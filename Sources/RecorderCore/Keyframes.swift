import Foundation

/// Lottie-lite keyframes (EDITING-CORE D5, T-920): one key sets any subset of the transform properties at item-local
/// time `t` (seconds since the item's start on its own clock: spine seconds for texts, output seconds for layers and
/// graphics). Each property interpolates between the neighbouring keys that set it, so "fade in" and "move" can be
/// keyed independently. Pure function of time: any frame renders without playback history (preview/export parity).
public struct Key: Codable, Equatable, Sendable {
    public enum Ease: String, Codable, Sendable, CaseIterable { case linear, hold, easeIn, easeOut, easeInOut, spring }
    public var t: Double
    public var x: Double?, y: Double?, scale: Double?, rotation: Double?, opacity: Double?
    /// How the value leaves this key towards the next one that sets the same property (nil = easeInOut).
    public var ease: Ease?
    public init(t: Double, x: Double? = nil, y: Double? = nil, scale: Double? = nil, rotation: Double? = nil, opacity: Double? = nil, ease: Ease? = nil) {
        self.t = t; self.x = x; self.y = y; self.scale = scale; self.rotation = rotation; self.opacity = opacity; self.ease = ease
    }
}

/// x/y: normalised 0–1 offset of the item's anchor (top-left origin); scale 1 = as placed; rotation in degrees; opacity 0–1.
public struct Transform: Equatable, Sendable {
    public var x: Double, y: Double, scale: Double, rotation: Double, opacity: Double
    public init(x: Double = 0, y: Double = 0, scale: Double = 1, rotation: Double = 0, opacity: Double = 1) {
        self.x = x; self.y = y; self.scale = scale; self.rotation = rotation; self.opacity = opacity
    }
}

/// Eased progress 0…1 → 0…1. `spring` is a critically-damped settle with a light overshoot that lands exactly on 1.
// shortcut: closed-form spring curve, not `Spring`'s simulated presets (those are velocity-driven 240 Hz tables); switch if
// keyed motion must match zoom springs frame for frame.
public func eased(_ u: Double, _ ease: Key.Ease) -> Double {
    let u = min(1, max(0, u))
    switch ease {
    case .linear: return u
    case .hold: return u < 1 ? 0 : 1
    case .easeIn: return u * u * u
    case .easeOut: return 1 - pow(1 - u, 3)
    case .easeInOut: return u < 0.5 ? 4 * u * u * u : 1 - pow(-2 * u + 2, 3) / 2
    case .spring:
        let raw = { (v: Double) in 1 - exp(-6 * v) * cos(9 * v) }
        return raw(u) + (1 - raw(1)) * u
    }
}

public func evaluate(_ keys: [Key], base: Transform = Transform(), at t: Double) -> Transform {
    var out = base
    func value(_ property: KeyPath<Key, Double?>) -> Double? {
        let set = keys.filter { $0[keyPath: property] != nil }
        guard let first = set.first, let last = set.last else { return nil }
        if t <= first.t { return first[keyPath: property] }
        if t >= last.t { return last[keyPath: property] }
        let i = set.firstIndex { $0.t > t }!, a = set[i - 1], b = set[i]
        let va = a[keyPath: property]!, vb = b[keyPath: property]!
        return va + (vb - va) * eased((t - a.t) / max(b.t - a.t, 1e-9), a.ease ?? .easeInOut)
    }
    if let v = value(\.x) { out.x = v }
    if let v = value(\.y) { out.y = v }
    if let v = value(\.scale) { out.scale = v }
    if let v = value(\.rotation) { out.rotation = v }
    if let v = value(\.opacity) { out.opacity = v }
    return out
}

/// nil when `keys` are valid for an item `length` seconds long: sorted, inside the item, finite, scale > 0, opacity 0–1.
public func keysError(_ keys: [Key], length: Double) -> String? {
    for (i, k) in keys.enumerated() {
        guard k.t.isFinite, k.t >= -1e-9, k.t <= length + 1e-9 else { return "key \(i) outside the item" }
        if i > 0, k.t < keys[i - 1].t { return "keys not sorted by t" }
        let values = [k.x, k.y, k.scale, k.rotation, k.opacity].compactMap { $0 }
        guard values.allSatisfy(\.isFinite), !values.isEmpty else { return "key \(i) sets no finite value" }
        if let s = k.scale, s <= 0 { return "key \(i) scale must be > 0" }
        if let o = k.opacity, !(0...1).contains(o) { return "key \(i) opacity must be 0–1" }
    }
    return nil
}
