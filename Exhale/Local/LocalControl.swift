import Foundation
import SwiftUI
import WidgetKit

/// What we've learned about talking to the purifier over Wi-Fi.
struct LocalConfig: Codable, Equatable {
    var enabled = true
    var host: String?
    var version: Double?
    var fanDP: String?
    var displayDP: String?
    /// True when the purifier stores the display backwards (true = screen off).
    var displayInverted: Bool = false
    /// Every value seen per data point, in the order first seen. Used to build the fan slider.
    var observed: [String: [JSONValue]] = [:]
    /// Local data point id -> cloud code, from Tuya.
    var codeMap: [String: String] = [:]

    static var stored: LocalConfig {
        get { AppGroup.read(LocalConfig.self, "local.json") ?? LocalConfig() }
        set { AppGroup.write(newValue, "local.json") }
    }

    /// The AC3250's fan point takes exactly 1...10, and it is a *text* enum ("1"..."10"), not a number.
    /// Sending the number 5 instead of the text "5" is invalid and the firmware falls back to speed 1,
    /// so always send the same type the purifier reports.
    var fanValues: [JSONValue] {
        guard let fan = fanDP else { return [] }
        let seen = observed[fan] ?? []
        let reportsText = seen.contains { if case .string = $0 { return true }; return false }
        let reportsNumber = seen.contains { if case .int = $0 { return true }; return false }
        if reportsText || !reportsNumber {
            return (1...10).map { JSONValue.string(String($0)) }
        }
        return (1...10).map { JSONValue.int($0) }
    }
}

enum LocalState: Equatable {
    case off, searching(String), connecting, connected(Double), failed(String)

    var text: String {
        switch self {
        case .off: return "Not connected"
        case .searching(let s): return s
        case .connecting: return "Connecting…"
        case .connected(let v): return "Connected over Wi-Fi (protocol \(String(format: "%.1f", v)))"
        case .failed(let e): return e
        }
    }

    var isConnected: Bool { if case .connected = self { return true } else { return false } }
}

extension AppStore {
    // MARK: Connection

    func startLocal() {
        guard local.enabled, let p = purifier, let key = p.info.localKey, let host = local.host, localTask == nil, link == nil else { return }
        localState = .connecting
        let devId = p.id
        let known = Array(local.codeMap.keys)
        let version = local.version
        localTask = Task { [weak self] in
            do {
                let onDPS: @Sendable ([String: JSONValue]) -> Void = { dps in
                    Task { @MainActor in AppStore.shared.receiveLocal(dps) }
                }
                let onClose: @Sendable (String) -> Void = { why in
                    Task { @MainActor in AppStore.shared.localClosed(why) }
                }
                let result: (LocalLink, [String: JSONValue])
                if let version {
                    let l = LocalLink(devId: devId, host: host, localKey: key, version: version, knownDPs: known, onDPS: onDPS, onClose: onClose)
                    do {
                        try await l.open()
                        result = (l, try await l.query())
                    } catch {
                        await l.close()
                        result = try await LocalLink.detect(devId: devId, host: host, localKey: key, knownDPs: known, onDPS: onDPS, onClose: onClose)
                    }
                } else {
                    result = try await LocalLink.detect(devId: devId, host: host, localKey: key, knownDPs: known, onDPS: onDPS, onClose: onClose)
                }
                guard let self else { await result.0.close(); return }
                self.link = result.0
                let v = result.0.version
                self.local.version = v
                self.saveLocal()
                self.localState = .connected(v)
                self.localRetry = 0
                self.receiveLocal(result.1)
                if self.local.codeMap.isEmpty, let client = self.cloudClient {
                    if let map = try? await client.dpMap(id: devId) {
                        self.local.codeMap = map
                        self.saveLocal()
                    }
                }
            } catch {
                self?.localTask = nil
                if let self, self.localWanted, self.localRetry > 0 {
                    self.localClosed(error.localizedDescription)
                } else {
                    self?.localState = .failed("Couldn't connect over Wi-Fi: \(error.localizedDescription)")
                }
                return
            }
            self?.localTask = nil
        }
    }

    func stopLocal() {
        localTask?.cancel()
        localTask = nil
        if let l = link { Task { await l.close() } }
        link = nil
        if localState.isConnected { localState = .off }
    }

