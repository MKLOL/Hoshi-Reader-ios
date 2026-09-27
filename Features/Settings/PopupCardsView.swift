import SwiftUI
import UIKit

struct PopupCardsView: View {
    let userConfig: UserConfig
    @State private var previewController = MangaAiController()
    @State private var dictionary = true
    @State private var fullPreview = false
    @State private var windowSize = CGSize(width: 1024, height: 768)
    private var style: PopupCardStyle { dictionary ? userConfig.dictionaryCard.normalized : userConfig.translationCard.normalized }
    private var defaults: CGSize {
        if dictionary {
            let layout = PopupLayout(selectionRect: CGRect(x: 20, y: 40, width: 30, height: 20), screenSize: windowSize,
                maxWidth: CGFloat(userConfig.popupWidth), maxHeight: CGFloat(userConfig.popupHeight),
                isVertical: false, isFullWidth: userConfig.popupFullWidth, preferTallPopup: UIDevice.current.userInterfaceIdiom == .pad)
            return CGSize(width: layout.width, height: layout.height)
        }
        return PopupCardGeometry.translationDefaults(in: windowSize, isPad: UIDevice.current.userInterfaceIdiom == .pad)
    }
    private var size: CGSize { style.size(defaults: defaults, available: windowSize, margin: dictionary ? 6 : (UIDevice.current.userInterfaceIdiom == .pad ? 36 : 16)) }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                Picker("Card", selection: $dictionary) {
                    Text("Dictionary").tag(true)
                    Text("Translation").tag(false)
                }.pickerStyle(.segmented).padding().accessibilityIdentifier("card-type")
                HStack {
                    Text("Actual-size preview · scroll to inspect").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Full preview") { fullPreview = true }.accessibilityIdentifier("card-full-preview")
                }.padding(.horizontal).padding(.bottom, 8)
                ScrollView([.horizontal, .vertical]) {
                    preview.frame(width: size.width, height: size.height).padding(16)
                }.frame(height: min(420, geometry.size.height * 0.40))
                    .background(.secondary.opacity(0.08))
                    .accessibilityIdentifier("card-preview")
                Form {
                    Section {
                        control("Width", key: \.width, fallback: defaults.width, range: 160...1600, step: 10, points: true, id: "card-width")
                        control("Height", key: \.height, fallback: defaults.height, range: 120...2000, step: 10, points: true, id: "card-height")
                        control("Content scale", key: \.scale, fallback: 1, range: 0.5...3, step: 0.05, points: false, id: "card-scale")
                        control("Font size", key: \.fontScale, fallback: 1, range: 0.5...3, step: 0.05, points: false, id: "card-font")
                        Button("Reset this card to defaults") {
                            if dictionary { userConfig.dictionaryCard = .init(); userConfig.popupWidth = 240; userConfig.popupHeight = 170; userConfig.popupFullWidth = false }
                            else { userConfig.translationCard = .init() }
                        }.accessibilityIdentifier("card-reset")
                    } footer: {
                        Text("Changes save automatically. Unchanged controls follow the available window. Cards stay inside the reading area and dictionary placement keeps the selected text visible.")
                    }
                }.accessibilityIdentifier("card-controls")
            }
        }
        .background(CardWindowReader(size: $windowSize).frame(width: 0, height: 0))
        .navigationTitle("Popup Cards")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $fullPreview) { fullPreviewBody }
    }

    private var fullPreviewBody: some View {
        NavigationStack {
            GeometryReader { geometry in
                preview.frame(width: max(1, min(size.width, geometry.size.width - 24)), height: max(1, min(size.height, geometry.size.height - 24)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }.navigationTitle("Card preview").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { fullPreview = false } } }
        }
    }

    @ViewBuilder private var preview: some View {
        if dictionary {
            PopupWebView(content: PopupCardSample.dictionaryHTML, position: .zero, clearSelection: false,
                         lookupEntries: PopupCardSample.entries, cardStyle: userConfig.dictionaryCard, isPreview: true)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.4)))
        } else {
            MangaAiPopupView(controller: previewController,
                book: BookMetadata(title: "Preview", cover: nil, folder: nil, lastAccess: Date()), userConfig: userConfig,
                previewEntry: AiChatEntry(bubbleText: PopupCardSample.source, prompt: "", model: "Sample translation",
                    response: PopupCardSample.response, timestampSeconds: 0), inlinePreview: true)
        }
    }

    private func control(_ title: String, key: WritableKeyPath<PopupCardStyle, Double?>, fallback: Double,
                         range: ClosedRange<Double>, step: Double, points: Bool, id: String) -> some View {
        let value = style[keyPath: key] ?? fallback
        return VStack {
            LabeledContent(title, value: points ? "\(Int(value.rounded())) pt" : "\(Int((value * 100).rounded()))%")
            Slider(value: Binding(get: { style[keyPath: key] ?? fallback }, set: { value in
                var next = style; next[keyPath: key] = value
                if dictionary {
                    if key == \.width { userConfig.popupFullWidth = false }
                    userConfig.dictionaryCard = next
                } else { userConfig.translationCard = next }
            }), in: range, step: step).accessibilityLabel(title).accessibilityIdentifier(id)
        }
    }
}

private struct CardWindowReader: UIViewRepresentable {
    @Binding var size: CGSize
    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ view: Probe, context: Context) { view.report = { size = $0 }; view.measure() }
    final class Probe: UIView {
        var report: ((CGSize) -> Void)?
        private var last: CGSize = .zero
        override func didMoveToWindow() { super.didMoveToWindow(); measure() }
        override func layoutSubviews() { super.layoutSubviews(); measure() }
        func measure() {
            guard let size = window?.bounds.size, size != last else { return }
            last = size
            DispatchQueue.main.async { [weak self] in self?.report?(size) }
        }
    }
}
