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

// MARK: - Haptics

/// Shared light impact generator for selection feedback (Kayoko fires one on
/// every selection change). Lazily created on first use, on the main thread.
enum SegmentHaptics {
    static let light = UIImpactFeedbackGenerator(style: .light)
}

/// True when `text` is entirely CJK ideographs / CJK punctuation / kana / hangul.
/// Used to decide spacing when rejoining non-contiguously selected tokens: CJK
/// runs stay tight, consecutive Latin words get a single space between them.
private func segmentTextIsCJK(_ text: String) -> Bool {
    for scalar in text.unicodeScalars {
        let v = scalar.value
        if (0x3000...0x303F).contains(v)   // CJK Symbols and Punctuation
            || (0x3040...0x30FF).contains(v) // Hiragana + Katakana
            || (0x3400...0x4DBF).contains(v) // CJK Unified Ideographs Ext A
            || (0x4E00...0x9FFF).contains(v) // CJK Unified Ideographs
            || (0xF900...0xFAFF).contains(v) // CJK Compatibility Ideographs
            || (0x1100...0x11FF).contains(v) // Hangul Jamo
            || (0x3130...0x318F).contains(v) // Hangul Compatibility Jamo
            || (0xAC00...0xD7AF).contains(v) // Hangul Syllables
        {
            return true
        }
    }
    return false
}

// MARK: - Chips

/// A single word chip: purely visual. All gestures live in `SegmentGestureLayer`
/// (a UIKit overlay), so the chip itself has no SwiftUI gesture that could
/// compete with the enclosing ScrollView.
///
/// The chip's width comes from the layout pass (`frames`), never from SwiftUI's
/// own text metrics. Letting SwiftUI pick its natural width meant every chip
/// could differ from the measured rect by a point or two, and the error
/// accumulated along a row — the visual chips ended up shifted right of their
/// hit rects, so tapping one word selected its neighbour.
struct SegmentChip: View {
    let text: String
    let isSelected: Bool
    let width: CGFloat

    var body: some View {
        Text(text)
            // Weight must NOT change with selection: a semibold chip is wider and
            // would reflow the row away from the measured rects.
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(isSelected ? Color.black : Color.white)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(width: max(width - 20, 1), height: 34)
            .padding(.horizontal, 10)
            .background(
                Capsule()
                    .fill(isSelected ? Color.white : Color.white.opacity(0.12))
            )
            .contentShape(Rectangle())
    }
}

