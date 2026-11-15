import Testing
@testable import RecorderCore
import Foundation

/// 5-line LCG (deterministic, no Foundation randomness) for reproducible property tests.
/// Shared by `randomOpsKeepInvariants` and `zoomsNeverOverlap`.
private struct LCG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = 6364136223846793005 &* state &+ 1442695040888963407
        return state
    }
}

@Test func splitProducesTwoClipsSameSpeed() {
    var p = Project(source: Source(duration: 10), clips: [Clip(sourceStart: 0, sourceEnd: 10, speed: 2)])
    let ok = p.split(atOutput: 2)
    #expect(ok)
    #expect(p.clips.count == 2)
    #expect(p.clips[0].sourceStart == 0)
    #expect(p.clips[0].sourceEnd == 4)   // 2 output seconds at 2x = 4 source seconds
    #expect(p.clips[0].speed == 2)
    #expect(p.clips[1].sourceStart == 4)
    #expect(p.clips[1].sourceEnd == 10)
    #expect(p.clips[1].speed == 2)
    #expect(p.checkInvariants() == nil)
}

@Test func splitNearEdgeRefused() {
    var p = Project(source: Source(duration: 10), clips: [Clip(sourceStart: 0, sourceEnd: 10, speed: 1)])
    let leadOk = p.split(atOutput: 0.01)     // within 2 frames (1/30 s) of the leading edge at 60fps
    let trailOk = p.split(atOutput: 9.99)    // within 2 frames of the trailing edge
    #expect(!leadOk)
    #expect(!trailOk)
    #expect(p.clips.count == 1)
}

@Test func removeLastClipRefused() {
    var p = Project(source: Source(duration: 10), clips: [Clip(sourceStart: 0, sourceEnd: 10, speed: 1)])
    let ok = p.removeClip(0)
    #expect(!ok)
    #expect(p.clips.count == 1)
}

@Test func trimClampsToNeighbour() {
    var p = Project(source: Source(duration: 10), clips: [
        Clip(sourceStart: 0, sourceEnd: 5, speed: 1),
        Clip(sourceStart: 6, sourceEnd: 10, speed: 1),
    ])
    // Extending clip 1's leading edge past clip 0's trailing edge clamps to it.
    p.trimClip(1, edge: .leading, toSource: 0)
    #expect(p.clips[1].sourceStart == 5)
    // Extending clip 0's trailing edge past clip 1's leading edge clamps to it.
    p.trimClip(0, edge: .trailing, toSource: 100)
    #expect(p.clips[0].sourceEnd == 5)
    // Shrinking below the minimum clip length clamps to it instead.
    p.trimClip(0, edge: .leading, toSource: 4.99)
    #expect(p.clips[0].sourceStart == 4.9)
    #expect(p.checkInvariants() == nil)
}

@Test func splitRemoveRestoreIsIdentity() {
    let original = Project(source: Source(duration: 20), clips: [Clip(sourceStart: 0, sourceEnd: 20, speed: 1)])
    var p = original
    let splitOk = p.split(atOutput: 8)
    #expect(splitOk)
    #expect(p.clips.count == 2)
    let removeOk = p.removeClip(1)
    #expect(removeOk)
    #expect(p.clips.count == 1)
    p.restoreCut(afterClip: 0)
    #expect(p == original)
}

