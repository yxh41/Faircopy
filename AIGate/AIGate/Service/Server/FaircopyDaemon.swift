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

    /// The worker keeps its own log (3.0.99).
    ///
    /// `FaircopyImageOCR.appendLog` does a read-modify-write on `faircopy_ocr.log`,
    /// which the app writes too; two processes doing that lose each other's
    /// lines. More to the point, 3.0.98's worker never reached that call at all,
    /// so whether this file exists is the cheapest possible answer to "did the
    /// daemon run a single line of our code" — the question that cost a release.
    static let logPath = FaircopyImageOCR.directory + "/faircopy_daemon.log"

    static func log(_ line: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let entry = "\(formatter.string(from: Date())) [\(getpid())] \(line)\n"
        let url = URL(fileURLWithPath: logPath)
        var existing = (try? Data(contentsOf: url)) ?? Data()
        if existing.count > 16 * 1024 { existing = Data() }
        existing.append(Data(entry.utf8))
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? existing.write(to: url, options: .atomic)
    }

    static func main() -> Never {
        // Before anything else can decide this process has nothing to do.
        let extra = CommandLine.arguments.dropFirst().joined(separator: " ")
        log("boot: worker entered args=\(extra)")

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

        bootStamp = Date().timeIntervalSince1970
        // No heart beat yet. `warmUp` writes the first one, and only if Vision
        // really runs in this process.
        warmUp()
        // `loop=timer keeper` is the marker the release check looks for: one
        // boot line per process. More than one in the log means launchd is
        // restarting the worker, i.e. it is exiting instead of waiting again.
        log(
            "daemon: resident ocr worker booted pid=\(getpid()) uid=\(getuid()) loop=timer keeper")

        // 🔴 3.0.98: this has to be a loop that actually waits.
        //
        // `RunLoop.current.run()` returns *immediately* when the loop owns no
        // timer and no source — and the heart beat above is a DispatchSource,
        // which GCD services off the run loop entirely. So 3.0.97 booted, wrote
        // one heart beat, fell straight through to `exit(EXIT_SUCCESS)`, and
        // launchd's KeepAlive started it again five seconds later. The file was
        // always fresh, the log said the worker was up, and every single
        // `faircopy.ocr.request` was posted to a process that had already left:
        // a Darwin notification is not queued for anyone who is not listening.
        //
        // A repeating run-loop timer is what gives the loop something to wait
        // for; the notification port is then serviced on the same loop.
        let keeper = Timer(timeInterval: 3600, repeats: true) { _ in beat() }
        RunLoop.current.add(keeper, forMode: .common)
        CFRunLoopRun()
        exit(EXIT_SUCCESS)
    }

    // MARK: - Warm up

    /// True once Vision has actually run in this process (3.0.98).
    ///
    /// The worker only announces itself after that. The reason SpringBoard could
    /// never do this job is that the accurate network refused to run there, and
    /// nothing says a daemon is exempt: if it refuses here too, the heart beat is
    /// simply never written. Then the app's own silent road keeps handling
    /// requests exactly as it did before this release, the plugin's fallback goes
    /// back to 2 s, and the user gets the old behaviour instead of eight seconds
    /// of nothing followed by the same old launch.
    ///
    /// It doubles as the first-request speed fix: loading the Chinese model takes
    /// seconds, and doing it here means the first real picture does not pay for
    /// it. The log line says which of the two happened, so nobody has to guess.
    private static var ready = false

    private static func warmUp() {
        DispatchQueue.global(qos: .utility).async {
            let started = Date()
            let side = 16
            // `CGColorSpaceCreateDeviceRGB()` is not optional in the Swift
            // overlay, so it cannot sit in a conditional binding.
            let space = CGColorSpaceCreateDeviceRGB()
            guard let context = CGContext(data: nil, width: side, height: side,
                                          bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let page = context.makeImage()
            else {
                log("daemon: warm up could not draw a blank page")
                return
            }

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans"]
            request.usesLanguageCorrection = true
            do {
                try VNImageRequestHandler(cgImage: page, options: [:]).perform([request])
            } catch {
                log(
                    "daemon: vision refused to run here, staying out of the way: "
                        + error.localizedDescription)
                return
            }

            DispatchQueue.main.async {
                ready = true
                startHeartbeat()
                log(
                    "daemon: vision ready in \(Int(Date().timeIntervalSince(started) * 1000)) ms, taking over")
            }
        }
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

    /// When this process started. Written into the heart beat so a restart loop
    /// is visible from the outside: a live worker keeps one `since`, a worker
    /// that launchd keeps restarting shows a new one every time.
    private static var bootStamp: Double = 0

    private static func beat() {
        let payload: [String: Any] = [
            "pid": Int(getpid()),
            "at": Date().timeIntervalSince1970,
            "since": bootStamp,
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
        // A worker that never warmed up must not touch the drop box: the heart
        // beat it never wrote means the app is answering this request, and
        // recognising it here as well would hand off a second panel.
        guard ready else {
            log(
                "daemon: request left to the app, vision is not available here")
            return
        }
        guard !busy else {
            log("daemon: request ignored (one already running)")
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
        log(
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
                log("daemon: panel broadcast, \(text.count) chars")
            } else {
                // Nothing to hand off. `retry` in the result file tells the
                // caller to fall back to the visible road, which still works.
                log("daemon: nothing to hand off")
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
