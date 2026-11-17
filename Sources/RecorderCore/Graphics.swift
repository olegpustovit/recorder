import Foundation

/// Motion graphics (EDITING-CORE D6, T-921). A graphic is a layer (`LayerBlock.kind == .graphic`), so it gets the layer
/// machinery for free: connected timing, tracks, move/resize/settle on cuts, `keys` (whole-graphic transform),
/// `motion`/`fadeIn`/`fadeOut` entrances. The layer's `rect` is the graphic's box; elements live inside it (0–1, top-left).
public struct Graphic: Codable, Equatable, Sendable {
    /// canvas: the box is in output-canvas coordinates · screen: in source-frame coordinates, so it follows zoom and crop
    /// (a callout stays on its button through a zoom).
    public enum Space: String, Codable, Sendable, CaseIterable { case canvas, screen }
    public var space: Space
    /// Set when made from a template; editing params regenerates `elements`. nil = hand-made or detached.
    public var template: GraphicTemplate?
    public var elements: [GraphicElement]
    public init(space: Space = .canvas, template: GraphicTemplate? = nil, elements: [GraphicElement]) {
        self.space = space; self.template = template; self.elements = elements
    }
}

public struct GraphicTemplate: Codable, Equatable, Sendable {
    public var name: String
    public var params: [String: JSONValue]
    public init(name: String, params: [String: JSONValue] = [:]) { self.name = name; self.params = params }
}

public struct GraphicElement: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case rect, ellipse, line, arrow, text, image }
    public var kind: Kind
    public var frame: NormRect              // inside the graphic's box, 0–1, top-left origin
    public var points: [NormPoint]?         // line/arrow: [from, to] inside the box
    public var fill: String?                // "#RRGGBB" or "#RRGGBBAA"
    public var stroke: String?
    public var width: Double?               // stroke width, points at 1080 px output height
    public var radius: Double?              // corner radius, points at 1080 px
    public var text: String?
    public var size: Double?                // text size, points at 1080 px
    public var weight: String?              // light | regular | medium | bold
    public var align: String?               // left | center | right
    public var file: String?                // image: package-relative media/ file
    /// Seconds from the graphic's start over which the element is revealed: bars grow left→right, text types out.
    public var reveal: Double?
    /// Text only: count from [0] to [1] over `reveal` (or the whole graphic); "#" in `text` is replaced by the number.
    public var count: [Double]?
    public var keys: [Key]?                 // per-element transform, seconds since the graphic's start
    public init(kind: Kind, frame: NormRect = NormRect(), points: [NormPoint]? = nil, fill: String? = nil, stroke: String? = nil,
                width: Double? = nil, radius: Double? = nil, text: String? = nil, size: Double? = nil, weight: String? = nil,
                align: String? = nil, file: String? = nil, reveal: Double? = nil, count: [Double]? = nil, keys: [Key]? = nil) {
        self.kind = kind; self.frame = frame; self.points = points; self.fill = fill; self.stroke = stroke; self.width = width
        self.radius = radius; self.text = text; self.size = size; self.weight = weight; self.align = align; self.file = file
        self.reveal = reveal; self.count = count; self.keys = keys
    }
}

/// RGBA 0–1 from "#RRGGBB" / "#RRGGBBAA"; nil when malformed.
public func graphicColor(_ hex: String) -> (r: Double, g: Double, b: Double, a: Double)? {
    let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : ""
    guard digits.count == 6 || digits.count == 8, let value = UInt64(digits, radix: 16) else { return nil }
    let v = digits.count == 6 ? value << 8 | 0xFF : value
    return (Double(v >> 24 & 0xFF) / 255, Double(v >> 16 & 0xFF) / 255, Double(v >> 8 & 0xFF) / 255, Double(v & 0xFF) / 255)
}

