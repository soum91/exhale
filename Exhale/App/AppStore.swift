import SwiftUI
import WidgetKit

@MainActor
final class AppStore: ObservableObject {
    @Published var token: TuyaToken?
    @Published var devices: [DeviceInfo] = []
    @Published var purifier: Purifier?
    @Published var history: [Sample] = []
    @Published var error: String?
    @Published var loadingDevices = false
    @Published var lastUpdate: Date?
    /// Codes with a command in flight, so the UI can show a spinner instead of flickering.
    @Published var pending: Set<String> = []
    @Published var scenes: [AirScene] = SceneStore.load()
    @Published var keepDisplayOff: Bool = Tweaks.values.keepDisplayOff {
        didSet {
            guard keepDisplayOff != Tweaks.values.keepDisplayOff else { return }
            var t = Tweaks.values
            t.keepDisplayOff = keepDisplayOff
            t.displayCode = purifier?.displayCode
            Tweaks.values = t
            if keepDisplayOff, let p = purifier, let client { Task { await SceneEngine.enforceDisplay(p, client: client); await refresh() } }
        }
    }

    static let shared = AppStore()

    // Wi-Fi (LAN) control
    @Published var local = LocalConfig.stored
    @Published var localDPS: [String: JSONValue] = [:]
    @Published var localChanged: [String: Date] = [:]
    @Published var localState: LocalState = .off
    var link: LocalLink?
    var localTask: Task<Void, Never>?
    var cloudClient: TuyaClient? { client }

    private var client: TuyaClient?
    private var pollTask: Task<Void, Never>?
    private var lastWidgetReload = Date.distantPast

    init() {
        token = TokenStore.load()
        if let token { client = TuyaClient(token: token) }
        purifier = Cache.purifier
        history = History.load()
    }

    // MARK: Session

    func signedIn(_ t: TuyaToken) {
        TokenStore.save(t)
        token = t
        client = TuyaClient(token: t)
        Task { await loadDevices() }
    }

