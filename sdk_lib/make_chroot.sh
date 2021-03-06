#!/bin/bash

# Copyright (c) 2012 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# This script sets up a Gentoo chroot environment. The script is passed the
# path to an empty folder, which will be populated with a Gentoo stage3 and
# setup for development. Once created, the password is set to PASSWORD (below).
# One can enter the chrooted environment for work by running enter_chroot.sh.

SCRIPT_ROOT=$(readlink -f $(dirname "$0")/..)
. "${SCRIPT_ROOT}/common.sh" || exit 1

ENTER_CHROOT=$(readlink -f $(dirname "$0")/enter_chroot.sh)

if [ -n "${USE}" ]; then
  echo "$SCRIPT_NAME: Building with a non-empty USE: ${USE}"
  echo "This modifies the expected behaviour and can fail."
fi

# Check if the host machine architecture is supported.
ARCHITECTURE="$(uname -m)"
if [[ "$ARCHITECTURE" != "x86_64" ]]; then
  echo "$SCRIPT_NAME: $ARCHITECTURE is not supported as a host machine architecture."
  exit 1
fi

# Script must be run outside the chroot and as root.
assert_outside_chroot
assert_root_user

# Define command line flags.
# See http://code.google.com/p/shflags/wiki/Documentation10x

DEFINE_string chroot "$DEFAULT_CHROOT_DIR" \
  "Destination dir for the chroot environment."
DEFINE_boolean usepkg $FLAGS_TRUE "Use binary packages to bootstrap."
DEFINE_integer jobs -1 "How many packages to build in parallel at maximum."
DEFINE_string cache_dir "" "Directory to store caches within."
DEFINE_boolean eclean "${FLAGS_TRUE}" "Run eclean to delete old binpkgs."

# Parse command line flags.
FLAGS_HELP="usage: $SCRIPT_NAME [flags]"
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

CROS_LOG_PREFIX=cros_sdk:make_chroot

# Set the right umask for chroot creation.
umask 022

# Only now can we die on error.  shflags functions leak non-zero error codes,
# so will die prematurely if 'switch_to_strict_mode' is specified before now.
# TODO: replace shflags with something less error-prone, or contribute a fix.
switch_to_strict_mode

[[ -z "${FLAGS_cache_dir}" ]] && die "--cache_dir is required"

. "${SCRIPT_ROOT}"/sdk_lib/make_conf_util.sh

USEPKG=""
USEPKGONLY=""
if [[ $FLAGS_usepkg -eq $FLAGS_TRUE ]]; then
  # Use binary packages. Include all build-time dependencies,
  # so as to avoid unnecessary differences between source
  # and binary builds.
  USEPKG="--getbinpkg --usepkg --with-bdeps y"
  # Use --usepkgonly to avoid building toolchain packages from source.
  USEPKGONLY="--usepkgonly"
fi

EMERGE_CMD="${CHROOT_TRUNK_DIR}/chromite/bin/parallel_emerge"

ENTER_CHROOT_ARGS=(
  CROS_WORKON_SRCROOT="$CHROOT_TRUNK"
  PORTAGE_USERNAME="${SUDO_USER}"
  IGNORE_PREFLIGHT_BINHOST="$IGNORE_PREFLIGHT_BINHOST"
)

# Invoke enter_chroot.  This can only be used after sudo has been installed.
enter_chroot() {
  echo "$(date +%H:%M:%S) [enter_chroot] $*"
  "$ENTER_CHROOT" --cache_dir "${FLAGS_cache_dir}" --chroot "$FLAGS_chroot" \
    -- "${ENTER_CHROOT_ARGS[@]}" "$@"
}

# Invoke enter_chroot running the command as root, and w/out sudo.
# This should be used prior to sudo being merged.
early_env=()
early_enter_chroot() {
  echo "$(date +%H:%M:%S) [early_enter_chroot] $*"
  "$ENTER_CHROOT" --chroot "$FLAGS_chroot" --early_make_chroot \
    --cache_dir "${FLAGS_cache_dir}" \
    -- "${ENTER_CHROOT_ARGS[@]}" "${early_env[@]}" "$@"
}

