import Foundation

/// The ordered inline rewrite rules of document 05 §4.2.
public struct MarkdownSpeechRules: Sendable {
    public struct Rule: Sendable {
        public let number: Int
        public let name: String
        public let apply: @Sendable (String) -> String
    }

    public let rules: [Rule]

    public static let standard = MarkdownSpeechRules(rules: Self.standardRules)

    public init(rules: [Rule]) {
        self.rules = rules
    }

    public func apply(_ text: String) -> String {
        var s = text
        for r in rules { s = r.apply(s) }
        return s
    }

    // MARK: Patterns

    static let image = Rx(#"!\[[^\]]*\]\([^)]*\)"#)
    static let link = Rx(#"\[([^\]]+)\]\((?:[^)\s]+)(?:\s+"[^"]*")?\)"#)
    static let url = Rx(#"<?(?:https?|ftp|file)://[^\s<>)\]]+>?"#)
    static let www = Rx(#"(?<![\w/])www\.[^\s<>)\]]+"#)
    static let bold = Rx(#"(\*\*|__)(.+?)\1"#)
    static let italic = Rx(#"(?<![\w*])(\*|_)(?=\S)(.+?)(?<=\S)\1(?![\w*])"#)
    static let strike = Rx(#"~~(.+?)~~"#)
    static let globDeep = Rx(#"(?<!\S)\*\*/\*\.([A-Za-z0-9]+)(?!\S)"#)
    static let glob = Rx(#"(?<!\S)\*\.([A-Za-z0-9]+)(?!\S)"#)
    static let path = Rx(#"(?<![\w@])(~|\.{1,2})?(/[\w.\-@+%]+){2,}/?"#)
    static let longFlag = Rx(#"(?<!\S)--([a-z][\w-]*)"#)
    static let shortFlag = Rx(#"(?<!\S)-([a-zA-Z])(?!\w)"#)
    static let arrow = Rx(#"\s*(->|=>|→|⇒)\s*"#)
    static let ampersand = Rx(#"\s&\s"#)
    static let comparison = Rx(#"\s(==|!=|<=|>=)\s"#)
    static let emoji = Rx(#"[\p{Extended_Pictographic}\x{2600}-\x{27BF}\x{2B00}-\x{2BFF}\x{FE0F}\x{200D}]"#)
    static let boxDrawing = Rx(#"[\x{2500}-\x{257F}\x{2022}\x{25A0}-\x{25FF}]"#)
    static let residualLine = Rx(#"(?m)^\s*[#>*_-]+\s*$"#)
    static let escapes = Rx(#"\\([\\`*_{}\[\]()#+\-.!|])"#)
    static let fileLineRef = Rx(#"\(([\w./-]+\.\w{1,5}):(\d+)\)"#)
    static let multiPunct = Rx(#"([.!?]){2,}"#)

    static func ruleImages(_ s: String) -> String { image.replace(s, with: "") }
    static func ruleLinks(_ s: String) -> String { link.replace(s, with: "$1") }
    static func ruleURLs(_ s: String) -> String { www.replace(url.replace(s, with: "link"), with: "link") }
    static func ruleBoldItalic(_ s: String) -> String { italic.replace(bold.replace(s, with: "$2"), with: "$2") }
    static func ruleStrike(_ s: String) -> String { strike.replace(s, with: "$1") }
    static func ruleGlobs(_ s: String) -> String { glob.replace(globDeep.replace(s, with: "$1 files"), with: "$1 files") }
    static func ruleFileLineRefs(_ s: String) -> String {
        fileLineRef.replace(s) { g in " \(SpeechTextRenderer.inlineCodeCleanup(g[1])) line \(g[2])" }
    }
    static func rulePaths(_ s: String) -> String {
        path.replace(s) { g in
            let whole = g[0]
            let skip: Set<String> = ["", "~", ".", ".."]
            let parts: [String] = whole.split(separator: "/").map { String($0) }
            let kept: [String] = parts.filter { !skip.contains($0) }
            guard let last = kept.last else { return whole }
            return SpeechTextRenderer.inlineCodeCleanup(last)
        }
    }
    static func ruleLongFlags(_ s: String) -> String {
        longFlag.replace(s) { g in g[1].replacingOccurrences(of: "-", with: " ") }
    }
    static func ruleShortFlags(_ s: String) -> String { shortFlag.replace(s, with: "dash $1") }
    static func ruleArrows(_ s: String) -> String { arrow.replace(s, with: " to ") }
    static func ruleAmpersand(_ s: String) -> String { ampersand.replace(s, with: " and ") }
    static func ruleComparison(_ s: String) -> String {
        comparison.replace(s) { g in
            switch g[1] {
            case "==": return " equals "
            case "!=": return " does not equal "
            case "<=": return " at most "
            default: return " at least "
            }
        }
    }
    static func ruleEmoji(_ s: String) -> String { emoji.replace(s, with: "") }
    static func ruleBoxDrawing(_ s: String) -> String { boxDrawing.replace(s, with: "") }
    static func ruleResidual(_ s: String) -> String { escapes.replace(residualLine.replace(s, with: ""), with: "$1") }
    static func ruleMultiPunct(_ s: String) -> String { multiPunct.replace(s) { g in String(g[0].prefix(1)) } }

    static let standardRules: [Rule] = [
        Rule(number: 1, name: "images", apply: ruleImages),
        Rule(number: 2, name: "links", apply: ruleLinks),
        Rule(number: 3, name: "urls", apply: ruleURLs),
        Rule(number: 5, name: "bold-italic", apply: ruleBoldItalic),
        Rule(number: 6, name: "strikethrough", apply: ruleStrike),
        Rule(number: 7, name: "globs", apply: ruleGlobs),
        Rule(number: 17, name: "file-line-refs", apply: ruleFileLineRefs),
        Rule(number: 8, name: "paths", apply: rulePaths),
        Rule(number: 9, name: "long-flags", apply: ruleLongFlags),
        Rule(number: 10, name: "short-flags", apply: ruleShortFlags),
        Rule(number: 11, name: "arrows", apply: ruleArrows),
        Rule(number: 12, name: "ampersand", apply: ruleAmpersand),
        Rule(number: 13, name: "comparison", apply: ruleComparison),
        Rule(number: 14, name: "emoji", apply: ruleEmoji),
        Rule(number: 15, name: "box-drawing", apply: ruleBoxDrawing),
        Rule(number: 16, name: "residual-markdown", apply: ruleResidual),
        Rule(number: 18, name: "multi-punct", apply: ruleMultiPunct),
    ]
}
