import SwiftUI
import WidgetKit

// Read-only Lock Screen status, built exactly like DewPoint's 1x1 temperature widget,
// the one Lock Screen widget that renders on iOS 27 beta 4 with sideloaded builds:
// static configuration, cached data only (no network in the timeline), no buttons,
// no accessory background. Tapping it opens the app.
struct ExhaleLockEntry: TimelineEntry {
    var date: Date
    var snap: Snapshot?
    var icon: String { snap?.isOn == true ? "fan.fill" : "aqi.medium" }
    var short: String { AQ.value(snap?.pm25) }
    var title: String { snap?.name ?? "Air purifier" }
    var headline: String { snap == nil ? "Open Exhale" : "PM2.5 \(AQ.value(snap?.pm25))" }
    var detail: String { snap.map { "\(AQ.label($0.pm25)) · \($0.isOn ? "On" : "Off")" } ?? "" }
    static func make() -> ExhaleLockEntry { .init(date: .now, snap: Cache.snapshot) }
}

struct ExhaleLockProvider: TimelineProvider {
    func placeholder(in context: Context) -> ExhaleLockEntry { ExhaleLockEntry.make() }
    func getSnapshot(in context: Context, completion: @escaping (ExhaleLockEntry) -> Void) { completion(ExhaleLockEntry.make()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ExhaleLockEntry>) -> Void) {
        completion(Timeline(entries: [ExhaleLockEntry.make()], policy: .after(.now.addingTimeInterval(900))))
    }
}

struct ExhaleLockWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ExhaleLockStatusV1", provider: ExhaleLockProvider()) { entry in
            ExhaleLockView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Air quality status")
        .description("PM2.5 and purifier power. Tap to open Exhale.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular])
    }
}

struct ExhaleLockView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ExhaleLockEntry

    var body: some View {
        Group {
            if family == .accessoryCircular {
                VStack(spacing: 1) {
                    Image(systemName: entry.icon)
                        .font(.system(size: 16, weight: .semibold))
                    Text(entry.short)
                        .font(.system(size: 11, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: entry.icon)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.title).font(.caption2).lineLimit(1)
                        Text(entry.headline).font(.headline).lineLimit(1).minimumScaleFactor(0.7)
                        if !entry.detail.isEmpty {
                            Text(entry.detail).font(.caption2).lineLimit(1)
                        }
                    }
                }
            }
        }
    }
}
