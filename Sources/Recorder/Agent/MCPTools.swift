import AppKit
import AVFoundation
import CryptoKit
import Foundation
import RecorderCore
import ScreenCaptureKit

struct MCPFailure: Error {
    let code: String
    let message: String
}

struct AgentRecordingRequest {
    let client: String
    let target: String
    let maxDuration: Double
}

enum MCPTools {
    static let instructions = """
    Recorder edits screen recordings. Times you send and receive are output seconds (the edited timeline). Typical loop:
    project.open → timeline.get + transcript.get → analyze → edit.apply (lands in a draft) → render.frames / render.sheet
    to check → fix → draft.submit for the human to review. Pass ifRevision from the latest result. Renders go to a cache
    folder; final exports need the user's approval. Key presses are never shared.
    To make a demo yourself: record.targets → record.start {window} → drive the app with your own computer-use tool,
    calling record.mark {label} when each step begins → record.stop (opens the project) → edit as usual: cut from a
    step's settled end to the next step's mark, label steps with text, pace demo, render.lint demo, then draft.submit.
    """
    static let operationSchemas: [[String: Any]] = {
        let number: [String: Any] = ["type": "number", "minimum": 0]
        let string: [String: Any] = ["type": "string"]
        let offset: [String: Any] = ["type": "number", "default": 0]
        let time: [String: Any] = ["description": "Numeric seconds use the ifRevision base timeline. Anchors resolve on the timeline after earlier operations in this batch; offset is signed output seconds, default 0. {marker} is a marker id or a label that exactly one marker has; {ref} is the start of an earlier op in this batch that declared ref; {shot, edge} is a shot id from analyze.shots (unknown until shot analysis is available).", "oneOf": [number,
            ["type": "object", "properties": ["marker": ["type": "string", "minLength": 1], "offset": offset], "required": ["marker"], "additionalProperties": false],
            ["type": "object", "properties": ["ref": ["type": "string", "minLength": 1], "offset": offset], "required": ["ref"], "additionalProperties": false],
            ["type": "object", "properties": ["shot": ["type": "string", "minLength": 1], "edge": ["type": "string", "enum": ["start", "end"], "default": "start"]], "required": ["shot"], "additionalProperties": false]]]
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
            if ["cut", "speed", "zoom", "text", "highlight", "marker", "layer"].contains(name) {
                properties["ref"] = ["type": "string", "minLength": 1, "description": "Names this op's start so later ops in the same batch can anchor on {ref:name}. Unique within the batch."]
            }
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
            op("speed", ["from": number, "to": number, "speed": number,
                "ramp": ["type": "object", "description": "Ease the speed change: output seconds of stepped ramp before and after the span (numeric from/to only).", "properties": ["in": number, "out": number], "additionalProperties": false]], ["from", "to", "speed"]),
            op("zoom", ["from": number, "to": number, "scale": number, "center": center, "follow": follow, "ease": ease], ["from", "to", "scale"]),
            op("text", ["from": number, "to": number, "style": ["type": "string", "enum": TextBlock.Style.allCases.map(\.rawValue)], "text": string, "position": point, "size": textSize, "color": color], ["from", "to", "style", "text"]),
            op("captions", ["maxWords": ["type": "integer", "minimum": 1, "maximum": 100]], []),
            op("highlight", ["from": number, "to": number, "rect": rect, "opacity": number], ["from", "to", "rect"]),
            op("marker", ["at": number, "label": string], ["at", "label"]),
            op("set", ["id": string, "from": number, "to": number,
                "mediaStart": ["type": "number", "minimum": 0, "description": "Layers: media in-point (slip; position and length stay)."],
                "mediaRate": ["type": "number", "minimum": 0.25, "maximum": 16, "description": "Layers: playback rate; the output length follows (2 = twice as fast, half as long)."],
                "text": string, "color": color, "position": point, "size": textSize, "scale": number, "center": center, "follow": follow, "ease": ease,
                "kind": ["type": "string", "enum": ["mask", "highlight", "blur"], "description": "Masks only."],
                "duck": ["type": "boolean", "description": "Audio only: the clip's track drops to 25 % under other tracks' sound (music under speech)."]], ["id"]),
            op("graphic", ["from": number, "to": number,
                "template": ["type": "object", "description": "A template from project.templates: {name, params}. Short and always valid; prefer it.",
                             "properties": ["name": ["type": "string", "enum": GraphicTemplates.catalog.map(\.name)], "params": ["type": "object"]], "required": ["name"], "additionalProperties": false],
                "elements": ["type": "array", "description": "Escape hatch instead of template: [{kind rect|ellipse|line|arrow|text, frame {x,y,w,h} 0–1 inside rect, points [{x,y},{x,y}] for line/arrow, fill/stroke #RRGGBB[AA], width, radius, text, size (pt at 1080p), weight light|regular|medium|bold, align, reveal (s), count [from,to], keys}]",
                             "items": ["type": "object"], "maxItems": 32],
                "space": ["type": "string", "enum": ["canvas", "screen"], "description": "screen: positions are source-frame 0–1 and follow zoom/crop."],
                "anchor": point, "rect": rect,
                "keys": ["type": "array", "description": "Whole-graphic keyframes [{t (s since start), x, y (offsets 0–1), scale, rotation (deg), opacity, ease linear|hold|easeIn|easeOut|easeInOut|spring}]", "items": ["type": "object"], "maxItems": 64]], ["from", "to"]),
            op("freeze", ["at": number, "duration": ["type": "number", "minimum": 0.5, "maximum": 10, "description": "Seconds to hold the frame at `at`; later footage moves back."]], ["at", "duration"]),
            op("transition", ["at": number, "kind": ["type": "string", "enum": ["dissolve", "dip"]], "duration": ["type": "number", "minimum": 0.1, "maximum": 3, "default": 0.5, "description": "At the clip seam nearest `at` (within 0.5 s). dissolve (≥ 0.5 s): the outgoing frame fades into the next clip; dip: through the background."]], ["at", "kind"]),
            op("animate", ["id": string, "keys": ["type": "array", "description": "Replace the keyframes of a layer, graphic or text block (same key shape as graphic.keys); [] clears.", "items": ["type": "object"], "maxItems": 64]], ["id", "keys"]),
            op("layer", ["from": number, "to": number, "asset": ["type": "string", "description": "A media/ file listed by project.assets (reuse an existing layer's media)."],
                "path": ["type": "string", "description": "Absolute path to an image or video in your home or temp folder; imported into the project when applied."],
                "recording": ["type": "string", "description": "A library recording id from project.assets; its screen video becomes a video layer."],
                "rect": rect], ["from"]),
            op("remove", ["id": string], ["id"]),
            op("style", ["patch": ["type": "object"]], ["patch"]),
            op("reframe", ["aspect": ["type": "string", "enum": ["4:5", "1:1", "9:16", "16:9"]], "mode": ["type": "string", "enum": ["perShot", "static"], "default": "perShot", "description": "perShot: one stationary or pan crop per shot aimed at its focus and cursor; static: one crop over every focus. Needs analyze.shots."],
                "focus": ["type": "object", "description": "Per-shot aim override: {\"s12\": {\"x\": 0.7, \"y\": 0.4}} (source frame 0–1, top-left origin).", "additionalProperties": point]], ["aspect"]),
            op("keepShots", ["shots": ["type": "array", "items": string, "description": "Shot ids from analyze.shots to keep; everything else is cut."],
                "protect": ["type": "array", "items": string, "description": "Shots always kept: ids, section:N, or caption~regex (needs analyze.shots captions:true), e.g. caption~graph, so the subject survives an energy filter."],
                "where": ["type": "object", "description": "Keep shots by kind and energy instead of ids.", "properties": ["kind": ["type": "array", "items": ["type": "string", "enum": ShotKind.allCases.map(\.rawValue)]], "minEnergy": number], "additionalProperties": false],
                "trim": ["type": "object", "description": "Source seconds trimmed from the start/end of each kept shot.", "properties": ["lead": number, "tail": number], "additionalProperties": false]], []),
            op("pace", ["beat": ["type": "object", "description": "Seconds a shot is held: default 0.9, payoff 1.3, motion 0.8.", "properties": ["default": number, "payoff": number, "motion": number], "additionalProperties": false],
                "maxStatic": number, "profile": ["type": "string", "enum": ["reel", "demo", "tutorial"], "default": "reel", "description": "Rhythm: reel beat-cuts clicks tight (beats 0.9/1.3/0.8 s, cuts waits ≥ 0.5 s); demo 1.4/2.0/1.2 s, waits ≥ 1 s; tutorial 2.5/3.5/2.0 s, waits ≥ 2 s. maxStatic defaults to the profile's."], "speedFill": ["type": "object", "description": "Speed range used to squeeze holds and slow shots (default 1.5-6).", "properties": ["min": number, "max": number], "additionalProperties": false]], []),
            op("steps", ["lead": ["type": "number", "minimum": 0, "default": 0.4],
                "settle": ["type": "number", "minimum": 0, "default": 1.2],
                "maxGap": ["type": "number", "minimum": 0, "default": 2],
                "retake": ["type": "string", "minLength": 1, "default": "retake:"],
                "protect": ["type": "array", "items": string, "description": "Shots never cut: ids, section:N or caption~regex."]], []),
            op("fitDuration", ["target": number, "tolerance": number, "protect": ["type": "array", "items": string, "description": "Shots never cut: ids, section:N or caption~regex."],
                "minPerSection": ["type": "number", "minimum": 0, "description": "Output seconds every section (shot.section from analyze.shots) keeps at least; report.sections shows kept time per section."],
                "balance": ["type": "string", "enum": ["energy", "even", "proportional"], "default": "energy", "description": "energy: drop the least interesting shots first; even: every section ends near the same seconds; proportional: sections keep time in proportion to their length."],
                "drop": ["type": "array", "items": ["type": "integer", "minimum": 1], "description": "Sections cut whole first (weak scenes), protected shots excepted."]], ["target"]),
            op("autoZoom", ["lead": number, "tail": number, "scale": number, "from": number, "to": number], [])
        ]
    }()
    private static let outputFields: [String: [String: Any]] = {
        let array: [String: Any] = ["type": "array"], object: [String: Any] = ["type": "object"], number: [String: Any] = ["type": "number"]
        let string: [String: Any] = ["type": "string"], boolean: [String: Any] = ["type": "boolean"]
        return [
            "project": ["projects": array, "title": string, "duration": number, "size": object, "clips": ["type": "integer"], "lanes": object, "hasMic": boolean,
                        "hasCamera": boolean, "transcribed": boolean, "access": string, "layers": array, "library": array, "paths": string, "draft": object, "templates": array],
            "record": ["displays": array, "windows": array, "state": string, "at": number, "target": string,
                       "maxDuration": number, "owner": ["type": ["string", "null"]], "marker": string,
                       "markers": ["type": ["array", "integer"]], "discarded": boolean, "size": object,
                       "title": string, "duration": number, "path": string],
            "timeline": ["duration": number, "clips": array, "blocks": array, "markers": array],
            "transcript": ["transcript": string, "words": array, "phrases": array, "truncated": boolean, "from": number],
            "analyze": ["pauses": array, "fillers": array, "idle": array, "typing": array, "clicks": array, "transcript": string, "words": ["type": "integer"]],
            "edit": ["mode": string, "changes": array, "duration": object, "warnings": array, "dryRun": boolean, "undone": string, "lowered": array, "reframe": object,
                     "report": ["type": "object", "description": "With a storyboard: duration, aslSec (visual shots), subShotAslSec, staticSec {before,after}, hookSec, longestStatic {sec,at}, lint [{rule,sev,at,shot,msg,suggest}], reframeJumps, sections [{section, name, srcFrom, srcTo (source s), outFrom, outTo (output s), shots [first,last], keptSec}]."]],
            "draft": ["base": ["type": ["string", "null"]], "ops": ["type": ["array", "integer"]], "changes": ["type": ["array", "integer"]], "submitted": boolean, "stale": boolean, "selected": ["type": "integer"],
                      "excluded": array, "skipped": array, "verdict": string],
            "render": ["files": array, "at": array, "seconds": number, "bytes": ["type": "integer"], "cancelled": boolean],
            "export": ["path": string, "srtPath": string, "seconds": number, "bytes": ["type": "integer"]],
            "ui": ["at": number, "select": array]]
    }()
    /// Every argument and op field path ("render.longEdge", "op.fitDuration.balance"), to tell a stale client what it misses.
    static let fieldPaths: Set<String> = {
        var paths = Set<String>()
        for tool in list {
            guard let name = tool["name"] as? String, let props = (tool["inputSchema"] as? [String: Any])?["properties"] as? [String: Any] else { continue }
            paths.formUnion(props.keys.map { "\(name).\($0)" })
        }
        for schema in operationSchemas {
            guard let props = schema["properties"] as? [String: Any], let op = ((props["op"] as? [String: Any])?["enum"] as? [String])?.first else { continue }
            paths.formUnion(props.keys.filter { $0 != "op" }.map { "op.\(op).\($0)" })
        }
        return paths
    }()
    /// Changes whenever any tool name, schema or annotation changes; sent in `initialize` (R2).
    static let schemaVersion: String = {
        let data = (try? JSONSerialization.data(withJSONObject: list, options: [.sortedKeys])) ?? Data()
        return SHA256.hash(data: data).prefix(6).map { String(format: "%02x", $0) }.joined()
    }()
    /// `tool.action` pairs with a handler in `call`; the `mcp-schema` self-test diffs this against `tools/list`.
    static let handled: Set<String> = [
        "record.targets", "record.start", "record.status", "record.mark", "record.pause", "record.resume", "record.stop",
        "project.list", "project.open", "project.info", "project.assets", "project.templates", "timeline.get", "transcript.get",
        "analyze.transcribe", "analyze.pauses", "analyze.fillers", "analyze.activity", "analyze.shots", "edit.apply", "edit.undo",
        "draft.status", "draft.submit", "draft.discard", "render.frames", "render.sheet", "render.clip", "render.storyboard", "render.strip", "render.compare", "render.lint", "render.cancel", "export.final", "ui.show"]
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
            // Every result also carries the project id and the revision it describes (null before project.open); errors carry error/message.
            let output = (outputFields[name] ?? [:]).merging(["project": ["type": ["string", "null"]], "revision": ["type": ["string", "null"]],
                "error": ["type": "string"], "message": ["type": "string"], "fix": ["type": "object"], "current": ["type": ["object", "null"]]], uniquingKeysWith: { a, _ in a })
            return ["name": name, "description": description, "annotations": annotations,
                    "inputSchema": ["type": "object", "properties": properties, "required": ["action"], "additionalProperties": false],
                    "outputSchema": ["type": "object", "properties": output]]
        }
        return [
            tool("record", ["targets", "start", "status", "mark", "pause", "resume", "stop"],
                 "Record the screen while your own computer-use tool performs a demo (Recorder never clicks or types). targets lists displays and windows; start needs exactly one of window or display (area needs display) and asks the user once per session; mark labels the current moment (use the returned marker id as an edit anchor later); stop finishes, opens the project and returns what project.open returns. Video only: no mic, camera or system audio. Area coordinates are points relative to the display, top-left origin; width/height resize window targets only. maxDuration defaults to 600 seconds, including pauses. Use step labels before actions, retake: <step> for retries, result for the final state. Use demo accounts; anything on screen is recorded.",
                 ["window": ["type": "integer", "minimum": 0], "display": ["type": "integer", "minimum": 0],
                  "area": ["type": "object", "properties": ["x": number, "y": number, "width": number, "height": number],
                           "required": ["x", "y", "width", "height"], "additionalProperties": false],
                  "width": ["type": "integer", "minimum": 320, "maximum": 7680],
                  "height": ["type": "integer", "minimum": 240, "maximum": 4320],
                  "exclude": ["type": "array", "items": string, "maxItems": 20],
                  "title": ["type": "string", "maxLength": 80],
                  "maxDuration": ["type": "number", "minimum": 10, "maximum": 1800],
                  "label": ["type": "string", "minLength": 1, "maxLength": 80], "discard": boolean,
                  "x": ["type": "number", "description": "record.mark only: global pointer x in points, top-left origin."],
                  "y": ["type": "number", "description": "record.mark only: global pointer y in points, top-left origin."],
                  "pointerAction": ["type": "string", "enum": AgentPointer.allCases.map(\.rawValue),
                                    "description": "record.mark only: with x and y, declare a pointer action if the driver sends no mouse events. This records motion without moving the system cursor."]]),
            tool("project", ["list", "open", "info", "assets", "templates"], "List recordings, open one by id or package path, read its summary and revision, list the media a layer op can use (assets), or the motion-graphic templates a graphic op can use (templates).", ["id": string, "path": string], read: true),
            tool("timeline", ["get"], "Read clips, effect blocks and markers in output seconds.", range, read: true),
            tool("transcript", ["get"], "Read up to 2000 spoken words with stable wN ids, or timestamped phrases. Key presses are never returned.", range.merging(["format": ["type": "string", "enum": ["words", "phrases"]]], uniquingKeysWith: { _, b in b }), read: true),
            tool("analyze", ["transcribe", "pauses", "fillers", "activity", "shots"], "Transcribe on-device, find mic pauses/fillers, read activity ranges without key characters, or get the shot storyboard (shots: ids stay tied to source moments across edits; times are output seconds).", ["minDuration": number, "threshold": ["type": "number", "minimum": 0, "maximum": 1],
                "captions": ["type": "boolean", "description": "analyze.shots only: add on-device 6–10 word captions per shot (slower; null when unavailable)."],
                "response_format": ["type": "string", "enum": ["concise", "detailed"], "description": "analyze.shots only: concise (default) omits reasons only; focus is always kept."],
                "thresholds": ["type": "object", "description": "analyze.shots only: optional overrides of ssim, minStable, cutSsim, motionDiff, payoffDiff, cursorSpeed, energyScale. energyScale and minStable must be > 0; ssim and cutSsim within 0…1.", "additionalProperties": ["type": "number", "minimum": 0]]]),   // not read-only: transcribe writes the transcript
            tool("edit", ["apply", "undo"], "Apply atomic edits using the latest ifRevision; edits land in a draft by default. Numeric times use that revision's output timeline; anchors ({marker:id|label, offset}, {ref:name, offset}, {shot, edge}) resolve after earlier ops in the batch. Declare ref:\"name\" on an op to anchor later ops on its start. At most one of keepShots/pace/fitDuration/steps per batch (call edit.apply once per intent). Intent fields: keepShots {shots|where{kind,minEnergy}, protect[id|section:N|caption~re], trim}; pace {profile reel|demo|tutorial, maxStatic, beat, speedFill}; fitDuration {target, tolerance, balance energy|even|proportional, minPerSection, drop[section], protect}; steps {lead, settle, maxGap, retake, protect} trims idle gaps around marked recording steps (run analyze.shots first). protect is per op. undo inside a draft removes your last edit.apply call. Errors carry fix and current.", ["ifRevision": string, "ops": ["type": "array", "items": ["oneOf": operationSchemas]], "dryRun": boolean, "lint": ["type": "string", "enum": ["reel", "tutorial", "demo"], "description": "Profile for report.lint (default reel)."]]),
            tool("draft", ["status", "submit", "discard"], "Read your draft's exclusions, skipped reasons and verdict; submit for review or discard it. A pending submitted draft can receive more edit.apply calls, returning to watching until submitted again. Reframe ops show keys as a count (plus jumps: crop steps not at a cut) unless response_format is detailed; submit returns op/change counts unless detailed.", ["note": string, "response_format": ["type": "string", "enum": ["concise", "detailed"]]]),
            tool("render", ["frames", "sheet", "clip", "storyboard", "strip", "compare", "lint", "cancel"], "Render frames, a contact sheet, a 540p proxy, per-shot storyboard tiles (needs analyze.shots), a filmstrip (strip: from, to, fps 4–8, ≤48 tiles) base|draft rows (compare: at ≤6) into the agent cache (key chips hidden), or lint the draft against a profile (lint: reel, tutorial, demo; needs analyze.shots).", ["at": ["type": "array", "items": number, "maxItems": 24], "shots": ["type": "array", "items": string, "maxItems": 48, "description": "render.storyboard only: shot ids; default all shots the draft keeps."], "page": ["type": "integer", "minimum": 1, "description": "render.storyboard only: 48 tiles per page."], "fps": ["type": "integer", "minimum": 4, "maximum": 8, "description": "render.strip only."], "from": number, "to": number, "count": ["type": "integer", "minimum": 1, "maximum": 24], "longEdge": ["type": "integer", "minimum": 2, "maximum": 640], "draft": boolean, "profile": ["type": "string", "enum": ["reel", "tutorial", "demo"]],
                "grid": ["type": "boolean", "description": "render.frames only: overlay a 0.1-step grid labelled 0–1, origin top-left, matching zoom center and text position coordinates (exact at 1× zoom with no layout padding)."]], read: true),
            tool("export", ["final"], "Export an MP4 after the user's native approval, optionally with SRT subtitles, or only from…to (output seconds).", ["destination": string, "shortEdge": ["type": "integer", "enum": [720, 1080, 2160]], "fps": ["type": "integer", "enum": [24, 30, 60]], "srt": boolean, "from": number, "to": number]),
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
    /// `ref` names declared on the ops of one batch, as name → op index (the batch is the scope; a duplicate name is an error).
    static func opRefs(_ value: Any?) throws -> [String: Int] {
        var refs: [String: Int] = [:]
        for (index, op) in (value as? [[String: Any]] ?? []).enumerated() {
            guard let name = op["ref"] as? String else { continue }
            guard refs.updateValue(index, forKey: name) == nil else { throw MCPFailure(code: "INVALID_OP", message: "ref \(name) is declared twice in this batch; use unique names") }
        }
        return refs
    }
    /// Every op the agent sends, intent or primitive, is checked against its tools/list schema before anything runs:
    /// an unknown or misspelt field is an error, never silently ignored.
    static func validateOp(_ value: [String: Any], index: Int) throws {
        guard let name = value["op"] as? String, let schema = operationSchemas.first(where: {
            (($0["properties"] as? [String: Any])?["op"] as? [String: Any])?["enum"] as? [String] == [name]
        }), let properties = schema["properties"] as? [String: Any] else {
            throw MCPFailure(code: "INVALID_OP", message: "op \(index) has an unknown op name; revise it using tools/list")
        }
        if let unknown = value.keys.sorted().first(where: { properties[$0] == nil }) {
            throw MCPFailure(code: "INVALID_OP", message: "op \(index) \(name): unknown field \(unknown); valid: \(properties.keys.filter { $0 != "op" }.sorted().joined(separator: ", "))")
        }
        for (key, field) in value {   // nested objects (where, trim, beat, speedFill, ramp) name their valid fields too
            guard let fields = field as? [String: Any], let sub = (properties[key] as? [String: Any])?["properties"] as? [String: Any],
                  let unknown = fields.keys.sorted().first(where: { sub[$0] == nil }) else { continue }
            throw MCPFailure(code: "INVALID_OP", message: "op \(index) \(name): unknown field \(key).\(unknown); valid: \(sub.keys.sorted().joined(separator: ", "))")
        }
        if let missing = (schema["required"] as? [String] ?? []).first(where: { value[$0] == nil }) {
            throw MCPFailure(code: "INVALID_OP", message: "op \(index) \(name): missing \(missing); revise it using tools/list")
        }
        if let problem = schemaViolation(value, schema, path: "op \(index)") {
            throw MCPFailure(code: "INVALID_OP", message: "\(problem.message); revise the op using tools/list")
        }
    }
    static func decodeOps(_ value: Any?) throws -> [EditOp] {
        guard let values = value as? [[String: Any]] else { throw MCPFailure(code: "INVALID_OP", message: "edit.apply needs ops: [EditOp]; use tools/list for the op schemas") }
        return try values.enumerated().map { index, value in
            try validateOp(value, index: index)
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
    /// `raw` is the JSON op list: a reframe's optional `focus: {"s12": {x, y}}` re-aims those shots (feedback run 6 #7).
    @MainActor private static func reframed(_ ops: [EditOp], raw: Any?, model: EditorModel) async throws -> [EditOp] {
        var storyboard: Storyboard?, out: [EditOp] = []
        let rawOps = raw as? [[String: Any]] ?? []
        for (index, op) in ops.enumerated() {
            guard case let .reframe(aspect, mode, nil) = op else { out.append(op); continue }
            if storyboard == nil { storyboard = try loadStoryboard(model: model) }
            var points: [String: NormPoint] = [:]
            for (id, value) in (rawOps.indices.contains(index) ? rawOps[index]["focus"] as? [String: Any] : nil) ?? [:] {
                guard let point = value as? [String: Any], let x = point["x"] as? Double, let y = point["y"] as? Double, (0...1).contains(x), (0...1).contains(y) else {
                    throw MCPFailure(code: "INVALID_OP", message: "reframe focus.\(id) must be {x, y} in 0–1 (source frame, top-left origin)")
                }
                points[id] = NormPoint(x: x, y: y)
            }
            let (board, unknown) = storyboard!.refocused(points)
            if let id = unknown.first { throw MCPFailure(code: "INVALID_OP", message: "reframe focus: unknown shot \(id); use ids from analyze.shots") }
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
        context.shotTime = shotTime(model: model)
        if needsSilence {
            guard model.liveProject.source.hasMic, let audio = Waveform.audioURL(in: model.packageURL, file: "mic.m4a") else { throw notTranscribed() }
            context.silent = silentRanges(levels: try await Waveform.peaks(for: audio), perSecond: Double(Waveform.peaksPerSecond), minDuration: 0, pad: 0)
        }
        return context
    }
    /// `{shot, edge}` anchors: source seconds of a shot edge from analyze.shots' cache (shot ids are source-keyed, so replay is stable).
    @MainActor static func shotTime(model: EditorModel) -> (@Sendable (String, Bool) -> Double?)? {
        guard let board = try? loadStoryboard(model: model) else { return nil }
        let edges = Dictionary(board.shots.map { ($0.id, ($0.from, $0.to)) }, uniquingKeysWith: { a, _ in a })
        return { id, end in edges[id].map { end ? $0.1 : $0.0 } }
    }
    private static func lintProfile(_ value: Any?) throws -> LintProfile {
        guard let value else { return .reel }
        guard let name = value as? String, let profile = LintProfile(name: name) else { throw MCPFailure(code: "INVALID_OP", message: "lint/profile must be reel, tutorial or demo") }
        return profile
    }
    /// Intents and ramped speed become cut/speed/zoom ops against the viewed timeline.
    private static func lowerIntentOps(_ value: Any?, project: Project, events: EventLog, storyboard: Storyboard?) throws -> (Any?, [Int], [LoweredIntent]) {
        guard let values = value as? [[String: Any]], values.contains(where: { ["keepShots", "pace", "fitDuration", "autoZoom", "steps"].contains($0["op"] as? String) || $0["ramp"] != nil }) else { return (value, (value as? [Any] ?? []).indices.map { $0 }, []) }
        for (index, op) in values.enumerated() { try validateOp(op, index: index) }   // intents bypassed decodeOps' check (R3-3)
        guard let raw = try? JSONDecoder().decode([JSONValue].self, from: JSONSerialization.data(withJSONObject: values)) else {
            throw MCPFailure(code: "INVALID_OP", message: "edit.apply ops must be JSON objects; use tools/list for the op schemas")
        }
        let activity: [Double] = values.contains { ($0["op"] as? String) == "steps" }
            ? events.events.compactMap { event in
                switch event.k {
                case .down, .up, .drag, .scroll, .key, .typing: return event.t
                case .move, .cursor: return nil
                }
            } : []
        let result = try lowerIntents(raw, project: project, clicks: events.clicks(), activity: activity) {
            guard let storyboard else { throw MCPFailure(code: "NOT_ANALYZED", message: "Run analyze.shots first") }
            return storyboard
        }
        return (try JSONSerialization.jsonObject(with: JSONEncoder().encode(result.ops)), result.origin, result.lowered)
    }
    @MainActor private static func edit(_ action: String, _ args: [String: Any], model: EditorModel, session: MCPSession) async throws -> [String: Any] {
        try requireEditable(model, draftSession: session, allowInvisible: true)
        let level = AgentAccess.level(for: model.liveProject.id)
        guard level == .draft || level == .live else { throw MCPFailure(code: "PERMISSION_DENIED", message: "Editing needs Draft or Live access in the Claude tab") }
        let active = session.draft.flatMap { $0.verdict == nil ? $0 : nil }
        if let active, active.baseProject.id != model.liveProject.id || level == .live {
            throw MCPFailure(code: "REVIEW_IN_PROGRESS", message: "Discard or finish the pending draft, or reopen its project, before editing")
        }
        if action == "undo", level == .draft {
            guard var draft = active, !draft.calls.isEmpty else { throw MCPFailure(code: "INVALID_OP", message: "Nothing to undo in this draft") }
            let undone = draft.changes.last?.first?.summary ?? "edit"
            try draft.popLastCall()
            if draft.calls.isEmpty { try MCPServer.shared.finishReview(session, commit: false) }
            else { session.draft = draft; try MCPServer.shared.review(session, watching: true); DraftPlayback.shared.invalidate(sessionID: session.id) }
            return ["mode": "draft", "undone": undone, "calls": draft.calls.count, "revision": draft.revision]
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
            // Feedback run 6 #8: say what was sent and what is current, and only mention the base when it is the problem.
            throw MCPFailure(code: "STALE_REVISION", message: staleRevisionMessage(sent: sent, current: expected, isDraft: active != nil, draftBase: active?.base, live: liveRevision))
        }
        var board: Storyboard?, reportNote: String?
        do { board = try loadStoryboard(model: model) }
        catch { reportNote = (error as? MCPFailure)?.message ?? "\(error)" }
        let profile = try lintProfile(args["lint"])
        let viewed = try viewedProject(model, session: session)
        let usesSteps = (args["ops"] as? [[String: Any]])?.contains { $0["op"] as? String == "steps" } == true
        let intentBoard = usesSteps ? (try? loadStoryboard(model: model, media: true).inSource(clips: viewed.clips)) : board
        let (loweredOps, origin, lowered) = try lowerIntentOps(args["ops"], project: viewed, events: model.events, storyboard: intentBoard)
        let decoded = try decodeOps(loweredOps)
        let originalDraftID = session.draft?.id
        let dryRun = args["dryRun"] as? Bool ?? false
        let resolution = try await MCPAssets.resolve(decoded, package: model.packageURL, project: model.liveProject, library: decoded.contains(where: { if case .layer(_, _, .recording, _) = $0 { return true }; return false }) ? await libraryRecordings() : [],
                                                     known: session.draft?.assets ?? [:])
        var keepImported = false, rendered: [URL] = []
        defer { if !keepImported || dryRun { MCPAssets.removeFiles(resolution.created + rendered) } }
        var ops = try await reframed(resolution.ops, raw: loweredOps, model: model)
        // freeze: render the held frame from the viewed project (draft included) into media/ (T-933).
        for (i, op) in ops.enumerated() {
            var at: EditTime, render: Double
            switch op {
            case let .freeze(when, _, nil): at = when; render = 0
            case let .transition(when, .dissolve, _, nil): at = when; render = -1.0 / 60   // the outgoing clip's last frame
            default: continue
            }
            guard case .seconds(var time) = at else { throw MCPFailure(code: "INVALID_OP", message: "freeze/transition at must be numeric output seconds") }
            let viewed = try viewedProject(model, session: session)
            if render != 0 { guard let seam = viewed.seam(near: time) else { throw MCPFailure(code: "INVALID_OP", message: "no clip seam within 0.5 s of \(time); seams are at timeline.get clip edges") }; time = max(0, seam.at + render) }
            let frame = EditorModel(packageURL: model.packageURL, project: viewed, events: model.events)
            guard time >= 0, time <= viewed.exportDuration, let png = try await EditorWindowController.renderFramesPNG(model: frame, at: [time], longEdge: nil).first else {
                throw MCPFailure(code: "OUT_OF_RANGE", message: "freeze at must be inside 0–\(viewed.exportDuration)")
            }
            let file = "media/\(render == 0 ? "freeze" : "transition")-\(UUID().uuidString).png", url = model.packageURL.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: url, options: .atomic)
            rendered.append(url)
            switch op {
            case let .freeze(_, duration, _): ops[i] = .freeze(at: at, duration: duration, file: file)
            case let .transition(_, kind, duration, _): ops[i] = .transition(at: at, kind: kind, duration: duration, file: file)
            default: break
            }
        }
        var context = try await editContext(ops, model: model)
        context.assets = resolution.assets
        context.refs = try opRefs(args["ops"])
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
        var result: (project: Project, changes: [EditChange])
        var nextRevision = expected
        do {
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
        } catch let error as EditError { throw error.remapped(origin) }
        // Draft replay keeps lowered indices; the payload speaks the agent's original batch indices.
        result.changes = result.changes.map { var c = $0; c.op = origin.indices.contains(c.op) ? origin[c.op] : c.op; return c }
        if !dryRun, !(resolution.created + rendered).isEmpty {
            keepImported = true
            session.agentMedia.formUnion((resolution.created + rendered).map { "media/" + $0.lastPathComponent })
            session.agentMediaPackage = model.packageURL
        }
        var payload: [String: Any] = ["revision": nextRevision, "mode": level.rawValue, "changes": try json(result.changes),
                "duration": ["before": before.exportDuration, "after": result.project.exportDuration], "warnings": warnings(result.project, changes: result.changes), "dryRun": dryRun]
        if let reportNote { payload["reportNote"] = reportNote }
        // Pure Core work (lint dry-runs each suggestion) off the main thread so the editor stays responsive.
        if let board { let after = result.project; payload["report"] = try json(await Task.detached { editReport(before: before, after: after, storyboard: board, profile: profile) }.value) }
        if !lowered.isEmpty { payload["lowered"] = try json(lowered) }
        if ops.contains(where: { if case .reframe = $0 { return true }; return false }) {
            // Feedback run 6 #7: say whether the crop keys actually changed.
            payload["reframe"] = ["keysBefore": before.cropKeys.count, "keysAfter": result.project.cropKeys.count,
                                  "changed": before.cropKeys != result.project.cropKeys || before.output != result.project.output, "shots": board?.shots.count ?? 0]
        }
        return payload
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
    /// R1: a reconnecting session takes over a disconnected session's in-memory draft, else re-adopts `agent-draft.json`.
    /// Orphans of the same client name win; with no name match any disconnected owner of this project's draft is taken
    /// (a client restart may rename itself). A draft some connected session holds is never duplicated from the file.
    @MainActor private static func adoptDraft(_ session: MCPSession, model: EditorModel) throws {
        session.draftRestoreError = nil
        let projectID = model.liveProject.id
        guard session.draft == nil || session.draft?.verdict != nil, AgentAccess.level(for: projectID) == .draft else { return }
        let orphans = MCPServer.shared.sessions.filter { !$0.connected && $0 !== session && $0.draft?.verdict == nil && $0.draft?.baseProject.id == projectID }
        if let orphan = orphans.first(where: { $0.agentName == session.agentName }) ?? orphans.first {
            session.draft = orphan.draft; orphan.draft = nil
            session.persistedPackage = orphan.persistedPackage; orphan.persistedPackage = nil
            session.agentMedia = orphan.agentMedia; session.agentMediaPackage = orphan.agentMediaPackage; orphan.agentMedia = []
            if model.reviewSessionID == orphan.id { model.reviewSessionID = session.id }
            DraftPlayback.shared.invalidate(sessionID: orphan.id)
            MCPServer.shared.removeFinishedSessions()
            return
        }
        let package = model.packageURL
        let record: AgentDraftRecord
        do {
            guard let found = try AgentDraftRecord.read(from: package) else { return }
            record = found
        } catch {
            AgentDraftRecord.quarantine(in: package)
            session.draftRestoreError = "agent-draft.json could not be read (\(error.localizedDescription)); kept as agent-draft.failed.json, edit.apply starts a new draft"
            return
        }
        guard !MCPServer.shared.sessions.contains(where: { $0 !== session && $0.draft?.id == record.id }) else { return }   // a live session owns it
        do {
            guard record.baseProject.id == projectID else { throw MCPFailure(code: "NO_PROJECT", message: "the draft belongs to another project") }
            session.draft = try AgentDraft(record, words: model.transcript ?? [], shotTime: shotTime(model: model))
            session.persistedPackage = package
            session.agentMedia = Set(session.draft?.assets.keys.map { $0 } ?? []); session.agentMediaPackage = package
            try? MCPServer.shared.review(session, watching: !record.submitted)   // shows it in the editor when the base still matches
        } catch {
            session.draft = nil
            AgentDraftRecord.quarantine(in: package)
            session.draftRestoreError = "agent-draft.json could not be restored (\(error)); kept as agent-draft.failed.json, edit.apply starts a new draft"
        }
    }
    /// The `draft` block of project.open: id, status (drafting, submitted or stale) and how many changes (draft.status lists them).
    static func draftSummary(_ draft: AgentDraft, live: Project) throws -> [String: Any] {
        var changes = draft.changes.flatMap { $0 }
        for index in changes.indices { changes[index].op = index }
        let stale = draft.base != (try revision(live))
        return ["id": draft.id, "status": stale ? "stale" : draft.submitted ? "submitted" : "drafting", "base": draft.base, "revision": draft.revision,
                "changes": changes.count, "list": "draft.status"]   // the full list costs ~10 KB per open
    }
    @MainActor private static func draft(_ action: String, _ args: [String: Any], model: EditorModel, session: MCPSession,
                                         notify: ((String, String) -> Void)?) async throws -> [String: Any] {
        if action == "submit" { try requireEditable(model, draftSession: session) }
        if action != "status", model.voiceover.isActive { throw MCPFailure(code: "PERMISSION_DENIED", message: "Recording a voiceover; stop it before reviewing") }
        if let draft = session.draft, draft.baseProject.id != model.liveProject.id, action != "discard" {
            throw MCPFailure(code: "NO_PROJECT", message: "Reopen the pending draft's project before checking or submitting it")
        }
        if action == "discard" { try MCPServer.shared.finishReview(session, commit: false) }
        if action == "submit" {
            guard session.draft != nil, session.draft?.verdict == nil else { throw MCPFailure(code: "INVALID_OP", message: "Create a draft with edit.apply before submitting it") }
            session.draft?.submitted = true; session.draft?.note = args["note"] as? String
            let wasActive = NSApp.isActive
            if wasActive { _ = await EditorWindowController.open(package: model.packageURL).value }
            try MCPServer.shared.review(session)
            if !wasActive, model.reviewSessionID == session.id, !model.isWatchingDraft, let count = session.draft?.selectedCount {
                let title = "Draft ready: \(model.liveProject.title)"
                let body = "\(session.agentName) submitted \(count) changes"
                if let notify { notify(title, body) }
                else { (NSApp.delegate as? AppDelegate)?.notifyDraft(title: title, body: body, package: model.packageURL) }
            }
        }
        let draft = session.draft
        var changes = draft?.changes.flatMap { $0 } ?? []
        for index in changes.indices { changes[index].op = index }
        let flatOps = draft?.calls.flatMap { $0 } ?? []
        var ops = try json(flatOps) as? [[String: Any]] ?? []
        if args["response_format"] as? String != "detailed" {   // ~140 crop keys per reframe are most of a 25 KB reply
            let board = try? loadStoryboard(model: model)
            for (i, op) in flatOps.enumerated() where i < ops.count {
                guard case let .reframe(_, _, keys?) = op else { continue }
                ops[i]["keys"] = keys.count
                if let board { ops[i]["jumps"] = cropJumps(keys, storyboard: board) }
            }
        }
        var payload: [String: Any] = ["base": draft?.base as Any? ?? NSNull(), "ops": ops,
                                     "changes": try json(changes), "submitted": draft?.submitted ?? false,
                                     "stale": draft.map { $0.verdict == nil && $0.base != (try? revision(model.liveProject)) } ?? false,
                                     "selected": draft?.selectedCount ?? 0]
        if let draft {
            payload["excluded"] = draft.rows.enumerated().filter { draft.excluded.contains($0.element.id) }.map(\.offset)
            payload["skipped"] = draft.rows.enumerated().compactMap { index, row -> [String: Any]? in
                draft.skipped[row.id].map { ["op": index, "reason": $0] }
            }
        }
        // submit only confirms the hand-off: counts instead of every op and change (~10 KB); draft.status or detailed has the lists.
        if action == "submit", args["response_format"] as? String != "detailed" { payload["ops"] = flatOps.count; payload["changes"] = changes.count }
        if let verdict = draft?.verdict ?? session.lastDraftVerdict { payload["verdict"] = verdict }
        if let draft, draft.verdict == nil { payload["revision"] = draft.revision }
        return payload
    }
    @MainActor static func call(_ name: String, _ args: [String: Any], session: MCPSession, progress: @escaping (Double) -> Void = { _ in },
                                approveExport: (@MainActor (AgentExportRequest) async throws -> Bool)? = nil,
                                approveRecording: (@MainActor (AgentRecordingRequest) async throws -> Bool)? = nil,
                                approvalTimeout: Duration = .seconds(600), notify: ((String, String) -> Void)? = nil) async -> [String: Any] {
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
            if ["project", "edit", "draft"].contains(loggedName) || (loggedName == "record" && action == "stop") { session.persistDraft() }
            let projectID = (try? model(for: session))?.liveProject.id ?? session.draft?.baseProject.id
            AgentActivity.shared.finish(activityID, result: errorCode ?? outcome, isError: errorCode != nil, projectID: projectID)
        }
        do {
            guard definition != nil, action != "invalid", Set(args.keys).isSubset(of: Set(properties.keys)) else {
                throw MCPFailure(code: "INVALID_OP", message: "Use a tool/action and arguments from tools/list, then retry")
            }
            if name == "record", action == "mark", let label = args["label"] as? String,
               label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw MCPFailure(code: "INVALID_OP", message: "mark needs a nonempty label")
            }
            for (key, value) in args.sorted(by: { $0.key < $1.key }) {
                if let schema = properties[key] as? [String: Any], let problem = schemaViolation(value, schema, path: key) {
                    throw MCPFailure(code: problem.range ? "OUT_OF_RANGE" : "INVALID_OP", message: "\(problem.message); revise it using tools/list and retry")
                }
            }
            if name != "record", session.projectURL != nil {
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
                payload = try await openProject(url: url, session: session)
            } else if name == "record" {
                payload = try await record(action, args, session: session, approve: approveRecording, approvalTimeout: approvalTimeout)
            } else {
                let model = try model(for: session)
                let viewed = try viewedProject(model, session: session)
                switch (name, action) {
                case ("project", "info"): payload = info(model, project: viewed)
                case ("project", "assets"): payload = MCPAssets.list(project: viewed, library: await libraryRecordings())
                case ("project", "templates"): payload = ["templates": try json(GraphicTemplates.catalog)]
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
                    _ = try await ShotAnalysis.signals(package: model.packageURL, progress: progress)
                    // The thresholds used here become the project's segmentation, so every tool reads this same shot table.
                    let thresholdsURL = model.packageURL.appendingPathComponent(ShotAnalysis.thresholdsName)
                    let captionsURL = model.packageURL.appendingPathComponent(ShotAnalysis.captionsName)
                    if (try? JSONDecoder().decode(ShotThresholds.self, from: Data(contentsOf: thresholdsURL))) != thresholds { try? FileManager.default.removeItem(at: captionsURL) }   // new ids
                    try? JSONEncoder().encode(thresholds).write(to: thresholdsURL, options: .atomic)
                    // ponytail: no recorder:// resource mechanism exists, so shots carry no thumb; use render.frames at a shot's time.
                    var source = try loadStoryboard(model: model)
                    if args["captions"] as? Bool == true {
                        source = try await AgentCaptions.captionShots(source, model: model)
                        // Kept in the package so intent ops can protect "caption~…" shots without re-running OCR.
                        let captions = Dictionary(source.shots.compactMap { s in s.caption.map { (s.id, $0) } }, uniquingKeysWith: { a, _ in a })
                        try? JSONEncoder().encode(captions).write(to: captionsURL, options: .atomic)
                    } else if Set(source.shots.compactMap(\.section)).count > 1 {
                        // Sections are named without captions:true: OCR only each section's representative shot, once ("" = no text).
                        var captions = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: captionsURL))) ?? [:]
                        let todo = source.sectionRepresentatives().filter { captions[$0.id] == nil }
                        if !todo.isEmpty {
                            let named = try await AgentCaptions.captionShots(Storyboard(duration: source.duration, fps: source.fps, shots: todo, summary: source.summary), model: model)
                            for shot in named.shots { captions[shot.id] = shot.caption ?? "" }
                            try? JSONEncoder().encode(captions).write(to: captionsURL, options: .atomic)
                            for i in source.shots.indices { if let c = captions[source.shots[i].id], !c.isEmpty { source.shots[i].caption = c } }
                        }
                    }
                    // Media-keyed table mapped through the viewed project's own clips and layers (T-901, EDITING-CORE D2).
                    var board = try loadStoryboard(model: model, media: true).output(project: viewed)
                    let named = Dictionary(source.shots.compactMap { s in s.caption.map { (s.id, $0) } }, uniquingKeysWith: { a, _ in a })
                    let sections = Dictionary(source.shots.compactMap { s in s.section.map { (s.id, $0) } }, uniquingKeysWith: { a, _ in a })
                    for i in board.shots.indices where board.shots[i].layer == nil {
                        board.shots[i].caption = named[board.shots[i].id] ?? board.shots[i].caption
                        board.shots[i].section = sections[board.shots[i].id]
                    }
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
                case ("draft", _): payload = try await draft(action, args, model: model, session: session, notify: notify)
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
            if session.projectURL != nil, name != "record" || (action == "stop" && payload["discarded"] as? Bool != true) {
                let current = try model(for: session)
                try requireAccess(current.liveProject, tool: name)
                if payload["project"] == nil { payload["project"] = current.liveProject.id }
                if payload["revision"] == nil { payload["revision"] = try revision(viewedProject(current, session: session)) }
            } else {
                if payload["project"] == nil { payload["project"] = NSNull() }
                if payload["revision"] == nil { payload["revision"] = NSNull() }
            }
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
            } else { failure = error as? MCPFailure ?? MCPFailure(code: name == "record" ? "RECORDING_FAILED" : "INVALID_OP", message: "\(error.localizedDescription); check Recorder and retry") }
            errorCode = failure.code
            // R7: every error says how to fix the call and where the project stands now.
            var fix: [String: Any] = ["hint": hints[failure.code] ?? "Revise the call using tools/list and retry"]
            var current: Any = NSNull()
            if name != "record", let model = try? model(for: session), let viewed = try? viewedProject(model, session: session) {
                var state: [String: Any] = ["revision": (try? revision(viewed)) ?? "", "duration": viewed.exportDuration]
                if failure.code == "OUT_OF_RANGE" || failure.message.contains("clip edge") {
                    // Only the ~20 clips nearest the failing time, so a long project does not flood the error.
                    var time = 0.0
                    if let editError = error as? EditError, let index = editError.opIndex, let ops = try? decodeOps(args["ops"]), ops.indices.contains(index) { time = ops[index].startSeconds ?? 0 }
                    let near = agentTimeline(viewed).clips.sorted { abs(($0.from + $0.to) / 2 - time) < abs(($1.from + $1.to) / 2 - time) }.prefix(20)
                    state["clips"] = near.sorted { $0.from < $1.from }.map { ["from": $0.from, "to": $0.to] }
                }
                current = state
                if name == "edit", let editError = error as? EditError, let index = editError.opIndex, let ops = try? decodeOps(args["ops"]),
                   let corrected = viewed.suggestedFix(for: editError, ops: ops), let object = try? object(corrected) {
                    fix["index"] = index; fix["op"] = object
                }
            }
            return result(["error": failure.code, "message": "\(failure.code): \(failure.message)", "fix": fix, "current": current], isError: true)
        }
    }

    @MainActor private static func recordingWindows(_ content: SCShareableContent) -> [SCWindow] {
        content.windows.filter {
            $0.windowLayer == 0 && $0.frame.width >= 120 && $0.frame.height >= 80
                && $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier
                && $0.owningApplication?.bundleIdentifier != AppIdentity.bundleID
        }.sorted {
            let lhs = ($0.owningApplication?.applicationName ?? "") + "\n" + ($0.title ?? "")
            let rhs = ($1.owningApplication?.applicationName ?? "") + "\n" + ($1.title ?? "")
            return lhs == rhs ? $0.windowID < $1.windowID : lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }

    @MainActor private static func record(_ action: String, _ args: [String: Any], session: MCPSession,
            approve: (@MainActor (AgentRecordingRequest) async throws -> Bool)?, approvalTimeout: Duration) async throws -> [String: Any] {
        let rc = RecordingController.shared
        let fields: Set<String>
        switch action {
        case "start": fields = ["window", "display", "area", "width", "height", "exclude", "title", "maxDuration"]
        case "mark": fields = ["label", "x", "y", "pointerAction"]
        case "stop": fields = ["discard"]
        default: fields = []
        }
        guard Set(args.keys).subtracting(["action"]).isSubset(of: fields) else {
            throw MCPFailure(code: "INVALID_OP", message: "Use only the arguments for record.\(action)")
        }
        if action == "targets" {
            guard Permissions.screen else { throw MCPFailure(code: "PERMISSION_NEEDED", message: "Screen Recording access is required to list targets") }
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            return ["displays": content.displays.map {
                ["id": $0.displayID, "width": $0.frame.width, "height": $0.frame.height, "main": $0.frame.origin == .zero] as [String: Any]
            }, "windows": recordingWindows(content).prefix(100).map { window in
                let frame = window.frame
                let display = content.displays.first { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }
                return ["id": window.windowID, "app": window.owningApplication?.applicationName ?? "",
                        "bundleId": window.owningApplication?.bundleIdentifier ?? "", "title": window.title ?? "",
                        "x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height,
                        "display": display.map { $0.displayID as Any } ?? NSNull()] as [String: Any]
            }]
        }
        if action == "status" {
            if rc.state == .idle, let failure = rc.lastAgentFailure, failure.owner == session.id {
                throw MCPFailure(code: "RECORDING_FAILED", message: failure.message)
            }
            let owner: Any = rc.state == .idle ? NSNull() : rc.agentOwner.map { $0 == session.id ? "you" : "other" } ?? "user"
            var result: [String: Any] = ["state": String(describing: rc.state), "at": rc.elapsed, "markers": rc.markers.count, "owner": owner]
            if let cap = rc.maxDuration { result["maxDuration"] = cap }
            if rc.state == .idle, let saved = rc.lastAgentPackage, saved.owner == session.id,
               let project = try? Project.load(from: saved.url.appendingPathComponent("project.json")) {
                result["project"] = project.id; result["at"] = project.source.duration; result["markers"] = project.markers.count
            }
            return result
        }
        if action == "start" {
            let windowID = (args["window"] as? NSNumber)?.doubleValue, displayID = (args["display"] as? NSNumber)?.doubleValue
            guard (windowID == nil) != (displayID == nil),
                  windowID == nil || (args["area"] == nil && args["exclude"] == nil),
                  (args["width"] == nil) == (args["height"] == nil),
                  args["width"] == nil || windowID != nil else {
                throw MCPFailure(code: "INVALID_OP", message: "start needs window OR display (+ optional area); width and height must both be given, for a window only; exclude is for display/area only")
            }
            guard session.connected else { throw MCPFailure(code: "DENIED", message: "The recording session disconnected") }
            guard Permissions.allGranted else { throw MCPFailure(code: "PERMISSION_NEEDED", message: "Screen Recording and Accessibility access are required") }
            guard rc.state == .idle, session.recordingApprovalTask == nil else { throw MCPFailure(code: "RECORDING_BUSY", message: "Another recording or approval is running") }
            func resolve(_ content: SCShareableContent) throws -> CaptureTarget {
                if let windowID {
                    guard let window = recordingWindows(content).first(where: { Double($0.windowID) == windowID }) else {
                        throw MCPFailure(code: "NO_TARGET", message: "The window is no longer on screen")
                    }
                    return .windows([window])
                }
                guard let display = content.displays.first(where: { Double($0.displayID) == displayID }) else {
                    throw MCPFailure(code: "NO_TARGET", message: "The display is no longer available")
                }
                if let area = args["area"] as? [String: Any] {
                    let rect = CGRect(x: try number(area, "x", default: 0), y: try number(area, "y", default: 0),
                                      width: try number(area, "width", default: 0), height: try number(area, "height", default: 0))
                    guard rect.width > 0, rect.height > 0, CGRect(origin: .zero, size: display.frame.size).contains(rect) else {
                        throw MCPFailure(code: "OUT_OF_RANGE", message: "area must lie inside the display, in points relative to its top-left")
                    }
                    return .area(display, rect)
                }
                return .display(display)
            }
            let cap = try number(args, "maxDuration", default: 600)
            var target = try resolve(await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true))
            if !session.recordingApproved {
                if !UserDefaults.standard.bool(forKey: "agentRecording.allowWithoutAsking") {
                    let request = AgentRecordingRequest(client: session.agentName, target: target.targetDescription, maxDuration: cap)
                    let approval = Task { @MainActor in
                        try await withThrowingTaskGroup(of: Bool.self) { group in
                            group.addTask { @MainActor in
                                if let approve { return try await approve(request) }
                                return try await RecordingController.approveAgentRecording(request)
                            }
                            group.addTask {
                                try await Task.sleep(for: approvalTimeout)
                                throw MCPFailure(code: "NEEDS_APPROVAL", message: "Recording approval timed out; request it again when the user is ready")
                            }
                            defer { group.cancelAll() }
                            return try await group.next() ?? false
                        }
                    }
                    session.recordingApprovalTask = approval
                    defer { session.recordingApprovalTask = nil }
                    let granted: Bool
                    do { granted = try await approval.value }
                    catch is CancellationError { throw MCPFailure(code: "DENIED", message: "Recording approval was cancelled") }
                    guard granted else { throw MCPFailure(code: "DENIED", message: "The user denied this recording; ask them before requesting it again") }
                }
                session.recordingApproved = true
            }
            guard session.connected else { throw MCPFailure(code: "DENIED", message: "The recording session disconnected during approval") }
            guard rc.state == .idle else { throw MCPFailure(code: "RECORDING_BUSY", message: "Another recording started during approval") }
            // Consent can outlive a window; never capture the stale target snapshot.
            target = try resolve(await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true))
            guard rc.state == .idle else { throw MCPFailure(code: "RECORDING_BUSY", message: "Another recording started while resolving the target") }
            var size: [String: Any]?
            if case .windows(let windows) = target, let width = (args["width"] as? NSNumber)?.doubleValue, let height = (args["height"] as? NSNumber)?.doubleValue {
                if let pid = windows[0].owningApplication?.processID {
                    WindowResizer.focus(pid: pid, windowTitle: windows[0].title, frame: windows[0].frame)
                    WindowResizer.resize(pid: pid, windowTitle: windows[0].title, to: CGSize(width: width, height: height))
                    try await Task.sleep(for: .milliseconds(300))
                    target = try resolve(await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true))
                }
                if abs(target.frameInScreenPoints.width - Double(width)) > 2 || abs(target.frameInScreenPoints.height - Double(height)) > 2 {
                    size = ["width": target.frameInScreenPoints.width, "height": target.frameInScreenPoints.height]
                }
            }
            guard session.connected else { throw MCPFailure(code: "DENIED", message: "The recording session disconnected") }
            let settings = RecordingSettings(agentCopyOf: .shared, excludedBundleIDs: args["exclude"] as? [String] ?? [])
            try await rc.beginForAgent(target: target, settings: settings, owner: session.id, title: args["title"] as? String, maxDuration: cap)
            if !session.connected { rc.finish(); throw MCPFailure(code: "DENIED", message: "The recording session disconnected; its take is being saved") }
            var result: [String: Any] = ["state": String(describing: rc.state), "target": target.targetDescription, "maxDuration": cap, "at": 0]
            if let size { result["size"] = size }
            return result
        }
        if rc.state != .idle {
            guard rc.agentOwner == session.id else { throw MCPFailure(code: "RECORDING_BUSY", message: "This recording belongs to another session or the user") }
        } else if let failure = rc.lastAgentFailure, failure.owner == session.id {
            throw MCPFailure(code: "RECORDING_FAILED", message: failure.message)
        }
        if action == "stop" {
            guard rc.agentOwner == session.id || (rc.state == .idle && rc.lastAgentPackage?.owner == session.id) else {
                throw MCPFailure(code: "NOT_RECORDING", message: "This session has no recording to stop")
            }
            if args["discard"] as? Bool == true {
                guard [.countdown, .recording, .paused].contains(rc.state) else {
                    throw MCPFailure(code: "NOT_RECORDING", message: "This take has already finished; it was kept")
                }
                rc.cancel()
                for _ in 0..<60 where rc.agentOwner == session.id { try await Task.sleep(for: .milliseconds(50)) }
                guard rc.agentOwner != session.id else { throw MCPFailure(code: "RECORDING_FAILED", message: "Discard did not finish within three seconds") }
                return ["discarded": true]
            }
            let url = try await rc.finishForAgent()
            var result = try await openProject(url: url, session: session)
            let project = try Project.load(from: url.appendingPathComponent("project.json"))
            result["markers"] = project.markers.map { ["id": $0.id, "at": $0.time, "label": $0.label] as [String: Any] }
            result["path"] = url.path
            return result
        }
        guard rc.agentOwner == session.id, rc.state == .recording || rc.state == .paused else {
            throw MCPFailure(code: "NOT_RECORDING", message: "This session is not recording")
        }
        switch action {
        case "mark":
            guard let text = args["label"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MCPFailure(code: "INVALID_OP", message: "mark needs a nonempty label")
            }
            guard rc.markers.count < 500 else { throw MCPFailure(code: "OUT_OF_RANGE", message: "A recording takes at most 500 markers") }
            let label = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let marker: Marker
            if args["x"] != nil || args["y"] != nil || args["pointerAction"] != nil {
                guard args["x"] != nil, args["y"] != nil, let value = args["pointerAction"] as? String,
                      let pointerAction = AgentPointer(rawValue: value) else {
                    throw MCPFailure(code: "INVALID_OP", message: "Send x, y and pointerAction together for a pointer mark")
                }
                let point = try CGPoint(x: number(args, "x", default: 0), y: number(args, "y", default: 0))
                marker = rc.addMarker(label: label, point: point, action: pointerAction)
            } else {
                marker = rc.addMarker(label: label)
            }
            return ["marker": marker.id, "at": marker.time]
        case "pause": rc.pause()
        case "resume": rc.resume()
        default: throw MCPFailure(code: "INVALID_OP", message: "Unknown recording action")
        }
        return ["state": String(describing: rc.state), "at": rc.elapsed]
    }

    @MainActor private static func openProject(url: URL, session: MCPSession) async throws -> [String: Any] {
        guard url.pathExtension == "recorder" else { throw MCPFailure(code: "NO_PROJECT", message: "Supply a .recorder package directory, then retry project.open") }
        let project = try await Task.detached { try Project.load(from: url.appendingPathComponent("project.json")) }.value
        try requireAccess(project, tool: "project")
        guard let controller = await EditorWindowController.open(package: url).value else {
            throw MCPFailure(code: "NO_PROJECT", message: "Recorder could not open this package; check its media in Recorder and retry project.open")
        }
        session.projectURL = controller.model.packageURL.standardizedFileURL
        try adoptDraft(session, model: controller.model)
        let viewed = try viewedProject(controller.model, session: session)
        var payload = info(controller.model, project: viewed)
        payload["revision"] = try revision(viewed)
        if let draft = session.draft, draft.verdict == nil, draft.baseProject.id == controller.model.liveProject.id { payload["draft"] = try draftSummary(draft, live: controller.model.liveProject) }
        else if let failure = session.draftRestoreError { payload["draft"] = ["status": "unrecoverable", "error": failure] }
        return payload
    }

    private static let hints = [
        "PERMISSION_NEEDED": "Ask the user to grant Recorder Screen Recording and Accessibility in System Settings ▸ Privacy & Security, then retry",
        "NO_TARGET": "Call record.targets again and use a current window or display id; the window must be on screen",
        "RECORDING_BUSY": "Another recording is running (the user's or another session's); wait for it to end or ask the user",
        "NOT_RECORDING": "Call record.start first; record.status shows the current state",
        "RECORDING_FAILED": "Recording could not start or finish; the user can recover the package from Recorder; tell them before retrying",
        "STALE_REVISION": "Retry edit.apply with ifRevision set to current.revision; re-read timeline.get first if times may have moved",
        "OUT_OF_RANGE": "Use times inside 0–current.duration; clip edges are in current.clips",
        "INVALID_OP": "Revise the op against tools/list (fields, ranges, enums) and retry",
        "NO_PROJECT": "Call project.open with an id or .recorder path, then retry",
        "NOT_TRANSCRIBED": "Call analyze.transcribe (needs a mic recording), then retry",
        "TRANSCRIPT_CHANGED": "Call transcript.get for the current transcript id and word ids, then retry",
        "PERMISSION_DENIED": "Ask the user to change this project's access in the Claude tab",
        "REVIEW_IN_PROGRESS": "Finish or discard the current review/draft, then retry",
        "RENDER_BUSY": "Wait for the running render or call render.cancel",
        "NEEDS_APPROVAL": "Request approval again when the user is ready",
        "DENIED": "Ask the user before requesting this again"]
    // Only fixed tool/kind names and aggregate numbers enter activity, never argument or response text.
    static func activityIntent(_ name: String, _ action: String, _ args: [String: Any]) -> String {
        switch (name, action) {
        case ("record", "targets"): return "Listing capture targets"
        case ("record", "start"): return "Starting recording"
        case ("record", "status"): return "Checking recording"
        case ("record", "mark"): return "Marking step"
        case ("record", "pause"): return "Pausing recording"
        case ("record", "resume"): return "Resuming recording"
        case ("record", "stop"): return "Stopping recording"
        case ("edit", "apply"):
            guard let ops = try? decodeOps(args["ops"]) else { return "Applying edits" }
            var kinds: [String] = []
            for op in ops {
                let kind: String
                switch op {
                case .captions: kind = "captions"
                case .highlight: kind = "highlight"
                case .set: kind = "set"
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
        case ("project", "templates"): return "Reading templates"
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
        case ("render", "lint"): return "Linting edit"
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
        case ("record", "targets"): return "\((payload["windows"] as? [Any])?.count ?? 0) windows"
        case ("record", "start"), ("record", "resume"): return "Recording"
        case ("record", "pause"): return "Paused"
        case ("record", "mark"): return "Marker added"
        case ("record", "stop"):
            return payload["discarded"] as? Bool == true ? "Discarded" : String(format: "%.1f s, %d markers", payload["duration"] as? Double ?? 0, (payload["markers"] as? [Any])?.count ?? 0)
        case ("record", "status"): return "Recording status checked"
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
        settings.shortEdge = Int(edge); settings.fps = Int(fps)
        let includeSRT = args["srt"] as? Bool ?? false
        // T-937: optional from/to exports just that output range (MP4 only; SRT cues are whole-timeline, so not combined).
        var range: TimeRange?
        if args["from"] != nil || args["to"] != nil {
            let from = try number(args, "from", default: 0), to = try number(args, "to", default: project.exportDuration)
            guard from >= 0, to > from + 0.1, to <= project.exportDuration else { throw MCPFailure(code: "OUT_OF_RANGE", message: "export range needs 0 ≤ from < to ≤ \(project.exportDuration)") }
            guard !includeSRT else { throw MCPFailure(code: "INVALID_OP", message: "srt covers the whole timeline; export a range without srt") }
            range = TimeRange(start: from, end: to)
        }
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
            let exporter = Exporter(model: frozen, settings: settings, destination: movie, outputRange: range)
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
        // Agents fire checks in parallel: wait for the running render instead of failing (render.cancel stops only the running one).
        while let running = session.renderTask {
            _ = await running.result
            if session.renderTask == running { await Task.yield() }   // let the finished render's caller clear it
        }
        let project = args["draft"] as? Bool == false ? model.liveProject : try viewedProject(model, session: session)
        if action == "lint" {
            let (live, board, profile) = (model.liveProject, try loadStoryboard(model: model), try lintProfile(args["profile"]))
            let report = await Task.detached { editReport(before: live, after: project, storyboard: board, profile: profile) }.value
            return (["revision": try revision(project), "profile": (args["profile"] as? String) ?? "reel", "report": try json(report)], [])
        }
        let revision = try revision(project)
        let projectID = project.id
        let frozen = AgentRender.renderModel(for: model, project: project)
        let duration = frozen.project.exportDuration
        var times: [Double] = []
        let edge = try number(args, "longEdge", default: 640)   // range comes from the tool schema
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
                // frames/sheet: the schema caps at 24; compare renders two frames per time, so it keeps its own 6.
                guard !values.isEmpty, action != "compare" || values.count <= 6 else { throw MCPFailure(code: "OUT_OF_RANGE", message: "Pass 1–24 frame/sheet times or 1–6 compare times") }
                times = try values.map { try number(["at": $0], "at", default: -1) }
            } else if action == "sheet" {
                // Feedback run 6 #6: sample only from…to when given.
                let count = try number(args, "count", default: 12), lo = try number(args, "from", default: 0), hi = try number(args, "to", default: duration)
                guard lo >= 0, hi > lo, hi <= duration else { throw MCPFailure(code: "OUT_OF_RANGE", message: "render.sheet needs 0 ≤ from < to ≤ \(duration)") }
                times = sheetTimes(count: Int(count), from: lo, to: hi)
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
    /// `media: true` keeps media-file seconds (for `Storyboard.output(project:)`, which also maps layers).
    @MainActor static func loadStoryboard(model: EditorModel, media: Bool = false) throws -> Storyboard {
        guard let signals = ShotAnalysis.cachedSignals(package: model.packageURL) else {
            throw MCPFailure(code: "NO_STORYBOARD", message: "run analyze.shots first (decoded once, then cached)")
        }
        let thresholds = (try? JSONDecoder().decode(ShotThresholds.self, from: Data(contentsOf: model.packageURL.appendingPathComponent(ShotAnalysis.thresholdsName)))) ?? ShotThresholds()
        var board = storyboard(signals: signals, fps: ShotAnalysis.fps, events: model.events.events, thresholds: thresholds)
        if !media { board = board.inSource(clips: model.liveProject.clips) }
        if let captions = try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: model.packageURL.appendingPathComponent(ShotAnalysis.captionsName))) {
            for i in board.shots.indices { board.shots[i].caption = captions[board.shots[i].id].flatMap { $0.isEmpty ? nil : $0 } }
        }
        return board
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
