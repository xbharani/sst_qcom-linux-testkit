#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
# Common, POSIX-compliant helpers for Qualcomm video stack selection and V4L2 testing.
# Requires functestlib.sh: log_info/log_warn/log_pass/log_fail/log_skip,
# check_dependencies, extract_tar_from_url, (optional) run_with_timeout, ensure_network_online.

# -----------------------------------------------------------------------------
# Public env knobs (may be exported by caller or set via CLI in run.sh)
# -----------------------------------------------------------------------------
# VIDEO_STACK auto|upstream|downstream|base|overlay|up|down (default: auto)
# VIDEO_PLATFORM lemans|monaco|kodiak|"" (auto-detect)
# TAR_URL bundle for input clips (used by video_ensure_clips_present_or_fetch)
# VIDEO_APP path to iris_v4l2_test (default /usr/bin/iris_v4l2_test)

# -----------------------------------------------------------------------------
# Constants / tool paths
# -----------------------------------------------------------------------------
IRIS_UP_MOD="qcom_iris"
IRIS_VPU_MOD="iris_vpu"
VENUS_CORE_MOD="venus_core"
VENUS_DEC_MOD="venus_dec"
VENUS_ENC_MOD="venus_enc"

# We purposely avoid persistent blacklist here (no /etc changes).
# Session-only blocks live under /run/modprobe.d
RUNTIME_BLOCK_DIR="/run/modprobe.d"

# Firmware path for Kodiak downstream blob
FW_PATH_KODIAK="/lib/firmware/qcom/vpu/vpu20_p1_gen2.mbn"
: "${FW_BACKUP_DIR:=/opt}"

MODPROBE="$(command -v modprobe 2>/dev/null || printf '%s' /sbin/modprobe)"
LSMOD="$(command -v lsmod 2>/dev/null || printf '%s' /sbin/lsmod)"

# Default app path (caller may override via env)
VIDEO_APP="${VIDEO_APP:-/usr/bin/iris_v4l2_test}"

# -----------------------------------------------------------------------------
# Tiny utils
# -----------------------------------------------------------------------------
video_exist_cmd() { command -v "$1" >/dev/null 2>&1; }

video_warn_if_not_root() {
    uid="$(id -u 2>/dev/null || printf '%s' 1)"
    if [ "$uid" -ne 0 ] 2>/dev/null; then
        log_warn "Not running as root; module/blacklist operations may fail."
    fi
}

video_has_module_loaded() {
    "$LSMOD" 2>/dev/null | awk '{print $1}' | grep -q "^$1$"
}

video_devices_present() {
    set -- /dev/video* 2>/dev/null
    [ -e "$1" ]
}

video_step() {
    id="$1"; msg="$2"
    if [ -n "$id" ]; then log_info "[$id] STEP: $msg"; else log_info "STEP: $msg"; fi
}

# -----------------------------------------------------------------------------
# Optional: log firmware hint after reload
# -----------------------------------------------------------------------------
video_log_fw_hint() {
    if video_exist_cmd dmesg; then
        out="$(dmesg 2>/dev/null | tail -n 200 | grep -Ei 'firmware|iris_vpu|venus' | tail -n 10)"
        if [ -n "$out" ]; then
            printf '%s\n' "$out" | while IFS= read -r ln; do log_info "dmesg: $ln"; done
        fi
    fi
}

# -----------------------------------------------------------------------------
# Shared module introspection helpers (kept; used by dump)
# -----------------------------------------------------------------------------
video_insmod_with_deps() {
    # Takes a logical module name (e.g. qcom_iris), resolves the path, then insmods deps+module
    m="$1"

    # Resolve file path first (handles hyphen/underscore and updates/)
    path="$(video_find_module_file "$m")" || path=""
    if [ -z "$path" ] || [ ! -f "$path" ]; then
        log_warn "insmod fallback: could not locate module file for $m"
        return 1
    fi

    # Load dependencies from the FILE (not the modname), then the module itself
    deps=""
    if video_exist_cmd modinfo; then
        deps="$(modinfo -F depends "$path" 2>/dev/null | tr ',' ' ' | tr -s ' ')"
    fi

    for d in $deps; do
        [ -z "$d" ] && continue
        video_has_module_loaded "$d" && continue
        # Try modprobe first (cheap), then insmod fallback by resolving its path
        if ! "$MODPROBE" -q "$d" 2>/dev/null; then
            dpath="$(video_find_module_file "$d")" || dpath=""
            if [ -n "$dpath" ] && [ -f "$dpath" ]; then
                insmod "$dpath" 2>/dev/null || true
            fi
        fi
    done

    insmod "$path" 2>/dev/null && return 0
    log_warn "insmod failed for $path"
    return 1
}

video_modprobe_dryrun() {
    m="$1"
    out=$("$MODPROBE" -n "$m" 2>/dev/null)
    if [ -n "$out" ]; then
        printf '%s\n' "$out" | while IFS= read -r ln; do log_info "modprobe -n $m: $ln"; done
    else
        log_info "modprobe -n $m:"
    fi
}

