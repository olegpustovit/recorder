import Foundation

public extension Project {
    /// Regeneration follows footage through cuts, copies and rate changes; each occurrence owns its zooms.
    func generatedAutoZooms(events: EventLog) -> [Zoom] {
        var result: [Zoom] = []
        var previous: Clip?
        for clip in clips where !clip.isEmpty {
            let mapped = remapWindowEvents(events, project: self, clip: clip).events
            for zoom in generateAutoZooms(clicks: mapped.clicks(), duration: source.duration) {
                let start = max(zoom.start, clip.mediaIn), end = min(zoom.end, clip.mediaEnd)
                guard end > start else { continue }
                var part = zoom
                part.start = clip.sourceStart + (start - clip.mediaIn) * clip.timeScale / clip.speed
                part.end = clip.sourceStart + (end - clip.mediaIn) * clip.timeScale / clip.speed
                if let previous, let last = result.last,
                   abs(previous.mediaEnd - clip.mediaIn) < 1e-8,
                   abs(previous.sourceEnd - clip.sourceStart) < 1e-8,
                   abs(last.end - part.start) < 1e-8, abs(part.start - clip.sourceStart) < 1e-8 {
                    result[result.count - 1].end = part.end
                } else { result.append(part) }
            }
            previous = clip
        }
        return result.filter { $0.end - $0.start >= 0.5 }
    }
}

/// SPEC §6.4: builds the initial `zooms` array for a finished recording from its click events.
/// `Edit ▸ Regenerate Auto Zooms` calls this again over the same `events.json`; `Edit ▸ Remove All
/// Zooms` just empties `project.zooms` (no call here).
public func generateAutoZooms(clicks: [InputEvent], duration: Double, lead: Double = 0.4, tail: Double = 1.5) -> [Zoom] {
    // 1. Left-button down events, oldest first (the input isn't guaranteed sorted).
    let downs = clicks.filter { $0.k == .down && $0.b == 0 }.sorted { $0.t < $1.t }

    // 2. Cluster: a click joins the current cluster if it's < 3 s after AND < 0.25 (normalised)
    // from the previous click; otherwise it starts a new cluster.
    var clusters: [[InputEvent]] = []
    for click in downs {
        if let prev = clusters.last?.last, click.t - prev.t < 3.0, normDistance(click, prev) < 0.25 {
            clusters[clusters.count - 1].append(click)
        } else {
            clusters.append([click])
        }
    }

    // 3. Each cluster becomes one zoom.
    let zooms = clusters.map { cluster in
        Zoom(start: cluster.first!.t - lead, end: cluster.last!.t + tail, scale: 2.0, mode: .auto)
    }

    // 4. Merge zooms whose gap is < 1.0 s. Clusters are already start-sorted, so a single linear
    // pass (classic interval merge) is enough.
    var merged: [Zoom] = []
    for zoom in zooms {
        if var last = merged.last, zoom.start - last.end < 1.0 {
            last.end = max(last.end, zoom.end)
            merged[merged.count - 1] = last
        } else {
            merged.append(zoom)
        }
    }

    // 5. Clamp to [0, duration] first, then drop anything left shorter than 1.0 s (clamping can
    // shrink a zoom below the threshold near the recording's edges).
    return merged.compactMap { zoom in
        var z = zoom
        z.start = min(max(z.start, 0), duration)
        z.end = min(max(z.end, 0), duration)
        return z.end - z.start >= 1.0 ? z : nil
    }
}

private func normDistance(_ a: InputEvent, _ b: InputEvent) -> Double {
    let dx = (a.x ?? 0) - (b.x ?? 0)
    let dy = (a.y ?? 0) - (b.y ?? 0)
    return (dx * dx + dy * dy).squareRoot()
}
