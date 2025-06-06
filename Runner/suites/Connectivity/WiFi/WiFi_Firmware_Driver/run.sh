#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

# Robustly find and source init_env
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INIT_ENV=""
SEARCH="$SCRIPT_DIR"
while [ "$SEARCH" != "/" ]; do
    if [ -f "$SEARCH/init_env" ]; then
        INIT_ENV="$SEARCH/init_env"
        break
    fi
    SEARCH=$(dirname "$SEARCH")
done

if [ -z "$INIT_ENV" ]; then
    echo "[ERROR] Could not find init_env (starting at $SCRIPT_DIR)" >&2
    exit 1
fi

# Only source if not already loaded (idempotent)
if [ -z "$__INIT_ENV_LOADED" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
fi
# Always source functestlib.sh, using $TOOLS exported by init_env
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="WiFi_Firmware_Driver"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1

log_info "--------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="

check_dependencies find grep modprobe lsmod cat

# Detect SoC from /proc/device-tree/model
if [ -f /proc/device-tree/model ]; then
    read -r soc_model < /proc/device-tree/model
else
    soc_model="Unknown"
fi
log_info "Detected SoC model: $soc_model"

# Scan firmware
log_info "Scanning for WiFi firmware under /lib/firmware/ath11k/..."
fwfile=""
if find /lib/firmware/ath11k/ -type f -name "amss.bin" -print -quit 2>/dev/null | grep -q .; then
    fwfile=$(find /lib/firmware/ath11k/ -type f -name "amss.bin" -print -quit 2>/dev/null)
elif find /lib/firmware/ath11k/ -type f -name "wpss.mbn" -print -quit 2>/dev/null | grep -q .; then
    fwfile=$(find /lib/firmware/ath11k/ -type f -name "wpss.mbn" -print -quit 2>/dev/null)
fi

if [ -z "$fwfile" ]; then
    log_skip_exit "$TESTNAME" "No WiFi firmware (amss.bin or wpss.mbn) found under /lib/firmware/ath11k/"
fi

size=$(stat -c%s "$fwfile" 2>/dev/null)
basename=$(basename "$fwfile")
log_info "Detected firmware [$basename]: $fwfile (size: $size bytes)"

case "$basename" in
    wpss.mbn)
        log_info "Platform using wpss.mbn firmware (e.g., Kodiak)"
        if validate_remoteproc_running "wpss"; then
            log_info "Remoteproc 'wpss' is active and validated."
        else
            log_fail_exit "$TESTNAME" "Remoteproc 'wpss' validation failed."
        fi
        log_info "No module load needed for wpss-based platform (e.g., Kodiak)."
        ;;
    amss.bin)
        log_info "amss.bin firmware detected (e.g., WCN6855 - Lemans/Monaco)"
        if ! modprobe ath11k_pci 2>/dev/null; then
            log_fail_exit "$TESTNAME" "Failed to load ath11k_pci module."
        fi
        ;;
    *)
        log_skip_exit "$TESTNAME" "Unsupported firmware type: $basename"
        ;;
esac

log_info "Checking active ath11k-related kernel modules via lsmod..."
if lsmod | grep -Eq '^ath11k(_.*)?\s'; then
    lsmod | grep -E '^ath11k(_.*)?\s' | while read -r mod_line; do
        log_info "  Module loaded: $mod_line"
    done
else
    log_fail_exit "$TESTNAME" "No ath11k-related kernel module detected via lsmod"
fi

log_pass_exit "$TESTNAME" "WiFi firmware and driver validation successful."
