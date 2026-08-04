# pfadi

<img src="assets/logo.svg" alt="The pfadi mark: a forward slash next to a text cursor"
     width="112" align="right">

A small macOS file browser with the one thing macOS has never had: an address
bar you can click into and type, with tab completion.

> **Work in progress.** It browses, copies, moves, renames, trashes and makes
> folders, in tabs, with drag and drop, and ⌘Z takes back any of it. It is not
> signed or notarised, so a copy handed to somebody else will not open on their
> Mac. Building it yourself works, which is what the Homebrew formula does.

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
⌘[ ⌘]   back and forward, with arrows in the toolbar to match
⌘↑      enclosing folder
⇧⌘H     home
⇧⌘.     show hidden files
⌘R      refresh
⌘D      add this folder to the sidebar, or take it back out
⇧⌘N     new folder, with the cursor already in its name
F2      rename the selection
⌘⌫      move the selection to the trash
⌘I      what is this thing: kind, size, dates, access, cloud status
⌘K      connect to a server, or just type smb://server/share above
⌘F      filter this folder by name
⌘T ⌘N   a new tab, a new window
⌘↓      open the selected folder in a tab, keeping where you are
⌘C ⌘V   copy, then paste, with ⌥⌘V to move instead
⌘Z      undo any of it
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

Right-click a row for **Open With**, which lists every application registered
for that file with the current default first. Hold option and the same list
becomes "always open every file of this kind with this", which is what the
system actually offers: defaults are per kind, never per file, so the menu
says so rather than hiding it behind the word "always".

**A share is an address too.** Type `smb://server/share` or
`nfs://filer/export` into the path field and it mounts and opens, rather than
sending you to a separate dialog with its own history and its own idea of what
you meant. `⌘K` puts `smb://` in the field for you. If it is already mounted it
goes straight there instead of producing a second mount point with a number on
the end, which is how people end up with `share-1` through `share-4`. Anything
needing a password is handed to the system, which already has a connect sheet
with keychain handling in it.

**Cloud files are marked and never downloaded by being looked at.** OneDrive,
Dropbox, Google Drive and iCloud all leave placeholder files that have a name,
a size and no bytes. They look completely ordinary to a directory listing,
which is how copying "everything" quietly pulls a hundred gigabytes down a
metered connection. A placeholder shows a cloud in the size column, and ⌘I says
which provider and which account. The check is `lstat` against the dataless
flag plus the path, so describing a file never asks its provider anything.

Tabs are macOS's own window tabs rather than a tab bar drawn by hand, so ⌘⇧[
and ⌘⇧], Merge All Windows and Move Tab to New Window all work the way they do
everywhere else. Drag and drop follows Finder's rule, because muscle memory is
the only rule that matters: a drag within a volume moves, across volumes it
copies, ⌥ forces a copy and ⌘ forces a move. Dropping onto a folder puts things
in it; dropping between rows puts them in the folder on screen.

Everything that changes anything is reversible, which is the rule the whole
write side is built on. ⌘Z puts back a trashed file, undoes a rename, trashes a
folder that was just created, and unwinds a copy or a move. A rename that would
land on an existing file is refused rather than replacing it.

**Replacing never destroys.** Choosing Replace during a paste puts the existing
item in the trash first and then copies. A wrong answer in that dialog is
recoverable, which is not true of any file manager that overwrites in place.

Copies go through `copyfile` with `COPYFILE_CLONE`. On APFS that is a
constant-time copy sharing blocks until one side is written to, so duplicating
twenty gigabytes costs no time and no disk, and it carries the extended
attributes, ACLs and flags that a read-and-write copy silently drops. A move
within one volume is `rename(2)`; across volumes it falls back to copy and
delete.

The tree is expanded before anything starts, so the progress bar is honest
about how much is left and Stop lands between two files rather than somewhere
inside a black box. Conflicts are all asked about up front: being interrupted
halfway through a long copy, with no idea what has already happened, is what
makes people stop trusting a file manager.

⌘F filters the folder you are in. Substring rather than prefix and blind to
case and accents, so `config` finds `.eslintrc.config.js`. The status line
counts what survived. The filter is dropped when you leave, because it
described the folder you were in and carrying it into the next one shows an
empty list with no explanation.

The sidebar has four sections. **Favourites** are yours: ⌘D puts the folder
you are in there and ⌘D takes it out again, and right-click removes a row. A
favourite whose folder has been deleted or unmounted is skipped rather than
drawn as a row that beeps when clicked, and it stays in the list in case the
volume comes back.

**Recents** is the last eight folders you went to, newest first, with home left
out because that is where a window opens when nothing else is known rather than
somewhere you chose.

**Cloud** and **Locations** are not yours and cannot be edited, because they
are facts about the machine rather than a list somebody curates. Cloud is
whatever is in `~/Library/CloudStorage`: your OneDrive, Dropbox or Google
Drive accounts, which otherwise live inside a folder macOS hides and are
unreachable unless you already know the path. Locations is the mounted
volumes, including anything mounted by typing an `smb://` into the path field.
Both are rebuilt on every refresh, because a share can be mounted and an
account can be signed out of while the window is open.

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
someone else will refuse to open.

Everything needed to change that is in place and waiting for a certificate:

```bash
PFADI_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
PFADI_NOTARY_PROFILE=pfadi \
  ./scripts/sign-and-notarise.sh
```

Hardened runtime, a trusted timestamp, an empty entitlements file because a
file browser needs no exceptions, then notarise and staple so it opens on a
machine that is offline. The release workflow runs the same script when
`SIGNING_CERTIFICATE_P12` is set as a repository secret, and warns and carries
on when it is not.

**None of that is needed to install pfadi, and it is deliberately not being
bought.** A Developer ID certificate requires an Apple Developer Program
membership at 99 USD a year, and there is no free route to one: a personal
Apple ID gets you an Apple Development certificate, which cannot sign anything
for distribution.

What signing would buy is the ability to hand somebody a prebuilt `.app` that
opens on a double click. Nothing else. The Homebrew formula compiles on the
machine it will run on, and a binary built locally is never quarantined in the
first place, so there is nothing for Gatekeeper to object to. That is why the
formula builds from source rather than downloading a release, and it is the
reason this project can be installed by anyone today, for nothing.

The script and the workflow job stay because they cost nothing to keep and
turn a certificate into a signed release the day one exists.

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

- [x] ~~A signed, notarised build.~~ Not planned. See below.

## Licence

MIT, see [LICENSE](LICENSE).

[QSpace]: https://qspace.awehunt.com
[Path Finder]: https://cocoatech.io
[Nimble Commander]: https://magnumbytes.com
