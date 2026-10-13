# 10 — Build, Lint and Release

Claudio is built entirely with the Swift Package Manager from the Command Line Tools. There is no Xcode project, no `.xcodeproj`, no storyboard and no asset catalog. The `.app` bundle is assembled by a shell script from SwiftPM's build products. Everything in this document runs on a machine with only `xcode-select --install` tools and Homebrew.

## 1. Prerequisites

| Tool | Version | Install | Purpose |
|------|---------|---------|---------|
| Command Line Tools | Swift 6.3 (`swift --version` prints `Apple Swift version 6.3`) | `xcode-select --install` | Compiler, SwiftPM, `codesign`, `lldb`, `llvm-cov`, `iconutil`, `sips` |
| Homebrew | current | brew.sh | Package manager |
| SwiftLint | 0.59.x pinned in `Brewfile` | `brew install swiftlint` | Linting |
| swift-format | 601.x pinned in `Brewfile` | `brew install swift-format` | Formatting (the Homebrew build is used even though the 6.3 toolchain ships `swift format`, so every machine and CI format identically) |
| create-dmg | not needed | — | `make dmg` uses `hdiutil` via `scripts/make-dmg.sh` |
| gh | optional | `brew install gh` | release job and local release publishing |

`Brewfile` at the repo root lists swiftlint, swift-format, create-dmg and gh. `make bootstrap` runs `brew bundle` and verifies the Swift version.

Xcode is not required. `xcodebuild`, `xctrace`, Instruments and SwiftUI previews are unavailable; document 11 §4 covers performance work without them. Two consequences surfaced during implementation: the `#Preview` macro cannot be expanded by the Command Line Tools (hence the vendored KeyboardShortcuts, D-29), and SwiftPM products that differ only in case collide on the default case-insensitive APFS volume (hence the `claudio-cli` product name, D-30).

## 2. `Package.swift`

```swift
// swift-tools-version: 6.0
import PackageDescription

let strictConcurrency: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableExperimentalFeature("StrictConcurrency=complete"),
]

let package = Package(
    name: "Claudio",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Claudio", targets: ["ClaudioApp"]),
        .executable(name: "claudio-cli", targets: ["ClaudioCLI"]),   // bundled as Contents/Helpers/claudio (D-30)
        .library(name: "ClaudioControlProtocol", targets: ["ClaudioControlProtocol"]),
        .library(name: "ClaudioCore", targets: ["ClaudioCore"]),
        .library(name: "ClaudioBackends", targets: ["ClaudioBackends"]),
    ],
    dependencies: [
        .package(path: "Vendor/KeyboardShortcuts"),   // vendored without #Preview blocks (D-29)
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
                .linkedFramework("CoreServices"),   // FSEvents
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
                .linkedFramework("Security"),       // Keychain
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
                .copy("Resources/sounds"),   // SwiftPM requires resources inside the target directory
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

        // Tests
        .testTarget(
            name: "ClaudioControlProtocolTests",
            dependencies: ["ClaudioControlProtocol"],
            path: "Tests/ClaudioControlProtocolTests"
        ),
        .testTarget(
            name: "ClaudioCoreTests",
            dependencies: ["ClaudioCore"],
            path: "Tests/ClaudioCoreTests",
            resources: [.copy("../Fixtures")]
        ),
        .testTarget(
            name: "ClaudioBackendsTests",
            dependencies: ["ClaudioBackends"],
            path: "Tests/ClaudioBackendsTests",
            resources: [.copy("Resources")]        // 1 s MP3 fixture, voices-list fixture
        ),
        .testTarget(
            name: "ClaudioIntegrationTests",
            dependencies: ["ClaudioCore", "ClaudioBackends", "ClaudioControlProtocol"],
            path: "Tests/ClaudioIntegrationTests",
            resources: [.copy("../Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
```

Notes:

- `resources: [.copy("../../Resources/sounds")]` places the chimes in the SwiftPM resource bundle `Claudio_ClaudioApp.bundle`, which the bundling script copies into `Contents/Resources`. Code loads them through `Bundle.module` (see §14 for the unbundled fallback).
- Dependencies are pinned with `exact:` and `Package.resolved` is committed. Updating a dependency is a deliberate commit.
- The CLI target's dependency list is enforced by `test_ControlProtocol_targetLinksFoundationOnly` (document 09 §3.13) and by the `otool` check in `scripts/make-app.sh`.

