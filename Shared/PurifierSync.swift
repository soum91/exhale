import Foundation
import AppIntents
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Refresh/command paths that run outside the app UI: the widget, background refresh and Shortcuts.
enum PurifierSync {
    /// Pulls the latest status, logs PM2.5 and updates the cached copy. Returns the cache on failure.
    @discardableResult
    static func refresh() async -> Purifier? {
        guard let token = TokenStore.load(), var p = Cache.purifier else { return Cache.purifier }
        let client = TuyaClient(token: token)
        do {
            if let info = try await client.device(id: p.id) {
                p.info = info
                Cache.save(p)
                if let pm = p.pm25 { History.append(pm) }
                await SceneEngine.afterRefresh(p, client: client)
                p = Cache.purifier ?? p
            }
        } catch {
            // Keep showing the last good reading.
        }
        return p
    }

    static func send(_ code: String, _ value: JSONValue) async throws {
        guard let token = TokenStore.load(), let p = Cache.purifier else {
            throw TuyaError(message: "Open Exhale and sign in first.")
        }
        let client = TuyaClient(token: token)
        try await client.send(id: p.id, [(code, value)])
        Cache.save(p.applying(code, value))
    }

    static func setPower(_ on: Bool?) async throws {
        guard let p = Cache.purifier, let code = p.powerCode else {
            throw TuyaError(message: "This device has no power switch.")
        }
        try await send(code, .bool(on ?? !p.isOn))
    }
}

struct TogglePurifierIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Air Purifier"
    static let description: IntentDescription? = IntentDescription("Turns the air purifier on or off.")

    func perform() async throws -> some IntentResult {
        try await PurifierSync.setPower(nil)
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
        return .result()
    }
}

struct SetPurifierPowerIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Air Purifier Power"
    static let description: IntentDescription? = IntentDescription("Turns the air purifier on or off.")

    @Parameter(title: "On")
    var on: Bool

    init() {}
    init(on: Bool) { self.on = on }

    func perform() async throws -> some IntentResult {
        try await PurifierSync.setPower(on)
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
        return .result()
    }
}

struct AirQualityIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Air Quality"
    static let description: IntentDescription? = IntentDescription("Reads the purifier's current PM2.5.")

    func perform() async throws -> some IntentResult & ReturnsValue<Double> & ProvidesDialog {
        let p = await PurifierSync.refresh()
        guard let pm = p?.pm25 else { throw TuyaError(message: "No PM2.5 reading yet.") }
        let text = "PM2.5 is \(Fmt.num(pm.rounded())) µg/m³, \(AQ.label(pm).lowercased())."
        return .result(value: pm, dialog: IntentDialog(stringLiteral: text))
    }
}
