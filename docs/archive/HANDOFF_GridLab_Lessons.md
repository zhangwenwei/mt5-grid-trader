# Grid Strategy Backtest Lessons — Hand-off Document

> ⚠️ **Archived · external document**: this document is about a different EA, **`GridLab.mq5`** (a unified framework with ranging/trend/martingale modes),
> **not this project's GridTrader** (a single range bi-directional grid). It is kept as a **reference for strategy lessons** —
> conclusions such as "a ranging grid only makes money in a true ranging market, EUR pairs range most reliably, martingale blows up and was eliminated"
> are exactly the background for why GridTrader focuses on range grids. **Do not treat the parameters/modes here as GridTrader settings.**

> Handed off to: whoever / whichever agent next works on grid performance optimization
> Source: 9 iterations / 35 backtests + 1 optimization run of 30 parameter sets
> Environment: MT5 Gaitame Finest (JPY broker), real ticks (Model 8), ¥100,000 / 1:25 / 0.01 lots / 18 ms latency
> Default backtest period: 2023.06.20–2026.06.19 (last 3 years), H1
> Assets: EA source `MQL5/Experts/GridLab.mq5` (unified ranging/trend/martingale framework, basket total stop + total TP); full data `RESULTS.md`

---

## 1. The single most important lesson (read this first)
**90% of a grid's success depends on whether "strategy ⇄ market type" match, not on parameter tuning.**
- Ranging (mean-reversion) grid → makes money only in a **true ranging market** (sell high, buy low, back and forth).
- Trend (pyramiding) grid → makes money only in **strong one-way markets**.
- Wrong match: at best repeated stop-outs and losses, at worst stacking orders into a margin call during a trend.
- **The market type cannot be known in advance** — that is the fundamental problem of grids. Before optimizing parameters, solve "how to detect/adapt to the current market"; that pays off far more than tweaking parameters.

## 2. How the three grids fared (USDJPY- H1, 3-year baseline)
| Variant | Net profit | Profit factor | Sharpe | Max equity DD | Min margin level | Conclusion |
|------|------|--------|------|------------|------------|------|
| Ranging OSC | -9,434 | 0.85 | -0.42 | 46% | 113% | Repeatedly stopped out in a one-way market → loss |
| Trend TREND | +12,506 | 1.03 | 0.26 | 18% | 519% | Caught the yen-depreciation trend → wins, but fragile |
| Martingale MART | +21,212 | 1.13 | 0.37 | 49% | **89.6%** | Highest profit but **fell below the stop-out level**, eliminated |

> Note: these three years of USDJPY were a strong one-way yen depreciation, so trend won and ranging lost. In a ranging market the conclusion reverses (see below).

## 3. Usable / eliminated
### ✅ Most robust and deployable: ranging grid × EUR ranging pairs
| Symbol | Net profit | Sharpe | Drawdown | Notes |
|------|------|------|------|------|
| EURUSD | +27,763 | 2.86 | 14% | Main pair, triple-validated |
| EURCHF | +27,408 | 1.11 | 20% | |
| EURGBP | +11,092 | 4.34 | 3% | Most stable but low return (very low volatility) |
| EURCAD | +11,349 | 0.53 | 12% | |

**All three validations (against overfitting) passed:**
1. By period: 2023-24 / 2024-25 / 2025-26 **each year profitable on its own**.
2. Parameters: step 15/30/40 gives almost the same net profit (~27-28k).
3. Stress test: extended to 5 years (including the strong 2022 EURUSD trend down to parity), still net profitable, **no margin call at any point** (minimum margin level 155%).

**Portfolio (4 EUR pairs, equal weight, ¥100k each): +19.4% over 3 years, realized drawdown only 2.4%** (a significant diversification benefit from low correlation).

### ⚠️ Fragile: trend grid
- USDJPY +12.5k looks good, but **year by year: -3664 / +19219 / -3566** — the profit came almost entirely from one strong trend in 2024-25.
- On ranging EURUSD it lost -36k; on high-volatility GBPJPY the **drawdown reached 92%, nearly a margin call**.

