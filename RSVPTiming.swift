import Foundation

/// RSVP timing engine — Optimal Recognition Point (ORP) and per-word pacing.
///
/// Derived from thomaskolmans/rsvp-reading (MIT). See NOTICE for the full
/// attribution chain; the MIT terms require it to travel with this file.
///
/// Parity-locked to `rsvpTiming.js`. `parity-vectors.json` is the shared golden
/// fixture both sides must reproduce exactly; run the parity check before
/// changing any threshold here.
///
/// Token conventions (shared with the tokenizer module):
///   - `"\n"`       a paragraph-break token (renders as a blank beat)
///   - `"⟩"` prefix marks the first word after a break (reorientation beat)
public enum RSVPTiming {

    // MARK: - ORP (Optimal Recognition Point)

    /// Letters AND numbers are ORP-countable; punctuation is not. A pure-number
    /// token ("2026", "12,345") would otherwise pivot on its first digit
    /// instead of being centred like a word.
    ///
    /// This must match the JS twin's `\p{L}\p{N}`, so it spans every Unicode
    /// number category — not just decimal digits. `CharacterSet.decimalDigits`
    /// is Nd-only and silently excludes superscripts (Nd vs No), which made
    /// footnote-marked words like "hierarchies.¹" pivot on a different letter
    /// than iOS. `Character.isNumber` covers Nd, Nl and No.
    private static func isORPCountable(_ char: Character) -> Bool {
        char.isLetter || char.isNumber
    }

    /// Length → ORP letter position.
    ///
    ///   1-3 letters → 1st letter      12-14 → 5th
    ///   4-5         → 2nd             15-17 → 6th
    ///   6-9         → 3rd             18+   → 7th
    ///   10-11       → 4th
    public static func getORPIndex(for word: String) -> Int {
        let clean = stripBreakMarker(word)
        let count = clean.filter(isORPCountable).count

        if count <= 3 { return 0 }
        if count <= 5 { return 1 }
        if count <= 9 { return 2 }
        if count <= 11 { return 3 }
        if count <= 14 { return 4 }
        if count <= 17 { return 5 }
        return 6
    }

    /// The actual character offset of the ORP letter, skipping non-countable
    /// characters such as leading quotes.
    ///
    /// Offsets are counted in `Character`s (not unicode scalars) so the result
    /// can be used directly with `String.index(_:offsetBy:)` — counting scalars
    /// here would drift on combining marks and emoji, and would also diverge
    /// from the JS twin, which counts UTF-16 units.
    public static func getActualORPIndex(for word: String) -> Int {
        let clean = stripBreakMarker(word)
        guard !clean.isEmpty else { return 0 }

        let orpIndex = getORPIndex(for: clean)
        var count = 0

        for (i, char) in clean.enumerated() where isORPCountable(char) {
            if count == orpIndex { return i }
            count += 1
        }

        return min(orpIndex, clean.count - 1)
    }

    /// Split a word into the three display segments around its ORP letter.
    public static func splitWordForDisplay(
        _ word: String
    ) -> (before: String, orp: String, after: String) {
        let clean = stripBreakMarker(word)
        guard !clean.isEmpty else { return ("", "", "") }

        let orpIdx = getActualORPIndex(for: clean)
        let start = clean.startIndex
        let orpIndex = clean.index(start, offsetBy: orpIdx, limitedBy: clean.endIndex)
            ?? clean.index(before: clean.endIndex)
        let afterIndex = clean.index(after: orpIndex)

        return (
            before: String(clean[start..<orpIndex]),
            orp: String(clean[orpIndex]),
            after: afterIndex < clean.endIndex ? String(clean[afterIndex...]) : ""
        )
    }

    // MARK: - Pacing

    /// Trailing characters that hide the real sentence/clause punctuation:
    /// footnote markers glued to the prior word ("theology.2"), closing quotes
    /// ('."', '?"'), and closing brackets. Without stripping these, the pause
    /// silently doesn't fire and the sentence blows past with no beat.
    private static let trailingNoise =
        "[0-9\u{00B9}\u{00B2}\u{00B3}\u{2070}-\u{2079}\"'\u{2018}\u{2019}\u{201C}\u{201D})\\]}\u{00BB}\u{203A}]+$"
    private static let trailingPunct = "[.!?;:,]+$"

    /// Attenuate punctuation pauses on short words. Every word keeps SOME
    /// pause — the rhythm lives in that beat — but a 2-letter word taking the
    /// full multiplier reads as a hitch, since the eye has already absorbed it
    /// well inside the baseline interval.
    private static func shortWordScale(_ letterLength: Int) -> Double {
        if letterLength <= 1 { return 0.3 }
        if letterLength == 2 { return 0.4 }
        if letterLength <= 5 { return 0.6 }
        if letterLength == 6 { return 0.8 }
        return 1.0
    }

