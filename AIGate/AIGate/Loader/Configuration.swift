//
//  Configuration.swift
//  AIGate
//
//  Created by 秋星桥 on 2024/8/15.
//

import Combine
import Darwin
import Foundation
import SwiftUI

@objc(WritingToolConfiguration)
class Configuration: NSObject, ObservableObject {
    @objc(shared)
    static let shared = Configuration()
    static let noneActivated: UUID = .init(uuidString: "9dfefff5-ab74-4c5f-ad55-87f31da6a5d1")!

    let viewModel: ViewModel = .init()

    @Persist(key: "ServiceSecret", defaultValue: UUID().uuidString)
    var serviceSecret: String

    @PublishedPersist(key: "Enabled", defaultValue: true)
    var isEnabled: Bool

    @PublishedPersist(key: "ActivatedEndpointID", defaultValue: noneActivated)
    var activatedEndpointID: Endpoint.ID

    var activatedEndpoint: Endpoint? {
        if activatedEndpointID == Self.noneActivated { return nil }
        return configuredEndpoints[activatedEndpointID]
    }

    @PublishedPersist(key: "ConfiguredEndpoints", defaultValue: [:])
    private var configuredEndpoints: [Endpoint.ID: Endpoint]

    /// In-memory reachability probe results, keyed by endpoint id. Not persisted;
    /// cleared on reload. Populated by `scanEndpoints()` and per-node `testConnection`.
    @Published var endpointReach: [Endpoint.ID: EndpointReach] = [:]

    /// True while `scanEndpoints()` is in flight.
    @Published var isScanningEndpoints = false

    // Must be @PublishedPersist: the gate daemon caches Persist values in memory
    // and only refreshes them on the .reload command, which is emitted from
    // objectWillChange. Plain @Persist here would leave the daemon serving a
    // stale (empty) custom_prompts list to the writing panel forever.
    @PublishedPersist(key: "CustomPrompts", defaultValue: [:])
    private var customPrompts: [UUID: CustomPrompt]

    var allCustomPrompts: [CustomPrompt] {
        customPrompts.values.sorted { $0.created < $1.created }
    }

    func hasCustomPrompt(withID id: UUID) -> Bool {
        customPrompts.keys.contains(id)
    }

    func addCustomPrompt(_ prompt: CustomPrompt) {
        customPrompts[prompt.id] = prompt
        saveCustomPrompts()
    }

    func updateCustomPrompt(_ prompt: CustomPrompt) {
        customPrompts[prompt.id] = prompt
        saveCustomPrompts()
    }

    func removeCustomPrompt(_ prompt: CustomPrompt) {
        customPrompts.removeValue(forKey: prompt.id)
        saveCustomPrompts()
    }

    /// Merges an imported set of prompts by id (imported entries overwrite
    /// same-id local entries, new ids are appended).
    func importCustomPrompts(_ prompts: [CustomPrompt]) {
        for prompt in prompts {
            customPrompts[prompt.id] = prompt
        }
        saveCustomPrompts()
    }

    private func saveCustomPrompts() {
        _customPrompts.saveNow()
        reloadViewModel()
    }

    var cancellable: Set<AnyCancellable> = []

