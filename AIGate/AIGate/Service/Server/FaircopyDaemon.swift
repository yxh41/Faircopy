//
//  FaircopyDaemon.swift
//  AIGate
//
//  The resident OCR worker (3.0.97).
//
//  Why this exists
//  ---------------
//  Vision's accurate text network cannot run inside SpringBoard: every
//  `.accurate` request there comes back `Error computing NN outputs` while
//  `.fast` on the same handler and the same picture succeeds, and `.fast` has no
//  Chinese model at all. So the words have to be read in a normal process.
//
//  Until now that process was the AIGate *app*, which meant every hand-off had
//  to launch it — a black flash, a switch away from what the user was reading,
//  and a bounce back. The app also only stays resident behind an audio session
//  trick (see `FaircopyBackgroundKeeper`), and a suspended process does not run
//  Darwin callbacks at all, so the first request after a boot always missed.
//
//  A LaunchDaemon has none of those problems: launchd starts it at boot, it is
//  never suspended, and it has no window to show. That is the same architecture
//  Snapper 3 uses for its own high-accuracy OCR on Dopamine (`snapper3ocrd`,
//  `RunAtLoad` + `KeepAlive` + a real on-disk program path) — the exact question
//  that started this: "它的确实能识别" — it recognises because it does not try to
//  do it in SpringBoard either.
//
//  What it answers
//  ---------------
//  Exactly the same contract the app's silent road has had since 3.0.83:
//
//    caller writes  faircopy_ocr_input.img / _target.txt / _mode.txt
//    caller posts   wiki.qaq.faircopy.ocr.request
//    this process   reads the picture, writes faircopy_ocr_result.json,
//                   writes faircopy_panel_pending.json, deletes the hand-off,
//                   posts wiki.qaq.faircopy.ocr.result then
//                   wiki.qaq.faircopy.present
//
//  The injector in the app the user is looking at claims the pending invocation
//  and presents the panel in place. No app switch anywhere on the path.

import CoreGraphics
import Foundation
import Vision

/// The iOS SDK ships no <notify/notify.h>; declare the one symbol needed.
@_silgen_name("notify_post")
private func fc_daemon_notify_post(_ name: UnsafePointer<CChar>?) -> UInt32

enum FaircopyDaemon {
    /// One picture at a time. A second request posted while the first is still
    /// being read would overwrite the input file mid-recognition.
    private static var busy = false

    /// Bumped on every heart beat so the app can tell a live worker from a dead
    /// one. Without it both processes would answer the same request and the
    /// user would get two panels (or a panel on top of another panel).
    private static var heartbeat: DispatchSourceTimer?

    static func main() -> Never {
        // Deliberately NOT starting `ServiceDaemon` here. That service is built
        // around a UIApplication living in the same process (`GateSessionDelegate`,
        // jetsam control, the network listener), and a crash in it would take the
        // OCR worker down with it — launchd would restart the pair, crash again,
        // and the user would get a recognition that never answers. The two have
        // nothing to do with each other: the app still runs the service its own
        // way when the user opens it, and the daemon only reads pictures.
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            fc_daemon_request_callback,
            FaircopyImageOCR.requestNotification as CFString,
            nil,
            .deliverImmediately
        )

        startHeartbeat()
        FaircopyImageOCR.appendLog(
            "daemon: resident ocr worker booted pid=\(getpid()) uid=\(getuid())")
        RunLoop.current.run()
        exit(EXIT_SUCCESS)
    }

    // MARK: - Heart beat

    /// Written every 5 s, treated as "the worker is alive" for 15 s by the app.
    ///
    /// The app keeps its own silent road as a fallback, and that road must stay
    /// quiet whenever this process is up: both would recognise the same picture
    /// and both would hand off a panel.
    static let heartbeatPath = FaircopyImageOCR.directory + "/faircopy_ocr_daemon.json"

    private static func startHeartbeat() {
        beat()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
        timer.setEventHandler { beat() }
        timer.resume()
        heartbeat = timer
    }

    private static func beat() {
        let payload: [String: Any] = [
            "pid": Int(getpid()),
            "at": Date().timeIntervalSince1970,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        let url = URL(fileURLWithPath: heartbeatPath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// True while a resident worker is answering requests. Read by the app so it
    /// steps aside instead of duplicating the work.
    ///
    /// KEEP IN SYNC with `FaircopyDaemon.heartbeatPath`.
    static func isAlive() -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: heartbeatPath)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let at = object["at"] as? Double
        else { return false }
        return Date().timeIntervalSince1970 - at < 15
    }

    // MARK: - Request handling

    /// Same hand-off contract as `FaircopyImageOCR.handleBackgroundRequest`,
    /// minus every piece of UIKit: there is no `beginBackgroundTask` to take
    /// out because launchd never suspends this process.
    static func handleRequest() {
        guard !busy else {
            FaircopyImageOCR.appendLog("daemon: request ignored (one already running)")
            return
        }
        busy = true
        beat()

        // An empty target means "let the injector arbitrate": its claim ticket
        // plus SpringBoard's 0.8 s deferral let the app the user is actually
        // looking at take the panel first. Nothing has to name that app to be
        // correct, the name only makes the first claim land on the right window.
        let named = FaircopyImageOCR.requestedDisplayTarget()
        let target = named ?? ""
        let mode = FaircopyImageOCR.requestedMode()
        FaircopyImageOCR.appendLog(
            "daemon: request target=\(named ?? "auto") mode=\(mode)")

        FaircopyImageOCR.recognize { outcome in
            let text = outcome.text
            var handedOff = false
            if !text.isEmpty {
                handedOff = PanelPendingStore.save(PanelPending(
                    keyword: text,
                    target: target,
                    at: Date().timeIntervalSince1970,
                    mode: mode
                ))
            }
            FaircopyImageOCR.writeResult(ok: handedOff, chars: text.count, retry: !handedOff)
            fc_daemon_notify_post(FaircopyImageOCR.resultNotification)

            if handedOff {
                FaircopyImageOCR.discardHandoffFiles()
                // Nothing was switched, so the app the user is looking at is
                // still in front: its injector presents the panel in place. The
                // broadcast is posted twice because the first one can arrive
                // before the capture window has finished tearing down; repeats
                // find the invocation claimed and are ignored.
                fc_daemon_notify_post("wiki.qaq.faircopy.present")
                FaircopyImageOCR.appendLog("daemon: panel broadcast, \(text.count) chars")
            } else {
                // Nothing to hand off. `retry` in the result file tells the
                // caller to fall back to the visible road, which still works.
                FaircopyImageOCR.appendLog("daemon: nothing to hand off")
            }
            busy = false
        }
    }
}

/// A C function pointer cannot capture context, so it only hops to the main
/// queue — `FaircopyDaemon` re-enters Swift there, behind its own guard.
private func fc_daemon_request_callback(
    _: CFNotificationCenter?,
    _: UnsafeMutableRawPointer?,
    _: CFNotificationName?,
    _: UnsafeRawPointer?,
    _: CFDictionary?
) {
    DispatchQueue.main.async {
        FaircopyDaemon.handleRequest()
    }
}
