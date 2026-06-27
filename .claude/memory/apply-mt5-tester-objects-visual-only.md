---
name: apply-mt5-tester-objects-visual-only
description: "MT5 非视觉回测结果图不渲染 ObjectCreate 对象, 只在视觉模式显示"
metadata: 
  node_type: memory
  type: reference
  originSessionId: f7d238bd-1d4e-4ddd-b715-e38b0ea37c83
---

MT5 策略测试器机制: 后台(非视觉)回测结束自动弹出的结果图, **只显示成交记录和指标**,
不渲染任何 ObjectCreate 画的图形对象(水平线/竖线/文字标签)。曾反复以为是代码 bug, 其实是 MT5 设计限制。

- 要看 EA 画的线: 必须用**视觉模式(Visual mode)**回测, 或挂到实盘/模拟图。
- OnDeinit 里画对象**一定不显示**(它在视觉窗口关闭后才执行)。
- OBJ_HLINE 只需价格、不需时间锚点, 在 OnInit 即可可靠创建; OBJ_TREND 需时间锚点, 在 OnInit 测试器里坐标系未就绪会创建失败(画不出)。水平线一律用 OBJ_HLINE。
- 命令行非视觉回测**无法**验证"线显不显示", 只能验证交易逻辑(读 STATS/日志)。

来源: MQL5 Book "Testing visualization: chart, objects, indicators"。
