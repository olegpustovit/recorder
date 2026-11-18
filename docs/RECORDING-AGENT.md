# Agent recording — implementation guide (T-950…T-956)

Status: T-950 through T-952 verified. The T-953 live eval is staged on the Mac mini and awaits computer-use approval.
See `docs/PLAN.md` for progress and `CHECKPOINT.md` for the staged session.
Proposal: https://artifacts.microapps.space/a/d0rs3s43x727

This guide is for an implementing agent (Codex or any model). It says **what** to build, **where**, **with which existing
code**, and **how to prove it**. Read §0–§4 once, then do the tasks in §5 strictly in order, one per session, following
`docs/PLAN.md` §0 Protocol and `CLAUDE.md`. Code-block signatures are **normative** (names, parameters, types); bodies are
yours. If the code contradicts this guide, the code wins: write `BLOCKED: …` under the task in PLAN.md and ask.

---

## 0. Goal in one paragraph

An MCP client that can also operate the Mac through **its own** computer-use tool (Claude Code computer use, cua-driver
MCP, OpenClaw, Codex computer use) records a **silent screen demo with no person present**. It lists capture targets,
starts a recording, performs the demo with its driver, and labels each step with `record.mark` while recording. Then it
stops the recording, which opens an ordinary Recorder project in the editor. The agent edits that project with the
existing MCP v2 tools (`analyze.shots`, `edit.apply` with cuts anchored on its markers, `pace`, text and graphics,
`render.lint demo`) and hands the human a draft through `draft.submit`. The human reviews and accepts it in the Claude
tab. **Recorder never moves the mouse or types.** It only captures the screen, records events and stores markers.

## 1. Decisions (fixed for this plan)

| # | Decision | Consequence for the code |
|---|----------|--------------------------|
| R1 | **Driver-agnostic.** Recorder exposes no input or click tool. | No `record.act`. `UIDriver` stays a dev-only selftest tool. |
| R2 | **Silent video only.** Agent recordings have no mic, camera or system audio, and no countdown. | The agent path builds its own `RecordingSettings` copy with `micID = nil`, `cameraID = nil`, `systemAudio = .off`, `countdown = 0`. The user's saved toolbar settings are never written. |
| R3 | **Consent.** The first `record.start` in each MCP session shows a native approval alert ("Allow for this session" / "Don't Allow"; ten-minute timeout). A new Settings ▸ Agents toggle, **"Let agents start recordings without asking"** (off by default, `UserDefaults` key `agentRecording.allowWithoutAsking`), skips the alert so a dedicated machine can run unattended. | `MCPSession.recordingApproved: Bool`. The approval closure can be injected for selftests, like `approveExport`. |
| R4 | **One recording at a time, owned by one session.** Only the session that started it can `mark`, `pause`, `resume` or `stop` it. Others get `RECORDING_BUSY`. A human recording in progress also gives `RECORDING_BUSY`. | `RecordingController.agentOwner: String?` (MCP session id). |
| R5 | **The human stays in control.** The normal recording widget and highlight stay visible. The human can stop, pause, restart or delete at any time. If the human stops it, the take is kept and `record.status` / `record.stop` return that project. | No hidden capture mode. `RecordingController.lastAgentPackage` remembers the finished package for the owner session. |
| R6 | **Safety stops.** `maxDuration` (default 600 s, 10–1800) finishes the recording automatically. If the owner session disconnects mid-recording, the recording **finishes** (it is kept, never discarded). | A token-checked `Task.sleep` in `RecordingController`, plus a disconnect hook in `MCPSession`. |
| R7 | **Markers are ordinary `Project.markers`** at source seconds. In a fresh recording, source time = output time = `RecordingController.elapsed`. The agent anchors edits on them with the existing `{marker: id|label, offset}`. | No `Project` format change and no Core change for markers. Label conventions (see §3.3) are guidance only. |
| R8 | **Default target is one window**, optionally resized to an exact size. Display and area targets accept `exclude: [bundleId]`. | The `CaptureTarget.filter` display/area branch also excludes those apps. |
| R9 | **Errors never hang the agent.** The agent path presents no `NSAlert` except the consent alert (R3). Capture failures throw `MCPFailure`, and the package is kept for recovery where the human path keeps it. | `finishCapture(presentErrors:)` gains a throwing variant. |
| R10 | **Keys stay local** (unchanged). `record.*` never returns events or key data. Agent renders already hide key chips. | Nothing new to filter. Don't add event output to any `record` result. |

Out of scope (do **not** build): Recorder-driven input, multi-take assembly, voice-over/TTS, camera or mic in agent
recordings, a new `Project` field for marker kinds, a headless editor, scheduling or cron, cloud upload.

## 2. Architecture

