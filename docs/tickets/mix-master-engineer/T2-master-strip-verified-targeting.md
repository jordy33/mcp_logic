# T2: Address the master Stereo Output strip with the verified plugin surface

**Role served**: Mastering engineer — the final chain (Limiter, Channel EQ, metering) lives on the
master Stereo Output, and today that strip cannot be targeted by any verified write.
**Priority**: P0
**Size**: L — one measured precondition that has not been taken, a new reference issuance path, a
second addressing mode threaded through five dispatch sites, a resolution branch that must not
weaken the existing physical-owner invariant, and the plugin channel's `AXPluginTrackBinding`
dependency replaced by a strip-bound resolver; the AX write machinery itself is unchanged.
**Status**: Implemented 2026-10-25 with a narrower addressing design than drafted (§2.0). Parameter
*reads* on the output strip are not included.
**Depends On**: Nothing. T3 depends on this one.

## 2.0 Design actually implemented — and why it differs from the draft

The draft proposed issuing a `mix_…` reference from the output-strip inventory read and teaching
`TargetRefResolver` a second ownership proof. That was not implemented. Instead, the output strip is
addressed by **`strip: "output"`, re-resolved live on every call**:

- `AXPluginTrackBinding.resolveOutputStrip(mixer:runtime:onRefusal:)` re-enumerates the Mixer and
  re-proves the strip on each operation, so there is no reference that can go stale and nothing to
  clear on project change. A stale-reference attack surface is avoided rather than guarded.
- `Binding.trackIndex` and `Binding.header` became optional (`nil` on the output-strip path), so a
  write cannot inherit a meaningless Arrange index. `boundPluginTrack` compares the header only when
  both sides have one (`CFEqual(nil, nil)` is false, so the naive form broke the output path).
- The insert driver seam keeps its `track: Int` shape. `outputStripDriverSentinel` (`-1`) is its
  only way to say "the retained strip binding, not an Arrange index"; `boundPluginTrack` is the
  only reader and rejects it unless `authorizedPluginTrack` holds a binding with no track index.
- The track-selection ladder is **skipped** for the output strip — it is not an Arrange track, and
  running the ladder would select a different strip.
- `PluginSagaExpectedBefore.matches` now takes `Int?` and compares `Optional(self.track) == track`,
  so an output-strip write made while a Saga before-state is active fails closed.

**Supported on the output strip**: `get_inventory { strip: "output" }`, `insert_verified`,
`set_param_verified`, `set_eq_band_verified` (each replaces `track` with `strip: "output"`).

**Not supported, and refused rather than guessed**: `get_param_verified`,
`get_channel_eq_state_verified`, `plan_parameter_changes`. All three require a `pluginInsert`
`target_ref` at the dispatcher, and no reference is issued for the output strip. They refuse with
the existing "requires an occupied insert target_ref" message.

