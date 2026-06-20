# GridTrader EA — 行为基线 (BASELINE.md)

> 本文件是重构前的完整行为契约，所有等价验证以此为基准。
> 对应代码：GridTrader.mq5 v1.05，提交 a5053bd。

---

## 1. EA 基本属性

| 属性 | 值 |
|------|----|
| 文件 | GridTrader.mq5 |
| 版本 | `#property version "1.05"` |
| 账户模式 | 对冲 (Hedging)，MQL5 |
| 依赖库 | `<Trade\Trade.mqh>`、`<Trade\PositionInfo.mqh>` |
| 全局对象 | `CTrade trade;`、`CPositionInfo pos;` |

---

## 2. 所有 Input 参数及默认值

### 2.1 方向开关
| 参数 | 类型 | 默认值 |
|------|------|--------|
| `TradeGrid_EnableBuy` | bool | true |
| `TradeGrid_EnableSell` | bool | true |

### 2.2 网格区间（人工必填）
| 参数 | 类型 | 默认值 | 约束 |
|------|------|--------|------|
| `TradeGrid_UpperPrice` | double | 0 | >0，且 > LowerPrice |
| `TradeGrid_LowerPrice` | double | 0 | >0 |

### 2.3 网格设置
| 参数 | 类型 | 默认值 | 约束 |
|------|------|--------|------|
| `TradeGrid_GridCount` | int | 10 | ≥2 |
| `TradeGrid_FirstAtEdge` | bool | true | — |

### 2.4 阶梯手数
| 参数 | 类型 | 默认值 | 约束 |
|------|------|--------|------|
| `LotForLine_InitLots` | double | 0.01 | >0，≥MinLots |
| `LotForLine_ReducePerLine` | double | 0.0 | ≥0 |
| `LotForLine_MinLots` | double | 0.01 | >0 |

### 2.5 方向总体止盈
| 参数 | 类型 | 默认值 |
|------|------|--------|
| `TpThreshold_BasePips` | int | 30 |

### 2.6 移动止损
| 参数 | 类型 | 默认值 | 约束 |
|------|------|--------|------|
| `TrailTotal_Enable` | bool | false | — |
| `TrailTotal_KeepPct` | int | 70 | (0,100)，仅 Enable 时校验 |
| `TrailTotal_AddPerOrder` | int | 0 | ≥0 |

### 2.7 越界判断
| 参数 | 类型 | 默认值 |
|------|------|--------|
| `BreakoutDist_AtrMult` | double | 1.0 |
| `BreakoutDist_AtrPeriod` | int | 14 |

### 2.8 超单亏损保护
| 参数 | 类型 | 默认值 |
|------|------|--------|
| `LossCut_MinOrders` | int | 0 (关闭) |

### 2.9 过滤与风控
| 参数 | 类型 | 默认值 |
|------|------|--------|
| `OnTick_MaxSpread` | int | 0 (不限) |
| `CTrade_Magic` | long | 20240601 |
| `CTrade_Slippage` | ulong | 30 |

### 2.10 图形显示
| 参数 | 类型 | 默认值 |
|------|------|--------|
| `DrawLines_ShowGraphics` | bool | true |

---

## 3. 全局状态变量

| 变量 | 类型 | 初始值 | 说明 |
|------|------|--------|------|
| `g_pip` | double | 0.0 | 1 pip 的价格单位 |
| `g_point` | double | 0.0 | 1 point |
| `g_digits` | int | 0 | 价格小数位 |
| `g_center` | double | 0.0 | 中线 = (上界+下界)/2 |
| `g_upper` | double | 0.0 | 网格上边界 |
| `g_lower` | double | 0.0 | 网格下边界 |
| `g_grid` | double | 0.0 | 格距 = (上-下)/GridCount |
| `g_lastBuyLine` | double | 0.0 | 上次开多的网格线价格（0=已武装） |
| `g_lastSellLine` | double | 0.0 | 上次开空的网格线价格（0=已武装） |
| `g_sellArmed` | bool | false | 卖组是否已触碰上界 |
| `g_buyArmed` | bool | false | 买组是否已触碰下界 |
| `g_trailPeakBuy` | double | 0.0 | 买组总pips历史峰值 |
| `g_trailPeakSell` | double | 0.0 | 卖组总pips历史峰值 |
| `g_boAtrHandle` | int | INVALID_HANDLE | ATR指标句柄 |
| `g_outOfRange` | bool | false | 当前是否处于越界暂停 |

