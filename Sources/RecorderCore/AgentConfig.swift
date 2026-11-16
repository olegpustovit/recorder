import Foundation

/// One MCP client: where its user-level config lives and how a `recorder` entry looks there (SPEC §10.1).
/// Ported from dbman's AgentConfig, user scope only (Recorder projects aren't code folders).
public struct AgentPlatform: Identifiable, Sendable, Equatable {
    public enum Style: Sendable { case plain, typed, claudeCode, zed, opencode, toml }
    public let id: String, name: String
    /// Config path relative to the home folder.
    public let path: String
    /// JSON object holding the servers (unused for TOML, whose table is `[mcp_servers.recorder]`).
    public let key: String
    public let style: Style
    /// Lower-case fragments of `initialize.clientInfo.name` that identify this client.
    public let clients: [String]

    public func url(home: URL) -> URL { home.appendingPathComponent(path) }
    public func matches(client name: String) -> Bool { let n = name.lowercased(); return clients.contains { n.contains($0) } }

    // shortcut: paths/client names from each app's public docs, verified only for Claude Code and Codex; fix an entry when a user reports it.
    public static let all: [AgentPlatform] = [
        .init(id: "claude-code", name: "Claude Code", path: ".claude.json", key: "mcpServers", style: .claudeCode, clients: ["claude-code"]),
        .init(id: "claude-desktop", name: "Claude Desktop", path: "Library/Application Support/Claude/claude_desktop_config.json", key: "mcpServers", style: .plain, clients: ["claude-ai", "claude-desktop"]),
        .init(id: "codex", name: "Codex", path: ".codex/config.toml", key: "", style: .toml, clients: ["codex"]),
        .init(id: "cursor", name: "Cursor", path: ".cursor/mcp.json", key: "mcpServers", style: .plain, clients: ["cursor"]),
        .init(id: "vscode", name: "VS Code (Copilot)", path: "Library/Application Support/Code/User/mcp.json", key: "servers", style: .typed, clients: ["visual studio code", "vscode", "copilot"]),
        .init(id: "opencode", name: "OpenCode", path: ".config/opencode/opencode.json", key: "mcp", style: .opencode, clients: ["opencode"]),
        .init(id: "zed", name: "Zed", path: ".config/zed/settings.json", key: "context_servers", style: .zed, clients: ["zed"]),
        .init(id: "windsurf", name: "Windsurf", path: ".codeium/windsurf/mcp_config.json", key: "mcpServers", style: .plain, clients: ["windsurf", "codeium"]),
    ]
}

public enum AgentStatus: Sendable, Equatable {
    /// The client's config folder doesn't exist (app not installed).
    case notFound
    case notConnected
    case connected
    /// A `recorder` entry points at another Recorder binary (e.g. a source build).
    case needsUpdate(String)
}

public struct AgentConfigError: LocalizedError, Sendable {
    public var errorDescription: String?
}

/// Pure text transforms (unit-tested) plus a guarded file write. Callers pass the home folder.
public enum AgentConfig {
    public static let table = "recorder"
    public static let arguments = ["--mcp"]

    static func entry(_ p: AgentPlatform, command: String) -> [String: Any] {
        switch p.style {
        case .plain, .toml: ["command": command, "args": arguments]
        case .typed: ["type": "stdio", "command": command, "args": arguments]
        case .claudeCode: ["type": "stdio", "command": command, "args": arguments, "env": [String: String]()]
        case .zed: ["source": "custom", "command": command, "args": arguments]
        case .opencode: ["type": "local", "command": [command] + arguments, "enabled": true]
        }
    }

    /// The snippet a user pastes by hand: the client's own file format with only the `recorder` entry.
    public static func snippet(_ p: AgentPlatform, command: String) -> String {
        if p.style == .toml { return tomlBlock(command: command).joined(separator: "\n") + "\n" }
        return (try? json([p.key: [table: entry(p, command: command)]])) ?? ""
    }

    /// Generic `mcpServers` JSON for any other client.
    public static func genericJSON(command: String) -> String { snippet(AgentPlatform.all[1], command: command) }

    /// `claude mcp add` arguments (the CLI owns ~/.claude.json, so Connect prefers it).
    public static func claudeAddArguments(command: String) -> [String] { ["mcp", "add", table, "-s", "user", "--", command] + arguments }

