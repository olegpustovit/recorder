import Foundation
import Testing
@testable import RecorderCore

private func base() -> Project {
    var a = Clip(sourceStart: 0, sourceEnd: 4, speed: 1); a.clockSpeed = 1
    var b = Clip(sourceStart: 4, sourceEnd: 8, speed: 1); b.clockSpeed = 1; b.mediaStart = 4
    return Project(source: Source(duration: 8), clips: [a, b], audioTracks: [], audioClips: [])
}

@Test func clipFileInsertImageAndVideoLayers() throws {
    var project = base()
    let image = LayerBlock(kind: .image, start: 1, end: 4, file: "media/a.png", rect: NormRect())
    let video = LayerBlock(kind: .video, start: 5, end: 7, file: "media/b.mov", mediaStart: 1.5, rect: NormRect())
    project.layers = [image, video]
    let first = project.insertLayers([UUID(uuidString: image.id)!], intoVideoAt: 1, copy: false)
    #expect(first == [1] && project.layers.count == 1 && project.checkInvariants() == nil)
    let second = project.insertLayers([UUID(uuidString: video.id)!], intoVideoAt: 3, copy: false)
    #expect(second == [3] && project.layers.isEmpty && project.checkInvariants() == nil)
    #expect(project.clips.map(\.file) == [nil, "media/a.png", nil, "media/b.mov"])
    let movie = project.clips[3]
    #expect(movie.mediaIn == 1.5 && abs(movie.outputDuration - 2) < 1e-9 && movie.hideCursor == nil)
    #expect(abs(project.clips[1].outputDuration - 3) < 1e-9 && project.zooms.isEmpty)
    #expect(project.liftClips([1], toTrack: 0, atOutput: 0, copy: true).isEmpty)
}

@Test func clipFileSaveVersionAndRoundTrip() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clipfile-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("project.json")
    var project = base()
    try project.save(to: url)
    #expect(try Project.load(from: url).version == Project.currentVersion)
    project.clips[1].file = "media/a.png"
    try project.save(to: url)
    let loaded = try Project.load(from: url)
    #expect(loaded.version == Project.currentVersion && loaded.clips == project.clips)
}

@Test func clipFileV3Decode() throws {
    let json = #"{"version":3,"clips":[{"sourceStart":0,"sourceEnd":2,"speed":1}]}"#
    let project = try JSONDecoder().decode(Project.self, from: Data(json.utf8))
    #expect(project.clips.count == 1 && project.clips[0].file == nil)
}
