# GridTrader —— MT5 区间双向网格 EA

USDJPY 上验证过的区间网格 EA。开发 / 修改本项目时遵守以下约定。

## 项目定位
- 单文件 EA：`GridTrader.mq5`（MQL5，对冲账户 Hedging 模式）。
- 仓库：https://github.com/zhangwenwei/mt5-grid-trader （只传源码 mq5；ex5/log/.claude 已被 .gitignore 排除）。
- 编译产物 `GridTrader.ex5`、编译日志 `GridTrader.log` 不进版本控制。

## 策略逻辑（改动前先理解，勿做反）
- **上下边界**：`InpUpperPrice` / `InpLowerPrice` 填 0 = 自动计算、填值 = 手动覆盖；中线 = (上界+下界)/2 自动算。
- **自动定界 `InpBoundsMode`**：唐奇安 high/low（含影线）/ 唐奇安 close（去插针）/ 中线±k×ATR 三选一；`InpAutoLookback` 回看根数，ATR 模式另有 `InpATRPeriod`/`InpATRMult`。
- **边界收缩 `InpBoundsShrinkPct`**：算出区间后向内收 X%（0~40），避免贴极值开单、缓解超界全平。
- **超界行为 `InpBreakoutMode`**：全平并暂停（原行为）/ 只暂停不平（让区间内单自行止盈）。
- **全局熔断**：`InpGlobalTP` 总浮盈触线全平；`InpGlobalSL` 总浮亏触线全平并永久停机（`g_halted`）。单位是账户货币，0=关闭。
- **上半区（中线~上界）做空，下半区（下界~中线）做多**；中线本身不开单（从中线 ±一格起）。
- 每单往**中线方向**走一个网格（`InpTakeProfitPips`）即单笔止盈。
- **超界全平**：用上一根已收盘 K 线 `iClose(_Symbol,_Period,1)`，close > 上界 或 < 下界 → `CloseAll()` 并暂停；close 回到区间内自动恢复。
- 买/卖独立开关、点差过滤（`InpMaxSpreadPoints`，默认 0 = 关闭）。
- 所有持仓统计只认 `_Symbol + InpMagic`，买卖两组互不干扰。

## 开单冷却（最易踩坑，务必保持）
- 用全局 `g_lastBuyLine` / `g_lastSellLine` 记录上次开单的**网格线价格**（0=已武装），**不要用 MathRound 的格序号**——大幅跳格时序号一变就误解锁，导致重复开单。
- **触碰窗 `tol = grid*0.25` 必须小于 解锁门槛 `release = grid*0.75`**。两者若相等（早期都用半格）会在网格线附近抖动时反复重入、贴脸双开。详见记忆 `gridtrader-cooldown-design`。
- 重复下单问题与点差无关（用户的点差过滤已关）。改开单密度时先确认 `tol < release`。

## 交易代码规范（沿用全局偏好）
- 下单/平仓用 `CTrade`，不手写旧 `OrderSend`。
- 关键交易调用必须检查返回值并打印 `ResultRetcode()` + `GetLastError()`。
- 价格/手数按品种 digits、lot step 规范化（见 `NormalizeLots`）；pips→price 用 `g_pip`（3/5 位报价 1pip=10point）。
- 缩进 4 空格；不擅自改止损/止盈/风控等默认参数值。

## 编译（命令行，无需打开 MetaEditor）
```
& "C:\Program Files\Gaitame Finest MetaTrader 5 Terminal\MetaEditor64.exe" /compile:"<GridTrader.mq5 绝对路径>" /log
```
- 编译结果看同目录 `GridTrader.log`（**UTF-16 编码**，PowerShell 用 `Get-Content -Encoding Unicode`），找 `Result: 0 errors`。
- **写文件前确认 MetaEditor 没打开着该文件**——打开时文件被锁，外部写入会被还原（本项目反复踩过这个坑）。

## 回测验证
- 无法远程触发 MT5 测试器 GUI；验证靠**读回测日志逐笔核对**。
- 日志路径：`C:\Users\ZWW\AppData\Roaming\MetaQuotes\Tester\<TerminalID>\Agent-127.0.0.1-30xx\logs\<date>.log`（UTF-16）。
- 比对新旧行为时注意按**日志文件修改时间 vs ex5 编译时间**判断哪段是新版跑的。
- 回测无数据/秒结束时，先查日志 `history data begins from ...`：常见是回测区间早于该品种可用历史起点。

## 风险红线（涉及资金，主动提醒用户）
- 区间网格在单边突破时会在边界**止损式全平**吃亏，这是设计内的最坏情况。
- 区间内同向可累积多单（`InpMaxOrdersPerSide` 是主要刹车），注意保证金占用与爆仓风险。
- `TakeProfit ≫ GridSize` 时持仓扛得久、回撤大；改这类参数组合要提示浮亏承受力。
- 默认假设跑模拟账户，除非用户明确说实盘。
