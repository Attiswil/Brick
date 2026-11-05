import Foundation

/// How a brick or unbrick happened.
enum BrickMethod: String, Codable {
    case manual      // a person pressed a button (app, Shortcut run by hand, HA dashboard)
    case tag         // a registered NFC brick tag was scanned
    case automation  // a Home Assistant automation, or an iOS Shortcuts automation
    case timer       // a timed brick ran out
    case schedule    // an on-device schedule started / ended
    case emergency   // an emergency unbrick was spent
}

enum BrickAction: String, Codable {
    case brick
    case unbrick
    case toggle
    case emergencyUnbrick = "emergency_unbrick"
    case requestReset = "request_emergency_reset"
    case cancelReset = "cancel_emergency_reset"
    case registerTag = "register_tag"
    case removeTag = "remove_tag"
}

/// The rules. Set in the app; locked while bricked.
struct BrickRules: Codable, Equatable {
    /// Refuse manual unbricks. A tag, timer, schedule, Home Assistant
    /// automation or emergency unbrick can still end a brick.
    var strict = true
    var emergencyMax = 5
    /// How long a requested reset takes to refill emergency unbricks.
    var resetHours: Double = 48
    /// Start the reset automatically when the last emergency unbrick is used.
    var autoRequestReset = false
    /// Scanning a brick tag while unbricked bricks the phone.
    var tagToggles = true
}

struct BrickStats: Codable, Equatable {
    var todaySeconds = 0
    var weekSeconds = 0
    var streakDays = 0
    var sessionsTotal = 0
    var longestSessionSeconds = 0
}

/// The live state. Owned by the phone; mirrored to Home Assistant.
struct BrickState: Codable, Equatable {
    var revision = 0
    var bricked = false
    var modeId: String?
    var brickedSince: Date?
    var endsAt: Date?
    var source: String?
    var lastMethod: String?
    var lastChanged: Date?
    var emergencyRemaining = 5
    var emergencyResetAt: Date?
}

/// A command run on the phone, whoever asked for it.
struct BrickCommand: Codable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var action: BrickAction
    var method: BrickMethod = .manual
    var modeId: String?
    var durationMinutes: Double?
    var tagId: String?
    var tagName: String?
    var source: String?
    var occurredAt = Date()
}

/// A command sent by Home Assistant (push or long-poll), snake_case JSON.
struct RemoteCommand: Codable, Equatable, Identifiable {
    var id: String
    var action: BrickAction
    var method: String?
    var modeId: String?
    var modeName: String?
    var durationMinutes: Double?
    var tagId: String?
    var tagName: String?
    var source: String?
    var issuedAt: Date?
    var expiresAt: Date?
}

/// What happened to a command - reported back to Home Assistant.
struct CommandResult: Codable, Equatable {
    var id: String
    var ok: Bool
    var changed = false
    var code: String?
    var message: String?
}

struct LocalSession: Codable, Equatable {
    var start: Date
    var end: Date
    var modeId: String?
    var endedBy: String
}

/// Everything the engine owns. Persisted in the app group.
struct LocalBook: Codable, Equatable {
    var state = BrickState()
    var rules = BrickRules()
    var tags: [String: String] = [:]  // sha256 tag hash -> name
    var sessions: [LocalSession] = []
    /// Ids of remote commands already handled (push and long-poll can both
    /// deliver the same one).
    var handledCommands: [String] = []
}

struct BrickRefusal: LocalizedError, Equatable {
    var code: String
    var message: String
    var errorDescription: String? { message }

    static func strict() -> BrickRefusal {
        BrickRefusal(code: "strict_mode",
                     message: "Strict mode is on: scan your brick, wait for the timer, or use an emergency unbrick.")
    }

    static let locked = BrickRefusal(code: "locked_while_bricked", message: "That's locked while you're bricked.")
}

// MARK: - JSON

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
        // Python can send microseconds; trim the fraction to milliseconds.
        if let dot = s.firstIndex(of: "."),
           let tz = s[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            let frac = s[s.index(after: dot)..<tz].prefix(3)
            return withFraction.date(from: String(s[..<dot]) + "." + String(frac) + String(s[tz...]))
        }
        return nil
    }
}

enum JSON {
    private static func encodeDate(_ date: Date, _ enc: Encoder) throws {
        var c = enc.singleValueContainer()
        try c.encode(ISO8601.string(date))
    }

    private static func decodeDate(_ dec: Decoder) throws -> Date {
        let c = try dec.singleValueContainer()
        let s = try c.decode(String.self)
        guard let date = ISO8601.date(s) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Bad date \(s)")
        }
        return date
    }

    /// Local storage.
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom(encodeDate)
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom(decodeDate)
        return d
    }()

    /// Home Assistant speaks snake_case.
    static let snakeEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .custom(encodeDate)
        return e
    }()

    static let snakeDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom(decodeDate)
        return d
    }()
}
