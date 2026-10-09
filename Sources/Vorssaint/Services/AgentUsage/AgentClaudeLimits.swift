// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Where a reading of Claude's plan limits came from, weakest first.
enum AgentClaudeLimitsSource: Int, Comparable {
    /// The Claude app's history file: percentages, with renewal times guessed.
    case claudeDesktopHistory = 0
    /// What Claude Code's status line received with its last response.
    case statusLine = 1
    /// What Claude Code answered when asked for the plan's usage just now.
    case directClaudeCode = 2

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct AgentClaudeObservation {
    let source: AgentClaudeLimitsSource
    let limits: AgentLimits
}

/// Puts the readings Claude's limits come from into one, window by window, so
/// that a passive report can never take the place of a newer or truer one.
enum AgentClaudeLimitsMerge {
    /// Two renewal times this close are the same window: the status line
    /// rounds to the second and the provider does not.
    static let sameWindow: TimeInterval = 300

    /// A reading at `now`: a window that renewed since has spent an unknown
    /// amount, so it is left out.
    static func placed(_ limits: AgentLimits, at now: Date) -> AgentLimits? {
        let windows = limits.windows.filter { ($0.resetsAt ?? .distantFuture) > now }
        guard !windows.isEmpty else { return nil }
        return AgentLimits(provider: limits.provider, windows: windows, observedAt: limits.observedAt, source: limits.source)
    }

    private struct Choice {
        var window: AgentLimitWindow
        var observedAt: Date
        var source: AgentClaudeLimitsSource
    }

    private static let order = ["claude.fh", "claude.sd", "claude.so", "claude.sn"]

    /// Of two readings of one window, the one to show.
    ///
    /// - Within one renewal period usage only grows, so the higher value is
    ///   the later truth: an older, lower report never takes a newer one's
    ///   place, and a later, higher one moves it on.
    /// - A later renewal time is a newer period: usage may have dropped.
    /// - The Claude app's history guesses its renewal times, so it only
    ///   stands for a window that nothing the provider reported covers, or
    ///   when it is later and no lower.
    private static func better(_ a: Choice, _ b: Choice) -> Choice {
        let estimated = AgentClaudeLimitsSource.claudeDesktopHistory
        if a.source == estimated || b.source == estimated {
            let (guess, exact) = a.source == estimated ? (a, b) : (b, a)
            if a.source == estimated, b.source == estimated { return newer(a, b) }
            return guess.observedAt > exact.observedAt && guess.window.usedPercent >= exact.window.usedPercent ? guess : exact
        }
        if let x = a.window.resetsAt, let y = b.window.resetsAt, abs(x.timeIntervalSince(y)) > sameWindow {
            return x > y ? a : b
        }
        if abs(a.window.usedPercent - b.window.usedPercent) > 0.0001 {
            return a.window.usedPercent > b.window.usedPercent ? a : b
        }
        return newer(a, b)
    }

    private static func newer(_ a: Choice, _ b: Choice) -> Choice {
        if a.observedAt != b.observedAt { return a.observedAt > b.observedAt ? a : b }
        return a.source >= b.source ? a : b
    }

    /// The readings as one. Dated by the oldest of the readings it is made
    /// of, so its age is never better than its weakest part; from the
    /// provider unless only the Claude app's history says anything.
    static func merge(_ observations: [AgentClaudeObservation]) -> AgentLimits? {
        var chosen: [String: Choice] = [:]
        for observation in observations {
            for window in observation.limits.windows {
                let candidate = Choice(window: window, observedAt: observation.limits.observedAt, source: observation.source)
                chosen[window.id] = chosen[window.id].map { better($0, candidate) } ?? candidate
            }
        }
        guard !chosen.isEmpty else { return nil }
        let ordered = chosen.values.sorted {
            (order.firstIndex(of: $0.window.id) ?? order.count) < (order.firstIndex(of: $1.window.id) ?? order.count)
        }
        let allEstimated = ordered.allSatisfy { $0.source == .claudeDesktopHistory }
        return AgentLimits(provider: .claude, windows: ordered.map(\.window),
                           observedAt: ordered.map(\.observedAt).min() ?? .distantPast,
                           source: allEstimated ? .claudeApp : .account)
    }
}
