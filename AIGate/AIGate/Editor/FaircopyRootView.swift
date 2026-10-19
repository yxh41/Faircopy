//
//  FaircopyRootView.swift
//  AIGate
//
//  Created by 秋星桥 on 2024/8/15.
//

import Combine
import MessageUI
import QuickLook
import SwiftUI
import SwiftUIIntrospect

enum ServiceStatus: Equatable {
    case unknown
    case connected
    case waitForActivation(failedTimes: Int)
    case disconnected(error: Error?)

    static func == (lhs: ServiceStatus, rhs: ServiceStatus) -> Bool {
        switch (lhs, rhs) {
        case (.unknown, .unknown):
            true
        case (.connected, .connected):
            true
        case let (.waitForActivation(l), .waitForActivation(r)):
            l == r
        case (.disconnected(_), .disconnected(_)):
            true
        default:
            false
        }
    }
}

/// Darwin notification other tweaks post to summon the writing panel.
/// Keep in sync with kFCExternalPresentNotification in
/// Library/WritingTools/Sources/WritingToolsInjector.h.
let kFCExternalPresentNotificationName = "wiki.qaq.faircopy.present"

/// URL scheme handled by AIGate (bounces back to the caller, then posts the
/// notification above). Keep in sync with SceneDelegate.handleOpenURL.
let kFCExternalPanelURLScheme = "faircopy://panel"

struct FaircopyRootView: View {
    @StateObject var appViewModel = FaircopyAppModel.shared
    @StateObject var configuration = Configuration.shared
    @StateObject var configurationViewModel = Configuration.shared.viewModel

    @State var mailResult: Result<MFMailComposeResult, Error>? = nil
    @State var isShowingMailView = false

    @State var openAddSheet = false
    @State var quickLookExport: URL?
    @State var copiedInvocationID: String?

    // Search-in-app destinations (分词 → 在应用中搜索). The list lives in a
    // shared preferences file the injected dylib also reads; see AppSearchStore.
    @State var appSearchEntries: [AppSearchEntry] = AppSearchStore.load()
    @State var appSearchEditing: AppSearchEntry? = nil
    @State var isAppSearchEditing = false
    /// Clipboard-protection toggle for the app-search jump. Persisted to a
    /// sibling shared file the injected dylib reads; see AppSearchSettingsStore.
    @State var protectClipboard: Bool = AppSearchSettingsStore.load().protectClipboard

    @State var serviceStatus: ServiceStatus = .unknown
    @State var usageStats: UsageStats?

    let timer = Timer
        .publish(every: 5, on: .main, in: .common)
        .autoconnect()

    var bundleDisplayName: String {
        let localizedName = NSLocalizedString("Faircopy", bundle: Bundle.wrti_support, comment: "")
        if localizedName == "Faircopy" {
            return "Faircopy"
        } else {
            return "\(localizedName) Faircopy"
        }
    }

    var bundleShortVersionString: String {
        Bundle.wrti_packageVersion
    }

    let scrollViewSubject: CurrentValueSubject<UIScrollView?, Never>?

    init(scrollViewSubject: CurrentValueSubject<UIScrollView?, Never>? = nil) {
        self.scrollViewSubject = scrollViewSubject
        _ = GateSessionDelegate()
    }

    var body: some View {
        majorContent
            .onAppear {
                checkStatus()
                fetchUsage()
            }
            .onReceive(timer) { _ in
                checkStatus()
                fetchUsage()
            }
            .toolbar {
                ToolbarItem {
                    NavigationLink {
                        TestTextView()
                    } label: {
                        Image(systemName: "character.cursor.ibeam")
                    }
                }
            }
            .tint(.accent)
            .transition(.opacity)
            .quickLookPreview($quickLookExport)
            .sheet(isPresented: $isShowingMailView) { mailLink }
        #if targetEnvironment(macCatalyst)
            .navigationBarHidden(true)
        #else
            .navigationTitle(appViewModel.isLiteEdition
                ? NSLocalizedString("Faircopy Lite", bundle: Bundle.wrti_support, comment: "")
                : NSLocalizedString("Faircopy", bundle: Bundle.wrti_support, comment: ""))
        #endif
    }

