import AppKit
import Darwin
import Foundation
import Observation
import RecorderCore

struct AgentDraft {
    let id = UUID().uuidString
    var base: String
    var baseProject: Project
    var calls: [[EditOp]] = []
    var changes: [[EditChange]] = []
    var contexts: [EditContext] = []
    var note: String?
    var submitted = false
    var verdict: String?
    var excluded: Set<[Int]> = []
    var skipped: [[Int]: String] = [:]
    var cutRanges: [(start: Double, end: Double, duration: Double)] = []
    var revision: String
    private(set) var duration: Double

    init(base: String, baseProject: Project) {
        self.base = base; self.baseProject = baseProject; revision = base; duration = baseProject.exportDuration
    }
    private func replayContext(_ context: EditContext, call: Int, indices: [Int]) -> EditContext {
        var context = context
        context.operationSeeds = indices.map { "\(id):\(call):\($0)" }
        return context
    }
    func project(from start: Project? = nil, context: EditContext) throws -> Project {
        try replay(from: start, context: context, skipInvalid: false).project
    }
    private func replay(from start: Project?, context: EditContext, skipInvalid: Bool) throws -> (project: Project, skipped: [[Int]: String], changes: [[EditChange]], cuts: [(start: Double, end: Double, duration: Double)]) {
        // shortcut: replay every call on each change/read; cache prefixes if measured drafts exceed tens of ops.
        var project = start ?? baseProject
        if let error = project.checkInvariants() { throw EditError.invariant(error) }
        var skipped: [[Int]: String] = [:], changes: [[EditChange]] = []
        var cuts: [(start: Double, end: Double, duration: Double)] = []
        for (callIndex, call) in calls.enumerated() {
            let automaticSkips = self.changes.indices.contains(callIndex) ? Set(self.changes[callIndex].filter(\.skipped).map(\.op)) : []
            var indices = call.indices.filter { !excluded.contains([callIndex, $0]) && (skipInvalid || self.skipped[[callIndex, $0]] == nil || automaticSkips.contains($0)) }
            let frozen = contexts.indices.contains(callIndex) ? contexts[callIndex] : context
            var resolved: [EditChange] = []
            while !indices.isEmpty {
                do {
                    let result = try project.applying(indices.map { call[$0] }, context: replayContext(frozen, call: callIndex, indices: indices))
                    resolved = result.changes.map { change in var change = change; change.op = indices[change.op]; return change }
                    for change in resolved where change.skipped { skipped[[callIndex, change.op]] = change.note ?? "Below the minimum length" }
                    if skipInvalid, indices.contains(where: { isCut(call[$0]) }) {
                        // Compare before/after cuts so free retiming's empty space is never labelled as a cut.
                        let nonCuts = indices.filter { !isCut(call[$0]) }
                        let beforeCuts = nonCuts.isEmpty ? project : try project.applying(nonCuts.map { call[$0] },
                            context: replayContext(frozen, call: callIndex, indices: nonCuts)).project
                        for clip in beforeCuts.clips {
                            var pieces = [TimeRange(start: clip.sourceStart, end: clip.sourceEnd)]
                            for retained in result.project.clips {
                                pieces = pieces.flatMap { piece -> [TimeRange] in
                                    guard retained.sourceStart < piece.end, retained.sourceEnd > piece.start else { return [piece] }
                                    var remaining: [TimeRange] = []
                                    if retained.sourceStart > piece.start { remaining.append(TimeRange(start: piece.start, end: retained.sourceStart)) }
                                    if retained.sourceEnd < piece.end { remaining.append(TimeRange(start: retained.sourceEnd, end: piece.end)) }
                                    return remaining
                                }
                            }
                            cuts += pieces.map { ($0.start, $0.end, ($0.end - $0.start) / clip.timeScale) }
                        }
                    }
                    project = result.project
                    break
                } catch {
                    guard skipInvalid else { throw error }
                    var failed = 0
                    switch error {
                    case EditError.invalidOp(let index, _), EditError.outOfRange(let index, _): failed = index
                    default:
                        // Find the first invalid prefix without shifting this call's base times.
                        for count in 1...indices.count {
                            let prefix = Array(indices.prefix(count))
                            if (try? project.applying(prefix.map { call[$0] }, context: replayContext(frozen, call: callIndex, indices: prefix))) == nil { failed = count - 1; break }
                        }
                    }
                    guard indices.indices.contains(failed) else { throw error }
                    skipped[[callIndex, indices.remove(at: failed)]] = String(describing: error)
                }
            }
            changes.append(resolved)
        }
        return (project, skipped, changes, cuts)
    }
    mutating func refreshReview(on base: Project? = nil, context: EditContext) throws -> Project {
        if let base { baseProject = base; self.base = try MCPTools.revision(base) }
        let result = try replay(from: nil, context: context, skipInvalid: true)
        skipped = result.skipped; cutRanges = result.cuts
        for (call, updated) in result.changes.enumerated() where changes.indices.contains(call) {
            for change in updated {
                if let index = changes[call].firstIndex(where: { $0.op == change.op }) { changes[call][index] = change }
            }
        }
        revision = try MCPTools.revision(result.project)
        duration = result.project.exportDuration
        return result.project
    }
    var selectedCount: Int {
        calls.enumerated().reduce(0) { count, call in count + call.element.indices.filter { !excluded.contains([call.offset, $0]) && skipped[[call.offset, $0]] == nil }.count }
    }
    typealias Row = AgentDraftRow
    var groups: [AgentChangeGroup] { AgentChangeGroup.groups(rows) }
    func seekTime(_ row: Row, in project: Project) throws -> Double {
        var prefix = self
        prefix.calls = Array(calls.prefix(row.call))
        return try row.outputTime(before: prefix.project(context: EditContext()), after: project)
    }
    var rows: [Row] {
        calls.enumerated().flatMap { call, ops in
            ops.enumerated().compactMap { index, op in
                guard changes.indices.contains(call), let change = changes[call].first(where: { $0.op == index }) else { return nil }
                return Row(call: call, index: index, op: op, change: change)
            }
        }
    }
    private func isCut(_ op: EditOp) -> Bool {
        switch op { case .cut, .cutWords, .cutPauses: return true; default: return false }
    }
    mutating func append(_ ops: [EditOp], context: EditContext) throws -> (project: Project, changes: [EditChange]) {
        let current = try project(context: context)
        let result = try current.applying(ops, context: replayContext(context, call: calls.count, indices: Array(ops.indices)))
        let nextRevision = try MCPTools.revision(result.project)
        calls.append(ops); changes.append(result.changes); contexts.append(context)
        submitted = false
        revision = nextRevision
        duration = result.project.exportDuration
        return result
    }
}

