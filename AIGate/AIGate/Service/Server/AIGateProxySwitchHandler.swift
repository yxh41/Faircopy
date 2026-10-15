//
//  AIGateProxySwitchHandler.swift
//  AIGate
//
//  Created by 秋星桥 on 2024/8/15.
//

import Foundation
import NIO

class AIGateProxySwitchHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    let downstream: ChannelHandlerContext

    var headerBuffer = Data()
    var headerCompleted = false
    var bodyBuffer = Data()
    var bodyBufferForWrite = Data()

    /// Rolling tail of the upstream body, scanned for a final usage object.
    private var usageScanBuffer = Data()
    private var usageRecorded = false
    private let usageScanLimit = 65_536
    private static let usageMarker = Data("\"usage\"".utf8)

    init(downstream: ChannelHandlerContext) {
        self.downstream = downstream
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var inputBuffer = unwrapInboundIn(data)
        guard let inputRead = inputBuffer.readBytes(length: inputBuffer.readableBytes) else { return }
        let inputData = Data(inputRead)

        switch headerCompleted {
        case false:
            assert(bodyBuffer.isEmpty)

            let parts = splitInputDataForHTTP(currentData: headerBuffer, incomingData: inputData)
            headerBuffer = parts.header
            bodyBuffer = parts.body
            headerCompleted = parts.headerCompleted

        case true:
            // into body status, header must be processed before
            bodyBuffer.append(inputData)
            writeToDownstream(context: context)
            return
        }

        guard headerCompleted else { return }

        guard let code = codeFromHeader() else {
            context.terminateChannel(reason: .upstreamUnrecognizedResponse)
            return
        }
        guard code == 200 else {
            context.terminateChannel(reason: .upstreamPassedError(code: code))
            return
        }
        scanUsage(from: bodyBuffer)
        writeToDownstream(context: context)
    }

    /// Extracts the final usage object from an SSE stream and records it once.
    /// Cheap pre-check on raw bytes avoids String conversion on every chunk.
    private func scanUsage(from data: Data) {
        guard !usageRecorded else { return }
        usageScanBuffer.append(data)
        if usageScanBuffer.count > usageScanLimit {
            usageScanBuffer = usageScanBuffer.suffix(usageScanLimit)
        }
        guard usageScanBuffer.range(of: Self.usageMarker) != nil else { return }

        guard let text = String(data: usageScanBuffer, encoding: .utf8),
              let usageRange = text.range(of: "\"usage\""),
              let braceStart = text[usageRange.upperBound...].firstIndex(of: "{")
        else { return }

        var depth = 0
        var objectEnd: String.Index?
        for index in text[braceStart...].indices {
            switch text[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { objectEnd = text.index(after: index) }
            default: break
            }
            if objectEnd != nil { break }
        }
        guard let objectEnd else { return } // incomplete object; wait for more bytes

        let objectText = String(text[braceStart ..< objectEnd])
        guard let objectData = objectText.data(using: .utf8),
              let payload = try? JSONDecoder().decode(UsagePayload.self, from: objectData),
              payload.prompt_tokens != nil || payload.completion_tokens != nil
        else {
            // Malformed usage object; drop the buffer so it cannot loop.
            usageScanBuffer = Data()
            return
        }

        UsageStatistics.shared.record(
            promptTokens: payload.prompt_tokens ?? 0,
            completionTokens: payload.completion_tokens ?? 0
        )
        usageRecorded = true
        usageScanBuffer = Data()
    }

    private struct UsagePayload: Decodable {
        let prompt_tokens: Int?
        let completion_tokens: Int?
        let total_tokens: Int?
    }

    func codeFromHeader() -> Int? {
        let header = headerBuffer
        let headerString = String(data: header, encoding: .utf8) ?? ""
        let lines = headerString.split(separator: "\r\n")
        let firstLine = lines.first ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 3 else { return nil }
        let codeString = parts[1]
        return Int(codeString)
    }

    func writeToDownstream(context: ChannelHandlerContext) {
        if !headerBuffer.isEmpty {
            let buffer = context.channel.allocator.buffer(bytes: headerBuffer)
            headerBuffer = Data()
            downstream.writeAndFlush(NIOAny(buffer), promise: nil)
        }
        if !bodyBuffer.isEmpty {
            let buffer = context.channel.allocator.buffer(bytes: bodyBuffer)
            bodyBuffer = Data()
            downstream.writeAndFlush(NIOAny(buffer), promise: nil)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        writeToDownstream(context: context)
        downstream.close(promise: nil)
    }
}
