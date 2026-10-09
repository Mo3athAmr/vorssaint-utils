// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Why asking Claude Code for the plan's usage gave nothing. Each says only
/// what kind of failure it was.
enum AgentClaudeUsageFailure: Error, Equatable {
    /// Claude Code is not on this Mac.
    case missing
    /// This Claude Code does not answer the request.
    case unsupported
    /// Claude Code is signed out.
    case notSignedIn
    /// It is signed in, but not with a plan that has limits.
    case noPlan
    /// The provider is limiting how often usage can be checked.
    case rateLimited
    case timedOut
    /// It stopped, or never started.
    case unreachable
    /// It answered in words this version does not know.
    case invalidResponse
}

/// What one refresh of the direct reading came to.
enum AgentClaudeDirectOutcome: Equatable {
    case skipped
    case succeeded(Date)
    case failed(AgentClaudeUsageFailure)
}

/// What the app knows of asking Claude Code for limits.
enum AgentClaudeDirectState: Equatable {
    /// Not asked yet in this launch.
    case untried
    case available(Date)
    case missing
    case unsupported
    case noPlan
}

protocol AgentClaudeUsageFetching: AnyObject {
    /// Blocks its caller for up to the client's time: run it on a queue of its own.
    func fetch() -> Result<AgentLimits, AgentClaudeUsageFailure>
}

