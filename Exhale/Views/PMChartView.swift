import SwiftUI
import UIKit

enum ChartRange: String, CaseIterable, Identifiable {
    case day = "24H", week = "7D", month = "30D"
    var id: String { rawValue }

    var span: TimeInterval {
        switch self {
        case .day: return 86400
        case .week: return 7 * 86400
        case .month: return 30 * 86400
        }
    }

    var step: TimeInterval {
        switch self {
        case .day: return 10 * 60
        case .week: return 3600
        case .month: return 6 * 3600
        }
    }

    func ticks(from start: Date, to end: Date) -> [Date] {
        let cal = Calendar.current
        var out: [Date] = []
        switch self {
        case .day:
            var d = cal.dateInterval(of: .hour, for: start)!.end
            while cal.component(.hour, from: d) % 6 != 0 { d = d.addingTimeInterval(3600) }
            while d < end { out.append(d); d = d.addingTimeInterval(6 * 3600) }
        case .week:
            var d = cal.startOfDay(for: start).addingTimeInterval(86400)
            while d < end { out.append(d); d = cal.date(byAdding: .day, value: 1, to: d)! }
        case .month:
            var d = cal.startOfDay(for: start).addingTimeInterval(86400)
            while d < end { out.append(d); d = cal.date(byAdding: .day, value: 7, to: d)! }
        }
        return out
    }

    func tickLabel(_ d: Date) -> String {
        switch self {
        case .day: return d.formatted(.dateTime.hour())
        case .week: return d.formatted(.dateTime.weekday(.abbreviated))
        case .month: return d.formatted(.dateTime.month(.abbreviated).day())
        }
    }

    func scrubLabel(_ d: Date) -> String {
        switch self {
        case .day: return d.formatted(.dateTime.hour().minute())
        case .week: return d.formatted(.dateTime.weekday(.abbreviated).hour())
        case .month: return d.formatted(.dateTime.month(.abbreviated).day().hour())
        }
    }
}

struct PMChartView: View {
    let samples: [Sample]
    var current: Double?
    @State private var range: ChartRange = .day
    @State private var selected: ChartPoint?
    @State private var now = Date()

    private var start: Date { now.addingTimeInterval(-range.span) }
    private var segments: [[ChartPoint]] { History.series(samples, from: start, to: now, step: range.step) }

    var body: some View {
        let segs = segments
        let flat = segs.flatMap { $0 }
        let top = PlotMapper.niceTop(for: flat.map(\.value).max() ?? 0)

        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionTitle(text: "PM2.5 history")
                Spacer()
                rangePicker
            }

            header(flat)

            GeometryReader { geo in
                let plot = CGSize(width: geo.size.width - 28, height: geo.size.height)
                let m = PlotMapper(start: start, end: now, top: top, size: plot)
                ZStack(alignment: .topLeading) {
                    grid(m, top: top, width: geo.size.width)
                    if flat.isEmpty {
                        Text("Readings are logged while Exhale or its widget refreshes. The graph fills in from here.")
                            .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            .frame(width: plot.width, height: plot.height)
                    } else {
                        AirCurve(segments: segs, start: start, end: now, top: top, lineWidth: 2.5, fillOpacity: 0.4)
                            .frame(width: plot.width, height: plot.height)
                            .animation(.easeInOut(duration: 0.35), value: range)
                    }
                    if let s = selected {
                        let p = m.point(s)
                        Rectangle().fill(Color.white.opacity(0.35)).frame(width: 1, height: plot.height)
                            .position(x: p.x, y: plot.height / 2)
                        Circle().fill(AQ.color(s.value)).frame(width: 12, height: 12)
                            .overlay(Circle().stroke(Color.white, lineWidth: 2.5))
                            .position(p)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            guard !flat.isEmpty else { return }
                            let x = min(max(g.location.x, 0), plot.width)
                            let nearest = flat.min { abs(m.x($0.date) - x) < abs(m.x($1.date) - x) }
                            if nearest != selected {
                                selected = nearest
                                UISelectionFeedbackGenerator().selectionChanged()
                            }
                        }
                        .onEnded { _ in withAnimation(.easeOut(duration: 0.2)) { selected = nil } }
                )
            }
            .frame(height: 190)

