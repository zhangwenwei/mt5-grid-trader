# GridTrader —— MT5 区间双向网格 EA

MT5 区间双向网格 EA（单一策略）：上半做空 / 下半做多、逆势回归；止盈用「方向总体 · 手数加权累加 总pips」，可选移动止损（峰值回撤到百分之多少），下单用阶梯手数。开发 / 修改本项目时遵守以下约定。**改动前先读代码、勿做反。**

## 项目定位
- 单文件 EA：`GridTrader.mq5`（MQL5，对冲账户 Hedging 模式）。
- 仓库：https://github.com/zhangwenwei/mt5-grid-trader （只传源码 mq5；ex5/log/.claude 已被 .gitignore 排除）。
- 编译产物 `GridTrader.ex5`、日志 `GridTrader.log` 不进版本控制。

## 策略逻辑（单一策略，`TradeGrid`）
- **上半区做空**：从 `中线+1格` 起每隔一格一条网格线，铺到上界；价格触碰某线即开空。
- **下半区做多**：从 `中线-1格` 起每隔一格一条网格线，铺到下界；价格触碰某线即开多。
- **中线不开单**（循环从 k=1 起）。做空线都在中线上方、做多线都在中线下方——**中线是起点(内边界)，不是终点**；铺线终点是上/下界（`line > 上界+tol` / `< 下界-tol` 时停）。**没有"加到中线为止"那种逻辑**（那是已删的边界顺势策略的概念）。
- **开单同时满足**：方向开关(`TradeGrid_EnableSell/Buy`)、当前 bid/ask 在区间内、该方向冷却已武装(`g_lastSellLine/BuyLine==0`)、价格进入网格线 `±tol`、`HasOrderNear` 该线半格内无同向单。**同向持仓上限由网格线数(≈格数/2)天然封顶。**
- **上下边界**：`TradeGrid_UpperPrice`/`TradeGrid_LowerPrice` **人工必填**(>0 且 上>下)，`g_center=(上+下)/2` 自动算；无自动定界，非法则 OnInit 拒绝启动。
- **网格数量 `TradeGrid_GridCount`**(整数, 须≥2)：把区间等分成这么多格, 格距 `g_grid=(上界−下界)/TradeGrid_GridCount` 在 OnInit 自动算并存全局。偶数格时中线恰落在一条网格线上被跳过、开单线数=格数；奇数格时中线不在线上、最外侧线距边界半格。
- **第一单须触碰边界 `TradeGrid_FirstAtEdge`**(默认开)：某方向空仓时第一单必须等价格先碰**裸边界**（空 `bid≥g_upper−tol` / 多 `ask≤g_lower+tol`）才开，避免区间中部就开单；加仓不受限；空仓且价格离开边界超 `release` 则撤防(`g_sellArmed`/`g_buyArmed`)。

## 阶梯手数（`LotForLine`）
- **靠边界大、向中线递减**：`lots = LotForLine_InitLots − distEdge×LotForLine_ReducePerLine`，封底 `LotForLine_MinLots`。
  - `distEdge` = 该网格线距所属边界的格数（最靠边界=0 → `LotForLine_InitLots` 最大）。
  - `LotForLine_ReducePerLine=0` 即所有格固定 `LotForLine_InitLots`。
- `NormalizeLots` 按 lot step 向下取整并夹到 [min,max]；注意它会把 0 抬到最小手，故开单前 `LotForLine` 已保证 ≥ `LotForLine_MinLots`。

