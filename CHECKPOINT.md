# Recorder checkpoint — 2026-11-18

Paused at the user's request for resuming on the MacBook Air. **The full proposal is not finished.**

Original goal: fully implement https://artifacts.microapps.space/a/d0rs3s43x727.
Branch: `dev`. Push target: `origin/dev` (`git@github.com:olegpustovit/recorder.git`).

## Resume here

Read `AGENTS.md`, `docs/PLAN.md` §“Agent recording”, and `docs/RECORDING-AGENT.md`.
**The first unchecked task is T-952.** Follow the tasks in order; do not reimplement T-950/T-951.

On the MacBook Air, preserve any local changes before switching or pulling. With a clean worktree:

```sh
cd ~/WORK/GIT/recorder
git switch dev
git pull --ff-only origin dev
```

The user has already authorized completing the proposal. The pause is only for the machine handoff.
No new feature work, deployment, or live demo was performed after the checkpoint request.

## Completed

- **T-950** — commit `ee23907`, agent recording path. Temporary silent settings copies, application exclusions,
  capture ownership/title/markers, pause-aware marker timestamps, throwing finish with recovery, duration cap,
  restart settings. Human recording continues to use the shared capture path.
- **T-951** — in this checkpoint commit, MCP `record` tool: `targets`, `start`, `status`, `mark`, `pause`, `resume`,
  `stop`. Shared `openProject` handles editor opening and draft adoption. Includes target/area/resize validation,
  one-session consent, opt-in Agents setting, ownership checks, discard, idempotent stop, and human Finish handoff.
  Disconnect cancels consent or saves the take, including while capture is starting. Shared schema validation now
  enforces the advertised string `maxLength`; existing schema tests cover that and nested area validation.

**Consent implementation correction:** the guide's original `NSAlert.runModal()` inside a main-actor Task blocked
real MCP socket requests and cancellation. Production now uses AppKit `beginModalSession` / `runModalSession` /
`endModalSession`, yielding with an awaited 20 ms sleep between event passes. It remains a native app-modal alert.
The guide is updated. Do not restore the blocking version.

The user explicitly answered **“Waive the visual check”** for T-951 after the native functional checks passed.
T-951 is checked off; no further consent-visual approval is pending. No human-performed interaction is claimed.

## Verification completed

Developer ID signed release bundle used for checks: `build/agent-recording/Recorder.app`.
A separate bundle was used so the running source-build app was not replaced.

- `make app APP=build/agent-recording/Recorder.app` — passed on the final source.
- `make test` — **305 tests in 18 suites passed**, including extended schema assertions. Core did not change
  afterward; subsequent changes were the app's native consent handling and its selftests, checked below.
- `--selftest mcp-record` — real captures; validation; consent once/deny/timeout/opt-in; ownership; paused markers;
  marker-anchored cut dry run; repeat stop; discard with a closed previous editor; human Finish; disconnect during
  approval, startup, and recording.
- `--selftest mcp-record --native` — **final release passed**: real native timeout, Don't Allow, responsive status,
  disconnect cancellation, and Allow starting a silent take, followed by immediate discard.
- `--selftest record-agent-cap` — a 10-second wall-time cap saved a paused take; paused time excluded from media.
- `--selftest mcp-schema` — 34 actions / ten tools, handler/schema parity and limits.
- `--selftest mcp-export /tmp/M6Fixture.recorder` — existing export approval and data-safety regressions passed.
- `--selftest mcp-roundtrip /tmp/M6Fixture.recorder` — ten tools, socket/protocol/project/access/key-privacy checks passed.
- `--selftest settings-png /tmp/recorder-t951-settings.png agents` — actual Settings Agents pane inspected.
  `agents pane=<id>` still renders the Connect an Agent views.
- A real private-socket server stayed responsive to `ping` after disconnecting while native consent was shown,
  then exited normally. This independently reproduced and verified the modal-hang fix.

`/tmp` evidence and generated media are **not portable** and are not committed. Regenerate as needed:

```sh
make app APP=build/agent-recording/Recorder.app
build/agent-recording/Recorder.app/Contents/MacOS/Recorder --selftest permissions
build/agent-recording/Recorder.app/Contents/MacOS/Recorder --selftest make-m6-fixture
build/agent-recording/Recorder.app/Contents/MacOS/Recorder --selftest mcp-record
build/agent-recording/Recorder.app/Contents/MacOS/Recorder --selftest mcp-record --native
```

`make-m6-fixture` always writes the disposable `/tmp/M6Fixture.recorder`; it ignores extra arguments.
Native consent QA writes an own-window screenshot to `/tmp/recorder-t951-consent.png` (ScreenCaptureKit,
not `cacheDisplay`, which missed native vibrant text). Both that screenshot and the Agents pane were inspected.

Check permission/signing state on the Air; do not assume this machine's grants transfer. Do not reset TCC or grant
permissions automatically. Keep keystrokes local to project packages; do not upload or log event/key data.
Use `make test`, never bare `swift test`. Avoid changing Swift source while a build is compiling it.

## Remaining work, in order

1. **T-952 — docs, smoke, scripts.** Update `Makefile`'s smoke test from nine to ten tools and add `record` to the
   expected set. Sync `docs/MCP.md`, `docs/SPEC.md`, `README.md`, `CLAUDE.md`. Add the reproducible
   `scripts/mcp-record-demo.sh` and stdio relay `scripts/mcp-log.py`; run their listed checks.
   **`make mcp-smoke` has not been run for this change; its current nine-tool expectation is intentionally still
   pending T-952.** An old running Recorder owns the normal socket and still exposes nine tools; smoke must reach
   the current build. Quit the old source-build app normally before replacing its bundle, preserving project/draft
   data. Existing MCP shims reconnect; don't blindly kill unrelated processes or replace a running bundle.
2. **T-953 — real TextEdit silent-demo eval**, per the guide, on `olegs-mac-mini`. Save the MCP transcript and metrics,
   prove clean `render.lint demo`, inspect cursor/auto-zooms and the submitted draft, answer the macOS re-consent
   question from real observations. SSH worked and an older signed Recorder reported both grants on the mini;
   the new code has **not** been copied or evaluated there. Interactive driver availability/prerequisites remain
   unverified. Development may resume on the Air; the guide's live-eval machine remains the mini unless changed.
3. **T-954 — pointer declarations**, `record.mark {x,y,action}` → deduplicated Core events and auto-zoom tests.
   These arguments are **not implemented yet**.
4. **T-955 — draft-ready notification**, native attention/notification and click-through to the editor's Claude tab.
   **Not implemented yet.**
5. **T-956 — conditional `steps` intent.** Decide from T-953's actual manual-cut/static-span evidence. Do not invent
   a reason to build it or mark it unnecessary before that evidence exists.

## Files and state

T-951 changes are in `Sources/Recorder/Agent/{MCPTools,MCPServer}.swift`,
`Sources/Recorder/Recording/RecordingController.swift`, `Sources/Recorder/App/{SettingsView,SelfTest}.swift`,
`Sources/RecorderCore/SchemaCheck.swift`, and `Tests/RecorderCoreTests/AgentDraftTests.swift`.
`docs/PLAN.md` and `docs/RECORDING-AGENT.md` record the verified status and corrections.

The two pre-existing `r.stdout` / `r.stderr` files were inspected before the requested “commit all”:
only old GIF-selftest metrics / empty stderr; no keys, events or credentials. They are included in the checkpoint.

The overall goal is paused, not complete. Continue at **T-952** when the user resumes.
