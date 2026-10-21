//
//  WritingToolsView+Links.swift
//  WritingTools
//
//  Created for Faircopy 3.0.52 — tappable links in answers.
//

import Foundation
import SwiftUI

/// Turns plain answer text into something tappable.
///
/// Answers used to be rendered with a bare `Text`, where a URL is inert — the
/// best you could do was long-press and copy it. With web search enabled the
/// model produces real links (and the provider attaches citations the body never
/// mentions), so every URL is promoted to a link attribute here.
enum AnswerLinkParser {
    /// `NSDataDetector` is documented as thread-safe and expensive to build, so
    /// it is created once.
    private static let detector: NSDataDetector? = {
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    }()

    /// Every http(s) URL in `text`, in source order.
    static func urls(in text: String) -> [URL] {
        guard !text.isEmpty, let detector else { return [] }
        let full = text as NSString
        return detector
            .matches(in: text, range: NSRange(location: 0, length: full.length))
            .compactMap { match in
                guard let url = match.url, url.scheme?.hasPrefix("http") == true else { return nil }
                return url
            }
    }

    /// Rebuilds `text` with every URL turned into a tappable link.
    ///
    /// Built by slicing around the matches rather than mapping NSRange offsets
    /// onto AttributedString indices: NSRange counts UTF-16 units while
    /// AttributedString indices count characters, so one emoji (2 units) would
    /// shift every link after it onto the wrong text.
    static func linkified(_ text: String) -> AttributedString {
        guard !text.isEmpty else { return AttributedString() }
        guard let detector else { return AttributedString(text) }
        let full = text as NSString
        let matches = detector.matches(in: text, range: NSRange(location: 0, length: full.length))
        guard !matches.isEmpty else { return AttributedString(text) }

        var result = AttributedString()
        var cursor = text.startIndex
        for match in matches {
            guard let matchRange = Range(match.range, in: text),
                  let url = match.url,
                  url.scheme?.hasPrefix("http") == true
            else { continue }
            // Overlapping matches would corrupt the rebuilt string.
            guard cursor <= matchRange.lowerBound else { continue }
            if cursor < matchRange.lowerBound {
                result += AttributedString(String(text[cursor ..< matchRange.lowerBound]))
            }
            var piece = AttributedString(String(text[matchRange]))
            piece.link = url
            // The SwiftUI underline attribute is typed `Text.LineStyle`, which is
            // iOS 16+. On iOS 15 the link still shows in the tint colour and is
            // tappable, so the guard only costs the underline on old systems.
            if #available(iOS 16.0, *) {
                piece.underlineStyle = .single
            }
            result += piece
            cursor = matchRange.upperBound
        }
        if cursor < text.endIndex {
            result += AttributedString(String(text[cursor...]))
        }
        return result
    }
}
