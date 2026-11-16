import Foundation

public struct AgentTimeline: Codable, Equatable, Sendable {
    public struct Clip: Codable, Equatable, Sendable {
        public var index: Int
        public var from: Double
        public var to: Double
        public var speed: Double
        public var file: String?
    }
    public struct Block: Codable, Equatable, Sendable {
        public var id: String
        public var lane: String
        public var from: Double
        public var to: Double
        public var label: String
        /// false: `edit.update` cannot change this block (`edit.remove` still can).
        public var editable = true
        public var reason: String? = nil
    }
    public struct Marker: Codable, Equatable, Sendable {
        public var id: String
        public var at: Double
        public var label: String
    }
    public var duration: Double
    public var clips: [Clip]
    public var blocks: [Block]
    public var markers: [Marker]
}

private func agentTime(_ time: Double) -> Double { (time * 100).rounded() / 100 }

public func agentTimeline(_ project: Project, from: Double? = nil, to: Double? = nil) -> AgentTimeline {
    let map = TimeMap(project.clips)
    func included(_ start: Double, _ end: Double) -> Bool {
        end > (from ?? -.infinity) && start < (to ?? .infinity)
    }
    var clips: [AgentTimeline.Clip] = []
    var output = 0.0
    for (index, clip) in project.clips.enumerated() {
        let end = output + clip.outputDuration
        if !clip.isEmpty && included(output, end) {
            clips.append(.init(index: index, from: agentTime(output), to: agentTime(end), speed: clip.speed, file: clip.file))
        }
        output = end
    }
    var blocks: [AgentTimeline.Block] = []
    func append(_ id: String, _ lane: String, _ start: Double, _ end: Double, _ label: String) {
        guard included(start, end) else { return }
        let editable = ["zoom", "text", "mask", "layer"].contains(lane)
        blocks.append(.init(id: id, lane: lane, from: agentTime(start), to: agentTime(end), label: label, editable: editable,
                            reason: editable ? nil : "\(lane) blocks have no edit.update fields; remove with edit.remove or change them in Recorder"))
    }
    func sourceBlock(_ id: String, _ lane: String, _ start: Double, _ end: Double, _ label: String) {
        var offset = 0.0
        for clip in project.clips {
            let lo = max(start, clip.sourceStart), hi = min(end, clip.sourceEnd)
            if hi > lo {
                append(id, lane, offset + (lo - clip.sourceStart) / clip.timeScale,
                       offset + (hi - clip.sourceStart) / clip.timeScale, label)
            }
            offset += clip.outputDuration
        }
    }
    for block in project.zooms { sourceBlock(block.id, "zoom", block.start, block.end, String(format: "%.1f×", locale: Locale(identifier: "en_US_POSIX"), block.scale)) }
    for block in project.texts { sourceBlock(block.id, "text", block.start, block.end, String(block.text.prefix(24))) }
    for block in project.masks { sourceBlock(block.id, "mask", block.start, block.end, block.kind.rawValue) }
    for block in project.layouts { sourceBlock(block.id, "layout", block.start, block.end, block.kind.rawValue) }
    for block in project.cameraClips { sourceBlock(block.id, "camera", block.start, block.end, "Camera") }
    for block in project.keystrokeClips { sourceBlock(block.id, "keys", block.start, block.end, "Keys") }
    for block in project.windowShots { sourceBlock(block.id, "window", block.start, block.end, "Window \(block.window + 1)") }
    for block in project.layers {
        if let start = map.outputTime(atSource: block.start) {
            append(block.id, "layer", start, start + block.end - block.start, block.kind.rawValue)
        }
    }
    for block in project.audioClips {
        for segment in project.audioSegments(block) {
            append(block.id, "audio", segment.output.start, segment.output.end, block.file)
        }
    }
    let markers: [AgentTimeline.Marker] = project.markers.compactMap { marker in
        guard project.clips.contains(where: { !$0.isEmpty && marker.time >= $0.sourceStart &&
            (marker.time < $0.sourceEnd || (marker.time == $0.sourceEnd && marker.time == project.clips.last?.sourceEnd)) }),
              let at = map.outputTime(atSource: marker.time), at >= (from ?? -.infinity), at < (to ?? .infinity) else { return nil }
        return .init(id: marker.id, at: agentTime(at), label: marker.label)
    }.sorted { $0.at < $1.at }
    return AgentTimeline(duration: agentTime(project.exportDuration), clips: clips,
                         blocks: blocks.sorted { $0.from < $1.from }, markers: markers)
}

public struct AgentWord: Codable, Equatable, Sendable {
    public var id: String
    public var text: String
    public var from: Double
    public var to: Double
    public var filler: Bool
}

public struct AgentTranscript: Codable, Equatable, Sendable {
    public var transcript: String
    public var words: [AgentWord]
    public var phrases: [String]?
}

public func agentTranscript(_ project: Project, words: [Word], from: Double? = nil, to: Double? = nil,
                            phrases: Bool = false) -> AgentTranscript {
    var result: [AgentWord] = []
    var output = 0.0
    for clip in project.clips {
        defer { output += clip.outputDuration }
        guard !clip.isEmpty, clip.file == nil else { continue }
        for (index, word) in words.enumerated() where word.start >= clip.mediaIn && word.start < clip.mediaEnd {
            let start = output + (word.start - clip.mediaIn) / clip.speed
            let end = output + (min(word.end, clip.mediaEnd) - clip.mediaIn) / clip.speed
            guard end > (from ?? -.infinity), start < (to ?? .infinity) else { continue }
            result.append(AgentWord(id: "w\(index)", text: word.text, from: agentTime(start),
                                    to: agentTime(end), filler: isFiller(word.text)))
        }
    }
    result.sort { $0.from < $1.from }
    let lines: [String]? = phrases ? captionPhrases(words: result.map {
        Word(text: $0.text, start: $0.from, end: $0.to)
    }).map { block in
        let tenths = Int((block.start * 10).rounded())
        return String(format: "[%d:%02d.%d] %@", tenths / 600, tenths / 10 % 60, tenths % 10, block.text)
    } : nil
    return AgentTranscript(transcript: transcriptID(words), words: result, phrases: lines)
}

public func isFiller(_ text: String) -> Bool {
    ["um", "uh", "er", "ah", "erm", "hmm", "mm"].contains(
        text.trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines)).lowercased())
}

public func transcriptID(_ words: [Word]) -> String {
    var hash: UInt32 = 2_166_136_261
    for word in words {
        for byte in "\(word.text.utf8.count):\(word.text):\(word.start):\(word.end);".utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
    }
    return String(format: "t-%08x", hash)
}

