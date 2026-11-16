#!/bin/sh
# Local developer install only; never reset another application's privacy grants.
set -eu

source_app=build/Recorder.app
destination=/Applications/Recorder.app
requirement='identifier "space.microapps.recorder" and (certificate leaf[subject.CN] = "Recorder Dev" or (anchor apple generic and certificate leaf[subject.OU] = "7ZH3FYV964"))'
# Grants are bound to the signer: reset them only when it changes (they would silently stop matching).
signer() { codesign -dvv "$1" 2>&1 | grep -m1 '^Authority=' || true; }
new_signer=$(signer "$source_app")
old_signer=$(signer "$destination")
codesign --verify --deep --strict -R="$requirement" "$source_app"
[ ! -L "$destination" ] || { echo "Refusing to replace a symlink: $destination" >&2; exit 1; }

# Copy and verify before touching the installed app; keep replacement on one volume.
stage=$(mktemp -d /Applications/.Recorder-install.XXXXXX)
trap 'rm -rf "$stage"' EXIT
ditto "$source_app" "$stage/Recorder.app"
codesign --verify --deep --strict -R="$requirement" "$stage/Recorder.app"

# NSRunningApplication sends a normal quit, allowing document autosave. Never kill
# a process just because its executable happens to be named Recorder.
osascript -l JavaScript <<'JXA'
ObjC.import('AppKit');
const copies = [];
['space.microapps.recorder', 'sh.nexo.recorder'].forEach(id => {
    const apps = $.NSRunningApplication.runningApplicationsWithBundleIdentifier(id);
    for (let i = 0; i < apps.count; i++) copies.push(apps.objectAtIndex(i));
});
copies.forEach(app => app.terminate);
for (let i = 0; i < 100 && copies.some(app => !app.isTerminated); i++) delay(0.1);
// Still running after 10 s (hung or slow quit): force it; autosave already flushed anything a normal quit would.
copies.filter(app => !app.isTerminated).forEach(app => app.forceTerminate);
for (let i = 0; i < 50 && copies.some(app => !app.isTerminated); i++) delay(0.1);
if (copies.some(app => !app.isTerminated)) throw Error('Recorder could not be force-quit; quit it manually, then retry make install.');
JXA

if [ -e "$destination" ]; then mv "$destination" "$stage/Previous.app"; fi
if ! mv "$stage/Recorder.app" "$destination"; then
    if [ -e "$stage/Previous.app" ] && ! mv "$stage/Previous.app" "$destination"; then
        trap - EXIT
        echo "Restore failed. Previous app preserved at $stage/Previous.app" >&2
    fi
    exit 1
fi
echo "Installed $destination. Existing recordings and settings are untouched."
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$destination"
if [ "$new_signer" = "$old_signer" ]; then echo "Same signer (${new_signer#Authority=}): permissions kept. Run: open /Applications/Recorder.app"; exit 0; fi

for service in ScreenCapture Accessibility Camera Microphone; do
    tccutil reset "$service" space.microapps.recorder >/dev/null || { echo "App installed, but $service could not be reset." >&2; exit 1; }
done
echo "Signer changed to ${new_signer#Authority=}: permissions reset. Run: open /Applications/Recorder.app and approve once."
