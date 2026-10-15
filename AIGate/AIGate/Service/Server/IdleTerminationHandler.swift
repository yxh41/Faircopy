//
//  IdleTerminationHandler.swift
//  AIGate
//
//  Created by 秋星桥 on 2024/8/15.
//

import Foundation
import NIO

class IdleTerminationHandler: ChannelInboundHandler {
    typealias InboundIn = IdleStateHandler.IdleStateEvent

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let idleEvent = event as? IdleStateHandler.IdleStateEvent {
            switch idleEvent {
            case .all:
                context.close(promise: nil)
            default:
                break
            }
        }
        context.fireUserInboundEventTriggered(event)
    }
}
