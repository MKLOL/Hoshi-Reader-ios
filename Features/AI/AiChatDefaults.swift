//
//  AiChatDefaults.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Default ChatGPT model + prompts, ported from Android AiChatSettings. The model is a free-text
//  field (not a fixed list) so users can enter any OpenAI model id.
//

import Foundation

enum AiChatDefaults {
    static let model = "gpt-5.5"

    static let prompt =
        "You are a helpful Japanese reading tutor. For the manga speech bubble below, give a natural English translation, then a short, concise breakdown of any tricky vocabulary or grammar. Please do a translation first, with the words, then do word by word, including both furigana and romanji for the word. Put these word in the table. Make sure you don’t skip words. Then at the end the grammar."

    static let imagePrompt =
        "Transcribe any Japanese text visible in this image crop and translate it into " +
        "natural English. If useful, include a short vocabulary or grammar note. If no " +
        "readable Japanese text is visible, say so."
}