    func localClosed(_ why: String) {
        link = nil
        guard localWanted, local.enabled, local.host != nil else {
            localState = .failed(why)
            return
        }
        // Tuya devices drop idle links and only allow one local client (the Guardian app can bump us),
        // so keep trying quietly with a growing delay while Exhale is open.
        localRetry = min(localRetry + 1, 6)
        let delay = UInt64([2, 3, 5, 10, 20, 30][localRetry - 1])
        localState = .searching("Reconnecting…")
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            guard let self, self.localWanted, self.link == nil, self.localTask == nil else { return }
            self.startLocal()
        }
    }

    func reconnectLocal() {
        stopLocal()
        startLocal()
    }

    func saveLocal() { LocalConfig.stored = local }

    /// Scans the Wi-Fi for the purifier, trying the local key on every host with Tuya's port open.
    func findOnWiFi() {
        guard let p = purifier, let key = p.info.localKey else {
            localState = .failed("Tuya didn't give Exhale this device's local key.")
            return
        }
        stopLocal()
        localState = .searching("Scanning your Wi-Fi…")
        let devId = p.id
        let known = Array(local.codeMap.keys)
        localTask = Task { [weak self] in
            let hosts = await LocalScan.openHosts { n in
                Task { @MainActor in AppStore.shared.localState = .searching("Scanning your Wi-Fi… \(n)/254") }
            }
            guard let self else { return }
            if hosts.isEmpty {
                self.localState = .failed("Nothing on your Wi-Fi answered on Tuya's port. Allow Local Network for Exhale in iOS Settings, or enter the IP from your router.")
                self.localTask = nil
                return
            }
            for host in hosts {
                self.localState = .searching("Trying \(host)…")
                if let found = try? await LocalLink.detect(devId: devId, host: host, localKey: key, knownDPs: known, onDPS: { _ in }, onClose: { _ in }) {
                    let l = found.0
                    await l.close()
                    self.local.host = host
                    self.local.version = l.version
                    self.saveLocal()
                    self.localTask = nil
                    self.startLocal()
                    return
                }
            }
            self.localState = .failed("Found \(hosts.count) Tuya device(s) but none accepted this purifier's key.")
            self.localTask = nil
        }
    }

    // MARK: Data

    func receiveLocal(_ dps: [String: JSONValue]) {
        var changed = false
        for (k, v) in dps {
            if localDPS[k] != v {
                if localDPS[k] != nil { localChanged[k] = .now }
                localDPS[k] = v
            }
            var seen = local.observed[k] ?? []
            if !seen.contains(v) {
                seen.append(v)
                if seen.count > 24 { seen.removeFirst() }
                local.observed[k] = seen
                changed = true
            }
        }
        if changed { saveLocal() }
        // The display came on by itself: knock it straight back off.
        if keepDisplayOff, let d = local.displayDP, let raw = dps[d]?.boolValue, raw != local.displayInverted,
           purifier?.isOn != false {
            Task { try? await self.sendLocal([d: .bool(self.local.displayInverted)]) }
        }
    }

    func sendLocal(_ dps: [String: JSONValue]) async throws {
        guard let l = link else { throw LocalError("Not connected over Wi-Fi.") }
        for (k, v) in dps { localDPS[k] = v }
        try await l.set(dps)
    }

    func queryLocal() async {
        guard let l = link else { return }
        if let dps = try? await l.query() { receiveLocal(dps) }
    }

    /// Cloud code -> local id, when the local value looks like the cloud value (same encoding).
    func localID(forCloud code: String) -> String? {
        guard link != nil, let p = purifier,
              let id = local.codeMap.first(where: { $0.value == code })?.key,
              let lv = localDPS[id], let cv = p.status[code] else { return nil }
        switch (lv, cv) {
        case (.bool, .bool), (.int, .int), (.string, .string): return id
        default: return nil
        }
    }

    // MARK: Mapped controls

    var localFanValues: [JSONValue] { local.fanValues }
    /// Current fan value, normalised to the same type as `localFanValues` so lookups match.
    var localFan: JSONValue? {
        guard let raw = local.fanDP.flatMap({ localDPS[$0] }), let n = raw.doubleValue else { return nil }
        return localFanValues.first { $0.doubleValue == n } ?? raw
    }
    var localDisplayOn: Bool? {
        local.displayDP.flatMap { localDPS[$0]?.boolValue }.map { $0 != local.displayInverted }
    }

    func setLocalFan(_ v: JSONValue, manualMode: Bool) {
        Task { await setFanSpeed(v, manualMode: manualMode) }
    }

    /// The firmware drops to speed 1 whenever it enters Manual, so a speed sent alongside a mode change gets
    /// wiped out if the mode lands second. Switch the mode first, wait for the purifier to confirm it, then
    /// send the speed and check that it stuck.
    func setFanSpeed(_ v: JSONValue, manualMode: Bool) async {
        guard let fan = local.fanDP else { return }
        if let f = local.fanDP { localDPS[f] = v }       // move the UI right away
        do {
            if manualMode, let p = purifier, let mode = p.modeCode, let range = p.functions[mode]?.range,
               let manual = range.first(where: { $0.lowercased() == "manual" }) {
                let modeID = local.codeMap.first(where: { $0.value == mode })?.key
                let current = modeID.flatMap { localDPS[$0]?.stringValue } ?? p.string(mode)
                if current != manual {
                    if let modeID, link != nil {
                        try await sendLocal([modeID: .string(manual)])
                    } else {
                        try await PurifierSync.send(mode, .string(manual))
                    }
                    purifier = purifier?.applying(mode, .string(manual))
                    // Wait for the purifier to report Manual (it resets the fan to 1 at that moment).
                    let deadline = Date().addingTimeInterval(3)
                    while Date() < deadline {
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        if let modeID { await queryLocal(); if localDPS[modeID]?.stringValue == manual { break } }
                    }
                    try? await Task.sleep(nanoseconds: 400_000_000)
                }
            }
            try await sendLocal([fan: v])
            // Verify, and send once more if the firmware threw it away.
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await queryLocal()
            if localDPS[fan] != v {
                try await sendLocal([fan: v])
            }
            if let p = purifier { Cache.save(p) }
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func toggleLocalDisplay() {
        guard let d = local.displayDP else { return }
        let on = localDisplayOn ?? false
        if !on, keepDisplayOff { keepDisplayOff = false }
        // Raw value that means the new state.
        setMany([("dp:\(d)", .bool(!on != local.displayInverted))])
    }
}