## 止盈与移动止损（唯一主动出场，二者互斥）
- **计量 = 总体盈利 总pips**(手数加权累加, 非平均)：`TotalPipsByType` = `Σ(单pips×手数)/LotForLine_MinLots`；多单 `(bid-open)/g_pip`、空单 `(open-ask)/g_pip`。**全组累加再归一到最小手**(故单数越多/手数越大越易达标; 全是最小手时=各单 pips 简单相加)，**纯价差不含手续费、不是平均、不是货币**。已无单笔止盈，开单不挂 TP（SL/TP 全传 0）。
- **方向总体止盈**(移动止损关时)：买/卖各自，总体盈利(总pips)达 `TpThreshold_BasePips` → `CloseSide` 平该方向全部。
- **移动止损 `TrailTotal_Enable`**(ON 替代总体止盈，`TrailTotal`)：总体盈利(总pips)峰值达 `TpThreshold_BasePips`（**固定阈值，不随单数变**）启动记峰值(`g_trailPeakBuy/Sell`)，当前值**回撤到 `峰值×EffectiveKeepRatio(单数)`** → 平该方向整组；**纯内部跟踪、不挂 broker SL**。`TrailTotal_KeepPct` 须在 (0,100)。**语义=「回撤到峰值的百分之多少就平」(保留比例)**——值越大跟踪越紧(回吐越少), 例 80=跌到峰值80%即平(回吐20%)。
- **动态回撤触发比例 `EffectiveKeepRatio(n)`**（移动止损专用）：回撤触发比例随持仓单数线性收紧 = `(TrailTotal_KeepPct + (单数-1)×TrailTotal_AddPerOrder) / 100`，上限 90%。`TrailTotal_AddPerOrder=0`(默认)即固定为 `TrailTotal_KeepPct`，不随单数变。须 `TrailTotal_AddPerOrder>=0`。注: 加仓使单数+1→回撤触发比例收紧，武装状态不受影响（武装条件是峰值≥固定阈值）。
- `TpThreshold_BasePips` 一参兼任：关移动止损=固定平仓阈值；开=移动止损启动阈值（固定值，不随单数变）。`TrailTotal_AddPerOrder` 控制**回撤触发比例**随单数收紧（只在移动止损模式下生效）。

## 超单亏损保护（`CheckLossCut`）
- **参数 `LossCut_MinOrders`**（默认 0=关闭）：某方向持仓数 > 此值且该方向当前浮盈（含隔夜利息，`FloatingPnL`）< 0 → 平该方向所有单；买/卖各自独立判断，互不影响。
- 在越界检查之后、止盈/开单之前每 tick 评估；触发时画橙红色竖线 + 平仓标签，返回 `true` 跳过本 tick 止盈/开单。
- 0 关闭时函数第一行即返回，无性能损耗。

## 越界判断与处理
- **越界判断**(`IsOutOfRange`)：用当前 tick 的 **`bid/ask`** 实时判断。越界=`bid > 上界+门槛` 或 `ask < 下界-门槛`；恢复=`bid ≤ 上界-缓冲 且 ask ≥ 下界+缓冲`（滞回带防贴边抖动）。
- 门槛与恢复缓冲**共用同一距离**(`BreakoutDist`)，**单位恒为 ATR**：`BreakoutDist_AtrMult`×ATR(周期 `BreakoutDist_AtrPeriod`，读不到/倍数≤0 则距离 0)。距离=0 即碰线触发。缓冲经 `ClampBuffer` 限制 ≤ 区间宽 40%。
- **越界处理恒为全平止损**：超界 `CloseAll` 并暂停，bid/ask 回内侧自动恢复(画蓝色竖线)。无开关、无 `BREAKOUT_OFF` 兜底关闭选项——越界一律全平。
- **`HandleBreakout` 逐 tick 评估**（v1.06 起）：触碰边界立即触发，含影线穿刺；`BreakoutDist()` 内部做 ATR 按 bar 缓存（`static s_atrBar/s_atrLast`），避免逐 tick `CopyBuffer` 开销。`g_outOfRange` 期间逐 tick `CloseAll` 兜底。

## 可视化
- **画图总开关 `DrawLines_ShowGraphics`**(默认开)：off = 不画任何图形(边界/网格线/标签/越界恢复线/竖线/信息面板)，**不影响交易**；守卫在 `DrawLines`/`DrawVLine`/`DrawInfoPanel` 及 OnTick 刷新块开头。
- 买/卖独立(各自统计、各自止盈)，只认 `_Symbol + CTrade_Magic`；点差过滤 `OnTick_MaxSpread`(默认 0=关)。
- **水平线**(仅视觉/实盘图显示)：红实粗=上界 / 黄虚细=中线 / 绿实粗=下界 / 灰细=网格线；**黄实粗**=越界触发线(边界±门槛)；**黄虚细**=恢复界限(边界内侧±缓冲)。
- **垂直线**(`DrawVLine`)：**蓝**=越界全平止损时刻；**绿**=移动止损平仓且落袋 `≥TpThreshold_BasePips`（固定阈值，赚得多）；**黄**=移动止损平仓且落袋 `<TpThreshold_BasePips`（赚得少）；**橙红**=超单亏损保护(`LossCut_MinOrders`)触发。注意黄色被复用——水平黄=越界线/恢复线、垂直黄=移动止损未达标，按线型区分。
- **左上角面板**：`DrawInfoPanelTrail()` 在 OnInit 调用一次，画移动止损参数等静态行（运行中不变）；`DrawInfoPanel()` 每 tick 实时刷新动态浮盈信息（每 tick 调用，但面板内容未变时跳过重绘）（**不要改回按 bar 节流**——会让浮盈显示滞后一根 bar，与实际盈亏严重不符；回测要快就关 `DrawLines_ShowGraphics` 或关可视模式）。面板内容：① 移动止损 开/关+参数(开金/关银)；② 买、③ 卖各自总体盈利(总pips)+单数+(开移动止损时)**峰值始终显示**: 未武装 `峰值X→启动N 止损目标T (待启动)`、已武装 `峰值X 止损目标T (已启动)`(盈绿亏红，无单灰)。峰值 `g_trailPeakBuy/Sell` 仅在 `TrailTotal` 内每 tick 更新(故移动止损开时才有意义)。
- 下单 comment 标网格编号 "Grid Buy/Sell #k"(k=距中线第几格)；`TesterHideIndicators(true)` 隐藏视觉回测指标；`OnDeinit` 不删 `GT_` 对象。

