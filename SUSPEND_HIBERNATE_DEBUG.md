# Suspend/Hibernate Debug Notes

**Date:** 2026-02-27
**Scope:** System suspend failures (separate from compositor cursor/video lag work)

---

## Symptoms

- First suspend often succeeds.
- Second suspend attempt fails/hangs.
- Power LED does not show normal sleep behavior.
- System may require hard reset.
- In some failed-resume paths, primary display shows static wallpaper + frozen center cursor.

---

## What Logs Show

From boot `-1` (`journalctl -b -1`):

- `systemd-sleep: Failed to put system to sleep. System resumed again: Device or resource busy`
- `systemd-suspend.service ... status=1/FAILURE`
- `systemd-suspend.service ... Killing process ... nvidia-sleep.sh`

Kernel timeline around failed second suspend:

- `PM: suspend entry (deep)`
- `PM: suspend exit`
- immediate follow-up `PM: suspend entry (s2idle)`
- freeze failures:
  - `Freezing remaining freezable tasks failed ... wq_busy=1` (in-flight `hub_event`)
  - `Freezing user space processes failed ... task:setfont ... state:D ... console_lock`
- repeated xHCI/USB errors on `usb 1-6`:
  - `device descriptor read/64, error -110`
  - `Timeout while waiting for setup device command`
  - `device not accepting address ..., error -71`

Interpretation: second suspend failure is primarily a **system sleep path freeze** (USB/xHCI + tty font setup), not just a compositor redraw bug.

---

## Existing NVIDIA Suspend Prereqs Found (Likely Prior Manual Setup)

These are already present and likely what made NVIDIA suspend/resume work at all before:

1. **GRUB kernel arg is already set**
   - `/etc/default/grub` has:
     - `GRUB_CMDLINE_LINUX_DEFAULT="quiet splash nvidia.NVreg_PreserveVideoMemoryAllocations=1"`
   - `/proc/cmdline` confirms it is active at runtime.

2. **Persistent NVIDIA modprobe tuning already exists**
   - `/etc/modprobe.d/nvidia.conf` (owner: `martinkavik`) sets:
     - `NVreg_PreserveVideoMemoryAllocations=1`
     - `NVreg_TemporaryFilePath=/var/tmp`
   - `/etc/modprobe.d/nvidia-power-management.conf` sets the same values.
   - There is also distro-generated `/etc/modprobe.d/nvidia-graphics-drivers-kms.conf` with preserve enabled.

3. **NVIDIA sleep integration services are enabled**
   - `nvidia-suspend.service`
   - `nvidia-resume.service`
   - `nvidia-hibernate.service`
   - Also linked from `/etc/systemd/system/systemd-suspend.service.wants/`:
     - `nvidia-suspend.service`
     - `nvidia-resume.service`

4. **Runtime state confirms preserve mode is active now**
   - `/proc/driver/nvidia/params` shows:
     - `PreserveVideoMemoryAllocations: 1`
     - `TemporaryFilePath: "/var/tmp"`

---

## Changes Applied Now

### 1) Disable vtconsole font hook that can block suspend

Updated:
- `/etc/console-setup/cached_setup_font.sh`

New behavior:
- no longer runs `setfont` loops on vtconsole add events
- only creates `/run/console-setup/font-loaded` and exits

Reason:
- logs show `setfont` stuck in `D` state during suspend freeze phase.

### 2) Force single suspend mode (deep)

Added:
- `/etc/systemd/sleep.conf.d/10-force-deep.conf`

```ini
[Sleep]
SuspendState=mem
MemorySleepMode=deep
```

Reason:
- avoid deep->fallback retry chains in one suspend operation.
- fail fast if deep path cannot proceed instead of entering unstable mixed states.

### 3) Suspend-only mitigation for unstable USB root port 1-6 (xHCI)

Observed repeatedly in kernel logs:

- `usb 1-6 ... error -110`
- `device not accepting address ... error -71`
- `xhci_hcd ... Timeout while waiting for setup device command`

These failures correlate with suspend freeze failures (`hub_event` busy workqueue and failed task freezing).

Originally applied:

- Immediate disable at runtime:
  - `/sys/bus/usb/devices/1-0:1.0/usb1-port6/disable = 1`
- Boot persistence service:
  - `/etc/systemd/system/disable-usb1-port6.service`
- Sleep-cycle persistence hook:
  - `/lib/systemd/system-sleep/20-disable-usb1-port6`

Update on 2026-03-20:

- `usb 1-6` was confirmed to be the `Superlux L401U` USB headset/microphone:
  - kernel log showed `usb 1-6 ... Product: L401U`, `Manufacturer: Superlux`
- Permanent boot-time disable made the microphone/headphones disappear after each reboot.
- Current configuration:
  - boot persistence service `disable-usb1-port6.service` is **disabled**
  - `/lib/systemd/system-sleep/20-disable-usb1-port6` now disables the port only on suspend `pre`
  - the same hook re-enables the port on resume `post`

