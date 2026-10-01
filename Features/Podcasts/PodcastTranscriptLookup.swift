import Foundation
import CoreGraphics
import CHoshiDicts
import Observation

/// TextKit addresses UTF-16, while dictionary matches count Unicode scalars.
nonisolated struct PodcastTranscriptSelection: Equatable {
    let text: String
    let query: String
    let offset: Int

    init?(text: String, offset: Int) {
        let source = text as NSString
        guard offset >= 0, offset < source.length else { return nil }
        let start = source.rangeOfComposedCharacterSequence(at: offset).location
        let range = source.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: min(32, source.length - start)))
        let query = source.substring(with: range)
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.text = text; self.query = query; self.offset = start
    }
    func highlight(matchedScalars: Int) -> NSRange {
        let start = String.Index(utf16Offset: offset, in: text)
        let end = text.unicodeScalars.index(start, offsetBy: max(0, matchedScalars), limitedBy: text.endIndex) ?? text.endIndex
        return NSRange(location: offset, length: end.utf16Offset(in: text) - offset)
    }
}

@Observable @MainActor final class PodcastTranscriptLookup {
    var popups: [PopupItem] = []
    private(set) var highlight: NSRange?
    private(set) var line: Int?
    private(set) var missingWord = false
    private var generation = 0
    private let lookup: (String, Int, Int) async -> LookupSnapshot

    init(lookup: @escaping (String, Int, Int) async -> LookupSnapshot = {
        await LookupEngine.shared.lookupAsync($0, maxResults: $1, scanLength: $2)
    }) { self.lookup = lookup }

    func select(text: String, line: Int, tap: SentenceTap, frame: CGRect, config: UserConfig, pause: () -> Void) async {
        dismiss()
        guard let selected = PodcastTranscriptSelection(text: text, offset: tap.characterOffset) else { return }
        pause() // Looking up never resumes audio automatically, including a missing word.
        self.line = line
        let selection = SelectionData(text: selected.query, sentence: text,
                                     rect: tap.rect.offsetBy(dx: frame.minX, dy: frame.minY))
        let request = generation
        let matched = await show(selection, config: config)
        guard generation == request else { return }
        highlight = matched.map { selected.highlight(matchedScalars: $0) }
        missingWord = matched == nil
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
        generation += 1; popups = []; highlight = nil; line = nil; missingWord = false
    }
    func closeChildren(_ parent: Int) {
        generation += 1
        popups = Array(popups.prefix(parent + 1))
    }
}
