//
//  LookupEngine.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import CHoshiDicts

/// Native results own their materialized strings/vectors; no borrowed media buffers cross queues.
nonisolated struct LookupSnapshot: @unchecked Sendable {
    let results: [LookupResult]
    let styles: [String: String]
}

nonisolated final class LookupEngine: @unchecked Sendable {
    static let shared = LookupEngine()
    
    private let lock = NSRecursiveLock()
    private let worker = DispatchQueue(label: "hoshi.dictionary.lookup", qos: .userInitiated)
    private var dictQuery: DictionaryQuery?
    private var deinflector: Deinflector?
    private var lookupEngine: Lookup?
    
    private init() {
        deinflector = Deinflector()
    }
    
    func buildQuery(termPaths: [URL], freqPaths: [URL], pitchPaths: [URL]) {
        lock.lock(); defer { lock.unlock() }
        // Destroy references into the old query before unmapping its dictionaries.
        lookupEngine = nil
        dictQuery = DictionaryQuery()
        for path in termPaths {
            dictQuery?.add_term_dict(std.string(path.path(percentEncoded: false)))
        }
        for path in freqPaths {
            dictQuery?.add_freq_dict(std.string(path.path(percentEncoded: false)))
        }
        for path in pitchPaths {
            dictQuery?.add_pitch_dict(std.string(path.path(percentEncoded: false)))
        }
        lookupEngine = Lookup(&dictQuery!, &deinflector!)
    }
    
    func lookup(_ str: String, maxResults: Int = 16, scanLength: Int = 16) -> [LookupResult] {
        lock.lock(); defer { lock.unlock() }
        return Array(lookupEngine?.lookup(std.string(str), Int32(maxResults), scanLength) ?? [])
    }
    
    func lookupAsync(_ text: String, maxResults: Int = 16, scanLength: Int = 16) async -> LookupSnapshot {
        await withCheckedContinuation { continuation in
            worker.async {
                self.lock.lock(); defer { self.lock.unlock() }
                continuation.resume(returning: LookupSnapshot(
                    results: self.lookup(text, maxResults: maxResults, scanLength: scanLength),
                    styles: self.getStylesMap()))
            }
        }
    }

    func getStyles() -> [DictionaryStyle] {
        lock.lock(); defer { lock.unlock() }
        return Array(dictQuery?.get_styles() ?? [])
    }

    /// Convenience over ``getStyles()`` returning a `dictName -> css` map. The CHoshiDicts
    /// `String(...)` interop conversions live here in one trivially type-checkable spot so the
    /// many inline callers (popup / dictionary / manga / AI views) don't each rebuild the map and
    /// risk type-checker timeouts in their larger surrounding expressions.
    func getStylesMap() -> [String: String] {
        var styles: [String: String] = [:]
        for style in getStyles() {
            // Route through the documented interop helper — bare `String(std.string)` doesn't
            // reliably resolve in this file's C++ interop import graph (see CxxStringInterop.swift).
            let name = cxxStringToSwift(style.dict_name)
            styles[name] = cxxStringToSwift(style.styles)
        }
        return styles
    }
    
    func withMediaFile<T>(dictName: String, mediaPath: String, _ body: (Data) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        // dictQuery is nil until buildQuery() runs (e.g. media fetch before any dictionary is built);
        // every other accessor optional-chains, so don't force-unwrap into a trap here.
        guard dictQuery != nil else { return body(Data()) }
        let view = dictQuery!.get_media_file_view(std.string(dictName), std.string(mediaPath))
        let size = Int(view.size)
        guard size > 0, let ptr = UnsafeMutableRawPointer(mutating: view.data) else {
            return body(Data())
        }
        let data = Data(bytes: ptr, count: size)
        return body(data)
    }
    
    func getMediaFile(dictName: String, mediaPath: String) -> Data {
        return withMediaFile(dictName: dictName, mediaPath: mediaPath) { Data($0) }
    }
}
