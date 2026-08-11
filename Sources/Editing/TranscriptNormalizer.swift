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

    static func normalize(_ text: String) -> String {
        var result = text

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
    private static func tidy(_ text: String) -> String {
        var result = text
        for (pattern, template) in [
            ("[ \\t]+([.,?!;:])", "$1"),     // no space before punctuation
            ("([.,?!;:])\\1+", "$1"),        // never repeat a mark
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
