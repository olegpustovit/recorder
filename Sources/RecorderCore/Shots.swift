import Foundation

/// Shot storyboard for `analyze.shots` (T-827). Shared contract for report/lint, intent ops and reframe
/// (T-828…T-831): fields here are frozen; segmentation functions are added by T-827.
public enum ShotKind: String, Codable, Sendable, CaseIterable { case payoff, motion, cursorOnly, `static`, typing }
public enum ShotBoundary: String, Codable, Sendable { case start, cut, scroll, animate, type }

public struct Shot: Codable, Equatable, Sendable {
    public var id: String            // "s07": ordinal in *source* time, stable across edits
    public var from: Double          // source seconds
    public var to: Double
    public var kind: ShotKind
    public var boundary: ShotBoundary
    public var energy: Double        // 0…1 mean normalised diff
    public var staticFrac: Double    // 0…1 fraction of frames with no change
    public var clicks: [Double]      // source seconds
    public var cursor: NormPoint?    // mean cursor position
    public var focus: NormRect       // changed pixels ∪ cursor dwell, normalised 0…1 top-left origin
    public var reasons: [String]
    public var caption: String?
    public var tag: String?          // "result": a hold meant to be long (exempt from maxStatic)
    public var part: String?         // "2/3" when edits split the shot into separate pieces (same id, cut between them)
    public var section: Int?         // 1-based scene of the project (see `inSource`); stable across edits
    public init(id: String, from: Double, to: Double, kind: ShotKind, boundary: ShotBoundary, energy: Double = 0,
                staticFrac: Double = 0, clicks: [Double] = [], cursor: NormPoint? = nil, focus: NormRect = NormRect(),
                reasons: [String] = [], caption: String? = nil, tag: String? = nil) {
        self.id = id; self.from = from; self.to = to; self.kind = kind; self.boundary = boundary
        self.energy = energy; self.staticFrac = staticFrac; self.clicks = clicks; self.cursor = cursor
        self.focus = focus; self.reasons = reasons; self.caption = caption; self.tag = tag
    }
    public var duration: Double { to - from }
}

public struct StoryboardSummary: Codable, Equatable, Sendable {
    public struct Span: Codable, Equatable, Sendable { public var from, to: Double; public init(from: Double, to: Double) { self.from = from; self.to = to } }
    public var shots: Int
    public var aslSec: Double
    public var staticSec: Double
    public var longestStatic: Span?
    public init(shots: Int, aslSec: Double, staticSec: Double, longestStatic: Span?) {
        self.shots = shots; self.aslSec = aslSec; self.staticSec = staticSec; self.longestStatic = longestStatic
    }
}

public struct Storyboard: Codable, Equatable, Sendable {
    public var duration: Double      // source seconds
    public var fps: Double
    public var shots: [Shot]         // source time, sorted, non-overlapping
    public var summary: StoryboardSummary
    public init(duration: Double, fps: Double, shots: [Shot], summary: StoryboardSummary) {
        self.duration = duration; self.fps = fps; self.shots = shots; self.summary = summary
    }
}

// Segmentation + output-time mapping for the frozen types above (T-827).

/// analyze.shots (T-827): GIFdroid-style segmentation of a screen recording into shots from cheap per-frame
/// signals plus input events. Pure: the app decodes frames (`FrameSignal`s at `fps`), Core decides. Times are
/// media seconds of the UNEDITED recording, so ids (s01…) stay stable across edits; `mapped(through:)` reports
/// the same shots in output time.

private extension NormRect {
    func union(_ o: NormRect) -> NormRect {
        let (x0, y0) = (min(x, o.x), min(y, o.y))
        return NormRect(x: x0, y: y0, w: max(x + w, o.x + o.w) - x0, h: max(y + h, o.y + o.h) - y0)
    }
}

/// What changed from the previous frame to this one (frame 0: diff 0, ssim 1).
public struct FrameSignal: Codable, Equatable, Sendable {
    public var diff: Double      // mean absolute luma difference, 0…1
    public var ssim: Double      // similarity with the previous frame, 0…1
    public var bbox: NormRect?   // changed-pixel bounding box, nil when nothing changed
    public init(diff: Double, ssim: Double, bbox: NormRect? = nil) { self.diff = diff; self.ssim = ssim; self.bbox = bbox }
}

