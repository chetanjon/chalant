import SwiftUI

struct ExpandedView: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject var music: MusicController
    @ObservedObject var timer: CountdownController
    @ObservedObject var focus: FocusController

    // Optional. Everything local runs without it. Lives in the Keychain;
    // loaded when the settings pane appears, saved on submit/dismiss.
    @State private var apiKey = ""

    @AppStorage("expandedSizePreset") private var sizePreset = "compact"
    @AppStorage("expandOnHover") private var expandOnHover = true
    @AppStorage("openDelay") private var openDelay = 0.12
    @AppStorage("collapseDelay") private var collapseDelay = 0.05
    @AppStorage("motionFeel") private var motionFeel = "serene"
    @AppStorage("auroraOn") private var auroraOn = true
    @AppStorage("sweepOn") private var sweepOn = true
    @AppStorage("glowOn") private var glowOn = true
    @AppStorage("idleEdgeOn") private var idleEdgeOn = true
    @AppStorage("batteryWingOn") private var batteryWingOn = true
    @AppStorage("accentMode") private var accentMode = "album"

    @Environment(\.moaiAccent) private var accent
    @State private var showSettings = false
    @FocusState private var inputFocused: Bool
    @Namespace private var tabNS

    init(model: NotchViewModel) {
        self.model = model
        self.music = model.music
        self.timer = model.timer
        self.focus = model.focus
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if showSettings {
                settings
                    .transition(.opacity)
            } else {
                if focus.isActive {
                    FocusStrip(focus: focus)
                        .transition(.opacity)
                } else if timer.isActive {
                    timerStrip
                        .transition(.opacity)
                }
                if music.nowPlaying != nil {
                    MusicStrip(music: music)
                        .transition(.opacity)
                }
                tabRow

                Group {
                    switch model.tab {
                    case .ask:
                        answerArea
                        if let context = model.pendingContext {
                            contextChip(context.name)
                        }
                        inputBar
                    case .clipboard:
                        ClipboardView(model: model)
                    case .shelf:
                        ShelfView(model: model)
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 16)
        // Keep content below the physical camera housing.
        .padding(.top, model.notchSize.height + 8)
        .foregroundStyle(.white)
        .animation(Theme.Motion.content, value: model.tab)
        .animation(Theme.Motion.content, value: showSettings)
        // The Bool, never nowPlaying itself: it mutates on every 1s poll.
        .animation(Theme.Motion.content, value: music.nowPlaying != nil)
        .animation(Theme.Motion.content, value: model.pendingContext != nil)
        .onAppear { inputFocused = true }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Moai")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Button {
                model.toggleListening()
            } label: {
                Image(systemName: "mic.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent)
            }
            .buttonStyle(.plain)
            Button {
                withAnimation(Theme.Motion.content) {
                    showSettings.toggle()
                }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(showSettings ? accent : Theme.textTertiary)
            }
            .buttonStyle(.plain)
            Button {
                model.collapse()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
        }
    }

    private var tabRow: some View {
        HStack(spacing: 6) {
            tabButton("Do", .ask)
            tabButton("Clips", .clipboard)
            tabButton("Shelf", .shelf)
            Spacer()
        }
    }

    private func tabButton(_ title: String, _ tab: NotchViewModel.Tab) -> some View {
        Button {
            withAnimation(Theme.Motion.content) {
                model.tab = tab
            }
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(
                    model.tab == tab ? Theme.textPrimary : Theme.textTertiary
                )
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background {
                    if model.tab == tab {
                        Capsule()
                            .fill(Color.white.opacity(0.12))
                            .matchedGeometryEffect(id: "tabPill", in: tabNS)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    private var timerStrip: some View {
        HStack(spacing: 10) {
            Text("Timer \(timer.display)")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Button {
                timer.stop()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .moaiCard()
    }

    private var settings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                settingsSection("Island") {
                    settingRow("Size") {
                        Picker("", selection: $sizePreset) {
                            Text("Compact").tag("compact")
                            Text("Cozy").tag("cozy")
                            Text("Large").tag("large")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(width: 190)
                    }
                    toggleRow("Open on hover", $expandOnHover)
                    toggleRow("Show edge when idle", $idleEdgeOn)
                    toggleRow("Battery in the notch", $batteryWingOn)
                    settingRow("Open") {
                        Picker("", selection: $openDelay) {
                            Text("Instant").tag(0.0)
                            Text("Quick").tag(0.12)
                            Text("Relaxed").tag(0.3)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(width: 190)
                    }
                    settingRow("Close") {
                        Picker("", selection: $collapseDelay) {
                            Text("Instant").tag(0.05)
                            Text("Quick").tag(0.35)
                            Text("Relaxed").tag(0.8)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(width: 190)
                    }
                }
                settingsSection("Life") {
                    settingRow("Feel") {
                        Picker("", selection: $motionFeel) {
                            Text("Still").tag("still")
                            Text("Serene").tag("serene")
                            Text("Balanced").tag("balanced")
                            Text("Lively").tag("lively")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(width: 236)
                    }
                    toggleRow("Aurora in the glass", $auroraOn)
                    toggleRow("Edge light on open", $sweepOn)
                    toggleRow("Glow with music", $glowOn)
                }
                settingsSection("Accent") {
                    HStack(spacing: 10) {
                        accentSwatch("album", music.accent, label: "Album")
                        accentSwatch("silver", Theme.accentFallback, label: "Silver")
                        accentSwatch("blue", Theme.accentBlue, label: "Blue")
                        accentSwatch("mint", Theme.accentMint, label: "Mint")
                        accentSwatch("rose", Theme.accentRose, label: "Rose")
                        Spacer()
                    }
                }
                settingsSection("Claude key") {
                    SecureField("sk-ant-...", text: $apiKey)
                        .onSubmit { KeychainStore.write(apiKey, account: "anthropicKey") }
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
                                .fill(Theme.field)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
                                .strokeBorder(Theme.hairlineFaint, lineWidth: 1)
                        )
                    Text("Optional, for the hard questions. Stays on this Mac.")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.bottom, 8)
        }
        .onAppear { apiKey = KeychainStore.read("anthropicKey") ?? "" }
        .onDisappear { KeychainStore.write(apiKey, account: "anthropicKey") }
    }

    private func settingsSection(
        _ title: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.3)
                .foregroundStyle(Theme.textTertiary)
            content()
        }
    }

    private func settingRow(
        _ label: String,
        @ViewBuilder control: () -> some View
    ) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            control()
        }
    }

    private func toggleRow(_ label: String, _ binding: Binding<Bool>) -> some View {
        settingRow(label) {
            Toggle("", isOn: binding)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.mini)
                .tint(accent)
        }
    }

    private func accentSwatch(_ mode: String, _ color: Color, label: String) -> some View {
        Button {
            accentMode = mode
        } label: {
            VStack(spacing: 5) {
                Circle()
                    .fill(color)
                    .frame(width: 22, height: 22)
                    .overlay(
                        Circle()
                            .strokeBorder(
                                accentMode == mode ? Theme.textPrimary : Color.white.opacity(0.12),
                                lineWidth: accentMode == mode ? 2 : 1
                            )
                    )
                Text(label)
                    .font(.system(size: 9))
                    .foregroundStyle(
                        accentMode == mode ? Theme.textSecondary : Theme.textTertiary
                    )
            }
        }
        .buttonStyle(.plain)
    }

    private var answerArea: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if model.isWorking, model.answer.isEmpty {
                    ThinkingDots()
                        .padding(.top, 4)
                } else if !model.errorText.isEmpty {
                    Text(model.errorText)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.danger)
                } else if model.answer.isEmpty {
                    Text("remind me to call amma at 6. focus 25. timer 10. note: an idea. notes. Or hold the notch and say it.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(model.answer)
                        .font(.system(size: 13))
                        .lineSpacing(3)
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
    }

    private func contextChip(_ name: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "paperclip")
                .font(.system(size: 9, weight: .semibold))
            Text(name)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
            Button {
                model.pendingContext = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(accent)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(accent.opacity(0.12)))
        .overlay(Capsule().strokeBorder(accent.opacity(0.4), lineWidth: 1))
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("What needs doing", text: $model.draftPrompt)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($inputFocused)
                .onSubmit(sendDraft)
            Button(action: sendDraft) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(
                        model.draftPrompt.isEmpty ? Theme.textTertiary : accent
                    )
            }
            .buttonStyle(.plain)
            .disabled(model.draftPrompt.isEmpty || model.isWorking)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
                .fill(Theme.field)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
                .strokeBorder(
                    model.draftPrompt.isEmpty ? Theme.hairlineFaint : accent.opacity(0.5),
                    lineWidth: 1
                )
        )
    }

    private func sendDraft() {
        let text = model.draftPrompt
        model.draftPrompt = ""
        model.submit(text)
    }
}

/// Focus session strip: countdown, cycle, noise picker, end.
struct FocusStrip: View {
    @ObservedObject var focus: FocusController
    @Environment(\.moaiAccent) private var accent

    var body: some View {
        HStack(spacing: 10) {
            Text(focus.phase == .work ? "Focus \(focus.display)" : "Break \(focus.display)")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
            Text("cycle \(focus.cycle)")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
            Spacer()
            noiseButton("B", .brown)
            noiseButton("W", .white)
            noiseButton("P", .pink)
            Button {
                focus.stop()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .moaiCard()
    }

    private func noiseButton(
        _ label: String,
        _ color: NoiseEngine.NoiseColor
    ) -> some View {
        Button {
            focus.setNoise(color)
        } label: {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(
                    focus.noiseColor == color ? accent : Theme.textTertiary
                )
        }
        .buttonStyle(.plain)
    }
}