    /// How long to hold a word on screen, in milliseconds.
    public static func getWordDelay(
        for word: String,
        wpm: Int,
        pauseOnPunctuation: Bool = true,
        punctuationMultiplier: Double = 2.0,
        wordLengthMultiplier: Double = 0,
        lineBreakMultiplier: Double = 3.0
    ) -> Double {
        guard !word.isEmpty else { return 60_000.0 / Double(max(1, wpm)) }
        guard wpm > 0 else { return 200 }

        var baseDelay = 60_000.0 / Double(wpm)

        if word == "\n" { return baseDelay * lineBreakMultiplier }

        let isFirstAfterBreak = word.hasPrefix("⟩")
        let clean = isFirstAfterBreak ? String(word.dropFirst()) : word

        let denoised = clean.replacingOccurrences(
            of: trailingNoise, with: "", options: .regularExpression)
        let letterLength = denoised.replacingOccurrences(
            of: trailingPunct, with: "", options: .regularExpression).count
        let scale = shortWordScale(letterLength)

        // Baseline before the reorientation beat. When a word is BOTH
        // first-after-break and punctuated, take the larger of the two pauses
        // rather than compounding them — stacking 1.5x by 2x gave a ~3x hitch.
        let preBreakBaseDelay = baseDelay

        if isFirstAfterBreak {
            baseDelay *= 1.0 + 0.5 * scale
        }

        // Long words need more time. 12+ chars is roughly two standard
        // deviations above mean English word length.
        if wordLengthMultiplier > 0 && clean.count >= 12 {
            baseDelay *= 1.0 + (wordLengthMultiplier / 100.0) * Double(clean.count - 12)
        }

        if pauseOnPunctuation {
            // Em/en-dash are semantic pause markers and count as
            // sentence-end-equivalent. Hyphen-minus inside a compound like
            // "well-known" is NOT pause-worthy.
            if let last = denoised.last, ".!?;:—–".contains(last) {
                let mult = 1.0 + (punctuationMultiplier - 1.0) * scale
                return isFirstAfterBreak
                    ? max(baseDelay, preBreakBaseDelay * mult)
                    : baseDelay * mult
            }
            if denoised.hasSuffix(",") {
                let mult = 1.0 + 0.5 * scale
                return isFirstAfterBreak
                    ? max(baseDelay, preBreakBaseDelay * mult)
                    : baseDelay * mult
            }
        }

        return baseDelay
    }

    /// Whether to pause at this index, for the pause-every-N-words setting.
    public static func shouldPauseAtWord(index: Int, pauseAfterWords: Int) -> Bool {
        guard pauseAfterWords > 0, index > 0 else { return false }
        return index % pauseAfterWords == 0
    }

    // MARK: - Formatting

    /// Remaining reading time as "M:SS".
    public static func formatTimeRemaining(wordsRemaining: Int, wpm: Int) -> String {
        guard wordsRemaining > 0, wpm > 0 else { return "0:00" }

        let totalSeconds = Int(ceil(Double(wordsRemaining) / Double(wpm) * 60.0))
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
    }

    // MARK: - Token helpers

    /// Strip the first-word-after-break marker.
    public static func stripBreakMarker(_ word: String) -> String {
        word.hasPrefix("⟩") ? String(word.dropFirst()) : word
    }

    /// Whether a token renders as a visible word (not a break beat or whitespace).
    public static func isRenderable(_ token: String) -> Bool {
        let clean = stripBreakMarker(token)
        return !clean.trimmingCharacters(in: .whitespaces).isEmpty && clean != "\n"
    }

    /// A window of words centred on the current position, for multi-word
    /// display modes. Break markers are stripped from every returned word.
    public static func extractWordFrame(
        _ allWords: [String],
        centerIndex: Int,
        frameSize: Int
    ) -> (subset: [String], centerOffset: Int) {
        guard frameSize > 1, centerIndex < allWords.count else {
            let word = centerIndex >= 0 && centerIndex < allWords.count
                ? allWords[centerIndex] : ""
            return ([stripBreakMarker(word)], 0)
        }

        let radius = frameSize / 2
        let lower = max(0, centerIndex - radius)
        let upper = min(allWords.count, centerIndex + radius + 1)

        return (allWords[lower..<upper].map(stripBreakMarker), centerIndex - lower)
    }

    /// Nearest renderable index, searching forward from `startIndex` then
    /// backward. Used when a restored reading position lands on a break token.
    public static func findNearestRenderableIndex(
        in tokens: [String],
        from startIndex: Int
    ) -> Int? {
        guard !tokens.isEmpty else { return nil }
        let clamped = max(0, min(tokens.count - 1, startIndex))

        if isRenderable(tokens[clamped]) { return clamped }

        for i in (clamped + 1)..<tokens.count where isRenderable(tokens[i]) { return i }
        for i in stride(from: clamped - 1, through: 0, by: -1)
            where isRenderable(tokens[i]) { return i }

        return nil
    }
}
