import ClaudioCore
import TestSupport
import XCTest

final class HookInstallerTests: XCTestCase {
    var root = TempRoot()
    var settingsURL: URL { root.path("settings.json") }
    var bundle: URL { root.path("Claudio.app") }

    override func setUp() { root = TempRoot() }
    override func tearDown() { root.cleanup() }

    private func installer(bundle: URL? = nil) -> HookInstaller {
        HookInstaller(settingsURL: settingsURL, backupsDirectory: root.path("backups"), bundleURL: bundle ?? self.bundle)
    }

    private func copyFixture(_ name: String) throws {
        let url = try XCTUnwrap(TestFixtures.url("settings/\(name)"))
        try FileManager.default.copyItem(at: url, to: settingsURL)
    }

    private func json() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any])
    }

    func test_HookInstaller_install_appendsEntriesPreservingOthers() throws {
        try copyFixture("with-orca-and-plugins.json")
        let before = try json()
        try installer().install()
        let after = try json()
        XCTAssertEqual(after["customKey"] as? NSDictionary, before["customKey"] as? NSDictionary)
        XCTAssertEqual(after["permissions"] as? NSDictionary, before["permissions"] as? NSDictionary)
        let hooks = try XCTUnwrap(after["hooks"] as? [String: Any])
        let beforeHooks = try XCTUnwrap(before["hooks"] as? [String: Any])
        for (event, groups) in beforeHooks {
            let afterGroups = try XCTUnwrap(hooks[event] as? [Any])
            let foreign = afterGroups.filter { HookInstaller.ownBundlePath(group: $0) == nil }
            XCTAssertEqual(foreign as NSArray, groups as? NSArray)
        }
        for event in HookInstaller.events {
            let groups = try XCTUnwrap(hooks[event] as? [[String: Any]])
            let ours = groups.filter { HookInstaller.ownBundlePath(group: $0) != nil }
            XCTAssertEqual(ours.count, 1, event)
            let hook = try XCTUnwrap((ours[0]["hooks"] as? [[String: Any]])?.first)
            XCTAssertEqual(hook["async"] as? Bool, true)
            XCTAssertEqual(hook["command"] as? String, bundle.path + "/Contents/Helpers/claudio hook")
            if HookInstaller.eventsWithMatcher.contains(event) { XCTAssertEqual(ours[0]["matcher"] as? String, "") }
        }
        guard case .installed(let count, let path) = installer().status() else { return XCTFail("expected installed") }
        XCTAssertEqual(count, 7)
        XCTAssertEqual(path, bundle.path)
    }

    func test_HookInstaller_install_isIdempotent_andMissingFileCreatesMinimal() throws {
        try installer().install()
        let first = try json() as NSDictionary
        try installer().install()
        XCTAssertEqual(try json() as NSDictionary, first)
        let hooks = try XCTUnwrap(try json()["hooks"] as? [String: Any])
        XCTAssertEqual(hooks.count, 7)
    }

    func test_HookInstaller_uninstall_removesExactlyOurs() throws {
        try copyFixture("with-orca-and-plugins.json")
        let before = try json()
        try installer().install()
        try installer().uninstall()
        let after = try json()
        XCTAssertEqual(after["hooks"] as? NSDictionary, before["hooks"] as? NSDictionary)
        XCTAssertEqual(installer().status(), .notInstalled)
    }

    func test_HookInstaller_malformedSettings_refusesToWrite() throws {
        try copyFixture("malformed.json")
        let before = try Data(contentsOf: settingsURL)
        XCTAssertThrowsError(try installer().install()) { error in
            guard case HookInstallerError.settingsMalformed = error else { return XCTFail("wrong error \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: settingsURL), before)
        guard case .settingsUnreadable = installer().status() else { return XCTFail("expected unreadable") }
    }

    func test_HookInstaller_backupRotationKeepsTen() throws {
        try installer().install()
        for _ in 0..<12 { try installer().install(); try installer().uninstall() }
        let backups = try FileManager.default.contentsOfDirectory(atPath: root.path("backups").path).filter { $0.hasPrefix("settings-") }
        XCTAssertEqual(backups.count, 10)
    }

    func test_HookInstaller_bundleMoved_statusReportsStale_andRepairRewrites() throws {
        try installer().install()
        let moved = root.path("Elsewhere/Claudio.app")
        guard case .installedElsewhere(_, let path) = installer(bundle: moved).status() else { return XCTFail("expected installedElsewhere") }
        XCTAssertEqual(path, bundle.path)
        try installer(bundle: moved).repair()
        guard case .installed(_, let newPath) = installer(bundle: moved).status() else { return XCTFail("expected installed") }
        XCTAssertEqual(newPath, moved.path)
    }

    func test_HookInstaller_unbundled_throws() {
        XCTAssertThrowsError(try installer(bundle: root.path("debug")).install())
    }

    func test_SkillInstaller_installAndRefuseForeign() throws {
        let dir = root.path("skills/speak")
        let s = SkillInstaller(skillDirectory: dir, cliPath: "/Applications/Claudio.app/Contents/Helpers/claudio")
        XCTAssertFalse(s.isInstalled())
        try s.install()
        XCTAssertTrue(s.isInstalled())
        XCTAssertTrue(try String(contentsOf: s.fileURL, encoding: .utf8).contains("Contents/Helpers/claudio"))
        try s.uninstall()
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.fileURL.path))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "# someone else's skill".write(to: s.fileURL, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try s.install())
        try s.uninstall()
        XCTAssertTrue(FileManager.default.fileExists(atPath: s.fileURL.path))
    }
}
