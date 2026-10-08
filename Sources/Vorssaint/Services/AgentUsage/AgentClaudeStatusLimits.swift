// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Claude Code hands its plan limits to a status line script it runs, as the
/// percentage used and the renewal time of the 5-hour and 7-day windows. The
/// script this app offers saves just those, with the time it ran, in a small
/// file in the app's folder, and this reads it. It is Claude Code's own
/// documented way to share them: no sign-in, keychain item or token is used,
/// and nothing is sent. The file is only as current as Claude Code's last
/// response, so a reading carries the time it was saved, never a later one.
enum AgentClaudeStatusLimits {
    static let fileName = "claude-rate-limits.json"
    static let scriptName = "claude-statusline.sh"
    private static let maximumSize = 64 << 10

    /// The file in the app's folder; nil outside a real bundle.
    static var fileURL: URL? { PrivateFileStore.containerURL?.appending(path: fileName, directoryHint: .notDirectory) }

    private static let windows: [(key: String, id: String, kind: AgentLimitWindow.Kind, minutes: Int)] = [
        ("five_hour", "claude.fh", .session, 300), ("seven_day", "claude.sd", .weekly, 10_080)]

    struct Reading: Equatable {
        struct Window: Equatable {
            let key: String
            let used: Double
            let resets: Date?
        }
        let date: Date
        let windows: [Window]
    }

    /// What the script saved; nil for a file this reader does not know.
    static func reading(from data: Data) -> Reading? {
        guard data.count <= maximumSize,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (json["version"] as? NSNumber)?.intValue == 1,
              let seconds = (json["t"] as? NSNumber)?.doubleValue, seconds.isFinite, seconds > 0,
              let limits = json["rate_limits"] as? [String: Any] else { return nil }
        var result: [Reading.Window] = []
        for window in windows {
            guard let entry = limits[window.key] as? [String: Any],
                  let number = entry["used_percentage"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite else { continue }
            let resets = (entry["resets_at"] as? NSNumber).flatMap { $0.doubleValue.isFinite && $0.doubleValue > 0 ? Date(timeIntervalSince1970: $0.doubleValue) : nil }
            result.append(Reading.Window(key: window.key, used: min(100, max(0, number.doubleValue)), resets: resets))
        }
        return Reading(date: Date(timeIntervalSince1970: seconds), windows: result)
    }

    /// The reading as limit windows at `now`. A window that renewed since has
    /// spent an unknown amount, and one without a date is not trusted past a
    /// day, as with the Claude app's readings.
    static func limits(from reading: Reading, now: Date) -> AgentLimits? {
        guard reading.date <= now.addingTimeInterval(300) else { return nil }
        var result: [AgentLimitWindow] = []
        for window in reading.windows {
            guard let spec = windows.first(where: { $0.key == window.key }) else { continue }
            if let resets = window.resets, resets <= now { continue }
            if window.resets == nil, now.timeIntervalSince(reading.date) >= 86_400 { continue }
            result.append(AgentLimitWindow(id: spec.id, kind: spec.kind, minutes: spec.minutes, scope: nil,
                                           usedPercent: window.used, resetsAt: window.resets))
        }
        guard !result.isEmpty else { return nil }
        return AgentLimits(provider: .claude, windows: result, observedAt: reading.date, source: .account)
    }

    /// When the script last saved, straight from the file.
    static func lastReceived(at url: URL? = fileURL) -> Date? {
        url.flatMap { try? Data(contentsOf: $0) }.flatMap(reading)?.date
    }

    // MARK: Setup

    /// Runs as Claude Code's status line. Saves only the plan limits, then
    /// hands the same input to a status line of the person's own, when one is
    /// named as the argument.
    static let script = """
    #!/bin/sh
    # Installed by Vorssaint. Claude Code runs this as its status line and
    # passes the session as JSON on stdin. Only the plan limits it reports
    # (percentages used and renewal times) are kept, in a file beside this
    # script that Vorssaint reads. Nothing is sent anywhere.
    # To keep a status line of your own, name it as the argument:
    #   claude-statusline.sh /path/to/your-statusline.sh
    input=$(cat)
    dir=$(cd "$(dirname "$0")" && pwd) || exit 0
    limits=$(printf '%s' "$input" | /usr/bin/plutil -extract rate_limits json -o - - 2>/dev/null)
    if [ -n "$limits" ]; then
      umask 077
      tmp="$dir/.claude-rate-limits.$$"
      printf '{"version":1,"t":%s,"rate_limits":%s}\\n' "$(date +%s)" "$limits" > "$tmp" \\
        && mv -f "$tmp" "$dir/\(fileName)"
    fi
    if [ $# -gt 0 ]; then printf '%s' "$input" | "$@"; fi

    """

    /// Writes the script into `folder`, owner-only and executable, and returns
    /// the lines to add to Claude Code's settings: its `statusLine`. Nil when
    /// the script cannot be written. Only on the person's request.
    static func install(in folder: URL? = PrivateFileStore.containerURL) -> String? {
        guard let folder, PrivateFileStore.createDirectory(at: folder, container: folder) else { return nil }
        let url = folder.appending(path: scriptName, directoryHint: .notDirectory)
        guard PrivateFileStore.write(Data(script.utf8), to: url),
              (try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)) != nil
        else { return nil }
        let command = "'" + url.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let setting: [String: Any] = ["statusLine": ["type": "command", "command": command]]
        guard let data = try? JSONSerialization.data(withJSONObject: setting, options: [.prettyPrinted, .sortedKeys,
                                                                                        .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return nil }
        // The object's members, to merge into settings.json.
        return text.split(separator: "\n").dropFirst().dropLast().map { String($0.dropFirst(2)) }.joined(separator: "\n")
    }
}
