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

/// One "search in app" destination.
struct AppSearchTarget: Identifiable {
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
let kAppSearchTargets: [AppSearchTarget] = [
    .init(id: "appstore", name: "AppStore",
          searchTemplate: "itms-apps://search.itunes.apple.com/WebObjects/MZSearch.woa/wa/search?term=%@",
          bareScheme: "itms-apps://"),
    .init(id: "pdd", name: "拼多多",
          searchTemplate: "pinduoduo://com.xunmeng.pinduoduo/page.html?search_key=%@",
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

private func appSearchContainsCJK(_ text: String) -> Bool {
    let set = CharacterSet(charactersIn: "\u{4E00}" ... "\u{9FFF}") // ideographs
        .union(CharacterSet(charactersIn: "\u{3000}" ... "\u{303F}")) // CJK punctuation
    return text.rangeOfCharacter(from: set) != nil
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
                ForEach(kAppSearchTargets) { target in
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
