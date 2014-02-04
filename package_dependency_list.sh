#!/bin/bash
# Copyright (c) 2014 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script that finds all dependencies and sub-dependencies of a package and
# then sums up the total sizes of those dependencies based on output from
# the script `package_size_stats.sh`.

. "$(dirname "$0")/common.sh" || exit 1

# Script must run inside the chroot
restart_in_chroot_if_needed "$@"

assert_not_root_user

# Developer-visible flags.
DEFINE_string board "${DEFAULT_BOARD}" \
  "The board to build packages for."
DEFINE_string depth "20" \
  "The depth to go looking for dependencies."

# Clean up the package name returned from qdepends.  Removes version numbers
# and USE flag conditional requirements from the given string.
# Arguments:
#   $1: An individual package string returned from qdepends.
# Returns:
#   The clean package name.
clean_package_name() {
  echo "$1" | sed -r -e 's/([~>=!<]*)(.*)/\2/g' -e 's/[:[].*//g' \
    -e 's/(.*)-([0-9])+.*/\1/g'
}

get_package_size() {
  local package="$1"
  local size="$(qsize-${FLAGS_board} -b -C "${package}" \
    | head -n1 \
    | sed -n "\:${package}-[0-9]:p" \
    | sed -r 's/.*, ([0-9]*) bytes/\1/')"
  echo "${size:-0}"
}

get_dependency_size() {
  declare -A deps
  local package_name="$(qcheck-${FLAGS_board} -q -C "$1" \
    | head -n 1 \
    | cut -d ' ' -f 2)"
  if [[ -z "${package_name}" ]]; then
    # Full package name lookup failed.
    package_name="$1"
  else
    package_name=$(clean_package_name "${package_name}")
  fi
  local dependencies="${package_name}"

  local dep_depth=${FLAGS_depth}

  info "Runtime dependencies for '${package_name}'"
  info "Dependency Search Depth: ${FLAGS_depth}"
  info ""

  local i
  local cleanname
  for i in ${dependencies}; do
    cleanname=$(clean_package_name $i)
    deps[${cleanname}]=$(get_package_size ${cleanname})
  done

  local loop=0
  local prevsize
  while [[ ${loop} -lt ${dep_depth} ]]; do
    : $(( loop += 1 ))
    prevsize=${#deps[@]}

    local depname
    for depname in "${!deps[@]}"; do
      dependencies="$(qdepends-${FLAGS_board} -r -N -C -q "${depname}" \
        | sed 's/\s\+/\n/g' \
        | sed '1d')"
      for i in ${dependencies}; do
        cleanname=$(clean_package_name "${i}")
        if [[ ${deps[${cleanname}]+set} != "set" ]]; then
          # New key found, add to array and get size if it's available.
          deps[${cleanname}]=$(get_package_size ${cleanname})
        fi
      done
    done

    if [[ ${prevsize} -eq ${#deps[@]} ]]; then
      # No new dependencies found on this iteration, break out of loop
      break
    fi
  done

  # Print all dependencies.
  local total_size=0
  for depname in "${!deps[@]}"; do
    info "${depname}: ${deps[${depname}]}"
    : $(( total_size += ${deps[${depname}]} ))
  done

  info ""
  info "Found ${#deps[@]} dependencies."
  info ""
  info "Total size for package '${package_name}': ${total_size}"
  info ""
  info " -----"
  info ""
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

  local package
  for package in "$@"; do
    get_dependency_size "${package}"
  done
}

main "$@"
