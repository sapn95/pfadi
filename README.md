# pfadi

<img src="assets/logo.svg" alt="The pfadi mark: a forward slash next to a text cursor"
     width="112" align="right">

A small macOS file browser with the one thing macOS has never had: an address
bar you can click into and type, with tab completion.

> **Work in progress.** It browses, copies, moves, renames, trashes and makes
> folders, in tabs, with drag and drop, and ⌘Z takes back any of it. It is not
> signed or notarised, which is why the Homebrew formula compiles rather than
> downloading. Keep Finder around for the things below it cannot do.

```bash
brew install sapn95/tap/pfadi
pfadi-default apply
```

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
([Nimble Commander]), or not written for macOS at all.

So: one pane, one path field, keyboard first.

## Keys

```text
⇧⌘G      type a path, with tab completion
click    a folder in the path: everything beside it, with a filter
2×click  a folder in the path: go there
›        the arrow after the last folder: everything inside it
⌘F       filter the folder you are in
space    Quick Look, and again to close it
return   open, or go there
a-z      type-ahead: jump to the row whose name starts like that
⌘[ ⌘]    back and forward
⌘↑       enclosing folder
⌘↓       open the selected folder in a tab
⇧⌘H      home
⇧⌘.      hide the dotfiles, which are shown by default
⌘R       refresh
⌘T ⌘N    a new tab, a new window
⌘C ⌘V    copy, then paste, with ⌥⌘V to move instead
⇧⌘N      new folder, with the cursor already in its name
F2       rename
⌘⌫       move to the trash
⌘Z       undo any of that
⌘I       what is this: kind, size, dates, access, cloud status
⇧⌘C      copy the path of the selection
⌃⌘T      open a terminal here
⇧⌘R      reveal in Finder
⌘D       add this folder to the sidebar, or take it back out
⌘K       connect to a server
```

## The address bar

The path along the top is clickable, all the way to the root: a path that
quietly begins in the middle is one you have to think about before you can
trust it. Clicking a folder offers everything beside it; the arrow after the
last one offers everything inside it. Both menus have the same shape, with the
filter at the top and already focused, whichever part was clicked and however
few folders are in it. A menu that is sometimes a plain list and sometimes a
searchable one means looking first and reacting second, every single time.

Clicking the leftmost folder goes straight there, because the root has no
siblings to offer. When the path is too long, folders fold into an ellipsis
that still opens them, and they give way in a deliberate order: the ones just
below the root first, then the root, and never the last one.

`⇧⌘G` or the button at the right end of the row swaps the whole thing for a
text field. Tab walks the matches inline, shift-tab goes back, both wrap, and
the status line counts along: `2 of 7`.

Escape does one of two things, and which one depends on whether tab has been
pressed. Part way through walking the matches it puts back exactly what you
typed before the first tab and leaves you in the field. Otherwise it gives up
on the field altogether: the path goes back to where you actually are and the
clickable bar returns.

Return has two jobs, in the order you need them. The first accepts the match
showing and leaves you in the field, so the next tab carries straight on into
the folder you just chose. The second goes there.

A path can be absolute, relative, or start with `~`. Pointing it at a file
hands the file to whichever application owns it.

## The sidebar

**Favourites** are yours: ⌘D adds and removes, a folder dropped between two
becomes one at that position, dragging reorders, and right-click removes. It
starts with Home, Desktop, Documents, Downloads, Applications and the root,
because a file browser that cannot reach `/` is a browser for one folder tree.

**Recents** is the last ten folders, newest first, with home left out: that is
where a window opens when nothing else is known, not somewhere you chose.

**Cloud** and **Locations** are facts about the machine rather than a list
somebody curates, so they cannot be edited. Cloud is whatever is in
`~/Library/CloudStorage` — your OneDrive, Dropbox or Google Drive accounts,
which otherwise live inside a folder macOS hides and are unreachable unless you
already know the path. Locations is the mounted volumes. Both are looked for
again when the window comes forward rather than on every navigation: asking the
kernel for every mounted filesystem blocks on a share whose server has gone
away, and that belongs nowhere near walking a folder tree.

