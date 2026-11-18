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
        /// false: `set` cannot change this block (`edit.remove` still can).
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
    func included(_ range: TimeRange) -> Bool { range.end > (from ?? -.infinity) && range.start < (to ?? .infinity) }
    var clips: [AgentTimeline.Clip] = [], blocks: [AgentTimeline.Block] = [], markers: [AgentTimeline.Marker] = []
    for item in items(project) {
        switch item.kind {
        case .gap: continue
        case .clip:
            guard included(item.out), let index = Int(item.id.dropFirst()) else { continue }
            let clip = project.clips[index]
            clips.append(.init(index: index, from: agentTime(item.out.start), to: agentTime(item.out.end), speed: clip.speed, file: clip.file))
        case .marker:
            guard item.out.start >= (from ?? -.infinity), item.out.start < (to ?? .infinity) else { continue }
            markers.append(.init(id: item.id, at: agentTime(item.out.start), label: item.label))
        default:
            guard included(item.out) else { continue }
            let editable = !item.editable.isEmpty
            blocks.append(.init(id: item.id, lane: item.kind.rawValue, from: agentTime(item.out.start), to: agentTime(item.out.end), label: item.label, editable: editable,
                                reason: editable ? nil : "\(item.kind.rawValue) blocks have no set fields; remove with edit.remove or change them in Recorder"))
        }
    }
    return AgentTimeline(duration: agentTime(project.exportDuration), clips: clips,
                         blocks: blocks.sorted { $0.from < $1.from }, markers: markers.sorted { $0.at < $1.at })
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

/// render.sheet sample times: `count` tile centres evenly over from…to (feedback run 6 #6: from/to were ignored). T-905.
public func sheetTimes(count: Int, from: Double, to: Double) -> [Double] {
    (0..<max(0, count)).map { from + (Double($0) + 0.5) * (to - from) / Double(count) }
}

/// STALE_REVISION text: what the agent sent, what is current, and the base only when the base is the problem (feedback run 6 #8).
public func staleRevisionMessage(sent: String, current: String, isDraft: Bool, draftBase: String?, live: String) -> String {
    "You passed \(sent); the current \(isDraft ? "draft" : "project") revision is \(current)"
        + (draftBase.map { $0 != live } == true ? "; the draft was built on \(draftBase!) but the editor is now at \(live), so discard or submit it first"
                                               : "; retry with ifRevision \(current)")
}
