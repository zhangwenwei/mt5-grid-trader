# GridTrader Refactor Equivalence Verification Report (VERIFICATION.md)

> ⚠️ **Historical archive (v1.05)**: this report verified the v1.05 refactor that "extracted the fixed take-profit into `Mgmt_FixedTP()`".
> **The current v1.06 code no longer has a `Mgmt_FixedTP` function** (the fixed TP was moved back inline into `OnTick`),
> so this report no longer matches any existing code. It is kept for history only — **do not use it to understand the current behavior**.
> The current behavior is defined by [BASELINE.md](../../BASELINE.md) and `GridTrader.mq5`.
> At the time of this report, log messages and chart labels were in Chinese; they are quoted here in English translation.

> Verifier: an independent subagent (not involved in the refactor)
> Reference: BASELINE.md + the original code (inline OnTick logic before the refactor)

---

## Overall conclusion

**PASS — all 40/40 items passed, behavior fully equivalent**

The only substantive change of the refactor was extracting the fixed-TP block inlined in OnTick into a `Mgmt_FixedTP()` function;
everything else was function reordering. Verification confirmed that every path behaves exactly like the original.

---

## Item-by-item verification

| # | Check | Result | Notes |
|---|--------|------|------|
| **A. OnTick call order** | | | |
| A1 | Spread filter comes first | **PASS** | `if(OnTick_MaxSpread > 0)` is the first effective statement in OnTick |
| A2 | `double grid = g_grid` declared right after the spread filter | **PASS** | `double grid = g_grid;` immediately follows the spread filter block |
| A3 | `DrawInfoPanel()` called right after the grid declaration | **PASS** | Called immediately after the grid declaration |
| A4 | lblBar label refresh block after DrawInfoPanel | **PASS** | The `static datetime lblBar = 0` block follows DrawInfoPanel |
| A5 | `HandleBreakout()` after the label refresh, true→return | **PASS** | `if(HandleBreakout()) return;` is after the lblBar block |
| A6 | `CheckLossCut()` after HandleBreakout, true→return | **PASS** | `if(CheckLossCut()) return;` follows immediately |
| A7 | Fixed TP after CheckLossCut (condition: `!TrailTotal_Enable && BasePips>0`) | **PASS** | Condition identical to the original |
| A8 | Trailing stop after the fixed TP (condition: `TrailTotal_Enable`) | **PASS** | `if(TrailTotal_Enable && TrailTotal()) return;` |
| A9 | `TradeGrid(grid)` last | **PASS** | Last statement of OnTick |
| **B. Mgmt_FixedTP() equivalence (core change)** | | | |
| B10 | Buy group: CountSide(BUY) first, then TotalPipsByType(BUY), condition `buyN>0 && buyPips>=BasePips` | **PASS** | Order and condition identical |
| B11 | Buy group PrintFormat format string identical to the original | **PASS** | `"Buy group TP: buy group total profit %.1f total pips >= %d, closing all buys"` is byte-for-byte identical to the original inline code (checked against the original code) |
| B12 | Buy trigger: `DrawCloseLabel("Buy TP", buyPips, BID)` arguments identical | **PASS** | `DrawCloseLabel("Buy TP", buyPips, SymbolInfoDouble(_Symbol, SYMBOL_BID))` |
| B13 | After the buy trigger `closedAny=true`, **no immediate return**, the sell group is still checked | **PASS** | No return after `closedAny=true`; the sell check continues |
| B14 | Sell group: independent `CountSide(SELL)` and `TotalPipsByType(SELL)` (buy variables not reused) | **PASS** | `sellN` / `sellPips` declared independently |
| B15 | Sell group PrintFormat format string identical to the original | **PASS** | `"Sell group TP: sell group total profit %.1f total pips >= %d, closing all sells"` byte-for-byte identical |
| B16 | Sell trigger: `DrawCloseLabel("Sell TP", sellPips, ASK)` arguments identical | **PASS** | `DrawCloseLabel("Sell TP", sellPips, SymbolInfoDouble(_Symbol, SYMBOL_ASK))` |
| B17 | `closedAny=true` after the sell trigger | **PASS** | Set correctly |
| B18 | Return value equivalent: original `if(closedAny) return` = new `if(Mgmt_FixedTP()) return` | **PASS** | `return(closedAny)` + caller `if(Mgmt_FixedTP()) return;`, semantically identical |
| **C. Integrity of all function bodies** | | | |
| C19 | `TradeGrid()` matches BASELINE 8.1 (tol/release/cooldown/arming/loops) | **PASS** | `tol=grid*0.25`, `release=grid*0.75`; cooldown release before CountSide; arming after CountSide; loops identical line by line |
| C20 | `LotForLine()` exact formula: distEdge uses MathRound, floored at MinLots, returns NormalizeLots | **PASS** | `(int)MathRound(…)`; MinLots floor; `return(NormalizeLots(lots))` |
| C21 | `NormalizeLots()` MathFloor rounding down, clamp to [min,max], NormalizeDouble(x,2) | **PASS** | All three steps correct |
| C22 | `TotalPipsByType()` buy: (bid-open)/g_pip×vol, sell: (open-ask)/g_pip×vol, sum/MinLots | **PASS** | Formula matches BASELINE 8.4 |
| C23 | `HasOrderNear()` tol=grid*0.5, condition `< tol` (strictly less) | **PASS** | `grid * 0.5`; `MathAbs(...) < tol` (not <=) |
| C24 | `HandleBreakout()` static evalBar, evaluated once per bar, per-tick CloseAll while `g_outOfRange` | **PASS** | `static datetime evalBar = 0`; `curBar != evalBar` guard; per-tick `CloseAll()` while out of range |
| C25 | `TrailTotal()` peak updated before the trigger check, reset to zero after triggering | **PASS** | `if(p > g_trailPeak) g_trailPeak = p` first, then the trigger check, then `g_trailPeak = 0.0`; buy/sell independent |
| C26 | `CheckLossCut()` returns false immediately when `LossCut_MinOrders<=0` | **PASS** | Early return in the first statement |
| C27 | `EffectiveKeepRatio()` pct capped at 90, return pct/100.0 | **PASS** | `if(pct > 90) pct = 90`; `return(pct / 100.0)` |
| C28 | `FloatingPnL()` Σ(Profit+Swap), filtered by Symbol+Magic+Type | **PASS** | Triple filter + `pos.Profit() + pos.Swap()` accumulation |
| C29 | `BreakoutDist()` CopyBuffer shift=1 (ATR of the last closed bar) | **PASS** | `CopyBuffer(g_boAtrHandle, 0, 1, 1, atr)`, third argument = 1 |
| C30 | `ClampBuffer()` maxBuf=(upper-lower)*0.4 | **PASS** | `(g_upper - g_lower) * 0.4` |
| **D. Global state and lifecycle** | | | |
| D31 | All global variable names, types and initial values identical | **PASS** | All 15 globals checked, no differences |
| D32 | `OnInit()` validation order matches BASELINE §4 | **PASS** | The six steps a→b→c→d→e→f match exactly |
| D33 | `OnDeinit()` releases the ATR handle, does not delete GT_ objects | **PASS** | `IndicatorRelease`; no `ObjectDelete("GT_…")` call at all |
| D34 | `OnTester()` returns STAT_PROFIT | **PASS** | `return(profit)` with `profit = TesterStatistics(STAT_PROFIT)` |
| **E. Function visibility** | | | |
| E35 | `Mgmt_FixedTP()` calls `DrawCloseLabel` (defined later) — allowed in MQL5 | **PASS** | MQL5 needs no forward declarations; the compiler resolves all symbols after scanning the whole file |
| E36 | Every function called from OnTick is defined in the same file | **PASS** | `DrawInfoPanel`/`HandleBreakout`/`CheckLossCut`/`Mgmt_FixedTP`/`TrailTotal`/`TradeGrid` are all defined in GridTrader.mq5 |
| **F. Focused check of potential differences** | | | |
| F37 | `Mgmt_FixedTP` still checks the sell group after closing the buy group (double check) | **PASS** | No return after `closedAny=true`, the sell check continues; fully equivalent to the original `if(closedAny) return` placed after both groups |
| F38 | `TrailTotal` still checks the sell group after closing the buy group | **PASS** | `closed` aggregates both groups; a single `return(closed)` at the end |
| F39 | The 4 static variables of `DrawInfoPanel` are kept | **PASS** | `prevBuyTxt`/`prevBuyClr`/`prevSellTxt`/`prevSellClr` all kept |
| F40 | The static evalBar of `HandleBreakout` is kept | **PASS** | `static datetime evalBar = 0;` kept |

