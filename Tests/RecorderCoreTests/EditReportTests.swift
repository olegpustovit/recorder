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
        #expect(abs(r.aslSec.before - 20.0 / 6) < 0.01)             // 6 shots
        #expect(abs(r.aslSec.after - 17.0 / 5) < 0.01)              // s00 dropped, not counted as 0
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
        let cropped = lint(Self.project(crop: NormRect(x: 0.5, y: 0, w: 0.5, h: 1)), storyboard: Self.board())
        #expect(cropped.contains { $0.rule == "edgeContent" })
        let inside = Storyboard(duration: 20, fps: 10, shots: [Shot(id: "s00", from: 0, to: 20, kind: .motion, boundary: .start, focus: NormRect(x: 0.6, y: 0.1, w: 0.3, h: 0.5))],
                                summary: StoryboardSummary(shots: 1, aslSec: 0, staticSec: 0, longestStatic: nil))
        #expect(!lint(Self.project(crop: NormRect(x: 0.5, y: 0, w: 0.5, h: 1)), storyboard: inside).contains { $0.rule == "edgeContent" })
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
}
