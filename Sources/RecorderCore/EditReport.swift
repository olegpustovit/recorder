import Foundation

/// T-829: what an edit did to pacing (report) and whether the result meets a delivery profile (lint).
/// Pure: takes the source-time `Storyboard` and two projects; shots are mapped to output time through `TimeMap`.
public struct LintProfile: Equatable, Sendable {
    public var name: String
    public var hookMax: Double
    public var maxStatic: Double
    public var asl: ClosedRange<Double>
    public var duration: ClosedRange<Double>
    public var tinyShot: Double
    public static let orphanEffect = 0.5
    /// reel = spec table; tutorial/demo are looser (viewers follow along, so holds and shots run longer).
    public static let reel = LintProfile(name: "reel", hookMax: 1.0, maxStatic: 1.2, asl: 0.8...2.0, duration: 15...45, tinyShot: 0.25)
    public static let tutorial = LintProfile(name: "tutorial", hookMax: 3.0, maxStatic: 4.0, asl: 2.0...8.0, duration: 30...300, tinyShot: 0.4)
    public static let demo = LintProfile(name: "demo", hookMax: 2.0, maxStatic: 2.5, asl: 1.5...5.0, duration: 20...120, tinyShot: 0.3)
    public init(name: String, hookMax: Double, maxStatic: Double, asl: ClosedRange<Double>, duration: ClosedRange<Double>, tinyShot: Double) {
        self.name = name; self.hookMax = hookMax; self.maxStatic = maxStatic; self.asl = asl; self.duration = duration; self.tinyShot = tinyShot
    }
    public init?(name: String) {
        guard let found = [LintProfile.reel, .tutorial, .demo].first(where: { $0.name == name }) else { return nil }
        self = found
    }
}

public struct LintItem: Codable, Equatable, Sendable {
    public var rule: String
    public var sev: String
    public var at: Double            // output seconds on the edited timeline
    public var shot: String?
    public var msg: String
    public var suggest: JSONValue?   // an op the agent can pass to edit.apply as-is (output seconds of the same timeline)
}

public struct EditReport: Codable, Equatable, Sendable {
    public struct Pair: Codable, Equatable, Sendable { public var before: Double; public var after: Double }
    public struct Static: Codable, Equatable, Sendable { public var sec: Double; public var at: Double }
    public var duration: Pair
    public var aslSec: Pair            // average visual shot: timeline split at edit cuts and boundary:"cut" shots
    public var subShotAslSec: Pair?    // average analyzer shot (sub-shots inside continuous footage count)
    public var hookSec: Double?
    public var longestStatic: Static?
    public var staticSec: Pair
    public var lint: [LintItem]
    public var reframeJumps: Int?      // crop steps not at a cut (reframed projects only)
}

/// One kept piece of recorded footage on the output timeline; `speed` is the clip's absolute speed (what a `speed` op sets).
struct Piece { var range: TimeRange; var speed: Double; var scale: Double; var source = 0.0 }
extension TimeMap {
    /// Output pieces where source `[from, to]` is kept (several when the footage was copied or split); recorded clips only.
    func pieces(source from: Double, to: Double) -> [Piece] {
        var start = 0.0, result: [Piece] = []
        for c in clips {
            defer { start += c.outputDuration }
            let lo = max(from, c.sourceStart), hi = min(to, c.sourceEnd)
            guard hi - lo > 1e-9, !c.isEmpty, c.file == nil else { continue }
            result.append(Piece(range: TimeRange(start: start + (lo - c.sourceStart) / c.timeScale, end: start + (hi - c.sourceStart) / c.timeScale), speed: c.speed, scale: c.timeScale, source: lo))
        }
        return result
    }
    func outputRanges(source from: Double, to: Double) -> [TimeRange] { pieces(source: from, to: to).map(\.range) }
    /// Output times where an edit makes the picture jump: joins of clips that don't continue the same footage.
    var editCuts: [Double] {
        var t = 0.0, cuts: [Double] = []
        for (a, b) in zip(clips, clips.dropFirst()) {
            t += a.outputDuration
            if a.file != b.file || a.isEmpty || b.isEmpty || abs(a.sourceEnd - b.sourceStart) > 1e-6 { cuts.append(t) }
        }
        return cuts
    }
    /// Absolute speed of the clip playing at output time `t`.
    func speed(atOutput t: Double) -> Double {
        var start = 0.0
        for c in clips { if t < start + c.outputDuration { return c.speed }; start += c.outputDuration }
        return clips.last?.speed ?? 1
    }
}

