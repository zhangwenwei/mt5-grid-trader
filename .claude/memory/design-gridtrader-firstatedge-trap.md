---
name: design-gridtrader-firstatedge-trap
description: With FirstAtEdge=true, if the grid range is set wider than the actual price swing, the bounds are never touched -> no orders at all (backtest all zeros)
metadata: 
  node_type: memory
  type: project
  originSessionId: dc2518a7-ab9b-4725-8cce-a27146ab06b2
---

GridTrader's `TradeGrid_FirstAtEdge=true` (default) requires that when a side is flat, its first order only opens after price touches the **bare bound** (sell: upper / buy: lower).

**Trap**: if `TradeGrid_UpperPrice/LowerPrice` are set **wider than the actual high/low** price reached in that period, the bounds are never touched → not a single order opens, backtest net profit = 0 and trades = 0 (hit twice in one session, and mistaken for a broken script).

**How to apply**:
- With FAE=true, the range must closely fit the **actual price swing** of the period (the bounds must be reachable).
- If you deliberately set the range wider than the swing (e.g. a range from analysis / a look-back band with a margin), you must set `FAE=false`, otherwise nothing trades at all.
- To probe the actual swing of a period: run once with a very wide range + `FAE=false` and take the min/max of the fill prices `deal ... at X`; that is the period's swing.

Related: [[apply-gridtrader-strategy-regime]]
