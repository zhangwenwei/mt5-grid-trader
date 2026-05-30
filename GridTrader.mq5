//+------------------------------------------------------------------+
//|                                                   GridTrader.mq5  |
//|              区间双向网格 EA - 上半做空 / 下半做多 / 超界平仓     |
//|                                                                  |
//|  逻辑: 直接填上下边界, 中线=(上界+下界)/2;                        |
//|        中线~上界 价格触线做空, 下界~中线 价格触线做多;            |
//|        每单往中线方向走一个网格止盈;                             |
//|        上一根收盘 K 线 close 超出上/下边界 -> 全平并暂停,         |
//|        close 回到区间内自动恢复交易; 中线本身不开单。            |
//|                                                                  |
//|  风险提示: 区间网格在单边突破时会在边界被止损式全平,             |
//|  区间内同向可累积多单, 请控制手数与单数, 先模拟回测。            |
//+------------------------------------------------------------------+
#property copyright "GridTrader"
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//--- 输入参数 -------------------------------------------------------
input group           "=== 方向开关 ==="
input bool     InpEnableBuy        = true;      // 允许下半做多
input bool     InpEnableSell       = true;      // 允许上半做空

input group           "=== 网格区间 ==="
// 上下界填 0 = 启动时按所选算法自动计算; 填具体价格 = 手动覆盖。
// 仅 OnInit 算一次, 之后固定。
input double   InpUpperPrice       = 0.0;       // 网格上边界价 (0=自动)
input double   InpLowerPrice       = 0.0;       // 网格下边界价 (0=自动)

enum ENUM_BOUNDS_MODE
  {
   BOUNDS_DONCHIAN_HL = 0,   // 唐奇安: 近N根 最高/最低 (含影线)
   BOUNDS_DONCHIAN_CLOSE,    // 唐奇安: 近N根 收盘价最高/最低 (去插针)
   BOUNDS_ATR                // 中线(近N根均价) ± k×ATR
  };
input ENUM_BOUNDS_MODE InpBoundsMode = BOUNDS_DONCHIAN_HL; // [手段1] 自动定界算法
input int      InpAutoLookback     = 100;       // 自动: 回看 K 线根数
input int      InpATRPeriod        = 14;        // 自动(ATR模式): ATR 周期
input double   InpATRMult          = 10.0;      // 自动(ATR模式): k 倍数
input double   InpBoundsShrinkPct  = 0.0;       // [手段2] 边界向内收缩百分比(0~40, 0=不收缩)

input group           "=== 网格设置 ==="
input double   InpGridSizePips     = 20.0;      // 网格间距 (pips)
input double   InpTakeProfitPips   = 20.0;      // 单笔止盈 (pips, 一般=网格间距)
input double   InpLots             = 0.01;      // 每单手数
input int      InpMaxOrdersPerSide = 10;        // 每方向最大单数 (刹车)

input group           "=== 超界行为 [手段4] ==="
enum ENUM_BREAKOUT_MODE
  {
   BREAKOUT_CLOSE_ALL = 0,   // 超界全平并暂停 (原行为)
   BREAKOUT_PAUSE_ONLY       // 超界只暂停开新单, 不平已有单(让其自行止盈)
  };
input ENUM_BREAKOUT_MODE InpBreakoutMode = BREAKOUT_CLOSE_ALL; // 超界处理方式

input group           "=== 全局熔断 [手段3] (账户货币, 0=关闭) ==="
input double   InpGlobalTP         = 0.0;       // 总浮盈达此值 -> 全平 (0=关闭)
input double   InpGlobalSL         = 0.0;       // 总浮亏达此值 -> 全平停机 (0=关闭)

input group           "=== 过滤与风控 ==="
input double   InpMaxSpreadPoints  = 0;         // 最大点差(points), <=0 不限制
input long     InpMagic            = 20240601;  // 魔术号
input ulong    InpSlippagePoints   = 30;        // 允许滑点(points)

//--- 全局对象 -------------------------------------------------------
CTrade        trade;
CPositionInfo pos;

