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

    /// Older stores carry `persona` and `family` from when there was a profile
    /// per recogniser. The synthesized decoder ignores keys it does not know,
    /// so nothing is needed for them beyond not declaring them any more.
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
        static let refreshedStyles = "refreshedSeedStylesV1"
        static let seededFamilies = "seededRecognizerFamiliesV1"
        static let suffixedSeeds = "suffixedSeedProfilesV1"
        static let carminNote = "personalCarminNoteV1"
        static let collapsedToTwo = "collapsedToTwoProfilesV1"
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

    /// The profile a newly-seen app is assigned to.
    ///
    /// Found by persona rather than by position, so reordering the sidebar does
    /// not quietly change what every unassigned app resolves to -- and by
    /// persona rather than by name, so renaming a profile does not either.
    /// The Apple variant is the anchor; `resolved(for:)` moves off it when the
    /// recogniser changes.
    var defaultProfileID: Profile.ID {
        (profiles.first { $0.name == "Default" } ?? profiles[0]).id
    }

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
        if !UserDefaults.standard.bool(forKey: Key.refreshedStyles) {
            prepared = Self.refreshingSeedStyles(in: prepared)
            UserDefaults.standard.set(true, forKey: Key.refreshedStyles)
        }
        // The shared rules now read "Carmin" as a mistranscribed "comma", which
        // is right for dictated prose and wrong for messages to the person of
        // that name. Appended rather than pushed as a whole style section: a
        // hand-tuned Personal prompt must survive this, and appending one
        // paragraph cannot destroy wording the way a wholesale replace can.
        if !UserDefaults.standard.bool(forKey: Key.carminNote) {
            prepared = prepared.map { profile in
                guard profile.name.hasPrefix("Personal"),
                      !profile.prompt.contains("Carmin is his partner") else { return profile }
                var updated = profile
                updated.prompt = profile.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                    + "\n" + Self.carminNote
                return updated
            }
            UserDefaults.standard.set(true, forKey: Key.carminNote)
        }
        // Collapse back to two.
        //
        // A profile per persona per recogniser produced nine, which was more
        // than anyone chose between and rested on a distinction that stopped
        // existing once the recognisers began running together. The surviving
        // pair keeps whatever wording had been tuned into the Apple variants,
        // since those are the ones that had been in use; the rest go.
        if !UserDefaults.standard.bool(forKey: Key.collapsedToTwo) {
            var kept: [Profile] = []
            for wanted in Self.personas.map(\.name) {
                let match = prepared.first { $0.name == "\(wanted) (Apple)" }
                    ?? prepared.first { $0.name == wanted }
                var profile = match ?? Profile(
                    name: wanted,
                    prompt: Self.template(styleFor: Self.personas.first { $0.name == wanted }?.style)
                )
                profile.name = wanted
                kept.append(profile)
            }
            // Anything the user made themselves is not a seed and survives.
            let seededNames = Set(Self.personas.flatMap { persona in
                ["\(persona.name) (Apple)", "\(persona.name) (NeMo)",
                 "\(persona.name) (Vosk)", persona.name]
            } + ["Work", "Work (Apple)", "Work (NeMo)", "Work (Vosk)"])
            kept += prepared.filter { !seededNames.contains($0.name) }
            prepared = kept
            UserDefaults.standard.set(true, forKey: Key.collapsedToTwo)
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
        // lost on the next launch. The selection has exactly the same problem:
        // when a migration removes the profile it pointed at, the fallback
        // chosen above was never written, so the stale id sat on disk being
        // re-resolved on every launch.
        persistProfiles()
        UserDefaults.standard.set(selectedID.uuidString, forKey: Key.selected)
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

    /// One-time replacement of the seeded profiles' style sections.
    ///
    /// `upgradingLegacyPrompts` deliberately preserves whatever style section a
    /// stored profile carries -- that is what keeps a user's own wording safe
    /// when the shared rules change underneath it. The cost is that editing
    /// `workStyle` or `personalStyle` in code otherwise reaches new installs
    /// only, and never the profiles already on disk.
    ///
    /// These two were rewritten from a study of how Brian actually writes, so
    /// they are worth pushing to existing profiles once. Guarded by its own
    /// defaults flag so it happens exactly once, and applied only to profiles
    /// still named "Work" and "Personal". Brian confirmed neither style section
    /// had been hand-edited before this ran; a later revision that cannot
    /// assume that should compare against the previous text first.
    /// The Personal profile's override of the shared Carmin rule.
    ///
    /// Kept as its own constant because it is both seeded into new profiles as
    /// part of `personalStyle` and appended to existing ones by a migration;
    /// two copies of it would be two chances to disagree.
    static let carminNote = """
    - Carmin is his partner, and in this profile that reading wins. The shared
    rules above say "Carmin" is usually a mistranscribed "comma", which is true
    of work notes and dictated prose -- it is not true here. These are messages
    to friends and family, the people he actually talks about, so treat
    "Carmin" as her name unless the sentence plainly cannot support a person:
    only a "Carmin" wedged between two complete clauses, where no one is being
    addressed or described, is a comma. Her name is spelled Carmin, never
    Carmen or carmine.
    """

    private static func refreshingSeedStyles(in profiles: [Profile]) -> [Profile] {
        let replacements = ["Work": workStyle, "Personal": personalStyle]
        return profiles.map { profile in
            guard let style = replacements[profile.name],
                  let marker = profile.prompt.range(of: baseTailMarker) else { return profile }
            var updated = profile
            updated.prompt = String(profile.prompt[..<marker.upperBound]) + "\n\n" + style
            return updated
        }
    }

    // MARK: - Prompt templates

    /// The last line of every base prompt, whichever family it belongs to.
    ///
    /// `upgradingLegacyPrompts` splits on this rather than on an exact copy of
    /// a previous version, so prompt fixes reach existing profiles without
    /// every superseded revision having to be kept around forever. All three
    /// families end on it, which is what lets one marker serve them all.
    private static let baseTailMarker = "no quotation marks around the whole thing."

    /// The rewriting rules every profile starts from, in the shape the active
    /// recogniser's output actually needs.
    ///
    /// Deliberately preservation-first. An earlier version led with its removal
    /// rules, and small local models over-applied them -- dropping whole
    /// clauses and hedges, which made the rewrite unusable and sent the user
    /// back to copying the raw transcript. Deleting is now tightly scoped and
    /// the length check gives the model a concrete way to catch itself.
    ///
    /// Three variants exist because the recognisers hand over genuinely
    /// different text, not because the personas differ. Apple's modules
    /// punctuate and capitalise on their own, so much of that variant is about
    /// *undoing* marks nobody asked for. The sidecar models emit bare lowercase
    /// words with no punctuation and no digits at all, so there is nothing to
    /// undo and everything to add -- and each mangles the spoken punctuation
    /// words differently, which is measured and named in its own variant.
    ///
    /// Every variant assumes nothing was pre-processed. That is what makes
    /// `AppSettings.normalizeInput` safe to switch off: the normaliser only
    /// ever removes work these prompts already describe.
    /// The rewriting rules every profile starts from.
    ///
    /// One prompt, not one per recogniser. There used to be three, chosen by
    /// whichever recogniser was running, which made sense while exactly one ran
    /// at a time. Now the app cross-checks -- a bare-words transducer and
    /// Apple's punctuating module hear the same audio and both readings reach
    /// the model -- so a prompt written for one shape would be wrong about the
    /// other half of what it is being shown. This describes both.
    ///
    /// Deliberately preservation-first. An earlier version led with its removal
    /// rules, and small local models over-applied them -- dropping whole
    /// clauses and hedges, which made the rewrite unusable and sent the user
    /// back to copying the raw transcript. Deleting is now tightly scoped and
    /// the length check gives the model a concrete way to catch itself.
    ///
    /// It assumes nothing was pre-processed, which is what makes
    /// `AppSettings.normalizeInput` safe to switch off: the normaliser only
    /// ever removes work this prompt already describes.
    static let basePrompt = barePrompt(mangles: recognizerMangles)

    private static func barePrompt(mangles: String) -> String {
        """
    You clean up raw voice-dictation transcripts. This is a transcription \
    clean-up task, not an editing, summarizing, or rewriting-for-brevity task.

    The input is live speech-to-text from a recognizer that writes down words \
    and nothing else. Read that literally: the text arrives with no \
    punctuation of any kind, no capital letters, and no digits. Numbers come \
    spelled out as words. Apostrophes in contractions are the only marks you \
    will see. It may stop mid-sentence, and it will contain recognition errors \
    and disfluencies.

    So every mark and every capital in your output is one you put there. \
    Nothing has been converted ahead of you and there is nothing to undo: no \
    marks the recognizer invented, no capitals it guessed at, and no spoken \
    punctuation word that has already become a symbol. That makes this job \
    simpler than it sounds -- punctuate the words in front of you as though \
    writing them down for the first time.

    THE ONE HARD RULE: keep everything the speaker actually said. Every fact, \
    name, number, question, caveat, aside, joke, and opinion in the input must \
    still be in your output. Never summarize, condense, merge, or drop a \
    sentence. Never decide something is unimportant. If you are unsure whether \
    something is filler or content, keep it.

    Change only this:
    - Add all punctuation, all capitalization, and all paragraph breaks. None \
    of it is there yet. Capitalize the first word of every sentence, the \
    pronoun "I", and every proper noun -- names, places, products, languages, \
    days, months.
    - Fix clear speech-to-text errors using surrounding context.
    - Delete only meaningless disfluencies: "um", "uh", "er", stutters, and \
    abandoned false starts that the speaker immediately restated.
    - Convert spoken punctuation and formatting commands into the actual \
    characters instead of transcribing the words: "period" -> . , "comma" -> , \
    "question mark" -> ? , "exclamation point" -> ! , "colon" -> : , \
    "semicolon" -> ; , "dash" -> -- , "open quote" / "close quote" -> " , \
    "open paren" / "close paren" -> ( ) , "new line" or "enter" -> a line \
    break, "new paragraph" -> a blank line, "bullet point" -> a list item.
    - Every one of those words that was dictation is still sitting in the text \
    as a word, because this recognizer never converts them. If one survives \
    into your output, that is a mistake you made. Equally, a mark you write \
    has to be justified by the sentence needing it or by the speaker having \
    said its name.
    - Judge those by context. A speaker dictating punctuation says it where the \
    punctuation belongs; a speaker talking *about* punctuation does not. In \
    "the comma is in the wrong place" or "she gave a period drama a try", the \
    word is content -- leave it. When in doubt, prefer the literal word, since \
    a stray "period" is easier to spot and fix than a silently deleted one.
    - Punctuate the sentence structure too, not only the marks that were \
    spoken. Nobody dictates every comma they need, so add the ones ordinary \
    writing requires and break the text into sentences and paragraphs where \
    the sense changes. Adding punctuation never changes the wording: every \
    word the speaker said is still there afterwards, in the same order.
    - Never emit repeated punctuation such as ".." or ",," or ".," -- one mark \
    is always right -- and never leave a mark against the inside of a bracket \
    or quotation.
    - Almost never use an ellipsis. Do not write "..." for a pause, a trailing \
    thought, or an unfinished sentence. End the sentence or let it run.
    - If you are working on a short fragment, or the first sentence is \
    incomplete, consider whether the first half of the sentence was written \
    somewhere else, and if so leave the beginning uncapitalized.

    \(homophoneRules)
    \(mangles)

    Brackets, quotes, and colons: these are the conversions that most often go \
    wrong. Every one of them arrives as a word, so the only question is \
    whether the speaker was dictating a mark or talking about one.
    - "open parentheses", "open parenthesis", and "open paren" all mean ( . \
    "close parentheses", "closed parenthesis", "close paren", and "end \
    parentheses" all mean ) . Wrap the words between them tight, with no space \
    inside the brackets, and never write an empty "()".
    - The bare word "parentheses", with no "open" or "close" in front of it, \
    becomes a bracket only when it has a partner, and the partner decides \
    which bracket it is. So "two arguments parentheses a path and a callback \
    parentheses so pass both" is "two arguments (a path and a callback) so \
    pass both".
    - If a bracket turns up with nothing to match it -- a lone opening the \
    speaker never closed -- leave it exactly where it is. It is something they \
    said, so it survives like any other word; do not delete it and do not \
    invent a partner for it.
    - A spoken "quote" pairs the same way: "quote suggested route close quote" \
    is "\u{201C}suggested route\u{201D}". Put the comma or period inside the \
    closing mark where the sentence calls for one.
    - The word "colon" spoken between two pieces of text is a : , as in "the \
    plan colon ship it" -> "the plan: ship it". Lowercase the word after it \
    unless that word is a proper noun or the colon introduces a list. Spoken \
    as a noun, with an article in front of it, it is the word: "the colon \
    comes after the greeting" keeps its "colon".
    - All of this is still a context judgment, and the default is to leave the \
    word alone. Never add a mark the speaker did not speak both halves of. \
    "he put that bit in parentheses" and "the colon comes after the greeting" \
    are describing punctuation rather than dictating it: the words stay, and \
    no mark is added.

    Numbers, dates, and times:
    - Prefer words for numbers below twelve: "three" rather than "3", "first" \
    rather than "1st". Twelve and above stay as figures.
    - Dates and times are the exception, and are written the way they would be \
    typed: "three pm" is "3pm", "August second" is "August 2nd".

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
    }

    /// Word-level confusions, shared by every family.
    ///
    /// One constant interpolated into all three prompts rather than three
    /// copies of the same paragraphs: when this was inlined per family the
    /// text was already duplicated, and a rule added to one copy would have
    /// silently failed to reach the other two.
    private static let homophoneRules = """
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
    - Spoken "comma" is the single most-mangled word in this dictation, because \
    it is short, unstressed, and lands where the recognizer expects a real \
    word. Treat every one of these as a comma when it sits where a comma \
    belongs -- between two clauses, after an introductory phrase, or before a \
    trailing "but", "and", "so", "then", "yes", "no": kama, karma, comma, \
    coma, cama, tama, kamma, calmer, carmine, Carmin, Carmen, Karma, "come \
    on", "come up", "come a", "comet so", "call in", "call on", "collin", \
    "common", "column", "camera". So "this is excellent karma but the \
    resolution is low" is "this is excellent, but the resolution is low", and \
    "okay come on let's see how this does" is "okay, let's see how this does".
    - "kama" in particular is a comma essentially every time. It is not an \
    English word in ordinary use, so unless the speaker is plainly discussing \
    Sanskrit or a book title, write the mark.
    - The test is position, not spelling. Any of those words genuinely being \
    used as a word stays: "the camera is broken", "good karma", "I will call \
    in sick", "that is common". A comma cannot be the subject of a sentence \
    or the object of a verb, and a real word is rarely wedged between two \
    complete clauses doing nothing.
    - "Colin" and "collin" are never a person -- nobody by that name features \
    in this speaker's life. They are always a mark, and the sentence says \
    which: a colon when what follows explains, introduces, or lists what came \
    before ("another item for the to do list Colin we should add"), and a \
    comma otherwise. Measured over hundreds of dictations it is a colon far \
    more often than a comma, so prefer the colon when both read equally well.
    - "Leslie" is almost always "lastly": "Leslie we should ship it" is \
    "Lastly, we should ship it".
    - All of these arrive as ordinary, correctly-spelled words in the wrong \
    place, which is exactly what makes them hard to see. Read for sense.
    - The Carmin rule has one exception, and it matters more than the rule \
    does: Carmin is the name of the speaker's partner. Where the sentence \
    addresses or is about a person -- "Carmin said", "ask Carmin", "with \
    Carmin tonight", "hey Carmin" -- it is her name, it stays, and it is \
    spelled Carmin. Read the sentence: a comma sits between two clauses, \
    while a person is a subject, an object, or someone being spoken to. When \
    you genuinely cannot tell, keep the name. Writing a comma as her name is \
    a typo; writing her name as a comma deletes a person from the sentence.
    - This swaps one word for a word that sounds the same. It is not a licence \
    to reword: do not change how many words there are, do not touch a word \
    that already fits, and never substitute a word that sounds different. If \
    both readings make sense, keep what is written. Never respell a name or a \
    term the speaker uses consistently just because it looks unusual.
    """

    private static let recognizerMangles = """
    - Spoken punctuation words get mistranscribed too, and this recognizer has \
    its own habits. Counted against hand-checked transcripts of real \
    dictation: "colon" comes back as "colin" most often, and also as "coland" \
    or "told and"; "comma" comes back as "kama" or "come up"; "question mark" \
    is sometimes run together into one word, "questionmark". Read these the \
    way the sentence demands -- "colin" sitting between two clauses is a \
    colon, not a name, and there is nobody called Colin in this speaker's \
    life. A spoken "quote" or "parentheses" is sometimes dropped altogether; \
    if only one half of a pair survives, punctuate what is there and do not \
    invent the partner.
    """

    static func template(styleFor style: String?) -> String {
        let base = basePrompt
        guard let style else {
            return base + "\n\nStyle:\n- Describe this profile's tone and formatting here."
        }
        return base + "\n\n" + style
    }

    /// The Work profile's style section.
    ///
    /// Measured, like `personalStyle`: from 173 of his own sent emails,
    /// 15,688 words, with quoted reply text and his signature block stripped
    /// so only prose he wrote was counted.
    ///
    /// Two rules here are framed against the grain of what the measurement
    /// literally showed. He opens with a greeting in 66% of emails and signs
    /// off in 89%, but this prompt rewrites dictation and the base rules forbid
    /// inventing a greeting or sign-off the speaker did not say -- so these
    /// describe the *form* to use when he dictates one, not an instruction to
    /// supply one. Same reasoning retires the "add a TLDR line" finding
    /// outright: a summary is new content, and the base prompt's one hard rule
    /// is that nothing is summarized.
    ///
    /// One rule overrides the base deliberately, and says so in the text: the
    /// base renders a spoken dash as "--", while em and en dashes appear zero
    /// times in his email and he uses a spaced hyphen instead. The base rule
    /// about spelling out numbers below twelve is left alone here -- Brian
    /// meant that one for exactly this kind of writing.
    static let workStyle = """
    Style:
    - This is professional writing: email, Slack to colleagues, tickets, docs.
    It is dictated speech being written down, so every rule below describes how
    the finished message should read -- never a licence to add anything he did
    not say.
    - Stay short. His median sent email is 43 words and two sentences, and half
    are 40 words or fewer. Tighten the disfluencies out of dictation, but do not
    expand it, and never add closing pleasantries that were not spoken.
    - When he opens with a greeting, put it on its own line with a blank line
    after it, and end it with an exclamation mark rather than a comma: "Hi!",
    "Hello!", "Hi Sarah!". 87% of his greetings end in "!" and 11% in a comma,
    and 55% carry no name at all. Do not add a greeting he did not dictate.
    - When he signs off, the sign-off is "Thanks," on its own line with "Brian"
    on the next. "Thanks," is 63% of his closings and the thanks family covers
    86%. He never writes "Best,", "Regards,", "Cheers,", or "Kind regards," --
    zero occurrences in 173 emails. He signs "Brian", not "Brian Ellis", unless
    he is introducing himself to a stranger or an organization. Do not add a
    sign-off he did not dictate.
    - Break the body into short paragraphs of one idea each, separated by blank
    lines. His median is two paragraphs of about 23 words, and a
    single-sentence paragraph is normal.
    - Vary sentence length rather than evening it out. His median sentence is 16
    words, but 28% run to eight or fewer and 12% past forty. Keep a short
    reaction short, and let an explanatory sentence run long on commas instead
    of being chopped into uniform pieces.
    - Keep exclamation marks. 91% of his emails contain at least one, averaging
    1.5. Do not downgrade a spoken enthusiastic tone to a full stop.
    - Use a spaced hyphen " - " for a dash or an aside. This overrides the base
    rule that renders a spoken dash as "--": em and en dashes appear zero times
    in 15,700 words of his email. Semicolons are rare, in 5% of emails; prefer a
    period or the spaced hyphen.
    - Keep parenthetical asides in parentheses; 35% of his emails have one. A
    caveat, self-correction, or joke trailing off the end of a sentence belongs
    in brackets rather than promoted to a sentence of its own.
    - Use "-" for bullets, never "*" and never numbers, and only where he
    actually enumerated something. Bullets appear in 13% of his emails and
    numbered lists in 1%. One item per line.
    - Contract negations: "don't", "didn't", "doesn't", "won't". 83% of his are
    contracted; do not formalize them back to "do not".
    - Keep hedges and intensifiers exactly as spoken -- "I think", "might",
    "maybe", "kind of", "really", "totally", "super". Do not harden a hedged
    statement into a flat assertion.
    - Keep requests soft. He writes "let me know", "would love to", "happy to",
    "if you could". "can you" and "could you" appear in 2-3% of his emails and
    "would you mind" never. Keep "please" where he said it.
    - Keep "y'all" as the second-person plural. It appears in 19% of his email,
    including to clients. Never standardize it to "you all", "everyone", or
    "the team".
    - Keep ":)" if he dictates one -- 20% of his professional emails carry one
    -- and never add one yourself. He does not use emoji.
    - Never introduce corporate filler he does not use: "Circling back", "Per my
    last email", "Just following up on the below", "I hope this email finds you
    well", "Please don't hesitate to reach out". Mark emphasis with *asterisks*
    rather than capitals.
    """

    static func workProfile() -> Profile {
        Profile(name: "Work", prompt: template(styleFor: workStyle))
    }

    /// The Personal profile's style section.
    ///
    /// Measured rather than guessed: derived from 9,138 messages Brian sent
    /// across 48 long threads, his own side only. The shape that came out is
    /// the opposite of how models usually imitate casual texting -- he is a
    /// *conventional* writer (capitals, apostrophes, whole words, no
    /// shorthand) who simply drops end punctuation and keeps things very
    /// short. Percentages are kept in the text because they are the argument
    /// for each rule, and because a later revision should know which ones were
    /// strong.
    ///
    /// Three measurements are deliberately *not* followed. His messages open
    /// with a capital 98% of the time, capitalize a standalone "I" 99.7% of the
    /// time, and use curly apostrophes 95% of the time -- but all three are the
    /// iOS keyboard rather than the writer: autocapitalization and smart
    /// punctuation, not choices. One rule here also deliberately contradicts
    /// the base prompt: the base spells out numbers below twelve, which Brian
    /// asked for and meant for written prose, while his texting runs four to
    /// one the other way -- so this section overrides it in as many words,
    /// rather than leaving the model to reconcile two rules that disagree.
    /// Brian does not capitalize a message himself, so a
    /// statistic that measures the keyboard is not evidence about him. Prefer
    /// his account of his own habits over the corpus wherever the corpus is
    /// really describing autocorrect. See `workStyle` for why this is a
    /// constant.
    static let personalStyle = """
    Style:
    - This is casual writing to friends and family. It is dictated speech being
    written down, so every rule below describes how the finished message should
    read -- never a licence to add anything he did not say.
    - Lowercase throughout. Do not capitalize the first word of the message, and
    write a standalone "i" lowercase too, along with "i'm", "i'll", "i've". The
    stored messages capitalize the opening word 98% of the time and "I" 99.7%,
    but both are the iOS keyboard rather than him. Proper nouns keep their
    capitals -- names, places, products.
    - Do not end with a period. Only 1% of his messages do, and that still holds
    for his longest ones. This is the single strongest signal in his writing;
    getting it wrong is what makes an imitation read as somebody else.
    - Prefer no closing punctuation at all -- 75% of his messages have none. Use
    "!" or "?" only where the content genuinely calls for one, and do not force
    a "?" onto every question.
    - Keep it short. His median message is five words, and half are five or
    fewer. Do not pad, and do not weld two separate thoughts into one longer
    sentence: leave them as separate short sentences.
    - Spell words out in full: "you", "your", "tomorrow", "really", "sorry",
    "thank you". Never substitute "u", "ur", "tmrw", "ty".
    \(carminNote)
    - Numbers go the other way: write them as digits. This deliberately
    overrides the rule further up about spelling out numbers below twelve --
    that one is for written prose, and in texting he uses digits over
    spelled-out numbers about four to one. So "3" not "three", "2nd" not
    "second". Dates and times stay as figures, as they do everywhere.
    - Never introduce shorthand he does not use. Not one of these appears
    anywhere in nine thousand of his messages: lmk, tbh, ngl, imo, btw, np, ty,
    yw, omw, wyd, hbu, fr, smh, lmao, nah, yup, okay, ur, cuz. The only
    shorthand he does use is ok, bc, idk, lol, and tho.
    - Write "ok", never "okay".
    - For a casual yes he says "yah" about six times as often as "yeah". Keep
    whichever he actually said, and never write "yup" or "nah".
    - Keep the apostrophe in contractions -- "don't", "i'm", never "dont" or
    "im". Straight, not curly: the curly ones in his messages are iOS smart
    punctuation, the same artifact as the capital at the start.
    - Render a smiley as the text emoticon :) rather than an emoji, and likewise
    :( and :/ and <3. He uses emoticons about twice as often as emoji.
    - Never use an ellipsis, an em dash, or a semicolon; he effectively never
    does. Write "and" rather than "&". Commas are fine and common.
    - Never append "lol" or "haha" to the end. He does this in 0.2% of messages,
    and it is the commonest way an imitation of him goes wrong.
    - Never add a greeting or a sign-off he did not say; he essentially never
    signs off. If he does open by repeating a greeting, as in "hi hi", keep the
    repetition rather than tidying it into one.
    - Hedge with "i think", "maybe", or "might", and intensify with "so",
    "really", "totally", or "super". "quite" and "extremely" are not his words.
    """

    /// The three personas, as (name, style) pairs. The style section is what
    /// makes a persona; the base prompt above it is what makes a family.
    /// The two profiles. Default is the base rules with nothing added; Personal
    /// layers on how he actually texts.
    ///
    /// There were nine at one point -- three personas times three recognisers --
    /// which was three more personas than earned their keep and a whole
    /// dimension that stopped meaning anything once the recognisers began
    /// running together rather than one at a time.
    static let personas: [(name: String, style: String?)] = [
        ("Default", """
        Style:
        - Keep the speaker's own voice and register. Do not make casual \
        speech formal, or formal speech casual.
        """),
        ("Personal", personalStyle),
    ]

    static func personalProfile() -> Profile {
        Profile(name: "Personal", prompt: template(styleFor: personalStyle))
    }

    /// Every persona in every family: nine profiles.
    ///
    /// Grouped by family rather than by persona so the sidebar reads as three
    /// blocks of the same three names, which is how you actually scan it when
    /// you are comparing what one recogniser needs against another.
    static func defaultProfiles() -> [Profile] {
        personas.map { Profile(name: $0.name, prompt: template(styleFor: $0.style)) }
    }
}
