//+------------------------------------------------------------------+
//|                                                   GridTrader.mq5  |
//|              区间双向网格 EA - 上半做空 / 下半做多 (极简版)       |
//|                                                                  |
//|  逻辑: 人工填上下边界, 中线=(上界+下界)/2;                        |
//|        中线~上界 价格触线做空, 下界~中线 价格触线做多;            |
//|        每单往中线方向走一个网格止盈; 中线本身不开单。            |
//|        上一根收盘超出上/下界 -> 全平并暂停开新单,                |
//|        close 回到区间内自动恢复交易。                           |
//|                                                                  |
//|  风险提示: 区间网格在单边突破时会在边界被止损式全平吃亏,         |
//|  这是设计内的最坏情况; 区间内同向可累积多单(InpMaxOrdersPerSide  |
//|  是主要刹车), 请控制手数与单数, 注意保证金, 先模拟回测。         |
//+------------------------------------------------------------------+
#property copyright "GridTrader"
#property version   "3.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//--- 输入参数 -------------------------------------------------------
input group           "=== 方向开关 ==="
input bool     InpEnableBuy        = true;      // 允许下半做多
input bool     InpEnableSell       = true;      // 允许上半做空

input group           "=== 网格区间 (人工必填) ==="
// 上下界必须手动填具体价格; 中线 = (上界+下界)/2 自动算。
input double   InpUpperPrice       = 0;         // 网格上边界价 (必填, >0)
input double   InpLowerPrice       = 0;         // 网格下边界价 (必填, >0)

input group           "=== 网格设置 ==="
input double   InpGridSizePips     = 20.0;      // 网格间距 (pips)
input double   InpLots             = 0.01;      // 每单手数
input int      InpMaxOrdersPerSide = 20;        // 每方向最大单数 (刹车)

input group           "=== 方向总体止盈 ==="
// 买单组、卖单组各自独立结算: 某一方向所有单合计浮盈(含库存费/手续费)达到此金额
// -> 只平掉该方向全部单(另一方向不动), 之后该方向重新铺网格。买卖共用这一个阈值。
// 单位 = 账户货币。0 = 关闭(则无任何止盈出口, 只剩超界处理, 极危险!)。
// 注意: 本版已去掉单笔止盈, 方向总体止盈是唯一主动止盈出口, 务必设合理值。
input double   InpGlobalTP         = 0.0;       // 单方向总浮盈达此值平掉该方向 (账户货币, 0=关闭)

input group           "=== 超界处理 ==="
// 三种越界处理动作三选一(均用上一根已收盘 K 线判断, 避免插针误触发):
//  关闭     = 突破边界不处理, 照常按网格开单(无兜底止损, 单边风险大);
//  全平止损 = 超界全平所有单并暂停, 回区间自动恢复(画蓝色竖线);
//  对冲锁仓 = 超界对每笔原单逐单开等量反向单冻结盈亏, 回区间平对冲单解锁(画紫色竖线)。
enum ENUM_BREAKOUT_MODE
  {
   BREAKOUT_OFF = 0,        // 关闭: 突破边界不处理
   BREAKOUT_CLOSE_ALL,      // 全平止损: 全平并暂停, 回区间恢复
   BREAKOUT_HEDGE_LOCK      // 对冲锁仓: 逐单对冲冻结, 回区间解锁
  };
input ENUM_BREAKOUT_MODE InpBreakoutMode = BREAKOUT_CLOSE_ALL; // 越界处理方式
// 滞回缓冲带: 越界用边界触发, 但"恢复/解锁"要求收盘价回到边界内侧这么多 pips 才生效。
// 防止价格贴着边界来回抖动导致反复锁仓/解锁(每轮吃点差, 利润流失)。0=不缓冲(立即恢复)。
input double   InpUnlockBufferPips = 30.0;      // 解锁/恢复回内侧缓冲 (pips, 0=关)

// 越界判断 = 正交两维: 价格基础(怎么算价格越界) × 指标过滤(叠加什么确认, 过滤假突破)。
// 最终越界 = 价格越界 且 指标过滤通过。可任意组合。
//  [价格基础] 收盘价=上一根收盘超界(稳,滞后); 含影线=上一根high/low穿透(灵敏,基于已收盘); tick=实时中间价(最灵敏,实盘受噪声).
//  [指标过滤] 无=不过滤; ATR=突破幅度>k×ATR; 布林=带宽较N根前扩张; ATR且布林=两者都满足(最严); ATR或布林=任一满足.
enum ENUM_BO_PRICE
  {
   BOP_CLOSE = 0,           // 收盘价
   BOP_WICK,                // 含影线 high/low
   BOP_TICK                 // 实时 tick 中间价
  };
