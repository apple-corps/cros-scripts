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

# Flags.
DEFINE_string yaml "model.yaml" "Source YAML file to generate JSON from." y
DEFINE_string json "model_auto_generated.json" "Target JSON file to check against." j

FLAGS_HELP="Check that a generated JSON file matches the source YAML for cros_config

USAGE: $0 [flags] args

For example:
$  ../../../../../scripts/check_json_from_yaml -y model.yaml -j model_auto_generated.json
"
# Parse command line.
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"
switch_to_strict_mode

main() {
  local tmp_json=$(mktemp)

  if [[ "$#" -ne 0 ]]; then
    flags_help
    exit 1
  fi

  if [[ -z "${FLAGS_yaml}" ]]; then
    die_notrace "-y or --yaml required."
  fi

  local yaml=${FLAGS_yaml}

  if [[ -z "${FLAGS_json}" ]]; then
    die_notrace "-j or --json required."
  fi

  local json=${FLAGS_json}

  cros_config_schema -c ${yaml} -o ${tmp_json}
  local tmp_cksum="$(cksum "$tmp_json" | cut -d ' ' -f 1)"
  rm "${tmp_json}"
  local existing_cksum="$(cksum "$json" | cut -d ' ' -f 1)"
  if [[ "$tmp_cksum" -ne "$existing_cksum" ]]; then
    warn "YAML has been updated, but JSON is out of date.\n"\
      "Updating ... please add to your current patchset.\n"\
      "git add $(pwd)/${json}"
    cros_config_schema -c ${yaml} -o ${json}
    exit 1
  fi
}

main "$@"