**Parameter contracts (#957).** The registry's `allowedParams` is a per-tool set, so admitting
`strip` on the four supported commands also admits it on the three unsupported ones. That is not a
claim that they work: their contracts name `strip` with a rule saying only `"output"` is accepted and
that a plugin-insert `target_ref` is still required, and the dispatcher refuses before any AX read.
For the three output-capable writes (`insert_verified`, `set_param_verified`,
`set_eq_band_verified`) `strip` is a real alternative in the published schema's selector group, so a
strip-only request is admitted by the schema and then resolved against the live Mixer.
`docs/COMMAND-PARAMETERS.md` is regenerated from the registry and committed, as #957 requires.

---

## 1. The measurement this ticket rests on — and the one it does not have

**What is measured.**

- `TargetKind` already carries `.mixerStrip` with the `mix_` prefix (`State/TargetReference.swift:10,17`).
- The Mixer surface already resolves `.mixerStrip` references and executes writes against them with
  **no track index involved**, by threading the physical binding into the channel:

  `Dispatchers/MixerDispatcher.swift:55-73` (representative; the same shape repeats at `:105`, `:139`,
  `:191`, `:273`, `:316`, `:357`, `:410`, `:476`):

  ```swift
  switch await TargetRefResolver.resolveMutationIndex(params, targetRegistry: targetRegistry, cache: cache,
      operation: operation, invalidIndexResult: toolInvalidParamsResult("A physical Mixer target_ref is required"),
      acceptedKinds: [.mixerStrip]) {
  case .failure(let result): return result
  case .success(let resolved):
      guard let physical = resolved.binding?.physicalMixerStrip, let reference = resolved.reference else { … }
      await AXMixerStripBinding.$current.withValue(physical) { … }
  ```

- Every verified plugin operation is addressed **by Arrange track index**, never by strip:

  `Dispatchers/PluginsDispatcher.swift:159` (`get_param_verified`, `get_channel_eq_state_verified`,
  `plan_parameter_changes`) and `:262`, `:316`, `:385` (`set_param_verified`, `set_eq_band_verified`,
  `insert_verified`) all pass `acceptedKinds: [.pluginInsert]` or `[.track, .pluginInsert]`, and each
  writes `writeParams["track"] = String(resolved.index)`.
- The plugin channel then resolves that index to a strip **through the Arrange header name**:
  `Accessibility/AXPluginTrackBinding.swift:24-80` reads `allTrackHeadersVerifiedRead`, requires the
  header name to be unique, and matches it against `stripEnumeration(in: mixer)`. `Accessibility/
  AccessibilityChannel+VerifiedPlugins.swift:268` is the call site.
- A master Stereo Output strip has **no Arrange track header**, so there is no index to pass and no
  header name to match. That is the entire reason this path is closed today — not a policy refusal,
  a structural one.

**What IS measured — corrected 2026-10-25.** An earlier draft of this section claimed nobody had
read the output strip's insert chain. That was wrong, and the evidence was already in the tree:

`docs/tickets/issue-234/axdump234b.out:49-67` (live Mixer dump, Logic 12.3, 2026-07-04) enumerates
**two** unclaimed strips at the right edge of the Mixer:

| Strip | `kids` | Name field | Insert row |
|-------|--------|-----------|------------|
| `AXLayoutItem desc='Stereo Out'` | 15 | `AXTextField desc='name' val='Stereo Out'` | `AXButton desc='audio plug-in' help='Audio Effect slot…'` |
| `AXLayoutItem desc='Master'` | 7 | `AXTextField desc='name' val='Master'` | **none** (it has `dim`, no `audio plug-in` row) |

So the strip the mastering chain belongs on — **Stereo Out**, not **Master** — is enumerable, is
named, and exposes exactly the insert row `audioPluginInsertSlots` classifies. The ticket as
originally written conflated the two; `Master` is a separate dim/monitor strip with no inserts at
all and is never a target here.

**What is still NOT measured:**

1. The default output-strip **name** in any locale other than en-US. `stereoOutStripName` therefore
   carries only `Stereo Out` and is not translated (see §2.1).
2. Whether `audioPluginInsertSlots`'s screen-order rule (`screenOrderedInsertSlots`) accepts a
   multi-insert output strip. The dump shows one insert row; the ordering rule was measured on
   track strips.
3. Whether Logic titles a plug-in editor window opened from the output strip's insert with the
   strip's own name (`Stereo Out`). The parameter path locates the editor by that title
   (`AccessibilityChannel+VerifiedPlugins.swift:2910`). If it does not, a parameter write on the
   output strip fails closed at the editor lookup — State C, never a wrong-target write.
4. Whether the strip survives a project epoch change with the same AX identity. The existing
   staleness rules apply; they were not re-measured for the output strip.

**Step 0 of this ticket is that measurement**, on Logic Pro 12.3, on `Scripts/livekit/` against a
fixture whose Stereo Output carries at least one insert:

1. Dump the mixer enumeration and record every strip's observed name/description.
2. Record whether a strip whose name identifies the Stereo Output appears, and at which ordinal.
3. Run `audioPluginInsertSlots` against it and record slot count, `read_status` per slot, and whether
   `complete` is true.
4. Record whether an empty slot's popup can be opened and read (the same probe `insert_verified`
   already performs for a track slot).