enum ENUM_BO_FILTER
  {
   BOF_NONE = 0,            // 不加指标过滤
   BOF_ATR,                 // ATR 动态门槛
   BOF_BBW,                 // 布林带宽扩张
   BOF_ATR_AND_BBW,         // ATR 且 布林 (双确认, 最严)
   BOF_ATR_OR_BBW           // ATR 或 布林 (任一)
  };
input ENUM_BO_PRICE  InpBreakoutPrice  = BOP_WICK;  // 越界价格基础(默认含影线)
input ENUM_BO_FILTER InpBreakoutFilter = BOF_BBW;   // 越界指标过滤(默认布林带宽:回测最优组合)
input int      InpBOAtrPeriod     = 14;         // [ATR] ATR 周期
input double   InpBOAtrMult       = 1.0;        // [ATR] 突破门槛 k×ATR
input int      InpBOBbPeriod      = 20;         // [布林] 布林带周期
input int      InpBOBbWidenBars   = 5;          // [布林] 带宽较 N 根前扩张才算

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
// 价格必须真正离开该线(超过 3/4 格)后, 才允许在该线重新开单,
// 防止止盈后立刻重挂、以及大幅跳格时反复开单。
// 0 表示无记录(已武装, 可开单)。
double g_lastBuyLine  = 0.0;
double g_lastSellLine = 0.0;

// 越界判断的指标句柄(仅所选方式需要时创建)
int    g_boAtrHandle = INVALID_HANDLE;
int    g_boBbHandle  = INVALID_HANDLE;

// 超界状态: 用上一根已收盘 K 线判断, true=当前在区间外。
// 全平止损模式: 超界 -> 全平并暂停; 回区间 -> 自动恢复。
bool   g_outOfRange   = false;

// 对冲锁仓状态: true=已对所有原单开反向对冲单, 盈亏冻结, 暂停止盈/开单。
// 回区间 -> 平掉对冲单解锁。对冲单用 comment="Grid Hedge" 标记区分原网格单。
bool   g_locked       = false;

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

   // 上下界必须人工填且上界 > 下界
   if(InpUpperPrice <= 0 || InpLowerPrice <= 0)
     {
      Print("参数非法: 上下边界必须手动填具体价格(>0)");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpUpperPrice <= InpLowerPrice)
     {
      PrintFormat("参数非法: 上界(%.5f) 必须大于 下界(%.5f)", InpUpperPrice, InpLowerPrice);
      return(INIT_PARAMETERS_INCORRECT);
     }

   // 按所选指标过滤创建句柄(只创建需要的)
   if(InpBreakoutMode != BREAKOUT_OFF)
     {
      bool needAtr = (InpBreakoutFilter == BOF_ATR || InpBreakoutFilter == BOF_ATR_AND_BBW || InpBreakoutFilter == BOF_ATR_OR_BBW);
      bool needBbw = (InpBreakoutFilter == BOF_BBW || InpBreakoutFilter == BOF_ATR_AND_BBW || InpBreakoutFilter == BOF_ATR_OR_BBW);
      if(needAtr)
        {
         g_boAtrHandle = iATR(_Symbol, _Period, InpBOAtrPeriod);
         if(g_boAtrHandle == INVALID_HANDLE){ Print("创建 ATR 句柄失败"); return(INIT_FAILED); }
        }
      if(needBbw)
        {
         g_boBbHandle = iBands(_Symbol, _Period, InpBOBbPeriod, 0, 2.0, PRICE_CLOSE);
         if(g_boBbHandle == INVALID_HANDLE){ Print("创建 布林带 句柄失败"); return(INIT_FAILED); }
        }
     }

   g_upper  = InpUpperPrice;
   g_lower  = InpLowerPrice;
   g_center = (g_upper + g_lower) / 2.0;

   DrawLines();

   PrintFormat("GridTrader v3 启动. 上界=%.5f 中线=%.5f 下界=%.5f grid=%.5f",
               g_upper, g_center, g_lower, InpGridSizePips * g_pip);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   // 释放越界判断指标句柄
   if(g_boAtrHandle != INVALID_HANDLE) IndicatorRelease(g_boAtrHandle);
   if(g_boBbHandle  != INVALID_HANDLE) IndicatorRelease(g_boBbHandle);

   // 不删除 GT_ 对象: 保留边界/中线/网格线, 便于卸载 EA 或测试结束后继续查看。
   // (如需手动清理, 在图表上删除 GT_ 前缀对象即可)
   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//| 回测结束: 打印 MT5 官方风险统计 (便于命令行回测读取)            |
