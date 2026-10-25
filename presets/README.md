# GridTrader Best-Configuration Preset (GridTrader_best.set)

The "best combination" of parameters found by backtest research. It can be loaded directly into the EA (chart EA inputs dialog / Strategy Tester → Load).

## ⚠️ Must change before use: the upper/lower range (most important)
`TradeGrid_UpperPrice=1.11940 / TradeGrid_LowerPrice=1.04430` in the `.set` are **example values for EURUSD 2024**.
**Before deploying, change them to the actual high / low of your symbol over roughly the last 3 months.** Placing the range correctly is the precondition for everything (a wrong range = losses or even a margin call, see [docs/STRATEGY_RESEARCH.md](../docs/STRATEGY_RESEARCH.md)).
- Because `FirstAtEdge=true`, the range must **closely fit the real price swing** (do not make it wider than the swing, or price never touches the bounds and no order ever opens).

## Basis for the configuration (backtest conclusions)
- **Both directions + LossCut=8 + laddered lots 0.02→0.01 + 28 grids + TP 35**: all four EUR pairs were profitable in 2024 with no margin call; LossCut is the most valuable single switch (higher net profit, lower drawdown).
- Trailing stop / trend filter = off (tested ineffective or harmful).

## Key parameters
| Parameter | Value | Purpose |
|---|---|---|
| Upper/Lower | **Change to the high/low of the last ~3 months** | Range (most critical) |
| GridCount | 28 | Spacing adapts to the range |
| TpThreshold_BasePips | 35 | Take-profit (total pips) |
| InitLots/Reduce | 0.02 / 0.01 | Laddered lots (largest at the bound) |
| LossCut_MinOrders | 8 | Loss cut on order count (**enabled by this preset**; the code default is 0 = off) |
| FirstAtEdge | true | First order must touch the bound |

## Risk red lines
- Use it **only in ranging markets**; trending markets lose money (a common weakness of grids).
- Laddered lots 0.02/0.01 improve results but also amplify risk; a misplaced range amplifies losses. Conservative option: InitLots=0.01, Reduce=0.0.
- Assumes a hedging account and a demo account by default; before live trading, observe on demo with small lots first.
- A full stop-out at the boundary on a one-way breakout is the designed worst case.

## How to load
- **Live/demo chart**: drag the EA onto the chart → Inputs tab → "Load" at the bottom right → choose this .set → change Upper/Lower → OK.
- **Strategy Tester**: Tester → select the EA (e.g. box\GridTrader) → Inputs tab → "Load", same as above.
