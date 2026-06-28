---
name: apply-gridtrader-strategy-regime
description: GridTrader 大规模回测寻优+样本外结论——LossCut最值钱、静态宽区间>滚动、双向>单向、样本内收益不外推、风控泛化但收益看行情
metadata: 
  node_type: memory
  type: project
  originSessionId: dc2518a7-ab9b-4725-8cce-a27146ab06b2
---

2026-06 对 GridTrader 做了约 100+ 次真实Tick回测(EURUSD 为主 + EUR 交叉盘)的策略寻优与 walk-forward, 核心结论:

- **LossCut 超单亏损保护(默认 0=关)是单项最有价值的开关**: 开到 ~8, 2024 EURUSD 净利 18044→26180、回撤 27.7%→21.8%; 再配阶梯手数 0.02↓0.01 达 31110 / PF1.30。它在趋势月砍掉失血方向。
- **静态宽区间 > 滚动重设区间**: 月度滚动、季度滚动都输给"罩住全程的宽静态区间"; 重设成更窄的近期带后, 价格一漂出就频繁越界止损。滚动救不了趋势。
- **双向 > 单方向**: 只多/只空 = 赌宏观方向(涨段只多赢、跌段只空赢), 但净利都打不过双向(双向同吃漂移 + 两侧震荡)。
- **样本内收益不外推**: IS=2024H1 大赚(EURUSD +57k / EURGBP +30k) → OOS=H2 全转亏(−3k / −8k), 因价格漂出 IS 区间。固定区间一遇漂移就失效。
- **风控泛化、收益不泛化**: 所有配置/品种 OOS 都零爆仓、回撤压在 ~13–15%(LossCut + 越界全平有效); 但盈利高度依赖"价格留在区间"。配置可跨 EUR 交叉盘泛化(USD/GBP/CHF/CAD 2024 单期都正), 仅限区间盘。
- 趋势暂停 / 趋势过滤无效(与 [[apply-gridtrader-adx-filter-backtest]] 一致); 分支 strat/trend-pause 是负面存档。

**How to apply**: 推荐配置 = 双向 + LossCut(~8) + 阶梯手数(0.02↓0.01) + 格28 + TP30-45 + 宽静态区间, 只在区间盘投放。已存 presets/GridTrader_best.set(用前必把 Upper/Lower 改成当前近3月实际高/低)。**别信样本内数字**, 实盘按"风控可信、收益看行情"预期, 区间要勤对齐。
**Why**: 网格成败主要看"行情匹配(区间 vs 趋势)+ 区间放对", 调参/加指标/滚动/赌方向都是二阶, 改不了本质。
注: 多数大额 JPY 数字用了 FAE=false + 宽区间, 偏乐观, 只作相对比较; FAE=true 窄区间更接近真实量级。相关 [[design-gridtrader-firstatedge-trap]]、[[design-gridtrader-cooldown]]。
