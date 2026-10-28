import Foundation
import Network
import SwiftUI

/// the Keystone Bridge (ESP32) puts devices in Apple Home. Exhale pairs with it on its own token and
/// sends the purifier: address, local key and which data point does what. The bridge talks to the
/// purifier itself after that, so Home works with this phone asleep or away.
struct HomeBridgeLink: Codable, Equatable {
    var host = ""
    var port = 8080
    var token = ""
    var lastSent: Date?

    var isSet: Bool { !host.isEmpty && !token.isEmpty }

    static var stored: HomeBridgeLink {
        get {
            guard let d = UserDefaults.standard.data(forKey: "homeBridge"),
                  let v = try? JSONDecoder().decode(HomeBridgeLink.self, from: d) else { return HomeBridgeLink() }
            return v
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "homeBridge") }
    }
}

enum HomeBridgeError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}

enum HomeBridgeAPI {
    static let app = "exhale"

    static func url(_ host: String, _ port: Int, _ path: String) -> URL? { URL(string: "http://\(host):\(port)\(path)") }

    static func info(host: String, port: Int) async throws -> [String: Any] {
        guard let u = url(host, port, "/api/info") else { throw HomeBridgeError.message("Bad address.") }
        var req = URLRequest(url: u)
        req.timeoutInterval = 4
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["app"] as? String == "afterglow-bridge" else { throw HomeBridgeError.message("That isn't a Keystone Bridge.") }
        return obj
    }

    static func claim(host: String, port: Int) async throws -> String {
        guard let u = url(host, port, "/api/dev/claim?app=\(app)") else { throw HomeBridgeError.message("Bad address.") }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.timeoutInterval = 5
        let (data, resp) = try await URLSession.shared.data(for: req)
        if (resp as? HTTPURLResponse)?.statusCode == 409 {
            throw HomeBridgeError.message("The bridge is already paired with Exhale on another install. In Keystone › Bridge, tap Reset next to Exhale, then pair here again.")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any], let t = obj["token"] as? String else {
            throw HomeBridgeError.message("The bridge didn't hand out a token. Update its firmware from Afterglow.")
        }
        return t
    }

    /// True when the bridge restarts to add the device to Home.
    static func send(_ body: [String: Any], _ link: HomeBridgeLink) async throws -> Bool {
        guard let u = url(link.host, link.port, "/api/dev/config?app=\(app)") else { throw HomeBridgeError.message("Bad address.") }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.timeoutInterval = 8
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(link.token, forHTTPHeaderField: "X-Device-Token")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw HomeBridgeError.message("The bridge doesn't know this phone anymore. Forget it here and pair again.") }
        guard code == 200, let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HomeBridgeError.message("Bridge said: \(String(decoding: data, as: UTF8.self))")
        }
        return obj["restart"] as? Bool ?? false
    }
}

/// Finds bridges by Bonjour (_afterglow._tcp).
@MainActor
final class HomeBridgeFinder: ObservableObject {
    struct Found: Hashable { var name: String; var host: String; var port: Int }
    @Published var found: [Found] = []
    @Published var searching = false
    private var browser: NWBrowser?

    func start() {
        stop()
        searching = true
        found = []
        let b = NWBrowser(for: .bonjour(type: "_afterglow._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            for r in results {
                guard case .service(let name, _, _, _) = r.endpoint else { continue }
                Task { await self?.resolve(r.endpoint, name: name) }
            }
        }
        b.start(queue: .main)
        browser = b
        Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            searching = false
        }
    }

    func stop() {
        browser?.cancel()
        browser = nil
        searching = false
    }

    private func resolve(_ endpoint: NWEndpoint, name: String) async {
        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let c = NWConnection(to: endpoint, using: params)
        let result: (String, Int)? = await withCheckedContinuation { cont in
            let once = OnceFlag()
            c.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case .hostPort(let h, let p)? = c.currentPath?.remoteEndpoint, once.fire() {
                        var host = "\(h)"
                        if let pct = host.firstIndex(of: "%") { host = String(host[..<pct]) }
                        cont.resume(returning: (host, Int(p.rawValue)))
                    } else if once.fire() { cont.resume(returning: nil) }
                    c.cancel()
                case .failed, .cancelled:
                    if once.fire() { cont.resume(returning: nil) }
                default: break
                }
            }
            c.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 4) {
                if once.fire() { cont.resume(returning: nil); c.cancel() }
            }
        }
        guard let r = result, !found.contains(where: { $0.host == r.0 }) else { return }
        found.append(Found(name: name, host: r.0, port: r.1))
    }
}

// MARK: - What Exhale sends

