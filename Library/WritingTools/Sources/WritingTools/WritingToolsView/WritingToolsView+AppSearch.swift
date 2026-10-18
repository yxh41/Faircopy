//
//  WritingToolsView+AppSearch.swift
//  WritingTools
//
//  Feature: jump straight into a target app's search with the segmented
//  keyword (Hammer It style). Each target carries a search URL scheme
//  template; `%@` is replaced with the keyword. Because the panel runs inside
//  arbitrary host apps, `canOpenURL` is useless (their Info.plist cannot
//  declare third-party schemes) — we simply call open(_:completionHandler:)
//  which needs no LSApplicationQueriesSchemes entry, and fall back to the
//  bare scheme if the search template fails. The keyword is also placed on
//  the clipboard before the jump so a stale scheme still ends in a
//  copy-paste, not a dead end.
//

import Foundation
import SwiftUI

/// One "search in app" destination. Codable so the settings pane
/// (`FaircopyRootView.providedAppSearchStore`) can persist a user-edited list
/// that the panel picks up on the next presentation.
struct AppSearchTarget: Identifiable, Codable {
    let id: String
    let name: String
    /// URL scheme template; `%@` becomes the percent-encoded keyword.
    let searchTemplate: String
    /// Scheme root to retry when the search template fails (app not installed
    /// under that scheme, or the template rotted away).
    let bareScheme: String

    /// Percent-encodes everything outside ASCII alphanumerics and the URL
    /// punctuation actually used by the templates. This intentionally encodes
    /// `{`, `}` and `"` (JD's JSON payload) plus spaces and all non-ASCII —
    /// the receiving apps decode query values themselves.
    private static let templateAllowed = CharacterSet.alphanumerics.union(
        CharacterSet(charactersIn: ":/?&=+;,!$'()*[]@~-._")
    )

    func searchURL(keyword: String) -> URL? {
        // Escape JSON metacharacters so templates that embed the keyword in a
        // JSON payload (JD) cannot be broken by a stray quote.
        let escaped = keyword
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let raw = searchTemplate.replacingOccurrences(of: "%@", with: escaped)
        guard
            let encoded = raw.addingPercentEncoding(withAllowedCharacters: Self.templateAllowed)
        else { return nil }
        return URL(string: encoded)
    }

    func bareURL() -> URL? {
        URL(string: bareScheme)
    }
}

extension AppSearchTarget {
    /// Scheme root (the part before `://` in the search template), used to look
    /// the target up in the installed-app map shared from AIGate.
    var schemeRoot: String? {
        guard let range = searchTemplate.range(of: "://") else { return nil }
        let head = String(searchTemplate[..<range.lowerBound])
        return head.isEmpty ? nil : head
    }
}

/// Built-in destinations, matching the reference list (Hammer It).
/// KEEP IN SYNC with `AppSearchStore.defaults` in
/// AIGate/AIGate/Editor/FaircopyRootView.swift — the two modules cannot share
/// a source file (the settings pane is compiled into the AIGate xcodeproj and
/// the FaircopyPrefs bundle, neither of which links the WritingTools
/// framework).
let kAppSearchDefaults: [AppSearchTarget] = [
    .init(id: "appstore", name: "AppStore",
          searchTemplate: "itms-apps://search.itunes.apple.com/WebObjects/MZSearch.woa/wa/search?term=%@",
          bareScheme: "itms-apps://"),
    // 3.0.24: the form that actually opens a result page is `search_result.html`
    // reached directly — neither `page.html` nor a `main_url`-wrapped payload
    // works. See 3.0.23, which guessed `page.html?main_url=…` and still failed.
    .init(id: "pdd", name: "拼多多",
          searchTemplate: "pinduoduo://com.xunmeng.pinduoduo/search_result.html?search_key=%@",
          bareScheme: "pinduoduo://"),
    .init(id: "taobao", name: "淘宝",
          searchTemplate: "taobao://s.taobao.com/?q=%@",
          bareScheme: "taobao://"),
    .init(id: "jd", name: "京东",
          searchTemplate: "openjd://virtual?params={\"des\":\"productList\",\"keyWord\":\"%@\",\"from\":\"search\",\"category\":\"jump\"}",
          bareScheme: "openjd://"),
    .init(id: "weibo", name: "Weibo",
          searchTemplate: "sinaweibo://searchall?q=%@",
          bareScheme: "sinaweibo://"),
    .init(id: "bilibili", name: "BiliBili",
          searchTemplate: "bilibili://search?keyword=%@",
          bareScheme: "bilibili://"),
    .init(id: "twitter", name: "Twitter",
          searchTemplate: "twitter://search?query=%@",
          bareScheme: "twitter://"),
    .init(id: "applemaps", name: "苹果地图",
          searchTemplate: "maps://?q=%@",
          bareScheme: "maps://"),
    .init(id: "baidumap", name: "百度地图",
          searchTemplate: "baidumap://map/place/search?query=%@&src=Faircopy",
          bareScheme: "baidumap://"),
    .init(id: "amap", name: "高德地图",
          searchTemplate: "iosamap://poi?sourceApplication=Faircopy&name=%@&dev=0",
          bareScheme: "iosamap://"),
    .init(id: "zhihu", name: "知乎",
          searchTemplate: "zhihu://search?q=%@",
          bareScheme: "zhihu://"),
    .init(id: "xhs", name: "小红书",
          searchTemplate: "xhsdiscover://search/result?keyword=%@",
          bareScheme: "xhsdiscover://"),
]

