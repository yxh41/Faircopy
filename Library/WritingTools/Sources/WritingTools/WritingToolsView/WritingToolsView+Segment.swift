//
//  WritingToolsView+Segment.swift
//  WritingTools
//
//  Word segmentation mode (分词). Splits the selected text into word tokens
//  and renders them as tappable chips. The tokenizer mirrors the approach
//  used by Kayoko (same studio): sentence enumeration for line breaks ->
//  NSDataDetector so links / phone numbers / dates / addresses stay whole ->
//  CFStringTokenizer word units -> CJK runs split per composed character.
//

import Foundation
import SwiftUI

/// One segmentation token with its UTF-16 range in the source text.
public struct SegmentToken: Identifiable, Equatable, Hashable {
    public let id: Int
    public let text: String
    public let range: NSRange
    public let lineBreakAfter: Bool

    public init(id: Int, text: String, range: NSRange, lineBreakAfter: Bool = false) {
        self.id = id
        self.text = text
        self.range = range
        self.lineBreakAfter = lineBreakAfter
    }

    // Manual conformances: NSRange's own Hashable synthesis is not something
    // we want to depend on across SDK versions.
    public static func == (lhs: SegmentToken, rhs: SegmentToken) -> Bool {
        lhs.id == rhs.id
            && lhs.text == rhs.text
            && lhs.range.location == rhs.range.location
            && lhs.range.length == rhs.range.length
            && lhs.lineBreakAfter == rhs.lineBreakAfter
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(text)
        hasher.combine(range.location)
        hasher.combine(range.length)
        hasher.combine(lineBreakAfter)
    }
}

/// Source length cap for a single segmentation pass. CJK text approaches one
/// token per character, so this bounds how many chips get rendered.
let kSegmentMaxLength = 1000

public enum WordSegmenter {
    /// Tokenizes text into word tokens.
    /// - Returns: the tokens plus whether the source was truncated.
    public static func segment(_ text: String) -> (tokens: [SegmentToken], truncated: Bool) {
        let source = text as NSString
        guard source.length > 0 else { return ([], false) }

        var truncated = false
        var effective = text
        if source.length > kSegmentMaxLength {
            var end = kSegmentMaxLength
            // back off a trailing high surrogate so we never split a pair
            while end > 0 {
                let unit = source.character(at: end - 1)
                if unit < 0xD800 || unit > 0xDBFF { break }
                end -= 1
            }
            effective = source.substring(to: end)
            truncated = true
        }

        let engine = SegmentEngine(source: effective as NSString)
        return (engine.run(), truncated)
    }
}

/// Port of Kayoko's KayokoWordSelectionTokenizer.
private final class SegmentEngine {
    private let source: NSString
    private var tokens: [SegmentToken] = []

    init(source: NSString) {
        self.source = source
    }

    func run() -> [SegmentToken] {
        let fullRange = NSRange(location: 0, length: source.length)
        var cursor = 0
        var previousSentenceLastIndex = NSNotFound
        var foundSentence = false

        source.enumerateSubstrings(in: fullRange, options: .bySentences) { _, sentenceRange, _, _ in
            foundSentence = true

            if sentenceRange.location > cursor {
                let gapRange = NSRange(location: cursor, length: sentenceRange.location - cursor)
                self.detectedTokens(in: gapRange)
            }

            let before = self.tokens.count
            self.detectedTokens(in: sentenceRange)
            let producedTokens = self.tokens.count > before
            if producedTokens, previousSentenceLastIndex != NSNotFound {
                self.markLineBreak(at: previousSentenceLastIndex)
            }
            if producedTokens {
                previousSentenceLastIndex = self.tokens.count - 1
            }

            cursor = NSMaxRange(sentenceRange)
        }

        if !foundSentence {
            detectedTokens(in: fullRange)
            return tokens
        }
        if cursor < source.length {
            let remaining = NSRange(location: cursor, length: source.length - cursor)
            detectedTokens(in: remaining)
        }
        return tokens
    }

    // MARK: - Detectors

