#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
# --- Robustly find and source init_env ---------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INIT_ENV=""
SEARCH="$SCRIPT_DIR"
while [ "$SEARCH" != "/" ]; do
    if [ -f "$SEARCH/init_env" ]; then
        INIT_ENV="$SEARCH/init_env"; break
    fi
    SEARCH=$(dirname "$SEARCH")
done
[ -z "$INIT_ENV" ] && echo "[ERROR] Could not find init_env (starting at $SCRIPT_DIR)" >&2 && exit 1

# shellcheck disable=SC1090
[ -z "$__INIT_ENV_LOADED" ] && . "$INIT_ENV"
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="Camera_RDI_FrameCapture"
RES_FILE="./$TESTNAME.res"
test_path="$(find_test_case_by_name "$TESTNAME")"
cd "$test_path" || exit 1

print_usage() {
    cat <<EOF
Usage: $0 [--format <v4l2_fmt1,v4l2_fmt2,...>] [--frames <count>] [--help]

Options:
  --format <v4l2_fmt1,v4l2_fmt2,...> Test one or more comma-separated formats (e.g., UYVY,NV12)
  --frames <count> Number of frames to capture per pipeline (default: 10)
  --help Show this help message
EOF
}

log_info "----------------------------------------------------------------------"
log_info "------------------- Starting $TESTNAME Testcase ----------------------"
log_info "=== Test Initialization ==="

# --------- Argument Parsing ---------
USER_FORMAT=""
FRAMES=10
while [ $# -gt 0 ]; do
    case "$1" in
        --format) shift; USER_FORMAT="$1" ;;
        --frames) shift; FRAMES="$1" ;;
        --help) print_usage; exit 0 ;;
        *) log_error "Unknown argument: $1"; print_usage; exit 1 ;;
    esac
    shift
done

# Helper: print planned media-ctl / yavta sequence for CI logs
print_planned_commands() {
    media_node="$1"
    pixfmt="$2"

    log_info "[CI] Planned sequence:"
    log_info " media-ctl -d $media_node --reset"

    # media-ctl -V (show with possible TARGET_FORMAT substitution exactly like configure helper does)
    if [ -n "$MEDIA_CTL_V_LIST" ]; then
        printf '%s\n' "$MEDIA_CTL_V_LIST" | while IFS= read -r vline; do
            [ -z "$vline" ] && continue
            vline_out="$(printf '%s' "$vline" | sed -E "s/fmt:[^/]+\/([0-9]+x[0-9]+)/fmt:${pixfmt}\/\1/g")"
            log_info " media-ctl -d $media_node -V '$vline_out'"
        done
    fi
    # media-ctl -l
    if [ -n "$MEDIA_CTL_L_LIST" ]; then
        printf '%s\n' "$MEDIA_CTL_L_LIST" | while IFS= read -r lline; do
            [ -z "$lline" ] && continue
            log_info " media-ctl -d $media_node -l '$lline'"
        done
    fi
    # yavta control writes (pre)
    if [ -n "$YAVTA_CTRL_PRE_LIST" ]; then
        printf '%s\n' "$YAVTA_CTRL_PRE_LIST" | while IFS= read -r ctrl; do
            [ -z "$ctrl" ] && continue
            dev="$(printf '%s' "$ctrl" | awk '{print $1}')"
            reg="$(printf '%s' "$ctrl" | awk '{print $2}')"
            val="$(printf '%s' "$ctrl" | awk '{print $3}')"
            [ -n "$dev" ] && [ -n "$reg" ] && [ -n "$val" ] && \
              log_info " yavta --no-query -w '$reg $val' $dev"
        done
    fi
    # main yavta capture (dimensions may be empty occasionally)
    size_arg=""
    if [ -n "$YAVTA_W" ] && [ -n "$YAVTA_H" ]; then
        size_arg="-s ${YAVTA_W}x${YAVTA_H}"
    fi
    if [ -n "$YAVTA_DEV" ]; then
        log_info " yavta -B capture-mplane -c -I -n $FRAMES -f $pixfmt $size_arg -F $YAVTA_DEV --capture=$FRAMES --file='frame-#.bin'"
    fi
    # yavta control writes (post)
    if [ -n "$YAVTA_CTRL_POST_LIST" ]; then
        printf '%s\n' "$YAVTA_CTRL_POST_LIST" | while IFS= read -r ctrl; do
            [ -z "$ctrl" ] && continue
            dev="$(printf '%s' "$ctrl" | awk '{print $1}')"
            reg="$(printf '%s' "$ctrl" | awk '{print $2}')"
            val="$(printf '%s' "$ctrl" | awk '{print $3}')"
            [ -n "$dev" ] && [ -n "$reg" ] && [ -n "$val" ] && \
              log_info " yavta --no-query -w '$reg $val' $dev"
        done
    fi
}

# --------- DT Precheck ---------
if ! dt_confirm_node_or_compatible "isp" "cam" "camss"; then
    log_skip "$TESTNAME SKIP – No ISP/camera node/compatible found in DT"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

