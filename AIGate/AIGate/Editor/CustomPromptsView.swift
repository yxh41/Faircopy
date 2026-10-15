//
//  CustomPromptsView.swift
//  AIGate
//
//  Management UI for user-defined writing prompts.
//

import SwiftUI

struct CustomPromptsView: View {
    @StateObject var configuration = Configuration.shared
    @StateObject var configurationViewModel = Configuration.shared.viewModel

    @State var editingPrompt: CustomPrompt?
    @State var isAddingPrompt = false

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
                Text(NSLocalizedString(
                    "Write the instruction for the model. Keep it self-contained; the selected text is appended after it.",
                    bundle: Bundle.wrti_support,
                    comment: ""
                ))
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