# Run a command within the chroot.  The main usage of this is to avoid the
# overhead of enter_chroot.  It's when we do not need access to the source
# tree, don't need the actual chroot profile env, and can run the command as
# root.  We do have to make sure PATH includes all the right programs as
# found inside of the chroot since the environment outside of the chroot
# might be insufficient (like distros with merged /bin /sbin and /usr).
bare_chroot() {
  PATH="/bin:/sbin:/usr/bin:/usr/sbin:${PATH}" \
    chroot "${FLAGS_chroot}" "$@"
}

# Appends stdin to the given file name as the sudo user.
#
# $1 - The output file name.
user_append() {
  cat >> "$1"
  chown ${SUDO_UID}:${SUDO_GID} "$1"
}

init_setup () {
   info "Running init_setup()..."
   mkdir -p -m 755 "${FLAGS_chroot}/usr" \
     "${FLAGS_chroot}${OVERLAYS_ROOT}" \
     "${FLAGS_chroot}"/"${CROSSDEV_OVERLAY}/metadata"
   # Newer portage complains about bare overlays.  Create the file that crossdev
   # will also create later on.
   cat <<EOF > "${FLAGS_chroot}/${CROSSDEV_OVERLAY}/metadata/layout.conf"
# Autogenerated and managed by crossdev
# Delete the above line if you want to manage this file yourself
masters = portage-stable chromiumos
repo-name = crossdev
use-manifests = true
thin-manifests = true
EOF
   ln -sf "${CHROOT_TRUNK_DIR}/src/third_party/eclass-overlay" \
     "${FLAGS_chroot}"/"${ECLASS_OVERLAY}"
   ln -sf "${CHROOT_TRUNK_DIR}/src/third_party/chromiumos-overlay" \
     "${FLAGS_chroot}"/"${CHROOT_OVERLAY}"
   ln -sf "${CHROOT_TRUNK_DIR}/src/third_party/portage-stable" \
     "${FLAGS_chroot}"/"${PORTAGE_STABLE_OVERLAY}"

   # Use the standardized upgrade script to setup proxied vars.
   load_environment_whitelist
   "${SCRIPT_ROOT}/sdk_lib/rewrite-sudoers.d.sh" \
     "${FLAGS_chroot}" "${SUDO_USER}" "${ENVIRONMENT_WHITELIST[@]}"

   find "${FLAGS_chroot}/etc/"sudoers* -type f -exec chmod 0440 {} +
   # Fix bad group for some.
   chown -R root:root "${FLAGS_chroot}/etc/"sudoers*

   info "Setting up hosts/resolv..."
   # Copy config from outside chroot into chroot.
   cp /etc/{hosts,resolv.conf} "$FLAGS_chroot/etc/"
   chmod 0644 "$FLAGS_chroot"/etc/{hosts,resolv.conf}

   # Setup host make.conf. This includes any overlay that we may be using
   # and a pointer to pre-built packages.
   # TODO: This should really be part of a profile in the portage.
   info "Setting up /etc/make.*..."
   rm -f "${FLAGS_chroot}"/etc/{,portage/}make.{conf,profile}{,.catalyst}
   mkdir -p "${FLAGS_chroot}/etc/portage"
   ln -sf "${CHROOT_CONFIG}/make.conf.amd64-host" \
     "${FLAGS_chroot}/etc/make.conf"
   ln -sf "${CHROOT_OVERLAY}/profiles/default/linux/amd64/10.0/sdk" \
     "${FLAGS_chroot}/etc/portage/make.profile"

   # Create make.conf.user .
   rm -f "${FLAGS_chroot}"/etc/make.conf.user
   cat <<\EOF > "${FLAGS_chroot}"/etc/make.conf.user
# This file is useful for doing global (chroot and all board) changes.
# Tweak emerge settings, ebuild env, etc...
#
# Make sure to append variables unless you really want to clobber all
# existing settings.  e.g. You most likely want:
#   FEATURES="${FEATURES} ..."
#   USE="${USE} foo"
# and *not*:
#   USE="foo"
#
# This also is a good place to setup ACCEPT_LICENSE.
EOF
   chmod 0644 "${FLAGS_chroot}"/etc/make.conf.user

   # Create directories referred to by our conf files.
   mkdir -p -m 775 "${FLAGS_chroot}/var/lib/portage/pkgs" \
     "${FLAGS_chroot}/var/cache/"chromeos-{cache,chrome} \
     "${FLAGS_chroot}/etc/profile.d"

   echo "export CHROMEOS_CACHEDIR=/var/cache/chromeos-cache" > \
     "${FLAGS_chroot}/etc/profile.d/chromeos-cachedir.sh"
   chmod 0644 "${FLAGS_chroot}/etc/profile.d/chromeos-cachedir.sh"
   rm -rf "${FLAGS_chroot}/var/cache/distfiles"
   ln -s chromeos-cache/distfiles "${FLAGS_chroot}/var/cache/distfiles"

   # Run this from w/in the chroot so we use whatever uid/gid
   # these are defined as w/in the chroot.
   bare_chroot chown "${SUDO_USER}:portage" /var/cache/chromeos-chrome

   # Add chromite/bin and depot_tools into the path globally; note that the
   # chromite wrapper itself might also be found in depot_tools.
   # We rely on 'env-update' getting called below.
   target="${FLAGS_chroot}/etc/env.d/99chromiumos"
   cat <<EOF > "${target}"
PATH="${CHROOT_TRUNK_DIR}/chromite/bin:${DEPOT_TOOLS_DIR}"
CROS_WORKON_SRCROOT="${CHROOT_TRUNK_DIR}"
PORTAGE_USERNAME="${SUDO_USER}"
EOF

   # TODO(zbehan): Configure stuff that is usually configured in postinst's,
   # but wasn't. Fix the postinst's.
   info "Running post-inst configuration hacks"
   early_enter_chroot env-update

   # This is basically a sanity check of our chroot.  If any of these
   # don't exist, then either bind mounts have failed, an invocation
   # from above is broke, or some assumption about the stage3 is no longer
   # true.
   early_enter_chroot ls -l /etc/make.conf /etc/portage/make.profile \
     /usr/local/portage/chromiumos/profiles/default/linux/amd64/10.0

   target="${FLAGS_chroot}/etc/profile.d"
   mkdir -p "${target}"
   ln -sfT \
     "/mnt/host/source/chromite/sdk/etc/profile.d/50-chromiumos-niceties.sh" \
     "${target}/50-chromiumos-niceties.sh"

   # Select a small set of locales for the user if they haven't done so
   # already.  This makes glibc upgrades cheap by only generating a small
   # set of locales.  The ones listed here are basically for the buildbots
   # which always assume these are available.  This works in conjunction
   # with `cros_sdk --enter`.
   # http://crosbug.com/20378
   local localegen="$FLAGS_chroot/etc/locale.gen"
   if ! grep -q -v -e '^#' -e '^$' "${localegen}" ; then
     cat <<EOF >> "${localegen}"
en_US ISO-8859-1
en_US.UTF-8 UTF-8
EOF
   fi
}

