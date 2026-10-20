import Foundation
import SwiftUI

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

    /// Fan values sorted low to high when they look numeric.
    var fanValues: [JSONValue] {
        guard let fan = fanDP, let seen = observed[fan] else { return [] }
        // Whole numbers: assume the Guardian app's 1...10 steps, plus anything higher we've actually seen.
        let ints = seen.compactMap { v -> Int? in if case .int(let i) = v { return i }; return nil }
        if ints.count == seen.count, let top = ints.max() {
            return (1...max(10, top)).map { JSONValue.int($0) }
        }
        let nums = seen.compactMap { $0.doubleValue }
        if nums.count == seen.count { return seen.sorted { ($0.doubleValue ?? 0) < ($1.doubleValue ?? 0) } }
        return seen
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
    var localFan: JSONValue? { local.fanDP.flatMap { localDPS[$0] } }
    var localDisplayOn: Bool? {
        local.displayDP.flatMap { localDPS[$0]?.boolValue }.map { $0 != local.displayInverted }
    }

    func setLocalFan(_ v: JSONValue, manualMode: Bool) {
        guard let fan = local.fanDP else { return }
        var cmds: [(String, JSONValue)] = [("dp:\(fan)", v)]
        if manualMode, let p = purifier, let mode = p.modeCode, let range = p.functions[mode]?.range,
           let manual = range.first(where: { $0.lowercased() == "manual" }), p.string(mode) != manual {
            cmds.insert((mode, .string(manual)), at: 0)
        }
        setMany(cmds)
    }

    func toggleLocalDisplay() {
        guard let d = local.displayDP else { return }
        let on = localDisplayOn ?? false
        if !on, keepDisplayOff { keepDisplayOff = false }
        // Raw value that means the new state.
        setMany([("dp:\(d)", .bool(!on != local.displayInverted))])
    }
}
