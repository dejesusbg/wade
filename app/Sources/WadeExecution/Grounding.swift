import Foundation

/// Guards against notes the model made up (Phase 7 follow-up). With only a page title on
/// screen, the on-device model filled a comparison note with invented specs ("Snapdragon 8
/// Gen 3, 128 GB") or claims ("higher specs, faster processing"), and padded link-only notes
/// with the title. A prompt can't reliably stop a small model from doing that, so Wade checks
/// a note against what was actually on screen before proposing it. The checks are simple and
/// deterministic on purpose: exact numbers, word stems, and "more than the title".
public enum Grounding {
    /// Why a proposed note must not be offered, or nil if it's fine. `context` is the trigger's
    /// screen context (app, title, url, excerpt, selection, error_text); `digest` its history.
    public static func problem(withNote argumentsJSON: String, context: [String: String], digest: String = "") -> String? {
        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)) as? [String: Any]) ?? [:]
        let content = (args["content"] as? String) ?? ""
        let everything = ([digest] + context.values).joined(separator: "\n")
        let body = [context["excerpt"], context["selection"], context["error_text"]].compactMap { $0 }.joined(separator: "\n")

        if isLinkOnly(content) {
            return "the note is only a link. Put the useful text from the screen in it, or don't offer a note."
        }
        let invented = ungroundedNumbers(in: content, source: everything)
        if !invented.isEmpty {
            return "the note has facts that aren't on screen (\(invented.prefix(5).joined(separator: ", "))). Use only what is shown, or don't offer a note."
        }
        let words = contentWords(noteText(content))
        let known = stems(everything)
        let unsupported = words.filter { !known.contains(stem($0)) }
        if !words.isEmpty, Double(unsupported.count) / Double(words.count) > 0.3 {
            return "the note says things that aren't on screen (\(unsupported.prefix(5).joined(separator: ", "))). Use only what is shown, or don't offer a note."
        }
        let title = stems(context["title"] ?? "")
        let fromPage = Set(words.map(stem)).intersection(stems(body)).subtracting(title)
        if fromPage.count < 3 {
            return "the note adds nothing beyond the page title. Save text from the page itself, or don't offer a note."
        }
        return nil
    }

    /// Numbers in `content` that don't occur anywhere in `source` (the screen context). Numbers
    /// are the facts a comparison or summary hinges on, and they're easy to check exactly.
    public static func ungroundedNumbers(in content: String, source: String) -> [String] {
        let known = Set(numbers(in: withoutURLs(source)))  // digits in a URL ("compare.php3") aren't facts
        return numbers(in: noteText(content)).filter { !known.contains($0) }
    }

    /// True when the note is only a link, or links with a label or two: not worth saving.
    /// Markdown links go entirely, text and all ("- Pixel 10: [link to gsmarena.com](…)" is
    /// still just a link).
    public static func isLinkOnly(_ content: String) -> Bool {
        noteText(content).filter(\.isLetter).count < 20
    }

    /// The note minus links, the "Source:" line and "Title:" scaffolding.
    static func noteText(_ content: String) -> String {
        let lines = content.split(separator: "\n").filter {
            let l = $0.trimmingCharacters(in: .whitespaces).lowercased()
            return !l.hasPrefix("source:") && !l.hasPrefix("title:")
        }
        return withoutURLs(lines.joined(separator: "\n").replacing(/\[[^\]]*\]\([^)]*\)/, with: ""))
    }

    static func numbers(in text: String) -> [String] {
        text.matches(of: /\d+(?:[.,]\d+)*/).map { String($0.output).replacingOccurrences(of: ",", with: "") }
    }

    static func withoutURLs(_ text: String) -> String {
        text.replacing(/https?:\/\/\S+/, with: "")
    }

    /// Words of 4+ letters that carry meaning (not glue words), lowercased.
    static func contentWords(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter }.map(String.init)
            .filter { $0.count >= 4 && !stopwords.contains($0) }
    }

    /// A crude stem: the first 5 letters, so "analyze"/"analyzes" and "improve"/"improving" match.
    static func stem(_ word: String) -> String { String(word.prefix(5)) }

    static func stems(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter }.map { stem(String($0)) })
    }

    // Glue words, plus the note-writing words a model adds around real content.
    static let stopwords: Set<String> = [
        "that", "this", "with", "from", "have", "been", "were", "will", "would", "could", "should",
        "which", "their", "there", "these", "those", "than", "then", "they", "them", "what", "when",
        "where", "while", "about", "into", "also", "such", "more", "most", "some", "only", "very",
        "your", "yours", "here", "note", "notes", "saved", "save", "summary", "source", "link",
        "page", "text", "versus", "para", "como", "pero", "esta", "este", "estos", "desde", "sobre",
    ]
}
