//
//  MarqueeText.swift
//  WritingTools
//
//  Created by Lessica on 2024/8/30.
//

import SwiftUI

struct MarqueeText: View {
    @Binding var text: String
    @Binding var isAnimated: Bool

    let font: UIFont
    let leftFade: CGFloat
    let rightFade: CGFloat
    let startDelay: Double

    @State var stringWidth: CGFloat = 0
    @State var stringHeight: CGFloat = 0
    @State var stringSpacing: CGFloat = 0

    @State var linearAnimation: Animation?
    @State var isAnimatedInternal: Bool = false

    struct ViewSizeKey: PreferenceKey {
        static var defaultValue: CGSize = .zero
        static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
            value = nextValue()
        }
    }

    struct ViewGeometry: View {
        var body: some View {
            GeometryReader { geometry in
                Color.clear
                    .preference(key: ViewSizeKey.self, value: geometry.size)
            }
        }
    }

    @State var viewWidth: CGFloat = 0
    @State var animationControl: Bool = false

    @ViewBuilder
    var textWithChevron: some View {
        Text("\(text) \(Image(systemName: "chevron.down"))")
            .lineLimit(1)
            .font(.init(font))
    }

    var body: some View {
        ZStack {
            Color.clear
                .background(ViewGeometry())

            if isAnimatedInternal {
                ZStack {
                    textWithChevron
                        .offset(x: animationControl ? -(stringWidth + stringSpacing) : 0)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(
                            minWidth: 0,
                            maxWidth: .infinity,
                            minHeight: 0,
                            maxHeight: .infinity,
                            alignment: .topLeading
                        )

                    textWithChevron
                        .offset(x: animationControl ? 0 : (stringWidth + stringSpacing))
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(
                            minWidth: 0,
                            maxWidth: .infinity,
                            minHeight: 0,
                            maxHeight: .infinity,
                            alignment: .topLeading
                        )
                }
                .animation(linearAnimation, value: animationControl)
                .onAppear {
                    animationControl = true
                }
                .onDisappear {
                    animationControl = false
                }
                .offset(x: leftFade)
                .mask {
                    HStack(spacing: 0) {
                        Rectangle()
                            .frame(width: 2)
                            .opacity(0)
                        LinearGradient(gradient: Gradient(colors: [Color.black.opacity(0), Color.black]), startPoint: .leading, endPoint: .trailing)
                            .frame(width: leftFade)
                        LinearGradient(gradient: Gradient(colors: [Color.black, Color.black]), startPoint: .leading, endPoint: .trailing)
                        LinearGradient(gradient: Gradient(colors: [Color.black, Color.black.opacity(0)]), startPoint: .leading, endPoint: .trailing)
                            .frame(width: rightFade)
                        Rectangle()
                            .frame(width: 2)
                            .opacity(0)
                    }
                }
                .offset(x: leftFade * -1)
            } else {
                textWithChevron
                    .frame(
                        minWidth: 0,
                        maxWidth: .infinity,
                        minHeight: 0,
                        maxHeight: .infinity,
                        alignment: .topLeading
                    )
            }
        }
        .frame(height: stringHeight)
        .onAppear { reloadStringSize() }
        .onChange(of: text) { _ in reloadStringSize() }
        .onChange(of: isAnimated) { _ in reloadAnimationState() }
        .onChange(of: stringWidth) { _ in reloadAnimationState() }
        .onPreferenceChange(ViewSizeKey.self) { size in
            viewWidth = size.width
            reloadAnimationState()
        }
    }

    private func reloadStringSize() {
        stringWidth = text.widthOfString(usingFont: font)
        stringHeight = text.heightOfString(usingFont: font)
        stringSpacing = stringHeight * 3.0
        linearAnimation = Animation
            .linear(duration: Double(stringWidth) / 30.0)
            .delay(startDelay).repeatForever(autoreverses: false)
    }

    private func reloadAnimationState() {
        isAnimatedInternal = isAnimated && viewWidth < stringWidth
    }

    init(
        text: Binding<String>,
        isAnimated: Binding<Bool>,
        font: UIFont,
        leftFade: CGFloat,
        rightFade: CGFloat,
        startDelay: Double
    ) {
        _text = text
        _isAnimated = isAnimated
        self.font = font
        self.leftFade = leftFade
        self.rightFade = rightFade
        self.startDelay = startDelay
    }
}

extension String {
    func widthOfString(usingFont font: UIFont) -> CGFloat {
        let fontAttributes = [NSAttributedString.Key.font: font]
        let this = self
        let size = this.size(withAttributes: fontAttributes)
        return size.width
    }

    func heightOfString(usingFont font: UIFont) -> CGFloat {
        let fontAttributes = [NSAttributedString.Key.font: font]
        let this = self
        let size = this.size(withAttributes: fontAttributes)
        return size.height
    }
}
