import SwiftUI

/// Says out loud that dictation cannot hear you.
///
/// **This exists because the failure was silent.** Without Input Monitoring,
/// `CGEvent.tapCreate` succeeds, the app logs that the hotkey installed, and the
/// tap then receives nothing for the life of the process. Holding the key does
/// nothing and the app never says why, which reads as a broken app rather than
/// a switch nobody turned on.
///
/// Law 5 of the design constitution governs the shape: a control appears only
/// when it can do something. When dictation can hear, this is not on screen at
/// all — there is no green tick, because "working" is the expected state and
/// does not need announcing.
struct DictationHearingNotice: View {
    let hearing: Dictation.Hearing

    var body: some View {
        switch hearing {
        case .hearing, .unproven:
            // Nothing to say. `unproven` is the ordinary state right after
            // launch: nobody has touched a modifier key yet, and reporting
            // that as a problem would cry wolf on every cold start.
            EmptyView()

        case .notPermitted:
            notice(
                "Chalant cannot see the key.",
                "macOS has not given it permission to watch the keyboard, so holding "
                    + "Option does nothing. This is the one permission dictation cannot work without."
            )

        case .suspect:
            notice(
                "Chalant does not seem to be hearing the key.",
                "Permission looks granted, but nothing has reached Chalant while you have "
                    + "been using it. This usually means the permission was granted to an older "
                    + "copy of the app. Switching it off and on again in System Settings fixes it."
            )
        }
    }

    private func notice(_ headline: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                // Law 3, one symbol per meaning: this is the app's "something
                // is wrong and you can fix it" glyph.
                Image(systemName: "exclamationmark.triangle")
                    .font(Theme.Fonts.iconThin(.xs))
                Text(headline)
                    .font(Theme.Fonts.body)
            }
            .foregroundStyle(Theme.textPrimary)

            SettingNote(detail)

            Button("Open Input Monitoring settings") {
                InputMonitoringPermission.openSettings()
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .tint(Theme.controlTint)
        }
        .padding(.vertical, Theme.Space.settingsRow)
    }
}
