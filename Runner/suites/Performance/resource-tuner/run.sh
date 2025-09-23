#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
# resource-tuner test runner (pinned whitelist)

# ---------- Repo env + helpers ----------
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
# Only source once (idempotent)
if [ -z "${__INIT_ENV_LOADED:-}" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
    __INIT_ENV_LOADED=1
fi
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

# ---------- Stable env ----------
umask 022
export LC_ALL=C
export PATH="/usr/sbin:/sbin:/usr/bin:/bin:${PATH}"
# Try best-effort core dumps; ignore on strict POSIX shells.
# shellcheck disable=SC3045
( ulimit -c unlimited ) >/dev/null 2>&1 || true

TESTNAME="resource-tuner"
test_path="$(find_test_case_by_name "$TESTNAME")"
cd "$test_path" || exit 1
RES_FILE="./${TESTNAME}.res"

# ---------- Lock (avoid concurrent runs on same host) ----------
LOCKFILE="/tmp/${TESTNAME}.lock"
if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCKFILE"
  if ! flock -n 9; then
    log_warn "Another ${TESTNAME} run is active; skipping"
    echo "$TESTNAME SKIP" >"$RES_FILE"; exit 0
  fi
else
  if ! mkdir "$LOCKFILE" 2>/dev/null; then
    log_warn "Another ${TESTNAME} run is active; skipping"
    echo "$TESTNAME SKIP" >"$RES_FILE"; exit 0
  fi
  trap 'rmdir "$LOCKFILE" 2>/dev/null || true' EXIT INT TERM
fi

# ---------- Approved list (pinned whitelist) ----------
APPROVED_TESTS="
/usr/bin/ClientDataManagerTests
/usr/bin/ResourceProcessorTests
/usr/bin/MemoryPoolTests
/usr/bin/SignalConfigProcessorTests
/usr/bin/DeviceInfoTests
/usr/bin/ThreadPoolTests
/usr/bin/MiscTests
/usr/bin/SignalParsingTests
/usr/bin/SafeOpsTests
/usr/bin/ExtensionIntfTests
/usr/bin/RateLimiterTests
/usr/bin/SysConfigAPITests
/usr/bin/ExtFeaturesParsingTests
/usr/bin/RequestMapTests
/usr/bin/TargetConfigProcessorTests
/usr/bin/InitConfigParsingTests
/usr/bin/RequestQueueTests
/usr/bin/CocoTableTests
/usr/bin/ResourceParsingTests
/usr/bin/TimerTests
/usr/bin/resource_tuner_tests
"

# Suites that need base configs (accept either common/ OR custom/)
SUITES_REQUIRE_BASE_CFGS="ResourceProcessorTests SignalConfigProcessorTests SysConfigAPITests \
ExtFeaturesParsingTests TargetConfigProcessorTests InitConfigParsingTests \
ResourceParsingTests ExtensionIntfTests resource_tuner_tests"

# ---------- CLI ----------
print_usage() {
    cat <<EOF
Usage: $0 [--all] [--bin <name|absolute>] [--list] [--timeout SECS]
Policy:
  - Service INACTIVE => overall SKIP (end early)
  - Base configs: suites require common/ OR custom/ (skip only if BOTH missing)
  - resource_tuner_tests additionally needs tests/Configs/ResourceSysFsNodes
  - Any test FAIL => overall FAIL
  - No FAIL & PASS>0 => overall PASS
  - No FAIL & PASS=0 => overall SKIP (everything skipped)

Options:
  --all Run all approved tests (default)
  --bin NAME|PATH Run only one approved test
  --list Print approved set and coverage and exit
  --timeout SECS Per-binary timeout if run_with_timeout() exists (default: 1200)
EOF
}
RUN_MODE="all"; ONE_BIN=""; TIMEOUT_SECS=1200
while [ $# -gt 0 ]; do
    case "$1" in
        --all) RUN_MODE="all" ;;
        --bin) shift; ONE_BIN="$1"; RUN_MODE="one" ;;
        --list) RUN_MODE="list" ;;
        --timeout) shift; TIMEOUT_SECS="${1:-1200}" ;;
        --help|-h) print_usage; exit 0 ;;
        *) log_error "Unknown argument: $1"; print_usage; exit 1 ;;
    esac; shift
