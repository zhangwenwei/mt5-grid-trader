# GridTrader EA — Behavioral Specification / Behavior Baseline (BASELINE.md)

> This file is the complete behavioral specification of GridTrader. Each item matches the current code, and it serves as the detailed long-term maintenance reference
> (complementary to CLAUDE.md: CLAUDE.md focuses on conventions, this file on exact flows and formulas).
> Matching code: GridTrader.mq5 **v1.06**, commit bcb6c34 (log/panel/label text translated to English afterwards; logic unchanged).
> Change history: v1.05 (a5053bd) → v1.06 changed breakout detection from "evaluate on each new bar close" to "evaluate bid/ask in real time every tick",
> and added a per-bar ATR cache (see §8.11 / §8.12 / §8.14 / §12 / §14).

---

## 1. EA basics

| Property | Value |
|------|----|
| File | GridTrader.mq5 |
| Version | `#property version "1.06"` |
| Account mode | Hedging, MQL5 |
| Libraries | `<Trade\Trade.mqh>`, `<Trade\PositionInfo.mqh>` |
| Global objects | `CTrade trade;`, `CPositionInfo pos;` |

---

## 2. All inputs and defaults

### 2.1 Direction
| Input | Type | Default |
|------|------|--------|
| `TradeGrid_EnableBuy` | bool | true |
| `TradeGrid_EnableSell` | bool | true |

### 2.2 Grid range (required, manual)
| Input | Type | Default | Constraint |
|------|------|--------|------|
| `TradeGrid_UpperPrice` | double | 0 | > 0 and > LowerPrice |
| `TradeGrid_LowerPrice` | double | 0 | > 0 |

### 2.3 Grid settings
| Input | Type | Default | Constraint |
|------|------|--------|------|
| `TradeGrid_GridCount` | int | 10 | ≥ 2 |
| `TradeGrid_FirstAtEdge` | bool | true | — |

### 2.4 Laddered lots
| Input | Type | Default | Constraint |
|------|------|--------|------|
| `LotForLine_InitLots` | double | 0.01 | > 0, ≥ MinLots |
| `LotForLine_ReducePerLine` | double | 0.0 | ≥ 0 |
| `LotForLine_MinLots` | double | 0.01 | > 0 |

### 2.5 Per-side total take-profit
| Input | Type | Default |
|------|------|--------|
| `TpThreshold_BasePips` | int | 30 |

### 2.6 Trailing stop
| Input | Type | Default | Constraint |
|------|------|--------|------|
| `TrailTotal_Enable` | bool | false | — |
| `TrailTotal_KeepPct` | int | 70 | (0, 100), validated only when Enable is true |
| `TrailTotal_AddPerOrder` | int | 0 | ≥ 0 |

### 2.7 Breakout detection
| Input | Type | Default |
|------|------|--------|
| `BreakoutDist_AtrMult` | double | 1.0 |
| `BreakoutDist_AtrPeriod` | int | 14 |

### 2.8 Loss cut on order count
| Input | Type | Default |
|------|------|--------|
| `LossCut_MinOrders` | int | 0 (off) |

### 2.9 Filters & risk
| Input | Type | Default |
|------|------|--------|
| `OnTick_MaxSpread` | int | 0 (no limit) |
| `CTrade_Magic` | long | 20240601 |
| `CTrade_Slippage` | ulong | 30 |

### 2.10 Graphics
| Input | Type | Default |
|------|------|--------|
| `DrawLines_ShowGraphics` | bool | true |

---

## 3. Global state variables