    var majorContent: some View {
        Form {
            if appViewModel.isLiteEdition { LiteEditionBannerHeader() }

            enableServiceSection
            endpointListSection
            builtInEndpointSection
            customPromptsSection
            appSearchSection
            usageSection

            if appViewModel.isLiteEdition { supportTweakSection }

            externalInvocationSection

            footerSection

            if appViewModel.isLiteEdition { LiteEditionBannerFooter() }
        }
        .listStyle(.insetGrouped)
        .introspect(.list, on: .iOS(.v13, .v14, .v15)) {
            scrollViewSubject?.send($0)
        }
        .introspect(.list, on: .iOS(.v16, .v17, .v18)) {
            scrollViewSubject?.send($0)
        }
    }

    var enableServiceSection: some View {
        Section {
            Toggle(isOn: .init(get: {
                configuration.isEnabled
            }, set: { newValue in
                configuration.isEnabled = newValue
            })) {
                Text(NSLocalizedString("Enable Service", bundle: Bundle.wrti_support, comment: ""))
            }
        } header: {
            Text(NSLocalizedString("Service", bundle: Bundle.wrti_support, comment: ""))
        } footer: {
            if case let .waitForActivation(failedTimes) = serviceStatus {
                Text(String(format: NSLocalizedString("Waiting for activation… %d/5", bundle: Bundle.wrti_support, comment: ""), failedTimes))
                    .foregroundStyle(Color.accent)
                    .transition(.opacity)
            } else if case let .disconnected(error) = serviceStatus, let error {
                Text(error.localizedDescription)
                    .foregroundStyle(.red)
                    .transition(.opacity)
            } else {
                Text(NSLocalizedString("Your configuration will be stored securely and will not be accessible to apps. This service will delegate your request from tweaks to server and sending response back to them.", bundle: Bundle.wrti_support, comment: ""))
                    .transition(.opacity)
            }
        }
        .animation(.smooth, value: serviceStatus)
    }

    var endpointListSection: some View {
        Section {
            ForEach(configurationViewModel.uiEndpoints, id: \.id) { value in
                EndpointButton(endpoint: value)
            }
            Button {
                openAddSheet = true
            } label: {
                Text(NSLocalizedString("Add Endpoint", bundle: Bundle.wrti_support, comment: ""))
            }
            .foregroundStyle(Color.accent)
            .sheet(isPresented: $openAddSheet) {
                NavigationView {
                    AddEndpointView()
                        .navigationBarTitleDisplayMode(.inline)
                }
                .navigationViewStyle(.stack)
            }
        } header: {
            Text(NSLocalizedString("Endpoints", bundle: Bundle.wrti_support, comment: ""))
        } footer: {
            Text(NSLocalizedString("Tap to activate your endpoint. Long press for a menu.", bundle: Bundle.wrti_support, comment: ""))
        }
        .animation(.smooth, value: configurationViewModel.uiEndpoints)
        .onAppear {
            configuration.reloadViewModel()
        }
    }

    var builtInEndpointSection: some View {
        Section {
            if configurationViewModel.uiActivatedEndpointIsLimited {
                HStack(spacing: 16) {
                    Text(NSLocalizedString("Built-in Endpoint Activated", bundle: Bundle.wrti_support, comment: ""))
                    Spacer()
                    Image(systemName: "checkmark")
                }
                .foregroundStyle(Color.accent)
                .transition(.opacity)
            } else {
                Button(NSLocalizedString("Use Built-in Endpoint", bundle: Bundle.wrti_support, comment: "")) {
                    configuration.activateLimited()
                }
                .transition(.opacity)
            }
        } header: {
            Text(NSLocalizedString("Built-in Endpoint", bundle: Bundle.wrti_support, comment: ""))
        } footer: {
            Text(NSLocalizedString("The built-in endpoint is a limited service provided by the tweak. It is free to use and no need to configure. Your request will be logged and stored on our server. Currently we do not offer a way to delete it.", bundle: Bundle.wrti_support, comment: ""))
        }
        .disabled(true)
        .animation(.smooth, value: configurationViewModel.uiActivatedEndpointIsLimited)
    }

