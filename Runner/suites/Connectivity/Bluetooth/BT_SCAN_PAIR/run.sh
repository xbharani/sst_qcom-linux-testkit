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

if [ -z "$__INIT_ENV_LOADED" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
fi

# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="BT_SCAN_PAIR"
test_path=$(find_test_case_by_name "$TESTNAME") || {
    log_fail "$TESTNAME : Test directory not found."
    echo "$TESTNAME FAIL" > "./$TESTNAME.res"
    exit 1
}
cd "$test_path" || exit 1
RES_FILE="./$TESTNAME.res"
rm -f "$RES_FILE"

log_info "------------------------------------------------------------"
log_info "Starting $TESTNAME Testcase"

BT_NAME=""
BT_MAC=""
WHITELIST=""
PAIR_RETRIES="${PAIR_RETRIES:-3}"
SCAN_ATTEMPTS="${SCAN_ATTEMPTS:-2}"

# Parse arguments
if [ -n "$1" ]; then
    if echo "$1" | grep -Eq '^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$'; then
        BT_MAC="$1"
    else
        BT_NAME="$1"
    fi
fi

if [ -n "$2" ]; then
    WHITELIST="$2"
    if [ -z "$BT_MAC" ] && echo "$2" | grep -Eq '^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$'; then
        BT_MAC="$2"
    fi
fi

# Fallback to file
if [ -z "$BT_NAME" ] && [ -z "$BT_MAC" ] && [ -f "./bt_device_list.txt" ]; then
    BT_NAME=$(awk '!/^#/ && NF {print $2}' ./bt_device_list.txt | head -n1)
    BT_MAC=$(awk '!/^#/ && NF {print $1}' ./bt_device_list.txt | head -n1)
fi

check_dependencies bluetoothctl rfkill expect hciconfig || {
    echo "$TESTNAME SKIP" > "$RES_FILE"
    exit 0
}

cleanup_bt_test() {
    [ -n "$BT_MAC" ] && bt_cleanup_paired_device "$BT_MAC"
    killall -q bluetoothctl 2>/dev/null
}
trap cleanup_bt_test EXIT

rfkill unblock bluetooth
retry_command_bt "hciconfig hci0 up" "Bring up hci0" || {
    log_fail "Failed to bring up hci0"
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 1
}

bt_remove_all_paired_devices

MATCH_FOUND=0

for scan_try in $(seq 1 "$SCAN_ATTEMPTS"); do
    log_info "Bluetooth scan attempt $scan_try..."
    bt_scan_devices

    LATEST_FOUND_LOG=$(find . -maxdepth 1 -name 'found_devices_*.log' -type f -print | sort -r | head -n1)
    [ -z "$LATEST_FOUND_LOG" ] && continue

    log_info "Devices found during scan:"
    cat "$LATEST_FOUND_LOG"

    if [ -z "$BT_NAME" ] && [ -z "$BT_MAC" ]; then
        log_pass "No device specified. Scan-only mode."
        echo "$TESTNAME PASS" > "$RES_FILE"
        exit 0
    fi

    log_info "Matching against: BT_NAME='$BT_NAME', BT_MAC='$BT_MAC', WHITELIST='$WHITELIST'"
    bt_remove_all_paired_devices
    bluetoothctl --timeout 3 devices | awk '{print $2}' | while read -r addr; do
        log_info "Forcing device removal: $addr"
        bluetoothctl remove "$addr" >/dev/null 2>&1
    done

    # Clean and prepare whitelist
WHITELIST_CLEAN=$(echo "$WHITELIST" | tr -d '\r' | tr ',\n' ' ' | xargs)
MATCH_FOUND=0

while IFS= read -r line; do
    mac=$(echo "$line" | awk '{print $1}')
    name=$(echo "$line" | cut -d' ' -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    log_info "Parsed: MAC='$mac' NAME='$name'"
    log_info "Checking if MAC or NAME is in whitelist: '$WHITELIST_CLEAN'"

    if [ -n "$BT_MAC" ] && [ "$mac" = "$BT_MAC" ]; then
        log_info "MAC matched: $mac"
        if [ -z "$WHITELIST_CLEAN" ] || echo "$WHITELIST_CLEAN" | grep -wq "$mac" || echo "$WHITELIST_CLEAN" | grep -wq "$name"; then
            log_info "MAC allowed by whitelist: $mac ($name)"
            MATCH_FOUND=1
            break
        else
            log_info "MAC matched but not in whitelist: $name"
        fi
    elif [ -n "$BT_NAME" ] && [ "$name" = "$BT_NAME" ]; then
        log_info "Name matched: $name"
        if [ -z "$WHITELIST_CLEAN" ] || echo "$WHITELIST_CLEAN" | grep -wq "$mac" || echo "$WHITELIST_CLEAN" | grep -wq "$name"; then
            log_info "Name allowed by whitelist: $name ($mac)"
            BT_MAC="$mac"
            MATCH_FOUND=1
            break
        else
            log_info "Name matched but not in whitelist: $name"
        fi
    fi
done < "$LATEST_FOUND_LOG"

    [ "$MATCH_FOUND" -eq 1 ] && break
    sleep 2
done

if [ "$MATCH_FOUND" -ne 1 ]; then
    log_fail "Expected device not found or not in whitelist"
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 1
fi

log_info "Attempting to pair with $BT_NAME ($BT_MAC)"
if bt_pair_with_mac "$BT_MAC" "$PAIR_RETRIES"; then
    log_info "Pairing successful. Attempting post-pair connection..."
    if bt_post_pair_connect "$BT_MAC"; then
        log_info "Post-pair connection successful, verifying with l2ping..."
        if bt_l2ping_check "$BT_MAC" "$RES_FILE"; then
            log_pass "Post-pair connection and l2ping verified"
            echo "$TESTNAME PASS" > "$RES_FILE"
            exit 0
        else
            log_warn "Post-pair successful but l2ping failed"
            echo "$TESTNAME FAIL" > "$RES_FILE"
            exit 1
        fi
    fi
else
    log_fail "Pairing failed after $PAIR_RETRIES retries"
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 1
fi
