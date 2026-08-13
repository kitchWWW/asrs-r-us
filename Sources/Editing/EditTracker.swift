import Foundation

/// Records how the user hand-corrected the model's output, so later rewrites
/// can be told "the user changed X to Y" and stop re-introducing the mistake.
@MainActor
final class EditTracker: ObservableObject {

    struct Edit: Identifiable, Equatable {
        let id = UUID()
        let before: String
        let after: String
    }

    /// Most recent last. Capped so the prompt cannot grow without bound.
    @Published private(set) var edits: [Edit] = []

    private let maxEdits = 12
    /// The text the model last produced -- the baseline any edit is measured against.
    private var baseline: String = ""

    func setBaseline(_ text: String) {
        baseline = text
    }

    func reset() {
        edits.removeAll()
        baseline = ""
    }

    /// Diffs `edited` against the current baseline and records the changed span.
    ///
    /// Uses a common-prefix/suffix trim rather than a full diff: for typing
    /// corrections this isolates exactly the touched region, and it costs
    /// nothing on every keystroke.
    func record(edited: String) {
        guard edited != baseline else { return }
        guard let change = Self.changedSpan(from: baseline, to: edited) else {
            baseline = edited
            return
        }

        // Collapse consecutive edits to the same region instead of logging
        // every keystroke as its own entry.
        if let last = edits.last, last.after == change.before {
            edits[edits.count - 1] = Edit(before: last.before, after: change.after)
        } else {
            edits.append(change)
        }
        if edits.count > maxEdits { edits.removeFirst(edits.count - maxEdits) }
        baseline = edited
    }

    /// The block appended to the rewrite prompt describing user corrections.
    ///
    /// This is now the only mechanism carrying corrections forward. Earlier
    /// versions also replayed the substitutions over the model's output in
    /// code, as insurance against a small local model reintroducing the
    /// wording the user had just fixed. That insurance cost more than it paid:
    /// the replay was a global regex, so a one-off correction such as "the" ->
    /// "a" rewrote every subsequent "the" in the text as well.
    var promptContext: String? {
        guard !edits.isEmpty else { return nil }
        let lines = edits.map { edit -> String in
            switch (edit.before.isEmpty, edit.after.isEmpty) {
            case (true, _): return "- The user inserted \"\(edit.after)\"."
            case (_, true): return "- The user deleted \"\(edit.before)\"."
            default: return "- The user changed \"\(edit.before)\" to \"\(edit.after)\"."
            }
        }
        return """
        The user manually corrected your previous output. These corrections are \
        binding and take priority over everything else in this prompt:
        \(lines.joined(separator: "\n"))

        - Apply every one of them. Where the transcript still carries the \
        wording on the left, your output must carry the wording on the right.
        - Honour them even when the transcript plainly says otherwise. The user \
        has seen both versions and is fixing a recognition error or your \
        wording; the transcript is not the authority here, they are.
        - Apply the same preference to comparable wording elsewhere in the text.
        - Never reintroduce the corrected-away wording anywhere in your output.
        """
    }

    /// Returns the minimal changed region between two strings, ignoring the
    /// shared prefix and suffix.
    static func changedSpan(from old: String, to new: String) -> Edit? {
        guard old != new else { return nil }
        let oldChars = Array(old)
        let newChars = Array(new)

        var prefix = 0
        while prefix < oldChars.count, prefix < newChars.count,
              oldChars[prefix] == newChars[prefix] {
            prefix += 1
        }

        var suffix = 0
        while suffix < oldChars.count - prefix,
              suffix < newChars.count - prefix,
              oldChars[oldChars.count - 1 - suffix] == newChars[newChars.count - 1 - suffix] {
            suffix += 1
        }

        // Widen to whole words so the context reads as "teh" -> "the" rather
        // than "e" -> "he", which is meaningless to the model.
        let oldStart = Self.wordStart(in: oldChars, before: prefix)
        let newStart = Self.wordStart(in: newChars, before: prefix)
        let oldEnd = Self.wordEnd(in: oldChars, after: oldChars.count - suffix)
        let newEnd = Self.wordEnd(in: newChars, after: newChars.count - suffix)

        let before = String(oldChars[oldStart..<max(oldStart, oldEnd)])
        let after = String(newChars[newStart..<max(newStart, newEnd)])
        guard before != after else { return nil }
        return Edit(before: before, after: after)
    }

    private static func wordStart(in chars: [Character], before index: Int) -> Int {
        var i = min(index, chars.count)
        while i > 0, !chars[i - 1].isWhitespace { i -= 1 }
        return i
    }

    private static func wordEnd(in chars: [Character], after index: Int) -> Int {
        var i = max(0, min(index, chars.count))
        while i < chars.count, !chars[i].isWhitespace { i += 1 }
        return i
    }
}
