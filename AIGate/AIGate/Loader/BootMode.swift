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
