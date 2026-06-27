---
name: design-gridtrader-cooldown
description: "GridTrader 区间网格 EA 的开单冷却阈值设计 —— 触碰窗必须小于解锁门槛, 防止价格在网格线附近抖动时重复开单"
metadata: 
  node_type: memory
  type: project
  originSessionId: 09f05b1e-5331-44e8-95b6-479a470dcc5b
---

GridTrader.mq5(区间双向网格 EA, 上半做空/下半做多/超界全平)的开单冷却必须用**两个不同的阈值**, 不能共用半格:

- 触碰窗 `tol = grid * 0.25`: 价格进入网格线 ±1/4 格才算"触碰", 才开单
- 解锁门槛 `release = grid * 0.75`: 开单后价格要离开该线 3/4 格, 才重新允许在该线开单

**Why:** 早期版本触碰窗和解锁门槛都用 `grid*0.5`(半格), 两者边界重叠。价格在某条网格线附近小幅抖动(如 +13pip ↔ +15pip)时, 会反复触发"解锁→再开", 导致 1 秒内同一条线贴脸双开(回测日志铁证: 2026.04.30 13:33:05 buy@158.028 / 13:33:06 buy@158.052, 差 2.4pip)。把解锁门槛拉大到 > 触碰窗, 中间留缓冲带, 抖动就不会重入。

**How to apply:** 改这个 EA 的开单密度/重复单问题时, 先确认 `tol < release`; 若快速行情偶尔漏开, 调大 `tol`(如 0.35)找平衡, 但始终保持 `tol < release`。重复下单问题与点差无关(用户的版本 OnTick_MaxSpread=0 已关点差过滤)。

冷却用全局变量 `g_lastBuyLine` / `g_lastSellLine` 记录上次开单的网格线价格(0=已武装), 不要用 MathRound 的格序号 —— 大幅跳格时序号一变就误解锁。

验证方式: 无法远程触发 MT5 测试器 GUI, 只能读回测日志逐笔核对。日志在 `...\Tester\<ID>\Agent-127.0.0.1-30xx\logs\<date>.log`, UTF-16 编码(PowerShell 用 `Get-Content -Encoding Unicode`)。命令行编译: `& "C:\Program Files\Gaitame Finest MetaTrader 5 Terminal\MetaEditor64.exe" /compile:"<mq5路径>" /log`。
