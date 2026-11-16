import Foundation
import Testing
@testable import RecorderCore

@Suite struct AgentConfigTests {
    let app = "/Applications/Recorder.app/Contents/MacOS/Recorder"
    func platform(_ id: String) -> AgentPlatform { AgentPlatform.all.first { $0.id == id }! }

    @Test func jsonInstallKeepsOtherServersAndReportsStatus() throws {
        let cursor = platform("cursor")
        let before = #"{"mcpServers":{"other":{"command":"x"}},"theme":"dark"}"#
        let after = try AgentConfig.install(cursor, into: before, command: app)
        let root = try JSONSerialization.jsonObject(with: Data(after.utf8)) as! [String: Any]
        let servers = root["mcpServers"] as! [String: Any]
        #expect(servers["other"] != nil && root["theme"] as? String == "dark")
        #expect((servers["recorder"] as? [String: Any])?["args"] as? [String] == ["--mcp"])
        #expect(AgentConfig.status(cursor, in: after, command: app) == .connected)
        #expect(AgentConfig.status(cursor, in: after, command: "/other/Recorder") == .needsUpdate(app))
        #expect(AgentConfig.status(cursor, in: before, command: app) == .notConnected)
        let removed = try AgentConfig.uninstall(cursor, from: after)
        #expect(AgentConfig.status(cursor, in: removed, command: app) == .notConnected)
        #expect(removed.contains("\"other\""))
        #expect(throws: AgentConfigError.self) { try AgentConfig.install(cursor, into: "{ // comment", command: app) }
        // OpenCode keeps the command as an array.
        #expect(AgentConfig.command(platform("opencode"), in: try AgentConfig.install(platform("opencode"), into: nil, command: app)) == app)
    }

    @Test func tomlInstallUpdateAndRemove() throws {
        let codex = platform("codex")
        let before = "model = \"o3\"\n\n[mcp_servers.other]\ncommand = \"x\"\n"
        let once = try AgentConfig.install(codex, into: before, command: "/old/Recorder")
        let twice = try AgentConfig.install(codex, into: once + "\n[mcp_servers.recorder.env]\nA = \"1\"\n", command: app)
        #expect(twice.components(separatedBy: "[mcp_servers.recorder]").count == 2)
        #expect(twice.contains("[mcp_servers.recorder.env]")) // update keeps sub-tables
        #expect(AgentConfig.status(codex, in: twice, command: app) == .connected)
        let removed = try AgentConfig.uninstall(codex, from: twice)
        #expect(!removed.contains("recorder") && removed.hasPrefix("model = \"o3\"") && removed.contains("[mcp_servers.other]"))
        #expect(throws: AgentConfigError.self) { try AgentConfig.install(codex, into: "mcp_servers.recorder.command = \"x\"\n", command: app) }
    }

    @Test func writeBacksUpOnceAndRoundTrips() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agentconfig-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let cursor = platform("cursor"), file = cursor.url(home: home)
        #expect(AgentConfig.status(cursor, home: home, command: app) == .notFound)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"mcpServers":{}}"#.write(to: file, atomically: true, encoding: .utf8)
        try AgentConfig.write(cursor, home: home, command: app)
        #expect(AgentConfig.status(cursor, home: home, command: app) == .connected)
        try AgentConfig.write(cursor, home: home, command: app, remove: true)
        #expect(AgentConfig.status(cursor, home: home, command: app) == .notConnected)
        #expect(try String(contentsOf: URL(fileURLWithPath: file.path + ".recorder-backup"), encoding: .utf8) == #"{"mcpServers":{}}"#)
        #expect(AgentConfig.claudeAddArguments(command: app) == ["mcp", "add", "recorder", "-s", "user", "--", app, "--mcp"])
        #expect(AgentConfig.sh("/a b/Recorder") == "'/a b/Recorder'")
    }
}
