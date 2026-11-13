# claude-theme.ps1 - re-applies a saved DevTools snippet (your Claude theme) automatically.
#
#   claude-theme              apply now (Claude must be open)
#   claude-theme -Watch       keep Claude themed: every launch, retries until confirmed, and after reloads
#   claude-theme -Install     start the watcher at logon (and now)
#   claude-theme -Uninstall   remove the watcher task
#   claude-theme -ShowDevTools  pause the watcher and show DevTools on screen (to edit the snippet);
#                             closing DevTools restarts the watcher and re-applies the theme
#   -Snippet <name>           snippet to run (default: nordtheme)
#
# It does the tuner's manual steps: opens DevTools, runs the snippet through DevTools' Ctrl+P
# menu ("!name" runs a saved snippet) and closes DevTools. DevTools is kept off-screen and
# transparent. To know when the page is ready and whether the theme took, it samples a few
# pixels of Claude's window: stock dark mode is neutral grey (#191919..#303030), Nord is
# blue-grey (#272C36, #2E3440, #3B4252). Light mode is left alone.
# Before every keystroke it checks the right window is in front and stops if not, so keys never
# land in a chat box. Nothing in Claude's files is changed.
param([string]$Snippet = 'nordtheme', [switch]$Watch, [switch]$Install, [switch]$Uninstall, [switch]$ShowDevTools)
$ErrorActionPreference = 'Stop'
$TaskName = 'Claude theme (re-apply snippet)'
$LogFile  = Join-Path $env:LOCALAPPDATA 'claude-theme.log'

function Log([string]$m) {
    if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 256KB) { Move-Item $LogFile "$LogFile.old" -Force }
    Add-Content $LogFile ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss.fff'), $m)
    if (-not $Watch) { Write-Host $m }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -Namespace CT -Name Win -MemberDefinition @'
