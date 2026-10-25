# GridTrader — MT5 Range Bi-directional Grid EA

MT5 range bi-directional grid EA (single strategy): sell in the upper half / buy in the lower half, counter-trend mean reversion. Take-profit uses the per-side **lot-weighted total pips**, an optional trailing stop (close when profit falls back to a percentage of the peak), and laddered lot sizes. Follow these conventions when developing or modifying this project. **Read the code before changing it; do not invert the logic.**

## Project scope
- Single-file EA: `GridTrader.mq5` (MQL5, **Hedging** account mode).
- Repository: https://github.com/zhangwenwei/mt5-grid-trader. Tracked: the `.mq5` source, docs, presets, and `.claude/memory/`, `.claude/hooks/`, `.claude/settings.json`. Ignored by `.gitignore`: `*.ex5`, `*.log`, the rest of `.claude/` (including `settings.local.json`).
- Build output `GridTrader.ex5` and the compile log `GridTrader.log` are not version-controlled.

## Strategy logic (single strategy, `TradeGrid`)
- **Upper half sells**: one grid line per cell from `center + 1 cell` up to the upper bound; price touching a line opens a sell.
- **Lower half buys**: one grid line per cell from `center − 1 cell` down to the lower bound; price touching a line opens a buy.
- **The center line never trades** (the loop starts at k=1). Sell lines are all above the center and buy lines all below it. **The center is the starting point (inner edge), not the end point**; lines end at the upper/lower bound (stop when `line > upper + tol` / `< lower − tol`). **There is no "add until the center" logic** (that belonged to the deleted boundary-trend strategy).
- **An order opens only when all hold**: direction switch (`TradeGrid_EnableSell/Buy`), current bid/ask inside the range, the side's cooldown is armed (`g_lastSellLine/BuyLine == 0`), price within `±tol` of the grid line, and `HasOrderNear` finds no same-side order within half a cell of that line. **The same-side position limit is naturally capped by the number of grid lines (≈ GridCount/2).**
- **Bounds**: `TradeGrid_UpperPrice` / `TradeGrid_LowerPrice` are **required manual inputs** (> 0 and upper > lower); `g_center = (upper + lower) / 2` is computed automatically. There is no automatic range detection; invalid input makes OnInit refuse to start.
- **Grid count `TradeGrid_GridCount`** (integer, must be ≥ 2): splits the range into this many equal cells. Spacing `g_grid = (upper − lower) / TradeGrid_GridCount` is computed in OnInit and stored globally. With an even count the center falls exactly on a grid line and is skipped, so the number of trading lines = the grid count; with an odd count the center is not on a line and the outermost lines are half a cell from the bounds.
- **First order must touch the bound, `TradeGrid_FirstAtEdge`** (default on): when a side is flat, its first order waits until price touches the **bare bound** (sell `bid ≥ g_upper − tol` / buy `ask ≤ g_lower + tol`), to avoid opening mid-range. Adding to an open side is not restricted. When flat and price moves more than `release` away from the bound, the side is disarmed (`g_sellArmed` / `g_buyArmed`).

## Laddered lots (`LotForLine`)
- **Largest at the bound, decreasing toward the center**: `lots = LotForLine_InitLots − distEdge × LotForLine_ReducePerLine`, floored at `LotForLine_MinLots`.
  - `distEdge` = number of cells from the grid line to its own bound (closest to the bound = 0 → `LotForLine_InitLots`, the largest).
  - `LotForLine_ReducePerLine = 0` means every line uses a fixed `LotForLine_InitLots`.
- `NormalizeLots` floors to the lot step and clamps to [min, max]. Note that it lifts 0 to the minimum lot, which is why `LotForLine` already guarantees ≥ `LotForLine_MinLots` before an order is opened.

