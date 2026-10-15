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
