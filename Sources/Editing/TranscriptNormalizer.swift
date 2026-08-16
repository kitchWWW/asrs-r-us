import Foundation

/// Mechanical clean-up applied to the transcript before it reaches the model.
///
/// A *run* of the same spoken punctuation word ("period period") is
/// unambiguously punctuation -- nobody dictates that as content -- so it is
/// resolved in code, where the answer is exact. A *single* occurrence is
/// genuinely ambiguous ("the sentence ended with a period") and is left for the
/// model to judge in context.
///
/// This split exists because the model proved unreliable at the mechanical
/// half: prose rules about collapsing runs either failed outright, or needed a
/// worked example that then leaked its own words into the output.
enum TranscriptNormalizer {

    /// Longer phrases first, so "question mark question mark" matches as a
    /// phrase instead of collapsing on the shared word "mark".
    private static let replacements: [(phrase: String, mark: String)] = [
        ("question mark", "?"),
        ("exclamation point", "!"),
        ("exclamation mark", "!"),
        ("new paragraph", "\n\n"),
        ("new line", "\n"),
        ("semicolon", ";"),
        ("colon", ":"),
        ("period", "."),
        ("comma", ","),
    ]

    /// Spoken punctuation that is unambiguous on its own. The Bool is whether
    /// the mark attaches to the word that follows it rather than the one before.
    private static let alwaysResolved: [(phrase: String, mark: String, attachesForward: Bool)] = [
        ("open parentheses", "(", true),
        ("open parenthesis", "(", true),
        ("open bracket", "(", true),
        ("open parens", "(", true),
        ("open paren", "(", true),
        ("close parentheses", ")", false),
        ("close parenthesis", ")", false),
        // "closed" and "end" are how the recognizer usually hears "close"
        // here. None of these is a phrase anyone says about anything else.
        ("closed parentheses", ")", false),
        ("closed parenthesis", ")", false),
        ("end parentheses", ")", false),
        ("end parenthesis", ")", false),
        ("close bracket", ")", false),
        ("close parens", ")", false),
        ("closed parens", ")", false),
        ("close paren", ")", false),
        ("closed paren", ")", false),
        ("open quote", "\u{201C}", true),
        ("close quote", "\u{201D}", false),
    ]

    static func normalize(_ text: String) -> String {
        var result = text

        // Phrases that are dictation even as a single occurrence. "period" has
        // to stay ambiguous because it is an ordinary word, but nobody says
        // "open parenthesis" except to dictate one -- so these resolve on sight,
        // and attach to the word they wrap rather than floating on their own.
        for (phrase, mark, attachesForward) in alwaysResolved {
            let escaped = NSRegularExpression.escapedPattern(for: phrase)
            let pattern = attachesForward
                ? "\\b\(escaped)\\b[ \\t]*"     // "( word"  -> "(word"
                : "[ \\t]*\\b\(escaped)\\b"     // "word )"  -> "word)"
            guard let regex = try? NSRegularExpression(
                pattern: pattern, options: [.caseInsensitive]
            ) else { continue }
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: NSRegularExpression.escapedTemplate(for: mark)
            )
        }

        // A spoken punctuation word sitting directly against its own mark --
        // "question mark?" -- is always dictation, never content, so it is safe
        // to resolve without guessing. This is the common case: the recognizer
        // inserts the punctuation *and* leaves the words behind.
        for (phrase, mark) in replacements where !mark.hasPrefix("\n") {
            let escapedPhrase = NSRegularExpression.escapedPattern(for: phrase)
            let escapedMark = NSRegularExpression.escapedPattern(for: mark)
            for pattern in [
                "[ \\t]*\\b\(escapedPhrase)\\b[ \\t]*\(escapedMark)",  // words then mark
                "\(escapedMark)[ \\t]*\\b\(escapedPhrase)\\b",          // mark then words
            ] {
                guard let regex = try? NSRegularExpression(
                    pattern: pattern, options: [.caseInsensitive]
                ) else { continue }
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: NSRegularExpression.escapedTemplate(for: mark)
                )
            }
        }

        for (phrase, mark) in replacements {
            let escaped = NSRegularExpression.escapedPattern(for: phrase)
            // Two or more of the same phrase in a row, absorbing surrounding
            // spaces and any stray comma the recognizer wedged between them.
            let pattern = "[ \\t]*\\b\(escaped)\\b(?:[\\s,]+\(escaped)\\b)+[ \\t]*"
            guard let regex = try? NSRegularExpression(
                pattern: pattern, options: [.caseInsensitive]
            ) else { continue }

            let template = mark.hasPrefix("\n") ? mark : "\(mark) "
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: NSRegularExpression.escapedTemplate(for: template)
            )
        }

        return tidy(result)
    }

    /// Removes the artefacts substitution leaves behind: a space before a mark,
    /// and doubled spaces where a run was absorbed.
    ///
    /// The collisions are worth spelling out, because they are the visible
    /// half of this file's job. The recognizer punctuates pauses, so a spoken
    /// mark almost always lands next to one it already inserted: "system,
    /// period" arrives as ",." and "statistics, close quote" as ",\u{201D}".
    /// Both are mechanical -- there is exactly one right answer and no context
    /// to weigh -- so they are resolved here rather than left for the model,
    /// which was reproducing them verbatim.
    private static func tidy(_ text: String) -> String {
        var result = text
        for (pattern, template) in [
            ("[ \\t]+([.,?!;:])", "$1"),     // no space before punctuation
            ("([.,?!;:])\\1+", "$1"),        // never repeat a mark
            ("\\([ \\t]+", "("),             // no gap after an opening bracket
            ("[ \\t]+\\)", ")"),             // no gap before a closing one
            ("[ \\t]{2,}", " "),             // collapse runs of spaces
            ("[ \\t]+\\n", "\n"),            // no trailing space on a line
        ] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: template
            )
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
