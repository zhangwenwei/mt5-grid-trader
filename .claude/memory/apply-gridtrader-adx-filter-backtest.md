---
name: apply-gridtrader-adx-filter-backtest
description: "ADX filter backtest conclusion: ineffective for the grid strategy, EURCAD net profit doubled with it off, removed from the code"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 20db9aee-4811-43c9-a282-dbbaa4066c9c
---

**Conclusion: the ADX filter is harmful overall for the GridTrader grid strategy; do not add it back.**

**Why:** On 2026-06-21 a 3-year backtest comparison of ADX on vs ADX off was run on EURUSD/EURGBP/EURCHF/EURCAD:
- EURCAD: ADX off net profit +12719 vs ADX on +6828 (doubled), trades 58 vs 32, drawdown almost unchanged (2.1% vs 2.0%)
- EURUSD: ADX on had a higher profit factor (7.96 vs 4.25), but lower net profit (6195 vs 7525)
- Overall pattern: the ADX filter reduced the number of trades, but blocked the profitable ranging trades as well, so returns dropped noticeably

**How to apply:** 
- Do not add trend/range filter indicators such as ADX or RSI to this range grid strategy
- The real risk control is already the "breakout full close" mechanism; extra entry filters only reduce returns
- If price enters a trend, the breakout protection stops out with a full close; there is no need to block entries in advance with an indicator
- ADX has been completely removed from the code (current #property version 1.06, no iADX/ADXFilter inputs); do not revive it

[[apply-gridtrader-breakout-check-backtest]]
