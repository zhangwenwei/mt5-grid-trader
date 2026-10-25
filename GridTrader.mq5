//+------------------------------------------------------------------+
//|                                                   GridTrader.mq5  |
//|     Range bi-directional grid EA - sell upper half / buy lower half |
//|                                                                  |
//|  Logic: upper/lower bounds are entered manually,                 |
//|         center = (upper + lower) / 2;                            |
//|         price touching a line between center~upper -> sell,      |
//|         between lower~center -> buy; the center line never trades;|
//|         exits via per-side total take-profit / trailing stop.    |
//|         bid/ask beyond upper/lower (checked every tick)          |
//|         -> close all and pause new entries;                      |
//|         trading resumes automatically once price is back inside. |
//|                                                                  |
//|  Risk: on a one-way breakout the range grid is stopped out at the|
//|  boundary with a full close - this is the designed worst case.   |
//|  Same-side positions can accumulate inside the range (naturally  |
//|  capped by the number of grid lines ~ GridCount/2). Keep lots and|
//|  grid count under control, watch margin, test on demo first.     |
//+------------------------------------------------------------------+
#property copyright "GridTrader"
#property version   "1.06"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//--- Inputs ---------------------------------------------------------
input group           "=== Direction ==="
input bool     TradeGrid_EnableBuy        = true;      // TradeGrid_EnableBuy | Allow buys in the lower half
input bool     TradeGrid_EnableSell       = true;      // TradeGrid_EnableSell | Allow sells in the upper half

input group           "=== Grid range (required, manual) ==="
// Upper/lower bounds must be entered as explicit prices; center = (upper + lower) / 2 is computed automatically.
input double   TradeGrid_UpperPrice       = 0;         // TradeGrid_UpperPrice | Grid upper bound price (required, >0)
input double   TradeGrid_LowerPrice       = 0;         // TradeGrid_LowerPrice | Grid lower bound price (required, >0)

input group           "=== Grid settings ==="
// Grid count: the range is split into this many equal cells; spacing = (upper - lower) / count, computed automatically.
// Example: 110-111 with 10 -> 0.1 per cell. Buys are laid from the lower bound toward the center, sells from the upper bound toward the center; the center never trades.
input int      TradeGrid_GridCount        = 10;        // TradeGrid_GridCount | Grid count (>=2; splits the range evenly, spacing is automatic)
// Note: the number of same-side open positions is naturally capped by the number of grid lines (~GridCount/2), so there is no separate "max orders" input.
// When a side is flat, its first order waits until price touches that side's bound (sell: upper / buy: lower), to avoid opening mid-range.
input bool     TradeGrid_FirstAtEdge = true;      // TradeGrid_FirstAtEdge | First order requires touching the bound (applies when the side is flat)

input group           "=== Lot size (laddered: largest at the bound, decreasing toward the center) ==="
// The grid line closest to the bound uses LotForLine_InitLots; each line further toward the center subtracts LotForLine_ReducePerLine; never below LotForLine_MinLots.
// LotForLine_ReducePerLine=0 means every line uses LotForLine_InitLots (i.e. fixed lot size).
input double   LotForLine_InitLots   = 0.01;            // LotForLine_InitLots | Initial lots at the bound (closest to the bound, largest)
input double   LotForLine_ReducePerLine = 0.0;             // LotForLine_ReducePerLine | Lots subtracted per line toward the center (0 = fixed lots)
input double   LotForLine_MinLots    = 0.01;            // LotForLine_MinLots | Minimum lot size floor

input group           "=== Per-side total take-profit ==="
// Buy and sell groups each compute their "total profit pips" (sum of pips x lots / LotForLine_MinLots, lot-weighted sum in min-lot units); reaching TpThreshold_BasePips -> close every order on that side.
// It is a sum over the group (not an average): more orders / larger lots reach it sooner; with all orders at the min lot it equals the plain sum of each order's pips.
input int      TpThreshold_BasePips        = 30;           // TpThreshold_BasePips | TP threshold (total pips): fixed TP trigger / trailing-stop activation level

input group           "=== Trailing stop (switch; when ON it replaces the total take-profit above) ==="
// Tracking starts once the peak total profit (total pips) reaches the activation threshold; when profit falls back to "TrailTotal_KeepPct% of the peak", every order on that side is closed.
// The activation threshold is fixed at TpThreshold_BasePips (it does not change with the order count); TrailTotal_AddPerOrder only tightens the keep percentage.
input bool     TrailTotal_Enable     = false;      // TrailTotal_Enable | Enable trailing stop (ON replaces the total take-profit)
input int      TrailTotal_KeepPct    = 70;         // TrailTotal_KeepPct | Close when profit drops to this % of the peak; higher = tighter. E.g. 80 = close at 80% of the peak
input int      TrailTotal_AddPerOrder = 0;         // TrailTotal_AddPerOrder | Extra percentage points of tightening per additional order (0 = constant; capped at 90%; e.g. base 70 + 5/order -> 1 order 70 / 2 orders 75 / 3 orders 80)

input group           "=== Breakout detection (how breakout / recovery is measured; a breakout always closes everything) ==="
// Evaluated in real time on the current tick's bid/ask (every tick, wick spikes trigger immediately). Breakout and recovery share one distance (an ATR multiple, adapts to volatility):
//   breakout = bid above (upper + distance) or ask below (lower - distance) -> close all orders and pause (blue vertical line);
//   recovery = bid back below (upper - buffer) and ask back above (lower + buffer) -> trading resumes automatically.
input double   BreakoutDist_AtrMult       = 1.0;      // BreakoutDist_AtrMult | Breakout/recovery distance = this multiple x ATR
input int      BreakoutDist_AtrPeriod = 14;       // BreakoutDist_AtrPeriod | ATR period

input group           "=== Loss cut on order count (close a side when it holds too many orders and is in a floating loss) ==="
// When the buy count or the sell count alone exceeds LossCut_MinOrders and that side's floating P/L (including swap) is < 0, close that side.
// Buys and sells are checked independently. 0 = protection disabled.
input int      LossCut_MinOrders = 0;         // LossCut_MinOrders | Loss-cut order count (checked when a side holds more than this; 0 = off)

