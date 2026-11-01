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

    /// 3.0.88: what the scan actually saw, so a response with no parsable usage
    /// can be classified after the fact instead of guessed at. `sawUsageMarker`
    /// separates "the provider never sent one" from "it sent one we could not
    /// read"; `upstreamEncoding` catches a compressed body the byte scan cannot
    /// see; `scannedBodyBytes` says whether there was a body at all.
    private var sawUsageMarker = false
    private var upstreamEncoding = "-"
    private var scannedBodyBytes = 0

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

    /// Extracts the final usage object from an SSE stream and records it once.
    /// Cheap pre-check on raw bytes avoids String conversion on every chunk.
    private func scanUsage(from data: Data) {
        guard !usageRecorded else { return }
        scannedBodyBytes += data.count
        usageScanBuffer.append(data)
        if usageScanBuffer.count > usageScanLimit {
            usageScanBuffer = usageScanBuffer.suffix(usageScanLimit)
        }
        guard usageScanBuffer.range(of: Self.usageMarker) != nil else { return }
        sawUsageMarker = true

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
        guard let objectData = objectText.data(using: .utf8) else {
            usageScanBuffer = Data()
            return
        }
        guard let payload = try? JSONDecoder().decode(UsagePayload.self, from: objectData) else {
            // Malformed usage object; drop the buffer so it cannot loop, and
            // leave a trace: this is the case where a provider reports usage
            // under names this build does not know.
            UsageStatistics.appendDiagnostic(
                "usage: undecodable \(describeScan()) keys=\(Self.tokenKeyNames(in: objectData))")
            usageScanBuffer = Data()
            return
        }
        // 3.0.88: providers built on the newer API surface report
        // `input_tokens`/`output_tokens` instead of `prompt_tokens`/
        // `completion_tokens`. Both shapes describe the same two numbers.
        let prompt = payload.prompt_tokens ?? payload.input_tokens
        let completion = payload.completion_tokens ?? payload.output_tokens
        guard prompt != nil || completion != nil else {
            UsageStatistics.appendDiagnostic(
                "usage: empty \(describeScan()) keys=\(Self.tokenKeyNames(in: objectData))")
            usageScanBuffer = Data()
            return
        }

        UsageStatistics.shared.record(
            promptTokens: prompt ?? 0,
            completionTokens: completion ?? 0
        )
        usageRecorded = true
        usageScanBuffer = Data()
    }

    private struct UsagePayload: Decodable {
        let prompt_tokens: Int?
        let completion_tokens: Int?
        let total_tokens: Int?
        let input_tokens: Int?
        let output_tokens: Int?
    }

    /// The `*_tokens` key names present in a body, deduplicated, capped.
    ///
    /// Only names are kept — never values, and never the surrounding text — so
    /// the diagnostic cannot leak what the user was writing.
    private static func tokenKeyNames(in data: Data) -> String {
        guard let text = String(data: data, encoding: .utf8) else { return "unreadable" }
        guard let regex = try? NSRegularExpression(pattern: "\"([a-zA-Z_]*tokens)\"") else {
            return "none"
        }
        let range = NSRange(text.startIndex..., in: text)
        var names: [String] = []
        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match, let matchRange = Range(match.range(at: 1), in: text) else { return }
            let name = String(text[matchRange])
            if !names.contains(name) { names.append(name) }
        }
        return names.isEmpty ? "none" : names.prefix(5).joined(separator: ",")
    }

    private func describeScan() -> String {
        "enc=\(upstreamEncoding) marker=\(sawUsageMarker ? 1 : 0) body=\(scannedBodyBytes)"
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
            // 3.0.88: record why the tokens are zeros. The panel can only show
            // the accumulated numbers, and "0 tokens but the request counted"
            // is produced by a provider that reports nothing, by one that
            // reports under other key names, and by a compressed body the scan
            // cannot read — the diagnostic tells them apart.
            UsageStatistics.appendDiagnostic(
                "usage: missing \(describeScan()) keys=\(Self.tokenKeyNames(in: usageScanBuffer))")
            UsageStatistics.shared.record(promptTokens: 0, completionTokens: 0)
            usageRecorded = true
        }
        writeToDownstream(context: context)
        downstream.close(promise: nil)
    }
}
