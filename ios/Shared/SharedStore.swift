import Foundation
import Security

/// App Group storage shared by the app and its extensions.
enum BrickConfig {
    static var appGroup: String {
        Bundle.main.object(forInfoDictionaryKey: "BrickAppGroup") as? String ?? "group.com.example.brickhub"
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

    /// Results of Home Assistant commands not yet reported back.
    var unsentResults: [CommandResult] {
        get { read("unsentResults", [CommandResult].self) ?? [] }
        set { write("unsentResults", newValue) }
    }

    /// Set when the state changed somewhere without network (an extension),
    /// so the app reports to Home Assistant next time it runs.
    var needsReport: Bool {
        get { defaults.bool(forKey: "needsReport") }
        set { defaults.set(newValue, forKey: "needsReport") }
    }

    var connection: HAConnection? {
        get { read("connection", HAConnection.self) }
        set { write("connection", newValue) }
    }

    var apnsToken: String? {
        get { defaults.string(forKey: "apnsToken") }
        set { defaults.set(newValue, forKey: "apnsToken") }
    }

    var lastReport: Date? {
        get { defaults.object(forKey: "lastReport") as? Date }
        set { defaults.set(newValue, forKey: "lastReport") }
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

    var modeNames: [String: String] {
        Dictionary(modes.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
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
