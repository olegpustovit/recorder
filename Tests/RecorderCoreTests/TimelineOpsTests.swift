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
