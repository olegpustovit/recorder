import SwiftUI
import RecorderCore

@MainActor struct AgentPanel: View {
    let model: EditorModel
    @AppStorage private var accessRaw: String
    @State private var selectedSessionID: String?

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
                if let draft = session.draft, draft.verdict == nil {
                    if let note = draft.note, !note.isEmpty { Text(note).font(Font(Theme.bodyFont)).fixedSize(horizontal: false, vertical: true) }
                    let stale = !model.isReviewingDraft && draft.base != (try? MCPTools.revision(model.liveProject))
                    if stale {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Draft is based on an older version").font(Font(Theme.bodyFont))
                            Button("Replay on current") { run(session) { try MCPServer.shared.review(session, rebase: true) } }
                                .buttonStyle(TechButtonStyle(kind: .secondary, compact: true))
                        }.padding(.leading, 10).overlay(alignment: .leading) { Rectangle().fill(Theme.warningColor).frame(width: 2) }
                    }
                    HStack {
                        Text("Changes").font(Font(Theme.headingFont(22)))
                        Spacer()
                        Text("\(draft.selectedCount) of \(draft.rows.count)").font(Font(Theme.labelFont)).monospacedDigit()
                    }
                    VStack(spacing: 0) {
                        Divider().overlay(Theme.strokeColor)
                        ForEach(draft.rows) { row in
                            VStack(alignment: .leading, spacing: 4) {
                                Toggle(isOn: Binding(get: { !draft.excluded.contains(row.id) && draft.skipped[row.id] == nil }, set: { included in
                                    run(session) { try MCPServer.shared.include(row.id, in: session, included: included) }
                                })) {
                                    HStack(spacing: 8) {
                                        Text(title(row.op)).lineLimit(1).strikethrough(draft.excluded.contains(row.id))
                                        Spacer(minLength: 0)
                                        Text(time(row.change.at)).foregroundStyle(Theme.textSecondaryColor).monospacedDigit()
                                        if abs(row.change.delta) > 0.001 { Text(delta(row.change.delta)).monospacedDigit() }
                                    }.font(Font(Theme.labelFont))
                                }
                                .toggleStyle(.checkbox).tint(Theme.accentColor)
                                .disabled(model.reviewSessionID != session.id || draft.skipped[row.id] != nil)
                                .accessibilityIdentifier("agent-change-\(row.call)-\(row.index)")
                                .accessibilityLabel("\(title(row.op)) at \(time(row.change.at)), \(row.change.delta < 0 ? "minus" : "plus") \(String(format: "%.1f", abs(row.change.delta))) seconds")
                                if let reason = draft.skipped[row.id] {
                                    Text("Skipped: \(reason)").font(Font(Theme.captionFont)).foregroundStyle(Theme.warningColor)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }.padding(.vertical, 8)
                            Divider().overlay(Theme.strokeColor)
                        }
                    }
                    HStack {
                        Button("Discard") { run(session) { try MCPServer.shared.finishReview(session, commit: false) } }
                            .buttonStyle(TechButtonStyle(kind: .secondary, compact: true))
                        Spacer()
                        if model.reviewSessionID == session.id {
                            Button("Accept \(draft.selectedCount)") { run(session) { try MCPServer.shared.finishReview(session, commit: true) } }
                                .buttonStyle(TechButtonStyle(kind: .primary, compact: true)).disabled(draft.selectedCount == 0)
                        } else if !stale {
                            Button("Review draft") { run(session) { try MCPServer.shared.review(session) } }
                                .buttonStyle(TechButtonStyle(kind: .primary, compact: true)).disabled(model.isReviewingDraft)
                        }
                    }
                } else {
                    Text(session.lastDraftVerdict ?? "Edits arrive here as a draft.")
                        .font(Font(Theme.bodyFont)).foregroundStyle(Theme.textSecondaryColor)
                }
                if let error = session.reviewError {
                    Text("Error: \(error)").font(Font(Theme.bodyFont)).foregroundStyle(Theme.dangerColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Agent sessions and drafts appear here.").font(Font(Theme.bodyFont)).foregroundStyle(Theme.textSecondaryColor)
            }
            Text("Activity").font(Font(Theme.headingFont(22)))
            let rows = Array(AgentActivity.shared.rows.filter { $0.projectID == model.liveProject.id }.suffix(50).reversed())
            if rows.isEmpty { Text("No tool calls yet.").font(Font(Theme.captionFont)).foregroundStyle(Theme.textSecondaryColor) }
            VStack(spacing: 0) {
                ForEach(rows) { row in
                    HStack(spacing: 6) {
                        Text(Self.clock.string(from: row.time)).foregroundStyle(Theme.textSecondaryColor)
                        Text(row.isError ? "error · \(row.tool)" : row.tool).lineLimit(1)
                            .foregroundStyle(row.isError ? Theme.dangerColor : Theme.textPrimaryColor)
                        Spacer(minLength: 0)
                        Text("\(row.ms) ms").foregroundStyle(Theme.textSecondaryColor).monospacedDigit()
                    }.font(Font(Theme.captionFont)).padding(.vertical, 5)
                    Divider().overlay(Theme.strokeColor)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func run(_ session: MCPSession, _ action: () throws -> Void) {
        do { try action() } catch { session.reviewError = (error as? MCPFailure)?.message ?? String(describing: error) }
    }
    private func time(_ value: Double) -> String {
        let tenth = Int((value * 10).rounded()); return String(format: "%d:%02d.%d", tenth / 600, tenth / 10 % 60, tenth % 10)
    }
    private func delta(_ value: Double) -> String { String(format: value < 0 ? "−%.1f s" : "+%.1f s", abs(value)) }
    private func title(_ op: EditOp) -> String {
        switch op {
        case .cut: return "Cut range"
        case .cutPauses: return "Cut pauses"
        case .cutWords: return "Cut words"
        case .speed: return "Playback speed"
        case .zoom: return "Zoom"
        case .text: return "Add text"
        case .captions: return "Captions"
        case .highlight: return "Highlight"
        case .marker: return "Marker"
        case .update: return "Update block"
        case .remove: return "Remove block"
        case .style: return "Styling"
        }
    }
}