---

## 4. OnInit 流程（精确顺序）

```
1. TesterHideIndicators(true)
2. g_point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT)
   g_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)
   g_pip    = (g_digits==3 || g_digits==5) ? 10*g_point : g_point
3. trade.SetExpertMagicNumber(CTrade_Magic)
   trade.SetDeviationInPoints(CTrade_Slippage)
   trade.SetTypeFillingBySymbol(_Symbol)
4. 参数校验（按序，任一失败 → return INIT_PARAMETERS_INCORRECT）
   a. TradeGrid_GridCount < 2
   b. LotForLine_InitLots<=0 || LotForLine_MinLots<=0 ||
      LotForLine_ReducePerLine<0 || LotForLine_InitLots<LotForLine_MinLots
   c. TrailTotal_AddPerOrder < 0
   d. TrailTotal_Enable==true 时:
      TrailTotal_KeepPct<=0 || TrailTotal_KeepPct>=100 || TpThreshold_BasePips<=0
   e. TradeGrid_UpperPrice<=0 || TradeGrid_LowerPrice<=0
   f. TradeGrid_UpperPrice <= TradeGrid_LowerPrice
5. g_boAtrHandle = iATR(_Symbol, _Period, BreakoutDist_AtrPeriod)
   失败(==INVALID_HANDLE) → return INIT_FAILED
6. g_upper  = TradeGrid_UpperPrice
   g_lower  = TradeGrid_LowerPrice
   g_center = (g_upper + g_lower) / 2.0
   g_grid   = (g_upper - g_lower) / TradeGrid_GridCount
7. DrawLines()
8. DrawInfoPanelTrail()
9. PrintFormat("GridTrader v3 启动. ...")
10. return INIT_SUCCEEDED
```

---

## 5. OnTick 流程（精确顺序，每个 tick）

```
1. 点差过滤:
   if(OnTick_MaxSpread > 0):
     spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD)
     if(spread > OnTick_MaxSpread) → return

2. double grid = g_grid   ← 本地别名

3. DrawInfoPanel()         ← 逐tick刷新面板（内部有缓存，无变化不写对象）

4. 每根新bar刷新价格标签和越界线位置（静态变量 lblBar 做 bar 节流）:
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

5. if(HandleBreakout()) → return   ← 越界保护

6. if(CheckLossCut()) → return     ← 超单亏损保护

7. 固定止盈（仅 !TrailTotal_Enable && TpThreshold_BasePips>0 时）:
   closedAny = false
   buyN    = CountSide(BUY)
   buyPips = TotalPipsByType(BUY)
   if(buyN>0 && buyPips>=TpThreshold_BasePips):
     PrintFormat(...)
     DrawCloseLabel("买TP", buyPips, BID)
     CloseSide(BUY)
     closedAny = true
   sellN    = CountSide(SELL)
   sellPips = TotalPipsByType(SELL)
   if(sellN>0 && sellPips>=TpThreshold_BasePips):
     PrintFormat(...)
     DrawCloseLabel("卖TP", sellPips, ASK)
     CloseSide(SELL)
     closedAny = true
   if(closedAny) → return

8. 移动止损（仅 TrailTotal_Enable 时）:
   if(TrailTotal()) → return

9. TradeGrid(grid)    ← 网格开单
```

**关键：步骤 7 中先计算 buyN/buyPips，再判断并关闭买组，然后独立计算 sellN/sellPips 再判断关闭卖组。即使买组已平，仍检查卖组。**

---

## 6. OnDeinit 流程

```
1. if(g_boAtrHandle != INVALID_HANDLE) IndicatorRelease(g_boAtrHandle)
2. ChartRedraw(0)
3. 不删除任何 GT_ 图形对象
```

## 7. OnTester 流程

