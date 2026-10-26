# T1: Bind an exported stem file to the track it came from

**Role served**: Mixing engineer — it must receive one file per recorded track, labelled with that
track's identity, or it cannot treat the stem set as a mix to balance.
**Priority**: P0
**Size**: L — a new export scope on a public operation, a per-subject export loop with selection
custody and restoration, a new measured label set, and a contract change on the exporter's State-A
reachability; the panel driver itself already exists.
**Status**: Implemented 2026-10-25 (unit-verified; live acceptance still open — see §9)
**Depends On**: #369 T1 (the panel drive, `docs/tickets/issue-369-per-track-stem-export/`)

---

## 1. The measurement this ticket rests on, and its limits

**Measured live on Logic Pro 12.3, 2026-08-19** (`docs/tickets/issue-369-per-track-stem-export/STATUS.md`):

- `File ▸ Export` carries three audio-file leaves whose wording distinguishes all-tracks from a
  selection: `All Tracks as Audio Files…` and a selection form.
- **The leaf title is rewritten by the current selection**: `Tracks as Audio Files…` became
  `1 Track as Audio File…` while one track was selected. This is the load-bearing measurement for
  this ticket — it is what makes a one-file-per-track export identifiable by selection rather than
  by guessing from the resulting filenames.
- A closed menu reads `enabled=false` for items that are enabled; enablement is only meaningful with
  the menu open.
- One populated track produced `Studio Grand_1.aif`, 2.048 s, 0.744 s non-silent, analyzer `pass`.

**Limits of that reading, stated so the implementer does not over-trust it:**

- The singular leaf spelling `1 Track as Audio File…` was observed **in en-US only**. The `LabelSet`
  this ticket adds (`singleTrackAsAudioFileMenuItem`) must be *measured*, not translated. Until it
  is, every non-en-US locale must refuse with `late_bound_label_unmeasured` rather than fall back to
  keyword matching — the same rule `allTracksAsAudioFilesMenuItem` already states in its rationale
  (`Sources/LogicProMCP/Accessibility/AXLocalePolicy.swift:677-684`).
- The measurement says the selection changes the leaf. It does **not** say the export writes exactly
  one file, that the selection survives the panel opening, or that the file's name contains the
  track name. **Nothing below assumes any of those three.** The ticket's design deliberately does not
  depend on the filename: it binds by construction (one selection, one export, one new file).
- **Not measured**: whether Logic preserves the pre-existing track selection after the panel closes
  in this path. The ticket therefore restores it explicitly and verifies the restore, rather than
  assuming it.

If the reading turns out to be about a *different* menu entry than the one `stemLeafTitleMatches`
resolves — the risk the reading flags, since the same panel's leaves share most of their wording —
then the whole selection-binding mechanism loses its discriminator and this ticket ends in a refusal,
not an implementation. That is the acceptable outcome and is checked by AC-3.

## 2. What the code does today

`export_run artifacts:["stem"]` drives **one** panel export for the whole project and then observes
the destination's before/after delta:

`Sources/LogicProMCP/Projects/ProjectExportExecutorArtifactFlow.swift:331-379`

```swift
// after-delta
let appeared = …   // every supported audio entry present after and not before
…
reason = "stem_subject_file_binding_unestablished: observed=\(appeared.count) expected=\(subjects.count); filenames are late-bound, no name-matching rule is used, and post-snapshot entries may have been created concurrently"
```

Every subject then receives the same observation list and State B
(`stemSubjectArtifacts`, `:413-439`). There is no path from a produced file to a subject, so a stem
run **cannot** reach State A. The mixing-engineer workflow therefore has no verified input at all:
it cannot know which `.aif` is the vocal and which is the kick drum, and the server says so.

That refusal is correct for a batch export. It stops being necessary once the export is per track.

## 3. The change

Add an export scope to the stem artifact. `all_tracks` keeps today's behaviour exactly (State B,
`stem_subject_file_binding_unestablished`). `per_track` exports one subject at a time and binds by
construction.

### 3.1 New public parameter

`Sources/LogicProMCP/Server/OperationParameterContracts.swift:544-555` — the export contract is built
from one shared parameter list:

