import Foundation

/// Which recogniser turns audio into words.
///
/// Two of these are macOS 26's own speech modules and two are local models run
/// in a sidecar process. They are different recognisers, not settings of one.
/// `SpeechTranscriber` punctuates, capitalises, and formats numbers, and none
/// of that can be turned off -- its only content option is profanity masking.
/// `DictationTranscriber` takes punctuation as an opt-*in*, so asking for
/// nothing gives back close to the bare words, and it accepts a custom language
/// model built from the dictionary.
///
/// The two sidecar models were picked by measurement, not preference. Over 28
/// recordings from the session log they invented **zero** punctuation -- a
/// transducer with no punctuation head cannot write a mark it was not given --
/// against 13.75 marks per 100 words for `SpeechTranscriber`, and they kept
/// half again as many spoken punctuation words as it did. The harness and the
/// full table are in `Evals/verbatim/`.
///
/// Which one wins is still an empirical question, which is why this is a
/// setting and why sessions are recorded: the same audio can be replayed
/// through all four.
enum RecognizerChoice: String, CaseIterable, Identifiable, Codable {
    case punctuated
    case raw
    case nemo
    case vosk

    var id: String { rawValue }

    /// Whether this recogniser runs in the sidecar rather than in-process.
    var isSidecar: Bool {
        switch self {
        case .punctuated, .raw: return false
        case .nemo, .vosk:      return true
        }
    }

    /// The engine name the sidecar is started with.
    var sidecarEngine: String? {
        switch self {
        case .nemo: return "sherpa"
        case .vosk: return "vosk"
        default:    return nil
        }
    }

    /// Subdirectory of the model store this recogniser loads from.
    var modelDirectoryName: String? {
        switch self {
        case .nemo: return "sherpa-onnx-nemo-streaming-fast-conformer-transducer-en-1040ms"
        case .vosk: return "vosk-model-en-us-0.22"
        default:    return nil
        }
    }

    /// Whether this recogniser ever takes back text it has already shown.
    ///
    /// This is what makes a "final" worth anything. `RewriteService` lets
    /// finals skip the debounce, on the reasoning that settled words are not
    /// speculative -- but that only holds for a recogniser whose *volatile*
    /// text is speculative in the first place. Measured over 6.5 minutes of
    /// real dictation (`Evals/verbatim/cadence.py`): Apple and Vosk revise,
    /// Vosk 20 times; the NeMo transducer revised zero times, because a
    /// transducer only ever appends. For that one every update is already as
    /// final as it will ever be, so treating its endpoints as finals would buy
    /// nothing and bill a rewrite for it.
    var revisesText: Bool {
        switch self {
        case .punctuated, .raw, .vosk: return true
        case .nemo:                    return false
        }
    }

    /// Shortest debounce that still coalesces anything, given how often this
    /// recogniser actually emits.
    ///
    /// Measured updates per minute of speech: NeMo 28.7, Vosk 59.4 -- roughly
    /// one every 2.1s and 1.0s. A 200 ms debounce is therefore *inert* for
    /// both: updates arrive far enough apart that every one survives it and
    /// becomes a request. Raising the floor to something near the real spacing
    /// is what makes the debounce do its job rather than merely appear to.
    ///
    /// This is a floor, not an override: the per-engine setting still applies
    /// and the larger of the two wins. It is also not the main protection
    /// against a token bill -- that is `minimumRewriteIntervalMilliseconds`,
    /// because no debounce can help when updates are already seconds apart.
    var debounceFloorMilliseconds: Int {
        switch self {
        case .punctuated, .raw: return 0      // the engine setting was tuned here
        case .nemo:             return 700
        case .vosk:             return 500
        }
    }

    /// The recognisers that run together when cross-checking is on.
    ///
    /// Deliberately two, not all of them. They are the pair that disagree
    /// usefully: Apple punctuates and normalises, the transducer writes bare
    /// words, so where they differ it is almost always about *which word was
    /// said* rather than about formatting. Vosk is excluded despite scoring
    /// well -- its model is 2.7 GB resident, and a third opinion is worth much
    /// less than the second one. Selecting Vosk still runs it as the primary;
    /// this list only governs who rides along.
    static let crossCheckSet: [RecognizerChoice] = [.punctuated, .nemo]

    /// The recognisers actually on offer.
    ///
    /// `.raw` is not among them. It is a measured dead end -- `DictationTranscriber`
    /// obeys spoken punctuation as commands in every configuration, so "comma"
    /// becomes "," and the word is gone, which is the one thing this app cannot
    /// have. It stays selectable so a session recorded with it can be replayed,
    /// but listing it beside the others implies a peer.
    static let primary: [RecognizerChoice] = [.punctuated, .nemo, .vosk]

    /// Short label for a picker row.
    var shortName: String {
        switch self {
        case .punctuated: return "Apple"
        case .raw:        return "Apple (bare words)"
        case .nemo:       return "NeMo FastConformer"
        case .vosk:       return "Vosk en-us 0.22"
        }
    }

    /// One line of what picking this costs and buys, from the bake-off in
    /// `Evals/verbatim/`. Kept next to the choice rather than typed into the
    /// view, so the numbers cannot drift apart from the thing they describe.
    var measurements: String? {
        switch self {
        case .punctuated:
            return "13.75 invented marks / 100 words · 0.69s word delay · nothing to install"
        case .raw:
            return "destroys spoken punctuation · kept as a replay path only"
        case .nemo:
            return "0.00 invented marks · 0.86s word delay · 457 MB model"
        case .vosk:
            return "0.00 invented marks · 0.58s word delay · 2.7 GB model"
        }
    }

    var displayName: String {
        switch self {
        case .punctuated: return "Punctuated (Apple SpeechTranscriber)"
        case .raw:        return "Bare words (Apple DictationTranscriber)"
        case .nemo:       return "NeMo FastConformer 1040 ms"
        case .vosk:       return "Vosk en-us 0.22"
        }
    }

    var explanation: String {
        switch self {
        case .punctuated:
            return "Keeps the words you say, including \"comma\" and \"period\", so the "
                 + "rewrite model decides what was dictation and what was content. It also "
                 + "adds punctuation at pauses that you did not say, which the prompt is "
                 + "written to strip. Measured at 13.75 invented marks per 100 words."
        case .raw:
            return "Inserts no punctuation of its own, but obeys spoken punctuation as "
                 + "commands: say \"comma\" and you get a comma, never the word. Measured "
                 + "over six utterances it kept 1 of 8 spoken punctuation words, against 6 "
                 + "of 8 for the other one. Kept as an experiment, not a recommendation."
        case .nemo:
            return "NVIDIA cache-aware streaming FastConformer, run locally in the sidecar. "
                 + "Invents no punctuation at all and keeps every spoken punctuation word, "
                 + "so the rewrite prompt does all the marking. Measured at 0.86s mean word "
                 + "delay -- the slowest of the candidates, and still inside the budget."
        case .vosk:
            return "Kaldi-based streaming recogniser, run locally in the sidecar. Invents no "
                 + "punctuation and kept the most spoken punctuation words of any streaming "
                 + "model tested, at 0.58s mean word delay. Needs a 1.8 GB model on disk."
        }
    }
}
