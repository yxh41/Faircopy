//
//  FaircopyApp.swift
//  AIGate
//
//  Created by 秋星桥 on 2024/8/15.
//

import SwiftUI
import Vision

/// The iOS SDK ships no <notify/notify.h>, so declare the symbol we need the
/// same way TaskProcess+ObjC.swift declares its private POSIX entry points.
@_silgen_name("notify_post")
private func fc_notify_post(_ name: UnsafePointer<CChar>?) -> UInt32

/// Hosts that must never paint the settings UI: both are invisible hand-offs
/// that bounce straight back to the caller.
private let kFCInvisibleHosts: Set<String> = ["panel", "ocr"]

struct FaircopyApp: App {
    @StateObject var vm = FaircopyAppModel.shared

    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            Group {
                if vm.suppressSettingsUI {
                    panelEntryPlaceholder
                } else {
                    NavigationView {
                        FaircopyRootView()
                    }
                    .navigationViewStyle(.stack)
                }
            }
        }
    }

    /// Placeholder shown instead of the settings UI while a `faircopy://panel`
    /// invocation is in flight: fully transparent, so the user sees their
    /// launcher / home screen instead of an AIGate flash. The accessibility
    /// identifier doubles as a build-time proof that this code shipped.
    private var panelEntryPlaceholder: some View {
        Color.clear
            .ignoresSafeArea()
            .accessibilityIdentifier("faircopy.panel.suppressed")
    }
}

final class FaircopyAppModel: ObservableObject {
    static let shared = FaircopyAppModel()
    let tweakURL = Bundle.main.url(forResource: "Faircopy", withExtension: "dylib")

    private let jailbreakSchemes: [String] = ["cydia", "sileo", "zbra"]

    private init() {
        #if targetEnvironment(simulator) || targetEnvironment(macCatalyst)
            isLiteEdition = ProcessInfo.processInfo.environment["isLiteEdition"] != nil
            isJailbroken = ProcessInfo.processInfo.environment["isJailbroken"] != nil
        #else
            isLiteEdition = (BootMode.current == .settingApp
                && Bundle.main.bundleIdentifier == "wiki.qaq.AIGate"
                && Bundle.main.infoDictionary?["SBAppTags"] == nil)
            isJailbroken = jailbreakSchemes.contains { scheme in
                UIApplication.shared.canOpenURL(URL(string: "\(scheme)://")!)
            }
        #endif
    }

    @Published var isLiteEdition = false
    @Published var isJailbroken = false

    /// True while AIGate must not paint its settings UI — currently only
    /// during a `faircopy://panel` invocation that is bouncing back to the
    /// caller. Sticky across foregrounds: it is cleared only when the user
    /// opens AIGate normally (see `SceneDelegate.scheduleSettingsUIRestore`).
    @Published var suppressSettingsUI = false

    private var backgroundTaskIdentifier: UIBackgroundTaskIdentifier = .invalid

    func beginBackgroundTask() {
        guard backgroundTaskIdentifier == .invalid else {
            return
        }
        backgroundTaskIdentifier = UIApplication.shared.beginBackgroundTask { [weak self] in
            self?.endBackgroundTask()
        }
    }

    func endBackgroundTask() {
        guard backgroundTaskIdentifier != .invalid else {
            return
        }
        UIApplication.shared.endBackgroundTask(backgroundTaskIdentifier)
        backgroundTaskIdentifier = .invalid
    }
}

extension FaircopyRootView {
    func spawnService() {
        guard appViewModel.isLiteEdition else {
            return
        }
        if case .connected = serviceStatus {
            return
        }
        #if targetEnvironment(simulator) || targetEnvironment(macCatalyst)
            return
        #else
            let task = TaskProcess()
            task.executableURL = Bundle.main.executableURL
            task.environment = [
                "BOOT_MODE": BootMode.serviceDaemon.rawValue,
            ]
            task.userIdentifier = 501
            task.groupIdentifier = 501
            try? task.run()
        #endif
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Earliest possible point: a cold `faircopy://panel` (or
        // `faircopy://ocr`) launch must never paint the settings UI, not even
        // for a single frame.
        if let url = launchOptions?[.url] as? URL, let host = url.host,
           kFCInvisibleHosts.contains(host)
        {
            FaircopyAppModel.shared.suppressSettingsUI = true
        }
        return true
    }

    func application(_: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options _: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let sceneConfig = UISceneConfiguration(
            name: nil,
            sessionRole: connectingSceneSession.role
        )
        sceneConfig.delegateClass = SceneDelegate.self
        return sceneConfig
    }
}

final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?

