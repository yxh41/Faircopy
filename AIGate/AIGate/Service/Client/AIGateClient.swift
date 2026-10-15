//
//  AIGateClient.swift
//  AIGate
//
//  Created by 秋星桥 on 2024/8/15.
//

import Foundation

class AIGateClient {
    enum Command: String, CaseIterable, Codable {
        case ping
        case reload
        case usageReset
    }

    enum CommandHeader: String {
        case exec = "X-Service-Command-Exec"
        case sect = "X-Service-Secret"
    }

    typealias CommandCompletion = (Data?, Error?) -> Void
    static func executeCommand(_ command: Command, completion: CommandCompletion? = nil) {
        var request = URLRequest(
            url: AIGateConfiguration.listenURL,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: TimeInterval(AIGateConfiguration.timeoutInterval)
        )
        request.addValue(
            command.rawValue,
            forHTTPHeaderField: CommandHeader.exec.rawValue
        )
        request.addValue(
            Configuration.shared.serviceSecret,
            forHTTPHeaderField: CommandHeader.sect.rawValue
        )
        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error { print("[*] failed to execute command: \(error)") }
            completion?(data, error)
        }.resume()
    }
}

extension AIGateClient.Command {
    func execute() {
        switch self {
        case .ping: break
        case .reload: Configuration.shared.reloadValueFromSystem()
        case .usageReset: UsageStatistics.shared.reset()
        }
    }
}

extension AIGateClient {
    /// Fetches accumulated token usage from the gate daemon.
    static func fetchUsage(completion: @escaping (UsageStats?) -> Void) {
        var components = URLComponents()
        components.scheme = "http"
        components.host = aiGateServiceAddress == "0.0.0.0" ? "127.0.0.1" : aiGateServiceAddress
        components.port = aiGateServicePort
        components.path = "/metrics"
        components.queryItems = [URLQueryItem(name: "query", value: "usage")]
        guard let url = components.url else {
            completion(nil)
            return
        }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data, let stats = try? JSONDecoder().decode(UsageStats.self, from: data) else {
                completion(nil)
                return
            }
            completion(stats)
        }.resume()
    }
}
