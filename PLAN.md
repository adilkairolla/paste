# PasteDeck — a native macOS clipboard manager (PasteNow-style)

## 1. Stack decision

| Option | Verdict |
|---|---|
| **Swift + AppKit/SwiftUI** | ✅ **Chosen.** `NSPasteboard`, `NSWorkspace` (source app + icons), `NSPanel` overlay, `SMAppService` (login item), Carbon `RegisterEventHotKey` (global hotkey, no permissions needed), `CGEvent` (paste-back) are all first-party. Anything else re-wraps these APIs anyway. |
| Rust (tauri/objc2) | Every clipboard/pasteboard/AX call becomes an FFI binding you maintain; UI is a webview → heavier RAM for an always-on agent. |
| Objective-C | Same APIs, worse ergonomics, no SwiftUI. |
| Electron | ~200 MB RSS resident all day for a background utility. No. |

**Target:** macOS 14+, arm64 + x86_64 universal. Swift 6 compiler, Swift 5 language mode
(avoids strict-concurrency churn in AppKit glue).

**Build:** SwiftPM (no Xcode installed — only Command Line Tools). `scripts/build_app.sh`
compiles and assembles a real `.app` bundle (`Info.plist`, `LSUIElement`, icon, ad-hoc
codesign). This keeps everything text-based/diffable — no `.pbxproj`.

**Storage:** system `libsqlite3` (has **FTS5** — verified) via a thin hand-rolled wrapper.
Zero third-party dependencies → no supply chain, no network at build time, tiny binary.

### Targets
- `PasteDeckCore` — Foundation-only: models, SQLite layer, store, classification,
  retention, preferences. Fully unit-testable headlessly.
- `PasteDeck` — executable: AppKit/SwiftUI, pasteboard monitor, hotkeys, panel UI.
- `PasteDeckCoreTests` — swift-testing suite over Core.

## 2. Feature map → implementation

| Requirement | How |
|---|---|
| Full clipboard history | `NSPasteboard.general.changeCount` polled at 0.35 s (no notification API exists). Captures **every representation** (UTI → bytes) of every pasteboard item so paste-back is byte-faithful into the origin app. |
| Media (images, files, rich text, colors) | Payloads stored per-UTI. ≤64 KB inline in SQLite, larger → content-addressed blob files (`blobs/ab/cd/<sha256>`), so identical copies dedupe on disk. 256 px PNG thumbnail cached inline for instant grid rendering. |
| Source app | `NSWorkspace.shared.frontmostApplication` sampled at capture time → bundle id + name; icon cached as PNG under `appicons/`. |
| Meta info | Per-kind JSON: text → chars/words/lines; link → url/host/scheme; image → px dimensions/format; file → paths/count/total size; color → hex/RGB. Plus size on disk, UTI list, first-seen / last-seen / use count. |
| ⌘⇧V opens it | Carbon `RegisterEventHotKey` (works with **zero** permissions, unlike a CGEventTap). Re-bindable via a key recorder in Settings. |
| Categories | Two kinds: **smart** (All / Pinned / Text / Links / Images / Files / Color / Code — computed filters) and **user categories** (persistent, many-to-many `item_categories`). |
| Persist into categories | Anything pinned or filed into a user category is **exempt from all pruning** — that's the "keep forever" guarantee. |
| Search | FTS5 (`unicode61`, prefix queries) over content + title + app name, with a `LIKE` fallback. Live-filtering as you type. |
| Memory/disk bounds | Retention: max items (2000), max age (30 d), max blob bytes (2 GB) — all configurable, `0 = unlimited`. Runs at launch, hourly, and throttled after inserts. Orphan-blob GC + `VACUUM`/`wal_checkpoint` on a schedule. RAM stays flat: the UI holds only the current page (200 rows) and thumbnails, never full payloads. |
| Start on startup | `SMAppService.mainApp.register()` (shows in System Settings ▸ Login Items), with a `~/Library/LaunchAgents` plist fallback. |

## 3. UI

A non-activating `NSPanel` docked to the bottom of the active screen, full width,
translucent (`NSVisualEffectView`), showing a horizontally scrolling **deck of cards** —
the Paste/PasteNow signature layout.

```
┌──────────────────────────────────────────────────────────────────────┐
│  All  Pinned  Text  Links  Images  Files  Code │ +Work +Snippets   🔍 │
├──────────────────────────────────────────────────────────────────────┤
│  ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐              │
│  │ Xcode  │ │ Safari │ │ Figma  │ │ Finder │ │ Notes  │   →          │
│  │ 2m ago │ │ 5m ago │ │ 11m    │ │ 1h     │ │ 3h     │              │
│  │ func … │ │ https… │ │ [img]  │ │ 3 files│ │ text…  │              │
│  └────────┘ └────────┘ └────────┘ └────────┘ └────────┘              │
├──────────────────────────────────────────────────────────────────────┤
│  Swift source · 1.2 KB · 48 lines · from Xcode · today 14:02      ⏎  │
└──────────────────────────────────────────────────────────────────────┘
```

Keys: `←/→` select · `⏎` paste into the app you came from · `⌘C` copy only ·
`⌘1…9` paste Nth · `⌘⌫` delete · `⌘P` pin · `⌘⇧C` add to category · `⇥` next category ·
`space` large preview · `esc` dismiss · typing anywhere searches.

Paste-back: write payloads → hide panel → re-activate the previously frontmost app →
synthesise ⌘V via `CGEvent` (needs Accessibility; degrades gracefully to copy-only with
an inline permission prompt).

## 4. Build order

1. Package skeleton, `.app` bundler, status-item agent, hotkey, empty panel ← *runnable*
2. SQLite wrapper + schema/migrations + blob store (+ tests)
3. Capture pipeline: monitor → snapshot → classifier → store (+ dedupe, ignore rules)
4. Deck UI: cards, selection, search, category bar, metadata strip
5. Paste-back + Accessibility permission flow
6. Categories CRUD, pinning
7. Retention, GC, Settings window, login item
8. Polish: app icon, animations, empty states, README

## 5. Privacy / safety notes

- Ignores pasteboards flagged `org.nspasteboard.ConcealedType` (password managers) and
  `…TransientType` / `…AutoGeneratedType`.
- Per-app exclusion list in Settings.
- Everything is local: a SQLite file + blobs in `~/Library/Application Support/PasteDeck`.
  No network code exists in the app at all.
