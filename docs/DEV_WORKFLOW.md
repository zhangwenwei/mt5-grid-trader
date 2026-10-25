# GridTrader Development / Backtest Workflow

> Notes on procedures (how to compile, how to backtest, how to check results), split out of CLAUDE.md.
> CLAUDE.md only covers "what the software is and how the logic runs"; this file covers "how to get the work done".
> The compile command is in the "Compiling" section of CLAUDE.md; this file covers backtesting.

## Before a backtest: close any running MT5 instance (automated)
- If an MT5 instance (including a live GUI) is already running, a command-line `terminal64 /config:...` launch **hands over to the existing instance and exits immediately**, so the backtest never actually runs (no report is produced). See memory `apply-mt5-cli-backtest-shutdown`.
- Therefore every backtest must first run `Stop-Process -Name terminal64 -Force` (+ sleep ~0.7 s) before launching.
- **This is handled automatically by a hook**: the PreToolUse hook `.claude/hooks/kill-mt5-before-backtest.sh` (registered in `.claude/settings.json`) kills any running MT5 before a launch command that contains both `terminal64` and `config`, then lets the command proceed; pure query commands do not trigger it. The user has authorized closing MT5 before backtests without asking.
- The hook and its settings are tracked in the repository, but they only take effect in a local Claude Code session that loads this project's `.claude/settings.json`.

## Backtest ini input names (identical to the code variable names)
The `[TesterInputs]` section of a backtest ini must use these actual variable names:
> Note: the values below are **example backtest values**, not the code input defaults (e.g. TpThreshold_BasePips is 60 here, while the code default is 30, see BASELINE.md §2).
```ini
[TesterInputs]
TradeGrid_UpperPrice=1.1400
TradeGrid_LowerPrice=1.0600
TradeGrid_EnableBuy=true
TradeGrid_EnableSell=true
TradeGrid_GridCount=10
TradeGrid_FirstAtEdge=true
LotForLine_InitLots=0.01
LotForLine_ReducePerLine=0.0
LotForLine_MinLots=0.01
TpThreshold_BasePips=60
TrailTotal_AddPerOrder=0
TrailTotal_Enable=false
TrailTotal_KeepPct=70
LossCut_MinOrders=0
BreakoutDist_AtrMult=1.0
BreakoutDist_AtrPeriod=14
OnTick_MaxSpread=0
CTrade_Magic=20240601
CTrade_Slippage=30
DrawLines_ShowGraphics=false
```

## Verifying backtests
- The MT5 tester GUI cannot be triggered remotely; verification is done by **reading the backtest log and checking trade by trade**.
- Logs: `%APPDATA%\MetaQuotes\Tester\<TerminalID>\Agent-127.0.0.1-30xx\logs\<date>.log` (UTF-16; use the Agent folder with the most recent modification time).
- The tester's `OnTester` prints one summary line starting with `STATS |` (NetProfit / MaxDD / PF / RF / Trades / WinRate) that can be grepped from the log.
- After a command-line compile, the EA **must be reloaded / the tester reopened** in MT5 for the new build to take effect; otherwise the cached old parameters are used (hit repeatedly).
- Backtest has no data / ends instantly: first check the log for `history data begins from ...`; the usual cause is a test period earlier than the symbol's available history.
