import AppKit
import AVFoundation
import ImageIO
import Metal
import RecorderCore

/// Native decoder + compositor checks. Proofs stay in a uniquely owned temporary directory.
enum RecordingLayerSelfTest {
    struct Failure: Error, CustomStringConvertible { let description: String }

    @MainActor static func runLiftIdentity(_ args: [String]) async throws {
        let root = try proofDirectory("lift-identity")
        try await makeMedia(in: root)
        var lines: [String] = []
        defer { try? lines.joined(separator: "\n").write(to: root.appendingPathComponent("results.log"), atomically: true, encoding: .utf8) }
        for canonical in [false, true] {
            for framed in [false, true] {
                var project = fixture(canonical: canonical, framed: framed)
                let name = "\(canonical ? "canonical" : "legacy")-\(framed ? "frame" : "bare")"
                try await identity(project, selected: [1], times: [4 + 1.0 / 60, 4.1, 4.5, 5.5, 6 - 1.0 / 60],
                                   name: name, root: root, lines: &lines)
                // A cut through a live instant auto zoom must retain its cursor/deadzone history.
                project.zooms = [Zoom(start: 1, end: canonical ? 10 : 11, scale: 2.3, mode: .auto, instant: true)]
                try await identity(project, selected: [1], times: [4 + 1.0 / 60, 4.1, 4.5, 5.9],
                                   name: name + "-instant", root: root, lines: &lines)
            }
        }
        var sole = fixture(canonical: false, framed: true)
        sole.clips = [Clip(sourceStart: 0, sourceEnd: 12)]
        try await identity(sole, selected: [0], times: [0.1, 4 + 1.0 / 60, 4.5, 7.9, 11.9, 4.1],
                           name: "sole-tail-backwards", root: root, lines: &lines)
        var windows = fixture(canonical: true, framed: true, windows: true)
        windows.clips[1].mediaStart = 0
        windows.zooms = [Zoom(start: 1, end: 10, scale: 1.8, mode: .auto, instant: true)]
        try await identity(windows, selected: [1], times: [4 + 1.0 / 60, 4.1, 4.5, 5 - 1.0 / 60, 5, 5.1, 5.9],
                           name: "repeated-media-windows", root: root, lines: &lines)
        print("lift-identity maxDelta=0; proofs \(root.path)")
    }

