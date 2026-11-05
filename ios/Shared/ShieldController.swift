import DeviceActivity
import FamilyControls
import Foundation
import ManagedSettings

/// Applies or clears the Screen Time shields. Shields set here persist even
/// when the app isn't running, so the brick holds until something removes it.
enum ShieldController {
    static let store = ManagedSettingsStore(named: ManagedSettingsStore.Name("brick"))
    /// Separate store so the clock lock outlives the brick itself.
    static let clockStore = ManagedSettingsStore(named: ManagedSettingsStore.Name("brick.clock"))

    static var isAuthorized: Bool {
        AuthorizationCenter.shared.authorizationStatus == .approved
    }

    /// Make the shields match the book. Safe to call as often as you like.
    static func sync(_ book: LocalBook, modes: [BrickMode]) {
        if book.state.bricked {
            apply(resolveMode(book.state.modeId, modes: modes))
        } else {
            store.clearAllSettings()
        }
        // The emergency reset runs on the phone's clock, so don't let the
        // clock be changed by hand while bricked or while a reset is pending.
        let lockClock = book.state.bricked || book.state.emergencyResetAt != nil
        clockStore.dateAndTime.requireAutomaticDateAndTime = lockClock ? true : nil
        ActivityScheduler.syncTimer(endsAt: book.state.bricked ? book.state.endsAt : nil)
    }

    /// The requested mode, else the first one. `nil` means the phone has no
    /// modes yet - then everything is blocked.
    static func resolveMode(_ modeId: String?, modes: [BrickMode]) -> BrickMode? {
        modes.first { $0.id == modeId } ?? modes.first
    }

    private static func apply(_ mode: BrickMode?) {
        guard let mode else {
            // Fail closed: no mode configured, block every app and site.
            store.shield.applications = nil
            store.shield.applicationCategories = .all()
            store.shield.webDomainCategories = .all()
            store.application.denyAppRemoval = true
            return
        }
        let sel = mode.selection
        switch mode.style {
        case .blockList:
            store.shield.applications = sel.applicationTokens.isEmpty ? nil : sel.applicationTokens
            store.shield.applicationCategories = sel.categoryTokens.isEmpty ? nil : .specific(sel.categoryTokens)
            store.shield.webDomains = sel.webDomainTokens.isEmpty ? nil : sel.webDomainTokens
            store.shield.webDomainCategories = sel.categoryTokens.isEmpty ? nil : .specific(sel.categoryTokens)
        case .allowList:
            store.shield.applications = nil
            store.shield.webDomains = nil
            store.shield.applicationCategories = .all(except: sel.applicationTokens)
            store.shield.webDomainCategories = .all(except: sel.webDomainTokens)
        }
        // Stops "just delete the app" (including this one) while bricked.
        store.application.denyAppRemoval = mode.preventAppRemoval ? true : nil
    }
}

/// DeviceActivity monitoring: timed bricks and on-device schedules. The
/// monitor extension gets woken by iOS at these times even if the app has
/// been force-quit and the phone is offline.
enum ActivityScheduler {
    static let timerActivity = DeviceActivityName("brick.timer")
    static let schedulePrefix = "brick.schedule."
    private static let center = DeviceActivityCenter()

    static func syncTimer(endsAt: Date?) {
        center.stopMonitoring([timerActivity])
        guard let endsAt, endsAt > Date() else { return }
        // DeviceActivity intervals must be at least 15 minutes long, so the
        // interval *ends* at endsAt and starts 15+ minutes before it.
        let start = min(Date(), endsAt.addingTimeInterval(-16 * 60))
        let cal = Calendar.current
        let comps: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]
        let schedule = DeviceActivitySchedule(
            intervalStart: cal.dateComponents(comps, from: start),
            intervalEnd: cal.dateComponents(comps, from: endsAt),
            repeats: false
        )
        do {
            try center.startMonitoring(timerActivity, during: schedule)
        } catch {
            NSLog("BrickHub: couldn't arm brick timer: \(error)")
        }
    }

    static func activityName(for schedule: BrickSchedule) -> DeviceActivityName {
        DeviceActivityName(schedulePrefix + schedule.id)
    }

    static func scheduleId(from activity: DeviceActivityName) -> String? {
        let raw = activity.rawValue
        guard raw.hasPrefix(schedulePrefix) else { return nil }
        return String(raw.dropFirst(schedulePrefix.count))
    }

    /// One daily-repeating activity per schedule; the extension checks the
    /// weekday when it fires. (iOS caps an app at ~20 monitored activities.)
    static func syncSchedules(_ schedules: [BrickSchedule]) {
        let existing = center.activities.filter { $0.rawValue.hasPrefix(schedulePrefix) }
        center.stopMonitoring(existing)
        for s in schedules where s.enabled && !s.weekdays.isEmpty {
            let schedule = DeviceActivitySchedule(
                intervalStart: DateComponents(hour: s.startMinutes / 60, minute: s.startMinutes % 60),
                intervalEnd: DateComponents(hour: s.endMinutes / 60, minute: s.endMinutes % 60),
                repeats: true
            )
            do {
                try center.startMonitoring(activityName(for: s), during: schedule)
            } catch {
                NSLog("BrickHub: couldn't start schedule \(s.name): \(error)")
            }
        }
    }
}
