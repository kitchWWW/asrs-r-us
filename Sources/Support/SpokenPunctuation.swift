import Foundation

/// The dictation command set, fed to the recognizer as contextual strings and
/// as phrases in the custom language model.
///
/// This app is built on the assumption that a spoken "colon" arrives as the
/// word "colon", so that `TranscriptNormalizer` and the rewrite prompt can
/// decide what it meant. That assumption is worth defending at the source: the
/// recognizer heard "colon" as the name "Colin" in 7 of 25 logged occurrences,
/// and a word that was never produced wrong needs no repair downstream.
///
/// Biased for unconditionally, unlike `TechVocabulary`, which is a preference.
/// These are not words the user happens to use -- they are the vocabulary the
/// app's whole input path is written around.
enum SpokenPunctuation {

    static let terms: [String] = [
        "colon", "semicolon", "period", "comma", "question mark",
        "exclamation point", "new paragraph", "new line",
        "open parentheses", "close parentheses", "open quote", "close quote",
    ]

    /// Sentences that put the term where dictation puts it.
    ///
    /// The shape matters more than the word, for the reason recorded in
    /// `CustomLanguageModel.phrases(for:)`: a language model learns sequences,
    /// so the carrier has to be the sequence you actually want predicted. The
    /// generic carriers are wrong here in a specific and damaging way -- "the
    /// colon", "a colon" train the *noun*, which is the one reading that must
    /// not win. These are drawn from real dictations in the session log.
    static func carriers(for term: String) -> [String]? {
        switch term.lowercased() {
        case "colon":
            return [
                "the plan colon ship it",
                "another item for the to do list colon",
                "this is a screenshot of what I see colon",
                "one new change colon",
                "two examples are here colon",
                "I think this is my answer colon",
                "it should work like this colon",
            ]
        case "period":
            return [
                "that is all I need period",
                "we should ship it period",
                "it has to be fast period new paragraph",
            ]
        case "comma":
            return [
                "first we build it comma then we test it",
                "if that works comma we can move on",
            ]
        case "question mark":
            return [
                "can you remind me of the name question mark",
                "is that the right approach question mark",
            ]
        case "exclamation point":
            return [
                "that is exactly it exclamation point",
            ]
        case "semicolon":
            return [
                "the first part is done semicolon the second is not",
            ]
        case "new paragraph", "new line":
            return [
                "that is the first point \(term) here is the second",
                "thanks \(term) Brian",
            ]
        case "open parentheses":
            return [
                "two arguments open parentheses a path and a callback",
                "it is fast open parentheses about ten milliseconds",
            ]
        case "close parentheses":
            return [
                "a path and a callback close parentheses so pass both",
                "about ten milliseconds close parentheses on this machine",
            ]
        case "open quote":
            return [
                "add a open quote run close quote button",
                "he called it open quote the fast path close quote",
            ]
        case "close quote":
            return [
                "open quote on the nature of awe close quote",
                "the button says open quote use close quote",
            ]
        default:
            return nil
        }
    }
}
