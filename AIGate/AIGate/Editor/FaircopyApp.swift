//
//  FaircopyApp.swift
//  AIGate
//
//  Created by 秋星桥 on 2024/8/15.
//

import Darwin
import SwiftUI

struct FaircopyApp: App {
    @StateObject var vm = FaircopyAppModel.shared

    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            NavigationView {
                FaircopyRootView()
            }
            .navigationViewStyle(.stack)
        }
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
    func application(_: UIApplication, didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        true
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

    func scene(_ scene: UIScene, willConnectTo _: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions)
    {
        guard let _ = scene as? UIWindowScene else { return }
        if let url = connectionOptions.urlContexts.first?.url,
           let src = connectionOptions.urlContexts.first?.options.sourceApplication
        {
            handleOpenURL(url, sourceApplication: src)
        }
    }

    func sceneDidBecomeActive(_: UIScene) {
        FaircopyAppModel.shared.endBackgroundTask()
    }

    func scene(_: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url,
              let src = URLContexts.first?.options.sourceApplication
        else {
            return
        }
        handleOpenURL(url, sourceApplication: src)
    }

    private func handleOpenURL(_ url: URL, sourceApplication src: String) {
        if url.host == "spawn" {
            FaircopyAppModel.shared.beginBackgroundTask()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                LSApplicationWorkspace.default().openApplication(withBundleID: src)
            }
        }
        if url.host == "panel" {
            // External panel entry: bounce back to the caller first, then post
            // the Darwin notification the tweak listens for. See
            // kFCExternalPresentNotification in WritingToolsInjector.h.
            FaircopyAppModel.shared.beginBackgroundTask()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                LSApplicationWorkspace.default().openApplication(withBundleID: src)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                // Keep in sync with kFCExternalPresentNotification in
                // Library/WritingTools/Sources/WritingToolsInjector.h
                notify_post("wiki.qaq.faircopy.present")
            }
        }
    }
}
