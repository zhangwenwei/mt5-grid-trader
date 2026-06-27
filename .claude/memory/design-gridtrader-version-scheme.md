---
name: design-gridtrader-version-scheme
description: GridTrader 版本号递增约定 — 从 v1.00 起每版 +0.01
metadata: 
  node_type: memory
  type: project
  originSessionId: acaae4cb-91bb-4a61-9f1f-0f5a95bfcae8
---

GridTrader EA 自 v1.00 正式版起，之后每个版本号 **+0.01 递增**（1.00 → 1.01 → 1.02 …），体现在 `GridTrader.mq5` 的 `#property version`。

**How to apply:** 每次要发版/提交一个新版本时，把 `#property version` 在当前值基础上加 0.01；commit / PR 注释带上该版本号。v1.00 是首个正式版（PR #1，分支 release/v1.00），在此之前是 3.00 等旧开发版号（已废弃，不再沿用）。
