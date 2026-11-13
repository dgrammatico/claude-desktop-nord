#!/usr/bin/env node
// Claude desktop theme injector.
//
// Starts the Claude desktop app with a local Chrome DevTools Protocol port, then
// injects a CSS theme into every Claude window: right away, and again before each
// page (re)load, for as long as Claude runs. It does the same thing as running the
// Theme Tuner snippet by hand from DevTools > Sources > Snippets, without the
// clicks, and without touching the app's files (no app.asar patching).
//
// Needs Node.js 22 or newer (built-in fetch and WebSocket). No npm packages.
//
//   node claude-theme.mjs                     launch Claude themed and keep it themed
//   node claude-theme.mjs --restart           quit a running Claude first, then launch
//   node claude-theme.mjs --theme my.css      use another CSS file (default: themes/nord.css)
//   node claude-theme.mjs --install-shortcut  add a "Claude (Themed)" launcher
//   node claude-theme.mjs --remove-shortcut   remove that launcher
//
// Environment: CLAUDE_PATH (path to the Claude executable), CLAUDE_THEME_PORT.

import { spawn, execFileSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync, rmSync, mkdirSync, readdirSync, statSync } from "node:fs";
import { homedir, platform } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const STYLE_ID = "claude-theme-tuner-theme";
const SHORTCUT_NAME = "Claude (Themed)";
const OS = platform();

// ---------- arguments ----------

function parseArgs(argv) {
  const opts = {
    theme: join(HERE, "themes", "nord.css"),
    port: Number(process.env.CLAUDE_THEME_PORT) || 9333,
    claude: process.env.CLAUDE_PATH || "",
    restart: false,
    install: false,
    remove: false,
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const val = () => {
      const v = argv[++i];
      if (v === undefined) fail(`${a} needs a value`);
      return v;
    };
    if (a === "--theme") opts.theme = resolve(val());
    else if (a === "--port") opts.port = Number(val());
    else if (a === "--claude") opts.claude = resolve(val());
    else if (a === "--restart") opts.restart = true;
    else if (a === "--install-shortcut") opts.install = true;
    else if (a === "--remove-shortcut") opts.remove = true;
    else if (a === "-h" || a === "--help") {
      console.log(readFileSync(fileURLToPath(import.meta.url), "utf8").split("\n").slice(1, 19).map((l) => l.replace(/^\/\/ ?/, "")).join("\n"));
      process.exit(0);
    } else fail(`unknown option ${a} (try --help)`);
  }
  if (!Number.isInteger(opts.port) || opts.port < 1024 || opts.port > 65535) fail("--port must be 1024-65535");
  return opts;
}

function log(...m) {
  console.log(`[claude-theme ${new Date().toLocaleTimeString()}]`, ...m);
}
function fail(msg) {
  console.error(`[claude-theme] ${msg}`);
  process.exit(1);
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---------- the script injected into each Claude page ----------

// Same behaviour as the Theme Tuner snippet: one <style>, kept last in <head>.
// It also copes with running at document start, before <head> exists.
export function buildPayload(css) {
  return `(() => {
  const ID = ${JSON.stringify(STYLE_ID)};
  const css = ${JSON.stringify(css)};
  const apply = () => {
    document.getElementById("user-solarized-light-theme")?.remove();
    let el = document.getElementById(ID);
    if (!el) {
      el = document.createElement("style");
      el.id = ID;
      document.head.appendChild(el);
    }
    if (el.textContent !== css) el.textContent = css;
    if (!el.dataset.pinned) {
      el.dataset.pinned = "1";
      // Keep the override last in <head> so stylesheets loaded later do not outrank it.
      new MutationObserver(() => {
        if (el.isConnected && document.head.lastElementChild !== el) document.head.appendChild(el);
      }).observe(document.head, { childList: true });
    }
  };
  if (document.head) apply();
  else {
    const wait = new MutationObserver(() => {
      if (document.head) { wait.disconnect(); apply(); }
    });
    wait.observe(document, { childList: true, subtree: true });
  }
})();`;
}

// ---------- finding and launching Claude ----------

function findClaude(explicit, quiet = false) {
  if (explicit) {
    if (!existsSync(explicit)) return quiet ? "" : fail(`Claude not found at ${explicit}`);
    return explicit;
  }
  const candidates = [];
  if (OS === "darwin") {
    candidates.push("/Applications/Claude.app/Contents/MacOS/Claude", join(homedir(), "Applications/Claude.app/Contents/MacOS/Claude"));
  } else if (OS === "win32") {
    const local = process.env.LOCALAPPDATA || join(homedir(), "AppData", "Local");
    candidates.push(join(local, "AnthropicClaude", "claude.exe"));
    candidates.push(...msixClaude());
  } else {
    candidates.push("/usr/bin/claude-desktop", "/opt/Claude/claude", "/usr/lib/claude-desktop/claude");
  }
  const found = candidates.find((p) => p && existsSync(p));
  if (!found && !quiet) fail(`could not find the Claude desktop app. Looked in:\n  ${candidates.join("\n  ")}\nSet CLAUDE_PATH or pass --claude <path to the Claude executable>.`);
  return found || "";
}

// The Microsoft Store / MSIX build lives under WindowsApps.
function msixClaude() {
  try {
    const out = execFileSync("powershell.exe", ["-NoProfile", "-Command", "(Get-AppxPackage -Name '*Claude*').InstallLocation"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] });
    const hits = [];
    for (const dir of out.split(/\r?\n/).map((s) => s.trim()).filter(Boolean)) {
      for (const sub of ["", "app"]) {
        const p = join(dir, sub, "claude.exe");
        if (existsSync(p)) hits.push(p);
      }
    }
    return hits;
  } catch {
    return [];
  }
}