/// Asks the installed Claude Code for the plan's usage over its own control
/// protocol: a short-lived headless process that is sent one control request
/// and no message, so no model turn happens and no conversation is made.
/// Claude Code signs in as it always does; this app never reads its
/// credentials. The request is not a public, stable interface, so a version
/// that does not answer it simply reads as unsupported.
final class AgentClaudeUsageClient: AgentClaudeUsageFetching {
    /// A cold start has taken a second or two; this leaves room for a slow one.
    static let timeout: TimeInterval = 20
    /// After the provider limits usage checks, none is made for this long.
    static let rateLimitCooldown: TimeInterval = 120
    static let arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json",
                            "--verbose", "--no-session-persistence", "--safe-mode"]

    private let find: () -> URL?
    private let environment: () -> [String: String]
    private let timeout: TimeInterval
    private let now: () -> Date

    init(executable: @escaping () -> URL? = { AgentClaudeUsageClient.executable() },
         environment: @escaping () -> [String: String] = { AgentClaudeUsageClient.environment() },
         timeout: TimeInterval = AgentClaudeUsageClient.timeout, now: @escaping () -> Date = Date.init) {
        self.find = executable
        self.environment = environment
        self.timeout = timeout
        self.now = now
    }

    // MARK: Locating

    static func candidates(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [home.appending(path: ".local/bin/claude"), URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
         URL(fileURLWithPath: "/usr/local/bin/claude"), home.appending(path: ".claude/local/claude"),
         home.appending(path: ".npm-global/bin/claude")]
    }

    static func executable(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        candidates(home: home).first { url in
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && !directory.boolValue
                && FileManager.default.isExecutableFile(atPath: url.path)
        }
    }

    /// The app's own environment with the tool's folder on its PATH, as it
    /// finds its siblings. Nothing is removed: how Claude Code signs in is
    /// the person's configuration. The child is only kept from updating
    /// itself, since this is not a session of the person's.
    static func environment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = base
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
                               base["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"].joined(separator: ":")
        environment["DISABLE_AUTOUPDATER"] = "1"
        return environment
    }

    // MARK: Asking

    func fetch() -> Result<AgentLimits, AgentClaudeUsageFailure> {
        guard let executable = find() else { return .failure(.missing) }
        // A folder of its own that holds nothing, so no project's files are near it.
        let folder = FileManager.default.temporaryDirectory.appending(path: "vorssaint-claude-usage", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        guard let session = AgentClaudeControlSession(executable, arguments: Self.arguments, environment: environment(),
                                                      directory: folder, timeout: timeout) else {
            return .failure(.unreachable)
        }
        defer { session.end() }
        switch session.request("get_usage") {
        case .reply(let reply): return Self.limits(fromReply: reply, observed: now())
        case .timedOut: return .failure(.timedOut)
        case .ended: return .failure(.unreachable)
        }
    }

    // MARK: Reading the answer

    private static let windows: [(key: String, id: String, kind: AgentLimitWindow.Kind, scope: String?)] = [
        ("five_hour", "claude.fh", .session, nil), ("seven_day", "claude.sd", .weekly, nil),
        ("seven_day_opus", "claude.so", .weekly, "Opus"), ("seven_day_sonnet", "claude.sn", .weekly, "Sonnet")]

    /// A control response: its success holds the usage, its error says why not.
    static func limits(fromReply reply: [String: Any], observed: Date) -> Result<AgentLimits, AgentClaudeUsageFailure> {
        guard let response = reply["response"] as? [String: Any], let subtype = response["subtype"] as? String else {
            return .failure(.invalidResponse)
        }
        guard subtype == "success" else {
            guard subtype == "error" else { return .failure(.invalidResponse) }
            return .failure(failure(forError: response["error"] as? String ?? ""))
        }
        guard let body = response["response"] as? [String: Any], let available = body["rate_limits_available"] as? Bool else {
            return .failure(.invalidResponse)
        }
        guard available else { return .failure(.noPlan) }
        guard let rates = body["rate_limits"] as? [String: Any] else { return .failure(.invalidResponse) }
        var result: [AgentLimitWindow] = []
        var provided = false
        for window in windows {
            guard let entry = rates[window.key] as? [String: Any] else { continue }
            provided = true
            guard let number = entry["utilization"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite else { continue }
            result.append(AgentLimitWindow(id: window.id, kind: window.kind, minutes: window.kind == .session ? 300 : 10_080,
                                           scope: window.scope, usedPercent: min(100, max(0, number.doubleValue)),
                                           resetsAt: (entry["resets_at"] as? String).flatMap(date)))
        }
        // A plan with limits reports at least its session or its week.
        guard provided, !result.isEmpty else { return .failure(.invalidResponse) }
        return .success(AgentLimits(provider: .claude, windows: result, observedAt: observed, source: .account))
    }

    private static func failure(forError text: String) -> AgentClaudeUsageFailure {
        let lowered = text.lowercased()
        if lowered.contains("429") || lowered.contains("rate limit") || lowered.contains("rate-limit") || lowered.contains("throttl") {
            return .rateLimited
        }
        if lowered.contains("unsupported") || lowered.contains("unknown") || lowered.contains("not supported")
            || lowered.contains("unrecognized") { return .unsupported }
        if lowered.contains("login") || lowered.contains("logged in") || lowered.contains("log in")
            || lowered.contains("sign in") || lowered.contains("signed in") || lowered.contains("auth") || lowered.contains("401") {
            return .notSignedIn
        }
        return .invalidResponse
    }

    /// The provider's renewal times carry microseconds and an offset.
    static func date(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let whole = ISO8601DateFormatter()
        if let date = whole.date(from: text) { return date }
        // Digits beyond the milliseconds, or none, for formatters that insist.
        guard let dot = text.firstIndex(of: ".") else { return nil }
        let rest = text[text.index(after: dot)...]
        let digits = rest.prefix { $0.isNumber }
        let tail = rest.dropFirst(digits.count)
        return whole.date(from: String(text[..<dot]) + tail)
    }
}

/// One conversation with a Claude Code process over its stream-json control
/// protocol: a JSON message a line. Every answer waits on one deadline, so a
/// process that stalls costs the time given at most. Blocks its caller: run it
/// on a queue of its own.
final class AgentClaudeControlSession {
    enum Outcome {
        case reply([String: Any])
        case timedOut
        case ended
    }

    /// Far above any answer here; a process that writes more is not one.
    private static let maximumBuffer = 4 << 20

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let deadline: DispatchTime
    private let arrived = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var buffer = Data()
    private var closed = false

    init?(_ executable: URL, arguments: [String], environment: [String: String], directory: URL, timeout: TimeInterval) {
        deadline = .now() + timeout
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // A process that exits early fails a write instead of ending the app.
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else { return nil }
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil }
            self?.receive(chunk)
        }
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            return nil
        }
    }

    /// Sends one control request and waits for its response, whatever else
    /// the process writes meanwhile.
    func request(_ subtype: String) -> Outcome {
        let id = "vorssaint-" + UUID().uuidString
        let message: [String: Any] = ["type": "control_request", "request_id": id, "request": ["subtype": subtype]]
        guard var line = try? JSONSerialization.data(withJSONObject: message, options: .withoutEscapingSlashes) else { return .ended }
        line.append(0x0A)
        do { try input.fileHandleForWriting.write(contentsOf: line) } catch { return .ended }
        while true {
            switch next() {
            case .reply(let message):
                guard message["type"] as? String == "control_response",
                      (message["response"] as? [String: Any])?["request_id"] as? String == id else { continue }
                return .reply(message)
            case let other: return other
            }
        }
    }

    /// Closing its input ends the process; one that lingers is stopped.
    func end() {
        try? input.fileHandleForWriting.close()
        output.fileHandleForReading.readabilityHandler = nil
        let child = process
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            guard child.isRunning else { return }
            child.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
        }
    }

    private func receive(_ chunk: Data) {
        lock.withLock {
            if chunk.isEmpty || buffer.count + chunk.count > Self.maximumBuffer { closed = true }
            else { buffer.append(chunk) }
        }
        arrived.signal()
    }

    /// The next message, however the output was split into chunks.
    private func next() -> Outcome {
        while true {
            let (line, ended): (Data?, Bool) = lock.withLock {
                guard let newline = buffer.firstIndex(of: 0x0A) else { return (nil, closed) }
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                return (line, false)
            }
            if let line {
                if let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] { return .reply(message) }
                continue
            }
            if ended { return .ended }
            if arrived.wait(timeout: deadline) == .timedOut { return .timedOut }
        }
    }
}