```
Claude Code ──stdio──▶ Recorder --mcp ──unix socket──▶ Recorder.app
   │ computer-use tool (separate MCP / built-in)          ├─ Agent/MCPTools.swift      + tool "record" (schema, handler, hints)
   │   clicks/types in the target app                     ├─ Agent/MCPServer.swift     + MCPSession.recordingApproved, disconnect hook
   ▼                                                      ├─ Recording/RecordingController.swift  + agent start/finish, markers, owner
 macOS apps  ◀── captured by ScreenCaptureKit ────────────├─ Recording/RecordingSettings.swift    + agent copy, excludedBundleIDs
                                                          ├─ Recording/CaptureTarget.swift        + exclude bundle ids
                                                          ├─ Recording/EventRecorder.swift        (T-954) agent pointer events
                                                          └─ App/SettingsView.swift (AgentsPane)  + consent toggle
RecorderCore: Events.swift (T-954 merge function + tests). Nothing else in Core changes.
```

Flow of one agent recording:

```
record.targets ─▶ record.start ─(consent once)─▶ RecordingController.beginForAgent ─▶ state .recording
   driver acts … record.mark ×N (… record.pause/resume) …
record.stop ─▶ RecordingController.finishForAgent ─▶ project.json (+ markers) ─▶ EditorWindowController.open
           ─▶ session.projectURL = package ─▶ same payload as project.open (+ markers) ─▶ normal edit loop
```

## 3. Tool surface: one new tool, `record`

Add it to `MCPTools.list`, `MCPTools.handled`, `activityIntent`, `activityResult` and `hints`. It is the 10th tool.
`schemaVersion` is a hash of `list`, so clients get `tools/list_changed` automatically.

### 3.1 Schema (flat, like the other tools; `tool(...)` helper)

```swift
tool("record", ["targets", "start", "status", "mark", "pause", "resume", "stop"],
     "Record the screen while your own computer-use tool performs a demo (Recorder never clicks or types). targets lists displays and windows; start needs exactly one of window or display (area needs display) and asks the user once per session; mark labels the current moment (use the returned marker id as an edit anchor later); stop finishes, opens the project and returns what project.open returns. Video only: no mic, camera or system audio.",
     ["window": ["type": "integer", "minimum": 0],
      "display": ["type": "integer", "minimum": 0],
      "area": ["type": "object", "properties": ["x": number, "y": number, "width": number, "height": number],
               "required": ["x", "y", "width", "height"], "additionalProperties": false],
      "width": ["type": "integer", "minimum": 320, "maximum": 7680],
      "height": ["type": "integer", "minimum": 240, "maximum": 4320],
      "exclude": ["type": "array", "items": string, "maxItems": 20],
      "title": ["type": "string", "maxLength": 80],
      "maxDuration": ["type": "number", "minimum": 10, "maximum": 1800],
      "label": ["type": "string", "minLength": 1, "maxLength": 80],
      "discard": boolean])
```

`read:` stays false (`destructiveHint: false`). Check that `schemaViolation` handles the nested `area` object. If it
doesn't, extend `schemaViolation` once (root-cause rule) and don't special-case `record`.

Add `outputFields["record"]`, as for the other tools, with the result keys below.

### 3.2 Actions

Coordinates are **global display points, top-left origin** (the same space as `SCWindow.frame` and CGEvent), which is
what computer-use tools report. Times are seconds since the first recorded frame, with paused time already removed. The
same number becomes the output time in the new project.

| Action | Args | Result | Errors |
|---|---|---|---|
| `targets` | — | `{displays:[{id,width,height,main}], windows:[{id,app,bundleId,title,x,y,width,height,display}]}` | `PERMISSION_NEEDED` |
| `start` | `window` \| `display` (+ `area`), `width`+`height` (window only, both or neither), `exclude` (display/area only), `title`, `maxDuration` | `{state:"recording", target:"<targetDescription>", maxDuration, at:0}` | `PERMISSION_NEEDED`, `NO_TARGET`, `RECORDING_BUSY`, `NEEDS_APPROVAL`, `DENIED`, `INVALID_OP`, `RECORDING_FAILED` |
| `status` | — | `{state, at, markers, owner:"you"\|"other"\|"user"\|null, maxDuration?, project?}`. `project` is the package's project id once this session's recording has finished | — |
| `mark` | `label` | `{marker:"<id>", at}` | `NOT_RECORDING`, `RECORDING_BUSY` (not owner), `OUT_OF_RANGE` (more than 500 markers) |
| `pause` / `resume` | — | `{state, at}` | `NOT_RECORDING`, `RECORDING_BUSY` |
| `stop` | `discard` (default false) | Not discarded: the `project.open` payload plus `markers:[{id,at,label}]`. Discarded: `{discarded:true}` | `NOT_RECORDING`, `RECORDING_BUSY`, `RECORDING_FAILED` |

