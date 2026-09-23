/// Normalizes and caps text captured from the screen before it leaves the app.
public enum ContentText {
    /// Collapses all whitespace runs to single spaces, trims, and caps at `max` characters
    /// (ending in "…" when cut).
    public static func clip(_ text: String, max: Int) -> String {
        let normalized = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard normalized.count > max else { return normalized }
        return String(normalized.prefix(Swift.max(0, max - 1))) + "…"
    }

    public static func clip(joining texts: [String], max: Int) -> String {
        clip(texts.joined(separator: " "), max: max)
    }
}