    @MainActor static func runParity(_ args: [String]) async throws {
        let root = try proofDirectory("layer-recording-parity")
        try await makeMedia(in: root)
        var lines: [String] = []
        defer { try? lines.joined(separator: "\n").write(to: root.appendingPathComponent("results.log"), atomically: true, encoding: .utf8) }
        for multiwindow in [false, true] {
            var project = fixture(canonical: true, framed: true, windows: multiwindow)
            if multiwindow { project.clips[1].mediaStart = 0 }
            let ids = project.liftClips([1], toTrack: 0, atOutput: 4, copy: false)
            try require(ids.count == 1, "Parity lift refused")
            try await parity(project, times: [4 + 1.0 / 60, 4.1, 4.5, 5, 5.1, 5.9, 4.1],
                             name: multiwindow ? "windows" : "mixed-rate", root: root, lines: &lines)
            // Copies are independent scenes. Compare each real preview/export result; their
            // overlap with Main legitimately draws a second translucent frame shadow.
            var copied = fixture(canonical: true, framed: true, windows: multiwindow)
            if multiwindow { copied.clips[1].mediaStart = 0 }
            let sourceIDs = Set(copied.zooms.map(\.id) + copied.masks.map(\.id) + copied.windowShots.map(\.id))
            let copiedIDs = copied.liftClips([1], toTrack: 0, atOutput: 8, copy: true)
            try require(copiedIDs.count == 1, "Copy lift refused")
            let layer = copied.layers.first { $0.id == copiedIDs[0].uuidString }!
            let carriedIDs = Set((layer.scene?.zooms ?? []).map(\.id) + (layer.scene?.masks ?? []).map(\.id) + (layer.scene?.windowShots ?? []).map(\.id))
            try require(carriedIDs.isDisjoint(with: sourceIDs), "Copy reused source scene IDs")
            let copiedModel = EditorModel(packageURL: root, project: copied, events: events(windows: multiwindow))
            for offset in [0.125, 0.5, 1.5] {
                let source = makeFrameState(model: copiedModel, outputTime: 4 + offset, screen: nil, camera: nil, size: CGSize(width: 320, height: 180))
                let duplicate = makeFrameState(model: copiedModel, outputTime: 8 + offset, screen: nil, camera: nil, size: CGSize(width: 320, height: 180)).layers.first { $0.block.id == layer.id }!
                try require(source.view == duplicate.view && source.prevView == duplicate.prevView, "Copy changed camera sampling at \(offset)")
                try require(cursorValues(source.cursor) == cursorValues(duplicate.cursor) && source.cursor?.imageID == duplicate.cursor?.imageID,
                            "Copy changed cursor sampling at \(offset)")
            }
            let sourceView = makeFrameState(model: copiedModel, outputTime: 4.5, screen: nil, camera: nil, size: CGSize(width: 320, height: 180)).view
            copiedModel.edit("Edit copied scene") { project in
                if let index = project.layers.firstIndex(where: { $0.id == layer.id }), project.layers[index].scene?.zooms.isEmpty == false {
                    project.layers[index].scene?.zooms[0].scale = 3.5
                }
            }
            try require(makeFrameState(model: copiedModel, outputTime: 4.5, screen: nil, camera: nil, size: CGSize(width: 320, height: 180)).view == sourceView,
                        "Editing a copy changed Main camera history")
            try await parity(copied, times: [8 + 1.0 / 60, 8.1, 8.5, 9, 9.9, 8.1],
                             name: multiwindow ? "copy-windows" : "copy", root: root, lines: &lines)
        }
        var sole = fixture(canonical: false, framed: true)
        sole.clips = [Clip(sourceStart: 0, sourceEnd: 12)]
        try require(sole.liftClips([0], toTrack: 0, atOutput: 0, copy: false).count == 1, "Sole clip lift refused")
        try await parity(sole, times: [0.1, 4.1, 11.9, 4.1], name: "sole-tail-backwards", root: root, lines: &lines)
        print("layer-recording-parity maxDelta=0; proofs \(root.path)")
    }

    @MainActor private static func identity(_ original: Project, selected: Set<Int>, times: [Double], name: String,
                                            root: URL, lines: inout [String]) async throws {
        var lifted = original
        let first = selected.min()!
        let at = original.clips.prefix(first).reduce(0) { $0 + $1.outputDuration }
        try require(lifted.liftClips(selected, toTrack: 0, atOutput: at, copy: false).count == selected.count, "\(name): lift refused")
        try require(lifted.checkInvariants() == nil, "\(name): invalid lifted project")
        let before = EditorModel(packageURL: root, project: original, events: events(windows: original.windowCount > 1))
        let after = EditorModel(packageURL: root, project: lifted, events: events(windows: original.windowCount > 1))
        for (index, time) in times.enumerated() {
            before.playhead = time; after.playhead = time
            let a = try await EditorWindowController.renderCurrentFramePNG(model: before)
            let b = try await EditorWindowController.renderCurrentFramePNG(model: after)
            let label = "\(name)-\(index)-t\(String(format: "%.4f", time))"
            try a.write(to: root.appendingPathComponent(label + "-before.png"))
            try b.write(to: root.appendingPathComponent(label + "-after.png"))
            let delta = try compare(image(a), image(b))
            let result = "lift-identity \(label) maxDelta=\(delta)"
            lines.append(result); print(result)
            try require(delta == 0, result)
        }
    }

