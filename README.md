# claude-desktop-nord

A [Nord](https://www.nordtheme.com/) theme for the Claude desktop app on Windows, plus a small tool that re-applies it every time Claude starts.

Light mode is left alone; dark mode becomes Nord. The theme also switches the UI to JetBrains Mono and makes inline code and code blocks easier to pick out.

Nothing in Claude's own files is changed, and no debugging port is opened. Run Claude without the watcher and you get the stock look.

## How it works

The theme is a DevTools **snippet** (`theme/nordtheme.js`) that adds one `<style>` element overriding Claude's design-system CSS variables (`--cds-*`, `--bg-*`, `--text-*`, `--df-*`) and keeps it last in `<head>`.

Claude forgets snippets' effects on every restart, so `claude-theme.ps1` does the manual steps for you:

1. opens Claude's DevTools (Ctrl+Alt+I) **hidden**: fully transparent, off-screen, no taskbar button;
2. runs the saved snippet through DevTools' Ctrl+P menu (`!nordtheme`);
3. closes DevTools again.

To know when Claude is ready and whether the theme took, it samples a few pixels of Claude's own window (via `PrintWindow`, so other windows can't fool it): stock dark mode is neutral grey, Nord is blue-grey.

Safety rules built into the watcher:

- keys are only sent while the right window is in front; if focus moves, it stops before the next keystroke, so nothing lands in a chat box;
- it only acts while Claude is the foreground window and you've paused typing;
- at most 6 attempts per Claude session (with backoff) and 10 re-applies after reloads, then it waits for the next launch.

## Files

```
claude-theme.ps1        the tool: apply once, or watch and re-apply at every launch
theme/nordtheme.js      the DevTools snippet (what Claude actually runs)
theme/nord.css          the same CSS on its own, for other injectors or the Theme Tuner
extras/glazewm.yaml     GlazeWM rules: keep the hidden DevTools out of tiling, hotkey to re-apply
legacy/                 first version (Node, DevTools port); superseded, see legacy/README.md
```

## Setup

1. **Enable Developer Mode** in Claude: *Help > Troubleshooting > Enable Developer Mode*.
2. Open DevTools (Ctrl+Alt+I) > **Sources > Snippets > + New snippet**, name it `nordtheme`, paste the contents of `theme/nordtheme.js`, save (Ctrl+S) and run it once (Ctrl+Enter).
3. Put `claude-theme.ps1` somewhere permanent (e.g. `~\bin`) and install the watcher:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File $HOME\bin\claude-theme.ps1 -Install
```

That registers a per-user scheduled task, **Claude theme (re-apply snippet)**, that starts at logon (and right away) and runs hidden. No admin rights needed.

## Usage

| Command | What it does |
|---|---|
| `claude-theme` | Apply once now (Claude must be open) |
| `claude-theme -Watch` | Keep Claude themed: every launch, retries until confirmed, and after reloads |
| `claude-theme -Install` | Start the watcher at logon (and now) |
| `claude-theme -Uninstall` | Remove the watcher task |
| `claude-theme -ShowDevTools` | Pause the watcher and show DevTools on screen so you can edit the snippet; closing DevTools restarts the watcher |
| `-Snippet <name>` | Run a different saved snippet (default `nordtheme`) |

Log: `%LOCALAPPDATA%\claude-theme.log` (rotates at 256 KB).

## Editing the theme

Run `claude-theme -ShowDevTools`, edit the `nordtheme` snippet, save with Ctrl+S, run with Ctrl+Enter, then close DevTools. Keep `theme/nordtheme.js` in sync if you track it here.

You can also design a theme in the [Claude Desktop Theme Tuner](https://rinn7e.com/claude-desktop-theme-tuner/) and save its snippet under a new name, then pass `-Snippet <name>`.

## Notes

- If some colours stop changing after a Claude update, Claude has renamed its CSS variables; the snippet needs updating.
- The colour check assumes Nord. If you switch to a very different theme, adjust `CT.Fast.Look` in the script.
- Windows only (Win32 window APIs).

## Credits

- Variable-override approach from the Clay theme by Maxime Bories (MIT).
- Snippet format from [Claude Desktop Theme Tuner](https://github.com/rinn7e/claude-desktop-theme-tuner).
- Colours: [Nord](https://www.nordtheme.com/) by Arctic Ice Studio.

## License

MIT, see `LICENSE`.
