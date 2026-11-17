import Testing
@testable import RecorderCore

/// T-932: roll keeps the length and moves the cut; slip keeps position/length and moves the media; both refuse safely.
@Suite struct RollSlipTests {
    func split() -> Project {
        var p = Project(source: Source(duration: 30, hasMic: true), clips: [Clip(sourceStart: 0, sourceEnd: 20)])
        _ = p.split(atOutput: 10)
        return p
    }

    @Test func rollMovesTheCutNotTheLength() throws {
        var p = split()
        let length = TimeMap(p.clips).outputDuration
        let rolled = p.rollEdit(between: 0, toSource: 12)
        #expect(rolled)
        #expect(p.clips[0].sourceEnd == 12 && p.clips[1].sourceStart == 12 && p.clips[1].mediaIn == 12)
        #expect(TimeMap(p.clips).outputDuration == length && p.checkInvariants() == nil)
        let back = p.rollEdit(between: 0, toSource: 8)
        #expect(back && p.clips[0].sourceEnd == 8 && p.clips[1].mediaIn == 8)
        let last = p.rollEdit(between: 1, toSource: 5)
        #expect(!last)                                                                  // no clip after the last
        var mixed = split(); mixed.setSpeed(1, 2)
        let clocks = mixed.rollEdit(between: 0, toSource: 12)
        #expect(!clocks)                                                                // different clocks: refuse
    }

    @Test func slipMovesMediaKeepsPlace() throws {
        var p = split()
        let place = (p.clips[1].sourceStart, p.clips[1].sourceEnd)
        let slipped = p.slipClip(1, byMedia: 3)
        #expect(slipped)
        #expect(p.clips[1].mediaIn == 13 && (p.clips[1].sourceStart, p.clips[1].sourceEnd) == place && p.checkInvariants() == nil)
        let mic = p.audioClips.first { $0.link != nil && $0.start >= 10 - 1e-9 }
        #expect(mic.map { abs($0.mediaStart - 13) < 1e-9 } == true)                  // linked audio slipped with it
        let late = p.slipClip(1, byMedia: 8), early = p.slipClip(0, byMedia: -1)
        #expect(!late && !early)                                                        // past the recording's end / before 0
    }
}

@Test func agentSlipsAClipThroughSet() throws {
    var p = Project(source: Source(duration: 30), clips: [Clip(sourceStart: 0, sourceEnd: 20)])
    _ = p.split(atOutput: 10)
    let r = try p.applying([.set(id: "c1", fields: SetFields(mediaStart: 14))], context: EditContext()).project
    #expect(r.clips[1].mediaIn == 14 && r.clips[1].sourceStart == 10 && TimeMap(r.clips).outputDuration == 20)
    do { _ = try p.applying([.set(id: "c1", fields: SetFields(mediaStart: 25))], context: EditContext()); Issue.record("slip past end") }
    catch { #expect("\(error)".contains("cannot slip")) }
    do { _ = try p.applying([.set(id: "c1", fields: SetFields(from: 2))], context: EditContext()); Issue.record("from on a clip") }
    catch { #expect("\(error)".contains("clip does not take from; valid: mediaStart")) }
}
