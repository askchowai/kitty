import Foundation

public enum HermesAPIError: LocalizedError, Sendable {
    case transport(String)
    case htmlResponse(status: Int)
    case http(status: Int, detail: String)
    case unauthorized(String)
    case decoding(String)
    case sessionExpired

    public var errorDescription: String? {
        switch self {
        case .transport(let m): return m
        case .htmlResponse:
            return "This URL is not the Hermes dashboard API (got an HTML login/page). Use the `hermes serve` / dashboard URL, add Access service-token headers if Cloudflare Access is on, and confirm the tunnel upgrades WebSockets."
        case .http(let status, let detail): return detail.isEmpty ? "HTTP \(status)" : "\(detail) (HTTP \(status))"
        case .unauthorized(let d): return d.isEmpty ? "The gateway rejected the credentials (401)." : d
        case .decoding(let m): return "Unexpected response from the gateway: \(m)"
        case .sessionExpired: return "Your session has expired. Sign in again."
        }
    }

    public var isUnauthorized: Bool {
        if case .unauthorized = self { return true }
        if case .sessionExpired = self { return true }
        return false
    }
}

public struct EmptyBody: Encodable, Sendable { public init() {} }

/// REST client for one gateway. Applies auth + Access headers, `?profile=`, 401→refresh→retry, and HTML detection.
public actor HermesAPI {
    public let gateway: GatewayURL
    public private(set) var signer: RequestSigner
    private let urlSession: URLSession
    /// Called on 401 for bearer modes; returns a refreshed signer or throws.
    public var refresher: (@Sendable () async throws -> RequestSigner)?
    private var refreshInFlight: Task<RequestSigner, Error>?

    public init(gateway: GatewayURL, signer: RequestSigner, urlSession: URLSession = HermesAPI.makeSession()) {
        self.gateway = gateway
        self.signer = signer
        self.urlSession = urlSession
    }

    public static func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieAcceptPolicy = .never
        cfg.httpShouldSetCookies = false
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 300
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }

    public func updateSigner(_ s: RequestSigner) { signer = s }
    public func setRefresher(_ r: (@Sendable () async throws -> RequestSigner)?) { refresher = r }

    // MARK: Typed helpers

    public func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], profile: String? = nil, authenticated: Bool = true) async throws -> T {
        let (data, _) = try await raw("GET", path, query: query, profile: profile, body: nil, authenticated: authenticated)
        return try decode(data)
    }

    public func send<T: Decodable, B: Encodable & Sendable>(_ method: String, _ path: String, query: [URLQueryItem] = [], profile: String? = nil, body: B) async throws -> T {
        let encoded = try JSONEncoder().encode(body)
        let (data, _) = try await raw(method, path, query: query, profile: profile, body: (encoded, "application/json"), authenticated: true)
        return try decode(data)
    }

    public func send<T: Decodable>(_ method: String, _ path: String, query: [URLQueryItem] = [], profile: String? = nil, json: JSONValue) async throws -> T {
        let encoded = try JSONEncoder().encode(json)
        let (data, _) = try await raw(method, path, query: query, profile: profile, body: (encoded, "application/json"), authenticated: true)
        return try decode(data)
    }

    public func sendMultipart<T: Decodable>(_ path: String, query: [URLQueryItem] = [], profile: String? = nil, fields: [String: String], fileField: String, filename: String, fileData: Data, mimeType: String) async throws -> T {
        let boundary = "Kitty-\(UUID().uuidString)"
        var body = Data()
        for (k, v) in fields {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(filename)\"\r\nContent-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        let (data, _) = try await raw("POST", path, query: query, profile: profile, body: (body, "multipart/form-data; boundary=\(boundary)"), authenticated: true)
        return try decode(data)
    }

    /// Downloads a file to a temporary location (caller moves/deletes it).
    public func download(_ path: String, query: [URLQueryItem] = []) async throws -> URL {
        var request = URLRequest(url: gateway.api(path, query: query))
        signer.apply(to: &request)
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        let (tmp, response) = try await urlSession.download(for: request)
        guard let http = response as? HTTPURLResponse else { throw HermesAPIError.transport("No HTTP response") }
        if http.statusCode >= 400 {
            let data = (try? Data(contentsOf: tmp)) ?? Data()
            throw Self.error(for: http, data: data)
        }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let name = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "path" })?.value.map { ($0 as NSString).lastPathComponent } ?? "download"
        let final = dest.appendingPathComponent(name.isEmpty ? "download" : name)
        try? FileManager.default.removeItem(at: final)
        try FileManager.default.moveItem(at: tmp, to: final)
        return final
    }

    // MARK: Core

    public func raw(_ method: String, _ path: String, query: [URLQueryItem] = [], profile: String? = nil, body: (Data, String)?, authenticated: Bool) async throws -> (Data, HTTPURLResponse) {
        var items = query
        if let profile, !profile.isEmpty, !items.contains(where: { $0.name == "profile" }) {
            items.append(URLQueryItem(name: "profile", value: profile))
        }
        let (data, http) = try await perform(method, path, items: items, body: body, authenticated: authenticated)
        if http.statusCode == 401, authenticated, signer.authMode.usesBearer, let refresher {
            let refreshed = try await coalescedRefresh(refresher)
            signer = refreshed
            let (data2, http2) = try await perform(method, path, items: items, body: body, authenticated: authenticated)
            if http2.statusCode >= 400 { throw Self.error(for: http2, data: data2) }
            return (data2, http2)
        }
        if http.statusCode >= 400 { throw Self.error(for: http, data: data) }
        if Self.looksLikeHTML(http: http, data: data) { throw HermesAPIError.htmlResponse(status: http.statusCode) }
        return (data, http)
    }

    private func coalescedRefresh(_ refresher: @Sendable @escaping () async throws -> RequestSigner) async throws -> RequestSigner {
        if let t = refreshInFlight { return try await t.value }
        let t = Task { try await refresher() }
        refreshInFlight = t
        defer { refreshInFlight = nil }
        return try await t.value
    }

    private func perform(_ method: String, _ path: String, items: [URLQueryItem], body: (Data, String)?, authenticated: Bool) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: gateway.api(path, query: items))
        request.httpMethod = method
        signer.apply(to: &request, includeCredential: authenticated)
        if let (data, type) = body {
            request.httpBody = data
            request.setValue(type, forHTTPHeaderField: "Content-Type")
        }
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw HermesAPIError.transport("No HTTP response") }
            return (data, http)
        } catch let e as HermesAPIError {
            throw e
        } catch {
            throw HermesAPIError.transport(error.localizedDescription)
        }
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try JSONCoding.decoder.decode(T.self, from: data) }
        catch { throw HermesAPIError.decoding(String(describing: error).prefix(200).description) }
    }

    public nonisolated static func looksLikeHTML(http: HTTPURLResponse, data: Data) -> Bool {
        let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if type.contains("text/html") { return true }
        if type.contains("application/json") { return false }
        let prefix = String(decoding: data.prefix(64), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return prefix.hasPrefix("<!doctype") || prefix.hasPrefix("<html")
    }

    public nonisolated static func error(for http: HTTPURLResponse, data: Data) -> HermesAPIError {
        if looksLikeHTML(http: http, data: data) { return .htmlResponse(status: http.statusCode) }
        var detail = ""
        if let obj = try? JSONDecoder().decode(JSONValue.self, from: data) {
            if let d = obj["detail"]?.stringValue { detail = d }
            else if let d = obj["detail"] { detail = d.displayText }
            else if let e = obj["error"]?.stringValue { detail = e }
            if obj["error"]?.stringValue == "session_expired" { return .sessionExpired }
        } else if let s = String(data: data, encoding: .utf8), s.count < 300 { detail = s }
        if http.statusCode == 401 { return .unauthorized(detail) }
        return .http(status: http.statusCode, detail: detail)
    }
}
