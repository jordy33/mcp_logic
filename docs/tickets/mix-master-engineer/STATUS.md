# Pipeline Status: Mixing Engineer / Mastering Engineer

**Scope**: the four P0 blockers between this server and an automated mixing-engineer +
mastering-engineer workflow. The roles, as this project reads them:

- **Mixing engineer** — takes the recorded tracks, balances their levels, cleans imperfections and
  applies effects so they coexist. Needs: one addressable audio file per recorded track, and verified
  writes to track-level gain/pan/EQ/compressor/sends.
- **Mastering engineer** — the final step; polishes and unifies the song's sound. Needs: verified
  writes to the master Stereo Output chain, a Limiter, and a bounce whose settings were observed.

This line of work covers **only** those two roles. Everything else this server does (composition,
MIDI editing, transport, arrange, region editing, session audit) stays available and is outside the
scope stated here and in the README.

**Current Phase**: all four implemented in unit-tested form; live acceptance open on T1's menu walk,
T2's output-strip round trip, T3's Limiter parameters and T4's dialog values
**Size**: 4 × P0

## Tickets

| Ticket | Title | Status | Review | Notes |
|--------|-------|--------|--------|-------|
| T1 | Bind an exported stem file to the track it came from | **Implemented** | — | `stem_scope:"per_track"` drives one export per subject with a proven-exclusive selection, so each produced file can reach State A; `all_tracks` keeps today's State B. The singular leaf is measured in en-US only, so other locales refuse |
| T2 | Address the master Stereo Output strip with the verified plugin surface | **Implemented (partial)** | — | `strip:"output"` on `get_inventory`/`insert_verified`/`set_param_verified`/`set_eq_band_verified`; parameter *reads* and a live round trip remain open (§4.0) |
| T3 | Insert a Limiter and write its parameters with verified readback | **Implemented (insert half)** | — | Limiter is insertable through the verified surface; no Limiter parameter is declared, so parameter writes stay refused until the Controls-view rows are measured |
| T4 | Read the Bounce dialog's settings and refuse a normalized render | **Implemented** | — | `bounce_settings` / `bounce_normalize` travel on every bounce artifact; `on` refuses the render; `unknown` proceeds and says so |

## Order

T1 and T4 are independent and can start immediately. T2 and T3 are independent of T1/T4, but T3's
mastering use depends on T2; **the Limiter's insert and parameter work can be measured and built on a
track strip while T2 is still open**, which is why step 0 of T3 does not require the master strip.

## Measurement log

| Date | What was established |
|------|----------------------|
| 2026-08-19 | Logic's File ▸ Export leaf title is rewritten by the selection (`Tracks as Audio Files…` → `1 Track as Audio File…`) — the basis for T1's selection-bound per-track export |
| 2026-09-02 | Compressor Controls-view checkbox press/readback measured — the method T3 reuses |
| 2026-09-14 | Channel EQ: 18 of 24 named parameters carry a measured write/readback round trip |
| 2026-10-25 | Static source review: which code paths block each role, enumerated in the four tickets |
| 2026-10-25 | Re-read `docs/tickets/issue-234/axdump234b.out`: the **Stereo Out** strip has an `audio plug-in` insert row; **Master** has none. This is the evidence T2 rests on, and it corrects an earlier claim in T2 that no dump had read the output strip |
| 2026-10-25 | T3 inserted: `Limiter` is in the verified insert allowlist (`Dynamics ▸ Limiter`), insert-only. The legacy `logic_mixer.insert_plugin` surface is explicitly kept at Gain/Compressor/Channel EQ by `legacyInsertPluginSpec` |
| 2026-10-25 | T1 implemented: `stem_scope` on the plan, a scope-aware leaf, and per-subject selection custody in the panel driver. The `1 Track as Audio File…` title is derived by Logic from the live selection and has no string-table row, so the label set carries no `derivedFrom` and no variants |
| 2026-10-25 | T4: the save-panel JXA walk now records `controls[]` in document order; `bounce_settings_readback` pairs each popup/checkbox with the nearest preceding static-text label. No live Logic run has yet shown what those rows actually are — the dialog's values remain unmeasured, which is why `unknown` does not refuse |

## Measurements these tickets still need

Each is step 0 of its ticket, and **each can end that ticket in a refusal**. They are listed together
because they share a shape: a capability was assumed from a menu string or a declaration, and no one
has read the control.

| Ticket | Measurement | If it fails |
|--------|-------------|-------------|
| T1 | ~~the singular per-track export leaf in en-US~~ — **taken** (2026-08-19). Still needed: the same leaf in every other locale the project claims, that one selection yields exactly one file, that the selection survives the panel opening, and the live menu walk that resolves the leaf | en-US only; every other locale refuses as an unmeasured per-track leaf, and a locale whose menu shows the all-tracks leaf to a per-track run refuses `stem_scope_leaf_mismatch` |
| T2 | ~~the master Stereo Output strip's insert chain through `audioPluginInsertSlots`~~ — **taken** (issue-234 dump, 2026-07-04). Still needed: the default strip name per locale, a multi-insert output strip through `screenOrderedInsertSlots`, whether the plug-in editor window is titled after the strip, and a live insert/parameter round trip | output-strip writes stay refused outside en-US and whenever the strip shape is not exactly the measured one |
| T3 | the Limiter's Controls-view rows: role, label, range, round trip | the parameter half refuses; insert-only ships if the menu path resolves |
| T4 | the Bounce dialog's popups and checkboxes, with values and row labels — **not taken**; the readback ships and reports `unknown` | the Normalize refusal only fires on a positive `on` read; `unknown` is reported, never treated as "settings were off" |

## What this pipeline deliberately does not do

- It does not decide the mix. Level, pan, EQ and compressor writes are exposed and verified; the
  judgement of what those values should be belongs to the calling engineer, and the mixing
  intelligence lives in the companion `mcp_sound_engineer` server, not here.
- It does not measure the audio result of a chain (loudness, true peak, phase). `logic_audio.analyze_file`
  reports peak/RMS/bands and file shape; a mastering-quality judgement is out of scope.
- It does not claim stem-to-bounce correspondence (a null test). T1 binds each stem to the export
  that produced it; nothing here proves the stem set sums to the mix.
