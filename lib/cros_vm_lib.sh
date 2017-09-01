# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# Common vm functions for use in crosutils.

DEFAULT_PRIVATE_KEY="${GCLIENT_ROOT}/src/scripts/mod_for_test_scripts/\
ssh_keys/testing_rsa"

DEFINE_string kvm_pid "" \
  "Use this pid file.  If it exists and is set, use the vm specified by pid."
DEFINE_boolean copy ${FLAGS_FALSE} "Copy the image file before starting the VM."
DEFINE_string mem_path "" "VM memory image to save or restore."
DEFINE_boolean no_graphics ${FLAGS_FALSE} "Runs the KVM instance silently."
DEFINE_boolean persist "${FLAGS_FALSE}" "Persist vm."
DEFINE_boolean scsi ${FLAGS_FALSE} "Loads disk as a virtio-scsi-disk. "\
"This option is used for testing Google Compute Engine-compatible images."
DEFINE_boolean snapshot ${FLAGS_FALSE} "Don't commit changes to image."
DEFINE_integer ssh_port 9222 "Port to tunnel ssh traffic over."
DEFINE_string ssh_private_key "${DEFAULT_PRIVATE_KEY}" \
    "Path to the private key to use to ssh into test image as the root user."
DEFINE_string vnc "" "VNC Server to display to instead of SDL "\
"(e.g. pass ':1' to listen on 0.0.0.0:5901)."
DEFINE_string usb_devices "" \
    "Usb devices for passthrough. Specified in a comma-separated list
     where each item is of the form <vendor_id>:<product_id>
     (eg. --usb_devices=1050:0211,0409:005a)"
DEFINE_boolean moblab ${FLAGS_FALSE} "Setup environment for moblab"
DEFINE_string qemu_binary \
  "${DEFAULT_CHROOT_DIR}"/usr/bin/qemu-system-x86_64 \
  "The qemu binary to be used. Defaults to qemu shipped with the SDK."

KVM_PID_FILE=/tmp/kvm.$$.pid
LIVE_VM_IMAGE=

# Pick which qemu/kvm binary will be used. Must be called before any function
# that needs ${KVM_BINARY}, and *after* the command line has been parsed by the
# calling script. Otherwise the default value can not be overriden by the user.
set_kvm() {
  # The value of the flag is only valid after the command line has been parsed.
  KVM_BINARY="${FLAGS_qemu_binary}"
  if [[ ! -x "${KVM_BINARY}" ]]; then
    if ! KVM_BINARY=$(which qemu-system-x86_64 2> /dev/null); then
      die "no QEMU binary found"
    fi
  fi
  info "QEMU binary: ${KVM_BINARY}"

  # Make sure it's a recent enough version.
  # The version string typically looks like this:
  #"QEMU emulator version 2.5.0, Copyright (c) 2003-2008 Fabrice Bellard"
  # but in Debian/ubuntu distributions, some QEMU binaries have a
  # space and a package version rather the comma just after the version number:
  #"QEMU emulator version 2.0.0 (Debian 2.0.0+dfsg-2ubuntu1.22), Copyright[...]"
  local ver version
  version=$("${KVM_BINARY}" --version)
  ver="${version#QEMU emulator version }"
  info "QEMU version: ${version}"
  case ${ver} in
  [23].[0-9]*) ;;
  *) die "Old/unknown/unsupported version of QEMU: ${ver}" ;;
  esac
}

get_pid() {
  sudo cat "${KVM_PID_FILE}"
}

get_host_files_prefix() {
  echo "${KVM_PID_FILE%.pid}"
}

# Configure paths to KVM pipes. Must not be called until after KVM_PID_FILE
# has been updated. (See, e.g., start_kvm.)
set_kvm_pipes() {
  local base="$(get_host_files_prefix)"
  KVM_PIPE_PREFIX="${base}.monitor"
  KVM_PIPE_IN="${KVM_PIPE_PREFIX}.in"  # to KVM
  KVM_PIPE_OUT="${KVM_PIPE_PREFIX}.out"  # from KVM
  KVM_SERIAL_FILE="${base}.serial"
}

