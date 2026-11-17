import CryptoKit
import Foundation

private final class EditIDSequence: @unchecked Sendable {
    let seed: String
    private var count = 0
    private let lock = NSLock()
    init(_ seed: String) { self.seed = seed }
    func next() -> UUID {
        let index = lock.withLock { let value = count; count += 1; return value }
        let bytes = Array(SHA256.hash(data: Data("\(seed):\(index)".utf8)).prefix(16))
        return bytes.withUnsafeBufferPointer { NSUUID(uuidBytes: $0.baseAddress!) as UUID }
    }
}

private enum EditIDs {
    @TaskLocal static var sequence: EditIDSequence?
    static func withSeed<T>(_ seed: String?, _ body: () throws -> T) rethrows -> T {
        try $sequence.withValue(seed.map(EditIDSequence.init), operation: body)
    }
}

/// Draft replay scopes deterministic ids to a synchronous edit; ordinary editor operations keep random UUIDs.
@usableFromInline func makeProjectID() -> UUID { EditIDs.sequence?.next() ?? UUID() }

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

public enum EditTime: Codable, Equatable, Sendable, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral {
    case seconds(Double)
    /// Marker by id, or by label when exactly one marker has it.
    case marker(String, offset: Double = 0)
    /// A same-batch `ref` name declared on an earlier op: that op's start.
    case ref(String, offset: Double = 0)
    /// A shot edge from `analyze.shots`, resolved by `EditContext.shotTime`.
    case shot(String, end: Bool = false)
    public init(integerLiteral value: Int) { self = .seconds(Double(value)) }
    public init(floatLiteral value: Double) { self = .seconds(value) }
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let value = try? c.decode(Double.self) { self = .seconds(value); return }
        let fields = try c.decode([String: JSONValue].self)
        let kinds = ["marker", "ref", "shot"].filter { fields[$0] != nil }
        guard kinds.count == 1, case .string(let name)? = fields[kinds[0]], !name.isEmpty,
              Set(fields.keys).isSubset(of: kinds[0] == "shot" ? ["shot", "edge"] : [kinds[0], "offset"]) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Expected seconds, {marker: id or label, offset}, {ref: name, offset} or {shot: id, edge: start|end}")
        }
        if kinds[0] == "shot" {
            var end = false
            if let edge = fields["edge"] {
                guard case .string(let value) = edge, ["start", "end"].contains(value) else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Shot edge must be start or end") }
                end = value == "end"
            }
            self = .shot(name, end: end); return
        }
        var offset = 0.0
        if let value = fields["offset"] {
            guard case .number(let number) = value else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Anchor offset must be seconds") }
            offset = number
        }
        self = kinds[0] == "marker" ? .marker(name, offset: offset) : .ref(name, offset: offset)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .seconds(let value): try c.encode(value)
        case let .marker(id, offset): try c.encode(["marker": JSONValue.string(id), "offset": .number(offset)])
        case let .ref(name, offset): try c.encode(["ref": JSONValue.string(name), "offset": .number(offset)])
        case let .shot(id, end): try c.encode(["shot": JSONValue.string(id), "edge": .string(end ? "end" : "start")])
        }
    }
    var isAnchor: Bool { if case .seconds = self { return false }; return true }
}

public enum ZoomFollow: String, Codable, Sendable { case cursor, fixed }

/// Media already inside the package (`media/<uuid>.<ext>`), probed once by the app and carried in `EditContext`
/// so a draft replays the same layer without touching the disk again.
public struct MediaAsset: Codable, Equatable, Sendable {
    public var file: String
    public var kind: LayerBlock.Kind
    public var duration: Double
    public var width: Double
    public var height: Double
    public var hasAudio: Bool
    public init(file: String, kind: LayerBlock.Kind, duration: Double = 0, width: Double, height: Double, hasAudio: Bool = false) {
        self.file = file; self.kind = kind; self.duration = duration; self.width = width; self.height = height; self.hasAudio = hasAudio
    }
}

/// Where a `layer` op gets its media. Only `.asset` reaches Core; the app turns `.path` (a trusted local file) and
/// `.recording` (a library recording's screen video) into an imported `.asset` before the op is applied or stored.
public enum LayerSource: Equatable, Sendable {
    case asset(String), path(String), recording(String)
}

/// Fields of the generic `set` op (EDITING-CORE D4): every field is optional; which ones an item accepts comes from its kind.
public struct SetFields: Codable, Equatable, Sendable {
    public var from: EditTime?, to: EditTime?
    public var mediaStart: Double?, mediaRate: Double?
    public var text: String?, color: BlockColor?
    public var position: NormPoint?, size: Double?, scale: Double?, center: NormPoint?, follow: ZoomFollow?, ease: ZoomEase?
    public var kind: Mask.Kind?
    public init(from: EditTime? = nil, to: EditTime? = nil, text: String? = nil, position: NormPoint? = nil, size: Double? = nil, scale: Double? = nil,
                center: NormPoint? = nil, follow: ZoomFollow? = nil, ease: ZoomEase? = nil, color: BlockColor? = nil,
                mediaStart: Double? = nil, mediaRate: Double? = nil, kind: Mask.Kind? = nil) {
        self.from = from; self.to = to; self.mediaStart = mediaStart; self.mediaRate = mediaRate; self.text = text; self.color = color
        self.position = position; self.size = size; self.scale = scale; self.center = center; self.follow = follow; self.ease = ease; self.kind = kind
    }
    public static let layerFields = ["from", "to", "mediaStart", "mediaRate", "color"]
    /// Names of the fields this patch sets (checked against `editableFields(kind)`).
    public var given: [String] {
        let all: [(String, Any?)] = [("from", from), ("to", to), ("mediaStart", mediaStart), ("mediaRate", mediaRate), ("text", text), ("color", color),
                                     ("position", position), ("size", size), ("scale", scale), ("center", center), ("follow", follow), ("ease", ease), ("kind", kind)]
        return all.compactMap { $0.1 == nil ? nil : $0.0 }
    }
}

public enum EditOp: Codable, Equatable, Sendable {
    case cut(from: EditTime, to: EditTime, snap: Bool = false)
    case cutPauses(minDuration: Double, keepTail: Double, from: EditTime?, to: EditTime?, snap: Bool = true)
    case cutWords(transcript: String, words: [String], snap: Bool = false)
    case speed(from: EditTime, to: EditTime, speed: Double, snap: Bool = false)
    case zoom(from: EditTime, to: EditTime, scale: Double, center: NormPoint?, follow: ZoomFollow? = nil, ease: ZoomEase? = nil)
    case text(from: EditTime, to: EditTime, style: TextBlock.Style, text: String, position: NormPoint?, size: Double?, color: BlockColor? = nil)
    case captions(maxWords: Int)
    case highlight(from: EditTime, to: EditTime, rect: NormRect, opacity: Double?)
    case marker(at: EditTime, label: String)
    case remove(id: String)
    /// The one patch op (EDITING-CORE D4): fields per item kind come from `editableFields`. Layers: from/to (output s),
    /// mediaStart (slip), mediaRate (speed), color.
    case set(id: String, fields: SetFields)
    case style(patch: [String: JSONValue])
    case layer(from: EditTime, to: EditTime?, source: LayerSource, rect: NormRect?)
    /// T-831. `keys` is `reframePlan`'s result; the app fills it from the storyboard before the op is stored (like `layer` media), so replay is self-contained.
    case reframe(aspect: Output.Aspect, mode: ReframeMode = .perShot, keys: [CropKey]? = nil)
    /// Motion graphic (T-925): a template (short, valid) or raw elements (escape hatch); a graphic layer on the output clock.
    case graphic(from: EditTime, to: EditTime, template: GraphicTemplate?, elements: [GraphicElement]?, space: Graphic.Space?, anchor: NormPoint?, rect: NormRect?, keys: [Key]?)
    /// Replace an item's keyframes (layer, graphic or text); [] clears them.
    case animate(id: String, keys: [Key])
    /// Hold the frame at `at` for `duration` s, pushing later footage back (T-933). The app renders the frame into `file`
    /// (a media/ PNG) before applying, so the stored op replays without rendering.
    case freeze(at: EditTime, duration: Double, file: String?)
    /// Transition at the clip seam nearest `at` (T-934); for a dissolve the app renders the outgoing frame into `file`.
    case transition(at: EditTime, kind: SeamTransition, duration: Double, file: String?)

