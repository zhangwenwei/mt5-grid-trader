---
name: apply-gridtrader-breakout-check-backtest
description: "Breakout check method backtest conclusion — wick/ATR best, ADX worst because its stop lags"
metadata: 
  node_type: memory
  type: project
  originSessionId: f7d238bd-1d4e-4ddd-b715-e38b0ea37c83
---

Early versions of GridTrader offered 6 "breakout check methods" (old input InpBreakoutCheck): close price / real-time tick / wick / ADX / ATR / Bollinger bandwidth. **Since v1.06 this is fixed to "per-tick bid/ask + ATR distance threshold" and that input was removed**; below is the backtest comparison from back then, which guided the final choice:
Backtest comparison (USDJPY range 159.5/158, 2026.01-04, full close stop + 30 pips buffer):

- Wick (CHECK_WICK): net profit 22548, drawdown 2.6% (lowest), recovery factor 3.99 (highest) — most robust, made the default.
- ATR dynamic threshold: net profit 24000 (highest), drawdown 4.4%. Use when maximizing net profit.
- Bollinger bandwidth: net profit 23622, drawdown 3.8%.
- Real-time tick: net profit 22940, drawdown 2.8%; but sensitive to spread/slippage/spikes in live trading, so the backtest advantage shrinks.
- Close price (baseline): net profit 16179.
- ADX confirmation: net profit 15497 (below the baseline), drawdown 7.8%, recovery factor 0.92 — **the worst**.

**Key counter-intuitive conclusion**: breakout handling is essentially **a stop-loss, and it must be timely**. ADX "only counts a breakout after the trend is confirmed" = lagging confirmation = stopping too late = counter-trend orders take huge losses (drawdown explodes).
Using a "wait for confirmation" indicator for a stop is the wrong direction; the more sensitive, earlier-stopping methods (wick/tick) actually have the smallest drawdown.

**Why**: two of my theoretical judgments (hysteresis hurts hedge locking, ADX fits best) were both overturned by backtest data; the lesson is that strategy choices must be decided by backtest data, not by reasoning about the mechanism alone.
**How to apply**: for breakout/stop logic prefer "timely trigger" checks (wick/ATR), not lagging confirmation (ADX/MACD). Re-run the backtests when the symbol/range/period changes; the ranking may change.
Related: [[design-gridtrader-cooldown]]
