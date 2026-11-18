import Testing
@testable import RecorderCore

struct EventsAgentPointerTests {
    @Test func clickAddsMoveAndPairForAutoZoom() {
        let merged = EventLog().mergingAgentPointer([(1, 0.3, 0.4, .click)])
        #expect(merged.events == [
            InputEvent(t: 1, k: .move, x: 0.3, y: 0.4),
            InputEvent(t: 1.05, k: .down, x: 0.3, y: 0.4, b: 0),
            InputEvent(t: 1.12, k: .up, x: 0.3, y: 0.4, b: 0),
        ])
        let project = Project(source: Source(duration: 4), clips: [Clip(sourceStart: 0, sourceEnd: 4)])
        #expect(project.generatedAutoZooms(events: merged).count == 1)
    }

    @Test func onlyNearbyRealClicksSuppressDeclarations() {
        let real = InputEvent(t: 1.1, k: .down, x: 0.4, y: 0.4, b: 0)
        let log = EventLog(events: [real])
        #expect(log.mergingAgentPointer([(1, 0.41, 0.41, .click)]).events == [real])
        #expect(log.mergingAgentPointer([(1, 0.8, 0.8, .click)]).clicks().count == 2)
        #expect(log.mergingAgentPointer([(2, 0.41, 0.41, .click)]).clicks().count == 2)
    }

    @Test func doubleClickAndMoveKeepSortedEventsAndOtherKinds() {
        let key = InputEvent(t: 1.5, k: .key, keyCode: 12)
        let cursor = InputEvent(t: 3, k: .cursor, id: "arrow")
        let merged = EventLog(events: [cursor, key]).mergingAgentPointer([
            (2, 0.4, 0.6, .move), (1, 0.3, 0.4, .doubleClick),
        ])
        #expect(merged.events.map(\.k) == [.move, .down, .up, .down, .up, .key, .move, .cursor])
        #expect(merged.events.map(\.t) == [1, 1.05, 1.12, 1.2, 1.27, 1.5, 2, 3])
        #expect(merged.events.suffix(3).first == key)
        #expect(merged.events.last == cursor)
    }
}
