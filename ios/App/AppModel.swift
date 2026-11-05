import BackgroundTasks
import FamilyControls
import Foundation
import SwiftUI
import UIKit
import UserNotifications

struct TagItem: Identifiable, Equatable {
    var hash: String
    var name: String
    var id: String { hash }
}

struct Banner: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var isError: Bool
}

/// UI state + actions. Everything that changes the brick goes through
/// `BrickSync`, so the app, Shortcuts and extensions all follow one set of rules.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    static let refreshTaskId = (Bundle.main.bundleIdentifier ?? "com.example.brickhub") + ".refresh"

    @Published private(set) var state = BrickState()
    @Published private(set) var modes: [BrickMode] = []
    @Published private(set) var schedules: [BrickSchedule] = []
    @Published private(set) var tags: [TagItem] = []
    @Published private(set) var connection: HAConnection?
    @Published private(set) var pendingCount = 0
    @Published private(set) var lastSync: Date?
    @Published var online: Bool?
    @Published var busy = false
    @Published var banner: Banner?
    @Published private(set) var authorized = false
    /// Set by the "Scan brick" Shortcut so the UI starts a scan on launch.
    @Published var scanRequested = false

    let store = SharedStore.shared
    private let scanner = NFCScanner()
    private var pollTask: Task<Void, Never>?

    init() { reload() }

    func reload() {
        let book = store.book
        state = book.state
        if store.connection == nil {
            // Standalone: stats are computed on the phone.
            state.stats = BrickEngine.stats(book)
        }
        modes = store.modes
        schedules = store.schedules
        tags = book.tags.map { TagItem(hash: $0.key, name: $0.value) }.sorted { $0.name < $1.name }
        connection = store.connection
        pendingCount = store.pending.count
        lastSync = store.lastSync
        authorized = ShieldController.isAuthorized
    }

    var isConnected: Bool { connection != nil }

    // MARK: Foreground sync

    func startForegroundSync() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.syncLoop()
        }
    }

    func stopForegroundSync() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func syncLoop() async {
        await BrickSync.shared.heartbeat()
        var first = true
        while !Task.isCancelled {
            if store.connection == nil {
                await BrickSync.shared.tickLocal()
                reload()
                try? await Task.sleep(for: .seconds(15))
                continue
            }
            do {
                // First call returns immediately; then long-poll for changes.
                try await BrickSync.shared.refresh(since: first ? nil : state.revision, wait: 25)
                online = true
                first = false
            } catch {
                online = false
                await BrickSync.shared.tickLocal()
                reload()
                try? await Task.sleep(for: .seconds(10))
            }
            reload()
        }
    }

    func syncNow() async {
        do {
            try await BrickSync.shared.refresh()
            await BrickSync.shared.heartbeat()
            online = true
        } catch {
            online = false
            show(error)
        }
        reload()
    }

    // MARK: Brick actions

    @discardableResult
    func run(_ cmd: PendingCommand, success: String? = nil) async -> Bool {
        busy = true
        defer { busy = false; reload() }
        do {
            let outcome = try await BrickSync.shared.perform(cmd)
            online = outcome == .online ? true : (outcome == .offline ? false : online)
            if outcome == .offline {
                banner = Banner(text: "Home Assistant is unreachable - done on this phone and queued.", isError: false)
            } else if let success {
                banner = Banner(text: success, isError: false)
            }
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            return true
        } catch {
            show(error)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return false
        }
    }

    func brickNow(modeId: String?, minutes: Double?) async {
        await run(PendingCommand(action: .brick, method: .manual, modeId: modeId,
                                 durationMinutes: minutes, source: deviceLabel))
    }

    /// Tap the brick: unbricks if bricked, otherwise bricks (like the real thing).
    func scanBrick(modeId: String? = nil, minutes: Double? = nil) async {
        scanRequested = false
        let bricked = state.bricked
        let tagId: String
        do {
            tagId = try await scanner.scan(
                prompt: bricked ? "Hold your brick near the top of your iPhone to unbrick."
                                : "Hold your brick near the top of your iPhone to brick.",
                success: bricked ? "Unbricked" : "Bricked"
            )
        } catch NFCScanner.ScanError.cancelled {
            return
        } catch {
            show(error)
            return
        }
        // Standalone: we can check the tag ourselves. Connected: HA decides
        // (it may know tags registered from ESPHome readers etc).
        if !isConnected && !BrickEngine.isKnownTag(store.book, tagId) {
            show(BrickRefusal(code: "unknown_tag", message: "That isn't one of your brick tags. Add it in Settings first."))
            return
        }
        await run(PendingCommand(action: bricked ? .unbrick : .brick, method: .tag,
                                 modeId: bricked ? nil : modeId,
                                 durationMinutes: bricked ? nil : minutes,
                                 tagId: tagId, source: deviceLabel))
    }

    func unbrickWithoutTag() async {
        await run(PendingCommand(action: .unbrick, method: .manual, source: deviceLabel))
    }

    func emergencyUnbrick() async {
        await run(PendingCommand(action: .emergencyUnbrick, method: .emergency, source: deviceLabel),
                  success: "Emergency unbrick used.")
    }

    func requestReset() async {
        await run(PendingCommand(action: .requestReset),
                  success: "Reset requested. Your emergency unbricks refill in \(Int(state.resetHours)) hours.")
    }

    func cancelReset() async {
        await run(PendingCommand(action: .cancelReset))
    }

    // MARK: Tags

    func addTag(name: String) async {
        do {
            let tagId = try await scanner.scan(prompt: "Hold the new brick near the top of your iPhone.",
                                               success: "Brick added")
            await run(PendingCommand(action: .registerTag, tagId: tagId, tagName: name),
                      success: "Added \(name.isEmpty ? "brick" : name).")
        } catch NFCScanner.ScanError.cancelled {
        } catch {
            show(error)
        }
    }

    func removeTag(hash: String) async {
        await run(PendingCommand(action: .removeTag, tagId: hash))
    }

    // MARK: Modes & schedules (locked while bricked)

    func save(mode: BrickMode) {
        guard !state.bricked else { return }
        var all = store.modes
        if let i = all.firstIndex(where: { $0.id == mode.id }) { all[i] = mode } else { all.append(mode) }
        store.modes = all
        reload()
        Task { await BrickSync.shared.heartbeat() }
    }

    func delete(mode: BrickMode) {
        guard !state.bricked else { return }
        store.modes = store.modes.filter { $0.id != mode.id }
        reload()
        Task { await BrickSync.shared.heartbeat() }
    }

    func save(schedule: BrickSchedule) {
        guard !state.bricked else { return }
        var all = store.schedules
        if let i = all.firstIndex(where: { $0.id == schedule.id }) { all[i] = schedule } else { all.append(schedule) }
        store.schedules = all
        ActivityScheduler.syncSchedules(all)
        reload()
    }

    func delete(schedule: BrickSchedule) {
        guard !state.bricked else { return }
        store.schedules = store.schedules.filter { $0.id != schedule.id }
        ActivityScheduler.syncSchedules(store.schedules)
        reload()
    }

    // MARK: Standalone rules

    func updateStandalone(emergencyMax: Int, resetHours: Double, strict: Bool) {
        guard !isConnected, !state.bricked else { return }
        store.updateBook { BrickEngine.applySettings(&$0, emergencyMax: emergencyMax, resetHours: resetHours, strict: strict) }
        reload()
    }

    // MARK: Connection

    func connect(url: String, token: String, deviceName: String) async -> Bool {
        var text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        guard let base = URL(string: text) else {
            banner = Banner(text: "That URL doesn't look right.", isError: true)
            return false
        }
        busy = true
        defer { busy = false; reload() }
        do {
            try await BrickSync.shared.connect(
                baseURL: base, token: token.trimmingCharacters(in: .whitespacesAndNewlines),
                deviceName: deviceName.isEmpty ? "iPhone" : deviceName
            )
            online = true
            banner = Banner(text: "Connected to Home Assistant.", isError: false)
            startForegroundSync()
            return true
        } catch {
            show(error)
            return false
        }
    }

    func disconnect() async {
        guard !state.bricked else { return }
        await BrickSync.shared.disconnect()
        online = nil
        reload()
    }

    // MARK: Permissions

    func requestScreenTime() async {
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
        } catch {
            show(error)
        }
        reload()
        await BrickSync.shared.heartbeat()
    }

    func requestNotifications() async {
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        if granted { UIApplication.shared.registerForRemoteNotifications() }
    }

    static func scheduleBackgroundRefresh() {
        let req = BGAppRefreshTaskRequest(identifier: refreshTaskId)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(req)
    }

    // MARK: Helpers

    private var deviceLabel: String { store.connection?.deviceName ?? "iPhone" }

    func show(_ error: Error) {
        banner = Banner(text: error.localizedDescription, isError: true)
    }
}