    var customPromptsSection: some View {
        Section {
            NavigationLink {
                CustomPromptsView()
            } label: {
                HStack {
                    Text(NSLocalizedString("Custom Prompts", bundle: Bundle.wrti_support, comment: ""))
                    Spacer()
                    Text("\(configurationViewModel.uiCustomPrompts.count)")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(NSLocalizedString("Writing", bundle: Bundle.wrti_support, comment: ""))
        } footer: {
            Text(NSLocalizedString(
                "User-defined prompts shown next to the built-in modes in the writing panel.",
                bundle: Bundle.wrti_support,
                comment: ""
            ))
        }
    }

    var externalInvocationSection: some View {
        Section {
            invocationCopyRow(
                id: "url",
                title: NSLocalizedString("URL Scheme", bundle: Bundle.wrti_support, comment: ""),
                value: kFCExternalPanelURLScheme,
                extraActions: [
                    InvocationExtraAction(title: NSLocalizedString("Open", bundle: Bundle.wrti_support, comment: "")) {
                        if let url = URL(string: kFCExternalPanelURLScheme) {
                            UIApplication.shared.open(url)
                        }
                    }
                ]
            )
            invocationCopyRow(
                id: "notification",
                title: NSLocalizedString("Darwin Notification", bundle: Bundle.wrti_support, comment: ""),
                value: kFCExternalPresentNotificationName,
                extraActions: [
                    InvocationExtraAction(title: NSLocalizedString("Copy Invocation Code", bundle: Bundle.wrti_support, comment: "")) {
                        UIPasteboard.general.string = "notify_post(\"\(kFCExternalPresentNotificationName)\")"
                    }
                ]
            )
        } header: {
            Text(NSLocalizedString("External Invocation", bundle: Bundle.wrti_support, comment: ""))
        } footer: {
            Text(NSLocalizedString("External Invocation Footer", bundle: Bundle.wrti_support, comment: ""))
        }
        .animation(.smooth, value: copiedInvocationID)
    }

    private struct InvocationExtraAction: Identifiable {
        let id = UUID()
        let title: String
        let perform: () -> Void
    }

    private func flashCopied(_ id: String) {
        copiedInvocationID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copiedInvocationID == id { copiedInvocationID = nil }
        }
    }

    private func invocationCopyRow(
        id: String,
        title: String,
        value: String,
        extraActions: [InvocationExtraAction] = []
    ) -> some View {
        Button {
            UIPasteboard.general.string = value
            flashCopied(id)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(value)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if copiedInvocationID == id {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accent)
                        .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            ForEach(extraActions) { action in
                Button(action.title) { action.perform() }
            }
        }
    }

    var usageSection: some View {
        Section {
            if let usageStats {
                labeledUsageRow(title: NSLocalizedString("Prompt Tokens", bundle: Bundle.wrti_support, comment: ""), value: usageStats.promptTokens)
                labeledUsageRow(title: NSLocalizedString("Completion Tokens", bundle: Bundle.wrti_support, comment: ""), value: usageStats.completionTokens)
                labeledUsageRow(title: NSLocalizedString("Requests", bundle: Bundle.wrti_support, comment: ""), value: usageStats.requestCount)
                Button(NSLocalizedString("Reset Statistics", bundle: Bundle.wrti_support, comment: "")) {
                    AIGateClient.executeCommand(.usageReset) { _, _ in
                        DispatchQueue.main.async { self.usageStats = UsageStats.empty }
                    }
                }
                .foregroundStyle(.red)
            } else {
                Text(NSLocalizedString("No usage recorded yet.", bundle: Bundle.wrti_support, comment: ""))
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(NSLocalizedString("Usage", bundle: Bundle.wrti_support, comment: ""))
        } footer: {
            Text(NSLocalizedString(
                "Token usage as reported by your endpoint. Counts accumulate across all apps using the writing tools.",
                bundle: Bundle.wrti_support,
                comment: ""
            ))
        }
    }

    private func labeledUsageRow(title: String, value: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(value)")
                .foregroundStyle(.secondary)
        }
    }

    func fetchUsage() {
        AIGateClient.fetchUsage { stats in
            DispatchQueue.main.async {
                usageStats = stats
            }
        }
    }

    var supportTweakSection: some View {
        Section {
            if let tweakURL = appViewModel.tweakURL {
                if #available(iOS 16, *) {
                    ShareLink(
                        item: tweakURL,
                        subject: Text(NSLocalizedString("Export Support Tweak", bundle: Bundle.wrti_support, comment: ""))
                    )
                } else {
                    Button(NSLocalizedString("Export Support Tweak", bundle: Bundle.wrti_support, comment: "")) {
                        quickLookExport = tweakURL
                    }
                }
            } else {
                Text(NSLocalizedString("Unable to locate tweak support", bundle: Bundle.wrti_support, comment: ""))
            }
        } header: {
            Text(NSLocalizedString("Application Supports", bundle: Bundle.wrti_support, comment: ""))
        } footer: {
            Text(String(format: NSLocalizedString("The support tweak is required to enable “%@” shortcut in editing menus. You can inject it into other applications via TrollFools or similar technologies.", bundle: Bundle.wrti_support, comment: ""), NSLocalizedString("Faircopy", bundle: Bundle.wrti_support, comment: "")))
        }
    }

