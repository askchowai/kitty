import KittyCore

extension ChatSession {
    /// What the chat's bot is doing, for its pose: a card waiting is the ask, the status line
    /// says thinking / tools / writing, a failed open is the error, a reconnect banner the
    /// metronome. Idle otherwise.
    var botState: BotFace.State {
        if !cards.isEmpty { return .awaitingApproval }
        if resumeError != nil, items.isEmpty { return .error }
        if banner?.hasPrefix("Reconnected") == true { return .reconnecting }
        guard isRunning else { return .idle }
        let s = statusLine ?? "Thinking…"
        if s == "Thinking…" || s == "Sending…" || s.hasPrefix("Queued") { return .thinking }
        if s.hasPrefix("Running") || s.hasPrefix("Preparing") { return .usingTool }
        return .working
    }
}
