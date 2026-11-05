import UserNotifications

/// Runs whenever Home Assistant's push arrives - even if the app has been
/// force-quit - and applies the brick before the banner is shown.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var content: UNNotificationContent?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        content = request.content
        Task {
            await BrickSync.shared.handlePush(request.content.userInfo)
            self.finish()
        }
    }

    override func serviceExtensionTimeWillExpire() {
        finish()
    }

    private func finish() {
        guard let handler = contentHandler, let content else { return }
        contentHandler = nil
        handler(content)
    }
}
