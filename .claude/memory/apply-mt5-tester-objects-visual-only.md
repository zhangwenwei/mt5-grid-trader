---
name: apply-mt5-tester-objects-visual-only
description: "The MT5 non-visual test result chart does not render ObjectCreate objects; they only show in visual mode"
metadata: 
  node_type: memory
  type: reference
  originSessionId: f7d238bd-1d4e-4ddd-b715-e38b0ea37c83
---

MT5 strategy tester behavior: the result chart that opens automatically after a background (non-visual) test **shows only trades and indicators**;
it does not render any graphic object drawn with ObjectCreate (horizontal lines / vertical lines / text labels). This was mistaken for a code bug several times; it is actually an MT5 design limitation.

- To see the lines the EA draws: run the test in **visual mode**, or attach the EA to a live/demo chart.
- Objects drawn in OnDeinit **never show** (it runs after the visual window has closed).
- OBJ_HLINE needs only a price, no time anchor, and can be created reliably in OnInit; OBJ_TREND needs a time anchor, and in the tester the coordinate system is not ready in OnInit, so creation fails (nothing drawn). Always use OBJ_HLINE for horizontal lines.
- A command-line non-visual backtest **cannot** verify whether lines are displayed; it can only verify the trading logic (read STATS/logs).

Source: MQL5 Book "Testing visualization: chart, objects, indicators".
