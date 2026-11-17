import Foundation
import Testing
@testable import RecorderCore

/// Regression replay on real footage: Golden Island's frame signals, mouse events and clips (no pixels, captions or key events), dumped with
/// `Recorder --selftest shots-fixture <copy.recorder> Tests/RecorderCoreTests/Fixtures/golden-island.json`.
/// Every agent-feedback round so far found bugs that toy storyboards could not show (media vs source time, slivers,
/// trailing gap, sticky crops); these invariants run the agent's pipelines on the real layout after every step.
@Suite struct GoldenIslandTests {
    struct Fixture: Decodable { let project: Project; let fps: Double; let signals: [FrameSignal]; let events: [InputEvent] }
    static let fixture: Fixture = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/golden-island.json")
        return try! JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }()
    /// The whole Core path the app runs: segmentation → media-to-source mapping (clips carry mediaStart remaps).
    static let board = storyboard(signals: fixture.signals, fps: fixture.fps, events: fixture.events).inSource(clips: fixture.project.clips)
    var base: Project { Self.fixture.project }
    var board: Storyboard { Self.board }

    /// One edit.apply the way MCPTools runs it: lower intents, apply in one call.
    func apply(_ project: Project, _ json: String) throws -> Project {
        let raw = try JSONDecoder().decode([JSONValue].self, from: Data(json.utf8))
        let lowered = try lowerIntents(raw, project: project) { board }
        let ops = try JSONDecoder().decode([EditOp].self, from: JSONEncoder().encode(lowered.ops))
        let result = try project.applying(ops, context: EditContext())
        let skipped = result.changes.filter(\.skipped).map { "\(ops[$0.op]) \($0.note ?? "")" }
        #expect(skipped.isEmpty, "\(json): skipped \(skipped)")
        try check(result.project, after: json)
        return result.project
    }

    /// What must hold after any step.
    func check(_ p: Project, after step: String) throws {
        #expect(p.checkInvariants() == nil, "\(step): \(p.checkInvariants() ?? "")")
        let report = editReport(before: base, after: p, storyboard: board)
        for item in report.lint {
            // Every suggestion must apply as-is (R2-2), and no zero-length shot is reported (R2-3).
            #expect(!item.msg.contains("lasts 0.0"), "\(step): \(item.msg)")
            if let s = item.suggest, case .object(let o) = s, o["op"] == .string("cut") {
                let op = try JSONDecoder().decode(EditOp.self, from: JSONEncoder().encode(s))
                let trial = try p.applying([op], context: EditContext())
                #expect(trial.changes.first?.skipped == false, "\(step): suggestion \(item.msg) does not apply")
            }
        }
    }

    @Test func intentPipelineRunsCleanOnRealLayout() throws {
        var p = try apply(base, #"[{"op":"keepShots","where":{"kind":["payoff","motion","typing"]}}]"#)
        p = try apply(p, #"[{"op":"pace"}]"#)
        p = try apply(p, #"[{"op":"pace","maxStatic":0.8}]"#)                 // a second pace failed with OUT_OF_RANGE (R2-10)
        p = try apply(p, #"[{"op":"fitDuration","target":30}]"#)
        #expect(abs(p.exportDuration - 30) <= 2.5)
        p = try apply(p, #"[{"op":"fitDuration","target":20}]"#)               // and again on the result
    }

    /// R3-1: while a shot plays, the reframed crop keeps its focus box (when the box fits the window) after the ease-in,
    /// and never shows less of it than the plain centre crop.
    @Test func reframeKeepsTheFocusOnEveryShot() throws {
        let size = CGSize(width: base.source.pixelWidth, height: base.source.pixelHeight)
        for aspect in [Output.Aspect.r1x1, .r4x5, .r9x16] {
            let keys = reframePlan(storyboard: board, aspect: aspect, mode: .perShot, sourceSize: size)
            var p = base; p.cropKeys = keys
            let w = keys[0].rect.w, h = keys[0].rect.h, centre = NormRect(x: (1 - w) / 2, y: (1 - h) / 2, w: w, h: h)
            func shown(_ f: NormRect, _ r: NormRect) -> Double {
                max(0, min(f.x + f.w, r.x + r.w) - max(f.x, r.x)) * max(0, min(f.y + f.h, r.y + r.h) - max(f.y, r.y))
            }
            var misses: [String] = []
            for s in board.shots where s.duration > 0.5 {
                let f = s.focus, area = max(f.w * f.h, 1e-9)
                for k in 0...8 {
                    let t = s.from + 0.35 + (s.duration - 0.4) * Double(k) / 8
                    let c = p.cropSample(atSource: t), cover = shown(f, c) / area
                    if shown(f, c) + 1e-6 < shown(f, centre) || (f.w <= w + 1e-9 && f.h <= h + 1e-9 && cover < 0.85) {
                        misses.append(String(format: "%@ %@ t=%.2f cover %.2f", aspect.rawValue, s.id, t, cover)); break
                    }
                }
            }
            #expect(misses.isEmpty, "\(misses)")
            // R3-1: the graph view swaps (src 7–9) hold still after a full-screen change; the wire pane acts on the right.
            if aspect == .r1x1 { #expect(p.cropSample(atSource: 8).x >= 0.3, "crop x \(p.cropSample(atSource: 8).x) at src 8") }
            #expect(cropJumps(keys, storyboard: board) == 0)
        }
    }

    /// R3-2: sections come from how the project rearranges the recording (8 scenes here), and minPerSection + even
    /// balance keep every scene in a 30 s cut (plain fitDuration dropped the graph and the contour ending entirely).
    @Test func fitDurationKeepsEveryScene() throws {
        #expect(Set(board.shots.compactMap(\.section)).count == 8)
        let plain = try apply(base, #"[{"op":"fitDuration","target":30}]"#)
        #expect(editReport(before: base, after: plain, storyboard: board).sections?.contains { $0.keptSec == 0 } == true)
        let even = try apply(base, #"[{"op":"fitDuration","target":30,"minPerSection":2,"balance":"even"}]"#)
        let sections = try #require(editReport(before: base, after: even, storyboard: board).sections)
        #expect(sections.count == 8 && sections.allSatisfy { $0.keptSec >= 2 - 0.01 }, "\(sections.map(\.keptSec))")
        #expect(abs(even.exportDuration - 30) <= 2)
    }
}
