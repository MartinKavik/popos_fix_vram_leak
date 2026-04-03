# Lag Rerender Investigation - 2026-03-30

## Current Session

- Running `cosmic-comp` PID `2163` is still a deleted old binary:
  - `/proc/2163/exe` -> `/usr/bin/cosmic-comp (deleted)`
  - running hash: `25d5a1b0ad8fec1744ef52e2704835352fbccb666e1a7de5adfb0a05a98d2a8c`
- Installed compositor for the next session:
  - `/usr/bin/cosmic-comp`
  - hash: `e9119244abe0930aa25250d31b2e9a732e265d61e1540cbcb917415fe732f985`
- The live lag before reboot was therefore measured on the stale compositor, not the newly installed one.

## What Was Verified Against `fix-screencopy-cpu`

Both repos are still based on the same commit:

- `fix-screencopy-cpu`: `0f411a6affe26c0c0f362593d144e4399a5c718b`
- `background-window-rules`: `0f411a6affe26c0c0f362593d144e4399a5c718b`

Confirmed present in `background-window-rules`:

- NVIDIA overload timing and `next_render_time()` fix
- active screencopy tracking via `mark_capture_active()` / `is_capture_active()`
- pending-frame age tracking for bounded screencopy skipping
- per-output animation scheduling via `animations_going_for_output()`
- main-loop perf counters
- render coalescing
- focused-output input redraw path
- commit read-lock fast path

## Change Made

The compositor commit scheduler in `background-window-rules` had drifted beyond `fix-screencopy-cpu`:

- it tried `render_output_for_surface(...)` for broader hidden-surface redraw attribution
- if no output could be attributed, it scheduled every output once as a correctness fallback

That logic was removed from:

- `src/wayland/handlers/compositor.rs`

The hot commit scheduling path now matches the original `fix-screencopy-cpu` behavior again:

- schedule the visible output when available
- otherwise schedule only an animating workspace output
- otherwise only log the unmapped visual commit warning

## Intentionally Kept Divergent

The following original-branch optimization was **not** restored because it previously broke screenshot/overview capture:

- the "empty screencopy damage => immediate success" shortcut in `src/backend/kms/surface/mod.rs`

This means the installed compositor keeps the core lag fixes from `fix-screencopy-cpu`, while avoiding the known screenshot regression from that specific optimization.

## Build / Install

- `cargo check -p cosmic-comp` passed
- `cargo build --release -p cosmic-comp` passed
- installed `/usr/bin/cosmic-comp` from:
  - `~/repos/cosmic-comp-background-window-rules/target/release/cosmic-comp`

