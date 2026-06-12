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
- **开单同时满足**：方向开关(`InpEnableSell/Buy`)、当前 bid/ask 在区间内、该方向冷却已武装(`g_lastSellLine/BuyLine==0`)、价格进入网格线 `±tol`、`HasOrderNear` 该线半格内无同向单。**同向持仓上限由网格线数(≈格数/2)天然封顶, 无单独"最大单数"参数(`InpMaxOrdersPerSide` 已删)。**
- **上下边界**：`InpUpperPrice`/`InpLowerPrice` **人工必填**(>0 且 上>下)，`g_center=(上+下)/2` 自动算；无自动定界，非法则 OnInit 拒绝启动。
- **网格数量 `InpGridCount`**(整数, 须≥2)：把区间等分成这么多格, 格距 `g_grid=(上界−下界)/InpGridCount` 在 OnInit 自动算并存全局(随区间宽变, 不再用 pips)。例 110−111 设 10 → 每格 0.1。**已删 `InpGridSizePips`(固定 pips 间距)**。偶数格时中线恰落在一条网格线上被跳过、开单线数=格数, 最外侧线正好在上/下边界; 奇数格时中线不在线上、最外侧线距边界半格(武装判据按「最外侧网格线」处理, 不锁死第一单)。
- **第一单须触碰边界 `InpFirstOrderAtEdge`**(默认开)：某方向空仓时第一单必须等价格先碰**最外侧网格线**(空碰最高空线 `bid≥topSellLine−tol` / 多碰最低多线 `ask≤botBuyLine+tol`)才开，避免区间中部就开单；加仓不受限；空仓且价格离开该线超 `release` 则撤防(`g_sellArmed`/`g_buyArmed`)。**武装判据用最外侧网格线(实际开单位置)而非裸边界 `g_upper/g_lower`**——区间宽非网格整数倍时最外侧线距边界可达近一格，用裸边界会碰不到而锁死/漏开第一单(对齐缺陷修复)。`topSellLine=g_center+⌊(上−中+tol)/grid⌋×grid`、`botBuyLine` 同理向下取。

## 阶梯手数（`LotForLine`）
- **靠边界大、向中线递减**：`lots = InpInitLots − distEdge×InpReduceLots`，封底 `InpMinLots`。
  - `distEdge` = 该网格线距所属边界的格数（最靠边界=0 → `InpInitLots` 最大）。
  - `InpReduceLots=0` 即所有格固定 `InpInitLots`。
- `NormalizeLots` 按 lot step 向下取整并夹到 [min,max]；注意它会把 0 抬到最小手，故开单前 `LotForLine` 已保证 ≥ `InpMinLots`。

## 止盈与移动止损（唯一主动出场，二者互斥）
- **计量 = 总体盈利 总pips**(手数加权累加, 非平均)：`TotalPipsByType` = `Σ(单pips×手数)/InpMinLots`；多单 `(bid-open)/g_pip`、空单 `(open-ask)/g_pip`。**全组累加再归一到最小手**(故单数越多/手数越大越易达标; 全是最小手时=各单 pips 简单相加)，**纯价差不含手续费、不是平均、不是货币**。已无单笔止盈，开单不挂 TP（SL/TP 全传 0）。(旧版是 `Σ(单pips×手数)/Σ手数` 每手加权平均 `WeightedPipsByType`, 已改为累加。)
- **动态阈值 `TpThreshold(n)`**：生效阈值随该方向持仓单数线性抬高 = `InpTPPips + (单数-1)×InpTPAddPerOrder`(n<1 视为1)。`InpTPAddPerOrder=0`(默认)即恒为基准 `InpTPPips`、不随单数变；例基准70+每单10 → 1单70/2单80/3单90。**移动止损启动、方向总体止盈、面板三处统一用它**(都按各自方向的当前单数算)。须 `InpTPAddPerOrder>=0`。
- **方向总体止盈**(移动止损关时)：买/卖各自，总体盈利(总pips)达 `TpThreshold(该向单数)` → `CloseSide` 平该方向全部。
- **移动止损 `InpTrailEnable`**(ON 替代总体止盈，`TrailTotal`)：总体盈利(总pips)峰值达 `TpThreshold(该向单数)` 启动记峰值(`g_trailPeakBuy/Sell`)，当前值**回撤到 `峰值×(InpTrailKeepPct/100)`** → 平该方向整组；**纯内部跟踪、不挂 broker SL**。`InpTrailKeepPct` 须在 (0,100)。**语义=「回撤到峰值的百分之多少就平」(保留比例), 不是「回撤了多少%」**——值越大跟踪越紧(回吐越少), 例 80=跌到峰值80%即平(回吐20%)。(旧名 `InpTrailRetracePct`=回撤了X%, 已反转重命名。)注: 加仓使单数+1→阈值抬高, 可能令已武装组暂时回到"待启动"(峰值<新阈值), 待总盈利涨到新阈值再武装。
- `InpTPPips` 一参兼任(基准)：关移动止损=平仓阈值基准；开=移动止损启动阈值基准；实际阈值经 `TpThreshold` 按单数抬高。

