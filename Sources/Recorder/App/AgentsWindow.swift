import AppKit
import RecorderCore
import SwiftUI

/// "Recorder ▸ Connect an Agent…" (⇧⌘A, SPEC §10.1): every MCP client Recorder knows, its status, one-click
/// Connect/Update/Disconnect, the exact command or config to paste by hand, and a guide with prompts to try.
/// Same window pattern as `SettingsWindow`; the config text transforms live in Core (`AgentConfig`).
enum AgentsWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 620),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Connect an Agent"
            w.minSize = NSSize(width: 760, height: 520)
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: AgentsView())
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

enum AgentClient {
    static var recorderExecutable: String { Bundle.main.executableURL!.path }

    /// `claude` from the usual install spots (a Finder-launched app has no login-shell PATH).
    static func claudeCLI() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin", "\(home)/.claude/local", "\(home)/.npm-global/bin", "/opt/homebrew/bin", "/usr/local/bin"]
            .map { $0 + "/claude" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// `agentpack` (or its short name `ap`) from PATH or the usual install folders.
    static func agentpackCLI() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "/run/current-system/sw/bin", "/etc/profiles/per-user/\(NSUserName())/bin"]
            + [".local/bin", ".cargo/bin", "go/bin", ".nix-profile/bin", ".bun/bin", ".npm-global/bin"].map { "\(home)/\($0)" }
        // shortcut: `ap` is trusted without a `--version` check; other tools named `ap` are rare enough here.
        for name in ["agentpack", "ap"] { for d in dirs where FileManager.default.isExecutableFile(atPath: "\(d)/\(name)") { return "\(d)/\(name)" } }
        return nil
    }

    static func run(_ executable: String, _ arguments: [String], in directory: URL? = nil) async throws -> (status: Int32, output: String) {
        try await Task.detached(priority: .userInitiated) {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
            process.currentDirectoryURL = directory ?? FileManager.default.homeDirectoryForCurrentUser
            var environment = ProcessInfo.processInfo.environment
            // Finder-launched apps lack the usual Claude/Homebrew install directories on PATH.
            environment["PATH"] = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path + ":/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            process.environment = environment
            process.standardOutput = pipe; process.standardError = pipe; process.standardInput = FileHandle.nullDevice
            try process.run()
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeout)
            defer { timeout.cancel() }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }.value
    }

    /// Claude Code goes through its CLI (it owns ~/.claude.json); everything else, or a missing CLI, edits the file.
    static func connect(_ p: AgentPlatform, remove: Bool = false) async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser, command = recorderExecutable
        if p.style == .claudeCode, let cli = claudeCLI() {
            _ = try? await run(cli, ["mcp", "remove", AgentConfig.table, "-s", "user"]) // an update re-adds
            if remove { return }
            let added = try await run(cli, AgentConfig.claudeAddArguments(command: command))
            if added.status == 0 { return }
        }
        try AgentConfig.write(p, home: home, command: command, remove: remove)
    }
}

private enum Pane: Hashable { case guide, platform(String), other, agentpack }

