import Foundation

public enum AgentChangeKind: String, CaseIterable, Sendable {
    case cuts = "Cuts", speed = "Speed", zoom = "Zoom", text = "Text", markers = "Markers", other = "Other"

    public init(_ op: EditOp) {
        switch op {
        case .cut, .cutPauses, .cutWords: self = .cuts
        case .speed: self = .speed
        case .zoom: self = .zoom
        case .text: self = .text
        case .marker: self = .markers
        case .update, .remove, .style, .captions, .highlight, .layer: self = .other
        }
    }
}

public struct AgentDraftRow: Identifiable, Sendable {
    public let call: Int
    public let index: Int
    public let op: EditOp
    public let change: EditChange
    public var id: [Int] { [call, index] }

    public init(call: Int, index: Int, op: EditOp, change: EditChange) {
        self.call = call; self.index = index; self.op = op; self.change = change
    }

    public func outputTime(before: Project, after: Project) -> Double {
        let source = change.sourceAt ?? TimeMap(before.clips).sourceTime(atOutput: change.at)
        var output = 0.0
        for clip in after.clips {
            if source < clip.sourceStart { return output }
            if source <= clip.sourceEnd { return output + (source - clip.sourceStart) / clip.timeScale }
            output += clip.outputDuration
        }
        return output
    }
}

public struct AgentChangeGroup: Identifiable, Sendable {
    public let kind: AgentChangeKind
    public let rows: [AgentDraftRow]
    public var id: AgentChangeKind { kind }
    public var deltaSum: Double { rows.reduce(0) { $0 + $1.change.delta } }

    public static func groups(_ rows: [AgentDraftRow]) -> [Self] {
        AgentChangeKind.allCases.compactMap { kind in
            let rows = rows.filter { AgentChangeKind($0.op) == kind }
            return rows.isEmpty ? nil : Self(kind: kind, rows: rows)
        }
    }
}

/// A pending agent draft as stored in the project package (`agent-draft.json`) so it survives quitting Recorder.
/// Replaying `calls` against `baseProject` with `contexts` and the same `id` reproduces the draft's ids exactly.
public struct AgentDraftRecord: Codable, Sendable {
    public static let fileName = "agent-draft.json"
    public static let failedFileName = "agent-draft.failed.json"
    public var id: String
    public var base: String
    public var baseProject: Project
    public var calls: [[EditOp]]
    public var contexts: [EditContext]
    public var excluded: [[Int]]
    public var note: String?
    public var submitted: Bool
    public var status: String { submitted ? "submitted" : "drafting" }

    public init(id: String, base: String, baseProject: Project, calls: [[EditOp]], contexts: [EditContext], excluded: [[Int]], note: String?, submitted: Bool) {
        self.id = id; self.base = base; self.baseProject = baseProject; self.calls = calls; self.contexts = contexts
        self.excluded = excluded; self.note = note; self.submitted = submitted
    }
    public func write(to package: URL) throws {
        try JSONEncoder().encode(self).write(to: package.appendingPathComponent(Self.fileName), options: .atomic)
    }
    /// nil when there is no file; throws when it exists but cannot be decoded.
    public static func read(from package: URL) throws -> Self? {
        let url = package.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
    /// Keeps an unreadable or unrestorable draft as `agent-draft.failed.json` so the next save cannot overwrite it.
    public static func quarantine(in package: URL) {
        let failed = package.appendingPathComponent(failedFileName)
        try? FileManager.default.removeItem(at: failed)
        try? FileManager.default.moveItem(at: package.appendingPathComponent(fileName), to: failed)
    }
    public static func remove(from package: URL) { try? FileManager.default.removeItem(at: package.appendingPathComponent(fileName)) }
}
