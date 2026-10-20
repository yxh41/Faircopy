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
                    if let reach = cvm.endpointReach[value.id] {
                        HStack(spacing: 4) {
                            Image(systemName: reach.reachable ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(reach.reachable ? .green : .red)
                            if let ms = reach.latencyMs {
                                Text("\(ms) ms")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if let detail = reach.detail {
                                Text(detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
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
        cvm.probeReach(value) { result in
            let message: String
            if result.reachable {
                message = NSLocalizedString("Reachable ✓", bundle: Bundle.wrti_support, comment: "")
            } else {
                message = result.detail
                    ?? String(format: NSLocalizedString("Connection failed: %@", bundle: Bundle.wrti_support, comment: ""), NSLocalizedString("no HTTP response", bundle: Bundle.wrti_support, comment: ""))
            }
            DispatchQueue.main.async {
                var next = cvm.endpointReach
                next[value.id] = result
                cvm.endpointReach = next
                testMessage = message
                showTestResult = true
            }
        }
    }
}