    /// Shell-quotes for zsh/bash/fish when needed.
    public static func sh(_ s: String) -> String {
        s.allSatisfy { $0.isLetter || $0.isNumber || "/._-+=:@~".contains($0) } ? s : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: install / uninstall / status (text in, text out)

    public static func install(_ p: AgentPlatform, into text: String?, command: String) throws -> String {
        if p.style == .toml { try tomlGuard(text ?? ""); return tomlInstall(text ?? "", command: command) }
        var root = try parse(text)
        var servers = root[p.key] as? [String: Any] ?? [:]
        servers[table] = entry(p, command: command)
        root[p.key] = servers
        return try json(root)
    }

    public static func uninstall(_ p: AgentPlatform, from text: String) throws -> String {
        if p.style == .toml { try tomlGuard(text); return tomlRemove(text) }
        var root = try parse(text)
        guard var servers = root[p.key] as? [String: Any], servers.removeValue(forKey: table) != nil else { return text }
        root[p.key] = servers
        return try json(root)
    }

    /// The launcher registered as `recorder`, nil when there is none.
    public static func command(_ p: AgentPlatform, in text: String?) -> String? {
        guard let text else { return nil }
        if p.style == .toml {
            let lines = text.components(separatedBy: "\n")
            guard let r = tomlRange(lines) else { return nil }
            return lines[r].lazy.compactMap { l -> String? in
                let t = l.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix("command"), let a = t.firstIndex(of: "\""), let b = t.lastIndex(of: "\""), a < b else { return nil }
                return String(t[t.index(after: a)..<b]).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
            }.first ?? ""
        }
        guard let servers = (try? parse(text))?[p.key] as? [String: Any], let d = servers[table] as? [String: Any] else { return nil }
        return (d["command"] as? String) ?? (d["command"] as? [String])?.first ?? ""
    }

    public static func status(_ p: AgentPlatform, in text: String?, command: String) -> AgentStatus {
        guard let c = self.command(p, in: text) else { return .notConnected }
        return c == command ? .connected : .needsUpdate(c)
    }

    // MARK: files

    public static func status(_ p: AgentPlatform, home: URL, command: String) -> AgentStatus {
        let u = p.url(home: home)
        let text = try? String(contentsOf: u, encoding: .utf8)
        if text == nil, !FileManager.default.fileExists(atPath: u.deletingLastPathComponent().path) { return .notFound }
        return status(p, in: text, command: command)
    }

    /// Rewrites the client's config with or without the `recorder` entry. Keeps the user's original once as
    /// `<file>.recorder-backup` and writes through a symlink, so a dotfile manager's link stays a link.
    public static func write(_ p: AgentPlatform, home: URL, command: String, remove: Bool = false) throws {
        let u = p.url(home: home), real = u.resolvingSymlinksInPath(), fm = FileManager.default
        let text = try? String(contentsOf: u, encoding: .utf8)
        let after = remove ? try uninstall(p, from: text ?? "") : try install(p, into: text, command: command)
        guard after != text else { return }
        try fm.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        let backup = URL(fileURLWithPath: real.path + ".recorder-backup")
        if text != nil, !fm.fileExists(atPath: backup.path) { try fm.copyItem(at: real, to: backup) }
        try after.write(to: real, atomically: true, encoding: .utf8)
    }

    // MARK: JSON

    static func parse(_ text: String?) throws -> [String: Any] {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        // shortcut: strict JSON only (a config with comments is refused, not rewritten); upgrade to a text-level patch if users hit it.
        guard let d = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw AgentConfigError(errorDescription: "The config isn't plain JSON (comments or a syntax error). Fix it, or copy the snippet below and paste it in yourself.")
        }
        return d
    }

    static func json(_ o: [String: Any]) throws -> String {
        let d = try JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: d, as: UTF8.self)
            .replacingOccurrences(of: #"(?m)^(\s*"(?:[^"\\]|\\.)*") : "#, with: "$1: ", options: .regularExpression)
            .replacingOccurrences(of: #"([\[{])\n\s*\n\s*([\]}])"#, with: "$1$2", options: .regularExpression) + "\n"
    }

    // MARK: TOML (one table, hand-rolled: [mcp_servers.recorder] and its sub-tables)

    static func tomlBlock(command: String) -> [String] {
        ["[mcp_servers.recorder]", "command = \"\(command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\"",
         "args = [\"--mcp\"]", "startup_timeout_sec = 20"]
    }

    /// Lines of the recorder table, up to the next header, trailing blanks excluded. `subtables` also swallows
    /// `[mcp_servers.recorder.*]` (uninstall); an update keeps them so the user's env survives.
    static func tomlRange(_ lines: [String], subtables: Bool = false) -> Range<Int>? {
        let head = "[mcp_servers.recorder]", sub = subtables ? "[mcp_servers.recorder." : "\u{0}"
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == head }) else { return nil }
        var end = start + 1
        while end < lines.count {
            let t = lines[end].trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("["), !t.hasPrefix(sub) { break }
            end += 1
        }
        while end > start + 1, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
        return start..<end
    }

    /// A `recorder` server defined inline or with dotted keys would end up twice (invalid TOML), so refuse.
    /// shortcut: line-based, multi-line inline tables are caught only on their `recorder` line; upgrade with a real TOML parser.
    static func tomlGuard(_ text: String) throws {
        var inServers = false
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#") || t.isEmpty { continue }
            if t.hasPrefix("[") { inServers = t == "[mcp_servers]" }
            let ours = t == "[mcp_servers.recorder]" || t.hasPrefix("[mcp_servers.recorder.")
            let defines = t.hasPrefix("mcp_servers") ? t.contains("recorder")
                : t.hasPrefix("[") ? t.hasPrefix("[mcp_servers.") && t.contains("recorder") && !ours
                : inServers && t.range(of: #"^["']?recorder["']?\s*[.=]"#, options: .regularExpression) != nil
            if defines { throw AgentConfigError(errorDescription: "This config already defines recorder inline or with dotted keys. Edit it by hand, or copy the snippet below.") }
        }
    }

    static func tomlInstall(_ text: String, command: String) -> String {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        if let r = tomlRange(lines) { lines.replaceSubrange(r, with: tomlBlock(command: command)) }
        else {
            if let last = lines.last, !last.trimmingCharacters(in: .whitespaces).isEmpty { lines.append("") }
            lines += tomlBlock(command: command)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func tomlRemove(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard var r = tomlRange(lines, subtables: true) else { return text }
        if r.lowerBound > 0, lines[r.lowerBound - 1].trimmingCharacters(in: .whitespaces).isEmpty { r = (r.lowerBound - 1)..<r.upperBound }
        lines.removeSubrange(r)
        if r.lowerBound == 0, let f = lines.first, f.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        return lines.joined(separator: "\n")
    }
}
