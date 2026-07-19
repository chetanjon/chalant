import ServiceManagement
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
    @AppStorage("glowOn") private var glowOn = true
    @AppStorage("idleEdgeOn") private var idleEdgeOn = true
    @AppStorage("batteryWingOn") private var batteryWingOn = true
    @AppStorage("accentMode") private var accentMode = "album"

    @Environment(\.moaiAccent) private var accent
    @State private var showSettings = false
    @State private var showFocus = false
    @State private var launchAtLogin = false
    @FocusState private var inputFocused: Bool
    @Namespace private var tabNS

    init(model: NotchViewModel) {
        self.model = model
        self.music = model.music
        self.timer = model.timer
        self.focus = model.focus
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            header

            if showSettings {
                settings
                    .transition(.opacity)
            } else if showFocus {
                FocusPanel(focus: focus)
                    .transition(.opacity)
            } else {
                if focus.isActive {
                    FocusStrip(focus: focus)
                        .onTapGesture {
                            withAnimation(Theme.Motion.content) { showFocus = true }
                        }
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
                    case .links:
                        ShortcutsView(model: model)
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, Theme.Space.xxl)
        .padding(.bottom, Theme.Space.xl)
        // Keep content below the physical camera housing.
        .padding(.top, model.notchSize.height + Theme.Space.m)
        .foregroundStyle(.white)
        .animation(Theme.Motion.content, value: model.tab)
        .animation(Theme.Motion.content, value: showSettings)
        .animation(Theme.Motion.content, value: showFocus)
        // The Bool, never nowPlaying itself: it mutates on every 1s poll.
        .animation(Theme.Motion.content, value: music.nowPlaying != nil)
        .animation(Theme.Motion.content, value: model.pendingContext != nil)
        .onAppear { inputFocused = true }
    }

    private var header: some View {
        HStack(spacing: Theme.Space.xs) {
            Text("Moai")
                .font(Theme.Fonts.title)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            HoverGlyphButton(symbol: "mic.fill", tint: accent) {
                model.toggleListening()
            }
            HoverGlyphButton(
                symbol: "timer",
                tint: showFocus || focus.isActive ? accent : Theme.textTertiary
            ) {
                withAnimation(Theme.Motion.content) {
                    showFocus.toggle()
                    if showFocus { showSettings = false }
                }
            }
            HoverGlyphButton(
                symbol: "gearshape",
                tint: showSettings ? accent : Theme.textTertiary
            ) {
                withAnimation(Theme.Motion.content) {
                    showSettings.toggle()
                    if showSettings { showFocus = false }
                }
            }
            CloseButton {
                model.collapse()
            }
        }
    }

    private var tabRow: some View {
        HStack(spacing: Theme.Space.s) {
            tabButton("Do", .ask)
            tabButton("Go", .links)
            tabButton("Clips", .clipboard)
            tabButton("Shelf", .shelf)
            Spacer()
        }
    }

    private func tabButton(_ title: String, _ tab: NotchViewModel.Tab) -> some View {
        TabPill(
            title: title,
            selected: model.tab == tab,
            namespace: tabNS
        ) {
            withAnimation(Theme.Motion.content) {
                model.tab = tab
            }
        }
    }

    private var timerStrip: some View {
        HStack(spacing: Theme.Space.m) {
            Text("Timer \(timer.display)")
                .font(Theme.Fonts.bodyEmphasisMono)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            CloseButton {
                timer.stop()
            }
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.xs)
        .moaiCard()
    }

    private var settings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
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
                        .font(Theme.Fonts.bodyMono)
                        .padding(Theme.Space.m)
                        .moaiField()
                    Text("Optional, for the hard questions. Stays on this Mac.")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.textHint)
                }
            }
            .padding(.bottom, Theme.Space.m)
        }
        .onAppear {
            apiKey = KeychainStore.read("anthropicKey") ?? ""
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
        .onDisappear { KeychainStore.write(apiKey, account: "anthropicKey") }
    }

    private func settingsSection(
        _ title: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(title.uppercased())
                .font(Theme.Fonts.micro)
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
                .font(Theme.Fonts.body)
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
                    .font(Theme.Fonts.micro)
                    .foregroundStyle(
                        accentMode == mode ? Theme.textSecondary : Theme.textTertiary
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }

    private var answerArea: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if model.isWorking, model.answer.isEmpty {
                    ThinkingDots()
                        .padding(.top, Theme.Space.xs)
                } else if !model.errorText.isEmpty {
                    Text(model.errorText)
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Theme.danger)
                } else if model.answer.isEmpty {
                    Text("remind me to call amma at 6. focus 25. timer 10. note: an idea. notes. Or hold the notch and say it.")
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Theme.textHint)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(model.answer)
                        .font(Theme.Fonts.reading)
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
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "paperclip")
                .font(Theme.Fonts.icon(.xs))
            Text(name)
                .font(Theme.Fonts.caption)
                .lineLimit(1)
            // Tight capsule: a 22pt frame would balloon the chip, so
            // this stays a bare glyph by design.
            Button {
                model.pendingContext = nil
            } label: {
                Image(systemName: "xmark")
                    .font(Theme.Fonts.icon(.xs, weight: .bold))
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
        }
        .foregroundStyle(accent)
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.xs)
        .background(Capsule().fill(accent.opacity(0.12)))
        .overlay(Capsule().strokeBorder(accent.opacity(0.4), lineWidth: 1))
    }

    private var inputBar: some View {
        HStack(spacing: Theme.Space.m) {
            TextField("What needs doing", text: $model.draftPrompt)
                .textFieldStyle(.plain)
                .font(Theme.Fonts.reading)
                .focused($inputFocused)
                .onSubmit(sendDraft)
            Button(action: sendDraft) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(Theme.Fonts.icon(.xl))
                    .foregroundStyle(
                        model.draftPrompt.isEmpty ? Theme.textTertiary : accent
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(PressableStyle())
            .disabled(model.draftPrompt.isEmpty || model.isWorking)
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
        .moaiField(active: !model.draftPrompt.isEmpty)
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
        HStack(spacing: Theme.Space.m) {
            Text(focus.phase == .work ? "Focus \(focus.display)" : "Break \(focus.display)")
                .font(Theme.Fonts.bodyEmphasisMono)
                .foregroundStyle(Theme.textPrimary)
            Text("cycle \(focus.cycle)")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.textHint)
            Spacer()
            ForEach(NoiseEngine.NoiseColor.allCases, id: \.self) { color in
                NoiseButton(
                    color: color,
                    selected: focus.noiseColor == color,
                    compact: true
                ) {
                    focus.setNoise(color)
                }
            }
            CloseButton {
                focus.stop()
            }
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.xs)
        .moaiCard()
    }
}

/// One tab in the sliding-pill row. Inactive tabs answer hover with
/// a tint lift and a ghost of the pill.
struct TabPill: View {
    let title: String
    let selected: Bool
    let namespace: Namespace.ID
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Fonts.label)
                .foregroundStyle(
                    selected ? Theme.textPrimary
                        : hovered ? Theme.textSecondary : Theme.textTertiary
                )
                .padding(.horizontal, Theme.Space.wingInset)
                .padding(.vertical, 5)
                .background {
                    if selected {
                        Capsule()
                            .fill(Color.white.opacity(0.12))
                            .matchedGeometryEffect(id: "tabPill", in: namespace)
                    } else if hovered {
                        Capsule()
                            .fill(Color.white.opacity(0.05))
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovered = $0 }
        .animation(Theme.Motion.hover, value: hovered)
    }
}
