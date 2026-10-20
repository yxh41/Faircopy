//
//  AddEndpointView.swift
//  AIGate
//
//  Created by 秋星桥 on 2024/8/15.
//

import SwiftUI
import SwiftUIIntrospect

private let noModelError: Error = NSError(
    domain: "Error",
    code: 0,
    userInfo: [NSLocalizedDescriptionKey: NSLocalizedString(
        "Unable to fetch models. Please check your endpoint address and its key carefully, then try again later.",
        bundle: Bundle.wrti_support,
        comment: ""
    )]
)

private let invalidURLError: Error = NSError(
    domain: "Error",
    code: 0,
    userInfo: [NSLocalizedDescriptionKey: NSLocalizedString(
        "Invalid URL.",
        bundle: Bundle.wrti_support,
        comment: ""
    )]
)

private let recommendedModelKeywords = [
    // OpenAI – fast and strong for writing
    "gpt-4o-mini",
    "gpt-4o",

    // Anthropic – haiku for speed/cost, sonnet for quality
    "claude-3.5-haiku",
    "claude-3.5-sonnet",

    // Google – flash tiers are fast and economical
    "gemini-1.5-flash",
    "gemini-2.0-flash",

    // Meta – common instruct variants via many providers
    "llama-3.2-90b-instruct",
    "llama-3.2-11b-instruct",
    "llama-3.1-70b-instruct",
    "llama-3.1-8b-instruct",

    // Alibaba Qwen – good balance for writing
    "qwen2.5-72b-instruct",
    "qwen2.5-14b-instruct",

    // Mistral / Cohere – practical choices
    "mixtral-8x7b-instruct",
    "mistral-large",
    "mistral-small",
    "command-r",
    "command-r-plus",

    // Deepseek – solid open models
    "deepseek-chat",

    // Generic size hints often used by aggregators
    "70b",
    "72b",
    "90b",
].map(\.filteredModelNameForMatch)

private let bannedRecommendedModelKeyword = [
    "beta",
    "vision",
    "online",

    // extra exclusions for non-text/real-time variants
    "realtime",
    "audio",
    "tts",
    "whisper",
    "asr",
].map(\.filteredModelNameForMatch)

struct AddEndpointView: View {
    @StateObject var cvm = Configuration.shared
    @Environment(\.dismiss) var dismiss

    @State var endpointURL: String
    @State var endpointKey: String

    @State var usableModels: [String] = []
    @State var selectedModels: Set<String> = []

    @State var isFetchingValues: Bool = false
    @State var lastError: Error? = nil

    /// Set in edit mode; saving then updates this endpoint in place instead of
    /// creating a new one. `Duplicate` leaves this nil.
    @State var editingEndpointID: UUID? = nil

    @FocusState private var isEndpointURLFocused: Bool
    @FocusState private var isEndpointKeyFocused: Bool

    /// Each fresh "Add Endpoint" starts blank so adding a different provider
    /// never disturbs the ones already saved — they stay in the Endpoints list
    /// and are reactivated with a tap. (Previously this pre-filled the
    /// last-used URL/key, forcing the user to clear it before entering a new
    /// provider.)
    ///
    /// `Duplicate` (and `Edit`) in the endpoint context menu open this view
    /// pre-filled with an existing endpoint's URL/key (see EndpointButton).
    /// `Duplicate` passes `editing: nil` so saving creates a new endpoint;
    /// `Edit` passes the endpoint so saving updates it in place — no re-typing,
    /// and switching models for the same provider only needs a model pick.
    init(prefillURL: String = "", prefillKey: String = "", editing endpoint: Configuration.Endpoint? = nil) {
        _endpointURL = State(initialValue: prefillURL)
        _endpointKey = State(initialValue: prefillKey)
        if let endpoint {
            // Keep usableModels empty so the URL/Key stay editable and the
            // "Fetch Available Models" button stays available; pre-select the
            // existing model so saving keeps it unless the user re-picks.
            _selectedModels = State(initialValue: [endpoint.model])
            _editingEndpointID = State(initialValue: endpoint.id)
        }
    }

    var url: URL? { URL(string: endpointURL) }
    var urlHost: String { url?.host ?? "" }

