import SwiftUI
import RecorderCore

struct AudioPanel: View {
    let model: EditorModel
    let audioID: UUID

    var clip: AudioClip? { model.project.audioClips.first { $0.id == audioID.uuidString } }
    private var duration: Double {
        guard let clip else { return 0 }
        let segments = model.project.audioSegments(clip)
        return (segments.last?.output.end ?? 0) - (segments.first?.output.start ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            InspectorSelectionHeader(title: "Audio clip") { model.selection = [] }
            if let clip {
                Text(model.project.audioTracks[clip.track].name).font(Font(Theme.headingFont(22)))
                Text(URL(fileURLWithPath: clip.file).lastPathComponent)
                    .font(Font(Theme.captionFont)).foregroundStyle(Theme.textSecondaryColor)
                let words = model.transcriptWords(in: clip)
                if words.isEmpty, clip.file == "mic.m4a" { TranscriptStatus(model: model) }
                if !words.isEmpty { TranscriptEditor(model: model) }
                Text("Linked to").font(Font(Theme.headingFont(22)))
                TechSegmentedControl(selection: Binding(get: { clip.link?.rawValue ?? "none" }, set: { value in
                    changeLink(AudioClip.Link(rawValue: value))
                }), options: linkOptions)
                if let offset = model.project.syncOffset(clip) {
                    HStack {
                        Text(abs(offset) < 1 / 60.0 ? "In sync" : String(format: "%+.2f s out of sync", offset))
                            .font(Font(Theme.captionFont)).foregroundStyle(abs(offset) < 1 / 60.0 ? Theme.textSecondaryColor : Theme.dangerColor)
                        Spacer(minLength: 0)
                    }
                    Button("Move into Sync", action: moveIntoSync)
                        .buttonStyle(TechButtonStyle(kind: .secondary, compact: true))
                        .disabled(abs(offset) < 1e-9)
                }
                Divider()
                LabeledSlider(title: "Gain", value: gainBinding, range: -60...20 * log10(2), defaultValue: 0,
                              format: { String(format: "%+.1f dB", $0) }, onEditingChanged: gesture("Audio Gain"))
                Toggle("Mute clip", isOn: Binding(get: { clip.gain == 0 }, set: { muted in
                    model.edit("Mute Audio") { project in
                        if let index = project.audioClips.firstIndex(where: { $0.id == audioID.uuidString }) { project.audioClips[index].gain = muted ? 0 : 1 }
                    }
                }))
                ForEach([true, false], id: \.self) { incoming in
                    LabeledSlider(title: incoming ? "Fade in" : "Fade out", value: fadeBinding(incoming: incoming),
                                  range: 0...max(0.1, duration), defaultValue: 0,
                                  format: { $0 == 0 ? "Off" : String(format: "%.2f s", $0) },
                                  onEditingChanged: gesture("Audio Fade"))
                }
                Text(String(format: "Duration %.2f s", duration)).font(Font(Theme.captionFont)).foregroundStyle(Theme.textSecondaryColor)
                Button("Remove audio", role: .destructive) {
                    model.edit("Remove Audio") { $0.removeBlock(audioID) }
                    model.selection = []
                }.buttonStyle(TechButtonStyle(kind: .danger, compact: true))
            }
        }
    }

    private var linkOptions: [(String, String)] {
        var options = [("none", "None"), ("screen", "Screen")]
        if model.project.source.hasCamera { options.append(("camera", "Camera")) }
        if let clip, model.project.layers.contains(where: { $0.kind == .video && $0.file == clip.file }) { options.append(("layer", "Its video")) }
        return options
    }

    func changeLink(_ link: AudioClip.Link?) {
        model.edit(link == nil ? "Unlink Audio" : "Link Audio") { project in
            if let link { _ = project.linkAudio(audioID, to: link) }
            else { _ = project.unlinkAudio(audioID) }
        }
    }

    func moveIntoSync() { model.edit("Move into Sync") { $0.moveIntoSync(audioID) } }

    var gainBinding: Binding<Double> {
        Binding(get: { 20 * log10(max(0.001, clip?.gain ?? 1)) }, set: { value in
            guard value.isFinite else { return }
            model.update { project in
                if let index = project.audioClips.firstIndex(where: { $0.id == audioID.uuidString }) {
                    project.audioClips[index].gain = min(2, max(0, pow(10, value / 20)))
                }
            }
        })
    }