**Before**

```swift
for op in ["export_plan", "export_run", "export_resume"] {
    var params = Dictionary(uniqueKeysWithValues: [
        "artifact", "artifacts", "collision_policy", "kind", "naming_policy", "outputRoot", "output_root",
        "path", "project", "projects",
    ].map { ($0, ParamRule.unconstrained("checked by ProjectExportPlanner.plan, whose refusals are not yet recorded by kind",
                                         sample: exportSamples[$0])) })
    if op != "export_plan" { params["confirmed"] = .enforced(.boolean, .bool(false)) }
```

**After**

```swift
for op in ["export_plan", "export_run", "export_resume"] {
    var params = Dictionary(uniqueKeysWithValues: [
        "artifact", "artifacts", "collision_policy", "kind", "naming_policy", "outputRoot", "output_root",
        "path", "project", "projects", "stem_scope",
    ].map { ($0, ParamRule.unconstrained("checked by ProjectExportPlanner.plan, whose refusals are not yet recorded by kind",
                                         sample: exportSamples[$0])) })
    if op != "export_plan" { params["confirmed"] = .enforced(.boolean, .bool(false)) }
```

and add the sample beside the others, `OperationParameterContracts.swift:174-178`:

```swift
private static let exportSamples: [String: Value] = [
    "path": .string("/tmp/lpm-957.logicx"), "project": .string("/tmp/lpm-957.logicx"),
    "projects": .array([.string("/tmp/lpm-957.logicx")]),
    "output_root": .string("/tmp/lpm-957-out"), "outputRoot": .string("/tmp/lpm-957-out"),
    "stem_scope": .string("per_track"),
]
```

`stem_scope` is accepted only when the request contains a `stem` artifact. A request that passes
`stem_scope` without `stem` is `invalid_params` — the parameter must not silently do nothing.

### 3.2 Planner records the scope

`Sources/LogicProMCP/Projects/ProjectExportPlanner.swift`, `stemArtifact` at `:220-287`. Add
`stemScope` to the plan artifact model (`ProjectExportPlannerModels.swift`,
`ProjectExportPlanArtifact`), defaulting to `.allTracks`, and set it from the validated request in
`validateStemRequest` at `:292-337`. `validateStemRequest` gains one rule:

```swift
// per_track requires exactly one project (already a stem precondition) AND a subject list that was
// read fresh; it does not require the destination folder to be empty, because each subject's file is
// named and collision-checked one at a time.
```

`export_plan` must echo `stem_scope` in the artifact's planning reason so a dry run says which mode
it would run. **This is the plan-time answer #369's T1 said was missing**: a per-track stem plan
promises *N exports, each bound to one subject by its own selection*, and it explicitly does not
promise a file list.

### 3.3 Leaf resolution gains a scope

`Sources/LogicProMCP/Projects/ProjectStemExportPanelDriver.swift:1325-1327`

**Before**

```swift
static func stemLeafTitleMatches(_ title: String) -> Bool {
    AXLocalePolicy.allTracksAsAudioFilesMenuItem.matches(title)
}
```

**After**

```swift
static func stemLeafTitleMatches(_ title: String, scope: StemExportScope) -> Bool {
    switch scope {
    case .allTracks:
        return AXLocalePolicy.allTracksAsAudioFilesMenuItem.matches(title)
    case .perTrack:
        return AXLocalePolicy.singleTrackAsAudioFileMenuItem.matches(title)
    }
}
```

New label set in `Sources/LogicProMCP/Accessibility/AXLocalePolicy.swift`, beside
`allTracksAsAudioFilesMenuItem` (`:677-684`), registered in the argument list at `:3653`:

```swift
static let singleTrackAsAudioFileMenuItem = LabelSet(
    canonical: "1 Track as Audio File…",
    variants: ["1 Track as Audio File…"],   // en-US only until each locale is measured
    rationale: "Measured 2026-08-19 on Logic Pro 12.3 in en-US: with exactly one Arrange track selected, the File > Export leaf the all-tracks entry rewrites to. Only the en-US string is measured; other locales must refuse rather than fall back to keyword matching.",
    derivedFrom: nil
)
```

