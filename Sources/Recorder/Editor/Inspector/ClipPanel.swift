import SwiftUI
import RecorderCore

/// SPEC §6.6 "Clip selected" / §7.2 "Speed": replaces the tabs in `InspectorView` while a clip is
/// selected. Speed edits go through `Project.setSpeed` (`TimelineOps.swift`, clamps to 0.25...16
/// and re-checks invariants); Remove through `Project.removeClip`.
struct ClipPanel: View {
    let model: EditorModel
    let clipIndex: Int

    private static let presets: [Double] = [0.5, 1, 1.5, 2, 4, 8]

    private var clip: Clip? { model.project.clips[safeIndex: clipIndex] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            InspectorSelectionHeader(title: "Clip") { deselect() }

            if let clip {
                Text("Playback speed").font(Font(Theme.headingFont(22)))
                presetPicker(current: clip.speed)

                LabeledSlider(title: "Custom", value: speedBinding, range: 0.25...16, defaultValue: 1,
                              format: { String(format: "%.2f×", $0) }, onEditingChanged: gesture("Speed"))

                Divider().padding(.vertical, 4)
                Toggle("Hide cursor", isOn: cursorHiddenBinding)
                    .foregroundStyle(Theme.textPrimaryColor)
                Text("Applies to this video clip only.")
                    .font(Font(Theme.captionFont)).foregroundStyle(Theme.textSecondaryColor)

                Divider().padding(.vertical, 4)
                Text("Video fades").font(Font(Theme.headingFont(22)))
                ForEach([true, false], id: \.self) { incoming in
                    LabeledSlider(title: incoming ? "Fade in" : "Fade out",
                                  value: fadeBinding(incoming: incoming), range: 0...max(0.01, clip.outputDuration),
                                  defaultValue: 0, format: { $0 == 0 ? "Off" : String(format: "%.2f s", $0) },
                                  onEditingChanged: gesture(incoming ? "Fade in" : "Fade out"))
                }
                Text("Off by default. Applies to this video clip only.")
                    .font(Font(Theme.captionFont)).foregroundStyle(Theme.textSecondaryColor)
                Divider().padding(.vertical, 4)
                HStack {
                    Text("Duration")
                        .font(Font(Theme.bodyFont))
                        .foregroundStyle(Theme.textSecondaryColor)
                    Spacer()
                    Text("\(timecode(clip.sourceEnd - clip.sourceStart)) → \(timecode(clip.outputDuration))")
                        .font(Font(Theme.timecodeFont(11)))
                        .foregroundStyle(Theme.textPrimaryColor)
                }

                Button("Remove clip", role: .destructive, action: removeClip)
                    .buttonStyle(TechButtonStyle(kind: .danger, compact: true))

            }
        }
    }

    private func presetPicker(current: Double) -> some View {
        HStack(spacing: 4) {
            ForEach(Self.presets, id: \.self) { preset in
                Button(formatSpeed(preset) + "×") {
                    model.edit("Speed") { $0.setSpeed(clipIndex, preset) }
                }
                .buttonStyle(TechButtonStyle(kind: current == preset ? .primary : .secondary, compact: true))
            }
        }
    }

    // MARK: - Bindings

    var cursorHiddenBinding: Binding<Bool> {
        Binding(get: { clip?.hideCursor == true },
                set: { model.setClipCursorHidden($0, at: clipIndex) })
    }

    func fadeBinding(incoming: Bool) -> Binding<Double> {
        Binding(get: { (incoming ? clip?.fadeIn : clip?.fadeOut) ?? 0 }, set: { value in
            model.update { project in
                guard project.clips.indices.contains(clipIndex) else { return }
                let duration = project.clips[clipIndex].outputDuration
                let seconds = value.isFinite ? min(max(0, value), duration) : 0
                if incoming { project.clips[clipIndex].fadeIn = seconds > 0 ? seconds : nil }
                else { project.clips[clipIndex].fadeOut = seconds > 0 ? seconds : nil }
            }
        })
    }

    private var speedBinding: Binding<Double> {
        Binding(
            get: { clip?.speed ?? 1 },
            set: { newValue in model.update { $0.setSpeed(clipIndex, newValue) } })
    }

    private func gesture(_ name: String) -> (Bool) -> Void {
        { editing in editing ? model.beginGesture() : model.commitGesture(name) }
    }

    private func removeClip() {
        model.edit("Remove clip") { $0.deleteClips([clipIndex]) }
        deselect()
    }

    private func deselect() {
        model.selectedClip = nil
    }

    private func formatSpeed(_ speed: Double) -> String {
        speed.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", speed) : String(format: "%.1f", speed)
    }

    private func timecode(_ t: Double) -> String {
        let centi = Int((max(0, t) * 100).rounded())
        return String(format: "%02d:%02d.%02d", centi / 6000, (centi / 100) % 60, centi % 100)
    }
}

