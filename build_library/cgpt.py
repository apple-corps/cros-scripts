#!/usr/bin/python
# Copyright (c) 2012 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

import copy
import json
import optparse
import os
import re
import sys

# First sector we can use.
START_SECTOR = 64

class ConfigNotFound(Exception):
  pass
class PartitionNotFound(Exception):
  pass
class InvalidLayout(Exception):
  pass
class InvalidAdjustment(Exception):
  pass


BASE_LAYOUT = 'base'
PRIMARY_ROOT_PARTITION = 'ROOT-A'
ROOT_PARTITION_VAR = 'ROOTFS_PARTITION_SIZE'
_INHERITED_LAYOUT_KEYS = set(('type', 'label', 'features',))


def LoadPartitionConfig(filename):
  """Loads a partition tables configuration file into a Python object.

  Args:
    filename: Filename to load into object
  Returns:
    Object containing disk layout configuration
  """

  valid_keys = set(('_comment', 'metadata', 'layouts'))
  valid_layout_keys = _INHERITED_LAYOUT_KEYS | set((
      '_comment', 'num', 'blocks', 'block_size', 'fs_blocks', 'fs_block_size'))

  if not os.path.exists(filename):
    raise ConfigNotFound('Partition config %s was not found!' % filename)
  with open(filename) as f:
    config = json.load(f)

  try:
    metadata = config['metadata']
    for key in ('block_size', 'fs_block_size'):
      metadata[key] = int(metadata[key])

    unknown_keys = set(config.keys()) - valid_keys
    if unknown_keys:
      raise InvalidLayout('Unknown items: %r' % unknown_keys)

    if len(config['layouts']) <= 0:
      raise InvalidLayout('Missing "layouts" entries')

    if not BASE_LAYOUT in config['layouts'].keys():
      raise InvalidLayout('Missing "base" config in "layouts"')

    for layout_name, layout in config['layouts'].iteritems():
      for part in layout:
        unknown_keys = set(part.keys()) - valid_layout_keys
        if unknown_keys:
          raise InvalidLayout('Unknown items in layout %s: %r' %
                              (layout_name, unknown_keys))

        if layout_name != BASE_LAYOUT:
          # Inherit from the base config by num.
          for base_part in config['layouts'][BASE_LAYOUT]:
            if ('num' in base_part and 'num' in part and
                base_part['num'] == part['num']):
              for k, v in base_part.iteritems():
                if k in _INHERITED_LAYOUT_KEYS and k not in part:
                  part[k] = v
              break

        if part['type'] != 'blank':
          for s in ('num', 'label'):
            if not s in part:
              raise InvalidLayout('Layout "%s" missing "%s"' % (layout_name, s))

        part['blocks'] = int(part['blocks'])
        part['bytes'] = part['blocks'] * metadata['block_size']

        if 'fs_blocks' in part:
          part['fs_blocks'] = int(part['fs_blocks'])
          part['fs_bytes'] = part['fs_blocks'] * metadata['fs_block_size']

          if part['fs_bytes'] > part['bytes']:
            raise InvalidLayout(
                'Filesystem may not be larger than partition: %s %s: %d > %d' %
                (layout_name, part['label'], part['fs_bytes'], part['bytes']))
  except KeyError as e:
    raise InvalidLayout('Layout is missing required entries: %s' % e)

  return config


def GetTableTotals(config, partitions):
  """Calculates total sizes/counts for a partition table.

  Args:
    config: Partition configuration file object
    partitions: List of partitions to process
  Returns:
    Dict containing totals data
  """

  ret = {
    'expand_count': 0,
    'expand_min': 0,
    'block_count': START_SECTOR * config['metadata']['block_size']
  }

  # Total up the size of all non-expanding partitions to get the minimum
  # required disk size.
  for partition in partitions:
    if 'features' in partition and 'expand' in partition['features']:
      ret['expand_count'] += 1
      ret['expand_min'] += partition['blocks']
    else:
      ret['block_count'] += partition['blocks']

  # At present, only one expanding partition is permitted.
  # Whilst it'd be possible to have two, we don't need this yet
  # and it complicates things, so it's been left out for now.
  if ret['expand_count'] > 1:
    raise InvalidLayout('1 expand partition allowed, %d requested'
                        % ret['expand_count'])

  ret['min_disk_size'] = ret['block_count'] + ret['expand_min']

  return ret


