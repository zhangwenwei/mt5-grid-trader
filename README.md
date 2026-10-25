# GridTrader — MT5 Range Bi-directional Grid EA

GridTrader is a single-file Expert Advisor for **MetaTrader 5** (MQL5) that trades a manually defined price range as a mean-reverting grid:

- **Upper half → sells**, **lower half → buys** (counter-trend, betting on a return to the middle).
- Exits are **per-side group exits**: a lot-weighted *total pips* take-profit, or an optional trailing stop on that total.
- If price **breaks out of the range**, every position is closed (a stop-out by design) and trading pauses until price returns inside.

> ⚠️ **Risk warning.** This is a grid strategy. It makes money only while price stays in a range. A one-way breakout is closed at a loss at the boundary — that is the designed worst case, not a bug. Read [Risk warning](#risk-warning) before running it anywhere near real money, and test on a **demo account** first.

Current version: **v1.06** (`#property version "1.06"`).

---

## Contents

- [Requirements](#requirements)
- [How it works](#how-it-works)
- [Input parameters](#input-parameters)
- [Installation & compilation](#installation--compilation)
- [Quick start](#quick-start)
- [Chart visuals](#chart-visuals)
- [Backtest summary](#backtest-summary)
- [Risk warning](#risk-warning)
- [Repository layout](#repository-layout)
- [License](#license)

---

## Requirements

| Item | Requirement |
|---|---|
| Platform | MetaTrader 5 (any recent build that supports `input group`) |
| Account mode | **Hedging** — buys and sells are held at the same time; a netting account will not work as designed |
| Libraries | MQL5 standard library only: `<Trade\Trade.mqh>`, `<Trade\PositionInfo.mqh>` |
| Instruments | Designed and tested on FX pairs (EURUSD and EUR crosses). 3/5-digit quotes use 1 pip = 10 points |

---

## How it works

### Range and grid lines
- You enter the **upper** and **lower** bound prices (`TradeGrid_UpperPrice`, `TradeGrid_LowerPrice`). Both are required; the EA refuses to start if they are missing or `upper <= lower`. There is no automatic range detection.
- `center = (upper + lower) / 2`.
- The range is split into `TradeGrid_GridCount` equal cells; spacing `grid = (upper − lower) / GridCount`.
- **Sell lines** start at `center + 1 cell` and go up to the upper bound; **buy lines** start at `center − 1 cell` and go down to the lower bound. **The center line never trades.**
- The number of same-side positions is naturally capped by the number of grid lines (≈ `GridCount / 2`).

### Entry conditions
An order opens on a grid line only when **all** of the following hold:
1. The direction is enabled (`TradeGrid_EnableSell` / `TradeGrid_EnableBuy`).
2. The current bid/ask is inside the range.
3. The side's cooldown is armed (see below).
4. Price is within the **touch window** `±0.25 × grid` of the line.
5. There is no same-side position within `±0.5 × grid` of that line.

**First order at the edge (`TradeGrid_FirstAtEdge`, default on).** When a side is flat, its first order waits until price has touched the *bare* bound (sell: `bid ≥ upper − tol`, buy: `ask ≤ lower + tol`). This avoids opening the first trade in the middle of the range. Adding to an existing side is not restricted. If the side is flat and price moves more than `0.75 × grid` away from the bound, the side is disarmed again.

> If the range is wider than the price actually travels, the bounds are never touched and **no trade ever opens** with this option on. Either fit the range to the real price swing or set `TradeGrid_FirstAtEdge=false`.

**Cooldown.** After opening on a line, the EA remembers that line's price. The same side cannot open again until price moves more than the **release threshold** `0.75 × grid` away from it. The touch window (0.25) is deliberately smaller than the release threshold (0.75) so jitter around a line cannot cause back-to-back duplicate entries.

### Laddered lot size
Lots are largest at the boundary and decrease toward the center:

```
lots = LotForLine_InitLots − distEdge × LotForLine_ReducePerLine   (floored at LotForLine_MinLots)
```

`distEdge` is the number of cells between the line and its own boundary (0 = the line closest to the boundary). `LotForLine_ReducePerLine = 0` gives a fixed lot size. Lots are then normalized to the symbol's lot step and clamped to its min/max volume.

### Exits (the only active exits; mutually exclusive)
Both exits work on a side's **total profit in pips**, a lot-weighted sum normalized to the minimum lot:

```
total pips = Σ(order pips × order lots) / LotForLine_MinLots
buy pips  = (bid − open) / pip       sell pips = (open − ask) / pip
```

It is a **sum, not an average**, price-only (no commission/swap), and not money. With every order at the minimum lot it equals the plain sum of each order's pips, so more orders or larger lots reach the target sooner. Orders are sent with **no broker SL/TP**.

- **Per-side total take-profit** (trailing stop off): when a side's total pips ≥ `TpThreshold_BasePips`, every order on that side is closed.
- **Trailing stop** (`TrailTotal_Enable=true`, replaces the TP above): once a side's peak total pips reaches `TpThreshold_BasePips` (a fixed activation level), the EA tracks the peak and closes the side when the current value falls to `peak × keep ratio`. This is internal tracking only, nothing is placed at the broker.
  - `keep ratio = (TrailTotal_KeepPct + (orders − 1) × TrailTotal_AddPerOrder) / 100`, capped at 90%.
  - `TrailTotal_KeepPct` means "close when profit falls back to this % of the peak": 80 = close at 80% of the peak (give back 20%). Higher = tighter.

### Loss cut on order count (`LossCut_MinOrders`, default 0 = off)
If one side holds **more than** `LossCut_MinOrders` positions **and** that side's floating P/L (profit + swap, account currency) is below zero, that side is closed. Buys and sells are evaluated independently.

### Breakout handling (always a full close)
- Checked **every tick** on bid/ask: out of range when `bid > upper + dist` or `ask < lower − dist`. Long wicks trigger immediately.
- `dist = BreakoutDist_AtrMult × ATR(BreakoutDist_AtrPeriod)`. ATR is read from the last closed bar and cached once per bar. If ATR is unavailable or the multiple is ≤ 0, `dist = 0` (touching the bound triggers).
- On breakout: **close all positions and pause**. While out of range, every tick closes anything left.
- Recovery uses a hysteresis band: trading resumes only when `bid ≤ upper − buffer` **and** `ask ≥ lower + buffer`. The buffer is the same ATR distance, clamped to at most 40% of the range width.
- There is no option to disable this. A breakout always closes everything.

### Per-tick order of operations

```
spread filter → info panel → (new bar) refresh labels/lines
→ breakout handling → loss cut → total TP or trailing stop → grid entries
```

Any step that closes positions ends the tick, so no new orders open on that tick.

---

## Input parameters

Defaults below are the **code defaults** in `GridTrader.mq5`. The preset in `presets/` uses different values (see [Quick start](#quick-start)).

| Group | Parameter | Type | Default | Description |
|---|---|---|---|---|
| Direction | `TradeGrid_EnableBuy` | bool | `true` | Allow buys in the lower half |
| | `TradeGrid_EnableSell` | bool | `true` | Allow sells in the upper half |
| Range | `TradeGrid_UpperPrice` | double | `0` | Upper bound price. **Required**, > 0 and > lower |
| | `TradeGrid_LowerPrice` | double | `0` | Lower bound price. **Required**, > 0 |
| Grid | `TradeGrid_GridCount` | int | `10` | Number of equal cells in the range (≥ 2) |
| | `TradeGrid_FirstAtEdge` | bool | `true` | First order of a flat side requires touching its bound |
| Lots | `LotForLine_InitLots` | double | `0.01` | Lots on the line closest to the bound (largest). > 0, ≥ MinLots |
| | `LotForLine_ReducePerLine` | double | `0.0` | Lots subtracted per line toward the center (0 = fixed lots). ≥ 0 |
| | `LotForLine_MinLots` | double | `0.01` | Lot floor; also the normalization unit for total pips. > 0 |
| Take-profit | `TpThreshold_BasePips` | int | `30` | Total-pips TP target / trailing-stop activation level |
| Trailing stop | `TrailTotal_Enable` | bool | `false` | Enable trailing stop (replaces the total TP) |
| | `TrailTotal_KeepPct` | int | `70` | Close when profit falls to this % of the peak. Must be in (0, 100) when enabled |
| | `TrailTotal_AddPerOrder` | int | `0` | Extra percentage points of tightening per additional order (capped at 90%). ≥ 0 |
| Breakout | `BreakoutDist_AtrMult` | double | `1.0` | Breakout / recovery distance = this × ATR |
| | `BreakoutDist_AtrPeriod` | int | `14` | ATR period |
| Loss cut | `LossCut_MinOrders` | int | `0` | Close a side holding more than this many orders while in a floating loss (0 = off) |
| Filters & risk | `OnTick_MaxSpread` | int | `0` | Skip ticks with spread above this (points); ≤ 0 = no limit |
| | `CTrade_Magic` | long | `20240601` | Magic number; the EA only manages its own symbol + magic |
| | `CTrade_Slippage` | ulong | `30` | Allowed slippage (points) |
| Graphics | `DrawLines_ShowGraphics` | bool | `true` | Master switch for all chart drawing. Off = draw nothing; trading is unaffected |

Invalid combinations (for example `GridCount < 2`, `InitLots < MinLots`, missing bounds) make `OnInit` return `INIT_PARAMETERS_INCORRECT` and the EA does not start. The reason is printed in the Experts log.

---

## Installation & compilation

1. Copy `GridTrader.mq5` into your terminal's `MQL5\Experts\` folder (or a subfolder such as `MQL5\Experts\box\`). In MT5: **File → Open Data Folder**.
2. Compile it with one of these:
   - **MetaEditor:** open the file and press **F7**.
   - **Command line:**
     ```powershell
     & "<MT5 install dir>\MetaEditor64.exe" /compile:"<absolute path>\GridTrader.mq5" /log
     ```
     The result is written to `GridTrader.log` next to the source file. The log is **UTF-16**, so read it with `Get-Content -Encoding Unicode` and look for `Result: 0 errors`.
3. Make sure MetaEditor does not have the file open while another tool writes to it, or your external changes may be reverted.
4. After recompiling, reload the EA on the chart, or reopen the Strategy Tester, so the new build is used.

`*.ex5` and `*.log` are build artifacts and are excluded by `.gitignore`.

---

## Quick start

1. Use a **hedging demo account**.
2. Attach the EA to a chart, open the **Inputs** tab, click **Load**, and pick [`presets/GridTrader_best.set`](presets/GridTrader_best.set).
3. **Change `TradeGrid_UpperPrice` / `TradeGrid_LowerPrice`.** The preset holds example EURUSD 2024 values (`1.11940 / 1.04430`). Replace them with the actual high/low of **your symbol over roughly the last 3 months**. A wrong range is the single biggest cause of losses.
4. Confirm and watch the info panel in the top-left corner.

Preset highlights (from backtests, see [docs/STRATEGY_RESEARCH.md](docs/STRATEGY_RESEARCH.md)):

| Parameter | Preset | Code default |
|---|---|---|
| `TradeGrid_GridCount` | 28 | 10 |
| `TpThreshold_BasePips` | 35 | 30 |
| `LotForLine_InitLots` / `ReducePerLine` | 0.02 / 0.01 | 0.01 / 0.0 |
| `LossCut_MinOrders` | **8** | **0 (off)** |
| `TrailTotal_Enable` | false | false |

More details: [presets/README.md](presets/README.md).

---

## Chart visuals

Drawing only happens in live/demo charts and **visual-mode** backtests. The non-visual tester result chart never renders `ObjectCreate` objects (an MT5 limitation). All objects use the `GT_` prefix and are **not deleted** when the EA is removed.

| Element | Meaning |
|---|---|
| Red thick solid horizontal | Upper bound |
| Yellow thin dashed horizontal | Center line |
| Green thick solid horizontal | Lower bound |
| Gray dotted horizontal | Grid lines |
| Yellow thick solid horizontal | Breakout trigger (bound ± ATR distance) |
| Yellow thin dashed horizontal | Recovery limit (bound ∓ buffer) |
| **Blue** vertical | Breakout full close |
| **Green** vertical | Trailing-stop close with profit ≥ `TpThreshold_BasePips` |
| **Yellow** vertical | Trailing-stop close with profit < `TpThreshold_BasePips` |
| **Orange-red** vertical | Loss cut on order count triggered |
| Text labels at close bars | Closed result in total pips (green positive, red negative) |

Yellow is reused: horizontal yellow lines are breakout/recovery levels, vertical yellow lines are low-profit trailing closes.

**Info panel (top-left):**
1. Trailing stop ON/OFF and its settings (drawn once at start).
2. Buy row and 3. Sell row, refreshed every tick: total pips and order count. With the trailing stop on, it also shows the peak and stop target, marked `(pending)` before activation or `(active)` after. Green = profit, red = loss, gray = flat.

Order comments are `Grid Buy #k` / `Grid Sell #k`, where `k` is the number of cells from the center.

To speed up backtests, set `DrawLines_ShowGraphics=false` or run in non-visual mode.

---

## Backtest summary

About 100+ MT5 **real-tick** (Model 8) backtests, mostly EURUSD plus EUR crosses. Full details are in [docs/STRATEGY_RESEARCH.md](docs/STRATEGY_RESEARCH.md).

- The best combination found: **both directions + LossCut ≈ 8 + laddered lots 0.02→0.01 + 28 grids + TP 30–45 + a wide static range**, used **only in ranging markets**.
- The loss cut on order count was the most valuable single switch. It raised net profit and lowered drawdown.
- A wide static range beat monthly or quarterly rolling ranges. Both directions beat buy-only or sell-only. Trend/ADX filters and the trailing stop did not help.
- **In-sample ≠ out-of-sample.** In a walk-forward test (range set on 2024 H1, traded on 2024 H2), EURUSD and EURGBP went from large in-sample profits to **out-of-sample losses**, because price drifted out of the range. Risk control held up (no margin call, drawdown about 13–15%), but **profit did not generalize**.
- Many absolute figures used `FirstAtEdge=false` with wide ranges and are optimistic. Use them for relative comparison only.

Past backtest results do not guarantee future performance.

---

## Risk warning

- **Breakouts are closed at a loss.** A one-way move out of the range triggers a full close at the boundary. This is the designed worst case and it cannot be disabled.
- **Laddered lots concentrate risk at the boundary.** The largest orders sit closest to the bound, so they lose the most on a breakout. Keep `LotForLine_InitLots` modest. A conservative setup is `InitLots=0.01`, `ReducePerLine=0`.
- **Positions accumulate.** Up to about `GridCount / 2` orders per side can be open at once. More grids means denser orders. Check margin and the risk of a margin call before going live.
- **Large TP targets mean long holding times.** If the TP or trailing threshold is much larger than the grid spacing, positions are held longer and drawdowns grow.
- **`TpThreshold_BasePips` is a lot-weighted total, not an average.** Re-tune it whenever you change lot sizes, grid count or symbol.
- **Ranging markets only.** Trending markets lose money, which is common to all grid systems. Re-align the range with current prices regularly.
- The EA assumes a **hedging** account. Run it on a **demo account** first, then with minimum lots, before considering real money. You are solely responsible for any trading results.

---

## Repository layout

```
GridTrader.mq5              EA source (single file)
BASELINE.md                 Detailed behavioral specification for v1.06 (flows, formulas)
CLAUDE.md                   Project conventions for AI-assisted development
presets/
  GridTrader_best.set       Best-found parameter set (change Upper/Lower before use)
  README.md                 How to use the preset
docs/
  DEV_WORKFLOW.md           Compile / backtest workflow notes
  STRATEGY_RESEARCH.md      Backtest research summary and conclusions
  archive/                  Historical docs that no longer match the current code
.claude/                    Claude Code memory, hooks and settings used during development
```

---

## License

No license file is currently included in this repository. All rights reserved by the author unless a license is added.
