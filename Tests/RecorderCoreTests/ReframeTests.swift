import Foundation
import Testing
@testable import RecorderCore

@Suite struct ReframeTests {
    let size = CGSize(width: 1920, height: 1080)
    func board(_ shots: [Shot]) -> Storyboard {
        Storyboard(duration: shots.last?.to ?? 0, fps: 10, shots: shots, summary: StoryboardSummary(shots: shots.count, aslSec: 0, staticSec: 0, longestStatic: nil))
    }
    func shot(_ i: Int, _ from: Double, _ to: Double, _ focus: NormRect, cursor: NormPoint? = nil) -> Shot {
        Shot(id: "s\(i)", from: from, to: to, kind: .motion, boundary: .cut, cursor: cursor, focus: focus)
    }
    func project(_ keys: [CropKey]) -> Project { var p = Project(); p.cropKeys = keys; return p }
    func contains(_ r: NormRect, _ f: NormRect) -> Bool {
        f.x >= r.x - 1e-9 && f.y >= r.y - 1e-9 && f.x + f.w <= r.x + r.w + 1e-9 && f.y + f.h <= r.y + r.h + 1e-9
    }

    @Test func focusStaysInCropOnAtLeast95PercentOfFrames() {
        let shots = [shot(0, 0, 4, NormRect(x: 0.05, y: 0.1, w: 0.2, h: 0.4)),
                     shot(1, 4, 9, NormRect(x: 0.6, y: 0.5, w: 0.3, h: 0.4)),
                     shot(2, 9, 12, NormRect(x: 0.4, y: 0.2, w: 0.1, h: 0.1), cursor: NormPoint(x: 0.5, y: 0.3))]
        for aspect in [Output.Aspect.r9x16, .r1x1, .r4x5] {
            let p = project(reframePlan(storyboard: board(shots), aspect: aspect, mode: .perShot, sourceSize: size))
            var hit = 0, total = 0
            for s in shots { for k in 0..<60 {
                let t = s.from + (s.to - s.from) * Double(k) / 60
                total += 1; if contains(p.cropSample(atSource: t), s.focus) { hit += 1 }
            } }
            #expect(Double(hit) / Double(total) >= 0.95)
        }
    }

    @Test func stationaryWhenFocusFitsPanWhenNot() {
        let fits = reframePlan(storyboard: board([shot(0, 0, 4, NormRect(x: 0.4, y: 0.4, w: 0.1, h: 0.2))]), aspect: .r9x16, mode: .perShot, sourceSize: size)
        #expect(fits.count == 2 && fits[0].rect == fits[1].rect)
        let wide = reframePlan(storyboard: board([shot(0, 0, 4, NormRect(x: 0.15, y: 0.2, w: 0.7, h: 0.3))]), aspect: .r9x16, mode: .perShot, sourceSize: size)
        #expect(wide[0].rect.x < wide[1].rect.x && wide[0].rect.y == wide[1].rect.y)
    }

    @Test func windowHasOutputAspectAndIsClamped() {
        let keys = reframePlan(storyboard: board([shot(0, 0, 2, NormRect(x: 0.95, y: 0.9, w: 0.05, h: 0.1)), shot(1, 2, 4, NormRect(x: 0, y: 0, w: 0.02, h: 0.02))]),
                               aspect: .r1x1, mode: .perShot, sourceSize: size)
        for k in keys {
            #expect(k.rect.x >= 0 && k.rect.y >= 0 && k.rect.x + k.rect.w <= 1 + 1e-9 && k.rect.y + k.rect.h <= 1 + 1e-9)
            #expect(abs(k.rect.w * size.width / (k.rect.h * size.height) - 1) < 1e-9)
        }
    }

    @Test func staticModeIsOneCropCoveringAllFocus() {
        let shots = [shot(0, 0, 2, NormRect(x: 0.3, y: 0.2, w: 0.1, h: 0.1)), shot(1, 2, 4, NormRect(x: 0.45, y: 0.5, w: 0.1, h: 0.2))]
        let keys = reframePlan(storyboard: board(shots), aspect: .r4x5, mode: .static, sourceSize: size)
        #expect(keys.count == 1 && shots.allSatisfy { contains(keys[0].rect, $0.focus) })
    }

