//
//  WritingToolsView+PanelModes.swift
//  WritingTools
//
//  Created for Faircopy 3.0.48 — user-configurable panel modes.
//

import Foundation
import SwiftUI

/// Ordered list of enabled writing modes, shared from the settings pane.
///
/// Same failure semantics as `AppSearchStore`: the panel runs inside an
/// arbitrary, sandboxed host app that may be unable to read the shared
/// directory, so a failed read falls back to every mode enabled in its
/// built-in order. Read on each presentation so edits land without a restart.
enum FaircopyPanelModesStore {
    /// KEEP IN SYNC with `FaircopyPanelModesStore.path` in FaircopyRootView.swift.
    static let path = "/var/mobile/Library/Preferences/wiki.qaq.ai.gate/faircopy_panel_modes.json"

    /// Built-in visual order, matching the original hardcoded panel rows:
    /// Proofread / Rewrite / Translate, Friendly / Professional / Concise,
    /// Expand / Summarize / Segment. Values are `Prompt.rawValue`.
    static let defaults: [String] = [
        "proofread", "rewrite", "translate",
        "friendly", "professional", "concise",
        "expand", "summarize", "segment",
    ]

    static func load() -> [String] {
        guard
            let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
            let list = try? JSONDecoder().decode([String].self, from: data)
        else { return defaults }
        // Drop ids we don't recognise (e.g. written by a newer version) rather
        // than trying to build a button for them.
        return list.filter { defaults.contains($0) }
    }
}

/// Per-mode presentation bits that used to be hardcoded in
/// `selectiveButtonPanels`. Keyed by `Prompt.rawValue` so the settings pane can
/// ship an arbitrary order without knowing anything about titles or icons.
enum FaircopyPanelMode {
    static func title(_ id: String) -> String {
        switch id {
        case "proofread": return "Proofread".localized
        case "rewrite": return "Rewrite".localized
        case "translate": return "Translate".localized
        case "friendly": return "Friendly".localized
        case "professional": return "Professional".localized
        case "concise": return "Concise".localized
        case "expand": return "Expand".localized
        case "summarize": return "Summarize".localized
        case "segment": return "Segment".localized
        default: return id.localized
        }
    }

    /// KEEP IN SYNC with `FaircopyPanelModesStore.iconName` in FaircopyRootView.
    /// Sticks to symbols that exist from iOS 13/14 on: `Image(systemName:)` for a
    /// name the system does not know renders nothing, and the button then shows
    /// its title with no icon at all (proofread and concise used to hit this).
    static func icon(_ id: String) -> String {
        switch id {
        case "proofread": return "text.badge.checkmark"
        case "rewrite": return "arrow.counterclockwise"
        case "translate": return "character.book.closed"
        case "friendly": return "bubble.left.and.bubble.right"
        case "professional": return "books.vertical"
        case "concise": return "arrow.down.right.and.arrow.up.left"
        case "expand": return "arrow.up.left.and.arrow.down.right"
        case "summarize": return "list.bullet.below.rectangle"
        case "segment": return "scissors"
        default: return "sparkles"
        }
    }

    static func prompt(_ id: String) -> Prompt? {
        Prompt(rawValue: id)
    }
}

/// A parameterized sub-action exposed by long-pressing a panel mode.
///
/// Variants are pure dylib-side data: each carries a short instruction fragment
/// that is appended to the mode's base system prompt (and, optionally, a
/// temperature override or a translate target). Because the dylib assembles the
/// full system prompt before relaying to AIGate, no gateway or `Prompt` enum
/// change is required — see `WritingToolsView.executeCurrentTask`.
///
/// `segment` (提问) is special: its variants are not model runs but ask-presets.
/// When `askPrefill` is set, selecting the variant drives `presentSegmentAsk`
/// instead of `executeCurrentTask`, optionally with web access consented.
struct FaircopyPanelVariant: Identifiable, Hashable {
    let id: String
    /// Localized title shown in the long-press menu.
    let title: String
    /// SF Symbol name. Must be one known from iOS 13/14 on — `Image(systemName:)`
    /// for an unknown name renders nothing (see `FaircopyPanelMode.icon`).
    let icon: String
    /// Instruction fragment appended after the mode's base prompt. Empty for
    /// variants that only change `temperature` / `translateTarget` / `askPrefill`.
    let modifier: String
    /// When set, overrides `Prompt.sampling(for:)` temperature for this run.
    let temperature: Double?
    /// When set, preselects the translate target before running (translate mode).
    let translateTarget: String?
    /// When set, this variant drives the 提问 flow with a pre-filled question
    /// instead of a plain model run. An empty string opens the ask with an empty
    /// field (used by the 联网追问 preset, which only sets `askWeb`).
    let askPrefill: String?
    /// When `askPrefill` is set, consents to web access for the ask session.
    let askWeb: Bool

