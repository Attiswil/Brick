import CryptoKit
import Foundation

/// Offline / standalone engine. A deliberate mirror of
/// `custom_components/brick_hub/engine.py` - keep the rules identical.
enum BrickEngine {
    static let historyDays = 90

    // MARK: Tags

    /// Same normalisation + salt as the Python side, so a UID scanned on the
    /// phone matches ESPHome readers and tags registered in Home Assistant.
    static func hashTag(_ raw: String) -> String? {
        let norm = raw.uppercased().filter { $0.isLetter || $0.isNumber }
        guard !norm.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data("brick_hub:\(norm)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func isKnownTag(_ book: LocalBook, _ tagId: String?) -> Bool {
        guard let tagId, let h = hashTag(tagId) else { return false }
        return book.tags[h] != nil
    }

    // MARK: Commands

    /// Applies a command locally. Throws `BrickRefusal` when the rules say no.
    @discardableResult
    static func apply(_ cmd: PendingCommand, to book: inout LocalBook, now: Date = Date()) throws -> Bool {
        let at = min(cmd.occurredAt, now)
        var action = cmd.action
        if action == .toggle { action = book.state.bricked ? .unbrick : .brick }
        switch action {
        case .brick:
            return brick(&book, cmd: cmd, at: at)
        case .unbrick:
            return try unbrick(&book, method: cmd.method, tagId: cmd.tagId, source: cmd.source, at: at)
        case .emergencyUnbrick:
            return try emergency(&book, at: at)
        case .requestReset:
            return try requestReset(&book, now: now)
        case .cancelReset:
            guard book.state.emergencyResetAt != nil else { return false }
            book.state.emergencyResetAt = nil
            return true
        case .registerTag:
            guard !book.state.bricked else {
                throw BrickRefusal(code: "locked_while_bricked", message: "Can't add brick tags while bricked")
            }
            guard let raw = cmd.tagId, let h = hashTag(raw) else {
                throw BrickRefusal(code: "invalid", message: "Couldn't read that tag")
            }
            let name = (cmd.tagName?.isEmpty == false) ? cmd.tagName! : "Brick \(book.tags.count + 1)"
            book.tags[h] = name
            book.state.tagCount = book.tags.count
            return true
        case .removeTag:
            guard !book.state.bricked else {
                throw BrickRefusal(code: "locked_while_bricked", message: "Can't remove brick tags while bricked")
            }
            let key = cmd.tagId.flatMap { book.tags[$0] != nil ? $0 : hashTag($0) }
            guard let key, book.tags.removeValue(forKey: key) != nil else {
                throw BrickRefusal(code: "unknown_tag", message: "Tag isn't registered")
            }
            book.state.tagCount = book.tags.count
            return true
        case .toggle:
            return false  // unreachable
        }
    }

    private static func brick(_ book: inout LocalBook, cmd: PendingCommand, at: Date) -> Bool {
        let newEnd = cmd.durationMinutes.map { at.addingTimeInterval($0 * 60) }
        if !book.state.bricked {
            book.state.bricked = true
            book.state.modeId = cmd.modeId ?? book.state.modeId ?? book.state.defaultModeId
            book.state.brickedSince = at
            book.state.endsAt = newEnd
            book.state.source = cmd.source
            book.state.lastMethod = cmd.method.rawValue
            book.state.lastChanged = at
            return true
        }
        // Already bricked: stricter only.
        var changed = false
        if let mode = cmd.modeId, mode != book.state.modeId,
           !(book.state.strict && cmd.method == .manual) {
            book.state.modeId = mode
            changed = true
        }
        if let end = book.state.endsAt, newEnd == nil || newEnd! > end {
            book.state.endsAt = newEnd
            changed = true
        }
        return changed
    }

    private static func endSession(_ book: inout LocalBook, at: Date, by method: BrickMethod) {
        if let start = book.state.brickedSince {
            book.sessions.append(LocalSession(start: start, end: max(at, start),
                                              modeId: book.state.modeId, endedBy: method.rawValue))
            let cutoff = at.addingTimeInterval(-Double(historyDays) * 86400)
            book.sessions.removeAll { $0.end < cutoff }
        }
        book.state.bricked = false
        book.state.brickedSince = nil
        book.state.endsAt = nil
        book.state.lastMethod = method.rawValue
        book.state.lastChanged = at
    }

    private static func unbrick(_ book: inout LocalBook, method: BrickMethod, tagId: String?,
                                source: String?, at: Date) throws -> Bool {
        guard book.state.bricked else { return false }
        switch method {
        case .tag:
            guard isKnownTag(book, tagId) else {
                throw BrickRefusal(code: "unknown_tag", message: "That isn't one of your brick tags")
            }
        case .timer:
            guard let end = book.state.endsAt, end <= at.addingTimeInterval(30) else {
                throw BrickRefusal(code: "strict_mode", message: "The timer hasn't finished yet")
            }
        case .schedule:
            guard book.state.lastMethod == BrickMethod.schedule.rawValue else { return false }
        case .manual, .automation:
            if book.state.strict {
                throw BrickRefusal(code: "strict_mode",
                                   message: "Strict mode is on: scan your brick, wait for the timer, or use an emergency unbrick.")
            }
        case .emergency:
            throw BrickRefusal(code: "invalid", message: "Use emergency unbrick")
        }
        if let source { book.state.source = source }
        endSession(&book, at: at, by: method)
        return true
    }

    private static func emergency(_ book: inout LocalBook, at: Date) throws -> Bool {
        guard book.state.emergencyRemaining > 0 else {
            throw BrickRefusal(code: "no_emergency_unbricks",
                               message: "No emergency unbricks left. Request a reset - it completes after \(Int(book.state.resetHours)) hours.")
        }
        guard book.state.bricked else {
            throw BrickRefusal(code: "not_bricked", message: "You're not bricked")
        }
        book.state.emergencyRemaining -= 1
        endSession(&book, at: at, by: .emergency)
        return true
    }

    private static func requestReset(_ book: inout LocalBook, now: Date) throws -> Bool {
        guard book.state.emergencyRemaining < book.state.emergencyMax else {
            throw BrickRefusal(code: "reset_not_needed", message: "You still have every emergency unbrick")
        }
        guard book.state.emergencyResetAt == nil else { return false }
        book.state.emergencyResetAt = now.addingTimeInterval(book.state.resetHours * 3600)
        return true
    }

    // MARK: Time

    /// Ends expired timers and completes due resets.
    @discardableResult
    static func tick(_ book: inout LocalBook, now: Date = Date()) -> Bool {
        var changed = false
        if book.state.bricked, let end = book.state.endsAt, end <= now {
            endSession(&book, at: end, by: .timer)
            changed = true
        }
        if let reset = book.state.emergencyResetAt, reset <= now {
            book.state.emergencyRemaining = book.state.emergencyMax
            book.state.emergencyResetAt = nil
            changed = true
        }
        return changed
    }

    /// Settings for standalone mode (no Home Assistant). Raising the maximum
    /// never refills - only a completed reset does.
    static func applySettings(_ book: inout LocalBook, emergencyMax: Int, resetHours: Double, strict: Bool) {
        book.state.emergencyMax = emergencyMax
        book.state.emergencyRemaining = max(0, min(book.state.emergencyRemaining, emergencyMax))
        if book.state.emergencyRemaining >= emergencyMax { book.state.emergencyResetAt = nil }
        book.state.resetHours = resetHours
        book.state.strict = strict
    }

    // MARK: Stats

    static func stats(_ book: LocalBook, now: Date = Date(), calendar: Calendar = .current) -> BrickStats {
        var sessions = book.sessions
        if book.state.bricked, let start = book.state.brickedSince {
            sessions.append(LocalSession(start: start, end: now, modeId: nil, endedBy: ""))
        }
        func overlap(_ a: Date, _ b: Date) -> TimeInterval {
            sessions.reduce(0) { total, s in
                let lo = max(s.start, a), hi = min(s.end, b)
                return hi > lo ? total + hi.timeIntervalSince(lo) : total
            }
        }
        let todayStart = calendar.startOfDay(for: now)
        let today = overlap(todayStart, now)
        let week = overlap(now.addingTimeInterval(-7 * 86400), now)
        var streak = 0
        var day = today >= 60 ? todayStart : calendar.date(byAdding: .day, value: -1, to: todayStart)!
        while streak <= historyDays {
            let next = calendar.date(byAdding: .day, value: 1, to: day)!
            if overlap(day, next) < 60 { break }
            streak += 1
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        let longest = sessions.map { $0.end.timeIntervalSince($0.start) }.max() ?? 0
        return BrickStats(todaySeconds: Int(today), weekSeconds: Int(week), streakDays: streak,
                          sessionsTotal: book.sessions.count, longestSessionSeconds: Int(longest))
    }
}
