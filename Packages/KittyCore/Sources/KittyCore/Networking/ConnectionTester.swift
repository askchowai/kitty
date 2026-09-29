import Foundation

public struct ConnectionTestStep: Identifiable, Hashable, Sendable {
    public enum Status: Hashable, Sendable { case pending, running, passed(String), failed(String) }
    public var id: String
    public var title: String
    public var status: Status = .pending

    public init(id: String, title: String, status: Status = .pending) {
        self.id = id
        self.title = title
        self.status = status
    }
}

public struct ConnectionTestOutcome: Sendable {
    public var steps: [ConnectionTestStep]
    public var version: String?
    public var authRequired: Bool?
    public var succeeded: Bool { steps.allSatisfy { if case .passed = $0.status { return true }; return false } }

    public init(steps: [ConnectionTestStep], version: String? = nil, authRequired: Bool? = nil) {
        self.steps = steps
        self.version = version
        self.authRequired = authRequired
    }
}

/// Runs the three-leg test the desktop performs: `/api/status` JSON, an authenticated call, and a live `/api/ws` upgrade.
public enum ConnectionTester {
    public static func run(connection: GatewayConnection, secrets: GatewaySecrets, progress: @Sendable @escaping ([ConnectionTestStep]) -> Void) async -> ConnectionTestOutcome {
        var steps = [
            ConnectionTestStep(id: "status", title: "GET /api/status returns JSON"),
            ConnectionTestStep(id: "auth", title: "Credentials accepted"),
            ConnectionTestStep(id: "ws", title: "WebSocket /api/ws opens and gateway.ready arrives"),
        ]
        func update(_ i: Int, _ s: ConnectionTestStep.Status) { steps[i].status = s; progress(steps) }

        let signer = RequestSigner(authMode: connection.authMode, secrets: secrets)
        let api = HermesAPI(gateway: connection.gateway, signer: signer)
        var version: String?
        var authRequired: Bool?

        update(0, .running)
        do {
            let status: GatewayStatusResponse = try await api.get("/api/status", authenticated: false)
            version = status.version
            authRequired = status.authRequired
            let gate = (status.authRequired ?? false) ? "auth gate on (\(status.authProviders?.joined(separator: ", ") ?? "-"))" : "no auth gate"
            update(0, .passed("Hermes \(status.version ?? "?"), \(gate)"))
        } catch {
            update(0, .failed(error.localizedDescription))
            return ConnectionTestOutcome(steps: steps, version: nil, authRequired: nil)
        }

        update(1, .running)
        do {
            if authRequired == true {
                if !connection.authMode.usesBearer {
                    update(1, .failed("This gateway has its auth gate enabled (non-loopback bind). Use “Sign in with browser” or “Username & password” instead of a session token."))
                    return ConnectionTestOutcome(steps: steps, version: version, authRequired: authRequired)
                }
                let me: AuthMeResponse = try await api.get("/api/auth/me")
                update(1, .passed("Signed in as \(me.displayName ?? me.email ?? me.userId ?? "user") via \(me.provider ?? "provider")"))
            } else {
                if connection.authMode.usesBearer {
                    update(1, .failed("This gateway has no auth gate; it expects the dashboard session token (HERMES_DASHBOARD_SESSION_TOKEN). Switch the auth mode to “Session token”."))
                    return ConnectionTestOutcome(steps: steps, version: version, authRequired: authRequired)
                }
                let profiles: ProfilesResponse = try await api.get("/api/profiles")
                update(1, .passed("Session token accepted; \(profiles.profiles.count) profile(s)"))
            }
        } catch {
            update(1, .failed(error.localizedDescription))
            return ConnectionTestOutcome(steps: steps, version: version, authRequired: authRequired)
        }

        update(2, .running)
        do {
            var ticket: String?
            if connection.authMode.usesBearer {
                let r: [String: JSONValue] = try await api.send("POST", "/api/auth/ws-ticket", body: EmptyBody())
                ticket = r["ticket"]?.stringValue
            }
            let url = RequestSigner.websocketURL(gateway: connection.gateway, token: signer.sessionToken, ticket: ticket)
            let result = try await probeWebSocket(url: url, headers: signer.publicHeaders)
            update(2, .passed(result))
        } catch {
            let hint = " HTTP works but the WebSocket failed: check that your reverse proxy or Cloudflare tunnel forwards Upgrade requests to /api/ws, that Access (if any) receives the same service-token headers, and that the gateway's dashboard.public_url matches this host."
            update(2, .failed(error.localizedDescription + hint))
        }
        return ConnectionTestOutcome(steps: steps, version: version, authRequired: authRequired)
    }

    /// Opens the socket and waits for the first frame (`gateway.ready`).
    public static func probeWebSocket(url: URL, headers: [String: String], timeout: Double = 12) async throws -> String {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }
        var req = URLRequest(url: url)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let task = session.webSocketTask(with: req)
        task.resume()
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                do {
                    let msg = try await task.receive()
                    let text: String
                    switch msg {
                    case .string(let s): text = s
                    case .data(let d): text = String(decoding: d, as: UTF8.self)
                    @unknown default: text = ""
                    }
                    task.cancel(with: .normalClosure, reason: nil)
                    if case .event(let ev) = InboundFrame.parse(text), ev.type == "gateway.ready" { return "gateway.ready received" }
                    return "socket open (first frame: \(text.prefix(40)))"
                } catch {
                    let code = task.closeCode.rawValue
                    let reason = task.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? ""
                    switch code {
                    case 4401: throw SocketError.closed(code: code, reason: "credential rejected (\(reason))")
                    case 4403: throw SocketError.closed(code: code, reason: "host/origin guard (\(reason)); set dashboard.public_url to this URL")
                    case 4408: throw SocketError.closed(code: code, reason: "peer not allowed (loopback-only bind)")
                    default:
                        if code > 0 { throw SocketError.closed(code: code, reason: reason) }
                        throw HermesAPIError.transport(error.localizedDescription)
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                task.cancel(with: .goingAway, reason: nil)
                throw SocketError.timeout("the WebSocket upgrade")
            }
            let r = try await group.next()!
            group.cancelAll()
            return r
        }
    }
}
