import Foundation

public enum GatewayURLError: LocalizedError, Equatable {
    case empty
    case unsupportedScheme(String)
    case missingHost
    case containsQuery
    case invalid

    public var errorDescription: String? {
        switch self {
        case .empty: return "Enter the URL of your Hermes dashboard (`hermes serve`)."
        case .unsupportedScheme(let s): return "Unsupported scheme “\(s)”. Use https:// or http://."
        case .missingHost: return "The URL has no host."
        case .containsQuery: return "Remove the query string; enter only the dashboard's base URL."
        case .invalid: return "That does not look like a valid URL."
        }
    }
}

/// A normalized gateway base URL: scheme + host [+ port] [+ path prefix], no trailing slash.
public struct GatewayURL: Hashable, Codable, Sendable, CustomStringConvertible {
    public let base: URL

    private init(base: URL) { self.base = base }

    /// Normalizes user input. Accepts `https://host`, `https://host/path`, `http://host:9119`, `host:9119`.
    /// Strips trailing slashes and any pasted `/api/...` or `/chat` suffix; appends an optional path prefix.
    /// `defaultScheme` is what a bare `host:port` gets: https, or http for a home or tailnet
    /// address where there is no certificate to be had.
    public static func normalize(_ raw: String, pathPrefix: String? = nil, defaultScheme: String = "https") throws(GatewayURLError) -> GatewayURL {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { throw .empty }
        if !text.contains("://") {
            if text.lowercased().hasPrefix("ws://") { text = "http://" + text.dropFirst(5) }
            else if text.lowercased().hasPrefix("wss://") { text = "https://" + text.dropFirst(6) }
            else { text = defaultScheme + "://" + text }
        }
        guard var comps = URLComponents(string: text) else { throw .invalid }
        let scheme = (comps.scheme ?? "").lowercased()
        switch scheme {
        case "https", "http": comps.scheme = scheme
        case "wss": comps.scheme = "https"
        case "ws": comps.scheme = "http"
        default: throw .unsupportedScheme(scheme)
        }
        guard let host = comps.host, !host.isEmpty else { throw .missingHost }
        comps.host = host.lowercased()
        if comps.query != nil, comps.query?.isEmpty == false { throw .containsQuery }
        comps.query = nil
        comps.fragment = nil
        comps.user = nil
        comps.password = nil

        var path = comps.path
        // Drop pasted dashboard routes so `https://host/hermes/api/status` still yields `https://host/hermes`.
        for suffix in ["/api/ws", "/api/status", "/api/health", "/chat", "/login", "/api"] {
            if path.hasSuffix(suffix) { path = String(path.dropLast(suffix.count)) }
        }
        if let prefix = pathPrefix?.trimmingCharacters(in: .whitespacesAndNewlines), !prefix.isEmpty {
            var p = prefix
            if !p.hasPrefix("/") { p = "/" + p }
            while p.hasSuffix("/") { p.removeLast() }
            if !path.hasSuffix(p) { path += p }
        }
        while path.hasSuffix("/") { path.removeLast() }
        comps.path = path
        guard let url = comps.url else { throw .invalid }
        return GatewayURL(base: url)
    }

    public var isTLS: Bool { base.scheme == "https" }
    public var host: String { base.host ?? "" }
    public var port: Int? { base.port }
    public var pathPrefix: String { base.path }
    public var description: String { base.absoluteString }

    /// Whether the host is on a private network (RFC 1918, link-local, loopback, .local, or an unqualified name).
    /// A Tailscale address: a MagicDNS name (*.ts.net) or the 100.64.0.0/10 range.
    public var isTailscaleHost: Bool {
        let h = host
        if h.hasSuffix(".ts.net") { return true }
        let parts = h.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }

    public var isPrivateHost: Bool {
        let h = host
        if h == "localhost" || h.hasSuffix(".local") || !h.contains(".") { return true }
        let parts = h.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4 {
            if parts[0] == 10 || parts[0] == 127 { return true }
            if parts[0] == 192 && parts[1] == 168 { return true }
            if parts[0] == 172 && (16...31).contains(parts[1]) { return true }
            if parts[0] == 169 && parts[1] == 254 { return true }
        }
        if h.hasPrefix("fd") || h.hasPrefix("fe80") || h == "::1" { return true }
        return false
    }

    /// `base + path (+ query)`; `path` starts with `/`.
    public func api(_ path: String, query: [URLQueryItem] = []) -> URL {
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        comps.path = pathPrefix + (path.hasPrefix("/") ? path : "/" + path)
        // Every query value fully percent-encoded (Foundation leaves ":" and "/" bare in a query,
        // which is legal, but a reverse proxy's "block common exploits" rule sees "=http://" in
        // the native sign-in's redirect_uri and answers 403). Servers decode either form alike.
        comps.percentEncodedQuery = query.isEmpty ? nil : Self.encodedQuery(query)
        return comps.url!
    }

    /// `name=value&…` with names and values encoded down to RFC 3986 unreserved characters.
    public static func encodedQuery(_ items: [URLQueryItem]) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s }
        return items.map { enc($0.name) + ($0.value.map { "=" + enc($0) } ?? "") }.joined(separator: "&")
    }

    /// `ws(s)://host[:port]<prefix><path>?<query>`
    public func websocket(_ path: String, query: [URLQueryItem] = []) -> URL {
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        comps.scheme = isTLS ? "wss" : "ws"
        comps.path = pathPrefix + (path.hasPrefix("/") ? path : "/" + path)
        comps.queryItems = query.isEmpty ? nil : query
        return comps.url!
    }
}
