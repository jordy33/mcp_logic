# Detached Mixer window is not locatable — every plugin/mixer tool fails closed

Status: implemented in the working tree (2026-11-01); unit-verified; live acceptance (AC1–AC6, AC8)
still pending because the implementation session could not run the real tools against Logic.

## 1. Measurement this ticket rests on

Measured 2026-10-30T23:21Z against a running host. Everything below is a reading, not an inference.

| Fact | Reading |
| --- | --- |
| Host | Logic Pro 12.4 "Creator Studio" (`com.apple.mobilelogic`), macOS Darwin 27.0.0, UI locale en-US, pid 3841 |
| Project | `100 años` (`/Users/jorgemacias/Music/Distro-home/100 años/100 años.logicx`) |
| MCP | `LogicProMCP` release build, SSE bridge 127.0.0.1:8765, `logic_system health` = permissions granted, AX/CGEvent/AppleScript/CoreMIDI ready |
| Logic frontmost | **No** (Terminal is frontmost; each tool call is approved from the terminal, so Logic is normal-titled, not active) |
| Windows (AX) | `[0] "100 años - Mixer: All"` AXWindow/AXStandardWindow, AXMain=true, 1500×820; `[1] "Stereo Out"` AXWindow/AXDialog (open Channel EQ editor); `[2] "100 años - Tracks"` AXWindow/AXStandardWindow |
| Mixer placement | **Detached window** (Window > Open Mixer), not the docked bottom pane |
| `get_inventory {track:4}` | State B, `plugins_unknown_reason: "mixer_not_visible"`, `mixer_reveal_attempted: false`, `mixer_reveal_strategies: []`, "mixer area was not locatable in the AX tree", `plugins_fetched_at: 2026-10-30T23:21:13.646Z` |
| `get_inventory {strip:"output"}` | Identical failure, `2026-10-30T23:21:15.405Z` |
| `logic://mixer` resource | stays `cache_stale`; last fetched 2026-10-30T22:27:59Z |
| MCU | `feedback_stale: true`, last feedback 2026-10-30T22:29:13.919Z |

The claim that would change if the reading were about something else: that the mixer tree is unreadable.
It is not. An independent Swift walk of ApplicationServices (same framework the MCP uses, same pid)
read the **detached** window successfully:

- `"100 años - Mixer: All"`: 966 nodes visited, 74 `AXSlider`, 91 `AXGroup`, 95 `AXCheckBox`,
  586 `AXButton`; containers matching the MCP's own mixer predicate:
  two `AXGroup` with `AXDescription = "Mixer"` and one `AXLayoutArea` with `AXDescription = "Mixer"`;
  269 elements whose title/description/help mention "channel strip"; 0 drill-down truncation.
- `"100 años - Tracks"`: 372 nodes visited, **zero** mixer containers (the only element with "Mixer"
  in its text is an `AXCheckBox`); 30 track-header references; 6 sliders (header faders).
- `"Stereo Out"` (plugin dialog): 71 nodes, no mixer content.

So the tree is there; the **locator** does not look at the window that holds it.

### 1a. The detached window is also the only one that names inserts (measured after the reveal workaround)