@Test func restoreCutUsesMedia() throws {
    for speed in [1.0, 2.0] {
        var p = Project(source: Source(duration: 12), clips: [Clip(sourceStart: 0, sourceEnd: 12, speed: speed)])
        let splitFirst = p.split(atOutput: 4 / speed)
        let splitSecond = p.split(atOutput: 8 / speed)
        let removed = p.removeClip(1)
        #expect(splitFirst && splitSecond && removed)
        let copied = try #require(p.copySelection(clips: [0], blocks: []))
        let pasted = p.pasteSelection(copied, atOutput: 8 / speed)
        #expect(pasted != nil)
        #expect(p.clips[0].sourceEnd == p.clips[1].sourceStart)
        #expect(p.clips[1].mediaIn == 8)

        p.restoreCut(afterClip: 0)

        #expect(p.checkInvariants() == nil)
        #expect(abs(TimeMap(p.clips).outputDuration - 16 / speed) < 1e-8)
        for media in stride(from: 0.5, to: 12, by: 1) {
            let output = media / speed
            let i = try #require(p.clipIndex(atOutput: output))
            #expect(abs(p.clips[i].mediaTime(atSource: TimeMap(p.clips).sourceTime(atOutput: output)) - media) < 1e-8)
        }
        let copiedIndex = try #require(p.clipIndex(atOutput: 13 / speed))
        #expect(abs(p.clips[copiedIndex].mediaTime(atSource: TimeMap(p.clips).sourceTime(atOutput: 13 / speed)) - 1) < 1e-8)
    }

    var trimmed = Clip(sourceStart: 0, sourceEnd: 3, speed: 2)
    trimmed.mediaStart = 2
    trimmed.clockSpeed = 1
    var p = Project(source: Source(duration: 10), clips: [trimmed])
    p.restoreCut(afterClip: -1)
    p.restoreCut(afterClip: p.clips.count - 1)
    #expect(p.checkInvariants() == nil)
    #expect(p.clips.first?.mediaIn == 0)
    let last = try #require(p.clips.last)
    #expect(abs(last.mediaTime(atSource: last.sourceEnd) - 10) < 1e-8)
    #expect(abs(TimeMap(p.clips).outputDuration - 5) < 1e-8)
}

@Test func noRestoreAcrossReorder() {
    for gap in [0.0, 2.0] {
        for speed in [1.0, 2.0] {
            var left = Clip(sourceStart: 0, sourceEnd: 4)
            left.mediaStart = 6
            left.clockSpeed = 1
            var right = Clip(sourceStart: 4 + gap, sourceEnd: 4 + gap + 4 / speed, speed: speed)
            right.mediaStart = 0
            right.clockSpeed = 1
            var p = Project(source: Source(duration: 10), clips: [left, right])
            let before = p
            p.restoreCut(afterClip: 0)
            #expect(p == before)
            #expect(p.checkInvariants() == nil)
        }
    }
}

@Test func randomOpsKeepInvariants() {
    var rng = LCG(state: 1)
    var p = Project(source: Source(duration: 60), clips: [Clip(sourceStart: 0, sourceEnd: 60, speed: 1)])

    p.linkVideoEdits = true
    for _ in 0..<1000 {
        switch Int.random(in: 0..<6, using: &rng) {
        case 0:
            p.split(atOutput: Double.random(in: 0...60, using: &rng))
        case 1:
            p.removeClip(Int.random(in: 0..<p.clips.count, using: &rng))
        case 2:
            let edge: Edge = Bool.random(using: &rng) ? .leading : .trailing
            p.trimClip(Int.random(in: 0..<p.clips.count, using: &rng), edge: edge,
                       toSource: Double.random(in: 0...60, using: &rng))
        case 3:
            p.restoreCut(afterClip: Int.random(in: -1..<p.clips.count, using: &rng))
        case 4:
            p.restoreAllCuts()
        default:
            p.setSpeed(Int.random(in: 0..<p.clips.count, using: &rng), Double.random(in: 0...20, using: &rng))
        }
        #expect(p.checkInvariants() == nil)
    }
}

@Test func zoomsNeverOverlap() {
    var rng = LCG(state: 2)
    var p = Project(source: Source(duration: 60), clips: [Clip(sourceStart: 0, sourceEnd: 60, speed: 1)])
    // Seed a handful of non-overlapping zooms spread across the source.
    for start in stride(from: 0.0, to: 60, by: 10) {
        #expect(p.addZoom(atSource: start + 1, length: 3, mode: .manual) != nil)
    }
    #expect(p.zooms.count == 6)

    for _ in 0..<1000 {
        guard let target = p.zooms.randomElement(using: &rng), let id = UUID(uuidString: target.id) else { continue }
        if Bool.random(using: &rng) {
            p.moveZoom(id, toStart: Double.random(in: -10...70, using: &rng))
        } else {
            let edge: Edge = Bool.random(using: &rng) ? .leading : .trailing
            p.resizeZoom(id, edge: edge, to: Double.random(in: -10...70, using: &rng))
        }
        #expect(p.checkInvariants() == nil)
    }
}

