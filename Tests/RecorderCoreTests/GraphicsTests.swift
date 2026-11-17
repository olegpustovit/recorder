import Foundation
import Testing
@testable import RecorderCore

/// T-921: graphics are layers with a payload: placement, validation, persistence, edits and text helpers.
@Suite struct GraphicsTests {
    static let card = Graphic(elements: [GraphicElement(kind: .rect, fill: "#080808E0", radius: 12),
                                         GraphicElement(kind: .text, frame: NormRect(x: 0.1, y: 0.3, w: 0.8, h: 0.4), fill: "#F4F3EE", text: "Golden Island", size: 64, weight: "light", align: "center")])
    func base() -> Project { Project(source: Source(duration: 20), clips: [Clip(sourceStart: 0, sourceEnd: 20)]) }

    @Test func graphicIsAConnectedLayer() throws {
        var p = base()
        let added = p.addGraphic(Self.card, atOutput: 2, duration: 3, rect: NormRect(x: 0.2, y: 0.3, w: 0.6, h: 0.3))
        let id = try #require(added)
        let layer = try #require(p.layers.first { $0.id == id.uuidString })
        #expect(layer.kind == .graphic && layer.graphic == Self.card && !layer.hasMedia && p.checkInvariants() == nil)
        #expect(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(p)) == p)
        let item = try #require(items(p).first { $0.id == id.uuidString })
        #expect(item.kind == .graphic && item.media == nil && item.out == TimeRange(start: 2, end: 5) && !item.editable.contains("mediaStart"))
        #expect(uncoveredRanges(p).isEmpty)                                    // a graphic never counts as coverage
        // Connected: a cut before it ripples it earlier; set moves it; remove deletes it.
        let cut = try p.applying([.cut(from: 0, to: 1)], context: EditContext()).project
        #expect(items(cut).first { $0.id == id.uuidString }?.out == TimeRange(start: 1, end: 4))
        let moved = try p.applying([.set(id: id.uuidString, fields: SetFields(from: 6, to: 8))], context: EditContext()).project
        #expect(items(moved).first { $0.id == id.uuidString }?.out == TimeRange(start: 6, end: 8))
        do { _ = try p.applying([.set(id: id.uuidString, fields: SetFields(mediaStart: 1))], context: EditContext()); Issue.record("mediaStart on a graphic") }
        catch { #expect("\(error)".contains("graphic does not take mediaStart")) }
        #expect(try p.applying([.remove(id: id.uuidString)], context: EditContext()).project.layers.isEmpty)
        #expect(agentTimeline(p).blocks.contains { $0.lane == "graphic" })
    }

    @Test func validation() {
        func bad(_ e: GraphicElement) -> String? { graphicError(Graphic(elements: [e]), length: 3) }
        #expect(graphicError(Graphic(elements: []), length: 3) == "has no elements")
        #expect(bad(GraphicElement(kind: .arrow)) == "element 0 arrow needs points [from, to]")
        #expect(bad(GraphicElement(kind: .rect, fill: "red"))?.contains("#RRGGBB") == true)
        #expect(bad(GraphicElement(kind: .text)) == "element 0 text is empty")
        #expect(bad(GraphicElement(kind: .text, text: "a", weight: "heavy")) != nil)
        #expect(bad(GraphicElement(kind: .rect, keys: [Key(t: 9, opacity: 1)])) == "element 0 key 0 outside the item")
        var p = base()
        let none = p.addGraphic(Graphic(elements: []), atOutput: 1, duration: 2, rect: NormRect())
        #expect(none == nil && p.layers.isEmpty)
    }

    @Test func textCountsTypesAndColoursParse() {
        let counter = GraphicElement(kind: .text, text: "# tiles", count: [0, 1240])
        #expect(graphicText(counter, at: 0, length: 2) == "0 tiles" && graphicText(counter, at: 2, length: 2) == "1240 tiles")
        let typed = GraphicElement(kind: .text, text: "Hello", reveal: 1)
        #expect(graphicText(typed, at: 0, length: 3) == "" && graphicText(typed, at: 0.5, length: 3) == "He" && graphicText(typed, at: 5, length: 3) == "Hello")
        #expect(graphicReveal(GraphicElement(kind: .rect, reveal: 2), at: 1) == 0.5 && graphicReveal(GraphicElement(kind: .rect), at: 0) == 1)
        #expect(graphicColor("#FF000080")! == (1, 0, 0, 128.0 / 255) && graphicColor("#00FF00")!.a == 1 && graphicColor("FF0000") == nil)
    }
}

/// T-922: every template builds a valid graphic from its own example and defaults; bad params name the valid ones.
@Test func templatesBuildValidGraphics() throws {
    for info in GraphicTemplates.catalog {
        for params in [info.example, [:]] {
            let made = try GraphicTemplates.make(info.name, params: params, length: 3)
            #expect(graphicError(made.graphic, length: 3) == nil, "\(info.name)")
            #expect(made.graphic.template?.name == info.name && made.rect.w > 0 && made.rect.h > 0)
            var p = Project(source: Source(duration: 20), clips: [Clip(sourceStart: 0, sourceEnd: 20)])
            let id = p.addGraphic(made.graphic, atOutput: 1, duration: 3, rect: made.rect)
            #expect(id != nil && p.checkInvariants() == nil, "\(info.name) does not place")
        }
    }
    #expect(try GraphicTemplates.make("callout", params: ["x": .number(0.8)], length: 2).graphic.space == .screen)
    #expect(throws: GraphicTemplates.Failure.self) { try GraphicTemplates.make("nope", params: [:], length: 2) }
    do { _ = try GraphicTemplates.make("callout", params: ["colour": .string("red")], length: 2); Issue.record("unknown param") }
    catch { #expect("\(error)".contains("params: text, x, y")) }
    #expect(throws: GraphicTemplates.Failure.self) { try GraphicTemplates.make("stepBadge", params: ["x": .number(2)], length: 2) }
}

/// T-925: `graphic` and `animate` ops — JSON in, one change each, replayable, strict errors.
@Test func graphicAndAnimateOps() throws {
    var base = Project(source: Source(duration: 20), clips: [Clip(sourceStart: 0, sourceEnd: 20)])
    base.texts = [TextBlock(id: "t", start: 8, end: 10, text: "Hi")]
    let json = #"""
    [{"op":"graphic","from":1,"to":4,"template":{"name":"callout","params":{"text":"Add a node","x":0.62,"y":0.38}},"keys":[{"t":0,"opacity":0},{"t":0.3,"opacity":1}]},
     {"op":"graphic","from":5,"to":7,"elements":[{"kind":"rect","frame":{"x":0,"y":0,"w":1,"h":1},"fill":"#080808E6","radius":8},{"kind":"text","frame":{"x":0,"y":0,"w":1,"h":1},"fill":"#F4F3EE","text":"Hello"}],"rect":{"x":0.3,"y":0.4,"w":0.4,"h":0.2}},
     {"op":"animate","id":"t","keys":[{"t":0,"y":0.1,"opacity":0},{"t":0.4,"y":0,"opacity":1,"ease":"spring"}]}]
    """#
    let ops = try JSONDecoder().decode([EditOp].self, from: Data(json.utf8))
    #expect(try JSONDecoder().decode([EditOp].self, from: JSONEncoder().encode(ops)) == ops)
    let context = EditContext(operationSeeds: ["a", "b", "c"])
    let r = try base.applying(ops, context: context)
    let graphics = r.project.layers.filter { $0.kind == .graphic }
    #expect(graphics.count == 2 && r.changes.count == 3 && r.project.checkInvariants() == nil, "\(graphics.map { ($0.rect, $0.keys as Any, $0.start) }) \(r.changes.count)")
    #expect(graphics[0].graphic?.template?.name == "callout" && graphics[0].graphic?.space == .screen && graphics[0].keys?.count == 2)
    #expect(graphics[1].rect == NormRect(x: 0.3, y: 0.4, w: 0.4, h: 0.2) && graphics[1].graphic?.template == nil)
    #expect(r.project.texts[0].keys?.last?.ease == .spring)
    #expect(agentTimeline(r.project).blocks.filter { $0.lane == "graphic" }.count == 2)
    #expect(try base.applying(ops, context: context).project == r.project)                      // replay is deterministic
    let cleared = try r.project.applying([.animate(id: "t", keys: [])], context: EditContext()).project
    #expect(cleared.texts[0].keys == nil)
    func fails(_ json: String, _ text: String) {
        do { _ = try base.applying(JSONDecoder().decode([EditOp].self, from: Data(json.utf8)), context: EditContext()); Issue.record("accepted \(json)") }
        catch { #expect("\(error)".contains(text), "\(error)") }
    }
    fails(#"[{"op":"graphic","from":1,"to":3}]"#, "exactly one of template or elements")
    fails(#"[{"op":"graphic","from":1,"to":3,"template":{"name":"nope","params":{}}}]"#, "unknown template nope")
    fails(#"[{"op":"graphic","from":1,"to":3,"template":{"name":"stepBadge","params":{"x":4}}}]"#, "stepBadge.x")
    fails(#"[{"op":"graphic","from":1,"to":3,"elements":[{"kind":"arrow","frame":{"x":0,"y":0,"w":1,"h":1}}]}]"#, "needs points")
    fails(#"[{"op":"graphic","from":1,"to":3,"template":{"name":"titleCard","params":{}},"keys":[{"t":9,"opacity":1}]}]"#, "outside the item")
    fails(#"[{"op":"animate","id":"nope","keys":[]}]"#, "unknown item nope")
}
