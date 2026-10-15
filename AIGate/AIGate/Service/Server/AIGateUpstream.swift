//
//  AIGateUpstream.swift
//  AIGate
//
//  Created by 秋星桥 on 2024/8/15.
//

import Foundation

struct AIGateUpstream {
    let url: URL
    let host: String
    let port: Int
    let tls: Bool
    let key: String
    let mid: String // model id

    init(url: URL, host: String, port: Int, tls: Bool, key: String, mid: String) {
        self.url = url
        self.host = host
        self.port = port
        self.tls = tls
        self.key = key
        self.mid = mid
    }
}

extension AIGateUpstream {
    init?() {
        let cvm = Configuration.shared
        guard let endpoint = cvm.activatedEndpoint else { return nil }

        guard let host = endpoint.url.host else { return nil }
        guard let scheme = endpoint.url.scheme else { return nil }

        let tls = scheme.lowercased() == "https"
        let port = endpoint.url.port ?? (tls ? 443 : 80)
        let key = endpoint.token
        let model = endpoint.model

        guard model.data(using: .utf8) != nil else { return nil }

        self.init(
            url: endpoint.url,
            host: host,
            port: port,
            tls: tls,
            key: key,
            mid: model
        )
    }
}
