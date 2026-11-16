# Recorder

Record a Mac display, window or area, then edit the recording with cuts, zooms, camera placement, cursor effects and keystroke overlays. The editor keeps the original media and saves edits in a project package.

![Recorder editor with generated demo media, timeline tracks and canvas controls](docs/images/editor.png)

*Native-editor capture with generated demo media.*

## Install

Requires macOS 15 or newer on Apple Silicon or Intel. Download the universal DMG from [GitHub releases](https://github.com/olegpustovit/recorder/releases/latest), drag Recorder into Applications and open it there.

For the first recording:

1. Allow **Screen & System Audio Recording** and **Accessibility** in **System Settings > Privacy & Security**.
2. Return to Recorder and choose **Check again**. Use **Relaunch** if macOS requires a new process after the change.
3. Choose a display, window or area. Enable camera, microphone or system audio if you need them and grant the corresponding permissions.
4. Record a short clip, stop, and edit it in the timeline.
5. Choose **Export** for an H.264/HEVC MP4 or animated GIF.

The current export pipeline is SDR sRGB. HDR brightness and colors outside sRGB are not preserved. Clipboard handoff copies the exported file for apps that accept files.

See [installation and troubleshooting](docs/INSTALLATION.md) for signing, updates, permission repair and local installation. Current release packaging requires Developer ID signing and notarization. The [tracker](docs/PLAN.md) records a successful permission readout from signed v0.3.3; that does not establish recovery on every affected Mac. Earlier ad-hoc releases had grant-detection failures. Real-microphone latency and extended-duration performance checks remain unverified.

## Build from source

Install Apple's Command Line Tools and Swift 6 or newer on a Mac:

```sh
git clone https://github.com/olegpustovit/recorder.git
cd recorder
make app
open build/Recorder.app
```

There are no third-party Swift packages. The targets use Swift 5 language mode. Use `make test` for the core checks; the Makefile supplies the Swift Testing framework paths.

`make app` builds without replacing an installed copy or resetting its permissions. `make install` also creates or reuses a local signing identity, replaces /Applications/Recorder.app and resets Recorder's permission grants. Read the [local-install details](docs/INSTALLATION.md#self-signed-local-install-and-permission-reset) before using it.

Native MCP editing, review/undo, Metal preview/export parity and approved MP4/SRT exports have been checked on macOS with generated media. Live microphone capture, positive on-device transcription and extended recording performance were not repeated for the MCP work.

## Connect an agent

Open **Settings > Agents > Connect** for Claude Code, or add the installed app yourself:

```sh
claude mcp add recorder -s user -- /Applications/Recorder.app/Contents/MacOS/Recorder --mcp
```

For a source build, replace the executable path with the absolute path to
`build/Recorder.app/Contents/MacOS/Recorder`. **Copy JSON** supplies configuration for other MCP clients.
The shim starts Recorder when needed; projects open in ordinary editor windows.

Ask Claude to open a recording, find pauses/fillers, propose cuts and captions, render a contact sheet and submit.
Access defaults to **Draft**: inspect changes in the **Claude** tab, untick any you do not want, then Accept or Discard.
Accept is one undo step. **Off**, **Read** and **Live** access are available per project.
Final MP4 exports require a native approval sheet and can include an SRT sidecar.

Tools never return key characters; agent previews hide key overlays. Render files expire from the agent cache after
seven days. Drafts live in memory and are lost when Recorder quits. See [Agents](docs/SPEC.md#10-agents-mcp)
and the [tool reference](docs/MCP.md). Run `make mcp-smoke` to build the app and check initialization and all nine tools;
quit a running source-build app before rebuilding its bundle.

## Help and development

[Report a problem](https://github.com/olegpustovit/recorder/issues) with the version and failing action. **Recorder > Copy State Snapshot** can help diagnosis, but inspect it before sharing because it can include window images.

The [specification](docs/SPEC.md), [implementation tracker](docs/PLAN.md), [UI guide](docs/UI-KIT.md) and [release guide](docs/RELEASING.md) contain the detailed design and checks.

## License and credits

Created by [Oleg Pustovit](https://github.com/olegpustovit). [MIT](LICENSE), with [third-party font and asset notices](Resources/THIRD_PARTY_NOTICES.md).
