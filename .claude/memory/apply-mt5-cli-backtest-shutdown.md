---
name: apply-mt5-cli-backtest-shutdown
description: "MT5 command-line backtests: do not wait for the process to exit; watch the log for \"thread finished\" and kill the process yourself"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 20db9aee-4811-43c9-a282-dbbaa4066c9c
---

When running command-line backtests with `terminal64.exe /config:...`, **do not use `WaitForExit` to wait for the process to exit on its own**.

**Why:** The MT5 test itself only takes 10–60 seconds, but terminal64.exe spends 8–10 minutes on shutdown after the test finishes (disconnecting from the server, saving caches, freeing memory). This is normal MT5 behavior and unrelated to machine performance. Waiting with WaitForExit wastes time no matter how many minutes you allow, and it easily hangs.

**How to apply:** The right approach is to watch the Agent log file and, as soon as `"thread finished"` or `"Test passed"` appears, immediately `Stop-Process terminal64 -Force`:

```powershell
function Run-BTAndWait {
    param($iniFile, $label, $logFile)

    # Record the log line count before launch so old content is not matched
    $beforeLines = if (Test-Path $logFile) { (Get-Content $logFile -Encoding Unicode).Count } else { 0 }

    $proc = Start-Process -FilePath $terminal -ArgumentList "/config:`"$iniFile`"" -PassThru

    # Poll the log for up to 5 minutes (the test itself needs only tens of seconds)
    $deadline = (Get-Date).AddMinutes(5)
    $done = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        if (Test-Path $logFile) {
            $lines = Get-Content $logFile -Encoding Unicode
            $newLines = $lines | Select-Object -Skip $beforeLines
            if ($newLines | Where-Object { $_ -match "thread finished|Test passed" }) {
                $done = $true; break
            }
        }
    }

    # Kill the process whether or not it finished (the terminal does not exit quickly by itself)
    Stop-Process -Name "terminal64" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 800

    if ($done) { Write-Host "$label done" -ForegroundColor Green }
    else        { Write-Host "$label did not finish within 5 minutes, force-killed" -ForegroundColor Red }
}
```

Key points:
- **The Agent port is not fixed**: MT5 assigns different tests to different Agents (3000, 3001, 3002...), so do not hard-code `Agent-127.0.0.1-3000`. Watch every `Agent-127.0.0.1-30*\logs\<date>.log`.
- Agent log root: `%APPDATA%\MetaQuotes\Tester\<TerminalID>\`
- Before each launch, snapshot the line count of **every existing** log and only look at new lines (avoids matching the previous result)
- Completion markers: `"thread finished"` or `"Test passed"`
- After completion terminal64 must be force-killed; it does not exit by itself
- The correct script location was `bt_configs/run_bt.ps1` (fixed to watch all ports)

**Addendum (2026-06 session)**:
- ⚠️ The `bt_configs/` folder has been deleted (together with run_bt.ps1); backtests now generate their ini on the fly in `$env:TEMP` and do not depend on a project subfolder.
- Claude Code's PowerShell/Bash tools **time out after 120 s by default**, so loops running several backtests get cut off → raise the tool `timeout` (max 600000 ms).
- terminal64 started with `Start-Process` is an independent process; after the script is killed by the tool timeout it **keeps running in the background** (the next `/config` then hands over to it and nothing really runs) → a **PreToolUse hook** `.claude/hooks/kill-mt5-before-backtest.sh` now kills MT5 automatically before every "command containing terminal64 + config".
- Real-tick (Model 8) full-year backtests are slow (~25–150 s, slower with more trades); probes with a wide range + large grid are especially slow, so give the monitoring deadline enough time.
- To probe the actual price swing of a period: run once with a wide range + `FAE=false` and take the min/max of the fill prices (see [[design-gridtrader-firstatedge-trap]]).

[[apply-gridtrader-breakout-check-backtest]] [[apply-gridtrader-strategy-regime]]
