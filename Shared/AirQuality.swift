import SwiftUI

/// PM2.5 bands (US EPA 2024 breakpoints, µg/m³).
enum AQBand: Int, CaseIterable {
    case good, moderate, sensitive, unhealthy, veryUnhealthy, hazardous

    static func of(_ pm: Double) -> AQBand {
        switch pm {
        case ..<9.05: return .good
        case ..<35.45: return .moderate
        case ..<55.45: return .sensitive
        case ..<125.45: return .unhealthy
        case ..<225.45: return .veryUnhealthy
        default: return .hazardous
        }
    }

    var lowerBound: Double {
        switch self {
        case .good: return 0
        case .moderate: return 9
        case .sensitive: return 35.4
        case .unhealthy: return 55.4
        case .veryUnhealthy: return 125.4
        case .hazardous: return 225.4
        }
    }

    var label: String {
        switch self {
        case .good: return "Good"
        case .moderate: return "Moderate"
        case .sensitive: return "Sensitive"
        case .unhealthy: return "Unhealthy"
        case .veryUnhealthy: return "Very unhealthy"
        case .hazardous: return "Hazardous"
        }
    }

    var short: String {
        switch self {
        case .sensitive: return "Fair"
        case .veryUnhealthy: return "V. poor"
        case .unhealthy: return "Poor"
        default: return label
        }
    }

    var color: Color {
        switch self {
        case .good: return Color(red: 0.24, green: 0.86, blue: 0.62)
        case .moderate: return Color(red: 0.98, green: 0.80, blue: 0.30)
        case .sensitive: return Color(red: 1.00, green: 0.60, blue: 0.27)
        case .unhealthy: return Color(red: 1.00, green: 0.36, blue: 0.38)
        case .veryUnhealthy: return Color(red: 0.71, green: 0.40, blue: 0.93)
        case .hazardous: return Color(red: 0.62, green: 0.20, blue: 0.30)
        }
    }

    var previous: AQBand { AQBand(rawValue: max(0, rawValue - 1)) ?? .good }

    /// Vertical gradient for a plot whose y axis runs 0...top, so the curve changes colour where the bands do.
    static func gradient(top: Double) -> Gradient {
        var stops: [Gradient.Stop] = [.init(color: AQBand.good.color, location: 0)]
        let blend = 0.05
        for band in AQBand.allCases.dropFirst() {
            let loc = band.lowerBound / max(top, 1)
            guard loc < 1 else { break }
            stops.append(.init(color: band.previous.color, location: max(0, loc - blend)))
            stops.append(.init(color: band.color, location: min(1, loc + blend)))
        }
        let topBand = AQBand.of(top)
        stops.append(.init(color: topBand.color, location: 1))
        return Gradient(stops: stops.sorted { $0.location < $1.location })
    }
}

enum AQ {
    static func color(_ pm: Double?) -> Color { pm.map { AQBand.of($0).color } ?? Color(white: 0.5) }
    static func label(_ pm: Double?) -> String { pm.map { AQBand.of($0).label } ?? "No data" }
    static func value(_ pm: Double?) -> String { pm.map { Fmt.num($0.rounded()) } ?? "–" }
}

/// US EPA AQI from PM2.5 (2024 breakpoints), the number the Guardian app shows.
enum USAQI {
    private static let table: [(cLo: Double, cHi: Double, iLo: Double, iHi: Double)] = [
        (0.0, 9.0, 0, 50), (9.1, 35.4, 51, 100), (35.5, 55.4, 101, 150),
        (55.5, 125.4, 151, 200), (125.5, 225.4, 201, 300), (225.5, 325.4, 301, 500),
    ]

    static func from(pm25: Double) -> Int {
        let c = (max(pm25, 0) * 10).rounded(.down) / 10
        for row in table where c <= row.cHi {
            let lo = max(c, row.cLo)
            return Int(((row.iHi - row.iLo) / (row.cHi - row.cLo) * (lo - row.cLo) + row.iLo).rounded())
        }
        return 500
    }

    static func band(_ aqi: Int) -> AQBand {
        switch aqi {
        case ..<51: return .good
        case ..<101: return .moderate
        case ..<151: return .sensitive
        case ..<201: return .unhealthy
        case ..<301: return .veryUnhealthy
        default: return .hazardous
        }
    }
}