    private enum CodingKeys: String, CodingKey {
        case op, from, to, minDuration, keepTail, transcript, words, speed, scale, center, style, text, position, size, maxWords, rect, opacity, at, label, id, patch, snap, follow, ease, color, asset, path, recording, aspect, mode, keys, template, elements, space, anchor, duration, file, kind
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ key: CodingKeys) throws -> T { try c.decode(T.self, forKey: key) }
        func optional<T: Decodable>(_ key: CodingKeys) throws -> T? { try c.decodeIfPresent(T.self, forKey: key) }
        switch try c.decode(String.self, forKey: .op) {
        case "cut": self = try .cut(from: get(.from), to: get(.to), snap: optional(.snap) ?? false)
        case "cutPauses": self = try .cutPauses(minDuration: optional(.minDuration) ?? 0.6, keepTail: optional(.keepTail) ?? 0.12, from: optional(.from), to: optional(.to), snap: optional(.snap) ?? true)
        case "cutWords": self = try .cutWords(transcript: get(.transcript), words: get(.words), snap: optional(.snap) ?? false)
        case "speed": self = try .speed(from: get(.from), to: get(.to), speed: get(.speed), snap: optional(.snap) ?? false)
        case "zoom": self = try .zoom(from: get(.from), to: get(.to), scale: get(.scale), center: optional(.center), follow: optional(.follow), ease: optional(.ease))
        case "text": self = try .text(from: get(.from), to: get(.to), style: get(.style), text: get(.text), position: optional(.position), size: optional(.size), color: optional(.color))
        case "captions": self = try .captions(maxWords: optional(.maxWords) ?? 4)
        case "highlight": self = try .highlight(from: get(.from), to: get(.to), rect: get(.rect), opacity: optional(.opacity))
        case "marker": self = try .marker(at: get(.at), label: get(.label))
        case "remove": self = try .remove(id: get(.id))
        case "set": self = try .set(id: get(.id), fields: SetFields(from: decoder))
        case "style": self = try .style(patch: get(.patch))
        case "layer":
            let sources: [(CodingKeys, (String) -> LayerSource)] = [(.asset, { .asset($0) }), (.path, { .path($0) }), (.recording, { .recording($0) })]
            let given = try sources.compactMap { key, make in try optional(key).map { (value: String) in make(value) } }
            guard given.count == 1 else {
                throw DecodingError.dataCorruptedError(forKey: .op, in: c, debugDescription: "layer needs exactly one of asset, path or recording")
            }
            self = try .layer(from: get(.from), to: optional(.to), source: given[0], rect: optional(.rect))
        case "reframe": self = try .reframe(aspect: get(.aspect), mode: optional(.mode) ?? .perShot, keys: optional(.keys))
        case "graphic": self = try .graphic(from: get(.from), to: get(.to), template: optional(.template), elements: optional(.elements), space: optional(.space), anchor: optional(.anchor), rect: optional(.rect), keys: optional(.keys))
        case "animate": self = try .animate(id: get(.id), keys: get(.keys))
        case "freeze": self = try .freeze(at: get(.at), duration: get(.duration), file: optional(.file))
        case "transition": self = try .transition(at: get(.at), kind: get(.kind), duration: optional(.duration) ?? 0.5, file: optional(.file))
        default: throw DecodingError.dataCorruptedError(forKey: .op, in: c, debugDescription: "Unknown edit op; use an op from edit.apply's schema")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        func put<T: Encodable>(_ value: T, _ key: CodingKeys) throws { try c.encode(value, forKey: key) }
        func optional<T: Encodable>(_ value: T?, _ key: CodingKeys) throws { try c.encodeIfPresent(value, forKey: key) }
        func range(_ name: String, _ from: EditTime, _ to: EditTime) throws {
            try put(name, .op); try put(from, .from); try put(to, .to)
        }
        switch self {
        case let .cut(from, to, snap): try range("cut", from, to); try put(snap, .snap)
        case let .cutPauses(minDuration, keepTail, from, to, snap):
            try put("cutPauses", .op); try put(minDuration, .minDuration); try put(keepTail, .keepTail)
            try optional(from, .from); try optional(to, .to); try put(snap, .snap)
        case let .cutWords(transcript, words, snap): try put("cutWords", .op); try put(transcript, .transcript); try put(words, .words); try put(snap, .snap)
        case let .speed(from, to, speed, snap): try range("speed", from, to); try put(speed, .speed); try put(snap, .snap)
        case let .zoom(from, to, scale, center, follow, ease): try range("zoom", from, to); try put(scale, .scale); try optional(center, .center); try optional(follow, .follow); try optional(ease, .ease)
        case let .text(from, to, style, text, position, size, color):
            try range("text", from, to); try put(style, .style); try put(text, .text); try optional(position, .position); try optional(size, .size); try optional(color, .color)
        case let .captions(maxWords): try put("captions", .op); try put(maxWords, .maxWords)
        case let .highlight(from, to, rect, opacity): try range("highlight", from, to); try put(rect, .rect); try optional(opacity, .opacity)
        case let .marker(at, label): try put("marker", .op); try put(at, .at); try put(label, .label)
        case let .remove(id): try put("remove", .op); try put(id, .id)
        case let .set(id, fields): try put("set", .op); try put(id, .id); try fields.encode(to: encoder)
        case let .style(patch): try put("style", .op); try put(patch, .patch)
        case let .reframe(aspect, mode, keys): try put("reframe", .op); try put(aspect, .aspect); try put(mode, .mode); try optional(keys, .keys)
        case let .graphic(from, to, template, elements, space, anchor, rect, keys):
            try range("graphic", from, to); try optional(template, .template); try optional(elements, .elements); try optional(space, .space)
            try optional(anchor, .anchor); try optional(rect, .rect); try optional(keys, .keys)
        case let .animate(id, keys): try put("animate", .op); try put(id, .id); try put(keys, .keys)
        case let .freeze(at, duration, file): try put("freeze", .op); try put(at, .at); try put(duration, .duration); try optional(file, .file)
        case let .transition(at, kind, duration, file): try put("transition", .op); try put(at, .at); try put(kind, .kind); try put(duration, .duration); try optional(file, .file)
        case let .layer(from, to, source, rect):
            try put("layer", .op); try put(from, .from); try optional(to, .to); try optional(rect, .rect)
            switch source {
            case .asset(let value): try put(value, .asset)
            case .path(let value): try put(value, .path)
            case .recording(let value): try put(value, .recording)
            }
        }
    }
    /// The first numeric time of the op (output seconds), for locating where an error happened.
    public var startSeconds: Double? {
        let time: EditTime?
        switch self {
        case let .cut(from, _, _), let .speed(from, _, _, _), let .zoom(from, _, _, _, _, _), let .text(from, _, _, _, _, _, _),
             let .highlight(from, _, _, _), let .layer(from, _, _, _), let .graphic(from, _, _, _, _, _, _, _): time = from
        case let .marker(at, _), let .freeze(at, _, _), let .transition(at, _, _, _): time = at
        case let .cutPauses(_, _, from, _, _): time = from
        case let .set(_, fields): time = fields.from
        default: time = nil
        }
        if case .seconds(let value)? = time { return value }
        return nil
    }
    var snapsClipBoundaries: Bool {
        switch self {
        case let .cut(_, _, snap), let .cutPauses(_, _, _, _, snap), let .cutWords(_, _, snap), let .speed(_, _, _, snap): return snap
        default: return false
        }
    }
}

