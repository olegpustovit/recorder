import Foundation

public func takePlacement(playheadOutput: Double, firstSampleHost: Double, playbackHost: Double) -> Double {
    playheadOutput + (firstSampleHost - playbackHost)
}

/// A kept piece of the source recording, played at `speed`. See docs/SPEC.md §5.
public struct Clip: Codable, Equatable, Sendable {
    public var sourceStart: Double
    public var sourceEnd: Double
    public var speed: Double
    /// Explicit fade lengths in output seconds; missing values mean Off (including older projects).
    public var fadeIn: Double? = nil
    public var fadeOut: Double? = nil
    public var hideCursor: Bool? = nil
    public var isGap: Bool? = nil
    public var mediaStart: Double? = nil
    /// Separate the timeline clock from playback rate for an unlinked speed edit.
    public var clockSpeed: Double? = nil
    // shortcut: synthesized Codable, so a colour added by a newer app version fails the load; add a lenient init(from:) before adding colours.
    public var color: BlockColor? = nil
    public var timeScale: Double { clockSpeed ?? speed }
    public var mediaDuration: Double { (sourceEnd - sourceStart) * (speed / timeScale) }
    public var mediaEnd: Double { mediaIn + mediaDuration }
    public func mediaTime(atSource time: Double) -> Double { mediaIn + (time - sourceStart) * (speed / timeScale) }
    public var mediaIn: Double { mediaStart ?? sourceStart }
    public var isEmpty: Bool { isGap == true }
    public init(sourceStart: Double, sourceEnd: Double, speed: Double = 1) {
        self.sourceStart = sourceStart; self.sourceEnd = sourceEnd; self.speed = speed
    }
    public var outputDuration: Double { (sourceEnd - sourceStart) / timeScale }
}

/// Maps between output (what the viewer sees) and source (what was recorded) time.
public struct TimeMap: Sendable {
    public let clips: [Clip]
    public init(_ clips: [Clip]) { self.clips = clips }

    public var outputDuration: Double { clips.reduce(0) { $0 + $1.outputDuration } }

    /// Every kept occurrence of recorded footage, in editing-clock order (copies included).
    public func sourceRanges(forMedia ranges: [TimeRange]) -> [TimeRange] {
        clips.filter { !$0.isEmpty }.flatMap { clip in
            ranges.compactMap { range -> TimeRange? in
                let start = max(range.start, clip.mediaIn), end = min(range.end, clip.mediaEnd)
                guard end > start else { return nil }
                let scale = clip.timeScale / clip.speed
                return TimeRange(start: clip.sourceStart + (start - clip.mediaIn) * scale,
                                 end: clip.sourceStart + (end - clip.mediaIn) * scale)
            }
        }.sorted { $0.start < $1.start }
    }

    /// Clamps to the valid range, so callers can pass any playhead value.
    public func sourceTime(atOutput t: Double) -> Double {
        var start = 0.0
        for c in clips {
            let end = start + c.outputDuration
            if t < end { return c.sourceStart + max(0, t - start) * c.timeScale }
            start = end
        }
        return clips.last?.sourceEnd ?? 0
    }

    /// nil when `s` falls in a removed segment.
    public func outputTime(atSource s: Double) -> Double? {
        var start = 0.0
        for c in clips {
            if s >= c.sourceStart && s <= c.sourceEnd { return start + (s - c.sourceStart) / c.timeScale }
            start += c.outputDuration
        }
        return nil
    }
}

public extension Project {
    func audioSegments(_ audio: AudioClip) -> [(media: TimeRange, output: TimeRange)] {
        let rate = audio.mediaRate ?? 1
        guard audio.start.isFinite, audio.end.isFinite, audio.end > audio.start,
              audio.mediaStart.isFinite, audio.mediaStart >= 0, rate.isFinite, rate > 0 else { return [] }
        if audio.link != .screen && audio.link != .camera {
            guard let start = TimeMap(clips).outputTime(atSource: audio.start) else { return [] }
            let duration = audio.end - audio.start
            return [(TimeRange(start: audio.mediaStart, end: audio.mediaStart + duration * rate),
                     TimeRange(start: start, end: start + duration))]
        }
        var output = 0.0
        var segments: [(media: TimeRange, output: TimeRange)] = []
        for clip in clips {
            guard clip.timeScale.isFinite, clip.timeScale > 0 else { return [] }
            let lower = max(audio.start, clip.sourceStart), upper = min(audio.end, clip.sourceEnd)
            if upper - lower > 1e-9 {
                let media = audio.mediaStart + (lower - audio.start) * rate
                let start = output + (lower - clip.sourceStart) / clip.timeScale
                segments.append((TimeRange(start: media, end: media + (upper - lower) * rate),
                                 TimeRange(start: start, end: start + (upper - lower) / clip.timeScale)))
            }
            output += clip.outputDuration
        }
        return segments
    }

