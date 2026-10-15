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
