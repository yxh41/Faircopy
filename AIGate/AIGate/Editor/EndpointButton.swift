//
//  EndpointButton.swift
//  AIGate
//
//  Created by 秋星桥 on 2024/8/15.
//

import Foundation
import SwiftUI

struct EndpointButton: View {
    @StateObject var cvm: Configuration = .shared
    let value: Configuration.Endpoint

    @State private var openDuplicate = false
    @State private var openEdit = false
    @State private var testMessage: String? = nil
    @State private var showTestResult = false

    init(endpoint: Configuration.Endpoint) {
        value = endpoint
    }

    var body: some View {
        Button {
            cvm.activatedEndpointID = value.id
        } label: {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(value.model)
                        .tint(.primary)
                        .foregroundStyle(.primary)
                    Text(value.url.host ?? value.url.absoluteString)
                        .font(.footnote)
                        .tint(.secondary)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "checkmark")
                    .opacity(cvm.activatedEndpointID == value.id ? 1 : 0)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                withAnimation {
                    cvm.remove(value)
                }
            } label: {
                Label(NSLocalizedString("Delete", bundle: Bundle.wrti_support, comment: ""), systemImage: "trash")
            }
            .tint(.red)
        }
        .contextMenu {
            if cvm.activatedEndpointID != value.id {
                Button {
                    cvm.activatedEndpointID = value.id
                } label: {
                    Label(NSLocalizedString("Activate", bundle: Bundle.wrti_support, comment: ""), systemImage: "checkmark")
                }
            } else {
                Button {
                    cvm.activatedEndpointID = Configuration.noneActivated
                } label: {
                    Label(NSLocalizedString("Deactivate", bundle: Bundle.wrti_support, comment: ""), systemImage: "xmark")
                }
            }
            Button {
                openDuplicate = true
            } label: {
                Label(NSLocalizedString("Duplicate", bundle: Bundle.wrti_support, comment: ""), systemImage: "doc.on.doc")
            }
            Button {
                openEdit = true
            } label: {
                Label(NSLocalizedString("Edit", bundle: Bundle.wrti_support, comment: ""), systemImage: "pencil")
            }
            Button {
                testConnection()
            } label: {
                Label(NSLocalizedString("Test Connection", bundle: Bundle.wrti_support, comment: ""), systemImage: "waveform")
            }
            Section {
                Button {
                    UIPasteboard.general.string = value.url.absoluteString
                } label: {
                    Label(NSLocalizedString("Copy URL", bundle: Bundle.wrti_support, comment: ""), systemImage: "link")
                }
                Button {
                    UIPasteboard.general.string = value.token
                } label: {
                    Label(NSLocalizedString("Copy Token", bundle: Bundle.wrti_support, comment: ""), systemImage: "key")
                }
                Button {
                    UIPasteboard.general.string = value.model
                } label: {
                    Label(NSLocalizedString("Copy Model", bundle: Bundle.wrti_support, comment: ""), systemImage: "doc.text")
                }
            }
            Section {
                Button(role: .destructive) {
                    cvm.remove(value)
                } label: {
                    Label(NSLocalizedString("Delete", bundle: Bundle.wrti_support, comment: ""), systemImage: "trash")
                }
            }
        }
        .sheet(isPresented: $openDuplicate) {
            NavigationView {
                AddEndpointView(prefillURL: value.url.absoluteString, prefillKey: value.token)
                    .navigationBarTitleDisplayMode(.inline)
            }
            .navigationViewStyle(.stack)
        }
        .sheet(isPresented: $openEdit) {
            NavigationView {
                AddEndpointView(prefillURL: value.url.absoluteString, prefillKey: value.token, editing: value)
                    .navigationBarTitleDisplayMode(.inline)
            }
            .navigationViewStyle(.stack)
        }
        .alert(NSLocalizedString("Test Connection", bundle: Bundle.wrti_support, comment: ""), isPresented: $showTestResult) {
            Button(NSLocalizedString("OK", bundle: Bundle.wrti_support, comment: ""), role: .cancel) { }
        } message: {
            Text(testMessage ?? "")
        }
    }

    func testConnection() {
        let base = value.url
        let key = value.token
        DispatchQueue.global(qos: .userInitiated).async {
            var message = ""
            let targets = [
                base.appendingPathComponent("v1").appendingPathComponent("models"),
                base.appendingPathComponent("models"),
            ]
            for target in targets {
                var req = URLRequest(url: target, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 20)
                if !key.isEmpty {
                    req.addValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                }
                let sem = DispatchSemaphore(value: 0)
                var outcome = ""
                URLSession.shared.dataTask(with: req) { _, resp, err in
                    defer { sem.signal() }
                    if let err {
                        outcome = String(format: NSLocalizedString("Connection failed: %@", bundle: Bundle.wrti_support, comment: ""), err.localizedDescription)
                        return
                    }
                    if let http = resp as? HTTPURLResponse {
                        if http.statusCode == 200 {
                            outcome = NSLocalizedString("Reachable ✓", bundle: Bundle.wrti_support, comment: "")
                        } else {
                            outcome = String(format: NSLocalizedString("Connection failed: %@", bundle: Bundle.wrti_support, comment: ""), "HTTP \(http.statusCode)")
                        }
                    } else {
                        outcome = String(format: NSLocalizedString("Connection failed: %@", bundle: Bundle.wrti_support, comment: ""), NSLocalizedString("no HTTP response", bundle: Bundle.wrti_support, comment: ""))
                    }
                }.resume()
                sem.wait()
                if !outcome.isEmpty {
                    message = outcome
                    break
                }
            }
            if message.isEmpty {
                message = String(format: NSLocalizedString("Connection failed: %@", bundle: Bundle.wrti_support, comment: ""), NSLocalizedString("no HTTP response", bundle: Bundle.wrti_support, comment: ""))
            }
            let final = message
            DispatchQueue.main.async {
                testMessage = final
                showTestResult = true
            }
        }
    }
}