    @Test func cutsAtShotBoundariesAndHoldsOutside() {
        let keys = reframePlan(storyboard: board([shot(0, 0, 2, NormRect(x: 0, y: 0, w: 0.1, h: 0.1)), shot(1, 2, 4, NormRect(x: 0.9, y: 0, w: 0.1, h: 0.1))]),
                               aspect: .r9x16, mode: .perShot, sourceSize: size)
        let p = project(keys)
        #expect(p.cropSample(atSource: 1.99).x < 0.01 && p.cropSample(atSource: 2.01).x > 0.5 && p.cropSample(atSource: 99) == keys.last!.rect)
    }

    @Test func oldProjectsDecodeUnchangedAndNoKeysUsesStaticCrop() throws {
        let old = try JSONDecoder().decode(Project.self, from: Data(#"{"version":3,"crop":{"x":0.1,"y":0.1,"w":0.5,"h":0.5}}"#.utf8))
        #expect(old.cropKeys.isEmpty && old.cropSample(atSource: 3) == old.crop)
        let round = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project([CropKey(t: 0, rect: NormRect(x: 0.2, y: 0, w: 0.3, h: 1))])))
        #expect(round.cropKeys.count == 1)
    }

    @Test func reframeOpSetsAspectAndKeys() throws {
        let keys = reframePlan(storyboard: board([shot(0, 0, 4, NormRect())]), aspect: .r9x16, mode: .perShot, sourceSize: size)
        let base = Project(source: Source(pixelWidth: 1920, pixelHeight: 1080, duration: 20), clips: [Clip(sourceStart: 0, sourceEnd: 20)])
        let r = try base.applying([.reframe(aspect: .r9x16, keys: keys)], context: EditContext()).project
        #expect(r.output.aspect == .r9x16 && r.cropKeys == keys)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try r.save(to: url)
        #expect(try Project.load(from: url).version == 6 && (try base.save(to: url)) == ())
        #expect(try Project.load(from: url).version == 3)
        #expect(throws: EditError.self) { try base.applying([.reframe(aspect: .r9x16)], context: EditContext()) }
        #expect(throws: EditError.self) { try base.applying([.reframe(aspect: .r4x3, keys: keys)], context: EditContext()) }
        var bad = keys; bad[0].rect.x = 0.9   // leaves the frame
        #expect(throws: EditError.self) { try base.applying([.reframe(aspect: .r9x16, keys: bad)], context: EditContext()) }
        bad = keys; bad[0].t = 9              // unsorted
        #expect(throws: EditError.self) { try base.applying([.reframe(aspect: .r9x16, keys: bad)], context: EditContext()) }
        #expect(throws: EditError.self) { try base.applying([.reframe(aspect: .r1x1, keys: keys)], context: EditContext()) } // wrong aspect
    }

    @Test func seamSamplesNextShotWindowExactly() {
        let keys = reframePlan(storyboard: board([shot(0, 0, 2, NormRect(x: 0, y: 0, w: 0.1, h: 0.1)), shot(1, 2, 4, NormRect(x: 0.9, y: 0, w: 0.1, h: 0.1))]),
                               aspect: .r9x16, mode: .perShot, sourceSize: size)
        let p = project(keys)
        #expect(p.cropSample(atSource: 2) == keys[2].rect && p.cropSample(atSource: 2.0001) == keys[2].rect && keys[1].t == keys[2].t)
    }

    @Test func fullAxisFocusIsCentredAndStaticWideFocusIsMid() {
        let full = reframePlan(storyboard: board([shot(0, 0, 4, NormRect())]), aspect: .r9x16, mode: .perShot, sourceSize: size)
        #expect(full[0].rect == full[1].rect && abs(full[0].rect.x + full[0].rect.w / 2 - 0.5) < 1e-9)
        let cur = reframePlan(storyboard: board([shot(0, 0, 4, NormRect(), cursor: NormPoint(x: 0.2, y: 0.5))]), aspect: .r9x16, mode: .perShot, sourceSize: size)
        #expect(cur[0].rect == cur[1].rect && abs(cur[0].rect.x + cur[0].rect.w / 2 - 0.5) < 1e-9)   // no target: centre, don't chase the cursor
        let wide = reframePlan(storyboard: board([shot(0, 0, 4, NormRect(x: 0.1, y: 0.2, w: 0.8, h: 0.3))]), aspect: .r9x16, mode: .static, sourceSize: size)
        #expect(abs(wide[0].rect.x + wide[0].rect.w / 2 - 0.5) < 1e-9)
    }

