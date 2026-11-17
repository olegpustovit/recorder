import AppKit
import AVFoundation
import RecorderCore

/// Media for the agent `layer` op (T-823): lists what a layer can use, validates and imports it.
///
/// Rules (SPEC §10 "Assets and layers"):
/// - A layer's media always ends up as an immutable `media/<uuid>.<ext>` file inside the package; nothing outside the package
///   is ever referenced and an imported file is never modified afterwards.
/// - Importing copies a file but never touches `project.json`, so a draft stays isolated: the file is invisible to autosave and
///   the saved project until the human accepts the layer. Files from a draft that is discarded (or whose layer is excluded) are removed.
/// - Local files must be regular image/video files inside the user's home folder or temp folder, not hidden, not in `~/Library`
///   (except the agent render cache) and not inside a `.recorder` package; symlinks are resolved first so they cannot escape.
/// - A library recording contributes its `screen.mov` and is subject to the same per-project access gate as `project.list`.
@MainActor enum MCPAssets {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "gif", "tif", "tiff", "bmp", "webp"]
    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]
    static let maxBytes: Int64 = 4_000_000_000

    /// Overridable by self-tests; normal runs use the real home and temp folders.
    static var trustedRoots: [URL] = [FileManager.default.homeDirectoryForCurrentUser, FileManager.default.temporaryDirectory]
        .map { $0.resolvingSymlinksInPath().standardizedFileURL }
    static var agentCache: URL { AgentRender.cacheRoot.resolvingSymlinksInPath().standardizedFileURL }

    struct Resolution {
        var ops: [EditOp]
        var assets: [String: MediaAsset]
        var created: [URL]
    }
    struct LibraryRecording { var id: String, title: String, duration: Double, package: URL }

    private static func contains(_ parent: URL, _ child: URL) -> Bool {
        let p = parent.pathComponents, c = child.pathComponents
        return c.count > p.count && Array(c.prefix(p.count)) == p
    }

    /// Validates an agent-supplied local path and returns its resolved URL.
    static func trustedFile(_ path: String) throws -> URL {
        guard path.hasPrefix("/") || path.hasPrefix("~") else {
            throw MCPFailure(code: "INVALID_OP", message: "layer path must be absolute; pass a full path to an image or video")
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).resolvingSymlinksInPath().standardizedFileURL
        guard let root = trustedRoots.first(where: { contains($0, url) }) else {
            throw MCPFailure(code: "PERMISSION_DENIED", message: "layer path must be inside your home or temp folder; move or copy the file there")
        }
        let relative = Array(url.pathComponents.dropFirst(root.pathComponents.count))
        if relative.contains(where: { $0.hasPrefix(".") }) || url.pathComponents.contains(where: { $0.hasSuffix(".recorder") }) {
            throw MCPFailure(code: "PERMISSION_DENIED", message: "layer path may not be hidden or inside a Recorder package; use recording:<id> for library recordings")
        }
        if relative.first == "Library", !contains(agentCache, url) {
            throw MCPFailure(code: "PERMISSION_DENIED", message: "layer path may not be inside ~/Library except Recorder's agent render cache")
        }
        let ext = url.pathExtension.lowercased()
        guard imageExtensions.contains(ext) || videoExtensions.contains(ext) else {
            throw MCPFailure(code: "INVALID_OP", message: "layer needs an image (png, jpg, heic, gif, tiff, bmp, webp) or video (mov, mp4, m4v)")
        }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true, let size = values?.fileSize else {
            throw MCPFailure(code: "INVALID_OP", message: "layer path is not a readable regular file")
        }
        guard Int64(size) <= maxBytes else { throw MCPFailure(code: "OUT_OF_RANGE", message: "layer media is larger than 4 GB") }
        return url
    }

    private static func asset(_ file: String, _ probe: EditorModel.ProbedMedia) throws -> MediaAsset {
        guard let kind = probe.kind else { throw MCPFailure(code: "INVALID_OP", message: "layers take images or videos; audio-only files are not supported") }
        return MediaAsset(file: file, kind: kind, duration: probe.duration, width: probe.width, height: probe.height, hasAudio: probe.audio)
    }

    static func removeFiles(_ urls: [URL]) { for url in urls { try? FileManager.default.removeItem(at: url) } }

    /// Turns every `.path`/`.recording`/`.asset` layer source into an imported, probed `.asset`. On any failure the files imported by
    /// this call are removed before the error is thrown, so a failed call changes nothing on disk.
    static func resolve(_ ops: [EditOp], package: URL, project: Project, library: [LibraryRecording], known: [String: MediaAsset] = [:]) async throws -> Resolution {
        var result = Resolution(ops: [], assets: [:], created: [])
        do {
            var imported: [String: MediaAsset] = [:]   // dedupe within a batch: one copy per distinct source
            for (index, op) in ops.enumerated() {
                guard case let .layer(from, to, source, rect) = op else { result.ops.append(op); continue }
                var media: MediaAsset
                switch source {
                case .asset(let file):
                    guard file.hasPrefix("media/"), !file.split(separator: "/").contains("..") else {
                        throw MCPFailure(code: "INVALID_OP", message: "op \(index): asset must be a media/ file from project.assets")
                    }
                    if let existing = known[file] ?? result.assets[file] { media = existing }
                    else if project.layers.contains(where: { $0.file == file && $0.kind != .recording }) {
                        let url = package.appendingPathComponent(file)
                        guard url.resolvingSymlinksInPath().path.hasPrefix(package.resolvingSymlinksInPath().path + "/media/") else {
                            throw MCPFailure(code: "INVALID_OP", message: "op \(index): asset is outside the package media folder")
                        }
                        media = try asset(file, try await EditorModel.probeMedia(url))
                    } else {
                        throw MCPFailure(code: "INVALID_OP", message: "op \(index): unknown asset \(file); call project.assets")
                    }
                case .path(let path):
                    if let cached = imported["path:" + path] { media = cached; break }
                    let url = try trustedFile(path)
                    let copy = try await EditorModel.copyMedia(url, into: package)
                    result.created.append(copy.url)
                    media = try asset(copy.file, EditorModel.ProbedMedia(kind: copy.kind, duration: copy.duration, width: copy.width, height: copy.height, audio: copy.audio))
                    imported["path:" + path] = media
                case .recording(let id):
                    if let cached = imported["recording:" + id] { media = cached; break }
                    guard id != project.id, let item = library.first(where: { $0.id == id }) else {
                        throw MCPFailure(code: "NO_PROJECT", message: "op \(index): recording \(id) is not another recording you can read; call project.assets")
                    }
                    let video = item.package.appendingPathComponent("screen.mov")
                    guard (try? video.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                        throw MCPFailure(code: "NO_PROJECT", message: "op \(index): recording \(id) has no screen video")
                    }
                    let copy = try await EditorModel.copyMedia(video, into: package)
                    result.created.append(copy.url)
                    media = try asset(copy.file, EditorModel.ProbedMedia(kind: copy.kind, duration: copy.duration, width: copy.width, height: copy.height, audio: copy.audio))
                    imported["recording:" + id] = media
                }
                guard media.kind != .recording, media.width > 0, media.height > 0 else {
                    throw MCPFailure(code: "INVALID_OP", message: "op \(index): layer media has no size")
                }
                var placed = rect
                if placed == nil, media.kind == .video {
                    let canvas = outputSize(aspect: project.output.aspect,
                                            croppedSource: CGSize(width: Double(project.source.pixelWidth) * project.crop.w, height: Double(project.source.pixelHeight) * project.crop.h),
                                            longEdge: 1000)
                    placed = layerPlacementRect(.card, aspect: media.width / media.height, canvas: canvas)
                }
                result.assets[media.file] = media
                result.ops.append(.layer(from: from, to: to, source: .asset(media.file), rect: placed))
            }
            return result
        } catch {
            removeFiles(result.created)
            throw error
        }
    }

    /// Removes media a session imported for a draft that no longer references it (discarded, excluded or replaced).
    static func purge(_ session: MCPSession, keeping project: Project?) {
        let referenced = Set((project?.layers.map(\.file) ?? []) + (project?.audioClips.map(\.file) ?? []))
        for file in session.agentMedia where !referenced.contains(file) {
            if let package = session.agentMediaPackage { try? FileManager.default.removeItem(at: package.appendingPathComponent(file)) }
        }
        session.agentMedia = []
        session.agentMediaPackage = nil
    }

    /// `project.assets`: what `layer` can use right now.
    static func list(project: Project, library: [LibraryRecording]) -> [String: Any] {
        let map = TimeMap(project.clips)
        // Every layer, recording layers included (feedback run 6: an appended recording layer was missing).
        let layers: [[String: Any]] = project.layers.map { layer in
            var row: [String: Any] = ["asset": layer.file, "kind": layer.kind.rawValue, "id": layer.id, "track": layer.track,
                                      "mediaStart": layer.mediaStart, "mediaRate": layer.mediaRate ?? 1]
            if let start = map.outputTime(atSource: layer.start) { row["from"] = start; row["to"] = start + layer.end - layer.start }
            return row
        }
        return ["layers": layers,
                "library": library.filter { $0.id != project.id }.map { ["recording": $0.id, "title": $0.title, "duration": $0.duration] as [String: Any] },
                "paths": "layer also accepts path (absolute image/video file in your home or temp folder) and recording (a library recording id)"]
    }
}