    var isFetchingOrFetchedValues: Bool { isFetchingValues || !usableModels.isEmpty }

    var recommendedModels: [String] {
        usableModels.filter { model in
            true
                && recommendedModelKeywords.contains { keyword in
                    model.filteredModelNameForMatch.contains(keyword)
                }
                && !bannedRecommendedModelKeyword.contains { keyword in
                    model.filteredModelNameForMatch.contains(keyword)
                }
        }.sorted()
    }

    var endpointURLSection: some View {
        Section {
            TextField(
                NSLocalizedString("Endpoint URL", bundle: Bundle.wrti_support, comment: ""),
                text: $endpointURL,
                prompt: Text(NSLocalizedString("URL", bundle: Bundle.wrti_support, comment: ""))
            )
            .autocorrectionDisabled()
            .textInputAutocapitalization(.none)
            .textContentType(.URL)
            .keyboardType(.URL)
            .submitLabel(.next)
            .truncationMode(.tail)
            .opacity(isFetchingOrFetchedValues ? 0.5 : 1)
            .focused($isEndpointURLFocused)
            .onSubmit {
                isEndpointURLFocused = false
                isEndpointKeyFocused = true
            }
            .introspect(.textField, on: .iOS(.v15, .v16, .v17, .v18)) { textField in
                textField.tintColor = .accent
                textField.autocapitalizationType = .none
                textField.autocorrectionType = .no
                textField.spellCheckingType = .no
                textField.smartQuotesType = .no
                textField.smartDashesType = .no
                textField.smartInsertDeleteType = .no
                textField.clearButtonMode = .whileEditing
            }
            if usableModels.isEmpty {
                NavigationLink(
                    destination: {
                        CommonProviderPicker { url in
                            if let url { endpointURL = url }
                        }
                    },
                    label: {
                        Text(NSLocalizedString("Common Provider", bundle: Bundle.wrti_support, comment: ""))
                    }
                )
                .foregroundStyle(isFetchingOrFetchedValues ? Color.secondary : Color.accent)
                .transition(.opacity)
            }
        } header: {
            Text(NSLocalizedString("Endpoint URL", bundle: Bundle.wrti_support, comment: ""))
        } footer: {
            Text(NSLocalizedString("The URL of the endpoint you want to add. It should be OpenAI API endpoint url without v1 suffix.", bundle: Bundle.wrti_support, comment: ""))
        }
    }

    var getKeyURL: URL? {
        commonProviders.first { $0.endpoint == endpointURL }?.whereToGetKey
    }

