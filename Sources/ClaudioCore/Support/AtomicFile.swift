import Foundation

/// Temp + rename writes so a crash never leaves a truncated file (document 08 §1).
public enum AtomicFile {
    public static func write(_ data: Data, to url: URL, permissions: Int? = nil) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).claudio-tmp-\(UUID().uuidString.prefix(8))")
        try data.write(to: tmp, options: [.atomic])
        if let permissions {
            try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: tmp.path)
        } else if let existing = try? fm.attributesOfItem(atPath: url.path)[.posixPermissions] {
            try? fm.setAttributes([.posixPermissions: existing], ofItemAtPath: tmp.path)
        }
        if let handle = try? FileHandle(forWritingTo: tmp) {
            try? handle.synchronize()
            try? handle.close()
        }
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: url)
        }
        try? fm.removeItem(at: tmp)
    }
}