@Test func addZoomFitsGap() {
    var p = Project(source: Source(duration: 10), clips: [Clip(sourceStart: 0, sourceEnd: 10, speed: 1)])

    // Empty lane: the whole [0, duration] is free; the block starts at s.
    let id1 = p.addZoom(atSource: 5, length: 3, mode: .manual)
    #expect(id1 != nil)
    #expect(p.zooms.count == 1)
    #expect(p.zooms[0].start == 5)
    #expect(p.zooms[0].end == 8)

    // Only [0, 5) is free now; a request longer than the gap clamps to it.
    let id2 = p.addZoom(atSource: 1, length: 10, mode: .manual)
    #expect(id2 != nil)
    let z2 = p.zooms.first { $0.id == id2!.uuidString }
    #expect(z2?.start == 0)
    #expect(z2?.end == 5)
    #expect(p.checkInvariants() == nil)

    // A gap under the minimum block length (0.5 s) refuses the add.
    p.zooms = [Zoom(id: UUID().uuidString, start: 0, end: 9.8)]
    let id3 = p.addZoom(atSource: 9.9, length: 1, mode: .manual)
    #expect(id3 == nil)
    #expect(p.zooms.count == 1)

    // Clicking inside an existing block (not a gap) also refuses.
    let id4 = p.addZoom(atSource: 5, length: 1, mode: .manual)
    #expect(id4 == nil)
    #expect(p.zooms.count == 1)
}

@Test func speedUpTypingKeepsInvariants() {
    // One 20 s clip; a typing range in the middle (5...9) gets split out and doubled, a range that
    // already sits exactly on a clip boundary (12...16, after a manual pre-cut) doesn't need a split
    // on that edge, and a range that only partly survives an earlier cut (18...25, but the source
    // only runs to 20) still speeds up whatever clip remains inside it.
    var p = Project(source: Source(duration: 20), clips: [
        Clip(sourceStart: 0, sourceEnd: 12, speed: 1),
        Clip(sourceStart: 12, sourceEnd: 20, speed: 1),
    ])
    p.linkVideoEdits = true
    p.speedUpTyping([TimeRange(start: 5, end: 9), TimeRange(start: 12, end: 16), TimeRange(start: 18, end: 25)])

    #expect(p.checkInvariants() == nil)
    // The 5...9 range became its own clip at 2×.
    guard let sped1 = p.clips.first(where: { $0.sourceStart == 5 && $0.sourceEnd == 9 }) else {
        #expect(Bool(false), "expected a 5...9 clip, got \(p.clips)")
        return
    }
    #expect(sped1.speed == 2)
    // The clips right before/after it are untouched (still 1×).
    #expect(p.clips.first(where: { $0.sourceStart == 0 && $0.sourceEnd == 5 })?.speed == 1)
    #expect(p.clips.first(where: { $0.sourceStart == 9 && $0.sourceEnd == 12 })?.speed == 1)
    // 12...16 already started exactly on a clip boundary; only the trailing edge needed a split.
    guard let sped2 = p.clips.first(where: { $0.sourceStart == 12 && $0.sourceEnd == 16 }) else {
        #expect(Bool(false), "expected a 12...16 clip, got \(p.clips)")
        return
    }
    #expect(sped2.speed == 2)
    // 18...25 is clamped by the source's own 20 s duration; the remaining 18...20 clip still speeds up.
    guard let sped3 = p.clips.first(where: { $0.sourceStart == 18 && $0.sourceEnd == 20 }) else {
        #expect(Bool(false), "expected an 18...20 clip, got \(p.clips)")
        return
    }
    #expect(sped3.speed == 2)
}

@Test func snapPicksNearest() {
    let candidates = [1.0, 5.0, 5.4, 9.0]

    let hit = snap(5.3, candidates: candidates, threshold: 0.5)
    #expect(hit.snapped)
    #expect(hit.value == 5.4)   // nearer than 5.0 (0.1 vs 0.3 away)

    let tooFar = snap(5.3, candidates: candidates, threshold: 0.05)
    #expect(!tooFar.snapped)
    #expect(tooFar.value == 5.3)

    let exact = snap(9.0, candidates: candidates, threshold: 0.5)
    #expect(exact.snapped)
    #expect(exact.value == 9.0)
}

