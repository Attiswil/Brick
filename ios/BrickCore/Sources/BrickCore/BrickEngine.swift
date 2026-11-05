import Foundation

/// The brick rules. Runs on the phone and is the only source of truth -
/// the app, Shortcuts, schedules and Home Assistant all go through here.
enum BrickEngine {
    static let historyDays = 90
    static let handledCommandMemory = 200
    /// A phone-side timer is allowed to fire this early (clock jitter).
    static let timerSlack: TimeInterval = 30

    // MARK: Tags

    static func isKnownTag(_ book: LocalBook, _ tagId: String?) -> Bool {
        guard let tagId, let h = TagHash.hash(tagId) else { return false }
        return book.tags[h] != nil
    }

    // MARK: Commands

    /// Applies a command. Returns whether anything changed; throws
    /// `BrickRefusal` when the rules say no.
    @discardableResult
    static func apply(_ cmd: BrickCommand, to book: inout LocalBook, now: Date = Date()) throws -> Bool {
        tick(&book, now: now)
        let at = min(cmd.occurredAt, now)  // never trust a future timestamp
        var action = cmd.action
        if action == .toggle { action = book.state.bricked ? .unbrick : .brick }
        let changed: Bool
        switch action {
        case .brick: changed = try brick(&book, cmd: cmd, at: at)
        case .unbrick: changed = try unbrick(&book, cmd: cmd, at: at)
        case .emergencyUnbrick: changed = try emergency(&book, at: at, now: now)
        case .requestReset: changed = try requestReset(&book, now: now)
        case .cancelReset:
            changed = book.state.emergencyResetAt != nil
            book.state.emergencyResetAt = nil
        case .registerTag: changed = try registerTag(&book, cmd: cmd)
        case .removeTag: changed = try removeTag(&book, cmd: cmd)
        case .toggle: changed = false  // resolved above
        }
        if changed { bump(&book, at: now) }
        return changed
    }

    private static func bump(_ book: inout LocalBook, at: Date) {
        book.state.revision += 1
        book.state.lastChanged = at
    }

    private static func brick(_ book: inout LocalBook, cmd: BrickCommand, at: Date) throws -> Bool {
        if cmd.method == .tag {
            guard isKnownTag(book, cmd.tagId) else {
                throw BrickRefusal(code: "unknown_tag", message: "That isn't one of your brick tags")
            }
            guard book.state.bricked || book.rules.tagToggles || cmd.action == .brick else {
                throw BrickRefusal(code: "tag_toggles_off", message: "Your brick tag only unbricks (see Settings).")
            }
        }
        let newEnd = cmd.durationMinutes.flatMap { $0 > 0 ? at.addingTimeInterval($0 * 60) : nil }
        if !book.state.bricked {
            book.state.bricked = true
            book.state.modeId = cmd.modeId ?? book.state.modeId
            book.state.brickedSince = at
            book.state.endsAt = newEnd
            book.state.source = cmd.source
            book.state.lastMethod = cmd.method.rawValue
            return true
        }
        // Already bricked: you can make it stricter, never weaker.
        var changed = false
        if let mode = cmd.modeId, mode != book.state.modeId {
            if book.rules.strict && cmd.method == .manual {
                throw BrickRefusal(code: "strict_mode", message: "Strict mode: can't switch modes while bricked.")
            }
            book.state.modeId = mode
            changed = true
        }
        if let end = book.state.endsAt, newEnd == nil || newEnd! > end {
            book.state.endsAt = newEnd  // extended, or made open-ended
            changed = true
        }
        return changed
    }

    private static func unbrick(_ book: inout LocalBook, cmd: BrickCommand, at: Date) throws -> Bool {
        guard book.state.bricked else { return false }
        switch cmd.method {
        case .tag:
            guard isKnownTag(book, cmd.tagId) else {
                throw BrickRefusal(code: "unknown_tag", message: "That isn't one of your brick tags")
            }
        case .timer:
            guard let end = book.state.endsAt, end <= at.addingTimeInterval(timerSlack) else {
                throw BrickRefusal(code: "timer_running", message: "The timer hasn't finished yet.")
            }
        case .schedule:
            // A schedule may only end a brick a schedule started.
            guard book.state.lastMethod == BrickMethod.schedule.rawValue else { return false }
        case .automation:
            break  // Home Assistant automations may end any brick, even in strict mode.
        case .manual:
            if book.rules.strict { throw BrickRefusal.strict() }
        case .emergency:
            throw BrickRefusal(code: "invalid", message: "Use emergency unbrick.")
        }
        endSession(&book, at: at, by: cmd.method, source: cmd.source)
        return true
    }

    private static func endSession(_ book: inout LocalBook, at: Date, by method: BrickMethod, source: String? = nil) {
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
        if let source { book.state.source = source }
    }