// PIDs of a running Claude desktop app (not the Claude Code CLI, which is also "claude").
function runningClaudePids() {
  try {
    if (OS === "darwin") {
      return execFileSync("pgrep", ["-x", "Claude"], { encoding: "utf8" }).split("\n").filter(Boolean);
    }
    if (OS === "win32") {
      const ps = "Get-Process claude -ErrorAction SilentlyContinue | Where-Object { $_.Path -match 'AnthropicClaude|WindowsApps' } | ForEach-Object { $_.Id }";
      return execFileSync("powershell.exe", ["-NoProfile", "-Command", ps], { encoding: "utf8" }).split(/\r?\n/).map((s) => s.trim()).filter(Boolean);
    }
  } catch {
    /* none running */
  }
  return [];
}

async function quitClaude() {
  log("quitting the running Claude app");
  try {
    if (OS === "darwin") execFileSync("osascript", ["-e", 'quit app "Claude"']);
    else if (OS === "win32") for (const pid of runningClaudePids()) execFileSync("taskkill", ["/PID", pid, "/T"], { stdio: "ignore" });
  } catch {
    /* fall through to the wait */
  }
  for (let i = 0; i < 40 && runningClaudePids().length; i++) await sleep(500);
  if (runningClaudePids().length) fail("Claude did not quit; close it yourself and run this again.");
}

function launchClaude(exe, port) {
  log(`starting ${exe}`);
  const child = spawn(exe, [`--remote-debugging-port=${port}`], { detached: true, stdio: "ignore" });
  child.on("error", (e) => fail(`could not start Claude: ${e.message}`));
  child.unref();
}

// ---------- DevTools protocol ----------

async function listTargets(port) {
  const res = await fetch(`http://127.0.0.1:${port}/json/list`, { signal: AbortSignal.timeout(2000) });
  return res.json();
}

async function portIsOpen(port) {
  try {
    await listTargets(port);
    return true;
  } catch {
    return false;
  }
}

// One open DevTools session per Claude page. The session must stay open: scripts
// added with Page.addScriptToEvaluateOnNewDocument are dropped when it closes.
function attach(target, payload, onClose) {
  const ws = new WebSocket(target.webSocketDebuggerUrl);
  let id = 0;
  const send = (method, params = {}) => ws.send(JSON.stringify({ id: ++id, method, params }));
  ws.addEventListener("open", () => {
    send("Page.enable"); // without it, the new-document script is not run on reloads
    send("Page.addScriptToEvaluateOnNewDocument", { source: payload });
    send("Runtime.evaluate", { expression: payload });
    log(`themed ${target.url}`);
  });
  ws.addEventListener("message", (ev) => {
    const msg = JSON.parse(ev.data);
    if (msg.error) log(`DevTools error on ${target.url}: ${msg.error.message}`);
    else if (msg.result?.exceptionDetails) log(`theme script failed on ${target.url}: ${msg.result.exceptionDetails.text}`);
  });
  ws.addEventListener("close", onClose);
  ws.addEventListener("error", () => {});
  return ws;
}

const themeable = (t) => (t.type === "page" || t.type === "webview") && t.webSocketDebuggerUrl && !/^(devtools|chrome|chrome-extension):/.test(t.url);