@Test func splitAtPausesOnlySplits() {
    var p = Project(source: Source(duration: 20), clips: [Clip(sourceStart: 0, sourceEnd: 20, speed: 1)])
    p.splitAtPauses([TimeRange(start: 5, end: 8), TimeRange(start: 12, end: 15)])
    #expect(p.checkInvariants() == nil)
    #expect(p.clips.map { $0.sourceStart } == [0, 5, 8, 12, 15])
    #expect(p.clips.map { $0.sourceEnd } == [5, 8, 12, 15, 20])
    #expect(p.clips.allSatisfy { $0.speed == 1 })
}

@Test func pausesSliceAndEraseMicOnly() {
    var p = Project(source: Source(duration: 20, hasMic: true), clips: [Clip(sourceStart: 0, sourceEnd: 20, speed: 1)])
    let silent = [TimeRange(start: 5, end: 8), TimeRange(start: 12, end: 15)]
    p.splitAudioAtPauses(file: "mic.m4a", silent: silent)
    #expect(p.checkInvariants() == nil)
    #expect(p.clips.count == 1) // video untouched
    #expect(p.audioClips.map(\.start) == [0, 5, 8, 12, 15])
    #expect(p.audioClips[0].fadeOut == 0.06 && p.audioClips[2].fadeIn == 0.06 && p.audioClips[1].fadeIn == nil)
    p.erasePauses(file: "mic.m4a", silent: silent, inOutput: TimeRange(start: 13, end: 13.5))
    #expect(p.checkInvariants() == nil)
    #expect(p.audioClips.map(\.start) == [0, 5, 8, 15]) // only the touched pause, gap left behind
    #expect(TimeMap(p.clips).outputDuration == 20)
    var fresh = Project(source: Source(duration: 20, hasMic: true), clips: [Clip(sourceStart: 0, sourceEnd: 20, speed: 1)])
    fresh.erasePauses(file: "mic.m4a", silent: silent, inOutput: TimeRange(start: 0, end: 20))
    #expect(fresh.audioClips.map(\.start) == [0, 8, 15])
}

@Test func eraserTailFade() {
    var p = Project(source: Source(duration: 20, hasMic: true), clips: [Clip(sourceStart: 0, sourceEnd: 20, speed: 1)])
    let silent = [TimeRange(start: 5, end: 8), TimeRange(start: 12, end: 12.2)]
    p.erasePauses(file: "mic.m4a", silent: silent, inOutput: TimeRange(start: 0, end: 20), tail: 0.12, fade: 0.08)
    #expect(p.checkInvariants() == nil)
    #expect(p.clips == [Clip(sourceStart: 0, sourceEnd: 20, speed: 1)]) // video untouched
    #expect(p.audioClips.count == 2) // the 0.2 s pause is shorter than 2×tail + 0.05: left alone
    #expect(abs(p.audioClips[0].end - 5.12) < 1e-9 && abs(p.audioClips[1].start - 7.88) < 1e-9) // tail kept
    #expect(p.audioClips[0].fadeOut == 0.08 && p.audioClips[1].fadeIn == 0.08)
    #expect(p.audioClips[0].fadeIn == nil && p.audioClips[1].fadeOut == nil)
}

@Test func pausesSliceDuplicateMedia() throws {
    for speed in [1.0, 2.0] {
        var p = Project(source: Source(duration: 10, hasMic: true), clips: [Clip(sourceStart: 0, sourceEnd: 10, speed: speed)])
        let copied = try #require(p.copySelection(clips: [0], blocks: []))
        #expect(p.pasteSelection(copied, atOutput: 10 / speed) != nil)
        #expect(p.audioClips.count == 2)
        let video = p.clips
        p.splitAudioAtPauses(file: "mic.m4a", silent: [TimeRange(start: 2, end: 4)], fade: 0.08)
        #expect(p.audioClips.count == 6)
        #expect(p.clips == video && p.checkInvariants() == nil)
        for start in [0.0, 10 / speed] {
            let pieces = p.audioClips.filter { $0.start >= start && $0.start < start + 10 / speed }
            #expect(pieces.map(\.mediaStart) == [0, 2, 4])
            #expect(pieces.map { $0.mediaRate ?? 1 } == [speed, speed, speed])
            let first = try #require(pieces.first)
            let last = try #require(pieces.last)
            #expect(abs(first.end - start - 2 / speed) < 1e-8)
            #expect(abs(last.start - start - 4 / speed) < 1e-8)
            #expect(first.fadeOut == 0.08 && last.fadeIn == 0.08)
        }
    }
}

