//
//  GlobalStorage.swift
//  MobileAffine
//
//  Created by 秋星桥 on 2024/6/28.
//

import CommonCrypto
import Foundation

private let dirname = "wiki.qaq.ai.gate"

#if targetEnvironment(simulator) || targetEnvironment(macCatalyst)
    private let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(dirname)
#else
    private let dir = URL(fileURLWithPath: "/var/mobile/Library/Preferences/")
        .appendingPathComponent(dirname)
#endif

extension String {
    var sha1: String {
        let data = Data(utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA1($0.baseAddress, CC_LONG(data.count), &digest) }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

class GlobalStorage: PersistProvider {
    static let shared = GlobalStorage()

    private init() {}

    /// Ensures the storage directory exists; lazy static initialization runs at
    /// most once and is thread-safe, replacing the previous per-access mkdir.
    private static let prepareDirectory: Void = {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }()

    func path(forKey: String) -> URL {
        _ = Self.prepareDirectory
        return dir.appendingPathComponent(forKey.sha1)
    }

    func data(forKey: String) -> Data? {
        try? Data(contentsOf: path(forKey: forKey))
    }

    func set(_ data: Data?, forKey: String) {
        guard let data else { return }
        // Atomic write: a kill mid-write can no longer leave a truncated config file.
        // File protection is intentionally left at the system default because the
        // launch daemon must read credentials before first unlock after boot.
        try? data.write(to: path(forKey: forKey), options: .atomic)
    }

    func removeObject(forKey: String) {
        try? FileManager.default.removeItem(at: path(forKey: forKey))
    }
}

extension Persist {
    init(key: String, defaultValue: Value) {
        self.init(key: key, defaultValue: defaultValue, engine: GlobalStorage.shared)
    }
}

extension PublishedPersist {
    init(key: String, defaultValue: Value) {
        self.init(key: key, defaultValue: defaultValue, engine: GlobalStorage.shared)
    }
}