public struct ShotThresholds: Codable, Equatable, Sendable {
    public var ssim = 0.985          // τ: a frame at or above it is "stable"
    public var minStable = 0.3       // seconds a stable run needs to count as a state
    public var cutSsim = 0.9         // a ≤ 2-frame change dipping below this is a cut
    public var motionDiff = 0.01     // mean diff at or above which a shot is motion
    public var payoffDiff = 0.03     // frame diff after a click that makes a payoff
    public var cursorSpeed = 0.05    // normalised screen widths/s for cursorOnly
    public var energyScale = 0.1     // diff that maps to energy 1
    public init() {}
    /// Why these values are unusable (they would divide by zero or put NaN into JSON), or nil.
    public var invalidReason: String? {
        if !(energyScale > 0 && energyScale.isFinite) { return "energyScale must be > 0" }
        if !(0...1).contains(ssim) { return "ssim must be within 0…1" }
        if !(0...1).contains(cutSsim) { return "cutSsim must be within 0…1" }
        if !(minStable > 0 && minStable.isFinite) { return "minStable must be > 0" }
        if ![motionDiff, payoffDiff, cursorSpeed].allSatisfy({ $0 >= 0 && $0.isFinite }) { return "motionDiff, payoffDiff and cursorSpeed must be ≥ 0" }
        return nil
    }
}


public func storyboard(signals: [FrameSignal], fps: Double = 10, events: [InputEvent],
                       thresholds t: ShotThresholds = ShotThresholds()) -> Storyboard {
    let n = signals.count
    guard n > 0, fps > 0 else { return summarize([], duration: 0, fps: fps) }
    var stable = signals.indices.map { $0 == 0 || signals[$0].ssim >= t.ssim }
    let minRun = max(1, Int((t.minStable * fps).rounded(.up)))
    var i = 0
    while i < n {   // stable runs shorter than minStable are part of the surrounding change
        var j = i
        while j < n, stable[j] == stable[i] { j += 1 }
        if stable[i], j - i < minRun { for k in i..<j { stable[k] = false } }
        i = j
    }
    let starts = [0] + (1..<max(1, n)).filter { !stable[$0] && stable[$0 - 1] }
    let moves = events.filter { ($0.k == .move || $0.k == .drag) && $0.x != nil && $0.y != nil }.sorted { $0.t < $1.t }
    let clicks = events.filter { $0.k == .down && $0.b == 0 }.map(\.t).sorted()
    let scrolls = events.filter { $0.k == .scroll }.map(\.t)
    // Shortcuts (command/control held) are not typing; one stray key must not make a long shot `.typing`.
    let typing = events.filter { $0.k == .typing || ($0.k == .key && ($0.mods ?? 0) & 0x140000 == 0) }.map(\.t).sorted()
    func any(_ times: [Double], _ lo: Double, _ hi: Double) -> Bool { times.contains { $0 >= lo && $0 < hi } }

    var shots: [Shot] = []
    for (k, a) in starts.enumerated() {
        let b = k + 1 < starts.count ? starts[k + 1] : n
        let (from, to) = (Double(a) / fps, Double(b) / fps)
        let frames = signals[a..<b]
        let lead = (a..<b).first { stable[$0] } ?? b          // end of the transition into this shot
        let energy = frames.map(\.diff).reduce(0, +) / Double(b - a)
        let peak = signals[a..<min(b, a + Int(fps.rounded(.up)))].map(\.diff).max() ?? 0   // a shot that opens on a big change then holds is still motion
        var reasons: [String] = []

        var boundary = ShotBoundary.start
        if a > 0 {
            boundary = .cut
            let (lo, hi) = (Double(a) / fps - 0.2, Double(lead) / fps + 0.1)
            if any(scrolls, lo, hi) { boundary = .scroll; reasons.append("scroll event during the change") }
            else if any(typing, lo, hi) { boundary = .type; reasons.append("typing during the change") }
            else if lead - a <= 2 {   // the change spans ≤ 2 frames: cut; cutSsim only says how sure
                let low = signals[a..<lead].map(\.ssim).min() ?? 1
                reasons.append("ssim dropped to \(r2(low)) within \(lead - a) frame(s)" + (low < t.cutSsim ? "" : " (shallow: above cutSsim)"))
            }
            else { boundary = .animate; reasons.append("gradual change over \(lead - a) frames, no input") }
        }

        let inRange = clicks.filter { $0 >= from && $0 < to }
        let payoff = clicks.contains { c in
            c >= from - 0.5 && c <= to && (a..<b).contains { f in
                let ft = Double(f) / fps
                return ft >= c - 0.1 && ft <= c + 1 && signals[f].diff >= t.payoffDiff
            }
        }
        let path = zip(moves.filter { $0.t >= from && $0.t < to }, moves.filter { $0.t >= from && $0.t < to }.dropFirst())
            .reduce(0) { $0 + hypot($1.1.x! - $1.0.x!, $1.1.y! - $1.0.y!) }
        let kind: ShotKind
        let typed = typing.filter { $0 >= from && $0 < to }
        let typingShot = typed.count >= 3 && (typed.last! - typed.first!) >= 0.25 * (to - from)
        if payoff { kind = .payoff; reasons.append("click followed by a large change") }
        else if typingShot { kind = .typing; reasons.append("typing in progress") }
        else if peak >= t.motionDiff || any(scrolls, from, to) { kind = .motion; reasons.append("peak diff \(r2(peak)) (mean \(r2(energy))) or scroll") }
        else if path / (to - from) >= t.cursorSpeed { kind = .cursorOnly; reasons.append("screen quiet, cursor moving") }
        else { kind = .`static`; reasons.append("screen quiet, cursor still") }

        // focus = changed pixels ∪ where the cursor dwelt over the shot's last second. Changes after the shot settles win:
        // the transition into a view swap repaints the whole screen and would make every such shot's focus the full frame.
        let dwell = moves.filter { $0.t >= max(from, to - 1) && $0.t < to }
        let settled = signals[min(lead, b)..<b].compactMap(\.bbox).filter { $0.w * $0.h >= 0.001 }   // ignore caret/clock blinks
        var focus = (settled.isEmpty ? frames.compactMap(\.bbox) : settled).reduce(nil as NormRect?) { $0?.union($1) ?? $1 }
        if let lo = dwell.map({ $0.x! }).min(), let hi = dwell.map({ $0.x! }).max(),
           let lo2 = dwell.map({ $0.y! }).min(), let hi2 = dwell.map({ $0.y! }).max() {
            let pad = 0.05, x0 = max(0, lo - pad), y0 = max(0, lo2 - pad)
            let box = NormRect(x: x0, y: y0, w: min(1, hi + pad) - x0, h: min(1, hi2 + pad) - y0)
            focus = focus?.union(box) ?? box
        }
        let seen = moves.filter { $0.t >= from && $0.t < to }
        shots.append(Shot(id: String(format: "s%02d", k + 1), from: r2(from), to: r2(to), kind: kind, boundary: boundary,
                          energy: r2(min(1, energy / t.energyScale)),
                          staticFrac: r2(Double((a..<b).filter { signals[$0].ssim >= t.ssim }.count) / Double(b - a)),
                          clicks: inRange.map(r2), cursor: seen.isEmpty ? nil : NormPoint(x: r2(seen.map { $0.x! }.reduce(0, +) / Double(seen.count)), y: r2(seen.map { $0.y! }.reduce(0, +) / Double(seen.count))),
                          focus: focus.map { NormRect(x: r2($0.x), y: r2($0.y), w: r2($0.w), h: r2($0.h)) } ?? NormRect(),
                          reasons: reasons, caption: nil))
    }
    return summarize(shots, duration: Double(n) / fps, fps: fps)
}