## 3. `Makefile`

```make
# Claudio — build, test, bundle, release. Requires only Command Line Tools + Homebrew.
SHELL := /bin/bash
.DEFAULT_GOAL := build

VERSION      := $(shell cat VERSION)
BUILD_NUMBER := $(shell git rev-list --count HEAD 2>/dev/null || echo 0)
GIT_SHA      := $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
CONFIG       ?= debug
BUILD_DIR    := .build
APP_DIR      := build
APP          := $(APP_DIR)/Claudio.app
INSTALL_DIR  ?= /Applications
BUNDLE_ID    := com.jdforsythe.claudio
SIGN_IDENTITY ?= -          # "-" = ad-hoc. Override: make app SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"

export CLAUDIO_VERSION=$(VERSION)
export CLAUDIO_BUILD=$(BUILD_NUMBER)
export CLAUDIO_SHA=$(GIT_SHA)

.PHONY: bootstrap build release test coverage lint format app install run logs clean dmg notarize fixtures bench version

bootstrap:            ## Install tooling via Homebrew and verify Swift
	brew bundle --no-upgrade
	@swift --version | grep -q "Swift version 6" || (echo "Swift 6 required" && exit 1)

build:                ## Debug build of all products
	swift build -c debug --product Claudio --product claudio

release:              ## Release build with debug symbols (dSYM kept for symbolication)
	swift build -c release --product Claudio --product claudio -Xswiftc -g
	mkdir -p $(APP_DIR)/dSYM
	dsymutil $(BUILD_DIR)/release/Claudio -o $(APP_DIR)/dSYM/Claudio.dSYM
	dsymutil $(BUILD_DIR)/release/claudio -o $(APP_DIR)/dSYM/claudio.dSYM

test: build           ## Run all tests (swift test with Xcode; shim runner with Command Line Tools, D-32)
	scripts/run-tests.sh

coverage:             ## Run tests with coverage and enforce thresholds
	CLAUDIO_BUILT_PRODUCTS=$(PWD)/$(BUILD_DIR)/debug swift test --parallel --enable-code-coverage
	scripts/check-coverage.sh

lint:                 ## SwiftLint + format check (no changes)
	swiftlint lint --strict --config .swiftlint.yml
	swift-format lint --strict --recursive --configuration .swift-format Sources Tests Package.swift

format:               ## Rewrite sources with swift-format
	swift-format format --in-place --recursive --configuration .swift-format Sources Tests Package.swift

app: CONFIG=release
app: release          ## Assemble build/Claudio.app from release products and sign
	scripts/make-app.sh $(CONFIG) "$(SIGN_IDENTITY)"

install: app          ## Install to /Applications, replacing a running instance
	-pkill -x Claudio || true
	rm -rf "$(INSTALL_DIR)/Claudio.app"
	cp -R "$(APP)" "$(INSTALL_DIR)/Claudio.app"
	open "$(INSTALL_DIR)/Claudio.app"

run: build            ## Run the debug app unbundled (hooks/login item unavailable; see docs/10 §13)
	CLAUDIO_UNBUNDLED=1 $(BUILD_DIR)/debug/Claudio

logs:                 ## Stream unified logs for the app
	log stream --predicate 'subsystem == "$(BUNDLE_ID)"' --level debug --style compact

clean:
	rm -rf $(BUILD_DIR) $(APP_DIR)

dmg: app              ## Build a drag-to-Applications DMG (scripts/make-dmg.sh, hdiutil only)
	SIGN_IDENTITY="$(SIGN_IDENTITY)" scripts/make-dmg.sh "$(APP_DIR)/Claudio-$(VERSION).dmg"

release-assets: dmg zip   ## DMG, zip and sha256 file for a GitHub release

notarize: app         ## Developer ID path only: notarize and staple (needs keychain profile "claudio-notary")
	scripts/notarize.sh "$(APP)" claudio-notary

fixtures:             ## Report fixture ages vs installed Claude Code
	scripts/fixture-report.sh

bench: build          ## Time-to-first-audio and gap report against the real default backend
	$(BUILD_DIR)/debug/claudio bench

version:
	@echo "$(VERSION) ($(BUILD_NUMBER)) $(GIT_SHA)"

help:
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-12s %s\n", $$1, $$2}'
```

