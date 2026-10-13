// Deterministically replaces prose, paths and tool payloads in a transcript with lorem text of equal length,
// preserving every structural field (docs/09 §2.2). Usage: swift scrub-transcript.swift <in.jsonl> <out.jsonl>
import Foundation

let args = CommandLine.arguments
guard args.count == 3 else { print("usage: scrub-transcript.swift <in.jsonl> <out.jsonl>"); exit(2) }
let input = try String(contentsOfFile: args[1], encoding: .utf8)
var seed: UInt64 = 0xcbf29ce484222325
for b in (args[1] as NSString).lastPathComponent.utf8 { seed = (seed ^ UInt64(b)) &* 0x100000001b3 }
func next() -> UInt64 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return seed >> 33 }
let lorem = "lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore et dolore magna aliqua".split(separator: " ")
func loremText(length: Int, template: String) -> String {
    var out = ""
    var lineStart = true
    for ch in template {
        if ch == "\n" { out.append("\n"); lineStart = true; continue }
        if lineStart, "#-*|`>".contains(ch) || ch.isNumber { out.append(ch); continue }
        if ch == "|" || ch == "`" { out.append(ch); continue }
        lineStart = false
        if ch == " " { out.append(" "); continue }
        let word = lorem[Int(next() % UInt64(lorem.count))]
        out.append(word[word.index(word.startIndex, offsetBy: Int(next() % UInt64(word.count)))])
    }
    return String(out.prefix(max(length, 0)))
}
var cwdMap: [String: String] = [:]
var titleCount = 0
let keepKeys: Set<String> = ["type","subtype","uuid","parentUuid","sessionId","session_id","promptId","requestId","apiBlockIndex","isSidechain","agentId","entrypoint","version","timestamp","userType","isMeta","origin","promptSource","turnOrigin","turnPosition","id","role","model","stop_reason","usage","durationMs","messageCount","permissionMode","mode","operation","hookCount","exitCode","name","tool_use_id","is_error","success","interrupted","agentType","leafUuid","messageId","pendingBackgroundAgentCount","stop_sequence","hookEvent","hookName"]
func scrub(_ value: Any, key: String?) -> Any {
    switch value {
    case let dict as [String: Any]:
        var out: [String: Any] = [:]
        for (k, v) in dict {
            switch k {
            case "cwd", "gitBranch":
                if k == "gitBranch" { out[k] = "main" } else {
                    let s = v as? String ?? ""
                    if cwdMap[s] == nil { cwdMap[s] = "/Users/fixture/project-\(cwdMap.count + 1)" }
                    out[k] = cwdMap[s]
                }
            case "aiTitle": titleCount += 1; out[k] = "Fixture Title \(titleCount)"
            case "signature": out[k] = "REDACTED"
            case "attachment", "rendered", "snapshot", "serverClassifierContext", "wireToolInputs", "wireIngestContext":
                if let d = v as? [String: Any], k == "attachment" {
                    var kept: [String: Any] = [:]
                    for key in ["type", "hookEvent", "hookName", "exitCode"] { if let x = d[key] { kept[key] = x } }
                    if let c = d["command"] as? String { kept["command"] = c.contains("claudio hook") ? c : "/Users/fixture/hook" }
                    out[k] = kept
                } else { out[k] = [String: Any]() }
            case "command": out[k] = "echo lorem"
            case "file_path", "notebook_path": out[k] = "/Users/fixture/project-1/File\(next() % 90 + 10).swift"
            default:
                if keepKeys.contains(k) { out[k] = v } else { out[k] = scrub(v, key: k) }
            }
        }
        return out
    case let arr as [Any]:
        return arr.map { scrub($0, key: key) }
    case let s as String:
        return loremText(length: s.count, template: s)
    default:
        return value
    }
}
var lines: [String] = []
for line in input.split(separator: "\n", omittingEmptySubsequences: true) {
    guard let data = line.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) else { lines.append(String(line)); continue }
    let scrubbed = scrub(obj, key: nil)
    let out = try JSONSerialization.data(withJSONObject: scrubbed, options: [.sortedKeys, .withoutEscapingSlashes])
    lines.append(String(decoding: out, as: UTF8.self))
}
try (lines.joined(separator: "\n") + "\n").write(toFile: args[2], atomically: true, encoding: .utf8)
print("✓ \(args[2]) (\(lines.count) lines)")
