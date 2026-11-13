> **Superseded.** This was the first version. It starts Claude with a local Chrome DevTools
> Protocol port (`--remote-debugging-port`), which endpoint security tools can flag as an
> infostealer pattern, and anything on the machine can use that port to drive your signed-in
> session. Use `claude-theme.ps1` in the repo root instead. Kept for reference only.
> In this folder the default theme path doesn't exist; pass `--theme ../theme/nord.css`.

# Claude desktop theme injector

Applies a CSS theme (default: `themes/nord.css`, dark mode = Nord, light mode
untouched) to the Claude desktop app **every time it launches**, so you no longer
have to open DevTools and re-run the snippet by hand after each restart.

It does exactly what the [Claude Desktop Theme Tuner](https://github.com/rinn7e/claude-desktop-theme-tuner)
snippet does (one `<style>` element, kept last in `<head>`) but automatically:

1. starts Claude with a local DevTools port (`--remote-debugging-port`, default 9333),
2. injects the theme into every Claude window right away **and** before every
   reload or new window, for as long as Claude runs,
3. exits by itself when you quit Claude.

The Claude app's files are not modified (no `app.asar` patching), so app updates
don't break or undo anything. Run Claude the normal way and you get the stock look.

## Requirements

- macOS or Windows with the Claude desktop app installed.
- [Node.js](https://nodejs.org) 22 or newer (`node --version`). No `npm install` needed.

## Use it

Quit Claude, then:

```bash
node claude-theme.mjs
```

If Claude is already open, `--restart` quits it first:

```bash
node claude-theme.mjs --restart
```

### Make it the way you open Claude (every launch)

```bash
node claude-theme.mjs --install-shortcut
```

- **macOS:** creates `~/Applications/Claude (Themed).app`. Open it (or keep it in
  the Dock) instead of Claude. For login, add it under System Settings > General >
  Login Items. Log: `~/Library/Logs/claude-theme.log`.
- **Windows:** creates a **Claude (Themed)** shortcut on the Desktop and in the
  Start menu (it runs silently, with no console window). Pin it to the taskbar in
  place of the normal Claude shortcut. For login, copy it into `shell:startup`.

The shortcut uses `--restart`, so it also works if Claude is already open.
Remove it with `node claude-theme.mjs --remove-shortcut`.

## Options

| Option | Meaning |
| --- | --- |
| `--theme <file.css>` | Use another CSS file, e.g. a new export from the Theme Tuner. Pass it to `--install-shortcut` too so the launcher uses it. |
| `--restart` | Quit a running Claude first. |
| `--port <n>` / `CLAUDE_THEME_PORT` | DevTools port (default 9333). |
| `--claude <path>` / `CLAUDE_PATH` | Claude executable, if it isn't found automatically. |

Default locations it looks in: `/Applications/Claude.app` (and `~/Applications`)
on macOS; `%LOCALAPPDATA%\AnthropicClaude\claude.exe` and the Microsoft Store
(MSIX) package on Windows.

### Changing the theme

Design a theme at <https://rinn7e.com/claude-desktop-theme-tuner/>, copy the
snippet, and paste **only the CSS** (the text between the backticks of
`` const css = `...` ``) into a new `.css` file under `themes/`. Then run with
`--theme themes/<name>.css`.

## Security note

While Claude runs this way, the DevTools port is open on `127.0.0.1` (this
computer only, not the network). Any program on your computer could use it to
control the Claude window, including your signed-in session. Only use it on a
computer you trust. Run Claude normally to close the port.

## Troubleshooting

- **"Claude is already running without the theme port"**: quit Claude fully
  (on Windows also from the system tray) or add `--restart`.
- **"DevTools port never opened"**: that Claude build doesn't accept
  `--remote-debugging-port`. On the Microsoft Store build, try the installer from
  claude.ai/download, or fall back to the manual snippet.
- **Some colors don't change after a Claude update**: Claude renamed its CSS
  variables. Re-export the theme from the Theme Tuner once it supports the new version.
