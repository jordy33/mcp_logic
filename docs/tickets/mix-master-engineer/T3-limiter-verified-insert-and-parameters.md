# T3: Insert a Limiter and write its parameters with verified readback

**Role served**: Mastering engineer — the final peak/ceiling control is a Limiter on the master Strip
(T2) or on a bus; today it cannot be inserted by any verified operation and none of its parameters
can be written.
**Priority**: P0
**Size**: M — three allowlist entries, one measured live Controls-view reading per parameter that has
never been taken, a catalog parameter block, and a capability-registry promotion from `experimental`
to qualified; no new addressing or write machinery.
**Status**: Implemented 2026-10-25 — **insert half only**. `Limiter` is in the verified insert
allowlist and is refused on the legacy path; **no Limiter parameter is declared**, so the parameter
half (AC-3 … AC-6) stays refused until the Controls-view rows are measured.
**Depends On**: T2 for the master Strip. **Not** blocked for track strips — the insert and parameter
work below is strip-agnostic.

---

## 2.0 What was actually implemented — and what still refuses (2026-10-25)

| Draft item | State |
|---|---|
| `case "limiter"` in the insert spec, canonical name matched exactly so `Adaptive Limiter` cannot alias | **done** — `StockPluginCatalog` entry `limiter` with `write: .insertOnly`, menu path `Audio FX ▸ Dynamics ▸ Limiter` |
| canonical id `logic.stock.effect.limiter` + alias | **done** — `VerifiedPluginCatalog` |
| `limiterParameters` block beside `compressorParameters` | **not done, deliberately** — no Limiter Controls-view row has ever been measured, so declaring any parameter would be an invented value |
| promotion from `experimental` to qualified | **not done for parameters** — there is nothing to promote |
| legacy `insert_plugin` surface | **unchanged by design** — `legacyInsertPluginSpec` keeps Gain / Compressor / Channel EQ, so the legacy operation's contract does not silently widen |

Acceptance criteria covered: **AC-1** (State A only from the post-insert inventory readback — the
existing verified-insert tests exercise the same machinery for the new catalog entry), **AC-2**
(`Limiter` allowed, `Adaptive Limiter` not: `VerifiedPluginCatalogTests` asserts the alias table does
not absorb it), **AC-7** (the three original plugins still insert and still refuse everything else;
`StockPluginCatalogTests` asserts `Limiter` is insertable through the verified surface and `nil` on
the legacy one).

**Not covered:** AC-3, AC-4, AC-5, AC-6 — every one of them is about declared parameters, and none
exists yet. A `set_param_verified` / `get_param_verified` request naming the Limiter is refused as an
unsupported parameter, which is AC-4's behaviour reached from the other side: the catalog never
started accepting a parameter the measurement had not round-tripped.

---

## 1. The measurement this ticket rests on — and what is missing

**Measured, and carried by the code as such:**

`Plugins/StockPluginCatalog.swift:1310-1400` records the Compressor's Controls-view boundary: an
`AXSlider` identified by `AXDescription="Threshold"` with `AXValue` normalized 0…100, written with
`set AXValue` and read back, plus two `AXCheckBox` rows (`Limiter On`, `Auto Release`) pressed and
read back on 2026-09-02. That is the *method* this ticket reuses. It is not a Limiter reading.

`CapabilityRegistry.swift:35-51` already declares three Limiter parameters:

```swift
candidate(limiter, "gain",          "Gain",           .decibels,    0 ... 24, 0.1),
candidate(limiter, "outputCeiling", "Output Ceiling", .decibels,  -24 ... 0, 0.1),
candidate(limiter, "release",       "Release",        .milliseconds, 10 ... 1_000, 1),
```

but `candidate(...)` (`:56-76`) hard-codes `selectorSignatures: []`, `qualificationEvidence: []`,
`status: .experimental`. **The ranges above have no recorded measurement** — they are declarations
with nothing behind them, which is exactly why the entry is experimental.

