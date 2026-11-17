import Foundation
import Testing
@testable import RecorderCore

@Suite struct EditReportTests {
    static func board(_ extra: [Shot] = []) -> Storyboard {
        let shots = [
            Shot(id: "s00", from: 0, to: 3, kind: .static, boundary: .start),
            Shot(id: "s01", from: 3, to: 4, kind: .payoff, boundary: .cut, clicks: [3.5]),
            Shot(id: "s02", from: 4, to: 4.2, kind: .motion, boundary: .scroll),
            Shot(id: "s03", from: 4.2, to: 10, kind: .cursorOnly, boundary: .cut, tag: "result"),
            Shot(id: "s04", from: 10, to: 12, kind: .typing, boundary: .type),
            Shot(id: "s05", from: 12, to: 20, kind: .static, boundary: .cut)]
        return Storyboard(duration: 20, fps: 10, shots: shots + extra, summary: StoryboardSummary(shots: 6, aslSec: 0, staticSec: 0, longestStatic: nil))
    }
    static func project(_ clips: [Clip] = [Clip(sourceStart: 0, sourceEnd: 20)], zooms: [Zoom] = [], crop: NormRect = NormRect()) -> Project {
        Project(source: Source(duration: 20), clips: clips, zooms: zooms, crop: crop)
    }
    func rules(_ p: Project, _ profile: LintProfile = .reel) -> [String] { lint(p, storyboard: Self.board(), profile: profile).map(\.rule) }

    @Test func reportMetricsFollowTheEdit() throws {
        let base = Self.project()
        let after = try base.applying([.cut(from: 0, to: 3)], context: EditContext()).project
        let r = editReport(before: base, after: after, storyboard: Self.board())
        #expect(r.duration == .init(before: 20, after: 17))
        #expect(r.hookSec == 0.5)                                   // click at 3.5 s lands at 0.5 s once s00 is gone
        #expect(r.staticSec == .init(before: 16.8, after: 13.8))    // static + cursorOnly shots
        #expect(r.longestStatic == .init(sec: 8, at: 9))
        #expect(r.aslSec == .init(before: 5, after: 5.67))          // visual shots: cut boundaries at 3, 4.2, 12; after: 1.2, 9
        #expect(abs(r.subShotAslSec!.before - 20.0 / 6) < 0.01)     // 6 analyzer shots
        #expect(abs(r.subShotAslSec!.after - 17.0 / 5) < 0.01)      // s00 dropped, not counted as 0
    }

    @Test func partialCutShortensAndSpeedMapsToOutputTime() throws {
        let sped = try Self.project().applying([.speed(from: 12, to: 20, speed: 4)], context: EditContext()).project
        let r = editReport(before: Self.project(), after: sped, storyboard: Self.board())
        #expect(r.longestStatic?.sec == 5.8)                       // s05 now 2 s, s03 is the longest
        #expect(abs(r.duration.after - 14) < 0.01)
    }

    @Test func reelRulesFire() {
        let found = lint(Self.project(), storyboard: Self.board())
        let names = found.map(\.rule)
        #expect(names.contains("hook") && names.contains("tinyShot") && names.contains("asl"))
        #expect(!names.contains("duration"))                              // 20 s is inside 15–45
        let holds = found.filter { $0.rule == "maxStatic" }.compactMap(\.shot)
        #expect(holds == ["s00", "s05"])                                  // s03 is tagged result
        #expect(found.allSatisfy { $0.suggest != nil || $0.rule == "duration" })
    }

    @Test func rulesStaySilentWhenSatisfied() throws {
        let tight = try Self.project().applying([.cut(from: 0, to: 2.7), .cut(from: 4, to: 14.4), .cut(from: 15.5, to: 20)], context: EditContext()).project
        // 20 - 2.7 - 10.4 - 4.5 = 2.4 s: the hook is fine, no hold, no flicker; only duration remains
        #expect(Set(rules(tight)) == ["duration", "asl"] || Set(rules(tight)) == ["duration"])
        #expect(!rules(tight).contains("hook") && !rules(tight).contains("maxStatic") && !rules(tight).contains("tinyShot"))
    }

    @Test func durationAndProfiles() throws {
        let long = Project(source: Source(duration: 20), clips: [Clip(sourceStart: 0, sourceEnd: 20, speed: 0.4)])
        #expect(rules(long).contains("duration"))                         // 50 s
        #expect(!rules(long, .tutorial).contains("duration"))
        #expect(rules(Self.project(), .tutorial).filter { $0 == "maxStatic" }.count == 1)   // only the 8 s hold exceeds 4 s
        #expect(LintProfile(name: "demo") == .demo && LintProfile(name: "nope") == nil)
    }

    @Test func orphanEffectAndEdgeContent() {
        let short = Zoom(start: 5, end: 5.3), fine = Zoom(start: 6, end: 8)
        let found = lint(Self.project(zooms: [short, fine]), storyboard: Self.board())
        #expect(found.filter { $0.rule == "orphanEffect" }.count == 1)
        #expect(found.first { $0.rule == "orphanEffect" }?.suggest == opJSON("remove", ["id": .string(short.id)]))
        let crop = NormRect(x: 0.5, y: 0, w: 0.5, h: 1)
        func edge(_ focus: NormRect) -> Bool {
            let sb = Storyboard(duration: 20, fps: 10, shots: [Shot(id: "s00", from: 0, to: 20, kind: .motion, boundary: .start, focus: focus)],
                                summary: StoryboardSummary(shots: 1, aslSec: 0, staticSec: 0, longestStatic: nil))
            return lint(Self.project(crop: crop), storyboard: sb).contains { $0.rule == "edgeContent" }
        }
        #expect(edge(NormRect(x: 0.4, y: 0.1, w: 0.3, h: 0.5)))      // fits the crop but pokes out of its left edge
        #expect(!edge(NormRect(x: 0.6, y: 0.1, w: 0.3, h: 0.5)))     // inside
        #expect(!edge(NormRect()))                                    // wider than the crop: moving it can't help
    }