@Test func eraserOnlyTouchedDuplicate() throws {
    for speed in [1.0, 2.0] {
        var p = Project(source: Source(duration: 10, hasMic: true), clips: [Clip(sourceStart: 0, sourceEnd: 10, speed: speed)])
        let copied = try #require(p.copySelection(clips: [0], blocks: []))
        #expect(p.pasteSelection(copied, atOutput: 10 / speed) != nil)
        #expect(p.audioClips.count == 2)
        let untouched = try #require(p.audioClips.first)
        let video = p.clips
        p.erasePauses(file: "mic.m4a", silent: [TimeRange(start: 2, end: 4)],
                      inOutput: TimeRange(start: 12.5 / speed, end: 13 / speed), tail: 0.2, fade: 0.08)
        #expect(p.audioClips.count == 3)
        #expect(p.audioClips.first == untouched)
        #expect(p.clips == video && p.checkInvariants() == nil)
        let speech = p.audioClips.filter { $0.start >= 10 / speed }
        let first = try #require(speech.first)
        let last = try #require(speech.last)
        #expect(abs(first.end - 12.2 / speed) < 1e-8)
        #expect(abs(last.start - 13.8 / speed) < 1e-8)
        #expect(abs(last.mediaStart - 3.8) < 1e-8)
        #expect(first.fadeOut == 0.08 && last.fadeIn == 0.08)
        #expect(first.mediaRate == speed && last.mediaRate == speed)
        #expect(abs(TimeMap(p.clips).outputDuration - 20 / speed) < 1e-8)
    }

    var p = Project(source: Source(duration: 20, hasMic: true), clips: [Clip(sourceStart: 0, sourceEnd: 5)])
    p.audioClips = [AudioClip(start: 0, end: 20, file: "mic.m4a")]
    p.erasePauses(file: "mic.m4a", silent: [TimeRange(start: 10, end: 12)],
                  inOutput: TimeRange(start: 10.5, end: 11))
    #expect(p.audioClips.map(\.start) == [0, 12])
    #expect(p.audioClips.map(\.end) == [10, 20])
    #expect(p.exportDuration == 20 && p.checkInvariants() == nil)
}

@Test func joinClipsUndoesSplits() {
    var p = Project(source: Source(duration: 20, hasMic: true), clips: [Clip(sourceStart: 0, sourceEnd: 20, speed: 1)])
    let original = p
    _ = p.split(atOutput: 5); _ = p.split(atOutput: 10)
    p.clips[0].fadeIn = 0.5; p.clips[2].fadeOut = 0.4
    let joined = p.joinClips([0, 1, 2])
    #expect(joined == [0])
    #expect(p.clips.count == 1 && p.clips[0].sourceEnd == 20 && p.clips[0].fadeIn == 0.5 && p.clips[0].fadeOut == 0.4)
    p.clips[0].fadeIn = nil; p.clips[0].fadeOut = nil
    #expect(p.clips == original.clips && p.checkInvariants() == nil)
    _ = p.split(atOutput: 5); _ = p.split(atOutput: 10)
    p.clips.remove(at: 1) // 0–5 then 10–20: not continuous media
    let cut = p
    let refused = p.joinClips([0, 1])
    #expect(refused.isEmpty && p == cut)

    var a = Project(source: Source(duration: 20, hasMic: true), clips: [Clip(sourceStart: 0, sourceEnd: 20, speed: 1)])
    let mic = UUID(uuidString: a.audioClips[0].id)!
    let split = a.splitAudio(mic, atOutput: 8, propagate: false)
    #expect(split)
    let ids = Set(a.audioClips.map { UUID(uuidString: $0.id)! })
    let audioJoined = a.joinAudio(ids)
    #expect(audioJoined == [mic])
    #expect(a.audioClips.count == 1 && a.audioClips[0].end == 20 && a.checkInvariants() == nil)
    a.splitAudioAtPauses(file: "mic.m4a", silent: [TimeRange(start: 5, end: 8)])
    a.audioClips.remove(at: 1) // erased pause leaves a gap: not joinable
    let erased = a
    let audioRefused = a.joinAudio(Set(a.audioClips.map { UUID(uuidString: $0.id)! }))
    #expect(audioRefused.isEmpty && a == erased)
}