`StockPluginCatalog.swift:1512` declares the plugin as insert-only:

```swift
fx("limiter", "Limiter", "Dynamics"),
```

**What is NOT measured, and gates the parameter half of this ticket:**

> **Nobody has read the Limiter's Controls view**: its row labels, which rows are `AXSlider` vs
> `AXCheckBox` vs popup, the `AXValue` range of each slider, the `AXValueDescription` unit spelling,
> and whether a given value round-trips.

**Step 0** — on Logic Pro 12.3, en interface, with `Scripts/livekit/` against a fixture with one
Limiter inserted on an audio track (not the master strip, so T2 is not a prerequisite for the
measurement):

1. For each row in the Limiter's Controls view: record the row's `AXStaticText` label, the control's
   `AXRole`, `AXDescription`, `AXValue`, `AXValueDescription`, and `AXMinValue`/`AXMaxValue` when present.
2. For each candidate parameter, perform one write/readback round trip and record the observed
   transition and the readback.
3. Record which rows refuse (popup-only, or a slider whose value does not move).

**The measurement decides the parameter list.** Only parameters with an observed round trip become
`availabilityState: .verified`. A row that reads but does not round-trip stays out of the writable
set and the ticket records why — the Channel EQ Low Cut/High Cut note at `:1494-1498` is the model.
If **no** Limiter parameter round-trips, the parameter half ends in a refusal and only the insert
half ships, with the catalog entry remaining `.insertOnly` and the capability candidates remaining
`.experimental`.

## 2. The change

### 2.1 The insert allowlist

`Channels/AccessibilityChannel+Plugins.swift:25-49`, `pluginInsertSpec(named:)` — **before**, the
switch ends:

```swift
case "channel eq", "channeleq":
    return PluginInsertSpec(
        canonicalName: "Channel EQ",
        aliases: ["Channel EQ"],
        menuPaths: insertPaths([["Channel EQ"], ["EQ", "Channel EQ"]])
    )
default:
    return nil
```

**after**, one case is added:

```swift
case "limiter":
    return PluginInsertSpec(
        canonicalName: "Limiter",
        aliases: ["Limiter"],
        menuPaths: insertPaths([["Dynamics", "Limiter"]])
    )
```

`insertPaths(...)` (`:15-24`) already expands each base path with the stereo/mono format labels, so
the new case needs nothing else. The canonical name `Limiter` must match the menu leaf exactly —
`Adaptive Limiter` (`StockPluginCatalog.swift:1506`) is a **different plugin** and must not match:
`pluginInsertSpec` lowercases and switches on an exact string, so no substring risk exists, and this
ticket adds no prefix matching.

### 2.2 The alias table

`Plugins/VerifiedPluginCatalog.swift:35-46` — add, keeping alphabetical grouping:

```swift
"limiter": "logic.stock.effect.limiter",
"logic.stock.effect.limiter": "logic.stock.effect.limiter",
```

Without this, `set_param_verified` refuses the plugin before it reaches the catalog.

`paramAliases` (`:48+`) gains one entry, **only for the parameters step 0 verified**. For example, if
`outputCeiling` verifies as a dB slider:

```swift
"logic.stock.effect.limiter": [
    "output_ceiling": "outputCeiling",
    "outputCeiling": "outputCeiling",
],
```

The public key is snake_case with an explicit unit where the unit is ambiguous; the catalog id keeps
the existing camelCase spelling already used by `CapabilityRegistry.swift:50`.

### 2.3 The catalog parameter block

`Plugins/StockPluginCatalog.swift:1512`. **Before:**

```swift
fx("limiter", "Limiter", "Dynamics"),
```

**After** (shape; the exact ids, units and methods are what step 0 supplies):

