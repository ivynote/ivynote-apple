import Foundation

/// Words of a note, counted as the server and the web count them (guide
/// 9.3): each CJK character (kana, kanji, hangul) is a word, as is every run
/// of other letters or digits. Markdown syntax does not count.
public enum WordCount {
    public static func count(_ body: String) -> Int {
        var n = 0
        var inWord = false
        for scalar in plain(body).unicodeScalars {
            if isCJK(scalar) {
                n += 1
                inWord = false
            } else if CharacterSet.alphanumerics.contains(scalar) {
                if !inWord { n += 1 }
                inWord = true
            } else {
                inWord = false
            }
        }
        return n
    }

    /// The body without code blocks, images, link syntax, line markers,
    /// emphasis and HTML.
    static func plain(_ body: String) -> String {
        var lines: [Substring] = []
        var inFence = false
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.drop(while: { $0 == " " || $0 == "\t" })
            if t.hasPrefix("```") || t.hasPrefix("~~~") { inFence.toggle(); continue }
            if !inFence { lines.append(line) }
        }
        var s = lines.joined(separator: "\n")
        s = s.replacing(/!\[[^\]]*\]\([^)]*\)/, with: "")
        s = s.replacing(/\[\[([^\[\]\n|]+)(?:\|([^\[\]\n]+))?\]\]/) { m in String(m.2 ?? m.1) }
        s = s.replacing(/\[([^\]]*)\]\([^)]*\)/) { String($0.1) }
        s = s.replacing(/<[^>\n]+>/, with: " ")
        s = s.replacing(/^[ \t]*(?:[#>]+|[-*+][ \t]+\[[ xX]\]|[-*+]|\d+[.)])[ \t]*/.anchorsMatchLineEndings(), with: "")
        s = s.replacing(/[*_~`=]+/, with: "")
        return s
    }

    static func isCJK(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3040...0x30FF, // kana
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F, // han
             0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F: // hangul
            true
        default:
            false
        }
    }
}
