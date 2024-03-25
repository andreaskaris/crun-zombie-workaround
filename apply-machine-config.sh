#!/bin/bash
#
# Apply a MachineConfiguration to a given $ROLE to deploy a script that cleans up stuck
# crun processes on pod deletion. The optional second parameter to this script is the
# log level of kill-crun.sh, "normal" or "debug".
# Requires file kill-crun.sh in the same location as this script.
# A backup of the generated MachineConfiguration will be saved to the /tmp/apply-machine-config
# directory.
#
# Usage: ./apply-machine-config.sh <ROLE> <DEBUG>
#
# 2024-03-25, Andreas Karis <akaris@redhat.com>

set -eu

DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
KILL_CRUN_SRC="${DIR}/kill-crun.sh"
KILL_CRUN_DST="/usr/local/bin/kill-crun.sh"
OUTPUT_DIR="/tmp/apply-machine-config"
RUN_EVERY_X_MINUTES=2

if ! [ -f "${KILL_CRUN_SRC}" ]; then
    echo "Missing dependency, could not find file ${KILL_CRUN_SRC}"
    exit 1
fi

if [ $# -lt 1 ]; then
    echo "Please provide the <role name>"
    exit 1
fi

ROLE="${1}"
DEBUG="${2:-''}"

mkdir -p "${OUTPUT_DIR}"
OUTPUT_FILE="${OUTPUT_DIR}/${ROLE}.yaml"

cat <<EOF | tee "${OUTPUT_FILE}" | oc apply -f -
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: ${ROLE}
  name: 99-${ROLE}-kill-crun
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
      - contents:
          source: data:text/plain;charset=utf-8;base64,$(base64 -w0 < "${KILL_CRUN_SRC}")
        filesystem: root
        mode: 0750
        path: ${KILL_CRUN_DST}
    systemd:
      units:
      - name: kill-crun.service
        enabled: true
        contents: |
          [Unit]
          Description=Kill stuck crun processes
          [Service]
          ExecStart=${KILL_CRUN_DST} ${DEBUG}
          [Install]
          WantedBy=multi-user.target
      - name: kill-crun.timer
        enabled: true
        contents: |
          [Unit]
          Description=Verify every ${RUN_EVERY_X_MINUTES} minutes if crun processes must be killed
          [Timer]
          OnCalendar=*:0/${RUN_EVERY_X_MINUTES}
          Unit=kill-crun.service
          [Install]
          WantedBy=timers.target
EOF
echo "Backup saved to ${OUTPUT_FILE}"
