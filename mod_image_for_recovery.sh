#!/bin/bash

# Copyright (c) 2011 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# This script modifies a base image to act as a recovery installer.
# If no kernel image is supplied, it will build a devkeys signed recovery
# kernel.  Alternatively, a signed recovery kernel can be used to
# create a Chromium OS recovery image.

SCRIPT_ROOT=$(dirname $(readlink -f "$0"))
. "${SCRIPT_ROOT}/build_library/build_common.sh" || exit 1
. "${SCRIPT_ROOT}/build_library/disk_layout_util.sh" || exit 1

# Default recovery kernel name.
RECOVERY_KERNEL_NAME=recovery_vmlinuz.image

DEFINE_string board "$DEFAULT_BOARD" \
  "board for which the image was built" \
  b
DEFINE_integer statefulfs_sectors 4096 \
  "number of free sectors in stateful filesystem when minimizing"
DEFINE_string kernel_image "" \
  "path to a pre-built recovery kernel"
DEFINE_string kernel_outfile "" \
  "emit recovery kernel to path/file ($RECOVERY_KERNEL_NAME if empty)"
DEFINE_string image "" \
  "source image to use ($CHROMEOS_IMAGE_NAME if empty)"
DEFINE_string to "" \
  "emit recovery image to path/file ($CHROMEOS_RECOVERY_IMAGE_NAME if empty)"
DEFINE_boolean kernel_image_only $FLAGS_FALSE \
  "only emit recovery kernel"
DEFINE_boolean sync_keys $FLAGS_TRUE \
  "update install kernel with the vblock from stateful"
DEFINE_boolean minimize_image $FLAGS_TRUE \
  "create a minimized recovery image from source image"
DEFINE_boolean modify_in_place $FLAGS_FALSE \
  "modify source image in place"
DEFINE_integer jobs -1 \
  "how many packages to build in parallel at maximum" \
  j
DEFINE_string build_root "/build" \
  "root location for board sysroots"
DEFINE_string keys_dir "${VBOOT_DEVKEYS_DIR}" \
  "directory containing the signing keys"
DEFINE_boolean verbose $FLAGS_FALSE \
  "log all commands to stdout" v
DEFINE_boolean decrypt_stateful $FLAGS_FALSE \
  "request a decryption of the stateful partition (implies --nominimize_image)"

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# Only now can we die on error.  shflags functions leak non-zero error codes,
# so will die prematurely if 'switch_to_strict_mode' is specified before now.
switch_to_strict_mode

if [ $FLAGS_verbose -eq $FLAGS_TRUE ]; then
  # Make debugging with -v easy.
  set -x
fi

# We need space for copying decrypted files to the recovery image, so force
# --nominimize_image when using --decrypt_stateful.
if [ $FLAGS_decrypt_stateful -eq $FLAGS_TRUE ]; then
  FLAGS_minimize_image=$FLAGS_FALSE
fi

# Load board options.
. "${BUILD_LIBRARY_DIR}/board_options.sh" || exit 1
EMERGE_BOARD_CMD="emerge-$BOARD"

# Files to preserve from original stateful, if minimize_image is true.
# If minimize_image is false, everything is always preserved.
WHITELIST="vmlinuz_hd.vblock unencrypted/import_extensions"

get_install_vblock() {
  # If it exists, we need to copy the vblock over to stateful
  # This is the real vblock and not the recovery vblock.
  local stateful_offset=$(partoffset "$FLAGS_image" ${PARTITION_NUM_STATE})
  local stateful_mnt=$(mktemp -d)
  local out=$(mktemp)

  set +e
  sudo mount -o ro,loop,offset=$((stateful_offset * 512)) \
             "$FLAGS_image" $stateful_mnt
  sudo cp "$stateful_mnt/vmlinuz_hd.vblock"  "$out"
  sudo chown $USER "$out"

  safe_umount "$stateful_mnt"
  rmdir "$stateful_mnt"
  switch_to_strict_mode
  echo "$out"
}

