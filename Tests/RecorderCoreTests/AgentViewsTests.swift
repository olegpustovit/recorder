import Foundation
import Testing
@testable import RecorderCore

@Suite struct AgentViewsTests {
    @Test func outputRangesAndFiltering() throws {
        let project = Project(source: Source(duration: 10), clips: [
            Clip(sourceStart: 0, sourceEnd: 2), Clip(sourceStart: 4, sourceEnd: 10, speed: 2)
        ], zooms: [Zoom(id: "zoom", start: 1, end: 8)],
           texts: [TextBlock(id: "text", start: 4, end: 6, text: "abcdefghijklmnopqrstuvwxyz")])
        let view = agentTimeline(project)
        #expect(view.duration == 5)
        #expect(view.clips.map(\.from) == [0, 2])
        #expect(view.clips.map(\.to) == [2, 5])
        #expect(view.clips.map(\.speed) == [1, 2])
        let zooms = view.blocks.filter { $0.id == "zoom" }
        #expect(zooms.map(\.from) == [1, 2])
        #expect(zooms.map(\.to) == [2, 4])
        #expect(zooms.allSatisfy { $0.label == "2.0×" })
        #expect(view.blocks.first { $0.id == "text" }?.label == "abcdefghijklmnopqrstuvwx")
        #expect(agentTimeline(project, from: 2, to: 3).clips.map(\.index) == [1])
        #expect(try JSONDecoder().decode(AgentTimeline.self, from: JSONEncoder().encode(view)) == view)
    }

    @Test func stableWordIDsAndPhrases() throws {
        let project = Project(source: Source(duration: 8), clips: [
            Clip(sourceStart: 0, sourceEnd: 2), Clip(sourceStart: 4, sourceEnd: 8, speed: 2)
        ])
        let words = [Word(text: "Um,", start: 1.234, end: 1.555),
                     Word(text: "removed", start: 3, end: 3.5),
                     Word(text: "settings", start: 5, end: 6)]
        let view = agentTranscript(project, words: words, phrases: true)
        #expect(view.words.map(\.id) == ["w0", "w2"])
        #expect(view.words.map(\.from) == [1.23, 2.5])
        #expect(view.words.map(\.to) == [1.56, 3])
        #expect(view.words.map(\.filler) == [true, false])
        #expect(view.phrases == ["[0:01.2] Um,", "[0:02.5] settings"])
        let filtered = agentTranscript(project, words: words, from: 2, to: 3)
        #expect(filtered.words.map(\.id) == ["w2"])
        #expect(filtered.transcript == view.transcript)
        #expect(filtered.phrases == nil)
        #expect(try JSONDecoder().decode(AgentTranscript.self, from: JSONEncoder().encode(view)) == view)
    }

    @Test func fillersAndStableHash() {
        #expect(isFiller("Um,"))
        #expect(isFiller(" (HMM!) "))
        #expect(!isFiller("umbrella"))
        #expect(!isFiller("um brella"))
        let words = [Word(text: "one", start: 1, end: 2)]
        #expect(transcriptID(words) == transcriptID(words))
        #expect(transcriptID(words).count == 10)
        #expect(transcriptID(words) != transcriptID([Word(text: "one", start: 1, end: 2.001)]))
        #expect(transcriptID(words) != transcriptID([Word(text: "two", start: 1, end: 2)]))
    }

    @Test func copiesImportedMediaAndBoundaries() {
        var copy = Clip(sourceStart: 4, sourceEnd: 6, speed: 2)
        copy.mediaStart = 0; copy.clockSpeed = 1
        var imported = Clip(sourceStart: 6, sourceEnd: 8)
        imported.file = "media/movie.mov"; imported.mediaStart = 0
        var gap = Clip(sourceStart: 8, sourceEnd: 10)
        gap.isGap = true; gap.mediaStart = 0
        let project = Project(source: Source(duration: 10), clips: [
            Clip(sourceStart: 0, sourceEnd: 2), copy, imported, gap
        ])
        let view = agentTranscript(project, words: [Word(text: "hello", start: 1, end: 1.5),
                                                    Word(text: "boundary", start: 2, end: 2.5)])
        #expect(view.words.map(\.id) == ["w0", "w0", "w1"])
        #expect(view.words.map(\.from) == [1, 2.5, 3])
        #expect(view.words.map(\.to) == [1.5, 2.75, 3.25])
        #expect(agentTimeline(project).clips.map(\.index) == [0, 1, 2])
    }

