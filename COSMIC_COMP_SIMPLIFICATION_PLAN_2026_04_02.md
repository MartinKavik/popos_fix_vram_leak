# COSMIC Compositor Simplification Plan

**Date:** 2026-04-02

## Execution Status

### Current installed stabilization batch

The current installed compositor build includes the active simplification batch from this plan:

- removed broad output-wide visible-pressure logic from ordinary visible scheduling
- kept only simpler owner-local visible coalescing
- stabilized visible owner kinds to `toplevel` vs `layer`
- removed focus-state-dependent scheduling buckets
- made workspace activation instant
- made overview enable/disable immediate in the stabilization build
- removed compositor priority elevation from the main thread and KMS surface threads
- stopped taking the shell write lock for `update_animations()` at 60 Hz when no animation is active
- added a layer-layout signature fast path so ordinary layer-surface content commits skip `layer_map.arrange()` unless size/anchor/exclusive-zone/margin/layer state actually changed
- added `layer_arrange` vs `layer_arrange_skipped` perf counters so panel/Dock commits can be verified on the cheap path after reboot
- simplified periodic shell maintenance refresh:
  - removed the small scheduled-token refresh subsystem
  - kept a direct timestamp gate instead
  - slowed idle maintenance refresh to `750ms`
  - kept the faster `150ms` cadence only while animations, workspace gestures, resize/zoom state, or pending shell/transient state still exist
- removed dead overview transition state and render branching:
  - `OverviewMode` now matches the actual stabilized behavior (`Active` or `None`)
  - deleted `Started` / `Ended` branches from shell and render code
  - removed overview fade-transition logic that was no longer reachable after instant overview enable/disable
- removed shortcut workspace-transition animation state:
  - `WorkspaceDelta::new_shortcut()` now resolves to the same instant path as ordinary stabilized activation
  - deleted `WorkspaceDelta::Shortcut` handling from shell/focus code
  - kept gesture-based workspace swipe state intact
- narrowed periodic tiling refresh:
  - periodic tiling maintenance no longer refreshes every ordinary live tiled element
  - it now only refreshes mapped elements that still need periodic cleanup, mainly stacks with dead child windows
  - ordinary live tiled windows rely on commit-time updates instead of being walked again during background maintenance
- narrowed periodic floating/sticky refresh:
  - `FloatingLayout::refresh()` now first checks whether anything is actually stale
  - if there are no dead elements, no out-of-output elements, and no dead spawn-order entries, it returns without calling Smithay `Space::refresh()`
  - this reduces background maintenance cost for ordinary live floating and sticky elements
- split periodic shell refresh from full workspace structural maintenance:
  - explicit full-refresh callers still use the full workspace reconciliation path
  - the periodic main-loop refresh now uses a light shell tick on every maintenance cadence
  - structural workspace normalization is only re-run on the slower workspace-maintenance cadence instead of every fast refresh tick
  - this removes another broad workspace walk from the ordinary maintenance hot path
- narrowed other periodic broad walks to the slower maintenance cadence too:
  - overlap-notify refresh is no longer run on every fast periodic tick
  - fallback X11 stacking-order sync is no longer run on every fast periodic tick
  - both now follow the same slower structural-maintenance cadence instead of riding the 150ms transient refresh path
- narrowed periodic toplevel-info refresh too:
  - full toplevel-info protocol refresh is no longer run on every fast periodic tick
  - explicit full-refresh callers still refresh it immediately
  - ordinary periodic upkeep now only refreshes toplevel-info on the slower maintenance cadence
  - this removes another all-toplevel/all-instance walk from the fast maintenance path
- narrowed fast periodic workspace ticking further:
  - fast periodic refresh no longer walks workspaces just because pending windows, pending layers, or override-redirect X11 windows exist
  - workspace ticking now stays tied to actual workspace/resize/zoom transient state, or to the slower structural-maintenance cadence
  - layer-map cleanup was also moved fully into the slower maintenance bucket instead of running on every fast periodic tick
- narrowed the fast-refresh trigger itself:
  - the compositor no longer enters the 150ms fast periodic cadence just because pending windows, pending layers, or override-redirect X11 windows exist
  - fast cadence is now reserved for actual workspace/resize/zoom transient state, with the rest falling back to slower maintenance
  - this keeps ordinary transient bookkeeping from dragging the shell back onto the faster upkeep loop
- moved more periodic safety-net sweeps off the fast path:
  - idle-inhibit recomputation is no longer run on every periodic tick
  - a11y keyboard-monitor client cleanup is no longer run on every periodic tick
  - both still run immediately in the explicit full-refresh path and on the slower maintenance cadence
