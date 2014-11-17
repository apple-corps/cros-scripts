#!/bin/bash
# Copyright (c) 2014 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# make_factory_toolkit.sh --board=[board]
#
# This script builds a factory toolkit, which is a self-extracting shellball,
# and can be installed onto a device running test image.

SCRIPT_ROOT=$(dirname "$(readlink -f "$0")")
. "${SCRIPT_ROOT}/common.sh" || exit 1

# Script must be run inside the chroot.
restart_in_chroot_if_needed "$@"

DEFINE_string board "${DEFAULT_BOARD}" \
  "The board to build a factory toolkit for."
DEFINE_string output_dir "" "Path to the folder to store the factory toolkit."
DEFINE_string version "" \
  "The version tag to be included in the identification string."
DEFINE_boolean host_based "${FLAGS_TRUE}" \
  "Whether to build a host-based toolkit."

cleanup() {
  sudo rm -rf "${temp_pack_root}"
}

main() {
  # Parse command line.
  FLAGS "$@" || exit 1
  eval set -- "${FLAGS_ARGV}"

  switch_to_strict_mode

  trap cleanup EXIT

  # Must specify a board
  if [[ -z "${FLAGS_board}" ]]; then
    die "No board specified. Use the --board option."
  fi

  local default_dir="${CHROOT_TRUNK_DIR}/src/build/images/${FLAGS_board}/latest"
  if [[ -n "${FLAGS_output_dir}" ]]; then
    local output_dir="${FLAGS_output_dir}"
  else
    local output_dir="${default_dir}"
  fi

  echo "Building into directory ${output_dir}"
  if [[ ! -d "${output_dir}" ]]; then
    die \
      "Output directory '${output_dir}' does not exist." \
      "Check the --board or --output_dir options and that the image is built."
  fi
  cd "${output_dir}"

  temp_pack_root="$(mktemp -d toolkit_XXXXXX)"
  if [[ ! -d "${temp_pack_root}" ]]; then
    die "Failed to create temporary directory."
  fi

  export INSTALL_MASK="${FACTORY_TEST_INSTALL_MASK}"
  emerge-${FLAGS_board} --root="${temp_pack_root}" --nodeps --usepkgonly -v \
    chromeos-factory chromeos-factory-board autotest-factory-install

  local factory_repo="${CHROOT_TRUNK_DIR}/src/platform/factory"
  local repo_status_script="${factory_repo}/py/toolkit/print_repo_status.py"
  if [[ -x "${repo_status_script}" ]]; then
    "${repo_status_script}" -b "${FLAGS_board}" >"${temp_pack_root}/REPO_STATUS"
  fi

  # Include 'makeself' in the toolkit
  local makeself_path="$(readlink -f $(which makeself))"
  local makeself_header_path="$(dirname "${makeself_path}")/makeself-header.sh"
  cp -L "${makeself_path}" "${makeself_header_path}" "${temp_pack_root}"

  # Include a VERSION tag in the toolkit
  if [[ -n "${FLAGS_version}" ]]; then
    local id_str="${FLAGS_board} Factory Toolkit ${FLAGS_version}"
  else
    local timestamp="$(date "+%Y-%m-%dT%H:%M:%S")"
    local builder="$(whoami)@$(hostname)"
    local id_str="${FLAGS_board} Factory Toolkit ${timestamp} ${builder}"
  fi

  local version_tag="usr/local/factory/TOOLKIT_VERSION"
  echo "${id_str}" | sudo_clobber "${temp_pack_root}/${version_tag}"
  ln -s "${version_tag}" "${temp_pack_root}/VERSION"

  # Determine whether to use host-based or monolithic goofy
  if [[ "${FLAGS_host_based}" -eq "${FLAGS_TRUE}" ]]; then
    local goofy_link_dst=goofy_split
  else
    local goofy_link_dst=goofy_monolithic
  fi
  echo "Pointing goofy symlink to ${goofy_link_dst}"
  local symlink_file="${temp_pack_root}/usr/local/factory/py/goofy"
  local symlink_dst="${temp_pack_root}/usr/local/factory/py/${goofy_link_dst}"
  sudo ln --force --no-dereference --symbolic --relative \
    "${symlink_dst}" "${symlink_file}" || \
    die "Unable to symlink ${symlink_dst} to ${symlink_file}"

  if [[ "${FLAGS_host_based}" -eq "${FLAGS_TRUE}" ]]; then
    local nohostbase_option=""
  else
    local nohostbase_option="--no-enable-presenter --no-enable-device"
  fi

  local output_toolkit="${output_dir}/install_factory_toolkit.run"
  "${temp_pack_root}/usr/local/factory/py/toolkit/installer.py" \
    --pack-into "${output_toolkit}" ${nohostbase_option}
}

main "$@"