video_list_runtime_blocks() {
    found=0
    for f in "$RUNTIME_BLOCK_DIR"/*.conf; do
        [ -e "$f" ] || continue
        if grep -Eiq '(^|[[:space:]])(blacklist|install)[[:space:]]+(qcom[-_]iris|iris[-_]vpu|venus[-_](core|dec|enc))' "$f" 2>/dev/null; then
            log_info "$f"
            found=1
        fi
    done
    [ "$found" -eq 0 ] && log_info "(none)"
}

video_dump_stack_state() {
    when="$1" # pre|post
    log_info "Modules ($when):"
    log_info "lsmod (iris/venus):"
    "$LSMOD" 2>/dev/null | awk 'NR==1 || $1 ~ /^(iris_vpu|qcom_iris|venus_core|venus_dec|venus_enc)$/ {print}'
    video_modprobe_dryrun qcom_iris
    video_modprobe_dryrun iris_vpu
    video_modprobe_dryrun venus_core
    video_modprobe_dryrun venus_dec
    video_modprobe_dryrun venus_enc
    log_info "runtime blocks:"
    video_list_runtime_blocks
}

video_find_module_file() {
    # Resolve a module file path for a logical mod name (handles _ vs -).
    # Prefers: modinfo -n, then .../updates/, then general search.
    m="$1"
    kr="$(uname -r 2>/dev/null)"
    if [ -z "$kr" ]; then
        kr="$(find /lib/modules -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | head -n1)"
    fi

    # Try modinfo database first
    if video_exist_cmd modinfo; then
        p="$(modinfo -n "$m" 2>/dev/null)"
        if [ -n "$p" ] && [ -f "$p" ]; then
            printf '%s\n' "$p"
            return 0
        fi
    fi

    # Fall back to name variants
    m_us="$m"
    m_hy="$(printf '%s' "$m" | tr '_' '-')"
    m_alt="$(printf '%s' "$m" | tr '-' '_')"

    # Prefer updates directory if present
    for pat in "$m_us" "$m_hy" "$m_alt"; do
        p="$(find "/lib/modules/$kr/updates" -type f -name "${pat}.ko*" 2>/dev/null | head -n 1)"
        [ -n "$p" ] && { printf '%s\n' "$p"; return 0; }
    done

    # General search under this kernel’s tree
    for pat in "$m_us" "$m_hy" "$m_alt"; do
        p="$(find "/lib/modules/$kr" -type f -name "${pat}.ko*" 2>/dev/null | head -n 1)"
        [ -n "$p" ] && { printf '%s\n' "$p"; return 0; }
    done

    # Very last-ditch: fuzzy search for *iris* matches to help logs
    p="$(find "/lib/modules/$kr" -type f -name '*iris*.ko*' 2>/dev/null | head -n 1)"
    [ -n "$p" ] && { printf '%s\n' "$p"; return 0; }

    return 1
}

# Back-compat aliases so existing callers keep working
modprobe_dryrun() { video_modprobe_dryrun "$@"; }
list_runtime_blocks() { video_list_runtime_blocks "$@"; }
dump_stack_state() { video_dump_stack_state "$@"; }

# -----------------------------------------------------------------------------
# Runtime-only (session) block/unblock: lives under /run/modprobe.d
# -----------------------------------------------------------------------------
video_block_mod_now() {
    # usage: video_block_mod_now qcom_iris [iris_vpu ...]
    mkdir -p "$RUNTIME_BLOCK_DIR" 2>/dev/null || true
    for m in "$@"; do
        printf 'install %s /bin/false\n' "$m" > "$RUNTIME_BLOCK_DIR/${m}-block.conf"
    done
    depmod -a 2>/dev/null || true
}

video_unblock_mod_now() {
    # usage: video_unblock_mod_now qcom_iris [iris_vpu ...]
    for m in "$@"; do rm -f "$RUNTIME_BLOCK_DIR/${m}-block.conf"; done
    depmod -a 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# Persistent de-blacklist for a module (handles qcom_iris ↔ qcom-iris)
# Removes:
# - "blacklist <mod>" lines
# - "install <mod> /bin/false" lines
# in /etc/modprobe.d and /lib/modprobe.d, for both _ and - spellings.
# Also clears runtime /run/modprobe.d/<mod>-block.conf files.
# -----------------------------------------------------------------------------
video_persistent_unblock_module() {
    m="$1"
    [ -n "$m" ] || return 0

    m_us="$(printf '%s' "$m" | tr '-' '_')"
    m_hy="$(printf '%s' "$m" | tr '_' '-')"

    # Clear runtime install-blocks (best effort)
    if command -v video_unblock_mod_now >/dev/null 2>&1; then
        video_unblock_mod_now "$m_us" "$m_hy"
    else
        rm -f "/run/modprobe.d/${m_us}-block.conf" "/run/modprobe.d/${m_hy}-block.conf" 2>/dev/null || true
    fi

    # Scrub persistent blacklists and install-/bin/false overrides
    for d in /etc/modprobe.d /lib/modprobe.d; do
        [ -d "$d" ] || continue
        for f in "$d"/*.conf; do
            [ -e "$f" ] || continue
            tmp="$f.tmp.$$"
            # Keep every line that does NOT match our blacklist/install patterns
            awk -v a="$m_us" -v b="$m_hy" '
                BEGIN { IGNORECASE=1 }
                {
                    line = $0
                    bl1 = "^[[:space:]]*blacklist[[:space:]]*" a "([[:space:]]|$)"
                    bl2 = "^[[:space:]]*blacklist[[:space:]]*" b "([[:space:]]|$)"
                    in1 = "^[[:space:]]*install[[:space:]]*" a "([[:space:]]|$).*[/]bin[/]false"
                    in2 = "^[[:space:]]*install[[:space:]]*" b "([[:space:]]|$).*[/]bin[/]false"
                    if (line ~ bl1 || line ~ bl2 || line ~ in1 || line ~ in2) next
                    print line
                }
            ' "$f" >"$tmp" 2>/dev/null || { rm -f "$tmp" >/dev/null 2>&1; continue; }
            mv "$tmp" "$f"
        done
    done

    # Clean up empty, module-specific blacklist files if any
    for f in \
        "/etc/modprobe.d/blacklist-${m_us}.conf" \
        "/etc/modprobe.d/blacklist-${m_hy}.conf"
    do
        [ -e "$f" ] || continue
        # Remove if file has no non-comment, non-blank lines
        if ! grep -Eq '^[[:space:]]*[^#[:space:]]' "$f" 2>/dev/null; then
            rm -f "$f" 2>/dev/null || true
        fi
    done

    # Refresh module dependency cache and udev rules
    depmod -a 2>/dev/null || true
    if command -v udevadm >/dev/null 2>&1; then
        udevadm control --reload-rules 2>/dev/null || true
    fi

    log_info "persistent unblock done for $m (and aliases: $m_us, $m_hy)"
    return 0
}

# -----------------------------------------------------------------------------
# modprobe with insmod fallback (standalone-like resilience)
# -----------------------------------------------------------------------------
video_modprobe_or_insmod() {
    m="$1"

    # 1) Try modprobe
    "$MODPROBE" "$m" 2>/dev/null && return 0

    # 2) If modprobe failed, scrub persistent blocks (blacklist + install /bin/false) and retry
    log_warn "modprobe $m failed, attempting de-blacklist + retry"
    video_persistent_unblock_module "$m"
    "$MODPROBE" "$m" 2>/dev/null && return 0

    # 3) As a final fallback, insmod the actual file (handles hyphen/underscore)
    if video_insmod_with_deps "$m"; then
        return 0
    fi

    # 4) One last nudge: try the hyphen/underscore alias through modprobe again
    malt="$(printf '%s' "$m" | tr '_-' '-_')"
    if [ "$malt" != "$m" ]; then
        "$MODPROBE" "$malt" 2>/dev/null && return 0
        if video_insmod_with_deps "$malt"; then
            return 0
        fi
    fi

    log_warn "modprobe $m failed, and insmod fallback did not succeed"
    return 1
}

# -----------------------------------------------------------------------------
# Stack normalization & auto preference
# -----------------------------------------------------------------------------
video_normalize_stack() {
    s="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    case "$s" in
        upstream|base|up) printf '%s\n' "upstream" ;;
        downstream|overlay|down) printf '%s\n' "downstream" ;;
        auto|"") printf '%s\n' "auto" ;;
        *) printf '%s\n' "$s" ;;
    esac
}

# -----------------------------------------------------------------------------
# Platform detect → lemans|monaco|kodiak|unknown
# -----------------------------------------------------------------------------
video_detect_platform() {
    model=""; compat=""
    if [ -r /proc/device-tree/model ]; then model=$(tr -d '\000' </proc/device-tree/model 2>/dev/null); fi
    if [ -r /proc/device-tree/compatible ]; then compat=$(tr -d '\000' </proc/device-tree/compatible 2>/dev/null); fi
    s=$(printf '%s\n%s\n' "$model" "$compat" | tr '[:upper:]' '[:lower:]')

    echo "$s" | grep -q "qcs9100" && { printf '%s\n' "lemans"; return 0; }
    echo "$s" | grep -q "qcs8300" && { printf '%s\n' "monaco"; return 0; }
    echo "$s" | grep -q "qcs6490" && { printf '%s\n' "kodiak"; return 0; }
    echo "$s" | grep -q "ride-sx" && echo "$s" | grep -q "9100" && { printf '%s\n' "lemans"; return 0; }
    echo "$s" | grep -q "ride-sx" && echo "$s" | grep -q "8300" && { printf '%s\n' "monaco"; return 0; }
    echo "$s" | grep -q "rb3" && echo "$s" | grep -q "6490" && { printf '%s\n' "kodiak"; return 0; }

    printf '%s\n' "unknown"
}

# -----------------------------------------------------------------------------
# Validation helpers
# -----------------------------------------------------------------------------
video_validate_upstream_loaded() {
    plat="$1"
    case "$plat" in
        lemans|monaco)
            video_has_module_loaded "$IRIS_UP_MOD" && video_has_module_loaded "$IRIS_VPU_MOD"
            return $?
            ;;
        kodiak)
            video_has_module_loaded "$VENUS_CORE_MOD" && video_has_module_loaded "$VENUS_DEC_MOD" && video_has_module_loaded "$VENUS_ENC_MOD"
            return $?
            ;;
        *) return 1 ;;
    esac
}

video_validate_downstream_loaded() {
    plat="$1"
    case "$plat" in
        # On lemans/monaco, downstream == iris_vpu present AND qcom_iris ABSENT
        lemans|monaco)
            if video_has_module_loaded "$IRIS_VPU_MOD" && ! video_has_module_loaded "$IRIS_UP_MOD"; then
                return 0
            fi
            return 1
            ;;
        # On kodiak, downstream == iris_vpu present AND venus core ABSENT
        kodiak)
            if video_has_module_loaded "$IRIS_VPU_MOD" && ! video_has_module_loaded "$VENUS_CORE_MOD"; then
                return 0
            fi
            return 1
            ;;
        *) return 1 ;;
    esac
}

# Verifies the requested stack after switching, per platform.
# Usage: video_assert_stack <platform> <upstream|downstream>
# Returns 0 if OK; prints a clear reason and returns 1 otherwise.
video_assert_stack() {
    plat="$1"; want="$(video_normalize_stack "$2")"

    case "$want" in
      upstream|up|base)
        if video_validate_upstream_loaded "$plat"; then
            return 0
        fi
        case "$plat" in
          lemans|monaco)
            log_fail "[STACK] Upstream requested but qcom_iris + iris_vpu are not both present."
            ;;
          kodiak)
            log_fail "[STACK] Upstream requested but venus_core/dec/enc are not all present."
            ;;
          *)
            log_fail "[STACK] Upstream requested but platform '$plat' is unknown."
            ;;
        esac
        return 1
        ;;
      downstream|overlay|down)
        if video_validate_downstream_loaded "$plat"; then
            return 0
        fi
        case "$plat" in
          lemans|monaco)
            log_fail "[STACK] Downstream requested but iris_vpu not present or qcom_iris still loaded."
            ;;
          kodiak)
            log_fail "[STACK] Downstream requested but iris_vpu not present or venus_core still loaded."
            ;;
          *)
            log_fail "[STACK] Downstream requested but platform '$plat' is unknown."
            ;;
        esac
        return 1
        ;;
      *)
        log_fail "[STACK] Unknown target stack '$want'."
        return 1
        ;;
    esac
}

video_stack_status() {
    plat="$1"
    if video_validate_downstream_loaded "$plat"; then
        printf '%s\n' "downstream"
    elif video_validate_upstream_loaded "$plat"; then
        printf '%s\n' "upstream"
    else
        printf '%s\n' "unknown"
    fi
}

# -----------------------------------------------------------------------------
# Unload all video modules relevant to platform (standalone-like)
# -----------------------------------------------------------------------------
video_unload_all_video_modules() {
    plat="$1"

    tryrmmod() {
        mod="$1"
        if video_has_module_loaded "$mod"; then
            if "$MODPROBE" -r "$mod" 2>/dev/null; then
                log_info "Removed module: $mod"
            else
                log_warn "Could not remove $mod via modprobe -r; retrying after short delay"
                sleep 0.2
                if "$MODPROBE" -r "$mod" 2>/dev/null; then
                    log_info "Removed module after retry: $mod"
                else
                    log_warn "Still could not remove: $mod"
                fi
            fi
        fi
    }

    case "$plat" in
      lemans|monaco)
        # Upstream first, then vpu (and retry upstream once vpu is gone)
        tryrmmod "$IRIS_UP_MOD"
        tryrmmod "$IRIS_VPU_MOD"
        tryrmmod "$IRIS_UP_MOD"
        ;;
      kodiak)
        # Upstream (venus*) and downstream (iris_vpu) — remove all
        tryrmmod "$VENUS_ENC_MOD"
        tryrmmod "$VENUS_DEC_MOD"
        tryrmmod "$VENUS_CORE_MOD"
        tryrmmod "$IRIS_VPU_MOD"
        ;;
      *) : ;;
    esac
}

# -----------------------------------------------------------------------------
# Hot switch (best-effort, no reboot) — mirrors standalone flow
# -----------------------------------------------------------------------------
video_hot_switch_modules() {
    plat="$1"; stack="$2"; rc=0

    case "$plat" in
      lemans|monaco)
        if [ "$stack" = "downstream" ]; then
            # Block upstream; allow downstream
            video_block_upstream_strict
            video_unblock_mod_now "$IRIS_VPU_MOD"

            # Clean slate
            video_unload_all_video_modules "$plat"

            # Load only iris_vpu
            if ! video_modprobe_or_insmod "$IRIS_VPU_MOD"; then
                rc=1
            fi

            # Final guard: upstream must not be loaded
            if video_has_module_loaded "$IRIS_UP_MOD"; then
                log_warn "$IRIS_UP_MOD reloaded unexpectedly; unloading and keeping block in place"
                "$MODPROBE" -r "$IRIS_UP_MOD" 2>/dev/null || rc=1
            fi

        else # upstream
            # Unblock both sides
            video_unblock_mod_now "$IRIS_UP_MOD" "$IRIS_VPU_MOD"

            # Clean slate
            video_unload_all_video_modules "$plat"

            # Load upstream core first, then vpu
            if ! video_modprobe_or_insmod "$IRIS_UP_MOD"; then
                log_warn "modprobe $IRIS_UP_MOD failed; printing current runtime blocks & retrying"
                video_list_runtime_blocks
                video_unblock_mod_now "$IRIS_UP_MOD"
                video_modprobe_or_insmod "$IRIS_UP_MOD" || rc=1
            fi
            video_modprobe_or_insmod "$IRIS_VPU_MOD" || true
        fi
        ;;

      kodiak)
        if [ "$stack" = "downstream" ]; then
            # Block upstream venus; allow downstream
            video_block_mod_now "$VENUS_CORE_MOD" "$VENUS_DEC_MOD" "$VENUS_ENC_MOD"
            video_unblock_mod_now "$IRIS_VPU_MOD"

            # Unload everything
            "$MODPROBE" -r "$IRIS_VPU_MOD" 2>/dev/null || true
            "$MODPROBE" -r "$VENUS_ENC_MOD" 2>/dev/null || true
            "$MODPROBE" -r "$VENUS_DEC_MOD" 2>/dev/null || true
            "$MODPROBE" -r "$VENUS_CORE_MOD" 2>/dev/null || true

            # Load downstream
            if ! video_modprobe_or_insmod "$IRIS_VPU_MOD"; then
                log_warn "Kodiak: failed to load $IRIS_VPU_MOD"
                rc=1
            fi

            # Automatic FW swap + live reload (does real work only if VIDEO_FW_DS is set & file exists)
            log_info "Kodiak: invoking firmware swap/reload helper (if VIDEO_FW_DS provided)"
            if ! video_kodiak_swap_and_reload "${VIDEO_FW_DS}"; then
                log_warn "Kodiak: swap/reload helper reported failure (continuing)"
            fi

            video_log_fw_hint

        else # upstream
            video_unblock_mod_now "$VENUS_CORE_MOD" "$VENUS_DEC_MOD" "$VENUS_ENC_MOD" "$IRIS_VPU_MOD"
            "$MODPROBE" -r "$IRIS_VPU_MOD" 2>/dev/null || true
            video_modprobe_or_insmod "$VENUS_CORE_MOD" || rc=1
            video_modprobe_or_insmod "$VENUS_DEC_MOD" || true
            video_modprobe_or_insmod "$VENUS_ENC_MOD" || true
            video_log_fw_hint
        fi
        ;;

      *) rc=1 ;;
    esac
    return $rc
}

# -----------------------------------------------------------------------------
# Entry point: ensure desired stack
# -----------------------------------------------------------------------------
video_ensure_stack() {
    want_raw="$1" # upstream|downstream|auto|base|overlay|up|down
    plat="$2"

    if [ -z "$plat" ]; then plat=$(video_detect_platform); fi
    want="$(video_normalize_stack "$want_raw")"

    if [ "$want" = "auto" ]; then
        pref="$(video_auto_preference_from_blacklist "$plat")"
        if [ "$pref" != "unknown" ]; then
            want="$pref"
        else
            cur="$(video_stack_status "$plat")"
            if [ "$cur" != "unknown" ]; then want="$cur"; else want="upstream"; fi
        fi
        log_info "AUTO stack selection => $want"
    fi

    # ----- Fast path only when it is safe to skip switching -----
    if [ "$want" = "upstream" ]; then
        if video_validate_upstream_loaded "$plat"; then
            printf '%s\n' "upstream"
            return 0
        fi
    else # downstream
        if video_validate_downstream_loaded "$plat"; then
            #
            # IMPORTANT: On Kodiak, if a downstream FW override is provided, we still
            # need to perform the firmware swap + live reload even if iris_vpu is already loaded.
            #
            if [ "$plat" = "kodiak" ] && [ -n "$VIDEO_FW_DS" ]; then
                log_info "Kodiak: downstream already loaded, but FW override provided — performing FW swap + live reload."
                # fall through to the hot-switch path below
            else
                printf '%s\n' "downstream"
                return 0
            fi
        fi
    fi

    # Apply persistent blacklist for the requested stack (no reboot needed; runtime blocks handle the session)
    video_apply_blacklist_for_stack "$plat" "$want" || return 1

    # Do the hot switch (unload opposite side, install FW if needed, load target side, attempt live FW apply where applicable)
    video_hot_switch_modules "$plat" "$want" || true

    # Ensure Kodiak FW swap even after a successful switch (defensive)
    if [ "$plat" = "kodiak" ] && [ "$want" = "downstream" ] && [ -n "$VIDEO_FW_DS" ] && [ -f "$VIDEO_FW_DS" ]; then
        if video_validate_downstream_loaded "$plat"; then
            log_info "Kodiak: downstream active and FW override detected — ensuring FW swap + live reload."
            video_kodiak_swap_and_reload "$VIDEO_FW_DS" || log_warn "Kodiak: post-switch FW swap/reload failed (continuing)"
        fi
    fi

    # Verify again
    if [ "$want" = "upstream" ]; then
        if video_validate_upstream_loaded "$plat"; then printf '%s\n' "upstream"; return 0; fi
    else
        if video_validate_downstream_loaded "$plat"; then printf '%s\n' "downstream"; return 0; fi
    fi

    printf '%s\n' "unknown"
    return 1
}

video_block_upstream_strict() {
    # Prefer runtime block first
    video_block_mod_now "$IRIS_UP_MOD"

    # If it keeps reappearing, persist a lightweight install rule
    if [ -w /etc/modprobe.d ]; then
        if ! grep -q "install[[:space:]]\+${IRIS_UP_MOD}[[:space:]]\+/bin/false" /etc/modprobe.d/qcom_iris-block.conf 2>/dev/null; then
            printf 'install %s /bin/false\n' "$IRIS_UP_MOD" >> /etc/modprobe.d/qcom_iris-block.conf 2>/dev/null || true
        fi
        depmod -a 2>/dev/null || true
    fi
}

# -----------------------------------------------------------------------------
# udev refresh + prune stale /dev/video* and /dev/media* nodes
# -----------------------------------------------------------------------------
video_clean_and_refresh_v4l() {
    # Try to have udev repopulate nodes for current drivers
    if video_exist_cmd udevadm; then
        log_info "udev trigger: video4linux/media"
        udevadm trigger --subsystem-match=video4linux --action=change 2>/dev/null || true
        udevadm trigger --subsystem-match=media --action=change 2>/dev/null || true
        udevadm settle 2>/dev/null || true
    fi

    # Prune /dev/video* nodes that have no sysfs backing
    for n in /dev/video*; do
        [ -e "$n" ] || continue
        bn=$(basename "$n")
        if [ ! -e "/sys/class/video4linux/$bn" ]; then
            log_info "Pruning stale node: $n"
            rm -f "$n" 2>/dev/null || true
        fi
    done

    # Prune /dev/media* nodes that have no sysfs backing
    for n in /dev/media*; do
        [ -e "$n" ] || continue
        bn=$(basename "$n")
        if [ ! -e "/sys/class/media/$bn" ]; then
            log_info "Pruning stale node: $n"
            rm -f "$n" 2>/dev/null || true
        fi
    done
}

# -----------------------------------------------------------------------------
# DMESG triage
# -----------------------------------------------------------------------------
video_scan_dmesg_if_enabled() {
    dm="$1"; logdir="$2"
    if [ "$dm" -ne 1 ] 2>/dev/null; then return 2; fi
    MODS='oom|memory|BUG|hung task|soft lockup|hard lockup|rcu|page allocation failure|I/O error'
    EXCL='using dummy regulator|not found|EEXIST|probe deferred'
    if scan_dmesg_errors "$logdir" "$MODS" "$EXCL"; then return 0; fi
    return 1
}

# -----------------------------------------------------------------------------
# JSON helpers (jq-free) — robust multi-key scan
# -----------------------------------------------------------------------------
video_is_decode_cfg() {
    cfg="$1"
    b=$(basename "$cfg" | tr '[:upper:]' '[:lower:]')
    case "$b" in *dec*.json) return 0 ;; *enc*.json) return 1 ;; esac
    dom=$(sed -n 's/.*"Domain"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$cfg" 2>/dev/null | head -n 1)
    dom_l=$(printf '%s' "$dom" | tr '[:upper:]' '[:lower:]')
    case "$dom_l" in decoder|decode) return 0 ;; encoder|encode) return 1 ;; esac
    return 0
}

video_extract_scalar() { k="$1"; cfg="$2"; sed -n "s/.*\"$k\"[[:space:]]*:[[:space:]]*\"\\([^\"\r\n]*\\)\".*/\\1/p" "$cfg"; }
video_extract_array() { k="$1"; cfg="$2"; sed -n "s/.*\"$k\"[[:space:]]*:\\s*\\[\\(.*\\)\\].*/\\1/p" "$cfg" | tr ',' '\n' | sed -n 's/.*"\([^"]*\)".*/\1/p'; }

video_extract_array_ml() {
    k="$1"; cfg="$2"
    awk -v k="$k" '
        $0 ~ "\""k"\"[[:space:]]*:" {in=1}
        in {print; if ($0 ~ /\]/) exit}
    ' "$cfg" | sed -n 's/.*"\([^"]*\)".*/\1/p' | grep -vx "$k"
}

