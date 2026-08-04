#!/usr/bin/env bash
# Wrap the built executable in a .app bundle.
#
# SwiftPM only produces a bare binary. macOS needs a bundle before it will give
# a process a Dock icon, a menu bar, or a place to hang an Info.plist.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIGURATION="${1:-release}"
BUNDLE="build/Pfadi.app"
# The VERSION file is the single source of truth: a release tag is checked
# against it, and a source tarball has no git history to describe.
VERSION="$(tr -d '[:space:]' < VERSION)"

swift build -c "$CONFIGURATION"
BINARY="$(swift build -c "$CONFIGURATION" --show-bin-path)/pfadi"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BINARY" "$BUNDLE/Contents/MacOS/pfadi"

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>pfadi</string>
	<key>CFBundleIdentifier</key>
	<string>io.github.sapn95.pfadi</string>
	<key>CFBundleName</key>
	<string>pfadi</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION}</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSSupportsAutomaticTermination</key>
	<false/>
</dict>
</plist>
PLIST

# Ad-hoc signing is enough to run it locally. Anything shipped to another Mac
# needs a Developer ID and notarisation, which this project does not have yet.
codesign --force --sign - "$BUNDLE" >/dev/null 2>&1 ||
	echo "note: could not ad-hoc sign, the app will still run locally"

echo "built $BUNDLE ($VERSION)"
