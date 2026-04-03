# TODO: Remaining Work for cosmic-comp Optimization

**Date:** 2026-03-06

---

## Current status

For the current compositor stabilization direction, use:

- [`COSMIC_COMP_SIMPLIFICATION_PLAN_2026_04_02.md`](/home/martinkavik/repos/popos_fix_vram_leak/COSMIC_COMP_SIMPLIFICATION_PLAN_2026_04_02.md)

This older file should be treated mainly as historical context for the earlier CPU/FD/screencopy investigation.

The local `fix-screencopy-cpu` worktree now includes these additional fixes on top of the earlier CPU and VRAM work:

- Surface-thread redraw gating now uses **output-local** animation state instead of the old global `animations_going()` path.
- Screencopy activity and pending-frame age now use a **monotonic clock**, so suspend/resume and wall-clock jumps cannot falsify capture state.
- Render-schedule diagnostics are now **per surface thread**, not process-global counters reset by whichever output logged first.
- Unknown recurring DRM submit failures now use **bounded backoff** instead of immediate redraw retry.
- Main-loop diagnostics now warn when `COMMIT_VISUAL_UNSCHEDULED` keeps growing over multiple intervals.
- Separate from compositor CPU work, the COSMIC panel/login path on `minotiros` also hit **FD exhaustion** (`Too many open files` -> applet `Broken pipe` storms).
- A persistent system-side mitigation is now installed at [`/etc/systemd/system/greetd.service.d/override.conf`](/etc/systemd/system/greetd.service.d/override.conf) with `LimitNOFILE=1048576`.
- A live FD logger is now available at [`cosmic-fd-monitor.sh`](/home/martinkavik/repos/popos_fix_vram_leak/cosmic-fd-monitor.sh), writing to [`fd-logs/cosmic-fd-monitor.log`](/home/martinkavik/repos/popos_fix_vram_leak/fd-logs/cosmic-fd-monitor.log).
- The FD logger is also installed as a persistent user service at [`~/.config/systemd/user/cosmic-fd-monitor.service`](/home/martinkavik/.config/systemd/user/cosmic-fd-monitor.service) and enabled for future logins.

This should make the next long-session test much more conclusive: we should be able to tell whether lag comes from cross-output redraws, lock pressure, screencopy pressure, or DRM retry loops.

---

## Next diagnostic cycle

The next test should use the **real session binary after reboot**, not only `cosmic-debug.sh`.

### Deployment flow

1. Build release binary:
   ```bash
   cd ~/repos/cosmic-comp
   cargo build --release
   ```
2. Back up the current runtime binary:
   ```bash
   sudo cp -a /usr/bin/cosmic-comp /usr/bin/cosmic-comp.backup.$(date +%Y%m%d-%H%M%S)
   ```
3. Install the new release build:
   ```bash
   sudo install -o root -g root -m 0755 \
     ~/repos/cosmic-comp/target/release/cosmic-comp \
     /usr/bin/cosmic-comp
   ```
4. Reboot and use the machine normally.
5. Collect logs from the **real COSMIC session**:
   ```bash
   journalctl --user -b 0 | grep '\[perf\]'
   ```

### What to look for after reboot

- `dominant_cause=blocked-on-lock`
- `dominant_cause=capture-pressure`
- `dominant_cause=error-retry`
- `cross_output_animations > 0`
- `visual_unscheduled` warnings
- non-zero `retry_unknown`
- panel/app stack remaining healthy with no new `Too many open files`
- FD counts in `fd-logs/cosmic-fd-monitor.log` staying roughly flat instead of climbing steadily

If the desktop becomes laggy again, the new counters should tell us which bucket it falls into instead of only showing high CPU.

---

## Still open

### 1. Runtime priority on the real session

The compositor still relies on code-level `setpriority`, but the real blocker is session `RLIMIT_NICE`.

- `data/cosmic-comp.service` is still not authoritative unless COSMIC changes how it launches the compositor.
- The real fix is still a user/session-level nice limit, for example:
  ```bash
  /etc/security/limits.d/cosmic-comp.conf
  martinkavik  -  nice  -10
  ```
- After relogin or reboot, verify:
  ```bash
  cat /proc/$(pgrep -x cosmic-comp)/limits | grep -i nice
  ps -p $(pgrep -x cosmic-comp) -o pid,ni,comm
  ```

### 2. Long-soak confirmation

We still need a real-world soak on `minotiros` after the new binary is installed:

- 2 to 4 hours of normal use
- multiple terminals / Claude sessions
- Firefox/video playback
- workspace overview open/close
- optional suspend/resume cycles only after the base long-uptime behavior is checked
- keep the FD monitor running during this soak:
  ```bash
  systemctl --user status cosmic-fd-monitor.service
  tail -f ~/repos/popos_fix_vram_leak/fd-logs/cosmic-fd-monitor.log
  ```

### 3. Potential future work if lag remains

- Real-time scheduling for surface threads (`SCHED_RR`) if nice elevation is still insufficient
- Further commit-path attribution if `blocked-on-lock` remains dominant
- Consumer-specific screencopy throttles if `capture-pressure` remains dominant
- Upstream panel/session hardening if FD counts still climb:
  - set a higher `NOFILE` limit in the COSMIC launch path by default
  - log per-process FD counts on threshold crossings
  - restart a wedged applet or panel automatically after repeated `Broken pipe` / `EMFILE`

---

## Docs to keep in sync

- `CPU_USAGE_FIX.md` is now the primary narrative doc for the CPU/stutter investigation.
- `NVIDIA_BUSY_LOOP_FIX.md` remains relevant for the NVIDIA zero-delay render timer issue.
- This file should track only the **current** remaining work and deployment/test flow, not historical stale diff counts.