    private weak var windowScene: UIWindowScene?

    /// True while a `faircopy://panel` bounce back to the caller is in
    /// flight. The settings UI stays suppressed until it lands.
    private var panelBounceInFlight = false

    /// Deferred "restore the settings UI" work, scheduled when the scene
    /// becomes active without a URL. Cancelled if a URL activation (e.g. a
    /// warm `faircopy://panel`) arrives instead of a plain user open.
    private var restoreWorkItem: DispatchWorkItem?

    func scene(_ scene: UIScene, willConnectTo _: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions)
    {
        guard let windowScene = scene as? UIWindowScene else { return }
        self.windowScene = windowScene
        if let url = connectionOptions.urlContexts.first?.url {
            handleOpenURL(url, sourceApplication: connectionOptions.urlContexts.first?.options.sourceApplication)
        }
    }

    func sceneWillEnterForeground(_: UIScene) {
        // Hide the scene's windows up front: a warm `faircopy://panel`
        // activation must never paint the previous UI (settings), not even
        // for one frame. A normal user open unhides again in
        // sceneDidBecomeActive.
        setSceneWindowsHidden(true)
    }

    func sceneDidBecomeActive(_: UIScene) {
        FaircopyAppModel.shared.endBackgroundTask()
        if panelBounceInFlight {
            // A panel bounce is still in flight: keep every window hidden.
            // This also covers the cold-launch race where SwiftUI builds its
            // window after `scene(_:willConnectTo:options:)` returns.
            setSceneWindowsHidden(true)
        }
        scheduleSettingsUIRestore()
    }

    func sceneDidEnterBackground(_: UIScene) {
        // The bounce has landed (or AIGate was backgrounded for another
        // reason): clear the in-flight flag and leave a sane window state
        // while backgrounded; the next foreground decides again.
        panelBounceInFlight = false
        setSceneWindowsHidden(false)
    }

    func scene(_: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        // A URL activation is never a plain user open: keep the settings UI
        // suppressed while it is handled.
        restoreWorkItem?.cancel()
        restoreWorkItem = nil
        guard let url = URLContexts.first?.url else { return }
        handleOpenURL(url, sourceApplication: URLContexts.first?.options.sourceApplication)
    }

    /// Restore the settings UI shortly after the scene becomes active, unless
    /// a URL activation (warm `faircopy://panel`) arrives first. The delay
    /// covers the gap between `sceneDidBecomeActive` and the delivery of
    /// `scene(_:openURLContexts:)`.
    private func scheduleSettingsUIRestore() {
        restoreWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, !self.panelBounceInFlight else { return }
            FaircopyAppModel.shared.suppressSettingsUI = false
            self.setSceneWindowsHidden(false)
        }
        restoreWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func setSceneWindowsHidden(_ hidden: Bool) {
        windowScene?.windows.forEach { $0.isHidden = hidden }
    }

