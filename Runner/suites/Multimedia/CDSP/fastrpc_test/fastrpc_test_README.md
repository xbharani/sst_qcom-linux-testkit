# FastRPC Test Script for Qualcomm Linux-based Platforms (Yocto)

## Overview

The **fastrpc_test** runner validates FastRPC (Fast Remote Procedure Call) on Qualcomm targets, offloading work to DSP domains (e.g., **CDSP**).  
It wraps the public [fastrpc test application](https://github.com/quic/fastrpc) with **robust logging, parameter control, and CI-friendly output**.

Supported capabilities:
- Auto-detect architecture from SoC ID.
- Multiple iterations and optional timeouts.
- Precise control over where the binary and assets live via `--bin-dir` and `--assets-dir`.
- Unbuffered output via `stdbuf` or `script` when available (falls back gracefully).

## Features

- **Calculator**, **HAP**, and **Multithreading** examples (as provided by `fastrpc_test`)
- CI-ready logs with timestamps and per-iteration results
- Parameterized control (`--arch`, `--repeat`, `--timeout`, `--bin-dir`, `--assets-dir`, `--verbose`)
- Auto-detection fallback for binary and assets
- Silent directory scan (no noisy `ls` dumps)

## Prerequisites

Have these on the target (or specify paths with the flags below):

- `fastrpc_test` binary (from [github.com/quic/fastrpc](https://github.com/quic/fastrpc))
- A **parent directory** that contains a `linux/` subfolder with the required libraries (often alongside the binary), and architecture folders such as `v68`, `v73`, `v75`.
- Optional but recommended:
  - `stdbuf` **or** `script` (for unbuffered stdout/stderr)
  - `timeout` (GNU coreutils) for wall-clock limiting; the script provides a portable fallback if missing.

## Directory Structure

```bash
Runner/
├── suites/
│   ├── Multimedia/
│   │   ├── CDSP/
│   │   │   ├── fastrpc_test/
│   │   │   │   ├── run.sh
│   │   │   │   ├── fastrpc_test_README.md 
```

## Usage

### Script arguments

```
Usage: run.sh [OPTIONS]

Options:
  --arch <name>        Architecture (auto-detected from SoC if omitted)
  --bin-dir <path>     Directory that contains the 'fastrpc_test' binary
  --assets-dir <path>  Directory that CONTAINS 'linux/' (libs/assets parent)
  --repeat <N>         Number of iterations (default: 1)
  --timeout <sec>      Timeout per run (no timeout if omitted)
  --verbose            Extra logging for CI debugging
  --help               Show this help

Binary & assets resolution (in order):
  Binary:   1) --bin-dir  2) $PATH (command -v fastrpc_test)
  Assets:   1) --assets-dir
            2) <bin-dir> (if provided)
            3) directory of resolved binary
            4) directory of this run.sh
            5) common locations: /usr/share/bin, /usr/share/fastrpc, /opt/fastrpc
The test executes FROM the assets directory so 'fastrpc_test' can find deps.
```

### Quick start

```bash
# If fastrpc_test is already in PATH and assets are discoverable:
./run.sh --repeat 3 --timeout 60
```

### Common scenarios

```bash
# 1) Binary in a custom folder; assets are alongside it (i.e., that folder has linux/)
./run.sh --bin-dir /opt/qcom/fastrpc --repeat 5

# 2) Binary in PATH; assets somewhere else
./run.sh --assets-dir /opt/qcom/fastrpc_assets --timeout 45

# 3) Both explicitly provided (most deterministic)
./run.sh --bin-dir /opt/qcom/fastrpc/bin --assets-dir /opt/qcom/fastrpc --arch v75 --repeat 10 --timeout 30 --verbose

# 4) Force architecture (skip SoC autodetect)
./run.sh --arch v68
```

### Sample output (trimmed)

```
[INFO] 2025-08-13 09:12:01 - -------------------Starting fastrpc_test Testcase----------------------------
[INFO] 2025-08-13 09:12:01 - Buffering: stdbuf -oL -eL | Timeout: 60 sec | Arch: v68
[INFO] 2025-08-13 09:12:01 - Resolved binary: /usr/bin/fastrpc_test
[INFO] 2025-08-13 09:12:01 - Assets dir: /usr/bin (linux/ expected here)
[INFO] 2025-08-13 09:12:01 - Running iter1/3 | start: 2025-08-13T09:12:01Z | cmd: fastrpc_test -d 3 -U 1 -t linux -a v68
... fastrpc_test output ...
[PASS] 2025-08-13 09:12:05 - iter1: pattern matched
[INFO] 2025-08-13 09:12:05 - Running iter2/3 | start: ...
...
[FAIL] 2025-08-13 09:12:15 - fastrpc_test : Test Failed (2/3) | logs: ./logs_fastrpc_test_20250813-091201
```

## CI debugging aids

- Per-iteration logs: `logs_fastrpc_test_<timestamp>/iterN.out` (+ `iterN.rc`)
- Summary result file: `fastrpc_test.res` (`PASS` / `FAIL`)
- Verbose mode: adds environment, resolutions, and timing details
- Graceful fallbacks when `stdbuf`, `script`, or `timeout` are missing
- Silent scan (no directory spam) during auto-detection

## Notes

- If `--arch` is omitted, the script maps `/sys/devices/soc0/soc_id` to a known arch (defaulting to `v68` when unknown).
- If `fastrpc_test` isn’t in `PATH`, use `--bin-dir` or add it to `PATH`.
- If you see `Error resolving path .../linux: No such file or directory`, point `--assets-dir` to the **parent** directory that actually contains a `linux/` subfolder.
- The script changes working directory to the resolved **assets** dir before invoking `fastrpc_test`, which is required for the binary to locate its shared libs/skeletons.

## License

SPDX-License-Identifier: BSD-3-Clause-Clear  
Copyright (c) Qualcomm Technologies, Inc.
