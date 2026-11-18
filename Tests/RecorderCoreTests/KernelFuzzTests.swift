import Foundation
import Testing
@testable import RecorderCore

/// T-911 (EDITING-CORE D8): seeded random EditOp batches over four layouts. After every batch the project keeps its
/// invariants, round-trips through JSON, keeps every item inside the export, and replays identically from the same seeds;
/// a rejected batch is an EditError (never a crash or a different error type).
@Suite struct KernelFuzzTests {
    struct RNG { var state: UInt64
        mutating func next() -> UInt64 { state &+= 0x9E3779B97F4A7C15; var z = state; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) }
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
        mutating func range(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * unit() }
        mutating func pick<T>(_ xs: [T]) -> T { xs[Int(next() % UInt64(xs.count))] }
    }

    static func fixtures() -> [(String, Project)] {
        let simple = Project(source: Source(duration: 20, hasMic: true), clips: [Clip(sourceStart: 0, sourceEnd: 20)])
        var layered = Project(source: Source(duration: 30, hasMic: true), clips: [Clip(sourceStart: 0, sourceEnd: 30)])
        _ = layered.addLayer(kind: .image, file: "media/a.png", atOutput: 3, duration: 4, rect: NormRect(x: 0.6, y: 0.6, w: 0.3, h: 0.3), hasAudio: false)
        _ = layered.addLayer(kind: .video, file: "media/v.mov", atOutput: 12, duration: 5, rect: NormRect(), hasAudio: true)
        _ = layered.addImportedAudio(file: "media/music.m4a", atOutput: 0, duration: 25)
        let golden = GoldenIslandTests.fixture.project
        var free = golden; free.linkVideoEdits = false
        return [("simple", simple), ("layered", layered), ("golden", golden), ("goldenFree", free)]
    }

    static func randomOp(_ p: Project, _ rng: inout RNG) -> EditOp {
        let d = max(0.5, TimeMap(p.clips).outputDuration)
        let a = rng.range(0, d), b = min(d, a + rng.range(0.1, max(0.2, d / 4)))
        let ids = items(p).filter { $0.kind != .clip && $0.kind != .gap }.map(\.id)
        let t = { (x: Double) in EditTime.seconds((x * 100).rounded() / 100) }
        switch rng.next() % 11 {
        case 0, 1: return .cut(from: t(a), to: t(b), snap: rng.next() % 2 == 0)
        case 2: return .speed(from: t(a), to: t(b), speed: rng.pick([0.5, 1.5, 2, 4]), snap: rng.next() % 2 == 0)
        case 3: return .zoom(from: t(a), to: t(b), scale: rng.pick([1.5, 2, 3]), center: rng.next() % 2 == 0 ? nil : NormPoint(x: rng.unit(), y: rng.unit()))
        case 4: return .text(from: t(a), to: t(b), style: rng.pick(TextBlock.Style.allCases), text: "Fuzz", position: nil, size: nil)
        case 5: return .highlight(from: t(a), to: t(b), rect: NormRect(x: 0.1, y: 0.1, w: 0.3, h: 0.3), opacity: 0.5)
        case 6: return .marker(at: t(a), label: "m")
        case 7: return ids.isEmpty ? .marker(at: t(a), label: "m") : .remove(id: rng.pick(ids))
        case 8:
            guard let layer = p.layers.isEmpty ? nil : rng.pick(p.layers) else { return .cut(from: t(a), to: t(b)) }
            switch rng.next() % 3 {
            case 0: return .set(id: layer.id, fields: SetFields(mediaRate: rng.pick([0.5, 1, 2, 3])))
            case 1: return .set(id: layer.id, fields: SetFields(mediaStart: rng.range(0, 3)))
            default: return .set(id: layer.id, fields: SetFields(from: t(a), to: t(b + 1)))
            }
        case 9: return ids.isEmpty ? .zoom(from: t(a), to: t(b), scale: 2, center: nil) : .set(id: rng.pick(ids), fields: SetFields(from: t(a), to: t(b)))
        default: return .cutPauses(minDuration: 0.6, keepTail: 0.12, from: nil, to: nil, snap: true)
        }
    }

    @Test func randomBatchesKeepTheKernelSound() throws {
        var accepted = 0, rejected = 0
        for (name, fixture) in Self.fixtures() {
            var rng = RNG(state: UInt64(name.utf8.reduce(0) { $0 &* 31 &+ UInt64($1) }))
            var project = fixture
            let silent = [TimeRange(start: 1, end: 2.5), TimeRange(start: 7, end: 9)]
            for step in 0..<125 {   // 4 fixtures × 125 = 500 batches
                let ops = (0..<Int(1 + rng.next() % 3)).map { _ in Self.randomOp(project, &rng) }
                let seeds = ops.indices.map { "\(name)-\(step)-\($0)" }
                let context = EditContext(silent: silent, operationSeeds: seeds, assets: ["media/v.mov": MediaAsset(file: "media/v.mov", kind: .video, duration: 5, width: 64, height: 36, hasAudio: true)])
                let before = project
                do {
                    let result = try project.applying(ops, context: context).project
                    accepted += 1
                    #expect(result.checkInvariants(mediaDurations: ["media/v.mov": 5]) == nil, "\(name) \(step): invariants \(ops)")
                    let decoded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(result))
                    #expect(decoded == result, "\(name) \(step): JSON round-trip \(ops)")
                    let export = result.exportDuration
                    // A trailing gap clip (padding a removed layer once needed) may sit past the export, which ignores it by design.
                    let stray = items(result).first { $0.kind != .gap && ($0.out.start < -1e-6 || $0.out.end > export + 1e-6 || $0.out.end < $0.out.start - 1e-9) }
                    #expect(stray == nil, "\(name) \(step): item outside 0…\(export): \(String(describing: stray)) after \(ops)")
                    let again = try before.applying(ops, context: context).project
                    #expect(again == result, "\(name) \(step): replay differs \(ops)")
                    project = result.clips.contains(where: { !$0.isEmpty }) && result.exportDuration > 1 ? result : fixture
                } catch let error as EditError {
                    rejected += 1
                    _ = error
                    #expect(project == before)
                } catch {
                    Issue.record("\(name) \(step): non-EditError \(error) for \(ops)")
                }
            }
        }
        #expect(accepted > 150 && rejected > 0, "accepted \(accepted), rejected \(rejected)")
    }
}
