// Minimal XCTest-compatible shim used only when the toolchain has no XCTest (Command Line Tools). The same test
// sources compile unchanged against the real XCTest under Xcode. See docs/13 D-32.
@_exported import Foundation
import Synchronization

public struct XCTSkip: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String = "") { self.message = message }
    public var description: String { message }
}

public func XCTSkipUnless(_ condition: Bool, _ message: String = "") throws {
    if !condition { throw XCTSkip(message) }
}

public func XCTSkipIf(_ condition: Bool, _ message: String = "") throws {
    if condition { throw XCTSkip(message) }
}

public struct XCTFailure: Sendable {
    public let message: String
    public let file: String
    public let line: UInt
}

public enum XCTContext {
    nonisolated(unsafe) static var failures: [XCTFailure] = []
    static let lock = NSLock()

    public static func record(_ message: String, file: StaticString, line: UInt) {
        lock.lock()
        failures.append(XCTFailure(message: message, file: "\(file)", line: line))
        lock.unlock()
    }

    public static func drain() -> [XCTFailure] {
        lock.lock()
        defer { lock.unlock() }
        let out = failures
        failures.removeAll()
        return out
    }
}

open class XCTestCase: NSObject {
    public required override init() { super.init() }
    open func setUp() {}
    open func tearDown() {}
    open func setUpWithError() throws {}
    open func tearDownWithError() throws {}
    open func setUp() async throws {}
    open func tearDown() async throws {}

    /// Runs the XCTest lifecycle around one test body.
    public func runLifecycle(isolation: isolated (any Actor)? = #isolation, _ body: () async throws -> Void) async throws {
        let syncSetUp: () -> Void = setUp
        let syncTearDown: () -> Void = tearDown
        try await setUp()
        try setUpWithError()
        syncSetUp()
        defer {
            syncTearDown()
            try? tearDownWithError()
        }
        do {
            try await body()
        } catch {
            try? await tearDown()
            throw error
        }
        try await tearDown()
    }
}

public func XCTFail(_ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    XCTContext.record("XCTFail: \(message)", file: file, line: line)
}

public func XCTAssert(_ expression: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(try expression(), message(), file: file, line: line)
}

public func XCTAssertTrue(_ expression: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do {
        if try !expression() { XCTContext.record("XCTAssertTrue failed \(message())", file: file, line: line) }
    } catch {
        XCTContext.record("XCTAssertTrue threw \(error) \(message())", file: file, line: line)
    }
}

public func XCTAssertFalse(_ expression: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do {
        if try expression() { XCTContext.record("XCTAssertFalse failed \(message())", file: file, line: line) }
    } catch {
        XCTContext.record("XCTAssertFalse threw \(error) \(message())", file: file, line: line)
    }
}

public func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do {
        let x = try a()
        let y = try b()
        if x != y { XCTContext.record("XCTAssertEqual failed: (\(x)) is not equal to (\(y)) \(message())", file: file, line: line) }
    } catch {
        XCTContext.record("XCTAssertEqual threw \(error) \(message())", file: file, line: line)
    }
}

public func XCTAssertEqual<T: FloatingPoint>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, accuracy: T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do {
        let x = try a()
        let y = try b()
        if abs(x - y) > accuracy { XCTContext.record("XCTAssertEqual failed: (\(x)) is not equal to (\(y)) within \(accuracy) \(message())", file: file, line: line) }
    } catch {
        XCTContext.record("XCTAssertEqual threw \(error) \(message())", file: file, line: line)
    }
}

public func XCTAssertNotEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do {
        let x = try a()
        let y = try b()
        if x == y { XCTContext.record("XCTAssertNotEqual failed: (\(x)) equals (\(y)) \(message())", file: file, line: line) }
    } catch {
        XCTContext.record("XCTAssertNotEqual threw \(error) \(message())", file: file, line: line)
    }
}

public func XCTAssertNil(_ expression: @autoclosure () throws -> Any?, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do {
        if let v = try expression() { XCTContext.record("XCTAssertNil failed: \(v) \(message())", file: file, line: line) }
    } catch {
        XCTContext.record("XCTAssertNil threw \(error) \(message())", file: file, line: line)
    }
}

public func XCTAssertNotNil(_ expression: @autoclosure () throws -> Any?, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do {
        if try expression() == nil { XCTContext.record("XCTAssertNotNil failed \(message())", file: file, line: line) }
    } catch {
        XCTContext.record("XCTAssertNotNil threw \(error) \(message())", file: file, line: line)
    }
}

