import Foundation
import Testing
@testable import RecorderCore

private func recordingFixture(speeds: [Double] = [1, 1, 1], withAudio: Bool = true) -> Project {
    let clips = speeds.enumerated().map { index, speed in
        var clip = Clip(sourceStart: Double(index) * 4, sourceEnd: Double(index + 1) * 4, speed: speed)
        clip.mediaStart = Double(index) * 8
        clip.clockSpeed = 1
        return clip
    }
    let tracks = withAudio ? [AudioTrack(id: "recording-mic", name: "Mic", volume: 0.8, muted: false)] : []
    let audio = withAudio ? clips.map {
        AudioClip(start: $0.sourceStart, end: $0.sourceEnd, mediaStart: $0.mediaIn,
                  mediaRate: $0.speed, file: "mic.m4a", track: 0, link: .screen)
    } : []
    return Project(source: Source(duration: 32, hasMic: withAudio), clips: clips,
                   audioTracks: tracks, audioClips: audio)
}

@Test func liftInsertRoundTrip() throws {
    var project = recordingFixture()
    project.clips[2].hideCursor = true
    project.clips[2].color = .blue
    project.clips[2].fadeIn = 0.2
    project.clips[2].fadeOut = 0.3
    project.zooms = [Zoom(start: 9, end: 11, scale: 2.4, mode: .manual)]
    project.masks = [Mask(start: 9.5, end: 10.5, kind: .highlight, opacity: 0.6, transition: 0.2)]
    project.source.hasCamera = true
    project.cameraClips = [CameraClip(start: 0, end: 12)]
    project.keystrokeClips = [Layout(start: 0, end: 12, kind: .settings, keys: Keys(show: true))]
    project.layouts = [Layout(start: 0, end: 12, kind: .bubble)]
    project.texts = [TextBlock(start: 1, end: 3, text: "Retained independent text")]
    let original = project
    let lifted = project.liftClips([2], toTrack: 0, atOutput: 8, copy: false)
    #expect(lifted.count == 1)
    #expect(project.clips.filter { !$0.isEmpty }.count == 2 && project.checkInvariants() == nil)
    #expect(project.cameraClips == original.cameraClips && project.layouts == original.layouts && project.keystrokeClips == original.keystrokeClips && project.texts == original.texts)
    let inserted = project.insertLayers(lifted, intoVideoAt: 2, copy: false)
    #expect(inserted == [2])
    #expect(project == original)

    var spanning = recordingFixture(withAudio: false)
    spanning.zooms = [Zoom(start: 2, end: 10, scale: 2.4, mode: .auto, instant: true)]
    spanning.masks = [Mask(start: 2, end: 10, kind: .highlight, transition: 1)]
    spanning.windowShots = [WindowShot(start: 0, end: 12, window: 0)]
    let whole = spanning
    let moved = spanning.liftClips([1], toTrack: 0, atOutput: 4, copy: false)
    let returned = spanning.insertLayers(moved, intoVideoAt: 1, copy: false)
    #expect(returned == [1] && spanning == whole)
    var middle = recordingFixture(withAudio: false)
    middle.source.hasCamera = true
    middle.cameraClips = [CameraClip(start: 0, end: 12)]
    middle.keystrokeClips = [Layout(start: 0, end: 12, kind: .settings, keys: Keys(show: true))]
    middle.layouts = [Layout(start: 0, end: 12, kind: .bubble)]
    middle.texts = [TextBlock(start: 1, end: 11, text: "Independent")]
    let originalClips = middle.clips
    let mid = middle.liftClips([1], toTrack: 0, atOutput: 4, copy: false)
    let restoredMiddle = middle.insertLayers(mid, intoVideoAt: 1, copy: false)
    #expect(restoredMiddle == [1] && middle.clips == originalClips && TimeMap(middle.clips).outputDuration == 12)
    for sample in [2.0, 6, 10] {
        let camera = try #require(middle.cameraClips.first { $0.start <= sample && $0.end > sample })
        #expect(abs(camera.mediaStart + (sample - camera.start) * (camera.mediaRate ?? 1) - sample) < 1e-8)
        #expect(middle.keystrokeClips.contains { $0.start <= sample && $0.end > sample })
        #expect(middle.layouts.contains { $0.start <= sample && $0.end > sample })
        #expect(middle.texts.contains { $0.start <= sample && $0.end > sample && $0.text == "Independent" })
    }
    let liftedAgain = spanning.liftClips([1], toTrack: 0, atOutput: 4, copy: false)
    let neighbour = try #require(spanning.zooms.first { $0.start == 2 })
    let didSplit = spanning.splitBlock(try #require(UUID(uuidString: neighbour.id)), atSource: 3)
    #expect(didSplit)
    let preserved = Set(spanning.zooms.map(\.id))
    _ = spanning.insertLayers(liftedAgain, intoVideoAt: 1, copy: false)
    #expect(spanning.zooms.count == 4 && preserved.isSubset(of: Set(spanning.zooms.map(\.id))))
}

@Test func liftCarriesZoomsAndAudio() throws {
    var project = recordingFixture(speeds: [1, 2, 0.5])
    project.clips[1].hideCursor = true
    project.clips[1].fadeIn = 0.15
    project.clips[1].fadeOut = 0.25
    project.clips[1].color = .green
    project.zooms = [Zoom(start: 5, end: 7, scale: 3, mode: .manual)]
    project.masks = [Mask(start: 5.25, end: 6.75, kind: .mask, opacity: 0.7, transition: 0.2)]
    project.audioTracks[0].volume = 1.3
    project.audioTracks[0].muted = true
    project.audioClips[1].gain = 0.7
    project.audioClips[1].fadeIn = 0.2
    project.audioClips[1].fadeOut = 0.3
    project.audioClips[1].color = .blue
    project.audioClips[1].envelope = [AudioGainPoint(time: 8, value: 0.2), AudioGainPoint(time: 12, value: 0.9), AudioGainPoint(time: 16, value: 0.4)]
    let sound = project.audioClips[1]
    let track = project.audioTracks[0]
    let zoom = project.zooms[0], mask = project.masks[0]
    let lifted = project.liftClips([1], toTrack: 0, atOutput: 1, copy: false)
    let id = try #require(lifted.first)
    let layer = try #require(project.layers.first { $0.id == id.uuidString })
    #expect(layer.kind == .recording && layer.file == "screen.mov")
    #expect(layer.mediaStart == 8 && layer.mediaRate == 2)
    #expect(layer.end - layer.start == 4)
    #expect(TimeMap(project.clips).outputTime(atSource: layer.start) == 1)
    #expect(layer.rect == NormRect() && layer.backdrop == .none)
    #expect(layer.fadeIn == 0.15 && layer.fadeOut == 0.25 && layer.color == .green)
    let scene = try #require(layer.scene)
    #expect(scene.hideCursor == true)
    #expect(scene.zooms.count == 1 && scene.zooms[0].id == zoom.id)
    #expect(scene.zooms[0].start == 1 && scene.zooms[0].end == 3 && scene.zooms[0].scale == 3)
    #expect(scene.masks.count == 1 && scene.masks[0].id == mask.id)
    #expect(scene.masks[0].start == 1.25 && scene.masks[0].end == 2.75)
    #expect(!project.zooms.contains { $0.id == zoom.id } && !project.masks.contains { $0.id == mask.id })
    let carried = try #require(project.audioClips.first { $0.layer == layer.id })
    #expect(carried.id == sound.id && carried.file == sound.file && carried.link == .layer)
    #expect(carried.mediaStart == sound.mediaStart && carried.mediaRate == sound.mediaRate)
    #expect(carried.gain == sound.gain && carried.envelope == sound.envelope && carried.color == sound.color)
    #expect(carried.fadeIn == sound.fadeIn && carried.fadeOut == sound.fadeOut)
    #expect(project.audioTracks[carried.track].volume == track.volume && project.audioTracks[carried.track].muted == track.muted)
    #expect(abs(try #require(project.syncOffset(carried))) < 1e-8)
    #expect(project.checkInvariants() == nil)

    var short = Project(source: Source(duration: 1), clips: [Clip(sourceStart: 0, sourceEnd: 0.1, speed: 16)], audioTracks: [], audioClips: [])
    let shortIDs = short.liftClips([0], toTrack: 0, atOutput: 0, copy: true)
    let shortLayer = try #require(short.layers.first)
    #expect(shortIDs.count == 1 && abs((shortLayer.end - shortLayer.start) - 0.1 / 16) < 1e-9)
    #expect(short.checkInvariants() == nil)
    var trimmed = recordingFixture(withAudio: false)
    trimmed.clips = [trimmed.clips[1]]
    trimmed.clips[0].sourceStart = 0; trimmed.clips[0].sourceEnd = 4
    trimmed.zooms = [Zoom(start: 0, end: 4, scale: 2)]
    let trimIDs = trimmed.liftClips([0], toTrack: 0, atOutput: 5, copy: true)
    let trimID = try #require(trimIDs.first)
    let originalContext = try #require(trimmed.layers.first?.scene?.cameraContext)
    trimmed.resizeLayer(trimID, edge: .leading, toOutput: 4)
    #expect(trimmed.layers.first?.mediaStart == 7 && trimmed.layers.first?.scene?.cameraContext == originalContext)
    trimmed.resizeLayer(trimID, edge: .leading, toOutput: 6)
    #expect(trimmed.layers.first?.mediaStart == 9 && trimmed.layers.first?.scene?.zooms.first?.start == -1)
    let inserted = trimmed.insertLayers(trimIDs, intoVideoAt: 0, copy: false)
    #expect(inserted == [0] && trimmed.checkInvariants() == nil)
    #expect(trimmed.zooms.first?.start == 0 && trimmed.zooms.first?.end == 3)
}

@Test func liftCollisionPushesUp() throws {
    var project = recordingFixture(withAudio: false)
    let existing = LayerBlock(kind: .image, start: 0, end: 8, file: "media/occupied.png", rect: NormRect())
    project.layers = [existing]
    let lifted = project.liftClips([1], toTrack: 0, atOutput: 1, copy: true)
    let layer = try #require(project.layers.first { lifted.contains(UUID(uuidString: $0.id)!) })
    #expect(layer.track == 1)
    #expect(project.layers.first { $0.id == existing.id } == existing)
    #expect(project.checkInvariants() == nil)

    var full = recordingFixture(withAudio: false)
    full.layers = (0..<4).map { LayerBlock(kind: .video, start: 0, end: 12, file: "media/track-\($0).mov", track: $0, rect: NormRect()) }
    let baseline = full
    let rejected = full.liftClips([1], toTrack: 0, atOutput: 1, copy: false)
    #expect(rejected.isEmpty && full == baseline)
    let invalidTrack = full.liftClips([1], toTrack: -1, atOutput: 1, copy: true)
    let invalidTime = full.liftClips([1], toTrack: 0, atOutput: .nan, copy: true)
    let invalidSelection = full.liftClips([-1, 9], toTrack: 0, atOutput: 1, copy: true)
    #expect(invalidTrack.isEmpty && invalidTime.isEmpty && invalidSelection.isEmpty && full == baseline)
    let missing = full.insertLayers([UUID()], intoVideoAt: 1, copy: false)
    #expect(missing.isEmpty && full == baseline)
    let unknown = project.insertLayers([UUID(uuidString: existing.id)!, UUID()], intoVideoAt: 0, copy: false)
    #expect(unknown.isEmpty && project.layers.contains { $0.id == existing.id })
}

@Test func liftCopyLeavesSource() throws {
    var project = recordingFixture()
    project.zooms = [Zoom(start: 5, end: 7, scale: 2.5, mode: .manual)]
    project.masks = [Mask(start: 5, end: 7, kind: .highlight, opacity: 0.5)]
    let original = project
    let copied = project.liftClips([1], toTrack: 0, atOutput: 12, copy: true)
    let id = try #require(copied.first)
    let layerIndex = try #require(project.layers.firstIndex { $0.id == id.uuidString })
    #expect(project.clips == original.clips && project.zooms == original.zooms && project.masks == original.masks)
    #expect(original.audioClips.allSatisfy { source in project.audioClips.contains(source) })
    let scene = try #require(project.layers[layerIndex].scene)
    #expect(scene.zooms.count == 1 && scene.zooms[0].id != original.zooms[0].id)
    #expect(scene.masks.count == 1 && scene.masks[0].id != original.masks[0].id)
    let copiedAudio = try #require(project.audioClips.first { $0.layer == id.uuidString })
    #expect(!original.audioClips.contains { $0.id == copiedAudio.id })
    project.layers[layerIndex].scene?.zooms[0].scale = 4
    #expect(project.zooms == original.zooms)
    let originalLayer = project.layers[layerIndex]
    let inserted = project.insertLayers(copied, intoVideoAt: project.clips.count, copy: true)
    #expect(inserted.count == 1)
    #expect(project.layers.first { $0.id == originalLayer.id } == originalLayer)
    #expect(project.checkInvariants() == nil)
}

@Test func v3DecodesUnchanged() throws {
    let legacy = recordingFixture()
    #expect(legacy.version == 3)
    let decoded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(legacy))
    #expect(decoded == legacy)
    let minimal = try JSONDecoder().decode(Project.self, from: Data(#"{"source":{}}"#.utf8))
    #expect(minimal.version == 3 && minimal.layers.isEmpty)
    let emptyScene = try JSONDecoder().decode(SceneEffects.self, from: Data("{}".utf8))
    #expect(emptyScene.zooms.isEmpty && emptyScene.masks.isEmpty && emptyScene.hideCursor == nil)
    let future = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
    defer { try? FileManager.default.removeItem(at: future) }
    try Data(#"{"version":6,"layers":[{"kind":"future-unknown-kind"}]}"#.utf8).write(to: future)
    #expect(throws: ProjectError.newerVersion(6)) { try Project.load(from: future) }
}

@Test func savesV3WithoutRecordingLayers() throws {
    var project = recordingFixture(withAudio: false)
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
    defer { try? FileManager.default.removeItem(at: path) }
    #expect(Project.currentVersion == 5)
    try project.save(to: path)
    #expect(try Project.load(from: path) == project)
    let originalVersion = project.version
    let copied = project.liftClips([1], toTrack: 0, atOutput: 12, copy: true)
    #expect(copied.count == 1 && project.version == originalVersion)
    try project.save(to: path)
    let loaded = try Project.load(from: path)
    var expected = project
    expected.version = 4
    #expect(loaded == expected)
    #expect(project.version == originalVersion)
    project.layers.removeAll()
    try project.save(to: path)
    #expect(try Project.load(from: path).version == 3)
}
