# Copyright (c) 2012 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

CHROMEOS_MASTER_JSON_CONFIG_FILE="${BOARD_ROOT}/usr/share/chromeos-config/config.json"

check_full_disk() {
  local prev_ret=$?

  # Disable die on error.
  set +e

  # See if we ran out of space.  Only show if we errored out via a trap.
  if [[ ${prev_ret} -ne 0 ]]; then
    local df=$(df -B 1M "${root_fs_dir}")
    if [[ ${df} == *100%* ]]; then
      error "Here are the biggest [partially-]extracted files (by disk usage):"
      # Send final output to stderr to match `error` behavior.
      sudo find "${root_fs_dir}" -xdev -type f -printf '%b %P\n' | \
        awk '$1 > 16 { $1 = $1 * 512; print }' | sort -n | tail -100 1>&2
      error "Target image has run out of space:"
      error "${df}"
    fi
  fi

   # Turn die on error back on.
  set -e
}

zero_free_space() {
  local fs_mount_point=$1

  if ! mountpoint -q "${fs_mount_point}"; then
    info "Not zeroing freespace in ${fs_mount_point} since it isn't a mounted" \
        "filesystem. This is normal for squashfs and ubifs partitions."
    return 0
  fi

  info "Zeroing freespace in ${fs_mount_point}"
  sudo fstrim -v "${fs_mount_point}"
}

