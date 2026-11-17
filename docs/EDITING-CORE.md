# Editing core v2: one model for the human editor and Claude

Requested 2026-11-17: "research the industry, build a robust video-editing core that a human can edit, keep every
screen-recording capability, give it an MCP interface, consistent architecture, add the missing features, so I can
record and Claude can edit and add motion graphics." Input: MCP usage feedback run 6
(https://artifacts.microapps.space/a/6h4p6rzd4tdr). Prototype of the human editor with the new features:
https://artifacts.microapps.space/a/2a8nw5c559k4 (source `docs/prototypes/editor-v2.html`, §7). Tasks: PLAN.md "Editing core v2" (T-901…T-940).

This document is normative for those tasks, in the same way MCP.md and AUDIO-LAYERS.md are for theirs.

## 1. What we learned from the industry (short)

| Source | Lesson we take | Lesson we reject |
|---|---|---|
| OpenTimelineIO | Keep "media that exists" (available range) and "media used" (source range) as separate fields. Validate one against the other, and don't assume containment. | Effect lists with no invariants, and a time warp that changes speed without changing duration. OTIO is an exchange format, not an engine. |
| Final Cut Pro X | A gapless **spine** plus **connected** items anchored to the spine. Ripple is the default, so collisions can't happen. Assets are declared once and referenced. | Nested storylines, compound clips, auditions. A draft covers what auditions do. |
| Premiere / Resolve | Exact definitions for ripple/roll/slip/slide trims. Keyframes are `(t, value, interpolation)` in clip-local time. | Hundreds of GUI verbs as API. Resolve MCP servers ship 26–369 tools. |
| Descript / Underlord | The transcript is the spine: deleting a word cuts the media under it. Each agent turn is one Revert step. | Layers that drift when the script changes. Our anchors must not do that (§3.2). |
| Cap (open source screen-recorder) | Flat typed segment lists (zoom/scene/mask/text/caption/keyboard/style), keyframed masks, text in/out presets, `Transition / Hold` frame mapping. | Transitions that address clips by index. Double seconds compared for equality. |
| Lottie / Remotion | Every visual property is either constant or keyframes `{t, v, ease}`. Values are pure functions of time, so any frame can be rendered without playing from the start. | Code-as-video (JSX, generators). An agent can't validate it, and Motion Canvas depends on playback history. |
| Shotstack / Creatomate | Declarative JSON, named animation presets plus raw keyframes as an escape hatch, tracks as z-order. | Stateless whole-document re-renders with no revisions or drafts. |

Ten rules for an API an LLM uses (we already follow 1, 3, 4 and 8; this plan closes 2, 5, 6, 7, 9 and 10):
stable ids; a few batched semantic ops; `ifRevision`; draft = one undo step; end-state ops plus `dryRun`;
strict validation with machine-fixable errors; one time domain plus semantic anchors; perception that matches
the edit surface; presets plus an escape hatch; determinism, invariants, property tests and golden runs.

## 2. Where we stand (audit 2026-11-17)

What already matches the industry model:
- `clips` + `TimeMap` is the spine. `layers` and unlinked audio are **connected** items (FCPX). Effects
  (zooms, masks, texts, layouts) live in spine time, so cuts never rewrite them.
- `Project -> Project` ops in `TimelineOps` check invariants. Undo is a whole-`Project` snapshot.
- `FrameState` is a pure function of output time, built from 240 Hz tables, and one compositor renders both
  preview and export.
- On the MCP side: one `edit.apply([EditOp])`, revisions, drafts, render/lint perception, and Golden Island
  regression runs.

What breaks, and why (root causes, not symptoms):

| Symptom (feedback run 6 and earlier) | Root cause |
|---|---|
| Durations disagree. Layers are invisible to shots, sections and lint. `assets.layers` is empty. | No single item view. Each tool walks `clips` and some of the 12 other arrays its own way. |
| A layer can't be trimmed, sped up or cut. | `update` has a hand-written field list for each lane. Layers only got `from`/`to`. |
| The tail gap can't be cut and flashes the background. | `cut` only removes footage. A gap with nothing over it is legal, and nothing warns about it. |
| `{shot}` anchors fail after a `speed` op in the same batch. | `useOutputClock` rewrites the spine's clock. Shot times are base-clock seconds, then mapped through the *new* clock. |
| `render.sheet` ignores `from`/`to`. Reframe is opaque. The stale message is confusing. | Tool polish. |

Missing for a human, per the feature audit: graphics/motion graphics, generic keyframes (only `cropKeys`
exists), markers UI, editable transcript (it is read-only), filler removal UI, roll/slip trims, freeze
frame, transitions between clips, a speed-ramp UI, ducking and an editable gain envelope, export range (I/O).
Human gestures and MCP share the `TimelineOps` primitives but not the op layer. That is fine for drags.
Discrete commands added from now on use `EditOp` (§3.4).

## 3. Architecture decisions (closed)

**D1. Evolve the arrays, no compatibility layers.** `project.json` keeps its per-kind arrays (no new targets, layers or
managers). Per the user (2026-11-17), there is no backward compatibility: one format version (7) is always written,
`set` is the only patch op (`update` removed), and no aliases or per-feature version gates exist. Loading keeps
field defaults so existing projects still open; that is data-loss protection, not compatibility.

**D2. Three clocks, named.**
- **Output** time: the timeline x-axis and every MCP number.
- **Spine** time: the editing clock of `clips` (today's "source"). Effects are stored in it. `useOutputClock`
  may rewrite it, together with everything stored in it.
- **Media** time: seconds into a file. It never changes.

Anything computed *outside* the project (storyboard shots, transcript words, events, silence) is keyed by media
time. It is mapped to spine time through the clips of the project being edited at that moment, never cached
spine seconds (fixes the anchor bug, T-902).

**D3. One item view.** `Items.swift`: `items(project) -> [Item]`. One `Item` per timed thing:

```swift
public struct Item: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case clip, gap, zoom, layout, camera, keys, mask, text, window, layer, audio, graphic, marker }
    public enum Anchor: String, Codable, Sendable { case spine, connected, output }   // follows cuts | starts on spine, own duration | fixed
    public var id: String, kind: Kind, lane: String, track: Int
    public var out: TimeRange                 // output seconds (what the viewer sees), clamped to the visible part
    public var spine: TimeRange?              // stored range for spine-anchored items
    public var media: MediaRange?             // {file, start, end, rate, available}: used vs available, OTIO-style
    public var anchor: Anchor
    public var editable: [String]             // fields `set` accepts for this item, from one table
    public var label: String
}
```

`agentTimeline`, `project.assets`, `exportDuration` and the lint coverage pass are all derived from it. Shots
from layers are reported as `kind:"layer"` coverage so sections and lint see them. `Project.exportDuration` is
the one duration that every tool reports.

**D4. One mutation language.** `EditOp` stays the agent's language. `set {id, …fields}` replaces the
per-lane `update`, which stays as an alias. Validation comes from the item's `editable` list, and an unknown
field is rejected with an error that lists the valid ones. Every new capability is built as:
**TimelineOps primitive → EditOp → human command → selftest**. New discrete human commands (graphics, transcript
deletes, markers, freeze, transitions) call `EditorModel.apply([EditOp])`, which is `edit(name) { try $0 = $0.applying(ops) }`.
Drags keep calling primitives inside a gesture. The capability table (§5) is kept in this file.

**D5. Keyframes, Lottie-lite.** One pure type is used by every animatable thing:

```swift
public struct Key: Codable, Equatable, Sendable {
    public enum Ease: String, Codable, Sendable { case linear, hold, easeIn, easeOut, easeInOut, spring }
    public var t: Double                      // item-local output seconds
    public var x, y, scale, rotation, opacity: Double?   // nil = not keyed at this key
    public var ease: Ease = .easeInOut
}
public struct Transform: Equatable, Sendable { public var x, y, scale, rotation, opacity: Double }
public func evaluate(_ keys: [Key], base: Transform, at t: Double) -> Transform   // per property, between neighbours that set it
```

`keys: [Key]?` goes on `LayerBlock`, `TextBlock` and `Graphic`. The existing `motion`/`fadeIn`/`fadeOut` presets
stay. When keys exist they replace the entrance motion, and fades still multiply opacity. `spring` reuses
`Spring` presets. Positions are normalised 0–1 (top-left origin), the same coordinates zoom `center` and text
`position` already use.

**D6. Graphics = elements plus optional template.** `Project.graphics: [Graphic]` are connected items like
layers (start on the spine clock, duration in output seconds), on `track` lanes (higher is in front).

```swift
public struct Graphic: Codable, Equatable, Sendable {
    public enum Space: String, Codable, Sendable { case canvas, screen }   // screen: follows zoom/crop, pinned to recorded pixels
    public var id: String, start: Double, end: Double, track: Int, space: Space
    public var template: GraphicTemplate?     // {name, params}; elements are regenerated when params change
    public var elements: [GraphicElement]     // what the compositor draws
    public var keys: [Key]?                   // whole-graphic transform
    public var enter: String?, exit: String?  // preset names: fade, pop, slide, wipe, typewriter (text only)
    public var color: BlockColor?
}
public struct GraphicElement: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case rect, ellipse, line, arrow, text, image }
    public var kind: Kind, frame: NormRect, fill: String?, stroke: String?, width: Double?, radius: Double?
    public var text: String?, size: Double?, weight: String?, align: String?, file: String?
    public var keys: [Key]?
}
```

Templates are pure Core functions `(params) -> [GraphicElement]` (`titleCard`, `callout` (arrow plus label at
a screen point), `stepBadge`, `spotlight`, `progressBar`, `counter`). They work the same way intent ops lower to
primitives. The human picks a template, and the inspector edits its params. "Detach" drops `template` and
exposes the elements. An agent can send a template (short and valid) or raw elements (the escape hatch).
`space: screen` is the screen-recorder twist: a callout on a button stays on the button through zooms and
reframes. It is mapped through the same `ZoomTargetMapping` the cursor uses. The compositor draws graphics with
CoreGraphics into a cached texture per (graphic, frame), so preview and export stay pixel-identical (AC-ED-2).

**D7. Time stays `Double` seconds.** Every op quantises output boundaries it creates to 1/240 s (the LUT rate).
`// ponytail: Double seconds, quantised; switch to Int64 ticks only if a frame-accuracy bug survives quantisation.`
Rational time would touch every file for no failure we have seen.

**D8. Robustness is tested, not promised.**
- `checkInvariants` covers every array: no overlap per (kind, track), ranges inside media, keys sorted and
  inside the item, graphic elements valid, references resolve.
- `KernelFuzzTests`: a seeded generator runs 500 random `EditOp` batches over 4 fixtures. After each batch:
  invariants hold, Codable round-trips, `items` lie within `0…exportDuration`, applying the same ops twice gives
  the same revision, and a failed batch leaves the project unchanged.
- Golden-frame parity selftests are extended to graphics and keyframes. Golden Island agent regressions stay in
  `make test`.

## 4. MCP v2 (additive; schemaVersion bump; `notifications/tools/list_changed`)

| Change | Tool / op |
|---|---|
| Every item (layers, audio, graphics) with `anchor`, `media` and `editable` | `timeline.get` (built from `items`) |
| One duration: `exportDuration` | `project.list`, `project.info`, `analyze.shots.duration`, sheets |
| Layers as coverage in shots, sections and lint. `assets.layers` filled in, with `mediaStart` and `mediaRate`. | `analyze.shots`, `project.assets`, report |
| Generic `set {id, …}` (layer `to`/`mediaStart`/`mediaRate`; any `editable` field). `update` stays as an alias. | `edit.apply` |
| `cut` over a gap removes it (ripple). Lint rule `uncovered` (no clip or layer covers the canvas) with a suggested `cut`. | `edit.apply`, lint |
| Anchors map through media time (shot anchors survive earlier `speed` ops) | `edit.apply` |
| `graphic {from,to, template:{name,params} \| elements:[…], space, track, enter, exit}` | `edit.apply` |
| `animate {id, keys:[Key]}` (replace), `keys:[]` clears | `edit.apply` |
| `freeze {at, duration}`, `transition {at, kind, duration}` (clip boundary) | `edit.apply` (Phase D) |
| `project.templates` → `[{name, params schema, example}]` | `project` |
| `render.sheet` honours `from`/`to`. `reframe` returns `{keysBefore, keysAfter, changed, shots}` and accepts `focus:{shotId:{x,y}}`. | `render`, `edit.apply` |
| `STALE_REVISION: you passed X; the current draft revision is Y (base Z)` | errors |

## 5. Capability parity (human ↔ Claude)

Each row must have all three columns before its task is ticked. "—" marks a column that is still missing and
names the task that fills it.

| Capability | Core primitive | Human | MCP op |
|---|---|---|---|
| Cut / split / remove | `split`, `deleteClips` | C, ⌫ | `cut`, `cutPauses`, `cutWords` |
| Speed / ramp | `setSpeed` | inspector; ramp — T-935 | `speed {ramp}` |
| Zoom (auto/manual/follow) | `addZoom` | Z, inspector | `zoom`, `autoZoom` |
| Text styles | `addText` | T, TextPanel | `text` |
| Mask / highlight / blur | `addMask` | inspector | `highlight`; blur — T-912 via `set` kind |
| Layers (image/video/recording) | `addLayer` | import, LayerPanel | `layer`, `set` trim — T-903 |
| Keyframes | `Key`/`evaluate` — T-920 | diamonds, ⌥K — T-924 | `animate` — T-925 |
| Graphics / templates | `Graphic` — T-921/922 | G, GraphicPanel — T-924 | `graphic` — T-925 |
| Markers | `markers` | M, ruler flags — T-930 | `marker` |
| Transcript cut / fillers | `cutWords` lowering | transcript panel — T-931 | `cutWords` |
| Roll / slip | T-932 | ⌥/⌘ drag — T-932 | `set` (`mediaStart`) — T-932 |
| Freeze frame | T-933 | ⇧F — T-933 | `freeze` — T-933 |
| Transitions | T-934 | right-click seam — T-934 | `transition` — T-934 |
| Ducking / envelope | T-936 | AudioPanel — T-936 | `style` patch / `set` — T-936 |
| Export range | T-937 | I / O — T-937 | `export.final {from,to}` — T-937 |
| Reframe / aspect | `reframe` | aspect menu | `reframe {focus}` — T-905 |

## 6. Out of scope (named so nobody builds them)

Nested/compound clips, multiple primary recordings with cursor events, reverse playback of clips, ProRes,
a proxy-quality toggle, a full-blown 3D camera, Rive-style state machines, LUTs/colour grading, a music
library and AI voices.

## 7. Prototype

`docs/prototypes/editor-v2.html` (published as an artifact; the link is in PLAN.md) is a browser mock of the
editor using the Signal UI tokens from `Theme.swift`. It covers:
- the Graphics lane, the template gallery, the GraphicPanel and keyframe diamonds
- on-canvas move of a `space: screen` callout that follows a zoom
- the transcript panel with word deletion and filler removal
- markers, roll/slip cursors, a freeze block and a seam transition
- the Claude review panel listing `graphic`/`animate`/`set` ops

It is a visual and interaction target only. It is not editor integration, and HUMAN steps still judge the
native build.
