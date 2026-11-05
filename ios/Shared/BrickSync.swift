import Foundation

/// Network-free, synchronous core used by everything - the app, Shortcuts,
/// and the extensions (which have no network). The phone is always the
/// source of truth: every change happens here first, then (optionally) gets
/// reported to Home Assistant.
enum LocalRunner {
    /// Run a command on the phone. Throws `BrickRefusal` if the rules say no.
    @discardableResult
    static func run(_ cmd: BrickCommand, store: SharedStore = .shared) throws -> Bool {
        let modes = store.modes
        var changed = false
        let book = try store.updateBook { book -> LocalBook in
            changed = try BrickEngine.apply(cmd, to: &book)
            return book
        }
        ShieldController.sync(book, modes: modes)
        if changed { store.needsReport = true }
        return changed
    }

    /// Run commands that came from Home Assistant.
    static func handle(_ commands: [RemoteCommand], store: SharedStore = .shared) -> [CommandResult] {
        guard !commands.isEmpty else { return [] }
        let modes = store.modes
        let names = store.modeNames
        let (book, results) = store.updateBook { book -> (LocalBook, [CommandResult]) in
            let results = commands.map { BrickEngine.handle($0, book: &book, modes: names) }
            return (book, results)
        }
        ShieldController.sync(book, modes: modes)
        let fresh = results.filter { $0.code != "duplicate" }
        if !fresh.isEmpty {
            store.unsentResults = store.unsentResults + fresh
            store.needsReport = true
        }
        return results
    }

    /// End timers and complete resets that are due.
    static func tick(store: SharedStore = .shared) {
        let modes = store.modes
        var changed = false
        let book = store.updateBook { book -> LocalBook in
            changed = BrickEngine.tick(&book)
            return book
        }
        ShieldController.sync(book, modes: modes)
        if changed { store.needsReport = true }
    }

    static func setRules(_ rules: BrickRules, store: SharedStore = .shared) throws {
        try store.updateBook { try BrickEngine.setRules(rules, book: &$0) }
        store.needsReport = true
    }
}

/// Talks to Home Assistant, if one is connected. Nothing here is needed for
/// the phone to brick and unbrick - it only delivers HA's commands and
/// reports the phone's state back.
actor BrickSync {
    static let shared = BrickSync()
    private let store: SharedStore

    init(store: SharedStore = .shared) {
        self.store = store
    }

    var isConnected: Bool { store.connection != nil }

    /// Run a command locally, then tell HA in the background. Never waits
    /// for the network: the phone decides, instantly, online or not.
    func perform(_ cmd: BrickCommand) throws {
        try LocalRunner.run(cmd, store: store)
        Task { await self.report() }
    }

    /// Report our state to HA and run any commands it has waiting.
    /// Best effort: failures just leave `needsReport` set for next time.
    func report() async {
        guard let client = HAClient.current(store) else { return }
        LocalRunner.tick(store: store)
        // Report; if HA hands back commands, run them and report their
        // results too (bounded, in case commands keep arriving).
        for _ in 0..<3 {
            let results = store.unsentResults
            do {
                let commands = try await client.report(makeReport(results: results))
                store.unsentResults = Array(store.unsentResults.dropFirst(results.count))
                store.needsReport = !store.unsentResults.isEmpty
                store.lastReport = Date()
                let fresh = LocalRunner.handle(commands, store: store).filter { $0.code != "duplicate" }
                if fresh.isEmpty { return }
            } catch {
                store.needsReport = true
                return
            }
        }
    }

    /// Long-poll HA for commands (while the app is open).
    func pollCommands(wait: Int = 25) async throws {
        guard let client = HAClient.current(store) else { return }
        if store.needsReport { await report() }
        let commands = try await client.commands(deviceId: store.deviceId, wait: wait)
        if !LocalRunner.handle(commands, store: store).isEmpty {
            await report()
        }
    }

    /// A push from HA carrying a command. Works without network; the result
    /// is reported if the network is there.
    func handlePush(_ userInfo: [AnyHashable: Any]) async -> CommandResult? {
        guard let dict = userInfo["brick_cmd"] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: dict),
              let cmd = try? JSON.snakeDecoder.decode(RemoteCommand.self, from: data) else { return nil }
        let result = LocalRunner.handle([cmd], store: store).first
        await report()
        return result
    }

    private func makeReport(results: [CommandResult]) -> PhoneReport {
        let book = store.book
        return PhoneReport(
            deviceId: store.deviceId,
            name: store.connection?.deviceName ?? "iPhone",
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            authorized: ShieldController.isAuthorized,
            apnsToken: store.apnsToken,
            apnsSandbox: store.apnsToken == nil ? nil : APNsEnvironment.isSandbox,
            modes: store.modes.map { PhoneReport.Mode(id: $0.id, name: $0.name) },
            tagHashes: Array(book.tags.keys).sorted(),
            rules: book.rules,
            state: book.state,
            stats: BrickEngine.stats(book),
            results: results
        )
    }

    /// Link a Home Assistant server. Validates the URL and token.
    func connect(baseURL: URL, token: String, deviceName: String) async throws {
        let client = HAClient(baseURL: baseURL, token: token)
        store.connection = HAConnection(baseURL: baseURL, deviceName: deviceName)
        store.token = token
        do {
            let commands = try await client.report(makeReport(results: []))
            store.lastReport = Date()
            store.needsReport = false
            // Don't run anything that was queued before we were linked.
            _ = commands
        } catch {
            store.connection = nil
            store.token = nil
            throw error
        }
    }

    func disconnect() {
        store.connection = nil
        store.token = nil
        store.unsentResults = []
    }
}

/// Which APNs environment our provisioning profile uses. Xcode builds use
/// the sandbox; TestFlight/App Store builds have no embedded profile.
enum APNsEnvironment {
    static let isSandbox: Bool = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1) else { return false }
        guard let range = text.range(of: "<key>aps-environment</key>") else { return false }
        return text[range.upperBound...].prefix(100).contains("development")
    }()
}
