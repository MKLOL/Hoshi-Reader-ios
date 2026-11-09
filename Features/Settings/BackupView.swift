//
//  BackupView.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import UniformTypeIdentifiers
import ZipArchive

struct BackupView: View {
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var exportURL: URL?
    @State private var target = ""
    @State private var isLoading = false
    @State private var loadingString = ""
    @State private var operation: Task<Void, Never>?
    @State private var pendingRestore: URL?
    @State private var restoreFailure: String?
    
    var body: some View {
        List {
            Section("Books") {
                Button("Backup") {
                    backupFolder(folder: "Books")
                }
                Button("Restore") {
                    target = "Books";
                    isImporting = true
                }
            }
            
            Section {
                Button("Backup") {
                    backupFolder(folder: "Dictionaries")
                }
                Button("Restore") {
                    target = "Dictionaries";
                    isImporting = true
                }
            } header: {
                Text("Dictionaries")
            } footer: {
                Text("Restoring will overwrite the current collection.")
            }
        }
        .fileMover(isPresented: $isExporting, file: exportURL) { result in
            switch result {
            case .success:
                exportURL = nil
            case .failure:
                cleanup()
            }
        } onCancellation: {
            cleanup()
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [UTType(filenameExtension: "hoshi")!]
        ) { result in
            if case .success(let url) = result {
                pendingRestore = url
            }
        }
        // Restoring replaces everything of that kind on this device, so the file is named
        // and confirmed before anything is touched.
        .confirmationDialog(
            target == "Books" ? "Replace all books?" : "Replace all dictionaries?",
            isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }),
            titleVisibility: .visible,
            presenting: pendingRestore
        ) { url in
            Button("Restore", role: .destructive) { restoreFolder(from: url, to: target) }
            Button("Cancel", role: .cancel) {}
        } message: { url in
            Text(target == "Books"
                 ? "The books, bookmarks and reading history on this device will be replaced by “\(url.lastPathComponent)”."
                 : "The dictionaries on this device will be replaced by “\(url.lastPathComponent)”.")
        }
        .alert("Not restored", isPresented: Binding(get: { restoreFailure != nil }, set: { if !$0 { restoreFailure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(restoreFailure ?? "")
        }
        .disabled(isLoading)
        .overlay {
            if isLoading {
                LoadingOverlay(loadingString)
            }
        }
        .navigationTitle("Backup")
        .onDisappear {
            // The document mover owns the exported file until its completion/cancellation callback.
            if !isExporting { operation?.cancel(); operation = nil; cleanup() }
        }
    }
    
    private func backupFolder(folder: String) {
        isLoading = true
        loadingString = "Archiving..."
        guard let directory = try? BookStorage.getAppDirectory().appendingPathComponent(folder) else {
            isLoading = false
            return
        }
        operation?.cancel()
        operation = Task.detached {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let archiveName = "\(folder)_\(formatter.string(from: Date())).hoshi"
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(archiveName)
            guard SSZipArchive.createZipFile(
                atPath: tempURL.path(percentEncoded: false),
                withContentsOfDirectory: directory.path(percentEncoded: false)
            ) else {
                await MainActor.run {
                    isLoading = false
                }
                return
            }
            
            guard !Task.isCancelled else { try? FileManager.default.removeItem(at: tempURL); return }
            await MainActor.run {
                guard !Task.isCancelled else { try? FileManager.default.removeItem(at: tempURL); return }
                exportURL = tempURL
                isLoading = false
                isExporting = true
            }
        }
    }
    
    private func cleanup() {
        if let exportURL {
            try? FileManager.default.removeItem(at: exportURL)
        }
        exportURL = nil
    }
    
    private func restoreFolder(from url: URL, to folder: String) {
        guard url.startAccessingSecurityScopedResource() else { return }
        isLoading = true
        loadingString = "Restoring..."
        guard let destination = try? BookStorage.getAppDirectory().appendingPathComponent(folder) else {
            isLoading = false
            url.stopAccessingSecurityScopedResource()
            return
        }
        operation?.cancel()
        operation = Task.detached {
            defer { url.stopAccessingSecurityScopedResource() }
            let fm = FileManager.default
            // Unzip into a temp staging dir FIRST and only swap it into place if it fully succeeds.
            // The old code deleted the live library before unzipping and ignored the unzip result, so
            // a corrupt/truncated archive (or a disk-full mid-unzip) wiped everything with no recovery.
            let staging = fm.temporaryDirectory.appendingPathComponent("hoshi-restore-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: staging) }
            let ok = SSZipArchive.unzipFile(atPath: url.path(percentEncoded: false), toDestination: staging.path(percentEncoded: false))
            // Require at least one NON-hidden entry: a corrupt archive that only yields junk like
            // `.DS_Store` / `__MACOSX` must not count as a successful extraction (it would still
            // replace the live library with effectively-empty content).
            let staged = (try? fm.contentsOfDirectory(atPath: staging.path(percentEncoded: false))) ?? []
            let extractedSomething = staged.contains { !$0.hasPrefix(".") && $0 != "__MACOSX" }
            let restored: Bool
            var failure: String?
            if ok && extractedSomething && !Task.isCancelled {
                // Both kinds of backup share one file type. A dictionary backup restored as
                // books would replace the whole library with dictionary folders.
                if backupMatches(folder, staging: staging, fileManager: fm) {
                    do {
                        try replaceRestoredFolder(staging: staging, destination: destination, fileManager: fm)
                        restored = true
                    } catch {
                        restored = false
                        failure = "The backup could not be put in place. Nothing was changed."
                    }
                } else {
                    restored = false
                    failure = folder == "Books"
                        ? "This file is not a backup of books. Nothing was changed."
                        : "This file is not a backup of dictionaries. Nothing was changed."
                }
            } else {
                restored = false
                if !Task.isCancelled { failure = "The backup could not be read. Nothing was changed." }
            }
            await MainActor.run {
                isLoading = false
                restoreFailure = failure
                if restored {
                    DictionaryManager.shared.loadDictionaries()
                    DictionaryManager.shared.rebuildLookupQuery()
                    NotificationCenter.default.post(name: .hoshiLibraryChanged, object: nil)
                }
            }
        }
    }
}

/// Whether an unpacked backup holds what its target stores: books are folders with their
/// metadata, dictionaries are sorted into folders by kind.
nonisolated func backupMatches(_ folder: String, staging: URL, fileManager fm: FileManager) -> Bool {
    let entries = (try? fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
    let directories = entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    // The folder names of `DictionaryType`.
    let dictionaryKinds: Set<String> = ["Term", "Frequency", "Pitch"]
    let holdsDictionaries = directories.contains { dictionaryKinds.contains($0.lastPathComponent) }
    if folder == "Dictionaries" { return holdsDictionaries }
    return !holdsDictionaries && directories.contains {
        fm.fileExists(atPath: $0.appendingPathComponent(FileNames.metadata).path(percentEncoded: false))
    }
}

nonisolated func replaceRestoredFolder(staging: URL, destination: URL, fileManager fm: FileManager) throws {
    try Task.checkCancellation()
    try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    let movedDestination = try moveExistingDestinationAside(destination: destination, fileManager: fm)
    do {
        try Task.checkCancellation()
        try fm.moveItem(at: staging, to: destination)
        if let movedDestination {
            try? fm.removeItem(at: movedDestination)
        }
    } catch {
        restoreMovedDestination(movedDestination, to: destination, fileManager: fm)
        throw error
    }
}

nonisolated private func moveExistingDestinationAside(destination: URL, fileManager fm: FileManager) throws -> URL? {
    guard fm.fileExists(atPath: destination.path(percentEncoded: false)) else { return nil }
    let backupName = ".hoshi-restore-\(destination.lastPathComponent)-\(UUID().uuidString)"
    let backupURL = destination.deletingLastPathComponent().appendingPathComponent(backupName, isDirectory: true)
    try fm.moveItem(at: destination, to: backupURL)
    return backupURL
}

nonisolated private func restoreMovedDestination(_ movedDestination: URL?, to destination: URL, fileManager fm: FileManager) {
    guard let movedDestination else { return }
    if fm.fileExists(atPath: destination.path(percentEncoded: false)) {
        try? fm.removeItem(at: destination)
    }
    try? fm.moveItem(at: movedDestination, to: destination)
}
