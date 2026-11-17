import Foundation

/// Shapes raw on-device recognition strings (OCR lines, a classifier label) into a short shot caption (T-832).
public enum ShotCaption {
    public static func shape(_ lines: [String], maxWords: Int = 10) -> String? {
        var seen = Set<String>(), words: [String] = []
        for line in lines {
            let text = line.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            // junk: too short, or fewer than half the characters are letters/digits (icons, rules, glyph noise)
            guard text.count >= 3, text.filter({ $0.isLetter || $0.isNumber }).count * 2 >= text.count,
                  seen.insert(text.lowercased()).inserted else { continue }
            // OCR noise survives as tokens that are mostly symbols ("(keyl", "')"): keep word-like tokens only
            words += text.split(whereSeparator: \.isWhitespace).map(String.init).filter { token in
                let core = token.trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?"))
                return !core.isEmpty && core.allSatisfy { $0.isLetter || $0.isNumber || "-'/".contains($0) }
            }
        }
        return words.isEmpty ? nil : words.prefix(maxWords).joined(separator: " ")
    }
}
