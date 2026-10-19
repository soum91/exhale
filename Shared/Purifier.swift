import Foundation

struct DeviceInfo: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var category: String
    var productName: String
    var online: Bool
    var status: [String: JSONValue]
    var localKey: String? = nil

    static func parse(_ d: [String: Any]) -> DeviceInfo? {
        guard let id = d["id"] as? String else { return nil }
        var status: [String: JSONValue] = [:]
        if let list = d["status"] as? [[String: Any]] {
            for item in list {
                if let code = item["code"] as? String { status[code] = JSONValue.from(item["value"]) }
            }
        } else if let dict = d["status"] as? [String: Any] {
            for (k, v) in dict { status[k] = JSONValue.from(v) }
        }
        return DeviceInfo(id: id,
                          name: (d["name"] as? String) ?? "Device",
                          category: (d["category"] as? String) ?? "",
                          productName: (d["product_name"] as? String) ?? (d["productName"] as? String) ?? "",
                          online: (d["online"] as? Bool) ?? ((d["online"] as? NSNumber)?.boolValue ?? true),
                          status: status,
                          localKey: (d["local_key"] as? String) ?? (d["localKey"] as? String))
    }

    /// Tuya category "kj" is air purifier.
    var isPurifier: Bool { category == "kj" || status.keys.contains("pm25") }
}

/// One data point's type and range from the device specification.
struct DPSpec: Codable, Hashable {
    var code: String
    var type: String          // Boolean, Integer, Enum, String, Json, Raw, Bitmap
    var range: [String]?      // Enum
    var min: Double?
    var max: Double?
    var step: Double?
    var scale: Int?
    var unit: String?
    var name: String?

    static func parse(_ d: [String: Any]) -> DPSpec? {
        guard let code = d["code"] as? String else { return nil }
        var s = DPSpec(code: code, type: (d["type"] as? String) ?? "")
        s.name = d["name"] as? String
        var values: [String: Any] = [:]
        if let str = d["values"] as? String, let data = str.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            values = obj
        } else if let obj = d["values"] as? [String: Any] {
            values = obj
        }
        s.range = (values["range"] as? [Any])?.map { "\($0)" }
        s.min = (values["min"] as? NSNumber)?.doubleValue
        s.max = (values["max"] as? NSNumber)?.doubleValue
        s.step = (values["step"] as? NSNumber)?.doubleValue
        s.scale = (values["scale"] as? NSNumber)?.intValue
        s.unit = values["unit"] as? String
        return s
    }

    var isBool: Bool { type.lowercased() == "boolean" || type.lowercased() == "bool" }
    var isEnum: Bool { type.lowercased() == "enum" }
    var isInt: Bool { type.lowercased() == "integer" || type.lowercased() == "value" }
    var divisor: Double { pow(10, Double(scale ?? 0)) }
}

struct Purifier: Codable, Hashable {
    var info: DeviceInfo
    var functions: [String: DPSpec]
    var statusSpec: [String: DPSpec]

    var id: String { info.id }
    var name: String { info.name }
    var status: [String: JSONValue] { info.status }

    func spec(_ code: String) -> DPSpec? { functions[code] ?? statusSpec[code] }
    func has(_ code: String) -> Bool { status[code] != nil || functions[code] != nil }
    private func first(_ codes: [String], writable: Bool = false) -> String? {
        codes.first { writable ? functions[$0] != nil : has($0) }
    }

    func bool(_ code: String) -> Bool? { status[code]?.boolValue }
    func string(_ code: String) -> String? { status[code]?.stringValue }
    func number(_ code: String) -> Double? {
        guard let raw = status[code]?.doubleValue else { return nil }
        return raw / (spec(code)?.divisor ?? 1)
    }

    // MARK: Known purifier data points

    var powerCode: String? { first(["switch", "switch_1", "power", "switch_power"], writable: true) }
    var isOn: Bool { powerCode.flatMap { bool($0) } ?? true }

    var pm25Code: String? { first(["pm25", "pm25_value", "pm2_5", "pm_25", "pm25_val"]) }
    var pm25: Double? { pm25Code.flatMap { number($0) } }

    var speedCode: String? { first(["fan_speed_enum", "speed", "fan_speed", "windspeed", "fan_speed_percent", "fan_level", "level"], writable: true) }
    var modeCode: String? { first(["mode", "work_mode", "fan_mode", "manual_mode"], writable: true) }
    var timerCode: String? { first(["countdown_set", "countdown", "timer"], writable: true) }
    var timerLeftCode: String? { first(["countdown_left", "remain_time", "countdown_time"]) }
    var filterCode: String? { first(["filter", "filter_life", "filter_days", "filter_left", "filter_life_percent"]) }
    var filterResetCode: String? { first(["filter_reset", "reset_filter", "filter_life_reset"], writable: true) }
    var airQualityCode: String? { first(["air_quality", "air_quality_index", "pm25_state"]) }

