import Foundation
import WidgetKit

/// Away from home, fan speed and display go through the Keystone Bridge: the app publishes an encrypted
/// request to the bridge's relay, and the bridge (on the home Wi-Fi) talks to the purifier over the LAN.
/// Power, mode and UV-C keep using Tuya's cloud, which works anywhere already.
enum BridgeRemote {
    static var link: HomeBridgeLink { HomeBridgeLink.stored }
    static var isReady: Bool { link.isSet && RelayConfig.stored?.on == true && RelayConfig.stored?.symmetricKey != nil }

    /// On the home Wi-Fi: fetch the relay key from the bridge, and resend the purifier setup if it changed
    /// (so the bridge uses the same fan values and display mapping as this app).
    static func syncOnLAN(config: [String: Any]?) async {
        let l = link
        guard l.isSet, let u = HomeBridgeAPI.url(l.host, l.port, "/api/remote") else { return }
        var req = URLRequest(url: u)
        req.timeoutInterval = 4
        req.setValue(l.token, forHTTPHeaderField: "X-Device-Token")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let broker = o["broker"] as? String, let id = o["id"] as? String, let key = o["key"] as? String else { return }
        let cfg = RelayConfig(broker: broker, id: id, key: key, on: (o["on"] as? Bool) ?? true)
        if RelayConfig.stored != cfg { RelayConfig.stored = cfg }

        if let config, let sig = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]) {
            let hash = sig.base64EncodedString()
            if UserDefaults.standard.string(forKey: "bridgeConfigSig") != hash,
               (try? await HomeBridgeAPI.send(config, l)) != nil {
                UserDefaults.standard.set(hash, forKey: "bridgeConfigSig")
            }
        }
    }

    static func control(_ fields: [String: Any]) async throws {
        var body = fields
        body["device"] = "purifier"
        let json = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
        let (code, data) = try await RelayClient.shared.request("POST", "/api/control",
            headers: ["X-Device-Token": link.token, "Content-Type": "application/json"], body: json, timeout: 12)
        guard code == 200 else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw TuyaError(message: "Keystone Bridge: \(msg ?? "error \(code)")")
        }
    }

    /// The bridge's view of the purifier: speed (1...n), display, on, auto, pm25.
    static func status() async throws -> [String: Any] {
        let (code, data) = try await RelayClient.shared.request("GET", "/api/info",
            headers: ["X-Device-Token": link.token], body: nil, timeout: 12)
        guard code == 200, let o = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let p = o["purifier"] as? [String: Any] else { throw RelayError.timeout }
        return p
    }
}

extension AppStore {
    /// Fan speed and display can be changed: over Wi-Fi at home, or through the bridge relay away.
    var hiddenControlsAvailable: Bool { localState.isConnected || remoteReady }
    var hiddenControlsViaRelay: Bool { !localState.isConnected && remoteReady }

    func refreshRemoteReady() { remoteReady = BridgeRemote.isReady }

    func syncBridge() async {
        let cfg = homeBridgeConfig().body
        await BridgeRemote.syncOnLAN(config: cfg)
        refreshRemoteReady()
    }

    /// Away from home: mirror the bridge's fan speed and display into the same state the Wi-Fi link fills.
    func pollRemote() async {
        guard link == nil, remoteReady, let p = try? await BridgeRemote.status() else { return }
        if let fan = local.fanDP, let speed = (p["speed"] as? NSNumber)?.intValue,
           speed >= 1, speed <= localFanValues.count {
            localDPS[fan] = localFanValues[speed - 1]
        }
        if let d = local.displayDP, let on = p["display"] as? Bool {
            localDPS[d] = .bool(on != local.displayInverted)
        }
    }

    func setFanRemote(_ v: JSONValue) async {
        guard let speed = localFanValues.firstIndex(of: v).map({ $0 + 1 }) else { return }
        if let f = local.fanDP { localDPS[f] = v }
        do {
            // The bridge switches to Manual itself when needed, then sets the speed.
            try await BridgeRemote.control(["speed": speed])
            if let p = purifier, let mode = p.modeCode, let manual = p.functions[mode]?.range?.first(where: { $0.lowercased() == "manual" }) {
                purifier = p.applying(mode, .string(manual))
            }
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await pollRemote()
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func setDisplayRemote(_ on: Bool) async {
        if let d = local.displayDP { localDPS[d] = .bool(on != local.displayInverted) }
        if on, keepDisplayOff { keepDisplayOff = false }
        do {
            try await BridgeRemote.control(["display": on])
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await pollRemote()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
