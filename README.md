# pfadi

<img src="assets/logo.svg" alt="The pfadi mark: a forward slash next to a text cursor"
     width="112" align="right">

A small macOS file browser with the one thing macOS has never had: an address
bar you can click into and type, with tab completion.

> **Work in progress.** It browses, and it can now make a folder, rename one
> thing and trash one thing, each of which ⌘Z takes back. It cannot copy or
> move anything yet. Keep Finder around.

## The problem

Finder gives you three ways to see where you are and none to say where you want
to go.

| What it offers | What it does not |
| --- | --- |
| A path bar at the bottom | Read-only. Double-click a segment to jump, but you cannot type in it. |
| A path menu behind ⌘-clicking the window title | A menu of ancestors. No input, no completion. |
| Go to Folder, ⇧⌘G | A modal sheet on top of the window. A detour, not an address bar. |

Every third-party file manager that does have a typable address bar is either
paid ([QSpace], [Path Finder], Commander One), dual-pane by conviction
([Nimble Commander]), or not written for macOS at all (muCommander, Double
Commander).

So: one pane, one path field, keyboard first.

## What it does

```text
⇧⌘G     jump to the path field
tab     walk to the next match, ⇧tab back, escape to undo
return  accept the match, then return again to go there
a-z     type-ahead: jump to the row whose name starts like that
space   Quick Look, and again to close it
⌘↑      enclosing folder
⇧⌘H     home
⇧⌘.     show hidden files
⌘R      refresh
⌘D      add this folder to the sidebar, or take it back out
⇧⌘N     new folder, with the cursor already in its name
F2      rename the selection
⌘⌫      move the selection to the trash
⌘Z      undo any of those three
⇧⌘C     copy the path of the selection
⌃⌘T     open a terminal in this folder
⇧⌘R     reveal the selection in Finder
```

Completion works the way a shell does it, and stays on the keyboard. Tab puts
the first match in the field, tab again replaces it with the next, shift-tab
goes back, and both directions wrap. The status line counts along: `2 of 7`.
Escape puts back exactly what you typed.

Return has two jobs, in the order you need them. The first one accepts the
match that is showing and leaves you in the field, so the next tab can carry
straight on into the folder you just chose. The second one goes there. Typing a
path yourself and pressing return once still just goes, because there is no
match sitting there to accept.

Directories keep their trailing slash. Dotfiles stay out of the matches until
you type a dot, whether or not hidden files are shown. When nothing matches, it
beeps and says so, rather than leaving you wondering whether the key registered.

A path can be absolute, relative to where you are, or start with `~`. Pointing
it at a file rather than a folder hands the file to whichever application owns
it.

Type-ahead follows the rules every list on this platform uses. A single letter
cycles through the entries starting with it, two or more letters are a
refinement that lands on the same row every time, and the prefix expires a
second after the last keystroke. Case and diacritics are ignored, so `uber`
finds `Über`.

The listing is watched, so anything the shell or a build tool does to the
folder shows up on its own. The selected row survives the refresh, because
being thrown back to the top every time a build writes a file is worse than a
stale list.

Click a column header to sort by it, click again to turn it around. Folders
stay above files whichever column and whichever direction, because a folder has
no size to sort by and having them scatter through the list helps nobody.

Space opens Quick Look and space closes it. It stays open while you walk the
list with the arrow keys, which is the point of having it.

The three operations that change anything are all reversible, which is why they
are the ones that exist. ⌘Z puts back a trashed file, undoes a rename, and
trashes a folder that was just created. A rename that would land on a file that
already exists is refused rather than replacing it.

The sidebar holds the folders you keep going back to. ⌘D puts the one you are
in there and ⌘D takes it out again, right-click removes a row, and a favourite
whose folder has been deleted or unmounted is skipped rather than drawn as a
row that beeps when clicked. It stays in the list, in case the volume comes
back.

What you set stays set. The favourites, the sort order, showing hidden files,
the column widths, the window size and the folder you were last in all come
back on the next launch, because a preference you have to make again every
morning is not a preference.

`⌃⌘T` opens whichever terminal is installed, preferring Ghostty, kitty, iTerm2,
Warp and Alacritty over Terminal.app in that order. Terminal.app is last
because it is always present, so ranking it anywhere else would mean nobody's
actual terminal ever wins.

From a shell:

```bash
open -a build/Pfadi.app ~/git    # opens that folder
open -a build/Pfadi.app file.txt # opens the folder holding it
```

## Install

```bash
brew install sapn95/tap/pfadi
```

