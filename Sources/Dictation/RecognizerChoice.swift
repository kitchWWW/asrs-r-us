import Foundation

/// Which recogniser turns audio into words.
///
/// Both of these run on every dictation, and there is no setting: the pair was
/// chosen by measurement and there is nothing left to pick between. Over 28
/// recordings from the session log the transducer invented **zero** punctuation
/// marks -- one with no punctuation head cannot write a mark it was not given --
/// against 13.75 per 100 words for `SpeechTranscriber`, and it kept half again
/// as many spoken punctuation words. So the transducer is the record and Apple
/// rides along, because the two mishear different things and their disagreement
/// is what settles a word. The harness is in `Evals/verbatim/`.
///
/// Two others were measured and are gone: Vosk scored well but needed a 2.7 GB
/// model resident for a third opinion worth much less than the second, and
/// `DictationTranscriber` obeys spoken punctuation as commands in every
/// configuration -- "comma" becomes "," and the word is unrecoverable, which is
/// the one thing this app cannot have.
enum RecognizerChoice: String, CaseIterable, Identifiable, Codable {
    /// NVIDIA cache-aware streaming FastConformer, in the sidecar. Bare
    /// lowercase words, no punctuation, no digits. Fills the panel.
    case nemo
    /// Apple's `SpeechTranscriber`, in process. Punctuates and capitalises on
    /// its own. Never shown; consulted only where a word looks wrong.
    case punctuated

    var id: String { rawValue }

    /// The recogniser whose text is the transcript.
    static let record: RecognizerChoice = .nemo
    /// The one that rides along as a second reading of the same audio.
    static let crossCheck: RecognizerChoice = .punctuated

    /// Whether this recogniser runs in the sidecar rather than in-process.
    var isSidecar: Bool { self == .nemo }

    /// The engine name the sidecar is started with.
    var sidecarEngine: String? { self == .nemo ? "sherpa" : nil }

    /// Subdirectory of the model store this recogniser loads from.
    var modelDirectoryName: String? {
        self == .nemo
            ? "sherpa-onnx-nemo-streaming-fast-conformer-transducer-en-1040ms"
            : nil
    }

    /// How the prompt refers to this recogniser when quoting its reading.
    var shortName: String {
        switch self {
        case .nemo:       return "NeMo FastConformer"
        case .punctuated: return "Apple"
        }
    }

    /// Whether this recogniser ever takes back text it has already shown.
    ///
    /// This is what makes a "final" worth anything. `RewriteService` lets
    /// finals skip the debounce, on the reasoning that settled words are not
    /// speculative -- but that only holds for a recogniser whose *volatile*
    /// text is speculative in the first place. Measured over 6.5 minutes of
    /// real dictation (`Evals/verbatim/cadence.py`): Apple revises; the
    /// transducer revised zero times, because a transducer only ever appends.
    /// For that one every update is already as final as it will ever be, so
    /// treating its endpoints as finals would buy nothing and bill a rewrite.
    var revisesText: Bool { self == .punctuated }

    /// Shortest debounce that still coalesces anything, given how often this
    /// recogniser actually emits.
    ///
    /// Measured updates per minute of speech: 28.7 for the transducer, roughly
    /// one every two seconds. A 200 ms debounce is therefore *inert* -- updates
    /// arrive far enough apart that every one survives it and becomes a
    /// request. This is a floor, not an override: the per-engine setting still
    /// applies and the larger of the two wins. It is also not the main
    /// protection against a token bill -- that is
    /// `minimumRewriteIntervalMilliseconds`, because no debounce can help when
    /// updates are already seconds apart.
    var debounceFloorMilliseconds: Int { self == .nemo ? 700 : 0 }
}