    var footerSection: some View {
        Section {
            NavigationLink(destination: TestTextView()) {
                Text(NSLocalizedString("Test Text Editor", bundle: Bundle.wrti_support, comment: ""))
            }
            if MFMailComposeViewController.canSendMail(), !appViewModel.isLiteEdition {
                Button(NSLocalizedString("Test Mail Composer", bundle: Bundle.wrti_support, comment: "")) {
                    isShowingMailView.toggle()
                }
            }
        } footer: {
            Text(String(format: NSLocalizedString("%@ v%@ by OwnGoal Studio", bundle: Bundle.wrti_support, comment: ""), bundleDisplayName, bundleShortVersionString))
        }
    }

    var liteEditionBannerHeader: some View {
        LiteEditionBannerHeader()
    }

    var mailLink: some View {
        MailView(result: $mailResult) { composer in
            composer.setToRecipients(["82flex@gmail.com"])

            if FaircopyAppModel.shared.isLiteEdition {
                composer.setSubject("[Feedback] Faircopy Lite v\(Bundle.wrti_packageVersion)")
            } else {
                composer.setSubject("[Feedback] Faircopy v\(Bundle.wrti_packageVersion)")
            }

            composer.setMessageBody("""
            <h2>Feature Request</h2>

            <b>Is your feature request related to a problem? Please describe.</b><br>
            A clear and concise description of what the problem is. Ex. I’m always frustrated when <i>[...]</i><br>
            <br>
            <b>Describe the solution you’d like</b><br>
            A clear and concise description of what you want to happen.<br>
            <br>
            <b>Describe alternatives you’ve considered</b><br>
            A clear and concise description of any alternative solutions or features you’ve considered.<br>
            <br>
            <b>Additional context</b><br>
            Add any other context or screenshots about the feature request here.<br>
            <br>
            <hr>

            <h2>Bug Report</h2>

            <b>Describe the bug</b><br>
            A clear and concise description of what the bug is.<br>
            <br>
            <b>To Reproduce</b><br>
            Steps to reproduce the behavior:<br>
            1. Go to…<br>
            2. Click on…<br>
            3. Scroll down to…<br>
            4. See error<br>
            <br>
            <b>Expected behavior</b><br>
            A clear and concise description of what you expected to happen.<br>
            <br>
            <b>Screenshots</b><br>
            If applicable, add screenshots to help explain your problem.<br>
            <br>
            <b>Please complete the following information:</b><br>
             - OS: iOS \(ProcessInfo.processInfo.operatingSystemVersionString)<br>
             - Version \(Bundle.wrti_packageVersion)<br>
             - Locale: \(Locale.current.identifier)<br>
             - Timezone: \(TimeZone.current.identifier)<br>
            <br>
            <b>Additional context</b><br>
            Add any other context about the problem here.<br>
            """, isHTML: true)
        }
    }