async function run(opts) {
  if (!existsSync(opts.theme)) fail(`theme file not found: ${opts.theme}`);
  const payload = buildPayload(readFileSync(opts.theme, "utf8"));

  if (!(await portIsOpen(opts.port))) {
    if (runningClaudePids().length) {
      if (!opts.restart) fail("Claude is already running without the theme port. Quit Claude and run this again, or add --restart.");
      await quitClaude();
    }
    launchClaude(findClaude(opts.claude), opts.port);
    let up = false;
    for (let i = 0; i < 120 && !(up = await portIsOpen(opts.port)); i++) await sleep(500);
    if (!up) fail(`Claude started but its DevTools port ${opts.port} never opened. This Claude build may not allow --remote-debugging-port.`);
  } else {
    log(`Claude is already listening on port ${opts.port}; attaching`);
  }

  const sessions = new Map(); // target id -> WebSocket
  let misses = 0;
  log(`theme ${opts.theme} active; this keeps running until Claude quits (Ctrl+C stops theming new windows)`);
  for (;;) {
    let targets;
    try {
      targets = await listTargets(opts.port);
      misses = 0;
    } catch {
      if (++misses >= 3) break; // Claude has quit
      await sleep(1000);
      continue;
    }
    for (const t of targets.filter(themeable)) {
      if (!sessions.has(t.id)) sessions.set(t.id, attach(t, payload, () => sessions.delete(t.id)));
    }
    await sleep(1500);
  }
  log("Claude quit; done");
  process.exit(0);
}

// ---------- launcher shortcuts ----------

function installShortcut(opts) {
  const node = process.execPath;
  const script = fileURLToPath(import.meta.url);
  const extra = opts.theme !== join(HERE, "themes", "nord.css") ? ` --theme "${opts.theme}"` : "";
  if (OS === "darwin") {
    const app = join(homedir(), "Applications", `${SHORTCUT_NAME}.app`);
    const logFile = join(homedir(), "Library", "Logs", "claude-theme.log");
    mkdirSync(dirname(app), { recursive: true });
    const sh = `'${node}' '${script}' --restart${extra.replace(/"/g, "'")} > '${logFile}' 2>&1 &`;
    const as = `do shell script ${JSON.stringify(sh)}`;
    rmSync(app, { recursive: true, force: true });
    execFileSync("osacompile", ["-o", app, "-e", as]);
    const icon = "/Applications/Claude.app/Contents/Resources/electron.icns";
    if (existsSync(icon)) execFileSync("cp", [icon, join(app, "Contents", "Resources", "applet.icns")]);
    log(`created ${app}. Open it (or drag it to the Dock) instead of Claude.`);
    log("To start it at login: System Settings > General > Login Items > + and pick it.");
  } else if (OS === "win32") {
    const vbs = join(HERE, "claude-theme-launch.vbs");
    const cmd = `"${node}" "${script}" --restart${extra}`;
    writeFileSync(vbs, `' Starts Claude with the theme, without a console window.\r\nCreateObject("WScript.Shell").Run "${cmd.replace(/"/g, '""')}", 0, False\r\n`);
    const icon = findClaude(opts.claude, true);
    const q = (v) => v.replace(/'/g, "''"); // PowerShell single-quoted string
    const ps = `
$s = New-Object -ComObject WScript.Shell
foreach ($dir in @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs'))) {
  $l = $s.CreateShortcut((Join-Path $dir '${SHORTCUT_NAME}.lnk'))
  $l.TargetPath = 'wscript.exe'
  $l.Arguments = '"${q(vbs)}"'
  $l.WorkingDirectory = '${q(HERE)}'
  if ('${q(icon)}') { $l.IconLocation = '${q(icon)},0' }
  $l.Save()
  Write-Output (Join-Path $dir '${SHORTCUT_NAME}.lnk')
}`;
    const out = execFileSync("powershell.exe", ["-NoProfile", "-Command", ps], { encoding: "utf8" });
    log(`created:\n${out.trim()}\nUse it (pin it to the taskbar) instead of the normal Claude shortcut.`);
    log("To start it at login, copy the shortcut into shell:startup (Win+R, type shell:startup).");
  } else {
    fail("shortcuts are only made on macOS and Windows; run this script from your own launcher instead.");
  }
}

function removeShortcut() {
  if (OS === "darwin") {
    rmSync(join(homedir(), "Applications", `${SHORTCUT_NAME}.app`), { recursive: true, force: true });
  } else if (OS === "win32") {
    const ps = `foreach ($dir in @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs'))) { Remove-Item -ErrorAction SilentlyContinue (Join-Path $dir '${SHORTCUT_NAME}.lnk') }`;
    execFileSync("powershell.exe", ["-NoProfile", "-Command", ps]);
    rmSync(join(HERE, "claude-theme-launch.vbs"), { force: true });
  }
  log("launcher removed");
}

// ---------- main ----------

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [major] = process.versions.node.split(".").map(Number);
  if (major < 22) fail(`needs Node.js 22 or newer (this is ${process.versions.node})`);
  const opts = parseArgs(process.argv.slice(2));
  if (opts.install) installShortcut(opts);
  else if (opts.remove) removeShortcut();
  else await run(opts);
}
