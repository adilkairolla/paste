# PasteDeck — manual

A native macOS clipboard manager: full history, categories that persist, search,
media support, and source-app attribution. Press **⌘⇧V** and the deck slides up
from the bottom of the screen.

![The deck](deck.png)

Written in Swift (AppKit + SwiftUI) with **zero third-party dependencies**.
History lives in a local SQLite database. There is no networking code in the app.

---

## Install

Requires macOS 14 or newer and the Xcode Command Line Tools (`xcode-select --install`).
A full Xcode install is *not* needed.

```sh
make install     # builds, copies to /Applications, launches
```

Or just build and run from the repo:

```sh
make run         # builds dist/PasteDeck.app and opens it
```

On first launch PasteDeck offers to open **System Settings ▸ Privacy & Security ▸
Accessibility**. Granting it lets PasteDeck press ⌘V for you after you pick an
item. Everything else — recording, searching, copying — works without it.

Without it, Enter and clicking a card still put the clipping on the clipboard,
but nothing lands in the app you came from. The deck stays open and says so
rather than looking like the key did nothing.

**An ad-hoc build loses that grant every time you rebuild** — see
[Accessibility and code signing](#accessibility-and-code-signing).

To start it automatically: **Settings ▸ General ▸ Start PasteDeck at login**.

## Using it

| Key | Action |
|---|---|
| `⌘⇧V` | Open / close the deck (re-bindable in Settings) |
| `←` `→` | Move through clippings |
| `↩` | Paste into the app you came from |
| `⌘C` | Copy without pasting |
| `⌘1`…`⌘9` | Paste the *n*-th clipping |
| `space` | Large preview with full metadata |
| `⌘P` | Pin (pinned items are never pruned) |
| `⌘⌫` | Delete the clipping |
| `⇥` / `⇧⇥`, `↑` `↓` | Next / previous category |
| `⌘N` | New category |
| `⌘,` | Settings |
| `esc` | Clear the search, then close |

Type anything to search — the field has focus the moment the deck opens.
Right-click a card for pinning, categories, *Copy as Plain Text*, *Open Link*,
*Reveal in Finder*, and delete.

### Categories

Two kinds share the same bar:

- **Smart** — All, Pinned, Text, Links, Images, Files, Code, Colors. These are
  live filters over the whole history.
- **Yours** — created with `⌘N` or the `+` chip. Filing a clipping into one makes
  it **permanent**: user categories and pins are exempt from every retention rule.

### What gets recorded

Every representation of every copy — plain text, RTF, HTML, PNG/TIFF/JPEG, file
URLs, colours, and app-private formats — so pasting back into the originating app
is byte-identical rather than downgraded to plain text.

Each clipping stores the app it came from (icon and name), when it was first and
last seen, how many times you've pasted it, its size, and kind-specific metadata:
pixel dimensions, character/word/line counts, URL host, file paths, hex value.

### What doesn't

- Pasteboards flagged `org.nspasteboard.ConcealedType` — password managers set
  this, so credentials are skipped.
- Transient and auto-generated pasteboards.
- Anything from an app on your ignore list (**Settings ▸ Privacy**).
- PasteDeck's own writes.

## Keeping storage bounded

**Settings ▸ History** sets three independent limits, each defaulting to
something sane and each settable to *No limit*:

| Limit | Default |
|---|---|
| Number of clippings | 2 000 |
| Age | 30 days |
| Disk used | 2 048 MB |

Pruning runs at launch, every 30 minutes, and on demand. It removes the oldest
clippings first and **never** touches pinned or filed ones. Payloads over 64 KB
live in a content-addressed blob store (`blobs/ab/cd/<sha256>`), so two copies of
the same screenshot occupy one file; unreferenced blobs are garbage collected on
the same schedule.

Memory stays flat regardless of history size: the deck reads one page of rows and
pulls thumbnails lazily, never full payloads.

Everything is under `~/Library/Application Support/PasteDeck/`.

## Development

```sh
make build    # compile every target
make test     # 45 unit tests over the store, classifier and retention
make app      # assemble dist/PasteDeck.app
make run      # build, replace the running copy, launch
make icon     # regenerate Resources/AppIcon.icns
```

Command Line Tools ship neither XCTest nor swift-testing, so the suite is a plain
executable with a small harness in `Tests/CoreTests/Harness.swift`.

Render the UI offscreen without launching anything:

```sh
swift run PasteDeck --render-preview /tmp/deck.png
swift run PasteDeck --render-preview /tmp/large.png --large
```

### Layout

```
Sources/PasteDeckCore/     Foundation only — unit-testable, no AppKit
  Model/                   ClipItem, ClipKind, ClipCategory, metadata
  Store/                   SQLite wrapper, schema + FTS5, ClipStore, blobs, retention
  Capture/                 Pasteboard snapshot, classifier, text/image analysis
  Settings/                Preferences, on-disk paths
Sources/PasteDeck/         The app
  Clipboard/               Pasteboard monitor, paste-back, source-app attribution
  System/                  Carbon hot key, Accessibility, login item
  UI/                      Deck panel, cards, category bar, detail bar, settings
Tests/CoreTests/           Test harness + suites
scripts/                   .app bundler, icon generator
```

### Design notes

- **Polling, not notifications.** macOS has no pasteboard-change notification;
  `changeCount` is polled every 0.35 s (configurable). It's an integer read.
- **Carbon for the hot key.** `RegisterEventHotKey` needs no permissions, unlike
  a `CGEventTap`, so the deck opens the moment you install it.
- **Non-activating panel.** The deck takes keyboard focus without stealing the
  menu bar; the app you came from is remembered and re-activated on paste.
- **External-content FTS5.** The search index is kept in sync by triggers, so it
  can never drift from the `items` table.
- **One radius formula.** `radius(container) = radiusTile + its own padding` —
  the concentric rule `inner = outer − inset` read from the inside out. Starting
  from a 4 pt tile that gives cards `4 + 8 = 12` and the panel `4 + 12 = 16`, so
  curves stay parallel however deep the nesting goes. Deriving the panel from
  the *card* instead (`12 + 12 = 24`) double-counts: cards sit in the middle of
  the panel and never touch its corners, and the panel ends up rounder than
  anything in it, crowding the search field and the meta bar that do live there.
  Pills are the exception — their radius is half their height by definition, so
  `Theme.pillPadding(_:)` derives their side padding from their height instead.
- **The panel height is a sum, not a measurement.** Every section has a fixed
  height and `Theme.deckHeight` adds them up (12 + 28 + 8 + 24 + 12 + 96 + 12 +
  1 + 52 = 245), so the hosting window can't crop a row or leave dead space.
  `design/layout-workbench.html` derives the same numbers from the same formula.
- **One colour means focus.** The accent ring marks whatever the arrows are
  steering — a card, a category chip, or the search field — and dims on the
  other two. Category tints say *which filter*; the accent says *where you are*.

## Accessibility and code signing

An ad-hoc signature (`codesign -s -`, the default here) gives the app no
identity of its own, so the requirement macOS files alongside the Accessibility
grant is the code hash itself:

```
$ codesign -d -r- /Applications/PasteDeck.app
designated => cdhash H"13dd4f8cc712ee6364084db62e08ee1265e0e8d7"
```

Every rebuild changes that hash. The grant then matches nothing — but the row
stays in System Settings with its switch still on, so the app looks authorised
and silently can't press ⌘V. `make install` therefore runs
`tccutil reset Accessibility app.pastedeck`, which puts the switch back to off
where it belongs so you can grant it again and see that you did.

To stop re-granting after every build, sign with a real identity — its
requirement is the same before and after:

```sh
make signing-cert                                  # once; asks for your password
SIGN_IDENTITY="PasteDeck Local Signing" make install
```

That creates a self-signed code-signing certificate in your login keychain and
trusts it for code signing. Delete "PasteDeck Local Signing" in Keychain Access
to undo it. Any Developer ID or Apple Development identity works just as well.

## Caveats

- Source-app attribution uses the frontmost app at copy time. Copies made by a
  background script are attributed to whatever was in front.