**Judgement, made here so the implementer does not have to:** the plural "Selected Tracks as Audio
Files…" is deliberately **not** matched. A per-track run exports exactly one track at a time; a leaf
that offers a multi-selection export is a different command and treating it as equivalent is how a
run silently exports the wrong set. `SingleTrack` in the name is the invariant, not a name.

### 3.4 The per-subject loop

`Sources/LogicProMCP/Projects/ProjectExportExecutorArtifactFlow.swift`, `produceStem` at `:223-380`.
Branch immediately after the existing destination/collision preflight:

```swift
switch artifact.stemScope {
case .allTracks:
    return await produceStemAllTracks(artifact: artifact, plan: plan, options: options)   // today's body, unchanged
case .perTrack:
    return await produceStemPerTrack(artifact: artifact, plan: plan, subjects: subjects, options: options)
}
```

`produceStemPerTrack`, for each subject in plan order:

1. **Read the current selection.** This lives in `ProjectStemExportPanelDriver`, not the executor —
   the driver is already the AX seam for exports (it holds `runtime: AXLogicProElements.Runtime` and
   `mouseRuntime`, `:317-321`), and the executor never touches AX itself (`Options.live()` passes the
   driver in as a closure, `ProjectExportExecutor.swift:96-110`). Read `AXSelected` per Arrange header
   with `AXValueExtractors.extractSelectedState` and record which indices are selected before the
   first export. Keep the same fail-closed rule the channel states at
   `AccessibilityChannel+Tracks.swift:2801-2814`: an unreadable flag means *unknown*, not *unselected*.
   `selectionPresentation` (`:667`) is `private` and is **not** made public for this; the driver's
   needs are narrower (which indices, and whether they are restored) than the channel's presentation
   record, and reusing a private helper by widening it would put a second consumer on a type built for
   one.
2. **Select exactly this subject** and prove it. Reuse the existing primitives rather than writing
   new ones: `AXLogicProElements.selectTrackViaAX(at:runtime:)` plus
   `AccessibilityChannel.selectionIsExclusive(index:runtime:)` (`:2801-2814`) with the bounded
   re-check loop at `:2780-2794`. Selection is by **Arrange index corroborated against the subject's
   name**, not by index alone; a name mismatch is State C `subject_selection_name_mismatch` and the
   loop stops.
3. **Drive one panel export** through `options.driveStemExport(destination)` with
   `scope: .perTrack`. The driver opens the menu, resolves the singular leaf, sets the destination,
   presses Export, and waits for the progress window — all of that already exists in
   `ProjectStemExportPanelDriver`; only the scope parameter and its leaf are new.
4. **Observe the destination delta for exactly one new file.** Zero new files or more than one is
   State B `per_track_export_observed_n_files` for that subject (not a crash, not a success), and the
   run continues to the next subject. This is the one place the batch logic already written
   (`:331-379`) is reused with `expected: 1`.
5. **Bind**: on exactly one new file, that file *is* the subject's output — the exported set was a
   single selected track. Run `options.analyze` on it with the same `analysisPolicy` (`:470-476`) the
   all-tracks path uses. Analyzer `pass` ⇒ **State A**, with the file path and the subject identity in
   the evidence. Analyzer warn/fail ⇒ State B with the same reasons the single bounce path reports
   (`.wav`/`.aif` path safety still applies).
6. **Restore the original selection** after every subject, including on refusal and cancellation,
   and verify the restore by re-reading the selected-index set and comparing it to the set recorded
   in step 1 (same fail-closed rule: an unreadable flag is not a match). A restore that cannot be
   proven is reported as a run-level `selection_restore_unproven` warning on every artifact the run
   produced; it does not downgrade an already-verified artifact (the file *was* produced and *was*
   analyzed) but it is never silent.

**Why State A is now honest.** In the batch path, "a file appeared" says nothing about which track
produced it. In the per-track path the export is driven with a proven-exclusive selection of one
track, so the file's provenance is fixed before it exists. That is the whole difference, and it is
the reason this ticket exists.

### 3.5 Ordering and failure semantics