```swift
fx("limiter", "Limiter", "Dynamics", write: .parameterWriteReadback, parameters: limiterParameters,
   notes: ["Insert verified through the Dynamics > Limiter menu path. <N> of <M> Controls-view parameters carry a measured write/readback round trip on <date>; <the rest, and why>."]),
```

`limiterParameters` is a new `private static let` beside `compressorParameters` (`:1306`), with one
`StockPluginParameterMetadata` per verified parameter, `availabilityState: .verified`, and the same
`StockPluginProvenance` shape the Compressor's verified rows use — `source: "release_binary_live_drive"`,
`method: "logic_plugins.set_param_verified.<write method>"`, `observedAt`, `locale`, and the
`evidence` array carrying the operation and the observed transition strings. A parameter with no
round trip must **not** be declared here at all; declaring it `.inferred` would put it back in the
surface the ticket is trying to keep honest.

### 2.4 Capability registry promotion

`PluginCapability/CapabilityRegistry.swift:49-51` — the three candidates move from the
`candidate(...)` convenience (which hard-codes `experimental`) to explicit
`VerifiedParameterCapability` constructions carrying:

- `selectorSignatures`: the measured `AXRole` + `AXDescription` pair per parameter,
- `qualificationEvidence`: the step-0 evidence strings (date, locale, operation, observed transition),
- `status: .qualified` for verified parameters; delete the candidates for parameters step 0 could not
  round-trip.

**The allowed ranges must be replaced with the measured ranges**, not kept. A declared `0 … 24` beside
a measured `0 … 100` percent model is the same defect the Compressor's threshold note at `:1300-1305`
exists to prevent: the caller would pass dB into a normalized control and the write would either fail
or land at the wrong value.

**Judgement made here:** a parameter whose measured model is normalized (like Compressor `threshold`)
is exposed with `valueType: .normalized` and a public note saying so — **not** converted to dB by this
server. Inventing a dB↔percent mapping is the failure mode the Channel EQ ticket already ruled out:
`Dispatchers/PluginsDispatcher.swift:87` states "no Hz-to-raw mapping is used".

### 2.5 Nothing else

`set_param_verified` (`PluginsDispatcher.swift:243-267`) resolves plugin → catalog → parameter and
dispatches to the measured write method. Once 2.1–2.3 exist, the operation reaches the Limiter with
**no dispatcher change**. If it does not, the gap is in the write-method dispatch (`HostParameters/`)
and that is where the implementer should look — not in a new code path.

## 3. Call sites the change reaches — enumerated

| # | Site | Kind |
|---|------|------|
| 1 | `Channels/AccessibilityChannel+Plugins.swift:25-49` | mechanical — one switch case |
| 2 | `Plugins/VerifiedPluginCatalog.swift:35-46` | needs a value — the `logic.stock.effect.limiter` id |
| 3 | `Plugins/VerifiedPluginCatalog.swift:48+` (`paramAliases`) | **measured**, per parameter |
| 4 | `Plugins/StockPluginCatalog.swift:1512` | needs values — the parameter block |
| 5 | `Plugins/StockPluginCatalog.swift:1306` (neighbour) | mechanical — new static block |
| 6 | `PluginCapability/CapabilityRegistry.swift:49-51` | cannot be resolved mechanically — §2.4 |
| 7 | `Dispatchers/PluginsDispatcher.swift:87` (description) | mechanical — add Limiter, and the unit caveat if any parameter is normalized |
| 8 | `Dispatchers/SystemDispatcher.swift:2365` (tool summary) | mechanical |
| 9 | `Channels/AccessibilityChannel+VerifiedPlugins.swift:25-49` (doc comment listing the verified surface) | mechanical — keep the header honest |
| 10 | `docs/COMMAND-PARAMETERS.md` (plugin parameter section) | mechanical |

**Deliberately unchanged:** `Dispatchers/MixerDispatcher.swift:615-618` — the legacy
`logic_mixer.insert_plugin` allowlist. It is a different, unverified surface and widening it would
create a second path to the same plugin with a weaker contract.

