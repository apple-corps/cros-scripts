# Copyright (c) 2011 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Common library file to be sourced by build_image,
# mod_image_for_test.sh, and mod_image_for_recovery.sh.  This
# file ensures that library source files needed by all the scripts
# are included once, and also takes care of certain bookeeping tasks
# common to all the scripts.

# SCRIPT_ROOT must be set prior to sourcing this file
. "${SCRIPT_ROOT}/common.sh" || exit 1

# All scripts using this file must be run inside the chroot.
restart_in_chroot_if_needed "$@"

. /usr/share/misc/chromeos-common.sh || exit 1

locate_gpt

should_build_image() {
  # Fast pass back if we should build all incremental images.
  local image_name
  local image_to_build

  for image_name in "$@"; do
    for image_to_build in ${IMAGES_TO_BUILD}; do
      [ "${image_to_build}" = "${image_name}" ] && return 0
    done
  done

  return 1
}

# Returns the pv command if it's available, otherwise plain-old cat. Note that
# this function echoes the command, rather than running it, so it can be used
# as an argument to other commands (like sudo).
pv_cat_cmd() {
  if type -P pv >&/dev/null; then
    # Limit pv's output to 80 columns, for readability.
    local term_cols=$(stty size 2>/dev/null | cut -d' ' -f2)
    if [[ ${term_cols:-0} -gt 80 ]]; then
      echo pv -w 80 -B 4m
    else
      echo pv -B 4m
    fi
  else
    echo cat
  fi
}

# Utility function for creating a copy of an image prior to
# modification from the BUILD_DIR:
#  $1: source filename
#  $2: destination filename
copy_image() {
  local src="${BUILD_DIR}/$1"
  local dst="${BUILD_DIR}/$2"
  if should_build_image $1; then
    echo "Creating $2 from $1..."
    $(pv_cat_cmd) "${src}" >"${dst}" || die "Cannot copy $1 to $2"
  else
    mv "${src}" "${dst}" || die "Cannot move $1 to $2"
  fi
}
