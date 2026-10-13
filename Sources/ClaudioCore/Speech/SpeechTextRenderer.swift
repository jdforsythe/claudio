import Foundation

/// Markdown → `Utterance` via a staged line-oriented rewriter (document 05 §4).
public struct SpeechTextRenderer: Sendable {
    public let rules: MarkdownSpeechRules
    public let segmenter: SentenceSegmenter
    public static let inputCap = 200_000

    public init(rules: MarkdownSpeechRules = .standard, segmenter: SentenceSegmenter = SentenceSegmenter()) {
        self.rules = rules
        self.segmenter = segmenter
    }

    enum Block {
        case prose(String)
        case segment(kind: Utterance.Segment.Kind, text: String)
    }

    public func render(_ item: SpeechItem) -> Utterance {
        if item.category == .event {
            let text = collapseWhitespace(Cues.strip(item.text))
            return Utterance(item: item, segments: text.isEmpty ? [] : [Utterance.Segment(text: text, kind: .cue)])
        }
        var text = item.text
        if text.count > Self.inputCap {
            Log.render.error("input over cap (\(text.count) chars); speaking raw prefix")
            text = String(text.prefix(Self.inputCap))
        }
        let segments = renderSegments(text)
        return Utterance(item: item, segments: segments)
    }

    /// Renders raw markdown into segments (used by `render` and `claudio render`).
    public func renderSegments(_ markdown: String) -> [Utterance.Segment] {
        let normalized = normalize(markdown)
        let blocks = parseBlocks(normalized)
        var out: [Utterance.Segment] = []
        for block in blocks {
            switch block {
            case .prose(let p):
                let cleaned = collapseWhitespace(inline(p))
                out.append(contentsOf: segmenter.segment(cleaned, kind: .sentence))
            case .segment(let kind, let t):
                let cleaned = kind == .cue ? collapseWhitespace(t) : collapseWhitespace(inline(t))
                out.append(contentsOf: segmenter.segment(cleaned, kind: kind))
            }
        }
        return out
    }

    // MARK: Stage 1 — normalize

