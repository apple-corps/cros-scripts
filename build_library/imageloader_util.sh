#!/bin/bash

# Copyright 2018 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Contains utility functions for creating an imageloader supported image.

# Sign the image manifest!
sign_manifest() {
  "${VBOOT_SIGNING_DIR}"/sign_official_build.sh \
    oci-container "$1" "${VBOOT_DEVKEYS_DIR}" "$1"
}

# Generate the imageloader.json.
generate_imageloader_manifest() {
  local pkg_version="$1"
  local output="$2"
  local manifest="${output}/imageloader.json"
  local image="${output}/image.squash"
  local table="${output}/table"

  (
    gethash() {
      local file="$1"
      echo $(sha256sum <"${file}" | awk '{print $1}')
    }

    printf '{\n'
    printf '"manifest-version": 1,\n'
    printf '"version": "%s",\n' "${pkg_version}"
    printf '"image-sha256-hash": "%s",\n' "$(gethash "${image}")"
    printf '"table-sha256-hash": "%s"\n' "$(gethash "${table}")"
    printf '}\n'
  ) >"${manifest}"

  # Sanity check the generated manifest.
  python -mjson.tool <"${manifest}" >/dev/null

  sign_manifest "${output}"
}

# Sign the specified disk image using verity so we can load it with dm-verity
# at runtime.  We don't allow algorithm selection -- sha256 should be good
# enough for everyone! :)
# Note: We write the verity command line to the "verity" variable as an output.
sign_disk_image() {
  local img="$1"
  local hashtree="${img}.hashtree"
  verity=$(verity mode=create alg=sha256 salt="random" payload="${img}" \
                  hashtree="${hashtree}")
  cat "${hashtree}" >>"${img}"
  rm "${hashtree}"
}

# Generates a squashfs image and its imageloader manifest from a source dir.
# The manifest is signed using oci_container keys.
# The output directory will contain the following:
#   * image.squash: a squashfs image build from the source directory
#   * table: text file containing verity commandline
#   * imageloader.json: imageloader manifest
#   * imageloader.sig.2: ECDSA signature of imageloader.json
generate_imageloader_image() {
  local version="$1"
  local src="$2"
  local output="$3"

  local img="${output}/image.squash"

  if [[ ! -d "${src}" ]]; then
    warn "Source directory not found: ${src}"
    return 1
  fi

  if [[ ! -d "${output}" ]]; then
    warn "Output directory not found: ${output}"
    return 1
  fi

  info "Generating squashfs file ... "
  local args=(
    -all-root
    -noappend
  )
  sudo mksquashfs "${src}" "${img}" "${args[@]}"
  sudo chown $(id -u):$(id -g) "${img}"

  info "Signing squashfs file ... "
  local verity
  sign_disk_image "${img}"
  echo "${verity}" > "${output}/table"

  info "Generating imageloader manifest ..."
  generate_imageloader_manifest "${version}" "${output}"
  return 0
}

# Creates a tar archive that contains imageloder supported image of a
# directory. See |generate_imageloader_image| for more info.
generate_and_tar_imageloader_image() {
  local version="$1"
  local src="$2"
  local output="$3"

  local image=$(mktemp -d)

  generate_imageloader_image "0.0.1" "${src}" "${image}"
  tar caf "${output}" -C "${image}" \
      image.squash table imageloader.json imageloader.sig.2
  rm -rf "${image}"
}