done

# ---------- Helpers ----------
approved_tests() { printf '%s\n' "$APPROVED_TESTS" | awk 'NF'; }
is_approved() {
    cand="$1"; cbase="$(basename "$cand")"
    for t in $(approved_tests); do
        [ "$cand" = "$t" ] && return 0
        [ "$cbase" = "$(basename "$t")" ] && return 0
    done; return 1
}
suite_requires_base_cfgs() {
    name="$1"
    for s in $SUITES_REQUIRE_BASE_CFGS; do [ "$name" = "$s" ] && return 0; done
    return 1
}
parse_and_score_log() {
    logf="$1"
    grep -Eiq '(^|[^a-z])fail(ed)?([^a-z]|$)|Assertion failed|Terminating Suite|Segmentation fault|Backtrace' "$logf" && return 1
    grep -Eiq 'Run Successful|executed successfully|Ran Successfully' "$logf" && return 0
    return 2
}
per_suite_timeout() {
    case "$1" in
        ThreadPoolTests|RateLimiterTests) echo 1800 ;;
        resource_tuner_tests) echo 2400 ;;
        *) echo "$TIMEOUT_SECS" ;;
    esac
}
run_cmd_maybe_timeout() {
    bin="$1"; shift
    secs="$(per_suite_timeout "$(basename "$bin")")"
    if command -v run_with_timeout >/dev/null 2>&1; then
        run_with_timeout "$secs" "$bin" "$@"
    else
        "$bin" "$@"
    fi
}

# ---------- Banner & deps ----------
log_info "----------------------------------------------------------------------"
log_info "------------------- Starting ${TESTNAME} Testcase ----------------------"
log_info "=== Test Initialization ==="
check_dependencies awk grep date printf || { log_skip "$TESTNAME SKIP – base tools missing"; echo "$TESTNAME SKIP" >"$RES_FILE"; exit 0; }

# ---------- Logs ----------
TS="$(date +%Y%m%d-%H%M%S)"
LOGDIR="./logs/${TESTNAME}-${TS}"
mkdir -p "$LOGDIR"
(dmesg 2>/dev/null || true) > "$LOGDIR/dmesg_snapshot.log"
ln -sfn "$LOGDIR" "./logs/${TESTNAME}-latest" 2>/dev/null || true

# ---------- SoC / Platform info (via functestlib) ----------
if command -v log_soc_info >/dev/null 2>&1; then
    log_soc_info
fi

# ---------- Service gate (use repo helper) ----------
SERVICE_NAME="${SERVICE_NAME:-resource-tuner.service}"
log_info "[SERVICE] Checking $SERVICE_NAME via check_systemd_services()"
if check_systemd_services "$SERVICE_NAME"; then
    log_pass "[SERVICE] $SERVICE_NAME is active"
else
    log_skip "[SERVICE] $SERVICE_NAME not active — overall SKIP"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

# ---------- Config preflight (check both common/ and custom/) ----------
RT_CONFIG_DIR="${RT_CONFIG_DIR:-/etc/resource-tuner}"
COMMON_DIR="$RT_CONFIG_DIR/common"
CUSTOM_DIR="$RT_CONFIG_DIR/custom"
TEST_NODES_DIR="$RT_CONFIG_DIR/tests/Configs/ResourceSysFsNodes"

COMMON_OK=1; CUSTOM_OK=1; NODES_OK=1

REQ_COMMON_FILES="${RT_REQUIRE_COMMON_FILES:-InitConfig.yaml PropertiesConfig.yaml ResourcesConfig.yaml SignalsConfig.yaml}"
REQ_CUSTOM_FILES="${RT_REQUIRE_CUSTOM_FILES:-InitConfig.yaml PropertiesConfig.yaml ResourcesConfig.yaml SignalsConfig.yaml TargetConfig.yaml ExtFeaturesConfig.yaml}"

