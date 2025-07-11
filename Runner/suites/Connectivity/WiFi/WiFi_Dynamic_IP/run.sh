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

# shellcheck disable=SC1090
if [ -z "$__INIT_ENV_LOADED" ]; then
    . "$INIT_ENV"
fi

# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="WiFi_Dynamic_IP"
#res_file="./$TESTNAME.res"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1

log_info "-------------------------------------------------------------"
log_info "------------------- Starting $TESTNAME Test -----------------"

# Credential extraction
creds=$(get_wifi_credentials "$1" "$2") || log_skip_exit "$TESTNAME" "WiFi: SSID and/or password missing. Skipping test." wifi_cleanup ""
SSID=$(echo "$creds" | awk '{print $1}')
PASSWORD=$(echo "$creds" | awk '{print $2}')
log_info "Using SSID='$SSID' and PASSWORD='[hidden]'"

check_dependencies iw ping

# If not a kernel-only/minimal build, systemd is checked, else skipped automatically
check_systemd_services systemd-networkd.service || log_fail_exit "$TESTNAME" "Network services check failed" wifi_cleanup ""

WIFI_IFACE=$(get_wifi_interface) || log_fail_exit "$TESTNAME" "No WiFi interface found" wifi_cleanup ""
log_info "Using WiFi interface: $WIFI_IFACE"

# nmcli with retry
if wifi_connect_nmcli "$WIFI_IFACE" "$SSID" "$PASSWORD"; then
    IP=$(wifi_get_ip "$WIFI_IFACE")
    [ -z "$IP" ] && log_fail_exit "$TESTNAME" "No IP after nmcli" wifi_cleanup "$WIFI_IFACE"
    if retry_command "ping -I \"$WIFI_IFACE\" -c 3 -W 2 8.8.8.8 >/dev/null 2>&1" 3 3; then
        log_pass_exit "$TESTNAME" "Internet connectivity verified via ping" wifi_cleanup "$WIFI_IFACE"
    else
        log_fail_exit "$TESTNAME" "Ping test failed after nmcli connection" wifi_cleanup "$WIFI_IFACE"
    fi
fi

# wpa_supplicant+udhcpc with retry
if wifi_connect_wpa_supplicant "$WIFI_IFACE" "$SSID" "$PASSWORD"; then
    IP=$(wifi_get_ip "$WIFI_IFACE")
    [ -z "$IP" ] && log_fail_exit "$TESTNAME" "No IP after wpa_supplicant" wifi_cleanup "$WIFI_IFACE"
    if retry_command "ping -I \"$WIFI_IFACE\" -c 3 -W 2 8.8.8.8 >/dev/null 2>&1" 3 3; then
        log_pass_exit "$TESTNAME" "Internet connectivity verified via ping" wifi_cleanup "$WIFI_IFACE"
    else
        log_fail_exit "$TESTNAME" "Ping test failed after wpa_supplicant connection" wifi_cleanup "$WIFI_IFACE"
    fi
fi

log_fail_exit "$TESTNAME" "All WiFi connection methods failed for $WIFI_IFACE (SSID: $SSID)" wifi_cleanup "$WIFI_IFACE"
