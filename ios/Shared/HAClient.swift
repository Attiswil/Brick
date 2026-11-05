import Foundation

/// What the phone tells Home Assistant: its real state, so HA can mirror it.
struct PhoneReport: Encodable {
    struct Mode: Encodable { var id: String; var name: String }

    var deviceId: String
    var name: String
    var appVersion: String
    var authorized: Bool
    var apnsToken: String?
    var apnsSandbox: Bool?
    var modes: [Mode]
    var tagHashes: [String]
    var rules: BrickRules
    var state: BrickState
    var stats: BrickStats
    var results: [CommandResult]
}

private struct CommandsEnvelope: Decodable {
    var ok: Bool
    var commands: [RemoteCommand]?
    var message: String?
}

enum HAError: LocalizedError {
    case http(Int, String)
    case network(Error)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .http(401, _): return "Home Assistant rejected the access token."
        case .http(404, _): return "Brick Hub isn't installed in Home Assistant (or HA needs a restart)."
        case .http(let code, let msg): return "Home Assistant returned \(code): \(msg)"
        case .network(let e): return "Can't reach Home Assistant: \(e.localizedDescription)"
        case .badResponse: return "Home Assistant sent something unexpected."
        }
    }
}

/// Optional link to Home Assistant. The phone works the same without it;
/// HA only sends commands and mirrors what the phone reports.
struct HAClient {
    var baseURL: URL
    var token: String
    var session: URLSession = .shared

    static func current(_ store: SharedStore = .shared) -> HAClient? {
        guard let conn = store.connection, let token = store.token else { return nil }
        return HAClient(baseURL: conn.baseURL, token: token)
    }

    private func send(_ path: String, query: [URLQueryItem] = [], body: Data? = nil,
                      timeout: TimeInterval = 15) async throws -> [RemoteCommand] {
        var comps = URLComponents(url: baseURL.appendingPathComponent("api/brick_hub/\(path)"),
                                  resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!, timeoutInterval: timeout)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw HAError.network(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let env = try? JSON.snakeDecoder.decode(CommandsEnvelope.self, from: data)
        guard status == 200 else {
            throw HAError.http(status, env?.message ?? String(decoding: data.prefix(200), as: UTF8.self))
        }
        guard let env, env.ok else { throw HAError.badResponse }
        return env.commands ?? []
    }

    /// Send our state (and command results); get back any waiting commands.
    func report(_ report: PhoneReport) async throws -> [RemoteCommand] {
        try await send("report", body: try JSON.snakeEncoder.encode(report))
    }

    /// Long-poll for commands while the app is open.
    func commands(deviceId: String, wait: Int = 25) async throws -> [RemoteCommand] {
        try await send("commands",
                       query: [URLQueryItem(name: "device_id", value: deviceId),
                               URLQueryItem(name: "wait", value: String(wait))],
                       timeout: TimeInterval(wait + 10))
    }
}
