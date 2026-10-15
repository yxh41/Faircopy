//
//  WritingToolsLocalizable.swift
//
//
//  Created by 秋星桥 on 2024/8/16.
//

import Foundation

@objc(WritingToolsLocalizable)
public class WritingToolsLocalizable: NSObject {
    @objc(sharedInstance)
    public static let shared = WritingToolsLocalizable()

    override private init() {
        super.init()

        setupChineseSimplified()
    }

    var systemLanguage: String {
        Locale.preferredLanguages.first ?? "en"
    }

    var localizedStringContents = [String: [String: String]]()

    @objc
    public func localizedMenuItemTitle() -> String {
        localizedString(forKey: "Faircopy")
    }

    @objc
    public func localizedString(forKey key: String) -> String {
        var decisionLanguageIdentifier: String?
        let systemLanguage = systemLanguage.lowercased()
        if decisionLanguageIdentifier == nil, localizedStringContents.keys.contains(systemLanguage) {
            decisionLanguageIdentifier = systemLanguage
        }
        if decisionLanguageIdentifier == nil {
            for value in localizedStringContents.keys {
                if value.hasPrefix(systemLanguage) {
                    decisionLanguageIdentifier = value
                    break
                }
                if systemLanguage.hasPrefix(value) {
                    decisionLanguageIdentifier = value
                    break
                }
            }
        }
        guard let lid = decisionLanguageIdentifier else { return key }
        return localizedStringContents[lid]?[key] ?? key
    }
}
