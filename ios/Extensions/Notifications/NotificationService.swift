import UserNotifications

/// Runs when Home Assistant's push arrives - even if the app has been
/// force-quit - executes the command on the phone, and rewrites the banner
/// to say what actually happened (e.g. "Refused: strict mode").
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        content = request.content.mutableCopy() as? UNMutableNotificationContent
        Task {
            let result = await BrickSync.shared.handlePush(request.content.userInfo)
            self.describe(result)
            self.finish()
        }
    }

    override func serviceExtensionTimeWillExpire() {
        finish()
    }

    private func describe(_ result: CommandResult?) {
        guard let result, let content else { return }
        let state = SharedStore.shared.book.state
        let modeName = SharedStore.shared.mode(state.modeId)?.name
        if result.ok {
            content.title = state.bricked ? "Bricked" : "Unbricked"
            var parts: [String] = []
            if state.bricked, let modeName { parts.append(modeName) }
            if state.bricked, let end = state.endsAt {
                parts.append("until \(end.formatted(date: .omitted, time: .shortened))")
            }
            if let source = state.source { parts.append("by \(source)") }
            content.body = parts.isEmpty ? (state.bricked ? "Your apps are blocked." : "Your apps are back.")
                                         : parts.joined(separator: " · ")
        } else if result.code == "duplicate" {
            return
        } else {
            content.title = "Brick Hub"
            content.body = "Didn't do that: \(result.message ?? result.code ?? "refused")"
        }
    }

    private func finish() {
        guard let handler = contentHandler, let content else { return }
        contentHandler = nil
        handler(content)
    }
}
