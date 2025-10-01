# Iris V4L2 Video Test Scripts for Qualcomm Linux (Yocto)

**Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.**  
**SPDX-License-Identifier: BSD-3-Clause-Clear**

---

## Overview

These scripts automate validation of video **encoding** and **decoding** on Qualcomm Linux platforms running a Yocto-based rootfs.
They drive the public `iris_v4l2_test` app: <https://github.com/quic/v4l-video-test-app>.

The suite includes a **reboot-free video stack switcher** (upstream ↔ downstream), a **Kodiak (QCS6490/RB3gen2) firmware swap flow**, and robust **pre-flight checks** (rootfs size, network bootstrap, module sanity, device nodes).

---

## What’s New (since 2025‑09‑26)

- **Pre-download rootfs auto‑resize**
  - New `ensure_rootfs_min_size` (now in `functestlib.sh`) verifies `/` has at least **2 GiB** available and, if the root partition is `/dev/disk/by-partlabel/rootfs`, runs:
    ```sh
    resize2fs /dev/disk/by-partlabel/rootfs
    ```
  - Invoked **before** any clip bundle download.

- **Kodiak upstream: auto‑install backup firmware before switching**
  - `video_kodiak_install_firmware` (in `lib_video.sh`) looks for a recent backup blob under **`$VIDEO_FW_BACKUP_DIR`** (defaults to `/opt/video-fw-backups`) **and legacy `/opt` patterns**, then copies it to:
    ```
    /lib/firmware/qcom/vpu/vpu20_p1_gen2.mbn
    ```
  - Attempts **remoteproc stop → firmware swap → start**, with fallback to **module reload** and **platform unbind/bind**.
  - Automatically runs when `--platform kodiak --stack upstream`.

- **Network bootstrap before downloads (Ethernet → Wi‑Fi)**
  - `ensure_network_online` first tries wired DHCP; if still offline and **Wi‑Fi credentials are available**, it attempts:
    1) `nmcli dev wifi connect` (with a **key‑mgmt fallback** that creates a PSK connection if NM complains: `802-11-wireless-security.key-mgmt: property is missing`), then
    2) `wpa_supplicant + udhcpc` as a final fallback.
  - Credentials are taken from environment **`SSID`/`PASSWORD`** or an optional `./ssid_list.txt` (first line: `ssid password`).

- **App path hardening**
  - If `--app` points to a file that exists but is not executable, the runner does a best‑effort `chmod +x` and proceeds.

- **Platform‑aware hard gates & clearer logging**
  - Upstream/Downstream validation is **platform specific** (lemans/monaco vs. kodiak).
  - udev refresh + stale node pruning for `/dev/video*` and `/dev/media*` after any stack change.

---

## Features

- Pure **V4L2** driver-level tests using `iris_v4l2_test`
- **Encode** (YUV → H.264/H.265) and **Decode** (H.264/H.265/VP9 → YUV)
- **Yocto**-friendly, POSIX shell with BusyBox-safe paths
- Parse & run multiple JSON configs; auto-detect **encode/decode**
- **Auto-fetch** missing input clips (retries, BusyBox `wget` compatible)
- **Rootfs size guard** (auto‑resize) **before** fetching assets
- **Network bootstrap** (Ethernet → Wi‑Fi via `nmcli`/`wpa_supplicant`) when needed for downloads
- Timeout, repeat, dry-run, JUnit XML, dmesg triage
- **Stack switcher**: upstream ↔ downstream without reboot
- **Kodiak firmware live swap** with backup/restore helpers
- **udev refresh + prune** of stale device nodes

---

## Directory Layout

```bash
Runner/
├── suites/
│   └── Multimedia/
│       └── Video/
│           ├── README_Video.md
│           └── Video_V4L2_Runner/
│               ├── h264Decoder.json
│               ├── h265Decoder.json
│               ├── vp9Decoder.json
│               ├── h264Encoder.json
│               ├── h265Encoder.json
│               └── run.sh
└── utils/
    ├── functestlib.sh
    └── lib_video.sh
```

---

## Quick Start

```bash
git clone <this-repo>
cd <this-repo>

# Copy to target
scp -r Runner user@<target_ip>:<target_path>
ssh user@<target_ip>

cd <target_path>/Runner
./run-test.sh Video_V4L2_Runner
```

> Results land under: `Runner/suites/Multimedia/Video/Video_V4L2_Runner/`

---

## Runner CLI (run.sh)

| Option | Description |
|---|---|
| `--config path.json` | Run a specific config file |
| `--dir DIR` | Directory to search for configs |
| `--pattern GLOB` | Filter configs by glob pattern |
| `--extract-input-clips true|false` | Auto-fetch missing clips (default: `true`) |
| `--timeout S` | Timeout per test (default: `60`) |
| `--strict` | Treat dmesg warnings as failures |
| `--no-dmesg` | Disable dmesg scanning |
| `--max N` | Run at most `N` tests |
| `--stop-on-fail` | Abort suite on first failure |
| `--loglevel N` | Log level passed to `iris_v4l2_test` |
| `--repeat N` | Repeat each test `N` times |
| `--repeat-delay S` | Delay between repeats |
| `--repeat-policy all|any` | PASS if all runs pass, or any run passes |
| `--junit FILE` | Write JUnit XML |
| `--dry-run` | Print commands only |
| `--verbose` | Verbose runner logs |
| `--app /path/to/iris_v4l2_test` | Override test app path |
| `--stack auto|upstream|downstream|base|overlay|up|down` | Select target stack |
| `--platform lemans|monaco|kodiak` | Force platform (else auto-detect) |
| `--downstream-fw PATH` | **Kodiak**: path to DS firmware (e.g. `vpu20_1v.mbn`) |