**If step 0 shows the master strip is not enumerable, or its slots do not read, this ticket ends in a
refusal that says so**, with the dump attached. It does not fall back to clicking coordinates and it
does not "try the last strip in the list" — a mastering chain applied to the wrong strip is worse than
no mastering chain.

**What would change if the reading turned out to be about something else.** If `stripEnumeration`
does not include the master strip because Logic lists it in a *separate* container (a different
`AXGroup` inside the Mixer window), then step 3 is about the wrong container and the ticket's premise
survives but its implementation changes: the master strip would be located in that container rather
than by ordinal. The measurement must therefore record the container path, not just the ordinal.

## 2. The change

### 2.1 A reference for the master strip

Nothing can address a strip that no operation has ever issued a reference for. Add master-strip
reference issuance to the existing inventory read — **no new public command**:

`Dispatchers/PluginsDispatcher.swift:216-238` (`get_inventory`) — accept `strip: "master"` as an
alternative to `track`:

```swift
// Before: track is the only selector
if let track = intParamOrNil(params, "track", "track_index", "index") {
    inventoryParams["track"] = String(track)
}

// After: exactly one selector
let master = nonEmptyString(params, "strip") == "master"
if master {
    guard intParamOrNil(params, "track", "track_index", "index") == nil else {
        return toolInvalidParamsResult("get_inventory takes exactly one of 'track' or strip:\"master\"")
    }
    inventoryParams["strip"] = "master"
} else if let track = intParamOrNil(params, "track", "track_index", "index") {
    inventoryParams["track"] = String(track)
}
```

Any other `strip` value is `invalid_params`. Absent both, the channel's existing `invalid_params`
fires unchanged.

`AccessibilityChannel+VerifiedPlugins.swift:178` currently requires `track` and refuses without it.
Add the branch:

```swift
// Before
guard let trackRaw = params["track"] ?? params["track_index"] ?? params["index"],
      let track = Int(trackRaw), track >= 0 else { … }

// After
if params["strip"] == "master" {
    return await masterStripInventory(params: params, runtime: runtime)
}
guard let trackRaw = … (unchanged)
```

`masterStripInventory` is new and does exactly four things, in this order — each one a refusal if it
cannot be proven:

1. locate the Stereo Output strip by the container path step 0 recorded, and require **exactly one**
   candidate;
2. read the strip's own name/description and require it to match the measured master-strip label (a
   new `LabelSet`, measured, not translated);
3. enumerate `audioPluginInsertSlots` and require `unreadableChildren == 0` — the same rule
   `AXPluginTrackBinding` already enforces at `:66-68`;
4. emit the same `plugins[]` item shape `pluginInventoryItems` produces (`:73+`) and register a
   `mix_…` reference bound to the physical strip.

The response must name the strip explicitly (`"strip": "master"`, `"track": null`) so a consumer
cannot mistake it for track 0.

### 2.2 The plugin ops accept `.mixerStrip`

`Dispatchers/PluginsDispatcher.swift` — add `.mixerStrip` to the accepted kinds at `:159`, `:262`,
`:316`, `:385`, and branch on the resolved binding:

```swift
acceptedKinds: [.track, .mixerStrip, .pluginInsert]
…
case .success(let resolved):
    if resolved.binding?.kind == .mixerStrip {
        guard let physical = resolved.binding?.physicalMixerStrip,
              let reference = resolved.reference else {
            return TargetRefResolver.staleTargetReferenceResult(
                params["target_ref"]?.stringValue, operation: operation)
        }
        writeParams.removeValue(forKey: "track")
        writeParams["strip"] = "master"
        // The physical owner is revalidated by the channel at each action; an
        // Arrange index is deliberately not synthesized.
        return await AXMixerStripBinding.$current.withValue(physical) {
            await toolTextResult(router.route(operation: "plugin.\(command)", params: writeParams))
        }
    }
    writeParams["track"] = String(resolved.index)
    … existing path, unchanged
```

