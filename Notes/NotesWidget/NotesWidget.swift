import SwiftUI
import WidgetKit

/// The pinned note on the Lock Screen (and, for free, the Home Screen).
/// Reads the record the app wrote to the App Group; never touches the store.
struct PinnedEntry: TimelineEntry {
    let date: Date
    let pinned: PinStore.Pinned?
}

struct PinnedProvider: TimelineProvider {
    func placeholder(in context: Context) -> PinnedEntry {
        PinnedEntry(date: .now, pinned: PinStore.Pinned(
            id: UUID(), title: "Groceries", preview: "1/4 · eggs, milk, rice", updatedAt: .now))
    }

    func getSnapshot(in context: Context, completion: @escaping (PinnedEntry) -> Void) {
        completion(PinnedEntry(date: .now, pinned: context.isPreview ? placeholder(in: context).pinned : PinStore.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PinnedEntry>) -> Void) {
        completion(Timeline(entries: [PinnedEntry(date: .now, pinned: PinStore.read())], policy: .never))
    }
}

struct NotesWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PinnedEntry

    var body: some View {
        Group {
            switch family {
            case .accessoryInline:
                inline
            case .accessoryRectangular:
                rectangular
            default:
                small
            }
        }
        .widgetURL(entry.pinned?.url)
        .containerBackground(Theme.bg, for: .widget)
    }

    private var inline: some View {
        Group {
            if let pinned = entry.pinned {
                Text(pinned.preview.isEmpty ? pinned.title : "\(pinned.title) · \(pinned.preview)")
            } else {
                Text("Nothing pinned")
            }
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let pinned = entry.pinned {
                Text(pinned.title)
                    .font(.headline)
                    .lineLimit(pinned.preview.isEmpty ? 2 : 1)
                if !pinned.preview.isEmpty {
                    Text(pinned.preview)
                        .font(.subheadline)
                        .lineLimit(1)
                }
            } else {
                Text("Nothing pinned")
                    .font(.headline)
                    .opacity(0.6)
                Text("Long-press a note to pin")
                    .font(.caption)
                    .opacity(0.6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let pinned = entry.pinned {
                Text(pinned.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.fg)
                    .lineLimit(2)
                if !pinned.preview.isEmpty {
                    Text(pinned.preview)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(3)
                }
            } else {
                Text("Nothing pinned")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                Text("Long-press a note to pin")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.faint)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

@main
struct NotesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NotesPinned", provider: PinnedProvider()) { entry in
            NotesWidgetView(entry: entry)
        }
        .configurationDisplayName("Pinned note")
        .description("Shows the note you pinned.")
        .supportedFamilies([.accessoryRectangular, .accessoryInline, .systemSmall])
    }
}

#Preview("Rectangular", as: .accessoryRectangular) {
    NotesWidget()
} timeline: {
    PinnedEntry(date: .now, pinned: PinStore.Pinned(
        id: UUID(), title: "Groceries", preview: "1/4 · eggs, milk, rice", updatedAt: .now))
    PinnedEntry(date: .now, pinned: nil)
}