打印统计行（STATS | 净利 | 最大回撤 | 盈利因子 | 恢复因子 | 笔数 | 胜率）。
返回值 = `TesterStatistics(STAT_PROFIT)`。

---

## 8. 关键算法精确规格

### 8.1 TradeGrid — 信号判断（每 tick）

```
tol     = g_grid * 0.25   // 触碰窗，必须 < release
release = g_grid * 0.75   // 解锁门槛

// --- 冷却解锁（先于武装判断） ---
if(g_lastSellLine != 0.0 && |bid - g_lastSellLine| > release) g_lastSellLine = 0.0
if(g_lastBuyLine  != 0.0 && |ask - g_lastBuyLine|  > release) g_lastBuyLine  = 0.0

// --- 区间确认 ---
buyInRange  = (ask >= g_lower && ask <= g_upper)
sellInRange = (bid >= g_lower && bid <= g_upper)

sellN = CountSide(SELL)
buyN  = CountSide(BUY)

// --- 边界武装（在 sellN/buyN 确定后） ---
if(bid >= g_upper - tol)          g_sellArmed = true
if(ask <= g_lower + tol)          g_buyArmed  = true
if(sellN==0 && bid < g_upper - release) g_sellArmed = false
if(buyN ==0 && ask > g_lower + release) g_buyArmed  = false

sellAllowed = (!TradeGrid_FirstAtEdge || sellN>0 || g_sellArmed)
buyAllowed  = (!TradeGrid_FirstAtEdge || buyN>0  || g_buyArmed)

// --- 上半区开空 ---
if(TradeGrid_EnableSell && sellAllowed && sellInRange && g_lastSellLine==0.0):
  for k=1,2,...:
    line = g_center + k*g_grid
    if(line > g_upper + tol) → break
    if(|bid - line| <= tol && !HasOrderNear(SELL, line, g_grid)):
      OpenOrder(SELL, k, LotForLine(SELL, line, g_grid))
      g_lastSellLine = line
      break

// --- 下半区开多 ---
if(TradeGrid_EnableBuy && buyAllowed && buyInRange && g_lastBuyLine==0.0):
  for k=1,2,...:
    line = g_center - k*g_grid
    if(line < g_lower - tol) → break
    if(|ask - line| <= tol && !HasOrderNear(BUY, line, g_grid)):
      OpenOrder(BUY, k, LotForLine(BUY, line, g_grid))
      g_lastBuyLine = line
      break
```

### 8.2 LotForLine — 手数计算（精确公式）

```
distEdge = Round((g_upper - line) / grid)   // SELL: 距上界格数
         = Round((line - g_lower) / grid)   // BUY:  距下界格数
if(distEdge < 0) distEdge = 0
lots = LotForLine_InitLots - distEdge * LotForLine_ReducePerLine
if(lots < LotForLine_MinLots) lots = LotForLine_MinLots
return NormalizeLots(lots)
```

### 8.3 NormalizeLots — 手数规范化

```
minLot  = SYMBOL_VOLUME_MIN
maxLot  = SYMBOL_VOLUME_MAX
lotStep = SYMBOL_VOLUME_STEP
if(lotStep > 0): lots = Floor(lots / lotStep) * lotStep   // 向下取整
lots = Max(minLot, Min(maxLot, lots))
return NormalizeDouble(lots, 2)
```

**注意**：NormalizeLots(0) 不返回 0，返回 minLot。LotForLine 保证传入值 ≥ MinLots，故不触发此陷阱。

### 8.4 TotalPipsByType — 总体盈利 pips

```
bid = SymbolInfoDouble(SYMBOL_BID)
ask = SymbolInfoDouble(SYMBOL_ASK)
sum = 0
for each pos (倒序遍历, Symbol==_Symbol && Magic==CTrade_Magic && Type==type):
  open = pos.PriceOpen()
  pips_i = (type==BUY) ? (bid-open)/g_pip : (open-ask)/g_pip
  sum += pips_i * pos.Volume()
return (LotForLine_MinLots > 0) ? sum / LotForLine_MinLots : 0
```

### 8.5 FloatingPnL — 方向浮盈（账户货币）