    /// Splits a range into detected entities (links, phones, dates, ...) and
    /// word tokens for everything in between.
    private func detectedTokens(in range: NSRange) {
        guard range.length > 0 else { return }

        var matches: [NSTextCheckingResult] = []
        Self.dataDetector?.enumerateMatches(in: source as String, options: [], range: range) { result, _, _ in
            guard let result, result.range.length > 0 else { return }
            matches.append(result)
        }
        matches.sort { $0.range.location < $1.range.location }

        var cursor = range.location
        for result in matches {
            let r = result.range
            if r.location < cursor || NSMaxRange(r) > NSMaxRange(range) { continue }
            if r.location > cursor {
                let gap = NSRange(location: cursor, length: r.location - cursor)
                wordTokens(in: gap)
            }
            addToken(in: r)
            cursor = NSMaxRange(r)
        }
        if cursor < NSMaxRange(range) {
            let remaining = NSRange(location: cursor, length: NSMaxRange(range) - cursor)
            wordTokens(in: remaining)
        }
    }

    // MARK: - Word Tokenization

    private func wordTokens(in range: NSRange) {
        guard range.length > 0 else { return }
        let substring = source.substring(with: range)

        guard let tokenizer = CFStringTokenizerCreate(
            kCFAllocatorDefault,
            substring as CFString,
            CFRangeMake(0, substring.utf16.count),
            kCFStringTokenizerUnitWord,
            nil
        ) else {
            characterTokens(in: range)
            return
        }

        var cursor = range.location
        var tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        while tokenType != [] {
            let cfRange = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            if cfRange.length == 0 || cfRange.location == kCFNotFound { break }
            let tokenRange = NSRange(location: range.location + cfRange.location, length: cfRange.length)

            if tokenRange.location > cursor {
                let gap = NSRange(location: cursor, length: tokenRange.location - cursor)
                characterTokens(in: gap)
            }

            // Keep consecutive non-CJK characters grouped (Latin words stay
            // whole) while emitting each CJK character / CJK punctuation as its
            // own token. Replaces the old behaviour where any CJK char in a
            // token forced the entire token — adjacent Latin words included — to
            // split per character.
            emitMixedToken(in: tokenRange)

            cursor = NSMaxRange(tokenRange)
            tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        }

        if cursor < NSMaxRange(range) {
            let remaining = NSRange(location: cursor, length: NSMaxRange(range) - cursor)
            characterTokens(in: remaining)
        }
    }

    /// Tokenizes a single CFStringTokenizer word unit without fragmenting Latin
    /// runs. Walks the unit by composed character: consecutive non-CJK
    /// characters accumulate into one token, while every CJK character (or CJK
    /// punctuation) becomes its own token. Mixed text like "你hello好" therefore
    /// yields "你", "hello", "好" instead of one glyph per character.
    private func emitMixedToken(in range: NSRange) {
        let substring = source.substring(with: range) as NSString
        var runStart = range.location
        var runLength = 0
        let flush = {
            if runLength > 0 {
                self.addToken(in: NSRange(location: runStart, length: runLength))
                runLength = 0
            }
        }
        substring.enumerateSubstrings(
            in: NSRange(location: 0, length: substring.length),
            options: .byComposedCharacterSequences
        ) { piece, pieceRange, _, _ in
            guard let piece else { return }
            if Self.containsCJK(piece) {
                flush()
                let actual = NSRange(location: range.location + pieceRange.location, length: pieceRange.length)
                self.addToken(in: actual)
            } else {
                if runLength == 0 { runStart = range.location + pieceRange.location }
                runLength += pieceRange.length
            }
        }
        flush()
    }

    /// Emits one token per composed character sequence (punctuation, symbols,
    /// CJK characters).
    private func characterTokens(in range: NSRange) {
        guard range.length > 0 else { return }
        let substring = source.substring(with: range) as NSString
        substring.enumerateSubstrings(
            in: NSRange(location: 0, length: substring.length),
            options: .byComposedCharacterSequences
        ) { piece, pieceRange, _, _ in
            guard let piece, Self.isValid(piece) else { return }
            let actual = NSRange(location: range.location + pieceRange.location, length: pieceRange.length)
            self.addToken(in: actual)
        }
    }

