//
//  FaircopyApp.swift
//  AIGate
//
//  Created by 秋星桥 on 2024/8/15.
//

import SwiftUI

/// The iOS SDK ships no <notify/notify.h>, so declare the symbol we need the
/// same way TaskProcess+ObjC.swift declares its private POSIX entry points.
@_silgen_name("notify_post")
private func fc_notify_post(_ name: UnsafePointer<CChar>?) -> UInt32

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
        // Earliest possible point: a cold `faircopy://panel` launch must never
        // paint the settings UI, not even for a single frame.
        if let url = launchOptions?[.url] as? URL, url.host == "panel" {
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
        guard let _ = scene as? UIWindowScene else { return }
        if let url = connectionOptions.urlContexts.first?.url {
            handleOpenURL(url, sourceApplication: connectionOptions.urlContexts.first?.options.sourceApplication)
        }
    }

    func sceneDidBecomeActive(_: UIScene) {
        FaircopyAppModel.shared.endBackgroundTask()
        scheduleSettingsUIRestore()
    }

    func sceneDidEnterBackground(_: UIScene) {
        // The bounce has landed (or AIGate was backgrounded for another
        // reason): clear the in-flight flag so a later foreground can restore
        // the settings UI.
        panelBounceInFlight = false
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
        }
        restoreWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
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
        if url.host == "panel" {
            // External panel entry: suppress the settings UI first so the user
            // never sees an AIGate flash, bounce back to the caller, then post
            // the Darwin notification the tweak listens for. See
            // kFCExternalPresentNotification in WritingToolsInjector.h.
            FaircopyAppModel.shared.suppressSettingsUI = true
            panelBounceInFlight = true
            FaircopyAppModel.shared.beginBackgroundTask()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                LSApplicationWorkspace.default().openApplication(withBundleID: bounceTarget)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                // Keep in sync with kFCExternalPresentNotification in
                // Library/WritingTools/Sources/WritingToolsInjector.h
                fc_notify_post("wiki.qaq.faircopy.present")
            }
            // Safety net: if the bounce failed and AIGate is still the active
            // app, restore the settings UI instead of stranding the user on a
            // transparent screen.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self = self, self.panelBounceInFlight else { return }
                self.panelBounceInFlight = false
                if UIApplication.shared.applicationState == .active {
                    FaircopyAppModel.shared.suppressSettingsUI = false
                }
            }
        }
    }
}
