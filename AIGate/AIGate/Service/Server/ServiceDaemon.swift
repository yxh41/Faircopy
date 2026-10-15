//
//  ServiceDaemon.swift
//  AIGate
//
//  Created by 秋星桥 on 2024/8/15.
//

import Darwin
import Foundation

enum ServiceDaemon {
    static func main() -> Never {
        JetsamDisableControl()
        _ = GateSessionDelegate()

        repeat {
            defer { sleep(3) }

            let service: AIGateService
            print("[*] launching service...")

            do {
                service = try AIGateService()
            } catch {
                print("[*] service boot failed: \(error)")
                continue
            }

            do {
                try service.wait()
            } catch {
                print("[*] service exit: \(error)")
            }
        } while BootMode.current == .bootBoth

        exit(EXIT_FAILURE)
    }
}