- moved popup cleanup and activation-token pruning off the fast path too:
  - popup-manager cleanup is no longer run on every periodic tick
  - activation-token expiry pruning is no longer run on every periodic tick
  - both still run in the explicit full-refresh path and on the slower maintenance cadence
- moved more transient housekeeping off the fast path:
  - override-redirect X11 cleanup/refresh is no longer run on every fast periodic tick
  - pending layer and pending window dead-entry cleanup is no longer run on every fast periodic tick
  - these now follow the slower maintenance cadence instead of riding the 150ms loop
- moved periodic focus repair off the fast path:
  - the broad `refresh_focus()` safety-net sweep is no longer run on every fast periodic tick
  - direct focus changes still happen immediately from input, map/unmap, popup-grab, and workspace actions
  - periodic focus repair now follows the slower maintenance cadence instead of living on the transient loop
- kept the current diagnostics, but without adding another new scheduling framework on top

Installed binary after this batch:

- `/usr/bin/cosmic-comp`
- SHA-256: `afed1b440ee715d5d50773f9253032dda1690436c89c997fae141948e5af08cb`

This is the current reboot/manual-test boundary. The next validation pass should judge this simpler compositor batch before adding any further render-path logic.

## Goal

Make the desktop usable again by removing complexity from the compositor hot path, not by adding more recovery logic or more heuristics.

The current problem is no longer mainly the old hidden-window leak. The live system is now mostly suffering from **high visible commit churn** on ordinary desktop use, while the compositor carries too much policy, scheduling, and diagnostics in its core path.

This plan treats two goals as equally important:

- reduce the number of admitted redraws
- reduce the cost of each admitted redraw

The recent logs show tiny damage ratios together with poor FPS and steady busy-render intervals, which means scheduling alone is not enough. Even the frames that are admitted are still too expensive.

This plan intentionally favors:

- simpler code
- fewer moving parts in the compositor
- less output-wide policy
- fewer fallback redraw triggers
- instant behavior over animated behavior when necessary
- architecture changes when they reduce long-term fragility

It does **not** use a quarantine model. The direction is simpler: **delete or revert extra code where possible** and keep only the fixes that are clearly correct and still needed.

## Current High-Level Diagnosis

### What has improved

- the old `pending_windows` / hidden pre-map leak is not the main issue anymore
- ghost first-map windows and missing initial focus are largely fixed
- workspace rename/remove/move behavior is in much better shape
- executable-path rule matching exists and is usable
- `cosmic-term` title churn was reduced at the source

### What is still bad

- the compositor still lags badly under ordinary visible client activity
- hovering or interacting with specific windows such as `1Password` makes lag obvious
- panel / Dock layer surfaces are still frequent visible offenders
- some sessions still drift into very high visible-commit rates and poor FPS
- too much logic now sits in the main scheduling and render path

### What the logs currently point to

The important recent pattern is:

- `pending_windows=0`
- `visual_hidden=0`
- overload often **not** active
- no repeated VBlank storm in the ordinary laggy state
- but very high `visible_commit` counts from a few real clients:
  - `cosmic-panel` Dock / Panel layer surfaces
  - `1Password`
  - `Firefox`
  - sometimes `cosmic-term`

That means the compositor is now mostly losing on **steady visible work**, not on the earlier leak/recovery failure mode.

## Why The Current Architecture Feels Fragile

The compositor currently mixes too many concerns in the same hot path:

- window first-map lifecycle
- window-rule matching and routing
- workspace activation / transitions / overview state
- layer-shell surfaces
- compositor-owned decorations and tab/title UI
- image capture / screencopy scheduling
- per-output render scheduling
- overload and VBlank recovery
- diagnostics and offender tracking

That makes small visible commits expensive, because even a tiny surface update can still pass through a lot of shell and output logic.

This is also why other desktops tend to feel less fragile: they usually keep the compositor path narrower, do less compositor-owned UI work, or isolate layer / window / transition behavior more cleanly.

## Design Principle For The Next Pass

**Remove code first.**

Do not add another generic scheduling framework unless deleting code first made it impossible.

The right shape is:

- lifecycle logic decides window/workspace state
- a small scheduler decides whether a specific visible owner should wake a specific output
- the renderer composites the smallest necessary scene
- overload logic only protects against hard failure, not ordinary desktop use

If reaching that shape requires refactoring module boundaries or moving logic out of current hot files, that is in scope. The goal is not to preserve the present structure. The goal is to end up with a structure that makes future lag regressions harder to introduce.