```
for each pos (倒序遍历, Symbol==_Symbol && Magic==CTrade_Magic && Type==type):
  sum += pos.Profit() + pos.Swap()
return sum
```

### 8.6 HasOrderNear — 附近是否已有同向单

```
tol = grid * 0.5   // 注意：用半格，非触碰窗
for each pos (倒序遍历, Symbol==_Symbol && Magic==CTrade_Magic && Type==type):
  if |pos.PriceOpen() - line| < tol → return true   // 严格小于，非 <=
return false
```

### 8.7 EffectiveKeepRatio — 有效回撤触发比例

```
if(n < 1) n = 1
pct = TrailTotal_KeepPct + (n-1) * TrailTotal_AddPerOrder
if(pct > 90) pct = 90
return pct / 100.0
```

### 8.8 TpThreshold — 移动止损启动阈值

```
return TpThreshold_BasePips   // 固定值，不随单数变
```

### 8.9 TrailTotal — 移动止损逻辑（每 tick）

```
startPips = TpThreshold()   // = TpThreshold_BasePips
closed = false

// 买组
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
    DrawCloseLabel("买移止", p, BID)
    g_trailPeakBuy = 0.0
    closed = true
else:
  g_trailPeakBuy = 0.0

// 卖组（同理，用 g_trailPeakSell、ASK）

return closed
```

**关键**：买组和卖组都会检查，即使买组已平，卖组仍然检查。

### 8.10 CheckLossCut — 超单亏损保护（每 tick）

```
if(LossCut_MinOrders <= 0) return false
closed = false

buyN = CountSide(BUY)
if(buyN > LossCut_MinOrders):
  pnl = FloatingPnL(BUY)
  if(pnl < 0):
    DrawVLine(clrOrangeRed, 2, false)
    DrawCloseLabel("买超单止损", TotalPipsByType(BUY), BID)
    CloseSide(BUY)
    closed = true

sellN = CountSide(SELL)
if(sellN > LossCut_MinOrders):
  pnl = FloatingPnL(SELL)
  if(pnl < 0):
    DrawVLine(clrOrangeRed, 2, false)
    DrawCloseLabel("卖超单止损", TotalPipsByType(SELL), ASK)
    CloseSide(SELL)
    closed = true

return closed
```

### 8.11 HandleBreakout — 越界处理（每根新 bar 才判断）

```
static datetime evalBar = 0
curBar = iTime(_Symbol, _Period, 0)
if(curBar > 0 && curBar != evalBar):
  evalBar = curBar
  close1 = iClose(_Symbol, _Period, 1)
  if(close1 > 0):
    buffer   = ClampBuffer(BreakoutDist())
    out      = IsOutOfRange()                         // close1 > upper+margin || < lower-margin
    backInside = (close1 <= g_upper-buffer && close1 >= g_lower+buffer)

    if(out && !g_outOfRange):                         // 新越界事件
      brkBuyPips  = TotalPipsByType(BUY)
      brkSellPips = TotalPipsByType(SELL)
      brkTotal    = brkBuyPips + brkSellPips
      g_outOfRange = true
      PrintFormat(...)
      DrawVLine(clrDodgerBlue)
      DrawCloseLabel("越界止损", brkTotal, BID)

    elif(backInside && g_outOfRange):                 // 恢复事件
      g_outOfRange = false
      PrintFormat(...)

if(g_outOfRange):
  CloseAll()   // 逐tick兜底平仓
  return true
return false
```

**关键**：`g_outOfRange` 期间每 tick 调用 `CloseAll()`（已平时空循环，开销可忽略）。

### 8.12 BreakoutDist — 越界距离

```
if(BreakoutDist_AtrMult <= 0) return 0.0
if(g_boAtrHandle == INVALID_HANDLE) return 0.0
if(CopyBuffer(g_boAtrHandle, 0, 1, 1, atr) < 1 || atr[0] <= 0) return 0.0
return BreakoutDist_AtrMult * atr[0]
```

**注意**：`CopyBuffer` 从 `shift=1` 取 1 根（上一根已收盘 bar 的 ATR）。

### 8.13 ClampBuffer — 缓冲限幅