def GetPartitionTable(options, config, image_type):
  """Generates requested image_type layout from a layout configuration.
  This loads the base table and then overlays the requested layout over
  the base layout.

  Args:
    options: Flags passed to the script
    config: Partition configuration file object
    image_type: Type of image eg base/test/dev/factory_install
  Returns:
    Object representing a selected partition table
  """

  # We make a deep copy so that changes to the dictionaries in this list do not
  # persist across calls.
  partitions = copy.deepcopy(config['layouts'][BASE_LAYOUT])
  metadata = config['metadata']

  if image_type != BASE_LAYOUT:
    for partition_t in config['layouts'][image_type]:
      for partition in partitions:
        if 'num' in partition_t and 'num' in partition:
          if partition_t['num'] == partition['num']:
            for k, v in partition_t.items():
              partition[k] = v

  for adjustment_str in options.adjust_part.split():
    adjustment = adjustment_str.split(':')
    if len(adjustment) < 2:
      raise InvalidAdjustment('Adjustment "%s" is incomplete' % adjustment_str)

    label = adjustment[0]
    operator = adjustment[1][0]
    operand = adjustment[1][1:]
    ApplyPartitionAdjustment(partitions, metadata, label, operator, operand)

  return partitions


def ApplyPartitionAdjustment(partitions, metadata, label, operator, operand):
  """Applies an adjustment to a partition specified by label

  Args:
    partitions: Partition table to modify
    metadata: Partition table metadata
    label: The label of the partition to adjust
    operator: Type of adjustment (+/-/=)
    operand: How much to adjust by
  """

  partition = GetPartitionByLabel(partitions, label)

  operand_digits = re.sub('\D', '', operand)
  size_factor = block_factor = 1
  suffix = operand[len(operand_digits):]
  if suffix:
    size_factors = { 'B': 0, 'K': 1, 'M': 2, 'G': 3, 'T': 4, }
    try:
      size_factor = size_factors[suffix[0].upper()]
    except KeyError:
      raise InvalidAdjustment('Unknown size type %s' % suffix)
    if size_factor == 0 and len(suffix) > 1:
      raise InvalidAdjustment('Unknown size type %s' % suffix)
    block_factors = { '': 1024, 'B': 1000, 'IB': 1024, }
    try:
      block_factor = block_factors[suffix[1:].upper()]
    except KeyError:
      raise InvalidAdjustment('Unknown size type %s' % suffix)

  operand_bytes = int(operand_digits) * pow(block_factor, size_factor)

  if operand_bytes % metadata['block_size'] == 0:
    operand_blocks = operand_bytes / metadata['block_size']
  else:
    raise InvalidAdjustment('Adjustment size %s not divisible by block size %s'
                            % (operand_bytes, metadata['block_size']))

  if operator == '+':
    partition['blocks'] += operand_blocks
    partition['bytes'] += operand_bytes
  elif operator == '-':
    partition['blocks'] -= operand_blocks
    partition['bytes'] -= operand_bytes
  elif operator == '=':
    partition['blocks'] = operand_blocks
    partition['bytes'] = operand_bytes
  else:
    raise ValueError('unknown operator %s' % operator)

  if partition['type'] == 'rootfs':
    # If we're adjusting a rootFS partition, we assume the full partition size
    # specified is being used for the filesytem, minus the space reserved for
    # the hashpad.
    partition['fs_bytes'] = partition['bytes']
    partition['fs_blocks'] = partition['fs_bytes'] / metadata['fs_block_size']
    partition['blocks'] = int(partition['blocks'] * 1.15)
    partition['bytes'] = partition['blocks'] * metadata['block_size']


def GetPartitionTableFromConfig(options, layout_filename, image_type):
  """Loads a partition table and returns a given partition table type

  Args:
    options: Flags passed to the script
    layout_filename: The filename to load tables from
    image_type: The type of partition table to return
  """

  config = LoadPartitionConfig(layout_filename)
  partitions = GetPartitionTable(options, config, image_type)

  return partitions