    private func handleOpenURL(_ url: URL, sourceApplication src: String?) {
        // iOS 16 often reports a nil source application (Shortcuts, third-party
        // launchers). Never strand the user on the AIGate settings UI: fall
        // back to the home screen when the caller is unknown.
        let bounceTarget = (src?.isEmpty == false) ? src! : "com.apple.SpringBoard"

        if url.host == "spawn" {
            FaircopyAppModel.shared.beginBackgroundTask()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                LSApplicationWorkspace.default().openApplication(withBundleID: bounceTarget)
            }
        }
        if url.host == "ocr" {
            // Picture hand-off (Kayoko's image swipe action).
            //
            // Vision's accurate text network cannot execute inside SpringBoard:
            // every `.accurate` request there fails with `Error computing NN
            // outputs` while `.fast` on the very same handler and picture
            // succeeds (Kayoko 4.3.15-4.3.21, proven pass by pass in
            // /var/mobile/Library/com.82flex.kayoko/ocr.log). A real app process
            // is where that network normally runs, so the recognition happens
            // here, invisibly: the settings UI never paints, the answer is
            // handed to the caller through the same pending-invocation file the
            // `panel` host uses, and the bounce lands on the home screen with a
            // `mode=segment` invocation waiting for it.
            FaircopyAppModel.shared.suppressSettingsUI = true
            panelBounceInFlight = true
            setSceneWindowsHidden(true)
            DispatchQueue.main.async { [weak self] in
                self?.setSceneWindowsHidden(true)
            }
            FaircopyAppModel.shared.beginBackgroundTask()
            FaircopyImageOCR.recognize { outcome in
                let text = outcome.text
                var handedOff = false
                if !text.isEmpty {
                    handedOff = PanelPendingStore.save(PanelPending(
                        keyword: text,
                        target: bounceTarget,
                        at: Date().timeIntervalSince1970,
                        mode: "segment"
                    ))
                }
                FaircopyImageOCR.writeResult(ok: handedOff, chars: text.count)
                // Tell Kayoko what happened; it owns the pill that is on screen
                // while this runs. Posted before the bounce so the pill is gone
                // by the time the panel arrives.
                fc_notify_post(FaircopyImageOCR.resultNotification)
                FaircopyAppModel.shared.beginBackgroundTask()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    LSApplicationWorkspace.default().openApplication(withBundleID: bounceTarget)
                }
                // Never strand the user on a blank, windowless AIGate if the
                // bounce itself fails. Captured strongly on purpose: the scene
                // delegate outlives this block, and a weak capture would need a
                // second weak capture inside it (the outer block is already
                // capture-list free).
                let delegate = self
                DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
                    guard delegate.panelBounceInFlight else { return }
                    delegate.panelBounceInFlight = false
                    if UIApplication.shared.applicationState == .active {
                        FaircopyAppModel.shared.suppressSettingsUI = false
                        delegate.setSceneWindowsHidden(false)
                    }
                }
            }
        }
        if url.host == "panel" {
            // External panel entry: suppress the settings UI so the user never
            // sees an AIGate flash — both at the content level (transparent
            // SwiftUI placeholder) and, as a backstop for first-frame timing,
            // by hiding every window of the scene. Then bounce back to the
            // caller and post the Darwin notification the tweak listens for.
            // See kFCExternalPresentNotification in WritingToolsInjector.h.
            FaircopyAppModel.shared.suppressSettingsUI = true
            panelBounceInFlight = true
            setSceneWindowsHidden(true)
            // 3.0.33: the bounce plus the shared pending-invocation file now
            // carry the invocation end to end — the Darwin broadcast is GONE
            // from this path. It was a payload-less broadcast that every
            // injected app answered; whenever the bounce target was not the
            // foreground app at broadcast time (cold relaunch above all),
            // SpringBoard answered it and the target answered again on
            // landing — two panels. Only a failed handoff still broadcasts.
            let keyword = Self.panelKeyword(from: url)
            let handedOff = PanelPendingStore.save(PanelPending(
                keyword: keyword,
                target: bounceTarget,
                at: Date().timeIntervalSince1970
            ))
            // On a cold launch SwiftUI's window may not exist yet at this
            // point; hide whatever appears before the first composite.
            DispatchQueue.main.async { [weak self] in
                self?.setSceneWindowsHidden(true)
            }
            FaircopyAppModel.shared.beginBackgroundTask()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                LSApplicationWorkspace.default().openApplication(withBundleID: bounceTarget)
            }
            if !handedOff {
                // The handoff file could not be written (disk / sandbox): fall
                // back to the payload-less broadcast so a panel still appears.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    // Keep in sync with kFCExternalPresentNotification in
                    // Library/WritingTools/Sources/WritingToolsInjector.h
                    fc_notify_post("wiki.qaq.faircopy.present")
                }
            }
            // Safety net: if the bounce failed and AIGate is still the active
            // app, restore the settings UI instead of stranding the user on a
            // blank screen. (No broadcast here: with a successful handoff the
            // bounce target owns the invocation, and a failed bounce leaves
            // nobody to summon.)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self = self, self.panelBounceInFlight else { return }
                self.panelBounceInFlight = false
                if UIApplication.shared.applicationState == .active {
                    FaircopyAppModel.shared.suppressSettingsUI = false
                    self.setSceneWindowsHidden(false)
                }
            }
        }
    }

    /// Extracts the percent-decoded `keyword` query item from a
    /// `faircopy://panel?keyword=…` URL. Empty when absent or blank — the
    /// injector then falls back to the context-driven (no keyword) path.
    static func panelKeyword(from url: URL) -> String {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return "" }
        for item in items where item.name == "keyword" {
            let value = (item.value ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return ""
    }
}

