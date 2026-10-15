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

struct FaircopyRootView: View {
    @StateObject var appViewModel = FaircopyAppModel.shared
    @StateObject var configuration = Configuration.shared
    @StateObject var configurationViewModel = Configuration.shared.viewModel

    @State var mailResult: Result<MFMailComposeResult, Error>? = nil
    @State var isShowingMailView = false

    @State var openAddSheet = false
    @State var quickLookExport: URL?

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
            usageSection

            if appViewModel.isLiteEdition { supportTweakSection }

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
