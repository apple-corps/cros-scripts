#!/usr/bin/env python2
# Copyright 2015 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

"""Unit tests for cgpt."""

# pylint: disable=W0212

from __future__ import print_function

import cgpt

import os
import shutil
import tempfile
import unittest


class JSONLoadingTest(unittest.TestCase):
  """Test stacked JSON loading functions."""

  def __init__(self, *args, **kwargs):
    unittest.TestCase.__init__(self, *args, **kwargs)
    self.tempdir = None
    self.maxDiff = 1000

  def setUp(self):
    self.tempdir = tempfile.mkdtemp(prefix='cgpt-test_')
    self.layout_json = os.path.join(self.tempdir, 'test_layout.json')
    self.parent_layout_json = os.path.join(self.tempdir,
                                           'test_layout_parent.json')

  def tearDown(self):
    if self.tempdir is not None:
      shutil.rmtree(self.tempdir)
      self.tempdir = None

  def testJSONComments(self):
    """Test that we ignore comments in JSON in lines starting with #."""
    with open(self.layout_json, 'w') as f:
      f.write("""# This line is a comment.
{
    # Here I have another comment starting with some whitespaces on the left.
    "layouts": {
        "common": []
    }
}
""")
    self.assertEqual(cgpt._LoadStackedPartitionConfig(self.layout_json),
                     {'layouts': {'common': []}})

  def testJSONCommentsLimitations(self):
    """Test that we can't parse inline comments in JSON.

    If we ever enable this, we need to change the README.disk_layout
    documentation to mention it.
    """
    with open(self.layout_json, 'w') as f:
      f.write("""{
    "layouts": { # This is an inline comment, but is not supported.
        "common": []}}""")
    self.assertRaises(ValueError,
                      cgpt._LoadStackedPartitionConfig, self.layout_json)

  def testPartitionOrderPreserved(self):
    """Test that the order of the partitions is the same as in the parent."""
    with open(self.parent_layout_json, 'w') as f:
      f.write("""{
  "layouts": {
    "common": [
      {
        "num": 3,
        "name": "Part 3"
      },
      {
        "num": 2,
        "name": "Part 2"
      },
      {
        "num": 1,
        "name": "Part 1"
      }
    ]
  }
}""")
    parent_layout = cgpt._LoadStackedPartitionConfig(self.parent_layout_json)

    with open(self.layout_json, 'w') as f:
      f.write("""{
  "parent": "%s",
  "layouts": {
    "common": []
  }
}""" % self.parent_layout_json)
    layout = cgpt._LoadStackedPartitionConfig(self.layout_json)
    self.assertEqual(parent_layout, layout)

    # Test also that even overriding one partition keeps all of them in order.
    with open(self.layout_json, 'w') as f:
      f.write("""{
  "parent": "%s",
  "layouts": {
    "common": [
      {
        "num": 2,
        "name": "Part 2"
      }
    ]
  }
}""" % self.parent_layout_json)
    layout = cgpt._LoadStackedPartitionConfig(self.layout_json)
    self.assertEqual(parent_layout, layout)

  def testGetStartSectorIsAccurate(self):
    """Test that primary_entry_array_lba results in a valid start sector."""
    test_params = (
        # block_size, primary_entry_array_lba, expected start
        (512,  2,     64),
        (512,  32768, 32768 + cgpt.SIZE_OF_PARTITION_ENTRY_ARRAY),
        (1024, 32768, 32768 + cgpt.SIZE_OF_PARTITION_ENTRY_ARRAY),
    )
    for i in test_params:
      with open(self.layout_json, 'w') as f:
        f.write("""{
  "metadata": {
    "block_size": %d,
    "fs_block_size": 4096,
    "primary_entry_array_lba": %d
  },
  "layouts": {
    "base": [
      {
        "type": "blank",
        "size": "32 MiB"
      }
    ]
  }
}""" % (i[0], i[1]))

      config = cgpt.LoadPartitionConfig(self.layout_json)
      class Options(object):
        adjust_part = ''
      partitions = cgpt.GetPartitionTable(Options(), config, 'base')
      start_sector = cgpt._GetStartSector(config, partitions)
      self.assertEqual(start_sector, i[2])

  def testGetTableTotalsBlockCountIsAccurate(self):
    """Test that primary_entry_array_lba results in an accurate block count."""
    test_params = (
        # block_size, primary_entry_array_lba, partition size (MiB)
        (512,  2,     32),
        (1024, 2,     32),
        (512,  2,     64),
        (512,  32768, 32),
        (1024, 32768, 32),
        (1024, 32768, 64),
    )
    for i in test_params:
      with open(self.layout_json, 'w') as f:
        f.write("""{
  "metadata": {
    "block_size": %d,
    "fs_block_size": 4096,
    "primary_entry_array_lba": %d
  },
  "layouts": {
    "base": [
      {
        "type": "blank",
        "size": "%d MiB"
      }
    ]
  }
}""" % (i[0], i[1], i[2]))

      config = cgpt.LoadPartitionConfig(self.layout_json)
      class Options(object):
        adjust_part = ''
      partitions = cgpt.GetPartitionTable(Options(), config, 'base')
      totals = cgpt.GetTableTotals(config, partitions)

      # Calculate the expected image block size.
      block_count = (
          cgpt._GetStartSector(config, partitions) +
          sum([i['blocks'] for i in partitions]) +
          cgpt.SIZE_OF_GPT_HEADER + cgpt.SIZE_OF_PARTITION_ENTRY_ARRAY)
      self.assertEqual(totals['block_count'], block_count)

  def testGapPartitionsAreIncluded(self):
    """Test that empty partitions (gaps) can be included in the child layout."""
    with open(self.layout_json, 'w') as f:
      f.write("""{
  "layouts": {
    # The common layout is empty but is applied to all the other layouts.
    "common": [],
    "base": [
      {
        "num": 2,
        "name": "Part 2"
      },
      {
        # Pad out, but not sure why.
        "type": "blank",
        "size": "64 MiB"
      },
      {
        "num": 1,
        "name": "Part 1"
      }
    ]
  }
}""")
    self.assertEqual(
        cgpt._LoadStackedPartitionConfig(self.layout_json),
        {
            'layouts': {
                'common': [],
                'base': [
                    {'num': 2, 'name': "Part 2"},
                    {'type': 'blank', 'size': "64 MiB"},
                    {'num': 1, 'name': "Part 1"}
                ]
            }})

  def testPartitionOrderShouldMatch(self):
    """Test that the partition order in parent and child layouts must match."""
    with open(self.layout_json, 'w') as f:
      f.write("""{
  "layouts": {
    "common": [
      {"num": 1},
      {"num": 2}
    ],
    "base": [
      {"num": 2},
      {"num": 1}
    ]
  }
}""")
    self.assertRaises(cgpt.ConflictingPartitionOrder,
                      cgpt._LoadStackedPartitionConfig, self.layout_json)

  def testOnlySharedPartitionsOrderMatters(self):
    """Test that only the order of the partition in both layouts matters."""
    with open(self.layout_json, 'w') as f:
      f.write("""{
  "layouts": {
    "common": [
      {"num": 1},
      {"num": 2},
      {"num": 3}
    ],
    "base": [
      {"num": 2},
      {"num": 12},
      {"num": 3},
      {"num": 5}
    ]
  }
}""")
    self.assertEqual(
        cgpt._LoadStackedPartitionConfig(self.layout_json),
        {
            'layouts': {
                'common': [
                    {'num': 1},
                    {'num': 2},
                    {'num': 3}
                ],
                'base': [
                    {'num': 1},
                    {'num': 2},
                    {'num': 12},
                    {'num': 3},
                    {'num': 5}
                ]
            }})

  def testFileSystemSizeMustBePositive(self):
    """Test that zero or negative file system size will raise exception."""
    with open(self.layout_json, 'w') as f:
      f.write("""{
  "metadata": {
    "block_size": "512",
    "fs_block_size": "4 KiB"
  },
  "layouts": {
    "base": [
      {
        "num": 1,
        "type": "rootfs",
        "label": "ROOT-A",
        "fs_size": "0 KiB"
      }
    ]
  }
}""")
    try:
      cgpt.LoadPartitionConfig(self.layout_json)
    except cgpt.InvalidSize as e:
      self.assertTrue('must be positive' in str(e))
    else:
      self.fail('InvalidSize not raised.')

  def testFileSystemSizeLargerThanPartition(self):
    """Test that file system size must not be greater than partition."""
    with open(self.layout_json, 'w') as f:
      f.write("""{
  "metadata": {
    "block_size": "512",
    "fs_block_size": "4 KiB"
  },
  "layouts": {
    "base": [
      {
        "num": 1,
        "type": "rootfs",
        "label": "ROOT-A",
        "size": "4 KiB",
        "fs_size": "8 KiB"
      }
    ]
  }
}""")
    try:
      cgpt.LoadPartitionConfig(self.layout_json)
    except cgpt.InvalidSize as e:
      self.assertTrue('may not be larger than partition' in str(e))
    else:
      self.fail('InvalidSize not raised.')

  def testFileSystemSizeNotMultipleBlocks(self):
    """Test that file system size must be multiples of file system blocks."""
    with open(self.layout_json, 'w') as f:
      f.write("""{
  "metadata": {
    "block_size": "512",
    "fs_block_size": "4 KiB"
  },
  "layouts": {
    "base": [
      {
        "num": 1,
        "type": "rootfs",
        "label": "ROOT-A",
        "size": "4 KiB",
        "fs_size": "3 KiB"
      }
    ]
  }
}""")
    try:
      cgpt.LoadPartitionConfig(self.layout_json)
    except cgpt.InvalidSize as e:
      self.assertTrue('not an even number of fs blocks' in str(e))
    else:
      self.fail('InvalidSize not raised.')

  def testFileSystemSizeForUbiWithNoPageSize(self):
    """Test that "page_size" must be present to calculate UBI fs size."""
    with open(self.layout_json, 'w') as f:
      f.write("""{
  "metadata": {
    "block_size": "512",
    "fs_block_size": "4 KiB"
  },
  "layouts": {
    "base": [
      {
        "num": 1,
        "type": "rootfs",
        "format": "ubi",
        "label": "ROOT-A",
        "size": "4 KiB",
        "fs_size": "4 KiB"
      }
    ]
  }
}""")
    try:
      cgpt.LoadPartitionConfig(self.layout_json)
    except cgpt.InvalidLayout as e:
      self.assertTrue('page_size' in str(e))
    else:
      self.fail('InvalidLayout not raised.')

  def testFileSystemSizeForUbiWithNoEraseBlockSize(self):
    """Test that "erase_block_size" must be present to calculate UBI fs size."""
    with open(self.layout_json, 'w') as f:
      f.write("""{
  "metadata": {
    "block_size": "512",
    "fs_block_size": "4 KiB"
  },
  "layouts": {
    "base": [
      {
        "num": "metadata",
        "page_size": "4 KiB"
      },
      {
        "num": 1,
        "type": "rootfs",
        "format": "ubi",
        "label": "ROOT-A",
        "size": "4 KiB",
        "fs_size": "4 KiB"
      }
    ]
  }
}""")
    try:
      cgpt.LoadPartitionConfig(self.layout_json)
    except cgpt.InvalidLayout as e:
      self.assertTrue('erase_block_size' in str(e))
    else:
      self.fail('InvalidLayout not raised.')

  def testFileSystemSizeForUbiIsNotMultipleOfUbiEraseBlockSize(self):
    """Test that we raise when fs_size is not multiple of eraseblocks."""
    with open(self.layout_json, 'w') as f:
      f.write("""{
  "metadata": {
    "block_size": "512",
    "fs_block_size": "4 KiB"
  },
  "layouts": {
    "base": [
      {
        "num": "metadata",
        "page_size": "4 KiB",
        "erase_block_size": "262144"
      },
      {
        "num": 1,
        "type": "rootfs",
        "format": "ubi",
        "label": "ROOT-A",
        "size": "256 KiB",
        "fs_size": "256 KiB"
      }
    ]
  }
}""")
    try:
      cgpt.LoadPartitionConfig(self.layout_json)
    except cgpt.InvalidSize as e:
      self.assertTrue('to "248 KiB" in the "common" layout' in str(e))
    else:
      self.fail('InvalidSize not raised')

  def testFileSystemSizeForUbiIsMultipleOfUbiEraseBlockSize(self):
    """Test that everything is okay when fs_size is multiple of eraseblocks."""
    with open(self.layout_json, 'w') as f:
      f.write("""{
  "metadata": {
    "block_size": "512",
    "fs_block_size": "4 KiB"
  },
  "layouts": {
    "base": [
      {
        "num": "metadata",
        "page_size": "4 KiB",
        "erase_block_size": "262144"
      },
      {
        "num": 1,
        "type": "rootfs",
        "format": "ubi",
        "label": "ROOT-A",
        "size": "256 KiB",
        "fs_size": "253952"
      }
    ]
  }
}""")
    self.assertEqual(
        cgpt.LoadPartitionConfig(self.layout_json),
        {
            'layouts': {
                'base': [
                    {
                        'erase_block_size': 262144,
                        'features': [],
                        'num': 'metadata',
                        'page_size': 4096,
                        'type': 'blank'
                    },
                    {
                        'blocks': 512,
                        'bytes': 262144,
                        'features': [],
                        'format': 'ubi',
                        'fs_bytes': 253952,
                        'fs_size': "253952",
                        'label': 'ROOT-A',
                        'num': 1,
                        'size': '256 KiB',
                        'type': 'rootfs'
                    }
                ],
                'common': []
            },
            'metadata': {
                'block_size': 512,
                'fs_block_size': 4096
            }
        })


