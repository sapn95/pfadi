#!/usr/bin/env bash
# Sign, notarise and staple build/Pfadi.app.
#
# Everything here needs an Apple Developer Program membership: a Developer ID
# Application certificate in the keychain, and credentials notarytool can use.
# Without those this script says so and stops, rather than producing something
# that looks signed and is not.
#
#   PFADI_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
#   PFADI_NOTARY_PROFILE=pfadi \
#     ./scripts/sign-and-notarise.sh
#
# The notary profile is made once with:
#   xcrun notarytool store-credentials pfadi \
#     --apple-id you@example.com --team-id TEAMID --password <app-specific>
set -euo pipefail

cd "$(dirname "$0")/.."

BUNDLE="build/Pfadi.app"
IDENTITY="${PFADI_SIGN_IDENTITY:-}"
PROFILE="${PFADI_NOTARY_PROFILE:-}"

if [ ! -d "$BUNDLE" ]; then
	echo "no $BUNDLE: run ./scripts/make-app.sh first" >&2
	exit 1
fi

if [ -z "$IDENTITY" ]; then
	echo "PFADI_SIGN_IDENTITY is not set." >&2
	echo "Available identities:" >&2
	security find-identity -v -p codesigning >&2 || true
	exit 1
fi

# --options runtime is the hardened runtime, which notarisation requires.
# --timestamp gets a trusted timestamp, without which the signature expires
# with the certificate rather than outliving it.
echo "==> signing"
codesign \
	--force \
	--sign "$IDENTITY" \
	--options runtime \
	--timestamp \
	--entitlements build/pfadi.entitlements \
	"$BUNDLE"

codesign --verify --deep --strict --verbose=2 "$BUNDLE"

if [ -z "$PROFILE" ]; then
	echo "==> signed, but PFADI_NOTARY_PROFILE is not set, so not notarised."
	echo "    It will run here. On anybody else's Mac Gatekeeper will refuse it."
	exit 0
fi

# Notarisation takes a zip or a disk image, never a bare bundle. ditto rather
# than zip: it is the only one that preserves the resource forks and the
# symlinks inside a bundle.
echo "==> notarising"
ARCHIVE="build/Pfadi.zip"
rm -f "$ARCHIVE"
/usr/bin/ditto -c -k --keepParent "$BUNDLE" "$ARCHIVE"

xcrun notarytool submit "$ARCHIVE" --keychain-profile "$PROFILE" --wait

# Stapling puts the notarisation ticket inside the bundle, so it opens on a
# machine that is offline. Without it Gatekeeper has to ask Apple every time.
echo "==> stapling"
xcrun stapler staple "$BUNDLE"
xcrun stapler validate "$BUNDLE"

echo "==> done: $BUNDLE is signed, notarised and stapled"