input group           "=== Filters & risk ==="
input int      OnTick_MaxSpread  = 0;         // OnTick_MaxSpread | Max spread (points), <=0 = no limit
input long     CTrade_Magic            = 20240601;  // CTrade_Magic | Magic number
input ulong    CTrade_Slippage   = 30;        // CTrade_Slippage | Allowed slippage (points)

input group           "=== Graphics ==="
input bool     DrawLines_ShowGraphics     = true;      // DrawLines_ShowGraphics | Master switch for drawing (bounds/grid/vertical lines/info panel); off = draw nothing, trading unaffected

//--- Global objects -------------------------------------------------
CTrade        trade;
CPositionInfo pos;

double g_pip    = 0.0;
double g_point  = 0.0;
int    g_digits = 0;
double g_center = 0.0;   // center = (upper + lower) / 2
double g_upper  = 0.0;   // grid upper bound
double g_lower  = 0.0;   // grid lower bound
double g_grid   = 0.0;   // spacing = (upper - lower) / TradeGrid_GridCount (computed in OnInit)

// Cooldown: remembers the grid line price of the last order opened on each side.
// Price must really leave that line (by more than 3/4 of a cell) before the line may trade again,
// preventing an immediate re-entry after TP and repeated entries on large gaps.
// 0 means no record (armed, may open).
double g_lastBuyLine  = 0.0;
double g_lastSellLine = 0.0;

// First-order bound arming (TradeGrid_FirstAtEdge): true = the bare bound has been touched, so the first order may open while flat.
// Disarmed when the side is flat and price moves more than release away from the bound; a new touch is then required.
bool   g_sellArmed = false;   // sell group: may open the first sell only after touching the upper bound
bool   g_buyArmed  = false;   // buy group: may open the first buy only after touching the lower bound

// Total trailing stop: peak of the side's total floating pips (close the group on pullback once >= the threshold). Reset to 0 when flat.
double g_trailPeakBuy  = 0.0;
double g_trailPeakSell = 0.0;

// ATR handle for the breakout distance (breakout detection always uses ATR; created in OnInit)
int    g_boAtrHandle = INVALID_HANDLE;

// Out-of-range state: evaluated in real time on the current tick's bid/ask, true = currently outside the range.
// Full close stop: out of range -> close all and pause; back in range -> resume automatically.
bool   g_outOfRange   = false;