class UtilityTest(unittest.TestCase):
  """Test various utility functions in cgpt.py."""

  def testParseHumanNumber(self):
    """Test that ParseHumanNumber is correct."""
    test_cases = [
        ("1", 1),
        ("2", 2),
        ("1KB", 1000),
        ("1KiB", 1024),
        ("1 K", 1024),
        ("1 KiB", 1024),
        ("3 MB", 3000000),
        ("4 MiB", 4 * 2**20),
        ("5GB", 5 * 10**9),
        ("6GiB", 6 * 2**30),
        ("7TB", 7 * 10**12),
        ("8TiB", 8 * 2**40),
    ]
    for inp, exp in test_cases:
      self.assertEqual(cgpt.ParseHumanNumber(inp), exp)

  def testProduceHumanNumber(self):
    """Test that ProduceHumanNumber is correct."""
    test_cases = [
        ("1", 1),
        ("2", 2),
        ("1 KB", 1000),
        ("1 KiB", 1024),
        ("3 MB", 3 * 10**6),
        ("4 MiB", 4 * 2**20),
        ("5 GB", 5 * 10**9),
        ("6 GiB", 6 * 2**30),
        ("7 TB", 7 * 10**12),
        ("8 TiB", 8 * 2**40),
    ]
    for exp, inp in test_cases:
      self.assertEqual(cgpt.ProduceHumanNumber(inp), exp)


  def testParseProduce(self):
    """Test that ParseHumanNumber(ProduceHumanNumber()) yields same value."""
    test_cases = [
        1, 2,
        1000, 1024,
        2 * 10**6, 2 * 2**20,
        3 * 10**9, 3 * 2**30,
        4 * 10**12, 4 * 2**40
    ]
    for n in test_cases:
      self.assertEqual(cgpt.ParseHumanNumber(cgpt.ProduceHumanNumber(n)), n)


if __name__ == '__main__':
  unittest.main()