CHROOT_TRUNK="${CHROOT_TRUNK_DIR}"
PORTAGE="${SRC_ROOT}/third_party/portage"
OVERLAY="${SRC_ROOT}/third_party/chromiumos-overlay"
CONFIG_DIR="${OVERLAY}/chromeos/config"
CHROOT_CONFIG="${CHROOT_TRUNK_DIR}/src/third_party/chromiumos-overlay/chromeos/config"
OVERLAYS_ROOT="/usr/local/portage"
ECLASS_OVERLAY="${OVERLAYS_ROOT}/eclass-overlay"
PORTAGE_STABLE_OVERLAY="${OVERLAYS_ROOT}/stable"
CROSSDEV_OVERLAY="${OVERLAYS_ROOT}/crossdev"
CHROOT_OVERLAY="${OVERLAYS_ROOT}/chromiumos"

# Pass proxy variables into the environment.
for type in http ftp all; do
   value=$(env | grep "${type}_proxy" || true)
   if [ -n "${value}" ]; then
      CHROOT_PASSTHRU+=("$value")
   fi
done

# Create a special /etc/make.conf.host_setup that we use to bootstrap
# the chroot.  The regular content for the file will be generated the
# first time we invoke update_chroot (further down in this script).
create_bootstrap_host_setup "${FLAGS_chroot}"