create_recovery_kernel_image() {
  local sysroot="$FACTORY_ROOT"
  local vmlinuz="$sysroot/boot/vmlinuz"
  local root_offset=$(partoffset "${RECOVERY_IMAGE}" ${PARTITION_NUM_ROOT_A})
  local root_size=$(partsize "${RECOVERY_IMAGE}" ${PARTITION_NUM_ROOT_A})

  local enable_rootfs_verification_flag=--noenable_rootfs_verification
  if grep -q enable_rootfs_verification "${IMAGE_DIR}/boot.desc"; then
    enable_rootfs_verification_flag=--enable_rootfs_verification
  fi

  # Tie the installed recovery kernel to the final kernel.  If we don't
  # do this, a normal recovery image could be used to drop an unsigned
  # kernel on without a key-change check.
  # Doing this here means that the kernel and initramfs creation can
  # be done independently from the image to be modified as long as the
  # chromeos-recovery interfaces are the same.  It allows for the signer
  # to just compute the new hash and update the kernel command line during
  # recovery image generation.  (Alternately, it means an image can be created,
  # modified for recovery, then passed to a signer which can then sign both
  # partitions appropriately without needing any external dependencies.)
  local kern_offset=$(partoffset "${RECOVERY_IMAGE}" ${PARTITION_NUM_KERN_A})
  local kern_size=$(partsize "${RECOVERY_IMAGE}" ${PARTITION_NUM_KERN_A})
  local kern_tmp=$(mktemp)
  local kern_hash=

  dd if="${RECOVERY_IMAGE}" bs=512 count=$kern_size \
     skip=$kern_offset of="$kern_tmp" 1>&2
  # We're going to use the real signing block.
  if [ $FLAGS_sync_keys -eq $FLAGS_TRUE ]; then
    dd if="$INSTALL_VBLOCK" of="$kern_tmp" conv=notrunc 1>&2
  fi
  local kern_hash=$(sha1sum "$kern_tmp" | cut -f1 -d' ')
  rm "$kern_tmp"

  # TODO(wad) add FLAGS_boot_args support too.
  ${SCRIPTS_DIR}/build_kernel_image.sh \
    --board="${FLAGS_board}" \
    --arch="${ARCH}" \
    --to="$RECOVERY_KERNEL_IMAGE" \
    --vmlinuz="$vmlinuz" \
    --working_dir="${IMAGE_DIR}" \
    --boot_args="noinitrd panic=60 cros_recovery kern_b_hash=$kern_hash" \
    --keep_work \
    --keys_dir="${FLAGS_keys_dir}" \
    ${enable_rootfs_verification_flag} \
    --public="recovery_key.vbpubk" \
    --private="recovery_kernel_data_key.vbprivk" \
    --keyblock="recovery_kernel.keyblock" 1>&2 || failboat "build_kernel_image"
  #sudo mount | sed 's/^/16651 /'
  #sudo losetup -a | sed 's/^/16651 /'
  trap - RETURN

  # Update the EFI System Partition configuration so that the kern_hash check
  # passes.
  local block_size=$(get_block_size)

  local efi_offset=$(partoffset "${RECOVERY_IMAGE}" ${PARTITION_NUM_EFI_SYSTEM})
  local efi_size=$(partsize "${RECOVERY_IMAGE}" ${PARTITION_NUM_EFI_SYSTEM})
  local efi_offset_bytes=$(( $efi_offset * $block_size ))
  local efi_size_bytes=$(( $efi_size * $block_size ))

  if [[ ${efi_size_bytes} -ne 0 ]]; then
    local efi_dir=$(mktemp -d)
    sudo mount -o loop,offset=${efi_offset_bytes},sizelimit=${efi_size_bytes} \
      "${RECOVERY_IMAGE}" "${efi_dir}"

    sudo sed  -i -e "s/cros_legacy/cros_legacy kern_b_hash=$kern_hash/g" \
      "$efi_dir/syslinux/usb.A.cfg" || true
    # This will leave the hash in the kernel for all boots, but that should be
    # safe.
    sudo sed  -i -e "s/cros_efi/cros_efi kern_b_hash=$kern_hash/g" \
      "$efi_dir/efi/boot/grub.cfg" || true
    safe_umount "$efi_dir"
    rmdir "$efi_dir"
  fi

  trap - EXIT
}