    func fadeBinding(incoming: Bool) -> Binding<Double> {
        Binding(get: { (incoming ? clip?.fadeIn : clip?.fadeOut) ?? 0 }, set: { value in
            guard value.isFinite else { return }
            let seconds = min(duration, max(0, (value * 10).rounded() / 10))
            model.update { project in
                if let index = project.audioClips.firstIndex(where: { $0.id == audioID.uuidString }) {
                    if incoming { project.audioClips[index].fadeIn = seconds > 0 ? seconds : nil }
                    else { project.audioClips[index].fadeOut = seconds > 0 ? seconds : nil }
                }
            }
        })
    }

    private func gesture(_ name: String) -> (Bool) -> Void {
        { editing in editing ? model.beginGesture() : model.commitGesture(name) }
    }
}

/// T-656: several audio clips selected — Gain / Mute / Fades edit all of them; differing values read "Mixed"
/// until changed. Each drag or toggle is one undo step.
struct AudioClipsPanel: View {
    let model: EditorModel
    let ids: Set<UUID>

    private var keys: Set<String> { Set(ids.map(\.uuidString)) }
    private var clips: [AudioClip] { model.project.audioClips.filter { keys.contains($0.id) } }
    /// Shortest selected clip, so one fade value fits every clip.
    private var duration: Double {
        clips.map { clip in
            let segments = model.project.audioSegments(clip)
            return (segments.last?.output.end ?? 0) - (segments.first?.output.start ?? 0)
        }.min() ?? 0
    }

    var body: some View {
        let clips = clips
        let gains = Set(clips.map(\.gain)), fadeIns = Set(clips.map { $0.fadeIn ?? 0 }), fadeOuts = Set(clips.map { $0.fadeOut ?? 0 })
        let muted = clips.filter { $0.gain == 0 }.count
        VStack(alignment: .leading, spacing: 12) {
            Text("\(clips.count) audio clips").font(Font(Theme.headingFont(22)))
            LabeledSlider(title: "Gain", value: gainBinding, range: -60...20 * log10(2), defaultValue: 0,
                          format: { gains.count > 1 ? "Mixed" : String(format: "%+.1f dB", $0) }, onEditingChanged: gesture("Audio Gain"))
            HStack {
                Toggle("Mute clips", isOn: Binding(get: { muted == clips.count }, set: { mute in
                    let keys = keys
                    model.edit("Mute Audio") { project in
                        for i in project.audioClips.indices where keys.contains(project.audioClips[i].id) { project.audioClips[i].gain = mute ? 0 : 1 }
                    }
                }))
                if muted > 0 && muted < clips.count {
                    Text("Mixed").font(Font(Theme.captionFont)).foregroundStyle(Theme.textTertiaryColor)
                }
            }
            ForEach([true, false], id: \.self) { incoming in
                let mixed = (incoming ? fadeIns : fadeOuts).count > 1
                LabeledSlider(title: incoming ? "Fade in" : "Fade out", value: fadeBinding(incoming: incoming),
                              range: 0...max(0.1, duration), defaultValue: 0,
                              format: { mixed ? "Mixed" : $0 == 0 ? "Off" : String(format: "%.2f s", $0) },
                              onEditingChanged: gesture("Audio Fade"))
            }
        }
    }

    private func updateAll(_ change: @escaping (inout AudioClip) -> Void) {
        let keys = keys
        model.update { project in for i in project.audioClips.indices where keys.contains(project.audioClips[i].id) { change(&project.audioClips[i]) } }
    }

    private var gainBinding: Binding<Double> {
        Binding(get: { 20 * log10(max(0.001, clips.first?.gain ?? 1)) }, set: { value in
            guard value.isFinite else { return }
            let gain = min(2, max(0, pow(10, value / 20)))
            updateAll { $0.gain = gain }
        })
    }

    private func fadeBinding(incoming: Bool) -> Binding<Double> {
        Binding(get: { (incoming ? clips.first?.fadeIn : clips.first?.fadeOut) ?? 0 }, set: { value in
            guard value.isFinite else { return }
            let seconds = min(duration, max(0, (value * 10).rounded() / 10))
            let fade = seconds > 0 ? seconds : nil
            updateAll { if incoming { $0.fadeIn = fade } else { $0.fadeOut = fade } }
        })
    }

