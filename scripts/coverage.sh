#!/usr/bin/env bash
# Measures how much of PfadiCore the self-test actually runs, and fails when it
# drops below the floor.
#
# Not `swift test --enable-code-coverage`: the tests are a plain executable,
# because both XCTest and swift-testing live inside the full Xcode install and
# this project builds with the Command Line Tools. So the instrumentation is
# asked for directly and the profile is merged by hand, which is all
# `swift test` does anyway.
set -euo pipefail

cd "$(dirname "$0")/.."

FLOOR="${COVERAGE_FLOOR:-80}"
OUT=".build/coverage"

rm -rf "$OUT"
mkdir -p "$OUT"

swift build -c debug --product pfadi-selftest \
	-Xswiftc -profile-generate -Xswiftc -profile-coverage-mapping

BINARY="$(swift build -c debug --show-bin-path)/pfadi-selftest"
LLVM_PROFILE_FILE="$OUT/selftest.profraw" "$BINARY"

xcrun llvm-profdata merge -sparse "$OUT/selftest.profraw" -o "$OUT/selftest.profdata"

# Tests and build products excluded: a test file that runs itself proves
# nothing, and counting it inflates the number by exactly the amount that
# makes it useless.
IGNORE='(Tests|\.build)/'

echo
xcrun llvm-cov report "$BINARY" \
	-instr-profile="$OUT/selftest.profdata" \
	-ignore-filename-regex="$IGNORE"

# The line figure from the summary row. Regions and functions are reported
# above for anybody reading, but only one number can be a gate and lines is the
# one people mean.
SUMMARY="$(xcrun llvm-cov export "$BINARY" \
	-instr-profile="$OUT/selftest.profdata" \
	-ignore-filename-regex="$IGNORE" \
	--summary-only)"

COVERED="$(printf '%s' "$SUMMARY" | /usr/bin/python3 -c '
import json, sys
lines = json.load(sys.stdin)["data"][0]["totals"]["lines"]
print(f"{lines[chr(99)+chr(111)+chr(117)+chr(110)+chr(116)]}")' 2>/dev/null || true)"

PERCENT="$(printf '%s' "$SUMMARY" | /usr/bin/python3 -c '
import json, sys
print(round(json.load(sys.stdin)["data"][0]["totals"]["lines"]["percent"], 2))')"

echo
echo "PfadiCore line coverage: ${PERCENT}% of ${COVERED} lines, floor ${FLOOR}%"

# Compared as numbers rather than as text: "9.5" sorts above "80" as a string,
# and a gate that passes on a catastrophe is worse than no gate.
if ! /usr/bin/python3 -c "import sys; sys.exit(0 if float('$PERCENT') >= float('$FLOOR') else 1)"; then
	echo "below the floor" >&2
	exit 1
fi
echo "ok"
