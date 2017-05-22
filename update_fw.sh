#!/bin/bash
# Copyright 2017 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to update the firmware on a live running ChromiumOS instance.

SCRIPT_ROOT=$(dirname "$(readlink -f $0)")
. "${SCRIPT_ROOT}/common.sh" || exit 1
. "${SCRIPT_ROOT}/remote_access.sh" || exit 1

# Script must be run inside the chroot.
restart_in_chroot_if_needed "$@"

DEFINE_string board "" "Override board reported by target"
DEFINE_string image "image.dev.bin" "Specify image to be flashed"
DEFINE_boolean reboot ${FLAGS_TRUE} "Reboot system after update"

# Parse command line.
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# Only now can we die on error.  shflags functions leak non-zero error codes,
# so will die prematurely if 'switch_to_strict_mode' is specified before now.
switch_to_strict_mode

cleanup() {
  cleanup_remote_access
  rm -rf "${TMP}"
}

main() {
  local image_path
  local image
  local local_build
  trap cleanup EXIT

  TMP=$(mktemp -d /tmp/update_fw.XXXXXX)

  remote_access_init

  learn_arch

  learn_board

  local_build="/build/${FLAGS_board}/firmware/${FLAGS_image}"

  # Check if supplied image is absolute path.
  if [[ -r ${FLAGS_image} ]]; then
    image=${FLAGS_image}
    # Also check if we are mistaken with image in local build.
    if [[ -r ${local_build} ]]; then
      # Ask user which image needs to be flashed.
      PS3="Please choose image to be flashed[1]: "
      choose image "${FLAGS_image}" "${FLAGS_image}" "${FLAGS_image}" \
        "${local_build}"
    fi
    # Flash the user provide image in custom path.
    image_path=${image}
  else
    # Otherwise use image present in local build.
    image_path=${local_build}
    # If image doesn't exist, then exit.
    if [[ ! -r ${image_path} ]]; then
      die_notrace "Could not find the image ${image_path}"
    fi
  fi

  info "copying ${image_path}"
  remote_cp_to "${image_path}" /tmp/bios.bin
  info "Updating Firmware..."
  remote_sh flashrom --fast-verify -w /tmp/bios.bin

  if [[ ${FLAGS_reboot} -eq ${FLAGS_TRUE} ]]; then
    remote_reboot
  fi
}

main "$@"