public struct RECT { public int L, T, R, B; }
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool IsIconic(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool IsWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool PostMessage(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, System.UIntPtr extra);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(System.IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
public delegate bool EnumProc(System.IntPtr h, System.IntPtr l);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, System.IntPtr l);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern int GetWindowLong(System.IntPtr h, int i);
[DllImport("user32.dll")] public static extern int SetWindowLong(System.IntPtr h, int i, int v);
[DllImport("user32.dll")] public static extern bool SetLayeredWindowAttributes(System.IntPtr h, uint key, byte alpha, uint flags);
[DllImport("user32.dll")] public static extern bool SetWindowPos(System.IntPtr h, System.IntPtr after, int x, int y, int cx, int cy, uint flags);
[DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern System.IntPtr GetDC(System.IntPtr h);
[DllImport("user32.dll")] public static extern int ReleaseDC(System.IntPtr h, System.IntPtr dc);
[DllImport("gdi32.dll")] public static extern uint GetPixel(System.IntPtr dc, int x, int y);
[DllImport("user32.dll")] public static extern bool PrintWindow(System.IntPtr h, System.IntPtr hdc, uint flags);
public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
[DllImport("user32.dll")] public static extern bool GetLastInputInfo(ref LASTINPUTINFO p);
public static uint IdleMs() { var i = new LASTINPUTINFO(); i.cbSize = 8; GetLastInputInfo(ref i); return (uint)System.Environment.TickCount - i.dwTime; }
'@
Add-Type -AssemblyName System.Drawing
# Hot path in C#: finding Claude's windows and reading its colours ran every 0.7 s in PowerShell
# (scriptblock callbacks + per-pixel calls), which cost minutes of CPU per hour.
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System; using System.Collections.Generic; using System.Diagnostics; using System.Drawing;
using System.Drawing.Imaging; using System.Runtime.InteropServices; using System.Text;
namespace CT {
public static class Fast {
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint f);
    struct RECT { public int L, T, R, B; }
    static readonly HashSet<uint> pids = new HashSet<uint>();
    static DateTime pidsAt = DateTime.MinValue;
    public static IntPtr Main = IntPtr.Zero, Dev = IntPtr.Zero;

    // pid -> is the Claude desktop app (not the Claude Code CLI). MainModule is slow, so each pid
    // is classified once.
    static readonly Dictionary<int, bool> seen = new Dictionary<int, bool>();
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    public static uint[] RefreshPids() {
        pids.Clear();
        var live = new HashSet<int>();
        foreach (var p in Process.GetProcessesByName("claude")) {
            live.Add(p.Id);
            bool isApp;
            if (!seen.TryGetValue(p.Id, out isApp)) {
                try { isApp = p.MainModule.FileName.IndexOf("\\AnthropicClaude\\", StringComparison.OrdinalIgnoreCase) >= 0; } catch { isApp = false; }
                seen[p.Id] = isApp;
            }
            if (isApp) pids.Add((uint)p.Id);
            p.Dispose();
        }
        foreach (var k in new List<int>(seen.Keys)) if (!live.Contains(k)) seen.Remove(k);
        pidsAt = DateTime.UtcNow;
        var a = new uint[pids.Count]; pids.CopyTo(a); return a;
    }
    // Finds Claude's main window ("Claude") and its DevTools window (also when hidden by Hide-Window).
    public static void Scan() {
        Main = IntPtr.Zero; Dev = IntPtr.Zero;
        if (pids.Count == 0 || (DateTime.UtcNow - pidsAt).TotalSeconds > 3) RefreshPids();
        if (pids.Count == 0) return;
        Walk();
        if (Main == IntPtr.Zero && (DateTime.UtcNow - pidsAt).TotalSeconds > 0.5) { RefreshPids(); Walk(); }
    }
    static void Walk() {
        var sb = new StringBuilder(256);
        EnumWindows(delegate (IntPtr h, IntPtr l) {
            if (!IsWindowVisible(h)) return true;
            uint p; GetWindowThreadProcessId(h, out p);
            if (!pids.Contains(p)) return true;
            sb.Length = 0; GetWindowText(h, sb, 256); string t = sb.ToString();
            if (t == "Claude") { if (Main == IntPtr.Zero) Main = h; }
            else if (t.StartsWith("Developer Tools")) { if (Dev == IntPtr.Zero) Dev = h; }
            return true;
        }, IntPtr.Zero);
    }
    // 'nord', 'stock' (dark, untinted), 'light' or 'unknown', read from Claude's own window.
    public static string Look(IntPtr h) {
        if (h == IntPtr.Zero || IsIconic(h)) return "unknown";
        RECT r; if (!GetWindowRect(h, out r)) return "unknown";
        int w = r.R - r.L, ht = r.B - r.T;
        if (w < 300 || ht < 300) return "unknown";
        int nord = 0, stock = 0, light = 0;
        using (var bmp = new Bitmap(w, ht, PixelFormat.Format32bppRgb)) {
            using (var g = Graphics.FromImage(bmp)) {
                IntPtr hdc = g.GetHdc(); bool ok = PrintWindow(h, hdc, 2); g.ReleaseHdc(hdc);
                if (!ok) return "unknown";
            }
            double[,] pts = { { 0.70, 0.30 }, { 0.70, 0.55 }, { 0.90, 0.80 }, { 0.45, 0.20 }, { 0.10, 0.85 } };
            for (int i = 0; i < 5; i++) {
                Color c = bmp.GetPixel((int)(w * pts[i, 0]), (int)(ht * pts[i, 1]));
                int R = c.R, G = c.G, B = c.B; double lum = (R * 0.299 + G * 0.587 + B * 0.114) / 255;
                if (lum > 0.6) light++;
                else if (B - R >= 12 && B - G >= 4 && lum < 0.35) nord++;
                else if (Math.Abs(R - G) <= 6 && Math.Abs(G - B) <= 6 && lum >= 0.04 && lum < 0.25) stock++;
            }
        }
        if (nord >= 2) return "nord"; if (light >= 3) return "light"; if (stock >= 2) return "stock"; return "unknown";
    }
}
}
'@
[void][CT.Win]::SetProcessDPIAware()   # real pixel coordinates on scaled monitors

function Get-Title([IntPtr]$h) { $sb = New-Object Text.StringBuilder 512; [void][CT.Win]::GetWindowText($h, $sb, 512); $sb.ToString() }
function Get-ClaudePids { @([CT.Fast]::RefreshPids()) }

# Visible top-level windows of the Claude desktop app (not the Claude Code CLI)
function Get-ClaudeWindows($pids) {
    $list = New-Object System.Collections.Generic.List[object]
    if (-not $pids) { return $list }
    $cb = [CT.Win+EnumProc]{ param($h, $l)
        if ([CT.Win]::IsWindowVisible($h)) {
            $p = 0; [void][CT.Win]::GetWindowThreadProcessId($h, [ref]$p)
            if ($pids -contains [int]$p) { $t = Get-Title $h; if ($t) { $list.Add([pscustomobject]@{ Handle = $h; Title = $t }) } }
        }
        $true }
    [void][CT.Win]::EnumWindows($cb, [IntPtr]::Zero)
    $list
}
function Get-MainWindow($pids) { [CT.Fast]::Scan(); if ([CT.Fast]::Main -ne [IntPtr]::Zero) { [pscustomobject]@{ Handle = [CT.Fast]::Main; Title = 'Claude' } } }
function Get-DevTools($pids)   { [CT.Fast]::Scan(); if ([CT.Fast]::Dev -ne [IntPtr]::Zero) { [pscustomobject]@{ Handle = [CT.Fast]::Dev; Title = (Get-Title ([CT.Fast]::Dev)) } } }

# What Claude's window is showing: 'nord', 'stock' (dark, untinted), 'light', or 'unknown'
function Get-Look([IntPtr]$h) { [CT.Fast]::Look($h) }
function Get-LookSlow([IntPtr]$h) {   # original PowerShell version, kept for reference
    if ([CT.Win]::IsIconic($h)) { return 'unknown' }
    $r = New-Object CT.Win+RECT
    if (-not [CT.Win]::GetWindowRect($h, [ref]$r)) { return 'unknown' }
    $w = $r.R - $r.L; $ht = $r.B - $r.T
    if ($w -lt 300 -or $ht -lt 300) { return 'unknown' }
    # Render Claude's own window (works even when another window covers it; reading the screen
    # picked up other Nord-coloured apps and reported 'nord' for an untouched Claude).
    $bmp = New-Object Drawing.Bitmap $w, $ht
    $nord = 0; $stock = 0; $light = 0
    try {
        $g = [Drawing.Graphics]::FromImage($bmp); $hdc = $g.GetHdc()
        $ok = [CT.Win]::PrintWindow($h, $hdc, 2)                         # PW_RENDERFULLCONTENT
        $g.ReleaseHdc($hdc); $g.Dispose()
        if (-not $ok) { return 'unknown' }
        foreach ($pt in @(@(0.70, 0.30), @(0.70, 0.55), @(0.90, 0.80), @(0.45, 0.20), @(0.10, 0.85))) {
            $c = $bmp.GetPixel([int]($w * $pt[0]), [int]($ht * $pt[1]))
            $R = $c.R; $G = $c.G; $B = $c.B
            $lum = ($R * 0.299 + $G * 0.587 + $B * 0.114) / 255
            if ($lum -gt 0.6) { $light++ }
            elseif (($B - $R) -ge 12 -and ($B - $G) -ge 4 -and $lum -lt 0.35) { $nord++ }      # blue-grey
            elseif ([Math]::Abs($R - $G) -le 6 -and [Math]::Abs($G - $B) -le 6 -and $lum -ge 0.04 -and $lum -lt 0.25) { $stock++ }   # neutral grey, not black (hidden window)  # neutral grey
        }
    } finally { $bmp.Dispose() }
    if ($nord -ge 2) { 'nord' } elseif ($light -ge 3) { 'light' } elseif ($stock -ge 2) { 'stock' } else { 'unknown' }
}

# Invisible but still able to take keyboard focus: fully transparent, off-screen, no taskbar button
function Hide-Window([IntPtr]$h) {
    $ex = [CT.Win]::GetWindowLong($h, -20)
    if (($ex -band 0x80080) -ne 0x80080) { [void][CT.Win]::SetWindowLong($h, -20, ($ex -bor 0x80000 -bor 0x80)) }
    [void][CT.Win]::SetLayeredWindowAttributes($h, 0, 0, 2)
    [void][CT.Win]::SetWindowPos($h, [IntPtr]::Zero, -32000, -32000, 0, 0, 0x15)
}

# Undo Hide-Window: opaque, normal window again, centered on the primary screen
function Show-Window([IntPtr]$h) {
    $ex = [CT.Win]::GetWindowLong($h, -20)
    [void][CT.Win]::SetLayeredWindowAttributes($h, 0, 255, 2)
    [void][CT.Win]::SetWindowLong($h, -20, ($ex -band (-bnot 0x80080)))
    $s = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $w = [int]($s.Width * 0.7); $ht = [int]($s.Height * 0.8)
    [void][CT.Win]::SetWindowPos($h, [IntPtr]::Zero, $s.X + [int](($s.Width - $w) / 2), $s.Y + [int](($s.Height - $ht) / 2), $w, $ht, 0x64)  # SHOWWINDOW|FRAMECHANGED|NOZORDER
}

function Focus([IntPtr]$h) {
    if ([CT.Win]::GetForegroundWindow() -eq $h) { return $true }
    [CT.Win]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero); [CT.Win]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
    [void][CT.Win]::SetForegroundWindow($h)
    for ($i = 0; $i -lt 30 -and [CT.Win]::GetForegroundWindow() -ne $h; $i++) { Start-Sleep -Milliseconds 10 }
    [CT.Win]::GetForegroundWindow() -eq $h
}

