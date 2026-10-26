# T4: Read the Bounce dialog's settings and refuse a normalized render

**Role served**: Mastering engineer — the mastered deliverable is the bounce, and a bounce whose
Normalize/dither/bit-depth settings were never read is an unverified artifact no matter how good the
audio analysis is.
**Priority**: P0
**Size**: M — one JXA walk extension, one new pairing function, four Swift plumbing sites, and a new
refusal boundary; the dialog driving and the helper's coordinate strategy are untouched.
**Status**: Implemented 2026-10-25 with one deliberate deviation (§2.3): a Normalize read as
positively `on` refuses the render; an unclassifiable reading proceeds and is reported as
`unknown`. The dialog's own rows remain unmeasured on a live Logic — step 0 has not been taken —
which is exactly why `unknown` does not refuse.
**Depends On**: Nothing.

---

## 2.0 Acceptance criteria as implemented (2026-10-25)

| AC | State |
|---|---|
| AC-1 readback returns label → value for popups and checkboxes | **implemented, not yet checked against a live dialog or a committed fixture** — the pairing function is unit-tested on synthetic snapshots only; no step-0 dump exists |
| AC-2 `bounceSettings` + `bounceSettingsReadStatus == "ok"` on a bounce artifact | **done** — both travel on every bounce artifact, success or failure path |
| AC-3 Normalize `on` → refusal, no file, dialog dismissed | **done in the helper** (`bounce_normalize_enabled`, `bounce_fired: false`, cancel before exit); the Swift executor maps a helper failure to State C with no artifact path |
| AC-4 unreadable snapshot → refusal | **not implemented, and deliberately** — see §2.3. An unreadable snapshot yields `bounceSettingsReadStatus == "unreadable"` and the bounce still runs |
| AC-5 existing snapshot consumers unchanged | **done** — the walk only adds a bucket; `save_panel_present` and `bounce_settings_present` keep their inputs |
| AC-6 the happy path stays State A | **done** — nothing in the settings path touches the analysis verdict |
| AC-7 an older helper with no `bounce_settings` key | **done** — decodes to `nil`, reported as `unreadable`, not as "no settings" |

---

## 1. The measurement this ticket rests on — and what is missing

**Measured**: the Bounce settings dialog is reachable and its presence is detectable.
`Scripts/logic_bounce_ui.py:437-455` (`bounce_settings_present`) confirms the dialog by finding a
confirm button, a cancel button, no text field, and at least one of the marker strings in
`BOUNCE_SETTINGS_MARKERS` (`Scripts/logic_ui_labels.py:24`: `realtime`, `offline`, `normalize`,
`pcm`, `audio tail`, in ten languages). `Scripts/logic_bounce.py:193-201` then **clicks OK without
reading any control's value**:

```python
if not click_bounce_settings_confirm():
    result["success"] = False
    result["error"] = "bounce_confirm_button_not_found"
    print(json.dumps(result)); return 1
```

`ProjectExportBounceHelper.swift:5-50` parses the helper's JSON into
`ProjectExportBounceHelperResult` (`ProjectExportExecutorBounceHelperResolution.swift:4-8`), which
carries exactly `artifactPath`, `error`, `bounceFired`. The settings are never in the payload even if
the helper had read them.

`ProjectExportExecutorArtifactFlow.swift:126-175`: the bounce branch produces the file, runs
`options.analyze`, and on `pass` returns **State A** with `ArtifactEvidence(from: analysis, source:
"audio_analyzer")`. State A therefore means "a file of this shape exists and analyzes" — it says
nothing about whether the render was normalized, dithered, or bounced at a different bit depth than
the caller believes. For every other export in this server, the parameters are in the request; here
they are in a dialog nobody read.

**What is NOT measured:** the dialog's AX structure per control — role, label, and the *values*.

`save_panel_snapshot_source()` (`Scripts/logic_ui_jxa.py:36-90`) walks the front window to depth 6
and buckets only `AXButton` names, `AXTextField` names, and `AXStaticText`. It does **not** read
`AXPopUpButton` or `AXCheckBox` values, so a popup reading `24-bit` or a checkbox reading `1` is
invisible to it. `BOUNCE_SETTINGS_MARKERS` proves strings are present; it cannot say which control
holds which value.

**Step 0** — on Logic Pro 12.3, en interface, with the Bounce dialog open (⇧⌘B), via
`Scripts/livekit/`:

1. Dump every descendant of the front window with role, name, value, `AXDescription`, and depth.
2. Record which controls are popups and which are checkboxes, and each one's label (the row's
   `AXStaticText`, not the control's own `AXTitle` — the Compressor measurement
   `StockPluginCatalog.swift:1344` found the same split and the same solution).
