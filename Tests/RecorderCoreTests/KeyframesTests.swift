import Foundation
import Testing
@testable import RecorderCore

/// T-920: per-property interpolation, eases, clamping, validation and persistence.
@Suite struct KeyframesTests {
    @Test func propertiesInterpolateBetweenTheirOwnKeys() {
        let keys = [Key(t: 0, scale: 0.5, opacity: 0, ease: .linear), Key(t: 1, opacity: 1, ease: .linear), Key(t: 2, scale: 1.5)]
        #expect(evaluate(keys, at: -1) == Transform(scale: 0.5, opacity: 0))        // before the first key: hold
        #expect(evaluate(keys, at: 0.5).opacity == 0.5)
        #expect(evaluate(keys, at: 1).scale == 1.0)                                 // scale skips the opacity-only key
        #expect(evaluate(keys, at: 3) == Transform(scale: 1.5, opacity: 1))         // after the last: hold
        #expect(evaluate([Key(t: 0, x: 0.2)], base: Transform(y: 0.4), at: 9) == Transform(x: 0.2, y: 0.4))
    }

    @Test func easesStartAtZeroAndLandOnOne() {
        for ease in Key.Ease.allCases {
            #expect(eased(0, ease) == 0 && abs(eased(1, ease) - 1) < 1e-12, "\(ease)")
        }
        #expect(eased(0.99, .hold) == 0 && eased(0.5, .easeIn) < 0.5 && eased(0.5, .easeOut) > 0.5 && abs(eased(0.5, .easeInOut) - 0.5) < 1e-12)
        #expect((0...100).map { eased(Double($0) / 100, .spring) }.max()! > 1)       // the spring overshoots before settling
    }

    @Test func validationAndPersistence() throws {
        #expect(keysError([Key(t: 0, opacity: 0), Key(t: 2, opacity: 1)], length: 2) == nil)
        #expect(keysError([Key(t: 1, opacity: 0), Key(t: 0.5, opacity: 1)], length: 2) == "keys not sorted by t")
        #expect(keysError([Key(t: 3, opacity: 0)], length: 2) == "key 0 outside the item")
        #expect(keysError([Key(t: 0)], length: 2) == "key 0 sets no finite value")
        #expect(keysError([Key(t: 0, scale: 0)], length: 2) != nil && keysError([Key(t: 0, opacity: 2)], length: 2) != nil)

        var project = Project(source: Source(duration: 10), clips: [Clip(sourceStart: 0, sourceEnd: 10)],
                              texts: [TextBlock(id: "t", start: 1, end: 3, text: "Hi")],
                              layers: [LayerBlock(id: "l", kind: .image, start: 2, end: 5, file: "media/a.png", rect: NormRect())])
        project.texts[0].keys = [Key(t: 0, opacity: 0), Key(t: 0.4, opacity: 1, ease: .spring)]
        project.layers[0].keys = [Key(t: 0, x: 0.1), Key(t: 3, x: 0.3)]
        #expect(project.checkInvariants() == nil)
        #expect(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project)) == project)
        project.layers[0].keys = [Key(t: 4, x: 0.1)]                                 // past the 3 s layer
        #expect(project.checkInvariants()?.contains("outside the item") == true)
    }
}