function Send([IntPtr]$h, [string]$keys) {
    if ([CT.Win]::GetForegroundWindow() -ne $h) { throw 'focus moved away; stopped before sending keys' }
    [System.Windows.Forms.SendKeys]::SendWait($keys)
}

function Invoke-Snippet([IntPtr]$dev) {
    if (-not (Focus $dev)) { throw 'could not focus DevTools' }
    Send $dev '{ESC}'
    Start-Sleep -Milliseconds 150
    Send $dev '^p'
    Start-Sleep -Milliseconds 450                 # the Ctrl+P box needs a moment to open
    Send $dev ('!' + $Snippet)
    Start-Sleep -Milliseconds 400                 # ...and to match the snippet name
    Send $dev '{ENTER}'
    Start-Sleep -Milliseconds 400
}

# Opens DevTools hidden. Ctrl+Alt+I is only sent while Claude itself is in front, and is retried
# because Claude ignores it for the first second or two after its window appears.
function Open-DevTools($pids, [IntPtr]$main, [int]$TimeoutMs) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        $dev = Get-DevTools $pids
        if ($dev) { Hide-Window $dev.Handle; return $dev }
        if ([CT.Win]::GetForegroundWindow() -eq $main -or (Focus $main)) {
            Send $main '^%i'
            $t = [Diagnostics.Stopwatch]::StartNew()
            while ($t.ElapsedMilliseconds -lt 800) {     # retry Ctrl+Alt+I sooner (was 1.5 s)
                $dev = Get-DevTools $pids
                if ($dev) { Hide-Window $dev.Handle; return $dev }
                Start-Sleep -Milliseconds 15
            }
        } else { Start-Sleep -Milliseconds 200 }
    }
    $null
}