    // MARK: - Token Construction

    private func addToken(in range: NSRange) {
        guard range.location >= 0, NSMaxRange(range) <= source.length else { return }
        let text = source.substring(with: range)
        guard Self.isValid(text) else { return }
        tokens.append(SegmentToken(id: tokens.count, text: text, range: range))
    }

    private func markLineBreak(at index: Int) {
        guard index >= 0, index < tokens.count else { return }
        let token = tokens[index]
        tokens[index] = SegmentToken(
            id: token.id,
            text: token.text,
            range: token.range,
            lineBreakAfter: true
        )
    }

    // MARK: - Helpers

    private static func isValid(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func containsCJK(_ text: String) -> Bool {
        text.rangeOfCharacter(from: cjkCharacterSet) != nil
    }

    private static let cjkCharacterSet: CharacterSet = {
        var set = CharacterSet()
        let ranges: [(UInt32, UInt32)] = [
            (0x4E00, 0x9FFF), // CJK Unified Ideographs
            (0xF900, 0xFAFF), // CJK Compatibility Ideographs
            (0x3000, 0x303F), // CJK Symbols and Punctuation
            (0x3040, 0x309F), // Hiragana
            (0x30A0, 0x30FF), // Katakana
            (0x31F0, 0x31FF), // Katakana Phonetic Extensions
            (0xAC00, 0xD7AF), // Hangul Syllables
            (0x1100, 0x11FF), // Hangul Jamo
            (0x3130, 0x318F), // Hangul Compatibility Jamo
        ]
        for (low, high) in ranges {
            guard let lowScalar = Unicode.Scalar(low), let highScalar = Unicode.Scalar(high) else { continue }
            set.insert(charactersIn: lowScalar ... highScalar)
        }
        return set
    }()

    private static let dataDetector: NSDataDetector? = {
        let types = NSTextCheckingResult.CheckingType.link.rawValue
            | NSTextCheckingResult.CheckingType.phoneNumber.rawValue
            | NSTextCheckingResult.CheckingType.date.rawValue
            | NSTextCheckingResult.CheckingType.address.rawValue
            | NSTextCheckingResult.CheckingType.transitInformation.rawValue
        return try? NSDataDetector(types: types)
    }()
}

// MARK: - Chips

/// A single word chip. Standalone struct keeps the enclosing expressions
/// small enough for the Swift type checker. The Text drives the layout size
/// (predictable in HStacks); the capsule is purely a background.
/// Uses a plain Button (NOT onTapGesture): the output area lives inside a
/// ScrollView, whose pan gesture cancels SwiftUI TapGestures on the slightest
/// finger drift — users reported chips needing several taps. A UIButton has a
/// proper touch slop and cleanly separates light taps (select) from drags
/// (scroll), same as every UITableView cell.
struct SegmentChip: View {
    let text: String
    let isSelected: Bool
    let maxWidth: CGFloat
    let action: () -> Void
    /// Content-space frames of every chip, for swipe-selection hit testing.
    let allFrames: [Int: CGRect]
    /// This chip's token id (also its key in `allFrames`).
    let selfId: Int
    /// Reports the finger position (content space) while a drag is in progress.
    let onDragChanged: (CGPoint) -> Void
    let onDragEnded: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.black : Color.white)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: maxWidth - 20)
                .padding(.horizontal, 10)
                .frame(minHeight: 34)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.white : Color.white.opacity(0.12))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Swipe selection: a drag started on this chip keeps reporting the finger
        // position relative to this chip's own frame, which the parent maps to a
        // chip id and extends the selection range. A plain tap still toggles via
        // `action` because the drag only acts once the finger actually moves.
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard let my = allFrames[selfId] else { return }
                    let absolute = CGPoint(
                        x: my.origin.x + value.location.x,
                        y: my.origin.y + value.location.y
                    )
                    onDragChanged(absolute)
                }
                .onEnded { _ in onDragEnded() }
        )
    }
}

