#!/bin/bash
# Copyright (c) 2014 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script that builds the given package and all its runtime dependencies, and
# installs them in a temporary directory and returns the size used

. "$(dirname "$0")/common.sh" || exit 1

EMERGE_CMD="${CHROMITE_BIN}/parallel_emerge"

export INSTALL_MASK="${DEFAULT_INSTALL_MASK}"

# Script must run inside the chroot
restart_in_chroot_if_needed "$@"

assert_not_root_user

# Developer-visible flags.
DEFINE_string board "${DEFAULT_BOARD}" \
  "The board to build packages for."

cleanup() {
  echo "Do you wish to remove the temporary install directory [${tmp_folder}]?"
  PS3="Remove? "
  local reply="Error"
  while [[ "${reply}" == "Error" ]]; do
    choose reply "Error" "Error" "Yes" "No"
  done
  if [[ "${reply}" == "Yes" ]]; then
    sudo rm -rf "${tmp_folder}"
  fi
}

main() {

  # Parse command line
  FLAGS "$@" || exit 1
  eval set -- "${FLAGS_ARGV}"

  if [[ $# -eq 0 ]]; then
    die "Usage: $0 --board=<board> <package>"
  fi

  if [[ -z "${FLAGS_board}" ]]; then
    die "Error: --board is required."
  fi

  local package="$1"
  local tmp_name=${1//\//_}
  tmp_folder=$(mktemp -d "/tmp/pdeps-${tmp_name}-XXXXX") \
    || die "Couldn't create temp folder."

  trap cleanup EXIT

  ${EMERGE_CMD} --board=${FLAGS_board} --root="${tmp_folder}" \
    --root-deps=rdeps --keep-going=y ${package}

  local size_used=$(sudo du -sh "${tmp_folder}" | cut -f1)

  info "Size used for package ${package}: ${size_used}\n\n"
}

main "$@"
