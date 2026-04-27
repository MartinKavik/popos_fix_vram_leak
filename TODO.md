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
- Render-schedule diagnostics are now emitted **per surface thread** with per-output request/coalescing counters.
- Unknown recurring DRM submit failures now use **bounded backoff** instead of immediate redraw retry.
- Main-loop diagnostics now warn when `COMMIT_VISUAL_UNSCHEDULED` keeps growing over multiple intervals.
- Surface-thread perf logs now also include **avg render/submit/frame times**, postprocess usage, multigpu usage, cleanup time, and output scale.
- Texture-cache cleanup on KMS is now **throttled** instead of running after every single frame.
- A new plain-tree release build was deployed on **2026-04-11**:
  - source: [`~/repos/cosmic-comp/target/release/cosmic-comp`](/home/martinkavik/repos/cosmic-comp/target/release/cosmic-comp)
  - installed: [`/usr/bin/cosmic-comp`](/usr/bin/cosmic-comp)
  - currently restored stable SHA-256: `f04448abac0cdc72ab4387bbd018eab135956a178726952acd835c1cc2b817fe`
  - restored from: [`/usr/bin/cosmic-comp.backup.20260411-185301`](/usr/bin/cosmic-comp.backup.20260411-185301)
  - failed candidate SHA-256: `65f0b25dabec25bd95b7aab81e19bccfe3464310c8494ebfcb844067ec416e3f`
  - this candidate was backed out after the April 11, 2026 `20:01` boot failed during startup with the same `/dev/dri/card1` EGL init error (`eglInitialize: DRI2: gbm device using incorrect/incompatible backend`)
  - the failed candidate had these scheduling-focused changes:
    - visible surface commits now schedule both the shell-visible output and the primary-scanout output when they disagree
    - main-loop perf logs now include `commit_output_mismatch` and mismatch offender summaries
    - frame callbacks now prefer the shell-visible output when primary-scanout attribution lags or is missing
    - main-loop perf logs now include `frame_callback_visible_override` and override offender summaries
    - seat active-output changes now schedule redraw on both the previous and new outputs so cursor/focus-owned surfaces do not wait for an unrelated later trigger
  - backup of the failed candidate: [`/usr/bin/cosmic-comp.backup.20260411-194146`](/usr/bin/cosmic-comp.backup.20260411-194146)
  - startup regression note:
    - the prior build `1a648d689e2b7fa11719022d732ff89ae4528fd86f53cb3849bd0e66cbe49141` failed on the April 11, 2026 boot during KMS/EGL bring-up with `eglInitialize: DRI2: gbm device using incorrect/incompatible backend`
    - the retry/backoff test build `402a7f647e7251e1af19f3a229c1dc0596e360cf955fc738f85ad01368ae6c3e` also failed on the April 11, 2026 boot after 8 `init_egl()` retries and was removed from `/usr/bin/cosmic-comp`
    - that retry test build was preserved at [`/usr/bin/cosmic-comp.backup.20260411-140100`](/usr/bin/cosmic-comp.backup.20260411-140100)
  - current repo-only debug pass:
    - adds startup logs around backend/KMS/EGL device selection and initialization
    - adds main-loop counters for frame-callback routing, duplicate suppression, missing callback targets, and callbacks routed to another output
    - adds surface-thread counters for schedule dispatches, redraw queueing/deferral, estimated-vblank queue/fire, empty frames, and callback batch emission
    - adds ownership-drift counters for:
      - `visible_output_for_surface` resolution path, ambiguous matches, and missing visible output
      - `update_primary_output` visit/change/missing/mismatch summaries
      - `take_presentation_feedback` missing-primary and wrong-output attribution summaries
    - adds one more scheduling pass for the next reboot:
      - `kms_schedule=...` counters for direct, mirror, and zero-match KMS wakeups
      - `pointer_active_output_switches` counters for pointer-driven seat output changes
    - attempted debug boot artifact SHA-256: `02f4743346fbddaeb0d3396ff52f9d37e36b690b65a714f39124d07004ad8ad5`
    - this build was installed on 2026-04-12 and then failed on the next boot with the same `/dev/dri/card1` EGL init error:
      - `eglInitialize: DRI2: gbm device using incorrect/incompatible backend`
      - `Failed to add device /dev/dri/card1: Failed to create EGLDisplay for device`
      - `Backend initialized without output`
    - rollback after failed boot:
      - restored `/usr/bin/cosmic-comp` to `f04448abac0cdc72ab4387bbd018eab135956a178726952acd835c1cc2b817fe`
      - restored from [`/usr/bin/cosmic-comp.backup.20260412-134118`](/usr/bin/cosmic-comp.backup.20260412-134118)
      - failed debug candidate preserved at [`/usr/bin/cosmic-comp.backup.20260412-152556`](/usr/bin/cosmic-comp.backup.20260412-152556)
    - current repo-only boot-safer debug candidate:
      - release artifact SHA-256: `f5b25e1bee116ef97a26f0052751dfd6c91d6381fca3aec00a8eb917e2ec5f93`
      - keeps the ownership, frame-callback, presentation-feedback, `kms_schedule=...`, and `pointer_active_output_switches` diagnostics
      - removes the two post-`f04448...` runtime behavior changes from the default path:
        - frame callbacks no longer prefer the shell-visible output over primary scanout
        - active-output changes no longer force redraw nudges on both old and new outputs
      - this candidate was installed on 2026-04-12 and failed again on the next boot
        - installed `/usr/bin/cosmic-comp`: `f5b25e1bee116ef97a26f0052751dfd6c91d6381fca3aec00a8eb917e2ec5f93`
        - rollback backup: [`/usr/bin/cosmic-comp.backup.20260412-161955`](/usr/bin/cosmic-comp.backup.20260412-161955)
      - failure on the 2026-04-12 18:34 boot:
        - `eglQueryDeviceStringEXT: EGL_BAD_PARAMETER`
        - `eglInitialize: DRI2: gbm device using incorrect/incompatible backend`
        - `Failed to add device /dev/dri/card0: Failed to create EGLDisplay for device`
        - `Backend initialized without output`
        - this is the same startup class as the earlier bad boots, but this time on `card0` instead of `card1`
      - rollback after failed boot:
        - restored `/usr/bin/cosmic-comp` to `f04448abac0cdc72ab4387bbd018eab135956a178726952acd835c1cc2b817fe`
        - greeter/session recovered on the same boot by terminating tty1 and letting greetd respawn
        - current recovered session is again running `f04448...`
      - current startup-focused candidate installed for the next reboot:
        - installed `/usr/bin/cosmic-comp`: `480250e2e42f460ddb94d5b78faf54bf0cbbfb61eba8c2092c93797460c2d649`
        - rollback backup: [`/usr/bin/cosmic-comp.backup.20260412-185635`](/usr/bin/cosmic-comp.backup.20260412-185635)
        - concrete startup fix: removed the eager `device.try_get_render_node()` from the new EGL-device log in [`src/backend/kms/device.rs`](/home/martinkavik/repos/cosmic-comp/src/backend/kms/device.rs), which was issuing an extra early `eglQueryDeviceStringEXT` and matched the bad-boot log signature
        - also trimmed the later ownership/callback/KMS-summary debug layer back out of the build so this candidate is closer to the last known login-safe `f04448...` binary while still keeping the startup logs in `backend/mod.rs`, `backend/kms/mod.rs`, and `backend/kms/device.rs`
    - tty1 was recovered on the same boot by terminating the broken greeter session, after which a fresh greeter session started successfully on the restored `f04448...` binary
- Separate from compositor CPU work, the COSMIC panel/login path on `minotiros` also hit **FD exhaustion** (`Too many open files` -> applet `Broken pipe` storms).
- A persistent system-side mitigation is now installed at [`/etc/systemd/system/greetd.service.d/override.conf`](/etc/systemd/system/greetd.service.d/override.conf) with `LimitNOFILE=1048576`.
- A live FD logger is now available at [`cosmic-fd-monitor.sh`](/home/martinkavik/repos/popos_fix_vram_leak/cosmic-fd-monitor.sh), writing to [`fd-logs/cosmic-fd-monitor.log`](/home/martinkavik/repos/popos_fix_vram_leak/fd-logs/cosmic-fd-monitor.log).
- The FD logger is also installed as a persistent user service at [`~/.config/systemd/user/cosmic-fd-monitor.service`](/home/martinkavik/.config/systemd/user/cosmic-fd-monitor.service) and enabled for future logins.

This should make the next long-session test much more conclusive: we should be able to tell whether lag comes from cross-output animation churn, lock pressure, broad busy rendering, or DRM retry loops.

---

## Next diagnostic cycle

The next test should use the **real session binary after reboot**, not only `cosmic-debug.sh`.

### Deployment flow