def GetScriptShell():
  """Loads and returns the skeleton script for our output script.

  Returns:
    A string containg the skeleton script
  """

  script_shell_path = os.path.join(os.path.dirname(__file__), 'cgpt_shell.sh')
  with open(script_shell_path, 'r') as f:
    script_shell = ''.join(f.readlines())

  # Before we return, insert the path to this tool so somebody reading the
  # script later can tell where it was generated.
  script_shell = script_shell.replace('@SCRIPT_GENERATOR@', script_shell_path)

  return script_shell


def WriteLayoutFunction(options, sfile, func_name, image_type, config):
  """Writes a shell script function to write out a given partition table.

  Args:
    options: Flags passed to the script
    sfile: File handle we're writing to
    func_name: Function name to write out for specified layout
    image_type: Type of image eg base/test/dev/factory_install
    config: Partition configuration file object
  """

  partitions = GetPartitionTable(options, config, image_type)
  partition_totals = GetTableTotals(config, partitions)

  lines = [
    '%s() {' % func_name,
    'create_image $1 %d %s' % (
        partition_totals['min_disk_size'],
        config['metadata']['block_size']),
    'local curr=%d' % START_SECTOR,
    '${GPT} create $1',
  ]

  # Pass 1: Set up the expanding partition size.
  for partition in partitions:
    partition['var'] = partition['blocks']

    if partition['type'] != 'blank':
      if partition['num'] == 1:
        if 'features' in partition and 'expand' in partition['features']:
          lines += [
            'local stateful_size=%s' % partition['blocks'],
            'if [ -b $1 ]; then',
            '  stateful_size=$(( $(numsectors $1) - %d))' %
                partition_totals['block_count'],
            'fi',
          ]
          partition['var'] = '${stateful_size}'

  lines += [
    ': $(( stateful_size -= (stateful_size %% %d) ))' % (
        config['metadata']['fs_block_size'],),
  ]

  # Pass 2: Write out all the cgpt add commands.
  for partition in partitions:
    if partition['type'] != 'blank':
      lines += [
        '${GPT} add -i %d -b ${curr} -s %s -t %s -l "%s" $1 && ' % (
            partition['num'], str(partition['var']), partition['type'],
            partition['label']),
      ]

    # Increment the curr counter ready for the next partition.
    if partition['var'] != 0:
      lines += [
        ': $(( curr += %s ))' % partition['var'],
      ]

  # Set default priorities on kernel partitions.
  prio = 15
  for n in (2, 4, 6):
    partition = GetPartitionByNumber(partitions, n)
    if partition['type'] != 'blank':
      lines += [
        '${GPT} add -i %s -S 0 -T 15 -P %i $1' % (n, prio)
      ]
      prio = 0

  lines += [
    '${GPT} boot -p -b $2 -i 12 $1',
    '${GPT} show $1',
  ]
  sfile.write('%s\n}\n' % '\n  '.join(lines))


def WriteRootPartitionSize(options, sfile, config):
  """Writes out the partition size variable that can be extracted by a caller.

  Args:
    options: Flags passed to the script
    sfile: File handle we're writing to
    config: Partition configuration file object
  """
  partitions = GetPartitionTable(options, config, BASE_LAYOUT)
  partition = GetPartitionByLabel(partitions, PRIMARY_ROOT_PARTITION)
  sfile.write('%s=%s\n' % (ROOT_PARTITION_VAR, partition['bytes']))


def GetPartitionByNumber(partitions, num):
  """Given a partition table and number returns the partition object.

  Args:
    partitions: List of partitions to search in
    num: Number of partition to find
  Returns:
    An object for the selected partition
  """
  for partition in partitions:
    if partition.get('num', None) == int(num):
      return partition

  raise PartitionNotFound('Partition %s not found' % num)


