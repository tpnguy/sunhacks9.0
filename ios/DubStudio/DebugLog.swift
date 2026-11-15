import Foundation
import os

/// In-app debug log for the take pipeline. Every line also goes to the Xcode console
/// (filter by subsystem "com.dubstudio.app"). Shown in the hidden Debug settings sheet.
final class DebugLog: ObservableObject, @unchecked Sendable {
    static let shared = DebugLog()
    private let logger = Logger(subsystem: "com.dubstudio.app", category: "take")
    @Published private(set) var lines: [String] = []
    private let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()

    func log(_ message: String) {
        let line = "\(fmt.string(from: Date()))  \(message)"
        logger.info("\(line, privacy: .public)")
        print("[DubStudio] \(line)")
        DispatchQueue.main.async {
            self.lines.append(line)
            if self.lines.count > 300 { self.lines.removeFirst(self.lines.count - 300) }
        }
    }

    func clear() { DispatchQueue.main.async { self.lines.removeAll() } }
    var text: String { lines.joined(separator: "\n") }
}

func dlog(_ message: String) { DebugLog.shared.log(message) }

/// Logs when the main (UI) thread is blocked for more than 1 s, so a frozen screen shows up in the log.
enum MainThreadWatchdog {
    private static var lastPong = Date()
    private static var reported = false
    static func start() {
        let q = DispatchQueue(label: "dubstudio.mainwatchdog")
        let timer = DispatchSource.makeTimerSource(queue: q)
        timer.schedule(deadline: .now() + 1, repeating: 0.5)
        timer.setEventHandler {
            let stalled = Date().timeIntervalSince(lastPong) // handler already runs on q
            if stalled > 1.0, !reported {
                reported = true
                dlog("⚠️ MAIN THREAD FROZEN for \(String(format: "%.1f", stalled)) s (UI hang). In Xcode press Pause and copy Thread 1's stack.")
            }
            DispatchQueue.main.async { q.async { lastPong = Date(); if reported { reported = false; dlog("main thread recovered") } } }
        }
        timer.resume()
        holder = timer
    }
    private static var holder: DispatchSourceTimer?
}