## Take-profit and trailing stop (the only active exits; mutually exclusive)
- **Metric = total profit in total pips** (lot-weighted sum, not an average): `TotalPipsByType` = `Σ(order pips × lots) / LotForLine_MinLots`; buys `(bid − open) / g_pip`, sells `(open − ask) / g_pip`. **The whole group is summed and normalized to the minimum lot** (so more orders / larger lots reach the target sooner; with every order at the minimum lot it equals the plain sum of each order's pips). **Price only, no commission, not an average, not money.** There is no per-order TP; orders are sent without TP (SL/TP both 0).
- **Per-side total take-profit** (trailing stop off): buys and sells separately. When the side's total pips reach `TpThreshold_BasePips` → `CloseSide` closes the whole side.
- **Trailing stop `TrailTotal_Enable`** (ON replaces the total TP; `TrailTotal`): once the side's peak total pips reach `TpThreshold_BasePips` (**a fixed threshold, independent of the order count**), the peak is tracked (`g_trailPeakBuy/Sell`). When the current value **falls back to `peak × EffectiveKeepRatio(orders)`** → close the whole side. **Purely internal tracking, no broker SL.** `TrailTotal_KeepPct` must be in (0, 100). **Semantics = "close when profit falls back to this percentage of the peak" (keep ratio)**: higher = tighter (less given back). Example: 80 = close at 80% of the peak (give back 20%).
- **Dynamic keep ratio `EffectiveKeepRatio(n)`** (trailing stop only): tightens linearly with the side's order count = `(TrailTotal_KeepPct + (orders − 1) × TrailTotal_AddPerOrder) / 100`, capped at 90%. `TrailTotal_AddPerOrder = 0` (default) keeps it fixed at `TrailTotal_KeepPct`. `TrailTotal_AddPerOrder` must be ≥ 0. Note: adding an order (+1) tightens the keep ratio; the armed state is unaffected (arming only requires peak ≥ the fixed threshold).
- `TpThreshold_BasePips` serves both roles: trailing off = fixed close threshold; trailing on = trailing activation threshold (fixed, independent of the order count). `TrailTotal_AddPerOrder` controls how the **keep ratio** tightens with the order count (only in trailing-stop mode).

## Loss cut on order count (`CheckLossCut`)
- **Input `LossCut_MinOrders`** (default 0 = off): when a side holds more than this many positions and that side's floating P/L (including swap, `FloatingPnL`) is < 0 → close every order on that side. Buys and sells are judged independently.
- Evaluated every tick after the breakout check and before TP/entries. When triggered it draws an orange-red vertical line + close label and returns `true`, skipping TP/entries for that tick.
- When 0 (off) the function returns on its first line, so there is no performance cost.

## Breakout detection and handling
- **Breakout check** (`IsOutOfRange`): evaluated in real time on the current tick's **`bid/ask`**. Out of range = `bid > upper + margin` or `ask < lower − margin`; recovery = `bid ≤ upper − buffer and ask ≥ lower + buffer` (a hysteresis band that prevents flip-flopping at the edge).
- The margin and the recovery buffer **share one distance** (`BreakoutDist`), **always in ATR units**: `BreakoutDist_AtrMult` × ATR (period `BreakoutDist_AtrPeriod`; if ATR is unavailable or the multiple is ≤ 0 the distance is 0). Distance 0 = trigger on touch. The buffer is limited by `ClampBuffer` to ≤ 40% of the range width.
- **A breakout is always a full close stop**: out of range → `CloseAll` and pause; bid/ask back inside → resume automatically (blue vertical line). There is no switch and no `BREAKOUT_OFF` fallback — every breakout closes everything.
- **`HandleBreakout` is evaluated every tick** (since v1.06): touching the bound triggers immediately, including wick spikes. `BreakoutDist()` caches ATR per bar internally (`static s_atrBar/s_atrLast`) to avoid a per-tick `CopyBuffer`. While `g_outOfRange` is set, `CloseAll` runs every tick as a safety net.

## Visualization
- **Master drawing switch `DrawLines_ShowGraphics`** (default on): off = draw nothing (bounds/grid lines/labels/breakout & recovery lines/vertical lines/info panel), **trading is unaffected**. The guard sits at the top of `DrawLines` / `DrawVLine` / `DrawInfoPanel` and the OnTick refresh block.
- Buys and sells are independent (separate statistics, separate TP); only `_Symbol + CTrade_Magic` is managed. Spread filter `OnTick_MaxSpread` (default 0 = off).
- **Horizontal lines** (visual only, live charts / visual tests): red solid thick = upper bound / yellow dashed thin = center / green solid thick = lower bound / gray thin = grid lines; **yellow solid thick** = breakout trigger (bound ± margin); **yellow dashed thin** = recovery limit (bound ∓ buffer, inside).
- **Vertical lines** (`DrawVLine`): **blue** = breakout full close; **green** = trailing-stop close with banked profit `≥ TpThreshold_BasePips` (fixed threshold, a good win); **yellow** = trailing-stop close with banked profit `< TpThreshold_BasePips` (a small win); **orange-red** = loss cut on order count (`LossCut_MinOrders`) triggered. Yellow is reused — horizontal yellow = breakout/recovery lines, vertical yellow = trailing stop below target — tell them apart by orientation and style.
- **Top-left panel**: `DrawInfoPanelTrail()` is called once in OnInit and draws the static trailing-stop settings row (unchanged at runtime). `DrawInfoPanel()` refreshes the dynamic floating-P/L rows every tick (called every tick, but redraw is skipped when the content has not changed). (**Do not change it back to per-bar throttling** — that makes the P/L display lag a full bar behind the real P/L. To speed up backtests turn off `DrawLines_ShowGraphics` or visual mode.) Panel content: ① trailing stop ON/OFF + settings (ON gold / OFF silver); ② buy and ③ sell rows, each with total pips + order count + (with trailing on) **the peak always shown**: not armed `peak X->start N stop T (pending)`, armed `peak X stop T (active)` (profit green / loss red / flat gray). The peaks `g_trailPeakBuy/Sell` are updated every tick only inside `TrailTotal`, so they are only meaningful when the trailing stop is on.
- Order comments carry the grid number, "Grid Buy/Sell #k" (k = cells from the center); `TesterHideIndicators(true)` hides indicators in visual tests; `OnDeinit` does not delete `GT_` objects.

## Entry cooldown (the easiest thing to break — keep it as is)
- `g_lastBuyLine` / `g_lastSellLine` store the **grid line price** of the last order (0 = armed). **Do not use the cell index** — on a large gap the index changes and unlocks by mistake.
- **Touch window `tol = grid × 0.25` must be < release threshold `release = grid × 0.75`.** If they are equal, jitter near a grid line re-enters repeatedly and opens back-to-back duplicates. See memory `design-gridtrader-cooldown`.
- `HasOrderNear` (half a cell, `grid × 0.5`) is a second de-duplication check ("a same-side order already exists near this line"). Unlocking uses price distance, never the cell index.

## Removed (do not look for / do not revive)
Hedge locking, Bollinger filter, trend (momentum) filter, boundary trend-following strategy (dual-strategy switch), automatic range detection, range shrinking, global SL circuit breaker, per-order TP, fixed lot size (split into the three ladder inputs), the old absolute-pips / divisor + broker-SL trailing mechanism, the separate per-side basket stop module, breakout distance in pips (now always ATR), the breakout handling switch (now always a full close stop), fixed-pips grid spacing (replaced by the evenly divided `TradeGrid_GridCount`), max orders per side (now capped naturally by the number of grid lines), TP time decay (`InpTPDecayBars`, removed after the v1.05 experiment).

## Trading code rules
- Use `CTrade` for opening/closing, never the legacy hand-written `OrderSend`; check the return value of key calls and print `ResultRetcode()` + `GetLastError()`.
- Normalize prices/lots by the symbol's digits and lot step (`NormalizeLots`); convert pips → price with `g_pip` (for 3/5-digit quotes 1 pip = 10 points).
- 4-space indentation; never change the defaults of stop-loss / take-profit / risk inputs without being asked.

## Compiling (command line, no need to open MetaEditor)
```
& "<MT5 install dir>\MetaEditor64.exe" /compile:"<absolute path to GridTrader.mq5>" /log
```
- Check `GridTrader.log` in the same folder (**UTF-16**; in PowerShell use `Get-Content -Encoding Unicode`) for `Result: 0 errors`.
- **Before writing the file, make sure MetaEditor does not have it open** — while it is open, external writes/compiles get reverted (hit repeatedly).

> Backtest workflow (backtest ini input names, verifying backtests by reading logs) is in [docs/DEV_WORKFLOW.md](docs/DEV_WORKFLOW.md).
> Backtest conclusions and recommended settings are in [docs/STRATEGY_RESEARCH.md](docs/STRATEGY_RESEARCH.md); a ready-to-load best parameter set is [presets/GridTrader_best.set](presets/GridTrader_best.set).

## Risk red lines (money is involved — warn the user proactively)
- On a one-way breakout the **stop-style full close** at the bound takes a loss; this is the designed worst case. Breakout handling is always a full close stop (no off switch).
- **Laddered lots put the heaviest orders at the bound**: on a breakout full close the large orders at the bound lose the most, amplifying breakout risk; keep `LotForLine_InitLots` under control.
- `TpThreshold_BasePips` is the **total profit in total pips** (whole-group sum `Σ(order pips × lots) / LotForLine_MinLots`, not an average). More orders / larger lots reach it sooner; with every order at the minimum lot it equals the plain sum of pips. Re-tune it whenever lots, grid count or symbol change.
- Multiple same-side orders can accumulate (up to ≈ the number of grid lines = GridCount/2). More grids = denser orders; watch margin and the risk of a margin call.
- When the TP / trailing threshold is much larger than the grid spacing, positions are held longer and drawdowns are larger.
- Assume a hedging account and a demo account by default, unless real trading is explicitly stated.