    @MainActor private static func parity(_ project: Project, times: [Double], name: String,
                                          root: URL, lines: inout [String]) async throws {
        var project = project
        // Square avoids a fractional preview letterbox from even-pixel aspect rounding at different resolutions.
        project.output.aspect = .r1x1
        let model = EditorModel(packageURL: root, project: project, events: events(windows: project.windowCount > 1))
        guard let device = MTLCreateSystemDefaultDevice() else { throw Failure(description: "Metal required") }
        let compositor = try Compositor(device: device, package: root)
        let longEdge = max(2, Int(max(Double(project.source.pixelWidth) * project.crop.w, Double(project.source.pixelHeight) * project.crop.h).rounded()))
        let size = compositor.outputSize(for: project, longEdge: longEdge)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let preview = PreviewView(model: model, preparedCompositor: compositor)
        window.contentView = preview
        preview.autoResizeDrawable = false
        preview.drawableSize = size
        window.orderFront(nil)
        defer { window.close() }
        for (index, time) in times.enumerated() {
            let live = try await preview.captureRenderedFrame(atOutput: time)
            let exported = try await EditorWindowController.renderCurrentFramePNG(model: model)
            let label = "\(name)-\(index)-t\(String(format: "%.4f", time))"
            try png(live).write(to: root.appendingPathComponent(label + "-preview.png"))
            try exported.write(to: root.appendingPathComponent(label + "-export.png"))
            let delta = try compare(live, image(exported))
            let result = "layer-recording-parity \(label) maxDelta=\(delta)"
            lines.append(result); print(result)
            try require(delta == 0, result)
        }
    }

    private static func fixture(canonical: Bool, framed: Bool, windows: Bool = false) -> Project {
        var clips = [Clip(sourceStart: 0, sourceEnd: 4), Clip(sourceStart: 4, sourceEnd: 8, speed: 2), Clip(sourceStart: 8, sourceEnd: 12, speed: 0.5)]
        if canonical {
            clips[0].mediaStart = 0; clips[0].clockSpeed = 1
            clips[1].sourceEnd = 6; clips[1].mediaStart = 4; clips[1].clockSpeed = 1
            clips[2].sourceStart = 6; clips[2].sourceEnd = 14; clips[2].mediaStart = 8; clips[2].clockSpeed = 1
        }
        var project = Project(title: "Recording layer native regression", source: Source(kind: .window,
            pixelWidth: 320, pixelHeight: 180, duration: 12,
            windowSizes: windows ? [PixelSize(w: 320, h: 180), PixelSize(w: 240, h: 240)] : []), clips: clips,
            zooms: [Zoom(start: 3.75, end: 7, scale: 2.2, center: NormPoint(x: 0.62, y: 0.4))],
            masks: [Mask(start: 3.9, end: 8.1, kind: .highlight, rect: NormRect(x: 0.25, y: 0.2, w: 0.35, h: 0.45), opacity: 0.7, transition: 1)],
            windowShots: windows ? [WindowShot(start: 0, end: 5, window: 0), WindowShot(start: 5, end: 14, window: 1)] : [],
            crop: windows ? NormRect() : NormRect(x: 0.1, y: 0.1, w: 0.8, h: 0.8),
            background: Background(kind: .color, color: "#263044"), frame: Frame(padding: 0.12, cornerRadius: 0.04, inset: 0.01, shadow: 0.6, enabled: framed),
            cursor: CursorStyle(size: 2, hideWhenIdle: false), audioTracks: [], audioClips: [])
        project.rippleDelete = false
        return project
    }