@Test func moveAudioToNewTrack() {
    var p = Project(source: Source(duration: 20, hasMic: true), clips: [Clip(sourceStart: 0, sourceEnd: 20, speed: 1)])
    p.audioTracks[0].volume = 0.5
    p.splitAudioAtPauses(file: "mic.m4a", silent: [TimeRange(start: 5, end: 8)])
    let ids = p.audioClips.prefix(2).map { UUID(uuidString: $0.id)! }
    let timing = p.audioClips.map { [$0.start, $0.end] }
    let moved = p.moveAudioToNewTrack(ids)
    #expect(moved)
    #expect(p.checkInvariants() == nil)
    #expect(p.audioTracks.last?.name == "Audio 1" && p.audioTracks.last?.volume == 0.5)
    #expect(p.audioClips.map(\.track) == [1, 1, 0] && p.audioClips.map { [$0.start, $0.end] } == timing)
    let added = p.addAudioTrack(), missing = p.moveAudioToNewTrack([UUID()])
    #expect(added == 2 && p.audioTracks[2].name == "Audio 2" && !missing)
    p.audioClips.append(AudioClip(start: 1, end: 3, file: "mic.m4a", track: 0)) // overlaps Audio 1's first clip
    let overlapped = p
    let refused = !p.moveAudioToNewTrack([UUID(uuidString: p.audioClips[0].id)!, UUID(uuidString: p.audioClips.last!.id)!])
    #expect(refused && p == overlapped)
}

@Test func highlightZoomCopiesTimingAndTarget() {
    var p = Project(source: Source(duration: 20), clips: [Clip(sourceStart: 0, sourceEnd: 20, speed: 1)])
    let id = p.addZoom(atSource: 4, length: 3, mode: .manual)!
    let zi = p.zooms.firstIndex { $0.id == id.uuidString }!
    p.zooms[zi].scale = 2; p.zooms[zi].center = NormPoint(x: 0.9, y: 0.5)
    let mid = p.highlightZoom(id)
    #expect(mid != nil && p.checkInvariants() == nil)
    let m = p.masks[0]
    #expect(m.kind == .highlight && m.start == p.zooms[zi].start && m.end == p.zooms[zi].end)
    #expect(abs(m.rect.w - 0.5) < 1e-9 && abs(m.rect.x - 0.5) < 1e-9 && abs(m.rect.y - 0.25) < 1e-9) // clamped inside the frame
    #expect(p.highlightZoom(id) == nil) // a mask already covers it
}

private func reorderFixture(speeds: [Double] = [1, 1, 1, 1]) -> Project {
    let clips = speeds.enumerated().map { i, speed in
        var clip = Clip(sourceStart: Double(i) * 4, sourceEnd: Double(i + 1) * 4, speed: speed)
        clip.mediaStart = Double(i) * 8
        clip.clockSpeed = 1
        return clip
    }
    var project = Project(source: Source(duration: 32), clips: clips)
    project.linkVideoEdits = true
    return project
}

@Test func reorderRoundTrip() {
    var p = reorderFixture()
    p.zooms = [Zoom(start: 5, end: 7)]
    p.clips[1].fadeIn = 0.2; p.clips[1].fadeOut = 0.3
    p.clips[1].hideCursor = true; p.clips[1].color = .blue
    let original = p
    #expect(p.reorderClips([1, 2], to: 4) == [2, 3])
    #expect(p.clips.map(\.mediaIn) == [0, 24, 8, 16])
    #expect(p.reorderClips([2, 3], to: 1) == [1, 2])
    #expect(p == original)
    for caret in [1, 2, 3, -1, 5] {
        #expect(p.reorderClips([1, 2], to: caret) == [1, 2])
        #expect(p == original)
    }
    #expect(p.reorderClips([], to: 2).isEmpty)
    #expect(p.reorderClips([-1, 8], to: 2).isEmpty)
    #expect(p == original)
    #expect(p.reorderClips([0, 2], to: 4) == [2, 3])
    #expect(p.clips.map(\.mediaIn) == [8, 24, 0, 16])
    #expect(p.checkInvariants() == nil)
}