3. Record the popup value spellings for format (`PCM`/`MP3`), bit depth, sample rate, and dither.
4. Record the Normalize control's three states and their observed spellings, and the
   realtime/offline control.

**If step 0 shows the controls are not individually readable** — e.g. the sheet exposes only one
opaque group — then this ticket ends in a refusal that says so, with the dump. It does **not**
substitute marker-presence for a value read: "the string `normalize` is somewhere in this dialog" is
exactly the absence-of-evidence the honest contract forbids reporting as evidence.

## 2. The change

### 2.1 Read the values in the JXA walk

`Scripts/logic_ui_jxa.py:36-90` — **before**, `walk` buckets three roles:

```javascript
if (role === "AXButton" && name) bucket.button_names.push(name);
if (role === "AXTextField") {
  if (name) bucket.text_field_names.push(name);
  bucket.text_field_count += 1;
}
if (role === "AXStaticText" && (name || value)) {
  bucket.static_texts.push(name || value);
}
```

**after** — two more buckets, each holding name *and* value, plus depth so a pairing function can
use order:

```javascript
if (role === "AXButton" && name) bucket.button_names.push(name);
if (role === "AXTextField") {
  if (name) bucket.text_field_names.push(name);
  bucket.text_field_count += 1;
}
if (role === "AXStaticText" && (name || value)) {
  bucket.static_texts.push(name || value);
}
if (role === "AXPopUpButton") {
  bucket.popup_buttons.push({name: name, value: value, depth: depth});
}
if (role === "AXCheckBox") {
  bucket.checkboxes.push({name: name, value: value, depth: depth});
}
```

and initialise both arrays in the `bucket` literal at `:73-79`. The emitted JSON gains
`popup_buttons` and `checkboxes`; nothing existing changes shape, so every current consumer
(`save_panel_present`, `bounce_settings_present`) keeps working — that is an AC, not an assumption.

The `safe(() => node.value(), "")` call is already made inside `walk` (`:32`), so no new AX
permission path is introduced.

### 2.2 Pair controls with their row labels

New function in `Scripts/logic_bounce_ui.py`, beside `bounce_settings_present` (`:437`):

```python
def bounce_settings_readback(run_jxa_fn: RunJxa = run_jxa) -> dict[str, str]:
    """label -> observed value for every popup and checkbox in the Bounce dialog.

    A control's label is the nearest preceding AXStaticText at the same or shallower
    depth in document order — the same row/label split measured for the Compressor's
    Controls view. A control with no preceding label is keyed by its own name; a
    control with neither is dropped and the caller sees a missing key rather than an
    invented one.
    """
```

The function is pure over the snapshot; it takes the same `run_jxa_fn` seam the neighbouring
functions take, so it is unit-testable against a recorded JSON payload with no Logic running. The
fixture for that test is **the step-0 dump, committed as a fixture**.

It returns `{}` on any snapshot error and the caller distinguishes "empty" from "unreadable" (below).

### 2.3 Report it from the helper

`Scripts/logic_bounce.py:185-201` — **before**, read nothing:

```python
dialog_up, dialog_open_strategies = open_bounce_dialog()
result["dialog_open_strategies"] = dialog_open_strategies
…
if not click_bounce_settings_confirm():
```

**after**:

```python
dialog_up, dialog_open_strategies = open_bounce_dialog()
result["dialog_open_strategies"] = dialog_open_strategies
…
settings = bounce_settings_readback()
if not settings:
    result["success"] = False
    result["error"] = "bounce_settings_unreadable"
    result["bounce_fired"] = False
    _cancel_bounce_settings()
    print(json.dumps(result)); return 1
result["bounce_settings"] = settings
normalize = normalize_state(settings)          # pure, unit-tested against the fixture
if normalize == "on":
    result["success"] = False
    result["error"] = "bounce_normalize_enabled"
    result["bounce_fired"] = False
    _cancel_bounce_settings()
    print(json.dumps(result)); return 1
if not click_bounce_settings_confirm():
```

`_cancel_bounce_settings()` presses the dialog's cancel button using `SAVE_PANEL_CANCEL_BUTTONS`
(`Scripts/logic_ui_labels.py:31`), through the same `_process_body` seam `click_bounce_settings_confirm`
uses. **The dialog must be dismissed and no file written** — a refusal that leaves Logic with a modal
sheet open is not a refusal, it is a hang.

`normalize_state` reads the value of the control whose label matches the normalize markers, and
returns `on` / `off` / `overload_protection_only` / `unknown`.

**Implemented 2026-10-25 — deliberate deviation from this draft.** The draft said `unknown` is
treated exactly like `on`. It is not. `unknown` **proceeds** and reports
`bounce_normalize: "unknown"`; only a positive `on` cancels the dialog and refuses.

