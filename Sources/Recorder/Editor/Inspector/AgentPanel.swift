import SwiftUI
import RecorderCore

extension EnvironmentValues {
    @Entry var agentReduceMotionPreview = false
}

@MainActor struct AgentPanel: View {
    let model: EditorModel
    @AppStorage private var accessRaw: String
    @State private var selectedSessionID: String?
    @State private var expanded: Set<AgentChangeKind> = []
    @State private var activityExpanded = false
    @State private var rail: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.agentReduceMotionPreview) private var previewReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || previewReduceMotion }

    init(model: EditorModel) {
        self.model = model
        _accessRaw = AppStorage(wrappedValue: AgentAccess.draft.rawValue, "agentAccess.\(model.liveProject.id)")
    }
    private var sessions: [MCPSession] { MCPServer.shared.projectSessions(model) }
    private var session: MCPSession? {
        sessions.first { $0.id == selectedSessionID } ?? sessions.first { $0.id == model.reviewSessionID }
            ?? sessions.first { $0.draft != nil && $0.draft?.verdict == nil } ?? sessions.first
    }
    private static let clock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()
    private var activityRows: [AgentActivity.Row] { AgentActivity.shared.rows.filter { $0.projectID == model.liveProject.id } }
    private var currentCall: AgentActivity.Row? {
        AgentActivity.shared.current.values.filter { $0.projectID == model.liveProject.id }.max { $0.time < $1.time }
    }
    private var status: String {
        if let currentCall { return currentCall.intent }
        if let draft = session?.draft, draft.verdict?.hasPrefix("accepted") == true { return "Accepted \(draft.selectedCount)" }
        if session?.draft == nil, session?.lastDraftVerdict == "discarded" { return "Discarded" }
        if let latest = activityRows.last, latest.isError { return latest.result }
        if session?.connected == false { return "Disconnected" }
        if session?.draft?.submitted == true { return "Ready for review" }
        if let draft = session?.draft { return "Drafting · \(draft.selectedCount) changes" }
        return "Idle"
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Claude").font(Font(Theme.headingFont(28)))
                        Spacer()
                        Menu {
                            ForEach(AgentAccess.allCases, id: \.rawValue) { level in
                                Button(level.rawValue.capitalized) { accessRaw = level.rawValue }
                            }
                        } label: { TechMenuLabel(title: accessRaw.capitalized) }
                            .menuStyle(.borderlessButton).fixedSize()
                            .accessibilityLabel("Agent access")
                    }
                    statusStrip
                    if case .failed(let message) = DraftPlayback.shared.state {
                        Text("Play draft: \(message)").font(Font(Theme.labelFont)).foregroundStyle(Theme.dangerColor)
                            .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("agent-play-error")
                            .onTapGesture { DraftPlayback.shared.dismissFailure() }
                    }
                    if let notice = model.reviewNotice {
                        Text(notice).font(Font(Theme.labelFont)).foregroundStyle(Theme.textPrimaryColor)
                            .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("agent-watching-notice")
                    }
                    if let session {
                        if sessions.count > 1 {
                            Menu {
                                ForEach(sessions, id: \.id) { item in Button(item.agentName) { selectedSessionID = item.id } }
                            } label: { Text(session.agentName).font(Font(Theme.labelFont)) }.menuStyle(.borderlessButton)
                        }
                        if session.draft?.verdict == nil, session.draft != nil,
                           session.previewSuppressed || (model.isReviewingDraft && model.reviewSessionID != session.id) {
                            Text(session.previewSuppressed ? "Preview paused. Your edits take priority." : "Another draft is shown. This draft stays hidden.")
                                .font(Font(Theme.labelFont)).foregroundStyle(Theme.warningColor).fixedSize(horizontal: false, vertical: true)
                        }
                        if let error = session.reviewError {
                            Text("Error: \(error)").font(Font(Theme.bodyFont)).foregroundStyle(Theme.dangerColor)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let draft = session.draft {
                            draftContent(draft, session: session)
                        } else if session.lastDraftVerdict == nil {
                            Text("Edits arrive here as a draft.")
                                .font(Font(Theme.bodyFont)).foregroundStyle(Theme.textSecondaryColor)
                        }
                    } else {
                        Text("Agent sessions and drafts appear here.").font(Font(Theme.bodyFont)).foregroundStyle(Theme.textSecondaryColor)
                    }
                    activity
                }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
            Divider().overlay(Theme.strokeColor)
            HStack {
                let playback = DraftPlayback.shared
                Button(playButtonTitle(playback)) { if let session { playback.toggle(model: model, session: session) } }
                    .buttonStyle(TechButtonStyle(kind: .secondary, compact: true))
                    .disabled(!playback.isRendering && !playback.canPlay(model: model, session: session))
                    .accessibilityIdentifier("agent-play-draft")
                Spacer()
                let draft = session?.draft
                let canAccept = session != nil && draft?.submitted == true && draft?.verdict == nil && model.reviewSessionID == session?.id
                let accepted = draft?.verdict?.hasPrefix("accepted") == true
                Button("\(accepted ? "Accepted" : "Accept") \(draft?.selectedCount ?? 0)") {
                    if let session { run(session) { try MCPServer.shared.finishReview(session, commit: true) } }
                }
                .buttonStyle(TechButtonStyle(kind: canAccept ? .primary : .secondary, compact: true)).disabled(!canAccept)
                .animation(.easeOut(duration: reduceMotion ? 0.14 : 0.32), value: canAccept)
                .accessibilityIdentifier("agent-accept")
            }.padding(.horizontal, 16).padding(.vertical, 12).background(Theme.bgPanelColor)
        }
        .onChange(of: session?.draft?.id) { _, id in
            expanded = []
            if id == nil { activityExpanded = false }
        }
        .onChange(of: session?.id) { _, _ in activityExpanded = false }
    }

    private func playButtonTitle(_ playback: DraftPlayback) -> String {
        if case .rendering(let value) = playback.state { return "Cancel \(Int((value * 100).rounded()))%" }
        return "Play draft"
    }

    private var statusStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(status).font(Font(Theme.labelFont)).foregroundStyle(Theme.textSecondaryColor)
                .lineLimit(1).frame(height: 16, alignment: .leading).help(session.map { "\($0.agentName): \(status)" } ?? status)
                .id(status).transition(.opacity)
                .animation(.easeOut(duration: reduceMotion ? 0.14 : 0.32), value: status)
                .accessibilityIdentifier("agent-status")
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Theme.strokeColor)
                    Rectangle().fill(Theme.textPrimaryColor)
                        .frame(width: geometry.size.width * (reduceMotion ? 1 : rail)).opacity(reduceMotion ? Double(rail) : 1)
                }
            }.frame(height: 1).accessibilityHidden(true)
        }
        .task(id: "\(currentCall?.id.uuidString ?? "idle"):\(activityRows.last?.id.uuidString ?? "none"):\(reduceMotion)") {
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) { rail = 0 }
            guard currentCall == nil, !activityRows.isEmpty else { return }
            do {
                try await Task.sleep(for: .milliseconds(16))
                try Task.checkCancellation()
                withAnimation(.timingCurve(0.2, 0.7, 0.2, 1, duration: reduceMotion ? 0.14 : 0.32)) { rail = 1 }
            } catch { }
        }
    }

    @ViewBuilder private func draftContent(_ draft: AgentDraft, session: MCPSession) -> some View {
        if let note = draft.note, !note.isEmpty {
            Text(note).font(Font(Theme.bodyFont)).fixedSize(horizontal: false, vertical: true)
        }
        let stale = draft.verdict == nil && !model.isReviewingDraft && draft.base != (try? MCPTools.revision(model.liveProject))
        if stale {
            VStack(alignment: .leading, spacing: 8) {
                Text("Draft is based on an older version").font(Font(Theme.bodyFont))
                Button("Replay on current") { run(session) { try MCPServer.shared.review(session, rebase: true) } }
                    .buttonStyle(TechButtonStyle(kind: .secondary, compact: true))
            }.padding(.leading, 10).overlay(alignment: .leading) { Rectangle().fill(Theme.warningColor).frame(width: 2) }
        } else if draft.verdict == nil && model.reviewSessionID != session.id {
            Button("Review draft") { run(session) { try MCPServer.shared.review(session) } }
                .buttonStyle(TechButtonStyle(kind: .secondary, compact: true)).disabled(model.isReviewingDraft || !draft.submitted)
        }
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(draft.selectedCount) changes").font(Font(Theme.labelFont))
            Spacer(minLength: 0)
            Text(String(format: "%.1f s", draft.duration)).font(Font(Theme.headingFont(22)))
            Text(delta(draft.duration - draft.baseProject.exportDuration)).font(Font(Theme.labelFont)).foregroundStyle(Theme.textSecondaryColor)
        }.monospacedDigit().accessibilityIdentifier("agent-summary")
        VStack(spacing: 0) {
            Divider().overlay(Theme.strokeColor)
            ForEach(draft.groups) { group in
                let selected = group.rows.filter { !draft.excluded.contains($0.id) && draft.skipped[$0.id] == nil }
                DisclosureGroup(isExpanded: Binding(get: { expanded.contains(group.kind) }, set: { open in
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.32)) {
                        if open { expanded.insert(group.kind) } else { expanded.remove(group.kind) }
                    }
                })) {
                    VStack(spacing: 0) {
                        ForEach(Array(group.rows.enumerated()), id: \.element.id) { index, row in
                            changeRow(row, draft: draft, session: session)
                                .modifier(AgentRowReveal(order: index))
                        }
                    }.padding(.leading, 8)
                } label: {
                    HStack(spacing: 6) {
                        AgentGroupCheckbox(state: selected.isEmpty ? .off : selected.count == group.rows.count ? .on : .mixed,
                                           label: "Include \(group.kind.rawValue.lowercased())", enabled: model.reviewSessionID == session.id && draft.submitted) {
                            run(session) { try MCPServer.shared.include(group.rows.map(\.id), in: session, included: selected.count != group.rows.count) }
                        }.frame(width: 24, height: 24)
                        Rectangle().fill(swatch(group.kind)).frame(width: 10, height: 10).accessibilityHidden(true)
                        Text(group.kind.rawValue)
                        Spacer(minLength: 0)
                        Text("\(group.rows.count)").foregroundStyle(Theme.textTertiaryColor)
                        Text(delta(selected.reduce(0) { $0 + $1.change.delta })).frame(minWidth: 52, alignment: .trailing)
                    }.font(Font(Theme.labelFont)).monospacedDigit()
                }.disclosureGroupStyle(AgentDisclosureStyle(title: group.kind.rawValue)).padding(.vertical, 5)
                    .modifier(AgentGroupArrival(token: "\(draft.id):\(group.rows.count)"))
                    .accessibilityIdentifier("agent-group-\(group.kind.rawValue.lowercased())")
                Divider().overlay(Theme.strokeColor)
            }
        }
    }

    private func changeRow(_ row: AgentDraft.Row, draft: AgentDraft, session: MCPSession) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Toggle("Include \(title(row.op))", isOn: Binding(get: { !draft.excluded.contains(row.id) && draft.skipped[row.id] == nil }, set: { included in
                    run(session) { try MCPServer.shared.include(row.id, in: session, included: included) }
                }))
                .labelsHidden().toggleStyle(.checkbox).tint(Theme.accentColor)
                .disabled(model.reviewSessionID != session.id || !draft.submitted || draft.skipped[row.id] != nil)
                .accessibilityIdentifier("agent-change-\(row.call)-\(row.index)")
                Button {
                    run(session) { model.playhead = min(model.project.exportDuration, max(0, try draft.seekTime(row, in: model.project))) }
                } label: {
                    HStack(spacing: 4) {
                        Text(title(row.op)).lineLimit(1).strikethrough(draft.excluded.contains(row.id))
                        Spacer(minLength: 0)
                        Text(time(row.change.at)).foregroundStyle(Theme.textSecondaryColor)
                    }.frame(maxWidth: .infinity, minHeight: 24, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).help("Seek to this change")
                    .accessibilityLabel("Seek to \(title(row.op)) at \(time(row.change.at))")
            }.font(Font(Theme.labelFont)).monospacedDigit()
            if let reason = draft.skipped[row.id] {
                Text("Skipped: \(reason)").font(Font(Theme.captionFont)).foregroundStyle(Theme.warningColor)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let note = row.change.note, !note.isEmpty {
                Text(note).font(Font(Theme.captionFont)).foregroundStyle(Theme.textSecondaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.vertical, 4)
    }

    private var activity: some View {
        let rows = Array(activityRows.suffix(50).reversed())
        return DisclosureGroup(isExpanded: $activityExpanded) {
            if rows.isEmpty { Text("No tool calls yet.").font(Font(Theme.captionFont)).foregroundStyle(Theme.textSecondaryColor) }
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(Self.clock.string(from: row.time)); Spacer(minLength: 0); Text("\(row.ms) ms")
                    }.font(Font(Theme.captionFont)).foregroundStyle(Theme.textTertiaryColor)
                    Text(row.intent).font(Font(Theme.labelFont)).fixedSize(horizontal: false, vertical: true)
                    Text(row.result).font(Font(Theme.captionFont))
                        .foregroundStyle(row.isError ? Theme.dangerColor : Theme.textSecondaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                }.padding(.vertical, 7).help(row.tool).modifier(AgentRowReveal(order: index))
            }
        } label: {
            HStack { Text("Activity"); Spacer(); Text("\(rows.count)") }.font(Font(Theme.labelFont))
        }.disclosureGroupStyle(AgentDisclosureStyle(title: "Activity"))
    }
    private func swatch(_ kind: AgentChangeKind) -> Color {
        switch kind {
        case .cuts, .speed: Theme.clipColor
        case .zoom: Theme.zoomColor
        case .text: Theme.textColor
        case .markers: Theme.layoutColor
        case .other: Theme.maskColor
        }
    }
    private func run(_ session: MCPSession, _ action: () throws -> Void) {
        do { try action() } catch { session.reviewError = (error as? MCPFailure)?.message ?? String(describing: error) }
    }
    private func time(_ value: Double) -> String {
        let tenth = Int((value * 10).rounded()); return String(format: "%d:%02d.%d", tenth / 600, tenth / 10 % 60, tenth % 10)
    }
    private func delta(_ value: Double) -> String {
        abs(value) < 0.001 ? "—" : String(format: value < 0 ? "−%.1f s" : "+%.1f s", abs(value))
    }
    private func title(_ op: EditOp) -> String {
        switch op {
        case .cut: "Cut range"
        case .cutPauses: "Cut pauses"
        case .cutWords: "Cut words"
        case .speed: "Playback speed"
        case .zoom: "Zoom"
        case .text: "Add text"
        case .captions: "Captions"
        case .highlight: "Highlight"
        case .marker: "Marker"
        case .set: "Set block"
        case .remove: "Remove block"
        case .style: "Styling"
        case .layer: "Add layer"
        case .reframe: "Reframe"
        }
    }
}

