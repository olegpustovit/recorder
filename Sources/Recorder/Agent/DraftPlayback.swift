import AppKit
import AVKit
import RecorderCore

/// "Play draft" (T-824): renders the draft being reviewed with the same 540p proxy pipeline as `render.clip`, then plays it
/// natively with audio. One preview at a time; it belongs to a specific draft revision and is thrown away, never shown, if the
/// draft changes, is accepted/discarded or the editor closes while it renders or plays.
@MainActor @Observable final class DraftPlayback: NSObject, NSWindowDelegate {
    static let shared = DraftPlayback()

    /// Identifies exactly what is being previewed.
    struct Identity: Equatable, Sendable {
        var projectID: String
        var sessionID: String
        var draftID: String
        var revision: String
    }
    enum State: Equatable {
        case idle
        case rendering(Double)
        case failed(String)
    }
    private(set) var state: State = .idle
    private(set) var identity: Identity?
    private(set) var presented: Identity?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var token = UUID()
    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private var file: URL?

    var isRendering: Bool { if case .rendering = state { return true }; return false }

    /// Starts a render for `identity`. Ignored while another render runs (the button turns into Cancel instead).
    /// `current` is asked again after rendering: a mismatch means the draft moved on, so the result is discarded.
    /// `render` and `present` are injected so the state machine is testable without a window or a renderer.
    func start(_ identity: Identity, current: @escaping @MainActor () -> Identity?,
               render: @escaping @MainActor (@escaping (Double) -> Void) async throws -> URL,
               present: @escaping @MainActor (URL, Identity) -> Void) {
        guard !isRendering else { return }
        closePreview()
        let mine = UUID()
        token = mine
        self.identity = identity
        state = .rendering(0)
        task = Task { @MainActor [weak self] in
            var output: URL?
            do {
                let url = try await render { value in
                    Task { @MainActor in
                        guard let self, self.token == mine, case .rendering = self.state else { return }
                        self.state = .rendering(min(1, max(0, value)))
                    }
                }
                output = url
                try Task.checkCancellation()
                guard let self, self.token == mine else { throw CancellationError() }
                guard current() == identity else {
                    try? FileManager.default.removeItem(at: url)
                    self.state = .failed("The draft changed while rendering. Play it again.")
                    self.identity = nil
                    self.task = nil
                    return
                }
                self.state = .idle
                self.task = nil
                self.file = url
                self.presented = identity
                present(url, identity)
            } catch {
                if let output { try? FileManager.default.removeItem(at: output) }
                guard let self, self.token == mine else { return }
                self.identity = nil
                self.task = nil
                self.state = error is CancellationError || (error as? MCPFailure)?.code == "DENIED" ? .idle : .failed(Self.message(error))
            }
        }
    }

    static func message(_ error: Error) -> String {
        if let failure = error as? MCPFailure { return failure.message }
        return error.localizedDescription
    }

    func cancel() {
        guard isRendering else { return }
        token = UUID()
        task?.cancel()
        task = nil
        identity = nil
        state = .idle
    }

    /// Drops the render and any open preview that belongs to `sessionID` (draft accepted/discarded, editor closed).
    func invalidate(sessionID: String) {
        if identity?.sessionID == sessionID { cancel() }
        if presented?.sessionID == sessionID { closePreview() }
    }
    func dismissFailure() { if case .failed = state { state = .idle } }

    // MARK: Native player

    func show(_ url: URL, _ identity: Identity, title: String) {
        file = nil   // the new file is already recorded by start(); only an older window may be closed here
        closePreview()
        file = url
        presented = identity
        let player = AVPlayer(url: url)
        let view = AVPlayerView(frame: NSRect(x: 0, y: 0, width: 640, height: 380))
        view.player = player
        view.controlsStyle = .floating
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.contentView = view
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        player.play()
    }

    func closePreview() {
        if let window {
            window.delegate = nil
            (window.contentView as? AVPlayerView)?.player?.pause()
            (window.contentView as? AVPlayerView)?.player = nil
            window.close()
            window.contentView = nil
        }
        window = nil
        if let file { try? FileManager.default.removeItem(at: file) }
        file = nil
        presented = nil
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in self.closePreview() }
    }

    // MARK: Editor integration

    static func identity(model: EditorModel, session: MCPSession) -> Identity? {
        guard let draft = session.draft, draft.verdict == nil, model.reviewSessionID == session.id else { return nil }
        return Identity(projectID: model.liveProject.id, sessionID: session.id, draftID: draft.id, revision: draft.revision)
    }
    func canPlay(model: EditorModel, session: MCPSession?) -> Bool {
        guard let session, Self.identity(model: model, session: session) != nil, model.project.exportDuration > 0 else { return false }
        return true
    }
    /// Toggles: starts a preview, or cancels the one that is rendering.
    func toggle(model: EditorModel, session: MCPSession) {
        if isRendering { cancel(); return }
        guard let identity = Self.identity(model: model, session: session), model.project.exportDuration > 0 else { return }
        let folder = AgentRender.cacheFolder(session: session.id)
        let duration = model.project.exportDuration
        start(identity, current: { [weak model, weak session] in
            guard let model, let session else { return nil }
            return Self.identity(model: model, session: session)
        }, render: { progress in
            try await AgentRender.clip(model: model, from: 0, to: duration, folder: folder, progress: progress)
        }, present: { [weak self] url, identity in
            self?.show(url, identity, title: "Draft preview · \(model.liveProject.title)")
        })
    }
}
