#!/usr/bin/python
# Copyright (c) 2012 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

"""Parse and operate based on disk layout files."""

from __future__ import print_function

import copy
import json
import optparse
import os
import re
import sys


class ConfigNotFound(Exception):
  """Config Not Found"""

class PartitionNotFound(Exception):
  """Partition Not Found"""

class InvalidLayout(Exception):
  """Invalid Layout"""

class InvalidAdjustment(Exception):
  """Invalid Adjustment"""

class InvalidSize(Exception):
  """Invalid Size"""

class ConflictingOptions(Exception):
  """Conflicting Options"""

class MismatchedRootfsFormat(Exception):
  """Rootfs partitions in different formats"""

class MismatchedRootfsBlocks(Exception):
  """Rootfs partitions have different numbers of reserved erase blocks"""

COMMON_LAYOUT = 'common'
BASE_LAYOUT = 'base'
# Blocks of the partition entry array.
SIZE_OF_PARTITION_ENTRY_ARRAY = 32
SIZE_OF_PMBR = 1
SIZE_OF_GPT_HEADER = 1


def ParseHumanNumber(operand):
  """Parse a human friendly number

  This handles things like 4GiB and 4MB and such.  See the usage string for
  full details on all the formats supported.

  Args:
    operand: The number to parse (may be an int or string)

  Returns:
    An integer
  """
  operand = str(operand)
  negative = -1 if operand.startswith('-') else 1
  if negative == -1:
    operand = operand[1:]
  operand_digits = re.sub(r'\D', r'', operand)

  size_factor = block_factor = 1
  suffix = operand[len(operand_digits):].strip()
  if suffix:
    size_factors = {'B': 0, 'K': 1, 'M': 2, 'G': 3, 'T': 4,}
    try:
      size_factor = size_factors[suffix[0].upper()]
    except KeyError:
      raise InvalidAdjustment('Unknown size type %s' % suffix)
    if size_factor == 0 and len(suffix) > 1:
      raise InvalidAdjustment('Unknown size type %s' % suffix)
    block_factors = {'': 1024, 'B': 1000, 'IB': 1024,}
    try:
      block_factor = block_factors[suffix[1:].upper()]
    except KeyError:
      raise InvalidAdjustment('Unknown size type %s' % suffix)

  return int(operand_digits) * pow(block_factor, size_factor) * negative


def ParseRelativeNumber(max_number, number):
  """Return the number that is relative to |max_number| by |number|

  We support three forms:
   90% - |number| is a percentage of |max_number|
   100 - |number| is the answer already (and |max_number| is ignored)
   -90 - |number| is subtracted from |max_number|

  Args:
    max_number: The limit to use when |number| is negative or a percent
    number: The (possibly relative) number to parse (may be an int or string)
  """
  max_number = int(max_number)
  number = str(number)
  if number.endswith('%'):
    percent = float(number[:-1]) / 100
    return int(max_number * percent)
  else:
    number = ParseHumanNumber(number)
    if number < 0:
      return max_number + number
    else:
      return number


def _ApplyLayoutOverrides(layout_to_override, layout):
  """Applies |layout| overrides on to |layout_to_override|.

  First add missing partition from layout to layout_to_override.
  Then, update partitions in layout_to_override with layout information.
  """
  for part_to_apply in layout:
    num = part_to_apply.get('num')
    if not num:
      continue

    for part in layout_to_override:
      if part.get('num') == num:
        part.update(part_to_apply)
        break
    # need of deepcopy, in case we change layout later.
    else:
      layout_to_override.append(copy.deepcopy(part_to_apply))


def LoadJSONWithComments(filename):
  """Loads a JSON file ignoring lines with comments.

  RFC 7159 doesn't allow comments on the file JSON format. This functions loads
  a JSON file removing all the comment lines. A comment line is any line
  starting with # and optionally indented with whitespaces. Note that inline
  comments are not supported.

  Args:
    filename: The input filename.

  Returns:
    The parsed JSON object.
  """
  regex = re.compile(r'^\s*#.*')
  with open(filename) as f:
    source = ''.join(regex.sub('', line) for line in f)
  return json.loads(source)


