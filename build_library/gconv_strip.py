#!/usr/bin/python
# Copyright 2014 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

"""Script to remove unused gconv charset modules from a build."""

import logging.handlers

import ahocorasick
import argparse
import glob
import operator
import os
import stat
import subprocess
import sys


# Path pattern to search for the gconv-modules file.
GCONV_MODULES_PATH = 'usr/*/gconv/gconv-modules'

# List of function names (symbols) known to use a charset as a parameter.
GCONV_SYMBOLS = (
    # glibc
    'iconv_open',
    'iconv',
    # glib
    'g_convert',
    'g_convert_with_fallback',
    'g_iconv',
    'g_locale_to_utf8',
    'g_get_charset',
    )

class GconvModules(object):
  """Class to manipulate the gconv/gconv-modules file and referenced modules.

  This class parses the contents of the gconv-modules file installed by glibc
  which provides the definition of the charsets supported by iconv_open(3). It
  allows to load the current gconv-modules file and rewrite it to include only
  a subset of the supported modules, removing the other modules.

  Each charset is involved on some transformation between that charset and an
  internal representation. This transformation is defined on a .so file loaded
  dynamically with dlopen(3) when the charset defined in this file is requested
  to iconv_open(3).

  See the comments on gconv-modules file for syntax details.
  """

  def __init__(self, gconv_modules_fn):
    """Initialize the class.

    Args:
      gconv_modules_fn: Path to gconv/gconv-modules file.
    """
    self._fn = gconv_modules_fn

    # An alias map of charsets. The key (fromcharset) is the alias name and
    # the value (tocharset) is the real charset name. We also support a value
    # that is an alias for another charset.
    self._alias = {}

    # The modules dict goes from charset to module names (the filenames without
    # the .so extension). Since several transformations involving the same
    # charset could be defined in different files, the values of this dict are
    # a set of module names.
    self._modules = {}

  def Load(self):
    """Load the charsets from gconv-modules."""
    for l in open(self._fn):
      l = l.rstrip('\n')
      if not l or l[0] == '#':  # Comment
        continue

      lst = l.split()
      if not lst:
        continue
      elif lst[0] == 'module':
        _, fromset, toset, filename = lst[:4]
        for charset in (fromset, toset):
          charset = charset.rstrip('/')
          mods = self._modules.get(charset, set())
          mods.add(filename)
          self._modules[charset] = mods
      elif lst[0] == 'alias':
        _, fromset, toset = lst
        fromset = fromset.rstrip('/')
        toset = toset.rstrip('/')
        # Warn if the same charset is defined as two different aliases
        if self._alias.get(fromset, toset) != toset:
          logging.error('charset "%s" already defined as "%s".',
                        fromset, self._alias[fromset])
        self._alias[fromset] = toset
      else:
        logging.error('Unknown line: %s', l)

    logging.debug('Found %d modules and %d alias on %s',
                  len(self._modules), len(self._alias), self._fn)
    charsets = sorted(self._alias.keys() + self._modules.keys())
    # Remove the 'INTERNAL' charset from the list, since it is not a charset
    # but an internal representation used to convert to and from other charsets.
    if 'INTERNAL' in charsets:
      charsets.remove('INTERNAL')
    return charsets

  def Rewrite(self, used_charsets, dry_run=False):
    """Rewrite gconv-modules file with only the used charsets.

    Args:
      used_charsets: A list of used charsets. This should be a subset of the
                     list returned by Load().
      dry_run: Whether this function should not change any file.
    """

    # Compute the used modules.
    used_modules = set()
    for charset in used_charsets:
      while charset in self._alias:
        charset = self._alias[charset]
      used_modules.update(self._modules[charset])
    unused_modules = reduce(set.union, self._modules.values()) - used_modules

    logging.debug('Used modules: %s', ', '.join(sorted(used_modules)))

    modules_dir = os.path.dirname(self._fn)
    unused_size = 0
    for module in sorted(unused_modules):
      module_path = os.path.join(modules_dir, '%s.so' % module)
      unused_size += os.lstat(module_path).st_size
      logging.debug('rm %s', module_path)
      if not dry_run:
        os.unlink(module_path)
    logging.info('Done. Using %d gconv modules. Removed %d unused modules'
                 ' (%.1f KiB)',
                 len(used_modules), len(unused_modules), unused_size / 1024.)

    # Recompute the gconv-modules file with only the included gconv modules.
    result = []
    for ln in open(self._fn):
      l = ln.rstrip('\n')
      lst = l.split()

      if not l or l[0] == '#' or not lst:
        result.append(ln)  # Keep comments and copyright headers.
      elif lst[0] == 'module':
        _, _, _, filename = lst[:4]
        if filename in used_modules:
          result.append(ln)  # Used module
      elif lst[0] == 'alias':
        _, charset, _ = lst
        charset = charset.rstrip('/')
        while charset in self._alias:
          charset = self._alias[charset]
        if used_modules.intersection(self._modules[charset]):
          result.append(ln)  # Alias to an used module
      else:
        logging.error('Unknown line: %s', l)

    if not dry_run:
      with open(self._fn, 'w') as f:
        f.write(''.join(result))


