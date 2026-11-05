import SwiftUI
import UIKit
import UserNotifications

@main
struct BrickHubApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                model.reload()
                model.startForegroundSync()
            case .background:
                model.stopForegroundSync()
                AppModel.scheduleBackgroundRefresh()
            default:
                break
            }
        }
        .backgroundTask(.appRefresh(AppModel.refreshTaskId)) {
            // Opportunistic catch-up: replay offline commands, pull HA state.
            _ = try? await BrickSync.shared.refresh()
            await BrickSync.shared.heartbeat()
            await AppModel.scheduleBackgroundRefresh()
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // Re-arm schedules and make shields match the stored state on launch.
        let store = SharedStore.shared
        ActivityScheduler.syncSchedules(store.schedules)
        ShieldController.sync(store.book, modes: store.modes)
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
                DispatchQueue.main.async { application.registerForRemoteNotifications() }
            }
        }
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        let store = SharedStore.shared
        guard store.apnsToken != token else { return }
        store.apnsToken = token
        Task { await BrickSync.shared.heartbeat() }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NSLog("BrickHub: push registration failed: \(error)")
    }

    /// Silent ("background") pushes land here.
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        await BrickSync.shared.handlePush(userInfo)
        await MainActor.run { AppModel.shared.reload() }
        return .newData
    }

    /// The app is open: it's already up to date, so keep the banner quiet.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        await MainActor.run { AppModel.shared.reload() }
        return [.list]
    }
}
