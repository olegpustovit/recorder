import Testing
@testable import RecorderCore

@Suite struct AgentDraftTests {
    @Test func seekUsesTheCurrentOutputClockAndCutSeams() throws {
        let base = Project(source: Source(duration: 20), clips: [Clip(sourceStart: 0, sourceEnd: 20)])
        let edited = try base.applying([.cut(from: 2, to: 4), .speed(from: 8, to: 12, speed: 2)], context: EditContext()).project
        func row(at: Double) -> AgentDraftRow {
            AgentDraftRow(call: 0, index: 0, op: .marker(at: at, label: ""), change: EditChange(op: 0, summary: "", at: at, delta: 0))
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
}
