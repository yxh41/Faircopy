//
//  CustomPromptsView.swift
//  AIGate
//
//  Management UI for user-defined writing prompts.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct CustomPromptsView: View {
    @StateObject var configuration = Configuration.shared
    @StateObject var configurationViewModel = Configuration.shared.viewModel

    @State var editingPrompt: CustomPrompt?
    @State var isAddingPrompt = false

    @State var showExport = false
    @State var showImport = false
    @State var exportURL: URL?

    var body: some View {
        Form {
            Section {
                ForEach(configurationViewModel.uiCustomPrompts) { prompt in
                    Button {
                        editingPrompt = prompt
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(prompt.title)
                                .foregroundStyle(.primary)
                            Text(prompt.prompt)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
                .onDelete { indexSet in
                    let prompts = configurationViewModel.uiCustomPrompts
                    for index in indexSet {
                        configuration.removeCustomPrompt(prompts[index])
                    }
                }
                Button {
                    isAddingPrompt = true
                } label: {
                    Text(NSLocalizedString("Add Custom Prompt", bundle: Bundle.wrti_support, comment: ""))
                }
                .foregroundStyle(Color.accent)
            } header: {
                Text(NSLocalizedString("Custom Prompts", bundle: Bundle.wrti_support, comment: ""))
            } footer: {
                Text(NSLocalizedString(
                    "Custom prompts appear in the writing panel next to the built-in modes. The selected text is appended after your prompt.",
                    bundle: Bundle.wrti_support,
                    comment: ""
                ))
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 16) {
                    Button {
                        exportPrompts()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    Button {
                        showImport = true
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                }
            }
        }
        .sheet(isPresented: $showExport) {
            if let exportURL {
                ShareSheet(items: [exportURL])
            }
        }
        .fileImporter(
            isPresented: $showImport,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            do {
                guard let url = try result.get().first else { return }
                let data = try Data(contentsOf: url)
                let prompts = try JSONDecoder().decode([CustomPrompt].self, from: data)
                configuration.importCustomPrompts(prompts)
            } catch {
                print("[*] import custom prompts failed: \(error)")
            }
        }
        .sheet(isPresented: $isAddingPrompt) {
            NavigationView {
                CustomPromptEditor(prompt: CustomPrompt(title: "", prompt: ""))
            }
            .navigationViewStyle(.stack)
        }
        .sheet(isPresented: Binding(
            get: { editingPrompt != nil },
            set: { if !$0 { editingPrompt = nil } }
        )) {
            if let editingPrompt {
                NavigationView {
                    CustomPromptEditor(prompt: editingPrompt)
                }
                .navigationViewStyle(.stack)
            }
        }
    }

    private func exportPrompts() {
        let prompts = configuration.allCustomPrompts
        guard let data = try? JSONEncoder().encode(prompts),
              let url = FileManager.default
                  .urls(for: .documentDirectory, in: .userDomainMask)
                  .first?
                  .appendingPathComponent("faircopy-prompts.json")
        else { return }
        try? data.write(to: url, options: .atomic)
        exportURL = url
        showExport = true
    }
}

/// Wraps UIActivityViewController for sharing the exported prompts file.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct CustomPromptEditor: View {
    @State var prompt: CustomPrompt
    @Environment(\.dismiss) var dismiss
    @StateObject var configuration = Configuration.shared

    var body: some View {
        Form {
            Section {
                TextField(
                    NSLocalizedString("Title", bundle: Bundle.wrti_support, comment: ""),
                    text: $prompt.title
                )
            } header: {
                Text(NSLocalizedString("Title", bundle: Bundle.wrti_support, comment: ""))
            }
            Section {
                TextEditor(text: $prompt.prompt)
                    .frame(minHeight: 220)
            } header: {
                Text(NSLocalizedString("Prompt", bundle: Bundle.wrti_support, comment: ""))
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(NSLocalizedString(
                        "Write the instruction for the model. Keep it self-contained; the selected text is appended after it.",
                        bundle: Bundle.wrti_support,
                        comment: ""
                    ))
                    Text("可用占位符：\("{{selection}}") 选中文本 · \("{{clipboard}}") 剪贴板 · \("{{language}}") 自动检测语言")
                        .font(.caption)
                }
            }
        }
        .navigationTitle(prompt.title.isEmpty
            ? NSLocalizedString("New Prompt", bundle: Bundle.wrti_support, comment: "")
            : prompt.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(NSLocalizedString("Save", bundle: Bundle.wrti_support, comment: "")) {
                    save()
                }
                .disabled(!canSave)
            }
        }
    }

    var canSave: Bool {
        !prompt.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !prompt.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        var trimmed = prompt
        trimmed.title = prompt.title.trimmingCharacters(in: .whitespacesAndNewlines)
        trimmed.prompt = prompt.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if configuration.hasCustomPrompt(withID: trimmed.id) {
            configuration.updateCustomPrompt(trimmed)
        } else {
            configuration.addCustomPrompt(trimmed)
        }
        dismiss()
    }
}
