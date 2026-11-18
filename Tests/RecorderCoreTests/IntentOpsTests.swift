import Foundation
import Testing
@testable import RecorderCore

@Suite struct IntentOpsTests {
    let board = EditReportTests.board()
    let base = EditReportTests.project()

    func lower(_ json: String, clicks: [InputEvent] = [], project: Project? = nil, board custom: Storyboard? = nil) throws -> (ops: [EditOp], lowered: [LoweredIntent], origin: [Int]) {
        let raw = try JSONDecoder().decode([JSONValue].self, from: Data(json.utf8))
        let r = try lowerIntents(raw, project: project ?? base, clicks: clicks) { custom ?? board }
        return (try JSONDecoder().decode([EditOp].self, from: JSONEncoder().encode(r.ops)), r.lowered, r.origin)
    }
    func one(_ shots: [Shot]) -> Storyboard { Storyboard(duration: 20, fps: 10, shots: shots, summary: StoryboardSummary(shots: shots.count, aslSec: 0, staticSec: 0, longestStatic: nil)) }
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
        #expect(byID.lowered.first?.shots?.filter(\.kept).map(\.id) == ["s01", "s04"])   // dry run shows the verdict per shot
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
        #expect(abs(after.exportDuration - 10.73) < 0.05)
        #expect(!lint(after, storyboard: board).contains { $0.rule == "maxStatic" })
    }

    @Test func fitDurationCountsAnOutroLayerPastTheVideo() throws {
        var outro = base
        let video = base.exportDuration
        // Like a real outro: anchored at the last source second, running 3 s past the video's end.
        outro.layers.append(LayerBlock(kind: .video, start: base.source.duration - 0.5, end: base.source.duration + 2.5, file: "media/outro.mov", rect: NormRect()))
        #expect(abs(outro.exportDuration - (video + 2.5)) < 0.01)
        let r = try lower(#"[{"op":"fitDuration","target":12,"tolerance":0.5}]"#, project: outro)
        let after = try outro.applying(r.ops, context: EditContext()).project
        #expect(abs(after.exportDuration - 12) <= 0.5)                               // the outro moves earlier, export hits target
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

    // Review fixes

    @Test func speedsAreAbsoluteSoExistingSpeedIsMultiplied() throws {
        let fast = EditReportTests.project([Clip(sourceStart: 0, sourceEnd: 12), Clip(sourceStart: 12, sourceEnd: 20, speed: 2)])   // s05 plays 4 s
        let r = try lower(#"[{"op":"pace"}]"#, project: fast)
        #expect(r.ops.contains(.speed(from: 12, to: 16, speed: 6.68, snap: true)))   // 2x * 3.34
        let hold = try #require(lint(fast, storyboard: board).first { $0.rule == "maxStatic" && $0.shot == "s05" })
        #expect(hold.suggest == opJSON("speed", ["from": .number(12), "to": .number(16), "speed": .number(6.68), "snap": .bool(true)]))
        let ramp = try lower(#"[{"op":"speed","from":2,"to":6,"speed":8,"ramp":{"in":0.4,"out":0.4}}]"#, project: EditReportTests.project([Clip(sourceStart: 0, sourceEnd: 20, speed: 2)]))
        let speeds = ramp.ops.compactMap { op -> Double? in if case .speed(_, _, let s, _) = op { return s }; return nil }
        #expect(speeds.first! > 2 && speeds.last! > 2 && speeds.last! < 8)           // eases from 2x, not from 1x
    }

    @Test func oneLengthChangingIntentPerBatch() throws {
        #expect(throws: EditError.invalidOp(index: 1, reason: "only one of keepShots/pace/fitDuration per batch; call edit.apply once per intent")) {
            try lower(#"[{"op":"pace"},{"op":"fitDuration","target":10}]"#)
        }
        #expect(try lower(#"[{"op":"pace"},{"op":"autoZoom"},{"op":"cut","from":0,"to":1}]"#).ops.isEmpty == false)
    }

    @Test func loweredOpsKeepTheirOriginalBatchIndex() throws {
        let r = try lower(#"[{"op":"marker","at":1,"label":"a"},{"op":"keepShots","shots":["s01"]},{"op":"cut","from":0,"to":1}]"#)
        #expect(r.origin == [0, 1, 1, 2])
        #expect(EditError.invalidOp(index: 2, reason: "x").remapped(r.origin) == .invalidOp(index: 1, reason: "x"))
    }

    @Test func paceRoundsUpAndAvoidsSliverCuts() throws {
        let b = one([Shot(id: "s00", from: 0, to: 7.25, kind: .static, boundary: .start)])
        let r = try lower(#"[{"op":"pace"}]"#, board: b)
        #expect(r.ops == [.speed(from: 0, to: 7.25, speed: 6.05, snap: true)])      // 6.0417 rounded up, 0.05 s remainder not cut
        _ = try apply(r.ops)   // lowered batch applies
        let held = one([Shot(id: "s00", from: 0, to: 8, kind: .payoff, boundary: .start, clicks: [1])])
        // beat cut: keep [click - 0.1, click + payoff 1.3], lose the wait before and the hold after
        #expect(try lower(#"[{"op":"pace"}]"#, board: held).ops == [.cut(from: 0, to: 0.9, snap: true), .cut(from: 2.3, to: 8, snap: true)])
        let moving = one([Shot(id: "s00", from: 0, to: 4, kind: .motion, boundary: .start), Shot(id: "s01", from: 4, to: 8, kind: .typing, boundary: .type)])
        #expect(try lower(#"[{"op":"pace"}]"#, board: moving).ops == [.speed(from: 0, to: 4, speed: 1.5, snap: true), .speed(from: 4, to: 8, speed: 1.5, snap: true)])
    }

    @Test func autoZoomSkipsExistingZoomsAndShortPieces() throws {
        let clicks = [InputEvent(t: 5, k: .down, x: 0.5, y: 0.5, b: 0), InputEvent(t: 6, k: .down, x: 0.5, y: 0.5, b: 0)]
        let withZoom = EditReportTests.project(zooms: [Zoom(start: 7, end: 9)])
        #expect(try lower(#"[{"op":"autoZoom"}]"#, clicks: clicks, project: withZoom).ops.isEmpty)
        let sped = EditReportTests.project([Clip(sourceStart: 0, sourceEnd: 20, speed: 8)])   // 2.9 source s = 0.36 s on screen
        #expect(try lower(#"[{"op":"autoZoom"}]"#, clicks: clicks, project: sped).ops.count == 1)   // source length counts, not output
    }

    @Test func keepShotsNeverDeletesImportedClips() throws {
        var imported = Clip(sourceStart: 0, sourceEnd: 3); imported.file = "media/x.mov"
        let p = EditReportTests.project([Clip(sourceStart: 0, sourceEnd: 20), imported])
        let r = try lower(#"[{"op":"keepShots","shots":["s01"]}]"#, project: p)
        #expect(r.ops == [.cut(from: 0, to: 3, snap: true), .cut(from: 4, to: 20, snap: true)])   // 20…23 is the imported clip
    }

    // Run-2b feedback R2-10/R2-12: keepShots → pace → fitDuration chain on a project whose source runs past its last clip.
    @Test func intentChainSurvivesTrailingGapAndSlivers() throws {
        var gap = Clip(sourceStart: 19.4, sourceEnd: 20); gap.isGap = true
        var project = EditReportTests.project([Clip(sourceStart: 0, sourceEnd: 19.4), gap])
        func step(_ json: String) throws {
            let r = try lowerIntents(try JSONDecoder().decode([JSONValue].self, from: Data(json.utf8)), project: project) { board }
            let ops = try JSONDecoder().decode([EditOp].self, from: JSONEncoder().encode(r.ops))
            let applied = try project.applying(ops, context: EditContext())
            let skipped = applied.changes.contains { $0.skipped }
            #expect(!skipped)                                                        // the tail cut stops at the footage, not the gap
            project = applied.project
        }
        project = try project.applying([.cut(from: 0, to: 2.996)], context: EditContext()).project   // s00 leaves a 0.004 s sliver
        try step(#"[{"op":"fitDuration","target":14,"tolerance":0.5}]"#)              // was OUT_OF_RANGE: cut 0.00–0.00
        try step(#"[{"op":"keepShots","where":{"kind":["payoff","motion","typing","static"]}}]"#)
        try step(#"[{"op":"pace","maxStatic":0.8}]"#)
        try step(#"[{"op":"fitDuration","target":5,"tolerance":0.5}]"#)
        #expect(project.exportDuration <= 5.5)
    }

    // R2-11: an energy filter drops calm close-ups of the subject; protect by caption keeps them.
    @Test func keepShotsProtectsByCaption() throws {
        var shots = board.shots
        shots[5].caption = "Graph Editor"; shots[5].energy = 0.02
        let r = try lower(#"[{"op":"keepShots","where":{"kind":["payoff"]},"protect":["caption~graph","s04"]}]"#, board: one(shots))
        #expect(r.lowered[0].shots?.filter(\.kept).map(\.id) == ["s01", "s04", "s05"])
        #expect(throws: EditError.self) { try lower(#"[{"op":"keepShots","protect":"s01"}]"#) }
    }
}
