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
DEFINE_boolean delete $FLAGS_FALSE "Delete an existing chroot."
DEFINE_boolean replace $FLAGS_FALSE "Overwrite existing chroot, if any."
DEFINE_integer jobs -1 "How many packages to build in parallel at maximum."
DEFINE_string stage3_path "" \
  "Use the stage3 located on this path."
DEFINE_string cache_dir "" "Directory to store caches within."
DEFINE_boolean useimage $FLAGS_FALSE "Mount the chroot on a loopback image."

# Parse command line flags.
FLAGS_HELP="usage: $SCRIPT_NAME [flags]"
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

CROS_LOG_PREFIX=cros_sdk:make_chroot
SUDO_HOME=$(eval echo ~"${SUDO_USER}")

# Set the right umask for chroot creation.
umask 022

# Only now can we die on error.  shflags functions leak non-zero error codes,
# so will die prematurely if 'switch_to_strict_mode' is specified before now.
# TODO: replace shflags with something less error-prone, or contribute a fix.
switch_to_strict_mode

[[ "${FLAGS_delete}" == "${FLAGS_FALSE}" ]] && \
  [[ -z "${FLAGS_cache_dir}" ]] && \
  die "--cache_dir is required"

. "${SCRIPT_ROOT}"/sdk_lib/make_conf_util.sh

PRIMARY_GROUP=$(id -g -n "${SUDO_USER}")
PRIMARY_GROUP_ID=$(id -g "${SUDO_USER}")

FULLNAME="ChromeOS Developer"
DEFGROUPS="${PRIMARY_GROUP},adm,cdrom,floppy,audio,video,portage"

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

cleanup() {
  # Clean up mounts
  safe_umount_tree "${FLAGS_chroot}"

  # Destroy LVM loopback setup if we can find a VG associated with our path.
  local chroot_img="${FLAGS_chroot}.img"
  [[ -f "$chroot_img" ]] || return 0

  local chroot_dev=$(losetup -j "$chroot_img" | cut -f1 -d:)
  local chroot_vg=$(find_vg_name "$FLAGS_chroot" "$chroot_dev")
  if [ -n "$chroot_vg" ] && vgs "$chroot_vg" >&/dev/null; then
    info "Removing VG $chroot_vg."
    vgremove -f "$chroot_vg" --noudevsync
  fi
  if [ -n "$chroot_dev" ]; then
    info "Detaching $chroot_dev."
    losetup -d "$chroot_dev"
  fi
}

# Appends stdin to the given file name as the sudo user.
#
# $1 - The output file name.
user_append() {
  cat >> "$1"
  chown ${SUDO_UID}:${SUDO_GID} "$1"
}

delete_existing() {
  # Delete old chroot dir.
  local chroot_img="${FLAGS_chroot}.img"
  if [[ ! -e "$FLAGS_chroot" && ! -f "$chroot_img" ]]; then
    return
  fi
  info "Cleaning up old mount points and loopback device..."
  cleanup
  info "Deleting $FLAGS_chroot..."
  rm -rf "$FLAGS_chroot"
  if [[ -f "$chroot_img" ]]; then
    info "Deleting $chroot_img..."
    rm -f "$chroot_img"
  fi
  info "Done."
}

