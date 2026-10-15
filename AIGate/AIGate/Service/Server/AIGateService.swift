//
//  AIGateService.swift
//  AIGate
//
//  Created by 秋星桥 on 2024/8/15.
//

import Foundation
import NIO
import NIOSSL

class AIGateService: Identifiable {
    var id: UUID = .init()
    var channel: Channel

    public init() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelInitializer { channel in
                Self.channelInitializer(group: group, channel: channel)
            }
            .childChannelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
            .childChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)

        channel = try bootstrap.bind(host: "127.0.0.1", port: aiGateServicePort).wait()

        print("[*] server started and listen on \(AIGateConfiguration.listenURL.absoluteString)")
    }

    func wait() throws {
        try channel.closeFuture.wait()
    }

    deinit { channel.close(mode: .all, promise: nil) }
}

extension AIGateService {
    /// Idle handler for client-facing (downstream) channels: reap idle
    /// connections aggressively so abandoned panels do not pile up.
    static func createIdleStateHandler() -> IdleStateHandler {
        IdleStateHandler(
            readTimeout: .seconds(AIGateConfiguration.timeoutInterval),
            writeTimeout: .seconds(AIGateConfiguration.timeoutInterval),
            allTimeout: .seconds(AIGateConfiguration.timeoutInterval)
        )
    }

    /// Idle handler for upstream-facing channels: slow models may take minutes
    /// before the first token arrives, so only truly dead connections are reaped.
    static func createUpstreamIdleStateHandler() -> IdleStateHandler {
        IdleStateHandler(
            readTimeout: .seconds(AIGateConfiguration.upstreamTimeoutInterval),
            writeTimeout: .seconds(AIGateConfiguration.upstreamTimeoutInterval),
            allTimeout: .seconds(AIGateConfiguration.upstreamTimeoutInterval)
        )
    }

    static func channelInitializer(group: EventLoopGroup, channel: Channel) -> EventLoopFuture<Void> {
        var ret = channel.pipeline.addHandlers([])
        ret = channel.pipeline.addHandlers([
            createIdleStateHandler(),
            IdleTerminationHandler(),
        ])
        ret = channel.pipeline.addHandler(AIGateHandler(group: group))
        return ret
    }
}