/// One wrapping row of word chips.
struct SegmentRowView: View {
    let tokens: [SegmentToken]
    let selected: Set<Int>
    let maxWidth: CGFloat
    let allFrames: [Int: CGRect]
    let onTap: (Int) -> Void
    let onDragChanged: (CGPoint) -> Void
    let onDragEnded: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(tokens) { token in
                SegmentChip(
                    text: token.text,
                    isSelected: selected.contains(token.id),
                    maxWidth: maxWidth,
                    allFrames: allFrames,
                    selfId: token.id,
                    action: { onTap(token.id) },
                    onDragChanged: onDragChanged,
                    onDragEnded: onDragEnded
                )
            }
        }
    }
}

extension WritingToolsView {
    /// Wrapping flow of word chips. Rows are pre-computed with NSString
    /// measurement (the `Layout` protocol is iOS 16+; deployment target is
    /// iOS 15) and rendered through a LazyVStack so long inputs stay cheap.
    var segmentOutputArea: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let frames = Self.segmentFrames(tokens: segmentTokens, availableWidth: width)
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(
                        Self.segmentRows(tokens: segmentTokens, availableWidth: width),
                        id: \.self
                    ) { row in
                        SegmentRowView(
                            tokens: row,
                            selected: selectedSegmentIndexes,
                            maxWidth: width,
                            allFrames: frames,
                            onTap: toggleSegmentSelection,
                            onDragChanged: { point in handleSegmentDrag(at: point, frames: frames) },
                            onDragEnded: handleSegmentDragEnded
                        )
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    /// Shared layout pass: packs tokens into rows (greedy, honouring sentence
    /// line breaks) and records each token's content-space frame so swipe
    /// selection can hit-test the finger against chips without runtime geometry.
    private static func packSegmentRows(
        tokens: [SegmentToken],
        availableWidth: CGFloat
    ) -> (rows: [[SegmentToken]], frames: [Int: CGRect]) {
        guard availableWidth > 0 else { return ([], [:]) }
        let font = UIFont.systemFont(ofSize: 13)
        let spacing: CGFloat = 6
        let chipPadding: CGFloat = 22
        let rowPitch: CGFloat = 40 // chip minHeight 34 + row spacing 6
        let rowInset: CGFloat = 2 // matches the LazyVStack's horizontal padding

        let innerWidth = max(availableWidth - rowInset * 2, 0)
        var rows: [[SegmentToken]] = []
        var frames: [Int: CGRect] = [:]
        var current: [SegmentToken] = []
        var currentWidth: CGFloat = 0
        var y: CGFloat = 0
        var x: CGFloat = rowInset

        for token in tokens {
            let textWidth = (token.text as NSString).size(withAttributes: [.font: font]).width
            let chipWidth = min(textWidth + chipPadding, innerWidth)
            let candidate = current.isEmpty ? chipWidth : currentWidth + spacing + chipWidth
            let newRow = !current.isEmpty && candidate > innerWidth
            if newRow {
                rows.append(current)
                current = []
                currentWidth = 0
                y += rowPitch
                x = rowInset
            }
            frames[token.id] = CGRect(x: x, y: y, width: chipWidth, height: 34)
            current.append(token)
            currentWidth = newRow ? chipWidth : candidate
            x += chipWidth + spacing
            if token.lineBreakAfter {
                rows.append(current)
                current = []
                currentWidth = 0
                y += rowPitch
                x = rowInset
            }
        }
        if !current.isEmpty { rows.append(current) }
        return (rows, frames)
    }

    /// Greedy row packing of chips, honouring sentence line breaks.
    static func segmentRows(tokens: [SegmentToken], availableWidth: CGFloat) -> [[SegmentToken]] {
        packSegmentRows(tokens: tokens, availableWidth: availableWidth).rows
    }

    /// Content-space frames for every chip, used by swipe selection hit-testing.
    static func segmentFrames(tokens: [SegmentToken], availableWidth: CGFloat) -> [Int: CGRect] {
        packSegmentRows(tokens: tokens, availableWidth: availableWidth).frames
    }

    var segmentStatsLine: some View {
        HStack(spacing: 8) {
            Image(systemName: "textformat.abc")
            Text(String(format: "%d words".localized, segmentTokens.count))
            if segmentTruncated {
                Text("· " + String(format: "First %d chars".localized, kSegmentMaxLength))
            }
            Text("· " + String(format: "%d selected".localized, selectedSegmentIndexes.count))
            Spacer()
        }
        .font(.caption2)
        .foregroundStyle(.white.opacity(0.55))
    }

    // MARK: - State

    func runSegmentation() {
        error = nil
        let result = WordSegmenter.segment(context.textProxy.selectedText)
        segmentTokens = result.tokens
        segmentTruncated = result.truncated
        selectedSegmentIndexes = []
        segmentActive = true
        output = ""
        isRunning = false
    }

    func toggleSegmentSelection(_ index: Int) {
        if selectedSegmentIndexes.contains(index) {
            selectedSegmentIndexes.remove(index)
        } else {
            selectedSegmentIndexes.insert(index)
        }
    }

    // MARK: - Swipe Selection

    /// Extends the selection to form a contiguous range from the chip where the
    /// drag began to the chip currently under the finger. The first contact only
    /// records the anchor; an actual movement (past a small threshold) engages
    /// range selection so an ordinary tap still toggles via the chip button.
    func handleSegmentDrag(at point: CGPoint, frames: [Int: CGRect]) {
        guard let hit = frames.first(where: { $0.value.insetBy(dx: -8, dy: -8).contains(point) }) else { return }
        let index = hit.key

        if segmentDragAnchor == nil {
            segmentDragAnchor = index
            segmentDragStartPoint = point
            return
        }

        if !segmentIsDragging {
            let dx = point.x - segmentDragStartPoint.x
            let dy = point.y - segmentDragStartPoint.y
            guard (dx * dx + dy * dy) > 64 else { return }
            segmentIsDragging = true
            selectedSegmentIndexes = [segmentDragAnchor!]
        }

        guard let anchor = segmentDragAnchor else { return }
        let lo = min(anchor, index)
        let hi = max(anchor, index)
        selectedSegmentIndexes = Set(lo...hi)
    }

    func handleSegmentDragEnded() {
        segmentIsDragging = false
        segmentDragAnchor = nil
        segmentDragStartPoint = .zero
    }

    var segmentSelectedTokens: [SegmentToken] {
        segmentTokens.filter { selectedSegmentIndexes.contains($0.id) }
    }

    /// Space-joined tokens — the classic segmentation output. Uses the
    /// selection when one exists, otherwise every token.
    var segmentSpacedText: String {
        let tokens = segmentSelectedTokens.isEmpty ? segmentTokens : segmentSelectedTokens
        return tokens.map(\.text).joined(separator: " ")
    }

    /// Selected tokens rejoined with their original separators, so unselected
    /// words can be dropped without mangling punctuation or line breaks.
    var segmentReconstructedText: String {
        let tokens = segmentSelectedTokens
        guard !tokens.isEmpty else { return context.textProxy.selectedText }
        let source = context.textProxy.selectedText as NSString
        var result = ""
        var lastEnd: Int?
        for token in tokens {
            if let lastEnd, lastEnd <= token.range.location {
                let gap = NSRange(location: lastEnd, length: token.range.location - lastEnd)
                result += source.substring(with: gap)
            }
            result += token.text
            lastEnd = NSMaxRange(token.range)
        }
        return result
    }

    func copySegmentResult() {
        UIPasteboard.general.string = segmentSpacedText
        // Clear the selection so the next batch of words can be picked without
        // manually deselecting first.
        selectedSegmentIndexes.removeAll()
    }

    /// Share the current selection (or all tokens). Clears the selection after
    /// handing the text off, mirroring copySegmentResult.
    func shareSegmentResult() {
        shareText(segmentSpacedText)
        selectedSegmentIndexes.removeAll()
    }

    func acceptSegmentResult() {
        dismiss()
        context.textProxy.replaceText(with: segmentReconstructedText)
    }
}
