import SwiftUI

/// The expanded island: a thin composition shell. Header on top, then
/// either an open utility pane (Focus / Settings, sliding in like a
/// drawer) or the content stack — strips, tabs, and the active tab.
struct ExpandedView: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject var music: MusicController
    @ObservedObject var timer: CountdownController
    @ObservedObject var focus: FocusController

    init(model: NotchViewModel) {
        self.model = model
        self.music = model.music
        self.timer = model.timer
        self.focus = model.focus
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HeaderBar(model: model, focus: focus)
                .staggeredReveal(0)

            if model.pane == .none {
                content
                    .transition(.opacity)
            } else {
                Group {
                    switch model.pane {
                    case .focus:
                        FocusPanel(focus: focus, timer: timer)
                    case .settings:
                        SettingsPane(music: music)
                    case .none:
                        EmptyView()
                    }
                }
                .transition(paneTransition)
            }
        }
        .padding(.horizontal, Theme.Space.xxl)
        .padding(.bottom, Theme.Space.xl)
        // Keep content below the physical camera housing.
        .padding(.top, model.notchSize.height + Theme.Space.m)
        .foregroundStyle(.white)
        .animation(Theme.Motion.content, value: model.tab)
        .animation(Theme.Motion.content, value: model.pane)
        // The Bool, never nowPlaying itself: it mutates on every 1s poll.
        .animation(Theme.Motion.content, value: music.nowPlaying != nil)
        .animation(Theme.Motion.content, value: model.pendingContext != nil)
        .onExitCommand {
            withAnimation(Theme.Motion.content) {
                if model.pane != .none {
                    model.pane = .none
                } else {
                    model.collapse()
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if focus.isActive {
            SessionStrip(kind: .focus, focus: focus, timer: timer) {
                withAnimation(Theme.Motion.content) { model.pane = .focus }
            }
            .transition(.opacity)
            .staggeredReveal(1)
        } else if timer.isActive {
            SessionStrip(kind: .timer, focus: focus, timer: timer) {
                withAnimation(Theme.Motion.content) { model.pane = .focus }
            }
            .transition(.opacity)
            .staggeredReveal(1)
        }
        if music.nowPlaying != nil {
            MusicStrip(music: music)
                .transition(.opacity)
                .staggeredReveal(1)
        }
        TabRow(model: model)
            .staggeredReveal(2)

        Group {
            switch model.tab {
            case .ask:
                DoView(model: model)
            case .clipboard:
                ClipboardView(model: model)
            case .shelf:
                ShelfView(model: model)
            case .links:
                ShortcutsView(model: model)
            }
        }
        // A whisper of lateral movement, matched to the pill's slide.
        .transition(
            .asymmetric(
                insertion: .offset(x: 8 * model.tabSlideDirection).combined(with: .opacity),
                removal: .opacity
            )
        )
        .staggeredReveal(3)
    }

    /// A drawer sliding over the content — deliberately different
    /// from the tabs' cross-fade.
    private var paneTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .trailing).combined(with: .opacity)
        )
    }
}
