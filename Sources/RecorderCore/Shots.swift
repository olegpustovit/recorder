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
