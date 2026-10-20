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

    static func icon(_ id: String) -> String {
        switch id {
        case "proofread": return "doc.text.magnifyingglass"
        case "rewrite": return "arrow.counterclockwise"
        case "translate": return "character.book.closed"
        case "friendly": return "bubble.left.and.bubble.right"
        case "professional": return "books.vertical"
        case "concise": return "textformat.abc.dottedunderline"
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
