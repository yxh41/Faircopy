//
//  TestTextView.swift
//  AIGate
//
//  Created by 秋星桥 on 2024/8/18.
//

import MessageUI
import SwiftUI
import UIKit

private let testText = """
It was a Christmas Eve with heavy snow. A little girl was selling matches on the street. "Matches, matches!"

But no one looked at her. She had lost her parents a few days ago, and she was selling matches without a coat in the cold weather. She didn't even sell one box. The girl was so hungry that she couldn't even open her mouth.

Then, a carriage came close to her. Trying to keep away from the carriage, she slipped and fell on the ice, and she lost her shoes. She had to walk on the snowy street with bare feet.
"""
private let openToolNotification = Notification.Name(UUID().uuidString)

struct TestTextView: View {
    @State var text: String = testText

    var body: some View {
        TextEditorView(text: $text)
            .toolbar {
                ToolbarItem {
                    Button {
                        text = UIPasteboard.general.string ?? ""
                        NotificationCenter.default.post(name: openToolNotification, object: nil)
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                    }
                    .foregroundStyle(Color.accent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(NSLocalizedString("Test Scene", bundle: Bundle.wrti_support, comment: ""))
            .navigationBarTitleDisplayMode(.inline)
    }
}

class TextEditorViewCoordinator: NSObject, UITextViewDelegate {
    @Binding var text: String

    weak var textView: UITextView?

    init(text: Binding<String>) {
        _text = text

        super.init()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openTools),
            name: openToolNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func textViewDidChange(_ textView: UITextView) {
        text = textView.text
    }

    @objc func openTools() {
        guard let textView else { return }
        textView.selectAll(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            self.openToolsPanel(withTextView: textView)
        }
    }

    func openToolsPanel(withTextView textView: UITextView) {
        let instanceSel = NSSelectorFromString("sharedInstance")
        let openSel = NSSelectorFromString("presentToolController:")
        guard let cls = NSClassFromString("WritingToolsPresenter") as? NSObject.Type,
              cls.responds(to: instanceSel),
              let shared = cls.perform(instanceSel)?.takeUnretainedValue() as? NSObject,
              shared.responds(to: openSel)
        else { return }
        shared.perform(openSel, with: textView)
    }
}

struct TextEditorView: UIViewRepresentable {
    @Binding var text: String

    init(text: Binding<String>) {
        _text = text
    }

    func makeCoordinator() -> TextEditorViewCoordinator {
        .init(text: $text)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = true
        textView.isSelectable = true
        textView.font = .preferredFont(forTextStyle: .body)
        textView.text = testText
        textView.delegate = context.coordinator
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        textView.tintColor = UIColor.accent
        context.coordinator.textView = textView
        DispatchQueue.main.async { textView.becomeFirstResponder() }
        return textView
    }

    func updateUIView(_ view: UITextView, context _: Context) {
        if view.text != text { view.text = text }
    }
}

// https://stackoverflow.com/questions/56784722/swiftui-send-email
struct MailView: UIViewControllerRepresentable {
    @Environment(\.presentationMode) var presentation
    @Binding var result: Result<MFMailComposeResult, Error>?
    public var configure: ((MFMailComposeViewController) -> Void)?

    public class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        @Binding var presentation: PresentationMode
        @Binding var result: Result<MFMailComposeResult, Error>?

        init(presentation: Binding<PresentationMode>,
             result: Binding<Result<MFMailComposeResult, Error>?>)
        {
            _presentation = presentation
            _result = result
        }

        public func mailComposeController(_: MFMailComposeViewController,
                                          didFinishWith result: MFMailComposeResult,
                                          error: Error?)
        {
            defer {
                $presentation.wrappedValue.dismiss()
            }
            guard error == nil else {
                self.result = .failure(error!)
                return
            }
            self.result = .success(result)
        }
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(presentation: presentation, result: $result)
    }

    public func makeUIViewController(context: UIViewControllerRepresentableContext<MailView>) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.mailComposeDelegate = context.coordinator
        configure?(vc)
        return vc
    }

    public func updateUIViewController(
        _: MFMailComposeViewController,
        context _: UIViewControllerRepresentableContext<MailView>
    ) {}
}
