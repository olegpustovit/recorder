import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(Double.self) { self = .number(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let value): try c.encode(value)
        case .number(let value): try c.encode(value)
        case .string(let value): try c.encode(value)
        case .array(let value): try c.encode(value)
        case .object(let value): try c.encode(value)
        }
    }
}

public enum EditOp: Codable, Equatable, Sendable {
    case cut(from: Double, to: Double)
    case cutPauses(minDuration: Double, keepTail: Double, from: Double?, to: Double?)
    case cutWords(transcript: String, words: [String])
    case speed(from: Double, to: Double, speed: Double)
    case zoom(from: Double, to: Double, scale: Double, center: NormPoint?)
    case text(from: Double, to: Double, style: TextBlock.Style, text: String, position: NormPoint?, size: Double?)
    case captions(maxWords: Int)
    case highlight(from: Double, to: Double, rect: NormRect, opacity: Double?)
    case marker(at: Double, label: String)
    case update(id: String, from: Double?, to: Double?, text: String?, position: NormPoint?, size: Double?, scale: Double?, center: NormPoint?)
    case remove(id: String)
    case style(patch: [String: JSONValue])

    private enum CodingKeys: String, CodingKey {
        case op, from, to, minDuration, keepTail, transcript, words, speed, scale, center, style, text, position, size, maxWords, rect, opacity, at, label, id, patch
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ key: CodingKeys) throws -> T { try c.decode(T.self, forKey: key) }
        func optional<T: Decodable>(_ key: CodingKeys) throws -> T? { try c.decodeIfPresent(T.self, forKey: key) }
        switch try c.decode(String.self, forKey: .op) {
        case "cut": self = try .cut(from: get(.from), to: get(.to))
        case "cutPauses": self = try .cutPauses(minDuration: optional(.minDuration) ?? 0.6, keepTail: optional(.keepTail) ?? 0.12, from: optional(.from), to: optional(.to))
        case "cutWords": self = try .cutWords(transcript: get(.transcript), words: get(.words))
        case "speed": self = try .speed(from: get(.from), to: get(.to), speed: get(.speed))
        case "zoom": self = try .zoom(from: get(.from), to: get(.to), scale: get(.scale), center: optional(.center))
        case "text": self = try .text(from: get(.from), to: get(.to), style: get(.style), text: get(.text), position: optional(.position), size: optional(.size))
        case "captions": self = try .captions(maxWords: optional(.maxWords) ?? 4)
        case "highlight": self = try .highlight(from: get(.from), to: get(.to), rect: get(.rect), opacity: optional(.opacity))
        case "marker": self = try .marker(at: get(.at), label: get(.label))
        case "update": self = try .update(id: get(.id), from: optional(.from), to: optional(.to), text: optional(.text), position: optional(.position), size: optional(.size), scale: optional(.scale), center: optional(.center))
        case "remove": self = try .remove(id: get(.id))
        case "style": self = try .style(patch: get(.patch))
        default: throw DecodingError.dataCorruptedError(forKey: .op, in: c, debugDescription: "Unknown edit op; use an op from edit.apply's schema")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        func put<T: Encodable>(_ value: T, _ key: CodingKeys) throws { try c.encode(value, forKey: key) }
        func optional<T: Encodable>(_ value: T?, _ key: CodingKeys) throws { try c.encodeIfPresent(value, forKey: key) }
        func range(_ name: String, _ from: Double, _ to: Double) throws {
            try put(name, .op); try put(from, .from); try put(to, .to)
        }
        switch self {
        case let .cut(from, to): try range("cut", from, to)
        case let .cutPauses(minDuration, keepTail, from, to):
            try put("cutPauses", .op); try put(minDuration, .minDuration); try put(keepTail, .keepTail)
            try optional(from, .from); try optional(to, .to)
        case let .cutWords(transcript, words): try put("cutWords", .op); try put(transcript, .transcript); try put(words, .words)
        case let .speed(from, to, speed): try range("speed", from, to); try put(speed, .speed)
        case let .zoom(from, to, scale, center): try range("zoom", from, to); try put(scale, .scale); try optional(center, .center)
        case let .text(from, to, style, text, position, size):
            try range("text", from, to); try put(style, .style); try put(text, .text); try optional(position, .position); try optional(size, .size)
        case let .captions(maxWords): try put("captions", .op); try put(maxWords, .maxWords)
        case let .highlight(from, to, rect, opacity): try range("highlight", from, to); try put(rect, .rect); try optional(opacity, .opacity)
        case let .marker(at, label): try put("marker", .op); try put(at, .at); try put(label, .label)
        case let .update(id, from, to, text, position, size, scale, center):
            try put("update", .op); try put(id, .id); try optional(from, .from); try optional(to, .to); try optional(text, .text)
            try optional(position, .position); try optional(size, .size); try optional(scale, .scale); try optional(center, .center)
        case let .remove(id): try put("remove", .op); try put(id, .id)
        case let .style(patch): try put("style", .op); try put(patch, .patch)
        }
    }
}