public struct EditContext: Codable, Sendable {
    // Codable covers what a persisted draft needs to replay (silent/assets/refs); words come from the live transcript.
    private enum CodingKeys: String, CodingKey { case silent, assets, refs }
    public var words: [Word] = []
    public var silent: [TimeRange] = []
    public var operationSeeds: [String] = []
    /// Probed media files keyed by package-relative path; `layer` ops may only name files listed here.
    public var assets: [String: MediaAsset] = [:]
    /// `ref` name → index of the op in this call that declares it; `{ref: name}` anchors resolve to that op's start.
    public var refs: [String: Int] = [:]
    /// Source time of a shot's start/end edge (`{shot:"s07", edge}`); nil → "unknown shot". The shot-analysis task sets this.
    public var shotTime: (@Sendable (String, Bool) -> Double?)? = nil
    public init(words: [Word] = [], silent: [TimeRange] = [], operationSeeds: [String] = [], assets: [String: MediaAsset] = [:]) {
        self.words = words; self.silent = silent; self.operationSeeds = operationSeeds; self.assets = assets
    }
}
public struct EditChange: Codable, Equatable, Sendable {
    public var op: Int
    public var summary: String
    public var at: Double
    public var delta: Double
    public var note: String? = nil
    public var skipped = false
    public var sourceAt: Double? = nil
}
public enum EditError: Error, Equatable, CustomStringConvertible {
    case invalidOp(index: Int, reason: String), outOfRange(index: Int, reason: String), transcriptChanged, invariant(String)
    /// The op the error is about, when it names one.
    public var opIndex: Int? {
        switch self { case let .invalidOp(index, _), let .outOfRange(index, _): return index; default: return nil }
    }
    public var description: String {
        switch self {
        case let .invalidOp(index, reason): return "INVALID_OP: op \(index): \(reason); revise the op and retry"
        case let .outOfRange(index, reason): return "OUT_OF_RANGE: op \(index): \(reason); call timeline.get for valid times"
        case .transcriptChanged: return "TRANSCRIPT_CHANGED: call transcript.get for the current transcript and word ids"
        case .invariant(let reason): return "INVARIANT: \(reason); revise the ops and retry"
        }
    }
}

/// Every block `timeline.get` emits as (id, source start, source end, isMarker). Layers store their length in output
/// seconds, so their end is where that length lands on the current clock.
private func editBlocks(_ p: Project) -> [(String, Double, Double, Bool)] {
    let map = TimeMap(p.clips)
    return p.zooms.map { ($0.id, $0.start, $0.end, false) } + p.texts.map { ($0.id, $0.start, $0.end, false) } + p.masks.map { ($0.id, $0.start, $0.end, false) }
        + p.layouts.map { ($0.id, $0.start, $0.end, false) } + p.keystrokeClips.map { ($0.id, $0.start, $0.end, false) }
        + p.cameraClips.map { ($0.id, $0.start, $0.end, false) } + p.windowShots.map { ($0.id, $0.start, $0.end, false) }
        + p.audioClips.map { ($0.id, $0.start, $0.end, false) }
        + p.layers.map { ($0.id, $0.start, map.sourceTime(atOutput: (map.outputTime(atSource: $0.start) ?? 0) + $0.end - $0.start), false) }
        + p.markers.map { ($0.id, $0.time, $0.time, true) }
}