def GetPartitionByLabel(partitions, label):
  """Given a partition table and label returns the partition object.

  Args:
    partitions: List of partitions to search in
    label: Label of partition to find
  Returns:
    An object for the selected partition
  """
  for partition in partitions:
    if 'label' not in partition:
      continue
    if partition['label'] == label:
      return partition

  raise PartitionNotFound('Partition "%s" not found' % label)


def WritePartitionScript(options, image_type, layout_filename, sfilename):
  """Writes a shell script with functions for the base and requested layouts.

  Args:
    options: Flags passed to the script
    image_type: Type of image eg base/test/dev/factory_install
    layout_filename: Path to partition configuration file
    sfilename: Filename to write the finished script to
  """

  config = LoadPartitionConfig(layout_filename)

  with open(sfilename, 'w') as f:
    script_shell = GetScriptShell()
    f.write(script_shell)

    WriteLayoutFunction(options, f, 'write_base_table', BASE_LAYOUT, config)
    WriteLayoutFunction(options, f, 'write_partition_table', image_type, config)
    WriteRootPartitionSize(options, f, config)


def GetBlockSize(_options, layout_filename):
  """Returns the partition table block size.

  Args:
    options: Flags passed to the script
    layout_filename: Path to partition configuration file
  Returns:
    Block size of all partitions in the layout
  """

  config = LoadPartitionConfig(layout_filename)
  return config['metadata']['block_size']


def GetFilesystemBlockSize(_options, layout_filename):
  """Returns the filesystem block size.

  Args:
    options: Flags passed to the script

  This is used for all partitions in the table that have filesystems.

  Args:
    layout_filename: Path to partition configuration file
  Returns:
    Block size of all filesystems in the layout
  """

  config = LoadPartitionConfig(layout_filename)
  return config['metadata']['fs_block_size']


def GetPartitionSize(options, image_type, layout_filename, num):
  """Returns the partition size of a given partition for a given layout type.

  Args:
    options: Flags passed to the script
    image_type: Type of image eg base/test/dev/factory_install
    layout_filename: Path to partition configuration file
    num: Number of the partition you want to read from
  Returns:
    Size of selected partition in bytes
  """

  partitions = GetPartitionTableFromConfig(options, layout_filename, image_type)
  partition = GetPartitionByNumber(partitions, num)

  return partition['bytes']


def GetFilesystemSize(options, image_type, layout_filename, num):
  """Returns the filesystem size of a given partition for a given layout type.

  If no filesystem size is specified, returns the partition size.

  Args:
    options: Flags passed to the script
    image_type: Type of image eg base/test/dev/factory_install
    layout_filename: Path to partition configuration file
    num: Number of the partition you want to read from
  Returns:
    Size of selected partition filesystem in bytes
  """

  partitions = GetPartitionTableFromConfig(options, layout_filename, image_type)
  partition = GetPartitionByNumber(partitions, num)

  if 'fs_bytes' in partition:
    return partition['fs_bytes']
  else:
    return partition['bytes']


def GetLabel(options, image_type, layout_filename, num):
  """Returns the label for a given partition.

  Args:
    options: Flags passed to the script
    image_type: Type of image eg base/test/dev/factory_install
    layout_filename: Path to partition configuration file
    num: Number of the partition you want to read from
  Returns:
    Label of selected partition, or 'UNTITLED' if none specified
  """

  partitions = GetPartitionTableFromConfig(options, layout_filename, image_type)
  partition = GetPartitionByNumber(partitions, num)

  if 'label' in partition:
    return partition['label']
  else:
    return 'UNTITLED'


def DoDebugOutput(options, image_type, layout_filename):
  """Prints out a human readable disk layout in on-disk order.

  This will round values larger than 1MB, it's exists to quickly
  visually verify a layout looks correct.

  Args:
    options: Flags passed to the script
    image_type: Type of image eg base/test/dev/factory_install
    layout_filename: Path to partition configuration file
  """
  partitions = GetPartitionTableFromConfig(options, layout_filename, image_type)

  label_len = max([len(x['label']) for x in partitions if 'label' in x])
  type_len = max([len(x['type']) for x in partitions if 'type' in x])

  msg = 'num:%4s label:%-*s type:%-*s size:%-10s fs_size:%-10s features:%s'
  for partition in partitions:
    if partition['bytes'] < 1024 * 1024:
      size = '%d B' % partition['bytes']
    else:
      size = '%d MiB' % (partition['bytes'] / 1024 / 1024)

    if 'fs_bytes' in partition:
      if partition['fs_bytes'] < 1024 * 1024:
        fs_size = '%d B' % partition['fs_bytes']
      else:
        fs_size = '%d MiB' % (partition['fs_bytes'] / 1024 / 1024)
    else:
      fs_size = 'auto'

    print msg % (
        partition.get('num', 'auto'),
        label_len,
        partition.get('label', ''),
        type_len,
        partition.get('type', ''),
        size,
        fs_size,
        partition.get('features', ''),
    )