@Test func reorderCarriesZoom() throws {
    var p = reorderFixture()
    p.zooms = [Zoom(start: 5, end: 7, scale: 3)]
    let layer = LayerBlock(kind: .video, start: 5.5, end: 6.5, file: "media/clip.mov", mediaStart: 1, rect: NormRect())
    p.layers = [layer]
    p.audioTracks = [AudioTrack(name: "Audio 1"), AudioTrack(name: "Audio 2")]
    p.audioClips = [AudioClip(start: 5.25, end: 6.25, mediaStart: 2, mediaRate: 1.5, file: "media/music.m4a"),
                    AudioClip(start: 5.5, end: 6.5, mediaStart: 1, file: layer.file, track: 1, link: .layer, layer: layer.id)]
    let original = p
    #expect(p.reorderClips([1], to: 4) == [3])
    #expect(p.zooms[0].start == 13 && p.zooms[0].end == 15 && p.zooms[0].scale == 3)
    #expect(p.layers[0].start == 13.5 && p.layers[0].end == 14.5 && p.layers[0].mediaStart == 1)
    #expect(p.audioClips.map(\.start) == [13.25, 13.5])
    #expect(p.audioClips.map(\.mediaStart) == [2, 1])
    #expect(p.checkInvariants() == nil)
    var independent = original
    #expect(independent.reorderClips([1], to: 4, propagate: false) == [3])
    #expect(independent.zooms == original.zooms && independent.layers == original.layers && independent.audioClips == original.audioClips)
    var unlinked = original
    unlinked.linkVideoEdits = false
    #expect(unlinked.reorderClips([1], to: 4) == [3])
    #expect(unlinked.zooms == original.zooms && unlinked.layers == original.layers && unlinked.audioClips == original.audioClips)
    let moved = try #require(p.zooms.first)
    #expect(moved.id == original.zooms[0].id)
}

@Test func reorderSplitsSpanningZoom() {
    var p = reorderFixture()
    p.zooms = [Zoom(start: 3, end: 5, scale: 3, center: NormPoint(x: 0.3, y: 0.7))]
    let zoom = p.zooms[0]
    #expect(p.reorderClips([0], to: 4) == [3])
    #expect(p.zooms.map(\.start) == [0, 15])
    #expect(p.zooms.map(\.end) == [1, 16])
    #expect(Set(p.zooms.map(\.id)).count == 2)
    #expect(p.zooms.allSatisfy { $0.scale == zoom.scale && $0.center == zoom.center && $0.mode == zoom.mode })
    #expect(p.checkInvariants() == nil)
    var invalidSplit = reorderFixture()
    invalidSplit.audioTracks = [AudioTrack(name: "Microphone")]
    invalidSplit.audioClips = [AudioClip(start: 3.95, end: 5, file: "mic.m4a", link: .screen)]
    let before = invalidSplit
    #expect(invalidSplit.reorderClips([0], to: 4) == [0])
    #expect(invalidSplit == before)
}

@Test func reorderKeepsLinkedAudioMedia() throws {
    var p = reorderFixture(speeds: [1, 2, 0.5, 1])
    p.audioTracks = [AudioTrack(name: "Microphone")]
    p.audioClips = p.clips.map { AudioClip(start: $0.sourceStart, end: $0.sourceEnd, mediaStart: $0.mediaIn,
                                         mediaRate: $0.speed, file: "mic.m4a", link: .screen) }
    let original = p.audioClips
    #expect(p.reorderClips([0, 2], to: 4) == [2, 3])
    for clip in p.clips {
        let audio = try #require(p.audioClips.first { $0.start == clip.sourceStart })
        let segment = try #require(p.audioSegments(audio).first)
        #expect(segment.media.start == clip.mediaIn && segment.media.end == clip.mediaEnd)
        #expect(audio.mediaStart == original.first { $0.id == audio.id }?.mediaStart)
        #expect(audio.mediaRate == clip.speed)
    }
    #expect(p.checkInvariants() == nil)
}