public struct EditContext: Sendable {
    public var words: [Word]
    public var silent: [TimeRange]
    public init(words: [Word] = [], silent: [TimeRange] = []) { self.words = words; self.silent = silent }
}
public struct EditChange: Codable, Equatable, Sendable {
    public var op: Int
    public var summary: String
    public var at: Double
    public var delta: Double
}
public enum EditError: Error, Equatable, CustomStringConvertible {
    case invalidOp(index: Int, reason: String), outOfRange(index: Int, reason: String), transcriptChanged, invariant(String)
    public var description: String {
        switch self {
        case let .invalidOp(index, reason): return "INVALID_OP: op \(index): \(reason); revise the op and retry"
        case let .outOfRange(index, reason): return "OUT_OF_RANGE: op \(index): \(reason); call timeline.get for valid times"
        case .transcriptChanged: return "TRANSCRIPT_CHANGED: call transcript.get for the current transcript and word ids"
        case .invariant(let reason): return "INVARIANT: \(reason); revise the ops and retry"
        }
    }
}

private func mergedEditRanges(_ ranges: [TimeRange]) -> [TimeRange] {
    var union: [TimeRange] = []
    for range in ranges.sorted(by: { $0.start < $1.start }) {
        if let last = union.last, range.start <= last.end + 1e-9 {
            union[union.count - 1].end = max(last.end, range.end)
        } else { union.append(range) }
    }
    return union
}

