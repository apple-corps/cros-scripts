#!/usr/bin/python
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


if __name__ == '__main__':
  unittest.main()
