// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// The link to Claude Code's status line: what the settings must hold for it
/// to count as set up, and that the script is kept current without ever
/// touching those settings.
enum AgentClaudeIntegrationTests {
    private static let unrelated = """
    {
      "theme": "dark",
      "model": "opus",
      "enabledPlugins": {"warp@claude-code-warp": true},
      "extraKnownMarketplaces": {"warp": {"source": {"source": "github", "repo": "warpdotdev/claude-code-warp"}}},
      "modelSettings": {"opus": {"effort": "high"}},
      "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "/Users/me/.notchpop/hook.sh Stop"}]}],
                "Notification": [{"hooks": [{"type": "command", "command": "/Users/me/.notchpop/hook.sh Notification"}]}]}
      STATUS
    }
    """

    private static func settings(_ status: String?) -> String {
        unrelated.replacingOccurrences(of: "STATUS", with: status.map { ",\n  \"statusLine\": \($0)" } ?? "")
    }

    static func run(_ suite: TestSuite) {
        let root = FileManager.default.temporaryDirectory.appending(path: "vorss-integration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func fresh(_ name: String) -> (home: URL, folder: URL, script: URL) {
            let home = root.appending(path: name)
            let folder = home.appending(path: "Library/Application Support/com.example.vorssaint")
            try? FileManager.default.createDirectory(at: home.appending(path: ".claude"), withIntermediateDirectories: true)
            return (home, folder, folder.appending(path: AgentClaudeStatusLimits.scriptName))
        }
        func write(_ text: String, home: URL) {
            try? Data(text.utf8).write(to: AgentClaudeIntegration.settingsURL(home: home))
        }
        func bytes(_ home: URL) -> Data? { try? Data(contentsOf: AgentClaudeIntegration.settingsURL(home: home)) }
        let reported = Date().addingTimeInterval(-600)

        // Set up, script current.
        let a = fresh("a")
        _ = AgentClaudeStatusLimits.writeScript(in: a.folder)
        write(settings(#"{"type": "command", "command": "'\#(a.script.path)'"}"#), home: a.home)
        let before = bytes(a.home)
        let connected = AgentClaudeIntegration.inspect(home: a.home, folder: a.folder, received: reported)
        suite.expect(connected == AgentClaudeIntegration.Report(state: .connected, received: reported)
                        && AgentClaudeIntegration.isCurrent(a.script) && bytes(a.home) == before,
                     "settings that run the current script count as connected, and the settings are left as they are")
        let waiting = AgentClaudeIntegration.inspect(home: a.home, folder: a.folder, received: nil)
        suite.expect(waiting.state == .waitingForFirstReport, "set up with no report yet is waiting, not an error")

        // Set up, script missing: put back.
        let b = fresh("b")
        write(settings(#"{"type": "command", "command": "'\#(b.script.path)'"}"#), home: b.home)
        let restored = AgentClaudeIntegration.inspect(home: b.home, folder: b.folder, received: reported)
        suite.expect(restored.state == .connected && AgentClaudeIntegration.isCurrent(b.script),
                     "a missing script is written again when the settings run it")

        // Set up, script old or loose: replaced whole, executable.
        let c = fresh("c")
        try? FileManager.default.createDirectory(at: c.folder, withIntermediateDirectories: true)
        try? Data("#!/bin/sh\n# an older script\n".utf8).write(to: c.script)
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: c.script.path)
        write(settings(#"{"type":"command","command":"\#(c.script.path.replacingOccurrences(of: " ", with: "\\\\ "))"}"#), home: c.home)
        suite.expect(!AgentClaudeIntegration.isCurrent(c.script), "an older script is not current")
        let updated = AgentClaudeIntegration.inspect(home: c.home, folder: c.folder, received: reported)
        let mode = (try? FileManager.default.attributesOfItem(atPath: c.script.path))?[.posixPermissions] as? Int
        suite.expect(updated.state == .connected && AgentClaudeIntegration.isCurrent(c.script) && mode == 0o700,
                     "an outdated script is replaced whole and made executable, with no new setting to paste")

        // Not set up: reported, and nothing written that was not asked for.
        let d = fresh("d")
        write(settings(nil), home: d.home)
        let missing = AgentClaudeIntegration.inspect(home: d.home, folder: d.folder, received: reported)
        suite.expect(missing.state == .setupRequired && !FileManager.default.fileExists(atPath: d.script.path)
                        && bytes(d.home) == Data(settings(nil).utf8),
                     "without a statusLine it is setup required, and the script is not written unasked")
        let other = fresh("other")
        write(settings(#"{"type": "command", "command": "/usr/local/bin/my-status.sh"}"#), home: other.home)
        suite.expect(AgentClaudeIntegration.inspect(home: other.home, folder: other.folder, received: reported).state == .setupRequired,
                     "a status line of another command is not this link")
        let none = fresh("none")
        try? FileManager.default.removeItem(at: AgentClaudeIntegration.settingsURL(home: none.home))
        suite.expect(AgentClaudeIntegration.inspect(home: none.home, folder: none.folder, received: nil).state == .setupRequired,
                     "no settings file is setup required")
        write("{ not json", home: none.home)
        suite.expect(AgentClaudeIntegration.inspect(home: none.home, folder: none.folder, received: nil).state == .setupRequired,
                     "settings that cannot be read are setup required, never a crash")

        // An older script that exists is kept current even before the settings run it.
        let e = fresh("e")
        try? FileManager.default.createDirectory(at: e.folder, withIntermediateDirectories: true)
        try? Data("# old\n".utf8).write(to: e.script)
        write(settings(nil), home: e.home)
        let kept = AgentClaudeIntegration.inspect(home: e.home, folder: e.folder, received: nil)
        suite.expect(kept.state == .setupRequired && AgentClaudeIntegration.isCurrent(e.script) && bytes(e.home) == Data(settings(nil).utf8),
                     "an existing script of this app is brought up to date while the settings stay as they are")

        // Repair writes the script again but never adds the setting.
        let f = fresh("f")
        _ = AgentClaudeStatusLimits.writeScript(in: f.folder)
        try? Data("tampered".utf8).write(to: f.script)
        write(settings(nil), home: f.home)
        let repaired = AgentClaudeIntegration.inspect(home: f.home, folder: f.folder, received: reported, repair: true)
        suite.expect(repaired.state == .setupRequired && AgentClaudeIntegration.isCurrent(f.script)
                        && bytes(f.home) == Data(settings(nil).utf8),
                     "repair puts the script right and reports setup required without adding the setting")
        let g = fresh("g")
        write(settings(#"{"type": "command", "command": "'\#(g.script.path)'"}"#), home: g.home)
        let ownBytes = bytes(g.home)
        let forced = AgentClaudeIntegration.inspect(home: g.home, folder: g.folder, received: reported, repair: true)
        suite.expect(forced.state == .connected && bytes(g.home) == ownBytes,
                     "repair on a set-up link leaves it connected and the settings untouched")

        // Layout, order and quoting do not matter; unrelated entries are never touched.
        let script = URL(fileURLWithPath: "/Users/me/Library/Application Support/com.example.vorssaint/\(AgentClaudeStatusLimits.scriptName)")
        let home = URL(fileURLWithPath: "/Users/me")
        let variants = [
            #"{"statusLine":{"command":"'/Users/me/Library/Application Support/com.example.vorssaint/claude-statusline.sh'","type":"command"}}"#,
            #"{"statusLine":{"type":"command","command":"\"/Users/me/Library/Application Support/com.example.vorssaint/claude-statusline.sh\" /Users/me/mine.sh"}}"#,
            #"{"statusLine":{"type":"command","command":"/Users/me/Library/Application\\ Support/com.example.vorssaint/claude-statusline.sh"}}"#,
            #"{"statusLine":{"type":"command","command":"~/Library/Application\\ Support/com.example.vorssaint/claude-statusline.sh"}}"#,
            #"{"statusLine":{"command":"$HOME/Library/'Application Support'/com.example.vorssaint/claude-statusline.sh"}}"#,
            "{\n    \"statusLine\"   :   {\n  \"type\":\"command\", \"command\":\"'/Users/me/Library/Application Support/com.example.vorssaint/claude-statusline.sh'\"}\n}",
            settings(#"{"type": "command", "command": "'/Users/me/Library/Application Support/com.example.vorssaint/claude-statusline.sh'"}"#),
        ]
        suite.expect(variants.allSatisfy { AgentClaudeIntegration.pointsToScript(Data($0.utf8), script: script, home: home) },
                     "formatting, key order, quoting, ~ and $HOME all read as the same command")
        let wrong = [
            #"{"statusLine":{"type":"command","command":"/Users/me/Library/Application Support/other/claude-statusline.sh"}}"#,
            #"{"statusLine":{"type":"text","command":"/Users/me/Library/Application\\ Support/com.example.vorssaint/claude-statusline.sh"}}"#,
            #"{"statusLine":"claude-statusline.sh"}"#, #"{"statusLine":{"type":"command"}}"#, "{}", "[]",
            settings(nil),
        ]
        suite.expect(!wrong.contains { AgentClaudeIntegration.pointsToScript(Data($0.utf8), script: script, home: home) }
                        && !AgentClaudeIntegration.pointsToScript(nil, script: script, home: home),
                     "another command, another type, a missing entry or no file is not this link")
        suite.expect(AgentClaudeIntegration.firstWord(of: "  'a b'/c\\ d  e") == "a b/c d"
                        && AgentClaudeIntegration.firstWord(of: "'unclosed") == nil && AgentClaudeIntegration.firstWord(of: "   ") == nil,
                     "the first word is read as a shell would, and an unclosed quote reads as none")
        // The copied setting names the script, and what it names reads back as this link.
        let h = fresh("h")
        let setting = AgentClaudeStatusLimits.install(in: h.folder)
        let wrapped = Data(("{" + (setting ?? "") + "}").utf8)
        suite.expect(AgentClaudeIntegration.pointsToScript(wrapped, script: h.script, home: h.home),
                     "the setting the app copies is the one it recognizes as set up")
    }
}