Impact:

- While the machine is awake, devices on USB root port `1-6` should remain available.
- During suspend entry, that port is still temporarily disabled to keep it out of the freeze path.
- After resume, the device on `1-6` must re-enumerate cleanly.
- Other USB ports/devices are unaffected.

---

## Frozen Monitor After Resume (2026-03-17)

### Symptom

One monitor frozen after resume — static image, no updates. Other monitor works fine. Mouse cursor may or may not move on the frozen screen. Super+W (workspace overview) may also get stuck and refuse to dismiss, because the animation cannot complete on the frozen output.

Observed across multiple resume cycles — **both** monitors are vulnerable (not just one):
- Resume 5 (Mar 17 11:47): DP-1 froze, HDMI-A-1 OK
- Resume 6 (Mar 17 17:36): HDMI-A-1 froze, DP-1 OK

### Root Cause

NVIDIA driver (580.x) loses a DRM page flip VBlank callback for one output after S3 resume. The cosmic-comp surface thread enters `WaitingForVBlank` state and never receives the completion event, permanently stalling the render loop for that output.

### Diagnosis

Check surface thread perf logs — the frozen output stops logging entirely:

```bash
journalctl -b --identifier cosmic-comp -o json | python3 -c "
import sys, json
from datetime import datetime
for line in sys.stdin:
    try:
        j = json.loads(line)
        msg = j.get('MESSAGE','')
        if 'surface thread stats' in msg:
            ts_us = int(j.get('__REALTIME_TIMESTAMP', '0'))
            dt = datetime.fromtimestamp(ts_us / 1e6)
            output = j.get('F_OUTPUT','?')
            frames = j.get('F_FRAMES','?')
            fps = j.get('F_FPS','?')
            print(f'{dt:%Y-%m-%d %H:%M:%S} | {output:12s} | frames={frames:>5s} fps={fps:>5s}')
    except: pass
" | tail -30
```

Expected: both outputs log every 60s. Broken: frozen output has zero entries after resume.

### Quick Fix

Toggle the frozen output off/on to force surface re-creation:

```bash
cosmic-randr disable <OUTPUT> && sleep 2 && cosmic-randr enable <OUTPUT>
```

### Permanent Fix

VBlank timeout watchdog added to `cosmic-comp/src/backend/kms/surface/mod.rs`. On every page flip, a 500ms timeout timer is scheduled. If the VBlank callback doesn't arrive in time, the surface thread auto-recovers: discards the stuck frame and queues a fresh render. Log message: `VBlank timeout — recovering from lost page flip event`.

### Affected Hardware

- NVIDIA GeForce RTX 2070, driver 580.126.09
- Dual-monitor: DP-1 (Dell U2515H 2560x1440) + HDMI-A-1 (BenQ GW2470 1080p)
- Either output can freeze (alternates between DP-1 and HDMI-A-1 across resume cycles)
- Super+W (workspace overview) gets stuck when an output is frozen — same root cause

---

## Current Risk/Status

- This reduces one known userspace blocker (`setfont`) and enforces deterministic sleep mode.
- A major hardware/driver contributor (`usb 1-6`) is now mitigated only during the suspend window, not permanently while awake.
- If suspend still fails intermittently, next step is hardware isolation (disconnect/inspect device or internal header behind root port `1-6`).
- Frozen-monitor-after-resume now auto-recovers via VBlank timeout watchdog (500ms).

---

## Quick Verification

After reboot:

1. Confirm effective sleep config:
   - `systemd-analyze cat-config systemd/sleep.conf`
2. Confirm the boot-time port-disable service is not enabled:
   - `systemctl is-enabled disable-usb1-port6.service`
   - expected result: `disabled`
3. Confirm the Superlux is present while awake:
   - `lsusb | grep -i superlux`
   - `wpctl status | grep -A4 L401U`
4. Run 3 suspend/resume cycles in a row.
5. If failure happens, collect:
   - `journalctl -b --no-pager --grep 'Failed to put system to sleep|Freezing user space processes failed|task:setfont|usb 1-6|xhci_hcd|systemd-suspend.service'`

---

## Revert

```bash
sudo rm -f /etc/systemd/sleep.conf.d/10-force-deep.conf
sudo systemctl disable --now disable-usb1-port6.service
sudo rm -f /etc/systemd/system/disable-usb1-port6.service
sudo rm -f /lib/systemd/system-sleep/20-disable-usb1-port6
echo 0 | sudo tee /sys/bus/usb/devices/1-0:1.0/usb1-port6/disable
sudoedit /etc/console-setup/cached_setup_font.sh
sudoedit /etc/console-setup/cached_setup_terminal.sh
sudo systemctl daemon-reload
```
