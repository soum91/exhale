import WidgetKit
import SwiftUI
import AppIntents

struct AirEntry: TimelineEntry {
    let date: Date
    let snapshot: Snapshot?
    let segments: [[ChartPoint]]
    let start: Date
    let end: Date
    let signedIn: Bool
    let shared: Bool

    var top: Double {
        let peak = segments.flatMap { $0 }.map(\.value).max() ?? 0
        return PlotMapper.niceTop(for: peak, minimum: 20)
    }

    static func make(_ snap: Snapshot?, hours: Double = 12) -> AirEntry {
        let end = Date()
        let start = end.addingTimeInterval(-hours * 3600)
        let segs = History.series(History.load(), from: start, to: end, step: 15 * 60)
        return AirEntry(date: end, snapshot: snap, segments: segs, start: start, end: end,
                        signedIn: TokenStore.load() != nil, shared: AppGroup.isShared)
    }

    static var preview: AirEntry {
        let end = Date(), start = end.addingTimeInterval(-12 * 3600)
        let vals: [Double] = [6, 5, 7, 12, 22, 18, 11, 8, 6, 5, 4, 6, 9, 7, 5, 4, 4, 5, 6, 5]
        let pts = vals.enumerated().map { i, v in
            ChartPoint(date: start.addingTimeInterval(Double(i) / Double(vals.count - 1) * 12 * 3600), value: v)
        }
        return AirEntry(date: end, snapshot: .preview, segments: [pts], start: start, end: end, signedIn: true, shared: true)
    }
}

struct AirProvider: TimelineProvider {
    func placeholder(in context: Context) -> AirEntry { .preview }

    func getSnapshot(in context: Context, completion: @escaping (AirEntry) -> Void) {
        if context.isPreview && Cache.snapshot == nil { completion(.preview); return }
        completion(.make(Cache.snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AirEntry>) -> Void) {
        Task {
            await PurifierSync.refresh()
            let entry = AirEntry.make(Cache.snapshot)
            // WidgetKit treats this as a hint; real cadence is roughly every 15-30 min.
            completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
        }
    }
}

// MARK: - Views

struct PowerButton: View {
    let snap: Snapshot
    var body: some View {
        if snap.hasPower {
            Button(intent: TogglePurifierIntent()) {
                Image(systemName: "power")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(snap.isOn ? Color.black : Color.white.opacity(0.7))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(snap.isOn ? Color.white : Color.white.opacity(0.14)))
            }
            .buttonStyle(.plain)
        }
    }
}

struct PMBlock: View {
    let snap: Snapshot
    var big: CGFloat = 46
    var body: some View {
        let band = snap.pm25.map(AQBand.of)
        VStack(alignment: .leading, spacing: 2) {
            Text("PM2.5")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(AQ.value(snap.pm25))
                    .font(.system(size: big, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.6)
                Text("µg/m³")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
            HStack(spacing: 5) {
                Circle().fill(band?.color ?? .gray).frame(width: 7, height: 7)
                Text(band?.label ?? "No data")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(band?.color ?? .gray)
                    .lineLimit(1)
            }
        }
    }
}

struct WidgetBackground: View {
    let pm: Double?
    let on: Bool
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.07, green: 0.09, blue: 0.12), Color(red: 0.03, green: 0.04, blue: 0.06)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [AQ.color(pm).opacity(on ? 0.35 : 0.12), .clear],
                           center: .topLeading, startRadius: 5, endRadius: 220)
        }
    }
}

struct EmptyState: View {
    let entry: AirEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "aqi.medium").font(.title2).foregroundStyle(.white.opacity(0.7))
            Spacer()
            Text(!entry.shared ? "Widget can't read app data. Reinstall with App Groups on." :
                    entry.signedIn ? "Pick your purifier in Exhale." : "Open Exhale to sign in.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

struct SmallView: View {
    let entry: AirEntry
    var body: some View {
        if let s = entry.snapshot {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    Text(s.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    PowerButton(snap: s)
                }
                Spacer(minLength: 0)
                PMBlock(snap: s, big: 42)
                if !s.online {
                    Text("Offline").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                } else if let sp = s.speed, s.isOn {
                    Label("Fan \(sp)", systemImage: "fan")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.top, 2)
                }
            }
        } else {
            EmptyState(entry: entry)
        }
    }
}