    /// 分词 →「在应用中搜索」destination list. Read from the shared preferences
    /// file on appear so edits made elsewhere (or a reset) are reflected, and
    /// written back after every change so the injected dylib picks them up the
    /// next time the panel is summoned.
    var appSearchSection: some View {
        Section {
            Toggle(isOn: $protectClipboard) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(NSLocalizedString("Clipboard Protection", bundle: Bundle.wrti_support, comment: ""))
                    Text(NSLocalizedString("Keeps the app search jump from overwriting your clipboard unless both schemes fail.", bundle: Bundle.wrti_support, comment: ""))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: protectClipboard) { newValue in
                AppSearchSettingsStore.save(AppSearchSettings(protectClipboard: newValue))
            }
            ForEach($appSearchEntries) { $entry in
                Button {
                    appSearchEditing = entry
                    isAppSearchEditing = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(Color.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name.isEmpty ? NSLocalizedString("Untitled", bundle: Bundle.wrti_support, comment: "") : entry.name)
                            Text(entry.searchTemplate)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .foregroundStyle(.primary)
            }
            .onDelete { indexSet in
                appSearchEntries.remove(atOffsets: indexSet)
                AppSearchStore.save(appSearchEntries)
            }
            .onMove { from, to in
                appSearchEntries.move(fromOffsets: from, toOffset: to)
                AppSearchStore.save(appSearchEntries)
            }
            Button {
                let fresh = AppSearchEntry(id: UUID().uuidString, name: "",
                                           searchTemplate: "", bareScheme: "")
                appSearchEntries.append(fresh)
                appSearchEditing = fresh
                isAppSearchEditing = true
            } label: {
                Text(NSLocalizedString("Add App", bundle: Bundle.wrti_support, comment: ""))
            }
            .foregroundStyle(Color.accent)
            Button {
                appSearchEntries = AppSearchStore.defaults
                AppSearchStore.save(appSearchEntries)
            } label: {
                Text(NSLocalizedString("Restore Defaults", bundle: Bundle.wrti_support, comment: ""))
            }
            Button {
                detectInstalledApps()
            } label: {
                Text(NSLocalizedString("Redetect Installed Apps", bundle: Bundle.wrti_support, comment: ""))
            }
            .foregroundStyle(Color.accent)
        } header: {
            Text(NSLocalizedString("Search in Apps", bundle: Bundle.wrti_support, comment: ""))
        } footer: {
            Text(NSLocalizedString("Apps shown when you pick words in 分词 and choose 在应用中搜索. Use %@ in the search template where the keyword goes.", bundle: Bundle.wrti_support, comment: ""))
        }
        .onAppear {
            appSearchEntries = AppSearchStore.load()
            protectClipboard = AppSearchSettingsStore.load().protectClipboard
            detectInstalledApps()
        }
        .sheet(isPresented: $isAppSearchEditing, onDismiss: {
            AppSearchStore.save(appSearchEntries)
        }) {
            NavigationView {
                AppSearchEditorView(entry: $appSearchEditing) { edited in
                    if let index = appSearchEntries.firstIndex(where: { $0.id == edited.id }) {
                        appSearchEntries[index] = edited
                    }
                    if edited.name.isEmpty && edited.searchTemplate.isEmpty {
                        // Discard an entry the user opened but never filled in.
                        appSearchEntries.removeAll { $0.id == edited.id }
                    }
                    AppSearchStore.save(appSearchEntries)
                }
                .navigationBarTitleDisplayMode(.inline)
            }
            .navigationViewStyle(.stack)
        }
    }

    /// Probes which built-in search targets are installed by querying
    /// `canOpenURL` for each built-in scheme (AIGate declares them in Info.plist
    /// via LSApplicationQueriesSchemes). The map is written to a shared file the
    /// injected dylib reads, so it can hide targets whose app isn't installed.
    /// User-added targets use arbitrary schemes we can't declare, so they are
    /// never probed and always shown.
    func detectInstalledApps() {
        var installed: [String: Bool] = [:]
        for target in AppSearchStore.defaults {
            guard let root = target.schemeRoot else { continue }
            guard installed[root] == nil else { continue }
            let url = URL(string: "\(root)://") ?? URL(string: "https://")!
            installed[root] = UIApplication.shared.canOpenURL(url)
        }
        AppSearchInstalledStore.save(installed)
        let count = installed.filter { $0.value }.count
        print("[Faircopy] app search: detected \(count) installed apps")
        appSearchEntries = AppSearchStore.load()
    }

