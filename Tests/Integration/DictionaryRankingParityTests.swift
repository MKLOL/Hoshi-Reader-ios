import CHoshiDicts
import CxxStdlib
import Foundation
import XCTest
@testable import Hoshi_Reader

nonisolated final class DictionaryRankingParityTests: XCTestCase {
    /// Same fixture as Android's native DictionaryRankingParityTest.
    func testEqualMinimumFrequencyUsesNextDictionary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let terms = try importFixture(root, "Terms")
        let primary = try importFixture(root, "Primary")
        let secondary = try importFixture(root, "Secondary")

        var query = DictionaryQuery()
        query.add_term_dict(std.string(terms.path(percentEncoded: false)))
        query.add_freq_dict(std.string(primary.path(percentEncoded: false)))
        query.add_freq_dict(std.string(secondary.path(percentEncoded: false)))
        var deinflector = Deinflector()
        try withUnsafeMutablePointer(to: &query) { query in
            try withUnsafeMutablePointer(to: &deinflector) { deinflector in
                let lookup = Lookup(&query.pointee, &deinflector.pointee)
                let results = Array(lookup.lookup(std.string("橋を渡る"), 16, 16))
                XCTAssertEqual(results.map { cxxStringToSwift($0.term.reading) }, ["はし", "きょう"])
                XCTAssertTrue(results.allSatisfy { cxxStringToSwift($0.matched) == "橋" })
                let term = try XCTUnwrap(results.first { cxxStringToSwift($0.term.reading) == "はし" })
                let frequency = try XCTUnwrap(Array(term.term.frequencies)
                    .first { cxxStringToSwift($0.dict_name) == "Primary" })
                XCTAssertEqual(Array(frequency.frequencies).map(\.value).sorted(), [12, 99])
                XCTAssertEqual(Array(lookup.lookup(std.string("橋"), 1, 1)).map { cxxStringToSwift($0.term.reading) }, ["はし"])
                XCTAssertEqual(Array(lookup.lookup(std.string("はし"), 16, 16)).map { cxxStringToSwift($0.term.reading) }, ["はし"])
            }
        }
    }

    private func importFixture(_ root: URL, _ title: String) throws -> URL {
        let archive = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: title, withExtension: "zip", subdirectory: "dictionary-ranking"))
        let imported = try DictionaryDownloads.importArchive(at: archive, to: root)
        XCTAssertEqual(imported, title)
        return root.appendingPathComponent(title, isDirectory: true)
    }
}
