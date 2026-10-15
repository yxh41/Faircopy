//
//  FaircopyAppModel+Ext.swift
//  AIGate
//
//  Created by Lessica on 2024/8/27.
//

import SwiftUI

final class FaircopyAppModel: ObservableObject {
    static let shared = FaircopyAppModel()
    let tweakURL = Bundle.main.url(forResource: "Faircopy", withExtension: "dylib")

    private init() {}

    @Published var isLiteEdition = false
    @Published var isJailbroken = true

    func beginBackgroundTask() {}
    func endBackgroundTask() {}
}

extension FaircopyRootView {
    func spawnService() {}
}

struct LiteEditionBannerHeader: View {
    var body: some View {
        EmptyView()
    }
}

struct LiteEditionBannerFooter: View {
    var body: some View {
        EmptyView()
    }
}
