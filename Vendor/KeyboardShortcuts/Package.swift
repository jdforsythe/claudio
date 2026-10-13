// swift-tools-version:5.9
// Vendored copy of sindresorhus/KeyboardShortcuts 2.3.0 (MIT) with `#Preview` blocks removed so the package
// builds with Command Line Tools only (the Previews macro plugin ships only with Xcode). See docs/13 D-29.
import PackageDescription

let package = Package(
    name: "KeyboardShortcuts",
    defaultLocalization: "en",
    platforms: [.macOS(.v10_15)],
    products: [.library(name: "KeyboardShortcuts", targets: ["KeyboardShortcuts"])],
    targets: [.target(name: "KeyboardShortcuts")]
)