    private static func events(windows: Bool) -> EventLog {
        var samples = [InputEvent(t: 0, k: .cursor, id: "test-pointer")]
        for index in 0...240 {
            let t = Double(index) / 20
            let x = 0.15 + 0.7 * (0.5 + 0.5 * sin(t * 1.7))
            let y = 0.2 + 0.6 * (0.5 + 0.5 * cos(t * 1.1))
            samples.append(InputEvent(t: t, k: .move, x: windows ? x * 200 + 80 : x, y: windows ? y * 120 + 30 : y))
        }
        return EventLog(events: samples.sorted { $0.t < $1.t }, windowFrames: windows ? [
            WindowFrame(t: 0, i: 0, x: 0, y: 0, w: 320, h: 180),
            WindowFrame(t: 0, i: 1, x: 60, y: 10, w: 240, h: 240)] : nil)
    }

    private static func proofDirectory(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("recorder-\(name)-\(UUID().uuidString).recorder")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try Data("T-713 owned native fixture\n".utf8).write(to: root.appendingPathComponent(".recording-selftest"))
        print("Recording fixture/proofs: \(root.path)")
        return root
    }

    private static func makeMedia(in root: URL) async throws {
        try await movie(root.appendingPathComponent("screen.mov"), width: 320, height: 180, alternate: false)
        try await movie(root.appendingPathComponent("window-1.mov"), width: 240, height: 240, alternate: true)
        let dir = root.appendingPathComponent("cursors")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        let bytes = (0..<(16 * 16)).flatMap { index -> [UInt8] in
            let edge = index % 16 < 3 || index / 16 < 3
            return edge ? [255, 255, 255, 255] : [0, 0, 0, 0]
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let cursor = CGImage(width: 16, height: 16, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 64,
            space: VideoColor.space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        try png(cursor).write(to: dir.appendingPathComponent("test-pointer.png"))
        try Data("{\"hotX\":0,\"hotY\":0,\"scale\":1}".utf8).write(to: dir.appendingPathComponent("test-pointer.json"))
    }

    private static func movie(_ url: URL, width: Int, height: Int, alternate: Bool) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width, AVVideoHeightKey: height, AVVideoColorPropertiesKey: VideoColor.properties])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? Failure(description: "Writer start") }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<360 {
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else { throw writer.error ?? Failure(description: "Writer stalled") }
                try await Task.sleep(for: .milliseconds(2))
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { throw Failure(description: "Fixture pixel buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            let ptr = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<height { for x in 0..<width {
                let i = y * stride + x * 4
                ptr[i] = UInt8((x + frame * 3) % 220 + 20)
                ptr[i + 1] = UInt8((y + frame) % 180 + 30)
                ptr[i + 2] = alternate ? 40 : UInt8((x / 16 + y / 16) % 2 == 0 ? 210 : 80)
                ptr[i + 3] = 255
            } }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else { throw writer.error ?? Failure(description: "Fixture append") }
        }
        input.markAsFinished()
        await writer.finishWriting()
        try require(writer.status == .completed, "Fixture writer \(String(describing: writer.error))")
    }

    private static func image(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure(description: "PNG decode") }
        return image
    }

    private static func cursorValues(_ cursor: CursorSample?) -> [Double] {
        guard let cursor else { return [] }
        return [cursor.x, cursor.y, cursor.prevX, cursor.prevY, cursor.alpha, cursor.rotation, cursor.clickScale]
    }

    private static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { throw Failure(description: "PNG destination") }
        CGImageDestinationAddImage(destination, image, nil)
        try require(CGImageDestinationFinalize(destination), "PNG encode")
        return data as Data
    }

    private static func compare(_ a: CGImage, _ b: CGImage) throws -> Int {
        try require(a.width == b.width && a.height == b.height, "Pixel sizes differ: \(a.width)x\(a.height) vs \(b.width)x\(b.height)")
        func bytes(_ image: CGImage) throws -> [UInt8] {
            var result = [UInt8](repeating: 0, count: image.width * image.height * 4)
            try result.withUnsafeMutableBytes { storage in
                guard let context = CGContext(data: storage.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: VideoColor.space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure(description: "Pixel comparison context") }
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            return result
        }
        let left = try bytes(a), right = try bytes(b)
        return zip(left, right).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }
}
