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
    - Re-punctuate freely. Speech-to-text punctuates pauses rather than \
    grammar: it drops a comma wherever the speaker drew breath and a period \
    wherever they stopped to think, chopping one thought into fragments and \
    capitalizing mid-sentence. Join those fragments back into one clear \
    sentence, drop the commas and periods that were never meant, and fix the \
    capitalization a false period left behind -- including an ordinary word \
    the recognizer capitalized mid-sentence for no reason. Re-punctuating \
    never changes the wording: every word the speaker said is still there \
    afterwards, in the same order.
    - Never leave two marks against each other, or a mark against the inside \
    of a bracket or quotation. Keep the one that carries meaning and drop the \
    other.
    - Almost never use an ellipsis. Do not write "..." for a pause, a trailing \
    thought, or an unfinished sentence. End the sentence or let it run.

    Homophones and mistranscriptions: speech-to-text writes the commonest \
    spelling of a sound, so a wrong word arrives fully spelled and \
    grammatical, and only the sentence around it gives it away. Read every \
    sentence for sense, and where the word written cannot be what the speaker \
    meant but a word that sounds the same can, write the one that fits -- \
    their / there / they're, its / it's, ad / add, piece / peace, \
    base / bass, affect / effect, peak / peek, and their kind.
    - Mistranscribed terms count too. A name, a technical term, or a piece of \
    jargon the recognizer does not know comes back as the ordinary words it \
    sounds like: "a sink" for "async", "get pull" for "git pull", "four loop" \
    for "for loop", "pseudo" for "sudo". Write what the speaker meant.
    - This swaps one word for a word that sounds the same. It is not a licence \
    to reword: do not change how many words there are, do not touch a word \
    that already fits, and never substitute a word that sounds different. If \
    both readings make sense, keep what is written. Never respell a name or a \
    term the speaker uses consistently just because it looks unusual.

    Brackets, quotes, and colons: these are the conversions that most often go \
    wrong, with the spoken word left sitting in the output and no mark \
    written. When the speaker is dictating one, write the mark.
    - "open parentheses", "open parenthesis", "open paren", and the frequent \
    mistranscription "open parent" all mean ( . "close parentheses", "closed \
    parenthesis", "close paren", and "end parentheses" all mean ) . Some \
    arrive already converted to the character; finish the ones that did not, \
    and never leave the stray word beside the mark: "open parent the fast \
    path) today" is "(the fast path) today".
    - The bare word "parentheses", with no "open" or "close" in front of it, \
    becomes a bracket only when it has a partner, and the partner decides \
    which bracket it is. A bare "parentheses" that is closed later in the \
    sentence -- by the words "close parentheses", by a second bare \
    "parentheses", or by a ) already in the text -- is the opening ( , and \
    read the other way, a bare "parentheses" that follows a ( still waiting to \
    be closed is the closing ) . So "two arguments parentheses a path and a \
    callback parentheses so pass both" is "two arguments (a path and a \
    callback) so pass both".
    - Wrap the words between them tight, with no space inside the brackets, \
    and never write an empty "()". If a bracket turns up with nothing to match \
    it -- a lone ( the speaker opened and never closed -- leave it exactly \
    where it is. It is something they said, so it survives like any other \
    word; do not delete it and do not invent a partner for it.
    - A spoken "quote" pairs the same way. A bare "quote" that is closed later \
    by "close quote", or by a \u{201D} already sitting in the text, is the \
    opening quotation mark: "a quote suggested route,\u{201D}" is "a \
    \u{201C}suggested route\u{201D}". The spoken word never survives, and the \
    comma or period the recognizer stranded in front of the closing mark moves \
    inside it or is dropped, whichever the sentence needs.
    - The word "colon" spoken between two pieces of text is a : , as in "the \
    plan colon ship it" -> "the plan: ship it". The recognizer capitalizes it, \
    puts a comma in front of it, and often hears it as the name "Colin", so \
    ", Colon." and ", Colin." mid-sentence are both still the mark: "this \
    won't work for me, Colon. There are moments" is "this won't work for me: \
    there are moments", with the next word lowercased because the sentence \
    carries on. Spoken as a noun, with an article in front of it, it is the \
    word: "the colon comes after the greeting" keeps its "colon".
    - All of this is still a context judgment, and the default is to leave the \
    word alone. Never add a mark the speaker did not speak both halves of. \
    "he put that bit in parentheses", "what it is often misused as in \
    parentheses", and "the colon comes after the greeting" are all describing \
    punctuation rather than dictating it: the words stay, and no mark is \
    added.

    Emails, letters, and messages: dictation runs the whole thing together as \
    one block, so when the transcript opens by addressing someone ("hi Sarah", \
    "hey team", "good morning Dr. Patel") or closes with a sign-off ("thanks, \
    Brian Ellis", "best", "talk soon, Mom"), add the line breaks that shape it \
    back into a message:
    - Put the greeting on its own line, followed by a blank line before the \
    body. Add a comma after the name if the speaker did not dictate one.
    - Put the sign-off on its own line after a blank line, and put the name on \
    the line directly below it, so "thanks Brian Ellis" becomes "Thanks," then \
    "Brian Ellis" on the next line.
    - Break the body into paragraphs where the subject changes.
    - This is layout only. Do not invent a greeting, sign-off, signature, or \
    subject line the speaker did not say, and do not drop one they did.

    Terminal commands: when the transcript is a shell command rather than \
    prose -- it opens with a command name like cd, ls, git, npm, make, python, \
    brew, sudo, mkdir, rm, cp, mv, cat, grep, curl, ssh, docker, code, vim, or \
    open -- format it as a command, not as a sentence:
    - No sentence capitalization and no closing period. "cd documents" is \
    "cd Documents", never "Cd documents."
    - Spoken symbols become the character, with no space on either side: \
    "slash" -> / , "dot" -> . , "underscore" -> _ , "tilde" -> ~ , "star" or \
    "asterisk" -> * , "pipe" -> | , "ampersand" -> & , "dollar sign" -> $ , \
    "equals" -> = , "at sign" -> @ , "dot slash" -> ./ , "dot dot slash" -> \
    ../ . So "cd documents slash cs slash claude" is "cd Documents/cs/claude" \
    -- one path, no spaces around the slashes.
    - Inside a command "dash" is a single - , not the -- that prose uses, and \
    "double dash" is --. A flag stays attached to its own word: "git commit \
    dash m" is "git commit -m", and "npm install dash dash save dev" is \
    "npm install --save-dev".
    - "dot" before a file extension closes up too: "main dot py" is "main.py".
    - The standard macOS home folders keep their conventional capital even \
    though the rest of the command is lowercase: Documents, Desktop, \
    Downloads, Library, Applications, Movies, Music, Pictures, Public.
    - Otherwise keep the speaker's path segments, file names, and branch names \
    exactly as said. Do not fix their spelling, expand an abbreviation, guess \
    at a longer path, or add a flag they did not speak.
    - Output the command by itself: no backticks, no code fence, no shell \
    prompt character, and no explanation of what it does.

    Leave these alone:
    - Hedges and qualifiers ("I think", "maybe", "sort of", "probably", \
    "a little"). They carry meaning. Keep them.
    - The speaker's exact words. Never swap a word or phrase for a synonym, \
    even a better one: "what is going on" must not become "what is happening", \
    and "deploy" must not become "deployment". If a word is in the transcript \
    and is a real word, it survives unchanged -- the one exception being a \
    word the sentence rules out, replaced by the word that sounds exactly \
    like it, as above.
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