/// One wrapping row of word chips.
struct SegmentRowView: View {
    let tokens: [SegmentToken]
    let selected: Set<Int>
    /// Content-space rects from the shared layout pass; only `width` is used here
    /// so what is drawn is exactly what gets hit-tested.
    let frames: [Int: CGRect]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(tokens) { token in
                SegmentChip(
                    text: token.text,
                    isSelected: selected.contains(token.id),
                    width: frames[token.id]?.width ?? 60
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
            // One layout pass for rows + hit-test frames + content height.
            let packed = Self.packSegmentRows(tokens: segmentTokens, availableWidth: width)
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(packed.rows, id: \.self) { row in
                        SegmentRowView(
                            tokens: row,
                            selected: selectedSegmentIndexes,
                            frames: packed.frames
                        )
                    }
                }
                .padding(.horizontal, 2)
                // Fill the viewport width so the gesture layer's origin and the
                // measured `frames` share one coordinate space (a narrower stack
                // would get centred by the ScrollView and offset every hit rect).
                .frame(maxWidth: .infinity, alignment: .leading)
                // UIKit gesture layer over the chips: deterministic vertical
                // scrolling (its pan declines vertical drags) + tap + horizontal
                // additive/subtractive range selection, exactly like Kayoko.
                // Sized to the measured content height so its coordinate space
                // matches `frames` exactly (no dependence on lazy layout).
                .overlay(alignment: .topLeading) {
                    SegmentGestureLayer(
                        frames: packed.frames,
                        onTap: handleSegmentTap,
                        onPanBegan: handleSegmentPanBegan,
                        onPanChanged: handleSegmentPanChanged,
                        onPanEnded: handleSegmentPanEnded
                    )
                    .frame(width: width, height: packed.height)
                }
            }
        }
    }

    /// Shared layout pass: packs tokens into rows (greedy, honouring sentence
    /// line breaks) and records each token's content-space frame so swipe
    /// selection can hit-test the finger against chips without runtime geometry.
    private static func packSegmentRows(
        tokens: [SegmentToken],
        availableWidth: CGFloat
    ) -> (rows: [[SegmentToken]], frames: [Int: CGRect], height: CGFloat) {
        guard availableWidth > 0 else { return ([], [:], 0) }
        let font = UIFont.systemFont(ofSize: 13)
        let spacing: CGFloat = 6
        // 10pt horizontal padding on each side + 4pt slack, so the text never
        // truncates when the chip is pinned to this exact width.
        let chipPadding: CGFloat = 24
        let rowPitch: CGFloat = 40 // chip height 34 + row spacing 6
        let rowInset: CGFloat = 2 // matches the LazyVStack's horizontal padding

        let innerWidth = max(availableWidth - rowInset * 2, 0)
        var rows: [[SegmentToken]] = []
        var frames: [Int: CGRect] = [:]
        var current: [SegmentToken] = []
        var currentWidth: CGFloat = 0
        var y: CGFloat = 0
        var x: CGFloat = rowInset

        for token in tokens {
            // `ceil` keeps every chip width integral: fractional widths would be
            // snapped independently at render time and cost up to 0.5pt per chip.
            let textWidth = ceil((token.text as NSString).size(withAttributes: [.font: font]).width)
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
        let height = rows.isEmpty ? 0 : CGFloat(rows.count) * 34 + CGFloat(rows.count - 1) * 6
        return (rows, frames, height)
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

    // MARK: - Selection callbacks (driven by SegmentGestureLayer)

    /// A tap (no drag) toggles the chip under the finger.
    func handleSegmentTap(_ index: Int) {
        toggleSegmentSelection(index)
        SegmentHaptics.light.impactOccurred()
    }

    /// A horizontal drag began: snapshot the current selection and decide —
    /// mirroring Kayoko — whether this gesture adds (anchor was unselected) or
    /// removes (anchor was selected).
    func handleSegmentPanBegan(_ index: Int) {
        segmentDragAnchor = index
        segmentDragOriginalSelection = selectedSegmentIndexes
        segmentDragSelects = !selectedSegmentIndexes.contains(index)
        segmentIsDragging = true
        SegmentHaptics.light.prepare()
    }

    func handleSegmentPanChanged(_ index: Int) {
        guard segmentIsDragging, let anchor = segmentDragAnchor else { return }
        applySegmentDragRange(anchor: anchor, through: index)
    }

    func handleSegmentPanEnded() {
        segmentIsDragging = false
        segmentDragAnchor = nil
        segmentDragOriginalSelection = []
        segmentDragSelects = true
    }

    /// Recomputes the applied range from the pre-drag snapshot every time, so
    /// dragging back toward the anchor shrinks the applied range instead of
    /// leaving a committed trail (matching Kayoko's applySelectionGestureThroughIndex).
    private func applySegmentDragRange(anchor: Int, through index: Int) {
        let lower = min(anchor, index)
        let upper = max(anchor, index)
        var updated = segmentDragOriginalSelection
        if segmentDragSelects {
            for i in lower ... upper { updated.insert(i) }
        } else {
            for i in lower ... upper { updated.remove(i) }
        }
        guard updated != selectedSegmentIndexes else { return }
        selectedSegmentIndexes = updated
        SegmentHaptics.light.impactOccurred()
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

    /// Selected tokens rejoined so that on Accept, unselected words are actually
    /// removed from the text.
    ///
    /// - Contiguous selection (a token begins exactly where the previous ended):
    ///   the original separator — whitespace, punctuation, line break — is copied
    ///   back verbatim, so punctuation survives reconstruction.
    /// - Non-contiguous selection (skipped words sit in the gap): the gap is
    ///   dropped entirely and the kept tokens are rejoined with minimal spacing
    ///   (no space inside CJK runs, a single space between Latin words). This is
    ///   what makes "select token 1 and token 3, skip token 2" remove token 2
    ///   instead of splicing it back through the gap.
    var segmentReconstructedText: String {
        let tokens = segmentSelectedTokens
        guard !tokens.isEmpty else { return context.textProxy.selectedText }
        let source = context.textProxy.selectedText as NSString
        var result = ""
        var lastEnd: Int? = nil
        var lastText: String? = nil
        for token in tokens {
            if let lastEnd {
                if lastEnd < token.range.location {
                    // Skipped tokens occupy the gap: drop them and rejoin the kept
                    // tokens with the same spacing rule as the search keyword.
                    let prevIsLatin = lastText.map { !segmentTextIsCJK($0) } ?? false
                    let currIsLatin = !segmentTextIsCJK(token.text)
                    if prevIsLatin, currIsLatin { result += " " }
                    print("[Faircopy] segment: dropping skipped words between kept tokens")
                } else if lastEnd == token.range.location {
                    // Contiguous: preserve the original separator verbatim.
                    let gap = NSRange(location: lastEnd, length: token.range.location - lastEnd)
                    if gap.length > 0 { result += source.substring(with: gap) }
                }
                // lastEnd > location: overlapping/duplicate selection — ignore.
            }
            result += token.text
            lastEnd = NSMaxRange(token.range)
            lastText = token.text
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

// MARK: - UIKit gesture layer

/// Tap + pan gesture host for the word chips, mirroring Kayoko's
/// `KayokoWordSelectionView` recognisers. Living in UIKit (instead of a SwiftUI
/// `DragGesture` per chip) is what makes vertical scrolling deterministic:
/// `gestureRecognizerShouldBegin` declines vertical-dominant pans so the
/// enclosing SwiftUI ScrollView scrolls, while horizontal pans drive
/// additive/subtractive range selection.
///
/// The view is transparent and only hit-tests against `frames` (content-space
/// chip rects) — the chips themselves stay pure SwiftUI for styling.
struct SegmentGestureLayer: UIViewRepresentable {
    let frames: [Int: CGRect]
    let onTap: (Int) -> Void
    let onPanBegan: (Int) -> Void
    let onPanChanged: (Int) -> Void
    let onPanEnded: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let view = GestureHostView()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.isUserInteractionEnabled = true
        view.isMultipleTouchEnabled = false

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        tap.delegate = context.coordinator
        tap.cancelsTouchesInView = false
        tap.delaysTouchesEnded = false
        view.addGestureRecognizer(tap)

        let pan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePan(_:))
        )
        pan.delegate = context.coordinator
        // Never consume the touches the ScrollView needs — we simply observe.
        pan.cancelsTouchesInView = false
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)

        context.coordinator.hostView = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // Keep the coordinator pointed at the freshest closures/frames, since the
        // SwiftUI view (and thus `self`) is rebuilt on every selection change.
        context.coordinator.parent = self
        context.coordinator.hostView = uiView as? GestureHostView
    }

    /// Transparent host that knows which `UIScrollView` encloses it, so the
    /// scroll can be frozen while a selection drag is in flight (Kayoko sets
    /// `scrollView.scrollEnabled = NO` for the same reason).
    final class GestureHostView: UIView {
        private weak var cachedScrollView: UIScrollView?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            cachedScrollView = nil
            _ = resolveScrollView()
        }

        func resolveScrollView() -> UIScrollView? {
            if let cachedScrollView { return cachedScrollView }
            var candidate: UIView? = superview
            while let view = candidate {
                if let scroll = view as? UIScrollView {
                    cachedScrollView = scroll
                    return scroll
                }
                candidate = view.superview
            }
            return nil
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: SegmentGestureLayer
        weak var hostView: GestureHostView?
        private weak var frozenScrollView: UIScrollView?

        init(_ parent: SegmentGestureLayer) {
            self.parent = parent
        }

        /// Content-space chip under a point, inflating by half the inter-chip gaps
        /// so the space between chips still registers (Kayoko's tokenSpacing/2 and
        /// lineSpacing/2). When inflated rects overlap, the nearest chip centre
        /// wins — otherwise dictionary iteration order would make hit-testing
        /// non-deterministic at the seams.
        private func index(at point: CGPoint) -> Int? {
            var bestIndex: Int?
            var bestDistance = CGFloat.greatestFiniteMagnitude
            for (index, frame) in parent.frames {
                guard frame.insetBy(dx: -3, dy: -3).contains(point) else { continue }
                let dx = point.x - frame.midX
                let dy = point.y - frame.midY
                let distance = dx * dx + dy * dy
                if distance < bestDistance {
                    bestDistance = distance
                    bestIndex = index
                }
            }
            return bestIndex
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view else { return }
            if let index = index(at: gesture.location(in: view)) {
                parent.onTap(index)
            }
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view else { return }
            let point = gesture.location(in: view)
            switch gesture.state {
            case .began:
                guard let index = index(at: point) else {
                    unlockScrolling()
                    return
                }
                freezeScrolling()
                parent.onPanBegan(index)
            case .changed:
                if let index = index(at: point) {
                    parent.onPanChanged(index)
                }
            case .ended, .cancelled, .failed:
                unlockScrolling()
                parent.onPanEnded()
            default:
                break
            }
        }

        private func freezeScrolling() {
            guard frozenScrollView == nil, let scroll = hostView?.resolveScrollView() else { return }
            frozenScrollView = scroll
            scroll.isScrollEnabled = false
        }

        private func unlockScrolling() {
            frozenScrollView?.isScrollEnabled = true
            frozenScrollView = nil
        }

        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            guard let pan = gesture as? UIPanGestureRecognizer, let view = pan.view else {
                return true
            }
            // Mostly vertical → hand the gesture to the enclosing scroll view.
            // This is the single change that makes scrolling deterministic with
            // many words: a per-chip SwiftUI DragGesture could not decline like
            // this, so it used to swallow the scroll for some drag angles.
            let velocity = pan.velocity(in: view)
            if abs(velocity.y) > abs(velocity.x) * 1.5 { return false }
            // Only a drag that starts on a chip becomes a selection.
            if index(at: pan.location(in: view)) == nil { return false }
            return true
        }

        /// Don't let a stray recogniser cancel scrolling mid-flick.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            other is UIPanGestureRecognizer && other.view is UIScrollView
        }
    }
}
