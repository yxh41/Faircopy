//
//  ServiceError.swift
//  AIGate
//
//  Created by 秋星桥 on 2024/8/22.
//

import Foundation
import NIO

enum ServiceError: Error {
    case notEnabled
    case modelNotFound
    case upstreamNotConfigured
    case upstreamNotReachable
    case upstreamPassedError(code: Int)
    case upstreamUnrecognizedResponse
}

extension ServiceError {
    static var lastError: ServiceError?

    static func clearLastError() {
        ServiceError.lastError = nil
    }
}

// Provide richer, localized HTTP status texts than HTTPURLResponse.localizedString(forStatusCode:)
private func wrtiHTTPStatusText(_ code: Int) -> String {
    let B = Bundle.wrti_support
    switch code {
    // 1xx Informational
    case 100: return NSLocalizedString("Continue", bundle: B, comment: "HTTP 100")
    case 101: return NSLocalizedString("Switching Protocols", bundle: B, comment: "HTTP 101")
    case 102: return NSLocalizedString("Processing", bundle: B, comment: "HTTP 102")
    case 103: return NSLocalizedString("Early Hints", bundle: B, comment: "HTTP 103")

    // 2xx Success
    case 200: return NSLocalizedString("OK", bundle: B, comment: "HTTP 200")
    case 201: return NSLocalizedString("Created", bundle: B, comment: "HTTP 201")
    case 202: return NSLocalizedString("Accepted", bundle: B, comment: "HTTP 202")
    case 203: return NSLocalizedString("Non-Authoritative Information", bundle: B, comment: "HTTP 203")
    case 204: return NSLocalizedString("No Content", bundle: B, comment: "HTTP 204")
    case 205: return NSLocalizedString("Reset Content", bundle: B, comment: "HTTP 205")
    case 206: return NSLocalizedString("Partial Content", bundle: B, comment: "HTTP 206")
    case 207: return NSLocalizedString("Multi-Status", bundle: B, comment: "HTTP 207")
    case 208: return NSLocalizedString("Already Reported", bundle: B, comment: "HTTP 208")
    case 226: return NSLocalizedString("IM Used", bundle: B, comment: "HTTP 226")

    // 3xx Redirection
    case 300: return NSLocalizedString("Multiple Choices", bundle: B, comment: "HTTP 300")
    case 301: return NSLocalizedString("Moved Permanently", bundle: B, comment: "HTTP 301")
    case 302: return NSLocalizedString("Found", bundle: B, comment: "HTTP 302")
    case 303: return NSLocalizedString("See Other", bundle: B, comment: "HTTP 303")
    case 304: return NSLocalizedString("Not Modified", bundle: B, comment: "HTTP 304")
    case 305: return NSLocalizedString("Use Proxy", bundle: B, comment: "HTTP 305")
    case 306: return NSLocalizedString("Switch Proxy", bundle: B, comment: "HTTP 306 (unused)")
    case 307: return NSLocalizedString("Temporary Redirect", bundle: B, comment: "HTTP 307")
    case 308: return NSLocalizedString("Permanent Redirect", bundle: B, comment: "HTTP 308")

    // 4xx Client errors
    case 400: return NSLocalizedString("Bad Request", bundle: B, comment: "HTTP 400")
    case 401: return NSLocalizedString("Unauthorized", bundle: B, comment: "HTTP 401")
    case 402: return NSLocalizedString("Payment Required", bundle: B, comment: "HTTP 402")
    case 403: return NSLocalizedString("Forbidden", bundle: B, comment: "HTTP 403")
    case 404: return NSLocalizedString("Not Found", bundle: B, comment: "HTTP 404")
    case 405: return NSLocalizedString("Method Not Allowed", bundle: B, comment: "HTTP 405")
    case 406: return NSLocalizedString("Not Acceptable", bundle: B, comment: "HTTP 406")
    case 407: return NSLocalizedString("Proxy Authentication Required", bundle: B, comment: "HTTP 407")
    case 408: return NSLocalizedString("Request Timeout", bundle: B, comment: "HTTP 408")
    case 409: return NSLocalizedString("Conflict", bundle: B, comment: "HTTP 409")
    case 410: return NSLocalizedString("Gone", bundle: B, comment: "HTTP 410")
    case 411: return NSLocalizedString("Length Required", bundle: B, comment: "HTTP 411")
    case 412: return NSLocalizedString("Precondition Failed", bundle: B, comment: "HTTP 412")
    case 413: return NSLocalizedString("Payload Too Large", bundle: B, comment: "HTTP 413")
    case 414: return NSLocalizedString("URI Too Long", bundle: B, comment: "HTTP 414")
    case 415: return NSLocalizedString("Unsupported Media Type", bundle: B, comment: "HTTP 415")
    case 416: return NSLocalizedString("Range Not Satisfiable", bundle: B, comment: "HTTP 416")
    case 417: return NSLocalizedString("Expectation Failed", bundle: B, comment: "HTTP 417")
    case 418: return NSLocalizedString("I'm a teapot", bundle: B, comment: "HTTP 418")
    case 421: return NSLocalizedString("Misdirected Request", bundle: B, comment: "HTTP 421")
    case 422: return NSLocalizedString("Unprocessable Content", bundle: B, comment: "HTTP 422")
    case 423: return NSLocalizedString("Locked", bundle: B, comment: "HTTP 423")
    case 424: return NSLocalizedString("Failed Dependency", bundle: B, comment: "HTTP 424")
    case 425: return NSLocalizedString("Too Early", bundle: B, comment: "HTTP 425")
    case 426: return NSLocalizedString("Upgrade Required", bundle: B, comment: "HTTP 426")
    case 428: return NSLocalizedString("Precondition Required", bundle: B, comment: "HTTP 428")
    case 429: return NSLocalizedString("Too Many Requests", bundle: B, comment: "HTTP 429")
    case 431: return NSLocalizedString("Request Header Fields Too Large", bundle: B, comment: "HTTP 431")
    case 451: return NSLocalizedString("Unavailable For Legal Reasons", bundle: B, comment: "HTTP 451")

    // 5xx Server errors
    case 500: return NSLocalizedString("Internal Server Error", bundle: B, comment: "HTTP 500")
    case 501: return NSLocalizedString("Not Implemented", bundle: B, comment: "HTTP 501")
    case 502: return NSLocalizedString("Bad Gateway", bundle: B, comment: "HTTP 502")
    case 503: return NSLocalizedString("Service Unavailable", bundle: B, comment: "HTTP 503")
    case 504: return NSLocalizedString("Gateway Timeout", bundle: B, comment: "HTTP 504")
    case 505: return NSLocalizedString("HTTP Version Not Supported", bundle: B, comment: "HTTP 505")
    case 506: return NSLocalizedString("Variant Also Negotiates", bundle: B, comment: "HTTP 506")
    case 507: return NSLocalizedString("Insufficient Storage", bundle: B, comment: "HTTP 507")
    case 508: return NSLocalizedString("Loop Detected", bundle: B, comment: "HTTP 508")
    case 510: return NSLocalizedString("Not Extended", bundle: B, comment: "HTTP 510")
    case 511: return NSLocalizedString("Network Authentication Required", bundle: B, comment: "HTTP 511")

    // Fallbacks
    case 100..<200: return NSLocalizedString("Informational", bundle: B, comment: "HTTP 1xx")
    case 200..<300: return NSLocalizedString("Success", bundle: B, comment: "HTTP 2xx")
    case 300..<400: return NSLocalizedString("Redirection", bundle: B, comment: "HTTP 3xx")
    case 400..<500: return NSLocalizedString("Client Error", bundle: B, comment: "HTTP 4xx")
    case 500..<600: return NSLocalizedString("Server Error", bundle: B, comment: "HTTP 5xx")
    default:
        // As an ultimate fallback, keep system text in case a future code appears.
        let system = HTTPURLResponse.localizedString(forStatusCode: code)
        if system.isEmpty || system == "(null)" {
            return String(format: NSLocalizedString("Status %d", bundle: B, comment: "Unknown HTTP status"), code)
        }
        return system
    }
}

