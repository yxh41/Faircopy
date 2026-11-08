//
//  WritingToolsView+Header.swift
//  WritingTools
//
//  Created by 秋星桥 on 2024/8/8.
//

import SwiftUI
import UIKit

extension WritingToolsView {
    var selectedTextCount: Int {
        textProxy.selectedText.count
    }

    var textCountDescription: String {
        selectedTextCount > 1
            ? String(format: "%d characters".localized, selectedTextCount)
            : String(format: "%d character".localized, selectedTextCount)
    }

    var shortenModelName: String {
        model
            .components(separatedBy: "/")
            .last?
            .components(separatedBy: ":")
            .first
            ?? ""
    }

    /// 3.0.124: brand mark instead of the app name.
    ///
    /// 「清稿」/「Faircopy」 cost about 40 pt at title3-bold, and the
    /// description beside it (character count + model name) is the thing that
    /// actually gets truncated first. A symbol gives that space back.
    ///
    /// 3.0.126: drawn from points, not looked up in the symbol table.
    ///
    /// Two attempts went into the bin first. 3.0.124 shipped
    /// `pencil.and.scribble` (SF Symbols 4, iOS 16) into a panel that also has
    /// to run on 15.x, and `Image(systemName:)` draws *nothing* for a name the
    /// OS does not know — no placeholder, no warning, no log. 3.0.125 then
    /// asked `UIImage(systemName:)` first and fell back to the app name, and
    /// the header was STILL an empty gap on 16.4.1. So the failure was never
    /// the symbol table: an `Image` left to the `HStack` can be compressed to
    /// zero width by the flexible marquee next to it, while `Text` keeps a
    /// non-zero minimum — which is why the name survived until 3.0.123 and
    /// everything after it read as "the mark is not there".
    ///
    /// A filled `Path` inside a fixed 20 pt frame can neither be compressed to
    /// nothing nor miss a symbol on some OS version. It stops depending on the
    /// system glyph table altogether.
    var brandMark: some View {
        BrandPencil()
            .frame(width: 20, height: 20)
            // Belt and braces: the frame already pins the size, but this stops
            // the marquee beside it from re-negotiating that size on layout.
            .fixedSize()
            .layoutPriority(1)
            // A glyph carries no text, so without a label VoiceOver stops
            // announcing which app this panel belongs to — the one piece of
            // information the app name was carrying. Kept localized on purpose.
            .accessibilityLabel("Faircopy".localized)
    }

    var title: some View {
        HStack(alignment: .bottom, spacing: 8) {
            brandMark
            MarqueeText(
                text: $headerDescription,
                isAnimated: $isHeaderDescriptionAnimated,
                font: UIFont.preferredFont(forTextStyle: .footnote),
                leftFade: 8,
                rightFade: 8,
                startDelay: 2
            )
            .opacity(0.25)
            .overlay {
                modelSelectionMenu.padding(-4)
            }
            closeButton
        }
        .animation(.spring, value: model)
        .animation(.spring, value: selectedTextCount)
        .onAppear {
            // 3.0.126: one line so a log can prove which build drew this
            // header. Three releases of "the mark is not there" were spent
            // guessing between "wrong symbol", "compressed to zero" and "this
            // view is not the one on screen"; this settles it in one look.
            // NSLog rather than print: the panel runs inside another app's
            // process, and only NSLog reliably reaches the device syslog.
            NSLog("[Faircopy] header mark: pencil drawn from path")
            checkModelName()
            fetchUsage()
            reloadHeaderDescription()
        }
        .onReceive(timer) { _ in
            checkModelName()
            fetchUsage()
        }
    }

    var modelSelectionMenu: some View {
        Group {
            if modelList.keys.count > 3 {
                collapsedModelSelectionMenu
            } else {
                expandedModelSelectionMenu
            }
        }
        .disabled(isRunning || isRetrying)
    }