| Variable | Type | Initial value | Description |
|------|------|--------|------|
| `g_pip` | double | 0.0 | Price value of 1 pip |
| `g_point` | double | 0.0 | 1 point |
| `g_digits` | int | 0 | Price decimal digits |
| `g_center` | double | 0.0 | Center = (upper + lower) / 2 |
| `g_upper` | double | 0.0 | Grid upper bound |
| `g_lower` | double | 0.0 | Grid lower bound |
| `g_grid` | double | 0.0 | Spacing = (upper − lower) / GridCount |
| `g_lastBuyLine` | double | 0.0 | Grid line price of the last buy (0 = armed) |
| `g_lastSellLine` | double | 0.0 | Grid line price of the last sell (0 = armed) |
| `g_sellArmed` | bool | false | Whether the sell group has touched the upper bound |
| `g_buyArmed` | bool | false | Whether the buy group has touched the lower bound |
| `g_trailPeakBuy` | double | 0.0 | Peak total pips of the buy group |
| `g_trailPeakSell` | double | 0.0 | Peak total pips of the sell group |
| `g_boAtrHandle` | int | INVALID_HANDLE | ATR indicator handle |
| `g_outOfRange` | bool | false | Whether trading is currently paused out of range |

---

## 4. OnInit flow (exact order)

```
1. TesterHideIndicators(true)
2. g_point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT)
   g_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)
   g_pip    = (g_digits==3 || g_digits==5) ? 10*g_point : g_point
3. trade.SetExpertMagicNumber(CTrade_Magic)
   trade.SetDeviationInPoints(CTrade_Slippage)
   trade.SetTypeFillingBySymbol(_Symbol)
4. Input validation (in order; any failure → return INIT_PARAMETERS_INCORRECT)
   a. TradeGrid_GridCount < 2
   b. LotForLine_InitLots<=0 || LotForLine_MinLots<=0 ||
      LotForLine_ReducePerLine<0 || LotForLine_InitLots<LotForLine_MinLots
   c. TrailTotal_AddPerOrder < 0
   d. when TrailTotal_Enable==true:
      TrailTotal_KeepPct<=0 || TrailTotal_KeepPct>=100 || TpThreshold_BasePips<=0
   e. TradeGrid_UpperPrice<=0 || TradeGrid_LowerPrice<=0
   f. TradeGrid_UpperPrice <= TradeGrid_LowerPrice
5. g_boAtrHandle = iATR(_Symbol, _Period, BreakoutDist_AtrPeriod)
   failure (==INVALID_HANDLE) → return INIT_FAILED
6. g_upper  = TradeGrid_UpperPrice
   g_lower  = TradeGrid_LowerPrice
   g_center = (g_upper + g_lower) / 2.0
   g_grid   = (g_upper - g_lower) / TradeGrid_GridCount
7. DrawLines()
8. DrawInfoPanelTrail()
9. PrintFormat("GridTrader v1.06 started. upper=%.5f center=%.5f lower=%.5f grids=%d spacing=%.5f", ...)
10. return INIT_SUCCEEDED
```

---

## 5. OnTick flow (exact order, every tick)

```
1. Spread filter:
   if(OnTick_MaxSpread > 0):
     spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD)
     if(spread > OnTick_MaxSpread) → return

2. double grid = g_grid   ← local alias

3. DrawInfoPanel()         ← panel refreshed every tick (internally cached; no object writes when unchanged)

4. Refresh price labels and breakout line positions on each new bar (static lblBar for per-bar throttling):
   static datetime lblBar = 0
   curBar = iTime(_Symbol, _Period, 0)
   if(DrawLines_ShowGraphics && curBar>0 && curBar!=lblBar):
     lblBar = curBar
     ObjectMove "GT_upper_lbl", "GT_center_lbl", "GT_lower_lbl"
     m = BreakoutDist()
     ObjectMove "GT_brk_up", "GT_brk_dn"
     b = ClampBuffer(BreakoutDist())
     ObjectMove "GT_rec_up", "GT_rec_dn"
     ChartRedraw(0)

5. if(HandleBreakout()) → return   ← breakout protection

6. if(CheckLossCut()) → return     ← loss cut on order count

7. Fixed take-profit (only when !TrailTotal_Enable && TpThreshold_BasePips>0):
   closedAny = false
   buyN    = CountSide(BUY)
   buyPips = TotalPipsByType(BUY)
   if(buyN>0 && buyPips>=TpThreshold_BasePips):
     PrintFormat(...)
     DrawCloseLabel("Buy TP", buyPips, BID)
     CloseSide(BUY)
     closedAny = true
   sellN    = CountSide(SELL)
   sellPips = TotalPipsByType(SELL)
   if(sellN>0 && sellPips>=TpThreshold_BasePips):
     PrintFormat(...)
     DrawCloseLabel("Sell TP", sellPips, ASK)
     CloseSide(SELL)
     closedAny = true
   if(closedAny) → return

8. Trailing stop (only when TrailTotal_Enable):
   if(TrailTotal()) → return

9. TradeGrid(grid)    ← grid entries
```

