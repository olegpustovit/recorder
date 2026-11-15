import Testing
@testable import RecorderCore

private func sceneHistoryFixture(canonical: Bool, instantAuto: Bool = false) -> Project {
    let clips = [Clip(sourceStart: 0, sourceEnd: 4), Clip(sourceStart: 4, sourceEnd: 8, speed: 2),
                 Clip(sourceStart: 8, sourceEnd: 12, speed: 0.5)]
    var project = Project(source: Source(pixelWidth: 640, pixelHeight: 360, duration: 12,
                                        windowSizes: [PixelSize(w: 640, h: 360), PixelSize(w: 360, h: 640)]),
                          clips: clips, cameraClips: [], audioTracks: [], audioClips: [])
    project.zooms = [Zoom(start: 0.5, end: 2, scale: 1.5, mode: .manual),
                     Zoom(start: 3.75, end: 7, scale: 2.4, mode: instantAuto ? .auto : .manual,
                          center: NormPoint(x: 0.35, y: 0.65), instant: instantAuto)]
    project.masks = [Mask(start: 3.9, end: 8.1, kind: .highlight, opacity: 0.7, transition: 1)]
    project.windowShots = [WindowShot(start: 4.5, end: 6, window: 1)]
    if canonical {
        let map = TimeMap(clips)
        for i in project.zooms.indices {
            project.zooms[i].start = map.outputTime(atSource: project.zooms[i].start)!
            project.zooms[i].end = map.outputTime(atSource: project.zooms[i].end)!
        }
        for i in project.masks.indices {
            project.masks[i].start = map.outputTime(atSource: project.masks[i].start)!
            project.masks[i].end = map.outputTime(atSource: project.masks[i].end)!
        }
        for i in project.windowShots.indices {
            project.windowShots[i].start = map.outputTime(atSource: project.windowShots[i].start)!
            project.windowShots[i].end = map.outputTime(atSource: project.windowShots[i].end)!
        }
        var output = 0.0
        project.clips = clips.map { original in
            var clip = original
            clip.sourceStart = output; output += original.outputDuration; clip.sourceEnd = output
            clip.mediaStart = original.mediaIn; clip.clockSpeed = 1
            return clip
        }
    }
    return project
}

private func historyCamera(_ project: Project) -> CameraPath {
    let events = EventLog(events: [InputEvent(t: 0, k: .move, x: 0.1, y: 0.8),
                                  InputEvent(t: 3, k: .move, x: 0.8, y: 0.2),
                                  InputEvent(t: 4.3, k: .move, x: 0.95, y: 0.7),
                                  InputEvent(t: 5, k: .move, x: 0.2, y: 0.9),
                                  InputEvent(t: 7, k: .move, x: 0.7, y: 0.1)])
    let cursor = CursorPath(events: events, style: project.cursor, hidden: [], duration: project.timelineSourceDuration)
    return CameraPath(zooms: project.zooms, cursor: cursor, spring: .focused,
                      duration: project.timelineSourceDuration, clips: project.clips)
}

@Test(arguments: [false, true]) func sceneEffectsPreserveHistoryAndPhase(canonical: Bool) throws {
    for instantAuto in [false, true] {
        let original = sceneHistoryFixture(canonical: canonical, instantAuto: instantAuto)
        var lifted = original
        #expect(lifted.liftClips([1], toTrack: 0, atOutput: 0, copy: true).count == 1)
        let layer = try #require(lifted.layers.first)
        let effective = lifted.recordingScene(for: layer)
        let oldPath = historyCamera(original), newPath = historyCamera(effective.project)
        let clip = original.clips[1]
        #expect(effective.sourceStart == clip.sourceStart && effective.sourceRate == clip.timeScale)
        #expect(effective.clip == clip)
        for local in [0, 1.0 / 60, 0.1, 0.25, 0.5, 1.5, clip.outputDuration - 1.0 / 60] {
            let expectedTime = clip.sourceStart + local * clip.timeScale
            let time = effective.sourceStart + local * effective.sourceRate
            #expect(newPath.sample(atSource: time) == oldPath.sample(atSource: expectedTime))
            #expect(newPath.sample(atSource: time - effective.sourceRate / 60)
                    == oldPath.sample(atSource: expectedTime - clip.timeScale / 60))
            let mask = try #require(effective.project.masks.first { time >= $0.start && time <= $0.end })
            #expect(mask.strength(at: time) == original.masks[0].strength(at: expectedTime))
            #expect(effective.project.windowIndex(atSource: time) == original.windowIndex(atSource: expectedTime))
        }
    }
}