# General purpose blocking kill on a pid.
# This function sends a specified kill signal [0-9] to a pid and waits for it
# die up to a given timeout.  It exponentially backs off it's timeout starting
# at 1 second.
# $1 the process id.
# $2 signal to send (-#).
# $3 max timeout in seconds.
# Returns 0 on success.
blocking_kill() {
  local timeout=1
  sudo kill -$2 $1
  while ps -p $1 > /dev/null && [ ${timeout} -le $3 ]; do
    sleep ${timeout}
    timeout=$((timeout*2))
  done
  ! ps -p ${1} > /dev/null
}

# Send a command to the KVM monitor. The caller is responsible for
# escaping the command, so that it survives sudo sh -c "$arg".
# Additionally, |set_kvm_pipes| must have been called before this
# function.
send_monitor_command() {
  local command="${1}"
  sudo sh -c "echo ${1} > ${KVM_PIPE_IN}"
}

# Send a command to the KVM monitor, and wait for KVM to issue another
# prompt. The caller is responsible for escaping the command, so that
# it survives sudo sh -c "$arg".  Additionally, |set_kvm_pipes| must
# have been called before this function.
send_monitor_command_and_wait() {
  local command="${1}"
  sudo sh -c "echo ${1} > ${KVM_PIPE_IN}"
  # Wait for the command prompt. Note that we send an empty command
  # before waiting, because the monitor's command prompt doesn't
  # include a newline. (And grep waits for a newline.)
  sudo sh -c "echo > ${KVM_PIPE_IN}"
  sudo grep -F -q "(qemu)" "${KVM_PIPE_OUT}"
}

# Return a command which will read stdin, and write a (compressed)
# bytestream to stdout, for the compression format implied by
# |filename|.
get_compressor() {
  local filename="${1}"
  local extra_flag="${2:-}"
  case "${filename}" in
    *.gz)
      compressor="pigz -c ${extra_flag}"
      ;;
    *.bz2)
      compressor="pbzip2 -c ${extra_flag}"
      ;;
    *)
      compressor="cat"
      ;;
  esac
  echo "${compressor}"
}

# Return a command which will read stdin, and write a (decompressed)
# bytestream to stdout, for the compression format implied by
# |filename|.
get_decompressor() {
  get_compressor "${1}" "-d"
}