/// Panel-side reader for the user-edited destination list.
///
/// The list is written by the settings pane (FaircopyPrefs / AIGate) and read
/// here, inside whatever app the panel is presented in. That host app is
/// sandboxed and may be unable to read the shared preferences directory, so a
/// failed read is not an error: it simply falls back to the built-in defaults.
/// Read is done on each presentation so edits appear without a restart.
struct AppSearchStore {
    /// KEEP IN SYNC with `AppSearchStore.path` in FaircopyRootView.swift.
    static let path = "/var/mobile/Library/Preferences/wiki.qaq.ai.gate/faircopy_appsearch.json"

    static func load() -> [AppSearchTarget] {
        let list: [AppSearchTarget]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let decoded = try? JSONDecoder().decode([AppSearchTarget].self, from: data),
           !decoded.isEmpty {
            list = decoded
        } else {
            list = kAppSearchDefaults
        }
        // Hide built-in targets whose app isn't installed. The installed map is
        // produced by AIGate (the only process allowed to declare the schemes in
        // its Info.plist and call canOpenURL); a scheme absent from the map means
        // it's a user-added target we can't probe, so we keep showing it.
        let installed = AppSearchInstalledStore.load()
        let filtered: [AppSearchTarget]
        if installed.isEmpty {
            filtered = list
        } else {
            filtered = list.filter { target in
                guard let root = target.schemeRoot else { return true }
                if let known = installed[root] {
                    if !known { print("[Faircopy] app search: hiding uninstalled target \(root)") }
                    return known
                }
                return true
            }
        }
        // Surface recently used destinations first. Timestamps come from
        // AppSearchRecentsStore (written by this same process on every jump);
        // targets with no timestamp (never jumped) sink to the bottom in their
        // configured order.
        let recents = AppSearchRecentsStore.load()
        return filtered.sorted { (recents[$0.id] ?? 0) > (recents[$1.id] ?? 0) }
    }
}

/// Installed-app map shared from AIGate (which can call `canOpenURL` for the
/// built-in schemes it declares in Info.plist). Keyed by scheme root; `false`
/// means the target's app is not installed and should be hidden from the panel.
struct AppSearchInstalledStore {
    /// KEEP IN SYNC with the same path in FaircopyRootView.swift.
    static let path = "/var/mobile/Library/Preferences/wiki.qaq.ai.gate/faircopy_appsearch_installed.json"

    static func load() -> [String: Bool] {
        guard
            let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
            let map = try? JSONDecoder().decode([String: Bool].self, from: data)
        else { return [:] }
        return map
    }
}

/// Most-recently-used timestamps for the search targets, shared from the panel
/// (which is the process that actually performs jumps). Keyed by target `id`;
/// `AppSearchStore.load()` uses it to surface frequently jumped apps at the top.
/// Best-effort: writes may be blocked in a sandboxed host app, in which case the
/// file stays empty and the menu keeps its configured order.
struct AppSearchRecentsStore {
    /// KEEP IN SYNC with the same path in FaircopyRootView.swift.
    static let path = "/var/mobile/Library/Preferences/wiki.qaq.ai.gate/faircopy_appsearch_recents.json"

    static func load() -> [String: Double] {
        guard
            let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
            let map = try? JSONDecoder().decode([String: Double].self, from: data)
        else { return [:] }
        return map
    }

