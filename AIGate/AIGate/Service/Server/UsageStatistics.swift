//
//  UsageStatistics.swift
//  AIGate
//
//  Tracks token usage reported by upstream providers.
//

import Foundation

struct UsageStats: Codable, Equatable {
    var promptTokens: Int
    var completionTokens: Int
    var requestCount: Int
    var lastUpdated: TimeInterval

    static let empty = UsageStats(
        promptTokens: 0,
        completionTokens: 0,
        requestCount: 0,
        lastUpdated: 0
    )
}

/// Accumulates usage parsed from upstream SSE streams. All reads and writes go
/// straight through GlobalStorage so NIO threads never touch Combine.
final class UsageStatistics {
    static let shared = UsageStatistics()

    private let storageKey = "UsageStats"
    private let lock = NSLock()
    private var stats: UsageStats

    private init() {
        if let data = GlobalStorage.shared.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(UsageStats.self, from: data)
        {
            stats = decoded
        } else {
            stats = .empty
        }
    }

    func record(promptTokens: Int, completionTokens: Int) {
        lock.lock()
        defer { lock.unlock() }
        stats.promptTokens += max(0, promptTokens)
        stats.completionTokens += max(0, completionTokens)
        stats.requestCount += 1
        stats.lastUpdated = Date().timeIntervalSince1970
        persist()
    }

    func current() -> UsageStats {
        lock.lock()
        defer { lock.unlock() }
        return stats
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        stats = .empty
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(stats) else { return }
        GlobalStorage.shared.set(data, forKey: storageKey)
    }
}

extension UsageStatistics {
    /// KEEP IN SYNC with FaircopyImageOCR.directory — the shared drop box the
    /// OCR hand-off already uses, chosen only because it is writable from both
    /// the app and the service daemon.
    static let diagnosticLogPath =
        "/var/mobile/Library/Preferences/wiki.qaq.ai.gate/faircopy_usage.log"

    /// One line per response that carried no parsable usage object (3.0.88).
    ///
    /// A panel showing 0 tokens with a healthy request count is exactly what
    /// the fallback in `AIGateProxySwitchHandler.channelInactive` produces, and
    /// from the panel alone three very different causes look identical: a
    /// provider that never reports usage (a relay ignoring
    /// `stream_options.include_usage`), one that reports it under other names
    /// (`input_tokens`/`output_tokens`), or a compressed body the byte scan
    /// cannot see. The key names left in the body separate all three, so they
    /// are what gets logged.
    static func appendDiagnostic(_ line: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let entry = "\(formatter.string(from: Date())) \(line)\n"
        let url = URL(fileURLWithPath: diagnosticLogPath)
        let directory = (diagnosticLogPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )
        var existing = (try? Data(contentsOf: url)) ?? Data()
        if existing.count > 8 * 1024 {
            existing = Data()
        }
        existing.append(Data(entry.utf8))
        try? existing.write(to: url, options: .atomic)
    }
}