    var endpointKeySection: some View {
        Section {
            HStack(spacing: 16) {
                SecureField(NSLocalizedString("Endpoint Key", bundle: Bundle.wrti_support, comment: ""), text: $endpointKey, prompt: Text(NSLocalizedString("Key", bundle: Bundle.wrti_support, comment: "")))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.none)
                    .textContentType(.password)
                    .keyboardType(.asciiCapable)
                    .submitLabel(.search)
                    .truncationMode(.head)
                    .opacity(isFetchingOrFetchedValues ? 0.5 : 1)
                    .focused($isEndpointKeyFocused)
                    .onSubmit {
                        isEndpointKeyFocused = false
                        fetchModels()
                    }
                    .introspect(.textField, on: .iOS(.v15, .v16, .v17, .v18)) { textField in
                        textField.tintColor = .accent
                        textField.autocapitalizationType = .none
                        textField.autocorrectionType = .no
                        textField.spellCheckingType = .no
                        textField.smartQuotesType = .no
                        textField.smartDashesType = .no
                        textField.smartInsertDeleteType = .no
                        textField.clearButtonMode = .never
                    }
                Button {
                    endpointKey = UIPasteboard.general.string ?? ""
                } label: {
                    Image(systemName: "doc.on.clipboard")
                        .foregroundStyle(isFetchingOrFetchedValues ? Color.secondary : Color.accent)
                }
                .buttonStyle(.plain)
            }
            if let whereToGetKey = getKeyURL, usableModels.isEmpty {
                Link(NSLocalizedString("Get Endpoint Key", bundle: Bundle.wrti_support, comment: ""), destination: whereToGetKey)
                    .opacity(isFetchingOrFetchedValues ? 0.5 : 1)
                    .foregroundStyle(isFetchingOrFetchedValues ? Color.secondary : Color.accent)
            }
        } header: {
            Text(NSLocalizedString("Endpoint Key", bundle: Bundle.wrti_support, comment: ""))
        } footer: {
            Text(NSLocalizedString("The authorization of this endpoint. It may be optional.", bundle: Bundle.wrti_support, comment: ""))
        }
    }

    var fetchModelsSection: some View {
        Section {
            Button {
                isEndpointURLFocused = false
                isEndpointKeyFocused = false
                fetchModels()
            } label: {
                Text(NSLocalizedString("Fetch Available Models", bundle: Bundle.wrti_support, comment: ""))
            }
            .disabled(url == nil || urlHost.isEmpty)
            .tint(Color.accent)
        } footer: {
            if let lastError {
                Text(String(format: NSLocalizedString("Error: %@", bundle: Bundle.wrti_support, comment: ""), lastError.localizedDescription))
                    .foregroundColor(.red)
            }
        }
    }

    var listRecommendedModelsSection: some View {
        Section {
            ForEach(recommendedModels, id: \.self) { model in
                Button {
                    if selectedModels.contains(model) {
                        selectedModels.remove(model)
                    } else {
                        selectedModels.insert(model)
                    }
                } label: {
                    HStack(spacing: 16) {
                        Text(model)
                        Spacer()
                        Image(systemName: "checkmark")
                            .opacity(selectedModels.contains(model) ? 1 : 0)
                    }
                    .tint(
                        selectedModels.contains(model) || selectedModels.isEmpty
                            ? Color.accent
                            : Color.primary
                    )
                    .foregroundStyle(
                        selectedModels.contains(model) || selectedModels.isEmpty
                            ? Color.accent
                            : Color.primary
                    )
                }
            }
        } header: {
            Text(NSLocalizedString("Recommended Models", bundle: Bundle.wrti_support, comment: ""))
        } footer: {
            Text(NSLocalizedString("Recommended models are tested to perform better in most cases.", bundle: Bundle.wrti_support, comment: ""))
        }
    }

    var listModelsSection: some View {
        Section {
            ForEach(usableModels, id: \.self) { model in
                Button {
                    if selectedModels.contains(model) {
                        selectedModels.remove(model)
                    } else {
                        selectedModels.insert(model)
                    }
                } label: {
                    HStack(spacing: 16) {
                        Text(model)
                        Spacer()
                        Image(systemName: "checkmark")
                            .opacity(selectedModels.contains(model) ? 1 : 0)
                    }
                    .tint(
                        selectedModels.contains(model) || selectedModels.isEmpty
                            ? Color.accent
                            : Color.primary
                    )
                    .foregroundStyle(
                        selectedModels.contains(model) || selectedModels.isEmpty
                            ? Color.accent
                            : Color.primary
                    )
                }
            }
        } header: {
            Text(NSLocalizedString("Available Models", bundle: Bundle.wrti_support, comment: ""))
        } footer: {
            Text(NSLocalizedString("Select a model you want to use.", bundle: Bundle.wrti_support, comment: ""))
        }
    }

    var saveEndpointsSection: some View {
        Button(
            selectedModels.count <= 1
                ? NSLocalizedString("Save Endpoint", bundle: Bundle.wrti_support, comment: "")
                : String(format: NSLocalizedString("Save %d Endpoints", bundle: Bundle.wrti_support, comment: ""), selectedModels.count)
        ) {
            save()
        }
        .disabled(selectedModels.isEmpty)
        .tint(Color.accent)
    }

    var body: some View {
        Form {
            Group {
                endpointURLSection
                endpointKeySection
            }
            .disabled(!usableModels.isEmpty)

            if usableModels.isEmpty {
                fetchModelsSection
            } else {
                if recommendedModels.isEmpty {
                    listModelsSection
                    saveEndpointsSection
                } else {
                    listRecommendedModelsSection
                    saveEndpointsSection
                    listModelsSection
                }
            }
        }
        .disabled(isFetchingValues)
        .navigationTitle(NSLocalizedString("Add Endpoint", bundle: Bundle.wrti_support, comment: ""))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(NSLocalizedString("Cancel", bundle: Bundle.wrti_support, comment: "")) {
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(NSLocalizedString("Save", bundle: Bundle.wrti_support, comment: "")) {
                    save()
                }
                .disabled(selectedModels.isEmpty)
            }
        }
        .animation(.spring, value: getKeyURL)
        .animation(.smooth, value: usableModels)
        .animation(.smooth, value: recommendedModels)
        .animation(.spring, value: isFetchingValues)
        .listStyle(.insetGrouped)
    }

    /// Persist the picked models. In edit mode the first model overwrites the
    /// original endpoint (same id, original create date preserved); any extra
    /// picked models are added as new endpoints. In add/duplicate mode every
    /// picked model becomes a new endpoint.
    func save() {
        guard let url else { return }
        let models = selectedModels.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending })
        guard !models.isEmpty else { return }
        if let editingEndpointID {
            cvm.update(Configuration.Endpoint(id: editingEndpointID, url: url, token: endpointKey, model: models[0]))
            for model in models.dropFirst() {
                cvm.add(.init(url: url, token: endpointKey, model: model))
            }
        } else {
            for model in models {
                cvm.add(.init(url: url, token: endpointKey, model: model))
            }
        }
        dismiss()
    }

    func fetchModels() {
        isFetchingValues = true
        lastError = nil
        DispatchQueue.global(qos: .userInteractive).async {
            var v1Error: Error?
            switch fetchModelsViaV1Endpoint() {
            case let .success(fetchedModels):
                completeWith(models: fetchedModels, error: nil)
                return
            case let .failure(error):
                v1Error = error
            }
            switch fetchModelsViaBareEndpoint() {
            case let .success(fetchedModels):
                completeWith(models: fetchedModels, error: nil)
                return
            case .failure: break
            }
            completeWith(models: [], error: v1Error)
        }
    }

    func completeWith(models: [String], error: Error?) {
        DispatchQueue.main.async {
            withAnimation {
                isFetchingValues = false
                if models.isEmpty {
                    lastError = error ?? noModelError
                } else {
                    usableModels = models
                    lastError = nil
                }
            }
        }
    }

    func fetchModelsViaV1Endpoint() -> Result<[String], Error> {
        guard let url = url?.appendingPathComponent("v1").appendingPathComponent("models") else {
            return .failure(invalidURLError)
        }
        return fetchModels(url: url)
    }

    func fetchModelsViaBareEndpoint() -> Result<[String], Error> {
        guard let url = url?.appendingPathComponent("models") else {
            return .failure(invalidURLError)
        }
        return fetchModels(url: url)
    }

    func fetchModels(url: URL) -> Result<[String], Error> {
        assert(!Thread.isMainThread)
        let sem = DispatchSemaphore(value: 0)
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 30
        )
        request.addValue("Bearer \(endpointKey)", forHTTPHeaderField: "Authorization")
        var models: [String] = []
        var check: Error?
        URLSession.shared.dataTask(with: request) { data, _, error in
            defer { sem.signal() }
            models = scrubModels(data)
            check = error
        }.resume()
        sem.wait()
        if !models.isEmpty {
            return .success(models)
        } else {
            return .failure(check ?? noModelError)
        }
    }

    func scrubModels(_ data: Data?) -> [String] {
        var fetchedModels = [String]()
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data)
        else { return [] }
        if let dic = object as? [String: Any], let list = dic["data"] as? [[String: Any]] {
            for item in list {
                guard let id = item["id"] as? String else { continue }
                fetchedModels.append(id)
            }
        } else if let list = object as? [[String: Any]] {
            for item in list {
                if let id = item["id"] as? String, !id.hasPrefix("azureml://") {
                    fetchedModels.append(id)
                } else if let id = item["name"] as? String {
                    fetchedModels.append(id)
                }
            }
        }
        return fetchedModels.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

private extension String {
    var filteredModelNameForMatch: String {
        lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
