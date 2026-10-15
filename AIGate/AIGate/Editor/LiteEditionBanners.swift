//
//  LiteEditionBanners.swift
//  AIGate
//
//  Created by 秋星桥 on 2024/8/28.
//

import SwiftUI

private let apps: [AppAdView.App] = [
    .init(
        name: NSLocalizedString("TrollRecorder", bundle: Bundle.wrti_support, comment: ""),
        url: URL(string: "https://havoc.app/package/trollrecorder")!,
        icon: URL(string: "https://media.havoc.app/6669b3b45e7d7e36f189dc6d")!,
        description: NSLocalizedString("Record your phone calls like never before.", bundle: Bundle.wrti_support, comment: ""),
        requiresJailbreak: false
    ),
    .init(
        name: NSLocalizedString("TrollRecorder JB", bundle: Bundle.wrti_support, comment: ""),
        url: URL(string: "https://havoc.app/package/trollrecorderjb")!,
        icon: URL(string: "https://media.havoc.app/6669b3d5f0419252d3535a28")!,
        description: NSLocalizedString("Record your phone calls like never before.", bundle: Bundle.wrti_support, comment: ""),
        requiresJailbreak: true
    ),
    .init(
        name: NSLocalizedString("TrollSpeed", bundle: Bundle.wrti_support, comment: ""),
        url: URL(string: "https://havoc.app/package/trollspeed")!,
        icon: URL(string: "https://media.havoc.app/68c58106a25de63e9b02f978?w=3840&q=75")!,
        description: NSLocalizedString("Shows upload & download speed below the status bar.", bundle: Bundle.wrti_support, comment: ""),
        requiresJailbreak: false
    ),
    .init(
        name: NSLocalizedString("TrollSpeed JB", bundle: Bundle.wrti_support, comment: ""),
        url: URL(string: "https://havoc.app/package/trollspeedjb")!,
        icon: URL(string: "https://media.havoc.app/68c58106a25de63e9b02f978?w=3840&q=75")!,
        description: NSLocalizedString("Shows upload & download speed below the status bar.", bundle: Bundle.wrti_support, comment: ""),
        requiresJailbreak: true
    ),
    .init(
        name: NSLocalizedString("Touch-Viz", bundle: Bundle.wrti_support, comment: ""),
        url: URL(string: "https://havoc.app/package/touchviz")!,
        icon: URL(string: "https://media.havoc.app/66b862c5328ec2048b895110")!,
        description: NSLocalizedString("Visualize your touch interactions!", bundle: Bundle.wrti_support, comment: ""),
        requiresJailbreak: true
    ),
    .init(
        name: NSLocalizedString("Colorful Wallpaper X", bundle: Bundle.wrti_support, comment: ""),
        url: URL(string: "https://havoc.app/package/colorfulx")!,
        icon: URL(string: "https://media.havoc.app/66bce1b0debd6e7267e2beac")!,
        description: NSLocalizedString("Dynamic wallpaper with colorful effects.", bundle: Bundle.wrti_support, comment: ""),
        requiresJailbreak: true
    ),
    .init(
        name: NSLocalizedString("TrollFools", bundle: Bundle.wrti_support, comment: ""),
        url: URL(string: "https://havoc.app/package/trollfools")!,
        icon: URL(string: "https://media.havoc.app/68c58003a25de63e9b02f445")!,
        description: NSLocalizedString("In-place tweak injection with insert_dylib and ChOma.", bundle: Bundle.wrti_support, comment: ""),
        requiresJailbreak: false
    ),
    .init(
        name: NSLocalizedString("Reveil", bundle: Bundle.wrti_support, comment: ""),
        url: URL(string: "https://havoc.app/package/reveil")!,
        icon: URL(string: "https://media.havoc.app/68c57f59a25de63e9b02f016")!,
        description: NSLocalizedString("Bringing back the most advanced system and security analysis tool.", bundle: Bundle.wrti_support, comment: ""),
        requiresJailbreak: false
    ),
    .init(
        name: NSLocalizedString("Faircopy", bundle: Bundle.wrti_support, comment: ""),
        url: URL(string: "https://havoc.app/package/faircopy")!,
        icon: URL(string: "https://media.havoc.app/68c57e59a25de63e9b02e964")!,
        description: NSLocalizedString("AI tool within your hands.", bundle: Bundle.wrti_support, comment: ""),
        requiresJailbreak: true
    ),
    .init(
        name: NSLocalizedString("TrollVNC", bundle: Bundle.wrti_support, comment: ""),
        url: URL(string: "https://havoc.app/package/trollvnc")!,
        icon: URL(string: "https://media.havoc.app/68b5c442ee3a688bd20c85d5")!,
        description: NSLocalizedString("Fast, feature-rich VNC server for iOS: remote control made simple.", bundle: Bundle.wrti_support, comment: ""),
        requiresJailbreak: false
    ),
    .init(
        name: NSLocalizedString("TrollVNC JB", bundle: Bundle.wrti_support, comment: ""),
        url: URL(string: "https://havoc.app/package/trollvncjb")!,
        icon: URL(string: "https://media.havoc.app/68b5c442ee3a688bd20c85d5")!,
        description: NSLocalizedString("Fast, feature-rich VNC server for iOS: remote control made simple.", bundle: Bundle.wrti_support, comment: ""),
        requiresJailbreak: true
    ),
    .init(
        name: NSLocalizedString("XXTouch Elite", bundle: Bundle.wrti_support, comment: ""),
        url: URL(string: "https://havoc.app/package/xxtouchelite")!,
        icon: URL(string: "https://media.havoc.app/67e696fba5c34c5c759ebfcc")!,
        description: NSLocalizedString("Full-Fledged Automation Framework for Jailbroken iOS.", bundle: Bundle.wrti_support, comment: ""),
        requiresJailbreak: true
    ),
    .init(
        name: NSLocalizedString("XXTouch Elite TS", bundle: Bundle.wrti_support, comment: ""),
        url: URL(string: "https://havoc.app/package/xxtouchelitets")!,
        icon: URL(string: "https://media.havoc.app/67e696fba5c34c5c759ebfcc")!,
        description: NSLocalizedString("Full-Fledged Automation Framework for TrollStore.", bundle: Bundle.wrti_support, comment: ""),
        requiresJailbreak: false
    ),
    .init(
        name: NSLocalizedString("Letterpress", bundle: Bundle.wrti_support, comment: ""),
        url: URL(string: "https://havoc.app/package/letterpress")!,
        icon: URL(string: "https://media.havoc.app/684904c652396218b48f9849")!,
        description: NSLocalizedString("An awesome music visualizer.", bundle: Bundle.wrti_support, comment: ""),
        requiresJailbreak: false
    ),
    .init(
        name: NSLocalizedString("AutoRun", bundle: Bundle.wrti_support, comment: ""),
        url: URL(string: "https://havoc.app/package/autorun")!,
        icon: URL(string: "https://media.havoc.app/6ac7c2aa2a0d9d4dfe546475")!,
        description: NSLocalizedString("Keep your everyday apps ready.", bundle: Bundle.wrti_support, comment: ""),
        requiresJailbreak: false
    ),
].shuffled()

