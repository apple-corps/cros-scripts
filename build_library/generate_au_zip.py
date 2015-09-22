#!/usr/bin/python2

# Copyright (c) 2012 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

"""Script to generate a zip file of delta-generator and its dependencies."""

from __future__ import print_function

import logging.handlers
import optparse
import os
import shutil
import subprocess
import tempfile

# GLOBALS
BINARY_EXECUTABLES = [
    # These are standard tools not necessarily installed outside the chroot at
    # the versions we need.
    '/bin/dd',
    '/usr/bin/e2cp',
    '/usr/bin/truncate',
    # These are specific to our build.
    '/usr/bin/cgpt',
    '/usr/bin/delta_generator',
    '/usr/bin/simg2img',
    # These versions include custom patches with bug fixes.
    '/usr/bin/bsdiff',
    '/usr/bin/bspatch',
    ]
EXECUTABLE_FILES = BINARY_EXECUTABLES + [
    '~/trunk/src/scripts/common.sh',
    '/usr/bin/brillo_update_payload',
    '/usr/bin/cros_generate_update_payload',
    '/usr/share/vboot/bin/common_minimal.sh',
    ]
# We need directories to be copied recursively to a dest within tempdir
SHELL_LIBRARIES = {'~/trunk/src/scripts/lib/shflags': 'lib/shflags'}


def CopyExecutableFiles(elf_binaries, zip_base):
  """Copy the listed binaries over to the target directory.

  For each binary 'foo' in elf_binaries create:

    zip_base/foo
      Wrapper script to handle dynamic linking when run:

    zip_base/foo.elf
      Originarl binary.

    zip_base/lib/...
      All libraries that foo depends on.

  Args:
    elf_binaries: List of binaries to copy, along with libraries.
    zip_base: Directory into which binaries/libraries are to be placed.
  """
  elf_binaries = [os.path.expanduser(p) for p in elf_binaries]

  cmd = ['/mnt/host/source/chromite/bin/lddtree',
         '--copy-to-tree', zip_base,
         '--copy-non-elfs',
         '--bindir', '/',
         '--libdir', '/lib',
         '--elf-subdir', '.elf',
         '--generate-wrappers']
  cmd += elf_binaries

  subprocess.check_call(cmd)


def CopyShellLibraries(shell_libraries, zip_base):
  """Copy shell library directories into the zip_base.

  Args:
    shell_libraries: A dictionary mapping directory_to_copy ->
                                          directory_relative_zip_base.
    zip_base: Target directory to copy into.
  """

  for source_dir, target_dir in shell_libraries.iteritems():
    src = os.path.expanduser(source_dir)
    dest = os.path.join(zip_base, target_dir)
    logging.debug('Copying %s -> %s', src, dest)
    shutil.copytree(src, dest)


def GenerateZipFile(zip_file, zip_base):
  """Create the specified zip file with contents of a directory.

  Args:
    zip_file: name of the zip file.
    zip_base: The directory that we should zip.
  """
  # Make sure the directory for the output file exists.
  zip_output_dir = os.path.dirname(zip_file)
  if not os.path.exists(zip_output_dir):
    os.makedirs(zip_output_dir)

  # Make sure the output zip file doesn't exist, so we start clean.
  if os.path.exists(zip_file):
    os.unlink(zip_file)

  logging.debug('Generating zip file %s with contents from %s', zip_file,
                zip_base)
  current_dir = os.getcwd()
  try:
    os.chdir(zip_base)
    subprocess.check_call(['zip', '-r', '-9', zip_file, '.'])
  finally:
    os.chdir(current_dir)


def main():
  """Main function to start the script"""
  parser = optparse.OptionParser()

  parser.add_option(
      '-d', '--debug', dest='debug', action='store_true',
      default=False, help='Verbose [%default]',)
  parser.add_option(
      '-o', '--output-dir', dest='output_dir',
      default='/tmp/au-generator',
      help='The output location for copying the zipfile [%default]')
  parser.add_option(
      '-z', '--zip-name', dest='zip_name',
      default='au-generator.zip', help='Name of the zip file. [%default]')
  parser.add_option(
      '-k', '--keep-temp', dest='keep_temp', default=False,
      action='store_true', help='Keep the temp files... [%default]',)

  logging_format = '%(asctime)s - %(filename)s - %(levelname)-8s: %(message)s'
  date_format = '%Y/%m/%d %H:%M:%S'
  logging.basicConfig(level=logging.INFO, format=logging_format,
                      datefmt=date_format)

  (options, _) = parser.parse_args()
  if options.debug:
    logging.getLogger().setLevel(logging.DEBUG)

  logging.debug('Options are %s ', options)

  zip_base = None
  try:
    zip_base = tempfile.mkdtemp(suffix='au', prefix='tmp')
    logging.debug('Using tempdir = %s', zip_base)

    CopyExecutableFiles(EXECUTABLE_FILES, zip_base)
    CopyShellLibraries(SHELL_LIBRARIES, zip_base)

    zip_file = os.path.join(options.output_dir, options.zip_name)
    GenerateZipFile(zip_file, zip_base)
    logging.info('Generated %s' % zip_file)

  finally:
    if zip_base and not options.keep_temp:
      shutil.rmtree(zip_base, ignore_errors=True)
      logging.debug('Removed tempdir = %s', zip_base)

if __name__ == '__main__':
  main()
