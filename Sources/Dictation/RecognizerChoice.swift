import Foundation

/// Which of the two speech modules in macOS 26 does the recognising.
///
/// They are different recognisers, not two settings of one. `SpeechTranscriber`
/// punctuates, capitalises, and formats numbers, and none of that can be turned
/// off -- its only content option is profanity masking. `DictationTranscriber`
/// takes punctuation as an opt-*in*, so asking for nothing gives back close to
/// the bare words, and it accepts a custom language model built from the
/// dictionary.
///
/// Which one wins is an empirical question, which is why this is a setting and
/// why sessions are recorded: the same audio can be replayed through both.
enum RecognizerChoice: String, CaseIterable, Identifiable, Codable {
    case punctuated
    case raw

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .punctuated: return "Punctuated (SpeechTranscriber)"
        case .raw:        return "Bare words (DictationTranscriber)"
        }
    }

    var explanation: String {
        switch self {
        case .punctuated:
            return "Keeps the words you say, including \"comma\" and \"period\", so the "
                 + "rewrite model decides what was dictation and what was content. It also "
                 + "adds punctuation at pauses that you did not say, which the prompt is "
                 + "written to strip."
        case .raw:
            return "Inserts no punctuation of its own, but obeys spoken punctuation as "
                 + "commands: say \"comma\" and you get a comma, never the word. Measured "
                 + "over six utterances it kept 1 of 8 spoken punctuation words, against 6 "
                 + "of 8 for the other one. Kept as an experiment, not a recommendation."
        }
    }
}
