/**
 * RSVP timing engine — Optimal Recognition Point (ORP) and per-word pacing.
 *
 * Derived from thomaskolmans/rsvp-reading (MIT). See NOTICE for the full
 * attribution chain; the MIT terms require it to travel with this file.
 *
 * Pure functions, no dependencies. The Swift twin in `RSVPTiming.swift` is
 * parity-locked to this file; `parity-vectors.json` is the shared golden
 * fixture both sides must reproduce exactly.
 *
 * Token conventions (shared with the tokenizer module):
 *   - '\n'          a paragraph-break token (renders as a blank beat)
 *   - '⟩' prefix    marks the first word after a break (reorientation beat)
 */

// ---------------------------------------------------------------------------
// ORP (Optimal Recognition Point)
// ---------------------------------------------------------------------------

/**
 * Length → ORP letter position. Letters AND digits count; punctuation does
 * not. A pure-number token ("2026", "12,345") has no \p{L} chars, so a
 * letter-only count would pivot it on its first digit instead of centering
 * it like a word — digits are part of the recognition point.
 *
 *   1-3 letters  → 1st letter      12-14 → 5th
 *   4-5          → 2nd             15-17 → 6th
 *   6-9          → 3rd             18+   → 7th
 *   10-11        → 4th
 *
 * @param {string} word
 * @returns {number} index of the letter to highlight
 */
export function getORPIndex(word) {
  if (!word || typeof word !== 'string') return 0;

  const cleanWord = stripBreakMarker(word);
  const len = cleanWord.replace(/[^\p{L}\p{N}]/gu, '').length;

  if (len <= 3) return 0;
  if (len <= 5) return 1;
  if (len <= 9) return 2;
  if (len <= 11) return 3;
  if (len <= 14) return 4;
  if (len <= 17) return 5;
  return 6;
}

// Pre-compiled for performance. Letters AND digits are ORP-eligible so numeric
// tokens pivot by length the same way words do (see getORPIndex).
const orpCountable = /[\p{L}\p{N}]/u;

/**
 * The actual character index of the ORP letter, skipping non-countable
 * characters such as leading quotes.
 *
 * @param {string} word
 * @returns {number}
 */
export function getActualORPIndex(word) {
  if (!word || typeof word !== 'string') return 0;

  const cleanWord = stripBreakMarker(word);
  const orpIndex = getORPIndex(cleanWord);
  let letterCount = 0;

  for (let i = 0; i < cleanWord.length; i++) {
    if (orpCountable.test(cleanWord[i])) {
      if (letterCount === orpIndex) return i;
      letterCount++;
    }
  }

  return Math.min(orpIndex, cleanWord.length - 1);
}

/**
 * Split a word into the three display segments around its ORP letter.
 *
 * @param {string} word
 * @returns {{ before: string, orp: string, after: string }}
 */
export function splitWordForDisplay(word) {
  if (!word || typeof word !== 'string') {
    return { before: '', orp: '', after: '' };
  }

  const cleanWord = stripBreakMarker(word);
  const orpIndex = getActualORPIndex(cleanWord);

  return {
    before: cleanWord.slice(0, orpIndex),
    orp: cleanWord[orpIndex] || '',
    after: cleanWord.slice(orpIndex + 1),
  };
}

// ---------------------------------------------------------------------------
// Pacing
// ---------------------------------------------------------------------------

