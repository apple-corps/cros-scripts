# Copyright (c) 2012 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Usage: run_lddtree <root> [args to lddtree] <files to process>
run_lddtree() {
  # Keep `local` decl split from assignment so return code is checked.
  local lddtree='/mnt/host/source/chromite/bin/lddtree'
  local root="$1"
  shift

  sudo "${lddtree}" -R "${root}" --no-auto-root --skip-non-elfs "$@"
}

# Usage: test_elf_deps <root> <files to check>
test_elf_deps() {
  # Keep `local` decl split from assignment so return code is checked.
  local f deps
  local root="$1"
  shift

  # We first check everything in one go.  We assume that it'll usually be OK,
  # so we make this the fast path.  If it does fail, we'll fall back to one at
  # a time so the error output is human readable.
  deps=$(run_lddtree "${root}" -l "$@") || return 1
  if echo "${deps}" | grep -q '^[^/]'; then
    error "test_elf_deps: Failed dependency check"
    for f in "$@"; do
      deps=$(run_lddtree "${root}" -l "${f}")
      if echo "${deps}" | grep -q '^[^/]'; then
        error "Package: $(ROOT="${root}" qfile -qCRv "${f}")"
        error "$(run_lddtree "${root}" "${f}")"
      fi
    done
    return 1
  fi

  return 0
}

test_image_content() {
  local root="$1"
  local returncode=0

  local binaries=(
    "$root/usr/bin/Xorg"
    "$root/boot/vmlinuz"
    "$root/sbin/session_manager"
    "$root/bin/sed"
  )
  # When chrome is built with USE="pgo_generate", rootfs chrome is actually a
  # symlink to a real binary which is in the stateful partition. So we do not
  # check for a valid chrome binary in that case.
  local chrome_binary="${root}/opt/google/chrome/chrome"
  if ! portageq-"${BOARD}" has_version "${root}" \
    'chromeos-base/chromeos-chrome[pgo_generate]'; then
    binaries+=( "${chrome_binary}" )
  fi

  for test_file in "${binaries[@]}"; do
    if [ ! -f "$test_file" ]; then
      error "test_image_content: Cannot find '$test_file'"
      returncode=1
    fi
  done

  # Keep `local` decl split from assignment so return code is checked.
  local libs

  # Check that all .so files, plus the binaries, have the appropriate
  # dependencies.  Need to use sudo as some files are set*id.
  libs=( $(sudo find "${root}" -type f -name '*.so*') )
  if ! test_elf_deps "${root}" "${binaries[@]}" "${libs[@]}"; then
    returncode=1
  fi

  local blacklist_dirs=(
    "$root/usr/share/locale"
  )
  for dir in "${blacklist_dirs[@]}"; do
    if [ -d "$dir" ]; then
      error "test_image_content: Blacklisted directory found: $dir"
      returncode=1
    fi
  done

  # Check that /etc/localtime is a symbolic link pointing at
  # /var/lib/timezone/localtime.
  local localtime="$root/etc/localtime"
  if [ ! -L "$localtime" ]; then
    error "test_image_content: /etc/localtime is not a symbolic link"
    returncode=1
  else
    local dest=$(readlink "$localtime")
    if [ "$dest" != "/var/lib/timezone/localtime" ]; then
      error "test_image_content: /etc/localtime points at $dest"
      returncode=1
    fi
  fi

  return $returncode
}