def MultipleStringMatch(patterns, corpus):
  """Search a list of strings in a corpus string.

  Args:
    patterns: A list of strings.
    corpus: The text where to search for the strings.

  Result:
    A list of Booleans stating whether each pattern string was found on the
    corpus or not.
  """
  tree = ahocorasick.KeywordTree()
  for word in patterns:
    tree.add(word)
  tree.make()

  result = [False] * len(patterns)
  for i, j in tree.findall(corpus):
    match = corpus[i:j]
    result[patterns.index(match)] = True

  return result


def GconvStrip(args):
  """Process gconv-modules and remove unused modules.

  Args:
    args: The command-line args passed to the script.

  Returns:
    The exit code number indicating whether the process succeeded.
  """
  root_st = os.lstat(args.root)
  if not stat.S_ISDIR(root_st.st_mode):
    raise Exception("root (%s) must be a directory.")

  # Detect the possible locations of the gconv-modules file.
  gconv_modules_files = glob.glob(os.path.join(args.root, GCONV_MODULES_PATH))

  if not gconv_modules_files:
    logging.error('gconv-modules file not found.')
    return 1

  # Only one gconv-modules files should be present, either on /usr/lib or
  # /usr/lib64, but not both.
  if len(gconv_modules_files) > 1:
    logging.error('Found several gconv-modules files.')
    return 1

  gconv_modules_fn = gconv_modules_files[0]
  logging.info('Searching for unused gconv files defined in %s',
               gconv_modules_fn)

  gmods = GconvModules(gconv_modules_fn)
  charsets = gmods.Load()

  # Use scanelf to search for all the binary files on the rootfs that require
  # or define the symbol iconv_open. We also include the binaries that define
  # it since there could be internal calls to it from other functions.
  files = set()
  for symbol in GCONV_SYMBOLS:
    output = subprocess.check_output([
        'scanelf', '--mount', '--quiet', '--recursive', '--format', '#s%F',
        '--symbol', symbol, args.root])
    symbol_files = output.splitlines()
    logging.debug('Symbol %s found on %d files.', symbol, len(symbol_files))
    files.update(symbol_files)

  # The charsets are represented as null-terminated strings on the binary files,
  # so we append the '\0' to each string. This prevents some false positives
  # when the name of the charset is a substring of some other string. It doesn't
  # prevent false positives when the charset name is the suffix of another
  # string, for example a binary with the string "DON'T DO IT\0" will match the
  # 'IT' charset. Empirical test on ChromeOS images suggests that only 4
  # charsets could fall in category.
  strings = [s + '\0' for s in charsets]
  logging.info('Will search for %d strings in %d files',
                len(strings), len(files))
  global_used = [False] * len(strings)
  for fn in files:
    with open(fn, 'rb') as f:
      used_fn = MultipleStringMatch(strings, f.read())

    global_used = map(operator.or_, global_used, used_fn)
    # Check the verbose flag to avoid running an useless loop.
    if args.verbose and any(used_fn):
      logging.debug('File %s:', fn)
      for i in range(len(used_fn)):
        if used_fn[i]:
          logging.debug(' - %s:', strings[i])

  used_charsets = [charsets[i] for i in range(len(charsets)) if global_used[i]]
  gmods.Rewrite(used_charsets, args.dry_run)
  return 0


def main():
  """Main function to start the script."""
  parser = argparse.ArgumentParser()

  parser.add_argument(
      '-V', '--verbose', dest='verbose', action='store_true', default=False,
      help='Verbose',)
  parser.add_argument(
      '--dry-run', dest='dry_run', action='store_true', default=False,
      help='process but don\'t modify any file.',)
  parser.add_argument(
      'root', help='path to the directory where the rootfs is mounted.',)

  logging_format = '%(asctime)s - %(filename)s - %(levelname)-8s: %(message)s'
  date_format = '%Y/%m/%d %H:%M:%S'
  logging.basicConfig(level=logging.INFO, format=logging_format,
                      datefmt=date_format)

  args = parser.parse_args()
  if args.verbose:
    logging.getLogger().setLevel(logging.DEBUG)

  logging.debug('Options are %s ', args)

  return GconvStrip(args)


if __name__ == '__main__':
  sys.exit(main())
