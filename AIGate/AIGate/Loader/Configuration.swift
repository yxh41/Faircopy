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

extension Configuration {
    final class ViewModel: ObservableObject {
        @Published var uiEndpoints: [Endpoint] = []
        @Published var uiActivatedEndpoint: Configuration.Endpoint?
        @Published var uiCustomPrompts: [CustomPrompt] = []
    }
}
