import Foundation
import Testing
@testable import EPUBKit

@Suite("Archive extraction isolation")
struct EPUBArchiveIsolationTests {
    @Test("An existing directory cannot make an invalid archive valid")
    func existingDirectoryDoesNotBypassArchiveValidation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("epub-invalid-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("book.epub")
        let existing = root.appendingPathComponent("book", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        let sentinel = existing.appendingPathComponent("bookmark.json")
        try "preserve".write(to: sentinel, atomically: true, encoding: .utf8)
        try "not a zip archive".write(to: archive, atomically: true, encoding: .utf8)
        for _ in 0..<2 {
            do {
                _ = try EPUBParser().parse(documentAt: archive)
                Issue.record("An invalid archive must fail even when a sibling directory exists")
            } catch let error as EPUBParserError {
                guard case .unzipFailed = error else {
                    Issue.record("Expected archive validation failure, got \(error)")
                    return
                }
            }
        }
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "preserve")
    }

    @Test("Concurrent parses never observe partial extraction or replace another import")
    func concurrentArchiveParsesAreIndependent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("epub-concurrent-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = EPUBLibrary().path(for: .theGeographyofBliss)
        let archive = root.appendingPathComponent("book.epub")
        try FileManager.default.copyItem(at: source, to: archive)
        let directories = try await withThrowingTaskGroup(of: URL.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    let document = try EPUBParser().parse(documentAt: archive)
                    #expect(document.title != nil)
                    #expect(document.directory.hasDirectoryPath)
                    #expect(FileManager.default.fileExists(atPath: document.contentDirectory.path))
                    return document.directory
                }
            }
            var results: [URL] = []
            for try await directory in group { results.append(directory) }
            return results
        }
        defer { for directory in directories { try? FileManager.default.removeItem(at: directory) } }
        #expect(Set(directories).count == 8)
        #expect(directories.contains(root.appendingPathComponent("book", isDirectory: true)))
    }
}
