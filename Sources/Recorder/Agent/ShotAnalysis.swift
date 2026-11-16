import AVFoundation
import CryptoKit
import RecorderCore

/// analyze.shots (T-827) app half: decode screen.mov at 10 fps, 1/8 scale luma, and reduce it to `FrameSignal`s
/// (RecorderCore.storyboard does the segmentation). Signals are cached in the package per media fingerprint.
enum ShotAnalysis {
    static let fps = 10.0
    /// Bump whenever decoding or the signal maths change: it is part of the cache key.
    static let algorithmVersion = 2
    private static let cacheName = "shots-cache.json"
    private struct Cache: Codable { var key: String; var signals: [FrameSignal] }

    // ponytail: fingerprint = size + mtime + SHA256 of the first MB, not the whole file; an in-place edit past 1 MB that
    // keeps size and mtime would be missed. Upgrade: hash the full file.
    static func fingerprint(_ url: URL) throws -> String {
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let mtime = (try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970) ?? 0
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let head = try handle.read(upToCount: 1 << 20) ?? Data()
        return "\(size)-\(mtime)-" + SHA256.hash(data: head).map { String(format: "%02x", $0) }.joined()
    }

    static func signals(package: URL, progress: @escaping (Double) -> Void) async throws -> [FrameSignal] {
        let media = package.appendingPathComponent("screen.mov"), cacheURL = package.appendingPathComponent(cacheName)
        guard FileManager.default.fileExists(atPath: media.path) else {
            throw MCPFailure(code: "NO_PROJECT", message: "This project has no screen.mov to analyze; analyze.shots needs a screen recording")
        }
        let key = "v\(algorithmVersion)-" + (try fingerprint(media))
        if let data = try? Data(contentsOf: cacheURL), let cache = try? JSONDecoder().decode(Cache.self, from: data), cache.key == key {
            return cache.signals
        }
        let result = try await decode(media, progress: progress)
        try? JSONEncoder().encode(Cache(key: key, signals: result)).write(to: cacheURL, options: .atomic)
        return result
    }

