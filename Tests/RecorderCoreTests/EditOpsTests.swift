import Foundation
import Testing
@testable import RecorderCore

@Suite struct EditOpsTests {
    @Test func replaySeedsKeepCreatedAndSplitIDsStable() throws {
        let base = project()
        let ops: [EditOp] = [.zoom(from: 1, to: 5, scale: 2, center: nil), .speed(from: 2, to: 4, speed: 2), .cut(from: 6, to: 7)]
        let context = EditContext(operationSeeds: ["zoom", "speed", "cut"])
        let first = try base.applying(ops, context: context)
        let replayed = try base.applying(ops, context: context)
        #expect(first.project == replayed.project && first.changes == replayed.changes)
        #expect(first.project.checkInvariants() == nil)
        let additions: [EditOp] = [.marker(at: 2, label: "Marker"), .text(from: 4, to: 6, style: .label, text: "Label", position: nil, size: nil)]
        let all = try base.applying(additions, context: EditContext(operationSeeds: ["marker", "label"]))
        let excluded = try base.applying([additions[1]], context: EditContext(operationSeeds: ["label"]))
        #expect(all.project.texts == excluded.project.texts)
        let ordinary = try base.applying([additions[1]], context: EditContext())
        #expect(ordinary.project.texts[0].id != excluded.project.texts[0].id)
        #expect(all.project.checkInvariants() == nil && excluded.project.checkInvariants() == nil)
    }

