#!/usr/bin/env bash
# The committed icon is still what the code draws.
#
# assets/Icon.icns is committed so that `brew install` does not have to render
# it: doing that put AppKit and iconutil in the install path, and under
# Homebrew's build environment iconutil rejected the iconset the same script
# produces correctly everywhere else.
#
# Committed art drifts from the code that made it, which is the reason it was
# generated at build time in the first place. So it is regenerated here and
# compared byte for byte. The renderer is deterministic: the same source gives
# the same file, which is what makes this a check rather than a coin toss.
set -euo pipefail

cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swift scripts/make-icon.swift "$WORK" >/dev/null

if cmp -s "$WORK/Icon.icns" assets/Icon.icns; then
	echo "the committed icon is what the code draws"
	exit 0
fi

echo "assets/Icon.icns is not what scripts/make-icon.swift draws." >&2
echo "Regenerate it with: swift scripts/make-icon.swift assets" >&2
exit 1
