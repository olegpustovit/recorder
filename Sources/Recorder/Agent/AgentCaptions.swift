import CoreGraphics
import ImageIO
import RecorderCore
import Vision

/// Opt-in per-shot captions (T-832): on-device Vision OCR on the shot's focus region at its settled keyframe, classifier label as fallback.
enum AgentCaptions {
    /// Returns the storyboard with `caption` filled where recognition produced something; shots stay nil on any failure.
    /// ponytail: captions the live project's keyframes (zoom/crop effects included), not source pixels; upgrade by decoding the source frame.
    @MainActor static func captionShots(_ storyboard: Storyboard, model: EditorModel) async -> Storyboard {
        var board = storyboard
        let project = model.liveProject
        let map = TimeMap(project.clips), frozen = AgentRender.renderModel(for: model, project: project)
        let anchored = board.shots.indices.compactMap { i in AgentRender.keyframe(board.shots[i], fps: board.fps, map: map).map { (i, $0) } }
        for chunk in stride(from: 0, to: anchored.count, by: 12).map({ Array(anchored[$0 ..< min($0 + 12, anchored.count)]) }) {
            guard let pngs = try? await EditorWindowController.renderFramesPNG(model: frozen, at: chunk.map(\.1), longEdge: 1280), pngs.count == chunk.count else { continue }
            for ((i, _), png) in zip(chunk, pngs) { board.shots[i].caption = caption(png: png, focus: board.shots[i].focus) }
        }
        return board
    }
    static func caption(png: Data, focus: NormRect) -> String? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil), let full = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let w = Double(full.width), h = Double(full.height)
        let crop = CGRect(x: focus.x * w, y: focus.y * h, width: focus.w * w, height: focus.h * h).integral.intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard let image = (crop.width >= 32 && crop.height >= 32 ? full.cropping(to: crop) : full) else { return nil }
        let text = VNRecognizeTextRequest(); text.recognitionLevel = .fast
        let classify = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        guard (try? handler.perform([text, classify])) != nil else { return nil }
        let lines = (text.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        let label = classify.results?.first { $0.confidence > 0.3 }?.identifier
        return ShotCaption.shape(lines.isEmpty ? [label].compactMap { $0 } : lines)
    }
}
