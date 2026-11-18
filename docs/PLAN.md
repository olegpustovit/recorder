# Recorder — Implementation Plan & Tracker

This file is **both the plan and the progress tracker**. `docs/SPEC.md` says *what* (mockups, behaviour, `AC-*`);
this file says *in what order, in which file, with what code, and how to prove it*.

**Free-editing roadmap (2026-11-15):** T-701…T-723 done (T-711 measured on Apple Silicon; Intel dropped
by the user). See [RESUME.md](RESUME.md).

## 0. Protocol (read every session)

User update (2026-10-16): visual deviations are accepted ("idc about deviations feel free to go"). Do not hold
release preparation for further visual sign-off. Continue functional/data-safety verification and disclose any
unmeasured hardware/performance checks; this is not evidence that those checks passed.

Latest permission evidence (2026-10-16): the downloaded, Developer ID signed v0.3.3 app, launched through
LaunchServices, reports `screen=true accessibility=true`. Earlier ad-hoc/build-241 denials below are historical,
not the current signed bundle's status. No grant was requested or reset. Prefer this signed bundle for remaining
live checks; obtain real capture evidence rather than assuming the old permission blocker still applies.

1. Find the first task below that is `- [ ]`. Do **only that task**. Never skip ahead, never batch tasks.
2. Read the SPEC sections the task lists. Read the files the task touches.
3. Implement exactly what "Do" says. Signatures in code blocks are **normative** (names, parameters, types); bodies are yours.
4. Run the task's **Verify** commands. Paste nothing, fake nothing: if a command fails, fix it or stop.
5. When Verify passes: change `- [ ]` to `- [x]`, append one line to §Log at the bottom
   (`T-xxx · date · what you verified · any deviation`), and commit: `git commit -am "T-xxx <title>"`.
6. `HUMAN:` lines need a person (permissions, looking at the screen). Do everything else, then stop and ask the user to
   perform the HUMAN step. Mark the task `- [~]` (blocked on human) until they confirm. Do not tick it yourself.
7. If the task is wrong or impossible: do not improvise an architecture. Write `BLOCKED: <why>` under the task, stop, ask.

8. **Two lanes (user decision, 2026-09-18).** Rule 1 applies per lane. *App lane*: this tree, `master`, strictly in order.
   *Core lane*: the pure-`RecorderCore` tasks T-401, T-402, T-403, T-410, T-411, T-412 run in order in the worktree
   `../recorder-core-lane` (branch `core-lane`) in parallel with the app lane. Core-lane agents never edit this file; the
   coordinator merges `core-lane` into `master`, runs `make test`, then ticks/logs here.

### Ponytail rules (apply to every task)

Before writing code, stop at the first rung that holds:
1. Is it in this task? If not, **don't build it** (no "while I'm here", no options for later).
2. Does it already exist in this repo? Reuse it (`SelectionRectView`, `Theme`, `model.edit`, `TimeMap`, `Spring`).
3. Does Foundation/AppKit/SwiftUI/AVFoundation already do it? Use that (`NSMenu`, `Form`, `Slider`, `FileManager.trashItem`, `CGImageDestination`…).
4. Can it be one line? One line.
5. Only then: the minimum code that works.

Hard limits: no third-party packages · no protocol with one conformer · no generic "manager/service/coordinator" layers ·
no new file when the task names the file · no comments that restate code · no extra settings/toggles.
A deliberate shortcut gets `// ponytail: <ceiling>, <upgrade path>`.
**Never lazy about:** permissions checks, atomic writes, not logging typed text, invariants in `TimelineOps`, the Verify step.
Tests: Core logic gets the tests the task lists — no more. App target gets none; it is verified with `--selftest` and HUMAN checks.

### Verification tools

- `make test FILTER=<name>` — Core unit tests (swift-testing; `import Testing`, never XCTest).
- `make app && build/Recorder.app/Contents/MacOS/Recorder --selftest <name> [args]` — headless app checks added by tasks below.
  Each selftest prints `SELFTEST <name> OK` and exits 0, or prints the reason and exits 1.
- `HUMAN:` visual checks reference a SPEC mockup; the human compares the running app against it.

### Status

| Milestone | Tasks | Done |
|---|---|---|
| M0 Foundations | T-001…T-006 | 6/6 |
| M1 Record | T-101…T-114 | 7/14 |
| M2 Record+ | T-201…T-208 (+T-207b) | 0/9 |
| M3 Editor shell | T-301…T-313 | 6/13 |
| M4 Timeline | T-401…T-418 | 7/18 |
| M5 Ship | T-501…T-509 | 2/9 |
| M6 Polish | T-601…T-610 | 4/10 |

Update the "Done" column whenever you tick a task.

---

## Editor roadmap — 2026-10-15

Proposal: https://claude.ai/artifact/5AM3Z6uVtk3nBi142picJA · SPEC §"Editor roadmap (October 2026)". Run in lanes
(worktree per lane, coordinator merges into `dev` and ticks here). Lanes: **K** T-619→T-622→T-623 · **E** T-620→T-621→T-624 ·
**V** T-625→T-626→T-631→T-632 · **T** T-628→T-629→T-630 · **W** T-633→T-634→T-635.

| Scope | Tasks | Done |
|---|---|---|
| P0 bugs | T-619…T-624 | 6/6 |
| P1 voice | T-625…T-626 | 2/2 |
| P2 text | T-628…T-630 | 3/3 |
| P3 visuals | T-631…T-632 | 2/2 |
| P4 windows | T-633…T-635 | 3/3 |

- [x] **T-619 Zoom spring steps in output time**
  - Do: `CameraPath.init` gains `clips: [Clip]`; each step uses `dt / k`, `k` = `timeScale` of the clip covering source t (1 outside clips). `EditorModel.buildPaths` passes `project.clips`; FrameState's motion-blur previous sample uses `sourceTime - k/60`. Rebuild paths when clip speeds change.
  - Verify: new test `zoomTransitionSpeedIndependent` (same manual zoom on a 1× and a 2× clip match at equal output times within 1e-3); `make test`; `--selftest parity` maxDelta=0.
- [x] **T-620 Escape chain; no stale drag selection**
  - Do: `PreviewView` handles Esc while a zoom target or mask rect is shown (cancel open gesture, else end region editing, keep selection; never `super`). `EditorWindowController.keyDown` stops forwarding keyCode 53 to the timeline. `TimelineView` clears `dragSelection`/marquee state on mouseUp.
  - Verify: `zoom-target` selftest extended: select zoom, edit target, Esc → selection still that zoom, project unchanged; Esc mid-drag reverts; `highlight-manipulation`, `crop` still OK.
- [x] **T-621 Selection survives undo/redo**
  - Do: `EditorModel.undo/redo` keep selection ids that still exist (SPEC §7.2); `undo()` clears `gestureSnapshot`.
  - Verify: `menu-actions` extended: select a zoom, edit, ⌘Z → zoom still selected; deleted-block undo/redo leaves no dangling id.
- [x] **T-622 Capture every key**
  - Do: delete `recordAllKeys` setting + Settings row; `EventRecorder` records every keyDown and modifier-only flagsChanged (no `.typing` from flagsChanged), drops events while paused (lock-protected `pausedSoFar`), skips auto-repeat, stores the typed character (`UCKeyTranslate`) in the key event (optional field, Codable default nil).
  - Verify: `make test FILTER=events` (decode old events w/o char); `make app`; `open -n … --selftest events 3` via LaunchServices.
- [x] **T-623 Key display categories and merged chips**
  - Do: Core `keyCategory(keyCode:mods:) -> KeyCategory` (`.shortcut .typing .navigation .modifier`); `Keys` gets `shortcuts/typing/navigation/modifiers: Bool` (default true; legacy `allKeys=false` → typing false); `KeyChips` returns keys within `hold` joined into one label, labels prefer the stored character; FrameState uses `mediaTime` for keys and `Layout` uses `< end`. KeysTab replaces "Include all recorded keys" with four toggles.
  - Verify: `make test FILTER=keyChips` (categories, merged label, legacy decode); `parity` on `make-m6-fixture`; `inspector-panels`.
- [x] **T-624 Editing papercuts**
  - Do: zoom target keeps keyboard focus like masks (arrow nudge); arrow-repeat nudges coalesce into one gesture; BackgroundTab ColorPickers use begin/commitGesture; PreviewView hit-tests the selected zoom/mask rect before the camera bubble; ↑/↓ jump to previous/next edit point; frame step = 1/project fps; ⌘D duplicates every selected block.
  - Verify: `zoom-target`, `highlight-manipulation`, `timeline-ops`, `inspector-panels`, `menu-actions` OK (extend where a check is missing).
- [x] **T-625 Silent ranges and Split at Pauses (Core)**
  - Do: `silentRanges(levels:perSecond:threshold:minDuration:pad:) -> [TimeRange]` beside `typingRanges`; `Project.splitAtPauses(_:)` beside `speedUpTyping` (splits only, invariants checked).
  - Verify: `make test FILTER=silentRanges`, `FILTER=splitAtPauses`.
- [x] **T-626 Voice waveform lane + Split at Pauses command**
  - Do: Video lane 48 pt when `source.hasMic`; sqrt-scaled 2/1 px bars; hatch silent spans (same `silentRanges` over `Waveform.peaks`); *Edit ▸ Split at Pauses* + Sound tab button, one undo step.
  - Verify: `timeline-png` inspected; `menu-actions` extended (one undo restores); `waveform` OK.
- [x] **T-628 TextBlock model + Text lane**
  - Do: `TextBlock` (id, start, end, text, words: [Word]?, style caption/title/label, position NormPoint, size) and `Project.texts` (decodeIfPresent ?? []), conformed to the private `TimedBlock` engine + linked edits; Text lane (clay `#EFDCCF` in Theme), drag-to-create, `T` adds at playhead, inspector TextPanel scaffold (text field, style segment, size, 3×3 position, Remove), pinned "Add text at playhead".
  - Verify: `make test FILTER=linkedTracks` (texts follow split/delete/move); `timeline-ops`; `inspector-panels`.
- [x] **T-629 Text render pass**
  - Do: FrameState `texts` (active blocks, current word index); Compositor pass 6 reusing the chip texture path; three styles per SPEC; 9:16 safe area.
  - Verify: `parity` maxDelta=0 on a fixture with all three styles (`make-text-fixture` selftest); `editor-png` inspected.
- [x] **T-630 Generate Captions**
  - Do: Core `captionPhrases(words:maxWords:gap:) -> [TextBlock]`; app `Editor/Transcriber.swift` (SFSpeechRecognizer on-device only, authorization check; SpeechTranscriber on macOS 26 if available); Sound tab button; replaces caption-style blocks only, one undo step; editing text re-spreads word timings.
  - Verify: `make test FILTER=captionPhrases`; `make app`; `--selftest captions <say-generated m4a>` via LaunchServices (HUMAN if Speech permission not granted).
- [x] **T-631 Backgrounds**
  - Do: image backdrop texture (aspect fill + blur) in Compositor; gradient angle slider; 8 gradient + 8 color presets (static arrays in BackgroundTab); 4–6 new generated wallpapers (`scripts/render-brand-assets.swift`, appended to Resources/Wallpapers).
  - Verify: `parity` with an image background; `export-colors`; `inspector-panels`; PNG inspected.
- [x] **T-632 Highlight helpers**
  - Do: ZoomPanel "Highlight this zoom"; `SelectionRectView` snap guides (frame edges/centres + other rects, 6 px, ⌘ bypass); mask context menu (kind, Duplicate).
  - Verify: `mask-overlay`, `zoom-target`, `highlight-manipulation` extended with a snap case.
- [x] **T-633 Multi-window capture**
  - Do: `CaptureTarget.windows([SCWindow])`; picker ⌘-click multi-select (≤ 4); one `SCStream` per window (`screen.mov` = window 0, `window-N.mov`), shared t0; EventRecorder polls every window frame at 10 Hz and stores `windowFrames` samples + global mouse points in events.
  - Verify: `pickers`; `record-perf` with 3 windows via LaunchServices; `--selftest record-windows 3` produces N decodable files on one clock.
- [x] **T-634 Window shots model + lane**
  - Do: `Project.windowShots` (source-time blocks, window index), generic block engine; Core `autoWindowShots(events:windowCount:minShot:)` (clicked window, ≥1.5 s); Window lane.
  - Verify: `make test FILTER=windowShots`; `timeline-ops`.
- [x] **T-635 Window composition + cursor remap**
  - Do: FrameSource one video track per window; FrameState picks the visible window and aspect-fits it; cursor normalised against that window's frame at t (hidden outside); crop disabled when multi-window.
  - Verify: `parity` maxDelta=0 on a 2-window fixture (`make-windows-fixture`); `export` OK.

---

## Audio & layers roadmap — 2026-10-16

Design + full Do/Verify per task: `docs/AUDIO-LAYERS.md` (decided 2026-10-16; read §1–§5 before any task, then the task's
§6 entry). Prototype: https://claude.ai/artifact/J2AhVTkaGo2CcbUfViHFFH. SPEC §"Audio lanes and layers (October 2026)".
Lanes: **A** T-640→T-645 · **L** T-646→T-649 (after T-640 merges; T-648 needs T-643) · T-650 last.

| Scope | Tasks | Done |
|---|---|---|
| Core model + links | T-640…T-642 | 3/3 |
| Audio lanes + voiceover | T-643…T-645 | 2/3 |
| Media layers + import | T-646…T-649 | 4/4 |
| Docs | T-650 | 1/1 |

- [x] **T-640 Audio/layer model + legacy derivation (Core)** — AUDIO-LAYERS §6
- [x] **T-641 Linked audio edits (Core)** — AUDIO-LAYERS §6
- [x] **T-642 Connected blocks settle (Core)** — AUDIO-LAYERS §6
- [x] **T-643 Composition + mix for N audio tracks** — AUDIO-LAYERS §6
- [x] **T-644 Audio lanes UI** — AUDIO-LAYERS §6
- [~] **T-645 Voiceover recording** — AUDIO-LAYERS §6
  - Machine implementation/checks complete; HUMAN AC-VO-2 pending: launch the app through LaunchServices, select Mic audio, press ⇧R, speak during the range, confirm countdown/live clip/auto-stop, original hatching, audible take and one ⌘Z restoring the original. `--selftest voiceover <m4a> --keep-fixture` leaves a disposable project for this check.
- [x] **T-646 Media import + layer lanes (Core + UI)** — AUDIO-LAYERS §6
- [x] **T-647 Image layer render pass** — AUDIO-LAYERS §6
- [x] **T-648 Video layer playback** — AUDIO-LAYERS §6
- [x] **T-649 Layer inspector + direct manipulation** — AUDIO-LAYERS §6
  - Verified on the v0.3.1 release source: layerEdits 5/5, inspector-panels, layer-rect and fixture parity (32 times,
    maxDelta=0). Native handles/resize/nudges/snapping/Escape/undo, context commands, immutable replacement and selected
    video playback pass. Inspected fresh Card + Dim and video result screenshots. User accepted visual deviations;
    the remaining prototype-comparison gate is waived, not represented as a human-performed comparison.
    Native artifacts: `/tmp/recorder-t649-editor-{selected,minimum,video,missing}.png` and
    `/tmp/recorder-t649-panel-{default,minimum,bottom,corner,missing}.png`; disposable package `/tmp/LayersFixture.recorder`.
- [x] **T-650 Docs + snapshot** — AUDIO-LAYERS §6
  - SPEC §5 documents immutable `voice/`/`media/`, additive version-3 audio/layer keys, legacy derivation and
    connected output timing. Snapshots include complete track/clip/layer metadata, missing-file flags, export
    duration and audio/layer inspector selection. Verified `snapshot` in debug/release, `make test` 129/129,
    `make app` release and strict bundle signature verification. T-645 real-microphone HUMAN checks remain pending.

---

## Requested voice editing — 2026-10-16

User request: transcript-aware mic editing, pause eraser, select-all auto zooms, calmer idle slots.

- [x] **T-651 Mic sliced at pauses + pause eraser (Core)**
  - `Project.splitAudioAtPauses(file:silent:fade:)` (audio only, 60 ms fades on the speech side), `erasePauses(file:silent:inOutput:)` (removes touched pauses, leaves gaps, video untouched).
  - Verify: `make test FILTER=pausesSliceAndEraseMicOnly`.
- [x] **T-652 Auto transcript + slicing on first open**
  - `EditorModel.prepareMic` (skipped under `--selftest`): slices mic.m4a at `Waveform.silent` (one undo step), transcribes on-device into `transcript.json`; Mic lane 50 pt with words drawn at their spoken x; AudioPanel shows the selected clip's transcript; Generate Captions reuses the transcript; Sound tab "Transcribe Again".
  - Verify: `make app`; `timeline-ops`, `menu-actions`, `inspector-panels`, `waveform` OK. HUMAN: open a fresh mic recording, grant Speech Recognition, confirm words and pause slices.
- [x] **T-653 Pause eraser tool, Zoom header double-click, idle slots on hover**
  - Toolbar eraser / `E`: drag across the timeline → `erasePauses` over the mic silent spans, one undo step; Esc/V exit. Double-click the Zoom track header selects every auto zoom (⌫ removes). Idle "Add image" slots draw only under the pointer.
  - Verify: `command-scissors`, `timeline-ops` OK. HUMAN: drag the eraser over a mic pause; double-click Zoom header → ⌫.

---

## Requested voice workflow — 2026-10-16 (evening)

User decisions: no mic pre-cuts on open (eraser cuts only where dragged) · eraser preset Tail + Fade · "+" adds lanes;
empty lanes (zoom, keys, layout, mask, text, window, camera without clips) are hidden, never clutter · fixed colour
swatches · multi-select shared settings for audio clips, colour + remove for any mixed selection (other kinds later).
Lanes run in worktrees `../recorder-voice-{e,t,c}` (branches `voice-*`), merged by the coordinator.

- [x] **T-654 Eraser Tail + Fade preset, no pre-cuts, transcription status** (lane e)
  - Core: `erasePauses(file:silent:inOutput:tail:fade:)` keeps `tail` s of the pause on each speech side (pauses shorter
    than 2×tail+0.05 s are left alone), fades the speech side by `fade`. `splitAudioAtPauses` keeps its signature.
  - App: `prepareMic` only transcribes (no slicing). Eraser toolbar button: right-click or long-press opens an NSPopover
    with `LabeledSlider`s Tail (0–500 ms, default 120) and Fade (0–300 ms, default 80), remembered in UserDefaults.
    While transcribing: Mic lane shows an indeterminate status ("Transcribing…" + spinner) where words will appear,
    and the header/AudioPanel/Sound tab show the same status; failures show the error text.
  - Verify: `make test FILTER=eraserTailFade` (+ `pausesSliceAndEraseMicOnly`); `command-scissors`, `timeline-ops`,
    `audio-mix-abutting` OK. HUMAN: drag the eraser over a pause with tail 200 ms — voice decays naturally.
- [x] **T-655 Lanes on demand: hide empty lanes, "+" menu, Move to New Track** (lane t)
  - Fixed lanes with no blocks are hidden unless revealed this session; lanes with content always show. A "+" button at
    the top of the track-header gutter opens an NSMenu: "Video Track" (reveals an empty `Layer N` lane on top; click it to choose media or drop a file on
    it; not saved until it holds a layer), "Audio Track" (appends `Audio N`, one undo) then each hidden
    lane type; choosing reveals that lane and scrolls it into view. Empty revealed lanes' header menu: "Hide Lane".
  - Core `moveAudioToNewTrack(_ ids:)` (new `Audio N` with the source track's volume/mute, one undo) via audio clip
    context menu "Move to New Track" (applies to the selection).
  - Verify: `make test FILTER=moveAudioToNewTrack`; all `timeline-*` selftests, `command-scissors`, `menu-actions`,
    `audio-lanes`, `media-import` OK (update fixtures that click a now-hidden empty lane by revealing it first).
- [x] **T-656 Clip colours + multi-select inspector** (lane c)
  - Core: optional colour tag (`red orange yellow green blue purple gray`) on every timeline block type and video clip;
    inherited by split/duplicate/paste; additive JSON key. Theme tokens for the 7 swatches (SPEC §3).
  - Timeline tints blocks by tag; context menu "Colour ▸" (swatch images + None) applies to the selection; inspector
    selection headers show the swatch row.
  - Multi-selection: all audio clips → shared Gain / Mute / Fade in / Fade out / Colour, mixed values shown as "Mixed",
    one undo per gesture; any other mix → count, Colour, Remove.
  - Verify: `make test FILTER=clipColor`; `inspector-panels`, `timeline-clipboard`, `timeline-ops` OK.

- [x] **T-657 Box selection + group move + Join Clips (⌘J)**
  - Dragging from empty timeline space boxes video clips *and* audio clips; dragging a selected audio clip moves every
    selected audio clip by the same delta (links ignored, stops at collisions), one undo. Core `joinClips(_:)` /
    `joinAudio(_:)` merge neighbours that continue the same media (undo a split); ⌘J (Edit ▸ Join Clips) and right-click
    "Join Clips"; a single selection joins its next neighbour.
  - Verify: `make test FILTER=joinClipsUndoesSplits`; `inspector-panels` (audio UI box → move → join → undo), timeline-*.
- [x] **T-658 Transcription on SpeechAnalyzer**
  - macOS 26+: `Transcriber.words` uses `SpeechAnalyzer` + `SpeechTranscriber` (`audioTimeRange` runs → `Word`s; the
    system installs the language model via `AssetInventory` on first use). macOS 15 keeps `SFSpeechRecognizer` on-device.
    Captions (word-highlight Caption style, T-629) consume the same words; no new layer.
  - Verify: `--selftest captions <mic.m4a>` on a 7 min take (ordered word timings to the end); `preview-frame` caption PNG.

## Requested clip cursor control — 2026-10-19

| Scope | Tasks | Done |
|---|---|---|
| Selected clip cursor visibility | T-659 | 1/1 |

- [x] **T-659 Hide cursor in the selected clip inspector**
  - Do: add a Hide cursor toggle below Playback speed in the selected Clip panel. Persist optional `Clip.hideCursor`
    (missing means visible), apply it at the shared preview/export frame-state boundary, and use the same edit from
    Edit ▸ Hide Cursor in Selected Clip. One undo step per toggle; no changes to other cuts or project cursor settings.
    Split/paste/move retain the flag; joins/restoration do not merge clips with different visibility. Existing global
    hide/idle/range behavior remains effective. Update SPEC and publish a clean signed/notarized patch release.
  - Verify: `make test`; `make app`; `--selftest clip-cursor`, `clip-fades`, `inspector-panels`, `menu-actions`,
    `timeline-ops`, `timeline-clipboard`, `timeline-selection`; preview/export parity on a mixed visible/hidden fixture;
    inspect 300/360-point Clip panel PNGs; verify the published universal DMG, signature, notarization, version and digest.
  - Released: [v0.4.1](https://github.com/olegpustovit/recorder/releases/tag/v0.4.1), source `88bf5af`.
    All listed local checks pass; clean CI and signed/notarized release runs pass. Public DMG digest, both
    architectures, version, strict signature, app/DMG tickets and Gatekeeper checks pass; its clip-cursor,
    menu-actions and mixed visible/hidden parity checks pass (maxDelta=0). Hardware gates remain as disclosed.


## Requested free editing (multi-track) — 2026-11-15

Proposal, audit and interactive prototype: https://artifacts.microapps.space/a/s3ft3gkc1k51 (the prototype is the
behavioural reference for every HUMAN step below). Video lane keeps today's flow; clips reorder, copy with ⌥, move as a
group, and lift onto free Video tracks with the same look.

**Decisions (locked 2026-11-15; change here, not in code):**
1. Lifted recording clips look exactly as on the Video lane (zoom, smoothed cursor, crop, frame) — not raw footage.
2. Dropping onto a magnetic Video lane **inserts** (later clips move right). No overwrite mode.
3. Copies own their effects (zooms/masks are duplicated, never shared).
4. The Video lane's **Magnet/Free** switch *is* `Project.rippleDelete` (one flag, no new key): Magnet = delete closes
   gaps + drag reorders; Free = delete leaves gaps + drag places at a time. The toolbar ripple button stays in sync.
5. `⌥` while dragging = **copy** (Finder/Final Cut). "Act on one clip, ignore links" moves to the link toggle (⌘L);
   `dragIgnoresLinks = event.modifierFlags.contains(.option)` in `TimelineView.mouseDown` goes away.
6. Lane order: `+ New track` drop row (always present) → Video N … Video 2 → Video → Camera/Zoom/… → audio.
7. Phases ship separately; phase 1 needs no file-format version bump (T-702b adds optional envelope metadata).

**Facts the plan relies on (verified in code 2026-11-15):** clips already separate the timeline clock
(`sourceStart/End`) from media (`mediaStart`, `clockSpeed`; `TimeMap.swift`); `useOutputClock()` rebases a project onto
output time (`TimelineOps.swift`); cursor, keys and camera-path events are sampled on the *media* clock per clip
(`makeFrameState`, `EditorModel.rebuildPathsIfNeeded`); the composition inserts each clip's `mediaIn`
(`FrameSource.swift`); `placeClip(moving:)` already carries zooms/layouts/masks/texts/keys/windowShots/camera and
linked audio with a clip via `editLinkedLayers`; `liftClip` and `deleteClips` already exist; `freeLayerTrack` already
pushes colliding layers up a track and caps video layer lanes at 4; the timeline already previews drags through
`dragProject`. So no clock rewrite is needed — reorder = permute clips, keep each clip's media, re-lay the clock.

### Phase 1 — Free editing on the Video lane (no version bump)

T-702b adds optional version-3 audio-envelope metadata to preserve sliced fades. Legacy projects need no migration;
older builds ignore those points and cannot preserve their phase. Recording layers still require version 4 in phase 2.

| Scope | Tasks | Done |
|---|---|---|
| Phase 1 | T-701, T-701b, T-702, T-702b, T-703…T-705, T-705b, T-705c | 9/9 |
| Phase 2 | T-711…T-714 | 4/4 |
| Phase 3 | T-721…T-723 | 3/3 |

- [x] **T-701 Core: media continuity instead of clock continuity**
  - Add `Clip.mediaEnd` (`mediaIn + mediaDuration`). Every "are these two clips continuous / what was cut here"
    decision must compare media, not clock: `mergeContiguousVideo` (already does both — keep), `joinClips` (already
    media-checked — keep), `restoreCut(afterClip:)` (the ripple-removed branch uses clock bounds `leftBound…rightBound`
    as footage — compute the removed footage as `clips[i].mediaEnd … clips[i+1].mediaIn` and refuse when that range is
    empty or negative, i.e. the neighbours aren't in recording order), `restoreAllCuts`, and the ✂ bubble placement in
    `TimelineView` (only where `a.mediaEnd < b.mediaIn` at equal speed).
  - Tests (`TimelineOpsTests`): `restoreCutUsesMedia` (cut, rebase clock via a move, restore → original footage);
    `noRestoreAcrossReorder` (reversed neighbours → restore is a no-op, invariants hold).
  - Verify: `make test FILTER=TimelineOps`.
  - Verified 2026-11-15: 18/18 targeted and 137/137 full Core tests. This machine now has Xcode/SDK 27.2;
    `make test` required `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` and a `TESTFLAGS` override
    selecting `--build-system native` plus that platform's Testing framework/rpaths. Default swiftbuild cannot
    load Testing macros; the CLT native build cannot load SwiftUI macros. No Makefile changes made for this task.
- [x] **T-701b Media-order audit fixes (artifact A8)**
  - Audit finding (2026-11-15): `regenerateAutoZooms`, `speedUpTyping`, and `splitAtPausesAsync` pass recorded-media
    times to edited-clock arrays/operations. Map ranges through every kept clip, preserving copies and rates.
    `splitAudioAtPauses` splits only the first repeated-media occurrence; `erasePauses` deletes by media range
    globally instead of the touched output occurrence. Fix both shared operations. `remapWindowEvents` chooses the
    first matching clip for repeated media: normalize cursor/events for each clip's own window selection.
  - Cursor frame sampling, camera-follow path construction, camera composition and transcript segment slicing
    already map per clip/audio segment; retain that behavior.
  - Verify: Core regressions for reversed/mixed-speed ranges, repeated-media auto zooms, erasing only the second
    audio copy, and repeated media with different window selections; `make test`; native affected editing selftests.
  - Verified 2026-11-15: 143/143 Core tests; native `menu-actions` (extended with moved zoom regeneration and
    repeated-media typing edits/undo), `cursor-copies` (FrameState sampling plus window edit/undo cache invalidation),
    and M6 fixture `parity` (maxDelta=0 at eight times). Xcode native/platform Testing overrides as in T-701.
    Multi-window cursor tables currently simulate full recording duration per clip; narrow the cache if long-project
    profiling warrants it. No real-device/performance acceptance implied.
- [x] **T-702 Core: `reorderClips`**
  - `mutating func reorderClips(_ indices: Set<Int>, to index: Int, propagate: Bool = true) -> Set<Int>` (returns the
    moved clips' new indices; `index` counts positions in the original array, like an insertion caret).
  - How: `before = self`; `useOutputClock()`; split `clips` into `moving` (selected, original order) and `rest`
    (everything else, gaps included); `rest.insert(contentsOf: moving, at: index − selected-before-index)`; walk the
    new array assigning a fresh clock (`sourceStart = t; sourceEnd = t + old clock length; t = sourceEnd`), keeping
    `mediaStart/speed/clockSpeed/fades/hideCursor/color` untouched; record `(oldRange, delta)` for every clip whose
    start changed. Then shift linked content **simultaneously**: add
    `private mutating func shiftLinked(_ moves: [(range: ClosedRange<Double>, delta: Double)])` that, for each array
    `editLinkedLayers` touches (plus camera clips and screen/camera audio), first slices blocks at every clip boundary
    (reuse the slice helper inside `applyLinkedEdit`; a zoom spanning two clips becomes two zooms that each follow their
    footage), then adds the delta of the range containing each piece. Connected layers/unlinked audio whose `start`
    lies in a moved range move with it (same rule as `placeClip(moving:)`). When `propagate == false` only clips move.
    Preserve existing Link Layers semantics: screen-linked audio follows propagation; effects, camera and connected
    items also require `linkVideoEdits`. Layer-linked audio follows its owning layer's delta, not its own start.
    Finish with `settleConnected()`; `checkInvariants() != nil` → `self = before`, return original indices.
  - Copy (`⌥`): no new op — `copySelection(clips:blocks:)` + `pasteSelection(_:atOutput:)` at the caret's output time
    (paste already inserts and duplicates effects with new ids = decision 3).
  - Tests: `reorderRoundTrip` (move then move back = original, compare `Project`), `reorderCarriesZoom` (zoom inside
    the moved clip keeps its offset), `reorderSplitsSpanningZoom`, `reorderKeepsLinkedAudioMedia` (mic clip media
    in-points unchanged relative to the video), `reorderKeepsPlaybackRates` (mixed 1×/2× clips: every `mediaDuration`
    unchanged), `reorderPreservesExportDuration`, `reorderInvariants` (1 000 random reorders, fixed seed, AC-TL-1 style).
  - Verify: `make test FILTER=reorder`.
  - Verified 2026-11-15: all seven targeted tests and 150/150 full Core tests pass with T-701's Xcode native/platform
    Testing flags. Random tests verify the requested permutation, not only invariants; invalid short-audio slicing
    rolls the whole edit back. Unchanged permutations return before clock normalization. `useOutputClock` is now an
    identity on an already explicit contiguous output clock, avoiding repeated slicing/new ids on every reorder.
  - Roundtrip identity is structural for canonical, collision-free projects whose effects do not require splitting.
    Legacy fields normalize to the explicit output clock; spanning effects remain sliced with independent ids;
    collision settlement can change tracks. Footage, rates, payloads and output length are preserved.
    The existing SPEC export rule still trims a newly trailing empty gap; export duration is preserved when retained
    content still reaches the same end. The seven-test duration fixture covers gaps inside retained video.
- [x] **T-702b Preserve spanning audio envelopes before magnetic editing**
  - Review finding (2026-11-15): `useOutputClock` and `applyLinkedEdit` retain each original audio fade on every
    sliced piece. A single fade-in on spanning mic audio can therefore repeat after reorder. Preserve each piece's
    original envelope phase/gain through slicing and rate conversion, including subsequent reorder, copy and trim.
    Reuse the shared audio-ramp path; legacy projects must retain their current envelope defaults.
  - Verify: a spanning mic clip with fade-in/out sliced across three video clips has the same gain at corresponding
    media samples before/after reorder, including cuts inside either fade, mixed rates and undo-equivalent roundtrip;
    `make test`; native `audio-mix-abutting`, `clip-fades` and `menu-actions`.
  - Verified 2026-11-15: 11/11 reorder/envelope tests and 154/154 full Core tests; all three named native selftests
    pass with T-701's Xcode native/platform Testing overrides. Optional validated media-time unit-gain points preserve
    fades across slicing, reorder, mixed/fractional rates, copy, trim, linked-audio movement, split/join and JSON
    roundtrip. Gain/mute retain points; explicit fade edits clear them. Preview mix refresh and timeline outlines use
    shared ramps. Near-equal floating-point segment boundaries coalesce before strict metadata validation.
    Version stays 3; older builds ignore the optional metadata and cannot preserve partial fade phase on rewrite.
- [x] **T-703 Timeline: lift-and-follow drag with live reflow**
  - `TimelineView` `DragKind.moveClip` gets two behaviours by `project.rippleDelete`: Magnet → on every
    `mouseDragged` compute the caret index (pointer x vs. midpoints of the *other* clips), build
    `trial = model.project; trial.reorderClips(selection, to: caret)` (or the paste path when `⌥` is held), set
    `dragProject = trial` and draw lanes from `dragProject` (the pattern layer drags already use) so neighbours open a
    slot live; Free → today's `moveClips(_:byOutput:)` path unchanged.
  - Draw the dragged clip(s) as a floating block under the pointer (same fill, 1 px white outline, shadow, `y` follows
    the mouse) and the landing slot as the block at 45 % opacity with an inset accent outline. Neighbour motion uses
    the existing 0.18 s "moved by another edit" block animation; nothing animates while the user drags *that* block.
  - Commit on `mouseUp` with one `model.edit("Move Clips") { $0 = trial }`; `Esc` mid-drag restores (AC-TL-6). A drop
    that changes nothing makes no undo entry. Auto-scroll when the pointer is within 40 pt of either edge.
  - Remove `dragIgnoresLinks` (decision 5); update the SPEC §7.2 hit table row "clips don't reorder".
  - Implement the artifact's `⌘D` gesture: selected Video clips duplicate immediately after themselves through
    copy/paste insertion; free-track items duplicate at the next free spot. Copies own their effect ids.
  - Verify: new `--selftest timeline-reorder` (synthetic `synthMouse` drags: reorder, ⌥ copy, group of two, Esc
    cancel, ⌘D insertion/free-track placement, exactly one undo step each); all existing `timeline-*` selftests;
    HUMAN: drag feel against the prototype.
  - Existing `timeline-ops` failure observed 2026-11-15: its + menu fixture omits the already-added "Video Track"
    item; update the fixture when verifying these timeline changes. Not evidence of a passing native timeline gate.
  - Verified 2026-11-15: 154/154 Core tests and every current `timeline-*` selftest pass, including the new
    `timeline-reorder` on both the compiled executable and assembled app. Checks include physical modifier events,
    release-only copy toggles, group moves, Escape/no-op undo, independent copied effects, noncontiguous ⌘D,
    layer collision placement, idle-then-edge scrolling, trial collision lanes and height-only layout growth.
    Existing offset-move fixtures now explicitly select Free; the PNG check covers both equal/unequal-speed seams.
  - Rendered/inspected `/tmp/recorder-t703-{drag,collision,timeline}.png` and `build/signal-ui-gallery.png`;
    `make -o build gallery gallery-png CONFIG=debug` reused the freshly verified native binary (default build-engine
    limitations remain as T-701). Reference-board files are absent; existing Theme/UI kit and artifact v6 followed.
    The local review fixture is `/tmp/Recorder-T703-Review.recorder`. User explicitly confirmed "Feel is right"
    for horizontal dragging, ⌥ copy toggling and Escape; this closes T-703's HUMAN check, not later vertical lifts.
  - Long debug-timeline diagnostic: 1800 s / 200 zooms / 60 edge updates mean 17.13 ms, max 19.74 ms,
    zoom commit 8560.27 ms. This excludes preview decode/presentation and is not AC-TL-3 or a hardware gate pass.
- [x] **T-704 Timeline: lane selection + group moves**
  - Header click / ⌘A lane select already ships (`selectLane`). Make a drag that starts on any selected Video clip move
    the whole selection: Magnet → `reorderClips(selection, …)` (lands as one block in timeline order); Free →
    `moveClips(selection, byOutput:)` (already group-aware). Blocks in other lanes keep today's same-lane rule.
  - Verify: extend `--selftest timeline-selection` (header click selects N, drag moves N, one undo).
  - Verified 2026-11-15: extended native check clicks the actual Video header and uses ⌘A over a fixture with
    leading/internal/trailing gaps, selects both real clips, grabs the second selected clip and checks both modes.
    Magnet lands the ordered group together; Free preserves the internal spacing; each drop has one exact undo.
    Block-lane ⌘A remains separate. A keyboard edit cancels the older trial, and mouse-up rejects a trial whose
    source project has changed, preserving intervening menu/external edits and current selection on drop or Escape.
    `make test` 154/154 plus `timeline-selection`, `timeline-reorder`, `timeline-ops` pass with T-701's Xcode native
    flags; reassembled debug app also passes `timeline-selection`. No new visual/HUMAN gate or hardware claim.
- [x] **T-705 Timeline: lane order, drop row, Magnet/Free switch**
  - `lanes`: replace the drag-only spare layer lane (`if mediaDragActive { layerTracks.insert(max + 1) }`) with a
    permanent 26 pt `+ New track` row at the top; order layer lanes above Video (decision 6). Fixtures use
    `laneMidY`, so order changes don't break them — re-check `timeline-tracks`, `timeline-full-layers`, `timeline-png`.
  - Video header gets a small `magnet` / `free` toggle bound to `project.rippleDelete` via `model.edit("Magnetic
    Video")`; switching Free → Magnet keeps spaces as gap clips (already the gap representation), ⌫ closes them.
  - Verify: `--selftest timeline-tracks`, `timeline-png` (inspect PNG); HUMAN: header + drop row against the prototype.
  - User correction 2026-11-15: images on Video tracks should fill the preview canvas. Change the shared image-import
    default from Card to Full, cover file/clipboard/new-track imports, and correct the agent-created review scene's
    small image rectangles while preserving the user's track/timing edits. Existing layer moves keep their geometry.
  - Automated verification 2026-11-15: 154/154 Core tests; native `timeline-tracks`, `timeline-full-layers`,
    `timeline-png`, `timeline-selection`, `timeline-reorder`, `timeline-ops` pass. Assembled app also passes tracks.
    Extended tracks check covers real header/toolbar/undo synchronization, unchanged gaps, compact accessibility,
    26 pt permanent geometry, no allocation on hover, deferred existing-layer placement/cancel/commit, keyboard
    interruption, explicit + click and real PNG drop/import to the next highest track with one undo.
    Clip coordinate fixtures use lane geometry; restore-bubble clicks precede both layer hits and idle media pickers.
  - `make -o build gallery gallery-png CONFIG=debug` reuses the verified binary; gallery/header/timeline renders
    inspected, as is settled minimum-size editor capture at `/tmp/recorder-t705-editor-minimum.png`.
    The initial editor captures showed loading state and are not settled evidence. Default settled capture fails the
    titlebar assertion consistently and is tracked in T-705b. User waived further HUMAN review on 2026-11-15
    ("dont need human review just keep going as u feel"); automated checks and agent image inspection replace that gate.
    Corrected review `/tmp/Recorder-T705-Full-Canvas-Review.recorder` preserves the user's track/timing edits;
    settled image at output 1.25 s inspected. File/clipboard/new-track imports pass Full-canvas assertions;
    preview/export parity maxDelta=0 across 11 times. Extra `make-layers-fixture` check fails image orientation;
    tracked separately in T-705c because its render fixture is independent of import defaults.
- [x] **T-705b Settle default editor capture and titlebar alignment**
  - Observed while verifying T-705: assembled-app `--selftest editor-png /tmp/Recorder-T705-Review.recorder
    /tmp/recorder-t705-editor-default.png 1300 850 --time 0.5` fails "window controls must align with the 48-point
    document row" consistently after preview preparation. The 1100×700 settled capture passes. Diagnose actual
    window layout versus capture lifecycle; fix the root cause without weakening alignment/clickability checks.
  - Read: SPEC §6.1, `EditorWindowController.swift` window/control layout, `SelfTest.swift` editor-png.
  - Verify: settled `editor-png --time 0.5` at 1100×700 and 1300×850; inspect both images; `menu-actions`,
    `timeline-tracks`; preserve fresh native build checks. No loading-state screenshot counted as settled evidence.
  - Verified 2026-11-15: native debug build and scratch assembled-app settled captures at both sizes, `menu-actions`
    and `timeline-tracks` pass. Both images inspected. Native ordering clamps the 850 pt window to 834 pt on this
    screen, resets native controls, and moves the document bar without invalidating its layout. The shared root
    layout now invalidates the bar after positioning it; existing clipping/alignment/clickability assertions stay.
- [x] **T-705c Correct full-canvas image orientation**
  - Observed during image-default verification: `--selftest make-layers-fixture` fails the existing compositor
    "Image orientation" check. Diagnose the fixture and shared image/render path; preserve transparency, crop,
    color and preview/export parity. Fix the cause without loosening the pixel assertion.
  - Verify: `make-layers-fixture`, `media-import`, parity on the generated layers fixture; inspect the orientation proof.
  - Verified 2026-11-15: the fixture's top-left drawing context had red/green bands reversed relative to its existing
    assertion. Corrected only the fixture bands, kept renderer and pixel assertions, and wrote an orientation proof.
    Native build, generated layers checks (including live video layers), `media-import`, and parity all pass;
    maxDelta=0 over 32 times. Inspected `/tmp/recorder-layers-orientation-proof.png` (red above green).

### Phase 2 — Recording clips on Video tracks (format v4 only when used)

- [x] **T-711 Measure two decodes of `screen.mov`**
  - Fixture: 4K HEVC 60 s recording with the middle clip duplicated as a full-canvas layer. Measure preview fps and
    export time on Apple Silicon and Intel (`PerfSelfTest` pattern). Record numbers in SPEC §9. If Intel drops frames,
    the fallback is decoding the layer copy at half resolution (preview only; export stays full).
  - Verify: `--selftest timeline-render-perf --dual-screen`.
  - Implemented 2026-11-15: a separate live benchmark branch with native AppKit event processing, visible-window
    preflight, real Metal presentation timestamps and distinct main/layer decoded-display timestamps. Generates
    3600 moving 4K HEVC frames, references identical screen bytes through `media/` until recording layers exist,
    and validates a real 2160p60 HEVC export's codec/dimensions/duration/3600 compressed samples. Original timeline
    drawing diagnostic remains available without the flag. Preview uses ordinary framebuffer-only drawables.
  - Measurement pending: this Mac is native arm64 Apple M1 (MacBookAir10,1), but the console session is locked
    (`CGSSessionScreenIsLocked=1`). Both direct and LaunchServices attempts found the benchmark window genuinely
    occluded; the command correctly refuses to claim playback results. Two full 3600-frame fixtures were generated
    before moving visibility preflight ahead of synthesis. No preview FPS or dual-screen export time measured;
    Intel hardware also unavailable. No wake/unlock action or review prompt requested; continue software tasks.
  - Apple Silicon measured 2026-11-15 (benchmark window floated above other apps; export counter now ignores
    0-sample marker buffers): preview 59.85 fps, distinct PTS 58.95/s main + 57.27/s layer, export 69.3 s for 60 s
    2160p60, `--selftest timeline-render-perf --dual-screen` OK. Numbers in SPEC §9.
  - Intel dropped by the user 2026-11-15 (no Intel hardware); closed on the Apple Silicon result. Intel stays
    unmeasured; rerun the same command natively on Intel if Intel preview complaints appear.
- [x] **T-712 Core: recording layers, `liftClips`, `insertLayers`, versioning**
  - `LayerBlock.Kind.recording` (file `"screen.mov"`, `mediaStart`, new `mediaRate: Double?` for sped-up clips,
    `rect` = full canvas, `backdrop .none`, clip fades retained, otherwise nil) and `LayerBlock.scene: SceneEffects?` where
    `struct SceneEffects: Codable, Equatable { var zooms: [Zoom]; var masks: [Mask]; var hideCursor: Bool? }` with times
    relative to the layer start. Optional scene window shots and original camera context (clips/zooms/masks/window
    shots plus selected original clip, captured before clock normalization) preserve multi-window selection,
    spring history and mask fade phase for T-713's identity promise. Retained effect IDs let the inverse rejoin only
    lift-generated fragments, preserving later splits/edits. Context contains project metadata, never events.
    Allow `"screen.mov"` in layer media validation (`mediaIsValid` duration =
    `source.duration`). Counts toward the 4 video-layer-lane cap in `freeLayerTrack`.
  - `liftClips(_ indices: Set<Int>, toTrack: Int, atOutput: Double, copy: Bool) -> [UUID]`: per clip (timeline order,
    keeping relative offsets) build the layer, move zooms/masks inside the clip's clock range into `scene` (sliced at
    the clip edges, re-based to 0), relink its screen-linked audio with `linkAudio(_, to: .layer, layer:)`, place with
    `freeLayerTrack(…, preferred: toTrack)` (collision → next track up, decision "nothing is overwritten"), then remove
    the clip with the existing `deleteClips` (ripple per `rippleDelete`). Stage the new content off-project until
    deletion finishes, then place it at the requested output position so ripple cannot shift the destination.
    `copy` skips the removal and duplicates ids. Recording minimum length is 0.1 media seconds; its output duration
    may be shorter at high speed. Imported layer minimum length stays unchanged.
  - `insertLayers(_ ids: [UUID], intoVideoAt index: Int, copy: Bool) -> Set<Int>`: inverse for `.recording` layers —
    build `Clip`s from `mediaStart/mediaRate`, insert through T-702's clock re-lay, restore `scene` effects at the new
    clock positions and relink audio to `.screen`. Imported image/video layers can't enter Video until T-722.
  - Versioning: `currentVersion = 4`, but `save` writes `4` only when a `.recording` layer exists, else `3`, so projects
    that don't use the feature still open in older builds. `currentVersion` is the supported maximum; new/versionless
    models retain version 3 metadata until file save chooses the required version. Read the version header before
    feature enums to reject future versions clearly. Older builds already refuse a newer version with an alert.
  - Tests: `liftInsertRoundTrip` (lift then insert at the same index = original), `liftCarriesZoomsAndAudio`,
    `liftCollisionPushesUp`, `liftCopyLeavesSource`, `v3DecodesUnchanged`, `savesV3WithoutRecordingLayers`.
  - Verify: `make test FILTER=lift`.
  - Verified 2026-11-15: targeted lift 4/4 and full Core 160/160 pass with the established native Xcode/Testing
    flags; app compiles. Six named tests cover rates, short fast clips, collision rollback, independent copies,
    audio settings/envelopes, immutable trim context, trimmed scene insertion, v3/default decoding and v4 saves.
    Round trips include independent camera/key/layout/text timing at middle and tail positions, automatic padding,
    spanning effect restoration and a later neighbor split. Only unchanged owned padding is reclaimed; copies own
    neither padding nor retained neighbors. Audio collisions may change lanes while preserving volume/mute/gain.
    Rendering and vertical gestures remain T-713/T-714; no recording-layer visual acceptance inferred yet.
- [x] **T-713 Render: recording layers through the screen pass**
  - Verified 2026-11-15: Core 162/162; `lift-identity` and `layer-recording-parity` maxDelta=0; `make-layers-fixture`,
    `media-import`, `timeline-tracks`, `menu-actions` OK. Parity root cause: `FrameHold` compared reader PTS (ns-rounded
    CMTime, 4.016666667) to a double request (4.0166666666666667) with `<=` and missed the exact frame, returning the
    previous one; now a 1e-6 slack. Shared fix, so all layers/export benefit.
  - `FrameSource.makeComposition`: a `.recording` layer inserts from the already-open screen asset (keep-alive rule
    in that file applies) into its layer track at `mediaStart … + duration × mediaRate`, scaled for `mediaRate`.
  - `EditorModel.rebuildPathsIfNeeded`: one `CameraPath(zooms: scene.zooms, cursor:, spring:, duration:)` per
    recording layer, cached by layer id + scene hash (ponytail: full re-simulation per edit, like the main path).
  - `makeFrameState`: for a `.recording` layer sample cursor at its media time (`cursorPath.sample(atSource:)` is
    already media-time) and view from its CameraPath; add `view`, `prevView`, `cursor` to `FrameState.Layer`.
  - `Compositor.drawLayer`: for `.recording`, call the existing `drawScreen` → `drawMasks` → `drawCursor` sequence
    with `rectPx` = the layer rect in pixels (default rect = the main screen rect, so a full-canvas lift is identical).
  - Verify: `--selftest layer-recording-parity` (preview vs export maxDelta 0) and `lift-identity` (render before and
    after lifting a clip at the same time: maxDelta 0) — the "looks the same on any lane" promise.
- [x] **T-714 Timeline: vertical drag, drop row, ⌥↑/⌥↓**
  - Extend T-703's drag: pointer over a layer lane or the `+ New track` row → `trial.liftClips(…)`; layer item over
    Video → `trial.insertLayers(…)`; free target shows the floating block snapped to edges/playhead. The new-track row
    shows a placeholder (no lane is created until drop, so nothing jumps under the pointer). `⌥↑`/`⌥↓` move the
    selection one lane at the same time. Carried zooms draw dimmed in the Zoom lane under their layer.
  - Verify: `--selftest timeline-lift` (lift, drop back, new track, collision push-up, one undo each);
    HUMAN: lift/drop feel and preview look against the prototype.

### Phase 3 — Polish (each independent)

- [x] **T-721 Edit carried effects** — selecting a lifted recording shows its `scene.zooms` editable in the Zoom lane
  (offset to the layer) through the generic timed-block ops. Verify: `make test FILTER=sceneEffects`; `timeline-lift`.
- [x] **T-722 Imported video/images on the Video lane** — `Clip.file: String?` (nil = `screen.mov`); composition
  inserts per-clip assets; such clips have no cursor/zoom/events. Bumps the "uses v4" check. Verify:
  `make test FILTER=clipFile`; `--selftest media-import`.
- [x] **T-723 Docs** — SPEC §5 (v4 keys, version rule), §7.1 anatomy mockup, §7.2 gestures (from the prototype), §7.3
  keys (⌥ copy, ⌥↑/⌥↓, ⌘D on clips), cheat sheet. Verify: `--selftest menu-actions`.

## Requested timeline tools — 2026-11-15

- [x] **T-731 Pencil tool + box select across lanes** · SPEC §7.2 — `P`/toolbar pencil draws blocks in effect lanes
  (the old pointer empty-lane add); the Select tool box-selects clips and blocks across every lane from any empty
  start point. Verify: `--selftest timeline-ops`.
- [x] **T-732 Join Clips groups mixed clips** · SPEC §5, §7.2 — `Clip.group`; ⌘J groups non-mergeable neighbours
  (keeps speeds/cuts), selection/move/trim treat a group as one clip, ⇧⌘J ungroups, paste gets a fresh group id.
  Verify: `make test FILTER=joinClips`; `--selftest timeline-ops`.
- [x] **T-733 Joined clip settings** · SPEC §5, §7.2 — selecting a group opens the clip inspector; speed is a group
  multiplier (`Clip.groupSpeed`, `setGroupSpeed`/`groupSpeedRange`, `displayedSpeed`), cursor/fades/remove act on the
  group; right-click Speed and the timeline label use the group speed. Verify: `make test FILTER=groupSpeed`;
  `--selftest clip-fades`.
- [~] **T-734 Insert preview when dropping onto Video** · SPEC §7.2 — dragging a lifted recording over the Video lane
  draws the trial insert (landing clip faded + outlined) and ripples neighbours apart/back. Verify: `--selftest timeline-lift`.

## Requested agent editing (MCP) — 2026-11-16

Source: [MCP.md](MCP.md) (normative: decisions §1, protocol §4, tools §5, per-task Do/Files/Signatures/Verify §6) ·
prototype https://artifacts.microapps.space/a/0shbfprqwqz2. Read MCP.md §0–§3 before the first of these tasks.
Core tasks (T-801…T-803) are pure and unit-tested; app tasks use `--selftest` cases named in MCP.md.

| Scope | Tasks | Done |
|---|---|---|
| Core: views, edit ops, markers/styles | T-801…T-803 | 3/3 |
| App: server, render, edit/draft | T-804…T-806 | 3/3 |
| App: review UI, graphics, export/settings | T-807…T-809 | 3/3 |
| Docs + smoke | T-810 | 1/1 |
| Connect an Agent window | T-811 | 1/1 |

- [x] **T-801 Core: agent views** · MCP.md §T-801 — `AgentViews.swift`: `agentTimeline`, `agentTranscript` (stable
  `wN` ids, output time, fillers), `isFiller`, `transcriptID`. Verify: `make test FILTER=AgentViews`; `make test`.
- [x] **T-802 Core: `EditOp` + `Project.applying`** · MCP.md §T-802 — ops in base output time, converted to source
  before mutating; `removeSourceRanges` via `split`/`deleteClips`; atomic with `checkInvariants`. Verify:
  `make test FILTER=EditOps`; `make test`.
- [x] **T-803 Core: markers, `lowerThird`/`chapter`, SRT** · MCP.md §T-803 — additive `markers`; version 5 only when the
  new styles are used; `srt(_:)`. Verify: `make test FILTER=ProjectTests`; `make test FILTER=EditOps`; `make test`.
- [x] **T-804 App: MCP server, `--mcp` shim, read tools** · MCP.md §2, §4, §T-804 — Unix socket, hand-rolled JSON-RPC,
  sessions, access levels, activity; `project`/`timeline`/`transcript`/`analyze`. Verify: `--selftest mcp-roundtrip <fixture>`;
  shim initialize smoke; `make test`.
- [x] **T-805 App: render tools** · MCP.md §T-805 — `renderFramesPNG` (multi-time, parity with Copy Frame), contact sheet,
  540p proxy clip with progress, agent cache + purge. Verify: `--selftest mcp-render <fixture>`; `--selftest parity`;
  `--selftest menu-actions`.
- [x] **T-806 App: `edit` + `draft` tools** · MCP.md §T-806 — draft = replayed calls on a base; live = one named undo
  step; `STALE_REVISION`; `EditorModel.isReviewingDraft` guard. Verify: `--selftest mcp-edit <fixture>`; `make test`.
- [x] **T-807 App: review UI** · MCP.md §T-807 — inspector `Claude` tab (`AgentPanel.swift`), document-bar status,
  timeline review marks, accept = one undo step. Verify: `--selftest mcp-review <fixture>`; agent/default/minimum/stale/error/long-note PNGs inspected. HUMAN visual gate waived by user (2026-11-15); no human-performed comparison claimed.
- [x] **T-808 App: render `lowerThird` + `chapter`** · MCP.md §T-808 — in `Compositor.drawText`; TextPanel styles.
  Verify: `--selftest parity` (all-five-style fixtures at 16:9 and 9:16) maxDelta 0 over 24 times each; `motion-text`, `layers`, full Core suite. Both styles and settled inspector PNGs inspected; HUMAN visual gate waived by user (2026-11-15).
- [x] **T-809 App: `export.final`, SRT, `ui.show`, Settings ▸ Agents** · MCP.md §T-809 — native approval sheet,
  `claude mcp add` connect row, Copy JSON. Verify: `--selftest mcp-export <fixture>`; actual Claude Code reports nine tools,
  native review/Undo/Redo and Export/Deny exercised on a disposable generated recording. User's HUMAN-review waiver
  applied to agent-driven workflow; no person or live speech-capture approval claimed.
- [x] **T-810 Docs + `make mcp-smoke`** · MCP.md §T-810 — SPEC §10 Agents, §5 version 5 rule, README, CLAUDE.md commands.
  Verify: `make mcp-smoke`; `make test`; `--selftest menu-actions`.
- [x] **T-811 App: Connect an Agent window (requested 2026-11-16)** · SPEC §10 "Connecting a client" — dbman-style
  `AgentsWindow.swift` (guide, eight clients, Other JSON, agentpack) replacing the Claude-only Settings row; Core
  `AgentConfig` (JSON/TOML install/uninstall/status). Verify: `make test FILTER=AgentConfig`; `make test`;
  `--selftest menus`; `--selftest settings-png <out> agents pane=<id>` inspected for guide/claude-code/codex/agentpack.

---

## Claude panel redesign and MCP gaps — 2026-11-16

Source: https://artifacts.microapps.space/a/crsebftafkp3 (version 6). The user's request is **the full design,
including prototype motion and every listed task**; the source's earlier "deferred until you ask" labels do
not remove T-817/T-821…T-824 from this request. Work in order, one verified task/commit at a time.
T-813 is included in T-812; T-816 is included in T-815, as the source specifies. Preserve native project
editing, read-only review guards, frozen autosave, stable replay IDs, privacy and one-step acceptance undo.

| Scope | Tasks | Done |
|---|---|---|
| Grouped review + pinned footer | T-812 (includes T-813) | 1/1 |
| Status, activity and finite motion | T-814 | 1/1 |
| Live preview + timeline motion | T-815 (includes T-816) | 1/1 |
| Iteration, boundary snapping, anchors | T-817…T-819 | 3/3 |
| Zoom documentation/grid + follow/ease | T-820…T-821 | 2/2 |
| Text styling, assets, draft playback | T-822…T-824 | 3/3 |

- [x] **T-812 Grouped Changes and pinned Accept (includes T-813)** — Core pure row grouping, fixed
  Cuts/Speed/Zoom/Text/Markers/Other order, drop empty groups, sum deltas. Collapsed group disclosures with
  lane swatches, counts, native tri-state checkboxes; individual rows retain skipped reasons and seek on click.
  Summary shows selected count, resulting duration and delta. Stale/error notices above the summary.
  Panel owns its scroll area; only Accept N is pinned below it (latest source design rule supersedes the
  older T-813 Discard/Accept footer wording). Untick all then Accept 0 to exit without modifying the project.
  Disclosure: 320 ms, 55 ms child stagger, 4 pt slide; Reduce Motion: no movement, 140 ms opacity only.
  Verify: `make test FILTER=AgentDraft`; `make test`; `--selftest inspector-panels`; `--selftest mcp-review <fixture>`
  (exclude/reinclude whole groups, seeded remaining result, zero-op acceptance); inspect 17- and 5-op panel
  PNGs at 320×640 plus 420 pt short/stale/error/long-note variants. Exercise native checkbox/disclosure/seek.
- [x] **T-814 Status strip, activity feed and panel motion** — Intent/result strings at existing tool-response
  sites, in-flight current call; privacy-safe status over a finite 1 px progress rail. Collapsed newest-first
  Activity N; errors keep codes. New group wipe 320 ms with 700 ms fading 2 px edge; press 80/hover160;
  disclosure/replay cancellation and Reduce Motion opacity140. Provide replayable native prototype using
  the real panel/widgets. Verify `mcp-edit` intent/result/privacy, working/idle/error PNGs and intermediate
  motion samples, rapid reversal/replay cancellation and Reduce Motion.
  Native checks: `--selftest mcp-panel-motion <output-directory>`, `mcp-edit <fixture>`, `mcp-render <fixture>`,
  `mcp-review <fixture>` (normal and `--reduce-motion`), `inspector-panels`; `make test`, gallery/PNG inspected.
- [x] **T-815 Live draft preview (includes T-816 marks)** — First successful draft apply begins watching,
  later calls update the frozen-safe review once per call; submit switches to reviewing and enables checkboxes.
  Guard gestures with "Claude is editing, Esc to take over"; second session stays invisible with notice.
  Auto-select Claude on first draft/live apply when key. Reuse existing cut chips/dashed added blocks, wipe
  320 ms staggered60–90 ms by lane, accepted outlines settle220; Reduce Motion opacity only. Update MCP.md
  D1/T-807 and SPEC §10. Verify new `mcp-live`: three unsubmitted calls, project/frames/marks per call,
  unchanged liveProject/disk, notice/gesture/Escape/discard, session conflict; real-client recorded sequence.
- [x] **T-817 Iterate after submit** — Pending submitted draft accepts more applies, returns to watching,
  preserves unchanged exclusions/IDs and nil verdict; draft.status reports exclusions and reasons.
  Verify `mcp-review` submit/exclude/apply/status/accept count and undo.
- [x] **T-818 Snap idle-derived edits to clip edges** — `snap:true` option, default for idle-derived operations;
  clamp nearest valid boundary, report adjustments in changes[].note, warn/skip collapsed operations rather
  than failing batch; retain strict validation otherwise. Include normalized source-frame zoom descriptions
  from T-820 here. Verify EditOps edge/minimum/batch/atomicity cases, `mcp-edit --headless` (user requests no
  test windows/focus changes), full Core suite.
- [x] **T-819 Marker anchors** — Accept numeric times or `{marker:"id", offset}`; resolve anchors after earlier
  ops in batch while numeric times retain documented base-time semantics. Verify EditOps cuts/speed/marker
  create/update/delete/offset/missing-anchor cases, stable replay/exclusions and MCP schema/native checks.
- [x] **T-820 Zoom coordinates and debug grid** — Document normalized0–1 source-frame coordinates, top-left
  origin (schema description done in T-818); reject out-of-range values; optional debug grid in render.frames.
  Verify coordinate validation, grid geometry/render output and normal-frame parity/privacy.
- [x] **T-821 Cursor-follow zoom and easing** — Zoom op `follow:"cursor"` and existing Spring presets;
  reuse CursorPath and 240Hz camera paths. Verify Core mapping/follow/preset/persistence/replay and actual
  preview/export parity including cut/speed edges; MCP schema and native editing checks.
- [x] **T-822 Existing text styling fields** — Text op accepts inspector size/position/palette colour; no new
  fonts or animation options. Verify flat JSON/validation/persistence/replay, inspector agreement and native
  render parity for all styles and aspect ratios.
- [x] **T-823 Assets and layer operations** — Start with SPEC design: `project.assets` lists imported layers
  and library recordings; `layer` op adds an image or another project's clip using existing layer machinery.
  Verify trusted-path/import/clock/copy validation, immutable media and atomic failure, draft isolation,
  replay/undo/save/reopen and preview/export parity; update schemas/docs/client smoke tool assumptions.
- [x] **T-824 Play draft** — Footer Play draft uses existing 540p render.clip proxy; cancellation/progress,
  stale/current draft identity and native playable preview. Audio ops remain outside the source's scope.
  Verify native playback with audio, errors/cancellation/repeated requests/review acceptance/close and
  final full-reference requirement audit (including all replay/reduced-motion and native-app evidence).

---

## Agent perception, intent edits and verification (MCP) — 2026-11-17

Source: https://artifacts.microapps.space/a/92t5aaqrr5ax (proposal 2026-11-16). The user requested **the full
proposal, every task**. Audio/voiceover stay out of scope as the source states. Preserve draft isolation, one-step
acceptance undo, privacy (renders hide key overlays) and existing op semantics; new ops lower to existing primitives.

| Scope | Tasks | Done |
|---|---|---|
| Reliability | T-825…T-826 | 2/2 |
| Perception + feedback core | T-827…T-829 | 3/3 |
| Intent ops + reframe | T-830…T-831 | 2/2 |
| Captions + eval harness | T-832…T-833 | 2/2 |

- [x] **T-825 Persistent drafts, listChanged, schema parity** — R1 `agent-draft.json` in the package (base revision,
  calls, status); `project.open` returns `draft:{id,status,changes}` and re-adopts it (replaces D8). R2
  `tools:{listChanged:true}`, `notifications/tools/list_changed` on upgrade, `schemaVersion` in `initialize`. R5 one
  source of truth for limits (render.frames 24), server-side `minimum`/`maximum`/`maxItems`/`enum` validation, R6
  annotations + `outputSchema`. Verify: Core draft persistence round-trip tests; schema/handler parity self-test.
- [x] **T-826 Addressable blocks, anchors, actionable errors** — R3 update/remove every lane `timeline.get` emits or
  mark `editable:false` with reason; layer from/to maps both ends. R4 `{marker:"label"}` when unique,
  `{shot:"s07",edge}` and same-batch `ref`. R7 errors carry `fix` and `current`. Verify: EditOps tests per lane,
  label/ref anchors, snapped-range fix on clip-edge error.
- [x] **T-827 analyze.shots** — Core pure segmentation (stable states SSIM ≥ 0.985 for 0.3 s, boundary kinds
  cut/scroll/animate/type, interest payoff/motion/cursorOnly/static/typing with reasons, focus box, source-keyed
  stable IDs, summary); app decodes 10 fps 1/8-scale luma with vImage, cached per media content hash. Verify:
  Core segmentation tests on synthetic signals; 100 s fixture analyses < 5 s.
  MEASURED 2026-11-17 (`--selftest shots-perf`, release, Golden Island 254.6 s, HEVC 2880×1800, 8798 frames):
  AVAssetReader scaling decode 29.5 s (≈11.5 s per 100 s); shipped VideoToolbox path 8.9 s (≈3.5 s per 100 s, target
  < 5 s met; Velvet Valley 41 s clip 0.83 s), cached call 0.01 s, shots 122 → 123. Path: compressed samples, skip
  droppable frames no 0.1 s tick shows (≈50 % of frames), ~8 s sync-aligned chunks decoded in parallel with alternating
  hardware/software VT sessions (each engine alone is serial; hw+sw together ≈ 3x), row-subsampled box luma. The decoders
  ignore ReducedResolutionDecode/ReducedCoefficientDecode for HEVC (unsupported). Falls back to AVAssetReader on any failure.
  Prior bound analysis (hardware decoder serial) was right for one engine only.
  F1 ≥ 0.8 on 5 hand-labelled recordings not measured (no labelled set exists).
- [x] **T-828 render.storyboard / strip / compare** — shot-anchored tiles (settled keyframe, id + duration label,
  ≤ 48 per page), filmstrip 4–8 fps, base|draft side by side. Verify: tile count = shots, legible at 320 px.
- [x] **T-829 Edit report + render.lint** — `report` (duration/asl/hook/longestStatic/staticSec before/after, lint)
  on every edit.apply/dryRun; `render.lint` profiles reel/tutorial/demo with rules hook, maxStatic, asl, duration,
  tinyShot, orphanEffect, edgeContent, each naming a shot and a suggested op. Verify: Core report/lint tests.
- [x] **T-830 Intent ops** — keepShots, pace, fitDuration, speed `ramp`, autoZoom exposure; each lowers to
  cut/speed/zoom in one undo step and returns lowered ops. Verify: Core lowering tests, one-step undo.
- [x] **T-831 reframe** — `output.aspect` plus per-shot stationary/pan crop aimed at focus and cursor
  (time-varying crop on the camera lane); edgeContent lint clean. Verify: Core crop-path tests, focus kept in frame.
- [x] **T-832 Optional per-shot captions** — on-device (Vision OCR/classification) 6–10 word captions; `null`
  when unavailable, everything works without them. Verify: caption present/absent paths.
- [x] **T-833 Agent eval harness** — script scoring lint pass rate, ops per task, images requested over a set of
  recordings with the brief "30 s reel, fast cuts, no text"; run on MCP changes. Verify: harness runs on fixtures.

---

## Editing core v2: human + Claude on one model — 2026-11-17

Source: [EDITING-CORE.md](EDITING-CORE.md) (normative: decisions D1–D8, MCP v2 §4, capability table §5) · feedback run 6
https://artifacts.microapps.space/a/6h4p6rzd4tdr · prototype https://artifacts.microapps.space/a/2a8nw5c559k4. The user requested
**the whole plan**. Order matters: reliability first, then the kernel the rest builds on. Each new capability lands as
TimelineOps primitive → EditOp → human command → selftest (D4), and fills its row in EDITING-CORE §5.

| Scope | Tasks | Done |
|---|---|---|
| A. Reliability (feedback run 6) | T-901…T-905 | 5/5 |
| B. Kernel: item view, fuzz, `set` | T-910…T-912 | 3/3 |
| C. Keyframes + motion graphics | T-920…T-925 | 6/6 |
| D. Human editor gaps | T-930…T-937 | 8/8 |
| E. Docs + eval | T-940 | 1/1 |

- [x] **T-901 One duration, layers visible to agent tools** — `project.list`/`info`/`timeline.get`/`analyze.shots`/sheet
  report `Project.exportDuration`; `project.assets.layers` lists every layer `{id,kind,file,from,to,mediaStart,mediaRate}`;
  shots/sections/lint treat output spans covered only by a layer as `kind:"layer"` coverage. Verify: Core test that a
  project with a layer past the last clip reports one duration in `agentTimeline` and the storyboard view;
  `--selftest mcp-roundtrip <fixture>`; `make test`.
- [x] **T-902 Media-time anchors** (D2) — `{shot}` anchors resolve base spine → media → spine of the batch prefix, so a
  `speed` earlier in the batch (which may switch to the output clock) no longer reports "removed footage". Verify:
  `make test FILTER=EditOps` (new `shotAnchorAfterSpeed`); `make test`.
- [x] **T-903 Layer trim and speed via `update`** — layer `to`, `mediaStart`, `mediaRate` (connected item; limits: media
  length, 0.5 s minimum, track collisions; reports the reachable limit); works for layers beyond clips' end. Verify:
  `make test FILTER=LayerEdit` cases trim/slip/rate/limit/past-end; `make test`.
- [x] **T-904 No uncovered canvas** — `cut` over a range that is a gap (interior or before a connected layer) removes it
  and ripples connected items; lint rule `uncovered` (output span with no clip and no layer, ≥ 1 frame) with a dry-run
  `cut` suggestion. Verify: Core tests (Golden Island 91.13–91.69 tail gap shape); `make test`.
- [x] **T-905 Tool polish** — `render.sheet` honours `from`/`to`; `STALE_REVISION` names what you passed and the
  current draft/base revisions; `reframe` returns `{keysBefore,keysAfter,changed,shots}` and accepts
  `focus:{"s12":{x,y}}` overrides. Verify: `make test FILTER=Reframe`; `--selftest mcp-render <fixture>`; MCP.md updated.
- [x] **T-910 `Items.swift` unified item view** (D3) — `items(project)` covering all 13 kinds with anchor, out/spine/media
  ranges and `editable`; `agentTimeline` and `project.assets` built on it. Verify: `make test FILTER=Items` (every array
  represented, out ranges in 0…exportDuration, Golden Island timeline unchanged); `make test`.
- [x] **T-911 Kernel fuzz** (D8) — `KernelFuzzTests`: seeded random EditOp batches over 4 fixtures, 500 batches; per
  batch invariants, Codable round-trip, items in range, determinism, failed batch leaves project unchanged. Fix every
  root cause it finds in the shared op. Verify: `make test FILTER=KernelFuzz`; `make test`.
- [x] **T-912 Generic `set` op** — patch any item by id over `Item.editable`; `update` = alias; unknown field error lists
  valid fields; mask `kind` (blur/highlight) settable. Verify: `make test FILTER=EditOps`; schema parity selftest.
- [x] **T-920 Keyframes core** (D5) — `Key`, `Transform`, `evaluate` (per-property neighbours, eases, spring via
  `Spring`); optional `keys` on LayerBlock/TextBlock; version 7 only when used; invariants (sorted, inside item).
  Verify: `make test FILTER=Keyframes`; `make test`.
- [x] **T-921 Graphic model** (D6) — `Project.graphics`, `GraphicElement`, connected-item TimelineOps (add/move/resize/
  delete/duplicate via the generic timed-block ops), invariants, v7 rule. Verify: `make test FILTER=Graphics`.
- [x] **T-922 Templates** — `titleCard`, `callout`, `stepBadge`, `spotlight`, `progressBar`, `counter` as pure
  `(params) -> [GraphicElement]` with param schemas (for `project.templates`). Verify: `make test FILTER=Graphics`.
- [x] **T-923 Render graphics + keyframes** — Compositor draws graphics (CG → cached texture), `space: screen` mapped
  through `ZoomTargetMapping`; layer/text keys applied. Verify: `--selftest parity` with graphics/keys fixtures maxDelta 0;
  `--selftest graphics-png <out>` inspected.
- [x] **T-924 Human: Graphics lane, template gallery, GraphicPanel, keyframes** — lane in TimelineView, `G` menu of
  templates, inspector params/elements/colours (Theme tokens), on-canvas move/resize (SelectionRectView), keyframe
  diamonds on the selected block, ⌥K add key at playhead, drag diamond. Verify: `--selftest graphics-ui`, inspector PNGs;
  HUMAN: compare with the prototype.
- [x] **T-925 MCP `graphic`, `animate`, `project.templates`** — ops lower to T-921/T-920 primitives; schema + parity;
  timeline.get emits graphics. Verify: `--selftest mcp-edit <fixture>` (title card + screen callout through a zoom,
  frames rendered); MCP.md §5.
- [x] **T-930 Markers UI** — `M` adds at playhead, ruler flags, double-click rename, ⌃←/⌃→ jump, delete. Verify:
  `--selftest markers`; HUMAN look.
- [x] **T-931 Editable transcript** — transcript panel words selectable; ⌫ applies `cutWords` through
  `EditorModel.apply`; fillers highlighted with "Remove fillers". Verify: `--selftest transcript-edit <fixture>`.
- [x] **T-932 Roll and slip** — Core `rollEdit(boundary, delta)`, `slipClip(id, delta)` (clips and video layers);
  ⌥-drag seam = roll, ⌘-drag body = slip. Verify: `make test FILTER=TimelineOps`; `--selftest timeline-trim`.
- [x] **T-933 Freeze frame** — `Clip.freeze` (hold one media frame for d output seconds) in TimeMap; ⇧F; MCP `freeze`.
  Verify: `make test FILTER=TimeMap`; parity selftest.
- [x] **T-934 Seam transitions** — `Clip.transitionIn {kind: dissolve|dipToBlack|push, duration}` centred on the seam;
  compositor blends both frames; MCP `transition`. Verify: Core TimeMap/overlap tests; parity selftest.
- [x] **T-935 Speed ramp UI** — clip inspector ramp in/out (reuse stepped ramp lowering). Verify: `--selftest clip-speed`.
- [x] **T-936 Ducking + gain envelope** — music track `duck` under mic/voiceover; editable envelope points on audio clips.
  Verify: `--selftest audio-mix`; `make test FILTER=AudioClip`.
- [x] **T-937 Export range** — I/O on the timeline, export sheet "Range: whole | in–out"; `export.final {from,to}`.
  Verify: `--selftest export-sheet`, `mcp-export`.
- [x] **T-940 Docs + eval** — MCP.md v2, SPEC §5/§10, eval harness brief "30 s reel with a title card and two callouts"
  on Golden Island. Verify: `make mcp-smoke`; harness run recorded.


---

## Agent recording: silent demos without a person — 2026-11-18

Source: [RECORDING-AGENT.md](RECORDING-AGENT.md) (normative: decisions R1–R10, `record` tool §3, edge cases §6) ·
proposal https://artifacts.microapps.space/a/d0rs3s43x727. The user asked for an agent to record the screen and deliver
an edited silent demo as a reviewable project. Recorder captures and marks; the agent's own computer-use tool acts (R1).
The proposal's open choices are taken at its recommendations: consent once per session plus an opt-in "without asking"
toggle (R3), any driver with Claude Code computer use for the eval, and one window as the default target (R8).

| Scope | Tasks | Done |
|---|---|---|
| Capture path + MCP tool | T-950…T-951 | 2/2 |
| Docs, smoke, scripts | T-952 | 1/1 |
| Live eval (MacBook Air) | T-953 | 1/1 |
| Robustness | T-954…T-956 | 1/3 |

- [x] **T-950 Agent recording path** · RECORDING-AGENT §5 T-950. `RecordingSettings(agentCopyOf:excludedBundleIDs:)`,
  `CaptureTarget.filter` excludes bundle ids, `RecordingController.beginForAgent/addMarker/finishForAgent` (shared
  `capture` body, `finishCapture(presentErrors:)`, owner/markers/title/maxDuration, markers saved into `project.json`).
  Verify: `--selftest record-agent` OK (or SKIP → `[~]` HUMAN: grant and re-run); `menus`, `menu-actions`; `make test`.
- [x] **T-951 MCP `record` tool** · §3, §5 T-951. targets/start/status/mark/pause/resume/stop, `openProject` extracted
  from `project.open`, consent alert + `approveRecording` injection + timeout, disconnect → finish, Settings ▸ Agents
  toggle. Verify: `--selftest mcp-record`, `record-agent-cap`, `mcp-schema`, `mcp-export`, `mcp-roundtrip <fixture>`;
  `settings-png <out> agents` inspected; `make test`. HUMAN (waivable): see the real consent alert via T-952's script.
- [x] **T-952 Docs, smoke, scripts** · §5 T-952. `mcp-smoke` 10 tools, MCP.md/SPEC §10/README/CLAUDE.md,
  `scripts/mcp-record-demo.sh`, `scripts/mcp-log.py`. Verify: `make mcp-smoke`; `bash -n`; relay self-check; `make test`.
- [x] **T-953 Live eval: TextEdit silent demo** · §5 T-953. HUMAN prerequisites (grants, interactive computer use on
  the MacBook Air). Verify: `agent-eval.py docs/evals/textedit-silent-demo.jsonl` in the Log; `render.lint demo` clean;
  draft visible in the Claude tab; SPEC §9 re-prompt question answered.
  See the Log for the live take, cursor limitations and consent observations.
- [x] **T-954 Agent pointer events** · §5 T-954. `record.mark {x,y,pointerAction}` → `EventLog.mergingAgentPointer` (Core,
  tested) so Accessibility-only drivers still get a cursor and auto-zooms. Cursor playback holds through sparse
  sample gaps. Verify: `make test FILTER=EventsAgentPointer`;
  `make test`; `--selftest mcp-record`.
- [ ] **T-955 Draft-ready notification** · §5 T-955. Dock bounce + `UNUserNotificationCenter` on `draft.submit` when
  inactive; title and count only. Verify: `--selftest mcp-review` incl. injected `notify`.
- [ ] **T-956 `steps` intent (conditional)** · §5 T-956. Only if T-953 shows ≥2 manual cuts per step or static-span lint
  warnings after `pace`; otherwise tick with `not needed: <evidence>`. Verify: `make test FILTER=IntentOps`; `make test`.

---

## Requested Nudge fixes — 2026-09-22

User-requested fixes are handled individually in this order, separately from the outstanding HUMAN milestone gates.
Repository: `/Users/snowbear/WORK/GIT/recorder`, branch `dev`, native AppKit/SwiftUI SwiftPM app.

| Scope | Tasks | Done |
|---|---|---|
| Recorder Nudge defects | DEF-1107…DEF-1111 | 5/5 |
| Requested clip fades | T-616 | 1/1 |
| Requested advanced gallery | T-617 | 1/1 |
| Requested signed releases | T-618 | 0/1 |

- [~] **T-618 Developer ID signed release DMGs**
  - User request: release CI uses the user's Apple account and publishes installable, notarized DMGs.
  - Do: require a Developer ID Application certificate and app-specific notarization credentials in GitHub secrets; fail closed if absent; retain app and DMG staple/assessment checks. Document one-time Apple account and GitHub setup.
  - Verify: parse workflow YAML, check shell syntax for every run block, and run `make test`; HUMAN: create/export the Developer ID certificate, generate an app-specific password, configure GitHub secrets, run a tagged release, and install the resulting DMG on a clean Mac/user account.

- [x] **T-617 Advanced gallery themes and demo motion**
  - User request: white/black inverted gallery with theme switcher, FUI scroll/interaction reveals, and a Twitter demo presentation.
  - Do: default to White; lead with the interactive timeline, then compose actual editor panels in staggered columns, live key preview, capture typography and small widgets. Omit the full editor shell and rejected cursor graphic from advanced mode. Reuse shared tokens/controls and timeline gestures with cancellable reveals and a finite Play demo sequence. Keep ordinary gallery and app behavior stable.
  - Verify: `make gallery CONFIG=debug`; `make gallery-png CONFIG=debug`; `--selftest ui-motion`; `--selftest ui-kit-png build/gallery-advanced-demo.png --gallery-advanced --gallery-demo --gallery-check`. Inspect both themes, intermediate reveals, component scroll and minimum-size captures. Reference boards are absent from this checkout; current UI-KIT notes used. Automated frames verify staging/layout, not a human assessment of pointer feel.

- [x] **T-611 / DEF-1107 Restore recording surface focus**
  - Mapping: AppDelegate recording actions → ToolbarController.show/presentPicker → SourcePickerOverlay. Recording surface means selected SCDisplay/SCWindow in the capture picker, not an editor clip or document window.
  - Do: retain session source IDs, validate on entry, preserve explicit pointer selection, and provide a visible unavailable-source fallback.
  - Verify: `make app`; `--selftest recording-focus` (real panels/live source validation plus deterministic missing-source matrix); existing `pickers` and `recording-dismissal` checks.
- [x] **T-612 / DEF-1108 End automatic export range at last active clip**
  - Mapping: screen Clip.isGap distinguishes removed media; cameraClips can remain independently over screen gaps. No explicit export in/out selection exists. Project.exportDuration computes the last retained screen/camera endpoint; sheet estimates, both encoders and MP4 audio use it. Empty export is disabled/rejected before destination mutation.
  - Verified: `make test FILTER=exportDurationTracksActiveMedia`, `make app`, selftests `export-range`, `export-sheet`, `audio-mix` all pass. Range test covers split/trim/move/delete, missing camera source, empty/invalid media; live sheet edits/undo/redo; MP4/GIF output with screen and camera tails; audio clipping and empty destination preservation.
- [x] **T-613 / DEF-1109 Precise small highlight manipulation**
  - Mapping: normalized Mask.rect → CropMapping within ZoomTargetMapping.contentRect → shared SelectionRectView. One cropped-source pixel replaces the inherited 100-point minimum. Small geometry has separated handles, body movement and offset-preserving resize; outside drag cannot replace the mask. Preview preserves rectangle keyboard focus; Escape cancels through EditorModel.
  - Verified: make app; selftests highlight-manipulation, pickers, mask-rect, crop, zoom-target all pass. Pointer coverage: all eight handles, two preview scales, no jump, minimum, bounds including persisted geometry, undo/redo and cancel; real PreviewView first-responder dispatch; small-highlight PNG rendered and inspected.
- [x] **T-614 / DEF-1110 Cmd-click scissors split**
  - Mapping: native ScissorsButton captures NSEvent.command at mouse-down, retains NSButton tracking, and routes the action to TimelineView.splitClipAtPlayhead → existing performSplit/Project.split. Screen clips occupy a single non-overlapping lane; the clip under the playhead is deterministic. No tool activation; the left piece remains selected.
  - Verified: make app; make test FILTER=split (4 tests); command-scissors, timeline-ops, menu-actions selftests. Actual button down/up tests cover both sticky states, modifier released before mouse-up, selected/nonselected target, effects selection, edges/gaps, geometry, one undo entry, undo/redo, button state and ordinary clicks.
- [x] **T-615 / DEF-1111 Immediate recording setup appearance**
  - Source: recording panels retained NSWindow.animationBehavior.default (AppKit infers automatic orderFront/orderOut animation). FloatingPanel.register now sets .none for recording-flow windows only; no custom initial SwiftUI fade exists. Countdown-number animation and unrelated windows retain their behavior.
  - Verified: before/after recording-appearance trace through fresh ToolbarController.show (same cold-launch entry), all three modes, widget and countdown. Baseline check fails with animation=0; fixed check passes with animation=2, alpha=1, immediate visibility/input and stable frames. Reduce Motion is false on the host; native .none is unconditional and the existing countdown Reduce Motion branch remains unchanged. Toolbar PNG rendered/inspected; recording-focus and recording-dismissal pass.

---

## M0 — Foundations

- [x] **T-001 git + signing identity**
  - Do: `git init && git add -A && git commit -m "skeleton + spec"`. Then `make cert`.
  - HUMAN: `make cert` asks for the login-keychain password once; on first `codesign` click "Always Allow".
  - Verify: `security find-identity -p codesigning | grep "Recorder Dev"` prints a line; `make app` output ends with signing by `Recorder Dev`; `codesign -dv build/Recorder.app 2>&1 | grep Authority` shows `Recorder Dev`.

- [x] **T-002 Theme** · SPEC §3
  - File: `Sources/Recorder/App/Theme.swift`
  - Do: one `enum Theme` with static `NSColor`s for every token in SPEC §3 (+ `Color` accessors via `Color(nsColor:)`), radii, fonts. Add `NSColor(hex:)` (6/8-digit) here — the only hex parser in the repo.
  ```swift
  enum Theme {
      static let bgWindow = NSColor(hex: "#0A0B0F") // …one per token
      enum Radius { static let control: CGFloat = 6, card: CGFloat = 10, panel: CGFloat = 16 }
      static func timecodeFont(_ size: CGFloat) -> NSFont { .monospacedDigitSystemFont(ofSize: size, weight: .medium) }
  }
  ```
  - Verify: `make build`.

- [x] **T-003 App shell** · SPEC §8
  - Files: replace `Sources/Recorder/main.swift` with `Sources/Recorder/App/main.swift` + `App/AppDelegate.swift`.
  - Do: `main.swift` = parse `--selftest` (T-004) else run `NSApplication` with `AppDelegate`. AppDelegate: `NSApp.appearance = NSAppearance(named: .darkAqua)`; build the main menu in code exactly as SPEC §8 (items may have `action: nil` for now — they get wired by later tasks); `applicationShouldTerminateAfterLastWindowClosed → false`; create `NSStatusItem` with menu `New Recording / Projects / Quit`.
  - Verify: `make run`. HUMAN: menu bar shows Recorder/File/Edit/Record/Export/View/Window; status item present; closing windows doesn't quit.

- [x] **T-004 Selftest harness**
  - File: `Sources/Recorder/App/SelfTest.swift`
  ```swift
  enum SelfTest {
      /// Register with: SelfTest.cases["name"] = { args in … throws }
      nonisolated(unsafe) static var cases: [String: ([String]) async throws -> Void] = [:]
      static func runIfRequested() // reads CommandLine.arguments; runs case; prints "SELFTEST <name> OK"; exit(0|1)
  }
  ```
  - Do: add case `metal` that compiles `"kernel void k(uint2 g [[thread_position_in_grid]]) {}"` with `makeLibrary(source:)`.
  - Verify: `make app && build/Recorder.app/Contents/MacOS/Recorder --selftest metal` → `SELFTEST metal OK`.

- [x] **T-005 Project model** · SPEC §5
  - File: `Sources/RecorderCore/Project.swift`. Test: `Tests/RecorderCoreTests/ProjectTests.swift`.
  - Do: `public struct Project: Codable, Equatable, Sendable` mirroring the JSON in SPEC §5 **field for field, same names**. Nested structs: `Source, Zoom, Layout, Mask, TimeRange, NormRect, NormPoint, Background, Frame, CursorStyle, Animation, Camera, Audio, Keys, Output`. String-backed enums for every `a|b|c` field. `Clip` already exists in `TimeMap.swift` — reuse it.
    Every struct has `init()` with the defaults shown in SPEC §5 and a custom `init(from:)` that uses `decodeIfPresent ?? default` for **every** key. Write one private helper and use it everywhere:
  ```swift
  extension KeyedDecodingContainer {
      func value<T: Decodable>(_ key: Key, default d: T) throws -> T { try decodeIfPresent(T.self, forKey: key) ?? d }
  }
  public static let currentVersion = 1
  public static func load(from url: URL) throws -> Project   // throws ProjectError.newerVersion if version > current
  public func save(to url: URL) throws                        // JSONEncoder [.prettyPrinted,.sortedKeys], Data.write(options:.atomic)
  ```
  - Tests (exactly these): `projectRoundTrip` (fully populated → encode → decode → equal) · `projectDefaultsFromMinimalJSON` (`{"version":1,"source":{…}}` decodes; `frame.padding == 0.08`) · `projectRejectsNewerVersion`.
  - Verify: `make test FILTER=project` · covers AC-PRJ-1, AC-PRJ-2.

- [x] **T-006 Event log model** · SPEC §4.8, §5
  - File: `Sources/RecorderCore/Events.swift`. Test in `ProjectTests.swift`.
  ```swift
  public struct InputEvent: Codable, Equatable, Sendable {
      public enum Kind: String, Codable, Sendable { case move, down, up, drag, scroll, key, typing, cursor }
      public var t: Double; public var k: Kind
      public var x: Double?; public var y: Double?     // normalised 0…1, top-left origin
      public var b: Int?                               // button
      public var keyCode: Int?; public var mods: UInt? // only for k == .key
      public var id: String?                           // cursor image hash for k == .cursor
  }
  public struct EventLog: Codable, Sendable { public var events: [InputEvent]
      public func moves() -> [InputEvent]; public func clicks() -> [InputEvent] }   // drag counts as move; clicks = left .down
  ```
  - Test: `eventLogRoundTrip`. Verify: `make test FILTER=eventLog`.

---

## M1 — Record  (SPEC §4.1–4.5, §4.8)

- [x] **T-101 Permissions** · SPEC §4.1
  - File: `Sources/Recorder/App/Permissions.swift`
  ```swift
  enum Permissions {
      static var screen: Bool { CGPreflightScreenCaptureAccess() }
      static var accessibility: Bool { AXIsProcessTrusted() }
      static func requestScreen() { CGRequestScreenCaptureAccess() }
      static func requestAccessibility() { AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) }
      static var allGranted: Bool { screen && accessibility }
  }
  ```
  - Selftest `permissions`: prints both booleans, always OK. Verify: run it.

- [x] **T-102 Onboarding window** · SPEC §4.1 mockup
  - File: `Sources/Recorder/App/OnboardingView.swift` (SwiftUI) — shown by AppDelegate in a 660×470 non-resizable `NSWindow` when `!Permissions.allGranted`.
  - Do: two rows + Continue, as the mockup. `Timer.publish(every: 1)` re-reads `Permissions`. Relaunch button (only if screen was just requested and still false after 5 s): `Process` launch `open -n <bundlePath>` then `NSApp.terminate`.
  - HUMAN: grant both permissions to `/Applications/Recorder.app` after `make install`; confirm AC-ONB-1/2/3.

- [x] **T-103 Floating panel base**
  - File: `Sources/Recorder/Recording/FloatingPanel.swift`
  ```swift
  /// Borderless, non-activating, above everything, on all Spaces, HUD material, radius 16. Every recording-flow window uses this.
  final class FloatingPanel: NSPanel {
      init(content: NSView, draggable: Bool)
      override var canBecomeKey: Bool { true }
      static var allWindowIDs: [CGWindowID] { get }   // every live FloatingPanel/overlay window number → used to exclude from capture
  }
  ```
  - Do: `styleMask [.borderless,.nonactivatingPanel]`, `level = .init(Int(CGShieldingWindowLevel()) - 1)`, `collectionBehavior [.canJoinAllSpaces,.fullScreenAuxiliary]`, `isMovableByWindowBackground = draggable`, content wrapped in `NSVisualEffectView(material: .hudWindow)` with `layer.cornerRadius = Theme.Radius.panel`. Keep a static weak list for `allWindowIDs`.
  - Verify: `make build` (exercised by T-104).

- [~] **T-104 Recording toolbar** · SPEC §4.2 mockup + menus
  - Files: `Recording/RecordingSettings.swift`, `Recording/ToolbarView.swift` (SwiftUI), `Recording/ToolbarController.swift`.
  ```swift
  @Observable final class RecordingSettings {          // persisted to UserDefaults on didSet, one key each
      enum Mode: String { case display, window, area }
      var mode: Mode; var cameraID: String?; var micID: String?
      enum SystemAudio: Codable { case off, all, apps([String]) }   // bundle ids
      var systemAudio: SystemAudio
      var denoise, disableAGC, hideDesktopIcons, hideDockIcon, highlightArea: Bool
      var countdown: Int                                  // 0,3,5,10
      static let shared = RecordingSettings()
  }
  ```
  - Do: toolbar = `HStack` of close · 3 mode buttons (SF Symbols `display`, `macwindow`, `rectangle.dashed`) · 3 input buttons · gear. Input buttons and gear pop a **native `NSMenu`** built in `ToolbarController` (`NSMenu.popUp(positioning:at:in:)`) with the exact items of SPEC §4.2; checkmarks from settings. Devices: `AVCaptureDevice.DiscoverySession` (`.video` / `.audio`); observe `AVCaptureDevice.wasConnectedNotification`/`wasDisconnected`. No "Device" button. `Esc` handling per AC-TB-4 via `cancelOperation(_:)`.
    Wire: status item "New Recording", `⌘N`, dock click (`applicationShouldHandleReopen`) → `ToolbarController.shared.show()`.
  - HUMAN: compare to the SPEC layout; AC-TB-2/3/4.
  - Visual deviations accepted by the user. Fixed stale saved camera/microphone IDs when reopening setup: validate
    against the same live discovery lists as the menus, falling back to Off before constructing the toolbar or
    requesting camera access. `device-selection` checks the shared restore decision without touching saved settings;
    menus/hotkeys/synthetic pickers/permission-refresh and all 129 Core tests pass. Physical hot-plug (AC-TB-2) and
    a real saved-selection relaunch (AC-TB-3) still require HUMAN evidence; the restore-decision test does not prove them.

- [x] **T-105 SelectionRectView (shared)** · SPEC §4.5, §6.7
  - File: `Sources/Recorder/Recording/SelectionRectView.swift` — used by area selection **and** the crop sheet. Build it once.
  ```swift
  final class SelectionRectView: NSView {
      var rect: CGRect                     // in view coords; didSet → needsDisplay + onChange
      var limit: CGRect                    // rect is clamped inside this
      var minSize = CGSize(width: 100, height: 100)
      var aspect: CGFloat?                 // locked aspect (crop presets); ⇧ locks current
      var onChange: ((CGRect) -> Void)?
  }
  ```
  - Do: draws 45% dim outside, dashed thirds inside, 8 round handles. Mouse: create / move / resize per SPEC §4.5 (⇧ aspect, ⌥ from centre), arrow keys nudge 1 px (⇧ = 10). Cursor rects for handles.
  - Verify: `make build`; exercised by T-108.

- [x] **T-106 CaptureTarget + content filter**
  - File: `Sources/Recorder/Recording/CaptureTarget.swift`
  ```swift
  enum CaptureTarget { case display(SCDisplay), window(SCWindow), area(SCDisplay, CGRect /* display points, top-left origin */) }
  extension CaptureTarget {
      func filter(content: SCShareableContent, settings: RecordingSettings) -> SCContentFilter
      func configuration(settings: RecordingSettings) -> SCStreamConfiguration
      var pixelSize: CGSize { get }; var scale: CGFloat { get }
      var frameInScreenPoints: CGRect { get }     // for normalising cursor positions
  }
  ```
  - Do: display/area → `SCContentFilter(display:excludingWindows:)` excluding every window whose `windowID ∈ FloatingPanel.allWindowIDs` (+ Finder desktop-icon windows when `hideDesktopIcons`, see SPEC open question 3); window → `SCContentFilter(desktopIndependentWindow:)`. Configuration exactly per SPEC §4.8 (`showsCursor=false`, 60 fps, `420v`, `queueDepth 6`, even-rounded size, `sourceRect` for area, audio + mic flags).
  - Verify: `make build`.

- [~] **T-107 Display & window pickers** · SPEC §4.3, §4.4 mockups
  - File: `Sources/Recorder/Recording/SourcePickerOverlay.swift`
  - Do: one borderless full-screen overlay window per `NSScreen` (same level as `FloatingPanel` − 1, registered in `allWindowIDs`). Content = SwiftUI: dim + title + size line + `Start recording` button (accent, with `⌄` countdown submenu). Display mode: active = screen under `NSEvent.mouseLocation` (tracking area). Window mode: on mouse move, hit-test `SCShareableContent.windows` (on-screen, `windowLayer == 0`, ≥100×100, not ours) front-to-back; draw accent tint + 2 px border on its frame; click selects. Convert `SCWindow.frame` (top-left origin, global) to the overlay's coords — write one `func flip(_ r: CGRect, in screen: NSScreen) -> CGRect` and reuse it in T-109.
    `Return` = start. Omit the `[Resize]` button until T-206.
  - HUMAN: AC-DSP-1 and AC-WIN-1 against the SPEC layout.
  - WAITING ON HUMAN: run `make run` (or `make install` yourself), select Display mode and Window mode from the toolbar, and confirm against the two reference screenshots — AC-DSP-1 (moving the mouse to another display moves the title/button there within one frame) and AC-WIN-1 (hover highlight tracks the front-most window under the cursor, including across displays). This machine has no Screen Recording/Accessibility TCC grants for this agent, so the overlays couldn't be visually driven or screenshotted here.
  - FIX 2026-09-18 (bug report: "window also it finds random windows" / "esc not working when i switched from one mode to another"): (1) window hit-test picked the first `SCShareableContent.windows` entry containing the mouse point, but that list isn't z-ordered — now ordered front-to-back via `CGWindowListCopyWindowInfo`, matched by `windowID` (`SourcePickerOverlay.frontToBackWindowIDs`/`frontmostWindow(at:order:frames:)`, covered by `--selftest pickers`); the window list also now re-polls every 1 s while the picker is open instead of a single fetch. (2) the hover hit-test point itself was double-flipped (`SourcePickerHostingView` is an `NSHostingView`, always top-left-origin/flipped — confirmed with a standalone `swift` snippet printing `isFlipped: true` — but `moved(to:)` treated its local point as bottom-left AppKit coords), mirroring the point vertically within the screen; now uses `NSEvent.mouseLocation` directly via `SourcePickerOverlay.cgGlobalPoint(_:)`. (3) `SourcePickerWindow` never forced first responder onto its `NSHostingView` on `makeKeyAndOrderFront` (same bug `FloatingPanel` already documents and works around) — confirmed with a standalone script: without the override `window.firstResponder === window` after `makeKeyAndOrderFront`, so `Esc`'s `cancelOperation` never reached anything; fixed with the same override `FloatingPanel`/`AreaSelectionWindow` use. (4) `Esc`'s handler called `ToolbarController.shared.show()` to re-key the toolbar, but `show()` *also* re-opens the current mode's overlay — so closing on `Esc` instantly reopened it. All `cancelOperation` overrides (toolbar + both overlays) now call one new `ToolbarController.handleEscape()` that closes the open overlay and re-keys the toolbar panel directly (no reopen), or closes the toolbar if nothing was open. Re-check AC-WIN-1 and AC-TB-4 (Esc after switching modes) against the reference screenshots.

- [~] **T-108 Area overlay** · SPEC §4.5 mockup
  - File: `Sources/Recorder/Recording/AreaSelectionOverlay.swift`
  - Do: overlay window on the display under the mouse hosting `SelectionRectView` + a small `FloatingPanel` with the Size/Position fields (SwiftUI `TextField(value:format:.number)`), two-way bound to `rect`. Remember last rect per display in `UserDefaults` keyed by `CGDirectDisplayID`. Start button below the toolbar.
  - HUMAN: AC-AREA-1 against the SPEC layout.
  - WAITING ON HUMAN: run `make run` (or `make install`), select Area mode from the toolbar, and confirm the SPEC behavior (AC-AREA-1) — drag-to-create, move, resize by all 8 handles, ⇧ (aspect lock) and ⌥ (resize from centre), arrow-key nudge (1 px / 10 px with ⇧), the Size/Position fields staying in sync both ways, the Start button below the toolbar, and that the last rect is remembered per display across reopen. This machine has no Screen Recording/Accessibility TCC grants for this agent, so the overlay couldn't be visually driven here.
  - FIX 2026-09-18 (bug report: "drag selection is wonky" / "esc not working when i switched from one mode to another"): root cause in the shared `SelectionRectView.resized(from:handle:mouse:option:aspect:)` (`Sources/Recorder/Recording/SelectionRectView.swift`) — `minSize` (100×100) was enforced after the fact by `clamp(_:to:limit:minSize:)`, which always grew a too-small rect by pinning `(minX, minY)` and pushing `(maxX, maxY)` outward; correct only for a `topRight`-anchored drag, but rect *creation* (and every other handle) anchors at a different corner, so the fixed/anchor corner silently dragged along with the mouse instead of staying put — confirmed by temporarily reverting the fix and re-running `--selftest pickers`, which failed with the anchor corner moving from `(700,700)` to `(700,800)` on a create-drag that stayed under 100×100. Fixed by enforcing `minSize` per dragged edge inside `resized(...)`, keeping the true anchor (the corner at `mouseDown`) fixed; `clamp` now only clips to the display bounds. Also guarded `AreaSelectionState.apply` (the Size/Position-field → `rect` path) to no-op while `SelectionRectView.isDragging`, so a field commit can't land mid-drag and fight the mouse. Esc: same root cause and fix as T-107 (see its FIX note) — `AreaSelectionWindow`/`AreaFieldsHostingView.cancelOperation` now both call the shared `ToolbarController.handleEscape()`. New permanent selftest `--selftest pickers` covers the create/resize drag math (`SelectionRectView`) and the window hit-test ordering (`SourcePickerOverlay`, T-107). Re-check AC-AREA-1 and Esc against the reference screenshot.

- [x] **T-109 EventRecorder** · SPEC §4.8
  - File: `Sources/Recorder/Recording/EventRecorder.swift`
  ```swift
  final class EventRecorder {
      init(target: CaptureTarget, cursorsDir: URL)
      func start(t0HostTime: CMTime)          // call when the first screen frame arrives
      func pause(); func resume()             // accumulates pausedSoFar
      func stop() -> EventLog
  }
  ```
  - Do: `CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask, …)` on a dedicated thread's run loop. `t = hostSeconds(event.timestamp) − t0 − pausedSoFar` (convert mach ticks with `mach_timebase_info`). Position: `event.location` (global, top-left) → normalised against `target.frameInScreenPoints`; for `.window` re-read the window frame at 10 Hz.
    **Keys:** store `.key` only if ⌘/⌃/⌥ is down or the key is non-printing (arrows, return, esc, tab, delete, F-keys). Otherwise store `.typing` with **no keyCode**. This is a privacy rule; do not relax it.
    Cursor: 60 Hz `DispatchSourceTimer` reads `NSCursor.currentSystem`; hash `tiffRepresentation` (SHA256 via CryptoKit, first 8 hex); new hash → write largest rep as `cursors/<id>.png` + `<id>.json` `{hotX,hotY,scale}`; emit `.cursor`. Coalesce `.move` closer than 1/240 s.
  - Selftest `events 3`: records 3 s into a temp dir, prints counts per kind; OK if ≥1 cursor image exists. HUMAN: wiggle the mouse while it runs.

- [x] **T-110 CaptureSession (screen + audio writers)** · SPEC §4.8
  - File: `Sources/Recorder/Recording/CaptureSession.swift`
  ```swift
  final class CaptureSession: NSObject, SCStreamOutput, SCStreamDelegate {
      init(target: CaptureTarget, settings: RecordingSettings, packageURL: URL) async throws
      func start() async throws
      func pause(); func resume()
      func finish() async throws -> Project.Source     // stops stream, finishes writers, returns measured duration/size
      func cancel() async                                // stop + delete packageURL
      private(set) var elapsed: Double                    // for the widget
  }
  ```
  - Do: one private `final class TrackWriter { init(url:, videoSettings|audioSettings); func append(_ sb: CMSampleBuffer, offset: CMTime); func finish() async }` wrapping `AVAssetWriter` + one input (`expectsMediaDataInRealTime = true`, `movieFragmentInterval = 10 s`). Three instances: `screen.mov` (HEVC, bitrate `min(60e6, w*h*4)`), `system.m4a`, `mic.m4a` (AAC 48 k/192 k).
    In `stream(_:didOutputSampleBuffer:of:)`: for `.screen` skip unless attachment `SCStreamFrameInfo.status == .complete`; first complete frame sets `t0` and calls `eventRecorder.start(t0HostTime:)`; retime every buffer with `CMSampleBufferCreateCopyWithNewTiming` to `pts − t0 − pausedSoFar`. While paused drop buffers; on resume add the gap to `pausedSoFar`.
    Add outputs for `.screen`, `.audio`, `.microphone` on one serial queue. `// ponytail: one queue for all three outputs; split if audio ever drops.`
  - Selftest `record display 3`: records main display 3 s to a temp package; asserts `screen.mov` has a video track, duration 2.5–3.5 s, size == display pixels, `events.json` exists. Verify: run it (needs T-102 HUMAN done).

- [~] **T-111 Recording flow glue**
  - WAITING ON HUMAN: built + merged. Record 10 s of a display, a window and an area → each package has a playable cursor-less `screen.mov` (AC-AREA-2, AC-WIN-3); countdown 3/5/10 + Esc (T-202); camera selected → `camera.mov` present (T-201).
  - LIVE COMPONENT VERIFIED (v0.3.2 via LaunchServices): `record-windows 3 10` captures only three test-owned animated
    windows, decodes their centre colors, checks all sizes and durations/shared clock (±0.75 s), and records each
    window's metadata. Mean CPU 0.9% of one core. Mic/system audio disabled for the check; saved settings restored and
    temporary media removed. This calls CaptureSession directly, not RecordingController.begin/finish: it does not
    complete the full three-mode/controller/editor handoff, cursor-exclusion, camera or countdown HUMAN gate.
  - File: `Sources/Recorder/Recording/RecordingController.swift`
  ```swift
  @MainActor final class RecordingController {
      static let shared = RecordingController()
      enum State { case idle, picking, countdown, recording, paused, finishing }
      private(set) var state: State
      func begin(target: CaptureTarget)     // from pickers' Start button
      func finish(); func cancel()
  }
  ```
  - Do: `begin` → close overlays/toolbar → create `~/Movies/Recorder/Recording <yyyy-MM-dd HH.mm.ss>.recorder/` → `CaptureSession.start`. `finish` → `CaptureSession.finish` → write `events.json` → build `Project` (source, one clip `0…duration`, defaults) → `project.save` → for now `NSWorkspace.shared.activateFileViewerSelecting([package])` (editor arrives in M3). Minimal stop UI for M1: status item title shows `● mm:ss`, its menu gains `Finish Recording`.
  - Verify: HUMAN records 10 s of a display, a window and an area; each package opens in Finder ("Show Package Contents") with playable `screen.mov` **without a cursor**; AC-AREA-2, AC-WIN-3.

- [~] **T-112 Highlight recorded area**
  - WAITING ON HUMAN: outline visible while recording an area/window, absent from `screen.mov` (AC-TB-1).
  - Do (in `RecordingController`): when `highlightArea` and target is area/window: a click-through overlay window (`ignoresMouseEvents = true`, in `allWindowIDs`) drawing a 2 px accent outline 2 px outside the rect. Remove on finish.
  - HUMAN: outline visible while recording, absent in `screen.mov`. AC-TB-1.

- [~] **T-113 Crash-safe recording** · AC-REC-3
  - WAITING ON HUMAN: `--selftest recover` OK (synthetic orphan package). Human: start recording, `pkill -9 Recorder`, relaunch → project.json exists, screen.mov plays (AC-REC-3).
  - Do: on launch scan the projects folder for packages that have `screen.mov` but no `project.json`; for each, build the default `Project` from the asset's duration/size and save it. (Fragmented writing from T-110 makes the `.mov` readable.)
  - HUMAN: start a recording, run `pkill -9 Recorder`, relaunch: `project.json` now exists in the package and `screen.mov` plays.

- [~] **T-114 M1 performance gate** · AC-REC-1
  - WAITING ON HUMAN: current release build 241 preflight via LaunchServices reports `screen=false accessibility=false`.
    This Apple M1 session has a 1920×1080 logical/pixel display at 60 Hz, not the required 1440×900@2x (2880×1800).
    No recording was started, no permission was requested/reset, and display settings were not changed.
    Display capture requests 60 fps + `420v`; its writer requests HEVC, but configuration alone does not prove
    hardware encoder use or sustained frame delivery. The existing `record-perf` diagnostic checks average CPU,
    not the <1% frame-loss gate, and an idle desktop run is not acceptance evidence.
    On a matching display with Recorder permissions granted, record 10 min of continuously animating content;
    report actual resolution/duration, average Recorder CPU in Activity Monitor (<25% of one core), delivered frames
    versus duration × 60 (<1% missing), and codec/hardware evidence. `ffprobe` is not installed here; QuickTime
    Inspector is the plan-listed alternative. Current preflight/display logs: `/tmp/recorder-t114-{permissions,displays}.log`.
  - HUMAN: record 10 min of the display at 60 fps; Activity Monitor CPU < 25% of one core; `ffprobe`/QuickTime inspector shows ≥ 99% of expected frames when content is animating. Record the numbers in §Log. If it fails: check `pixelFormat` is `420v` and the writer is HEVC hardware (`AVVideoCodecType.hevc`), nothing else.

---

## M2 — Record+  (SPEC §4.6, §4.7, §4.4 resize)

- [~] **T-201 Camera capture + bubble** · SPEC §4.6
  - WAITING ON HUMAN: built + merged (lane-capture). Select a camera in the toolbar → bubble appears, drags, snaps to corners; AC-CAM-1 (bubble never in `screen.mov`) and the AC-CAM-2 clap test need T-111 recording flow first.
  - Files: `Recording/CameraCapture.swift`, `Recording/CameraBubblePanel.swift`.
  - Do: `AVCaptureSession` (preset `.high`) with the selected device; `AVCaptureVideoPreviewLayer` in a 200×200 `FloatingPanel` (mirrored via `connection.isVideoMirrored`, `cornerRadius 40`, `cornerCurve .continuous`), draggable, snaps to the nearest corner (24 pt margin) on mouse-up. `AVCaptureVideoDataOutput` → a fourth `TrackWriter` (`camera.mov`, H.264) using the **same** `t0`/`pausedSoFar` as `CaptureSession` (expose them). Buffers before `t0` are dropped. Store the bubble's final corner into `project.camera.corner`.
  - HUMAN: AC-CAM-1; clap test for AC-CAM-2 (compare `camera.mov` and `mic.m4a` in QuickTime).

- [~] **T-202 Countdown** · SPEC §4.7 — File `Recording/CountdownOverlay.swift`. SwiftUI number in a panel centred on the target rect, scale+fade per second, `Esc` cancels back to the picker. `RecordingController.begin` awaits it when `countdown > 0`.
  - PARTIAL: `CountdownOverlay.run(seconds:over:) async -> Bool` merged; `RecordingController.begin` must await it (T-111), then HUMAN check.
  - HUMAN: 3/5/10 work; Esc cancels.

- [~] **T-203 Recording widget** · SPEC §4.7 mockup — File `Recording/RecordingWidgetPanel.swift`. `FloatingPanel` with timer (`Theme.timecodeFont`), Finish / Pause⇄Resume / Restart / Delete (confirm alert). Right-click → Hide. Replaces the M1 status-item-only UI (status item keeps the same actions).
  - WAITING ON HUMAN/UI-driver: merged. Widget appears at record start (shown BEFORE the capture filter snapshot so it is excluded), Finish/Pause/Restart/Delete (confirm alert, default = Keep Recording); AC-REC-2 pause test.
  - HUMAN: AC-REC-2 (pause 5 s: duration excludes it, no audio click, cursor aligned later in M4).

- [~] **T-204 Global hotkeys** — File `App/Hotkeys.swift` (do not reuse `EventRecorder`'s tap; it only lives while recording): `NSEvent.addGlobalMonitorForEvents(matching: .keyDown)` + local monitor; one `[(keyCode, mods, action)]` table matching every global default of SPEC §4.7: `⌃⌥⌘R` (start: show toolbar / finish), `⌃⌥⌘P` (pause/resume), `⌃⌘↩` (toolbar), `⌥⌘3/4/5` (toolbar + display/window/area picker), `⌥⌘Z` (open last project — no-op until T-207b wires it). All but R/P are ignored while recording (AC-APP-4). `// ponytail: fixed bindings; rebinding UI is T-609.`
  - WAITING ON HUMAN: `--selftest menus` validates the hotkey table; hotkeys while another app is focused need a human (AC-APP-4).
  - HUMAN: hotkeys work while another app is focused.

- [~] **T-205 Hide dock icon / desktop icons** — `NSApp.setActivationPolicy(.accessory)` on start, `.regular` on finish. Desktop icons: answer SPEC open question 3 empirically (list `SCShareableContent.windows` where `owningApplication?.bundleIdentifier == "com.apple.finder"` and inspect `windowLayer`/title), exclude them, **write the answer into SPEC §9**.
  - WAITING ON HUMAN: SPEC §9 Q3 answered empirically (one Finder window at desktop-icon level); eyeball both toggles in a real recording.
  - HUMAN: both toggles behave.

- [~] **T-206 Window resize presets** · SPEC §4.4 menu — File `Recording/WindowResizer.swift`: `static func resize(pid: pid_t, windowTitle: String?, to: CGSize)` via `AXUIElementCreateApplication` → `kAXWindowsAttribute` → match by title/frame → set `kAXSizeAttribute`. Add the `[Resize]` `NSMenu` to the window picker; sizes larger than the screen are disabled; saved sizes in `UserDefaults`; `Custom…` = `NSAlert` with two text fields.
  - HUMAN: AC-WIN-2.
  - WAITING ON HUMAN: run `make run` (or `make install`), select Window mode, hover a window, click `[Resize]` next to its size (SPEC §4.4 mockup — same row as "1440 × 834"), and confirm: choosing a quick/ratio-submenu preset actually resizes the real window and the on-screen highlight + size label immediately reflect its new frame; any preset larger than that window's display is greyed out/disabled; `Custom…` opens an `NSAlert` with Width/Height fields and resizes + remembers that size; "Save current size" and previously-saved sizes appear in the menu across reopen. This machine has no Screen Recording/Accessibility TCC grants for this agent (`--selftest permissions` → `screen=false accessibility=false`), so the picker/menu couldn't be visually driven or a real window resized here.
  - HUMAN: AC-WIN-2.

- [~] **T-207 Settings window (minimal)** · SPEC §8 — File `App/SettingsView.swift`: SwiftUI `Form` with General (projects folder via `NSOpenPanel`) and Recording (fps 30/60, countdown, 3 toggles) bound to `RecordingSettings`. `⌘,`.
  - HUMAN: values persist across relaunch.
  - WAITING ON HUMAN: confirm `⌘,` (main menu) and the toolbar gear menu's "Settings…" item both open the Settings window, and that projects-folder/fps/countdown/toggle changes persist across a relaunch.

- [~] **T-207b Status-item menu** · SPEC §8 — in `AppDelegate`: rebuild the idle status menu exactly as SPEC §8 (SF Symbols `record.circle`, `display`, `macwindow`, `rectangle.dashed`; key equivalents as listed). `Record Display/Window/Area` = `RecordingSettings.shared.mode = …` + `ToolbarController.shared.show()` + open that picker (reuse what the toolbar mode buttons call — one function, also used by T-204's table). `Show Recorder in Dock` = one persisted `Bool` → `NSApp.setActivationPolicy`, per the §8 rule. `Open Last Project` = newest `*.recorder` by modification date in the projects folder (opens in Finder until the editor exists in M3, then the editor). Main-menu File items reuse the same selectors.
  - WAITING ON HUMAN: `--selftest menus` OK (titles/order/key equivalents vs SPEC §8/§4.7, targets set); visual check against the SPEC.
  - HUMAN: menu matches the mockup; AC-APP-4.

- [~] **T-208 M2 gate** — HUMAN: full pass of SPEC §4 mockups vs the app; list deviations in §Log.
  - WAITING ON HUMAN: release build 241 passes `menus`, synthetic `pickers`, injected `permission-refresh` and
    isolated `hotkeys`. Current native review renders: `/tmp/recorder-t208-{toolbar,onboarding,settings}.png`.
    These are layout specimens, not proof of live source selection, capture exclusion, camera/mic sync, countdown
    cancellation, recording-widget actions, other-app hotkeys, real window resizing or settings persistence.
    Read-only LaunchServices preflight still reports `screen=false accessibility=false`; no grant/reset or capture
    was attempted. Picker-opening tests were not run because their live content enumeration can request access.
    HUMAN: walk SPEC §4.1–§4.7 with real inputs/recordings and report deviations (or explicit approval), including
    the camera clap/exclusion checks, 3/5/10 s countdown + Escape, five-second pause, resize presets and relaunch.
    Current visual direction is documented in `docs/UI-KIT.md`; unavailable FUI boards were not reviewed, and no
    human visual approval is inferred from the successful renders. M2 remains 0/9 until its HUMAN checks pass.

---

## M3 — Editor shell  (SPEC §5.1, §6.1, §6.2, §6.6 Background, §6.7)

- [x] **T-301 ProjectStore** · SPEC §5.1
  - File: `Sources/Recorder/Library/ProjectStore.swift`
  ```swift
  @Observable final class ProjectStore {
      struct Item: Identifiable { let id: URL; var title: String; var duration: Double; var modified: Date; var thumbnail: NSImage? }
      private(set) var items: [Item]
      var folder: URL                                    // default ~/Movies/Recorder, from Settings
      func reload()                                      // background scan of *.recorder, sorted by modified desc
      func rename(_ url: URL, to: String) throws; func duplicate(_ url: URL) throws; func trash(_ url: URL) throws
  }
  ```
  - Do: `DispatchSource.makeFileSystemObjectSource` on the folder → `reload()`. Rename moves the package dir **and** sets `project.title`. Trash = `FileManager.trashItem`. Thumbnail: `AVAssetImageGenerator` at 1 s → `thumbnail.jpg` written once (during `RecordingController.finish`).
  - Selftest `library`: creates 3 fake packages in a temp folder, asserts order, rename, duplicate, trash.

- [~] **T-302 Library window** · SPEC §5.1 mockup — File `Library/LibraryView.swift`: `LazyVGrid(.adaptive(minimum: 220))`, search field, context menu, inline rename, empty state, `New Recording` button. Open on launch (when permissions OK) and `⇧⌘O`. Document open: `application(_:open:)` for `.recorder` packages; already-open project → focus its window.
  - WAITING ON HUMAN: built + merged; coordinator checked the offscreen render (`--selftest library-png`) against the §5.1 mockup. Human: AC-LIB-2 (rename/duplicate/trash ↔ Finder), AC-LIB-3 (double-click a `.recorder` package) — AC-LIB-3's editor half needs T-307; `Library.open` has the marked hand-off line.
  - HUMAN: AC-LIB-2, AC-LIB-3.

- [x] **T-303 EditorModel (state + undo + autosave)** · SPEC §2 "Undo", §5 "Autosave"
  - File: `Sources/Recorder/Editor/EditorModel.swift`
  ```swift
  @MainActor @Observable final class EditorModel {
      let packageURL: URL
      private(set) var project: Project
      let events: EventLog
      var playhead: Double = 0            // OUTPUT seconds
      var isPlaying = false
      var selection: Set<UUID> = []       // zoom/layout/mask ids
      var selectedClip: Int?
      var timeMap: TimeMap { TimeMap(project.clips) }

      /// The ONLY way to mutate `project`. One call = one undo step.
      func edit(_ name: String, _ change: (inout Project) -> Void)
      /// For drags: begin → many `update` → commit | cancel. One undo step total.
      func beginGesture(); func update(_ change: (inout Project) -> Void); func commitGesture(_ name: String); func cancelGesture()
      func undo(); func redo()
      func saveNow()
  }
  ```
  - Do: undo/redo = two `[Project]` stacks (cap 200). `// ponytail: whole-struct snapshots; Project is a few KB.` Autosave: cancel+reschedule a 0.5 s `DispatchWorkItem` on every mutation → `project.save`; also on window close and `applicationWillTerminate`. SwiftUI sliders use `beginGesture/commitGesture` through `onEditingChanged`.
  - Selftest `model`: edit → undo → redo equality; gesture with 10 updates = 1 undo step; file on disk updated after 0.6 s. (AC-INS-2, AC-PRJ-3 partially.)

- [x] **T-304 Shaders + Compositor v1 (background, frame, shadow, crop, aspect)** · SPEC §6.2 passes 1–2
  - Files: `Sources/Recorder/Render/Shaders.swift` (one `let shaderSource = """ … """`), `Render/Compositor.swift`, `Render/FrameState.swift`.
  ```swift
  struct FrameState {                       // built by pure code; the compositor never reads EditorModel
      var outputSize: CGSize
      var screen: MTLTexture?; var camera: MTLTexture?
      var view: ViewTransform; var prevView: ViewTransform      // {center: NormPoint, scale: Double}; identity for now
      var cursor: CursorSample?                                  // nil until T-412
      var project: Project
  }
  final class Compositor {
      init(device: MTLDevice) throws                              // makeLibrary(source: shaderSource)
      func render(_ s: FrameState, to target: MTLTexture, commandBuffer: MTLCommandBuffer)
      func outputSize(for project: Project, longEdge: Int) -> CGSize   // aspect: auto = cropped source aspect
  }
  ```
  - Shader: one vertex fn (unit quad + per-draw uniforms: rect in NDC, uv rect) and one fragment fn with `mode` uniform (0 colour, 1 gradient, 2 texture, 3 rounded-texture-with-shadow). Rounded rect + shadow = SDF:
    `float d = length(max(abs(p) - halfSize + r, 0.0)) - r;` alpha = `1 - smoothstep(-1, 1, d)`; shadow = `shadowAlpha * (1 - smoothstep(0, blurPx, d_offset))` drawn in the same quad (quad is enlarged by `blurPx`).
    Layout math (put in `RecorderCore/Layout.swift`, pure, tested): `screenRect(output:, cropAspect:, padding:) -> CGRect` = largest rect of the crop aspect inside output inset by `padding × min(w,h)`. Test `layoutFitsAndCentres`.
    Background kinds: colour, gradient (2 stops + angle), wallpaper/image (texture loaded with `MTKTextureLoader`, aspect-fill UVs); blur via `MPSImageGaussianBlur` once per change, cached.
  - Selftest `render <package> <out.png>`: renders output frame 0 at 1920 long edge to PNG; OK if file exists and the centre pixel ≠ the corner pixel.
  - HUMAN: open the PNG — rounded corners, shadow, padding, background look like SPEC §6.1's preview.

- [x] **T-305 FrameSource + composition**
  - File: `Sources/Recorder/Render/FrameSource.swift`
  ```swift
  /// Builds the AVMutableComposition from project.clips (insertTimeRange + scaleTimeRange per clip) for screen, camera, mic, system.
  func makeComposition(package: URL, project: Project) async throws -> (AVMutableComposition, AVAudioMix)
  final class TextureCache { init(device:); func texture(from pb: CVPixelBuffer) -> MTLTexture? }   // CVMetalTextureCache; 420v → two planes, convert in shader (mode 4: biplanar YCbCr → RGB, BT.709)
  ```
  - Do: composition tracks: video[0]=screen, video[1]=camera, audio[0]=mic, audio[1]=system; volumes/mutes → `AVMutableAudioMixInputParameters`; `audioTimePitchAlgorithm = .spectral`.
  - Verify: used by T-306; selftest `composition <package>` prints composition duration == `TimeMap.outputDuration` ± 1/60.

- [~] **T-306 PreviewView + transport** · SPEC §6.1, §6.2 "Preview"
  - WAITING ON HUMAN: merged; `--selftest preview-frame` OK and PNG reviewed (real 420v frame, correct colours, rounded/shadowed). Human: AC-ED-1, AC-ED-3 in the editor (`Recorder --open <package>`).
  - File: `Sources/Recorder/Editor/PreviewView.swift` (`MTKView`, `isPaused = true`, `enableSetNeedsDisplay = true`).
  - Do: `AVPlayer` + `AVPlayerItemVideoOutput` (one per video track via `AVPlayerItem.add`; request `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`). `CADisplayLink` (from `NSView.displayLink(target:selector:)`) while playing → `model.playhead = player.currentTime` → `needsDisplay`. `draw`: `copyPixelBuffer(forItemTime:)` (keep last buffer if nil) → `FrameState` → `Compositor.render` to `currentDrawable`. Observe `model.project` → redraw. Seek: coalesce (`isSeeking` flag + `pendingTime`), `toleranceBefore/After: .zero`. Clip edits → rebuild composition, `replaceCurrentItem`, restore playhead. Letterbox with `Theme.bgWindow`.
    Transport bar (SwiftUI under the preview) + keys `Space ← → ⇧← ⇧→ Home End J K L`.
  - HUMAN: AC-ED-1, AC-ED-3.

- [~] **T-307 Editor window** · SPEC §6.1 mockup — File `Editor/EditorWindowController.swift`: `NSSplitView`-free manual layout (preview | 300 pt inspector) over a timeline placeholder (`NSView`, 220 pt, height draggable 160–420). Top bar in the titlebar (`NSTitlebarAccessoryViewController`): `‹ Projects`, title (click = rename), aspect `NSPopUpButton`, Crop, Export (disabled until M5). `RecordingController.finish` and the library now open this window instead of Finder.
  - WAITING ON HUMAN: merged; layout vs §6.1 mockup, AC-REC-4. Inspector/timeline/library/finish hand-offs wired by the integration pass.
  - FIX (T-311, 2026-09-18): the top bar rendered completely empty (coordinator caught it with a real on-screen screenshot) — `NSTitlebarAccessoryViewController` never reliably sized the wide bar in this environment; replaced with `.fullSizeContentView` + the bar as a manually-positioned `EditorRootView` subview. Root-cause story and the (now-not-`NSTitlebarAccessoryViewController`) top-bar code live in `EditorWindowController.swift`. Still not HUMAN-confirmed on a real screen (see T-311's Log entry) — re-check needed alongside this task's existing HUMAN items.
  - HUMAN: layout matches the mockup; AC-REC-4 (editor visible < 2 s after Finish); the top-bar fix above.

- [~] **T-308 Inspector shell + Background tab** · SPEC §6.6 — Files `Editor/Inspector/InspectorView.swift`, `Inspector/BackgroundTab.swift`, `Inspector/LabeledSlider.swift`.
  - WAITING ON HUMAN: `--selftest inspector` OK (1 drag = 1 undo step, autosave); coordinator reviewed `inspector-png` vs §6.6. Human: AC-INS-1 once hosted in the editor window (T-307). Known gap: system `.heic` wallpapers fall back to flat colour until Compositor loads absolute paths.
  - Do: `LabeledSlider(title:, value: Binding<Double>, range:, default:, format:)` — the **only** slider component: label left, value right (double-click to type), ⌥-click resets, wraps `model.beginGesture/commitGesture`. Tab bar with 6 SF Symbol buttons (`1`–`6` keys); non-implemented tabs show `Text("Coming in M4/M5")`. Background tab: kind picker, wallpaper grid (bundled `Resources/Wallpapers/*.jpg` + `/System/Library/Desktop Pictures/*.heic` thumbnails), `ColorPicker`s, image `NSOpenPanel` (copy file into the package as `background.<ext>`), Blur/Padding/Corners/Inset/Shadow sliders.
    Wallpapers: generate 12 abstract gradient JPEGs with a throwaway selftest `make-wallpapers` (Core Image `CILinearGradient`/`CIRadialGradient` blends) and commit them. Update the Makefile `app` target: `cp -R Resources/Wallpapers $(APP)/Contents/Resources/`.
  - HUMAN: AC-INS-1 for every Background control.

- [~] **T-309 Output aspect** — `Compositor.outputSize` honours `project.output.aspect`; popup in the top bar edits it. Test in Core: `layoutAspects` (9:16 output with 16:10 source keeps source aspect inside padding). HUMAN: switching aspect re-letterboxes instantly.
  - WAITING ON HUMAN: `Compositor.outputSize(for:longEdge:)` now delegates to the Core function; the top-bar `Auto ▾` popup edits `project.output.aspect` through `model.edit("Aspect")` (one undo step) and stays in sync with undo/redo via `withObservationTracking`. Human: confirm switching aspect re-letterboxes the *preview canvas* instantly (AC-ED-1) — not verifiable headlessly since the preview needs a live editor window + real capture.

- [~] **T-310 Crop sheet** · SPEC §6.7 mockup — File `Editor/CropSheet.swift`. Sheet window hosting the current source frame (`AVAssetImageGenerator` at playhead's source time) under a `SelectionRectView` (reuse T-105; pass `aspect` for presets). Fields in source pixels. Confirm = one `model.edit("Crop")`; Discard/Esc = nothing.
  - WAITING ON HUMAN: merged + wired to the top-bar Crop button; `--selftest crop` OK (mapping round-trip, Confirm = 1 undo step, Discard = no change); `crop-png` reviewed. Human: AC-CROP look against the dark-app SPEC.
  - HUMAN: AC-CROP-1 against the SPEC.

- [x] **T-311 Menu wiring** — connect File/Edit/View items that now have targets (Open, Projects, Save, Save As = copy package, Show Raw Files = reveal in Finder, Undo/Redo, Crop, tabs). Items without a target stay disabled automatically (`validateMenuItem`).
  - DONE: File ▸ Save/Save As…/Show Raw Files, Edit ▸ Undo/Redo/Split/Remove/Add Zoom/Regenerate Auto Zooms/Remove All Zooms/Restore All Cuts/Speed Up Typing/Hide Cursor in Selected Clip, View ▸ tabs 1–6 (real names)/Zoom In/Zoom Out/Fit/Crop… all wired on `EditorWindowController` with `target = nil` (responder chain) + `validateMenuItem` (`NSMenuItemValidation`); View ▸ Command Menu… ⌘K / Keyboard Shortcuts ⌘/ wired on `AppDelegate` (SPEC §8 has no Help menu to put them in, so both went in View's last group, per the coordinator's instruction — SPEC §8 updated to match). Also fixed, root cause, a live bug the coordinator found while reviewing this task (T-307): the titlebar top bar rendered completely empty — `NSTitlebarAccessoryViewController` with `.layoutAttribute = .right` never reliably sized the wide multi-control bar in this environment; replaced with `window.styleMask.contains(.fullSizeContentView)` + the bar as one more manually-positioned subview of `EditorRootView` (see `EditorWindowController.swift`'s top-bar section for the full story, including a second bug the same diagnostic-tint technique caught: a same-class `didSet` relay silently never fires when assigned from inside that class's own initializer).

- [x] **T-312 Library perf** · AC-LIB-1 — selftest `library-perf`: 200 fake packages, `reload()` < 300 ms. If slower: make sure only `project.json` + `thumbnail.jpg` are read.

- [~] **T-313 M3 gate** — HUMAN: record → editor opens → change every Background control → quit → reopen: identical (AC-INS-1, AC-PRJ-3 by `pkill -9` mid-edit).
  - VERIFIED: `background-persistence` opens real editors, exercises slider bindings/all backdrop kinds, flushes through app termination, reopens with identical project/rendered pixels, and SIGKILLs only owned children before/after autosave. Background replacement now retains immutable copies for undo and rejects corrupt images without changing files/project/history. Visual deviations accepted by the user; live recording → editor handoff remains unverified on the current permission-denied build, not a visual release blocker.

---

## M4 — Timeline  (SPEC §6.3–6.5, §7 — read §7 fully before T-404)

Core first (T-401…T-403, T-410…T-412 are pure + tested), then the view.

- [x] **T-401 TimelineOps: clips** · SPEC §7.4
  - File: `Sources/RecorderCore/TimelineOps.swift`. Tests: `Tests/RecorderCoreTests/TimelineOpsTests.swift`.
  ```swift
  public enum Edge: Sendable { case leading, trailing }
  public extension Project {
      mutating func split(atOutput t: Double, fps: Double = 60) -> Bool     // false if within 2 frames of a clip edge
      mutating func removeClip(_ i: Int) -> Bool                            // false if it is the last clip
      mutating func trimClip(_ i: Int, edge: Edge, toSource s: Double)      // clamps: neighbour's source boundary, min 0.1 s, 0…duration
      mutating func restoreCut(afterClip i: Int)                            // i = -1 → restore head; merges with neighbour when speeds match
      mutating func restoreAllCuts()
      mutating func setSpeed(_ i: Int, _ speed: Double)                     // clamp 0.25…16
      func clipIndex(atOutput t: Double) -> Int?
      func checkInvariants() -> String?                                     // nil = OK; message otherwise
  }
  ```
  - Invariants (SPEC §7.4): clips sorted by `sourceStart`, non-overlapping, each ≥ 0.1 s, speed 0.25…16, count ≥ 1. Every mutating op ends with `assert(checkInvariants() == nil)`.
  - Tests (exactly): `splitProducesTwoClipsSameSpeed` · `splitNearEdgeRefused` · `removeLastClipRefused` · `trimClampsToNeighbour` · `splitRemoveRestoreIsIdentity` (AC-TL-2) · `randomOpsKeepInvariants` (seeded `SystemRandomNumberGenerator` replacement: write a 5-line LCG; 1 000 iterations; AC-TL-1).

- [x] **T-402 TimelineOps: zooms & generic blocks**
  ```swift
  public extension Project {
      mutating func addZoom(atSource s: Double, length: Double = 3, mode: Zoom.Mode) -> UUID?   // fits into the free gap; nil if gap < 0.5 s
      mutating func moveZoom(_ id: UUID, toStart s: Double)             // clamps against neighbours and 0…duration
      mutating func resizeZoom(_ id: UUID, edge: Edge, to s: Double)    // min 0.5 s, no overlap
      mutating func removeBlock(_ id: UUID)                             // zoom, layout or mask
  }
  public func snap(_ x: Double, candidates: [Double], threshold: Double) -> (value: Double, snapped: Bool)
  ```
  - Layout/mask blocks get the same three ops — implement **once** over a private `protocol TimedBlock { var id: UUID; var start: Double; var end: Double }` that `Zoom`, `Layout`, `Mask` adopt (three conformers ⇒ allowed), with `minLength` parameter (0.5 s).
  - Tests: `zoomsNeverOverlap` (random moves/resizes, 1 000 iters) · `addZoomFitsGap` · `snapPicksNearest`.

- [x] **T-403 Spring** · SPEC §6.3
  - File: `Sources/RecorderCore/Spring.swift`
  ```swift
  public struct Spring: Sendable {
      public var response: Double, damping: Double            // ω = 2π/response, ζ = damping
      /// Closed form, rest → 1. ζ ≥ 1: 1 − (1 + ωt)·e^(−ωt).  ζ < 1: 1 − e^(−ζωt)·(cos ω_d t + (ζω/ω_d)·sin ω_d t), ω_d = ω√(1−ζ²)
      public func value(at t: Double) -> Double
      /// One semi-implicit Euler step toward a moving target: a = ω²(target − x) − 2ζω·v;  v += a·dt;  x += v·dt
      public func step(x: inout Double, v: inout Double, target: Double, dt: Double)
      public static let focused = Spring(response: 0.55, damping: 1), smooth = Spring(response: 0.9, damping: 0.85)
      public static let cursorRapid = Spring(response: 0.12, damping: 1), cursorMedium = Spring(response: 0.22, damping: 1), cursorSmooth = Spring(response: 0.38, damping: 1)
  }
  ```
  - Tests (AC-ZM-1): `springStartsAtZeroEndsAtOne` · `criticallyDampedIsMonotonicNoOvershoot` · `stepConvergesToClosedForm` (|step-sim − value(at:)| < 0.01 at dt = 1/240).

- [~] **T-404 TimelineView: geometry + static drawing** · SPEC §7.1
  - WAITING ON HUMAN: merged; coordinator reviewed `timeline-png` vs §7.1. Human look in the real editor after T-307.
  - File: `Sources/Recorder/Editor/TimelineView.swift` (+ `TimelineGeometry.swift` in **Core**, pure, tested).
  ```swift
  // Core
  public struct TimelineGeometry: Sendable {
      public var pxPerSecond: Double, scrollX: Double, width: Double
      public func x(forOutput t: Double) -> Double
      public func output(forX x: Double) -> Double
      public mutating func zoom(by factor: Double, anchorX: Double, minPxPerSecond: Double, maxPxPerSecond: Double)   // time under anchorX stays put (AC-TL-4)
      public func tickInterval() -> Double      // adaptive: 1/60,1/10,0.5,1,5,10,30,60… so labels are ≥ 70 px apart
  }
  ```
  - Tests: `zoomKeepsAnchorTime` · `tickIntervalReadable`.
  - View: flipped `NSView`, `wantsLayer = true`, draws in `draw(_ dirtyRect:)` with Core Graphics only. Lanes top→bottom: ruler 22, clip 44, zoom 32, layout 28 (only if `source.hasCamera`), mask 28 (hidden until T-601). Blocks: rounded rect radius 10, fill from Theme (`clip`, `accent`, `layout`, `mask`), 1 px inner highlight, label (`🔍 2.0× A`, `2× ⏩`). Zoom x-extents = `timeMap.outputTime(atSource:)` of start/end, clipped to visible clips (torn edge `⌇` when partially hidden). Playhead + cap + timecode. Observe `model` with `withObservationTracking` → `needsDisplay = true`.
  - HUMAN: static look vs SPEC §7.1 mockup.

- [~] **T-405 Timeline navigation** · SPEC §7.2 "Navigation" — `scrollWheel` (pan; `⌘` = zoom at mouse), `magnify(with:)` (pinch at mouse), `⌘=`/`⌘-` (anchor playhead), `⇧Z`/Fit button, slider in the timeline toolbar. Click/drag on ruler = scrub (`model.playhead`, preview seeks coalesced). Page-wise auto-scroll during playback; manual scroll disables it until next play. Hover line + timecode tooltip (`NSTrackingArea`, `mouseMoved`).
  - WAITING ON HUMAN: AC-TL-4 pinch/scroll anchoring with a real trackpad, after T-307.
  - HUMAN: AC-TL-4 (pinch keeps the time under the pointer fixed).

- [~] **T-406 Hit-testing + cursors + selection** · SPEC §7.2 table
  - WAITING ON HUMAN: hit-test assertions pass in `timeline-png`; cursors per §7.2 table need a human after T-307.
  ```swift
  enum TimelineHit { case playhead, clipEdge(Int, Edge), clipBody(Int), cutBubble(afterClip: Int),
                     blockEdge(UUID, Edge), blockBody(UUID), emptyLane(Lane, source: Double), ruler, none }
  func hitTest(at p: CGPoint) -> TimelineHit       // order exactly as the SPEC table; edge zone 6 pt, 3 pt when block < 24 pt
  ```
  - Do: cursor per hit (`resizeLeftRight`, `openHand`/`closedHand`, `pointingHand`, `crosshair`-style plus). Click selects (white 2 px outline + glow), `⇧`-click adds same-lane, empty click/`Esc` deselects. `⌫` removes selection (`removeClip`/`removeBlock` via `model.edit`). Inspector swap arrives in T-413.
  - HUMAN: every row of the hit table shows the right cursor.

- [~] **T-407 Split** · SPEC §7.2 "Split" — **the headline interaction; implement every sentence of that paragraph.**
  - WAITING ON HUMAN: merged; `--selftest timeline-ops` drives real NSEvents (split at playhead, refusal near edges, split mode, Esc). Human feel-check + AC-TL-5/7.
  - Do: `C` → `model.edit("Split") { $0.split(atOutput: playhead) }` (works during playback: AC-TL-5). Split mode: `flagsChanged` ⌥ = momentary, `S`/✂ button = sticky, `Esc` exits. In split mode draw a full-height dashed accent blade at the snapped mouse x with a timecode chip; preview hover-scrubs to the blade time without moving `model.playhead` (add `model.hoverTime: Double?`; `PreviewView` renders `hoverTime ?? playhead`). Click = split there. Refused split (returns false) → 3-cycle 4 px horizontal shake of the blade, no alert. Success → 0.25 s fading white line.
  - HUMAN: AC-TL-5, AC-TL-7.

- [~] **T-408 Trim, remove, restore, speed, ripple animation** · SPEC §7.2
  - WAITING ON HUMAN: merged; `timeline-ops` asserts project result, invariants, 1 undo step, Esc-restores per gesture. Human: ripple animation, menus, ✂ bubbles.
  - Do: clip edge drag = `beginGesture` → `update { trimClip }` per mouseDragged → `commitGesture("Trim")`; `Esc` mid-drag → `cancelGesture` (AC-TL-6). During drag: chip `00:20.60 (Δ −0:01.20)`, preview shows the edge frame via `hoverTime`. ✂ bubble drawn at every seam where `clips[i].sourceEnd != clips[i+1].sourceStart` and at head/tail when trimmed; click → `NSPopover` "Restore 00:05.80 removed here [Restore]". Context menus per SPEC (clip / empty clip area / ruler) as `NSMenu`. Speed submenu + `Custom…`. Ripple animation: when `project.clips` changes and **no drag is active**, animate block x/width from old to new geometry over 0.18 s (keep `previousRects: [Int: CGRect]`, drive with the display link, ease-out). `// ponytail: animate by index; fine because ops change at most one seam.`
  - HUMAN: remove a middle segment → neighbours slide together, bubble appears, restore works, undo is one step each.

- [~] **T-409 Snapping + zoom-block gestures** · SPEC §7.2 "Snapping", "Zoom blocks"
  - WAITING ON HUMAN: merged; snapping on/off-candidate assertions in `timeline-ops`. Human: AC-TL-3 feel on a long project.
  - Do: candidates = playhead, all clip edges, all block edges (except the dragged one), left-click times from `events` (draw them as 1×4 pt ticks in the zoom lane); threshold `6 / pxPerSecond`; `⌘` held disables; while snapped draw a 1 px accent guide across all lanes. Applies to: split blade, trims, block move/resize. Empty zoom lane: ghost block under pointer; click → `addZoom` (mode `.auto` if a click event lies within ±1 s, else `.manual`). Body drag = `moveZoom`, edges = `resizeZoom`. `Z` adds at playhead. Double-click = select + playhead to start. `⌘D` duplicates after itself. Context menu Disable/Enable · Instant · Remove.
  - HUMAN: AC-TL-3 feel check with a long project; AC-TL-6.

- [x] **T-410 AutoZoom** · SPEC §6.4
  - File: `Sources/RecorderCore/AutoZoom.swift` — `public func generateAutoZooms(clicks: [InputEvent], duration: Double) -> [Zoom]` implementing the 5 numbered rules literally.
  - Tests (AC-AZ-1): `clusterByTimeAndDistance` · `mergeCloseZooms` · `dropShortAndClamp` · `outputSortedNonOverlappingDeterministic`.
  - DONE: core (lane-autozoom, 4 tests green) + wiring complete — `RecordingController.finish` already filled `project.zooms` (T-111); T-311 added `Edit ▸ Regenerate Auto Zooms` (`EditorWindowController.regenerateAutoZooms`) and `Edit ▸ Remove All Zooms` (`.removeAllZooms`), both verified headlessly in the `menu-actions` selftest (produces the expected zoom, one undo step).

- [x] **T-411 CursorPath** · SPEC §6.5
  - File: `Sources/RecorderCore/CursorPath.swift`
  ```swift
  public struct CursorSample: Sendable { public var x, y, prevX, prevY: Double; public var imageID: String?; public var alpha, rotation, clickScale: Double }
  public struct CursorPath: Sendable {
      public init(events: EventLog, style: CursorStyle, hidden: [TimeRange], duration: Double, rate: Double = 240)
      public func sample(atSource t: Double) -> CursorSample          // index + lerp; pure lookup
  }
  ```
  - Pipeline order exactly as SPEC §6.5 (shake removal → spring follow → idle hide → loop → rotation → click pulse → hidden ranges). M4 implements: spring follow, idle hide, click pulse, imageID, hidden flag. The rest are `// T-604`.
  - Tests (AC-CUR-1): `smoothedNeverLeadsRaw` · `settlesWithinHalfPixelAfterRest` · `idleHidesAfterTwoSeconds` · `sampleIsOrderIndependent`.

- [x] **T-412 CameraPath** · SPEC §6.3
  - File: `Sources/RecorderCore/CameraPath.swift`
  ```swift
  public struct ViewTransform: Sendable, Equatable { public var cx, cy, scale: Double; public static let identity = ViewTransform(cx: 0.5, cy: 0.5, scale: 1) }
  public struct CameraPath: Sendable {
      public init(zooms: [Zoom], cursor: CursorPath, spring: Spring, duration: Double, rate: Double = 240)
      public func sample(atSource t: Double) -> ViewTransform
  }
  ```
  - Do: build the target signal per step (outside enabled zooms: identity; inside: `scale`, centre = manual centre or dead-zone follower: move the target only when the cursor leaves the central 60% of the current viewport, then by just enough to bring it back to the 60% box). Simulate `cx, cy, scale` with `Spring.step`. `instant` zooms: copy target, zero velocity. After each step clamp centre so the viewport `[c − 0.5/scale, c + 0.5/scale]` stays inside 0…1.
  - Tests: `viewportAlwaysInsideSource` (AC-ZM-2, random zooms) · `sampleIsOrderIndependent` (AC-ZM-3) · `instantZoomJumps` · `outsideZoomsIsIdentityEventually`.

- [~] **T-413 Paths into the renderer + cursor pass** · SPEC §6.2 passes 2–3
  - WAITING ON HUMAN: merged; zoom + redrawn cursor verified in `preview-frame` PNGs and one live screenshot (large crisp arrow). Human: AC-CUR/AC-ZM feel with a real recording.
  - Do: `EditorModel` owns `cursorPath`/`cameraPath`, rebuilt inside `edit/update` only when `zooms`, `cursor`, `animation.screen` or `cursorHidden` changed (compare before/after). `FrameState.view/prevView/cursor` filled from them (prev = `t − 1/60`). Shader: screen UV = `center + (uv − 0.5) / scale`, inside the crop rect. Cursor pass: texture from `cursors/<id>.png` (cache `[String: MTLTexture]`), quad positioned in **screen space** (so it zooms), size = image points × `cursor.size` × output scale, offset by hotspot, × `clickScale`, alpha.
  - Selftest `render` gains `--t <seconds>`; HUMAN: play a recording with clicks — view zooms in on clicks and follows; cursor smooth, large, sharp (AC-CUR-2).

- [~] **T-414 Inspector: selection panels + Cursor tab (basic)** · SPEC §6.6 — Files `Inspector/ZoomPanel.swift`, `ClipPanel.swift`, `CursorTab.swift`. Selection replaces tabs; `‹ Back`/`Esc` deselects (AC-INS-3). Zoom panel: Level 1.2–5, Auto/Manual, Instant, Disable, Remove. Clip panel: speed presets + custom slider 0.25–16, duration readout, Remove. Cursor tab: Hide, Size 0.5–4, Movement picker, Hide when idle (others disabled with "M6").
  - Current v0.3.2 source passes inspector-panels, menu-actions and timeline-ops; fresh zoom/clip/cursor renders
    inspected. Undo/redo, speed edits and cursor autosave checks pass; selection routing and Escape chain inspected.
    User accepted visual deviations, so no further mockup sign-off is required. Keep [~] because AC-INS-3's actual
    one-frame panel-switch timing is not measured by these tests; a settled PNG does not prove that timing.
    Deviation: per-clip audio controls live on the audio lane, not an added field on the screen Clip.
- [~] **T-415 Manual zoom target in preview** — when a `.manual` zoom is selected, `PreviewView` shows the **un-zoomed** frame with a draggable accent rectangle (size = 1/scale) — reuse `SelectionRectView` with `aspect` locked and resize disabled (`allowsResize = false`, add that flag). Drag = `update { zoom.center }`.
  - WAITING ON HUMAN (feel only): `zoom-target`/`zoom-target-png`/`hover-preview` all pass headlessly (mapping round trip, one-undo-step drag, clamped-to-frame drag, AC-TL-7 hover-without-moving-playhead); `TimelineView.onHoverTime` now wired to `PreviewView.hoverTime` in `EditorWindowController`'s init. Human: live drag feel over a real recording (does the rectangle track the cursor smoothly, no jitter/lag).
- [x] **T-416 Waveform** — File `Render/Waveform.swift`: `AVAssetReader` over mic (else system) → min/max peaks at 200/s → `[Float]` cached in memory; drawn inside clip blocks mapped through `TimeMap`. `// ponytail: computed on open, not cached on disk.`
  - VERIFIED: fixed rounded-down sample buckets that produced 201 rather than 200 peaks for one second of 44.1 kHz
    audio. The shared extractor now compares cumulative frames to exact bucket boundaries. New waveform regression
    fails before the fix and passes after it; audio-lanes, synthetic voiceover, timeline-ops, timeline-png and all
    129 Core tests pass. Reviewed fresh waveform/silence/mute rendering. Placement is per audio clip after T-644's
    audio-lane roadmap; the user's visual waiver closes the remaining taste review, not other performance gates.
    Shipped in v0.3.3; the downloaded signed app also passes the exact 200-bucket regression.
- [~] **T-417 Accessibility** · AC-TL-8 — `accessibilityChildren()` returns one `NSAccessibilityElement` per block, role `.button`, label per SPEC, `accessibilityPerformIncrement/Decrement` move by one frame. HUMAN: VoiceOver reads blocks.
  - WAITING ON HUMAN: merged; `timeline-ops` asserts children count/roles/labels/frames and increment/decrement = 1 undo step. Human: VoiceOver pass (AC-TL-8).
- [~] **T-418 M4 gate** — `make test` all green; HUMAN walks SPEC §7.2 paragraph by paragraph and §7.3 key by key; deviations into §Log. AC-TL-3 on a 30-min recording.
  - VERIFIED: 129 Core tests; native timeline-ops/clipboard/selection/tracks/full-layers, command-scissors, clip-fades, zoom-target, highlight-manipulation, menu-actions and LaunchServices workspace-replay pass. User accepts visual deviations. A full physical-key/VoiceOver walkthrough and display-refresh measurement on a 30-minute/200-zoom recording remain unmeasured; do not report AC-TL-3 passed.

---

## M5 — Ship  (SPEC §6.2 blur, §6.6 remaining tabs, §6.8)

- [~] **T-501 Motion blur** · SPEC §6.2 pass 2–3 — shader: when `|view − prevView|` > 0.5 px (in output px), average 8 taps of the screen texture along the UV delta, scaled by `animation.motionBlur` and gated by `blurZoom`/`blurPan` (scale change vs centre change); cursor quad: 8 taps along `pos − prevPos`, gated by `blurCursor`. Animations tab (`Inspector/AnimationsTab.swift`): slider + 3 advanced toggles + Focused/Smooth. The cursor Movement picker stays in the Cursor tab.
  - WAITING ON HUMAN (taste): merged; parity maxDelta=0 inside a zoom transition with blur on; blur on/off PNGs reviewed by lane agent.
  - HUMAN: blur visible during zoom-in on a paused frame mid-transition (scrub slowly); none when static.
- [~] **T-502 Camera compositing** · SPEC §6.6 Camera — pass 4: camera texture in a rounded-rect SDF quad (reuse mode 3), size/corner/roundness/mirror/shadow; `shrinkWhenZoomed`: size × `lerp(1, 0.7, (scale−1)/(2−1) clamped)`. Camera tab UI; dragging the camera in the preview snaps to nearest corner.
  - WAITING ON HUMAN: merged; camera bubble + drag-to-corner (`camera-drag` selftest), parity 0 on the camera fixture; coordinator reviewed a mid-fade frame. Human: real camera recording (AC-CAM-*).
- [~] **T-503 Layout track** — lane enabled; blocks via the generic block ops (T-402); kinds `cameraFull` (camera fills output, screen hidden) / `hidden`; 0.3 s cross-fade using `Spring.focused.value(at:)` at block edges; `LayoutPanel.swift`.
  - WAITING ON HUMAN: Core mix + renderer + lane + LayoutPanel + Camera-tab button all merged; parity 0 mid cross-fade.
- [~] **T-504 Audio tab** — volumes/mutes → rebuild `AVAudioMix` only (no composition rebuild). `denoise`: applied **at export only** as an 80 Hz high-pass + peak normalise to −1 dBFS over the mic samples; preview plays the raw mic. `// ponytail: no real noise suppression and no preview; add an audio tap if users ask.` Click sound: mix `Resources/click.caf` at each `.down` time (export only; preview plays it with `NSSound`).
  - WAITING ON HUMAN (listen only): both halves now merged — Audio tab UI (volumes, mutes, denoise, click sound) and the behaviour (live `AVAudioMix` swap without composition rebuild, export-only high-pass+normalise denoise, click track mixed at export / `NSSound` in preview). `audio-mix` selftest OK (`rms full=0.353 quiet=0.088 muted=0.0`; denoise peak≈expected; click rms at/away from click clearly distinct). Human: listen to a real recording's volume/mute/denoise/click-sound behaviour end to end.
- [x] **T-505 Exporter (MP4)** · SPEC §6.8
  - File: `Sources/Recorder/Render/Exporter.swift`
  ```swift
  struct ExportSettings: Codable { enum Format: String, Codable { case mp4, gif }; var format: Format; var shortEdge: Int /*720,1080,2160*/; var fps: Int; var quality: Quality; var codec: Codec }
  final class Exporter {
      init(model: EditorModel, settings: ExportSettings, destination: URL)
      var progress: (Double, Int, Int) -> Void          // fraction, frame, total
      func run() async throws; func cancel()
  }
  ```
  - Do: video: use `AVAssetReaderTrackOutput` (not `AVAssetReaderVideoCompositionOutput`) per video track of the T-305 composition, decode sequentially, and for output frame `n` at `t = n/fps` advance each reader until its buffer PTS ≥ t (hold last). Build `FrameState` with the **same function** the preview uses (extract `func makeFrameState(model:, outputTime:, screen:, camera:, size:)` into `FrameState.swift` and call it from both). Render into a `CVPixelBuffer` from `AVAssetWriterInputPixelBufferAdaptor.pixelBufferPool` (Metal-compatible, BGRA). Audio: `AVAssetReaderAudioMixOutput` → AAC input. Bitrate formula from SPEC §6.8. Cancel → `cancelWriting` + delete file (AC-EXP-3).
  - Selftests: `export <package> <out.mp4>` (asserts duration == `timeMap.outputDuration` ± 1 frame — AC-EXP-4) · `parity <package>` (renders frame at t via preview path and export path into textures; max channel delta ≤ 1 — AC-ED-2).
- [~] **T-506 Export sheet UI** · SPEC §6.8 mockup — `Editor/ExportSheet.swift`: pickers, size estimate (`bitrate × duration / 8`), states Exporting/Done, Copy to clipboard (temp file URL on `NSPasteboard`), persisted defaults, editor locked while exporting. Enable the Export button + `⌘E`.
  - WAITING: `ExportSheet.present(for:on:)` merged, `export-sheet` selftest OK (estimate, persistence, run to 1.0, cancel deletes partial), PNG reviewed by lane agent; Export button/⌘E wiring now done (`EditorWindowController.exportTapped`, top-bar button + Export ▸ Export… ⌘E menu item, both responder-chain-resolved, `menu-actions` selftest covers disable-with-no-editor + validate-with-editor) — HUMAN look at the sheet itself still pending.
- [x] **T-507 GIF** — same frame loop → `CGImageDestinationCreateWithURL(… UTType.gif …)`, per-frame `kCGImagePropertyGIFDelayTime`, loop 0, long edge ≤ 960; warn if > 60 s. `// ponytail: ImageIO's default palette; add per-frame quantisation only if banding is reported.`
- [~] **T-508 Perf gates** — HUMAN + selftest timing: AC-EXP-1 (1 min 1080p60 < 30 s), AC-EXP-2 (10-min drift < 1 frame: compare last click sound vs cursor pulse), AC-APP-3 (idle CPU/RAM). Numbers into §Log.
  - VERIFIED on signed v0.3.2 / Apple M1: `export-perf 60` exports all 3,600 1080p60 HEVC frames in 19.58 s
    (AC-EXP-1 PASS); fixture synthesis 19.3 s excluded. Video duration 60.0000 s, drift 0.0000 s, last PTS 59.9833 s.
  - WAITING ON HUMAN: AC-EXP-2 requires an actual ten-minute audio-bearing package and comparison of last click
    sound/cursor pulse. `export-perf 600` is video-only, so it cannot prove audio drift. AC-APP-3 requires the real
    app idle with toolbar open (<1% CPU, <150 MB RAM), measured for ten minutes; `idle-perf` hosts no toolbar and
    explicitly reports only a lower bound. Do not use either diagnostic as a full-gate substitute.
- [~] **T-509 M5 gate / release** — clean-clone build and installer regressions; signed/notarized universal DMG and next `vMAJOR.MINOR.PATCH` release. Original v1.0 acceptance still requires HUMAN record → edit → export and real-device/performance gates.
  - RELEASED: [v0.3.3](https://github.com/olegpustovit/recorder/releases/tag/v0.3.3), source `2fb0859`, includes exact waveform timing and the v0.3.2 missing-device restore fix. CI and signed/notarized universal-DMG pipeline pass, including the new native waveform regression. Downloaded DMG/app pass digest, stapled-ticket and Gatekeeper checks; both architectures/version and the shipped waveform selftest verified. LaunchServices preflight still reports screen=true/accessibility=true on this Mac without requesting/resetting grants. Clean-clone release build, audio/synthetic voiceover, background crash recovery and export checks pass. Previous v0.3.1 shipped the audio/media update; unpublished v0.3.0 remains failed-build history. Used installer fixtures and a separately mounted DMG instead of resetting TCC or replacing the user's app. Remaining [~] is original full v1.0/HUMAN acceptance, not a pending release; validation limits are public in the release notes.

---

## M6 — Polish  (each independent; any order)

- [~] **T-601 Masks & highlights** · SPEC §7.1 lane, §6.6 Mask panel — lane on; rect edited in preview with `SelectionRectView`; mask = solid fill at `opacity`, highlight = dim everything outside the rect by `opacity`. Keys: only those in SPEC §7.3.
  - PARTIAL: lane + MaskPanel + MaskRectOverlay + compositor pass all merged (mask/highlight render correctly, `parity` 0 on `/tmp/M6Fixture.recorder`); `MaskRectOverlay` now mounted over the live preview (`PreviewView.maskOverlayView`/`onResize`, wired in `EditorWindowController`'s init) — its content-rect mapping was root-caused to `ZoomTargetMapping.contentRect` (was `CropMapping.imageRect`, which ignored the preview's own letterboxing and the frame's `padding` inset; also fixed a stray-`onChange`-during-selection-change bug this surfaced, see Log). `mask-rect`/new `mask-overlay` selftests OK. No colour/blur controls (no fields).
- [~] **T-602 Keyboard-shortcut overlay** — render `.key` events as rounded chips (`⌘ ⇧ K`) bottom-centre for 1.2 s; text rendered to a texture with Core Text, cached per string. Keys tab.
  - WAITING ON HUMAN (look only): behaviour half (Core `keyChipLabel`/`activeKeyChip` + tests) and render half (`FrameState.keyChip`, `Compositor`'s Core Text chip texture pass) both merged and verified (`parity` 0 on `/tmp/M6Fixture.recorder`, which has `keys.show = true` and two `.key` events); `Inspector/KeysTab.swift`'s "Show keyboard shortcuts" toggle already wired to `project.keys.show`. Human: look at a real chip on screen (position/size/fade against SPEC §6.6).
- [x] **T-603 Speed up typing** — Edit ▸ Speed Up Typing: find runs of `.typing` events (gap < 1 s, length > 3 s), split clips around them, set 2×. Core fn `typingRanges(events:) -> [TimeRange]` + test.
  - DONE: Core `typingRanges(events:)` (pre-existing) + new `Project.speedUpTyping(_:factor:)` (`RecorderCore/TimelineOps.swift`, splits clips at each range's source-time edges and sets the enclosed clip(s) to `factor`×) with test `speedUpTypingKeepsInvariants`; `Edit ▸ Speed Up Typing` wired on `EditorWindowController`, verified headlessly (produces the expected 2× clip, `checkInvariants() == nil`, one undo step).
- [~] **T-604 Cursor advanced** — loop position, rotate, remove shakes, always-arrow, hide-cursor ranges. Edit ▸ Hide Cursor in Selected Clip uses the per-clip flag introduced by T-659; legacy `cursorHidden` ranges remain supported. Tests per stage in `CursorPath`.
  - Core pipeline stages and Cursor-tab controls (shake removal, loop, rotation, always-arrow) are implemented. The original source-range menu implementation is superseded by T-659's per-clip flag and inspector toggle; historical `cursorHidden` values continue to load. Remaining [~] is the real-recording feel gate, not missing controls.
- [x] **T-605 Presets** — save/apply = the styling subset of `Project` (`background, frame, cursor, animation, camera`) as JSON in `~/Library/Application Support/Recorder/Presets/`; export/import via file panels.
- [x] **T-606 Import video** — drag a movie into the library → package with the file copied as `screen.mov`, empty `events.json`.
- [~] **T-607 Command menu (⌘K)** — a searchable list over the existing `NSMenu` items (walk `NSApp.mainMenu`), performs the item's action. No separate command registry.
  - WAITING ON HUMAN (taste only): `--selftest command-menu` OK + PNG reviewed by lane agent; `CommandMenu.show()` now bound to View ▸ Command Menu… ⌘K (`AppDelegate.wireViewHelpItems`, T-311).
- [~] **T-608 Cheat sheet (⌘/)** — static SwiftUI grid of SPEC §7.3.
  - WAITING ON HUMAN (taste only): all 19 rows of SPEC §7.3 rendered (`cheatsheet-png`); `CheatSheet.show()` now bound to View ▸ Keyboard Shortcuts ⌘/ (`AppDelegate.wireViewHelpItems`, T-311).
- [~] **T-609 Shortcut settings + Copy frame (⇧⌘C)** — rebind the global hotkeys (the T-204 table); copy current composed frame to the pasteboard as PNG.
  - DONE: `App/Hotkeys.swift` — `Hotkey` gained a `character` (default `NSMenuItem.keyEquivalent`); `Hotkeys.overrides`/`currentBinding(for:titled:)`/`rebind(_:keyCode:modifiers:character:defaults:)` (rejects a combo already in use by another hotkey)/`resetToDefaults(defaults:)`/`reload(from:)` persist through `RecordingSettings.swift`'s new free-standing `HotkeyBinding`/`HotkeyOverrides` (one JSON `UserDefaults` key, keyed by `Hotkey.title`, injectable `defaults` so tests never touch `.standard`); `match(_:)` reads the current (override-aware) binding. `App/SettingsView.swift` — Shortcuts section: one row per hotkey (`HotkeyRecorderField`/`HotkeyCaptureButton`, click → "Press keys…" → next combo commits, Esc cancels) + "Reset to Defaults". `App/AppDelegate.swift` — `buildIdleStatusMenu`/`buildRecordingStatusMenu`'s key equivalents now come from `Hotkeys.currentBinding(titled:)` (`hotkeyKey` helper) instead of literals, so a rebind is reflected there. Copy Frame: `EditorWindowController.copyFrameAsImage`/`renderCurrentFramePNG` (Export ▸ Copy Frame as Image ⇧⌘C, responder-chain-resolved like Export…) decode the current frame with the exporter's `AVAssetReader` + sequential `copyNextSampleBuffer()` path (not the preview's `AVPlayer`, which stacks concurrent decode sessions against `PreviewView`'s own player on an edited window) through `makeFrameState`/`Compositor.render` at the project's native cropped resolution, PNG onto the pasteboard.
  - Verified headlessly: `make test` 48/48; `--selftest hotkeys` (throwaway `UserDefaults` suite — override → table + persisted store reflect it, duplicate combo rejected, reset restores every default, `buildIdleStatusMenu`'s key equivalent follows both the rebind and the reset) OK; `menu-actions` extended (Export…/Copy Frame resolve via the responder chain with an editor open, disabled with none; Copy Frame's PNG lands on an injected pasteboard at the project's exact pixel size) OK; `menus`/`command-menu`/`export-sheet`/`editor-png`/`parity` all still OK.
  - WAITING ON HUMAN: Settings ▸ Shortcuts pane's actual click-to-record UI is unverified beyond compiling — SwiftUI/AppKit key capture needs a real key event, which can't be driven headlessly and this session may not click/type into the real app (no UI automation; the user is on this machine). The underlying logic it drives (`Hotkeys.rebind`/duplicate-reject/`resetToDefaults`) is fully covered by `--selftest hotkeys` above.
  - HUMAN: open Settings ▸ Shortcuts, click a row's field, confirm it shows "Press keys…" then captures the next combo pressed (Esc cancels instead), that binding it to a combo already used elsewhere is rejected (visible "Already in use"), and "Reset to Defaults" restores every row; confirm the status-item menu's key equivalents (`⌃⌘↩`/`⌥⌘3` etc.) follow a rebind.
- [x] **T-610 State snapshot dump** (SPEC §8.1) — `Recorder ▸ Copy State Snapshot` (⌃⌥⌘S, global, allowed WHILE RECORDING like ⌃⌥⌘R/⌃⌥⌘P), also in both status-item menu variants: `App/StateSnapshot.swift`'s `StateSnapshot.dump(to:pasteboard:playSound:)` writes `~/Library/Logs/Recorder/Snapshots/<yyyy-MM-dd HH.mm.ss>/` — `snapshot.json` (app/OS/permission/recording/settings/hotkey/memory state, every `NSApp` window, one entry per open editor: playhead/selection/undo-redo names/`TimeMap` duration/`checkInvariants()`/preview+timeline internals/inspector panel/export-sheet phase), `editor-<n>-project.json` (each open editor's current in-memory `Project`, via the same encoder `Project.save` uses), `editor-<n>-events-summary.json` (event-KIND counts + first/last timestamps only, never raw events), one `window-<n>-<class>.png` per Recorder's own VISIBLE window, and `README.txt`; puts the folder path on the pasteboard, plays a system sound, and flashes the existing status item's title ("Snapshot copied", 2 s, `AppDelegate.flashStatusItem`) — no new window class. Keeps only the newest 20 snapshot folders. `scripts/freeze-dump.sh [pid]` is the out-of-process fallback for a fully hung main thread (`sample`/`ps` on the running process into a new folder under the same directory, path to `pbcopy`). Small read-only accessors added where state was private: `Permissions.camera/mic`, `RecordingController.currentTargetDescription`, `CaptureTarget.targetDescription`, `EditorModel.undoStepNames/redoStepNames`, `PreviewView.debugPlayerStatus/debugRate/debugCurrentTime/debugHasScreenPixelBuffer/debugPendingFrameRetries/debugIsSeeking`, `TimelineView.debugSplitMode/debugDragKind`, `EditorWindowController.allOpen` (a weak-boxed registry populated in `init` — `makeOffscreen` windows were never in the private `openWindows` dedup dict) and `currentInspectorTab`.
  - Verified: `make app` (no `error:`); `make test` 48/48; selftests `snapshot` (new — offscreen editor, one edit + a selected zoom, injected temp dir + private pasteboard: folder/snapshot.json/editor-0-project.json (`Project.load` equality)/events-summary (no raw events)/pasteboard string/20-folder retention all OK), `menus` (extended for the new menu items + hotkey), `hotkeys`, `menu-actions`, `model` all OK. Real run: `open -n build/Recorder.app --args --open /tmp/M6Fixture.recorder`, `scripts/freeze-dump.sh <pid>` produced a non-empty `sample.txt` + `ps.txt` and copied the folder path via `pbcopy`; a one-off headless run with a real ordered-front editor window confirmed `window-0-NSWindow.png` shows the actual editor chrome (top bar, Background inspector tab, timeline with Mask/Highlight blocks) — the MTKView preview pane itself renders blank in `cacheDisplay`, a documented `// ponytail:` limitation (`CGWindowListCreateImage`, which would avoid that, is compile-time `unavailable` on this SDK — "Please use ScreenCaptureKit instead" — so this always uses `cacheDisplay`).
  - deviations: git commit omitted from `snapshot.json`'s `app` block — no Makefile step bakes one in anywhere in this project, and adding a build-time step for one optional field wasn't worth it (task allowed "omit"); `currentInspectorTab` only tracks tab switches made through the `View ▸ 1–6` menu (SwiftUI's own tab-button clicks are a private `@State` with no callback out) — the more important "selection replaces the tabs" case (clip/zoom/layout/mask panel) is computed independently from `model` and is always accurate.

---

## Requested clip fades — 2026-09-22

- [x] **T-616 Explicit clip fades, default Off** — Remove automatic post-gap video arrival. Add per-clip Fade in/Fade out sliders (output seconds, Off by default for new and old projects), preserve outer fades across splits, and snap the dragged selection's leading edge exactly to zero. Shared opacity covers preview/export. SPEC: Video clip fades below.
  - Verify: `make test` (including old JSON defaults, explicit ramp values and split preservation), `make app`, `--selftest clip-fades` (controls, undo/redo, persistence, zero-edge snap and Command bypass), `--selftest timeline-ops`, `--selftest parity` with explicit fades; inspect `/tmp/recorder-clip-fades.png`.

## Log

Append one line per completed task: `T-xxx · YYYY-MM-DD · verified: <what> · deviations: <none|…>`

T-002 · 2026-09-18 · verified: `make build` succeeds with `Sources/Recorder/App/Theme.swift` added (enum `Theme`, `NSColor` tokens + `Color` accessors, `Radius`, body/caption/title fonts, `timecodeFont`, `NSColor(hex:)`) · deviations: none
T-003 · 2026-09-18 · verified: `make build` and `make app SIGN_ID=-` succeed; launched `build/Recorder.app/Contents/MacOS/Recorder` in the background, alive after 3 s (no crash), killed cleanly · deviations: "Record" menu's spec shorthand "Start/Finish" rendered as static title "Start/Finish" (toggling to real state comes with T-104/T-111); "View" tab items titled "1"–"6" (spec §8 says only "tabs 1–6", not yet named — inspector tab names arrive with T-308+); About/Quit/Close/Window-menu Minimize/Zoom/Bring-All-to-Front wired to standard AppKit responder-chain selectors (generic, not app logic) so the app is actually usable/quittable meanwhile; visual menu/status-item check is HUMAN (marked `[~]`).
T-004 · 2026-09-18 · verified: `make app SIGN_ID=-` builds; `build/Recorder.app/Contents/MacOS/Recorder --selftest metal` prints `SELFTEST metal OK` and exits 0; `--selftest nope` prints reason and exits 1; `make test` still passes (1 test) · deviations: none
T-005 · 2026-09-18 · verified: `make test FILTER=project` passes 3/3 (`projectRoundTrip`, `projectDefaultsFromMinimalJSON`, `projectRejectsNewerVersion`); `make test` passes 4/4 (adds `timeMapRoundTrip`); `make build` succeeds · deviations: SPEC §5's example JSON values are used as every nested struct's `init()` default (spec doesn't state defaults separately from the example) except where the example gives no value (`background.imagePath` defaults to `""`); `Zoom`/`Layout`/`Mask` (no example default given for `start`/`end`/`kind` alone) default to `start:0,end:3,scale:2,mode:.manual` / `start:0,end:0,kind:.cameraFull` / `start:0,end:0,kind:.mask,opacity:0.8`; `Output.Aspect` uses explicit raw values (`r16x9 = "16:9"` etc.) since Swift case names can't contain `:`; `id`/`createdAt` default to a freshly generated `UUID().uuidString`/current ISO8601 timestamp when missing.
T-001 · 2026-09-18 · verified: user clicked Always Allow; `codesign --sign "Recorder Dev"` succeeds, `codesign -dvv` shows `Authority=Recorder Dev` · deviations: identity lists as CSSMERR_TP_NOT_TRUSTED (self-signed, expected), signing works
T-003 · 2026-09-18 · HUMAN confirmed: user ran the app, menu bar is fine · deviations: none
T-006 · 2026-09-18 · verified: `make test FILTER=eventLog` passes 1/1 (`eventLogRoundTrip`, exercises encode/decode round trip plus `moves()` incl. drag and `clicks()` filtered to left `.down`); `make test` passes 5/5; `make build` succeeds · deviations: none
T-101 · 2026-09-18 · verified: `make app` builds and signs with `Recorder Dev`; `build/Recorder.app/Contents/MacOS/Recorder --selftest permissions` prints `screen=false accessibility=false` then `SELFTEST permissions OK`, exit 0; `make test` passes 5/5 · deviations: registered the `permissions` case directly in `SelfTest.swift`'s `cases` dictionary literal (same place `metal` was registered by T-004) rather than adding a second registration mechanism
T-102 · 2026-09-18 · verified: `make app` builds and signs with `Recorder Dev`; `make test` passes 5/5; launched `build/Recorder.app/Contents/MacOS/Recorder` in the background, alive after 3 s with no crash output, killed cleanly · deviations: AppDelegate's skeleton placeholder window replaced with a conditional show of `OnboardingView` only when `!Permissions.allGranted`; when all granted nothing is shown yet (toolbar arrives in T-104), per task instruction. HUMAN verification of AC-ONB-1/2/3 (needs real TCC grants via `make install`) not yet done — task marked `[~]`.
T-103 · 2026-09-18 · verified: `make build` succeeds with `Sources/Recorder/Recording/FloatingPanel.swift` added (`FloatingPanel: NSPanel`, `.borderless`/`.nonactivatingPanel`, level `CGShieldingWindowLevel()-1`, `.canJoinAllSpaces`/`.fullScreenAuxiliary`, `isMovableByWindowBackground`, `NSVisualEffectView(.hudWindow)` content wrapper with radius-16 + 1px `Theme.stroke` border, `canBecomeKey == true`, static `allWindowIDs`); `make test` passes 5/5 · deviations: added a `static func register(_ window: NSWindow)` (not in the task's code block) backing the weak window list, since T-107's overlay windows (not `FloatingPanel` instances) also need to register into the same list for `allWindowIDs`/T-106 capture exclusion — `FloatingPanel.init` calls it on itself, no other behavior added.
T-104 · 2026-09-18 · verified: `make app` builds and signs with `Recorder Dev`; `make test` passes 5/5; launched `build/Recorder.app/Contents/MacOS/Recorder` in the background, alive after 3 s with no crash output, killed cleanly · deviations: added `Sources/Recorder/Recording/RecordingSettings.swift` (`@Observable`, exact shape from the task's code block, UserDefaults-backed one key per property), `Recording/ToolbarView.swift` (SwiftUI toolbar: close · 3 mode buttons · 3 input buttons · gear, reads `RecordingSettings.shared` directly, mode buttons only set `settings.mode`), `Recording/ToolbarController.swift` (owns the `FloatingPanel`, positions it bottom-centre 40 pt above the Dock on the screen under the mouse, builds every native `NSMenu` from SPEC §4.2 — camera/mic via `AVCaptureDevice.DiscoverySession`, system audio incl. the multi-check "selected apps" submenu from `NSWorkspace.runningApplications`, settings gear with the countdown submenu — and observes `AVCaptureDevice.wasConnectedNotification`/`wasDisconnectedNotification`, falling back a disconnected *selected* device to "Don't record…"); `AppDelegate.swift` wired minimally (status item + `File ▸ New Recording`/`⌘N` both call `ToolbarController.shared.show()`, `applicationShouldHandleReopen` for dock-icon click, launch shows the toolbar instead of nothing when permissions are already granted, onboarding's Continue now also shows it). Two ponytail-forced deviations from the task's literal wording, both load-bearing, not cosmetic: (1) `FloatingPanel` is declared `final`, so `Esc`→`cancelOperation(_:)` (AC-TB-4) is implemented on a small `private final class ToolbarHostingView: NSHostingView<ToolbarView>` instead of a `FloatingPanel` subclass — same responder-chain mechanism the task names, different class; (2) `AppDelegate`/`ToolbarController` are plain (non-`@MainActor`) `NSObject`s, not actors, because marking either `@MainActor` under Swift 6 tools (even in language mode 5) forced `@MainActor` down through `main.swift`'s top-level code, which is out of this task's file list — deferred to whichever task first needs real actor isolation. `--selftest permissions` still prints `screen=false accessibility=false` in this (unsigned-for-TCC) environment, so the toolbar itself couldn't be visually driven by this agent. Skipped building the `[Resize]`/`Device` mode and per-mode overlays — out of scope per the task ("No 'Device' button"; overlays are T-105/T-107/T-108).
T-105 · 2026-09-18 · verified: `make build` succeeds with `Sources/Recorder/Recording/SelectionRectView.swift` added (`SelectionRectView: NSView`, exact stored-property signatures from the task's code block: `rect`/`limit`/`minSize`/`aspect`/`onChange`); `make test` passes 5/5 · deviations: `rect`'s `didSet` clamps into `limit`/`minSize` itself (re-entrant, guarded on equality) so the invariant holds for every external and internal assignment, not just drag gestures; one private `Handle` enum (8 cases) plus one `resized(from:handle:mouse:option:aspect:)` routine drives every resize handle *and* rect creation (creation reuses the `.bottomRight` case dragged from a zero-size rect at the mouse-down point) — the "one hit-test/resize routine parametrised by handle" the task asks for; ⌥ mirrors the opposite edge around the drag-start centre, ⇧ locks to the rect's aspect at mouse-down (or the `aspect` property when set); handle cursors use `NSCursor.frameResize(position:directions:)` (macOS 15 API, matches the "macOS 15+, Apple Silicon" target in CLAUDE.md) instead of the coarser pre-15 resize cursors, giving correct per-corner/edge cursor shapes. Not HUMAN-visually verified yet (no host window exists until T-108 wires it up, per the task's own "exercised by T-108" Verify note).
T-106 · 2026-09-18 · verified: `make build` succeeds with `Sources/Recorder/Recording/CaptureTarget.swift` added (`enum CaptureTarget { case display(SCDisplay), window(SCWindow), area(SCDisplay, CGRect) }` with `filter(content:settings:)`, `configuration(settings:)`, `pixelSize`, `scale`, `frameInScreenPoints` exactly per the task's signatures); `make test` passes 5/5 · deviations: none from the task's code block. `filter` excludes `FloatingPanel.allWindowIDs` plus, when `settings.hideDesktopIcons`, windows owned by `com.apple.finder` at `CGWindowLevelForKey(.desktopIconWindow)` — SPEC §9 open question 3 can't be verified without Screen Recording permission on this machine, so that heuristic is marked `// ponytail:` with the upgrade path (confirm against a live `SCShareableContent` listing once granted, record the answer in SPEC §9) instead of guessing a different design. `configuration` sets every field SPEC §4.8 lists (`showsCursor=false`, 1/60 s interval, `420v`, `queueDepth=6`, even-rounded `width/height`, `sourceRect` for `.area`, `capturesAudio`/`excludesCurrentProcessAudio`/`captureMicrophone`/`microphoneCaptureDeviceID`, 48 kHz/2 ch). `scale` for `.window` falls back to `NSScreen.main` (SCWindow doesn't expose its owning display) — also flagged `// ponytail:` since it's a corner-cut, not the open question.
T-102 · 2026-09-18 · HUMAN confirmed: user granted both permissions via onboarding, "granted permissions all good" · deviations: none
T-104 fix · 2026-09-18 · root cause(s): `Recording/FloatingPanel.swift` panel `level` was `CGShieldingWindowLevel()-1` (the system screen-shield level, ~2.1e9, non-interactive by design) instead of SPEC §4's `.screenSaver-1`, and `content` was never made first responder (`initialFirstResponder` only auto-populates from the designated initializer's contentView, which is replaced after `super.init`) so `cancelOperation(_:)`/Esc never fired · verified: `make app`/`make test` (5/5) pass; headless in-process repro via synthetic `NSEvent`s (`panel.sendEvent`, no TCC needed) confirmed first responder now lands on the content view and Esc closes the panel across repeated runs; alive-after-3s smoke check clean · not verified here (no GUI/TCC in this environment): on-screen HUD vibrancy vs. white background, and the camera/mic/system-audio/gear `NSMenu` popups (not exercised headlessly to avoid hanging in `NSMenu`'s nested tracking loop) — re-check needed, T-104 stays `[~]`.
T-107 · 2026-09-18 · verified: `make build`/`make app` succeed with `Sources/Recorder/Recording/SourcePickerOverlay.swift` added (`SourcePickerOverlay` enum: `show(mode:)`/`close()`/`startRecording(target:)`/`flip(_:in:)`; private `SourcePickerWindow: NSPanel` one per `NSScreen` at `.screenSaver-2`, registered via `FloatingPanel.register`; private `SourcePickerState` `@Observable` shared across screens; SwiftUI `SourcePickerContentView` + `StartRecordingButton`); `make test` passes 5/5; launched `build/Recorder.app/Contents/MacOS/Recorder` in the background, alive after 3 s with no crash output, killed cleanly · deviations: the "one function" for "set mode + show its picker" (reused by T-207b's status menu and T-204's hotkeys per their own PLAN wording) lives on `ToolbarController` as `selectMode(_ mode:)` (sets `RecordingSettings.shared.mode` then calls `SourcePickerOverlay.show(mode:)`), not inside the new file itself — matches the existing `.shared.show()/.close()` singleton pattern AppDelegate already calls into, and both T-207b's and T-204's own task text point at "what the toolbar mode buttons call" as that one function. `ToolbarView`'s mode buttons now call `onSelectMode(mode)` instead of setting `settings.mode` directly (new closure param); `ToolbarController.show()` also calls `SourcePickerOverlay.show(mode:)` so the picker is visible whenever the toolbar is (matches SPEC §4.2's flow and lets the two reference screenshots be compared directly), and `ToolbarController.close()` now also calls `SourcePickerOverlay.close()` (ⓧ closes toolbar+overlay together per SPEC). AC-TB-4 (Esc closes overlays first, then toolbar) wired by making the overlay under the mouse the key window; its `cancelOperation` closes the overlay and re-shows/re-keys the toolbar panel (via `ToolbarController.shared.show()`, a no-op panel-recreation since one already exists) so a second Esc reaches the toolbar's own `cancelOperation`. `NSTrackingArea(options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved])` on each overlay's content view drives both "active display" (enter/exit) and window-mode hit-testing (continuous move), per the task's "(tracking area)" hint. Window list (`SCShareableContent.windows`) is fetched once when the picker opens, not re-polled while open — `// ponytail:` comment with upgrade path (periodic refresh) since SPEC only requires live *hover* tracking, not a live window list. `SourcePickerWindow`'s screen property is named `targetScreen` (not `screen`) because `NSWindow` already declares a `screen` property (compile error otherwise). Not HUMAN-verified: this machine has no Screen Recording/Accessibility TCC grants for this agent, so the overlays' on-screen appearance vs. the two reference screenshots (AC-DSP-1, AC-WIN-1) couldn't be checked — task marked `[~]`.
T-104 polish · 2026-09-18 · root cause(s), all in the shared `Recording/FloatingPanel.swift`: (A) `.hudWindow` blends with whatever is behind the window, so over a bright app it read as washed-out mid-grey instead of near-black — fixed by forcing `effect.appearance = NSAppearance(named: .vibrantDark)` and adding an opaque-layer `Theme.bgPanel` tint view (alpha 0.7) between the effect view and `content`. (B) `layer.cornerRadius`+`masksToBounds` doesn't clip an `NSVisualEffectView`'s behind-window blur, leaking square corners past the rounded shape with a rectangular shadow — fixed with a resizable rounded-rect `NSImage` (`capInsets`/`resizingMode = .stretch`, radius `Theme.Radius.panel`) set as `effect.maskImage`, `masksToBounds` removed (kept `cornerRadius` only so the 1px `Theme.stroke` layer border still follows the rounded shape), `invalidateShadow()` called after layout so the window shadow follows the mask. (C) `ToolbarController.popUp` anchored menus at `NSEvent.mouseLocation`, overlapping the toolbar — fixed to keep mouse-x but anchor the menu's bottom edge to `panel.frame.maxY` so menus open above the toolbar like the reference · verified: `make app` builds and signs with `Recorder Dev`; `make test` passes 5/5; launched `build/Recorder.app/Contents/MacOS/Recorder` in the background, alive after 3 s with no crash output, killed cleanly · not verified here: no display/WindowServer access in this environment (`screencapture` fails with "could not create image from display"), so the on-screen dark-HUD tint, clean rounded corners/shadow, and menu position above the toolbar could not be visually confirmed — re-check needed, T-104 stays `[~]`.
T-108 · 2026-09-18 · verified: `make build`/`make app`/`make test` (5/5) all pass; launched `build/Recorder.app/Contents/MacOS/Recorder` in the background, alive after 3 s with no crash output, killed cleanly · deviations: added `Sources/Recorder/Recording/AreaSelectionOverlay.swift` (`AreaSelectionOverlay` enum `show()`/`close()` wired the same way as `SourcePickerOverlay`; private `AreaSelectionWindow: NSPanel` at `.screenSaver-2` hosting `SelectionRectView` full-screen plus the reused `StartRecordingButton` positioned below the toolbar's 40pt-above-Dock line; private `AreaSelectionState` `@Observable` bridge that persists the rect to `UserDefaults` (`NSStringFromRect`/`NSRectFromString`, keyed `"area.rect.<displayID>"`) on every change and converts between `SelectionRectView`'s bottom-left view coords and `CaptureTarget.area`'s top-left display-point coords; `AreaFieldsView` SwiftUI panel with `TextField(value:format:.number)` Size/Position fields two-way bound via `AreaSelectionState.topLeft`). Minimal wiring outside the named file, all load-bearing: `SourcePickerOverlay.show(mode:)`/`close()` now route `.area` to `AreaSelectionOverlay.show()`/always call `AreaSelectionOverlay.close()` (so `ToolbarController.selectMode(.area)`, mode-switching, and closing the toolbar all show/hide the right overlay — no changes needed in `ToolbarController.swift` itself, it already calls through `SourcePickerOverlay.show(mode:)`/`close()`); `StartRecordingButton` and the `NSScreen.displayID` extension un-`private`-ed in `SourcePickerOverlay.swift` for reuse instead of duplicating ~30 lines of button+menu code. Root-cause fix in the shared `SelectionRectView.swift`: `clamp(_:to:minSize:)` was inflating a fresh `.zero` rect to `minSize` (100×100) the instant `limit` was set, so opening the overlay always showed a pre-drawn rect instead of SPEC §4.5's "No rect yet: crosshair cursor, drag to create" — fixed by leaving an exactly-zero rect untouched (a real drag/resize never starts from zero, so create/resize/move behavior for T-105's existing users, i.e. the future crop sheet, is unchanged). Esc closes the overlay and re-keys the toolbar exactly like `SourcePickerWindow.cancel()` (`AreaSelectionWindow.cancelOperation`/`AreaFieldsHostingView.cancelOperation`), so a second Esc reaches the toolbar per AC-TB-4. Not HUMAN-verified: this machine has no Screen Recording/Accessibility TCC grant for this agent, so the overlay's on-screen appearance, drag/resize/⇧/⌥/arrow-key behavior, Size/Position field sync, and per-display rect persistence across reopen couldn't be exercised — task marked `[~]`.
T-401 · 2026-09-18 · verified: core-lane merged, `make test` 14/14 on master (6 listed tests) · deviations: interior restoreCut with differing neighbour speeds re-inserts the range as a 1× clip; split also refuses pieces < 0.1 s source
T-402 · 2026-09-18 · verified: `make test` 14/14 on master (3 listed tests) · deviations: ids stay `String` in JSON, public ops take `UUID` and convert at the boundary; addZoom starts at `s` and shrinks to the gap; layouts/masks share the zoom invariants
T-410 (core only) · 2026-09-18 · verified: `make test` in lane, 4 listed tests · deviations: rule 5 clamps before dropping < 1 s so no short zoom survives at the ends; wiring pending
T-207 · 2026-09-18 · verified: `make app` builds and signs with `Recorder Dev`; `make test` passes 18/18; launched `build/Recorder.app/Contents/MacOS/Recorder` in the background, alive after 3 s with no crash output, killed cleanly · deviations: added `RecordingSettings.fps` (default 60) and `.projectsFolder` (default `~/Movies/Recorder`) — SPEC §8 properties the class lacked, same one-`UserDefaults`-key-per-property style as the rest of the class; `SettingsWindow` (in `App/SettingsView.swift`) is the one reusable window (`enum` with a cached `NSWindow`, `.titled, .closable`, hosting `SettingsView` via `NSHostingView`), opened by `AppDelegate.openSettings` (wired to the "Recorder ▸ Settings…" `⌘,` item, which previously had `action: nil`) and by `ToolbarController.openSettingsWindow` (wired to the gear menu's "Settings…" item, previously inert per its own T-207 comment, now removed). Scope matches this task's text exactly (General: projects folder only; Recording: fps 30/60, countdown, the 3 toggles) — SPEC §8's "default export settings" / "after recording: open editor" General fields and the Shortcuts pane are out of scope (M6 / other tasks) per the task's own wording. Not HUMAN-verified: no display/WindowServer or TCC grant in this environment, so opening the window via `⌘,`/gear-menu and value persistence across a real relaunch couldn't be visually confirmed — task marked `[~]`.
T-301 · 2026-09-18 · verified: lane-library merged; `--selftest library` OK on master · deviations: thumbnail is read-only here (writing belongs to T-111 finish); SelfTest harness now pumps the main run loop instead of blocking on a semaphore (cases using DispatchQueue.main hung)
T-303 · 2026-09-18 · verified: `--selftest model` OK on master (undo/redo equality, 10-update gesture = 1 undo step, autosave on disk after 0.6 s) · deviations: none
T-403 · 2026-09-18 · verified: lane-paths merged, `make test` 29/29 on master · deviations: the plan's 0.01 step-vs-closed-form bound is unreachable for semi-implicit Euler at dt = 1/240 (error ∝ (ω·dt)²); measured peaks focused 0.015, smooth 0.010, cursorSmooth 0.022, cursorMedium 0.038, cursorRapid 0.071 — test asserts per-preset bounds over the whole transient + < 1e-3 settled
T-411 · 2026-09-18 · verified: 4 listed tests green · deviations: shake removal/loop/rotation are `// T-604` comments per plan; 0.5 px tolerance assumes a 1920 px wide source
T-412 · 2026-09-18 · verified: 4 listed tests green · deviations: test renamed `cameraSampleIsOrderIndependent` (free-function test names share one namespace with T-411's `sampleIsOrderIndependent`)
T-109 · 2026-09-18 · verified: lane-capture merged, `make app` OK; `--selftest events 3` exits 1 cleanly without TCC (agent shell) · deviations: none; HUMAN run pending
T-110 · 2026-09-18 · verified: `make app` OK; `--selftest record display 3` exits 1 cleanly without TCC · deviations: `finish()` returns `Source` (the type is top-level in Core, not nested in `Project`); HUMAN run pending
T-206 · 2026-09-18 · verified: `make app` builds and signs with `Recorder Dev`; `make test` passes 29/29; launched `build/Recorder.app/Contents/MacOS/Recorder` in the background, alive after 3 s with no crash output, killed cleanly · deviations: `WindowResizer.resize` matches the AX window by title only (falls back to the front-most AX window when the title is nil/unmatched) since the normative signature carries no frame param — noted as `// ponytail:` with an upgrade path; the `[Resize]` control sits next to the size line ("1440 × 834  [Resize]") per the SPEC §4.4 ASCII mockup rather than next to the Start-recording button (the task text's looser paraphrase); 9:16/16:10/Square submenu sizes aren't listed verbatim in SPEC §4.4 (only 4:3's five sizes are) so five round numbers per ratio were chosen matching the 4:3 list's pattern; saved sizes stored in `UserDefaults` as `[[Double]]` under key `WindowResizer.savedSizes`. Not HUMAN-verified: no Screen Recording/Accessibility TCC grant for this agent, so AC-WIN-2 (real resize + highlight/size-label follows, oversize presets disabled, Custom… remembered) couldn't be exercised — task marked `[~]`.
T-304 · 2026-09-18 · verified: `--selftest render` OK on master; coordinator viewed the PNG (rounded corners, soft shadow, ~8 % padding, violet background — matches SPEC §6.1); `layoutFitsAndCentres` green · deviations: layout math is the free function `screenRect(...)` (a `Layout` type already exists in Project); shadow drawn on a full-canvas quad; screen texture is a synthetic gradient until T-306/T-413
T-305 · 2026-09-18 · verified by lane agent: `--selftest composition` 2.0 s single clip and 1.5 s two-clip (1× + 2×) fixtures OK; builds on master · deviations: `audioTimePitchAlgorithm` belongs to AVPlayerItem → T-306; TextureCache returns luma only until shader mode 4 (T-306), both `// ponytail:`
T-201 · 2026-09-18 · verified: `make app`, launch smoke · deviations: exposes CaptureSession `t0/pausedSoFar/isPaused` + internal `TrackWriter`; camera TCC gate via `CameraCapture.request`; HUMAN pending
T-416 (peaks) · 2026-09-18 · verified: `--selftest waveform` on big-endian aiff and m4a; coordinator caught byte-swapped samples (missing `AVLinearPCMIsBigEndianKey: false`), fixed; selftest now range-checks the peak
T-603 (core) / T-202 (file) · 2026-09-18 · merged; wiring pending
KNOWN ISSUE · `--selftest library` flaked 1/7 on master: `ProjectStore.duplicate` copies into the watched folder before fixing `project.json` title, so a reload can see the stale title (and the folder watcher never fires for the later in-package write). Fix in T-302: copy to a temp dir, rewrite project.json, then move into the folder.
T-107/T-108 fix · 2026-09-18 · root causes: (1) window hit-test used an unordered `SCShareableContent.windows` list and picked the first match instead of the front-most — now ordered via `CGWindowListCopyWindowInfo` front-to-back, matched by `windowID`; (2) the hover point was double-flipped (`NSHostingView` is always top-left/flipped, confirmed with a standalone `swift` snippet) — now built from `NSEvent.mouseLocation` directly; (3) `SourcePickerWindow` never forced first responder onto its content view on `makeKeyAndOrderFront` (same bug `FloatingPanel` documents), so `Esc` reached nothing after a mode switch — confirmed with a standalone script (`firstResponder === window`, not the view, without the fix) — added the same override; (4) `Esc`'s handler called `ToolbarController.show()` to re-key the toolbar, which also re-opened the just-closed overlay — replaced every overlay/toolbar `cancelOperation` with one shared `ToolbarController.handleEscape()`; (5) area-selection `minSize` enforcement in `SelectionRectView.resized(...)` grew a too-small rect from the wrong corner (always `(minX,minY)`), dragging the anchor instead of the tracked edge — confirmed by reverting the fix and re-running `--selftest pickers` (anchor moved `700→800`) — now grows the dragged edge only, anchor fixed; also guarded the Size/Position fields from writing into `rect` mid-drag. Verified: `make build`/`make app`/`make test` (35/35) all pass; new `--selftest pickers` (create/resize drag math + window hit-test ordering) → `SELFTEST pickers OK`; launch smoke (alive 3 s, killed own PID). T-107/T-108 left `[~]`, WAITING ON HUMAN notes updated with re-check items (AC-WIN-1, AC-AREA-1, AC-TB-4).
T-301 fix · 2026-09-18 · root cause: duplicate/rename moved the package into the watched folder before rewriting project.json → stale title could stick; now staged in an item-replacement dir then moved · verified: `--selftest library` 30/30 (agent) + 15/15 (coordinator)
T-302 · 2026-09-18 · verified: `make app`, 35 tests, `library-png` render reviewed by coordinator · deviations: opens reveal in Finder until T-307; HUMAN pending
T-107/T-108 fix · 2026-09-18 · merged (b131bb7): flipped hover point + unordered window list; min-size clamp moved the drag anchor; overlay never first responder + Esc handler reopened the overlay → one `ToolbarController.handleEscape()`; `--selftest pickers` OK · HUMAN re-check pending
T-111/T-112/T-113 · 2026-09-18 · verified on master: `make app`, 38 tests, `--selftest recover` OK, launch smoke · deviations: `CameraCapture.current` weak static for the camera hand-off; editor hand-off call site marked in RecordingController.finish; finish fills zooms via generateAutoZooms (T-410 wire, menu items still open) and writes thumbnail.jpg
T-308 · 2026-09-18 · verified on master: `--selftest inspector` OK, PNG reviewed · deviations: `LabeledSlider` gained `onEditingChanged`; 12 generated wallpapers in Resources/Wallpapers (Makefile copies them); gradient angle has no control
T-404/T-405/T-406 · 2026-09-18 · verified on master: TimelineGeometry tests (3) green, `timeline-png` with hit-test assertions OK, PNG reviewed · deviations: minimal TimelineToolbar (Fit + zoom slider); cut-bubble hit box sits in an 8 pt sliver above the clip lane
T-604 (core) / T-309 (core) · 2026-09-18 · verified: core-lane merged, `make test` 43/43 on master · deviations: shake threshold assumes a 1920 px reference width (`// ponytail:`); rotation = clamp(vx·12°, ±12°); always-arrow = `imageID nil` (renderer draws the default arrow)
T-306/T-307 · 2026-09-18 · verified on master: `make app`, 43 tests, `preview-frame` OK (PNG reviewed), `--open` smoke by agent · deviations: shader mode 4 (BT.709 video range) + two-plane TextureCache; `Compositor.render(viewport:)` letterboxes; camera decode and CameraPath/CursorPath sampling deferred to T-502/T-413; aspect popup + Crop button unwired until T-309/T-310
integration · 2026-09-18 · wired the M3/M4/T-309 hand-off points left by the parallel lanes: `EditorWindowController` hosts real `InspectorView`/`TimelineView`+`TimelineToolbar` (placeholders removed); `Library.open`/`RecordingController.finish` now call `EditorWindowController.open(package:)`; top-bar `‹ Projects` → `Library.show()`, `⌗ Crop` → `CropSheet.present(for:on:)` (T-310 had already landed on master by the time this ran); `Compositor.outputSize(for:longEdge:)` delegates to `RecorderCore.outputSize(aspect:croppedSource:longEdge:)`; aspect popup edits `project.output.aspect` via `model.edit` and stays synced through undo/redo (`withObservationTracking`) · verified: `make app`, `make test` 47/47, selftests `metal model library pickers recover inspector render crop inspector-panels preview-frame` all OK, new `editor-png` selftest OK + PNG reviewed (preview | 300 pt inspector over timeline matches SPEC §6.1; MTKView area blank and the titlebar accessory 0-width are known offscreen-capture gaps, not app bugs), `--open` smoke launch alive 4 s / no crash, killed cleanly · deviations: none beyond the two capture gaps noted above (see `// ponytail:` above the `editor-png` case)
T-109 · 2026-09-18 · VERIFIED with real TCC (launched via `open -n … --args --selftest events 3`, Recorder.app's own grants): counts move=78 cursor=1, cursor image written → `SELFTEST events OK`
T-110 · 2026-09-18 · VERIFIED with real TCC (`open -n … --args --selftest record display 3`): duration 2.98 s, size 2880×1800, events.json present → `SELFTEST record OK`
T-312 · 2026-09-18 · verified: `--selftest library-perf` 108–182 ms for 200 packages (< 300 ms, AC-LIB-1); no ProjectStore change needed
T-310 / T-414 / core halves of T-503, T-602, T-605 · 2026-09-18 · merged; see task notes
NOTE · agents can run TCC-gated checks through LaunchServices: `open -n --stdout OUT --stderr ERR build/Recorder.app --args --selftest <name> …` (shell-launched binaries inherit the terminal's missing grants).
T-606 · 2026-09-18 · verified on master: `--selftest import` OK (package contents, measured source, single full clip, original untouched), staged via `stageThenMove` · deviations: no fps on `Source` (not in SPEC §5); imports get kind `.display`, no audio/camera flags
T-605 · 2026-09-18 · verified on master: Core `presetRoundTripAndApply` + `--selftest presets` OK (save/list/apply through EditorModel = 1 undo step, export/import round-trip, delete) · deviations: "Presets ▾" menu sits above the inspector tab bar (SPEC gives no location)
T-203/T-204/T-205/T-207b · 2026-09-18 · verified on master: `make app`, 47 tests, `--selftest menus` OK, real-TCC `record display 3` still OK after the `elapsed` refactor (3.0 s, 2880×1800), `finder-windows` answered SPEC §9 Q3 · deviations: `CaptureSession.elapsed` now host-clock based; widget shown before the exclusion snapshot (follow-up fix); Delete alert default = Keep Recording
T-607/T-608 · 2026-09-18 · merged: `command-menu` selftest OK; root fix `NSApp` → `NSApplication.shared` (nil under --selftest); menu bindings pending T-311
T-311 (+ T-410/T-603/T-604/T-607/T-608 menu halves) · 2026-09-18 · verified: `make app`; `make test` 48/48 (adds `speedUpTypingKeepsInvariants`); selftests `metal model library pickers recover inspector inspector-panels crop menus command-menu import presets menu-actions editor-png` all OK; new `--selftest menu-actions` builds the real `AppDelegate.buildMainMenu()` + a real offscreen `EditorWindowController` over a fixture package and checks target==nil (responder chain, not a manager object), `sendAction` resolves nothing with no editor open, `validateMenuItem` approves/titles items correctly once an editor exists, and Split/Remove/Add Zoom/Regenerate Auto Zooms/Remove All Zooms/Restore All Cuts/Speed Up Typing/Hide Cursor each produce the documented `Project` change with `checkInvariants() == nil` and exactly one `performUndo`/`performRedo` step; launch smoke (alive 3 s, killed own PID) · deviations: (1) Undo/Redo wired to custom `performUndo`/`performRedo` selectors (not the standard `undo:`/`redo:` pair, to avoid any collision with `NSTextView`'s own undo manager on text fields) — titles rewritten with the edit name in `validateMenuItem` since `EditorModel` gained parallel `undoNames`/`redoNames` stacks (cheap, per the task's own "if cheap" wording); (2) Remove's/TimelineView's own `⌫` handling couldn't be reused (private, different file, per T-311's boundary) — the same few lines are duplicated in `EditorWindowController.removeSelected`; (3) `AppDelegate.buildMainMenu`/`buildIdleStatusMenu`-style status menus stay `private`→un-`private` only where a selftest needs to call them directly (matches the existing pattern). Root-cause fix (coordinator report, filed against this same task): the editor window's titlebar top bar (‹ Projects · title · Auto ▾ · Crop · Export) rendered completely empty, live and offscreen alike. Two stacked bugs, both found with a temporary diagnostic background tint that never appeared on screen: (a) `NSTitlebarAccessoryViewController` with `.layoutAttribute = .right` never reliably sized the wide, multi-control bar in this environment regardless of its own Auto Layout constraints — dropped entirely in favor of `window.styleMask.contains(.fullSizeContentView)` + the bar as one more manually-positioned subview of `EditorRootView` (same plain frame-layout style already used for preview/inspector/timeline); (b) the first fix attempt used a same-class `didSet`-relay property to swap the real (button-wired) bar in after `super.init()` — Swift never fires property observers for assignments made from inside the declaring type's own initializer, no matter how many times or how late, so the "real" bar was silently never installed; fixed by assigning `rootView.topBar` directly (a different object's property, not `self`'s own) instead of through a same-class relay. `EditorWindowController.swift`'s top-bar section documents both. Not verified: a real on-screen screenshot of the live app — this machine's screen is shared with other concurrent agents/the user's own apps, and `open -n --args --open <pkg>` + `osascript activate` couldn't reliably keep the Recorder window frontmost long enough to capture it (another window kept stealing focus); the offscreen `editor-png` selftest exercises the identical `EditorWindowController` construction path (`makeOffscreen` calls the same private `init`) and shows the top bar rendering correctly, which is the strongest verification available headlessly — HUMAN should confirm the on-screen look matches SPEC §6.1 next time the app is run interactively.
T-505 · 2026-09-18 · verified on master: `--selftest export` (duration exact, 1280×720, decodable) and `--selftest parity` maxDelta=0 over 7 times incl. 2× clip / zoom / frame boundary (AC-ED-2, AC-EXP-4) · deviations: root-caused a one-frame offset (exporter picked first PTS ≥ t, preview shows last PTS ≤ t) — both now use largest PTS ≤ t; audio appended after video
T-507 · 2026-09-18 · verified on master: `--selftest export-gif` (23 frames for 1.5 s, loop 0, delay 0.067 s, long edge 960) · deviations: fps clamped to ≤ 24; GIF loop is a separate function reusing FrameHold/makeFrameState/Compositor
T-407/T-408/T-409/T-416 draw · 2026-09-18 · merged; `timeline-ops` OK on master · deviations: root fixes in TimelineOps `addBlock` boundary (`<` not `<=`) and drag modifiers read from the event; clip "Mute Audio" menu item disabled (no field)
T-413 · 2026-09-18 · merged; EditorModel caches CursorPath/CameraPath, rebuilt only when zooms/cursor/animation.screen/cursorHidden change
Inspector tabs (T-604/T-502/T-504/Animations/T-602 UI halves) · 2026-09-18 · merged; omitted for lack of fields: Keys size/position, Camera "Add fullscreen layout"
T-307 fix · 2026-09-18 · titlebar top bar now visible in a REAL screenshot (‹ Projects · Auto ▾ · Crop · Export); OPEN BUG: live preview shows no video frame when paused at open on master (works in the render lane's own build) — being debugged on the integration branch
T-506 (remainder)/top-bar title fix · 2026-09-18 · verified: `make app`, `make test` 48/48; `--selftest metal model library pickers recover inspector inspector-panels crop menus menu-actions command-menu import presets timeline-ops export-sheet editor-png` and `parity /tmp/fixture2.recorder` all OK; `editor-png` PNG reviewed before/after — title now reads "Fixture" in the top bar. Root cause of the missing title: an editable `NSTextField` (`NSTextField(string:)`'s default) reports `NSView.noIntrinsicMetric` (-1) for its `intrinsicContentSize.width` until it actually becomes the window's field editor, so the top bar's `NSStackView` read "no natural width" and collapsed it to ~4 pt — the text was always there, just laid out at near-zero width. Fixed in `Editor/EditorWindowController.swift`: new private `TitleField: NSTextField` starts `isEditable = false` (real intrinsic width, matches the mockup's static look) and flips `isEditable = true` on `mouseDown` for the click-to-rename gesture (SPEC §6.1), flipping back off in `titleCommitted` once editing ends; rename itself is unchanged, one `model.edit("rename") { $0.title = newTitle }`; deliberately does NOT also rename the package directory the way `ProjectStore.rename` (`Library/ProjectStore.swift`, SPEC §5.1's Library card rename) does — that would need `EditorModel.packageURL` (currently `let`) to become mutable and `EditorWindowController.openWindows`'s URL-keyed registry to be re-keyed live, both in `EditorModel.swift`/outside this task's file set, for a rename gesture SPEC §6.1 only labels "(click = rename)" without SPEC §5.1's explicit "(renames the package dir)" wording. BLOCKED-ish, not asked: flagging the drift (package dir name vs. `project.title` can diverge after an editor-title rename) for a human/product call rather than expanding scope. Export wiring: top-bar `⬆ Export` button (was `isEnabled = false`, `target = nil`) now `target = self, action = #selector(exportTapped)`; added Export ▸ `Export…`/`Copy Frame as Image` menu items' actions (`AppDelegate.buildMainMenu`, `target = nil`, responder-chain-resolved like the Edit/View items) · deviations: none beyond what's noted above.
T-609 · 2026-09-18 · verified headlessly (see the task's own log lines above); not ticked `[x]` — the Settings ▸ Shortcuts pane's click-to-record control needs a HUMAN (no UI automation) · deviations: none
T-501/T-502/T-503 (render) · 2026-09-18 · verified on master: 48 tests, parity maxDelta=0 on /tmp/fixture2 and /tmp/CamFixture (9 samples incl. zoom transition + layout fade), `camera-drag` OK · deviations: ROOT FIX in FrameSource.makeComposition — camera/mic/system AVURLAssets were released while their tracks were still in use (every project with a camera failed to load); camera bubble margin 2 % of short edge; system .heic wallpapers now load by absolute path
T-417/T-503 lane/T-601 lane · 2026-09-18 · verified on master: `timeline-ops`, `mask-rect`, `inspector-panels` OK · deviations: generic add/move/resize block engine keyed by WritableKeyPath in TimelineOps; MaskPanel has kind/opacity only
T-609 · 2026-09-18 · merged (see task note): `hotkeys` selftest OK; Copy Frame renders via the exporter's AVAssetReader path (a first AVPlayer-based version deadlocked under load — found via a 2 h hung selftest, fixed at the root)
T-307 fix · 2026-09-18 · top-bar title invisible because an editable NSTextField has no intrinsic width → `TitleField` starts non-editable, editable on click
PERF · 2026-09-18 · export-perf 60: 19.49 s / 184.7 fps (load avg 10–14); record-perf 20: CPU 0.4 % avg, 1040 frames delivered (idle desktop), hvc1
T-415/hover-preview final wiring · 2026-09-18 · verified: `make app` (no `error:`), `make test` 48/48; final integration pass wired `EditorWindowController`'s init to `timeline.onHoverTime = { [weak preview] in preview?.hoverTime = $0 }` (AC-TL-7, `Editor/TimelineView.swift`'s own documented hook), replacing a stale "would connect here" comment — `hover-preview /tmp/fixture2.recorder` OK (hover moves the player without moving `model.playhead`; `nil` restores it), `zoom-target`/`zoom-target-png` still OK, `parity` maxDelta=0 on `/tmp/fixture2.recorder`/`/tmp/CamFixture.recorder`/`/tmp/M6Fixture.recorder` · deviations: none; T-415 left `[~]` (selftests pass, live drag feel needs HUMAN).
T-601 mask overlay mounted · 2026-09-18 · verified: `make app`, `make test` 48/48; `mask-rect` + new `mask-overlay` selftests OK, `zoom-target`/`crop`/`menu-actions` unaffected, `parity` maxDelta=0 on all three fixtures, `editor-png`/live screenshot reviewed. Wired `MaskRectOverlay` over the live preview per its own documented hook: `PreviewView` gained a `maskOverlayView` mount point + `onResize` callback (`Editor/PreviewView.swift`), forwarded through the same single mouse-dispatch point as the T-415 zoom-target overlay/camera-bubble drag (mutually exclusive by construction — selection is one lane at a time); `EditorWindowController`'s init creates the overlay, sets `preview.maskOverlayView`/`preview.onResize`, and calls `layout(in:)` once. Root cause confirmed and fixed at the shared mapping (`Editor/MaskRectOverlay.swift`): `layout(in:)` computed its content rect via `CropMapping.imageRect(imageSize:in:)` — the source's own letterbox only, ignoring `PreviewView`'s letterboxed viewport AND the frame's `padding` inset inside it (both insets T-415's `ZoomTargetMapping.contentRect` already accounts for) — switched to reuse `ZoomTargetMapping.contentRect(viewBounds:project:)` directly (one mapping for both overlays; `CropMapping`'s `normRect`/`viewRect` pair, which is generic rect math, stays unchanged for the NormRect↔view-rect conversion within that content rect). `PreviewView.draw` now also shows the un-zoomed frame while a mask is selected (`isMaskSelected()`), same as it already does for a selected manual zoom, so the overlay's rect matches what's on screen. Fixing the mapping (recomputing on more than just the initial mount) surfaced a second, previously-latent bug in `rectChanged`: `SelectionRectView.limit`'s `didSet` unconditionally re-touches `rect` (and thus fires `onChange`) even when reassigned to an unchanged value, so a live drag's `model.update` → observation → `updateContentRect()` → `selectionView.limit = imageRect` (same value) round trip re-fired `onChange` with a stale/zero rect and clobbered the mask's `rect` mid-drag; fixed by gating `rectChanged` on `gestureOpen` (only true inside a real user drag, bracketed by `container.onMouseDown`/`onMouseUp`), mirroring the same-purpose `zoomTargetGestureActive` gate `PreviewView.zoomTargetRectChanged` already uses. Extended `mask-overlay` selftest asserts the mapping directly for a letterboxed 16:9-in-portrait view with the project's default (non-zero, 0.08) padding: NormRect → overlay rect → NormRect round-trips within 1e-9 and the overlay rect stays inside `ZoomTargetMapping.contentRect`; `mask-rect` itself now zeroes `project.frame.padding` so its existing drag-math assertions keep their simple numbers · deviations: none beyond the root-cause fixes above.
T-504/T-602 status only · 2026-09-18 · no code change — corrected stale PLAN notes to match what's actually on master: T-504's behaviour half (live `AVAudioMix` swap, export-only denoise/click mix) and UI half (Audio tab) were already both merged; T-602's render half (`FrameState.keyChip`/`Compositor`'s Core Text chip pass) and UI half (`Inspector/KeysTab.swift`'s toggle) were already both merged too — both left `[~]`, WAITING ON HUMAN (listen for T-504, look for T-602) since nothing in either can be verified headlessly · verified: `audio-mix` OK (rms/denoise/click numbers logged above), `parity` on `/tmp/M6Fixture.recorder` (keys.show on, two `.key` events) OK.
Final integration sweep · 2026-09-18 · verified: `make app` (grepped for `error:`, none), `make test` 48/48; every selftest in the sweep OK — `metal model library pickers recover inspector inspector-panels crop menus menu-actions command-menu import presets timeline-ops mask-rect mask-overlay hotkeys zoom-target audio-mix`; `parity` maxDelta=0 on `/tmp/fixture2.recorder`/`/tmp/CamFixture.recorder`/`/tmp/M6Fixture.recorder` (`/tmp/M6Fixture.recorder` regenerated via `--selftest make-m6-fixture`, was missing `project.json`/`screen.mov` on disk); `hover-preview /tmp/fixture2.recorder` OK; `export /tmp/M6Fixture.recorder` OK (90 frames, 1280×720); `editor-png /tmp/M6Fixture.recorder` OK, PNG reviewed; one real on-screen screenshot (`open -n build/Recorder.app --args --open /tmp/M6Fixture.recorder` + `scripts/ui.sh screenshot`) reviewed, matches SPEC §6.1/§7.1 layout, app quit cleanly afterward. Also checked for built-but-unreachable UI entry points (grep for `static func show`/`present(`/`runSelfTest`-only APIs): none found — every `show`/`present` in `Sources/Recorder/**` already has a real-UI caller (menu item, button, or responder-chain action); `run*SelfTest` functions are intentional test-only harnesses over render/decode logic whose real-UI paths are separately wired.
ENV · 2026-09-18 evening · laptop lid closed: machine slept ~2 h (agents frozen), afterwards no display is online, so TCC/screenshot checks (`record`, `screenshot`) fail with "no display" — not a regression; re-run when the display is back
T-610 · 2026-09-18 · verified: `make app` (no `error:`), `make test` 48/48; selftests `snapshot` (new), `menus` (extended), `hotkeys`, `menu-actions`, `model` all OK; real run (`open -n` + `scripts/freeze-dump.sh <pid>`) produced a non-empty `sample.txt`/`ps.txt` and copied the folder path; a one-off headless visible-window run confirmed `StateSnapshot`'s own `window-<n>-<class>.png` shows real editor chrome · deviations: git commit omitted from `snapshot.json` (no build-time bake step exists in this project, task allowed omitting it); `CGWindowListCreateImage` (would avoid needing `cacheDisplay` for the own-window PNGs) is compile-time `unavailable` on this SDK, so `writeWindowPNGs` always uses `cacheDisplay` — noted as a `// ponytail:` in `StateSnapshot.swift`; `EditorWindowController.currentInspectorTab` only reflects `View ▸ 1–6` menu switches, not raw SwiftUI tab-button clicks (private `@State`, no callback out) — the more important "selection replaces the tabs" case is computed independently from `model` and stays accurate.

T-505/T-506 · 2026-09-20 · Fixed MP4 writer deadlock (video-only feeding stalled Cool Forest at frame 32): feed ready audio/video inputs together, check reader/writer failures, bound backpressure/finalization waits, synchronize cancellation and remove partial files on failure. Verified Cool Forest 1378×1080/24 fps: 190 frames, H.264 and HEVC ≈1.4 s; expanded audio-mix regression to 60 decoded frames and cancellation at frame 32 (<1 s, partial deleted). Export sheet now has visible idle Cancel, bordered Cancel export with cancelling feedback, Escape cancellation/dismissal and idle/completed click-away. `audio-mix`, `export-sheet` (including AppKit outside-click/Escape), `export-colors`, idle/failure PNG checks passed.

T-611 / DEF-1107 · 2026-09-22 · Restored session-scoped display/window picker selection, validated live sources, excluded own app windows, added unavailable-window prompt and discarded stale async refreshes. Verified `make app`, LaunchServices `--selftest recording-focus` (live SCWindow restore, real visible panels, display return/fallback, explicit replacement and mode switch), `pickers`, `recording-dismissal` all OK. Synthetic resolver assertions cover fresh/removed/empty sources.

T-612 / DEF-1108 · 2026-09-22 · Added Project.exportDuration for last retained screen/camera endpoint; retained interior gaps and timeline edit space. Sheet duration/size, MP4/GIF frame count, reader bounds and MP4 session end now agree. Empty exports disabled/rejected. Verified targeted Core test, make app, export-range (real MP4/GIF, audio tail, camera, undo/redo), export-sheet and audio-mix all OK. No user range state exists to clamp; no new range UI introduced.

T-613 / DEF-1109 · 2026-09-22 · Highlight minimum is one cropped-source pixel with independent handle hit targets; body drag, resize grab offset and bounded geometry; outside drags do not recreate a selected mask. Fixed shared clamping callback so persisted geometry agrees with display; preview retains rectangle focus; Escape rolls back without undo entry and responder-chain fallback preserves crop cancellation. make app and highlight-manipulation/pickers/mask-rect/crop/zoom-target all OK; /tmp/recorder-small-highlight.png inspected.

T-614 / DEF-1110 · 2026-09-22 · Command-click scissors dispatches shared semantic split at output playhead without toggling tools; mouse-down modifier survives release, toolbar refresh restores native button state, left split clip selected. Existing split mutation/boundary policy reused. make app; make test FILTER=split (4/4); command-scissors, timeline-ops, menu-actions all OK.

T-615 / DEF-1111 · 2026-09-22 · Suppressed native inferred recording-panel appearance animations at the shared registration point. Before trace: default(0); after: none(2), full alpha/visibility at every sample, stable layout and first responder. make app and recording-appearance OK; toolbar PNG inspected. Final five-ticket audit: make test 70/70; recording-appearance, recording-focus, recording-dismissal, export-range, highlight-manipulation, command-scissors all OK on the same final signed build. No remaining Nudge Recorder defects in the fetched five-ticket inventory; unrelated pre-existing agentpack.toml/pack.lock/AGENTS.md changes left intact.

T-616 · 2026-09-22 · Removed implicit post-gap fade, added optional per-clip fade controls with old-project Off defaults and outer-edge split preservation. Corrected leading-edge snapping to zero (Command bypass retained). Verified make test 71/71, make app, clip-fades (bindings/undo/redo/save/zero-snap), timeline-ops, and parity on a fixture with explicit fades: maxDelta=0 at 8 times. Inspected clip panel PNG. Existing project timing remains unchanged until edited.

T-617 · 2026-09-22 · Added gallery-advanced launch target, Black/White appearance switch, scroll-triggered rules and staggered content/lane reveals, cancellable 12-second demo and Reduce Motion handling. Built/opened both galleries; standard PNG and ui-motion passed. Advanced demo check asserted theme transitions and captured entrance/stagger, settled scroll stages and minimum size; images inspected. Media matte remains fixed; ordinary app tokens retain their original colors.

T-617 refinement · 2026-09-22 · Advanced gallery now opens White with the timeline first, followed by production Canvas/Camera/Cursor/Motion/Keystrokes panels in staggered columns, a bound key specimen, capture typography and compact widget studies. Removed the full editor shell and cursor hero. Shared camera/cursor popups refresh on appearance changes. Verified debug build, default-White render/panel-mount/full-editor-absence guards, six-stage demo in both themes, minimum-width panels, ui-motion, placement, inspector-panels and standard gallery PNG. Inspected rendered opening, panels, key specimen and native picker contrast.

T-618 · 2026-09-30 · Release CI now requires Developer ID signing and notarization with a secret Apple ID; removed ad-hoc publication fallback. YAML and every run block passed syntax checks; missing-secret gate rejected release; `make test` passed 71/71. Waiting on HUMAN Apple Developer certificate/private key, app-specific password, GitHub secrets, and clean install of a tagged release DMG.

T-619 · 2026-10-15 · lane K, re-verified on dev after merge: `make test` 81/81 (zoomTransitionSpeedIndependent), parity M6 maxDelta=0 · deviations: test tolerance 0.03 (discrete 240 Hz steps differ at zoom edges; continuous-time spring would reach 1e-3)
T-622 · 2026-10-15 · lane K: `make test FILTER=events` (legacy decode, ch round-trip), `make app` OK · NOT RUN: `--selftest events 3` — Recorder's Screen Recording/Accessibility grants are currently off (`permissions` → false); HUMAN: re-grant, then run it and check events.json (letters/arrows/modifiers/ch, nothing while paused) · deviations: char via CGEvent.keyboardGetUnicodeString (layout-aware, built in) instead of UCKeyTranslate; field `ch`
T-623 · 2026-10-15 · lane K, re-verified on dev: keyCategories/keyChipMergesAndFilters/keysLegacyAllKeysDecode pass; parity M6 maxDelta=0; inspector-panels OK · deviations: merged label keeps last 8 keys; plain characters run together (`hi`), others space-separated
T-625 · 2026-10-15 · lane V: silentRanges/splitAtPauses tests pass on dev · deviations: none
T-626 · 2026-10-15 · lane V, re-verified on dev: menu-actions OK (Split at Pauses one undo step), timeline-png inspected (48 pt lane, sqrt bars, hatched pause) · deviations: one 5 ms bucket per bar (ponytail)
T-628 · 2026-10-15 · lane T, re-verified on dev: linked*/textBlocks tests, timeline-ops, timeline-clipboard, inspector-panels OK · deviations: FILTER is `linked` (test names)
T-629 · 2026-10-15 · lane T, re-verified on dev: make-text-fixture + parity maxDelta=0 over 10 times; preview-frame PNGs inspected in lane · deviations: only Barlow Light bundled → Caption uses Light ×1.15 with drawn outline (ponytail)
T-630 · 2026-10-15 · lane T: captionPhrases test; `open -n … --selftest captions <say m4a>` recognised words → 4 phrases OK (Speech already granted) · deviations: SFSpeechRecognizer only, no SpeechAnalyzer (ponytail)
T-631 · 2026-10-15 · lane V: parity with image background maxDelta=0, export-colors OK (re-run on dev), inspector-panels OK; wallpapers 13–16 generated · deviations: aspect-fill only for image backdrops (bundled wallpapers unchanged)
T-632 · 2026-10-15 · lane V, re-verified on dev: highlight-manipulation (snap + ⌘ bypass), mask-overlay, zoom-target, pickers OK; highlightZoom Core op test · deviations: snapping off while aspect-locked or ⌥ held; area/crop also snap to frame edges (shared view)
T-620 · 2026-10-15 · lane E: zoom-target Esc check failed before the fix ("leaked"), passes after; re-verified on dev: zoom-target, highlight-manipulation OK · deviations: Esc swallowed in PreviewView while a rect overlay shows; dragSelection cleared on mouseUp and after cancel
T-621 · 2026-10-15 · lane E, re-verified on dev: menu-actions OK (selection survives ⌘Z/⇧⌘Z; undone creation leaves no dangling id) · deviations: clip selection kept by index (clips have no ids; ponytail); redo also clears the gesture snapshot
T-624 · 2026-10-15 · lane E, re-verified on dev: zoom-target (focus kept, arrow+repeats = 1 undo), highlight-manipulation, menu-actions (↑/↓ edit points, ⌘D multi), timeline-ops, inspector-panels, command-scissors OK · deviations: no project fps field → frame step uses export default fps; ColorPicker commits after 0.5 s stillness (no selftest; HUMAN feel check); camera-bubble hit order has no check
T-633 · 2026-10-15 · lane W: pickers OK (⌘-click toggle, 4-window cap); NOT RUN: record-windows 3 / record-perf 3 windows — Screen Recording grant currently refused for Recorder Dev builds (-3801); HUMAN: re-grant and run both · deviations: `.window` became `.windows([SCWindow])`; `Source.windowSizes`; `windowFrames` written only on change
T-634 · 2026-10-15 · lane W: `make test FILTER=Window` 6/6; re-verified on dev: timeline-ops, timeline-clipboard (Window lane skipped there — exists only with >1 window) OK · deviations: autoWindowShots takes `duration:`; contiguous shots incl. window 0; "Show Window N" context menu instead of a panel
T-635 · 2026-10-15 · lane W, re-verified on dev: make-windows-fixture, parity /tmp/WindowsFixture maxDelta=0, export 120 frames decoded, parity M6 (single window) maxDelta=0 · deviations: one screen track with shot inserts instead of per-window tracks (SPEC updated); cursor remap in Core `remapWindowEvents` (ponytail: exact only without unlinked clip moves); rect overlays sized for the window visible at selection time (ponytail)
Merge · 2026-10-15 · all five lanes merged into dev: `make test` 86/86, `make app`; selftests OK on the merged build: parity ×3 fixtures, export, inspector-panels, timeline-ops, menu-actions, timeline-png (inspected), timeline-clipboard (fixed: loop skipped the new Window lane), highlight-manipulation, mask-overlay, mask-rect, zoom-target, export-colors, pickers, command-scissors, clip-fades, export-range, export-sheet, audio-mix, model, metal, library, hotkeys, snapshot. `workspace-replay` (timeout, key window nil) and `crop` (Escape) fail in every lane build — checked against the pre-roadmap baseline below.

Baseline · 2026-10-15 · pre-roadmap commit acf7f73 (debug build in a temp worktree) fails `workspace-replay` (timeout, key window nil) and `crop` ("Escape did not discard the crop sheet") identically → pre-existing, not caused by T-619…T-635; both need the app to be key/frontmost, which this agent session can't guarantee. Open for a HUMAN run with the app frontmost.
T-622 · 2026-10-15 · added `--selftest key-capture`: tap decisions extracted to pure `EventRecorder.keyEvents`, driven with synthetic CGEvents (letter → key+typing with ch, Space ch " ", ⌘C key only, arrow ch nil, auto-repeat dropped, Shift press → key, release → nothing) OK; `make test` 86/86. Still HUMAN: live `events 3` once Screen Recording/Accessibility are re-granted (screen was locked during this run).
Recheck · 2026-10-15 · screen unlocked, app frontmost via LaunchServices: `crop` OK, `workspace-replay` OK on merged dev — earlier failures were the locked session, not code. `events 3` still -3801 (TCC deny entry for Recorder Dev build; needs the user's toggle).
T-633 · 2026-10-15 · live (Screen Recording granted, LaunchServices): first `record-windows 3` HUNG — merge bug: lane W's window-frame timer called `outputTime` (lane K made it take the NSLock) while holding the same non-recursive lock → deadlock in `EventRecorder.stop()` (sampled). Fixed by reading the time before locking. Then `record-windows 3 10` OK: 3 animated windows (corner square moving at 60 Hz), 3 files at their own sizes, one clock (durations within 0.75 s), centre colours correct, windowFrames for every window, avg CPU 1.1 % of one core (< 25 % AC-REC-1 bar, now asserted in the check); `record-perf 5` display regression OK (0.6 %, hvc1); `events 3` OK.
T-622 · 2026-10-15 · live (Screen Recording + Accessibility granted): new `events 3 keys` posts Shift-alone and F13 through the real tap → captured as `key` 56/105. First run FOUND A BUG: F13 also logged `.typing` (hand-kept non-printing keycode list lacked F13–F20) → root fix: `.typing` only when the key produced a printable character (`ch != nil`); list deleted. Re-run: `events 3 keys` OK (key ×2, no typing), `key-capture` OK, `make test` 86/86, parity M6 maxDelta=0.

T-640 · 2026-10-16 · Added AudioTrack/AudioClip/LayerBlock, additive version-3 project keys, legacy Mic/System derivation and TimedBlock media advancement. Verified `make test FILTER=audioModel` 4/4 and `make test` 90/90 (including AC-PRJ-1/2), both with `DEVELOPER_DIR=/Library/Developer/CommandLineTools`: the selected Xcode 6.4 compiler otherwise loads the Makefile's incompatible CLT 6.3 Testing framework. Tests cover populated JSON/disk round trips, explicit disabled fades, legacy cuts/2×/gaps/media in-points/link defaults, empty clip preservation, output-time overlaps, track/link/gain/rect checks and known media bounds. `checkInvariants(mediaDurations:)` accepts known imported-file durations; recorded audio uses source.duration. App composition/UI wiring remains T-641…T-649. Existing agentpack.toml/pack.lock conflicts preserved; task commit uses a separate index.

T-641 · 2026-10-16 · Extracted shared applyLinkedEdit; screen audio follows video with Link layers off, camera/layer audio edits propagate both ways, layer splits repoint sound, and propagate:false preserves partners. Added unlinkAudio/linkAudio, syncOffset/moveIntoSync, output-clock conversion and linked-audio video clipboard handling. Verified with `DEVELOPER_DIR=/Library/Developer/CommandLineTools`: `make test FILTER=linkedAudio` 12/12 (500 fixed-seed video/camera/layer edits, sync, split/delete/move/speed, unlink/relink, partial partners, Option overrides, mixed clocks and clipboard); `make test` 102/102; `make app CONFIG=debug`; `--selftest timeline-ops` OK. The expanded random sequence caught floating-point slivers and hidden camera references; fixed in the shared slicer and sync lookup. Clarification: Option-delete of a video layer preserves and detaches its audio rather than leaving an invalid dangling link (AUDIO-LAYERS §4.1). Connected settling, composition and UI remain T-642 onward. Existing config conflicts preserved; task commit uses a separate index.

T-642 · 2026-10-16 · Added settleConnected after video edits/clock conversion: deleted anchors move to the deletion boundary, later collisions reuse free higher lanes or create them, and connected clips/layers retain their ids, output lengths, media ranges and settings. Clip moves carry connected anchors and linked layer sound when Link layers and propagation are enabled. Audio lane changes skip Mic/System, preserve volume/mute, and reserve future blocks rather than displacing them. Verified regressions fail before the fix (deletion rolled back; moves left media behind); with `DEVELOPER_DIR=/Library/Developer/CommandLineTools`, `make test FILTER=connected` 8/8 (500 seeded video edits, ripple/gaps/endpoints, mixed clocks, half-open anchors, lane reuse/creation/mute and idempotence), `make test` 110/110, `make app CONFIG=debug`, `--selftest timeline-ops` and `timeline-clipboard` OK. Core model/links roadmap 3/3; composition and UI remain T-643 onward. Existing config conflicts preserved; task commit uses a separate index.

T-643 · 2026-10-16 · Replaced Mic/System insertion with per-track audio clips, cached package audio/video assets, linked/connected timing and linear gain/fade/mute ramps with spectral pitch preservation. Shared Core audio segment/envelope math and absolute media/output boundaries prevent fractional-cut A/V drift; exportDuration includes audio/layer tails. Preview rebuilds for timing/routes and refreshes mixing on the same item; existing Sound controls and composition callers now use audioTracks. Export cleanup still targets mic.m4a only; missing audio is silent and invalid package paths preserve existing destinations. Verified with `DEVELOPER_DIR=/Library/Developer/CommandLineTools`: `make test` 112/112; `make app CONFIG=debug`; new `audio-lanes` OK (legacy segment equality incl. short cuts, 53 fractional-speed cuts, four real tracks from M4A/MOV, detach/move, live item identity, decoded gain/fades/mute/pitch and 7 s tail, missing-media preview/export and traversal rejection); `audio-mix`, `export-range`, `inspector-panels` OK; regenerated M6 fixture and `parity` maxDelta=0 over 8 times. Audio-lane UI remains T-644. Existing config conflicts preserved; task commit uses a separate index.

T-644 · 2026-10-16 · Added nonempty 36 pt audio lanes with package-file waveforms/silence hatching, gain-zero hatching, fade handles, chain/offset badges and partner outlines; 132/16 pt headers with mute, volume and playback meters; AudioPanel, Command–L, audio menus/accessibility and native vertical overflow. Snapshot-based move/trim/track/fade gestures support snapping, Option overrides, Escape and one undo each; Core output-clock edits keep audio tails editable. Clipboard now retains linked screen/camera/layer partners, remaps restored audio tracks and selects the grabbed lane, avoiding linked Cut data loss; tiny linked-layer pieces that cannot be pasted are refused. Verified with `DEVELOPER_DIR=/Library/Developer/CommandLineTools`: `make test` 114/114; `make app CONFIG=debug`; `timeline-ops`, `menu-actions`, `inspector-panels`, `timeline-clipboard` (Mic/System linked, Voiceover/Audio connected), `waveform` (incl. path rejection), `audio-lanes` (incl. 201 MOV audio waveform peaks), `timeline-selection`, `timeline-tracks`, `timeline-full-layers`, `command-scissors`, `workspace-replay` OK. Ran `make gallery`/`make gallery-png`; inspected gallery, audio inspector, shortcut sheet and timeline PNGs for selected/all four audio lanes, compact, empty, minimum-size scrolled bottom and playback meters. Reference image folder absent; followed current UI kit. Record/re-record controls remain disabled for T-645; human interaction feel/release remain unverified. Existing config conflicts preserved via isolated task index.

T-645 · 2026-10-16 · Implemented microphone TCC/device selection, AVCaptureAudioFileOutput AAC takes, sample-accurate first-buffer/host-clock playback, silent countdown/pre-roll, HUD monitoring/meter, live virtual waveform lane and Stop/Discard keyboard/window/quit cleanup. Core placement/re-record edits trim pre/post-roll, mute only the replaced original range, reuse voiceover lanes, retain old media and commit in one undo step; project edits are locked during capture. Preview preparation now seeks the current paused playhead and avoids stale compositions/competing seeks. Verified with `DEVELOPER_DIR=/Library/Developer/CommandLineTools`: `make test FILTER=takePlacement` 3/3; full `make test` 117/117; `make app CONFIG=debug`; synthetic `voiceover` with generated and supplied M4A (placement, mute, replacement, undo/redo, save/load, cancellation/cleanup, corrupt media and path rejection); final native player/host-clock drift 0.000132 s. `timeline-ops`, `menu-actions`, `inspector-panels`, `timeline-clipboard`, `audio-lanes`, `hover-preview` OK; M6 parity maxDelta=0 over 8 times. Gallery/gallery-png passed; reviewed countdown, minimum preview, pre-roll, growing and committed take PNGs. Reference image folder absent; followed current UI kit. Task remains [~]: HUMAN AC-VO-2 and real-microphone latency calibration via LaunchServices are not verified; synthetic input is not hardware evidence. Disposable fixture retained via `voiceover <m4a> --keep-fixture`. No release yet; unrelated config conflicts preserved via isolated task index.

T-646 · 2026-10-16 · Added validated image/movie/audio imports through Add Media, preview/timeline file drops and image/file paste; background-owned media copies, import status, free Audio tracks, linked video sound and one-undo commits. Added padded idle ranges/slots mapped through media time and cached per edit; dynamic layer lanes, asynchronous thumbnail strips, fade handles, connected move/trim/vertical gestures, missing-file hatching, focus/selection/clipboard/accessibility. Layer ops share the linked-block engine and clamp before extending the clock, so out-of-media trims cannot add spurious timeline gaps. Verified with `DEVELOPER_DIR=/Library/Developer/CommandLineTools`: `make test FILTER=idleRanges` 1/1, `FILTER=layerBlocks` 3/3, full `make test` 121/121; `make app CONFIG=debug`; `media-import` (PNG, MOV with/without sound, M4A, byte-identical copies, one undo each, image/file pasteboard, native layer gestures, linked sound, fades, Escape, selection/focus/clipboard, corrupt/short media cleanup and escaped-directory rejection); `timeline-png --layers`, `timeline-ops`, `menu-actions`, `timeline-clipboard`, `inspector-panels`, `audio-lanes`, `hover-preview /tmp/M6Fixture.recorder`, `timeline-selection`, `timeline-tracks`, `timeline-full-layers`, `command-scissors` OK. Updated old fixed-height/nearest-snap/accessibility fixture assumptions for idle lanes without weakening their checks. M6 parity maxDelta=0 over 8 times; gallery/gallery-png passed; inspected selected, minimum, compact and missing-media timeline PNGs plus gallery. Reference boards absent; followed current UI kit. Native external file-drop/picker feel and 30-minute refresh-rate acceptance remain unmeasured; rendering/inspector are T-647…T-649, real mic remains HUMAN T-645, no release yet. Existing config conflicts preserved via isolated task index.

T-647 · 2026-10-16 · Added shared Core connected layer timing/fade/motion math, FrameState layer samples and resolution-aware ImageIO/sRGB texture caching with orientation/PNG alpha and package-path checks. The shared compositor draws stored Card/Full/Corner/Free rects, frame-styled card shadows/corners, dim and screen/cursor-only GPU blur, ascending lanes, camera, above-camera layers, text then keys. Missing media has no render/backdrop. Added an image-only LayersFixture and GPU assertions for rect/color/orientation/alpha, dim/fade, blur/sharp camera, lane/camera order, missing/escaped paths and bounded cache reuse. Native timed screenshots exposed a paused initial-attach seek overwriting a newer playhead; fixed the shared ready callback to seek the current paused playhead. Verified with `DEVELOPER_DIR=/Library/Developer/CommandLineTools`: `make test FILTER=layerRendering` 2/2; full `make test` 123/123; `make app CONFIG=debug`; `make-layers-fixture`; parity maxDelta=0 at 24 layer/fade times, M6 8 times and regenerated WindowsFixture 5 times; `export` produced/decoded all 270 frames (9 s, 1280×720), with a separately decoded 6.75 s frame confirming the above-camera green pixel (0,255,0). Inspected native `editor-png --time` mid-fade/blur/minimum captures, Scale/Slide/alpha-missing preview PNGs and the encoded frame. `export-colors`, `timeline-ops`, `menu-actions`, `inspector-panels`, `media-import`, `audio-lanes`, synthetic `voiceover` and `hover-preview` OK. Video-layer decode and layer controls remain T-648/T-649; real mic and other HUMAN/release gates remain open. Existing config conflicts preserved via isolated task index.

T-648 · 2026-10-16 · Added one 1× composition video track per layer lane, explicit camera/layer mappings and shared file/transform metadata; the main player keeps only screen video plus mixed audio. Isolated muted layer players follow seeks/playback/voiceover, while MP4/GIF/frame-copy paths use per-lane FrameHold readers and the shared FrameState/compositor. Video orientation is applied before sRGB compositing; missing files cannot reuse an old lane frame. Timing/file/lane edits rebuild, styling redraws, and detached previews pause their decoders. Fixed a native-test-exposed stale seek race by gating seeks on item readiness, resetting state on replacement and ignoring old-item completions. Core enforces four video lanes, reuses free existing lanes or refuses imports without committing copied media/undo. Verified with `DEVELOPER_DIR=/Library/Developer/CommandLineTools`: `make test FILTER=layerBlocks` 4/4 and full `make test` 124/124; `make app CONFIG=debug`; expanded `make-layers-fixture` checks in-points/gaps/1×, native playback/hover/backward seeks, rotated markers, camera-less/missing clips, styling-vs-timing item identity, four simultaneous video buffers plus screen/camera, fifth-lane refusal, invalid-path existing-export preservation and detach cleanup. Layer parity maxDelta=0 over 32 times (including either side of video frame changes); M6 8 times and WindowsFixture 5 times remain exact. MP4 export decoded 270/270 frames at 1280×720/9 s; separately decoded output pixels prove green at 0.9 s, blue at 2.25 s, the rotated white marker at 5 s and above-camera red at 6.75 s. GIF export passes size/count/delay/loop checks. `audio-lanes` decodes detached layer sound at its moved position (old 0.0, moved 0.4007 amplitude) with unchanged video; `export-colors`, `timeline-ops`, `menu-actions`, `inspector-panels`, `media-import`, synthetic `voiceover` and layer-fixture `hover-preview` pass. Inspected native normal/minimum rotated-video screenshots and encoded frames. Intel decoder/30-minute interaction performance, layer controls (T-649), HUMAN gates and release remain unverified/open. Existing config conflicts preserved via isolated task index.

T-649 · 2026-10-16 · Integrated the shared LayerPanel into selection routing and the component gallery: oriented thumbnails/owned replacement, Card/Full/Corner grid/Free rectangles, backdrop/motion/fades, camera order and targeted detach/link-back commands. Preview reuses SelectionRectView on the output canvas with aspect locking, move snapping/Command bypass, held-arrow nudges, one undo, Escape/reselection/resize cancellation and paused Edit region versus composed playback. Connected effect previews preserve output lengths across speed edits. Layer duplicate copies linked sound and mix settings; replace retains immutable files/detached sound and enforces the shared four-video-lane budget without committing failed imports. Verified with DEVELOPER_DIR=/Library/Developer/CommandLineTools: make test FILTER=layerEdits 5/5, full make test 129/129, make app CONFIG=debug; inspector-panels and new layer-rect pass, including actual native gestures, selected-video playback, context actions, replacement rollback/file retention, stale-thumbnail cancellation, inspector minimum/bottom scroll and missing media. media-import, timeline-ops, menu-actions, audio-lanes, synthetic voiceover, export-colors, hover-preview and regenerated make-layers-fixture pass. Layer parity maxDelta=0 over 32 times; M6 parity exact over 8. make gallery/gallery-png and advanced gallery demo/check pass (both appearances/minimum); inspected selected/minimum/video/missing editor PNGs and default/minimum/bottom/corner/missing panel PNGs. Reference boards absent; current UI kit followed. T-649 remains [~] for HUMAN Card + Dim/playing-video comparison and live interaction feel; real microphone, Intel/30-minute gates and release remain open. Existing agentpack.toml/pack.lock conflicts preserved via isolated task index.

T-650 · 2026-10-16 · Updated SPEC §5 with voice/media package directories, immutable committed media, additive version-3 audioTracks/audioClips/layers examples, legacy/empty-audio semantics and connected output-time rules; §8.1 documents snapshot media metadata. StateSnapshot reuses the Project types' encoders for full track/clip/layer entries, adds package-contained missingFile checks and export duration, and identifies audio/image/video selection panels. Extended the existing snapshot selftest with real synthetic voice/video/image files, missing files and an escaping symlink; asserts encoder parity for every media field, track mix/link/in-point/style metadata, a 24-second audio tail over 20 seconds of screen, empty arrays, selection panels, no raw key characters or external file content/media copies, private clipboard and 20-folder retention. Verified with DEVELOPER_DIR=/Library/Developer/CommandLineTools: make app CONFIG=debug + --selftest snapshot; full make test 129/129; default make app release (168.33 s) + --selftest snapshot; codesign --verify --deep --strict. Roadmap Docs is 1/1; T-645/T-649 remain [~] awaiting HUMAN and older HUMAN/performance/release gates remain open. No public version/release issued. Existing agentpack.toml/pack.lock conflicts preserved via isolated task index.

T-114 · 2026-10-16 · Audited the first remaining gate against SPEC AC-REC-1 and the existing record-perf diagnostic; no capture or implementation changes. Release build 241's read-only permissions selftest through LaunchServices completed with screen=false accessibility=false (process terminal). system_profiler reports Apple M1, 1920×1080 pixels/UI at 60 Hz, not the required 1440×900@2x/2880×1800 workload. CaptureTarget requests 1/60 s and 420v for display capture; CaptureSession requests HEVC. Neither proves hardware encoder selection, <1% frame loss or ten-minute CPU. record-perf asserts only CPU/codec, labels its low-static-content frame count and removes its temporary package, so its success cannot tick this HUMAN gate. ffprobe is absent; QuickTime Inspector remains the plan alternative. Marked [~], left M1 Done at 7/14 and requested manual measurements on matching hardware. Did not prompt/reset TCC, alter the display, record the desktop or change encoding settings without failure evidence. No release issued; existing config conflicts preserved.

T-208 · 2026-10-16 · Audited the next gate against SPEC §4 and current capture surfaces without changing app code. Existing release build 241 passes menus, synthetic pickers, injected permission-refresh and private-suite hotkeys. capture-panel-png, denied onboarding-png and settings-png pass; inspected their actual PNGs at /tmp/recorder-t208-{toolbar,onboarding,settings}.png (toolbar 560×181). Strict bundle signature verification passes. A fresh LaunchServices permissions selftest reports screen=false accessibility=false. Did not run live picker/capture tests that enumerate SCShareableContent and could prompt; did not request/reset TCC, open a camera/mic session, change display settings or start a recording. These specimens and synthetic checks do not establish HUMAN visual approval, exclusion/clap sync, countdown/widget recording behavior, other-app hotkeys, window resizing or relaunch persistence. FUI reference boards are absent; existing UI-KIT direction is not a human approval. Marked T-208 [~], left M2 at 0/9, and requested the SPEC §4 walkthrough/deviations. Release remains gated; unrelated config conflicts preserved.

T-313 · 2026-10-16 · User accepts visual deviations and requests proceeding to release; recorded this policy without claiming hardware checks passed. Fixed destructive backdrop replacement with validated immutable package copies and a native failure alert. Added real-editor slider/backdrop/quit/reopen pixel persistence, replacement undo/redo/corrupt-image rollback and owned-child SIGKILL before/after autosave checks. With DEVELOPER_DIR=/Library/Developer/CommandLineTools: make test 129/129, make app CONFIG=debug; background-persistence, model, inspector, inspector-panels, menu-actions, timeline-ops pass; LayersFixture parity maxDelta=0 over 32 times; strict codesign and task diff checks pass. T-313 remains [~] solely for unverified live capture handoff; no synthetic claim of hardware acceptance. Existing config conflicts preserved.

T-418 · 2026-10-16 · Reviewed SPEC §7.2/7.3; make test 129/129 and native timeline-ops, timeline-clipboard, timeline-selection, timeline-tracks, timeline-full-layers, command-scissors, clip-fades, zoom-target, highlight-manipulation and menu-actions pass. LaunchServices workspace-replay passes real playback, frame/trim/zoom/camera/mask/keys edits, save/reload, a playable 31-second export and clipboard handoff. Visual deviations accepted by user; no new interaction changes. Kept [~] for the unperformed full physical-key/VoiceOver walkthrough and AC-TL-3 30-minute/200-zoom display-refresh measurement. These limits will be disclosed in release notes rather than represented as verified. Existing config conflicts preserved.

T-509 · 2026-10-16 · Installer regression fixtures pass native certificate rejection, successful replacement, signature/quit/replace/restore failures, current/legacy permission-reset handling and certificate generation without Keychain mutation. Added assembled-release background-persistence smoke; updated signing guidance without claiming permission migration fixed. Clean clone passes all 129 Core tests. Initial v0.3.0 CI/release stopped before publication on an older compiler's ambiguous CGFloat/Double blur expression; explicitly converting output size to Double fixes the shared compositor without changing its math. Rechecked 129/129, debug app and LayersFixture parity maxDelta=0 over 32 times locally. Retain the failed tag as history; publish the corrected candidate as v0.3.1 only after signed/notarized pipeline checks. Clean release build and DMG verification are in progress; full v1.0/HUMAN acceptance is not claimed. Existing config conflicts preserved.

T-509 · 2026-10-16 · Published v0.3.1 from 650a31d: CI run 38948201893 and Release run 38948201717 both succeed. Clean detached-tag release build passes strict codesign, version 0.3.1, background-persistence, export-colors and export-sheet. Independently downloaded the public 8,881,873-byte universal DMG; hdiutil checksum, app/DMG stapled tickets and Gatekeeper Notarized Developer ID assessments pass. Verified x86_64 + arm64 and version; the readonly-mounted signed app passes real-editor backdrop persistence/undo and owned-child SIGKILL recovery. SHA-256 493784fdc1fe859a0a530a85433c766168d9ed28b8e514476f770e92db885900 matches GitHub asset digest. Published release notes explicitly disclose real-device permission migration, mic latency, Intel hardware, VoiceOver and extended-duration performance limits; no full v1.0 acceptance claim. Did not replace the user's installed app, quit their Recorder copies or reset TCC. Existing config conflicts preserved.

T-649 · 2026-10-16 · Applied the user's explicit acceptance of visual deviations to the remaining prototype-comparison gate, without claiming a human performed it. Re-ran make test FILTER=layerEdits (5/5), inspector-panels, layer-rect and LayersFixture parity (32 times, maxDelta=0) against the v0.3.1 release source; inspected fresh native selected Card + Dim and video-result screenshots. Native rectangle gestures/Escape/one-undo, playback, menus and immutable replacement pass. Marked T-649 complete in both trackers; Media layers + import 4/4. No app-source change or new release needed; real-mic/permission/performance gates remain unverified. Existing config conflicts preserved.

T-104 · 2026-10-16 · Audited toolbar/settings/menu/capture callers against AC-TB-2/3/4 and found saved device IDs survived unplugging while setup was closed: microphone remained selected and a missing camera could reach the permission/open path. Setup now filters both saved IDs through the menus' existing live discovery lists before creating the toolbar, preserving available devices and persisting Off for absent ones. Added shared restore-decision selftest for Off, connected, reordered, missing and empty lists without hardware access or real preference changes; included it in assembled-release smoke checks. With DEVELOPER_DIR=/Library/Developer/CommandLineTools: debug app, device-selection, menus, hotkeys, synthetic pickers, permission-refresh and make test 129/129 pass; strict codesign, shell syntax and diff checks pass. Visual deviations accepted; keep [~] for physical hot-plug and true saved-selection relaunch. This hotfix is newer than v0.3.1 and requires a follow-up release; existing config conflicts preserved.

T-509 · 2026-10-16 · Published follow-up v0.3.2 from 9a9eec3 with T-104's missing-device restore fix and T-649's accepted visual gate. CI 38950445140 and Release 38950510497 succeed; installer regressions and clean detached-tag release build, strict codesign, device-selection, background-persistence, export-colors and export-sheet pass. Independently downloaded the public 8,883,671-byte DMG; checksum, both app/DMG stapled tickets and Gatekeeper Notarized Developer ID assessments pass. Verified x86_64 + arm64, bundle version 0.3.2 and shipped device-selection smoke. SHA-256 360c9a68e09a65380592df2861c69759099acfdbfa9b509ee66f078b50669af1 matches GitHub. Important new evidence: passive permissions selftest through LaunchServices on this signed bundle reports screen=true accessibility=true, unlike the historical ad-hoc build. No permission request/reset, actual capture or installed-app replacement performed. These grants permit further live checks but do not prove permission migration on other Macs, physical hot-plug, real-mic calibration or extended-duration performance. Public release notes retain those limits; full v1.0/HUMAN acceptance remains open. Existing config conflicts preserved.

T-111 · 2026-10-16 · Revalidated v0.3.2's signed-bundle permissions through LaunchServices (screen=true/accessibility=true), then ran its existing record-windows 3 10 case against three Recorder-owned animated windows only. Live ScreenCaptureKit capture passes: decoded centre colors, sizes 480×300/360×420/560×320, per-file 10 s durations within 0.75 s, shared clock/window metadata; average process CPU 0.9% of one core. Existing test temporarily disables mic/system audio and restores those selections; temporary package removed and readonly DMG detached. No full-desktop, microphone, camera or system-audio content captured; no grant requested/reset or user Recorder process stopped. This is direct CaptureSession component evidence, not proof of RecordingController/UI finish-to-editor, all three capture modes, cursor exclusion or the required ten-minute retina performance workload. Keep T-111 [~] for its remaining HUMAN scope. No app-source change/new release; existing config conflicts preserved.

T-508 · 2026-10-16 · Inspected both performance helpers before using their evidence: export-perf has no audio, and idle-perf hosts no toolbar and labels itself a headless lower bound. Corrected the tracker instruction that incorrectly suggested export-perf 600 could close A/V drift. Ran signed v0.3.2's export-perf 60 on Apple M1: synthesizes moving 1920×1080@60 content in 19.3 s (excluded), exports 3,600 frames in 19.58 s / 183.8 fps, AC-EXP-1 PASS under 30 s; video duration 60.0000 s, drift 0.0000 s, last PTS 59.9833 s. Explicit shell checks also require all frames and the duration PASS line. Temporary media cleaned and readonly DMG detached. Keep [~] for the actual ten-minute audio/cursor comparison and real-toolbar idle CPU/RAM measurement; no headless/synthetic substitute claimed. No app-source change/new release; existing config conflicts preserved.

T-414 · 2026-10-16 · Audited InspectorView selection routing and ZoomPanel/ClipPanel/CursorTab bindings plus TimelineView's cancel-before-deselect Escape chain against SPEC §6.6/AC-INS-3. Current v0.3.2 release-source build passes inspector-panels, menu-actions and timeline-ops; generated and inspected fresh /tmp/recorder-t414-{zoom,clip,cursor}.png. Existing tests cover model edit/gesture undo and persisted fields, not a timed rendered panel switch. User's visual waiver closes mockup approval, but the literal one-frame latency requirement remains unverified; corrected the previous “taste only” claim and retained [~] rather than calling a settled PNG timing evidence. No app-source change/new release; existing config conflicts preserved.

T-416 · 2026-10-16 · Found a functional timing defect while auditing the waveform taste gate: flooring 44,100/200 to 220 frames per bucket made the nominal 200 Hz table run fast, shifting waveforms/silence decisions on longer audio. Added a native regression requiring exactly 200 buckets for the existing one-second 44.1 kHz fixture; observed failure at 201 before editing the extractor. Replaced fixed rounded bucket lengths with cumulative frame/rate boundary comparisons in the shared extractor, preserving channels, final partial buckets, caching and errors. Regression now passes at 200; audio-lanes (including MOV audio), synthetic voiceover, timeline-ops, timeline-png and make test 129/129 pass with CLT; strict codesign and diff checks pass. Inspected /tmp/recorder-t416-timeline.png with mic/system/voice/imported audio, silence and muted hatching. User's accepted visual deviations close taste review; task [x], M4 7/18. SPEC clarifies exact bucket rate and the newer audio-lane placement. This source fix is newer than v0.3.2 and needs the follow-up release; no physical-mic or performance gate implied. Existing config conflicts preserved.

T-509 · 2026-10-16 · Preparing v0.3.3 for T-416's waveform-rate fix; added the exact native waveform regression to assembled universal release checks, so publication fails if one second of 44.1 kHz audio does not produce 200 buckets. Shell syntax and local native waveform regression pass. Existing full 129-test/native audio/voiceover evidence is recorded under T-416; clean tagged release build and signed/notarized publication/download checks follow. No change to signing or manual-acceptance policy; existing config conflicts preserved.

T-509 · 2026-10-16 · Published v0.3.3 from 2fb0859 with T-416's waveform timing fix. CI 38954235540 and Release 38954235289 succeed; assembled universal app passes the new waveform gate before notarization/publication. Clean detached-tag release build/version/strict codesign, waveform, audio-lanes, synthetic voiceover, background-persistence, export-colors and export-sheet pass. Independently downloaded the public 8,884,323-byte DMG; checksum, both app/DMG stapled tickets and Gatekeeper Notarized Developer ID assessments pass, as do architecture checks (x86_64 + arm64), version 0.3.3 and the shipped native waveform case (exactly 200 buckets). SHA-256 45c029e64a667a12cac395907763800425376ba3bfa99df080c952159c5a8870 automatically matches GitHub's asset digest. Passive signed-bundle preflight through LaunchServices still reports screen=true/accessibility=true; no TCC reset/request, mic/camera capture or installed-app replacement. Public notes retain physical-device, latency and long-duration verification limits; full v1.0/HUMAN acceptance remains open. Existing config conflicts preserved.

T-651…T-653 · 2026-10-16 · Voice editing request: 130/130 tests incl. pausesSliceAndEraseMicOnly; debug app timeline-ops, menu-actions, inspector-panels, command-scissors, waveform OK. Makefile `test` pins DEVELOPER_DIR to CLT (xcode-select now points at Xcode, whose Testing macros mismatch CLT's framework). Live Speech/eraser/visual checks are HUMAN. Not committed: agentpack.toml/pack.lock merge conflict pending.

fix · 2026-10-16 · Crash after opening a mic recording: split-at-pauses slices abut at float-noisy boundaries that round to a 1-tick overlap at timescale 600, and AVFoundation throws on overlapping volume ramps (`makeAudioMix` now clamps each ramp to the previous end per track). Transcriber kept only the final result, which on long audio repeats just the last utterance; now merges every utterance (Soft Harbor 434 s: 16 → 684 words). New `--selftest audio-mix-abutting` crashes before the fix and passes after; clip-fades and captions OK.

T-654…T-656 · 2026-10-16 · Voice workflow merged from lanes voice-e/t/c: eraser Tail+Fade preset, no pre-cuts, transcription status; lanes on demand + "+" menu + Move to New Track; colour tags + multi-select audio inspector. Merge conflicts (tests, context menu) resolved keeping both; multi-selection menu offers Move to New Track for audio-only selections. `make test` 133/133; debug app timeline-ops, command-scissors, menu-actions, audio-lanes, inspector-panels, timeline-clipboard/selection/tracks/full-layers, media-import, audio-mix-abutting, timeline-png --colors OK (PNG inspected). HUMAN: eraser tail by ear, "+" menu/reveal feel, swatches on a real display, multi-audio slider drag.

T-657 · 2026-10-16 · Box selection of audio clips, group audio move, Join Clips (⌘J) for video and audio. `make test` 134/134; debug app inspector-panels (box→move→join→undo), timeline-ops, command-scissors, menu-actions, audio-lanes, timeline-clipboard/selection/tracks/full-layers, media-import OK. HUMAN: box-drag and ⌘J feel in the live editor.
T-658 · 2026-10-18 · Transcriber on SpeechAnalyzer/SpeechTranscriber (macOS 26+), SFSpeechRecognizer fallback. `captions` selftest on Soft Harbor (434 s): ~7.6 s, words to 431.8 s, ordered timings; caption preview-frame shows the current-word box.

T-659 · 2026-10-19 · Added Hide cursor below Playback speed in the selected Clip inspector, optional per-clip JSON flag, shared menu/model undo edit and shared preview/export frame gating. Splits/paste retain the flag; join/restoration preserves differing visibility; global and legacy range hides remain supported. CLT make test passes 135/135; debug make app version 0.4.1, clip-cursor, clip-fades, inspector-panels, menu-actions, timeline-ops, timeline-clipboard and timeline-selection pass. Inspected 300/360-point panel renders and the full 320-point inspector. Synthetic fixture with an explicit cursor sprite verifies hiding changes the selected clip's pixels while its neighbor stays byte-identical; preview/export parity is exact at five visible/hidden times. Installer regressions, strict codesign, shell syntax and diff checks pass. Reference boards are absent; existing UI kit and user's panel followed. Signed/notarized patch publication and public-download verification pending; T-659 remains unchecked until those pass.

T-659 · 2026-10-19 · Published v0.4.1 from 88bf5af; CI 39308484407 and Release 39308486851 succeed, both with 135/135 Core tests. Assembled universal release passes clip-cursor before publication alongside existing permission/device/waveform/background/export smoke checks. Independently downloaded the public 8,886,782-byte DMG: SHA-256 303467938116baff9c898d577f847f91aece6bf02011b056166e1f992e238472 matches GitHub's asset digest; checksum, app/DMG stapled tickets, Gatekeeper Notarized Developer ID assessments, strict app signature, x86_64 + arm64 and bundle version 0.4.1 pass. Mounted read-only app passes clip-cursor, menu-actions and five-time visible/hidden preview/export parity with maxDelta=0; detached afterward. make gallery/gallery-png pass and the rendered gallery was inspected. Task marked complete (1/1); public notes describe the toggle and preserve hardware/permission/latency/VoiceOver/performance limits and older-version compatibility caveat. No installed app replacement or TCC changes.

Documentation review · 2026-10-23 · Shortened the entry README, retained installation/repair details in INSTALLATION.md, reconciled the permission summary with the signed-v0.3.3 evidence above and corrected stale skeleton/install wording in agent guides. Checked relative links and shell syntax on Linux; no native build, capture, export or permission pass is claimed. Native rendering recapture was excluded by the user for unsupported hardware. No functional acceptance boxes changed.

T-701 · 2026-11-15 · Added Clip.mediaEnd; restore and cut bubbles use footage bounds, refusing reversed neighbours. Rebased restoration reuses clipboard insertion to preserve later footage/effects; head/tail, playback rates and tiny moved edge gaps covered. Targeted make test FILTER=TimelineOps passes 18/18; full make test passes 137/137 using installed Xcode native engine/platform Testing flags (default swiftbuild/CLT macro failures recorded above). Native timeline-ops remains failing at the pre-existing Video Track menu fixture mismatch; no UI acceptance claimed. Artifact audits add T-701b for media-order/copy bugs and explicit ⌘D implementation to T-703. Unrelated worktree edits preserved.

T-701b · 2026-11-15 · Completed artifact A8 media-order fixes: recorded typing/silence ranges map into every kept clip; regeneration maps independently owned zooms through copies/rates while retaining effects across harmless splits; pause slicing visits every media occurrence and erasing preserves untouched copies and connected tails; multi-window cursor normalization, camera following and frame sampling use each copy’s window selection with edit/undo cache invalidation. Core make test 143/143 passes with Xcode native/platform Testing overrides; native menu-actions and cursor-copies pass; fresh M6 fixture parity maxDelta=0 across eight times. Full-duration per-clip multi-window cursor simulation is the documented profiling limit. No physical-device/performance gate claimed; unrelated worktree changes preserved.

T-702 · 2026-11-15 · Added group reorderClips with original-array carets, stable group order, no-op/invalid guards, simultaneous linked-content slicing/shifts, whole connected anchors and layer-owned audio deltas, existing link semantics, collision settlement and invariant rollback. Made explicit output-clock normalization idempotent. Seven targeted reorder tests pass; full make test 150/150 with Xcode native/platform Testing flags, including 1000 seeded requested-permutation checks and rollback on invalid audio slivers. Documented canonical-vs-legacy roundtrip representation and existing trailing-gap export trimming; added T-702b for reviewer-found repeated spanning-audio fades before UI integration. No native drag behavior, physical performance or release acceptance claimed. Unrelated worktree changes preserved.

T-702b · 2026-11-15 · Added optional validated media-time audio-envelope points, captured before slicing/clock changes and evaluated through the shared volume-ramp path; explicit fades reset points, gain/mute retain them, compatible joins preserve them. Preview audio-only refresh and timeline ramp outlines include stored envelopes. Eleven targeted reorder/envelope tests pass; final full make test 154/154 and native audio-mix-abutting, clip-fades, menu-actions pass. Regressions compare gains at matching media samples through uniform/mixed/fractional rates, reordered/roundtripped cuts inside fades, copy/trim/rate edits, mixed-clock audio move, split/join and JSON; malformed/nonfinite metadata rejected, floating segment boundaries coalesced. Xcode native/platform Testing flags as T-701. Version-3 additive metadata documented; old builds ignore phase preservation on rewrite. No hardware/listening/performance acceptance or release claimed; unrelated edits preserved.

T-703 · 2026-11-15 · Integrated trial-only magnetic reordering and Free placement with pointer-following ghosts, 45% landing slots, identity-aware 0.18s neighbor motion, continuous40pt edge scroll, release-time Option copying and one-edit commit; no-op/Escape leave no undo. Option-click still blades after release; sticky blade stays immediate. Added Video ⌘D per selected clip and retained layer collision-aware duplication. New trial tracks/headers/layer mapping render correctly; layout height growth preserves drag and stale source-selection outlines are suppressed. All154 Core tests and all9 current timeline-* selftests pass (new reorder also passes from assembled app); gallery and drag/collision/timeline renders inspected. User confirmed horizontal feel is right in local review fixture. Recorded debug long-timeline timing above without presentation/hardware claim. Existing Video Track/header-selection baseline is retained in this commit; unrelated config changes remain untouched. No vertical lift/recording-layer/performance acceptance or release claimed.

T-704 · 2026-11-15 · Verified existing header/Command-A Video group selection with real synthetic header clicks, gaps and grabbing the second selected clip in both Magnet/Free; order, retained spacing, complete selection and one exact undo are asserted. Added stale-trial protection: editing shortcuts cancel clip drag, and drop never overwrites an intervening external/menu edit or restores stale selection. Extended timeline-selection also checks keyboard/drop/Escape interruptions and block-lane Command-A isolation. Full make test154/154 and native timeline-selection/reorder/ops pass; make -o build app CONFIG=debug reuses verified native build and assembled app selection case passes. Xcode native/platform Testing overrides as T-701. No hardware/performance/release acceptance claimed; unrelated config edits preserved.

T-705 · 2026-11-15 · Implemented permanent26pt New track strip, descending Video N layers above Video, native accessible Magnet/Free header using existing rippleDelete and synchronized toolbar/undo. External file drops use next track; existing layers show a private row placeholder without lane/project allocation until one-step drop, with Escape/cancel and keyboard interruption safe. New row-aware clip ghost geometry and restore-bubble event priority retained; fixture coordinates use laneMidY. Full make test154/154, six native timeline cases (tracks/full-layers/png/selection/reorder/ops) and assembled tracks pass; native checks include actual PNG import, hover stability, gap preservation and mode undo. Gallery/header/timeline and settled1100×700 editor renders inspected. Default1300×850 settled capture fails titlebar alignment consistently; T-705b added to diagnose/fix before claiming full UI validation. HUMAN header/drop-row question is pending on opened review fixture; task remains[~], no visual acceptance invented. Native Xcode/platform Testing flags as T-701; gallery reused verified native binary; unrelated config changes preserved.

T-705 follow-up · 2026-11-15 · User reported image should fill canvas; changed shared new-image import default to Full while preserving videos and existing placements. File/clipboard/new-track imports verified; full154 Core pass, media-import/tracks pass, corrected settled review image inspected, parity maxDelta0 over11 times. Review copy retains user track/timing edits. User explicitly waived further HUMAN reviews; T705 completed using automated checks and agent visual judgment. Titlebar failure remains T705b; independent extra layers-render check exposed orientation assertion, recorded as T705c.

T-705b · 2026-11-15 · Fixed native window-control alignment after screen-constrained resize by invalidating the document bar layout after every root positioning. Geometry proved native850→834pt clamp moved bar but reset controls16pt from top; fix restores24pt. Native debug build, scratch assembled settled1100×700/1300×850 captures, menu-actions and timeline-tracks pass; both PNGs inspected. No test assertions weakened; no Core logic changed.

T-705c · 2026-11-15 · Corrected reversed red/green bands in orientation fixture under its top-left CTM; production image rendering unchanged, pixel assertion retained. Native build, make-layers-fixture (compositor+livevideo), media-import pass; layers parity maxDelta0 over32 times. Added and inspected rendered orientation proof; Phase1 now9/9.

T-711 · 2026-11-15 · Added opt-in native dual4K60 benchmark with actual presented timestamps and sampled main/layer PTS, standard framebuffer-only playback, full2160p60HEVC export validation/reporting and native event-loop dispatch. Native build and ordinary menu-actions/tracks pass. Two3600-frame moving fixtures generated; actual playback attempts correctly refused occluded windows. Final LaunchServices preflight plus read-onlyCGSession confirmed lockedconsole; no wake/unlock attempted. Task remains[~]: noASpreviewFPS/dualexporttime orIntelresult claimed. User requested no further prompts, so continuing software tasks while hardware/visible-session evidence remains outstanding.

T-712 · 2026-11-15 · Added recording layers/mediaRate/scene and original camera context, lift/insert using shared clock/slicing/paste/collision operations, conditional v4 saves with v3 defaults and future-header refusal. Preserved fades/color/hidecursor, carried screen audio envelopes/settings, independent global-lane output positions and safe owned padding. Copies clear ownership and refresh scene IDs; unchanged spanning effects can rejoin while later neighbor edits survive. Trim context remains immutable and insertion clips scene tails. Native targetedlift4/4/full160/160 pass; app compiles and diffcheck clean. Audio collision routing can choose another lane; recording render/gestures still pending713/714. Unrelated config modifications remain untouched.

T-713 paused handoff · 2026-11-15 · User paused goal and requested a repository handoff usable by another agent. Saved unfinished renderer/native tests and temporary PTS diagnostics as explicit WIP; T713 stays unchecked. Last full Core162/162 and lift-identity49 exact samples pass; actual Preview/export parity fails first mixed2xsample at4.0167,maxDelta127. Diagnostic build interrupted, so rebuild first. Durable logs and PNG pairs copied into docs/handoff; docs/RESUME.md records code map, commands, user review waiver, pending hardware measurements and next tasks. No agent compiler/test remained active at handoff; unrelated CLAUDE.md/Makefile/pack.lock edits preserved.

T-713 · 2026-11-15 · Recording layers render through the screen pass; preview/export parity and lift identity at maxDelta 0. Root cause of the parity failure was FrameHold missing a frame whose ns-rounded PTS exceeded the double request time by ~3e-10; added 1e-6 slack. Temporary PTS prints removed.

T-714 · 2026-11-15 · Clip drag lifts over layer lanes / New track row (placeholder, committed on release; ⌥ copies, Esc cancels); recording layers drag back onto Video via insertLayers as a trial (reverted on invariant failure); ⌥↑/⌥↓ move selection one lane; carried zooms draw dimmed. One model.edit per gesture. New --selftest timeline-lift passes with timeline-reorder/-selection/-tracks/-ops, menu-actions. HUMAN feel waived by user.

T-721 · 2026-11-15 · add/move/resize/removeSceneZoom reuse generic block ops on layer.scene.zooms (stored as output offsets from layer.start; length capped by sceneZoomLength from the recordingScene context clip). Zoom lane edits them while a recording layer or its carried zoom is selected. sceneEffects tests incl. sceneZoomRendersWhereAdded pass.

T-722 · 2026-11-15 · Clip.file lets imported image/video layers enter Video via insertLayers (no cursor/zoom; liftClips refuses them); save writes v4 when any clip has a file. Composition inserts per-clip assets, images as a cached one-frame movie keyed by path hash+mtime+size. clipFile 3/3, media-import extended. Main text/masks still apply over file clips by source time (user-placed; not filtered).

T-723 · 2026-11-15 · SPEC §5 v4 keys + version rule, §7.1 anatomy, §7.2 free-editing gestures, §7.3 keys (⌥↑/⌥↓, ⌘D clips, ⌘L ignore-links), §7.4 invariant note; cheat sheet updated (⌥ drop copies, ⌥⌫ ignores links).

Free-editing merge · 2026-11-15 · Combined T-713/714/721/722/723 verified on dev: native build, make test 167/167, selftests lift-identity + layer-recording-parity (maxDelta 0), timeline-lift/-reorder/-selection/-tracks/-ops/-full-layers, media-import, make-layers-fixture, menu-actions all OK. Review fixes: carried-zoom mapping, lift trial revert, image cache key.

T-711 · 2026-11-15 · Apple Silicon measured: preview 59.85 fps presented, 58.95/57.27 distinct PTS/s (main/layer), dual-decode 4K60 export 69.3 s for 60 s; selftest OK after floating the benchmark window and counting only non-empty sample buffers. Intel BLOCKED (no hardware); task stays [~].

T-711 close · 2026-11-15 · User chose to drop the Intel measurement; T-711 closed on the Apple Silicon result.

T-731 T-732 · 2026-11-15 · Pencil tool (P), cross-lane box select, ⌘J grouping with ⇧⌘J ungroup. make test 168/168 (with Xcode's DEVELOPER_DIR; CLT toolchain can't load SwiftUI macros here); selftests timeline-ops (new pointer/pencil/group/box checks), timeline-selection/-lift/-clipboard/-tracks/-full-layers, menus, menu-actions, audio-lanes, command-scissors OK. Fixed two selection writes inside `model.update` closures (exclusive-access crash once `selectedClips` reads `project`).

T-733 · 2026-11-16 · Joined clips get the clip inspector: group speed multiplies members (ratios kept, linked/ripple path), cursor/fades/remove on the group. make test 169/169 (Xcode DEVELOPER_DIR); selftests clip-fades (new group checks), clip-cursor, timeline-ops, timeline-selection, inspector, inspector-panels, menu-actions OK (debug build).

T-734 · 2026-11-16 · Video-lane insert preview for Video 2+ drags (trial clip lane + index-aligned ripple from zero-length stand-ins). Selftests timeline-lift (new preview check), timeline-reorder/-ops/-tracks/-full-layers OK (debug build). HUMAN: judge the animation in the app.

T-801 · 2026-11-16 · Added pure Codable output-time timeline/transcript views, stable transcript hash and full-array word IDs, filler detection and caption-based phrase formatting. Covers retained effect segments, window shots, connected audio/layer tails, range filters, imported/gap exclusion and copied footage with independent media clocks. Existing TimeMap media semantics retained rather than treating editing-clock positions as microphone media times. Tests live in the existing SwiftPM Tests/RecorderCoreTests directory. make test FILTER=AgentViews passes 5/5; full make test passes 174/174 using the documented Xcode native/platform Testing flags. No AppKit/AVFoundation imports in the new Core file; no project mutation or UI changes. Remaining MCP tasks T-802…T-810 are unimplemented.

T-802 · 2026-11-16 · Added flat-JSON EditOp/JSONValue, atomic Project.applying with base-output range resolution, indexed validation/errors and change summaries/deltas. Reuses split/delete/setSpeed/block/caption/Preset paths; unions overlapping cuts, preserves source-time effects and ripple settings, follows linked audio, maps pause/word/caption media through copies/rates and excludes imports from transcript-driven cuts. Plain cuts support imported clips; public removeSourceRanges remains recording-only. Shared removeBlock now accepts persisted string IDs while its existing UUID callers retain the same implementation. Exact cuts that cannot satisfy existing minimum clip/split constraints fail atomically rather than silently truncating. Marker ops intentionally reject until T-803. make test FILTER=EditOps passes 10/10; full make test passes 184/184 with documented Xcode native/platform Testing flags; diff check passes. No native MCP runtime/UI acceptance claimed; T-803…T-810 remain pending.

T-803 · 2026-11-16 · Added additive source-time Marker persistence/defaults and output-time agent views (removed footage/gaps omitted), marker add/update/remove ops, lowerThird/chapter style values and conditional version-5 saves while retaining the version-3/4 rule otherwise. Added caption-only SRT with cut/rate mapping, cue merging and millisecond timestamps. Updated future-header/version assertions; existing recording-layer version-4 saves still pass. Exhaustive compositor switches temporarily route the two new styles through title rendering (documented shortcut); dedicated plates/fades and inspector choices remain T-808. make test FILTER=ProjectTests passes 14/14, FILTER=EditOps passes 11/11, full make test passes 188/188 with documented Xcode native/platform Testing flags; diff check passes. No MCP runtime/UI acceptance claimed; T-804…T-810 remain pending.

T-804 · 2026-11-16 · Added owner-only Unix socket listener with same-uid peer checks, bounded newline framing, JSON-RPC sessions/progress, stdio shim/autolaunch, per-project access, 200-row privacy-safe activity, SHA-256 revisions and project/timeline/transcript/analyze read handlers. Nine schemas are advertised; later-task write/render/export/UI handlers remain unavailable. ProjectStore now supplies scan completion plus project ids/mic flags; closed controllers are removed from allOpen so closed-session reads fail and project.open can recover. Native build + assembled debug app mcp-roundtrip on disposable M6 copies pass: framing/parse errors/notifications, library/open/close/reopen, revisions, 2000-word pagination, real waveform pauses, fillers/clicks, invalid arguments, off/read access and key-character privacy. Initial fixture close check used an aliased /tmp URL; corrected it to use project identity. Real app stdio initialize smoke returns one valid result, normal NSRunningApplication termination removes the default socket, existing library selftest passes, full make test 188/188 and diff check pass. Used documented Xcode native/platform Testing flags and make -o build app CONFIG=debug assembly workaround. No TCC reset, real microphone/Speech run, real-client connection or review/export acceptance claimed; T-805…T-810 remain pending.

T-805 · 2026-11-16 · Generalised Copy Frame to sorted sequential multi-time decoding while preserving request order/native PNG parity; added key-safe frozen render models, PNGs, labelled four-column JPEG sheets, UUID cache files and seven-day purge. Added an optional output range to the existing Exporter using native writer-session offsets, retaining original frame/mix clocks: the guide's source-removal proposal skips imports, refuses short boundary slices and cannot trim connected tails reliably. Updated MCP.md with this implementation and its decode-from-zero profiling limit. Socket requests can run concurrently so same-session cancel works during a proxy; progress tokens are request-local, jobs cancel/clean up and later renders reuse the session. Results include inline images only for frames/sheets, links for every file, original project revision and actual proxy duration/bytes. Native build/assembled app mcp-render passes (PNG order/parity, key overrides/events, sheet, two-second 540p proxies with audio including imports/tails, busy/cancel/progress, wire responses and cache expiry); mcp-roundtrip and menu-actions pass; fixture parity maxDelta=0 over 8 times; full make test 188/188 and diff check pass. Inspected /tmp/recorder-t805-sheet.jpg. Documented Xcode native/platform Testing flags and assembly workaround retained. No real-client draft/review/final-export acceptance claimed; T-806…T-810 remain pending.

T-806 · 2026-11-16 · Added twelve-op schemas/validation, draft/live apply and guarded live undo, dry runs, submit/status/discard, per-call frozen contexts and draft-aware reads/renders. Recheck editor/draft revisions, identity/call count, transcript, access and gesture/review/voiceover guards after awaited analysis; stale human bases cannot be overwritten. Core UUID creation now uses a scoped deterministic sequence only for seeded draft replay, preserving cross-call ids and retained-op ids through exclusions while ordinary editor ids remain random. Added motion-text overlap groups and validated inspector style changes so lower-third/caption warnings are reachable without weakening Caption/Title/Label non-overlap invariants. Updated MCP.md and SPEC for these required details. Native assembled-app mcp-edit passes three-call replay, cached revision/id/exclusion checks, dry-run/editor/disk isolation, draft/live frames, stale bases, submit/discard, pause/transcript errors, real overlap warnings, single-step live undo and review/gesture guards. Targeted EditOps 13/13 and full make test 190/190 pass; mcp-roundtrip, mcp-render, menu-actions and inspector-panels pass; diff check clean. Documented Xcode native/platform Testing flags and assembly workaround retained. Submitted drafts are stored/focused; preview/checkbox/accept UI remains T-807. Dedicated motion rendering, real-client connection and approved final exports remain T-808…T-810; no broader completion claimed.

T-807 · 2026-11-16 · Added the conditional 320pt Claude inspector scope, per-project access menu, client/status/note, real checkbox changes with skipped-dependency reasons, Discard/Accept N, stale Replay on current, project-scoped last-50 activity, document-bar status and timeline cut chips/rules/dashed added-block outlines. Review previews keep a frozen live snapshot for autosave/Save Now/close and other-client/explicit-live MCP reads; accept is one named undo step, discard restores the base. Frozen-context/id replay supports exclusions and dependent-op recovery; stale rebase preserves human edits, disconnected/closed-window pending drafts remain in memory. Timeline/inspector/preview/import/voiceover/destructive-menu actions are guarded while playback/scrubbing remain usable. Native mcp-review passes three-op partial acceptance, exact two-op seeded result, accepted 2 of 3 verdict, undo, disk/client isolation, Escape/edit guards, actual playback/scrubbing, stale rebase/discard, dependent recovery, linked/free retiming cut durations, disconnect and safe close. Full make test 190/190, mcp-edit, mcp-render, mcp-roundtrip, menu-actions, inspector-panels and timeline-ops pass. Built with the documented Xcode native/platform Testing flags and assembled the verified debug binary; no default-engine workaround change. Rendered/inspected real-review editor at 1200×760 and 1100×700, all five agent panel variants plus 420pt short panel, and regenerated/opened the gallery; artifacts /tmp/recorder-mcp-review{,-min}.png and /tmp/recorder-t807-agent*.png. Prototype/current editor/gallery guide used because original reference boards are absent. User visual waiver applied as agent judgment, not human approval. Diff check clean; real external-client connection/final export remain T-809/T-810.

T-808 · 2026-11-16 · Replaced temporary title plates for lowerThird/chapter in the existing text pass: Barlow title + 45% Andale subtitle, fixed 85% dark plate and scaled 3px white left rule, left-anchored default (0.05,0.8), centred chapter text with an optional numeric first line over a fixed 72% full-canvas scrim, and deterministic 0.3-source-second edge fades. Video colours remain fixed across app appearances; motion textures/font sizes are bounded and overflow truncated. TextPanel uses the existing selector in two rows for all five styles, includes the lower-third default anchor, and hides the ineffective chapter position grid; invariant-checked one-step style edits retained. Added Core construction/decode/explicit-position assertions, all-five-style marked landscape/portrait fixtures, fade-edge parity sampling, motion-text native pixel/cache/fade/appearance/oversize checks, text inspector PNG variants, and a settled 600ms screenshot wait. The previously unregistered layers command now invokes the existing marked layer-fixture/test runner unchanged. Full make test 190/190 passes using the documented Xcode native/platform Testing flags; assembled verified debug binary. Native motion-text, layers (including video playback), mcp-edit and both inspector PNG cases pass; real preview/export parity maxDelta0 over24 times per aspect. Inspected all four real 1920px preview frames (/tmp/recorder-t808-{lower,chapter}-{landscape,portrait}.png), four synthetic pixel-proof renders and settled 320pt style panels; user visual waiver applied as agent inspection, no human approval invented. MCP.md/SPEC updated; diff check clean. Final export approval/settings and external-client smoke remain T-809/T-810.

T-809 · 2026-11-16 · Added export.final with native NSAlert approval, ten-minute timeout/cancellation, saved native MP4 presets, unique default Movies/Recorder/Exports destinations, frozen accepted-project rendering, SRT/resource links and progress. Recheck identity/access/revision/editability after approval; stage completed outputs and move without overwriting existing/racing movies or sidecars. Added ui.show clamping/selection and consistent pending-draft revisions, plus retained active jobs and cleanup after client disconnect. Settings Agents uses actual Claude discovery/configuration, Connect, Copy JSON and observable live sessions; configured clients cannot be connected twice. Native mcp-export passes allow/deny/timeout/cancel/busy, stale/access/closed-project guards, MP4 decode/preset/progress, exact SRT, collisions, staging/disk/default isolation, UI/draft revisions and connection JSON/arguments. Full make test190/190 passes; final assembled-app mcp-export, mcp-render, mcp-roundtrip, menu-actions, settings-png agents and gallery PNG pass; inspected loading/configured/error client-row states and gallery. Actual Claude Code2.1.325 user configuration was added through the native Connect action to this workspace build; mcp get reports Connected and real CLI initialization exposes exactly9 Recorder tools. On /tmp/recorder-t809-client-root linked disposable package, real client read timeline/transcript, analyzed AAC pauses/fillers, cut, captioned, added a lower third, rendered four frames and submitted4 ops. Native checkbox untick/Accept3 produced2.775s, one native Undo restored the entire original project JSON, Redo restored accepted data. Real client ui.show and export used the production approval sheet; native Export wrote a124240-byte1280×720/24fps MP4 with one audio track (2.791667s rounded to frames) plus correct Welcome/to Recorder today SRT. A second production sheet selected a unique destination; native Escape returned DENIED with no new files. Real client also recovered from an atomic INVALID_OP overlap using the unchanged revision, rendered the corrected draft, then discarded it; accepted project unchanged. Kept generated example at ~/Movies/Recorder/Exports/Onboarding walkthrough · MCP check.{mp4,srt}; exact decoded frame /tmp/recorder-t809-approved-frame.png; CLI evidence /tmp/recorder-t809-client-{draft,export,recovery}.jsonl. User visual/HUMAN-review waiver applied as agent-driven checks on generated media/cached transcript, not a person's approval or evidence of live mic/transcription. Existing screen/Accessibility grants used without reset, installation, wake or unlock. MCP.md updated; diff check clean. T-810 docs/smoke remains.


T-810 · 2026-11-16 · Added SPEC §10 Agents (access/review, privacy, protocol/tools, clocks and limits), corrected all §5 format rules to conditional v5/v4/v3, documented connection/default workflow in README and --mcp/mcp-smoke in CLAUDE.md. Added a timed stdio smoke that pipes initialize + tools/list through the same-binary shim, asserting protocol and exactly nine tools including edit. Fixed the shared Makefile toolchain selection/Testing paths and selected the native SwiftPM engine so the Verify commands run without manual flags; Xcode/CLT path selection and smoke Python syntax checked. Plain make build release passes; gracefully quit the owned idle source-build app before assembling the Developer ID signed bundle. Plain make mcp-smoke passes (auto-launch and piped-EOF reply drain); plain make test passes190/190; packaged release --selftest menu-actions passes; diff check clean. Logs /tmp/recorder-t810-{build,smoke,core,menu}.log. Fresh prototype version2 audit maps all decisions, nine tools,19 in-scope capabilities and ten tasks to tests/native real-client evidence in MCP.md §9; T-801…T-810 complete. No new dependency, installation, permission reset, release/push, wake or unlock. Existing real-client/native-review/generated-media evidence retained; fresh mic capture and positive on-device speech were not repeated, drafts remain memory-only and native SwiftPM is deprecated upstream. Unrelated backlog unchanged.

T-811 · 2026-11-16 · User report: on the MacBook Air the installed build had MCP but nothing showed how to connect it (Claude Code had no server configured). Added Recorder ▸ Connect an Agent… (⇧⌘A, also in the status menu) modelled on dbman's Agents window: Start here guide + prompts, eight clients with Live/Connected/Update/Off/Not found status, Connect/Update/Disconnect/Reveal Config, copyable CLI commands and per-client snippets, Other client JSON, and an agentpack pane (init/mcp add/sync, copy as script, launch agents in Terminal). Core AgentConfig ported from dbman, user scope only (JSON merge / one TOML table, refuses commented JSON and inline TOML, keeps one .recorder-backup). Settings ▸ Agents now links to the window and lists live sessions; old AgentClient JSON/args moved to AgentConfig and the mcp-export check updated. make test FILTER=AgentConfig 3/3, make test 193/193, --selftest menus OK, settings-png renders for guide/claude-code/codex/agentpack inspected. Client paths other than Claude Code/Codex come from public docs (shortcut comment). mcp-export/mcp-smoke not re-run (unchanged logic; would replace the running source-build app).

T-812 · 2026-11-16 · Read panel-redesign artifact crsebftafkp3 version6 and added its entire requested roadmap, including formerly deferred tasks, to this tracker. Grouped pure Core rows in fixed kind order with stable call/index IDs and summed deltas; native tri-state group checkboxes validate/replay a whole group atomically through the existing inclusion path. Panel now owns its scroll area, collapsed groups/activity, current duration/delta summary, top stale/error notices and pinned Accept-only footer; Accept0 closes without modifying the project or adding undo. Named disclosures use320ms expansion/chevron rotation,55ms child stagger/4pt entrance, cancellable tasks and140ms opacity-only reduced motion; prototype environment override never disables the system preference. Change-row seeks remap each call's base clock through the current draft, including removed-footage seams and speed changes. make test FILTER=AgentDraft2/2 and full make test195/195 pass. Native mcp-review normal and --reduce-motion both pass actual checkbox/disclosure/seek/footer clicks, rapid reversals, exact seeded group replay/atomic invalid-ID rejection, zero-op acceptance, one-step undo and existing disk/client/close protections. inspector-panels passes; inspected 17-/5-op320×640,420pt short, stale/error/long-note, expanded/intermediate/reduced and integrated minimum editor PNGs. make -o app gallery and gallery-png CONFIG=debug pass using the already verified assembled binary; opened/inspected the actual gallery image. Agent visual judgment uses the existing user waiver, not a claimed human comparison. Evidence /tmp/recorder-t812-{group,core,review,reduced,panels,gallery,gallery-png}.log and /tmp/recorder-t812-*.png. No dependencies, project format change, install, permission reset, release or push. T-814 onward remain unfinished; full live propagation/prototype sequence is not claimed.

T-814 · 2026-11-16 · Added privacy-safe tool intents and aggregate results (kind/count/delta, render totals or error codes) at the existing MCPTools response boundary, with separately identified in-flight calls so cancellation cannot erase another request. The real panel now has a finite completion rail/status, collapsed newest-first intent/result feed,320ms group wipe/700ms2pt edge,80ms disclosure-button press/160ms hover,140ms reduced opacity, and cancellable arrival/disclosure/replay state; accepted groups remain readable/disabled with Accepted N. Added gallery Open study…: generated32s media, production editor/inspector/compositor/timeline, four-call17-op replay, Stop/restart and native Reduce Motion toggle; existing review methods simulate between-call preview in this isolated study only, not a claim that production T-815 live propagation exists. Full make test195/195 passes; mcp-edit asserts a3-op intent/result and no recorded key/edit/marker text, mcp-render verifies actual in-flight proxy state/cancellation, mcp-review passes normal/reduced native checkbox/disclosure/seek/footer/reversal checks, inspector-panels passes. New mcp-panel-motion passes native Replay/Stop/Reduce Motion, working/idle/error/ready/accepted and each-call mid/settled sampling, expanded activity reset, repeated replay cancellation, exact17-op totals/base-disk isolation, one acceptance undo, concurrent-call and sample-close cleanup. Inspected normal/reduced panel frames, expanded red error feed, reset state and full/minimum sample editor with real rendered preview overlay. make -o app gallery and gallery-png CONFIG=debug pass on the verified assembled debug binary; gallery PNG inspected. Evidence /tmp/recorder-t814-{core,edit,render,motion,review,review-reduced,panels,gallery,gallery-png}.log; /tmp/recorder-t814-motion/*.png. Existing user visual waiver applied as agent judgment, not a human comparison. No dependency, project-format change, install, TCC reset, release or push. T-815 and remaining MCP features remain unfinished.

T-815 · 2026-11-16 · First successful draft apply now starts the existing frozen-safe review in watching mode; later calls update it once per batch, and submit enables review controls in place. Watching blocks human mutations/acceptance, shows the Escape takeover notice, and Escape through preview/timeline/controller restores the human base while suppressing later automatic previews for that session. Competing clients retain invisible drafts with a notice and cannot replace/submit over the owner. First Draft/Live apply conditionally selects Claude only when the editor is key. Reused existing cut chips/dashed blocks with stable cut identities,320ms wipe/75ms lane stagger,220ms accepted settlement and140ms reduced opacity on the existing finite display link. The gallery's17-op replay now uses production MCPTools apply/submit. Actual-client verification exposed duplicate editor keys for symlink aliases and file/directory URL forms; fixed canonicalization once in the shared opener and added regressions for both forms. Full make test195/195 passes; final assembled debug app passes mcp-live normal/reduced, mcp-edit, mcp-review normal/reduced, mcp-panel-motion, mcp-roundtrip, mcp-render, mcp-export, project-navigation and inspector-panels. Inspected intermediate/settled timeline marks, normal/reduced panels, full/minimum sample editors and gallery PNG; make -o app gallery and gallery-png CONFIG=debug pass. Actual authenticated Claude Code used only a generated disposable package through an isolated same-uid socket/stdio relay, applied three sequential calls (2/3/5 cumulative ops), submitted, and was observed watching in the same native editor before every submit with liveProject/disk/undo frozen. Its180s own-window movie completed normally, decoded into three distinct nonblank changing states, and final discard preserved the original package. Evidence /tmp/recorder-t815-client-1794842781329/{client.jsonl,observations.json,call-*.png,recorded-*.png,live-client.mov}; logs /tmp/recorder-t815-{core,live,live-reduced,edit,review,review-reduced,motion,wire,render,export,navigation,panels,gallery,gallery-png}.log. The recorded study explicitly selects Claude; automatic selection assertions are conditional on native key-window state. Existing user visual waiver applied as agent judgment; no human comparison, install, TCC reset, wake/unlock, new dependency, project-format change, release or push. Normal production shim/configuration and the installed app were preserved. T-817…T-824 remain unfinished.

T-817 · 2026-11-16 · Pending submitted drafts now accept additional applies from their owner and return to watching until resubmitted. Reused existing replay/exclusions/status reasons; stable draft/operation ids and nil verdict survive iteration, with the human base/disk/undo frozen. Dry, empty and failed calls leave review submitted; awaited analysis rechecks submission/exclusions/skipped state as well as the existing identity/revision/access guards. Updated MCP schema description, MCP.md and SPEC. make test195/195 passes. Extended mcp-review normal/reduced passes submit/exclude/apply/status/resubmit, native disabled watching controls,3-of4 acceptance and one undo; dependent creation/update exclusion/reason survives another apply and recovers the same id when re-included. mcp-edit passes dry/empty/invalid/successful submitted iteration; mcp-live normal/reduced, mcp-panel-motion and mcp-roundtrip pass. Normal iteration-watching/ready panel PNGs inspected. Logs /tmp/recorder-t817-{core,review,review-reduced,edit,live,live-reduced,motion,wire}.log; PNGs /tmp/recorder-t812-{iteration-watching,iteration-ready}.png. No new dependency, format change, install, client configuration change, TCC reset, release or push; actual client recording was not repeated. User requested no further test windows or focus changes because they disrupt work: owned test processes are finished and subsequent work must stay in the background. T-818…T-824 remain pending.

T-818 · 2026-11-16 · Added flat Codable snap options to clip-splitting cut/cutWords/speed and default-on cutPauses, preserving strict defaults/opt-out. Reused the editor's0.1s media/two-frame output split limits at actual playback/media clocks; invalid points move to the nearest clip edge, earlier cuts inform later snap boundaries, and changes.note reports adjusted source ranges. Collapsed/uneditable ranges and snapped full-media removal become skipped warnings while valid batch operations continue; malformed/nonfinite inputs and strict invalid edits remain atomic errors. Draft replay retains automatic no-op skips in its deterministic cut seed, reports their reasons and excludes them from Accept N; adjustment notes use the existing change row. Added source-frame/top-left0–1 center schema descriptions from T-820. Full make test199/199 passes, including four added edge/base-time/stable-id, short/neighboring/full-removal, rate/import/speed and pause/default/JSON/word cases. New mcp-edit --headless passes the actual MCP schema/decoder, Boolean rejection, adjustment/warning generation, frozen replay and skipped selection without NSApplication/window creation. Logs /tmp/recorder-t818-{core,headless}.log. Per the user's instruction, no GUI selftests, app windows, focus changes, gallery launch, install or real-client recording were run; interactive row appearance was not rechecked. No dependencies, saved project format change, TCC reset, client configuration change, release or push. T-819…T-824 remain pending.

T-819 · 2026-11-16 · Time fields (from/to/at) on cut, cutPauses, speed, zoom, text, highlight, marker and update accept numeric seconds (documented base-revision semantics, unchanged) or `{marker:"id", offset}`; anchors resolve against the draft prefix after earlier ops in the batch, including markers created/updated/deleted earlier. Missing anchors, anchors in removed footage and out-of-range offsets are atomic errors; replay keeps stable ids and excluded anchors skip dependents with a reason. MCP schema `oneOf` number/anchor plus edit description updated. make test 203/203 passes; `mcp-edit --headless` passes anchor schema/decode/offset/exclusion/recovery with no windows. No GUI selftests, dependencies, format change, install, release or push. T-820…T-824 remain pending.

T-820 · 2026-11-16 · Zoom center/text position validation (finite, 0–1, source frame, top-left) now has regression coverage for create and update and a clearer error. New optional `render.frames` `grid:true` overlays a labelled 0.1-step grid (pure Core `DebugGrid` geometry, magenta lines, 0/0.5/1 emphasised) after rendering; default path untouched so normal frames are byte-identical, key chips still hidden. Non-boolean grid or use outside render.frames is INVALID_OP. make test 205/205; `mcp-edit --headless` draws the grid on a synthetic PNG and asserts line pixels at normalized corners/centre. No GUI selftests, dependencies, format change or push. T-821…T-824 remain pending.

T-821 · 2026-11-16 · Zoom ops (create and update) take `follow:"cursor"|"fixed"` and `ease:"focused|smooth|rapid|medium|slow"`. Cursor maps to the existing auto mode (CursorPath dead-zone tracking in the 240 Hz CameraPath table), fixed to manual; cursor with a center is an error, omitted follow keeps today's center-based default. Ease maps to the existing Spring presets via new optional `Zoom.ease` (saved only when set, absent/unknown decodes nil, so saved projects and format version are unchanged); CameraPath uses the zoom's preset for entry, tracking and its exit. Preview and export share the cached table through FrameState so they agree, including clip speed/cut edges via the existing timeScale. follow/ease on non-zoom updates are errors. make test 208/208 incl. entry/exit preset ordering, settle, legacy JSON, create/update/validation/JSON cases; `mcp-edit --headless` asserts schema enums and decode. No GUI selftests, dependencies, format version change or push. T-822…T-824 remain pending.

T-822 · 2026-11-16 · Text create/update accept the inspector's existing fields only: `size` (now validated 16–120, same as the slider; schema min/max), `position` (normalized, already supported) and `color` from the existing BlockColor palette (the inspector swatch field). Update also tags zoom and mask blocks with color; markers reject it. Colour is the existing optional `color` field (no new fonts, animation, format or render path), so preview/export/inspector read the same TextBlock values. make test 209/209 incl. create/update/bounds/JSON/hex-rejection cases; `mcp-edit --headless` asserts schema and decode. No GUI selftests, dependencies or push; native render parity by construction (render path unchanged). T-823…T-824 remain pending.

T-823 · 2026-11-16 · SPEC §10 "Assets and layers" written first. New `project.assets` action lists package layer media and other readable library recordings (same access gate as project.list). New `layer` op (`asset`|`path`|`recording`, exactly one; images `from/to`, videos whole-clip, optional rect, default card placement) is applied by Core only for imported `MediaAsset`s carried in the draft call's frozen `EditContext`, so replay, exclusions, anchors and undo are unchanged. App `MCPAssets` validates local paths (regular image/video, ≤4 GB, home/temp only, resolved symlinks, no hidden dirs, no ~/Library except the agent cache, no .recorder packages), probes/copies through the editor's own import code (refactored into `EditorModel.probeMedia/copyMedia`, behaviour unchanged) into immutable `media/<uuid>.<ext>` without writing project.json, dedupes within a call, removes imports on failure/dryRun, and purges unreferenced session media at draft accept/discard. Audio-only files are refused. make test 212/212 (layer image/video/audio link, validation, anchors after cuts, lanes, JSON exactly-one-source); `mcp-edit --headless` covers trusted/rejected paths incl. symlink/hidden/package/outside, byte-identical import, dedupe, isolation, atomic failure, purge, frozen replay, reuse by asset id, listing, schema, and a generated real .mov imported as a library recording with card placement. No GUI selftests, dependencies, saved-format change or push; native preview/export of layers is the existing layer renderer reading the same package media, not re-run here (no GUI per standing instruction). T-824 remains pending.

T-824 · 2026-11-16 · Footer **Play draft** (left of Accept N) uses the existing `AgentRender.clip` 540p proxy of the reviewed draft project via new `DraftPlayback` (Identity = project/session/draft id/revision). Button shows Cancel n% while rendering; repeat requests are ignored while rendering and a new request replaces the previous preview; failures show an inline message; a result for a draft that moved on is deleted, never shown; new edit.apply, accept, discard, takeover, editor close and session invalidate cancel the render and close/delete the preview. Native AVKit window plays with audio. Enabled only while a draft is being watched/reviewed by the panel's session with nonzero duration. make test 212/212; release and debug builds pass; `mcp-edit --headless` asserts the state machine with injected render/present (progress, normal flow, repeat ignored, replacement deletes previous, cancel incl. a renderer that ignores cancellation, stale draft discard, error text, DENIED quiet, owner-only invalidation). The proxy renderer is unchanged and keeps its existing audio/540p/offset assertions in `mcp-render`. NOT run (standing instruction: no test windows or focus changes): GUI selftests, the AVKit window itself, native panel PNGs for the new button, real-client recording; those remain HUMAN/visual checks. No dependencies, saved-format change, install or push.

Final audit against https://artifacts.microapps.space/a/crsebftafkp3 · 2026-11-16 · Grouped Changes + pinned footer (T-812), status strip/activity/motion with Reduce Motion (T-814), live draft preview + timeline marks (T-815), iterate after submit (T-817), clip-edge snapping (T-818), marker anchors (T-819), zoom coordinate docs/validation + debug grid (T-820), cursor-follow + easing (T-821), text styling fields (T-822), assets + layer op (T-823), Play draft (T-824) are all implemented and committed (6d1ee38…T-824). Audio ops stay out of scope as the source states. Evidence caveat: tasks T-819…T-824 were verified with the Core suite and headless checks only, per the standing no-GUI instruction, so their native visual/real-client confirmation is outstanding for the human.

Native verification · 2026-11-16 · Run on explicit user approval ("Run them now", overriding the earlier no-test-windows request for this pass). Debug app assembled; on /tmp/M6Fixture.recorder all pass: mcp-edit, mcp-render, mcp-review normal and --reduce-motion, mcp-live, mcp-panel-motion, mcp-roundtrip, mcp-export, project-navigation, inspector-panels, mcp-edit --headless, plus new `mcp-layer-playback` (real MCPTools layer edit on an open editor: draft isolation of live state/project.json, preview and export-proxy frames show the layer exactly in its range, real AVKit Play draft window with audio+video tracks that plays, cancel, edit.apply invalidation, window-close cleanup, discard purge, accept keeps exactly the used media as one undo) and `zoom-ease-parity` (zoom ease changes both preview and proxy frames and converges). Native run exposed and fixed two defects the headless tests could not: show() deleted the just-rendered preview file, and mcp-edit still asserted 12 op schemas. Actual authenticated Claude Code via `mcp-live-client` (evidence /tmp/recorder-t824-client) passed with the new tool schemas. Panel PNGs /tmp/recorder-t824-motion/{ready,editor-ready}.png inspected: Play draft sits left of Accept N in the pinned footer at 320 pt without clipping. make test 212/212. Still HUMAN: judging panel feel/motion against the design frame (mark [~] until looked at).

HUMAN review · 2026-11-16 · The user judged the Claude panel's feel and motion against the design frame and approved it ("i approve finalize it pls"). The remaining `[~]` for this request is closed; T-812…T-824 are complete.

T-833 · 2026-11-17 · Agent eval harness `scripts/agent-eval.py` (stdlib only): scores MCP JSONL transcripts for ops per task (dryRun false, ok edit.apply), images returned by render.* (tiles/frames counted from args), tool calls, final lint pass (last `lint` array, fails on error/warn), final report duration, plus manual `--pref label=value`; table and `--json`. `--selftest` asserts metrics on two synthetic transcripts and passes. Brief and usage documented in docs/MCP.md §10. No Makefile target (the script takes transcript args), no GUI run, no dependencies. Real recordings and MCP changes not yet run through it (fixtures are synthetic). T-830, T-831, T-832 remain pending.
T-827 analyze.shots · 2026-11-17 · Core `storyboard(signals:fps:events:thresholds:)` + `Storyboard.mapped(through:)` (Shots.swift), app decode/SSIM/cache (ShotAnalysis.swift, `shots-cache.json`), `analyze.shots` tool with concise/detailed and thresholds. `make test` passes (ShotsTests). The 100 s decode timing is unverified (no GUI/selftest run); `thumb` omitted (no recorder:// resource mechanism).
T-828 · 2026-11-17 · `render.storyboard/strip/compare` (AgentRender `tiles`/`keyframe`/`compare`, MCPTools render branch; storyboard via `loadStoryboard` stub until T-827 merges) · verified: `make test` all pass, `make build` · not verified: rendered output (no GUI run; needs `--selftest`/HUMAN on a fixture once analyze.shots exists).

T-832 · 2026-11-17 · opt-in shot captions: Core `ShotCaption.shape` + `ShotCaptionTests`, app `AgentCaptions.captionShots` (Vision OCR on focus crop, classifier fallback, nil on failure) · verified: `make test` all pass, `make build` · not verified: Vision output on a real recording; `captions:true` on analyze.shots is wired by the integrator. captions wiring into analyze.shots done at integration
T-831 · 2026-11-17 · `reframe` op (`aspect` 4:5|1:1|9:16|16:9, `mode` perShot|static). Core `reframePlan(storyboard:aspect:mode:sourceSize:) -> [CropKey]` (AutoFlip-style: stationary on focus ∪ cursor when it fits the largest aspect window, else linear pan between focus edges, clamped inside the frame; static = one window over all focus). Model: additive `Project.cropKeys` (source-time linear keys, empty = static `crop`; `Project.cropSample(atSource:)`), `Output.Aspect.r4x5` + `.ratio` (replaced three duplicate switches); format version 6 saved only when 4:5 or cropKeys is used (SPEC §5; `currentVersion` 6). Preview and export both sample the crop in `makeFrameState` (one line), so the existing Compositor consumes a per-frame crop of constant aspect; the Crop sheet clears keys. The MCP edit handler fills the op's `keys` from `loadStoryboard` before the op is stored (draft replay needs no storyboard); `loadStoryboard` is a stub throwing "run analyze.shots first" until T-827 merges (`// ponytail:`). Tests: ReframeTests (focus kept ≥95% of frames, stationary vs pan, clamp/aspect, static, cut at boundaries, old-project decode, op + version). make test and make build pass. NOT verified (no GUI): native preview/export pixel parity of a keyed crop, editor overlays (zoom-target/mask rect) while keys are active still map through the static `crop`; edgeContent lint is T-829.
T-829 · 2026-11-17 · `EditReport.swift` (editReport/lint/LintProfile reel|tutorial|demo, rules hook/maxStatic/asl/duration/tinyShot/orphanEffect/edgeContent with `suggest` ops) takes a source-time Storyboard; edit.apply/dryRun return `report`, `render.lint {profile,draft}` added; `MCPTools.loadStoryboard` is a stub until T-827 merges. make test 225/225 (EditReportTests). Not run: GUI/selftests.

T-830 · 2026-11-17 · `IntentOps.swift` lowerIntents: keepShots, pace, fitDuration, autoZoom (AutoZoom lead/tail params), speed `ramp` (stepped, ponytail) → cut/speed/zoom in the same batch (one `applying`, one undo step), `lowered` returned by edit.apply. IntentOpsTests incl. fitDuration target/tolerance/protect. make test 225/225; selftest schema count bumped 13→17 (not run).
T-825 · 2026-11-17 · Drafts persist in `agent-draft.json` (Core `AgentDraftRecord`; `project.open` re-adopts and returns `draft:{id,status,changes}`, replaces D8); `initialize` advertises `tools.listChanged` + `schemaVersion` and sends `tools/list_changed` after a schema change; limits validated server-side from the tool schemas (render.frames cap 24 = schema, Core `schemaViolation`); annotations, `outputSchema`, `mcp-schema` parity self-test (not run: no-GUI instruction). `make test` passes; selftests and live client not run.

T-826 · 2026-11-17 · `edit.remove` covers every lane `timeline.get` emits, `edit.update` adds layers (both ends), other lanes are `editable:false` + `reason`; anchors `{marker:label}` (unique), same-batch `ref`, `{shot,edge}` via `EditContext.shotTime` (defaults to unknown shot); errors carry `fix` (snapped/clamped op) and `current`. Core tests for lanes, anchors, fix; `make test` passes. The layer timeline view was already correct (connected length), so only update uses both ends.
Integration T-825…T-833 · 2026-11-17 · Merged all branches on dev after independent review + fix rounds per branch. Shared `loadStoryboard` reads analyze.shots' cached signals only (never decodes); `{shot,edge}` anchors resolve from it, including persisted-draft restore; `edgeContent` samples the keyed crop and suggests `reframe`; `fitDuration` targets the export length (outro layers count; regression test). Evidence: make test 262/262; headless `--selftest mcp-schema` (26 actions) and `mcp-edit --headless` OK; `shots-perf` on a copy of Golden Island: 122 source shots, cached call 0.007 s, Core reel pipeline keepShots→pace→fitDuration 30→reframe 4:5 = 98.6→31.0 s, hook 0.0 s, static 0.9→0.0 s, lint flags asl 4.7 s (reel wants ≤2.0); `--selftest mcp-shots` (user-approved window) end to end through MCPTools.call OK. Not met/unverified: decode speed (≈11.5 s per 100 s release, target 5 s), F1 vs hand labels, native visual review of storyboard tiles/captions/reframed preview-export.
Recording-time shot cache · 2026-11-17 · `ShotAnalysis.Live` computes analyze.shots signals from capture frames (same ticks/luma as decode, off the capture queue, utility QoS) and writes `shots-cache.json` after screen.mov is finalised, so analyze.shots on new recordings never decodes. BGRA window captures are converted to BT.709 video-range luma; existing recordings keep the decode path. Verify: `--selftest shots-live` on Gentle Moon (17 s): 173/173 ticks, 9/9 shots, boundary F1 1.00 vs decode. Not run: a live capture session (needs Screen Recording + a real recording).
Feedback fixes (https://artifacts.microapps.space/a/fchbf383fa0q) · 2026-11-17 · P0-1/P0-2 root cause: shot times are screen.mov media seconds but storyboard, captions, lint, keepShots, reframe and {shot} anchors treated them as project source seconds (they differ once clips carry mediaStart, e.g. Golden Island source 33.3 s = media 57.8 s). One shot table now: `Storyboard.inSource(clips:)` converts once in `loadStoryboard`, which analyze.shots also returns, with the thresholds analyze.shots used persisted (`shots-thresholds.json`). Captions: accurate OCR, confidence ≥ 0.5, symbol-noise tokens dropped, typing shots never captioned. P0-3: keepShots lowered result lists every shot with kind/energy/kept. P1-1: focus ≥ 80% of an axis centres; no window shows less focus than the centre crop. P1-2: edit.undo inside a draft drops the last call. P1-3: hook counts motion/clicks, tinyShot compares the printed value, edgeContent never changes the chosen aspect. P1-4: one-intent-per-batch in the edit tool description. Skipped P2 (per-section report timeline, dual timestamps on sheets, export preset, note in review UI). Verify: make test 267/267; mcp-schema; mcp-shots on Gentle Moon (undo, reapply, id parity).
Feedback run 2/2b fixes · 2026-11-17 · artifact fchbf383fa0q v3. R2-1 reframe perShot: 3 % hysteresis (keeps the window when it shows as much focus), 0.3 s ease at non-cut shot boundaries, steps only at `boundary:"cut"`; `report.reframeJumps` + concise draft ops show `{keys: n, jumps}`. R2-2 tinyShot suggest is dry-run applied (piece, widened to clip edges, or stretched to 0.12 s) else none. R2-3 shot pieces < 1 analysis frame dropped from lint and intents. R2-4 tinyShot only next to an edit cut or `boundary:"cut"`. R2-5 `aslSec` = visual shots (edit cuts + cut shots), `subShotAslSec` separate. R2-6 render.compare base at the same source moment, labels base/draft/src. R2-7 draft.status concise keys. R2-8 renders queue per session (export still RENDER_BUSY). R2-9 `part:"k/n"` on split shots. R2-10 root cause: snapped intent ops skip range checks except `to > from`, so a fully cut sliver became a 0-length op → OUT_OF_RANGE; intents drop sliver pieces and < 0.01 s ops. R2-11 `protect` (ids or `caption~regex`) on keepShots/fitDuration; captions persisted in `shots-captions.json`. R2-12 keepShots tail cut ends at the last footage clip, not a trailing gap. Evidence: make test 272/272; mcp-schema, mcp-edit --headless, mcp-render (M6 fixture), mcp-shots (Gentle Moon) OK. Skipped: minPerSection quota and section-balanced pace (R2-11), easing at edit cuts. Not run on Golden Island.
Feedback run 3 + regression fixture · 2026-11-17 · Why feedback kept finding bugs: Core tests used hand-made storyboards; real-footage checks (shots-perf, mcp-shots) were opt-in selftests needing the video, so the bugs that only real layouts show (mediaStart remaps, trailing gap, slivers at edit boundaries, view-swap focus) were found by the agent instead. Now `Tests/RecorderCoreTests/Fixtures/golden-island.json` (253 KB: cached frame signals, mouse events thinned to 10 Hz, clips; key events, texts and captions removed; regenerate with `--selftest shots-fixture <copy.recorder> <out.json>`) feeds `GoldenIslandTests` in `make test`: segmentation → media→source → keepShots/pace/pace/fitDuration 30/fitDuration 20 with no skipped op, invariants, every lint cut suggestion applies; reframe 1:1/4:5/9:16 never worse than centre, ≥85 % focus when it fits, 0 jumps, and the R3-1 point. Both tests fail on the previous Core and pass now. Fixes: R3-1 root cause = focus was the union of every changed pixel, so a click that swaps the whole view made the shot's focus the full frame (centre crop); focus now uses changes after the shot settles (blinks < 0.1 % area ignored), and a shot with no usable focus aims at the next shot's within 3 s; edgeContent samples 3 points. R3-3 intent ops bypassed decodeOps' schema check; now `validateOp` checks every op, naming unknown fields and the valid ones (mcp-edit asserts it). Second-pace skips: intents no longer emit cut/speed ranges under the 0.1 s clip minimum. R3-6 submit and project.open return counts unless detailed. Evidence: make test 274/274; mcp-schema, mcp-edit --headless, mcp-shots (Gentle Moon), mcp-render (M6) OK. Not done: R3-2 sections/minPerSection, R3-4 protect by range/section, R3-5 beat-cutting pace.
R3-2 sections · 2026-11-17 · Shots carry `section`: a break where the project rearranges the recording (media jump ≠ source jump between clips; trims and cut pauses are not breaks), else cut-delimited runs ≥ 10 s for untouched/historical recordings; < 3 s sections merge. `fitDuration {minPerSection, balance: energy|even}`, `protect: section:N`, `report.sections[{section,name?,from,to,shots,keptSec}]`. Golden Island fixture: 8 sections; plain fitDuration 30 leaves graph and contour at 0 s, `minPerSection:2, balance:even` keeps 2.0–4.1 s in every section at 31.1 s (GoldenIslandTests.fitDurationKeepsEveryScene). Not done: section names without captions, proportional balance, keepShots quotas, R3-5 beat pace.
Feedback run 4 · 2026-11-17 · R4-1 root cause: the server advertised the new fields (the unknown-field error lists them from the same schema) but the client kept its tool list from before the app update and ignored tools/list_changed; now every tool result carries `schemaNotice` naming the missing fields until that connection re-lists, and `intentFields` (asserted on every intent field read) must equal the tools/list op schemas (mcp-schema). Nested intent fields no longer fall back to same-named top-level fields. R4-2 fitDuration notes sections left under minPerSection. R4-3 `fitDuration.drop:[section]`. R4-4 sections report srcFrom/srcTo and outFrom/outTo. R4-5 pace beat-cuts shots with clicks (Golden Island: 21 of 29 ops speed 1.5 → 25 cuts + 10 speeds, ASL 2.9 → 1.2 s) and absorbs < 0.3 s pieces between cuts. tinyShot now measures visible pieces between cuts. Regression: GoldenIslandTests.run4PipelineShipsCleanAndBalanced replays the agent's run-4 pipeline (duration 30±2.5, reel ASL, 0 jumps, no edgeContent, short sections noted) + fitDurationDropsChosenSections; mcp-schema checks parity and the stale-client notice. Evidence: make test 278/278, mcp-schema, mcp-edit --headless, mcp-shots (Gentle Moon) OK.
Closing run-4 leftovers · 2026-11-17 · Section names without captions:true: analyze.shots OCRs each section's representative (longest non-typing shot) once, cached in shots-captions.json ("" = no text); report.sections[].name uses it (mcp-shots asserts one cached read per section; Gentle Moon 2 sections, analyze 23.6 s vs 21.4 s before). fitDuration balance even/proportional now cut to per-section quotas found by bisection (last shot trimmed, no stub < 0.5 s): Golden Island even 2.4–3.0 s per section, proportional 24 s scene 5.0 s vs short scenes 2.0 s. pace {profile}: reel/demo/tutorial beats and waits; Golden Island ASL 1.23/2.7/3.61 s, each inside its profile, cuts 25/8/2, no flicker on demo/tutorial. Regression: GoldenIslandTests.paceFollowsTheProfile, balanceModesSplitAsAdvertised, sectionsHaveNamingShots. Evidence: make test 281/281; release + debug build; mcp-schema (parity incl. pace.profile), mcp-edit --headless, mcp-shots (Gentle Moon), mcp-render (M6) OK.
Run 5 + UI responsiveness · 2026-11-17 · Measured with a main-thread watchdog in mcp-shots (now a hard guard: any tool > 250 ms fails). Before: analyze.shots 1311 ms, render.storyboard 586 ms, render.compare 312 ms of UI freeze on a 17 s clip; cause: renderFramesPNG decoded the video sequentially and PNG-encoded on the main actor, contact sheets composed on main, edit/lint reports (with dry-run applies) on main. Now sample reads, PNG and sheet encoding and reports run off main: worst 54 ms (edit.apply). R5-1 edit description lists the intent fields (clients that cache schemas read it); schemaNotice keeps the text item mirroring structuredContent (caught by mcp-render). R5-2 section names: 3 shots read per section, heading-like (ALL-CAPS word) captions first, OCR noise names nothing. R5-3 protect is per op (documented in the description). Not done: R5-4 (lint already flags the one hook flicker). Evidence: make test 281/281; release+debug build; mcp-schema, mcp-edit --headless, mcp-shots, mcp-render, mcp-roundtrip OK.
T-901 · 2026-11-17 · verified: `make test` 282/282 (new `layersAreShotsAndDurationIsExport`); `--selftest mcp-edit --headless` OK; `--selftest mcp-shots <Bright Forest>` OK · Core `Storyboard.output(project:)` maps the media-keyed table through the viewed project's clips and full-canvas layers (recording layers of screen.mov show their media window's shots with `layer` set; image/video layers become `L:<id>` coverage); analyze.shots uses it (captions/sections copied by id), duration = exportDuration; `project.assets.layers` lists every layer incl. recording with track/mediaStart/mediaRate; library duration = exportDuration. Lint/report still read clip-only shots: layer-aware lint comes with T-904 (`uncovered`) and T-910.
T-902 · 2026-11-17 · verified: `make test` 283/283; new `shotAnchorAfterSpeed` (Golden Island, Free mode, anchored shot inside a 3× range) fails without the fix (s70 marker 0.33 s off) and passes with it · `{shot}` anchors map base spine → media → prefix spine (`EditOps.coordinate`). Root cause: in Free mode `setSpeed` rewrites clip spine ranges, so base-spine shot seconds pointed at other footage. Markers/refs are stored in the project's own spine and are rewritten with it, so they keep the existing path.
T-903 · 2026-11-17 · verified: `make test` 284/284 (new `GoldenIslandLayerTests.layerSetRateSlipTrim` on the feedback layout: 3× rate shortens the 2× recording layer to 2/3, slip to 30 s keeps position/length, trim to end−2 and extend to end+1 past the clips, slip past media fails naming the limit, text on a layer lists valid fields, JSON round-trip); `--selftest mcp-schema` OK; `mcp-edit --headless` OK · Delivered as the generic `set {id,…}` op (EDITING-CORE D4) rather than more `update` fields: layers accept from/to (numeric output s, also beyond the clips' end), mediaStart, mediaRate (length follows; linked layer audio follows), color; `set` on any other id lowers to `update`. Anchored from/to on layers is not supported yet (INVALID_OP says numeric).
T-904 · 2026-11-17 · verified: `make test` 285/285 (new `uncoveredGapIsLintedAndCuttable` on Golden Island: the 0.56 s tail gap is found, linted with a cut, the cut removes it, ripples the appended layer by 0.56 s and shortens export by the same; the existing pipeline tests now also apply every `uncovered` suggestion); `mcp-edit --headless`, `mcp-shots` OK · Core `uncoveredRanges(project)` (no non-gap clip and no full-canvas layer, ≥ 1/60 s); lint rule `uncovered` suggests a cut of the part inside the clips, rounded inward to 0.01 s (a tail past the clips gets no op); unsnapped `cut` ranges include gap clips and `agentRemoveSourceRanges` shortens gap time (`removeGapTime`) then `settleConnected` re-anchors layers.
T-905 · 2026-11-17 · verified: `make test` 286/286 (new `toolPolishSheetStaleRefocus`); `--selftest mcp-schema` OK; `mcp-edit --headless` OK · Core `sheetTimes`, `staleRevisionMessage`, `Storyboard.refocused` (pure, tested) wired into MCPTools: render.sheet honours from/to; STALE_REVISION says "You passed X; the current draft revision is Y" and names the base only when it moved; reframe accepts `focus:{shotId:{x,y}}` and edit.apply returns `reframe:{keysBefore,keysAfter,changed,shots}`. Assertions for the sheet range and stale text were also added to the windowed `mcp-roundtrip`/`mcp-edit <fixture>` selftests but NOT run (user: no test windows/focus changes).
T-910 · 2026-11-17 · verified: `make test` 287/287 (new `itemsCoverEveryKind`); `agentTimeline` JSON for Golden Island (+ markers, zooms, text, a from/to window) byte-identical before/after the rewrite (temporary dump test, removed); `mcp-edit --headless` OK · `Items.swift`: `Item {id, kind, track, out, spine?, media?, anchor, editable, label}` for 12 kinds (graphics join in T-921), `editableFields(kind)` is the one field table; `agentTimeline` and `project.assets` ranges are built from `items`. `Storyboard.output` and `uncoveredRanges` keep their own coverage pass (they need full-canvas, not every layer).
T-911 · 2026-11-17 · verified: `make test` 288/288 (new `KernelFuzzTests`: 500 seeded batches over simple/layered/Golden Island/Golden Island Free; also run once at 2,400 batches, clean); `mcp-edit --headless` OK · Root causes the fuzz found and fixed in shared code: (1) `resizeLayer` let an imported video layer run past its file when the caller had no duration (agent `update`/`set`) — it now caps at the current media end unless the duration is passed (human path always passes it); `set mediaStart` on such a video may only slip earlier; (2) `items` listed blocks over a trailing gap past the export (Free mode) — items are now clamped to the visible part. Trailing gap clips themselves may sit past the export by design (the export ignores them).
T-912 · 2026-11-17 · verified: `make test` 289/289 (new `genericSetUsesTheFieldTable`: zoom scale, text text+position, mask from+kind blur, text-on-zoom error lists valid fields, layout has none, JSON decode); `mcp-schema` OK; `mcp-edit --headless` OK · `SetFields` carries every update field + mask `kind`; `set` validates against `editableFields(item.kind)` from `items(base)`, then non-layer items run the existing update path per phase (the stored op stays `set`, so replay/IDs are unchanged); mask kind applied after it. `update` kept as the older name (no deprecation churn for existing drafts).
T-920 · 2026-11-17 · verified: `make test` 292/292 (new `KeyframesTests`: per-property neighbours, holds before/after, eases 0→1 incl. spring overshoot, validation, round-trip, invariant); `mcp-edit --headless` OK · `Keyframes.swift`: `Key`, `Transform`, `eased`, `evaluate`, `keysError`; optional `keys` on TextBlock (spine s since start) and LayerBlock (output s since start), checked in `checkInvariants`. User direction mid-task (no backward compatibility): `save` now always writes `currentVersion` 7; the per-feature minimum-version rule and its tests are gone (tests now assert the single version); loading keeps defaults so existing projects open. SPEC §5 and EDITING-CORE D1 updated. Spring ease is closed-form (`shortcut:` comment).
Clean core · 2026-11-17 · verified: `make test` 292/292; `mcp-schema`, `mcp-edit --headless` OK · Per the user (no backward compatibility): removed `EditOp.update` and its JSON name; `set` is the only patch op (Core prepare/apply branches now match `.set` for non-layer items, the dead layer branch of the old update path is deleted, mask `kind` lives in the mask branch); tests and selftests converted mechanically; MCP schema/docs list only `set`. Persisted drafts containing "update" ops will not replay (reported as unrecoverable and kept as agent-draft.failed.json).
T-921 · 2026-11-17 · verified: `make test` 295/295 (new `GraphicsTests`: connected placement/cut ripple/set move/remove, table rejects mediaStart, validation, count/type-out text, colour parse); `mcp-edit --headless` OK · Graphic = `LayerBlock.kind .graphic` + `graphic` payload (D6 revised: reuse layer machinery, no new array); `hasMedia` replaces 18 `kind != .image` checks; `Item.Kind.graphic`; graphics never count as coverage or shots; `Project.addGraphic`.
T-922 · 2026-11-17 · verified: `make test FILTER=Graphics` 4/4 (new `templatesBuildValidGraphics`: every template from its example and from defaults is valid and places; unknown template/param/out-of-range errors) · `GraphicTemplates.make(name, params, length)` + `catalog` (titleCard, callout, stepBadge, spotlight, progressBar, counter); screen-space templates use a full-frame box so element coordinates are source-frame coordinates.
T-923 · 2026-11-17 · verified: `make test` 296/296; new headless `--selftest graphics-png <Bright Forest> <out>` (title card, screen callout under a 2× manual zoom, counter, progress bar, keyed text; each changes pixels vs the plain project) OK and its PNGs inspected (callout ring lands on the zoomed target at constant size, counter mid-count, title/keyed text legible on a light recording); `--selftest parity <out>/graphics.recorder`: every graphic sample time maxDelta 0; overall 3 at t=1.286 (inside the added zoom's spring) — the untouched source project already fails parity at maxDelta 4 (pre-existing, 2× clip, not graphics) · Compositor draws graphic layers with CoreGraphics into an output-sized transparent texture (top-left origin) composited by the image-layer path; `space: screen` maps through the cursor/mask crop+zoom mapping; `Graphic.anchor` = follow a point at constant size (callout, badge), nil = scale with zoom (spotlight); Core `layerStates` applies layer keys (x/y/scale/opacity; rotation drawn for graphics only — `shortcut`) and returns `elapsed`; `drawText` applies text keys. Templates restyled for contrast on light and dark recordings (dark plates, outlined strokes). Image elements dropped (use an image layer). Graphics redraw every frame (`shortcut:` cache later).
T-925 (done before T-924: headless-verifiable and unblocks Claude) · 2026-11-17 · verified: `make test` 297/297 (new `graphicAndAnimateOps`: JSON round-trip, template + raw elements + rect, keys, animate text/clear, deterministic replay, six strict-error cases); `mcp-schema`, `mcp-edit --headless`, `make mcp-smoke` OK · EditOp `graphic {from,to, template{name,params} | elements, space, anchor, rect, keys}` lowers to `addGraphic` (first free graphic lane) and `animate {id, keys}` (layer/graphic/text); `project.templates` returns the catalog; schema/docs. Bug found by the test and fixed: `lazy.compactMap(...).first` ran the side-effecting placement twice (duplicated graphics).
T-924 · 2026-11-17 · `- [~]` pending HUMAN look/feel · verified headlessly: `make test` 297/297; new `--selftest graphics-ui <Bright Forest> <out>` (Add Graphic selects + names the undo step, ⌥K keys at playhead 0.2/1.5 s, undo, Edit ▸ Add Graphic submenu = catalog with the right action, Add Keyframe ⌥K) OK; GraphicPanel rendered offscreen with ImageRenderer and inspected (headings, template summary, params, Detach, Space, keyframe list, Key at playhead/Clear); `mcp-edit --headless` OK · Graphics show on the existing layer lanes (sage, template name, keyframe diamonds when selected, no file thumbnails); `G` pops the template menu at the pointer; Edit ▸ Add Graphic ▸ <template>; Edit ▸ Add Keyframe ⌥K (keys the current transform so nothing jumps); GraphicPanel edits params through `GraphicTemplates.make` (same path as the agent op). Not verified: param TextFields (ImageRenderer can't draw AppKit-backed fields), on-canvas drag of a graphic box (reuses the layer rect handles), live timeline drawing — no windows per the user's instruction. HUMAN: open the app, press G, pick Callout, edit text, ⌥K at two times, drag the box, compare with the prototype.
T-930 · 2026-11-17 · `- [~]` pending HUMAN look · verified headlessly: new `--selftest markers <package>` (works on a temp copy: M adds Marker 1/2 as one undo step each, ⌃→/⌃← jump, M on a marker removes it, undo, Edit ▸ Add / Remove Marker) OK · ruler flags + labels drawn from `items` (same markers timeline.get shows). Rename is by `set {id, text}` (agent) only — no rename UI yet (no modal dialogs); HUMAN: check the flags on the ruler.
T-931 · 2026-11-17 · `- [~]` pending HUMAN feel · verified headlessly: new `--selftest transcript-edit <package> <out>` (temp copy + synthetic mic transcript: cut w3–w4 as one undo step shortens the edit by 0.5 s at 2×, filler ids follow the edit, Remove fillers, undo ×2 restores) OK; TranscriptEditor rendered offscreen and inspected (wrapping words, dotted filler underline, Cut n / Remove n buttons); `make test` OK; `mcp-edit --headless` OK · `EditorModel.apply(ops, name:)` = the human entry to the agent language (D4); TranscriptEditor in AudioPanel: click/⇧-click select, ⌫ or Cut → `cutWords` (snap), Remove fillers. Also: the user's Golden Island pending draft had one `"op":"update"`, rewritten to `"set"` (same fields) so it still replays after the update removal.
T-932 · 2026-11-17 · `- [~]` pending HUMAN gesture feel · verified: `make test` 300/300 (new `RollSlipTests`: roll moves the cut both ways with the length unchanged, refuses at the last clip and across different clocks; slip keeps place and moves media, linked mic audio slips with it, refuses past the recording/before 0; agent `set {id:"c1", mediaStart}` slips, errors name the limit and the field table) · Core `rollEdit(between:toSource:)` composes `trimClip` (shrink, then grow) so audio/layers/settling follow trim rules; `slipClip(_:byMedia:)` refuses when linked audio spans other clips; timeline: ⌥-drag a clip edge = roll, ⌥, / ⌥. = slip selected clip 1 frame (⇧ 10). ⌘-drag slip from the plan replaced by the keyboard nudge (no new drag kind in TimelineView).
T-933 · 2026-11-17 · verified: `make test` 301/301 (new `freezeInsertsAStill`: +1.5 s, later zoom moves with its footage, still layer full-canvas, no uncovered gap, out-of-range refused); new headless `--selftest freeze <package> [out]` (temp copy: ⇧F's command renders the frame into media/, +1.50 s, held frame vs the frozen PNG at 8×8 block means: residual 3.9/255, undo restores, `freeze` op in the schema) OK; `mcp-schema`, `mcp-edit --headless` OK · Plan's `Clip.freeze` in TimeMap replaced by reuse (no TimeMap/composition change): `insertStill` = split → image layer → `insertLayers` into the Video lane → that inserted time becomes a gap covered by a full-canvas image layer of the finished frame (drawn unframed, so zoom/cursor/background are exactly what was on screen). Edit ▸ Freeze Frame ⇧F; MCP `freeze {at, duration}` (the app renders the viewed frame into media/ before applying; files cleaned up on failure/dry run like imported assets). Found, not fixed: image layers render ~6/255 darker than the same pixels through the screen path (uniform colour bias, pre-existing image-layer colour path).
T-934 · 2026-11-17 · verified: `make test` 302/302 (new `seamTransitions`: nearest seam ≤ 0.5 s, dip = 0.3/0.3 fades, dissolve still at the seam half-faded at the midpoint, dissolve without a frame refused); new headless `--selftest transitions <package>` (temp copy: ⌘T renders the outgoing frame into media/ and adds the fading still, undo, Add Dip, no seam → no-op, `transition` in the schema) OK; `freeze` re-run OK; `mcp-schema`, `mcp-edit --headless` OK · Plan's two-frame compositor blend replaced by reuse: dissolve = the outgoing clip's last frame as a full-canvas image layer fading out over the next clip (outgoing motion is held during the dissolve — `shortcut`, fine for screen recordings); dip = existing clip fades; `push` dropped (YAGNI). Edit ▸ Add Dissolve ⌘T / Add Dip; MCP `transition {at, kind, duration}` (app renders the frame). Found by the selftest: image layers have a 0.5 s minimum, so freeze and dissolve now state 0.5 s minimums (Core, schema, messages).
T-935 · 2026-11-17 · verified: `make test` OK; new headless `--selftest speed-ramp <package>` (temp copy: middle clip at 4× its neighbours, Ramp 0.6 s → 2.00 2.75 4.25 5.75 7.25 8.00 … 2.00, one undo step, invariants) OK · ClipPanel shows Ramp 0.3/0.6/1.0 s when the clip's speed differs from 1; `EditorModel.rampSpeed` rebuilds the change from the neighbour's speed to the clip's speed through the agent's own `speed {ramp}` lowering (`lowerIntents`) — one shared path. First attempt ramped from the clip's current speed to itself (all steps 8×); caught by the selftest. Button look not inspected (no windows).
T-936 · 2026-11-17 · `- [~]` pending HUMAN listen · verified: `make test` 304/304 (new `DuckingTests`: speech ranges 4–8 s, ducked music 1.0 → 0.625 at −0.15 s → 0.25 inside → 1.0, duck round-trips; gain point at 10 s lands in the ramps media-keyed, out-of-clip/over-range refused); `--selftest audio-mix`, `audio-lanes` OK (mix path now goes through `duckedVolumeRamps`); `mcp-schema`, `mcp-edit --headless` OK · `AudioTrack.duck`; Core `speechRanges`, `duckedVolumeRamps` (FrameSource uses it), `setGainPoint` (freezes fades into media-keyed points; found by the test: clearing fades resets the envelope, so it is cleared first); AudioPanel: Duck under speech, Level at playhead + Set, n points + Clear; MCP `set {id:<audio>, duck}`. Not done: dragging envelope points on the timeline (points are set at the playhead), timeline envelope drawing does not show ducking.
T-937 · 2026-11-17 · verified: new headless `--selftest export-in-out <package>` (temp copy: In 2.0 / Out 4.5 through the model → a real 2.50 s MP4 via `Exporter(outputRange:)`; setting the full range clears it) OK; existing `export-range` (export-duration rules) still OK; `mcp-schema`, `mcp-edit --headless`, `make test` OK · Reuse: `Exporter` already took `outputRange` (built for proxy clips) — wired to `EditorModel.exportRange` (I / O / ⌥X, per session), a white band on the ruler, the export sheet (Range row + Whole video, duration/size from the range; GIF stays whole), and MCP `export.final {from,to}` (rejected with srt). Found while testing: a duplicate selftest key traps the whole case table, so the new case is `export-in-out`.
T-940 · 2026-11-17 · verified: `make test` 305/305 (new `GoldenIslandTests.reelWithTitleCardAndCallouts`: the eval brief "30 s reel with a title card and two callouts" as the agent's ops on the real layout — fitDuration, gap cut if linted, titleCard + two screen-space callouts on the strongest payoff shots with keyed pop-in, a dip at a seam → 30 ± 2.5 s, three graphic blocks in timeline.get, no background-only canvas, every lint suggestion applicable); `make mcp-smoke` OK · EDITING-CORE §5 parity table at its final state, SPEC §10 note, MCP.md updated per task. Not run: a live Claude session through the eval harness (it opens editor windows; the user asked for none) — run `scripts/score` after a real session.
T-924/T-930/T-932 follow-up · 2026-11-17 · verified headlessly: new `--selftest timeline-gestures <package>` drives the real TimelineView event handlers with synthesized events on a windowless view (⌘-drag clip body = slip −1.00 s media with place/length kept, one `Slip Clip` step; ⌥-drag a cut = roll to 6.00 s with length kept; M marker; I/O range; double-click a ruler flag = rename to "Intro", one `Rename Marker` step) OK; new `--selftest timeline-v2-png <package> <out>` renders the real timeline with `cacheDisplay` (no window) — marker flags, In/Out band, sage graphic block with template name and keyframe diamonds inspected; `make test` 305/305 · Added: ⌘-drag slip (plan's gesture, replacing the keyboard-only shortcut), double-click flag rename (NSPopover field). Still `- [~]`: HUMAN look/feel in the running app for T-924, T-930, T-931, T-932, T-936.
HUMAN waiver · 2026-11-17 · The user waived the in-app HUMAN look/feel checks for T-924, T-930, T-931, T-932, T-936 (answered "Waive, tick them"), accepting the headless evidence: event-driven `timeline-gestures`, offscreen `timeline-v2-png`/`graphics-ui`/`transcript-edit` renders, `graphics-png`, `freeze`, `transitions`, `audio-mix`. No human-performed comparison is claimed.
Parity fix · 2026-11-17 · verified: `--selftest parity` maxDelta 0 on the untouched Bright Forest copy (was 4) and on the T-923 graphics fixture (19 times, was 3) · Root cause in the parity selftest, not the renderer: sample times like 1.286 s were compared at the exact time on the export path but seeked at 1/600 s CMTime (1.28667) on the preview path; with a variable-rate recording a frame inside that window was picked by one path only. Times are now quantized to the preview's 1/600 s clock before both paths (exports already run on n/fps, exact in that clock).
Windowed + live verification (Mac mini, user's choice to keep the laptop free) · 2026-11-17 · on `olegs-mac-mini` (macOS 27.0.1) with this tree: `make test` 305/305; `make-m6-fixture` then `--selftest mcp-roundtrip`, `mcp-edit`, `mcp-review`, `mcp-live` on copies of /tmp/M6Fixture.recorder all OK (mcp-edit's hard-coded op-schema count updated 18 → 22: −update, +set graphic animate freeze transition; earlier failures on Bright Forest/Gentle Moon were fixture assumptions — 2× speed halves the synthetic 2 s pause, existing zooms overlap the test's zoom, the tests expect the 3 s M6 fixture). Live eval: a real JSON-RPC session (`scratchpad eval_reel_graphics.py`) against this build's MCP server on a private socket (`--selftest mcp-serve`, because another Recorder owned the default socket on the mini), Golden Island copy: templates listed, 66 shots, fitDuration → 29.46 s, applied lint's `uncovered` cut, titleCard + two screen callouts with keyed pop-in, dissolve at 6.53 s → 28.90 s, 3 graphic blocks, frames + lint rendered, draft discarded; `scripts/agent-eval.py`: 15 calls, 6 ops, 3 images, 28.9 s (lint warnings left: edgeContent ×4 from the 16:9 crop, tinyShot ×1). Freeze-frame parity (T-933): `--selftest freeze <pkg> <out>` keeps a frozen copy; `parity` on it maxDelta 0 over 10 times. Fixed: dissolve frames were named `freeze-*` in media/.
Free-running Claude eval (T-940) · 2026-11-17 · on the Mac mini, `claude -p` (Claude Code 2.1.326) given only the brief ("~30 s social reel, fast cuts, title card, two callouts; verify with renders and render.lint reel; fix every warning; submit, don't export") and the Recorder MCP tools, through a logging stdio↔socket relay to this build's server (`--selftest mcp-serve`): it chose pace + fitDuration, cut the uncovered tail gap and two flicker slivers, reframed per shot, added a title card and two callouts (re-placed one after a render), submitted. Final 29.13 s, final `render.lint` reel: no warnings. `scripts/agent-eval.py docs/evals/golden-island-reel-graphics.jsonl`: 23 calls, 11 ops, 45 images, 29.1 s. Transcript kept in docs/evals/ (no key events in it). `mcp-edit`'s schema check is now the planned op-name set (22 names: primitives, set, graphic/animate/freeze/transition, intents; no update) instead of a count — passes.

T-950 · 2026-11-18 · verified: `make app APP=build/agent-recording/Recorder.app` (release, Developer ID signed, separate bundle to leave the running source app intact); that binary's `--selftest record-agent` OK (real 400×300 display-area capture, 1.517 s, silent settings, title + three pause-aware markers saved, second owner refused, saved mic/countdown unchanged, test package trashed), `menus`, `menu-actions` OK; `make test` 305/305. Debug capture/menu checks also passed. Shared capture and throwing finish path, agent ownership/title/markers, token-checked wall-time cap and restart settings; stream failure now finishes through the controller rather than only logging. Area frames now include their display's global offset. Excluded Finder apps no longer get desktop windows re-included through the hide-desktop exceptions. Agent-owned widget/timer finishes suppress error alerts (R9); human errors still alert and failed-finish packages stay recoverable. Selftest measures its first second from the recording clock (SCK's first frame may precede startCapture's return). Duration-cap timing is T-951's `record-agent-cap` check; the MCP tool and the remaining proposal tasks are not implemented yet.

T-951 · 2026-11-18 · verified: Developer ID signed release `make app APP=build/agent-recording/Recorder.app`; `mcp-record` (real captures, target/shape/range validation, once-per-session approval, deny/timeout/opt-in, ownership, paused markers, marker-anchored cut dry run, idempotent stop, discard with a closed previous editor, human Finish, disconnect during approval/start/recording), `record-agent-cap` (10 s wall cap saves a paused take), `mcp-schema` (34 actions / 10 tools), `mcp-export`, `mcp-roundtrip /tmp/M6Fixture.recorder` all OK. `make test` 305/305 including extended shared schema checks for maxLength and nested area validation. Native `mcp-record --native` also passed on the final release: actual timeout, Don't Allow, responsive status, disconnect cancellation, actual Allow starts a silent take, then discard removes it; own-window `/tmp/recorder-t951-consent.png` inspected, as was `settings-png /tmp/recorder-t951-settings.png agents`. Fixed the guide's synchronous NSAlert.runModal hang: real private-socket ping timed out during consent; yielding AppKit modal sessions now allow cancellation and ping succeeds after disconnect. EOF safety hook runs before draining replies; capture generation guards prevent stale startup cleanup affecting another take. User explicitly waived the remaining HUMAN visual check ("Waive the visual check"); no human-performed interaction is claimed. Task docs updated to the verified native approach. Not run: mcp-smoke (its nine-tool expectation and docs/scripts are T-952); no live TextEdit eval yet. User requested checkpoint, commit/push, and pause for resuming on the MacBook Air.

T-952 · 2026-11-18 · MacBook Air, macOS 27.2: `make mcp-smoke` passed against the new Developer ID signed release with all ten tools. `bash -n scripts/mcp-record-demo.sh` passed, and a stub shim verified the target, area, marker sequence and printed project ID. The real Recorder initialize relay check produced exactly two byte-identical lines, and a stub checked append, file permissions and child shutdown. `make test` passed 305 tests in 18 suites. The native consent visual check was waived in T-951, and the live demo and OS re-consent observations remain in T-953.

T-953 preflight · 2026-11-18 · Mac mini (macOS 27.0.1): staged the signed build, verified its signature and Recorder's Screen Recording and Accessibility grants, and verified ten tools and idle capture on a private socket. In the staged interactive Claude Code 2.1.327 session, the built-in computer-use server is disabled. The relay connects to the older nine-tool app on the standard socket. Awaiting human setup and approval for the TextEdit run.

T-953 scoring preflight · 2026-11-18 · Fixed the scorer to read `structuredContent.report.lint` and keep dry-run lint and duration out of the final metrics. The saved T-940 transcript now reports PASS with its existing 23 calls, 11 ops, 45 images and 29.1 s. Scorer selftest passed on the Air and on the staged Mac mini copy. `make test` passed 305 tests in 18 suites. The live TextEdit eval remains pending.

T-953 local setup · 2026-11-18 · User moved the eval to the MacBook Air (macOS 27.2). Installed the Developer ID signed build at `/Applications/Recorder.app` after normally quitting the idle source build. The same signer retained both Recorder grants. The installed shim returned all ten tools and idle capture. `--selftest mcp-record` passed with real capture and injected consent. The extra native-consent selftest did not pass locally, so native capture approval is still to be checked in the interactive run. Claude Code sees the installed server and the user enabled computer use. Restarted only the staged Claude session with `--dangerously-skip-permissions` at the user's request.

T-953 · 2026-11-18 · Live interactive Claude Code 2.1.327 + built-in computer use on the MacBook Air, macOS 27.2. After approval for TextEdit and the installed Recorder's native prompt, Claude selected a bounded display area to include the Open panel, captured a 38.25 s silent take with five markers, created a document and typed a bold 36 pt heading. The raw timeline had six auto-zooms. Two raw filmstrips show cursor movement around clicks with long gaps and drift between samples. Local event counts show 18 move/drag samples over the take and an 8.16 s gap, supporting the user's report of visibly broken motion. The submitted draft reduces the take to 16.3 s, has four step titles and nine manual cuts across four steps, and replaces the six auto-zooms with one fixed zoom. The trial of `pace` removed whole steps and Claude undid it. The nine retained cuts meet T-956's threshold. `render.lint demo` returned no warnings or errors and one duration info item. `scripts/ui.sh screenshot` showed the Claude tab in Ready for review with 20 changes. `scripts/agent-eval.py docs/evals/textedit-silent-demo.jsonl`: 27 calls, 35 ops including reverted work, 35 images, PASS, 16.3 s. The public transcript preserves metrics with image bytes and unrelated window metadata removed. The original transcript and screenshots stay local. No export was requested or performed. Separate macOS re-consent was unconfirmed, so SPEC §9 records the observation without inferring a periodic policy.

T-954 · 2026-11-18 · `make test FILTER=EventsAgentPointer` passed three tests, and `make test` passed 309 tests in 19 suites. The signed debug bundle passed `mcp-record` and `mcp-schema`. The real area-capture selftest declared a click without posting a mouse event, found the normalized down in the local package and found an auto-zoom. `pointerAction` distinguishes the pointer event from the MCP dispatch field `action:"mark"`. Existing captures also benefit from bounded cursor interpolation. In new filmstrips of the original TextEdit take, the cursor stays on Bold through the 24–25.3 s idle segment, where the original strip showed it sliding across the toolbar. No change to the saved draft or its source events was needed.
