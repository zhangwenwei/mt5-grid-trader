# GridTrader 重构等价验证报告 (VERIFICATION.md)

> 验证者：独立 subagent（未参与重构）
> 对照基准：BASELINE.md + 原始代码（重构前 OnTick 内联逻辑）

---

## 总体结论

**PASS — 40/40 项全部通过，行为完全等价**

重构的唯一实质性变化是将 OnTick 内联的固定止盈块提取为 `Mgmt_FixedTP()` 函数，
其余仅为函数重排。验证确认所有路径行为与原版一致。

---

## 逐项验证

| # | 检查项 | 结论 | 说明 |
|---|--------|------|------|
| **A. OnTick 调用顺序** | | | |
| A1 | 点差过滤在最前 | **PASS** | `if(OnTick_MaxSpread > 0)` 是 OnTick 第一个有效语句 |
| A2 | `double grid = g_grid` 在点差过滤后立即声明 | **PASS** | 点差过滤块之后立即 `double grid = g_grid;` |
| A3 | `DrawInfoPanel()` 在 grid 声明后立即调用 | **PASS** | 紧接 grid 声明之后调用 |
| A4 | lblBar 标签刷新块在 DrawInfoPanel 后 | **PASS** | `static datetime lblBar = 0` 块在 DrawInfoPanel 之后 |
| A5 | `HandleBreakout()` 在标签刷新后，true→return | **PASS** | `if(HandleBreakout()) return;` 位于 lblBar 块之后 |
| A6 | `CheckLossCut()` 在 HandleBreakout 后，true→return | **PASS** | `if(CheckLossCut()) return;` 紧接其后 |
| A7 | 固定止盈在 CheckLossCut 后（条件：`!TrailTotal_Enable && BasePips>0`） | **PASS** | 条件与原版完全一致 |
| A8 | 移动止损在固定止盈后（条件：`TrailTotal_Enable`） | **PASS** | `if(TrailTotal_Enable && TrailTotal()) return;` |
| A9 | `TradeGrid(grid)` 在最后 | **PASS** | OnTick 最后一条语句 |
| **B. Mgmt_FixedTP() 等价性（核心变更）** | | | |
| B10 | 买组：先 CountSide(BUY)，再 TotalPipsByType(BUY)，条件 `buyN>0 && buyPips>=BasePips` | **PASS** | 顺序与条件均一致 |
| B11 | 买组 PrintFormat 格式字符串与原版一致 | **PASS** | `"买组止盈触发: 买组总体盈利 %.1f 总pips >= %d, 平掉所有买单"` 与原版内联代码逐字节一致（已核对原始代码） |
| B12 | 买组触发：`DrawCloseLabel("买TP", buyPips, BID)` 参数与原版一致 | **PASS** | `DrawCloseLabel("买TP", buyPips, SymbolInfoDouble(_Symbol, SYMBOL_BID))` |
| B13 | 买组触发后 `closedAny=true`，**不立即 return**，继续检查卖组 | **PASS** | `closedAny=true` 后无 return，继续执行卖组检查 |
| B14 | 卖组：独立的 `CountSide(SELL)` 和 `TotalPipsByType(SELL)`（不复用买组变量） | **PASS** | 独立声明 `sellN` / `sellPips`，不复用买组变量 |
| B15 | 卖组 PrintFormat 格式字符串与原版一致 | **PASS** | `"卖组止盈触发: 卖组总体盈利 %.1f 总pips >= %d, 平掉所有卖单"` 与原版逐字节一致 |
| B16 | 卖组触发：`DrawCloseLabel("卖TP", sellPips, ASK)` 参数与原版一致 | **PASS** | `DrawCloseLabel("卖TP", sellPips, SymbolInfoDouble(_Symbol, SYMBOL_ASK))` |
| B17 | 卖组触发后 `closedAny=true` | **PASS** | 正确设置 |
| B18 | 返回值等价：原版 `if(closedAny) return` = 新版 `if(Mgmt_FixedTP()) return` | **PASS** | `return(closedAny)` + 调用方 `if(Mgmt_FixedTP()) return;`，语义完全等价 |
| **C. 所有函数体完整性** | | | |
| C19 | `TradeGrid()` 与 BASELINE 8.1 一致（tol/release/冷却/武装/循环） | **PASS** | `tol=grid*0.25`，`release=grid*0.75`；冷却解锁在 CountSide 之前；武装判断在 CountSide 之后；循环结构逐行一致 |
| C20 | `LotForLine()` 精确公式：distEdge 用 MathRound，封底 MinLots，返回 NormalizeLots | **PASS** | `(int)MathRound(…)`；封底 MinLots；`return(NormalizeLots(lots))` |
| C21 | `NormalizeLots()` MathFloor 向下取整，夹到 [min,max]，NormalizeDouble(x,2) | **PASS** | 三步均正确 |
| C22 | `TotalPipsByType()` 买:(bid-open)/g_pip×vol，卖:(open-ask)/g_pip×vol，sum/MinLots | **PASS** | 公式与 BASELINE 8.4 一致 |
| C23 | `HasOrderNear()` tol=grid*0.5，条件 `< tol`（严格小于） | **PASS** | `grid * 0.5`；`MathAbs(...) < tol`（非 <=） |
| C24 | `HandleBreakout()` 静态 evalBar，每 bar 只判断一次，`g_outOfRange` 期间逐 tick CloseAll | **PASS** | `static datetime evalBar = 0`；`curBar != evalBar` 守卫；越界期逐 tick `CloseAll()` |
| C25 | `TrailTotal()` 峰值更新在触发判断前，触发后峰值归零 | **PASS** | 先 `if(p > g_trailPeak) g_trailPeak = p`，再判触发，触发后 `g_trailPeak = 0.0`；买/卖各自独立 |
| C26 | `CheckLossCut()` `LossCut_MinOrders<=0` 直接返回 false | **PASS** | 函数第一句即提前返回 |
| C27 | `EffectiveKeepRatio()` pct 上限 90，return pct/100.0 | **PASS** | `if(pct > 90) pct = 90`；`return(pct / 100.0)` |
| C28 | `FloatingPnL()` Σ(Profit+Swap)，过滤 Symbol+Magic+Type | **PASS** | 三重过滤 + `pos.Profit() + pos.Swap()` 累加 |
| C29 | `BreakoutDist()` CopyBuffer shift=1（上一根已收盘 ATR） | **PASS** | `CopyBuffer(g_boAtrHandle, 0, 1, 1, atr)`，第三参数=1 |
| C30 | `ClampBuffer()` maxBuf=(upper-lower)*0.4 | **PASS** | `(g_upper - g_lower) * 0.4` |
| **D. 全局状态与生命周期** | | | |
| D31 | 所有全局变量名称、类型、初始值与原版一致 | **PASS** | 15 个全局变量全部核对，无差异 |
| D32 | `OnInit()` 参数校验顺序与 BASELINE 4 节一致 | **PASS** | a→b→c→d→e→f 六步顺序完全对应 |
| D33 | `OnDeinit()` 释放 ATR 句柄，不删 GT_ 对象 | **PASS** | `IndicatorRelease`；无任何 `ObjectDelete("GT_…")` 调用 |
| D34 | `OnTester()` 返回 STAT_PROFIT | **PASS** | `return(profit)` 其中 `profit = TesterStatistics(STAT_PROFIT)` |
| **E. 函数可见性** | | | |
| E35 | `Mgmt_FixedTP()` 调用 `DrawCloseLabel`（在其后定义）MQL5 允许 | **PASS** | MQL5 不要求前向声明，编译器扫描整个文件后解析所有符号 |
| E36 | OnTick 中所有被调函数均在同一文件定义 | **PASS** | `DrawInfoPanel`/`HandleBreakout`/`CheckLossCut`/`Mgmt_FixedTP`/`TrailTotal`/`TradeGrid` 全部定义于 GridTrader.mq5 |
| **F. 潜在差异重点排查** | | | |
| F37 | `Mgmt_FixedTP` 买组平仓后仍检查卖组（双检行为） | **PASS** | `closedAny=true` 后无 return，继续卖组；与原版 `if(closedAny) return` 置于两组后完全等价 |
| F38 | `TrailTotal` 买组平仓后仍检查卖组 | **PASS** | `closed` 汇总两组，函数末尾统一 `return(closed)` |
| F39 | `DrawInfoPanel` 的 4 个 static 变量保留 | **PASS** | `prevBuyTxt`/`prevBuyClr`/`prevSellTxt`/`prevSellClr` 全部保留 |
| F40 | `HandleBreakout` 的 static evalBar 保留 | **PASS** | `static datetime evalBar = 0;` 保留 |

