import AVFoundation
import CryptoKit
import Foundation
import RecorderCore

struct MCPFailure: Error {
    let code: String
    let message: String
}

enum MCPTools {
    static let instructions = """
    Recorder edits screen recordings. Times you send and receive are output seconds (the edited timeline). Typical loop:
    project.open → timeline.get + transcript.get → analyze → edit.apply (lands in a draft) → render.frames / render.sheet
    to check → fix → draft.submit for the human to review. Pass ifRevision from the latest result. Renders go to a cache
    folder; final exports need the user's approval. Key presses are never shared.
    """
    static let list: [[String: Any]] = {
        let string: [String: Any] = ["type": "string"]
        let number: [String: Any] = ["type": "number", "minimum": 0]
        let boolean: [String: Any] = ["type": "boolean"]
        let range = ["from": number, "to": number]
        func tool(_ name: String, _ actions: [String], _ description: String, _ fields: [String: Any], read: Bool = false) -> [String: Any] {
            var properties = fields
            properties["action"] = ["type": "string", "enum": actions]
            var annotations: [String: Any] = read ? ["readOnlyHint": true] : ["destructiveHint": false]
            if name == "export" { annotations["openWorldHint"] = false }
            return ["name": name, "description": description, "annotations": annotations,
                    "inputSchema": ["type": "object", "properties": properties, "required": ["action"], "additionalProperties": false]]
        }
        return [
            tool("project", ["list", "open", "info"], "List recordings, open one by id or package path, or read its summary and revision.", ["id": string, "path": string], read: true),
            tool("timeline", ["get"], "Read clips, effect blocks and markers in output seconds.", range, read: true),
            tool("transcript", ["get"], "Read up to 2000 spoken words with stable wN ids, or timestamped phrases. Key presses are never returned.", range.merging(["format": ["type": "string", "enum": ["words", "phrases"]]], uniquingKeysWith: { _, b in b }), read: true),
            tool("analyze", ["transcribe", "pauses", "fillers", "activity"], "Transcribe on-device, find mic pauses/fillers, or read activity ranges without key characters.", ["minDuration": number, "threshold": number], read: true),
            tool("edit", ["apply", "undo"], "Apply atomic edits using the latest ifRevision; edits land in a draft by default.", ["ifRevision": string, "ops": ["type": "array", "items": ["type": "object"]], "dryRun": boolean]),
            tool("draft", ["status", "submit", "discard"], "Read or submit your draft for review, or discard it.", ["note": string]),
            tool("render", ["frames", "sheet", "clip", "cancel"], "Render frames, a contact sheet or a 540p proxy into the agent cache. Key chips are hidden.", ["at": ["type": "array", "items": number, "maxItems": 24], "from": number, "to": number, "count": ["type": "integer", "minimum": 1, "maximum": 24], "longEdge": ["type": "integer", "minimum": 1, "maximum": 640], "draft": boolean]),
            tool("export", ["final"], "Export an MP4 after the user's native approval, optionally with SRT subtitles.", ["destination": string, "shortEdge": ["type": "integer", "minimum": 1], "fps": ["type": "integer", "minimum": 1], "srt": boolean]),
            tool("ui", ["show"], "Move the editor playhead and select blocks by id.", ["at": number, "select": ["type": "array", "items": string]])
        ]
    }()

