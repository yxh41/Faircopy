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

/// Append-only diagnostics shared by the panel and the gateway.
///
/// `print` from an injected dylib lands in the host app's stdout, which nothing
/// on the device exposes — so the one line that says *why* an answer carried no
/// address was unreadable in practice. Both processes append to this file
/// instead (the same directory the other Faircopy state files live in), and it
/// can be opened with Filza or `cat`.
enum FaircopyDiag {
    /// KEEP IN SYNC with `FaircopyDiag.path` in the AIGate target.
    static let path = "/var/mobile/Library/Preferences/wiki.qaq.ai.gate/faircopy_diag.log"

    /// Small enough to paste, large enough for a long session.
    private static let maxBytes = 131_072
    private static let keepBytes = 32_768

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    static func log(_ message: String) {
        // NSLog as well: whatever already tails syslog on the device keeps
        // working, and this is the only copy that survives a sandbox denial.
        NSLog("[Faircopy] %@", message)
        let line = "\(stamp.string(from: Date())) \(message)\n"
        DispatchQueue.global(qos: .utility).async {
            append(line)
        }
    }

    private static func append(_ line: String) {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let data = line.data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
        trim(url)
    }

    /// Whether the gateway's last decision was to hand this upstream a real web
    /// -search switch, or to fall back to prompt-only.
    ///
    /// The panel cannot see the upstream, so without this the UI can only say
    /// "no link came back" — while the actual reason may be "this endpoint has
    /// no live search at all", in which case re-running online forever is futile.
    /// Read once per finished answer, never during rendering.
    static func lastGateLiveSearch() -> Bool? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        let text = String(decoding: data.suffix(keepBytes), as: UTF8.self)
        var result: Bool?
        for line in text.split(separator: "\n") {
            if line.contains("gate: web plugin injected") {
                result = true
            } else if line.contains("gate: prompt-only") {
                result = false
            }
        }
        return result
    }

    /// Keeps the file paste-sized: when it outgrows `maxBytes` the oldest lines
    /// are dropped rather than the newest, which are the interesting ones.
    private static func trim(_ url: URL) {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              size > maxBytes,
              let data = try? Data(contentsOf: url)
        else { return }
        try? Data(data.suffix(keepBytes)).write(to: url)
    }
}