@Test func sceneEffectsTrimAndLocalEditKeepPrefix() throws {
    let original = sceneHistoryFixture(canonical: true)
    var lifted = original
    let id = try #require(lifted.liftClips([1], toTrack: 0, atOutput: 5, copy: true).first)
    let context = try #require(lifted.layers.first?.scene?.cameraContext)
    lifted.resizeLayer(id, edge: .leading, toOutput: 5.25)
    var layer = try #require(lifted.layers.first)
    #expect(layer.scene?.cameraContext == context)
    let trimmed = lifted.recordingScene(for: layer)
    #expect(trimmed.sourceStart == original.clips[1].sourceStart + 0.25)
    let oldPath = historyCamera(original), trimmedPath = historyCamera(trimmed.project)
    for local in [0, 0.1, 0.5, 1.5] {
        let time = trimmed.sourceStart + local * trimmed.sourceRate
        #expect(trimmedPath.sample(atSource: time) == oldPath.sample(atSource: time))
        let mask = try #require(trimmed.project.masks.first { time >= $0.start && time <= $0.end })
        #expect(mask.strength(at: time) == original.masks[0].strength(at: time))
    }
    try #require(layer.scene?.zooms.count == 1)
    layer.scene?.zooms[0].scale = 3.5
    let edited = lifted.recordingScene(for: layer)
    let editedPath = historyCamera(edited.project)
    let before = original.clips[1].sourceStart - 1.0 / 60
    #expect(editedPath.sample(atSource: before) == oldPath.sample(atSource: before))
    let during = trimmed.sourceStart + 1
    #expect(editedPath.sample(atSource: during).scale > oldPath.sample(atSource: during).scale)
}

@Test func sceneEffectsZoomEdits() throws {
    var p = Project(source: Source(duration: 10), clips: [Clip(sourceStart: 0, sourceEnd: 10)])
    var layer = LayerBlock(kind: .recording, start: 2, end: 6, file: "screen.mov", rect: NormRect(), mediaRate: 2, scene: SceneEffects())
    layer.id = "L"
    p.layers = [layer]
    // Local zoom time is output seconds since layer.start; the layer spans 4.
    let a0 = p.addSceneZoom(layerID: "L", atLocal: 1, length: 2), b0 = p.addSceneZoom(layerID: "L", atLocal: 3.2, length: 0.6)
    let a = try #require(a0), b = try #require(b0)
    #expect(p.addSceneZoom(layerID: "L", atLocal: 1.5) == nil)          // inside a
    #expect(p.layers[0].scene!.zooms.map(\.start) == [1, 3.2])
    p.moveSceneZoom(layerID: "L", b, toStart: 3.9)                         // clamped to the layer end
    #expect(p.layers[0].scene!.zooms[1].end == 4)
    p.resizeSceneZoom(layerID: "L", a, edge: .trailing, to: 100)         // clamped by neighbour
    #expect(p.layers[0].scene!.zooms[0].end == p.layers[0].scene!.zooms[1].start)
    p.removeSceneZoom(layerID: "L", a)
    #expect(p.layers[0].scene!.zooms.map(\.id) == [b.uuidString])
    #expect(p.zooms.isEmpty)                                             // Main untouched
    #expect(p.addSceneZoom(layerID: "nope", atLocal: 0) == nil)
}

/// A carried zoom added at layer-output offset X must render (per `recordingScene`) at output X, for a sped-up lifted layer.
@Test(arguments: [1.0, 1.5]) func sceneZoomRendersWhereAdded(mediaRate: Double) throws {
    var p = sceneHistoryFixture(canonical: false)
    let lifted = p.liftClips([1], toTrack: 0, atOutput: 5, copy: true)
    let id = try #require(lifted.first)
    let found = p.layers.firstIndex { $0.id == id.uuidString }
    var i = try #require(found)
    p.layers[i].mediaRate = (p.layers[i].mediaRate ?? 1) * mediaRate; p.layers[i].end = p.layers[i].start + 1.5
    i = p.layers.firstIndex { $0.id == id.uuidString }!
    p.layers[i].scene?.zooms = []
    let layer = p.layers[i]
    let x = 0.5
    let added = p.addSceneZoom(layerID: layer.id, atLocal: x, length: 0.5)
    let zid = try #require(added)
    let scene = p.recordingScene(for: p.layers[i])
    let zoom = try #require(scene.project.zooms.first { $0.id == zid.uuidString })
    // Playback maps layer output offset o to source origin + o * rate.
    let rendered = (zoom.start - scene.sourceStart) / scene.sourceRate
    #expect(abs(rendered - x) < 1e-9)
    #expect(p.sceneZoomLength(p.layers[i]) <= 1.5 + 1e-9)
}
