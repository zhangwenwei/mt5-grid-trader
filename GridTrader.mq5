//+------------------------------------------------------------------+
//|                                                   GridTrader.mq5  |
//|              区间双向网格 EA - 上半做空 / 下半做多 (极简版)       |
//|                                                                  |
//|  逻辑: 人工填上下边界, 中线=(上界+下界)/2;                        |
//|        中线~上界 价格触线做空, 下界~中线 价格触线做多;            |
//|        方向总体止盈/移动止损出场; 中线本身不开单。              |
//|        上一根收盘超出上/下界 -> 全平并暂停开新单,                |
//|        close 回到区间内自动恢复交易。                           |
//|                                                                  |
//|  风险提示: 区间网格在单边突破时会在边界被止损式全平吃亏,         |
//|  这是设计内的最坏情况; 区间内同向可累积多单(InpMaxOrdersPerSide  |
//|  是主要刹车), 请控制手数与单数, 注意保证金, 先模拟回测。         |
//+------------------------------------------------------------------+
#property copyright "GridTrader"
#property version   "1.02"
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
input int      InpMaxOrdersPerSide = 20;        // 每方向最大单数 (刹车)
// 某方向空仓时, 第一单必须等价格先触碰对应边界(空碰上界/多碰下界)才开, 避免区间中部就开单。
input bool     InpFirstOrderAtEdge = true;      // 第一单须先触碰边界 (空仓时生效)

input group           "=== 手数 (阶梯: 边界大, 向中线递减) ==="
// 最靠边界的网格单用 InpInitLots; 每向中线方向拉开一格手数 -InpReduceLots; 不低于 InpMinLots。
// InpReduceLots=0 则所有格都用 InpInitLots(等于固定手数)。
input double   InpInitLots   = 0.01;            // 边界处初始手数 (最靠边界, 最大)
input double   InpReduceLots = 0.0;             // 每向中线拉开一格减少的手数 (0=固定手数)
input double   InpMinLots    = 0.01;            // 最小手数下限

input group           "=== 方向总体止盈 ==="
// 买/卖两组各自结算"手数加权平均浮盈"(Σ单pips×手数/Σ手数, pips/手)达 InpTPPips -> 平该方向全部单。
// 按手数加权, 不同手数(如马丁加仓)也能正确衡量; 同手数时=各单 pips 简单平均。
// (已移除单笔止盈, 只保留方向总体; 开下方移动止损时本阈值改作"启动阈值"。)
input double   InpTPPips      = 30.0;           // 该方向加权平均浮盈达此 pips/手: 平该方向(移动止损关)/ 启动移动止损(开)

input group           "=== 移动止损 (开关, ON 时替代上面的总体止盈) ==="
// 复用上面 InpTPPips 作启动阈值: 加权平均浮盈达 InpTPPips 时——
//  关 = 直接平(总体止盈); 开 = 启动跟踪记峰值, 从峰值回撤 InpTrailRetracePct% 才平该方向(让利润奔跑)。
input bool     InpTrailEnable     = false;      // 开启移动止损 (ON 替代总体止盈)
input double   InpTrailRetracePct = 30.0;       // 峰值回撤百分比(%): 从峰值回落此 % 平该方向

input group           "=== 方向篮子止损 (独立模块, 测试用; 默认关) ==="
// 与上面的"总体止盈/移动止损"完全独立: 单独开关、单独函数、单独调用点,
// 便于单独回测验证后, 再合并进 TrailTotal() 作为移动止损的止损分支。
// 触发: 某方向"手数加权平均浮亏"(pips/手) 达到本阈值 -> 平掉该方向全部持仓。
// 注意: 砍仓后若价格继续不利, 网格可能在更远的网格线重新开同向单(网格本性),
//       回测时重点观察"砍了又铺"的频率及其对总利润/回撤的影响。
input bool     InpSideStopEnable  = false;      // 开启方向篮子止损 (独立)
input double   InpSideStopPips    = 0.0;        // 该方向加权平均浮亏达此 pips/手 -> 平该方向 (>0生效)

