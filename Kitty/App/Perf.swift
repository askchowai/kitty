import Foundation
import os

/// DEBUG only: counts how often the heavy views re-evaluate, printed once a second to the log
/// (`log stream --predicate 'subsystem == "Kitty" AND category == "perf"'`). Reads as a
/// per-second "how much work did a scroll cause" figure; zero cost in Release.
enum Perf {
    #if DEBUG
    nonisolated(unsafe) private static var counts: [String: Int] = [:]
    private static let lock = NSLock()
    private static let log = Logger(subsystem: "Kitty", category: "perf")
    nonisolated(unsafe) private static var timer: Timer?

    static func tick(_ name: String) {
        lock.lock(); counts[name, default: 0] += 1; lock.unlock()
        if timer == nil {
            DispatchQueue.main.async {
                guard timer == nil else { return }
                timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in flush() }
            }
        }
    }

    private static func flush() {
        lock.lock(); let snapshot = counts; counts = [:]; lock.unlock()
        guard !snapshot.isEmpty else { return }
        let line = snapshot.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        log.notice("\(line, privacy: .public)")
    }
    #else
    @inline(__always) static func tick(_ name: String) {}
    #endif
}