    func checkStatus() {
        spawnService()
        AIGateClient.executeCommand(.ping) { _, error in
            DispatchQueue.main.async {
                if let error {
                    if case let .waitForActivation(failedTimes) = serviceStatus {
                        if failedTimes >= 5 {
                            serviceStatus = .disconnected(error: error)
                            appViewModel.endBackgroundTask()
                        } else {
                            serviceStatus = .waitForActivation(failedTimes: failedTimes + 1)
                        }
                    } else {
                        serviceStatus = .waitForActivation(failedTimes: 1)
                    }
                } else {
                    serviceStatus = .connected
                    appViewModel.endBackgroundTask()
                }
            }
        }
    }
}


// MARK: - Search in Apps (分词 → 在应用中搜索)

/// One user-editable search destination. Property names MUST match
/// `AppSearchTarget` in the WritingTools framework so the JSON written here
/// decodes there unchanged.
struct AppSearchEntry: Codable, Identifiable {
    var id: String
    var name: String
    var searchTemplate: String
    var bareScheme: String
}

extension AppSearchEntry {
    /// Scheme root (the part before `://` in the search template), used to look
    /// the target up in the installed-app map.
    var schemeRoot: String? {
        guard let range = searchTemplate.range(of: "://") else { return nil }
        let head = String(searchTemplate[..<range.lowerBound])
        return head.isEmpty ? nil : head
    }
}

/// Shared store for the search-in-app destination list.
///
/// The file lives inside AIGate's global storage directory so the injected
/// dylib (running in arbitrary, sandboxed host apps) can read it too; a host
/// app that cannot read it simply falls back to its built-in defaults.
enum AppSearchStore {
    /// KEEP IN SYNC with `AppSearchStore.path` in
    /// Library/WritingTools/Sources/WritingTools/WritingToolsView/WritingToolsView+AppSearch.swift
    static let path = "/var/mobile/Library/Preferences/wiki.qaq.ai.gate/faircopy_appsearch.json"

    /// KEEP IN SYNC with `kAppSearchDefaults` in
    /// Library/WritingTools/Sources/WritingTools/WritingToolsView/WritingToolsView+AppSearch.swift
    // GENERATED FROM Resources/AppSearch/appsearch_defaults.json — DO NOT EDIT BY HAND.
    // Edit the JSON, then run Scripts/gen_appsearch_defaults.py to regenerate both copies.
    static let defaults: [AppSearchEntry] = [
// >>> APPSEARCH_DEFAULTS_GENERATED >>>
        .init(id: "appstore", name: "AppStore", searchTemplate: "itms-apps://search.itunes.apple.com/WebObjects/MZSearch.woa/wa/search?term=%@", bareScheme: "itms-apps://"),
        .init(id: "pdd", name: "拼多多", searchTemplate: "pinduoduo://com.xunmeng.pinduoduo/search_result.html?search_key=%@", bareScheme: "pinduoduo://"),
        .init(id: "taobao", name: "淘宝", searchTemplate: "taobao://s.taobao.com/?q=%@", bareScheme: "taobao://"),
        .init(id: "jd", name: "京东", searchTemplate: "openjd://virtual?params={\"des\":\"productList\",\"keyWord\":\"%@\",\"from\":\"search\",\"category\":\"jump\"}", bareScheme: "openjd://"),
        .init(id: "weibo", name: "Weibo", searchTemplate: "sinaweibo://searchall?q=%@", bareScheme: "sinaweibo://"),
        .init(id: "bilibili", name: "BiliBili", searchTemplate: "bilibili://search?keyword=%@", bareScheme: "bilibili://"),
        .init(id: "twitter", name: "Twitter", searchTemplate: "twitter://search?query=%@", bareScheme: "twitter://"),
        .init(id: "applemaps", name: "苹果地图", searchTemplate: "maps://?q=%@", bareScheme: "maps://"),
        .init(id: "baidumap", name: "百度地图", searchTemplate: "baidumap://map/place/search?query=%@&src=Faircopy", bareScheme: "baidumap://"),
        .init(id: "amap", name: "高德地图", searchTemplate: "iosamap://poi?sourceApplication=Faircopy&name=%@&dev=0", bareScheme: "iosamap://"),
        .init(id: "zhihu", name: "知乎", searchTemplate: "zhihu://search?q=%@", bareScheme: "zhihu://"),
        .init(id: "xhs", name: "小红书", searchTemplate: "xhsdiscover://search/result?keyword=%@", bareScheme: "xhsdiscover://"),
    // <<< APPSEARCH_DEFAULTS_GENERATED <<<
    ]

