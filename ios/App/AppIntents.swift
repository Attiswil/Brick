import AppIntents
import Foundation

// Shortcuts actions. These make every iOS automation trigger (Focus, arrive
// / leave, Wi-Fi, CarPlay, alarm, charger...) a brick trigger too - no Home
// Assistant needed for those.

struct ModeEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Mode"
    static var defaultQuery = ModeQuery()
    var id: String
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct ModeQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ModeEntity] {
        SharedStore.shared.modes.filter { identifiers.contains($0.id) }.map { ModeEntity(id: $0.id, name: $0.name) }
    }

    func suggestedEntities() async throws -> [ModeEntity] {
        SharedStore.shared.modes.map { ModeEntity(id: $0.id, name: $0.name) }
    }
}

struct BrickIntent: AppIntent {
    static var title: LocalizedStringResource = "Brick Phone"
    static var description = IntentDescription("Block the apps in a mode. Bricking is always allowed.")

    @Parameter(title: "Mode") var mode: ModeEntity?
    @Parameter(title: "Minutes", description: "Unbrick automatically after this long. Leave empty for no limit.")
    var minutes: Int?

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let cmd = PendingCommand(action: .brick, method: .automation, modeId: mode?.id,
                                 durationMinutes: minutes.map(Double.init), source: "Shortcut")
        try await BrickSync.shared.perform(cmd)
        await MainActor.run { AppModel.shared.reload() }
        return .result(dialog: "Bricked.")
    }
}

/// Only works with strict mode off - otherwise use "Scan Brick".
struct UnbrickIntent: AppIntent {
    static var title: LocalizedStringResource = "Unbrick Phone"
    static var description = IntentDescription("Unbrick without a tag. Refused while strict mode is on.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // Shortcuts can be run by hand, so they count as manual.
        try await BrickSync.shared.perform(PendingCommand(action: .unbrick, method: .manual, source: "Shortcut"))
        await MainActor.run { AppModel.shared.reload() }
        return .result(dialog: "Unbricked.")
    }
}

struct ScanBrickIntent: AppIntent {
    static var title: LocalizedStringResource = "Scan Brick"
    static var description = IntentDescription("Open Brick Hub and scan your brick tag.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared.scanRequested = true
        return .result()
    }
}

struct IsBrickedIntent: AppIntent {
    static var title: LocalizedStringResource = "Is Phone Bricked"

    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let state = (try? await BrickSync.shared.refresh()) ?? SharedStore.shared.book.state
        return .result(value: state.bricked)
    }
}

struct BrickShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: BrickIntent(), phrases: ["Brick my phone with \(.applicationName)"],
                    shortTitle: "Brick", systemImageName: "lock.iphone")
        AppShortcut(intent: ScanBrickIntent(), phrases: ["Scan my brick with \(.applicationName)"],
                    shortTitle: "Scan Brick", systemImageName: "wave.3.right")
    }
}
