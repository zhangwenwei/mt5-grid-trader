# 记忆索引

按「设计 / 应用」两类分组；文件名前缀 `design-` / `apply-` 与之对应。

## 🔧 设计（EA 设计决策 & 代码实现）
- [GridTrader 冷却阈值设计](design-gridtrader-cooldown.md) — 触碰窗 < 解锁门槛, 防网格线附近抖动重复开单
- [NormalizeLots(0) 陷阱](design-mql5-normalizelots-zero-minlot.md) — 返回最小手非0, 按算出手数开单前判断原始值>0
- [GridTrader 版本号约定](design-gridtrader-version-scheme.md) — 自 v1.00 起每版 #property version +0.01 递增
- [GridTrader FirstAtEdge 陷阱](design-gridtrader-firstatedge-trap.md) — 区间比实际价幅宽时边界碰不到→一单不开(FAE=true)

## 📊 应用（回测结论 & 工具/操作经验）
- [越界判断方式回测结论](apply-gridtrader-breakout-check-backtest.md) — 含影线/ATR最优, ADX因止损滞后反而最差; 止损要及时不要等确认
- [ADX过滤回测结论](apply-gridtrader-adx-filter-backtest.md) — 对网格策略有害，EURCAD关掉后净利翻倍；越界保护已足够，勿加指标过滤
- [MT5测试器图形对象](apply-mt5-tester-objects-visual-only.md) — 非视觉回测结果图不画ObjectCreate对象, 只视觉模式显示
- [MT5 CLI 回测控制流](apply-mt5-cli-backtest-shutdown.md) — 不等进程退出，监控日志 "thread finished" 后立即 Force Kill，否则超时8-10分钟
- [GridTrader 策略寻优总结](apply-gridtrader-strategy-regime.md) — LossCut最值钱; 静态宽区间>滚动; 双向>单向; 样本内收益不外推, 风控泛化收益看行情