private func summarize(_ shots: [Shot], duration: Double, fps: Double) -> Storyboard {
    var shots = shots, seen: [String: Int] = [:]
    let total = Dictionary(shots.map { ($0.id, 1) }, uniquingKeysWith: +)
    for i in shots.indices where total[shots[i].id]! > 1 {
        seen[shots[i].id, default: 0] += 1
        shots[i].part = "\(seen[shots[i].id]!)/\(total[shots[i].id]!)"
    }
    let quiet = shots.filter { $0.kind == .`static` }
    let longest = quiet.max { $0.to - $0.from < $1.to - $1.from }
    return Storyboard(duration: duration, fps: fps, shots: shots, summary: StoryboardSummary(
        shots: shots.count, aslSec: shots.isEmpty ? 0 : r2(shots.map { $0.to - $0.from }.reduce(0, +) / Double(shots.count)),
        staticSec: r2(quiet.map { $0.to - $0.from }.reduce(0, +)), longestStatic: longest.map { StoryboardSummary.Span(from: $0.from, to: $0.to) }))
}

public extension Storyboard {
    /// The same shots (same ids) in the output time of `map`; footage the edits dropped is omitted, a shot split
    /// by a cut appears once per kept piece, and imported/gap clips have no recorded footage.
    /// Media-file seconds (what the analysis measures) → project source seconds, the clock every edit, TimeMap and crop key
    /// uses (they differ once clips carry `mediaStart`). Each recording clip contributes the part of a shot it shows; shots no
    /// clip shows are dropped; ids are kept, so one shot table serves analyze, storyboard, lint, intent ops and reframe.
    func inSource(clips: [Clip]) -> Storyboard {
        var out: [Shot] = []
        for clip in clips where !clip.isEmpty && clip.file == nil {
            for var s in shots {
                let (lo, hi) = (max(s.from, clip.mediaIn), min(s.to, clip.mediaEnd))
                guard hi - lo > 1e-9 else { continue }
                s.clicks = s.clicks.filter { $0 >= lo && $0 < hi }.map { r2(clip.sourceTime(atMedia: $0)) }
                (s.from, s.to) = (clip.sourceTime(atMedia: lo), clip.sourceTime(atMedia: hi))
                // a clip split with nothing removed continues the same piece
                if let last = out.lastIndex(where: { $0.id == s.id }), abs(out[last].to - s.from) < 1e-6 { out[last].to = s.to; out[last].clicks += s.clicks }
                else { out.append(s) }
            }
        }
        var board = summarize(out.sorted { $0.from < $1.from }, duration: duration, fps: fps)
        board.summary.shots = Set(out.map(\.id)).count
        board.assignSections(clips: clips)
        return board
    }

