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
# "-" = ad-hoc. Override: make app SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"
SIGN_IDENTITY ?= -

export CLAUDIO_VERSION=$(VERSION)
export CLAUDIO_BUILD=$(BUILD_NUMBER)
export CLAUDIO_SHA=$(GIT_SHA)

.PHONY: bootstrap buildinfo build release test coverage lint format app install run logs clean dmg zip release-assets notarize fixtures bench version help

bootstrap:            ## Install tooling via Homebrew and verify Swift
	brew bundle --no-upgrade
	@swift --version | grep -q "Swift version 6" || (echo "Swift 6 required" && exit 1)
	ln -sf ../../scripts/pre-commit .git/hooks/pre-commit

buildinfo:            ## Regenerate BuildInfo.swift from VERSION and git
	scripts/gen-buildinfo.sh

build: buildinfo      ## Debug build of all products (the CLI product is claudio-cli; see docs/13 D-30)
	swift build -c debug --product Claudio
	swift build -c debug --product claudio-cli

release: buildinfo    ## Release build with debug symbols (dSYM kept for symbolication)
	swift build -c release --product Claudio -Xswiftc -g
	swift build -c release --product claudio-cli -Xswiftc -g
	mkdir -p $(APP_DIR)/dSYM
	dsymutil $(BUILD_DIR)/release/Claudio -o $(APP_DIR)/dSYM/Claudio.dSYM
	dsymutil $(BUILD_DIR)/release/claudio-cli -o $(APP_DIR)/dSYM/claudio.dSYM

test: build           ## Run all tests in parallel; built-product tests enabled
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

dmg: app              ## Build a drag-to-Applications DMG (hdiutil only; no extra tools)
	SIGN_IDENTITY="$(SIGN_IDENTITY)" scripts/make-dmg.sh "$(APP_DIR)/Claudio-$(VERSION).dmg"

zip: app              ## Zip the app for a GitHub release
	rm -f "$(APP_DIR)/Claudio-$(VERSION).zip"
	ditto -c -k --keepParent "$(APP)" "$(APP_DIR)/Claudio-$(VERSION).zip"

release-assets: dmg zip   ## DMG, zip and sha256 file for a release
	(cd $(APP_DIR) && shasum -a 256 "Claudio-$(VERSION).dmg" "Claudio-$(VERSION).zip" > "Claudio-$(VERSION).sha256")
	@ls -la $(APP_DIR)/Claudio-$(VERSION).*

notarize: app         ## Developer ID path only: notarize and staple (needs keychain profile "claudio-notary")
	scripts/notarize.sh "$(APP)" claudio-notary

fixtures:             ## Report fixture ages vs installed Claude Code
	scripts/fixture-report.sh

bench: build          ## Time-to-first-audio and gap report against the real default backend
	$(BUILD_DIR)/debug/claudio-cli bench

version:
	@echo "$(VERSION) ($(BUILD_NUMBER)) $(GIT_SHA)"

help:
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-12s %s\n", $$1, $$2}'
