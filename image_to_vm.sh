#!/bin/bash

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to convert the output of build_image.sh to a QEMU image.

# Helper scripts should be run from the same location as this script.
SCRIPT_ROOT=$(dirname "$(readlink -f "$0")")
. "${SCRIPT_ROOT}/common.sh" || exit 1
. "${SCRIPT_ROOT}/build_library/build_common.sh" || exit 1

# Need to be inside the chroot to load chromeos-common.sh
assert_inside_chroot

# Load functions and constants for chromeos-install
. /usr/share/misc/chromeos-common.sh || exit 1
. "${SCRIPT_ROOT}/lib/cros_vm_constants.sh" || exit 1

# Flags
DEFINE_string adjust_part "" \
  "Adjustments to apply to the partition table"
DEFINE_string board "${DEFAULT_BOARD}" \
  "Board for which the image was built"
DEFINE_boolean factory $FLAGS_FALSE \
    "Modify the image for manufacturing testing"
DEFINE_boolean factory_install $FLAGS_FALSE \
    "Modify the image for factory install shim"

# We default to TRUE so the buildbot gets its image.
DEFINE_boolean force_copy ${FLAGS_FALSE} "Always rebuild test image"
DEFINE_string from "" \
  "Directory containing rootfs.image and mbr.image"
DEFINE_string disk_layout "2gb-rootfs-updatable" \
  "The disk layout type to use for this image."
DEFINE_string state_image "" \
  "Stateful partition image (defaults to creating new statful partition)"
DEFINE_boolean test_image "${FLAGS_FALSE}" \
  "Copies normal image to ${CHROMEOS_TEST_IMAGE_NAME}, modifies it for test."
DEFINE_string to "" \
  "Destination folder for VM output file(s)"

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# Die on any errors.
switch_to_strict_mode

TEMP_DIR=$(mktemp -d)
TEMP_MNT=""
TEMP_ESP_MNT=""
SRC_DEV=""
DST_DEV=""
cleanup() {
  if [[ -n "${TEMP_MNT}" ]]; then
    safe_umount "${TEMP_MNT}" || true
    rmdir "${TEMP_MNT}" || true
  fi
  if [[ -n "${TEMP_ESP_MNT}" ]]; then
    safe_umount "${TEMP_ESP_MNT}" || true
    rmdir "${TEMP_ESP_MNT}" || true
  fi

  if [[ -n "${SRC_DEV}" ]]; then
    loopback_detach "${SRC_DEV}" || true
  fi
  if [[ -n "${DST_DEV}" ]]; then
    loopback_detach "${DST_DEV}" || true
  fi
  rm -rf "${TEMP_DIR}"
}
trap 'ret=$?; cleanup; die_err_trap ${ret}' INT TERM EXIT

# Default to the most recent image
if [ -z "${FLAGS_from}" ] ; then
  FLAGS_from="$(${SCRIPT_ROOT}/get_latest_image.sh --board=${FLAGS_board})"
fi
if [ -z "${FLAGS_to}" ] ; then
  FLAGS_to="${FLAGS_from}"
fi

# Convert args to full paths.  Use echo here on the unquoted value to process all
# shell level expansions like ~ and *.
if ! resolved=$(readlink -f "$(echo ${FLAGS_from})"); then
  die_notrace "image_to_vm: processing --from failed." \
    "Verify the path exists: ${FLAGS_from}" \
    "  cwd: ${PWD}"
fi
FLAGS_from=${resolved}
if ! resolved=$(readlink -f "$(echo ${FLAGS_to})"); then
  die_notrace "image_to_vm: Processing --to failed." \
    "Verify the path exists: ${FLAGS_to}" \
    "  cwd: ${PWD}"
fi
FLAGS_to=${resolved}

if [ ${FLAGS_factory} -eq ${FLAGS_TRUE} ]; then
  SRC_IMAGE="${FLAGS_from}/${CHROMEOS_FACTORY_TEST_IMAGE_NAME}"
elif [ ${FLAGS_test_image} -eq ${FLAGS_TRUE} ]; then
  SRC_IMAGE="${FLAGS_from}/${CHROMEOS_TEST_IMAGE_NAME}"
else
  # Use the standard image
  SRC_IMAGE="${FLAGS_from}/${CHROMEOS_IMAGE_NAME}"
fi
if [[ ! -e ${SRC_IMAGE} ]]; then
  die_notrace "image_to_vm: src image does not exist: ${SRC_IMAGE}" \
    "Please verify you have selected the right input." \
    "Note: only dev/test/factory images can be used as inputs."
fi

. "${BUILD_LIBRARY_DIR}/board_options.sh" || exit 1
. "${SCRIPT_ROOT}/build_library/disk_layout_util.sh" || exit 1

# Memory units are in MBs
TEMP_IMG="$(dirname "${SRC_IMAGE}")/vm_temp_image.bin"

# Split apart the partitions and make some new ones
SRC_DEV=$(loopback_partscan "${SRC_IMAGE}")