private let nonJailbrokenApps = apps.filter {
    !$0.requiresJailbreak
}

struct LiteEditionBannerHeader: View {
    var body: some View {
        if FaircopyAppModel.shared.isJailbroken {
            Section {
                Button(NSLocalizedString("Get Jailbreak Edition", bundle: Bundle.wrti_support, comment: "")) {
                    let url = URL(string: "https://havoc.app/package/faircopy")!
                    UIApplication.shared.open(url)
                }
            } header: {
                Text(NSLocalizedString("Complete Edition", bundle: Bundle.wrti_support, comment: ""))
            } footer: {
                Text(NSLocalizedString("Faircopy Lite is made for TrollStore with partial support for Faircopy, which is now free for everyone to try out.", bundle: Bundle.wrti_support, comment: ""))
            }
        }
    }
}

struct LiteEditionBannerFooter: View {
    var body: some View {
        Section {
            if FaircopyAppModel.shared.isJailbroken {
                ForEach([0, 1, 2, 3, 4], id: \.self) {
                    if $0 < apps.count {
                        AppAdView(app: apps[$0])
                    }
                }
            } else {
                ForEach([0, 1, 2], id: \.self) {
                    if $0 < nonJailbrokenApps.count {
                        AppAdView(app: nonJailbrokenApps[$0])
                    }
                }
            }
        } header: {
            Text(NSLocalizedString("More from OwnGoal Studio", bundle: Bundle.wrti_support, comment: ""))
        }
    }
}

private struct AppAdView: View {
    struct App {
        let name: String
        let url: URL
        let icon: URL
        let description: String
        let requiresJailbreak: Bool
    }

    let app: App

    var body: some View {
        Button {
            UIApplication.shared.open(app.url)
        } label: {
            if #available(iOS 16, *) {
                content
            } else {
                content.padding(.vertical, 8)
            }
        }
    }

    var content: some View {
        HStack(spacing: 16) {
            CachedAsyncImage(url: app.icon) { input in
                if let image = input.image {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Color.gray
                }
            }
            .clipShape(RoundedRectangle(
                cornerRadius: 6, style: .continuous
            ))
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name)
                    .font(.headline)
                Text(app.description)
                    .font(.subheadline)
            }
        }
        .tint(.primary)
    }
}