1. Build release binary:
   ```bash
   cd ~/repos/cosmic-comp
   cargo build --release -p cosmic-comp
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
- `dominant_cause=cross-output-animation`
- `dominant_cause=error-retry`
- `cross_output_animations > 0`
- `visual_unscheduled` warnings
- non-zero `retry_unknown`
- large `avg_render_ms` on the slow output
- large `avg_submit_ms` / `avg_frame_ms` on the slow output
- non-zero `postprocess_frames` / `multigpu_frames` on the slow output
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

---

## April 13 17:40 live lag findings

- The session is currently running the caller-attributed debug build:
  - running `/proc/2162/exe`: `25868058edd14b385732abb9cfda1f8f546f0f89e13fc88afc7b1136bb3a5e9b`
- The strongest live lag signal is now source-attributed:
  - `schedule_request_sources=compositor.rs:462=...`
  - this is the visible-output commit path in [`src/wayland/handlers/compositor.rs`](/home/martinkavik/repos/cosmic-comp/src/wayland/handlers/compositor.rs)
  - DP-1 bad intervals were often only about `10-13 fps`, with requests dominated by that client-commit path, not by retries or unscheduled commits
- Secondary churn showed up from:
  - `schedule_request_sources=mod.rs:228=...`
  - this is the old KMS libinput handler path in [`src/backend/kms/mod.rs`](/home/martinkavik/repos/cosmic-comp/src/backend/kms/mod.rs) that scheduled **all outputs** after every input event
- During the worse cross-output intervals:
  - `commit_output_mismatch` became non-zero again
  - `cross_output_animations` became non-zero again
  - DP-1 started getting many timer-driven frames / empty frames while still avoiding DRM retry failures
- Not observed in this session:
  - no FD exhaustion regression
  - no DRM retry churn in `cosmic-comp`
  - no new compositor startup regression

## April 13 17:48 next-boot candidate

- Built and installed a narrow follow-up candidate:
  - installed `/usr/bin/cosmic-comp`: `d686272eae382f862cb009ad7a77e49440d0b82505209c03595629bbe7f12d8b`
  - rollback backup: [`/usr/bin/cosmic-comp.backup.20260413-174839`](/usr/bin/cosmic-comp.backup.20260413-174839)
- Change in this candidate:
  - after libinput events, KMS now schedules only the union of seat active outputs before/after the event, instead of scheduling every output in the shell

## April 18 14:18 staged lag fix, phase 1

- Current branch baseline for staged lag work:
  - [`fix-screencopy-cpu`](https://github.com/MartinKavik/cosmic-comp/tree/fix-screencopy-cpu)
  - latest pushed commit before this local phase: `a9a5134916b3bb59a28c6cbe37b3e6ee27677e89`
- Live profiling on the running `41baa99d85b210bd02c0ffa7e74866d7de187b6ba934abde77ca0a97dd54ea29` build still pointed at main-thread commit lookup churn:
  - `Shell::visible_output_for_surface`: about `363` calls / 5s
  - `Shell::element_for_surface`: about `712` calls / 5s
  - hot userspace frames still centered on `object_info`, `get_object_data_any`, and `Weak::upgrade`
- Implemented the first isolated patch from the staged roadmap:
  - added `Shell::resizing_element_for_surface(&WlSurface)` in [`src/shell/mod.rs`](/home/martinkavik/repos/cosmic-comp/src/shell/mod.rs)
  - changed [`src/wayland/handlers/compositor.rs`](/home/martinkavik/repos/cosmic-comp/src/wayland/handlers/compositor.rs) so normal `wl_surface.commit` no longer does a global `element_for_surface()` scan just to feed `ResizeSurfaceGrab::apply_resize_to_location(...)`
  - the commit path now looks up an element only when that mapped element already has `resize_state.is_some()`
- Validation:
  - `cargo check -p cosmic-comp` passed
  - `cargo build --release -p cosmic-comp` passed
- Installed next-session candidate:
  - installed `/usr/bin/cosmic-comp`: `5921355a2517a72f67671940d1cb221a3246088d5872036358311c05b4c394b1`
  - rollback backup: [`/usr/bin/cosmic-comp.backup.20260418-141845`](/usr/bin/cosmic-comp.backup.20260418-141845) = `41baa99d85b210bd02c0ffa7e74866d7de187b6ba934abde77ca0a97dd54ea29`
- Important:
  - the current live GUI session is still running `41baa99...`
  - `5921355...` is only on disk until the next relogin or reboot
  - do not batch the next PDF-suggested stages until this one is measured first

## April 18 16:13 staged lag fix, phase 2

- Implemented the next isolated step from the staged lag roadmap in [`src/shell/mod.rs`](/home/martinkavik/repos/cosmic-comp/src/shell/mod.rs) and [`src/shell/element/mod.rs`](/home/martinkavik/repos/cosmic-comp/src/shell/element/mod.rs):
  - added `CosmicMapped::has_toplevel_surface(&WlSurface)`
  - `Shell::visible_output_for_surface()` now tries a cheap toplevel-only match for sticky and active-workspace windows before falling back to the existing `WindowSurfaceType::ALL` scan
- Scope intentionally stayed narrow:
  - no startup-path changes
  - no KMS or seat/session changes
  - existing `ALL` behavior remains as fallback for subsurfaces and popups
- Validation:
  - `cargo check -p cosmic-comp` passed
  - `cargo build --release -p cosmic-comp` passed
- Installed next-session candidate:
  - installed `/usr/bin/cosmic-comp`: `bdcf642292dea3cef2534bc238a5bc9c0466badffd07193a42822cc8cd7c9008`
  - rollback backup: [`/usr/bin/cosmic-comp.backup.20260418-161333`](/usr/bin/cosmic-comp.backup.20260418-161333) = `5921355a2517a72f67671940d1cb221a3246088d5872036358311c05b4c394b1`

## April 20 adaptive guardrails candidate

- Live diagnostics on the indexed metrics build narrowed the remaining lag to three hot commit-path wastes:
  - resize lookup was attempted on almost every commit even with no active resize
  - mapped-element lookup was still attempted for many non-window roles and missed heavily
  - layer-surface commits were triggering `arrange()` checks that almost always ended unchanged
- Implemented a guardrailed follow-up in the plain tree:
  - commit-time resize lookup is now skipped entirely unless there is an active resize grab or a window still waiting for its final resize commit
  - non-window indexed roles now bypass mapped-element lookup in both `Common::on_commit()` and `cached_element_for_surface()`
  - full fallback scans for unresolved surfaces now use a per-surface backoff after repeated misses
  - layer-surface `arrange()` now runs only for top-level layer commits whose geometry-relevant cached state changed; unchanged layer churn is counted and temporarily backed off
- Files changed:
  - [`src/shell/mod.rs`](/home/martinkavik/repos/cosmic-comp/src/shell/mod.rs)
  - [`src/wayland/handlers/compositor.rs`](/home/martinkavik/repos/cosmic-comp/src/wayland/handlers/compositor.rs)
  - [`src/shell/layout/floating/grabs/resize.rs`](/home/martinkavik/repos/cosmic-comp/src/shell/layout/floating/grabs/resize.rs)
  - [`src/shell/layout/floating/mod.rs`](/home/martinkavik/repos/cosmic-comp/src/shell/layout/floating/mod.rs)
  - [`src/wayland/handlers/layer_shell.rs`](/home/martinkavik/repos/cosmic-comp/src/wayland/handlers/layer_shell.rs)
- Validation:
  - `cargo check -p cosmic-comp` passed
  - `cargo build --release -p cosmic-comp` passed
- Installed next-session candidate:
  - installed `/usr/bin/cosmic-comp`: `fa111d65959edf9e029ce9606b50855b749fae4b6a7f140a4c8a7c21adc2c9bf`
  - rollback backup: [`/usr/bin/cosmic-comp.backup.20260420-024242`](/usr/bin/cosmic-comp.backup.20260420-024242) = `bdab3924e0b329844b8f6b2f329c696138db4e8cfd2c3ef843626d6d22f18d8c`
  - current live session is still running the old deleted image:
    - `/proc/3184/exe` = `bdab3924e0b329844b8f6b2f329c696138db4e8cfd2c3ef843626d6d22f18d8c`
- Important:
  - the current live GUI session is still running `5921355...`
  - `bdcf642...` is only on disk until the next relogin or reboot

## April 18 17:26 staged lag fix, phase 3

- Implemented the next isolated shell-lookup step in [`src/shell/mod.rs`](/home/martinkavik/repos/cosmic-comp/src/shell/mod.rs):
  - `Shell::element_for_surface()` now checks the active workspace in each workspace set first
  - then sticky mapped windows
  - then minimized windows
  - then non-active workspaces as fallback
- Scope stayed narrow:
  - no startup-path changes
  - no KMS/render-thread changes
  - no cache/index layer yet
- Why this step:
  - live profiling on the running builds still showed `element_for_surface()` hotter than expected
  - the old ordering paid minimized/global scan cost before the common case of a visible active-workspace window commit
- Validation:
  - `cargo check -p cosmic-comp` passed
  - `cargo build --release -p cosmic-comp` passed
- Installed next-session candidate:
  - installed `/usr/bin/cosmic-comp`: `886dcc2b0d9fa96109c8d92a0f701b3370ea4cec50f1c5e51ca10b0f81a00160`
  - rollback backup: [`/usr/bin/cosmic-comp.backup.20260418-172634`](/usr/bin/cosmic-comp.backup.20260418-172634) = `bdcf642292dea3cef2534bc238a5bc9c0466badffd07193a42822cc8cd7c9008`
- Important:
  - the current live GUI session is still running `5921355...`
  - neither phase 2 nor phase 3 is active until relogin or reboot

## April 18 21:06 staged lag fix, phase 4

- Implemented the first structural cache step from the roadmap in [`src/shell/mod.rs`](/home/martinkavik/repos/cosmic-comp/src/shell/mod.rs):
  - added a lazy per-surface `SurfaceCommitLookupCache` stored in Smithay surface state
  - cache stores:
    - a weak output hint for visible-output lookup
    - a `CosmicMappedKey` hint for mapped-element lookup
  - every cache hit is validated before use; stale entries are dropped and fall back to the old scan
- The two hot commit-time paths now use that cache:
  - `Common::on_commit()` uses `shell.cached_element_for_surface(surface)` instead of unconditional `element_for_surface(surface)`
  - `Shell::visible_output_for_surface()` now checks a validated cached output hint before the full multi-output scan
  - `Shell::resizing_element_for_surface()` now checks the validated cached mapped hint before its resize-state scan
- Scope stayed narrow:
  - no startup-path changes
  - no seat/session changes
  - no KMS thread changes
  - no global surface index yet
- Why this step:
  - live profiling on the running `886dcc...` session still showed the main thread dominated by repeated Wayland object lookup churn
  - earlier reorder/fast-path changes reduced some waste but did not change the fundamental repeated commit-time lookup cost enough
- Validation:
  - `cargo check -p cosmic-comp` passed
  - `cargo build --release -p cosmic-comp` passed
- Installed next-session candidate:
  - installed `/usr/bin/cosmic-comp`: `21a655c01b754bedf21fca026850b86db12621ce79917321268a4eee0dc4cfad`
  - rollback backup: [`/usr/bin/cosmic-comp.backup.20260418-210617`](/usr/bin/cosmic-comp.backup.20260418-210617) = `886dcc2b0d9fa96109c8d92a0f701b3370ea4cec50f1c5e51ca10b0f81a00160`
- Important:
  - the current live GUI session is still running `886dcc...`
  - phase 4 is only on disk until the next relogin or reboot

## April 19 11:22 staged lag fix, combined follow-up

- Three additional lag-optimization steps were stacked on top of phase 4 and then built together:
  - cached mapped hints now validate against `WindowSurfaceType::ALL`, so subsurface/popup commits can reuse the mapped-element hint instead of falling back to a global scan
  - `visible_output_for_surface()` now uses a cached mapped hint to resolve the output directly through shell/workspace ownership before falling back to the full per-output visibility scan
  - the commit path now computes `layer_output_for_surface()` once and reuses it for both render scheduling and later layer `arrange()`, removing the duplicate layer-map scan for layer-surface commits
- These changes live in:
  - [`src/shell/mod.rs`](/home/martinkavik/repos/cosmic-comp/src/shell/mod.rs)
  - [`src/wayland/handlers/compositor.rs`](/home/martinkavik/repos/cosmic-comp/src/wayland/handlers/compositor.rs)
- Validation:
  - `cargo check -p cosmic-comp` passed
  - `cargo build --release -p cosmic-comp` passed after reboot
- Installed next-session candidate:
  - installed `/usr/bin/cosmic-comp`: `ba1092624cb1052bcfd6a0c002007b967a22891da9beef3e4746f5547b6c9f47`
  - rollback backup: [`/usr/bin/cosmic-comp.backup.20260419-112232`](/usr/bin/cosmic-comp.backup.20260419-112232) = `21a655c01b754bedf21fca026850b86db12621ce79917321268a4eee0dc4cfad`
- Important:
  - the currently running session was still the older `21a655...` image at install time
  - this combined candidate only becomes active after relogin or reboot
  - this is intended to cut cursor/input-driven cross-output redraw churn without dropping redraws on real output switches

## April 13 19:34 next-boot candidate

- Built and installed a Firefox-oriented follow-up candidate:
  - installed `/usr/bin/cosmic-comp`: `619e3f37ae1a11ab05ac500fba9624dda82f620eee5ed593c49ae94a4ab43e00`
  - rollback backup: [`/usr/bin/cosmic-comp.backup.20260413-193407`](/usr/bin/cosmic-comp.backup.20260413-193407)
- Change in this candidate:
  - `PointerAxis` now refreshes `seat.active_output()` from the real pointer location before wheel dispatch
  - post-libinput redraw scheduling now includes outputs currently under each seat's pointer, not only `active_output()` before/after the event
  - this keeps the reduced cross-output redraw scope from `d686...` but avoids starving hover/scroll updates when active-output tracking lags behind pointer ownership

## April 14 15:22 next-boot candidate

- Built and installed a stuck-output diagnostic follow-up candidate:
  - installed `/usr/bin/cosmic-comp`: `528a94ef5210f9f6891131e36716f9487382510cb2300ef801712df75b1a9e7f`
  - rollback backup: [`/usr/bin/cosmic-comp.backup.20260414-152205`](/usr/bin/cosmic-comp.backup.20260414-152205)
- Change in this candidate:
  - main-loop perf logs now include `schedule_offenders=...` with commit-level attribution by output, client, root surface, app id, title, and whether the surface is a session-lock surface
  - session-lock handler now logs `Session lock activated`, `Session lock cleared`, and `Registered session lock surface` with output/surface ids
  - this candidate is diagnostic-only and is meant to prove whether the frozen second monitor is being fed by a true lock surface or by a stale normal client such as `cosmic-greeter`

## April 16 11:02 next-boot candidate

- Built and installed a suspend/resume follow-up candidate:
  - installed `/usr/bin/cosmic-comp`: `0385b8f05b7b8afabc47c319e02fc822e595f79b1299bcd9bda39c6e50227e7a`
  - rollback backup: [`/usr/bin/cosmic-comp.backup.20260416-110205`](/usr/bin/cosmic-comp.backup.20260416-110205)
- Change in this candidate:
  - on `SessionEvent::ActivateSession`, KMS now drops the old per-output `Surface` objects before reapplying output config
  - that forces the normal output initialization path to recreate the DRM surfaces and modeset the outputs after resume instead of trying to keep the pre-suspend surface objects alive
  - this is intended to make the working live recovery (`cosmic-randr disable HDMI-A-1` + `enable HDMI-A-1`) happen automatically inside `cosmic-comp` after wake

## April 16 22:35 next-boot candidate

- Built and installed a suspend/resume follow-up candidate:
  - installed `/usr/bin/cosmic-comp`: `a8abe9eeb6e992e4b298871503c9de8b28ad48a974afdd8cba71af99b431f842`
  - rollback backup: [`/usr/bin/cosmic-comp.backup.20260416-223508`](/usr/bin/cosmic-comp.backup.20260416-223508)
- Change in this candidate:
  - `enumerate_surfaces()` now recreates a KMS `Surface` whenever a connector still has a CRTC but the compositor has intentionally dropped the old `Surface` object; previously resume/recovery could keep the `Output` object but fail to recreate the backing `Surface`
  - `resume_session()` now suspends each existing per-output `Surface` before clearing the map, instead of dropping them cold
  - post-resume DRM access recovery no longer escalates on the first submit failure inside the recovery window; it now requires repeated failures before forcing device recovery

## April 16 22:43 next-boot candidate

- Built and installed a suspend/resume + lag follow-up candidate:
  - installed `/usr/bin/cosmic-comp`: `da7f0e7e79eda764ee2ae8d9281cfaf2ccd2dbacd199e2cdb4789d49e7526a96`
  - rollback backup: [`/usr/bin/cosmic-comp.backup.20260416-224308`](/usr/bin/cosmic-comp.backup.20260416-224308)
- Change in this candidate:
  - keeps the April 16 suspend/resume fixes above
  - commit-triggered redraw scheduling now suppresses back-to-back requests from the same surface inside a 6 ms window instead of immediately calling `schedule_render()` on every commit
  - main-loop perf logs now include `commit_schedule_suppressed` and `suppressed_schedule_offenders` so the next boot can confirm whether the dominant commit spam is actually being filtered

## April 16 23:13 corrected next-boot candidate

- Replaced the broken April 16 22:43 candidate with a corrected suspend/resume-only follow-up:
  - installed `/usr/bin/cosmic-comp`: `a8abe9eeb6e992e4b298871503c9de8b28ad48a974afdd8cba71af99b431f842`
  - rollback backup: [`/usr/bin/cosmic-comp.backup.20260416-231303`](/usr/bin/cosmic-comp.backup.20260416-231303)
- Change in this candidate:
  - keeps the April 16 suspend/resume fixes
  - removes the 6 ms commit-suppression experiment because it starved normal terminal repaint/scroll behavior in the first live boot
  - keeps the commit-output-mismatch and schedule-offender diagnostics, but no longer suppresses commit-triggered redraws

## April 17 07:19 next-boot candidate

- Built and installed a callback-routing follow-up candidate:
  - installed `/usr/bin/cosmic-comp`: `da10276f4ec4ba8897b5f231473dcd6f681a55a882098a01e812fb6af618a61f`
  - rollback backup: [`/usr/bin/cosmic-comp.backup.20260417-071923`](/usr/bin/cosmic-comp.backup.20260417-071923)
- Change in this candidate:
  - keeps the April 16 suspend/resume fixes
  - `send_frames()` now prefers the shell-visible output for recently committing surfaces instead of relying only on `surface_primary_scanout_output()`
  - adds `frame_callback_visible_override` to the 60s main-loop perf line so the next boot can show whether callbacks were being rescued from stale scanout attribution

## April 17 11:45 next-boot candidate

- Built and installed a callback-routing + input-routing follow-up candidate:
  - installed `/usr/bin/cosmic-comp`: `ecdcb925e0369de51c25c55ab953b573eec1c957b7b1d01bcc3aeeae3cbe0549`
  - rollback backup: [`/usr/bin/cosmic-comp.backup.20260417-114542`](/usr/bin/cosmic-comp.backup.20260417-114542)
- Change in this candidate:
  - keeps the April 16 suspend/resume fixes
  - keeps the April 17 frame-callback visible-output override
  - on pointer button press, `seat.active_output()` is now refreshed from the actual pointer location before focus and interaction handling, so click/hover-driven redraw decisions are less likely to stay attached to the wrong monitor

## April 17 12:04 startup-only follow-up candidate

- Built and installed a startup-regression follow-up candidate:
  - installed `/usr/bin/cosmic-comp`: `596cf090a2118fcdc70051bb995dd9eacf28b72187175c03394af5b42b8e8baf`
  - rollback backup: [`/usr/bin/cosmic-comp.backup.20260417-120417`](/usr/bin/cosmic-comp.backup.20260417-120417)
- Change in this candidate:
  - keeps the April 16 suspend/resume fixes
  - keeps the April 17 callback-routing and input-routing lag fixes
  - removes early `EGLDevice` introspection from `init_egl()` startup logging, because the failed April 17 boot showed `eglQueryDeviceStringEXT: EGL_BAD_PARAMETER` before `eglInitialize`, matching the log-only `EGLDevice` formatting path on NVIDIA

## April 17 12:18 startup-retry follow-up candidate

- Built and installed a startup-regression follow-up candidate:
  - installed `/usr/bin/cosmic-comp`: `e66fd1164e9fbd8dc6f53d5b3fd10bb258b45d8a10d4f0ed7e22375b55a01060`
  - rollback backup: [`/usr/bin/cosmic-comp.backup.20260417-121802`](/usr/bin/cosmic-comp.backup.20260417-121802)
- Change in this candidate:
  - keeps the April 16 suspend/resume fixes
  - keeps the April 17 callback-routing and input-routing lag fixes
  - adds bounded retry around DRM/GBM/EGL device bring-up in `device_added()`, reopening the DRM node on each attempt before giving up
  - rationale: the same post-April-17 binary family sometimes reached normal scheduling logs and sometimes died immediately with `eglInitialize: DRI2: gbm device using incorrect/incompatible backend`, which points to a timing-sensitive startup failure rather than a clean deterministic bad path

## April 17 12:35 non-fatal zero-output startup follow-up candidate

- Built and installed a startup-regression follow-up candidate:
  - installed `/usr/bin/cosmic-comp`: `452193ab0a50bff93b062ae209edbe024850a5c9a94ba0b99a6034ac7e48112f`
  - rollback backup: [`/usr/bin/cosmic-comp.backup.20260417-123522`](/usr/bin/cosmic-comp.backup.20260417-123522)
- Change in this candidate:
  - keeps the April 16 suspend/resume fixes
  - keeps the April 17 callback-routing and input-routing lag fixes
  - keeps the bounded startup retry inside `device_added()`
  - stops treating `Backend initialized without output` as fatal for KMS during initial startup
  - adds delayed DRM device re-enumeration retry from the KMS backend when startup comes up with zero outputs
  - defers initial seat creation until an output actually exists, then finishes the greeter seat initialization at that point
- Investigation result supporting this change:
  - a direct `/dev/dri/card1` GBM/EGL probe from TTY succeeded repeatedly, including with DRM client capabilities enabled, so the NVIDIA GBM/EGL path itself is not generically broken
  - the compositor-specific failure is therefore more likely “startup sequencing leaves KMS with zero usable outputs for a moment” than “GBM/EGL can never initialize on this machine”

## April 17 12:46 seatless-startup panic follow-up candidate

- Built and installed a startup-regression follow-up candidate:
  - installed `/usr/bin/cosmic-comp`: `c72248d0aaf77319b5780ba5195857f43b5ca758d755d398a15314145e580e2a`
  - rollback backup: [`/usr/bin/cosmic-comp.backup.20260417-124627`](/usr/bin/cosmic-comp.backup.20260417-124627)
- Change in this candidate:
  - keeps the April 16 suspend/resume fixes
  - keeps the April 17 callback-routing and input-routing lag fixes
  - keeps the non-fatal zero-output KMS startup and delayed DRM retry
  - fixes the new panic exposed by that path: input now skips seat-dependent processing until a seat exists, and `ensure_initial_seat()` attaches already-known libinput devices to the first seat once an output appears
- Investigation result supporting this change:
  - the April 17 12:35 candidate no longer exited at `Backend initialized without output`, but then panicked on the first libinput event with `No seat?` in `process_input_event`
  - that meant the zero-output startup path was viable in principle, but needed seatless-input handling to stay alive long enough for delayed KMS recovery to work

## April 17 12:56 debug-only seatless-Xwayland follow-up candidate

- Built and installed a debug-only startup-regression follow-up candidate:
  - built with `cargo build -p cosmic-comp`
  - installed `/usr/bin/cosmic-comp`: `897498a505240205318dffce53bb6f3d9dec301cb73586af19fc8803c8816287`
  - rollback backup: [`/usr/bin/cosmic-comp.backup.20260417-125608`](/usr/bin/cosmic-comp.backup.20260417-125608) = `c72248d0aaf77319b5780ba5195857f43b5ca758d755d398a15314145e580e2a`
- Change in this candidate:
  - keeps the non-fatal zero-output KMS startup, delayed DRM retry, and seat bootstrap work
  - fixes the next seatless startup panic exposed after that path survived farther: Xwayland callbacks now no-op until a seat exists instead of dereferencing `shell.seats.last_active()`
  - specifically guards X11 stacking updates, focus/eavesdropping helpers, selection forwarding, and map/move/resize/fullscreen paths when startup is still seatless
- Investigation result supporting this change:
  - the April 17 12:46 candidate no longer died in input handling, but then panicked from `update_x11_stacking_order` with `No seat?` while greetd/Xwayland was already up and KMS still had zero outputs
  - that means startup is now blocked by “Xwayland assumes a seat exists before delayed output recovery finishes”, not by the original EGL bring-up error alone

## April 17 13:08 debug-only seatless-startup protocol follow-up candidate

- Built and installed a debug-only startup-regression follow-up candidate:
  - built with `cargo build -p cosmic-comp`
  - installed `/usr/bin/cosmic-comp`: `c6449337c90cb2575d9d8d97f26f7291b9e61d4feefffacc449ad6eccde2f5fb`
  - rollback backup: [`/usr/bin/cosmic-comp.backup.20260417-130829`](/usr/bin/cosmic-comp.backup.20260417-130829) = `897498a505240205318dffce53bb6f3d9dec301cb73586af19fc8803c8816287`
- Change in this candidate:
  - keeps the zero-output KMS startup, delayed DRM retry, and earlier seatless Xwayland guards
  - changes pending windows and pending layers so they may exist before a seat/output is available and only resolve those dependencies when mapping actually happens
  - fixes the next greeter-startup panics exposed by the previous candidate:
    - `fractional_scale` no longer falls back to `last_active()` when there is still no seat/output
    - `layer_shell::new_layer_surface` no longer requires an existing seat/output just to queue the surface
    - `xdg_shell`, `xdg_activation`, `a11y`, and the compositor initial-map path now tolerate seatless startup instead of dereferencing `last_active()`
    - Xwayland map requests are now queued even before the first seat exists
- Investigation result supporting this change:
  - the April 17 12:56 candidate got past the Xwayland stacking panic, then crashed in `fractional_scale::new_fractional_scale` and later in `layer_shell::new_layer_surface`, both for the same reason: greetd protocol traffic was still reaching handlers that assumed a seat already existed
  - this candidate addresses that broader class rather than chasing single call sites

## April 17 13:34 debug-only pending-surface replay candidate

- Built and installed a debug-only follow-up candidate:
  - built with `cargo build -p cosmic-comp`
  - installed `/usr/bin/cosmic-comp`: `7243d79782166ed8e61007cdfdb8d241c57fba26a6d350626d6449b4fdc819ec`
  - rollback backup: [`/usr/bin/cosmic-comp.backup.20260417-133454`](/usr/bin/cosmic-comp.backup.20260417-133454) = `c6449337c90cb2575d9d8d97f26f7291b9e61d4feefffacc449ad6eccde2f5fb`
- Change in this candidate:
  - keeps the earlier seatless-startup fixes
  - adds an explicit replay of pending greeter/panel/window surfaces once the first seat/output becomes available, instead of waiting for those clients to commit again
  - this is wired from `ensure_initial_seat()` into the compositor initial-configure path
- Investigation result supporting this change:
  - the previous normal boot with `c644...` no longer crashed during startup at all: NVIDIA EGL initialized, both outputs were brought up, Xwayland started, and `cosmic-greeter` plus desktop components launched
  - that means the remaining failure is no longer “startup panic”; it is “visual session comes up wrong after startup survives”
  - a plausible cause is that some early greeter/layer/toplevel surfaces were queued during seatless startup and then never got remapped once seat/output recovery finished

## April 17 13:34 TTY access hardening

- Enabled and started real `getty@tty2` through `getty@tty6` systemd services.
- Rationale:
  - on bad graphical boots, `greetd` conflicts with `tty1`, and there was no reliable fallback login on other VTs
  - this does not fix the compositor bug itself, but it removes the “pulsing boot made TTY login impossible” failure mode for future debugging

## April 17 13:54 debug-only seatless commit-path follow-up candidate

- Built and deployed a debug-only follow-up candidate:
  - validated with `cargo check -p cosmic-comp`
  - built with `cargo build -p cosmic-comp`
  - active debug artifact hash: `52742ed39cbd302c1f7afd1247aed2e1f21a510b20f7d9887c950e6103ffcc75`
  - previous `/usr/bin/cosmic-comp` moved to [`/usr/bin/cosmic-comp.backup.20260417-135406`](/usr/bin/cosmic-comp.backup.20260417-135406)
  - `/usr/bin/cosmic-comp` now symlinks to `/home/martinkavik/repos/cosmic-comp/target/debug/cosmic-comp` to avoid another multi-hundred-MB copy on each debug iteration
- Change in this candidate:
  - fixes the still-active `No seat?` panic in `wl_surface.commit` while greeter surfaces are doing null commits before the first seat exists
  - widens the same seatless-startup rule to other startup-time management paths so they degrade to no-op/default behavior instead of panicking:
    - `workspace` request handling
    - `toplevel_management`
    - `image_copy_capture` cursor/session helpers
- Investigation result supporting this change:
  - the April 17 13:42 failed boot still panicked in `wayland/handlers/compositor.rs` at the null-commit path, proving the earlier “seatless startup is fixed” conclusion was wrong
  - that panic explains the `tty1` pulsing: `greetd` keeps restarting `cosmic-comp` after the crash
  - removing this panic is the first requirement before judging the later visual freeze that happens after startup survives

## April 17 14:00 deployment regression discovered

- The `13:54` deployment method was wrong:
  - `/usr/bin/cosmic-comp` was changed into a symlink pointing into `/home/martinkavik/repos/...`
  - user `cosmic-greeter` cannot traverse `/home/martinkavik` because that directory is `750`
  - result: `greetd` looped with `greeter exited without creating a session` before `cosmic-comp` emitted any logs
- Recovery action:
  - restored a real executable file at `/usr/bin/cosmic-comp`
  - restarted `cosmic-greeter.service`
  - confirmed `/usr/bin/cosmic-comp --version` works as user `cosmic-greeter`

## April 17 14:06 debug-only no-headless-greeter startup candidate

- Built and installed a debug-only follow-up candidate:
  - validated with `cargo check -p cosmic-comp`
  - built with `cargo build -p cosmic-comp`
  - installed `/usr/bin/cosmic-comp`: `a85506242a67e09ab78fb2e90f9af3fa57466b030114ed1a48f21f9f96e0a1d4`
  - rollback backup: [`/usr/bin/cosmic-comp.backup.20260417-140653`](/usr/bin/cosmic-comp.backup.20260417-140653) = `52742ed39cbd302c1f7afd1247aed2e1f21a510b20f7d9887c950e6103ffcc75`
  - deployment method: hardlink from the built debug artifact into `/usr/bin/cosmic-comp`, not a symlink into `/home`
- Change in this candidate:
  - `cosmic-comp` no longer starts XWayland or the greeter/session path while KMS has zero outputs
  - startup of the graphical session is now gated on both:
    - at least one real output existing
    - `ensure_initial_seat()` having created the first seat
  - delayed DRM enumeration retry now starts the graphical session only after that condition becomes true
- Investigation result supporting this change:
  - the previous failed boot did not panic; instead it failed EGL on `/dev/dri/card1`, fell back to `llvmpipe`, had zero outputs, and still launched `cosmic-greeter`
  - that produced a “live but blind” compositor: no real KMS output, no seat, but a headless greeter/XWayland stack still running
  - this candidate removes that invalid startup state so “no outputs yet” stays a retry condition instead of becoming a frozen graphical boot

## April 17 rollback decision

- We do **not** have a precise commit-level boundary for when the screen-freeze regression started.
- What we do know:
  - clean branch `fix-screencopy-cpu` at `4ce4f88c` is the last clean code state in this worktree
  - the freezing startup behavior came from the large uncommitted startup/debug patch stack layered on top of that commit
  - those uncommitted changes touched 21 source files and included:
    - KMS startup retry / zero-output startup
    - delayed seat/bootstrap logic
    - seatless XWayland / Wayland handler guards
    - pending-surface replay
    - no-headless-greeter startup gating
- Decision for the next iteration:
  - revert the uncommitted worktree changes completely
  - rebuild from clean `4ce4f88c`
  - deploy a release binary from that clean tree
  - for future lag work, reintroduce fixes in much smaller chunks so the exact freeze point becomes attributable

## April 17 clean-tree release rollback

- Reverted the entire uncommitted startup/debug patch stack from `/home/martinkavik/repos/cosmic-comp`, restoring the worktree to clean `4ce4f88c` on branch `fix-screencopy-cpu`.
- Built a fresh release binary from that clean tree:
  - commit: `4ce4f88c4a6487b439f5854a74996223dff21d2f`
  - built artifact hash: `350c25f94259ed2eb99ae2a029ba1ac1be6229e304aaba4b3f1ba9e4649b8574`
- Installed it to `/usr/bin/cosmic-comp`:
  - installed hash: `350c25f94259ed2eb99ae2a029ba1ac1be6229e304aaba4b3f1ba9e4649b8574`
  - rollback backup of the previously installed debug candidate: [`/usr/bin/cosmic-comp.backup.20260417-154614`](/usr/bin/cosmic-comp.backup.20260417-154614) = `a85506242a67e09ab78fb2e90f9af3fa57466b030114ed1a48f21f9f96e0a1d4`
- This rollback intentionally chooses a **clean code baseline** over the mixed April 16/17 startup experiments.
- Next lag iteration rule:
  - only introduce smaller, isolated changes on top of this clean release baseline
  - avoid mixing startup-flow changes with lag instrumentation/fixes in the same rollout

## April 17 narrow libinput redraw-targeting candidate

- Built a new release candidate on top of the clean `4ce4f88c` baseline:
  - validated with `cargo check -p cosmic-comp`
  - built with `cargo build --release -p cosmic-comp`
  - built and installed hash: `cd66dc6d8cf91c056008c694e3afe19448113b6bc001e72cbf8f12e122697697`
  - rollback backup: [`/usr/bin/cosmic-comp.backup.20260417-171519`](/usr/bin/cosmic-comp.backup.20260417-171519) = `350c25f94259ed2eb99ae2a029ba1ac1be6229e304aaba4b3f1ba9e4649b8574`
- Scope of change:
  - only `src/backend/kms/mod.rs`
  - no startup-path changes
  - no frame-callback / output-ownership changes
  - no greeter/session changes
- Hypothesis:
  - clean `4ce4f88c` still redraws **every output after every libinput event**
  - that is a known broad amplifier and likely contributes to the lag/churn shape on multi-monitor sessions
- Change:
  - after each libinput event, KMS now redraws only the union of outputs touched by seats before and after event processing:
    - `seat.active_output()`
    - `seat.focused_output()`, if any
    - the output currently containing each seat's pointer location, if any
  - this preserves old/new output redraw when pointer ownership moves, but drops the unconditional “all outputs” redraw
- Test intent for next reboot:
  - keep the current boot-safe compositor baseline
  - isolate whether narrowing this one broad input-triggered redraw path reduces lag without reintroducing startup regressions

## April 18 live lag round on `cd66dc6...`

- The reboot is running the April 17 libinput redraw-targeting candidate:
  - running `/proc/3113/exe`: `cd66dc6d8cf91c056008c694e3afe19448113b6bc001e72cbf8f12e122697697`
  - installed `/usr/bin/cosmic-comp`: same hash before the next install
- Live sampling result:
  - `cosmic-comp` main thread stayed hot at about `42%` CPU
  - per-output surface threads were comparatively cold over a 5s schedstat window:
    - main thread runtime delta: about `2.89s / 5s`
    - `surface-HDMI-A-*`: about `0.07s / 5s`
    - `surface-DP-1`: about `0.014s / 5s`
  - this rules out KMS submit / per-output render threads as the dominant bottleneck in the sampled lag window
- User-space stack sampling with `profile-bpfcc` on the running compositor pointed at Wayland object churn on the main thread:
  - hottest symbols were overwhelmingly:
    - `wayland_backend::...::object_info`
    - `wayland_backend::...::get_object_data_any`
    - `wayland_server::Weak::upgrade`
  - these are consistent with repeated `wl_surface` / surface-tree lookup work, not with render or atomic commit cost
- Code-level follow-up from that sample:
  - `shell.visible_output_for_surface()` does a full scan across outputs, layers, sticky windows, mapped windows, minimized windows, grabs, and cursor surfaces
  - `wayland/handlers/compositor.rs::commit()` calls `visible_output_for_surface()` on every surface commit to schedule output redraws
  - that is now the strongest concrete main-thread lag suspect on the clean baseline

## April 18 primary-scanout fast-path candidate

- Built and installed a follow-up release candidate on top of the `cd66dc6...` input-targeting build:
  - validated with `cargo check -p cosmic-comp`
  - built with `cargo build --release -p cosmic-comp`
  - built and installed hash: `41baa99d85b210bd02c0ffa7e74866d7de187b6ba934abde77ca0a97dd54ea29`
  - rollback backup: [`/usr/bin/cosmic-comp.backup.20260418-074418`](/usr/bin/cosmic-comp.backup.20260418-074418) = `cd66dc6d8cf91c056008c694e3afe19448113b6bc001e72cbf8f12e122697697`
- Scope of change:
  - only `src/shell/mod.rs`
  - no startup-path changes
  - no KMS init changes
  - no frame-callback routing changes
- Change:
  - `visible_output_for_surface()` now first checks the cached Smithay `surface_primary_scanout_output` for the committing surface
  - only if that cache is missing or no longer matches a live output does it fall back to the existing full scan
- Hypothesis:
  - many commits in the laggy session are paying the full visible-surface scan cost even when the compositor already has a cached primary scanout output for that surface
  - using that cached fast path should reduce the main-thread Wayland object lookup churn without changing startup behavior

## April 18 live lag round on `41baa99...`

- The current session is already running the primary-scanout fast-path build:
  - running `/proc/3229/exe`: `41baa99d85b210bd02c0ffa7e74866d7de187b6ba934abde77ca0a97dd54ea29`
  - installed `/usr/bin/cosmic-comp`: same hash
- Snapshot during the lag round:
  - `cosmic-comp` CPU about `25%`
  - main thread still dominates; surface threads do not dominate the CPU snapshot
- `profile-bpfcc` still shows main-thread Wayland object churn as the hottest class:
  - `wayland_backend::...::object_info`
  - `wayland_backend::...::get_object_data_any`
  - `wayland_server::Weak::upgrade`
- Direct uprobes on the running binary over 5 seconds:
  - `Shell::visible_output_for_surface`: `363` calls / 5s
  - `Shell::element_for_surface` (one active monomorphization): `712` calls / 5s
  - `Shell::workspace_for_surface`: no hits in the sampled window
- Interpretation:
  - the primary-scanout fast path did not eliminate the main-thread lookup churn
  - the stronger remaining suspect is repeated `element_for_surface` scanning, not `workspace_for_surface`
  - next lag iteration should target surface-to-element lookup cost, likely by adding a cheap fast path or cache before the current full workspace/sticky/minimized scans

## April 21 schedule-coalescing candidate on `fa111d...`

- Live metrics on the running `fa111d...` build narrowed the remaining lag shape:
  - lookup-path full scans are no longer the dominant cost
  - resize lookup waste is gone when no resize is active
  - unchanged layer `arrange()` churn is being skipped/backed off correctly
  - the remaining pressure is high raw visible-commit scheduling volume on the main thread
- Recent `[perf] surface lookup cache stats` intervals showed:
  - `commit_total`: about `5k-9k/min`
  - `commit_schedule_from_visible`: about `3.6k-7.9k/min`
  - `visible_path_primary_scanout`: dominant fast path, about `3k-7.7k/min`
  - `element_index_hits`: dominant, about `3.1k-7.8k/min`
  - `visible_path_full_scan`: very low
  - `element_index_role_skips`: still `0`, so non-window role gating was not the current limiter
- New hypothesis:
  - even after the lookup fixes, the main thread is still sending too many `schedule_render()` requests across the KMS surface-thread channel
  - `queue_redraw()` already coalesces inside the surface thread, but the main thread still pays to enqueue every request unless it is suppressed earlier
- Change in `src/backend/kms/surface/mod.rs`:
  - added a per-surface `render_request_pending` latch in front of `ThreadCommand::ScheduleRender`
  - main-thread `schedule_render()` now suppresses duplicate requests while one is already pending for that output surface
  - follow-up adjustment: the latch now stays set across the queued/vblank period and is only cleared when the queued redraw actually begins, plus on startup-skip and suspend/resume/DPMS-off transitions
  - added new per-output `[perf] surface schedule stats` counters at `warn` level:
    - `schedule_requested`
    - `schedule_dispatched`
    - `schedule_suppressed_pending`
    - `schedule_thread_commands`
    - `schedule_startup_skips`
    - `schedule_dpms_off_skips`
    - `queue_redraw_queued_new`
    - `queue_redraw_queued_from_estimated_vblank`
    - `queue_redraw_already_queued`
    - `queue_redraw_waiting_for_vblank`
    - `queue_redraw_force_replaced`
- Expected next-boot interpretation:
  - if `schedule_suppressed_pending` grows materially while `schedule_dispatched` falls and lag improves, the missing problem was repeated visible-commit scheduling while outputs were already queued or already waiting for vblank
  - if `schedule_dispatched` still tracks `schedule_requested` closely and lag remains, then the remaining problem is actual redraw demand rather than output scheduling churn
- April 22 follow-up on `c29f702...`:
  - the stronger vblank-spanning latch worked, especially on `DP-1`; `schedule_suppressed_pending` rose into the high hundreds / low thousands per minute and `schedule_dispatched` dropped materially
  - however, the session still lagged badly because fast-path visible commits were still extremely frequent:
    - `commit_schedule_from_visible` remained around `5k-6k/min`
    - `visible_path_primary_scanout` remained dominant
    - lookup waste stayed mostly fixed
  - new follow-up change:
    - replaced the fixed per-surface visible-commit delay with a short burst-based guard in `src/shell/mod.rs`
    - the first few rapid commits from the same surface/output still schedule normally
    - only sustained micro-bursts inside the same 8ms window are clamped
    - added new counter `commit_schedule_visible_backoff_skips` to show how much of the remaining visible-commit spam is being clamped before KMS scheduling
- April 22 render-side follow-up on `4b50b15...`:
  - current live logs showed the previous clamp fixed the video/playback regression, but lag still remained
  - the new data said lookup waste and queue buildup were no longer the main bottleneck:
    - `visible_path_full_scan=0`
    - `element_index_misses` near zero in steady windows
    - `schedule_suppressed_pending` very high on both outputs
    - yet real dispatch volume and `commit_schedule_from_visible` still stayed high
  - new hypothesis:
    - the remaining cost has moved into actual scene assembly / redraw work in `src/backend/render/mod.rs`, not commit lookup or schedule spam
  - new combined change:
    - added per-output `[perf] render assembly stats` logging at `warn` level in `src/backend/render/mod.rs`
    - new counters include:
      - `output_elements_*`
      - `workspace_elements_*`
      - `cursor_*`
      - `render_input_order_*`
      - per-stage calls / elements / time for:
        - `ZoomUI`
        - `SessionLock`
        - `LayerPopup`
        - `LayerSurface`
        - `OverrideRedirect`
        - `StickyPopups`
        - `Sticky`
        - `WorkspacePopups`
        - `Workspace`
    - added a low-risk render optimization in `cursor_elements()`:
      - skip per-output seat cursor/DnD processing when that seat has no pointer on the output and no active move/menu grab that could affect it
      - continue rendering move/menu grabs when active, because they may still span outputs
      - added `cursor_seats_total` and `cursor_seats_skipped` to show whether that filter is carrying real load
  - next-boot interpretation:
    - if `cursor_us_total` drops and `cursor_seats_skipped` is large, seat-to-output cursor/grab churn was a real contributor
    - if `stage_workspace_*` dominates, the next target is `workspace.render()` / `workspace.render_popups()`
    - if `stage_layer_surface_*` or `stage_layer_popup_*` dominates, the next target is layer-surface tree rendering rather than workspace windows
- April 24 liveness follow-up on `b20fc...`:
  - user reported the session is more usable over time, but videos / whole screens sometimes need pointer hover to resume rendering
  - diagnosis:
    - the hard visible-commit burst clamp can drop the exact commit that a frame-callback-driven client needs to advance
    - when that commit never reaches KMS scheduling, no next frame callback may be produced until unrelated pointer hover schedules a render
  - surgical change in `src/shell/mod.rs`:
    - keep the burst detector and counter path
    - stop hard-dropping saturated visible commits
    - count those cases as `commit_schedule_visible_backoff_soft_hits`
    - rely on the vblank-spanning KMS output coalescing to suppress duplicate render queue pressure without risking client starvation
  - expected result:
    - videos and animated/browser surfaces should no longer require hover to kick rendering
    - `commit_schedule_visible_backoff_skips` should stay at `0`
    - `commit_schedule_visible_backoff_soft_hits` shows how often the old hard clamp would have fired
    - if lag regresses, the next target remains workspace render assembly, not restoring hard visible-commit drops
- April 24 input-schedule follow-up on `5abaa8...`:
  - user reported the session starts getting laggy again
  - current live state:
    - running and installed compositor hash was `5abaa8aff5b75cfff14514be6850a203fe0be6c836a31bf7a7c893b5fe49d8cb`
    - `commit_schedule_visible_backoff_skips=0` and `commit_schedule_visible_backoff_soft_hits=0` in the recent windows, so the liveness fix was not the active lag source
    - lookup remained cheap: `visible_path_full_scan=0`, `element_index_misses` mostly `0`
    - render assembly was moderate, but some surface schedule intervals showed `schedule_requested` exploding far above commit count:
      - example: `DP-1 schedule_requested=14743`, `schedule_dispatched=14254`, while commit volume was only around `3k/min`
      - example: `HDMI-A-1 schedule_requested=16844`, `schedule_suppressed_pending=14815`
    - a `prompter` process was also pegging one CPU at about `100%`, so external CPU pressure was present
  - diagnosis:
    - libinput still schedules renders for active/focused/pointer outputs after every input event
    - high-rate pointer/input events can drive render schedule attempts far above display rate
  - change in `src/backend/kms/mod.rs`:
    - added input-origin render scheduling counters:
      - `input_events`
      - `input_outputs_considered`
      - `input_schedule_dispatched`
      - `input_schedule_throttled`
    - added `[perf] kms input render stats` at `warn` level
    - throttled input-origin render scheduling per output to one dispatch per `8ms`
    - client commit scheduling, layer scheduling, animation scheduling, and KMS vblank coalescing are unchanged
  - expected next-boot interpretation:
    - if `input_schedule_throttled` is high and `surface schedule stats.schedule_requested` falls, input event wakeups were a real remaining amplifier
    - if lag remains while input throttle is low, the next target is still workspace/layer render assembly or external CPU load
- April 25 pointer-motion redraw follow-up on `6d173390...`:
  - user reported the session is better but cursor movement, typing, and loading animations are still visibly laggy
  - live logs from the previous build showed:
    - input throttling was active, with large `input_schedule_throttled` counts
    - lookup/index counters remained healthy, so the lag was not caused by surface lookup fallback
    - output render assembly still ran often, especially on the output containing the pointer
    - pure pointer motion still used the broad input redraw path, which considered active output, focused output, and pointer output for each event
  - change in `src/backend/kms/mod.rs`:
    - classified input redraws into `PointerMotion` and `Broad`
    - `PointerMotion` and `PointerMotionAbsolute` now collect only outputs containing a seat pointer before/after event processing
    - keyboard, scroll, button, gesture, touch, tablet, device add/remove, and special events stay on the conservative broad path
    - expanded `[perf] kms input render stats` with split counters:
      - `input_pointer_motion_events`
      - `input_broad_events`
      - `input_pointer_motion_outputs_considered`
      - `input_broad_outputs_considered`
      - `input_pointer_motion_schedule_dispatched`
      - `input_broad_schedule_dispatched`
      - `input_pointer_motion_schedule_throttled`
      - `input_broad_schedule_throttled`
  - expected next-boot interpretation:
    - during mouse movement, `input_pointer_motion_outputs_considered` should be close to one output per motion event instead of redrawing active/focused/pointer outputs
    - the monitor not containing the pointer should show lower input-origin render pressure
    - if typing/loading animations remain laggy while pointer-motion counters are reduced, the next target is actual workspace/layer render assembly or client commit volume, not input targeting
  - validation/deployment:
    - `cargo check -p cosmic-comp` passed
    - `cargo build --release -p cosmic-comp` passed
    - installed `/usr/bin/cosmic-comp`: `de3e5d977bac95df8294ac32fd825febc1c1d9b12e07fc6a4ccb18db55114f44`
    - rollback backup: [`/usr/bin/cosmic-comp.backup.20260425-201743`](/usr/bin/cosmic-comp.backup.20260425-201743) = `b3e95efd5cd624283b3830a98773e8ec060a77fbcc8ca02c7c66762784b2dab8`
- April 25 compositor scheduler priority follow-up:
  - user reported browser/app test loops can freeze the browser and make the whole display laggy
  - live scheduler state showed a priority inversion:
    - `cosmic-comp` was `SCHED_OTHER` nice `-3`
    - Firefox and its content processes were nice `-6`
    - 1Password processes were nice `-8`
  - realtime priority was not available (`Max realtime priority 0`) and is intentionally not used, because an unbounded compositor busy loop under realtime scheduling can hard-freeze the machine
  - immediate runtime fix:
    - changed the running `cosmic-comp` PID to nice `-10`
  - persistent system fix:
    - installed [`system76-scheduler-config.kdl`](/home/martinkavik/repos/popos_fix_vram_leak/system76-scheduler-config.kdl) to [`/etc/system76-scheduler/config.kdl`](/etc/system76-scheduler/config.kdl)
    - changed the `desktop-environment` assignment from nice `-3` to nice `-10`
    - restarted `com.system76.Scheduler.service` so it reread the override
    - verified running `cosmic-comp` is now nice `-10`, ahead of Firefox/1Password but below PipeWire/audio at nice `-15`
  - queue/leak interpretation from this lag window:
    - current RSS/FDs did not show the old leak shape (`~426 MiB RSS`, `~301` FDs, no swap pressure)
    - surface scheduling already coalesces repeated render requests with `render_request_pending` and `QueueState`; this prevents an unbounded queue of render commands
    - the remaining degradation looks like sustained event/render amplification: noisy clients keep generating commits/input events, and the compositor main thread spends too much time processing them even though duplicate queued renders are suppressed
    - next compositor-side diagnostic if lag remains after reboot is per-client/per-surface commit attribution, so the logs identify which app/window is producing the commit storm
- April 25 overload/backpressure implementation TODOs and checkpoint:
  - TODO 1: add attribution without behavior change
    - implemented `[perf] commit attribution stats`
    - logs top clients and top surfaces by commit count, visible schedules, budget skips, layer schedules, misses, average commit time, and max commit time
    - client identity is currently PID plus `/proc/<pid>/comm`
  - TODO 2: add global overload detector
    - implemented `OverloadLevel::{Normal, Soft, Hard}` in `Shell`
    - detector evaluates one-second windows using commit rate, visible-schedule pressure, average commit handler time, and max commit handler time
    - logs `[perf] compositor overload transition` with the old/new level and trigger metrics
  - TODO 3: add liveness-safe visible commit admission control
    - implemented `Shell::visible_commit_schedule_decision(...)`
    - Wayland/Smithay commit processing still runs for every commit
    - only redundant render scheduling is skipped under overload
    - per-surface deadline escape hatch allows a schedule after `12ms` in `Soft` overload and `16ms` in `Hard` overload, so videos/animations should not require pointer hover to advance
    - counters:
      - `commit_schedule_visible_backoff_skips`
      - `commit_schedule_visible_backoff_soft_hits`
      - `commit_schedule_client_budget_skips`
  - TODO 4: add overload-aware input backpressure
    - pointer-motion input render interval remains `8ms` in `Normal`
    - pointer-motion interval becomes `12ms` in `Soft` and `16ms` in `Hard`
    - broad input events stay at `8ms` to keep keyboard/click/scroll responsive
    - new counters:
      - `input_overload_normal_events`
      - `input_overload_soft_events`
      - `input_overload_hard_events`
  - TODO 5: add per-client noisy-source policy
    - implemented visible scheduling budget per PID
    - `Soft` overload allows up to `90` visible schedules/sec per client
    - `Hard` overload allows up to `60` visible schedules/sec per client
    - per-surface liveness deadline can still override the client budget
    - stale client budget entries are pruned after inactivity so the budget map does not grow unbounded
  - validation:
    - `cargo check -p cosmic-comp` passed
    - `git diff --check` passed
    - `cargo build --release -p cosmic-comp` passed
    - installed `/usr/bin/cosmic-comp`: `91fd4ad831f0ed425e074e16b4d8a2bf9c99b1c2ca9778836934a62bcaa031a2`
    - rollback backup: [`/usr/bin/cosmic-comp.backup.20260425-220813`](/usr/bin/cosmic-comp.backup.20260425-220813) = `de3e5d977bac95df8294ac32fd825febc1c1d9b12e07fc6a4ccb18db55114f44`
  - next runtime interpretation:
    - if lag improves and `commit_schedule_visible_backoff_skips` / `commit_schedule_client_budget_skips` rise during overload, the new admission policy is carrying load
    - if lag remains but top client logs identify Firefox or a specific process as dominant, the next step is a tighter app-specific or surface-role-specific policy
    - if overload stays `Normal` while lag remains, the bottleneck is outside this commit/input admission path
- April 26 overload/backpressure retune after live lag returned:
  - live facts before the patch:
    - running compositor was still commit `ebef3a3b` / installed hash `91fd4ad831f0ed425e074e16b4d8a2bf9c99b1c2ca9778836934a62bcaa031a2`
    - `cosmic-comp` main thread spiked during lag while KMS surface threads were mostly idle
    - lookup/cache metrics showed the earlier lookup optimizations were working: primary-scanout/index paths dominated and full scans were near zero
    - top commit source remained Firefox, but diagnostic terminal output also created visible redraw bursts
    - overload was flapping between `Normal` and `Soft`; it did not stay active long enough and rarely reached `Hard`
    - visible commit skips were too low relative to total visible commits, so noisy clients still forced too many redraw opportunities
  - implemented commit `9546189c` in [`/home/martinkavik/repos/cosmic-comp/src/shell/mod.rs`](/home/martinkavik/repos/cosmic-comp/src/shell/mod.rs):
    - lower overload thresholds to match observed pressure: severe hard at `>=80` visible-pressure/sec or `>=140` commits/sec
    - make overload state stickier: return to `Normal` only after 10 quiet windows
    - apply visible commit pacing to every surface while overloaded, not only extreme micro-bursts
    - `Soft` overload now paces same-surface visible schedules at `24ms`
    - `Hard` overload now paces same-surface visible schedules at `33ms`
    - per-client budgets remain as a backstop: `75/sec` in `Soft`, `60/sec` in `Hard`
    - expanded overload transition logs with visible schedules/sec, layer schedules/sec, skip counts, and consecutive window counters
  - validation/deployment:
    - `cargo check -p cosmic-comp` passed
    - `cargo fmt --check` still reports pre-existing formatting drift in earlier touched files, so no whole-repo formatting was applied
    - `cargo build --release -p cosmic-comp` passed
    - installed `/usr/bin/cosmic-comp`: `3f7a8741fe80ffbe2231e67007a7c1528b974518201e93a45cb1e22b4f2c6ba4`
    - current running compositor is still old hash `91fd4ad831f0ed425e074e16b4d8a2bf9c99b1c2ca9778836934a62bcaa031a2` until compositor/session restart
    - rollback backup from the still-running old binary: [`/usr/bin/cosmic-comp.backup.20260426-145646`](/usr/bin/cosmic-comp.backup.20260426-145646)
  - next runtime interpretation:
    - after restart, overload should enter `Hard` during the visible-pressure bursts that previously only produced brief `Soft`
    - `commit_schedule_visible_backoff_skips` should rise during laggy/noisy-client periods
    - videos should continue advancing because `Hard` still allows same-surface schedules roughly every `33ms`
    - if lag remains while `Hard` and skip counters are active, the next target is render assembly or GPU/KMS submission rather than Wayland surface lookup
- April 27 multi-angle lag/degradation implementation:
  - live trigger:
    - latest installed/running compositor from April 26 was active, but `cosmic-comp` main thread still sat around `50-65%` CPU after a long session
    - lookup metrics were clean, KMS surface threads were mostly idle, and GPU/DRM fault evidence was weak
    - `prompter`, `codex`, `node`, `cosmic-term`, and `cosmic-edit` were competing with the compositor at high priority before scheduler isolation
  - scheduler checkpoint in `popos_fix_vram_leak`:
    - commit `a81e15d` lowers local dev/test tools to nice `8`, batch scheduling, idle I/O
    - verified after service restart: `cosmic-comp` stayed nice `-10`, while `prompter`, `codex`, `node`, `cosmic-term`, and `cosmic-edit` moved to nice `8`
  - compositor checkpoints in `cosmic-comp`:
    - `c6dae592` adds `[perf] main loop stats` and `[perf] overload residency stats`
    - `47eaed89` adds per-client/output visible admission and throttles unchanged layer render scheduling under overload
    - `63c57e28` caps output capture pending frames, logs `[perf] capture queue stats`, and reduces capture callback pace in `Hard`
    - `c8aa1a62` coalesces broad input redraws when an output already has pending render work under overload and adds KMS pending-age/command-latency counters
  - validation/deployment:
    - `cargo check -p cosmic-comp` passed
    - `git diff --check` passed
    - `cargo build --release -p cosmic-comp` passed
    - installed `/usr/bin/cosmic-comp`: `36cedc6702bcbbc130abd665afec2a42d52c62f2f8b6c074d578af361831f9c9`
    - backup from the previous installed binary: [`/usr/bin/cosmic-comp.backup.20260427-083424`](/usr/bin/cosmic-comp.backup.20260427-083424) = `3f7a8741fe80ffbe2231e67007a7c1528b974518201e93a45cb1e22b4f2c6ba4`
    - current running compositor remained old hash `3f7a8741fe80ffbe2231e67007a7c1528b974518201e93a45cb1e22b4f2c6ba4` until compositor/session restart
  - next runtime interpretation:
    - if lag remains, first check `[perf] main loop stats`; this should identify whether CPU is in Wayland dispatch, flush, animation update, refresh, or elsewhere
    - if visible/layer/capture/input skip counters rise and lag improves, admission pressure was the right fix direction
    - if `schedule_pending_age_ms_max` or `schedule_command_latency_ms_max` rises, investigate KMS/output queue latency
    - if capture drops rise heavily, identify the capture client before further compositor throttling
- April 27 visible-render kickstart regression fix:
  - symptom after reboot into `36cedc67`: videos/animations and some screen updates lagged or stalled unless the mouse cursor moved over them
  - likely cause: visible commit admission was skipping immediate renders under overload but did not queue a delayed render, so pointer-motion input became the accidental wakeup path
  - compositor checkpoint:
    - `748e2669` adds coalesced deferred visible renders after `VisibleBudgetSkipped` decisions
    - new counters: `commit_schedule_deferred_visible_renders` and `commit_schedule_deferred_visible_render_coalesced`
  - validation/deployment:
    - `cargo check -p cosmic-comp` passed
    - `git diff --check` passed
    - `cargo build --release -p cosmic-comp` passed
    - installed `/usr/bin/cosmic-comp`: `ed6bb24bd6c78210d324c30c0d1d526e65e24633a0447e7e0597fed8f479e793`
    - backup from the previous installed binary: [`/usr/bin/cosmic-comp.backup.20260427-090218`](/usr/bin/cosmic-comp.backup.20260427-090218) = `36cedc6702bcbbc130abd665afec2a42d52c62f2f8b6c074d578af361831f9c9`
    - current running compositor remained old hash `36cedc6702bcbbc130abd665afec2a42d52c62f2f8b6c074d578af361831f9c9` until compositor/session restart
- April 27 formatting gate fix:
  - compositor checkpoint:
    - `28fc3f64` applies `cargo fmt` to the recent lag instrumentation/backpressure files
  - validation/deployment:
    - `cargo fmt --check` passed
    - `git diff --check` passed
    - `cargo check -p cosmic-comp` passed
    - `cargo build --release -p cosmic-comp` passed
    - installed `/usr/bin/cosmic-comp`: `cd2e510cda2480cbb0e6c2da316cb1fec2ef45a6e5b5bf64fa97792a312b0c48`
    - backup from the previous installed binary: [`/usr/bin/cosmic-comp.backup.20260427-091017`](/usr/bin/cosmic-comp.backup.20260427-091017) = `ed6bb24bd6c78210d324c30c0d1d526e65e24633a0447e7e0597fed8f479e793`
    - current running compositor remained old hash `36cedc6702bcbbc130abd665afec2a42d52c62f2f8b6c074d578af361831f9c9` until compositor/session restart
- April 27 lag subagent round:
  - live finding:
    - current GUI compositor was still `/usr/bin/cosmic-comp (deleted)` = `36cedc6702bcbbc130abd665afec2a42d52c62f2f8b6c074d578af361831f9c9`
    - installed/build artifact before this round was `cd2e510cda2480cbb0e6c2da316cb1fec2ef45a6e5b5bf64fa97792a312b0c48`
    - current lag logs were therefore from the older aggressive throttling build, not from the already-installed deferred-render fix
    - logs showed persistent `Hard` overload, main-loop/refresh spikes around `260-277ms`, low KMS pending age/command latency, and no lookup churn
    - two `prompter -c` processes were using roughly one CPU core each, but were already nice `8`/batch under scheduler isolation
  - compositor checkpoint:
    - `54d123be` retunes overload so skipped visible commits cannot force/hold `Hard` without real commit/main-loop cost
    - overdue same-surface liveness now bypasses per-client/output budget so a noisy same-PID surface cannot starve another visible surface indefinitely
    - layer render throttling now resolves layer surfaces through `WindowSurfaceType::ALL`, so subsurface commits are guarded too
    - broad input redraw pending suppression now skips only when all target output surfaces already have render requests pending
    - KMS surface pending latches are cleared consistently when queued render state is discarded, and pending-age metrics now survive until the latch is cleared
    - added `[perf] common refresh stats` phase metrics to identify which refresh maintenance phase causes future stalls
  - validation/deployment:
    - `cargo fmt --check` passed
    - `git diff --check` passed
    - `cargo check -p cosmic-comp` passed
    - `cargo build --release -p cosmic-comp` passed
    - installed `/usr/bin/cosmic-comp`: `a77b33f93a3b804b62078a1455da6ec9aa294a45f460f7d8b9fc5b56c70bf0e6`
    - backup from the previous installed binary: [`/usr/bin/cosmic-comp.backup.20260427-135331`](/usr/bin/cosmic-comp.backup.20260427-135331) = `cd2e510cda2480cbb0e6c2da316cb1fec2ef45a6e5b5bf64fa97792a312b0c48`
    - current running compositor remained old hash `36cedc6702bcbbc130abd665afec2a42d52c62f2f8b6c074d578af361831f9c9` until compositor/session restart
