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
    static let operationSchemas: [[String: Any]] = {
        let number: [String: Any] = ["type": "number", "minimum": 0]
        let string: [String: Any] = ["type": "string"]
        let time: [String: Any] = ["description": "Numeric seconds use the ifRevision base timeline. A marker anchor resolves on the timeline after earlier operations in this batch; offset is signed output seconds, default 0.", "oneOf": [number,
            ["type": "object", "properties": ["marker": ["type": "string", "minLength": 1], "offset": ["type": "number", "default": 0]], "required": ["marker"], "additionalProperties": false]]]
        let point: [String: Any] = ["type": "object", "properties": ["x": number, "y": number], "required": ["x", "y"], "additionalProperties": false]
        let center: [String: Any] = ["type": "object", "description": "Normalized 0–1 coordinates in the source frame; origin is the top-left corner.", "properties": ["x": ["type": "number", "minimum": 0, "maximum": 1], "y": ["type": "number", "minimum": 0, "maximum": 1]], "required": ["x", "y"], "additionalProperties": false]
        let follow: [String: Any] = ["type": "string", "enum": ["cursor", "fixed"], "description": "cursor: the camera tracks the cursor (no center); fixed: hold center. Default: cursor when center is omitted, fixed otherwise."]
        let ease: [String: Any] = ["type": "string", "enum": ZoomEase.allCases.map(\.rawValue), "description": "Camera easing preset for this zoom's entry, tracking and exit: focused, smooth, rapid, medium or slow. Default: the project's screen animation."]
        let color: [String: Any] = ["type": "string", "enum": BlockColor.allCases.map(\.rawValue), "description": "Palette colour tag shown on the block (inspector swatch): red, orange, yellow, green, blue, purple or gray."]
        let textSize: [String: Any] = ["type": "number", "minimum": 16, "maximum": 120, "description": "Text size in points, same range as the inspector slider."]
        let rect: [String: Any] = ["type": "object", "properties": ["x": number, "y": number, "w": number, "h": number], "required": ["x", "y", "w", "h"], "additionalProperties": false]
        func op(_ name: String, _ properties: [String: Any], _ required: [String]) -> [String: Any] {
            var properties = properties
            for key in ["from", "to", "at"] where properties[key] != nil { properties[key] = time }
            if ["cut", "cutPauses", "cutWords", "speed"].contains(name) {
                properties["snap"] = ["type": "boolean", "default": name == "cutPauses", "description": "Snap invalid split boundaries to the nearest clip edge. Skips ranges below the clip minimum with a warning; changes[].note reports adjustments."]
            }
            return ["type": "object", "properties": properties.merging(["op": ["type": "string", "enum": [name]]], uniquingKeysWith: { _, b in b }),
             "required": ["op"] + required, "additionalProperties": false]
        }
        return [
            op("cut", ["from": number, "to": number], ["from", "to"]),
            op("cutPauses", ["from": number, "to": number, "minDuration": number, "keepTail": number], []),
            op("cutWords", ["transcript": string, "words": ["type": "array", "items": string]], ["transcript", "words"]),
            op("speed", ["from": number, "to": number, "speed": number], ["from", "to", "speed"]),
            op("zoom", ["from": number, "to": number, "scale": number, "center": center, "follow": follow, "ease": ease], ["from", "to", "scale"]),
            op("text", ["from": number, "to": number, "style": ["type": "string", "enum": TextBlock.Style.allCases.map(\.rawValue)], "text": string, "position": point, "size": textSize, "color": color], ["from", "to", "style", "text"]),
            op("captions", ["maxWords": ["type": "integer", "minimum": 1, "maximum": 100]], []),
            op("highlight", ["from": number, "to": number, "rect": rect, "opacity": number], ["from", "to", "rect"]),
            op("marker", ["at": number, "label": string], ["at", "label"]),
            op("update", ["id": string, "from": number, "to": number, "text": string, "position": point, "size": textSize, "scale": number, "center": center, "follow": follow, "ease": ease, "color": color], ["id"]),
            op("layer", ["from": number, "to": number, "asset": ["type": "string", "description": "A media/ file listed by project.assets (reuse an existing layer's media)."],
                "path": ["type": "string", "description": "Absolute path to an image or video in your home or temp folder; imported into the project when applied."],
                "recording": ["type": "string", "description": "A library recording id from project.assets; its screen video becomes a video layer."],
                "rect": rect], ["from"]),
            op("remove", ["id": string], ["id"]),
            op("style", ["patch": ["type": "object"]], ["patch"]),
            op("reframe", ["aspect": ["type": "string", "enum": ["4:5", "1:1", "9:16", "16:9"]], "mode": ["type": "string", "enum": ["perShot", "static"], "default": "perShot", "description": "perShot: one stationary or pan crop per shot aimed at its focus and cursor; static: one crop over every focus. Needs analyze.shots."]], ["aspect"])
        ]
    }()
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
            tool("project", ["list", "open", "info", "assets"], "List recordings, open one by id or package path, read its summary and revision, or list the media a layer op can use (assets).", ["id": string, "path": string], read: true),
            tool("timeline", ["get"], "Read clips, effect blocks and markers in output seconds.", range, read: true),
            tool("transcript", ["get"], "Read up to 2000 spoken words with stable wN ids, or timestamped phrases. Key presses are never returned.", range.merging(["format": ["type": "string", "enum": ["words", "phrases"]]], uniquingKeysWith: { _, b in b }), read: true),
            tool("analyze", ["transcribe", "pauses", "fillers", "activity", "shots"], "Transcribe on-device, find mic pauses/fillers, read activity ranges without key characters, or get the shot storyboard (shots: ids stay tied to source moments across edits; times are output seconds).", ["minDuration": number, "threshold": number,
                "captions": ["type": "boolean", "description": "analyze.shots only: add on-device 6–10 word captions per shot (slower; null when unavailable)."],
                "response_format": ["type": "string", "enum": ["concise", "detailed"], "description": "analyze.shots only: concise (default) omits reasons only; focus is always kept."],
                "thresholds": ["type": "object", "description": "analyze.shots only: optional overrides of ssim, minStable, cutSsim, motionDiff, payoffDiff, cursorSpeed, energyScale. energyScale and minStable must be > 0; ssim and cutSsim within 0…1.", "additionalProperties": ["type": "number", "minimum": 0]]], read: true),
            tool("edit", ["apply", "undo"], "Apply atomic edits using the latest ifRevision; edits land in a draft by default. Numeric times use that revision's output timeline; {marker:id, offset:seconds} anchors resolve after earlier ops in the batch.", ["ifRevision": string, "ops": ["type": "array", "items": ["oneOf": operationSchemas]], "dryRun": boolean]),
            tool("draft", ["status", "submit", "discard"], "Read your draft's exclusions, skipped reasons and verdict; submit for review or discard it. A pending submitted draft can receive more edit.apply calls, returning to watching until submitted again.", ["note": string]),
            tool("render", ["frames", "sheet", "clip", "storyboard", "strip", "compare", "cancel"], "Render frames, a contact sheet, a 540p proxy, per-shot storyboard tiles (needs analyze.shots), a filmstrip (strip: from, to, fps 4–8, ≤48 tiles) or base|draft rows (compare: at ≤6) into the agent cache. Key chips are hidden.", ["at": ["type": "array", "items": number, "maxItems": 24], "shots": ["type": "array", "items": string, "maxItems": 48, "description": "render.storyboard only: shot ids; default all shots the draft keeps."], "page": ["type": "integer", "minimum": 1, "description": "render.storyboard only: 48 tiles per page."], "fps": ["type": "integer", "minimum": 4, "maximum": 8, "description": "render.strip only."], "from": number, "to": number, "count": ["type": "integer", "minimum": 1, "maximum": 24], "longEdge": ["type": "integer", "minimum": 1, "maximum": 640], "draft": boolean,
                "grid": ["type": "boolean", "description": "render.frames only: overlay a 0.1-step grid labelled 0–1, origin top-left, matching zoom center and text position coordinates (exact at 1× zoom with no layout padding)."]]),
            tool("export", ["final"], "Export an MP4 after the user's native approval, optionally with SRT subtitles.", ["destination": string, "shortEdge": ["type": "integer", "enum": [720, 1080, 2160]], "fps": ["type": "integer", "enum": [24, 30, 60]], "srt": boolean]),
            tool("ui", ["show"], "Move the editor playhead and select blocks by id.", ["at": ["type": "number"], "select": ["type": "array", "items": string]])
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
    @MainActor static func viewedProject(_ model: EditorModel, session: MCPSession) throws -> Project {
        guard let draft = session.draft, draft.verdict == nil, draft.baseProject.id == model.liveProject.id else { return model.liveProject }
        return try draft.project(context: EditContext(words: model.transcript ?? []))
    }
    private static func json<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }
    static func decodeOps(_ value: Any?) throws -> [EditOp] {
        guard let values = value as? [[String: Any]] else { throw MCPFailure(code: "INVALID_OP", message: "edit.apply needs ops: [EditOp]; use tools/list for the op schemas") }
        return try values.enumerated().map { index, value in
            guard let name = value["op"] as? String, let schema = operationSchemas.first(where: {
                (($0["properties"] as? [String: Any])?["op"] as? [String: Any])?["enum"] as? [String] == [name]
            }), let properties = schema["properties"] as? [String: Any],
                Set(value.keys).isSubset(of: Set(properties.keys)), (schema["required"] as? [String] ?? []).allSatisfy({ value[$0] != nil }) else {
                throw MCPFailure(code: "INVALID_OP", message: "op \(index) has missing or unknown fields; revise it using tools/list")
            }
            for key in ["position", "center", "rect"] where value[key] != nil {
                let keys = key == "rect" ? Set(["x", "y", "w", "h"]) : Set(["x", "y"])
                guard let fields = value[key] as? [String: Any], Set(fields.keys) == keys else {
                    throw MCPFailure(code: "INVALID_OP", message: "op \(index) \(key) needs \(keys.sorted().joined(separator: ", ")); revise the op")
                }
                for field in keys { _ = try number(fields, field, default: 0) }
            }
            do { return try JSONDecoder().decode(EditOp.self, from: JSONSerialization.data(withJSONObject: value)) }
            catch { throw MCPFailure(code: "INVALID_OP", message: "op \(index) has an invalid value; revise it using tools/list") }
        }
    }
    @MainActor private static func requireEditable(_ model: EditorModel, draftSession: MCPSession? = nil, allowInvisible: Bool = false) throws {
        guard !model.voiceover.isActive else { throw MCPFailure(code: "PERMISSION_DENIED", message: "Recording a voiceover; stop it before editing or reviewing") }
        guard !model.isEditingGesture, model.mediaImportStatus == nil else { throw MCPFailure(code: "REVIEW_IN_PROGRESS", message: "Finish the import or timeline gesture before editing") }
        if model.isReviewingDraft {
            guard let session = draftSession, let owner = model.reviewSessionID, AgentAccess.level(for: model.liveProject.id) == .draft,
                  owner == session.id || allowInvisible else {
                throw MCPFailure(code: "REVIEW_IN_PROGRESS", message: "Finish the current review before editing or submitting another draft")
            }
        }
    }
    /// Fills each `reframe` op's crop keys from the storyboard so the stored op replays without it.
    @MainActor private static func reframed(_ ops: [EditOp], model: EditorModel) async throws -> [EditOp] {
        var storyboard: Storyboard?, out: [EditOp] = []
        for op in ops {
            guard case let .reframe(aspect, mode, nil) = op else { out.append(op); continue }
            if storyboard == nil { storyboard = try loadStoryboard(model: model) }
            let board = storyboard!
            let source = model.liveProject.source
            out.append(.reframe(aspect: aspect, mode: mode, keys: reframePlan(storyboard: board, aspect: aspect, mode: mode, sourceSize: CGSize(width: source.pixelWidth, height: source.pixelHeight))))
        }
        return out
    }
    @MainActor private static func editContext(_ ops: [EditOp], model: EditorModel) async throws -> EditContext {
        var needsWords = false, needsSilence = false
        for op in ops {
            switch op { case .cutWords, .captions: needsWords = true; case .cutPauses: needsSilence = true; default: break }
        }
        if needsWords, !model.liveProject.source.hasMic || model.transcript == nil { throw notTranscribed() }
        var context = EditContext(words: model.transcript ?? [])
        if needsSilence {
            guard model.liveProject.source.hasMic, let audio = Waveform.audioURL(in: model.packageURL, file: "mic.m4a") else { throw notTranscribed() }
            context.silent = silentRanges(levels: try await Waveform.peaks(for: audio), perSecond: Double(Waveform.peaksPerSecond), minDuration: 0, pad: 0)
        }
        return context
    }
    @MainActor private static func edit(_ action: String, _ args: [String: Any], model: EditorModel, session: MCPSession) async throws -> [String: Any] {
        try requireEditable(model, draftSession: action == "apply" ? session : nil, allowInvisible: true)
        let level = AgentAccess.level(for: model.liveProject.id)
        guard level == .draft || level == .live else { throw MCPFailure(code: "PERMISSION_DENIED", message: "Editing needs Draft or Live access in the Claude tab") }
        let active = session.draft.flatMap { $0.verdict == nil ? $0 : nil }
        if let active, active.baseProject.id != model.liveProject.id || level == .live {
            throw MCPFailure(code: "REVIEW_IN_PROGRESS", message: "Discard or finish the pending draft, or reopen its project, before editing")
        }
        if action == "undo" {
            guard level == .live, let name = model.undoStepNames.last, name.hasPrefix("Claude:") else {
                throw MCPFailure(code: "PERMISSION_DENIED", message: "Undo needs Live access and a Claude edit at the top of the undo stack; use draft.discard for drafts")
            }
            model.undo()
            return ["mode": "live", "undone": name, "revision": try revision(model.liveProject)]
        }
        let liveRevision = try revision(model.liveProject)
        let expected = active?.revision ?? liveRevision
        guard let sent = args["ifRevision"] as? String else { throw MCPFailure(code: "INVALID_OP", message: "Pass ifRevision from timeline.get or the previous edit.apply") }
        guard sent == expected, active == nil || active?.base == liveRevision else {
            throw MCPFailure(code: "STALE_REVISION", message: "Editor is at \(liveRevision), draft is at \(expected); call timeline.get, then discard/review any stale draft and retry")
        }
        let decoded = try decodeOps(args["ops"])
        let originalDraftID = session.draft?.id
        let dryRun = args["dryRun"] as? Bool ?? false
        let resolution = try await MCPAssets.resolve(decoded, package: model.packageURL, project: model.liveProject, library: decoded.contains(where: { if case .layer(_, _, .recording, _) = $0 { return true }; return false }) ? await libraryRecordings() : [],
                                                     known: session.draft?.assets ?? [:])
        var keepImported = false
        defer { if !keepImported || dryRun { MCPAssets.removeFiles(resolution.created) } }
        let ops = try await reframed(resolution.ops, model: model)
        var context = try await editContext(ops, model: model)
        context.assets = resolution.assets
        guard try MCPTools.model(for: session) === model else { throw MCPFailure(code: "NO_PROJECT", message: "Project changed during analysis; reopen it and retry") }
        try requireAccess(model.liveProject, tool: "edit"); try requireEditable(model, draftSession: session, allowInvisible: true)
        guard level == AgentAccess.level(for: model.liveProject.id) else { throw MCPFailure(code: "PERMISSION_DENIED", message: "Access changed during analysis; check access and retry") }
        guard liveRevision == (try revision(model.liveProject)), originalDraftID == session.draft?.id,
              active?.revision == session.draft.flatMap({ $0.verdict == nil ? $0.revision : nil }),
              active?.calls.count == session.draft.flatMap({ $0.verdict == nil ? $0.calls.count : nil }),
              active?.submitted == session.draft.flatMap({ $0.verdict == nil ? $0.submitted : nil }),
              active?.excluded == session.draft.flatMap({ $0.verdict == nil ? $0.excluded : nil }),
              active?.skipped == session.draft.flatMap({ $0.verdict == nil ? $0.skipped : nil }) else {
            throw MCPFailure(code: "STALE_REVISION", message: "The editor or draft changed during analysis; call timeline.get and retry")
        }
        if ops.contains(where: { switch $0 { case .cutWords, .captions: return true; default: return false } }), context.words != model.transcript {
            throw MCPFailure(code: "TRANSCRIPT_CHANGED", message: "Transcript changed during analysis; call transcript.get and retry")
        }
        let before = try viewedProject(model, session: session)
        let result: (project: Project, changes: [EditChange])
        var nextRevision = expected
        if level == .draft {
            var draft = active ?? AgentDraft(base: liveRevision, baseProject: model.liveProject)
            result = try draft.append(ops, context: context)
            if !dryRun, !ops.isEmpty {
                let previous = session.draft
                session.draft = draft
                do { try MCPServer.shared.review(session, watching: true) }
                catch { session.draft = previous; throw error }
                session.lastDraftVerdict = nil; session.reviewError = nil; nextRevision = session.draft?.revision ?? draft.revision
                DraftPlayback.shared.invalidate(sessionID: session.id)   // a preview of the previous revision is stale
                if active == nil, EditorWindowController.allOpen.first(where: { $0.model === model })?.window?.isKeyWindow == true {
                    model.inspectorShowsAgent = true
                }
            }
        } else {
            result = try model.liveProject.applying(ops, context: context)
            if !dryRun, result.project != model.liveProject {
                let summary = result.changes.first?.summary ?? "Edit"
                model.edit("Claude: \(summary)\(result.changes.count > 1 ? " +\(result.changes.count - 1)" : "")") { $0 = result.project }
                nextRevision = try revision(model.liveProject)
                if session.shownLiveProjects.insert(model.liveProject.id).inserted,
                   EditorWindowController.allOpen.first(where: { $0.model === model })?.window?.isKeyWindow == true {
                    model.inspectorShowsAgent = true
                }
            }
        }
        if !dryRun, !resolution.created.isEmpty {
            keepImported = true
            session.agentMedia.formUnion(resolution.created.map { "media/" + $0.lastPathComponent })
            session.agentMediaPackage = model.packageURL
        }
        return ["revision": nextRevision, "mode": level.rawValue, "changes": try json(result.changes),
                "duration": ["before": before.exportDuration, "after": result.project.exportDuration], "warnings": warnings(result.project, changes: result.changes), "dryRun": dryRun]
    }
    static func warnings(_ project: Project, changes: [EditChange]) -> [String] {
        let blocks = agentTimeline(project).blocks.filter { $0.lane == "text" }
        let captions = Set(project.texts.filter { $0.style == .caption }.map(\.id))
        let thirds = Set(project.texts.filter { $0.style == .lowerThird }.map(\.id))
        return changes.filter(\.skipped).compactMap { change in change.note.map { "op \(change.op): \($0)" } } + blocks.filter { thirds.contains($0.id) }.flatMap { third in
            blocks.filter { captions.contains($0.id) && $0.from < third.to && $0.to > third.from }.map {
                "lowerThird \(third.id) overlaps captions \(max(third.from, $0.from))–\(min(third.to, $0.to))"
            }
        }
    }
    @MainActor private static func draft(_ action: String, _ args: [String: Any], model: EditorModel, session: MCPSession) async throws -> [String: Any] {
        if action == "submit" { try requireEditable(model, draftSession: session) }
        if action != "status", model.voiceover.isActive { throw MCPFailure(code: "PERMISSION_DENIED", message: "Recording a voiceover; stop it before reviewing") }
        if let draft = session.draft, draft.baseProject.id != model.liveProject.id, action != "discard" {
            throw MCPFailure(code: "NO_PROJECT", message: "Reopen the pending draft's project before checking or submitting it")
        }
        if action == "discard" { try MCPServer.shared.finishReview(session, commit: false) }
        if action == "submit" {
            guard session.draft != nil, session.draft?.verdict == nil else { throw MCPFailure(code: "INVALID_OP", message: "Create a draft with edit.apply before submitting it") }
            session.draft?.submitted = true; session.draft?.note = args["note"] as? String
            _ = await EditorWindowController.open(package: model.packageURL).value
            try MCPServer.shared.review(session)
        }
        let draft = session.draft
        var changes = draft?.changes.flatMap { $0 } ?? []
        for index in changes.indices { changes[index].op = index }
        var payload: [String: Any] = ["base": draft?.base as Any? ?? NSNull(), "ops": try json(draft?.calls.flatMap { $0 } ?? []),
                                     "changes": try json(changes), "submitted": draft?.submitted ?? false,
                                     "stale": draft.map { $0.verdict == nil && $0.base != (try? revision(model.liveProject)) } ?? false,
                                     "selected": draft?.selectedCount ?? 0]
        if let draft {
            payload["excluded"] = draft.rows.enumerated().filter { draft.excluded.contains($0.element.id) }.map(\.offset)
            payload["skipped"] = draft.rows.enumerated().compactMap { index, row -> [String: Any]? in
                draft.skipped[row.id].map { ["op": index, "reason": $0] }
            }
        }
        if let verdict = draft?.verdict ?? session.lastDraftVerdict { payload["verdict"] = verdict }
        if let draft, draft.verdict == nil { payload["revision"] = draft.revision }
        return payload
    }
    @MainActor static func call(_ name: String, _ args: [String: Any], session: MCPSession, progress: @escaping (Double) -> Void = { _ in },
                                approveExport: (@MainActor (AgentExportRequest) async throws -> Bool)? = nil,
                                approvalTimeout: Duration = .seconds(600)) async -> [String: Any] {
        let began = Date()
        let definition = list.first { $0["name"] as? String == name }
        let properties = (definition?["inputSchema"] as? [String: Any])?["properties"] as? [String: Any] ?? [:]
        let allowed = (properties["action"] as? [String: Any])?["enum"] as? [String] ?? []
        let action = (args["action"] as? String).flatMap { allowed.contains($0) ? $0 : nil } ?? "invalid"
        let loggedName = definition == nil ? "invalid" : name
        let activityID = AgentActivity.shared.begin(.init(time: began, agent: session.agentName, tool: "\(loggedName).\(action)",
            intent: activityIntent(loggedName, action, args), projectID: (try? model(for: session))?.liveProject.id ?? session.draft?.baseProject.id,
            sessionID: session.id))
        var errorCode: String?, outcome = "Completed"
        defer {
            let projectID = (try? model(for: session))?.liveProject.id ?? session.draft?.baseProject.id
            AgentActivity.shared.finish(activityID, result: errorCode ?? outcome, isError: errorCode != nil, projectID: projectID)
        }
        do {
            guard definition != nil, action != "invalid", Set(args.keys).isSubset(of: Set(properties.keys)) else {
                throw MCPFailure(code: "INVALID_OP", message: "Use a tool/action and arguments from tools/list, then retry")
            }
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
                if let current = try? model(for: session) { try requireAccess(current.liveProject, tool: name) }
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
                    if let existing = EditorWindowController.allOpen.first(where: { $0.model.liveProject.id == id }) { url = existing.model.packageURL }
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
                let viewed = try viewedProject(controller.model, session: session)
                payload = info(controller.model, project: viewed)
                payload["revision"] = try revision(viewed)
            } else {
                let model = try model(for: session)
                let viewed = try viewedProject(model, session: session)
                switch (name, action) {
                case ("project", "info"): payload = info(model, project: viewed)
                case ("project", "assets"): payload = MCPAssets.list(project: viewed, library: await libraryRecordings())
                case ("timeline", "get"):
                    let bounds = try bounds(args, duration: viewed.exportDuration)
                    payload = try object(agentTimeline(viewed, from: bounds.0, to: bounds.1))
                case ("transcript", "get"):
                    guard let words = model.transcript else { throw notTranscribed() }
                    let bounds = try bounds(args, duration: viewed.exportDuration)
                    let format = args["format"] as? String ?? "words"
                    guard ["words", "phrases"].contains(format) else { throw MCPFailure(code: "INVALID_OP", message: "transcript.get format must be words or phrases") }
                    var view = agentTranscript(viewed, words: words, from: bounds.0, to: bounds.1)
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
                    guard model.liveProject.source.hasMic, let audio = Waveform.audioURL(in: model.packageURL, file: "mic.m4a") else { throw notTranscribed() }
                    let minimum = try number(args, "minDuration", default: 0.6), threshold = try number(args, "threshold", default: 0.02)
                    guard minimum >= 0, (0...1).contains(threshold) else { throw MCPFailure(code: "OUT_OF_RANGE", message: "Use nonnegative minDuration and threshold between 0 and 1") }
                    let peaks = try await Waveform.peaks(for: audio)
                    let silent = silentRanges(levels: peaks, perSecond: Double(Waveform.peaksPerSecond), threshold: Float(threshold), minDuration: minimum)
                    payload = ["pauses": outputRanges(silent, project: viewed)]
                case ("analyze", "fillers"):
                    guard let words = model.transcript else { throw notTranscribed() }
                    payload = ["fillers": agentTranscript(viewed, words: words).words.filter(\.filler).map {
                        ["word": $0.id, "from": $0.from, "to": $0.to, "text": $0.text] as [String: Any]
                    }]
                case ("analyze", "activity"):
                    let project = viewed, events = model.events.events
                    let map = TimeMap(project.clips)
                    let clicks = model.events.clicks().flatMap { event in
                        project.clips.compactMap { clip -> Double? in
                            guard !clip.isEmpty, clip.file == nil, event.t >= clip.mediaIn, event.t < clip.mediaEnd else { return nil }
                            return map.outputTime(atSource: clip.sourceTime(atMedia: event.t)).map { ($0 * 100).rounded() / 100 }
                        }
                    }.sorted()
                    payload = ["idle": outputRanges(idleRanges(events: events + [InputEvent(t: project.source.duration, k: .move)]), project: project),
                               "typing": outputRanges(typingRanges(events: events), project: project), "clicks": clicks]
                case ("analyze", "shots"):
                    let format = args["response_format"] as? String ?? "concise"
                    guard ["concise", "detailed"].contains(format) else { throw MCPFailure(code: "INVALID_OP", message: "response_format must be concise or detailed") }
                    let thresholds = try ShotAnalysis.thresholds(args["thresholds"])
                    let signals = try await ShotAnalysis.signals(package: model.packageURL, progress: progress)
                    // ponytail: no recorder:// resource mechanism exists, so shots carry no thumb; use render.frames at a shot's time.
                    var source = storyboard(signals: signals, fps: ShotAnalysis.fps, events: model.events.events, thresholds: thresholds)
                    if args["captions"] as? Bool == true { source = try await AgentCaptions.captionShots(source, model: model) }
                    let board = source.mapped(through: TimeMap(viewed.clips))
                    payload = try object(board)
                    if format == "concise", let shots = payload["shots"] as? [[String: Any]] {
                        payload["shots"] = shots.map { $0.filter { $0.key != "reasons" } }
                    }
                case ("analyze", "transcribe"):
                    guard model.liveProject.source.hasMic, Waveform.audioURL(in: model.packageURL, file: "mic.m4a") != nil else { throw notTranscribed() }
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
                case ("edit", _): payload = try await edit(action, args, model: model, session: session)
                case ("draft", _): payload = try await draft(action, args, model: model, session: session)
                case ("export", "final"):
                    (payload, extraContent) = try await exportFinal(args, model: model, session: session, progress: progress,
                        approve: approveExport, approvalTimeout: approvalTimeout)
                case ("ui", "show"):
                    if let selected = args["select"] {
                        guard let ids = selected as? [String] else { throw MCPFailure(code: "INVALID_OP", message: "select must be an array of block ids from timeline.get") }
                        let project = model.project
                        let existing = Set(project.zooms.map(\.id) + project.texts.map(\.id) + project.masks.map(\.id)
                            + project.layouts.map(\.id) + project.cameraClips.map(\.id) + project.keystrokeClips.map(\.id)
                            + project.windowShots.map(\.id) + project.layers.map(\.id) + project.audioClips.map(\.id))
                        model.selectedClips = []
                        model.selection = Set(ids.filter { existing.contains($0) }.compactMap(UUID.init(uuidString:)))
                        if !model.selection.isEmpty { model.inspectorShowsAgent = false }
                    }
                    if args["at"] != nil { model.playhead = min(model.project.exportDuration, max(0, try number(args, "at", default: model.playhead))) }
                    _ = await EditorWindowController.open(package: model.packageURL).value
                    payload = ["at": model.playhead, "select": model.selection.map(\.uuidString).sorted()]
                default: throw MCPFailure(code: "INVALID_OP", message: "\(name).\(action) is not available in this build; use Recorder's editor")
                }
                if ["project", "timeline", "transcript", "analyze"].contains(name) { payload["revision"] = try revision(viewed) }
            }
            if session.projectURL != nil {
                let current = try model(for: session)
                try requireAccess(current.liveProject, tool: name)
                if payload["project"] == nil { payload["project"] = current.liveProject.id }
                if payload["revision"] == nil { payload["revision"] = try revision(viewedProject(current, session: session)) }
            } else { payload["project"] = NSNull(); payload["revision"] = NSNull() }
            outcome = activityResult(name, action, payload)
            var reply = result(payload)
            reply["content"] = (reply["content"] as? [[String: Any]] ?? []) + extraContent
            return reply
        } catch {
            let failure: MCPFailure
            if let editError = error as? EditError {
                let code: String
                switch editError { case .invalidOp: code = "INVALID_OP"; case .outOfRange: code = "OUT_OF_RANGE"; case .transcriptChanged: code = "TRANSCRIPT_CHANGED"; case .invariant: code = "INVARIANT" }
                failure = MCPFailure(code: code, message: String(editError.description.dropFirst(code.count + 2)))
            } else { failure = error as? MCPFailure ?? MCPFailure(code: "INVALID_OP", message: "\(error.localizedDescription); check the project in Recorder and retry") }
            errorCode = failure.code
            return result(["error": failure.code, "message": "\(failure.code): \(failure.message)"], isError: true)
        }
    }

    // Only fixed tool/kind names and aggregate numbers enter activity, never argument or response text.
    static func activityIntent(_ name: String, _ action: String, _ args: [String: Any]) -> String {
        switch (name, action) {
        case ("edit", "apply"):
            guard let ops = try? decodeOps(args["ops"]) else { return "Applying edits" }
            var kinds: [String] = []
            for op in ops {
                let kind: String
                switch op {
                case .captions: kind = "captions"
                case .highlight: kind = "highlight"
                case .update: kind = "update"
                case .remove: kind = "remove"
                case .style: kind = "style"
                case .layer: kind = "layer"
                default: kind = AgentChangeKind(op).rawValue.lowercased()
                }
                if !kinds.contains(kind) { kinds.append(kind) }
            }
            let verb = args["dryRun"] as? Bool == true ? "Checking" : "Applying"
            if ops.isEmpty { return "\(verb) 0 ops" }
            if kinds.count == 1 { return "\(verb) \(ops.count) \(kinds[0]) ops" }
            return "\(verb) \(ops.count) ops · \(kinds.joined(separator: ", "))"
        case ("edit", "undo"): return "Undoing edit"
        case ("project", "list"): return "Reading recordings"
        case ("project", "open"): return "Opening recording"
        case ("project", "info"): return "Reading project"
        case ("project", "assets"): return "Reading assets"
        case ("timeline", "get"): return "Reading timeline"
        case ("transcript", "get"): return "Reading transcript"
        case ("analyze", "pauses"): return "Finding pauses"
        case ("analyze", "fillers"): return "Finding fillers"
        case ("analyze", "activity"): return "Finding activity"
        case ("analyze", "shots"): return "Segmenting shots"
        case ("analyze", "transcribe"): return "Transcribing speech"
        case ("render", "frames"): return "Rendering frames"
        case ("render", "sheet"): return "Rendering contact sheet"
        case ("render", "storyboard"): return "Rendering shot storyboard"
        case ("render", "strip"): return "Rendering filmstrip"
        case ("render", "compare"): return "Rendering base vs draft"
        case ("render", "clip"): return "Rendering preview"
        case ("render", "cancel"): return "Cancelling render"
        case ("draft", "submit"): return "Preparing review"
        case ("draft", "status"): return "Checking draft"
        case ("draft", "discard"): return "Discarding draft"
        case ("export", "final"): return "Exporting final video"
        case ("ui", "show"): return "Showing timeline"
        default: return "Calling Recorder"
        }
    }
    static func activityResult(_ name: String, _ action: String, _ payload: [String: Any]) -> String {
        switch (name, action) {
        case ("edit", "apply"):
            let count = (payload["changes"] as? [Any])?.count ?? 0
            let duration = payload["duration"] as? [String: Double] ?? [:]
            let delta = (duration["after"] ?? 0) - (duration["before"] ?? 0)
            return "\(count) ops · \(String(format: delta < 0 ? "−%.1f s" : "+%.1f s", abs(delta)))\(payload["dryRun"] as? Bool == true ? " · dry run" : "")"
        case ("edit", "undo"): return "Undone"
        case ("draft", "submit"): return payload["stale"] as? Bool == true ? "Stale draft" : "Ready for review · \(payload["selected"] as? Int ?? 0) changes"
        case ("draft", "discard"): return "Discarded"
        case ("analyze", "pauses"): return "\((payload["pauses"] as? [Any])?.count ?? 0) pauses"
        case ("analyze", "fillers"): return "\((payload["fillers"] as? [Any])?.count ?? 0) fillers"
        case ("analyze", "shots"): return "\(((payload["shots"] as? [Any])?.count ?? 0)) shots"
        case ("analyze", "activity"): return "\((payload["idle"] as? [Any])?.count ?? 0) idle ranges"
        case ("analyze", "transcribe"): return "\(payload["words"] as? Int ?? 0) words"
        case ("render", "frames"): return "\((payload["files"] as? [Any])?.count ?? 0) frames"
        case ("render", "sheet"): return "Contact sheet ready"
        case ("render", "storyboard"): return "Storyboard ready"
        case ("render", "strip"): return "Filmstrip ready"
        case ("render", "compare"): return "Comparison ready"
        case ("render", "clip"), ("export", "final"): return String(format: "%.1f s video ready", payload["seconds"] as? Double ?? 0)
        case ("render", "cancel"): return payload["cancelled"] as? Bool == true ? "Cancelled" : "Nothing to cancel"
        case ("project", "list"): return "\((payload["projects"] as? [Any])?.count ?? 0) recordings"
        case ("transcript", "get"): return "\((payload["words"] as? [Any])?.count ?? 0) words"
        default: return "Completed"
        }
    }

    @MainActor private static func exportFinal(_ args: [String: Any], model: EditorModel, session: MCPSession,
            progress: @escaping (Double) -> Void, approve: (@MainActor (AgentExportRequest) async throws -> Bool)?,
            approvalTimeout: Duration) async throws -> ([String: Any], [[String: Any]]) {
        try requireEditable(model)
        guard session.renderTask == nil else { throw MCPFailure(code: "RENDER_BUSY", message: "Wait for the current render/export or call render.cancel") }
        guard let controller = EditorWindowController.allOpen.first(where: { $0.model === model }), controller.window?.attachedSheet == nil else {
            throw MCPFailure(code: "RENDER_BUSY", message: "Close the editor's current sheet before exporting")
        }
        let project = model.liveProject, revision = try revision(model.liveProject)
        guard project.exportDuration > 0 else { throw MCPFailure(code: "OUT_OF_RANGE", message: "Add media before exporting") }
        var settings = ExportSettings.loadDefault()
        settings.format = .mp4
        if ![24, 30, 60].contains(settings.fps) { settings.fps = 30 }
        if ![720, 1080, 2160].contains(settings.shortEdge) { settings.shortEdge = 1080 }
        let edge = try number(args, "shortEdge", default: Double(settings.shortEdge)), fps = try number(args, "fps", default: Double(settings.fps))
        guard [720.0, 1080, 2160].contains(edge), [24.0, 30, 60].contains(fps) else {
            throw MCPFailure(code: "OUT_OF_RANGE", message: "Use shortEdge 720, 1080 or 2160 and fps 24, 30 or 60")
        }
        settings.shortEdge = Int(edge); settings.fps = Int(fps)
        let includeSRT = args["srt"] as? Bool ?? false
        let fm = FileManager.default
        func exists(_ url: URL) -> Bool { (try? fm.attributesOfItem(atPath: url.path)) != nil }
        func used(_ url: URL) -> Bool { exists(url) || (includeSRT && exists(url.deletingPathExtension().appendingPathExtension("srt"))) }
        let destination: URL
        if let path = args["destination"] as? String {
            guard !path.isEmpty else { throw MCPFailure(code: "INVALID_OP", message: "Choose a local .mp4 destination or omit destination for a unique name") }
            destination = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath()
        } else {
            let folder = fm.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Recorder/Exports", isDirectory: true)
            let title = project.title.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
            let name = title.isEmpty ? "Untitled" : title
            var candidate = folder.appendingPathComponent(name).appendingPathExtension("mp4"), suffix = 2
            while used(candidate) { candidate = folder.appendingPathComponent("\(name) \(suffix)").appendingPathExtension("mp4"); suffix += 1 }
            destination = candidate.resolvingSymlinksInPath()
        }
        guard destination.pathExtension.lowercased() == "mp4", !used(destination) else {
            throw MCPFailure(code: "INVALID_OP", message: "Destination must be an unused .mp4 path (and unused .srt path when requested); choose another name")
        }
        let request = AgentExportRequest(project: project, settings: settings, destination: destination, includeSRT: includeSRT, client: session.agentName)
        let frozen = EditorModel(packageURL: model.packageURL, project: project, events: model.events, paths: (model.cursorPath, model.cameraPath))
        let job = UUID()
        let task = Task { @MainActor () throws -> [URL] in
            let granted = try await withThrowingTaskGroup(of: Bool.self) { group in
                group.addTask { @MainActor in
                    if let approve { return try await approve(request) }
                    return try await controller.approveAgentExport(request)
                }
                group.addTask {
                    try await Task.sleep(for: approvalTimeout)
                    throw MCPFailure(code: "NEEDS_APPROVAL", message: "Export approval timed out after ten minutes; request it again when the user is ready")
                }
                defer { group.cancelAll() }
                return try await group.next() ?? false
            }
            try Task.checkCancellation()
            guard granted else { throw MCPFailure(code: "DENIED", message: "The user denied this export; ask them before requesting it again") }
            guard try MCPTools.model(for: session) === model else { throw MCPFailure(code: "NO_PROJECT", message: "The project changed; reopen it before requesting an export") }
            try requireAccess(model.liveProject, tool: "export"); try requireEditable(model)
            guard revision == (try MCPTools.revision(model.liveProject)) else { throw MCPFailure(code: "STALE_REVISION", message: "The project changed during approval; request approval for its latest revision") }
            guard !used(destination) else { throw MCPFailure(code: "INVALID_OP", message: "The destination appeared during approval; choose another name") }
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let staging = destination.deletingLastPathComponent().appendingPathComponent(".recorder-export-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: staging, withIntermediateDirectories: false)
            defer { try? fm.removeItem(at: staging) }
            let movie = staging.appendingPathComponent(destination.lastPathComponent)
            let exporter = Exporter(model: frozen, settings: settings, destination: movie)
            exporter.progress = { value, _, _ in Task { @MainActor in progress(value) } }
            progress(0)
            try await withTaskCancellationHandler { try await exporter.run() } onCancel: { exporter.cancel() }
            try Task.checkCancellation()
            guard try MCPTools.model(for: session) === model else { throw MCPFailure(code: "NO_PROJECT", message: "The editor changed or closed during export; reopen it and retry") }
            try requireAccess(model.liveProject, tool: "export")
            let subtitles = destination.deletingPathExtension().appendingPathExtension("srt")
            let stagedSRT = staging.appendingPathComponent(subtitles.lastPathComponent)
            if includeSRT { try RecorderCore.srt(project).write(to: stagedSRT, atomically: true, encoding: .utf8) }
            // Moving from staging never overwrites a destination created by another export.
            try fm.moveItem(at: movie, to: destination)
            if includeSRT {
                do { try fm.moveItem(at: stagedSRT, to: subtitles) }
                catch { try? fm.removeItem(at: destination); throw error }
            }
            progress(1)
            return includeSRT ? [destination, subtitles] : [destination]
        }
        session.renderTask = task; session.renderJobID = job
        defer { if session.renderJobID == job { session.renderTask = nil; session.renderJobID = nil }; MCPServer.shared.removeFinishedSessions() }
        let files: [URL]
        do { files = try await task.value }
        catch is CancellationError { throw MCPFailure(code: "DENIED", message: "Export cancelled; request another export when ready") }
        catch Exporter.ExportError.cancelled { throw MCPFailure(code: "DENIED", message: "Export cancelled; request another export when ready") }
        var payload: [String: Any] = ["project": project.id, "revision": revision, "path": destination.path,
            "seconds": try await AVURLAsset(url: destination).load(.duration).seconds,
            "bytes": (try fm.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.intValue ?? 0]
        if includeSRT { payload["srtPath"] = files[1].path }
        let links = files.map { ["type": "resource_link", "uri": $0.absoluteString, "name": $0.lastPathComponent,
                                "mimeType": $0.pathExtension == "srt" ? "application/x-subrip" : "video/mp4"] }
        return (payload, links)
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
        let project = args["draft"] as? Bool == false ? model.liveProject : try viewedProject(model, session: session)
        let revision = try revision(project)
        let projectID = project.id
        let frozen = AgentRender.renderModel(for: model, project: project)
        let duration = frozen.project.exportDuration
        var times: [Double] = []
        let edge = try number(args, "longEdge", default: 640)
        guard (2...640).contains(edge) else { throw MCPFailure(code: "OUT_OF_RANGE", message: "longEdge must be 2–640 pixels") }
        var labels: [String]?
        var extra: [String: Any] = [:]
        if action == "compare", args["draft"] as? Bool == false { throw MCPFailure(code: "INVALID_OP", message: "render.compare compares the live project with the draft; draft:false leaves nothing to compare") }
        if action == "storyboard" {
            let board = try loadStoryboard(model: model)
            if args["shots"] != nil, !(args["shots"] is [String]) { throw MCPFailure(code: "INVALID_OP", message: "shots must be an array of shot id strings") }
            let wanted = args["shots"] as? [String]
            if let wanted, let unknown = wanted.first(where: { id in !board.shots.contains { $0.id == id } }) {
                throw MCPFailure(code: "INVALID_OP", message: "Unknown shot id \(unknown); run analyze.shots and use its ids")
            }
            let map = TimeMap(frozen.project.clips)
            let kept = board.shots.filter { wanted?.contains($0.id) ?? true }.compactMap { shot in
                AgentRender.keyframe(shot, fps: board.fps, map: map).map { (shot, $0.output, $0.kept) }
            }
            let pages = max(1, (kept.count + 47) / 48)
            let rawPage = try number(args, "page", default: 1)
            guard rawPage >= 1, rawPage <= Double(pages), rawPage == rawPage.rounded(), case let page = Int(rawPage) else { throw MCPFailure(code: "OUT_OF_RANGE", message: "page must be 1–\(pages)") }
            let slice = kept[(page - 1) * 48 ..< min(kept.count, page * 48)]
            times = slice.map(\.1)
            labels = slice.map { String(format: "%@ %.1fs", $0.0.id, $0.2) }
            extra = ["page": page, "pages": pages, "shots": slice.map(\.0.id)]
            guard !times.isEmpty else { throw MCPFailure(code: "OUT_OF_RANGE", message: "The draft keeps none of these shots") }
        } else if action == "strip" {
            let fps = try number(args, "fps", default: 6)
            let from = try number(args, "from", default: -1), to = try number(args, "to", default: -1)
            guard (4...8).contains(fps), fps == fps.rounded(), from >= 0, to > from, to <= duration, (to - from) * fps <= 48 else {
                throw MCPFailure(code: "OUT_OF_RANGE", message: "render.strip needs fps 4–8 and 0 ≤ from < to ≤ \(duration) with at most 48 tiles (\(Int(48 / fps)) s at \(Int(fps)) fps)")
            }
            times = (0..<max(1, Int(((to - from) * fps).rounded(.down)))).map { from + Double($0) / fps }
            labels = times.map(AgentRender.timecode)
        }
        if action == "frames" || action == "sheet" || action == "compare" {
            if let values = args["at"] as? [Any] {
                guard !values.isEmpty, values.count <= (action == "sheet" ? 24 : 6) else { throw MCPFailure(code: "OUT_OF_RANGE", message: "Use 1–6 frame times or 1–24 sheet times") }
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
        let requested = times, tileLabels = labels
        let grid = args["grid"] as? Bool == true
        if args["grid"] != nil, !(args["grid"] is Bool) || action != "frames" { throw MCPFailure(code: "INVALID_OP", message: "grid must be a boolean and is supported by render.frames only") }
        let task = Task { @MainActor in
            switch action {
            case "frames": return try await AgentRender.frames(model: frozen, at: requested, longEdge: Int(edge), folder: folder, grid: grid)
            case "sheet": return [try await AgentRender.sheet(model: frozen, at: requested, folder: folder)]
            case "storyboard", "strip": return [try await AgentRender.sheet(model: frozen, at: requested, labels: tileLabels, folder: folder)]
            case "compare": return [try await AgentRender.compare(base: AgentRender.renderModel(for: model, project: model.liveProject), draft: frozen, at: requested, folder: folder)]
            case "clip": return [try await AgentRender.clip(model: frozen, from: from, to: to, folder: folder, progress: progress)]
            default: throw MCPFailure(code: "INVALID_OP", message: "Choose a render action from tools/list")
            }
        }
        session.renderTask = task; session.renderJobID = jobID
        defer { if session.renderJobID == jobID { session.renderTask = nil; session.renderJobID = nil }; MCPServer.shared.removeFinishedSessions() }
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
        } else { payload["at"] = times; payload.merge(extra) { _, new in new } }
        try requireAccess(frozen.project, tool: "render")
        guard EditorWindowController.allOpen.contains(where: { $0.model.liveProject.id == projectID }) else {
            throw MCPFailure(code: "NO_PROJECT", message: "The editor closed during rendering; use project.open and retry")
        }
        return (payload, content)
    }

    /// Source-time storyboard from analyze.shots' cached signals, for storyboard/lint/intent/reframe ops.
    // shortcut: uses default thresholds even if analyze.shots was called with overrides; persist them with the cache if agents rely on overrides.
    @MainActor static func loadStoryboard(model: EditorModel) throws -> Storyboard {
        guard let signals = ShotAnalysis.cachedSignals(package: model.packageURL) else {
            throw MCPFailure(code: "NO_STORYBOARD", message: "run analyze.shots first (decoded once, then cached)")
        }
        return storyboard(signals: signals, fps: ShotAnalysis.fps, events: model.events.events)
    }

    @MainActor static func libraryRecordings() async -> [MCPAssets.LibraryRecording] {
        await libraryItems().filter { AgentAccess.level(for: $0.projectID) != .off }
            .map { MCPAssets.LibraryRecording(id: $0.projectID, title: $0.title, duration: $0.duration, package: $0.id.resolvingSymlinksInPath().standardizedFileURL) }
    }
    @MainActor private static func libraryItems() async -> [ProjectStore.Item] {
        let store = ProjectStore(folder: RecordingSettings.shared.projectsFolder)
        await withCheckedContinuation { continuation in store.reload { continuation.resume() } }
        return store.items
    }
    @MainActor private static func info(_ model: EditorModel, project: Project? = nil) -> [String: Any] {
        let p = project ?? model.liveProject
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