/// A shot's kept footage; pieces of one shot that abut on the output (a clip split by an edit) count as one hold.
struct ShotSegment {
    var shot: Shot; var pieces: [Piece]
    var range: TimeRange { TimeRange(start: pieces.first!.range.start, end: pieces.last!.range.end) }
    var duration: Double { range.end - range.start }
}
extension Storyboard {
    /// Every kept occurrence of every shot in output time, sorted. Dropped shots have none; partly cut shots are shortened.
    /// Pieces under one analysis frame are leftover slivers of cut shots (rounding), not footage: lint and intents skip them.
    func segments(_ map: TimeMap) -> [ShotSegment] {
        let frame = 1 / max(fps, 1)
        return allSegments(map).filter { $0.duration >= frame - 1e-6 }
    }
    private func allSegments(_ map: TimeMap) -> [ShotSegment] {
        shots.flatMap { shot -> [ShotSegment] in
            var result: [ShotSegment] = []
            for piece in map.pieces(source: shot.from, to: shot.to).sorted(by: { $0.range.start < $1.range.start }) {
                if let last = result.last, abs(last.pieces.last!.range.end - piece.range.start) < 1e-6 { result[result.count - 1].pieces.append(piece) }
                else { result.append(ShotSegment(shot: shot, pieces: [piece])) }
            }
            return result
        }.sorted { $0.range.start < $1.range.start }
    }
}
extension Shot { var isStatic: Bool { kind == .static || kind == .cursorOnly } }

func r2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
func opJSON(_ name: String, _ fields: [String: JSONValue]) -> JSONValue {
    .object(fields.merging(["op": .string(name)]) { a, _ in a })
}
func cutJSON(_ a: Double, _ b: Double) -> JSONValue { opJSON("cut", ["from": .number(r2(a)), "to": .number(r2(b)), "snap": .bool(true)]) }

private struct Metrics {
    var duration = 0.0, asl = 0.0, subAsl = 0.0, staticSec = 0.0, hook: Double?, longest: EditReport.Static?
    var segs: [ShotSegment] = []
    var cuts: [Double] = []   // output times a viewer sees as cuts
    var frame = 0.1           // one analysis frame
    func isCut(_ t: Double) -> Bool { cuts.contains { abs($0 - t) <= frame + 1e-6 } }
}
private func metrics(_ project: Project, _ sb: Storyboard) -> Metrics {
    let map = TimeMap(project.clips)
    var m = Metrics(duration: project.exportDuration)
    m.frame = 1 / max(sb.fps, 1)
    m.segs = sb.segments(map)
    let shotCuts = m.segs.filter { $0.shot.boundary == .cut && abs($0.pieces[0].source - $0.shot.from) < 1e-6 }.map(\.range.start)
    for t in (map.editCuts + shotCuts).sorted() where t > m.frame && t < map.outputDuration - m.frame && !m.isCut(t) { m.cuts.append(t) }
    m.asl = map.outputDuration / Double(m.cuts.count + 1)
    var perShot: [String: Double] = [:]
    for s in m.segs {
        perShot[s.shot.id, default: 0] += s.duration
        guard s.shot.isStatic else { continue }
        m.staticSec += s.duration
        if s.duration > (m.longest?.sec ?? 0) { m.longest = .init(sec: r2(s.duration), at: r2(s.range.start)) }
    }
    if !perShot.isEmpty { m.subAsl = perShot.values.reduce(0, +) / Double(perShot.count) }
    // The hook is the first thing that happens: a payoff, a motion shot, or any click (an opening that animates from frame 0 counts).
    m.hook = m.segs.compactMap { s -> Double? in
        let click = s.shot.clicks.compactMap { map.outputTime(atSource: $0) }.filter { $0 >= s.range.start && $0 < s.range.end }.min()
        switch s.shot.kind { case .payoff: return click ?? s.range.start; case .motion: return s.range.start; default: return click }
    }.min()
    return m
}

