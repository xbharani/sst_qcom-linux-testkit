
# Bluetooth BT_SCAN_PAIR Test

This test automates Bluetooth scanning and pairing for embedded Linux devices using BlueZ and bluetoothctl. It is designed for use in the [qcom-linux-testkit](https://github.com/qualcomm-linux/qcom-linux-testkit) test suite.

## Features

- Scans for Bluetooth devices
- Optionally pairs with a device by name or MAC address
- Retries pairing on failure, including handling for busy/temporarily unavailable devices
- Cleans up previous pairings for repeatable CI runs
- Accepts device name/MAC as argument, environment variable, or in `bt_device_list.txt`
- Generates summary and detailed logs (`scan.log`, `pair.log`, `found_devices.log`)

## Usage

```sh
./run.sh [DEVICE_NAME_OR_MAC] [WHITELIST]
```
- `DEVICE_NAME_OR_MAC` – (optional) Device name or MAC address to pair.
  - Can also be set as `BT_NAME_ENV` or in `bt_device_list.txt`
- `WHITELIST` – (optional) Comma-separated MACs/names allowed for pairing.
  - Can also be set as `BT_WHITELIST_ENV`

If no device name is given, only scanning is performed and the test passes if devices are found.

## Examples

```sh
./run.sh [BT_NAME] [WHITELIST]
```

- `BT_NAME` - Optional. Bluetooth name or MAC to search for.
- `WHITELIST` - Optional. Comma-separated names/MACs allowed for pairing.

- Scan for any device (no pairing):

  ```
  ./run.sh
  ```

- Scan and pair with a device named "MySpeaker":

  ```
  ./run.sh MySpeaker
  ```

- Scan and pair only if device MAC is in whitelist:

  ```
  ./run.sh MySpeaker 00:11:22:33:44:55,AnotherSpeaker
  ```

- Use environment variables:

  ```
  export BT_NAME_ENV="MySpeaker"
  export BT_WHITELIST_ENV="00:11:22:33:44:55"
  ./run.sh
  ```

- Device list file (first line is used):

  ```
  echo "MySpeaker" > bt_device_list.txt
  ./run.sh
  ```

## Whitelist Usage

To ensure only known devices are considered during scan:

```sh
./run.sh JBL_Speaker "JBL_Speaker,12:34:56:78:9A:BC"
```

## Arguments & Variables

- Argument 1: Device name or MAC address (takes precedence)
- `BT_NAME_ENV`: Device name or MAC from the environment
- `bt_device_list.txt`: Fallback if argument or env is not set

## Example Summary Output

```
[INFO] 2025-06-23 10:00:00 - Starting BT_SCAN_PAIR Testcase
[INFO] 2025-06-23 10:00:02 - Unblocking and powering on Bluetooth
[INFO] 2025-06-23 10:00:05 - Devices found during scan:
Device 12:34:56:78:9A:BC SomeBTHeadset
[INFO] 2025-06-23 10:00:06 - Expected device 'SomeBTHeadset' found in scan
[PASS] 2025-06-23 10:00:08 - Pairing successful with 12:34:56:78:9A:BC
```

## Result

- PASS: Device paired (or scan-only with no target)
- FAIL: Device not found, not in whitelist, or pairing failed
- All paired devices are removed after the test

## Files Generated

- `BT_SCAN_PAIR.res`: Test PASS/FAIL/SKIP result
- `scan.log`: Output of Bluetooth device scan
- `found_devices.log`: List of discovered device names/MACs
- `pair.log`: Detailed pairing output and errors

## Troubleshooting

- Ensure `bluetoothctl`, `rfkill`, `expect`, and `hciconfig` are available.
- For headless automation, the remote device must be in pairing/discoverable mode.
- The script retries pairing if "busy" or "temporarily unavailable" errors are seen.
- Check `pair.log` and `scan.log` for detailed debug info if a failure occurs.

## Helper Functions (in functestlib.sh)

- `bt_scan_devices` – Scans and logs found BT devices
- `bt_pair_with_mac` – Attempts pairing via expect with retries
- `bt_in_whitelist` – Checks if MAC/name is in whitelist
- `bt_cleanup_paired_device` – Removes paired device by MAC

## Customization

- **Whitelist**: You can restrict scan to a whitelist of MAC addresses or names using environment variables or script customization.
- **Retries/Timeouts**: Retry and timeout values can be set in the script for more robust pairing.

## Integration with LAVA

In your LAVA job:

```yaml
deploy:
  to: tftp
  images:
    bt_device_list.txt:
      image: path/to/bt_device_list.txt
      compression: none
```

Injects a per-DUT Bluetooth configuration.

## Dependencies

- `bluetoothctl`, `expect`, `rfkill`, `hciconfig`
- BlueZ stack running on embedded Linux

## License

SPDX-License-Identifier: BSD-3-Clause-Clear
Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