private extension Array {
    subscript(safeIndex i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}


extension ClipPanel {
    @MainActor static func runCursorSelfTest() throws {
        struct Fail: Error, CustomStringConvertible { let description: String }
        _ = NSApplication.shared
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clip-cursor-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        var project = Project(source: Source(duration: 20), clips: [
            Clip(sourceStart: 0, sourceEnd: 2), Clip(sourceStart: 2, sourceEnd: 6, speed: 4), Clip(sourceStart: 6, sourceEnd: 10)
        ])
        project.clips[1].clockSpeed = 1
        project.clips[1].mediaStart = 0
        project.cursor.hideWhenIdle = false
        let events = EventLog(events: [InputEvent(t: 0, k: .move, x: 0.2, y: 0.3), InputEvent(t: 19, k: .move, x: 0.8, y: 0.7)])
        let model = EditorModel(packageURL: url, project: project, events: events)
        model.selectedClip = 1
        let panel = ClipPanel(model: model, clipIndex: 1)
        func alpha(_ time: Double, in model: EditorModel) -> Double {
            makeFrameState(model: model, outputTime: time, screen: nil, camera: nil, size: CGSize(width: 640, height: 360)).cursor?.alpha ?? -1
        }
        guard !panel.cursorHiddenBinding.wrappedValue, alpha(4, in: model) > 0 else { throw Fail(description: "cursor should start visible") }
        panel.cursorHiddenBinding.wrappedValue = true
        guard panel.cursorHiddenBinding.wrappedValue, model.undoStepCount == 1, model.selectedClip == 1,
              model.project.clips[0] == project.clips[0], model.project.clips[2] == project.clips[2],
              model.project.cursor == project.cursor, model.project.cursorHidden.isEmpty,
              alpha(1.999, in: model) > 0, alpha(2, in: model) == 0, alpha(4, in: model) == 0,
              alpha(5.999, in: model) == 0, alpha(6, in: model) > 0 else {
            throw Fail(description: "clip hiding leaked across a cut, ignored the media clock, or created extra undo steps")
        }
        panel.cursorHiddenBinding.wrappedValue = true
        guard model.undoStepCount == 1 else { throw Fail(description: "idempotent hide created undo") }
        model.undo()
        guard model.project == project, !panel.cursorHiddenBinding.wrappedValue, alpha(4, in: model) > 0 else { throw Fail(description: "undo hide") }
        model.redo()
        model.saveNow()
        let reloaded = try loadEditorModel(package: url)
        guard reloaded.project == model.project, alpha(4, in: reloaded) == 0, alpha(6, in: reloaded) > 0 else { throw Fail(description: "hide did not persist") }
        for width in [300.0, 360.0] {
            let view = NSHostingView(rootView: panel.padding(16).frame(width: width).signalWindow())
            view.setFrameSize(view.fittingSize)
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw Fail(description: "panel bitmap") }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw Fail(description: "panel PNG") }
            try png.write(to: URL(fileURLWithPath: "/tmp/recorder-clip-cursor-\(Int(width)).png"))
        }
        panel.cursorHiddenBinding.wrappedValue = false
        guard !panel.cursorHiddenBinding.wrappedValue, alpha(4, in: model) > 0, model.undoStepCount == 2 else { throw Fail(description: "show cursor") }
        model.undo()
        guard alpha(4, in: model) == 0 else { throw Fail(description: "undo show") }
        model.redo()
        model.edit("Global hide") { $0.cursor.hidden = true }
        guard alpha(4, in: model) == 0, alpha(6, in: model) == 0 else { throw Fail(description: "global hide must still apply") }
        model.undo()
        model.edit("Legacy range") { $0.cursorHidden = [TimeRange(start: 0, end: 1)] }
        guard alpha(0.5, in: model) == 0, alpha(4, in: model) > 0 else { throw Fail(description: "legacy ranges must still apply") }
        let beforeInvalid = model.project, steps = model.undoStepCount
        ClipPanel(model: model, clipIndex: 99).cursorHiddenBinding.wrappedValue = true
        guard model.project == beforeInvalid, model.undoStepCount == steps else { throw Fail(description: "stale selection mutated project") }
        model.saveNow()
        guard try Project.load(from: url.appendingPathComponent("project.json")) == model.project else { throw Fail(description: "show did not persist") }
        print("clip-cursor: selected-cut boundaries, repeated media, independent speed, undo/redo, show, global/legacy hide, persistence and panel renders verified")
    }

    @MainActor static func runFadesSelfTest() throws {
        struct Fail: Error { }
        _ = NSApplication.shared
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clip-fades-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try TimelineView.checkClipZeroSnap(packageURL: url)
        let project = Project(source: Source(duration: 4), clips: [Clip(sourceStart: 0, sourceEnd: 4)])
        let model = EditorModel(packageURL: url, project: project, events: EventLog())
        let panel = ClipPanel(model: model, clipIndex: 0)
        guard panel.fadeBinding(incoming: true).wrappedValue == 0, panel.fadeBinding(incoming: false).wrappedValue == 0 else { throw Fail() }
        model.beginGesture()
        panel.fadeBinding(incoming: true).wrappedValue = 0.4
        model.commitGesture("Fade in")
        guard model.undoStepCount == 1, abs(model.project.videoOpacity(atOutput: 0.2) - 0.5) < 1e-8 else { throw Fail() }
        model.undo()
        guard model.project == project else { throw Fail() }
        model.redo()
        model.beginGesture()
        panel.fadeBinding(incoming: false).wrappedValue = 0.6
        model.commitGesture("Fade out")
        guard abs(model.project.videoOpacity(atOutput: 3.7) - 0.5) < 1e-8 else { throw Fail() }
        model.saveNow()
        guard try Project.load(from: url.appendingPathComponent("project.json")) == model.project else { throw Fail() }
        let view = NSHostingView(rootView: panel.padding(20).frame(width: 360).signalWindow())
        view.setFrameSize(view.fittingSize)
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw Fail() }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/recorder-clip-fades.png"))
    }
}
