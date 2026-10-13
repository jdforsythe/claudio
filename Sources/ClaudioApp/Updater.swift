import AppKit
import ClaudioControlProtocol
import ClaudioCore
import CryptoKit
import Foundation

/// In-app updates from GitHub releases: check, download the zip, verify its sha256 against the release's
/// checksum file, swap the bundle in place and relaunch. Files the app downloads itself carry no quarantine
/// flag, so an update never triggers the Gatekeeper prompt that a browser download does.
@MainActor @Observable
final class Updater {
    static let repository = "jdforsythe/claudio"
    static let checkInterval: TimeInterval = 24 * 3600

    struct Release: Sendable, Equatable {
        let version: String
        let zipURL: URL
        let checksumURL: URL?
        let notes: String
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(String)
        case downloading(String)
        case installing
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var latest: Release?
    private let settings: AppSettings
    private let bundleURL: URL
    private let isBundled: Bool
    private var periodic: Task<Void, Never>?
    private var selfWatch: Task<Void, Never>?

    init(settings: AppSettings, bundleURL: URL, isBundled: Bool) {
        self.settings = settings
        self.bundleURL = bundleURL
        self.isBundled = isBundled
    }

    var availableVersion: String? {
        if case .available(let v) = state { return v }
        return nil
    }

    func start() {
        guard isBundled else { return }
        periodic = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.settings.autoUpdateCheck, Date().timeIntervalSince(self.settings.lastUpdateCheck) > Self.checkInterval {
                    await self.check()
                }
                try? await Task.sleep(for: .seconds(3600))
            }
        }
        watchOwnBundle()
    }

    // MARK: Check

    func check() async {
        guard isBundled else { return }
        state = .checking
        do {
            let release = try await Self.fetchLatest()
            settings.lastUpdateCheck = Date()
            latest = release
            if Self.isNewer(release.version, than: BuildInfo.version) {
                state = .available(release.version)
                Log.ui.info("update available: \(release.version)")
            } else {
                state = .upToDate
            }
        } catch {
            state = .failed(String(describing: error))
            Log.ui.notice("update check failed: \(error)")
        }
    }

    static func fetchLatest() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)  // swiftlint:disable:this force_unwrapping
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Claudio/\(BuildInfo.version)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw MessageError("GitHub returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String, let assets = obj["assets"] as? [[String: Any]] else {
            throw MessageError("unexpected release JSON")
        }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        func asset(_ suffix: String) -> URL? {
            assets.first { ($0["name"] as? String)?.hasSuffix(suffix) == true }
                .flatMap { $0["browser_download_url"] as? String }.flatMap(URL.init(string:))
        }
        guard let zip = asset(".zip").flatMap({ url in url.lastPathComponent.contains("dSYM") ? nil : url }) ?? assets.compactMap({ a -> URL? in
            guard let name = a["name"] as? String, name.hasSuffix(".zip"), !name.contains("dSYM") else { return nil }
            return (a["browser_download_url"] as? String).flatMap(URL.init(string:))
        }).first else {
            throw MessageError("release \(version) has no app zip")
        }
        return Release(version: version, zipURL: zip, checksumURL: asset(".sha256"), notes: obj["body"] as? String ?? "")
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").compactMap { Int($0) }
        let pb = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: Install

    func installLatest() async {
        guard let release = latest else {
            await check()
            guard latest != nil, case .available = state else { return }
            await installLatest()
            return
        }
        state = .downloading(release.version)
        do {
            let (zipFile, _) = try await URLSession.shared.download(from: release.zipURL)
            if let checksumURL = release.checksumURL {
                let (sumData, _) = try await URLSession.shared.data(from: checksumURL)
                let expected = String(decoding: sumData, as: UTF8.self).split(separator: "\n")
                    .first { $0.hasSuffix(release.zipURL.lastPathComponent) }?.split(separator: " ").first.map(String.init)
                let actual = SHA256.hash(data: try Data(contentsOf: zipFile)).map { String(format: "%02x", $0) }.joined()
                if let expected, expected != actual { throw MessageError("checksum mismatch for \(release.zipURL.lastPathComponent)") }
            }
            state = .installing
            try replaceBundle(withZip: zipFile)
            Log.ui.info("installed update \(release.version); relaunching")
            // Let the caller (Settings or the CLI) receive the result before the process goes away.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(700))
                self.relaunch()
            }
        } catch {
            state = .failed(String(describing: error))
            Log.ui.error("update failed: \(error)")
        }
    }

    private func replaceBundle(withZip zip: URL) throws {
        let fm = FileManager.default
        let stage = fm.temporaryDirectory.appendingPathComponent("claudio-update-\(UUID().uuidString)")
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zip.path, stage.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { throw MessageError("could not unpack the update") }
        guard let newApp = try fm.contentsOfDirectory(at: stage, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" }) else {
            throw MessageError("the update contains no app bundle")
        }
        // Downloads made by this app are not quarantined, but be explicit in case a proxy added the flag.
        removexattr(newApp.path, "com.apple.quarantine", XATTR_NOFOLLOW)
        _ = try fm.replaceItemAt(bundleURL, withItemAt: newApp, backupItemName: nil, options: [])
        try? fm.removeItem(at: stage)
    }

    func relaunch() {
        let path = bundleURL.path
        let script = Process()
        script.executableURL = URL(fileURLWithPath: "/bin/sh")
        script.arguments = ["-c", "sleep 1; /usr/bin/open -n \"\(path)\""]
        try? script.run()
        NSApp.terminate(nil)
    }

    // MARK: Self watch (a DMG drag over the running app)

    private func watchOwnBundle() {
        let plist = bundleURL.appendingPathComponent("Contents/Info.plist")
        let running = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        selfWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self else { return }
                guard let dict = NSDictionary(contentsOf: plist) as? [String: Any],
                      let onDisk = dict["CFBundleVersion"] as? String, let running, onDisk != running else { continue }
                Log.ui.notice("bundle on disk changed (\(running) → \(onDisk)); relaunching")
                self.relaunch()
                return
            }
        }
    }
}
