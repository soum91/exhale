import Foundation

enum SceneTrigger: Codable, Hashable {
    case manual
    case arrive
    case leave
    case pmAbove(Double)
    case pmBelow(Double)

    var isLocation: Bool { self == .arrive || self == .leave }
    var isPM: Bool {
        switch self {
        case .pmAbove, .pmBelow: return true
        default: return false
        }
    }

    var label: String {
        switch self {
        case .manual: return "Tap to run"
        case .arrive: return "When I arrive home"
        case .leave: return "When I leave home"
        case .pmAbove(let v): return "PM2.5 rises above \(Fmt.num(v))"
        case .pmBelow(let v): return "PM2.5 drops below \(Fmt.num(v))"
        }
    }

    var icon: String {
        switch self {
        case .manual: return "hand.tap"
        case .arrive: return "house.fill"
        case .leave: return "figure.walk"
        case .pmAbove: return "arrow.up.right"
        case .pmBelow: return "arrow.down.right"
        }
    }
}

struct SceneAction: Codable, Hashable {
    var code: String
    var value: JSONValue
}

struct AirScene: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var name: String
    var icon: String = "sparkles"
    var enabled: Bool = true
    var trigger: SceneTrigger = .manual
    var actions: [SceneAction] = []
    /// PM triggers fire once per crossing and re-arm after the air moves back past the threshold.
    var armed: Bool = true
    var lastRun: Date?

    func summary(_ p: Purifier?) -> String {
        if actions.isEmpty { return "No actions" }
        return actions.map { a -> String in
            if a.code == p?.powerCode { return a.value.boolValue == true ? "On" : "Off" }
            let name = Fmt.label(a.code)
            if case .bool(let b) = a.value { return "\(name) \(b ? "on" : "off")" }
            return "\(name) \(Fmt.label(a.value.display))"
        }
        .joined(separator: " · ")
    }
}

enum SceneStore {
    private static let file = "scenes.json"
    static func load() -> [AirScene] { AppGroup.read([AirScene].self, file) ?? [] }
    static func save(_ list: [AirScene]) { AppGroup.write(list, file) }
}

/// Options that work around the purifier's firmware.
enum Tweaks {
    private static let file = "tweaks.json"
    struct Values: Codable { var keepDisplayOff = false; var displayCode: String? }
    static var values: Values {
        get { AppGroup.read(Values.self, file) ?? Values() }
        set { AppGroup.write(newValue, file) }
    }
}

enum SceneEngine {
    /// Sends one batched command (one wake of the purifier's display) and skips anything already set.
    static func run(_ scene: AirScene, purifier: Purifier?, client: TuyaClient? = nil) async throws {
        guard let p = purifier ?? Cache.purifier else { throw TuyaError(message: "No purifier selected.") }
        guard let c = client ?? TokenStore.load().map({ TuyaClient(token: $0) }) else {
            throw TuyaError(message: "Not signed in.")
        }
        var actions = scene.actions.filter { p.status[$0.code] != $0.value }
        // Turning on has to go first or some purifiers ignore the rest.
        if let power = p.powerCode, let i = actions.firstIndex(where: { $0.code == power }) {
            let a = actions.remove(at: i)
            actions.insert(a, at: 0)
        }
        if !actions.isEmpty {
            try await c.send(id: p.id, actions.map { ($0.code, $0.value) })
            var updated = p
            for a in actions { updated = updated.applying(a.code, a.value) }
            Cache.save(updated)
        }
        var list = SceneStore.load()
        if let i = list.firstIndex(where: { $0.id == scene.id }) {
            list[i].lastRun = .now
            SceneStore.save(list)
        }
    }

    /// Called after every fresh reading (app, widget, background refresh). Returns names of scenes that ran.
    @discardableResult
    static func evaluatePM(_ pm: Double, purifier: Purifier, client: TuyaClient) async -> [String] {
        var list = SceneStore.load()
        var ran: [String] = []
        var changed = false
        for i in list.indices where list[i].enabled {
            let s = list[i]
            let hit: Bool, rearm: Bool
            switch s.trigger {
            case .pmAbove(let v): hit = pm > v; rearm = pm <= v - max(2, v * 0.1)
            case .pmBelow(let v): hit = pm < v; rearm = pm >= v + max(2, v * 0.1)
            default: continue
            }
            if s.armed && hit {
                if let last = s.lastRun, Date().timeIntervalSince(last) < 600 { continue }
                list[i].armed = false
                list[i].lastRun = .now
                changed = true
                SceneStore.save(list)
                if (try? await run(s, purifier: Cache.purifier ?? purifier, client: client)) != nil { ran.append(s.name) }
                list = SceneStore.load()
            } else if !s.armed && rearm {
                list[i].armed = true
                changed = true
            }
        }
        if changed { SceneStore.save(list) }
        return ran
    }

    /// If the firmware turned the display back on by itself, switch it off again.
    static func enforceDisplay(_ p: Purifier, client: TuyaClient) async {
        let t = Tweaks.values
        guard t.keepDisplayOff, let code = t.displayCode ?? p.displayCode, p.functions[code] != nil,
              p.isOn, p.bool(code) == true else { return }
        try? await client.send(id: p.id, [(code, .bool(false))])
        Cache.save(p.applying(code, .bool(false)))
    }

    static func afterRefresh(_ p: Purifier, client: TuyaClient) async {
        await enforceDisplay(p, client: client)
        if let pm = p.pm25 { await evaluatePM(pm, purifier: p, client: client) }
    }
}

extension Purifier {
    var displayCode: String? {
        ["light", "switch_led", "switch_backlight", "screen", "display", "screen_switch"].first { functions[$0]?.isBool == true }
    }
}