    @Test func connectedTailsAndAllLanes() {
        let project = Project(source: Source(duration: 8), clips: [Clip(sourceStart: 0, sourceEnd: 8, speed: 2)],
            layouts: [Layout(start: 2, end: 4)], cameraClips: [CameraClip(start: 2, end: 4)],
            keystrokeClips: [Layout(start: 2, end: 4, kind: .settings)], masks: [Mask(start: 2, end: 4)],
            windowShots: [WindowShot(start: 2, end: 4, window: 1)],
            audioTracks: [AudioTrack(name: "Audio")],
            audioClips: [AudioClip(start: 6, end: 10, file: "mic.m4a")],
            layers: [LayerBlock(kind: .image, start: 4, end: 7, file: "image.png", rect: NormRect())])
        let view = agentTimeline(project)
        #expect(Set(view.blocks.map(\.lane)) == ["layout", "camera", "keys", "mask", "window", "audio", "layer"])
        #expect(view.blocks.first { $0.lane == "layer" }?.to == 5)
        #expect(view.blocks.first { $0.lane == "audio" }?.to == 7)
        #expect(view.duration == 7)
        #expect(view.markers.isEmpty)
    }
}

/// T-905 tool polish (feedback run 6 #6, #7, #8).
@Test func toolPolishSheetStaleRefocus() {
    #expect(sheetTimes(count: 2, from: 0.5, to: 1.0) == [0.625, 0.875])
    #expect(sheetTimes(count: 4, from: 0, to: 8) == [1, 3, 5, 7])
    let draft = staleRevisionMessage(sent: "aaa", current: "bbb", isDraft: true, draftBase: "base1", live: "base1")
    #expect(draft == "You passed aaa; the current draft revision is bbb; retry with ifRevision bbb")
    let moved = staleRevisionMessage(sent: "aaa", current: "bbb", isDraft: true, draftBase: "base1", live: "live2")
    #expect(moved.contains("built on base1") && moved.contains("now at live2") && !moved.contains("retry with"))
    let board = Storyboard(duration: 4, fps: 10, shots: [Shot(id: "s01", from: 0, to: 4, kind: .static, boundary: .start, focus: NormRect(x: 0, y: 0, w: 0.4, h: 0.2))],
                           summary: StoryboardSummary(shots: 1, aslSec: 4, staticSec: 4, longestStatic: nil))
    let (aimed, unknown) = board.refocused(["s01": NormPoint(x: 0.95, y: 0.5), "s99": NormPoint(x: 0.5, y: 0.5)])
    #expect(unknown == ["s99"])
    #expect(aimed.shots[0].focus == NormRect(x: 0.6, y: 0.4, w: 0.4, h: 0.2) && aimed.shots[0].cursor == NormPoint(x: 0.95, y: 0.5))
}

/// T-910: one item view covers every stored array, stays inside the export, and agentTimeline is built from it.
@Test func itemsCoverEveryKind() throws {
    let base = GoldenIslandTests.fixture.project
    var p = base
    p.markers = [Marker(id: "m1", time: 5, label: "intro")]
    p.zooms = [Zoom(id: "z1", start: 2, end: 4, scale: 2)]
    p.texts = [TextBlock(id: "t1", start: 6, end: 8, text: "Hello")]
    let all = items(p)
    let kinds = Set(all.map(\.kind))
    #expect(kinds.isSuperset(of: [.clip, .gap, .zoom, .text, .layer, .marker]))
    #expect(all.allSatisfy { $0.out.start >= -1e-9 && $0.out.end <= p.exportDuration + 1e-9 && $0.out.end >= $0.out.start })
    let layer = try #require(all.first { $0.kind == .layer })
    #expect(layer.anchor == .connected && layer.media?.rate == 2 && layer.editable.contains("mediaRate"))
    #expect(abs(layer.out.end - p.exportDuration) < 1e-9)              // the appended layer is the export's end
    let timeline = agentTimeline(p)
    #expect(timeline.blocks.map(\.id).contains(layer.id) && timeline.markers.map(\.id) == ["m1"])
    #expect(timeline.clips.count == p.clips.filter { !$0.isEmpty }.count)
    #expect(timeline.blocks.first { $0.lane == "zoom" }?.editable == true && timeline.duration == (p.exportDuration * 100).rounded() / 100)
}