# create_dev_install_lists updates package lists used by
# chromeos-base/dev-install
create_dev_install_lists() {
  local root_fs_dir=$1

  info "Building dev-install package lists"

  local pkgs=(
    portage
    virtual/target-os
    virtual/target-os-dev
    virtual/target-os-test
  )

  local pkgs_out=$(mktemp -d)

  for pkg in "${pkgs[@]}" ; do
    (
      emerge-${BOARD} --color n --pretend --quiet --emptytree \
        --root-deps=rdeps ${pkg} | \
        egrep -o ' [[:alnum:]-]+/[^[:space:]/]+\b' | \
        tr -d ' ' | \
        sort > "${pkgs_out}/${pkg##*/}.packages"
      pipestatus=${PIPESTATUS[*]}
      [[ ${pipestatus// } -eq 0 ]] || touch "${pkgs_out}/FAILED"
    ) &
  done
  wait
  if [[ -e "${pkgs_out}/FAILED" ]]; then
    die_notrace "Generating lists failed"
  fi

  # bootstrap = portage - target-os
  comm -13 "${pkgs_out}/target-os.packages" \
    "${pkgs_out}/portage.packages" > "${pkgs_out}/bootstrap.packages"

  # chromeos-base = target-os + portage - virtuals
  sort -u "${pkgs_out}/target-os.packages" "${pkgs_out}/portage.packages" \
    | grep -v "virtual/" \
     > "${pkgs_out}/chromeos-base.packages"

  # package.installable = target-os-dev + target-os-test - target-os + virtuals
  comm -23 <(sort -u "${pkgs_out}/target-os-dev.packages" \
                     "${pkgs_out}/target-os-test.packages") \
    "${pkgs_out}/target-os.packages" \
    > "${pkgs_out}/package.installable"
  grep "virtual/" "${pkgs_out}/target-os.packages" | sort \
    >> "${pkgs_out}/package.installable"

  # Add dhcp to the list of packages installed since its installation will not
  # complete (can not add dhcp group since /etc is not writeable). Bootstrap it
  # instead.
  grep "net-misc/dhcp-" "${pkgs_out}/target-os-dev.packages" \
    >> "${pkgs_out}/chromeos-base.packages" || true
  grep "net-misc/dhcp-" "${pkgs_out}/target-os-dev.packages" \
    >> "${pkgs_out}/bootstrap.packages" || true

  # Copy the file over for chromite to process.
  sudo mkdir -p "${BOARD_ROOT}/build/dev-install"
  sudo mv "${pkgs_out}/package.installable" "${BOARD_ROOT}/build/dev-install/"

  sudo mkdir -p \
    "${root_fs_dir}/usr/share/dev-install/portage/make.profile/package.provided" \
    "${root_fs_dir}/usr/share/dev-install/rootfs.provided"
  sudo cp "${pkgs_out}/bootstrap.packages" \
    "${root_fs_dir}/usr/share/dev-install/"
  sudo cp "${pkgs_out}/chromeos-base.packages" \
    "${root_fs_dir}/usr/share/dev-install/rootfs.provided/"

  # Copy the toolchain settings which are fixed at build_image time.
  sudo cp "${BOARD_ROOT}/etc/portage/profile/package.provided" \
    "${root_fs_dir}/usr/share/dev-install/portage/make.profile/package.provided/"

  rm -r "${pkgs_out}"
}

install_libc() {
  root_fs_dir="$1"
  # We need to install libc manually from the cross toolchain.
  # TODO: Improve this? It would be ideal to use emerge to do this.
  libc_version="$(get_variable "${BOARD_ROOT}/${SYSROOT_SETTINGS_FILE}" \
    "LIBC_VERSION")"
  PKGDIR="/var/lib/portage/pkgs"
  local libc_atom="cross-${CHOST}/glibc-${libc_version}"
  LIBC_PATH="${PKGDIR}/${libc_atom}.tbz2"

  if [[ ! -e ${LIBC_PATH} ]]; then
    sudo emerge --nodeps -gf "=${libc_atom}"
  fi

  # Strip out files we don't need in the final image at runtime.
  local libc_excludes=(
    # Compile-time headers.
    'usr/include' 'sys-include'
    # Link-time objects.
    '*.[ao]'
    # Debug commands not used by normal runtime code.
    'usr/bin/'{getent,ldd}
    # LD_PRELOAD objects for debugging.
    'lib*/lib'{memusage,pcprofile,SegFault}.so 'usr/lib*/audit'
    # We only use files & dns with nsswitch, so throw away the others.
    'lib*/libnss_'{compat,db,hesiod,nis,nisplus}'*.so*'
    # This is only for very old packages which we don't have.
    'lib*/libBrokenLocale*.so*'
  )
  pbzip2 -dc --ignore-trailing-garbage=1 "${LIBC_PATH}" | \
    sudo tar xpf - -C "${root_fs_dir}" ./usr/${CHOST} \
      --strip-components=3 "${libc_excludes[@]/#/--exclude=}"
}

# Generates imageloader images containing demo mode resources.
# Generates two imageloader images under BUILD_DIR:
#   * standalone demo resources - archive containing demo resources to be added
#     to demo mode enabled release images. The demo mode resources will be added
#     to target image stateful partition during factory flow.
#   * test demo resources - demo resources that will be moved to the test images
#     stateful partition during mod_image_for_test.
generate_demo_mode_resources_images() {
  local demo_resources_src="$1"

  # Used to enable demo mode on test images, but with reduced set of demo apps.
  if [[ -d "${demo_resources_src}/test" ]]; then
    mkdir -p  "${BUILD_DIR}/test_demo_resources"
    generate_imageloader_image "0.0.1" \
        "${demo_resources_src}/test/image" \
        "${BUILD_DIR}/test_demo_resources"
  fi

  if [[ -d "${demo_resources_src}/standalone" ]]; then
    # Used to generate the demo resources archive to be bundled with release
    # images in factory - these are intended to contain the full set of demo
    # mode apps.
    generate_and_tar_imageloader_image "0.0.1" \
        "${demo_resources_src}/standalone/image" \
        "${BUILD_DIR}/demo_resources.tar.gz"
  fi
}

create_base_image() {
  local image_name=$1
  local rootfs_verification_enabled=$2
  local bootcache_enabled=$3
  local image_type="usb"

  if [[ "${FLAGS_disk_layout}" != "default" ]]; then
    image_type="${FLAGS_disk_layout}"
  else
    if should_build_image ${CHROMEOS_FACTORY_INSTALL_SHIM_NAME}; then
      image_type="factory_install"
    fi
  fi

  check_valid_layout "base"
  check_valid_layout "${image_type}"

  info "Using image type ${image_type}"
  get_disk_layout_path
  info "Using disk layout ${DISK_LAYOUT_PATH}"
  root_fs_dir="${BUILD_DIR}/rootfs"
  stateful_fs_dir="${BUILD_DIR}/stateful"
  esp_fs_dir="${BUILD_DIR}/esp"

  trap "delete_prompt" EXIT
  mkdir "${root_fs_dir}" "${stateful_fs_dir}" "${esp_fs_dir}"
  build_gpt_image "${BUILD_DIR}/${image_name}" "${image_type}"

  trap "check_full_disk ; unmount_image ; delete_prompt" EXIT
  mount_image "${BUILD_DIR}/${image_name}" "${root_fs_dir}" \
    "${stateful_fs_dir}" "${esp_fs_dir}"

  df -h "${root_fs_dir}"

  # Create symlinks so that /usr/local/usr based directories are symlinked to
  # /usr/local/ directories e.g. /usr/local/usr/bin -> /usr/local/bin, etc.
  setup_symlinks_on_root "." \
    "${stateful_fs_dir}/var_overlay" "${stateful_fs_dir}"

  # install libc
  install_libc "${root_fs_dir}"

  if should_build_image ${CHROMEOS_FACTORY_INSTALL_SHIM_NAME}; then
    # Install our custom factory install kernel with the appropriate use flags
    # to the image.
    emerge_custom_kernel "${root_fs_dir}"
  fi

  # We "emerge --root=${root_fs_dir} --root-deps=rdeps --usepkgonly" all of the
  # runtime packages for chrome os. This builds up a chrome os image from
  # binary packages with runtime dependencies only.  We use INSTALL_MASK to
  # trim the image size as much as possible.
  emerge_to_image --root="${root_fs_dir}" ${BASE_PACKAGE}

  #
  # Take a somewhat arbitrary number of post-emerge tasks and run them
  # in parallel to speed things up.
  #

  # Run depmod to recalculate the kernel module dependencies.
  run_depmod "${BOARD_ROOT}" "${root_fs_dir}"

  # Generate the license credits page for the packages installed on this
  # image in a location that will be used by Chrome.
  info "Generating license credits page. Time:"
  sudo mkdir -p "${root_fs_dir}/opt/google/chrome/resources"
  local license_path="${root_fs_dir}/opt/google/chrome/resources/about_os_credits.html"
  time sudo "${GCLIENT_ROOT}/chromite/licensing/licenses" \
    --board="${BOARD}" \
    --log-level error \
    --generate-licenses \
    --output "${license_path}"
  # Copy the license credits file to ${BUILD_DIR} so that is will be uploaded
  # as artifact later in ArchiveStage.
  if [[ -r "${license_path}" ]]; then
    cp "${license_path}" "${BUILD_DIR}/license_credits.html"
  fi

  # Remove unreferenced gconv charsets.
  # gconv charsets are .so modules loaded dynamically by iconv_open(3),
  # installed by glibc. Applications using them don't explicitly depend on them
  # and we don't known which ones will be used until all the applications are
  # installed. This script looks for the charset names on all the binaries
  # installed on the the ${root_fs_dir} and removes the unreferenced ones.
  sudo "${CHROMITE_BIN}/gconv_strip" "${root_fs_dir}"

  # Run ldconfig to create /etc/ld.so.cache.
  run_ldconfig "${root_fs_dir}"

  # Run udevadm to generate /etc/udev/hwdb.bin
  run_udevadm_hwdb "${root_fs_dir}"

  # File searches /usr/share even if it's installed in /usr/local.  Add a
  # symlink so it works in dev images & when using dev_install.  Unless it's
  # already installed.  https://crbug.com/210493
  if [[ ! -x "${root_fs_dir}/usr/bin/file" ]]; then
    sudo mkdir -p "${root_fs_dir}/usr/share/misc"
    sudo ln -s /usr/local/share/misc/magic.mgc \
      "${root_fs_dir}/usr/share/misc/magic.mgc"
  fi

  # Portage hardcodes /usr/share/portage internally even when it's installed
  # in /usr/local, so add a symlink as needed so it works in dev images & when
  # using dev_install.
  if [[ ! -d "${root_fs_dir}/usr/share/portage" ]]; then
    sudo ln -s /usr/local/share/portage "${root_fs_dir}/usr/share/portage"
  fi

  # Set /etc/lsb-release on the image.
  local official_flag=
  if [[ "${CHROMEOS_OFFICIAL:-0}" == "1" ]]; then
    official_flag="--official"
  fi

  # Get the build info of ARC if available.
  if type get_arc_build_info &>/dev/null; then
    # This will set CHROMEOS_ARC_*.
    get_arc_build_info "${root_fs_dir}"
  fi
  local arc_flags=()
  if [[ -n "${CHROMEOS_ARC_VERSION}" ]]; then
    arc_flags+=("--arc_version=${CHROMEOS_ARC_VERSION}")
  fi
  if [[ -n "${CHROMEOS_ARC_ANDROID_SDK_VERSION}" ]]; then
    arc_flags+=("--arc_android_sdk_version=${CHROMEOS_ARC_ANDROID_SDK_VERSION}")
  fi

  "${VBOOT_SIGNING_DIR}"/insert_container_publickey.sh \
    "${root_fs_dir}" \
    "${VBOOT_DEVKEYS_DIR}"/cros-oci-container-pub.pem

  local builder_path=
  if [[ -n "${FLAGS_builder_path}" ]]; then
    builder_path="--builder_path=${FLAGS_builder_path}"
  fi

  # For unified builds, include a list of models, e.g. with --models "reef pyro"
  local model_flags=()
  if [[ -f "${CHROMEOS_MASTER_JSON_CONFIG_FILE}" ]]; then
    models=$(grep '"name":' "${CHROMEOS_MASTER_JSON_CONFIG_FILE}" \
      | uniq | sed -e 's/.*"name": "\(.*\)".*/\1/' | tr '\n' ' ')
    [[ -n "${models}" ]] && model_flags+=( --models "${models%% }" )
  fi

  "${CHROMITE_BIN}/cros_set_lsb_release" \
    --sysroot="${root_fs_dir}" \
    --board="${BOARD}" \
    "${model_flags[@]}" \
    ${builder_path} \
    --keyset="devkeys" \
    --version_string="${CHROMEOS_VERSION_STRING}" \
    --auserver="${CHROMEOS_VERSION_AUSERVER}" \
    --devserver="${CHROMEOS_VERSION_DEVSERVER}" \
    ${official_flag} \
    --buildbot_build="${BUILDBOT_BUILD:-"N/A"}" \
    --track="${CHROMEOS_VERSION_TRACK:-"developer-build"}" \
    --branch_number="${CHROMEOS_BRANCH}" \
    --build_number="${CHROMEOS_BUILD}" \
    --chrome_milestone="${CHROME_BRANCH}" \
    --patch_number="${CHROMEOS_PATCH}" \
    "${arc_flags[@]}"

  # Set /etc/os-release on the image.
  # Note: fields in /etc/os-release can come from different places:
  # * /etc/os-release itself with docrashid
  # * /etc/os-release.d for fields created with do_osrelease_field
  sudo "${CHROMITE_BIN}/cros_generate_os_release" \
    --root="${root_fs_dir}" \
    --version="${CHROME_BRANCH}" \
    --build_id="${CHROMEOS_VERSION_STRING}"

  # Create the boot.desc file which stores the build-time configuration
  # information needed for making the image bootable after creation with
  # cros_make_image_bootable.
  create_boot_desc "${image_type}"

  # Write out the GPT creation script.
  # This MUST be done before writing bootloader templates else we'll break
  # the hash on the root FS.
  write_partition_script "${image_type}" \
    "${root_fs_dir}/${PARTITION_SCRIPT_PATH}"
  sudo chown root:root "${root_fs_dir}/${PARTITION_SCRIPT_PATH}"

  # Populates the root filesystem with legacy bootloader templates
  # appropriate for the platform.  The autoupdater and installer will
  # use those templates to update the legacy boot partition (12/ESP)
  # on update.
  # (This script does not populate vmlinuz.A and .B needed by syslinux.)
  # Factory install shims may be booted from USB by legacy EFI BIOS, which does
  # not support verified boot yet (see create_legacy_bootloader_templates.sh)
  # so rootfs verification is disabled if we are building with --factory_install
  local enable_rootfs_verification=
  if [[ ${rootfs_verification_enabled} -eq ${FLAGS_TRUE} ]]; then
    enable_rootfs_verification="--enable_rootfs_verification"
  fi
  local enable_bootcache=
  if [[ ${bootcache_enabled} -eq ${FLAGS_TRUE} ]]; then
    enable_bootcache="--enable_bootcache"
  fi

  ${BUILD_LIBRARY_DIR}/create_legacy_bootloader_templates.sh \
    --arch=${ARCH} \
    --board=${BOARD} \
    --image_type="${image_type}" \
    --to="${root_fs_dir}"/boot \
    --boot_args="${FLAGS_boot_args}" \
    --enable_serial="${FLAGS_enable_serial}" \
    --loglevel="${FLAGS_loglevel}" \
      ${enable_rootfs_verification} \
      ${enable_bootcache}

  # Run board-specific build image function, if available.
  if type board_finalize_base_image &>/dev/null; then
    board_finalize_base_image
  fi

  generate_demo_mode_resources_images \
      "${root_fs_dir}/build/rootfs/chromeos-assets/demo_resources"

  # Clean up symlinks so they work on a running target rooted at "/".
  # Here development packages are rooted at /usr/local.  However, do not
  # create /usr/local or /var on host (already exist on target).
  setup_symlinks_on_root . "/var" "${stateful_fs_dir}"

  # Our masking of files will implicitly leave behind a bunch of empty
  # dirs.  We can't differentiate between empty dirs we want and empty
  # dirs we don't care about, so just prune ones we know are OK.
  sudo find "${root_fs_dir}/usr/include" -depth -type d -exec rmdir {} + \
    2>/dev/null || :

  setup_etc_shadow "${root_fs_dir}"

  if [[ -d "${root_fs_dir}/usr/share/dev-install" ]]; then
    # Create a package for the dev-only files installed in /usr/local
    # of a base image. This package can later be downloaded with
    # dev_install running from a base image.
    # Files installed in /usr/local/var were already installed in
    # stateful since we created a symlink for those. We ignore the
    # symlink in this package since the directory /usr/local/var
    # exists in the target image when dev_install runs.
    # TODO(deymo): Move dev-only-extras.tbz2 outside packages. See
    # crbug.com/448178 for details.
    sudo tar -cf "${BOARD_ROOT}/packages/dev-only-extras.tbz2" -I pbzip2 \
      --exclude=var -C "${root_fs_dir}/usr/local" .

    create_dev_install_lists "${root_fs_dir}"
  fi

  restore_fs_contexts "${BOARD_ROOT}" "${root_fs_dir}" "${stateful_fs_dir}"

   # Move the bootable kernel images out of the /boot directory to save
  # space.  We put them in the $BUILD_DIR so they can be used to write
  # the bootable partitions later.
  mkdir "${BUILD_DIR}/boot_images"

  # We either copy or move vmlinuz depending on whether it should be included
  # in the final built image.  Boards that boot with legacy bioses
  # need the kernel on the boot image, boards with coreboot/depthcharge
  # boot from a boot partition.
  if has "include_vmlinuz" "$(portageq-${FLAGS_board} envvar USE)"; then
    cpmv="cp"
  else
    cpmv="mv"
  fi
  [ -e "${root_fs_dir}"/boot/Image-* ] && \
    sudo "${cpmv}" "${root_fs_dir}"/boot/Image-* "${BUILD_DIR}/boot_images"
  [ -L "${root_fs_dir}"/boot/zImage-* ] && \
    sudo "${cpmv}" "${root_fs_dir}"/boot/zImage-* "${BUILD_DIR}/boot_images"
  [ -e "${root_fs_dir}"/boot/vmlinuz-* ] && \
    sudo "${cpmv}" "${root_fs_dir}"/boot/vmlinuz-* "${BUILD_DIR}/boot_images"
  [ -L "${root_fs_dir}"/boot/vmlinuz ] && \
    sudo "${cpmv}" "${root_fs_dir}"/boot/vmlinuz "${BUILD_DIR}/boot_images"
  [ -L "${root_fs_dir}"/boot/vmlinux.uimg ] && \
    sudo "${cpmv}" "${root_fs_dir}"/boot/vmlinux.uimg \
        "${BUILD_DIR}/boot_images"

# Zero rootfs free space to make it more compressible so auto-update
  # payloads become smaller.
  zero_free_space "${root_fs_dir}"

  unmount_image
  trap - EXIT

  USE_DEV_KEYS=
  if should_build_image ${CHROMEOS_FACTORY_INSTALL_SHIM_NAME}; then
    USE_DEV_KEYS="--use_dev_keys"
  fi

  if [[ ${skip_kernelblock_install} -ne 1 ]]; then
    # Place flags before positional args.
    ${SCRIPTS_DIR}/bin/cros_make_image_bootable "${BUILD_DIR}" \
      ${image_name} ${USE_DEV_KEYS} --adjust_part="${FLAGS_adjust_part}"
  fi
}