## Keep / Remove

### Keep

These changes are worth keeping because they fix correctness problems and do not appear to be the main current lag source:

- first-map / initial-focus fixes
- root-null-buffer cleanup for mapped root toplevels
- workspace rename/remove/move fixes
- executable-path window-rule matching
- `cosmic-term` title/header throttling
- enough build/perf logging to identify top visible offenders
- emergency VBlank / transition-abort recovery as a last-resort safety net

### Remove or Simplify Aggressively

These are the main candidates to delete, revert, or drastically simplify:

- broad output-wide visible-pressure logic in normal operation
- output-level heuristics that activate too late to help
- fallback render scheduling added for uncertain ownership cases
- non-essential animation-related scheduling in ordinary workspace activation
- bookkeeping-heavy hot-path offender/coalescing logic that does not directly reduce renders
- broad render triggers on metadata / hover / focus transitions unless compositor-owned UI truly changed
- any path that schedules output redraw without a clearly identified visible owner or explicit workspace transition

## File-Level Cleanup Targets

### `src/state.rs`

This file has accumulated too much global policy.

Target cleanup:

- reduce it to:
  - metadata refresh queue
  - minimal owner-local scheduling state
  - minimal overload state
- remove broad output-wide visible-pressure policy from the normal path
- remove counters and retention structures that are not used for decisions
- keep minute summaries, but stop tracking excessive per-owner/per-output history in the hot path

Desired outcome:

- `state.rs` becomes coordination state, not a policy engine
- if necessary, split scheduling state into a dedicated module so `state.rs` stops growing as a catch-all

### `src/wayland/handlers/compositor.rs`

This should become the place that:

- classifies commits
- resolves the real owner
- decides whether the commit is visible enough to matter

Target cleanup:

- keep one stable owner key for toplevels and one for layers
- remove owner identity inputs that should not matter:
  - focus state
  - changing titles
- remove fallback render scheduling for uncertain ownership
- keep only:
  - visible commit
  - explicit workspace/transition activation
  - explicit screencopy/capture

Desired outcome:

- commit handling should be understandable without reading unrelated recovery code
- if needed, move owner resolution and commit classification into a smaller dedicated unit with a narrow interface
- explicitly cover both Wayland and Xwayland owners instead of assuming Wayland-root resolution is enough

### `src/backend/kms/surface/mod.rs`

This file is carrying too much normal-path logic.

Target cleanup:

- keep hard-failure recovery for real timeout storms
- remove or simplify normal-path gating that tries to be clever every frame
- keep only the smallest necessary counters for:
  - render requests
  - coalesced renders
  - timeout streaks
- disable default-on debug logging decisions unless they are truly needed all the time
- keep the surface thread focused on rendering and basic recovery, not shell policy

Desired outcome:

- no ordinary desktop interaction should depend on a large collection of recovery heuristics
- if necessary, move emergency recovery into a separate file/module so normal render flow is visibly smaller

### `src/shell/mod.rs`

Target cleanup:

- remove non-essential transition complexity from the default path
- make workspace activation instant while stabilizing
- keep transition-abort support only as an emergency fallback
- re-check all workspace refresh calls and remove ones that are defensive but unnecessary

Desired outcome:

- workspace switching becomes boring and reliable first
- and the shell code makes a clearer distinction between state mutation and presentation/animation

### `src/wayland/handlers/xdg_shell/mod.rs`

Target cleanup:

- keep rule-routing correctness
- keep metadata throttling for compositor-owned UI
- remove any redraw trigger that exists only because metadata changed somewhere, unless compositor-drawn UI is actually affected

Desired outcome:

- title/app-id changes should mostly be protocol state changes, not compositor redraw events

### compositor-owned chrome and stacks

Target cleanup:

- simplify or temporarily reduce nonessential compositor-drawn chrome during stabilization
- ensure ordinary client-content commits do not automatically drag SSD/tab/title invalidation with them
- keep compositor-owned metadata redraw limited to actually visible compositor-owned UI

Desired outcome:

- compositor-owned presentation is not a hidden tax on ordinary visible client activity

## Architectural Corrections

### 1. Stable owner-local scheduling only

The scheduler should work per visible owner first.

Needed rule:

- one owner gets at most one pending redraw per frame

Owner keys:

- toplevel: `(output, client identity, root surface id)`
- layer: `(output, client identity, namespace, surface id)`

Not part of the owner key:

- focus state
- title text
- other transient presentation labels

This is the simplest structure that still contains noisy windows like `1Password` or Firefox without punishing the whole output.