//+------------------------------------------------------------------+
double OnTester()
  {
   double profit   = TesterStatistics(STAT_PROFIT);
   double ddMoney  = TesterStatistics(STAT_EQUITY_DD);        // 最大资金回撤(货币)
   double ddPct    = TesterStatistics(STAT_EQUITYDD_PERCENT); // 最大资金回撤(%)
   double pf       = TesterStatistics(STAT_PROFIT_FACTOR);    // 盈利因子
   double trades   = TesterStatistics(STAT_TRADES);           // 成交笔数
   double winRate  = 0.0;
   double won      = TesterStatistics(STAT_PROFIT_TRADES);
   if(trades > 0) winRate = won / trades * 100.0;
   double recovery = TesterStatistics(STAT_RECOVERY_FACTOR);  // 恢复因子

   PrintFormat("STATS | 净利=%.0f | 最大回撤=%.0f (%.1f%%) | 盈利因子=%.2f | 恢复因子=%.2f | 笔数=%.0f | 胜率=%.1f%%",
               profit, ddMoney, ddPct, pf, recovery, trades, winRate);
   return(profit);
  }

//+------------------------------------------------------------------+
//| 画上界/中线/下界三条水平线 + 网格线 (均用 OBJ_HLINE)             |
//|  注意: 图形对象只在视觉模式回测/实盘图显示; 非视觉回测结果图     |
//|  不渲染任何 ObjectCreate 对象(MT5 机制), 故命令行回测看不到线。  |
//+------------------------------------------------------------------+
void DrawLines()
  {
   // 网格线 (淡灰点线): 先画, 放背景层, 让边界/中线浮在其上不被覆盖
   double grid = InpGridSizePips * g_pip;
   int gi = 0;
   for(double line = g_center + grid; line <= g_upper + grid*0.5 && gi < 200; line += grid)
     { DrawHSeg("GT_g_u" + IntegerToString(gi), line, C'200,200,210', STYLE_DOT, 1, true); gi++; }
   gi = 0;
   for(double line = g_center - grid; line >= g_lower - grid*0.5 && gi < 200; line -= grid)
     { DrawHSeg("GT_g_d" + IntegerToString(gi), line, C'200,200,210', STYLE_DOT, 1, true); gi++; }

   // 上界 (红色虚线) / 中线 (黄色实线) / 下界 (绿色虚线): 后画, 放前景层(BACK=false)
   DrawHSeg("GT_upper",  g_upper,  clrTomato,    STYLE_DASH,  1, false);
   DrawHSeg("GT_center", g_center, clrGold,      STYLE_SOLID, 2, false);
   DrawHSeg("GT_lower",  g_lower,  clrLimeGreen, STYLE_DASH,  1, false);

   // 上界/中线/下界的价格数值标签
   DrawPriceLabel("GT_upper_lbl",  g_upper,  "上界 " + DoubleToString(g_upper,  g_digits), clrTomato);
   DrawPriceLabel("GT_center_lbl", g_center, "中线 " + DoubleToString(g_center, g_digits), clrGold);
   DrawPriceLabel("GT_lower_lbl",  g_lower,  "下界 " + DoubleToString(g_lower,  g_digits), clrLimeGreen);

   // [诊断] 报告对象创建结果(确认画线代码确实执行、对象确实存在)
   PrintFormat("DRAWDIAG | GT_对象总数=%d | center=%s find=%d color=%d",
               ObjectsTotal(0, -1, -1),
               (ObjectFind(0,"GT_center")>=0?"存在":"缺失"),
               ObjectFind(0,"GT_center"),
               (int)ObjectGetInteger(0,"GT_center",OBJPROP_COLOR));

   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//| 画一条水平线 (OBJ_HLINE), 横贯整个图表。                         |
//|  OBJ_HLINE 只需价格、不需时间锚点, 在 OnInit 即可可靠创建,        |
//|  视觉模式回测图与实盘图都正常显示。                              |
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
   ObjectSetInteger(0, nm, OBJPROP_BACK,       back);  // 网格线置背景, 边界/中线置前景防覆盖
  }

