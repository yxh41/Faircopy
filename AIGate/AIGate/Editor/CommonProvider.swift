//
//  CommonProvider.swift
//  AIGate
//
//  Created by 秋星桥 on 2024/8/23.
//

import SwiftUI

struct EndpointProvider {
    let name: String
    let endpoint: String
    let whereToGetKey: URL
}

let commonProviders: [EndpointProvider] = [
    .init(
        name: "OpenRouter",
        endpoint: "https://openrouter.ai/api",
        whereToGetKey: .init(string: "https://openrouter.ai/settings/keys")!
    ),
    .init(
        name: "DeepSeek",
        endpoint: "https://api.deepseek.com",
        whereToGetKey: .init(string: "https://platform.deepseek.com/api_keys")!
    ),
    .init(
        name: "Groq",
        endpoint: "https://api.groq.com/openai",
        whereToGetKey: .init(string: "https://console.groq.com/keys")!
    ),
    .init(
        name: "OpenAI",
        endpoint: "https://api.openai.com",
        whereToGetKey: .init(string: "https://platform.openai.com/api-keys")!
    ),
    .init(
        name: "TogetherAI",
        endpoint: "https://api.together.xyz",
        whereToGetKey: .init(string: "https://api.together.ai/settings/api-keys")!
    ),
    .init(
        name: "NVIDIA NIM",
        endpoint: "https://integrate.api.nvidia.com",
        whereToGetKey: .init(string: "https://build.nvidia.com/explore/reasoning")!
    ),
    .init(
        name: "GitHub Models",
        endpoint: "https://models.inference.ai.azure.com",
        whereToGetKey: .init(string: "https://github.com/settings/tokens")!
    ),
]

struct CommonProviderPicker: View {
    let onSelection: (String?) -> Void

    @Environment(\.dismiss) private var dismiss

    var noticeContent: some View {
        VStack(spacing: 8) {
            Text(NSLocalizedString("These are some common providers, you can get the key from the link below, and then select the provider you want to use.", bundle: Bundle.wrti_support, comment: ""))
                .font(.callout)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(NSLocalizedString("Please be aware that these service providers are not related to our product, and we do not take responsibility for the usage of these services.", bundle: Bundle.wrti_support, comment: ""))
                .font(.callout)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var notice: some View {
        Section(NSLocalizedString("Notice", bundle: Bundle.wrti_support, comment: "")) {
            if #available(iOS 16, *) {
                noticeContent
            } else {
                noticeContent.padding(.vertical, 8)
            }
        }
    }

    var body: some View {
        List {
            notice
            Section(NSLocalizedString("Tap to Select", bundle: Bundle.wrti_support, comment: "")) {
                ForEach(commonProviders, id: \.name) { provider in
                    Button {
                        onSelection(provider.endpoint)
                        dismiss()
                    } label: {
                        Text(provider.name)
                    }
                    .foregroundStyle(Color.accent)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(NSLocalizedString("Common Provider", bundle: Bundle.wrti_support, comment: ""))
    }
}
