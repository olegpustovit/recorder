import AVFoundation
import CryptoKit
import VideoToolbox
import RecorderCore

/// analyze.shots (T-827) app half: decode screen.mov at 10 fps, 1/8 scale luma, and reduce it to `FrameSignal`s
/// (RecorderCore.storyboard does the segmentation). Signals are cached in the package per media fingerprint.
enum ShotAnalysis {
    static let fps = 10.0
    /// Bump whenever decoding or the signal maths change: it is part of the cache key.
    static let algorithmVersion = 3
    private static let cacheName = "shots-cache.json"
    static let thresholdsName = "shots-thresholds.json"
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

    /// Signals only if analyze.shots already decoded this media; never decodes (edit reports must stay instant).
    static func cachedSignals(package: URL) -> [FrameSignal]? {
        let media = package.appendingPathComponent("screen.mov")
        guard let key = try? "v\(algorithmVersion)-" + fingerprint(media),
              let data = try? Data(contentsOf: package.appendingPathComponent(cacheName)),
              let cache = try? JSONDecoder().decode(Cache.self, from: data), cache.key == key else { return nil }
        return cache.signals
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

    /// Recording-time signals: the capture stream already has every frame in memory, so the stop writes the cache and
    /// analyze.shots never decodes a new recording. Same ticks (latest frame at or before k/10 s), size and luma as `decode`.
    final class Live {
        private let queue = DispatchQueue(label: "recorder.shots.live", qos: .utility)
        private var latest: CVPixelBuffer?, previous: [UInt8]?, signals: [FrameSignal] = [], w = 0, h = 0

        /// Main-stream frames (4:2:0 or BGRA window captures); `t` = output seconds.
        func add(_ buffer: CVPixelBuffer, at t: Double) {
            queue.async { [self] in
                emit(upTo: t); latest = buffer
            }
        }

        private func emit(upTo t: Double) {
            guard let buffer = latest, Double(signals.count) / ShotAnalysis.fps < t else { return }
            if w == 0 { (w, h) = (max(16, CVPixelBufferGetWidth(buffer) / 8 & ~1), max(16, CVPixelBufferGetHeight(buffer) / 8 & ~1)) }
            let frame = ShotAnalysis.lumaBox(buffer, w: w, h: h)
            signals.append(ShotAnalysis.signal(frame, previous, w: w, h: h)); previous = frame
            while Double(signals.count) / ShotAnalysis.fps < t { signals.append(FrameSignal(diff: 0, ssim: 1)) }   // same frame held
        }

        /// Call after screen.mov is finalised: the cache key is that file's fingerprint.
        func write(package: URL, duration: Double) {
            let result: [FrameSignal]? = queue.sync { [self] in
                let ticks = max(1, Int((duration * ShotAnalysis.fps).rounded(.down)))
                emit(upTo: Double(ticks) / ShotAnalysis.fps); latest = nil
                return signals.count < ticks ? nil : Array(signals.prefix(ticks))
            }
            guard let result, let key = try? "v\(ShotAnalysis.algorithmVersion)-" + ShotAnalysis.fingerprint(package.appendingPathComponent("screen.mov")) else { return }
            try? JSONEncoder().encode(ShotAnalysis.Cache(key: key, signals: result)).write(to: package.appendingPathComponent(ShotAnalysis.cacheName), options: .atomic)
        }
    }

    private static func decode(_ url: URL, progress: @escaping (Double) -> Void) async throws -> [FrameSignal] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw MCPFailure(code: "NO_PROJECT", message: "screen.mov has no video track")
        }
        let duration = try await asset.load(.duration).seconds, size = try await track.load(.naturalSize)
        var w = max(16, Int(size.width) / 8 & ~1), h = max(16, Int(size.height) / 8 & ~1)
        if let fast = try? decodeVT(asset, track, duration: duration, w: w, h: h, progress: progress) { return fast }
        try Task.checkCancellation()   // VT setup or decode failed: fall back to AVAssetReader's scaling decode below
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