double g_pip    = 0.0;
double g_point  = 0.0;
int    g_digits = 0;
double g_center = 0.0;   // 中线 = (上界+下界)/2
double g_upper  = 0.0;   // 网格上边界
double g_lower  = 0.0;   // 网格下边界

// 冷却: 记录某方向最后一次开单的网格线价格。
// 价格必须真正离开该线(超过半格)后, 才允许在该线重新开单,
// 防止止盈后立刻重挂、以及大幅跳格时反复开单。
// 0 表示无记录(已武装, 可开单)。
double g_lastBuyLine  = 0.0;
double g_lastSellLine = 0.0;

int    g_atrHandle = INVALID_HANDLE; // ATR 模式用
bool   g_halted    = false;          // 全局止损熔断后停机

//+------------------------------------------------------------------+
int OnInit()
  {
   g_point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   g_pip    = (g_digits == 3 || g_digits == 5) ? 10 * g_point : g_point;

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   if(InpLots <= 0 || InpGridSizePips <= 0 || InpMaxOrdersPerSide <= 0)
     {
      Print("参数非法: 手数/网格间距/最大单数必须大于0");
      return(INIT_PARAMETERS_INCORRECT);
     }

   // ATR 模式需要时创建指标句柄
   bool needAuto = (InpUpperPrice <= 0 || InpLowerPrice <= 0);
   if(needAuto && InpBoundsMode == BOUNDS_ATR)
     {
      g_atrHandle = iATR(_Symbol, _Period, InpATRPeriod);
      if(g_atrHandle == INVALID_HANDLE)
        {
         Print("创建 ATR 句柄失败");
         return(INIT_FAILED);
        }
     }

   // 解析上下边界(手动填值优先, 填 0 则按所选算法自动计算)
   if(!ResolveBounds(g_upper, g_lower))
      return(INIT_PARAMETERS_INCORRECT);

   g_center = (g_upper + g_lower) / 2.0;

   DrawLines();

   PrintFormat("GridTrader v2 启动. 上界=%.5f 中线=%.5f 下界=%.5f grid=%.5f (%s)",
               g_upper, g_center, g_lower, InpGridSizePips * g_pip,
               (InpUpperPrice<=0 || InpLowerPrice<=0) ? "含自动边界" : "手动边界");
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   ObjectDelete(0, "GT_upper");
   ObjectDelete(0, "GT_center");
   ObjectDelete(0, "GT_lower");
   if(g_atrHandle != INVALID_HANDLE)
      IndicatorRelease(g_atrHandle);
   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//| 解析上下边界: 手动填值优先, 填 0 则按 InpBoundsMode 自动计算。   |
//| 自动算出后, 按 InpBoundsShrinkPct 向内收缩(手段2)。            |
//| 返回 false 表示参数非法/计算失败。                              |
//+------------------------------------------------------------------+
bool ResolveBounds(double &upper, double &lower)
  {
   bool autoUpper = (InpUpperPrice <= 0);
   bool autoLower = (InpLowerPrice <= 0);

   double autoHi = 0.0, autoLo = 0.0;
   if(autoUpper || autoLower)
     {
      if(!CalcAutoBounds(autoHi, autoLo))
         return(false);
     }

   upper = autoUpper ? autoHi : InpUpperPrice;
   lower = autoLower ? autoLo : InpLowerPrice;

   if(upper <= lower)
     {
      PrintFormat("参数非法: 上界(%.5f) 必须大于 下界(%.5f)", upper, lower);
      return(false);
     }

   // [手段2] 向内收缩: 把区间两端各往中间收 shrinkPct/2, 避免贴极值开单
   double shrink = MathMax(0.0, MathMin(40.0, InpBoundsShrinkPct));
   if(shrink > 0.0)
     {
      double mid  = (upper + lower) / 2.0;
      double half = (upper - lower) / 2.0 * (1.0 - shrink / 100.0);
      upper = mid + half;
      lower = mid - half;
     }
   return(true);
  }

//+------------------------------------------------------------------+
//| 按所选算法计算自动上下界(未收缩)。                              |
//+------------------------------------------------------------------+
bool CalcAutoBounds(double &hi, double &lo)
  {
   if(InpAutoLookback <= 0)
     {
      Print("参数非法: InpAutoLookback 必须大于 0");
      return(false);
     }

   if(InpBoundsMode == BOUNDS_ATR)
     {
      // 中线 = 近 N 根收盘均价; 半宽 = k×ATR
      double atr[];
      if(CopyBuffer(g_atrHandle, 0, 1, 1, atr) < 1 || atr[0] <= 0)
        {
         Print("自动计算边界失败: ATR 读取失败(历史不足?)");
         return(false);
        }
      double sum = 0.0;
      for(int s = 1; s <= InpAutoLookback; s++)
         sum += iClose(_Symbol, _Period, s);
      double mid  = sum / InpAutoLookback;
      double half = InpATRMult * atr[0];
      hi = mid + half;
      lo = mid - half;
      return(true);
     }

   // 唐奇安: high/low 或 收盘价
   ENUM_SERIESMODE hiMode = (InpBoundsMode == BOUNDS_DONCHIAN_CLOSE) ? MODE_CLOSE : MODE_HIGH;
   ENUM_SERIESMODE loMode = (InpBoundsMode == BOUNDS_DONCHIAN_CLOSE) ? MODE_CLOSE : MODE_LOW;

   int hiIdx = iHighest(_Symbol, _Period, hiMode, InpAutoLookback, 1);
   int loIdx = iLowest (_Symbol, _Period, loMode, InpAutoLookback, 1);
   if(hiIdx < 0 || loIdx < 0)
     {
      Print("自动计算边界失败: 历史 K 线不足, 请增大历史数据或减小回看根数");
      return(false);
     }

   if(InpBoundsMode == BOUNDS_DONCHIAN_CLOSE)
     {
      hi = iClose(_Symbol, _Period, hiIdx);
      lo = iClose(_Symbol, _Period, loIdx);
     }
   else
     {
      hi = iHigh(_Symbol, _Period, hiIdx);
      lo = iLow (_Symbol, _Period, loIdx);
     }

   if(hi <= 0 || lo <= 0)
     {
      Print("自动计算边界失败: 取到无效高低价");
      return(false);
     }
   return(true);
  }

//+------------------------------------------------------------------+
//| 画上界/中线/下界三条水平线                                       |
//+------------------------------------------------------------------+
void DrawLines()
  {
   // 上界 (红色)
   ObjectCreate(0, "GT_upper", OBJ_HLINE, 0, 0, g_upper);
   ObjectSetInteger(0, "GT_upper", OBJPROP_COLOR,     clrTomato);
   ObjectSetInteger(0, "GT_upper", OBJPROP_STYLE,     STYLE_DASH);
   ObjectSetInteger(0, "GT_upper", OBJPROP_WIDTH,     1);
   ObjectSetInteger(0, "GT_upper", OBJPROP_SELECTABLE, false);
   ObjectSetString (0, "GT_upper", OBJPROP_TEXT,      "上界");

   // 中线 (黄色实线)
   ObjectCreate(0, "GT_center", OBJ_HLINE, 0, 0, g_center);
   ObjectSetInteger(0, "GT_center", OBJPROP_COLOR,     clrGold);
   ObjectSetInteger(0, "GT_center", OBJPROP_STYLE,     STYLE_SOLID);
   ObjectSetInteger(0, "GT_center", OBJPROP_WIDTH,     2);
   ObjectSetInteger(0, "GT_center", OBJPROP_SELECTABLE, false);
   ObjectSetString (0, "GT_center", OBJPROP_TEXT,      "中线");

   // 下界 (绿色)
   ObjectCreate(0, "GT_lower", OBJ_HLINE, 0, 0, g_lower);
   ObjectSetInteger(0, "GT_lower", OBJPROP_COLOR,     clrLimeGreen);
   ObjectSetInteger(0, "GT_lower", OBJPROP_STYLE,     STYLE_DASH);
   ObjectSetInteger(0, "GT_lower", OBJPROP_WIDTH,     1);
   ObjectSetInteger(0, "GT_lower", OBJPROP_SELECTABLE, false);
   ObjectSetString (0, "GT_lower", OBJPROP_TEXT,      "下界");

   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   // 全局止损熔断后: 永久停机(已在触发时全平), 不再交易
   if(g_halted)
      return;

   // 点差过滤
   if(InpMaxSpreadPoints > 0)
     {
      long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      if(spread > InpMaxSpreadPoints)
         return;
     }

   double grid = InpGridSizePips * g_pip;

   // 1) 单笔止盈检查(始终执行)
   ManageTakeProfit();

   // 2) [手段3] 全局熔断: 总浮盈/浮亏触线 -> 全平
   double pnl = TotalFloatingPnL();
   if(InpGlobalTP > 0 && pnl >= InpGlobalTP)
     {
      PrintFormat("全局止盈触发: 浮盈 %.2f >= %.2f, 全平", pnl, InpGlobalTP);
      CloseAll();
      return;
     }
   if(InpGlobalSL > 0 && pnl <= -InpGlobalSL)
     {
      PrintFormat("全局止损触发: 浮亏 %.2f <= -%.2f, 全平停机", pnl, InpGlobalSL);
      CloseAll();
      g_halted = true;   // 止损熔断后停机, 不再开单
      return;
     }

   // 3) 超界判断: 用上一根已收盘 K 线的 close
   double close1 = iClose(_Symbol, _Period, 1);
   bool   outOfRange = (close1 > 0 && (close1 > g_upper || close1 < g_lower));
   if(outOfRange)
     {
      // [手段4] 超界行为
      if(InpBreakoutMode == BREAKOUT_CLOSE_ALL)
         CloseAll();      // 全平
      return;             // 两种模式都暂停开新单; close 回区间后自动恢复
     }

   // 4) 区间内开网格单
   TradeGrid(grid);
  }

//+------------------------------------------------------------------+
//| 本 symbol+magic 所有持仓的总浮动盈亏(含库存费/手续费)          |
//+------------------------------------------------------------------+
double TotalFloatingPnL()
  {
   double total = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!pos.SelectByIndex(i))    continue;
      if(pos.Symbol() != _Symbol)  continue;
      if(pos.Magic()  != InpMagic) continue;
      total += pos.Profit() + pos.Swap() + pos.Commission();
     }
   return(total);
  }