The version environment variables are read by `Sources/ClaudioControlProtocol/BuildInfo.swift`, which is generated by `scripts/gen-buildinfo.sh` as a pre-build step invoked from both `build` and `release` (the generated file is git-ignored and regenerated on every build so `claudio version` always matches the tree).

## 4. `scripts/make-app.sh`

```bash
#!/usr/bin/env bash
# Assemble Claudio.app from SwiftPM products. Usage: make-app.sh <debug|release> <sign-identity>
set -euo pipefail

CONFIG="${1:-release}"
SIGN="${2:--}"                       # "-" = ad-hoc
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PRODUCTS="$ROOT/.build/$CONFIG"
OUT="$ROOT/build"
APP="$OUT/Claudio.app"
VERSION="$(cat "$ROOT/VERSION")"
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 0)"

echo "▸ assembling $APP ($CONFIG, version $VERSION build $BUILD_NUMBER)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Binaries
cp "$PRODUCTS/Claudio" "$APP/Contents/MacOS/Claudio"
mkdir -p "$APP/Contents/Helpers"
cp "$PRODUCTS/claudio-cli" "$APP/Contents/Helpers/claudio"      # D-30: case-insensitive APFS forbids claudio/Claudio in one dir
chmod 755 "$APP/Contents/MacOS/Claudio" "$APP/Contents/Helpers/claudio"

# Guard: the CLI must not link audio or UI frameworks (startup budget 20 ms).
if otool -L "$APP/Contents/Helpers/claudio" | grep -qE 'AVFoundation|AppKit|SwiftUI'; then
  echo "✗ claudio links a forbidden framework" >&2; exit 1
fi

# Info.plist with version substitution
sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD_NUMBER/g" \
    "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Icon, sounds, SwiftPM resource bundle
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
if [ -d "$PRODUCTS/Claudio_ClaudioApp.bundle" ]; then
  cp -R "$PRODUCTS/Claudio_ClaudioApp.bundle" "$APP/Contents/Resources/"
else
  echo "✗ resource bundle missing; run swift build first" >&2; exit 1
fi

# Sign. Inner binary first, then the bundle. Hardened runtime only for Developer ID.
ENT="$ROOT/Resources/Claudio.entitlements"
if [ "$SIGN" = "-" ]; then
  codesign --force --sign - --entitlements "$ENT" "$APP/Contents/Helpers/claudio"
  codesign --force --sign - --entitlements "$ENT" --identifier com.jdforsythe.claudio "$APP"
else
  codesign --force --sign "$SIGN" --options runtime --timestamp --entitlements "$ENT" "$APP/Contents/Helpers/claudio"
  codesign --force --sign "$SIGN" --options runtime --timestamp --entitlements "$ENT" "$APP"
fi
codesign --verify --deep --strict "$APP"
echo "✓ $APP"
```

The script is idempotent and leaves nothing outside `build/`. `codesign --verify --deep --strict` failing is a build failure.

## 5. `Resources/Info.plist`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>        <string>en</string>
    <key>CFBundleExecutable</key>               <string>Claudio</string>
    <key>CFBundleIconFile</key>                 <string>AppIcon</string>
    <key>CFBundleIdentifier</key>               <string>com.jdforsythe.claudio</string>
    <key>CFBundleInfoDictionaryVersion</key>    <string>6.0</string>
    <key>CFBundleName</key>                     <string>Claudio</string>
    <key>CFBundleDisplayName</key>              <string>Claudio</string>
    <key>CFBundlePackageType</key>              <string>APPL</string>
    <key>CFBundleShortVersionString</key>       <string>__VERSION__</string>
    <key>CFBundleVersion</key>                  <string>__BUILD__</string>
    <key>LSMinimumSystemVersion</key>           <string>15.0</string>
    <key>LSUIElement</key>                      <true/>
    <key>LSApplicationCategoryType</key>        <string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key>          <true/>
    <key>NSHumanReadableCopyright</key>         <string>Copyright © 2026 Jeremy Forsythe. MIT License.</string>
    <key>NSPrincipalClass</key>                 <string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key>   <false/>
    <key>NSSupportsSuddenTermination</key>      <false/>
