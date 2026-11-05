import Foundation

/// The headings of a note body, for the outline (the web client's
/// `outline()` in `packages/core/src/markdown/render.ts`).
public struct Heading: Equatable, Identifiable, Sendable {
    public let level: Int
    public let text: String
    /// 0-based line in the body.
    public let line: Int
    public var id: Int { line }

    public init(level: Int, text: String, line: Int) {
        self.level = level
        self.text = text
        self.line = line
    }
}

public enum Outline {
    /// ATX headings (`#` to `######`), outside fenced code blocks.
    public static func headings(in body: String) -> [Heading] {
        var out: [Heading] = []
        var inFence = false
        for (i, raw) in body.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.hasSuffix("\r") ? raw.dropLast() : raw
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle() }
            if inFence { continue }
            guard let m = line.wholeMatch(of: /(#{1,6})\s+(.+?)\s*#*\s*/) else { continue }
            out.append(Heading(level: m.1.count, text: String(m.2), line: i))
        }
        return out
    }
}