    static func load() -> [AppSearchEntry] {
        guard
            let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
            let list = try? JSONDecoder().decode([AppSearchEntry].self, from: data)
        else { return defaults }
        return list
    }

    static func save(_ list: [AppSearchEntry]) {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// Mirrors `AppSearchSettings` / `AppSearchSettingsStore` in
/// WritingToolsView+AppSearch.swift — the two modules cannot share a source file
/// (AIGate does not link the WritingTools framework). Property names MUST match
/// so the JSON decodes unchanged on the panel side.
struct AppSearchSettings: Codable {
    var protectClipboard: Bool
}

struct AppSearchSettingsStore {
    /// KEEP IN SYNC with the same path in WritingToolsView+AppSearch.swift.
    static let path = "/var/mobile/Library/Preferences/wiki.qaq.ai.gate/faircopy_appsearch_settings.json"

    static func load() -> AppSearchSettings {
        guard
            let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
            let s = try? JSONDecoder().decode(AppSearchSettings.self, from: data)
        else { return AppSearchSettings(protectClipboard: true) }
        return s
    }

    static func save(_ settings: AppSearchSettings) {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(settings) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// Mirrors `AppSearchInstalledStore` in WritingToolsView+AppSearch.swift — the two
/// modules cannot share a source file (AIGate does not link the WritingTools
/// framework). Property names MUST match so the JSON decodes unchanged on the
/// panel side.
struct AppSearchInstalledStore {
    /// KEEP IN SYNC with the same path in WritingToolsView+AppSearch.swift.
    static let path = "/var/mobile/Library/Preferences/wiki.qaq.ai.gate/faircopy_appsearch_installed.json"

    static func load() -> [String: Bool] {
        guard
            let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
            let map = try? JSONDecoder().decode([String: Bool].self, from: data)
        else { return [:] }
        return map
    }

    static func save(_ map: [String: Bool]) {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(map) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// Editor for one destination: display name, search template, fallback scheme.
/// Deployment target is iOS 15, so no `TextField(axis:)` or Font.monospaced().
struct AppSearchEditorView: View {
    @Binding var entry: AppSearchEntry?
    let onCommit: (AppSearchEntry) -> Void

    @State private var draft = AppSearchEntry(id: "", name: "", searchTemplate: "", bareScheme: "")
    @Environment(\.dismiss) var dismiss
    @State private var showValidationError = false
    @State private var validationMessage = ""

    /// Explicit init: a private stored property would otherwise make the
    /// synthesized memberwise initializer private and unusable from the caller.
    init(entry: Binding<AppSearchEntry?>, onCommit: @escaping (AppSearchEntry) -> Void) {
        self._entry = entry
        self.onCommit = onCommit
    }

    /// Extracts `scheme://` from a template/scheme string, validating the scheme
    /// grammar (lowercase/uppercase letters, digits, `+ - .`, no spaces, no `%@`).
    private func schemeOf(_ value: String) -> String? {
        guard let range = value.range(of: "://") else { return nil }
        let head = String(value[..<range.lowerBound])
        guard !head.isEmpty, !head.contains(" "), !head.contains("%@") else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+-.")
        guard head.rangeOfCharacter(from: allowed.inverted) == nil else { return nil }
        return head + "://"
    }

    /// Builds a test URL from the current draft with a fixed keyword, mirroring
    /// the panel's percent-encoding (no JSON metachar escaping — the test word
    /// is plain). Returns nil if the template has no `%@` placeholder yet.
    private func testURL() -> URL? {
        guard draft.searchTemplate.contains("%@") else { return nil }
        let raw = draft.searchTemplate.replacingOccurrences(of: "%@", with: "test")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ":/?&=+;,!$'()*[]@~-._"))
        guard let encoded = raw.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: encoded)
    }

    private func validate() -> Bool {
        guard draft.searchTemplate.contains("%@") else {
            validationMessage = NSLocalizedString("Search template must contain %@", bundle: Bundle.wrti_support, comment: "")
            return false
        }
        guard schemeOf(draft.searchTemplate) != nil else {
            validationMessage = NSLocalizedString("Search template must start with a valid scheme (e.g. weibo://search?q=%@)", bundle: Bundle.wrti_support, comment: "")
            return false
        }
        if !draft.bareScheme.isEmpty, schemeOf(draft.bareScheme) == nil {
            validationMessage = NSLocalizedString("Fallback scheme must be a valid scheme ending in ://", bundle: Bundle.wrti_support, comment: "")
            return false
        }
        return true
    }

    private func commit() {
        guard validate() else {
            showValidationError = true
            return
        }
        var committed = draft
        if committed.id.isEmpty { committed.id = UUID().uuidString }
        onCommit(committed)
        dismiss()
    }

    private func testJump() {
        guard let url = testURL() else {
            validationMessage = NSLocalizedString("Search template must contain %@", bundle: Bundle.wrti_support, comment: "")
            showValidationError = true
            return
        }
        print("[Faircopy] app search test-jump: \(url.absoluteString)")
        UIApplication.shared.open(url)
    }

    var body: some View {
        Form {
            Section {
                TextField(NSLocalizedString("Weibo", bundle: Bundle.wrti_support, comment: ""), text: $draft.name)
            } header: {
                Text(NSLocalizedString("Name", bundle: Bundle.wrti_support, comment: ""))
            }
            Section {
                TextField(NSLocalizedString("e.g. weibo://search?q=%@", bundle: Bundle.wrti_support, comment: ""), text: $draft.searchTemplate)
                    .font(.footnote)
            } header: {
                Text(NSLocalizedString("Search Template", bundle: Bundle.wrti_support, comment: ""))
            } footer: {
                Text(NSLocalizedString("Use %@ where the picked keyword goes.", bundle: Bundle.wrti_support, comment: ""))
            }
            Section {
                TextField(NSLocalizedString("e.g. weibo://", bundle: Bundle.wrti_support, comment: ""), text: $draft.bareScheme)
                    .font(.footnote)
            } header: {
                Text(NSLocalizedString("Fallback Scheme", bundle: Bundle.wrti_support, comment: ""))
            } footer: {
                Text(NSLocalizedString("Opened if the search template fails, so you still land in the app with the keyword on the clipboard.", bundle: Bundle.wrti_support, comment: ""))
            }
            Section {
                Button {
                    testJump()
                } label: {
                    HStack(spacing: 6) {
                        Spacer()
                        Image(systemName: "paperplane")
                        Text(NSLocalizedString("Test Jump", bundle: Bundle.wrti_support, comment: ""))
                        Spacer()
                    }
                }
                .foregroundStyle(Color.accent)
            } header: {
                Text(NSLocalizedString("Preview", bundle: Bundle.wrti_support, comment: ""))
            } footer: {
                Text(NSLocalizedString("Opens the template in this app with a fixed keyword so you can confirm the scheme works before saving.", bundle: Bundle.wrti_support, comment: ""))
            }
        }
        .navigationTitle(draft.name.isEmpty ? NSLocalizedString("New App", bundle: Bundle.wrti_support, comment: "") : draft.name)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(NSLocalizedString("Cancel", bundle: Bundle.wrti_support, comment: "")) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(NSLocalizedString("Save", bundle: Bundle.wrti_support, comment: "")) { commit() }
            }
        }
        .alert(isPresented: $showValidationError) {
            Alert(
                title: Text(NSLocalizedString("Invalid Template", bundle: Bundle.wrti_support, comment: "")),
                message: Text(validationMessage),
                dismissButton: .default(Text(NSLocalizedString("OK", bundle: Bundle.wrti_support, comment: "")))
            )
        }
        .onAppear {
            if let entry = entry { draft = entry }
        }
    }
}
