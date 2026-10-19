import Foundation

/// Outdoor air at home from Open-Meteo (free, no key). Refreshed at most every 30 minutes.
@MainActor
final class OutdoorAir: ObservableObject {
    static let shared = OutdoorAir()

    @Published private(set) var aqi: Int?
    @Published private(set) var pm25: Double?
    @Published private(set) var updated: Date?

    private init() {
        let d = UserDefaults.standard
        if d.object(forKey: "outdoor.aqi") != nil { aqi = d.integer(forKey: "outdoor.aqi") }
        if d.object(forKey: "outdoor.pm") != nil { pm25 = d.double(forKey: "outdoor.pm") }
        updated = d.object(forKey: "outdoor.updated") as? Date
    }

    func refresh(force: Bool = false) async {
        guard let home = Geo.shared.home else { return }
        if !force, let u = updated, Date().timeIntervalSince(u) < 1800 { return }
        let url = URL(string: String(format: "https://air-quality-api.open-meteo.com/v1/air-quality?latitude=%.4f&longitude=%.4f&current=us_aqi,pm2_5", home.lat, home.lon))!
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cur = obj["current"] as? [String: Any] else { return }
        if let a = (cur["us_aqi"] as? NSNumber)?.doubleValue { aqi = Int(a.rounded()) }
        pm25 = (cur["pm2_5"] as? NSNumber)?.doubleValue
        updated = .now
        let d = UserDefaults.standard
        d.set(aqi, forKey: "outdoor.aqi")
        d.set(pm25, forKey: "outdoor.pm")
        d.set(updated, forKey: "outdoor.updated")
    }
}
