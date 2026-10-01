import SwiftUI

/// The same recursive dictionary cards for native sentence text and podcast transcripts.
struct NativeDictionaryPopupStack: View {
    let userConfig: UserConfig
    @Binding var popups: [PopupItem]
    let screenSize: CGSize
    var coverURL: URL? = nil
    var documentTitle: String? = nil
    let onTextSelected: (SelectionData) async -> Int?
    let onDismiss: () -> Void
    let onCloseChildren: (Int) -> Void

    var body: some View {
        ForEach($popups) { $popup in
            let popupId = popup.id
            PopupView(
                userConfig: userConfig,
                isVisible: $popup.showPopup,
                selectionData: popup.currentSelection,
                lookupResults: popup.lookupResults,
                dictionaryStyles: popup.dictionaryStyles,
                screenSize: screenSize,
                isVertical: popup.isVertical,
                isFullWidth: popup.isFullWidth,
                coverURL: coverURL,
                documentTitle: documentTitle,
                clearSelection: popup.clearSelection,
                onTextSelected: { selection in
                    if let index = popups.firstIndex(where: { $0.id == popupId }) {
                        onCloseChildren(index)
                    }
                    return await onTextSelected(selection)
                },
                onTapOutside: {
                    if let index = popups.firstIndex(where: { $0.id == popupId }) {
                        onCloseChildren(index)
                    }
                },
                onSwipeDismiss: {
                    guard let index = popups.firstIndex(where: { $0.id == popupId }),
                          popups.indices.contains(index) else { return }
                    if index == 0 {
                        onDismiss()
                    } else if popups.indices.contains(index - 1) {
                        popups[index - 1].clearSelection.toggle()
                        onCloseChildren(index - 1)
                    }
                }
            )
            .zIndex(Double(100 + (popups.firstIndex(where: { $0.id == popupId }) ?? 0)))
        }
    }
}
