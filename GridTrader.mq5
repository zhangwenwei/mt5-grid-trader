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

input group           "=== 网格区间 (直接填上下边界价格) ==="
input double   InpUpperPrice       = 0.0;       // 网格上边界价 (必填, >下边界)
input double   InpLowerPrice       = 0.0;       // 网格下边界价 (必填, <上边界)

input group           "=== 网格设置 ==="
input double   InpGridSizePips     = 20.0;      // 网格间距 (pips)
input double   InpTakeProfitPips   = 20.0;      // 单笔止盈 (pips, 一般=网格间距)
input double   InpLots             = 0.01;      // 每单手数
input int      InpMaxOrdersPerSide = 10;        // 每方向最大单数 (刹车)

input group           "=== 过滤与风控 ==="
input double   InpMaxSpreadPoints  = 0;         // 最大点差(points), <=0 不限制(本次关闭)
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

   // 校验上下边界
   if(InpUpperPrice <= 0 || InpLowerPrice <= 0 || InpUpperPrice <= InpLowerPrice)
     {
      Print("参数非法: 必须填写有效的上/下边界价, 且上界 > 下界");
      return(INIT_PARAMETERS_INCORRECT);
     }

   g_upper  = InpUpperPrice;
   g_lower  = InpLowerPrice;
   g_center = (g_upper + g_lower) / 2.0;

   DrawLines();

   PrintFormat("GridTrader v2 启动. 上界=%.5f 中线=%.5f 下界=%.5f grid=%.5f",
               g_upper, g_center, g_lower, InpGridSizePips * g_pip);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   ObjectDelete(0, "GT_upper");
   ObjectDelete(0, "GT_center");
   ObjectDelete(0, "GT_lower");
   ChartRedraw(0);
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
   // 点差过滤(本次默认关闭)
   if(InpMaxSpreadPoints > 0)
     {
      long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      if(spread > InpMaxSpreadPoints)
         return;
     }

   double grid = InpGridSizePips * g_pip;

   // 1) 单笔止盈检查(始终执行)
   ManageTakeProfit();

   // 2) 超界判断: 用上一根已收盘 K 线的 close
   double close1 = iClose(_Symbol, _Period, 1);
   if(close1 > 0 && (close1 > g_upper || close1 < g_lower))
     {
      CloseAll();   // 全平
      return;       // 暂停开单, close 回到区间内自动恢复
     }

   // 3) 区间内开网格单
   TradeGrid(grid);
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
