#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

# --------- Robustly source init_env and functestlib.sh ----------
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
if [ -z "$__INIT_ENV_LOADED" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
fi
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"
# ---------------------------------------------------------------

TESTNAME="fastrpc_test"
RESULT_FILE="$TESTNAME.res"

# Defaults
REPEAT=1
TIMEOUT=""
ARCH=""
BIN_DIR="" # optional: where fastrpc_test lives
ASSETS_DIR="" # optional: parent containing linux/ etc
VERBOSE=0

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --arch <name> Architecture (only if explicitly provided)
  --bin-dir <path> Directory containing 'fastrpc_test' binary
  --assets-dir <path> Directory that CONTAINS 'linux/' (defaults to \$BINDIR, e.g. /usr/bin)
  --repeat <N> Number of repetitions (default: 1)
  --timeout <sec> Timeout for each run (no timeout if omitted)
  --verbose Extra logging for CI debugging
  --help Show this help

Notes:
- Default binary path is /usr/bin/fastrpc_test.
- /bin/fastrpc_test is used ONLY if ALLOW_BIN_FASTRPC=1 or you pass --bin-dir /bin.
- Default assets location prefers \$BINDIR/linux (so /usr/bin/linux).
- If --arch is omitted, the -a flag is not passed at all.
EOF
}

# --------------------- Parse arguments -------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --arch) ARCH="$2"; shift 2 ;;
        --bin-dir) BIN_DIR="$2"; shift 2 ;;
        --assets-dir) ASSETS_DIR="$2"; shift 2 ;;
        --repeat) REPEAT="$2"; shift 2 ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        --verbose) VERBOSE=1; shift ;;
        --help) usage; exit 0 ;;
        *) echo "[ERROR] Unknown argument: $1" >&2; usage; echo "$TESTNAME : FAIL" >"$RESULT_FILE"; exit 1 ;;
    esac
done

# ---------- Validation ----------
case "$REPEAT" in *[!0-9]*|"") log_error "Invalid --repeat: $REPEAT"; echo "$TESTNAME : FAIL" >"$RESULT_FILE"; exit 1 ;; esac
if [ -n "$TIMEOUT" ]; then
    case "$TIMEOUT" in *[!0-9]*|"") log_error "Invalid --timeout: $TIMEOUT"; echo "$TESTNAME : FAIL" >"$RESULT_FILE"; exit 1 ;; esac
fi

# Ensure we're in the testcase directory (repo convention)
test_path="$(find_test_case_by_name "$TESTNAME")" || {
    log_error "Cannot locate test path for $TESTNAME"
    echo "$TESTNAME : FAIL" >"$RESULT_FILE"
    exit 1
}
cd "$test_path" || {
    log_error "cd to test path failed: $test_path"
    echo "$TESTNAME : FAIL" >"$RESULT_FILE"
    exit 1
}

log_info "--------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"

# Small debug helper
log_debug() { [ "$VERBOSE" -eq 1 ] && log_info "[debug] $*"; }

# -------------------- Binary detection (default: /usr/bin) ----------------
FASTBIN=""
if [ -n "$BIN_DIR" ] && [ -x "$BIN_DIR/fastrpc_test" ]; then
    # Explicit override wins
    FASTBIN="$BIN_DIR/fastrpc_test"
elif [ -x /usr/bin/fastrpc_test ]; then
    FASTBIN="/usr/bin/fastrpc_test"
elif [ -x /bin/fastrpc_test ] && [ "${ALLOW_BIN_FASTRPC:-0}" = "1" ]; then
    FASTBIN="/bin/fastrpc_test"
    log_warn "ALLOW_BIN_FASTRPC=1: using /bin/fastrpc_test"
else
    log_fail "'fastrpc_test' not found in /usr/bin. Pass --bin-dir <dir> (or ALLOW_BIN_FASTRPC=1 to allow /bin)."
    echo "$TESTNAME : FAIL" >"$RESULT_FILE"
    exit 1
fi

if [ ! -x "$FASTBIN" ]; then
    log_fail "Binary not executable: $FASTBIN"
    echo "$TESTNAME : FAIL" >"$RESULT_FILE"
    exit 1
fi

BINDIR="$(dirname "$FASTBIN")"
log_info "Using binary: $FASTBIN"
log_debug "PATH=$PATH"
log_info "Binary details:"
# shellcheck disable=SC2012
log_info " ls -l: $(ls -l "$FASTBIN" 2>/dev/null || echo 'N/A')"
log_info " file : $(file "$FASTBIN" 2>/dev/null || echo 'N/A')"

# -------------------- Optional arch argument -------------------
# Use positional params trick so we don't misquote "-a <arch>"
set -- # clear "$@"
if [ -n "$ARCH" ]; then
    set -- -a "$ARCH"
    log_info "Arch option: -a $ARCH"
else
    log_info "No --arch provided; running without -a"
fi

# -------------------- Buffering tool availability ---------------
HAVE_STDBUF=0; command -v stdbuf >/dev/null 2>&1 && HAVE_STDBUF=1
HAVE_SCRIPT=0; command -v script >/dev/null 2>&1 && HAVE_SCRIPT=1
HAVE_TIMEOUT=0; command -v timeout >/dev/null 2>&1 && HAVE_TIMEOUT=1

