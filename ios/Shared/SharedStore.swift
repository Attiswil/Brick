import Foundation
import Security

/// App Group storage shared by the app and its extensions.
enum BrickConfig {
    static var appGroup: String {
        Bundle.main.object(forInfoDictionaryKey: "BrickAppGroup") as? String ?? "group.com.example.brickhub"
    }
}

enum JSON {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(ISO8601.string(date))
        }
        return e
    }()

    /// Decodes Home Assistant's snake_case JSON with ISO-8601 dates.
    static let snakeDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = ISO8601.date(s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Bad date \(s)")
            }
            return date
        }
        return d
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = snakeDecoder.dateDecodingStrategy
        return d
    }()
}

enum ISO8601 {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func string(_ d: Date) -> String { withFraction.string(from: d) }

    static func date(_ s: String) -> Date? {
        if let d = withFraction.date(from: s) ?? plain.date(from: s) { return d }
        // Trim long fractions ("…:00.123456+00:00") down to milliseconds.
        if let dot = s.firstIndex(of: "."),
           let tz = s[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            let frac = s[s.index(after: dot)..<tz].prefix(3)
            let trimmed = String(s[..<dot]) + "." + String(frac) + String(s[tz...])
            return withFraction.date(from: trimmed)
        }
        return nil
    }
}

struct HAConnection: Codable, Equatable {
    var baseURL: URL
    var deviceName: String
}

final class SharedStore {
    static let shared = SharedStore()
    let defaults: UserDefaults

    init(suite: String = BrickConfig.appGroup) {
        defaults = UserDefaults(suiteName: suite) ?? .standard
    }

    private func read<T: Decodable>(_ key: String, _ type: T.Type) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSON.decoder.decode(T.self, from: data)
    }

    private func write<T: Encodable>(_ key: String, _ value: T?) {
        if let value, let data = try? JSON.encoder.encode(value) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    var book: LocalBook {
        get { read("book", LocalBook.self) ?? LocalBook() }
        set { write("book", newValue) }
    }

    var modes: [BrickMode] {
        get { read("modes", [BrickMode].self) ?? [] }
        set { write("modes", newValue) }
    }

    var schedules: [BrickSchedule] {
        get { read("schedules", [BrickSchedule].self) ?? [] }
        set { write("schedules", newValue) }
    }

    var pending: [PendingCommand] {
        get { read("pending", [PendingCommand].self) ?? [] }
        set { write("pending", newValue) }
    }

    var connection: HAConnection? {
        get { read("connection", HAConnection.self) }
        set { write("connection", newValue) }
    }

    var apnsToken: String? {
        get { defaults.string(forKey: "apnsToken") }
        set { defaults.set(newValue, forKey: "apnsToken") }
    }

    var lastSync: Date? {
        get { defaults.object(forKey: "lastSync") as? Date }
        set { defaults.set(newValue, forKey: "lastSync") }
    }

    var deviceId: String {
        if let id = defaults.string(forKey: "deviceId") { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: "deviceId")
        return id
    }

    func mode(_ id: String?) -> BrickMode? {
        guard let id else { return nil }
        return modes.first { $0.id == id }
    }

    /// Read-modify-write the book.
    @discardableResult
    func updateBook<T>(_ body: (inout LocalBook) throws -> T) rethrows -> T {
        var b = book
        let result = try body(&b)
        book = b
        return result
    }

    func enqueue(_ cmd: PendingCommand) {
        pending = pending + [cmd]
    }

    // MARK: Token (Keychain, shared through the app group)

    private let tokenAccount = "ha-token"

    var token: String? {
        get {
            var query = keychainQuery()
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: AnyObject?
            guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
                  let data = out as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        set {
            SecItemDelete(keychainQuery() as CFDictionary)
            guard let newValue, !newValue.isEmpty else { return }
            var query = keychainQuery()
            query[kSecValueData as String] = Data(newValue.utf8)
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(query as CFDictionary, nil)
        }
    }

    private func keychainQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "brickhub",
            kSecAttrAccount as String: tokenAccount,
            kSecAttrAccessGroup as String: BrickConfig.appGroup,
        ]
    }
}