Why: the dialog has never been measured on a live Logic, so on every machine today the pairing can
return nothing at all — no control rows, or rows whose labels do not match the markers. Refusing on
`unknown` would therefore refuse **every** bounce, including the track-level bounces this server
already produces, before the first measurement exists. That is not "fail closed on an unverified
setting"; it is "the only working bounce path stops working until someone measures a dialog."

What keeps it honest instead: `bounce_normalize` is reported on **every** bounce artifact
(`bounce_settings` + `bounce_settings_read_status`), so a caller never sees a silent success. A
consumer that requires a proven `off` must check the field and refuse `unknown` itself. Once step 0
measures the dialog, this deviation should be re-examined — the safe end state is `unknown` =
refuse, and it is only safe when `unknown` is the rare case.

### 2.4 Carry it through Swift

`Projects/ProjectExportExecutorBounceHelperResolution.swift:4-8` — **before**:

```swift
struct ProjectExportBounceHelperResult: Sendable, Equatable {
    let artifactPath: String?
    let error: String?
    let bounceFired: Bool
```

**after**:

```swift
struct ProjectExportBounceHelperResult: Sendable, Equatable {
    let artifactPath: String?
    let error: String?
    let bounceFired: Bool
    /// label -> observed value, verbatim from the dialog. nil when the helper did not
    /// report them (an older helper on disk, or a failure before the dialog opened).
    let settings: [String: String]?
```

`ProjectExportExecutorBounceHelper.swift:5-50` decodes `obj["bounce_settings"]` as
`[String: String]` and passes it to both `.success` and `.failure`. The two static constructors
(`:9-15`) gain a defaulted `settings: [String: String]? = nil` so every existing call site compiles
unchanged — then the one site that has them passes them.

`ProjectExportExecutorArtifactFlow.swift` `produce` — the bounce branch (`:126-154`) passes
`bounceResult.settings` into the `RunArtifact` it returns on every path, including the C path where
`bounceResult.artifactPath == nil`: **the settings were read even when the render failed**, and
throwing them away is the habit this ticket exists to break.

`Projects/ProjectExportExecutorModels.swift` — `RunArtifact` gains:

```swift
let bounceSettings: [String: String]?
let bounceSettingsReadStatus: String?   // "ok" | "unreadable"
```

`bounceSettingsReadStatus` is `"ok"` when `settings != nil`, `"unreadable"` when the artifact came
from the bounce helper and `settings == nil`. For non-bounce artifacts both are `nil`.

### 2.5 What the artifact State means now

- A bounce artifact whose audio analyzes `pass` and whose settings were read is **State A**, and its
  result carries the settings. State A now means "a file of this shape exists, analyzes, and the
  dialog settings that produced it were observed".
- A bounce artifact whose audio analyzes `pass` but whose settings could not be read stays **State
  A** — the file *was* produced and *was* analyzed, and downgrading it would be a lie in the other
  direction — **but** `bounceSettingsReadStatus: "unreadable"` and the run reports
  `bounce_settings_unreadable` at run level. A caller that requires settings before shipping checks
  the field. This is deliberately not a run failure: the helper refusing when it cannot read already
  covers the normal path (2.3), so this case is an older-helper or a crash-before-dialog case.
- Normalize-on is **never** State A: the helper returns before clicking, so no artifact exists.

## 3. Call sites the change reaches — enumerated

| # | Site | Kind |
|---|------|------|
| 1 | `Scripts/logic_ui_jxa.py:36-90` | mechanical — two buckets (§2.1) |
| 2 | `Scripts/logic_bounce_ui.py:437` (neighbour) | cannot be resolved mechanically — the pairing function is judgement (§2.2) |
| 3 | `Scripts/logic_bounce.py:185-201` | needs values — §2.3 |
| 4 | `Scripts/logic_ui_labels.py:24` (markers) | verify only — markers stay as the presence check they are; they do not become the value read |
| 5 | `Projects/ProjectExportExecutorBounceHelperResolution.swift:4-15` | mechanical + defaulted constructor |
| 6 | `Projects/ProjectExportExecutorBounceHelper.swift:5-50` | mechanical — decode one more key on every return path |
| 7 | `Projects/ProjectExportExecutorModels.swift` (`RunArtifact`) | mechanical field addition |
| 8 | `Projects/ProjectExportExecutorArtifactFlow.swift:126-175` | needs values — every return path passes the settings |
| 9 | `Projects/ProjectExportExecutorRunResults.swift:4-59` | verify only — the aggregate must not drop the two new fields; if it does, that is part of this ticket |
| 10 | `Scripts/install.sh` (installs `logic_ui_labels.py` beside the helpers) | verify only — no new module is added, so no install change; if step 0 makes a new module unavoidable, this site must be added |

