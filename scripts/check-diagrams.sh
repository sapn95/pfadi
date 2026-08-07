#!/usr/bin/env bash
# Every Mermaid diagram in the README has to be a diagram, not a paragraph
# that looks like one.
#
# GitHub renders ```mermaid fenced blocks itself, so the diagrams live in the
# README rather than as committed .svg files beside a .mmd source. That is a
# deliberate departure from the house standard, which requires the rendered SVG
# because Bitbucket Server cannot render Mermaid at all. On GitHub the SVG is a
# second copy of the same picture with nothing keeping the two in step.
#
# What the SVG did buy was proof that the source parses. This buys the same
# thing by handing each block to the real renderer and throwing the output
# away.
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v mmdc >/dev/null 2>&1; then
	echo "mmdc is not installed: brew install mermaid-cli" >&2
	exit 1
fi

# mermaid-cli renders in a headless browser and does not ship one. Rather than
# downloading a second Chromium into a cache directory, it is pointed at
# whichever browser is already here. A CI runner has Chrome; a Mac usually has
# something.
if [ -z "${PUPPETEER_EXECUTABLE_PATH:-}" ]; then
	for browser in \
		"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
		"/Applications/Chromium.app/Contents/MacOS/Chromium" \
		"/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"; do
		if [ -x "$browser" ]; then
			export PUPPETEER_EXECUTABLE_PATH="$browser"
			break
		fi
	done
fi
if [ -z "${PUPPETEER_EXECUTABLE_PATH:-}" ]; then
	echo "no browser for mermaid-cli to render in." >&2
	echo "Set PUPPETEER_EXECUTABLE_PATH, or install one." >&2
	exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Split the README on the fences. awk rather than a regex over the whole file,
# because a diagram containing the word "mermaid" is not a fence.
/usr/bin/awk -v out="$work" '
  /^```mermaid$/ { inside = 1; count++; next }
  /^```$/        { inside = 0; next }
  inside         { print > (out "/diagram-" count ".mmd") }
' README.md

found=0
for source in "$work"/*.mmd; do
	[ -e "$source" ] || break
	found=$((found + 1))
	if ! mmdc --quiet -i "$source" -o "$source.svg" >/dev/null 2>"$source.err"; then
		echo "$(basename "$source" .mmd) does not render:" >&2
		cat "$source.err" >&2
		echo "--- the source ---" >&2
		cat "$source" >&2
		exit 1
	fi
done

if [ "$found" -eq 0 ]; then
	echo "no mermaid blocks found in README.md" >&2
	exit 1
fi

echo "$found diagrams render"
