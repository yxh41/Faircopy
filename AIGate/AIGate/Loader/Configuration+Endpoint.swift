//
//  Configuration+Endpoint.swift
//  AIGate
//
//  Created by 秋星桥 on 2024/8/25.
//

import Foundation

extension Configuration {
    struct Endpoint: Codable, Identifiable, Equatable, Hashable {
        let id: UUID
        let create: Date

        var url: URL
        var token: String
        var model: String

        init(id: UUID = .init(), url: URL, token: String, model: String) {
            self.id = id
            self.url = url
            self.token = token
            self.model = model
            create = Date()
        }
    }
}
