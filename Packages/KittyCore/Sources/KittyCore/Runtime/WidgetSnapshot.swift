import Foundation

/// The little state every widget and complication draws from. Written by whichever app is
/// running (iPhone or watch) into the shared Keychain group; read by the widget extensions.
public struct WidgetSnapshot: Codable, Sendable, Equatable {
    public struct Chat: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var title: String
        public var profile: String
        public var lastActive: Double?
        public var running: Bool
        public var needsYou: Bool
        public init(id: String, title: String, profile: String, lastActive: Double?, running: Bool, needsYou: Bool) {
            self.id = id; self.title = title; self.profile = profile; self.lastActive = lastActive; self.running = running; self.needsYou = needsYou
        }
    }

    public var gatewayName: String
    public var connectionID: String
    public var profile: String
    public var needsAttention: Int
    public var chats: [Chat]
    public var contextPercent: Int?
    public var updatedAt: Date
    /// Whether the app's socket to the gateway was open when this was written; nil on snapshots
    /// from before the field existed, or written by a widget refresh that could not tell.
    public var connected: Bool?

    public init(gatewayName: String, connectionID: String, profile: String, needsAttention: Int, chats: [Chat], contextPercent: Int?, updatedAt: Date = Date(), connected: Bool? = nil) {
        self.gatewayName = gatewayName; self.connectionID = connectionID; self.profile = profile
        self.needsAttention = needsAttention; self.chats = chats; self.contextPercent = contextPercent; self.updatedAt = updatedAt
        self.connected = connected
    }

    public static let account = "widget.snapshot"

    public static func load() -> WidgetSnapshot? { Keychain.getCodable(WidgetSnapshot.self, account: account) }
    public func save() { try? Keychain.setCodable(self, account: Self.account) }

    public var activeChat: Chat? { chats.first { $0.running } }
    public var attentionChat: Chat? { chats.first { $0.needsYou } }
    public var runningCount: Int { chats.filter(\.running).count }
    /// How the status widget reads the gateway: reachable, unreachable, or unknown (stale).
    public enum Health: Sendable { case online, offline, unknown }
    public var health: Health {
        // Older than an hour, the last word is not worth much either way.
        guard Date().timeIntervalSince(updatedAt) < 3600, let connected else { return .unknown }
        return connected ? .online : .offline
    }
}