    static func revision(_ project: Project) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(project)).map { String(format: "%02x", $0) }.joined().prefix(12).description
    }
    static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any] ?? [:]
    }
    static func result(_ payload: [String: Any], isError: Bool = false) -> [String: Any] {
        let text = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return ["content": [["type": "text", "text": text]], "structuredContent": payload, "isError": isError]
    }
    @MainActor static func model(for session: MCPSession) throws -> EditorModel {
        guard let url = session.projectURL, let controller = EditorWindowController.allOpen.first(where: { $0.model.packageURL.standardizedFileURL == url }) else {
            throw MCPFailure(code: "NO_PROJECT", message: "Open an editor with project.open; if it was closed, open it again")
        }
        return controller.model
    }
    static func requireAccess(_ project: Project, tool: String) throws {
        let level = AgentAccess.level(for: project.id)
        guard level != .off, level != .read || !["edit", "draft", "export"].contains(tool) else {
            throw MCPFailure(code: "PERMISSION_DENIED", message: "\(level.rawValue) access for this project; change access in the Claude tab before retrying \(tool)")
        }
    }
    @MainActor static func call(_ name: String, _ args: [String: Any], session: MCPSession, progress: @escaping (Double) -> Void = { _ in }) async -> [String: Any] {
        let began = Date()
        var action = "invalid", errorCode: String?
        defer {
            let loggedName = list.contains { $0["name"] as? String == name } ? name : "invalid"
            AgentActivity.shared.log(.init(time: began, agent: session.agentName, tool: "\(loggedName).\(action)",
                summary: errorCode ?? "completed", ms: Int(Date().timeIntervalSince(began) * 1000), isError: errorCode != nil))
        }
        do {
            guard let tool = list.first(where: { $0["name"] as? String == name }),
                  let schema = tool["inputSchema"] as? [String: Any], let properties = schema["properties"] as? [String: Any],
                  let actionSchema = properties["action"] as? [String: Any], let allowed = actionSchema["enum"] as? [String],
                  let requested = args["action"] as? String, allowed.contains(requested), Set(args.keys).isSubset(of: Set(properties.keys)) else {
                throw MCPFailure(code: "INVALID_OP", message: "Use a tool/action and arguments from tools/list, then retry")
            }
            action = requested
            for (key, value) in args {
                let type = (properties[key] as? [String: Any])?["type"] as? String
                let valid: Bool
                switch type {
                case "string": valid = value is String
                case "boolean": valid = (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
                case "number", "integer":
                    valid = (value as? NSNumber).map { CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue.isFinite && (type != "integer" || $0.doubleValue.rounded() == $0.doubleValue) } ?? false
                case "array": valid = value is [Any]
                case "object": valid = value is [String: Any]
                default: valid = false
                }
                guard valid else { throw MCPFailure(code: "INVALID_OP", message: "\(key) must be \(type ?? "a valid argument"); revise it using tools/list and retry") }
            }
            if session.projectURL != nil {
                if let current = try? model(for: session) { try requireAccess(current.project, tool: name) }
                else if name == "project", ["open", "list"].contains(action) { session.projectURL = nil }
                else { _ = try model(for: session) }
            }
            var payload: [String: Any]
            var extraContent: [[String: Any]] = []
            if name == "project", action == "list" {
                let items = await libraryItems()
                payload = ["projects": items.filter { AgentAccess.level(for: $0.projectID) != .off }.map { item in
                    ["id": item.projectID, "title": item.title, "path": item.id.path, "duration": item.duration,
                     "modified": ISO8601DateFormatter().string(from: item.modified), "hasMic": item.hasMic] as [String: Any]
                }]
            } else if name == "project", action == "open" {
                let url: URL
                if let path = args["path"] as? String, !path.isEmpty {
                    url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).resolvingSymlinksInPath().standardizedFileURL
                } else if let id = args["id"] as? String {
                    if let existing = EditorWindowController.allOpen.first(where: { $0.model.project.id == id }) { url = existing.model.packageURL }
                    else if let item = await libraryItems().first(where: { $0.projectID == id }) { url = item.id.resolvingSymlinksInPath().standardizedFileURL }
                    else { throw MCPFailure(code: "NO_PROJECT", message: "No project with this id; call project.list or supply its .recorder path") }
                } else { throw MCPFailure(code: "INVALID_OP", message: "project.open needs id or path; call project.list first") }
                guard url.pathExtension == "recorder" else { throw MCPFailure(code: "NO_PROJECT", message: "Supply a .recorder package directory, then retry project.open") }
                let project = try await Task.detached { try Project.load(from: url.appendingPathComponent("project.json")) }.value
                try requireAccess(project, tool: name)
                guard let controller = await EditorWindowController.open(package: url).value else {
                    throw MCPFailure(code: "NO_PROJECT", message: "Recorder could not open this package; check its media in Recorder and retry project.open")
                }
                session.projectURL = controller.model.packageURL.standardizedFileURL
                payload = info(controller.model)
            } else {
                let model = try model(for: session)
                switch (name, action) {
                case ("project", "info"): payload = info(model)
                case ("timeline", "get"):
                    let bounds = try bounds(args, duration: model.project.exportDuration)
                    payload = try object(agentTimeline(model.project, from: bounds.0, to: bounds.1))
                case ("transcript", "get"):
                    guard let words = model.transcript else { throw notTranscribed() }
                    let bounds = try bounds(args, duration: model.project.exportDuration)
                    let format = args["format"] as? String ?? "words"
                    guard ["words", "phrases"].contains(format) else { throw MCPFailure(code: "INVALID_OP", message: "transcript.get format must be words or phrases") }
                    var view = agentTranscript(model.project, words: words, from: bounds.0, to: bounds.1)
                    let next = view.words.count > 2000 ? view.words[2000].from : nil
                    view.words = Array(view.words.prefix(2000))
                    if format == "phrases" {
                        view.phrases = captionPhrases(words: view.words.map { Word(text: $0.text, start: $0.from, end: $0.to) }).map {
                            let tenths = Int(($0.start * 10).rounded())
                            return String(format: "[%d:%02d.%d] %@", tenths / 600, tenths / 10 % 60, tenths % 10, $0.text)
                        }
                    }
                    payload = try object(view); payload["truncated"] = next != nil
                    if let next { payload["from"] = next }
                case ("analyze", "pauses"):
                    guard model.project.source.hasMic, let audio = Waveform.audioURL(in: model.packageURL, file: "mic.m4a") else { throw notTranscribed() }
                    let minimum = try number(args, "minDuration", default: 0.6), threshold = try number(args, "threshold", default: 0.02)
                    guard minimum >= 0, (0...1).contains(threshold) else { throw MCPFailure(code: "OUT_OF_RANGE", message: "Use nonnegative minDuration and threshold between 0 and 1") }
                    let peaks = try await Waveform.peaks(for: audio)
                    let silent = silentRanges(levels: peaks, perSecond: Double(Waveform.peaksPerSecond), threshold: Float(threshold), minDuration: minimum)
                    payload = ["pauses": outputRanges(silent, project: model.project)]
                case ("analyze", "fillers"):
                    guard let words = model.transcript else { throw notTranscribed() }
                    payload = ["fillers": agentTranscript(model.project, words: words).words.filter(\.filler).map {
                        ["word": $0.id, "from": $0.from, "to": $0.to, "text": $0.text] as [String: Any]
                    }]
                case ("analyze", "activity"):
                    let project = model.project, events = model.events.events
                    let map = TimeMap(project.clips)
                    let clicks = model.events.clicks().flatMap { event in
                        project.clips.compactMap { clip -> Double? in
                            guard !clip.isEmpty, clip.file == nil, event.t >= clip.mediaIn, event.t < clip.mediaEnd else { return nil }
                            return map.outputTime(atSource: clip.sourceTime(atMedia: event.t)).map { ($0 * 100).rounded() / 100 }
                        }
                    }.sorted()
                    payload = ["idle": outputRanges(idleRanges(events: events + [InputEvent(t: project.source.duration, k: .move)]), project: project),
                               "typing": outputRanges(typingRanges(events: events), project: project), "clicks": clicks]
                case ("analyze", "transcribe"):
                    guard model.project.source.hasMic, Waveform.audioURL(in: model.packageURL, file: "mic.m4a") != nil else { throw notTranscribed() }
                    guard !model.isTranscribing else { throw MCPFailure(code: "RENDER_BUSY", message: "Transcription is running; wait and call transcript.get") }
                    progress(0)
                    await model.transcribe()
                    guard let words = model.transcript, !words.isEmpty || model.transcriptStatus == "No speech found." else {
                        throw MCPFailure(code: "NOT_TRANSCRIBED", message: "\(model.transcriptStatus ?? "Transcription failed"); check Speech permission in Recorder and retry analyze.transcribe")
                    }
                    progress(1)
                    payload = ["transcript": transcriptID(words), "words": words.count]
                case ("render", _):
                    (payload, extraContent) = try await render(action, args, model: model, session: session, progress: progress)
                default: throw MCPFailure(code: "INVALID_OP", message: "\(name).\(action) is not available in this build; use Recorder's editor")
                }
            }
            if session.projectURL != nil {
                let current = try model(for: session)
                try requireAccess(current.project, tool: name)
                if payload["project"] == nil { payload["project"] = current.project.id }
                if payload["revision"] == nil { payload["revision"] = try revision(current.project) }
            } else { payload["project"] = NSNull(); payload["revision"] = NSNull() }
            var reply = result(payload)
            reply["content"] = (reply["content"] as? [[String: Any]] ?? []) + extraContent
            return reply
        } catch {
            let failure = error as? MCPFailure ?? MCPFailure(code: "INVALID_OP", message: "\(error.localizedDescription); check the project in Recorder and retry")
            errorCode = failure.code
            return result(["error": failure.code, "message": "\(failure.code): \(failure.message)"], isError: true)
        }
    }

    @MainActor private static func render(_ action: String, _ args: [String: Any], model: EditorModel, session: MCPSession,
                                          progress: @escaping (Double) -> Void) async throws -> ([String: Any], [[String: Any]]) {
        if action == "cancel" {
            let task = session.renderTask
            task?.cancel()
            _ = await task?.result
            return (["cancelled": task != nil], [])
        }
        guard session.renderTask == nil else { throw MCPFailure(code: "RENDER_BUSY", message: "A render is running; call render.cancel or wait for it to finish") }
        let revision = try revision(model.project)
        let projectID = model.project.id
        let frozen = AgentRender.renderModel(for: model, project: model.project)
        let duration = frozen.project.exportDuration
        var times: [Double] = []
        let edge = try number(args, "longEdge", default: 640)
        guard (2...640).contains(edge) else { throw MCPFailure(code: "OUT_OF_RANGE", message: "longEdge must be 2–640 pixels") }
        if action == "frames" || action == "sheet" {
            if let values = args["at"] as? [Any] {
                guard !values.isEmpty, values.count <= (action == "frames" ? 6 : 24) else { throw MCPFailure(code: "OUT_OF_RANGE", message: "Use 1–6 frame times or 1–24 sheet times") }
                times = try values.map { try number(["at": $0], "at", default: -1) }
            } else if action == "sheet" {
                let count = try number(args, "count", default: 12)
                guard (1...24).contains(count) else { throw MCPFailure(code: "OUT_OF_RANGE", message: "Contact sheet count must be 1–24") }
                times = (0..<Int(count)).map { (Double($0) + 0.5) * duration / count }
            } else { throw MCPFailure(code: "INVALID_OP", message: "render.frames requires at: [output seconds]") }
            guard duration > 0, times.allSatisfy({ $0 >= 0 && $0 <= duration }) else { throw MCPFailure(code: "OUT_OF_RANGE", message: "Use frame times within 0–\(duration); call project.info") }
        }
        let from = try number(args, "from", default: -1), to = try number(args, "to", default: -1)
        if action == "clip", !(from >= 0 && to > from && to <= duration) { throw MCPFailure(code: "OUT_OF_RANGE", message: "render.clip needs 0 ≤ from < to ≤ \(duration)") }
        let folder = AgentRender.cacheFolder(session: session.id)
        if action == "clip" { progress(0) }
        let jobID = UUID()
        let requested = times
        let task = Task { @MainActor in
            switch action {
            case "frames": return try await AgentRender.frames(model: frozen, at: requested, longEdge: Int(edge), folder: folder)
            case "sheet": return [try await AgentRender.sheet(model: frozen, at: requested, folder: folder)]
            case "clip": return [try await AgentRender.clip(model: frozen, from: from, to: to, folder: folder, progress: progress)]
            default: throw MCPFailure(code: "INVALID_OP", message: "Choose a render action from tools/list")
            }
        }
        session.renderTask = task; session.renderJobID = jobID
        defer { if session.renderJobID == jobID { session.renderTask = nil; session.renderJobID = nil } }
        let files: [URL]
        do { files = try await task.value }
        catch is CancellationError { throw MCPFailure(code: "DENIED", message: "Render cancelled; request another render when ready") }
        catch Exporter.ExportError.cancelled { throw MCPFailure(code: "DENIED", message: "Render cancelled; request another render when ready") }
        var payload: [String: Any] = ["project": projectID, "revision": revision, "files": files.map { $0.absoluteString }]
        var content: [[String: Any]] = []
        for file in files {
            let mime = file.pathExtension == "png" ? "image/png" : file.pathExtension == "jpg" ? "image/jpeg" : "video/mp4"
            if action != "clip" { content.append(["type": "image", "mimeType": mime, "data": try Data(contentsOf: file).base64EncodedString()]) }
            content.append(["type": "resource_link", "uri": file.absoluteString, "name": file.lastPathComponent, "mimeType": mime])
        }
        if action == "clip", let file = files.first {
            payload["seconds"] = try await AVURLAsset(url: file).load(.duration).seconds
            payload["bytes"] = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
        } else { payload["at"] = times }
        try requireAccess(frozen.project, tool: "render")
        guard EditorWindowController.allOpen.contains(where: { $0.model.project.id == projectID }) else {
            throw MCPFailure(code: "NO_PROJECT", message: "The editor closed during rendering; use project.open and retry")
        }
        return (payload, content)
    }

    @MainActor private static func libraryItems() async -> [ProjectStore.Item] {
        let store = ProjectStore(folder: RecordingSettings.shared.projectsFolder)
        await withCheckedContinuation { continuation in store.reload { continuation.resume() } }
        return store.items
    }
    @MainActor private static func info(_ model: EditorModel) -> [String: Any] {
        let p = model.project
        return ["title": p.title, "duration": p.exportDuration, "size": ["w": p.source.pixelWidth, "h": p.source.pixelHeight],
                "clips": p.clips.filter { !$0.isEmpty }.count,
                "lanes": ["zoom": p.zooms.count, "text": p.texts.count, "mask": p.masks.count, "layout": p.layouts.count,
                          "camera": p.cameraClips.count, "keys": p.keystrokeClips.count, "layer": p.layers.count, "audio": p.audioClips.count, "window": p.windowShots.count],
                "hasMic": p.source.hasMic, "hasCamera": p.source.hasCamera, "transcribed": model.transcript != nil,
                "access": AgentAccess.level(for: p.id).rawValue]
    }
    private static func notTranscribed() -> MCPFailure {
        MCPFailure(code: "NOT_TRANSCRIBED", message: "This project needs a microphone recording/transcript; call analyze.transcribe if mic.m4a exists")
    }
    static func number(_ args: [String: Any], _ key: String, default fallback: Double) throws -> Double {
        guard let raw = args[key] else { return fallback }
        guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else {
            throw MCPFailure(code: "INVALID_OP", message: "\(key) must be a finite number; revise it and retry")
        }
        return value.doubleValue
    }
    private static func bounds(_ args: [String: Any], duration: Double) throws -> (Double?, Double?) {
        let from = try number(args, "from", default: 0), to = try number(args, "to", default: duration)
        guard from >= 0, to >= from, to <= duration else { throw MCPFailure(code: "OUT_OF_RANGE", message: "Use 0 ≤ from ≤ to ≤ \(duration); call project.info for duration") }
        return (from, to)
    }
    static func outputRanges(_ ranges: [TimeRange], project: Project) -> [[String: Double]] {
        let map = TimeMap(project.clips)
        return map.sourceRanges(forMedia: ranges).compactMap { range in
            guard let from = map.outputTime(atSource: range.start), let to = map.outputTime(atSource: range.end) else { return nil }
            return ["from": (from * 100).rounded() / 100, "to": (to * 100).rounded() / 100]
        }
    }
}
