// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// The person's refresh runs the service's production methods unchanged
/// against real log and limit files in a temporary home, with the queue run
/// inline. Counters stand in for the three things a refresh must not do:
/// start the price download, restart reading, or read a log from its start.
enum AgentUsageRefreshTests {
    enum NotchAgentSupport {
        static let defaultLimitThreshold = 80.0
        static func limitThreshold() -> Double? { 80 }
    }

    /// Counts what reaches the disk reader, so a log read again from its
    /// start, or a second scan of the folders, shows.
    enum AgentLogReader {
        static var lines = 0
        static var discoveries = 0
        static func discover(_ roots: [AgentLogRoot], since horizon: Date) -> [(path: String, provider: AgentProvider)] {
            discoveries += 1
            return AgentUsageProductionLogReader.discover(roots, since: horizon)
        }
        static func readCopilotHistory(_ cursor: AgentLogCursor, shouldContinue: () -> Bool,
                                       line: (Data) -> Void) {
            AgentUsageProductionLogReader.readCopilotHistory(cursor, shouldContinue: shouldContinue) {
                lines += 1
                line($0)
            }
        }
        static func readAppended(_ cursor: AgentLogCursor, since horizon: Date = .distantPast, shouldContinue: () -> Bool,
                                 including: ((Data, Range<Int>) -> Bool)? = nil, line: (Data) -> Void) {
            AgentUsageProductionLogReader.readAppended(cursor, since: horizon, shouldContinue: shouldContinue,
                                                        including: including) {
                lines += 1
                line($0)
            }
        }
    }

    struct Queue {
        func async(execute work: () -> Void) { work() }
    }

    final class Cancellation {
        var isCancelled = false
    }

    class Fixture {
        static let horizon = TimeInterval(AgentUsageSnapshot.dayCount) * 86_400
        let queue = Queue()
        var home = FileManager.default.temporaryDirectory
        var running = true
        var paused = false
        var isRefreshing = false
        var session = 1
        var readerSession = 1
        var providers: [AgentProvider] = [.claude]
        var enabled: Set<AgentProvider> = [.claude]
        var watchedRoots: [AgentLogRoot] = []
        var readerCancellation: Cancellation? = Cancellation()
        var cursors: [String: AgentLogCursor] = [:]
        var store = AgentUsageStore()
        var claudePlan: AgentPlan?
        var claudeOrganization: String?
        var claudeUnchangedAfterRefresh: Date?
        var lastManualRefreshAt: Date?
        var claudeStatusURL: URL?
        var claudeStatusModified: Date?
        var claudeStatusReading: AgentClaudeStatusLimits.Reading?
        var claudeAppModified: Date?
        var claudeAppSamples: [AgentClaudeAppUsage.Sample] = []
        var previousLimits: [AgentProvider: AgentLimits] = [:]
        var warned: [String: (provider: AgentProvider, window: AgentLimitWindow)] = [:]
        var snapshot = AgentUsageSnapshot()
        var publications: [AgentUsageSnapshot] = []
        var events: [AgentUsageEvent] = []
        var codexChecks = 0
        var planReads = 0
        var priceDownloads = 0
        func checkCodexAccount() { codexChecks += 1 }
        func readClaudePlan() { planReads += 1 }
        func syncPrices() { priceDownloads += 1 }
        func loadPrices() { priceDownloads += 1 }
        func report(_ event: AgentUsageEvent) { events.append(event) }
        func publish() {
            snapshot = store.snapshot(plans: [:], providers: enabled, now: Date())
            publications.append(snapshot)
        }
    }

    // MARK: Fixtures

    private static func assistant(_ id: String, output: Int, stop: String = "end_turn", at time: Date) -> String {
        #"{"type":"assistant","timestamp":\#(time.timeIntervalSince1970),"sessionId":"s","requestId":"r-\#(id)","message":{"id":"m-\#(id)","model":"claude-opus-5-5","stop_reason":"\#(stop)","usage":{"input_tokens":1000,"output_tokens":\#(output)}}}"#
    }

    private static func user(at time: Date) -> String {
        #"{"type":"user","timestamp":\#(time.timeIntervalSince1970),"sessionId":"s","message":{"content":"work"}}"#
    }

