import Foundation
import Testing
@testable import RecorderCore

@Suite struct AgentDraftTests {
    @Test func seekUsesTheCurrentOutputClockAndCutSeams() throws {
        let base = Project(source: Source(duration: 20), clips: [Clip(sourceStart: 0, sourceEnd: 20)])
        let edited = try base.applying([.cut(from: 2, to: 4), .speed(from: 8, to: 12, speed: 2)], context: EditContext()).project
        func row(at: Double) -> AgentDraftRow {
            AgentDraftRow(call: 0, index: 0, op: .marker(at: .seconds(at), label: ""), change: EditChange(op: 0, summary: "", at: at, delta: 0))
        }
        #expect(row(at: 1).outputTime(before: base, after: edited) == 1)
        #expect(row(at: 3).outputTime(before: base, after: edited) == 2)
        #expect(row(at: 10).outputTime(before: base, after: edited) == 7)
        #expect(row(at: 20).outputTime(before: base, after: edited) == 16)
        #expect(row(at: 7).outputTime(before: edited, after: edited) == 7)
        #expect(row(at: 7).outputTime(before: edited, after: base) == 10)
    }

    @Test func groupsKeepKindOrderRowIdentityAndDeltas() {
        let ops: [EditOp] = [.marker(at: 8, label: "A"), .cut(from: 1, to: 2), .text(from: 3, to: 4, style: .title, text: "Title", position: nil, size: nil),
            .cutPauses(minDuration: 1, keepTail: 0.1, from: nil, to: nil), .speed(from: 4, to: 6, speed: 2), .zoom(from: 6, to: 8, scale: 2, center: nil),
            .cutWords(transcript: "t", words: ["w0"]), .captions(maxWords: 4), .style(patch: [:]), .remove(id: "x"),
            .update(id: "x", from: nil, to: nil, text: nil, position: nil, size: nil, scale: nil, center: nil),
            .highlight(from: 1, to: 2, rect: NormRect(), opacity: nil)]
        let rows = ops.enumerated().map { index, op in
            AgentDraftRow(call: index / 3, index: index % 3, op: op,
                          change: EditChange(op: index % 3, summary: "Change", at: Double(index), delta: AgentChangeKind(op) == .cuts ? -1 : 0))
        }
        let groups = AgentChangeGroup.groups(rows)
        #expect(groups.map(\.kind) == AgentChangeKind.allCases)
        #expect(groups[0].rows.map(\.id) == [[0, 1], [1, 0], [2, 0]])
        #expect(groups[0].deltaSum == -3)
        #expect(groups.dropFirst().allSatisfy { $0.deltaSum == 0 })
        #expect(groups.flatMap(\.rows).count == rows.count)
        #expect(AgentChangeGroup.groups([]).isEmpty)
        #expect(AgentChangeGroup.groups([rows[0]]).map(\.kind) == [.markers])
        #expect(AgentChangeGroup.groups(rows.filter { AgentChangeKind($0.op) != .cuts }).map(\.kind) == Array(AgentChangeKind.allCases.dropFirst()))
    }

    @Test func persistedDraftRoundTripsAndReplaysToTheSameProject() throws {
        let base = Project(source: Source(duration: 20, hasMic: true), clips: [Clip(sourceStart: 0, sourceEnd: 20)])
        var first = EditContext(); first.silent = [TimeRange(start: 5, end: 7)]
        let calls: [[EditOp]] = [[.marker(at: 4, label: "hook"), .cutPauses(minDuration: 0.5, keepTail: 0.1, from: nil, to: nil)],
                                 [.zoom(from: 4, to: 6, scale: 2, center: nil)]]
        let second = EditContext()
        var project = base, changes: [[EditChange]] = []
        for (index, call) in calls.enumerated() {
            var context = [first, second][index]
            context.operationSeeds = call.indices.map { "draft:\(index):\($0)" }
            let result = try project.applying(call, context: context)
            project = result.project; changes.append(result.changes)
        }
        let record = AgentDraftRecord(id: "draft", base: "r0", baseProject: base, calls: calls, contexts: [first, second], excluded: [[0, 1]], note: "n", submitted: true)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("draft-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try record.write(to: folder)
        let loaded = try #require(AgentDraftRecord.read(from: folder))
        #expect(loaded.status == "submitted" && loaded.excluded == [[0, 1]] && loaded.calls == calls && loaded.baseProject == base)
        #expect(loaded.contexts[0].silent == first.silent && loaded.contexts[1].silent.isEmpty)
        var replayed = loaded.baseProject
        for (index, call) in loaded.calls.enumerated() {
            var context = loaded.contexts[index]
            context.operationSeeds = call.indices.map { "\(loaded.id):\(index):\($0)" }
            replayed = try replayed.applying(call, context: context).project
        }
        #expect(replayed.zooms.map(\.id) == project.zooms.map(\.id) && replayed.markers.map(\.id) == project.markers.map(\.id))
        #expect(replayed.clips == project.clips && replayed.zooms[0].start == 4)
        AgentDraftRecord.remove(from: folder)
        #expect(AgentDraftRecord.read(from: folder) == nil)
    }

    @Test func schemaViolationEnforcesLimitsFromTheSchema() {
        let schema: [String: Any] = ["type": "object", "additionalProperties": false, "required": ["action"], "properties": [
            "action": ["type": "string", "enum": ["frames"]],
            "at": ["type": "array", "maxItems": 24, "items": ["type": "number", "minimum": 0]],
            "longEdge": ["type": "integer", "minimum": 2, "maximum": 640],
            "shortEdge": ["type": "integer", "enum": [720, 1080]]]]
        #expect(schemaViolation(["action": "frames", "at": [0, 1.5], "longEdge": 640, "shortEdge": 1080], schema) == nil)
        #expect(schemaViolation(["action": "frames", "at": Array(repeating: 1, count: 25)], schema)?.range == true)
        #expect(schemaViolation(["action": "frames", "at": [-1]], schema)?.range == true)
        #expect(schemaViolation(["action": "frames", "longEdge": 641], schema)?.range == true)
        #expect(schemaViolation(["action": "frames", "longEdge": 2.5], schema)?.range == false)
        #expect(schemaViolation(["action": "frames", "shortEdge": 900], schema)?.range == true)
        #expect(schemaViolation(["action": "other"], schema)?.range == false)
        #expect(schemaViolation(["action": "frames", "bogus": 1], schema) != nil)
        #expect(schemaViolation(["longEdge": 4], schema)?.message.contains("required") == true)
        #expect(schemaViolation(["action": "frames", "longEdge": true], schema) != nil)
    }
}
