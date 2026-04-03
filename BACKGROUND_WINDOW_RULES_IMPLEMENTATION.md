# Background Window Rules: Implementation Handoff

## Purpose

This document records what was implemented for the Background Window Rules feature, why each part was added, what was verified, and what remains as follow-up work outside the original implementation plan.

The feature goal was to make browser or desktop-app windows opened indirectly by AI CLI tools, test runners, auth helpers, or similar automation predictable and non-disruptive in COSMIC.

## User Problem Addressed

The original problem was:

- background-launched windows could steal focus
- they could appear on the current workspace instead of a dedicated background workspace
- they did not reopen in a stable floating position
- test and agent workflows became annoying and less deterministic

The implemented feature addresses that by letting users create explicit rules that:

- match windows by app ID/X11 class, with optional title refinement
- open those windows in the background
- route them to a named workspace
- keep them floating
- remember their position

## Design Reference

The original design and user-story document lives in:

- `BACKGROUND_WINDOW_RULES.md`

That document defines the intended product behavior. This handoff document describes the concrete implementation work that was completed.

## Repo Split

The implementation was done across three COSMIC repos plus this documentation repo:

1. `cosmic-settings-daemon`
2. `cosmic-comp`
3. `cosmic-settings`
4. this repo for the design and implementation docs

All three implementation repos were on the feature branch:

- `background-window-rules`

## What Was Implemented

### 1. Documentation

Added:

- `BACKGROUND_WINDOW_RULES.md`
- `BACKGROUND_WINDOW_RULES_IMPLEMENTATION.md`

Why:

- `BACKGROUND_WINDOW_RULES.md` is the product/design reference
- this file is the engineering handoff and implementation status record

### 2. Shared Config Schema in `cosmic-settings-daemon`

Changed file:

- `config/src/window_rules/mod.rs`

What was added:

- `WindowBehaviorRule`
- `WorkspaceTarget`
- `LaunchPolicy`
- `FocusPolicy`
- `OutputSelectionPolicy`
- `behavior_rules_custom: Vec<WindowBehaviorRule>`
- helper loading for custom behavior rules

Why:

- the compositor and Settings UI need a shared persisted rule model
- rules need to express more than existing tiling exceptions
- a stable workspace target must include both a visible name and hidden stable ID

Important behavior encoded by the schema:

- background-only launches
- explicit do-not-focus policy
- optional dedicated workspace target
- optional forced floating
- optional remembered floating geometry

### 3. Compositor Behavior in `cosmic-comp`

Changed files:

- `src/config/mod.rs`
- `src/shell/mod.rs`
- `src/shell/workspace.rs`
- `src/wayland/handlers/xdg_shell/mod.rs`
- `src/xwayland.rs`
- `Cargo.toml`

What was added:

- watching and loading `behavior_rules_custom`
- shell-side storage of active behavior rules
- dynamic local state for remembered floating geometry
- map-time matching of rules against window app ID and optional title
- background-open handling without focus theft
- workspace routing by stable workspace ID
- recreation of missing auto-removed workspaces
- workspace visible-name restoration on recreation
- urgent marking of the target workspace
- forced floating for matched rules
- restore/save of remembered floating geometry keyed by rule ID
- persistence on both Wayland toplevel destroy and Xwayland unmap paths

Why:

- the compositor is the only layer that can reliably enforce focus, placement, floating, and workspace behavior
- stable workspace recreation is necessary because dynamic workspaces may disappear when empty
- geometry must be keyed by rule ID rather than transient window identity so reopened windows land in a stable place

Important implementation detail:

- valid intentional activation is preserved
- background suppression applies to background/untrusted launches
- dialogs and modal/child windows are not background-rerouted away from their parent flow

Dynamic state path used:

- `~/.local/state/cosmic-comp/window_rules_state.ron`

### 4. Settings UI in `cosmic-settings`

Changed files:

