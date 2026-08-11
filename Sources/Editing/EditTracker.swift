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

    /// Re-applies recorded corrections to a fresh rewrite.
    ///
    /// The prompt already describes each edit, but honouring it is left to the
    /// model, and a small local model frequently reintroduces the very wording
    /// the user just fixed. Replaying the substitutions in code makes the
    /// correction stick regardless of what the model returns.
    func applying(to text: String) -> String {
        var result = text
        for edit in edits {
            // Match on the word itself, ignoring punctuation captured by the
            // word-boundary widening. A correction recorded as "Friday." must
            // still apply when the new rewrite punctuates it as "Friday,".
            let before = edit.before.trimmingCharacters(in: Self.edgePunctuation)
            let after = edit.after.trimmingCharacters(in: Self.edgePunctuation)
            guard !before.isEmpty, before != after else { continue }

            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: before))\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            guard regex.firstMatch(in: result, range: range) != nil else { continue }

            result = regex.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: after)
            )
        }
        return result
    }

    /// Punctuation and whitespace that can sit on either edge of a captured
    /// span without being part of the word the user actually corrected.
    private static let edgePunctuation = CharacterSet(charactersIn: " \t.,;:!?\"')(")

    /// The block appended to the rewrite prompt describing user corrections.
    var promptContext: String? {
        guard !edits.isEmpty else { return nil }
        let lines = edits.map { edit -> String in
            let before = edit.before.isEmpty ? "(nothing)" : "\"\(edit.before)\""
            let after = edit.after.isEmpty ? "(deleted)" : "\"\(edit.after)\""
            return "- The user changed \(before) to \(after)."
        }
        return """
        The user manually corrected your previous output:
        \(lines.joined(separator: "\n"))

        Honor these corrections. They reflect what the user actually wants -- \
        preserve them in your rewrite and apply the same preference elsewhere \
        when it is relevant.
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