//+------------------------------------------------------------------+
//| 在指定价位画文字标签, 显示名称+价格数值 (锚在最新 K 线右侧)      |
//+------------------------------------------------------------------+
void DrawPriceLabel(const string nm, const double price, const string text, const color clr)
  {
   datetime t = iTime(_Symbol, _Period, 0);   // 最新 K 线时间, 标签贴在图表右侧
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
//| 越界处理触发时刻画一条竖线标记 (颜色区分: 止损蓝 / 锁仓紫)      |
//|  名字带当前 K 线时间, 保证每次各画一条、互不覆盖。              |
//+------------------------------------------------------------------+
void DrawVLine(const color clr)
  {
   datetime t = iTime(_Symbol, _Period, 0);   // 当前 K 线时间
   if(t <= 0) t = TimeCurrent();
   string nm = "GT_v_" + IntegerToString((long)t);
   if(ObjectFind(0, nm) < 0)
      ObjectCreate(0, nm, OBJ_VLINE, 0, t, 0);
   else
      ObjectMove(0, nm, 0, t, 0);
   ObjectSetInteger(0, nm, OBJPROP_COLOR,      clr);
   ObjectSetInteger(0, nm, OBJPROP_STYLE,      STYLE_SOLID);
   ObjectSetInteger(0, nm, OBJPROP_WIDTH,      1);
   ObjectSetInteger(0, nm, OBJPROP_BACK,       true);    // 置背景, 不挡 K 线
   ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   // 点差过滤
   if(InpMaxSpreadPoints > 0)
     {
      long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      if(spread > InpMaxSpreadPoints)
         return;
     }

   double grid = InpGridSizePips * g_pip;

   // 边界/中线/网格线是 OBJ_HLINE, OnInit 已画好, 不随时间移动, 这里不动。
   // 价格标签是 OBJ_TEXT, 需锚在最新 K 线; 每根新 bar 把标签右移到当前 K 线,
   // 让标签始终显示在图表右侧(OnInit 时测试器拿不到有效时间, 故在此刷新)。
   static datetime lblBar = 0;
   datetime curBar = iTime(_Symbol, _Period, 0);
   if(curBar > 0 && curBar != lblBar)
     {
      lblBar = curBar;
      ObjectMove(0, "GT_upper_lbl",  0, curBar, g_upper);
      ObjectMove(0, "GT_center_lbl", 0, curBar, g_center);
      ObjectMove(0, "GT_lower_lbl",  0, curBar, g_lower);
      ChartRedraw(0);
     }

   // 越界处理(三选一): 全平止损 / 对冲锁仓 / 关闭; 返回 true 则本 tick 不再止盈/开单
   if(HandleBreakout())
      return;

   // 1) 方向总体止盈: 买组/卖组各自结算, 哪组浮盈达标只平哪组(另一组不动), 本 tick 不再开单
   if(InpGlobalTP > 0)
     {
      bool closedAny = false;

      double buyPnl = TotalFloatingPnLByType(POSITION_TYPE_BUY);
      if(CountSide(POSITION_TYPE_BUY) > 0 && buyPnl >= InpGlobalTP)
        {
         PrintFormat("买组止盈触发: 买单总浮盈 %.2f >= %.2f, 平掉所有买单", buyPnl, InpGlobalTP);
         CloseSide(POSITION_TYPE_BUY);
         closedAny = true;
        }

      double sellPnl = TotalFloatingPnLByType(POSITION_TYPE_SELL);
      if(CountSide(POSITION_TYPE_SELL) > 0 && sellPnl >= InpGlobalTP)
        {
         PrintFormat("卖组止盈触发: 卖单总浮盈 %.2f >= %.2f, 平掉所有卖单", sellPnl, InpGlobalTP);
         CloseSide(POSITION_TYPE_SELL);
         closedAny = true;
        }

      if(closedAny) return;   // 本 tick 已平仓, 下一轮重新铺该方向网格
     }

   // 2) 区间内开网格单
   TradeGrid(grid);
  }

//+------------------------------------------------------------------+
//| 越界判断 (按 InpBreakoutCheck 选方式): 价格是否有效越出边界。    |
//|  价格类(收盘/tick/影线)纯看价格; 指标类(ADX/ATR/BBW)在价格超界   |
//|  基础上叠加指标确认, 过滤震荡假突破。指标读不到时退化为纯收盘价。|
//+------------------------------------------------------------------+
bool IsOutOfRange()
  {
   // 1) 价格基础: 价格是否越界
   if(!PriceOut())
      return(false);

   // 2) 指标过滤: 叠加确认(无则直接通过)
   switch(InpBreakoutFilter)
     {
      case BOF_NONE:        return(true);
      case BOF_ATR:         return(AtrConfirm());
      case BOF_BBW:         return(BbwConfirm());
      case BOF_ATR_AND_BBW: return(AtrConfirm() && BbwConfirm());
      case BOF_ATR_OR_BBW:  return(AtrConfirm() || BbwConfirm());
     }
   return(true);
  }

//+------------------------------------------------------------------+
//| 价格基础: 按 InpBreakoutPrice 判断价格是否越出边界。            |
//+------------------------------------------------------------------+
bool PriceOut()
  {
   if(InpBreakoutPrice == BOP_TICK)
     {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double mid = (bid + ask) / 2.0;
      return(mid > g_upper || mid < g_lower);
     }
   if(InpBreakoutPrice == BOP_WICK)
     {
      double hi = iHigh(_Symbol, _Period, 1);
      double lo = iLow (_Symbol, _Period, 1);
      if(hi <= 0 || lo <= 0) return(false);
      return(hi > g_upper || lo < g_lower);
     }
   // BOP_CLOSE
   double close1 = iClose(_Symbol, _Period, 1);
   if(close1 <= 0) return(false);
   return(close1 > g_upper || close1 < g_lower);
  }

//+------------------------------------------------------------------+
//| ATR 确认: 上一根收盘突破边界的幅度 > k×ATR (突破够大)。         |
//|  读不到 ATR 时退化为 true(不拦截)。                            |
//+------------------------------------------------------------------+
bool AtrConfirm()
  {
   double close1 = iClose(_Symbol, _Period, 1);
   if(close1 <= 0) return(true);
   double atr[];
   if(CopyBuffer(g_boAtrHandle, 0, 1, 1, atr) < 1 || atr[0] <= 0) return(true);
   double margin = InpBOAtrMult * atr[0];
   return(close1 > g_upper + margin || close1 < g_lower - margin);
  }

//+------------------------------------------------------------------+
//| 布林带宽确认: 带宽较 N 根前扩张(趋势启动)。读不到退化为 true。  |
//+------------------------------------------------------------------+
bool BbwConfirm()
  {
   int    nb = InpBOBbWidenBars + 1;
   double up[], dn[];
   if(CopyBuffer(g_boBbHandle, 1, 1, nb, up) < nb ||
      CopyBuffer(g_boBbHandle, 2, 1, nb, dn) < nb) return(true);
   double widthNow  = up[nb-1] - dn[nb-1];   // 最新带宽
   double widthPrev = up[0]    - dn[0];       // N 根前带宽
   return(widthNow > widthPrev);
  }

//+------------------------------------------------------------------+
//| 越界处理 (按 InpBreakoutMode 三选一):                            |
//|  越界判断委托给 IsOutOfRange(); 恢复/解锁看收盘价回到内侧缓冲带。 |
//|  返回值: true=当前处于越界暂停中(本 tick 不应再止盈/开单);       |
//|          false=区间内或功能关闭(正常交易)。                      |
//+------------------------------------------------------------------+
bool HandleBreakout()
  {
   // 关闭: 清残留状态, 不处理, 让上层正常交易
   if(InpBreakoutMode == BREAKOUT_OFF)
     {
      g_outOfRange = false;
      g_locked     = false;
      return(false);
     }

   double close1 = iClose(_Symbol, _Period, 1);   // 上一根已收盘 K 线收盘价
   if(close1 <= 0) return(false);                   // 历史不足时不判定

   // 触发用边界, 恢复用"边界内侧 buffer"形成滞回带, 防贴边反复锁解。
   double buffer = InpUnlockBufferPips * g_pip;
   double maxBuf = (g_upper - g_lower) * 0.4;      // 上限: 不超过区间宽40%, 防上下缓冲交叠
   if(buffer > maxBuf) buffer = maxBuf;
   if(buffer < 0)      buffer = 0;

   bool out        = IsOutOfRange();                                            // 越界(按所选方式判断,触发)
   bool backInside = (close1 <= g_upper - buffer && close1 >= g_lower + buffer); // 回到内侧(恢复,看收盘价)

   //=== 模式1: 全平止损 ===
   if(InpBreakoutMode == BREAKOUT_CLOSE_ALL)
     {
      if(out && !g_outOfRange)
        {
         g_outOfRange = true;
         PrintFormat("超界全平: 上一根收盘 %.*f 超出区间 [%.*f, %.*f]",
                     g_digits, close1, g_digits, g_lower, g_digits, g_upper);
         DrawVLine(clrDodgerBlue);   // 止损: 蓝色竖线
        }
      else if(backInside && g_outOfRange)
        {
         g_outOfRange = false;
         PrintFormat("回到区间内侧(缓冲%.0fpips), 恢复交易: 上一根收盘 %.*f",
                     InpUnlockBufferPips, g_digits, close1);
        }

      if(g_outOfRange)
        {
         CloseAll();      // 平掉所有单
         return(true);    // 暂停止盈/开单
        }
      return(false);
     }

   //=== 模式2: 对冲锁仓 ===
   // 超界且未锁 -> 对冲并锁定; 回到内侧缓冲带且已锁 -> 平对冲单解锁。
   if(out && !g_locked)
     {
      LockHedge();
      g_locked = true;
      PrintFormat("超界对冲锁仓: 上一根收盘 %.*f 超出区间 [%.*f, %.*f]",
                  g_digits, close1, g_digits, g_lower, g_digits, g_upper);
      return(true);
     }
   else if(backInside && g_locked)
     {
      UnlockHedge();
      g_locked = false;
      PrintFormat("回到区间内侧(缓冲%.0fpips), 解锁对冲: 上一根收盘 %.*f",
                  InpUnlockBufferPips, g_digits, close1);
      return(false);
     }

   if(g_locked)
      return(true);    // 锁仓中: 盈亏冻结, 暂停止盈/开单
   return(false);
  }

//+------------------------------------------------------------------+
//| 对冲锁仓: 按方向合并手数后各开一笔反向单, 冻结净敞口。          |
//|  例: 5 笔 0.01 买单(共 0.05) -> 开一笔 0.05 卖单; 卖单同理。     |
//|  比逐单对冲少开单、省点差。对冲单 comment="Grid Hedge"。        |
//+------------------------------------------------------------------+
void LockHedge()
  {
   double buyVol  = 0.0;   // 原买单总手
   double sellVol = 0.0;   // 原卖单总手

   // 1) 累计原网格单各方向总手(排除已存在的对冲单)
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!pos.SelectByIndex(i))         continue;
      if(pos.Symbol() != _Symbol)       continue;
      if(pos.Magic()  != InpMagic)      continue;
      if(pos.Comment() == "Grid Hedge") continue;   // 跳过已有对冲单
      if(pos.PositionType() == POSITION_TYPE_BUY) buyVol  += pos.Volume();
      else                                        sellVol += pos.Volume();
     }

   // 2) 各开一笔合并反向对冲: 买总手->开等量卖, 卖总手->开等量买。
   //    注意必须判断原始 buyVol/sellVol>0, 不能判断 NormalizeLots 结果——
   //    NormalizeLots(0) 会被抬到最小手, 否则没持仓的一方会凭空开一笔最小对冲单。
   double hedgeSell = 0.0, hedgeBuy = 0.0;
   if(buyVol > 0)
     {
      hedgeSell = NormalizeLots(buyVol);
      if(!trade.Sell(hedgeSell, _Symbol, 0.0, 0.0, 0.0, "Grid Hedge"))
         PrintFormat("对冲卖单失败 vol=%.2f retcode=%d err=%d",
                     hedgeSell, trade.ResultRetcode(), GetLastError());
     }
   if(sellVol > 0)
     {
      hedgeBuy = NormalizeLots(sellVol);
      if(!trade.Buy(hedgeBuy, _Symbol, 0.0, 0.0, 0.0, "Grid Hedge"))
         PrintFormat("对冲买单失败 vol=%.2f retcode=%d err=%d",
                     hedgeBuy, trade.ResultRetcode(), GetLastError());
     }
   PrintFormat("对冲锁仓: 原买%.2f手->锁卖%.2f, 原卖%.2f手->锁买%.2f",
               buyVol, hedgeSell, sellVol, hedgeBuy);
  }

