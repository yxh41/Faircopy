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
    /// Link colour inside the answer body.
    ///
    /// The system link tint is the host app's accent colour — in the Faircopy
    /// panel that came out as a saturated blue on a warm pink surface, which
    /// looked pasted on. Mint reads as a link while staying in the same family
    /// as the panel's white-on-gradient text.
    static let tint = Color(red: 0.64, green: 0.95, blue: 0.90)

    /// Marker-style highlight behind a URL, so an address is findable in a wall
    /// of text even before the colour registers.
    static let highlight = Color.white.opacity(0.16)

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
            // Tint is applied by the view (`.tint(...)`), not as a run
            // attribute: it is the one link colour hook that exists on iOS 15
            // too, and the marker styling below is typed with iOS 16 API.
            if #available(iOS 16.0, *) {
                piece.backgroundColor = Self.highlight
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
