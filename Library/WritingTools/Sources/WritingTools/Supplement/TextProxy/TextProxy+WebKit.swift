//
//  TextProxy+WebKit.swift
//  WritingTools
//
//  Created by Lessica on 2024/8/22.
//

import WebKit

import WritingToolsInjector

extension WKContentView: TextProxyObject {
    var _eligibleForWritingTool: Bool { isFocusingElement() && isUserInteractionEnabled }
    var _appearanceForWritingTool: TextProxy.WTAppearance {
        .init(magicColorBehavior: .overText)
    }

    func _selectAll() { selectAll(nil) }
    func _selectedText() -> String { text(in: _selectedRange()) ?? "" }
    func _selectedTextAttribute() -> TextAttribute { textStyling(at: _selectedRange().start, in: .forward) ?? [:] }
    func _selectedRange() -> UITextRange { selectedTextRange ?? .init() }

    var _requiresAsynconousSelectedTextFetching: Bool { true }

    // WebKit are trimming characters to 200 per selection
    // and the full content is only available by async task
    func _fetchSelectedText(_ onCompletion: @escaping (String) -> Void) {
        let selectedText = _selectedText()
        if selectedText.count < 200 {
            onCompletion(selectedText)
            return
        }
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self else { return }
            if responds(to: #selector(accessibilityRetrieveSpeakSelectionContent)),
               responds(to: #selector(accessibilitySpeakSelectionSetContent(_:)))
            {
                fc_isGettingSelectedTextSemaphore = DispatchSemaphore(value: 0)
                accessibilityRetrieveSpeakSelectionContent()
                let waited = fc_isGettingSelectedTextSemaphore?.wait(timeout: .now() + 1.0)
                fc_isGettingSelectedTextSemaphore = nil

                if waited == .timedOut {
                    onCompletion(selectedText)
                } else {
                    onCompletion(fc_selectedText ?? selectedText)
                }
            } else {
                onCompletion(selectedText)
            }
        }
    }

    private func findCompositingView(fromView view: UIView) -> UIView? {
        guard let classObject = NSClassFromString("WKCompositingView") else {
            return nil
        }
        if view.isKind(of: classObject) {
            return view
        }
        for subview in view.subviews {
            if let result = findCompositingView(fromView: subview) {
                return result
            }
        }
        return nil
    }

    func _selectionRectsInView() -> [CGRect] {
        guard let selectedTextRange else { return [] }
        var ans = selectionRects(for: selectedTextRange).map(\.rect)
        if let compositingView = findCompositingView(fromView: self) {
            ans = ans.map { compositingView.convert($0, to: self) }
        }
        return ans
    }

    func _replaceText(with text: String, atRange range: UITextRange, attribute _: TextAttribute) -> UITextRange? {
        insertText(text)
        guard let endPos = position(from: range.start, offset: text.count) else {
            return nil
        }
        let newRange = textRange(from: range.start, to: endPos)
        return newRange
    }
}
