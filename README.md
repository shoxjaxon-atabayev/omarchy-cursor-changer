# omarchy-cursor-changer

A minimal, native Omarchy plugin for discovering, previewing, and applying installed XCursor themes.

> Discover → Preview → Select → Apply

It is not a cursor editor and does not create, download, or modify cursor themes — it manages the ones already installed on your system.

## What it does

Open the plugin and it scans your system for installed XCursor themes (real cursor themes — not icon themes), renders a real preview of each one directly from its actual cursor bitmaps, and shows them in a grid alongside whichever theme is currently active. Pick a different one, hit **Apply**, and it's applied across Hyprland and your GTK/Qt apps. Nothing on your system changes until you click Apply — selecting a card is always non-destructive.

```
┌─────────────────────────────────────────────────────────┐
│  Cursor                                                  │
│  Choose a cursor style for your desktop                  │
│                                                           │
│  ┌────────────────────┐  ┌────────────────────┐          │
│  │  ↖  I  ⌛ ↔  ✋      │  │  ↖  I  ⌛ ↔  ✋      │          │
│  │   Adwaita           │  │   Yaru               │        │
│  │   ● Active          │  │                       │       │
│  └────────────────────┘  └────────────────────┘          │
│                                                           │
│                                     [ Cancel ]  [ Apply ] │
└─────────────────────────────────────────────────────────┘
```

