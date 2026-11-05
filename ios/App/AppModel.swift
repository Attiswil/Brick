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

/// UI state + actions. The phone decides everything locally and instantly;
/// Home Assistant (if linked) is told afterwards and can send commands.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    static let refreshTaskId = (Bundle.main.bundleIdentifier ?? "com.example.brickhub") + ".refresh"

    @Published private(set) var state = BrickState()
    @Published private(set) var rules = BrickRules()
    @Published private(set) var stats = BrickStats()
    @Published private(set) var modes: [BrickMode] = []
    @Published private(set) var schedules: [BrickSchedule] = []
    @Published private(set) var tags: [TagItem] = []
    @Published private(set) var connection: HAConnection?
    @Published private(set) var lastReport: Date?
    @Published private(set) var needsReport = false
    @Published var haReachable: Bool?
    @Published var busy = false
    @Published var banner: Banner?
    @Published private(set) var authorized = false
    /// Set by the "Scan Brick" Shortcut so the UI starts a scan on launch.
    @Published var scanRequested = false

    let store = SharedStore.shared
    private let scanner = NFCScanner()
    private var pollTask: Task<Void, Never>?

    init() { reload() }

    func reload() {
        let book = store.book
        state = book.state
        rules = book.rules
        stats = BrickEngine.stats(book)
        modes = store.modes
        schedules = store.schedules
        tags = book.tags.map { TagItem(hash: $0.key, name: $0.value) }.sorted { $0.name < $1.name }
        connection = store.connection
        lastReport = store.lastReport
        needsReport = store.needsReport
        authorized = ShieldController.isAuthorized
    }

    var isConnected: Bool { connection != nil }

    func modeName(_ id: String?) -> String? {
        modes.first { $0.id == id }?.name
    }

    // MARK: While the app is open

    /// Ticks local timers; if linked to HA, reports and long-polls for commands.
    func startForegroundLoop() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in await self?.foregroundLoop() }
    }

    func stopForegroundLoop() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func foregroundLoop() async {
        LocalRunner.tick()
        reload()
        if isConnected { await BrickSync.shared.report() }
        while !Task.isCancelled {
            if store.connection == nil {
                try? await Task.sleep(for: .seconds(15))
                LocalRunner.tick()
                reload()
                continue
            }
            do {
                try await BrickSync.shared.pollCommands(wait: 25)
                haReachable = true
            } catch {
                haReachable = false
                try? await Task.sleep(for: .seconds(15))
            }
            LocalRunner.tick()
            reload()
        }
    }

    func syncNow() async {
        LocalRunner.tick()
        await BrickSync.shared.report()
        haReachable = isConnected ? !store.needsReport : nil
        reload()
    }

    // MARK: Brick actions (all instant and local)

    @discardableResult
    func run(_ cmd: BrickCommand, success: String? = nil) async -> Bool {
        defer { reload() }
        do {
            try await BrickSync.shared.perform(cmd)
            if let success { banner = Banner(text: success, isError: false) }
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            return true
        } catch {
            show(error)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return false
        }
    }

    func brickNow(modeId: String?, minutes: Double?) async {
        await run(BrickCommand(action: .brick, method: .manual, modeId: modeId,
                               durationMinutes: minutes, source: "This iPhone"))
    }

    /// Tap the brick: unbricks if bricked, otherwise bricks.
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
        await run(BrickCommand(action: bricked ? .unbrick : .brick, method: .tag,
                               modeId: bricked ? nil : modeId,
                               durationMinutes: bricked ? nil : minutes,
                               tagId: tagId, source: "Brick tag"))
    }

    func unbrickWithoutTag() async {
        await run(BrickCommand(action: .unbrick, method: .manual, source: "This iPhone"))
    }

    func emergencyUnbrick() async {
        await run(BrickCommand(action: .emergencyUnbrick, method: .emergency, source: "Emergency"),
                  success: "Emergency unbrick used.")
    }

    func requestReset() async {
        await run(BrickCommand(action: .requestReset),
                  success: "Reset requested. Your emergency unbricks refill in \(Int(rules.resetHours)) hours.")
    }

    func cancelReset() async {
        await run(BrickCommand(action: .cancelReset))
    }

    // MARK: Tags

    func addTag(name: String) async {
        do {
            let tagId = try await scanner.scan(prompt: "Hold the new brick near the top of your iPhone.",
                                               success: "Brick added")
            await run(BrickCommand(action: .registerTag, tagId: tagId, tagName: name),
                      success: "Added \(name.isEmpty ? "your brick" : name).")
        } catch NFCScanner.ScanError.cancelled {
        } catch {
            show(error)
        }
    }

    func removeTag(hash: String) async {
        await run(BrickCommand(action: .removeTag, tagId: hash))
    }

    // MARK: Rules, modes & schedules (locked while bricked)

    func save(rules newRules: BrickRules) {
        do {
            try LocalRunner.setRules(newRules)
            banner = Banner(text: "Rules saved.", isError: false)
            Task { await BrickSync.shared.report() }
        } catch {
            show(error)
        }
        reload()
    }

    func save(mode: BrickMode) {
        guard !state.bricked else { return }
        var all = store.modes
        if let i = all.firstIndex(where: { $0.id == mode.id }) { all[i] = mode } else { all.append(mode) }
        store.modes = all
        reload()
        Task { await BrickSync.shared.report() }
    }

    func delete(mode: BrickMode) {
        guard !state.bricked else { return }
        store.modes = store.modes.filter { $0.id != mode.id }
        reload()
        Task { await BrickSync.shared.report() }
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

    // MARK: Home Assistant link (optional)

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
            haReachable = true
            banner = Banner(text: "Linked to Home Assistant.", isError: false)
            startForegroundLoop()
            return true
        } catch {
            show(error)
            return false
        }
    }

    /// Unlinking never changes the brick - the phone owns it either way.
    func disconnect() async {
        await BrickSync.shared.disconnect()
        haReachable = nil
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
        Task { await BrickSync.shared.report() }
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

    func show(_ error: Error) {
        banner = Banner(text: error.localizedDescription, isError: true)
    }
}
