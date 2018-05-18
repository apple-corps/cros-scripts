#!/bin/bash
# Copyright 2018 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to check that the auto-generated json file used for code reviews only
# matches the current output of the source yaml file for cros_config.

# Loads script libraries.
SCRIPT_ROOT=$(dirname "$(readlink -f "$0")")
. "${SCRIPT_ROOT}/common.sh" || exit 1

# Script must be run inside the chroot.
restart_in_chroot_if_needed "$@"

main() {
  local yaml_files_changed=$(echo "${PRESUBMIT_FILES}" \
    | grep chromeos-config-bsp.*yaml)
  [[ -z "${yaml_files_changed}" ]] && exit 0
  local build=$(pwd | sed 's#.*overlay-\([^-/]*\).*#\1#')
  [[ -z "${build}" ]] && exit 0
  local src_root="../../private-overlays/overlay-${build}-private/chromeos-base"
  local gend_file="files/model_auto_generated.json"

  local generated="/build/${build}/usr/share/chromeos-config/yaml/config.yaml"
  local source_ctl_file="${src_root}/chromeos-config-bsp-${build}-private/${gend_file}"
  if [[ ! -f "${source_ctl_file}" ]]; then
    src_root="~/trunk/src/overlays/overlay-${build}/chromeos-base"
    source_ctl_file="${src_root}/chromeos-config-bsp/${gend_file}"
  fi

  if [[ -f "${source_ctl_file}" ]]; then
    if [[ ! -f "${generated}" ]]; then
      emerge-${build} chromeos-config-bsp chromeos-config
    fi
    if [[ ! -f "${generated}" ]]; then
      warn "Failed to generate ${generated} via emerge-${build} "\
        "chromeos-config-bsp chromeos-config."
      exit 1
    fi
    local generated_cksum="$(cksum "${generated}" | cut -d ' ' -f 1)"
    local source_ctl_cksum="$(cksum "${source_ctl_file}" | cut -d ' ' -f 1)"
    if [[ "${generated_cksum}" -ne "${source_ctl_cksum}" ]]; then
      cp "${generated}" "${source_ctl_file}"
      warn "YAML has been updated, but JSON is out of date.\n"\
        "Updating ... please add to your current patchset.\n"\
        "git add ${source_ctl_file}"
      exit 1
    fi
    info "Successfully verified ${generated} matches ${source_ctl_file}"
  fi
}

main "$@"