(The preview strips above are drawn from real, actual pixel data extracted from each theme's XCursor files — not the arrows shown in this ASCII mockup.)

## Installation

```bash
git clone https://github.com/shoxjaxon-atabayev/omarchy-cursor-changer.git ~/.config/omarchy/plugins/community.shoxjaxon.cursor-changer
omarchy-shell shell rescanPlugins
omarchy plugin enable community.shoxjaxon.cursor-changer
```

Or, from within Omarchy:

```bash
omarchy plugin add https://github.com/shoxjaxon-atabayev/omarchy-cursor-changer.git --enable
```

## Usage

The plugin is an overlay (the same kind of surface as Omarchy's clipboard manager and image picker), summoned on demand — it does not run a background process or add anything to the bar by itself.

Summon it:

```bash
omarchy-shell shell toggle community.shoxjaxon.cursor-changer
```

Bind it to a key by adding a line to `~/.config/hypr/bindings.lua`, for example:

```lua
o.bind("SUPER + CTRL + C", "Cursor", "omarchy-shell shell toggle community.shoxjaxon.cursor-changer")
```

(This plugin does not add the binding for you — see [Configuration ownership](#configuration-ownership) below for why.)

Inside the overlay:

| Action | Result |
|---|---|
| Click a card | Selects it locally. Nothing on the system changes yet. |
| `Tab` / `Shift+Tab` | Move the keyboard cursor between Import, the theme grid, Cancel, and Apply. |
| Arrow keys (grid focused) | Move the highlighted card. |
| `Enter` / `Space` (grid focused) | Select the highlighted card. |
| `Enter` (Apply focused) | Apply the selected theme. |
| `Escape` | Discard any unapplied selection and close — works no matter which control currently has the keyboard cursor. |
| **Apply** | Applies the selected theme system-wide. Disabled when the selection matches what's already active. |
| **Cancel** | Same as Escape. |
| **Import…** | Pick a cursor theme you've already downloaded (a folder or a `.tar.gz`/`.tar.xz`/`.tar.bz2`/`.zip` archive) and add it to `~/.local/share/icons` — see [Importing a downloaded cursor pack](#importing-a-downloaded-cursor-pack). |

The whole overlay is driven from a single keyboard-focus owner (there is deliberately no native per-widget Tab chain), specifically so `Escape` always works regardless of which control the keyboard cursor is currently on.

## Importing a downloaded cursor pack

This plugin doesn't search the internet for cursor themes and isn't a marketplace (see `SPEC.md`'s non-goals) — but if you've already downloaded a cursor pack yourself, click **Import…** (top-right of the header, or the equivalent button in the empty state) to pick it from your filesystem via the normal desktop file picker. It accepts:

- a plain folder (a `cursors/` subdirectory, optionally with an `index.theme`), or
- an archive: `.tar.gz`/`.tgz`, `.tar.xz`, `.tar.bz2`, `.tar`, or `.zip`.

Archives are extracted into an isolated temp directory first — nothing is ever written to `~/.local/share/icons` until the extracted content is confirmed to actually be a cursor theme. Real-world downloaded packs are often wrapped in one or two extra folders (a README/screenshots directory, a version-numbered release folder), so the importer searches a few levels deep for the actual theme rather than assuming it sits at the archive root. If a theme with the same name is already installed, the import is refused rather than silently overwriting it.

You can also skip the plugin entirely and place a theme directly under `~/.local/share/icons/<theme-name>/` (or `~/.icons/<theme-name>/`) yourself — the **Import…** button is a convenience for exactly that, not a new mechanism.

## Supported cursor themes

Any theme that follows the standard [XCursor](https://www.x.org/releases/X11R7.7/doc/man/man3/Xcursor.3.xhtml) layout — a directory with a `cursors/` subfolder — is discovered automatically. This covers essentially everything packaged for Linux desktops: Adwaita, Yaru, Bibata, Capitaine, Nordzy, and so on, whether installed system-wide (`/usr/share/icons`) or per-user (`~/.local/share/icons`, `~/.icons`).

Themes are discovered from, in priority order:

1. `~/.icons`
2. `$XDG_DATA_HOME/icons` (usually `~/.local/share/icons`)
3. Every `icons` directory under `$XDG_DATA_DIRS` (usually `/usr/local/share` and `/usr/share`)

If the same theme name shows up in more than one location, the user-installed copy wins and only one card is shown. `Inherits=` chains (a theme borrowing cursors from a parent theme) are resolved automatically, including multi-level chains, with protection against inheritance cycles.

Themes that declare cursor roles under different filenames (e.g. `default` vs `left_ptr`, `watch` vs `wait`, `hand2` vs `pointer`) are still recognized — each role tries several known aliases before being treated as unavailable.

## Known limitations

- **Cursor size is not editable here.** Applying a theme keeps whatever size is already configured (defaulting to 24px if none is set). A cursor size editor is explicitly out of scope — see `SPEC.md`.
- **Already-running apps may not update their cursor instantly.** Apps that support server-side cursor rendering (Qt, Chromium/Electron, and the rest of the Hypr ecosystem) pick up `hyprctl setcursor` immediately. GTK apps specifically do not use server-side cursors and instead need `XCURSOR_THEME` and `gsettings set org.gnome.desktop.interface cursor-theme` — which this plugin sets — but a GTK app that already cached the old theme at its own startup still won't refresh until it's restarted. This is a real, current Hyprland/GTK behavior, not something a plugin can work around without restarting your other applications for you ([Hyprland FAQ](https://wiki.hypr.land/FAQ/)).
- **The visible pointer sometimes only redraws on the next mouse move.** This is a known, currently-accepted Hyprland behavior, not specific to this plugin — see [hyprwm/Hyprland#4221](https://github.com/hyprwm/Hyprland/issues/4221). If the cursor doesn't look different immediately after Apply, move the mouse; `gsettings get org.gnome.desktop.interface cursor-theme` will already show the new value even before the pointer visually catches up.
- **Reboot persistence covers the cursor theme, not custom sizes**, and relies on a post-boot hook (see [Architecture](#architecture)) rather than a Hyprland config option, because `hyprctl setcursor` is a live, session-scoped IPC call, not a persistent setting.
- **No cursor themes found in some minimal installs.** If nothing shows up, install a cursor theme package (e.g. `pacman -S bibata-cursor-theme` or similar for your theme of choice) and reopen the plugin.

## Architecture

```
Discovery → Parsing/Inheritance → Preview render → Preview cache → Apply → Verify → Persist
```

Everything filesystem/subprocess-related lives in small, independently runnable, independently testable shell/Python scripts under `bin/`; the QML layer (`Main.qml`, `ThemeCard.qml`) is a thin presentation layer that shells out to them asynchronously via `Quickshell.Io.Process` and never touches cursor files, `gsettings`, or `hyprctl` directly.

| Script | Responsibility |
|---|---|
| `bin/omarchy-cursor-changer-discover` | Scans the XDG icon paths, filters to real cursor themes (has a non-empty `cursors/`), dedupes user-over-system, returns sorted JSON. |
| `bin/omarchy-cursor-changer-resolve` | Parses `index.theme` (`Name=`, `Inherits=`), walks the inheritance chain (cycle-safe), resolves each cursor role via a small alias table. |
| `bin/lib/xcursor_preview.py` | Parses the XCursor binary format directly (stdlib only — no Pillow/ImageMagick), composites several real cursor roles into one transparent-background PNG strip. |
| `bin/omarchy-cursor-changer-preview` | Wraps the above with a content-fingerprinted cache under `~/.cache/omarchy/cursor-changer/previews/`. |
| `bin/omarchy-cursor-changer-apply` | Validates the theme, applies it via `hyprctl setcursor` (live Hyprland/XWayland cursor) then `gsettings set org.gnome.desktop.interface cursor-theme`/`cursor-size` (GTK/Qt), verifies the change stuck, persists plugin state, installs the post-boot hook, and rolls back whatever it changed if any step fails. |
| `bin/omarchy-cursor-changer-state` | Reads back the plugin's own persisted state (never errors on a missing/corrupt file). |
| `bin/omarchy-cursor-changer-import` | Validates and installs a local theme directory or archive into `~/.local/share/icons` (extraction always goes through an isolated temp directory first). |
| `bin/omarchy-cursor-changer-import-pick` | Wraps the above with Omarchy's own `omarchy-file-select` desktop file chooser, for the UI's **Import…** button. |
| `bin/omarchy-cursor-changer-reapply.hook` | Installed into `~/.config/omarchy/hooks/post-boot.d/`; re-issues `hyprctl setcursor` on the next login, since that call is session-scoped and Hyprland has no persistent "default cursor theme" config option of its own. |

**Source of truth:** the plugin's own `~/.local/state/omarchy/cursor-changer/state.json` for "what did this plugin last apply," cross-referenced with `gsettings get org.gnome.desktop.interface cursor-theme` for "what do GTK/Qt currently see." No separate UI-owned database — reopening the plugin always re-derives active/selected state from these two.

### Configuration ownership

The plugin never edits `~/.config/hypr/*.lua`, `~/.config/omarchy/hooks/theme-set.d/`, or any file it doesn't itself own. The only files it writes are its own state file, its own preview cache, and the one hook script listed above (idempotently installed/updated, never touching anything else in `post-boot.d/`). Applying a theme uses only two already-standard mechanisms — `hyprctl setcursor` and `gsettings` — the same tools Omarchy's own theme system uses for the equivalent icon-theme setting. No `sudo`, no root, no background daemon.

## Troubleshooting

**"No cursor themes found"**
No directory in the search path above has a real cursor theme (a `cursors/` folder with actual files) — install one and reopen the plugin.

**A theme's preview looks empty or a role is missing an icon**
That theme doesn't ship (or inherit) a cursor for that particular role; the plugin falls back to the theme's own pointer cursor for missing roles, and skips a role's cell entirely only if nothing in the theme or its inheritance chain resolves anything at all. This does not affect Apply — the underlying `hyprctl`/`gsettings` mechanism uses the whole theme, not just the previewed roles.

**Apply reports "Couldn't apply cursor theme"**
The previous cursor theme is left untouched — the plugin captures the prior state before making any change and rolls back automatically on failure. Common causes: the theme was deleted from disk after the plugin scanned it, or `hyprctl`/`gsettings` are unavailable (only expected outside a real Hyprland session).

**The cursor looks right in most apps but not one specific app**
That app likely cached the old cursor theme at its own startup (see [Known limitations](#known-limitations)) — restart it.

**Apply reported success but the pointer still looks the same**
Move the mouse — Hyprland sometimes only redraws the visible pointer on the next motion event, not the instant `hyprctl setcursor` runs (see [Known limitations](#known-limitations)). You can confirm the change actually took effect independently of what's on screen with `gsettings get org.gnome.desktop.interface cursor-theme`.

**Escape/keybindings didn't close the overlay in an older build of this plugin**
Fixed: earlier versions gave the theme grid its own real keyboard focus, which made it a focus *sibling* of the Escape handler rather than a descendant, so Escape was silently dropped whenever the grid (or a button) held focus. All keyboard handling now runs through a single owner for exactly this reason — see the comment above `focusZone` in `Main.qml`.

**Debugging**
Every `bin/omarchy-cursor-changer-*` script can be run directly from a terminal and prints JSON or a clear error to stdout/stderr — this is the fastest way to isolate whether an issue is in discovery/parsing/preview/apply or in the UI layer on top of it.

```bash
~/.config/omarchy/plugins/community.shoxjaxon.cursor-changer/bin/omarchy-cursor-changer-discover | jq .
~/.config/omarchy/plugins/community.shoxjaxon.cursor-changer/bin/omarchy-cursor-changer-state | jq .
```

## Development

```bash
for t in test/shell/*.sh; do [[ $t == *base-test.sh ]] || bash "$t"; done
omarchy-plugin-validate ~/.config/omarchy/plugins/community.shoxjaxon.cursor-changer
```

`SPEC.md` (kept local, not published — see `.gitignore`) is the full product/technical specification this plugin was built against.

## License

MIT — see `LICENSE`.
