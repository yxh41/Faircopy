//
//  AIGateUpstream.swift
//  AIGate
//
//  Created by 秋星桥 on 2024/8/15.
//

import Dispatch
import Foundation

struct AIGateUpstream {
    let url: URL
    let host: String
    let port: Int
    let tls: Bool
    let key: String
    let mid: String // model id

    init(url: URL, host: String, port: Int, tls: Bool, key: String, mid: String) {
        self.url = url
        self.host = host
        self.port = port
        self.tls = tls
        self.key = key
        self.mid = mid
    }
}

extension AIGateUpstream {
    init?() {
        let cvm = Configuration.shared
        guard let endpoint = cvm.activatedEndpoint else { return nil }

        guard let host = endpoint.url.host else { return nil }
        guard let scheme = endpoint.url.scheme else { return nil }

        let tls = scheme.lowercased() == "https"
        let port = endpoint.url.port ?? (tls ? 443 : 80)
        let key = endpoint.token
        let model = endpoint.model

        guard model.data(using: .utf8) != nil else { return nil }

        self.init(
            url: endpoint.url,
            host: host,
            port: port,
            tls: tls,
            key: key,
            mid: model
        )
    }
}

// MARK: - Faircopy 3.0.50: opt-in web search for 提问

/// One-shot "this request may go online" flag, written by the writing panel and
/// consumed while the gateway rewrites the request body.
///
/// Lives here (rather than in its own file) because AIGate's Xcode target lists
/// its sources explicitly — a brand-new file would compile locally but be absent
/// from the target until someone edits project.pbxproj by hand.
///
/// Why a file and not a header: the panel speaks to the gateway through a
/// trimmed OpenAI SDK whose `ChatQuery` has a fixed shape, so it has no way to
/// attach an extra field to the request. The gateway already touches every body
/// to swap the model id, which makes it the natural place to act on the flag.
///
/// Why an expiry: without one, a single 联网提问 would leave `:online` on every
/// later proofread / translate / rewrite in that panel — slower, and billed as
/// web requests.
enum FaircopyWebSearch {
    /// KEEP IN SYNC with `FaircopyWebSearchStore.path` in the WritingTools dylib.
    static let path = "/var/mobile/Library/Preferences/wiki.qaq.ai.gate/faircopy_web_search.json"

    /// Deliberately not cached: the panel writes the flag microseconds before it
    /// fires the request, so any cache would risk serving a stale `false` and
    /// silently dropping the user's choice. The file is tens of bytes.
    static let maxAge: TimeInterval = 60

    private struct Payload: Codable {
        let enabled: Bool
        let at: TimeInterval
    }

    static func isRequested() -> Bool {
        let now = Date().timeIntervalSince1970
        guard
            let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
            let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return false }
        guard payload.enabled else { return false }
        guard now - payload.at <= maxAge else {
            print("[AIGate] web search: flag expired, ignoring")
            return false
        }
        return true
    }

    /// Only OpenRouter documents a per-request "search the web for this one"
    /// switch. oneapi / newapi relays, self-hosted gateways and vLLM either
    /// ignore the extra field or reject the body outright, so they are left
    /// untouched — a 400 there would look like the panel broke. The wider prompt
    /// still applies for them, so the toggle is never a no-op.
    static func supportsLiveSearch(host: String) -> Bool {
        host.lowercased().contains("openrouter.ai")
    }

    /// OpenRouter's web plugin for this request, or nil to leave the body alone.
    ///
    /// Uses the `plugins` field rather than the `:online` model suffix: the
    /// suffix collides with other suffixes (`:free`, `:nitro`) — OpenRouter
    /// rejects `vendor/model:free:online` — while `plugins` composes with any
    /// model id and does not require guessing how the endpoint's model string is
    /// shaped.
    static func pluginPayload(host: String) -> [[String: String]]? {
        guard isRequested() else { return nil }
        guard supportsLiveSearch(host: host) else {
            print("[AIGate] web search: upstream \(host) has no live-search switch, prompt-only")
            FaircopyDiag.log("gate: prompt-only, host=\(host)")
            return nil
        }
        print("[AIGate] web search: injecting web plugin for \(host)")
        FaircopyDiag.log("gate: web plugin injected, host=\(host)")
        return [["id": "web"]]
    }
}

/// Append-only diagnostics shared with the panel.
///
/// KEEP IN SYNC with `FaircopyDiag` in the WritingTools dylib — same path, same
/// line format. The panel can only see the answer; the gateway is the only place
/// that knows which upstream served it and whether the web switch was actually
/// accepted, and a "no address" report cannot be diagnosed without both halves.
enum FaircopyDiag {
    static let path = "/var/mobile/Library/Preferences/wiki.qaq.ai.gate/faircopy_diag.log"

    private static let maxBytes = 131_072
    private static let keepBytes = 32_768

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    static func log(_ message: String) {
        NSLog("[AIGate] %@", message)
        // No extra prefix: the messages already start with "gate:", and the
        // panel greps for that marker.
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

    private static func trim(_ url: URL) {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              size > maxBytes,
              let data = try? Data(contentsOf: url)
        else { return }
        try? Data(data.suffix(keepBytes)).write(to: url)
    }
}
