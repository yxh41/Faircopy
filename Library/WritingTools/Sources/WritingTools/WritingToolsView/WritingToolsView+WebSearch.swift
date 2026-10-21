//
//  WritingToolsView+WebSearch.swift
//  WritingTools
//
//  Created for Faircopy 3.0.50 — opt-in web search for 提问.
//

import Foundation

/// Hands a one-shot "this request may go online" flag to the AIGate daemon.
///
/// The panel is a dylib inside an arbitrary host app and the OpenAI SDK this
/// panel uses has a fixed request shape (`ChatQuery` has no free-form body), so
/// the flag cannot ride along with the HTTP request. The gateway already reads
/// and rewrites every request body to swap the model id, so it picks the flag up
/// from the shared preferences directory instead — the same channel the panel
/// claim ticket and the AppSearch store already use.
///
/// `at` is a hard requirement, not decoration: without an expiry a single
/// opt-in would leave every later request (proofread, translate, rewrite…)
/// paying for `:online` and waiting on web fetches.
enum FaircopyWebSearchStore {
    /// KEEP IN SYNC with `FaircopyWebSearch.path` in the AIGate target.
    static let path = "/var/mobile/Library/Preferences/wiki.qaq.ai.gate/faircopy_web_search.json"

    /// Must stay well above the time between writing the flag and the gateway
    /// reading it (one local request) and well below the time a user might
    /// come back for a second task in the same panel.
    static let maxAge: TimeInterval = 60

    private struct Payload: Codable {
        let enabled: Bool
        let at: TimeInterval
    }

    /// Records the user's choice for the run that is about to start. Passing
    /// `false` still writes the file so a previous opt-in is dropped
    /// immediately instead of lingering until it expires.
    static func markRequested(_ enabled: Bool) {
        let payload = Payload(enabled: enabled, at: Date().timeIntervalSince1970)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        do {
            try data.write(to: url, options: .atomic)
            print("[Faircopy] web search flag written: \(enabled)")
        } catch {
            // Non-fatal: the request still runs, just without live search.
            print("[Faircopy] web search flag write failed: \(error.localizedDescription)")
        }
    }
}