install_recovery_kernel() {
  local kern_a_offset=$(partoffset "$RECOVERY_IMAGE" ${PARTITION_NUM_KERN_A})
  local kern_a_size=$(partsize "$RECOVERY_IMAGE" ${PARTITION_NUM_KERN_A})
  local kern_b_offset=$(partoffset "$RECOVERY_IMAGE" ${PARTITION_NUM_KERN_B})
  local kern_b_size=$(partsize "$RECOVERY_IMAGE" ${PARTITION_NUM_KERN_B})

  if [ $kern_b_size -eq 1 ]; then
    echo "Image was created with no KERN-B partition reserved!" 1>&2
    echo "Cannot proceed." 1>&2
    return 1
  fi

  # Backup original kernel to KERN-B
  dd if="$RECOVERY_IMAGE" of="$RECOVERY_IMAGE" bs=512 \
     count=$kern_a_size \
     skip=$kern_a_offset \
     seek=$kern_b_offset \
     conv=notrunc

  # We're going to use the real signing block.
  if [ $FLAGS_sync_keys -eq $FLAGS_TRUE ]; then
    dd if="$INSTALL_VBLOCK" of="$RECOVERY_IMAGE" bs=512 \
       seek=$kern_b_offset \
       conv=notrunc
  fi

  # Install the recovery kernel as primary.
  dd if="$RECOVERY_KERNEL_IMAGE" of="$RECOVERY_IMAGE" bs=512 \
     seek=$kern_a_offset \
     count=$kern_a_size \
     conv=notrunc

  # Set the 'Success' flag to 1 (to prevent the firmware from updating
  # the 'Tries' flag).
  sudo $GPT add -i ${PARTITION_NUM_KERN_A} -S 1 "$RECOVERY_IMAGE"

  # Repeat for the legacy bioses.
  # Replace vmlinuz.A with the recovery version we built.
  # TODO(wad): Extract the $RECOVERY_KERNEL_IMAGE and grab vmlinuz from there.
  local sysroot="$FACTORY_ROOT"
  local vmlinuz="$sysroot/boot/vmlinuz"
  local failed=0

  if [ "$ARCH" = "x86" ]; then
    # There is no syslinux on ARM, so this copy only makes sense for x86.
    set +e
    local esp_offset=$(partoffset "$RECOVERY_IMAGE" ${PARTITION_NUM_EFI_SYSTEM})
    local esp_mnt=$(mktemp -d)
    sudo mount -o loop,offset=$((esp_offset * 512)) "$RECOVERY_IMAGE" "$esp_mnt"
    sudo cp "$vmlinuz" "$esp_mnt/syslinux/vmlinuz.A" || failed=1
    safe_umount "$esp_mnt"
    rmdir "$esp_mnt"
    switch_to_strict_mode
  fi

  if [ $failed -eq 1 ]; then
    echo "Failed to copy recovery kernel to ESP"
    return 1
  fi
  return 0
}

find_sectors_needed() {
  # Find the minimum disk sectors needed for a file system to hold a list of
  # files or directories.
  local base_dir="$1"
  local file_list="$2"

  # Calculate space needed by the files we'll be copying, plus
  # a reservation for recovery logs or other runtime data.
  local in_use=$(cd "${base_dir}"
                 du -s -B512 ${file_list} |
                   awk '{ sum += $1 } END { print sum }')
  local sectors_needed=$(( in_use + FLAGS_statefulfs_sectors ))

  # Add 10% overhead for the FS, rounded down.  There's some
  # empirical justification for this number, but at heart, it's a
  # wild guess.
  echo $(( sectors_needed + sectors_needed / 10 ))
}

maybe_resize_stateful() {
  # If we're not minimizing, then just copy and go.
  if [ $FLAGS_minimize_image -eq $FLAGS_FALSE ]; then
    return 0
  fi

  local old_stateful_offset old_stateful_mnt sectors_needed
  local small_stateful new_stateful_mnt

  # Mount the old stateful partition so we can copy selected values
  # off of it.
  old_stateful_offset=$(partoffset "$FLAGS_image" ${PARTITION_NUM_STATE})
  old_stateful_mnt=$(mktemp -d)

  sudo mount -o ro,loop,offset=$((old_stateful_offset * 512)) \
    "$FLAGS_image" $old_stateful_mnt

  sectors_needed=$(find_sectors_needed "${old_stateful_mnt}" "${WHITELIST}")

  # Rebuild the image with stateful partition sized by sectors_needed.
  small_stateful=$(mktemp)
  dd if=/dev/zero of="$small_stateful" bs=512 \
    count="${sectors_needed}" 1>&2
  trap "rm $small_stateful" RETURN
  # Don't bother with ext3 for such a small image.
  /sbin/mkfs.ext2 -F -b 4096 "$small_stateful" 1>&2

  # If it exists, we need to copy the vblock over to stateful
  # This is the real vblock and not the recovery vblock.
  new_stateful_mnt=$(mktemp -d)

  sudo mount -o loop $small_stateful $new_stateful_mnt

  # Create the directories that are going to be needed below. With correct
  # permissions and ownership.
  sudo mkdir --mode=755 "${new_stateful_mnt}/unencrypted"

  # Copy over any files that need to be preserved.
  for name in ${WHITELIST}; do
    if [ -e "${old_stateful_mnt}/${name}" ]; then
      sudo cp -a "${old_stateful_mnt}/${name}" "${new_stateful_mnt}/${name}"
    fi
  done

  # Cleanup everything.
  safe_umount "$old_stateful_mnt"
  safe_umount "$new_stateful_mnt"
  rmdir "$old_stateful_mnt"
  rmdir "$new_stateful_mnt"
  switch_to_strict_mode

  # Create a recovery image of the right size
  # TODO(wad) Make the developer script case create a custom GPT with
  # just the kernel image and stateful.
  update_partition_table "${FLAGS_image}" "$small_stateful" \
                         "${sectors_needed}" \
                         "${RECOVERY_IMAGE}" 1>&2
  return 0
}

