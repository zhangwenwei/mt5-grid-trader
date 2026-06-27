---
name: apply-gridtrader-adx-filter-backtest
description: ADX过滤回测结论：对网格策略无效，EURCAD关掉后净利翻倍，已从代码中移除
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 20db9aee-4811-43c9-a282-dbbaa4066c9c
---

**结论：ADX过滤对GridTrader网格策略整体有害，不要加回来。**

**Why:** 2026-06-21 对 EURUSD/EURGBP/EURCHF/EURCAD 做了 ADX开 vs ADX关 的3年回测对比：
- EURCAD：ADX关净利 +12719 vs ADX开 +6828（翻倍），笔数 58 vs 32，回撤几乎不变（2.1% vs 2.0%）
- EURUSD：ADX开盈利因子更高（7.96 vs 4.25），但净利反而更少（6195 vs 7525）
- 总体规律：ADX过滤减少了笔数，但把有效的震荡单也一起挡掉了，收益明显下降

**How to apply:** 
- 不要为这套区间网格策略加 ADX、RSI 等趋势/震荡过滤指标
- 真正的风控已经是「越界全平」机制，额外的开仓过滤只会减少收益
- 如果价格进入趋势，越界保护会止损全平；不需要提前用指标阻止开仓
- ADX已从代码中彻底删除（当前 #property version 1.06，已无 iADX/ADXFilter 输入），勿复活

[[apply-gridtrader-breakout-check-backtest]]