/// Output seconds a project block (source time) is visible for, and where it starts.
private func visible(_ start: Double, _ end: Double, _ map: TimeMap) -> (sec: Double, at: Double)? {
    let ranges = map.outputRanges(source: start, to: end)
    guard let first = ranges.first else { return nil }
    return (ranges.reduce(0) { $0 + $1.end - $1.start }, first.start)
}

public func lint(_ project: Project, storyboard sb: Storyboard, profile: LintProfile = .reel) -> [LintItem] {
    lint(project, metrics(project, sb), sb, profile)
}

private func lint(_ project: Project, _ m: Metrics, _ sb: Storyboard, _ p: LintProfile) -> [LintItem] {
    var items: [LintItem] = []
    let map = TimeMap(project.clips)
    func shotAt(_ t: Double) -> String? { m.segs.first { $0.range.start <= t && t < $0.range.end }?.shot.id }
    if let hook = m.hook, hook > p.hookMax {
        let first = m.segs.first { $0.shot.kind == .payoff }
        items.append(LintItem(rule: "hook", sev: "warn", at: r2(hook), shot: first?.shot.id,
            msg: String(format: "first payoff at %.1fs, want <= %.1fs: cut the lead-in", hook, p.hookMax),
            suggest: hook - 0.3 > 0.1 ? cutJSON(0, hook - 0.3) : nil))
    }
    for s in m.segs {
        if s.shot.isStatic, s.shot.tag != "result", s.duration > p.maxStatic + 1e-6 {
            let factor = (s.duration / p.maxStatic * 100).rounded(.up) / 100
            let single = s.pieces.count == 1 ? s.pieces[0].speed * factor : .infinity   // speed ops set absolute speed
            items.append(LintItem(rule: "maxStatic", sev: "warn", at: r2(s.range.start), shot: s.shot.id,
                msg: String(format: "%.1fs hold with %@ only: speed up or cut %@", s.duration, s.shot.kind == .cursorOnly ? "cursor" : "no change", s.shot.id),
                suggest: factor <= 6 && single <= 16 ? opJSON("speed", ["from": .number(r2(s.range.start)), "to": .number(r2(s.range.end)), "speed": .number((single * 100).rounded(.up) / 100), "snap": .bool(true)])
                                                      : cutJSON(s.range.start + p.maxStatic, s.range.end)))
        }
        // Compare what the message prints ("0.25 s, want ≥ 0.25 s" must not fire); only a piece next to a cut flickers,
        // a sub-shot inside continuous footage does not.
        if r2(s.duration) < p.tinyShot - 1e-6, m.isCut(s.range.start) || m.isCut(s.range.end) {
            let fix = applicableCut(project, s.range.start, s.range.end)
            items.append(LintItem(rule: "tinyShot", sev: "warn", at: r2(s.range.start), shot: s.shot.id,
                msg: String(format: "%@ lasts %.2fs (flicker, want >= %.2fs)", s.shot.id, s.duration, p.tinyShot) + (fix == nil ? "; too short to cut, trim the neighbouring clip by hand" : ""),
                suggest: fix))
        }
        // Reframed projects crop per moment (T-831): sample after the 0.3 s ease, the middle and the end, so a late move shows.
        // Only a focus box that would fit the crop but pokes out of it is a framing problem; a wider one can't be fixed by moving.
        let f = s.shot.focus, tol = 0.005, d = s.shot.duration
        if [min(0.35, d / 2), d / 2, max(d - 0.05, d / 2)].map({ project.cropSample(atSource: s.shot.from + $0) }).contains(where: { c in
            c != NormRect() && f.w <= c.w && f.h <= c.h && (f.x < c.x - tol || f.y < c.y - tol || f.x + f.w > c.x + c.w + tol || f.y + f.h > c.y + c.h + tol)
        }) {
            // Keep the shape the user chose: reframe only within an explicit aspect; a manual crop (auto aspect) gets no op.
            let aspect = project.output.aspect
            items.append(LintItem(rule: "edgeContent", sev: "warn", at: r2(s.range.start), shot: s.shot.id,
                msg: "\(s.shot.id) focus box is clipped by the output crop" + (aspect == .auto ? "; move the crop" : ""),
                suggest: aspect == .auto ? nil : .object(["op": .string("reframe"), "aspect": .string(aspect.rawValue), "mode": .string("perShot")])))
        }
    }
    if !m.segs.isEmpty, !p.asl.contains(m.asl) {
        let high = m.asl > p.asl.upperBound
        items.append(LintItem(rule: "asl", sev: "info", at: 0, shot: nil,
            msg: String(format: "average shot %.2fs, want %.1f-%.1fs: %@", m.asl, p.asl.lowerBound, p.asl.upperBound, high ? "pace it" : "hold shots longer or keep fewer"),
            suggest: opJSON("pace", ["maxStatic": .number(p.maxStatic)])))
    }
    if !p.duration.contains(m.duration) {
        let long = m.duration > p.duration.upperBound
        items.append(LintItem(rule: "duration", sev: "info", at: 0, shot: nil,
            msg: String(format: "%.1fs long, want %.0f-%.0fs", m.duration, p.duration.lowerBound, p.duration.upperBound),
            suggest: long ? opJSON("fitDuration", ["target": .number(p.duration.upperBound)]) : nil))
    }
    for z in project.zooms where z.enabled {
        if let v = visible(z.start, z.end, map), v.sec < LintProfile.orphanEffect {
            items.append(LintItem(rule: "orphanEffect", sev: "warn", at: r2(v.at), shot: shotAt(v.at), msg: String(format: "zoom %@ is only %.2fs long", z.id, v.sec), suggest: opJSON("remove", ["id": .string(z.id)])))
        }
    }
    for t in project.texts where t.style != .caption {
        if let v = visible(t.start, t.end, map), v.sec < LintProfile.orphanEffect {
            items.append(LintItem(rule: "orphanEffect", sev: "warn", at: r2(v.at), shot: shotAt(v.at), msg: String(format: "text %@ is only %.2fs long", t.id, v.sec), suggest: opJSON("remove", ["id": .string(t.id)])))
        }
    }
    return items.sorted { $0.at < $1.at }
}