private struct AgentGroupArrival: ViewModifier {
    let token: String
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.agentReduceMotionPreview) private var previewReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || previewReduceMotion }
    @State private var extent: CGFloat = 0
    @State private var edge = 0.0
    func body(content: Content) -> some View {
        content.mask(alignment: .leading) {
            GeometryReader { geometry in Rectangle().frame(width: geometry.size.width * (reduceMotion ? 1 : extent)) }
        }.opacity(reduceMotion ? Double(extent) : 1)
            .overlay(alignment: .leading) {
                Rectangle().fill(Theme.textPrimaryColor).frame(width: 2).opacity(reduceMotion ? 0 : edge)
                    .offset(x: -16).allowsHitTesting(false)
            }
            .task(id: "\(token):\(reduceMotion)") {
                do {
                    var transaction = Transaction(); transaction.disablesAnimations = true
                    withTransaction(transaction) { edge = reduceMotion ? 0 : 1 }
                    try await Task.sleep(for: .milliseconds(16))
                    try Task.checkCancellation()
                    withAnimation(.timingCurve(0.2, 0.7, 0.2, 1, duration: reduceMotion ? 0.14 : 0.32)) { extent = 1 }
                    withAnimation(.easeOut(duration: 0.7)) { edge = 0 }
                } catch { }
            }
    }
}

