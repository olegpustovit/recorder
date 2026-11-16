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
                    if let session {
                        if sessions.count > 1 {
                            Menu {
                                ForEach(sessions, id: \.id) { item in Button(item.agentName) { selectedSessionID = item.id } }
                            } label: { Text(session.agentName).font(Font(Theme.labelFont)) }.menuStyle(.borderlessButton)
                        }
                        Text("\(session.agentName) · \(session.connected ? MCPServer.shared.phase(session, model: model) : "disconnected")")
                            .font(Font(Theme.labelFont)).foregroundStyle(Theme.textSecondaryColor)
                        if let error = session.reviewError {
                            Text("Error: \(error)").font(Font(Theme.bodyFont)).foregroundStyle(Theme.dangerColor)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let draft = session.draft, draft.verdict == nil {
                            draftContent(draft, session: session)
                        } else {
                            Text(session.lastDraftVerdict ?? "Edits arrive here as a draft.")
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
                Spacer()
                let draft = session?.draft
                let canAccept = session != nil && draft?.submitted == true && draft?.verdict == nil && model.reviewSessionID == session?.id
                Button("Accept \(draft?.verdict == nil ? draft?.selectedCount ?? 0 : 0)") {
                    if let session { run(session) { try MCPServer.shared.finishReview(session, commit: true) } }
                }
                .buttonStyle(TechButtonStyle(kind: .primary, compact: true)).disabled(!canAccept)
                .accessibilityIdentifier("agent-accept")
            }.padding(.horizontal, 16).padding(.vertical, 12).background(Theme.bgPanelColor)
        }
        .onChange(of: session?.draft?.id) { _, _ in expanded = [] }
    }

    @ViewBuilder private func draftContent(_ draft: AgentDraft, session: MCPSession) -> some View {
        if let note = draft.note, !note.isEmpty {
            Text(note).font(Font(Theme.bodyFont)).fixedSize(horizontal: false, vertical: true)
        }
        let stale = !model.isReviewingDraft && draft.base != (try? MCPTools.revision(model.liveProject))
        if stale {
            VStack(alignment: .leading, spacing: 8) {
                Text("Draft is based on an older version").font(Font(Theme.bodyFont))
                Button("Replay on current") { run(session) { try MCPServer.shared.review(session, rebase: true) } }
                    .buttonStyle(TechButtonStyle(kind: .secondary, compact: true))
            }.padding(.leading, 10).overlay(alignment: .leading) { Rectangle().fill(Theme.warningColor).frame(width: 2) }
        } else if model.reviewSessionID != session.id {
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
            }
        }.padding(.vertical, 4)
    }

    private var activity: some View {
        let rows = Array(AgentActivity.shared.rows.filter { $0.projectID == model.liveProject.id }.suffix(50).reversed())
        return DisclosureGroup {
            if rows.isEmpty { Text("No tool calls yet.").font(Font(Theme.captionFont)).foregroundStyle(Theme.textSecondaryColor) }
            ForEach(rows) { row in
                HStack(spacing: 6) {
                    Text(Self.clock.string(from: row.time)).foregroundStyle(Theme.textSecondaryColor)
                    Text(row.isError ? "error · \(row.tool)" : row.tool).lineLimit(1)
                        .foregroundStyle(row.isError ? Theme.dangerColor : Theme.textPrimaryColor)
                    Spacer(minLength: 0)
                    Text("\(row.ms) ms").foregroundStyle(Theme.textSecondaryColor)
                }.font(Font(Theme.captionFont)).padding(.vertical, 5)
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
        case .update: "Update block"
        case .remove: "Remove block"
        case .style: "Styling"
        }
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
                }.buttonStyle(.plain).foregroundStyle(Theme.textTertiaryColor)
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