init_users () {
   info "Set timezone..."
   # date +%Z has trouble with daylight time, so use host's info.
   rm -f "${FLAGS_chroot}/etc/localtime"
   if [ -f /etc/localtime ] ; then
     cp /etc/localtime "${FLAGS_chroot}/etc"
   else
     ln -sf /usr/share/zoneinfo/PST8PDT "${FLAGS_chroot}/etc/localtime"
   fi
   info "Adding user/group..."
   # Add the necessary groups to the chroot.
   # Duplicate GIDs are allowed here in order to ensure that the required
   # groups are the same inside and outside the chroot.
   # TODO(dpursell): Handle when PRIMARY_GROUP exists in the chroot already
   # with a different GID; groupadd will not create the new GID in that case.
   bare_chroot groupadd -f -o -g "${PRIMARY_GROUP_ID}" "${PRIMARY_GROUP}"
   # Add ourselves as a user inside the chroot.
   # We need the UID to match the host user's. This can conflict with
   # a particular chroot UID. At the same time, the added user has to
   # be a primary user for the given UID for sudo to work, which is
   # determined by the order in /etc/passwd. Let's put ourselves on top
   # of the file.
   bare_chroot useradd -o -G "${DEFGROUPS}" -g "${PRIMARY_GROUP}" \
     -u "${SUDO_UID}" -s /bin/bash -m -c "${FULLNAME}" "${SUDO_USER}"
   # Because passwd generally isn't sorted and the entry ended up at the
   # bottom, it is safe to just take it and move it to top instead.
   sed -e '1{h;d};$!{H;d};$G' -i "${FLAGS_chroot}/etc/passwd"
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

   # Some operations need an mtab.
   ln -sfT /proc/mounts "${FLAGS_chroot}/etc/mtab"

   # Set up sudoers.  Inside the chroot, the user can sudo without a password.
   # (Safe enough, since the only way into the chroot is to 'sudo chroot', so
   # the user's already typed in one sudo password...)
   # Make sure the sudoers.d subdir exists as older stage3 base images lack it.
   mkdir -p "${FLAGS_chroot}/etc/sudoers.d"

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

   # Automatically change to scripts directory.
   echo 'cd ${CHROOT_CWD:-~/trunk/src/scripts}' \
       | user_append "${FLAGS_chroot}/home/${SUDO_USER}/.bash_profile"

   # Enable bash completion for build scripts.
   printf '%s\n' "# Set up bash autocompletion." \
        ". ~/trunk/src/scripts/bash_completion" \
       | user_append "${FLAGS_chroot}/home/${SUDO_USER}/.bashrc"

   if [[ -f "${SUDO_HOME}/.cros_chroot_init" ]]; then
     warn "~/.cros_chroot_init is no longer supported"
   fi
}

unpack_tarball() {
  local tarball_path="$1"
  local dest_dir="$2"
  local decompress
  case "${tarball_path}" in
    *.tbz2|*.tar.bz2) decompress=$(type -p pbzip2 || echo bzip2) ;;
    *.tar.xz) decompress=$(type -p pixz || echo xz) ;;
    *) die "Unknown tarball compression: ${tarball_path}" ;;
  esac
  ${decompress} -dc <"${tarball_path}" | tar -xp -C "${dest_dir}"
}

