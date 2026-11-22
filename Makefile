# Mantel build commands. Run from the repository root.
PROJECT := Mantel.xcodeproj
SCHEME  := Mantel
DERIVED := build
APP     := $(DERIVED)/Build/Products/Debug/Mantel.app
PACKAGE := Packages/NotchKit
# Every Swift package, tested in this order.
PACKAGES := Packages/NotchKit Packages/BlockKit

.PHONY: build test run quit clean

build: ## Build the app (Debug)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		-destination "platform=macOS,arch=arm64" -derivedDataPath $(DERIVED) -quiet build

# make test                                 every package in turn, then builds
#                                           the root manifest (the kit by URL)
# make test FILTER=NotchCoreTests            one target in Packages/NotchKit
# make test PKG=Packages/BlockKit [FILTER=X] one package, optionally filtered
test: ## Run the package unit tests. Scope with PKG=<package path> and FILTER=<target>
ifdef PKG
	swift test --package-path $(PKG) $(if $(FILTER),--filter $(FILTER),)
else ifdef FILTER
	swift test --package-path $(PACKAGE) --filter $(FILTER)
else
	@set -e; for p in $(PACKAGES); do \
		echo "== $$p"; swift test --package-path $$p; \
	done; \
	echo "== ."; swift build --package-path .
endif

run: build quit ## Build, then launch the app
	open $(APP)

quit: ## Quit the running app, if any
	-@pkill -x Mantel 2>/dev/null || true

clean:
	rm -rf $(DERIVED) .build $(addsuffix /.build,$(PACKAGES))
