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
    func apply(_ project: Project, _ json: String) throws -> Project { try applyLowered(project, json).project }
    func applyLowered(_ project: Project, _ json: String) throws -> (project: Project, lowered: [LoweredIntent]) {
        let raw = try JSONDecoder().decode([JSONValue].self, from: Data(json.utf8))
        let lowered = try lowerIntents(raw, project: project) { board }
        let ops = try JSONDecoder().decode([EditOp].self, from: JSONEncoder().encode(lowered.ops))
        let result = try project.applying(ops, context: EditContext())
        let skipped = result.changes.filter(\.skipped).map { "\(ops[$0.op]) \($0.note ?? "")" }
        #expect(skipped.isEmpty, "\(json): skipped \(skipped)")
        try check(result.project, after: json)
        return (result.project, lowered.lowered)
    }

    /// What must hold after any step.
    func check(_ p: Project, after step: String) throws {
        #expect(p.checkInvariants() == nil, "\(step): \(p.checkInvariants() ?? "")")
        let report = editReport(before: base, after: p, storyboard: board)
        for item in report.lint {
            // Every suggestion must apply as-is (R2-2), and no zero-length shot is reported (R2-3).
            #expect(!item.msg.contains("lasts 0.0") && !item.msg.contains("for 0.0"), "\(step): \(item.msg)")
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

    /// Run 4, the agent's exact pipeline: remove the tail layer → keepShots minEnergy 0.05 → pace → fitDuration 30 even
    /// minPerSection 2 → apply lint's flicker cuts → reframe 1:1. Each assertion is a run-4 finding.
    @Test func run4PipelineShipsCleanAndBalanced() throws {
        var p = try apply(base, #"[{"op":"remove","id":"\#(base.layers[0].id)"}]"#)
        p = try apply(p, #"[{"op":"keepShots","where":{"minEnergy":0.05}}]"#)
        let paced = try applyLowered(p, #"[{"op":"pace"}]"#)
        let speeds = paced.lowered[0].ops.filter { if case .object(let o) = $0 { return o["op"] == .string("speed") }; return false }.count
        #expect(Double(speeds) <= Double(paced.lowered[0].ops.count) / 2, "pace is still mostly a blanket speed-up (R4-5)")
        p = paced.project
        let fit = try applyLowered(p, #"[{"op":"fitDuration","target":30,"balance":"even","minPerSection":2}]"#)
        p = fit.project
        let sections = try #require(editReport(before: base, after: p, storyboard: board).sections)
        for s in sections where s.keptSec < 2 - 0.01 {   // R4-2: never silently under the minimum
            #expect(fit.lowered[0].note?.contains("section \(s.section) keeps") == true, "section \(s.section) short without a note")
        }
        #expect(sections.allSatisfy { $0.keptSec == 0 ? $0.outFrom == nil : $0.outFrom != nil && $0.srcTo > $0.srcFrom })   // R4-4
        for item in lint(p, storyboard: board) where item.rule == "tinyShot" {   // the agent's "cut flicker" step
            guard let s = item.suggest else { continue }
            p = try apply(p, String(decoding: try JSONEncoder().encode([s]), as: UTF8.self))
            break   // later suggestions moved with that cut; one per apply, like the agent
        }
        let keys = reframePlan(storyboard: board, aspect: .r1x1, mode: .perShot, sourceSize: CGSize(width: base.source.pixelWidth, height: base.source.pixelHeight))
        p = try p.applying([.reframe(aspect: .r1x1, mode: .perShot, keys: keys)], context: EditContext()).project
        let report = editReport(before: base, after: p, storyboard: board)
        #expect(abs(report.duration.after - 30) <= 2.5, "duration \(report.duration.after)")
        #expect(LintProfile.reel.asl.contains(report.aslSec.after), "asl \(report.aslSec.after)")
        #expect(report.reframeJumps == 0)
        #expect(!report.lint.contains { $0.rule == "edgeContent" }, "\(report.lint.filter { $0.rule == "edgeContent" }.map(\.msg))")
    }

    /// R4-3: a weak section can be dropped whole, and the rest still balances.
    @Test func fitDurationDropsChosenSections() throws {
        let fit = try applyLowered(base, #"[{"op":"fitDuration","target":30,"balance":"even","minPerSection":2,"drop":[3]}]"#)
        let sections = try #require(editReport(before: base, after: fit.project, storyboard: board).sections)
        #expect(sections.first { $0.section == 3 }?.keptSec == 0)
        #expect(sections.filter { $0.section != 3 }.allSatisfy { $0.keptSec >= 2 - 0.01 })
    }

    /// pace follows the delivery profile: each lands in its own ASL range, slower profiles cut less and never flicker.
    @Test func paceFollowsTheProfile() throws {
        let kept = try apply(base, #"[{"op":"keepShots","where":{"minEnergy":0.05}}]"#)
        var cuts: [Int] = []
        for name in ["reel", "demo", "tutorial"] {
            let paced = try applyLowered(kept, #"[{"op":"pace","profile":"\#(name)"}]"#)
            let profile = try #require(LintProfile(name: name))
            let report = editReport(before: base, after: paced.project, storyboard: board, profile: profile)
            #expect(profile.asl.contains(report.aslSec.after), "\(name) asl \(report.aslSec.after)")
            if name != "reel" { #expect(!report.lint.contains { $0.rule == "tinyShot" }, "\(name) flickers") }
            cuts.append(paced.lowered[0].ops.filter { if case .object(let o) = $0 { return o["op"] == .string("cut") }; return false }.count)
        }
        #expect(cuts[0] > cuts[1] && cuts[1] > cuts[2], "cuts reel/demo/tutorial \(cuts)")
    }

    /// even = every section near the same seconds; proportional = long scenes keep more. Both exact enough to trust.
    @Test func balanceModesSplitAsAdvertised() throws {
        func sections(_ balance: String) throws -> [SectionStat] {
            let p = try apply(base, #"[{"op":"fitDuration","target":30,"minPerSection":2,"balance":"\#(balance)"}]"#)
            #expect(abs(p.exportDuration - 30) <= 2, "\(balance) duration \(p.exportDuration)")
            return try #require(editReport(before: base, after: p, storyboard: board).sections)
        }
        let even = try sections("even").map(\.keptSec)
        // Granularity: trims under 0.3 s are skipped and a trim never leaves a stub < 0.5 s, so a section can miss by ≤ 0.5 s.
        #expect(even.max()! - even.min()! <= 0.75, "even \(even)")
        let prop = try sections("proportional")
        for a in prop { for b in prop where a.srcTo - a.srcFrom >= 2 * (b.srcTo - b.srcFrom) {
            #expect(a.keptSec >= b.keptSec - 0.5, "proportional: \(a.section) (\(a.srcTo - a.srcFrom)s) keeps \(a.keptSec) < \(b.section) keeps \(b.keptSec)")
        } }
    }

    /// Every section has a representative shot to name it (never a typing shot), and the report uses its caption.
    @Test func sectionsHaveNamingShots() throws {
        let reps = board.sectionRepresentatives()
        #expect(Set(reps.compactMap(\.section)) == Set(board.shots.compactMap(\.section)))
        #expect(reps.allSatisfy { $0.kind != .typing })
        var named = board
        for i in named.shots.indices where named.shots[i].id == reps[1].id { named.shots[i].caption = "Graph editor" }
        #expect(editReport(before: base, after: base, storyboard: named).sections?.first { $0.section == reps[1].section }?.name == "Graph editor")
        // R5-2: a heading beats a longer shot's noise; noise alone names nothing.
        func shot(_ id: String, _ d: Double, _ c: String) -> Shot { Shot(id: id, from: 0, to: d, kind: .motion, boundary: .cut, caption: c) }
        #expect(sectionName([shot("a", 5, "array/range 256 type lter t"), shot("b", 3, "document"), shot("c", 1, "SOURCE ATLAS")]) == "SOURCE ATLAS")
        #expect(sectionName([shot("a", 5, "tlow 1Im 016 STEER PANOUR 7"), shot("b", 2, "Where lines run long")]) == "Where lines run long")
        #expect(sectionName([shot("a", 5, "tlow 1Im 016 ab 9")]) == nil)
    }
}

/// Feedback run 6 on the real layout: a recording layer (2×, media 21.05 s) appended after a 0.56 s tail gap.
@Suite struct GoldenIslandLayerTests {
    var base: Project { GoldenIslandTests.fixture.project }
    var layer: LayerBlock { base.layers[0] }
    func span(_ p: Project, _ id: String) -> (Double, Double)? {
        p.layers.first { $0.id == id }.flatMap { l in TimeMap(p.clips).outputTime(atSource: l.start).map { ($0, $0 + l.end - l.start) } }
    }

    /// T-903: a layer past the clips' end can be sped up, slipped and trimmed through `set`.
    @Test func layerSetRateSlipTrim() throws {
        let (start, end) = try #require(span(base, layer.id))
        let faster = try base.applying([.set(id: layer.id, fields: SetFields(mediaRate: 3))], context: EditContext()).project
        let (s1, e1) = try #require(span(faster, layer.id))
        #expect(abs(s1 - start) < 1e-9 && abs((e1 - s1) - (end - start) * 2 / 3) < 1e-6 && faster.layers[0].mediaRate == 3)
        #expect(faster.checkInvariants() == nil && faster.exportDuration < base.exportDuration)

        let slipped = try base.applying([.set(id: layer.id, fields: SetFields(mediaStart: 30))], context: EditContext()).project
        #expect(slipped.layers[0].mediaStart == 30 && span(slipped, layer.id).map { abs($0.0 - start) + abs($0.1 - end) < 1e-9 } == true)

        let trimmed = try base.applying([.set(id: layer.id, fields: SetFields(to: .seconds(end - 2)))], context: EditContext()).project
        #expect(span(trimmed, layer.id).map { abs($0.1 - (end - 2)) < 1e-6 && abs($0.0 - start) < 1e-9 } == true)
        let longer = try base.applying([.set(id: layer.id, fields: SetFields(to: .seconds(end + 1)))], context: EditContext()).project
        #expect(span(longer, layer.id).map { abs($0.1 - (end + 1)) < 1e-6 } == true)

        do { _ = try base.applying([.set(id: layer.id, fields: SetFields(mediaStart: 250))], context: EditContext()); Issue.record("slip past media end accepted") }
        catch { #expect("\(error)".contains("media")) }
        do { _ = try base.applying([.set(id: layer.id, fields: SetFields(text: "x"))], context: EditContext()); Issue.record("text on a layer accepted") }
        catch { #expect("\(error)".contains("mediaRate")) }   // the error lists the valid fields
        let json = #"{"op":"set","id":"L","to":3,"mediaStart":1,"mediaRate":2}"#
        let op = try JSONDecoder().decode(EditOp.self, from: Data(json.utf8))
        #expect(op == .set(id: "L", fields: SetFields(to: 3, mediaStart: 1, mediaRate: 2)))
        #expect(try JSONDecoder().decode(EditOp.self, from: JSONEncoder().encode(op)) == op)
    }

    /// T-904: the uncovered tail gap is linted with a cut suggestion, and that cut removes it, rippling the layer.
    @Test func uncoveredGapIsLintedAndCuttable() throws {
        let gap = try #require(uncoveredRanges(base).first)
        #expect(abs((gap.end - gap.start) - 0.5642) < 0.001)
        let items = lint(base, storyboard: GoldenIslandTests.board)
        #expect(items.contains { $0.rule == "uncovered" && $0.suggest != nil })
        let (start, _) = try #require(span(base, layer.id))
        let cut = try base.applying([.cut(from: .seconds(gap.start), to: .seconds(gap.end))], context: EditContext()).project
        #expect(uncoveredRanges(cut).isEmpty && cut.checkInvariants() == nil)
        #expect(span(cut, layer.id).map { abs($0.0 - (start - (gap.end - gap.start))) < 1e-6 } == true)
        #expect(abs(base.exportDuration - cut.exportDuration - (gap.end - gap.start)) < 1e-6)
    }
}
