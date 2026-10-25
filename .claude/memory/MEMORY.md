# Memory Index

Grouped into "design / apply"; the file name prefixes `design-` / `apply-` match the groups.

## 🔧 Design (EA design decisions & implementation)
- [GridTrader cooldown threshold design](design-gridtrader-cooldown.md) — touch window < release threshold, prevents duplicate entries from jitter near a grid line
- [NormalizeLots(0) trap](design-mql5-normalizelots-zero-minlot.md) — returns the min lot, not 0; check the raw value > 0 before opening by a computed lot size
- [GridTrader version scheme](design-gridtrader-version-scheme.md) — since v1.00 each version bumps #property version by +0.01
- [GridTrader FirstAtEdge trap](design-gridtrader-firstatedge-trap.md) — range wider than the actual price swing → bounds never touched → no orders at all (FAE=true)

## 📊 Apply (backtest conclusions & tooling/operations experience)
- [Breakout check method backtest](apply-gridtrader-breakout-check-backtest.md) — wick/ATR best, ADX worst because its stop lags; stops must be timely, do not wait for confirmation
- [ADX filter backtest](apply-gridtrader-adx-filter-backtest.md) — harmful for the grid strategy, EURCAD net profit doubled with it off; breakout protection is enough, do not add indicator filters
- [MT5 tester graphic objects](apply-mt5-tester-objects-visual-only.md) — the non-visual test result chart does not draw ObjectCreate objects, only visual mode shows them
- [MT5 CLI backtest control flow](apply-mt5-cli-backtest-shutdown.md) — do not wait for the process to exit; watch the log for "thread finished" then Force Kill, otherwise 8-10 min timeouts
- [GridTrader strategy optimization summary](apply-gridtrader-strategy-regime.md) — LossCut most valuable; static wide range > rolling; both directions > one; do not extrapolate in-sample profit, risk control generalizes, profit depends on the market