extension AppStore {
    /// Local data point ids for everything Home needs. Nil (with a reason) if something is missing.
    func homeBridgeConfig() -> (body: [String: Any]?, problem: String?) {
        guard let p = purifier else { return (nil, "Pick your purifier first.") }
        guard let key = p.info.localKey, key.count == 16 else { return (nil, "Tuya didn't send this purifier's local key. Sign in again.") }
        guard let host = local.host else { return (nil, "Set up Wi-Fi control first (Settings › Wi-Fi control) so Exhale knows the purifier's address.") }
        let byCode = Dictionary(local.codeMap.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
        func dp(_ code: String?) -> String? { code.flatMap { byCode[$0] } }
        guard let sw = dp(p.powerCode) else { return (nil, "Couldn't map the power switch to a Wi-Fi data point yet. Open Wi-Fi control once while connected.") }

        var o: [String: Any] = ["id": p.id, "name": p.name, "key": key, "ip": host, "ver": local.version ?? 3.3, "sw": sw]
        if let pm = dp(p.pm25Code) {
            o["pm"] = pm
            o["pmDiv"] = p.pm25Code.flatMap { p.spec($0)?.divisor } ?? 1
        }
        if let m = p.modeCode, let mdp = dp(m), let range = p.functions[m]?.range,
           let auto = range.first(where: { $0.lowercased() == "auto" || $0.lowercased() == "smart" }),
           let manual = range.first(where: { $0.lowercased() == "manual" }) {
            o["mode"] = mdp
            o["modeAuto"] = auto
            o["modeManual"] = manual
        }
        if let fan = local.fanDP, !local.fanValues.isEmpty {
            o["fan"] = fan
            o["fanValues"] = local.fanValues.map(\.any)
        }
        if let lock = p.toggles.first(where: { $0.title == "Child lock" }), let ldp = dp(lock.code) { o["lock"] = ldp }
        if p.filterFraction != nil, let f = p.filterCode, let fdp = dp(f) {
            o["filter"] = fdp
            o["filterMax"] = Int(p.spec(f)?.max ?? 100)
        }
        if let d = local.displayDP {
            o["display"] = d
            o["displayInverted"] = local.displayInverted
            o["keepDisplayOff"] = keepDisplayOff
        }
        return (["utcOffset": TimeZone.current.secondsFromGMT(), "purifier": o], nil)
    }
}

// MARK: - Screen

struct HomeBridgeView: View {
    @EnvironmentObject var store: AppStore
    @StateObject private var finder = HomeBridgeFinder()
    @State private var link = HomeBridgeLink.stored
    @State private var status: String?
    @State private var busy = false
    @State private var manualHost = ""
    @State private var bridgeName: String?

    var body: some View {
        List {
            Section {
                Text("the Keystone Bridge (ESP32) can put the purifier in Apple Home: a purifier tile with speed and auto, a PM2.5 air quality sensor, filter life, child lock and a display switch. If \"Keep display off\" is on, the bridge keeps knocking the display back off around the clock, even with this phone away.")
                    .font(.footnote)
            }

            if link.isSet {
                Section {
                    LabeledContent("Bridge", value: bridgeName ?? link.host)
                    if let d = link.lastSent { LabeledContent("Last sent", value: d.formatted(date: .abbreviated, time: .shortened)) }
                    Button { Task { await send() } } label: {
                        Label(busy ? "Sending…" : "Send purifier to Apple Home", systemImage: "arrow.up.circle")
                    }
                    .disabled(busy)
                    Button("Forget this bridge", role: .destructive) {
                        link = HomeBridgeLink()
                        HomeBridgeLink.stored = link
                        finder.start()
                    }
                } footer: {
                    Text("Send again after you change Keep display off, re-pair the purifier or its address changes. The first send restarts the bridge (about 20 s) so Home sees the new tiles.")
                }
            } else {
                Section {
                    if finder.searching { HStack { ProgressView(); Text("Looking for the bridge…") } }
                    ForEach(finder.found, id: \.self) { f in
                        Button { Task { await pair(f.host, f.port) } } label: { LabeledContent(f.name, value: f.host) }
                    }
                    Button("Search again") { finder.start() }
                    HStack {
                        TextField("Or type its IP", text: $manualHost).keyboardType(.decimalPad)
                        Button("Pair") { Task { await pair(manualHost.trimmingCharacters(in: .whitespaces), 8080) } }
                            .disabled(manualHost.isEmpty)
                    }
                } header: {
                    Text("Pair")
                } footer: {
                    Text("No bridge yet? Set one up with the Keystone app.")
                }
            }
            if let status { Section { Text(status).font(.footnote) } }
        }
        .navigationTitle("Apple Home")
        .onAppear {
            link = HomeBridgeLink.stored
            if !link.isSet { finder.start() }
        }
        .onDisappear { finder.stop() }
    }

    private func pair(_ host: String, _ port: Int) async {
        guard !host.isEmpty else { return }
        busy = true
        defer { busy = false }
        do {
            let info = try await HomeBridgeAPI.info(host: host, port: port)
            bridgeName = "Keystone Bridge \(info["version"] as? String ?? "")"
            let token = try await HomeBridgeAPI.claim(host: host, port: port)
            link = HomeBridgeLink(host: host, port: port, token: token)
            HomeBridgeLink.stored = link
            busy = false
            await send()
        } catch {
            status = "Couldn't pair: \(error.localizedDescription)"
        }
    }

    private func send() async {
        let built = store.homeBridgeConfig()
        guard let body = built.body else { status = built.problem; return }
        busy = true
        defer { busy = false }
        do {
            let restart = try await HomeBridgeAPI.send(body, link)
            link.lastSent = .now
            HomeBridgeLink.stored = link
            status = restart ? "Sent. The bridge is restarting to add the purifier to Apple Home (about 20 s). It shows up under the bridge in the Home app; no new pairing needed."
                             : "Sent. Apple Home is up to date."
        } catch {
            status = error.localizedDescription
        }
    }
}