input group           "=== 越界判断 (怎么算 越界 / 恢复) ==="
// 全部基于上一根已收盘 K 线(避免插针误触发)。越界与恢复共用同一距离:
//   越界 = 收盘价 超出(边界 + 距离);   恢复 = 收盘价 回到(边界内侧 距离)以内。
// "距离单位"决定下面用 pips值 还是 ATR倍数 (另一个不生效)。
enum ENUM_BREAKOUT_UNIT
  {
   BU_PIPS = 0,             // 固定 pips (用 [pips] 距离)
   BU_ATR                   // ATR 倍数 (用 [ATR] 距离, 随波动自适应)
  };
input ENUM_BREAKOUT_UNIT InpBreakoutUnit = BU_PIPS;  // 距离单位 (pips / ATR倍数)
input double   InpBreakoutPips      = 30.0;     // [pips] 越界/恢复距离 (固定pips时用)
input double   InpBreakoutAtr       = 1.0;      // [ATR] 越界/恢复距离倍数 (ATR倍数时用)
input int      InpBreakoutAtrPeriod = 14;       // [ATR] ATR 周期

input group           "=== 越界处理 (判定越界后的动作) ==="
// 判定越界后做什么, 二选一:
//  关闭     = 不处理, 照常按网格开单(无兜底止损, 单边风险大);
//  全平止损 = 超界全平所有单并暂停, 回区间(满足上面恢复条件)自动恢复(画蓝色竖线)。
enum ENUM_BREAKOUT_MODE
  {
   BREAKOUT_OFF = 0,        // 关闭: 突破边界不处理
   BREAKOUT_CLOSE_ALL       // 全平止损: 全平并暂停, 回区间恢复
  };
input ENUM_BREAKOUT_MODE InpBreakoutMode = BREAKOUT_CLOSE_ALL; // 越界处理方式

input group           "=== 过滤与风控 ==="
input double   InpMaxSpreadPoints  = 0;         // 最大点差(points), <=0 不限制
input long     InpMagic            = 20240601;  // 魔术号
input ulong    InpSlippagePoints   = 30;        // 允许滑点(points)

input group           "=== 图形显示 ==="
input bool     InpShowGraphics     = true;      // 画图总开关(边界/网格/竖线/信息面板); off=不画, 不影响交易

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

// 第一单触碰边界武装(InpFirstOrderAtEdge): true=已碰过最外侧网格线, 空仓时才允许开第一单。
// 该方向空仓且价格离开该线后撤防, 要求重新触碰。(武装判据用最外侧网格线而非裸边界,
// 避免区间宽非网格整数倍时碰不到边界而锁死第一单。)
bool   g_sellArmed = false;   // 卖组: 碰过最高空线才可开第一空
bool   g_buyArmed  = false;   // 买组: 碰过最低多线才可开第一多

// 总体移动止损: 记录该方向合计浮盈 pips 的峰值(>=触发阈值后回撤平组)。无持仓时归 0。
double g_trailPeakBuy  = 0.0;
double g_trailPeakSell = 0.0;

// 越界距离的 ATR 句柄(仅 InpBreakoutUnit=BU_ATR 时创建)
int    g_boAtrHandle = INVALID_HANDLE;

// 超界状态: 用上一根已收盘 K 线判断, true=当前在区间外。
// 全平止损模式: 超界 -> 全平并暂停; 回区间 -> 自动恢复。
bool   g_outOfRange   = false;

