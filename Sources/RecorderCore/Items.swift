import Foundation

/// One view of everything timed in a project (EDITING-CORE D3, T-910). The stored model keeps its per-kind arrays; every
/// tool that needs "what is on the timeline" (agentTimeline, project.assets, lint coverage) reads this instead of walking
/// the arrays its own way, so layers, audio and markers can no longer be forgotten by one tool.
public struct Item: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case clip, gap, zoom, layout, camera, keys, mask, text, window, layer, audio, marker
    }
    /// spine: stored on the spine clock, follows cuts · connected: starts on the spine, keeps its own output length.
    public enum Anchor: String, Codable, Sendable { case spine, connected }
    public struct Media: Codable, Equatable, Sendable {
        public var file: String, start: Double, end: Double, rate: Double   // media seconds; rate = media s per output s
    }
    public var id: String
    public var kind: Kind
    public var track: Int
    public var out: TimeRange          // output seconds; spine items cut into pieces appear once per visible piece
    public var spine: TimeRange?       // stored range for spine-anchored items
    public var media: Media?
    public var anchor: Anchor
    public var editable: [String]      // fields `set`/`update` accept; empty = remove-only
    public var label: String
}

/// Fields each kind accepts through `set`/`update` (the one table the agent schema and timeline.get read).
public func editableFields(_ kind: Item.Kind) -> [String] {
    switch kind {
    case .zoom: ["from", "to", "scale", "center", "follow", "ease", "color"]
    case .text: ["from", "to", "text", "position", "size", "color"]
    case .mask: ["from", "to", "color"]
    case .layer: SetFields.layerFields
    case .marker: ["from", "text"]
    case .clip, .gap, .layout, .camera, .keys, .window, .audio: []
    }
}

public func items(_ project: Project) -> [Item] {
    let map = TimeMap(project.clips)
    var out: [Item] = []
    var offset = 0.0
    for (index, clip) in project.clips.enumerated() {
        let end = offset + clip.outputDuration
        out.append(Item(id: "c\(index)", kind: clip.isEmpty ? .gap : .clip, track: 0, out: TimeRange(start: offset, end: end),
                        spine: TimeRange(start: clip.sourceStart, end: clip.sourceEnd),
                        media: clip.isEmpty ? nil : .init(file: clip.file ?? "screen.mov", start: clip.mediaIn, end: clip.mediaEnd, rate: clip.speed),
                        anchor: .spine, editable: [], label: clip.isEmpty ? "gap" : String(format: "%g×", locale: Locale(identifier: "en_US_POSIX"), clip.speed)))
        offset = end
    }
    func spineItem(_ id: String, _ kind: Item.Kind, _ start: Double, _ end: Double, _ label: String, media: Item.Media? = nil) {
        var offset = 0.0
        for clip in project.clips {
            let lo = max(start, clip.sourceStart), hi = min(end, clip.sourceEnd)
            if hi > lo {
                out.append(Item(id: id, kind: kind, track: 0,
                                out: TimeRange(start: offset + (lo - clip.sourceStart) / clip.timeScale, end: offset + (hi - clip.sourceStart) / clip.timeScale),
                                spine: TimeRange(start: start, end: end), media: media, anchor: .spine, editable: editableFields(kind), label: label))
            }
            offset += clip.outputDuration
        }
    }
    for b in project.zooms { spineItem(b.id, .zoom, b.start, b.end, String(format: "%.1f×", locale: Locale(identifier: "en_US_POSIX"), b.scale)) }
    for b in project.texts { spineItem(b.id, .text, b.start, b.end, String(b.text.prefix(24))) }
    for b in project.masks { spineItem(b.id, .mask, b.start, b.end, b.kind.rawValue) }
    for b in project.layouts { spineItem(b.id, .layout, b.start, b.end, b.kind.rawValue) }
    for b in project.cameraClips { spineItem(b.id, .camera, b.start, b.end, "Camera") }
    for b in project.keystrokeClips { spineItem(b.id, .keys, b.start, b.end, "Keys") }
    for b in project.windowShots { spineItem(b.id, .window, b.start, b.end, "Window \(b.window + 1)") }
    for layer in project.layers {
        guard let start = map.outputTime(atSource: layer.start) else { continue }
        let length = layer.end - layer.start, rate = layer.mediaRate ?? 1
        out.append(Item(id: layer.id, kind: .layer, track: layer.track, out: TimeRange(start: start, end: start + length), spine: nil,
                        media: layer.kind == .image ? nil : .init(file: layer.file, start: layer.mediaStart, end: layer.mediaStart + length * rate, rate: rate),
                        anchor: .connected, editable: editableFields(.layer), label: layer.kind.rawValue))
    }
    for audio in project.audioClips {
        let connected = audio.link != .screen && audio.link != .camera   // same rule as TimeMap.audioSegments
        for segment in project.audioSegments(audio) {
            out.append(Item(id: audio.id, kind: .audio, track: audio.track, out: segment.output, spine: connected ? nil : TimeRange(start: audio.start, end: audio.end),
                            media: .init(file: audio.file, start: segment.media.start, end: segment.media.end, rate: audio.mediaRate ?? 1),
                            anchor: connected ? .connected : .spine, editable: [], label: audio.file))
        }
    }
    for marker in project.markers {
        // A marker shows only where footage plays at it (the last clip's end counts).
        guard project.clips.contains(where: { !$0.isEmpty && marker.time >= $0.sourceStart &&
            (marker.time < $0.sourceEnd || (marker.time == $0.sourceEnd && marker.time == project.clips.last?.sourceEnd)) }),
              let at = map.outputTime(atSource: marker.time) else { continue }
        out.append(Item(id: marker.id, kind: .marker, track: 0, out: TimeRange(start: at, end: at), spine: TimeRange(start: marker.time, end: marker.time),
                        media: nil, anchor: .spine, editable: editableFields(.marker), label: marker.label))
    }
    // Only what plays: a block over a trailing gap (past the export, e.g. Free mode) is never seen (T-911 fuzz).
    let end = project.exportDuration
    return out.compactMap { item in
        guard item.kind != .clip, item.kind != .gap, item.kind != .marker else { return item }
        guard item.out.start < end - 1e-9 else { return nil }
        var visible = item
        visible.out.end = min(item.out.end, end)
        return visible
    }
}
