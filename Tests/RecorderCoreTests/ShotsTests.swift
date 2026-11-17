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

    @Test func mediaTimesBecomeSourceTimesThroughMediaStart() {
        // Golden Island layout: source 0–4 plays media 10–14, source 4–8 plays media 0–4 (reordered footage).
        let board = Storyboard(duration: 14, fps: 10, shots: [
            Shot(id: "s01", from: 0, to: 4, kind: .static, boundary: .start),
            Shot(id: "s02", from: 4, to: 10, kind: .motion, boundary: .cut),
            Shot(id: "s03", from: 10, to: 14, kind: .payoff, boundary: .cut, clicks: [11])],
            summary: StoryboardSummary(shots: 3, aslSec: 0, staticSec: 0, longestStatic: nil))
        var a = Clip(sourceStart: 0, sourceEnd: 4), b = Clip(sourceStart: 4, sourceEnd: 8)
        a.mediaStart = 10; b.mediaStart = 0
        let source = board.inSource(clips: [a, b])
        #expect(source.shots.map(\.id) == ["s03", "s01"])              // s02's footage is in no clip
        #expect(source.shots[0].from == 0 && source.shots[0].to == 4 && source.shots[0].clicks == [1])
        #expect(source.shots[1].from == 4 && source.shots[1].to == 8)
        let out = source.mapped(through: TimeMap([a, b]))                  // same table, output time
        #expect(out.shots.map(\.id) == ["s03", "s01"] && out.shots[0].clicks == [1])
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

    /// T-901: a recording layer appended after the clips and a full-canvas image layer are part of the shot table,
    /// and the storyboard's duration is the export duration (feedback run 6: the 6.9 s ending was invisible).
    @Test func layersAreShotsAndDurationIsExport() {
        let media = storyboard(signals: Self.signals(), events: [Self.click])           // s01 0–2, s02 2–4, s03 4–6
        let tail = LayerBlock(id: "rec", kind: .recording, start: 6, end: 8, file: "screen.mov", mediaStart: 1,
                              rect: NormRect(), backdrop: .none, mediaRate: 2)
        let still = LayerBlock(id: "img", kind: .image, start: 1, end: 1.5, file: "a.png", rect: NormRect())
        let pip = LayerBlock(id: "pip", kind: .image, start: 3, end: 5, file: "b.png", rect: NormRect(x: 0.6, y: 0.6, w: 0.3, h: 0.3))
        let project = Project(source: Source(duration: 6), clips: [Clip(sourceStart: 0, sourceEnd: 6)], layers: [tail, still, pip])
        let out = media.output(project: project)
        #expect(out.duration == project.exportDuration && out.duration == 8)
        #expect(out.shots.map(\.id) == ["s01", "L:img", "s01", "s02", "s03", "s01", "s02", "s03"])
        #expect(out.shots.map(\.from) == [0, 1, 1.5, 2, 4, 6, 6.5, 7.5] && out.shots.last?.to == 8)
        #expect(out.shots.map(\.layer) == [nil, "img", nil, nil, nil, "rec", "rec", "rec"])
        #expect(out.shots[6].clicks == [6.5])                                             // media click 2.0 at 2× after 1.0
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

    // Run-2 feedback R2-9: a shot split by a cut repeats its id; `part` says so, a plain split stays one shot.
    @Test func cutShotPiecesArePartNumbered() throws {
        let sb = Storyboard(duration: 10, fps: 10, shots: [Shot(id: "s01", from: 0, to: 10, kind: .motion, boundary: .start)],
                            summary: StoryboardSummary(shots: 1, aslSec: 10, staticSec: 0, longestStatic: nil))
        let cut = try Project(source: Source(duration: 10), clips: [Clip(sourceStart: 0, sourceEnd: 10)]).applying([.cut(from: 4, to: 6)], context: EditContext()).project
        #expect(sb.mapped(through: TimeMap(cut.clips)).shots.map(\.part) == ["1/2", "2/2"])
        let split = [Clip(sourceStart: 0, sourceEnd: 5), Clip(sourceStart: 5, sourceEnd: 10)]
        #expect(sb.mapped(through: TimeMap(split)).shots.map(\.part) == [nil])
    }

    // R3-2: sections without any project metadata (historical recordings): cut-delimited runs of >= 10 s; short ones merge.
    @Test func sectionsFallBackToCutsAndMergeShortOnes() {
        let shots = [Shot(id: "s01", from: 0, to: 12, kind: .motion, boundary: .start),
                     Shot(id: "s02", from: 12, to: 14, kind: .motion, boundary: .cut),     // starts section 2
                     Shot(id: "s03", from: 14, to: 20, kind: .motion, boundary: .cut),     // < 10 s since s02: same section
                     Shot(id: "s04", from: 20, to: 24, kind: .motion, boundary: .scroll),
                     Shot(id: "s05", from: 24, to: 25, kind: .motion, boundary: .cut)]     // only 1 s left: merged back
        let sb = Storyboard(duration: 25, fps: 10, shots: shots, summary: StoryboardSummary(shots: 5, aslSec: 0, staticSec: 0, longestStatic: nil))
        #expect(sb.inSource(clips: [Clip(sourceStart: 0, sourceEnd: 25)]).shots.map(\.section) == [1, 2, 2, 2, 2])
        // A trimmed project (cut pauses) is not rearranged: its clip joins are not sections.
        #expect(sb.inSource(clips: [Clip(sourceStart: 0, sourceEnd: 11), Clip(sourceStart: 13, sourceEnd: 25)]).shots.compactMap(\.section).max() == 2)
        #expect(protects(["section:2"], sb.inSource(clips: [Clip(sourceStart: 0, sourceEnd: 25)]).shots[2]))
    }
}
