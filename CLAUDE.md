# GridTrader —— MT5 区间双向网格 EA

MT5 区间双向网格 EA（单一策略）：上半做空 / 下半做多、逆势回归；止盈用「方向总体 · 手数加权平均 pips」，可选移动止损（峰值百分比回撤），下单用阶梯手数。开发 / 修改本项目时遵守以下约定。**改动前先读代码、勿做反。**

## 项目定位
- 单文件 EA：`GridTrader.mq5`（MQL5，对冲账户 Hedging 模式）。
- 仓库：https://github.com/zhangwenwei/mt5-grid-trader （只传源码 mq5；ex5/log/.claude 已被 .gitignore 排除）。
- 编译产物 `GridTrader.ex5`、日志 `GridTrader.log` 不进版本控制。

## 策略逻辑（单一策略，`TradeGrid`）
- **上半区做空**：从 `中线+1格` 起每隔一格一条网格线，铺到上界；价格触碰某线即开空。
- **下半区做多**：从 `中线-1格` 起每隔一格一条网格线，铺到下界；价格触碰某线即开多。
- **中线不开单**（循环从 k=1 起）。做空线都在中线上方、做多线都在中线下方——**中线是起点(内边界)，不是终点**；铺线终点是上/下界（`line > 上界+tol` / `< 下界-tol` 时停）。**没有"加到中线为止"那种逻辑**（那是已删的边界顺势策略的概念）。
- **开单同时满足**：方向开关(`InpEnableSell/Buy`)、当前 bid/ask 在区间内、该方向冷却已武装(`g_lastSellLine/BuyLine==0`)、持仓数 < `InpMaxOrdersPerSide`、价格进入网格线 `±tol`、`HasOrderNear` 该线半格内无同向单。
- **上下边界**：`InpUpperPrice`/`InpLowerPrice` **人工必填**(>0 且 上>下)，`g_center=(上+下)/2` 自动算；无自动定界，非法则 OnInit 拒绝启动。
- **网格间距 `InpGridSizePips`**：固定 pips（`grid=InpGridSizePips*g_pip`），与区间宽度无关。

## 阶梯手数（`LotForLine`）
- **靠边界大、向中线递减**：`lots = InpInitLots − distEdge×InpReduceLots`，封底 `InpMinLots`。
  - `distEdge` = 该网格线距所属边界的格数（最靠边界=0 → `InpInitLots` 最大）。
  - `InpReduceLots=0` 即所有格固定 `InpInitLots`。
- `NormalizeLots` 按 lot step 向下取整并夹到 [min,max]；注意它会把 0 抬到最小手，故开单前 `LotForLine` 已保证 ≥ `InpMinLots`。

## 止盈与移动止损（唯一主动出场，二者互斥）
- **计量 = 手数加权平均浮盈**(pips/手)：`WeightedPipsByType` = `Σ(单pips×手数)/Σ手数`；多单 `(bid-open)/g_pip`、空单 `(open-ask)/g_pip`。**纯价差不含手续费**；同手数时=各单 pips 简单平均。**不是合计、不是货币。已无单笔止盈，开单不挂 TP（SL/TP 全传 0）。**
- **方向总体止盈**(移动止损关时)：买/卖各自，加权平均浮盈达 `InpTPPips` → `CloseSide` 平该方向全部。
- **移动止损 `InpTrailEnable`**(ON 替代总体止盈，`TrailTotal`)：加权平均浮盈峰值达 `InpTPPips` 启动记峰值(`g_trailPeakBuy/Sell`)，当前值回撤到 `峰值×(1−InpTrailRetracePct/100)` → 平该方向整组；**纯内部跟踪、不挂 broker SL**。`InpTrailRetracePct` 须在 (0,100)。
- `InpTPPips` 一参兼任：关移动止损=平仓阈值；开=移动止损启动阈值。