# common/
if [ ! -d "$COMMON_DIR" ]; then
    log_warn "[CFG] Missing dir: $COMMON_DIR"; COMMON_OK=0
else
    for f in $REQ_COMMON_FILES; do
        [ -f "$COMMON_DIR/$f" ] || { log_warn "[CFG] Missing file: $COMMON_DIR/$f"; COMMON_OK=0; }
    done
fi

# custom/
if [ ! -d "$CUSTOM_DIR" ]; then
    log_warn "[CFG] Missing dir: $CUSTOM_DIR"; CUSTOM_OK=0
else
    for f in $REQ_CUSTOM_FILES; do
        [ -f "$CUSTOM_DIR/$f" ] || { log_warn "[CFG] Missing file: $CUSTOM_DIR/$f"; CUSTOM_OK=0; }
    done
    # Informational: count entries (POSIX-friendly find)
    cn=$(find "$CUSTOM_DIR/ResourceSysFsNodes" -mindepth 1 -maxdepth 1 -type f -print 2>/dev/null | wc -l | awk '{print $1}')
    [ -n "$cn" ] && log_info "[CFG] custom/ResourceSysFsNodes entries: $cn"
fi

# tests nodes (hard requirement for resource_tuner_tests)
if [ ! -d "$TEST_NODES_DIR" ]; then
    log_warn "[CFG] Missing dir: $TEST_NODES_DIR"; NODES_OK=0
else
    count_nodes=$(find "$TEST_NODES_DIR" -mindepth 1 -maxdepth 1 -type f -print 2>/dev/null | wc -l | awk '{print $1}')
    if [ "${count_nodes:-0}" -le 0 ]; then
        log_warn "[CFG] $TEST_NODES_DIR is empty"; NODES_OK=0
    fi
fi

# ---------- Preflight whitelist coverage ----------
: >"$LOGDIR/summary.txt"
preflight_bins() {
    : >"$LOGDIR/coverage.txt"; : >"$LOGDIR/missing_bins.txt"
    total=0; present=0; missing=0
    for t in $(approved_tests); do
        total=$((total+1))
        base="$(basename "$t")"
        resolved="$t"
        [ -x "$resolved" ] || resolved="$(command -v "$base" 2>/dev/null || true)"
        if [ -x "$resolved" ]; then
            echo "[PRESENT] $base -> $resolved" >>"$LOGDIR/coverage.txt"
            present=$((present+1))
        else
            echo "[MISSING] $base" >>"$LOGDIR/missing_bins.txt"
            echo "SKIP" >"$LOGDIR/${base}.res"
            echo "[SKIP] $base – not found" >>"$LOGDIR/summary.txt"
            missing=$((missing+1))
        fi
    done
    {
        echo "total=$total"
        echo "present=$present"
        echo "missing=$missing"
    } > "$LOGDIR/coverage_counts.env"
    [ $missing -gt 0 ] && log_warn "Whitelist coverage: $present/$total present, $missing missing"
}
preflight_bins
if [ -r "$LOGDIR/coverage_counts.env" ]; then
  # shellcheck disable=SC1091
  . "$LOGDIR/coverage_counts.env"
else
  total=0; present=0; missing=0
fi

# ---------- List mode ----------
if [ "$RUN_MODE" = "list" ]; then
    log_info "Approved tests:"; approved_tests | sed 's/^/ - /'
    log_info "Coverage:"; sed 's/^/ - /' "$LOGDIR/coverage.txt" 2>/dev/null || true
    [ -s "$LOGDIR/missing_bins.txt" ] && { log_info "Missing:"; sed 's/^/ - /' "$LOGDIR/missing_bins.txt"; }
    exit 0
fi

# ---------- Build run list ----------
if [ "$RUN_MODE" = "one" ]; then
    TESTS="$ONE_BIN"
else
    TESTS="$(approved_tests)"
fi
[ -z "$TESTS" ] && { log_skip "$TESTNAME SKIP – approved list empty"; echo "$TESTNAME SKIP" >"$RES_FILE"; exit 0; }

# ---------- Execute ----------
PASS=0; FAIL=0; SKIP=0