**Judgement made here:** the master path does **not** synthesize a track index. Producing a fake
`track` so the existing code path "just works" would hand the channel an Arrange index that refers to
something else entirely — the exact class of bug the honest-contract machinery exists to prevent. The
channel gets a strip mode instead.

### 2.3 A strip-bound resolver in the plugin channel

`Accessibility/AXPluginTrackBinding.swift` gains a sibling:

```swift
static func resolve(
    physical: AXMixerStripBinding.Binding,
    mixer: AXUIElement,
    runtime: AXLogicProElements.Runtime,
    onRefusal: ((String) -> Void)? = nil
) -> Binding?
```

It performs the same proven steps as `resolve(track:)` — live mixer enumeration, unreadable-child
count zero, name read for every strip, exactly one match — but derives the expected strip from
`physical` (via `matches`) instead of from an Arrange header name, and requires the matched strip to
be **the unique** strip matching that physical binding. `Binding.trackIndex` becomes optional
(`let trackIndex: Int?`) so the master case cannot inherit a meaningless index.

Call sites that must be adapted for the optional — **all of them enumerated**:

| Site | Change |
|------|--------|
| `AXPluginTrackBinding.swift:24-80` | `trackIndex` → optional; still always set on the Arrange path |
| `AccessibilityChannel+VerifiedPlugins.swift:268` | branch: master → `resolve(physical:)`, else `resolve(track:)` |
| `AccessibilityChannel+VerifiedPlugins.swift:362` (`"mixer_strip_index": target.mixerStripIndex`) | unchanged; still an observation |
| Any reader of `Binding.trackIndex` | mechanical; the field is only ever used to echo an index back |

Search before implementing: `grep -rn "trackIndex" Sources/LogicProMCP/Accessibility/AXPluginTrackBinding.swift` and in `AccessibilityChannel+VerifiedPlugins.swift`. If a consumer **requires** a non-optional index for a decision (not an echo), that consumer is on the `set_param_verified` write path and is a defect this ticket must fix, not paper over with `?? 0`.

### 2.4 Resolution must not weaken the physical-owner invariant

`Dispatchers/TargetRefResolution.swift:102-128` currently proves a `.mixerStrip` reference by
requiring membership in `cache.getChannelStrips()`:

```swift
await cache.getChannelStrips().contains(where: { $0.physicalBinding?.matches(physical) == true })
```

`ChannelStripState` is track-indexed (`State/StateModels.swift:184`), and the master strip has no
track index, so it will not be in that collection. **Do not delete the check** — extend it with a
second, equally strong proof:

```swift
let ownedByTrack = await cache.getChannelStrips().contains(where: { $0.physicalBinding?.matches(physical) == true })
let ownedByMaster = await cache.getMasterStripBinding()?.matches(physical) == true
guard …, (ownedByTrack || ownedByMaster) else {
    return .failure(staleTargetReferenceResult(rawReference, operation: operation))
}
```

`getMasterStripBinding()` is a new cache accessor written **only** by the step-0-verified master
inventory read (`2.1`), and it is cleared on project-epoch change by the same mechanism that clears
project-scoped state. A master reference that cannot be re-observed against a live census is stale —
the same answer the existing branch already gives for a track strip.

## 3. Call sites the change reaches — enumerated