extension ServiceError: LocalizedError {
    var localizedDescription: String? {
        switch self {
        case .notEnabled:
            NSLocalizedString("Service Disabled", bundle: Bundle.wrti_support, comment: "")
        case .modelNotFound:
            NSLocalizedString("Model Not Found", bundle: Bundle.wrti_support, comment: "")
        case .upstreamNotConfigured:
            NSLocalizedString("Endpoint Not Configured", bundle: Bundle.wrti_support, comment: "")
        case .upstreamNotReachable:
            NSLocalizedString("Endpoint Not Reachable", bundle: Bundle.wrti_support, comment: "")
        case let .upstreamPassedError(code):
            String(
                format: NSLocalizedString("Endpoint Error: %d %@", bundle: Bundle.wrti_support, comment: ""),
                code, wrtiHTTPStatusText(code)
            )
        case .upstreamUnrecognizedResponse:
            NSLocalizedString("Invalid Response", bundle: Bundle.wrti_support, comment: "")
        }
    }
}

extension ChannelHandlerContext {
    func terminateChannel(reason: ServiceError) {
        ServiceError.lastError = reason
        let reasonText = ["ErrorDescription": reason.localizedDescription]
        var code = 480
        if case let .upstreamPassedError(code: c) = reason { code = c }
        responseWithHTTP(code: code, json: reasonText)
    }
}
