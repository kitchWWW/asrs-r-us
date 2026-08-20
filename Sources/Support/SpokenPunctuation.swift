import Foundation

/// The dictation command set, fed to the recognizer as contextual strings.
///
/// This app is built on the assumption that a spoken "colon" arrives as the
/// word "colon", so that the rewrite prompt can decide what it meant. That assumption is worth defending at the source: the
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
}
