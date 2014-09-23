#!/bin/bash

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to convert the output of build_image.sh to a VMware image and write a
# corresponding VMware config file.

# Helper scripts should be run from the same location as this script.
SCRIPT_ROOT=$(dirname "$(readlink -f "$0")")
. "${SCRIPT_ROOT}/common.sh" || exit 1
. "${SCRIPT_ROOT}/build_library/disk_layout_util.sh" || exit 1
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
DEFINE_string format "qemu" \
  "Output format, either qemu, vmware or virtualbox"
DEFINE_string from "" \
  "Directory containing rootfs.image and mbr.image"
DEFINE_string disk_layout "2gb-rootfs-updatable" \
  "The disk layout type to use for this image."
DEFINE_boolean make_vmx ${FLAGS_TRUE} \
  "Create a vmx file for use with vmplayer (vmware only)."
DEFINE_integer mem "${DEFAULT_MEM}" \
  "Memory size for the vm config in MBs (vmware only)."
DEFINE_string state_image "" \
  "Stateful partition image (defaults to creating new statful partition)"
DEFINE_boolean test_image "${FLAGS_FALSE}" \
  "Copies normal image to ${CHROMEOS_TEST_IMAGE_NAME}, modifies it for test."
DEFINE_string to "" \
  "Destination folder for VM output file(s)"
DEFINE_string vbox_disk "${DEFAULT_VBOX_DISK}" \
  "Filename for the output disk (virtualbox only)."
DEFINE_string vmdk "${DEFAULT_VMDK}" \
  "Filename for the vmware disk image (vmware only)."
DEFINE_string vmx "${DEFAULT_VMX}" \
  "Filename for the vmware config (vmware only)."

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# Die on any errors.
switch_to_strict_mode

if [ -z "${FLAGS_board}" ] ; then
  die_notrace "--board is required."
fi

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
trap cleanup INT TERM EXIT

BOARD="$FLAGS_board"

IMAGES_DIR="${DEFAULT_BUILD_ROOT}/images/${FLAGS_board}"
# Default to the most recent image
if [ -z "${FLAGS_from}" ] ; then
  FLAGS_from="$(${SCRIPT_ROOT}/get_latest_image.sh --board=${FLAGS_board})"
else
  pushd "${FLAGS_from}" && FLAGS_from=`pwd` && popd
fi
if [ -z "${FLAGS_to}" ] ; then
  FLAGS_to="${FLAGS_from}"
fi

if [ ${FLAGS_factory} -eq ${FLAGS_TRUE} ]; then
  SRC_IMAGE="${FLAGS_from}/${CHROMEOS_FACTORY_TEST_IMAGE_NAME}"
elif [ ${FLAGS_test_image} -eq ${FLAGS_TRUE} ]; then
  SRC_IMAGE="${FLAGS_from}/${CHROMEOS_TEST_IMAGE_NAME}"
else
  # Use the standard image
  SRC_IMAGE="${FLAGS_from}/${CHROMEOS_IMAGE_NAME}"
fi

# Memory units are in MBs
TEMP_IMG="$(dirname "${SRC_IMAGE}")/vm_temp_image.bin"

# If we're not building for VMWare, don't build the vmx
if [ "${FLAGS_format}" != "vmware" ]; then
  FLAGS_make_vmx="${FLAGS_FALSE}"
fi

# Convert args to paths.  Need eval to un-quote the string so that shell
# chars like ~ are processed; just doing FOO=`readlink -f $FOO` won't work.
FLAGS_from=`eval readlink -f $FLAGS_from`
FLAGS_to=`eval readlink -f $FLAGS_to`

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
  dd if="${SRC_STATE}" of="${TEMP_STATE}"
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
sudo dd if="${SRC_ROOTFS}" of="${DST_ROOTFS}"
sudo dd if="${TEMP_STATE}" of="${DST_STATE}"
sudo dd if="${SRC_ESP}"    of="${DST_ESP}"
sudo dd if="${SRC_OEM}"    of="${DST_OEM}"