# --------- Kernel config sanity (MANDATORY bits only gate if totally absent) ---------
log_info "[CONFIG] Expect at least: CONFIG_VIDEO_QCOM_CAMSS=y (or =m)"
check_kernel_config "CONFIG_VIDEO_QCOM_CAMSS CONFIG_MEDIA_CONTROLLER CONFIG_V4L2_FWNODE" \
  || log_warn "[CONFIG] One or more options missing; will continue if CAMSS stack is otherwise present"

# Optional visibility: print any CAMCC entries (name varies by tree)
if ! check_kernel_config "CONFIG_QCOM_CAMCC_SC7280"; then
    if command -v zgrep >/dev/null 2>&1; then
        CAMCC_SYMS="$(zgrep -E '^CONFIG_.*CAMCC.*=(y|m)' /proc/config.gz 2>/dev/null || true)"
    else
        CAMCC_SYMS="$(gzip -dc /proc/config.gz 2>/dev/null | grep -E '^CONFIG_.*CAMCC.*=(y|m)' || true)"
    fi
    if [ -n "$CAMCC_SYMS" ]; then
        printf '%s\n' "$CAMCC_SYMS" | while IFS= read -r s; do
            [ -n "$s" ] && log_info "[CONFIG] $s"
        done
    fi
fi

# --------- Broader readiness gate (module OR builtin OR nodes OR dmesg) ---------
DMESG_CACHE="$(dmesg 2>/dev/null || true)"

if [ -e /dev/media0 ] || [ -e /dev/video0 ]; then
    log_pass "[READY] Media/video nodes present:"
    for f in /dev/media* /dev/video*; do
        [ -e "$f" ] || continue
        log_info " - $f"
    done
elif is_module_loaded qcom_camss; then
    log_pass "[READY] qcom_camss module loaded"
elif [ -d /sys/module/qcom_camss ]; then
    log_pass "[READY] qcom_camss present as builtin"
elif printf '%s\n' "$DMESG_CACHE" | grep -qiE 'qcom[-_]camss'; then
    log_info "[READY] CAMSS messages found in dmesg (likely builtin)"
else
    log_skip "Camera_RDI_FrameCapture SKIP – CAMSS driver not present (module or built-in)"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

# --------- Module inventory (visibility only; no gating) ---------
MODULES_LIST="qcom_camss camcc_sc7280 videodev mc v4l2_fwnode v4l2_async videobuf2_common videobuf2_v4l2 videobuf2_dma_contig videobuf2_dma_sg videobuf2_memops"

present_mods=""
builtin_mods=""
missing_mods=""
for m in $MODULES_LIST; do
    if is_module_loaded "$m"; then
        present_mods="$present_mods $m"
    elif [ -d "/sys/module/$m" ]; then
        builtin_mods="$builtin_mods $m"
    else
        missing_mods="$missing_mods $m"
    fi
done

if [ -n "$present_mods" ]; then
    log_pass "[MODULES] Loaded:"
    for m in $present_mods; do [ -n "$m" ] && log_info " - $m"; done
fi
if [ -n "$builtin_mods" ]; then
    log_info "[MODULES] Built-in:"
    for m in $builtin_mods; do [ -n "$m" ] && log_info " - $m"; done
fi
if [ -n "$missing_mods" ]; then
    log_warn "[MODULES] Not found:"
    for m in $missing_mods; do [ -n "$m" ] && log_info " - $m"; done
fi

# Sensor modules (best-effort)
SENSOR_MODS="$(awk '{print $1}' /proc/modules 2>/dev/null | grep -E '^(imx|ov|gc|ar)[0-9]+' | tr '\n' ' ')"
[ -n "$SENSOR_MODS" ] && { log_info "[MODULES] Sensors:"; for s in $SENSOR_MODS; do log_info " - $s"; done; }

# --------- Dmesg probe errors (non-benign filter) ---------
DRIVER_MOD="qcom_camss"
DMESG_MODULES='qcom_camss|camss|isp'
DMESG_EXCLUDE='dummy regulator|supply [^ ]+ not found|using dummy regulator|Failed to create device link|reboot-mode.*-EEXIST|can.t register reboot mode'
if scan_dmesg_errors "$SCRIPT_DIR" "$DMESG_MODULES" "$DMESG_EXCLUDE"; then
    log_skip "$TESTNAME SKIP – $DRIVER_MOD probe errors detected in dmesg"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

# --------- Dependency Checks ---------
check_dependencies media-ctl yavta python3 v4l2-ctl || {
    log_skip "$TESTNAME SKIP – Required tools missing"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
}

# --------- Media Node Detection ---------
MEDIA_NODE="$(detect_media_node)"
if [ -z "$MEDIA_NODE" ]; then
    log_skip "$TESTNAME SKIP – Media node not found"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi
log_info "Detected media node: $MEDIA_NODE"

# Light-touch global reset once
media-ctl -d "$MEDIA_NODE" -r >/dev/null 2>&1 || true
log_info "Media graph reset (-r) done on $MEDIA_NODE"
sleep 0.2

