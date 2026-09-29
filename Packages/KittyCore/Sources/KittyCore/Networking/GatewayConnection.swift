import Foundation

public enum AuthMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case sessionToken
    case password
    case oauth

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .sessionToken: return "Session token"
        case .password: return "Username & password"
        case .oauth: return "Sign in with browser"
        }
    }
    public var usesBearer: Bool { self != .sessionToken }
}

/// Optional Cloudflare Access service-token pair. Headers are attached only when BOTH values are set.
public struct CloudflareAccess: Hashable, Codable, Sendable {
    public var clientId: String = ""
    public var clientSecret: String = ""

    public var isConfigured: Bool { !clientId.isEmpty && !clientSecret.isEmpty }
    public var isPartiallyConfigured: Bool { !isConfigured && (!clientId.isEmpty || !clientSecret.isEmpty) }

    public static let clientIdHeader = "CF-Access-Client-Id"
    public static let clientSecretHeader = "CF-Access-Client-Secret"

    public var headers: [String: String] {
        guard isConfigured else { return [:] }
        return [Self.clientIdHeader: clientId, Self.clientSecretHeader: clientSecret]
    }

    public init(clientId: String = "", clientSecret: String = "") {
        self.clientId = clientId
        self.clientSecret = clientSecret
    }
}

/// Non-secret metadata for one saved gateway. Secrets live in `GatewaySecrets` (Keychain).
public struct GatewayConnection: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var name: String
    public var gateway: GatewayURL
    public var authMode: AuthMode
    public var authProvider: String?
    public var createdAt: Date = Date()
    public var lastProfile: String?
    public var hasAccessHeaders: Bool = false
    public var lastVersion: String?
    /// How the phone reaches the gateway ("local", "tailscale", "cloudflare", "other"); only
    /// for the form's help and the list's label, the URL and headers do the work.
    public var connectionKind: String?

    public init(id: UUID = UUID(), name: String, gateway: GatewayURL, authMode: AuthMode, authProvider: String? = nil, createdAt: Date = Date(), lastProfile: String? = nil, hasAccessHeaders: Bool = false, lastVersion: String? = nil, connectionKind: String? = nil) {
        self.id = id
        self.name = name
        self.gateway = gateway
        self.authMode = authMode
        self.authProvider = authProvider
        self.createdAt = createdAt
        self.lastProfile = lastProfile
        self.hasAccessHeaders = hasAccessHeaders
        self.lastVersion = lastVersion
        self.connectionKind = connectionKind
    }
}

/// Everything sensitive for one gateway, stored in the Keychain under the connection id.
public struct GatewaySecrets: Codable, Hashable, Sendable {
    public var sessionToken: String?
    public var accessToken: String?
    public var refreshToken: String?
    public var expiresAt: Double?
    public var provider: String?
    public var userId: String?
    public var access: CloudflareAccess = CloudflareAccess()

    public var bearer: String? { accessToken?.isEmpty == false ? accessToken : nil }
    public var accessTokenExpiresSoon: Bool {
        guard let expiresAt else { return false }
        return Date(timeIntervalSince1970: expiresAt).timeIntervalSinceNow < 60
    }

    public init(sessionToken: String? = nil, accessToken: String? = nil, refreshToken: String? = nil, expiresAt: Double? = nil, provider: String? = nil, userId: String? = nil, access: CloudflareAccess = CloudflareAccess()) {
        self.sessionToken = sessionToken
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.provider = provider
        self.userId = userId
        self.access = access
    }
}
