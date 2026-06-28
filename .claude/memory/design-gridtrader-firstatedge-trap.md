---
name: design-gridtrader-firstatedge-trap
description: FirstAtEdge=true 时若网格区间设得比实际价幅还宽, 边界永远碰不到 -> 一单不开(回测全0)
metadata: 
  node_type: memory
  type: project
  originSessionId: dc2518a7-ab9b-4725-8cce-a27146ab06b2
---

GridTrader 的 `TradeGrid_FirstAtEdge=true`(默认)要求某方向空仓时第一单必须先触碰**裸边界**(空碰上界 / 多碰下界)才开。

**坑**: 若把 `TradeGrid_UpperPrice/LowerPrice` 设得比该时段价格**实际走到的高/低还宽**, 边界就永远碰不到 → 一单都不开, 回测净利=0、笔数=0(本会话踩过两次, 还误以为脚本坏了)。

**How to apply**:
- 用 FAE=true 时, 区间必须贴近该时段**实际价幅**(边界要够得着)。
- 若有意把区间设得宽于价幅(如按分析/回看带定区间, 留缓冲), 必须改 `FAE=false`, 否则完全不交易。
- 探测某段实际价幅: 用一个很宽的区间 + `FAE=false` 跑一遍, 取成交价 `deal ... at X` 的 min/max 即该段价幅。

相关: [[apply-gridtrader-strategy-regime]]
