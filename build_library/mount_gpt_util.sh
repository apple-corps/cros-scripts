# Copyright (c) 2011 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# This global array variable is used to remember options from
# mount_image so that unmount_image can do its job.
MOUNT_GPT_OPTIONS=( )

# Usage: mount_image image rootfs_mountpt stateful_mountpt esp_mountpt \
#   [esp_mount]
#
# Mount the root, stateful, and optionally ESP partitions in a Chromium OS
# image.
# Args:
#  image: path to image to be mounted
#  rootfs_mountpt: path to root fs mount point
#  stateful_mountpt: path to stateful fs mount point
#  $4: path to ESP fs mount point; if empty the ESP will not be mounted
mount_image() {
  MOUNT_GPT_OPTIONS=(
    --from "$1"
    --rootfs_mountpt "$2"
    --stateful_mountpt "$3"
  )

  if [ $# -ge 4 ]; then
    MOUNT_GPT_OPTIONS+=( --esp_mountpt "$4" )
  fi

  "${SCRIPTS_DIR}/mount_gpt_image.sh" "${MOUNT_GPT_OPTIONS[@]}"
}

# Usage: remount_image [extra_flags ...]
#
# Remount the file systems mounted in the previous call to mount_image with the
# passed extra flags.
# Args:
#   extra_flags: Optional flags, "--read_only" and "--safe" passed to
#     mount_gpt_image.sh
remount_image() {
  # Check the extra_flags passed.
  local flag
  for flag in "$@"; do
    case "${flag}" in
      --read_only)
        ;;
      --safe)
        ;;
      *)
        die "Invalid flag '${flag}' passed to remount_image."
    esac
  done
  "${SCRIPTS_DIR}/mount_gpt_image.sh" --remount "${MOUNT_GPT_OPTIONS[@]}" "$@"
}

# Usage: unmount_image - Unmount the file systems mounted in the previous
#   call to mount_image.
# No arguments
unmount_image() {
  if [[ ${#MOUNT_GPT_OPTIONS[@]} -eq 0 ]]; then
    warn "Image already unmounted."
    return 1
  fi
  "${SCRIPTS_DIR}/mount_gpt_image.sh" --unmount "${MOUNT_GPT_OPTIONS[@]}"

  MOUNT_GPT_OPTIONS=( )
}