enum MCPSocket {
    static func error(_ operation: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "\(operation): \(String(cString: strerror(errno)))"])
    }
    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw CocoaError(.fileWriteInvalidFileName) }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }
    static func connect(_ path: String) throws -> Int32 {
        var address = try address(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw error("socket") }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { let failure = error("connect"); close(fd); throw failure }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { close(fd); throw CocoaError(.fileReadNoPermission) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
        return fd
    }
    static func write(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }
}

enum MCPShim {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("--mcp") else { return }
        // shortcut: no reconnect if the app quits mid-session; reconnect from the MCP client.
        let path = MCPServer.defaultSocketPath
        do {
            var fd: Int32
            do { fd = try MCPSocket.connect(path) }
            catch {
                let launcher = Process()
                launcher.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                let app = Bundle.main.bundleURL
                launcher.arguments = app.pathExtension == "app" ? ["-g", "-j", app.path] : ["-g", "-j", "-b", "space.microapps.recorder"]
                launcher.standardOutput = FileHandle.standardError
                launcher.standardError = FileHandle.standardError
                try launcher.run()
                let deadline = Date().addingTimeInterval(15)
                var connected: Int32?
                while Date() < deadline {
                    if let socket = try? MCPSocket.connect(path) { connected = socket; break }
                    Thread.sleep(forTimeInterval: 0.1)
                }
                guard let connected else { throw NSError(domain: "RecorderMCP", code: 1, userInfo: [NSLocalizedDescriptionKey: "Recorder did not open its MCP socket in 15 seconds; launch Recorder and retry"] ) }
                fd = connected
            }
            let socket = fd
            DispatchQueue.global().async {
                var buffer = [UInt8](repeating: 0, count: 16_384)
                while true {
                    let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else {
                        // Drain replies after piped stdin closes (initialize smoke), then exit on socket EOF.
                        shutdown(socket, SHUT_WR)
                        return
                    }
                    guard MCPSocket.write(Data(buffer.prefix(count)), to: socket) else { exit(0) }
                }
            }
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while true {
                let count = Darwin.read(socket, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                guard count > 0, MCPSocket.write(Data(buffer.prefix(count)), to: STDOUT_FILENO) else { exit(0) }
            }
        } catch {
            FileHandle.standardError.write(Data("Recorder MCP: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}

/// Owns the fd until the read loop ends, so shutdown cannot race descriptor reuse.
private final class MCPConnection: @unchecked Sendable {
    let fd: Int32
    let pending = DispatchGroup()
    private let writer = DispatchQueue(label: "Recorder.MCP.write")
    private let lifecycle = NSLock()
    private var isClosed = false
    init(_ fd: Int32) { self.fd = fd }
    func send(_ object: [String: Any], completed: @escaping () -> Void = {}) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { completed(); return }
        writer.async {
            guard self.lifecycle.withLock({ !self.isClosed }) else { completed(); return }
            if !MCPSocket.write(data + Data([10]), to: self.fd) { Darwin.shutdown(self.fd, SHUT_RDWR) }
            completed()
        }
    }
    func shutdown() { lifecycle.withLock { if !isClosed { Darwin.shutdown(fd, SHUT_RDWR) } } }
    func readLines(_ handle: (Data) -> Void) {
        defer { pending.wait(); writer.sync {}; lifecycle.withLock { isClosed = true; close(fd) } }
        var pending = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return }
            pending.append(contentsOf: buffer.prefix(count))
            while let newline = pending.firstIndex(of: 10) {
                let line = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                // shortcut: bound JSON requests to 4 MiB; use render tools for large media, never embed media in arguments.
                guard line.count <= 4 * 1024 * 1024 else { return }
                handle(line)
            }
            guard pending.count <= 4 * 1024 * 1024 else { return }
        }
    }
}

enum AgentAccess: String, CaseIterable {
    case off, read, draft, live
    static func level(for projectID: String) -> AgentAccess {
        UserDefaults.standard.string(forKey: "agentAccess.\(projectID)").flatMap(Self.init(rawValue:)) ?? .draft
    }
    static func set(_ level: AgentAccess, for projectID: String) { UserDefaults.standard.set(level.rawValue, forKey: "agentAccess.\(projectID)") }
}

@MainActor @Observable final class AgentActivity {
    static let shared = AgentActivity()
    struct Row: Identifiable {
        let id = UUID()
        let time: Date
        let agent: String
        let tool: String
        let intent: String
        var result: String = ""
        var ms: Int = 0
        var isError = false
        var projectID: String? = nil
        var sessionID: String? = nil
    }
    private(set) var rows: [Row] = []
    private(set) var current: [UUID: Row] = [:]
    func log(_ row: Row) { rows.append(row); if rows.count > 200 { rows.removeFirst(rows.count - 200) } }
    @discardableResult func begin(_ row: Row) -> UUID { current[row.id] = row; return row.id }
    func clearPending(_ id: UUID) { current.removeValue(forKey: id) }
    func finish(_ id: UUID, result: String, isError: Bool = false, projectID: String? = nil) {
        guard var row = current.removeValue(forKey: id) else { return }
        row.result = result; row.isError = isError; row.ms = Int(Date().timeIntervalSince(row.time) * 1000)
        row.projectID = projectID ?? row.projectID
        log(row)
    }
    func clear(sessionID: String) {
        rows.removeAll { $0.sessionID == sessionID }
        current = current.filter { $0.value.sessionID != sessionID }
    }
}

@MainActor @Observable final class MCPServer {
    static let shared = MCPServer()
    nonisolated static var defaultSocketPath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Recorder/mcp.sock").path
    }
    private var listener: Int32 = -1
    private var path: String?
    private(set) var sessions: [MCPSession] = []

    func start(socketPath: String = MCPServer.defaultSocketPath) throws {
        guard listener < 0 else { return }
        let url = URL(fileURLWithPath: socketPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var attributes = stat()
        if lstat(socketPath, &attributes) == 0 {
            guard attributes.st_mode & S_IFMT == S_IFSOCK, attributes.st_uid == getuid() else { throw CocoaError(.fileWriteNoPermission) }
            if let live = try? MCPSocket.connect(socketPath) { close(live); throw NSError(domain: NSPOSIXErrorDomain, code: Int(EADDRINUSE)) }
            guard unlink(socketPath) == 0 else { throw MCPSocket.error("remove stale socket") }
        } else if errno != ENOENT { throw MCPSocket.error("inspect socket") }
        var address = try MCPSocket.address(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MCPSocket.error("socket") }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { let error = MCPSocket.error("bind"); close(fd); throw error }
        guard chmod(socketPath, 0o600) == 0, listen(fd, 16) == 0 else {
            let error = MCPSocket.error("listen"); close(fd); unlink(socketPath); throw error
        }
        listener = fd; path = socketPath
        DispatchQueue.global(qos: .utility).async { [weak self] in
            while true {
                let peer = accept(fd, nil, nil)
                if peer < 0 && errno == EINTR { continue }
                guard peer >= 0 else { break }
                var uid: uid_t = 0, gid: gid_t = 0
                guard getpeereid(peer, &uid, &gid) == 0, uid == getuid() else { close(peer); continue }
                var one: Int32 = 1
                setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
                Task { @MainActor in
                    guard let self, self.listener == fd else { close(peer); return }
                    self.attach(peer)
                }
            }
        }
    }
    private func attach(_ fd: Int32) {
        let connection = MCPConnection(fd)
        let session = MCPSession(send: { connection.send($0) }, disconnect: { connection.shutdown() })
        sessions.append(session)
        DispatchQueue.global(qos: .utility).async {
            connection.readLines { line in
                connection.pending.enter()
                Task { @MainActor in
                    let response: [String: Any]?
                    do {
                        let object = try JSONSerialization.jsonObject(with: line, options: [.fragmentsAllowed])
                        if let request = object as? [String: Any] { response = await session.handle(request) }
                        else { response = MCPSession.error(-32600, "Expected a JSON-RPC object", id: NSNull()) }
                    } catch { response = MCPSession.error(-32700, "Invalid JSON; send one UTF-8 JSON object per line", id: NSNull()) }
                    if let response { connection.send(response, completed: { connection.pending.leave() }) }
                    else { connection.pending.leave() }
                }
            }
            Task { @MainActor in
                session.connected = false
                self.removeFinishedSessions()
            }
        }
    }
    func register(_ session: MCPSession) {
        if !sessions.contains(where: { $0 === session }) { sessions.append(session) }
    }
    func projectSessions(_ model: EditorModel) -> [MCPSession] {
        let url = model.packageURL.resolvingSymlinksInPath().standardizedFileURL
        return sessions.filter { $0.projectURL?.resolvingSymlinksInPath().standardizedFileURL == url || $0.draft?.baseProject.id == model.liveProject.id }
    }
    func phase(_ session: MCPSession, model: EditorModel) -> String {
        if model.reviewSessionID == session.id { return model.isWatchingDraft ? "watching" : "reviewing" }
        if session.renderJobID != nil { return "rendering" }
        if session.draft?.submitted == true, session.draft?.verdict == nil { return "reviewing" }
        if session.draft?.verdict == nil, session.draft != nil { return "drafting" }
        return "idle"
    }
    func removeFinishedSessions() {
        sessions.removeAll { !$0.connected && $0.renderJobID == nil && ($0.draft == nil || $0.draft?.verdict != nil) }
    }
    func review(_ session: MCPSession, rebase: Bool = false, watching: Bool = false) throws {
        let model = try MCPTools.model(for: session)
        guard var draft = session.draft, draft.verdict == nil, draft.baseProject.id == model.liveProject.id else {
            throw MCPFailure(code: "NO_PROJECT", message: "Open the draft's project before reviewing it")
        }
        if watching, session.previewSuppressed || (model.isReviewingDraft && model.reviewSessionID != session.id) { return }
        guard !model.voiceover.isActive, !model.isEditingGesture, model.mediaImportStatus == nil,
              !model.isReviewingDraft || model.reviewSessionID == session.id else {
            throw MCPFailure(code: "REVIEW_IN_PROGRESS", message: "Finish the current review, recording or gesture first")
        }
        register(session)
        if !watching { model.inspectorShowsAgent = true }
        session.reviewError = nil
        if !rebase, draft.base != (try MCPTools.revision(model.liveProject)) { return }
        let proposed = try draft.refreshReview(on: rebase ? model.liveProject : nil, context: EditContext(words: model.transcript ?? []))
        if !model.isReviewingDraft {
            EditorWindowController.allOpen.first { $0.model === model }?.coreTimelineView.cancelOperation(nil)
            guard model.beginReview(watching: watching) else { throw MCPFailure(code: "REVIEW_IN_PROGRESS", message: "Finish the current gesture before reviewing") }
        }
        model.reviewSessionID = session.id
        model.isWatchingDraft = watching
        try model.updateReview { $0 = proposed }
        draft.submitted = !watching; session.draft = draft
        if !watching { session.previewSuppressed = false }
        updateMarks(model, base: draft.baseProject)
    }
    func include(_ row: [Int], in session: MCPSession, included: Bool) throws {
        try include([row], in: session, included: included)
    }
    func include(_ rows: [[Int]], in session: MCPSession, included: Bool) throws {
        let model = try MCPTools.model(for: session)
        guard model.reviewSessionID == session.id, !model.isWatchingDraft, var draft = session.draft, draft.submitted,
              rows.allSatisfy({ $0.count == 2 && draft.calls.indices.contains($0[0]) && draft.calls[$0[0]].indices.contains($0[1]) }) else {
            throw MCPFailure(code: "REVIEW_IN_PROGRESS", message: "Start this draft's review before changing its checkboxes")
        }
        for row in rows {
            if included { draft.excluded.remove(row) } else { draft.excluded.insert(row) }
        }
        let proposed = try draft.refreshReview(context: EditContext(words: model.transcript ?? []))
        try model.updateReview { $0 = proposed }
        session.draft = draft; session.reviewError = nil
        updateMarks(model, base: draft.baseProject)
    }
    func finishReview(_ session: MCPSession, commit: Bool) throws {
        let model = EditorWindowController.allOpen.first { $0.model.reviewSessionID == session.id }?.model
        if commit, model == nil || model?.isWatchingDraft == true || session.draft?.submitted != true {
            throw MCPFailure(code: "REVIEW_IN_PROGRESS", message: "Wait for draft.submit before accepting the draft")
        }
        let draft = session.draft
        let note = (draft?.note?.replacingOccurrences(of: "\n", with: " ") ?? "Review edits").prefix(40)
        model?.endReview(commit: commit, name: "Claude: \(note)")
        let count = draft?.selectedCount ?? 0, total = draft?.calls.flatMap { $0 }.count ?? 0
        let verdict = commit ? (count == total ? "accepted" : "accepted \(count) of \(total)") : "discarded"
        session.lastDraftVerdict = verdict
        if commit { session.draft?.verdict = verdict } else { session.draft = nil }
        session.reviewError = nil
        session.previewSuppressed = false
        removeFinishedSessions()
    }
    @discardableResult func takeOverWatching(_ model: EditorModel) -> Bool {
        guard model.isWatchingDraft, let id = model.reviewSessionID, let session = sessions.first(where: { $0.id == id }) else { return false }
        model.endReview(commit: false, name: "")
        session.previewSuppressed = true
        session.reviewError = nil
        return true
    }
    func editorClosing(_ model: EditorModel) {
        guard let id = model.reviewSessionID else { return }
        model.endReview(commit: false, name: "")
        sessions.first { $0.id == id }?.draft?.submitted = false
    }
    private func updateMarks(_ model: EditorModel, base: Project) {
        func ids(_ project: Project) -> Set<String> {
            Set(project.zooms.map(\.id) + project.texts.map(\.id) + project.masks.map(\.id) + project.layouts.map(\.id)
                + project.keystrokeClips.map(\.id) + project.cameraClips.map(\.id) + project.layers.map(\.id) + project.audioClips.map(\.id))
        }
        model.reviewAddedIDs = ids(model.project).subtracting(ids(base))
        let draft = sessions.first { $0.id == model.reviewSessionID }?.draft
        var cuts: [(id: String, time: Double, duration: Double)] = []
        for cut in draft?.cutRanges ?? [] {
            var output = 0.0
            for retained in model.project.clips {
                if retained.sourceStart >= cut.end - 1e-9 { break }
                output += retained.outputDuration
            }
            cuts.append(("\(cut.start):\(cut.end)", model.timeMap.outputTime(atSource: cut.start) ?? output, cut.duration))
        }
        var merged: [(id: String, time: Double, duration: Double)] = []
        for cut in cuts.sorted(by: { $0.time < $1.time }) {
            if let last = merged.last, abs(last.time - cut.time) < 1e-6 {
                merged[merged.count - 1].duration += cut.duration
                merged[merged.count - 1].id += ";\(cut.id)"
            }
            else { merged.append(cut) }
        }
        model.reviewCuts = merged.map { ($0.id, $0.time, String(format: "−%.1f s", $0.duration)) }
    }
    func stop() {
        for controller in EditorWindowController.allOpen { editorClosing(controller.model) }
        guard listener >= 0 else { return }
        shutdown(listener, SHUT_RDWR); close(listener); listener = -1
        for session in sessions { session.renderTask?.cancel(); session.disconnect() }
        sessions = []
        if let path { unlink(path) }
        path = nil
    }
}

@MainActor @Observable final class MCPSession {
    let id = UUID().uuidString
    let connectedSince = Date()
    var connected = true
    var reviewError: String?
    var agentName = "MCP client"
    var projectURL: URL?
    // shortcut: drafts are memory-only and disappear when Recorder quits; persist only if recovery is requested.
    var draft: AgentDraft?
    var lastDraftVerdict: String?
    var previewSuppressed = false
    var shownLiveProjects: Set<String> = []
    @ObservationIgnored var renderTask: Task<[URL], Error>?
    var renderJobID: UUID?
    private let send: ([String: Any]) -> Void
    let disconnect: () -> Void
    init(send: @escaping ([String: Any]) -> Void = { _ in }, disconnect: @escaping () -> Void = {}) {
        self.send = send; self.disconnect = disconnect
    }
    static func error(_ code: Int, _ message: String, id: Any) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }
    func handle(_ request: [String: Any]) async -> [String: Any]? {
        guard request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String,
              request["params"] == nil || request["params"] is [String: Any] else {
            return Self.error(-32600, "Expected jsonrpc 2.0, a method string and object params", id: request["id"] ?? NSNull())
        }
        guard let id = request["id"] else { return nil }
        guard id is String || id is NSNull || ((id as? NSNumber).map { CFGetTypeID($0) != CFBooleanGetTypeID() } ?? false) else {
            return Self.error(-32600, "Request id must be a string or number", id: NSNull())
        }
        let params = request["params"] as? [String: Any] ?? [:]
        let result: [String: Any]
        switch method {
        case "initialize":
            if let info = params["clientInfo"] as? [String: Any], let name = info["name"] as? String { agentName = String(name.prefix(80)) }
            result = ["protocolVersion": "2025-06-18", "capabilities": ["tools": [:]],
                      "serverInfo": ["name": "recorder", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"],
                      "instructions": MCPTools.instructions]
        case "ping": result = [:]
        case "tools/list": result = ["tools": MCPTools.list]
        case "tools/call":
            guard let name = params["name"] as? String, params["arguments"] == nil || params["arguments"] is [String: Any] else {
                return Self.error(-32602, "tools/call needs name and object arguments", id: id)
            }
            let token = (params["_meta"] as? [String: Any])?["progressToken"]
            result = await MCPTools.call(name, params["arguments"] as? [String: Any] ?? [:], session: self, progress: progressReporter(token: token))
        default: return Self.error(-32601, "Unknown method \(method); call initialize or tools/list", id: id)
        }
        return ["jsonrpc": "2.0", "id": id, "result": result]
    }
    func notify(_ method: String, _ params: [String: Any]) { send(["jsonrpc": "2.0", "method": method, "params": params]) }
    private func progressReporter(token: Any?) -> (Double) -> Void {
        var last = Date.distantPast
        return { [weak self] value in
            guard let self, let token, Date().timeIntervalSince(last) >= 0.25 else { return }
            last = Date()
            self.notify("notifications/progress", ["progressToken": token, "progress": value, "total": 1])
        }
    }
}