private struct AgentPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(configuration.isPressed ? Theme.bgHoverColor : .clear)
            .animation(.easeOut(duration: Theme.Motion.press), value: configuration.isPressed)
    }
}

private struct AgentDisclosureStyle: DisclosureGroupStyle {
    let title: String
    func makeBody(configuration: Configuration) -> some View {
        AgentDisclosureBody(configuration: configuration, title: title)
    }
}

private struct AgentDisclosureBody: View {
    let configuration: DisclosureGroupStyleConfiguration
    let title: String
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.agentReduceMotionPreview) private var previewReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || previewReduceMotion }
    @State private var hovered = false
    private func toggle() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.32)) { configuration.isExpanded.toggle() }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                Button(action: toggle) {
                    Image(systemName: "chevron.right").font(.system(size: 10))
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .frame(width: 16, height: 28)
                }.buttonStyle(AgentPressStyle()).foregroundStyle(Theme.textTertiaryColor)
                    .accessibilityLabel("\(configuration.isExpanded ? "Collapse" : "Expand") \(title)")
                    .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
                configuration.label.contentShape(Rectangle()).onTapGesture(perform: toggle)
            }.background(hovered ? Theme.bgControlColor : .clear)
                .onHover { hovered = $0 }.animation(reduceMotion ? nil : .easeOut(duration: Theme.Motion.hover), value: hovered)
            if configuration.isExpanded { configuration.content }
        }
    }
}

private struct AgentRowReveal: ViewModifier {
    let order: Int
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.agentReduceMotionPreview) private var previewReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || previewReduceMotion }
    @State private var visible = false
    func body(content: Content) -> some View {
        content.opacity(visible ? 1 : 0).offset(x: visible || reduceMotion ? 0 : -4)
            .task(id: reduceMotion) {
                do {
                    if !reduceMotion { try await Task.sleep(for: .milliseconds(order * 55)) }
                    try Task.checkCancellation()
                    withAnimation(.easeOut(duration: reduceMotion ? 0.14 : 0.32)) { visible = true }
                } catch { }
            }
    }
}

private struct AgentGroupCheckbox: NSViewRepresentable {
    let state: NSControl.StateValue
    let label: String
    let enabled: Bool
    let action: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: "", target: context.coordinator, action: #selector(Coordinator.toggle))
        button.allowsMixedState = true
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        button.state = state; button.isEnabled = enabled; button.setAccessibilityLabel(label)
        context.coordinator.action = action
    }
    final class Coordinator: NSObject {
        var action: (() -> Void)?
        @objc func toggle() { action?() }
    }
}
