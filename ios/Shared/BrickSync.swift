import Foundation

/// The one place that changes brick state on the phone. Used by the app,
/// App Intents, background refresh and the notification extension.
///
/// Rules:
/// * Connected: commands go to Home Assistant, which is the source of truth.
/// * Can't reach HA: the local engine applies the command (same rules) and it
///   is queued; queued commands are replayed, in order, before anything else.
/// * Never adopt HA's state while local commands are still unsent - otherwise
///   an offline brick could be undone by a stale push.
/// * Not configured for HA at all: fully standalone.
actor BrickSync {
    static let shared = BrickSync()
    private let store: SharedStore

    init(store: SharedStore = .shared) {
        self.store = store
    }

    enum Outcome {
        case online
        case offline  // applied locally, queued for HA
        case standalone
    }

    // MARK: Commands

    @discardableResult
    func perform(_ cmd: PendingCommand) async throws -> Outcome {
        guard let client = HAClient.current(store) else {
            try applyLocally(cmd)
            return .standalone
        }
        await flushPending(client)
        if store.pending.isEmpty {
            do {
                let remote = try await client.command(cmd, deviceId: store.deviceId)
                // Keep tag hashes locally so offline tag-unbricks still work.
                if cmd.action == .registerTag || cmd.action == .removeTag {
                    store.updateBook { book in _ = try? BrickEngine.apply(cmd, to: &book) }
                }
                await adopt(remote, client: client)
                return .online
            } catch HAError.refused(let refusal, let remote) {
                if let remote { await adopt(remote, client: client) }
                throw refusal
            } catch let error as HAError where error.isConnectivity {
                // fall through to offline
            }
        }
        if cmd.action == .registerTag || cmd.action == .removeTag {
            throw BrickRefusal(code: "offline", message: "Connect to Home Assistant to change brick tags.")
        }
        try applyLocally(cmd)
        store.enqueue(cmd)
        return .offline
    }

    private func applyLocally(_ cmd: PendingCommand) throws {
        let modes = store.modes
        let book = try store.updateBook { book -> LocalBook in
            BrickEngine.tick(&book)
            try BrickEngine.apply(cmd, to: &book)
            book.state.stats = BrickEngine.stats(book)
            return book
        }
        ShieldController.sync(book, modes: modes)
    }

    // MARK: Sync

    /// Sends queued offline commands in order. Refusals are dropped (HA said
    /// no - its state wins); connectivity errors stop the flush.
    func flushPending(_ client: HAClient? = nil) async {
        guard let client = client ?? HAClient.current(store) else { return }
        var queue = store.pending
        var lastRemote: RemoteState?
        while let cmd = queue.first {
            do {
                lastRemote = try await client.command(cmd, deviceId: store.deviceId)
            } catch HAError.refused(_, let remote) {
                lastRemote = remote ?? lastRemote
            } catch {
                break
            }
            queue.removeFirst()
            store.pending = queue
        }
        if let lastRemote, queue.isEmpty {
            await adopt(lastRemote, client: client)
        }
    }

    /// Pull state from HA. With `since` this long-polls.
    @discardableResult
    func refresh(since: Int? = nil, wait: Int = 25) async throws -> BrickState {
        guard let client = HAClient.current(store) else {
            return tickLocal()
        }
        await flushPending(client)
        let remote = try await client.state(since: since, wait: wait)
        if store.pending.isEmpty {
            await adopt(remote, client: client)
        }
        return store.book.state
    }

    /// Advance local timers (standalone / offline).
    @discardableResult
    func tickLocal() -> BrickState {
        let modes = store.modes
        let book = store.updateBook { book -> LocalBook in
            BrickEngine.tick(&book)
            book.state.stats = BrickEngine.stats(book)
            return book
        }
        ShieldController.sync(book, modes: modes)
        return book.state
    }

    /// Apply HA's state to the phone, then tell HA we did.
    func adopt(_ remote: RemoteState, client: HAClient?) async {
        let modes = store.modes
        let book = store.updateBook { book -> LocalBook in
            book.state = remote.state
            return book
        }
        ShieldController.sync(book, modes: modes)
        store.lastSync = Date()
        if let client { await heartbeat(client) }
    }

    /// Handle the `brick` dictionary from a push (works with no network).
    func handlePush(_ userInfo: [AnyHashable: Any]) async {
        guard let dict = userInfo["brick"] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: dict),
              let push = try? JSON.snakeDecoder.decode(PushState.self, from: data) else { return }
        let client = HAClient.current(store)
        if !store.pending.isEmpty {
            // We have unsent offline changes: reconcile properly or not at all.
            await flushPending(client)
            return
        }
        let current = store.book.state
        guard push.rev >= current.revision else { return }  // out-of-order push
        let modes = store.modes
        let book = store.updateBook { book -> LocalBook in
            book.state = push.merged(into: book.state)
            return book
        }
        ShieldController.sync(book, modes: modes)
        if let client {
            // Best effort: fetch the full state (stats, mode names) and ack.
            if let remote = try? await client.state() { await adopt(remote, client: client) }
        }
    }

    // MARK: Device registration

    func heartbeat(_ client: HAClient? = nil) async {
        guard let client = client ?? HAClient.current(store) else { return }
        var body: [String: Any] = [
            "device_id": store.deviceId,
            "name": store.connection?.deviceName ?? "iPhone",
            "authorized": ShieldController.isAuthorized,
            "applied_revision": store.book.state.revision,
            "modes": store.modes.map { ["id": $0.id, "name": $0.name] },
            "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
        ]
        if let token = store.apnsToken {
            body["apns_token"] = token
            body["apns_sandbox"] = APNsEnvironment.isSandbox
        }
        _ = try? await client.device(body)
    }

    /// Connect (or re-test) a Home Assistant server.
    func connect(baseURL: URL, token: String, deviceName: String) async throws {
        let client = HAClient(baseURL: baseURL, token: token)
        _ = try await client.state()  // validates URL + token + integration
        store.connection = HAConnection(baseURL: baseURL, deviceName: deviceName)
        store.token = token
        // Register first so HA learns our modes, then take HA's state.
        await heartbeat(client)
        try await refresh()
    }

    func disconnect() {
        store.connection = nil
        store.token = nil
        store.pending = []
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

/// Synchronous, network-free path for extensions (DeviceActivity monitor):
/// apply the command with the local engine and queue it for HA if connected.
enum OfflineRunner {
    @discardableResult
    static func run(_ cmd: PendingCommand, store: SharedStore = .shared) -> Bool {
        let modes = store.modes
        do {
            let book = try store.updateBook { book -> LocalBook in
                BrickEngine.tick(&book)
                try BrickEngine.apply(cmd, to: &book)
                book.state.stats = BrickEngine.stats(book)
                return book
            }
            ShieldController.sync(book, modes: modes)
            if store.connection != nil { store.enqueue(cmd) }
            return true
        } catch {
            NSLog("BrickHub: \(cmd.action.rawValue) refused offline: \(error.localizedDescription)")
            return false
        }
    }

    /// End expired timers locally (HA does the same on its side).
    static func tick(store: SharedStore = .shared) {
        let modes = store.modes
        let book = store.updateBook { book -> LocalBook in
            BrickEngine.tick(&book)
            return book
        }
        ShieldController.sync(book, modes: modes)
    }
}
