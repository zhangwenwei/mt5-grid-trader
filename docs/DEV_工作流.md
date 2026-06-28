# GridTrader 开发 / 回测工作流

> 操作流程类备忘（怎么编译、怎么回测、怎么核对结果），从 CLAUDE.md 拆出来放这里。
> CLAUDE.md 只保留「软件是什么、逻辑怎么跑」；本文件管「怎么干活」。
> 编译命令见 CLAUDE.md「编译」一节；本文件覆盖回测相关。

## 回测前置：先关掉占用的 MT5（已自动化）
- 命令行 `terminal64 /config:...` 若已有 MT5 实例（含实盘 GUI）在跑，会**移交给现有实例并秒退**，回测根本没真跑（报告不生成）。详见记忆 `apply-mt5-cli-backtest-shutdown`。
- 所以每次回测前必须先 `Stop-Process -Name terminal64 -Force`（+ sleep ~0.7s）再启动。
- **已做成钩子自动处理**：PreToolUse 钩子 `.claude/hooks/kill-mt5-before-backtest.sh`（注册于 `.claude/settings.json`）会在执行"同时含 `terminal64` 和 `config`"的启动命令前，自动杀掉占用的 MT5 再放行；纯查询命令不触发。用户已授权回测前可擅自关闭 MT5。
- 该钩子在 `.claude/`（被 .gitignore 排除），仅本机生效、不随仓库走。

## 回测 ini 参数名（与代码变量名一致）
回测 ini 文件的 `[TesterInputs]` 须用以下实际变量名：
> 注：下列为回测**示例取值**，非代码 input 默认值（例 TpThreshold_BasePips 这里示例 60，代码默认是 30，见 BASELINE.md §2）。
```ini
[TesterInputs]
TradeGrid_UpperPrice=1.1400
TradeGrid_LowerPrice=1.0600
TradeGrid_EnableBuy=true
TradeGrid_EnableSell=true
TradeGrid_GridCount=10
TradeGrid_FirstAtEdge=true
LotForLine_InitLots=0.01
LotForLine_ReducePerLine=0.0
LotForLine_MinLots=0.01
TpThreshold_BasePips=60
TrailTotal_AddPerOrder=0
TrailTotal_Enable=false
TrailTotal_KeepPct=70
LossCut_MinOrders=0
BreakoutDist_AtrMult=1.0
BreakoutDist_AtrPeriod=14
OnTick_MaxSpread=0
CTrade_Magic=20240601
CTrade_Slippage=30
DrawLines_ShowGraphics=false
```

## 回测验证
- 无法远程触发 MT5 测试器 GUI；验证靠**读回测日志逐笔核对**。
- 日志：`C:\Users\ZWW\AppData\Roaming\MetaQuotes\Tester\<TerminalID>\Agent-127.0.0.1-30xx\logs\<date>.log`（UTF-16，取修改时间最新的 Agent）。
- 命令行编译后 MT5 端**必须重新加载 EA / 重开测试器**才生效，否则看的是缓存旧参数(反复踩过)。
- 回测无数据/秒结束：先查日志 `history data begins from ...`，常见是回测区间早于品种可用历史。