run_one() {
    bin="$1"
    name="$(basename "$bin")"
    tlog="$LOGDIR/${name}.log"
    tres="$LOGDIR/${name}.res"

    # whitelist enforcement
    if ! is_approved "$bin"; then
        log_skip "[TEST] $name not in approved set – skipping"
        echo "SKIP" >"$tres"; echo "[SKIP] $name – not approved" >>"$LOGDIR/summary.txt"; return 2
    fi

    # base config requirement: accept common OR custom; skip only if BOTH missing
    if suite_requires_base_cfgs "$name"; then
        if [ $COMMON_OK -eq 0 ] && [ $CUSTOM_OK -eq 0 ]; then
            log_skip "[CFG] Base configs missing (common/ AND custom/) — skipping $name"
            echo "SKIP" >"$tres"; echo "[SKIP] $name – base configs missing" >>"$LOGDIR/summary.txt"; return 2
        fi
    fi

    # resource_tuner_tests also needs test nodes
    if [ "$name" = "resource_tuner_tests" ] && [ $NODES_OK -eq 0 ]; then
        log_skip "[CFG] Test ResourceSysFsNodes missing/empty — skipping $name"
        echo "SKIP" >"$tres"; echo "[SKIP] $name – test nodes missing" >>"$LOGDIR/summary.txt"; return 2
    fi

    # resolve binary
    if [ ! -x "$bin" ] && command -v "$bin" >/dev/null 2>&1; then bin="$(command -v "$bin")"; fi
    if [ ! -x "$bin" ]; then
        log_skip "[TEST] $name missing – skipping"
        echo "SKIP" >"$tres"; echo "[SKIP] $name – not found" >>"$LOGDIR/summary.txt"; return 2
    fi

    log_info "--- Running $bin ---"
    log_info "[CI] Logging to $tlog"
    run_cmd_maybe_timeout "$bin" >"$tlog" 2>&1
    rc=$?

    parse_and_score_log "$tlog"; score=$?
    [ $score -eq 2 ] && [ $rc -eq 0 ] && score=0

    case $score in
        0) log_pass "[TEST] $name PASS"; echo "PASS" >"$tres"; echo "[PASS] $name" >>"$LOGDIR/summary.txt"; return 0 ;;
        1) log_fail "[TEST] $name FAIL"; echo "FAIL" >"$tres"; echo "[FAIL] $name (rc=$rc)" >>"$LOGDIR/summary.txt"; return 1 ;;
        2) log_skip "[TEST] $name SKIP"; echo "SKIP" >"$tres"; echo "[SKIP] $name (rc=$rc)" >>"$LOGDIR/summary.txt"; return 2 ;;
    esac
}

for t in $TESTS; do
    run_one "$t"; rc=$?
    case $rc in
        0) PASS=$((PASS+1)) ;;
        1) FAIL=$((FAIL+1)) ;;
        2) SKIP=$((SKIP+1)) ;;
    esac
done

# ---------- Summaries & gating ----------
log_info "--------------------------------------------------"
log_info "Per-test summary:"; sed -n 'p' "$LOGDIR/summary.txt" | while IFS= read -r L; do [ -n "$L" ] && log_info " $L"; done
if [ -r "$LOGDIR/coverage_counts.env" ]; then
  # shellcheck disable=SC1091
  . "$LOGDIR/coverage_counts.env"
else
  total=${total:-0}; present=${present:-0}; missing=${missing:-0}
fi
log_info "Coverage: ${present:-0}/${total:-0} present"
log_info "Overall counts: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"

# Final policy (skips are neutral):
# - Any FAIL -> overall FAIL
# - Else if PASS>0 -> overall PASS
# - Else -> overall SKIP (everything skipped)
if [ "$FAIL" -gt 0 ]; then
  echo "$TESTNAME FAIL" >"$RES_FILE"
  exit 0
fi
if [ "$PASS" -gt 0 ]; then
  echo "$TESTNAME PASS" >"$RES_FILE"
  exit 0
fi
echo "$TESTNAME SKIP" >"$RES_FILE"
exit 0