    /// Sections (scenes) for balance: a new one where the project rearranges the recording (a clip whose media position
    /// doesn't follow from the previous one, unlike a plain trim or cut pause); a recording that was only trimmed is split
    /// at `boundary:"cut"` shots into runs of ≥ 10 s. Sections under 3 s join their neighbour.
    /// shortcut: no app/window or caption signal, so two scenes inside one untouched clip only split at cuts; add one when shots carry it.
    mutating func assignSections(clips: [Clip]) {
        let recorded = clips.filter { !$0.isEmpty && $0.file == nil }
        var starts: [Double] = []   // source seconds where a section begins
        for (a, b) in zip(recorded, recorded.dropFirst()) where abs((b.mediaIn - a.mediaEnd) - (b.sourceStart - a.sourceEnd)) > 0.05 {
            starts.append(b.sourceStart)
        }
        if starts.isEmpty {
            var from = shots.first?.from ?? 0
            for s in shots where s.boundary == .cut && s.from - from >= 10 { starts.append(s.from); from = s.from }
        }
        let end = shots.last?.to ?? 0
        var bounds = [shots.first?.from ?? 0] + starts.sorted() + [end]
        var i = 1
        while i < bounds.count - 1 {   // drop a start whose section (or the one before it) is shorter than 3 s
            if bounds[i + 1] - bounds[i] < 3 || bounds[i] - bounds[i - 1] < 3 { bounds.remove(at: i) } else { i += 1 }
        }
        for k in shots.indices { shots[k].section = (bounds.dropLast().lastIndex { $0 <= shots[k].from + 1e-6 } ?? 0) + 1 }
    }

    /// Shots read to name each section: its 3 longest non-typing shots (typing is never read, key presses stay private).
    func sectionRepresentatives() -> [Shot] {
        Dictionary(grouping: shots.filter { $0.section != nil && $0.kind != .typing }, by: { $0.section! })
            .values.flatMap { $0.sorted { $0.duration > $1.duration }.prefix(3) }.sorted { $0.from < $1.from }
    }

    /// Source-time storyboard (see `inSource`) → output time through the project's clips.
    func mapped(through map: TimeMap) -> Storyboard {
        var out: [Shot] = [], offset = 0.0, open: [String: (idx: Int, src: Double)] = [:]
        for clip in map.clips {
            defer { offset += clip.outputDuration }
            guard !clip.isEmpty, clip.file == nil else { continue }
            func output(_ source: Double) -> Double { r2(offset + (source - clip.sourceStart) / clip.timeScale) }
            for var s in shots {
                let (lo, hi) = (max(s.from, clip.sourceStart), min(s.to, clip.sourceEnd))
                guard hi - lo > 1e-9 else { continue }
                s.clicks = s.clicks.filter { $0 >= lo && $0 < hi }.map(output)
                (s.from, s.to) = (output(lo), output(hi))
                // a plain split (nothing removed) is one shot: join pieces contiguous in source and output time
                if let o = open[s.id], abs(o.src - lo) < 1e-9, abs(out[o.idx].to - s.from) < 0.02 {
                    out[o.idx].to = s.to; out[o.idx].clicks += s.clicks; open[s.id] = (o.idx, hi)
                } else { open[s.id] = (out.count, hi); out.append(s) }
            }
        }
        var board = summarize(out.sorted { $0.from < $1.from }, duration: map.outputDuration, fps: fps)
        board.summary.shots = Set(out.map(\.id)).count
        return board
    }
}

/// Boundary precision/recall/F1 against reference times (T-827 acceptance): greedy one-to-one match within `tolerance`.
public func boundaryScore(detected: [Double], truth: [Double], tolerance: Double = 0.3) -> (precision: Double, recall: Double, f1: Double) {
    var unused = truth.sorted(), hits = 0
    for d in detected.sorted() {
        guard let i = unused.indices.min(by: { abs(unused[$0] - d) < abs(unused[$1] - d) }), abs(unused[i] - d) <= tolerance else { continue }
        unused.remove(at: i); hits += 1
    }
    let p = detected.isEmpty ? 0 : Double(hits) / Double(detected.count), r = truth.isEmpty ? 0 : Double(hits) / Double(truth.count)
    return (p, r, p + r == 0 ? 0 : 2 * p * r / (p + r))
}
