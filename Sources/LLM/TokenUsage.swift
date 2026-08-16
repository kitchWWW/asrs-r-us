import Foundation

/// Token counts for one billed request.
struct TokenUsage {
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    /// Tokens written to the prompt cache. Billed at a premium over plain input.
    let cacheWriteTokens: Int
    /// Tokens served from the prompt cache. Billed at roughly a tenth of input.
    let cacheReadTokens: Int
}

/// Dollar rates per million tokens for one model.
///
/// Rates are stated rather than assumed. Amazon Bedrock is partner-operated
/// and prices Claude separately from Anthropic's first-party API, and the
/// figures below are the published first-party rates -- the right shape, but
/// not guaranteed to be what this account is billed. The token counts the
/// spend figure is built from are exact and come straight off each response,
/// so if a rate is wrong the tokens are still right and the estimate rescales.
///
/// The cache multipliers do hold on Bedrock: its published cache-write and
/// cache-read prices for Claude sit at 1.25x and 0.1x of the input rate, the
/// same ratios the first-party API uses.
struct ModelPricing {
    let inputPerMTok: Double
    let outputPerMTok: Double

    /// Writing to the cache costs 1.25x input at the 5-minute TTL this app uses.
    var cacheWritePerMTok: Double { inputPerMTok * 1.25 }
    /// Reading from it costs about a tenth of input -- the whole point of
    /// caching the ~1,750-token preamble.
    var cacheReadPerMTok: Double { inputPerMTok * 0.1 }

    /// Matched on a substring so an inference-profile prefix or a region
    /// qualifier around the model name still resolves.
    static func forModel(_ modelID: String) -> ModelPricing? {
        let id = modelID.lowercased()
        for (needle, pricing) in table where id.contains(needle) {
            return pricing
        }
        return nil
    }

    /// Published first-party per-MTok rates. Sonnet 5 carries an introductory
    /// rate through 2026-08-31; the standard $3/$15 is used here so the
    /// estimate does not silently understate spend once it lapses.
    private static let table: [(String, ModelPricing)] = [
        ("opus-5", ModelPricing(inputPerMTok: 5, outputPerMTok: 25)),
        ("opus-4-8", ModelPricing(inputPerMTok: 5, outputPerMTok: 25)),
        ("sonnet-5", ModelPricing(inputPerMTok: 3, outputPerMTok: 15)),
        ("sonnet-4-6", ModelPricing(inputPerMTok: 3, outputPerMTok: 15)),
        ("haiku-4-5", ModelPricing(inputPerMTok: 1, outputPerMTok: 5)),
    ]

    /// What one request cost, in dollars.
    static func cost(of usage: TokenUsage) -> Double? {
        guard let rates = forModel(usage.model) else { return nil }
        let million = 1_000_000.0
        return Double(usage.inputTokens) / million * rates.inputPerMTok
            + Double(usage.outputTokens) / million * rates.outputPerMTok
            + Double(usage.cacheWriteTokens) / million * rates.cacheWritePerMTok
            + Double(usage.cacheReadTokens) / million * rates.cacheReadPerMTok
    }

    /// How the rates are described in the UI, so the number is never presented
    /// as an authoritative bill.
    static func rateDescription(for modelID: String) -> String? {
        guard let rates = forModel(modelID) else { return nil }
        return String(
            format: "$%.0f in / $%.0f out per million tokens",
            rates.inputPerMTok, rates.outputPerMTok
        )
    }
}