Subjects are exported **serially**. A subject that ends State B or C does not abort the run — the
mixing engineer is better served by 11 of 12 tracks plus an explicit list of what is missing than by
nothing. The run result's aggregate (`ProjectExportExecutorRunResults.swift:4-59`) already reports the
worst state; confirm it reports per-subject states and that `confirmationRequiredRun` still gates the
whole run before any export.

## 4. Call sites the change reaches — enumerated

| # | Site | Kind |
|---|------|------|
| 1 | `Server/OperationParameterContracts.swift:544-555` | mechanical — add `stem_scope` to the list |
| 2 | `Server/OperationParameterContracts.swift:174-178` | needs a value this ticket supplies (the sample) |
| 3 | `Projects/ProjectExportPlanner.swift:292-337` | needs a value (`stemScope` from params) |
| 4 | `Projects/ProjectExportPlannerModels.swift` (`ProjectExportPlanArtifact`) | mechanical field addition + Codable |
| 5 | `Projects/ProjectExportPlanner.swift:220-287` (`stemArtifact`) | mechanical — pass the scope through |
| 6 | `Projects/ProjectStemExportPanelDriver.swift:1325-1327` | mechanical — signature + switch |
| 6b | `Projects/ProjectStemExportPanelDriver.swift` (the drive entry, `:108`; runtime at `:317-321`) | cannot be resolved mechanically — selection/restore custody lands here, §3.4 steps 1, 2, 6 |
| 7 | `Accessibility/AXLocalePolicy.swift:677` (neighbour) and `:3653` (registration) | needs a value this ticket supplies, which must be **measured** |
| 8 | `Projects/ProjectExportExecutorArtifactFlow.swift:223-380` | cannot be resolved mechanically — this is the branch and the loop, §3.4 |
| 9 | `Projects/ProjectExportExecutor.swift:96-110` (`StemExportDrive` typealias and `Options.live()`) | needs the scope threaded into the drive closure |
| 10 | `Dispatchers/ProjectDispatcher.swift:114-222` | mechanical — `stem_scope` passes through the existing param dictionary |
| 11 | `Projects/ProjectExportExecutorRunResults.swift:4-59` | verify only — no change expected; if the aggregate collapses per-subject states, that is a bug this ticket must fix, not assume away |

`export_resume` (`ProjectExportExecutor.swift:163-169`) continues to **refuse stems**. Per-track mode
does not change that: a resumed per-track run would re-drive Logic's panel against a folder whose
state it did not establish. Revisit separately.

## 5. Acceptance criteria that can fail

- [ ] **AC-1** A `per_track` run over 3 populated tracks produces 3 artifacts, each State A or B, and
      each `target`/subject field naming a distinct track. A run that returns fewer than 3 artifacts
      fails.
- [ ] **AC-2** For each State-A artifact, the file named in the result is the only file the
      destination gained during that subject's export window. Checked by snapshotting the destination
      around each subject, not around the run.
- [ ] **AC-3** With exactly one track selected before the menu is opened, the leaf resolved is the
      singular form. If the driver resolves `All Tracks…` instead, the run is State C
      `stem_scope_leaf_mismatch` and **nothing is exported**. Live check on a fixture with ≥2 tracks.
- [ ] **AC-4** A subject whose selection cannot be proven exclusive is State C
      `subject_selection_not_exclusive` and produces no export, and the following subject still runs.
      Checked by forcing the exclusivity predicate false in a unit test.
- [ ] **AC-5** The pre-run selection is restored and proven equal after the run, including when the
      run ends in refusal. A test that mutates the restore away turns this red.
- [ ] **AC-6** `stem_scope: "per_track"` with no `stem` artifact is `invalid_params`; `stem_scope:
      "sideways"` is `invalid_params`; `all_tracks` (or absent) produces today's State B
      `stem_subject_file_binding_unestablished` unchanged — asserted by a test that fails if the old
      reason string is altered for the old path.
- [ ] **AC-7** A per-track run in a non-en-US locale where the label is unmeasured refuses before
      opening any menu, with `late_bound_label_unmeasured`. Checked by pointing the locale policy at a
      locale with no measured variant.

## 6. Mutations that must turn a test RED