def _LoadStackedPartitionConfig(filename):
  """Loads a partition table and its possible parent tables.

  This does very little validation.  It's just enough to walk all of the parent
  files and merges them with the current config.  Overall validation is left to
  the caller.

  Args:
    filename: Filename to load into object.

  Returns:
    Object containing disk layout configuration
  """
  if not os.path.exists(filename):
    raise ConfigNotFound('Partition config %s was not found!' % filename)
  config = LoadJSONWithComments(filename)

  # Let's first apply our new configs onto base.
  common_layout = config['layouts'].setdefault(COMMON_LAYOUT, [])
  for layout_name, layout in config['layouts'].iteritems():
    # Don't apply on yourself.
    if layout_name == COMMON_LAYOUT or layout_name == '_comment':
      continue

    # Need to copy a list of dicts so make a deep copy.
    working_layout = copy.deepcopy(common_layout)
    _ApplyLayoutOverrides(working_layout, layout)
    config['layouts'][layout_name] = working_layout

  dirname = os.path.dirname(filename)
  # Now let's inherit the values from all our parents.
  for parent in config.get('parent', '').split():
    parent_filename = os.path.join(dirname, parent)
    parent_config = _LoadStackedPartitionConfig(parent_filename)

    # First if the parent is missing any fields the new config has, fill them
    # in.
    for key in config.keys():
      if key == 'parent':
        continue
      elif key == 'metadata':
        # We handle this especially to allow for inner metadata fields to be
        # added / modified.
        parent_config.setdefault(key, {})
        parent_config[key].update(config[key])
      else:
        parent_config.setdefault(key, config[key])

    # The overrides work by taking the parent_config, apply the new config
    # layout info, and return the resulting config which is stored in the parent
    # config.

    # So there's an issue where an inheriting layout file may contain new
    # layouts not previously defined in the parent layout. Since we are
    # building these layout files based on the parent configs and overriding
    # new values, we first add the new layouts not previously defined in the
    # parent config using a copy of the base layout from that parent config.
    parent_layouts = set(parent_config['layouts'])
    config_layouts = set(config['layouts'])
    new_layouts = config_layouts - parent_layouts

    # Actually add the copy. Use a copy such that each is unique.
    parent_cmn_layout = parent_config['layouts'].setdefault(COMMON_LAYOUT, [])
    for layout_name in new_layouts:
      parent_config['layouts'][layout_name] = copy.deepcopy(parent_cmn_layout)

    # Iterate through each layout in the parent config and apply the new layout.
    common_layout = config['layouts'].setdefault(COMMON_LAYOUT, [])
    for layout_name, parent_layout in parent_config['layouts'].iteritems():
      if layout_name == '_comment':
        continue

      layout_override = config['layouts'].setdefault(layout_name, [])
      if layout_name != COMMON_LAYOUT:
        _ApplyLayoutOverrides(parent_layout, common_layout)

      _ApplyLayoutOverrides(parent_layout, layout_override)

    config = parent_config

  config.pop('parent', None)
  return config


