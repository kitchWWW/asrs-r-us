import Combine
import Foundation

/// User-facing configuration. The API key lives in the keychain; everything
/// else is small enough for UserDefaults. Rewrite prompts live in
/// `ProfileStore`, not here.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Key {
        static let apiKeyAccount = "anthropic-api-key"
        static let model = "model"
        static let debounceMilliseconds = "debounceMilliseconds"
        static let restorePasteboard = "restorePasteboard"
        static let insertionMethod = "insertionMethod"
        static let backend = "rewriteBackend"
        static let localModelRepo = "localModelRepo"
        static let localPort = "localPort"
        static let llamaServerPath = "llamaServerPath"
        static let inputDeviceUID = "inputDeviceUID"
        static let hotKey = "hotKeyBinding"
        static let dictionary = "dictionary"
    }

    @Published var apiKey: String {
        didSet { Keychain.set(apiKey, for: Key.apiKeyAccount) }
    }

    @Published var model: String {
        didSet { defaults.set(model, forKey: Key.model) }
    }

    /// How long the transcript must be quiet before a rewrite is fired.
    @Published var debounceMilliseconds: Int {
        didSet { defaults.set(debounceMilliseconds, forKey: Key.debounceMilliseconds) }
    }

    @Published var restorePasteboard: Bool {
        didSet { defaults.set(restorePasteboard, forKey: Key.restorePasteboard) }
    }

    /// How text reaches the target app. Paste is fast and universal; typing
    /// never touches the pasteboard, for clipboard managers that ignore the
    /// transient-type convention.
    @Published var insertionMethod: TextInserter.Method {
        didSet { defaults.set(insertionMethod.rawValue, forKey: Key.insertionMethod) }
    }

    /// Which engine generates rewrites. Local is the default: no API key, no
    /// network, and measurably faster than a round trip for short dictation.
    @Published var backend: RewriteBackendKind {
        didSet { defaults.set(backend.rawValue, forKey: Key.backend) }
    }

    /// Hugging Face GGUF repo passed to `llama-server -hf`.
    @Published var localModelRepo: String {
        didSet { defaults.set(localModelRepo, forKey: Key.localModelRepo) }
    }

    @Published var localPort: Int {
        didSet { defaults.set(localPort, forKey: Key.localPort) }
    }

    /// Optional override when llama-server is not in a standard location.
    @Published var llamaServerPath: String {
        didSet { defaults.set(llamaServerPath, forKey: Key.llamaServerPath) }
    }

    /// CoreAudio UID of the microphone to record from. Empty means "use the
    /// built-in mic", which is the default -- deliberately not the system
    /// default input, which is often whatever headset was plugged in last.
    @Published var inputDeviceUID: String {
        didSet { defaults.set(inputDeviceUID, forKey: Key.inputDeviceUID) }
    }

    /// Words the speaker uses often that get mis-transcribed. Applies to every
    /// profile: this is the user's vocabulary, not a writing style.
    @Published var dictionary: String {
        didSet { defaults.set(dictionary, forKey: Key.dictionary) }
    }

    /// The dictionary rendered as a prompt section, or nil when empty.
    var dictionaryPromptSection: String? {
        let entries = dictionary
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !entries.isEmpty else { return nil }

        return """
        The speaker's vocabulary. These words come up often in their dictation \
        and are frequently mis-transcribed:

        \(entries.map { "- \($0)" }.joined(separator: "\n"))

        Apply these when rewriting:
        - If the transcript contains a word that sounds like one of these but is \
        spelled differently, replace it with the spelling listed here. This \
        includes correctly spelled homophones: a word can be valid English and \
        still be the wrong word. If an entry notes a word it is confused with, \
        and the transcript uses that other word where the listed one fits the \
        subject, substitute it.
        - Write listed acronyms in capitals, joining letters that were \
        transcribed separately: "a s r" becomes "ASR".
        - Do not force these words in where the speaker clearly said something \
        else, and never add them to text that did not call for them.
        """
    }

    /// Shortcut that opens the dictation window.
    @Published var hotKey: HotKeyBinding {
        didSet {
            if let data = try? JSONEncoder().encode(hotKey) {
                defaults.set(data, forKey: Key.hotKey)
            }
            onHotKeyChanged?(hotKey)
        }
    }

    /// Set by the app delegate so the event tap can be re-armed on change.
    var onHotKeyChanged: ((HotKeyBinding) -> Void)?

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            Key.model: "claude-haiku-4-5",
            Key.debounceMilliseconds: 350,
            Key.restorePasteboard: true,
            Key.insertionMethod: TextInserter.Method.paste.rawValue,
            Key.backend: RewriteBackendKind.local.rawValue,
            // Benchmarked fastest for this task on Apple Silicon: 67 ms median
            // on a short transcript, and more faithful than larger models.
            Key.localModelRepo: "bartowski/Qwen2.5-1.5B-Instruct-GGUF:Q4_K_M",
            Key.localPort: 8080,
            Key.llamaServerPath: "",
            Key.inputDeviceUID: "",
            Key.dictionary: "",
        ])
        apiKey = Keychain.string(for: Key.apiKeyAccount)
            ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
            ?? ""
        model = defaults.string(forKey: Key.model) ?? "claude-haiku-4-5"
        debounceMilliseconds = defaults.integer(forKey: Key.debounceMilliseconds)
        restorePasteboard = defaults.bool(forKey: Key.restorePasteboard)
        insertionMethod = TextInserter.Method(
            rawValue: defaults.string(forKey: Key.insertionMethod) ?? ""
        ) ?? .paste
        backend = RewriteBackendKind(
            rawValue: defaults.string(forKey: Key.backend) ?? ""
        ) ?? .local
        localModelRepo = defaults.string(forKey: Key.localModelRepo)
            ?? "bartowski/Qwen2.5-1.5B-Instruct-GGUF:Q4_K_M"
        localPort = defaults.integer(forKey: Key.localPort)
        llamaServerPath = defaults.string(forKey: Key.llamaServerPath) ?? ""
        inputDeviceUID = defaults.string(forKey: Key.inputDeviceUID) ?? ""
        dictionary = defaults.string(forKey: Key.dictionary) ?? ""
        hotKey = defaults.data(forKey: Key.hotKey)
            .flatMap { try? JSONDecoder().decode(HotKeyBinding.self, from: $0) }
            ?? .f7
    }

    var hasAPIKey: Bool { !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