    @Test func cursorMapsIntoSampledCropSpace() {
        let p = cropSpace(x: 0.5, y: 0.5, in: NormRect(x: 0.3, y: 0, w: 0.45, h: 1))
        #expect(abs(p.0 - 0.2 / 0.45) < 1e-9 && abs(p.1 - 0.5) < 1e-9)
    }

    @Test func wideFocusCentresAndNeverLosesToTheCentreCrop() {
        // Feedback: a 0.98×0.96 focus with the cursor at the far right pushed the 1:1 window to the edge.
        let wide = Shot(id: "s01", from: 0, to: 2, kind: .motion, boundary: .start, cursor: NormPoint(x: 0.95, y: 0.5), focus: NormRect(x: 0.01, y: 0.02, w: 0.98, h: 0.96))
        let board = Storyboard(duration: 2, fps: 10, shots: [wide], summary: StoryboardSummary(shots: 1, aslSec: 2, staticSec: 0, longestStatic: nil))
        let keys = reframePlan(storyboard: board, aspect: .r1x1, mode: .perShot, sourceSize: CGSize(width: 1920, height: 1080))
        #expect(keys.allSatisfy { abs($0.rect.x + $0.rect.w / 2 - 0.5) < 1e-6 })
        // A focus on the left half whose aimed window would clip it more than the centre does: fall back to the centre.
        let left = Shot(id: "s02", from: 0, to: 2, kind: .payoff, boundary: .start, cursor: NormPoint(x: 0.0, y: 0.5), focus: NormRect(x: 0.2, y: 0.1, w: 0.6, h: 0.8))
        let k2 = reframePlan(storyboard: Storyboard(duration: 2, fps: 10, shots: [left], summary: board.summary), aspect: .r1x1, mode: .perShot, sourceSize: CGSize(width: 1920, height: 1080))
        let centreX = (1 - k2[0].rect.w) / 2
        func shown(_ r: NormRect) -> Double { max(0, min(0.8, r.x + r.w) - max(0.2, r.x)) }
        #expect(k2.allSatisfy { shown($0.rect) + 1e-9 >= shown(NormRect(x: centreX, y: 0, w: $0.rect.w, h: 1)) })
    }

    // Run-2 feedback R2-1: no twitch for near-identical windows, no lurch inside continuous footage, steps only at cuts.
    @Test func hysteresisAndEaseInsideContinuousFootage() {
        func s(_ i: Int, _ from: Double, _ to: Double, _ x: Double, _ b: ShotBoundary) -> Shot {
            Shot(id: "s\(i)", from: from, to: to, kind: .motion, boundary: b, focus: NormRect(x: x, y: 0.4, w: 0.1, h: 0.2))
        }
        let sb = board([s(0, 0, 2, 0.30, .start), s(1, 2, 4, 0.31, .animate), s(2, 4, 6, 0.6, .animate), s(3, 6, 8, 0.1, .cut)])
        let keys = reframePlan(storyboard: sb, aspect: .r9x16, mode: .perShot, sourceSize: size)
        let p = project(keys)
        #expect(p.cropSample(atSource: 1.9) == p.cropSample(atSource: 2.1))              // 1 % move: held
        let mid = p.cropSample(atSource: 4.15).x, before = p.cropSample(atSource: 3.99).x, after = p.cropSample(atSource: 4.3).x
        #expect(before < mid && mid < after)                                              // eased over 0.3 s, not stepped
        #expect(abs(p.cropSample(atSource: 5.99).x - p.cropSample(atSource: 6).x) > 0.1)   // a cut still jumps
        #expect(cropJumps(keys, storyboard: sb) == 0)
        #expect(cropJumps([CropKey(t: 0, rect: NormRect()), CropKey(t: 4, rect: NormRect()), CropKey(t: 4, rect: NormRect(x: 0.2, y: 0, w: 0.5, h: 1))], storyboard: sb) == 1)
    }
}
