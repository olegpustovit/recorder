import CoreGraphics
import ImageIO
import RecorderCore
import Vision

/// Opt-in per-shot captions (T-832): on-device Vision OCR on the shot's focus region at its settled keyframe, classifier label as fallback.
enum AgentCaptions {
    /// Returns the storyboard with `caption` filled where recognition produced something; shots stay nil on any failure.
    /// Frames are rendered uncropped/unzoomed so `focus` (source-frame space) maps directly; Vision then runs off the main thread.
    @MainActor static func captionShots(_ storyboard: Storyboard, model: EditorModel) async throws -> Storyboard {
        var board = storyboard
        var project = model.liveProject
        let map = TimeMap(project.clips)
        project.crop = NormRect(); project.zooms = []; project.layouts = []
        let frozen = AgentRender.renderModel(for: model, project: project)
        // Typing shots are never captioned: their focus is the typed text, and key presses are never shared.
        let anchored = board.shots.indices.filter { board.shots[$0].kind != .typing }.compactMap { i in AgentRender.keyframe(board.shots[i], fps: board.fps, map: map).map { (i, $0.output) } }
        for chunk in stride(from: 0, to: anchored.count, by: 12).map({ Array(anchored[$0 ..< min($0 + 12, anchored.count)]) }) {
            try Task.checkCancellation()
            guard let pngs = try? await EditorWindowController.renderFramesPNG(model: frozen, at: chunk.map(\.1), longEdge: 1280), pngs.count == chunk.count else { continue }
            let jobs = zip(chunk, pngs).map { ($0.0, $1, board.shots[$0.0].focus) }
            let task = Task.detached { () throws -> [(Int, String?)] in
                try jobs.map { i, png, focus in try Task.checkCancellation(); return (i, caption(png: png, focus: focus)) }
            }
            for (i, text) in try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() }) { board.shots[i].caption = text }
        }
        return board
    }
    static func caption(png: Data, focus: NormRect) -> String? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil), let full = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let w = Double(full.width), h = Double(full.height)
        let crop = CGRect(x: focus.x * w, y: focus.y * h, width: focus.w * w, height: focus.h * h).integral.intersection(CGRect(x: 0, y: 0, width: w, height: h))
        // too-small focus: no caption rather than OCR of unrelated on-screen text (privacy)
        guard !crop.isNull, crop.width >= 32, crop.height >= 32, let image = full.cropping(to: crop) else { return nil }
        let text = VNRecognizeTextRequest(); text.recognitionLevel = .accurate
        let classify = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        guard (try? handler.perform([text, classify])) != nil else { return nil }
        // Low-confidence OCR is noise ("(kEyldDN '…"): no caption beats a wrong one.
        let lines = (text.results ?? []).compactMap { $0.topCandidates(1).first }.filter { $0.confidence >= 0.5 }.map(\.string)
        let label = classify.results?.first { $0.confidence > 0.3 }?.identifier
        return ShotCaption.shape(lines.isEmpty ? [label].compactMap { $0 } : lines)
    }
}