//+------------------------------------------------------------------+
//| 解锁: 平掉所有对冲单(comment="Grid Hedge"), 原网格单恢复交易。   |
//+------------------------------------------------------------------+
void UnlockHedge()
  {
   int closed = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!pos.SelectByIndex(i))         continue;
      if(pos.Symbol() != _Symbol)       continue;
      if(pos.Magic()  != InpMagic)      continue;
      if(pos.Comment() != "Grid Hedge") continue;   // 只平对冲单
      ClosePosition(pos.Ticket());
      closed++;
     }
   PrintFormat("解锁: 平掉对冲单 %d 笔", closed);
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

   // 实时价边界确认: 超界判断用的是上一根收盘价, 当前 tick 价可能已在界外。
   // 开单前用当前 bid/ask 再确认在区间内, 避免在边界外侧开单。
   bool buyInRange  = (ask >= g_lower && ask <= g_upper);   // 开多需当前价在区间内
   bool sellInRange = (bid >= g_lower && bid <= g_upper);   // 开空需当前价在区间内

   //--- 上半区: 从中线+一格向上每隔一格一条网格线, 到上界 -> 做空 ---
   if(InpEnableSell && sellInRange && g_lastSellLine == 0.0 && CountSide(POSITION_TYPE_SELL) < InpMaxOrdersPerSide)
     {
      for(int k = 1; ; k++)
        {
         double line = g_center + k * grid;
         if(line > g_upper + tol) break;
         // 价格"触碰"该网格线, 且该线附近还没有空单 -> 挂空, 并对该线上锁
         if(MathAbs(bid - line) <= tol && !HasOrderNear(POSITION_TYPE_SELL, line, grid))
           {
            OpenOrder(POSITION_TYPE_SELL);
            g_lastSellLine = line;   // 上锁: 价格离开该线 3/4 格前不再开空
            break;
           }
        }
     }

   //--- 下半区: 从中线-一格向下每隔一格一条网格线, 到下界 -> 做多 ---
   if(InpEnableBuy && buyInRange && g_lastBuyLine == 0.0 && CountSide(POSITION_TYPE_BUY) < InpMaxOrdersPerSide)
     {
      for(int k = 1; ; k++)
        {
         double line = g_center - k * grid;
         if(line < g_lower - tol) break;
         // 价格"触碰"该网格线, 且该线附近还没有多单 -> 挂多, 并对该线上锁
         if(MathAbs(ask - line) <= tol && !HasOrderNear(POSITION_TYPE_BUY, line, grid))
           {
            OpenOrder(POSITION_TYPE_BUY);
            g_lastBuyLine = line;   // 上锁: 价格离开该线 3/4 格前不再开多
            break;
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| 某方向(买/卖)本 symbol+magic 持仓的总浮动盈亏(含库存费/手续费)   |
//+------------------------------------------------------------------+
double TotalFloatingPnLByType(const ENUM_POSITION_TYPE type)
  {
   double total = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!pos.SelectByIndex(i))      continue;
      if(pos.Symbol() != _Symbol)    continue;
      if(pos.Magic()  != InpMagic)   continue;
      if(pos.PositionType() != type) continue;
      total += pos.Profit() + pos.Swap() + pos.Commission();
     }
   return(total);
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
//| 平掉本 symbol+magic 某一方向(买/卖)的所有持仓                    |
//+------------------------------------------------------------------+
void CloseSide(const ENUM_POSITION_TYPE type)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!pos.SelectByIndex(i))      continue;
      if(pos.Symbol() != _Symbol)    continue;
      if(pos.Magic()  != InpMagic)   continue;
      if(pos.PositionType() != type) continue;

      ClosePosition(pos.Ticket());
     }
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