---

## 发现的差异

**无 FAIL 项。**

---

## 重构结构变化摘要（供参考）

| 变化 | 性质 | 对交易行为的影响 |
|------|------|----------------|
| 函数重排为 7 个模块 | 纯结构 | 无（MQL5 函数调用不依赖定义顺序） |
| 新增 `Mgmt_FixedTP()` | 提取内联为函数 | 无（完全等价，见 B10–B18） |
| OnTick 固定止盈块改为函数调用 | 重构 | 无（逻辑路径完全相同） |

---

## Strategy Tester A/B 对比验证步骤

> 建议在完成代码验证后，用 Strategy Tester 做实证对比，结果应完全一致。

**准备**：在重构前用 `git stash` 或 `git show HEAD~1:GridTrader.mq5 > GridTrader_orig.mq5` 保存原版，
或直接对比 `git diff HEAD~1..HEAD GridTrader.mq5` 确认差异仅为函数重排。

**A/B 对比参数（两次测试参数必须逐字段相同）**：

```
品种:      选定一个（如 USDJPY）
周期:      H1（或任意固定周期）
起止时间:  2024-01-01 ~ 2024-06-30（或任意固定区间）
建模方式:  每个 tick（仅当价格）
初始资金:  10000 USD
杠杆:      1:100
```

**对比指标（两份报告必须完全一致）**：
1. 总成交笔数
2. 每笔交易的：时间戳 / 方向 / 手数 / 开仓价 / 平仓价 / 盈亏
3. 净利润
4. 最大回撤（货币 & 百分比）
5. 净值曲线形状

**不一致时的排查思路**：
- 第一笔出现差异的时刻 → 对比该时刻 OnTick 调用路径
- 重点检查 `Mgmt_FixedTP` 的双检行为是否在买组平仓时卖组仍被检查