/// One pending `faircopy://panel` invocation, handed from AIGate to the
/// injected apps through a shared file. The Darwin notification cannot carry
/// a payload across processes, so the keyword and the bounce target travel
/// here instead (same shared directory the app-search stores use).
struct PanelPending: Codable {
    var keyword: String
    var target: String
    var at: Double
    /// 3.0.79: `"segment"` makes the injector open the panel already tokenized.
    /// Absent (nil) keeps the original "just show the text" behaviour, so an
    /// older Faircopy reading a newer file still presents something.
    var mode: String?
}

struct PanelPendingStore {
    /// KEEP IN SYNC with kFCPendingPanelPath in WritingToolsInjector.m.
    static let path = "/var/mobile/Library/Preferences/wiki.qaq.ai.gate/faircopy_panel_pending.json"

    /// Writes the invocation atomically. Returns false when the write failed —
    /// the caller then falls back to the payload-less Darwin broadcast.
    @discardableResult
    static func save(_ pending: PanelPending) -> Bool {
        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(pending)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            print("[Faircopy] panel handoff file write failed: \(error.localizedDescription)")
            return false
        }
    }
}

/// Recognises the text in a picture handed over by Kayoko.
///
/// Runs in AIGate's own process on purpose. Vision's accurate text network
/// cannot execute in SpringBoard — every `.accurate` request there returns
/// `Error computing NN outputs` while `.fast` on the same handler and the same
/// picture succeeds (Kayoko 4.3.15-4.3.21); a normal app process is where that
/// network runs, Live Text included. `faircopy://ocr` is the invisible entry
/// point: the picture is left in the shared preferences directory, the answer
/// comes back as a `mode=segment` pending invocation.
enum FaircopyImageOCR {
    /// KEEP IN SYNC with the kKayokoFaircopy… constants in
    /// Kayoko/src/Tweak/Core/Controllers/KayokoHistoryListViewController.m.
    static let directory = "/var/mobile/Library/Preferences/wiki.qaq.ai.gate"
    static let inputPath = directory + "/faircopy_ocr_input.img"
    static let resultPath = directory + "/faircopy_ocr_result.json"
    static let logPath = directory + "/faircopy_ocr.log"
    static let resultNotification = "wiki.qaq.faircopy.ocr.result"

    struct Outcome {
        let text: String
    }

    private struct Attempt {
        let languages: [String]
        let correction: Bool
        let accurate: Bool
        var revision = 0
    }

    /// Accurate first, then progressively less ambitious. `fast` is the last
    /// rung only so that a Latin-only picture still yields something if the
    /// accurate network ever refuses to run here either — it has no Chinese
    /// model at all, which is exactly why 4.3.15-4.3.18 produced Latin soup.
    private static var attempts: [Attempt] {
        [
            Attempt(languages: ["zh-Hans"], correction: true, accurate: true),
            Attempt(languages: ["zh-Hans"], correction: false, accurate: true),
            Attempt(languages: ["zh-Hans", "en-US"], correction: true, accurate: true),
            Attempt(languages: ["zh-Hans"], correction: true, accurate: true, revision: 2),
            Attempt(languages: ["en-US"], correction: true, accurate: true),
            Attempt(languages: ["en-US"], correction: true, accurate: false),
        ]
    }