</dict>
</plist>
```

Keys deliberately absent: `NSMicrophoneUsageDescription` (no audio input), `NSAppleEventsUsageDescription` (no AppleScript), `NSAppTransportSecurity` (every endpoint is HTTPS/WSS; ATS defaults apply). `LSUIElement` keeps the app out of the Dock and the Cmd-Tab switcher.

## 6. `Resources/Claudio.entitlements`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- No App Sandbox: see docs/10 §6 -->
    <key>com.apple.security.app-sandbox</key>               <false/>
    <!-- Hardened runtime (effective only with --options runtime / Developer ID) -->
    <key>com.apple.security.cs.allow-jit</key>              <false/>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key> <false/>
    <key>com.apple.security.cs.disable-library-validation</key>       <false/>
    <key>com.apple.security.network.client</key>            <true/>
    <key>com.apple.security.automation.apple-events</key>   <false/>
</dict>
</plist>
```

The app is **not sandboxed** because every one of its core functions crosses the sandbox boundary: it reads arbitrary files under `~/.claude/projects` and any user-configured extra root; it writes `~/.claude/settings.json` on request; it creates a Unix domain socket that another process (`claudio`, launched by Claude Code) connects to; and it spawns `claude agents --json`. A sandboxed build would need security-scoped bookmarks for each root, could not be reached by the hook receiver, and could not execute `claude`. Hardened runtime is enabled on the Developer ID path with no exceptions; the app has no JIT, loads no plugins and uses no unsigned libraries.

## 7. Icon

`Resources/AppIcon.icns` is generated from `Resources/AppIcon-1024.png` by `scripts/make-icon.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
SRC="${1:-Resources/AppIcon-1024.png}"
OUT="${2:-Resources/AppIcon.icns}"
TMP="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$TMP"
for s in 16 32 128 256 512; do
  sips -z $s $s "$SRC" --out "$TMP/icon_${s}x${s}.png" >/dev/null
  d=$((s*2))
  sips -z $d $d "$SRC" --out "$TMP/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$TMP" -o "$OUT"
echo "✓ $OUT"
```

The menu bar icon is not part of the icns; it is an SF Symbol rendered at runtime (document 07 §2).

## 8. Lint and format configuration

### `.swiftlint.yml`

```yaml
included:
  - Sources
  - Tests
  - Package.swift
excluded:
  - .build
  - build
  - Sources/ClaudioControlProtocol/BuildInfo.swift   # generated

analyzer_rules:
  - unused_declaration
  - unused_import

opt_in_rules:
  - array_init
  - closure_spacing
  - contains_over_filter_count
  - contains_over_first_not_nil
  - discouraged_optional_boolean
  - empty_count
  - empty_string
  - explicit_init
  - fallthrough
  - fatal_error_message
  - first_where
  - force_unwrapping
  - implicitly_unwrapped_optional
  - last_where
  - legacy_multiple
  - literal_expression_end_indentation
  - modifier_order
  - multiline_arguments
  - multiline_parameters
  - operator_usage_whitespace
  - overridden_super_call
  - prefer_self_type_over_type_of_self
  - redundant_nil_coalescing
  - sorted_first_last
  - toggle_bool
  - unneeded_parentheses_in_closure_argument
  - vertical_parameter_alignment_on_call
  - yoda_condition

disabled_rules:
  - todo                    # TODOs are tracked in issues, not blocked by lint
  - trailing_comma          # swift-format owns this
  - opening_brace           # swift-format owns this
  - line_length             # configured below as warning only

line_length:
  warning: 120
  error: 160
  ignores_urls: true
  ignores_comments: true

identifier_name:
  min_length: 2
  excluded: [id, x, y, i, j, k, db, ok, v]

type_body_length:
  warning: 400
  error: 600

file_length:
  warning: 600
  error: 900

function_body_length:
  warning: 60
  error: 100

cyclomatic_complexity:
  warning: 12
  error: 20

force_unwrapping:
  severity: error

custom_rules:
  no_print:
    name: "No print in library code"
    regex: '^\s*print\('
    included: "Sources/(ClaudioCore|ClaudioBackends|ClaudioApp)/.*\\.swift"
    message: "Use Log.<category> instead of print"
    severity: error
  no_sleep_in_tests:
    name: "No sleeps in tests"
    regex: '(Task\.sleep|usleep|sleep\(|asyncAfter)'
    included: "Tests/.*\\.swift"
    message: "Use TestClock.advance(by:)"
    severity: error
```

### `.swift-format`