    static func touch(_ id: String) {
        var map = load()
        map[id] = Date().timeIntervalSince1970
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(map) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

/// Clipboard-protection toggle for the app-search jump. Persisted by the
/// settings pane (FaircopyPrefs / AIGate) in a sibling file the injected dylib
/// reads on every jump. Defaults to `true` (protect): the jump itself never
/// needs the clipboard — it is only a last-resort safety net used when both the
/// search scheme and the bare scheme fail to open the target app.
struct AppSearchSettings: Codable {
    var protectClipboard: Bool
}

struct AppSearchSettingsStore {
    /// KEEP IN SYNC with the same path in FaircopyRootView.swift.
    static let path = "/var/mobile/Library/Preferences/wiki.qaq.ai.gate/faircopy_appsearch_settings.json"

    static func load() -> AppSearchSettings {
        guard
            let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
            let s = try? JSONDecoder().decode(AppSearchSettings.self, from: data)
        else { return AppSearchSettings(protectClipboard: true) }
        return s
    }
}

private func appSearchContainsCJK(_ text: String) -> Bool {
    for scalar in text.unicodeScalars {
        let v = scalar.value
        if (0x4E00...0x9FFF).contains(v) || (0x3000...0x303F).contains(v) { return true }
    }
    return false
}

extension WritingToolsView {
    /// Keyword for the app search: the selected tokens rejoined the way a
    /// search box expects — no spaces inside CJK runs, single spaces between
    /// consecutive Latin words. Falls back to the full selected text when
    /// nothing is picked.
    var segmentSearchKeyword: String {
        let tokens = segmentSelectedTokens
        guard !tokens.isEmpty else { return context.textProxy.selectedText }
        var result = ""
        var previousText: String?
        for token in tokens {
            if let previousText,
               !appSearchContainsCJK(previousText), !appSearchContainsCJK(token.text) {
                result += " "
            }
            result += token.text
            previousText = token.text
        }
        return result
    }

    /// Full-width menu entry shown under the chips while a selection exists.
    /// A `Menu` gives the vertical destination list without adding layout
    /// pressure to the already-4-slot button row.
    @ViewBuilder
    var segmentAppSearchMenu: some View {
        Menu {
            Section("Search in Apps".localized) {
                ForEach(AppSearchStore.load()) { target in
                    Button(target.name) { openSegmentSearch(in: target) }
                }
            }
        } label: {
            RoundedRectangle(cornerRadius: 12)
                .foregroundStyle(.white)
                .opacity(0.1)
                .frame(height: 40)
                .overlay(
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                        Text("Search in Apps".localized)
                    }
                    .font(.system(.footnote))
                    .foregroundStyle(.white)
                )
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }

    /// Dismiss the panel, then hand the keyword to the target app. The delay
    /// lets the dismissal animation finish so the host app regains key window
    /// status before the URL open (opening mid-dismissal is racy on iOS 16).
    func openSegmentSearch(in target: AppSearchTarget) {
        let keyword = segmentSearchKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        guard let url = target.searchURL(keyword: keyword) else { return }
        let protect = AppSearchSettingsStore.load().protectClipboard
        SegmentHaptics.light.impactOccurred()
        // 默认保护剪贴板：正常跳转路径不写入；仅当两个 scheme 都失败时作为兜底
        // 写入关键词，方便用户手动粘贴完成搜索。关闭保护时沿用旧行为：跳转前先写入。
        if !protect {
            UIPasteboard.general.string = keyword
            print("[Faircopy] app search: clipboard copy (protection off)")
        }
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            UIApplication.shared.open(url) { success in
                guard !success else {
                    // 跳转成功（搜索模板命中）：记录最近使用，便于菜单把常用应用置顶
                    AppSearchRecentsStore.touch(target.id)
                    return
                }
                if let bare = target.bareURL() {
                    UIApplication.shared.open(bare) { bareSuccess in
                        if bareSuccess {
                            // 兜底 scheme 也成功：同样记为最近使用
                            AppSearchRecentsStore.touch(target.id)
                        } else if protect {
                            // 兜底：两个 scheme 都失败才写入，给用户最后手动粘贴的机会
                            UIPasteboard.general.string = keyword
                            print("[Faircopy] app search: jump failed, keyword left on clipboard")
                        } else {
                            print("[Faircopy] app search: bare scheme also failed (clipboard untouched)")
                        }
                    }
                } else if protect {
                    UIPasteboard.general.string = keyword
                    print("[Faircopy] app search: jump failed, keyword left on clipboard")
                }
            }
        }
    }
}