    func audioVolumeRamps(_ audio: AudioClip) -> [(range: TimeRange, start: Double, end: Double)] {
        let segments = audioSegments(audio)
        guard let first = segments.first, let last = segments.last, audio.gain.isFinite else { return [] }
        if let envelope = audio.envelope {
            guard audio.envelopeIsValid else { return [] }
            func value(at time: Double) -> Double {
                guard let right = envelope.firstIndex(where: { $0.time > time }) else { return envelope.last!.value }
                guard right > 0 else { return envelope[0].value }
                let a = envelope[right - 1], b = envelope[right]
                return a.value + (b.value - a.value) * (time - a.time) / (b.time - a.time)
            }
            return segments.flatMap { segment in
                let times = [segment.media.start] + envelope.filter { $0.time > segment.media.start && $0.time < segment.media.end }.map(\.time) + [segment.media.end]
                func output(_ time: Double) -> Double {
                    segment.output.start + (time - segment.media.start) * (segment.output.end - segment.output.start) / (segment.media.end - segment.media.start)
                }
                return zip(times, times.dropFirst()).map { a, b in
                    (TimeRange(start: output(a), end: output(b)), audio.gain * value(at: a), audio.gain * value(at: b))
                }
            }
        }
        let duration = last.output.end - first.output.start
        guard duration.isFinite, duration > 0 else { return [] }
        let fadeIn = min(duration, max(0, audio.fadeIn?.isFinite == true ? audio.fadeIn! : 0))
        let fadeOut = min(duration, max(0, audio.fadeOut?.isFinite == true ? audio.fadeOut! : 0))
        var boundaries = [0.0, duration]
        if fadeIn + fadeOut > duration { boundaries.append(duration * fadeIn / (fadeIn + fadeOut)) }
        else {
            if fadeIn > 0 { boundaries.append(fadeIn) }
            if fadeOut > 0 { boundaries.append(duration - fadeOut) }
        }
        let times = Set(boundaries).sorted()
        func volume(_ time: Double) -> Double {
            audio.gain * min(1, fadeIn > 0 ? time / fadeIn : 1, fadeOut > 0 ? (duration - time) / fadeOut : 1)
        }
        return zip(times, times.dropFirst()).map { start, end in
            (TimeRange(start: first.output.start + start, end: first.output.start + end), volume(start), volume(end))
        }
    }

    /// Freeze only faded clips; media-keyed points preserve partial ramps through subsequent edits.
    internal func audioPreservingEnvelope(_ audio: AudioClip) -> AudioClip {
        guard audio.envelope == nil, (audio.fadeIn ?? 0) > 0 || (audio.fadeOut ?? 0) > 0 else { return audio }
        var unit = audio
        unit.gain = 1
        let ramps = audioVolumeRamps(unit)
        func value(at time: Double) -> Double {
            guard let ramp = ramps.first(where: { time >= $0.range.start - 1e-9 && time <= $0.range.end + 1e-9 }) else { return 0 }
            return min(1, max(0, ramp.start + (ramp.end - ramp.start) * (time - ramp.range.start) / (ramp.range.end - ramp.range.start)))
        }
        var points: [AudioGainPoint] = []
        for segment in audioSegments(audio) {
            let times = Set([segment.output.start, segment.output.end] + ramps.flatMap { [$0.range.start, $0.range.end] }
                .filter { $0 > segment.output.start && $0 < segment.output.end }).sorted()
            for time in times {
                let media = segment.media.start + (time - segment.output.start) * (segment.media.end - segment.media.start) / (segment.output.end - segment.output.start)
                if let previous = points.last, abs(previous.time - media) < 1e-9 { continue }
                points.append(AudioGainPoint(time: media, value: value(at: time)))
            }
        }
        var result = audio
        if points.count >= 2 { result.envelope = points }
        return result
    }

    /// End of retained video, audio and layers in output time; trailing gaps and effects alone do not extend it.
    var exportDuration: Double {
        guard !clips.isEmpty else { return 0 }
        var output = 0.0, end = 0.0
        for clip in clips {
            let duration = clip.outputDuration
            guard duration.isFinite, duration >= 0, clip.timeScale > 0 else { return 0 }
            if !clip.isEmpty { end = output + duration }
            if source.hasCamera {
                for camera in cameraClips {
                    let lo = max(clip.sourceStart, camera.start), hi = min(clip.sourceEnd, camera.end)
                    if hi > lo { end = max(end, output + (hi - clip.sourceStart) / clip.timeScale) }
                }
            }
            output += duration
        }
        for audio in audioClips {
            if let audioEnd = audioSegments(audio).last?.output.end { end = max(end, audioEnd) }
        }
        let map = TimeMap(clips)
        for layer in layers where layer.end.isFinite && layer.end > layer.start {
            if let start = map.outputTime(atSource: layer.start) { end = max(end, start + layer.end - layer.start) }
        }
        return end.isFinite ? end : 0
    }
}