# Run all the init stuff to setup the env.
init_setup

# Clean out any stale binpkgs that might be in a warm cache. This is done
# immediately after unpacking the tarball in case ebuilds have been removed
# (e.g. from a revert).
if [[ "${FLAGS_eclean}" -eq "${FLAGS_TRUE}" ]]; then
  info "Cleaning stale binpkgs"
  early_enter_chroot /bin/bash -c '
    source /mnt/host/source/src/scripts/common.sh &&
    eclean -e <(get_eclean_exclusions) packages'
fi

info "Updating portage"
early_enter_chroot emerge -uNv --quiet --ignore-world portage

# Add chromite into python path.
for python_path in "${FLAGS_chroot}/usr/lib/"python*.*; do
  python_path+="/site-packages"
  sudo mkdir -p "${python_path}"
  sudo ln -s -fT "${CHROOT_TRUNK_DIR}"/chromite "${python_path}"/chromite
done

# Now that many of the fundamental packages should be in a good state, update
# the host toolchain.  We have to do this step by step ourselves to avoid races
# when building tools that are actively used (e.g. updating the assembler while
# also compiling other packages that use the assembler).
# https://crbug.com/715788
info "Updating host toolchain"
TOOLCHAIN_ARGS=( --deleteold )
if [[ "${FLAGS_usepkg}" == "${FLAGS_FALSE}" ]]; then
  TOOLCHAIN_ARGS+=( --nousepkg )
fi
# First the low level compiler tools.  These should be fairly independent of
# the C library, so we can do it first.
early_enter_chroot ${EMERGE_CMD} -uNv ${USEPKG} ${USEPKGONLY} ${EMERGE_JOBS} \
  sys-devel/binutils
# Next the C library.  The compilers often use newer features, but the C library
# is often designed to work with older compilers.
early_enter_chroot ${EMERGE_CMD} -uNv ${USEPKG} ${USEPKGONLY} ${EMERGE_JOBS} \
  sys-kernel/linux-headers sys-libs/glibc
# Now we can let the rest of the compiler packages build in parallel as they
# don't generally rely on each other.
# Note: early_enter_chroot executes as root.
early_enter_chroot "${CHROOT_TRUNK_DIR}/chromite/bin/cros_setup_toolchains" \
    --hostonly "${TOOLCHAIN_ARGS[@]}"

info "Updating Perl modules"
early_enter_chroot \
  "${CHROOT_TRUNK_DIR}/src/scripts/build_library/perl_rebuild.sh"

# If we're creating a new chroot, we also want to set it to the latest version.
enter_chroot run_chroot_version_hooks --init-latest

# Update chroot.
# Skip toolchain update because it already happened above, and the chroot is
# not ready to emerge all cross toolchains.
UPDATE_ARGS=( --skip_toolchain_update --noeclean )
if [[ "${FLAGS_usepkg}" == "${FLAGS_TRUE}" ]]; then
  UPDATE_ARGS+=( --usepkg )
else
  UPDATE_ARGS+=( --nousepkg )
fi
if [[ "${FLAGS_jobs}" -ne -1 ]]; then
  UPDATE_ARGS+=( --jobs="${FLAGS_jobs}" )
fi
enter_chroot "${CHROOT_TRUNK_DIR}/src/scripts/update_chroot" "${UPDATE_ARGS[@]}"

# The java-config package atm does not support $ROOT.  Select a default
# VM ourselves until that gets fixed upstream.
enter_chroot sudo eselect java-vm set system openjdk-bin-11

command_completed