    static func recognize(completion: @escaping (Outcome) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let started = Date()
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: inputPath)),
                  let image = UIImage(data: data),
                  let cgImage = image.cgImage
            else {
                appendLog("input unreadable: \(inputPath)")
                DispatchQueue.main.async { completion(Outcome(text: "")) }
                return
            }
            appendLog("input \(cgImage.width)x\(cgImage.height) orientation=\(image.imageOrientation.rawValue) bytes=\(data.count)")
            let orientation = cgImageOrientation(of: image)
            var best = ""
            var bestLabel = "nothing"
            for (index, attempt) in attempts.enumerated() {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = attempt.accurate ? .accurate : .fast
                request.recognitionLanguages = attempt.languages
                request.usesLanguageCorrection = attempt.correction
                if attempt.revision > 0 {
                    request.revision = attempt.revision
                }
                let label = "\(attempt.languages.joined(separator: "+"))/\(attempt.accurate ? "acc" : "fast")"
                let handler = VNImageRequestHandler(cgImage: cgImage,
                                                    orientation: orientation,
                                                    options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    appendLog(passLine(index, label, appliedRevision: request.revision,
                                       outcome: "req=FAIL err=\(describe(error))", since: started))
                    continue
                }
                // `VNRequest.results` is `[VNObservation]?`; the request type
                // refines it at runtime, not in the overlay.
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let text = assemble(observations)
                let average = quality(observations)
                appendLog(passLine(index, label, appliedRevision: request.revision,
                                   outcome: "req=OK obs=\(observations.count) text=\(text.count) q=\(String(format: "%.2f", average))",
                                   since: started))
                if !text.isEmpty {
                    best = text
                    bestLabel = label
                    break
                }
            }
            appendLog("result chars=\(best.count) ms=\(Int(Date().timeIntervalSince(started) * 1000)) from \(bestLabel)")
            DispatchQueue.main.async { completion(Outcome(text: best)) }
        }
    }

    /// Written before the bounce so Kayoko can take its pill down (or say that
    /// the picture had no text) at the same moment the panel is summoned.
    static func writeResult(ok: Bool, chars: Int) {
        let payload: [String: Any] = [
            "ok": ok,
            "chars": chars,
            "at": Date().timeIntervalSince1970,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: URL(fileURLWithPath: resultPath), options: .atomic)
    }

    // MARK: - Internals

    /// Vision's origin is bottom-left, so `maxY` descending is top-to-bottom.
    /// Observations that share a baseline (within 1% of the image height) are
    /// ordered left-to-right, which is what keeps a chat screenshot's timestamp
    /// and message on the same line instead of swapping them.
    private static func assemble(_ observations: [VNRecognizedTextObservation]) -> String {
        let lines: [(String, CGRect)] = observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            guard candidate.confidence >= 0.2 else { return nil }
            return (candidate.string, observation.boundingBox)
        }
        let ordered = lines.sorted { lhs, rhs in
            if abs(lhs.1.maxY - rhs.1.maxY) > 0.01 {
                return lhs.1.maxY > rhs.1.maxY
            }
            return lhs.1.minX < rhs.1.minX
        }
        // Tuple key paths (`\.0`) do not exist in Swift; index the element.
        return ordered.map { $0.0 }.joined(separator: "\n")
    }

    private static func quality(_ observations: [VNRecognizedTextObservation]) -> Double {
        let confidences = observations.compactMap { $0.topCandidates(1).first?.confidence }
        guard !confidences.isEmpty else { return 0 }
        return Double(confidences.reduce(0, +)) / Double(confidences.count)
    }

    private static func cgImageOrientation(of image: UIImage) -> CGImagePropertyOrientation {
        switch image.imageOrientation {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }

    private static func passLine(_ index: Int, _ label: String, appliedRevision: Int,
                                 outcome: String, since: Date) -> String {
        let ms = Int(Date().timeIntervalSince(since) * 1000)
        return "p\(index + 1) \(label) rev\(appliedRevision) \(outcome) t=\(ms)ms"
    }

    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        var text = "\(ns.domain)#\(ns.code) \(ns.localizedDescription)"
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += " <- \(underlying.domain)#\(underlying.code) \(underlying.localizedDescription)"
        }
        return text.replacingOccurrences(of: "\"", with: "'")
    }

    /// Append and self-trim: the log is a diagnostic, not a record, and this
    /// directory is also where the app-search stores live.
    private static func appendLog(_ line: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let entry = "\(formatter.string(from: Date())) \(line)\n"
        let url = URL(fileURLWithPath: logPath)
        var existing = (try? Data(contentsOf: url)) ?? Data()
        if existing.count > 8 * 1024 {
            existing = Data()
        }
        existing.append(Data(entry.utf8))
        try? existing.write(to: url, options: .atomic)
    }
}