TEMP_MNT=$(mktemp -d)
TEMP_ESP_MNT=$(mktemp -d)
mkdir -p "${TEMP_MNT}"
enable_rw_mount "${DST_ROOTFS}"
sudo mount "${DST_ROOTFS}" "${TEMP_MNT}"
mkdir -p "${TEMP_ESP_MNT}"
sudo mount "${DST_ESP}" "${TEMP_ESP_MNT}"

# Modify the unverified usb template, which uses a default usb_disk of sdb3,
# for targets (e.g. x86 and amd64) that have syslinux installed.
SYSLINUX_USB_A_CONFIG="${TEMP_MNT}/boot/syslinux/usb.A.cfg"
if [ -e "${SYSLINUX_USB_A_CONFIG}" ]; then
  sudo sed -i -e 's/sdb3/sda3/g' "${SYSLINUX_USB_A_CONFIG}"
fi

# Add loading of cirrus fb module
if [ "${FLAGS_format}" = "qemu" ]; then
  sudo_clobber "${TEMP_MNT}/etc/init/cirrusfb.conf" <<END
start on starting boot-splash
task
exec modprobe cirrus
END
fi

# Unmount everything prior to building a final image
trap - INT TERM EXIT
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
trap detach_loopback INT TERM EXIT

# cros_make_image_bootable made the kernel in slot A recovery signed. We want
# it to be normally signed like the one in slot B, so copy B into A.
IMAGE_DEV=$(loopback_partscan "${TEMP_IMG}")
sudo cp ${IMAGE_DEV}p4 ${IMAGE_DEV}p2

trap - INT TERM EXIT
loopback_detach "${IMAGE_DEV}"

echo Creating final image
# Convert image to output format
if [ "${FLAGS_format}" = "virtualbox" -o "${FLAGS_format}" = "qemu" ]; then
  if [ "${FLAGS_format}" = "virtualbox" ]; then
    sudo VBoxManage convertdd "${TEMP_IMG}" "${FLAGS_to}/${FLAGS_vbox_disk}"
  else
    mv ${TEMP_IMG} ${FLAGS_to}/${DEFAULT_QEMU_IMAGE}
  fi
elif [ "${FLAGS_format}" = "vmware" ]; then
  qemu-img convert -f raw "${TEMP_IMG}" \
    -O vmdk "${FLAGS_to}/${FLAGS_vmdk}"
else
  die_notrace "Invalid format: ${FLAGS_format}"
fi

rm -rf "${TEMP_IMG}"

echo "Created image at ${FLAGS_to}"

# Generate the vmware config file
# A good reference doc: http://www.sanbarrow.com/vmx.html
VMX_CONFIG="#!/usr/bin/vmware
.encoding = \"UTF-8\"
config.version = \"8\"
virtualHW.version = \"4\"
memsize = \"${FLAGS_mem}\"
ide0:0.present = \"TRUE\"
ide0:0.fileName = \"${FLAGS_vmdk}\"
ethernet0.present = \"TRUE\"
usb.present = \"TRUE\"
sound.present = \"TRUE\"
sound.virtualDev = \"es1371\"
displayName = \"Chromium OS\"
guestOS = \"otherlinux\"
ethernet0.addressType = \"generated\"
floppy0.present = \"FALSE\""

if [[ "${FLAGS_make_vmx}" = "${FLAGS_TRUE}" ]]; then
  echo "${VMX_CONFIG}" > "${FLAGS_to}/${FLAGS_vmx}"
  echo "Wrote the following config to: ${FLAGS_to}/${FLAGS_vmx}"
  echo "${VMX_CONFIG}"
fi


if [ "${FLAGS_format}" == "qemu" ]; then
  echo "If you have qemu-kvm installed, you can start the image by:"
  echo "sudo kvm -m ${FLAGS_mem} -vga cirrus -pidfile /tmp/kvm.pid" \
       "-net nic,model=virtio -net user,hostfwd=tcp::9222-:22 \\"
  echo "-hda ${FLAGS_to}/${DEFAULT_QEMU_IMAGE}"
fi
