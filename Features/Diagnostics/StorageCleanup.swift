//
//  StorageCleanup.swift
//  Hoshi Reader
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Finds files the app left behind when an import, export, restore or sync did not finish, and
/// removes them on request. Only files the app is known to create are offered, and never one
/// written recently enough to belong to work still running.
nonisolated struct StorageCleanup: Sendable {
    struct Category: Identifiable, Equatable, Sendable {
        enum Kind: String, Sendable { case temporary, imports, received }
        var id: Kind
        var title: String
        var detail: String
        var size: Int64
        var count: Int
        var targets: [URL]
    }

    /// A transfer or import writes at least this often while it runs.
    static let idle: TimeInterval = 10 * 60
    /// A file handed over by another app can wait in the import queue behind large manga.
    static let receivedIdle: TimeInterval = 24 * 60 * 60

    var temporary: URL
    var books: URL?
    var dictionaries: URL?
    var received: URL?
    var now = Date()

    @MainActor static var installed: StorageCleanup {
        let app = try? BookStorage.getAppDirectory()
        return StorageCleanup(
            temporary: FileManager.default.temporaryDirectory,
            books: app?.appendingPathComponent("Books"),
            dictionaries: app?.appendingPathComponent("Dictionaries"),
            received: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("Inbox"))
    }

    func scan() -> [Category] {
        var imports = children(of: books).filter { $0.lastPathComponent.hasPrefix(MokuroImporter.stagingPrefix) }
        for type in ["Term", "Frequency", "Pitch"] {
            imports += children(of: dictionaries?.appendingPathComponent(type)).filter { $0.lastPathComponent.hasPrefix(DictionaryDownloads.stagingPrefix) }
        }
        return [
            category(.temporary, "Temporary files",
                     "Backup archives, restore and sync staging, import copies and shared clips that were not removed when their work ended.",
                     children(of: temporary).filter { Self.isAppTemporary($0.lastPathComponent) }, idle: Self.idle),
            category(.imports, "Interrupted imports",
                     "Manga and dictionaries that were only partly unpacked.", imports, idle: Self.idle),
            category(.received, "Files received from other apps",
                     "Copies iOS made of files opened in Hoshi Reader, left behind after their import.",
                     children(of: received), idle: Self.receivedIdle)
        ].compactMap { $0 }
    }

    /// The list may have been on screen for a while. Only what was shown and still qualifies now
    /// is removed, so a file an import has started using since is left alone.
    func clean(_ shown: [Category]) -> [Category] {
        let current = Set(scan().flatMap(\.targets).map(\.standardizedFileURL))
        for target in shown.flatMap(\.targets) where current.contains(target.standardizedFileURL) {
            try? FileManager.default.removeItem(at: target)
        }
        return scan()
    }

    /// Names the app gives its own files in the temporary directory. WebKit and iOS keep files
    /// there too, and those are not the app's to remove.
    static func isAppTemporary(_ name: String) -> Bool {
        let prefixes = ["hoshi-restore-", "hoshi-sync-stage-", "hoshi-sync-upload-", "hoshi-diagnostics-",
                        "NewsImport-", "MokuroImport-", "sasayaki-", "podcast-"]
        if prefixes.contains(where: name.hasPrefix) || name.hasSuffix(".hoshi") { return true }
        // Import copies and unpacked Anki packages are named by a bare UUID.
        return UUID(uuidString: (name as NSString).deletingPathExtension) != nil
    }

    private func children(of directory: URL?) -> [URL] {
        guard let directory else { return [] }
        return (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    }

    private func category(_ id: Category.Kind, _ title: String, _ detail: String, _ candidates: [URL], idle: TimeInterval) -> Category? {
        var size: Int64 = 0, count = 0, targets: [URL] = []
        for candidate in candidates.sorted(by: { $0.path < $1.path }) {
            let measured = measure(candidate)
            guard now.timeIntervalSince(measured.modified) >= idle else { continue }
            size += measured.size; count += measured.files; targets.append(candidate)
        }
        return targets.isEmpty ? nil : Category(id: id, title: title, detail: detail, size: size, count: count, targets: targets)
    }

    /// Size, file count and newest modification anywhere inside `url`.
    private func measure(_ url: URL) -> (size: Int64, files: Int, modified: Date) {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        var size: Int64 = 0, files = 0, modified = Date.distantPast
        func add(_ item: URL) {
            guard let values = try? item.resourceValues(forKeys: keys) else { return }
            if let date = values.contentModificationDate { modified = max(modified, date) }
            if values.isRegularFile == true { size += Int64(values.fileSize ?? 0); files += 1 }
        }
        add(url)
        if let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) {
            for case let item as URL in walker { add(item) }
        }
        return (size, max(files, 1), modified)
    }
}