//+------------------------------------------------------------------+
//| 区间内双向网格开单: 上半(中线~上界)做空, 下半(下界~中线)做多     |
//| 中线本身不开单, 从中线±一格开始。                               |
//+------------------------------------------------------------------+
void TradeGrid(const double grid)
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double tol     = grid * 0.25;  // 触碰窗: 价格进入网格线 ±1/4 格才算"触碰"
   double release = grid * 0.75;  // 解锁门槛: 价格离开上次开单线 3/4 格才重新武装
                                  // (解锁门槛 > 触碰窗, 留出缓冲, 防止边界抖动反复重入)

   // 价格真正离开上次开单的线 -> 解除该方向冷却(重新武装)
   if(g_lastSellLine != 0.0 && MathAbs(bid - g_lastSellLine) > release) g_lastSellLine = 0.0;
   if(g_lastBuyLine  != 0.0 && MathAbs(ask - g_lastBuyLine)  > release) g_lastBuyLine  = 0.0;

   //--- 上半区: 从中线+一格向上每隔一格一条网格线, 到上界 -> 做空 ---
   if(InpEnableSell && g_lastSellLine == 0.0 && CountSide(POSITION_TYPE_SELL) < InpMaxOrdersPerSide)
     {
      for(int k = 1; ; k++)
        {
         double line = g_center + k * grid;
         if(line > g_upper + tol) break;
         // 价格"触碰"该网格线, 且该线附近还没有空单 -> 挂空, 并对该线上锁
         if(MathAbs(bid - line) <= tol && !HasOrderNear(POSITION_TYPE_SELL, line, grid))
           {
            OpenOrder(POSITION_TYPE_SELL);
            g_lastSellLine = line;   // 上锁: 价格离开该线半格前不再开空
            break;
           }
        }
     }

   //--- 下半区: 从中线-一格向下每隔一格一条网格线, 到下界 -> 做多 ---
   if(InpEnableBuy && g_lastBuyLine == 0.0 && CountSide(POSITION_TYPE_BUY) < InpMaxOrdersPerSide)
     {
      for(int k = 1; ; k++)
        {
         double line = g_center - k * grid;
         if(line < g_lower - tol) break;
         // 价格"触碰"该网格线, 且该线附近还没有多单 -> 挂多, 并对该线上锁
         if(MathAbs(ask - line) <= tol && !HasOrderNear(POSITION_TYPE_BUY, line, grid))
           {
            OpenOrder(POSITION_TYPE_BUY);
            g_lastBuyLine = line;   // 上锁: 价格离开该线半格前不再开多
            break;
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| 单笔止盈: 每单往中线方向走一个网格平仓                           |
//+------------------------------------------------------------------+
void ManageTakeProfit()
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double tp  = InpTakeProfitPips * g_pip;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!pos.SelectByIndex(i))      continue;
      if(pos.Symbol() != _Symbol)    continue;
      if(pos.Magic()  != InpMagic)   continue;

      double openP = pos.PriceOpen();

      if(pos.PositionType() == POSITION_TYPE_BUY)
        {
         if(bid >= openP + tp)
            ClosePosition(pos.Ticket());
        }
      else // SELL
        {
         if(ask <= openP - tp)
            ClosePosition(pos.Ticket());
        }
     }
  }

