//
//  LlmModelCatalog.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  The curated set of downloadable GGUF models for on-device translation. Ported from the Android
//  reader's `features/ai/offline/LlmModelCatalog.kt` — same models, same Hugging Face URLs, same
//  default (Gemma-2-2B JP→EN). Each entry also carries the LLM.swift `Template` to apply for that
//  model family (Gemma → `.gemma`, Qwen2.5 → `.chatML()`). Pure value types, `nonisolated`.
//

import Foundation
import LLM

/// The chat template family a model expects, decoupled from LLM.swift's `Template` so the catalog
/// stays a pure `Codable`-friendly value type. Mapped to a concrete `Template` via `llmTemplate`.
nonisolated enum LlmTemplateKind: String, Sendable {
    /// Gemma `<start_of_turn>` format.
    case gemma
    /// ChatML `<|im_start|>` format (Qwen2.5 and friends).
    case chatML
}

/// A downloadable GGUF model hosted on Hugging Face.
nonisolated struct LlmModel: Identifiable, Equatable, Sendable {
    /// Stable internal id persisted in settings (see `OfflineTranslationSettingsStore`).
    let id: String
    let displayName: String
    let description: String
    /// Hugging Face `owner/name` repository slug.
    let repo: String
    /// The GGUF file inside that repo; also the on-disk file name.
    let fileName: String
    /// Advertised download size, used for the progress bar and the truncated-file check.
    let approxSizeBytes: Int64
    /// The model's native context window (clamped at load time).
    let contextLength: Int32
    /// Which chat template family to apply when generating.
    let templateKind: LlmTemplateKind

    /// Direct Hugging Face download URL for `fileName` (follows redirects to the CDN).
    var downloadURL: URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/main/\(fileName)?download=true")!
    }

    /// The concrete LLM.swift `Template` to load this model with.
    var llmTemplate: Template {
        switch templateKind {
        case .gemma: return .gemma
        case .chatML: return .chatML()
        }
    }
}

/// The fixed set of models the app can download for on-device translation.
///
/// Curated rather than open-ended: each entry is a GGUF known to run under the bundled llama.cpp
/// build, ordered best-quality (and heaviest) first down to tiniest/test.
nonisolated enum LlmModelCatalog {
    /// Purpose-built Japanese→English translator. Best translation, but translation only.
    static let gemmaTranslateQ8 = LlmModel(
        id: "gemma-2-2b-jpn-it-translate-q8",
        displayName: "Gemma 2 2B JP→EN (translate only)",
        description: "Purpose-built Japanese→English translation — best translation quality, "
            + "fast (~3.3 GB), but does NOT explain grammar/vocabulary.",
        repo: "webbigdata/gemma-2-2b-jpn-it-translate-gguf",
        fileName: "gemma-2-2b-jpn-it-translate-Q8_0.gguf",
        approxSizeBytes: 3_354_000_000,
        contextLength: 4096,
        templateKind: .gemma
    )

    /// General instruct model big enough to also EXPLAIN grammar/vocab, not just translate.
    static let qwen7BQ4 = LlmModel(
        id: "qwen2.5-7b-instruct-q4km",
        displayName: "Qwen2.5 7B (translate + explain)",
        description: "General model that also explains grammar & vocabulary, not just translates. "
            + "~4.7 GB; needs a strong device (8 GB+ RAM). A few seconds to ~a minute per "
            + "explanation.",
        repo: "bartowski/Qwen2.5-7B-Instruct-GGUF",
        fileName: "Qwen2.5-7B-Instruct-Q4_K_M.gguf",
        approxSizeBytes: 4_680_000_000,
        contextLength: 4096,
        templateKind: .chatML
    )

    /// 14B — best offline explanations, but heavy and slow on a phone (mostly a "how slow?" test).
    static let qwen14BQ4 = LlmModel(
        id: "qwen2.5-14b-instruct-q4km",
        displayName: "Qwen2.5 14B (explain, slow)",
        description: "Best offline explanations, but ~9 GB and SLOW on-device — only for "
            + "high-RAM devices (12 GB+). Expect a long wait per reply.",
        repo: "bartowski/Qwen2.5-14B-Instruct-GGUF",
        fileName: "Qwen2.5-14B-Instruct-Q4_K_M.gguf",
        approxSizeBytes: 8_990_000_000,
        contextLength: 4096,
        templateKind: .chatML
    )

    /// Lightweight multilingual model — good middle ground for low-RAM devices.
    static let qwen1_5BQ4 = LlmModel(
        id: "qwen2.5-1.5b-instruct-q4km",
        displayName: "Qwen2.5 1.5B (lightweight)",
        description: "Smaller multilingual model. ~1 GB, faster, good for low-RAM devices.",
        repo: "bartowski/Qwen2.5-1.5B-Instruct-GGUF",
        fileName: "Qwen2.5-1.5B-Instruct-Q4_K_M.gguf",
        approxSizeBytes: 1_120_000_000,
        contextLength: 4096,
        templateKind: .chatML
    )

    /// Tiny model for verifying the download/load/translate pipeline end-to-end.
    static let qwen0_5BQ4 = LlmModel(
        id: "qwen2.5-0.5b-instruct-q4km",
        displayName: "Qwen2.5 0.5B (test/tiny)",
        description: "Tiny model for testing the pipeline. ~400 MB, lowest quality.",
        repo: "bartowski/Qwen2.5-0.5B-Instruct-GGUF",
        fileName: "Qwen2.5-0.5B-Instruct-Q4_K_M.gguf",
        approxSizeBytes: 400_000_000,
        contextLength: 4096,
        templateKind: .chatML
    )

    /// The model chosen by default when the user first enables on-device translation.
    static let `default` = gemmaTranslateQ8

    /// All catalog models. Default translator first, then explain-capable models, then small.
    static let all: [LlmModel] = [
        gemmaTranslateQ8,
        qwen7BQ4,
        qwen14BQ4,
        qwen1_5BQ4,
        qwen0_5BQ4,
    ]

    /// Looks up a model by its persisted `id`, or `nil` if unknown.
    static func byId(_ id: String) -> LlmModel? {
        all.first { $0.id == id }
    }
}