//+------------------------------------------------------------------+
int OnInit()
  {
   // In visual testing the tester shows the indicators the EA uses (e.g. ATR) by default; hide them to keep the chart clean (tester only)
   TesterHideIndicators(true);

   g_point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   g_pip    = (g_digits == 3 || g_digits == 5) ? 10 * g_point : g_point;

   trade.SetExpertMagicNumber(CTrade_Magic);
   trade.SetDeviationInPoints(CTrade_Slippage);
   trade.SetTypeFillingBySymbol(_Symbol);

   if(TradeGrid_GridCount < 2)
     {
      Print("Invalid input: grid count must be >= 2");
      return(INIT_PARAMETERS_INCORRECT);
     }

   if(LotForLine_InitLots <= 0 || LotForLine_MinLots <= 0 || LotForLine_ReducePerLine < 0 || LotForLine_InitLots < LotForLine_MinLots)
     {
      Print("Invalid input: InitLots/MinLots must be > 0, ReduceLots >= 0, and InitLots >= MinLots");
      return(INIT_PARAMETERS_INCORRECT);
     }

   if(TrailTotal_AddPerOrder < 0)
     {
      Print("Invalid input: TrailTotal_AddPerOrder must be >= 0 (tightening per extra order, 0 = constant)");
      return(INIT_PARAMETERS_INCORRECT);
     }

   if(TrailTotal_Enable && (TrailTotal_KeepPct <= 0 || TrailTotal_KeepPct >= 100 || TpThreshold_BasePips <= 0))
     {
      Print("Invalid input: trailing stop requires TpThreshold_BasePips > 0 and keep % (TrailTotal_KeepPct) within (0,100)");
      return(INIT_PARAMETERS_INCORRECT);
     }

   // Upper/lower bounds must be entered manually and upper > lower
   if(TradeGrid_UpperPrice <= 0 || TradeGrid_LowerPrice <= 0)
     {
      Print("Invalid input: upper/lower bounds must be entered as explicit prices (>0)");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(TradeGrid_UpperPrice <= TradeGrid_LowerPrice)
     {
      PrintFormat("Invalid input: upper bound (%.5f) must be greater than lower bound (%.5f)", TradeGrid_UpperPrice, TradeGrid_LowerPrice);
      return(INIT_PARAMETERS_INCORRECT);
     }

   // Breakout distance uses ATR: create the ATR handle
   g_boAtrHandle = iATR(_Symbol, _Period, BreakoutDist_AtrPeriod);
   if(g_boAtrHandle == INVALID_HANDLE){ Print("Failed to create ATR handle"); return(INIT_FAILED); }

   g_upper  = TradeGrid_UpperPrice;
   g_lower  = TradeGrid_LowerPrice;
   g_center = (g_upper + g_lower) / 2.0;
   g_grid   = (g_upper - g_lower) / TradeGrid_GridCount;   // spacing = range width / grid count

   DrawLines();
   DrawInfoPanelTrail();   // the top-row settings never change at runtime, so draw them once in OnInit

   PrintFormat("GridTrader v1.06 started. upper=%.5f center=%.5f lower=%.5f grids=%d spacing=%.5f",
               g_upper, g_center, g_lower, TradeGrid_GridCount, g_grid);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   // Release indicator handles
   if(g_boAtrHandle    != INVALID_HANDLE) IndicatorRelease(g_boAtrHandle);

   // GT_ objects are not deleted: bounds/center/grid lines stay visible after the EA is removed or a test ends.
   // (To clean up manually, delete the GT_-prefixed objects from the chart.)
   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//| End of test: print MT5's built-in risk stats (for CLI backtests) |
//+------------------------------------------------------------------+
double OnTester()
  {
   double profit   = TesterStatistics(STAT_PROFIT);
   double ddMoney  = TesterStatistics(STAT_EQUITY_DD);        // max equity drawdown (money)
   double ddPct    = TesterStatistics(STAT_EQUITYDD_PERCENT); // max equity drawdown (%)
   double pf       = TesterStatistics(STAT_PROFIT_FACTOR);    // profit factor
   double trades   = TesterStatistics(STAT_TRADES);           // number of trades
   double winRate  = 0.0;
   double won      = TesterStatistics(STAT_PROFIT_TRADES);
   if(trades > 0) winRate = won / trades * 100.0;
   double recovery = TesterStatistics(STAT_RECOVERY_FACTOR);  // recovery factor

   PrintFormat("STATS | NetProfit=%.0f | MaxDD=%.0f (%.1f%%) | PF=%.2f | RF=%.2f | Trades=%.0f | WinRate=%.1f%%",
               profit, ddMoney, ddPct, pf, recovery, trades, winRate);
   return(profit);
  }

//+------------------------------------------------------------------+
//| Draw the upper/center/lower horizontal lines + grid lines        |
//| (all OBJ_HLINE)                                                  |
//|  Note: graphic objects only show in visual-mode tests and on     |
//|  live charts; the non-visual test result chart renders no        |
//|  ObjectCreate objects (MT5 design), so CLI backtests show none.  |
//+------------------------------------------------------------------+
void DrawLines()
  {
   if(!DrawLines_ShowGraphics) return;

   // Grid lines (light gray dots): drawn first in the background layer so bounds/center stay on top
   double grid = g_grid;
   int gi = 0;
   for(double line = g_center + grid; line <= g_upper + grid*0.5 && gi < 200; line += grid)
     { DrawHSeg("GT_g_u" + IntegerToString(gi), line, C'200,200,210', STYLE_DOT, 1, true); gi++; }
   gi = 0;
   for(double line = g_center - grid; line >= g_lower - grid*0.5 && gi < 200; line -= grid)
     { DrawHSeg("GT_g_d" + IntegerToString(gi), line, C'200,200,210', STYLE_DOT, 1, true); gi++; }

   // Upper (red solid) / center (yellow dashed) / lower (green solid): drawn last, in the foreground (BACK=false)
   DrawHSeg("GT_upper",  g_upper,  clrTomato,    STYLE_SOLID, 3, false);
   DrawHSeg("GT_center", g_center, clrYellow,    STYLE_DASH,  1, false);
   DrawHSeg("GT_lower",  g_lower,  clrLimeGreen, STYLE_SOLID, 3, false);

   // Price labels for upper/center/lower
   DrawPriceLabel("GT_upper_lbl",  g_upper,  "Upper " + DoubleToString(g_upper,  g_digits), clrTomato);
   DrawPriceLabel("GT_center_lbl", g_center, "Center " + DoubleToString(g_center, g_digits), clrGold);
   DrawPriceLabel("GT_lower_lbl",  g_lower,  "Lower " + DoubleToString(g_lower,  g_digits), clrLimeGreen);

   // [diagnostic] report object creation (confirms the drawing code ran and the objects exist)
   PrintFormat("DRAWDIAG | objects_total=%d | center=%s find=%d color=%d",
               ObjectsTotal(0, -1, -1),
               (ObjectFind(0,"GT_center")>=0?"exists":"missing"),
               ObjectFind(0,"GT_center"),
               (int)ObjectGetInteger(0,"GT_center",OBJPROP_COLOR));

   // Breakout stop trigger lines (thick yellow)
   DrawBreakoutLines();

   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//| Draw breakout/recovery lines:                                    |
//|  yellow solid thick = breakout stop trigger (bound +/- margin);  |
//|  yellow dashed thin = grid recovery limit (bound -/+ buffer).    |
//|  Margin/buffer always come from the ATR distance and move with   |
//|  volatility; OnTick refreshes them on every new bar (a breakout  |
//|  always closes everything, there is no switch).                  |
//+------------------------------------------------------------------+
void DrawBreakoutLines()
  {
   double margin = BreakoutDist();
   DrawHSeg("GT_brk_up", g_upper + margin, clrYellow, STYLE_SOLID, 3, false);
   DrawHSeg("GT_brk_dn", g_lower - margin, clrYellow, STYLE_SOLID, 3, false);

   double buffer = ClampBuffer(BreakoutDist());
   DrawHSeg("GT_rec_up", g_upper - buffer, clrYellow, STYLE_DASH, 1, false);
   DrawHSeg("GT_rec_dn", g_lower + buffer, clrYellow, STYLE_DASH, 1, false);
  }

//+------------------------------------------------------------------+
//| Draw a horizontal line (OBJ_HLINE) across the whole chart.       |
//|  OBJ_HLINE needs only a price, no time anchor, so it can be      |
//|  created reliably in OnInit and shows in both visual tests and   |
//|  live charts.                                                    |
//+------------------------------------------------------------------+
void DrawHSeg(const string nm, const double price, const color clr,
              const ENUM_LINE_STYLE style, const int width, const bool back)
  {
   if(ObjectFind(0, nm) < 0)
      ObjectCreate(0, nm, OBJ_HLINE, 0, 0, price);
   else
      ObjectMove(0, nm, 0, 0, price);
   ObjectSetInteger(0, nm, OBJPROP_COLOR,      clr);
   ObjectSetInteger(0, nm, OBJPROP_STYLE,      style);
   ObjectSetInteger(0, nm, OBJPROP_WIDTH,      width);
   ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, nm, OBJPROP_BACK,       back);  // grid lines in the background, bounds/center in the foreground
  }

//+------------------------------------------------------------------+
//| Draw a text label at a price showing name + value               |
//| (anchored to the right of the latest bar)                        |
//+------------------------------------------------------------------+
void DrawPriceLabel(const string nm, const double price, const string text, const color clr)
  {
   datetime t = iTime(_Symbol, _Period, 0);   // latest bar time, so the label sits on the right side of the chart
   if(ObjectFind(0, nm) < 0)
      ObjectCreate(0, nm, OBJ_TEXT, 0, t, price);
   else
      ObjectMove(0, nm, 0, t, price);
   ObjectSetString (0, nm, OBJPROP_TEXT,       text);
   ObjectSetInteger(0, nm, OBJPROP_COLOR,      clr);
   ObjectSetInteger(0, nm, OBJPROP_FONTSIZE,   9);
   ObjectSetInteger(0, nm, OBJPROP_ANCHOR,     ANCHOR_LEFT);
   ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, nm, OBJPROP_BACK,       false);
  }

//+------------------------------------------------------------------+
//| Draw a vertical marker at the current bar                        |
//| (breakout stop = blue / trailing stop = yellow).                 |
//|  The name includes the bar time so each event gets its own line. |
//|  back=false puts it in the foreground (not hidden by dense bars);|
//|  width controls the thickness.                                   |
//+------------------------------------------------------------------+
void DrawVLine(const color clr, const int width=1, const bool back=true)
  {
   if(!DrawLines_ShowGraphics) return;
   datetime t = iTime(_Symbol, _Period, 0);   // current bar time
   if(t <= 0) t = TimeCurrent();
   string nm = "GT_v_" + IntegerToString((long)t);
   if(ObjectFind(0, nm) < 0)
      ObjectCreate(0, nm, OBJ_VLINE, 0, t, 0);
   else
      ObjectMove(0, nm, 0, t, 0);
   ObjectSetInteger(0, nm, OBJPROP_COLOR,      clr);
   ObjectSetInteger(0, nm, OBJPROP_STYLE,      STYLE_SOLID);
   ObjectSetInteger(0, nm, OBJPROP_WIDTH,      width);
   ObjectSetInteger(0, nm, OBJPROP_BACK,       back);
   ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
  }

//+------------------------------------------------------------------+
//| Draw a close-result text label at the current bar                |
//| (pips, green if positive, red if negative).                      |
//|  Used with the vertical lines: TP = green, trailing/breakout     |
//|  stop = colored by P/L.                                          |
//|  Multiple closes on the same bar are stacked 0.3 cell upward.    |
//+------------------------------------------------------------------+
void DrawCloseLabel(const string tag, const double value, const double price, const bool inPips = true)
  {
   if(!DrawLines_ShowGraphics) return;
   datetime t = iTime(_Symbol, _Period, 0);
   if(t <= 0) t = TimeCurrent();
   string baseNm = "GT_pips_" + IntegerToString((long)t);
   string nm = baseNm;
   int stack = 0;
   while(ObjectFind(0, nm) >= 0)
     {
      stack++;
      nm = baseNm + "_" + IntegerToString(stack);
     }
   double adjPrice = price + stack * g_grid * 0.3;
   string sign = (value >= 0) ? "+" : "";
   string text = inPips
                 ? StringFormat("%s %s%.0fpips", tag, sign, value)
                 : StringFormat("%s %s%.2f",     tag, sign, value);
   color  clr  = (value >= 0) ? clrLime : clrTomato;
   ObjectCreate(0, nm, OBJ_TEXT, 0, t, adjPrice);
   ObjectSetString (0, nm, OBJPROP_TEXT,       text);
   ObjectSetInteger(0, nm, OBJPROP_COLOR,      clr);
   ObjectSetInteger(0, nm, OBJPROP_FONTSIZE,   9);
   ObjectSetInteger(0, nm, OBJPROP_ANCHOR,     ANCHOR_LEFT_LOWER);
   ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, nm, OBJPROP_BACK,       false);
   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//| One row of the top-left info panel                               |
//| (fixed screen coordinates, does not scroll with price).          |
//+------------------------------------------------------------------+
void InfoLabel(const string nm, const int y, const string text, const color clr)
  {
   if(ObjectFind(0, nm) < 0)
      ObjectCreate(0, nm, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, nm, OBJPROP_CORNER,     CORNER_LEFT_UPPER);
   ObjectSetInteger(0, nm, OBJPROP_XDISTANCE,  10);
   ObjectSetInteger(0, nm, OBJPROP_YDISTANCE,  y);
   ObjectSetString (0, nm, OBJPROP_TEXT,       text);
   ObjectSetInteger(0, nm, OBJPROP_COLOR,      clr);
   ObjectSetInteger(0, nm, OBJPROP_FONTSIZE,   10);
   ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
  }

//+------------------------------------------------------------------+
//| Top-left live P/L panel: total profit (total pips) + order count |
//| for the buy and sell groups.                                     |
//|  profit = green, loss = red, flat = gray.                        |
//+------------------------------------------------------------------+
void DrawInfoPanelTrail()
  {
   if(!DrawLines_ShowGraphics) return;
   string addTxt   = (TrailTotal_AddPerOrder != 0) ? StringFormat("(+%d%%/order, max 90%%)", TrailTotal_AddPerOrder) : "";
   string trailTxt = TrailTotal_Enable
                     ? StringFormat("Trailing stop: ON   start %d / keep %d%%%s", TpThreshold_BasePips, TrailTotal_KeepPct, addTxt)
                     : StringFormat("Trailing stop: OFF   (total TP %d total pips)", TpThreshold_BasePips);
   InfoLabel("GT_info_trail", 56, trailTxt, TrailTotal_Enable ? clrGold : clrSilver);
  }

void DrawInfoPanel()
  {
   if(!DrawLines_ShowGraphics) return;
   int    buyN  = CountSide(POSITION_TYPE_BUY);
   int    sellN = CountSide(POSITION_TYPE_SELL);

   static string prevBuyTxt  = "";  static color prevBuyClr  = clrNONE;
   static string prevSellTxt = "";  static color prevSellClr = clrNONE;
   bool changed = false;

   // Buy row: when flat, write the gray placeholder once, then skip
   string buyTxt;
   color  buyClr;
   if(buyN == 0)
     {
      buyTxt = "Buy -- (0 orders)";
      buyClr = clrGray;
     }
   else
     {
      double buyPips   = TotalPipsByType(POSITION_TYPE_BUY);
      buyTxt = StringFormat("Buy %+.1f total pips (%d orders)", buyPips, buyN);
      if(TrailTotal_Enable)
        {
         int    startB  = TpThreshold();
         double keepB   = EffectiveKeepRatio(buyN);
         bool   armedB  = (g_trailPeakBuy >= startB);
         double targetB = (armedB ? g_trailPeakBuy : startB) * keepB;
         int    pctB    = (int)MathRound(keepB * 100);
         buyTxt += armedB
                   ? StringFormat("  peak %.1f stop %.1f(%d%%) (active)", g_trailPeakBuy, targetB, pctB)
                   : StringFormat("  peak %.1f->start %d stop %.1f(%d%%) (pending)", g_trailPeakBuy, startB, targetB, pctB);
        }
      buyClr = (buyPips >= 0 ? clrLime : clrTomato);
     }
   if(buyTxt != prevBuyTxt || buyClr != prevBuyClr)
     {
      InfoLabel("GT_info_buy", 100, buyTxt, buyClr);
      prevBuyTxt = buyTxt;  prevBuyClr = buyClr;
      changed = true;
     }

   // Sell row: same logic
   string sellTxt;
   color  sellClr;
   if(sellN == 0)
     {
      sellTxt = "Sell -- (0 orders)";
      sellClr = clrGray;
     }
   else
     {
      double sellPips  = TotalPipsByType(POSITION_TYPE_SELL);
      sellTxt = StringFormat("Sell %+.1f total pips (%d orders)", sellPips, sellN);
      if(TrailTotal_Enable)
        {
         int    startS  = TpThreshold();
         double keepS   = EffectiveKeepRatio(sellN);
         bool   armedS  = (g_trailPeakSell >= startS);
         double targetS = (armedS ? g_trailPeakSell : startS) * keepS;
         int    pctS    = (int)MathRound(keepS * 100);
         sellTxt += armedS
                    ? StringFormat("  peak %.1f stop %.1f(%d%%) (active)", g_trailPeakSell, targetS, pctS)
                    : StringFormat("  peak %.1f->start %d stop %.1f(%d%%) (pending)", g_trailPeakSell, startS, targetS, pctS);
        }
      sellClr = (sellPips >= 0 ? clrLime : clrTomato);
     }
   if(sellTxt != prevSellTxt || sellClr != prevSellClr)
     {
      InfoLabel("GT_info_sell", 144, sellTxt, sellClr);
      prevSellTxt = sellTxt;  prevSellClr = sellClr;
      changed = true;
     }

   if(changed) ChartRedraw(0);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   // Spread filter
   if(OnTick_MaxSpread > 0)
     {
      long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      if(spread > OnTick_MaxSpread)
         return;
     }

   double grid = g_grid;

   DrawInfoPanel();   // buy/sell rows: unchanged content skips ObjectSet*, flat sides almost never trigger

   // Price labels are OBJ_TEXT; move them to the current bar on each new bar so they stay on the right (per-tick moves are unnecessary).
   // In OnInit the tester has no valid time yet, so they are refreshed here. Bounds/center/grid lines are OBJ_HLINE and do not move with time.
   static datetime lblBar = 0;
   datetime curBar = iTime(_Symbol, _Period, 0);
   if(DrawLines_ShowGraphics && curBar > 0 && curBar != lblBar)
     {
      lblBar = curBar;
      ObjectMove(0, "GT_upper_lbl",  0, curBar, g_upper);
      ObjectMove(0, "GT_center_lbl", 0, curBar, g_center);
      ObjectMove(0, "GT_lower_lbl",  0, curBar, g_lower);
      // Breakout/recovery lines: the ATR margin/buffer moves with volatility, refresh on every new bar
      double m = BreakoutDist();
      ObjectMove(0, "GT_brk_up", 0, 0, g_upper + m);
      ObjectMove(0, "GT_brk_dn", 0, 0, g_lower - m);
      double b = ClampBuffer(BreakoutDist());
      ObjectMove(0, "GT_rec_up", 0, 0, g_upper - b);
      ObjectMove(0, "GT_rec_dn", 0, 0, g_lower + b);
      ChartRedraw(0);
     }

   // Breakout handling: full close stop; returning true skips TP/entries for this tick
   if(HandleBreakout())
      return;

   // Loss cut on order count: close a side that holds too many orders while in a floating loss
   if(CheckLossCut())
      return;

   // 1) Per-side total take-profit (when the trailing stop is off): close only the group that reached the target; no new entries this tick
   if(!TrailTotal_Enable && TpThreshold_BasePips > 0)
     {
      bool closedAny = false;

      int    buyN    = CountSide(POSITION_TYPE_BUY);
      double buyPips = TotalPipsByType(POSITION_TYPE_BUY);
      if(buyN > 0 && buyPips >= TpThreshold_BasePips)
        {
         PrintFormat("Buy group TP: buy group total profit %.1f total pips >= %d, closing all buys", buyPips, TpThreshold_BasePips);
         DrawCloseLabel("Buy TP", buyPips, SymbolInfoDouble(_Symbol, SYMBOL_BID));
         CloseSide(POSITION_TYPE_BUY);
         closedAny = true;
        }

      int    sellN    = CountSide(POSITION_TYPE_SELL);
      double sellPips = TotalPipsByType(POSITION_TYPE_SELL);
      if(sellN > 0 && sellPips >= TpThreshold_BasePips)
        {
         PrintFormat("Sell group TP: sell group total profit %.1f total pips >= %d, closing all sells", sellPips, TpThreshold_BasePips);
         DrawCloseLabel("Sell TP", sellPips, SymbolInfoDouble(_Symbol, SYMBOL_ASK));
         CloseSide(POSITION_TYPE_SELL);
         closedAny = true;
        }

      if(closedAny) return;   // closed this tick; the side's grid is rebuilt on the next pass
     }

   // 1b) Trailing stop (replaces the total TP when ON): tracks each side's group total and closes the side on pullback
   if(TrailTotal_Enable && TrailTotal())
      return;                       // group closed by trailing stop, no new entries this tick

   // 2) Open grid orders inside the range
   TradeGrid(grid);
  }

//+------------------------------------------------------------------+
//| Floating P/L of a side (account currency):                       |
//| sum(pos.Profit + pos.Swap), this magic only.                     |
//+------------------------------------------------------------------+
double FloatingPnL(const ENUM_POSITION_TYPE type)
  {
   double sum = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!pos.SelectByIndex(i))        continue;
      if(pos.Symbol() != _Symbol)      continue;
      if(pos.Magic()  != CTrade_Magic) continue;
      if(pos.PositionType() != type)   continue;
      sum += pos.Profit() + pos.Swap();
     }
   return(sum);
  }

