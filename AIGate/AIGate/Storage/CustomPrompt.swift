//
//  CustomPrompt.swift
//  AIGate
//
//  User-defined writing prompt model, shared by the companion app editor,
//  the gate daemon and the writing panel.
//

import Foundation

struct CustomPrompt: Codable, Equatable, Identifiable, Hashable {
    let id: UUID
    var title: String
    var prompt: String
    var created: TimeInterval

    init(
        id: UUID = .init(),
        title: String,
        prompt: String,
        created: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.created = created
    }
}
