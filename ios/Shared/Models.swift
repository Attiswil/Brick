import Foundation
import FamilyControls

/// How a brick or unbrick happened. Mirrors `Method` in engine.py.
enum BrickMethod: String, Codable {
    case manual, tag, automation, timer, schedule, emergency
}

/// Commands. Mirrors `Action` in engine.py.
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

struct BrickStats: Codable, Equatable {
    var todaySeconds = 0
    var weekSeconds = 0
    var streakDays = 0
    var sessionsTotal = 0
    var longestSessionSeconds = 0
}

/// The brick state. When connected, Home Assistant is the source of truth
/// and this is a mirror; offline (or standalone) the app's own engine owns it.
struct BrickState: Codable, Equatable {
    var revision = 0
    var bricked = false
    var modeId: String?
    var modeName: String?
    var defaultModeId: String?
    var brickedSince: Date?
    var endsAt: Date?
    var source: String?
    var lastMethod: String?
    var lastChanged: Date?
    var emergencyRemaining = 5
    var emergencyMax = 5
    var emergencyResetAt: Date?
    var resetHours: Double = 48
    var strict = true
    var tagCount = 0
    var stats: BrickStats?

    init() {}

    enum CodingKeys: String, CodingKey {
        case revision, bricked, modeId, modeName, defaultModeId, brickedSince, endsAt,
             source, lastMethod, lastChanged, emergencyRemaining, emergencyMax,
             emergencyResetAt, resetHours, strict, tagCount, stats
    }

    // Tolerant decoding: missing keys keep their defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        bricked = try c.decodeIfPresent(Bool.self, forKey: .bricked) ?? false
        modeId = try c.decodeIfPresent(String.self, forKey: .modeId)
        modeName = try c.decodeIfPresent(String.self, forKey: .modeName)
        defaultModeId = try c.decodeIfPresent(String.self, forKey: .defaultModeId)
        brickedSince = try c.decodeIfPresent(Date.self, forKey: .brickedSince)
        endsAt = try c.decodeIfPresent(Date.self, forKey: .endsAt)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        lastMethod = try c.decodeIfPresent(String.self, forKey: .lastMethod)
        lastChanged = try c.decodeIfPresent(Date.self, forKey: .lastChanged)
        emergencyRemaining = try c.decodeIfPresent(Int.self, forKey: .emergencyRemaining) ?? 5
        emergencyMax = try c.decodeIfPresent(Int.self, forKey: .emergencyMax) ?? 5
        emergencyResetAt = try c.decodeIfPresent(Date.self, forKey: .emergencyResetAt)
        resetHours = try c.decodeIfPresent(Double.self, forKey: .resetHours) ?? 48
        strict = try c.decodeIfPresent(Bool.self, forKey: .strict) ?? true
        tagCount = try c.decodeIfPresent(Int.self, forKey: .tagCount) ?? 0
        stats = try c.decodeIfPresent(BrickStats.self, forKey: .stats)
    }
}

/// The compact state Home Assistant puts in a push payload (`brick` key).
struct PushState: Decodable {
    var rev: Int
    var bricked: Bool
    var modeId: String?
    var since: Date?
    var endsAt: Date?
    var em: Int
    var emMax: Int
    var emReset: Date?
    var strict: Bool
    var src: String?
    var method: String?

    func merged(into base: BrickState) -> BrickState {
        var s = base
        s.revision = rev
        s.bricked = bricked
        s.modeId = modeId
        s.brickedSince = since
        s.endsAt = endsAt
        s.emergencyRemaining = em
        s.emergencyMax = emMax
        s.emergencyResetAt = emReset
        s.strict = strict
        s.source = src
        s.lastMethod = method
        return s
    }
}

enum BlockStyle: String, Codable, CaseIterable, Identifiable {
    case blockList, allowList
    var id: String { rawValue }
    var label: String { self == .blockList ? "Block selected" : "Allow only selected" }
}

/// A mode: which apps/sites to block. Apple only exposes the selection as
/// opaque tokens on this device, so modes live here and only their id and
/// name are shared with Home Assistant.
struct BrickMode: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var selection = FamilyActivitySelection()
    var style: BlockStyle = .blockList
    var preventAppRemoval = true

    var summary: String {
        let apps = selection.applicationTokens.count
        let cats = selection.categoryTokens.count
        let webs = selection.webDomainTokens.count
        var parts: [String] = []
        if apps > 0 { parts.append("\(apps) app\(apps == 1 ? "" : "s")") }
        if cats > 0 { parts.append("\(cats) categor\(cats == 1 ? "y" : "ies")") }
        if webs > 0 { parts.append("\(webs) site\(webs == 1 ? "" : "s")") }
        let what = parts.isEmpty ? "nothing selected" : parts.joined(separator: ", ")
        return style == .blockList ? "Blocks \(what)" : "Allows only \(what)"
    }
}

/// An on-device schedule. Runs even with no network (via DeviceActivity).
struct BrickSchedule: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var modeId: String?
    var startMinutes = 22 * 60
    var endMinutes = 7 * 60
    /// Calendar weekdays, 1 = Sunday ... 7 = Saturday.
    var weekdays: Set<Int> = Set(1...7)
    var enabled = true

    var timeLabel: String {
        func fmt(_ m: Int) -> String {
            var c = DateComponents(); c.hour = m / 60; c.minute = m % 60
            let d = Calendar.current.date(from: c) ?? Date()
            return d.formatted(date: .omitted, time: .shortened)
        }
        return "\(fmt(startMinutes)) – \(fmt(endMinutes))"
    }
}

/// A command waiting to be sent to Home Assistant (made while offline, or
/// by an extension, which has no network access).
struct PendingCommand: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString  // doubles as the idempotency event_id
    var action: BrickAction
    var method: BrickMethod = .manual
    var modeId: String?
    var durationMinutes: Double?
    var tagId: String?
    var tagName: String?
    var source: String?
    var occurredAt = Date()
}

struct LocalSession: Codable, Equatable {
    var start: Date
    var end: Date
    var modeId: String?
    var endedBy: String
}

/// Everything the local engine needs.
struct LocalBook: Codable, Equatable {
    var state = BrickState()
    var tags: [String: String] = [:]  // sha256 hash -> name
    var sessions: [LocalSession] = []
}

struct BrickRefusal: LocalizedError, Equatable {
    var code: String
    var message: String
    var errorDescription: String? { message }
}
