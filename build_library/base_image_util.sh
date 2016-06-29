# Copyright (c) 2012 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

. "${SRC_ROOT}/platform/dev/toolchain_utils.sh" || exit 1

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
  # dd is a silly thing and will produce a "No space left on device" message
  # that cannot be turned off and is confusing to unsuspecting victims.
  info "${fs_mount_point}/filler"
  ( sudo dd if=/dev/zero of="${fs_mount_point}/filler" bs=4096 conv=fdatasync \
      status=noxfer || true ) 2>&1 | grep -v "No space left on device"
  sudo rm "${fs_mount_point}/filler"
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
    emerge-${BOARD} --pretend --quiet --emptytree \
      --root-deps=rdeps ${pkg} | \
      egrep -o ' [[:alnum:]-]+/[^[:space:]/]+\b' | \
      tr -d ' ' | \
      sort > "${pkgs_out}/${pkg##*/}.packages"
    local _pipestatus=${PIPESTATUS[*]}
    [[ ${_pipestatus// } -eq 0 ]] || error "\`emerge-${BOARD} ${pkg}\` failed"
  done

  # bootstrap = portage - target-os
  comm -13 "${pkgs_out}/target-os.packages" \
    "${pkgs_out}/portage.packages" > "${pkgs_out}/bootstrap.packages"

  # chromeos-base = target-os + portage - virtuals
  sort -u "${pkgs_out}/target-os.packages" "${pkgs_out}/portage.packages" \
    | grep -v "virtual/" \
     > "${pkgs_out}/chromeos-base.packages"

  # package.installable = target-os-dev + target-os-test - target-os + virtuals
  comm -23 <(cat "${pkgs_out}/target-os-dev.packages" \
                 "${pkgs_out}/target-os-test.packages" | sort) \
    "${pkgs_out}/target-os.packages" \
    > "${pkgs_out}/package.installable"
  grep "virtual/" "${pkgs_out}/target-os.packages" \
    >> "${pkgs_out}/package.installable"

  # Add dhcp to the list of packages installed since its installation will not
  # complete (can not add dhcp group since /etc is not writeable). Bootstrap it
  # instead.
  grep "net-misc/dhcp-" "${pkgs_out}/target-os-dev.packages" \
    >> "${pkgs_out}/chromeos-base.packages" || true
  grep "net-misc/dhcp-" "${pkgs_out}/target-os-dev.packages" \
    >> "${pkgs_out}/bootstrap.packages" || true

  sudo mkdir -p \
    "${root_fs_dir}/usr/share/dev-install/portage/make.profile/package.provided"
  sudo cp "${pkgs_out}/bootstrap.packages" \
    "${root_fs_dir}/usr/share/dev-install/portage"
  sudo cp "${pkgs_out}/package.installable" \
    "${root_fs_dir}/usr/share/dev-install/portage/make.profile"
  sudo cp "${pkgs_out}/chromeos-base.packages" \
    "${root_fs_dir}/usr/share/dev-install/portage/make.profile/package.provided"

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
  check_valid_layout ${image_type}

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

  # Generate the license credits page for the packages installed on this
  # image in a location that will be used by Chrome.
  info "Generating license credits page. Time:"
  sudo mkdir -p "${root_fs_dir}/opt/google/chrome/resources"
  time sudo "${GCLIENT_ROOT}/chromite/licensing/licenses" \
    --board="${BOARD}" \
    --log-level error \
    --generate-licenses \
    --output "${root_fs_dir}/opt/google/chrome/resources/about_os_credits.html"

  # Remove unreferenced gconv charsets.
  # gconv charsets are .so modules loaded dynamically by iconv_open(3),
  # installed by glibc. Applications using them don't explicitly depend on them
  # and we don't known which ones will be used until all the applications are
  # installed. This script looks for the charset names on all the binaries
  # installed on the the ${root_fs_dir} and removes the unreferenced ones.
  sudo "${GCLIENT_ROOT}/chromite/bin/gconv_strip" "${root_fs_dir}"

  # Run ldconfig to create /etc/ld.so.cache.
  run_ldconfig "${root_fs_dir}"

  # Set /etc/lsb-release on the image.
  local official_flag=
  if [[ "${CHROMEOS_OFFICIAL:-0}" == "1" ]]; then
    official_flag="--official"
  fi

  # Get the version of ARC if available
  if type set_arc_version &>/dev/null; then
    set_arc_version
  fi
  local arc_version=
  if [[ -n "${CHROMEOS_ARC_VERSION}" ]]; then
    arc_version="--arc_version=${CHROMEOS_ARC_VERSION}"
  fi

  "${GCLIENT_ROOT}/chromite/bin/cros_set_lsb_release" \
    --sysroot="${root_fs_dir}" \
    --board="${BOARD}" \
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
    ${arc_version}

  # Set /etc/os-release on the image.
  # Note: fields in /etc/os-release can come from different places:
  # * /etc/os-release itself with docrashid
  # * /etc/os-release.d for fields created with do_osrelease_field
  sudo "${GCLIENT_ROOT}/chromite/bin/cros_generate_os_release" \
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

  # Don't test the factory install shim
  if ! should_build_image ${CHROMEOS_FACTORY_INSTALL_SHIM_NAME}; then
    if [[ ${skip_test_image_content} -ne 1 ]]; then
      # Check that the image has been correctly created.
      test_image_content "$root_fs_dir"
    fi
  fi

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

  # Restore the extended attributes of necessary files.
  local selinux_config="${BOARD_ROOT}/etc/selinux/config"
  if [[ -e "${selinux_config}" ]]; then
    local selinux_type="$(source "${selinux_config}" && echo "${SELINUXTYPE}")"
    local file_contexts="${BOARD_ROOT}/etc/selinux/${selinux_type}/contexts/files/file_contexts"
    # If the selinux_config file exists, file_contexts must also.
    if ! [[ -e "${file_contexts}" ]]; then
      local err_msg="The SELinux config file exists at ${selinux_config}, "
      err_msg+="but an SELinux context file not found at ${file_contexts}."
      die_notrace "${err_msg}"
    fi
    sudo /sbin/setfiles -r "${root_fs_dir}" "${file_contexts}" "${root_fs_dir}"
  fi

  # Zero rootfs free space to make it more compressible so auto-update
  # payloads become smaller
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