struct AgentsView: View {
    @State private var pane: Pane
    /// `initial`: a platform id, "other" or "agentpack" (the settings-png selftest renders each pane).
    init(initial: String? = nil) {
        _pane = State(initialValue: initial == "agentpack" ? .agentpack : initial == "other" ? .other : initial.map { .platform($0) } ?? .guide)
    }
    @State private var statuses: [String: AgentStatus] = [:]
    private var live: [MCPSession] { MCPServer.shared.sessions.filter(\.connected) }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 250)
            Rectangle().fill(Theme.strokeColor).frame(width: 1)
            ScrollView {
                Group {
                    switch pane {
                    case .guide: GuidePane(live: live)
                    case .other: OtherPane()
                    case .agentpack: AgentpackPane()
                    case .platform(let id): PlatformPane(p: AgentPlatform.all.first { $0.id == id }!, status: statuses[id] ?? .notFound,
                                                         live: live.filter { AgentPlatform.all.first { $0.id == id }!.matches(client: $0.agentName) },
                                                         rescan: rescan)
                    }
                }.padding(20).frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .signalWindow()
        .onAppear(perform: rescan)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in rescan() }
    }

    private func rescan() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        for p in AgentPlatform.all { statuses[p.id] = AgentConfig.status(p, home: home, command: AgentClient.recorderExecutable) }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            row("Start here", sub: "How it works · prompts to try", on: pane == .guide) { pane = .guide } chip: { EmptyView() }
            Text("Clients").font(Font(Theme.captionFont)).foregroundStyle(Theme.textTertiaryColor).padding(.top, 12).padding(.leading, 8)
            ForEach(AgentPlatform.all) { p in
                let st = statuses[p.id] ?? .notFound
                row(p.name, sub: "~/" + p.path, on: pane == .platform(p.id), dim: st == .notFound) { pane = .platform(p.id) } chip: {
                    StatusChip(status: st, live: live.contains { p.matches(client: $0.agentName) })
                }
            }
            row("Other client", sub: "Command line + JSON", on: pane == .other) { pane = .other } chip: { EmptyView() }
            Text("Manage").font(Font(Theme.captionFont)).foregroundStyle(Theme.textTertiaryColor).padding(.top, 12).padding(.leading, 8)
            row("agentpack", sub: "One definition · every agent", on: pane == .agentpack, dim: AgentClient.agentpackCLI() == nil) { pane = .agentpack } chip: {
                if AgentClient.agentpackCLI() == nil { StatusChip(status: .notFound) } else { EmptyView() }
            }
            Spacer()
            HStack {
                TechStatus(title: live.isEmpty ? "No agents live" : "\(live.count) live", color: live.isEmpty ? Theme.textTertiaryColor : Theme.layoutColor)
                Spacer()
                Button("Rescan", action: rescan).buttonStyle(TechButtonStyle(kind: .quiet, compact: true))
            }.padding(8)
        }
        .padding(8)
        .background(Theme.bgPanelColor)
    }

    private func row<C: View>(_ name: String, sub: String, on: Bool, dim: Bool = false, action: @escaping () -> Void, @ViewBuilder chip: () -> C) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(Font(Theme.bodyFont)).foregroundStyle(dim && !on ? Theme.textTertiaryColor : Theme.textPrimaryColor)
                    Text(sub).font(Font(Theme.captionFont)).foregroundStyle(Theme.textTertiaryColor).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                chip()
            }
            .padding(.horizontal, 8).frame(height: 38)
            .background(on ? Theme.bgSelectedColor : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

private struct StatusChip: View {
    let status: AgentStatus
    var live = false
    var body: some View {
        switch status {
        case _ where live: TechStatus(title: "Live", color: Theme.accentColor)
        case .connected: TechStatus(title: "Connected", color: Theme.layoutColor)
        case .needsUpdate: TechStatus(title: "Update", color: Theme.warningColor)
        case .notConnected: TechStatus(title: "Off", color: Theme.strokeStrongColor)
        case .notFound: TechStatus(title: "Not found", color: Theme.strokeColor)
        }
    }
}

/// Caption + selectable monospace block + Copy.
private struct CopyBlock: View {
    let caption: String, code: String
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(caption).font(Font(Theme.captionFont)).foregroundStyle(Theme.textSecondaryColor)
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString(code, forType: .string)
                }.buttonStyle(TechButtonStyle(kind: .quiet, compact: true))
            }
            Text(code).font(Font(Theme.captionFont)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                .background(Theme.bgControlColor).overlay(Rectangle().stroke(Theme.strokeColor))
        }
    }
}

private struct PlatformPane: View {
    let p: AgentPlatform, status: AgentStatus, live: [MCPSession]
    let rescan: () -> Void
    @State private var working = false
    @State private var error: String?

