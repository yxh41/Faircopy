//
//  WritingToolsView+Compare.swift
//  WritingTools
//
//  3.0.129: 原文对照 (bilingual comparison).
//
//  After a translation finishes the answer alone loses the words it started
//  from, and the collapsible "原文" card (3.0.107) only ever stacked the source
//  above the answer — never the two beside each other. This view pairs each
//  original sentence with its translation so the reader can check line by line
//  which source line produced which output line.
//
//  Alignment is index-based: both sides are split into sentences and matched by
//  position. Free-form translation may merge or split sentences, so a count
//  mismatch simply leaves the unmatched half as an orphan line at the end —
//  still a faithful comparison, just not a perfect 1:1 lattice.

import SwiftUI

/// Whether the translate result is shown as a paired 原文/译文 comparison.
enum CompareMode {
    case off
    case on

    static let defaultsKey = "faircopy.translate.compare"

    /// Remembered per host app, like SegmentCopyOrder, so the toggle stays put
    /// across panel re-opens and launches.
    static var remembered: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }
}

extension WritingToolsView {
    /// Toggle pill shown under the language chips in Translate mode. Flips the
    /// comparison on/off and persists the choice.
    @ViewBuilder
    var compareToggle: some View {
        Button {
            compareMode.toggle()
            CompareMode.remembered = compareMode
            // Long enough to survive Swift's small-literal inlining so the
            // release check can prove this shipped.
            NSLog("[Faircopy] compare mode toggled, on=\(compareMode) src=\(sourceSubject.count) out=\(output.count)")
        } label: {
            HStack(spacing: 4) {
                Image(systemName: compareMode ? "rectangle.split.2x2.fill" : "rectangle.split.2x2")
                Text(compareMode ? "Compare: On".localized : "Compare: Off".localized)
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(compareMode ? Color.black : Color.white.opacity(0.9))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(compareMode ? Color.white : Color.white.opacity(0.14)))
        }
        .buttonStyle(.plain)
        .disabled(output.isEmpty)
        .opacity(output.isEmpty ? 0.4 : 1)
    }

    /// True when the comparison should replace the plain answer: Translate mode,
    /// toggle on, both texts present, and the stream has settled (aligning a
    /// half-written answer is meaningless).
    var showsBilingualComparison: Bool {
        guard taskPrompt == .translate,
              compareMode,
              !isRunning,
              !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !sourceSubject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        return true
    }

    var bilingualComparison: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                let pairs = Self.alignBilingual(source: sourceSubject, translation: output)
                ForEach(Array(pairs.enumerated()), id: \.offset) { index, pair in
                    VStack(alignment: .leading, spacing: 4) {
                        if let original = pair.original {
                            comparisonLine(label: "Source".localized, text: original, emphasized: false)
                        }
                        if let translation = pair.translation {
                            comparisonLine(label: "Translation".localized, text: translation, emphasized: true)
                        }
                    }
                    if index < pairs.count - 1 {
                        Divider().opacity(0.12)
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    /// One labelled line of the comparison: a muted caption (原文 / 译文)
    /// followed by the text. The translation reads brighter than the source so
    /// the eye lands on the answer first and the source second.
    private func comparisonLine(label: String, text: String, emphasized: Bool) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
                .frame(minWidth: 28, alignment: .leading)
            Text(text)
                .font(emphasized ? .system(.footnote) : .system(size: 12))
                .foregroundStyle(emphasized ? .white : .white.opacity(0.62))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Sentence alignment

    private struct AlignedPair {
        let original: String?
        let translation: String?
    }

    /// Splits text into non-empty, trimmed sentences. Mirrors the sentence walk
    /// the word segmenter uses (enumerateSubstrings bySentences), which keeps
    /// CJK punctuation attached to its sentence.
    private static func splitSentences(_ text: String) -> [String] {
        let ns = text as NSString
        guard ns.length > 0 else { return [] }
        var out: [String] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .bySentences) { piece, _, _, _ in
            guard let piece, !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            out.append(piece.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return out
    }

    /// Pairs source sentences with translation sentences by index. When counts
    /// differ, the overflow on either side becomes orphan lines (rendered with
    /// only their own caption) rather than being dropped.
    private static func alignBilingual(source: String, translation: String) -> [AlignedPair] {
        let src = splitSentences(source)
        let dst = splitSentences(translation)
        let count = max(src.count, dst.count)
        guard count > 0 else { return [] }
        var pairs: [AlignedPair] = []
        for i in 0 ..< count {
            pairs.append(AlignedPair(
                original: i < src.count ? src[i] : nil,
                translation: i < dst.count ? dst[i] : nil
            ))
        }
        return pairs
    }
}
