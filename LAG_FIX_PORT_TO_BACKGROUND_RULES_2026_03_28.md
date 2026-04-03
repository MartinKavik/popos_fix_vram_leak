# Long-Session Lag Fix Port to `background-window-rules`

Date: March 28, 2026

## Summary

Ported the proven long-session lag and blinking fixes from `~/repos/cosmic-comp` branch `fix-screencopy-cpu` into `~/repos/cosmic-comp-background-window-rules`, keeping the newer background-workspace behavior in place.

This was necessary because the live system had been rebooted onto `/usr/bin/cosmic-comp` built from `cosmic-comp-background-window-rules`, while the long-session fixes still only existed in the separate `fix-screencopy-cpu` worktree.

## What Was Ported

- NVIDIA render timer fix in `src/backend/kms/surface/timings.rs`
  - stop returning zero delay on NVIDIA
  - sleep until near-vblank instead of busy-looping
- Screencopy activity/throttle fixes
  - `mark_capture_active()` / `is_capture_active()`
  - only fast-throttle active consumers
  - reduce fast screencopy throttle from 60 FPS to 30 FPS
  - edge-triggered output wakeup when output frame queue goes idle -> active
  - bounded screencopy skipping under overload
  - empty-damage fast path
- Render scheduling and lock-contention fixes
  - focused-output-only redraw on input
  - output-local animation scheduling
  - throttled main-loop animation updates
  - commit-handler read-lock fast path with write-lock only for real mutations
  - render request coalescing
- Recovery/diagnostics
  - VBlank timeout watchdog
  - DRM submit retry/backoff and recovery path
  - XWayland primary-output retry
  - perf counters and diagnostics needed for future soak-test attribution

## Build and Install

Built successfully in:

- `~/repos/cosmic-comp-background-window-rules`
  - `cargo check -p cosmic-comp`
  - `cargo build --release -p cosmic-comp`

Installed:

- source: `~/repos/cosmic-comp-background-window-rules/target/release/cosmic-comp`
- destination: `/usr/bin/cosmic-comp`

Installed hash:

- `34ee67aa63034d922478d8700fee8e34ab7a0f04bc731961a7db28cd4bf6be9d`

Install time:

- `/usr/bin/cosmic-comp` updated on March 28, 2026 at `00:20:46 +0100`

## Important Runtime Note

The currently running compositor process was **not** replaced in-place by this install.

At install time:

- running process: `/proc/2142/exe`
- running hash: `ca74329d759c2a56cb259ad8456079a5f6fead9370133c238dfa741962dd02dd`
- installed `/usr/bin/cosmic-comp` hash: `34ee67aa63034d922478d8700fee8e34ab7a0f04bc731961a7db28cd4bf6be9d`

So a fresh session, relogin, or reboot is required before testing whether the lag regression is fixed.

## Service File Note

The compositor repo also contains a `data/cosmic-comp.service` change for:

- `Nice=-5`
- `LimitNICE=-5`

That unit file was **not** installed as part of this deployment, and on this machine there is no active packaged `cosmic-comp.service` under `/usr/lib/systemd` or `/etc/systemd`. As already noted in `CPU_USAGE_FIX.md`, the session does not currently appear to be launched from a dedicated `cosmic-comp.service` unit, so the binary install is the operative deployment step here.
