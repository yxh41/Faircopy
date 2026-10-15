//
//  Bundle+Ext.swift
//  AIGate
//
//  Created by Lessica on 2024/8/20.
//

import Foundation

extension Bundle {
    static let wrti_support = Bundle.main
    static let wrti_packageVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
}