    struct ToggleDef: Hashable { let code: String; let title: String; let icon: String }
    static let knownToggles: [ToggleDef] = [
        .init(code: "anion", title: "Ionizer", icon: "sparkles"),
        .init(code: "uv", title: "UV-C", icon: "light.max"),
        .init(code: "lock", title: "Child lock", icon: "lock.fill"),
        .init(code: "child_lock", title: "Child lock", icon: "lock.fill"),
        .init(code: "light", title: "Display light", icon: "lightbulb.fill"),
        .init(code: "switch_led", title: "Display light", icon: "lightbulb.fill"),
        .init(code: "switch_backlight", title: "Backlight", icon: "lightbulb.fill"),
        .init(code: "switch_night_light", title: "Night light", icon: "moon.stars.fill"),
        .init(code: "wet", title: "Humidify", icon: "humidity.fill"),
        .init(code: "beep", title: "Beep", icon: "speaker.wave.2.fill"),
        .init(code: "switch_beep", title: "Beep", icon: "speaker.wave.2.fill"),
        .init(code: "sleep", title: "Sleep", icon: "moon.fill"),
        .init(code: "eco", title: "Eco", icon: "leaf.fill"),
    ]
    var toggles: [ToggleDef] {
        var seenTitles = Set<String>()
        return Self.knownToggles.filter { t in
            guard functions[t.code]?.isBool == true, !seenTitles.contains(t.title) else { return false }
            seenTitles.insert(t.title)
            return true
        }
    }

    struct Reading: Hashable { let code: String; let title: String; let icon: String; let unit: String }
    static let knownReadings: [Reading] = [
        .init(code: "temp", title: "Temperature", icon: "thermometer.medium", unit: "°"),
        .init(code: "temp_indoor", title: "Temperature", icon: "thermometer.medium", unit: "°"),
        .init(code: "humidity", title: "Humidity", icon: "humidity", unit: "%"),
        .init(code: "humidity_indoor", title: "Humidity", icon: "humidity", unit: "%"),
        .init(code: "tvoc", title: "TVOC", icon: "aqi.medium", unit: ""),
        .init(code: "eco2", title: "eCO₂", icon: "carbon.dioxide.cloud", unit: "ppm"),
        .init(code: "co2_value", title: "CO₂", icon: "carbon.dioxide.cloud", unit: "ppm"),
        .init(code: "ch2o_value", title: "Formaldehyde", icon: "flask", unit: ""),
        .init(code: "pm10", title: "PM10", icon: "aqi.low", unit: "µg/m³"),
        .init(code: "pm1", title: "PM1.0", icon: "aqi.low", unit: "µg/m³"),
        .init(code: "total_runtime", title: "Runtime", icon: "clock", unit: ""),
        .init(code: "total_pm", title: "Total cleaned", icon: "wind", unit: ""),
    ]
    var readings: [Reading] {
        var seen = Set<String>()
        return Self.knownReadings.filter { r in
            guard status[r.code] != nil, !seen.contains(r.title) else { return false }
            seen.insert(r.title)
            return true
        }
    }
    func readingText(_ r: Reading) -> String {
        guard let v = number(r.code) else { return string(r.code) ?? "–" }
        let unit = spec(r.code)?.unit.flatMap { $0.isEmpty ? nil : $0 } ?? r.unit
        return "\(Fmt.num(v))\(unit.hasPrefix("°") || unit == "%" ? "" : " ")\(unit)"
    }

    /// Writable data points the dedicated controls above don't already cover.
    var extraFunctions: [DPSpec] {
        var handled = Set([powerCode, speedCode, modeCode, timerCode, filterResetCode].compactMap { $0 })
        handled.formUnion(toggles.map(\.code))
        return functions.values
            .filter { !handled.contains($0.code) && ($0.isBool || $0.isEnum || $0.isInt) }
            .sorted { $0.code < $1.code }
    }

    /// Filter life as 0...1 when the device reports a percentage.
    var filterFraction: Double? {
        guard let code = filterCode, let v = number(code) else { return nil }
        let s = spec(code)
        if s?.unit == "%" || code.contains("life") || code == "filter" {
            let maxV = s?.max.map { $0 / (s?.divisor ?? 1) } ?? 100
            return max(0, min(1, v / (maxV > 0 ? maxV : 100)))
        }
        return nil
    }
    var filterText: String? {
        guard let code = filterCode, let v = number(code) else { return nil }
        if let f = filterFraction, code != "filter_days" { return "\(Int((f * 100).rounded()))%" }
        let unit = spec(code)?.unit ?? ""
        return "\(Fmt.num(v)) \(unit.isEmpty ? (code.contains("day") ? "days" : "") : unit)"
    }

    func applying(_ code: String, _ value: JSONValue) -> Purifier {
        var copy = self
        copy.info.status[code] = value
        return copy
    }
}

enum Fmt {
    static func num(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }

    /// "fan_speed_enum" -> "Fan speed", "sleep" -> "Sleep", "4" -> "4"
    static func label(_ raw: String) -> String {
        let known: [String: String] = [
            "auto": "Auto", "manual": "Manual", "sleep": "Sleep", "smart": "Smart",
            "low": "Low", "mid": "Med", "middle": "Med", "medium": "Med", "high": "High",
            "turbo": "Turbo", "strong": "Turbo", "max": "Max", "quiet": "Quiet", "silent": "Silent",
            "cancel": "Off", "off": "Off", "1h": "1 h", "2h": "2 h", "4h": "4 h", "8h": "8 h",
            "great": "Great", "good": "Good", "severe": "Poor", "poor": "Poor", "bad": "Bad",
            "fan_speed_enum": "Fan speed", "speed": "Fan speed", "mode": "Mode", "work_mode": "Mode",
        ]
        if let k = known[raw.lowercased()] { return k }
        if let n = Int(raw) { return String(n) }
        let words = raw.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}