def LoadPartitionConfig(filename):
  """Loads a partition tables configuration file into a Python object.

  Args:
    filename: Filename to load into object

  Returns:
    Object containing disk layout configuration
  """

  valid_keys = set(('_comment', 'hybrid_mbr', 'metadata', 'layouts', 'parent'))
  valid_layout_keys = set((
      '_comment', 'num', 'blocks', 'block_size', 'fs_blocks', 'fs_block_size',
      'uuid', 'label', 'format', 'fs_format', 'type', 'features', 'num',
      'size', 'fs_size', 'fs_options'))

  config = _LoadStackedPartitionConfig(filename)
  try:
    metadata = config['metadata']
    for key in ('block_size', 'fs_block_size'):
      metadata[key] = ParseHumanNumber(metadata[key])

    unknown_keys = set(config.keys()) - valid_keys
    if unknown_keys:
      raise InvalidLayout('Unknown items: %r' % unknown_keys)

    if len(config['layouts']) <= 0:
      raise InvalidLayout('Missing "layouts" entries')

    if not BASE_LAYOUT in config['layouts'].keys():
      raise InvalidLayout('Missing "base" config in "layouts"')

    for layout_name, layout in config['layouts'].iteritems():
      if layout_name == '_comment':
        continue

      for part in layout:
        unknown_keys = set(part.keys()) - valid_layout_keys
        if unknown_keys:
          raise InvalidLayout('Unknown items in layout %s: %r' %
                              (layout_name, unknown_keys))

        if part['type'] != 'blank':
          for s in ('num', 'label'):
            if not s in part:
              raise InvalidLayout('Layout "%s" missing "%s"' % (layout_name, s))

        if 'size' in part:
          if 'blocks' in part:
            raise ConflictingOptions(
                'Conflicting settings are used. '
                'Found section sets both \'blocks\' and \'size\'.')
          part['bytes'] = ParseHumanNumber(part['size'])
          part['blocks'] = part['bytes'] / metadata['block_size']

          if part['bytes'] % metadata['block_size'] != 0:
            raise InvalidSize(
                'Size: "%s" (%s bytes) is not an even number of block_size: %s'
                % (part['size'], part['bytes'], metadata['block_size']))

        if 'fs_size' in part:
          part['fs_bytes'] = ParseHumanNumber(part['fs_size'])
          if part['fs_bytes'] > part['bytes']:
            raise InvalidLayout(
                'Filesystem may not be larger than partition: %s %s: %d > %d' %
                (layout_name, part['label'], part['fs_bytes'], part['bytes']))
          if part['fs_bytes'] % metadata['fs_block_size'] != 0:
            raise InvalidSize(
                'File system size: "%s" (%s bytes) is not an even number of '
                'fs blocks: %s' %
                (part['fs_size'], part['fs_bytes'], metadata['fs_block_size']))

        if 'blocks' in part:
          part['blocks'] = ParseHumanNumber(part['blocks'])
          part['bytes'] = part['blocks'] * metadata['block_size']

        if 'fs_blocks' in part:
          max_fs_blocks = part['bytes'] / metadata['fs_block_size']
          part['fs_blocks'] = ParseRelativeNumber(max_fs_blocks,
                                                  part['fs_blocks'])
          part['fs_bytes'] = part['fs_blocks'] * metadata['fs_block_size']

          if part['fs_bytes'] > part['bytes']:
            raise InvalidLayout(
                'Filesystem may not be larger than partition: %s %s: %d > %d' %
                (layout_name, part['label'], part['fs_bytes'], part['bytes']))
  except KeyError as e:
    raise InvalidLayout('Layout is missing required entries: %s' % e)

  return config


def _GetPrimaryEntryArrayLBA(config):
  """Return the start LBA of the primary partition entry array.

  Normally this comes after the primary GPT header but can be adjusted by
  setting the "primary_entry_array_lba" key under "metadata" in the config.

  Args:
    config: The config dictionary.

  Returns:
    The position of the primary partition entry array.
  """

  pmbr_and_header_size = SIZE_OF_PMBR + SIZE_OF_GPT_HEADER
  entry_array = config['metadata'].get('primary_entry_array_lba',
                                       pmbr_and_header_size)
  if entry_array < pmbr_and_header_size:
    raise InvalidLayout('Primary entry array (%d) must be at least %d.' %
                        entry_array, pmbr_and_header_size)
  return entry_array


def _GetStartSector(config):
  """Return the first usable location (LBA) for partitions.

  This value is the first LBA after the PMBR, the primary GPT header, and
  partition entry array.

  We round it up to 64 to maintain the same layout as before in the normal (no
  padding between the primary GPT header and its partition entry array) case.

  Args:
    config: The config dictionary.

  Returns:
    A suitable LBA for partitions, at least 64.
  """

  entry_array = _GetPrimaryEntryArrayLBA(config)
  start_sector = max(entry_array + SIZE_OF_PARTITION_ENTRY_ARRAY, 64)
  return start_sector


