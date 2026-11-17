import Foundation

/// T-830: intent ops lowered to the existing `cut` / `speed` / `zoom` primitives. Everything is resolved against the
/// project the batch starts from (output seconds), exactly like hand-written ops, so the lowered batch goes through
/// one `applying` call and one undo step.
public struct LoweredIntent: Codable, Equatable, Sendable {
    public var op: Int               // index in the agent's batch
    public var intent: String
    public var ops: [JSONValue]      // primitives that replaced it
    public var dropped: [String]?    // fitDuration: shots removed whole
    public var note: String?
    public var shots: [ShotPick]?    // keepShots: every shot with its verdict, so a dry run shows a bad filter before it applies
}

public struct ShotPick: Codable, Equatable, Sendable {
    public var id: String, kind: ShotKind, energy: Double, kept: Bool
}

private extension JSONValue {
    subscript(key: String) -> JSONValue? { if case .object(let o) = self { return o[key] }; return nil }
    var num: Double? { if case .number(let v) = self { return v }; return nil }
    var strings: [String]? { if case .array(let a) = self { let s = a.compactMap { v -> String? in if case .string(let x) = v { return x }; return nil }; return s.count == a.count ? s : nil }; return nil }
}

/// `storyboard` is only called when an op needs shots (so autoZoom/ramp work without analysis).
/// `origin[i]` is the index in the agent's batch that produced `ops[i]`; use it to report errors and changes.
public func lowerIntents(_ ops: [JSONValue], project: Project, clicks: [InputEvent] = [],
                         storyboard: () throws -> Storyboard) throws -> (ops: [JSONValue], origin: [Int], lowered: [LoweredIntent]) {
    let map = TimeMap(project.clips), total = map.outputDuration
    var out: [JSONValue] = [], origin: [Int] = [], lowered: [LoweredIntent] = []
    // Each intent reads the batch-start timeline, so two that change the length would aim at stale times.
    let lengthChanging = ops.enumerated().filter { if case .string(let n)? = $1["op"] { return ["keepShots", "pace", "fitDuration"].contains(n) }; return false }
    if lengthChanging.count > 1 {
        throw EditError.invalidOp(index: lengthChanging[1].offset, reason: "only one of keepShots/pace/fitDuration per batch; call edit.apply once per intent")
    }
    let imported = { () -> [TimeRange] in var t = 0.0; return project.clips.compactMap { c in defer { t += c.outputDuration }; return c.file != nil ? TimeRange(start: t, end: t + c.outputDuration) : nil } }()
    var board: Storyboard?
    func sb() throws -> Storyboard { if let board { return board }; let b = try storyboard(); board = b; return b }
    func cutsAvoidingImported(_ a: Double, _ b: Double) -> [JSONValue] {   // imported clips are never deleted by an intent
        var pieces = [TimeRange(start: a, end: b)]
        for hole in imported {
            pieces = pieces.flatMap { p -> [TimeRange] in
                guard hole.end > p.start, hole.start < p.end else { return [p] }
                return [TimeRange(start: p.start, end: hole.start), TimeRange(start: hole.end, end: p.end)].filter { $0.end - $0.start > 0.05 }
            }
        }
        return pieces.map { cutJSON($0.start, $0.end) }
    }
    for (index, raw) in ops.enumerated() {
        func bad(_ reason: String) -> EditError { .invalidOp(index: index, reason: reason) }
        guard case .string(let name)? = raw["op"] else { out.append(raw); origin.append(index); continue }
        func number(_ key: String, _ fallback: Double, in v: JSONValue? = nil) throws -> Double {
            guard let field = (v ?? raw)[key] else { return fallback }
            guard let n = field.num, n.isFinite else { throw bad("\(key) must be a number") }
            return n
        }
        var result: [JSONValue] = [], dropped: [String]?, note: String?, picks: [ShotPick]?
        func up(_ v: Double) -> Double { (v * 100).rounded(.up) / 100 }
        /// `factor` is relative; the speed op sets absolute speed, so scale each piece by its clip's current speed.
        func speedUp(_ s: ShotSegment, _ from: Double, _ to: Double, _ factor: Double) {
            for piece in s.pieces {
                let lo = max(from, piece.range.start), hi = min(to, piece.range.end)
                if hi - lo > 1e-6 { result.append(opJSON("speed", ["from": .number(r2(lo)), "to": .number(r2(hi)), "speed": .number(min(16, up(piece.speed * factor))), "snap": .bool(true)])) }
            }
        }
        switch name {
        case "keepShots":
            let board = try sb()
            var chosen: [Shot]
            if let ids = raw["shots"]?.strings {
                chosen = try ids.map { id in guard let s = board.shots.first(where: { $0.id == id }) else { throw bad("unknown shot \(id); call analyze.shots") }; return s }
            } else if let w = raw["where"] {
                let kinds = try w["kind"].map { v -> Set<ShotKind> in
                    guard let names = v.strings else { throw bad("where.kind must be [kind]") }
                    return Set(try names.map { n in guard let k = ShotKind(rawValue: n) else { throw bad("unknown shot kind \(n)") }; return k })
                }
                let minEnergy = try number("minEnergy", 0, in: w)
                chosen = board.shots.filter { (kinds?.contains($0.kind) ?? true) && $0.energy >= minEnergy }
            } else { throw bad("keepShots needs shots:[id] or where:{kind,minEnergy}") }
            let keptIDs = Set(chosen.map(\.id)); var seen = Set<String>()
            picks = board.shots.filter { seen.insert($0.id).inserted }.map { ShotPick(id: $0.id, kind: $0.kind, energy: $0.energy, kept: keptIDs.contains($0.id)) }
            let lead = try number("lead", 0, in: raw["trim"]), tail = try number("tail", 0, in: raw["trim"])
            guard lead >= 0, tail >= 0 else { throw bad("trim.lead and trim.tail must be >= 0") }
            var keep: [TimeRange] = []
            for s in chosen where s.to - tail > s.from + lead { keep += map.outputRanges(source: s.from + lead, to: s.to - tail) }
            guard !keep.isEmpty else { throw bad("no shots to keep; check the ids or filters against analyze.shots") }
            var at = 0.0
            for k in keep.sorted(by: { $0.start < $1.start }) {   // gaps between kept ranges (including overlaps from copies) are cut
                if k.start - at > 0.05 { result += cutsAvoidingImported(at, k.start) }
                at = max(at, k.end)
            }
            if total - at > 0.05 { result += cutsAvoidingImported(at, total) }
        case "pace":
            let beat = raw["beat"], fill = raw["speedFill"]
            let dflt = try number("default", 0.9, in: beat), payoff = try number("payoff", 1.3, in: beat), motion = try number("motion", 0.8, in: beat)
            let maxStatic = try number("maxStatic", 1.2)
            let lo = try number("min", 1.5, in: fill), hi = try number("max", 6, in: fill)
            guard dflt > 0, payoff > 0, motion > 0, maxStatic > 0, lo >= 1, hi >= lo else { throw bad("pace beats and maxStatic must be > 0 and speedFill 1 <= min <= max") }
            for s in try sb().segments(map) {
                let a = s.range.start, b = s.range.end, d = s.duration
                switch s.shot.kind {
                case .static, .cursorOnly:
                    guard s.shot.tag != "result", d > maxStatic + 1e-6 else { continue }
                    let ratio = up(d / maxStatic)
                    if ratio >= lo {   // speed the head so it plays in maxStatic, cut what the speed cap can't absorb
                        let v = min(ratio, hi), x = min(d, maxStatic * v)
                        if d - x < 0.1 { speedUp(s, a, b, ratio) }   // a sliver is not worth a cut
                        else { speedUp(s, a, a + x, v); result.append(cutJSON(a + x, b)) }
                    } else { result.append(cutJSON(a + maxStatic, b)) }
                case .payoff:   // hold the change for `payoff` after it settles (last click), cut the rest
                    let settle = (s.shot.clicks.compactMap { map.outputTime(atSource: $0) }.max() ?? a) - a
                    let hold = settle + payoff
                    if d > hold + 0.05 { result.append(cutJSON(a + hold, b)) }
                case .motion, .typing:   // content moves: ease it with at most speedFill.min, never the static-hold squeeze
                    let target = s.shot.kind == .motion ? motion : dflt
                    if d / target >= 1.1 { speedUp(s, a, b, min(up(d / target), lo)) }
                }
            }
        case "fitDuration":
            let target = try number("target", 0), tolerance = try number("tolerance", 2)
            guard target > 0, tolerance >= 0 else { throw bad("fitDuration needs target > 0 and tolerance >= 0") }
            let protected = Set(raw["protect"]?.strings ?? [])
            // Interest: kind rank first, energy as tie-break. Lowest goes first.
            let rank: [ShotKind: Double] = [.static: 0, .cursorOnly: 1, .typing: 2, .motion: 3, .payoff: 4]
            let order = try sb().segments(map).filter { !protected.contains($0.shot.id) }
                .sorted { (rank[$0.shot.kind]! + $0.shot.energy, -$0.duration) < (rank[$1.shot.kind]! + $1.shot.energy, -$1.duration) }
            // Target the exported length: layers/audio past the video (e.g. an outro) count, and shift earlier with each cut.
            var length = project.exportDuration, ids: [String] = []
            for s in order {
                let excess = length - target
                if excess <= tolerance { break }
                if s.duration <= excess + tolerance {
                    result.append(cutJSON(s.range.start, s.range.end)); length -= s.duration
                    if !ids.contains(s.shot.id) { ids.append(s.shot.id) }
                } else {   // last one: compress to absorb the remaining excess, or trim its tail when that would need > 6x
                    let ratio = up(s.duration / (s.duration - excess))
                    if ratio <= 6 { speedUp(s, s.range.start, s.range.end, ratio) } else { result.append(cutJSON(s.range.end - excess, s.range.end)) }
                    length = target; break
                }
            }
            dropped = ids
            if length - target > tolerance { note = String(format: "could not reach %.1fs: %.1fs left after protected/remaining shots", target, length) }
        case "autoZoom":
            let lead = try number("lead", 0.4), tail = try number("tail", 1.5), scale = try number("scale", 2)
            let from = try number("from", 0), to = try number("to", total)
            guard lead >= 0, tail >= 0, scale >= 1 else { throw bad("autoZoom needs lead/tail >= 0 and scale >= 1") }
            // Non-destructive: a generated zoom that overlaps an existing zoom is skipped (Regenerate would replace them; an agent batch must not).
            for z in generateAutoZooms(clicks: clicks, duration: project.source.duration, lead: lead, tail: tail)
            where !project.zooms.contains(where: { $0.start < z.end && $0.end > z.start }) {
                for p in map.pieces(source: z.start, to: z.end) where (p.range.end - p.range.start) * p.scale >= 0.5 && min(p.range.end, to) - max(p.range.start, from) >= 0.1 {
                    result.append(opJSON("zoom", ["from": .number(r2(max(p.range.start, from))), "to": .number(r2(min(p.range.end, to))), "scale": .number(scale)]))
                }
            }
        case "speed" where raw["ramp"] != nil:
            // ponytail: no native speed easing, so the ramp is 4 stepped speeds per side; upgrade when clips gain a speed curve.
            guard let from = raw["from"]?.num, let to = raw["to"]?.num, to > from, let speed = raw["speed"]?.num, speed > 0 else { throw bad("a ramped speed needs numeric from < to and speed > 0") }
            var rin = try number("in", 0.2, in: raw["ramp"]), rout = try number("out", 0.2, in: raw["ramp"])
            guard rin >= 0, rout >= 0 else { throw bad("ramp.in and ramp.out must be >= 0") }
            if rin + rout > 0.8 * (to - from) { let k = 0.8 * (to - from) / (rin + rout); rin *= k; rout *= k }
            let snap = raw["snap"] ?? .bool(false)
            func step(_ a: Double, _ b: Double, _ v: Double) {
                result.append(opJSON("speed", ["from": .number(r2(a)), "to": .number(r2(b)), "speed": .number(r2(v)), "snap": snap]))
            }
            // Ramp from the speed already playing at `from` to `speed`, and back to what plays at `to`.
            let s0 = map.speed(atOutput: from), s1 = map.speed(atOutput: to - 1e-6)
            let nIn = min(4, Int(rin / 0.15)), nOut = min(4, Int(rout / 0.15))
            for i in 0..<nIn { step(from + rin / Double(nIn) * Double(i), from + rin / Double(nIn) * Double(i + 1), s0 + (speed - s0) * (Double(i) + 0.5) / Double(nIn)) }
            let midStart = from + (nIn > 0 ? rin : 0), midEnd = to - (nOut > 0 ? rout : 0)
            step(midStart, midEnd, speed)
            for i in 0..<nOut { step(midEnd + rout / Double(nOut) * Double(i), midEnd + rout / Double(nOut) * Double(i + 1), speed + (s1 - speed) * (Double(i) + 0.5) / Double(nOut)) }
        default: out.append(raw); origin.append(index); continue
        }
        out += result; origin += result.map { _ in index }
        lowered.append(LoweredIntent(op: index, intent: name, ops: result, dropped: dropped, note: note, shots: picks))
    }
    return (out, origin, lowered)
}

public extension EditError {
    /// Re-point an error at the agent's original op index after intents were lowered.
    func remapped(_ origin: [Int]) -> EditError {
        func m(_ i: Int) -> Int { origin.indices.contains(i) ? origin[i] : i }
        switch self {
        case let .invalidOp(i, r): return .invalidOp(index: m(i), reason: r)
        case let .outOfRange(i, r): return .outOfRange(index: m(i), reason: r)
        default: return self
        }
    }
}
