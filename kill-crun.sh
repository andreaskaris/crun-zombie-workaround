#!/bin/bash
#
# Workaround for https://issues.redhat.com/browse/OCPBUGS-31317 | https://issues.redhat.com/browse/RHEL-30102
# 
# When a session with a TTY is connected to a pod, such a session can end up filling the buffer of the TTY session between crio and crun
# and make crun block forever in do_tty_write.
# When the pod is stopped, the exec session's process (e.g. in a lot of cases bash) will become a zombie. It should be crun's job to remove
# the zombie, but crun cannot do this as it is stuck in do_tty_write. As a result, the container never shuts down and the pod is stuck in
# Terminating forever.
# This script scans all processes, and it will issue a `kill -9` for any instance of crun which is:
# a) the parent of a zombie child
# b) stuck in do_tty_write according to /proc/<pid>/stack
#
# 2024-03-24, Andreas Karis <akaris@redhat.com>

set -eu

LOG_LEVEL="${1:-normal}"
if [ "${LOG_LEVEL}" == "debug" ]; then
    set -x
fi

SCRIPT_NAME="${0}"

function get_defunct() {
    ps -e -o pid,state | awk '$NF == "Z" {print $1}'
}

function get_ppid() {
    local pid
    pid="${1}"
    awk '/PPid:/ {print $NF}' < "/proc/${pid}/status"
}

function is_crun() {
    local pid
    local name
    pid="${1}"   
    name=$(awk '/Name:/ {print $NF}' < "/proc/${pid}/status")
    [ "${name}" == "crun" ]
}

function is_blocked_in_tty_write() {
    local pid
    pid="${1}"   
    grep -q do_tty_write "/proc/${pid}/stack"
}

function log_msg() {
    local prefix
    local message
    prefix="${SCRIPT_NAME}:"
    message="${1}"
    logger "$prefix $message"
}

function get_pid_info() {
    local pid
    pid=${1}
    ps -T -o flags,state,uid,pid,ppid,pgid,sid,cls,pri,addr,sz,wchan,lstart,tty,time,cmd -p "${pid}" | tail -1
}

for defunct_process in $(get_defunct); do
    ppid=$(get_ppid "${defunct_process}")
    if ! is_crun "${ppid}"; then
        continue
    fi
    if ! is_blocked_in_tty_write "${ppid}"; then
        continue
    fi
    pid_info=$(get_pid_info "${ppid}")
    log_msg "Killing stuck crun instance with process ID ${ppid} (${pid_info})"
    kill -9 "${ppid}"
done