//+------------------------------------------------------------------+
int OnInit()
  {
   // 测试器视觉模式默认会显示 EA 用到的指标(如ATR), 这里关掉避免图表累赘(仅影响测试器)
   TesterHideIndicators(true);

   g_point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   g_pip    = (g_digits == 3 || g_digits == 5) ? 10 * g_point : g_point;

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   if(InpGridSizePips <= 0 || InpMaxOrdersPerSide <= 0)
     {
      Print("参数非法: 网格间距/最大单数必须大于0");
      return(INIT_PARAMETERS_INCORRECT);
     }

   if(InpInitLots <= 0 || InpMinLots <= 0 || InpReduceLots < 0 || InpInitLots < InpMinLots)
     {
      Print("参数非法: 手数 InitLots/MinLots 须>0, ReduceLots>=0, 且 InitLots>=MinLots");
      return(INIT_PARAMETERS_INCORRECT);
     }

   if(InpTrailEnable && (InpTrailRetracePct <= 0 || InpTrailRetracePct >= 100 || InpTPPips <= 0))
     {
      Print("参数非法: 移动止损需 InpTPPips>0 且 回撤百分比在 (0,100) 之间");
      return(INIT_PARAMETERS_INCORRECT);
     }

   // 方向篮子止损(独立模块): 开启时阈值必须 > 0
   if(InpSideStopEnable && InpSideStopPips <= 0)
     {
      Print("参数非法: 方向篮子止损开启时 InpSideStopPips 必须 > 0");
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

   // 越界距离用 ATR 单位时创建 ATR 句柄
   if(InpBreakoutMode != BREAKOUT_OFF && InpBreakoutUnit == BU_ATR)
     {
      g_boAtrHandle = iATR(_Symbol, _Period, InpBreakoutAtrPeriod);
      if(g_boAtrHandle == INVALID_HANDLE){ Print("创建 ATR 句柄失败"); return(INIT_FAILED); }
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
   // 释放指标句柄
   if(g_boAtrHandle    != INVALID_HANDLE) IndicatorRelease(g_boAtrHandle);

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
   if(!InpShowGraphics) return;

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

   // 越界止损触发线 (黄色粗线)
   DrawBreakoutLines();

   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//| 画越界/恢复线: 黄粗线=越界止损触发(边界±门槛);                  |
//|              绿粗线=恢复网格界限(边界内侧±缓冲)。               |
//|  门槛/缓冲按 距离单位(pips/ATR) 取值; ATR模式会变, OnTick 每根   |
//|  新 bar 刷新位置。仅"全平止损"模式画(关闭无越界处理)。          |
//+------------------------------------------------------------------+
void DrawBreakoutLines()
  {
   if(InpBreakoutMode == BREAKOUT_OFF)
      return;
   double margin = BreakoutDist(InpBreakoutPips, InpBreakoutAtr);
   DrawHSeg("GT_brk_up", g_upper + margin, clrYellow, STYLE_SOLID, 3, false);
   DrawHSeg("GT_brk_dn", g_lower - margin, clrYellow, STYLE_SOLID, 3, false);

   double buffer = ClampBuffer(BreakoutDist(InpBreakoutPips, InpBreakoutAtr));
   DrawHSeg("GT_rec_up", g_upper - buffer, clrLime, STYLE_SOLID, 3, false);
   DrawHSeg("GT_rec_dn", g_lower + buffer, clrLime, STYLE_SOLID, 3, false);
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
//| 在当前 K 线时刻画一条竖线标记 (越界止损蓝 / 移动止损黄)。       |
//|  名字带当前 K 线时间, 保证每次各画一条、互不覆盖。              |
//|  back=false 置前景更醒目(密集 K 线区不被盖); width 控制粗细。    |
//+------------------------------------------------------------------+
void DrawVLine(const color clr, const int width=1, const bool back=true)
  {
   if(!InpShowGraphics) return;
   datetime t = iTime(_Symbol, _Period, 0);   // 当前 K 线时间
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
//| 左上角信息面板的单行标签 (屏幕坐标固定, 不随价格滚动)。         |
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
//| 左上角实时盈亏面板: 买/卖两组各自的加权平均浮盈(pips/手)+单数。 |
//|  盈=绿, 亏=红, 无持仓=灰。                                      |
//+------------------------------------------------------------------+
void DrawInfoPanel()
  {
   if(!InpShowGraphics) return;
   int    buyN      = CountSide(POSITION_TYPE_BUY);
   int    sellN     = CountSide(POSITION_TYPE_SELL);
   double buyPips   = WeightedPipsByType(POSITION_TYPE_BUY);
   double sellPips  = WeightedPipsByType(POSITION_TYPE_SELL);
   double keepRatio = 1.0 - InpTrailRetracePct / 100.0;   // 移动止损保留比例

   // 顶行: 移动止损 开/关 + 参数
   string trailTxt = InpTrailEnable
                     ? StringFormat("移动止损: 开   启动 %.0f / 回撤 %.0f%%", InpTPPips, InpTrailRetracePct)
                     : StringFormat("移动止损: 关   (总体止盈 %.0f pips/手)", InpTPPips);
   InfoLabel("GT_info_trail", 56, trailTxt, InpTrailEnable ? clrGold : clrSilver);

   // 买行: 加权平均浮盈 + (移动止损开启时)止损目标点
   string buyTxt = StringFormat("买 %+.1f pips/手 (%d单)", buyPips, buyN);
   if(InpTrailEnable && buyN > 0)
     {
      bool   armedB  = (g_trailPeakBuy >= InpTPPips);                 // 是否已启动跟踪
      double targetB = (armedB ? g_trailPeakBuy : InpTPPips) * keepRatio;
      buyTxt += armedB
                ? StringFormat("  止损目标%.1f (峰值%.1f)", targetB, g_trailPeakBuy)
                : StringFormat("  止损目标%.1f (待启动)", targetB);
     }
   InfoLabel("GT_info_buy", 100, buyTxt,
             buyN == 0 ? clrGray : (buyPips >= 0 ? clrLime : clrTomato));

   // 卖行: 同上
   string sellTxt = StringFormat("卖 %+.1f pips/手 (%d单)", sellPips, sellN);
   if(InpTrailEnable && sellN > 0)
     {
      bool   armedS  = (g_trailPeakSell >= InpTPPips);
      double targetS = (armedS ? g_trailPeakSell : InpTPPips) * keepRatio;
      sellTxt += armedS
                 ? StringFormat("  止损目标%.1f (峰值%.1f)", targetS, g_trailPeakSell)
                 : StringFormat("  止损目标%.1f (待启动)", targetS);
     }
   InfoLabel("GT_info_sell", 144, sellTxt,
             sellN == 0 ? clrGray : (sellPips >= 0 ? clrLime : clrTomato));

   ChartRedraw(0);
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

   DrawInfoPanel();   // 左上角实时显示买/卖加权平均浮盈(pips/手)

   // 边界/中线/网格线是 OBJ_HLINE, OnInit 已画好, 不随时间移动, 这里不动。
   // 价格标签是 OBJ_TEXT, 需锚在最新 K 线; 每根新 bar 把标签右移到当前 K 线,
   // 让标签始终显示在图表右侧(OnInit 时测试器拿不到有效时间, 故在此刷新)。
   static datetime lblBar = 0;
   datetime curBar = iTime(_Symbol, _Period, 0);
   if(InpShowGraphics && curBar > 0 && curBar != lblBar)
     {
      lblBar = curBar;
      ObjectMove(0, "GT_upper_lbl",  0, curBar, g_upper);
      ObjectMove(0, "GT_center_lbl", 0, curBar, g_center);
      ObjectMove(0, "GT_lower_lbl",  0, curBar, g_lower);
      // 越界/恢复线: ATR 模式门槛/缓冲随波动变, 每根新 bar 刷新位置
      if(InpBreakoutMode != BREAKOUT_OFF)
        {
         double m = BreakoutDist(InpBreakoutPips, InpBreakoutAtr);
         ObjectMove(0, "GT_brk_up", 0, 0, g_upper + m);
         ObjectMove(0, "GT_brk_dn", 0, 0, g_lower - m);
         double b = ClampBuffer(BreakoutDist(InpBreakoutPips, InpBreakoutAtr));
         ObjectMove(0, "GT_rec_up", 0, 0, g_upper - b);
         ObjectMove(0, "GT_rec_dn", 0, 0, g_lower + b);
        }
      ChartRedraw(0);
     }

   // 越界处理: 全平止损 / 关闭; 返回 true 则本 tick 不再止盈/开单
   if(HandleBreakout())
      return;

   // 1) 方向总体止盈(未开移动止损时生效): 各组合计浮盈达标只平该组, 本 tick 不再开单
   if(!InpTrailEnable && InpTPPips > 0)
     {
      bool closedAny = false;

      double buyPips = WeightedPipsByType(POSITION_TYPE_BUY);
      if(CountSide(POSITION_TYPE_BUY) > 0 && buyPips >= InpTPPips)
        {
         PrintFormat("买组止盈触发: 买单加权平均浮盈 %.1f pips/手 >= %.1f, 平掉所有买单", buyPips, InpTPPips);
         CloseSide(POSITION_TYPE_BUY);
         closedAny = true;
        }

      double sellPips = WeightedPipsByType(POSITION_TYPE_SELL);
      if(CountSide(POSITION_TYPE_SELL) > 0 && sellPips >= InpTPPips)
        {
         PrintFormat("卖组止盈触发: 卖单加权平均浮盈 %.1f pips/手 >= %.1f, 平掉所有卖单", sellPips, InpTPPips);
         CloseSide(POSITION_TYPE_SELL);
         closedAny = true;
        }

      if(closedAny) return;   // 本 tick 已平仓, 下一轮重新铺该方向网格
     }

   // 1b) 移动止损(ON 时替代总体止盈): 按方向整组合计浮盈跟踪, 回撤触及平该方向
   if(InpTrailEnable && TrailTotal())
      return;                       // 整组移动止损平仓, 本 tick 不再开单

   // 1c) 方向篮子止损 (独立模块, 与上面止盈/移动止损解耦; 测试OK后再并入 TrailTotal)
   if(SideBasketStop())
      return;                       // 某方向触发止损平组, 本 tick 不再开单

   // 2) 区间内开网格单
   TradeGrid(grid);
  }

//+------------------------------------------------------------------+
//| 越界距离换算: 按单位开关选用 pips 套或 ATR 套, 返回价格距离。   |
//|  PIPS: pipsVal×pip;  ATR: atrMult×当前ATR(读不到则返回0)。       |
//+------------------------------------------------------------------+
double BreakoutDist(const double pipsVal, const double atrMult)
  {
   if(InpBreakoutUnit == BU_PIPS)
      return(pipsVal <= 0 ? 0.0 : pipsVal * g_pip);
   // BU_ATR
   if(atrMult <= 0) return(0.0);
   double atr[];
   if(g_boAtrHandle == INVALID_HANDLE) return(0.0);
   if(CopyBuffer(g_boAtrHandle, 0, 1, 1, atr) < 1 || atr[0] <= 0) return(0.0);
   return(atrMult * atr[0]);
  }

//+------------------------------------------------------------------+
//| 恢复缓冲裁剪: 不超过区间宽 40%(防上下缓冲交叠), 不小于 0。      |
//|  画恢复线与越界恢复判断共用, 保证图上线与实际生效值一致。       |
//+------------------------------------------------------------------+
double ClampBuffer(double buffer)
  {
   double maxBuf = (g_upper - g_lower) * 0.4;
   if(buffer > maxBuf) buffer = maxBuf;
   if(buffer < 0)      buffer = 0;
   return(buffer);
  }

//+------------------------------------------------------------------+
//| 越界判断: 上一根收盘价超出"边界 ± 外扩门槛"即算越界。          |
//|  门槛按距离单位取 pips套或ATR套, 0 时为收盘一超界即触发。      |
//+------------------------------------------------------------------+
bool IsOutOfRange()
  {
   double close1 = iClose(_Symbol, _Period, 1);
   if(close1 <= 0) return(false);
   double margin = BreakoutDist(InpBreakoutPips, InpBreakoutAtr);
   return(close1 > g_upper + margin || close1 < g_lower - margin);
  }

//+------------------------------------------------------------------+
//| 越界处理 (按 InpBreakoutMode 二选一):                            |
//|  越界判断委托给 IsOutOfRange(); 恢复看收盘价回到内侧缓冲带。     |
//|  返回值: true=当前处于越界暂停中(本 tick 不应再止盈/开单);       |
//|          false=区间内或功能关闭(正常交易)。                      |
//+------------------------------------------------------------------+
bool HandleBreakout()
  {
   // 关闭: 清残留状态, 不处理, 让上层正常交易
   if(InpBreakoutMode == BREAKOUT_OFF)
     {
      g_outOfRange = false;
      return(false);
     }

   double close1 = iClose(_Symbol, _Period, 1);   // 上一根已收盘 K 线收盘价
   if(close1 <= 0) return(false);                   // 历史不足时不判定

   // 触发用边界, 恢复用"边界内侧 buffer"形成滞回带, 防贴边反复止损/恢复。
   double buffer = ClampBuffer(BreakoutDist(InpBreakoutPips, InpBreakoutAtr));

   bool out        = IsOutOfRange();                                            // 越界(触发)
   bool backInside = (close1 <= g_upper - buffer && close1 >= g_lower + buffer); // 回到内侧(恢复)

   //=== 全平止损 ===
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
      PrintFormat("回到区间内侧(缓冲%.1f%s), 恢复交易: 上一根收盘 %.*f",
                  (InpBreakoutUnit==BU_PIPS ? InpBreakoutPips : InpBreakoutAtr),
                  (InpBreakoutUnit==BU_PIPS ? "pips" : "×ATR"), g_digits, close1);
     }

   if(g_outOfRange)
     {
      CloseAll();      // 平掉所有单
      return(true);    // 暂停止盈/开单
     }
   return(false);
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

   int sellN = CountSide(POSITION_TYPE_SELL);
   int buyN  = CountSide(POSITION_TYPE_BUY);

   // 第一单须先触碰"最外侧网格线"(空仓时): 碰最高空线武装卖、碰最低多线武装多;
   // 空仓且价格离开该线超 release 则撤防。有持仓时(加仓)不受此限,
   // InpFirstOrderAtEdge=false 则视为始终已武装。
   // 武装判据用"最外侧网格线"(实际开单位置)而非裸边界: 区间宽非网格整数倍时,
   // 最外侧线距边界可达近一格, 用裸边界会因碰不到而锁死/漏开第一单(对齐缺陷)。
   double topSellLine = g_center + MathFloor((g_upper - g_center + tol) / grid) * grid; // 最靠上界的空线
   double botBuyLine  = g_center - MathFloor((g_center - g_lower + tol) / grid) * grid; // 最靠下界的多线
   if(bid >= topSellLine - tol) g_sellArmed = true;
   if(ask <= botBuyLine  + tol) g_buyArmed  = true;
   if(sellN == 0 && bid < topSellLine - release) g_sellArmed = false;
   if(buyN  == 0 && ask > botBuyLine  + release) g_buyArmed  = false;
   bool sellAllowed = (!InpFirstOrderAtEdge || sellN > 0 || g_sellArmed);
   bool buyAllowed  = (!InpFirstOrderAtEdge || buyN  > 0 || g_buyArmed);

   //--- 上半区: 从中线+一格向上每隔一格一条网格线, 到上界 -> 做空 ---
   if(InpEnableSell && sellAllowed && sellInRange && g_lastSellLine == 0.0 && sellN < InpMaxOrdersPerSide)
     {
      for(int k = 1; ; k++)
        {
         double line = g_center + k * grid;
         if(line > g_upper + tol) break;
         // 价格"触碰"该网格线, 且该线附近还没有空单 -> 挂空, 并对该线上锁
         if(MathAbs(bid - line) <= tol && !HasOrderNear(POSITION_TYPE_SELL, line, grid))
           {
            OpenOrder(POSITION_TYPE_SELL, k, LotForLine(POSITION_TYPE_SELL, line, grid));
            g_lastSellLine = line;   // 上锁: 价格离开该线 3/4 格前不再开空
            break;
           }
        }
     }

   //--- 下半区: 从中线-一格向下每隔一格一条网格线, 到下界 -> 做多 ---
   if(InpEnableBuy && buyAllowed && buyInRange && g_lastBuyLine == 0.0 && buyN < InpMaxOrdersPerSide)
     {
      for(int k = 1; ; k++)
        {
         double line = g_center - k * grid;
         if(line < g_lower - tol) break;
         // 价格"触碰"该网格线, 且该线附近还没有多单 -> 挂多, 并对该线上锁
         if(MathAbs(ask - line) <= tol && !HasOrderNear(POSITION_TYPE_BUY, line, grid))
           {
            OpenOrder(POSITION_TYPE_BUY, k, LotForLine(POSITION_TYPE_BUY, line, grid));
            g_lastBuyLine = line;   // 上锁: 价格离开该线 3/4 格前不再开多
            break;
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| 某方向(买/卖)持仓的"手数加权平均浮盈"(pips/手)。               |
//|  Σ(单pips × 单手数) / Σ手数; 不同手数下按手数加权, 纯价差不含费。|
//|  同手数时退化为各单 pips 的简单平均。                           |
//+------------------------------------------------------------------+
double WeightedPipsByType(const ENUM_POSITION_TYPE type)
  {
   double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double wsum = 0.0;   // Σ(pips × 手数)
   double lots = 0.0;   // Σ手数
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!pos.SelectByIndex(i))      continue;
      if(pos.Symbol() != _Symbol)    continue;
      if(pos.Magic()  != InpMagic)   continue;
      if(pos.PositionType() != type) continue;
      double open = pos.PriceOpen();
      double pips = (type == POSITION_TYPE_BUY) ? (bid - open) / g_pip
                                                : (open - ask) / g_pip;
      wsum += pips * pos.Volume();
      lots += pos.Volume();
     }
   return(lots > 0.0 ? wsum / lots : 0.0);
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
//| 阶梯手数: 最靠边界的格用 InitLots, 每向中线一格 -ReduceLots,     |
//|  不低于 MinLots。返回已规范化手数。                             |
//+------------------------------------------------------------------+
double LotForLine(const ENUM_POSITION_TYPE type, const double line, const double grid)
  {
   int distEdge = (type == POSITION_TYPE_SELL)
                  ? (int)MathRound((g_upper - line) / grid)    // 上半区: 距上界的格数
                  : (int)MathRound((line - g_lower) / grid);   // 下半区: 距下界的格数
   if(distEdge < 0) distEdge = 0;
   double lots = InpInitLots - distEdge * InpReduceLots;
   if(lots < InpMinLots) lots = InpMinLots;
   return(NormalizeLots(lots));
  }

//+------------------------------------------------------------------+
//| 开一单 (备注标注网格编号; 手数由调用方按阶梯算好传入; 不挂TP)   |
//+------------------------------------------------------------------+
void OpenOrder(const ENUM_POSITION_TYPE type, const int gridNo, const double lots)
  {
   if(lots <= 0) return;

   // 备注标注在哪条网格线下单(距中线第几格): 如 "Grid Sell #3" / "Grid Buy #2"
   string cmt = StringFormat("Grid %s #%d", (type==POSITION_TYPE_BUY ? "Buy" : "Sell"), gridNo);

   // 不挂单笔 TP(已移除单笔止盈), 出场靠方向总体止盈 / 移动止损 / 越界处理
   bool ok = (type == POSITION_TYPE_BUY)
             ? trade.Buy (lots, _Symbol, 0.0, 0.0, 0.0, cmt)
             : trade.Sell(lots, _Symbol, 0.0, 0.0, 0.0, cmt);

   if(!ok)
      PrintFormat("开仓失败 %s lots=%.2f retcode=%d err=%d",
                  cmt, lots, trade.ResultRetcode(), GetLastError());
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
//| 移动止损·总体: 某方向合计浮盈(pips)达 X 后记峰值, 回撤 X/Y 平整组。|
//|  返回 true 表示本 tick 有平仓动作。                              |
//+------------------------------------------------------------------+
bool TrailTotal()
  {
   double startPips  = InpTPPips;
   double keepRatio  = 1.0 - InpTrailRetracePct / 100.0;   // 保留比例(回撤30% -> 保留0.7)
   bool   closed     = false;

   // 买组
   if(CountSide(POSITION_TYPE_BUY) > 0)
     {
      double p = WeightedPipsByType(POSITION_TYPE_BUY);
      if(p > g_trailPeakBuy) g_trailPeakBuy = p;
      if(g_trailPeakBuy >= startPips && p <= g_trailPeakBuy * keepRatio)
        {
         PrintFormat("买组移动止损: 峰值%.1f -> 回撤到%.1f pips/手(回撤%.0f%%), 平掉所有买单",
                     g_trailPeakBuy, p, InpTrailRetracePct);
         CloseSide(POSITION_TYPE_BUY);
         DrawVLine(p >= InpTPPips ? clrLime : clrYellow, 2, false);  // 落袋≥初设TP=绿, 否则黄
         g_trailPeakBuy = 0.0;
         closed = true;
        }
     }
   else g_trailPeakBuy = 0.0;

   // 卖组
   if(CountSide(POSITION_TYPE_SELL) > 0)
     {
      double p = WeightedPipsByType(POSITION_TYPE_SELL);
      if(p > g_trailPeakSell) g_trailPeakSell = p;
      if(g_trailPeakSell >= startPips && p <= g_trailPeakSell * keepRatio)
        {
         PrintFormat("卖组移动止损: 峰值%.1f -> 回撤到%.1f pips/手(回撤%.0f%%), 平掉所有卖单",
                     g_trailPeakSell, p, InpTrailRetracePct);
         CloseSide(POSITION_TYPE_SELL);
         DrawVLine(p >= InpTPPips ? clrLime : clrYellow, 2, false);  // 落袋≥初设TP=绿, 否则黄
         g_trailPeakSell = 0.0;
         closed = true;
        }
     }
   else g_trailPeakSell = 0.0;

   return(closed);
  }

//+------------------------------------------------------------------+
//| 方向篮子止损 (独立模块, 与止盈/移动止损解耦, 便于单独回测验证)。 |
//|  某方向"手数加权平均浮亏"(pips/手) 达到 InpSideStopPips 时,       |
//|  平掉该方向全部持仓。返回 true 表示本 tick 有平仓动作。          |
//|  复用 WeightedPipsByType / CloseSide, 度量口径与止盈完全一致。   |
//|  注: 测试通过后, 可把这两段并入 TrailTotal() 作为其止损分支。    |
//+------------------------------------------------------------------+
bool SideBasketStop()
  {
   if(!InpSideStopEnable || InpSideStopPips <= 0)
      return(false);

   bool closed = false;

   // 买组: 加权平均浮亏达阈值 -> 平所有买单
   if(CountSide(POSITION_TYPE_BUY) > 0)
     {
      double p = WeightedPipsByType(POSITION_TYPE_BUY);
      if(p <= -InpSideStopPips)
        {
         PrintFormat("买组篮子止损: 加权平均浮亏 %.1f pips/手 <= -%.1f, 平掉所有买单",
                     p, InpSideStopPips);
         CloseSide(POSITION_TYPE_BUY);
         DrawVLine(clrRed, 2, false);   // 篮子止损: 红色竖线
         g_trailPeakBuy = 0.0;          // 同步清空峰值, 防下一组沿用旧峰值(移动止损开启时)
         closed = true;
        }
     }

   // 卖组: 同上
   if(CountSide(POSITION_TYPE_SELL) > 0)
     {
      double p = WeightedPipsByType(POSITION_TYPE_SELL);
      if(p <= -InpSideStopPips)
        {
         PrintFormat("卖组篮子止损: 加权平均浮亏 %.1f pips/手 <= -%.1f, 平掉所有卖单",
                     p, InpSideStopPips);
         CloseSide(POSITION_TYPE_SELL);
         DrawVLine(clrRed, 2, false);
         g_trailPeakSell = 0.0;
         closed = true;
        }
     }

   return(closed);
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
