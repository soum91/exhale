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
            if p.id != purifier?.id { History.clear(); history = [] }
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
    }

    func refresh() async {
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

    func set(_ code: String, _ value: JSONValue) {
        guard let client, let before = purifier else { return }
        // Turning the display on by hand switches off "keep display off", or the next poll would undo it.
        if code == (Tweaks.values.displayCode ?? before.displayCode), value.boolValue == true, Tweaks.values.keepDisplayOff {
            var t = Tweaks.values
            t.keepDisplayOff = false
            Tweaks.values = t
            keepDisplayOff = false
        }
        let old = before.status[code]
        purifier = before.applying(code, value)
        pending.insert(code)
        Task {
            do {
                try await client.send(id: before.id, [(code, value)])
                pending.remove(code)
                if let p = purifier { Cache.save(p) }
                reloadWidgets()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await refresh()
            } catch {
                pending.remove(code)
                if var p = purifier {
                    p.info.status[code] = old
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
