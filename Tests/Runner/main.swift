import ClaudioCore
import Foundation
import XCTest

if let path = ProcessInfo.processInfo.environment["CLAUDIO_TEST_LOG"] {
    Log.fileSink.configure(url: URL(fileURLWithPath: path), threshold: .debug)
}

let code = await XCTestRunner.main(allTests)
exit(code)