# Fix the kernel command line
SRC_STATE="${SRC_DEV}"p1
SRC_ROOTFS="${SRC_DEV}"p3
SRC_KERN="${SRC_DEV}"p4
SRC_OEM="${SRC_DEV}"p8
SRC_ESP="${SRC_DEV}"p12
if [ -n "${FLAGS_state_image}" ]; then
  TEMP_STATE="${FLAGS_state_image}"
else
  STATEFUL_SIZE_BYTES=$(get_filesystem_size "${FLAGS_disk_layout}" 1)
  STATEFUL_SIZE_MEGABYTES=$(( STATEFUL_SIZE_BYTES / 1024 / 1024 ))
  original_image_size=$(bd_safe_size "${SRC_STATE}")
  if [ "${original_image_size}" -gt "${STATEFUL_SIZE_BYTES}" ]; then
    die "Cannot resize stateful image to smaller than original. Exiting."
  fi

  echo "Resizing stateful partition to ${STATEFUL_SIZE_MEGABYTES}MB"
  # Extend the original file size to the new size.
  TEMP_STATE="${TEMP_DIR}"/stateful
  # Create TEMP_STATE as a regular user so a regular user can delete it.
  sudo chmod a+r "${SRC_STATE}"
  cp "${SRC_STATE}" "${TEMP_STATE}"
  sudo e2fsck -pf "${TEMP_STATE}"
  sudo resize2fs "${TEMP_STATE}" ${STATEFUL_SIZE_MEGABYTES}M
fi
TEMP_PMBR="${TEMP_DIR}"/pmbr
dd if="${SRC_IMAGE}" of="${TEMP_PMBR}" bs=512 count=1

# Set up a new partition table.
PARTITION_SCRIPT_PATH=$(mktemp)
write_partition_script "${FLAGS_disk_layout}" "${PARTITION_SCRIPT_PATH}"
. "${PARTITION_SCRIPT_PATH}"
write_partition_table "${TEMP_IMG}" "${TEMP_PMBR}"
rm "${PARTITION_SCRIPT_PATH}"

DST_DEV=$(loopback_partscan "${TEMP_IMG}")
DST_STATE="${DST_DEV}"p1
DST_ROOTFS="${DST_DEV}"p3
DST_KERN="${DST_DEV}"p4
DST_OEM="${DST_DEV}"p8
DST_ESP="${DST_DEV}"p12

# Copy into the partition parts of the file.
sudo cp "${SRC_ROOTFS}" "${DST_ROOTFS}"
sudo cp "${TEMP_STATE}" "${DST_STATE}"
sudo cp "${SRC_ESP}"    "${DST_ESP}"
sudo cp "${SRC_OEM}"    "${DST_OEM}"

TEMP_MNT=$(mktemp -d)
TEMP_ESP_MNT=$(mktemp -d)
mkdir -p "${TEMP_MNT}"
enable_rw_mount "${DST_ROOTFS}"
sudo mount "${DST_ROOTFS}" "${TEMP_MNT}"
mkdir -p "${TEMP_ESP_MNT}"
sudo mount "${DST_ESP}" "${TEMP_ESP_MNT}"

# Unmount everything prior to building a final image
trap 'die_err_trap' INT TERM EXIT
cleanup

# Make the built-image bootable.
# NOTE: The TEMP_IMG must live in the same image dir as the original image
#       to operate automatically below.
${SCRIPTS_DIR}/bin/cros_make_image_bootable $(dirname "${TEMP_IMG}") \
                                            $(basename "${TEMP_IMG}") \
                                            --force_developer_mode

IMAGE_DEV=""
detach_loopback() {
  if [ -n "${IMAGE_DEV}" ]; then
    loopback_detach "${IMAGE_DEV}"
  fi
}
trap 'ret=$?; detach_loopback; die_err_trap ${ret}' INT TERM EXIT

# cros_make_image_bootable made the kernel in slot A recovery signed. We want
# it to be normally signed like the one in slot B, so copy B into A.
IMAGE_DEV=$(loopback_partscan "${TEMP_IMG}")
sudo cp ${IMAGE_DEV}p4 ${IMAGE_DEV}p2

trap 'die_err_trap' INT TERM EXIT
switch_to_strict_mode
loopback_detach "${IMAGE_DEV}"

echo Creating final image
mv "${TEMP_IMG}" "${FLAGS_to}/${DEFAULT_QEMU_IMAGE}"

rm -rf "${TEMP_IMG}"

echo "Created image at ${FLAGS_to}"

echo "If you have qemu-kvm installed, you can start the image by:"
echo "sudo kvm -m ${FLAGS_mem} -vga cirrus -pidfile /tmp/kvm.pid" \
  "-net nic,model=virtio -net user,hostfwd=tcp::9222-:22 \\"
echo "-hda ${FLAGS_to}/${DEFAULT_QEMU_IMAGE}"