1. Delete the `selectionIsExclusive` re-check in the loop → AC-4's test goes red.
2. Make `stemLeafTitleMatches` return the all-tracks label for `.perTrack` → AC-3 goes red.
3. Remove the per-subject delta (`expected: 1`) and diff the whole run → AC-2 goes red (a
   two-subject fixture assigns the wrong file to a subject).
4. Skip the selection restore → AC-5 goes red.
5. Return State A for a zero-file observation → the analyzer-gated test for that subject goes red.
6. Keep `stem_subject_file_binding_unestablished` for `per_track` → AC-1 goes red (still State B).

## 7. Explicitly NOT in scope

- Filename template matching (`<TrackName>_1.aif`). The binding here is by construction; a name-based
  association is a different, weaker mechanism and is not added even as a corroboration, because a
  corroboration that can disagree with the construction invites a retry that overwrites the wrong
  file.
- Parallel or batched per-track export (one menu open, N exports).
- `export_resume` for stems.
- Per-track export of *ungrouped regions* (sub-track granularity). Subjects remain tracks.
- The all-tracks batch path's State B. It stays exactly as it is.
- Mixing decisions themselves (levels, pans, EQ) — those are `logic.py`, not this server.

## 8. What this ticket does NOT establish

- That Logic's per-track export produces a file whose *contents* correspond only to the selected
  track. The ticket establishes **which export was driven for which subject**, and the analyzer
  establishes the file is real, non-silent audio of the expected shape. It does **not** establish
  that the file contains no bleed, no bus processing, or the same start offset as the other stems.
  A stem-sum-vs-bounce null test is out of scope and remains unbuilt.
- That the label is measured in any locale other than en-US.
- That a selection survives Logic's panel opening in every region/group configuration. The restore is
  explicit for this reason; if a configuration breaks the selection proof, the run refuses per AC-4.
- Anything about the mixing decisions the downstream engineer makes. This ticket only makes the stem
  set *addressable*.


---

## 9. What was implemented (2026-10-25), and where it deviates from §3

Implemented on the branch's working tree. `swift build` is green and the new suites pass; nothing
here has been exercised against a running Logic Pro, so every live statement in §1 keeps the
standing it had.

### 9.1 The shape that was built

| Piece | Where |
|---|---|
| `stem_scope` parameter (`all_tracks` \| `per_track`), refused without a `stem` artifact and on an unknown value | `ProjectExportPlanner.stemExportScope`, `OperationParameterContracts`, `OperationRegistry` |
| Scope recorded on the plan artifact + echoed as `analysis["stem_scope"]` / `analysis["stem_scope_plan"]` | `ProjectExportPlannerModels.ProjectExportPlanArtifact`, `ProjectExportPlanner.stemArtifact` |
| `singleTrackAsAudioFileMenuItem` (en-US only, no `derivedFrom`) | `AXLocalePolicy` |
| Scope-aware leaf matching, with a distinct refusal when the menu offers the all-tracks leaf to a per-track run | `ProjectStemExportPanelDriver.stemLeafTitleMatches(_:scope:)`, `AXSurface.resolveStemLeaf` |
| Selection custody: capture → select+prove → export → restore+prove | `ProjectStemExportPanelDriver.drive(destination:scope:subject:…)` and four new `Surface` members |
| Per-subject loop, per-subject before/after fence, State A when exactly one file appeared and the analyzer passed | `ProjectExportExecutorArtifactFlow.produceStemPerTrack` / `produceStemForSubject` |
| `warnings` on a run artifact, for a run-level note that does not lower its state | `ProjectExportRunArtifact` |

### 9.2 Deliberate deviations, each with its reason

1. **Selection custody lives in the driver, behind four `Surface` members**, not in the executor
   and not via `selectionPresentation`. The members are `captureSelection()`, `selectSubject(index:name:)`,
   `restoreSelection(_:)` and `selectionMatches(_:)`, all with fail-closed protocol-extension defaults
   (`nil`, `.refused("stem_per_track_selection_unsupported")`, an unrestorable reason, `false`). A
   surface that only supports all-tracks therefore cannot silently skip a step: a per-track run
   against it refuses before opening any menu.
