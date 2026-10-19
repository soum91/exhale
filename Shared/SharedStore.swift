import Foundation

/// Files shared between the app and the widget through the App Group container.
enum AppGroup {
    static let defaultID = "group.com.soum91.exhale"

    /// AltStore rewrites group IDs and lists the real ones under ALTAppGroups, so try those first.
    static var containerURL: URL { resolved.url }

    /// False when the sideload stripped the App Group, so the widget can't see the app's data.
    static var isShared: Bool { resolved.shared }

    private static let resolved: (url: URL, shared: Bool) = {
        var ids: [String] = []
        for bundle in [Bundle.main, appBundle].compactMap({ $0 }) {
            if let alt = bundle.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] { ids += alt }
        }
        ids.append(defaultID)
        for id in ids {
            if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) {
                return (url, true)
            }
        }
        let fallback = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return (fallback, false)
    }()

    /// The containing app's bundle when running inside the widget extension.
    private static var appBundle: Bundle? {
        let url = Bundle.main.bundleURL
        guard url.pathExtension == "appex" else { return nil }
        return Bundle(url: url.deletingLastPathComponent().deletingLastPathComponent())
    }

    static func file(_ name: String) -> URL { containerURL.appendingPathComponent(name) }

    static func read<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let data = try? Data(contentsOf: file(name)) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        return try? dec.decode(T.self, from: data)
    }

    static func write<T: Encodable>(_ value: T, _ name: String) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        guard let data = try? enc.encode(value) else { return }
        try? data.write(to: file(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func remove(_ name: String) { try? FileManager.default.removeItem(at: file(name)) }
}

enum TokenStore {
    static func load() -> TuyaToken? { AppGroup.read(TuyaToken.self, "token.json") }
    static func save(_ t: TuyaToken) { AppGroup.write(t, "token.json") }
    static func clear() { AppGroup.remove("token.json") }
}

/// What the widget needs, small and fast to read.
struct Snapshot: Codable, Hashable {
    var deviceID: String
    var name: String
    var pm25: Double?
    var isOn: Bool
    var hasPower: Bool
    var online: Bool
    var speed: String?
    var updated: Date

    static let preview = Snapshot(deviceID: "", name: "Air Purifier", pm25: 7, isOn: true, hasPower: true, online: true, speed: "2", updated: .now)
}

enum Cache {
    static var purifier: Purifier? { AppGroup.read(Purifier.self, "purifier.json") }
    static var snapshot: Snapshot? { AppGroup.read(Snapshot.self, "snapshot.json") }

    static func save(_ p: Purifier) {
        AppGroup.write(p, "purifier.json")
        var speed: String? = nil
        if let code = p.speedCode, let v = p.string(code) { speed = Fmt.label(v) }
        AppGroup.write(Snapshot(deviceID: p.id, name: p.name, pm25: p.pm25, isOn: p.isOn,
                                hasPower: p.powerCode != nil, online: p.info.online,
                                speed: speed, updated: .now), "snapshot.json")
    }

    static func clear() {
        AppGroup.remove("purifier.json")
        AppGroup.remove("snapshot.json")
    }
}