### ❌ Eliminated: martingale grid
- Highest profit, but the minimum margin level fell below 100% (close to forced liquidation), violating "never blow up".
- **Key counter-intuitive point**: "tightening the total stop" on the martingale cuts losses before the floating loss recovers and turns profit into loss. A martingale cannot be made safe by simply tightening the SL.

## 4. Parameter sensitivity (from the full 30-set optimization, ranging × EURUSD)
- **MaxLevels is a "fake parameter"**: no effect at all at ≥ 8 (EURUSD rarely stacked more than 8 levels in three years, and the total stop caps the levels). Give it enough and stop wasting an optimization dimension on it.
- **GridStep is the only real driver**, but the whole 15–40 pip range is a **flat plateau** (net 27.5–27.9k, Sharpe 2.9–3.7, drawdown 10–14%) → there is no magic value that needs fine tuning.
- **The only minefield**: tight step + many levels (Step15 + Lv8 = -1200, drawdown 32.5%). **Rule: the tighter the step, the fewer the levels**, otherwise orders stack too deep in a trend and the total stop cuts them.
- **Direction of total-stop tightness**: for a mean-reversion grid **a tighter total stop is better** (cuts losing baskets early in trends, never triggers in calm periods, no side effects); the opposite holds for martingale.
- Locked configuration: `GridStep=30~35pip, MaxLevels=10, per-level TP = follows the step, basket total stop = 15k, total TP = 3k`.

## 5. Pitfalls / engineering notes
1. **Always kill the terminal64 process before a backtest**: if a live GUI instance is running, `terminal64 /config` hands over to it and exits immediately, so the backtest never runs (no report, a leftover GUI window). Before every launch `Stop-Process terminal64` + sleep 0.7 s.
2. **This broker has no GBPUSD-** (a JPY broker). Available majors: EURUSD-/USDCHF-/USDCAD- + the JPY crosses + the EUR crosses. Symbols carry a `-` suffix.
3. **HTML reports are UTF-16 LE with Chinese labels**; parse with `decode('utf-16-le')`. Key fields: total net profit / profit factor / Sharpe ratio / maximal equity drawdown / margin level / total trades. Both the orders table and the deals table start with a date-time, so **anchor on the deals table header (balance column) when parsing the balance curve** and do not grab the orders table by mistake.
4. **This EA's ranging mode is tick-driven, not bar-triggered** → the timeframe (M15/H1/H4) has no effect on OSC. To make the timeframe matter, add a `lastBarTime` new-bar gate.
5. The ini latency needs both lines `ExecutionMode=1` + `ExecutionDelay=18` (writing `ExecutionMode=18` by mistake is silently ignored).

## 6. Clear directions for further optimization (by value)
1. **Market adaptation (highest value)**: give GridLab ADX / Bollinger bandwidth / long-timeframe slope detection of ranging vs trending, and switch OSC/TREND modes or pause automatically. It addresses the fundamental "market type unknown in advance" problem and pays off far more than tweaking parameters.
2. **Out-of-sample / forward validation**: run walk-forward with MT5 ForwardMode to confirm the locked parameters do not degrade on unseen data (so far only split by period, no strict WFA).
3. **Dynamic lots / spacing**: use ATR-adaptive grid spacing (GridMasterPro already has ATR spacing to borrow from) instead of fixed pips.
4. **Portfolio-level optimization**: the current portfolio is a simple equal-weight stack; consider correlation weighting, capital allocation by each symbol's volatility, and a unified portfolio-level total stop.
5. **Making martingale safe**: if you still want martingale's high win rate, the answer is not a tighter SL but limiting the maximum cumulative lots/exposure + enabling it only in confirmed ranges.
6. **More symbols**: validate the ranging grid on more true ranging pairs (e.g. AUDCAD-, EURGBP-); note that AUDNZD was actually trending in these three years (the ranging grid lost), do not assume.

## 7. Scoring function suggestion
The current optimization uses "survival-first Sharpe": DD ≥ 90% counts as a blow-up with a heavy penalty, otherwise Sharpe. Next, add a **drawdown constraint** to the score (e.g. `Sharpe × (1 - DD/limit)` or a large penalty for combinations with DD above a threshold), so the optimizer ranks under the "never blow up" premise instead of chasing Sharpe alone.