public func XCTAssertGreaterThan<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do {
        let x = try a(), y = try b()
        if !(x > y) { XCTContext.record("XCTAssertGreaterThan failed: \(x) is not greater than \(y) \(message())", file: file, line: line) }
    } catch { XCTContext.record("threw \(error)", file: file, line: line) }
}

public func XCTAssertGreaterThanOrEqual<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do {
        let x = try a(), y = try b()
        if !(x >= y) { XCTContext.record("XCTAssertGreaterThanOrEqual failed: \(x) < \(y) \(message())", file: file, line: line) }
    } catch { XCTContext.record("threw \(error)", file: file, line: line) }
}

public func XCTAssertLessThan<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do {
        let x = try a(), y = try b()
        if !(x < y) { XCTContext.record("XCTAssertLessThan failed: \(x) is not less than \(y) \(message())", file: file, line: line) }
    } catch { XCTContext.record("threw \(error)", file: file, line: line) }
}

public func XCTAssertLessThanOrEqual<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do {
        let x = try a(), y = try b()
        if !(x <= y) { XCTContext.record("XCTAssertLessThanOrEqual failed: \(x) > \(y) \(message())", file: file, line: line) }
    } catch { XCTContext.record("threw \(error)", file: file, line: line) }
}

public func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line, _ errorHandler: (any Error) -> Void = { _ in }) {
    do {
        _ = try expression()
        XCTContext.record("XCTAssertThrowsError failed: did not throw \(message())", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}

public func XCTAssertNoThrow<T>(_ expression: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { _ = try expression() } catch { XCTContext.record("XCTAssertNoThrow failed: \(error) \(message())", file: file, line: line) }
}

public struct XCTUnwrapError: Error {}

public func XCTUnwrap<T>(_ expression: @autoclosure () throws -> T?, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) throws -> T {
    if let v = try expression() { return v }
    XCTContext.record("XCTUnwrap failed: nil \(message())", file: file, line: line)
    throw XCTUnwrapError()
}

/// Registry the generated `Registry.swift` fills in; the runner iterates it.
public struct XCTestEntry: Sendable {
    public let suite: String
    public let name: String
    public let run: @Sendable () async throws -> Void
    public init(suite: String, name: String, run: @escaping @Sendable () async throws -> Void) {
        self.suite = suite
        self.name = name
        self.run = run
    }
}

public enum XCTestRunner {
    public static let perTestTimeout: TimeInterval = 30

    struct TimeoutError: Error {}

    /// Runs the body in a detached task and returns when it finishes or the timeout fires; a test that cannot be
    /// cancelled is abandoned (leaked) rather than joined, so one hang never stalls the whole suite.
    private final class Settle: Sendable {
        let flag = Mutex(false)
        func claim() -> Bool { flag.withLock { s in if s { return false }; s = true; return true } }
    }

    static func raceWithTimeout(_ body: @escaping @Sendable () async throws -> Void) async throws {
        let settled = Settle()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let work = Task.detached { [settled] in
                let result: Result<Void, any Error>
                do { try await body(); result = .success(()) } catch { result = .failure(error) }
                if settled.claim() { continuation.resume(with: result) }
            }
            Task.detached { [settled] in
                try? await Task.sleep(for: .seconds(perTestTimeout))
                if settled.claim() {
                    work.cancel()
                    continuation.resume(throwing: TimeoutError())
                }
            }
        }
    }

    public static func main(_ entries: [XCTestEntry]) async -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)
        let filter = CommandLine.arguments.dropFirst().first
        var passed = 0, failed = 0, skipped = 0
        let start = Date()
        for entry in entries {
            let fullName = "\(entry.suite)/\(entry.name)"
            if let filter, !fullName.contains(filter) { continue }
            let t0 = Date()
            do {
                try await raceWithTimeout(entry.run)
            } catch is TimeoutError {
                XCTContext.record("test timed out after \(Int(perTestTimeout)) s", file: #filePath, line: 0)
            } catch let skip as XCTSkip {
                skipped += 1
                print("SKIP \(fullName) (\(skip.message))")
                _ = XCTContext.drain()
                continue
            } catch {
                XCTContext.record("threw \(error)", file: #filePath, line: 0)
            }
            let failures = XCTContext.drain()
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            if failures.isEmpty {
                passed += 1
                print("PASS \(fullName) (\(ms) ms)")
            } else {
                failed += 1
                print("FAIL \(fullName) (\(ms) ms)")
                for f in failures { print("     \(f.file):\(f.line): \(f.message)") }
            }
        }
        print("\nExecuted \(passed + failed) tests, \(failed) failed, \(skipped) skipped in \(String(format: "%.1f", Date().timeIntervalSince(start))) s")
        return failed == 0 ? 0 : 1
    }
}
