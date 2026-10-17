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
    // 3.0.23: Pinduoduo's `page.html` only renders a `main_url` payload — the
    // bare `?search_key=` form loaded no result page. The inner search URL is
    // already percent-encoded here so the outer encoding pass leaves it intact.
    .init(id: "pdd", name: "拼多多",
          searchTemplate: "pinduoduo://com.xunmeng.pinduoduo/page.html?main_url=https%3A%2F%2Fmobile.yangkeduo.com%2Fsearch_result.html%3Fsearch_key%3D%@",
          bareScheme: "pinduoduo://"),
    .init(id: "taobao", name: "淘宝",
          searchTemplate: "taobao://s.taobao.com/?q=%@",
          bareScheme: "taobao://"),
    .init(id: "jd", name: "京东",
          searchTemplate: "openapp.jdmobile://virtual?params={\"category\":\"jump\",\"des\":\"search\",\"keyword\":\"%@\",\"from\":\"faircopy\"}",
          bareScheme: "openapp.jdmobile://"),
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
        guard
            let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
            let list = try? JSONDecoder().decode([AppSearchTarget].self, from: data),
            !list.isEmpty
        else { return kAppSearchDefaults }
        return list
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
        // Keyword always rides the clipboard: if the search scheme rots, the
        // bare-scheme fallback still lands in the app and one paste completes
        // the flow instead of a dead end.
        UIPasteboard.general.string = keyword
        SegmentHaptics.light.impactOccurred()
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            UIApplication.shared.open(url) { success in
                if success { return }
                print("[Faircopy] app search scheme failed: \(url.absoluteString), retrying bare scheme")
                if let bare = target.bareURL() {
                    UIApplication.shared.open(bare) { _ in }
                }
            }
        }
    }
}