struct MediumView: View {
    let entry: AirEntry
    var body: some View {
        if let s = entry.snapshot {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top) {
                        Text(s.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        PowerButton(snap: s)
                    }
                    Spacer(minLength: 0)
                    PMBlock(snap: s, big: 40)
                }
                .frame(width: 128)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Last 12 h").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
                        Spacer()
                        Text(s.updated, style: .time).font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                    }
                    ZStack {
                        if entry.segments.isEmpty {
                            Text("Graph fills in as readings come in")
                                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                                .multilineTextAlignment(.center)
                        } else {
                            AirCurve(segments: entry.segments, start: entry.start, end: entry.end, top: entry.top, lineWidth: 2)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    HStack {
                        Text(entry.start, format: .dateTime.hour())
                        Spacer()
                        Text("Now")
                    }
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                }
            }
        } else {
            EmptyState(entry: entry)
        }
    }
}

struct LargeView: View {
    let entry: AirEntry
    var body: some View {
        if let s = entry.snapshot {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    Text(s.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                    Spacer()
                    PowerButton(snap: s)
                }
                PMBlock(snap: s, big: 54)
                Text("Last 12 hours").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
                GeometryReader { geo in
                    ZStack(alignment: .topLeading) {
                        ForEach(gridLines, id: \.self) { v in
                            let y = PlotMapper(start: entry.start, end: entry.end, top: entry.top, size: geo.size).y(v)
                            Path { p in p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: geo.size.width, y: y)) }
                                .stroke(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                            Text(Fmt.num(v)).font(.system(size: 9)).foregroundStyle(.white.opacity(0.35))
                                .position(x: geo.size.width - 8, y: y - 7)
                        }
                        AirCurve(segments: entry.segments, start: entry.start, end: entry.end, top: entry.top)
                    }
                }
                HStack {
                    Text(entry.start, format: .dateTime.hour())
                    Spacer()
                    Text(entry.start.addingTimeInterval(6 * 3600), format: .dateTime.hour())
                    Spacer()
                    Text("Now")
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
            }
        } else {
            EmptyState(entry: entry)
        }
    }

    private var gridLines: [Double] {
        [9, 35.4, 55.4, 125.4].filter { $0 < entry.top }
    }
}

struct CircularView: View {
    let entry: AirEntry
    var body: some View {
        let pm = entry.snapshot?.pm25
        Gauge(value: min(pm ?? 0, 100), in: 0...100) {
            Text("PM")
        } currentValueLabel: {
            Text(AQ.value(pm))
        }
        .gaugeStyle(.accessoryCircular)
    }
}

struct RectangularView: View {
    let entry: AirEntry
    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                Text("PM2.5").font(.system(size: 11, weight: .semibold)).opacity(0.7)
                Text(AQ.value(entry.snapshot?.pm25)).font(.system(size: 22, weight: .semibold, design: .rounded))
                Text(AQ.label(entry.snapshot?.pm25)).font(.system(size: 11)).lineLimit(1)
            }
            if !entry.segments.isEmpty {
                CurveShape(segments: entry.segments, start: entry.start, end: entry.end, top: entry.top, filled: false)
                    .stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .widgetAccentable()
            }
        }
    }
}

struct ExhaleWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: AirEntry

    var body: some View {
        Group {
            switch family {
            case .systemSmall: SmallView(entry: entry)
            case .systemMedium: MediumView(entry: entry)
            case .systemLarge: LargeView(entry: entry)
            case .accessoryCircular: CircularView(entry: entry)
            case .accessoryRectangular: RectangularView(entry: entry)
            case .accessoryInline:
                Text("PM2.5 \(AQ.value(entry.snapshot?.pm25)) · \(AQ.label(entry.snapshot?.pm25))")
            default: SmallView(entry: entry)
            }
        }
        .containerBackground(for: .widget) {
            if family == .systemSmall || family == .systemMedium || family == .systemLarge {
                WidgetBackground(pm: entry.snapshot?.pm25, on: entry.snapshot?.isOn ?? false)
            } else {
                Color.clear
            }
        }
        .widgetURL(URL(string: "exhale://open"))
    }
}

struct ExhaleWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ExhaleAir", provider: AirProvider()) { entry in
            ExhaleWidgetView(entry: entry)
        }
        .configurationDisplayName("Air Quality")
        .description("PM2.5 from your purifier with a power button and the last 12 hours.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

@main
struct ExhaleWidgetBundle: WidgetBundle {
    var body: some Widget {
        ExhaleWidget()
    }
}
