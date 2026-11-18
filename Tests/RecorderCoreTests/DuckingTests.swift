import Foundation
import Testing
@testable import RecorderCore

/// T-936: a ducked music track drops to 25 % under speech with 0.3 s ramps; gain points are media-keyed and validated.
@Suite struct DuckingTests {
    func project() -> Project {
        var p = Project(source: Source(duration: 20, hasMic: true), clips: [Clip(sourceStart: 0, sourceEnd: 20)])
        p.audioClips = p.audioClips.map { var a = $0; a.end = 8; a.start = 4; a.mediaStart = 4; return a }   // speech 4–8 s
        _ = p.addImportedAudio(file: "media/music.m4a", atOutput: 0, duration: 20)
        return p
    }

    @Test func musicDucksUnderSpeech() throws {
        var p = project()
        let music = try #require(p.audioClips.first { $0.file == "media/music.m4a" })
        p.audioTracks[music.track].duck = true
        #expect(p.speechRanges() == [TimeRange(start: 4, end: 8)])
        let ramps = p.duckedVolumeRamps(music)
        func level(_ t: Double) -> Double {
            let r = ramps.first { t >= $0.range.start && t <= $0.range.end }!
            return r.start + (r.end - r.start) * (t - r.range.start) / (r.range.end - r.range.start)
        }
        #expect(abs(level(2) - 1) < 1e-9 && abs(level(6) - 0.25) < 1e-9 && abs(level(3.85) - 0.625) < 1e-6 && abs(level(10) - 1) < 1e-9)
        #expect(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(p)).audioTracks[music.track].duck == true)
    }

    @Test func gainPointsAreMediaKeyed() throws {
        var p = project()
        let music = try #require(p.audioClips.first { $0.file == "media/music.m4a" })
        let set = p.setGainPoint(audio: music.id, atOutput: 10, value: 0.2)
        #expect(set && p.checkInvariants() == nil)
        let ramps = p.audioVolumeRamps(p.audioClips.first { $0.id == music.id }!)
        #expect(ramps.contains { abs($0.range.end - 10) < 1e-9 && abs($0.end - 0.2) < 1e-9 }, "\(ramps) \(String(describing: p.audioClips.first { $0.id == music.id }?.envelope))")
        let outside = p.setGainPoint(audio: music.id, atOutput: 30, value: 0.5), loud = p.setGainPoint(audio: music.id, atOutput: 5, value: 3)
        #expect(!outside && !loud)
    }
}
