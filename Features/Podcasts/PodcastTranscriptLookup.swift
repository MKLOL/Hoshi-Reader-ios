import Foundation
import CoreGraphics
import CHoshiDicts
import Observation

@Observable @MainActor final class PodcastTranscriptLookup {
    var popups: [PopupItem] = []
    private(set) var line: Int?
    private(set) var missingWord = false
    private var generation = 0
    private let lookup: (String, Int, Int) async -> LookupSnapshot

    init(lookup: @escaping (String, Int, Int) async -> LookupSnapshot = {
        await LookupEngine.shared.lookupAsync($0, maxResults: $1, scanLength: $2)
    }) { self.lookup = lookup }

    /// Reuse the EPUB selection payload: its query excludes ruby and its rectangle is a base glyph.
    func select(_ selection: SelectionData, line: Int, config: UserConfig, pause: () -> Void) async -> Int? {
        dismiss()
        guard !selection.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        pause()
        self.line = line
        let request = generation
        let matched = await show(selection, config: config)
        guard !Task.isCancelled, generation == request else { return nil }
        missingWord = matched == nil
        return matched
    }

    func show(_ selection: SelectionData, config: UserConfig) async -> Int? {
        let request = generation
        let snapshot = await lookup(selection.text, config.maxResults, config.scanLength)
        guard !Task.isCancelled, generation == request, let first = snapshot.results.first else { return nil }
        popups.append(PopupItem(showPopup: true, currentSelection: selection,
            lookupResults: snapshot.results, dictionaryStyles: snapshot.styles,
            isVertical: false, isFullWidth: config.popupFullWidth, clearSelection: false))
        return cxxStringToSwift(first.matched).unicodeScalars.count
    }

    func dismiss() {
        generation += 1; popups = []; line = nil; missingWord = false
    }
    func closeChildren(_ parent: Int) {
        generation += 1
        popups = Array(popups.prefix(parent + 1))
    }
}