video_strings_from_array_key() {
    k="$1"; cfg="$2"
    {
        video_extract_array_ml "$k" "$cfg"
        video_extract_array "$k" "$cfg"
    } 2>/dev/null | sed '/^$/d' | awk '!seen[$0]++'
}

video_extract_base_dirs() {
    cfg="$1"
    for k in InputDir InputDirectory InputFolder BasePath BaseDir; do
        video_extract_scalar "$k" "$cfg"
    done | sed '/^$/d' | head -n 1
}

video_guess_codec_from_cfg() {
    cfg="$1"
    for k in Codec codec CodecName codecName VideoCodec videoCodec DecoderName EncoderName Name name; do
        v=$(video_extract_scalar "$k" "$cfg" | head -n 1)
        if [ -n "$v" ]; then printf '%s\n' "$v"; return 0; fi
    done
    for tok in hevc h265 h264 av1 vp9 vp8 mpeg4 mpeg2 h263 avc; do
        if grep -qiE "(^|[^A-Za-z0-9])${tok}([^A-Za-z0-9]|$)" "$cfg" 2>/dev/null; then printf '%s\n' "$tok"; return 0; fi
    done
    b=$(basename "$cfg" | tr '[:upper:]' '[:lower:]')
    for tok in hevc h265 h264 av1 vp9 vp8 mpeg4 mpeg2 h263 avc; do case "$b" in *"$tok"*) printf '%s\n' "$tok"; return 0 ;; esac; done
    printf '%s\n' "unknown"
    return 0
}

