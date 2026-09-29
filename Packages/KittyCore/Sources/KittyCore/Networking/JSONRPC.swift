import Foundation

public struct RPCError: Error, Hashable, Sendable, LocalizedError {
    public var code: Int
    public var message: String
    public var data: JSONValue?
    public var errorDescription: String? { message }

    public static let methodNotFound = -32601

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

/// A gateway → client request (approval, clarify, sudo, secret, vault.*, …). Answered by a response frame with the same id.
public struct ServerRequest: Hashable, Sendable, Identifiable {
    public var id: String
    public var method: String
    public var params: JSONValue
    public var sessionID: String { params["session_id"]?.stringValue ?? "" }

    public init(id: String, method: String, params: JSONValue) {
        self.id = id
        self.method = method
        self.params = params
    }
}

/// One `event` notification frame.
public struct GatewayEvent: Hashable, Sendable {
    public var type: String
    public var sessionID: String
    public var payload: JSONValue
    public var seq: Int?

    public init(type: String, sessionID: String, payload: JSONValue, seq: Int? = nil) {
        self.type = type
        self.sessionID = sessionID
        self.payload = payload
        self.seq = seq
    }
}

public enum InboundFrame: Sendable {
    case response(id: JSONValue, result: JSONValue?, error: RPCError?)
    case event(GatewayEvent)
    case serverRequest(ServerRequest)
    case unknown

    public static func parse(_ text: String) -> InboundFrame {
        guard let data = text.data(using: .utf8), let obj = try? JSONDecoder().decode(JSONValue.self, from: data) else { return .unknown }
        return parse(obj)
    }

    public static func parse(_ obj: JSONValue) -> InboundFrame {
        let method = obj["method"]?.stringValue
        let id = obj["id"]
        if method == "event" {
            let params = obj["params"] ?? .null
            return .event(GatewayEvent(type: params["type"]?.stringValue ?? "",
                                       sessionID: params["session_id"]?.stringValue ?? "",
                                       payload: params["payload"] ?? .null,
                                       seq: params["seq"]?.intValue))
        }
        if let method, let id, let sid = id.stringValue {
            return .serverRequest(ServerRequest(id: sid, method: method, params: obj["params"] ?? .object([:])))
        }
        if let id, !id.isNull, method == nil {
            var err: RPCError?
            if let e = obj["error"] {
                err = RPCError(code: e["code"]?.intValue ?? -32000, message: e["message"]?.stringValue ?? "Unknown error", data: e["data"])
            }
            return .response(id: id, result: obj["result"], error: err)
        }
        return .unknown
    }
}

public enum RPCFrames {
    public static func request(id: Int, method: String, params: JSONValue) -> String {
        encode(.object(["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params]))
    }

    public static func response(id: String, result: JSONValue) -> String {
        encode(.object(["jsonrpc": "2.0", "id": .string(id), "result": result]))
    }

    public static func errorResponse(id: String, code: Int, message: String) -> String {
        encode(.object(["jsonrpc": "2.0", "id": .string(id), "error": .object(["code": .number(Double(code)), "message": .string(message)])]))
    }

    public static func encode(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
