# Uses the Xcode app even when xcode-select points at the Command Line Tools.
export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

.PHONY: project open test test-live build-ios build-mac clean

project:            ## Generate Ivynote.xcodeproj from project.yml
	xcodegen generate

open: project       ## Generate and open in Xcode
	open Ivynote.xcodeproj

test:               ## IvynoteKit unit tests (no simulator needed)
	cd IvynoteKit && swift test

test-live:          ## Also run against a disposable server: make test-live SERVER=http://127.0.0.1:18080
	cd IvynoteKit && IVY_TEST_SERVER=$(SERVER) swift test

build-ios: project  ## Compile for the iOS Simulator (unsigned)
	xcodebuild -project Ivynote.xcodeproj -scheme Ivynote -destination 'generic/platform=iOS Simulator' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build

build-mac: project  ## Compile for macOS (unsigned)
	xcodebuild -project Ivynote.xcodeproj -scheme Ivynote -destination 'platform=macOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build

clean:
	rm -rf build IvynoteKit/.build Ivynote.xcodeproj
