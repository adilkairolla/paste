# PasteDeck

A clipboard history manager for macOS. Press **⌘⇧V**, pick a clipping, it pastes
into whatever you were just doing.

![The deck](docs/deck.png)

- Full history — text, links, code, colours, images, files
- **Stack** several clippings with `⇧↩` and paste them as one labelled block
- **Prompts** — reusable templates with `{{slots}}`, filled in before pasting
- Shows which app each clipping came from, and its metadata
- Full-text search across everything
- Persistent categories, plus pinning
- Old items pruned automatically so the database can't grow forever
- Starts at login, lives in the menu bar, no Dock icon

### Built for pasting into an LLM

Copying an error, then the function, then the docs — one at a time into a chat
window — is most of what using a model looks like. Stack all three with `⇧↩` and
PasteDeck composes them into one block, each part labelled by kind and source
app. Save the wrapper around them as a prompt with a `{{stack}}` slot and the
whole round trip becomes two keystrokes.

Everything stays on your machine. No network code, no accounts, no dependencies —
one 3 MB binary and system SQLite.

## Install

Requires macOS 14+ and the Swift toolchain (Command Line Tools are enough — no
Xcode needed).

```sh
make install    # builds, copies to /Applications, launches it
make run        # build and run without installing
make test       # 46 tests
```

Then grant **System Settings ▸ Privacy & Security ▸ Accessibility** so it can
press ⌘V for you. Everything else works without it.

## Keys

| | |
|---|---|
| `⌘⇧V` | open the deck |
| `←` `→` `⇥` | move within a row |
| `↑` `↓` | move between search, categories, items |
| `↩` | paste — the stack if there is one, else the selected clipping |
| `⇧↩` | add / remove from the stack |
| `⌘1`–`⌘9` | paste the nth clipping |
| `space` | large preview |
| `⌘⇧N` / `⌘E` | new prompt / edit prompt |
| `⌘P` / `⌘⌫` | pin / delete |

## More

[`docs/manual.md`](docs/manual.md) covers the storage model, the retention
policy, the design system, and why an ad-hoc build loses its Accessibility
grant on every rebuild.