- `cosmic-settings/src/pages/desktop/window_management.rs`
- `cosmic-settings/src/subscription/mod.rs`
- `cosmic-settings/src/subscription/toplevel_windows.rs`
- `Cargo.toml`

What was added:

- a Background Window Rules section in Window Management
- listing of existing behavior rules
- add/remove/edit/toggle flows
- fields for:
  - app ID/class regex
  - optional title regex
  - open in background
  - background workspace name
  - keep floating
  - remember position
- a live open-window subscription based on the compositor toplevel-info protocol
- a capture flow that creates a rule from a currently open window
- capture prefill for exact app ID and exact title

Why:

- users need a first-party way to author and manage these rules
- the open-window capture flow makes rule authoring practical without forcing users to inspect app IDs manually
- the manual editor still exists so captured rules can be refined after creation

Capture behavior:

- the Settings page subscribes to the live toplevel list
- it shows currently open windows
- choosing `Create rule` makes a new rule with exact app ID and exact title match
- the title can be cleared after capture to widen the rule to app-wide behavior

## Cargo Patching Used During Development

To make the repos work together locally during implementation, path overrides were added so:

- `cosmic-comp` uses the local `cosmic-settings-daemon` config crate
- `cosmic-settings` uses the local `cosmic-settings-daemon` config crate

Why:

- the new shared schema exists locally and is needed immediately by the compositor and Settings app
- without local patching, those repos would keep resolving the upstream dependency that does not yet include the new rule types

## Verification Completed

Formatting:

- `cargo fmt` in `cosmic-settings-daemon`
- `cargo fmt` in `cosmic-comp`
- `cargo fmt` in `cosmic-settings`

Build verification:

- `cargo check -p cosmic-settings-config`
- `cargo check -p cosmic-comp`
- `cargo check -p cosmic-settings --no-default-features --features page-window-management,wayland`
- `cargo check -p cosmic-settings --no-default-features --features page-window-management`

Why both Settings checks were run:

- the Wayland build covers the live toplevel capture integration
- the non-Wayland page build confirms the page still compiles when the live subscription is compiled out

## What Matches the Original Plan

The original plan called for:

- a design doc first
- shared config schema
- compositor enforcement
- stable named workspace recreation
- urgency instead of focus theft
- remembered floating geometry
- Settings UI inside the normal COSMIC Settings app
- live window capture from currently open windows
- dedicated feature branches

All of those items were implemented.

## Follow-Up Work That Is Still Reasonable

The implementation plan itself is complete, but some normal follow-up work remains available if desired.

### 1. Live Runtime QA

Not yet done in this workspace:

- end-to-end validation inside a real running COSMIC session

Recommended checks:

- create a rule from a live browser window
- close the window and relaunch through an AI/test tool
- verify no focus theft
- verify no workspace switch
- verify urgent workspace indication
- verify workspace recreation after the background workspace becomes empty
- verify remembered floating geometry after move/resize/reopen
- verify dialogs still follow parent behavior

### 2. Commit and PR Preparation

Not yet done:

- create commits
- split or squash commits if needed
- prepare PR descriptions for the three implementation repos

### 3. UI Polish

Possible follow-up improvements:

- expose workspace selection with a picker instead of free-form name entry
- provide a clearer “app-wide vs exact title” toggle instead of requiring title clearing for widening the match
- show more metadata in the capture list if useful, such as workspace or activation state detail

### 4. Broader Test Coverage

Reasonable additional work:

- add automated tests if the relevant repos have the right harness points
- add regression coverage around background mapping and geometry restoration

## Known Limits of This Pass

- no live COSMIC session runtime validation was performed here
- no PRs or commits were created
- some unrelated user changes already existed in the worktrees and were intentionally left untouched
- full default `cosmic-settings` build was not the primary verification target in this environment; the targeted Window Management builds were used instead

## Summary

This feature is implemented end to end.

The main outcome is that COSMIC now has the building blocks for explicit background-window rules that stop noisy AI/test-created windows from interrupting active work, while still preserving normal intentional launches.