    /// Fast path (T-827): read compressed samples, skip droppable frames no 0.1 s tick shows, and decode GOP-aligned chunks in
    /// parallel with VideoToolbox, alternating hardware and software sessions (the two engines run concurrently; either alone
    /// is serial). Luma is box-averaged to w×h. ~3.5x faster than AVAssetReader's scaling decode.
    // ponytail: all chunks cancel only at the end (no mid-decode cancel), and a decode reads every frame between ticks that other frames depend on.
    private static func decodeVT(_ asset: AVURLAsset, _ track: AVAssetTrack, duration: Double, w: Int, h: Int,
                                 progress: @escaping (Double) -> Void) throws -> [FrameSignal] {
        func samples(_ range: CMTimeRange?, _ body: (CMSampleBuffer) -> Void) throws {
            let reader = try AVAssetReader(asset: asset), out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            if let range { reader.timeRange = range }
            reader.add(out)
            guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
            while let s = out.copyNextSampleBuffer() { if CMSampleBufferGetNumSamples(s) > 0 { body(s) } }
            if reader.status == .failed { throw reader.error ?? CocoaError(.fileReadUnknown) }
        }
        func flag(_ s: CMSampleBuffer, _ key: CFString) -> Bool? {
            ((CMSampleBufferGetSampleAttachmentsArray(s, createIfNecessary: false) as? [[CFString: Any]])?.first?[key]) as? Bool
        }
        var times: [CMTime] = [], syncs: [CMTime] = []
        try samples(nil) { s in
            let t = CMSampleBufferGetPresentationTimeStamp(s)
            times.append(t); if flag(s, kCMSampleAttachmentKey_NotSync) != true { syncs.append(t) }
        }
        times.sort()
        guard let first = times.first, !syncs.isEmpty else { throw CocoaError(.fileReadUnknown) }
        // Each tick shows the latest frame at or before it; only those frames matter (nil before the first frame).
        let ticks = max(1, Int((duration * fps).rounded(.down)))
        var tickFrame: [CMTime?] = [], i = 0
        for k in 0..<ticks {
            while i + 1 < times.count, times[i + 1].seconds <= Double(k) / fps { i += 1 }
            tickFrame.append(times[i].seconds <= Double(k) / fps ? times[i] : nil)
        }
        let needed = Set(tickFrame.compactMap { $0 })
        // ~8 s chunks starting at sync samples
        var starts = [first]
        for s in syncs.sorted() where s.seconds - starts.last!.seconds >= 8 { starts.append(s) }
        let ends = Array(starts.dropFirst()) + [CMTime(seconds: duration + 1, preferredTimescale: 600)]

        struct Chunk { var frames: [(CMTime, [UInt8])] = []; var signals: [CMTime: FrameSignal] = [:] }
        var chunks = [Chunk](repeating: Chunk(), count: starts.count), failure: Error?, done = 0
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: starts.count) { c in
            do {
                var sess: VTDecompressionSession?
                let spec = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: c % 2 == 1] as CFDictionary
                let attrs = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] as CFDictionary
                var got: [CMTime: [UInt8]] = [:], formatted = false
                try samples(CMTimeRange(start: starts[c], end: ends[c])) { s in
                    if !formatted, let fd = CMSampleBufferGetFormatDescription(s) {
                        formatted = true
                        if VTDecompressionSessionCreate(allocator: nil, formatDescription: fd, decoderSpecification: spec, imageBufferAttributes: attrs,
                                                        outputCallback: nil, decompressionSessionOut: &sess) != 0 { lock.lock(); failure = CocoaError(.fileReadUnknown); lock.unlock() }
                    }
                    guard let sess else { return }
                    let t = CMSampleBufferGetPresentationTimeStamp(s)
                    if !needed.contains(t) && flag(s, kCMSampleAttachmentKey_IsDependedOnByOthers) == false { return }
                    let st = VTDecompressionSessionDecodeFrame(sess, sampleBuffer: s, flags: [._EnableAsynchronousDecompression], infoFlagsOut: nil) { st, _, buf, pts, _ in
                        guard st == 0, let buf, needed.contains(pts), pts >= starts[c], pts < ends[c] else { return }   // a boundary frame belongs to one chunk only
                        let f = lumaBox(buf, w: w, h: h); lock.lock(); got[pts] = f; lock.unlock()
                    }
                    if st != 0 { lock.lock(); failure = CocoaError(.fileReadUnknown); lock.unlock() }
                }
                if let sess { VTDecompressionSessionWaitForAsynchronousFrames(sess); VTDecompressionSessionInvalidate(sess) }
                var chunk = Chunk(frames: got.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
                for j in chunk.frames.indices.dropFirst() { chunk.signals[chunk.frames[j].0] = signal(chunk.frames[j].1, chunk.frames[j - 1].1, w: w, h: h) }
                lock.lock(); chunks[c] = chunk; done += 1; progress(min(0.99, Double(done) / Double(starts.count))); lock.unlock()
            } catch { lock.lock(); failure = error; lock.unlock() }
        }
        if let failure { throw failure }
        var signals = chunks.reduce(into: [CMTime: FrameSignal]()) { $0.merge($1.signals) { a, _ in a } }
        var previous: [UInt8]?
        for chunk in chunks where !chunk.frames.isEmpty {   // stitch: first frame of a chunk vs last of the one before
            if let previous { signals[chunk.frames[0].0] = signal(chunk.frames[0].1, previous, w: w, h: h) }
            previous = chunk.frames.last!.1
        }
        guard chunks.reduce(0, { $0 + $1.frames.count }) == needed.count else { throw CocoaError(.fileReadUnknown) }
        progress(1)
        return (0..<ticks).map { k in
            guard let t = tickFrame[k], k == 0 || tickFrame[k - 1] != t else { return FrameSignal(diff: 0, ssim: 1) }
            return signals[t] ?? FrameSignal(diff: 0, ssim: 1)
        }
    }

    /// w×h luma from a full-size 4:2:0 or BGRA buffer: mean of every 2nd row × 8 columns per output pixel; the decode output
    /// is full-res (the decoders ignore reduced-size requests for HEVC) and reading all rows costs more than the decode.
    private static func lumaBox(_ buffer: CVPixelBuffer, w: Int, h: Int) -> [UInt8] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly); defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        // Window captures arrive as BGRA: convert to the same video-range BT.709 luma the encoder stores (Y' = 16 + 219·L).
        let bgra = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA
        let stride = bgra ? CVPixelBufferGetBytesPerRow(buffer) : CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let base = (bgra ? CVPixelBufferGetBaseAddress(buffer) : CVPixelBufferGetBaseAddressOfPlane(buffer, 0))!.assumingMemoryBound(to: UInt8.self)
        let fx = CVPixelBufferGetWidth(buffer) / w, fy = CVPixelBufferGetHeight(buffer) / h
        var frame = [UInt8](repeating: 0, count: w * h), acc = [Int32](repeating: 0, count: w)
        for y in 0..<h {
            acc.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
            var n: Int32 = 0
            for k in Swift.stride(from: 0, to: fy, by: 2) {
                let row = base + (y * fy + k) * stride
                if bgra {   // integer BT.709: 16 + (47·R + 157·G + 16·B) / 256 ≈ 16 + 219·(0.2126R + 0.7152G + 0.0722B)/255
                    for x in 0..<w { var s: Int32 = 0; for j in 0..<fx { let p = row + (x * fx + j) * 4; s += 16 + (47 * Int32(p[2]) + 157 * Int32(p[1]) + 16 * Int32(p[0])) >> 8 }; acc[x] += s }
                } else {
                    for x in 0..<w { var s: Int32 = 0; for j in 0..<fx { s += Int32(row[x * fx + j]) }; acc[x] += s }
                }
                n += Int32(fx)
            }
            for x in 0..<w { frame[y * w + x] = UInt8(acc[x] / n) }
        }
        return frame
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
        try reelPipeline(package: URL(fileURLWithPath: path), signals: s)
    }

    /// The spec's §4 loop on real data, Core only: storyboard → keepShots → pace → fitDuration 30 s → reframe 4:5 → report + lint.
    private static func reelPipeline(package: URL, signals: [FrameSignal]) throws {
        struct Fail: Error { let description: String }
        let base = try Project.load(from: package.appendingPathComponent("project.json"))
        let log = (try? JSONDecoder().decode(EventLog.self, from: Data(contentsOf: package.appendingPathComponent("events.json")))) ?? EventLog(events: [])
        let board = storyboard(signals: signals, fps: fps, events: log.events).inSource(clips: base.clips)
        func step(_ project: Project, _ op: JSONValue) throws -> Project {
            let result = try lowerIntents([op], project: project, clicks: log.clicks(), storyboard: { board })
            let lowered = result.ops
            if ProcessInfo.processInfo.environment["SHOTS_DEBUG"] != nil {
                for l in result.lowered { print("  \(l.intent): \(l.ops.count) ops, dropped \(l.dropped?.count ?? 0), note \(l.note ?? "-")") }
                print("  ops: \(String(data: try JSONEncoder().encode(lowered), encoding: .utf8)!.prefix(1500))")
            }
            let ops = try MCPTools.decodeOps(JSONSerialization.jsonObject(with: JSONEncoder().encode(lowered)))
            let applied = try project.applying(ops, context: EditContext())
            if ProcessInfo.processInfo.environment["SHOTS_DEBUG"] != nil {
                print(String(format: "  duration %.2f → %.2f, skipped %d", TimeMap(project.clips).outputDuration, TimeMap(applied.project.clips).outputDuration, applied.changes.filter(\.skipped).count))
                for c in applied.changes where c.skipped { print("   skipped: \(c.note ?? "")") }
            }
            return applied.project
        }
        var p = try step(base, .object(["op": .string("keepShots"), "where": .object(["kind": .array(["payoff", "motion", "typing"].map { .string($0) })])]))
        p = try step(p, .object(["op": .string("pace")]))
        p = try step(p, .object(["op": .string("fitDuration"), "target": .number(30), "tolerance": .number(2)]))
        let keys = reframePlan(storyboard: board, aspect: .r4x5, mode: .perShot, sourceSize: CGSize(width: base.source.pixelWidth, height: base.source.pixelHeight))
        p = try p.applying([.reframe(aspect: .r4x5, mode: .perShot, keys: keys)], context: EditContext()).project
        let report = editReport(before: base, after: p, storyboard: board)
        let rules = Dictionary(grouping: report.lint, by: \.rule).mapValues(\.count).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        print(String(format: "shots-pipeline duration %.1f→%.1fs asl %.2f→%.2fs static %.1f→%.1fs hook=%@ longestStatic=%@ cropKeys=%d lint[%@]",
                     report.duration.before, report.duration.after, report.aslSec.before, report.aslSec.after,
                     report.staticSec.before, report.staticSec.after, report.hookSec.map { String(format: "%.2fs", $0) } ?? "-",
                     report.longestStatic.map { String(format: "%.2fs@%.1f", $0.sec, $0.at) } ?? "-", p.cropKeys.count, rules))
        // fitDuration only shortens, so the 30 s target is checked only on projects that start longer than it.
        guard report.duration.before <= 32 || abs(report.duration.after - 30) <= 2 else { throw Fail(description: "fitDuration missed 30±2 s: \(report.duration.after)") }
        guard p.checkInvariants() == nil else { throw Fail(description: "invariants: \(p.checkInvariants()!)") }
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
