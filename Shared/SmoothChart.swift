import SwiftUI

/// Geometry for a time/PM2.5 plot. Shared by the in-app chart and the widgets.
struct PlotMapper {
    let start: Date
    let end: Date
    let top: Double
    let size: CGSize

    func x(_ d: Date) -> CGFloat {
        let span = max(end.timeIntervalSince(start), 1)
        return CGFloat(d.timeIntervalSince(start) / span) * size.width
    }

    func y(_ v: Double) -> CGFloat {
        size.height - CGFloat(min(max(v, 0), top) / max(top, 1)) * size.height
    }

    func point(_ p: ChartPoint) -> CGPoint { CGPoint(x: x(p.date), y: y(p.value)) }

    /// A round axis ceiling that leaves headroom above the peak.
    static func niceTop(for peak: Double, minimum: Double = 20) -> Double {
        let target = max(peak * 1.25, minimum)
        let steps: [Double] = [10, 15, 20, 25, 30, 40, 50, 60, 80, 100, 120, 150, 200, 250, 300, 400, 500, 750, 1000]
        return steps.first { $0 >= target } ?? (ceil(target / 250) * 250)
    }
}

/// Smooth curve through the points using monotone cubic interpolation (no dips below zero, no fake peaks).
struct CurveShape: Shape {
    var segments: [[ChartPoint]]
    var start: Date
    var end: Date
    var top: Double
    var filled: Bool

    func path(in rect: CGRect) -> Path {
        let m = PlotMapper(start: start, end: end, top: top, size: rect.size)
        var path = Path()
        for seg in segments {
            let pts = seg.map(m.point)
            guard let first = pts.first else { continue }
            if pts.count == 1 {
                // Lone reading: a small flat dash so it still shows up.
                let a = CGPoint(x: first.x - 2, y: first.y), b = CGPoint(x: first.x + 2, y: first.y)
                if filled {
                    path.move(to: CGPoint(x: a.x, y: rect.height))
                    path.addLine(to: a); path.addLine(to: b)
                    path.addLine(to: CGPoint(x: b.x, y: rect.height))
                    path.closeSubpath()
                } else {
                    path.move(to: a); path.addLine(to: b)
                }
                continue
            }
            if filled {
                path.move(to: CGPoint(x: first.x, y: rect.height))
                path.addLine(to: first)
            } else {
                path.move(to: first)
            }
            Self.addMonotone(pts, to: &path)
            if filled {
                path.addLine(to: CGPoint(x: pts.last!.x, y: rect.height))
                path.closeSubpath()
            }
        }
        return path
    }

    static func addMonotone(_ p: [CGPoint], to path: inout Path) {
        let n = p.count
        guard n > 1 else { return }
        var dx = [CGFloat](repeating: 0, count: n - 1)
        var slope = [CGFloat](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) {
            dx[i] = max(p[i + 1].x - p[i].x, 0.0001)
            slope[i] = (p[i + 1].y - p[i].y) / dx[i]
        }
        var tangent = [CGFloat](repeating: 0, count: n)
        tangent[0] = slope[0]
        tangent[n - 1] = slope[n - 2]
        if n > 2 {
            for i in 1..<(n - 1) {
                let m0 = slope[i - 1], m1 = slope[i]
                if m0 * m1 <= 0 {
                    tangent[i] = 0
                } else {
                    let w1 = 2 * dx[i] + dx[i - 1]
                    let w2 = dx[i] + 2 * dx[i - 1]
                    tangent[i] = (w1 + w2) / (w1 / m0 + w2 / m1)
                }
            }
        }
        for i in 0..<(n - 1) {
            let h = dx[i] / 3
            let c1 = CGPoint(x: p[i].x + h, y: p[i].y + tangent[i] * h)
            let c2 = CGPoint(x: p[i + 1].x - h, y: p[i + 1].y - tangent[i + 1] * h)
            path.addCurve(to: p[i + 1], control1: c1, control2: c2)
        }
    }
}

/// The Blueair-style look: a soft, colour-graded fill under a smooth line that turns amber or red
/// only where the air actually got worse.
struct AirCurve: View {
    var segments: [[ChartPoint]]
    var start: Date
    var end: Date
    var top: Double
    var lineWidth: CGFloat = 2.5
    var fillOpacity: Double = 0.35

    var body: some View {
        let grad = AQBand.gradient(top: top)
        ZStack {
            CurveShape(segments: segments, start: start, end: end, top: top, filled: true)
                .fill(LinearGradient(gradient: grad, startPoint: .bottom, endPoint: .top))
                .opacity(fillOpacity)
                .mask(LinearGradient(colors: [.white, .white.opacity(0.15)], startPoint: .top, endPoint: .bottom))
            CurveShape(segments: segments, start: start, end: end, top: top, filled: false)
                .stroke(LinearGradient(gradient: grad, startPoint: .bottom, endPoint: .top),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
    }
}
