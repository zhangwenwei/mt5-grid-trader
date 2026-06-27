---
name: apply-mt5-cli-backtest-shutdown
description: "MT5 命令行回测：不能等进程退出，要监控日志 \"thread finished\" 后主动杀进程"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 20db9aee-4811-43c9-a282-dbbaa4066c9c
---

用 `terminal64.exe /config:...` 跑命令行回测时，**不要用 `WaitForExit` 等进程自然退出**。

**Why:** MT5 测试本身只需 10–60 秒，但 terminal64.exe 在测试完成后会花 8–10 分钟做收尾（断开服务器、保存缓存、释放内存）。这是 MT5 正常行为，和电脑性能无关。用 WaitForExit 等退出，无论设多少分钟都很浪费时间，且容易卡住。

**How to apply:** 正确做法是监控 Agent 日志文件，一旦出现 `"thread finished"` 或 `"Test passed"` 就立刻 `Stop-Process terminal64 -Force`：

```powershell
function Run-BTAndWait {
    param($iniFile, $label, $logFile)

    # 记录启动前日志行数，避免匹配到历史内容
    $beforeLines = if (Test-Path $logFile) { (Get-Content $logFile -Encoding Unicode).Count } else { 0 }

    $proc = Start-Process -FilePath $terminal -ArgumentList "/config:`"$iniFile`"" -PassThru

    # 轮询日志，最多等5分钟（测试本身几十秒就够）
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

    # 无论是否完成都杀掉进程（terminal不会自己快速退出）
    Stop-Process -Name "terminal64" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 800

    if ($done) { Write-Host "$label 完成" -ForegroundColor Green }
    else        { Write-Host "$label 5分钟内未完成，已强制终止" -ForegroundColor Red }
}
```

关键点：
- **Agent 端口不固定**：MT5 会把不同测试分配给不同的 Agent（3000、3001、3002...），不能硬编码 `Agent-127.0.0.1-3000`。必须监听所有 `Agent-127.0.0.1-30*\logs\<date>.log`。
- Agent 日志根目录：`C:\Users\ZWW\AppData\Roaming\MetaQuotes\Tester\52E30E5000D12076386E4B78F270129E\`
- 每次启动前记录**所有现有**日志的行数快照，只看新产生的行（避免误匹配上次结果）
- 测试完成标志：`"thread finished"` 或 `"Test passed"`
- 完成后必须 Force Kill terminal64，它不会自己退出
- 正确的脚本位置：`bt_configs/run_bt.ps1`（已修复，监听所有端口）

[[apply-gridtrader-breakout-check-backtest]]
