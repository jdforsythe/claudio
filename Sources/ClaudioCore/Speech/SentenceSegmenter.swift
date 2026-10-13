import Foundation
import NaturalLanguage

/// Prose → sentence segments with abbreviation repair, short-merge and long-split (document 05 §5).
public struct SentenceSegmenter: Sendable {
    public var minimumLength: Int = 60
    public var maximumBytes: Int = 1200

    public init(minimumLength: Int = 60, maximumBytes: Int = 1200) {
        self.minimumLength = minimumLength
        self.maximumBytes = maximumBytes
    }

    static let abbreviations: [String] = [
        "e.g.", "i.e.", "vs.", "etc.", "Dr.", "Mr.", "Mrs.", "Ms.", "Prof.", "Inc.", "Ltd.", "No.", "Fig.", "approx.",
        "cf.", "St.", "Jr.", "Sr.",
    ]

    public func segment(_ text: String, kind: Utterance.Segment.Kind) -> [Utterance.Segment] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        switch kind {
        case .tableRow:
            return [Utterance.Segment(text: trimmed, kind: .tableRow)]
        case .heading, .listItem, .cue:
            return splitLong(trimmed).map { Utterance.Segment(text: $0, kind: kind) }
        case .sentence:
            break
        }
        var sentences = tokenize(trimmed)
        sentences = repairAbbreviations(sentences)
        sentences = mergeShort(sentences)
        var out: [Utterance.Segment] = []
        for s in sentences {
            for piece in splitLong(s) {
                let t = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { out.append(Utterance.Segment(text: t, kind: .sentence)) }
            }
        }
        return out
    }

    func tokenize(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        var language = NLLanguage.english
        if let (lang, confidence) = recognizer.languageHypotheses(withMaximum: 1).first, confidence >= 0.8 {
            language = lang
        }
        tokenizer.setLanguage(language)
        tokenizer.string = text
        var out: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let s = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { out.append(s) }
            return true
        }
        if out.isEmpty { out = [text] }
        return out
    }

    func repairAbbreviations(_ sentences: [String]) -> [String] {
        guard sentences.count > 1 else { return sentences }
        var out: [String] = []
        var i = 0
        while i < sentences.count {
            var current = sentences[i]
            while i + 1 < sentences.count, Self.shouldJoin(current, next: sentences[i + 1]) {
                current += " " + sentences[i + 1]
                i += 1
            }
            out.append(current)
            i += 1
        }
        return out
    }

    static func shouldJoin(_ first: String, next: String) -> Bool {
        for abbr in abbreviations where first.hasSuffix(abbr) || first.hasSuffix(abbr.lowercased()) {
            return true
        }
        let chars = Array(first)
        if chars.count >= 2, chars[chars.count - 1] == ".", chars[chars.count - 2].isUppercase,
           chars.count == 2 || !chars[chars.count - 3].isLetter {
            return true  // initial like "J."
        }
        if let last = chars.last, last == ".", chars.count >= 2, chars[chars.count - 2].isNumber,
           let nextFirst = next.first, nextFirst.isNumber {
            return true  // "version 2." + "1.290"
        }
        return false
    }

    func mergeShort(_ sentences: [String]) -> [String] {
        var out: [String] = []
        var carry: String?
        for s in sentences {
            if let c = carry {
                let merged = c + " " + s
                if merged.count < minimumLength {
                    carry = merged
                } else {
                    out.append(merged)
                    carry = nil
                }
            } else if s.count < minimumLength {
                carry = s
            } else {
                out.append(s)
            }
        }
        if let c = carry { out.append(c) }
        return out
    }

    func splitLong(_ sentence: String) -> [String] {
        guard sentence.utf8.count > maximumBytes else { return [sentence] }
        var pieces: [String] = []
        var remaining = Substring(sentence)
        while remaining.utf8.count > maximumBytes {
            let window = Self.prefixWithinBytes(remaining, maximumBytes)
            var cut: String.Index?
            let searchStart = window.index(window.startIndex, offsetBy: Int(Double(window.count) * 0.6))
            for separator in ["; ", ": ", ", ", " — ", " - "] {
                if let r = window.range(of: separator, options: .backwards), r.lowerBound >= searchStart {
                    if cut == nil || r.upperBound > cut! { cut = r.upperBound }  // swiftlint:disable:this force_unwrapping
                }
            }
            if cut == nil, let r = window.range(of: " ", options: .backwards), r.lowerBound > window.startIndex {
                cut = r.upperBound
            }
            let cutIndex = cut ?? window.endIndex
            let piece = remaining[remaining.startIndex..<cutIndex].trimmingCharacters(in: .whitespaces)
            if !piece.isEmpty { pieces.append(piece) }
            remaining = remaining[cutIndex...]
            if remaining.startIndex == cutIndex, cutIndex == window.endIndex, window.isEmpty { break }
        }
        let tail = remaining.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { pieces.append(tail) }
        return pieces
    }

    static func prefixWithinBytes(_ s: Substring, _ limit: Int) -> Substring {
        var count = 0
        var end = s.startIndex
        for i in s.indices {
            let n = s[i].utf8.count
            if count + n > limit { break }
            count += n
            end = s.index(after: i)
        }
        return s[s.startIndex..<end]
    }
}