/// Text an element shows at `t` seconds since the graphic's start (count-up and type-out applied).
public func graphicText(_ element: GraphicElement, at t: Double, length: Double) -> String {
    var text = element.text ?? ""
    if let count = element.count, count.count == 2 {
        let span = element.reveal ?? length, u = span > 0 ? min(1, max(0, t / span)) : 1
        let value = count[0] + (count[1] - count[0]) * eased(u, .easeOut)
        let whole = count.allSatisfy { $0 == $0.rounded() }
        let number = whole ? String(Int(value.rounded())) : String(format: "%.1f", value)
        text = text.contains("#") ? text.replacingOccurrences(of: "#", with: number) : number
    } else if let reveal = element.reveal, reveal > 0 {
        let shown = Int((Double(text.count) * min(1, max(0, t / reveal))).rounded(.down))
        text = String(text.prefix(shown))
    }
    return text
}

/// Fraction 0–1 of a non-text element revealed at `t` (1 when it has no reveal).
public func graphicReveal(_ element: GraphicElement, at t: Double) -> Double {
    guard let reveal = element.reveal, reveal > 0, element.kind != .text else { return 1 }
    return eased(min(1, max(0, t / reveal)), .easeInOut)
}

/// nil when the graphic is drawable; otherwise the first problem (checked by `checkInvariants`).
public func graphicError(_ g: Graphic, length: Double) -> String? {
    guard !g.elements.isEmpty else { return "has no elements" }
    for (i, e) in g.elements.enumerated() {
        let f = e.frame
        guard [f.x, f.y, f.w, f.h].allSatisfy(\.isFinite), f.w >= 0, f.h >= 0, f.x >= -1, f.y >= -1, f.x + f.w <= 2, f.y + f.h <= 2 else { return "element \(i) frame invalid" }
        if e.kind == .line || e.kind == .arrow {
            guard let p = e.points, p.count == 2, p.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return "element \(i) \(e.kind.rawValue) needs points [from, to]" }
        }
        for color in [e.fill, e.stroke].compactMap({ $0 }) where graphicColor(color) == nil { return "element \(i) colour \(color) is not #RRGGBB[AA]" }
        if e.kind == .text, (e.text ?? "").isEmpty && e.count == nil { return "element \(i) text is empty" }
        if e.kind == .image, !(e.file ?? "").hasPrefix("media/") || (e.file ?? "").split(separator: "/").contains("..") { return "element \(i) image needs a media/ file" }
        if let size = e.size, !(4...400).contains(size) { return "element \(i) size must be 4–400" }
        if let width = e.width, !(0...100).contains(width) { return "element \(i) width must be 0–100" }
        if let radius = e.radius, !(0...1000).contains(radius) { return "element \(i) radius must be 0–1000" }
        if let weight = e.weight, !["light", "regular", "medium", "bold"].contains(weight) { return "element \(i) weight must be light, regular, medium or bold" }
        if let align = e.align, !["left", "center", "right"].contains(align) { return "element \(i) align must be left, center or right" }
        if let reveal = e.reveal, !(reveal.isFinite && reveal > 0) { return "element \(i) reveal must be > 0 seconds" }
        if let count = e.count, count.count != 2 || !count.allSatisfy(\.isFinite) { return "element \(i) count must be [from, to]" }
        if let keys = e.keys, let k = keysError(keys, length: length) { return "element \(i) \(k)" }
    }
    return nil
}

public extension Project {
    /// Adds a graphic layer at output `time` (one undo step for callers using `EditorModel.edit`). nil when it doesn't fit.
    @discardableResult
    mutating func addGraphic(_ graphic: Graphic, atOutput time: Double, duration: Double, rect: NormRect, track: Int = 0) -> UUID? {
        let before = self
        guard graphicError(graphic, length: duration) == nil,
              // placed as a still (same timing/track rules), then given its payload: invariants need both together
              let id = addLayer(kind: .image, file: "media/graphic", atOutput: time, duration: duration, rect: rect, track: track),
              let i = layers.firstIndex(where: { $0.id == id.uuidString }) else { self = before; return nil }
        layers[i].kind = .graphic
        layers[i].file = ""
        layers[i].graphic = graphic
        layers[i].backdrop = .none
        guard checkInvariants() == nil else { self = before; return nil }
        return id
    }
}
