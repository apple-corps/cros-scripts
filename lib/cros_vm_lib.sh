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

KVM_PID_FILE=/tmp/kvm.$$.pid
LIVE_VM_IMAGE=

if ! KVM_BINARY=$(which kvm 2> /dev/null); then
  if ! KVM_BINARY=$(which qemu-kvm 2> /dev/null); then
    die "no kvm binary found"
  fi
fi

get_pid() {
  sudo cat "${KVM_PID_FILE}"
}

# Configure paths to KVM pipes. Must not be called until after KVM_PID_FILE
# has been updated. (See, e.g., start_kvm.)
set_kvm_pipes() {
  local base="${KVM_PID_FILE%.pid}"
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

kvm_version_greater_equal() {
  local test_version="${1}"
  local kvm_version=$(kvm --version | sed -E 's/^.*version ([0-9\.]*) .*$/\1/')

  [ $(echo -e "${test_version}\n${kvm_version}" | sort -r -V | head -n 1) = \
    $kvm_version ]
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
  # Determine appropriate qemu CPU for board.
  # TODO(spang): Let the overlay provide appropriate options.
  local board="$2"
  local cpu_option=""
  case "${board}" in
    x86-alex*|x86-mario*|x86-zgb*)
      cpu_option="-cpu n270"
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
    local nographics=""
    local usesnapshot=""
    if [ ${FLAGS_no_graphics} -eq ${FLAGS_TRUE} ]; then
      if kvm_version_greater_equal "1.4.0"; then
        nographics="-display none"
      else
        nographics="-nographic"
      fi
    fi
    if [ -n "${FLAGS_vnc}" ]; then
      nographics="-vnc ${FLAGS_vnc}"
    fi

    if [ ${FLAGS_snapshot} -eq ${FLAGS_TRUE} ]; then
      snapshot="-snapshot"
    fi

    local vm_image="$1"
    if [ ${FLAGS_copy} -eq ${FLAGS_TRUE} ]; then
      local our_copy=$(mktemp "${vm_image}.copy.XXXXXXXXXX")
      if cp "${vm_image}" "${our_copy}"; then
          info "Copied ${vm_image} to ${our_copy}."
          vm_image="${our_copy}"
      else
          die "Copy failed. Aborting."
      fi
    fi

    local net_option="-net nic,model=virtio"
    if [ -f "$(dirname "${vm_image}")/.use_e1000" ]; then
      info "Detected older image, using e1000 instead of virtio."
      net_option="-net nic,model=e1000"
    fi

    local cache_type="writeback"
    if kvm_version_greater_equal "0.14"; then
      cache_type="unsafe"
    fi

    local incoming=""
    local incoming_option=""
    if [ -n "${FLAGS_mem_path}" ]; then
      local decompressor=$(get_decompressor "${FLAGS_mem_path}")
      incoming="-incoming"
      incoming_option="exec: ${decompressor} ${FLAGS_mem_path}"
    fi

    local usb_passthrough=""
    if [ -n "${FLAGS_usb_devices}" ]; then
      usb_devices=(${FLAGS_usb_devices//,/ })
      for bus_id in "${usb_devices[@]}"; do
        device=(${bus_id//:/ })
        if [ ${#device[@]} -ne 2 ]; then
          continue
        fi
        passthrough="-device usb-host,hostbus=${device[0]},hostaddr=${device[1]}"
        usb_passthrough="${usb_passthrough} ${passthrough}"
      done

      if [ -n "${usb_passthrough}" ]; then
        usb_passthrough="-usb ${usb_passthrough}"
      fi
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
    drive="-drive file=${vm_image},index=0,media=disk,cache=${cache_type}"
    if [ ${FLAGS_scsi} -eq ${FLAGS_TRUE} ]; then
      drive=$(echo "-drive if=none,id=hd,file=${vm_image},cache=${cache_type}"\
          "-device virtio-scsi-pci,id=scsi "\
          "-device scsi-hd,drive=hd")
    fi

    # Note: the goofiness around the expansion of |incoming_option| is
    # to ensure that it is quoted if set, but _not_ quoted if
    # unset. (QEMU chokes on empty arguments).
    sudo "${KVM_BINARY}" -m 2G \
      -smp 4 \
      -vga cirrus \
      -pidfile "${KVM_PID_FILE}" \
      -chardev pipe,id=control_pipe,path="${KVM_PIPE_PREFIX}" \
      -serial "file:${KVM_SERIAL_FILE}" \
      -mon chardev=control_pipe \
      -daemonize \
      ${cpu_option} \
      ${net_option} \
      ${nographics} \
      ${snapshot} \
      -net user,hostfwd=tcp:127.0.0.1:${FLAGS_ssh_port}-:22 \
      ${incoming} ${incoming_option:+"$incoming_option"} \
      ${usb_passthrough} \
      ${drive}

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