//+------------------------------------------------------------------+
//| Loss cut on order count: buys and sells checked independently.   |
//|  Side count > LossCut_MinOrders and side floating P/L < 0        |
//|  -> close that side.                                             |
//|  Returns true if anything was closed this tick (no TP/entries).  |
//+------------------------------------------------------------------+
bool CheckLossCut()
  {
   if(LossCut_MinOrders <= 0) return(false);
   bool closed = false;

   int buyN = CountSide(POSITION_TYPE_BUY);
   if(buyN > LossCut_MinOrders)
     {
      double pnl = FloatingPnL(POSITION_TYPE_BUY);
      if(pnl < 0)
        {
         double pipsBuy = TotalPipsByType(POSITION_TYPE_BUY);
         PrintFormat("Loss cut (buy): %d buys > limit %d, floating P/L=%.2f (%.1f total pips), closing buy group",
                     buyN, LossCut_MinOrders, pnl, pipsBuy);
         DrawVLine(clrOrangeRed, 2, false);
         DrawCloseLabel("Buy LossCut", pipsBuy, SymbolInfoDouble(_Symbol, SYMBOL_BID));
         CloseSide(POSITION_TYPE_BUY);
         closed = true;
        }
     }

   int sellN = CountSide(POSITION_TYPE_SELL);
   if(sellN > LossCut_MinOrders)
     {
      double pnl = FloatingPnL(POSITION_TYPE_SELL);
      if(pnl < 0)
        {
         double pipsSell = TotalPipsByType(POSITION_TYPE_SELL);
         PrintFormat("Loss cut (sell): %d sells > limit %d, floating P/L=%.2f (%.1f total pips), closing sell group",
                     sellN, LossCut_MinOrders, pnl, pipsSell);
         DrawVLine(clrOrangeRed, 2, false);
         DrawCloseLabel("Sell LossCut", pipsSell, SymbolInfoDouble(_Symbol, SYMBOL_ASK));
         CloseSide(POSITION_TYPE_SELL);
         closed = true;
        }
     }

   return(closed);
  }

