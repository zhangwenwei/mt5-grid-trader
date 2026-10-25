# GridTrader Strategy Research Summary (mainly EURUSD, real-tick backtests)

> All results come from MT5 real-tick (Model 8) backtests, not hand-calculated simulations. About 100+ backtests in total.
> Absolute JPY figures are optimistic because they depend on "range width / FirstAtEdge / whether positions are carried across windows"; **focus on relative rankings and directional conclusions**.
> Every "profitable" conclusion assumes **a ranging market**.

> **Note on branches:** this research was done on the `strat/losscut-default` branch, which also changed the code default of `LossCut_MinOrders` from 0 to 8. **On `main` the code default is still 0 (off)**; the recommended value 8 is applied through [presets/GridTrader_best.set](../presets/GridTrader_best.set).

## 1. Final recommended configuration (both directions + LossCut on + laddered lots)
| Parameter | Value | Notes |
|---|---|---|
| Direction | Both (Buy + Sell) | Highest net profit in every market condition (see §3) |
| GridCount | 28 (spacing adapts to the range width) | Peak of the profit-vs-density curve, highest profit factor |
| TpThreshold_BasePips | 30–45 | Sweet spot, a stable plateau |
| LotForLine_InitLots / Reduce | 0.02 / 0.01 (laddered) | Improves results; fixed 0.01 is the conservative option |
| **LossCut_MinOrders** | **8 (on)** | **Most valuable single switch: higher net profit, lower drawdown** |
| Range Upper/Lower | Covers the recent actual price swing (wide, static) | Do not roll it narrower, do not set it wider than the actual swing |
| Trailing stop / trend filter | Off | Ineffective or harmful |

> A ready-to-load parameter file is [presets/GridTrader_best.set](../presets/GridTrader_best.set) (before use, Upper/Lower must be changed to the actual high/low of the last ~3 months).

## 2. Experiment results
### 1) Parameter optimization (pure ranging window 2023.07–2024.12, FAE=true)
- Best: grid 28 / TP 45 / ladder 0.03→0.01 → net profit +6787, drawdown 1.3%, PF 4.88, RF 5.04, no margin call.
- Sensitivities: net profit vs grid count = concave (peak at 24–32); vs TP = interior optimum (sweet spot 30–45); vs lots = scales linearly, but drawdown/PF deteriorate in step; drawdown is driven almost entirely by lot size.

### 2) Walk-forward: static vs rolling range (2024, FAE=false)
| | Total net profit | Notes |
|---|---|---|
| Static (wide band fixed for the whole year) | +18,044 / +38,140 (best config) | Wins |
| Monthly rolling | +11,370 | Loses |
| Quarterly rolling (best config) | +10,636 | Loses |
- **Rolling always loses to static**: after resetting to a narrower recent band, the next quarter's drift pushes price out and triggers frequent breakout stops. **A wide static range that covers the whole period works best.**

### 3) Direction variants (buy-only / sell-only, parameters only)
| Market | Both | Buy only | Sell only |
|---|---|---|---|
| 2023 H1 rising | **59948** | 38839 | 21109 |
| 2024 net falling | **31110** | 6749 | 24361 |
- A single direction = a bet on the macro direction (buy-only wins in rising periods, sell-only in falling periods), **but neither beats both directions** (both directions capture the drift and the two-sided oscillation, and LossCut cuts the bleeding counter-trend side).

### 4) Parameter-level strategy comparison (full year 2024)
| Strategy | Net profit | Drawdown | PF |
|---|---|---|---|
| Baseline | 18044 | 27.7% | 1.17 |
| Trailing stop | 23083 | 26.7% | 1.22 |
| **Loss cut LossCut=8** | 26180 | **21.8%** | 1.25 |
| Laddered lots 0.02/0.01 | 22974 | 28.9% | 1.21 |
| **Ladder + loss cut** | **31110** | 23.3% | **1.30** |

### 5) Generalization across symbols (2024, best config)
| Symbol | Net profit | Drawdown | PF |
|---|---|---|---|
| EURUSD- | +38174 | 16.8% | 1.44 |
| EURGBP- | +14101 | 14.6% | 1.22 |
| EURCHF- | +9514 | 29.9% | 1.07 |
| EURCAD- | +15935 | 18.5% | 1.13 |
- All four EUR pairs were **profitable with no margin call** → the configuration generalizes (EURUSD strongest, EURCHF weakest).

### 6) Code variant: trend pause (branch strat/trend-pause, negative)
- The most sensitive setting only slightly lowered drawdown without improving net profit; loosening the threshold turned it into a loss. **Trend/indicator filters do not help a grid**, consistent with the earlier ADX conclusion. Not recommended for merging into main.

### 7) Strict multi-symbol out-of-sample walk-forward (IS = range set on 2024 H1 → OOS = 2024 H2, best config)
| Symbol | IS net profit (H1) | OOS net profit (H2) |
|---|---|---|
| EURUSD- | +57,057 (DD 8.8%) | **−3,315** (DD 15.1%) |
| EURGBP- | +29,752 (DD 10.9%) | **−8,188** (DD 13.3%) |
- **Large in-sample profits → out-of-sample losses**: in H2 price drifted out of the range set from H1, and a fixed range breaks down once price drifts. OOS still had **no margin call and drawdown held at 13–15%**.
- **Conclusion**: risk control generalizes, profit does not. **Do not extrapolate in-sample figures**; for live trading expect "trustworthy risk control, returns depend on the market", and keep the range aligned with the current price swing.

## 3. Key conclusions
1. **The built-in, off-by-default "loss cut on order count" (LossCut) is the most valuable switch** (higher net profit, lower drawdown). The research branch changed its default to 8; on `main` the default is still 0 and the preset sets it to 8.
2. **Both directions + LossCut + laddered lots + wide static range + ranging markets only** = the best combination, and it generalizes across symbols.
3. **Adding code, filters, rolling ranges or directional bets never beat it.** 90% of a grid's success depends on "market match (range vs trend) + a correctly placed range", not on parameter tuning or added indicators.
4. No configuration hit a margin call — the breakout full close works as the safety net.

## 4. Risks and disclaimer
- **In-sample ≠ out-of-sample**: the multi-symbol walk-forward shows large in-sample profits turning into out-of-sample losses (see §2.7); most absolute figures are inflated by FAE=false, do not extrapolate them.
- Laddered lots cut both ways (with a misplaced range they amplify losses; one run blew up at −35k); use them only when the range is placed correctly.
- Everything assumes a ranging market; trending periods lose money (verified). Judge the current market type before trading live.

## 5. Branches (none merged into main)
- `strat/trend-pause`: trend-pause variant (negative result archived, v1.07).
- `strat/losscut-default`: LossCut default 0→8 + the original version of this summary (v1.07).
- `main`: stays at v1.06 with LossCut default 0.