public extension Project {
    /// Resolves every output range against the base project before applying any changes.
    func applying(_ ops: [EditOp], context: EditContext) throws -> (project: Project, changes: [EditChange]) {
        if let error = checkInvariants() { throw EditError.invariant(error) }
        let baseMap = TimeMap(clips)
        let duration = baseMap.outputDuration
        let baseBlocks = zooms.map { ($0.id, $0.start, $0.end) } + texts.map { ($0.id, $0.start, $0.end) } + masks.map { ($0.id, $0.start, $0.end) }
        func ranges(_ from: Double, _ to: Double, index: Int, recordedOnly: Bool = false) throws -> [TimeRange] {
            guard from.isFinite, to.isFinite, from >= 0, to <= duration, to > from else {
                throw EditError.outOfRange(index: index, reason: "expected 0 ≤ from < to ≤ \(duration)")
            }
            var offset = 0.0
            return clips.compactMap { clip in
                defer { offset += clip.outputDuration }
                let lo = max(from, offset), hi = min(to, offset + clip.outputDuration)
                guard hi > lo, !clip.isEmpty, !recordedOnly || clip.file == nil else { return nil }
                return TimeRange(start: clip.sourceStart + (lo - offset) * clip.timeScale,
                                 end: clip.sourceStart + (hi - offset) * clip.timeScale)
            }
        }
        func point(_ point: NormPoint?, index: Int) throws {
            if let point, !point.x.isFinite || !point.y.isFinite || !(0...1).contains(point.x) || !(0...1).contains(point.y) {
                throw EditError.invalidOp(index: index, reason: "position/center must be inside the normalized canvas")
            }
        }
        func positive(_ value: Double?, index: Int) throws {
            if let value, !value.isFinite || value <= 0 { throw EditError.invalidOp(index: index, reason: "size/scale must be finite and positive") }
        }
        var prepared: [(op: EditOp, ranges: [TimeRange], at: Double)] = []
        for (index, op) in ops.enumerated() {
            var resolved: [TimeRange] = [], at = 0.0
            switch op {
            case let .cut(from, to), let .speed(from, to, _), let .zoom(from, to, _, _), let .text(from, to, _, _, _, _), let .highlight(from, to, _, _):
                resolved = try ranges(from, to, index: index); at = from
                guard !resolved.isEmpty else { throw EditError.invalidOp(index: index, reason: "range contains only gaps") }
            case let .cutPauses(minimum, tail, from, to):
                guard minimum.isFinite, minimum >= 0, tail.isFinite, tail >= 0 else {
                    throw EditError.invalidOp(index: index, reason: "minDuration and keepTail must be finite and nonnegative")
                }
                let bounds = try ranges(from ?? 0, to ?? duration, index: index, recordedOnly: true)
                let pauses = context.silent.filter { $0.start.isFinite && $0.end.isFinite && $0.end - $0.start >= minimum && $0.end - $0.start > 2 * tail + 0.05 }
                    .map { TimeRange(start: $0.start + tail, end: $0.end - tail) }
                resolved = baseMap.sourceRanges(forMedia: pauses).flatMap { pause in
                    bounds.compactMap { bound in
                        let lo = max(bound.start, pause.start), hi = min(bound.end, pause.end)
                        return hi > lo ? TimeRange(start: lo, end: hi) : nil
                    }
                }
                at = resolved.first.flatMap { baseMap.outputTime(atSource: $0.start) } ?? from ?? 0
            case let .cutWords(transcript, ids):
                guard transcript == transcriptID(context.words) else { throw EditError.transcriptChanged }
                var media: [TimeRange] = []
                for id in ids {
                    guard id.first == "w", let i = Int(id.dropFirst()), context.words.indices.contains(i), id == "w\(i)" else {
                        throw EditError.invalidOp(index: index, reason: "unknown word \(id); call transcript.get")
                    }
                    let word = context.words[i]
                    let left = i > 0 ? min(0.15, max(0, (word.start - context.words[i - 1].end) / 2)) : 0
                    let right = i + 1 < context.words.count ? min(0.15, max(0, (context.words[i + 1].start - word.end) / 2)) : 0
                    guard word.start.isFinite, word.end.isFinite, word.end > word.start else {
                        throw EditError.invalidOp(index: index, reason: "invalid word timing; transcribe again")
                    }
                    media.append(TimeRange(start: max(0, word.start - left), end: word.end + right))
                }
                resolved = baseMap.sourceRanges(forMedia: media)
                at = resolved.first.flatMap { baseMap.outputTime(atSource: $0.start) } ?? 0
            case let .update(id, from, to, _, _, _, _, _):
                let block = baseBlocks.first { $0.0 == id }
                guard let block else { throw EditError.invalidOp(index: index, reason: "unknown block \(id)") }
                at = from ?? baseMap.outputTime(atSource: block.1) ?? 0
                if from != nil || to != nil {
                    let mapped = try ranges(at, to ?? baseMap.outputTime(atSource: block.2) ?? duration, index: index)
                    guard let first = mapped.first, let last = mapped.last else { throw EditError.invalidOp(index: index, reason: "updated range contains only gaps") }
                    resolved = [TimeRange(start: from == nil ? block.1 : first.start, end: to == nil ? block.2 : last.end)]
                }
            case let .marker(time, _):
                guard time.isFinite, time >= 0, time <= duration else { throw EditError.outOfRange(index: index, reason: "marker must be inside the timeline") }
                at = time
            case .remove(let id):
                guard let block = baseBlocks.first(where: { $0.0 == id }) else { throw EditError.invalidOp(index: index, reason: "unknown block \(id)") }
                at = baseMap.outputTime(atSource: block.1) ?? 0
            case .captions, .style: break
            }
            prepared.append((op, mergedEditRanges(resolved), at))
        }
        var result = self, changes: [EditChange] = []
        var cuts: [(index: Int, ranges: [TimeRange])] = []
        func stamp(_ time: Double) -> String { String(format: "%d:%04.1f", Int(time) / 60, time.truncatingRemainder(dividingBy: 60)) }
        for (index, item) in prepared.enumerated() {
            let before = TimeMap(result.clips).outputDuration
            let span = item.ranges.first.map { TimeRange(start: $0.start, end: item.ranges.last!.end) }
            var summary: String
            switch item.op {
            case .cut, .cutPauses, .cutWords:
                cuts.append((index, item.ranges))
                let kind: String
                switch item.op { case .cutPauses: kind = "Cut pause"; case .cutWords: kind = "Cut words"; default: kind = "Cut" }
                summary = "\(kind) \(stamp(item.at))"
            case let .speed(_, _, speed):
                guard speed.isFinite, (0.25...16).contains(speed) else { throw EditError.invalidOp(index: index, reason: "speed must be 0.25–16") }
                for range in item.ranges.reversed() {
                    try result.agentSplit(range, index: index)
                    let indices = result.clips.indices.filter { !result.clips[$0].isEmpty && result.clips[$0].sourceStart >= range.start - 1e-9 && result.clips[$0].sourceEnd <= range.end + 1e-9 }
                    for i in indices.reversed() {
                        result.setSpeed(i, speed)
                        guard abs(result.clips[i].speed - speed) < 1e-9 else { throw EditError.invalidOp(index: index, reason: "speed cannot fit this clip; enable linked video edits") }
                    }
                }
                summary = "Speed \(speed)× \(stamp(item.at))"
            case let .zoom(_, _, scale, center):
                try positive(scale, index: index); try point(center, index: index)
                guard scale >= 1, let span else { throw EditError.invalidOp(index: index, reason: "zoom scale must be at least 1") }
                if let overlap = result.zooms.first(where: { $0.start < span.end && $0.end > span.start }) {
                    throw EditError.invalidOp(index: index, reason: "zoom overlaps \(overlap.id)")
                }
                guard span.end - span.start >= 0.5, let id = result.addZoom(atSource: span.start, length: span.end - span.start, mode: center == nil ? .auto : .manual),
                      let i = result.zooms.firstIndex(where: { $0.id == id.uuidString }) else { throw EditError.invalidOp(index: index, reason: "zoom needs at least 0.5 source seconds in a free lane") }
                result.zooms[i].scale = scale
                if let center { result.zooms[i].center = center }
                summary = "Zoom \(scale)× \(stamp(item.at))"
            case let .text(_, _, style, text, position, size):
                try point(position, index: index); try positive(size, index: index)
                guard let span, span.end - span.start >= 0.5, !result.texts.contains(where: { $0.start < span.end && $0.end > span.start }),
                      let id = result.addText(atSource: span.start, length: span.end - span.start, style: style, text: text),
                      let i = result.texts.firstIndex(where: { $0.id == id.uuidString }) else { throw EditError.invalidOp(index: index, reason: "text overlaps a block or is shorter than 0.5 source seconds") }
                if let position { result.texts[i].position = position }
                if let size { result.texts[i].size = size }
                summary = "Add \(style.rawValue) \(stamp(item.at))"
            case let .captions(maxWords):
                guard !context.words.isEmpty, maxWords > 0, maxWords <= 100 else { throw EditError.invalidOp(index: index, reason: "captions need a transcript and maxWords between 1 and 100") }
                let mapped = context.words.flatMap { word in
                    baseMap.sourceRanges(forMedia: [TimeRange(start: word.start, end: word.end)]).map {
                        Word(text: word.text, start: $0.start, end: $0.end)
                    }
                }.sorted { $0.start < $1.start }
                result.replaceCaptions(captionPhrases(words: mapped, maxWords: maxWords))
                summary = "Generate captions"
            case let .highlight(_, _, rect, opacity):
                guard [rect.x, rect.y, rect.w, rect.h, opacity ?? 0.6].allSatisfy(\.isFinite), rect.x >= 0, rect.y >= 0, rect.w > 0, rect.h > 0,
                      rect.x + rect.w <= 1, rect.y + rect.h <= 1, (0...1).contains(opacity ?? 0.6),
                      let span, span.end - span.start >= 0.5, !result.masks.contains(where: { $0.start < span.end && $0.end > span.start }),
                      result.addMask(atSource: span.start, length: span.end - span.start, kind: .highlight, rect: rect, opacity: opacity ?? 0.6) != nil else {
                    throw EditError.invalidOp(index: index, reason: "highlight needs a normalized rect, opacity 0–1 and a free range of at least 0.5 source seconds")
                }
                summary = "Highlight \(stamp(item.at))"
            case .marker: throw EditError.invalidOp(index: index, reason: "markers are not available until T-803")
            case let .update(id, _, _, text, position, size, scale, center):
                try point(position, index: index); try point(center, index: index); try positive(size, index: index); try positive(scale, index: index)
                if let span, span.end - span.start < 0.5 { throw EditError.invalidOp(index: index, reason: "updated block needs at least 0.5 source seconds") }
                if let i = result.zooms.firstIndex(where: { $0.id == id }) {
                    guard text == nil, position == nil, size == nil, scale == nil || scale! >= 1 else { throw EditError.invalidOp(index: index, reason: "zoom supports scale/center and times") }
                    if let span { result.zooms[i].start = span.start; result.zooms[i].end = span.end }
                    if let scale { result.zooms[i].scale = scale }
                    if let center { result.zooms[i].center = center; result.zooms[i].mode = .manual }
                    result.zooms.sort { $0.start < $1.start }
                } else if let i = result.texts.firstIndex(where: { $0.id == id }) {
                    guard scale == nil, center == nil else { throw EditError.invalidOp(index: index, reason: "text supports text/position/size and times") }
                    if let span { result.texts[i].start = span.start; result.texts[i].end = span.end }
                    if let text { result.texts[i].setText(text) }
                    if let position { result.texts[i].position = position }
                    if let size { result.texts[i].size = size }
                    result.texts.sort { $0.start < $1.start }
                } else if let i = result.masks.firstIndex(where: { $0.id == id }) {
                    guard text == nil, position == nil, size == nil, scale == nil, center == nil else { throw EditError.invalidOp(index: index, reason: "mask update supports times only") }
                    if let span { result.masks[i].start = span.start; result.masks[i].end = span.end }
                    result.masks.sort { $0.start < $1.start }
                } else { throw EditError.invalidOp(index: index, reason: "unknown block \(id)") }
                summary = "Update block \(stamp(item.at))"
            case let .remove(id):
                guard result.zooms.contains(where: { $0.id == id }) || result.texts.contains(where: { $0.id == id }) || result.masks.contains(where: { $0.id == id }) else { throw EditError.invalidOp(index: index, reason: "unknown block \(id)") }
                result.removeBlock(id: id)
                summary = "Remove block"
            case let .style(patch):
                do {
                    let encoder = JSONEncoder(), decoder = JSONDecoder()
                    var original = try decoder.decode([String: JSONValue].self, from: encoder.encode(Preset(name: "Agent", from: result)))
                    // Codable omits nil options; keep their known keys available to a patch.
                    for (section, key) in [("frame", "enabled"), ("camera", "position")] {
                        if case .object(var fields) = original[section] {
                            if fields[key] == nil { fields[key] = .null }
                            original[section] = .object(fields)
                        }
                    }
                    func merge(_ base: JSONValue, _ patch: JSONValue, path: String) throws -> JSONValue {
                        guard case .object(var fields) = base else {
                            if case .number(let value) = patch, !value.isFinite { throw EditError.invalidOp(index: index, reason: "nonfinite style value at \(path)") }
                            if path == "camera.position.", case .object(let fields) = patch, !Set(fields.keys).isSubset(of: ["x", "y"]) {
                                throw EditError.invalidOp(index: index, reason: "camera.position accepts x and y only")
                            }
                            return patch
                        }
                        guard case .object(let updates) = patch else { throw EditError.invalidOp(index: index, reason: "\(path) must be an object") }
                        for (key, value) in updates {
                            guard let existing = fields[key], key != "name" else { throw EditError.invalidOp(index: index, reason: "unknown style key \(path)\(key)") }
                            fields[key] = try merge(existing, value, path: "\(path)\(key).")
                        }
                        return .object(fields)
                    }
                    let merged = try merge(.object(original), .object(patch), path: "")
                    let preset = try decoder.decode(Preset.self, from: encoder.encode(merged))
                    guard preset.frame.padding >= 0, preset.frame.padding < 0.5, preset.frame.cornerRadius >= 0, preset.frame.inset >= 0,
                          preset.frame.shadow >= 0, preset.cursor.size > 0, preset.camera.size > 0, preset.camera.aspect > 0,
                          preset.background.blur >= 0 else { throw EditError.invalidOp(index: index, reason: "style dimensions are outside their valid range") }
                    try point(preset.camera.position, index: index)
                    preset.apply(to: &result)
                } catch let error as EditError { throw error }
                catch { throw EditError.invalidOp(index: index, reason: "invalid style patch: \(error.localizedDescription)") }
                summary = "Update styling"
            }
            if let error = result.checkInvariants() { throw EditError.invariant("op \(index): \(error)") }
            changes.append(EditChange(op: index, summary: summary, at: item.at, delta: TimeMap(result.clips).outputDuration - before))
        }
        // Remove the union once; overlapping cut ops must never remove the same footage twice.
        var removed: [TimeRange] = []
        for cut in cuts {
            let novel = cut.ranges.reduce(into: [TimeRange]()) { parts, range in
                var pieces = [range]
                for old in removed {
                    pieces = pieces.flatMap { piece -> [TimeRange] in
                        guard old.end > piece.start, old.start < piece.end else { return [piece] }
                        var kept: [TimeRange] = []
                        if piece.start < old.start { kept.append(TimeRange(start: piece.start, end: old.start)) }
                        if piece.end > old.end { kept.append(TimeRange(start: old.end, end: piece.end)) }
                        return kept
                    }
                }
                parts += pieces
            }
            changes[cut.index].delta = -novel.reduce(0) { total, range in
                total + result.clips.reduce(0) { sum, clip in sum + max(0, min(range.end, clip.sourceEnd) - max(range.start, clip.sourceStart)) / clip.timeScale }
            }
            changes[cut.index].summary += String(format: " (−%.2f s)", -changes[cut.index].delta)
            removed += cut.ranges
        }
        let union = mergedEditRanges(removed)
        // Validate all boundaries before the nonthrowing shared removal helper can skip a refused split.
        var splitTrial = result
        for range in union.reversed() {
            for boundary in [range.end, range.start] {
                let owner = cuts.first { $0.ranges.contains { abs($0.start - boundary) < 1e-9 || abs($0.end - boundary) < 1e-9 } }?.index ?? 0
                try splitTrial.agentSplit(TimeRange(start: boundary, end: boundary), index: owner)
            }
        }
        let beforeCut = TimeMap(result.clips).outputDuration
        result.agentRemoveSourceRanges(union, includeImported: true)
        let expected = -changes.filter { change in cuts.contains { $0.index == change.op } }.reduce(0) { $0 + $1.delta }
        guard abs(beforeCut - TimeMap(result.clips).outputDuration - expected) < 1e-7 else {
            throw EditError.invalidOp(index: cuts.first?.index ?? 0, reason: "cut could not remove the exact range; keep at least 0.1 seconds of media at each split")
        }
        if let error = result.checkInvariants() { throw EditError.invariant(error) }
        return (result, changes)
    }

