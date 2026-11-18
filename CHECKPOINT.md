# Recorder checkpoint — 2026-11-18

Resumed on the MacBook Air. **The full proposal is not finished.**

Original goal: fully implement https://artifacts.microapps.space/a/d0rs3s43x727.
Branch: `dev`. Push target: `origin/dev` (`git@github.com:olegpustovit/recorder.git`).

## Resume here

Read `AGENTS.md`, `docs/PLAN.md` §“Agent recording”, and `docs/RECORDING-AGENT.md`.
**Resume at T-956 on the MacBook Air.** The TextEdit draft is ready for review in Recorder.

On the MacBook Air, preserve any local changes before switching or pulling. With a clean worktree:

```sh
cd ~/WORK/GIT/recorder
git switch dev
git pull --ff-only origin dev
```

The user has already authorized completing the proposal and moved T-953 to this MacBook Air.

## Completed

- **T-950** — commit `ee23907`, agent recording path. Temporary silent settings copies, application exclusions,
  capture ownership/title/markers, pause-aware marker timestamps, throwing finish with recovery, duration cap,
  restart settings. Human recording continues to use the shared capture path.
- **T-951** — commit `4899ce6`, MCP `record` tool: `targets`, `start`, `status`, `mark`, `pause`, `resume`,
  `stop`. Shared `openProject` handles editor opening and draft adoption. Includes target/area/resize validation,
  one-session consent, opt-in Agents setting, ownership checks, discard, idempotent stop, and human Finish handoff.
  Disconnect cancels consent or saves the take, including while capture is starting. Shared schema validation now
  enforces the advertised string `maxLength`; existing schema tests cover that and nested area validation.
- **T-952** — ten-tool smoke check, docs, area demo script, and byte-preserving MCP transcript relay.
  Verification is in the plan Log.

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

### Completed local eval

**T-953 — real TextEdit silent-demo eval** on the MacBook Air (macOS 27.2).
   The signed build is installed at `/Applications/Recorder.app` and owns the standard MCP socket.
   Its Screen Recording and Accessibility grants survived the same-signer update. The existing Claude Code
   `recorder` connection uses the installed binary. The staged interactive session and relay see all ten tools.
   Attach with `tmux -L recorder-demo attach -t eval`. The built-in `computer-use` server is enabled for this
   eval folder. The local launcher in `build/textedit-eval/start.sh` runs Claude Code with
   `--dangerously-skip-permissions` at the user's request. Claude still requires TextEdit access per session.
   Recorder's unattended opt-in is off, so the first start also requires native capture approval.
   The draft runs 16.3 s with four step titles, nine cuts and no demo lint warnings. The raw take was 38.25 s.
   The public transcript in `docs/evals/textedit-silent-demo.jsonl` retains call metadata and scores with image
   payloads and unrelated window titles removed. The raw transcript and review screenshots stay in `build/textedit-eval`.

### Next

T-954 and T-955 are verified in the signed QA build. They add `record.mark {x,y,pointerAction}`, correct cursor
drift on existing takes and add a background draft notification. The installed release will be updated after T-956.

**T-956 — `steps` intent.** The submitted T-953 draft needed nine cuts for four steps, which meets the threshold.

## Files and state

T-951 changes are in `Sources/Recorder/Agent/{MCPTools,MCPServer}.swift`,
`Sources/Recorder/Recording/RecordingController.swift`, `Sources/Recorder/App/{SettingsView,SelfTest}.swift`,
`Sources/RecorderCore/SchemaCheck.swift`, and `Tests/RecorderCoreTests/AgentDraftTests.swift`.
`docs/PLAN.md` and `docs/RECORDING-AGENT.md` record the verified status and corrections.

The two pre-existing `r.stdout` / `r.stderr` files were inspected before the requested “commit all”:
only old GIF-selftest metrics / empty stderr; no keys, events or credentials. They are included in the checkpoint.
