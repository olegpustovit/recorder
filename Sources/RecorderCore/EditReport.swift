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
    public var aslSec: Pair
    public var hookSec: Double?
    public var longestStatic: Static?
    public var staticSec: Pair
    public var lint: [LintItem]
}

/// One kept piece of recorded footage on the output timeline; `speed` is the clip's absolute speed (what a `speed` op sets).
struct Piece { var range: TimeRange; var speed: Double; var scale: Double }
extension TimeMap {
    /// Output pieces where source `[from, to]` is kept (several when the footage was copied or split); recorded clips only.
    func pieces(source from: Double, to: Double) -> [Piece] {
        var start = 0.0, result: [Piece] = []
        for c in clips {
            defer { start += c.outputDuration }
            let lo = max(from, c.sourceStart), hi = min(to, c.sourceEnd)
            guard hi - lo > 1e-9, !c.isEmpty, c.file == nil else { continue }
            result.append(Piece(range: TimeRange(start: start + (lo - c.sourceStart) / c.timeScale, end: start + (hi - c.sourceStart) / c.timeScale), speed: c.speed, scale: c.timeScale))
        }
        return result
    }
    func outputRanges(source from: Double, to: Double) -> [TimeRange] { pieces(source: from, to: to).map(\.range) }
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
    func segments(_ map: TimeMap) -> [ShotSegment] {
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
    var duration = 0.0, asl = 0.0, staticSec = 0.0, hook: Double?, longest: EditReport.Static?
    var segs: [ShotSegment] = []
}
private func metrics(_ project: Project, _ sb: Storyboard) -> Metrics {
    let map = TimeMap(project.clips)
    var m = Metrics(duration: project.exportDuration)
    m.segs = sb.segments(map)
    var perShot: [String: Double] = [:]
    for s in m.segs {
        perShot[s.shot.id, default: 0] += s.duration
        guard s.shot.isStatic else { continue }
        m.staticSec += s.duration
        if s.duration > (m.longest?.sec ?? 0) { m.longest = .init(sec: r2(s.duration), at: r2(s.range.start)) }
    }
    if !perShot.isEmpty { m.asl = perShot.values.reduce(0, +) / Double(perShot.count) }
    m.hook = m.segs.filter { $0.shot.kind == .payoff }.map { s in
        s.shot.clicks.compactMap { map.outputTime(atSource: $0) }.min() ?? s.range.start
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
        if s.duration < p.tinyShot - 1e-6 {
            items.append(LintItem(rule: "tinyShot", sev: "warn", at: r2(s.range.start), shot: s.shot.id,
                msg: String(format: "%@ lasts %.2fs (flicker, want >= %.2fs)", s.shot.id, s.duration, p.tinyShot),
                suggest: cutJSON(s.range.start, s.range.end)))
        }
        // Reframed projects crop per moment (T-831); sample the window at the shot's middle.
        let f = s.shot.focus, c = project.cropSample(atSource: (s.shot.from + s.shot.to) / 2), tol = 0.005
        // Only a focus box that would fit the crop but pokes out of it is a framing problem; a wider one can't be fixed by moving.
        if c != NormRect(), f.w <= c.w, f.h <= c.h, f.x < c.x - tol || f.y < c.y - tol || f.x + f.w > c.x + c.w + tol || f.y + f.h > c.y + c.h + tol {
            let aspect = project.output.aspect == .auto ? "16:9" : project.output.aspect.rawValue
            items.append(LintItem(rule: "edgeContent", sev: "warn", at: r2(s.range.start), shot: s.shot.id,
                msg: "\(s.shot.id) focus box is clipped by the output crop",
                suggest: .object(["op": .string("reframe"), "aspect": .string(aspect), "mode": .string("perShot")])))
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

/// `before` is the project the edit started from, `after` the draft.
public func editReport(before: Project, after: Project, storyboard sb: Storyboard, profile: LintProfile = .reel) -> EditReport {
    let b = metrics(before, sb), a = metrics(after, sb)
    return EditReport(duration: .init(before: r2(b.duration), after: r2(a.duration)), aslSec: .init(before: r2(b.asl), after: r2(a.asl)),
                      hookSec: a.hook.map(r2), longestStatic: a.longest, staticSec: .init(before: r2(b.staticSec), after: r2(a.staticSec)),
                      lint: lint(after, a, sb, profile))
}
