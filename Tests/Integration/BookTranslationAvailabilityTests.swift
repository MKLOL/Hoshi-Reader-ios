import XCTest
@testable import Hoshi_Reader

nonisolated final class BookTranslationAvailabilityTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func epub(translation: String = "Hello", syncId: String = "novel", version: Int = 1) -> Data {
        let text = "こんにちは"
        return try! JSONSerialization.data(withJSONObject: ["version": version, "kind": "epub", "syncId": syncId,
            "spineCount": 1, "entries": ["c0s0": ["spine": 0, "start": 0, "len": 5,
            "text": text, "hash": EpubTranslationStore.textHash(text), "translation": translation, "explanation": ""]]])
    }
    func testEPUBAvailabilityTracksAtomicReplacementDeletionAndInvalidation() throws {
        let root = try root(), file = root.appendingPathComponent("sentence_translations.json")
        let cache = BookTranslationAvailability()
        XCTAssertFalse(cache.hasTranslations(root: root, syncId: "novel"))
        try epub().write(to: file, options: .atomic)
        XCTAssertTrue(cache.hasTranslations(root: root, syncId: "novel"))
        XCTAssertFalse(cache.hasTranslations(root: root, syncId: "wrong-book"))
        XCTAssertTrue(cache.hasTranslations(root: root, syncId: "novel"))
        for invalid in [epub(translation: " \n"), epub(version: 2), Data("{broken".utf8), Data("{}".utf8)] {
            try invalid.write(to: file, options: .atomic)
            XCTAssertFalse(cache.hasTranslations(root: root, syncId: "novel"))
        }
        try epub().write(to: file, options: .atomic)
        XCTAssertTrue(cache.hasTranslations(root: root, syncId: "novel"))
        try FileManager.default.removeItem(at: file)
        XCTAssertFalse(cache.hasTranslations(root: root, syncId: "novel"))
    }
    func testMangaAndShelfCollectionRequireUsableMatchingTranslations() throws {
        let root = try root(), id = UUID(), file = root.appendingPathComponent("pretranslations.json")
        try Data("{}".utf8).write(to: root.appendingPathComponent("mokuro.json"))
        let cache = BookTranslationAvailability()
        let input = BookTranslationAvailability.Book(id: id, root: root, syncId: "manga")
        for (json, available) in [
            (#"{"version":1,"syncId":"manga","entries":{}}"#, false),
            (#"{"version":1,"syncId":"manga","entries":{"p0b0":{"text":"こんにちは","hash":"a","translation":"Hello","explanation":""}}}"#, true),
            (#"{"version":1,"syncId":"other","entries":{"p0b0":{"text":"こんにちは","hash":"a","translation":"Hello","explanation":""}}}"#, false),
            (#"{"version":1,"syncId":"manga","entries":{"p0b0":{"text":"こんにちは","hash":"a","translation":"  ","explanation":""}}}"#, false),
            (#"{"version":99,"syncId":"manga","entries":{"p0b0":{"text":"こんにちは","hash":"a","translation":"Hello","explanation":""}}}"#, false)
        ] {
            try Data(json.utf8).write(to: file, options: .atomic)
            XCTAssertEqual(cache.load([input]).contains(id), available)
        }
    }
    func testUnchangedSidecarIsReadOnceAndSameSizeAtomicReplacementInvalidatesCache() throws {
        let root = try root(), file = root.appendingPathComponent("sentence_translations.json")
        let reads = ReadCounter()
        let cache = BookTranslationAvailability { url in reads.increment(); return try Data(contentsOf: url) }
        try epub().write(to: file, options: .atomic)
        let modified = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
        XCTAssertTrue(cache.hasTranslations(root: root, syncId: "novel"))
        XCTAssertTrue(cache.hasTranslations(root: root, syncId: "novel"))
        XCTAssertEqual(reads.value, 1)
        try epub(translation: "     ").write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        XCTAssertFalse(cache.hasTranslations(root: root, syncId: "novel"))
        XCTAssertEqual(reads.value, 2)
    }
}
nonisolated private final class ReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
