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
import Darwin
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

    /// 3.0.103: the gateway thread logs too, and `log()` is a read-modify-write
    /// on one file. Two writers without a lock lose each other's lines, which is
    /// exactly the kind of damage that makes a log worthless when it matters.
    /// Not taken from the signal handler — that one writes raw.
    private static let logLock = NSLock()

    static func log(_ line: String) {
        logLock.lock()
        defer { logLock.unlock() }
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

        // 3.0.101: install the handlers first. The accurate pass faults the
        // process without raising anything Swift can catch and without writing
        // a byte to stderr (3.0.100 proved that: `.err` and `.out` stayed at 0
        // bytes across every restart), so the only way to learn *where* it dies
        // is to catch the signal inside the process and print the stack.
        installFaultHandlers()

        // 🔴 3.0.103: the gateway the panel actually dials.
        //
        // 3.0.102 finally got the picture read, and the panel then said it could
        // not establish a connection — because it was telling the truth. The
        // writing panel never talks to the model provider itself: `Configurator`
        // dials `http://127.0.0.1:5540`, and that listener was only ever started
        // by `FaircopyRootView.spawnService()` as a `BOOT_MODE=ServiceDaemon`
        // child of the running app. Once this worker took the app out of the
        // road, nobody was listening on 5540 at all.
        //
        // The credentials are not the problem: `GlobalStorage` keeps them as
        // plain files under `/var/mobile/Library/Preferences/wiki.qaq.ai.gate/`,
        // which is exactly why its own comment says "the launch daemon must read
        // credentials before first unlock after boot". So the gateway can be
        // served from here, with the same key, the same endpoint and the same
        // usage accounting as before.
        //
        // What is deliberately NOT started is `ServiceDaemon` itself: its loop
        // exits as soon as `BootMode` is not `.bootBoth`, and it builds a
        // `GateSessionDelegate` around a UIApplication this process does not
        // have. The listener alone is all the panel needs.
        //
        // Called below, once the jetsam allowance is already lifted.

        // 🔴 3.0.102: this is the whole bug.
        //
        // 3.0.101 proved that `.fast` survives and `.accurate` kills the process
        // without a single one of the installed signal handlers ever running —
        // and the fault handler always writes its header line before it walks
        // the stack, so "no header at all" can only mean the kernel killed the
        // process outright. SIGKILL is not catchable, and the one thing that
        // SIGKILLs a launchd job the moment it grows is jetsam.
        //
        // A foreground app gets a large allowance, which is why the very same
        // binary reads Chinese perfectly when the user opens AIGate. A launchd
        // daemon gets a small one, `.fast`'s little Latin model fits inside it,
        // and `.accurate`'s Chinese network does not — which is exactly the
        // boundary the log shows (and why the moment of death wandered between
        // zero and six seconds: it depends on how far the load got).
        //
        // The app already carries `com.apple.private.memorystatus` and
        // `com.apple.private.kernel.jetsam`; `Jetsam.m` has always had the call
        // that uses them, it simply was never made on this road. A task limit of
        // zero means "no limit".
        releaseJetsamLimit()

        // A worker that cannot warm up is restarted by launchd every five
        // seconds forever. That is a battery fire on a device the user is
        // holding, so a flapping worker backs off before it touches Vision.
        // 3.0.102 defeats the reason it flaps, so this is the seat belt, not
        // the brake.
        backOffIfFlapping()

        // Only now: the gateway allocates buffers and a thread, and none of that
        // may happen while the low default allowance still applies.
        startGateway()

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            fc_daemon_request_callback,
            FaircopyImageOCR.requestNotification as CFString,
            nil,
            .deliverImmediately
        )

        bootStamp = Date().timeIntervalSince1970
        log("daemon: observer installed, probing vision")
        // 3.0.99: synchronous on purpose. Asynchronously this text never
        // appeared: the worker exited within milliseconds of announcing itself,
        // and a background queue racing a dying process leaves no evidence at
        // all. Run it here and the log says exactly how far it got.
        warmUp()
        // `loop=timer keeper` is the marker the release check looks for: one
        // boot line per process. More than one in the log means launchd is
        // restarting the worker, i.e. it is exiting instead of waiting again.
        log(
            "daemon: resident ocr worker booted pid=\(getpid()) uid=\(getuid()) loop=timer keeper")

        // 🔴 3.0.101: the loop has to *wait*, and `run(mode:before:)` alone does
        // not make it wait.
        //
        // Foundation is explicit about it: "If no input sources or timers are
        // attached to the run loop, this method exits immediately." The heart
        // beat is a DispatchSource, which GCD services off the run loop
        // entirely, so it does not count. 3.0.100 never reached this line (the
        // accurate pass faulted first), which means the question "does the loop
        // hold" was never actually answered — so a real repeating timer is
        // attached here as a source before the loop is entered. Without it the
        // worker would spin a core at 100% and, worse, never receive the Darwin
        // notification it exists for.
        keeperTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in }

        while true {
            autoreleasepool {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(60))
            }
        }
        exit(EXIT_SUCCESS)
    }

    /// Strong reference so the run loop source above is never deallocated.
    private static var keeperTimer: Timer?

    // MARK: - Forensics

    /// 3.0.101: the worker dies inside `VNImageRequestHandler.perform` and leaves
    /// no message anywhere. Swift's `do/catch` cannot see a memory fault, and a
    /// memory fault writes nothing to stderr, so launchd's `StandardErrorPath`
    /// stays empty — which is exactly the evidence 3.0.100 produced (both files
    /// at 0 bytes, never touched). Catching the signal here and dumping the
    /// stack into our own log is the only way to see the crash site.
    private static func installFaultHandlers() {
        for sig in [SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT, SIGTRAP] {
            _ = signal(sig, fc_daemon_fault_handler)
        }
        // A closure here would have to reach `Self`, and a `@convention(c)`
        // pointer cannot be formed from anything that captures context — so the
        // body lives at file scope as a plain function.
        NSSetUncaughtExceptionHandler(fc_daemon_exception_handler)
    }

    private static let bootPath = FaircopyImageOCR.directory + "/faircopy_daemon_boot.json"

    /// Raises this task's jetsam allowance to "none" (3.0.102).
    ///
    /// `memorystatus_control` is already declared in `Extension/Jetsam/Jetsam.h`,
    /// which the bridging header pulls in, and `JetsamDisableControl()` in
    /// `Jetsam.m` is the same call — but it returns void, so the call is made
    /// directly and its return code checked.
    ///
    /// 3.0.105: silent on success. This used to log `rc=0 rss=17 MB` on every
    /// boot; the question it answered ("is the allowance really lifted?") was
    /// settled by one boot of 3.0.102, and the rss figures were only ever there
    /// to show how much the accurate network asks for. A refusal still has to be
    /// visible, because it is the only sign the private entitlement went away.
    private static func releaseJetsamLimit() {
        let code = memorystatus_control(
            UInt32(MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT), getpid(), 0, nil, 0)
        if code != 0 {
            log("daemon: jetsam limit refused rc=\(code)")
        }
    }

    /// Turns a five-second restart storm into a fifteen-second one.
    ///
    /// A worker that faults in warm up is relaunched by `KeepAlive` for as long
    /// as the package stays installed. Ten boots a minute, each loading a Vision
    /// model, is a lot of heat on a phone in someone's hand — so a boot that
    /// arrives suspiciously soon after the previous one waits first.
    private static func backOffIfFlapping() {
        let url = URL(fileURLWithPath: bootPath)
        let now = Date().timeIntervalSince1970
        if let data = try? Data(contentsOf: url),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let at = object["at"] as? Double,
           now - at < 15 {
            log("daemon: crash loop guard, last boot was \(Int(now - at)) s ago, waiting 15 s")
            sleep(15)
        }
        let payload: [String: Any] = ["at": Date().timeIntervalSince1970, "pid": Int(getpid())]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Gateway

    /// The listener the writing panel dials (3.0.103).
    ///
    /// `AIGateService` binds 127.0.0.1:5540 and proxies every panel request to
    /// the configured endpoint, swapping in the model id and the key and
    /// accounting the tokens. The app used to own that as a child process; this
    /// process owns it now, so a picture hand-off never needs the app at all.
    ///
    /// Rebinding is retried rather than treated as fatal: while AIGate is open
    /// its own child already holds the port and a second bind simply fails.
    /// Five seconds later the port is either still theirs — nothing to do — or
    /// free again, because the app was closed, and this loop takes over.
    private static func startGateway() {
        Thread {
            var lastNote = "listening"
            while true {
                do {
                    let service = try AIGateService()
                    lastNote = "listening"
                    log("daemon: gateway listening on 127.0.0.1:\(aiGateServicePort)")
                    try service.wait()
                    log("daemon: gateway channel closed, rebinding")
                } catch {
                    let note = error.localizedDescription
                    if note != lastNote {
                        lastNote = note
                        log("daemon: gateway bind failed, the app may own the port: \(note)")
                    }
                }
                sleep(5)
            }
        }.start()
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
        let started = Date()
        let side = 16
        // `CGColorSpaceCreateDeviceRGB()` is not optional in the Swift overlay,
        // so it cannot sit in a conditional binding.
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

        // Make this process look like the one place accurate Vision is known to
        // work — a normal app process. A launchd daemon starts in `/` with no
        // HOME and no TMPDIR; the app has both, and the model cache / Espresso
        // scratch space may care. The three lines that used to report the before
        // and after of this were 3.0.101 forensics: they are gone in 3.0.105,
        // the normalisation itself stays.
        _ = setenv("HOME", "/var/mobile", 1)
        _ = setenv("TMPDIR", "/tmp", 1)
        _ = chdir("/var/mobile")

        // ONE pass, accurate, zh-Hans. The `.fast` control pass that used to run
        // first existed only to prove the fault was level-specific rather than
        // process-wide (3.0.101); 3.0.102 answered that with jetsam, so since
        // 3.0.105 the boot no longer spends a Vision call on it.
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
        ready = true
        startHeartbeat()
        log(
            "daemon: vision ready in \(Int(Date().timeIntervalSince(started) * 1000)) ms, taking over")
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

// MARK: - Signal forensics

/// `backtrace(3)` lives in libsystem_c but the iOS SDK ships no <execinfo.h>,
/// so the symbol is declared by hand. It is the only libexecinfo symbol used:
/// `backtrace_symbols_fd` is not reliably exported on iOS, and
/// `backtrace_symbols` allocates, which is not safe inside a signal handler.
@_silgen_name("backtrace")
private func fc_backtrace(
    _ buffer: UnsafeMutablePointer<UnsafeMutableRawPointer?>?,
    _ size: Int32
) -> Int32

/// Runs on the crashing thread, so nothing here formats with `snprintf` —
/// Swift cannot call a C variadic function at all — and nothing builds a Swift
/// `String`. Every line is written from a `StaticString` plus a hand-rolled
/// decimal, which is the only shape that cannot allocate or take a lock while
/// the process is already dying.
///
/// Each frame is resolved with `dladdr`, so the log names the image and the
/// nearest symbol straight away: no offline symbolication, no dSYM, and no
/// guessing whether the fault is Vision, Espresso, Metal or libsystem.
private func fc_daemon_fault(_ sig: Int32) {
    let fd = open(FaircopyDaemon.logPath, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    if fd >= 0 {
        fc_write(fd, "\ndaemon: FAULT signal=")
        fc_writeDecimal(fd, UInt(bitPattern: Int(sig)))
        fc_write(fd, " pid=")
        fc_writeDecimal(fd, UInt(getpid()))
        fc_write(fd, "\n")

        var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 32)
        let count = fc_backtrace(&frames, 32)
        var index = 0
        while index < Int(count) {
            if let address = frames[index] {
                var info = Dl_info()
                if dladdr(UnsafeRawPointer(address), &info) != 0 {
                    fc_write(fd, "  #")
                    fc_writeDecimal(fd, UInt(index))
                    fc_write(fd, " @")
                    fc_writeDecimal(fd, UInt(bitPattern: address))
                    fc_write(fd, " ")
                    if let image = info.dli_fname {
                        fc_writeCString(fd, image)
                    } else {
                        fc_write(fd, "?")
                    }
                    fc_write(fd, " ")
                    if let symbol = info.dli_sname {
                        fc_writeCString(fd, symbol)
                    } else {
                        fc_write(fd, "?")
                    }
                    fc_write(fd, "\n")
                }
            }
            index += 1
        }
        fc_write(fd, "daemon: FAULT end frames=")
        fc_writeDecimal(fd, UInt(bitPattern: Int(count)))
        fc_write(fd, "\n")
        close(fd)
    }
    // Let the default action happen so the system still records the crash: this
    // handler only adds evidence, it does not swallow the fault.
    _ = signal(sig, SIG_DFL)
    _ = raise(sig)
}

/// Typed up front: `signal(3)` wants a `@convention(c)` pointer, and naming the
/// conversion explicitly makes it a compile-time constant rather than a closure
/// that could be allowed to capture.
private let fc_daemon_fault_handler: @convention(c) (Int32) -> Void = fc_daemon_fault

/// An uncaught Objective-C exception is not a signal and Swift cannot catch it,
/// so it gets its own reporter. Reaching `FaircopyDaemon.log` from a top-level
/// function is fine; doing it inside a closure is not, because the closure would
/// capture `Self` and could then not be passed as a C pointer.
private func fc_daemon_exception(_ exception: NSException) {
    FaircopyDaemon.log(
        "daemon: uncaught exception " + exception.name.rawValue + " reason=" + (exception.reason ?? "-")
    )
    FaircopyDaemon.log(
        "daemon: exception stack\n" + exception.callStackSymbols.joined(separator: "\n"))
}

private let fc_daemon_exception_handler: @convention(c) (NSException) -> Void = fc_daemon_exception

private func fc_write(_ fd: Int32, _ text: StaticString) {
    text.withUTF8Buffer { buffer in
        if let base = buffer.baseAddress {
            _ = write(fd, base, buffer.count)
        }
    }
}

private func fc_writeCString(_ fd: Int32, _ text: UnsafePointer<CChar>) {
    _ = write(fd, text, Int(strlen(text)))
}

/// Unsigned decimal without `snprintf`, which the Swift overlay marks
/// unavailable because it is a C variadic function.
private func fc_writeDecimal(_ fd: Int32, _ value: UInt) {
    var reversed = [CChar](repeating: 0, count: 24)
    var digits = [CChar](repeating: 0, count: 24)
    var remaining = value
    var count = 0
    repeat {
        reversed[count] = CChar(48 + Int(remaining % 10))
        count += 1
        remaining /= 10
    } while remaining > 0 && count < 24
    var out = 0
    while count > 0 {
        count -= 1
        digits[out] = reversed[count]
        out += 1
    }
    _ = write(fd, digits, out)
}