//+------------------------------------------------------------------+
//| Breakout distance: BreakoutDist_AtrMult x current ATR, as price. |
//|  Returns 0 if ATR is unavailable or the multiple is <= 0         |
//|  (touching the bound triggers immediately).                      |
//+------------------------------------------------------------------+
double BreakoutDist()
  {
   if(BreakoutDist_AtrMult <= 0) return(0.0);
   if(g_boAtrHandle == INVALID_HANDLE) return(0.0);
   // ATR is read once per bar and cached, avoiding a per-tick CopyBuffer that slows backtests
   static datetime s_atrBar  = 0;
   static double   s_atrLast = 0.0;
   datetime curBar = iTime(_Symbol, _Period, 0);
   if(curBar > 0 && curBar != s_atrBar)
     {
      s_atrBar = curBar;
      double atr[];
      if(CopyBuffer(g_boAtrHandle, 0, 1, 1, atr) >= 1 && atr[0] > 0)
         s_atrLast = atr[0];
     }
   return(BreakoutDist_AtrMult * s_atrLast);
  }

//+------------------------------------------------------------------+
//| Clamp the recovery buffer: at most 40% of the range width        |
//| (so the upper/lower buffers never overlap), never below 0.       |
//|  Shared by the recovery lines and the recovery check, so the     |
//|  drawn line always matches the value actually used.              |
//+------------------------------------------------------------------+
double ClampBuffer(double buffer)
  {
   double maxBuf = (g_upper - g_lower) * 0.4;
   if(buffer > maxBuf) buffer = maxBuf;
   if(buffer < 0)      buffer = 0;
   return(buffer);
  }