    /// Removes recording ranges using the normal split/delete path, retaining source-time effects for undo/restoration.
    mutating func removeSourceRanges(_ ranges: [TimeRange]) {
        agentRemoveSourceRanges(ranges, includeImported: false)
    }

    private mutating func agentRemoveSourceRanges(_ ranges: [TimeRange], includeImported: Bool) {
        let original = self
        let ripple = rippleDelete
        let effects = (zooms, texts, masks, layouts, keystrokeClips, windowShots)
        rippleDelete = true
        defer {
            rippleDelete = ripple
            (zooms, texts, masks, layouts, keystrokeClips, windowShots) = effects
            if checkInvariants() != nil { self = original }
        }
        for range in ranges.sorted(by: { $0.start > $1.start }) where range.start.isFinite && range.end.isFinite && range.end > range.start {
            let before = self
            guard (try? agentSplit(range, index: 0, includeImported: includeImported)) != nil else { continue }
            let indices = Set(clips.indices.filter { !clips[$0].isEmpty && (includeImported || clips[$0].file == nil) && clips[$0].sourceStart >= range.start - 1e-9 && clips[$0].sourceEnd <= range.end + 1e-9 })
            deleteClips(indices, propagate: true)
            if checkInvariants() != nil { self = before }
        }
    }

    private mutating func agentSplit(_ range: TimeRange, index: Int, includeImported: Bool = true) throws {
        for boundary in [range.end, range.start] {
            guard clips.contains(where: { !$0.isEmpty && (includeImported || $0.file == nil) && boundary > $0.sourceStart + 1e-9 && boundary < $0.sourceEnd - 1e-9 }) else { continue }
            guard let output = TimeMap(clips).outputTime(atSource: boundary), split(atOutput: output) else {
                throw EditError.invalidOp(index: index, reason: "split at \(boundary) is too close to a clip edge; retain at least 0.1 seconds of media")
            }
        }
    }
}