---

## Differences found

**No FAIL items.**

---

## Summary of structural changes (for reference)

| Change | Nature | Effect on trading behavior |
|------|------|----------------|
| Functions reordered into 7 modules | Pure structure | None (MQL5 calls do not depend on definition order) |
| New `Mgmt_FixedTP()` | Inline code extracted into a function | None (fully equivalent, see B10–B18) |
| OnTick fixed-TP block replaced by a function call | Refactor | None (identical logic path) |

---

## Strategy Tester A/B comparison steps

> After the code verification, an empirical comparison in the Strategy Tester is recommended; the results should be identical.

**Preparation**: before the refactor, save the original with `git stash` or `git show HEAD~1:GridTrader.mq5 > GridTrader_orig.mq5`,
or simply run `git diff HEAD~1..HEAD GridTrader.mq5` to confirm the differences are only function reordering.

**A/B comparison settings (every field must be identical in both runs)**:

```
Symbol:      pick one (e.g. USDJPY)
Timeframe:   H1 (or any fixed timeframe)
Period:      2024-01-01 ~ 2024-06-30 (or any fixed period)
Modelling:   Every tick (price only)
Deposit:     10000 USD
Leverage:    1:100
```

**Metrics to compare (both reports must match exactly)**:
1. Total number of trades
2. For each trade: timestamp / direction / lots / open price / close price / P/L
3. Net profit
4. Maximum drawdown (money & percent)
5. Shape of the equity curve

**If they differ**:
- Find the first moment a difference appears → compare the OnTick call path at that moment
- Focus on whether `Mgmt_FixedTP` still checks the sell group when the buy group is closed