2. **A restore that cannot be performed is reported, not approximated.** The measured primitive
   (`AXLogicProElements.selectTrackViaAX(at:)`) selects ONE track. A snapshot naming zero tracks or
   several tracks is therefore not restorable, and the driver says so
   (`selection_restore_unavailable_for_empty_selection` / `…_for_multi_selection`) instead of
   selecting "the nearest thing". The result travels as a new driver outcome case,
   `completedSelectionRestoreUnproven`, which the executor turns into a `warnings` entry on every
   artifact the run produced. It never downgrades a State A: the file was written and analyzed.
3. **`per_track` does NOT weaken `fail_if_exists`.** §3.2 says a per-track run does not require an
   empty destination. That claim was not adopted: the file Logic will name is unknown before the
   export, so a per-subject delta cannot tell "a new file appeared" from "an existing file was
   overwritten" — an overwrite would surface as an honest-looking `observed=0`. The pre-run
   non-empty refusal therefore stays for both scopes.
4. **The label set carries no variants and no `derivedFrom`.** Apple's string table has no row for
   this title: Logic rewrites the leaf from the live selection, and the nearest key
   (`Export Track as Audio File`) names a key command routed differently. Every locale other than
   en-US therefore refuses as `stem_export_single_track_audio_file_label_not_measured_for_current_locale`
   rather than matching keywords.
5. **`export_resume` continues to refuse stems.** Threading `stem_scope` through it only satisfies
   the parameter contract; the executor's existing refusal is untouched.

### 9.3 Acceptance criteria, mapped to tests

`Tests/LogicProMCPTests/StemPerTrackExportTests.swift`:

- **AC-1** `perTrackBindsEachFileToItsSubject` — two subjects, two State A artifacts, distinct
  subjects and distinct paths.
- **AC-2** same test: each artifact's path is the single file written during that subject's own
  drive window. `twoFileWindowIsNotAttributed` and `zeroFileWindowDoesNotAbortTheRun` prove the
  fence fails closed in both directions.
- **AC-3** `leafMatcherIsScopeSpecific` (singular vs all-tracks, both scopes),
  `perTrackSurfaceRefusesTheAllTracksLeaf` (a synthetic menu tree offering only the all-tracks leaf
  makes a per-track `AXSurface` refuse `stem_scope_leaf_mismatch`, and the same tree is `.available`
  to an all-tracks surface) and `unmeasuredPerTrackLeafRefuses` (a near-miss title that is not the
  measured en-US string refuses as unmeasured rather than resolving). The **live** menu walk — that
  a running Logic actually shows the singular leaf to a per-track run — is not exercised by any test.
- **AC-4** `refusedSelectionDoesNotOpenTheMenu` — a refused exclusivity proof produces no export and
  no menu opening; `zeroFileWindowDoesNotAbortTheRun` shows the following subject still runs.
- **AC-5** `unprovenRestoreIsReported` (driver) and `unprovenRestoreCarriesWarnings` (executor).
  Removing either the restore or the `selectionMatches` proof turns them red.
- **AC-6** `scopeValidation` (`stem_scope` without `stem`; unknown value) and
  `allTracksReasonIsUnchanged` (the batch path still reports `stem_subject_file_binding_unestablished`).
- **AC-7** `unmeasuredPerTrackLeafRefuses` covers the refusal *path*: any title the label set has not
  measured resolves to neither leaf and the per-track surface reports
  `stem_export_single_track_audio_file_label_not_measured_for_current_locale`. What it does not do is
  put the process in a real non-en-US locale: the fixture supplies the unmatched title directly. The
  label set carries no variants, so for every locale other than en-US this is what the code does by
  construction; the locale-negotiation half is covered by the existing LabelSet tests.

### 9.4 What this still does not establish

- That Logic's per-track export writes exactly one file, that the selection survives the panel
  opening, or that the singular leaf is what the menu shows in any given locale — all three were
  unmeasured when the ticket was written and remain unmeasured. The design keeps refusing rather
  than assuming. §8's list is unchanged and still applies.
- Anything about the *contents* of the exported file (bleed, bus processing, start offset).
- A restore for a multi-track or empty pre-run selection.
