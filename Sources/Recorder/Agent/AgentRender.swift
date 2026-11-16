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
    @MainActor static func frames(model: EditorModel, at times: [Double], longEdge: Int, folder: URL) async throws -> [URL] {
        guard !times.isEmpty, times.count <= 24, (2...640).contains(longEdge) else {
            throw MCPFailure(code: "OUT_OF_RANGE", message: "Use 1–24 frame times and longEdge 2–640")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let images = try await EditorWindowController.renderFramesPNG(model: renderModel(for: model, project: model.project), at: times, longEdge: longEdge)
        var files: [URL] = []
        do {
            for image in images {
                try Task.checkCancellation()
                let url = folder.appendingPathComponent("frame-\(UUID().uuidString).png")
                try image.write(to: url, options: .atomic)
                files.append(url)
            }
            return files
        } catch { for url in files { try? FileManager.default.removeItem(at: url) }; throw error }
    }
    @MainActor static func sheet(model: EditorModel, at times: [Double], folder: URL) async throws -> URL {
        let frames = try await frames(model: model, at: times, longEdge: 320, folder: folder)
        defer { for frame in frames { try? FileManager.default.removeItem(at: frame) } }
        let images = try frames.map { url -> CGImage in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw MCPFailure(code: "INVALID_OP", message: "Could not read a rendered frame; retry render.sheet")
            }
            return image
        }
        let cellWidth = 320, cellHeight = (images.map(\.height).max() ?? 200) + 24
        let width = cellWidth * 4, height = cellHeight * ((images.count + 3) / 4)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: VideoColor.space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw MCPFailure(code: "INVALID_OP", message: "Could not create a contact sheet; retry with fewer frames")
        }
        context.setFillColor(Theme.bgWindow.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        for (i, image) in images.enumerated() {
            try Task.checkCancellation()
            let x = (i % 4) * cellWidth, y = height - (i / 4 + 1) * cellHeight
            context.draw(image, in: CGRect(x: x + (cellWidth - image.width) / 2, y: y + 24, width: image.width, height: image.height))
            let tenths = Int((times[i] * 10).rounded())
            let time = String(format: "%d:%02d.%d", tenths / 600, tenths / 10 % 60, tenths % 10)
            (time as NSString).draw(at: CGPoint(x: x + 8, y: y + 5), withAttributes: [.font: Theme.timecodeFont(11), .foregroundColor: Theme.textPrimary])
        }
        let url = folder.appendingPathComponent("sheet-\(UUID().uuidString).jpg")
        guard let image = context.makeImage(), let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw MCPFailure(code: "INVALID_OP", message: "Could not encode the contact sheet; retry render.sheet")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: url)
            throw MCPFailure(code: "INVALID_OP", message: "Could not save the contact sheet; check cache disk space and retry")
        }
        return url
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