    private static func emergency(_ book: inout LocalBook, at: Date, now: Date) throws -> Bool {
        guard book.state.emergencyRemaining > 0 else {
            throw BrickRefusal(code: "no_emergency_unbricks",
                               message: "No emergency unbricks left. Request a reset - it takes \(Int(book.rules.resetHours)) hours.")
        }
        guard book.state.bricked else {
            throw BrickRefusal(code: "not_bricked", message: "You're not bricked.")
        }
        book.state.emergencyRemaining -= 1
        endSession(&book, at: at, by: .emergency)
        if book.state.emergencyRemaining == 0, book.rules.autoRequestReset, book.state.emergencyResetAt == nil {
            book.state.emergencyResetAt = now.addingTimeInterval(book.rules.resetHours * 3600)
        }
        return true
    }

    private static func requestReset(_ book: inout LocalBook, now: Date) throws -> Bool {
        guard book.state.emergencyRemaining < book.rules.emergencyMax else {
            throw BrickRefusal(code: "reset_not_needed", message: "You still have every emergency unbrick.")
        }
        guard book.state.emergencyResetAt == nil else { return false }  // never restarts the clock
        book.state.emergencyResetAt = now.addingTimeInterval(book.rules.resetHours * 3600)
        return true
    }

    private static func registerTag(_ book: inout LocalBook, cmd: BrickCommand) throws -> Bool {
        guard !book.state.bricked else { throw BrickRefusal.locked }
        guard let raw = cmd.tagId, let h = TagHash.hash(raw) else {
            throw BrickRefusal(code: "invalid", message: "Couldn't read that tag.")
        }
        let trimmed = cmd.tagName?.trimmingCharacters(in: .whitespaces) ?? ""
        let name = trimmed.isEmpty ? "Brick \(book.tags.count + 1)" : trimmed
        guard book.tags[h] != name else { return false }
        book.tags[h] = name
        return true
    }

    private static func removeTag(_ book: inout LocalBook, cmd: BrickCommand) throws -> Bool {
        guard !book.state.bricked else { throw BrickRefusal.locked }
        // Accept the raw tag id or its hash (the UI only has hashes).
        let key = cmd.tagId.flatMap { book.tags[$0] != nil ? $0 : TagHash.hash($0) }
        guard let key, book.tags.removeValue(forKey: key) != nil else {
            throw BrickRefusal(code: "unknown_tag", message: "That tag isn't registered.")
        }
        return true
    }

    // MARK: Remote commands (from Home Assistant)

    /// Runs a command from Home Assistant. Expired commands are dropped -
    /// only commands that reach the phone promptly count.
    static func handle(_ remote: RemoteCommand, book: inout LocalBook,
                       modes: [String: String], now: Date = Date()) -> CommandResult {
        if book.handledCommands.contains(remote.id) {
            return CommandResult(id: remote.id, ok: true, code: "duplicate")
        }
        book.handledCommands.append(remote.id)
        if book.handledCommands.count > handledCommandMemory {
            book.handledCommands.removeFirst(book.handledCommands.count - handledCommandMemory)
        }
        if let expires = remote.expiresAt, expires < now {
            return CommandResult(id: remote.id, ok: false, code: "expired",
                                 message: "The phone got this command too late, so it was dropped.")
        }
        var modeId = remote.modeId.flatMap { modes[$0] != nil ? $0 : nil }
        if modeId == nil, let wanted = remote.modeName ?? remote.modeId {
            modeId = modes.first { $0.value.caseInsensitiveCompare(wanted) == .orderedSame }?.key
            if modeId == nil {
                return CommandResult(id: remote.id, ok: false, code: "unknown_mode",
                                     message: "This phone has no mode called \(wanted).")
            }
        }
        // HA decides automation vs manual (a person in the dashboard).
        let method: BrickMethod
        switch remote.method {
        case "automation": method = .automation
        case "tag": method = .tag
        default: method = .manual
        }
        let cmd = BrickCommand(id: remote.id, action: remote.action, method: method, modeId: modeId,
                               durationMinutes: remote.durationMinutes, tagId: remote.tagId,
                               tagName: remote.tagName, source: remote.source, occurredAt: now)
        do {
            let changed = try apply(cmd, to: &book, now: now)
            return CommandResult(id: remote.id, ok: true, changed: changed)
        } catch let r as BrickRefusal {
            return CommandResult(id: remote.id, ok: false, code: r.code, message: r.message)
        } catch {
            return CommandResult(id: remote.id, ok: false, code: "error", message: error.localizedDescription)
        }
    }

    // MARK: Rules

    /// Change the rules. Locked while bricked. Raising the maximum never
    /// refills emergency unbricks - only a completed reset does.
    static func setRules(_ rules: BrickRules, book: inout LocalBook, now: Date = Date()) throws {
        guard !book.state.bricked else { throw BrickRefusal.locked }
        var r = rules
        r.emergencyMax = max(0, min(r.emergencyMax, 20))
        r.resetHours = max(1, min(r.resetHours, 336))
        book.rules = r
        book.state.emergencyRemaining = max(0, min(book.state.emergencyRemaining, r.emergencyMax))
        if book.state.emergencyRemaining >= r.emergencyMax { book.state.emergencyResetAt = nil }
        bump(&book, at: now)
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
            book.state.emergencyRemaining = book.rules.emergencyMax
            book.state.emergencyResetAt = nil
            changed = true
        }
        if changed { bump(&book, at: now) }
        return changed
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
