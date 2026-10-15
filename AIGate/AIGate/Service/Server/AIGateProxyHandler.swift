//
//  AIGateProxyHandler.swift
//  AIGate
//
//  Created by 秋星桥 on 2024/8/15.
//

import Foundation
import NIO
import NIOSSL
import NIOTLS

class AIGateProxyHandler: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = Void
    typealias OutboundIn = ByteBuffer

    let upstream: AIGateUpstream
    var upstreamChannel: Channel?
    var pendingBuffer: [ByteBuffer] = []

    init(upstream: AIGateUpstream) {
        self.upstream = upstream
    }

    func activateUpstream(downstream: ChannelHandlerContext) {
        let upstream = upstream

        let bootstrap = ClientBootstrap(group: downstream.channel.eventLoop)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { Self.channelInitializer($0, forUpstream: upstream, downstream: downstream) }

        let future = bootstrap.connect(host: upstream.host, port: upstream.port)
        future.whenSuccess { channel in
            self.upstreamChannel = channel
            self.flushPendingRequests()
        }
        future.whenFailure { _ in
            downstream.terminateChannel(reason: .upstreamNotReachable)
        }
    }

    func channelRead(context _: ChannelHandlerContext, data: NIOAny) {
        let byteBuffer = unwrapInboundIn(data)
        pendingBuffer.append(byteBuffer)
        flushPendingRequests()
    }

    func flushPendingRequests() {
        guard let upstreamChannel else { return }
        for item in pendingBuffer {
            upstreamChannel.write(NIOAny(item), promise: nil)
        }
        pendingBuffer.removeAll()
        upstreamChannel.flush()
    }

    func channelInactive(context _: ChannelHandlerContext) {
        _ = upstreamChannel?.close()
    }
}

extension AIGateProxyHandler {
    static func channelInitializer(_ channel: Channel, forUpstream upstream: AIGateUpstream, downstream: ChannelHandlerContext) -> EventLoopFuture<Void> {
        channel.pipeline.addHandlers([])
            .flatMap {
                guard upstream.tls else { return channel.pipeline.addHandlers([]) }
                let host = upstream.host
                let sslContext = try! NIOSSLContext(configuration: TLSConfiguration.makeClientConfiguration())
                let tls = try! NIOSSLClientHandler(context: sslContext, serverHostname: host)
                return channel.pipeline.addHandlers([tls])
            }
            .flatMap {
                channel.pipeline.addHandlers([
                    AIGateService.createUpstreamIdleStateHandler(),
                    IdleTerminationHandler(),
                    AIGateProxySwitchHandler(downstream: downstream),
                ])
            }
    }
}
