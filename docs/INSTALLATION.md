# Installation and troubleshooting

## Installation

**Existing permission grants may need repair after an older build.** Passing
export/CI checks does not establish that permission migration works on an affected
Mac. Real-microphone latency and extended-duration performance gates also remain
unverified; see the acceptance tracker in [the plan](PLAN.md).

1. Download `Recorder-<version>-universal.dmg` from the
   [latest release](https://github.com/olegpustovit/recorder/releases/latest).
2. Open the DMG and drag **Recorder** into **Applications**.
3. Eject the DMG. Open **Recorder from Applications**.
4. Approve the macOS permissions described below.

The same DMG supports Apple Silicon and Intel Macs running **macOS 15 or later**.
To update, quit Recorder and replace the app in Applications with the new version.
Your recordings are stored separately, by default in `~/Movies/Recorder`.

### First launch: signing and Gatekeeper

Current release packaging requires **Developer ID signing and Apple notarization**
of both the app and DMG, including stapled tickets and Gatekeeper assessment before
publication. Older ad-hoc releases may still show an unidentified-developer or
“Apple could not verify” message.

After attempting to open the installed app:

1. Open **System Settings → Privacy & Security**.
2. Scroll to the security message about Recorder and choose **Open Anyway**.
3. Authenticate if asked, then confirm **Open**.

Use this exception only for the Recorder build you intentionally downloaded from
this repository. See [Apple’s explanation of Gatekeeper](https://support.apple.com/en-us/102445).
No global Gatekeeper change is needed. If a current release is blocked, report the
version and warning rather than disabling Gatekeeper; see [releasing](RELEASING.md).

### Capture permissions

Recorder needs these entries enabled in **System Settings → Privacy & Security**:

| Permission | Purpose |
| --- | --- |
| Screen & System Audio Recording | Capture the selected screen content and optional system audio. |
| Accessibility | Preserve pointer and shortcut activity and support window controls. |
| Camera / Microphone | Requested when you enable those inputs. |

Return to Recorder and select **Check again**. This is a read-only check, not another
permission request. If access is still missing, use **Relaunch** after enabling it:
macOS can retain the denied state in the old process. Apple also documents
[screen and system audio permissions](https://support.apple.com/guide/mac-help/mchld6aa7d23/mac).

**Already enabled, but Recorder still says access is missing?** Ad-hoc updates can
leave a permission entry associated with an older copy of the app:

1. Quit other running copies of Recorder. Check the path/version shown in setup.
2. In builds with **Repair access…**, choose it and confirm **Reset and Relaunch**.
   This resets only Recorder’s Screen Recording and Accessibility grants, not other
   apps or recordings. Then use **Allow…**, enable access, and relaunch once more.
3. On older builds, quit Recorder, remove its entry with **−** from both permission
   lists, add `/Applications/Recorder.app` with **+**, and enable it before reopening.

If an old grant still cannot be replaced, quit every Recorder process and run these
targeted commands in Terminal, then open the installed app and grant access again:

```sh
tccutil reset ScreenCapture space.microapps.recorder
tccutil reset Accessibility space.microapps.recorder
```

These revoke Recorder’s two grants only. Do not use `tccutil reset All`.
Starting with 0.1.4, the app identifier is `space.microapps.recorder`. For 0.1.2 and
older, the reset commands must instead use `sh.nexo.recorder`. The new identity needs
fresh macOS permissions; old grants cannot migrate. Quit older copies before updating.
Existing preferences are copied once without overwriting new settings; project files
and presets stay in place, and legacy `.recorder` projects remain supported.
Ad-hoc builds do not have a stable signing identity across updates, so recovery may
be needed again after replacing the app. Developer ID signing is needed for stable
public-release identity; repeated permission checks cannot repair that mismatch.

Avoid launching a second copy from the DMG or a build folder while troubleshooting.

## Troubleshooting

- **MP4 or GIF export crashes on 0.1.0 / 0.1.1:** update to **0.1.2 or later**.
  Those builds contain a Metal command-completion bug affecting both formats.
- **Capture looks washed out:** 0.1.2 makes capture color settings explicit and honors
  source color metadata during rendering. Color information already lost or incorrectly
  tagged in an older recording cannot always be recovered; compare a fresh recording.
- **Copy to clipboard:** copies the exported file for pasting into apps that accept
  files. It does not put a playable video into a plain-text field.
- **Still stuck:** use **Recorder → Copy State Snapshot**, then
  [open an issue](https://github.com/olegpustovit/recorder/issues) with your app/macOS versions,
  the failing action and any relevant crash report. Review snapshot contents before
  attaching them; snapshots can include images of Recorder’s windows.

## Build from source

Install Apple’s Command Line Tools (`xcode-select --install`) and use Swift 6 or later:

```sh
git clone https://github.com/olegpustovit/recorder.git
cd recorder
make app
open build/Recorder.app
```

There are no third-party Swift package dependencies.

### Self-signed local install and permission reset

```sh
make install
open /Applications/Recorder.app
```

Run as your normal logged-in user, **not with sudo**. `make install` creates or reuses
the local **Recorder Dev** certificate (Keychain may ask for access), builds with that
identity, verifies the signature, quits running Recorder copies normally, and replaces
`/Applications/Recorder.app`. It resets only Recorder's Screen Recording, Accessibility,
Camera and Microphone grants for both `space.microapps.recorder` and legacy
`sh.nexo.recorder`. Every `make install` intentionally resets these grants.

Recordings, presets and preferences are not removed. Approve fresh macOS permissions
after launching the installed copy; quit and reopen if macOS requires it. If Recorder
cannot quit or signing fails, installation stops instead of force-killing it or falling
back to ad-hoc signing. Errors resetting the current identity are reported as failures.

`make cert` alone creates/reuses the certificate; `make app` builds without resetting
permissions or replacing the installed app. Self-signing is **not** Apple notarization
and is **not yet confirmed** to fix the reported grant-detection failure.

### Verify changes

```sh
ruby scripts/test-install.rb # isolated installer/certificate tests; no real grants reset
make test
make app
build/Recorder.app/Contents/MacOS/Recorder --selftest export-colors
build/Recorder.app/Contents/MacOS/Recorder --selftest export-sheet
```

The export checks use the actual GPU and codecs: color conversion, H.264, HEVC,
animated GIF, clipboard handoff, cancellation and retry. They require a Metal-capable
Mac. Add `--capture` to `export-colors` to test a real ScreenCaptureKit capture of a
generated test window; that check requires Screen Recording permission.

See the [product specification](SPEC.md), [UI direction](UI-KIT.md),
and [release instructions](RELEASING.md) for more detail.

