# Recorder recording-layers handoff — 2026-11-15

**Paused at the user's request.** This file is a handoff for any coding agent, independent of Codex chat history,
goal tools, or subagents. Resume implementation only when requested. Read this file, `AGENTS.md`, and `docs/PLAN.md`.

## Goal and user decisions

Implement the magnetic/free timeline prototype completely:
https://artifacts.microapps.space/a/s3ft3gkc1k51 . Its implementation roadmap is PLAN T-701 through T-723.
The broader repository has other unfinished milestones; keep this work scoped to that roadmap.

- User approved horizontal dragging/copy/Escape feel: “Feel is right.”
- New images must fill the preview canvas, not appear as a small overlay. The shared importer now defaults images
  to `NormRect()`. Existing placements and video-import Card placement are retained.
- User explicitly waived further human reviews: “pls im gonna sleep dont need human review just keep going as u feel”.
  Use actual automated checks and agent visual judgment. This does **not** turn missing performance measurements
  into passes or authorize waking/unlocking the Mac.
- User subsequently paused the goal and requested this saved handoff. Do not automatically continue now.

## Checkpoint and working tree

Repository: `/Users/snowbear/projects/recorder`, branch `dev`.

Last completed task commit: `3661ce7 T-712 Lift recording clips with independent scenes and audio`.
The next checkpoint is deliberately titled **WIP T-713**. It saves unfinished renderer code and diagnostics;
it is not a verified task completion. Find it with `git log --oneline --grep='WIP T-713'`.

The following pre-existing changes are unrelated and were excluded from our commits:
`CLAUDE.md`, `Makefile`, `pack.lock`. Preserve them. Do not reset/clean the worktree to resume.

No agent-owned compiler or test process was running when this handoff was saved. The user's app windows and
project packages were left intact. No installation, permission reset, release, push, or deployment was performed.

## Completed versus outstanding

Phase 1 is complete: PLAN T-701, T-701b, T-702, T-702b, T-703, T-704, T-705, T-705b, T-705c.
Recent commits:

| Commit | Result |
| --- | --- |
| `3fffeda` | Permanent New track strip, Video ordering/Magnet switch, full-canvas image defaults |
| `95e3ab7` | Native document controls realign after macOS constrains window height |
| `45b4bbc` | Correct reversed bands in the image-orientation test fixture; renderer unchanged |
| `cb0250b` | Real dual-screen performance benchmark, measurements still pending |
| `3661ce7` | Recording-layer Core operations and conditional v4 format; 160 Core tests passed |

T-711 remains `[~]`. This host is native Apple M1 / MacBookAir10,1. Actual GUI visibility checks found a locked
console (`CGSSessionScreenIsLocked=1`); no live playback FPS or dual-screen export timing was obtained. Intel is
also unmeasured. The benchmark refuses occluded-window results before generating another expensive fixture.

**Resume at T-713, the first unchecked roadmap task.** Then T-714, T-721, T-722, T-723 in order. Do not mark the goal
complete while those tasks or required measurements remain outstanding.

## T-712 behavior to preserve

`LayerBlock.Kind.recording`, `mediaRate`, and `scene` carry screen footage, local zooms/masks/window shots,
cursor visibility, fades/color, and screen-linked audio. `liftClips`/`insertLayers` reuse shared slicing, clock,
paste, collision and audio-envelope operations. Copies receive independent IDs and sound settings survive
collision routing, though audio lane placement can change.

`RecordingCameraContext` snapshots original clips/effects/window choices **before clock normalization**. Keep it
immutable on trim. Current media time maps through the selected original clip, including repeated footage;
never select the first clip with matching media. Context contains no recorded events.

Retained effect IDs permit rejoining unchanged lift fragments without erasing a later neighbor split.
`scene.padding` identifies only lift-created independent-lane tail padding; copies clear padding and neighbor
ownership. Camera/key/layout/text lanes and camera-linked audio retain absolute output positions across lift/insert.
Recording minimum length is 0.1 **media** seconds, so fast clips may be shorter in output time.

Maximum supported format is 4, but new/versionless models retain version-3 metadata. Atomic `Project.save` writes
4 only when a recording layer exists, otherwise 3. Loading checks the version header before feature enums.
T-722 must extend the v4 predicate when `Clip.file` is implemented.

## T-713 WIP implementation

Production changes are in:

- `Sources/RecorderCore/TimelineOps.swift`: `Project.recordingScene(for:)` builds effective original-clock history;
  returns `(project, clip, sourceStart, sourceRate)`. Restores unchanged boundary-spanning zoom/mask history.
- `Sources/RecorderCore/TimeMap.swift`: symmetric `Clip.sourceTime(atMedia:)` inverse.
- `Sources/Recorder/Editor/EditorModel.swift`: cached recording camera/cursor paths. Cache excludes cosmetic
  placement changes; sample clocks update from current media during trim without resimulating paths each frame.
- `Sources/Recorder/Render/FrameSource.swift`: recording assets/windows/rates into existing layer tracks.
- `Sources/Recorder/Render/FrameState.swift`: recording view/previous view/cursor/mask/source-time payloads.
- `Sources/Recorder/Render/Compositor.swift`: recording layers reuse `drawScreenContent`, preserving main frame
  geometry, crop, padding, shadow, screen → cursor → masks order, multi-window sizing and outer camera/layout alpha.