/// The first cut around output `[a, b]` that `edit.apply` would not skip (snapping drops slivers under its minimum length):
/// the piece itself, widened to the clip edges it nearly touches, or stretched to the minimum into the neighbouring footage.
private func applicableCut(_ project: Project, _ a: Double, _ b: Double) -> JSONValue? {
    var t = 0.0, edges = [0.0]
    for c in project.clips { t += c.outputDuration; edges.append(t) }
    let lo = edges.filter { $0 <= a + 1e-6 && a - $0 <= 0.25 }.max() ?? a, hi = edges.filter { $0 >= b - 1e-6 && $0 - b <= 0.25 }.min() ?? b
    for (x, y) in [(a, b), (lo, hi), (a, max(b, a + 0.12)), (min(a, b - 0.12), b)] where x >= 0 && y <= t {
        let op = EditOp.cut(from: .seconds(r2(x)), to: .seconds(r2(y)), snap: true)
        if let trial = try? project.applying([op], context: EditContext()), trial.changes.first?.skipped == false { return cutJSON(x, y) }
    }
    return nil
}

/// `before` is the project the edit started from, `after` the draft.
public func editReport(before: Project, after: Project, storyboard sb: Storyboard, profile: LintProfile = .reel) -> EditReport {
    let b = metrics(before, sb), a = metrics(after, sb)
    return EditReport(duration: .init(before: r2(b.duration), after: r2(a.duration)), aslSec: .init(before: r2(b.asl), after: r2(a.asl)),
                      subShotAslSec: .init(before: r2(b.subAsl), after: r2(a.subAsl)),
                      hookSec: a.hook.map(r2), longestStatic: a.longest, staticSec: .init(before: r2(b.staticSec), after: r2(a.staticSec)),
                      lint: lint(after, a, sb, profile), reframeJumps: after.cropKeys.isEmpty ? nil : cropJumps(after.cropKeys, storyboard: sb))
}
