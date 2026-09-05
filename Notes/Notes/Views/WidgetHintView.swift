import SwiftUI

/// Shown once, the first time a note is pinned. iOS does not let an app add
/// a widget to the Lock Screen; the user does it once, and this says how.
struct WidgetHintView: View {
    @Environment(\.dismiss) private var dismiss

    private let steps = [
        "Lock your iPhone, then press and hold the Lock Screen.",
        "Tap Customize, choose Lock Screen, then tap the widget area under the clock.",
        "Add Notes. Your pinned note shows there from now on.",
    ]

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 24) {
                Text("Add Notes to your Lock Screen")
                    .font(.system(size: 28, weight: .semibold))
                    .tracking(-0.03 * 28)
                    .foregroundStyle(Theme.fg)
                    .padding(.top, 32)
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("\(index + 1)")
                                .font(Theme.Font.rowTitle)
                                .monospacedDigit()
                                .foregroundStyle(Theme.fg)
                            Text(step)
                                .font(Theme.Font.rowBody)
                                .foregroundStyle(Theme.muted)
                        }
                    }
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("Got it")
                        .font(Theme.Font.toolbar)
                        .foregroundStyle(Theme.bg)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Theme.fg, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(PressedButtonStyle())
                .padding(.bottom, 16)
            }
            .padding(.horizontal, Theme.pagePadding)
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Theme.bg)
        .presentationDragIndicator(.visible)
    }
}
