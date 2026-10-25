---
name: design-gridtrader-cooldown
description: "Entry cooldown threshold design of the GridTrader range grid EA — the touch window must be smaller than the release threshold to prevent duplicate entries when price jitters near a grid line"
metadata: 
  node_type: memory
  type: project
  originSessionId: 09f05b1e-5331-44e8-95b6-479a470dcc5b
---

The entry cooldown of GridTrader.mq5 (range bi-directional grid EA, sell upper half / buy lower half / full close out of range) must use **two different thresholds**; they must not share half a cell:

- Touch window `tol = grid * 0.25`: price only counts as "touching" when within ±1/4 cell of a grid line, and only then opens an order
- Release threshold `release = grid * 0.75`: after an order, price must move 3/4 cell away from that line before the line may trade again

**Why:** Early versions used `grid*0.5` (half a cell) for both the touch window and the release threshold, so the two boundaries overlapped. When price jittered slightly around a grid line (e.g. +13 pip ↔ +15 pip) it repeatedly triggered "release → open again", opening back-to-back duplicates on the same line within 1 second (hard evidence from the backtest log: 2026.04.30 13:33:05 buy@158.028 / 13:33:06 buy@158.052, 2.4 pip apart). Making the release threshold larger than the touch window leaves a buffer band in between, and jitter can no longer re-enter.

**How to apply:** When changing this EA's entry density / duplicate-order behavior, first confirm `tol < release`; if fast markets occasionally miss entries, enlarge `tol` (e.g. 0.35) to find a balance, but always keep `tol < release`. The duplicate-order problem is unrelated to spread (the user's version had OnTick_MaxSpread=0, spread filter off).

The cooldown uses the globals `g_lastBuyLine` / `g_lastSellLine` to store the grid line price of the last order (0 = armed); do not use a MathRound cell index — on a large gap the index changes and unlocks by mistake.

Verification: the MT5 tester GUI cannot be triggered remotely; the only way is to read the backtest log trade by trade. Logs are in `...\Tester\<ID>\Agent-127.0.0.1-30xx\logs\<date>.log`, UTF-16 encoded (PowerShell: `Get-Content -Encoding Unicode`). Command-line compile: `& "<MT5 install dir>\MetaEditor64.exe" /compile:"<mq5 path>" /log`.