    var body: some View {
        let command = AgentClient.recorderExecutable
        VStack(alignment: .leading, spacing: 16) {
            TechSectionLabel(index: "MCP", title: p.name)
            Text(sentence).foregroundStyle(Theme.textSecondaryColor).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                switch status {
                case .connected: Button("Disconnect") { act(remove: true) }.buttonStyle(TechButtonStyle(kind: .danger))
                case .needsUpdate: Button("Update") { act() }.buttonStyle(TechButtonStyle(kind: .primary))
                    Button("Disconnect") { act(remove: true) }.buttonStyle(TechButtonStyle(kind: .danger))
                case .notConnected, .notFound: Button("Connect") { act() }.buttonStyle(TechButtonStyle(kind: .primary))
                }
                Button("Reveal Config") { NSWorkspace.shared.activateFileViewerSelecting([p.url(home: FileManager.default.homeDirectoryForCurrentUser)]) }
                    .buttonStyle(TechButtonStyle(kind: .quiet)).disabled(status == .notFound || status == .notConnected && !FileManager.default.fileExists(atPath: p.url(home: FileManager.default.homeDirectoryForCurrentUser).path))
            }.disabled(working)
            if let error { Text(error).foregroundStyle(Theme.dangerColor).fixedSize(horizontal: false, vertical: true) }
            if !live.isEmpty {
                ForEach(live, id: \.id) { s in
                    TechStatus(title: "Live · \(s.agentName) · \(s.projectURL?.deletingPathExtension().lastPathComponent ?? "no project open") · since \(s.connectedSince.formatted(date: .omitted, time: .shortened))", color: Theme.accentColor)
                }
            }
            if p.style == .claudeCode {
                CopyBlock(caption: "Terminal — same as Connect", code: "claude mcp add recorder -s user -- \(AgentConfig.sh(command)) --mcp")
                CopyBlock(caption: "Check it", code: "claude mcp get recorder")
            } else if p.style == .toml {
                CopyBlock(caption: "Terminal — same as Connect", code: "codex mcp add recorder -- \(AgentConfig.sh(command)) --mcp")
            }
            CopyBlock(caption: "Or paste into ~/\(p.path)", code: AgentConfig.snippet(p, command: command))
            CopyBlock(caption: "Then ask, for example", code: GuidePane.prompts[0])
        }
    }

    private var sentence: String {
        switch status {
        case .notFound: "\(p.name) doesn't seem to be installed (no ~/\((p.path as NSString).deletingLastPathComponent) folder). Connect creates the config anyway, or copy the snippet below."
        case .notConnected: "Connect adds a `recorder` server to \(p.name)'s config. Start a new \(p.name) session afterwards; it launches Recorder on demand."
        case .connected: "\(p.name) is set up to launch this Recorder. Start a new session to pick it up; while it's connected it shows as Live here and in the editor's Claude tab."
        case .needsUpdate(let other): "\(p.name) points at a different Recorder:\n\(other)\nUpdate points it at this app."
        }
    }

    private func act(remove: Bool = false) {
        working = true; error = nil
        Task {
            do { try await AgentClient.connect(p, remove: remove) } catch { self.error = error.localizedDescription }
            working = false
            rescan()
        }
    }
}

private struct OtherPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TechSectionLabel(index: "MCP", title: "Other client")
            Text("Any MCP client that launches stdio servers works. Point it at Recorder's binary with the --mcp argument; it starts the app if needed.")
                .foregroundStyle(Theme.textSecondaryColor).fixedSize(horizontal: false, vertical: true)
            CopyBlock(caption: "Launch line", code: "\(AgentConfig.sh(AgentClient.recorderExecutable)) --mcp")
            CopyBlock(caption: "mcpServers JSON", code: AgentConfig.genericJSON(command: AgentClient.recorderExecutable))
        }
    }
}

