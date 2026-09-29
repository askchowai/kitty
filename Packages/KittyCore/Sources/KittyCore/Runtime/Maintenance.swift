import Foundation
import Observation

// MARK: Log entries

/// Groups raw log lines into entries. A line that starts with a timestamp opens a new entry;
/// anything else (tracebacks, wrapped JSON) belongs to the entry before it.
public enum LogEntries {
    public static func group(_ lines: [String]) -> [String] {
        var out: [String] = []
        for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            if startsEntry(line) || out.isEmpty { out.append(line) } else { out[out.count - 1] += "\n" + line }
        }
        return out
    }

    /// `2026-09-22 20:39:05,879 INFO …` or ISO `2026-09-22T20:39:05`.
    public static func startsEntry(_ line: String) -> Bool {
        let s = Array(line.utf8)
        guard s.count >= 16 else { return false }
        let digits: [Int] = [0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15]
        for i in digits where !(s[i] >= 48 && s[i] <= 57) { return false }
        return s[4] == 45 && s[7] == 45 && (s[10] == 32 || s[10] == 84) && s[13] == 58
    }
}

// MARK: Maintenance (restart / update) over the dashboard's action endpoints

public struct UpdateCheck: Decodable, Sendable {
    public var installMethod: String?
    public var currentVersion: String?
    public var behind: Int?
    public var updateAvailable: Bool?
    public var canApply: Bool?
    public var updateCommand: String?
    public var message: String?
    public var commits: [UpdateCommit]?

    public struct UpdateCommit: Codable, Sendable, Hashable {
        public var sha: String?; public var summary: String?; public var author: String?; public var at: String?
        enum CodingKeys: String, CodingKey { case sha, summary, author, at }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sha = try c.decodeIfPresent(String.self, forKey: .sha)
            summary = try c.decodeIfPresent(String.self, forKey: .summary)
            author = try c.decodeIfPresent(String.self, forKey: .author)
            // Some gateways send the commit time as Unix seconds rather than a string.
            if let s = try? c.decodeIfPresent(String.self, forKey: .at) { at = s }
            else if let n = try? c.decodeIfPresent(Double.self, forKey: .at) { at = Date(timeIntervalSince1970: n).formatted(date: .abbreviated, time: .shortened) }
        }
    }

    public enum CodingKeys: String, CodingKey {
        case installMethod = "install_method", currentVersion = "current_version", behind
        case updateAvailable = "update_available", canApply = "can_apply", updateCommand = "update_command", message, commits
        case version, method
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Older dashboards name these `version` / `method`; accept either and never show "?".
        currentVersion = try c.decodeIfPresent(String.self, forKey: .currentVersion) ?? c.decodeIfPresent(String.self, forKey: .version)
        installMethod = try c.decodeIfPresent(String.self, forKey: .installMethod) ?? c.decodeIfPresent(String.self, forKey: .method)
        behind = try c.decodeIfPresent(Int.self, forKey: .behind)
        updateAvailable = try c.decodeIfPresent(Bool.self, forKey: .updateAvailable)
        canApply = try c.decodeIfPresent(Bool.self, forKey: .canApply)
        updateCommand = try c.decodeIfPresent(String.self, forKey: .updateCommand)
        message = try c.decodeIfPresent(String.self, forKey: .message)
        commits = try c.decodeIfPresent([UpdateCommit].self, forKey: .commits)
    }
}

/// Drives `hermes update` and `hermes gateway restart` through `/api/hermes/update`,
/// `/api/gateway/restart` and the `/api/actions/{name}/status` tail the dashboard exposes.
/// One per gateway, so a callout on the Model screen and the System screen show the same run.
@MainActor
@Observable
public final class MaintenanceModel {
    /// True when `error` is the dashboard's code-skew refusal rather than a real failure.
    public nonisolated static func isRestartRequired(_ error: String?) -> Bool {
        error?.localizedCaseInsensitiveContains("Restart required") == true
    }

    public enum Phase: Equatable { case idle, running(String), finished(String, exitCode: Int?), failed(String) }

    public var phase: Phase = .idle
    public var check: UpdateCheck?
    public var checkError: String?
    public var checking = false
    /// Tail of the action log while an action runs or after it finished.
    public var actionLog: [String] = []
    private var pollTask: Task<Void, Never>?