    private static func decode(_ url: URL, progress: @escaping (Double) -> Void) async throws -> [FrameSignal] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw MCPFailure(code: "NO_PROJECT", message: "screen.mov has no video track")
        }
        let duration = try await asset.load(.duration).seconds, size = try await track.load(.naturalSize)
        var w = max(16, Int(size.width) / 8 & ~1), h = max(16, Int(size.height) / 8 & ~1)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }

        let ticks = max(1, Int((duration * fps).rounded(.down)))
        var signals: [FrameSignal] = [], previous: [UInt8]?, lastProgress = 0.0
        var latest: CVPixelBuffer?   // reference only: pixels are copied just when a 0.1 s tick is due
        // ScreenCaptureKit writes frames only when content changes, so each 0.1 s tick shows the latest frame at or before it.
        func emit(upTo time: Double) {
            guard let buffer = latest, signals.count < ticks, Double(signals.count) / fps < time else { return }
            CVPixelBufferLockBaseAddress(buffer, .readOnly); defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!, stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            // The decoder may round the requested size; index with the size actually delivered.
            (w, h) = (CVPixelBufferGetWidthOfPlane(buffer, 0), CVPixelBufferGetHeightOfPlane(buffer, 0))
            var frame = [UInt8](repeating: 0, count: w * h)
            frame.withUnsafeMutableBytes { dst in
                for row in 0..<h { (dst.baseAddress! + row * w).copyMemory(from: base + row * stride, byteCount: w) }
            }
            signals.append(signal(frame, previous, w: w, h: h)); previous = frame
            while signals.count < ticks, Double(signals.count) / fps < time { signals.append(FrameSignal(diff: 0, ssim: 1)) }   // same frame again
        }
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            emit(upTo: CMSampleBufferGetPresentationTimeStamp(sample).seconds)
            latest = buffer
            let done = min(0.99, Double(signals.count) / Double(ticks))
            if done - lastProgress >= 0.01 { lastProgress = done; progress(done) }
        }
        guard reader.status != .failed else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        emit(upTo: .infinity)
        progress(1)
        return signals
    }

    /// Luma buffers are tiny (≈240×135). SSIM is the mean over 8×8 windows; sums are exact integers.
    private static func signal(_ a: [UInt8], _ b: [UInt8]?, w: Int, h: Int) -> FrameSignal {
        guard let b, a.count == b.count, a != b else { return FrameSignal(diff: 0, ssim: 1) }
        return a.withUnsafeBufferPointer { a in b.withUnsafeBufferPointer { b in
            var sum = 0, (x0, y0, x1, y1) = (w, h, -1, -1)
            for y in 0..<h {
                let row = y * w
                for x in 0..<w {
                    let d = abs(Int(a[row + x]) - Int(b[row + x]))
                    sum += d
                    if d > 16 { x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y) }
                }
            }
            let (c1, c2) = (6.5025, 58.5225)
            var total = 0.0, windows = 0.0
            for wy in stride(from: 0, to: h - 7, by: 8) { for wx in stride(from: 0, to: w - 7, by: 8) {
                var (sa, sb, saa, sbb, sab) = (0, 0, 0, 0, 0)
                for y in wy..<wy + 8 {
                    let row = y * w + wx
                    for x in row..<row + 8 {
                        let (p, q) = (Int(a[x]), Int(b[x]))
                        sa += p; sb += q; saa += p * p; sbb += q * q; sab += p * q
                    }
                }
                let (ma, mb) = (Double(sa) / 64, Double(sb) / 64)
                let (va, vb, cov) = (Double(saa) / 64 - ma * ma, Double(sbb) / 64 - mb * mb, Double(sab) / 64 - ma * mb)
                total += (2 * ma * mb + c1) * (2 * cov + c2) / ((ma * ma + mb * mb + c1) * (va + vb + c2)); windows += 1
            } }
            let box = x1 < 0 ? nil : NormRect(x: Double(x0) / Double(w), y: Double(y0) / Double(h),
                                              w: Double(x1 - x0 + 1) / Double(w), h: Double(y1 - y0 + 1) / Double(h))
            return FrameSignal(diff: Double(sum) / Double(w * h) / 255, ssim: windows > 0 ? total / windows : 1, bbox: box)
        } }
    }

    /// `--selftest shots-perf <package>`: analyze a copy (the cache write must not touch the original) and time it.
    static func selfTestPerf(_ args: [String]) async throws {
        struct Fail: Error { let description: String }
        guard let path = args.first else { throw Fail(description: "usage: shots-perf <package>") }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("shots-perf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path).appendingPathComponent("screen.mov"), to: tmp.appendingPathComponent("screen.mov"))
        let start = Date()
        let s = try await signals(package: tmp, progress: { _ in })
        let first = Date().timeIntervalSince(start)
        let again = Date(); _ = try await signals(package: tmp, progress: { _ in })
        let cached = Date().timeIntervalSince(again)
        let board = storyboard(signals: s, events: [])
        print(String(format: "shots-perf frames=%d media=%.1fs decode=%.2fs cached=%.3fs shots=%d asl=%.2fs",
                     s.count, Double(s.count) / fps, first, cached, board.shots.count, board.summary.aslSec))
        guard cached < 0.5 else { throw Fail(description: "cache miss on second call") }
    }

    /// Optional per-call overrides of `ShotThresholds` by field name.
    static func thresholds(_ args: Any?) throws -> ShotThresholds {
        guard let args else { return ShotThresholds() }
        guard let args = args as? [String: Any] else { throw MCPFailure(code: "INVALID_OP", message: "thresholds must be an object of numbers") }
        var merged = try MCPTools.object(ShotThresholds())
        for (key, value) in args {
            guard merged[key] != nil, let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else {
                throw MCPFailure(code: "INVALID_OP", message: "thresholds.\(key) must be a finite number; known keys: \(merged.keys.sorted().joined(separator: ", "))")
            }
            merged[key] = n.doubleValue
        }
        let result = try JSONDecoder().decode(ShotThresholds.self, from: JSONSerialization.data(withJSONObject: merged))
        if let why = result.invalidReason { throw MCPFailure(code: "INVALID_OP", message: "thresholds: \(why)") }
        return result
    }
}
