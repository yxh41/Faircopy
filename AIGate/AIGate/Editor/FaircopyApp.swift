//
//  FaircopyApp.swift
//  AIGate
//
//  Created by 秋星桥 on 2024/8/15.
//

import AVFoundation
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
            FaircopyImageOCR.appendLog("boot url host=\(host) pid=\(ProcessInfo.processInfo.processIdentifier)")
        }
        // 3.0.83: silent picture hand-off. Whenever this process is alive at
        // all — even parked in the background — it can recognise a picture for
        // Kayoko without being brought to the front. Registered on every
        // launch, because iOS may resurrect the process in the background and
        // never show a window.
        FaircopyImageOCR.installBackgroundRequestObserver()
        // 3.0.86: an observer in a suspended process never runs. Hold the
        // process in the background from the moment it launches — including a
        // silent launch, which is exactly the case that has to stay resident.
        FaircopyBackgroundKeeper.shared.start()
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
            // 3.0.82: `src` is `com.apple.springboard` for this openURL even
            // though Kayoko is the one asking (3.0.80 log: `ocr: url received
            // src=com.apple.springboard`), so bouncing back to "whoever opened
            // me" landed the user on the home screen and the panel had to be
            // summoned there. Kayoko now names itself with `?caller=`; an
            // explicit caller wins over `src`, so the bounce returns to Kayoko
            // and the injector presents the panel in that process the moment it
            // activates — the Safari path, with no summon at all.
            let caller = Self.queryValue("caller", in: url)
            let named = FaircopyImageOCR.requestedDisplayTarget()
            // 3.0.85: two related but different answers.
            //   panelTarget — where the panel is drawn. Empty means "let the
            //     injector arbitrate", which is what the plain broadcast road
            //     has always done: the foreground app claims the ticket at once
            //     and SpringBoard defers 0.8 s, so no one has to name the
            //     frontmost app at all.
            //   landTarget  — where this app goes when it is done. That has to
            //     be a real bundle id, so an unnamed caller lands on `src`.
            let panelTarget: String
            if let caller,
               caller.caseInsensitiveCompare("wiki.qaq.AIGate") != .orderedSame,
               caller.caseInsensitiveCompare("com.apple.springboard") != .orderedSame
            {
                panelTarget = caller
            } else {
                panelTarget = named ?? ""
            }
            let landTarget = named ?? bounceTarget
            //
            // Vision's accurate text network cannot execute inside SpringBoard:
            // every `.accurate` request there fails with `Error computing NN
            // outputs` while `.fast` on the very same handler and picture
            // succeeds (Kayoko 4.3.15-4.3.21, proven pass by pass in
            // /var/mobile/Library/com.82flex.kayoko/ocr.log). A real app process
            // is where that network normally runs, so the recognition happens
            // here, invisibly: the settings UI never paints, the answer is
            // handed to the caller through the same pending-invocation file the
            // `panel` host uses, and the bounce lands back in the caller with a
            // `mode=segment` invocation waiting for it.
            FaircopyAppModel.shared.suppressSettingsUI = true
            panelBounceInFlight = true
            FaircopyImageOCR.appendLog("ocr: url received src=\(src ?? "nil")")
            // Deliberately two long literals joined instead of one interpolated
            // line: Swift inlines any literal of 15 bytes or less, which made
            // the ` caller=` fragment of the line above unsearchable in the
            // binary (the 3.0.82 proof failed on exactly that). These two are
            // past the threshold, so the caller decision stays provable.
            FaircopyImageOCR.appendLog(
                "ocr: caller from url = " + (caller ?? "none") + " bounce target = " + landTarget)
            // A cold launch builds its window after this method returns, so one
            // hide attempt is not enough: the window that appears a frame later
            // would still paint (black, since the settings UI is suppressed).
            // Repeat across the first 250 ms.
            for delay in [0.0, 0.02, 0.1, 0.25] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.setSceneWindowsHidden(true)
                }
            }
            FaircopyAppModel.shared.beginBackgroundTask()
            // 3.0.86: the silent road may have answered this very picture a
            // moment ago — the request was posted while this process was
            // suspended, so it only became a callback once the fallback launch
            // brought the app forward. Reading the same picture a second time
            // costs another second and races the panel that is already on its
            // way. The bounce is still owed, though: this launch is visible.
            if FaircopyImageOCR.finishedWithin(4.0) {
                FaircopyImageOCR.appendLog("ocr: url road stands down, silent road already answered")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    LSApplicationWorkspace.default().openApplication(withBundleID: landTarget)
                }
                if landTarget.lowercased() == "com.apple.springboard" {
                    FaircopyImageOCR.summonOnHomeScreen()
                }
                return
            }
            FaircopyImageOCR.recognize { outcome in
                let text = outcome.text
                FaircopyImageOCR.markFinished()
                var handedOff = false
                if !text.isEmpty {
                    handedOff = PanelPendingStore.save(PanelPending(
                        keyword: text,
                        target: panelTarget,
                        at: Date().timeIntervalSince1970,
                        mode: "segment"
                    ))
                }
                FaircopyImageOCR.writeResult(ok: handedOff, chars: text.count)
                // 3.0.87: last road to touch the picture — discard it whether
                // the hand-off worked or not (an unreadable picture has no use
                // either). The silent road keeps it only when it fails, so that
                // this launch can still read it.
                FaircopyImageOCR.discardHandoffFiles()
                // Tell Kayoko what happened; it owns the pill that is on screen
                // while this runs. Posted before the bounce so the pill is gone
                // by the time the panel arrives.
                fc_notify_post(FaircopyImageOCR.resultNotification)
                FaircopyAppModel.shared.beginBackgroundTask()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    LSApplicationWorkspace.default().openApplication(withBundleID: landTarget)
                }
                // SpringBoard never reports `didBecomeActive` when the user
                // lands back on the home screen — it stays Active for as long
                // as any app is frontmost — so the pending-invocation
                // activation fallback in the injector can never fire there and
                // the panel simply never appeared. The broadcast is the only
                // summon that works on the home screen; the injector answers it
                // only in the processes the invocation is addressed to (and
                // drops AIGate itself), so nothing else opens a panel.
                // Timed from AIGate's own backgrounding, not from here: see
                // FaircopyImageOCR.summonOnHomeScreen.
                // 3.0.82: only reachable when the caller was unknown and the
                // bounce fell back to the home screen. A named caller (Kayoko)
                // activates on landing and claims the invocation itself.
                if handedOff, landTarget.lowercased() == "com.apple.springboard" {
                    FaircopyImageOCR.summonOnHomeScreen()
                }
                // 3.0.82: a named caller is only useful if its process really
                // runs the injector. One log line a couple of seconds after the
                // bounce says whether anybody claimed the invocation — it
                // changes nothing that was handed off, it only makes the next
                // report readable (a silent caller shows up as `none` here).
                if handedOff, landTarget.lowercased() != "com.apple.springboard" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        FaircopyImageOCR.appendLog(
                            "ocr: claim after bounce = \(FaircopyImageOCR.panelClaimOwner())")
                    }
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

    /// First non-blank value of `name` in the URL's query, or nil.
    ///
    /// 3.0.82: `faircopy://ocr?caller=<bundle id>` — the caller names itself so
    /// the bounce does not have to trust `sourceApplication`, which reported
    /// `com.apple.springboard` for Kayoko (see `handleOpenURL`).
    static func queryValue(_ name: String, in url: URL) -> String? {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        for item in items where item.name == name {
            let value = (item.value ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return nil
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
    /// 3.0.83: posted by the caller to ask for a silent recognition. Answered
    /// from whatever state this process is in — no app switch, no window.
    static let requestNotification = "wiki.qaq.faircopy.ocr.request"

    /// 3.0.84: the app the panel belongs on, written by the caller.
    ///
    /// Kayoko's list is a SpringBoard window drawn over the app the user is
    /// looking at, so the panel must be presented by THAT app — otherwise it
    /// lands on SpringBoard's layer beneath that app's window and the user sees
    /// nothing until they return to the home screen. Only the workspace knows
    /// the answer, and AIGate is not the workspace, so it travels in a file.
    ///
    /// KEEP IN SYNC with kKayokoFaircopyOCRDisplayTargetPath.
    static let displayTargetPath = directory + "/faircopy_ocr_target.txt"

    /// One request at a time: a second picture posted while the first is still
    /// being read would overwrite the input file mid-recognition.
    private static var backgroundBusy = false

    /// 3.0.87: drop the hand-off files once they have done their job.
    ///
    /// The caller leaves a full-size screenshot here, and nothing ever removed
    /// it — it stayed on disk, readable by root and mobile, until the next
    /// swipe overwrote it. By the time a panel is handed off the words live in
    /// the invocation, so the picture has no further use. The one exception is
    /// the retry road: the visible launch still has to read the same file, so
    /// the silent road only discards on success and the visible road discards
    /// afterwards whichever way it went.
    static func discardHandoffFiles() {
        let manager = FileManager.default
        try? manager.removeItem(atPath: inputPath)
        try? manager.removeItem(atPath: displayTargetPath)
        appendLog("ocr: handoff files discarded")
    }

    /// When the last hand-off finished, whatever road took it (3.0.86).
    ///
    /// The two roads can overlap for one specific reason: a request posted
    /// while this process is suspended is delivered only once it is brought to
    /// the front, which is *during* the fallback launch. Both roads would then
    /// read the same picture and both would try to present a panel. The time
    /// stamp lets the URL road notice that the silent one already answered and
    /// limit itself to the bounce it still owes the user.
    private static var lastFinishedAt: Date?

    static func markFinished() {
        lastFinishedAt = Date()
    }

    static func finishedWithin(_ seconds: TimeInterval) -> Bool {
        guard let last = lastFinishedAt else { return false }
        return Date().timeIntervalSince(last) < seconds
    }

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

    /// 3.0.83: silent recognition, answered from a background process.
    ///
    /// The whole app switch existed for one reason — Vision's accurate network
    /// refuses to run inside SpringBoard — and this process is the one place it
    /// does run. Keeping it parked in the background and waking it with a
    /// Darwin notification therefore removes the switch entirely: the caller
    /// (a list hosted by SpringBoard) keeps the screen it had, and the panel is
    /// presented on top of it.
    ///
    /// Fails soft. An unreadable picture, or a handoff file that cannot be
    /// written, answers `retry` instead of silence; the caller then takes the
    /// visible `faircopy://ocr` road, i.e. exactly 3.0.82. A caller that gets
    /// no answer at all (this process was jetsammed) does the same.
    static func installBackgroundRequestObserver() {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            fc_ocr_request_callback,
            requestNotification as CFString,
            nil,
            .deliverImmediately
        )
        appendLog("boot: silent ocr observer installed")
    }

    /// The app the caller named for this picture, or nil when it named nothing
    /// usable — nil means "let the injector arbitrate" (see `handleBackgroundRequest`).
    static func requestedDisplayTarget() -> String? {
        let url = URL(fileURLWithPath: displayTargetPath)
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return isPlausibleBundleIdentifier(value) ? value : nil
    }

    /// A bundle id worth addressing a panel to: ASCII, dotted, sane length.
    ///
    /// 3.0.85: this is the guard that keeps a broken private API on the caller's
    /// side from costing anything here. Kayoko 4.3.25 asked SpringBoard for the
    /// frontmost app through `SBFrontmostApplicationDisplayIdentifier`, whose
    /// signature on 16.4 is not the one assumed — it handed back an invalid
    /// pointer and `copy` on it crashed SpringBoard (EXC_BAD_ACCESS at
    /// 0x10000003). Everything unstable is gone now, and anything that still
    /// slips through fails this check instead of becoming a panel target.
    static func isPlausibleBundleIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 200 else { return false }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        return value.rangeOfCharacter(from: allowed.inverted) == nil
    }

    static func handleBackgroundRequest() {
        DispatchQueue.main.async {
            guard !backgroundBusy else {
                appendLog("ocr: background request ignored (one already running)")
                return
            }
            backgroundBusy = true
            // 3.0.85: an empty target is not "nowhere" — the injector treats it
            // as a plain broadcast, and its arbitration ticket plus SpringBoard's
            // 0.8 s deferral let the app the user is looking at claim the panel
            // first. That is the same road `wiki.qaq.faircopy.present` has always
            // taken, so nothing has to name the frontmost app to be correct.
            let named = requestedDisplayTarget()
            let target = named ?? ""
            let task = UIApplication.shared.beginBackgroundTask(withName: "faircopy.ocr") {}
            appendLog("ocr: background request state=\(UIApplication.shared.applicationState.rawValue) target=\(named ?? "auto")")
            recognize { outcome in
                let text = outcome.text
                markFinished()
                var handedOff = false
                if !text.isEmpty {
                    handedOff = PanelPendingStore.save(PanelPending(
                        keyword: text,
                        target: target,
                        at: Date().timeIntervalSince1970,
                        mode: "segment"
                    ))
                }
                writeResult(ok: handedOff, chars: text.count, retry: !handedOff)
                // Tells Kayoko the pill can come down, whether or not a panel
                // follows — same contract as the visible road.
                fc_notify_post(resultNotification)
                if handedOff {
                    // 3.0.87: the words are in the invocation now; the picture
                    // does not need to outlive them.
                    discardHandoffFiles()
                    // SpringBoard is already in front (nothing was switched), so
                    // the injector presents in place: no summon timing, no
                    // window of this app in the way.
                    fc_notify_post("wiki.qaq.faircopy.present")
                    appendLog("ocr: background panel broadcast")
                } else {
                    appendLog("ocr: background request could not hand off")
                }
                UIApplication.shared.endBackgroundTask(task)
                backgroundBusy = false
            }
        }
    }

    /// Summons the panel at the one moment the home screen is really in front.
    ///
    /// Broadcasting straight after the bounce is not enough: AIGate is still
    /// frontmost for a few hundred milliseconds, and a panel presented then
    /// lands on SpringBoard's layer *behind* AIGate's window — while the claim
    /// is taken all the same, so the retry broadcast finds "already handled"
    /// and does nothing. The panel then sits there invisible until something
    /// forces SpringBoard to re-lay out its windows (switching pages did it).
    ///
    /// AIGate's own didEnterBackgroundNotification is the exact edge: at that
    /// instant the home screen is what the user is looking at. Two broadcasts
    /// follow it, because the transition takes a moment to settle; repeats are
    /// ignored once the invocation is claimed, so this can only produce the
    /// panel, never a second one.
    static func summonOnHomeScreen() {
        DispatchQueue.main.async {
            summonPending = true
            NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { _ in
                fireSummonBroadcasts()
            }
            // If the bounce never lands the app stays in front, and a panel
            // behind it is worth nothing: drop the pending summon so a much
            // later backgrounding cannot pop a stale panel either.
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
                summonPending = false
            }
        }
    }

    private static var summonPending = false

    private static func fireSummonBroadcasts() {
        guard summonPending else { return }
        summonPending = false
        appendLog("ocr: home screen is back in front")
        // The home-screen transition itself takes ~0.35 s; presenting during it
        // is the same losing race as presenting over AIGate, so the first
        // broadcast waits for it to finish.
        for delay in [0.6, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                appendLog("ocr: broadcast for SpringBoard")
                fc_notify_post("wiki.qaq.faircopy.present")
            }
        }
    }

    /// Written before the bounce so Kayoko can take its pill down (or say that
    /// the picture had no text) at the same moment the panel is summoned.
    ///
    /// 3.0.83: `retry` means "this process could not finish it silently" — the
    /// caller then runs the visible `faircopy://ocr` road instead of showing the
    /// user an error for a picture that is perfectly readable.
    static func writeResult(ok: Bool, chars: Int, retry: Bool = false) {
        var payload: [String: Any] = [
            "ok": ok,
            "chars": chars,
            "at": Date().timeIntervalSince1970,
        ]
        if retry { payload["retry"] = true }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: URL(fileURLWithPath: resultPath), options: .atomic)
    }

    // MARK: - Internals

    /// Who currently owns the panel ticket, for the post-bounce log line.
    ///
    /// Read-only. KEEP IN SYNC with `kFC_PanelClaimPath` in
    /// Library/WritingTools/Sources/WritingToolsInjector/WritingToolsInjector.m.
    /// `none` means nobody consumed the invocation: either the caller has no
    /// injector loaded, or it has not activated yet (see 3.0.82's caller bounce).
    static func panelClaimOwner() -> String {
        let path = directory + "/faircopy_panel_claim.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data),
              let claim = object as? [String: Any]
        else { return "none" }
        let bundle = claim["bundle"] as? String ?? "?"
        let pid = claim["pid"] as? Int ?? -1
        return "\(bundle)(pid \(pid))"
    }

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
    static func appendLog(_ line: String) {
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

/// Darwin callback for the silent OCR request (3.0.83).
///
/// A C function pointer cannot capture context, so it only hops to the main
/// queue — `FaircopyImageOCR` re-enters Swift there, with its own re-entrancy
/// guard. The notification itself carries no payload: the picture is already
/// waiting in the shared drop box, exactly like the URL road.
private func fc_ocr_request_callback(
    _: CFNotificationCenter?,
    _: UnsafeMutableRawPointer?,
    _: CFNotificationName?,
    _: UnsafeRawPointer?,
    _: CFDictionary?
) {
    DispatchQueue.main.async {
        FaircopyImageOCR.handleBackgroundRequest()
    }
}

/// Keeps this process alive in the background so the silent OCR hand-off can
/// actually answer (3.0.86).
///
/// Declaring `UIBackgroundModes: audio` grants nothing by itself: without an
/// active audio session iOS suspends the app seconds after it leaves the
/// screen, and a suspended process does not run Darwin callbacks. The
/// notification Kayoko posts was therefore never delivered — it sat queued in
/// notifyd until the fallback `faircopy://ocr` brought the app to the front,
/// at which point it fired *during* the launch (`state=1` in the log), the
/// picture was recognised twice and both bounce roads ran.
///
/// A looping silent track is the one background mode that is both cheap and
/// unconditional. The session mixes with whatever is already playing, so the
/// user's music is never interrupted, and the volume is low enough that the
/// track is inaudible in any case — the content itself is all zeroes.
final class FaircopyBackgroundKeeper {
    static let shared = FaircopyBackgroundKeeper()

    private var player: AVAudioPlayer?
    private var started = false

    /// Safe to call on every launch: the first call builds the player, later
    /// ones only make sure it is still playing (an interruption or a route
    /// change can stop it behind our back).
    func start() {
        if started {
            ensurePlaying()
            return
        }
        started = true

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            let player = try AVAudioPlayer(data: Self.silentTrack())
            player.numberOfLoops = -1
            player.volume = 0.02
            player.prepareToPlay()
            player.play()
            self.player = player
        } catch {
            FaircopyImageOCR.appendLog(
                "keepalive: audio session unavailable = \(error.localizedDescription)")
            return
        }

        let center = NotificationCenter.default
        center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main
        ) { note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended
            else { return }
            FaircopyBackgroundKeeper.shared.ensurePlaying()
        }
        center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { _ in
            FaircopyBackgroundKeeper.shared.ensurePlaying()
        }

        FaircopyImageOCR.appendLog("keepalive: audio session active, process will stay resident")
    }

    private func ensurePlaying() {
        guard let player else {
            started = false
            start()
            return
        }
        if !player.isPlaying {
            try? AVAudioSession.sharedInstance().setActive(true)
            player.play()
            FaircopyImageOCR.appendLog("keepalive: resumed after interruption")
        }
    }

    /// One second of 16-bit mono PCM at 8 kHz, all zeroes. Built in memory so
    /// nothing has to ship as a resource (and nothing can go missing from the
    /// bundle).
    private static func silentTrack() -> Data {
        let sampleRate: UInt32 = 8000
        let frames = Int(sampleRate) // one second
        let dataSize = UInt32(frames * 2)

        var bytes = Data()
        func put(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { bytes.append(contentsOf: $0) }
        }
        func putShort(_ value: UInt16) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { bytes.append(contentsOf: $0) }
        }

        bytes.append(contentsOf: Array("RIFF".utf8))
        put(36 + dataSize)
        bytes.append(contentsOf: Array("WAVE".utf8))
        bytes.append(contentsOf: Array("fmt ".utf8))
        put(16) // PCM header size
        putShort(1) // PCM
        putShort(1) // mono
        put(sampleRate)
        put(sampleRate * 2) // byte rate
        putShort(2) // block align
        putShort(16) // bits per sample
        bytes.append(contentsOf: Array("data".utf8))
        put(dataSize)
        bytes.append(Data(count: Int(dataSize)))
        return bytes
    }
}
