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
///
/// Spoken "colon" is the one single occurrence that is resolved here anyway --
/// see `colonSpellings` for why it does not behave like "period" and "comma".
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
        // "colon" is not here: it never reaches these rules with a mark
        // beside it or a twin behind it, so it is resolved on its own below.
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

    /// How the recogniser spells a spoken colon.
    ///
    /// This one is resolved in code even as a single occurrence, which the rest
    /// of this file treats as too ambiguous to touch. It earns the exception on
    /// the evidence: across 565 logged sessions every one of the 25 occurrences
    /// was dictation, the recogniser never once wrote the mark itself, and it
    /// heard the word as a name ("Colin", "Colon") in 7 of them. It also wraps
    /// what it heard in punctuation it invented -- "the list, colon. We should"
    /// -- so the model had four repairs to make at once and dropped the word
    /// outright on short fragments, which is exactly when it is dictated.
    ///
    /// Deliberately unguarded, at Brian's instruction: talking *about* a colon
    /// ("the colon comes after the greeting") loses its word too. He dictates
    /// the mark far more often than he discusses it, knows nobody named Colin,
    /// and sees the result in the panel before anything is pasted. Note that
    /// the plural "colons" and the word "semicolon" both survive untouched --
    /// neither is this token, so neither matches.
    private static let colonSpellings = ["colon", "colin", "collin"]

    static func normalize(_ text: String) -> String {
        var result = text

        // Spoken colons, resolved before anything else so the marks the
        // recogniser wedged around the word are absorbed here rather than
        // colliding with each other later. It eats a comma in front and a
        // comma or full stop behind, because those are its invention and not
        // something the speaker said: "the list, colon. We should" is "the
        // list: We should". Capitalisation of the following word is left to
        // the model, which has the context to know a proper noun from a
        // sentence that merely carries on.
        let colonAlternatives = colonSpellings.joined(separator: "|")
        if let regex = try? NSRegularExpression(
            pattern: "[ \\t]*,?[ \\t]*\\b(?:\(colonAlternatives))\\b[ \\t]*[.,]?[ \\t]*",
            options: [.caseInsensitive]
        ) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ": "
            )
        }

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
    /// period" arrives as ",." -- mechanical, one right answer, no context to
    /// weigh, so it is resolved here rather than left for the model, which was
    /// reproducing it verbatim. When two different marks collide the weaker
    /// one loses, a comma to anything and a full stop to a spoken "?" or "!".
    ///
    /// A comma against a closing quotation mark is *not* in that set, despite
    /// arriving the same way: ",\u{201D}" is also how correct English is
    /// punctuated, so there is no one right answer to apply blind. That one
    /// stays with the model, which can see whether the comma belongs.
    private static func tidy(_ text: String) -> String {
        var result = text
        for (pattern, template) in [
            ("[ \\t]+([.,?!;:])", "$1"),     // no space before punctuation
            ("([.,?!;:])\\1+", "$1"),        // never repeat a mark
            (",+([.?!;:])", "$1"),          // a comma against a stronger mark loses
            ("([.?!;:]),+", "$1"),          // whichever side it landed on
            ("\\.+([?!])", "$1"),           // and a full stop loses to a spoken ? or !
            ("([?!])\\.+", "$1"),
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
