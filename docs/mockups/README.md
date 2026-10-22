# Mockups

High-fidelity HTML/CSS mockups of the screens in `../specs/ux.md`, rendered to PNG at 2× with headless Google Chrome.
Light appearance is the reference; three screens are also rendered dark.

| PNG | Screen | ux.md |
|---|---|---|
| `window-empty.png` (+ `-dark`) | Empty window: the drop zone, the fan of sample cards, Choose Files…, popular pairs | §5.1 |
| `window-drag.png` | Files hovering: gradient border, "Drop 3 files to add them" | §5.2 |
| `window-cards.png` (+ `-dark`) | Eight files of eight kinds, each with its source → target pills and the colour flow | §5.3, §3.4 |
| `target-picker.png` | The format picker popover for a HEIC photo | §5.4 |
| `options-sheet.png` | JPG options for two photos | §5.5 |
| `window-converting.png` | Done, converting (source → target gradient), waiting, and a card that needs a helper | §5.6 |
| `window-done.png` (+ `-dark`) | Results: cards in their new colours, one failure with its fix, the summary bar | §5.7 |
| `menubar.png` | The menu-bar drop panel with two dropped files and recent conversions | §5.9 |
| `quick-action.png` | Finder › Quick Actions with Super Converter's actions | §5.10 |
| `settings-helpers.png` | Settings › Helpers | §5.11 |

## Rendering

`src/shared.css` holds the design tokens (ux §3) and components, `src/shared.js` draws the window chrome, the cards
and the thumbnail stand-ins, `src/files.js` the sample files; each `src/*.html` is one screen (`#dark` in the URL
switches to dark appearance). Render everything, or some screens:

```sh
sh docs/mockups/render.sh                      # all screens
sh docs/mockups/render.sh window-cards.html    # one screen (and its dark variant if it has one)
```

The script runs Chrome headless with a throwaway profile in `docs/mockups/.chrome-profile/` (git-ignored) and
`--allow-file-access-from-files`, so the pages can load SF Pro Rounded from `/System/Library/Fonts/SFNSRounded.ttf`.
They must be rendered on a Mac.
