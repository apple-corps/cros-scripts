# Copyright 2018 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

restore_fs_contexts() {
  local board_root="$1"
  local rootfs="$2"

  # Restore the extended attributes of necessary files.
  local selinux_config="${board_root}/etc/selinux/config"
  if [[ -e "${selinux_config}" ]]; then
    info "Restoring SELinux file context."
    local selinux_type="$(source "${selinux_config}" && echo "${SELINUXTYPE}")"
    local file_contexts="${board_root}/etc/selinux/${selinux_type}/contexts/files/file_contexts"
    # If the selinux_config file exists, file_contexts must also.
    if ! [[ -e "${file_contexts}" ]]; then
      local err_msg="The SELinux config file exists at ${selinux_config}, "
      err_msg+="but an SELinux context file not found at ${file_contexts}."
      die_notrace "${err_msg}"
    fi
    sudo /sbin/setfiles -r "${rootfs}" "${file_contexts}" "${rootfs}"
  fi
}