```
maxBuf = (g_upper - g_lower) * 0.4
buffer = Min(buffer, maxBuf)
buffer = Max(buffer, 0)
return buffer
```

### 8.14 IsOutOfRange — 越界判断

```
close1 = iClose(_Symbol, _Period, 1)
if(close1 <= 0) return false
margin = BreakoutDist()
return (close1 > g_upper + margin || close1 < g_lower - margin)
```

---

## 9. 持仓遍历规范

所有持仓循环（CountSide、CloseSide、CloseAll、TotalPipsByType、FloatingPnL、HasOrderNear）均使用：

```mql5
for(int i = PositionsTotal() - 1; i >= 0; i--)
{
   if(!pos.SelectByIndex(i)) continue;
   if(pos.Symbol() != _Symbol) continue;
   if(pos.Magic() != CTrade_Magic) continue;
   // 方向过滤（按函数需要）
   ...
}
```

**倒序遍历** 防止平仓后索引偏移。

---

## 10. 下单与平仓规范

### OpenOrder
```
string cmt = "Grid Buy/Sell #k"   // k = 距中线第几格
trade.Buy(lots, _Symbol, 0.0, 0.0, 0.0, cmt)   // 不挂 SL/TP
trade.Sell(lots, _Symbol, 0.0, 0.0, 0.0, cmt)
// 失败: PrintFormat("开仓失败 ..."); 不重试
```

### ClosePosition
```
trade.PositionClose(ticket)
// 失败: PrintFormat("平仓失败 ..."); 不重试
```

---

## 11. Magic Number 用法

- `OnInit` 中 `trade.SetExpertMagicNumber(CTrade_Magic)` 全局设置
- 所有持仓过滤循环均检查 `pos.Magic() != CTrade_Magic`
- `trade.Buy/Sell` 会自动带上已设置的 magic

---

## 12. 信号判断时机

| 逻辑 | 判断时机 |
|------|---------|
| 网格开单 (TradeGrid) | **每个 tick** |
| 固定止盈 | **每个 tick** |
| 移动止损 (TrailTotal) | **每个 tick** |
| 超单亏损保护 | **每个 tick** |
| 越界状态翻转 (HandleBreakout) | **每根新 bar 一次**（evalBar 静态变量）|
| 价格标签/越界线刷新 | **每根新 bar 一次**（lblBar 静态变量）|
| DrawInfoPanel 刷新 | **每个 tick**（内容缓存，减少实际写入）|

---

## 13. 可视化规范

| 对象名 | 类型 | 触发 |
|--------|------|------|
| `GT_upper`, `GT_center`, `GT_lower` | OBJ_HLINE | OnInit |
| `GT_g_u0~N`, `GT_g_d0~N` | OBJ_HLINE | OnInit（网格线，背景层）|
| `GT_brk_up/dn` | OBJ_HLINE | OnInit + 每bar更新位置 |
| `GT_rec_up/dn` | OBJ_HLINE | OnInit + 每bar更新位置 |
| `GT_upper_lbl`, `GT_center_lbl`, `GT_lower_lbl` | OBJ_TEXT | OnInit + 每bar更新时间锚 |
| `GT_info_trail` | OBJ_LABEL | OnInit (DrawInfoPanelTrail) |
| `GT_info_buy`, `GT_info_sell` | OBJ_LABEL | 每tick (DrawInfoPanel) |
| `GT_v_<timestamp>` | OBJ_VLINE | 平仓事件触发 |
| `GT_pips_<timestamp>[_N]` | OBJ_TEXT | 平仓事件触发 |

**OnDeinit 不删除任何 GT_ 对象。**
`DrawLines_ShowGraphics=false` 时不创建/更新任何图形对象。

---

## 14. 静态变量（跨 tick 持久化）

| 所在函数 | 变量 | 作用 |
|---------|------|------|
| `HandleBreakout` | `evalBar` (datetime) | 每 bar 只评估一次越界 |
| `OnTick` | `lblBar` (datetime) | 每 bar 只刷新一次标签 |
| `DrawInfoPanel` | `prevBuyTxt`, `prevBuyClr`, `prevSellTxt`, `prevSellClr` | 面板内容缓存 |