**Servers** remembers what you have connected to, and always ends in
`Connect to Server…`. A way in that only appears once you already have one is
not a way in.

## Cloud files

OneDrive, Dropbox, Google Drive and iCloud all leave **placeholder** files: a
name, a size, a date, and no bytes. They look completely ordinary to a
directory listing, which is how copying "everything" quietly pulls a hundred
gigabytes down a metered connection.

A placeholder shows a cloud in the size column, the status line counts them,
and ⌘I says which provider, which account, and how much of the file is actually
on this Mac.

The check is `lstat` against the dataless flag plus the path. **Deliberately
not the File Provider**: asking an extension about an item is how you start
downloading the thing you were only trying to describe. The provider is
resolved once per folder, so a folder outside anybody's cloud costs nothing per
file.

Downloading a placeholder on demand and evicting one to free space are not
here: both need the File Provider domain APIs rather than a filesystem call.
Opening a file downloads it, because that is what the provider does when
something reads it.

## Shares

Type `smb://server/share` or `nfs://filer/export` into the path field and it
mounts and opens. `⌘K` asks instead, with the protocol as a button and the
shape each one expects written under the field.

It understands what people actually paste:

| Pasted | Understood as |
| --- | --- |
| `\\filer\projects` | `smb://filer/projects` |
| `\\filer\team share\docs` | `smb://filer/team%20share/docs` |
| `filer:/export/data` | `nfs://filer/export/data` |

It says when it rewrote something, quoting both back, and a checkbox turns that
off. An already-mounted share is found rather than mounted again, which is how
people end up with `share-1` through `share-4`.

## Writing to disk

Everything that changes anything is reversible. ⌘Z puts back a trashed file,
undoes a rename, trashes a folder that was just created, and unwinds a copy or
a move.

**Replacing never destroys.** Choosing Replace during a paste puts the existing
item in the trash first and then copies. A wrong answer in that dialog is
recoverable, which is not true of a file manager that overwrites in place.

Copies go through `copyfile` with `COPYFILE_CLONE`. On APFS that is a
constant-time copy sharing blocks until one side is written to, so duplicating
twenty gigabytes costs no time and no disk, and it carries the extended
attributes, ACLs and flags a read-and-write copy silently drops. A move within
one volume is `rename(2)`; across volumes it falls back to copy and delete, and
takes the emptied source folders with it.

The tree is expanded before anything starts, so the progress bar is honest and
Stop lands between two files rather than inside a recursive call. Conflicts are
all resolved up front: being interrupted halfway through a long copy, with no
idea what has already happened, is what makes people stop trusting a file
manager.

Two things it refuses outright: a folder into itself, and a folder into its own
descendant. The containment check compares path components rather than string
prefixes, or `/a/bc` would count as living inside `/a/b`.

## Instead of Finder

```bash
pfadi-default          # what the system has now, changing nothing
pfadi-default apply    # the launcher, the shell function, and what macOS allows
pfadi-default undo     # all of it back
```

Every claim it makes is measured at run time rather than assumed:

| | |
| --- | --- |
| Volumes | Handed over |
| Folders | **Refused**, `paramErr` from `LSSetDefaultRoleHandlerForContentType` |
| Directories | **Refused**, the same |
| The `file://` scheme | **Refused**, the same |

Declaring `public.folder` in `CFBundleDocumentTypes` does not change the
answer; it was tried, and the bundle declares it anyway. **Nothing but Finder
can be the default for a folder on this system.** That is the entire reason for
the shell function `apply` installs, which sends `open .` and `open <folder>`
to pfadi and leaves `open report.pdf` alone. Finder cannot be taken out of the
Dock either: macOS reserves that tile.

The launcher it puts in `~/Applications` is a bundle whose only content is the
command that starts pfadi. A symlink there is not indexed, because Spotlight
indexes `~/Applications` but not Homebrew's Cellar. A copy is indexed and then
goes stale the next time brew upgrades the real thing, which is worse: it keeps
launching a version that is no longer installed. A launcher is neither.

## Build

