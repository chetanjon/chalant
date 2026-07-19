import ServiceManagement
import SwiftUI

/// Settings in the island's own voice: each section is a quiet card,
/// rows separated by hairlines instead of floating in a bare scroll.
struct SettingsPane: View {
    @ObservedObject var music: MusicController

    // Optional. Everything local runs without them. Live in the Keychain;
    // loaded when the pane appears, saved on submit/dismiss.
    @State private var apiKeys: [AIProvider: String] = [:]
    @State private var launchAtLogin = false

    @AppStorage("expandedSizePreset") private var sizePreset = "compact"
    @AppStorage("expandOnHover") private var expandOnHover = true
    @AppStorage("openDelay") private var openDelay = 0.12
    @AppStorage("collapseDelay") private var collapseDelay = 0.05
    @AppStorage("motionFeel") private var motionFeel = "serene"
    @AppStorage("auroraOn") private var auroraOn = true
    @AppStorage("glowOn") private var glowOn = true
    @AppStorage("idleEdgeOn") private var idleEdgeOn = true
    @AppStorage("batteryWingOn") private var batteryWingOn = true
    @AppStorage("accentMode") private var accentMode = "album"

    @Environment(\.moaiAccent) private var accent

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                section("Island", reveal: 0) {
                    row("Size") {
                        picker($sizePreset, [
                            ("Compact", "compact"), ("Cozy", "cozy"), ("Large", "large"),
                        ])
                    }
                    divider
                    toggleRow("Open on hover", $expandOnHover)
                    divider
                    toggleRow("Show edge when idle", $idleEdgeOn)
                    divider
                    toggleRow("Battery in the notch", $batteryWingOn)
                    divider
                    toggleRow("Start at login", Binding(
                        get: { launchAtLogin },
                        set: { enabled in
                            launchAtLogin = enabled
                            if enabled {
                                try? SMAppService.mainApp.register()
                            } else {
                                try? SMAppService.mainApp.unregister()
                            }
                        }
                    ))
                    divider
                    row("Open") {
                        picker($openDelay, [
                            ("Instant", 0.0), ("Quick", 0.12), ("Relaxed", 0.3),
                        ])
                    }
                    divider
                    row("Close") {
                        picker($collapseDelay, [
                            ("Instant", 0.05), ("Quick", 0.35), ("Relaxed", 0.8),
                        ])
                    }
                }
                section("Life", reveal: 1) {
                    row("Feel") {
                        picker($motionFeel, [
                            ("Still", "still"), ("Serene", "serene"),
                            ("Balanced", "balanced"), ("Lively", "lively"),
                        ], width: 236)
                    }
                    divider
                    toggleRow("Aurora in the glass", $auroraOn)
                    divider
                    toggleRow("Glow with music", $glowOn)
                }
                section("Accent", reveal: 2) {
                    HStack(spacing: Theme.Space.l) {
                        swatch("album", music.accent, label: "Album")
                        swatch("silver", Theme.accentFallback, label: "Silver")
                        swatch("blue", Theme.accentBlue, label: "Blue")
                        swatch("mint", Theme.accentMint, label: "Mint")
                        swatch("rose", Theme.accentRose, label: "Rose")
                        Spacer()
                    }
                }
                section("AI keys", reveal: 3) {
                    ForEach(AIProvider.allCases, id: \.self) { provider in
                        keyField(for: provider)
                        if provider != AIProvider.allCases.last {
                            divider
                        }
                    }
                    Text("Optional, for the hard questions. Pick who answers with the chip next to the Do box. Keys stay on this Mac.")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.textHint)
                }
                footer
            }
            .padding(.bottom, Theme.Space.m)
        }
        .onAppear {
            for provider in AIProvider.allCases {
                apiKeys[provider] = KeychainStore.read(provider.keychainAccount) ?? ""
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
        .onDisappear { saveKeys() }
    }

    private func keyField(for provider: AIProvider) -> some View {
        HStack(spacing: Theme.Space.m) {
            Text(provider.displayName)
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 56, alignment: .leading)
            SecureField(
                provider.keyPlaceholder,
                text: Binding(
                    get: { apiKeys[provider] ?? "" },
                    set: { apiKeys[provider] = $0 }
                )
            )
            .onSubmit { saveKeys() }
            .textFieldStyle(.plain)
            .font(Theme.Fonts.bodyMono)
            .padding(Theme.Space.m)
            .moaiField()
        }
    }

    private func saveKeys() {
        for provider in AIProvider.allCases {
            KeychainStore.write(apiKeys[provider] ?? "", account: provider.keychainAccount)
        }
    }

    // MARK: Building blocks

    private func section(
        _ title: String,
        reveal: Int,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(title.uppercased())
                .font(Theme.Fonts.micro)
                .tracking(1.3)
                .foregroundStyle(Theme.textTertiary)
                .padding(.leading, Theme.Space.xs)
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                content()
            }
            .padding(Theme.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .moaiCard()
        }
        .staggeredReveal(reveal)
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.hairlineFaint)
            .frame(height: 1)
    }

    private func row(
        _ label: String,
        @ViewBuilder control: () -> some View
    ) -> some View {
        HStack {
            Text(label)
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            control()
        }
    }

    private func toggleRow(_ label: String, _ binding: Binding<Bool>) -> some View {
        row(label) {
            Toggle("", isOn: binding)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.mini)
                .tint(accent)
        }
    }

    private func picker<Value: Hashable>(
        _ selection: Binding<Value>,
        _ options: [(String, Value)],
        width: CGFloat = 190
    ) -> some View {
        Picker("", selection: selection) {
            ForEach(options, id: \.1) { option in
                Text(option.0).tag(option.1)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .frame(width: width)
    }

    private func swatch(_ mode: String, _ color: Color, label: String) -> some View {
        SettingsSwatch(
            color: color,
            label: label,
            selected: accentMode == mode
        ) {
            accentMode = mode
        }
    }

    private var footer: some View {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return VStack(alignment: .leading, spacing: 2) {
            Text("Moai\(version.map { " \($0)" } ?? "")")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.textTertiary)
            Text("Motion follows the system Reduce Motion setting.")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.textGhost)
        }
        .padding(.leading, Theme.Space.xs)
        .padding(.top, Theme.Space.xs)
    }
}

/// One accent choice: a swatch that lifts on hover and rings when
/// selected.
private struct SettingsSwatch: View {
    let color: Color
    let label: String
    let selected: Bool
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Circle()
                    .fill(color)
                    .frame(width: 26, height: 26)
                    .overlay(
                        Circle()
                            .strokeBorder(
                                selected ? Theme.textPrimary : Color.white.opacity(0.12),
                                lineWidth: selected ? 2 : 1
                            )
                    )
                    .scaleEffect(hovered && !selected ? 1.08 : 1)
                Text(label)
                    .font(Theme.Fonts.micro)
                    .foregroundStyle(
                        selected ? Theme.textSecondary
                            : hovered ? Theme.textSecondary : Theme.textTertiary
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovered = $0 }
        .animation(Theme.Motion.hover, value: hovered)
    }
}