@Test func reorderKeepsPlaybackRates() {
    var p = reorderFixture(speeds: [1, 2, 0.5, 1])
    p.clips[0].fadeIn = 0.4; p.clips[2].fadeOut = 0.3
    p.clips[1].hideCursor = true; p.clips[3].color = .green
    let original = p.clips
    #expect(p.reorderClips([1, 3], to: 0) == [0, 1])
    for clip in p.clips {
        let old = original.first { $0.mediaIn == clip.mediaIn }!
        #expect(clip.mediaDuration == old.mediaDuration && clip.speed == old.speed && clip.clockSpeed == old.clockSpeed)
        #expect(clip.fadeIn == old.fadeIn && clip.fadeOut == old.fadeOut && clip.hideCursor == old.hideCursor && clip.color == old.color)
    }
    var legacy = Project(source: Source(duration: 12), clips: [Clip(sourceStart: 0, sourceEnd: 4), Clip(sourceStart: 4, sourceEnd: 12, speed: 2)])
    legacy.zooms = [Zoom(start: 6, end: 10)]
    #expect(legacy.reorderClips([0], to: 2) == [1])
    #expect(legacy.reorderClips([1], to: 0) == [0])
    #expect(legacy.clips.map(\.mediaIn) == [0, 4])
    #expect(legacy.clips.map(\.mediaDuration) == [4, 8])
    #expect(legacy.clips.map(\.speed) == [1, 2])
    #expect(legacy.zooms.map(\.start) == [5] && legacy.zooms.map(\.end) == [7])
    #expect(legacy.checkInvariants() == nil)
}

@Test func reorderPreservesExportDuration() {
    for withGap in [false, true] {
        var p = reorderFixture(speeds: [1, 2, 0.5, 1])
        if withGap { p.clips[1].isGap = true }
        let duration = p.exportDuration
        let output = TimeMap(p.clips).outputDuration
        #expect(p.reorderClips([0], to: 4) == [3])
        #expect(p.exportDuration == duration && TimeMap(p.clips).outputDuration == output)
        #expect(p.clips.filter(\.isEmpty).count == (withGap ? 1 : 0))
        #expect(p.checkInvariants() == nil)
    }
}

@Test func reorderInvariants() {
    var rng = LCG(state: 702)
    var p = reorderFixture(speeds: [1, 2, 0.5, 1])
    p.zooms = p.clips.map { Zoom(start: $0.sourceStart + 1, end: $0.sourceStart + 2) }
    p.audioTracks = [AudioTrack(name: "Microphone")]
    p.audioClips = p.clips.map { AudioClip(start: $0.sourceStart, end: $0.sourceEnd, mediaStart: $0.mediaIn,
                                         mediaRate: $0.speed, file: "mic.m4a", link: .screen) }
    let media = p.clips.map(\.mediaIn).sorted()
    for _ in 0..<1000 {
        var selected = Set(p.clips.indices.filter { _ in Bool.random(using: &rng) })
        if selected.isEmpty { selected.insert(Int.random(in: p.clips.indices, using: &rng)) }
        let caret = Int.random(in: 0...p.clips.count, using: &rng)
        let duration = p.exportDuration
        let moving = p.clips.indices.filter { selected.contains($0) }
        var expected = p.clips.indices.filter { !selected.contains($0) }
        expected.insert(contentsOf: moving, at: caret - selected.filter { $0 < caret }.count)
        let expectedMedia = expected.map { p.clips[$0].mediaIn }
        let moved = p.reorderClips(selected, to: caret)
        #expect(moved.count == selected.count)
        #expect(p.clips.map(\.mediaIn) == expectedMedia)
        #expect(p.clips.map(\.mediaIn).sorted() == media)
        #expect(p.exportDuration == duration)
        #expect(p.checkInvariants() == nil)
        for clip in p.clips {
            #expect(p.zooms.contains { $0.start == clip.sourceStart + 1 && $0.end == clip.sourceStart + 2 })
            #expect(p.audioClips.contains { $0.start == clip.sourceStart && $0.mediaStart == clip.mediaIn && $0.mediaRate == clip.speed })
        }
    }
}
