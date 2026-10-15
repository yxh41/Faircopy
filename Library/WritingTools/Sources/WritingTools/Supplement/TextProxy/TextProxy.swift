//
//  TextProxy.swift
//  WritingTools
//
//  Created by 秋星桥 on 2024/8/19.
//

import Combine
import UIKit

typealias TextAttribute = [NSAttributedString.Key: Any]

class TextProxy: ObservableObject {
    let delegatingView: TextProxyObject

    var isEligibleForWritingTool: Bool {
        [
            delegatingView._eligibleForWritingTool,
            !selectedRange.isEmpty,
            !selectedText.isEmpty,
        ].allSatisfy { $0 }
    }

    var appearanceForWritingTool: WTAppearance {
        delegatingView._appearanceForWritingTool
    }

    @Published private(set) var selectedText: String = ""

    private(set) var selectedTextAttribute: TextAttribute = [:]
    private(set) var selectedRange: UITextRange = .init()
    private(set) var selectionRectsInView: [CGRect] = []
    private(set) var replacedRange: UITextRange = .init()

    init?(delegatingView: UIView) {
        guard let delegatingView = delegatingView as? TextProxyObject else {
            return nil
        }
        self.delegatingView = delegatingView
        frozenCurrentParameters()
        prepareSelectedTextAsynconously()
    }

    func selectAll() {
        delegatingView._selectAll()
        frozenCurrentParameters()
    }

    func frozenCurrentParameters() {
        selectedText = delegatingView._selectedText()
        selectedTextAttribute = delegatingView._selectedTextAttribute()
        selectedRange = delegatingView._selectedRange()
        selectionRectsInView = delegatingView._selectionRectsInView()
        replacedRange = selectedRange
    }

    func replaceText(with text: String, atRange range: UITextRange, attribute: TextAttribute) {
        if let range = delegatingView._replaceText(with: text, atRange: range, attribute: attribute) {
            replacedRange = range
        }
    }

    func replaceText(with text: String) {
        replaceText(with: text, atRange: selectedRange, attribute: selectedTextAttribute)
    }
}

extension TextProxy {
    struct WTAppearance {
        enum MagicColorBehavior {
            case behindText
            case overText
        }

        var magicColorBehavior: MagicColorBehavior

        init(magicColorBehavior: MagicColorBehavior) {
            self.magicColorBehavior = magicColorBehavior
        }
    }
}

extension TextProxy {
    private func prepareSelectedTextAsynconously() {
        if delegatingView._requiresAsynconousSelectedTextFetching {
            _prepareSelectedTextAsynconously()
        }
    }

    private func _prepareSelectedTextAsynconously() {
        delegatingView._fetchSelectedText { [weak self] content in
            self?.__prepareSelectedTextAsynconously(content)
        }
    }

    private func __prepareSelectedTextAsynconously(_ content: String) {
        DispatchQueue.main.async { [weak self] in
            self?.selectedText = content
        }
    }
}

protocol TextProxyObject: UIView, UITextInput {
    var _eligibleForWritingTool: Bool { get }
    var _appearanceForWritingTool: TextProxy.WTAppearance { get }
    var _requiresAsynconousSelectedTextFetching: Bool { get }
    func _selectedText() -> String
    func _fetchSelectedText(_ onCompletion: @escaping (String) -> Void)
    func _selectedTextAttribute() -> TextAttribute
    func _selectedRange() -> UITextRange
    func _selectionRectsInView() -> [CGRect]
    func _replaceText(with text: String, atRange range: UITextRange, attribute: TextAttribute) -> UITextRange?
    func _selectAll()
}
