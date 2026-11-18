# TopNotch build commands. Run from the repository root.
PROJECT := TopNotch.xcodeproj
SCHEME  := TopNotch
DERIVED := build
APP     := $(DERIVED)/Build/Products/Debug/TopNotch.app
PACKAGE := Packages/NotchKit

.PHONY: build test run quit clean

build: ## Build the app (Debug)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		-destination "platform=macOS,arch=arm64" -derivedDataPath $(DERIVED) -quiet build

test: ## Run the package unit tests. Scope with FILTER=NotchCoreTests
	swift test --package-path $(PACKAGE) $(if $(FILTER),--filter $(FILTER),)

run: build quit ## Build, then launch the app
	open $(APP)

quit: ## Quit the running app, if any
	-@pkill -x TopNotch 2>/dev/null || true

clean:
	rm -rf $(DERIVED) $(PACKAGE)/.build
