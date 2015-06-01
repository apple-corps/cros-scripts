# Copyright (c) 2011 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

if [ -z "${FLAGS_board}" ]; then
  error "--board is required."
  exit 1
fi

BOARD="${FLAGS_board}"
BOARD_ROOT="/build/${BOARD}"

if [[ ! -d "${BOARD_ROOT}" ]]; then
  die_notrace "The board has not been set up: ${BOARD}"
fi

# What cross-build are we targeting?
. "${BOARD_ROOT}/etc/make.conf.board_setup"
