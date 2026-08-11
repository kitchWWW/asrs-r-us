import Combine
import Foundation
import SwiftUI

/// A named rewrite persona. The prompt is the complete system prompt sent for
/// that profile -- not a fragment layered onto something hidden -- so what you
/// see in Settings is exactly what the model is told.
struct Profile: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var prompt: String

    init(id: UUID = UUID(), name: String, prompt: String) {
        self.id = id
        self.name = name
        self.prompt = prompt
    }
}

@MainActor
final class ProfileStore: ObservableObject {
    static let shared = ProfileStore()

    private enum Key {
        static let profiles = "profiles"
        static let selected = "selectedProfileID"
        /// Pre-profiles single prompt, migrated into the first profile.
        static let legacyPrompt = "systemPrompt"
        static let prunedSeeds = "prunedSeedProfilesV2"
        static let seededWorkPersonal = "seededWorkPersonalV1"
    }

    @Published var profiles: [Profile] {
        didSet { persistProfiles() }
    }

    @Published var selectedID: Profile.ID {
        didSet { defaults.set(selectedID.uuidString, forKey: Key.selected) }
    }

    private let defaults = UserDefaults.standard

    var active: Profile {
        profiles.first { $0.id == selectedID } ?? profiles[0]
    }

    var activePrompt: String { active.prompt }

    private init() {
        let stored: [Profile] = {
            guard let data = UserDefaults.standard.data(forKey: Key.profiles),
                  let decoded = try? JSONDecoder().decode([Profile].self, from: data),
                  !decoded.isEmpty
            else { return [] }
            return decoded
        }()

        // Resolve into a local first: `selectedID` cannot read `self.profiles`
        // until every stored property is initialized.
        let resolved: [Profile]
        if stored.isEmpty {
            // First run. If the user had already tuned the old single prompt,
            // carry it over as their default profile rather than discarding it.
            var seeded = Self.defaultProfiles()
            if let legacy = UserDefaults.standard.string(forKey: Key.legacyPrompt),
               !legacy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               legacy != Self.basePrompt {
                seeded[0].prompt = legacy
            }
            resolved = seeded
        } else {
            resolved = stored
        }
        var prepared = Self.upgradingLegacyPrompts(in: resolved)
        // Existing installs need these added explicitly: seeding only runs on a
        // first launch with an empty store.
        if !UserDefaults.standard.bool(forKey: Key.seededWorkPersonal) {
            let existing = Set(prepared.map(\.name))
            if !existing.contains("Work") { prepared.append(Self.workProfile()) }
            if !existing.contains("Personal") { prepared.append(Self.personalProfile()) }
            UserDefaults.standard.set(true, forKey: Key.seededWorkPersonal)
        }
        if !UserDefaults.standard.bool(forKey: Key.prunedSeeds) {
            let pruned = prepared.filter { !["Work", "Friends"].contains($0.name) }
            if !pruned.isEmpty { prepared = pruned }
            UserDefaults.standard.set(true, forKey: Key.prunedSeeds)
        }
        profiles = prepared

        // Resolve against `prepared`, not `resolved`: pruning may have removed
        // the profile the saved selection points at.
        let savedID = UserDefaults.standard.string(forKey: Key.selected)
            .flatMap(UUID.init(uuidString:))
        if let savedID, prepared.contains(where: { $0.id == savedID }) {
            selectedID = savedID
        } else {
            selectedID = prepared[0].id
        }

        // Always write back. Property observers do not fire during init, so the
        // `didSet` that normally persists `profiles` never runs here -- without
        // this, migrations and pruning applied in memory only and were silently
        // lost on the next launch.
        persistProfiles()
    }

    // MARK: - Mutation

    @discardableResult
    func addProfile(named name: String = "New Profile") -> Profile {
        let unique = uniqueName(from: name)
        let profile = Profile(name: unique, prompt: Self.template(styleFor: nil))
        profiles.append(profile)
        selectedID = profile.id
        return profile
    }

