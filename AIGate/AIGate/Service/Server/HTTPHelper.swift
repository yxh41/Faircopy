//
//  HTTPHelper.swift
//  AIGate
//
//  Created by 秋星桥 on 2024/8/22.
//

import Foundation
import NIO

enum HTTPHelper {
    static let newline: Data = "\r\n".data(using: .utf8)!
    static let headerEnd = newline + newline
}

struct HTTPParts {
    let header: Data
    let body: Data
    let headerCompleted: Bool
}

extension ChannelHandlerContext {
    func responseWithHTTP(
        code: Int,
        json: (some Encodable)? = nil
    ) {
        let data: Data = if let json {
            (try? JSONEncoder().encode(json)) ?? .init()
        } else {
            Data()
        }
        let resp = [
            """
            HTTP/1.1 \(code) \(code == 200 ? "OK" : "Application Defined Code")
            Content-Type: application/json
            Content-Length: \(data.count)
            """.data(using: .utf8) ?? .init(),
            HTTPHelper.newline,
            HTTPHelper.newline,
            data,
            HTTPHelper.newline,
            HTTPHelper.newline,
        ].reduce(Data()) { $0 + $1 }
        let down = NIOAny(channel.allocator.buffer(bytes: resp))
        writeAndFlush(down, promise: nil)
        close(mode: .all, promise: nil)
    }
}

extension ChannelHandler {
    func splitInputDataForHTTP(currentData: Data, incomingData: Data) -> HTTPParts {
        let fullChain = currentData + incomingData
        var headerEndIndex: Int?
        if let index = fullChain.range(of: HTTPHelper.headerEnd) {
            headerEndIndex = index.lowerBound + HTTPHelper.headerEnd.count
        }
        let header: Data
        let body: Data
        if let headerEndIndex {
            header = fullChain[0 ..< headerEndIndex]
            body = fullChain[headerEndIndex...]
        } else {
            header = fullChain
            body = Data()
        }
        return HTTPParts(
            header: header,
            body: body,
            headerCompleted: headerEndIndex != nil
        )
    }
}