**Key: in step 7, buyN/buyPips are computed first, the buy group is checked and closed, then sellN/sellPips are computed independently and the sell group is checked and closed. The sell group is still checked even if the buy group was just closed.**

---

## 6. OnDeinit flow

```
1. if(g_boAtrHandle != INVALID_HANDLE) IndicatorRelease(g_boAtrHandle)
2. ChartRedraw(0)
3. No GT_ graphic objects are deleted
```

## 7. OnTester flow

Prints one statistics line (`STATS | NetProfit | MaxDD | PF | RF | Trades | WinRate`).
Return value = `TesterStatistics(STAT_PROFIT)`.

---

## 8. Exact specification of key algorithms

### 8.1 TradeGrid — signal evaluation (every tick)

```
tol     = g_grid * 0.25   // touch window, must be < release
release = g_grid * 0.75   // release threshold

// --- cooldown release (before arming) ---
if(g_lastSellLine != 0.0 && |bid - g_lastSellLine| > release) g_lastSellLine = 0.0
if(g_lastBuyLine  != 0.0 && |ask - g_lastBuyLine|  > release) g_lastBuyLine  = 0.0

// --- range check ---
buyInRange  = (ask >= g_lower && ask <= g_upper)
sellInRange = (bid >= g_lower && bid <= g_upper)

sellN = CountSide(SELL)
buyN  = CountSide(BUY)

// --- bound arming (after sellN/buyN are known) ---
if(bid >= g_upper - tol)          g_sellArmed = true
if(ask <= g_lower + tol)          g_buyArmed  = true
if(sellN==0 && bid < g_upper - release) g_sellArmed = false
if(buyN ==0 && ask > g_lower + release) g_buyArmed  = false

sellAllowed = (!TradeGrid_FirstAtEdge || sellN>0 || g_sellArmed)
buyAllowed  = (!TradeGrid_FirstAtEdge || buyN>0  || g_buyArmed)

// --- upper half: sells ---
if(TradeGrid_EnableSell && sellAllowed && sellInRange && g_lastSellLine==0.0):
  for k=1,2,...:
    line = g_center + k*g_grid
    if(line > g_upper + tol) → break
    if(|bid - line| <= tol && !HasOrderNear(SELL, line, g_grid)):
      OpenOrder(SELL, k, LotForLine(SELL, line, g_grid))
      g_lastSellLine = line
      break

// --- lower half: buys ---
if(TradeGrid_EnableBuy && buyAllowed && buyInRange && g_lastBuyLine==0.0):
  for k=1,2,...:
    line = g_center - k*g_grid
    if(line < g_lower - tol) → break
    if(|ask - line| <= tol && !HasOrderNear(BUY, line, g_grid)):
      OpenOrder(BUY, k, LotForLine(BUY, line, g_grid))
      g_lastBuyLine = line
      break
```

### 8.2 LotForLine — lot calculation (exact formula)

