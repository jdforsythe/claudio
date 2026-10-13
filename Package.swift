// swift-tools-version: 6.0
import Foundation
import PackageDescription

let strictConcurrency: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
]

// XCTest ships with Xcode, not with the Command Line Tools. With Xcode (or CLAUDIO_XCTEST=1) the suites are
// ordinary test targets run by `swift test`; otherwise the same sources compile against a small XCTest-compatible
// shim into the `claudio-tests` executable run by `swift run claudio-tests` (docs/13 D-32).
let xctestFramework = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks/XCTest.framework"
let useXCTest = Context.environment["CLAUDIO_XCTEST"] == "1"
    || (Context.environment["CLAUDIO_XCTEST"] != "0" && FileManager.default.fileExists(atPath: xctestFramework))

let supportTarget: Target = .target(
    name: "TestSupport",
    dependencies: ["ClaudioCore"],
    path: "Tests/TestSupport",
    resources: [.copy("../Fixtures")],
    swiftSettings: strictConcurrency
)

let testTargets: [Target] = useXCTest
    ? [
        supportTarget,
        .testTarget(name: "ClaudioControlProtocolTests", dependencies: ["ClaudioControlProtocol", "TestSupport"], path: "Tests/ClaudioControlProtocolTests"),
        .testTarget(name: "ClaudioCoreTests", dependencies: ["ClaudioCore", "TestSupport"], path: "Tests/ClaudioCoreTests"),
        .testTarget(name: "ClaudioBackendsTests", dependencies: ["ClaudioBackends", "TestSupport"], path: "Tests/ClaudioBackendsTests"),
        .testTarget(name: "ClaudioIntegrationTests", dependencies: ["ClaudioCore", "ClaudioBackends", "ClaudioControlProtocol", "TestSupport"], path: "Tests/ClaudioIntegrationTests"),
    ]
    : [
        supportTarget,
        // NonisolatedNonsendingByDefault lets the shim's lifecycle call the (non-Sendable) test case's async
        // setUp/tearDown on the caller's isolation, matching how XCTest itself runs them.
        .target(name: "XCTest", path: "Tests/XCTestShim",
                swiftSettings: strictConcurrency + [.enableUpcomingFeature("NonisolatedNonsendingByDefault")]),
        .executableTarget(
            name: "claudio-tests",
            dependencies: ["ClaudioControlProtocol", "ClaudioCore", "ClaudioBackends", "TestSupport", "XCTest"],
            path: "Tests",
            exclude: ["Fixtures", "TestSupport", "XCTestShim", "README.md"],
            swiftSettings: strictConcurrency + [.enableUpcomingFeature("NonisolatedNonsendingByDefault")]
        ),
    ]

let package = Package(
    name: "Claudio",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Claudio", targets: ["ClaudioApp"]),
        .executable(name: "claudio-cli", targets: ["ClaudioCLI"]),  // bundled as Contents/Helpers/claudio (D-30)
        .library(name: "ClaudioControlProtocol", targets: ["ClaudioControlProtocol"]),
        .library(name: "ClaudioCore", targets: ["ClaudioCore"]),
        .library(name: "ClaudioBackends", targets: ["ClaudioBackends"]),
    ],
    dependencies: [
        .package(path: "Vendor/KeyboardShortcuts"),
        .package(url: "https://github.com/apple/swift-argument-parser", exact: "1.5.1"),
    ],
    targets: [
        // Foundation-only wire types shared by app and CLI.
        .target(
            name: "ClaudioControlProtocol",
            path: "Sources/ClaudioControlProtocol",
            swiftSettings: strictConcurrency
        ),

        .target(
            name: "ClaudioCore",
            dependencies: ["ClaudioControlProtocol"],
            path: "Sources/ClaudioCore",
            swiftSettings: strictConcurrency,
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreServices"),
                .linkedFramework("NaturalLanguage"),
            ]
        ),

        .target(
            name: "ClaudioBackends",
            dependencies: ["ClaudioCore"],
            path: "Sources/ClaudioBackends",
            swiftSettings: strictConcurrency,
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("Security"),
                .linkedFramework("Network"),
            ]
        ),

        .executableTarget(
            name: "ClaudioApp",
            dependencies: [
                "ClaudioCore",
                "ClaudioBackends",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
            path: "Sources/ClaudioApp",
            resources: [
                .copy("Resources/sounds"),
            ],
            swiftSettings: strictConcurrency,
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ServiceManagement"),
            ]
        ),

        // Must stay tiny: no ClaudioCore, no AVFoundation, no AppKit.
        .executableTarget(
            name: "ClaudioCLI",
            dependencies: [
                "ClaudioControlProtocol",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/ClaudioCLI",
            swiftSettings: strictConcurrency
        ),

        // Tests (see below: appended depending on the toolchain)
    ] + testTargets,
    swiftLanguageModes: [.v6]
)
