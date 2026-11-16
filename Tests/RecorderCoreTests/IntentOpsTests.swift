import Foundation
import Testing
@testable import RecorderCore

@Suite struct IntentOpsTests {
    let board = EditReportTests.board()
    let base = EditReportTests.project()

    func lower(_ json: String, clicks: [InputEvent] = []) throws -> (ops: [EditOp], lowered: [LoweredIntent]) {
        let raw = try JSONDecoder().decode([JSONValue].self, from: Data(json.utf8))
        let r = try lowerIntents(raw, project: base, clicks: clicks) { board }
        return (try JSONDecoder().decode([EditOp].self, from: JSONEncoder().encode(r.ops)), r.lowered)
    }
    /// One `applying` call is the whole batch: the editor wraps it in a single `model.edit`, i.e. one undo step.
    func apply(_ ops: [EditOp]) throws -> Project {
        let r = try base.applying(ops, context: EditContext())
        #expect(r.changes.count == ops.count)
        return r.project
    }

    @Test func keepShotsCutsEverythingElse() throws {
        let byID = try lower(#"[{"op":"keepShots","shots":["s01","s04"]}]"#)
        #expect(byID.ops == [.cut(from: 0, to: 3, snap: true), .cut(from: 4, to: 10, snap: true), .cut(from: 12, to: 20, snap: true)])
        #expect(byID.lowered.first?.ops.count == 3)
        #expect(try apply(byID.ops).exportDuration == 3)
        let byKind = try lower(#"[{"op":"keepShots","where":{"kind":["payoff","typing"]}}]"#)
        #expect(byKind.ops == byID.ops)
        let trimmed = try lower(#"[{"op":"keepShots","shots":["s01","s04"],"trim":{"lead":0.2,"tail":0.2}}]"#)
        #expect(abs(try apply(trimmed.ops).exportDuration - 2.2) < 0.01)
        #expect(throws: EditError.self) { try lower(#"[{"op":"keepShots","shots":["s99"]}]"#) }
        #expect(throws: EditError.self) { try lower(#"[{"op":"keepShots","where":{"minEnergy":5}}]"#) }
    }

    @Test func paceSqueezesHoldsAndLeavesResults() throws {
        let r = try lower(#"[{"op":"pace"}]"#)
        #expect(r.ops.contains(.speed(from: 0, to: 3, speed: 2.5, snap: true)))      // 3 s hold, 2.5x fits maxStatic 1.2 exactly
        #expect(r.ops.contains(.speed(from: 12, to: 19.2, speed: 6, snap: true)) && r.ops.contains(.cut(from: 19.2, to: 20, snap: true)))
        #expect(!r.ops.contains { if case .cut(.seconds(let a), _, _) = $0 { return a >= 4.2 && a < 10 }; return false })   // tagged result stays
        let after = try apply(r.ops)
        #expect(abs(after.exportDuration - 10.3) < 0.1)
        #expect(!lint(after, storyboard: board).contains { $0.rule == "maxStatic" })
    }

    @Test func fitDurationHitsTargetAndProtects() throws {
        let r = try lower(#"[{"op":"fitDuration","target":12,"tolerance":0.5}]"#)
        #expect(r.lowered[0].dropped == ["s05"])
        #expect(abs(try apply(r.ops).exportDuration - 12) <= 0.5)
        let kept = try lower(#"[{"op":"fitDuration","target":12,"tolerance":0.5,"protect":["s05"]}]"#)
        #expect(kept.lowered[0].dropped == ["s00"])                                  // protected hold survives
        let out = try apply(kept.ops)
        #expect(abs(out.exportDuration - 12) <= 0.5)
        #expect(!kept.ops.contains { if case .cut(.seconds(let a), _, _) = $0 { return a >= 12 }; return false })
        let impossible = try lower(#"[{"op":"fitDuration","target":1,"protect":["s00","s01","s02","s03","s04","s05"]}]"#)
        #expect(impossible.ops.isEmpty && impossible.lowered[0].note != nil)
        #expect(try lower(#"[{"op":"fitDuration","target":30}]"#).ops.isEmpty)       // already short enough
    }

    @Test func speedRampStepsUpAndDown() throws {
        let r = try lower(#"[{"op":"speed","from":2,"to":6,"speed":3,"ramp":{"in":0.2,"out":0.4}}]"#)
        let speeds = r.ops.compactMap { op -> Double? in if case .speed(_, _, let s, _) = op { return s }; return nil }
        #expect(speeds.count == r.ops.count && speeds.count == 1 + 1 + 2)
        #expect(speeds[0] < 3 && speeds[1] == 3 && speeds[2] < 3 && Array(speeds[2...]) == speeds[2...].sorted(by: >))
        #expect(speeds.max() == 3 && speeds.first! > 1 && speeds.last! > 1)
        let after = try apply(r.ops)
        #expect(after.exportDuration < 20 && after.exportDuration > 20 - 4 * (1 - 1 / 3.0) - 0.01)
        #expect(try lower(#"[{"op":"speed","from":2,"to":3,"speed":2}]"#).lowered.isEmpty)   // no ramp: untouched
    }

    @Test func autoZoomExposesClusteringWithLeadAndTail() throws {
        let clicks = [InputEvent(t: 5, k: .down, x: 0.5, y: 0.5, b: 0), InputEvent(t: 6, k: .down, x: 0.5, y: 0.5, b: 0)]
        let r = try lower(#"[{"op":"autoZoom"}]"#, clicks: clicks)
        #expect(r.ops == [.zoom(from: 4.6, to: 7.5, scale: 2, center: nil)])
        let custom = try lower(#"[{"op":"autoZoom","lead":0,"tail":1,"scale":1.5}]"#, clicks: clicks)
        #expect(custom.ops == [.zoom(from: 5, to: 7, scale: 1.5, center: nil)])
        #expect(try apply(r.ops).zooms.count == 1)
    }

    @Test func mixedBatchKeepsOrderAndPassesPrimitivesThrough() throws {
        let r = try lower(#"[{"op":"marker","at":1,"label":"a"},{"op":"keepShots","shots":["s01"]},{"op":"cut","from":0,"to":1}]"#)
        #expect(r.ops.first == .marker(at: 1, label: "a") && r.ops.last == .cut(from: 0, to: 1))
        #expect(r.lowered.map(\.op) == [1])
    }
}