def DoParseOnly(options, image_type, layout_filename):
  """Parses a layout file only, used before reading sizes to check for errors.

  Args:
    options: Flags passed to the script
    image_type: Type of image eg base/test/dev/factory_install
    layout_filename: Path to partition configuration file
  """
  _ = GetPartitionTableFromConfig(options, layout_filename, image_type)


def main(argv):
  action_map = {
    'write': {
      'usage': ['<image_type>', '<partition_config_file>', '<script_file>'],
      'func': WritePartitionScript,
    },
    'readblocksize': {
      'usage': ['<partition_config_file>'],
      'func': GetBlockSize,
    },
    'readfsblocksize': {
      'usage': ['<partition_config_file>'],
      'func': GetFilesystemBlockSize,
    },
    'readpartsize': {
      'usage': ['<image_type>', '<partition_config_file>', '<partition_num>'],
      'func': GetPartitionSize,
    },
    'readfssize': {
      'usage': ['<image_type>', '<partition_config_file>', '<partition_num>'],
      'func': GetFilesystemSize,
    },
    'readlabel': {
      'usage': ['<image_type>', '<partition_config_file>', '<partition_num>'],
      'func': GetLabel,
    },
    'debug': {
      'usage': ['<image_type>', '<partition_config_file>'],
      'func': DoDebugOutput,
    },
    'parseonly': {
      'usage': ['<image_type>', '<partition_config_file>'],
      'func': DoParseOnly,
    }
  }

  usage = """%prog <action> [options]

For information on the JSON format, see:
  http://dev.chromium.org/chromium-os/building-chromium-os/disk-layout-format

The --adjust_part flag takes arguments like:
  <label>:<op><size>
Where:
  <label> is a label name as found in the disk layout file
  <op> is one of the three: + - =
  <size> is a number followed by an optional size qualifier:
         B, KiB, MiB, GiB, TiB: bytes, kibi-, mebi-, gibi-, tebi- (base 1024)
         B,   K,   M,   G,   T: short hand for above
         B,  KB,  MB,  GB,  TB: bytes, kilo-, mega-, giga-, tera- (base 1000)

This will set the ROOT-A partition size to 1 gibibytes (1024 * 1024 * 1024 * 1):
  --adjust_part ROOT-A:=1GiB
This will grow the ROOT-A partition size by 500 mebibytes (1024 * 1024 * 500):
  --adjust_part ROOT-A:+500MiB
This will shrink the ROOT-A partition size by 10 mebibytes (1024 * 1024 * 10):
  --adjust_part ROOT-A:-20MiB

Actions:
""" + '\n'.join(['%20s %s' % (x, ' '.join(action_map[x]['usage']))
                 for x in sorted(action_map)])
  parser = optparse.OptionParser(usage=usage)
  parser.add_option("--adjust_part", dest="adjust_part",
                    help="adjust partition sizes", default="")
  (options, args) = parser.parse_args(args=argv[1:])

  if len(args) < 1 or args[0] not in action_map:
    parser.error('need a valid action to perform')
  else:
    action_name = args[0]
    action = action_map[action_name]
    if len(action['usage']) == len(args) - 1:
      ret = action['func'](options, *args[1:])
      if ret is not None:
        print ret
    else:
      sys.exit('Usage: %s %s %s' % (sys.argv[0], args[0],
               ' '.join(action['usage'])))


if __name__ == '__main__':
  main(sys.argv)