The formula compiles from source rather than downloading a bundle. pfadi has no
Developer ID signature and is not notarised, so a prebuilt `.app` fetched from a
release would be quarantined and refuse to open. A binary built on the machine
it runs on has no such problem, and it takes under a minute.

From a terminal that is all you need:

```bash
pfadi           # the current directory
pfadi ~/git     # somewhere else
```

The command returns immediately rather than holding the terminal, and a window
that is already open is reused instead of a second one appearing.

To have it appear in Spotlight, Launchpad and `open -a`, link the bundle into
your applications folder:

```bash
ln -sfn "$(brew --prefix pfadi)/Pfadi.app" ~/Applications/Pfadi.app
```

## The mark

<img src="assets/logo.svg" alt="" width="88" align="left">

Two characters, side by side. The white shape is a **forward slash**, the one
character every path on this system is made of. The amber block is a **text
cursor**, the kind that sits blinking in a terminal waiting for you to type.

Put together they read `/▮`: a path, and the place you type one. That is the
entire application in two shapes, and it is the thing macOS itself refuses to
give you.

Nothing alpine in it. No cross, no edelweiss, no mountain.

The icon is drawn by [`scripts/make-icon.swift`](scripts/make-icon.swift)
rather than checked in as a bitmap, so it stays diffable, the palette lives in
one enum, and every size macOS asks for is drawn rather than resampled.
[`assets/logo.svg`](assets/logo.svg) is the same geometry as a vector, for
places like this one that want to scale it.

## Build

Needs Swift 6 and macOS 14. The Command Line Tools are enough. Xcode is not
required, which is the whole reason the test target looks the way it does.

```bash
swift build                  # the binary
swift run pfadi-selftest     # the tests
./scripts/make-app.sh        # build/Pfadi.app
```

There is no Developer ID signature and no notarisation, which is why the
Homebrew formula compiles instead of downloading. A prebuilt copy handed to
someone else will refuse to open, and that stays true until this is worth
shipping.

Releases are cut by tagging. `VERSION` is the single source of truth and the
release workflow refuses to run when the tag disagrees with it.

## How it is put together

| Path | What lives there |
| --- | --- |
| `Sources/PfadiCore` | Directory listing, sorting, path completion, type-ahead, the watcher, the favourites, the preferences, the start-folder rules. No AppKit, so it can be tested. |
| `Sources/pfadi` | The window, the table, the path field, the menu bar. AppKit, built in code, no nib files. |
| `Tests/PfadiSelfTest` | The tests, as a plain executable. |
| `scripts/make-app.sh` | Wraps the SwiftPM binary in a `.app` bundle. |
| `scripts/make-icon.swift` | Draws the icon at every size macOS asks for. |
| `Formula/pfadi.rb` | The Homebrew formula, copied into the tap on release. |

Two decisions worth knowing about before reading the code.

**The tests are an executable, not a `.testTarget`.** Both XCTest and
swift-testing ship inside the full Xcode install, so `swift test` cannot run on
a machine that only has the Command Line Tools. A 15 GB download is a steep
price for sixteen assertions, so the suite is a `main.swift` with a forty-line
harness that prints one line per check and exits non-zero on failure. CI runs
the same command a laptop does.

**Directory URLs go through one funnel.** Foundation appends a trailing slash
to a file URL when it has consulted the filesystem and found a directory, and
none when it has not. The same folder then produces two URLs that compare
unequal, which quietly breaks anything asking "am I already there?".
`PathCompletion.directoryURL` is the single spelling, and a self-test
reproduces the original mismatch so it cannot come back.

## CI

Every pull request runs, on the newest published version of each action:

| Job | What it proves |
| --- | --- |
| build and self-test | `swift build`, the self-test suite, and that `make-app.sh` produces a launchable bundle with a valid `Info.plist`. |
| swift-format | `swift format lint --strict` against `.swift-format`. |
| lint workflows | actionlint, yamllint, markdownlint. |
| secret scan | gitleaks over the full history. |

The build job runs on macOS because AppKit does not cross-compile. The rest run
on Linux because they do not need to.

## What is missing

Roughly in the order it hurts.

- [ ] Copy and move, with progress and a conflict story.
- [ ] Back and forward.
- [ ] An info panel.
- [ ] Cloud files marked as such, and not downloaded by being looked at.
- [ ] SMB and NFS shares, mounted by typing one in the path field.
- [ ] Drag and drop.
- [ ] Tabs.
- [ ] A signed, notarised build.

## Licence

MIT, see [LICENSE](LICENSE).

[QSpace]: https://qspace.awehunt.com
[Path Finder]: https://cocoatech.io
[Nimble Commander]: https://magnumbytes.com
