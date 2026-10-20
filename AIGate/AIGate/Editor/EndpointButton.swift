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
    }
}
