//
//  AIGateHandler.swift
//  AIGate
//
//  Created by 秋星桥 on 2024/8/15.
//

import Foundation
import NIO

class AIGateHandler: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer

    let group: EventLoopGroup

    init(group: EventLoopGroup) {
        self.group = group
    }

    var upstream: AIGateUpstream?
    var headerBuffer = Data()
    var headerCompleted = false
    var bodyBuffer = Data()
    var upstreamHandler: AIGateProxyHandler?
    var upstreamHandlerReady: Bool = false
    var contentLength: Int? = nil

    func channelActive(context _: ChannelHandlerContext) {
        upstream = .init()

        headerBuffer = Data()
        headerCompleted = false
        bodyBuffer = Data()
        upstreamHandler = nil
        upstreamHandlerReady = false
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
            fireUpstreamInteractIfPossible(context: context)
            return
        }

        // once header completed
        // extract the uri to see if it is the time we shall response with file data
        // if file not found, we process to the raw tcp proxying
        guard headerCompleted else { return }

        if checkForServerCommandIfFoundInHeader() {
            context.responseWithHTTP(code: 200, json: [
                "status": "ok",
                "timestamp": String(Date().timeIntervalSince1970),
            ])
            return
        } else if checkForServerCommandIfIsGettingModelName() {
            struct Payload: Codable {
                let model: String?
                let model_list: [Configuration.Endpoint]
                let custom_prompts: [CustomPrompt]
            }
            context.responseWithHTTP(code: 200, json: Payload(
                model: Configuration.shared.activatedEndpoint?.model,
                model_list: Configuration.shared.endpointHandlerForQuickSwitch(),
                custom_prompts: Configuration.shared.allCustomPrompts
            ))
            return
        } else if checkForServerCommandIfIsGettingUsage() {
            context.responseWithHTTP(code: 200, json: UsageStatistics.shared.current())
            return
        } else if let modelID = checkForServerCommandSetModel() {
            guard Configuration.shared.hasEndpointWithID(modelID) else {
                context.terminateChannel(reason: .modelNotFound)
                return
            }
            if BootMode.current == .serviceDaemon {
                Configuration.shared.activatedEndpointID = modelID
                Configuration.shared.saveNow()
            } else {
                DispatchQueue.main.async {
                    Configuration.shared.activatedEndpointID = modelID
                    Configuration.shared.saveNow()
                    Configuration.shared.reloadValueFromSystem()
                }
            }
            context.responseWithHTTP(code: 200, json: [
                "status": "ok",
                "timestamp": String(Date().timeIntervalSince1970),
            ])
            return
        } else if checkForServerCommandIfIsErrorChecking() {
            context.responseWithHTTP(code: 480, json: [
                "last_error": ServiceError.lastError?.localizedDescription,
            ])
            ServiceError.clearLastError()
            return
        } else if !Configuration.shared.isEnabled {
            context.terminateChannel(reason: .notEnabled)
            return
        }

        guard let upstream else {
            context.terminateChannel(reason: .upstreamNotConfigured)
            return
        }

        findContentLengthInsideHeader()
        if contentLength == nil {
            patchHeaderValues(upstream: upstream, replacingContentLength: nil)
        }

        let proxyHandler = AIGateProxyHandler(upstream: upstream)
        upstreamHandler = proxyHandler
        proxyHandler.activateUpstream(downstream: context)
        context.pipeline.addHandler(proxyHandler).whenComplete { [weak self] _ in
            guard let self else { return }
            upstreamHandlerReady = true
            fireUpstreamInteractIfPossible(context: context)
        }
    }

    func fireUpstreamInteractIfPossible(context: ChannelHandlerContext) {
        guard upstreamHandlerReady else { return }
        guard let upstream else {
            context.terminateChannel(reason: .upstreamNotConfigured)
            return
        }

        if let contentLength {
            // wait until everything is received before we can send to host
            guard bodyBuffer.count >= contentLength else { return }

            // now we replace the model id inside the body if found
            replaceModelInformationFromRequestBody()

            // before sending to upstream, fix the header!
            patchHeaderValues(upstream: upstream, replacingContentLength: bodyBuffer.count)
        }

        if !headerBuffer.isEmpty {
            let buffer = context.channel.allocator.buffer(bytes: headerBuffer)
            headerBuffer = Data()
            context.fireChannelRead(NIOAny(buffer))
        }
        if !bodyBuffer.isEmpty {
            let buffer = context.channel.allocator.buffer(bytes: bodyBuffer)
            bodyBuffer = Data()
            context.fireChannelRead(NIOAny(buffer))
        }
    }

    func parseHeaderLines() -> (head: String, contents: [String]) {
        guard let header = String(data: headerBuffer, encoding: .utf8) else {
            return ("", [])
        }
        var headerLines = header
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let firstLine = headerLines.first else {
            return ("", [])
        }
        headerLines.removeFirst()
        return (firstLine, headerLines)
    }

    func findContentLengthInsideHeader() {
        for line in parseHeaderLines().contents {
            if line.lowercased().hasPrefix("Content-Length: ".lowercased()) {
                contentLength = Int(
                    line
                        .dropFirst("Content-Length: ".count)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        }
    }

    func patchHeaderValues(upstream: AIGateUpstream, replacingContentLength: Int?) {
        var headerObject = parseHeaderLines()

        var headerContents = headerObject.contents

        var tokenInjected = false

        for idx in headerContents.indices {
            if headerContents[idx].lowercased().hasPrefix("Host: ".lowercased()) {
                headerContents[idx] = "Host: \(upstream.host)"
            }
            if headerContents[idx].lowercased().hasPrefix("Origin: ".lowercased()) {
                headerContents[idx] = "Origin: \(upstream.host)"
            }
            if headerContents[idx].lowercased().hasPrefix("Referer: ".lowercased()) {
                headerContents[idx] = "Referer: \(upstream.host)"
            }
            if headerContents[idx].lowercased().hasPrefix("Connection: ".lowercased()) {
                headerContents[idx] = "Connection: close"
            }
            if headerContents[idx].lowercased().hasPrefix("Authorization: ".lowercased()) {
                headerContents[idx] = "Authorization: Bearer \(upstream.key)"
                tokenInjected = true
            }
            if headerContents[idx].lowercased().hasPrefix("Content-Length: ".lowercased()) {
                if let replacingContentLength {
                    headerContents[idx] = "Content-Length: \(replacingContentLength)"
                }
            }
        }
        if !tokenInjected {
            headerContents.append("Authorization: Bearer \(upstream.key)")
        }

        let method = headerObject.head
            .components(separatedBy: " ")
            .first ?? "GET"
        var uri = headerObject.head
            .components(separatedBy: " ")
            .dropFirst()
            .first ?? "/"
        let version = headerObject.head
            .components(separatedBy: " ")
            .dropFirst(2)
            .first ?? "HTTP/1.1"
        if upstream.url.path != "/", upstream.url.path != "" {
            var leadingPrefix = upstream.url.path
            while leadingPrefix.hasSuffix("/") {
                leadingPrefix.removeLast()
            }
            while uri.hasPrefix("/") {
                uri.removeFirst()
            }
            uri = upstream.url.path + "/" + uri
        }
        if upstream.url.host == "models.inference.ai.azure.com" {
            if uri.hasPrefix("/v1") {
                uri = String(uri.dropFirst("/v1".count))
            }
        }
        let newHead = "\(method) \(uri) \(version)"
        headerObject.head = newHead
        headerObject.contents = headerContents
        let text = headerObject.head
            + "\r\n"
            + headerObject.contents.joined(separator: "\r\n")
            + "\r\n\r\n"
        headerBuffer = Data(text.utf8)
    }

    func replaceModelInformationFromRequestBody() {
        guard var object = try? JSONSerialization.jsonObject(with: bodyBuffer, options: []) as? [String: Any] else { return }
        defer {
            if let new = try? JSONSerialization.data(withJSONObject: object, options: []) {
                bodyBuffer = new
            }
        }

        if object["model"] is String,
           let our = Configuration.shared.activatedEndpoint?.model
        { object["model"] = our }

        // Ask streaming providers to report token usage in their final SSE chunk.
        // Providers that ignore unknown fields simply never emit usage.
        if object["stream"] as? Bool == true, object["stream_options"] == nil {
            object["stream_options"] = ["include_usage": true]
        }
    }
}

extension AIGateHandler {
    func checkForServerCommandIfFoundInHeader() -> Bool {
        let headerLines = parseHeaderLines().contents
        var command: String? = nil
        var secret: String? = nil
        for line in headerLines {
            if line.hasPrefix(AIGateClient.CommandHeader.exec.rawValue) {
                command = line
                    .components(separatedBy: ":")
                    .last?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if line.hasPrefix(AIGateClient.CommandHeader.sect.rawValue) {
                secret = line
                    .components(separatedBy: ":")
                    .last?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard secret == Configuration.shared.serviceSecret,
              let command = AIGateClient.Command(rawValue: command ?? "")
        else { return false }
        command.execute()
        return true
    }

    func checkForServerCommandIfIsErrorChecking() -> Bool {
        let headerLines = parseHeaderLines().head
        if headerLines.hasPrefix("GET /metrics?query=last_error ") {
            return true
        }
        return false
    }

    func checkForServerCommandIfIsGettingModelName() -> Bool {
        let headerLines = parseHeaderLines().head
        if headerLines.hasPrefix("GET /metrics?query=model ") {
            return true
        }
        return false
    }

    func checkForServerCommandIfIsGettingModelList() -> Bool {
        let headerLines = parseHeaderLines().head
        if headerLines.hasPrefix("GET /metrics?query=model_list ") {
            return true
        }
        return false
    }

    func checkForServerCommandIfIsGettingUsage() -> Bool {
        let headerLines = parseHeaderLines().head
        if headerLines.hasPrefix("GET /metrics?query=usage ") {
            return true
        }
        return false
    }

    func checkForServerCommandSetModel() -> UUID? {
        let header = parseHeaderLines()
        let headerLines = header.head
        if !headerLines.hasPrefix("GET /action?command=set&keyword=model ") {
            return nil
        }
        let headerKey = "X-Faircopy-ModelID"
        let headerValue = header.contents
            .first { $0.hasPrefix("\(headerKey): ") }?
            .components(separatedBy: ":")
            .dropFirst()
            .joined(separator: ":")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let headerValue, let uuid = UUID(uuidString: headerValue) else {
            return nil
        }
        return uuid
    }
}