            xAxis

            legend
        }
        .card()
        .onAppear { now = Date() }
        .onChange(of: samples.count) { _, _ in now = Date() }
    }

    private var rangePicker: some View {
        HStack(spacing: 2) {
            ForEach(ChartRange.allCases) { r in
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) { range = r; now = Date() }
                } label: {
                    Text(r.rawValue)
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(range == r ? Color.white.opacity(0.16) : .clear))
                        .foregroundStyle(range == r ? Color.white : Color.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.05)))
    }

    @ViewBuilder
    private func header(_ flat: [ChartPoint]) -> some View {
        if let s = selected {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(AQ.value(s.value)).font(.system(size: 28, weight: .semibold, design: .rounded))
                Text("µg/m³").font(.caption).foregroundStyle(.secondary)
                Text(AQBand.of(s.value).label).font(.subheadline.weight(.semibold)).foregroundStyle(AQ.color(s.value))
                Spacer()
                Text(range.scrubLabel(s.date)).font(.caption).foregroundStyle(.secondary)
            }
        } else {
            let values = flat.map(\.value)
            let avg = values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
            let peak = values.max()
            let clean = values.isEmpty ? nil : Double(values.filter { $0 < 9.05 }.count) / Double(values.count)
            HStack(spacing: 0) {
                stat("Average", avg.map { Fmt.num($0.rounded()) } ?? "–", color: AQ.color(avg))
                stat("Peak", peak.map { Fmt.num($0.rounded()) } ?? "–", color: AQ.color(peak))
                stat("Good air", clean.map { "\(Int(($0 * 100).rounded()))%" } ?? "–", color: AQBand.good.color)
            }
        }
    }

    private func stat(_ title: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func grid(_ m: PlotMapper, top: Double, width: CGFloat) -> some View {
        let bands: [Double] = [9, 35.4, 55.4, 125.4, 225.4].filter { $0 < top * 0.97 }
        let lines: [Double] = [0] + bands + [top]
        return ZStack(alignment: .topLeading) {
            ForEach(lines, id: \.self) { v in
                let y = m.y(v)
                Path { p in
                    p.move(to: CGPoint(x: 0, y: y))
                    p.addLine(to: CGPoint(x: m.size.width, y: y))
                }
                .stroke(Color.white.opacity(v == 0 ? 0.15 : 0.07), style: StrokeStyle(lineWidth: 1, dash: v == 0 ? [] : [3, 4]))
                Text(Fmt.num(v.rounded()))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(v == 0 || v == top ? Color.white.opacity(0.35) : AQBand.of(v + 0.1).color.opacity(0.8))
                    .position(x: m.size.width + 14, y: y)
            }
        }
        .frame(width: width, height: m.size.height, alignment: .topLeading)
    }

    private var xAxis: some View {
        GeometryReader { geo in
            let m = PlotMapper(start: start, end: now, top: 1, size: CGSize(width: geo.size.width - 28, height: 1))
            ZStack(alignment: .topLeading) {
                ForEach(range.ticks(from: start, to: now), id: \.self) { d in
                    Text(range.tickLabel(d))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                        .fixedSize()
                        .position(x: m.x(d), y: 6)
                }
            }
        }
        .frame(height: 12)
    }

    private var legend: some View {
        HStack(spacing: 12) {
            ForEach([AQBand.good, .moderate, .sensitive, .unhealthy], id: \.self) { b in
                HStack(spacing: 4) {
                    Circle().fill(b.color).frame(width: 7, height: 7)
                    Text(b.short).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                }
            }
            Spacer()
        }
    }
}