- `Sources/Recorder/Editor/PreviewView.swift`: recording decoder filters, scene/window rebuild checks, readiness
  for gaps/tails without requiring nonexistent main video.
- `Sources/Recorder/Render/Exporter.swift`: recording parity lanes and transition-time coverage.
- `Sources/Recorder/App/SelfTest.swift`: registers `lift-identity` and `layer-recording-parity`.

New tests: `Tests/RecorderCoreTests/SceneEffectsTests.swift` and
`Sources/Recorder/Render/RecordingLayerSelfTest.swift`.

Important sampling equation: original-clock rate is
`layer.mediaRate * originalClip.timeScale / originalClip.speed`. Previous view samples that rate divided by 60
earlier. Canonical speed=2/clock=1 and legacy speed=2/clock=2 must both work. A sliced zoom cannot simply restart
at local zero: preserve spring/dead-zone history and original mask fade bounds.

## Exact verification state and immediate next step

1. Last full Core run: **162/162 passed**, including real CameraPath/Mask-strength history regressions.
2. Native build passed before the last temporary PTS instrumentation. A later diagnostic build was interrupted;
   rebuild the saved source before trusting the existing binary.
3. `--selftest lift-identity`: **49 before/after samples passed at maxDelta=0**. Cases include legacy/canonical
   clocks, frame enabled/disabled, spring and instant-auto zooms, mask fades, sole/tail/backward seeks and repeated
   media with a multi-window switch. These compare actual AVAssetReader/export-compositor renders before/after.
4. `--selftest layer-recording-parity`: **FAILED**, first case `mixed-rate-0-t4.0167`, **maxDelta=127**.
   This compares the actual PreviewView drawable with the export decode/render path. Geometry appears aligned;
   many channels differ by about 3–5 levels and a tile edge differs much more. Frame selection/color decode is a
   hypothesis, not a proven cause. Diagnose actual returned AVPlayer display PTS against FrameHold/reader PTS at
   the same composition output time, especially the 2× segment. Keep the strict zero-delta assertion.

Temporary **unconditional `RECORDPTS` prints** are intentionally saved in
`PreviewView.currentLayerTextures` and `FrameHold.imageBuffer(upTo:)` in Exporter.swift. They were the last
diagnostic edits. Remove or gate them after fixing parity; do not ship per-frame logging.

Native parity uses square output to avoid an existing fractional preview-letterbox/aspect-rounding discrepancy;
native-aspect lift identity is checked separately. Copy-over-original shadows can legitimately overdraw: use
independent scene sampling and preview/export parity for copies, not whole-frame equality with the single source.

After fixing parity, run both required native cases, the Core suite, and affected existing layer checks. Inspect
proof images. Only then tick T-713, update PLAN counts/log, and commit its verified completion.

## Commands (ordinary shell; no Codex-specific tools)

This machine now has Xcode/SDK 27.2; the older CLT-only notes in AGENTS.md describe the original machine.
Default SwiftPM swiftbuild cannot load the Testing macros here. Use the verified native engine and framework flags:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make test TESTFLAGS='--build-system native -Xswiftc -F -Xswiftc /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks -Xlinker -F -Xlinker /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks -Xlinker -rpath -Xlinker /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks -Xlinker -rpath -Xlinker /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib'
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --build-system native
make -o build app CONFIG=debug
build/Recorder.app/Contents/MacOS/Recorder --selftest lift-identity
build/Recorder.app/Contents/MacOS/Recorder --selftest layer-recording-parity
```

Add `FILTER=sceneEffects` or `FILTER=lift` to the **make test** command for focused Core runs. Use `make test`, not
bare `swift test`. Do not modify Swift files while SwiftPM is compiling. `make -o build app` assembles the already
verified native debug binary without invoking the failing default engine. Do not install/reset TCC casually.

Existing useful native checks: `make-layers-fixture`, `media-import`, `layer-rect`, `timeline-tracks`,
`timeline-full-layers`, `timeline-png`, `timeline-selection`, `timeline-reorder`, `timeline-ops`, `menu-actions`.
Ordinary paused GPU captures can run while locked; true presented-frame performance cannot.

## Durable evidence

Logs and representative passing/failing PNG pairs are committed under
[`handoff/2026-11-15-recording-layers/`](handoff/2026-11-15-recording-layers/).
The tests regenerate their synthetic media, so resuming does not depend on temporary fixture directories.

Original local proof directories (may disappear):

- `/var/folders/km/z2_l_55s52dd6vwhkkqj5m000000gn/T/recorder-lift-identity-122EBB61-3379-4B3A-8B60-4F6649DCFA6A.recorder`
- `/var/folders/km/z2_l_55s52dd6vwhkkqj5m000000gn/T/recorder-layer-recording-parity-2267D73E-F937-4F61-864C-063BF0D951E6.recorder`

The corrected user review copy is `/tmp/Recorder-T705-Full-Canvas-Review.recorder`; it preserved the user's track
and timing changes while making the agent-created image rectangles full canvas. Do not overwrite the original
review package or user edits. Reference image boards under `reference/ui-kit-inspiration/` are absent in this
checkout; use existing `docs/UI-KIT.md`, shared Theme controls and the repository UI skill for subsequent UI work.
