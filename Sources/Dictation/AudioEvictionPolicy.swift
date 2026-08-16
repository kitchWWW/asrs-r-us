import Foundation

/// How the recordings folder is thinned once it hits its ceiling.
///
/// The archive exists to be tested against, so *which* recordings survive is a
/// different question from how many. The three options fail in different ways
/// and the default is the one that fails least; see `SessionAudio.prune`.
enum AudioEvictionPolicy: String, CaseIterable, Identifiable, Codable {
    case timeDiverse
    case oldestFirst
    case random

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .timeDiverse: return "Time-diverse sample"
        case .oldestFirst: return "Oldest first"
        case .random:      return "Random"
        }
    }
}
