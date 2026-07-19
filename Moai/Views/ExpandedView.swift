import SwiftUI

/// The island's open form. One rule governs it: Full is Peek grown
/// taller. The three shared rows — session/music, ambience, ask —
/// never move; Full adds tabs and depth *below* them.
struct ExpandedView: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject var music: MusicController
    @ObservedObject var timer: CountdownController
    @ObservedObject var focus: FocusController
    @ObservedObject var ambience: AmbienceController

    init(model: NotchViewModel) {
        self.model = model
        self.music = model.music
        self.timer = model.timer
        self.focus = model.focus
        self.ambience = model.ambience
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            // --- the shared rows: identical in Peek and Full ---
            if focus.isActive || timer.isActive {
                SessionStrip(
                    kind: focus.isActive ? .focus : .timer,
                    focus: focus,
                    timer: timer
                ) {
                    withAnimation(Theme.Motion.content) {
                        model.tab = .focus
                        model.full = true
                    }
                }
                .transition(.opacity)
            }
            if music.nowPlaying != nil {
                MusicRow(music: music)
                    .transition(.opacity)
            }
            AmbienceRow(ambience: ambience)
            AskBar(model: model)

            // --- the growth: tabs and depth, below what you know ---
            if model.full {
                grown
                    .transition(.opacity)
            }

            MoreButton(expanded: model.full) {
                withAnimation(Theme.Motion.content) {
                    model.full.toggle()
                    if !model.full { model.pane = .none }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.top, model.notchSize.height + Theme.Space.m)
        .padding(.bottom, Theme.Space.m)
        .foregroundStyle(.white)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: ExpandedSizeKey.self, value: geo.size)
            }
        )
        .onPreferenceChange(ExpandedSizeKey.self) { size in
            guard size.height > 0 else { return }
            model.expandedSize = size
        }
        .animation(Theme.Motion.content, value: model.tab)
        .animation(Theme.Motion.content, value: model.full)
        .animation(Theme.Motion.content, value: model.pane)
        .animation(Theme.Motion.content, value: music.nowPlaying != nil)
        .animation(Theme.Motion.content, value: ambience.active)
        .animation(Theme.Motion.content, value: model.pendingContext != nil)
        .animation(Theme.Motion.content, value: model.answer.isEmpty)
        .onExitCommand {
            withAnimation(Theme.Motion.content) {
                if model.pane != .none {
                    model.pane = .none
                } else if model.full {
                    model.full = false
                } else {
                    model.collapse()
                }
            }
        }
    }

    @ViewBuilder
    private var grown: some View {
        Rectangle()
            .fill(Theme.hairlineFaint)
            .frame(height: 1)

        if model.pane == .settings {
            HStack(spacing: Theme.Space.xs) {
                HoverGlyphButton(symbol: "chevron.left", tint: Theme.textSecondary) {
                    withAnimation(Theme.Motion.content) { model.pane = .none }
                }
                Text("Settings")
                    .font(Theme.Fonts.title)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
            }
            SettingsPane(music: music)
                .frame(height: 300)
        } else {
            HStack(spacing: Theme.Space.s) {
                TabRow(model: model)
                Spacer()
                HoverGlyphButton(symbol: "gearshape", scale: .s, tint: Theme.textTertiary) {
                    withAnimation(Theme.Motion.content) { model.pane = .settings }
                }
            }

            Group {
                switch model.tab {
                case .ask:
                    AnswerView(model: model)
                case .links:
                    ShortcutsView(model: model)
                        .frame(height: 230)
                case .clipboard:
                    ClipboardView(model: model)
                        .frame(height: 230)
                case .shelf:
                    ShelfView(model: model)
                        .frame(height: 230)
                case .focus:
                    FocusPanel(focus: focus, timer: timer)
                        .frame(height: 190)
                }
            }
            .transition(.opacity)
        }
    }
}

private struct ExpandedSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}
