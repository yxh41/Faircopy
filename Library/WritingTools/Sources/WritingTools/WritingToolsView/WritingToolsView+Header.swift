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
    /// A stroked `Path` inside a fixed 20 pt frame can neither be compressed to
    /// nothing nor miss a symbol on some OS version, and because it is a line
    /// rather than a filled block it sits at the same visual weight as the ✕ on
    /// the other end of the row. It stops depending on the system glyph table
    /// altogether.
    ///
    /// 3.0.127: the shape itself is a sheet with a pen across its corner — the
    /// same silhouette as the system's square-and-pencil mark, so the header
    /// reads as one family with the close button. The filled nib that shipped
    /// in 3.0.126 arrived (the blank was a squeeze, not a symbol), but at 20 pt
    /// a solid shape that size reads as a blade.
    var brandMark: some View {
        BrandMark()
            .stroke(style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
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
        VStack(alignment: .leading, spacing: 3) {
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
            // 3.0.139: an externally summoned card says who summoned it. The
            // frosted-glass skin already sets it apart; this names the caller.
            if context.isExternalInvocation {
                externalSourceBadge
            }
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
            NSLog("[Faircopy] header mark: rounded sheet and pen drawn from path")
            checkModelName()
            fetchUsage()
            reloadHeaderDescription()
        }
        .onReceive(timer) { _ in
            checkModelName()
            // 3.0.136: only poll usage once we have a previous value — before the
            // first successful fetch there is nothing to refresh, so skip the
            // request instead of hammering a daemon that isn't answering.
            if usage != nil { fetchUsage() }
        }
    }

    /// 3.0.139: "来自 X" under the title on an externally summoned card.
    ///
    /// A tiny dot rather than an SF Symbol: a symbol the OS does not know
    /// renders as nothing, and this row must never become an empty gap (see
    /// the brandMark note above).
    var externalSourceBadge: some View {
        let rawName = context.sourceAppName ?? ""
        let name = rawName.isEmpty ? "Faircopy".localized : rawName
        let label = String(format: "From %@".localized, name)
        return HStack(spacing: 4) {
            Circle()
                .fill(Color.white.opacity(0.5))
                .frame(width: 3, height: 3)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Color.white.opacity(0.55))
                .lineLimit(1)
        }
        .padding(.leading, 2)
        .accessibilityLabel(label)
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
            // 3.0.136: cancellable one-shot (was a bare asyncAfter).
            self.scheduleWork(delay: 0.1) {
                self.postSetupModel()
                self.confirmModelSwitch(model.id)
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
        // 3.0.136: schedule as a cancellable work item (via `scheduleWork`) so a
        // dismissed panel stops the retry loop instead of firing against a dead view.
        scheduleWork(delay: 0.45) {
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

/// The panel's brand mark: a sheet with a pen laid across its corner.
///
/// Drawn from points rather than loaded from the symbol table, for the two
/// failures documented on `brandMark` (a name the OS does not have draws
/// nothing; an `Image` beside a flexible marquee is laid out at zero width).
/// Stroked, not filled — at 20 pt a solid silhouette this size reads as a blade.
///
/// Geometry is authored in a 24 unit box (`unit` scales it to whatever frame the
/// shape is given) and mirrors the system square-and-pencil mark: the sheet
/// loses its top-right corner, the pen runs through it.
struct BrandMark: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 24
        let origin = CGPoint(
            x: rect.minX + (rect.width - 24 * unit) / 2,
            y: rect.minY + (rect.height - 24 * unit) / 2
        )

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + x * unit, y: origin.y + y * unit)
        }

        var path = Path()

        // Sheet: three full corners, then the top edge stops short of the
        // corner the pen comes through.
        path.move(to: point(12, 3))
        path.addLine(to: point(7, 3))
        path.addQuadCurve(to: point(3, 7), control: point(3, 3))
        path.addLine(to: point(3, 17))
        path.addQuadCurve(to: point(7, 21), control: point(3, 21))
        path.addLine(to: point(17, 21))
        path.addQuadCurve(to: point(21, 17), control: point(21, 21))
        path.addLine(to: point(21, 12))

        // Pen: rounded cap, shaft, and the two short edges of the nib.
        path.move(to: point(18.4, 2.6))
        path.addQuadCurve(to: point(21.4, 5.6), control: point(21.4, 2.6))
        path.addLine(to: point(12, 15))
        path.addLine(to: point(8, 16))
        path.addLine(to: point(9, 12))
        path.closeSubpath()

        return path
    }
}
