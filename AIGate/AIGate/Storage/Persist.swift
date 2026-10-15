//
//  Persist.swift
//  MobileAffine
//
//  Created by 秋星桥 on 2024/6/28.
//

import Combine
import Foundation

private let valueEncoder = JSONEncoder()
private let valueDecoder = JSONDecoder()

@propertyWrapper
struct Persist<Value: Codable> {
    private let key: String
    private let engine: PersistProvider
    private let defaultValue: Value
    private let subject: CurrentValueSubject<Value, Never>
    private let cancellables: Set<AnyCancellable>

    public var projectedValue: AnyPublisher<Value, Never> {
        subject.eraseToAnyPublisher()
    }

    public init(key: String, defaultValue: Value, engine: PersistProvider) {
        self.key = key
        self.engine = engine
        self.defaultValue = defaultValue
        subject = .init(engine.obtainValue(for: key) ?? defaultValue)

        var cancellables: Set<AnyCancellable> = .init()
        subject
            .receive(on: DispatchQueue.global(qos: .utility))
            .sink { engine.writeValue($0, forKey: key) }
            .store(in: &cancellables)
        self.cancellables = cancellables
    }

    public var wrappedValue: Value {
        get { subject.value }
        set { subject.send(newValue) }
    }

    public func invalidateCaches() {
        let value = engine.obtainValue(for: key) ?? defaultValue
        subject.send(value)
    }

    public func saveNow() {
        engine.writeValue(subject.value, forKey: key)
    }
}

private extension PersistProvider {
    func obtainValue<T: Codable>(for key: String) -> T? {
        guard let data = data(forKey: key) else { return nil }
        return try? valueDecoder.decode(T.self, from: data)
    }

    func writeValue(_ value: some Codable, forKey key: String) {
        let data = try? valueEncoder.encode(value)
        set(data, forKey: key)
    }
}