    override init() {
        super.init()

        objectWillChange
            .throttle(for: .seconds(0.5), scheduler: DispatchQueue.global(qos: .utility), latest: true)
            .sink { [weak self] _ in
                self?.notifyConfigurationChangeToSystem()
            }
            .store(in: &cancellable)

        objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.reloadViewModel()
            }
            .store(in: &cancellable)
    }

    func reloadViewModel() {
        assert(Thread.isMainThread)
        viewModel.uiActivatedEndpoint = activatedEndpoint
        viewModel.uiEndpoints = configuredEndpoints.values.sorted { $0.create < $1.create }
        viewModel.uiCustomPrompts = allCustomPrompts
    }

    func add(_ endpoint: Endpoint) {
        configuredEndpoints[endpoint.id] = endpoint
        if activatedEndpoint == nil {
            activatedEndpointID = endpoint.id
        }
        reloadViewModel()
    }

    func remove(_ endpoint: Endpoint) {
        configuredEndpoints.removeValue(forKey: endpoint.id)
        if activatedEndpointID == endpoint.id {
            activatedEndpointID = Self.noneActivated
        }
        reloadViewModel()
    }

    /// Replace an existing endpoint in place. Keeps the original `create` date
    /// so the list order (sorted by create time) is preserved on edit.
    func update(_ endpoint: Endpoint) {
        var endpoint = endpoint
        if let old = configuredEndpoints[endpoint.id] {
            endpoint.create = old.create
        }
        configuredEndpoints[endpoint.id] = endpoint
        reloadViewModel()
    }

    // MARK: - Endpoint reachability

    /// Probe a single endpoint's `/models` (also tries `/v1/models`) and report
    /// reachability plus round-trip latency in milliseconds. Used by both the bulk
    /// "Test All" scan and the per-node "Test Connection" action.
    func probeReach(_ endpoint: Endpoint, completion: @escaping (EndpointReach) -> Void) {
        let base = endpoint.url
        let key = endpoint.token
        let targets = [
            base.appendingPathComponent("v1").appendingPathComponent("models"),
            base.appendingPathComponent("models"),
        ]
        let start = Date()
        func attempt(_ index: Int) {
            guard index < targets.count else {
                let detail = NSLocalizedString("no HTTP response", bundle: Bundle.wrti_support, comment: "")
                completion(EndpointReach(reachable: false, latencyMs: nil, detail: detail))
                return
            }
            var req = URLRequest(url: targets[index], cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 20)
            if !key.isEmpty {
                req.addValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
            URLSession.shared.dataTask(with: req) { _, response, error in
                if error != nil {
                    attempt(index + 1)
                    return
                }
                let latencyMs = Int(Date().timeIntervalSince(start) * 1000)
                guard let http = response as? HTTPURLResponse else {
                    attempt(index + 1)
                    return
                }
                if http.statusCode == 200 {
                    completion(EndpointReach(reachable: true, latencyMs: latencyMs, detail: nil))
                } else {
                    let detail = String(format: NSLocalizedString("Connection failed: %@", bundle: Bundle.wrti_support, comment: ""), "HTTP \(http.statusCode)")
                    completion(EndpointReach(reachable: false, latencyMs: latencyMs, detail: detail))
                }
            }.resume()
        }
        attempt(0)
    }

    /// Probe every configured endpoint concurrently and publish results to
    /// `endpointReach`. Intended for the "Test All" bulk scan.
    func scanEndpoints() {
        let endpoints = Array(configuredEndpoints.values)
        guard !endpoints.isEmpty else { return }
        isScanningEndpoints = true
        let group = DispatchGroup()
        for endpoint in endpoints {
            group.enter()
            probeReach(endpoint) { result in
                DispatchQueue.main.async { [weak self] in
                    if let self {
                        var next = self.endpointReach
                        next[endpoint.id] = result
                        self.endpointReach = next
                    }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            self.isScanningEndpoints = false
        }
    }

    func notifyConfigurationChangeToSystem() {
        AIGateClient.executeCommand(.reload)
    }

    func saveNow() {
        _isEnabled.saveNow()
        _activatedEndpointID.saveNow()
        _configuredEndpoints.saveNow()
        _customPrompts.saveNow()
    }

    @objc
    func reloadValueFromSystem() {
        _isEnabled.invalidateCaches()
        _activatedEndpointID.invalidateCaches()
        _configuredEndpoints.invalidateCaches()
        _customPrompts.invalidateCaches()
    }

    func endpointHandlerForQuickSwitch() -> [Endpoint] {
        var redactedCopying = Array(configuredEndpoints.values)
        for idx in 0 ..< redactedCopying.count {
            redactedCopying[idx].token = "[********]"
        }
        return redactedCopying
    }

    func hasEndpointWithID(_ uuid: UUID) -> Bool {
        configuredEndpoints.keys.contains(uuid)
    }
}

/// Result of a reachability probe for a single endpoint.
struct EndpointReach: Equatable {
    /// Whether the endpoint responded with HTTP 200 on its `/models` endpoint.
    let reachable: Bool
    /// Round-trip latency in milliseconds (from request start to first response),
    /// or nil if no response was received.
    let latencyMs: Int?
    /// Human-readable failure detail (e.g. "HTTP 401" or "no HTTP response"),
    /// nil when reachable.
    let detail: String?
}

extension Configuration {
    final class ViewModel: ObservableObject {
        @Published var uiEndpoints: [Endpoint] = []
        @Published var uiActivatedEndpoint: Configuration.Endpoint?
        @Published var uiCustomPrompts: [CustomPrompt] = []
    }
}