| # | Site | Kind |
|---|------|------|
| 1 | `Dispatchers/PluginsDispatcher.swift:216-238` | cannot be resolved mechanically — selector exclusivity, §2.1 |
| 2 | `Dispatchers/PluginsDispatcher.swift:159,262,316,385` | mechanical — add `.mixerStrip`, but the master branch in each is judgement supplied here (§2.2) |
| 3 | `Channels/AccessibilityChannel+VerifiedPlugins.swift:178` | needs a value — the `strip` branch |
| 4 | `Channels/AccessibilityChannel+VerifiedPlugins.swift:268` | mechanical once the resolver exists |
| 5 | `Accessibility/AXPluginTrackBinding.swift` (new resolver + optional field) | cannot be resolved mechanically — §2.3 |
| 6 | `Dispatchers/TargetRefResolution.swift:102-128` | needs a value — the second owner proof, §2.4 |
| 7 | `State/StateCache.swift` (new `getMasterStripBinding`) | mechanical |
| 8 | `Accessibility/AXLocalePolicy.swift` (new master-strip label) | **measured**, not supplied |
| 9 | `Server/OperationParameterContracts.swift` — `logic_plugins.get_inventory` params | mechanical |
| 10 | `Dispatchers/PluginsDispatcher.swift:87` (tool description) | mechanical — document `strip:"master"` and the `.mixerStrip` target_kind |
| 11 | `Dispatchers/MixerDispatcher.swift:615-618` (`insert_plugin` allowlist message) | verify only — the legacy mixer insert is a different surface and is **not** being extended |

## 4.0 Acceptance criteria as implemented (2026-10-25)

Hermetic tests in `Tests/LogicProMCPTests/PluginOutputStripTargetingTests.swift` (fake AX runtime,
fixtures modelled on the issue-234 dump):

| # | Criterion | Status |
|---|-----------|--------|
| I-1 | The output strip resolves by measured name **and** a non-empty insert section; `Master` (no insert row) is not it | ✅ `outputStripResolvesWithoutAnArrangeIndex`, `masterStripWithoutInsertsIsRefused` |
| I-2 | A strip named `Stereo Out` with no insert section refuses (`output_strip_insert_section_unavailable`) instead of reporting a verified-empty chain | ✅ `outputStripWithoutInsertSectionIsRefused` |
| I-3 | Two same-named strips refuse (`output_strip_name_not_unique`); no ordinal fallback | ✅ `duplicateOutputStripNameIsRefused` |
| I-4 | `get_inventory { strip: "output" }` returns State A with `strip: "output"`, `track: null`, `track_name: "Stereo Out"` | ✅ `inventoryOnOutputStripNamesItsTarget` |
| I-5 | `strip` + `track` together, `strip: "master"`, and neither selector are all State C `invalid_params` | ✅ `inventorySelectorExclusivity` |
| I-6 | `insert_verified` refuses `strip` + `track` before any AX access | ✅ `insertVerifiedRefusesBothSelectors` |
| I-7 | The output binding is stable across a re-resolution | ✅ in I-1 |

**Still open** — the original ACs below describe the `mix_` reference design and do **not** apply
as written. What remains unproven, and would need a live Logic run:

- AC-1 / AC-2 / AC-3: a live inserts-and-parameters round trip on a real Stereo Out strip, including
  whether the plug-in editor window opens under the strip's name (measurement gap 3 in §1).
- AC-5: cross-project staleness — not applicable, there is no stored reference; the strip is
  re-proven per call.
- AC-6: covered by the existing Arrange tests passing unedited; run them.
- AC-7: `Binding.trackIndex` is `Int?` with no `?? 0` anywhere — asserted by §2.0's constructor
  (there is no numeric default to fall back to), not by a separate test.

## 4. Acceptance criteria that can fail (original `mix_` reference design — not implemented)

