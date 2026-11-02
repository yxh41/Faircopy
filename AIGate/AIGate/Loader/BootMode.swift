//
//  BootMode.swift
//  AIGate
//
//  Created by 秋星桥 on 2024/8/15.
//

import Foundation

enum BootMode: String, CaseIterable {
    case settingApp = "SettingApp"
    case serviceDaemon = "ServiceDaemon"
    /// 3.0.97: the resident OCR worker — the network service plus the silent
    /// `faircopy.ocr.request` listener, and no window of any kind. This is what
    /// the LaunchDaemon runs, so a picture hand-off never has to launch the app.
    case faircopyDaemon = "FaircopyDaemon"
    case bootBoth = "BootBoth"
}

extension BootMode {
    static let current: Self = {
        #if targetEnvironment(simulator) || targetEnvironment(macCatalyst)
            return .bootBoth
        #else
            // 3.0.99: the command line is checked first, and it is the reason
            // this release exists.
            //
            // `launchd.plist` can carry `EnvironmentVariables`, and on iOS 15+
            // that is no longer dependable: process spawning belongs to
            // RunningBoard, and a daemon started from a LaunchDaemon plist does
            // not necessarily inherit them. 3.0.98 shipped the worker flag that
            // way, so `BOOT_MODE` read as nil, `BootMode.current` fell back to
            // `.settingApp`, and a SwiftUI app was asked to start inside a
            // process with no window server session: `UIApplicationMain`
            // returned straight away, `main.swift` reached its `exit(0)`, and
            // launchd reported a perfectly healthy daemon with exit status 0
            // that never ran a single line of the worker.
            //
            // An argument cannot be lost the same way.
            if CommandLine.arguments.contains("--faircopy-daemon") {
                return .faircopyDaemon
            }
            guard let read = ProcessInfo.processInfo.environment["BOOT_MODE"] else {
                return .settingApp
            }
            guard let mode = BootMode(rawValue: read) else {
                fatalError("Unrecognized Boot Mode")
            }
            print("[*] using boot mode from env: \(mode.rawValue)")
            return mode
        #endif
    }()
}