```
distEdge = Round((g_upper - line) / grid)   // SELL: cells from the upper bound
         = Round((line - g_lower) / grid)   // BUY:  cells from the lower bound
if(distEdge < 0) distEdge = 0
lots = LotForLine_InitLots - distEdge * LotForLine_ReducePerLine
if(lots < LotForLine_MinLots) lots = LotForLine_MinLots
return NormalizeLots(lots)
```

### 8.3 NormalizeLots — lot normalization

```
minLot  = SYMBOL_VOLUME_MIN
maxLot  = SYMBOL_VOLUME_MAX
lotStep = SYMBOL_VOLUME_STEP
if(lotStep > 0): lots = Floor(lots / lotStep) * lotStep   // round down
lots = Max(minLot, Min(maxLot, lots))
return NormalizeDouble(lots, 2)
```

**Note**: NormalizeLots(0) does not return 0, it returns minLot. LotForLine guarantees the input is ≥ MinLots, so this trap is not hit.

### 8.4 TotalPipsByType — total profit pips

```
bid = SymbolInfoDouble(SYMBOL_BID)
ask = SymbolInfoDouble(SYMBOL_ASK)
sum = 0
for each pos (reverse iteration, Symbol==_Symbol && Magic==CTrade_Magic && Type==type):
  open = pos.PriceOpen()
  pips_i = (type==BUY) ? (bid-open)/g_pip : (open-ask)/g_pip
  sum += pips_i * pos.Volume()
return (LotForLine_MinLots > 0) ? sum / LotForLine_MinLots : 0
```

### 8.5 FloatingPnL — side floating P/L (account currency)

```
for each pos (reverse iteration, Symbol==_Symbol && Magic==CTrade_Magic && Type==type):
  sum += pos.Profit() + pos.Swap()
return sum
```

### 8.6 HasOrderNear — same-side order already nearby

```
tol = grid * 0.5   // note: half a cell, not the touch window
for each pos (reverse iteration, Symbol==_Symbol && Magic==CTrade_Magic && Type==type):
  if |pos.PriceOpen() - line| < tol → return true   // strictly less than, not <=
return false
```

### 8.7 EffectiveKeepRatio — effective pullback keep ratio

```
if(n < 1) n = 1
pct = TrailTotal_KeepPct + (n-1) * TrailTotal_AddPerOrder
if(pct > 90) pct = 90
return pct / 100.0
```

Note: pct is integer arithmetic (all three operands are int, the result is int).

### 8.8 TpThreshold — trailing stop activation threshold

```
return TpThreshold_BasePips   // fixed, independent of the order count
```

### 8.9 TrailTotal — trailing stop logic (every tick)

```
startPips = TpThreshold()   // = TpThreshold_BasePips
closed = false

// buy group
buyN = CountSide(BUY)
if(buyN > 0):
  keepRatio = EffectiveKeepRatio(buyN)
  p = TotalPipsByType(BUY)
  if(p > g_trailPeakBuy) g_trailPeakBuy = p
  if(g_trailPeakBuy >= startPips && p <= g_trailPeakBuy * keepRatio):
    effPct = Round(keepRatio * 100)
    PrintFormat(...)
    CloseSide(BUY)
    DrawVLine(p>=startPips ? clrLime : clrYellow, 2, false)
    DrawCloseLabel("Buy Trail", p, BID)
    g_trailPeakBuy = 0.0
    closed = true
else:
  g_trailPeakBuy = 0.0

// sell group (same, using g_trailPeakSell, ASK and "Sell Trail")

return closed
```

**Key**: both the buy and the sell group are checked; the sell group is still checked even if the buy group was just closed.

### 8.10 CheckLossCut — loss cut on order count (every tick)