- [ ] **AC-1** On a fixture with a Stereo Output carrying 2 inserts, `get_inventory { strip: "master" }`
      returns 2 slots with `read_status: "ok"` and a `mix_…` target_ref, under 40 seconds, and the
      response names the strip as master with `track: null`. (Step 0's measurement, re-run as a test.)
- [ ] **AC-2** `insert_verified` with that `mix_…` ref and `plugin: "channel_eq"` returns State A
      **only when** a post-insert `get_inventory` on the same ref observes Channel EQ at the requested
      slot. A test that reports State A from the click alone goes red.
- [ ] **AC-3** `set_eq_band_verified` on the master ref writes and reads back within tolerance, State
      A, on the same ref, after `get_inventory` has confirmed the strip still matches.
- [ ] **AC-4** `get_inventory` with both `track` and `strip:"master"` is `invalid_params`; with
      `strip:"aux"` is `invalid_params`; with neither is the existing refusal, unchanged.
- [ ] **AC-5** A master `mix_…` ref used after the project changed (project epoch bump, or a second
      project opened) is refused `stale_target_reference` **before** any AX write, with
      `write_attempted: false`. Checked by constructing the ref, reopening the project, then writing.
- [ ] **AC-6** The Arrange-track path is byte-for-byte unchanged: the existing `set_param_verified` /
      `insert_verified` / `get_inventory{track}` tests pass without edits. Any test that needs editing
      means the optional `trackIndex` leaked into a decision.
- [ ] **AC-7** `grep -rn 'trackIndex'` over `AXPluginTrackBinding.swift` shows no `?? 0` fallback.
      Asserted by a test that fails on the literal `?? 0` in that file.

## 5. Mutations that must turn a test RED

1. Remove the `ownedByMaster` half of §2.4 → AC-5 goes red only if the master half is the only proof;
   to make it red, delete **both** halves and assert a cross-project master ref still resolves.
2. Reset `writeParams["strip"]` to also set `writeParams["track"] = "0"` → AC-6 goes red (the master
   write lands on track 0's strip).
3. Return State A on `insert_verified` without the post-insert inventory readback → AC-2 goes red.
4. Make `Binding.trackIndex` non-optional again with `?? 0` → AC-7 goes red.
5. Accept `strip` values other than `"master"` → AC-4 goes red.
6. Skip the `audioPluginInsertSlots` `unreadableChildren == 0` check → AC-1 goes red on a fixture with
   an unreadable slot (constructed in the fake runtime).

## 6. Explicitly NOT in scope

- **Limiter insertion and its parameters** — that is T3, and it is blocked on this ticket for the
  master chain only. (Limiter on a *track* strip is not blocked; it is simply not this ticket.)
- Aux/bus/VCA strip targeting. Only the master Stereo Output is added. Generalising to every strip
  without a track header is the same code shape but a different identity question — an aux has a bus
  number and a name a user can change — and is not decided here.
- Routing changes on the master strip (output assignment, bounce source).
- The legacy `logic_mixer.insert_plugin` allowlist (`MixerDispatcher.swift:615-618`). It keeps its
  three plugins and its track addressing.
- Master-strip **metering** readback.
- Any write to the master strip's fader/pan — `mixer.set_volume` / `set_pan` already accept
  `.mixerStrip` **for track strips**; whether they work on the master is a separate measurement and
  is not tested here.

## 7. What this ticket does NOT establish

- That a mastering chain written through this surface sounds like anything in particular. It
  establishes that the write lands on the strip Logic calls Stereo Output and that the value reads
  back. It says nothing about whether that strip is the one feeding the bounce path — **that is not
  verified here** and is the single largest gap between "the master chain is set" and "the master
  chain is applied to the render". T4's bounce readback does not close it either; a null test against
  a master-chain-bypassed render would, and no such test exists.
- That the master strip's insert slots are enumerable in locales or Logic versions other than the one
  step 0 measures.
- That an `insert_verified` on the master survives a sample-rate change, a project reload, or a
  Control Surface re-connect. The staleness rules are the existing ones; they were not re-measured
  against the master strip.
- Any opinion about what a mastering engineer *should* do. This ticket only makes the strip writable.