    @Test func motionTextCanOverlapCaptionsAndRetainsLaneValidation() throws {
        let base = project()
        let context = EditContext(words: [Word(text: "spoken", start: 2, end: 4)])
        var result = try base.applying([.captions(maxWords: 4), .text(from: 1, to: 5, style: .lowerThird, text: "Sam", position: nil, size: nil)], context: context).project
        #expect(result.texts.count == 2)
        let id = try #require(result.texts.first { $0.style == .lowerThird }.flatMap { UUID(uuidString: $0.id) })
        result.moveText(id, toStart: 1.5)
        result.resizeText(id, edge: .trailing, to: 6)
        #expect(result.texts.first { $0.id == id.uuidString }?.start == 1.5)
        result.replaceCaptions(captionPhrases(words: context.words))
        #expect(result.texts.count == 2 && result.checkInvariants() == nil)
        var invalid = result
        invalid.texts[invalid.texts.firstIndex { $0.id == id.uuidString }!].style = .title
        #expect(invalid.checkInvariants() != nil)
        #expect(throws: EditError.self) {
            try result.applying([.text(from: 2, to: 4, style: .lowerThird, text: "Collision", position: nil, size: nil)], context: context)
        }
    }

    @Test func markerOpsUseBaseTimeAndCanBeUpdatedAndRemoved() throws {
        let base = project()
        let result = try base.applying([.cut(from: 2, to: 4), .marker(at: 8, label: "Start"), .marker(at: 3, label: "Cut")], context: EditContext())
        #expect(result.project.markers.map(\.time) == [3, 8])
        #expect(agentTimeline(result.project).markers.map(\.at) == [6])
        let id = try #require(result.project.markers.first { $0.label == "Start" }?.id)
        let updated = try result.project.applying([
            .update(id: id, from: 10, to: nil, text: "Updated", position: nil, size: nil, scale: nil, center: nil)
        ], context: EditContext())
        #expect(updated.project.markers.first { $0.id == id }?.time == 12)
        #expect(agentTimeline(updated.project).markers.first?.label == "Updated")
        let removed = try updated.project.applying([.remove(id: id)], context: EditContext())
        #expect(!removed.project.markers.contains { $0.id == id })
        #expect(throws: EditError.self) {
            try base.applying([.marker(at: -1, label: "Invalid")], context: EditContext())
        }
        #expect(result.project.checkInvariants() == nil && updated.project.checkInvariants() == nil && removed.project.checkInvariants() == nil)
    }

    private func project() -> Project {
        Project(source: Source(duration: 20, hasMic: true), clips: [Clip(sourceStart: 0, sourceEnd: 20)])
    }

    @Test func flatJSONRoundTrip() throws {
        let json = #"[{"op":"cut","from":2,"to":4},{"op":"cutPauses"},{"op":"cutWords","transcript":"t-1","words":["w0"]},{"op":"speed","from":0,"to":1,"speed":2},{"op":"zoom","from":1,"to":3,"scale":2},{"op":"text","from":1,"to":3,"style":"title","text":"hello"},{"op":"captions"},{"op":"highlight","from":1,"to":3,"rect":{"x":0.1,"y":0.2,"w":0.3,"h":0.4}},{"op":"marker","at":3,"label":"chapter"},{"op":"update","id":"id","from":1,"text":"new"},{"op":"remove","id":"id"},{"op":"style","patch":{"frame":{"padding":0.06}}}]"#
        let ops = try JSONDecoder().decode([EditOp].self, from: Data(json.utf8))
        #expect(ops.count == 12)
        #expect(try JSONDecoder().decode([EditOp].self, from: JSONEncoder().encode(ops)) == ops)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(EditOp.self, from: Data(#"{"op":"bogus"}"#.utf8)) }
        #expect(project().checkInvariants() == nil)
    }

    @Test func cutsUseBaseTimeRegardlessOfOrder() throws {
        let base = project()
        let snapshot = base
        let cuts: [EditOp] = [.cut(from: 2, to: 4), .cut(from: 8, to: 11)]
        let forward = try base.applying(cuts, context: EditContext())
        let reverse = try base.applying(cuts.reversed(), context: EditContext())
        #expect(forward.project.clips == reverse.project.clips)
        #expect(forward.project.clips.map(\.sourceStart) == [0, 4, 11])
        #expect(forward.project.clips.map(\.sourceEnd) == [2, 8, 20])
        #expect(TimeMap(forward.project.clips).outputDuration == 15)
        #expect(forward.changes.map(\.delta) == [-2, -3])
        #expect(forward.project.audioClips.map { $0.end - $0.start }.reduce(0, +) == 15)
        #expect(forward.project.checkInvariants() == nil && reverse.project.checkInvariants() == nil)
        #expect(base == snapshot)
    }

    @Test func effectsSurviveCutsAndSpeedUsesBaseTime() throws {
        let base = project()
        let applied = try base.applying([.cut(from: 2, to: 4), .zoom(from: 2, to: 4, scale: 2, center: nil),
                                        .speed(from: 8, to: 12, speed: 2)], context: EditContext())
        #expect(applied.project.zooms.count == 1)
        #expect(applied.project.zooms[0].start == 2 && applied.project.zooms[0].end == 4)
        #expect(applied.project.clips.first { $0.sourceStart == 8 }?.speed == 2)
        #expect(TimeMap(applied.project.clips).outputDuration == 16)
        #expect(applied.changes.map(\.delta) == [-2, 0, -2])
        #expect(applied.project.checkInvariants() == nil)
    }

    @Test func pausesKeepTailsAndSkipShortRanges() throws {
        let context = EditContext(silent: [TimeRange(start: 2, end: 4), TimeRange(start: 8, end: 8.4)])
        let result = try project().applying([.cutPauses(minDuration: 0.3, keepTail: 0.2, from: nil, to: nil)], context: context)
        #expect(abs(TimeMap(result.project.clips).outputDuration - 18.4) < 1e-9)
        #expect(result.project.clips[0].sourceEnd == 2.2)
        #expect(result.project.clips[1].sourceStart == 3.8)
        #expect(result.project.checkInvariants() == nil)
    }

    @Test func wordsCheckRevisionAndUseMediaCopies() throws {
        var base = project()
        var clip = Clip(sourceStart: 0, sourceEnd: 10, speed: 2)
        clip.mediaStart = 0; clip.clockSpeed = 1
        var imported = Clip(sourceStart: 10, sourceEnd: 20)
        imported.file = "media/movie.mov"; imported.mediaStart = 0
        base.clips = [clip, imported]; base.audioClips = []
        let context = EditContext(words: [Word(text: "one", start: 1, end: 2), Word(text: "um", start: 3, end: 4), Word(text: "two", start: 5, end: 6)])
        #expect(throws: EditError.transcriptChanged) {
            try base.applying([.cutWords(transcript: "stale", words: ["w1"])], context: context)
        }
        let result = try base.applying([.cutWords(transcript: transcriptID(context.words), words: ["w1"])], context: context)
        #expect(abs(result.changes[0].delta + 0.65) < 1e-9)
        #expect(result.project.clips.last == imported)
        #expect(result.project.checkInvariants() == nil && base.checkInvariants() == nil)
    }

    @Test func invalidOpsAreAtomicAndReportIndex() throws {
        var base = project()
        base.zooms = [Zoom(start: 2, end: 5)]
        let snapshot = base
        do {
            _ = try base.applying([.text(from: 10, to: 12, style: .title, text: "new", position: nil, size: nil),
                                   .zoom(from: 3, to: 6, scale: 2, center: nil)], context: EditContext())
            Issue.record("overlap accepted")
        } catch let error as EditError {
            guard case .invalidOp(let index, let reason) = error else { Issue.record("wrong error \(error)"); return }
            #expect(index == 1 && reason.contains(base.zooms[0].id))
        }
        #expect(base == snapshot)
        #expect(throws: EditError.self) { try base.applying([.cut(from: -1, to: 3)], context: EditContext()) }
        #expect(throws: EditError.self) { try base.applying([.cut(from: 0.01, to: 1)], context: EditContext()) }
        #expect(throws: EditError.self) { try base.applying([.zoom(from: 7, to: 9, scale: .infinity, center: nil)], context: EditContext()) }
        #expect(base.checkInvariants() == nil)
        do {
            _ = try base.applying([.cut(from: 2, to: 4), .cut(from: 8.01, to: 19.99)], context: EditContext())
            Issue.record("tiny retained clip accepted")
        } catch let error as EditError {
            guard case .invalidOp(let index, _) = error else { Issue.record("wrong error \(error)"); return }
            #expect(index == 1)
        }
    }

    @Test func styleMergesOnlyRequestedFields() throws {
        let base = project()
        var expected = base
        expected.frame.padding = 0.06
        let result = try base.applying([.style(patch: ["frame": .object(["padding": .number(0.06)])])], context: EditContext())
        #expect(result.project == expected)
        #expect(throws: EditError.self) { try base.applying([.style(patch: ["frame": .object(["typo": .number(1)])])], context: EditContext()) }
        #expect(throws: EditError.self) { try base.applying([.style(patch: ["clips": .array([])])], context: EditContext()) }
        #expect(result.project.checkInvariants() == nil)
    }

    @Test func updateRemoveCaptionsAndHighlight() throws {
        var base = project()
        let block = TextBlock(start: 1, end: 3, text: "old")
        base.texts = [block]
        let result = try base.applying([
            .update(id: block.id, from: 2, to: 4, text: "new", position: NormPoint(x: 0.2, y: 0.3), size: 42, scale: nil, center: nil),
            .highlight(from: 5, to: 7, rect: NormRect(x: 0.1, y: 0.2, w: 0.3, h: 0.4), opacity: 0.6),
            .captions(maxWords: 4)
        ], context: EditContext(words: [Word(text: "hello", start: 10, end: 11)]))
        #expect(result.project.texts[0].text == "new" && result.project.texts[0].start == 2)
        #expect(result.project.texts[1].style == .caption)
        #expect(result.project.masks[0].kind == .highlight)
        let removed = try result.project.applying([.remove(id: block.id)], context: EditContext())
        #expect(!removed.project.texts.contains { $0.id == block.id })
        #expect(removed.changes[0].at == 2)
        #expect(result.project.checkInvariants() == nil && removed.project.checkInvariants() == nil)
    }

    @Test func overlappingCutsAreRemovedOnceAndImportsAreEditable() throws {
        var base = project()
        base.clips[0].file = "media/movie.mov"
        base.audioClips = []
        let result = try base.applying([.cut(from: 2, to: 5), .cut(from: 4.99, to: 7)], context: EditContext())
        #expect(result.project.clips.map(\.sourceStart) == [0, 7])
        #expect(result.project.clips.map(\.sourceEnd) == [2, 20])
        #expect(abs(result.changes.map(\.delta).reduce(0, +) + 5) < 1e-9)
        var unchanged = base
        unchanged.removeSourceRanges([TimeRange(start: 2, end: 7)])
        #expect(unchanged == base)
        #expect(TimeMap(unchanged.clips).outputDuration == 20)
        #expect(result.project.checkInvariants() == nil && unchanged.checkInvariants() == nil)
    }

    @Test func optionalStyleAndStringIDs() throws {
        var base = project()
        base.zooms = [Zoom(id: "legacy", start: 1, end: 3)]
        let result = try base.applying([.remove(id: "legacy"), .style(patch: ["frame": .object(["enabled": .bool(false)])])], context: EditContext())
        #expect(result.project.zooms.isEmpty)
        #expect(result.project.frame.enabled == false)
        #expect(result.project.checkInvariants() == nil)
    }

    @Test func snappedCutsReportEdgesAndKeepBaseTimeAndIDs() throws {
        let base = project()
        let ops: [EditOp] = [.cut(from: 0.01, to: 2, snap: true), .cut(from: 6, to: 8), .marker(at: 15, label: "Kept")]
        let context = EditContext(operationSeeds: ["edge", "strict", "marker"])
        let result = try base.applying(ops, context: context)
        #expect(result.project.clips.map(\.sourceStart) == [2, 8])
        #expect(result.project.clips.map(\.sourceEnd) == [6, 20])
        #expect(result.changes.map(\.delta) == [-2, -2, 0])
        #expect(result.changes[0].note?.contains("0.010") == true)
        #expect(result.changes[0].note?.contains("0.000") == true)
        #expect(result.changes.allSatisfy { !$0.skipped })
        #expect(try base.applying(ops, context: context).project == result.project)
        #expect(result.project.markers[0].time == 15 && result.project.checkInvariants() == nil)
        #expect(throws: EditError.self) { try base.applying([.cut(from: 0.01, to: 2)], context: EditContext()) }
    }

    @Test func snappedShortAndNeighboringCutsDoNotFailTheBatch() throws {
        let base = project()
        let result = try base.applying([.cut(from: 2, to: 2.04, snap: true), .cut(from: 4, to: 5, snap: true),
            .cut(from: 5.04, to: 6, snap: true), .marker(at: 10, label: "Still applied")], context: EditContext())
        #expect(result.changes[0].skipped && result.changes[0].note != nil)
        #expect(result.changes.map(\.delta) == [0, -1, -1, 0])
        #expect(result.project.clips.map(\.sourceStart) == [0, 6])
        #expect(result.project.clips.map(\.sourceEnd) == [4, 20])
        #expect(result.project.markers.count == 1 && result.project.checkInvariants() == nil)
        let all = try base.applying([.cut(from: 0.01, to: 19.99, snap: true)], context: EditContext())
        #expect(all.project == base && all.changes[0].skipped && all.changes[0].note != nil)
        #expect(throws: EditError.self) { try base.applying([.cut(from: .seconds(.nan), to: 2, snap: true)], context: EditContext()) }
        #expect(throws: EditError.self) { try base.applying([.cut(from: 2, to: 1, snap: true)], context: EditContext()) }
        #expect(throws: EditError.self) { try base.applying([.cut(from: 0.01, to: 2, snap: true), .style(patch: ["typo": .bool(true)])], context: EditContext()) }
        #expect(base.clips == project().clips)
    }

    @Test func snappingHonorsMediaAndOutputMinimumsAndSpeedSplits() throws {
        let base = project()
        let fast = Project(source: Source(duration: 40), clips: [Clip(sourceStart: 0, sourceEnd: 40, speed: 16)])
        let cut = try fast.applying([.cut(from: 0.01, to: 0.1, snap: true)], context: EditContext())
        #expect(abs(cut.changes[0].delta + 0.1) < 1e-9 && cut.project.clips[0].sourceStart == 1.6)
        var copied = Clip(sourceStart: 0, sourceEnd: 10, speed: 4)
        copied.clockSpeed = 1; copied.mediaStart = 0; copied.file = "media/movie.mov"
        let imported = Project(source: Source(duration: 40), clips: [copied])
        let mediaCut = try imported.applying([.cut(from: 0.02, to: 1, snap: true)], context: EditContext())
        #expect(mediaCut.project.clips[0].sourceStart == 1 && mediaCut.project.clips[0].mediaIn == 4)
        let speed = try base.applying([.speed(from: 0.01, to: 2, speed: 2, snap: true)], context: EditContext())
        #expect(speed.project.clips[0].sourceStart == 0 && speed.project.clips[0].speed == 2)
        #expect(speed.changes[0].note != nil && !speed.changes[0].skipped)
        let short = try base.applying([.speed(from: 2, to: 2.02, speed: 2, snap: true)], context: EditContext())
        #expect(short.project == base && short.changes[0].skipped)
        #expect(throws: EditError.self) { try project().applying([.speed(from: 2, to: 2.02, speed: 0, snap: true)], context: EditContext()) }
        #expect(cut.project.checkInvariants() == nil && mediaCut.project.checkInvariants() == nil && speed.project.checkInvariants() == nil)
    }

    @Test func pauseSnappingDefaultsAndFlatJSONKeepStrictOptOut() throws {
        let context = EditContext(silent: [TimeRange(start: 0.01, end: 1), TimeRange(start: 2, end: 2.08)])
        let op = EditOp.cutPauses(minDuration: 0.01, keepTail: 0, from: nil, to: nil)
        let result = try project().applying([op], context: context)
        #expect(result.project.clips[0].sourceStart == 1 && result.changes[0].delta == -1)
        #expect(result.changes[0].note != nil && !result.changes[0].skipped)
        #expect(throws: EditError.self) {
            try project().applying([.cutPauses(minDuration: 0.01, keepTail: 0, from: nil, to: nil, snap: false)], context: context)
        }
        let ops: [EditOp] = [op, .cut(from: 1, to: 2, snap: true), .cutWords(transcript: "t", words: ["w0"], snap: true), .speed(from: 1, to: 2, speed: 2, snap: true)]
        #expect(try JSONDecoder().decode([EditOp].self, from: JSONEncoder().encode(ops)) == ops)
        #expect(try JSONDecoder().decode(EditOp.self, from: Data(#"{"op":"cutPauses"}"#.utf8)) == .cutPauses(minDuration: 0.6, keepTail: 0.12, from: nil, to: nil))
        let words = EditContext(words: [Word(text: "edge", start: 0.01, end: 1)])
        let wordCut = try project().applying([.cutWords(transcript: transcriptID(words.words), words: ["w0"], snap: true)], context: words)
        #expect(wordCut.project.clips[0].sourceStart == 1 && wordCut.changes[0].note != nil)
        #expect(result.project.checkInvariants() == nil)
    }

    @Test func anchorsFollowEarlierCutsAndSpeedWhileNumbersKeepBaseTime() throws {
        var base = project()
        base.markers = [Marker(id: "anchor", time: 10, label: "Anchor")]
        let ops: [EditOp] = [.cut(from: 2, to: 4), .speed(from: 4, to: 8, speed: 2),
            .marker(at: .marker("anchor", offset: -1), label: "Relative"), .marker(at: 5, label: "Numeric"),
            .text(from: .marker("anchor", offset: -1), to: .marker("anchor"), style: .title, text: "Anchored", position: nil, size: nil),
            .cut(from: .marker("anchor", offset: 1), to: .marker("anchor", offset: 2))]
        let result = try base.applying(ops, context: EditContext(operationSeeds: ops.indices.map { "anchor-\($0)" }))
        #expect(result.project.markers.first { $0.label == "Relative" }?.time == 9)
        #expect(result.project.markers.first { $0.label == "Numeric" }?.time == 5)
        #expect(result.project.texts[0].start == 9 && result.project.texts[0].end == 10)
        #expect(!result.project.clips.contains { $0.sourceStart < 12 && $0.sourceEnd > 11 })
        #expect(TimeMap(result.project.clips).outputDuration == 15)
        #expect(result.changes[4].sourceAt == 9 && result.project.checkInvariants() == nil)
    }

    @Test func anchorsUseCreatedUpdatedAndDeletedMarkersInOrder() throws {
        let base = project()
        let create = EditOp.marker(at: 2, label: "Created")
        let id = try base.applying([create], context: EditContext(operationSeeds: ["created"])).project.markers[0].id
        let ops: [EditOp] = [create, .update(id: id, from: 4, to: nil, text: "Updated", position: nil, size: nil, scale: nil, center: nil),
            .marker(at: .marker(id, offset: 1), label: "Relative"), .remove(id: id)]
        let context = EditContext(operationSeeds: ["created", "update", "relative", "remove"])
        let result = try base.applying(ops, context: context)
        #expect(result.project.markers.count == 1 && result.project.markers[0].time == 5)
        #expect(try base.applying(ops, context: context).project == result.project)
        #expect(throws: EditError.self) {
            try base.applying(ops + [.marker(at: .marker(id), label: "Deleted")], context: EditContext(operationSeeds: context.operationSeeds + ["deleted"]))
        }
        #expect(base.markers.isEmpty && result.project.checkInvariants() == nil)
    }

    @Test func anchorsSupportOffsetsAfterUnlinkedExtensionAndSeekTheSourcePoint() throws {
        var base = project(); base.linkVideoEdits = false
        base.markers = [Marker(id: "anchor", time: 15, label: "Anchor")]
        let op = EditOp.text(from: .marker("anchor", offset: 10), to: .marker("anchor", offset: 11), style: .title, text: "Extended", position: nil, size: nil)
        let result = try base.applying([.speed(from: 0, to: 20, speed: 0.5), op], context: EditContext())
        #expect(result.project.texts[0].start == 25 && result.project.texts[0].end == 26)
        #expect(TimeMap(result.project.clips).outputDuration == 40)
        let row = AgentDraftRow(call: 0, index: 1, op: op, change: result.changes[1])
        #expect(row.outputTime(before: base, after: result.project) == 25)
        #expect(result.project.checkInvariants() == nil)
    }

    @Test func anchorJSONAndInvalidReferencesAreAtomic() throws {
        let json = #"[{"op":"marker","at":{"marker":"m","offset":-1},"label":"Relative"},{"op":"cut","from":{"marker":"m"},"to":{"marker":"m","offset":1}}]"#
        let ops = try JSONDecoder().decode([EditOp].self, from: Data(json.utf8))
        #expect(try JSONDecoder().decode([EditOp].self, from: JSONEncoder().encode(ops)) == ops)
        let base = project()
        do {
            _ = try base.applying([.style(patch: ["frame": .object(["padding": .number(0.04)])]), ops[0]], context: EditContext())
            Issue.record("missing anchor accepted")
        } catch let error as EditError {
            guard case .invalidOp(let index, _) = error else { Issue.record("wrong error"); return }
            #expect(index == 1)
        }
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(EditTime.self, from: Data(#"{"marker":"m","typo":1}"#.utf8)) }
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(EditTime.self, from: Data(#"{"marker":"m","offset":true}"#.utf8)) }
        var marked = base; marked.markers = [Marker(id: "m", time: 3, label: "")]
        #expect(throws: EditError.self) { try marked.applying([.marker(at: .marker("m", offset: .nan), label: "")], context: EditContext()) }
        #expect(throws: EditError.self) { try marked.applying([.marker(at: .marker("m", offset: -4), label: "")], context: EditContext()) }
        #expect(throws: EditError.self) { try marked.applying([.cut(from: 2, to: 4), .marker(at: .marker("m"), label: "Removed")], context: EditContext()) }
        #expect(base.frame.padding == project().frame.padding)
    }
}