```
if(LossCut_MinOrders <= 0) return false
closed = false

buyN = CountSide(BUY)
if(buyN > LossCut_MinOrders):
  pnl = FloatingPnL(BUY)
  if(pnl < 0):
    DrawVLine(clrOrangeRed, 2, false)
    DrawCloseLabel("Buy LossCut", TotalPipsByType(BUY), BID)
    CloseSide(BUY)
    closed = true

sellN = CountSide(SELL)
if(sellN > LossCut_MinOrders):
  pnl = FloatingPnL(SELL)
  if(pnl < 0):
    DrawVLine(clrOrangeRed, 2, false)
    DrawCloseLabel("Sell LossCut", TotalPipsByType(SELL), ASK)
    CloseSide(SELL)
    closed = true

return closed
```

### 8.11 HandleBreakout — breakout handling (evaluated every tick)

```
bid    = SymbolInfoDouble(SYMBOL_BID)
ask    = SymbolInfoDouble(SYMBOL_ASK)
buffer = ClampBuffer(BreakoutDist())
out    = IsOutOfRange()                              // bid > upper+margin || ask < lower-margin
backInside = (bid <= g_upper-buffer && ask >= g_lower+buffer)

if(out && !g_outOfRange):                            // new breakout event
  brkBuyPips  = TotalPipsByType(BUY)
  brkSellPips = TotalPipsByType(SELL)
  brkTotal    = brkBuyPips + brkSellPips
  g_outOfRange = true
  PrintFormat("Out of range, closing all: bid=... is outside [...]")
  DrawVLine(clrDodgerBlue)
  DrawCloseLabel("Breakout SL", brkTotal, bid)

elif(backInside && g_outOfRange):                    // recovery event
  g_outOfRange = false
  PrintFormat("Back inside the range (buffer ... x ATR), resuming trading: bid=...")

if(g_outOfRange):
  CloseAll()   // per-tick safety-net close
  return true
return false
```

**v1.06 change**: there is no longer a `static evalBar` and the previous bar close `close1` is no longer used; the check now runs **every tick** on the current `bid/ask`,
and touching the bound (including long wick spikes) triggers immediately. While `g_outOfRange` is set, `CloseAll()` is called every tick (an empty loop once everything is closed, negligible cost).

### 8.12 BreakoutDist — breakout distance (ATR cached per bar)

```
if(BreakoutDist_AtrMult <= 0) return 0.0
if(g_boAtrHandle == INVALID_HANDLE) return 0.0
static datetime s_atrBar  = 0      // bar time of the last ATR read
static double   s_atrLast = 0.0    // cached ATR value
curBar = iTime(_Symbol, _Period, 0)
if(curBar > 0 && curBar != s_atrBar):              // read only once per new bar
  s_atrBar = curBar
  if(CopyBuffer(g_boAtrHandle, 0, 1, 1, atr) >= 1 && atr[0] > 0):
    s_atrLast = atr[0]                              // on read failure the old value is kept
return BreakoutDist_AtrMult * s_atrLast
```

**Note**: `CopyBuffer` reads 1 value from `shift=1` (the ATR of the last closed bar).
Note: if CopyBuffer fails on a bar, s_atrBar has already been updated to that bar, so it is not retried within the bar and the old s_atrLast keeps being used.
**v1.06 change**: added the `static s_atrBar/s_atrLast` per-bar cache to avoid a per-tick `CopyBuffer` slowing backtests
(after breakout detection moved to every tick, this function is called every tick). Before a value is read on the first bar `s_atrLast=0` (distance = 0, trigger on touch).

### 8.13 ClampBuffer — buffer clamp

```
maxBuf = (g_upper - g_lower) * 0.4
buffer = Min(buffer, maxBuf)
buffer = Max(buffer, 0)
return buffer
```

### 8.14 IsOutOfRange — breakout check (bid/ask every tick)

```
bid    = SymbolInfoDouble(SYMBOL_BID)
ask    = SymbolInfoDouble(SYMBOL_ASK)
margin = BreakoutDist()
return (bid > g_upper + margin || ask < g_lower - margin)
```

**v1.06 change**: the old version used the previous bar close `close1` (once per bar); the new version uses **the current tick's bid/ask** —
`bid` for an upside break, `ask` for a downside break, triggered in real time every tick.

