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

    /// Rolling tail of the upstream body, split into SSE lines.
    private var usageScanBuffer = Data()
    private var usageRecorded = false
    private let usageScanLimit = 65_536

    /// 3.0.88/3.0.89: what the scan actually saw, so a response with no parsable
    /// usage can be classified after the fact instead of guessed at.
    /// `sawUsageMarker` separates "the provider never sent one" from "it sent
    /// one we could not read"; `lastUsageShape` says what that value was
    /// (`null` in every chunk means the provider ignores
    /// `stream_options.include_usage`); `upstreamEncoding` catches a compressed
    /// body; `chunkCount` and `scannedBodyBytes` say how much arrived at all.
    private var sawUsageMarker = false
    private var lastUsageShape = "absent"
    private var upstreamEncoding = "-"
    private var scannedBodyBytes = 0
    private var chunkCount = 0

    /// Upstream response code, parsed once from the header. Cached because
    /// `writeToDownstream` drains `headerBuffer` after the first chunk.
    private var upstreamCode: Int? = nil

    init(downstream: ChannelHandlerContext) {
        self.downstream = downstream
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var inputBuffer = unwrapInboundIn(data)
        guard let inputRead = inputBuffer.readBytes(length: inputBuffer.readableBytes) else { return }
        let inputData = Data(inputRead)

        if headerCompleted {
            // Body chunk after the header was consumed: keep buffering and keep
            // scanning. The trailing usage object of a streaming (SSE) response
            // arrives in one of these later chunks, so scanUsage MUST run here
            // too — returning early used to drop every usage report.
            bodyBuffer.append(inputData)
        } else {
            assert(bodyBuffer.isEmpty)
            let parts = splitInputDataForHTTP(currentData: headerBuffer, incomingData: inputData)
            headerBuffer = parts.header
            bodyBuffer = parts.body
            headerCompleted = parts.headerCompleted
        }

        guard headerCompleted else { return }

        if upstreamCode == nil {
            guard let code = codeFromHeader() else {
                context.terminateChannel(reason: .upstreamUnrecognizedResponse)
                return
            }
            upstreamCode = code
        }
        guard let code = upstreamCode else {
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

    /// Extracts the usage object from an SSE stream and records it once (3.0.89).
    ///
    /// The old byte scan looked for the first `"usage"` literal, then for the
    /// next `{`. That is wrong the moment a provider writes `"usage": null` in
    /// every chunk - which most do, and only the final chunk carries the real
    /// numbers - because the brace it found belonged to the *next* chunk. The
    /// slice decoded into a perfectly valid object with no numbers, the buffer
    /// was cleared to stop it looping, and the next chunk repeated the same
    /// mistake. One response logged that fourteen times and never reached the
    /// numbers. Parsing line by line is what an SSE stream actually is, and it
    /// turns `"usage": null` into a no-op instead of a trap.
    private func scanUsage(from data: Data) {
        guard !usageRecorded else { return }
        scannedBodyBytes += data.count
        chunkCount += 1
        usageScanBuffer.append(data)
        // Consume complete lines; the unterminated tail waits for the next chunk.
        while let newline = usageScanBuffer.firstIndex(of: 0x0A) {
            let line = Data(usageScanBuffer[usageScanBuffer.startIndex ..< newline])
            usageScanBuffer.removeSubrange(usageScanBuffer.startIndex ... newline)
            if scanUsageLine(line) { return }
        }
        if usageScanBuffer.count > usageScanLimit {
            usageScanBuffer = usageScanBuffer.suffix(usageScanLimit)
        }
    }

    /// One SSE line (`data: {...}`), or a whole non-streaming body.
    ///
    /// Returns true once a usage object with numbers has been recorded.
    private func scanUsageLine(_ line: Data) -> Bool {
        guard !line.isEmpty, let raw = String(data: line, encoding: .utf8) else { return false }
        var text = raw
        if text.hasPrefix("data:") {
            text = String(text.dropFirst(5))
        } else if text.hasPrefix(":") || text.hasPrefix("event:") || text.hasPrefix("id:") {
            return false // comment / heartbeat / metadata
        }
        text = text.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("{"),
              let payloadData = text.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: payloadData),
              let object = parsed as? [String: Any],
              let usage = object["usage"]
        else { return false }

        sawUsageMarker = true
        guard let numbers = usage as? [String: Any] else {
            lastUsageShape = (usage is NSNull) ? "null" : "notobject"
            return false
        }
        lastUsageShape = "object"
        // 3.0.88: providers built on the newer API surface report
        // `input_tokens`/`output_tokens` for the same two numbers.
        let prompt = (numbers["prompt_tokens"] as? Int) ?? (numbers["input_tokens"] as? Int)
        let completion = (numbers["completion_tokens"] as? Int) ?? (numbers["output_tokens"] as? Int)
        guard prompt != nil || completion != nil else { return false }

        UsageStatistics.shared.record(
            promptTokens: prompt ?? 0,
            completionTokens: completion ?? 0
        )
        usageRecorded = true
        return true
    }

    private func describeScan() -> String {
        "enc=\(upstreamEncoding) marker=\(sawUsageMarker ? 1 : 0) usage=\(lastUsageShape)"
            + " chunks=\(chunkCount) body=\(scannedBodyBytes)"
    }

    func codeFromHeader() -> Int? {
        let header = headerBuffer
        let headerString = String(data: header, encoding: .utf8) ?? ""
        let lines = headerString.split(separator: "\r\n")
        let firstLine = lines.first ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 3 else { return nil }
        // 3.0.88: remembered for the usage diagnostic — a compressed body hides
        // the `"usage"` literal from the byte scan entirely, which would look
        // exactly like a provider that never reports usage.
        for line in lines.dropFirst() {
            guard line.lowercased().hasPrefix("content-encoding:") else { continue }
            let value = line.split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""
            let encoding = value.trimmingCharacters(in: .whitespaces)
            if !encoding.isEmpty { upstreamEncoding = encoding.lowercased() }
        }
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
        // Fallback accounting: a 200 response that never carried a parsable
        // usage object (relay without include_usage support, or a stream cut
        // short) still consumed a request. Count it with zero tokens so the
        // usage panel's request count stays honest; tokens stay 0 because the
        // provider never reported them.
        if !usageRecorded, upstreamCode == 200 {
            // A non-streaming answer is a single JSON document with no trailing
            // newline, so it is still sitting in the tail when the channel
            // closes. One last attempt before accounting for the request.
            _ = scanUsageLine(usageScanBuffer)
        }
        if !usageRecorded, upstreamCode == 200 {
            // 3.0.88/3.0.89: record why the tokens are zeros. The panel can only
            // show the accumulated numbers, and "0 tokens but the request
            // counted" is produced by a provider that reports nothing, by one
            // whose `usage` is `null` in every chunk, and by a compressed body —
            // the diagnostic tells them apart.
            UsageStatistics.appendDiagnostic("usage: no numbers reported " + describeScan())
            UsageStatistics.shared.record(promptTokens: 0, completionTokens: 0)
            usageRecorded = true
        }
        writeToDownstream(context: context)
        downstream.close(promise: nil)
    }
}
