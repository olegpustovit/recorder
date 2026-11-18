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
    public var section: Int? = nil
}

private extension JSONValue {
    subscript(key: String) -> JSONValue? { if case .object(let o) = self { return o[key] }; return nil }
    var num: Double? { if case .number(let v) = self { return v }; return nil }
    var strings: [String]? { if case .array(let a) = self { let s = a.compactMap { v -> String? in if case .string(let x) = v { return x }; return nil }; return s.count == a.count ? s : nil }; return nil }
}

/// An intent `protect` entry: a shot id, `section:N`, or `caption~REGEX` matched case-insensitively against the shot's OCR caption.
func protects(_ list: [String], _ shot: Shot) -> Bool {
    list.contains { entry in
        if entry.hasPrefix("section:") { return shot.section.map { "section:\($0)" == entry } ?? false }
        guard entry.hasPrefix("caption~") else { return entry == shot.id }
        return shot.caption?.range(of: String(entry.dropFirst(8)), options: [.regularExpression, .caseInsensitive]) != nil
    }
}

/// Top-level fields each intent reads. `mcp-schema` checks them against the tools/list op schemas (intents: equal; ramped
/// speed: a subset), and every read below asserts its key is listed, so Core and the advertised schema cannot drift (R4-1).
public let intentFields: [String: Set<String>] = [
    "keepShots": ["shots", "where", "trim", "protect"],
    "pace": ["beat", "maxStatic", "speedFill", "profile"],
    "steps": ["lead", "settle", "maxGap", "retake", "protect"],
    "fitDuration": ["target", "tolerance", "protect", "minPerSection", "balance", "drop"],
    "autoZoom": ["lead", "tail", "scale", "from", "to"],
    "speed": ["from", "to", "speed", "ramp", "snap"]]