---

## Pre‑Flight: Rootfs Size & Network

### Auto‑resize before downloads
The runner calls `ensure_rootfs_min_size 2` **before** any download. If `/` is on `/dev/disk/by-partlabel/rootfs` and total size is below ~2 GiB, it executes:
```sh
resize2fs /dev/disk/by-partlabel/rootfs
```

### Network bootstrap (if offline)
If the target is offline when a clip bundle is needed:

1. Tries Ethernet DHCP (safe retries)
2. If **Wi‑Fi creds** are available, tries:
   - `nmcli dev wifi connect "<ssid>" password "<pass>" ifname <iface>`  
     If NetworkManager complains about missing key‑mgmt, it auto‑falls back to:  
     ```sh
     nmcli con add type wifi ifname <iface> con-name auto-<ssid> ssid "<ssid>" \
       wifi-sec.key-mgmt wpa-psk wifi-sec.psk "<pass>"
     nmcli con up auto-<ssid>
     ```
   - If still offline, uses `wpa_supplicant + udhcpc`

**Provide credentials via:**
```sh
export SSID="WIFI_SSID"
export PASSWORD="WIFI_PASSWORD"
# or create ./ssid_list.txt with:  WIFI_PASSWORD WIFI_PASSWORD
```

---

## Stack Selection & Validation

- **lemans/monaco**
  - **Upstream**: `qcom_iris` + `iris_vpu`
  - **Downstream**: `iris_vpu` only (and *no* `qcom_iris`)

- **kodiak**
  - **Upstream**: `venus_core`, `venus_dec`, `venus_enc`
  - **Downstream**: `iris_vpu`

The runner:
1. Prints **pre/post** module snapshots and any runtime/persistent modprobe blocks
2. Switches stacks without reboot (uses runtime blacklists under `/run/modprobe.d`)
3. **Refreshes** `/dev/video*` & `/dev/media*` with udev and **prunes** stale nodes

---

## Kodiak Firmware Flows

### Downstream (custom blob)
When `--stack downstream` and you pass `--downstream-fw /path/to/vpu20_1v.mbn`:
1. The blob is copied to: `/lib/firmware/qcom/vpu/vpu20_p1_gen2.mbn`
2. Previous image is backed up to: `/opt/video-fw-backups/vpu20_p1_gen2.mbn.<timestamp>.bak`
3. Runner tries **remoteproc restart**, then **module reload**, then **unbind/bind**

### Upstream (restore a backup before switch)
When `--stack upstream` on **kodiak**, the runner tries to **restore a known‑good backup** to `/lib/firmware/qcom/vpu/vpu20_p1_gen2.mbn` **before** switching:
- Search order:
  1. `$VIDEO_FW_BACKUP_DIR` (default `/opt/video-fw-backups`), newest `vpu20_p1_gen2.mbn.*.bak`
  2. Legacy `/opt` patterns (e.g., `vpu20_p1_gen2.mbn.*.bak`)
- Then it attempts **remoteproc restart**; falls back as needed.

**Tip:** If you maintain backups under a custom path:
```sh
export VIDEO_FW_BACKUP_DIR=/opt
./run.sh --platform kodiak --stack upstream
```

---

## Examples

### Run all configs with auto stack
```sh
./run.sh
```

### Force downstream on lemans/monaco
```sh
./run.sh --stack downstream
```

### Force upstream on lemans/monaco
```sh
./run.sh --stack upstream
```

### Kodiak: downstream with custom firmware (live swap)
```sh
./run.sh --platform kodiak --stack downstream --downstream-fw /data/fw/vpu20_1v.mbn
```

### Kodiak: upstream with automatic backup restore
```sh
./run.sh --platform kodiak --stack upstream
# optionally pin the backup directory
VIDEO_FW_BACKUP_DIR=/opt ./run.sh --platform kodiak --stack upstream
```

### Ensure Wi‑Fi is used for downloads (if needed)
```sh
export SSID="WIFI_SSID"
export PASSWORD="WIFI_PASSWORD"
./run.sh --extract-input-clips true
```

### Use a specific app binary
```sh
./run.sh --app /data/vendor/iris_test_app/iris_v4l2_test --stack upstream
```

### Run only H.265 decode
```sh
./run.sh --pattern '*h265*Decoder.json'
```

---

## Troubleshooting

- **“No backup firmware found” on kodiak upstream switch**  
  Ensure your backups exist under `/opt/video-fw-backups` **or** legacy `/opt` with a name like `vpu20_p1_gen2.mbn.<timestamp>.bak`, or set `VIDEO_FW_BACKUP_DIR`.

- **Upstream/Downstream mismatch**  
  Check the **pre/post module snapshots**; the runner will explicitly log which modules are present/absent.

- **No `/dev/video*`**  
  The runner triggers udev and prunes stale nodes; verify udev is available and rules are active.

- **Download fails**  
  Ensure time is sane (TLS), network is reachable, and provide Wi‑Fi creds via env or `ssid_list.txt`. The downloader uses BusyBox‑compatible flags with retries.

---
