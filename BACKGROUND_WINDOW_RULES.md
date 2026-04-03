# Background Window Rules

## Problem

GUI windows opened indirectly by AI CLI tools, test runners, auth helpers, or related desktop automation are disruptive in COSMIC today:

- they can take focus away from the current terminal or editor
- they can appear on the current workspace instead of a dedicated background workspace
- they do not reopen in a stable floating position
- if a dedicated workspace becomes empty and is auto-removed, the next reopen has no stable target

The goal of this feature is to make those windows predictable and non-disruptive without breaking normal, intentional user launches.

## User-Facing Behavior

Users configure explicit window rules in COSMIC Settings.

Each rule can:

- match an app by `app_id` or X11 class
- optionally narrow the match by title
- mark matching launches as background-only
- route matching windows to a named background workspace
- force matching windows to open floating
- remember the last floating geometry for future reopens

`Open in background` means:

- never take keyboard focus
- never switch the active workspace
- never switch the active output
- open on the configured background workspace
- mark that workspace urgent instead of interrupting the user

Normal user-initiated launches still focus normally when they carry a valid activation token.

Dialogs and modal/child windows are not background-routed away from their parent window.

## Workspace Model

Rules target a visible workspace name plus a hidden stable workspace ID.

This split is required because the workspace may disappear when empty:

- the user sees and chooses a human-readable workspace name such as `AI Tests`
- the compositor stores an internal stable workspace ID for that target
- if the workspace is auto-removed, the compositor recreates it later with the same ID and visible name

Urgency is represented as the normal workspace urgent state. The workspace UI decides how it is rendered, but the expected behavior is a highlighted workspace indicator rather than a forced popup or focus change.

## Settings UI

The feature is implemented inside the existing COSMIC Settings app, under Window Management.

The UI flow is:

1. Open Settings and navigate to Window Management.
2. Open a new Window Rules section or subpage.
3. Click Add Rule.
4. Pick a live window from the current toplevel list.
5. COSMIC pre-fills app identity and title from that window.
6. The user chooses:
   - app-wide match or app-plus-title refinement
   - open in background
   - named background workspace
   - keep floating
   - remember position
7. Save the rule.

The live window picker is built from the compositor's existing toplevel-info protocol. No separate capture daemon is needed for the first version.

## Implementation Split

### 1. `cosmic-settings-daemon`

Extend the `com.system76.CosmicSettings.WindowRules` config schema with a new collection of behavior rules.

The new rule model should include:

- rule ID
- enabled flag
- app matcher
- optional title matcher
- launch policy
- focus policy
- optional workspace target
- open-floating flag
- remember-floating-geometry flag

Existing tiling exceptions remain unchanged and continue to work.

### 2. `cosmic-comp`

Add behavior-rule loading and watching alongside the existing tiling-exception watch path.

At map time:

- evaluate background rules before final focus/placement decisions
- preserve focus for valid user-initiated activation
- suppress focus for background-only or urgent-only launches
- skip background routing for dialogs and child/modal windows

For workspace routing:

- resolve the rule's target workspace by hidden stable ID
- if missing, recreate it in the correct workspace set
- reapply the visible name
- map the window there without switching away from the current workspace
- set the workspace urgent

For geometry persistence:

- store remembered floating geometry in local compositor state
- key it by rule ID, not by transient window identity
- restore it when reopening matching windows

### 3. `cosmic-settings`

Add a Window Rules UI to the existing Window Management area.

The page must support:

- listing existing rules
- creating rules from live open windows
- editing and deleting rules
- enabling and disabling rules
- choosing a named background workspace
- toggling floating and remembered geometry

## Implementation Order

1. Write this design doc.
2. Add config schema support in `cosmic-settings-daemon`.
3. Add compositor rule handling in `cosmic-comp`.
4. Add the Settings UI in `cosmic-settings`.
5. Verify end-to-end behavior across all three repos.

## Verification

The feature is correct when the following scenarios work:

- a matched browser window launched by a background tool does not steal focus
- that window opens on the configured background workspace
- if the workspace was auto-removed, it is recreated automatically
- the recreated workspace keeps its visible name
- the workspace becomes urgent instead of interrupting the user
- a matched floating window reopens in its remembered position
- a user-initiated launch with a valid activation token still focuses normally
- dialogs from a matched app continue following parent behavior
- unmatched apps behave exactly as before

## Repos and Branches

Implementation is expected on dedicated feature branches in:

- `cosmic-comp`
- `cosmic-settings-daemon`
- `cosmic-settings`

This keeps the work isolated and reviewable while still delivering the feature as one coordinated change set.
