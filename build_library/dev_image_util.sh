# Copyright (c) 2012 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Shell function library for functions specific to creating dev
# images from base images.  The main function for export in this
# library is 'install_dev_packages'.


# Modifies an existing image to add development packages.
# Takes as an arg the name of the image to be created.
install_dev_packages() {
  local image_name=$1

  info "Adding developer packages to ${image_name}"

  trap "unmount_image ; delete_prompt" EXIT

  mount_image "${BUILD_DIR}/${image_name}" "${root_fs_dir}" \
    "${stateful_fs_dir}" "${esp_fs_dir}"

  # Determine the root dir for developer packages.
  local root_dev_dir="${root_fs_dir}/usr/local"

  # Symlink to /etc/{passwd,group,pam.d} from inside the developer package
  # root, so ebuilds can create users, groups, and set pam rules at build time.
  sudo mkdir -p "${root_dev_dir}/etc"
  sudo ln -s ../../../etc/passwd "${root_dev_dir}/etc/passwd"
  sudo ln -s ../../../etc/group "${root_dev_dir}/etc/group"
  sudo ln -s ../../../etc/pam.d "${root_dev_dir}/etc/pam.d"

  # Install dev-specific init scripts into / from chromeos-dev-root.
  emerge_to_image --root="${root_fs_dir}" chromeos-dev-root

  # Install developer packages described in chromeos-dev.
  emerge_to_image --root="${root_dev_dir}" chromeos-dev

  # Copy over the libc debug info so that gdb
  # works with threads and also for a better debugging experience.
  sudo mkdir -p "${root_fs_dir}/usr/local/usr/lib/debug"
  pbzip2 -dc --ignore-trailing-garbage=1 "${LIBC_PATH}" | \
    sudo tar xpf - -C "${root_fs_dir}/usr/local/usr/lib/debug" \
      ./usr/lib/debug/usr/${CHOST} --strip-components=6
  # Since gdb only looks in /usr/lib/debug, symlink the /usr/local
  # path so that it is found automatically.
  sudo ln -s /usr/local/usr/lib/debug "${root_fs_dir}/usr/lib/debug"

  # Install the bare necessary files so that the "emerge" command works
  sudo cp -a ${root_dev_dir}/share/portage ${root_fs_dir}/usr/share
  sudo sed -i s,/usr/bin/wget,wget, \
    ${root_fs_dir}/usr/share/portage/config/make.globals

  sudo mkdir -p ${root_fs_dir}/etc/make.profile

  # Re-run ldconfig to fix /etc/ld.so.cache.
  sudo ldconfig -r "${root_fs_dir}"

  # Additional changes to developer image.
  sudo mkdir -p "${root_fs_dir}/root"

  # Leave core files for developers to inspect.
  sudo touch "${root_fs_dir}/root/.leave_core"

  # This hack is only needed for devs who have old versions of glibc, which
  # filtered out ldd when cross-compiling.  TODO(davidjames): Remove this hack
  # once everybody has upgraded to a new version of glibc.
  if [[ ! -x "${root_fs_dir}/usr/bin/ldd" ]]; then
    sudo cp -a "$(which ldd)" "${root_fs_dir}/usr/bin"
  fi

  # If vim is installed, then a vi symlink would probably help.
  if [[ -x "${root_fs_dir}/usr/local/bin/vim" ]]; then
    sudo ln -sf vim "${root_fs_dir}/usr/local/bin/vi"
  fi

  # If pygtk is installed in stateful-dev, then install a path.
  local d
  for d in "${root_fs_dir}"/usr/local/lib/python*/site-packages/gtk-2.0; do
    if [[ -d ${d} ]]; then
      sudo_clobber "${d%/*}/pygtk.pth" <<<"gtk-2.0"
    fi
  done

  # File searches /usr/share by default, so add a wrapper script so it
  # can find the right path in /usr/local.
  local path="${root_fs_dir}/usr/local/bin/file"
  if [[ -x ${path} ]]; then
    sudo mv "${path}" "${path}.bin"
    sudo_clobber "${path}" <<EOF
#!/bin/sh
exec file.bin -m /usr/local/share/misc/magic.mgc "\$@"
EOF
    sudo chmod a+rx "${path}"
  fi

  # If python is installed on stateful-dev, fix python symlinks.
  # Really we need to do this in order to clean up the python-wrapper
  # mess from the eselect-python package.
  if [[ -n $(ls "${root_fs_dir}"/usr/local/bin/python* 2>/dev/null) ]]; then
    local pyver=$(ROOT="${root_fs_dir}/usr/local" eselect python show --ABI)
    if [[ -z ${pyver} ]]; then
      # TODO(build): Should be able to make this fatal once python-2.7 lands.
      pyver=$(readlink "${root_fs_dir}"/usr/local/bin/python2 | sed s:python::)
    fi
    local python_path="/usr/local/bin/python${pyver}"

    info "Fixing python symlinks for developer and test images."
    local cmds=() path python_paths=(
      /usr/{local/,}bin/python
      /usr/{local/,}bin/python${pyver:0:1}
      /usr/bin/python${pyver}
    )
    for path in "${python_paths[@]}"; do
      cmds+=(
        "ln -sfT '${python_path}' '${root_fs_dir}${path}'"
      )
    done
    sudo_multi "${cmds[@]}"
  fi

  # If bash is not installed on rootfs, we'll need a  bash symlink.
  # Otherwise, emerge won't work.
  if [[ ! -e "${root_fs_dir}"/bin/bash ]]; then
    info "Fixing bash path for developer and test images."
    sudo ln -sf /usr/local/bin/bash "${root_fs_dir}"/bin/bash
  fi

  info "Developer image built and stored at ${image_name}"

  cleanup_mounts
  trap - EXIT

  if [[ ${skip_kernelblock_install} -ne 1 ]]; then
    if should_build_image ${image_name}; then
      ${SCRIPTS_DIR}/bin/cros_make_image_bootable "${BUILD_DIR}" \
        ${image_name} --force_developer_mode
    fi
  fi
}
