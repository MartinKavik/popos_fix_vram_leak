# Background Window Rules Update: March 27, 2026

## Purpose

This document records the follow-up implementation work completed after the original background-window-rules feature landed.

The earlier docs in this repo describe the first version:

- `BACKGROUND_WINDOW_RULES.md`
- `BACKGROUND_WINDOW_RULES_IMPLEMENTATION.md`

This update covers the later fixes and scope expansion around:

- duplicate named workspaces
- workspace rename/remove support
- dragging named workspaces between monitors
- single-source-of-truth rule workspace persistence
- background windows still switching workspace/focus through activation paths
- background windows briefly mapping into the focused workspace before being moved

## Problem Summary

The earlier feature was not sufficient in practice.

Observed failures:

- moving a rule-owned workspace between monitors could leave two visible workspaces with the same name
- rule-owned workspace placement and naming still existed in two places
- empty named rule workspaces could not be removed from the overview
- named workspaces could not be renamed from the overview
- cross-monitor workspace drag was only partially wired
- a valid activation token could still override background routing
- some windows could first map into the active workspace, disturb tiling briefly, and only later get remapped when title/class metadata arrived

## Design Direction Implemented

The update intentionally removed the old compatibility-oriented shape and made the model stricter:

- rule-owned workspace identity is stored only in the window-rule config
- compositor local state no longer persists rule workspace names or preferred outputs
- named persistent workspace names must be unique
- background-only rules are authoritative over activation-token workspace switching
- a background window must go directly to its target workspace on first visible map, or stay normal forever after a short wait, but not visibly bounce between workspaces

## Shared Config Changes

Repo:

- `cosmic-settings-daemon`

Changed file:

- `config/src/window_rules/mod.rs`

Changes:

- bumped `com.system76.CosmicSettings.WindowRules` config version from `1` to `2`
- removed `OutputSelectionPolicy` from rule workspaces
- changed `WorkspaceTarget` to:
  - `workspace_id`
  - `workspace_name`
  - `keep_alive_when_empty`
  - `preferred_output`
- added explicit preferred-output schema with connector name plus optional EDID fields

Result:

- the rule config is now the single persisted authority for rule-owned workspace identity, name, keep-alive policy, and preferred output

## Compositor Changes

Repo:

- `cosmic-comp-background-window-rules`

Key files:

- `src/config/mod.rs`
- `src/shell/mod.rs`
- `src/shell/workspace.rs`
- `src/wayland/handlers/workspace.rs`
- `src/wayland/handlers/xdg_activation.rs`
- `src/wayland/handlers/xdg_shell/mod.rs`
- `src/xwayland.rs`
- `cosmic-comp-config/src/workspace.rs`

### 1. Removed duplicate persisted rule-workspace state

Changes:

- removed compositor persistence of rule workspace name/output placement from `window_rules_state.ron`
- kept only remembered floating geometry there
- kept a real `window_rules_context` handle in compositor config so workspace rename/move/remove can write directly back to `behavior_rules_custom`

Result:

- no compositor-only `background_workspaces` store remains for rule-owned workspaces

### 2. Fixed duplicate named workspaces across monitors

Changes:

- rule workspace lookup is now global by `workspace_id`
- if a matching workspace already exists on another output, the compositor migrates that workspace instead of creating another one
- sync now removes stale empty duplicates for the same `workspace_id`

Result:

- moving a rule-owned workspace to another monitor no longer creates a second live copy of the same named workspace

### 3. Added real rename/remove behavior

Changes:

- implemented Wayland workspace `Rename` handling
- implemented Wayland workspace `Remove` handling
- rename updates the live workspace label and writes the new visible name back into the owning rule
- remove is allowed only for empty non-pinned named workspaces
- removing an empty rule-owned workspace flips `keep_alive_when_empty` to `false` in the owning rule, then removes the live workspace
- pinned workspace names are now persisted through `PinnedWorkspace.name`

Result:

- the overview can now rename named workspaces and remove empty removable ones

### 4. Updated workspace capabilities

Changes:

- named persistent workspaces now advertise `Rename`
- empty removable named workspaces advertise `Remove`
- capabilities are refreshed after map/unmap/sync/pin/remove operations

Result:

- the UI can trust protocol capabilities instead of guessing which actions are legal

### 5. Fixed focus theft and workspace switching

Changes:

- `BackgroundOnly` rules now override activation-token workspace switching
- later `xdg_activation` requests for already-routed background windows only mark the target workspace urgent
- background windows do not switch active output
- background windows do not activate the target workspace
- background windows do not take keyboard focus

Result:

- preconfigured background windows stay in the background even if they arrive with a valid activation token

### 6. Fixed first-map tiling disturbance

Changes:

- removed reliance on late visible unmap/remap as the normal rule-routing path
- pending windows now wait up to `500ms` for missing title/class metadata if they could still match a background rule
- during that wait they stay pending and do not visibly map into the focused workspace
- if the rule resolves in time, the first visible map goes directly to the target named workspace
- if metadata still has not resolved after the wait, the window maps normally once and is not later cross-workspace-remapped

Result:

- no more intentional “map in current workspace first, then shove elsewhere” behavior for background-rule placement

## Settings UI Changes

Repo:

- `cosmic-settings`

Changed file:

- `cosmic-settings/src/pages/desktop/window_management.rs`

Changes:

- new rules now use the new `WorkspaceTarget` shape
- added `Keep workspace alive when empty`
- added duplicate-name validation for rule workspace names
- duplicate names now show inline validation errors instead of being silently accepted
- Settings displays the rule’s preferred output when present

Result:

- the Settings editor matches the stricter workspace model used by the compositor

## Workspace Overview Changes

Repo:

- `cosmic-workspaces-epoch`

Key files:

- `src/backend/mod.rs`
- `src/backend/wayland/mod.rs`
- `src/backend/mock.rs`
- `src/main.rs`
- `src/view/mod.rs`

Changes:

- added backend commands for:
  - `RenameWorkspace`
  - `RemoveWorkspace`
- overview now supports inline rename of named workspaces
- overview now exposes remove for workspaces that advertise `Remove`
- cross-monitor workspace drag now works by dropping onto:
  - another workspace tile
  - a monitor’s toplevel preview area
  - a monitor’s workspace bar area
- output-area drops move the workspace after the active workspace on the target monitor

Result:

- the Super+W overview is now the real control surface for named workspace management

## Verification Run

The following builds were run after the changes:

- `cargo check -p cosmic-settings-config` in `cosmic-settings-daemon`
- `cargo check -p cosmic-comp` in `cosmic-comp-background-window-rules`
- `cargo check -p cosmic-settings` in `cosmic-settings`
- `cargo check` in `cosmic-workspaces-epoch`
- `cargo check` in `cosmic-settings-daemon`

All completed successfully.

## Notes

- This update intentionally does not preserve the old compositor-managed rule workspace persistence model.
- Existing unrelated dirty changes in the implementation repos were left in place.
- This repo document only records the engineering changes; it does not install or deploy rebuilt binaries by itself.
