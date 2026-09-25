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
//  model family (Gemma → `.gemma`, Qwen → `.chatML()`). Pure value types, `nonisolated`.
//

import Foundation
import LLM

/// The chat template family a model expects, decoupled from LLM.swift's `Template` so the catalog
/// stays a pure `Codable`-friendly value type. Mapped to a concrete `Template` via `llmTemplate`.
nonisolated enum LlmTemplateKind: String, Sendable {
    /// Gemma `<start_of_turn>` format.
    case gemma
    /// ChatML `<|im_start|>` format (Qwen2.5 / Qwen3 / Qwen3.5 and friends).
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
        contextLength: 8192,
        templateKind: .gemma
    )

    /// Largest / best on-device model that still FITS the iPad GPU. The 9B at Q4_K_M needs ~6.2 GB of
    /// Metal working set, over the M4 iPad's ~5.7 GB GPU limit — its command buffer OOMs after the
    /// first token. This Q3_K_M build keeps the full 9B on Metal at ~4.5 GB of weights (paired with a
    /// capped `n_ubatch` in `OfflineLlmManager`/`LLMCore` so the 248K-vocab logits buffer stays
    /// small). Qwen3.5 (Gated DeltaNet, arch `qwen35`); reasoning OFF by default (no `<think>`).
    /// Requires the b9840+ llama.cpp engine.
    static let qwen35_9B = LlmModel(
        id: "qwen3.5-9b-q3ks",
        displayName: "Qwen3.5 9B (largest)",
        description: "Newest, largest on-device model — translates AND explains grammar & vocab. "
            + "Heavily quantized (Q3_K_S, ~4.3 GB) to fit the iPad GPU's ~5.5 GB limit and run on "
            + "Metal; the 4B is faster and comparable. A few seconds per reply.",
        repo: "unsloth/Qwen3.5-9B-GGUF",
        fileName: "Qwen3.5-9B-Q3_K_S.gguf",
        approxSizeBytes: 4_316_865_760,
        contextLength: 32768,
        templateKind: .chatML
    )

    /// Lighter Qwen3.5 — strong quality for its size, much faster, fits 8 GB devices.
    static let qwen35_4B = LlmModel(
        id: "qwen3.5-4b-q4km",
        displayName: "Qwen3.5 4B (translate + explain, fast)",
        description: "Smaller Qwen3.5 that still translates AND explains, noticeably faster than "
            + "the 9B. ~2.7 GB; good for 8 GB+ devices. Reasoning off by default.",
        repo: "unsloth/Qwen3.5-4B-GGUF",
        fileName: "Qwen3.5-4B-Q4_K_M.gguf",
        approxSizeBytes: 2_740_937_888,
        contextLength: 32768,
        templateKind: .chatML
    )

    /// Compact Qwen3.5 — lightweight option for low-RAM devices / quick checks.
    static let qwen35_2B = LlmModel(
        id: "qwen3.5-2b-q4km",
        displayName: "Qwen3.5 2B (lightweight)",
        description: "Compact Qwen3.5. ~1.3 GB, fast, good for low-RAM devices. Lower quality "
            + "than the 4B/9B but still explains.",
        repo: "unsloth/Qwen3.5-2B-GGUF",
        fileName: "Qwen3.5-2B-Q4_K_M.gguf",
        approxSizeBytes: 1_280_835_840,
        contextLength: 32768,
        templateKind: .chatML
    )

    /// Tiny option shared with Android for constrained devices and quick checks.
    static let qwen35_0_8B = LlmModel(
        id: "qwen3.5-0.8b-q4km",
        displayName: "Qwen3.5 0.8B (tiny)",
        description: "Tiny Qwen3.5 for quick checks and constrained devices. ~580 MB; lower quality than the larger models.",
        repo: "bartowski/Qwen_Qwen3.5-0.8B-GGUF",
        fileName: "Qwen_Qwen3.5-0.8B-Q4_K_M.gguf",
        approxSizeBytes: 580_000_000,
        contextLength: 4096,
        templateKind: .chatML
    )

    /// Legacy Qwen2.5 entries are kept so existing downloaded GGUF files remain visible, usable,
    /// counted in storage, and deletable after catalog upgrades.
    static let qwen7BQ4 = LlmModel(
        id: "qwen2.5-7b-instruct-q4km",
        displayName: "Qwen2.5 7B (legacy)",
        description: "Legacy general model that translates and explains grammar/vocabulary. "
            + "~4.7 GB; kept for existing downloads.",
        repo: "bartowski/Qwen2.5-7B-Instruct-GGUF",
        fileName: "Qwen2.5-7B-Instruct-Q4_K_M.gguf",
        approxSizeBytes: 4_680_000_000,
        contextLength: 32768,
        templateKind: .chatML
    )

    static let qwen14BQ4 = LlmModel(
        id: "qwen2.5-14b-instruct-q4km",
        displayName: "Qwen2.5 14B (legacy, slow)",
        description: "Legacy high-RAM explanation model. ~9 GB and slow; kept for existing "
            + "downloads.",
        repo: "bartowski/Qwen2.5-14B-Instruct-GGUF",
        fileName: "Qwen2.5-14B-Instruct-Q4_K_M.gguf",
        approxSizeBytes: 8_990_000_000,
        contextLength: 32768,
        templateKind: .chatML
    )

    static let qwen1_5BQ4 = LlmModel(
        id: "qwen2.5-1.5b-instruct-q4km",
        displayName: "Qwen2.5 1.5B (legacy)",
        description: "Legacy lightweight multilingual model. ~1 GB; kept for existing downloads.",
        repo: "bartowski/Qwen2.5-1.5B-Instruct-GGUF",
        fileName: "Qwen2.5-1.5B-Instruct-Q4_K_M.gguf",
        approxSizeBytes: 1_120_000_000,
        contextLength: 32768,
        templateKind: .chatML
    )

    static let qwen0_5BQ4 = LlmModel(
        id: "qwen2.5-0.5b-instruct-q4km",
        displayName: "Qwen2.5 0.5B (legacy/tiny)",
        description: "Legacy tiny pipeline-test model. ~400 MB; kept for existing downloads.",
        repo: "bartowski/Qwen2.5-0.5B-Instruct-GGUF",
        fileName: "Qwen2.5-0.5B-Instruct-Q4_K_M.gguf",
        approxSizeBytes: 400_000_000,
        contextLength: 32768,
        templateKind: .chatML
    )

    /// The model chosen by default when the user first enables on-device translation.
    static let `default` = gemmaTranslateQ8

    /// All catalog models. Default translator first, then new explain-capable models, then legacy
    /// Qwen2.5 models so old downloads are not orphaned.
    static let all: [LlmModel] = [
        gemmaTranslateQ8,
        qwen35_9B,
        qwen35_4B,
        qwen35_2B,
        qwen35_0_8B,
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
