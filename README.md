# pfadi

A small macOS file browser with the one thing macOS has never had: an address
bar you can click into and type, with tab completion.

> **Work in progress.** It builds, it runs, it navigates. It cannot copy, move,
> rename or delete anything yet. Treat it as a browser, not a file manager, and
> keep Finder around.

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
tab     complete the half-typed component
return  go there
⌘↑      enclosing folder
⇧⌘H     home
⇧⌘.     show hidden files
⌘R      refresh
```

Completion works the way a shell does it. Type `/Users/sa`, press tab, land on
`/Users/sapn/`. Directories keep their trailing slash so a second tab carries
straight on into them. Dotfiles stay out of the candidate list until you type a
dot, whether or not hidden files are shown.

A path can be absolute, relative to where you are, or start with `~`. Pointing
it at a file rather than a folder hands the file to whichever application owns
it.

From a shell:

```bash
open -a build/Pfadi.app ~/git    # opens that folder
open -a build/Pfadi.app file.txt # opens the folder holding it
```

## Build

Needs Swift 6 and macOS 14. The Command Line Tools are enough. Xcode is not
required, which is the whole reason the test target looks the way it does.

```bash
swift build                  # the binary
swift run pfadi-selftest     # the tests
./scripts/make-app.sh        # build/Pfadi.app
```

There is no release build, no Developer ID signature and no notarisation. A
copy downloaded from anyone else will refuse to open, and that stays true until
this is worth shipping.

## How it is put together

| Path | What lives there |
| --- | --- |
| `Sources/PfadiCore` | Directory listing, sorting, path completion. No AppKit, so it can be tested. |
| `Sources/pfadi` | The window, the table, the path field. AppKit, built in code, no nib files. |
| `Tests/PfadiSelfTest` | The tests, as a plain executable. |
| `scripts/make-app.sh` | Wraps the SwiftPM binary in a `.app` bundle. |

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

- [ ] Copy, move, rename, delete. Nothing writes to disk yet.
- [ ] Watching the directory, so external changes appear without ⌘R.
- [ ] Type-ahead selection in the list.
- [ ] Remembering the last folder between launches.
- [ ] Sorting by clicking a column header.
- [ ] Quick Look on space.
- [ ] Drag and drop.
- [ ] Tabs.
- [ ] A signed, notarised build.

## Licence

MIT, see [LICENSE](LICENSE).

[QSpace]: https://qspace.awehunt.com
[Path Finder]: https://cocoatech.io
[Nimble Commander]: https://magnumbytes.com