Rules:

- `targets` windows: on-screen windows from `SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)`
  where `windowLayer == 0`, `width ≥ 120`, `height ≥ 80`, and the owning app is **not Recorder** (pid ≠ own pid). Return
  at most 100, sorted by app then title. `display` = id of the display containing the window's centre. `main` = the
  display whose frame origin is (0,0).
- `start` validation, in order: unknown or mixed target args → `INVALID_OP`. Missing grants (`Permissions.allGranted`)
  → `PERMISSION_NEEDED`. `RecordingController.shared.state != .idle` → `RECORDING_BUSY`. Re-fetch shareable content and
  resolve the id → `NO_TARGET` if it's gone or minimized. An area must lie inside its display (points, top-left, relative
  to that display) → else `OUT_OF_RANGE`. Then consent (R3), then `beginForAgent`.
- `width/height` on a window: `WindowResizer.focus(...)`, then `WindowResizer.resize(pid:windowTitle:to:)`. Wait 300 ms,
  then **re-fetch** the `SCWindow`, because its frame changed and `CaptureTarget` reads the frame. If the new size is off
  by more than 2 pt (the app refused the size), continue anyway and return `size:{width,height}` with the actual size.
- `title` → after finish, `Project.title` is this string (the package name stays from `ProjectStore.newProjectURL`).
- `stop` on a recording the **human** already finished (state `.idle`, `lastAgentPackage` set for this session) returns
  the same open payload. This makes it idempotent.
- `mark` while paused is allowed (`at` is frozen at the pause point).
- `activityIntent`: `"Listing capture targets"`, `"Starting recording"`, `"Checking recording"`, `"Marking step"`,
  `"Pausing recording"`, `"Resuming recording"`, `"Stopping recording"`. **Never log the label text** (activity rows hold
  fixed strings only; see the existing comment above `activityIntent`). `activityResult`: e.g. `"12 windows"`,
  `"Recording"`, `"Marker 4"`, `"38.2 s, 6 markers"`.

New `hints` entries:

```swift
"PERMISSION_NEEDED": "Ask the user to grant Recorder Screen Recording and Accessibility in System Settings ▸ Privacy & Security, then retry",
"NO_TARGET": "Call record.targets again and use a current window or display id; the window must be on screen",
"RECORDING_BUSY": "Another recording is running (the user's or another session's); wait for it to end or ask the user",
"NOT_RECORDING": "Call record.start first; record.status shows the current state",
"RECORDING_FAILED": "Recording could not start or finish; the user can recover the package from Recorder; tell them before retrying",
```

`NEEDS_APPROVAL` and `DENIED` already exist and are reused unchanged.

### 3.3 Agent guidance (goes into MCP.md and the `instructions` text)

Append to `MCPTools.instructions` (and MCP.md §5.0 verbatim):

> To make a demo yourself: record.targets → record.start {window} → drive the app with your own computer-use tool,
> calling record.mark {label} when each step begins → record.stop (opens the project) → edit as usual: cut from a
> step's settled end to the next step's mark, label steps with text, pace demo, render.lint demo, then draft.submit.

