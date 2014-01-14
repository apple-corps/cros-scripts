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

cleanup() {
  sudo rm -rf "${temp_pack_root}"
}

main() {
  # Parse command line.
  FLAGS "$@" || exit 1
  eval set -- "${FLAGS_ARGV}"

  switch_to_strict_mode

  trap cleanup EXIT

  local default_dir="${CHROOT_TRUNK_DIR}/src/build/images/${FLAGS_board}/latest"
  if [[ -n "${FLAGS_output_dir}" ]]; then
    local output_dir="${FLAGS_output_dir}"
  else
    local output_dir="${default_dir}"
  fi
  cd "${output_dir}"

  local temp_pack_root="$(mktemp -d toolkit_XXXXXX)"
  if [[ ! -d "${temp_pack_root}" ]]; then
    die "Failed to create temporary directory."
  fi

  export INSTALL_MASK="${FACTORY_TEST_INSTALL_MASK}"
  emerge-${FLAGS_board} --root="${temp_pack_root}" --nodeps --usepkgonly -v \
    chromeos-factory chromeos-factory-board autotest-factory-install

  local output_toolkit="${output_dir}/install_factory_toolkit.sh"
  makeself --bzip2 --nox11 "${temp_pack_root}" \
    "${output_toolkit}" \
    "Factory Toolkit" \
    usr/local/factory/py/toolkit/installer.py

  echo "
  Factory toolkit generated at ${output_toolkit}.

  To install factory toolkit on a live device running a test image, copy this
  to the device and execute it as root.

  Alternatively, the factory toolkit can be used to patch a test image. For
  more information, run:
    ${output_toolkit} -- --help

  "
}

main "$@"