buf_label="none"
if [ $HAVE_STDBUF -eq 1 ]; then
    buf_label="stdbuf -oL -eL"
elif [ $HAVE_SCRIPT -eq 1 ]; then
    buf_label="script -q"
fi

# ---------------- Assets directory resolution ------------------
# Prefer $BINDIR/linux (e.g., /usr/bin/linux); allow explicit --assets-dir.
RESOLVED_RUN_DIR=""
if [ -n "$ASSETS_DIR" ] && [ -d "$ASSETS_DIR/linux" ]; then
    RESOLVED_RUN_DIR="$ASSETS_DIR"
elif [ -d /usr/bin/linux ]; then
    RESOLVED_RUN_DIR="/usr/bin"
elif [ -d "$BINDIR/linux" ]; then
    RESOLVED_RUN_DIR="$BINDIR"
elif [ -d "$SCRIPT_DIR/linux" ]; then
    RESOLVED_RUN_DIR="$SCRIPT_DIR"
else
    RESOLVED_RUN_DIR="$BINDIR"
    log_warn "No 'linux/' assets found; running from $RESOLVED_RUN_DIR"
fi

# -------------------- Logging root -----------------------------
TS="$(date +%Y%m%d-%H%M%S)"
LOG_ROOT="./logs_${TESTNAME}_${TS}"
mkdir -p "$LOG_ROOT" || { log_error "Cannot create $LOG_ROOT"; echo "$TESTNAME : FAIL" >"$RESULT_FILE"; exit 1; }

tmo_label="none"; [ -n "$TIMEOUT" ] && tmo_label="${TIMEOUT}s"
log_info "Repeats: $REPEAT | Timeout: $tmo_label | Buffering: $buf_label"
log_info "Run dir: $RESOLVED_RUN_DIR"
log_debug "Run dir has linux?: $( [ -d "$RESOLVED_RUN_DIR/linux" ] && echo yes || echo no )"

# -------------------- Run loop ---------------------------------
PASS_COUNT=0
i=1
while [ "$i" -le "$REPEAT" ]; do
    iter_tag="iter$i"
    iter_log="$LOG_ROOT/${iter_tag}.out"
    iter_rc="$LOG_ROOT/${iter_tag}.rc"
    iso_now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    log_info "Running $iter_tag/$REPEAT | start: $iso_now | dir: $RESOLVED_RUN_DIR"

    # Base command (for logging only)
    # shellcheck disable=SC2145
    log_info "Executing: $FASTBIN -d 3 -U 1 -t linux $*"

    rc=127
    (
        cd "$RESOLVED_RUN_DIR" || exit 127

        if [ $HAVE_STDBUF -eq 1 ]; then
            # Prefer line-buffered stdout/stderr when available
            # run_with_timeout from functestlib.sh wraps timeout if TIMEOUT is set
            run_with_timeout "$TIMEOUT" stdbuf -oL -eL "$FASTBIN" -d 3 -U 1 -t linux "$@"

        elif [ $HAVE_SCRIPT -eq 1 ]; then
            # script(1) fallback to get unbuffered-ish output
            if [ -n "$TIMEOUT" ] && [ $HAVE_TIMEOUT -eq 1 ]; then
                script -q -c "timeout $TIMEOUT $FASTBIN -d 3 -U 1 -t linux $*" /dev/null
            else
                script -q -c "$FASTBIN -d 3 -U 1 -t linux $*" /dev/null
            fi

        else
            # Plain execution (still via run_with_timeout if available)
            run_with_timeout "$TIMEOUT" "$FASTBIN" -d 3 -U 1 -t linux "$@"
        fi
    ) >"$iter_log" 2>&1
    rc=$?

    printf '%s\n' "$rc" >"$iter_rc"

    if [ -s "$iter_log" ]; then
        echo "----- $iter_tag output begin -----"
        cat "$iter_log"
        echo "----- $iter_tag output end -----"
    fi

    if [ "$rc" -ne 0 ]; then
        log_fail "$iter_tag: fastrpc_test exited $rc (see $iter_log)"
    fi

    if grep -q "All tests completed successfully" "$iter_log"; then
        PASS_COUNT=$((PASS_COUNT+1))
        log_pass "$iter_tag: success"
    else
        log_warn "$iter_tag: success pattern not found"
    fi

    i=$((i+1))
done

# -------------------- Finalize --------------------------------
if [ "$PASS_COUNT" -eq "$REPEAT" ]; then
    log_pass "$TESTNAME : Test Passed ($PASS_COUNT/$REPEAT)"
    echo "$TESTNAME : PASS" > "$RESULT_FILE"
else
    log_fail "$TESTNAME : Test Failed ($PASS_COUNT/$REPEAT)"
    echo "$TESTNAME : FAIL" > "$RESULT_FILE"
fi

# Failsafe: ensure the .res file exists for CI/LAVA consumption
[ -f "$RESULT_FILE" ] || {
    log_error "Missing result file ($RESULT_FILE) — creating FAIL"
    echo "$TESTNAME : FAIL" >"$RESULT_FILE"
}

exit 0