## 越界判断与处理
- **越界判断**(`IsOutOfRange`)：用上一根**已收盘** K 线 `iClose(_Symbol,_Period,1)`。越界=收盘超出 `边界±门槛`；恢复=收盘回到 `边界内侧 缓冲` 以内（滞回带防贴边抖动）。
- 门槛与恢复缓冲**共用同一距离**(`BreakoutDist`)，**单位恒为 ATR**：`InpBreakoutAtr`×ATR(周期 `InpBreakoutAtrPeriod`，读不到/倍数≤0 则距离 0)。距离=0 即碰线触发。缓冲经 `ClampBuffer` 限制 ≤ 区间宽 40%。
- **越界处理恒为全平止损**：超界 `CloseAll` 并暂停，收盘回内侧自动恢复(画蓝色竖线)。无开关、无 `BREAKOUT_OFF` 兜底关闭选项——越界一律全平。
- **`HandleBreakout` 每根新 bar 才评估一次**(判据只依赖已收盘 K 线+ATR(1), bar 内不变)：避免逐 tick `CopyBuffer(ATR)` 拖慢回测。**勿改回逐 tick**——越界状态只可能在 bar 收盘时翻转, 逐 tick 评估纯属浪费。`g_outOfRange` 期间仍逐 tick `CloseAll` 兜底(已平时空循环)。

## 可视化
- **画图总开关 `InpShowGraphics`**(默认开)：off = 不画任何图形(边界/网格线/标签/越界恢复线/竖线/信息面板)，**不影响交易**；守卫在 `DrawLines`/`DrawVLine`/`DrawInfoPanel` 及 OnTick 刷新块开头。
- 买/卖独立(各自统计、各自止盈)，只认 `_Symbol + InpMagic`；点差过滤 `InpMaxSpreadPoints`(默认 0=关)。
- **水平线**(仅视觉/实盘图显示)：红上界 / 金中线 / 绿下界 / 灰网格线；**黄粗线**=越界触发线(边界±门槛)；**绿粗线**=恢复界限(边界内侧±缓冲)。
- **垂直线**(`DrawVLine`)：**蓝**=越界全平止损时刻；**绿**=移动止损平仓且落袋 `≥InpTPPips`(赚得多)；**黄**=移动止损平仓且落袋 `<InpTPPips`(赚得少)。注意黄色被复用——水平黄=越界线、垂直黄=移动止损未达标，按线型区分。
- **左上角面板**(`DrawInfoPanel`，**每 tick 实时刷新**——曾试过节流到每 bar, 但会让浮盈显示滞后一根 bar、与实际盈亏严重不符而误判, 已改回逐 tick; 回测要快就关 `InpShowGraphics` 或关可视模式, 别靠节流面板)：① 移动止损 开/关+参数(开金/关银)；② 买、③ 卖各自加权平均浮盈(pips/手)+单数+(开移动止损时)**峰值始终显示**: 未武装 `峰值X→启动N 止损目标T (待启动)`、已武装 `峰值X 止损目标T (已启动)`(盈绿亏红，无单灰)。峰值 `g_trailPeakBuy/Sell` 仅在 `TrailTotal` 内每 tick 更新(故移动止损开时才有意义)。
- 下单 comment 标网格编号 "Grid Buy/Sell #k"(k=距中线第几格)；`TesterHideIndicators(true)` 隐藏视觉回测指标；`OnDeinit` 不删 `GT_` 对象。

## 开单冷却（最易踩坑，务必保持）
- `g_lastBuyLine`/`g_lastSellLine` 记上次开单的**网格线价格**(0=已武装)，**不要用格序号**——大幅跳格时序号一变就误解锁。
- **触碰窗 `tol=grid*0.25` 必须 < 解锁门槛 `release=grid*0.75`**，相等会在网格线附近抖动时反复重入、贴脸双开。详见记忆 `gridtrader-cooldown-design`。
- 另有 `HasOrderNear`(用半格 `grid*0.5`)做"该线附近已有同向单"二次去重。解锁判断用价格距离，不用格序号。

## 已删除（勿找 / 勿复活）
对冲锁仓、布林过滤、趋势(动量)过滤、边界顺势/趋势跟随策略(双策略开关 `InpStrategy`)、自动定界、边界收缩、全局 SL 熔断、单笔止盈(`InpTakeProfitPips`)、固定手数 `InpLots`(已拆为阶梯三参)、移动止损旧的绝对 pips/除数+broker SL 机制(`InpTrailStartPips`/`InpTrailDivisor`)、方向篮子止损独立模块(`SideBasketStop`/`InpSideStopEnable`/`InpSideStopPips`)、越界距离 pips 单位(`BU_PIPS`/`InpBreakoutPips`/`ENUM_BREAKOUT_UNIT`/`InpBreakoutUnit`，现恒用 ATR)、越界处理开关(`InpBreakoutMode`/`BREAKOUT_OFF`/`ENUM_BREAKOUT_MODE`，现恒为全平止损)、固定 pips 网格间距(`InpGridSizePips`，已换为按区间等分的 `InpGridCount`)、每方向最大单数(`InpMaxOrdersPerSide`，上限改由网格线数天然封顶)。

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
- 单边突破时在边界**止损式全平**吃亏，是设计内最坏情况；越界处理现恒为全平止损(无关闭选项)。
- **阶梯手数边界重仓**：越界全平时边界处大手数单亏最多，放大突破风险；控制 `InpInitLots`。
- `InpTPPips` 是**总体盈利 总pips**(全组累加 `Σ(单pips×手数)/InpMinLots`，非平均)，单数越多/手数越大越易达标，全是最小手时=各单 pips 简单相加；改手数/格数/品种时按此重设(口径变了, 阈值需重调大)。
- 同向可累积多单(上限≈网格线数=格数/2)，格数越多单越密，注意保证金与爆仓。
- 止盈/移动止损阈值远大于网格间距时持仓扛得久、回撤大。
- 默认按对冲(Hedging)、模拟账户假设，除非明确说实盘。