```json
{
  "version": 1,
  "lineLength": 120,
  "indentation": { "spaces": 4 },
  "tabWidth": 4,
  "maximumBlankLines": 1,
  "respectsExistingLineBreaks": true,
  "lineBreakBeforeControlFlowKeywords": false,
  "lineBreakBeforeEachArgument": false,
  "lineBreakBeforeEachGenericRequirement": false,
  "prioritizeKeepingFunctionOutputTogether": true,
  "indentConditionalCompilationBlocks": false,
  "multiElementCollectionTrailingCommas": true,
  "rules": {
    "AllPublicDeclarationsHaveDocumentation": false,
    "AlwaysUseLowerCamelCase": true,
    "AmbiguousTrailingClosureOverload": true,
    "DoNotUseSemicolons": true,
    "DontRepeatTypeInStaticProperties": true,
    "FileScopedDeclarationPrivacy": true,
    "FullyIndirectEnum": true,
    "GroupNumericLiterals": true,
    "NeverForceUnwrap": false,
    "NeverUseForceTry": true,
    "NeverUseImplicitlyUnwrappedOptionals": true,
    "NoAccessLevelOnExtensionDeclaration": true,
    "NoBlockComments": true,
    "NoCasesWithOnlyFallthrough": true,
    "NoEmptyTrailingClosureParentheses": true,
    "NoLabelsInCasePatterns": true,
    "NoLeadingUnderscores": false,
    "NoParensAroundConditions": true,
    "NoVoidReturnOnFunctionSignature": true,
    "OneCasePerLine": true,
    "OneVariableDeclarationPerLine": true,
    "OnlyOneTrailingClosureArgument": true,
    "OrderedImports": true,
    "ReturnVoidInsteadOfEmptyTuple": true,
    "UseEarlyExits": true,
    "UseLetInEveryBoundCaseVariable": true,
    "UseShorthandTypeNames": true,
    "UseSingleLinePropertyGetter": true,
    "UseSynthesizedInitializer": true,
    "UseTripleSlashForDocumentationComments": true,
    "UseWhereClausesInForLoops": true,
    "ValidateDocumentationComments": true
  }
}
```

### Pre-commit hook

`scripts/pre-commit` is installed by `make bootstrap` via `ln -sf ../../scripts/pre-commit .git/hooks/pre-commit`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
FILES=$(git diff --cached --name-only --diff-filter=ACM -- '*.swift' | grep -v BuildInfo.swift || true)
[ -z "$FILES" ] && exit 0
swift-format format --in-place --configuration .swift-format $FILES
swiftlint lint --strict --quiet --config .swiftlint.yml -- $FILES
git add $FILES
```

## 9. CI — `.github/workflows/ci.yml`

```yaml
name: CI

on:
  push:
    branches: [main]
    tags: ['v*']
  pull_request:

concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true

jobs:
  build-test:
    name: Lint, test, bundle
    runs-on: macos-15
    timeout-minutes: 40
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }          # git rev-list --count needs history

      - name: Select toolchain
        run: |
          sudo xcode-select -s /Applications/Xcode_16.4.app || true
          swift --version
          swift --version | grep -q "Swift version 6" || { echo "Swift 6 required"; exit 1; }

      - name: Install tools
        run: brew bundle --no-upgrade

      - name: Cache SwiftPM
        uses: actions/cache@v4
        with:
          path: |
            .build
            ~/Library/Caches/org.swift.swiftpm
          key: spm-${{ runner.os }}-${{ hashFiles('Package.resolved') }}-${{ hashFiles('Package.swift') }}
          restore-keys: spm-${{ runner.os }}-

      - name: Lint
        run: make lint

      - name: Test with coverage
        run: make coverage
        env:
          CLAUDIO_LIVE_TESTS: "0"

      - name: Upload coverage report
        uses: actions/upload-artifact@v4
        with: { name: coverage, path: build/coverage.txt }

      - name: Bundle app (ad-hoc signed)
        run: make app

      - name: Zip app
        run: ditto -c -k --keepParent build/Claudio.app build/Claudio.zip

      - name: Upload app artifact
        uses: actions/upload-artifact@v4
        with: { name: Claudio.app, path: build/Claudio.zip }

      - name: Upload dSYMs
        uses: actions/upload-artifact@v4
        with: { name: dSYM, path: build/dSYM }

  release:
    name: GitHub release
    needs: build-test
    if: startsWith(github.ref, 'refs/tags/v')
    runs-on: macos-15
    permissions: { contents: write }
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - uses: actions/download-artifact@v4
        with: { name: Claudio.app, path: build }
      - uses: actions/download-artifact@v4
        with: { name: dSYM, path: build/dSYM }
      - name: Verify tag matches VERSION
        run: |
          test "v$(cat VERSION)" = "${GITHUB_REF_NAME}" || { echo "VERSION file ($(cat VERSION)) != tag ($GITHUB_REF_NAME)"; exit 1; }
      - name: Package
        run: |
          V=$(cat VERSION)
          mv build/Claudio.zip "build/Claudio-$V.zip"
          ditto -c -k build/dSYM "build/Claudio-$V-dSYM.zip"
          (cd build && shasum -a 256 "Claudio-$V.zip" "Claudio-$V-dSYM.zip" > "Claudio-$V.sha256")
      - name: Create release
        env: { GH_TOKEN: '${{ github.token }}' }
        run: |
          V=$(cat VERSION)
          gh release create "v$V" \
            --title "Claudio $V" \
            --notes-file CHANGELOG.md \
            "build/Claudio-$V.zip" "build/Claudio-$V-dSYM.zip" "build/Claudio-$V.sha256"
