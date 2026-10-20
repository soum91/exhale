import Foundation

/// A record of every background refresh attempt, so we can see whether iOS ran the widget or
/// background refresh overnight, and whether it got a reading.
struct RefreshEntry: Codable, Hashable, Identifiable {
    var id = UUID()
    var date: Date
    var source: String
    var ok: Bool
    var pm: Double?
    var note: String?
}

enum RefreshLog {
    private static let file = "refresh-log.json"
    static func load() -> [RefreshEntry] { AppGroup.read([RefreshEntry].self, file) ?? [] }

    static func add(_ source: String, ok: Bool, pm: Double? = nil, note: String? = nil) {
        var list = load()
        list.append(RefreshEntry(date: .now, source: source, ok: ok, pm: pm, note: note))
        if list.count > 400 { list.removeFirst(list.count - 400) }
        AppGroup.write(list, file)
    }

    static func clear() { AppGroup.remove(file) }
}
