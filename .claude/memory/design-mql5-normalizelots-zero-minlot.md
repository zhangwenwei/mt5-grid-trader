---
name: design-mql5-normalizelots-zero-minlot
description: "NormalizeLots(0) returns the minimum lot, not 0; check the raw value > 0 before opening an order by a computed lot size"
metadata: 
  node_type: memory
  type: reference
  originSessionId: f7d238bd-1d4e-4ddd-b715-e38b0ea37c83
---

MQL5 trap: GridTrader's NormalizeLots() ends with `lots = MathMax(minLot, ...)`,
so **NormalizeLots(0.0) does not return 0 but the symbol's minimum lot (e.g. 0.01)**.

This caused a real bug (note: the hedge-locking feature has since been removed from the code; the following is the real case from back then, and the lesson still applies): when merging hedge locking, a side with no positions (total lots = 0) still opened a minimum-lot hedge order out of nothing
(log "original sell 0.00 lots -> lock buy 0.01"), effectively an unhedged opposite position + extra spread paid.

**How to apply**: anywhere an order is opened "by a computed lot size" (hedge / add-on / martingale), decide whether to open using **the raw lot size vol > 0**,
never the result of NormalizeLots(vol) (it is always >= minLot, always true).
Related: [[apply-gridtrader-breakout-check-backtest]]
