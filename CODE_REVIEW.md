# GridTrader 代码审阅（v1.05）

> 审阅对象：`GridTrader.mq5`（单文件 EA，约 1000 行）
> 审阅方式：静态通读（Linux 环境无 MetaEditor，未编译/未回测）
> 结论：整体质量在个人量化 EA 中偏上——命名清晰、注释到位、关键调用查返回值、
> OnInit 全参数校验、冷却用价格而非序号、滞回带防抖、bar 级节流都做对了。
> 下面按严重程度列出可改进项，回家在电脑上逐条处理。

---

## 🔴 值得改的（安全 / 正确性相关）

### 1. 点差过滤会让所有风控失明 —— 最该改

**位置**：`OnTick()` 第 474–479 行

```mql5
if(OnTick_MaxSpread > 0)
  {
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > OnTick_MaxSpread)
      return;          // ← 这里直接 return, 在所有风控之前
  }
```

这个 `return` 位置在 `HandleBreakout()`(506)、`CheckLossCut()`(510)、
方向总体止盈、移动止损 **全部之前**。

**后果**：点差变大的时刻（新闻、隔夜换日、流动性枯竭）恰恰是最该跑路的时刻，
但 EA 此时**不越界全平、不超单止损、不移动止损**，直接放任裸仓。
点差过滤的本意只是「别在烂点差里开新单」，不该顺手把出场也一起关了。

**建议改法**：点差闸只挡 `TradeGrid()`（开单），把风控 / 出场逻辑放到点差闸之前。
例如把开单那一步单独包一层点差判断，OnTick 顶部不再因点差提前 return。

---

### 2. 持仓全程没有 broker 端 SL —— 操作性风险

**位置**：`OpenOrder()` 第 858–860 行，下单 SL/TP 全传 0。

所有出场（越界全平、移动止损、方向总体止盈）都是 **EA 内部逐 tick 判断**。
一旦 EA 掉线、终端关闭、VPS 断电，仓位完全裸奔，无任何保护。

这是网格 EA 的通病，CLAUDE.md 也明确写了「纯内部跟踪不挂 broker SL」是有意为之。
但既然涉及资金，必须提醒：**这套策略强依赖 EA 持续在线**。

**可选改法（需你拍板，涉及策略语义）**：挂一个远离价格的灾难性 broker SL 兜底，
正常情况永远不会触发，只用于防断线。不加也行，但要清楚这个风险敞口。

---

## 🟡 小瑕疵（逻辑细节，影响小）

### 3. 奇数格时「最靠边界手数最大」会偏一格

**位置**：`LotForLine()` 第 838–840 行

```mql5
int distEdge = (type == POSITION_TYPE_SELL)
               ? (int)MathRound((g_upper - line) / grid)
               : (int)MathRound((line - g_lower) / grid);
```

奇数格时最外侧线距边界 0.5 格，`MathRound(0.5)=1`，于是边界最外侧那条线
拿到的是 `InitLots − 1×ReducePerLine`，而不是满额 `InitLots`，与
「最靠边界 = 最大」的意图差一格。偶数格无此问题（中线落线、边界落线）。
`ReducePerLine=0`（默认）时无影响。

**建议**：若要严格，可改用 `MathFloor` 或对 distEdge 做 round-down 处理。

---

### 4. `BreakoutDist()` 每次评估读两遍 ATR

**位置**：`HandleBreakout()` 第 667–668 行

`ClampBuffer(BreakoutDist())` 与 `IsOutOfRange()` 内部各调一次 `BreakoutDist()`，
一次评估两次 `CopyBuffer`。因为已是 bar 级节流，开销可忽略，
但可以缓存成一个局部变量传进去更干净。

---

### 5. `LotForLine_MinLots` 与 broker 最小手可能不一致

**位置**：`TotalPipsByType()` 第 793 行 vs `NormalizeLots()` 第 994 行

`TotalPipsByType` 用参数 `LotForLine_MinLots` 做归一分母，但实际下单会被
`NormalizeLots` 夹到 broker 的 `SYMBOL_VOLUME_MIN`。若两者不等，
止盈「总 pips」口径与真实手数会有系统性偏差。

**建议**：OnInit 校验 `LotForLine_MinLots >= 品种最小手`，
或直接用品种最小手做归一分母。

---

## 🟢 写得好的地方（别动）

- **冷却用网格线价格而非序号**（91–96、714–715）+ `tol < release` 不变量（709–711）
  —— 网格最易踩的坑，处理正确。
- **越界判断用上一根收盘** `iClose(1)`（642）防插针 + bar 级节流（658–660）
  + 滞回带（667–669）。
- **加权总 pips 口径**（777–794）一致地贯穿止盈 / 移动止损 / 面板。
- **参数 OnInit 全校验**（128–162），非法即拒绝启动。

---

## 修改优先级建议

| 优先级 | 条目 | 改动大小 | 是否需拍板 |
|--------|------|----------|------------|
| 1 | 点差过滤失明（#1） | 小 | 否，纯安全改进 |
| 2 | 断线兜底 SL（#2） | 中 | 是，涉及策略语义 |
| 3 | MinLots 一致性校验（#5） | 小 | 否 |
| 4 | 奇数格手数偏移（#3） | 小 | 否（默认参数下无影响） |
| 5 | ATR 重复读取（#4） | 小 | 否（纯整洁度） |
