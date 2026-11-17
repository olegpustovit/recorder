import Foundation

/// One time-varying crop sample (T-831): `rect` is the source crop window at source second `t`; keys interpolate linearly.
public struct CropKey: Codable, Equatable, Sendable {
    public var t: Double
    public var rect: NormRect
    public init(t: Double, rect: NormRect) { self.t = t; self.rect = rect }
}

public enum ReframeMode: String, Codable, Sendable { case perShot, `static` }

public extension Project {
    /// The crop at source time `t`: `cropKeys` interpolated (held outside their span), else the static `crop`.
    /// Preview and export both call this through `makeFrameState`, so they sample identically.
    func cropSample(atSource t: Double) -> NormRect {
        guard let first = cropKeys.first, let last = cropKeys.last else { return crop }
        if t <= first.t { return first.rect }
        if t >= last.t { return last.rect }
        let i = cropKeys.lastIndex { $0.t <= t }!
        let a = cropKeys[i], b = cropKeys[i + 1]
        let u = (t - a.t) / max(b.t - a.t, 1e-9)
        func mix(_ x: Double, _ y: Double) -> Double { x + (y - x) * u }
        return NormRect(x: mix(a.rect.x, b.rect.x), y: mix(a.rect.y, b.rect.y), w: mix(a.rect.w, b.rect.w), h: mix(a.rect.h, b.rect.h))
    }
}

/// A source-normalized point in the space of `crop` (0…1 inside the window, may fall outside when the point is cropped away).
/// The compositor's `ViewTransform` centres are crop-normalized, so cursor follow must pass through this (preview and export share it).
public func cropSpace(x: Double, y: Double, in crop: NormRect) -> (Double, Double) {
    ((x - crop.x) / max(crop.w, 1e-9), (y - crop.y) / max(crop.h, 1e-9))
}

/// AutoFlip-style crop plan. Every window has the output aspect and the largest size that fits the source, clamped inside
/// the frame. Per shot: stationary on `focus ∪ cursor` when it fits the window, else a linear pan from the focus's
/// leading edge to its trailing edge (centred on the axis that fits). `static` = one window over every shot's focus.
public func reframePlan(storyboard: Storyboard, aspect: Output.Aspect, mode: ReframeMode, sourceSize: CGSize) -> [CropKey] {
    guard let ratio = aspect.ratio, sourceSize.width > 0, sourceSize.height > 0, !storyboard.shots.isEmpty else { return [] }
    let src = sourceSize.width / sourceSize.height
    let w = ratio >= src ? 1 : ratio / src, h = ratio >= src ? src / ratio : 1
    func focus(_ shot: Shot) -> NormRect {
        // A span covering (almost) the whole axis, e.g. the default full-frame focus, says nothing: collapse to the cursor, else the centre.
        // A focus covering most of an axis is no target at all: centre it rather than chase the cursor.
        func axis(_ lo: Double, _ len: Double, _ c: Double?) -> (Double, Double) {
            if len >= 0.8 { return (0.5, 0) }
            let a = min(lo, c ?? lo), b = max(lo + len, c ?? lo + len)
            return b - a >= 0.9 ? (c ?? 0.5, 0) : (a, b - a)
        }
        let f = shot.focus
        let (x, w) = axis(f.x, f.w, shot.cursor?.x), (y, h) = axis(f.y, f.h, shot.cursor?.y)
        return NormRect(x: x, y: y, w: w, h: h)
    }
    // Window origin along one axis for a focus span [lo, hi] in a window of size `size`: (start, end) positions.
    func place(_ lo: Double, _ hi: Double, _ size: Double, hold: Bool) -> (Double, Double) {
        func clamp(_ v: Double) -> Double { min(max(v, 0), 1 - size) }
        let mid = clamp((lo + hi) / 2 - size / 2)
        return hold || hi - lo <= size + 1e-9 ? (mid, mid) : (clamp(lo), clamp(hi - size))
    }
    func rects(_ f: NormRect, hold: Bool = false) -> (NormRect, NormRect) {
        let (x0, x1) = place(f.x, f.x + f.w, w, hold: hold), (y0, y1) = place(f.y, f.y + f.h, h, hold: hold)
        return (NormRect(x: x0, y: y0, w: w, h: h), NormRect(x: x1, y: y1, w: w, h: h))
    }
    if mode == .static {
        let fs = storyboard.shots.map(focus)
        let x0 = fs.map(\.x).min()!, y0 = fs.map(\.y).min()!, x1 = fs.map { $0.x + $0.w }.max()!, y1 = fs.map { $0.y + $0.h }.max()!
        return [CropKey(t: 0, rect: rects(NormRect(x: x0, y: y0, w: x1 - x0, h: y1 - y0), hold: true).0)]
    }
    // Never worse than the default centre crop: a window that shows less of the shot's focus box falls back to the centre.
    let centre = NormRect(x: (1 - w) / 2, y: (1 - h) / 2, w: w, h: h)
    func shown(_ f: NormRect, _ r: NormRect) -> Double {
        max(0, min(f.x + f.w, r.x + r.w) - max(f.x, r.x)) * max(0, min(f.y + f.h, r.y + r.h) - max(f.y, r.y))
    }
    func guarded(_ r: NormRect, _ f: NormRect) -> NormRect { shown(f, r) + 1e-9 < shown(f, centre) ? centre : r }
    var keys: [CropKey] = []
    for shot in storyboard.shots {
        var (a, b) = rects(focus(shot))
        (a, b) = (guarded(a, shot.focus), guarded(b, shot.focus))
        if let prev = keys.last?.rect {
            // Hysteresis: a window within 3 % of the current one that shows as much of the focus keeps the current one (no twitch).
            if abs(a.x - prev.x) <= 0.03, abs(a.y - prev.y) <= 0.03, shown(shot.focus, prev) + 1e-9 >= shown(shot.focus, a) {
                if a == b { b = prev }
                a = prev
            }
        }
        // A cut may jump (`cropSample` takes the later of two keys at one t); continuous footage eases over 0.3 s instead.
        let ease = keys.isEmpty || shot.boundary == .cut || a == keys.last!.rect ? 0 : min(0.3, shot.duration / 2)
        keys += [CropKey(t: shot.from + ease, rect: a), CropKey(t: shot.to, rect: b)]
    }
    return keys
}

/// Crop steps (two keys at one instant with different windows) at a shot boundary that is not a visual cut: a visible lurch.
public func cropJumps(_ keys: [CropKey], storyboard: Storyboard) -> Int {
    zip(keys, keys.dropFirst()).filter { k, n in
        abs(k.t - n.t) < 1e-6 && k.rect != n.rect && !storyboard.shots.contains { abs($0.from - n.t) < 1e-6 && $0.boundary == .cut }
    }.count
}
