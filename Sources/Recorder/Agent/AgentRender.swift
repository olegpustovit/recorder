import AppKit
import AVFoundation
import ImageIO
import RecorderCore
import UniformTypeIdentifiers

enum AgentRender {
    static var cacheRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/Recorder/Agent", isDirectory: true)
    }
    static func cacheFolder(session: String) -> URL {
        let folder = cacheRoot.appendingPathComponent(session, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return folder
    }
    static func purgeOldCaches(olderThan days: Int = 7) {
        let cutoff = Date().addingTimeInterval(-Double(max(0, days)) * 86_400)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        for folder in (try? FileManager.default.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: Array(keys))) ?? [] {
            guard UUID(uuidString: folder.lastPathComponent) != nil,
                  let values = try? folder.resourceValues(forKeys: keys), values.isDirectory == true, values.isSymbolicLink != true,
                  let modified = values.contentModificationDate, modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: folder)
        }
    }
    @MainActor static func renderModel(for model: EditorModel, project: Project) -> EditorModel {
        let paths = project == model.project ? (model.cursorPath, model.cameraPath) : nil
        var project = project
        project.keys.show = false
        for i in project.keystrokeClips.indices { project.keystrokeClips[i].keys?.show = false }
        let events = EventLog(events: model.events.events.filter { $0.k != .key && $0.k != .typing }, windowFrames: model.events.windowFrames)
        return EditorModel(packageURL: model.packageURL, project: project, events: events, paths: paths)
    }
    @MainActor static func frames(model: EditorModel, at times: [Double], longEdge: Int, folder: URL, grid: Bool = false) async throws -> [URL] {
        guard !times.isEmpty, times.count <= 48, (2...640).contains(longEdge) else {
            throw MCPFailure(code: "OUT_OF_RANGE", message: "Use 1–48 frame times and longEdge 2–640")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let images = try await EditorWindowController.renderFramesPNG(model: renderModel(for: model, project: model.project), at: times, longEdge: longEdge)
        var files: [URL] = []
        do {
            for image in images {
                try Task.checkCancellation()
                let url = folder.appendingPathComponent("frame-\(UUID().uuidString).png")
                try (grid ? try drawGrid(on: image) : image).write(to: url, options: .atomic)
                files.append(url)
            }
            return files
        } catch { for url in files { try? FileManager.default.removeItem(at: url) }; throw error }
    }
    /// Overlays the 0.1-step normalized grid (origin top-left) on a rendered PNG; only used when the agent asks for `grid`.
    static func drawGrid(on png: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                      space: VideoColor.space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw MCPFailure(code: "INVALID_OP", message: "Could not draw the debug grid; retry without grid")
        }
        let w = image.width, h = image.height
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let font = NSFont.monospacedSystemFont(ofSize: max(8, CGFloat(min(w, h)) / 40), weight: .regular)
        for line in DebugGrid.lines {
            let color = NSColor(calibratedRed: 1, green: 0.2, blue: 0.8, alpha: line.major ? 0.9 : 0.45)
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(line.major ? 2 : 1)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            switch line.axis {
            case .vertical:
                let x = DebugGrid.pixel(line.value, length: w) + 0.5
                context.move(to: CGPoint(x: x, y: 0)); context.addLine(to: CGPoint(x: x, y: CGFloat(h))); context.strokePath()
                if line.major { (line.label as NSString).draw(at: CGPoint(x: min(x + 2, CGFloat(w) - font.pointSize * 2.5), y: CGFloat(h) - font.pointSize * 1.4), withAttributes: attributes) }
            case .horizontal:
                let y = CGFloat(h) - 0.5 - DebugGrid.pixel(line.value, length: h)   // CG origin is bottom-left; grid origin is top-left
                context.move(to: CGPoint(x: 0, y: y)); context.addLine(to: CGPoint(x: CGFloat(w), y: y)); context.strokePath()
                if line.major && line.value > 0 { (line.label as NSString).draw(at: CGPoint(x: 2, y: y + 2), withAttributes: attributes) }
            }
        }
        guard let output = context.makeImage(), let data = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw MCPFailure(code: "INVALID_OP", message: "Could not encode the debug grid frame; retry without grid")
        }
        CGImageDestinationAddImage(destination, output, nil)
        guard CGImageDestinationFinalize(destination) else { throw MCPFailure(code: "INVALID_OP", message: "Could not encode the debug grid frame; retry without grid") }
        return data as Data
    }
    @MainActor static func sheet(model: EditorModel, at times: [Double], labels: [String]? = nil, columns: Int = 4, folder: URL) async throws -> URL {
        let portrait = model.project.source.pixelHeight > model.project.source.pixelWidth
        return try tiles(try await frames(model: model, at: times, longEdge: 320, folder: folder), labels: labels ?? times.map(timecode), columns: portrait ? 8 : columns, folder: folder)
    }
    /// Settled keyframe of a shot: output seconds just before the end of its last kept piece, plus the KEPT duration; nil when the draft dropped it all.
    static func keyframe(_ shot: Shot, fps: Double, map: TimeMap) -> (output: Double, kept: Double)? {
        var spans: [(Double, Double)] = [], output = 0.0, mapped: [Double] = []
        for clip in map.clips {
            defer { output += clip.outputDuration }
            guard !clip.isEmpty, clip.file == nil else { continue }   // recording clips only, like sourceRanges
            let a = max(shot.from, clip.sourceStart), b = min(shot.to, clip.sourceEnd)
            guard b > a else { continue }
            spans.append((a, b))
            mapped.append(output + (min(b, max(a, b - 1.5 / max(fps, 1))) - clip.sourceStart) / clip.timeScale)
        }
        guard let last = mapped.last else { return nil }
        return (last, spans.reduce(0) { $0 + $1.1 - $1.0 })
    }
    static func timecode(_ t: Double) -> String {
        let tenths = Int((t * 10).rounded())
        return String(format: "%d:%02d.%d", tenths / 600, tenths / 10 % 60, tenths % 10)
    }
    /// Draws rendered frame files (deleted afterwards) into one labelled JPEG grid.
    @MainActor static func tiles(_ frames: [URL], labels: [String], columns: Int, folder: URL) throws -> URL {
        defer { for frame in frames { try? FileManager.default.removeItem(at: frame) } }
        let images = try frames.map { url -> CGImage in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw MCPFailure(code: "INVALID_OP", message: "Could not read a rendered frame; retry the render")
            }
            return image
        }
        let cellWidth = max(120, images.map(\.width).max() ?? 320), cellHeight = (images.map(\.height).max() ?? 200) + 24
        let width = cellWidth * columns, height = cellHeight * ((images.count + columns - 1) / columns)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: VideoColor.space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw MCPFailure(code: "INVALID_OP", message: "Could not create a contact sheet; retry with fewer tiles")
        }
        context.setFillColor(Theme.bgWindow.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        for (i, image) in images.enumerated() {
            try Task.checkCancellation()
            let x = (i % columns) * cellWidth, y = height - (i / columns + 1) * cellHeight
            context.draw(image, in: CGRect(x: x + (cellWidth - image.width) / 2, y: y + 24, width: image.width, height: image.height))
            (labels[i] as NSString).draw(at: CGPoint(x: x + 8, y: y + 5), withAttributes: [.font: Theme.timecodeFont(11), .foregroundColor: Theme.textPrimary])
        }
        let url = folder.appendingPathComponent("sheet-\(UUID().uuidString).jpg")
        guard let image = context.makeImage(), let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw MCPFailure(code: "INVALID_OP", message: "Could not encode the contact sheet; retry the render")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: url)
            throw MCPFailure(code: "INVALID_OP", message: "Could not save the contact sheet; check cache disk space and retry")
        }
        return url
    }
    /// Base (live) and draft frames side by side, one row per draft time: the base row shows the same source moment (cuts
    /// shift the timelines apart), clamped to the base when that footage isn't in it. Labels carry draft, base and source time.
    @MainActor static func compare(base: EditorModel, draft: EditorModel, at times: [Double], folder: URL) async throws -> URL {
        let sources = times.map { TimeMap(draft.project.clips).sourceTime(atOutput: $0) }
        let baseTimes = zip(times, sources).map { t, s in min(TimeMap(base.project.clips).outputTime(atSource: s) ?? t, base.project.exportDuration) }
        let b = try await frames(model: base, at: baseTimes, longEdge: 320, folder: folder)
        let d: [URL]
        do { d = try await frames(model: draft, at: times, longEdge: 320, folder: folder) }
        catch { for url in b { try? FileManager.default.removeItem(at: url) }; throw error }
        let labels = times.indices.flatMap { i in ["base " + timecode(baseTimes[i]) + " · src " + timecode(sources[i]), "draft " + timecode(times[i]) + " · src " + timecode(sources[i])] }
        return try tiles(zip(b, d).flatMap { [$0, $1] }, labels: labels, columns: 2, folder: folder)
    }
    @MainActor static func clip(model: EditorModel, from: Double, to: Double, folder: URL, progress: @escaping (Double) -> Void) async throws -> URL {
        guard from.isFinite, to.isFinite, from >= 0, to > from, to <= model.project.exportDuration else {
            throw MCPFailure(code: "OUT_OF_RANGE", message: "Use 0 ≤ from < to ≤ project duration; call project.info")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = folder.appendingPathComponent("proxy-\(UUID().uuidString).mp4")
        let frozen = renderModel(for: model, project: model.project)
        let exporter = Exporter(model: frozen, settings: ExportSettings(shortEdge: 540, fps: 30, quality: .web, codec: .h264),
                                destination: url, outputRange: TimeRange(start: from, end: to))
        exporter.progress = { value, _, _ in Task { @MainActor in progress(value) } }
        do {
            try Task.checkCancellation()
            try await withTaskCancellationHandler { try await exporter.run() } onCancel: { exporter.cancel() }
            try Task.checkCancellation()
            return url
        } catch { try? FileManager.default.removeItem(at: url); throw error }
    }
}