Label conventions (guidance, not parsed): one mark **before** each visible action, labelled with the step ("Open
Settings"). After a failed attempt, mark `"retake: <step>"`, then cut from the failed step's marker to the retake marker.
Mark `"result"` when the final state is on screen.

## 4. Existing code to reuse (read before the task that uses it)

| Need | Use | File |
|---|---|---|
| Start/finish/pause, widget, highlight, dock policy | `RecordingController` (`start`, `finishCapture`, `pause`, `resume`, `cancel`, `reset`) | `Recording/RecordingController.swift` |
| Capture target and filter | `CaptureTarget.display/.windows/.area`, `filter(content:settings:)`, `targetDescription` | `Recording/CaptureTarget.swift` |
| Clock | `RecordingController.elapsed` (= `CaptureSession.elapsed`, pause-aware) | `Recording/CaptureSession.swift` |
| Window focus/resize | `WindowResizer.focus(pid:windowTitle:frame:)`, `.resize(pid:windowTitle:to:)` | `Recording/WindowResizer.swift` |
| TCC check | `Permissions.allGranted` | `App/Permissions.swift` |
| Marker model | `Marker(time:label:)`, `Project.markers` (source seconds) | `RecorderCore/Project.swift` |
| Open project + payload | `project.open` branch in `MCPTools.call` (extract it, §5 T-951) | `Agent/MCPTools.swift` |
| Approval pattern + timeout | `exportFinal` (task group + `Task.sleep`), `approveExport` injection | `Agent/MCPTools.swift`, `Editor/EditorWindowController.swift` |
| Errors | `MCPFailure(code:message:)`, `hints` | `Agent/MCPTools.swift` |
| Session identity/teardown | `MCPSession.id`, `.agentName`, connection close path | `Agent/MCPServer.swift` |
| Settings UI | `AgentsPane` | `App/SettingsView.swift` |
| Selftest registry | case table near `"mcp-export"` / `"mcp-serve"` (**duplicate keys trap the whole table**) | `App/SelfTest.swift` |
| Eval scoring | `scripts/agent-eval.py <jsonl>` (transcript format: one JSON-RPC message per line) | `scripts/` |

## 5. Tasks

Do them strictly in order. Each one ends with its Verify step run for real, then a tick, a Status table bump, a Log
line and a commit `T-9xx <title>`.

### T-950 App: agent recording path in `RecordingController`

Files: `Recording/RecordingController.swift`, `Recording/RecordingSettings.swift`, `Recording/CaptureTarget.swift`,
`App/SelfTest.swift`.

1. `RecordingSettings`: add a non-persisted stored property and an agent copy initializer. Assignments inside `init`
   don't fire `didSet`, so nothing is written to `UserDefaults`:

   ```swift
   /// Not persisted: set only on agent copies (R8).
   var excludedBundleIDs: [String] = []
   /// T-950: a throwaway copy for an agent recording (R2). Never `.shared`, never persisted.
   init(agentCopyOf base: RecordingSettings, excludedBundleIDs: [String])
   ```

   The copy takes every field from `base` except `micID = nil`, `cameraID = nil`, `systemAudio = .off`, `countdown = 0`,
   and `excludedBundleIDs` from the argument. Keep `private init()` for `.shared`.
2. `CaptureTarget.filter`: in the display/area branch, exclude
   `content.applications.filter { settings.excludedBundleIDs.contains($0.bundleIdentifier) }` alongside `ownApps`.
3. `RecordingController`: refactor, without changing the human behaviour:

   ```swift
   private(set) var agentOwner: String?          // MCP session id while an agent recording runs (R4)
   private(set) var lastAgentPackage: (owner: String, url: URL)?
   private(set) var markers: [Marker] = []
   private(set) var maxDuration: Double?
   private var recordingToken = UUID()
   private var currentSettings: RecordingSettings?  // what `restart()` re-uses
   private var agentTitle: String?

   /// T-950 agent path (R2, R9): no toolbar, countdown, camera or alerts; throws instead.
   func beginForAgent(target: CaptureTarget, settings: RecordingSettings, owner: String,
                      title: String?, maxDuration: Double) async throws
   /// Appends a marker at `elapsed` (R7). Only valid in .recording/.paused.
   func addMarker(label: String) -> Marker
   /// Finishes like the widget's Finish but throws instead of alerting; returns the package.
   func finishForAgent() async throws -> URL
   ```

   - Extract the shared body of `start(target:isRestart:restartCamera:)` (from `showHighlight` to setting
     `state = .recording`) into `private func capture(target:settings:camera:) async throws`. `start` keeps its
     camera-check alert, toolbar close/show, countdown and error alert around it. `beginForAgent` calls `capture` directly
     with `camera: nil`. On failure it hides the highlight and widget, removes the empty package (as `start` does), sets
     `state = .idle` and throws `MCPFailure(code: "RECORDING_FAILED", …)`.
   - `beginForAgent` guards `state == .idle` (→ `RECORDING_BUSY`) and `Permissions.allGranted` (→ `PERMISSION_NEEDED`).
     It sets `state = .countdown` **before** the first `await` (reserve the transition, like `begin`), and sets
     `agentOwner`, `agentTitle`, `maxDuration` and a new `recordingToken`. It schedules
     `Task { try? await Task.sleep(for: .seconds(maxDuration)); if token matches and state is .recording/.paused { finish() } }`.
     Elapsed time includes pauses, so the cap is wall-clock-ish. That's fine and should be documented in a comment.
   - `finishCapture`: change to `private func finishCapture(presentErrors: Bool) async throws -> URL?`. With
     `presentErrors: true` (human widget, status menu, hotkeys) it alerts exactly as today and returns nil
     on error. Agent-owned finishes, including widget, disconnect and max-duration stops, pass `false` (R9). With `false` it throws `RECORDING_FAILED` at the same points and keeps the package. Before
     `project.save`: `project.markers = markers` and `if let agentTitle { project.title = agentTitle }`. After save, if
     `agentOwner != nil`, set `lastAgentPackage = (agentOwner!, packageURL)`. `finish()` keeps its signature
     (`Task { _ = try? await finishCapture(presentErrors: agentOwner == nil) }`).
   - `reset()` clears `agentOwner`, `markers`, `maxDuration`, `agentTitle`, `currentSettings` (not `lastAgentPackage`).
   - `restart()` re-uses `currentSettings ?? .shared` and keeps the owner. Markers are cleared because the take restarts.
   - `finishCapture` reads `RecordingSettings.shared.denoise`. Leave it: agent recordings have no mic.
4. Selftest `record-agent` (window-free, in `SelfTest.swift`): requires `Permissions.allGranted`, else prints
   `SKIP: needs Screen Recording + Accessibility` and exits 0. Steps:
   - Record the main display **area** `{0,0,400,300}` with `exclude: ["com.apple.finder"]` through `beginForAgent`,
     `title: "record-agent selftest"`, `maxDuration: 30`.
   - Wait until `elapsed` reaches 1.0 s (the first frame can precede `startCapture` returning), `addMarker("one")`, pause 0.5 s, `addMarker("paused")`, resume, wait 0.5 s, `addMarker("two")`, then
     `finishForAgent()`.
   - Assert: `project.json` loads, title matches, three markers with increasing times, the `paused` marker's time equals
     `one + ~0` (frozen; within 0.6 s of `one` and ≤ `two`), `source.duration` ≈ 1.5 ± 0.4 s, `hasMic == false`, no
     `camera.mov`, and `UserDefaults` `recording.countdown`/`recording.micID` unchanged.
   - Also assert a second `beginForAgent` while recording throws `RECORDING_BUSY`.
   - Close the editor window the finish opened, then move the package to the Trash (`FileManager.trashItem`).

**Verify:** `make build`; `build/Recorder.app/Contents/MacOS/Recorder --selftest record-agent` (after `make app`; quit a
running source-build app first) prints OK; `--selftest menus` and `--selftest menu-actions` still OK (the human path is
unchanged); `make test`. Note in the log whether `record-agent` ran or SKIPped. If it SKIPped, the task is `- [~]` with
a HUMAN note "grant permissions and re-run".

### T-951 App: MCP `record` tool, consent, disconnect, Settings toggle

Files: `Agent/MCPTools.swift`, `Agent/MCPServer.swift`, `Recording/RecordingController.swift`,
`App/SettingsView.swift`, `App/SelfTest.swift`.

1. Schema/handled/intent/result/hints as in §3. Add `"record.targets"…"record.stop"` to `MCPTools.handled` (the
   `mcp-schema` selftest diffs it).
2. Extract the `project.open` branch body into
   `@MainActor private static func openProject(url: URL, session: MCPSession) async throws -> [String: Any]` and call it
   from `project.open` and `record.stop`. Behaviour stays unchanged (access check, draft adoption, revision, draft
   summary).
3. In `call`, add `else if name == "record" { payload = try await record(action, args, session: session, approve: approveRecording, approvalTimeout: approvalTimeout) }`
   **before** the `model(for:)` branch, because `record` needs no open project. Add a parameter to `call`:

   ```swift
   approveRecording: (@MainActor (AgentRecordingRequest) async throws -> Bool)? = nil
   ```

   and in `MCPTools.swift`:

   ```swift
   struct AgentRecordingRequest { let client: String; let target: String; let maxDuration: Double }
   @MainActor private static func record(_ action: String, _ args: [String: Any], session: MCPSession,
       approve: (@MainActor (AgentRecordingRequest) async throws -> Bool)?, approvalTimeout: Duration) async throws -> [String: Any]
   ```

   For `record.stop`, set `session.projectURL` through `openProject`, so the outer `session.projectURL != nil` epilogue
   fills `project`/`revision` as it does for `project.open`. For the other actions with no open project, the epilogue
   already writes `project: null, revision: null`. That's fine.
4. Consent (R3): `MCPSession.recordingApproved = false` per session. On `start`: if
   `UserDefaults.standard.bool(forKey: "agentRecording.allowWithoutAsking")` or `recordingApproved`, skip the prompt.
   Otherwise race `approve ?? RecordingController.approveAgentRecording` against `Task.sleep(for: approvalTimeout)`
   exactly like `exportFinal` (timeout → `NEEDS_APPROVAL`, false → `DENIED`). Re-check `state == .idle` after approval.

   ```swift
   /// R3 consent alert. App-modal (no editor window exists yet); activates Recorder first.
   static func approveAgentRecording(_ request: AgentRecordingRequest) async throws -> Bool
   ```

   Body: build an `NSAlert` with messageText `"\(client) wants to record your screen"` and informativeText
   `"Target: \(target). Video only, up to \(Int(ceil(maxDuration/60))) min. You can stop it from the recording widget at any time."`,
   and buttons "Allow for This Session" (first) and "Don't Allow". `NSApp.activate()`, `alert.layout()`, then
   `NSApp.beginModalSession(for: alert.window)`; run `NSApp.runModalSession` passes with an awaited 20 ms sleep between
   them. Always end the session and order out the window in `defer`. Check cancellation between passes; `.abort` →
   `CancellationError`. This keeps native app-modal behavior while letting MCP calls, the approval timeout and
   disconnect cancellation run. **Verified correction to the original guide:** `runModal()` inside a main-actor Task
   blocked a real socket `ping` after disconnect; the yielding modal session passes the native timeout, Don't Allow,
   status and disconnect checks. [AppKit modal sessions](https://developer.apple.com/documentation/appkit/nsapplication/runmodalsession(_:))
   explicitly support work between event passes. No hidden parent window or custom dialog is needed.
5. Disconnect (R6): factor `func sessionEnded(_ session: MCPSession)` in `MCPServer.swift`. Set `connected = false`,
   cancel `recordingApprovalTask`, and, when this session owns capture, call `RecordingController.shared.finish()`.
   Invoke it from the connection reader's EOF callback **before** waiting for pending replies, so a slow request cannot
   delay the safety stop. Remove finished sessions after pending replies drain. The controller remembers a finish
   requested during startup/restart; the selftest calls the same hook in approval, startup and recording states.
6. Settings ▸ Agents (`AgentsPane`): one `Toggle("Let agents start recordings without asking", isOn: …)` bound to the
   `UserDefaults` key through `@AppStorage("agentRecording.allowWithoutAsking")`, with the footnote
   `"Agents still can't hear audio or read your keystrokes. The recording widget stays visible."`.
7. Selftest `mcp-record` (skips like `record-agent` without grants). Drive `MCPTools.call` with a real `MCPSession` (as
   `checkMCPExport` does) and an injected `approveRecording` that counts calls and returns true:
   - `record.targets` returns ≥1 display, and no window has Recorder's bundle id.
   - `record.start {display: main, area:{0,0,400,300}, title:"mcp-record"}` asks once.
   - `record.status` gives `owner:"you"`.
   - A second session's `record.mark` → `RECORDING_BUSY`.
   - `mark "one"`, then `pause`, `resume`, then `mark "two"`.
   - `record.stop` returns `project`, `revision`, `duration > 0`, and `markers` with labels `["one","two"]`. Then
     `timeline.get` shows both markers, and an `edit.apply` `cut {from:{marker:"one"}, to:{marker:"two"}}` dry-run
     resolves.
   - A second `record.start` in the same session doesn't ask again (approve count still 1).
   - Stop it with `discard:true` → `{discarded:true}`, and no new package remains.
   - A new session with an injected `false` → `DENIED`.
   - An injected approval that sleeps, with `approvalTimeout: .milliseconds(200)` → `NEEDS_APPROVAL`.
   - Owner disconnect: start, simulate the session teardown hook, then assert the state reaches `.idle` and
     `lastAgentPackage` is set.
   - `maxDuration: 10` is accepted (don't wait for it). The timer is covered by `record-agent-cap` below.
   - Clean up: close the editors and trash the packages.
   - Add `record-agent-cap`: `beginForAgent(maxDuration: 10)`, then wait up to 15 s for `.idle` and assert that a
     package exists. Keep this separate because it's slow.

**Verify:** `make app`; `--selftest mcp-record`, `--selftest record-agent-cap`, `--selftest mcp-schema`,
`--selftest mcp-export` (approval pattern untouched), `--selftest mcp-roundtrip <fixture>`; `make test`.
Also run `--selftest mcp-record --native` (real native timeout, Don't Allow, responsive status, disconnect cancellation,
and Allow followed by a silent capture that is immediately discarded) and inspect its own-window
`/tmp/recorder-t951-consent.png`. Render
`--selftest settings-png <out> agents` and inspect the toggle. HUMAN (waivable): see the real consent alert once by
running `scripts/mcp-record-demo.sh`, defined in T-952. The user waived this remaining visual check on
2026-11-18 after the native functional checks passed; no further consent-visual sign-off is pending for T-951.

### T-952 Docs, smoke, demo script

1. `Makefile` `mcp-smoke`: expect **10** tools and add `"record"` to the name set. Change the message to "all ten
   tools".
2. `docs/MCP.md`: a new §5.1 row for `record`, §5.0 instructions text (with §3.3's appended paragraph), new error codes
   in the error table, and a short "§11 Agent recording" pointing here.
3. `docs/SPEC.md` §10: "ten tools", plus a subsection **Agent recording** that copies R1–R10 in prose (consent,
   visibility, safety stops, keys stay local) and the Settings toggle. Answer, or add to SPEC §9 open questions, "Does
   macOS 27 still re-prompt ScreenCaptureKit apps periodically?" Record the answer in T-953.
4. `README.md` (nine → ten tools, one sentence on agent recording) and the `CLAUDE.md` command list (new selftests).
5. `scripts/mcp-record-demo.sh`: a bash script that pipes JSON-RPC through `Recorder --mcp`. It runs `initialize`,
   `record.targets`, `record.start` on the main display area `{0,0,800,600}`, sleeps 3 s, `record.mark "demo"`, sleeps
   2 s, `record.stop`, and prints the project id. Use Python only as `mcp-smoke` does, for JSON. This shows the real
   consent alert to a human and is the HUMAN step for T-951.
6. `scripts/mcp-log.py <out.jsonl> -- <Recorder binary> --mcp`: a transparent stdio relay (stdlib only). It spawns
   the command, copies stdin→child and child→stdout unchanged, and appends every line from both directions to
   `<out.jsonl>` as-is, in the format `scripts/agent-eval.py` reads. Register it as the MCP command for the T-953 run
   (`claude mcp add recorder-eval -- python3 scripts/mcp-log.py … -- …/Recorder --mcp`). The T-940 relay lived in a
   scratchpad, so this makes it reproducible. Self-check: pipe `initialize` through it as `mcp-smoke` does, and assert
   that the log has 2 lines.

**Verify:** `make mcp-smoke` passes with 10 tools; `bash -n scripts/mcp-record-demo.sh`; the `mcp-log.py` self-check; `make test`.

### T-953 Live eval: an agent records and edits a silent demo (Mac mini)

Run on `olegs-mac-mini`, as in the T-940 evals. HUMAN prerequisites, done once by a person (mark `- [~]` until done):
Screen Recording + Accessibility for Recorder and for the driver, and Claude Code computer use enabled in an
**interactive** session (`/mcp` → computer-use; it doesn't work with `-p`).

1. Brief, given verbatim to the agent: "Using TextEdit, record a ~30 s silent demo: create a document, type a heading,
   make it bold, change its size to 36. Use record.* for capture and your computer-use tool for actions; mark each step;
   then edit it into a tight demo with step titles; render.lint demo must be clean; draft.submit; don't export."
2. Log the MCP traffic with `scripts/mcp-log.py` (T-952), save it to
   `docs/evals/textedit-silent-demo.jsonl` (no key events are in MCP traffic), and run
   `scripts/agent-eval.py docs/evals/textedit-silent-demo.jsonl`.
3. Record in the Log:
   - calls, ops, images, raw vs final duration, and lint result
   - whether clicks produced auto-zooms (look at `timeline.get` zooms)
   - whether the cursor was visible and moved, judged from `render.strip`
   - how many manual `cut`s the agent needed per step
   - whether a consent prompt or macOS re-consent prompt appeared
4. Answer SPEC §9's re-prompt question from what happened.

**Verify:** `agent-eval.py` output in the Log; the draft is visible in the Claude tab (`scripts/ui.sh screenshot <out.png>`, inspected); `render.lint demo` reports no warnings. If the cursor didn't move or zooms are
missing because the driver doesn't post mouse events, T-954 is required. Otherwise it's still done for robustness.

### T-954 Core + app: agent pointer events for Accessibility-only and background drivers

Problem: drivers that press buttons through Accessibility (cua-driver, Peekaboo, Claude background mode) post **no
mouse events**, so `events.json` has no moves or clicks. The cursor stays frozen and there are no auto-zooms. (Cursor
**position** comes only from the event tap. The 60 Hz timer only logs cursor *image* changes.)

1. `record.mark` gains optional `x`, `y` (global points) and
   `action: "click"|"doubleClick"|"move"` (schema: `x`/`y` number, `action` enum). `action` requires `x` and `y`. Target
   must not be multi-window, which agent recordings never are.
2. Core, `RecorderCore/Events.swift`:

   ```swift
   public enum AgentPointer: String, Codable, Sendable { case click, doubleClick, move }
   extension EventLog {
       /// T-954: adds agent-declared pointer actions (normalised x/y, output seconds) where the real log has
       /// no matching event: a click is dropped if a real left `.down` lies within ±0.25 s and 0.03 (normalised)
       /// of it. Each kept action becomes `.move` at t, then `.down`/`.up` at t+0.05/t+0.12 (doubleClick: a second
       /// pair at +0.20/+0.27); `move` becomes a single `.move`. Result stays sorted by t.
       public func mergingAgentPointer(_ actions: [(t: Double, x: Double, y: Double, action: AgentPointer)]) -> EventLog
   }
   ```

   Tests in `Tests/RecorderCoreTests/EventsAgentPointerTests.swift`:
   - a click with no real events → move+down+up
   - a click deduped against a nearby real down
   - a click kept against a far-away real down (distance or time)
   - doubleClick → two pairs
   - output sorted, other kinds (`key`, `cursor`) untouched
   - `AutoZoom`/`generatedAutoZooms` sees the merged click: build a minimal `Project` and assert one zoom
3. App: `EventRecorder.addAgentPointer(globalPoint: CGPoint, action: AgentPointer)` normalises with the existing
   `normalized(_:)` and stamps `outputTime(hostSeconds())`. It stores the action in a separate locked array (dropped
   while paused). `stop()` returns `EventLog(...).mergingAgentPointer(agentActions)`. Expose it through
   `CaptureSession.addAgentPointer` and `RecordingController.addMarker(label:point:action:)`.
4. Extend `mcp-record`: `record.mark {label, x, y, action:"click"}` with a point inside the recorded area → after stop,
   `events.json` has the synthetic `.down` and the project has ≥1 auto-zoom.

**Verify:** `make test FILTER=EventsAgentPointer`; `make test`; `--selftest mcp-record`.

### T-955 App: tell the human a draft is ready

On `draft.submit`, when `NSApp.isActive == false`, call `NSApp.requestUserAttention(.informationalRequest)`. Then post a
`UNUserNotificationCenter` notification ("Draft ready: <project title>", body "<client> submitted N changes"). Request
authorization once, on the first submit, with `[.alert]`. Clicking the notification brings that editor to the front
with the Claude tab (`EditorWindowController.open(package:)`, `model.inspectorShowsAgent = true`). If authorization is
denied, the dock bounce is enough; don't retry. Never put labels or transcript text in the notification, only the title
and the count.

**Verify:** `--selftest mcp-review` still OK. Add a branch that calls the submit path with an injected
`notify: (String, String) -> Void` and asserts title/body. HUMAN (waivable): see the banner once.

### T-956 Core: `steps` intent (conditional)

**Do this only if T-953's Log shows the agent needed ≥2 manual `cut` ops per step, or `render.lint demo` still flags
static spans after `pace`.** Otherwise tick it with `not needed: <evidence from T-953>`.

If needed: an intent op `steps {lead: 0.4, settle: 1.2, maxGap: 2.0, retake: "retake:"}` in `IntentOps.swift`. It keeps
`[marker.time − lead, settle end]` for each marker. Settle end = the last event or shot change before the next marker,
plus `settle`, capped at the next marker. It cuts the rest when a gap exceeds `maxGap`. It drops from a step's marker to
its `"retake: <label>"` marker. It lowers to existing `cut` ops (D4 rule: primitive → EditOp → human command not needed
for an intent), and it's listed in `report` like `pace`. Tests in `IntentOpsTests` (three markers, a retake, gap
collapse, protect untouched). Add it to the MCP `edit` description and the EDITING-CORE §5 table.

**Verify:** `make test FILTER=IntentOps`; `make test`; rerun T-953's brief with "use steps" and compare durations in the
Log.

## 6. Edge cases checklist (each must be handled; most are one line)

- `record.start` while the user's own toolbar/picker is open (`state` still `.idle`, but `ToolbarController` is
  visible) → allowed. Close the toolbar (`ToolbarController.shared.close()`) the same way `start` does.
- Target window closes mid-recording → existing SCStream error path. The agent's next call sees `state` idle and
  `lastAgentPackage` if the package was saved, else `RECORDING_FAILED`.
- Owner calls `record.start` again while recording → `RECORDING_BUSY` (never stack).
- Human presses Delete on the widget → package discarded. `record.status` → `state:"idle"`, no `project`.
  `record.stop` → `NOT_RECORDING`.
- `record.stop` before the first frame arrived (state `.countdown`) → wait up to 3 s for `.recording`, else cancel and
  throw `RECORDING_FAILED`.
- `exclude` contains Recorder's bundle id → harmless (already excluded).
- `width/height` given for a display/area target → `INVALID_OP`. Only one of them given → `INVALID_OP`.
- Label is empty or only whitespace → `INVALID_OP`. Trim it to 80 characters. Never log it.
- More than 500 markers → `OUT_OF_RANGE`.
- App relaunched mid-recording → existing `RecordingRecovery`. The agent's session is gone too, and the shim
  reconnects. `record.status` → idle.
- `allowWithoutAsking` toggled off mid-session → already-approved sessions stay approved until they disconnect.

## 7. What a finished session looks like (acceptance)

1. An interactive Claude Code session on the Mac mini, with Recorder + computer use connected, gets the T-953 brief.
2. It records a window, marks 4–6 steps, stops, and the editor opens on a project named after the brief.
3. It cuts dead time on its markers (or with `steps`), adds step titles, passes `render.lint demo`, and submits.
4. The human sees "Draft ready", opens it, sees the cut chips and titles on the timeline, unticks one change, and clicks
   Accept (one undo step).
5. Nothing left Recorder: no upload, no key characters in any MCP response, and the media is untouched.
