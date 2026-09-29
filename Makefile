.PHONY: setup run project open test-core clean

# One-time: checks Xcode, installs xcodegen, creates the free signing certificate.
setup:
	./scripts/setup.sh

# Build, install to ~/Applications and launch.
run:
	./scripts/build-and-install.sh

# Generate Macky.xcodeproj (to work in Xcode).
project:
	xcodegen generate

open: project
	open Macky.xcodeproj

# Unit tests for the platform-independent logic.
test-core:
	cd Packages/MackyCore && swift test

clean:
	rm -rf build Macky.xcodeproj