//+------------------------------------------------------------------+
//| Breakout check: the current tick's bid/ask beyond                |
//| "bound +/- margin" counts as out of range.                       |
//|  Checked every tick, triggers on touch (long wicks may trigger). |
//+------------------------------------------------------------------+
bool IsOutOfRange()
  {
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double margin = BreakoutDist();
   return(bid > g_upper + margin || ask < g_lower - margin);
  }

//+------------------------------------------------------------------+
//| Breakout handling (always a full close stop):                    |
//|  checks the current bid/ask every tick; touching the bound       |
//|  closes everything immediately (wicks included).                 |
//|  Recovery uses a "buffer inside the bound" hysteresis band to    |
//|  avoid flip-flopping between recover and stop near the edge.     |
//|  Returns: true = paused out of range; false = in range (normal). |
//+------------------------------------------------------------------+
bool HandleBreakout()
  {
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double buffer = ClampBuffer(BreakoutDist());
   bool   out    = IsOutOfRange();
   bool   backInside = (bid <= g_upper - buffer && ask >= g_lower + buffer);

   if(out && !g_outOfRange)
     {
      double brkBuyPips  = TotalPipsByType(POSITION_TYPE_BUY);
      double brkSellPips = TotalPipsByType(POSITION_TYPE_SELL);
      double brkTotal    = brkBuyPips + brkSellPips;
      g_outOfRange = true;
      PrintFormat("Out of range, closing all: bid=%.*f is outside [%.*f, %.*f]",
                  g_digits, bid, g_digits, g_lower, g_digits, g_upper);
      DrawVLine(clrDodgerBlue);
      DrawCloseLabel("Breakout SL", brkTotal, bid);
     }
   else if(backInside && g_outOfRange)
     {
      g_outOfRange = false;
      PrintFormat("Back inside the range (buffer %.1f x ATR), resuming trading: bid=%.*f",
                  BreakoutDist_AtrMult, g_digits, bid);
     }

   if(g_outOfRange)
     {
      CloseAll();
      return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Bi-directional grid entries inside the range:                    |
//| upper half (center~upper) sells, lower half (lower~center) buys. |
//| The center line itself never trades; lines start at center +/- 1.|
//+------------------------------------------------------------------+
void TradeGrid(const double grid)
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double tol     = grid * 0.25;  // touch window: price within +/- 1/4 cell of a grid line counts as a "touch"
   double release = grid * 0.75;  // release threshold: price must move 3/4 cell away from the last order line to re-arm
                                  // (release > touch window leaves a buffer so jitter near a line cannot re-enter repeatedly)

   // Price has really left the last order line -> clear that side's cooldown (re-arm)
   if(g_lastSellLine != 0.0 && MathAbs(bid - g_lastSellLine) > release) g_lastSellLine = 0.0;
   if(g_lastBuyLine  != 0.0 && MathAbs(ask - g_lastBuyLine)  > release) g_lastBuyLine  = 0.0;

   // Entry-side range check: confirm the current bid/ask is inside the range so no order opens outside a bound.
   // (Breakout full close is handled independently by HandleBreakout every tick; this is only a pre-entry range check.)
   bool buyInRange  = (ask >= g_lower && ask <= g_upper);   // buying requires the current price inside the range
   bool sellInRange = (bid >= g_lower && bid <= g_upper);   // selling requires the current price inside the range

   int sellN = CountSide(POSITION_TYPE_SELL);
   int buyN  = CountSide(POSITION_TYPE_BUY);

   // First order must touch the bare bound (when flat): touching upper arms sells, touching lower arms buys;
   // flat and price more than release away from the bound -> disarm. Adding to an open side is not restricted;
   // TradeGrid_FirstAtEdge=false treats both sides as always armed.
   if(bid >= g_upper - tol) g_sellArmed = true;
   if(ask <= g_lower + tol) g_buyArmed  = true;
   if(sellN == 0 && bid < g_upper - release) g_sellArmed = false;
   if(buyN  == 0 && ask > g_lower + release) g_buyArmed  = false;
   bool sellAllowed = (!TradeGrid_FirstAtEdge || sellN > 0 || g_sellArmed);
   bool buyAllowed  = (!TradeGrid_FirstAtEdge || buyN  > 0 || g_buyArmed);

   //--- Upper half: one grid line per cell from center+1 cell up to the upper bound -> sell ---
   if(TradeGrid_EnableSell && sellAllowed && sellInRange && g_lastSellLine == 0.0)
     {
      for(int k = 1; ; k++)
        {
         double line = g_center + k * grid;
         if(line > g_upper + tol) break;
         // Price "touches" this grid line and no sell is near it yet -> sell and lock this line
         if(MathAbs(bid - line) <= tol && !HasOrderNear(POSITION_TYPE_SELL, line, grid))
           {
            OpenOrder(POSITION_TYPE_SELL, k, LotForLine(POSITION_TYPE_SELL, line, grid));
            g_lastSellLine = line;   // lock: no new sell until price moves 3/4 cell away from this line
            break;
           }
        }
     }

   //--- Lower half: one grid line per cell from center-1 cell down to the lower bound -> buy ---
   if(TradeGrid_EnableBuy && buyAllowed && buyInRange && g_lastBuyLine == 0.0)
     {
      for(int k = 1; ; k++)
        {
         double line = g_center - k * grid;
         if(line < g_lower - tol) break;
         // Price "touches" this grid line and no buy is near it yet -> buy and lock this line
         if(MathAbs(ask - line) <= tol && !HasOrderNear(POSITION_TYPE_BUY, line, grid))
           {
            OpenOrder(POSITION_TYPE_BUY, k, LotForLine(POSITION_TYPE_BUY, line, grid));
            g_lastBuyLine = line;   // lock: no new buy until price moves 3/4 cell away from this line
            break;
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| "Total profit pips" of a side's positions                        |
//| (lot-weighted sum, normalized to the min lot).                   |
//|  sum(pips x lots) / LotForLine_MinLots: each order's pips are    |
//|  weighted by its lots and summed, then divided by the min lot to |
//|  express it in "min-lot pips" -> values stay in pips magnitude;  |
//|  with all orders at the min lot it is exactly the plain sum of   |
//|  pips. Proportional to the real money P/L; with laddered lots    |
//|  the large orders at the bound weigh more. Price only, no fees.  |
//+------------------------------------------------------------------+
double TotalPipsByType(const ENUM_POSITION_TYPE type)
  {
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sum = 0.0;   // sum(pips x lots)
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!pos.SelectByIndex(i))      continue;
      if(pos.Symbol() != _Symbol)    continue;
      if(pos.Magic()  != CTrade_Magic)   continue;
      if(pos.PositionType() != type) continue;
      double open = pos.PriceOpen();
      double pips = (type == POSITION_TYPE_BUY) ? (bid - open) / g_pip
                                                : (open - ask) / g_pip;
      sum += pips * pos.Volume();
     }
   return(LotForLine_MinLots > 0.0 ? sum / LotForLine_MinLots : 0.0);
  }

//+------------------------------------------------------------------+
//| Whether this side already has a position near a price (+/- half) |
//+------------------------------------------------------------------+
bool HasOrderNear(const ENUM_POSITION_TYPE type, const double line, const double grid)
  {
   double tol = grid * 0.5;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!pos.SelectByIndex(i))          continue;
      if(pos.Symbol() != _Symbol)        continue;
      if(pos.Magic()  != CTrade_Magic)       continue;
      if(pos.PositionType() != type)     continue;

      if(MathAbs(pos.PriceOpen() - line) < tol)
         return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Count positions on one side                                      |
//+------------------------------------------------------------------+
int CountSide(const ENUM_POSITION_TYPE type)
  {
   int c = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!pos.SelectByIndex(i))          continue;
      if(pos.Symbol() != _Symbol)        continue;
      if(pos.Magic()  != CTrade_Magic)       continue;
      if(pos.PositionType() != type)     continue;
      c++;
     }
   return(c);
  }

//+------------------------------------------------------------------+
//| Laddered lots: the line closest to the bound uses InitLots,      |
//|  each line toward the center subtracts ReduceLots,               |
//|  never below MinLots. Returns normalized lots.                   |
//+------------------------------------------------------------------+
double LotForLine(const ENUM_POSITION_TYPE type, const double line, const double grid)
  {
   int distEdge = (type == POSITION_TYPE_SELL)
                  ? (int)MathRound((g_upper - line) / grid)    // upper half: cells from the upper bound
                  : (int)MathRound((line - g_lower) / grid);   // lower half: cells from the lower bound
   if(distEdge < 0) distEdge = 0;
   double lots = LotForLine_InitLots - distEdge * LotForLine_ReducePerLine;
   if(lots < LotForLine_MinLots) lots = LotForLine_MinLots;
   return(NormalizeLots(lots));
  }

//+------------------------------------------------------------------+
//| Open one order (comment carries the grid number; lots are        |
//| computed by the caller from the ladder; no TP is attached)       |
//+------------------------------------------------------------------+
void OpenOrder(const ENUM_POSITION_TYPE type, const int gridNo, const double lots)
  {
   if(lots <= 0) return;

   // Comment records which grid line the order was opened on (cells from the center), e.g. "Grid Sell #3" / "Grid Buy #2"
   string cmt = StringFormat("Grid %s #%d", (type==POSITION_TYPE_BUY ? "Buy" : "Sell"), gridNo);

   // No per-order TP (per-order TP was removed); exits come from the per-side total TP / trailing stop / breakout handling
   bool ok = (type == POSITION_TYPE_BUY)
             ? trade.Buy (lots, _Symbol, 0.0, 0.0, 0.0, cmt)
             : trade.Sell(lots, _Symbol, 0.0, 0.0, 0.0, cmt);

   if(!ok)
      PrintFormat("Open failed %s lots=%.2f retcode=%d err=%d",
                  cmt, lots, trade.ResultRetcode(), GetLastError());
  }

//+------------------------------------------------------------------+
//| Close a given position                                           |
//+------------------------------------------------------------------+
void ClosePosition(const ulong ticket)
  {
   if(!trade.PositionClose(ticket))
      PrintFormat("Close failed ticket=%I64u retcode=%d err=%d",
                  ticket, trade.ResultRetcode(), GetLastError());
  }

//+------------------------------------------------------------------+
//| Trailing stop activation threshold (total pips):                 |
//| fixed, equal to the base value.                                  |
//+------------------------------------------------------------------+
int TpThreshold()
  {
   return(TpThreshold_BasePips);
  }

//+------------------------------------------------------------------+
//| Effective keep ratio: tightens with the order count, max 90%.    |
//| keepPct + (n-1) x TrailTotal_AddPerOrder, clamped to [keepPct,90].|
//+------------------------------------------------------------------+
double EffectiveKeepRatio(int n)
  {
   if(n < 1) n = 1;
   int pct = TrailTotal_KeepPct + (n - 1) * TrailTotal_AddPerOrder;
   if(pct > 90) pct = 90;
   return(pct / 100.0);
  }

//+------------------------------------------------------------------+
//| Total trailing stop: once a side's total profit reaches the      |
//|  threshold its peak is tracked; a pullback to peak x keep ratio  |
//|  closes the group. The threshold is fixed (TpThreshold); the keep|
//|  ratio tightens with the order count. Returns true if closed.    |
//+------------------------------------------------------------------+
bool TrailTotal()
  {
   bool closed = false;
   int  startPips = TpThreshold();   // activation threshold is fixed = TpThreshold_BasePips

   // Buy group
   int buyN = CountSide(POSITION_TYPE_BUY);
   if(buyN > 0)
     {
      double keepRatio = EffectiveKeepRatio(buyN);   // more orders = tighter keep %, max 90%
      double p = TotalPipsByType(POSITION_TYPE_BUY);
      if(p > g_trailPeakBuy) g_trailPeakBuy = p;
      if(g_trailPeakBuy >= startPips && p <= g_trailPeakBuy * keepRatio)
        {
         int effPct = (int)MathRound(keepRatio * 100);
         PrintFormat("Buy group trailing stop: peak %.1f -> pulled back to %.1f total pips (%d%% of peak, %d orders), closing all buys",
                     g_trailPeakBuy, p, effPct, buyN);
         CloseSide(POSITION_TYPE_BUY);
         DrawVLine(p >= startPips ? clrLime : clrYellow, 2, false);
         DrawCloseLabel("Buy Trail", p, SymbolInfoDouble(_Symbol, SYMBOL_BID));
         g_trailPeakBuy = 0.0;
         closed = true;
        }
     }
   else g_trailPeakBuy = 0.0;

   // Sell group
   int sellN = CountSide(POSITION_TYPE_SELL);
   if(sellN > 0)
     {
      double keepRatio = EffectiveKeepRatio(sellN);
      double p = TotalPipsByType(POSITION_TYPE_SELL);
      if(p > g_trailPeakSell) g_trailPeakSell = p;
      if(g_trailPeakSell >= startPips && p <= g_trailPeakSell * keepRatio)
        {
         int effPct = (int)MathRound(keepRatio * 100);
         PrintFormat("Sell group trailing stop: peak %.1f -> pulled back to %.1f total pips (%d%% of peak, %d orders), closing all sells",
                     g_trailPeakSell, p, effPct, sellN);
         CloseSide(POSITION_TYPE_SELL);
         DrawVLine(p >= startPips ? clrLime : clrYellow, 2, false);
         DrawCloseLabel("Sell Trail", p, SymbolInfoDouble(_Symbol, SYMBOL_ASK));
         g_trailPeakSell = 0.0;
         closed = true;
        }
     }
   else g_trailPeakSell = 0.0;

   return(closed);
  }

//+------------------------------------------------------------------+
//| Close every position of one side (buy/sell) for this symbol+magic|
//+------------------------------------------------------------------+
void CloseSide(const ENUM_POSITION_TYPE type)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!pos.SelectByIndex(i))      continue;
      if(pos.Symbol() != _Symbol)    continue;
      if(pos.Magic()  != CTrade_Magic)   continue;
      if(pos.PositionType() != type) continue;

      ClosePosition(pos.Ticket());
     }
  }

//+------------------------------------------------------------------+
//| Close every position for this symbol+magic                       |
//+------------------------------------------------------------------+
void CloseAll()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!pos.SelectByIndex(i))          continue;
      if(pos.Symbol() != _Symbol)        continue;
      if(pos.Magic()  != CTrade_Magic)       continue;

      ClosePosition(pos.Ticket());
     }
  }

//+------------------------------------------------------------------+
//| Normalize lot size                                               |
//+------------------------------------------------------------------+
double NormalizeLots(double lots)
  {
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(lotStep > 0)
      lots = MathFloor(lots / lotStep) * lotStep;

   lots = MathMax(minLot, MathMin(maxLot, lots));
   return(NormalizeDouble(lots, 2));
  }
//+------------------------------------------------------------------+