# Runs the snippet until the window actually shows Nord (or the time runs out). Keeps keyboard
# focus on the hidden DevTools for that short time instead of bouncing between windows.
function Invoke-Apply([int]$TimeoutMs = 4000, [switch]$Launch) {
    $pids = Get-ClaudePids
    $main = Get-MainWindow $pids
    if (-not $main) { Log 'Claude window not found'; return $false }
    if (-not $Launch -and (Get-Look $main.Handle) -eq 'nord') { Log 'already themed'; return $true }
    $prev = [CT.Win]::GetForegroundWindow()
    $start = [Diagnostics.Stopwatch]::StartNew()
    $dev = Get-DevTools $pids
    $opened = -not $dev
    if (-not $dev) { $dev = Open-DevTools $pids $main.Handle ($TimeoutMs + 6000) }
    if (-not $dev) { Log 'DevTools did not open (is Developer Mode on?)'; return $false }
    try {
        $sw = [Diagnostics.Stopwatch]::StartNew()                      # wait for DevTools to load
        while ($sw.ElapsedMilliseconds -lt 5000 -and (Get-Title $dev.Handle) -notmatch '://') { Start-Sleep -Milliseconds 15 }
        Hide-Window $dev.Handle
        $runs = 0; $stable = 0; $last = -10000
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
            $look = Get-Look $main.Handle
            if ($look -eq 'nord') { if (++$stable -ge 2) { break } }   # 2 readings ~50 ms apart is enough
            elseif ($look -eq 'light') { Log 'Claude is in light mode; the snippet only themes dark mode'; break }
            else {
                $stable = 0
                if ($sw.ElapsedMilliseconds - $last -ge 1500) { Invoke-Snippet $dev.Handle; $runs++; $last = $sw.ElapsedMilliseconds }
            }
            Start-Sleep -Milliseconds 50
        }
        Log ("{0} after {1} ms ({2} run(s))" -f $(if ($stable -ge 2) { 'theme on' } else { "gave up, look=$look" }), $start.ElapsedMilliseconds, $runs)
        return ($stable -ge 2)
    } finally {
        if ($opened -and [CT.Win]::IsWindow($dev.Handle)) { [void][CT.Win]::PostMessage($dev.Handle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) }
        $back = $main.Handle
        if ($prev -ne [IntPtr]::Zero -and $prev -ne $dev.Handle) { $back = $prev }
        [void][CT.Win]::SetForegroundWindow($back)
    }
}

