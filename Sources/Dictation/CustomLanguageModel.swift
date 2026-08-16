import Foundation
import OSLog
import Speech

/// Builds a custom language model out of the user's dictionary, so the
/// recogniser is biased toward their words before it ever produces a wrong
/// one.
///
/// This goes further than `AnalysisContext.contextualStrings`, which nudges an
/// already-trained model at recognition time. A custom language model is
/// compiled from phrases and handed to `DictationTranscriber` as a content
/// hint, and it is the only way to teach it a token it has never seen -- an
/// email address, a band name, a project codename. Fixing a term here means the
/// wrong word never exists, which beats asking the rewrite model to spot and
/// repair it downstream with no idea what was actually said.
///
/// Compiling is slow enough to be worth caching, so the compiled model is
/// keyed by a digest of the dictionary and rebuilt only when that changes.
@MainActor
enum CustomLanguageModel {

    private static let log = Logger(subsystem: "com.brianellis.ASRs-R-US", category: "language-model")

    /// A compiled model for these terms, or nil if there is nothing to teach
    /// or the build failed. Biasing is an enhancement: a failure here has to
    /// leave dictation working.
    static func configuration(
        terms: [String],
        locale: Locale
    ) async -> SFSpeechLanguageModel.Configuration? {
        guard !terms.isEmpty else { return nil }

        // Keyed on the phrases, not the terms they came from: changing how a
        // term is wrapped changes what the model learns, and a digest that
        // could not see that difference would serve a stale model back.
        let phrases = phrases(for: terms)
        let digest = digest(of: phrases, locale: locale)
        let directory = self.directory
        let modelURL = directory.appendingPathComponent("\(digest).bin")
        let vocabularyURL = directory.appendingPathComponent("\(digest).vocab")
        let configuration = SFSpeechLanguageModel.Configuration(
            languageModel: modelURL, vocabulary: vocabularyURL
        )

        // Already compiled for exactly this dictionary.
        if FileManager.default.fileExists(atPath: modelURL.path) {
            return configuration
        }

        let assetURL = directory.appendingPathComponent("\(digest).json")
        do {
            let data = SFCustomLanguageModelData(
                locale: locale,
                identifier: Bundle.main.bundleIdentifier ?? "com.brianellis.ASRs-R-US",
                version: digest
            ) {
                for phrase in phrases {
                    // The count is a weight, not a measurement: it says how
                    // much more likely this phrase is than the recogniser
                    // would otherwise assume.
                    SFCustomLanguageModelData.PhraseCount(phrase: phrase, count: 50)
                }
            }
            try await data.export(to: assetURL)
            try await SFSpeechLanguageModel.prepareCustomLanguageModel(
                for: assetURL, configuration: configuration
            )
            // The exported phrases are only an input to the compiler.
            try? FileManager.default.removeItem(at: assetURL)

            log.info("compiled a language model from \(terms.count) dictionary terms")
            sweepStaleModels(keeping: digest)
            return configuration
        } catch {
            log.error("could not compile the custom language model: \(error.localizedDescription)")
            return nil
        }
    }

    /// Wraps each term in short carrier phrases.
    ///
    /// Measured, not assumed: a model built from the bare words barely moved
    /// the recogniser -- "Carmin" still came back "Carmen" and "highkey" still
    /// came back "highly". The same words inside sentences fixed both. A
    /// language model is a model of *sequences*, so a lone token teaches it
    /// almost nothing about when to expect that token.
    ///
    /// The carriers are chosen by the shape of the term because a wrong one is
    /// worse than none: "the brian.e2014@gmail.com" is a sentence nobody says,
    /// and training on it spends the model's weight on nonsense.
    static func phrases(for terms: [String]) -> [String] {
        terms.flatMap { term -> [String] in
            let carriers: [String]
            if term.contains("@") {
                carriers = ["my email is \(term)", "send it to \(term)", "email \(term)"]
            } else if term.contains("://") || term.contains(".com") || term.contains("/") {
                carriers = ["go to \(term)", "open \(term)", "the link is \(term)"]
            } else {
                carriers = ["the \(term)", "a \(term)", "\(term) is", "it was \(term)"]
            }
            return [term] + carriers
        }
    }

    /// `~/Library/Application Support/ASRs-R-US/language-model/`
    private static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ASRs-R-US", isDirectory: true)
            .appendingPathComponent("language-model", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    /// Stable across launches -- `hashValue` is not, and a seed that changes
    /// every launch would recompile the model every launch.
    private static func digest(of phrases: [String], locale: Locale) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in (phrases.joined(separator: "\n") + locale.identifier).utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 36)
    }

    /// The dictionary changing leaves the previous compilation behind.
    private static func sweepStaleModels(keeping digest: String) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return
        }
        for name in names where !name.hasPrefix(digest) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
