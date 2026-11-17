import Testing
@testable import RecorderCore

@Suite struct ShotsTests {
    /// 6 s at 10 fps: still 0–2 s, cut at 2.0, still, slow animation 4–5 s, still.
    static func signals() -> [FrameSignal] {
        (0..<60).map { i in
            if i == 20 { return FrameSignal(diff: 0.3, ssim: 0.3, bbox: NormRect(x: 0.2, y: 0.2, w: 0.4, h: 0.3)) }
            if (40..<50).contains(i) { return FrameSignal(diff: 0.03, ssim: 0.95) }
            return FrameSignal(diff: 0, ssim: 1)
        }
    }
    static let click = InputEvent(t: 2.0, k: .down, x: 0.5, y: 0.4, b: 0)

    @Test func segmentsAndClassifies() {
        let moves = [InputEvent(t: 1.5, k: .move, x: 0.5, y: 0.4), InputEvent(t: 3.5, k: .move, x: 0.5, y: 0.4)]
        let s = storyboard(signals: Self.signals(), events: [Self.click] + moves)
        #expect(s.shots.map(\.id) == ["s01", "s02", "s03"])
        #expect(s.shots.map(\.from) == [0, 2, 4])
        #expect(s.shots.map(\.kind) == [.static, .payoff, .motion])
        #expect(s.shots.map(\.boundary) == [.start, .cut, .animate])
        #expect(s.shots[1].clicks == [2.0])
        #expect(s.shots[1].focus == NormRect(x: 0.2, y: 0.2, w: 0.4, h: 0.3))
        #expect(s.shots[1].cursor == NormPoint(x: 0.5, y: 0.4) && s.shots[0].cursor == NormPoint(x: 0.5, y: 0.4))
        #expect(s.shots[0].staticFrac == 1 && s.shots[0].caption == nil && !s.shots[1].reasons.isEmpty)
        #expect(s.summary == StoryboardSummary(shots: 3, aslSec: 2, staticSec: 2, longestStatic: .init(from: 0, to: 2)))
    }

    @Test func boundaryByInput() {
        let scroll = storyboard(signals: Self.signals(), events: [InputEvent(t: 3.95, k: .scroll)])
        #expect(scroll.shots[2].boundary == .scroll && scroll.shots[2].kind == .motion)
        let type = storyboard(signals: Self.signals(), events: [4.1, 4.4, 4.7].map { InputEvent(t: $0, k: .typing) })
        #expect(type.shots[2].boundary == .type && type.shots[2].kind == .typing)
    }

    @Test func cursorOnlyVsStatic() {
        let still = (0..<30).map { _ in FrameSignal(diff: 0, ssim: 1) }
        let moving = (0..<30).map { InputEvent(t: Double($0) / 10, k: .move, x: Double($0) / 30, y: 0.5) }
        #expect(storyboard(signals: still, events: moving).shots.map(\.kind) == [.cursorOnly])
        #expect(storyboard(signals: still, events: []).shots.map(\.kind) == [.static])
    }

    @Test func thresholdsChangeResult() {
        var t = ShotThresholds()
        t.ssim = 0.9   // the 0.95 animation now counts as stable: no boundary at 4 s
        #expect(storyboard(signals: Self.signals(), events: [], thresholds: t).shots.count == 2)
        t = ShotThresholds(); t.minStable = 2.5   // no run is long enough to be a state
        #expect(storyboard(signals: Self.signals(), events: [], thresholds: t).shots.count == 1)
    }

    @Test func idsStayPutAfterACut() {
        let s = storyboard(signals: Self.signals(), events: [Self.click])
        var clip1 = Clip(sourceStart: 0, sourceEnd: 2), clip2 = Clip(sourceStart: 4, sourceEnd: 6)
        clip1.speed = 1; clip2.speed = 2   // second half plays at 2x
        let out = s.mapped(through: TimeMap([clip1, clip2]))
        #expect(out.shots.map(\.id) == ["s01", "s03"])   // s02 dropped, s03 keeps its id
        #expect(out.shots.map(\.from) == [0, 2] && out.shots.map(\.to) == [2, 3])
        let split = s.mapped(through: TimeMap([Clip(sourceStart: 0, sourceEnd: 3)]))
        #expect(split.shots.map(\.id) == ["s01", "s02"] && split.shots[1].to == 3 && split.summary.shots == 2)
    }

    @Test func splitWithNothingRemovedIsOneShot() {
        let s = storyboard(signals: Self.signals(), events: [Self.click])
        let split = s.mapped(through: TimeMap([Clip(sourceStart: 0, sourceEnd: 3), Clip(sourceStart: 3, sourceEnd: 6)]))
        #expect(split.shots.map(\.id) == ["s01", "s02", "s03"] && split.shots[1].to == 4 && split.summary.shots == 3)
        let gap = s.mapped(through: TimeMap([Clip(sourceStart: 0, sourceEnd: 3), Clip(sourceStart: 3.5, sourceEnd: 6)]))
        #expect(gap.shots.map(\.id) == ["s01", "s02", "s02", "s03"] && gap.summary.shots == 3)   // real cut inside s02: two pieces, one shot
    }

    @Test func typingNeedsDensityAndNoShortcuts() {
        let one = storyboard(signals: Self.signals(), events: [InputEvent(t: 4.1, k: .key, keyCode: 0, mods: 0)])
        #expect(one.shots[2].kind == .motion)
        let cmd = [4.1, 4.4, 4.7].map { InputEvent(t: $0, k: .key, keyCode: 8, mods: 0x100000) }
        #expect(storyboard(signals: Self.signals(), events: cmd).shots[2].kind == .motion)
        let sparse = [0.1, 2.5, 5.9].map { InputEvent(t: $0, k: .typing) }   // 3 events but across other shots
        #expect(storyboard(signals: Self.signals(), events: sparse).shots[0].kind != .typing)
    }

    @Test func openingBurstThenHoldIsMotion() {
        let sig = (0..<30).map { i in FrameSignal(diff: i == 10 ? 0.2 : 0, ssim: i == 10 ? 0.5 : 1) }
        #expect(storyboard(signals: sig, events: []).shots[1].kind == .motion)
    }

    @Test func cutIsDecidedBySpanNotDepth() {
        var sig = Self.signals(); sig[20] = FrameSignal(diff: 0.05, ssim: 0.95)   // shallow but 1 frame
        #expect(storyboard(signals: sig, events: []).shots[1].boundary == .cut)
    }

    @Test func thresholdValidation() {
        #expect(ShotThresholds().invalidReason == nil)
        var t = ShotThresholds(); t.energyScale = 0; #expect(t.invalidReason != nil)
        t = ShotThresholds(); t.ssim = 1.5; #expect(t.invalidReason != nil)
        t = ShotThresholds(); t.cutSsim = -0.1; #expect(t.invalidReason != nil)
        t = ShotThresholds(); t.minStable = 0; #expect(t.invalidReason != nil)
        t = ShotThresholds(); t.motionDiff = .nan; #expect(t.invalidReason != nil)
    }

    @Test func emptyInput() {
        #expect(storyboard(signals: [], events: []).shots.isEmpty)
    }

    @Test func boundaryScoreMatchesOneToOneWithinTolerance() {
        let s = boundaryScore(detected: [1.0, 1.1, 5.0, 9.0], truth: [1.2, 5.25, 7.0])
        #expect(s.precision == 0.5 && abs(s.recall - 2.0 / 3) < 1e-9)   // 1.1 can't reuse 1.2; 9.0 has no match; 7.0 missed
        #expect(boundaryScore(detected: [], truth: [1]).f1 == 0)
    }
}