## 越界判断与处理
- **越界判断**(`IsOutOfRange`)：用上一根**已收盘** K 线 `iClose(_Symbol,_Period,1)`。越界=收盘超出 `边界±门槛`；恢复=收盘回到 `边界内侧 缓冲` 以内（滞回带防贴边抖动）。
- 门槛与恢复缓冲**共用同一距离**(`BreakoutDist`)，单位由 `InpBreakoutUnit` 定：`BU_PIPS`→`InpBreakoutPips`×g_pip；`BU_ATR`→`InpBreakoutAtr`×ATR(周期 `InpBreakoutAtrPeriod`，读不到则距离 0)。距离=0 即碰线触发。缓冲经 `ClampBuffer` 限制 ≤ 区间宽 40%。
- **越界处理 `InpBreakoutMode`**：`BREAKOUT_OFF`(不处理，无兜底) / `BREAKOUT_CLOSE_ALL`(超界 `CloseAll` 并暂停，收盘回内侧自动恢复)。

## 可视化
- 买/卖独立(各自统计、各自止盈)，只认 `_Symbol + InpMagic`；点差过滤 `InpMaxSpreadPoints`(默认 0=关)。
- **水平线**(仅视觉/实盘图显示)：红上界 / 金中线 / 绿下界 / 灰网格线；**黄粗线**=越界触发线(边界±门槛)；**绿粗线**=恢复界限(边界内侧±缓冲)。
- **垂直线**(`DrawVLine`)：**蓝**=越界全平止损时刻；**绿**=移动止损平仓且落袋 `≥InpTPPips`(赚得多)；**黄**=移动止损平仓且落袋 `<InpTPPips`(赚得少)。注意黄色被复用——水平黄=越界线、垂直黄=移动止损未达标，按线型区分。
- **左上角面板**(`DrawInfoPanel`，每 tick 刷新)：① 移动止损 开/关+参数(开金/关银)；② 买、③ 卖各自加权平均浮盈(pips/手)+单数+止损目标(盈绿亏红，无单灰)。
- 下单 comment 标网格编号 "Grid Buy/Sell #k"(k=距中线第几格)；`TesterHideIndicators(true)` 隐藏视觉回测指标；`OnDeinit` 不删 `GT_` 对象。

## 开单冷却（最易踩坑，务必保持）
- `g_lastBuyLine`/`g_lastSellLine` 记上次开单的**网格线价格**(0=已武装)，**不要用格序号**——大幅跳格时序号一变就误解锁。
- **触碰窗 `tol=grid*0.25` 必须 < 解锁门槛 `release=grid*0.75`**，相等会在网格线附近抖动时反复重入、贴脸双开。详见记忆 `gridtrader-cooldown-design`。
- 另有 `HasOrderNear`(用半格 `grid*0.5`)做"该线附近已有同向单"二次去重。解锁判断用价格距离，不用格序号。

## 已删除（勿找 / 勿复活）
对冲锁仓、布林过滤、趋势(动量)过滤、边界顺势/趋势跟随策略(双策略开关 `InpStrategy`)、自动定界、边界收缩、全局 SL 熔断、单笔止盈(`InpTakeProfitPips`)、固定手数 `InpLots`(已拆为阶梯三参)、移动止损旧的绝对 pips/除数+broker SL 机制(`InpTrailStartPips`/`InpTrailDivisor`)。

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

## 回测验证
- 无法远程触发 MT5 测试器 GUI；验证靠**读回测日志逐笔核对**。
- 日志：`C:\Users\ZWW\AppData\Roaming\MetaQuotes\Tester\<TerminalID>\Agent-127.0.0.1-30xx\logs\<date>.log`（UTF-16，取修改时间最新的 Agent）。
- 命令行编译后 MT5 端**必须重新加载 EA / 重开测试器**才生效，否则看的是缓存旧参数(反复踩过)。
- 回测无数据/秒结束：先查日志 `history data begins from ...`，常见是回测区间早于品种可用历史。

## 风险红线（涉及资金，主动提醒用户）
- 单边突破时在边界**止损式全平**吃亏（`CLOSE_ALL`），是设计内最坏情况；`BREAKOUT_OFF` 完全无兜底。
- **阶梯手数边界重仓**：越界全平时边界处大手数单亏最多，放大突破风险；控制 `InpInitLots`、勿关越界全平。
- `InpTPPips` 是**加权平均每手 pips**(非合计)，同手数下=各单简单平均；改手数/品种时按此重设。
- 同向可累积多单(`InpMaxOrdersPerSide` 主刹车)，注意保证金与爆仓。
- 止盈/移动止损阈值远大于网格间距时持仓扛得久、回撤大。
- 默认按对冲(Hedging)、模拟账户假设，除非明确说实盘。