if ($Install) {
    $me = $MyInvocation.MyCommand.Path
    $arg = "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$me`" -Watch -Snippet `"$Snippet`""
    $action   = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument $arg
    $trigger  = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew `
        -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName $TaskName
    Write-Host "Watcher installed and started (task '$TaskName'). Log: $LogFile"
    return
}
if ($Uninstall) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host 'Watcher removed.'
    return
}
if ($ShowDevTools) {
    # The watcher hides every DevTools window it sees, so pause it while you edit.
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) { Stop-ScheduledTask -TaskName $TaskName; Write-Host 'Watcher paused.' }
    $pids = Get-ClaudePids
    if (-not $pids) { Write-Host 'Claude is not running.'; if ($task) { Start-ScheduledTask -TaskName $TaskName }; return }
    $dev = Get-DevTools $pids
    if (-not $dev) {
        $main = Get-MainWindow $pids
        if ($main -and (Focus $main.Handle)) { Send $main.Handle '^%i' }
        for ($i = 0; $i -lt 100 -and -not $dev; $i++) { Start-Sleep -Milliseconds 50; $dev = Get-DevTools $pids }
    }
    if (-not $dev) { Write-Host 'Could not open DevTools (is Developer Mode on?).'; if ($task) { Start-ScheduledTask -TaskName $TaskName }; return }
    Show-Window $dev.Handle; [void](Focus $dev.Handle)
    Write-Host 'DevTools is on screen: Sources > Snippets > nordtheme. Save with Ctrl+S, run with Ctrl+Enter, then close DevTools.'
    while ([CT.Win]::IsWindow($dev.Handle) -and [CT.Win]::IsWindowVisible($dev.Handle)) { Start-Sleep -Milliseconds 500 }
    if ($task) { Start-ScheduledTask -TaskName $TaskName; Write-Host 'DevTools closed; watcher restarted.' }
    return
}

if ($Watch) {
    $mutex = New-Object Threading.Mutex($false, 'Local\ClaudeThemeWatcher')
    if (-not $mutex.WaitOne(0)) { return }
    Log "watcher started (snippet '$Snippet')"
    # Keeps Claude themed until it is confirmed, retrying with backoff; re-checks every ~2 s.
    # Safety rules (learned the hard way):
    #  - looks are read from Claude's own window (PrintWindow), never from the screen
    #  - only acts while Claude itself is the foreground window and you have paused typing,
    #    so it never switches workspaces or pulls Claude forward
    #  - needs several 'stock' readings in a row; hidden/minimised/black readings don't count
    #  - at most 6 attempts per Claude session, then it logs and stops until the next launch
    $session = [IntPtr]::Zero; $attempts = 0; $stockRun = 0; $next = [datetime]::MinValue; $themed = $false; $reapplies = 0
    $backoff = @(0, 5, 15, 45, 120, 120)
    $nextCheck = [datetime]::MinValue; $sessionStart = Get-Date
    # Timing: 150 ms polls until Claude is themed (fast pickup at launch); once themed, the
    # window is only re-checked every 3 s (a full-window capture is the expensive part).
    $wait = 150
    while ($true) {
        Start-Sleep -Milliseconds $wait
        $wait = 150
        # While the known Claude window still exists, skip the window search entirely.
        if ($session -ne [IntPtr]::Zero -and [CT.Fast]::IsWindow($session)) { $mainH = $session }
        else { [CT.Fast]::Scan(); $mainH = [CT.Fast]::Main }
        if ($mainH -eq [IntPtr]::Zero) { $session = [IntPtr]::Zero; $wait = 400; continue }
        if ($mainH -ne $session) {                             # new Claude window (launch/restart)
            $session = $mainH; $attempts = 0; $stockRun = 0; $themed = $false; $next = Get-Date; $reapplies = 0
            $nextCheck = [datetime]::MinValue; $sessionStart = Get-Date
            Log 'Claude window appeared'
        }
        if ($attempts -ge $backoff.Count -or $reapplies -ge 10) { $wait = 2000; continue }   # gave up for this session
        if ([CT.Win]::GetForegroundWindow() -ne $mainH) { $wait = 300; continue }          # only while Claude is in front
        if ($themed -and (Get-Date) -lt $nextCheck) { $wait = 500; continue }
        $look = Get-Look $mainH
        if ($look -eq 'nord') {
            if (-not $themed) { $themed = $true; Log 'theme confirmed' }
            $stockRun = 0; $nextCheck = (Get-Date).AddSeconds(3); continue
        }
        if ($look -ne 'stock') {                             # light / unknown / hidden: leave alone,
            if (((Get-Date) - $sessionStart).TotalSeconds -gt 20) { $wait = 1500 }   # and stop polling fast after launch
            continue
        }
        $stockRun++
        $needed = if ($themed) { 2 } else { 1 }              # once themed, need 2 readings in a row
        if ($themed) { $nextCheck = (Get-Date).AddMilliseconds(400) }
        if ($stockRun -lt $needed -or (Get-Date) -lt $next) { continue }
        # Keys go to the hidden DevTools, so wait for a short pause in your typing/clicking first:
        # brief at launch (you're waiting on the app), longer for a mid-session re-apply.
        $idleNeeded = if ($reapplies -gt 0 -or $attempts -gt 0) { 1500 } else { 500 }
        if ([CT.Win]::IdleMs() -lt $idleNeeded) { continue }
        $main = [pscustomobject]@{ Handle = $mainH; Title = 'Claude' }
        $attempts++
        if ($themed) { $reapplies++; Log "stock colours back (reload?), re-applying ($reapplies of 10 this session)"; $themed = $false }
        try { $ok = Invoke-Apply -TimeoutMs 12000 -Launch } catch { $ok = $false; Log "attempt ${attempts}: $($_.Exception.Message)" }
        $stockRun = 0
        if ($ok) { $themed = $true; $attempts = 0; $next = Get-Date; $nextCheck = (Get-Date).AddSeconds(3) }
        else {
            if ($attempts -ge $backoff.Count) { Log "giving up for this Claude session after $attempts attempts (Alt+Shift+Y to retry)" }
            else { $next = (Get-Date).AddSeconds($backoff[$attempts]) }
        }
    }
}

try { if (-not (Invoke-Apply -TimeoutMs 9000)) { exit 1 } } catch { Log $_.Exception.Message; exit 1 }
