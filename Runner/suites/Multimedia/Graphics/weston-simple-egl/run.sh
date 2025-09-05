#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
# Validate weston-simple-egl runs under a working Wayland session.
# - Robust Wayland env resolution (adopts socket & fixes XDG_RUNTIME_DIR perms)
# - CI-friendly logs and PASS/FAIL semantics
# - Optional FPS parsing if build prints it (lenient if not present)

# ---------- Source init_env and functestlib ----------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INIT_ENV=""
SEARCH="$SCRIPT_DIR"
while [ "$SEARCH" != "/" ]; do
  if [ -f "$SEARCH/init_env" ]; then INIT_ENV="$SEARCH/init_env"; break; fi
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

TESTNAME="weston-simple-egl"
# Tunables (env override)
DURATION="${DURATION:-30s}" # how long to run the client
STOP_GRACE="${STOP_GRACE:-3s}" # grace period on stop
EXPECT_FPS="${EXPECT_FPS:-60}" # nominal refresh (used for logging)
FPS_TOL_PCT="${FPS_TOL_PCT:-10}" # +/- tolerance %
REQUIRE_FPS="${REQUIRE_FPS:-0}" # 1=require FPS lines & threshold; 0=best effort

test_path="$(find_test_case_by_name "$TESTNAME" 2>/dev/null || echo "$SCRIPT_DIR")"
cd "$test_path" || exit 1
RES_FILE="./$TESTNAME.res"
LOG_FILE="./${TESTNAME}_run.log"
rm -f "$RES_FILE" "$LOG_FILE"

log_info "--------------------------------------------------------------------------"
log_info "------------------- Starting $TESTNAME Testcase --------------------------"
# FIX #1: Use ASCII '+/-' and keep it in a normal string
log_info "Config: DURATION=$DURATION STOP_GRACE=$STOP_GRACE EXPECT_FPS=${EXPECT_FPS}+/-${FPS_TOL_PCT}% REQUIRE_FPS=$REQUIRE_FPS"

# Dependencies
check_dependencies weston-simple-egl || {
  log_fail "$TESTNAME : weston-simple-egl binary not found in PATH"
  echo "$TESTNAME SKIP" > "$RES_FILE"
  exit 0
}
BIN="$(command -v weston-simple-egl 2>/dev/null || true)"
log_info "Using weston-simple-egl: ${BIN:-<none>}"

