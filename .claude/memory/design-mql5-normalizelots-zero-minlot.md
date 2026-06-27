---
name: design-mql5-normalizelots-zero-minlot
description: "NormalizeLots(0) 返回最小手而非 0, 按算出手数开单前要判断原始值>0"
metadata: 
  node_type: memory
  type: reference
  originSessionId: f7d238bd-1d4e-4ddd-b715-e38b0ea37c83
---

MQL5 陷阱: GridTrader 的 NormalizeLots() 末尾有 `lots = MathMax(minLot, ...)`,
所以 **NormalizeLots(0.0) 返回的不是 0, 而是品种最小手(如0.01)**。

曾导致真实 bug(注: 对冲锁仓功能现已从代码移除, 以下为当时的真实案例, 教训仍适用): 合并对冲锁仓时, 某方向无持仓(总手=0)却凭空开了一笔最小对冲单
(日志"原卖0.00手->锁买0.01"), 相当于反向裸露+多付点差。

**How to apply**: 任何"按计算手数开单"的地方(对冲/加仓/马丁), 判断是否开单要用**原始手数 vol>0**,
不能判断 NormalizeLots(vol) 的结果(它永远 >= minLot, 恒为真)。
相关: [[apply-gridtrader-breakout-check-backtest]]