    public var isBusy: Bool { if case .running = phase { return true }; return false }

    public func checkForUpdate(runtime rt: GatewayRuntime, force: Bool) async {
        checking = true; defer { checking = false }
        do {
            check = try await rt.api.get("/api/hermes/update/check",
                                         query: force ? [URLQueryItem(name: "force", value: "true")] : [],
                                         profile: rt.selectedProfile)
            checkError = nil
        } catch { checkError = error.localizedDescription }
    }

    public func update(runtime rt: GatewayRuntime) async {
        await run(runtime: rt, name: "hermes-update", label: "Updating Hermes") {
            try await rt.api.send("POST", "/api/hermes/update", profile: rt.selectedProfile, body: EmptyBody())
        }
    }

    public func restartGateway(runtime rt: GatewayRuntime) async {
        await restartGateway(runtime: rt, profile: rt.selectedProfile)
    }

    /// Restart one profile's gateway (nil = the default profile's), not necessarily the one selected in the app.
    /// The action is reported through the dashboard that is restarting, so its status often never
    /// comes back: two minutes is the most it waits before calling that out.
    public func restartGateway(runtime rt: GatewayRuntime, profile: String?) async {
        await run(runtime: rt, name: "gateway-restart", label: "Restarting gateway", deadline: 120) {
            try await rt.api.send("POST", "/api/gateway/restart", profile: profile, body: EmptyBody())
        }
    }

    /// Ends the running action from outside with a verdict of its own (the caller saw the
    /// gateway come back by other means, say); a no-op when nothing is running.
    public func finishEarly(_ message: String) {
        guard case .running = phase else { return }
        phase = .finished(message, exitCode: nil)
        pollTask?.cancel(); pollTask = nil
    }

    private func run(runtime rt: GatewayRuntime, name: String, label: String, deadline: TimeInterval = 15 * 60, start: @escaping () async throws -> JSONValue) async {
        guard !isBusy else { return }
        pollTask?.cancel()
        actionLog = []
        phase = .running(label)
        do {
            let r = try await start()
            if r["ok"]?.boolValue == false {
                phase = .failed(r["message"]?.stringValue ?? r["error"]?.stringValue ?? "The gateway refused the action.")
                return
            }
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        pollTask = Task { await poll(runtime: rt, name: name, label: label, deadline: deadline) }
        await pollTask?.value
    }

    /// Tails the action until it exits. The update relaunches the dashboard mid-run, so transport
    /// errors while polling mean "restarting", not "failed" — keep going until the deadline.
    private func poll(runtime rt: GatewayRuntime, name: String, label: String, deadline: TimeInterval) async {
        let deadline = Date().addingTimeInterval(deadline)
        var sawRunning = false
        while !Task.isCancelled, Date() < deadline {
            try? await Task.sleep(for: .seconds(2))
            do {
                let st: JSONValue = try await rt.api.get("/api/actions/\(name)/status", query: [URLQueryItem(name: "lines", value: "60")], profile: rt.selectedProfile)
                actionLog = st["lines"]?.arrayValue?.map { $0.displayText } ?? []
                let running = st["running"]?.boolValue ?? false
                if running { sawRunning = true; phase = .running(label); continue }
                let code = st["exit_code"]?.intValue
                if let receipt = st["receipt"], let outcome = receipt["outcome"]?.stringValue {
                    phase = .finished(outcome == "success" ? "\(label): done" : "\(label): \(outcome)", exitCode: code)
                } else if code == nil, !sawRunning {
                    // Process registry lost (dashboard relaunched) before we ever saw it run; give it time.
                    phase = .running("\(label) — waiting for the dashboard to come back")
                    continue
                } else {
                    phase = .finished(code == 0 ? "\(label): done" : "\(label): exited \(code.map(String.init) ?? "?")", exitCode: code)
                }
                await rt.reconnectNow()
                return
            } catch {
                phase = .running("\(label) — dashboard restarting…")
            }
        }
        if case .running = phase { phase = .failed("\(label) did not report completion in time. Check the gateway machine.") }
    }
}

