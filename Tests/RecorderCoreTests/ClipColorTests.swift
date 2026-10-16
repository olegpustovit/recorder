import Testing
@testable import RecorderCore
import Foundation

/// T-656: colour tags round-trip, are optional in JSON and survive split/duplicate.
@Test func clipColorRoundTripAndInheritance() throws {
    var p = Project(source: Source(duration: 20), clips: [Clip(sourceStart: 0, sourceEnd: 20)])
    p.zooms = [Zoom(start: 2, end: 8)]
    p.audioTracks = [AudioTrack(name: "Mic")]
    p.audioClips = [AudioClip(start: 0, end: 20, file: "mic.m4a")]
    let zoomID = UUID(uuidString: p.zooms[0].id)!, audioID = UUID(uuidString: p.audioClips[0].id)!
    p.setColor(.blue, blocks: [zoomID, audioID], clips: [0])
    #expect(p.zooms[0].color == .blue && p.audioClips[0].color == .blue && p.clips[0].color == .blue)
    #expect(p.color(ofBlock: zoomID) == .blue)

    let decoded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(p))
    #expect(decoded == p)

    // Older projects have no key at all.
    let plain = try JSONDecoder().decode(Zoom.self, from: Data(#"{"id":"x","start":0,"end":1}"#.utf8))
    #expect(plain.color == nil)
    let clip = try JSONDecoder().decode(Clip.self, from: Data(#"{"sourceStart":0,"sourceEnd":1,"speed":1}"#.utf8))
    #expect(clip.color == nil)

    let split = p.split(atOutput: 10)
    #expect(split)
    #expect(p.clips.count == 2 && p.clips.allSatisfy { $0.color == .blue })
    let splitZoom = p.splitBlock(zoomID, atSource: 5)
    #expect(splitZoom)
    #expect(p.zooms.count == 2 && p.zooms.allSatisfy { $0.color == .blue })
    let duplicated = p.duplicateBlock(UUID(uuidString: p.zooms[1].id)!)
    let copy = try #require(duplicated)
    #expect(p.color(ofBlock: copy) == .blue)

    p.setColor(nil, blocks: [zoomID])
    #expect(p.color(ofBlock: zoomID) == nil)
    #expect(p.checkInvariants() == nil)
}