```

The GitHub `macos-15` runner ships Xcode, which is fine: SwiftPM behaves identically whether the toolchain comes from Xcode or Command Line Tools. The build never invokes `xcodebuild`, so the pipeline is the same one a developer runs locally. CI builds are ad-hoc signed; users of CI artifacts follow the Gatekeeper note in §14.

## 10. Versioning

- Semantic versioning. The single source of truth is the `VERSION` file (`0.1.0`). `CFBundleShortVersionString` is substituted from it.
- `CFBundleVersion` is `git rev-list --count HEAD`, monotonically increasing, so Sparkle-style comparisons and macOS "which is newer" checks work without manual bumps.
- `claudio version` prints `Claudio 0.1.0 (412) a1b2c3d` from `BuildInfo` (generated at build time: `version`, `build`, `sha`, `date`).
- A release is: update `VERSION` and `CHANGELOG.md` in one commit titled `release: vX.Y.Z`, tag `vX.Y.Z`, push the tag. CI verifies tag and file agree.
- `AppSettings` and the JSON stores carry their own schema versions independent of the app version (document 08 §12).

## 11. Developer ID signing and notarization

Ad-hoc signing (`--sign -`) is the default and sufficient for the developer's own Mac: SMAppService accepts an ad-hoc signed app in `/Applications` as a login item, and hooks run from the bundle path without restriction. Distribution to other Macs without Gatekeeper warnings requires a Developer ID.

One-time setup:

```
# Create and store a notarization profile (App Store Connect API key or Apple ID app-specific password)
xcrun notarytool store-credentials claudio-notary --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
security find-identity -v -p codesigning     # confirm "Developer ID Application: Name (TEAMID)"
```

Release:

```
make app SIGN_IDENTITY="Developer ID Application: Jeremy Forsythe (TEAMID)"
make notarize
```

`scripts/notarize.sh <app> <profile>`:

```bash
#!/usr/bin/env bash
set -euo pipefail
APP="$1"; PROFILE="$2"
ZIP="${APP%.app}-notary.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose=2 "$APP"
rm -f "$ZIP"
echo "✓ notarized and stapled: $APP"
```

What changes in `make-app.sh` on this path: `--options runtime --timestamp` are added (hardened runtime, secure timestamp), which the script already does when the identity is not `-`. The entitlements file is unchanged. `spctl --assess` must print `accepted`.

## 12. Homebrew cask (later)

```ruby
cask "claudio" do
  version "0.1.0"
  sha256 "<sha256 of Claudio-0.1.0.zip>"
  url "https://github.com/jdforsythe/claudio/releases/download/v#{version}/Claudio-#{version}.zip"
  name "Claudio"
  desc "Reads Claude Code sessions aloud from the menu bar"
  homepage "https://github.com/jdforsythe/claudio"
  depends_on macos: ">= :sequoia"
  app "Claudio.app"
  binary "#{appdir}/Claudio.app/Contents/MacOS/claudio"
  zap trash: [
    "~/Library/Application Support/Claudio",
    "~/Library/Preferences/com.jdforsythe.claudio.plist",
    "~/Library/Logs/Claudio",
  ]