//+------------------------------------------------------------------+
//| 该方向在某价格附近(±半格)是否已有持仓                            |
//+------------------------------------------------------------------+
bool HasOrderNear(const ENUM_POSITION_TYPE type, const double line, const double grid)
  {
   double tol = grid * 0.5;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!pos.SelectByIndex(i))          continue;
      if(pos.Symbol() != _Symbol)        continue;
      if(pos.Magic()  != InpMagic)       continue;
      if(pos.PositionType() != type)     continue;

      if(MathAbs(pos.PriceOpen() - line) < tol)
         return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| 统计某方向持仓数量                                               |
//+------------------------------------------------------------------+
int CountSide(const ENUM_POSITION_TYPE type)
  {
   int c = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!pos.SelectByIndex(i))          continue;
      if(pos.Symbol() != _Symbol)        continue;
      if(pos.Magic()  != InpMagic)       continue;
      if(pos.PositionType() != type)     continue;
      c++;
     }
   return(c);
  }

//+------------------------------------------------------------------+
//| 开一单                                                           |
//+------------------------------------------------------------------+
void OpenOrder(const ENUM_POSITION_TYPE type)
  {
   double lots = NormalizeLots(InpLots);
   if(lots <= 0) return;

   bool ok = (type == POSITION_TYPE_BUY)
             ? trade.Buy (lots, _Symbol, 0.0, 0.0, 0.0, "Grid Buy")
             : trade.Sell(lots, _Symbol, 0.0, 0.0, 0.0, "Grid Sell");

   if(!ok)
      PrintFormat("开仓失败 type=%s retcode=%d err=%d",
                  (type==POSITION_TYPE_BUY?"BUY":"SELL"),
                  trade.ResultRetcode(), GetLastError());
  }

//+------------------------------------------------------------------+
//| 平指定单                                                         |
//+------------------------------------------------------------------+
void ClosePosition(const ulong ticket)
  {
   if(!trade.PositionClose(ticket))
      PrintFormat("平仓失败 ticket=%I64u retcode=%d err=%d",
                  ticket, trade.ResultRetcode(), GetLastError());
  }

//+------------------------------------------------------------------+
//| 平掉本 symbol+magic 的所有持仓                                   |
//+------------------------------------------------------------------+
void CloseAll()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!pos.SelectByIndex(i))          continue;
      if(pos.Symbol() != _Symbol)        continue;
      if(pos.Magic()  != InpMagic)       continue;

      ClosePosition(pos.Ticket());
     }
  }

//+------------------------------------------------------------------+
//| 手数规范化                                                       |
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
