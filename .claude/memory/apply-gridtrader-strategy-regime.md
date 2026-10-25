---
name: apply-gridtrader-strategy-regime
description: GridTrader large-scale backtest optimization + out-of-sample conclusions — LossCut most valuable, static wide range > rolling, both directions > one, do not extrapolate in-sample profit, risk control generalizes but profit depends on the market
metadata: 
  node_type: memory
  type: project
  originSessionId: dc2518a7-ab9b-4725-8cce-a27146ab06b2
---

In 2026-06 about 100+ real-tick backtests (mainly EURUSD + EUR crosses) of strategy optimization and walk-forward were run on GridTrader. Core conclusions:

- **The LossCut loss cut on order count (default 0 = off) is the most valuable single switch**: set to ~8, 2024 EURUSD net profit 18044→26180 and drawdown 27.7%→21.8%; combined with laddered lots 0.02→0.01 it reaches 31110 / PF 1.30. It cuts the bleeding side in trending months.
- **Static wide range > rolling reset range**: monthly and quarterly rolling both lose to "a wide static range covering the whole period"; after resetting to a narrower recent band, price drifts out and triggers frequent breakout stops. Rolling cannot save you from trends.
- **Both directions > one direction**: buy-only / sell-only = a bet on the macro direction (buy-only wins in rising periods, sell-only in falling periods), but neither beats both directions in net profit (both directions capture the drift + two-sided oscillation).
- **Do not extrapolate in-sample profit**: IS = 2024 H1 big profits (EURUSD +57k / EURGBP +30k) → OOS = H2 all losses (−3k / −8k), because price drifted out of the IS range. A fixed range breaks down once price drifts.
- **Risk control generalizes, profit does not**: every configuration/symbol had no margin call OOS and drawdown held at ~13–15% (LossCut + breakout full close work); but profit depends heavily on "price staying in the range". The configuration generalizes across EUR crosses (USD/GBP/CHF/CAD all positive in single-period 2024), ranging markets only.
- Trend pause / trend filters are ineffective (consistent with [[apply-gridtrader-adx-filter-backtest]]); branch strat/trend-pause is an archived negative result.

**How to apply**: recommended configuration = both directions + LossCut (~8) + laddered lots (0.02→0.01) + 28 grids + TP 30-45 + a wide static range, deployed only in ranging markets. Saved as presets/GridTrader_best.set (before use Upper/Lower must be changed to the actual high/low of the last ~3 months). **Do not trust in-sample figures**; for live trading expect "trustworthy risk control, returns depend on the market", and keep the range aligned.
**Why**: a grid's success mainly depends on "market match (range vs trend) + a correctly placed range"; tuning/adding indicators/rolling/directional bets are second-order and cannot change that.
Note: most large JPY figures used FAE=false + wide ranges and are optimistic, for relative comparison only; FAE=true with narrow ranges is closer to the real magnitude. Related [[design-gridtrader-firstatedge-trap]], [[design-gridtrader-cooldown]].