def GetTableTotals(config, partitions):
  """Calculates total sizes/counts for a partition table.

  Args:
    config: Partition configuration file object
    partitions: List of partitions to process

  Returns:
    Dict containing totals data
  """

  start_sector = _GetStartSector(config)
  ret = {
      'expand_count': 0,
      'expand_min': 0,
      'block_count': start_sector * config['metadata']['block_size']
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
  partitions = copy.deepcopy(config['layouts'][image_type])
  metadata = config['metadata']

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

  operand_bytes = ParseHumanNumber(operand)
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
    A string containing the skeleton script
  """

  script_shell_path = os.path.join(os.path.dirname(__file__), 'cgpt_shell.sh')
  with open(script_shell_path, 'r') as f:
    script_shell = ''.join(f.readlines())

  # Before we return, insert the path to this tool so somebody reading the
  # script later can tell where it was generated.
  script_shell = script_shell.replace('@SCRIPT_GENERATOR@', script_shell_path)

  return script_shell


def WriteLayoutFunction(options, sfile, func, image_type, config):
  """Writes a shell script function to write out a given partition table.

  Args:
    options: Flags passed to the script
    sfile: File handle we're writing to
    func: function of the layout:
       for removable storage device: 'partition',
       for the fixed storage device: 'base'
    image_type: Type of image eg base/test/dev/factory_install
    config: Partition configuration file object
  """

  partitions = GetPartitionTable(options, config, image_type)
  partition_totals = GetTableTotals(config, partitions)

  lines = [
      'write_%s_table() {' % func,
      'create_image $1 %d %s' % (
          partition_totals['min_disk_size'],
          config['metadata']['block_size']),
      'local curr=%d' % _GetStartSector(config),
      '# Create the GPT headers and tables. Pad the primary ones.',
      '${GPT} create -p %d $1' % (_GetPrimaryEntryArrayLBA(config) -
                                  (SIZE_OF_PMBR + SIZE_OF_GPT_HEADER)),
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
              '  stateful_size=$(( $(numsectors $1) - %d))' % (
                  partition_totals['block_count']),
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

  # Set default priorities and retry counter on kernel partitions.
  tries = 15
  prio = 15
  # The order of partition numbers in this loop matters.
  # Make sure partition #2 is the first one, since it will be marked as
  # default bootable partition.
  for n in (2, 4, 6):
    partition = GetPartitionByNumber(partitions, n)
    if partition['type'] != 'blank':
      lines += [
          '${GPT} add -i %s -S 0 -T %i -P %i $1' % (n, tries, prio)
      ]
      prio = 0
      # When not writing 'base' function, make sure the other partitions are
      # marked as non-bootable (retry count == 0), since the USB layout
      # doesn't have any valid data in slots B & C. But with base function,
      # called by chromeos-install script, the KERNEL A partition is replicated
      # into both slots A & B, so we should leave both bootable for error
      # recovery in this case.
      if func != 'base':
        tries = 0

  lines += ['${GPT} boot -p -b $2 -i 12 $1']
  if config.get('hybrid_mbr'):
    lines += ['install_hybrid_mbr $1']
  lines += ['${GPT} show $1']

  sfile.write('%s\n}\n' % '\n  '.join(lines))


def WritePartitionSizesFunction(options, sfile, func, image_type, config):
  """Writes out the partition size variable that can be extracted by a caller.

  Args:
    options: Flags passed to the script
    sfile: File handle we're writing to
    func: function of the layout:
       for removable storage device: 'partition',
       for the fixed storage device: 'base'
    image_type: Type of image eg base/test/dev/factory_install
    config: Partition configuration file object
  """
  func_name = 'load_%s_vars' % func
  lines = [
      '%s() {' % func_name,
      'DEFAULT_ROOTDEV="%s"' % config['metadata'].get('rootdev_%s' % func, ''),
  ]

  partitions = GetPartitionTable(options, config, image_type)
  for partition in partitions:
    for key in ('label', 'num'):
      if key in partition:
        shell_label = str(partition[key]).replace('-', '_').upper()
        part_bytes = partition['bytes']
        fs_bytes = partition.get('fs_bytes', part_bytes)
        part_format = partition.get('format', '')
        fs_format = partition.get('fs_format', '')
        lines += [
            'PARTITION_SIZE_%s=%s' % (shell_label, part_bytes),
            '     DATA_SIZE_%s=%s' % (shell_label, fs_bytes),
            '        FORMAT_%s=%s' % (shell_label, part_format),
            '     FS_FORMAT_%s=%s' % (shell_label, fs_format),
        ]

  sfile.write('%s\n}\n' % '\n  '.join(lines))


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

    for func, layout in (('base', BASE_LAYOUT), ('partition', image_type)):
      WriteLayoutFunction(options, f, func, layout, config)
      WritePartitionSizesFunction(options, f, func, layout, config)

    # TODO: Backwards compat.  Should be killed off once we update
    #       cros_generate_update_payload to use the new code.
    partitions = GetPartitionTable(options, config, BASE_LAYOUT)
    partition = GetPartitionByLabel(partitions, 'ROOT-A')
    f.write('ROOTFS_PARTITION_SIZE=%s\n' % (partition['bytes'],))


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

  This is used for all partitions in the table that have filesystems.

  Args:
    options: Flags passed to the script
    layout_filename: Path to partition configuration file

  Returns:
    Block size of all filesystems in the layout
  """

  config = LoadPartitionConfig(layout_filename)
  return config['metadata']['fs_block_size']


def GetType(options, image_type, layout_filename, num):
  """Returns the type of a given partition for a given layout.

  Args:
    options: Flags passed to the script
    image_type: Type of image eg base/test/dev/factory_install
    layout_filename: Path to partition configuration file
    num: Number of the partition you want to read from

  Returns:
    Type of the specified partition.
  """
  partitions = GetPartitionTableFromConfig(options, layout_filename, image_type)
  partition = GetPartitionByNumber(partitions, num)
  return partition.get('type')


def GetPartitions(options, image_type, layout_filename):
  """Returns the partition numbers for the image_type.

  Args:
    options: Flags passed to the script
    image_type: Type of image eg base/test/dev/factory_install
    layout_filename: Path to partition configuration file

  Returns:
    A space delimited string of partition numbers.
  """
  partitions = GetPartitionTableFromConfig(options, layout_filename, image_type)
  return ' '.join(str(p['num']) for p in partitions if 'num' in p)


def GetUUID(options, image_type, layout_filename, num):
  """Returns the filesystem UUID of a given partition for a given layout type.

  Args:
    options: Flags passed to the script
    image_type: Type of image eg base/test/dev/factory_install
    layout_filename: Path to partition configuration file
    num: Number of the partition you want to read from

  Returns:
    UUID of specified partition. Defaults to random if not set.
  """
  partitions = GetPartitionTableFromConfig(options, layout_filename, image_type)
  partition = GetPartitionByNumber(partitions, num)
  return partition.get('uuid', 'random')


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


def GetFilesystemFormat(options, image_type, layout_filename, num):
  """Returns the filesystem format of a given partition for a given layout type.

  Args:
    options: Flags passed to the script
    image_type: Type of image eg base/test/dev/factory_install
    layout_filename: Path to partition configuration file
    num: Number of the partition you want to read from

  Returns:
    Format of the selected partition's filesystem
  """

  partitions = GetPartitionTableFromConfig(options, layout_filename, image_type)
  partition = GetPartitionByNumber(partitions, num)

  return partition.get('fs_format')


def GetFormat(options, image_type, layout_filename, num):
  """Returns the format of a given partition for a given layout type.

  Args:
    options: Flags passed to the script
    image_type: Type of image eg base/test/dev/factory_install
    layout_filename: Path to partition configuration file
    num: Number of the partition you want to read from

  Returns:
    Format of the selected partition's filesystem
  """

  partitions = GetPartitionTableFromConfig(options, layout_filename, image_type)
  partition = GetPartitionByNumber(partitions, num)

  return partition.get('format')


def GetFilesystemOptions(options, image_type, layout_filename, num):
  """Returns the filesystem options of a given partition and layout type.

  Args:
    options: Flags passed to the script
    image_type: Type of image eg base/test/dev/factory_install
    layout_filename: Path to partition configuration file
    num: Number of the partition you want to read from

  Returns:
    The selected partition's filesystem options
  """

  partitions = GetPartitionTableFromConfig(options, layout_filename, image_type)
  partition = GetPartitionByNumber(partitions, num)

  fs_options = partition.get('fs_options', {})
  if isinstance(fs_options, dict):
    fs_format = partition.get('fs_format')
    result = fs_options.get(fs_format, '')
  elif isinstance(fs_options, basestring):
    result = fs_options
  else:
    raise InvalidLayout('Partition number %s: fs_format must be a string or '
                        'dict, not "%s"' % (num, fs_options.__class__.__name__))
  if '"' in result or "'" in result:
    raise InvalidLayout('Partition number %s: fs_format cannot have quotes' %
                        num)

  return result


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
  config = LoadPartitionConfig(layout_filename)
  partitions = GetPartitionTable(options, config, image_type)

  label_len = max([len(x['label']) for x in partitions if 'label' in x])
  type_len = max([len(x['type']) for x in partitions if 'type' in x])

  msg = 'num:%4s label:%-*s type:%-*s size:%-10s fs_size:%-10s features:%s'

  # Print out non-layout options first.
  print('Config Data')
  metadata_msg = 'field:%-14s value:%s'
  for key in config.keys():
    if key not in ('layouts', '_comment'):
      print(metadata_msg % (key, config[key]))

  print('\n%s Layout Data' % image_type.upper())
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

    print(msg % (
        partition.get('num', 'auto'),
        label_len,
        partition.get('label', ''),
        type_len,
        partition.get('type', ''),
        size,
        fs_size,
        partition.get('features', ''),
    ))


def CheckRootfsPartitionsMatch(partitions):
  """Checks that rootfs partitions are substitutable with each other.

  This function asserts that either all rootfs partitions are in the same format
  or none have a format, and it asserts that have the same number of reserved
  erase blocks.
  """
  partition_format = None
  reserved_erase_blocks = -1
  for partition in partitions:
    if partition.get('type') == 'rootfs':
      new_format = partition.get('format', '')
      new_reserved_erase_blocks = partition.get('reserved_erase_blocks', 0)

      if partition_format is None:
        partition_format = new_format
        reserved_erase_blocks = new_reserved_erase_blocks

      if new_format != partition_format:
        raise MismatchedRootfsFormat(
            'mismatched rootfs formats: "%s" and "%s"' %
            (partition_format, new_format))

      if reserved_erase_blocks != new_reserved_erase_blocks:
        raise MismatchedRootfsBlocks(
            'mismatched rootfs reserved erase block counts: %s and %s' %
            (reserved_erase_blocks, new_reserved_erase_blocks))


def Validate(options, image_type, layout_filename):
  """Validates a layout file, used before reading sizes to check for errors.

  Args:
    options: Flags passed to the script
    image_type: Type of image eg base/test/dev/factory_install
    layout_filename: Path to partition configuration file
  """
  partitions = GetPartitionTableFromConfig(options, layout_filename, image_type)
  CheckRootfsPartitionsMatch(partitions)


def main(argv):
  action_map = {
      'write': {
          'usage': ['<image_type>', '<disk_layout>', '<script_file>'],
          'func': WritePartitionScript,
      },
      'readblocksize': {
          'usage': ['<disk_layout>'],
          'func': GetBlockSize,
      },
      'readfsblocksize': {
          'usage': ['<disk_layout>'],
          'func': GetFilesystemBlockSize,
      },
      'readpartsize': {
          'usage': ['<image_type>', '<disk_layout>', '<partition_num>'],
          'func': GetPartitionSize,
      },
      'readformat': {
          'usage': ['<image_type>', '<disk_layout>', '<partition_num>'],
          'func': GetFormat,
      },
      'readfsformat': {
          'usage': ['<image_type>', '<disk_layout>', '<partition_num>'],
          'func': GetFilesystemFormat,
      },
      'readfssize': {
          'usage': ['<image_type>', '<disk_layout>', '<partition_num>'],
          'func': GetFilesystemSize,
      },
      'readfsoptions': {
          'usage': ['<image_type>', '<disk_layout>', '<partition_num>'],
          'func': GetFilesystemOptions,
      },
      'readlabel': {
          'usage': ['<image_type>', '<disk_layout>', '<partition_num>'],
          'func': GetLabel,
      },
      'readtype': {
          'usage': ['<image_type>', '<disk_layout>', '<partition_num>'],
          'func': GetType,
      },
      'readpartitionnums': {
          'usage': ['<image_type>', '<disk_layout>'],
          'func': GetPartitions,
      },
      'readuuid': {
          'usage': ['<image_type>', '<disk_layout>', '<partition_num>'],
          'func': GetUUID,
      },
      'debug': {
          'usage': ['<image_type>', '<disk_layout>'],
          'func': DoDebugOutput,
      },
      'validate': {
          'usage': ['<image_type>', '<disk_layout>'],
          'func': Validate,
      },
  }

  usage = """%prog <action> [options]

For information on the JSON format, see:
  http://dev.chromium.org/chromium-os/developer-guide/disk-layout-format

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
"""

  action_docs = []
  for action_name, action in sorted(action_map.iteritems()):
    doc = action['func'].__doc__.split('\n', 1)[0]
    action_docs.append('  %s %s\n      %s' % (action_name,
                                              ' '.join(action['usage']), doc))
  usage += '\n\n'.join(action_docs)

  parser = optparse.OptionParser(usage=usage)
  parser.add_option("--adjust_part", dest="adjust_part",
                    help="adjust partition sizes", default="")
  (options, args) = parser.parse_args(args=argv[1:])

  if not args or args[0] not in action_map:
    parser.error('need a valid action to perform')
  else:
    action_name = args[0]
    action = action_map[action_name]
    if len(action['usage']) == len(args) - 1:
      ret = action['func'](options, *args[1:])
      if ret is not None:
        print(ret)
    else:
      sys.exit('Usage: %s %s %s' % (sys.argv[0], args[0],
                                    ' '.join(action['usage'])))


if __name__ == '__main__':
  main(sys.argv)
