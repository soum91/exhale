import Foundation

struct Sample: Hashable {
    let t: Date
    let pm: Double
}

struct ChartPoint: Hashable, Identifiable {
    let date: Date
    let value: Double
    var id: Date { date }
}

/// PM2.5 log kept on the phone. Tuya's sharing API has no history endpoint, so the app, the widget and
/// background refreshes all add readings here. Last 48 h keeps ~1/min, older data is rolled into 10-min averages.
enum History {
    private static let fileName = "pm-history.json"
    private static let keepDays: Double = 45

    static func load() -> [Sample] {
        guard let rows = AppGroup.read([[Double]].self, fileName) else { return [] }
        return rows.compactMap { r in r.count >= 2 ? Sample(t: Date(timeIntervalSince1970: r[0]), pm: r[1]) : nil }
    }

    private static func save(_ samples: [Sample]) {
        AppGroup.write(samples.map { [$0.t.timeIntervalSince1970.rounded(), ($0.pm * 10).rounded() / 10] }, fileName)
    }

    @discardableResult
    static func append(_ pm: Double, at date: Date = .now) -> [Sample] {
        var all = load()
        if let last = all.last, date.timeIntervalSince(last.t) < 55 {
            return all
        }
        all.append(Sample(t: date, pm: pm))
        all = compact(all, now: date)
        save(all)
        return all
    }

    static func clear() { AppGroup.remove(fileName) }

    private static func compact(_ samples: [Sample], now: Date) -> [Sample] {
        let oldest = now.addingTimeInterval(-keepDays * 86400)
        let rawFrom = now.addingTimeInterval(-48 * 3600)
        var out: [Sample] = []
        var bucketStart: Date?
        var bucket: [Sample] = []
        func flush() {
            guard !bucket.isEmpty else { return }
            let avg = bucket.map(\.pm).reduce(0, +) / Double(bucket.count)
            out.append(Sample(t: bucket[bucket.count / 2].t, pm: avg))
            bucket.removeAll()
        }
        for s in samples.sorted(by: { $0.t < $1.t }) where s.t >= oldest {
            if s.t >= rawFrom {
                flush()
                out.append(s)
                continue
            }
            if let start = bucketStart, s.t.timeIntervalSince(start) < 600 {
                bucket.append(s)
            } else {
                flush()
                bucketStart = s.t
                bucket = [s]
            }
        }
        flush()
        return out
    }

    /// Averages samples into fixed time buckets and splits the line wherever there's a gap in the data.
    static func series(_ samples: [Sample], from start: Date, to end: Date, step: TimeInterval) -> [[ChartPoint]] {
        let relevant = samples.filter { $0.t >= start && $0.t <= end }
        guard !relevant.isEmpty else { return [] }
        var buckets: [Int: (sum: Double, n: Int, last: Date)] = [:]
        for s in relevant {
            let i = Int(s.t.timeIntervalSince(start) / step)
            let b = buckets[i] ?? (0, 0, s.t)
            buckets[i] = (b.sum + s.pm, b.n + 1, max(b.last, s.t))
        }
        var segments: [[ChartPoint]] = []
        var current: [ChartPoint] = []
        for i in buckets.keys.sorted() {
            let b = buckets[i]!
            let center = start.addingTimeInterval((Double(i) + 0.5) * step)
            let date = min(center, b.last)
            let point = ChartPoint(date: date, value: b.sum / Double(b.n))
            // One continuous line, Blueair style: gaps (app closed, no refresh) are bridged smoothly.
            current.append(point)
        }
        // Light 3-point smoothing takes the sensor jitter out without flattening real spikes much.
        if current.count >= 5 {
            let raw = current
            for i in 1..<(raw.count - 1) {
                let v = (raw[i - 1].value + 2 * raw[i].value + raw[i + 1].value) / 4
                current[i] = ChartPoint(date: raw[i].date, value: v)
            }
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }
}