/// `storyboard` is only called when an op needs shots (so autoZoom/ramp work without analysis).
/// `origin[i]` is the index in the agent's batch that produced `ops[i]`; use it to report errors and changes.
public func lowerIntents(_ ops: [JSONValue], project: Project, clicks: [InputEvent] = [], activity: [Double] = [],
                         storyboard: () throws -> Storyboard) throws -> (ops: [JSONValue], origin: [Int], lowered: [LoweredIntent]) {
    let map = TimeMap(project.clips), total = map.outputDuration
    // End of the last recorded/imported footage: a trailing gap clip has nothing to cut (snapping would skip it).
    let contentEnd = { () -> Double in var t = 0.0, end = 0.0; for c in project.clips { t += c.outputDuration; if !c.isEmpty { end = t } }; return end }()
    var out: [JSONValue] = [], origin: [Int] = [], lowered: [LoweredIntent] = []
    // Each intent reads the batch-start timeline, so two that change the length would aim at stale times.
    let lengthChanging = ops.enumerated().filter { if case .string(let n)? = $1["op"] { return ["keepShots", "pace", "fitDuration", "steps"].contains(n) }; return false }
    if lengthChanging.count > 1 {
        throw EditError.invalidOp(index: lengthChanging[1].offset, reason: "only one of keepShots/pace/fitDuration/steps per batch; call edit.apply once per intent")
    }
    let imported = { () -> [TimeRange] in var t = 0.0; return project.clips.compactMap { c in defer { t += c.outputDuration }; return c.file != nil ? TimeRange(start: t, end: t + c.outputDuration) : nil } }()
    var board: Storyboard?
    func sb() throws -> Storyboard { if let board { return board }; let b = try storyboard(); board = b; return b }
    func cutsAvoidingImported(_ a: Double, _ b: Double, protecting protected: [TimeRange] = []) -> [JSONValue] {
        var pieces = [TimeRange(start: a, end: b)]
        for hole in imported + protected {
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
        func arg(_ key: String) -> JSONValue? {
            assert(intentFields[name]?.contains(key) ?? true, "\(name).\(key) is read but not in intentFields/tools schema")
            return raw[key]
        }
        func number(_ key: String, _ fallback: Double) throws -> Double { try value(arg(key), key, fallback) }
        /// A field of a nested object (`where`, `trim`, `beat`, `speedFill`, `ramp`); an absent object means the default.
        func nested(_ key: String, _ fallback: Double, in v: JSONValue?) throws -> Double { try value(v?[key], key, fallback) }
        func value(_ field: JSONValue?, _ key: String, _ fallback: Double) throws -> Double {
            guard let field else { return fallback }
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
            if let ids = arg("shots")?.strings {
                chosen = try ids.map { id in guard let s = board.shots.first(where: { $0.id == id }) else { throw bad("unknown shot \(id); call analyze.shots") }; return s }
            } else if let w = arg("where") {
                let kinds = try w["kind"].map { v -> Set<ShotKind> in
                    guard let names = v.strings else { throw bad("where.kind must be [kind]") }
                    return Set(try names.map { n in guard let k = ShotKind(rawValue: n) else { throw bad("unknown shot kind \(n)") }; return k })
                }
                let minEnergy = try nested("minEnergy", 0, in: w)
                chosen = board.shots.filter { (kinds?.contains($0.kind) ?? true) && $0.energy >= minEnergy }
            } else if arg("protect") == nil { throw bad("keepShots needs shots:[id], where:{kind,minEnergy} or protect") } else { chosen = [] }
            // protect keeps the subject even when the filter would drop it (calm close-ups score low energy).
            if let list = arg("protect") {
                guard let entries = list.strings else { throw bad("protect must be [shot id or caption~regex]") }
                chosen += board.shots.filter { protects(entries, $0) && !chosen.contains($0) }
            }
            let keptIDs = Set(chosen.map(\.id)); var seen = Set<String>()
            picks = board.shots.filter { seen.insert($0.id).inserted }.map { ShotPick(id: $0.id, kind: $0.kind, energy: $0.energy, kept: keptIDs.contains($0.id), section: $0.section) }
            let lead = try nested("lead", 0, in: arg("trim")), tail = try nested("tail", 0, in: arg("trim"))
            guard lead >= 0, tail >= 0 else { throw bad("trim.lead and trim.tail must be >= 0") }
            var keep: [TimeRange] = []
            for s in chosen where s.to - tail > s.from + lead { keep += map.outputRanges(source: s.from + lead, to: s.to - tail) }
            guard !keep.isEmpty else { throw bad("no shots to keep; check the ids or filters against analyze.shots") }
            var at = 0.0
            for k in keep.sorted(by: { $0.start < $1.start }) {   // gaps between kept ranges (including overlaps from copies) are cut
                if k.start - at > 0.05 { result += cutsAvoidingImported(at, k.start) }
                at = max(at, k.end)
            }
            if contentEnd - at > 0.05 { result += cutsAvoidingImported(at, contentEnd) }
        case "pace":
            let beat = arg("beat"), fill = arg("speedFill")
            // The delivery profile sets the rhythm: reel beat-cuts tight; demo and tutorial hold longer and only cut real waits.
            let profileName: String
            switch arg("profile") { case nil: profileName = "reel"; case .string(let v)?: profileName = v; default: throw bad("profile must be reel, demo or tutorial") }
            guard let profile = LintProfile(name: profileName) else { throw bad("profile must be reel, demo or tutorial") }
            let pace: (dflt: Double, payoff: Double, motion: Double, wait: Double) =
                profile.name == "tutorial" ? (2.5, 3.5, 2.0, 2.0) : profile.name == "demo" ? (1.4, 2.0, 1.2, 1.0) : (0.9, 1.3, 0.8, 0.5)
            let dflt = try nested("default", pace.dflt, in: beat), payoff = try nested("payoff", pace.payoff, in: beat), motion = try nested("motion", pace.motion, in: beat)
            let maxStatic = try number("maxStatic", profile.maxStatic)
            let lo = try nested("min", 1.5, in: fill), hi = try nested("max", 6, in: fill)
            guard dflt > 0, payoff > 0, motion > 0, maxStatic > 0, lo >= 1, hi >= lo else { throw bad("pace beats and maxStatic must be > 0 and speedFill 1 <= min <= max") }
            for s in try sb().segments(map) {
                let a = s.range.start, b = s.range.end, d = s.duration
                // Beat cut (R3-5/R4-5): a shot with clicks keeps [click - 0.1, click + beat] and loses the waiting around it,
                // instead of a blanket speed-up. Waits shorter than the profile's (reel 0.5 s) stay; shots without clicks fall through.
                let beats = s.shot.clicks.compactMap { map.outputTime(atSource: $0) }.filter { $0 >= a && $0 < b }.sorted()
                if !s.shot.isStatic, !beats.isEmpty {
                    let hold = s.shot.kind == .payoff ? payoff : s.shot.kind == .motion ? motion : dflt
                    var windows: [(Double, Double)] = []
                    for c in beats {
                        let w = (max(a, c - 0.1), min(b, c + hold))
                        if let last = windows.last, w.0 <= last.1 + pace.wait { windows[windows.count - 1].1 = max(last.1, w.1) } else { windows.append(w) }
                    }
                    var at = a
                    for w in windows { if w.0 - at >= pace.wait { result.append(cutJSON(at, w.0)) }; at = w.1 }
                    if b - at >= pace.wait { result.append(cutJSON(at, b)) }
                    continue
                }
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
            // No flicker from beat cuts: a kept piece under 0.3 s between two cuts (or a cut and an edit cut / the timeline
            // edge) is cut too, and a speed op inside a cut is dropped.
            let cuts = result.compactMap { op -> (Double, Double)? in
                guard op["op"] == .string("cut"), let x = op["from"]?.num, let y = op["to"]?.num else { return nil }
                return (x, y)
            }.sorted { $0.0 < $1.0 }
            if !cuts.isEmpty {
                let edges = ([0, contentEnd] + map.editCuts).sorted()
                var merged: [(Double, Double)] = []
                for c in cuts { if let l = merged.last, c.0 - l.1 < 0.3 { merged[merged.count - 1].1 = max(l.1, c.1) } else { merged.append(c) } }
                merged = merged.map { c in
                    var (x, y) = c
                    if let e = edges.last(where: { $0 <= x + 1e-9 }), x - e < 0.3 { x = e }
                    if let e = edges.first(where: { $0 >= y - 1e-9 }), e - y < 0.3 { y = e }
                    return (x, y)
                }
                result = result.filter { op in
                    guard op["op"] != .string("cut") else { return false }
                    guard let f = op["from"]?.num, let t = op["to"]?.num else { return true }
                    return !merged.contains { f >= $0.0 - 1e-9 && t <= $0.1 + 1e-9 }
                } + merged.map { cutJSON($0.0, $0.1) }
            }
        case "steps":
            let lead = try number("lead", 0.4), settle = try number("settle", 1.2), maxGap = try number("maxGap", 2)
            guard lead >= 0, settle >= 0, maxGap >= 0 else { throw bad("steps lead, settle and maxGap must be nonnegative") }
            let retake: String
            switch arg("retake") {
            case nil: retake = "retake:"
            case .string(let prefix)? where !prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty: retake = prefix
            default: throw bad("steps retake must be a nonempty marker prefix")
            }
            guard arg("protect") == nil || arg("protect")?.strings != nil else { throw bad("protect must be a list of shot selectors") }
            let segments = try sb().segments(map), selectors = arg("protect")?.strings ?? []
            let protected = segments.filter { protects(selectors, $0.shot) }.map(\.range)
            let marks = project.markers.compactMap { mark in
                map.outputTime(atSource: mark.time).flatMap { $0 <= contentEnd ? (time: $0, label: mark.label) : nil }
            }.sorted { $0.time < $1.time }
            guard !marks.isEmpty else { throw bad("steps needs at least one marker on the video timeline") }
            var failedAttempts = Set<Int>(), failedRanges: [TimeRange] = [], lastAttempt: [String: Int] = [:]
            for (i, mark) in marks.enumerated() {
                var label = mark.label
                if label.hasPrefix(retake) {
                    label = String(label.dropFirst(retake.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if let failed = lastAttempt[label] {
                        failedAttempts.insert(failed)
                        failedRanges.append(TimeRange(start: marks[failed].time, end: mark.time))
                    }
                }
                lastAttempt[label] = i
            }
            var outputStart = 0.0
            var activityInOutput = project.clips.flatMap { clip -> [Double] in
                defer { outputStart += clip.outputDuration }
                guard !clip.isEmpty, clip.file == nil else { return [] }
                return activity.filter { $0 >= clip.mediaIn && $0 < clip.mediaEnd }
                    .map { outputStart + ($0 - clip.mediaIn) / clip.speed }
            }
            for segment in segments {
                if !segment.shot.isStatic || segment.shot.boundary == .cut { activityInOutput.append(segment.range.start) }
                if !segment.shot.isStatic { activityInOutput.append(segment.range.end) }
            }
            activityInOutput.sort()
            let windows = marks.indices.filter { !failedAttempts.contains($0) }.map { i in
                let start = marks[i].time
                let limit = i + 1 < marks.count ? marks[i + 1].time : contentEnd
                let last = activityInOutput.last { start <= $0 && $0 < limit } ?? start
                return TimeRange(start: max(0, start - lead), end: min(limit, last + settle))
            }
            guard windows.contains(where: { $0.end > $0.start }) else { throw bad("steps kept no video; increase lead or settle") }
            var start = 0.0
            var gaps = failedRanges
            for keep in mergedEditRanges(windows + protected) {
                if keep.start - start > maxGap { gaps.append(TimeRange(start: start, end: keep.start)) }
                start = max(start, keep.end)
            }
            if contentEnd - start > maxGap { gaps.append(TimeRange(start: start, end: contentEnd)) }
            result = mergedEditRanges(gaps).flatMap { cutsAvoidingImported($0.start, $0.end, protecting: protected) }
            let reserved = (imported + protected).flatMap { map.editRanges(from: $0.start, to: $0.end) }
            if !reserved.isEmpty {
                // shortcut: omit cuts that would snap into protected footage, split them further if this leaves visible waits.
                result = result.filter { cut in
                    guard let from = cut["from"]?.num, let to = cut["to"]?.num else { return false }
                    let snapped = snappedEditRanges(map.editRanges(from: from, to: to), clips: project.clips)
                    return !snapped.contains { piece in
                        reserved.contains { min(piece.end, $0.end) - max(piece.start, $0.start) > 1e-9 }
                    }
                }
            }
        case "fitDuration":
            let target = try number("target", 0), tolerance = try number("tolerance", 2)
            guard target > 0, tolerance >= 0 else { throw bad("fitDuration needs target > 0 and tolerance >= 0") }
            let protected = arg("protect")?.strings ?? []
            // Interest: kind rank first, energy as tie-break. Lowest goes first.
            let rank: [ShotKind: Double] = [.static: 0, .cursorOnly: 1, .typing: 2, .motion: 3, .payoff: 4]
            let minPerSection = try number("minPerSection", 0)
            let balance: String
            switch arg("balance") { case nil: balance = "energy"; case .string(let v)? where ["even", "proportional", "energy"].contains(v): balance = v; default: throw bad("balance must be even, proportional or energy") }
            guard minPerSection >= 0 else { throw bad("minPerSection must be >= 0") }
            let all = try sb().segments(map)
            var kept = sectionSeconds(all)   // output seconds per section; minPerSection never lets one fall below it
            var order = all.filter { !protects(protected, $0.shot) }
                .sorted { (rank[$0.shot.kind]! + $0.shot.energy, -$0.duration) < (rank[$1.shot.kind]! + $1.shot.energy, -$1.duration) }
            // Target the exported length: layers/audio past the video (e.g. an outro) count, and shift earlier with each cut.
            var length = project.exportDuration, ids: [String] = []
            // drop: whole sections the agent judged weak (e.g. an empty code view) go first, except protected shots.
            guard arg("drop") == nil || arg("drop").map({ v -> Bool in if case .array(let a) = v { return a.allSatisfy { $0.num != nil } }; return false }) == true else { throw bad("drop must be [section number]") }
            let dropSections: Set<Int> = { if case .array(let a)? = arg("drop") { return Set(a.compactMap { $0.num.map(Int.init) }) }; return [] }()
            for s in order where dropSections.contains(s.shot.section ?? 1) {
                result.append(cutJSON(s.range.start, s.range.end)); length -= s.duration; kept[s.shot.section ?? 1, default: 0] -= s.duration
                if !ids.contains(s.shot.id) { ids.append(s.shot.id) }
            }
            order.removeAll { dropSections.contains($0.shot.section ?? 1) }
            if balance != "energy", length - target > tolerance {
                // Balanced: give each section a quota, then cut it down to that, least interesting shots first and the last one
                // trimmed, so the split is exact rather than whole-shot greedy. even: one shared level L (quota = min(own, L));
                // proportional: one share p of each section's own length. Both never below minPerSection or protected footage.
                let movable = Dictionary(grouping: order, by: { $0.shot.section ?? 1 })
                let floor = kept.mapValues { _ in 0.0 }.merging(movable.mapValues { _ in 0.0 }) { a, _ in a }.reduce(into: [Int: Double]()) { acc, e in
                    acc[e.key] = kept[e.key, default: 0] - (movable[e.key] ?? []).reduce(0) { $0 + $1.duration }   // protected seconds
                }
                func quota(_ k: Int, _ x: Double) -> Double {
                    let have = kept[k, default: 0]
                    return max(floor[k, default: 0], min(have, max(minPerSection, balance == "even" ? x : have * x)))
                }
                let excess = length - target
                func removed(_ x: Double) -> Double { kept.keys.reduce(0) { $0 + kept[$1, default: 0] - quota($1, x) } }
                var lo = 0.0, hi = balance == "even" ? (kept.values.max() ?? 0) : 1.0
                for _ in 0..<60 { let mid = (lo + hi) / 2; if removed(mid) > excess { lo = mid } else { hi = mid } }
                for k in kept.keys.sorted() {
                    var need = kept[k, default: 0] - quota(k, hi)
                    for s in movable[k] ?? [] where need > 0.05 {   // `order` is least interesting first
                        if s.duration <= need + 0.05 || s.duration - need < 0.5 {   // a trim must not leave a flicker stub
                            result.append(cutJSON(s.range.start, s.range.end)); need -= s.duration; length -= s.duration; kept[k, default: 0] -= s.duration
                            if !ids.contains(s.shot.id) { ids.append(s.shot.id) }
                        } else {
                            if need >= 0.3 { result.append(cutJSON(s.range.end - need, s.range.end)); length -= need; kept[k, default: 0] -= need }
                            need = 0
                        }
                    }
                }
            }
            while balance == "energy", length - target > tolerance {
                let excess = length - target
                func amount(_ s: ShotSegment) -> Double { s.duration <= excess + tolerance ? s.duration : excess }
                // Least interesting first; minPerSection keeps every section at or above its floor.
                guard let pick = order.indices.first(where: { kept[order[$0].shot.section ?? 1, default: 0] - amount(order[$0]) >= minPerSection - 1e-6 }) else { break }
                let s = order.remove(at: pick)
                kept[s.shot.section ?? 1, default: 0] -= amount(s)
                if s.duration <= excess + tolerance {
                    result.append(cutJSON(s.range.start, s.range.end)); length -= s.duration
                    if !ids.contains(s.shot.id) { ids.append(s.shot.id) }
                } else {   // last one: compress to absorb the remaining excess, or trim its tail when that would need > 6x
                    let ratio = up(s.duration / (s.duration - excess))
                    if ratio <= 6 { speedUp(s, s.range.start, s.range.end, ratio) } else { result.append(cutJSON(s.range.end - excess, s.range.end)) }
                    length = target
                }
            }
            dropped = ids
            var notes: [String] = []
            if length - target > tolerance { notes.append(String(format: "could not reach %.1fs: %.1fs left after protected shots and minPerSection", target, length)) }
            // minPerSection never cuts a section below it, so a short one had less footage to begin with: say so (R4-2).
            for (k, sec) in kept.sorted(by: { $0.key < $1.key }) where minPerSection > 0 && !dropSections.contains(k) && sec < minPerSection - 0.01 {
                notes.append(String(format: "section %d keeps %.1fs < minPerSection %.1fs: it only had that much footage", k, max(0, sec), minPerSection))
            }
            note = notes.isEmpty ? nil : notes.joined(separator: "; ")
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
            guard let from = arg("from")?.num, let to = arg("to")?.num, to > from, let speed = arg("speed")?.num, speed > 0 else { throw bad("a ramped speed needs numeric from < to and speed > 0") }
            var rin = try nested("in", 0.2, in: arg("ramp")), rout = try nested("out", 0.2, in: arg("ramp"))
            guard rin >= 0, rout >= 0 else { throw bad("ramp.in and ramp.out must be >= 0") }
            if rin + rout > 0.8 * (to - from) { let k = 0.8 * (to - from) / (rin + rout); rin *= k; rout *= k }
            let snap = arg("snap") ?? .bool(false)
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
        // A piece that rounds to nothing (from == to) would fail the whole batch as OUT_OF_RANGE, and a cut/speed range under
        // the 0.1 s clip minimum is only skipped by snapping: emit neither.
        result = result.filter { op in
            guard let a = op["from"]?.num, let b = op["to"]?.num else { return true }
            return b - a >= ([.string("cut"), .string("speed")].contains(op["op"]) ? 0.1 : 0.01) - 1e-9
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