// Trailing characters that hide the real sentence/clause punctuation:
//   1. Footnote markers — many EPUBs emit footnote refs as bare digits glued
//      to the prior word ("theology.2", "Platonism,1"), or as superscripts.
//   2. Closing quotation marks — dialogue ends in '."', '?"' etc, where the
//      terminal char is the quote, not the punctuation.
//   3. Closing brackets — "(end of phrase.)", "[note.]".
// Without stripping these, the period/comma is invisible to the tests below
// and the pause silently doesn't fire — the reader feels the sentence blow
// past with no beat.
const TRAILING_NOISE = /[0-9¹²³⁴⁵⁶⁷⁸⁹⁰"'’”\)\]\}»›]+$/;
const TRAILING_PUNCT = /[.!?;:,]+$/;

/**
 * Attenuate punctuation pauses on short words.
 *
 * Every word gets SOME pause — the rhythm of "...he ran home." lives in that
 * beat — but a 2-letter word taking the full multiplier reads as a hitch,
 * because the eye has already absorbed it well inside the baseline interval.
 *
 * @param {number} letterLength
 * @returns {number} scale in [0.3, 1]
 */
function shortWordScale(letterLength) {
  if (letterLength <= 1) return 0.3;
  if (letterLength === 2) return 0.4;
  if (letterLength <= 5) return 0.6;
  if (letterLength === 6) return 0.8;
  return 1;
}

/**
 * How long to hold a word on screen, in milliseconds.
 *
 * @param {string} word - token, possibly carrying a '⟩' break marker
 * @param {number} wordsPerMinute
 * @param {boolean} [pauseOnPunctuation=true]
 * @param {number} [punctuationMultiplier=2] - multiplier at sentence ends
 * @param {number} [wordLengthMultiplier=0] - % added per char past 12
 * @param {number} [lineBreakMultiplier=3] - multiplier for a '\n' beat
 * @returns {number} delay in ms
 */
export function getWordDelay(
  word,
  wordsPerMinute,
  pauseOnPunctuation = true,
  punctuationMultiplier = 2,
  wordLengthMultiplier = 0,
  lineBreakMultiplier = 3,
) {
  if (!word || typeof word !== 'string') return 60000 / wordsPerMinute;
  if (!wordsPerMinute || wordsPerMinute <= 0) return 200; // fallback

  let baseDelay = 60000 / wordsPerMinute;

  if (word === '\n') return baseDelay * lineBreakMultiplier;

  const isFirstAfterBreak = word.startsWith('⟩');
  const cleanWord = isFirstAfterBreak ? word.substring(1) : word;

  const denoised = cleanWord.replace(TRAILING_NOISE, '');
  const letterLength = denoised.replace(TRAILING_PUNCT, '').length;
  const scale = shortWordScale(letterLength);

  // Baseline before the reorientation beat is applied. When a word is BOTH
  // first-after-break and punctuated, take the larger of the two pauses
  // rather than compounding them — stacking 1.5x by 2x gave a ~3x hitch.
  const preBreakBaseDelay = baseDelay;

  if (isFirstAfterBreak) {
    baseDelay *= 1 + 0.5 * scale;
  }

  // Long words need more time. 12+ chars is roughly two standard deviations
  // above mean English word length.
  if (wordLengthMultiplier > 0 && cleanWord.length >= 12) {
    baseDelay *= 1 + (wordLengthMultiplier / 100) * (cleanWord.length - 12);
  }

  if (pauseOnPunctuation) {
    // Em-dash and en-dash are semantic pause markers (parenthetical breaks,
    // ranges) and count as sentence-end-equivalent. Hyphen-minus inside a
    // compound like "well-known" is NOT pause-worthy.
    if (/[.!?;:—–]$/.test(denoised)) {
      const mult = 1 + (punctuationMultiplier - 1) * scale;
      return isFirstAfterBreak
        ? Math.max(baseDelay, preBreakBaseDelay * mult)
        : baseDelay * mult;
    }
    if (/,$/.test(denoised)) {
      const mult = 1 + 0.5 * scale;
      return isFirstAfterBreak
        ? Math.max(baseDelay, preBreakBaseDelay * mult)
        : baseDelay * mult;
    }
  }

  return baseDelay;
}

/**
 * Whether to pause at this index, for the pause-every-N-words setting.
 *
 * @param {number} wordIndex - 0-based
 * @param {number} pauseAfterWords - 0 disables
 * @returns {boolean}
 */
export function shouldPauseAtWord(wordIndex, pauseAfterWords) {
  if (pauseAfterWords <= 0) return false;
  if (wordIndex <= 0) return false;
  return wordIndex % pauseAfterWords === 0;
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

/**
 * Remaining reading time as "M:SS".
 *
 * @param {number} remainingWords
 * @param {number} wordsPerMinute
 * @returns {string}
 */
export function formatTimeRemaining(remainingWords, wordsPerMinute) {
  if (remainingWords <= 0 || !wordsPerMinute || wordsPerMinute <= 0) {
    return '0:00';
  }

  const seconds = Math.ceil((remainingWords / wordsPerMinute) * 60);
  const mins = Math.floor(seconds / 60);
  const secs = seconds % 60;

  return `${mins}:${secs.toString().padStart(2, '0')}`;
}

// ---------------------------------------------------------------------------
// Token helpers
// ---------------------------------------------------------------------------

/**
 * Strip the first-word-after-break marker.
 *
 * @param {string} word
 * @returns {string}
 */
export function stripBreakMarker(word) {
  if (typeof word !== 'string') return '';
  return word.startsWith('⟩') ? word.substring(1) : word;
}

/**
 * Whether a token renders as a visible word (not a break beat or whitespace).
 *
 * @param {string} token
 * @returns {boolean}
 */
export function isRenderable(token) {
  if (typeof token !== 'string') return false;
  const clean = stripBreakMarker(token);
  return clean.trim().length > 0 && clean !== '\n';
}

/**
 * A window of words centred on the current position, for multi-word display
 * modes. Break markers are stripped from every returned word.
 *
 * @param {string[]} allWords
 * @param {number} centerIdx
 * @param {number} frameSize - odd numbers recommended
 * @returns {{ subset: string[], centerOffset: number }}
 */
export function extractWordFrame(allWords, centerIdx, frameSize) {
  if (frameSize <= 1 || centerIdx >= allWords.length) {
    return { subset: [stripBreakMarker(allWords[centerIdx] || '')], centerOffset: 0 };
  }

  const radius = Math.floor(frameSize / 2);
  const leftBound = Math.max(0, centerIdx - radius);
  const rightBound = Math.min(allWords.length, centerIdx + radius + 1);

  return {
    subset: allWords.slice(leftBound, rightBound).map(stripBreakMarker),
    centerOffset: centerIdx - leftBound,
  };
}

/**
 * Nearest renderable index, searching forward from `startIndex` then backward.
 * Used when a restored reading position lands on a break token.
 *
 * @param {string[]} tokens
 * @param {number} startIndex
 * @returns {number} index, or -1 if nothing is renderable
 */
export function findNearestRenderableWordIndex(tokens, startIndex) {
  if (!Array.isArray(tokens) || tokens.length === 0) return -1;

  const clamped = Math.max(
    0,
    Math.min(tokens.length - 1, Number.isFinite(startIndex) ? startIndex : 0),
  );

  if (isRenderable(tokens[clamped])) return clamped;

  for (let i = clamped + 1; i < tokens.length; i += 1) {
    if (isRenderable(tokens[i])) return i;
  }
  for (let i = clamped - 1; i >= 0; i -= 1) {
    if (isRenderable(tokens[i])) return i;
  }

  return -1;
}
