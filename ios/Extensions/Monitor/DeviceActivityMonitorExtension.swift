import DeviceActivity
import Foundation

/// iOS wakes this extension at DeviceActivity interval boundaries, even if
/// the app was force-quit and the phone has no signal. It has no network, so
/// it only changes local state; the app reports to Home Assistant later.
final class DeviceActivityMonitorExtension: DeviceActivityMonitor {
    private let store = SharedStore.shared

    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        guard let schedule = schedule(for: activity) else { return }
        let weekday = Calendar.current.component(.weekday, from: Date())
        guard schedule.weekdays.contains(weekday), !store.book.state.bricked else { return }
        try? LocalRunner.run(BrickCommand(action: .brick, method: .schedule,
                                          modeId: schedule.modeId, source: schedule.name), store: store)
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        if activity == ActivityScheduler.timerActivity {
            LocalRunner.tick(store: store)  // timed brick is over
            return
        }
        guard let schedule = schedule(for: activity) else { return }
        let state = store.book.state
        // Only end a brick this schedule started.
        guard state.bricked, state.lastMethod == BrickMethod.schedule.rawValue,
              state.source == schedule.name else { return }
        try? LocalRunner.run(BrickCommand(action: .unbrick, method: .schedule, source: schedule.name), store: store)
    }

    private func schedule(for activity: DeviceActivityName) -> BrickSchedule? {
        guard let id = ActivityScheduler.scheduleId(from: activity) else { return nil }
        return store.schedules.first { $0.id == id && $0.enabled }
    }
}