    static let ansi = Rx(#"\x{1B}\[[0-9;?]*[ -/]*[@-~]"#)
    static let zeroWidth = Rx(#"[\x{200B}-\x{200D}\x{FEFF}]"#)

    func normalize(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        t = Self.ansi.replace(t, with: "")
        t = Self.zeroWidth.replace(t, with: "")
        return t
    }

    // MARK: Stages 2–7 — block structure

    static let fenceOpen = Rx(#"^\s*(`{3,}|~{3,})\s*([A-Za-z0-9_+-]*)"#)
    static let tableSeparator = Rx(#"^\s*\|?\s*:?-{1,}:?\s*(\|\s*:?-{1,}:?\s*)*\|?\s*$"#)
    static let heading = Rx(#"^#{1,6}\s+(.*?)\s*#*\s*$"#)
    static let listItem = Rx(#"^(\s*)([-*+]|\d+[.)])\s+(.*)$"#)
    static let horizontalRule = Rx(#"^\s*([-*_])\s*\1\s*\1[\s\1]*$"#)
    static let htmlTag = Rx(#"<[^>\n]{1,80}>"#)
    static let refLink = Rx(#"^\[[^\]]+\]:\s+\S+"#)
    static let blockquote = Rx(#"^\s*>\s?"#)
    static let setextUnderline = Rx(#"^\s*(=+|-+)\s*$"#)
    static let taskMarker = Rx(#"^\[( |x|X)\]\s*"#)

    func parseBlocks(_ text: String) -> [Block] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [Block] = []
        var paragraph: [String] = []
        var i = 0
        var previousBlank = true

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.prose(paragraph.joined(separator: " ")))
                paragraph.removeAll()
            }
        }

        while i < lines.count {
            let rawLine = lines[i]
            let line = Self.blockquote.replace(rawLine, with: "")

            // Fenced code
            if let m = Self.fenceOpen.captures(line) {
                flushParagraph()
                let fence = m[1]
                let lang = m[2]
                var j = i + 1
                while j < lines.count {
                    let candidate = Self.blockquote.replace(lines[j], with: "").trimmingCharacters(in: .whitespaces)
                    if candidate.hasPrefix(fence), candidate.allSatisfy({ $0 == fence.first }) { break }
                    j += 1
                }
                blocks.append(.segment(kind: .cue, text: Self.codeBlockCue(language: lang)))
                i = j + 1
                previousBlank = true
                continue
            }

            // Blank line
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushParagraph()
                previousBlank = true
                i += 1
                continue
            }

            // Indented code (outside lists, after a blank line)
            if previousBlank, paragraph.isEmpty, Self.isIndentedCode(line) {
                var j = i
                while j < lines.count, Self.isIndentedCode(lines[j]) || lines[j].trimmingCharacters(in: .whitespaces).isEmpty {
                    if lines[j].trimmingCharacters(in: .whitespaces).isEmpty,
                       j + 1 < lines.count, !Self.isIndentedCode(lines[j + 1]) { break }
                    j += 1
                }
                blocks.append(.segment(kind: .cue, text: "code block."))
                i = j
                previousBlank = true
                continue
            }

            // Table
            if line.contains("|"), i + 1 < lines.count,
               Self.tableSeparator.matches(Self.blockquote.replace(lines[i + 1], with: "")) {
                flushParagraph()
                let headers = Self.splitCells(line)
                var j = i + 2
                while j < lines.count {
                    let row = Self.blockquote.replace(lines[j], with: "")
                    guard row.contains("|"), !row.trimmingCharacters(in: .whitespaces).isEmpty else { break }
                    let cells = Self.splitCells(row)
                    var parts: [String] = []
                    for (idx, cell) in cells.enumerated() {
                        let header = idx < headers.count ? headers[idx] : "column \(idx + 1)"
                        let value = cell.isEmpty ? "empty" : cell
                        parts.append("\(header): \(value)")
                    }
                    blocks.append(.segment(kind: .tableRow, text: parts.joined(separator: ", ") + "."))
                    j += 1
                }
                i = j
                previousBlank = true
                continue
            }

            // Heading (ATX)
            if let m = Self.heading.captures(line) {
                flushParagraph()
                blocks.append(.segment(kind: .heading, text: m[1]))
                i += 1
                previousBlank = true
                continue
            }

            // Setext heading: a single prose line followed by === or ---
            if i + 1 < lines.count, Self.setextUnderline.matches(lines[i + 1]), paragraph.isEmpty,
               !Self.listItem.matches(line), !line.contains("|") {
                flushParagraph()
                blocks.append(.segment(kind: .heading, text: line.trimmingCharacters(in: .whitespaces)))
                i += 2
                previousBlank = true
                continue
            }

            // Horizontal rule / reference link definitions
            if Self.horizontalRule.matches(line) || Self.refLink.matches(line) {
                flushParagraph()
                i += 1
                previousBlank = true
                continue
            }

            // Lists
            if let m = Self.listItem.captures(line) {
                flushParagraph()
                let markerWidth = m[1].count + m[2].count + 1
                var itemText = m[3]
                var j = i + 1
                while j < lines.count {
                    let next = Self.blockquote.replace(lines[j], with: "")
                    if next.trimmingCharacters(in: .whitespaces).isEmpty { break }
                    if Self.listItem.matches(next) { break }
                    let leading = next.prefix(while: { $0 == " " || $0 == "\t" }).count
                    guard leading >= min(markerWidth, 2) || !paragraphLikeStart(next) else { break }
                    itemText += " " + next.trimmingCharacters(in: .whitespaces)
                    j += 1
                }
                if let t = Self.taskMarker.captures(itemText) {
                    itemText = Self.taskMarker.replace(itemText, with: "")
                    if t[1].lowercased() == "x" { itemText = "done: " + itemText }
                }
                var cleaned = itemText.trimmingCharacters(in: .whitespaces)
                if let last = cleaned.last, !".!?:".contains(last) { cleaned += "." }
                blocks.append(.segment(kind: .listItem, text: cleaned))
                i = j
                previousBlank = false
                continue
            }

            // Prose
            paragraph.append(line.trimmingCharacters(in: .whitespaces))
            previousBlank = false
            i += 1
        }
        flushParagraph()
        return blocks
    }

    private func paragraphLikeStart(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.first.map { $0.isUppercase } ?? false
    }

    static func isIndentedCode(_ line: String) -> Bool {
        line.hasPrefix("    ") || line.hasPrefix("\t")
    }

    static func splitCells(_ row: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var escaped = false
        for ch in row {
            if escaped {
                current.append(ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        if let first = cells.first, first.isEmpty { cells.removeFirst() }
        if let last = cells.last, last.isEmpty { cells.removeLast() }
        return cells
    }

    static let languageNames: [String: String] = [
        "js": "JavaScript", "javascript": "JavaScript", "ts": "TypeScript", "typescript": "TypeScript",
        "py": "Python", "python": "Python", "sh": "shell", "bash": "shell", "zsh": "shell", "shell": "shell",
        "swift": "Swift", "json": "JSON", "yaml": "YAML", "yml": "YAML", "md": "markdown", "markdown": "markdown",
        "rb": "Ruby", "go": "Go", "rs": "Rust", "c": "C", "cpp": "C plus plus", "html": "HTML", "css": "CSS",
        "sql": "SQL", "xml": "XML", "toml": "TOML", "text": "", "txt": "", "plaintext": "",
    ]

    static func codeBlockCue(language: String) -> String {
        let lang = language.lowercased()
        guard !lang.isEmpty else { return "code block." }
        let name = languageNames[lang] ?? language
        return name.isEmpty ? "code block." : "\(name) code block."
    }

    // MARK: Stage 8 — inline

    static let inlineCode = Rx(#"`([^`\n]+)`"#)

    func inline(_ text: String) -> String {
        // Protect cleaned inline code so later rules do not rewrite it twice (stage-order guard).
        var protected: [String] = []
        var s = Self.inlineCode.replace(text) { g in
            protected.append(Self.inlineCodeCleanup(g[1]))
            return "\u{E000}\(protected.count - 1)\u{E001}"
        }
        s = Self.htmlTag.replace(s, with: "")
        s = rules.apply(s)
        s = Rx(#"\x{E000}(\d+)\x{E001}"#).replace(s) { g in
            if let idx = Int(g[1]), idx < protected.count { return protected[idx] }
            return ""
        }
        return s
    }

    // MARK: Stage 9 — whitespace

    static let spaces = Rx(#"[ \t]+"#)
    static let newlines = Rx(#"\n{3,}"#)
    static let spaceBeforePunct = Rx(#"\s+([,.;:!?])"#)

    func collapseWhitespace(_ s: String) -> String {
        var t = Self.spaces.replace(s, with: " ")
        t = Self.newlines.replace(t, with: "\n\n")
        t = Self.spaceBeforePunct.replace(t, with: "$1")
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: inlineCodeCleanup (document 05 §4.3)

    static let knownExtensions: Set<String> = [
        "swift", "py", "js", "ts", "tsx", "jsx", "json", "md", "yml", "yaml", "toml", "sh", "rs", "go", "rb", "java",
        "kt", "c", "h", "cpp", "m", "mm", "html", "css", "sql", "txt", "plist", "xcconfig", "lock",
    ]
    static let extensionsAsWords: Set<String> = [
        "swift", "json", "yaml", "yml", "toml", "plist", "lock", "html", "java", "go", "sql", "txt", "css", "cpp",
        "xcconfig",
    ]
    static let filenamePattern = Rx(#"^([\w.\-]+)\.([A-Za-z0-9]{1,8})$"#)
    static let allCapsRun = Rx(#"^[A-Z0-9]{2,}$"#)

    public static func inlineCodeCleanup(_ token: String) -> String {
        let t = token.trimmingCharacters(in: .whitespaces)
        if let m = filenamePattern.captures(t), knownExtensions.contains(m[2].lowercased()) {
            let stem = cleanupIdentifier(m[1])
            return "\(stem) dot \(spokenExtension(m[2]))"
        }
        return cleanupIdentifier(t)
    }

    static func spokenExtension(_ ext: String) -> String {
        let lower = ext.lowercased()
        if extensionsAsWords.contains(lower) || lower.count > 3 { return lower }
        return lower.uppercased().map { String($0) }.joined(separator: " ")
    }

    static func cleanupIdentifier(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: "::", with: " ")
        t = t.replacingOccurrences(of: "->", with: " to ").replacingOccurrences(of: "=>", with: " to ")
        t = t.replacingOccurrences(of: "==", with: " equals ")
        t = t.replacingOccurrences(of: "!=", with: " does not equal ")
        for ch in ["<", ">", "(", ")", "[", "]", "{", "}", "\"", "'"] {
            t = t.replacingOccurrences(of: ch, with: " ")
        }
        // Identifiers and long numbers are spelled out (same rule as prose).
        t = MarkdownSpeechRules.ruleIdentifiers(t)
        // Dotted paths that are not filenames: a.b.c → a b c
        t = t.replacingOccurrences(of: ".", with: " ")
        // snake_case → words (keep all-caps runs)
        let words = t.split(separator: " ").map(String.init)
        var out: [String] = []
        for w in words {
            let parts = w.split(separator: "_", omittingEmptySubsequences: true).map(String.init)
            for p in parts {
                if allCapsRun.matches(p) {
                    out.append(p)
                } else {
                    out.append(ToolCallSummarizer.splitCamel(p))
                }
            }
        }
        return out.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}