    init(
        id: String,
        title: String,
        icon: String,
        modifier: String = "",
        temperature: Double? = nil,
        translateTarget: String? = nil,
        askPrefill: String? = nil,
        askWeb: Bool = false
    ) {
        self.id = id
        self.title = title
        self.icon = icon
        self.modifier = modifier
        self.temperature = temperature
        self.translateTarget = translateTarget
        self.askPrefill = askPrefill
        self.askWeb = askWeb
    }

    /// Variant sub-menus per mode, keyed by `Prompt.rawValue`. Every id here must
    /// also exist in `FaircopyPanelModesStore.defaults` or it is unreachable.
    /// Keep symbols iOS 13/14-safe (see `FaircopyPanelMode.icon` rule).
    static let registry: [String: [FaircopyPanelVariant]] = [
        "proofread": [
            .init(id: "strict", title: "严格模式", icon: "checkmark.shield",
                  modifier: "Apply a stricter pass: also improve word choice, phrasing, and clarity, not just correctness. Keep meaning and tone unchanged."),
            .init(id: "grammar", title: "仅语法", icon: "text.badge.checkmark",
                  modifier: "Fix only spelling, grammar, and punctuation. Do not change wording, tone, or structure at all."),
            .init(id: "terminology", title: "统一术语", icon: "abc",
                  modifier: "Unify terminology: choose one consistent term per concept and use it throughout the text."),
        ],
        "rewrite": [
            .init(id: "casual", title: "更口语", icon: "face.smiling",
                  modifier: "Rewrite in a relaxed, conversational tone while keeping all meaning."),
            .init(id: "literary", title: "更书面", icon: "books.vertical",
                  modifier: "Rewrite with richer vocabulary and a more polished, literary register."),
            .init(id: "alternative", title: "换种说法", icon: "arrow.2.squarepath",
                  modifier: "Express the same meaning with completely different wording and sentence structure."),
            .init(id: "structure", title: "保留结构", icon: "list.bullet",
                  modifier: "Keep the original sentence structure and order; only refine wording."),
        ],
        "translate": [
            .init(id: "zh", title: "→ 中文", icon: "globe", translateTarget: "Chinese"),
            .init(id: "en", title: "→ 英文", icon: "globe", translateTarget: "English"),
            .init(id: "ja", title: "→ 日文", icon: "globe", translateTarget: "Japanese"),
        ],
        "friendly": [
            .init(id: "warmer", title: "更温暖", icon: "flame",
                  modifier: "Sound especially warm and approachable, while staying faithful to the original."),
            .init(id: "humor", title: "带点幽默", icon: "heart",
                  modifier: "Add mild, tasteful humor where it fits; keep it concise and faithful."),
        ],
        "professional": [
            .init(id: "email", title: "写成邮件", icon: "envelope",
                  modifier: "Format the result as a clear, professional email or message."),
            .init(id: "academic", title: "学术口吻", icon: "graduationcap",
                  modifier: "Use a neutral, academic register appropriate for formal writing."),
        ],
        "concise": [
            .init(id: "ultra", title: "极简", icon: "minus.circle",
                  modifier: "Make it as short as possible: keep only the essential information, drop everything else."),
            .init(id: "bullets", title: "列要点", icon: "list.bullet",
                  modifier: "If the content can be a list, return it as a compact bullet list; otherwise keep it tight."),
        ],
        "expand": [
            .init(id: "examples", title: "加例子", icon: "lightbulb",
                  modifier: "Add a concrete example or two to clarify the point."),
            .init(id: "structure", title: "加结构", icon: "rectangle.grid.2x2",
                  modifier: "Add clear structure (headings or a short outline) to organize the content."),
        ],
        "summarize": [
            .init(id: "oneliner", title: "一句话", icon: "text.alignleft",
                  modifier: "Summarize in a single, concise sentence."),
            .init(id: "points", title: "三个要点", icon: "list.number",
                  modifier: "Summarize as three short key points."),
            .init(id: "outline", title: "详细大纲", icon: "list.bullet.below.rectangle",
                  modifier: "Summarize as a detailed outline with the main points and sub-points."),
        ],
        "segment": [
            .init(id: "web", title: "联网追问", icon: "globe", askPrefill: "", askWeb: true),
            .init(id: "explain", title: "解释", icon: "lightbulb", askPrefill: "请解释这段文字的意思"),
            .init(id: "points", title: "列要点", icon: "list.number", askPrefill: "请列出这段内容的要点"),
            .init(id: "translate", title: "翻译这段", icon: "character.book.closed", askPrefill: "请把这段翻译成中文"),
        ],
    ]
}
