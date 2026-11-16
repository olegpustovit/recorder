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