video_canon_codec() {
    c=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    case "$c" in
        h265|hevc) printf '%s\n' "hevc" ;;
        h264|avc) printf '%s\n' "h264" ;;
        vp9) printf '%s\n' "vp9" ;;
        vp8) printf '%s\n' "vp8" ;;
        av1) printf '%s\n' "av1" ;;
        mpeg4) printf '%s\n' "mpeg4" ;;
        mpeg2) printf '%s\n' "mpeg2" ;;
        h263) printf '%s\n' "h263" ;;
        *) printf '%s\n' "$c" ;;
    esac
}

video_pretty_name_from_cfg() {
    cfg="$1"; base=$(basename "$cfg" .json)
    nm=$(video_extract_scalar "name" "$cfg"); [ -z "$nm" ] && nm=$(video_extract_scalar "Name" "$cfg")
    if video_is_decode_cfg "$cfg"; then cd_op="Decode"; else cd_op="Encode"; fi
    codec=$(video_extract_scalar "codec" "$cfg"); [ -z "$codec" ] && codec=$(video_extract_scalar "Codec" "$cfg")
    nice="$cd_op:$base"
    if [ -n "$nm" ]; then nice="$nm"; elif [ -n "$codec" ]; then nice="$cd_op:$codec ($base)"; fi
    safe=$(printf '%s' "$nice" | tr ' ' '_' | tr -cd 'A-Za-z0-9._-')
    printf '%s|%s\n' "$nice" "$safe"
}

