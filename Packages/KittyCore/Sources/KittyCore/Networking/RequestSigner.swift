import Foundation

/// Produces the auth + Access headers for REST calls and the query credential for the WebSocket upgrade.
public struct RequestSigner: Hashable, Sendable {
    public var authMode: AuthMode
    public var sessionToken: String?
    public var bearer: String?
    public var access: CloudflareAccess

    public static let sessionTokenHeader = "X-Hermes-Session-Token"

    public init(authMode: AuthMode, secrets: GatewaySecrets) {
        self.authMode = authMode
        self.sessionToken = secrets.sessionToken
        self.bearer = secrets.bearer
        self.access = secrets.access
    }

    public init(authMode: AuthMode, sessionToken: String? = nil, bearer: String? = nil, access: CloudflareAccess = CloudflareAccess()) {
        self.authMode = authMode
        self.sessionToken = sessionToken
        self.bearer = bearer
        self.access = access
    }

    /// Headers for every HTTP request and the WebSocket handshake.
    public var headers: [String: String] {
        var h = access.headers
        switch authMode {
        case .sessionToken:
            if let t = sessionToken, !t.isEmpty { h[Self.sessionTokenHeader] = t }
        case .password, .oauth:
            if let b = bearer, !b.isEmpty { h["Authorization"] = "Bearer \(b)" }
        }
        return h
    }

    /// Headers with no gateway credential (public endpoints); Access headers still apply.
    public var publicHeaders: [String: String] { access.headers }

    public func apply(to request: inout URLRequest, includeCredential: Bool = true) {
        for (k, v) in includeCredential ? headers : publicHeaders { request.setValue(v, forHTTPHeaderField: k) }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
    }

    /// The `?token=` credential for loopback/session-token gateways; gated gateways use a minted ticket instead.
    public var websocketTokenQuery: URLQueryItem? {
        guard authMode == .sessionToken, let t = sessionToken, !t.isEmpty else { return nil }
        return URLQueryItem(name: "token", value: t)
    }

    public static func websocketURL(gateway: GatewayURL, token: String?, ticket: String?) -> URL {
        var items: [URLQueryItem] = []
        if let ticket, !ticket.isEmpty { items.append(URLQueryItem(name: "ticket", value: ticket)) }
        else if let token, !token.isEmpty { items.append(URLQueryItem(name: "token", value: token)) }
        return gateway.websocket("/api/ws", query: items)
    }
}