    private func gesture(_ name: String) -> (Bool) -> Void {
        { editing in editing ? model.beginGesture() : model.commitGesture(name) }
    }
}

/// Text-based editing (T-931): the kept words in output order; click (⇧-click extends) selects, ⌫ or "Cut" removes them
/// through the same `cutWords` op the agent uses (`EditorModel.apply`), so both paths share validation and one undo step.
struct TranscriptEditor: View {
    let model: EditorModel
    @State private var selected: Set<String> = []
    @State private var anchor: Int?

    var body: some View {
        let view = agentTranscript(model.project, words: model.transcript ?? [])
        let fillers = view.words.filter(\.filler).map(\.id)
        VStack(alignment: .leading, spacing: 8) {
            Text("Transcript").font(Font(Theme.headingFont(22))).foregroundStyle(Theme.textPrimaryColor)
            WordFlow(spacing: 4) {
                ForEach(Array(view.words.enumerated()), id: \.element.id) { index, word in
                    Text(word.text).font(Font(Theme.captionFont))
                        .padding(.horizontal, 3).padding(.vertical, 1)
                        .foregroundStyle(selected.contains(word.id) ? Theme.bgWindowColor : Theme.textPrimaryColor)
                        .background(selected.contains(word.id) ? Theme.textPrimaryColor : .clear)
                        .underline(word.filler, pattern: .dot, color: Theme.warningColor)
                        .contentShape(Rectangle())
                        .onTapGesture { select(index, in: view.words) }
                        .accessibilityAddTraits(.isButton).accessibilityLabel(word.text + (word.filler ? ", filler" : ""))
                }
            }
            HStack {
                Button("Cut \(selected.count) word\(selected.count == 1 ? "" : "s")") { cut(Array(selected), transcript: view.transcript) }
                    .buttonStyle(TechButtonStyle(kind: .secondary, compact: true)).disabled(selected.isEmpty)
                    .keyboardShortcut(.delete, modifiers: [])
                Button("Remove \(fillers.count) filler\(fillers.count == 1 ? "" : "s")") { cut(fillers, transcript: view.transcript) }
                    .buttonStyle(TechButtonStyle(kind: .secondary, compact: true)).disabled(fillers.isEmpty)
            }
        }
    }

    private func select(_ index: Int, in words: [AgentWord]) {
        if NSEvent.modifierFlags.contains(.shift), let anchor {
            selected = Set(words[min(anchor, index)...max(anchor, index)].map(\.id))
        } else {
            let id = words[index].id
            if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
            anchor = index
        }
        if let first = words.first(where: { selected.contains($0.id) }) { model.isPlaying = false; model.playhead = first.from }
    }

    private func cut(_ ids: [String], transcript: String) {
        guard !ids.isEmpty else { return }
        model.apply([.cutWords(transcript: transcript, words: ids.sorted { (Int($0.dropFirst()) ?? 0) < (Int($1.dropFirst()) ?? 0) }, snap: true)],
                    name: ids.count == 1 ? "Cut Word" : "Cut \(ids.count) Words")
        selected = []; anchor = nil
    }
}

/// Wrapping row layout for transcript words.
struct WordFlow: SwiftUI.Layout {
    var spacing: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews) {
            for (index, x) in row.items { subviews[index].place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + row.y), proposal: .unspecified) }
        }
    }
    private func arrange(width: CGFloat, _ subviews: LayoutSubviews) -> [(items: [(Int, CGFloat)], y: CGFloat, width: CGFloat, height: CGFloat)] {
        var rows: [(items: [(Int, CGFloat)], y: CGFloat, width: CGFloat, height: CGFloat)] = [([], 0, 0, 0)]
        for (index, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if rows[rows.count - 1].width + size.width > width, !rows[rows.count - 1].items.isEmpty {
                let last = rows[rows.count - 1]
                rows.append(([], last.y + last.height + spacing, 0, 0))
            }
            rows[rows.count - 1].items.append((index, rows[rows.count - 1].width))
            rows[rows.count - 1].width += size.width + spacing
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}