struct GuidePane: View {
    let live: [MCPSession]
    static let prompts = [
        "Open my latest Recorder project and cut the long pauses and filler words. Show me a contact sheet, then submit the draft.",
        "Add captions to the whole recording and a lower third with my name and title in the first five seconds.",
        "Zoom in on each click in the first minute, check the frames, and submit it as a draft.",
        "Add chapter cards at each topic change in the transcript.",
        "Export the accepted project as 1080p MP4 with an SRT next to it.",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TechSectionLabel(index: "MCP", title: "Edit with an agent")
            Text("Recorder runs an MCP server. An agent such as Claude Code reads a project's timeline and transcript, proposes cuts, captions, zooms, lower thirds and chapter cards, checks them with rendered frames, and hands you a draft.")
                .foregroundStyle(Theme.textSecondaryColor).fixedSize(horizontal: false, vertical: true)
            step("1", "Connect a client", "Pick it on the left and press Connect. Claude Code uses `claude mcp add`; others get a `recorder` entry in their config file.")
            step("2", "Start a new agent session", "Restart the client or open a new chat so it loads the server. It shows as Live here.")
            step("3", "Ask for an edit", "The agent's changes land as a draft — nothing changes until you review it.")
            step("4", "Review in the editor", "The inspector's Claude tab lists every change: untick what you don't want and press Accept. One Undo reverts it all.")
            step("5", "Export", "Final exports always ask for your approval in Recorder first.")
            Text("Prompts to try").font(Font(Theme.labelFont)).padding(.top, 4)
            ForEach(Self.prompts, id: \.self) { CopyBlock(caption: "Prompt", code: $0) }
            Text("Tools: project · timeline · transcript · analyze · edit · draft · render · export · ui. Keystrokes are never shared with agents; renders go to a cache folder; access per project is set in the Claude tab.")
                .font(Font(Theme.captionFont)).foregroundStyle(Theme.textTertiaryColor).fixedSize(horizontal: false, vertical: true)
            if live.isEmpty { TechStatus(title: "No agent connected yet", color: Theme.strokeStrongColor) }
            else { ForEach(live, id: \.id) { TechStatus(title: "Live · \($0.agentName)", color: Theme.accentColor) } }
        }
    }

    private func step(_ n: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(n).foregroundStyle(Theme.bgWindowColor).frame(width: 22, height: 20).background(Theme.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Font(Theme.bodyFont))
                Text(.init(body)).font(Font(Theme.captionFont)).foregroundStyle(Theme.textSecondaryColor).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// agentpack (SPEC §10.1): declare Recorder once in a project's agentpack.toml and stage it for every agent.
/// Same steps as dbman's pane: `init` when there is no manifest, `mcp add recorder`, `sync`.
private struct AgentpackPane: View {
    @AppStorage("agents.agentpackProject") private var projectPath = ""
    @State private var running = false
    @State private var output = ""
    private let cli = AgentClient.agentpackCLI()

    private var project: URL? { projectPath.isEmpty ? nil : URL(fileURLWithPath: (projectPath as NSString).expandingTildeInPath) }
    private var toml: String? { project.flatMap { try? String(contentsOf: $0.appendingPathComponent("agentpack.toml"), encoding: .utf8) } }
    private var ap: String { cli.map { ($0 as NSString).lastPathComponent } ?? "ap" }
    private var add: [String] { ["mcp", "add", AgentConfig.table, "--command", AgentClient.recorderExecutable, "--args"] + AgentConfig.arguments }
    private var needsAdd: Bool { toml?.contains("recorder") != true }
    private var steps: [[String]] { (toml == nil ? [["init"]] : []) + (needsAdd ? [add] : []) + [["sync"]] }
    private func line(_ args: [String]) -> String { ([ap] + args.map(AgentConfig.sh)).joined(separator: " ") }
    private var cdLine: String { "cd " + AgentConfig.sh(projectPath.isEmpty ? "~/projects/my-video" : projectPath) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TechSectionLabel(index: "AP", title: "agentpack")
            Text("agentpack keeps one agentpack.toml per project and stages its MCP servers into Claude Code, Codex, Cursor and OpenCode. Add Recorder there once; teammates get it on their next sync.")
                .foregroundStyle(Theme.textSecondaryColor).fixedSize(horizontal: false, vertical: true)
            if cli == nil {
                Text("Neither `agentpack` nor `ap` was found (looked in PATH, Homebrew, ~/.local/bin, ~/.cargo/bin, Nix profiles). Install it from github.com/olegpustovit/agentpack and reopen this pane, or copy the commands below.")
                    .foregroundStyle(Theme.warningColor).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                TextField("~/projects/my-video", text: $projectPath).textFieldStyle(.plain).padding(6)
                    .background(Theme.bgControlColor).overlay(Rectangle().stroke(Theme.strokeColor))
                Button("Choose…", action: choose).buttonStyle(TechButtonStyle(kind: .secondary, compact: true))
                if toml != nil { TechStatus(title: "agentpack.toml", color: Theme.layoutColor) }
            }
            ForEach(Array(steps.enumerated()), id: \.offset) { i, a in
                CopyBlock(caption: "\(i + 1) · " + (a == ["init"] ? "Create agentpack.toml" : a == ["sync"] ? "Stage it for every agent" : "Add Recorder to agentpack.toml"), code: line(a))
            }
            HStack(spacing: 8) {
                Button(running ? "Running…" : steps.count == 1 ? "Sync" : "Run \(steps.count) Steps", action: run)
                    .buttonStyle(TechButtonStyle(kind: .primary)).disabled(running || cli == nil || project == nil)
                CopyBlockButton(title: "Copy as Script", text: ([cdLine] + steps.map(line)).joined(separator: "\n"))
            }
            if !output.isEmpty {
                Text(output).font(Font(Theme.captionFont)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10).background(Theme.bgControlColor)
            }
            Text("Launch an agent in the project").font(Font(Theme.labelFont)).padding(.top, 4)
            ForEach(["claude", "codex", "agent", "opencode"], id: \.self) { a in
                HStack(spacing: 8) {
                    Text("$ \(cdLine) && \(ap) \(a)").font(Font(Theme.captionFont)).foregroundStyle(Theme.textSecondaryColor)
                        .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    CopyBlockButton(title: "Copy", text: "\(cdLine) && \(ap) \(a)")
                    Button("Open in Terminal") { launch(a) }.buttonStyle(TechButtonStyle(kind: .quiet, compact: true)).disabled(project == nil || cli == nil)
                }
            }
            Text("Commit agentpack.toml and pack.lock. Recorder shows as unpinnable in pack.lock: it's a local launcher with no source to hash.")
                .font(Font(Theme.captionFont)).foregroundStyle(Theme.textTertiaryColor).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func choose() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { projectPath = url.path }
    }

    private func run() {
        guard let cli, let project else { return }
        running = true; output = ""
        let steps = steps
        Task {
            var log = ""
            for a in steps {
                let r = try? await AgentClient.run(cli, a, in: project)
                log += "$ \(line(a))\n" + (r?.output ?? "could not run agentpack") + "\n"
                if r?.status != 0 { log += "exit \(r?.status ?? -1)\n"; break }
            }
            output = log.split(separator: "\n", omittingEmptySubsequences: false).suffix(16).joined(separator: "\n")
            running = false
        }
    }

    /// Opens Terminal in the project running `agentpack <agent>` (a .command file needs no Apple Events permission).
    private func launch(_ agent: String) {
        guard let cli, let project else { return }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("recorder-agentpack-\(agent).command")
        try? "#!/bin/zsh\ncd \(AgentConfig.sh(project.path)) && \(AgentConfig.sh(cli)) \(agent)\n".write(to: file, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        NSWorkspace.shared.open(file)
    }
}

private struct CopyBlockButton: View {
    let title: String, text: String
    @State private var copied = false
    var body: some View {
        Button(copied ? "Copied" : title) {
            NSPasteboard.general.clearContents()
            copied = NSPasteboard.general.setString(text, forType: .string)
        }.buttonStyle(TechButtonStyle(kind: .quiet, compact: true))
    }
}
