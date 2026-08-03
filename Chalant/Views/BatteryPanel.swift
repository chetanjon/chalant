import SwiftUI

/// What's actually worth knowing about the battery, not the
/// percentage the collapsed glance already shows (`NotchRootView
/// .batteryGlance`): how long it has left, whether it's plugged in,
/// and its health over time. Time to empty or full is the one number
/// worth a whole panel for; cycle count and condition are a quieter
/// second tier below it, shown only when actually known.
struct BatteryPanel: View {
    let battery: SystemStatsController.Battery
    @ObservedObject var stats: SystemStatsController
    @Environment(\.chalantAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            SectionHeader(title: "Battery")
            headline
            if let line = Self.timeLine(for: battery) {
                Text(line)
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.textSecondary)
            }
            plugRow
            if let health = stats.batteryHealth, let line = Self.healthLine(health) {
                Rectangle()
                    .fill(Theme.hairlineFaint)
                    .frame(height: 1)
                    .padding(.vertical, Theme.Space.xs)
                Text(line)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 0)
        }
        // Fetched here rather than on `SystemStatsController`'s own
        // 60-second timer: it reads a heavier IOKit service than the
        // charge/state snapshot that timer already polls, and cycle
        // count and condition don't move fast enough to justify
        // asking for them when nobody's even looking.
        .onAppear { stats.refreshBatteryHealth() }
    }

    private var headline: some View {
        let low = battery.level <= 20 && battery.state != .charging
        let iconTint: Color = battery.state == .charging ? accent
            : low ? Theme.danger : Theme.textSecondary
        return HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Image(systemName: symbolName)
                .font(Theme.Fonts.icon(.l))
                .foregroundStyle(iconTint)
            Text("\(battery.level)%")
                .font(Theme.Fonts.display)
                .foregroundStyle(Theme.textPrimary)
            Text(Self.stateLabel(battery.state))
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var plugRow: some View {
        HStack(spacing: Theme.Space.snug) {
            Image(systemName: battery.pluggedIn ? "powerplug.fill" : "powerplug")
                .font(Theme.Fonts.icon(.xs))
            Text(battery.pluggedIn ? "Plugged in" : "Running on battery")
                .font(Theme.Fonts.caption)
        }
        .foregroundStyle(Theme.textTertiary)
    }

    private var symbolName: String {
        if battery.state == .charging { return "bolt.fill" }
        return battery.level <= 20 ? "battery.25" : "battery.100"
    }

    private static func stateLabel(_ state: SystemStatsController.Battery.State) -> String {
        switch state {
        case .charging: return "Charging"
        case .discharging: return "On battery"
        case .full: return "Fully charged"
        case .notCharging: return "Not charging"
        }
    }

    /// The one number this panel exists for. macOS reports -1 for a
    /// few seconds after any plug or unplug while it works out the
    /// real figure; showing that as "-1 min", or letting it read as
    /// zero, would be a lie the menu bar doesn't tell. Pure and
    /// hoisted out of the view body so the two things that can be
    /// quietly wrong here, the duration format and the not-yet-known
    /// case, are one function away from a test (see
    /// ChalantTests.swift).
    static func timeLine(for battery: SystemStatsController.Battery) -> String? {
        guard let minutes = battery.minutesRemaining else { return nil }
        if minutes < 0 {
            return battery.state == .charging
                ? "Still working out when it'll be full"
                : "Still working out how long that'll last"
        }
        let clock = FocusStatsStore.clock(minutes)
        return battery.state == .charging ? "Full in \(clock)" : "\(clock) left"
    }

    /// Cycle count and condition together, whichever are actually
    /// known; nil when neither is, rather than a row that says
    /// nothing.
    static func healthLine(_ health: SystemStatsController.Health) -> String? {
        var parts: [String] = []
        if let cycles = health.cycleCount {
            parts.append(cycles == 1 ? "1 cycle" : "\(cycles) cycles")
        }
        if let condition = health.condition {
            parts.append(condition)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
