# Recorder MCP — agent editing (implementation guide)

Status: implemented and verified 2026-11-16 · tasks **T-801…T-810** in `docs/PLAN.md` · prototype: https://artifacts.microapps.space/a/0shbfprqwqz2

This document is written for an implementing agent (any model). It says **what** to build, **where**, **with which
existing code**, and **how to prove it works**. Read §0–§3 once, then do the tasks in §6 strictly in order, one per
session, following `docs/PLAN.md` §0 Protocol. Code-block signatures are **normative** (names, parameters, types);
bodies are yours. If something here contradicts the code, the code wins: write `BLOCKED:` under the task and ask.

---

## 0. Goal in one paragraph

An MCP client (Claude Code, Codex, …) can open a Recorder project, read its timeline and transcript, find pauses and
filler words, propose edits (cuts, speed, zooms, captions, titles, lower thirds, chapter cards, highlights, markers,
styling), look at the result through rendered frames / contact sheets / proxy clips written to a cache folder, and hand
the human a **draft** that the human accepts or rejects change by change inside the editor. Final exports to the user's
folders need the human's approval. Nothing the agent does bypasses `EditorModel`'s undo, autosave or invariants.

## 1. Decisions (fixed for this plan)

| # | Decision | Consequence for the code |
|---|----------|--------------------------|
| D1 | Agent edits land in a **draft** by default; per-project access `off · read · draft · live`. | Draft = in-memory `[EditOp]` on a frozen base, visible read-only from the first successful apply (watching); submit makes it ready for review. Live = `model.edit("Claude: …")`. |
| D2 | **No MCP SDK.** Hand-rolled JSON-RPC 2.0, newline-delimited, protocol `2025-06-18`. | CLAUDE.md forbids third-party packages. ~300 lines in one file. |
| D3 | Agents never receive key characters. | No tool returns `InputEvent.ch`. Agent renders force `project.keys.show = false`. |
| D4 | Motion graphics = **two new text styles** (`lowerThird`, `chapter`) + existing highlight masks and zooms. | Rendered by the existing `Compositor.drawText` path. No shaders/HTML from agents. |
| D5 | Agents render freely into the cache; `export.final` outside it needs approval. | Cache: `~/Library/Caches/Recorder/Agent/<session>/`, purged at launch when older than 7 days. |
| D6 | The **same `Recorder` binary** is the stdio shim: `Recorder --mcp`. | No new SwiftPM target, no `assemble-app.sh` change. |
| D7 | A project an agent works on is **open in an editor window**. | One code path: tools act on `EditorWindowController`'s `EditorModel`. No headless editing. |
| D8 | Drafts are **persisted** (T-825, replaces the in-memory D8) in `agent-draft.json` inside the project package: id, base revision and base project, calls, per-call replay context (silent ranges, imported assets), exclusions, note, submitted flag. | Written atomically after each edit, review change and submit; deleted on accept or discard. `project.open` re-adopts it (or a disconnected session's in-memory draft) and returns `draft:{id,status,changes}`. One file per package, so one pending draft per project; a second concurrent draft overwrites it. The base project is stored so a stale draft replays exactly; words come from the live transcript. |
| D9 | All times in tool I/O are **output seconds of the project at `ifRevision`** (what the agent sees in renders). | Core converts with `TimeMap` before mutating. Agents never see source time. |

Out of scope (do **not** build): MCP resources/prompts, music ducking, LUFS normalisation, OCR, background music, counters,
progress bars, end cards, agent-written graphics, multiple simultaneous visible draft previews per project, (reconnect-and-replay in the shim was added in T-825/T-826 review fixes: if the app socket drops the shim relaunches the app, reconnects and replays the client's `initialize` + `notifications/initialized`, swallowing the duplicate reply; requests in flight are lost).

## 2. Architecture

```
Claude Code ──stdio──▶ Recorder --mcp (shim) ──unix socket──▶ Recorder.app (running, hidden if needed)
                       pumps bytes only                        ├─ Agent/MCPServer.swift   JSON-RPC, sessions, access, activity
                                                               ├─ Agent/MCPTools.swift    tool schemas + handlers
                                                               ├─ Agent/AgentRender.swift frames, contact sheet, proxy clip
                                                               ├─ EditorModel / TimelineOps / Compositor / Exporter (existing)
                                                               └─ Inspector/AgentPanel.swift  review + activity + access UI
RecorderCore: AgentViews.swift (timeline/transcript views, fillers) · EditOps.swift (EditOp, apply) · Project markers/styles
```

- Socket: `~/Library/Application Support/Recorder/mcp.sock` (create the folder). Accept only peers with the same uid
  (`getpeereid`). One thread accepts; each connection gets one `MCPSession` that reads lines on a background thread and
  hops to `@MainActor` for every tool call (all editor state is main-actor).
- Shim (`Recorder --mcp`): in `main.swift`, **before** `SelfTest.runIfRequested()`. Connect; if that fails run
  `/usr/bin/open -g -j -b space.microapps.recorder` (or the enclosing `.app` path of `Bundle.main`), poll every 100 ms
  for 15 s. Then two threads: stdin→socket, socket→stdout. On EOF from either side, exit(0).
  `// ponytail: no reconnect if the app quits mid-session; the client must reconnect (/mcp). Copy dbman-mcp's replay if users hit it.`
- The app starts the listener in `AppDelegate.applicationDidFinishLaunching` (not in selftests unless a selftest starts it).

## 3. Existing code to reuse (read these before the task that uses them)

| Need | Use | File |
|------|-----|------|
| Mutate a project with one undo step | `EditorModel.edit(_ name:_ change:)` | `Editor/EditorModel.swift` |
| Trial edits (review) | `beginGesture()` → `update {}` → `commitGesture(name)` / `cancelGesture()` | same |
| Output ↔ source time | `project.timeMap` (`TimeMap.sourceTime(atOutput:)`, `outputTime(atSource:)`) | `RecorderCore/TimeMap.swift` |
| Split / delete clips with ripple + linked audio | `split(atOutput:)`, `deleteClips(_:propagate:)` | `RecorderCore/TimelineOps.swift` |
| Speed | `setSpeed(_:_:)` | same |
| Zoom / text / mask blocks | `addZoom(atSource:length:mode:)`, `addText(atSource:length:style:text:)`, `addMask(atSource:length:kind:rect:opacity:)`, `removeBlock(id:)` | same |
| Captions | `captionPhrases(words:maxWords:gap:)`, `replaceCaptions(_:)` | `Project.swift`, `TimelineOps.swift` |
| Pauses | `Waveform.peaks(for:)` + `silentRanges(levels:perSecond:…)` (peaks are 200/s) | `Render/Waveform.swift`, `RecorderCore/Events.swift` |
| Transcript | `model.transcript` (`[Word]`, mic media seconds = source seconds), `model.transcribe()` | `EditorModel.swift`, `Editor/Transcriber.swift` |
| Idle / typing / clicks | `idleRanges(events:)`, `typingRanges(events:)`, `.down` events | `RecorderCore/Events.swift` |
| Styling subset patch | `Preset` (background, frame, cursor, animation, camera) | `RecorderCore/Preset.swift` |
| Render a real frame (export-identical) | `EditorWindowController.renderCurrentFramePNG(model:)` | `Editor/EditorWindowController.swift` |
| Render a movie | `Exporter(model:settings:destination:)`, `ExportSettings(shortEdge:fps:quality:codec:)`, `progress` callback | `Render/Exporter.swift` |
| Open a project window | `EditorWindowController.open(package:)`, `EditorWindowController.allOpen` | same |
| Library listing | `ProjectStore(folder:)`, `.items` | `Library/ProjectStore.swift` |
| Invariants | `project.checkInvariants()` | `TimelineOps.swift` |
| Colours, fonts, controls | `Theme`, `UIComponents.swift` | `App/` |

Rules that bite: every `Project` mutation in the app goes through `EditorModel`; effects are stored in **source** time;
convert only through `TimeMap`; `make test`, never bare `swift test`; Core never imports AppKit/AVFoundation/Metal.

## 4. MCP protocol subset (D2)

Transport: one JSON object per line, UTF-8, `\n` terminated, both directions. Implement exactly these methods:

| Method | Reply |
|--------|-------|
| `initialize` | `{"protocolVersion":"2025-06-18","capabilities":{"tools":{"listChanged":true}},"schemaVersion":<hash of tools/list>,"serverInfo":{"name":"recorder","version":<CFBundleShortVersionString>},"instructions":<§5.0 text>}`. Store `params.clientInfo.name` as the session's agent name. |
| `notifications/initialized` | none; but when this client (name and version when given, else name) last initialized against a different `schemaVersion` (remembered in UserDefaults), the server then sends `notifications/tools/list_changed` once (T-825). Clients may ignore it, so until that connection calls `tools/list`, every tool result also carries `schemaNotice` naming the new argument/op fields (R4-1). |
| `ping` | `{}` |
| `tools/list` | `{"tools":[…§5 schemas…]}` |
| `tools/call` | `{"content":[…],"structuredContent":{…},"isError":false}` |
| anything else with an `id` | JSON-RPC error `-32601` |

- Tool failures are **results**, not JSON-RPC errors: `isError: true`, `content: [{"type":"text","text":"STALE_REVISION: …"}]`,
  `structuredContent: {"error":"STALE_REVISION","message":"…","fix":{…},"current":{…}}` (T-826): `fix` is always an
  object with a `hint` and, when derivable, `{index, op}` — the corrected op (a clip-edge cut returns the range snapped to
  the edge with `snap:true`; an out-of-range time is clamped); `current` is `{revision, duration, clips:[{from,to}]}` of
  the project the call saw (null before `project.open`). `current.clips` is present only for range errors, capped to the
  ~20 clips nearest the failing time; `revision` and `duration` are always there.
- `content` always starts with one `text` item holding the JSON of `structuredContent` (clients that ignore structured
  output still work). Images: `{"type":"image","mimeType":"image/png","data":<base64>}`. Files:
  `{"type":"resource_link","uri":"file:///…","name":"proxy-0001.mp4","mimeType":"video/mp4"}`.
- Progress: if `params._meta.progressToken` is present on a long call (`render.clip`, `export.final`, `analyze.transcribe`),
  send `{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":…,"progress":0.35,"total":1}}`
  at most every 0.25 s.
- Tool annotations in `tools/list`: `project`, `timeline`, `transcript`, `render` `{"readOnlyHint":true}`; `analyze` (its `transcribe`
  writes), `edit` (`undo` is not idempotent) and `draft` `{"destructiveHint":false}`; `export` `{"destructiveHint":false,"openWorldHint":false}`. Every tool also declares an
  `outputSchema` (loose: known keys typed, none required, plus `project`/`revision`/`error`/`message`); results are
  always in `structuredContent`.
- Limits live only in the tool `inputSchema`. `tools/call` validates arguments against it server-side (`type`, `enum`,
  `minimum`, `maximum`, `minLength`, `maxLength`, `maxItems`, nested objects/arrays; `oneOf` unions are checked by the op decoder, which
  also validates each op against its own schema). Out-of-range or off-enum numbers return `OUT_OF_RANGE`, wrong shapes
  `INVALID_OP`. `render.frames at` takes up to 24 times, the same as the schema says. `MCPTools.handled` lists every
  `tool.action` with a handler; `--selftest mcp-schema` diffs it against `tools/list` and checks annotations,
  outputSchemas and the render limits.

Error codes (exact strings): `PERMISSION_DENIED`, `NO_PROJECT`, `STALE_REVISION`, `TRANSCRIPT_CHANGED`, `NOT_TRANSCRIBED`,
`OUT_OF_RANGE`, `INVALID_OP`, `INVARIANT`, `RENDER_BUSY`, `NEEDS_APPROVAL`, `DENIED`, `REVIEW_IN_PROGRESS`.
Every message says what to do next (e.g. `STALE_REVISION: project is at 9f2c41ab03de, you sent 1a0b…; call timeline.get and retry`).

| Recording error | Recovery |
|---|---|
| `PERMISSION_NEEDED` | Grant Recorder Screen Recording and Accessibility in System Settings and retry. |
| `NO_TARGET` | Refresh `record.targets` and choose a current on-screen window or display. |
| `RECORDING_BUSY` | Wait for the human or other session's take to end. |
| `NOT_RECORDING` | Check `record.status` and start a take with this session. |
| `RECORDING_FAILED` | Check Recorder for a recoverable take before retrying. |

## 5. Tool surface (server name `recorder`)

### 5.0 `instructions` text (send verbatim in `initialize`)

> Recorder edits screen recordings. Times you send and receive are output seconds (the edited timeline). Typical loop:
> project.open → timeline.get + transcript.get → analyze → edit.apply (lands in a draft) → render.frames / render.sheet
> to check → fix → draft.submit for the human to review. Pass ifRevision from the latest result. Renders go to a cache
> folder; final exports need the user's approval. Key presses are never shared.
> To make a demo yourself: record.targets → record.start {window} → drive the app with your own computer-use tool,
> calling record.mark {label} when each step begins → record.stop (opens the project) → edit as usual: cut from a
> step's settled end to the next step's mark, label steps with text, pace demo, render.lint demo, then draft.submit.

### 5.1 Tools

Ten tools, each with an `action` string (Resolve's MCP shows that grouping keeps context small).

| Tool | Actions → result (project-scoped results include `project` id and `revision`) |
|------|---------------------------------------------------------------------|
| `project` | `list` → `[{id,title,path,duration,modified,hasMic}]` · `open {id\|path}` → opens the editor window, returns `info` plus `draft:{id,status:"drafting"\|"submitted"\|"stale",base,revision,changes}` when a pending draft was re-adopted (or `draft:{status:"unrecoverable",error}` when the file could not be read or replayed; it is then kept as
`agent-draft.failed.json` and never overwritten). The draft attaches only to its own project. Takeover rule: a reconnecting
client takes over a disconnected session's in-memory draft of this project, preferring the same client name and otherwise any
(a client restart may rename itself); a draft a connected session holds is never duplicated from the file; continue with the returned `revision` · `info` → `{title,duration,size:{w,h},clips,lanes:{zoom,text,mask,…counts},hasMic,hasCamera,transcribed,access}` · `assets` → `{layers:[{asset,kind,id,track,from,to,mediaStart,mediaRate}], library:[{recording,title,duration}]}` (media a `layer` op can use) · `templates` → `{templates:[{name,summary,params,example}]}` (graphic op templates) |
| `timeline` | `get {from?,to?}` → `AgentTimeline` (§T-801) |
| `transcript` | `get {from?,to?,format:"words"\|"phrases"}` → `AgentTranscript` (§T-801). `NOT_TRANSCRIBED` if `model.transcript == nil`. |
| `analyze` | `transcribe` (async, progress) · `pauses {minDuration=0.6,threshold=0.02}` → `[{from,to}]` · `fillers` → `[{word,from,to,text}]` · `activity` → `{idle:[…],typing:[…],clicks:[t…]}` (ranges only, never characters) · `shots {response_format="concise"\|"detailed", thresholds?}` → `Storyboard` `{duration,fps,shots:[{id,from,to,kind,boundary,energy,staticFrac,clicks,cursor,focus,reasons,caption}],summary}` in output seconds, `duration` = export duration; full-canvas layers are shots too (`layer:<id>`; recording layers show their media window's shots, image/video layers one `L:<id>` coverage shot) (dropped footage omitted; ids s01… come from the unedited recording so they survive cuts; concise omits `reasons` only (`focus` is kept); no `thumb` yet). Signals (10 fps, 1/8 luma diff/SSIM/changed bbox) are cached in `shots-cache.json` in the package; progress reported. `thresholds` (an object) overrides `ssim=0.985, minStable=0.3, cutSsim=0.9, motionDiff=0.01, payoffDiff=0.03, cursorSpeed=0.05, energyScale=0.1` (`energyScale`, `minStable` > 0; `ssim`, `cutSsim` within 0…1; others ≥ 0; else INVALID_OP) |
| `edit` | `apply {ifRevision, ops:[EditOp], dryRun=false}` → `{revision, mode:"draft"\|"live", changes:[EditChange], duration:{before,after}, warnings:[…], report?:EditReport, lowered?:[LoweredIntent]}` (`lint:"reel"\|"tutorial"\|"demo"` picks the report profile) · `undo` (live only: `model.undo()` if the top undo name starts with `Claude:`) |
| `draft` | (`submit` returns op/change counts unless `response_format:"detailed"`; `project.open`'s draft block counts changes) `status {response_format="concise"}` → `{base, ops, changes, submitted, verdict?}`; concise shows a reframe op's `keys` as a count plus `jumps`, `detailed` returns every key · `submit {note}` → opens review in the editor · `discard` |
| `render` | `frames {at:[t…] ≤24, draft=true, longEdge=640, grid=false}` (grid: 0.1-step magenta overlay labelled 0–1, origin top-left, the coordinates zoom `center` and text `position` use) → images + links · `sheet {count=12 ≤24 \| at:[…], from?, to?, draft=true}` (from/to: sample only that range) → 1 JPEG + link · `clip {from,to, draft=true}` → job, then link (async, progress) · `storyboard {shots?:[id], page=1, draft=true}` → 1 JPEG, one 320 px tile per shot at its settled keyframe (just before `to`), labelled `id duration`, ≤48 per page (`page`/`pages` returned), shots the draft dropped are skipped; needs `analyze.shots` (else `NO_STORYBOARD`) · `strip {from,to,fps=6 (4–8)}` → 1 filmstrip JPEG, ≤48 tiles · `compare {at:[t…] ≤6}` → 1 JPEG, one row per draft time, live base left at the **same source moment** (clamped when the base lacks it), draft right; labels carry base/draft/source time · `lint {profile="reel", draft=true}` → `{revision, profile, report}` (needs a storyboard) · `cancel` |
| `export` | `final {destination?, shortEdge?, fps?, srt=false, from?, to?}` (from/to: export only that output range; not with srt) → waits for approval → `{path, seconds, bytes}` or `DENIED` |
| `ui` | `show {at, select?:[id]}` → moves the playhead / selection in the editor |
| `record` | `targets` → windows and displays · `start {window\|display, area?, width?, height?, exclude?, title?, maxDuration?}` → recorded target and duration cap · `status` → state, time, marker count and owner · `mark {label, x?, y?, pointerAction?}` → marker ID and time · `pause` / `resume` → state and time · `stop {discard=false}` → opens the saved project and returns its metadata, path and markers, or returns `{discarded:true}` |

Optional shot captions (T-832): `AgentCaptions.captionShots(storyboard, model:)` fills `Shot.caption` (6–10 words, Vision OCR on the shot's focus crop, classifier label fallback, shaped by Core `ShotCaption.shape`); `null` on any failure. New recordings write the `analyze.shots` signal cache while recording (`ShotAnalysis.Live`, 4:2:0 or BGRA window capture; older recordings decode once on first call). Opt-in with `captions:true` on `analyze.shots`; captions are kept in the package as `shots-captions.json` (id → caption, removed when the thresholds change) so `protect:["caption~regex"]` works in later edits; typing shots are never captioned.

`draft=true` renders the project with the session's draft applied (or the live project when there is no draft).

### 5.2 `EditOp` (JSON, discriminated by `op`)

All times are output seconds of the project at `ifRevision`. Ids come from `timeline.get`.
`cut`, `cutWords` and `speed` accept `snap:true`; `cutPauses` defaults to it and accepts `snap:false` for strict
behavior. Use snapping for cuts derived from idle ranges. It clamps to the timeline and moves invalid split
points to the nearest clip edge using the editor's0.1s media/two-frame output minimums. Timed effects do not
split clips and retain their existing range validation. Adjustments are returned in `changes[].note` with source
ranges. A collapsed/uneditable operation returns `skipped:true`, its note and a warning; other operations proceed.
Draft status/panel excludes these skipped operations from Accept N and preserves their replay ids.
Zoom centers are normalized0–1 in the source frame, with the origin at the top-left corner.

```jsonc
{"op":"cut","from":12.0,"to":14.5}                          // remove a range (video + linked audio, ripple); also removes empty timeline (gaps) and ripples layers after it
{"op":"cutPauses","minDuration":0.6,"keepTail":0.12,"from":0,"to":96}   // from/to optional = whole project
{"op":"cutWords","transcript":"t-3fa9c1d2","words":["w118","w119"]}
{"op":"speed","from":30,"to":42,"speed":2}
{"op":"zoom","from":3,"to":7.5,"scale":2,"center":{"x":0.6,"y":0.4}}   // no center = auto (follows cursor)
{"op":"text","from":1,"to":5,"style":"lowerThird","text":"Sam Lee\nBuilding Recorder","position":{"x":0.05,"y":0.8},"size":40}
{"op":"captions","maxWords":4}                               // replaces Caption-style blocks from the transcript
{"op":"highlight","from":20,"to":24,"rect":{"x":0.5,"y":0.3,"w":0.3,"h":0.2},"opacity":0.6}
{"op":"marker","at":31,"label":"Recording"}
{"op":"remove","id":"…"}
{"op":"set","id":"<layer>","to":30,"mediaStart":21.05,"mediaRate":2}   // generic patch by id (T-912); each timeline.get item lists the fields it takes (zoom: from,to,scale,center,follow,ease,color · text: from,to,text,position,size,color · mask: from,to,color,kind · layer: from,to,mediaStart,mediaRate,color · marker: from,text · clip c<i>: mediaStart = slip, position/length stay · audio: duck = its track drops to 25 % under other tracks' sound); a field the item doesn't take is INVALID_OP naming the valid ones. Layers: from/to also past the clips' end, mediaStart = slip, mediaRate = speed (length follows). `set` is the only patch op (`update` was removed 2026-11-17)
{"op":"reframe","aspect":"9:16","mode":"perShot","focus":{"s12":{"x":0.7,"y":0.4}}}   // focus (optional): re-aim those shots; the result carries reframe:{keysBefore,keysAfter,changed,shots}   // "4:5"|"1:1"|"9:16"|"16:9"; sets output.aspect + time-varying crop per shot (needs analyze.shots; error "run analyze.shots first" otherwise). perShot holds the window when the next shot's is within 3 % and shows as much focus, eases over 0.3 s at non-cut shot boundaries, and only steps at `boundary:"cut"`. A shot with no usable focus (a full-screen view swap that then holds) aims at the next shot with one, within 3 s
{"op":"graphic","from":3.4,"to":7.6,"template":{"name":"callout","params":{"text":"Add a node","x":0.62,"y":0.38}},"keys":[{"t":0,"opacity":0,"scale":0.7,"ease":"spring"},{"t":0.35,"opacity":1,"scale":1}]}   // motion graphic (T-925): template from project.templates (titleCard, callout, stepBadge, spotlight, progressBar, counter) or raw "elements"; space "screen" follows zoom; it is a graphic layer (lane "graphic"), so set/remove/animate address it by id
{"op":"freeze","at":12.4,"duration":1.2}   // hold that frame (rendered by the app into media/), later footage moves back (T-933)
{"op":"transition","at":9.5,"kind":"dissolve","duration":0.4}   // at the clip seam nearest at (≤ 0.5 s); dissolve = outgoing frame fades into the next clip, dip = through the background (T-934)
{"op":"animate","id":"<graphic, layer or text id>","keys":[{"t":0,"y":0.1,"opacity":0},{"t":0.4,"y":0,"opacity":1}]}   // replace keyframes; [] clears
{"op":"style","patch":{"background":{"kind":"color","color":"#101010"},"frame":{"padding":0.06}}}   // merge into Preset
```

Text styles: `title`, `label`, `caption` (existing), `lowerThird`, `chapter` (new, T-803).

### 5.3 Intent ops and the edit report (T-829, T-830)

Core: `EditReport.swift` (`editReport`, `lint`, `LintProfile`), `IntentOps.swift` (`lowerIntents`). Both take a source-time
`Storyboard` (analyze.shots) and map shots to output time through `TimeMap`. The MCP layer calls `MCPTools.loadStoryboard`
(analyze.shots' cached signals, never a fresh decode; `NO_STORYBOARD` until analyze.shots ran). Without a storyboard
`edit.apply` still works and returns `reportNote` instead of `report`; intent ops that need shots fail with `NO_STORYBOARD`.

Intent ops are rewritten to `cut` / `speed` / `zoom` against the same base timeline before the batch is decoded, so the
whole batch is one `applying` call and one undo step. Every intent reads the batch-start timeline, so **at most one** of `keepShots`/`pace`/`fitDuration` is allowed per batch (`INVALID_OP`; call `edit.apply` again for the next); `autoZoom`, `speed ramp` and explicit ops may be mixed in because they use the same base times. `changes[].op` and errors use the agent's original batch index. Speeds in lowered ops are absolute (relative factor × the clip's current speed, rounded up). Intents never delete imported clips. `autoZoom` skips clusters that overlap an existing zoom. If no storyboard is available, `edit.apply` returns `reportNote` with the reason instead of `report`. `lowered:[{op,intent,ops,dropped?,note?}]` returns the primitives.

```jsonc
{"op":"keepShots","shots":["s02","s05"],"trim":{"lead":0.1,"tail":0.2}}   // or "where":{"kind":["payoff"],"minEnergy":0.3}; trim = source seconds per kept shot; others cut (snap)
{"op":"keepShots","where":{"kind":["payoff","motion"],"minEnergy":0.1},"protect":["caption~graph","s49"]}   // protect: always kept (ids or caption~regex, case-insensitive)
{"op":"pace","beat":{"default":0.9,"payoff":1.3,"motion":0.8},"maxStatic":1.2,"speedFill":{"min":1.5,"max":6}}
{"op":"fitDuration","target":30,"tolerance":2,"protect":["s02"]}          // lowered.dropped = shots removed whole
{"op":"fitDuration","target":30,"minPerSection":2,"balance":"even","drop":[3]}   // every section keeps ≥ 2 s; even: same seconds per section, proportional: in proportion to its length (quota by bisection, last shot trimmed, ≤ 0.5 s granularity); drop cuts weak sections whole
{"op":"autoZoom","lead":0.4,"tail":1.5,"scale":2,"from":0,"to":60}        // AutoZoom.swift click clustering → zoom ops (from/to optional output window)
{"op":"speed","from":10,"to":14,"speed":3,"ramp":{"in":0.2,"out":0.3}}     // stepped speeds (4 per side max), no native easing
```

`pace`: static/cursorOnly shots longer than `maxStatic` (and not tagged `result`) are sped up by `d/maxStatic` when that is
within `speedFill`, with any remainder cut; shorter overshoot is simply cut. Payoff shots are held `beat.payoff` after their last click and the tail is cut. Motion/typing shots longer than their beat are sped up to it, capped at `speedFill.min`. Pieces of one shot that abut after a cut count as one hold.

`fitDuration`: drops whole segments in ascending interest (static < cursorOnly < typing < motion < payoff, energy breaks ties)
until the length is within `tolerance` of `target`; the last one is compressed (speed ≤ 6x) or tail-trimmed to land on target.
`pace {profile="reel"|"demo"|"tutorial"}` beat-cuts shots with clicks (keeps `[click − 0.1, click + beat]`; reel beats 0.9/1.3/0.8 s and cuts waits ≥ 0.5 s, demo 1.4/2.0/1.2 s and ≥ 1 s, tutorial 2.5/3.5/2.0 s and ≥ 2 s; `maxStatic` defaults to the profile's; never leaves a piece < 0.3 s between cuts) and speeds up only shots without clicks and holds. Intent ops are validated against the tools/list schema like primitives: an unknown field (also inside `where`, `trim`, `beat`, `speedFill`, `ramp`) is `INVALID_OP` naming the valid ones. `protect` entries (ids or `caption~regex`) are never touched; if the target is unreachable `lowered[].note` says so. Intents skip shot pieces under one analysis frame and never emit a range that rounds to zero length or a cut/speed under the 0.1 s clip minimum; `keepShots` cuts up to the end of the last footage clip (a trailing gap is left alone).

`report`: `{duration, aslSec, subShotAslSec, staticSec: {before,after}, hookSec, longestStatic:{sec,at}, lint:[…], reframeJumps?}`, computed draft vs the timeline
the batch started from. Static = `static` or `cursorOnly` shots. `hookSec` = output time of the first payoff's first kept click
(its start when none). Lint item: `{rule, sev, at, shot?, msg, suggest?}`; `suggest` is an op for the next `edit.apply`
(output seconds of the edited timeline). `edgeContent` suggests the T-831 `reframe` op. `aslSec` is the visual average shot: the timeline split at edit cuts (clip joins that don't continue the same footage) and `boundary:"cut"` shots; `subShotAslSec` averages analyzer shots. `tinyShot` fires for a visible piece between two cuts (edit cuts, `boundary:"cut"` shots or the timeline edges) shorter than the profile minimum, and its `suggest` is a cut that a dry run confirmed applies (else none). Pieces under one analysis frame are ignored. `reframeJumps` counts crop steps not at a cut. `sections:[{section,name?,srcFrom,srcTo,outFrom?,outTo?,shots:[first,last],keptSec}]` (src = source seconds, out/keptSec = output seconds) shows scene balance; `name` is the on-screen text of the section's representative shot (its longest non-typing shot), which `analyze.shots` reads once per section even without `captions:true`; `fitDuration` notes any section left under `minPerSection` (it only had that much footage). Every shot carries `section` (1-based): a new section where the project rearranges the recording (a clip whose media position doesn't follow from the previous clip, unlike trims or cut pauses); a recording that was only trimmed splits at `boundary:\"cut\"` shots into runs of ≥ 10 s; sections under 3 s join a neighbour. `protect` also takes `section:N`. A shot split into separate pieces by cuts carries `part:"k/n"`.

| Rule | reel | demo | tutorial |
|---|---|---|---|
| hook (first payoff at) | ≤ 1.0 s | ≤ 2.0 s | ≤ 3.0 s |
| maxStatic (not tag `result`) | 1.2 s | 2.5 s | 4.0 s |
| asl | 0.8–2.0 s | 1.5–5.0 s | 2.0–8.0 s |
| duration | 15–45 s | 20–120 s | 30–300 s |
| tinyShot | < 0.25 s | < 0.3 s | < 0.4 s |
| orphanEffect (zoom, non-caption text) | < 0.5 s visible, all profiles | | |
| uncovered (only background visible: no clip, no full-canvas layer, ≥ 1 frame) | all profiles; `suggest` = `cut` of the part inside the clips | | |
| edgeContent | shot focus box outside `project.crop`, all profiles | | |
**Anchors (T-826).** Any `from`/`to`/`at` may be a number or an anchor object, resolved on the timeline after the
earlier ops of the same batch: `{"marker":"<id or label>","offset":s}` (a label works when exactly one marker has it;
two or more is an error naming the count), `{"ref":"name","offset":s}` (the start of an earlier op in this batch that
declared `"ref":"name"`; allowed on `cut`, `speed`, `zoom`, `text`, `highlight`, `marker`, `layer`; names are unique per
batch and do not carry across `edit.apply` calls — use marker labels for that), and `{"shot":"s07","edge":"start"|"end"}`.
Shot anchors resolve through `EditContext.shotTime(id, isEnd) -> source seconds`, filled from analyze.shots' cached
storyboard; before analyze.shots ran they return `INVALID_OP: unknown anchor`.

**Every block is addressable.** `edit.remove` removes any block `timeline.get` emits (zoom, text, mask, layout, camera,
keys, window, layer, audio) or marker, only that block (linked clips and audio stay). `set` covers zoom, text,
mask, markers and layers (`from`/`to` move both ends of a layer on the output clock, either direction, and fail with the
reachable limit when a neighbour, the media length or 0.5 s blocks it; `color`). Blocks `set` cannot change are
emitted with `editable:false` and a `reason`, and a `set` on one says so instead of "unknown block".

---

## 6. Tasks

Each task: **Do**, **Files**, **Signatures**, **Verify**, **Done when**. Keep to the listed files. Add a
`// ponytail: <limit>, <upgrade path>` comment for every deliberate shortcut.

### T-801 Core: agent views (timeline, transcript, fillers)

**Do.** Pure functions that turn `Project` (+ transcript words) into the compact, output-time JSON the agent reads.

**Files.** `Sources/RecorderCore/AgentViews.swift` (new) · `Tests/AgentViewsTests.swift` (new).

```swift
public struct AgentTimeline: Codable, Equatable, Sendable {
    public struct Clip: Codable, Equatable, Sendable { public var index: Int; public var from: Double; public var to: Double; public var speed: Double; public var file: String? }
    public struct Block: Codable, Equatable, Sendable { public var id: String; public var lane: String; public var from: Double; public var to: Double; public var label: String }
    public struct Marker: Codable, Equatable, Sendable { public var id: String; public var at: Double; public var label: String }
    public var duration: Double
    public var clips: [Clip]
    public var blocks: [Block]      // lanes: zoom, text, mask, layout, camera, keys, layer, audio
    public var markers: [Marker]    // empty until T-803
}
public func agentTimeline(_ project: Project, from: Double? = nil, to: Double? = nil) -> AgentTimeline

public struct AgentWord: Codable, Equatable, Sendable { public var id: String; public var text: String; public var from: Double; public var to: Double; public var filler: Bool }
public struct AgentTranscript: Codable, Equatable, Sendable {
    public var transcript: String            // "t-" + 8 hex of a stable hash of the words (FNV-1a over text+times is fine)
    public var words: [AgentWord]            // only words whose source time maps to output (cut words are omitted)
    public var phrases: [String]?            // "[0:01.2] so first we open settings" when format == phrases
}
public func agentTranscript(_ project: Project, words: [Word], from: Double? = nil, to: Double? = nil, phrases: Bool = false) -> AgentTranscript
public func isFiller(_ text: String) -> Bool  // um uh er ah erm hmm mm, case-insensitive, punctuation stripped
public func transcriptID(_ words: [Word]) -> String
```

- Word ids are `"w\(index in the full transcript array)"` so they stay valid as the agent cuts (ids never renumber).
- Output time of a word = `project.timeMap.outputTime(atSource: word.start)`; omit the word when `nil`.
- Round every time to 0.01 s. Block `label`: zoom `"2.0×"`, text first 24 chars, mask kind, etc.
- Read `TimeMap.swift` first; clips with `file != nil` (imported) have no transcript.

**Verify.** `make test FILTER=AgentViews` — tests: (1) project with 2 clips and a 2× clip yields correct output ranges;
(2) a word inside a removed range is omitted and later ids are unchanged; (3) `isFiller("Um,") == true`, `isFiller("umbrella") == false`;
(4) `transcriptID` changes when one word's time changes. Then `make test`.

**Done when** tests pass and no AppKit/AVFoundation import is in Core.

### T-802 Core: `EditOp` and `apply`

**Do.** Decode agent ops and apply them to a `Project` atomically: either every op applies and invariants hold, or
nothing changes and an error says which op failed.

**Files.** `Sources/RecorderCore/EditOps.swift` (new) · `Tests/EditOpsTests.swift` (new). Small additions to
`TimelineOps.swift` only if a helper is genuinely missing (prefer composing existing functions).

```swift
public enum EditOp: Codable, Equatable, Sendable {
    case cut(from: Double, to: Double, snap: Bool = false)
    case cutPauses(minDuration: Double, keepTail: Double, from: Double?, to: Double?, snap: Bool = true)
    case cutWords(transcript: String, words: [String], snap: Bool = false)
    case speed(from: Double, to: Double, speed: Double, snap: Bool = false)
    case zoom(from: Double, to: Double, scale: Double, center: NormPoint?)
    case text(from: Double, to: Double, style: TextBlock.Style, text: String, position: NormPoint?, size: Double?)
    case captions(maxWords: Int)
    case highlight(from: Double, to: Double, rect: NormRect, opacity: Double?)
    case marker(at: Double, label: String)
    case update(id: String, from: Double?, to: Double?, text: String?, position: NormPoint?, size: Double?, scale: Double?, center: NormPoint?)
    case remove(id: String)
    case style(patch: [String: JSONValue])   // JSONValue: tiny Codable enum (null,bool,number,string,array,object) in this file
}
public struct EditContext: Sendable {
    public var words: [Word]          // full transcript, mic media seconds (= source seconds)
    public var silent: [TimeRange]    // silentRanges over mic.m4a at the requested threshold, source seconds
    public init(words: [Word] = [], silent: [TimeRange] = [])
}
public struct EditChange: Codable, Equatable, Sendable {
    public var op: Int; public var summary: String; public var at: Double; public var delta: Double
    public var note: String? = nil; public var skipped = false
}
public enum EditError: Error, Equatable, CustomStringConvertible {
    case invalidOp(index: Int, reason: String), outOfRange(index: Int, reason: String), transcriptChanged, invariant(String)
}
extension Project {
    /// Applies `ops` to a copy. All op times are OUTPUT seconds of `self`; they are converted to SOURCE ranges with
    /// `self.timeMap` before anything mutates, so op order does not shift later ops.
    public func applying(_ ops: [EditOp], context: EditContext) throws -> (project: Project, changes: [EditChange])
    /// Removes SOURCE ranges from screen clips (`file == nil`), splitting at edges and rippling; linked audio follows.
    public mutating func removeSourceRanges(_ ranges: [TimeRange])
}
```

Implementation notes (follow them):
- Convert first, mutate second: build `[(kind, sourceRange, …)]` from `self.timeMap`, then apply removals **last** and
  **in descending source order**, effects (zoom/text/mask/marker) first. Effects are stored in source time, so removing
  footage never invalidates them (SPEC §5 "why source time").
- `removeSourceRanges`: for each range, find overlapping clips, `split(atOutput:)` at the range's output edges (compute
  output edges from the *current* `timeMap` each iteration), then `deleteClips(_:propagate:)` for clips fully inside.
  Force ripple for the call: save `rippleDelete`, set `true`, restore after. Read `split` and `deleteClips` fully first.
- `cutPauses`: take `context.silent` ranges overlapping `[from,to]` (converted), shrink each by `keepTail` on both sides,
  drop those shorter than `2*keepTail + 0.05` (same rule as the pause eraser), then `removeSourceRanges`.
- `cutWords`: `transcriptChanged` if `transcriptID(context.words) != transcript`. Word `wN` → source `[start,end]`
  widened to half the gap to each neighbour, capped at 0.15 s per side.
- `speed`: split at both edges, then `setSpeed` on every clip fully inside.
- Snapped cut/speed ranges respect both media and output minimums at current playback rates. Cut snapping also
  considers earlier cuts in the batch, preventing tiny retained seams. A snapped cut that would remove all
  remaining media is skipped with a warning. Strict operations and invalid/nonfinite parameters still fail
  atomically. No arbitrary snap tolerance or new duration setting is introduced.
- `zoom`: `addZoom(atSource:length:mode:)` with `.manual` when `center` is set else `.auto`; then set `scale`/`center`.
  `addZoom` returns nil when the lane is occupied → `invalidOp(reason: "zoom overlaps <id>")`.
- `text`: `addText(atSource:length:style:text:)`, then set `position`/`size`. `captions`: `replaceCaptions(captionPhrases(words: context.words, maxWords:))`.
- `highlight`: `addMask(atSource:length:kind: .highlight, rect:, opacity:)`. `marker`: T-803 adds `markers`; until then `invalidOp`.
- `update`/`remove`: find the id in zooms/texts/masks/markers; `remove` uses `removeBlock(id:)`.
- `style`: encode `Preset(from: self)` (read `Preset.swift` for the real initializer/apply names), merge `patch` into
  the JSON object recursively, decode `Preset`, apply. Unknown keys → `invalidOp`.
- After all ops: `checkInvariants()`; non-nil → throw `.invariant(message)`.
- `EditChange.summary`: human-readable, e.g. `"Cut pause 0:08.3 (−1.7 s)"`, `"Zoom 2.0× 0:03–0:07.5"`. `delta` = output
  duration change in seconds (negative for cuts). `at` = output time in `self`.

**Verify.** `make test FILTER=EditOps` with at least: (1) two cuts given in base output time remove exactly those
ranges regardless of op order (compare `timeMap` output durations); (2) a zoom op inside a later-cut range survives in
source time; (3) `cutPauses` honours `keepTail` and drops short pauses; (4) `cutWords` with a stale transcript id throws
`.transcriptChanged`; (5) an overlapping zoom returns `.invalidOp` and leaves the project unchanged; (6) `style` patch
changes `frame.padding` only; (7) every test ends with `checkInvariants() == nil`. Then `make test`.

### T-803 Core: markers, `lowerThird`/`chapter` styles, SRT

**Files.** `Sources/RecorderCore/Project.swift`, `EditOps.swift`, `AgentViews.swift`, `Tests/ProjectTests.swift`, `Tests/EditOpsTests.swift`.

```swift
public struct Marker: Codable, Equatable, Sendable { public var id: String; public var time: Double; public var label: String }  // SOURCE time
// Project: public var markers: [Marker] = []   (decode with default [], additive key, no version bump)
// TextBlock.Style: add `lowerThird`, `chapter`
public func srt(_ project: Project) -> String   // Caption-style blocks only, output time, "HH:MM:SS,mmm"
```

- **Version rule** (SPEC §5): `TextBlock.Style` is an enum, so an older build would fail to decode the new raw values.
  Bump `currentVersion` to 5 and save `"version": 5` only when a text uses `lowerThird` or `chapter`; otherwise keep the
  existing 3/4 rule. Update the version comment in SPEC §5 in T-810.
- `markers` follow ripple automatically because they are in source time; `agentTimeline` maps them to output time and
  omits markers inside removed footage.
- `EditOp.marker` now appends a `Marker`; `update`/`remove` find markers by id.

**Verify.** `make test FILTER=ProjectTests` (round-trip with markers and the new styles; a project with only `title`
texts still saves version ≤ 4; one with `lowerThird` saves 5) and `make test FILTER=EditOps` (marker op); `srt` test with
a 2× clip checks timestamps. Then `make test`.

### T-804 App: MCP server, shim, read tools

**Do.** The transport (§2, §4), sessions, access levels, activity feed, and the read tools `project`, `timeline`,
`transcript`, `analyze`.

**Files.** `Sources/Recorder/App/main.swift` (shim branch) · `Sources/Recorder/Agent/MCPServer.swift` (new: socket,
JSON-RPC, `MCPSession`, `AgentAccess`, `AgentActivity`) · `Sources/Recorder/Agent/MCPTools.swift` (new: schemas +
handlers) · `AppDelegate.swift` (start listener) · `SelfTest.swift` (register case).

```swift
enum MCPShim { static func runIfRequested() }            // main.swift calls this first; never returns when --mcp
@MainActor final class MCPServer {
    static let shared: MCPServer
    func start(socketPath: String = MCPServer.defaultSocketPath) throws
    func stop()
    static var defaultSocketPath: String                   // ~/Library/Application Support/Recorder/mcp.sock
}
@MainActor final class MCPSession {                        // one per socket connection
    var agentName: String                                   // clientInfo.name
    var projectURL: URL?                                    // set by project.open
    var draft: AgentDraft?                                  // T-806
    func handle(_ request: [String: Any]) async -> [String: Any]?   // nil for notifications
    func notify(_ method: String, _ params: [String: Any])
}
enum AgentAccess: String, CaseIterable { case off, read, draft, live
    static func level(for projectID: String) -> AgentAccess          // UserDefaults "agentAccess.<id>", default .draft
    static func set(_ level: AgentAccess, for projectID: String)
}
@MainActor @Observable final class AgentActivity {         // last 200 rows, shown in the inspector (T-807)
    static let shared: AgentActivity
    struct Row: Identifiable { let id = UUID(); let time: Date; let agent: String; let tool: String; let summary: String; let ms: Int; let isError: Bool }
    private(set) var rows: [Row]
    func log(_ row: Row)
}
enum MCPTools { static let list: [[String: Any]]          // tools/list payload
    @MainActor static func call(_ name: String, _ args: [String: Any], session: MCPSession) async -> [String: Any] }
```

- Use `JSONSerialization` for the envelope; decode tool args that map to Core types (`EditOp`) with `JSONDecoder` from
  `JSONSerialization.data(withJSONObject:)`.
- Revision = first 12 hex chars of SHA-256 (CryptoKit) of `JSONEncoder` (`.sortedKeys`) encoding of `model.project`.
- `project.open`: `await EditorWindowController.open(package:).value`; the session keeps the URL; later tools find the
  model through `EditorWindowController.allOpen.first { $0.model.packageURL == url }` (expose `model` if private).
  Closed window → `NO_PROJECT: open it again with project.open`.
- Access checks: `off` → every tool `PERMISSION_DENIED`; `read` → `edit`/`draft`/`export` denied.
- `analyze.pauses`: `Waveform.audioURL(in:file:"mic.m4a")` → `Waveform.peaks(for:)` (200/s) → `silentRanges(levels:perSecond:200,threshold:minDuration:)`
  → map to output time; drop ranges inside cut footage.
- Log every call to `AgentActivity` (tool + action, short summary, duration, error flag). Never log arguments that
  could contain transcript text in full; summaries only.
- Register selftest `mcp-roundtrip <package>`: start the server on a temp socket path, connect with a plain socket
  client, send `initialize`, `tools/list`, `project.open`, `timeline.get`, `transcript.get` (accept `NOT_TRANSCRIBED`),
  `analyze.pauses`; assert JSON shapes and that `tools/list` has 9 tools.

**Verify.** `make app && build/Recorder.app/Contents/MacOS/Recorder --selftest mcp-roundtrip <fixture package>`
(use the fixture the `parity` selftest uses). Manual smoke with the shim:
`printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"smoke"},"capabilities":{}}}' | build/Recorder.app/Contents/MacOS/Recorder --mcp`
prints one `result` line. `make test` still green.

### T-805 App: render tools (frames, contact sheet, proxy clip, cache)

**Files.** `Sources/Recorder/Agent/AgentRender.swift` (new) · `EditorWindowController.swift` (generalise the frame
renderer) · `MCPTools.swift` · `MCPServer.swift` (concurrent cancel + request-local progress) · `AppDelegate.swift`
(cache purge) · `Render/Exporter.swift` (optional output range) · `SelfTest.swift`.

```swift
// EditorWindowController: replace the body of renderCurrentFramePNG with a call to the new function.
@MainActor static func renderFramesPNG(model: EditorModel, at times: [Double], longEdge: Int?) async throws -> [Data]
enum AgentRender {
    static func cacheFolder(session: String) -> URL          // ~/Library/Caches/Recorder/Agent/<session>/, created
    static func purgeOldCaches(olderThan days: Int = 7)       // called at launch
    @MainActor static func renderModel(for model: EditorModel, project: Project) -> EditorModel   // keys.show = false
    @MainActor static func frames(model: EditorModel, at: [Double], longEdge: Int, folder: URL) async throws -> [URL]
    @MainActor static func sheet(model: EditorModel, at: [Double], folder: URL) async throws -> URL  // JPEG grid
    @MainActor static func clip(model: EditorModel, from: Double, to: Double, folder: URL,
                                progress: @escaping (Double) -> Void) async throws -> URL
}
```

- `renderFramesPNG`: same reader setup as today, but **sort** the times and reuse one `AVAssetReader` + `FrameHold`
  per track, calling `imageBuffer(upTo:)` in increasing order (FrameHold only moves forward). Scale the output size to
  `longEdge` when given. `copyFrameAsImage` keeps calling it with `[model.playhead]`, `nil`.
- `renderModel`: `EditorModel(packageURL:project:events:)` with the given project, `keys.show = false`, every
  keystroke-clip override disabled and key/typing events removed (D3). Reuse existing motion paths when the supplied
  project matches. Draft renders pass the draft project; live renders pass `model.project`.
- `sheet`: render each time at long edge 320, draw into one `CGContext` grid (4 columns), burn the timecode
  (`m:ss.s`, `Theme.timecodeFont(11)` metrics are fine via `NSAttributedString.draw` in an `NSGraphicsContext`),
  encode JPEG quality 0.8 with `CGImageDestination`.
- `clip`: freeze the draft/live project and use `Exporter(model: renderModel, settings: ExportSettings(shortEdge: 540,
  fps: 30, quality: .web, codec: .h264), destination:, outputRange: TimeRange(start: from, end: to))`. Keep frame state
  and mix ramps on their original output clock; start the native writer session at `from`, append original-time
  samples and end at `from + rendered duration`. Decode video from zero to preserve frames held across idle spans;
  skip audio packets entirely before `from`. The earlier proposed `removeSourceRanges` complement cannot reliably
  trim imported clips, sub-minimum slices or connected tails, and rebuilding paths would change zooms at the cut.
  Forward progress through a request-local token (at most every 0.25 s). One job per session; a second render call waits
  for it (queued), `export` still gets `RENDER_BUSY`. The socket accepts concurrent requests so `cancel` on that connection can
  cancel and await the job, remove its partial MP4, then allow another render.
- Tool result: images inline only for `frames` (≤ 6, long edge ≤ 640) and `sheet` (1); `clip` returns a `resource_link`
  plus `{seconds, bytes}`. Every file is also listed as `resource_link`.
- Selftest `mcp-render <package>`: frames at 3 times are non-blank PNGs of the requested size; the frame at t equals
  `renderCurrentFramePNG` with playhead t (bytes identical — parity); sheet exists; 2 s clip plays (AVURLAsset duration ±0.1 s).
  Also checks imported footage and connected-tail proxies with audio, overriding key chips, same-connection
  cancel/busy/progress, PNG/JPEG inline plus file links, proxy duration/bytes, original project revision and cache expiry.

**Verify.** `--selftest mcp-render <fixture>`, `--selftest parity <fixture>` (unchanged), `--selftest menu-actions`
(Copy Frame still works), `make test`.

### T-806 App: `edit` and `draft` tools

**Files.** `MCPTools.swift`, `MCPServer.swift` (`AgentDraft`), `EditorModel.swift` (review/gesture guards),
`SelfTest.swift`; `RecorderCore/EditOps.swift`, `Project.swift`, `TimelineOps.swift` and `Tests/RecorderCoreTests/EditOpsTests.swift`
(deterministic replay ids and motion-text overlap groups); `Inspector/TextPanel.swift` (validate style changes).

```swift
struct AgentDraft {
    var base: String                    // revision of the editor's project when the draft started
    var baseProject: Project
    var calls: [[EditOp]]               // one entry per edit.apply call, in order
    var changes: [[EditChange]]         // parallel to calls
    var note: String?
    var submitted = false
    var verdict: String?                // "accepted", "accepted 7 of 9", "discarded"
    var excluded: Set<[Int]> = []       // [callIndex, opIndex] the human unticked (T-807)
    /// Replays every call on `start` (default baseProject), skipping excluded ops.
    func project(from start: Project? = nil, context: EditContext) throws -> Project
    var revision: String { get }        // hash of project(context:) — cache it after each apply
}
```

- Why calls, not one flat op list: each call's times refer to the project **that call saw** (its `ifRevision`). The
  first call sees `baseProject`; the second sees the draft after call 1; and so on. Replaying the calls in order
  reproduces exactly that. `// ponytail: replays all calls on every change; fine for tens of ops.`
- Keep a frozen `EditContext` per call so refreshing the derived transcript does not silently change an existing
  proposal. Replay uses that call's context, with the method's `context` as a fallback for manually constructed drafts.
- New ids must survive replay and exclusions: `EditContext.operationSeeds` (default empty) supplies one internal seed
  per op, based on draft id/call index/original op index. Core scopes a deterministic UUID sequence to that synchronous
  op (and to the combined cut phase). All ordinary editor ids stay random. These seeds are not MCP arguments or saved
  project metadata. Motion styles have separate overlap groups so lower thirds can coexist with captions and produce
  the warnings below; Caption/Title/Label keep their shared non-overlap rule.
- `edit.apply`:
  1. Draft mode: `ifRevision` must equal the draft's `revision` (or the editor's revision when no draft exists yet) →
     else `STALE_REVISION`. Live mode: must equal the editor's revision.
  2. Build `EditContext` (transcript words; silent ranges computed only if an op is `cutPauses`).
  3. **Draft mode**: `let next = try current.applying(ops, context:)` where `current` is the draft project (or
     `model.project` when starting a draft: then set `base`/`baseProject`). Append the call and its changes. Return the
     new draft revision. The editor shows the watching preview; its saved human base stays unchanged.
  4. **Live mode**: `let result = try model.project.applying(ops, context:)`, then
     `model.edit("Claude: \(changes[0].summary)\(n > 1 ? " +\(n-1)" : "")") { $0 = result.project }`.
  5. `dryRun`: run `applying`, return changes, store nothing.
  6. Warnings: a `lowerThird` text overlapping a `caption` in time → `"lowerThird <id> overlaps captions <from>–<to>"`.
- Dry runs return the unchanged current `revision` plus `dryRun: true`; the duration/changes describe the prospective
  result. Empty batches do not create a draft or undo step. Recheck project/draft identity, revision, call count,
  transcript, access and editing guards after any awaited audio analysis.
- Timeline/transcript/activity reads and renders use the session's active draft and its revision. `render` with
  `draft: false` uses the live project. Reject an apply when the human has changed the draft's base, even if the client
  passes the draft's own latest revision. Live edits require discarding any pending draft first.
- `draft.submit {note}`: mark submitted; bring the editor window front; start review (T-807). Further successful
  nonempty applies on that pending draft return it to watching until it is submitted again, retaining its id,
  prior checkbox exclusions, stable operation ids and nil verdict. New calls use the current checked proposal's
  revision and output clock. Dry runs, empty batches and failed calls leave submitted review unchanged.
  Recheck submission, exclusions and skipped operations after awaited analysis, including checkbox changes that
  leave the project revision unchanged. `draft.status` returns the verdict once the human decides (`accepted`, `accepted 7 of 9`,
  `discarded`) and a `stale` flag when the base differs. `draft.discard` clears the draft and remembers `discarded` for
  the next status query. A session keeps its pending draft when opening another project, but must reopen the original
  project or explicitly discard before editing another one.
- `EditorModel`: add `var isReviewingDraft = false` and make `edit(_:_:)` and `beginGesture()` return early while it is
  true (same pattern as the existing `voiceover.isActive` guard); guard update/commit/cancel/undo/redo too. Review uses its own gesture via a private path
  (`beginReview`/`updateReview`/`endReview(commit:name:)`) that bypasses the guard.
- Selftest `mcp-edit <package>`: draft mode leaves `model.project` unchanged; live mode adds exactly one undo step named
  `Claude: …`; a stale `ifRevision` returns `STALE_REVISION`; two calls in one draft replay correctly.

**Verify.** `make test FILTER=EditOps` (replay ids/splits/exclusions and motion-text overlap invariants),
`--selftest mcp-edit <fixture>`, `make test`.

### T-807 App: review UI (Signal UI)

Read `docs/UI-KIT.md` (Signal UI direction), `Theme.swift`, `UIComponents.swift`, `docs/images/editor.png`,
`build/signal-ui-gallery.png` (`make gallery-png`), and the prototype. Use only `Theme` tokens and shared components. No new colours.

**Files.** `Sources/Recorder/Editor/Inspector/AgentPanel.swift` (new) · `Inspector/InspectorView.swift` (third header
tab) · `EditorWindowController.swift` (document bar status) · `TimelineView.swift` (review marks) · `EditorModel.swift` ·
`MCPServer.swift`/`MCPTools.swift` (review replay, session observation, status) · `PreviewView.swift`, `MediaImport.swift`,
`VoiceoverRecorder.swift` (review edit guards) · `SelfTest.swift`.

Layout (inspector, 320 pt; updated by T-812 to the [panel redesign](https://artifacts.microapps.space/a/crsebftafkp3)):

```
 Whole project   Selection   [Claude]              ← existing header tabs + "Claude" (white = selected)
 ───────────────────────────────────────────
 Claude                                Draft ▾     ← headingFont(28) · access menu Off/Read/Draft/Live
 claude-code · reviewing                           ← labelFont, textSecondary
 “Removed 6 long pauses and 3 fillers.”            ← the note, bodyFont
 8 changes                        89.0 s −9.6 s   ← selected count, resulting duration and delta
 ▸ [-] ▪ Cuts                         6 −9.6 s    ← collapsed, native tri-state checkbox + lane swatch
 ▸ [x] ▪ Text                         3      —
 ▸ Activity                                  12   ← last 50 rows, newest first, collapsed
 ───────────────────────────────────────────
                                  [ Accept 8 ]    ← pinned outside scroll area, shared white button
```

- The `Claude` tab appears when any session has this project open or a draft exists; otherwise hidden.
- Document bar: left of `Saved`, `Claude · drafting|watching|reviewing|rendering|idle` in `labelFont`/`textSecondary`; click
  selects the Claude tab. No animation loops.
- Watching/review: first successful non-dry `edit.apply` starts `beginReview(watching: true)` with the existing
  frozen human base; each later apply updates the same preview once per call. First draft/Live apply selects
  Claude only when the window is key. `draft.submit` changes watching to reviewing, enables inclusion/Accept
  and focuses the editor; it does not change the proposal. Before submit the same review guards apply, with
  the visible `Claude is editing, Esc to take over` notice in the panel/timeline footer. Toggling a
  checkbox recomputes with that op excluded. Group toggles validate all row ids and replay once atomically.
  Groups use fixed Cuts/Speed/Zoom/Text/Markers/Other order, omit empty kinds and start collapsed. Expanded
  rows retain individual checkboxes/skipped reasons; a row click maps its original call's clock through the
  current draft and seeks there, using the cut seam when its footage was removed.
  Accept → `endReview(commit: true, name: "Claude: <note, 40 chars>")` = one undo step. Untick everything then
  Accept 0 to close without changing the project or creating undo. `draft.discard` still restores the base;
  Escape does not discard a submitted review. No separate Discard button in the T-812 panel.
  The session's `draft.status` reports the verdict.
- Escape during watching restores the frozen human project and suppresses automatic preview for that session,
  retaining its draft in memory. Subsequent agent calls stay hidden; human edits make the old base stale.
  Explicit submit/review can show the proposal again when the base is still current. Discard/close safely ends
  the visible watch. A second Draft client may build an invisible draft but cannot submit over the current
  preview (`REVIEW_IN_PROGRESS`); its panel says the draft stays hidden. Live edits cannot bypass this lock.
- Review previews replace `model.project`; `model.liveProject` retains the saved human base until acceptance.
  Autosave/Save Now/close write only that base. Other sessions and explicit `render {draft:false}` read the live
  base; the reviewing session's default reads/renders use its checked proposal. Closing the editor restores the
  base and leaves the pending draft in memory; client disconnect also retains pending drafts until resolved.
- Replay uses the original per-call analysis and deterministic operation ids. Unchecking an operation retries the
  retained operations in each call; invalid dependents are shown as skipped with a reason, and are retried when
  their prerequisite is checked again. `draft.status` includes flat `excluded` indices, `skipped` indices/reasons,
  and the selected count. Exclusion indices refer to the complete call-ordered op list; skipped entries retain
  their per-change `reason` text. Checkboxes do not collect free-text rejection notes. Iterating a submitted
  pending draft preserves these exclusions/reasons, disables inclusion/Accept while watching, then enables
  them on resubmit. Acceptance still creates one undo step for the complete checked result.
  A stale draft stays out of preview until **Replay on current** explicitly rebases it;
  discard then restores that current human base.
- Timeline review marks while reviewing: at each cut's output position in the **draft**, a 1 pt `Theme.textPrimary`
  vertical rule across the lanes and a ruler chip `−1.7 s` (`captionFont`, `bgControl` fill); blocks added by the draft get
  a 1 pt dashed `textPrimary` outline. Pass `[(time: Double, label: String)]` and `Set<String>` (added ids) to `TimelineView`.
- Review cut marks use each call's removed clock ranges after retiming, then map into the final draft's output
  timeline. Free-retiming gaps are retained space, not cut marks; adjacent cuts at one output position share a chip.
- New block fills/outlines and cut marks reveal over320ms, with75ms lane staggering, through the existing
  drawing paths. Stable added-block/source-cut identities preserve older reveals as calls arrive. Acceptance
  closes/fades dashed outlines into normal solid block edges over220ms and removes cut marks; discard/replay
  cancels them. Reduce Motion replaces wipes/stagger/dash movement with140ms opacity. The shared display link
  stops when the finite animation ends. These states are UI-only, with no project JSON additions.
- While reviewing, timeline/inspector edits are inert (EditorModel guard) and playback/scrubbing still work.
  Destructive menus, preview gestures, media imports, voiceover, crop and export entry points are also gated.
- The summary/error/stale content scrolls while Accept stays pinned, including in a420pt panel. Disclosures
  open over320ms with55ms child stagger/4pt entrance, cancellable on close or motion-mode change. Reduce Motion
  uses140ms opacity with immediate layout changes. A prototype-only environment override supplements (never
  disables) the system Reduce Motion preference; it also permits a deterministic native reduced-motion selftest.
- Accessibility: groups use native mixed-state NSButton checkboxes, rows use labelled Toggle checkboxes, and
  disclosures/seek/Accept are named buttons with keyboard semantics.
- T-814 status/activity: tool entry creates an independently identified in-flight activity; the current
  project's latest call supplies the status intent. Completion removes only that call, appends one of the
  last200 entries, and supplies an aggregate result (op/count/delta, render count/duration, or error code).
  These strings use fixed names and numbers; they do not interpolate input text/labels/notes/paths/keys or
  raw response/error text. The collapsed project feed shows the newest50 with intent/result, then time/ms.
  The1pt rail resets at call start and draws over320ms on completion (140ms opacity for Reduce Motion);
  it represents a completed call, not a guessed percentage of the agent's total work. Idle/ready/accepted
  statuses are plain text. New groups wipe320ms; a2pt edge fades700ms. Existing groups keep their state
  as counts change. Arrivals and disclosures cancel stale tasks; shared buttons retain80ms press/160ms hover.
  Accepted groups remain readable with disabled inclusion controls and an Accepted N footer; replay resets
  the activity disclosure and cancels unfinished child reveals.
  `make gallery` → **Claude panel motion study / Open study…** opens a generated recording and the real
  inspector/preview/timeline, with Replay, Stop and a preview-only Reduce Motion toggle. Its staged operations
  now use the same production MCPTools apply/submit path; it no longer simulates propagation by swapping reviews.

**T-815 Verify.** `mcp-live <fixture> [--reduce-motion]` checks three unsubmitted calls, real preview differences,
cumulative marks and intermediate/settled timeline samples, immutable liveProject/disk/undo, pre-submit guards,
hidden competing drafts/failed submit, in-place readiness, one undo/settlement, Escape through preview/timeline/
controller, suppression/stale edits, background/Live focus and close. `mcp-live-client <generated-fixture> <out>`
runs actual Claude Code with only the generated package and an isolated stdio-to-Unix-socket relay (normal
same-binary production shim unchanged), records only its native window with `screencapture -v -l`, verifies each
of three calls before submit and the unchanged human base, decodes three distinct recorded states, then discards.
The relay/config/prompt, client JSONL, observations, PNGs and movie stay in the local output directory. Also run
`mcp-edit`, `mcp-review` normal/reduced, `mcp-panel-motion`, `mcp-render`, `mcp-export`, `project-navigation`,
`inspector-panels`, `make test` and gallery checks. The recorded study selects the Claude panel explicitly;
conditional automatic selection is checked by `mcp-live`. Native package opening canonicalizes symlink aliases
and file/directory URL forms so a client cannot silently open a second editor for the same human project.

**T-818 Verify.** `make test` covers near-edge/base-time cuts and stable ids, short/neighboring/full-removal
skips, media/output minima at mixed rates, imported clocks, speed, pause defaults/strict opt-out, word cuts,
flat JSON and atomic invalid batches. `Recorder --selftest mcp-edit --headless` checks the real MCP schema and
decoder, adjustment/warning output, frozen draft replay and skipped selection counts without creating any
application windows. Interactive `mcp-edit` is not repeated under the user's no-window/no-focus instruction.

**T-817 Verify.** `mcp-review <fixture> [--reduce-motion]` submits, unticks an operation, applies another call,
checks the same draft/operation identities and exclusions, native disabled watching controls, status reasons,
resubmission, the accepted3-of4 count and one undo to the base. A dependent-op case retains its excluded
creation and skipped update/reason across iteration, then recovers the same id when re-included.
`mcp-edit` checks successful iteration and that dry, empty or invalid calls leave submitted review unchanged.
Run both, `mcp-live` normal/reduced, `mcp-panel-motion`, `make test` and inspect the iteration panel samples.

**T-814 Verify.** `mcp-edit` asserts a3-op intent/result and absence of private recorded key/edit/marker text.
`mcp-render` checks in-flight state during an actual cancellable proxy. `mcp-panel-motion <output-directory>`
clicks native Replay/Stop/Reduce Motion, samples each of four calls mid/settled plus working/idle/error/ready/
accepted states, exercises restart/cancellation,17-op counts, base/disk isolation, one undo, concurrent activity
cleanup and sample-close cleanup. Existing `mcp-review` runs in normal/reduced motion, `inspector-panels` and
full `make test` remain required; inspect the native renders and gallery.

**Verify.** Selftest `mcp-review <package>`: submit a 3-op draft, untick one via the model API, accept → project equals
`base.applying(2 ops)` with the same operation seeds, undo restores base, `draft.status` says `accepted 2 of 3`.
Also checks disk/other-client isolation, edit/Escape guards, actual playback and scrubbing, stale rebase/discard,
dependent-operation recovery, linked/free speed + cut durations, disconnect retention and safe editor close.
It writes `/tmp/recorder-mcp-review.png` and `/tmp/recorder-mcp-review-min.png` from real review state.
`--selftest inspector-png <out.png> agent` renders the panel; `agent-short`, `agent-long`, `agent-stale`, and
`agent-error` cover overflow and feedback. **Visual review:** compare the panel against the prototype and
`build/signal-ui-gallery.png`. The user's 2026-11-15 waiver of further HUMAN visual reviews permits agent inspection;
do not describe it as a human-performed comparison or as evidence of physical recording/client integration.

### T-808 App: render `lowerThird` and `chapter`

**Files.** `Render/Compositor.swift` (`drawText`), `Inspector/TextPanel.swift` (style segment gains the two styles),
`SelfTest.swift` (parity fixture text and native render checks), `Exporter.swift` (sample fade edges in parity),
`Theme.swift` (fixed video text/plate colours), `RecorderCore/Project.swift` + `ProjectTests.swift` (lower-third default anchor).

- `lowerThird`: text block's first line = title (`headingFont`-like Barlow Semi Condensed Light at `size`), second line =
  subtitle (Andale Mono at `size*0.45`), left-aligned at `position` (default x 0.05, y 0.80) on a `#0B0B0B` @ 85 % plate
  with a 3 px `#F4F3EE` left rule; fade 0.3 s in/out using the block's edges (reuse the caption fade if one exists).
- `chapter`: full-frame `#080808` @ 72 % scrim, centred title (`size`, Barlow Light), small mono index above if the text
  starts with `"<n>\n"`; 0.3 s fade.
- Lower-third position anchors the plate's top-left, clamped inside the canvas; its omitted position defaults to
  `(0.05, 0.8)` for construction and decoding. Explicit saved positions remain unchanged. Font/plate dimensions and
  the 3 px rule scale from a 1080 px short edge, matching the existing text pass.
- Both motion styles fade linearly over 0.3 source seconds at each stored edge (short blocks use half their duration).
  The fixed video palette stays unchanged when the editor switches between light and dark appearances.
- Cache key must include style and both lines. Both are drawn in the existing text pass (render order unchanged).
  Motion-text textures are bounded to the canvas and truncate overflow; an oversized font cannot allocate an
  unbounded bitmap. Chapter titles are always centred; their position grid is hidden in TextPanel.
- TextPanel's existing style selector uses two rows for all five choices at 320 pt; lower-third positioning includes
  its default 5% left anchor. Existing style changes still validate overlap groups and form one undo step.
- Preview and export share the code (parity maxDelta 0).

**Verify.** `--selftest make-text-fixture <package> [--portrait]` writes a marked six-second package with all five
styles; it refuses to overwrite an unmarked package. Run `--selftest parity <package>` for both aspect ratios
(midpoints and both fade edges), `--selftest motion-text` for native pixel checks, `--selftest layers` for the existing
layer suite, and `make test`. The `layers` command forwards to the existing marked layer-fixture/test runner.
`motion-text` checks the 85% plate, left anchor, 72% scrim, subtitle/index cache keys, fades, appearance independence
and bounded oversized text at 16:9 and 9:16, writing `/tmp/recorder-motion-*.png`.
`--selftest inspector-png <out.png> text-lowerThird|text-chapter` captures the settled style controls.
**Visual review:** inspect both styles over actual preview frames at 16:9 and 9:16. The user's 2026-11-15 HUMAN
visual waiver permits agent inspection; no human-performed comparison is claimed.

### T-809 App: `export.final`, SRT sidecar, `ui.show`, Settings ▸ Agents

**Files.** `MCPTools.swift`, `MCPServer.swift` (keep active jobs until resolved), `EditorWindowController.swift`
(approval sheet), `App/SettingsView.swift` (Agents section), `SelfTest.swift` (export/UI/connection checks).

- `export.final`: build the same `ExportSettings` the Export sheet uses (read `ExportSheet.swift` for defaults);
  destination default `~/Movies/Recorder/Exports/<title>.mp4` (unique name). Show a native `NSAlert` **sheet** on the
  editor window: title `"claude-code wants to export"`, informative text with duration, size, preset, destination;
  buttons `Export` (default) and `Deny`. Pending > 10 min → `NEEDS_APPROVAL` timeout result. On Export run `Exporter` with
  progress notifications; if `srt` write `<name>.srt` with `srt(project)`.
  Uses the accepted live project, never an unaccepted draft; defaults come from the native Export sheet's saved
  settings, with MP4 format and valid MP4 frame rates. Overrides accept the same 720/1080/2160 short edges and
  24/30/60 fps choices. Capture the approved project/settings, then recheck access, editor identity, revision and
  review/gesture/import/voiceover state after approval. Render the frozen approved snapshot into a sibling staging
  directory; publish completed movie/SRT by non-overwriting moves, cleaning staging on denial, cancellation or
  failure. Existing movies, sidecars and destinations that appear while approval is pending are preserved.
  `render.cancel` cancels a pending approval or export; timeout also dismisses its sheet. Closing the editor during
  approval returns `NO_PROJECT`. Replies identify the exported revision and include `path`, `seconds`, `bytes`,
  optional `srtPath`, and resource links. Final exports retain the native project's configured effects/keys; agent
  inspection renders still hide key overlays.
- `ui.show {at, select}`: `model.playhead = at` (clamped), `model.selection = ids that exist`.
  Omitted fields preserve their current values; unknown ids are ignored, non-string ids are rejected. Selection
  uses the actual editor project (including an active review preview), with the usual session revision in replies.
- Settings ▸ Agents: one row per known client — v1 only **Claude Code**: status (`claude` found on PATH via
  `/usr/bin/env which claude`; installed if `claude mcp get recorder` exits 0), `Connect` runs
  `claude mcp add recorder -s user -- <Bundle.main.executablePath> --mcp` and shows its output; `Copy JSON` copies
  `{"mcpServers":{"recorder":{"command":"<path>","args":["--mcp"]}}}` for other clients. Live session list (agent name,
  project, connected since). Lookup also adds the standard user-local/Homebrew bin directories to Finder's sparse
  PATH. CLI operations run off the UI thread; termination is requested if their own child is still running after 30 seconds.
  Configured clients cannot be connected twice; Copy JSON stays available. Only connected sessions appear in this list.

**Verify.** Selftest `mcp-export <package>` injects approval callbacks, never presents an approval sheet, writes and
loads an MP4 + exact output-time SRT, and checks deny/timeout/cancel/busy, stale revision, changed access, editor close,
existing/racing destinations, unchanged project/defaults, staging cleanup, `ui.show`, draft-revision consistency, and
connection JSON/arguments. `settings-png <out.png> agents` captures the real Agents pane with a session fixture.
**Real-client/visual check:** connect from Settings, confirm nine Recorder tools in Claude Code, then run §8 on a
disposable recording: read/analyze/edit/render/submit, untick one change, accept, Undo/Redo, then approve and deny
native export sheets. Verify default unique destinations and MP4 + SRT, plus recovery from a rejected overlapping edit.
The user's 2026-11-15 waiver permits agent-driven review of this disposable workflow; do not claim a person approved
it or that generated/cached speech proves live microphone capture/on-device transcription.

### T-810 Docs and smoke

**Files.** `docs/SPEC.md` (new §10 Agents: this document's §1, §4, §5 condensed; version 5 rule in §5), `README.md`
(connect command), `CLAUDE.md` (commands: `Recorder --mcp`), `Makefile` (`mcp-smoke`: pipes the initialize + tools/list
lines from T-804 through the shim and checks for `"name":"edit"` and all nine tools), `docs/PLAN.md` Log.
The Makefile selects Testing paths from
`DEVELOPER_DIR`/`xcode-select` and uses SwiftPM's native build system, so these commands need no manual toolchain overrides.

**Verify.** `make mcp-smoke`, `make test`, `--selftest menu-actions`.

---

## 7. Edge cases checklist (each must be handled, most are one line)

- Project closed mid-session → `NO_PROJECT`. App quits → shim exits; client shows disconnected.
- Human edits while a draft exists → next `edit.apply` with the old revision gets `STALE_REVISION`; the draft itself
  still replays on review because review applies calls to the **current** project only if `base` still equals the
  current revision; otherwise review shows `Draft is based on an older version` with `Replay on current` (replays
  `calls` on `model.project`; ops that now throw are listed as skipped). The client can still `draft.discard`.
- Voiceover recording active → every edit/review tool returns `REVIEW_IN_PROGRESS`-style `PERMISSION_DENIED: recording a voiceover`.
- Project without mic → `transcript`/`cutWords`/`cutPauses`/`captions` return `NOT_TRANSCRIBED` with a clear message.
- Imported clips (`Clip.file != nil`) are never cut by `cutPauses`/`cutWords` (no transcript there).
- Multi-window recordings: frames render as today; nothing special.
- Times outside `[0, duration]` → `OUT_OF_RANGE` naming the op index.
- Two agents on one project → each session has its own draft; only one review at a time (`REVIEW_IN_PROGRESS`).
- Large transcripts: `transcript.get` without range returns at most 2,000 words plus `"truncated": true` and the next `from`.

## 8. What a finished session looks like (acceptance)

1. `claude mcp add recorder -s user -- /Applications/Recorder.app/Contents/MacOS/Recorder --mcp`
2. In Claude Code: "Open *Onboarding walkthrough*, cut long pauses and fillers, add captions and a lower third with my
   name, show me a contact sheet, then submit."
3. Recorder opens the project; the Claude tab shows activity; Claude reads, edits, renders, fixes an overlap, submits.
4. The human unticks one change, presses Accept; one undo step `Claude: …` appears; ⌘Z restores the original.
5. "Export it" → native sheet → Export → MP4 (+ SRT) in `~/Movies/Recorder/Exports/`.


## 9. Completion evidence — 2026-11-16

Compared the implementation with the freshly read prototype **version 2**: its decisions, nine tools,
19 in-scope capability rows, flows and T-801…T-810 roadmap are covered. No MCP SDK or third-party package was added.
The per-task evidence is recorded in [PLAN.md](PLAN.md#log); this table maps the prototype to those checks.

| Prototype capability | Implementation and evidence |
|---|---|
| Timeline/transcript data, word IDs, fillers, output clocks | T-801; AgentViews tests, `mcp-roundtrip`, actual Claude Code timeline/transcript/filler reads |
| Cut/split/ripple/speed, word/pause cuts, captions, zoom/cursor, highlights/style | T-802/T-806; EditOps tests, `mcp-edit`, actual client atomic-overlap rejection/retry and pause/filler/caption edits |
| Markers, SRT, conditional version 5 | T-803; ProjectTests/EditOps, native MP4/SRT checks and decoded real-client export |
| Lower thirds/chapter cards | T-808; `motion-text`, inspected native frames/inspector; preview/export `maxDelta=0` at 24 times each in 16:9 and 9:16 |
| Same-binary shim, nine tools, access, privacy and activity | T-804; `mcp-roundtrip`; T-810 `make mcp-smoke` initializes the packaged app and asserts protocol plus all nine tools |
| Frames, contact sheet, 540p proxy, progress/cancel, cache | T-805; `mcp-render` checks pixel parity, key suppression, order, audio/imports/tails, links, progress/cancel and retention; actual client rendered frames/sheets |
| Draft review, per-change inclusion, stale replay, live undo | T-806/T-807; `mcp-edit`/`mcp-review`, inspected native layouts; actual Claude draft followed by native untick/Accept/Undo/Redo |
| Final approval, MP4/SRT, client setup, UI navigation | T-809; `mcp-export` checks denial/timeout/cancel, races/collisions, stale/access guards, output decoding and presets; actual Settings Connect and Claude Code Export/Deny workflow |
| Documentation and repeatable checks | T-810; plain `make build`, `make mcp-smoke`, `make test` (190/190), packaged-app `--selftest menu-actions`, diff check |

The actual-client acceptance used Claude Code 2.1.325 with a disposable generated recording and cached words.
A native checkbox excluded one of four proposed edits; accepting three produced 2.775 seconds, and one native
Undo restored the original project. The approved 1280×720/24fps movie decoded with audio and the expected text;
its duration was 2.791667 seconds after frame rounding. A second native approval was denied and wrote no files.
The user waived HUMAN visual gates; these were agent-driven native checks, not a person's approval.

Verification limits: fresh microphone capture and positive on-device transcription were not repeated; the existing
on-device transcription engine is reused. Lexical filler detection can only flag words present in its transcript.
Drafts were memory-only at that time (persisted since T-825); the shim requires client reconnection after app exit, and long draft replay remains
uncached as documented in source. The native SwiftPM build system is currently required on this toolchain and is
deprecated upstream; the Makefile honors `DEVELOPER_DIR`, with Xcode and CLT Testing-path selection checked.
This completion covers the prototype's MCP scope, including its explicit exclusions in §1; unrelated older
repository milestones retain their existing status.

## 10. Agent eval (T-833)

`scripts/agent-eval.py` scores MCP client transcripts for the brief **"30 s reel, fast cuts, no text"** over a set of
recordings. Run it on every MCP change. Input is JSONL, one JSON-RPC message per line, as a stdio relay logs it
(`tools/call` requests and their responses). Label = file name without `.jsonl`.

```
scripts/agent-eval.py run1.jsonl run2.jsonl ...         # table: calls, ops, images, lint PASS/FAIL, final duration, pref
scripts/agent-eval.py --json --pref run1=0.7 run*.jsonl  # + JSON summary; --pref is the manual human-vs-hand-edit score
scripts/agent-eval.py --selftest                         # asserts metrics on built-in synthetic transcripts
```

Metrics: `ops` = ops of `edit.apply` calls with `dryRun` false that succeeded; `images` = image items of `render.*`
responses, counting `at` length or `count` from the args. Lint passes when the last successful report outside
a dry run has no `error` or `warn` item in `structuredContent.report.lint`. Older logs may have a top-level
`structuredContent.lint` array. The summary lint rate uses transcripts with a verdict.

## 11. Agent recording

Use one window and demo data. Mark each step before the action, use `retake: <step>` for retries and mark `result`
once the final state is visible. Stop the take before editing. See the [recording guide](RECORDING-AGENT.md) for the
action arguments, consent rules and demo script. For an eval, wrap the shim with
`scripts/mcp-log.py <out.jsonl> -- <Recorder binary> --mcp`. The local transcript can contain window titles,
project paths and rendered images. Inspect it before sharing.

For a driver that leaves no mouse events, add `x`, `y` and `pointerAction` together to a `record.mark` call.
Coordinates use global screen points with a top-left origin. The action is `click`, `doubleClick` or `move`.
Declarations affect the recorded pointer only. Marks outside the target or during a pause keep the label and omit
the pointer event, and a nearby captured click supersedes a declared click.

When a draft is submitted in the background, Recorder requests Dock attention and can show a macOS notification
with the project title, client name and change count. Clicking it opens the Claude review.

After `analyze.shots`, `edit.apply` with `{"op":"steps"}` keeps each marker and its following activity, removes
waits longer than two seconds, and cuts failed attempts before their `retake: <step>` markers. Use `dryRun:true`
to inspect the lowered cuts. Set `lead`, `settle` or `maxGap` in output seconds, or use `protect` for shots
that must stay intact. `steps` and `pace` need separate calls.