    func duplicate(_ profile: Profile) {
        var copy = profile
        copy.id = UUID()
        copy.name = uniqueName(from: "\(profile.name) Copy")
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles.insert(copy, at: index + 1)
        } else {
            profiles.append(copy)
        }
        selectedID = copy.id
    }

    /// Removing is refused when it would leave no profiles: the rewriter always
    /// needs a prompt.
    func remove(_ id: Profile.ID) {
        guard profiles.count > 1, let index = profiles.firstIndex(where: { $0.id == id }) else {
            return
        }
        profiles.remove(at: index)
        if selectedID == id {
            selectedID = profiles[min(index, profiles.count - 1)].id
        }
    }

    /// Binding target for the detail pane.
    func binding(for id: Profile.ID) -> Binding<Profile>? {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { self.profiles[index] },
            set: { self.profiles[index] = $0 }
        )
    }

    func resetToDefaults() {
        profiles = Self.defaultProfiles()
        selectedID = profiles[0].id
    }

    private func uniqueName(from name: String) -> String {
        var candidate = name
        var suffix = 2
        while profiles.contains(where: { $0.name == candidate }) {
            candidate = "\(name) \(suffix)"
            suffix += 1
        }
        return candidate
    }

    private func persistProfiles() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        defaults.set(data, forKey: Key.profiles)
    }

    /// Brings stored profiles onto the current base prompt while preserving the
    /// style section each one carries below it.
    ///
    /// Matches on the base prompt's closing line rather than on an exact copy of
    /// a previous version, so prompt fixes reach existing profiles without
    /// needing every superseded revision kept around forever.
    private static func upgradingLegacyPrompts(in profiles: [Profile]) -> [Profile] {
        profiles.map { profile in
            guard let marker = profile.prompt.range(of: baseTailMarker) else { return profile }
            let styleSection = String(profile.prompt[marker.upperBound...])
            let refreshed = basePrompt + styleSection
            guard refreshed != profile.prompt else { return profile }

            var updated = profile
            updated.prompt = refreshed
            return updated
        }
    }

    // MARK: - Prompt templates

    /// The rewriting rules every profile starts from. A profile's prompt is
    /// this plus a style section, and is fully editable afterwards.
    /// Final line of the base prompt. Used to find where the shared rules end
    /// and a profile's own style section begins.
    private static let baseTailMarker = "no quotation marks around the whole thing."

    /// The rewriting rules every profile starts from. A profile's prompt is
    /// this plus a style section, and is fully editable afterwards.
    /// Previous default. Kept so profiles still carrying it can be upgraded
    /// in place without clobbering user edits.
    static let legacyBasePrompts: [String] = [
        """
        You rewrite raw voice-dictation transcripts into clean, well-formed text.

        You will receive a live speech-to-text transcript. It may be mid-sentence, \
        contain recognition errors, filler words, false starts, and no punctuation. \
        Infer from the content what kind of writing the speaker is producing and \
        format it the way that kind of writing is normally formatted.

        Rules:
        - Preserve the speaker's meaning, facts, and intent exactly. Never add \
        information they did not say.
        - Fix punctuation, capitalization, and obvious transcription errors.
        - Remove filler ("um", "uh", "you know") and false starts.
        - Obey spoken formatting commands ("new paragraph", "bullet point", \
        "quote unquote") by applying them rather than transcribing them.
        - If the transcript ends mid-sentence, rewrite what is there and stop. Do \
        not invent an ending.
        - When the user has manually edited your previous output, treat those edits \
        as corrections and honor them in this and all later rewrites.

        Output only the rewritten text. No preamble, no commentary, no code fences, \
        no quotation marks around the whole thing.
        """,
    ]

    /// The rewriting rules every profile starts from.
    ///
    /// Deliberately preservation-first. The previous version led with its
    /// removal rules, and small local models over-applied them -- dropping
    /// whole clauses and hedges, which made the rewrite unusable and sent the
    /// user back to copying the raw transcript. Deleting is now tightly scoped
    /// and the length check gives the model a concrete way to catch itself.
    static let basePrompt = """
    You clean up raw voice-dictation transcripts. This is a transcription \
    clean-up task, not an editing, summarizing, or rewriting-for-brevity task.

    The input is live speech-to-text. It may stop mid-sentence and will contain \
    recognition errors, disfluencies, and little or no punctuation.

    THE ONE HARD RULE: keep everything the speaker actually said. Every fact, \
    name, number, question, caveat, aside, joke, and opinion in the input must \
    still be in your output. Never summarize, condense, merge, or drop a \
    sentence. Never decide something is unimportant. If you are unsure whether \
    something is filler or content, keep it.

    Change only this:
    - Add punctuation, capitalization, and paragraph breaks.
    - Fix clear speech-to-text errors using surrounding context.
    - Delete only meaningless disfluencies: "um", "uh", "er", stutters, and \
    abandoned false starts that the speaker immediately restated.
    - Convert spoken punctuation and formatting commands into the actual \
    characters instead of transcribing the words: "period" -> . , "comma" -> , \
    "question mark" -> ? , "exclamation point" -> ! , "colon" -> : , \
    "semicolon" -> ; , "dash" -> -- , "open quote" / "close quote" -> " , \
    "open paren" / "close paren" -> ( ) , "new line" or "enter" -> a line \
    break, "new paragraph" -> a blank line, "bullet point" -> a list item.
    - Judge those by context. A speaker dictating punctuation says it where the \
    punctuation belongs; a speaker talking *about* punctuation does not. In \
    "the comma is in the wrong place" or "she gave a period drama a try", the \
    word is content -- leave it. When in doubt, prefer the literal word, since \
    a stray "period" is easier to spot and fix than a silently deleted one.
    - A spoken punctuation word that sits beside the mark it names, as in "ship \
    it period." , is one piece of punctuation: keep the mark and drop the word. \
    No spoken punctuation word should survive into the output, and never emit \
    repeated punctuation such as ".." or ",," or ".," -- one mark is always \
    right.
    - Re-punctuate freely. Speech-to-text scatters periods and commas wherever \
    the speaker drew breath, chopping one thought into fragments and \
    capitalizing mid-sentence. Join those fragments back into a single clear \
    sentence, drop the commas that were never meant, and fix the capitalization \
    left behind by a false period. This is a punctuation change only -- every \
    word still survives.
    - Almost never use an ellipsis. Do not write "..." for a pause, a trailing \
    thought, or an unfinished sentence. End the sentence or let it run.

    Leave these alone:
    - Hedges and qualifiers ("I think", "maybe", "sort of", "probably", \
    "a little"). They carry meaning. Keep them.
    - The speaker's own wording, slang, and register. Do not upgrade their \
    vocabulary or make casual speech formal.
    - Repetition used for emphasis, and the speaker's order of ideas.

    Length check before you answer: your output should be about as long as the \
    input once "um"s and stutters are gone. If it is noticeably shorter, you \
    have deleted something the speaker said -- put it back.

    If the transcript ends mid-sentence, clean up what is there and stop. Never \
    invent an ending.

    When the user has manually edited your previous output, treat those edits as \
    corrections and honor them in this and all later rewrites.

    Output only the cleaned-up text. No preamble, no commentary, no code fences, \
    no quotation marks around the whole thing.
    """

    static func template(styleFor style: String?) -> String {
        guard let style else {
            return basePrompt + "\n\nStyle:\n- Describe this profile's tone and formatting here."
        }
        return basePrompt + "\n\n" + style
    }

    static func workProfile() -> Profile {
        Profile(
            name: "Work",
            prompt: template(styleFor: """
            Style:
            - This is professional writing: email, Slack to colleagues, tickets, docs.
            - Clear, warm, and competent. Not stiff, not chummy.
            - Use real emoji sparingly and only where the speaker clearly \
            intended one.
            - Prefer complete sentences and correct punctuation. Break \
            multi-topic dictation into short paragraphs.
            """)
        )
    }

    static func personalProfile() -> Profile {
        Profile(
            name: "Personal",
            prompt: template(styleFor: """
            Style:
            - This is casual writing to friends and family.
            - Keep it loose and conversational. Contractions, sentence \
            fragments, and lowercase are fine if that is how it was said.
            - Render a smiley as the text emoticon :) rather than an emoji, and \
            likewise :( and ;) for the obvious ones.
            - Do not tidy the personality out of it. Slang stays.
            - Short. Do not pad a two-line message into a paragraph.
            """)
        )
    }

    static func defaultProfiles() -> [Profile] {
        [
            Profile(
                name: "Default",
                prompt: template(styleFor: """
                Style:
                - Keep the speaker's own voice and register. Do not make casual \
                speech formal, or formal speech casual.
                """)
            ),
            workProfile(),
            personalProfile(),
        ]
    }
}