`AccessibilityChannel+Project.swift:1367-1510` (`project.bounce`, `bounce_fired: false`) is **not**
touched: that operation's contract is "the dialog is open for a human", and it has no helper to read
settings from.

## 4. Acceptance criteria that can fail

- [ ] **AC-1** With the Bounce dialog open, `bounce_settings_readback()` returns a non-empty mapping
      containing a key for file format, one for bit depth, and one for normalize, each with the value
      Logic displays. Checked against the committed step-0 fixture and live.
- [ ] **AC-2** `export_run artifacts:["bounce"]` returns a result whose artifact carries
      `bounceSettings` with those keys, and `bounceSettingsReadStatus == "ok"`.
- [ ] **AC-3** With Normalize set to ON in the dialog, the run returns State C
      `bounce_normalize_enabled`, `bounce_fired: false`, **no new file in the destination**, and the
      Bounce dialog is closed afterwards. A test that leaves the sheet open fails.
- [ ] **AC-4** A snapshot whose popups/checkboxes cannot be read yields
      `bounce_settings_unreadable`, State C, and zero files — not a render with settings omitted.
      Checked in the helper's unit tests against a truncated snapshot.
- [ ] **AC-5** `save_panel_present` and `bounce_settings_present` return exactly what they returned
      before the walk change, on the same recorded snapshots. Asserted by running the existing tests
      unmodified.
- [ ] **AC-6** The artifact for a bounce with a `pass` analysis and readable settings is still State
      A — the new fields did not silently downgrade the happy path. Asserted by a test that fails if
      `bounceSettingsReadStatus` is anything but `"ok"` there.
- [ ] **AC-7** An older helper on disk that emits no `bounce_settings` key produces
      `bounceSettingsReadStatus == "unreadable"` and State A for a passing artifact, with the run-level
      note present.

## 5. Mutations that must turn a test RED

1. Drop the `AXPopUpButton` bucket from the JXA walk → AC-1 red.
2. Return `"off"` from `normalize_state` when the label is not found → AC-3 red (a normalize-on
   fixture would render).
3. Remove `_cancel_bounce_settings()` from the normalize refusal → AC-3 red (the sheet stays open).
4. Decode `bounce_settings` only on the `.success` path → AC-2 red (a failed render loses its
   settings) and the C-path assertion red.
5. Set `bounceSettingsReadStatus` to `"ok"` when `settings == nil` → AC-7 red.
6. Make the pairing function key controls by their own `AXTitle` → AC-1 red on the fixture, whose
   controls carry no title (the measured Compressor shape).

## 6. Explicitly NOT in scope

- **Setting** the bounce settings from the request. This ticket reads and refuses; it does not write.
  Writing them is a separate surface decision (`bounce_format`, `bounce_bit_depth`, `bounce_dither`,
  `bounce_normalize`) with its own parameter contract, and doing it here would let a "readback" ticket
  quietly become a "render configuration" ticket.
- Normalization/dither on the **stem export panel** (`ProjectStemExportPanelDriver`). Different
  panel, different controls, different ticket.
- `project.bounce` (dialog-only) gaining a settings readback.
- The helper's coordinate strategy (save-panel frame read, staging favourite click,
  `Scripts/logic_bounce.py:210-272`). It is the least verified part of the helper and is explicitly
  left as it is.
- Loudness measurement of the resulting bounce (LUFS/true peak). `logic_audio.analyze_file` measures
  peak/RMS/bands; a loudness target check is a different instrument.
- Any claim that a non-normalized bounce is the "correct" master. The ticket makes the setting
  visible and refuses the one case that silently changes the deliverable's level.

## 7. What this ticket does NOT establish

- That the settings read from the dialog are the settings Logic **applied**. The reading is taken
  immediately before the OK press; the ticket does not re-read after, because the dialog is gone. A
  value that Logic rewrites on OK (e.g. an incompatible bit depth for a chosen format) would be
  reported as what was displayed, not as what was used. Step 0 should record whether any control
  changes on OK; if it does, the ticket gains a post-render cross-check (file header via the
  analyzer) and that addition must be recorded here.
- That reading the dialog covers sample rate. The analyzer already reports sample rate from the file,
  and that is the authoritative reading; the dialog value is a display.
- That Normalize ON is always wrong. It is refused because a mastering render must not change level
  without the caller saying so — not because normalization is bad.
- That the helper reads the dialog on a locale where the row labels could not be paired. A failed
  pairing returns missing keys and `normalize_state` returns `unknown`, which — as implemented —
  **does not refuse**; it is reported. Reading the dialog is therefore not established on any
  locale yet, including en-US, and no consumer may treat `bounce_normalize: "off"` as verified until
  a live measurement shows the pairing works.
