// Shared dictionary/podcast furigana alignment, extracted from popup.js.
// Copyright © 2026 Manhhao.
// Copyright © 2023-2025 Yomitan Authors.
// Copyright © 2021-2022 Yomichan Authors.
// SPDX-License-Identifier: GPL-3.0-or-later

const KANJI_RANGE = '\u4E00-\u9FFF\u3400-\u4DBF\uF900-\uFAFF\u3005';
const KANJI_PATTERN = new RegExp(`[${KANJI_RANGE}]`);
const KANJI_SEGMENT_PATTERN = new RegExp(`[${KANJI_RANGE}]+|[^${KANJI_RANGE}]+`, 'g');
// Built once: constructing a segmenter per word dominated the cost of annotating a transcript.
const GRAPHEME_SEGMENTER = new Intl.Segmenter('ja', {granularity: 'grapheme'});

function toHiragana(text) {
    return text.replace(/[\u30A1-\u30F6]/g, ch => String.fromCharCode(ch.charCodeAt(0) - 0x60));
}

// https://github.com/yomidevs/yomitan/blob/c24d4c9b39ceec1b5fd133df774c41972e9ebbdc/ext/js/language/ja/japanese.js#L171
function createFuriganaSegment(text, reading) {
    return {text, reading};
}

// https://github.com/yomidevs/yomitan/blob/c24d4c9b39ceec1b5fd133df774c41972e9ebbdc/ext/js/language/ja/japanese.js#L242
function getFuriganaKanaSegments(text, reading) {
    const textLength = text.length;
    const newSegments = [];
    let start = 0;
    let state = (reading[0] === text[0]);
    for (let i = 1; i < textLength; ++i) {
        const newState = (reading[i] === text[i]);
        if (state === newState) { continue; }
        newSegments.push(createFuriganaSegment(text.substring(start, i), state ? '' : reading.substring(start, i)));
        state = newState;
        start = i;
    }
    newSegments.push(createFuriganaSegment(text.substring(start, textLength), state ? '' : reading.substring(start, textLength)));
    return newSegments;
}

// https://github.com/yomidevs/yomitan/blob/c24d4c9b39ceec1b5fd133df774c41972e9ebbdc/ext/js/language/ja/japanese.js#L182
const AMBIGUOUS_FURIGANA = Symbol('ambiguous furigana');

function segmentizeFurigana(reading, readingNormalized, groups, groupsStart, cache = new Map()) {
    const key = `${groupsStart}:${reading.length}`;
    if (!cache.has(key)) {
        cache.set(key, findFuriganaSegments(reading, readingNormalized, groups, groupsStart, cache));
    }
    const result = cache.get(key);
    // Callers prepend to the result; cached suffixes must remain immutable.
    return Array.isArray(result) ? result.slice() : result;
}

function findFuriganaSegments(reading, readingNormalized, groups, groupsStart, cache) {
    const groupCount = groups.length - groupsStart;
    if (groupCount <= 0) {
        return reading.length === 0 ? [] : null;
    }

    const group = groups[groupsStart];
    const {isKana, text} = group;
    const textLength = text.length;
    if (isKana) {
        const {textNormalized} = group;
        if (textNormalized !== null && readingNormalized.startsWith(textNormalized)) {
            const segments = segmentizeFurigana(
                                                reading.substring(textLength),
                                                readingNormalized.substring(textLength),
                                                groups,
                                                groupsStart + 1,
                                                cache,
                                                );
            if (segments === AMBIGUOUS_FURIGANA) { return AMBIGUOUS_FURIGANA; }
            if (segments !== null) {
                if (reading.startsWith(text)) {
                    segments.unshift(createFuriganaSegment(text, ''));
                } else {
                    segments.unshift(...getFuriganaKanaSegments(text, reading));
                }
                return segments;
            }
        }
        return null;
    } else {
        let result = null;
        for (let i = reading.length; i >= textLength; --i) {
            const segments = segmentizeFurigana(
                                                reading.substring(i),
                                                readingNormalized.substring(i),
                                                groups,
                                                groupsStart + 1,
                                                cache,
                                                );
            if (segments === AMBIGUOUS_FURIGANA) { return AMBIGUOUS_FURIGANA; }
            if (segments !== null) {
                if (result !== null) {
                    // More than one way to segmentize the tail; preserve ambiguity through parents.
                    return AMBIGUOUS_FURIGANA;
                }
                const segmentReading = reading.substring(0, i);
                segments.unshift(createFuriganaSegment(text, segmentReading));
                result = segments;
            }
            // There is only one way to segmentize the last non-kana group
            if (groupCount === 1) {
                break;
            }
        }
        return result;
    }
}

function segmentFurigana(expression, reading, {strict = false} = {}) {
    if (strict) {
        return segmentKanjiFurigana(expression, reading);
    }
    if (!reading || reading === expression) {
        return [[expression, '']];
    }

    const groups = [];
    const segmentMatches = expression.match(KANJI_SEGMENT_PATTERN) || [];
    for (const text of segmentMatches) {
        const isKana = !KANJI_PATTERN.test(text[0]);
        const textNormalized = isKana ? toHiragana(text) : null;
        groups.push({isKana, text, textNormalized});
    }

    const readingNormalized = toHiragana(reading);
    const segments = segmentizeFurigana(reading, readingNormalized, groups, 0);

    if (Array.isArray(segments)) {
        return segments.map(seg => [seg.text, seg.reading]);
    }

    return [[expression, reading]];
}

// Generated readings must never repeat kana that are already printed in the base. Reuse the
// dictionary's established alignment, retaining its whole-word fallback only for kanji-only
// expressions. A mixed word that cannot be aligned unambiguously stays plain.
function segmentKanjiFurigana(expression, reading) {
    const plain = [[expression, '']];
    if (typeof expression !== 'string' || typeof reading !== 'string' || !reading) {
        return plain;
    }
    // A native word token is short. Bound unusual/corrupt tokens before recursive dictionary
    // alignment so one reading cannot block the transcript's WebKit main thread.
    if (expression.length > 512 || reading.length > 512) { return plain; }
    const normalizedReading = toHiragana(reading.normalize('NFC'));
    if (!/^[\u3041-\u3096\u309D-\u309F\u30FC]+$/.test(normalizedReading)) {
        return plain;
    }

    // Matching uses canonical kana, while the returned base is always the original string.
    // Built-in grapheme segmentation maps NFC boundaries back to the original UTF-16 offsets.
    let normalizedExpression = '';
    const originalOffsets = new Map([[0, 0]]);
    for (const {segment, index} of GRAPHEME_SEGMENTER.segment(expression)) {
        normalizedExpression += segment.normalize('NFC');
        originalOffsets.set(normalizedExpression.length, index + segment.length);
    }
    const segments = segmentFurigana(normalizedExpression, normalizedReading);
    const result = [];
    let offset = 0;
    for (const [base, ruby] of segments) {
        const start = originalOffsets.get(offset);
        offset += base.length;
        const end = originalOffsets.get(offset);
        if (start === undefined || end === undefined) { return plain; }
        const onlyKanji = base.length > 0 && [...base].every(character => KANJI_PATTERN.test(character));
        result.push([expression.slice(start, end), onlyKanji ? ruby : '']);
    }
    return result;
}
