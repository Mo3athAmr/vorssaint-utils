// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

/// The AI page's options, under its row in the Dynamic Island settings.
struct NotchAgentsSettingsControls: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var usage = AgentUsageService.shared
    @AppStorage(DefaultsKey.notchAgentsClaude) private var claude = true
    @AppStorage(DefaultsKey.notchAgentsCodex) private var codex = true
    @AppStorage(DefaultsKey.notchAgentsOpenCode) private var opencode = true
    @AppStorage(DefaultsKey.notchAgentsCopilot) private var copilot = true
    @AppStorage(DefaultsKey.notchAgentsCardOrder) private var cardOrder = ""
    @AppStorage(DefaultsKey.notchAgentsHiddenCards) private var hiddenCards = ""
    @AppStorage(DefaultsKey.notchAgentsLimitDisplay) private var limitDisplay = NotchAgentLimitDisplay.remaining.rawValue
    @AppStorage(DefaultsKey.notchAgentsLimitFocus) private var limitFocus = NotchAgentLimitFocus.mostUsed.rawValue
    @AppStorage(DefaultsKey.notchAgentsLiveActivity) private var liveActivity = true
    @AppStorage(DefaultsKey.notchAgentsReadout) private var readout = NotchAgentReadout.elapsed.rawValue
    @AppStorage(DefaultsKey.notchAgentsFinishAlert) private var finishAlert = true
    @AppStorage(DefaultsKey.notchAgentsFinishMinimum) private var finishMinimum = NotchAgentSupport.defaultFinishMinimum
    @AppStorage(DefaultsKey.notchAgentsLimitAlert) private var limitAlert = true
    @AppStorage(DefaultsKey.notchAgentsLimitThreshold) private var limitThreshold = NotchAgentSupport.defaultLimitThreshold
    @AppStorage(DefaultsKey.notchAgentsDailyBudget) private var dailyBudget = 0.0
    @AppStorage(DefaultsKey.notchAgentsPriceUpdates) private var priceUpdates = true
    @State private var dragging: NotchAgentCard?
    @State private var roots: [AgentProvider: Bool] = [:]
    /// Read from the file while the section is off and the service is idle.
    @State private var claudeAppFileCheck: Date?
    /// When Claude Code's status line last saved its limits; nil if it never has.
    @State private var statusLineReceived: Date?
    @State private var statusLineCopied = false
    /// What the link to Claude Code's status line looked like when last checked.
    @State private var integration: AgentClaudeIntegration.Report?

    private var text: NotchAgentStrings { FeatureStrings.notchAgents(l10n.language) }
    private var locale: Locale { l10n.language.formattingLocale() }

    private var orderedCards: [NotchAgentCard] {
        let stored = cardOrder.split(separator: ",").compactMap { NotchAgentCard(rawValue: String($0)) }
        var seen = Set<NotchAgentCard>()
        return (stored + NotchAgentCard.allCases).filter { seen.insert($0).inserted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(text.settingsDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            providerRow(.claude, isOn: $claude)
            providerRow(.codex, isOn: $codex)
            providerRow(.opencode, isOn: $opencode)
            providerRow(.copilot, isOn: $copilot)

            Divider()
            Text(text.cardsTitle).font(.subheadline.weight(.medium))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                ForEach(orderedCards) { card in
                    PanelReorderableItem(item: card,
                                         order: Binding(get: { orderedCards },
                                                        set: { cardOrder = $0.map(\.rawValue).joined(separator: ",") }),
                                         dragging: $dragging) {
                        NotchEditorItem(symbol: card.symbol, title: text.card(card), included: cardBinding(card)) {
                            cardBinding(card).wrappedValue.toggle()
                        }
                        .accessibilityAction(named: FeatureStrings.clipboard(l10n.language).moveUp) { moveCard(card, by: -1) }
                        .accessibilityAction(named: FeatureStrings.clipboard(l10n.language).moveDown) { moveCard(card, by: 1) }
                    }
                }
            }
            Text(text.cardsHint).font(.caption).foregroundStyle(.secondary)
            // The one card that makes Codex ask the account, said where it is chosen.
            if codex, cardBinding(.resets).wrappedValue {
                Text(text.resetsHelp).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SettingsChoiceRow(symbol: NotchAgentCard.limits.symbol, title: text.limitsAs, selection: $limitDisplay) {
                Text(text.remaining).tag(NotchAgentLimitDisplay.remaining.rawValue)
                Text(text.used).tag(NotchAgentLimitDisplay.used.rawValue)
            }
            // The resting island shows this allowance whatever the live
            // reading, and the live reading uses it when it shows a limit.
            SettingsMenuRow(symbol: "rectangle.topthird.inset.filled", title: text.limitFocus, selection: $limitFocus) {
                ForEach(NotchAgentLimitFocus.allCases) { focus in
                    Text(text.limitFocus(focus)).tag(focus.rawValue)
                }
            }

            Divider()
            Text(text.liveTitle).font(.subheadline.weight(.medium))
            switchRow("waveform.path.ecg", text.liveActivity, isOn: $liveActivity)
            if liveActivity {
                SettingsMenuRow(symbol: "camera.metering.center.weighted", title: text.readout, selection: $readout) {
                    ForEach(NotchAgentReadout.allCases) { option in
                        Text(text.readout(option)).tag(option.rawValue)
                    }
                }
                .padding(.leading, settingsRowTextInset)
                NotchAgentStripSample(readout: NotchAgentReadout(rawValue: readout) ?? .elapsed,
                                      display: NotchAgentLimitDisplay(rawValue: limitDisplay) ?? .remaining,
                                      focus: NotchAgentLimitFocus(rawValue: limitFocus) ?? .mostUsed,
                                      provider: claude ? .claude : codex ? .codex : opencode ? .opencode : .copilot)
                    .padding(.leading, settingsRowTextInset)
            }

            Divider()
            Text(text.alerts).font(.subheadline.weight(.medium))
            switchRow("checkmark.circle", text.finishAlert, isOn: $finishAlert)
            if finishAlert {
                SettingsMenuRow(symbol: "timer", title: text.finishAfter, selection: $finishMinimum) {
                    ForEach(NotchAgentSupport.finishMinimums, id: \.self) { seconds in
                        Text(seconds == 0 ? text.anyLength : AgentFormat.duration(seconds, locale: locale, style: .short))
                            .tag(seconds)
                    }
                }
                .padding(.leading, settingsRowTextInset)
            }
            switchRow("exclamationmark.triangle", text.limitAlert, isOn: $limitAlert)
            if limitAlert {
                SettingsMenuRow(symbol: "gauge.with.dots.needle.67percent", title: text.limitAt, selection: $limitThreshold) {
                    ForEach(NotchAgentSupport.limitThresholds, id: \.self) { value in
                        Text(text.usedShare(AgentFormat.percent(value / 100))).tag(value)
                    }
                }
                .padding(.leading, settingsRowTextInset)
            }
            SettingsMenuRow(symbol: "dollarsign.circle", title: text.budget, selection: $dailyBudget) {
                ForEach(NotchAgentSupport.budgets, id: \.self) { value in
                    Text(value == 0 ? text.off : AgentFormat.cost(value)).tag(value)
                }
            }
            Text(text.valueNote).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SettingsRow(symbol: "arrow.triangle.2.circlepath", title: text.priceUpdates, caption: priceCaption) {
                Toggle(text.priceUpdates, isOn: $priceUpdates).labelsHidden().toggleStyle(.switch)
            }

            if claude {
                Divider()
                Text(text.integrationTitle).font(.subheadline.weight(.medium))
                // Ages move on the page's own clock, only while it is open.
                TimelineView(.periodic(from: .now, by: 10)) { context in
                    claudeIntegration(now: context.date)
                }
            }
        }
        .toggleStyle(.switch)
        .onAppear {
            findRoots()
            // An agent turned off is not read at all, not even for its status.
            if claude { refreshIntegration() }
        }
        .onChange(of: claude) { _, on in if on { refreshIntegration() } }
        // Back from adding the setting to Claude Code's file.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if claude { refreshIntegration() }
        }
        // Cards and agents set the page's height, and the live reading the
        // closed island's width, which the island follows.
        .onChange(of: [cardOrder, hiddenCards, String(claude), String(codex), String(opencode), String(copilot),
                       String(liveActivity), readout, limitDisplay, limitFocus]) { _, _ in
            NotchService.shared.syncWithPreferences()
        }
    }

    private var priceCaption: String {
        guard let day = usage.pricesUpdated else { return text.priceUpdatesHint }
        return text.priceUpdatesHint + " " + text.pricesFrom(AgentFormat.day(day, locale: locale))
    }

    /// The state shown: a first report that arrives while the page is open
    /// ends the wait without another look at the settings.
    private var integrationState: AgentClaudeIntegration.State? {
        guard let state = integration?.state else { return nil }
        let received = usage.claudeReported ?? statusLineReceived
        return state == .waitingForFirstReport && received != nil ? .connected : state
    }

    /// Where the link to Claude Code stands. Its status line is where the
    /// limits come from; the Claude app's history only stands in for it.
    @ViewBuilder private func claudeIntegration(now: Date) -> some View {
        let received = usage.claudeReported ?? statusLineReceived
        let fallback = usage.claudeAppChecked ?? claudeAppFileCheck
        VStack(alignment: .leading, spacing: 6) {
            if let state = integrationState {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: state == .connected || state == .waitingForFirstReport
                          ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(state == .connected || state == .waitingForFirstReport ? Color.green : Color.orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(integrationTitle(state)).font(.callout.weight(.medium))
                        Text(integrationDetail(state)).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if state == .setupRequired {
                        Button(text.statusLineCopy) { copyStatusLineSetup() }
                    } else {
                        Button(text.integrationRepair) { repairIntegration() }
                    }
                }
                if state == .connected || state == .waitingForFirstReport {
                    VStack(alignment: .leading, spacing: 2) {
                        if let received {
                            Text(text.statusLineReceived(AgentFormat.age(of: received, now: now, locale: locale)))
                                .help(text.statusLineHelp)
                        }
                        Text(text.lastRefresh(usage.lastManualRefreshAt.map { AgentFormat.age(of: $0, now: now, locale: locale) } ?? "–"))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            if let fallback {
                Text(text.fallback(AgentFormat.age(of: fallback, now: now, locale: locale)))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func integrationTitle(_ state: AgentClaudeIntegration.State) -> String {
        switch state {
        case .connected, .waitingForFirstReport: return text.integrationConnected
        case .setupRequired: return text.integrationSetupRequired
        case .repairRequired: return text.integrationRepairNeeded
        }
    }

    private func integrationDetail(_ state: AgentClaudeIntegration.State) -> String {
        switch state {
        case .connected: return text.integrationConnectedDetail
        case .waitingForFirstReport: return text.integrationWaitingDetail
        case .setupRequired: return statusLineCopied ? text.statusLineCopied : text.statusLineHint
        case .repairRequired: return text.integrationRepairNeededDetail
        }
    }

    /// Looks at the link again: the script is brought up to date when it is
    /// in use, and Claude Code's settings are only read. Off the main thread.
    private func refreshIntegration(repair: Bool = false) {
        DispatchQueue.global(qos: .utility).async {
            let received = AgentClaudeStatusLimits.lastReceived()
            let report = AgentClaudeIntegration.inspect(received: received, repair: repair)
            let checked = AgentClaudeAppUsage.lastCheck()
            DispatchQueue.main.async {
                statusLineReceived = received
                claudeAppFileCheck = checked
                integration = report
            }
        }
    }

    /// Writes the script again and checks the settings; it never adds the
    /// setting itself, so a link that is not set up says so.
    private func repairIntegration() { refreshIntegration(repair: true) }

    /// Writes the script and puts the setting on the clipboard, off the main thread.
    private func copyStatusLineSetup() {
        DispatchQueue.global(qos: .userInitiated).async {
            let setting = AgentClaudeStatusLimits.install()
            DispatchQueue.main.async {
                guard let setting else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(setting, forType: .string)
                statusLineCopied = true
            }
        }
    }

    /// Laid out like every other row, with the agent's own mark for an icon.
    private func providerRow(_ provider: AgentProvider, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            NotchAgentMark(provider: provider, size: 13)
                .frame(width: 26, height: 26)
                .background(provider.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                Text(roots[provider] == true ? text.found : text.notFound)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            // One agent stays on; turning the section off stops all.
            Toggle(provider.displayName, isOn: isOn).labelsHidden().toggleStyle(.switch)
                .disabled(isOn.wrappedValue && [claude, codex, opencode, copilot].filter { $0 }.count <= 1)
        }
    }

    /// Where the logs live is checked when the page opens, not on every draw.
    private func findRoots() {
        let found = AgentLogRoot.all().filter(\.exists).map(\.provider)
        roots = Dictionary(uniqueKeysWithValues: AgentProvider.allCases.map { ($0, found.contains($0)) })
    }

    private func switchRow(_ symbol: String, _ title: String, isOn: Binding<Bool>) -> some View {
        SettingsRow(symbol: symbol, title: title) {
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch)
        }
    }

    private func cardBinding(_ card: NotchAgentCard) -> Binding<Bool> {
        Binding {
            !hiddenCards.split(separator: ",").contains(Substring(card.rawValue))
        } set: { shown in
            var hidden = Set(hiddenCards.split(separator: ",").map(String.init))
            if shown { hidden.remove(card.rawValue) } else { hidden.insert(card.rawValue) }
            hiddenCards = hidden.sorted().joined(separator: ",")
        }
    }

    /// VoiceOver's way to reorder the cards, which otherwise only drag.
    private func moveCard(_ card: NotchAgentCard, by offset: Int) {
        var order = orderedCards
        guard let index = order.firstIndex(of: card), order.indices.contains(index + offset) else { return }
        order.swapAt(index, index + offset)
        cardOrder = order.map(\.rawValue).joined(separator: ",")
    }
}

extension NotchAgentCard: PanelOrderItem {}

/// The closed island while an agent works, drawn small beside its option:
/// the mark on one side of the camera and the chosen reading on the other.
/// A turn in progress shows its own numbers; otherwise an example does.
private struct NotchAgentStripSample: View {
    let readout: NotchAgentReadout
    let display: NotchAgentLimitDisplay
    let focus: NotchAgentLimitFocus
    let provider: AgentProvider
    @ObservedObject private var usage = AgentUsageService.shared
    private static let camera: CGFloat = 64

    var body: some View {
        NotchAgentReadoutTimeline(readout: readout) { date in
            let working = usage.snapshot.live.first?.provider ?? provider
            HStack(spacing: 0) {
                NotchAgentGlyph(provider: working, size: 11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: Self.camera)
                Text(reading(at: date))
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(working.tint)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .frame(width: Self.camera + 116, height: 24)
            .background(NotchShape(attached: true, radius: 9).fill(.black))
            .environment(\.colorScheme, .dark)
        }
        .accessibilityHidden(true)
    }

    private func reading(at now: Date) -> String {
        var snapshot = usage.snapshot
        if snapshot.live.isEmpty {
            snapshot.live = [AgentLiveSession(id: "example", provider: provider, started: now.addingTimeInterval(-754),
                                              lastActivity: now, model: "", project: "",
                                              tokens: AgentTokens(input: 1_180_000, cacheWrite: 0, cacheRead: 0, output: 20_000),
                                              cost: 4.56)]
        }
        return NotchAgentSupport.stripReading(snapshot, readout: readout, display: display, focus: focus, now: now)
    }
}
