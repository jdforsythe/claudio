Vendored from https://github.com/sindresorhus/KeyboardShortcuts at 2.3.0 (MIT license, see LICENSE).
Changes: (1) `String.localized` in `Utilities.swift` locates the resource bundle in the host app's `Contents/Resources` instead of `Bundle.module`, whose generated accessor crashes on machines other than the build machine; (2) the three `#Preview` blocks at the end of `Sources/KeyboardShortcuts/Recorder.swift` are removed,
because the SwiftUI Previews macro plugin is not available in the Command Line Tools toolchain.
To update: copy a new release's `Sources/` here and re-apply the same removal.