# $1: Path to the virtual image to start.
# $2: Name of the board to virtualize.
start_kvm() {
  local vm_image="$1"
  local board="$2"
  local extra_args=( "${@:3}" )

  set_kvm

  # Determine appropriate qemu CPU for board.
  # TODO(spang): Let the overlay provide appropriate options.
  local cpu_option=""
  case "${board}" in
    x86-alex*|x86-mario*|x86-zgb*)
      cpu_option="-cpu n270"
      ;;
  esac

  # Use virtio-gpu instead of cirrus if the board supports it.
  case "${board}" in
    amd64-generic|betty|newbie|novato)
      video_card="virtio"
      ;;
    *)
      video_card="cirrus"
      ;;
  esac

  # Override default pid file.
  local start_vm=0
  [ -n "${FLAGS_kvm_pid}" ] && KVM_PID_FILE=${FLAGS_kvm_pid}
  if [ -f "${KVM_PID_FILE}" ]; then
    local pid=$(get_pid)
    # Check if the process exists.
    if ps -p ${pid} > /dev/null ; then
      echo "Using a pre-created KVM instance specified by ${FLAGS_kvm_pid}." >&2
      start_vm=1
    else
      # Let's be safe in case they specified a file that isn't a pid file.
      echo "File ${KVM_PID_FILE} exists but specified pid doesn't." >&2
    fi
  fi

  # No kvm specified by pid file found, start a new one.
  if [ ${start_vm} -eq 0 ]; then
    echo "Starting a KVM instance" >&2
    local kvm_flag=""
    local nographics=""
    local usesnapshot=""
    if [ ${FLAGS_no_graphics} -eq ${FLAGS_TRUE} ]; then
      nographics="-display none"
    fi
    if [ -n "${FLAGS_vnc}" ]; then
      nographics="-vnc ${FLAGS_vnc}"
    fi

    if [ ${FLAGS_snapshot} -eq ${FLAGS_TRUE} ]; then
      snapshot="-snapshot"
    fi

    # When using the regular qemu system binary, force KVM.
    case "${KVM_BINARY}" in
      */qemu-system-x86_64)
        kvm_flag="-enable-kvm"
        ;;
    esac

    if [ ${FLAGS_copy} -eq ${FLAGS_TRUE} ]; then
      local our_copy=$(mktemp "${vm_image}.copy.XXXXXXXXXX")
      if cp "${vm_image}" "${our_copy}"; then
          info "Copied ${vm_image} to ${our_copy}."
          vm_image="${our_copy}"
      else
          die "Copy failed. Aborting."
      fi
    fi

    # Qemu-vlans are used by qemu to separate out network traffic on the slirp
    # network bridge. qemu forwards traffic on a slirp vlan to all ports
    # conected on that vlan. By default, slirp ports are on vlan 0.
    # We explicitly set a vlan here so that another qemu VM using slirp doesn't
    # conflict with our network traffic.
    local net_option="-net nic,model=virtio,vlan=${FLAGS_ssh_port}"
    local net_user="-net user,hostfwd=tcp:127.0.0.1:${FLAGS_ssh_port}-:22"
    net_user+=",vlan=${FLAGS_ssh_port}"

    local incoming=""
    local incoming_option=""
    if [ -n "${FLAGS_mem_path}" ]; then
      local decompressor=$(get_decompressor "${FLAGS_mem_path}")
      incoming="-incoming"
      incoming_option="exec: ${decompressor} ${FLAGS_mem_path}"
    fi

    local usb_passthrough=""
    if [ -n "${FLAGS_usb_devices}" ]; then
      local bus_id
      local usb_devices=(${FLAGS_usb_devices//,/ })
      for bus_id in "${usb_devices[@]}"; do
        local device=(${bus_id//:/ })
        if [ ${#device[@]} -ne 2 ]; then
          continue
        fi
        usb_passthrough+=" -device usb-host,vendorid=$((0x${device[0]}))"
        usb_passthrough+=",productid=$((0x${device[1]}))"
      done

      if [ -n "${usb_passthrough}" ]; then
        usb_passthrough="-usb ${usb_passthrough}"
      fi
    fi

    local base="$(get_host_files_prefix)"
    local moblab_env=""
    if [ ${FLAGS_moblab} -eq ${FLAGS_TRUE} ]; then
      # Increase moblab memory size.
      moblab_env="-m 4G"

      # Add hostforwarding for important moblab pages to the SLIRP connection.
      MOB_MONITOR_PORT=$(( FLAGS_ssh_port + 1 ))
      AFE_PORT=$(( FLAGS_ssh_port + 2 ))
      DEVSERVER_PORT=$(( FLAGS_ssh_port + 3 ))

      net_user+=",hostfwd=tcp:127.0.0.1:${MOB_MONITOR_PORT}-:9991"
      net_user+=",hostfwd=tcp:127.0.0.1:${AFE_PORT}-:80"
      net_user+=",hostfwd=tcp:127.0.0.1:${DEVSERVER_PORT}-:8080"

      info "Mob* Monitor: 127.0.0.1:${MOB_MONITOR_PORT}"
      info "Autotest: 127.0.0.1:${AFE_PORT}"
      info "Devserver: 127.0.0.1:${DEVSERVER_PORT}"
    fi

    set_kvm_pipes
    for pipe in "${KVM_PIPE_IN}" "${KVM_PIPE_OUT}"; do
      sudo rm -f "${pipe}"  # assumed safe because, the PID is not running
      sudo mknod "${pipe}" p
      sudo chmod 600 "${pipe}"
    done

    sudo touch "${KVM_SERIAL_FILE}"
    sudo chmod a+r "${KVM_SERIAL_FILE}"

    local drive
    drive="-drive file=${vm_image},index=0,media=disk,cache=unsafe"
    if [ ${FLAGS_scsi} -eq ${FLAGS_TRUE} ]; then
      drive=$(echo "-drive if=none,id=hd,file=${vm_image},cache=unsafe"\
          "-device virtio-scsi-pci,id=scsi "\
          "-device scsi-hd,drive=hd")
    fi

    # Note: the goofiness around the expansion of |incoming_option| is
    # to ensure that it is quoted if set, but _not_ quoted if
    # unset. (QEMU chokes on empty arguments).
    local cmd=(
      "${KVM_BINARY}" ${kvm_flag} -m 2G
      -smp 4
      -vga "${video_card}"
      -pidfile "${KVM_PID_FILE}"
      -chardev pipe,id=control_pipe,path="${KVM_PIPE_PREFIX}"
      -serial "file:${KVM_SERIAL_FILE}"
      -mon chardev=control_pipe
      -daemonize
      ${cpu_option}
      ${net_option}
      ${nographics}
      ${snapshot}
      ${net_user}
      ${incoming} ${incoming_option:+"$incoming_option"}
      ${usb_passthrough}
      ${moblab_env}
      ${drive}
      "${extra_args[@]}"
    )
    info "Launching: ${cmd[*]}"
    sudo "${cmd[@]}"

    info "KVM started with pid stored in ${KVM_PID_FILE}"
    info "Serial output, if available, can be found here in ${KVM_SERIAL_FILE}"
    LIVE_VM_IMAGE="${vm_image}"
  fi
}

# Checks to see if we can access the target virtual machine with ssh.
ssh_ping() {
  # TODO(sosa): Remove outside chroot use once all callers work inside chroot.
  local cmd
  if [ $INSIDE_CHROOT -ne 1 ]; then
    cmd="${GCLIENT_ROOT}/src/scripts/ssh_test.sh"
  else
    cmd=/usr/lib/crosutils/ssh_test.sh
  fi
  "${cmd}" \
    --ssh_port=${FLAGS_ssh_port} \
    --private_key=${FLAGS_ssh_private_key} \
    --remote=127.0.0.1 >&2
}
# Tries to ssh into live image $1 times.  After first failure, a try involves
# shutting down and restarting kvm.
retry_until_ssh() {
  local can_ssh_into=1
  local max_retries=3
  local retries=0
  ssh_ping && can_ssh_into=0

  while [ ${can_ssh_into} -eq 1 ] && [ ${retries} -lt ${max_retries} ]; do
    echo "Failed to connect to virtual machine, retrying ... " >&2
    stop_kvm || echo "Could not stop kvm.  Retrying anyway." >&2
    start_kvm "${LIVE_VM_IMAGE}"
    ssh_ping && can_ssh_into=0
    retries=$((retries + 1))
  done
  return ${can_ssh_into}
}

stop_kvm() {
  set_kvm
  if [ "${FLAGS_persist}" -eq "${FLAGS_TRUE}" ]; then
    echo "Persist requested.  Use --ssh_port ${FLAGS_ssh_port} " \
      "--ssh_private_key ${FLAGS_ssh_private_key} " \
      "--kvm_pid ${KVM_PID_FILE} to re-connect to it." >&2
  else
    echo "Stopping the KVM instance" >&2
    set_kvm_pipes
    local pid=$(get_pid)
    if [ -n "${pid}" ]; then
      if [ -n "${FLAGS_mem_path}" ]; then
        local mem_path="${FLAGS_mem_path}"
        local compressor=$(get_compressor "${mem_path}")
        echo "Saving memory snapshot to ${mem_path}..."
        echo "    freezing VM..."
        send_monitor_command_and_wait "stop"
        echo "    saving memory, piping through ${compressor}..."
        # Create file as current user, so that it will be readable by
        # the current user. (Otherwise, it would be owned by root.)
        touch "${mem_path}"
        send_monitor_command_and_wait \
            "migrate \\\"exec:${compressor} \> ${mem_path}\\\""
        # Flush any disk I/O that is buffered in KVM.
        echo "    flushing disk buffers..."
        send_monitor_command_and_wait "commit all"
        # Quit KVM now, so that we don't modify the filesystem which
        # this memory image depends on.
        echo "    asking KVM to quit..."
        send_monitor_command "quit"
        echo "    done."
      else
        # Initiate the power-off sequence inside the guest. Note that
        # this monitor command does not wait for the guest to power
        # off the system.
        send_monitor_command "system_powerdown"
      fi
      blocking_kill ${pid} 0 16 || blocking_kill ${pid} 9 3
      sudo rm -f "${KVM_PID_FILE}" "${KVM_PIPE_IN}" "${KVM_PIPE_OUT}" \
        "${KVM_SERIAL_FILE}"
    else
      echo "No kvm pid found to stop." >&2
      return 1
    fi
  fi
}
