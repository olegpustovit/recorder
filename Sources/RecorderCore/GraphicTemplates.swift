import Foundation

/// Graphic templates (T-922): pure `(params, length) -> Graphic + box`, like intent ops lowering to primitives. The result
/// stores `template` so the inspector can re-edit params; `catalog` feeds `project.templates` and the template menu.
public struct GraphicTemplateInfo: Codable, Equatable, Sendable {
    public var name: String, summary: String, params: [String: String], example: [String: JSONValue]
}

public enum GraphicTemplates {
    static let paper = "#F4F3EE", ink = "#141414", plate = "#080808E6"

    public static let catalog: [GraphicTemplateInfo] = [
        .init(name: "titleCard", summary: "Centred title on a dark plate (canvas).", params: ["text": "title", "subtitle": "optional second line"],
              example: ["text": .string("Golden Island"), "subtitle": .string("Building a map editor")]),
        .init(name: "callout", summary: "Ring on a point with an arrow and label; follows zoom (screen).", params: ["text": "label", "x": "target 0–1 (source frame)", "y": "target 0–1"],
              example: ["text": .string("Add a node"), "x": .number(0.62), "y": .number(0.38)]),
        .init(name: "stepBadge", summary: "Numbered disc on a point; follows zoom (screen).", params: ["text": "number or short label", "x": "0–1", "y": "0–1"],
              example: ["text": .string("2"), "x": .number(0.3), "y": .number(0.3)]),
        .init(name: "spotlight", summary: "Outline around a region; follows zoom (screen).", params: ["x": "left 0–1", "y": "top 0–1", "w": "width", "h": "height"],
              example: ["x": .number(0.5), "y": .number(0.3), "w": .number(0.3), "h": .number(0.2)]),
        .init(name: "progressBar", summary: "Bar along the bottom that fills over the graphic's length (canvas).", params: [:], example: [:]),
        .init(name: "counter", summary: "Number counting up; '#' in text is the number (canvas).", params: ["from": "start", "to": "end", "text": "e.g. '# tiles'", "x": "centre 0–1", "y": "centre 0–1"],
              example: ["from": .number(0), "to": .number(1240), "text": .string("# tiles")]),
    ]

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case unknown(String), param(String)
        public var description: String {
            switch self {
            case .unknown(let n): "unknown template \(n); use one of \(GraphicTemplates.catalog.map(\.name).joined(separator: ", "))"
            case .param(let m): m
            }
        }
    }

    /// The graphic and its layer box (normalised output canvas for canvas space, source frame for screen space).
    public static func make(_ name: String, params: [String: JSONValue], length: Double) throws -> (graphic: Graphic, rect: NormRect) {
        guard let info = catalog.first(where: { $0.name == name }) else { throw Failure.unknown(name) }
        if let extra = params.keys.sorted().first(where: { info.params[$0] == nil }) {
            throw Failure.param("\(name) does not take \(extra); params: \(info.params.keys.sorted().joined(separator: ", "))")
        }
        func text(_ key: String, _ fallback: String) throws -> String {
            guard let value = params[key] else { return fallback }
            guard case .string(let s) = value, !s.isEmpty else { throw Failure.param("\(name).\(key) must be a non-empty string") }
            return s
        }
        func number(_ key: String, _ fallback: Double, _ range: ClosedRange<Double> = 0...1) throws -> Double {
            guard let value = params[key] else { return fallback }
            guard case .number(let n) = value, n.isFinite, range.contains(n) else { throw Failure.param("\(name).\(key) must be a number in \(range.lowerBound)–\(range.upperBound)") }
            return n
        }
        let full = NormRect()
        var graphic: Graphic, rect: NormRect
        switch name {
        case "titleCard":
            let subtitle = params["subtitle"] == nil ? nil : try text("subtitle", "")
            rect = NormRect(x: 0.15, y: 0.36, w: 0.7, h: 0.28)
            var elements = [GraphicElement(kind: .rect, fill: plate, radius: 10),
                            GraphicElement(kind: .text, frame: NormRect(x: 0.05, y: subtitle == nil ? 0.25 : 0.14, w: 0.9, h: 0.5), fill: paper,
                                           text: try text("text", "Title"), size: 64, weight: "light", align: "center")]
            if let subtitle {
                elements.append(GraphicElement(kind: .text, frame: NormRect(x: 0.05, y: 0.62, w: 0.9, h: 0.26), fill: "#B8B8B2", text: subtitle, size: 28, weight: "regular", align: "center"))
            }
            graphic = Graphic(space: .canvas, elements: elements)
        case "callout":
            let x = try number("x", 0.5), y = try number("y", 0.5), label = try text("text", "Look here")
            let left = x > 0.5   // label on the side with more room
            let lx = left ? max(0.02, x - 0.36) : min(0.7, x + 0.08), ly = max(0.02, y - 0.16)
            rect = full
            graphic = Graphic(space: .screen, elements: [
                GraphicElement(kind: .ellipse, frame: NormRect(x: x - 0.035, y: y - 0.06, w: 0.07, h: 0.12), stroke: paper, width: 4),
                GraphicElement(kind: .arrow, points: [NormPoint(x: left ? lx + 0.28 : lx, y: ly + 0.07), NormPoint(x: left ? x - 0.03 : x + 0.03, y: y - 0.04)], stroke: paper, width: 4),
                GraphicElement(kind: .rect, frame: NormRect(x: lx, y: ly, w: 0.28, h: 0.07), fill: paper, radius: 6),
                GraphicElement(kind: .text, frame: NormRect(x: lx + 0.015, y: ly + 0.008, w: 0.25, h: 0.055), fill: ink, text: label, size: 30, weight: "medium", align: "left"),
            ])
        case "stepBadge":
            let x = try number("x", 0.5), y = try number("y", 0.5)
            rect = full
            graphic = Graphic(space: .screen, elements: [
                GraphicElement(kind: .ellipse, frame: NormRect(x: x - 0.025, y: y - 0.044, w: 0.05, h: 0.088), fill: paper),
                GraphicElement(kind: .text, frame: NormRect(x: x - 0.025, y: y - 0.03, w: 0.05, h: 0.06), fill: ink, text: try text("text", "1"), size: 36, weight: "medium", align: "center"),
            ])
        case "spotlight":
            let x = try number("x", 0.35), y = try number("y", 0.35), w = try number("w", 0.3), h = try number("h", 0.3)
            guard x + w <= 1, y + h <= 1, w > 0, h > 0 else { throw Failure.param("spotlight region must lie inside 0–1") }
            rect = full
            graphic = Graphic(space: .screen, elements: [GraphicElement(kind: .rect, frame: NormRect(x: x, y: y, w: w, h: h), stroke: paper, width: 4, radius: 8)])
        case "progressBar":
            rect = NormRect(x: 0.1, y: 0.93, w: 0.8, h: 0.012)
            graphic = Graphic(space: .canvas, elements: [GraphicElement(kind: .rect, fill: "#F4F3EE40", radius: 3),
                                                        GraphicElement(kind: .rect, fill: paper, radius: 3, reveal: max(0.1, length))])
        case "counter":
            let x = try number("x", 0.5), y = try number("y", 0.5), from = try number("from", 0, -1e9...1e9), to = try number("to", 100, -1e9...1e9)
            rect = NormRect(x: min(max(0, x - 0.25), 0.5), y: min(max(0, y - 0.07), 0.86), w: 0.5, h: 0.14)
            graphic = Graphic(space: .canvas, elements: [GraphicElement(kind: .text, fill: paper, text: try text("text", "#"), size: 72, weight: "light", align: "center",
                                                                        reveal: min(1.5, max(0.1, length)), count: [from, to])])
        default: throw Failure.unknown(name)
        }
        graphic.template = GraphicTemplate(name: name, params: params)
        return (graphic, rect)
    }
}