# Find a usable VG name for a given path and device.  If there is an existing
# VG associated with the device, it will be returned.  If not, find an unused
# name in the format cros_<safe_path>_NNN, where safe_path is an escaped version
# of the last 90 characters of the path and NNN is a counter.  Example:
# /home/user/chromiumos/chroot/ -> cros_home+user+chromiumos+chroot_000.
# If no unused name with this pattern can be found, return an empty string.
find_vg_name() {
  local chroot_path="$1"
  local chroot_dev="$2"
  chroot_path=${chroot_path##/}
  chroot_path=${chroot_path%%/}
  chroot_path=${chroot_path//[^A-Za-z0-9_+.-]/+}
  chroot_path=${chroot_path: -$((${#chroot_path} < 90 ? ${#chroot_path} : 90))}
  local vg_name=""
  if [ -n "$chroot_dev" ]; then
    vg_name=$(pvs -q --noheadings -o vg_name "$chroot_dev" 2>/dev/null | \
              sed -e 's/^ *//')
  fi
  if [ -z "$vg_name" ]; then
    local counter=0
    vg_name=$(printf "cros_%s_%03d" "$chroot_path" "$counter")
    while [ "$counter" -lt 1000 ] && vgs "$vg_name" >&/dev/null; do
      counter=$((counter + 1))
      vg_name=$(printf "cros_%s_%03d" "$chroot_path" "$counter")
    done
    if [ "$counter" -gt 999 ]; then
      vg_name=""
    fi
  fi
  echo "$vg_name"
}

# Create a loopback image and mount it on the chroot path so that we can take
# snapshots before building.  If an image already exists, try to mount it.  The
# chroot is initially mounted inside a temporary shared chroot.build subtree
# that should have already been set up by the parent process, and then bind
# mounted into the correct final location.  The purpose of this indirection is
# so that processes outside our mount namespace can see the top-level chroot
# after we finish.
mount_chroot_image() {
  local chroot_image="$1"
  local mount_path="$2"

  # Make sure there's an image.
  local existing_chroot=0
  local chroot_dev=""
  if [ -f "$chroot_image" ]; then
    info "Attempting to reuse existing image file ${chroot_image}"
    chroot_dev=$(losetup -j "$chroot_image" | cut -f1 -d:)
    existing_chroot=1
  else
    dd if=/dev/null of="$chroot_image" bs=1G seek=500 >&/dev/null
  fi

  # Get/scan a loopback device attached to our image.
  if [ -n "$chroot_dev" ]; then
    pvscan -q "$chroot_dev" >&/dev/null
  else
    chroot_dev=$(losetup -f "$chroot_image" --show)
  fi

  # Find/create a VG on the loopback device.
  chroot_vg=$(find_vg_name "$mount_path" "$chroot_dev")
  if [ -z "$chroot_vg" ]; then
    die_notrace "Unable to find usable VG name for ${mount_path}."
  fi
  if vgs "$chroot_vg" >&/dev/null; then
    vgchange -q -a y --noudevsync "$chroot_vg" >/dev/null || :
  else
    vgcreate -q "$chroot_vg" "$chroot_dev" >/dev/null
  fi

  # Find/create an LV inside our VG.  If the LV is new, also create the FS.
  # We need to pass --noudevsync to lvcreate because we're running inside
  # a separate IPC namespace from the udev process.
  if lvs "$chroot_vg/chroot" >&/dev/null; then
    lvchange -q -ay "$chroot_vg/chroot" --noudevsync >/dev/null || :
  else
    lvcreate -q -L 499G -T "${chroot_vg}/thinpool" -V500G -n chroot \
        --noudevsync >/dev/null
    mke2fs -q -m 0 -t ext4 "/dev/${chroot_vg}/chroot"
  fi

  # Mount the FS into a directory that should have been set up as a shared
  # subtree by our parent process, then bind mount it into the place where
  # it belongs.  The parent will take care of moving the mount to the correct
  # final place on the outside of our mount namespace after we exit.
  local temp_chroot="${FLAGS_chroot}.build/chroot"
  if ! mount -text4 -onoatime "/dev/${chroot_vg}/chroot" "$temp_chroot"; then
    local chroot_example_opt=""
    if [[ "$mount_path" != "$DEFAULT_CHROOT_DIR" ]]; then
      chroot_example_opt="--chroot=$FLAGS_chroot"
    fi

    die_notrace <<EOF

Unable to mount ${chroot_vg}/chroot on ${temp_chroot}.  Check for corrupted
image ${chroot_image}, or run

cros_sdk --delete $chroot_example_opt

to clean up an old chroot first.

EOF
  fi
  mount --make-private "$temp_chroot"
  mount --bind "$temp_chroot" "$mount_path"
  mount --make-private "$mount_path"
  if [ "$existing_chroot" = "1" ]; then
    info "Mounted existing chroot image."
  fi
}

# Handle deleting an existing environment.
if [[ $FLAGS_delete  -eq $FLAGS_TRUE || \
  $FLAGS_replace -eq $FLAGS_TRUE ]]; then
  delete_existing
  [[ $FLAGS_delete -eq $FLAGS_TRUE ]] && exit 0
fi

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
CHROOT_STATE="${FLAGS_chroot}/etc/debian_chroot"
CHROOT_VERSION="${FLAGS_chroot}/etc/cros_chroot_version"
CHROOT_IMAGE="${FLAGS_chroot}.img"

# Pass proxy variables into the environment.
for type in http ftp all; do
   value=$(env | grep "${type}_proxy" || true)
   if [ -n "${value}" ]; then
      CHROOT_PASSTHRU+=("$value")
   fi
done

# Create the destination directory.
mkdir -p "$FLAGS_chroot"

[[ $FLAGS_useimage -eq $FLAGS_TRUE ]] && \
  mount_chroot_image "$CHROOT_IMAGE" "$FLAGS_chroot"

# If the version contains something non-zero, we were already created and this
# is just a re-mount.
[[ -f "$CHROOT_VERSION" && "$(<$CHROOT_VERSION)" != "0" ]] && exit 0

echo
if [[ -f "${CHROOT_STATE}" ]]; then
  info "stage3 already set up.  Skipping..."
elif [[ -z "${FLAGS_stage3_path}" ]]; then
  die_notrace "Please use --stage3_path when bootstrapping"
else
  info "Unpacking stage3..."
  unpack_tarball "${FLAGS_stage3_path}" "${FLAGS_chroot}"
  rm -f "$FLAGS_chroot/etc/"make.{globals,conf.user}
fi

# Ensure that we properly detect when we are inside the chroot.
# We'll force this to the latest version at the end as needed.
if [[ ! -e "${CHROOT_VERSION}" ]]; then
  echo "0" > "${CHROOT_VERSION}"
fi

# Set up users, if needed, before mkdir/mounts below.
[ -f $CHROOT_STATE ] || init_users

# Reset internal vars to force them to the 'inside the chroot' value;
# since user directories now exist, this can do the upgrade in place.
set_chroot_trunk_dir "${FLAGS_chroot}" poppycock

echo
info "Setting up mounts..."
# Set up necessary mounts and make sure we clean them up on exit.
mkdir -p "${FLAGS_chroot}/${CHROOT_TRUNK_DIR}" \
    "${FLAGS_chroot}/${DEPOT_TOOLS_DIR}" "${FLAGS_chroot}/run"

# Create a special /etc/make.conf.host_setup that we use to bootstrap
# the chroot.  The regular content for the file will be generated the
# first time we invoke update_chroot (further down in this script).
create_bootstrap_host_setup "${FLAGS_chroot}"

if ! [ -f "$CHROOT_STATE" ];then
  INITIALIZE_CHROOT=1
fi

if ! early_enter_chroot bash -c 'type -P pbzip2' >/dev/null ; then
  # This chroot lacks pbzip2 early on, so we need to disable it.
  early_env+=(
    PORTAGE_BZIP2_COMMAND="bzip2"
    PORTAGE_BUNZIP2_COMMAND="bunzip2"
  )
fi

if [ -z "${INITIALIZE_CHROOT}" ];then
  info "chroot already initialized.  Skipping..."
else
  # Run all the init stuff to setup the env.
  init_setup
fi

# Add file to indicate that it is a chroot.
# Add version of stage3 for update checks.
echo "STAGE3=${FLAGS_stage3_path}" > "${CHROOT_STATE}"

# Switch SDK python to Python 3 by default.
early_enter_chroot eselect python update

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

if [ -n "${INITIALIZE_CHROOT}" ]; then
  # If we're creating a new chroot, we also want to set it to the latest
  # version.
  enter_chroot run_chroot_version_hooks --init-latest
fi

# Update chroot.
# Skip toolchain update because it already happened above, and the chroot is
# not ready to emerge all cross toolchains.
UPDATE_ARGS=( --skip_toolchain_update )
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

CHROOT_EXAMPLE_OPT=""
if [[ "$FLAGS_chroot" != "$DEFAULT_CHROOT_DIR" ]]; then
  CHROOT_EXAMPLE_OPT="--chroot=$FLAGS_chroot"
fi

command_completed

cat <<EOF

${CROS_LOG_PREFIX:-cros_sdk}: All set up.  To enter the chroot, run:
$ cros_sdk --enter $CHROOT_EXAMPLE_OPT

CAUTION: Do *NOT* rm -rf the chroot directory; if there are stale bind
mounts you may end up deleting your source tree too.  To unmount and
delete the chroot cleanly, use:
$ cros_sdk --delete $CHROOT_EXAMPLE_OPT

EOF

is_nfs() {
  [[ $(stat -f -L -c %T "$1") == "nfs" ]]
}

if is_nfs "${SUDO_HOME}"; then
  warn "${SUDO_HOME} is on NFS. This is untested. Send patches if it's broken."
fi