`get_inventory {track:4, reveal_mixer:true}` succeeded (State A): the reveal clicked
`View > Show Mixer`, docked a 1680×424 mixer pane into the arrange window, and the lookup found it
(`mixer_strip_index: 9`, track name "100 años master (Vocals)_gerardo", seven empty inserts).
But `get_inventory {strip:"output"}` then failed with
`plugins_unknown_reason: "occupied_insert_name_unreadable"` ("an occupied insert exposed a generic
slot label instead of its plugin name"), even though the Stereo Out strip carries a Channel EQ.

Per-strip comparison of the *same* Stereo Out channel strip (`AXLayoutItem` whose name field is
"Stereo Out"):

| Element | Docked pane (Tracks window) | Detached window ("Mixer: All") |
| --- | --- | --- |
| Occupied insert | `AXGroup desc="audio plug-in"`, bypass checkbox `1` | `AXGroup desc="Channel EQ"`, bypass checkbox `0` |
| Insert buttons | `AXButton desc="audio plug-in"` ×7, no title/value | `AXButton desc="audioPlugIn"` ×7, no title/value |
| EQ thumbnail | `AXButton desc="EQ" value="off"` | `AXButton desc="equalizerThumbnail" value="on"` |

The plugin name is therefore **not present anywhere in the docked pane's AX tree** for this insert;
it is present as the `AXGroup` description in the detached window. The reveal workaround unblocks
`track:` reads of empty chains only. It is not a workaround for occupied inserts, and it changes
the user's layout.

## 2. Root cause, exact paths

1. `Sources/LogicProMCP/Channels/AccessibilityChannel+VerifiedPlugins.swift:2875` and `:5630`
   call `AXLogicProElements.mixerAreaLookup(runtime:)`.
2. `Sources/LogicProMCP/Accessibility/AXLogicProElements+Mixer.swift:198-200`:

   ```swift
   static func mixerAreaLookup(runtime: Runtime = .production) -> MixerAreaLookup {
       guard let window = mainWindow(runtime: runtime) else { return .notFound }
       return mixerAreaLookup(in: window, runtime: runtime)
   }
   ```

3. `Sources/LogicProMCP/Accessibility/AXLogicProElements.swift:137` `mainWindow()` enumerates
   `kAXWindowsAttribute` and, at step 3, prefers the window that has a Track Headers group — i.e.
   **the arrange window**. The detached Mixer window is never used as a search root.
4. The candidate walk itself (`mixerAreaCandidates`, `AXLogicProElements+Mixer.swift:438`) would
   match the detached window: its predicate accepts `AXGroup`/`AXScrollArea`/`AXLayoutArea` whose
   identifier/description/title normalizes to a Mixer label, and the measured window carries
   `AXDescription = "Mixer"` on exactly those roles. The failure is the root window choice, not the
   predicate.

This is already known upstream: `docs/prd/PRD-issue-234-mixer-strip-selection-12-3.md` NG7 records
"`getMixerArea` searches `mainWindow()` only" and
`docs/observations/2026-09-23-972-en-US-plugin-instance-identity.json` measured the same standalone
window reachable "by a direct walk of all windows but not by `getMixerArea`". This session is the
first real-user case where the documented recovery ("the pane-reveal path restores function") does
**not** run: `get_inventory` defaults `reveal_mixer` to false, so no reveal is attempted at all,
and the State B hint ("Open View > Show Mixer") is actively misleading because the Mixer **is** open.

## 3. What the MCP is missing

**R1 — Mixer lookup must search detached windows.** In `mixerAreaLookup(runtime:)`, after the
arrange-window lookup returns `.notFound` (and only then), run the **same** `mixerAreaCandidates`
walk over the other non-dialog `AXWindow`s from `kAXWindowsAttribute`, in a deterministic order.
Do not search `AXDialog` windows. Return the binding with its owning window.

**R2 — Carry the owning window through the binding.** `MixerAreaBinding` currently has
`mixer`, `owners`, `path`. Add the root `window` (or expose it in a new lookup result) so the
reveal/raise path and trace can name which window was bound.

**R3 — Raise, don't re-dock.** `inventoryRevealWindow` / the reveal path should, when a standalone
Mixer window exists, `AXRaise` it instead of clicking View > Show Mixer. Re-docking opens a second
mixer pane (measured 1680×424), changes the user's layout, and — per §1a — its insert labels are
generic, so it cannot support occupied-slot reads at all. `forceMixerWindowFront`
(`AccessibilityChannel+VerifiedPlugins.swift:6498`) already loops over windows but matches only
`role == AXGroup && identifier == "Mixer"`; the measured detached window exposes **no** identifier
on its container (description "Mixer" only). Extend that match to the locale-aware Mixer label set
(`AXLocalePolicy.mixerNamedElement`) on identifier/description/title.

**R4 — Read occupied slot names from the representation that has them.** The insert-name reader
must (a) accept an occupied slot's name from an `AXGroup` child whose `AXDescription` is the plugin
name (measured "Channel EQ"), not only from insert-button titles, and (b) bind the strip in the
window where that representation exists. With both windows open, the detached window wins for any
occupied chain; the docked pane is sufficient only for empty chains. A `mixer_window: "auto" |
"docked" | "detached"` selector would make the choice explicit and enforceable. Do **not** solve
this by defaulting the reveal on: after reveal the docked pane still reports
`occupied_insert_name_unreadable`.

**R5 — Parameter editing must bind to detached strips.** `insert_verified` / `set_eq_band_verified`
/ the send tools resolve strips through the same lookup. Verify they work with only the detached
window open, including the master `strip: "output"` (the session has a Channel EQ on Stereo Out,
slot 1, that the MCP cannot currently see).

**R6 — `logic://mixer` freshness.** The resource remained `cache_stale` (last fetched 22:27:59Z)
throughout, with MCU feedback stale since 22:29:13Z, while `health` kept reporting the channel
`ready: true`. A stale resource that never recovers after `refresh_cache` is a second bug: either
refresh it from a successful AX read, or report *why* it cannot (and whether the cause is the
detached window).

## 4. Acceptance criteria (failable)

1. With **only** a detached Mixer window open (`View > Show Mixer` off) and the arrange window
   present: `logic_plugins.get_inventory {track:4}` returns State A with the insert chain (this
   session: empty chain is the honest answer; today it returns State B), and
   `{strip:"output"}` returns State A naming **"Channel EQ"** at slot 1.
2. With the detached window *and* a docked pane both open (the state after the reported reveal
   workaround), `{strip:"output"}` still returns State A naming "Channel EQ" — the read must not
   degrade to `occupied_insert_name_unreadable` just because the docked pane exists.
3. With the docked mixer pane and no detached window: behavior is unchanged (regression guard),
   including the measured generic-name failure for an occupied slot — this criterion pins the
   limitation rather than pretending it is fixed.
4. With both a docked pane and a detached window: the tool binds deterministically, records the
   chosen window title in the response/trace, and never mixes strips from two windows in one read.
5. With no mixer anywhere: the existing reveal path still runs and still fails closed with the same
   State B codes.
6. `get_inventory` on a detached-window session never emits the hint "Open View > Show Mixer" as
   the only recovery; either it succeeds or it states that the detached window could not be read.
7. A unit/integration test whose production mutation (removing the cross-window search) turns it
   RED: e.g. fixture with two windows where only the non-arrange window contains the Mixer
   container; the lookup must find it. Today's `mainWindow()`-only implementation fails that test.
8. `forceMixerWindowFront` raises the measured detached window (no identifier, description "Mixer")
   and the raise is observable in the trace.
9. No new dependence on Logic being frontmost: every check above passes while Terminal is the
   frontmost application (the measured condition; the MCP never had focus at execution time because
   each tool call is approved from the terminal).

## 5. Not in scope

- Plugin-window GUI automation (clicking/dragging inside Channel EQ). This session proved it is
  unreliable because focus leaves Logic between commands; the MCP must drive AX elements, not
  coordinates in a modal-ish editor.
- Reading plugin parameter values from the detached mixer's own strip UI (no editor open).
- Any change to the docked-pane detection for Logic 12.2/12.3 or the locale label sets.
- MCU stale-feedback diagnosis beyond R6.

## 6. What this ticket does not establish

- That `insert_verified`/`set_eq_band_verified` succeed end-to-end once the locator is fixed;
  only that they can reach the strip. Their own write/readback gates remain unverified here.
- That the detached window's strip → track-index mapping is identical to the docked pane's. The
  walk proves the strips exist and are `AXLayoutItem` children of a Mixer-described `AXLayoutArea`;
  it does not prove index parity. Acceptance 1 must pin track 4 by its observed name, not only by
  ordinal.
- That raising the detached window has no effect on the user's screenset. `AXRaise` does not
  change the layout, but this was not measured after a real reveal.

## 7. Implementation (2026-11-01)

All changes are in the working tree; nothing is committed.

| Requirement | Change |
| --- | --- |
| R1 | `AXLogicProElements.nonDialogWindows` + `isArrangeWindow` (`AXLogicProElements.swift`). `mixerWindowLookup(runtime:preference:)` (`AXLogicProElements+Mixer.swift`) runs the existing candidate walk over every non-dialog window, arrange window last under `auto`; the pre-existing single-window fallback is kept when `AXWindows` is empty. |
| R2 | `MixerWindowLookup` carries `window`, `title`, `placement`; `MixerAreaBinding` gained `window` (set by the tracks binding and the population walk). |
| R3 | `raiseMixerWindow` / `forceMixerWindowFront` raise `mixerWindowLookup().window` instead of scanning for `identifier == "Mixer"`, which the measured detached window does not expose. Re-docking is never triggered when a Mixer is already visible. |
| R4 | The insert reader already accepts an occupied slot named by its `AXGroup` description (measured "Channel EQ"); the fix is binding the representation that has it. New `mixer_window: "auto" \| "docked" \| "detached"` on `get_inventory` (dispatcher validation + parameter contract + tool description). `auto` prefers the detached window; `detached` fails closed with `detached_mixer_not_visible` instead of binding the docked pane. Responses carry `mixer_window` and `mixer_window_title` in State A and in the State B paths that got as far as binding. |
| R5 | Parameter tools share `mixerAreaLookup(runtime:)`, so they now resolve strips in the detached window; their write/readback gates are unchanged and untested here (see §6). |
| R6 | `logic://mixer` candidate read (`AccessibilityChannel+Mixer.swift`) uses the cross-window lookup while still taking project identity from the arrange window. |
| AC7 | `Tests/LogicProMCPTests/DetachedMixerWindowLookupTests.swift`: 8 tests over a fake-AX fixture with an arrange window (track-header rail) and a detached "… - Mixer: All" window. Restoring the arrange-window-only search makes the lookup and inventory tests red. The eighth test pins the target-aware fallback: a detached Mixer that does not carry the requested track or output strip must not shadow the docked pane, so the preference is a preference, not a blind first match. |

Verification performed: `swift test --filter DetachedMixerWindowLookupTests` green; `swift test --filter Issue982 --filter PluginGetInventory --filter PluginOutputStripTargeting --filter ParameterContractCensus --filter OperationRegistry --filter AXLogicProElementsTests --filter MixerStripBinding --filter Mixer123Selection` green after updating `pluginTrackBindingRetainsTheAcquiredMixerWhenAnotherMixerIsDiscoverable`, whose old assertion pinned global discovery to the arrange Mixer. The policy now explicitly prefers the detached window, and that test still proves an acquired binding is never replaced by a fresh discovery.

Two follow-on consequences of the target-aware preference are pinned in the suite rather than left implicit: (a) `defaultInsertVerified`'s preflight now passes an `accepting` predicate (the same track/output-strip resolution the read will need), because a bare `auto` lookup would bind a detached window that lacks the requested strip; (b) `PluginInsertVerifiedTests`' `testPlugin1107InsertRaisesAcquiredMixerWindowNotAnotherMixer` covers the case where an unrelated mixer window is first in `AXWindows` — it must still be refused, not silently bound. `OperationCatalogTests.commandParams[.pluginsGetInventory]` lists `mixer_window` so the strict registry census and `docs/COMMAND-PARAMETERS.md` stay in agreement with the registry.

The strict census was already red at HEAD for unrelated reasons, on the registry's side of the comparison. Seven plugin tools (`get_inventory`, `get_param_verified`, `get_channel_eq_state_verified`, `plan_parameter_changes`, `set_param_verified`, `set_eq_band_verified`, `insert_verified`) accept `strip` in the registry, but `expectedAllowedParams` derived only `index`/`project_ref`/`track`, so it reported the registry's own `strip` as unpinned. `strip` is a target selector like `track` (the plugin tools take `strip: "output"` in place of an index), so it is now part of the derived generic-selector set instead of being re-pinned per operation. The three `project.export_*` ops accept `stem_scope` in the registry and in the committed docs table but were missing it from the catalog's pinned list; the pin now matches. The docs table regeneration produced exactly one changed row (`get_inventory`, the new `mixer_window` column).

Not verified live: AC1–AC6 and AC8 require Logic with the "100 años" project and a detached Mixer window, plus a release rebuild/restart of the MCP so the bridge runs the new code.

## 8. Why this blocks real work (session context)

The user's mastering pass (Spotify −14 LUFS target) needs: high shelf +2 dB @ ~8 kHz and −1.5 dB
below ~60 Hz on Stereo Out, plus an EQ + Compressor chain on the vocal track (track 4, fader
+2.1 dB, no inserts). With this locator bug every one of those operations is refused before it can
start, and GUI scripting the plugin editor is not viable because approving the next MCP command
returns focus to the terminal and closes/loses the plugin window. The detached Mixer window is the
only working mixer surface in this session.

## 9. Opening the detached window (2026-11-02)

R4 let the server *read* a detached Mixer but not *open* one: `get_inventory {mixer_window:
"detached", reveal_mixer: true}` fell through to `notRevealed` because the only reveal drives
`View > Show Mixer`, which docks the pane inside the arrange window and never opens a second
window. The operator had to press `Window > Open Mixer` by hand.

**Measurement.** `--probe-window-menu` (observation only: it opens the Window menu through AX,
names every entry, and presses nothing) on Logic Pro Creator Studio 12.4 (6707) reports
`Open Mixer`, enabled, `AXMenuItemCmdChar: "2"`, `AXMenuItemCmdModifiers: 0` — ⌘2. The same menu
reports `Open Main Window` ⌘1 and `Open Event List` ⌘7. Apple's pinned key-command table already
in the repo (`docs/canon/web/logicpro-key-commands/global-commands.table.html`) binds `Open Mixer |
Command-2`, so the measurement and the canon agree — the shortcut is Apple's default, not an
artifact of this machine's settings.

**Decision — accelerator, not AX press on the item.** Pressing the item through AX needs a
`LabelSet`, and a `LabelSet` needs a row pinned in `docs/canon/index/`. That corpus is pinned to
Logic 12.3 (6674) while this machine runs 12.4 (6707), and `logic_canon.py build` refuses a partial
rebuild across builds; rebuilding against 12.4 changes pre-existing verified translations
(`showLibraryMenuItem`, the slider/pan hints, two plugin-window labels), which is its own change.
The accelerator is measurable today. It is also remappable, which is why the window is polled for
afterwards rather than assumed.

**Behavior.** `AccessibilityChannel.ensureDetachedMixerWindowForInventory` runs only for an
explicit `mixer_window: "detached"` request with `reveal_mixer: true`. It returns at once if the
window is already open; refuses without actuating when Logic's windows are not positively
observable; activates Logic (re-reading the windows afterwards, so activation cannot conjure an
unobservable host); posts ⌘2 to Logic's pid; then polls `mixerWindowWithoutReveal(preference:
.detached)` for `mixerRevealPollTimeoutMs` (2.5 s). It binds the window only if it appears, reports
`strategies: ["cgevent_cmd2_open_mixer"]`, and leaves the existing fail-closed
`detached_mixer_not_visible` State B path (`recovery_hint` now names `reveal_mixer:true`) when it
does not. A docked or `auto` request never takes this path.

**Tests.** `DetachedMixerWindowLookupTests` gains three: the inventory routes a detached reveal to
the new function (and a docked reveal never to it); the real function posts exactly one keycode 19
with `.maskCommand` on a fixture with no detached window, and reports the window it could not open;
and it posts nothing when the window is already open or when no Logic window is observable.
**Verified live 2026-11-02** on the running project ("100 años", release build, bridge restarted).
With only `100 años - Tracks` open, `get_inventory {strip:"output", mixer_window:"detached",
reveal_mixer:true}` reported `mixer_reveal_strategies: ["cgevent_cmd2_open_mixer"]`, a new
`100 años - Mixer: Tracks` window, `mixer_window: "detached"`. `track: 11` then read State A
(`Pop Overheads`, Channel EQ + Compressor), and after the operator scrolled Stereo Out into view,
`strip:"output"` read State A (`Channel EQ`, insert 0). Before that scroll it returned State B
`occupied_insert_name_unreadable` — the pre-existing #1228 offscreen-row limit, not the reveal.