end
```

Published via a `homebrew-claudio` tap once a Developer ID build exists; Homebrew casks of unsigned apps generate Gatekeeper friction.

## 13. Local development loop

Typical cycle:

```
make install && make logs
```

`make install` takes a release build, bundles, signs ad-hoc, kills the running instance, copies to `/Applications`, and relaunches. On an M-series Mac an incremental release build of a one-file change takes 10–25 s; a clean release build about 2–3 minutes; a clean debug build about 60–90 s. `make logs` streams the unified log for the subsystem.

Faster iteration on core logic: `swift test --filter TurnAssemblerTests` runs in a few seconds and needs no bundle.

Running unbundled (`make run`) launches `.build/debug/Claudio` directly with `CLAUDIO_UNBUNDLED=1`. In this mode:

- The menu bar, popover, HUD, settings, playback and all backends work.
- `Bundle.module` resolves to `.build/debug/Claudio_ClaudioApp.bundle` so sounds load.
- `SMAppService` registration is unavailable (not in a bundle); the Launch at Login toggle is disabled with the help text "Install the app to enable".
- Hook installation is refused with "Install the app to enable hooks" because the hook command path must be stable.
- KeyboardShortcuts needs a bundle identifier (§14).

Debugging with `lldb` from the Command Line Tools:

```
lldb .build/debug/Claudio -- 
(lldb) env CLAUDIO_UNBUNDLED=1
(lldb) breakpoint set --name "Arbiter.activate(_:)"
(lldb) run
```

Attach to the installed app: `lldb -n Claudio`. Swift REPL-style expression evaluation works for core types. For the CLI: `lldb .build/debug/claudio -- status --json`.

## 14. Troubleshooting builds

**`Bundle.module` crashes when running unbundled.** SwiftPM's generated `Bundle.module` accessor looks for `Claudio_ClaudioApp.bundle` next to the executable, then in the main bundle's Resources. Both locations are covered by `make run` and `make-app.sh` respectively. If a custom launch path breaks it, `Resources.swift` falls back to `Bundle.main.url(forResource:withExtension:)` and finally logs `ui: chime resource missing` and plays no chime rather than crashing.

**KeyboardShortcuts asserts "bundle identifier is nil" under `swift run` / `make run`.** The library stores shortcuts in UserDefaults keyed by bundle identifier. Unbundled binaries have none. `ClaudioApp.swift` detects `Bundle.main.bundleIdentifier == nil` and, when `CLAUDIO_UNBUNDLED=1`, calls `UserDefaults.standard.addSuite(named: "com.jdforsythe.claudio")` and sets `KeyboardShortcuts.userDefaults = UserDefaults(suiteName: "com.jdforsythe.claudio")!` before any shortcut is registered. Hotkeys then behave identically to the bundled app.

**Resource bundle missing in `make app`.** Happens when `swift build` was run with `--product claudio` only. Always build both products; the Makefile does.

**`codesign` fails with "resource fork, Finder information, or similar detritus not allowed".** Run `xattr -cr build/Claudio.app` before signing; `make-app.sh` does this automatically when the error is detected.

**`codesign --verify --deep --strict` fails after copying the app.** Copy with `cp -R` or `ditto`, not Finder drag from a network share; and never modify files inside the bundle after signing.

**Gatekeeper refuses an ad-hoc build on another Mac** ("Claudio cannot be opened because the developer cannot be verified"). Right-click → Open once, or:

```
xattr -dr com.apple.quarantine /Applications/Claudio.app
```

This is expected for ad-hoc builds and is the reason the Developer ID path (§11) exists.

**Strict concurrency errors in AVFoundation callbacks.** `PlaybackEngine` is the only place `@unchecked Sendable` is permitted (document 02 §6). Elsewhere, wrap non-Sendable Apple objects in an actor or hop with `MainActor.assumeIsolated` only where the API documents main-thread delivery.

**Slow incremental builds.** Check that `.build` is not on a path that Spotlight indexes (`mdutil -s .`), and that `swift-format` isn't being run over `.build` (it is excluded in the Makefile invocations).

**`swift test` cannot find fixtures.** Fixtures are copied via `resources: [.copy("../Fixtures")]`; access them with `Bundle.module.url(forResource: "Fixtures/transcripts/<name>/session", withExtension: "jsonl")`. Adding a fixture does not require touching `Package.swift`.