    private static func append(_ lines: [String], to file: URL) {
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: file) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file)
        }
    }

    private static func history(_ samples: [(ago: TimeInterval, session: Double, week: Double)], to home: URL,
                                modified: Date) {
        let url = AgentClaudeAppUsage.historyURL(home: home)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let entries = samples.map { sample in
            #"{"t":\#(Int((Date().timeIntervalSince1970 - sample.ago) * 1000)),"u":{"fh":\#(sample.session),"sd":\#(sample.week)}}"#
        }
        try? Data(#"{"version":2,"samples":[\#(entries.joined(separator: ","))]}"#.utf8).write(to: url)
        try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    private static func accounts(_ samples: [(ago: TimeInterval, org: String, session: Double, week: Double)],
                                 to home: URL, modified: Date) {
        let url = AgentClaudeAppUsage.historyURL(home: home)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let entries = samples.map { sample in
            #"{"t":\#(Int((Date().timeIntervalSince1970 - sample.ago) * 1000)),"org":"\#(sample.org)","u":{"fh":\#(sample.session),"sd":\#(sample.week)}}"#
        }
        try? Data(#"{"version":2,"samples":[\#(entries.joined(separator: ","))]}"#.utf8).write(to: url)
        try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    private static func status(_ session: Double?, _ week: Double?, ago: TimeInterval, to url: URL,
                               resetsIn: TimeInterval = 3600, modified: Date? = nil) {
        var limits: [String: Any] = [:]
        let reset = Int(Date().timeIntervalSince1970 + resetsIn)
        if let session { limits["five_hour"] = ["used_percentage": session, "resets_at": reset] }
        if let week { limits["seven_day"] = ["used_percentage": week, "resets_at": reset + 86_400] }
        let body: [String: Any] = ["version": 1, "t": Int(Date().timeIntervalSince1970 - ago), "rate_limits": limits]
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: body).write(to: url)
        if let modified { try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
    }

    private static func warnings(_ host: Fixture) -> Int {
        host.events.filter { if case .limitWarning = $0 { return true } else { return false } }.count
    }

    private static func used(_ host: Fixture) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: (host.store.limits[.claude]?.windows ?? []).map { ($0.id, $0.usedPercent) })
    }

    // MARK: Claude Code's status line

    private static func statusLine(_ suite: TestSuite, folder: URL, drain: () -> Void) {
        let now = Date()
        // What Claude Code documents handing a status line, shaped as it shows.
        let input = #"{"model":{"id":"m"},"session_id":"s","rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":\#(Int(now.timeIntervalSince1970) + 7200)},"seven_day":{"used_percentage":41.2,"resets_at":\#(Int(now.timeIntervalSince1970) + 90_000)}}}"#
        let install = folder.appending(path: "status-install")
        let setting = AgentClaudeStatusLimits.install(in: install)
        let script = install.appending(path: AgentClaudeStatusLimits.scriptName)
        let attributes = try? FileManager.default.attributesOfItem(atPath: script.path)
        suite.expect(setting != nil && (attributes?[.posixPermissions] as? Int) == 0o700
                        && FileManager.default.isExecutableFile(atPath: script.path),
                     "setting up writes a script only its owner can run")
        let wrapped = Data(("{" + (setting ?? "") + "}").utf8)
        let object = (try? JSONSerialization.jsonObject(with: wrapped)) as? [String: Any]
        let line = (object?["statusLine"] as? [String: Any])
        suite.expect(line?["type"] as? String == "command"
                        && (line?["command"] as? String)?.hasPrefix("'") == true
                        && (line?["command"] as? String)?.contains(script.path) == true,
                     "the setting to add is valid JSON naming the script, quoted for a path with spaces")

        func run(_ stdin: String, arguments: [String] = []) -> (status: Int32, output: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [script.path] + arguments
            let inPipe = Pipe(), outPipe = Pipe()
            process.standardInput = inPipe
            process.standardOutput = outPipe
            process.standardError = Pipe()
            do { try process.run() } catch { return (-1, "") }
            inPipe.fileHandleForWriting.write(Data(stdin.utf8))
            try? inPipe.fileHandleForWriting.close()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }
        let data = install.appending(path: AgentClaudeStatusLimits.fileName)
        let first = run(input)
        let saved = (try? Data(contentsOf: data)).flatMap(AgentClaudeStatusLimits.reading)
        suite.expect(first.status == 0 && first.output.isEmpty && saved?.windows.map(\.key) == ["five_hour", "seven_day"]
                        && saved?.windows.map(\.used) == [23.5, 41.2]
                        && abs((saved?.date ?? .distantPast).timeIntervalSinceNow) < 30,
                     "the script saves only the plan limits and when it ran, and prints nothing of its own")
        let raw = String(decoding: (try? Data(contentsOf: data)) ?? Data(), as: UTF8.self)
        suite.expect(!raw.contains("session_id") && !raw.contains("model"),
                     "nothing else of the session's input is kept")
        try? FileManager.default.removeItem(at: data)
        let without = run(#"{"model":{"id":"m"}}"#)
        suite.expect(without.status == 0 && !FileManager.default.fileExists(atPath: data.path),
                     "input without limits, as for an account that has none, saves nothing")
        let chained = install.appending(path: "mine.sh")
        try? Data("#!/bin/sh\ncat | /usr/bin/wc -c | /usr/bin/tr -d ' '\n".utf8).write(to: chained)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: chained.path)
        let passed = run(input, arguments: [chained.path])
        suite.expect(passed.output.trimmingCharacters(in: .whitespacesAndNewlines) == String(input.utf8.count)
                        && FileManager.default.fileExists(atPath: data.path),
                     "a status line named as the argument still gets the whole input, and its output is shown")


        // A refresh with no newer report from Claude Code keeps the report's own date.
        let quiet = folder.appending(path: "status-quiet-file/\(AgentClaudeStatusLimits.fileName)")
        let emptyHome = folder.appending(path: "status-quiet-home")
        status(23, 22, ago: 24 * 60, to: quiet)
        let waiting = Host()
        waiting.home = emptyHome
        waiting.claudeStatusURL = quiet
        waiting.readClaudeApp(now: now)
        let reported = waiting.store.limits[.claude]?.observedAt
        suite.expect(reported != nil && abs(Date().timeIntervalSince(reported ?? Date()) - 24 * 60) < 5,
                     "a report from 24 minutes ago is dated 24 minutes ago")
        waiting.refreshUsage()
        drain()
        suite.expect(waiting.store.limits[.claude]?.observedAt == reported && waiting.snapshot.limits[.claude]?.observedAt == reported
                        && used(waiting) == ["claude.fh": 23, "claude.sd": 22]
                        && waiting.claudeUnchangedAfterRefresh == reported,
                     "refreshing with no newer report leaves its date and values alone and says nothing newer came")
        waiting.refreshUsage()
        drain()
        suite.expect(waiting.store.limits[.claude]?.observedAt == reported && waiting.claudeUnchangedAfterRefresh == reported
                        && waiting.codexChecks == 2,
                     "refreshing again still does not make the report newer, while Codex is asked every time")
        status(25, 23, ago: 5, to: quiet)
        waiting.refreshUsage()
        drain()
        let fresher = waiting.store.limits[.claude]?.observedAt
        suite.expect(used(waiting) == ["claude.fh": 25, "claude.sd": 23] && fresher != reported
                        && abs(Date().timeIntervalSince(fresher ?? .distantPast) - 5) < 5
                        && waiting.claudeUnchangedAfterRefresh == nil,
                     "a newer report brings its values, dates them as reported and clears the note")
        // The ordinary look picks it up too, with no refresh.
        status(26, 24, ago: 1, to: quiet, modified: Date().addingTimeInterval(2))
        waiting.readClaudeApp(now: Date())
        suite.expect(used(waiting) == ["claude.fh": 26, "claude.sd": 24],
                     "the ordinary look notices a newer report without a refresh")


        // The time of the person's refresh is its own: it never stands for a report.
        let stamped = Host()
        stamped.home = emptyHome
        stamped.claudeStatusURL = quiet
        status(40, 41, ago: 3600, to: quiet)
        stamped.readClaudeApp(now: now)
        let reportedThen = stamped.store.limits[.claude]?.observedAt
        suite.expect(stamped.lastManualRefreshAt == nil, "before any refresh there is no refresh time")
        let pressed = Date()
        stamped.refreshUsage()
        suite.expect(stamped.lastManualRefreshAt.map { $0 >= pressed && $0.timeIntervalSince(pressed) < 2 } == true,
                     "pressing refresh sets the refresh time at once")
        drain()
        suite.expect(stamped.store.limits[.claude]?.observedAt == reportedThen
                        && abs(Date().timeIntervalSince(reportedThen ?? Date()) - 3600) < 5,
                     "the report keeps its own time, an hour old, beside the refresh time")
        let refreshedAt = stamped.lastManualRefreshAt
        status(42, 43, ago: 1, to: quiet, modified: Date().addingTimeInterval(3))
        stamped.readClaudeApp(now: Date())
        suite.expect(stamped.lastManualRefreshAt == refreshedAt && used(stamped) == ["claude.fh": 42, "claude.sd": 43]
                        && abs(Date().timeIntervalSince(stamped.store.limits[.claude]?.observedAt ?? .distantPast)) < 5,
                     "a new report moves the received time and leaves the refresh time where it was")
        let pressedAt = refreshedAt ?? now
        let english = Locale(identifier: "en_US")
        let age53 = AgentFormat.age(of: pressedAt, now: pressedAt.addingTimeInterval(53), locale: english)
        let age4 = AgentFormat.age(of: pressedAt, now: pressedAt.addingTimeInterval(240), locale: english)
        let ageNow = AgentFormat.age(of: pressedAt, now: pressedAt, locale: english)
        suite.expect(age53.contains("53") && age4.contains("4") && age4.contains("min") && ageNow.lowercased().contains("now"),
                     "the age reads in seconds, then minutes, as the clock moves on, with no timer of its own (\(ageNow) / \(age53) / \(age4))")

        // The script run again without a new report keeps the report's time.
        func aging(_ seconds: Double) {
            guard var json = (try? JSONSerialization.jsonObject(with: Data(contentsOf: data))) as? [String: Any] else { return }
            json["t"] = Int(Date().timeIntervalSince1970 - seconds)
            try? JSONSerialization.data(withJSONObject: json).write(to: data)
        }
        func savedTime() -> Double? {
            ((try? JSONSerialization.jsonObject(with: Data(contentsOf: data))) as? [String: Any])?["t"] as? Double
        }
        func variant(_ extra: String, spent: Int) -> String {
            #"{"model":{"id":"m"},"session_id":"s","vim":"\#(extra)","cost":{"total_api_duration_ms":\#(spent)},"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":\#(Int(now.timeIntervalSince1970) + 7200)}}}"#
        }
        try? FileManager.default.removeItem(at: data)
        _ = run(variant("a", spent: 1000))
        aging(600)
        let before = savedTime()
        _ = run(variant("b", spent: 1000))
        suite.expect(before != nil && savedTime() == before,
                     "the script run again for another reason, with the same report and no new response, keeps the report's time")
        _ = run(variant("b", spent: 2500))
        suite.expect((savedTime() ?? 0) > (before ?? 0) + 500,
                     "a new response, even with the same percentages, moves the time")
        aging(600)
        let again = savedTime()
        let changed = run(#"{"session_id":"s","cost":{"total_api_duration_ms":2500},"rate_limits":{"five_hour":{"used_percentage":30,"resets_at":\#(Int(now.timeIntervalSince1970) + 7200)}}}"#)
        suite.expect(changed.status == 0 && (savedTime() ?? 0) > (again ?? 0) + 500,
                     "a changed report moves the time")
        let rawAfter = String(decoding: (try? Data(contentsOf: data)) ?? Data(), as: UTF8.self)
        suite.expect(!rawAfter.contains("vim") && !rawAfter.contains("model") && rawAfter.contains("\"mark\""),
                     "only the limits, their time and a change marker are kept")

        // The reader.
        let sample = Data(#"{"version":1,"t":\#(Int(now.timeIntervalSince1970) - 60),"rate_limits":{"five_hour":{"used_percentage":5,"resets_at":\#(Int(now.timeIntervalSince1970) + 600)},"seven_day":{"used_percentage":150,"resets_at":\#(Int(now.timeIntervalSince1970) - 5)}}}"#.utf8)
        let reading = AgentClaudeStatusLimits.reading(from: sample)
        let limits = reading.flatMap { AgentClaudeStatusLimits.limits(from: $0, now: now) }
        suite.expect(limits?.windows.map(\.id) == ["claude.fh"] && limits?.windows.first?.usedPercent == 5
                        && limits?.windows.first?.kind == .session && limits?.windows.first?.minutes == 300
                        && limits?.observedAt == reading?.date && limits?.source == .account
                        && reading?.windows.last?.used == 100,
                     "a window that renewed since is left out, a value is held to 0–100, and the reading is dated when saved")
        suite.expect(AgentClaudeStatusLimits.reading(from: Data("{}".utf8)) == nil
                        && AgentClaudeStatusLimits.reading(from: Data(#"{"version":2,"t":1,"rate_limits":{}}"#.utf8)) == nil
                        && AgentClaudeStatusLimits.reading(from: Data("not json".utf8)) == nil
                        && AgentClaudeStatusLimits.reading(from: Data(#"{"version":1,"t":-1,"rate_limits":{}}"#.utf8)) == nil
                        && reading.flatMap({ AgentClaudeStatusLimits.limits(from: $0, now: now.addingTimeInterval(-3600)) }) == nil,
                     "a file this reader does not know, or dated in the future, gives no limits")

        // Against the Claude app's file: the newer reading is the one shown.
        let home = folder.appending(path: "status-home")
        let url = folder.appending(path: "status-file/\(AgentClaudeStatusLimits.fileName)")
        history([(21 * 3600, 8, 15)], to: home, modified: now.addingTimeInterval(-21 * 3600))
        let host = Host()
        host.home = home
        host.claudeStatusURL = url
        host.readClaudeApp(now: now)
        suite.expect(used(host) == ["claude.sd": 15] && host.store.limits[.claude]?.source == .claudeApp,
                     "without the status line, the Claude app's old reading is what shows")
        status(5, 19, ago: 30, to: url)
        host.refreshUsage()
        drain()
        suite.expect(used(host) == ["claude.fh": 5, "claude.sd": 19] && host.store.limits[.claude]?.source == .account
                        && host.claudeUnchangedAfterRefresh == nil
                        && host.snapshot.limits[.claude]?.windows.map(\.remainingFraction).sorted() == [0.81, 0.95]
                        && Date().timeIntervalSince(host.store.limits[.claude]?.observedAt ?? Date()) >= 29,
                     "Claude Code's newer reading shows its session and week, dated when it was saved, and nothing is reported old")
        history([(21 * 3600, 8, 15), (5, 40, 60)], to: home, modified: now.addingTimeInterval(-3))
        host.refreshUsage()
        drain()
        suite.expect(used(host) == ["claude.fh": 40, "claude.sd": 60] && host.store.limits[.claude]?.source == .claudeApp,
                     "a still newer reading from the Claude app takes over from the older status line one")
        // An unreadable status file keeps what was read; removing it hands back to the Claude app.
        status(7, 21, ago: 1, to: url)
        try? FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        host.refreshUsage()
        drain()
        suite.expect(used(host) == ["claude.fh": 40, "claude.sd": 60],
                     "a status file that cannot be read now changes nothing")
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        host.refreshUsage()
        drain()
        suite.expect(used(host) == ["claude.fh": 7, "claude.sd": 21] && host.store.limits[.claude]?.source == .account,
                     "the next look reads it once it can be")
        try? FileManager.default.removeItem(at: url)
        host.refreshUsage()
        drain()
        suite.expect(used(host) == ["claude.fh": 40, "claude.sd": 60] && host.store.limits[.claude]?.source == .claudeApp,
                     "without the status file the Claude app's reading shows again")
        // Old on both sides: the refresh says so, with the newer of the two dates.
        let aged = folder.appending(path: "status-aged")
        let agedURL = folder.appending(path: "status-aged-file/\(AgentClaudeStatusLimits.fileName)")
        history([(21 * 3600, 8, 15)], to: aged, modified: now.addingTimeInterval(-21 * 3600))
        status(10, 30, ago: 3 * 3600, to: agedURL, resetsIn: 3600)
        let old = Host()
        old.home = aged
        old.claudeStatusURL = agedURL
        old.readClaudeApp(now: now)
        old.refreshUsage()
        drain()
        suite.expect(old.claudeUnchangedAfterRefresh == old.store.limits[.claude]?.observedAt && old.claudeUnchangedAfterRefresh != nil
                        && used(old) == ["claude.fh": 10, "claude.sd": 30],
                     "a status reading hours old is shown with its own date and reported old by a refresh")
        let off = Host()
        off.home = aged
        off.claudeStatusURL = agedURL
        off.enabled = []
        off.readClaudeApp(now: now)
        suite.expect(off.store.limits[.claude] == nil && off.claudeStatusReading == nil,
                     "with Claude off the status file is not read")
    }

    static func run(_ suite: TestSuite) {
        func drain() {
            var reached = false
            DispatchQueue.main.async { reached = true }
            let deadline = Date().addingTimeInterval(1)
            while !reached && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.001)) }
            suite.expect(reached, "the refresh fixture drains its main-queue hand-over")
        }
        let folder = FileManager.default.temporaryDirectory.appending(path: "vorss-refresh-\(UUID().uuidString)")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                   ofItemAtPath: AgentClaudeAppUsage.historyURL(home: folder).path)
            try? FileManager.default.removeItem(at: folder)
        }
        // The folders exist first, so the root is the real path discovery reports.
        let claudeRoot = AgentLogRoot.all(home: folder).first { $0.provider == .claude }!
        try? FileManager.default.createDirectory(at: claudeRoot.url, withIntermediateDirectories: true)
        let root = AgentLogRoot.all(home: folder).first { $0.provider == .claude }!
        let log = root.url.appending(path: "project/session.jsonl")
        let now = Date()
        func established() -> Host {
            let host = Host()
            host.home = folder
            host.watchedRoots = [root]
            host.store.reportsTransitions = true
            host.catchUpLogs()
            host.publish()
            host.publications.removeAll()
            AgentLogReader.lines = 0
            AgentLogReader.discoveries = 0
            return host
        }

        // Usage and spending: what the logs gained since the last look.
        // Kept inside today, so a run just after midnight still totals them as today's.
        let dayStart = Calendar.current.startOfDay(for: now)
        func recent(_ ago: TimeInterval) -> Date { max(dayStart.addingTimeInterval(1), now.addingTimeInterval(-ago)) }
        append([user(at: recent(300)), assistant("a", output: 500, at: recent(290))], to: log)
        let host = established()
        let cursor = host.cursors[log.path]
        let offset = cursor?.offset ?? 0
        append([assistant("b", output: 700, at: recent(60))], to: log)
        let other = root.url.appending(path: "second/other.jsonl")
        append([assistant("c", output: 900, at: recent(30))], to: other)
        host.refreshUsage()
        drain()

        let entries: [(String, Int)] = [("a", 500), ("b", 700), ("c", 900)]
        let expectedCost = entries.reduce(0.0) {
            $0 + (AgentPricing.cost(AgentBillable(tokens: AgentTokens(input: 1000, output: $1.1)),
                                    model: "claude-opus-5-5").cost ?? -1)
        }
        suite.expect(host.store.records.count == 3 && !host.isRefreshing && host.publications.count == 1,
                     "a refresh reads the usage written since the last look, in a log known and a log new, and publishes once")
        suite.expectClose(host.snapshot.usage(.today).total.cost, expectedCost,
                          "spending after a refresh is the sum of every record, priced by the price list in use",
                          tol: 0.000001)
        suite.expect(expectedCost > 0 && host.snapshot.usage(.today).total.tokens.output == 2100,
                     "usage totals include what was known and what was written since")
        suite.expect(host.cursors[log.path] === cursor && cursor?.offset ?? 0 > offset && cursor?.restarted == false,
                     "a known log continues from its cursor, which is neither replaced nor started over")
        suite.expect(AgentLogReader.lines == 2 && AgentLogReader.discoveries == 1,
                     "a refresh hands the parser only the two new lines, never the history before them, after one scan")
        suite.expect(host.priceDownloads == 0 && host.codexChecks == 1 && host.planReads == 1,
                     "a refresh downloads no price list, asks the Codex account once and looks at the plan once")

        // Nothing new: nothing is read, and the same numbers come back.
        AgentLogReader.lines = 0
        let totals = host.snapshot.usage(.today).total
        host.refreshUsage()
        drain()
        suite.expect(AgentLogReader.lines == 0 && host.snapshot.usage(.today).total == totals && host.store.records.count == 3,
                     "a refresh with nothing written reads no line and changes no total")

        // Repeated requests while one is running are one refresh.
        let rapid = established()
        AgentLogReader.lines = 0
        append([assistant("d", output: 100, at: now)], to: log)
        rapid.refreshUsage()
        rapid.refreshUsage()
        rapid.refreshUsage()
        suite.expect(rapid.isRefreshing, "a refresh stays in progress until its snapshot is handed over")
        drain()
        suite.expect(rapid.publications.count == 1 && AgentLogReader.discoveries == 1 && AgentLogReader.lines == 1
                        && rapid.codexChecks == 1 && rapid.planReads == 1 && !rapid.isRefreshing,
                     "three requests in a row scan the folders once, read the new line once, ask Codex once and publish once")
        rapid.refreshUsage()
        drain()
        suite.expect(rapid.publications.count == 2 && rapid.codexChecks == 2,
                     "a request after the last one finished is a refresh of its own")
        let idle = Host()
        idle.running = false
        idle.refreshUsage()
        idle.running = true
        idle.paused = true
        idle.refreshUsage()
        drain()
        suite.expect(!idle.isRefreshing && idle.publications.isEmpty && idle.codexChecks == 0,
                     "no refresh starts while the service is stopped or paused")
        let stopped = established()
        stopped.refreshUsage()
        stopped.session += 1
        stopped.isRefreshing = false
        drain()
        suite.expect(!stopped.isRefreshing, "a refresh finishing after the service restarted leaves the new reading's state alone")

        // Live work: the same turn, with its start, throughout.
        let liveLog = root.url.appending(path: "live/live.jsonl")
        let began = now.addingTimeInterval(-40)
        append([user(at: began), assistant("l1", output: 50, stop: "tool_use", at: began.addingTimeInterval(5))], to: liveLog)
        let live = established()
        let working = live.snapshot.live
        suite.expect(working.count == 1 && live.store.turns.count == 1, "the fixture has one turn working")
        let turns = live.store.turns
        live.refreshUsage()
        drain()
        suite.expect(live.store.turns == turns && live.snapshot.live == working && live.snapshot.live.first?.started == working.first?.started,
                     "a refresh with nothing new leaves the working turn, its start and its progress as they were")
        // The agent keeps writing while a refresh runs: both happen.
        append([assistant("l2", output: 80, stop: "tool_use", at: now)], to: liveLog)
        live.publications.removeAll()
        live.refreshUsage()
        drain()
        suite.expect(live.publications.allSatisfy { $0.live.count == 1 } && !live.publications.isEmpty
                        && live.store.turns.count == 1 && live.snapshot.live.first?.id == working.first?.id
                        && live.snapshot.live.first?.started == working.first?.started
                        && (live.snapshot.live.first?.tokens.output ?? 0) > (working.first?.tokens.output ?? 0),
                     "work that goes on during a refresh is counted once, in the same turn with the same start, never empty or doubled")

        // Limits: the file the Claude app saves, read again on request.
        let limited = Host()
        limited.home = folder
        limited.store.reportsTransitions = true
        history([(300, 5, 10), (120, 10, 20)], to: folder, modified: now.addingTimeInterval(-100))
        limited.readClaudeApp(now: now)
        limited.checkLimits()
        suite.expect(used(limited) == ["claude.fh": 10, "claude.sd": 20], "the fixture starts with a session and a weekly reading")
        history([(300, 5, 10), (120, 10, 20), (10, 40, 55)], to: folder, modified: now.addingTimeInterval(-50))
        limited.refreshUsage()
        drain()
        suite.expect(used(limited) == ["claude.fh": 40, "claude.sd": 55]
                        && limited.snapshot.limits[.claude]?.windows.map(\.usedPercent).sorted() == [40, 55],
                     "a refresh shows the newer session and weekly readings the file now holds")
        suite.expect(warnings(limited) == 0, "a reading below the warning level announces no warning")

        // One source failing: the limits file cannot be read, the logs can.
        let url = AgentClaudeAppUsage.historyURL(home: folder)
        history([(300, 5, 10), (10, 90, 95)], to: folder, modified: now.addingTimeInterval(-40))
        try? FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        let before = used(limited)
        limited.watchedRoots = [root]
        limited.enabled = [.claude]
        append([assistant("e", output: 10, at: now)], to: log)
        let known = limited.store.records.count
        limited.refreshUsage()
        drain()
        suite.expect(used(limited) == before && limited.snapshot.limits[.claude]?.windows.map(\.usedPercent).sorted() == [40, 55],
                     "limits that cannot be read this time keep their last values rather than turning to nothing")
        suite.expect(limited.store.records.count > known && !limited.isRefreshing && limited.running && warnings(limited) == 0,
                     "the logs are still read when the limits cannot be, the spinner ends, the service runs and nothing is announced")
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        limited.refreshUsage()
        drain()
        suite.expect(used(limited) == ["claude.fh": 90, "claude.sd": 95],
                     "the next refresh reads the file once it can be, with no restart")
        suite.expect(warnings(limited) == 2, "crossing the warning level is announced once for each of the two windows")
        history([(300, 5, 10), (10, 90, 95)], to: folder, modified: now.addingTimeInterval(-20))
        for _ in 0..<3 {
            limited.refreshUsage()
            drain()
        }
        suite.expect(warnings(limited) == 2, "refreshing again, even from a file saved again, never repeats a warning already announced")

        // Claude's own file is old: Claude saves a reading only while it polls,
        // which a refresh cannot start. The old reading stays, with its own
        // date, and the refresh says it found it old.
        let oldHome = folder.appending(path: "old-home")
        history([(21 * 3600, 8, 15)], to: oldHome, modified: now.addingTimeInterval(-21 * 3600))
        let old = Host()
        old.home = oldHome
        old.readClaudeApp(now: now)
        let sampleDate = old.claudeAppSamples.last?.date
        let observed = old.store.limits[.claude]?.observedAt
        suite.expect(sampleDate != nil && used(old) == ["claude.sd": 15] && observed == sampleDate,
                     "a day-old reading keeps its week and drops a session that ended long ago")
        old.refreshUsage()
        drain()
        suite.expect(old.claudeUnchangedAfterRefresh == sampleDate && old.store.limits[.claude]?.observedAt == sampleDate
                        && old.snapshot.limits[.claude]?.observedAt == sampleDate && used(old) == ["claude.sd": 15]
                        && !old.isRefreshing,
                     "a refresh that finds the Claude app's reading old keeps its values and its date, and reports it old")
        // Claude polls again and saves a newer reading: the refresh shows it as it dates.
        history([(21 * 3600, 8, 15), (30, 5, 19)], to: oldHome, modified: now.addingTimeInterval(-20))
        old.refreshUsage()
        drain()
        let newer = old.claudeAppSamples.last?.date
        suite.expect(used(old) == ["claude.fh": 5, "claude.sd": 19] && old.claudeUnchangedAfterRefresh == nil
                        && newer != sampleDate && old.store.limits[.claude]?.observedAt == newer
                        && Date().timeIntervalSince(newer ?? Date()) >= 29
                        && old.snapshot.limits[.claude]?.windows.map(\.remainingFraction).sorted() == [0.81, 0.95],
                     "a newer saved reading brings back the session and updates the week, dated when Claude saved it, not when refreshed")
        old.refreshUsage()
        drain()
        suite.expect(old.claudeUnchangedAfterRefresh == newer && old.store.limits[.claude]?.observedAt == newer
                        && old.snapshot.limits[.claude]?.observedAt == newer,
                     "refreshing again with nothing newer keeps the reading's own date and reports that nothing newer came")

        // The ordinary look the service takes every thirty seconds notices a
        // newer reading by itself: no second refresh clears the finding.
        let autoHome = folder.appending(path: "auto-home")
        history([(21 * 3600, 8, 15)], to: autoHome, modified: now.addingTimeInterval(-21 * 3600))
        let auto = Host()
        auto.home = autoHome
        auto.readClaudeApp(now: now)
        auto.refreshUsage()
        drain()
        let foundOld = auto.claudeUnchangedAfterRefresh
        suite.expect(foundOld != nil && AgentClaudeAppUsage.isStillOld(foundOld: foundOld, latest: auto.latestClaudeAppReading())
                        && used(auto) == ["claude.sd": 15],
                     "a refresh that finds the reading old leaves the finding standing for that reading")
        history([(21 * 3600, 8, 15), (20, 5, 19)], to: autoHome, modified: now.addingTimeInterval(-5))
        auto.readClaudeApp(now: Date())
        auto.checkLimits()
        auto.publish()
        suite.expect(!AgentClaudeAppUsage.isStillOld(foundOld: auto.claudeUnchangedAfterRefresh, latest: auto.latestClaudeAppReading())
                        && used(auto) == ["claude.fh": 5, "claude.sd": 19]
                        && auto.snapshot.limits[.claude]?.observedAt == auto.latestClaudeAppReading()
                        && auto.latestClaudeAppReading() != foundOld,
                     "a newer reading clears the finding and shows the new limits dated by their own sample, with no second refresh")
        suite.expect(!AgentClaudeAppUsage.isStillOld(foundOld: nil, latest: nil)
                        && !AgentClaudeAppUsage.isStillOld(foundOld: nil, latest: Date()),
                     "nothing found old means nothing is shown old")

        // Another account's newer reading is not this account's.
        let mixedHome = folder.appending(path: "mixed-home")
        accounts([(21 * 3600, "org-a", 8, 15), (60, "org-b", 70, 60)], to: mixedHome, modified: now.addingTimeInterval(-60))
        let mixed = Host()
        mixed.home = mixedHome
        mixed.claudeOrganization = "org-a"
        mixed.readClaudeApp(now: now)
        mixed.refreshUsage()
        drain()
        suite.expect(used(mixed) == ["claude.sd": 15]
                        && mixed.claudeUnchangedAfterRefresh == mixed.claudeAppSamples.first(where: { $0.organization == "org-a" })?.date
                        && mixed.claudeUnchangedAfterRefresh != nil,
                     "a newer reading of another account never replaces this account's, which is reported old")
        let off = Host()
        off.home = oldHome
        off.enabled = []
        off.refreshUsage()
        drain()
        suite.expect(off.claudeUnchangedAfterRefresh == nil, "with Claude off a refresh reports nothing about it")


        statusLine(suite, folder: folder, drain: drain)
        suite.expect(limited.priceDownloads == 0 && limited.paused == false,
                     "no refresh in any of these downloads a price list")
    }
}
