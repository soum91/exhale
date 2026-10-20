import Foundation
import CryptoKit

/// Pulls real PM2.5 history from Tuya's cloud device log through the Tuya developer (IoT Platform) API.
/// The Smart Life login Exhale normally uses can't read logs, so this needs the user's own free cloud project.
struct CloudHistoryConfig: Codable, Equatable {
    var accessID = ""
    var secret = ""
    var host = "https://openapi.tuyaus.com"
    var lastFetched: Date?
    var lastResult: String?

    var isSet: Bool { !accessID.isEmpty && !secret.isEmpty }

    static var stored: CloudHistoryConfig {
        get { AppGroup.read(CloudHistoryConfig.self, "cloud-history.json") ?? CloudHistoryConfig() }
        set { AppGroup.write(newValue, "cloud-history.json") }
    }

    static let regions: [(name: String, host: String)] = [
        ("Western America", "https://openapi.tuyaus.com"),
        ("Eastern America", "https://openapi-ueaz.tuyaus.com"),
        ("Central Europe", "https://openapi.tuyaeu.com"),
        ("Western Europe", "https://openapi-weaz.tuyaeu.com"),
        ("India", "https://openapi.tuyain.com"),
        ("China", "https://openapi.tuyacn.com"),
    ]
}

actor TuyaOpenAPI {
    private let cfg: CloudHistoryConfig
    private var token: String?
    private var tokenExpiry = Date.distantPast

    init(_ cfg: CloudHistoryConfig) { self.cfg = cfg }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func sign(_ s: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(s.utf8), using: SymmetricKey(data: Data(cfg.secret.utf8)))
        return mac.map { String(format: "%02X", $0) }.joined()
    }

    /// path must include the query string with keys sorted, e.g. "/v1.0/token?grant_type=1".
    private func get(_pathAndQuery: String, withToken: Bool) async throws -> Any? {
        let t = String(Int64(Date().timeIntervalSince1970 * 1000))
        let nonce = UUID().uuidString.lowercased()
        let stringToSign = "GET\n" + sha256Hex(Data()) + "\n\n" + _pathAndQuery
        let tok = withToken ? (token ?? "") : ""
        let signature = sign(cfg.accessID + tok + t + nonce + stringToSign)
        guard let url = URL(string: cfg.host + _pathAndQuery) else { throw TuyaError(message: "Bad URL") }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue(cfg.accessID, forHTTPHeaderField: "client_id")
        req.setValue(signature, forHTTPHeaderField: "sign")
        req.setValue(t, forHTTPHeaderField: "t")
        req.setValue(nonce, forHTTPHeaderField: "nonce")
        req.setValue("HMAC-SHA256", forHTTPHeaderField: "sign_method")
        if withToken { req.setValue(tok, forHTTPHeaderField: "access_token") }
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TuyaError(message: "Unexpected reply from Tuya developer API")
        }
        guard obj["success"] as? Bool == true else {
            throw TuyaError(message: "\(obj["msg"] as? String ?? "Request failed") (\(obj["code"].map { "\($0)" } ?? "?"))")
        }
        return obj["result"]
    }

    private func ensureToken() async throws {
        if token != nil, tokenExpiry.timeIntervalSinceNow > 60 { return }
        token = nil
        let r = try await get(_pathAndQuery: "/v1.0/token?grant_type=1", withToken: false) as? [String: Any]
        guard let tok = r?["access_token"] as? String else { throw TuyaError(message: "No token from Tuya developer API") }
        token = tok
        let expire = (r?["expire_time"] as? NSNumber)?.doubleValue ?? 3600
        tokenExpiry = Date().addingTimeInterval(expire)
    }

    private static func query(_ items: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return items.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&")
    }

    /// Reported values of one data point between two dates, oldest first.
    func reportLog(deviceID: String, code: String, from: Date, to: Date, maxPages: Int = 60) async throws -> [Sample] {
        try await ensureToken()
        var out: [Sample] = []
        var rowKey: String?
        let start = String(Int64(from.timeIntervalSince1970 * 1000))
        let end = String(Int64(to.timeIntervalSince1970 * 1000))
        var useV1 = false
        for _ in 0..<maxPages {
            var r: [String: Any]?
            if !useV1 {
                var q = ["codes": code, "start_time": start, "end_time": end, "size": "100"]
                if let rowKey { q["last_row_key"] = rowKey }
                do {
                    r = try await get(_pathAndQuery: "/v2.0/cloud/thing/\(deviceID)/report-logs?" + Self.query(q), withToken: true) as? [String: Any]
                } catch {
                    if out.isEmpty && rowKey == nil { useV1 = true } else { throw error }
                }
            }
            if useV1 {
                var q = ["type": "7", "codes": code, "start_time": start, "end_time": end, "size": "100"]
                if let rowKey { q["start_row_key"] = rowKey }
                r = try await get(_pathAndQuery: "/v1.0/devices/\(deviceID)/logs?" + Self.query(q), withToken: true) as? [String: Any]
            }
            let logs = r?["logs"] as? [[String: Any]] ?? []
            for l in logs {
                guard (l["code"] as? String) == code,
                      let ms = (l["event_time"] as? NSNumber)?.doubleValue,
                      let v = (l["value"] as? NSNumber)?.doubleValue ?? (l["value"] as? String).flatMap(Double.init) else { continue }
                out.append(Sample(t: Date(timeIntervalSince1970: ms / 1000), pm: v))
            }
            let more = (r?["has_more"] as? Bool) ?? (r?["has_next"] as? Bool) ?? false
            rowKey = (r?["last_row_key"] as? String) ?? (r?["next_row_key"] as? String)
            if !more || rowKey == nil || logs.isEmpty { break }
        }
        return out.sorted { $0.t < $1.t }
    }
}

enum CloudBackfill {
    /// Fills the local history with the cloud's record since the last fetch (up to 7 days back).
    @discardableResult
    static func run() async -> String? {
        var cfg = CloudHistoryConfig.stored
        guard cfg.isSet, let p = Cache.purifier, let code = p.pm25Code else { return nil }
        let to = Date()
        let from = max(cfg.lastFetched?.addingTimeInterval(-600) ?? .distantPast, to.addingTimeInterval(-7 * 86400))
        let api = TuyaOpenAPI(cfg)
        let result: String
        do {
            let samples = try await api.reportLog(deviceID: p.id, code: code, from: from, to: to)
            let scale = p.spec(code)?.divisor ?? 1
            History.merge(samples.map { Sample(t: $0.t, pm: $0.pm / scale) })
            cfg.lastFetched = to
            result = "Got \(samples.count) readings from the cloud"
        } catch {
            result = "Cloud history failed: \(error.localizedDescription)"
        }
        cfg.lastResult = result
        CloudHistoryConfig.stored = cfg
        return result
    }
}