## 开单冷却（最易踩坑，务必保持）
- `g_lastBuyLine`/`g_lastSellLine` 记上次开单的**网格线价格**(0=已武装)，**不要用格序号**——大幅跳格时序号一变就误解锁。
- **触碰窗 `tol=grid*0.25` 必须 < 解锁门槛 `release=grid*0.75`**，相等会在网格线附近抖动时反复重入、贴脸双开。详见记忆 `gridtrader-cooldown-design`。
- 另有 `HasOrderNear`(用半格 `grid*0.5`)做"该线附近已有同向单"二次去重。解锁判断用价格距离，不用格序号。

## 已删除（勿找 / 勿复活）
对冲锁仓、布林过滤、趋势(动量)过滤、边界顺势/趋势跟随策略(双策略开关)、自动定界、边界收缩、全局 SL 熔断、单笔止盈、固定手数(已拆为阶梯三参)、移动止损旧的绝对 pips/除数+broker SL 机制、方向篮子止损独立模块、越界距离 pips 单位(现恒用 ATR)、越界处理开关(现恒为全平止损)、固定 pips 网格间距(已换为按区间等分的 `TradeGrid_GridCount`)、每方向最大单数(上限改由网格线数天然封顶)、TP时间衰减(`InpTPDecayBars`，v1.05试验后移除)。

## 交易代码规范
- 下单/平仓用 `CTrade`，不手写旧 `OrderSend`；关键调用检查返回值并打印 `ResultRetcode()`+`GetLastError()`。
- 价格/手数按品种 digits、lot step 规范化(`NormalizeLots`)；pips→price 用 `g_pip`(3/5 位报价 1pip=10point)。
- 缩进 4 空格；不擅自改止损/止盈/风控等默认参数值。

## 编译（命令行，无需打开 MetaEditor）
```
& "C:\Program Files\Gaitame Finest MetaTrader 5 Terminal\MetaEditor64.exe" /compile:"<GridTrader.mq5 绝对路径>" /log
```
- 结果看同目录 `GridTrader.log`（**UTF-16**，PowerShell 用 `Get-Content -Encoding Unicode`），找 `Result: 0 errors`。
- **写文件前确认 MetaEditor 没打开着该文件**——打开时外部写入/编译会被还原(反复踩过)。

> 回测相关流程（回测 ini 参数名、回测验证/读日志核对）见 [docs/DEV_工作流.md](docs/DEV_工作流.md)。
> 策略回测结论与推荐参数见 [docs/策略探索总结.md](docs/策略探索总结.md)；可直接加载的最佳参数见 [presets/GridTrader_best.set](presets/GridTrader_best.set)。

## 风险红线（涉及资金，主动提醒用户）
- 单边突破时在边界**止损式全平**吃亏，是设计内最坏情况；越界处理现恒为全平止损(无关闭选项)。
- **阶梯手数边界重仓**：越界全平时边界处大手数单亏最多，放大突破风险；控制 `LotForLine_InitLots`。
- `TpThreshold_BasePips` 是**总体盈利 总pips**(全组累加 `Σ(单pips×手数)/LotForLine_MinLots`，非平均)，单数越多/手数越大越易达标，全是最小手时=各单 pips 简单相加；改手数/格数/品种时按此重设。
- 同向可累积多单(上限≈网格线数=格数/2)，格数越多单越密，注意保证金与爆仓。
- 止盈/移动止损阈值远大于网格间距时持仓扛得久、回撤大。
- 默认按对冲(Hedging)、模拟账户假设，除非明确说实盘。