    var expandedModelSelectionMenu: some View {
        Menu {
            ForEach(modelList.keys, id: \.self) { key in
                Section(key.urlHost) {
                    ForEach(modelList.values[key, default: []]) { modelHandler in
                        Button {
                            setModel(modelHandler)
                        } label: {
                            if isActivatedModel(modelHandler) {
                                Label(modelHandler.model, systemImage: "checkmark")
                            } else {
                                Text(modelHandler.model)
                            }
                        }
                    }
                }
            }
        } label: {
            Rectangle()
                .foregroundStyle(.clear)
        }
        .buttonStyle(.plain)
    }

    var collapsedModelSelectionMenu: some View {
        Menu {
            Section("Available Models".localized) {
                ForEach(modelList.keys, id: \.self) { key in
                    Menu {
                        ForEach(modelList.values[key, default: []]) { modelHandler in
                            Button {
                                setModel(modelHandler)
                            } label: {
                                if isActivatedModel(modelHandler) {
                                    Label(modelHandler.model, systemImage: "checkmark")
                                } else {
                                    Text(modelHandler.model)
                                }
                            }
                        }
                    } label: {
                        Text(key.urlHost)
                    }
                }
            }
        } label: {
            Rectangle()
                .foregroundStyle(.clear)
        }
        .buttonStyle(.plain)
    }

    /// 3.0.106: the checkmark follows the activated endpoint, not the model name.
    ///
    /// Falls back to the name only when the gateway did not send `endpoint_id`
    /// (a panel talking to an older service), which is the behaviour of 3.0.105
    /// and before.
    func isActivatedModel(_ handler: ModelHandler) -> Bool {
        if !activeEndpointID.isEmpty {
            return activeEndpointID.caseInsensitiveCompare(handler.id.uuidString) == .orderedSame
        }
        return model == handler.model
    }

    var closeButton: some View {
        Image(systemName: "xmark")
            .font(.footnote.bold())
            .foregroundStyle(.white)
            .opacity(isClosePressed ? 0.5 : 1)
            .background {
                Circle()
                    .foregroundStyle(.white)
                    .opacity(isClosePressed ? 0.05 : 0.1)
                    .padding(-8)
            }
            .padding(EdgeInsets(top: 0, leading: 0, bottom: 4, trailing: 8))
            .animation(.easeOut(duration: 0.15), value: isClosePressed)
            ._onButtonGesture { isClosePressed = $0 } perform: { dismiss() }
    }

    func reloadHeaderDescription() {
        headerDescription = [textCountDescription, shortenModelName]
            .filter { !$0.isEmpty }
            .joined(separator: "   ")
    }