public extension Project {
    /// R7: the op corrected for a time outside the timeline or too close to a clip edge (snapped to the edge). Only for
    /// range errors, and only when the corrected op is non-empty and applies on its own; otherwise nil.
    func suggestedFix(for error: EditError, ops: [EditOp]) -> EditOp? {
        guard let index = error.opIndex, ops.indices.contains(index) else { return nil }
        switch error {
        case .outOfRange: break
        case .invalidOp(_, let reason): guard reason.contains("clip edge") else { return nil }
        default: return nil
        }
        let duration = TimeMap(clips).outputDuration
        var edges = [0.0], offset = 0.0
        for clip in clips { offset += clip.outputDuration; edges.append(offset) }
        func fit(_ time: EditTime) -> EditTime {
            guard case .seconds(let value) = time, value.isFinite else { return time }
            let clamped = min(duration, max(0, value))
            let edge = edges.min { abs($0 - clamped) < abs($1 - clamped) } ?? clamped
            return .seconds(abs(edge - clamped) < 0.1 ? edge : clamped)
        }
        let fixed: EditOp
        switch ops[index] {
        case let .cut(from, to, _): fixed = .cut(from: fit(from), to: fit(to), snap: true)
        case let .speed(from, to, speed, _): fixed = .speed(from: fit(from), to: fit(to), speed: speed, snap: true)
        case let .zoom(from, to, scale, center, follow, ease): fixed = .zoom(from: fit(from), to: fit(to), scale: scale, center: center, follow: follow, ease: ease)
        default: return nil
        }
        guard fixed != ops[index], (try? applying([fixed], context: EditContext())) != nil else { return nil }
        return fixed
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

private func snappedEditRanges(_ ranges: [TimeRange], clips: [Clip]) -> [TimeRange] {
    mergedEditRanges(ranges.flatMap { range in
        clips.filter { !$0.isEmpty }.compactMap { clip -> TimeRange? in
            var start = max(range.start, clip.sourceStart), end = min(range.end, clip.sourceEnd)
            guard end > start else { return nil }
            let margin = max(0.1 * clip.timeScale / clip.speed, 2 / 60.0 * clip.timeScale)
            func boundary(_ time: Double) -> Double {
                let left = time - clip.sourceStart, right = clip.sourceEnd - time
                guard min(left, right) < margin else { return time }
                return left <= right ? clip.sourceStart : clip.sourceEnd
            }
            start = boundary(start); end = boundary(end)
            let wholeClip = start == clip.sourceStart && end == clip.sourceEnd
            guard end > start, (end - start) * clip.speed / clip.timeScale >= 0.1 - 1e-9,
                  wholeClip || (end - start) / clip.timeScale >= 2 / 60.0 else { return nil }
            return TimeRange(start: start, end: end)
        }
    })
}

private func snappingNote(_ before: [TimeRange], _ after: [TimeRange]) -> String? {
    guard before != after else { return nil }
    guard !after.isEmpty else { return "Snapping left no editable range of the minimum length." }
    func times(_ ranges: [TimeRange]) -> String {
        ranges.map { String(format: "%.3f–%.3f", $0.start, $0.end) }.joined(separator: ", ")
    }
    return "Snapped source ranges \(times(before)) → \(times(after)) s."
}

private typealias PreparedEdit = (op: EditOp, ranges: [TimeRange], at: Double, note: String?, sourceAt: Double?)

public extension Project {
    /// Resolves every output range against the base project before applying any changes.
    func applying(_ ops: [EditOp], context: EditContext) throws -> (project: Project, changes: [EditChange]) {
        guard context.operationSeeds.isEmpty || context.operationSeeds.count == ops.count else {
            throw EditError.invalidOp(index: 0, reason: "one replay seed is required per op")
        }
        if let error = checkInvariants() { throw EditError.invariant(error) }
        let baseMap = TimeMap(clips)
        let duration = baseMap.outputDuration
        func numericRanges(_ from: Double, _ to: Double, index: Int, recordedOnly: Bool = false, snap: Bool = false, gaps: Bool = false) throws -> [TimeRange] {
            guard from.isFinite, to.isFinite, to > from, snap || (from >= 0 && to <= duration) else {
                throw EditError.outOfRange(index: index, reason: "expected 0 ≤ from < to ≤ \(duration)")
            }
            let from = max(0, from), to = min(duration, to)
            var offset = 0.0
            return clips.compactMap { clip in
                defer { offset += clip.outputDuration }
                let lo = max(from, offset), hi = min(to, offset + clip.outputDuration)
                guard hi > lo, gaps || !clip.isEmpty, !recordedOnly || clip.file == nil else { return nil }
                return TimeRange(start: clip.sourceStart + (lo - offset) * clip.timeScale,
                                 end: clip.sourceStart + (hi - offset) * clip.timeScale)
            }
        }
        var context = context
        var prepared: [PreparedEdit] = []
        var refTimes: [String: Double] = [:]
        // `set` validates its fields against the item's kind (one table, `editableFields`), then non-layer items run the
        // patch path below; ids created earlier in the batch skip the table check and get its per-kind validation (T-912).
        let kinds = Dictionary(items(self).map { ($0.id, $0.kind) } + markers.map { ($0.id, .marker) }, uniquingKeysWith: { a, _ in a })
        for (index, op) in ops.enumerated() {
            guard case let .set(id, fields) = op, let kind = kinds[id] else { continue }
            let valid = editableFields(kind)
            if let bad = fields.given.first(where: { !valid.contains($0) }) {
                throw EditError.invalidOp(index: index, reason: valid.isEmpty ? "\(kind.rawValue) \(id) has no settable fields; remove it with edit.remove"
                                                                               : "\(kind.rawValue) does not take \(bad); valid: \(valid.joined(separator: ", "))")
            }
        }
        for (index, op) in ops.enumerated() {
            var resolved: [TimeRange] = [], at = 0.0, note: String?, sourceAt: Double?
            var current: Project?
            func prefix() throws -> Project {
                if let current { return current }
                if context.operationSeeds.isEmpty { context.operationSeeds = ops.map { _ in UUID().uuidString } }
                let project = try applyingPrepared(prepared, context: context).project
                current = project
                return project
            }
            func coordinate(_ time: EditTime) throws -> (source: Double, output: Double) {
                switch time {
                case .seconds(let value):
                    guard value.isFinite, op.snapsClipBoundaries || (value >= 0 && value <= duration) else {
                        throw EditError.outOfRange(index: index, reason: "numeric time must be inside the base timeline")
                    }
                    let bounded = min(duration, max(0, value))
                    return (baseMap.sourceTime(atOutput: bounded), bounded)
                default:
                    let project = try prefix(), map = TimeMap(project.clips)
                    var id = "", offset = 0.0, found: Double?
                    switch time {
                    case let .marker(key, delta):
                        id = key; offset = delta
                        let byID = project.markers.filter { $0.id == key }
                        let hits = byID.isEmpty ? project.markers.filter { $0.label == key } : byID
                        guard hits.count <= 1 else { throw EditError.invalidOp(index: index, reason: "marker label \(key) matches \(hits.count) markers; use an id from timeline.get") }
                        found = hits.first?.time
                    case let .ref(key, delta): id = key; offset = delta; found = refTimes[key]
                    case let .shot(key, end):
                        // Shot times are base-spine seconds; an earlier op may have moved the spine to the output clock,
                        // so go through media time (never changes) into the prefix's spine (T-902, EDITING-CORE D2).
                        id = key
                        let recorded = { (c: Clip) in !c.isEmpty && c.file == nil }
                        found = context.shotTime?(key, end).flatMap { base in
                            clips.first { recorded($0) && base >= $0.sourceStart - 1e-9 && base <= $0.sourceEnd + 1e-9 }.map { $0.mediaTime(atSource: base) }
                        }.flatMap { media in
                            project.clips.first { recorded($0) && media >= $0.mediaIn - 1e-9 && media <= $0.mediaEnd + 1e-9 }.map { $0.sourceTime(atMedia: media) }
                        }
                    case .seconds: break
                    }
                    guard offset.isFinite, let found else {
                        throw EditError.invalidOp(index: index, reason: "unknown anchor \(id): no such marker, earlier ref or shot, or invalid offset")
                    }
                    guard let position = map.outputTime(atSource: found) else {
                        throw EditError.outOfRange(index: index, reason: "anchor \(id) is in removed footage")
                    }
                    let output = position + offset
                    guard output.isFinite, output >= 0, output <= map.outputDuration else {
                        throw EditError.outOfRange(index: index, reason: "marker offset is outside the current timeline")
                    }
                    let source = map.sourceTime(atOutput: output)
                    return (source, baseMap.outputTime(atSource: source) ?? duration)
                }
            }
            func ranges(_ from: EditTime, _ to: EditTime, recordedOnly: Bool = false) throws -> [TimeRange] {
                // A cut also removes empty timeline (gap clips): background-only spans must be cuttable (T-904).
                var gaps = false
                if case .cut(_, _, false) = op { gaps = true }
                if case .seconds(let from) = from, case .seconds(let to) = to {
                    return try numericRanges(from, to, index: index, recordedOnly: recordedOnly, snap: op.snapsClipBoundaries, gaps: gaps)
                }
                let start = try coordinate(from).source, end = try coordinate(to).source
                guard end > start else { throw EditError.outOfRange(index: index, reason: "anchor range must have from < to") }
                return try prefix().clips.compactMap { clip in
                    let lo = max(start, clip.sourceStart), hi = min(end, clip.sourceEnd)
                    guard hi > lo, gaps || !clip.isEmpty, !recordedOnly || clip.file == nil else { return nil }
                    return TimeRange(start: lo, end: hi)
                }
            }
            func block(_ id: String, current: Bool = false) throws -> (String, Double, Double, Bool)? {
                if !current, let block = editBlocks(self).first(where: { $0.0 == id }) { return block }
                return editBlocks(try prefix()).first { $0.0 == id }
            }
            switch op {
            case let .graphic(from, to, _, _, _, _, _, _):
                // Connected item: keep both ends as base spine points; apply maps them to the current output clock.
                let a = try coordinate(from), b = try coordinate(to)
                guard b.output > a.output else { throw EditError.outOfRange(index: index, reason: "graphic needs from < to") }
                at = a.output; resolved = [TimeRange(start: a.source, end: b.source)]
                if from.isAnchor || to.isAnchor { sourceAt = a.source }
            case let .animate(id, _):
                guard let block = try block(id) else { throw EditError.invalidOp(index: index, reason: "unknown item \(id)") }
                at = baseMap.outputTime(atSource: block.1) ?? 0
            case let .cut(from, to, _), let .speed(from, to, _, _), let .zoom(from, to, _, _, _, _), let .text(from, to, _, _, _, _, _), let .highlight(from, to, _, _):
                resolved = try ranges(from, to); at = try coordinate(from).output
                if from.isAnchor || to.isAnchor { sourceAt = try coordinate(from).source }
                if case .seconds(let from) = from, case .seconds(let to) = to, op.snapsClipBoundaries, from < 0 || to > duration { note = "Clamped output range to 0–\(duration) s." }
                guard !resolved.isEmpty || op.snapsClipBoundaries else { throw EditError.invalidOp(index: index, reason: "range contains only gaps") }
            case let .cutPauses(minimum, tail, from, to, snap):
                guard minimum.isFinite, minimum >= 0, tail.isFinite, tail >= 0 else {
                    throw EditError.invalidOp(index: index, reason: "minDuration and keepTail must be finite and nonnegative")
                }
                let bounds = try ranges(from ?? 0, to ?? .seconds(duration), recordedOnly: true)
                if case .seconds(let from) = from ?? 0, case .seconds(let to) = to ?? .seconds(duration), snap, from < 0 || to > duration { note = "Clamped output range to 0–\(duration) s." }
                let pauses = context.silent.filter { $0.start.isFinite && $0.end.isFinite && $0.end - $0.start >= minimum && $0.end - $0.start > 2 * tail + 0.05 }
                    .map { TimeRange(start: $0.start + tail, end: $0.end - tail) }
                let pauseMap = from?.isAnchor == true || to?.isAnchor == true ? TimeMap(try prefix().clips) : baseMap
                resolved = pauseMap.sourceRanges(forMedia: pauses).flatMap { pause in
                    bounds.compactMap { bound in
                        let lo = max(bound.start, pause.start), hi = min(bound.end, pause.end)
                        return hi > lo ? TimeRange(start: lo, end: hi) : nil
                    }
                }
                if let first = resolved.first, let output = baseMap.outputTime(atSource: first.start) { at = output } else { at = try coordinate(from ?? 0).output }
                if from?.isAnchor == true || to?.isAnchor == true { sourceAt = resolved.first?.start }
            case let .cutWords(transcript, ids, _):
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
            case let .set(id, _) where kinds[id] == .clip:
                guard let i = Int(id.dropFirst()), clips.indices.contains(i) else { throw EditError.invalidOp(index: index, reason: "unknown clip \(id)") }
                at = baseMap.outputTime(atSource: clips[i].sourceStart) ?? 0
            case let .set(id, fields) where !layers.contains(where: { $0.id == id }):
                let (from, to) = (fields.from, fields.to)
                let anchored = from?.isAnchor == true || to?.isAnchor == true
                let block = try block(id, current: anchored)
                guard let block else { throw EditError.invalidOp(index: index, reason: "unknown block \(id)") }
                at = try from.map { try coordinate($0).output } ?? baseMap.outputTime(atSource: block.1) ?? 0
                if anchored { sourceAt = try from.map { try coordinate($0).source } ?? block.1 }
                if block.3 {
                    if let from {
                        let source = try coordinate(from).source
                        resolved = [TimeRange(start: source, end: source)]
                    }
                    break
                }
                if from != nil || to != nil {
                    if anchored {
                        let start = try from.map { try coordinate($0).source } ?? block.1
                        let end = try to.map { try coordinate($0).source } ?? block.2
                        guard end - start >= 0.5 else { throw EditError.invalidOp(index: index, reason: "block needs at least 0.5 source seconds") }
                        resolved = [TimeRange(start: start, end: end)]
                        break
                    }
                    let mapped = try ranges(.seconds(at), to ?? .seconds(baseMap.outputTime(atSource: block.2) ?? duration))
                    guard let first = mapped.first, let last = mapped.last else { throw EditError.invalidOp(index: index, reason: "range contains only gaps") }
                    resolved = [TimeRange(start: from == nil ? block.1 : first.start, end: to == nil ? block.2 : last.end)]
                }
            case let .freeze(time, _, _), let .transition(time, _, _, _):
                let point = try coordinate(time)
                at = point.output; resolved = [TimeRange(start: point.source, end: point.source)]
                if time.isAnchor { sourceAt = point.source }
            case let .marker(time, _):
                let point = try coordinate(time)
                at = point.output; resolved = [TimeRange(start: point.source, end: point.source)]
                if time.isAnchor { sourceAt = point.source }
            case .remove(let id):
                guard let block = try block(id) else { throw EditError.invalidOp(index: index, reason: "unknown block \(id)") }
                at = baseMap.outputTime(atSource: block.1) ?? 0
            case let .layer(from, to, source, _):
                guard case .asset(let file) = source, let asset = context.assets[file] else {
                    throw EditError.invalidOp(index: index, reason: "layer media is not imported; pass asset from project.assets, or a path/recording through edit.apply")
                }
                let start = try coordinate(from)
                at = start.output
                if from.isAnchor { sourceAt = start.source }
                if asset.kind == .video {
                    guard to == nil else { throw EditError.invalidOp(index: index, reason: "video layers play their whole clip; omit to") }
                    resolved = [TimeRange(start: start.source, end: start.source)]
                } else {
                    guard let to else { throw EditError.invalidOp(index: index, reason: "image layers need to") }
                    let end = try coordinate(to)
                    guard end.source > start.source else { throw EditError.outOfRange(index: index, reason: "layer range must have from < to") }
                    resolved = [TimeRange(start: start.source, end: end.source)]
                }
            case let .set(id, fields):
                guard let layer = layers.first(where: { $0.id == id }) else {
                    throw EditError.invalidOp(index: index, reason: "unknown layer \(id): mediaStart/mediaRate apply to layers from timeline.get")
                }
                guard [fields.from, fields.to].allSatisfy({ $0 == nil || !$0!.isAnchor }) else {
                    throw EditError.invalidOp(index: index, reason: "layer set takes numeric from/to (output seconds)")
                }
                if case .seconds(let value)? = fields.from { at = value } else { at = baseMap.outputTime(atSource: layer.start) ?? 0 }
            case .captions, .style, .reframe: break
            }
            let merged = mergedEditRanges(resolved)
            if let name = context.refs.first(where: { $0.value == index })?.key, let start = merged.first?.start { refTimes[name] = start }
            prepared.append((op, merged, at, note, sourceAt))
        }
        return try applyingPrepared(prepared, context: context)
    }

    private func applyingPrepared(_ prepared: [PreparedEdit], context: EditContext) throws -> (project: Project, changes: [EditChange]) {
        let baseMap = TimeMap(clips)
        let kinds = Dictionary(items(self).map { ($0.id, $0.kind) }, uniquingKeysWith: { a, _ in a })   // base ids, as `set` resolved them
        func point(_ point: NormPoint?, index: Int) throws {
            if let point, !point.x.isFinite || !point.y.isFinite || !(0...1).contains(point.x) || !(0...1).contains(point.y) {
                throw EditError.invalidOp(index: index, reason: "position/center must be normalized 0–1 (zoom center: source frame, origin top-left)")
            }
        }
        func textSize(_ value: Double?, index: Int) throws {
            if let value, !(16...120).contains(value) { throw EditError.invalidOp(index: index, reason: "text size must be 16–120 like the inspector slider") }
        }
        func positive(_ value: Double?, index: Int) throws {
            if let value, !value.isFinite || value <= 0 { throw EditError.invalidOp(index: index, reason: "size/scale must be finite and positive") }
        }
        var result = self, changes: [EditChange] = []
        var cuts: [(index: Int, ranges: [TimeRange])] = []
        func stamp(_ time: Double) -> String { String(format: "%d:%04.1f", Int(time) / 60, time.truncatingRemainder(dividingBy: 60)) }
        for (index, item) in prepared.enumerated() {
            let seed = context.operationSeeds.isEmpty ? nil : context.operationSeeds[index]
            let change = try EditIDs.withSeed(seed) {
                let before = TimeMap(result.clips).outputDuration
                let span = item.ranges.first.map { TimeRange(start: $0.start, end: item.ranges.last!.end) }
                var summary: String
                var note = item.note, skipped = false
                switch item.op {
                case .cut, .cutPauses, .cutWords:
                    cuts.append((index, item.ranges))
                    let kind: String
                    switch item.op { case .cutPauses: kind = "Cut pause"; case .cutWords: kind = "Cut words"; default: kind = "Cut" }
                    summary = "\(kind) \(stamp(item.at))"
                case let .speed(_, _, speed, snap):
                    guard speed.isFinite, (0.25...16).contains(speed) else { throw EditError.invalidOp(index: index, reason: "speed must be 0.25–16") }
                    let speedRanges = snap ? snappedEditRanges(item.ranges, clips: result.clips) : item.ranges
                    if snap {
                        if let adjustment = snappingNote(item.ranges, speedRanges) { note = [note, adjustment].compactMap { $0 }.joined(separator: " ") }
                        skipped = speedRanges.isEmpty
                        if skipped { note = "Snapping left no editable range of the minimum length." }
                    }
                    for range in speedRanges.reversed() {
                        try result.agentSplit(range, index: index)
                        let indices = result.clips.indices.filter { !result.clips[$0].isEmpty && result.clips[$0].sourceStart >= range.start - 1e-9 && result.clips[$0].sourceEnd <= range.end + 1e-9 }
                        for i in indices.reversed() {
                            result.setSpeed(i, speed)
                            guard abs(result.clips[i].speed - speed) < 1e-9 else { throw EditError.invalidOp(index: index, reason: "speed cannot fit this clip; enable linked video edits") }
                        }
                    }
                    summary = "Speed \(speed)× \(stamp(item.at))"
                case let .zoom(_, _, scale, center, follow, ease):
                    try positive(scale, index: index); try point(center, index: index)
                    if follow == .cursor, center != nil { throw EditError.invalidOp(index: index, reason: "follow:\"cursor\" takes no center; omit it or use follow:\"fixed\"") }
                    guard scale >= 1, let span else { throw EditError.invalidOp(index: index, reason: "zoom scale must be at least 1") }
                    if let overlap = result.zooms.first(where: { $0.start < span.end && $0.end > span.start }) {
                        throw EditError.invalidOp(index: index, reason: "zoom overlaps \(overlap.id)")
                    }
                    guard span.end - span.start >= 0.5, let id = result.addZoom(atSource: span.start, length: span.end - span.start, mode: follow == .cursor || (follow == nil && center == nil) ? .auto : .manual),
                          let i = result.zooms.firstIndex(where: { $0.id == id.uuidString }) else { throw EditError.invalidOp(index: index, reason: "zoom needs at least 0.5 source seconds in a free lane") }
                    result.zooms[i].scale = scale
                    if let center { result.zooms[i].center = center }
                    result.zooms[i].ease = ease
                    summary = "Zoom \(scale)× \(stamp(item.at))"
                case let .text(_, _, style, text, position, size, color):
                    try point(position, index: index); try positive(size, index: index); try textSize(size, index: index)
                    guard let span, span.end - span.start >= 0.5, !result.texts.contains(where: { style.sharesLane(with: $0.style) && $0.start < span.end && $0.end > span.start }),
                          let id = result.addText(atSource: span.start, length: span.end - span.start, style: style, text: text),
                          let i = result.texts.firstIndex(where: { $0.id == id.uuidString }) else { throw EditError.invalidOp(index: index, reason: "text overlaps a block or is shorter than 0.5 source seconds") }
                    if let position { result.texts[i].position = position }
                    if let size { result.texts[i].size = size }
                    result.texts[i].color = color
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
                case let .layer(_, _, source, rect):
                    guard case .asset(let file) = source, let asset = context.assets[file], let span = item.ranges.first,
                          asset.kind != .recording, asset.width > 0, asset.height > 0, asset.width.isFinite, asset.height.isFinite else {
                        throw EditError.invalidOp(index: index, reason: "layer media is not imported")
                    }
                    if let rect, ![rect.x, rect.y, rect.w, rect.h].allSatisfy(\.isFinite) || rect.x < 0 || rect.y < 0 || rect.w <= 0 || rect.h <= 0 || rect.x + rect.w > 1 + 1e-9 || rect.y + rect.h > 1 + 1e-9 {
                        throw EditError.invalidOp(index: index, reason: "layer rect must be a normalized rectangle")
                    }
                    let map = TimeMap(result.clips)
                    guard let output = map.outputTime(atSource: span.start) else { throw EditError.outOfRange(index: index, reason: "layer start is in removed footage") }
                    let length: Double
                    if asset.kind == .video { length = asset.duration }
                    else if let end = map.outputTime(atSource: span.end) { length = end - output }
                    else { throw EditError.outOfRange(index: index, reason: "layer end is in removed footage") }
                    guard length >= 0.5, length.isFinite, asset.kind == .image || asset.duration >= 0.5 else {
                        throw EditError.invalidOp(index: index, reason: "layer needs at least 0.5 seconds")
                    }
                    guard result.addLayer(kind: asset.kind, file: file, atOutput: output, duration: length, rect: rect ?? NormRect(), hasAudio: asset.hasAudio) != nil else {
                        throw EditError.invalidOp(index: index, reason: "layer does not fit: it needs free layer lane time, at most four video lanes, and a video must end inside the timeline")
                    }
                    summary = "Add \(asset.kind.rawValue) layer \(stamp(item.at))"
                case let .marker(_, label):
                    result.markers.append(Marker(time: span?.start ?? baseMap.sourceTime(atOutput: item.at), label: label))
                    result.markers.sort { $0.time < $1.time }
                    summary = "Marker \(stamp(item.at))"
                case let .set(id, fields) where kinds[id] == .clip:
                    // Slip: base clip → the current clip showing the same footage (earlier ops may have split or moved it).
                    guard let i = Int(id.dropFirst()), let mediaStart = fields.mediaStart, clips.indices.contains(i),
                          let j = result.clips.firstIndex(where: { !$0.isEmpty && $0.file == clips[i].file && abs($0.mediaIn - clips[i].mediaIn) < 1e-9 }) else {
                        throw EditError.invalidOp(index: index, reason: "clip \(id) slip needs mediaStart and the clip's footage")
                    }
                    guard result.slipClip(j, byMedia: mediaStart - result.clips[j].mediaIn) || abs(mediaStart - result.clips[j].mediaIn) < 1e-9 else {
                        throw EditError.invalidOp(index: index, reason: String(format: "clip %@ cannot slip to %.2f s: the media must cover %.2f s and linked audio must lie inside the clip", id, mediaStart, result.clips[j].mediaDuration))
                    }
                    summary = "Slip clip \(stamp(item.at))"
                case let .set(id, fields) where !result.layers.contains(where: { $0.id == id }):
                    let (from, to, text, position, size, scale, center, follow, ease, color) =
                        (fields.from, fields.to, fields.text, fields.position, fields.size, fields.scale, fields.center, fields.follow, fields.ease, fields.color)
                    try point(position, index: index); try point(center, index: index); try positive(size, index: index); try positive(scale, index: index)
                    if let i = result.markers.firstIndex(where: { $0.id == id }) {
                        guard to == nil, position == nil, size == nil, scale == nil, center == nil, follow == nil, ease == nil, color == nil else {
                            throw EditError.invalidOp(index: index, reason: "marker takes from and text (label)")
                        }
                        if let span { result.markers[i].time = span.start }
                        if let text { result.markers[i].label = text }
                        result.markers.sort { $0.time < $1.time }
                        summary = "Set marker \(stamp(item.at))"
                        break
                    }
                    if let span, span.end - span.start < 0.5 { throw EditError.invalidOp(index: index, reason: "block needs at least 0.5 source seconds") }
                    if let i = result.zooms.firstIndex(where: { $0.id == id }) {
                        guard text == nil, position == nil, size == nil, scale == nil || scale! >= 1 else { throw EditError.invalidOp(index: index, reason: "zoom supports scale/center/follow/ease and times") }
                        if follow == .cursor, center != nil { throw EditError.invalidOp(index: index, reason: "follow:\"cursor\" takes no center; omit it or use follow:\"fixed\"") }
                        if follow == .cursor { result.zooms[i].mode = .auto }
                        if follow == .fixed { result.zooms[i].mode = .manual }
                        if let ease { result.zooms[i].ease = ease }
                        if let color { result.zooms[i].color = color }
                        if let span { result.zooms[i].start = span.start; result.zooms[i].end = span.end }
                        if let scale { result.zooms[i].scale = scale }
                        if let center { result.zooms[i].center = center; result.zooms[i].mode = .manual }
                        result.zooms.sort { $0.start < $1.start }
                    } else if let i = result.texts.firstIndex(where: { $0.id == id }) {
                        try textSize(size, index: index)
                        guard scale == nil, center == nil, follow == nil, ease == nil else { throw EditError.invalidOp(index: index, reason: "text supports text/position/size/color and times") }
                        if let span { result.texts[i].start = span.start; result.texts[i].end = span.end }
                        if let text { result.texts[i].setText(text) }
                        if let position { result.texts[i].position = position }
                        if let size { result.texts[i].size = size }
                        if let color { result.texts[i].color = color }
                        result.texts.sort { $0.start < $1.start }
                    } else if let i = result.masks.firstIndex(where: { $0.id == id }) {
                        guard text == nil, position == nil, size == nil, scale == nil, center == nil, follow == nil, ease == nil else { throw EditError.invalidOp(index: index, reason: "mask takes from, to, color, kind") }
                        if let color { result.masks[i].color = color }
                        if let kind = fields.kind { result.masks[i].kind = kind }   // mask / highlight / blur
                        if let span { result.masks[i].start = span.start; result.masks[i].end = span.end }
                        result.masks.sort { $0.start < $1.start }
                    } else if editBlocks(result).contains(where: { $0.0 == id }) {
                        throw EditError.invalidOp(index: index, reason: "set does not support block \(id) (timeline.get editable:false); remove it with edit.remove or change it in Recorder")
                    } else { throw EditError.invalidOp(index: index, reason: "unknown block \(id)") }
                    summary = "Set block \(stamp(item.at))"
                case let .set(id, fields):
                    guard fields.text == nil else {
                        throw EditError.invalidOp(index: index, reason: "layer set supports \(SetFields.layerFields.joined(separator: ", "))")
                    }
                    guard let i = result.layers.firstIndex(where: { $0.id == id }), let layerID = UUID(uuidString: id) else {
                        throw EditError.invalidOp(index: index, reason: "unknown layer \(id)")
                    }
                    let old = result.layers[i], rate = old.mediaRate ?? 1
                    let linked = result.audioClips.indices.filter { result.audioClips[$0].link == .layer && result.audioClips[$0].layer == id }
                    func limit(_ what: String) -> EditError {
                        .invalidOp(index: index, reason: "layer \(what) is blocked by the media length (\(old.kind == .recording ? String(format: "%.2f s", result.source.duration) : "file")), a neighbour on track \(old.track) or the minimum length")
                    }
                    if let newRate = fields.mediaRate {
                        // Speed: same start and media in-point, the output length follows (connected items store output length).
                        guard newRate.isFinite, (0.25...16).contains(newRate) else { throw EditError.invalidOp(index: index, reason: "mediaRate must be 0.25–16") }
                        let length = (old.end - old.start) * rate / newRate
                        result.layers[i].mediaRate = newRate == 1 && old.kind != .recording ? nil : newRate
                        result.layers[i].end = old.start + length
                        for a in linked { result.audioClips[a].mediaRate = newRate; result.audioClips[a].end = result.audioClips[a].start + length }
                        guard result.checkInvariants() == nil else { throw limit("mediaRate \(newRate)") }
                    }
                    if let mediaStart = fields.mediaStart {
                        // Slip: same position and length, other footage.
                        guard mediaStart.isFinite, mediaStart >= 0, old.hasMedia else { throw EditError.invalidOp(index: index, reason: "mediaStart must be ≥ 0 seconds on a video or recording layer") }
                        let known = old.kind == .recording ? result.source.duration : context.assets[old.file]?.duration
                        guard known.map({ mediaStart + (old.end - old.start) * rate <= $0 + 1e-9 }) ?? (mediaStart <= old.mediaStart) else { throw limit("mediaStart \(mediaStart)") }
                        let shift = mediaStart - result.layers[i].mediaStart
                        result.layers[i].mediaStart = mediaStart
                        for a in linked { result.audioClips[a].mediaStart += shift }
                        guard result.checkInvariants() == nil else { throw limit("mediaStart \(mediaStart)") }
                    }
                    if fields.from != nil || fields.to != nil {
                        // Base output seconds → current output; past the clips' end the tail keeps its offset.
                        let current = TimeMap(result.clips)
                        func output(_ time: EditTime?) -> Double? {
                            guard case .seconds(let t)? = time else { return nil }
                            if t <= baseMap.outputDuration { return current.outputTime(atSource: baseMap.sourceTime(atOutput: t)) }
                            return current.outputDuration + t - baseMap.outputDuration
                        }
                        let layer = result.layers[i]
                        guard let start = current.outputTime(atSource: layer.start) else { throw EditError.outOfRange(index: index, reason: "layer start is in removed footage") }
                        let want = (output(fields.from) ?? start, output(fields.to) ?? (output(fields.from).map { $0 + layer.end - layer.start } ?? start + layer.end - layer.start))
                        guard want.0 >= 0, want.1 > want.0 else { throw EditError.outOfRange(index: index, reason: "layer needs 0 ≤ from < to") }
                        if fields.to == nil {
                            result.moveLayer(layerID, toOutput: want.0)
                        } else {
                            for edge in want.0 >= start ? [Edge.trailing, .leading] : [.leading, .trailing] {
                                result.resizeLayer(layerID, edge: edge, toOutput: edge == .leading ? want.0 : want.1)
                            }
                        }
                        let now = result.layers.first { $0.id == id }.flatMap { l in TimeMap(result.clips).outputTime(atSource: l.start).map { ($0, $0 + l.end - l.start) } }
                        guard let now, abs(now.0 - want.0) < 1e-6, abs(now.1 - want.1) < 1e-6 else {
                            throw EditError.invalidOp(index: index, reason: String(format: "layer cannot span %.2f–%.2f s: ", want.0, want.1) + "a neighbour, the media length or the minimum length blocks it" + (now.map { String(format: " (reachable now: %.2f–%.2f s)", $0.0, $0.1) } ?? ""))
                        }
                    }
                    if let color = fields.color, let j = result.layers.firstIndex(where: { $0.id == id }) { result.layers[j].color = color }
                    summary = "Set layer \(stamp(item.at))"
                case let .graphic(_, _, template, elements, space, anchor, rect, keys):
                    let map = TimeMap(result.clips)
                    guard let span, let start = map.outputTime(atSource: span.start), let end = map.outputTime(atSource: span.end), end - start >= 0.5 else {
                        throw EditError.invalidOp(index: index, reason: "graphic needs at least 0.5 s of kept timeline")
                    }
                    var graphic: Graphic, box: NormRect
                    switch (template, elements) {
                    case let (template?, nil):
                        do { (graphic, box) = try GraphicTemplates.make(template.name, params: template.params, length: end - start) }
                        catch { throw EditError.invalidOp(index: index, reason: "\(error)") }
                    case let (nil, elements?):
                        graphic = Graphic(space: space ?? .canvas, elements: elements, anchor: anchor); box = NormRect()
                    default: throw EditError.invalidOp(index: index, reason: "graphic needs exactly one of template or elements (see project.templates)")
                    }
                    if let space { graphic.space = space }
                    if let anchor { graphic.anchor = anchor }
                    if let rect { box = rect }
                    if let problem = graphicError(graphic, length: end - start) { throw EditError.invalidOp(index: index, reason: "graphic \(problem)") }
                    if let keys, let problem = keysError(keys, length: end - start) { throw EditError.invalidOp(index: index, reason: "keys: \(problem)") }
                    var placed: UUID?
                    for track in 0..<8 where placed == nil { placed = result.addGraphic(graphic, atOutput: start, duration: end - start, rect: box, track: track) }
                    guard let id = placed else {
                        throw EditError.invalidOp(index: index, reason: "graphic does not fit: the box must lie inside the canvas and a free graphic lane is needed")
                    }
                    if let keys, !keys.isEmpty, let i = result.layers.firstIndex(where: { $0.id == id.uuidString }) { result.layers[i].keys = keys }
                    summary = "Add \(template?.name ?? "graphic") \(stamp(item.at))"
                case let .freeze(_, duration, file):
                    guard let file, file.hasPrefix("media/"), let span, let at = TimeMap(result.clips).outputTime(atSource: span.start) else {
                        throw EditError.invalidOp(index: index, reason: "freeze needs a rendered frame; use edit.apply (the app renders it)")
                    }
                    guard duration.isFinite, (0.5...10).contains(duration), result.insertStill(file: file, atOutput: at, duration: duration) else {
                        throw EditError.invalidOp(index: index, reason: "freeze duration must be 0.5–10 s at a point inside the footage")
                    }
                    summary = String(format: "Freeze %.1f s %@", duration, stamp(item.at))
                case let .transition(_, kind, duration, file):
                    guard let span, let at = TimeMap(result.clips).outputTime(atSource: span.start),
                          result.addTransition(kind, near: at, duration: duration, file: file) else {
                        throw EditError.invalidOp(index: index, reason: "transition needs a seam between two clips within 0.5 s of at, duration 0.1–3 s (dissolve ≥ 0.5 s) no longer than the next clip" + (kind == .dissolve && file == nil ? ", and a rendered frame (use edit.apply)" : ""))
                    }
                    summary = "\(kind == .dissolve ? "Dissolve" : "Dip") \(stamp(item.at))"
                case let .animate(id, keys):
                    let value: [Key]? = keys.isEmpty ? nil : keys
                    if let i = result.layers.firstIndex(where: { $0.id == id }) {
                        if let keys = value, let problem = keysError(keys, length: result.layers[i].end - result.layers[i].start) { throw EditError.invalidOp(index: index, reason: "keys: \(problem)") }
                        result.layers[i].keys = value
                    } else if let i = result.texts.firstIndex(where: { $0.id == id }) {
                        if let keys = value, let problem = keysError(keys, length: result.texts[i].end - result.texts[i].start) { throw EditError.invalidOp(index: index, reason: "keys: \(problem)") }
                        result.texts[i].keys = value
                    } else { throw EditError.invalidOp(index: index, reason: "animate works on layers, graphics and text; \(id) is none of them") }
                    summary = "Animate \(stamp(item.at))"
                case let .remove(id):
                    if result.markers.contains(where: { $0.id == id }) {
                        result.markers.removeAll { $0.id == id }
                        summary = "Remove marker"
                        break
                    }
                    guard editBlocks(result).contains(where: { $0.0 == id }) else { throw EditError.invalidOp(index: index, reason: "unknown block \(id)") }
                    result.removeBlock(id: id, propagate: false)   // only this block, never the linked clips or audio
                    guard !editBlocks(result).contains(where: { $0.0 == id }) else { throw EditError.invalidOp(index: index, reason: "block \(id) could not be removed") }
                    summary = "Remove block"
                case let .reframe(aspect, _, keys):
                    guard [.r4x5, .r1x1, .r9x16, .r16x9].contains(aspect) else { throw EditError.invalidOp(index: index, reason: "reframe aspect must be 4:5, 1:1, 9:16 or 16:9") }
                    guard let keys, !keys.isEmpty else { throw EditError.invalidOp(index: index, reason: "reframe needs a storyboard; run analyze.shots first") }
                    let sw = Double(result.source.pixelWidth), sh = Double(result.source.pixelHeight), eps = 1e-6
                    let sound = zip(keys, keys.dropFirst()).allSatisfy { $0.t <= $1.t } && keys.allSatisfy { k in
                        let r = k.rect
                        return [k.t, r.x, r.y, r.w, r.h].allSatisfy(\.isFinite) && k.t >= 0 && r.w > 0 && r.h > 0
                            && r.x >= -eps && r.y >= -eps && r.x + r.w <= 1 + eps && r.y + r.h <= 1 + eps
                            && (sw <= 0 || sh <= 0 || abs(r.w * sw / (r.h * sh) / aspect.ratio! - 1) < 1e-3)
                    }
                    guard sound else { throw EditError.invalidOp(index: index, reason: "reframe keys must be sorted, inside the frame and match the output aspect") }
                    result.output.aspect = aspect; result.cropKeys = keys
                    summary = "Reframe \(aspect.rawValue)"
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
                return EditChange(op: index, summary: summary, at: item.at, delta: TimeMap(result.clips).outputDuration - before, note: note, skipped: skipped, sourceAt: item.sourceAt)
            }
            changes.append(change)
        }
        // Remove the union once; overlapping cut ops must never remove the same footage twice.
        var removed: [TimeRange] = [], cutPreview = result
        for position in cuts.indices {
            var cut = cuts[position]
            if prepared[cut.index].op.snapsClipBoundaries {
                let snapped = snappedEditRanges(cut.ranges, clips: cutPreview.clips)
                if let adjustment = snappingNote(cut.ranges, snapped) {
                    changes[cut.index].note = [changes[cut.index].note, adjustment].compactMap { $0 }.joined(separator: " ")
                }
                cut.ranges = snapped
                var trial = cutPreview
                trial.agentRemoveSourceRanges(snapped, includeImported: true)
                let intended = snapped.reduce(0) { total, range in
                    total + cutPreview.clips.filter { !$0.isEmpty }.reduce(0) { sum, clip in
                        sum + max(0, min(range.end, clip.sourceEnd) - max(range.start, clip.sourceStart)) / clip.timeScale
                    }
                }
                if abs(TimeMap(cutPreview.clips).outputDuration - TimeMap(trial.clips).outputDuration - intended) > 1e-7 {
                    cut.ranges = []
                    changes[cut.index].note = "Snapping would remove all remaining media or leave an invalid split."
                }
                if cut.ranges.isEmpty {
                    changes[cut.index].skipped = true
                    if changes[cut.index].note?.isEmpty != false { changes[cut.index].note = "Snapping left no editable range of the minimum length." }
                }
            }
            cutPreview.agentRemoveSourceRanges(cut.ranges, includeImported: true)
            cuts[position] = cut
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
        let cutSeed = context.operationSeeds.isEmpty ? nil : cuts.map { context.operationSeeds[$0.index] }.joined(separator: "|") + ":cuts"
        EditIDs.withSeed(cutSeed) { result.agentRemoveSourceRanges(union, includeImported: true) }
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
            removeGapTime(range)
            if checkInvariants() != nil { self = before }
        }
    }

    /// Shortens gap clips by their overlap with `range` (a gap has no footage or effects, so only its length changes) and
    /// re-anchors connected items whose spine point disappeared, which ripples them earlier (T-904).
    private mutating func removeGapTime(_ range: TimeRange) {
        var changed = false
        for i in clips.indices.reversed() where clips[i].isEmpty && clips.count > 1 {
            let lo = max(range.start, clips[i].sourceStart), hi = min(range.end, clips[i].sourceEnd)
            guard hi - lo > 1e-9 else { continue }
            changed = true
            if hi - lo >= clips[i].sourceEnd - clips[i].sourceStart - 1e-9 { clips.remove(at: i) } else { clips[i].sourceEnd -= hi - lo }
        }
        if changed { settleConnected() }
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
