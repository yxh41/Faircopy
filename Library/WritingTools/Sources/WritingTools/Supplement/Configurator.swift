//
//  Configurator.swift
//  WritingTools
//
//  Created by 秋星桥 on 2024/8/8.
//

import Combine
import Foundation
import OpenAI

public class Configurator: ObservableObject {
    public static let shared = Configurator()

    public let openAI: OpenAI = .init(configuration: .init(
        token: "user_activated_token",
        host: "127.0.0.1",
        port: 5540,
        scheme: "http",
        timeoutInterval: 30
    ))

    public let mid: String = "user_activated_model"

    // ➜  Faircopy git:(main) ✗ curl http://127.0.0.1:5540/metrics\?query=last_error -v
    // < HTTP/1.1 480 Application Defined Code >
    // {"last_error":"上游节点返回错误: 404"}%
    public let gateErrorCheckRequest: URLRequest = {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:5540/metrics?query=last_error")!)
        request.httpMethod = "GET"
        return request
    }()

    public let gateModelCheckRequest: URLRequest = {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:5540/metrics?query=model")!)
        request.httpMethod = "GET"
        return request
    }()

    public let gateUsageCheckRequest: URLRequest = {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:5540/metrics?query=usage")!)
        request.httpMethod = "GET"
        return request
    }()

    public let gateModelSetRequest: URLRequest = {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:5540/action?command=set&keyword=model")!)
        request.httpMethod = "GET"
        return request
    }()
}
