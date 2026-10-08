// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Where the link to Claude Code's status line stands. The script is this
/// app's own, kept current by it once the person has set it up or it exists.
/// Claude Code's settings are the person's: they are read, only to see
/// whether `statusLine` runs this script, and never written or logged.
enum AgentClaudeIntegration {
    enum State: Equatable {
        /// `statusLine` does not run this app's script.
        case setupRequired
        /// Set up, and no report has arrived yet.
        case waitingForFirstReport
        /// Set up, and Claude Code has reported.
        case connected
        /// Set up, but the script could not be put right.
        case repairRequired
    }

    struct Report: Equatable {
        let state: State
        /// When Claude Code last reported its limits through the script.
        let received: Date?
    }

    private static let maximumSettingsSize = 2 << 20

    static func settingsURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appending(path: ".claude/settings.json", directoryHint: .notDirectory)
    }

    /// Whether the settings' `statusLine` runs `script`, however the JSON is
    /// laid out, quoted or followed by arguments. Nothing else is looked at.
    static func pointsToScript(_ settings: Data?, script: URL,
                               home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        guard let settings, settings.count <= maximumSettingsSize,
              let json = (try? JSONSerialization.jsonObject(with: settings)) as? [String: Any],
              let line = json["statusLine"] as? [String: Any],
              (line["type"] as? String).map({ $0 == "command" }) ?? true,
              let command = line["command"] as? String, var word = firstWord(of: command) else { return false }
        if word == "~" || word.hasPrefix("~/") { word = home.path + word.dropFirst() }
        for variable in ["${HOME}", "$HOME"] where word.hasPrefix(variable) {
            word = home.path + word.dropFirst(variable.count)
        }
        func normal(_ path: String) -> String {
            URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        }
        return normal(word) == normal(script.path)
    }

    /// The command's first word, with its quotes taken off as a shell would.
    static func firstWord(of command: String) -> String? {
        var word = ""
        var quote: Character?
        var started = false
        var characters = command.makeIterator()
        while let character = characters.next() {
            if let open = quote {
                if character == open { quote = nil }
                else if character == "\\", open == "\"", let next = characters.next() { word.append(next) }
                else { word.append(character) }
            } else if character == "'" || character == "\"" {
                quote = character
                started = true
            } else if character == "\\" {
                if let next = characters.next() { word.append(next) }
                started = true
            } else if character.isWhitespace {
                if started { break }
            } else {
                word.append(character)
                started = true
            }
        }
        return started && quote == nil && !word.isEmpty ? word : nil
    }

    /// The script as this app writes it now, with its permissions.
    static func isCurrent(_ script: URL) -> Bool {
        guard let data = try? Data(contentsOf: script), data == Data(AgentClaudeStatusLimits.script.utf8),
              let permissions = (try? FileManager.default.attributesOfItem(atPath: script.path))?[.posixPermissions] as? Int
        else { return false }
        return permissions == 0o700
    }

    /// Looks at the link and keeps the script current: replaced whole when it
    /// is missing or old, if it already exists or the settings run it, or when
    /// `repair` asks for it. Claude Code's settings are only read. Off the
    /// main thread, at the settings page, on a repair and when the section
    /// starts; never on a timer.
    @discardableResult
    static func inspect(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                        folder: URL? = PrivateFileStore.containerURL,
                        received: Date?, repair: Bool = false) -> Report {
        guard let folder else { return Report(state: .repairRequired, received: received) }
        let script = folder.appending(path: AgentClaudeStatusLimits.scriptName, directoryHint: .notDirectory)
        let configured = pointsToScript(try? Data(contentsOf: settingsURL(home: home)), script: script, home: home)
        var current = isCurrent(script)
        if repair || (!current && (configured || FileManager.default.fileExists(atPath: script.path))) {
            current = AgentClaudeStatusLimits.writeScript(in: folder) != nil
        }
        let outcome: State
        if !configured { outcome = .setupRequired }
        else if !current { outcome = .repairRequired }
        else { outcome = received == nil ? .waitingForFirstReport : .connected }
        return Report(state: outcome, received: received)
    }
}
