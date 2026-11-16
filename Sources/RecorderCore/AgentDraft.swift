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
        case .update, .remove, .style, .captions, .highlight: self = .other
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
