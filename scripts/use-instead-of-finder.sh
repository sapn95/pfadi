#!/usr/bin/env bash
# Make pfadi the one you reach for instead of Finder.
#
# Three things it can do, and two it cannot. It says which is which rather than
# quietly doing half the job.
#
#   pfadi-instead-of-finder          # show what it would do
#   pfadi-instead-of-finder --apply  # do it
#   pfadi-instead-of-finder --undo   # put everything back
set -euo pipefail

BUNDLE="${PFADI_APP:-}"
if [ -z "$BUNDLE" ]; then
	for candidate in \
		"$(brew --prefix pfadi 2>/dev/null || true)/Pfadi.app" \
		"/Applications/Pfadi.app" \
		"$HOME/Applications/Pfadi.app" \
		"$(cd "$(dirname "$0")/.." && pwd)/build/Pfadi.app"; do
		if [ -d "$candidate" ]; then
			BUNDLE="$candidate"
			break
		fi
	done
fi

if [ ! -d "${BUNDLE:-}" ]; then
	echo "cannot find Pfadi.app. Set PFADI_APP to it and try again." >&2
	exit 1
fi

# The command rather than the bundle: it is what stays correct across an
# upgrade, because brew rewrites it to point at whatever it just installed.
COMMAND="$(command -v pfadi || echo "/usr/bin/open -a $BUNDLE")"

MODE="${1:---dry-run}"
MARKER_START="# >>> pfadi instead of finder >>>"
MARKER_END="# <<< pfadi instead of finder <<<"
LINK="$HOME/Applications/Pfadi.app"

shell_block() {
	cat <<-BLOCK
		$MARKER_START
		# \`open .\` and \`open <folder>\` go to pfadi. Everything else is untouched,
		# so \`open report.pdf\` still opens whatever owns a PDF.
		open() {
		  if [ \$# -eq 1 ] && [ -d "\$1" ]; then
		    command open -a "$BUNDLE" "\$1"
		  else
		    command open "\$@"
		  fi
		}
		$MARKER_END
	BLOCK
}

profile_for_shell() {
	case "$(basename "${SHELL:-/bin/zsh}")" in
		bash) echo "$HOME/.bash_profile" ;;
		*) echo "$HOME/.zshrc" ;;
	esac
}

PROFILE="$(profile_for_shell)"

# A tiny bundle in ~/Applications whose only job is to start the real one.
#
# A symlink here is not indexed: Spotlight indexes ~/Applications but not
# Homebrew's Cellar, and a link gives it nothing of its own to look at. A copy
# is indexed and then goes stale the next time brew upgrades the real thing,
# which is worse, because it keeps launching a version that is no longer there.
#
# A launcher is neither. It is found because it lives here, and it can never be
# out of date because it does not contain the application, only the command
# that starts whichever one is installed.
make_launcher() {
	rm -rf "$LINK"
	mkdir -p "$LINK/Contents/MacOS" "$LINK/Contents/Resources"

	printf '#!/bin/sh\nexec %s "$@"\n' "$COMMAND" >"$LINK/Contents/MacOS/launch"
	chmod +x "$LINK/Contents/MacOS/launch"

	if [ -f "$BUNDLE/Contents/Resources/Icon.icns" ]; then
		cp "$BUNDLE/Contents/Resources/Icon.icns" "$LINK/Contents/Resources/Icon.icns"
	fi

	cat >"$LINK/Contents/Info.plist" <<-PLIST
		<?xml version="1.0" encoding="UTF-8"?>
		<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
		<plist version="1.0">
		<dict>
			<key>CFBundleExecutable</key>
			<string>launch</string>
			<key>CFBundleIdentifier</key>
			<string>io.github.sapn95.pfadi.launcher</string>
			<key>CFBundleName</key>
			<string>pfadi</string>
			<key>CFBundleIconFile</key>
			<string>Icon</string>
			<key>CFBundlePackageType</key>
			<string>APPL</string>
			<key>LSUIElement</key>
			<true/>
		</dict>
		</plist>
	PLIST

	# Tell Launch Services about it now rather than whenever it notices.
	local lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
	[ -x "$lsregister" ] && "$lsregister" -f "$LINK" >/dev/null 2>&1
	return 0
}

report() {
	echo "pfadi:   $BUNDLE"
	echo "shell:   $PROFILE"
	echo
	echo "It will:"
	echo "  1. put a small launcher in ~/Applications, so Spotlight finds it"
	echo "  2. make \`open .\` in a terminal open pfadi instead of Finder"
	echo "  3. leave everything else alone"
	echo
	echo "It cannot:"
	echo "  - remove Finder from the Dock. macOS reserves that tile and there is"
	echo "    no supported way to give it up."
	echo "  - become the handler for folders system-wide. LaunchServices refuses"
	echo "    to reassign public.folder, which is why step 2 exists at all."
}

case "$MODE" in
	--apply)
		report
		echo
		mkdir -p "$HOME/Applications"
		make_launcher
		echo "==> put $LINK where Spotlight looks"

		if grep -qF "$MARKER_START" "$PROFILE" 2>/dev/null; then
			echo "==> $PROFILE already has the shell function"
		else
			printf '\n%s\n' "$(shell_block)" >>"$PROFILE"
			echo "==> added the shell function to $PROFILE"
		fi
		echo
		echo "Open a new terminal, or run: source $PROFILE"
		;;

	--undo)
		rm -f "$LINK"
		echo "==> removed $LINK"
		if grep -qF "$MARKER_START" "$PROFILE" 2>/dev/null; then
			# sed rather than a rewrite: the file is somebody's own and the
			# only part of it that is ours is between the two markers.
			/usr/bin/sed -i '' "/$MARKER_START/,/$MARKER_END/d" "$PROFILE"
			echo "==> removed the shell function from $PROFILE"
		else
			echo "==> $PROFILE had nothing of ours in it"
		fi
		;;

	*)
		report
		echo
		echo "Nothing has been changed. Run it again with --apply."
		;;
esac