## 4. Acceptance criteria that can fail

- [ ] **AC-1** `insert_verified { track, insert, plugin: "limiter" }` returns State A **only when** the
      post-insert inventory observes a plugin whose observed name is `Limiter` at that slot. A test
      that returns State A from the popup click alone goes red.
- [ ] **AC-2** `insert_verified { plugin: "adaptive_limiter" }` is refused (not in the allowlist) and
      the refusal names the three-plus-one allowed plugins. Checked by a test asserting the refusal
      string contains `Limiter` and does not accept the request.
- [ ] **AC-3** For every parameter the catalog declares `.verified`, `set_param_verified` writes and
      reads back within tolerance, State A, and the value observed after the write differs from the
      value before it. A parameter declared `.verified` without a live round trip fails this AC.
- [ ] **AC-4** A parameter the measurement could not round-trip is **absent** from the catalog entry
      and `set_param_verified` on it is refused as unsupported. Checked by naming one such parameter
      in a test — the test fails if the entry started accepting it.
- [ ] **AC-5** `get_param_verified` on a verified Limiter parameter returns the catalog unit and the
      verbatim `observed_display`, not an inferred conversion — asserted against a fixture value whose
      display string contains the unit.
- [ ] **AC-6** `CapabilityRegistry` reports no Limiter capability with `status: .experimental` after
      the change; each surviving candidate has non-empty `selectorSignatures` and
      `qualificationEvidence`. Asserted by iterating the registry, not by reading the source.
- [ ] **AC-7** The three previously allowlisted plugins still insert and still refuse everything else —
      the existing allowlist tests pass unmodified.

## 5. Mutations that must turn a test RED

1. Remove the `case "limiter"` from `pluginInsertSpec` → AC-1 and AC-2 both go red.
2. Add `"limiter"` to `pluginAliases` but not `pluginInsertSpec` → AC-1 red (insert refuses), AC-7
   green — proving the two allowlists are tested separately.
3. Leave `status: .experimental` on a verified Limiter parameter → AC-6 red.
4. Declare a parameter `.verified` without a round-trip measurement in the fixture → AC-3 red.
5. Keep the declared `0 ... 24` range beside a measured normalized control → AC-3 red (the write
   lands out of range or reads back wrong).
6. Make `pluginInsertSpec` match `"adaptive limiter"` through the `limiter` case (e.g. with
   `contains`) → AC-2 red.

## 6. Explicitly NOT in scope

- **Adaptive Limiter**, Multipressor, DeEsser 2, and every other Dynamics plugin. The catalog keeps
  them insert-only or absent.
- Preset/setting application.
- Auto-release / true-peak / lookahead modelled as *derived* values. If a row is a checkbox it is
  written as a boolean; if it is a slider it is written in its own units. No parameter is computed
  from another.
- Measured **latency** compensation or how the Limiter's lookahead affects stem alignment.
- Any claim that a Limiter on the master strip processes the bounce. T2 §7 already says this is not
  established; this ticket does not change that.
- The legacy `logic_mixer.insert_plugin` path.

## 7. What this ticket does NOT establish

- That inserting and configuring a Limiter makes a master sound louder, cleaner, or "radio ready".
  The ticket establishes the control was inserted and the value round-tripped. It says nothing about
  the audio result, and the server has no instrument that measures it.
- That the Limiter's Controls view in another locale exposes the same row labels. The `AXDescription`
  values are English literals in `StockPluginCatalog`; whether Logic localizes plugin control
  descriptions was not measured here. If it does, a localized Logic fails the write rather than
  writing the wrong row — but the failure is a refusal, not support.
- That the Limiter ships in the same Dynamics submenu position on variants other than the one
  measured. Creator Studio is recognised-not-supported (`README` "At a Glance") and is out of scope.
- That any Limiter parameter is safe to write while audio is playing.
