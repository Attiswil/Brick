import XCTest
@testable import BrickCore

final class BrickEngineTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func book(_ rules: BrickRules = BrickRules()) -> LocalBook {
        var b = LocalBook()
        b.rules = rules
        b.state.emergencyRemaining = rules.emergencyMax
        return b
    }

    func cmd(_ action: BrickAction, _ method: BrickMethod = .manual, mode: String? = nil,
             minutes: Double? = nil, tag: String? = nil, at: Date? = nil) -> BrickCommand {
        BrickCommand(action: action, method: method, modeId: mode, durationMinutes: minutes,
                     tagId: tag, occurredAt: at ?? t0)
    }

    func refusal(_ code: String, _ body: () throws -> Void, line: UInt = #line) {
        do { try body(); XCTFail("expected \(code)", line: line) }
        catch let r as BrickRefusal { XCTAssertEqual(r.code, code, line: line) }
        catch { XCTFail("\(error)", line: line) }
    }

    func testTagHashMatchesHomeAssistant() {
        // hashlib.sha256(b"brick_hub:04A1B2C3") in tags.py
        let expected = "27e80505ce6eaff0769f20aff4531f6758247ca9c2b3821e73caf386695bcc8b"
        XCTAssertEqual(TagHash.hash("04:a1:b2:c3"), expected)
        XCTAssertEqual(TagHash.hash("04-A1-B2-C3"), expected)
        XCTAssertNil(TagHash.hash(" :- "))
    }

    func testStrictBlocksManualButNotTagOrAutomation() throws {
        var b = book()
        try BrickEngine.apply(cmd(.registerTag, tag: "04A1B2C3"), to: &b, now: t0)
        try BrickEngine.apply(cmd(.brick), to: &b, now: t0)
        XCTAssertTrue(b.state.bricked)
        refusal("strict_mode") { try BrickEngine.apply(cmd(.unbrick), to: &b, now: t0) }
        refusal("unknown_tag") { try BrickEngine.apply(cmd(.unbrick, .tag, tag: "FF"), to: &b, now: t0) }
        try BrickEngine.apply(cmd(.unbrick, .tag, tag: "04-a1-b2-c3"), to: &b, now: t0)
        XCTAssertFalse(b.state.bricked)
        // Home Assistant automations can end any brick, even in strict mode.
        try BrickEngine.apply(cmd(.brick, .tag, tag: "04A1B2C3"), to: &b, now: t0)
        try BrickEngine.apply(cmd(.unbrick, .automation), to: &b, now: t0)
        XCTAssertFalse(b.state.bricked)
        XCTAssertEqual(b.sessions.last?.endedBy, "automation")
    }

    func testNonStrictAllowsManual() throws {
        var b = book(BrickRules(strict: false))
        try BrickEngine.apply(cmd(.toggle), to: &b, now: t0)
        try BrickEngine.apply(cmd(.toggle), to: &b, now: t0)
        XCTAssertFalse(b.state.bricked)
    }

    func testTimersExtendNeverShorten() throws {
        var b = book()
        try BrickEngine.apply(cmd(.brick, minutes: 60), to: &b, now: t0)
        try BrickEngine.apply(cmd(.brick, minutes: 5), to: &b, now: t0)
        XCTAssertEqual(b.state.endsAt, t0.addingTimeInterval(3600))
        try BrickEngine.apply(cmd(.brick, minutes: 90), to: &b, now: t0)
        XCTAssertEqual(b.state.endsAt, t0.addingTimeInterval(5400))
        refusal("timer_running") { try BrickEngine.apply(cmd(.unbrick, .timer), to: &b, now: t0) }
        XCTAssertFalse(BrickEngine.tick(&b, now: t0.addingTimeInterval(5399)))
        XCTAssertTrue(BrickEngine.tick(&b, now: t0.addingTimeInterval(5400)))
        XCTAssertFalse(b.state.bricked)
        XCTAssertEqual(b.sessions.last?.endedBy, "timer")
    }

    func testEmergencyAndTwoDayReset() throws {
        var b = book(BrickRules(emergencyMax: 2))
        for _ in 0..<2 {
            try BrickEngine.apply(cmd(.brick), to: &b, now: t0)
            try BrickEngine.apply(cmd(.emergencyUnbrick), to: &b, now: t0)
            XCTAssertFalse(b.state.bricked)
        }
        try BrickEngine.apply(cmd(.brick), to: &b, now: t0)
        refusal("no_emergency_unbricks") { try BrickEngine.apply(cmd(.emergencyUnbrick), to: &b, now: t0) }
        try BrickEngine.apply(cmd(.requestReset), to: &b, now: t0)
        XCTAssertEqual(b.state.emergencyResetAt, t0.addingTimeInterval(48 * 3600))
        // Asking again doesn't restart the clock.
        XCTAssertFalse(try BrickEngine.apply(cmd(.requestReset), to: &b, now: t0.addingTimeInterval(3600)))
        XCTAssertEqual(b.state.emergencyResetAt, t0.addingTimeInterval(48 * 3600))
        BrickEngine.tick(&b, now: t0.addingTimeInterval(48 * 3600 - 1))
        XCTAssertEqual(b.state.emergencyRemaining, 0)
        BrickEngine.tick(&b, now: t0.addingTimeInterval(48 * 3600))
        XCTAssertEqual(b.state.emergencyRemaining, 2)
        XCTAssertNil(b.state.emergencyResetAt)
    }

    func testAutoRequestReset() throws {
        var b = book(BrickRules(emergencyMax: 1, autoRequestReset: true))
        try BrickEngine.apply(cmd(.brick), to: &b, now: t0)
        try BrickEngine.apply(cmd(.emergencyUnbrick), to: &b, now: t0)
        XCTAssertEqual(b.state.emergencyResetAt, t0.addingTimeInterval(48 * 3600))
    }

    func testRulesLockedWhileBrickedAndNoFreeRefill() throws {
        var b = book(BrickRules(emergencyMax: 3))
        try BrickEngine.apply(cmd(.brick), to: &b, now: t0)
        try BrickEngine.apply(cmd(.emergencyUnbrick), to: &b, now: t0)
        try BrickEngine.setRules(BrickRules(emergencyMax: 10), book: &b, now: t0)
        XCTAssertEqual(b.state.emergencyRemaining, 2)
        try BrickEngine.apply(cmd(.brick), to: &b, now: t0)
        refusal("locked_while_bricked") { try BrickEngine.setRules(BrickRules(strict: false), book: &b, now: t0) }
        refusal("locked_while_bricked") { try BrickEngine.apply(cmd(.registerTag, tag: "AA"), to: &b, now: t0) }
    }

    func testStrictManualModeSwitchRefused() throws {
        var b = book()
        try BrickEngine.apply(cmd(.brick, mode: "a"), to: &b, now: t0)
        refusal("strict_mode") { try BrickEngine.apply(cmd(.brick, mode: "b"), to: &b, now: t0) }
        try BrickEngine.apply(cmd(.brick, .automation, mode: "b"), to: &b, now: t0)
        XCTAssertEqual(b.state.modeId, "b")
    }

    func testScheduleOnlyEndsScheduleBricks() throws {
        var b = book()
        try BrickEngine.apply(cmd(.brick), to: &b, now: t0)
        XCTAssertFalse(try BrickEngine.apply(cmd(.unbrick, .schedule), to: &b, now: t0))
        XCTAssertTrue(b.state.bricked)
        var s = book()
        try BrickEngine.apply(cmd(.brick, .schedule), to: &s, now: t0)
        XCTAssertTrue(try BrickEngine.apply(cmd(.unbrick, .schedule), to: &s, now: t0))
    }

    func testTagToggleRespectsSetting() throws {
        var b = book(BrickRules(tagToggles: false))
        try BrickEngine.apply(cmd(.registerTag, tag: "AB"), to: &b, now: t0)
        refusal("tag_toggles_off") { try BrickEngine.apply(cmd(.toggle, .tag, tag: "AB"), to: &b, now: t0) }
        try BrickEngine.apply(cmd(.brick, .tag, tag: "AB"), to: &b, now: t0)  // explicit "tap to brick"
        try BrickEngine.apply(cmd(.toggle, .tag, tag: "AB"), to: &b, now: t0)
        XCTAssertFalse(b.state.bricked)
    }

    // MARK: Remote commands

    func remote(_ action: BrickAction, id: String = UUID().uuidString, method: String = "automation",
                mode: String? = nil, expires: Date? = nil) -> RemoteCommand {
        RemoteCommand(id: id, action: action, method: method, modeId: nil, modeName: mode,
                      durationMinutes: nil, tagId: nil, tagName: nil, source: "Bedtime",
                      issuedAt: t0, expiresAt: expires ?? t0.addingTimeInterval(120))
    }

    func testRemoteCommandsResolveModesDropExpiredAndDedupe() {
        var b = book()
        let modes = ["m1": "Deep work", "m2": "Bedtime"]
        var r = BrickEngine.handle(remote(.brick, id: "a", mode: "bedtime"), book: &b, modes: modes, now: t0)
        XCTAssertTrue(r.ok && r.changed)
        XCTAssertEqual(b.state.modeId, "m2")
        XCTAssertEqual(b.state.source, "Bedtime")
        // Same command delivered twice (push + long-poll) runs once.
        r = BrickEngine.handle(remote(.brick, id: "a"), book: &b, modes: modes, now: t0)
        XCTAssertEqual(r.code, "duplicate")
        // Late commands are dropped.
        r = BrickEngine.handle(remote(.unbrick, expires: t0.addingTimeInterval(-1)), book: &b, modes: modes, now: t0)
        XCTAssertEqual(r.code, "expired")
        XCTAssertTrue(b.state.bricked)
        // A person in the HA dashboard is manual -> strict refuses.
        r = BrickEngine.handle(remote(.unbrick, method: "manual"), book: &b, modes: modes, now: t0)
        XCTAssertEqual(r.code, "strict_mode")
        // An automation can end it.
        r = BrickEngine.handle(remote(.unbrick), book: &b, modes: modes, now: t0)
        XCTAssertTrue(r.ok && !b.state.bricked)
        r = BrickEngine.handle(remote(.brick, mode: "Nope"), book: &b, modes: modes, now: t0)
        XCTAssertEqual(r.code, "unknown_mode")
    }

    func testDecodesHomeAssistantCommandJSON() throws {
        let json = """
        {"id":"c1","action":"brick","method":"automation","mode_name":"Deep work",
         "duration_minutes":90,"source":"Office","issued_at":"2026-11-05T09:00:00.123456+00:00",
         "expires_at":"2026-11-05T09:02:00+00:00"}
        """
        let c = try JSON.snakeDecoder.decode(RemoteCommand.self, from: Data(json.utf8))
        XCTAssertEqual(c.action, .brick)
        XCTAssertEqual(c.modeName, "Deep work")
        XCTAssertEqual(c.durationMinutes, 90)
        XCTAssertNotNil(c.issuedAt)
        XCTAssertEqual(c.expiresAt.map { ISO8601.string($0) }, "2026-11-05T09:02:00.000Z")
    }

    func testStatsAndStreak() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Australia/Sydney")!
        var b = book(BrickRules(strict: false))
        let day1 = cal.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 10))!
        let day2 = cal.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 10))!
        for d in [day1, day2] {
            try BrickEngine.apply(cmd(.brick, at: d), to: &b, now: d)
            try BrickEngine.apply(cmd(.unbrick, at: d.addingTimeInterval(3600)), to: &b, now: d.addingTimeInterval(3600))
        }
        let s = BrickEngine.stats(b, now: day2.addingTimeInterval(8 * 3600), calendar: cal)
        XCTAssertEqual(s.todaySeconds, 3600)
        XCTAssertEqual(s.streakDays, 2)
        XCTAssertEqual(s.sessionsTotal, 2)
    }

    func testBookRoundTrips() throws {
        var b = book()
        try BrickEngine.apply(cmd(.brick, minutes: 30), to: &b, now: t0)
        let data = try JSON.encoder.encode(b)
        XCTAssertEqual(try JSON.decoder.decode(LocalBook.self, from: data), b)
    }
}
