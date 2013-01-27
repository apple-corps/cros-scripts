#!/bin/bash

# Copyright (c) 2011 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# make_netboot.sh --board=[board]
#
# This script builds a kernel image bundle with the factory install shim
# included as initramfs. Generated image, along with the netboot firmware
# are placed in a "netboot" subfolder.

SCRIPT_ROOT=$(dirname $(readlink -f "$0"))
. "${SCRIPT_ROOT}/common.sh" || exit 1

# Script must be run inside the chroot.
restart_in_chroot_if_needed "$@"

DEFINE_string board "${DEFAULT_BOARD}" \
  "The board to build an image for."
DEFINE_string image_dir "" "Path to the folder to store netboot images."

# Parse command line.
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

. "${SCRIPT_ROOT}/build_library/build_common.sh" || exit 1
. "${BUILD_LIBRARY_DIR}/board_options.sh" || exit 1

switch_to_strict_mode
# build_packages artifact output.
SYSROOT="${GCLIENT_ROOT}/chroot/build/${FLAGS_board}"
# build_image artifact output.

if [ -n "${FLAGS_image_dir}" ]; then
  cd ${FLAGS_image_dir}
else
  cd "${CHROOT_TRUNK_DIR}"/src/build/images/"${FLAGS_board}"/latest
fi

# Generate staging dir for netboot files.
sudo rm -rf netboot
mkdir -p netboot

# Get netboot firmware.
# TODO(nsanders): Set default IP here when userspace
# env modification is available.
# TODO(nsanders): ARM generic doesn't build chromeos-u-boot package.
# When ARM generic goes away, delete the test.
if ls "${SYSROOT}"/firmware/nv_image-*.bin >/dev/null 2>&1; then
    echo "Copying netboot firmware nv_image-*.bin"
    cp -v "${SYSROOT}"/firmware/nv_image-*.bin "netboot"
else
    echo "Skipping netboot firmware: " \
        "${SYSROOT}/firmware/nv_image-*.bin not present?"
fi

# Create temporary emerge root
temp_build_path="$(mktemp -d bk_XXXXXXXX)"
if ! [ -d "${temp_build_path}" ]; then
  echo "Failed to create temporary directory."
  exit 1
fi

# Build initramfs network boot image
echo "Building kernel"
export USE='vfat netboot_ramfs i2cdev tpm'
export EMERGE_BOARD_CMD="emerge-${FLAGS_board}"
emerge_custom_kernel ${temp_build_path}

# Place kernel image under 'netboot'
echo "Generating netboot kernel vmlinux.uimg"
if [ "${ARCH}" = "arm" ]; then
  cp "${temp_build_path}"/boot/vmlinux.uimg netboot/
else
  # U-boot put kernel image at 0x100000. We load it at 0x3000000 because
  # 0x3000000 is safe enough not to overlap with image at 0x100000.
  mkimage -A x86 -O linux -T kernel -n "Linux kernel" -C none \
      -d "${temp_build_path}"/boot/vmlinuz \
      -a 0x03000000 -e 0x03000000 netboot/vmlinux.uimg
fi

sudo rm -rf "${temp_build_path}"