Needs Swift 6 and macOS 14. The Command Line Tools are enough; Xcode is not
required, which is the whole reason the test target looks the way it does.

```bash
swift build                    # the binary
swift run pfadi-selftest       # the tests
swift run pfadi --layout-check # the window, measured
./scripts/make-app.sh          # build/Pfadi.app
```

There is no Developer ID signature and no notarisation, and that is a decision
rather than an omission. A certificate needs an Apple Developer Program
membership at 99 USD a year and there is no free route to one. What it would
buy is handing somebody a prebuilt `.app` that opens on a double click, and
nothing else: the formula compiles on the machine it will run on, and a locally
built binary is never quarantined. `scripts/sign-and-notarise.sh` and the
`sign` job stay, and turn a certificate into a signed release the day one
exists.

Releases are cut by tagging. `VERSION` is the single source of truth and the
release workflow refuses a tag that disagrees with it.

It can also be run for a tag that already exists, from the Actions tab. A tag
push is a webhook, and GitHub throttles webhooks when Actions is having a bad
day: on 6 August 2026 a pushed tag produced no run at all and three releases
had to be cut by hand. One trigger is not enough for the one workflow that has
to happen.

## How it is put together

| Path | What lives there |
| --- | --- |
| `Sources/PfadiCore` | Listing, sorting, completion, type-ahead, the watcher, transfers, favourites, preferences, shares. No AppKit, so it can be tested. |
| `Sources/pfadi` | The window, the list, the path bar, the sidebar, the menus. AppKit, built in code, no nib files. |
| `Sources/pfadi-default` | The tool that puts pfadi where Finder is. |
| `Tests/PfadiSelfTest` | The tests, as a plain executable. |
| `scripts/` | The `.app` bundle, the icon, signing. |
| `Formula/pfadi.rb` | The Homebrew formula, copied into the tap on release. |

Four decisions a reader trips over.

**The tests are an executable, not a `.testTarget`.** XCTest and swift-testing
both ship inside the full Xcode install, so `swift test` cannot run on a machine
with only the Command Line Tools. A 15 GB download is a steep price for three
hundred assertions.

**There is a window check.** A layout mistake is invisible to a build, to the
tests and to a launch: the application starts, and the window is sixty points
tall with the filter off the edge. `--layout-check` builds the real window
off-screen at two sizes, measures every control, and fails on an **ambiguous**
layout, because a view free to be in two places will eventually pick the wrong
one.

It then clicks through it. The root was unreachable for three versions while
the model that knew about it was correct the whole time, so reading the model
proved nothing. These go through the same code a click runs: the path bar's own
button action, the sidebar's own selection handler. They also wait for the
listing, because reading a folder happens on a worker and arrives on the main
queue, and a check with no run loop turning sees an empty folder every time.

**The path bar is buttons, not `NSPathControl`.** That control reports the same
intrinsic width whatever it shows, sixty points for one folder or for ten, so
nothing beside it can be placed relative to its contents and the whole row ends
up underdetermined.

**Directory URLs go through one funnel.** Foundation appends a trailing slash
when it has consulted the filesystem and none when it has not, so the same
folder produces two URLs that compare unequal. `PathCompletion.directoryURL` is
the single spelling, and it took three separate bugs to learn that.

## CI

Every pull request runs, on the newest published version of each action:

| Job | What it proves |
| --- | --- |
| build and self-test | `swift build`, the suite, the layout check, and that `make-app.sh` produces a launchable bundle |
| swift-format | `swift format lint --strict` |
| lint workflows | actionlint, yamllint, markdownlint |
| secret scan | gitleaks over the full history |

The build job runs on macOS because AppKit does not cross-compile. The rest run
on Linux because they do not need to.

## Wanted next

- **Expandable folders in the list**, the way an open panel does it.
- **Downloading and evicting cloud placeholders**, which needs the File
  Provider domain APIs.

## Licence

MIT, see [LICENSE](LICENSE).

[QSpace]: https://qspace.awehunt.com
[Path Finder]: https://cocoatech.io
[Nimble Commander]: https://magnumbytes.com