    func checkModelName() {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.25) {
            let request = Configurator.shared.gateModelCheckRequest
            var checkModel = ""
            var checkEndpointID = ""
            var checkModelList = [ModelHandler]()
            var checkCustomPrompts = [CustomPromptEntry]()
            let sem = DispatchSemaphore(value: 0)
            URLSession.shared.dataTask(with: request) { data, _, _ in
                defer { sem.signal() }
                guard let data else { return }
                guard let json = try? JSONSerialization.jsonObject(
                    with: data, options: []
                ) as? [String: Any] else { return }

                if let model = json["model"] as? String {
                    checkModel = model
                }
                if let modelList = json["model_list"] as? [Any] {
                    lazy var dec = JSONDecoder()
                    checkModelList = modelList
                        .compactMap { try? JSONSerialization.data(withJSONObject: $0) }
                        .compactMap { try? dec.decode(ModelHandler.self, from: $0) }
                        // 3.0.106: by name, so the menu reads in a stable order.
                        // It used to sort by `id.uuidString`, i.e. by random
                        // UUID, which reshuffled the list whenever an endpoint
                        // was added and made a switch hard to follow.
                        .sorted {
                            ($0.model, $0.id.uuidString) < ($1.model, $1.id.uuidString)
                        }
                }
                if let endpointID = json["endpoint_id"] as? String {
                    checkEndpointID = endpointID
                }
                if let customPrompts = json["custom_prompts"] as? [Any] {
                    lazy var dec = JSONDecoder()
                    checkCustomPrompts = customPrompts
                        .compactMap { try? JSONSerialization.data(withJSONObject: $0) }
                        .compactMap { try? dec.decode(CustomPromptEntry.self, from: $0) }
                        .sorted { $0.title < $1.title }
                }
            }.resume()
            sem.wait()

            var build: [String: [ModelHandler]] = [:]
            for model in checkModelList {
                build[model.url.absoluteString, default: []].append(model)
            }
            let tree = ModelTree(values: build)

            DispatchQueue.main.async {
                var dirty = false
                if model != checkModel {
                    model = checkModel
                    dirty = true
                }
                if modelList != tree {
                    modelList = tree
                    dirty = true
                }
                if activeEndpointID != checkEndpointID {
                    activeEndpointID = checkEndpointID
                    dirty = true
                }
                if customPrompts != checkCustomPrompts {
                    customPrompts = checkCustomPrompts
                    dirty = true
                }
                if dirty { reloadHeaderDescription() }
            }
        }
    }

    /// Polls cumulative token usage from the gate daemon and surfaces it in the panel.
    func fetchUsage() {
        let request = Configurator.shared.gateUsageCheckRequest
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data,
                  let stats = try? JSONDecoder().decode(PanelUsage.self, from: data) else { return }
            DispatchQueue.main.async {
                usage = stats
            }
        }.resume()
    }

    func setModel(_ model: ModelHandler) {
        var request = Configurator.shared.gateModelSetRequest
        request.setValue(model.id.uuidString, forHTTPHeaderField: "X-Faircopy-ModelID")
        URLSession.shared.dataTask(with: request) { _, _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                postSetupModel()
                confirmModelSwitch(model.id)
            }
        }.resume()
    }

    /// 3.0.106: make the panel reflect the switch it just asked for.
    ///
    /// The gateway used to answer 200 before the write landed (it queued the
    /// write on the main thread), so the single read 100 ms later could still
    /// see the old endpoint and the checkmark did not move. The gateway now
    /// writes first; this retry covers the remaining case — a worker busy with
    /// a recognition, which delays its main queue by up to a second.
    func confirmModelSwitch(_ expected: UUID, attempt: Int = 0) {
        guard attempt < 4 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            if self.activeEndpointID.caseInsensitiveCompare(expected.uuidString) == .orderedSame {
                return
            }
            self.checkModelName()
            self.confirmModelSwitch(expected, attempt: attempt + 1)
        }
    }

    func postSetupModel() {
        checkModelName()

        if let configClass = NSClassFromString("WritingToolConfiguration") as? NSObject.Type,
           let sharedInstance = configClass
           .perform(NSSelectorFromString("shared"))?
           .takeUnretainedValue() as? NSObject,
           sharedInstance.responds(to: NSSelectorFromString("reloadValueFromSystem"))
        {
            sharedInstance.perform(NSSelectorFromString("reloadValueFromSystem"))
        }

        if shouldShowOutput, !isRunning, !isRetrying { executeCurrentTask() }
    }
}

private extension String {
    var urlHost: String {
        URL(string: self)?.host ?? self
    }
}

/// The panel's brand mark: a pencil pointing up and to the right.
///
/// 3.0.126: built from points instead of `Image(systemName:)`. The symbol route
/// failed twice for two different reasons — a name the OS does not have draws
/// nothing at all (3.0.124), and an `Image` handed to an `HStack` beside a
/// flexible marquee can be laid out at zero width (3.0.125). A filled path in a
/// fixed frame has neither failure mode, and it looks the same on every OS this
/// panel supports.
struct BrandPencil: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 20

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * unit, y: rect.minY + y * unit)
        }

        var path = Path()

        // Barrel: the slab that runs from the shoulder down to the nib.
        path.move(to: point(5.4, 12.4))
        path.addLine(to: point(12.6, 5.2))
        path.addLine(to: point(15.4, 8.0))
        path.addLine(to: point(8.2, 15.2))
        path.closeSubpath()

        // Nib: the wedge that meets the paper at the bottom left.
        path.move(to: point(2.2, 17.8))
        path.addLine(to: point(5.4, 12.4))
        path.addLine(to: point(8.2, 15.2))
        path.closeSubpath()

        return path
    }
}