---

## 9. Position iteration convention

Every position loop (CountSide, CloseSide, CloseAll, TotalPipsByType, FloatingPnL, HasOrderNear) uses:

```mql5
for(int i = PositionsTotal() - 1; i >= 0; i--)
{
   if(!pos.SelectByIndex(i)) continue;
   if(pos.Symbol() != _Symbol) continue;
   if(pos.Magic() != CTrade_Magic) continue;
   // direction filter (as the function needs)
   ...
}
```

**Reverse iteration** prevents index shifts after a position is closed.

---

## 10. Order open/close conventions

### OpenOrder
```
string cmt = "Grid Buy/Sell #k"   // k = cells from the center
trade.Buy(lots, _Symbol, 0.0, 0.0, 0.0, cmt)   // no SL/TP attached
trade.Sell(lots, _Symbol, 0.0, 0.0, 0.0, cmt)
// on failure: PrintFormat("Open failed ..."); no retry
```

### ClosePosition
```
trade.PositionClose(ticket)
// on failure: PrintFormat("Close failed ..."); no retry
```

---

## 11. Magic number usage

- `trade.SetExpertMagicNumber(CTrade_Magic)` is set globally in `OnInit`
- Every position filter loop checks `pos.Magic() != CTrade_Magic`
- `trade.Buy/Sell` automatically carries the configured magic

---

## 12. Evaluation timing

| Logic | When evaluated |
|------|---------|
| Grid entries (TradeGrid) | **every tick** |
| Fixed take-profit | **every tick** |
| Trailing stop (TrailTotal) | **every tick** |
| Loss cut on order count | **every tick** |
| Breakout state flip (HandleBreakout) | **every tick** (since v1.06, on the current bid/ask) |
| Price label / breakout line refresh | **once per new bar** (static lblBar) |
| ATR read (BreakoutDist) | **once per new bar** (s_atrBar cache; the value feeds the per-tick breakout check) |
| DrawInfoPanel refresh | **every tick** (content cached to reduce actual writes) |

---

## 13. Visualization

| Object name | Type | Created / updated |
|--------|------|------|
| `GT_upper`, `GT_center`, `GT_lower` | OBJ_HLINE | OnInit |
| `GT_g_u0~N`, `GT_g_d0~N` | OBJ_HLINE | OnInit (grid lines, background layer) |
| `GT_brk_up/dn` | OBJ_HLINE | OnInit + position updated each bar |
| `GT_rec_up/dn` | OBJ_HLINE | OnInit + position updated each bar |
| `GT_upper_lbl`, `GT_center_lbl`, `GT_lower_lbl` | OBJ_TEXT | OnInit + time anchor updated each bar |
| `GT_info_trail` | OBJ_LABEL | OnInit (DrawInfoPanelTrail) |
| `GT_info_buy`, `GT_info_sell` | OBJ_LABEL | every tick (DrawInfoPanel) |
| `GT_v_<timestamp>` | OBJ_VLINE | on close events |
| `GT_pips_<timestamp>[_N]` | OBJ_TEXT | on close events |

**OnDeinit does not delete any GT_ object.**
When `DrawLines_ShowGraphics=false`, no graphic object is created or updated.
Note: the number of grid line objects GT_g_u*/GT_g_d* is capped at 200 (creation loop gi<200).

---

## 14. Static variables (persisted across ticks)

| Function | Variable | Purpose |
|---------|------|------|
| `BreakoutDist` | `s_atrBar` (datetime), `s_atrLast` (double) | Read ATR once per bar and cache it (v1.06, replaces the deleted evalBar) |
| `OnTick` | `lblBar` (datetime) | Refresh label/breakout line positions only once per bar |
| `DrawInfoPanel` | `prevBuyTxt`, `prevBuyClr`, `prevSellTxt`, `prevSellClr` | Panel content cache |
