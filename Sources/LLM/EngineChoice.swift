import Foundation

/// One selectable rewrite engine for the dictation panel.
///
/// Mostly coarse: the choice on offer is *where the rewrite happens* -- on
/// this Mac, through Apple Intelligence, or through a hosted Claude -- not
/// which specific model within each. The exception is Bedrock, which offers
/// Sonnet 5 and Haiku 4.5 side by side so the two can be alternated from the
/// panel and compared on real dictation. Any other model ID still goes in
/// Settings.
struct EngineChoice: Identifiable, Hashable {
    let id: String
    /// Short label for the pill.
    let name: String
    /// Second line in the menu.
    let detail: String
    let backend: RewriteBackendKind
    /// The Bedrock model this entry selects; nil for engines with one entry.
    var bedrockModelID: String? = nil

    static let bedrockSonnet = "us.anthropic.claude-sonnet-5"
    static let bedrockHaiku = "us.anthropic.claude-haiku-4-5-20251001-v1:0"

    static let catalog: [EngineChoice] = [
        EngineChoice(id: "local", name: "Local",
                     detail: "Runs on this Mac · free and private",
                     backend: .local),
        EngineChoice(id: "apple", name: "Apple",
                     detail: "On-device Apple Intelligence",
                     backend: .appleIntelligence),
        EngineChoice(id: "bedrock", name: "Sonnet 5",
                     detail: "Claude via Amazon Bedrock · best quality",
                     backend: .bedrock, bedrockModelID: bedrockSonnet),
        EngineChoice(id: "bedrock-haiku", name: "Haiku 4.5",
                     detail: "Claude via Amazon Bedrock · faster, cheaper",
                     backend: .bedrock, bedrockModelID: bedrockHaiku),
        EngineChoice(id: "anthropic", name: "Anthropic",
                     detail: "Claude via the Anthropic API",
                     backend: .anthropic),
    ]

    @MainActor
    static func current(settings: AppSettings) -> EngineChoice {
        // A Bedrock model typed into Settings matches neither entry; it still
        // reads as Bedrock, and the pill names the model it is really using.
        catalog.first {
            $0.backend == settings.backend
                && ($0.bedrockModelID == nil || $0.bedrockModelID == settings.bedrockModelID)
        } ?? catalog.first { $0.backend == settings.backend } ?? catalog[0]
    }

    /// What the pill shows: the engine, plus the model when that is the thing
    /// the user is actually choosing between day to day.
    @MainActor
    func pillLabel(settings: AppSettings) -> String {
        switch backend {
        case .bedrock:   return Self.shortModel(settings.bedrockModelID)
        case .local:     return Self.shortModel(settings.localModelRepo)
        default:         return name
        }
    }

    /// "us.anthropic.claude-haiku-4-5-20251001-v1:0" -> "Haiku 4.5"
    /// "bartowski/Qwen2.5-7B-Instruct-GGUF:Q4_K_M"   -> "Qwen 7B"
    static func shortModel(_ model: String) -> String {
        let lower = model.lowercased()
        for (needle, label) in [("haiku-4-5", "Haiku 4.5"), ("sonnet-5", "Sonnet 5"),
                                ("sonnet-4-6", "Sonnet 4.6"), ("opus-5", "Opus 5"),
                                ("opus-4-8", "Opus 4.8")] where lower.contains(needle) {
            return label
        }
        if let range = lower.range(of: #"qwen[\d.]*-([\d.]+b)"#, options: .regularExpression) {
            return "Qwen " + lower[range].split(separator: "-").last!.uppercased()
        }
        return model.split(separator: "/").last.map(String.init) ?? model
    }
}
