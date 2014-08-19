#!/bin/bash

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

SCRIPT_ROOT=$(dirname $(readlink -f "$0"))
. "${SCRIPT_ROOT}/common.sh" || exit 1

error "image_to_usb.sh is deprecated! Use 'cros flash' instead."
error "See 'cros flash -h' for the usage."
error "More information is available at:"
error "http://www.chromium.org/chromium-os/build/cros-flash"

exit 1
