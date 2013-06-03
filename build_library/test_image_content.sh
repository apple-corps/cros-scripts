# Copyright (c) 2012 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

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
  local libs check_deps
  local lddtree='/mnt/host/source/chromite/bin/lddtree'

  # Check that all .so files, plus the binaries, have the appropriate
  # dependencies.  Need to use sudo as some files are set*id.
  libs=( $(sudo find "${root}" -type f -name '*.so*') )
  check_deps=$(sudo ${lddtree} -l -R "${root}" --no-auto-root --skip-non-elfs \
    "${binaries[@]}" "${libs[@]}")
  if echo "${check_deps}" | grep '^[^/]'; then
    error "test_image_content: Failed dependency check"
    error "${check_deps}"
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
