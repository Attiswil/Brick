import DeviceActivity
import Foundation

/// iOS wakes this extension at DeviceActivity interval boundaries, even if
/// the app was force-quit and the phone has no signal.
final class DeviceActivityMonitorExtension: DeviceActivityMonitor {
    private let store = SharedStore.shared

    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        guard let schedule = schedule(for: activity) else { return }
        let weekday = Calendar.current.component(.weekday, from: Date())
        guard schedule.weekdays.contains(weekday), !store.book.state.bricked else { return }
        OfflineRunner.run(PendingCommand(action: .brick, method: .schedule,
                                         modeId: schedule.modeId, source: schedule.name))
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        if activity == ActivityScheduler.timerActivity {
            // Timed brick is over. HA ends it on its side too, so no need to queue.
            OfflineRunner.tick()
            return
        }
        guard let schedule = schedule(for: activity) else { return }
        let state = store.book.state
        // Only end bricks this schedule started - never a manual/HA brick.
        guard state.bricked, state.lastMethod == BrickMethod.schedule.rawValue,
              state.source == schedule.name else { return }
        OfflineRunner.run(PendingCommand(action: .unbrick, method: .schedule, source: schedule.name))
    }

    private func schedule(for activity: DeviceActivityName) -> BrickSchedule? {
        guard let id = ActivityScheduler.scheduleId(from: activity) else { return nil }
        return store.schedules.first { $0.id == id && $0.enabled }
    }
}