# --------- Pipeline Detection (Python) ---------
TOPO_FILE="$(mktemp "/tmp/${TESTNAME}_topo.XXXXXX")"
TMP_PIPELINES_FILE="$(mktemp "/tmp/${TESTNAME}_blocks.XXXXXX")"
trap 'rm -f "$TOPO_FILE" "$TMP_PIPELINES_FILE"' EXIT

media-ctl -p -d "$MEDIA_NODE" >"$TOPO_FILE" 2>/dev/null
PYTHON_PIPELINES="$(run_camera_pipeline_parser "$TOPO_FILE")"
if [ -z "$PYTHON_PIPELINES" ]; then
    log_skip "$TESTNAME SKIP – No valid pipelines found"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi
printf '%s\n' "$PYTHON_PIPELINES" >"$TMP_PIPELINES_FILE"

log_info "User format override: ${USER_FORMAT:-<none>}"
log_info "Frame count per pipeline: $FRAMES"

# --------- Pipeline Processing (core logic unchanged) ---------
PASS=0; FAIL=0; SKIP=0; COUNT=0
block=""
while IFS= read -r line || [ -n "$line" ]; do
    if [ "$line" = "--" ]; then
        COUNT=$((COUNT+1))
        TMP="/tmp/cam_block.$$.$COUNT"
        printf '%s\n' "$block" > "$TMP"

        # Parses block and sets SENSOR, VIDEO, YAVTA_DEV, YAVTA_FMT, MEDIA_CTL_* lists, etc.
        parse_pipeline_block "$TMP"
        rm -f "$TMP"

        # -------- Multi-format support (POSIX style, no arrays) --------
        FORMATS_LIST="$USER_FORMAT"
        [ -z "$FORMATS_LIST" ] && FORMATS_LIST="$YAVTA_FMT"

        OLD_IFS="$IFS"; IFS=','
        for FMT_OVERRIDE in $FORMATS_LIST; do
            FMT_OVERRIDE="$(printf '%s' "$FMT_OVERRIDE" | sed 's/^ *//;s/ *$//')"
            TARGET_FORMAT="$FMT_OVERRIDE"; [ -z "$TARGET_FORMAT" ] && TARGET_FORMAT="$YAVTA_FMT"

            # New banner: show pad mbus fmt and video pixfmt
            PAD_MBUS_FMT="$(printf '%s\n' "$MEDIA_CTL_V_LIST" | sed -n 's/.*fmt:\([^/]]*\)\/.*/\1/p' | head -n1)"
            [ -z "$PAD_MBUS_FMT" ] && PAD_MBUS_FMT="auto"
            log_info "----- Pipeline $COUNT: ${SENSOR:-unknown} $VIDEO [pads:$PAD_MBUS_FMT] [video:$TARGET_FORMAT] -----"

            if [ -z "$VIDEO" ] || [ "$VIDEO" = "None" ] || [ -z "$YAVTA_DEV" ]; then
                log_skip "$SENSOR: Invalid pipeline – skipping"
                SKIP=$((SKIP+1))
                continue
            fi

            # CI debug: print the exact commands we will run
            print_planned_commands "$MEDIA_NODE" "$TARGET_FORMAT"

            # Configure & capture (original helpers)
            configure_pipeline_block "$MEDIA_NODE" "$TARGET_FORMAT"
            execute_capture_block "$FRAMES" "$TARGET_FORMAT"
            RET=$?

            # Safety net retry
            if [ "$RET" -ne 0 ]; then
                log_warn "First attempt failed; resetting media graph and retrying once"
                log_info " media-ctl -d $MEDIA_NODE -r"
                media-ctl -d "$MEDIA_NODE" -r >/dev/null 2>&1 || true
                sleep 0.1
                print_planned_commands "$MEDIA_NODE" "$TARGET_FORMAT"
                configure_pipeline_block "$MEDIA_NODE" "$TARGET_FORMAT"
                execute_capture_block "$FRAMES" "$TARGET_FORMAT"
                RET=$?
            fi

            case "$RET" in
                0) log_pass "$SENSOR $VIDEO $TARGET_FORMAT PASS"; PASS=$((PASS+1)) ;;
                1) log_fail "$SENSOR $VIDEO $TARGET_FORMAT FAIL (capture failed)"; FAIL=$((FAIL+1)) ;;
                2) log_skip "$SENSOR $VIDEO $TARGET_FORMAT SKIP (unsupported format)"; SKIP=$((SKIP+1)) ;;
                3) log_skip "$SENSOR $VIDEO missing data – skipping"; SKIP=$((SKIP+1)) ;;
            esac
        done
        IFS="$OLD_IFS"
        block=""
    else
        if [ -z "$block" ]; then block="$line"; else block="$block
$line"; fi
    fi
done < "$TMP_PIPELINES_FILE"

log_info "Test Summary: Passed: $PASS, Failed: $FAIL, Skipped: $SKIP"
if [ "$PASS" -gt 0 ]; then
    echo "$TESTNAME PASS" >"$RES_FILE"
elif [ "$FAIL" -gt 0 ]; then
    echo "$TESTNAME FAIL" >"$RES_FILE"
else
    echo "$TESTNAME SKIP" >"$RES_FILE"
fi
exit 0