### 2. Layer-shell fast path

Panel and applet commits are currently too expensive for what they are.

Needed behavior:

- small Dock/Panel commits should not refresh workspace state
- if layer geometry, exclusive zone, and stacking are unchanged:
  - redraw only as a layer update
  - do not traverse broad workspace refresh logic

This is probably the biggest medium-term performance win after simplification.

This may require a real architectural split between:

- layer-scene invalidation
- workspace-scene invalidation
- transition/overview presentation

That split is desirable, not something to avoid.

Important constraint:

- owner-local scheduling alone is **not enough** if the renderer still pays almost full-scene cost for a tiny layer commit

So this is not just a scheduler change. It is also a scene invalidation / render-path change.

### 2a. Xwayland correctness and cost review

The current offender set includes apps like `1Password` and some Firefox paths that may not behave like ordinary Wayland toplevels.

The simplification pass must explicitly verify:

- owner identity for Xwayland toplevels
- visible/hidden attribution for Xwayland surfaces
- hover/focus/property-change paths do not bypass simplified scheduling
- damage attribution and render cost are not silently worse for Xwayland than Wayland

This is required, not optional.

### 3. Instant workspace activation until stable

Animations are not the current product priority. Usability is.

Needed behavior:

- workspace switching is instant by default for the stabilization period
- overview/workspace transition code should not be on the hot path unless explicitly being used
- only reintroduce richer transition behavior after the desktop is stable again

### 4. Logging that identifies culprits without becoming another subsystem

Keep:

- build id at startup
- top visible offenders by output
- large-damage summaries
- timeout/transition-abort warnings

Remove or reduce:

- hot-path tracking that is interesting but not actionable
- counters that exist only because a previous heuristic needed them

Logging must help explain the next bad session, but it must not become another policy layer.

## Architecture Improvements Explicitly In Scope

The stabilization work is allowed to improve structure, not only delete lines.

Acceptable architectural changes:

- split oversized files when that creates cleaner ownership boundaries
- move scheduling logic out of shell/workspace policy code
- separate normal render flow from emergency recovery flow
- separate layer-surface invalidation from workspace-content invalidation
- replace global catch-all state with smaller focused structs
- remove implicit coupling between window metadata, rule routing, workspace refresh, and visible scheduling

Not acceptable:

- adding another large generic framework without deleting existing complexity first
- preserving a confusing structure only to avoid refactoring

The preferred direction is:

1. smaller modules
2. fewer implicit dependencies
3. fewer hot-path decisions
4. clearer ownership of scheduling, lifecycle, and rendering

## Validation Discipline

This work should not repeat the recent pattern of stacking multiple unvalidated fixes before the next reboot.

Rules:

- only land one coherent stabilization batch at a time
- each batch must be measurable against the same desktop workflow
- do not mix unrelated correctness work into the same lag-reduction batch
- if a batch does not materially reduce lag or materially simplify code, stop adding heuristics

Required evidence after each batch:

- compositor CPU under the same light-desktop workflow
- top visible offenders by output
- whether outputs still sit in `cause=busy-render`
- whether the code path got smaller or clearer

If a simplification batch makes the code larger or harder to reason about, it failed even if one metric moved slightly.

## Implementation Order

### Phase 1: Simplification pass

- remove broad output-wide visible-pressure logic from ordinary scheduling
- keep only owner-local coalescing
- stabilize owner keys
- make workspace activation instant
- remove broad render fallbacks and defensive redraw triggers
- review Xwayland-visible owner handling in the same pass, so `1Password`-style cases are not left outside the simplification model

Acceptance:

- code is smaller
- ordinary visible commits go through fewer branches
- module boundaries are clearer than before, even if some code moved rather than only shrinking
- the same light-desktop workload produces less busy-render time than before
- admitted visible frames are cheaper to process, not only fewer

### Phase 2: Layer-shell fast path

- make panel/Dock/applet commits cheap when geometry did not change
- prevent ordinary layer commits from kicking wider workspace work

Current execution status:

- done for the common commit path: ordinary mapped layer commits now skip `arrange()` unless the layout-affecting layer signature changed
- still open if needed later: broader layer-scene partitioning beyond the current fast path

Acceptance:

- panel remains responsive
- panel churn does not dominate render scheduling
- small layer commits no longer behave like workspace-scene updates

### Phase 3: Re-test with the current offender set

Primary checks:

- hover and interact with `1Password`
- use Firefox on the same output
- keep panel and applets visible
- run two terminals with normal output

Acceptance:

- cursor remains responsive
- no obvious lag from simple hover/input
- compositor CPU is materially lower under the same workflow
- outputs do not remain in long steady `busy-render` intervals during ordinary use
- a noisy focused client on one output does not make the other output feel degraded

### Phase 4: If simplification is not enough, do a controlled bisect

If the compositor is still laggy after Phase 1 and Phase 2, stop adding more scheduling logic and do a structured regression search through the current hot-path changes.

Purpose:

- identify whether one specific large change family is responsible
- avoid turning the compositor into an accumulation of partially-correct mitigations

Targets for comparison:

- current branch state
- simplified branch after Phase 1 and Phase 2
- older known-good behavior for the visible path, if available

This is a required fallback, not an optional idea.

### Phase 5: Only then consider selective reintroductions

Only after stability is confirmed:

- consider whether any output-wide pressure logic is still needed
- consider whether any workspace animation should return
- consider whether additional offender attribution is worth keeping

Rule:

- no reintroduction unless it demonstrates real benefit against the stabilized baseline

## Success Criteria

The plan is successful only if all of these are true:

- fresh boot feels responsive without any warm-up period
- hovering a noisy app like `1Password` does not make the cursor laggy
- panel/Dock activity does not keep outputs in constant busy-render state
- small layer updates no longer force workspace-scale work
- workspace switching is boring and reliable
- no hard reset is needed after clicking or switching workspaces
- the compositor remains usable after at least one hour of normal desktop use
- the final code is simpler to explain than the current branch
- compositor-owned chrome is no longer a significant hidden contributor to ordinary client churn

## Non-Goals For This Pass

- preserving every animation or transition effect
- keeping every experimental scheduling heuristic
- optimizing every edge case before the common case is stable
- hiding the real culprit behind more generic recovery logic

This pass is about getting back to a compositor that is simple enough to reason about and cheap enough to use.

## Review Corrections

After a second review of the current logs, changed files, and implementation scope, these additional constraints are needed to make the plan more complete and less likely to create more regressions.

### 1. One phase at a time

Do not land multiple stabilization ideas together and then test them as a batch.

Required discipline:

- complete one phase
- build and install it
- test it on a fresh session
- keep or revert it before starting the next phase

If multiple phases are stacked before testing, the project will return to the same failure mode as before: many interacting changes and no clear culprit.

### 2. Keep a strict non-regression matrix

A compositor can feel faster while still regressing core behavior.

Every stabilization phase must re-check:

- normal new windows start focused
- no ghost tiled occupants return
- workspace rename/remove/move still works
- window drag/drop in overview still works
- screenshot/screencopy still works
- rule-based workspace routing still works

The lag work is not allowed to silently break these again.

### 3. Explicitly separate compositor responsibility from client responsibility

The compositor must stop amplifying client churn into desktop lag. That is the real stabilization target.

This plan does **not** assume the compositor can stop every client from making frequent commits. Instead it requires:

- noisy clients stay local to their own owner/output budget
- panel/layer churn does not pay workspace-scene cost
- one client cannot make the whole desktop feel frozen

If a client remains individually noisy after compositor simplification, that becomes a separate client-side issue, not proof that the compositor architecture is still correct.

### 4. Keep permanent instrumentation minimal

The plan should not end with another always-on observability framework.

Permanent instrumentation should stay limited to:

- build identity
- top visible offenders
- large-damage summary
- hard-failure warnings

Anything deeper should be removable or debug-only once the compositor is stable again.

### 5. Accept that some source-side fixes may still be needed later

`cosmic-panel` is a repeated live offender, but its source tree is not currently local here. That means the first stabilization pass must contain panel churn from the compositor side.

However, the architecture review also says this clearly:

- compositor simplification first
- panel/client source-side dedupe second if still necessary

This avoids misplacing responsibility while still acknowledging that not every visible offender must be solved only inside `cosmic-comp`.

## Execution Discipline

The implementation should follow these rules:

1. No new feature work while stabilization is in progress.
2. No mixed commits that combine correctness fixes and performance heuristics unless they are inseparable.
3. Prefer deletion and replacement over wrapping old logic in another guard.
4. If a simplification makes code harder to understand, it is not a simplification.
5. If a hot-path counter is not used for a decision or a minimal summary, remove it.

## Practical Definition Of Success

The real end state is not "zero commits" or "zero CPU". The real end state is:

- normal desktop interaction stays responsive
- noisy clients remain isolated
- workspace switching cannot hard-freeze the session
- the compositor does not need a large policy layer to stay stable
- future regressions become easier to diagnose because the hot path is smaller

That is the standard this plan should be judged against.
