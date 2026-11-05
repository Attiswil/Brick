import Foundation

struct RemoteMode: Decodable, Equatable {
    var id: String
    var name: String
}

/// HA's public state: `BrickState` plus the mode list.
struct RemoteState: Decodable {
    var state: BrickState
    var modes: [RemoteMode]

    init(from decoder: Decoder) throws {
        state = try BrickState(from: decoder)
        let c = try decoder.container(keyedBy: Keys.self)
        modes = try c.decodeIfPresent([RemoteMode].self, forKey: .modes) ?? []
    }

    private enum Keys: String, CodingKey { case modes }
}

private struct Envelope: Decodable {
    var ok: Bool
    var code: String?
    var message: String?
    var note: String?
    var state: RemoteState?
}

enum HAError: LocalizedError {
    case refused(BrickRefusal, RemoteState?)
    case http(Int, String)
    case network(Error)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .refused(let r, _): return r.message
        case .http(let code, let msg): return "Home Assistant returned \(code): \(msg)"
        case .network(let e): return "Can't reach Home Assistant: \(e.localizedDescription)"
        case .badResponse: return "Home Assistant sent something unexpected. Is Brick Hub installed?"
        }
    }

    /// True when it's worth falling back to offline mode.
    var isConnectivity: Bool {
        switch self {
        case .network: return true
        case .http(let code, _): return code >= 500 || code == 404
        default: return false
        }
    }
}

struct HAClient {
    var baseURL: URL
    var token: String
    var session: URLSession = .shared

    static func current(_ store: SharedStore = .shared) -> HAClient? {
        guard let conn = store.connection, let token = store.token else { return nil }
        return HAClient(baseURL: conn.baseURL, token: token)
    }

    private func request(_ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil,
                         timeout: TimeInterval = 15) async throws -> RemoteState {
        var comps = URLComponents(url: baseURL.appendingPathComponent("api/brick_hub/\(path)"),
                                  resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!, timeoutInterval: timeout)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw HAError.network(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let env = try? JSON.snakeDecoder.decode(Envelope.self, from: data)
        if status == 409, let env {
            throw HAError.refused(BrickRefusal(code: env.code ?? "refused", message: env.message ?? "Refused"), env.state)
        }
        guard status == 200 else {
            let msg = env?.message ?? String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw HAError.http(status, status == 401 ? "The access token was rejected" : msg)
        }
        guard let state = env?.state else { throw HAError.badResponse }
        return state
    }

    func state(since: Int? = nil, wait: Int = 25) async throws -> RemoteState {
        guard let since else { return try await request("state") }
        return try await request(
            "state",
            query: [URLQueryItem(name: "since", value: String(since)), URLQueryItem(name: "wait", value: String(wait))],
            timeout: TimeInterval(wait + 10)
        )
    }

    func command(_ cmd: PendingCommand, deviceId: String) async throws -> RemoteState {
        var body: [String: Any] = [
            "action": cmd.action.rawValue,
            "method": cmd.method.rawValue,
            "event_id": cmd.id,
            "occurred_at": ISO8601.string(cmd.occurredAt),
            "device_id": deviceId,
        ]
        if let v = cmd.modeId { body["mode_id"] = v }
        if let v = cmd.durationMinutes { body["duration_minutes"] = v }
        if let v = cmd.tagId { body["tag_id"] = v }
        if let v = cmd.tagName { body["tag_name"] = v }
        if let v = cmd.source { body["source"] = v }
        return try await request("command", body: body)
    }

    func device(_ body: [String: Any]) async throws -> RemoteState {
        try await request("device", body: body)
    }
}
