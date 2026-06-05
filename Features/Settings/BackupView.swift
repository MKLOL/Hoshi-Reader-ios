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
                restoreFolder(from: url, to: target)
            }
        }
        .overlay {
            if isLoading {
                LoadingOverlay(loadingString)
            }
        }
        .navigationTitle("Backup")
    }
    
    private func backupFolder(folder: String) {
        isLoading = true
        loadingString = "Archiving..."
        let directory = try! BookStorage.getAppDirectory().appendingPathComponent(folder)
        Task.detached {
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
            
            await MainActor.run {
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
        Task.detached {
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
            if ok && extractedSomething {
                do {
                    try replaceRestoredFolder(staging: staging, destination: destination, fileManager: fm)
                    restored = true
                } catch {
                    restored = false
                }
            } else {
                restored = false
            }
            await MainActor.run {
                isLoading = false
                if restored {
                    DictionaryManager.shared.loadDictionaries()
                    DictionaryManager.shared.rebuildLookupQuery()
                }
            }
        }
    }
}

nonisolated private func replaceRestoredFolder(staging: URL, destination: URL, fileManager fm: FileManager) throws {
    try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    let movedDestination = try moveExistingDestinationAside(destination: destination, fileManager: fm)
    do {
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