# Collect input clip paths from varied schemas (expanded keys)
video_extract_input_clips() {
    cfg="$1"

    {
        # 1) direct scalar-ish
        for k in \
            InputPath inputPath Inputpath input InputFile input_file infile InFile InFileName \
            FilePath Source Clip File Bitstream BitstreamFile YUV YUVFile YuvFileName Path RawFile RawInput RawYUV \
            Sequence
        do
            video_extract_scalar "$k" "$cfg"
        done
    } 2>/dev/null | sed '/^$/d'

    {
        # 2) common array keys
        for k in Inputs InputFiles input_files Clips Files FileList Streams Bitstreams FileNames InputStreams; do
            video_strings_from_array_key "$k" "$cfg"
        done
    } 2>/dev/null | sed '/^$/d'

    # 3) arrays of file names with a base directory hint
    basedir=$(video_extract_base_dirs "$cfg")
    if [ -n "$basedir" ]; then
        for arr in Files Inputs Clips InputFiles FileNames; do
            video_strings_from_array_key "$arr" "$cfg" | sed '/^\//! s_^_'"$basedir"'/_'
        done
    fi
}

# -----------------------------------------------------------------------------
# Network-aware clip ensure/fetch
# -----------------------------------------------------------------------------
video_ensure_clips_present_or_fetch() {
    cfg="$1"; tu="$2"
    clips=$(video_extract_input_clips "$cfg")
    if [ -z "$clips" ]; then return 0; fi

    tmp_list="${LOG_DIR:-.}/.video_missing.$$"
    : > "$tmp_list"
    printf '%s\n' "$clips" | while IFS= read -r p; do
        [ -z "$p" ] && continue
        case "$p" in /*) abs="$p" ;; *) abs=$(cd "$(dirname "$cfg")" 2>/dev/null && pwd)/$p ;; esac
        [ -f "$abs" ] || printf '%s\n' "$abs" >> "$tmp_list"
    done

    if [ ! -s "$tmp_list" ]; then
        rm -f "$tmp_list" 2>/dev/null || true
        return 0
    fi

    log_warn "Some input clips are missing (list: $tmp_list)"
    [ -z "$tu" ] && tu="$TAR_URL"

    if command -v ensure_network_online >/dev/null 2>&1; then
        if ! ensure_network_online; then
            log_warn "Network offline/limited; cannot fetch media bundle"
            rm -f "$tmp_list" 2>/dev/null || true
            return 2
        fi
    fi

    if [ -n "$tu" ]; then
        log_info "Attempting fetch via TAR_URL=$tu"
        if extract_tar_from_url "$tu"; then
            rm -f "$tmp_list" 2>/dev/null || true
            return 0
        fi
        log_warn "Fetch/extract failed for TAR_URL"
        rm -f "$tmp_list" 2>/dev/null || true
        return 1
    fi

    log_warn "No TAR_URL provided; cannot fetch media bundle."
    rm -f "$tmp_list" 2>/dev/null || true
    return 1
}

# -----------------------------------------------------------------------------
# JUnit helper
# -----------------------------------------------------------------------------
video_junit_append_case() {
    of="$1"; class="$2"; name="$3"; t="$4"; st="$5"; logf="$6"
    [ -n "$of" ] || return 0
    tailtxt=""
    if [ -f "$logf" ]; then
        tailtxt=$(tail -n 50 "$logf" 2>/dev/null | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g')
    fi
    {
        printf ' <testcase classname="%s" name="%s" time="%s">\n' "$class" "$name" "$t"
        case "$st" in
            PASS) : ;;
            SKIP) printf ' <skipped/>\n' ;;
            FAIL) printf ' <failure message="%s">\n' "failed"; printf '%s\n' "$tailtxt"; printf ' </failure>\n' ;;
        esac
        printf ' </testcase>\n'
    } >> "$of"
}

# -----------------------------------------------------------------------------
# Timeout wrapper availability + single run
# -----------------------------------------------------------------------------
video_have_run_with_timeout() { video_exist_cmd run_with_timeout; }

# Ensure the test app is executable; if not, try to fix it (or stage a temp copy)
video_prepare_app() {
    app="${VIDEO_APP:-/usr/bin/iris_v4l2_test}"

    if [ -z "$app" ] || [ ! -e "$app" ]; then
        log_fail "App not found: $app"
        return 1
    fi

    # If it's already executable, we're done.
    if [ -x "$app" ]; then
        return 0
    fi

    # Try to chmod in place.
    if chmod +x "$app" 2>/dev/null; then
        log_info "Set executable bit on $app"
        return 0
    fi

    # If chmod failed (e.g., RO filesystem), try a temp copy in /tmp and exec that.
    tmp="/tmp/$(basename "$app").$$"
    if cp -f "$app" "$tmp" 2>/dev/null && chmod +x "$tmp" 2>/dev/null; then
        VIDEO_APP="$tmp"
        log_info "Using temp executable copy: $VIDEO_APP"
        return 0
    fi

    log_warn "Could not make app executable (chmod/copy failed). Execution may fail."
    return 1
}

video_run_once() {
    cfg="$1"; logf="$2"; tmo="$3"; suc="$4"; lvl="$5"
# NEW: ensure the app is executable (or stage a temp copy)
    video_prepare_app || true
    : > "$logf"
    {
        iso_now="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo now)"
        printf 'BEGIN-RUN %s\n' "$iso_now"
        printf 'APP=%s\n' "$VIDEO_APP"
        printf 'CFG=%s\n' "$cfg"
        printf 'LOGLEVEL=%s TIMEOUT=%s\n' "$lvl" "${tmo:-none}"
        printf 'CMD=%s %s %s %s\n' "$VIDEO_APP" "--config" "$cfg" "--loglevel $lvl"
    } >>"$logf" 2>&1

    if video_have_run_with_timeout; then
        if run_with_timeout "$tmo" "$VIDEO_APP" --config "$cfg" --loglevel "$lvl" >>"$logf" 2>&1; then :; else
            rc=$?
            if [ "$rc" -eq 124 ] 2>/dev/null; then log_fail "[run] timeout after ${tmo}s"; else log_fail "[run] $VIDEO_APP exited rc=$rc"; fi
            printf 'END-RUN rc=%s\n' "$rc" >>"$logf"
            grep -Eq "$suc" "$logf"
            return $?
        fi
    else
        if "$VIDEO_APP" --config "$cfg" --loglevel "$lvl" >>"$logf" 2>&1; then :; else
            rc=$?
            log_fail "[run] $VIDEO_APP exited rc=$rc (no timeout enforced)"
            printf 'END-RUN rc=%s\n' "$rc" >>"$logf"
            grep -Eq "$suc" "$logf"
            return $?
        fi
    fi

    printf 'END-RUN rc=0\n' >>"$logf"
    grep -Eq "$suc" "$logf"
}

# -----------------------------------------------------------------------------
# Kodiak firmware swap + live reload (no reboot)
# -----------------------------------------------------------------------------
# Always use the final on-device firmware name
video_kodiak_fw_basename() {
    printf '%s\n' "vpu20_p1_gen2.mbn"
}

# Install (rename) firmware: source (e.g. vpuw20_1v.mbn) -> /lib/firmware/qcom/vpu/vpu20_p1_gen2.mbn
video_kodiak_install_fw() {
    # usage: video_kodiak_install_fw /path/to/vpuw20_1v.mbn
    src="$1"
    if [ -z "$src" ] || [ ! -f "$src" ]; then
        log_warn "Kodiak FW src missing: $src"
        return 1
    fi

    dst="$FW_PATH_KODIAK" # /lib/firmware/qcom/vpu/vpu20_p1_gen2.mbn
    tmp="${dst}.new.$$"

    mkdir -p "$(dirname "$dst")" 2>/dev/null || true

    # Backup any existing firmware into /opt (timestamped)
    if [ -f "$dst" ]; then
        mkdir -p "$FW_BACKUP_DIR" 2>/dev/null || true
        ts=$(date +%Y%m%d%H%M%S 2>/dev/null || printf '%s' "now")
        cp -f "$dst" "$FW_BACKUP_DIR/vpu20_p1_gen2.mbn.$ts.bak" 2>/dev/null || true
    fi

    # Copy source to the exact destination filename (rename happens here)
    cp -f "$src" "$tmp" 2>/dev/null || { log_warn "FW copy to temp failed: $tmp"; return 1; }
    chmod 0644 "$tmp" 2>/dev/null || true
    chown root:root "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$dst" 2>/dev/null || { log_warn "FW mv into place failed: $dst"; rm -f "$tmp" 2>/dev/null || true; return 1; }
    sync || true
    if command -v restorecon >/dev/null 2>&1; then
        restorecon "$dst" 2>/dev/null || true
    fi

    log_info "Kodiak FW installed at: $dst (from: $(basename "$src"))"
    return 0
}

# Install latest Kodiak upstream firmware from backups into the kernel firmware path.
# Looks under ${VIDEO_FW_BACKUP_DIR:-/opt} for multiple filename styles:
# vpu20_p1_gen2_*.mbn
# vpu20_p1_gen2.mbn.*
# vpu20_p1_gen2*.mbn.bak
# vpu20_p1_gen2*.bak
# vpu20_p1_gen2*.mbn.*
video_kodiak_install_firmware() {
    src_dir="${VIDEO_FW_BACKUP_DIR:-/opt}"
    dest="/lib/firmware/qcom/vpu/vpu20_p1_gen2.mbn"

    [ -d "$src_dir" ] || { log_warn "Backup dir not found: $src_dir"; return 0; }
    mkdir -p "$(dirname "$dest")" 2>/dev/null || true

    candidates=""
    for g in \
        "$src_dir"/vpu20_p1_gen2_*.mbn \
        "$src_dir"/vpu20_p1_gen2.mbn.* \
        "$src_dir"/vpu20_p1_gen2*.mbn.bak \
        "$src_dir"/vpu20_p1_gen2*.bak \
        "$src_dir"/vpu20_p1_gen2*.mbn.* ; do
        for f in $g; do
            [ -f "$f" ] && candidates="$candidates
$f"
        done
    done

    if [ -z "$candidates" ]; then
        log_warn "No backup firmware found under $src_dir (tried patterns: vpu20_p1_gen2_*.mbn, vpu20_p1_gen2.mbn.*, *.mbn.bak, *.bak)"
        return 0
    fi

    # Pick newest by modification time without 'ls'
    newest=""
    # shellcheck disable=SC2048,SC2086
    for f in $candidates; do
        [ -f "$f" ] || continue
	if [ -z "$newest" ] || [ -n "$(find "$f" -prune -newer "$newest" -print -quit 2>/dev/null)" ]; then
            newest="$f"
        fi
    done
    [ -n "$newest" ] || newest="$(printf '%s\n' "$candidates" | head -n1)"

    log_info "Using backup firmware: $newest → $dest"
    if cp -f "$newest" "$dest" 2>/dev/null; then
        chmod 0644 "$dest" 2>/dev/null || true
        log_pass "Installed Kodiak upstream firmware to $dest"
        return 0
    fi

    log_warn "cp failed; trying install -D"
    if install -m 0644 -D "$newest" "$dest" 2>/dev/null; then
        log_pass "Installed Kodiak upstream firmware to $dest"
        return 0
    fi

    log_error "Failed to install firmware from $newest to $dest"
    return 1
}

# remoteproc reload must reference the *destination* basename
video_kodiak_try_remoteproc_reload() {
    bn="$(video_kodiak_fw_basename)" # always "vpu20_p1_gen2.mbn"
    did=0
    for rp in /sys/class/remoteproc/remoteproc*; do
        [ -d "$rp" ] || continue
        name="$(tr '[:upper:]' '[:lower:]' < "$rp/name" 2>/dev/null)"
        case "$name" in
            *vpu*|*video*|*iris* )
                log_info "remoteproc: $rp (name=$name)"
                if [ -r "$rp/state" ]; then log_info "remoteproc state (pre): $(cat "$rp/state" 2>/dev/null)"; fi
                if [ -w "$rp/state" ]; then echo stop > "$rp/state" 2>/dev/null || true; fi
                if [ -w "$rp/firmware" ]; then printf '%s' "$bn" > "$rp/firmware" 2>/dev/null || true; fi
                if [ -w "$rp/state" ]; then echo start > "$rp/state" 2>/dev/null || true; fi
                sleep 1
                if [ -r "$rp/state" ]; then log_info "remoteproc state (post): $(cat "$rp/state" 2>/dev/null)"; fi
                did=1
            ;;
        esac
    done
    [ $did -eq 1 ] && { log_info "remoteproc reload attempted with $bn"; return 0; }
    return 1
}

video_kodiak_try_module_reload() {
    # Reload iris_vpu so request_firmware() grabs the new blob
    rc=1
    if video_has_module_loaded "$IRIS_VPU_MOD"; then
        log_info "module reload: rmmod $IRIS_VPU_MOD"
        "$MODPROBE" -r "$IRIS_VPU_MOD" 2>/dev/null || true
        sleep 1
    fi
    log_info "module reload: modprobe $IRIS_VPU_MOD"
    if "$MODPROBE" "$IRIS_VPU_MOD" 2>/dev/null; then
        rc=0
    else
        ko=$("$MODPROBE" -n -v "$IRIS_VPU_MOD" 2>/dev/null | awk '/(^| )insmod( |$)/ {print $2; exit}')
        if [ -n "$ko" ] && [ -f "$ko" ]; then
            log_info "module reload: insmod $ko"
            insmod "$ko" 2>/dev/null && rc=0 || rc=1
        fi
    fi
    [ $rc -eq 0 ] && log_info "iris_vpu module reloaded"
    return $rc
}

video_kodiak_try_unbind_bind() {
    # Last resort: platform unbind/bind
    did=0
    for drv in /sys/bus/platform/drivers/*; do
        [ -d "$drv" ] || continue
        case "$(basename "$drv")" in *iris*|*vpu*|*video* )
            for dev in "$drv"/*; do
                [ -L "$dev" ] || continue
                dn="$(basename "$dev")"
                log_info "platform: unbind $dn from $(basename "$drv")"
                if [ -w "$drv/unbind" ]; then echo "$dn" > "$drv/unbind" 2>/dev/null || true; fi
                sleep 1
                log_info "platform: bind $dn to $(basename "$drv")"
                if [ -w "$drv/bind" ]; then echo "$dn" > "$drv/bind" 2>/dev/null || true; fi
                did=1
            done
        ;; esac
    done
    [ $did -eq 1 ] && { log_info "platform unbind/bind attempted"; return 0; }
    return 1
}

video_kodiak_swap_and_reload() {
    # usage: video_kodiak_swap_and_reload /path/to/newfw.mbn
    newsrc="$1"
    if [ -z "$newsrc" ] || [ ! -f "$newsrc" ]; then
        log_warn "No FW source to install (VIDEO_FW_DS unset or missing)"
        return 1
    fi
    video_kodiak_install_fw "$newsrc" || return 1
    video_kodiak_try_remoteproc_reload && { video_clean_and_refresh_v4l; return 0; }
    video_kodiak_try_module_reload && { video_clean_and_refresh_v4l; return 0; }
    video_kodiak_try_unbind_bind && { video_clean_and_refresh_v4l; return 0; }
    log_warn "FW reload attempts did not confirm success (remoteproc/module/unbind)."
    return 1
}

# Fallback: try modprobe first, then insmod the path printed by "modprobe -n -v"
if ! command -v video_try_modprobe_then_insmod >/dev/null 2>&1; then
video_try_modprobe_then_insmod() {
    m="$1"
    # Try modprobe
    if "$MODPROBE" "$m" 2>/dev/null; then
        return 0
    fi
    # Try to parse an insmod line from a dry-run
    p="$("$MODPROBE" -n -v "$m" 2>/dev/null | awk '/(^| )insmod( |$)/ {print $2; exit}')"
    if [ -n "$p" ] && [ -f "$p" ]; then
        insmod "$p" 2>/dev/null && return 0
    fi
    return 1
}
fi

# --- Persistent blacklist storage (if not already defined) ---
: "${BLACKLIST_DIR:=/etc/modprobe.d}"
: "${BLACKLIST_FILE:=$BLACKLIST_DIR/blacklist.conf}"

# Return 0 if token is present in blacklist.conf, else 1
video_is_blacklisted() {
    tok="$1"
    [ -f "$BLACKLIST_FILE" ] || return 1
    grep -q "^blacklist[[:space:]]\+$tok$" "$BLACKLIST_FILE" 2>/dev/null
}

# Ensure a "blacklist <token>" line exists (idempotent)
video_ensure_blacklist() {
    tok="$1"
    mkdir -p "$BLACKLIST_DIR" 2>/dev/null || true
    if ! video_is_blacklisted "$tok"; then
        printf 'blacklist %s\n' "$tok" >>"$BLACKLIST_FILE"
        log_info "Added persistent blacklist for: $tok"
    fi
}

# Remove any matching "blacklist <token>" lines (idempotent)
video_remove_blacklist() {
    tok="$1"
    [ -f "$BLACKLIST_FILE" ] || return 0
    tmp="$BLACKLIST_FILE.tmp.$$"
    # delete lines like: blacklist <tok> (with optional surrounding spaces)
    sed "/^[[:space:]]*blacklist[[:space:]]\+${tok}[[:space:]]*$/d" \
        "$BLACKLIST_FILE" >"$tmp" 2>/dev/null && mv "$tmp" "$BLACKLIST_FILE"
    log_info "Removed persistent blacklist for: $tok"
}

# -----------------------------------------------------------------------------
# Blacklist desired stack (persistent, cross-boot)
# -----------------------------------------------------------------------------
video_apply_blacklist_for_stack() {
    plat="$1"; stack="$2"
    case "$plat" in
        lemans|monaco)
            if [ "$stack" = "downstream" ]; then
                # Block upstream; allow downstream
                video_ensure_blacklist "qcom-iris"
                video_ensure_blacklist "qcom_iris"
                video_remove_blacklist "iris-vpu"
                video_remove_blacklist "iris_vpu"
            else # upstream
                # Unblock everything (we rely on runtime blocks for session control)
                video_remove_blacklist "qcom-iris"
                video_remove_blacklist "qcom_iris"
                video_remove_blacklist "iris-vpu"
                video_remove_blacklist "iris_vpu"
            fi
            ;;
        kodiak)
            if [ "$stack" = "downstream" ]; then
                # Block upstream venus; allow downstream iris_vpu
                video_ensure_blacklist "venus-core"
                video_ensure_blacklist "venus_core"
                video_ensure_blacklist "venus-dec"
                video_ensure_blacklist "venus_dec"
                video_ensure_blacklist "venus-enc"
                video_ensure_blacklist "venus_enc"
                video_remove_blacklist "iris-vpu"
                video_remove_blacklist "iris_vpu"
            else # upstream
                # Unblock venus and iris_vpu
                video_remove_blacklist "venus-core"
                video_remove_blacklist "venus_core"
                video_remove_blacklist "venus-dec"
                video_remove_blacklist "venus_dec"
                video_remove_blacklist "venus-enc"
                video_remove_blacklist "venus_enc"
                video_remove_blacklist "iris-vpu"
                video_remove_blacklist "iris_vpu"
            fi
            ;;
        *)
            return 1
            ;;
    esac
    return 0
}

# -----------------------------------------------------------------------------
# AUTO preference helper using persistent blacklists
# -----------------------------------------------------------------------------
video_auto_preference_from_blacklist() {
    plat="$1"
    case "$plat" in
        lemans|monaco)
            if video_is_blacklisted "qcom-iris" || video_is_blacklisted "qcom_iris"; then
                printf '%s\n' "downstream"; return 0
            fi
            ;;
        kodiak)
            if video_is_blacklisted "venus-core" || video_is_blacklisted "venus_core" \
               || video_is_blacklisted "venus-dec" || video_is_blacklisted "venus_dec" \
               || video_is_blacklisted "venus-enc" || video_is_blacklisted "venus_enc"; then
                printf '%s\n' "downstream"; return 0
            fi
            ;;
    esac
    printf '%s\n' "unknown"
    return 0
}