# Resolve Wayland socket:
# 1) If current env points to a real socket, use it.
sock=""
if [ -n "$XDG_RUNTIME_DIR" ] && [ -n "$WAYLAND_DISPLAY" ] && [ -e "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]; then
  sock="$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"
fi

# 2) Otherwise, scan common locations.
if [ -z "$sock" ]; then
  for s in $(find_wayland_sockets); do
    if [ -e "$s" ]; then sock="$s"; break; fi
  done
fi

# 3) If still no socket, try to start Weston and wait a bit.
if [ -z "$sock" ]; then
  if weston_is_running; then
    log_warn "Weston running but no Wayland socket visible; attempting to continue."
  else
    log_info "Weston not running. Attempting to start..."
    weston_start
  fi
  # Wait for socket to appear (up to ~5s)
  n=0
  while [ $n -lt 5 ] && [ -z "$sock" ]; do
    for s in $(find_wayland_sockets); do
      if [ -e "$s" ]; then sock="$s"; break; fi
    done
    [ -n "$sock" ] && break
    sleep 1
    n=$((n+1))
  done
fi

if [ -z "$sock" ]; then
  log_fail "$TESTNAME : FAIL (no Wayland socket found after attempting to start Weston)"
  echo "$TESTNAME FAIL" > "$RES_FILE"
  exit 1
fi

# Adopt env and fix runtime dir perms (done inside helper(s))
adopt_wayland_env_from_socket "$sock"

# FIX #2: Avoid duplicate prints — helpers can log the chosen socket/env once.
# If your helpers are quiet instead, uncomment the two lines below:
# log_info "Selected Wayland socket: $sock"
# log_info "Wayland env: XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR WAYLAND_DISPLAY=$WAYLAND_DISPLAY"

if wayland_connection_ok; then
  log_info "Wayland connection test: OK (wayland-info/env)"
else
  log_fail "$TESTNAME : FAIL (Wayland connection test failed)"
  print_path_meta "$XDG_RUNTIME_DIR" | sed 's/^/[DBG] /'
  stat "$XDG_RUNTIME_DIR" 2>/dev/null | sed 's/^/[DBG] /' || true
  echo "$TESTNAME FAIL" > "$RES_FILE"
  exit 1
fi

# Try to enable FPS prints if supported by the client build (best effort).
export SIMPLE_EGL_FPS=1
export WESTON_SIMPLE_EGL_FPS=1

# Run the client for DURATION with a stopwatch for CI logs.
log_info "Running weston-simple-egl for $DURATION ..."
start_ts="$(date +%s 2>/dev/null || echo 0)"
if command -v run_with_timeout >/dev/null 2>&1; then
  run_with_timeout "$DURATION" weston-simple-egl >"$LOG_FILE" 2>&1
  rc=$?
else
  if command -v timeout >/dev/null 2>&1; then
    timeout "$DURATION" weston-simple-egl >"$LOG_FILE" 2>&1
    rc=$?
  else
    # Last resort: background and sleep.
    sh -c 'weston-simple-egl' >"$LOG_FILE" 2>&1 &
    pid=$!
    # DURATION like "30s" → "30"
    dur_s="$(printf '%s' "$DURATION" | sed -n 's/^\([0-9][0-9]*\)s$/\1/p')"
    [ -z "$dur_s" ] && dur_s="$DURATION"
    sleep "$dur_s"
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    rc=143
  fi
fi
end_ts="$(date +%s 2>/dev/null || echo 0)"
elapsed=$(( end_ts - start_ts ))
[ "$elapsed" -lt 0 ] && elapsed=0

# FPS parsing (best effort)
fps="-"
fps_line="$(grep -E '([Ff][Pp][Ss]|frames per second|^fps:)' "$LOG_FILE" 2>/dev/null | tail -n 1)"
if [ -n "$fps_line" ]; then
  # Extract last numeric token (integer or float)
  fps="$(printf '%s\n' "$fps_line" | awk '{
      for (i=NF;i>=1;i--) if ($i ~ /^[0-9]+(\.[0-9]+)?$/) {print $i; exit}
    }')"
  [ -z "$fps" ] && fps="-"
fi

# CI debugging summary
log_info "Result summary: rc=$rc elapsed=${elapsed}s fps=${fps} (expected ~${EXPECT_FPS}+/-${FPS_TOL_PCT}%)"
# Quick duration gate: must have run at least (DURATION-1) seconds to be considered OK.
dur_s="$(printf '%s' "$DURATION" | sed -n 's/^\([0-9][0-9]*\)s$/\1/p')"
[ -z "$dur_s" ] && dur_s="$DURATION"
min_ok=$(( dur_s - 1 ))
[ "$min_ok" -lt 0 ] && min_ok=0

final="PASS"

if [ "$elapsed" -lt "$min_ok" ]; then
  final="FAIL"
  log_fail "$TESTNAME : FAIL (exited after ${elapsed}s; expected ~${dur_s}s) — rc=$rc"
fi

# Optional FPS gate
if [ "$final" = "PASS" ] && [ "$REQUIRE_FPS" -eq 1 ]; then
  if [ "$fps" = "-" ]; then
    final="FAIL"
    log_fail "$TESTNAME : FAIL (no FPS lines found but REQUIRE_FPS=1)"
  else
    # Integer-only tolerance check (portable)
    lo=$(( (EXPECT_FPS * (100 - FPS_TOL_PCT)) / 100 ))
    hi=$(( (EXPECT_FPS * (100 + FPS_TOL_PCT)) / 100 ))
    fps_int="$(printf '%s' "$fps" | cut -d. -f1)"
    if [ "$fps_int" -lt "$lo" ] || [ "$fps_int" -gt "$hi" ]; then
      final="FAIL"
      log_fail "$TESTNAME : FAIL (fps=$fps outside ${lo}-${hi})"
    fi
  fi
fi

case "$final" in
  PASS)
    log_pass "$TESTNAME : PASS"
    echo "$TESTNAME PASS" > "$RES_FILE"
    exit 0
    ;;
  *)
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 1
    ;;
esac