    @Test func splitShotPiecesCountAsOneHold() throws {
        let base = Self.project()
        let cutMiddle = try base.applying([.cut(from: 1, to: 2)], context: EditContext()).project   // s00: 3 s -> two abutting 1 s pieces
        let found = lint(cutMiddle, storyboard: Self.board())
        let hold = try #require(found.first { $0.rule == "maxStatic" && $0.shot == "s00" })
        #expect(hold.msg.hasPrefix("2.0s"))
        #expect(!found.contains { $0.rule == "tinyShot" && $0.shot == "s00" })
        #expect(editReport(before: base, after: cutMiddle, storyboard: Self.board()).longestStatic?.sec == 8)
    }

    @Test func suggestionsApplyAndFixTheirFinding() throws {
        let base = Self.project()
        let hold = try #require(lint(base, storyboard: Self.board()).first { $0.rule == "maxStatic" })
        let op = try JSONDecoder().decode(EditOp.self, from: JSONEncoder().encode(try #require(hold.suggest)))
        let fixed = try base.applying([op], context: EditContext()).project
        #expect(fixed.exportDuration < base.exportDuration)
        let hook = try #require(lint(base, storyboard: Self.board()).first { $0.rule == "hook" })
        let after = try base.applying([try JSONDecoder().decode(EditOp.self, from: JSONEncoder().encode(try #require(hook.suggest)))], context: EditContext()).project
        #expect(editReport(before: base, after: after, storyboard: Self.board()).hookSec ?? 9 <= 1.0)
    }

    @Test func hookCountsOpeningMotionAndTinyShotUsesPrintedValue() {
        // Feedback: an opening that animates from frame 0 was reported as "first payoff at 5.9 s".
        let shots = [Shot(id: "s01", from: 0, to: 3, kind: .motion, boundary: .start),
                     Shot(id: "s02", from: 3, to: 3.249, kind: .static, boundary: .cut),
                     Shot(id: "s03", from: 3.249, to: 9, kind: .payoff, boundary: .cut, clicks: [5.9])]
        let sb = Storyboard(duration: 9, fps: 10, shots: shots, summary: StoryboardSummary(shots: 3, aslSec: 3, staticSec: 0, longestStatic: nil))
        let p = Project(source: Source(duration: 9), clips: [Clip(sourceStart: 0, sourceEnd: 9)])
        #expect(editReport(before: p, after: p, storyboard: sb).hookSec == 0)
        #expect(!lint(p, storyboard: sb).contains { $0.rule == "hook" || $0.rule == "tinyShot" })   // 0.249 s prints as 0.25 s
    }

    // Run-2 feedback (R2-2…R2-5): lint measures what a viewer sees, not analyzer granularity.
    @Test func tinyShotOnlyAtCutsDropsSliversAndSuggestsOnlyCutsThatApply() throws {
        let shots = [Shot(id: "s01", from: 0, to: 5, kind: .motion, boundary: .start),
                     Shot(id: "s02", from: 5, to: 5.2, kind: .motion, boundary: .animate),    // sub-shot in continuous footage
                     Shot(id: "s03", from: 5.2, to: 10, kind: .motion, boundary: .animate),
                     Shot(id: "s04", from: 10, to: 10.15, kind: .motion, boundary: .cut),     // a real flash after a cut
                     Shot(id: "s05", from: 10.15, to: 20, kind: .motion, boundary: .animate)]
        let sb = Storyboard(duration: 20, fps: 10, shots: shots, summary: StoryboardSummary(shots: 5, aslSec: 0, staticSec: 0, longestStatic: nil))
        let p = Self.project()
        let tiny = lint(p, storyboard: sb).filter { $0.rule == "tinyShot" }
        #expect(tiny.map(\.shot) == ["s04"])
        let op = try JSONDecoder().decode(EditOp.self, from: JSONEncoder().encode(try #require(tiny.first?.suggest)))
        #expect(try p.applying([op], context: EditContext()).changes.first?.skipped == false)
        #expect(editReport(before: p, after: p, storyboard: sb).aslSec.after == 10)        // one cut → two visual shots
        // A cut leaving 0.03 s of s01 (under one analysis frame) reports no zero-length shot.
        let sliver = try p.applying([.cut(from: 0, to: 4.97)], context: EditContext()).project
        #expect(!lint(sliver, storyboard: sb).contains { $0.shot == "s01" && $0.rule == "tinyShot" })
        // An uncuttable sliver (under the 0.1 s snap minimum) next to an edit cut gets a cut that applies, or none.
        let clipped = try p.applying([.cut(from: 10.21, to: 15)], context: EditContext()).project
        for item in lint(clipped, storyboard: sb) where item.rule == "tinyShot" {
            guard let s = item.suggest else { continue }
            let op = try JSONDecoder().decode(EditOp.self, from: JSONEncoder().encode(s))
            #expect(try clipped.applying([op], context: EditContext()).changes.first?.skipped == false)
        }
    }
}