    func signOut() {
        stopPolling()
        TokenStore.clear()
        Cache.clear()
        token = nil
        client = nil
        purifier = nil
        devices = []
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func handle(_ e: Error) {
        if let te = e as? TuyaError, te.isAuth {
            signOut()
            error = te.message
            return
        }
        if (e as? URLError)?.code == .cancelled { return }
        error = e.localizedDescription
    }

    // MARK: Devices

    func loadDevices() async {
        guard let client else { return }
        loadingDevices = true
        defer { loadingDevices = false }
        do {
            let list = try await client.allDevices()
            devices = list.sorted { ($0.isPurifier ? 0 : 1, $0.name) < ($1.isPurifier ? 0 : 1, $1.name) }
            if purifier == nil {
                let purifiers = devices.filter(\.isPurifier)
                if purifiers.count == 1 { await select(purifiers[0]) }
            }
        } catch {
            handle(error)
        }
    }

    func select(_ device: DeviceInfo) async {
        guard let client else { return }
        do {
            let spec = try await client.specification(id: device.id)
            let p = Purifier(info: device, functions: spec.functions, statusSpec: spec.status)
            if p.id != purifier?.id {
                History.clear(); history = []
                stopLocal()
                local = LocalConfig()
                saveLocal()
            }
            purifier = p
            Cache.save(p)
            record(p)
            WidgetCenter.shared.reloadAllTimelines()
            startPolling()
        } catch {
            handle(error)
        }
    }

    func forgetDevice() {
        stopPolling()
        Cache.clear()
        purifier = nil
        Task { await loadDevices() }
    }

    // MARK: Polling

    func startPolling() {
        stopPolling()
        startLocal()
        guard purifier != nil, client != nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        stopLocal()
    }

    func refresh() async {
        if link != nil { await queryLocal() }
        guard let client, let current = purifier else { return }
        do {
            guard let info = try await client.device(id: current.id) else { return }
            // Don't let a stale read undo a command that's still going out.
            var merged = info
            for code in pending { merged.status[code] = purifier?.status[code] }
            var p = purifier ?? current
            let wasOn = p.isOn
            p.info = merged
            purifier = p
            lastUpdate = .now
            Cache.save(p)
            record(p)
            await SceneEngine.afterRefresh(p, client: client)
            if let after = Cache.purifier, after.id == p.id, after.status != p.status, pending.isEmpty {
                purifier = after
            }
            if wasOn != p.isOn || Date().timeIntervalSince(lastWidgetReload) > 300 {
                reloadWidgets()
            }
        } catch {
            handle(error)
        }
    }

    private func record(_ p: Purifier) {
        if let pm = p.pm25 { history = History.append(pm) }
    }

    private func reloadWidgets() {
        lastWidgetReload = .now
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: Commands

    func set(_ code: String, _ value: JSONValue) { setMany([(code, value)]) }

    /// Sends several data points as one command, so the purifier only reacts once. "dp:<id>" codes are raw
    /// local data points; cloud codes go over Wi-Fi too when the local link speaks the same values.
    func setMany(_ commands: [(String, JSONValue)]) {
        guard let before = purifier else { return }
        var localCmds: [String: JSONValue] = [:]
        var viaLocal: [(String, JSONValue)] = []
        var cloudCmds: [(String, JSONValue)] = []
        // In a batch, skip settings that are already right (one-off taps still go through).
        let wanted = commands.count == 1 ? commands : commands.filter { $0.0.hasPrefix("dp:") || before.status[$0.0] != $0.1 }
        for (code, value) in wanted {
            if code.hasPrefix("dp:") {
                localCmds[String(code.dropFirst(3))] = value
            } else if let id = localID(forCloud: code) {
                localCmds[id] = value
                viaLocal.append((code, value))
            } else {
                cloudCmds.append((code, value))
            }
        }
        if !localCmds.isEmpty {
            var p = before
            for (code, value) in viaLocal { p = p.applying(code, value) }
            purifier = p
            Task {
                do {
                    try await sendLocal(localCmds)
                    if let p = purifier { Cache.save(p) }
                    reloadWidgets()
                } catch {
                    if !viaLocal.isEmpty { setCloud(viaLocal) }
                    handle(error)
                }
            }
        }
        if !cloudCmds.isEmpty { setCloud(cloudCmds) }
    }

    private func setCloud(_ commands: [(String, JSONValue)]) {
        guard let client, let before = purifier else { return }
        let cmds = commands.filter { before.status[$0.0] != $0.1 || commands.count == 1 }
        guard !cmds.isEmpty else { return }
        // Turning the display on by hand switches off "keep display off", or the next poll would undo it.
        let displayCode = Tweaks.values.displayCode ?? before.displayCode
        if cmds.contains(where: { $0.0 == displayCode && $0.1.boolValue == true }), Tweaks.values.keepDisplayOff {
            var t = Tweaks.values
            t.keepDisplayOff = false
            Tweaks.values = t
            keepDisplayOff = false
        }
        var old: [String: JSONValue?] = [:]
        var updated = before
        for (code, value) in cmds {
            old.updateValue(before.status[code], forKey: code)
            updated = updated.applying(code, value)
            pending.insert(code)
        }
        purifier = updated
        Task {
            do {
                try await client.send(id: before.id, cmds)
                for (code, _) in cmds { pending.remove(code) }
                if let p = purifier { Cache.save(p) }
                reloadWidgets()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await refresh()
            } catch {
                for (code, _) in cmds { pending.remove(code) }
                if var p = purifier {
                    for (code, value) in old { p.info.status[code] = value }
                    purifier = p
                }
                handle(error)
            }
        }
    }

    func togglePower() {
        guard let p = purifier, let code = p.powerCode else { return }
        set(code, .bool(!p.isOn))
    }

    // MARK: Scenes

    func saveScene(_ s: AirScene) {
        var list = SceneStore.load()
        var scene = s
        scene.armed = true
        if let i = list.firstIndex(where: { $0.id == s.id }) { list[i] = scene } else { list.append(scene) }
        SceneStore.save(list)
        scenes = list
        Geo.shared.sync()
    }

    func deleteScene(_ s: AirScene) {
        let list = SceneStore.load().filter { $0.id != s.id }
        SceneStore.save(list)
        scenes = list
        Geo.shared.sync()
    }

    func runScene(_ s: AirScene) async throws {
        guard let client else { throw TuyaError(message: "Not signed in.") }
        do {
            try await SceneEngine.run(s, purifier: purifier, client: client)
            scenes = SceneStore.load()
            if let p = Cache.purifier, p.id == purifier?.id { purifier = p }
            reloadWidgets()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await refresh()
        } catch {
            handle(error)
            throw error
        }
    }

    // MARK: Background refresh

    static let refreshID = "com.soum91.exhale.refresh"
}
