# pfadi

> **Work in progress.** It builds, it runs, it navigates. It cannot copy,
> move, rename or delete anything yet. Treat it as a browser, not a file
> manager, and keep Finder around.

A small macOS file browser with the one thing macOS refuses to give you: an
address bar you can click into and type a path, with tab completion.

```
⇧⌘G     jump to the path field
tab     complete the half-typed component
return  go there
⌘↑      enclosing folder
⇧⌘H     home
⇧⌘.     show hidden files
⌘R      refresh
```

## Why

Finder has a path bar at the bottom and a path menu behind ⌘-clicking the
title, and neither of them lets you type. `⇧⌘G` opens a modal sheet, which is a
detour, not an address bar. Every alternative that does have one is either paid
([QSpace], [Path Finder]), dual-pane by conviction ([Nimble Commander],
Commander One), or not native.

So: one pane, one path field, keyboard first.

## Build

Needs Swift 6 and macOS 14. The Command Line Tools are enough, Xcode is not
required.

```bash
swift build                  # the binary
swift run pfadi-selftest     # the tests
./scripts/make-app.sh        # build/Pfadi.app
```

```bash
open -a build/Pfadi.app ~/git    # opens that folder
```

There is no release build, no signature, and no notarisation. Anything you
download from someone else will not open on your Mac, and that is on purpose
until this is worth shipping.

## Layout

| | |
|---|---|
| `Sources/PfadiCore` | directory listing, sorting, path completion. No AppKit, so it can be tested. |
| `Sources/pfadi` | the window, the table, the path field. AppKit, no nib files. |
| `Tests/PfadiSelfTest` | the tests, as a plain executable. |

The tests are an executable rather than a `.testTarget` because both XCTest and
swift-testing live inside the full Xcode install, and `swift test` therefore
cannot run on a machine that only has the Command Line Tools. A 15 GB download
is a steep price for sixteen assertions.

## What is missing

Roughly in the order it hurts:

- [ ] Copy, move, rename, delete. Nothing writes to disk yet.
- [ ] Watching the directory, so external changes show up without ⌘R.
- [ ] Drag and drop.
- [ ] Sorting by clicking a column header.
- [ ] Type-ahead selection in the list.
- [ ] Remembering the last folder between launches.
- [ ] Quick Look on space.
- [ ] Tabs.
- [ ] A signed, notarised build.

## Licence

MIT, see [LICENSE](LICENSE).

[QSpace]: https://qspace.awehunt.com
[Path Finder]: https://cocoatech.io
[Nimble Commander]: https://magnumbytes.com