cleanup() {
  set +e
  if [ "$FLAGS_image" != "$RECOVERY_IMAGE" ]; then
    rm "$RECOVERY_IMAGE"
  fi
  rm "$INSTALL_VBLOCK"
}


# Main process begins here.
set -u

# No image was provided, use standard latest image path.
if [ -z "$FLAGS_image" ]; then
  DEFAULT_IMAGE_DIR="$($SCRIPT_ROOT/get_latest_image.sh --board=$BOARD)"
  FLAGS_image="$DEFAULT_IMAGE_DIR/$CHROMEOS_IMAGE_NAME"
fi

# Turn path into an absolute path.
FLAGS_image=$(readlink -f "$FLAGS_image")

# Abort early if we can't find the image.
if [ ! -f "$FLAGS_image" ]; then
  die_notrace "Image not found: $FLAGS_image"
fi

IMAGE_DIR="$(dirname "$FLAGS_image")"
IMAGE_NAME="$(basename "$FLAGS_image")"
RECOVERY_IMAGE="${FLAGS_to:-$IMAGE_DIR/$CHROMEOS_RECOVERY_IMAGE_NAME}"
RECOVERY_KERNEL_IMAGE=\
"${FLAGS_kernel_outfile:-$IMAGE_DIR/$RECOVERY_KERNEL_NAME}"
STATEFUL_DIR="$IMAGE_DIR/stateful_partition"
SCRIPTS_DIR=${SCRIPT_ROOT}

# Mounts gpt image and sets up var, /usr/local and symlinks.
# If there's a dev payload, mount stateful
#  offset=$(partoffset "${FLAGS_from}/${filename}" 1)
#  sudo mount ${ro_flag} -o loop,offset=$(( offset * 512 )) \
#    "${FLAGS_from}/${filename}" "${FLAGS_stateful_mountpt}"
# If not, resize stateful to 1 sector.
#

if [ $FLAGS_kernel_image_only -eq $FLAGS_TRUE -a \
     -n "$FLAGS_kernel_image" ]; then
  die_notrace "Cannot use --kernel_image_only with --kernel_image"
fi

if [ $FLAGS_modify_in_place -eq $FLAGS_TRUE ]; then
  if [ $FLAGS_minimize_image -eq $FLAGS_TRUE ]; then
    die_notrace "Cannot use --modify_in_place and --minimize_image together."
  fi
  RECOVERY_IMAGE="${FLAGS_image}"
else
  cp "${FLAGS_image}" "${RECOVERY_IMAGE}"
fi

echo "Creating recovery image from ${FLAGS_image}"

INSTALL_VBLOCK=$(get_install_vblock)
if [ -z "$INSTALL_VBLOCK" ]; then
  die "Could not copy the vblock from stateful."
fi

# Build the recovery kernel.
FACTORY_ROOT="${BOARD_ROOT}/factory-root"
RECOVERY_KERNEL_FLAGS="fbconsole vtconsole recovery_ramfs tpm i2cdev vfat"
USE="${RECOVERY_KERNEL_FLAGS}" emerge_custom_kernel "$FACTORY_ROOT" ||
  failboat "Cannot emerge custom kernel"

if [ -z "$FLAGS_kernel_image" ]; then
  create_recovery_kernel_image
  echo "Recovery kernel created at $RECOVERY_KERNEL_IMAGE"
else
  RECOVERY_KERNEL_IMAGE="$FLAGS_kernel_image"
fi

if [ $FLAGS_kernel_image_only -eq $FLAGS_TRUE ]; then
  echo "Kernel emitted. Stopping there."
  rm "$INSTALL_VBLOCK"
  exit 0
fi

trap cleanup EXIT

maybe_resize_stateful  # Also copies the image if needed.

if [ $FLAGS_decrypt_stateful -eq $FLAGS_TRUE ]; then
  stateful_mnt=$(mktemp -d)
  offset=$(partoffset "${RECOVERY_IMAGE}" ${PARTITION_NUM_STATE})
  sudo mount -o loop,offset=$(( offset * 512 )) \
    "${RECOVERY_IMAGE}" "${stateful_mnt}"
  echo -n "1" | sudo tee "${stateful_mnt}"/decrypt_stateful >/dev/null
  sudo umount "$stateful_mnt"
  rmdir "$stateful_mnt"
fi

install_recovery_kernel

okboat

echo "Recovery image created at $RECOVERY_IMAGE"
print_time_elapsed
trap - EXIT
