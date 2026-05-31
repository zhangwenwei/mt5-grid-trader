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
input double   InpUpperPrice       = 159.5;     // 网格上边界价 (0=自动)
input double   InpLowerPrice       = 157.5;     // 网格下边界价 (0=自动)

enum ENUM_BOUNDS_MODE
  {
   BOUNDS_DONCHIAN_HL = 0,   // 唐奇安: 近N根 最高/最低 (含影线)
   BOUNDS_DONCHIAN_CLOSE,    // 唐奇安: 近N根 收盘价最高/最低 (去插针)
   BOUNDS_ATR,               // 中线(近N根均价) ± k×ATR
   BOUNDS_CENTER_PIPS,       // 以当前价为中线 ± InpHalfRangePips
   BOUNDS_CENTER_ATR,        // 以当前价为中线 ± k×ATR (价格必居中)
   BOUNDS_DAILY_SWING,       // 触碰次数法 S/R 做上下界
   BOUNDS_FIBO_TOUCH         // 斐波回撤位 + 触碰次数 双确认 做上下界
  };
input ENUM_BOUNDS_MODE InpBoundsMode = BOUNDS_DAILY_SWING; // [手段1] 自动定界算法
input int      InpAutoLookback     = 100;       // 自动(唐奇安): 回看 K 线根数
input int      InpATRPeriod        = 14;        // 自动(ATR模式): ATR 周期
input double   InpATRMult          = 10.0;      // 自动(ATR模式): k 倍数
input double   InpHalfRangePips    = 150.0;     // 自动(CENTER_PIPS模式): 中线上下各展开 pips
input ENUM_TIMEFRAMES InpSwingTF   = PERIOD_H1; // S/R: 用哪个周期找密集价位
input int      InpSRMonths          = 3;        // S/R: 回看月数(按时间, 默认近3个月)
input double   InpSRMinDistPips    = 80.0;      // S/R: 边界距现价的最小距离(pips, 避免贴中枢)
input double   InpFiboTolPips       = 30.0;     // 斐波模式: 触碰峰值距斐波位多近才算"双确认"(pips)
input int      InpSwingStrength    = 5;         // (保留, 未用)
input double   InpBoundsShrinkPct  = 0.0;       // [手段2] 边界向内收缩百分比(0~40, 0=不收缩)

input group           "=== 网格设置 ==="
input double   InpGridSizePips     = 20.0;      // 网格间距 (pips)
input double   InpTakeProfitPips   = 30.0;      // 单笔止盈 (pips)
input double   InpLots             = 0.01;      // 每单手数
input int      InpMaxOrdersPerSide = 20;        // 每方向最大单数 (刹车)

input group           "=== 超界行为 [手段4] ==="
enum ENUM_BREAKOUT_MODE
  {
   BREAKOUT_CLOSE_ALL = 0,   // 超界全平并暂停 (原行为)
   BREAKOUT_PAUSE_ONLY,      // 超界只暂停开新单, 不平已有单(让其自行止盈)
   BREAKOUT_HEDGE_LOCK,      // 超界对冲净敞口锁仓, 回区间后解锁
   BREAKOUT_TRAIL_SL         // 超界给逆势单挂跟踪止损(趋势认亏离场/震荡回血)
  };
input ENUM_BREAKOUT_MODE InpBreakoutMode = BREAKOUT_TRAIL_SL; // 超界处理方式(默认:跟踪止损)
input double   InpTrailDistPips    = 50.0;      // 跟踪止损距离 (pips, 仅 TRAIL_SL 模式)

input group           "=== 全局熔断 [手段3] (账户货币, 0=关闭) ==="
input double   InpGlobalTP         = 0.0;       // 总浮盈达此值 -> 全平 (0=关闭)
input double   InpGlobalSL         = 0.0;       // 总浮亏达此值 -> 全平停机 (0=关闭)

input group           "=== 趋势过滤器 [手段5] (趋势市暂停开新单) ==="
enum ENUM_TREND_FILTER
  {
   TREND_FILTER_OFF = 0,     // 关闭, 任何行情都开单
   TREND_FILTER_ADX,         // 仅 ADX: ADX>阈值=趋势, 暂停开单
   TREND_FILTER_ADX_BB       // ADX>阈值 且 布林带宽扩张, 才判趋势
  };
input ENUM_TREND_FILTER InpTrendFilter = TREND_FILTER_OFF; // 趋势过滤模式
input ENUM_TIMEFRAMES InpTrendTF   = PERIOD_CURRENT; // 趋势过滤用哪个周期(可低于交易周期, 反应更快)
input int      InpADXPeriod        = 14;        // ADX 周期
input double   InpADXThreshold     = 25.0;      // ADX 阈值(>此值=趋势)
input int      InpBBPeriod         = 20;        // 布林带周期(ADX_BB模式)
int            InpBBWidenBars      = 5;         // 带宽较N根前扩张则算趋势(ADX_BB模式)

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
int    g_adxHandle = INVALID_HANDLE; // 趋势过滤 ADX
int    g_bbHandle  = INVALID_HANDLE; // 趋势过滤 布林带
bool   g_halted    = false;          // 全局止损熔断后停机

bool   g_locked       = false;       // 锁仓状态(超界对冲中)
ulong  g_hedgeTicket  = 0;           // 对冲锁仓单的 ticket

// 锁仓诊断统计
int    g_lockCount    = 0;           // 锁仓次数
long   g_lockBars     = 0;           // 锁仓累计 bar 数(粗略时长)
double g_hedgeCostSum = 0.0;         // 对冲单平仓时的累计盈亏(含点差/库存费)

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
   if(needAuto && (InpBoundsMode == BOUNDS_ATR || InpBoundsMode == BOUNDS_CENTER_ATR))
     {
      g_atrHandle = iATR(_Symbol, _Period, InpATRPeriod);
      if(g_atrHandle == INVALID_HANDLE)
        {
         Print("创建 ATR 句柄失败");
         return(INIT_FAILED);
        }
     }

   // 趋势过滤器指标句柄
   if(InpTrendFilter != TREND_FILTER_OFF)
     {
      g_adxHandle = iADX(_Symbol, InpTrendTF, InpADXPeriod);
      if(g_adxHandle == INVALID_HANDLE){ Print("创建 ADX 句柄失败"); return(INIT_FAILED); }
     }
   if(InpTrendFilter == TREND_FILTER_ADX_BB)
     {
      g_bbHandle = iBands(_Symbol, InpTrendTF, InpBBPeriod, 0, 2.0, PRICE_CLOSE);
      if(g_bbHandle == INVALID_HANDLE){ Print("创建 布林带 句柄失败"); return(INIT_FAILED); }
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
   if(g_atrHandle != INVALID_HANDLE) IndicatorRelease(g_atrHandle);
   if(g_adxHandle != INVALID_HANDLE) IndicatorRelease(g_adxHandle);
   if(g_bbHandle  != INVALID_HANDLE) IndicatorRelease(g_bbHandle);
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
   PrintFormat("LOCKSTATS | 锁仓次数=%d | 锁仓累计bar=%d | 对冲单累计盈亏(点差+利息+方向)=%.0f",
               g_lockCount, g_lockBars, g_hedgeCostSum);
   return(profit);
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
//| 触碰次数法找支撑阻力(不依赖周期, 找价格反复停留的密集价位)。   |
//| 1) 读回看期 high/low, 确定价格范围, 切成 bin(每格=网格间距)。  |
//| 2) 每根 K 线扫过的价格格 +1 计数。                              |
//| 3) 当前价上方触碰最多的格=阻力, 下方触碰最多的格=支撑。         |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| 价格是否落在任一斐波位的容差范围内                              |
//+------------------------------------------------------------------+
bool NearAnyFibo(const double price, const double &fibo[], const double tol)
  {
   for(int i = 0; i < ArraySize(fibo); i++)
      if(MathAbs(price - fibo[i]) <= tol) return(true);
   return(false);
  }

//+------------------------------------------------------------------+
bool CalcDailySwing(double &hi, double &lo)
  {
   if(InpSRMonths < 1)
     {
      Print("参数非法: S/R 回看月数必须>=1");
      return(false);
     }

   // 按"时间范围"取数: 从 (当前K线时间 - N个月) 到 上一根已收盘K线
   datetime tEnd   = iTime(_Symbol, InpSwingTF, 1);              // 上一根已收盘
   datetime tStart = tEnd - (datetime)InpSRMonths * 30 * 24 * 3600; // N个月前(按30天/月)

   double dh[], dl[];
   int gotH = CopyHigh(_Symbol, InpSwingTF, tStart, tEnd, dh);
   int gotL = CopyLow (_Symbol, InpSwingTF, tStart, tEnd, dl);
   if(gotH < 20 || gotL < 20 || gotH != gotL)
     {
      PrintFormat("S/R: 近%d个月历史不足(取到%d根), 请补历史数据或减小月数", InpSRMonths, gotH);
      return(false);
     }
   PrintFormat("S/R: 取近%d个月数据, 共%d根%s K线", InpSRMonths, gotH, EnumToString(InpSwingTF));

   // 价格范围
   double rangeHi = dh[ArrayMaximum(dh)];
   double rangeLo = dl[ArrayMinimum(dl)];
   if(rangeHi <= rangeLo){ Print("S/R: 价格范围无效"); return(false); }

   // bin 大小 = 网格间距(与交易对齐, 不依赖周期)
   double binSize = InpGridSizePips * g_pip;
   if(binSize <= 0){ Print("S/R: bin 大小无效"); return(false); }
   int bins = (int)MathCeil((rangeHi - rangeLo) / binSize) + 1;
   if(bins < 3 || bins > 5000){ Print("S/R: bin 数量异常 ", bins); return(false); }

   // 统计每个 bin 被多少根 K 线的 [low,high] 覆盖(触碰次数)
   int touch[];
   ArrayResize(touch, bins);
   ArrayInitialize(touch, 0);
   int n = ArraySize(dh);
   for(int i = 0; i < n; i++)
     {
      int b0 = (int)((dl[i] - rangeLo) / binSize);
      int b1 = (int)((dh[i] - rangeLo) / binSize);
      if(b0 < 0) b0 = 0;
      if(b1 > bins-1) b1 = bins-1;
      for(int b = b0; b <= b1; b++) touch[b]++;
     }

   double mid = (SymbolInfoDouble(_Symbol, SYMBOL_BID) + SymbolInfoDouble(_Symbol, SYMBOL_ASK)) / 2.0;
   int curBin = (int)((mid - rangeLo) / binSize);
   if(curBin < 0) curBin = 0;
   if(curBin > bins-1) curBin = bins-1;

   // 距现价的最小 bin 数(避免选到贴着中枢的价位)
   int minGap = (int)MathRound(InpSRMinDistPips * g_pip / binSize);
   if(minGap < 1) minGap = 1;

   bool useFibo = (InpBoundsMode == BOUNDS_FIBO_TOUCH);
   double fibo[];
   if(useFibo)
     {
      double ratios[] = {0.236, 0.382, 0.5, 0.618, 0.786};
      ArrayResize(fibo, 5);
      for(int r = 0; r < 5; r++) fibo[r] = rangeHi - (rangeHi - rangeLo) * ratios[r];
     }
   double fiboTol = InpFiboTolPips * g_pip;

   //--- 1) 纯触碰: 现价上/下方最近距离外, 触碰最高的局部峰值 ---
   int resBin=-1, resCnt=-1, supBin=-1, supCnt=-1;
   for(int b = curBin + minGap; b < bins - 1; b++){
      if(touch[b] >= touch[b-1] && touch[b] >= touch[b+1] && touch[b] > resCnt){ resCnt=touch[b]; resBin=b; } }
   for(int b = curBin - minGap; b >= 1; b--){
      if(touch[b] >= touch[b-1] && touch[b] >= touch[b+1] && touch[b] > supCnt){ supCnt=touch[b]; supBin=b; } }
   double resTouch = (resBin >= 0) ? rangeLo + (resBin+0.5)*binSize : rangeHi;
   double supTouch = (supBin >= 0) ? rangeLo + (supBin+0.5)*binSize : rangeLo;

   double resistance = resTouch, support = supTouch;

   //--- 2) 斐波保守微调: 只在斐波位"更靠内(收窄区间)"时才采用, 绝不撑宽 ---
   if(useFibo)
     {
      int rfBin=-1, rfCnt=-1, sfBin=-1, sfCnt=-1;
      for(int b = curBin + minGap; b < bins - 1; b++){
         if(touch[b] >= touch[b-1] && touch[b] >= touch[b+1] && touch[b] > rfCnt
            && NearAnyFibo(rangeLo+(b+0.5)*binSize, fibo, fiboTol)){ rfCnt=touch[b]; rfBin=b; } }
      for(int b = curBin - minGap; b >= 1; b--){
         if(touch[b] >= touch[b-1] && touch[b] >= touch[b+1] && touch[b] > sfCnt
            && NearAnyFibo(rangeLo+(b+0.5)*binSize, fibo, fiboTol)){ sfCnt=touch[b]; sfBin=b; } }
      // 阻力: 斐波位若更低(更靠内)则采用; 支撑: 斐波位若更高(更靠内)则采用
      if(rfBin >= 0){ double rf=rangeLo+(rfBin+0.5)*binSize; if(rf < resistance) resistance=rf; }
      if(sfBin >= 0){ double sf=rangeLo+(sfBin+0.5)*binSize; if(sf > support)    support=sf; }
     }

   if(resistance <= support){ Print("S/R: 阻力<=支撑, 退化用区间极值"); resistance=rangeHi; support=rangeLo; }

   hi = resistance;
   lo = support;
   PrintFormat("%sS/R: 阻力=%.5f 支撑=%.5f | 现价%.5f 触碰区间[%.5f,%.5f] minGap=%d格",
               (useFibo?"斐波保守":"触碰法"),
               hi, lo, mid, supTouch, resTouch, minGap);
   return(true);
  }

//+------------------------------------------------------------------+
//| 按所选算法计算自动上下界(未收缩)。                              |
//+------------------------------------------------------------------+
bool CalcAutoBounds(double &hi, double &lo)
  {
   // 触碰次数 S/R, 或 斐波+触碰双确认(同一函数, 内部按模式分支)
   if(InpBoundsMode == BOUNDS_DAILY_SWING || InpBoundsMode == BOUNDS_FIBO_TOUCH)
      return(CalcDailySwing(hi, lo));

   // 以当前价为中线的两种模式: 保证价格永远在区间正中, 不受启动时机影响
   if(InpBoundsMode == BOUNDS_CENTER_PIPS || InpBoundsMode == BOUNDS_CENTER_ATR)
     {
      double mid = (SymbolInfoDouble(_Symbol, SYMBOL_BID) + SymbolInfoDouble(_Symbol, SYMBOL_ASK)) / 2.0;
      double half;
      if(InpBoundsMode == BOUNDS_CENTER_PIPS)
        {
         if(InpHalfRangePips <= 0){ Print("参数非法: InpHalfRangePips 必须>0"); return(false); }
         half = InpHalfRangePips * g_pip;
        }
      else // CENTER_ATR
        {
         double atr[];
         if(CopyBuffer(g_atrHandle, 0, 1, 1, atr) < 1 || atr[0] <= 0)
           { Print("自动计算边界失败: ATR 读取失败(历史不足?)"); return(false); }
         half = InpATRMult * atr[0];
        }
      hi = mid + half;
      lo = mid - half;
      return(true);
     }

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

   double close1 = iClose(_Symbol, _Period, 1);
   bool   outOfRange = (close1 > 0 && (close1 > g_upper || close1 < g_lower));

   //--- 锁仓状态处理: 回到区间内则解锁 ---
   if(g_locked)
     {
      // 统计锁仓时长(按新 bar 计)
      static datetime lockBarTime = 0;
      datetime bt = iTime(_Symbol, _Period, 0);
      if(bt != lockBarTime){ g_lockBars++; lockBarTime = bt; }

      if(!outOfRange)
         Unlock();        // 平掉对冲单, 恢复网格
      return;            // 锁仓期间: 不止盈、不开单、不熔断(盈亏已冻结)
     }

   // 1) 单笔止盈检查(非锁仓时)
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
      g_halted = true;
      return;
     }

   // 3) 超界处理
   if(outOfRange)
     {
      if(InpBreakoutMode == BREAKOUT_CLOSE_ALL)
         CloseAll();
      else if(InpBreakoutMode == BREAKOUT_HEDGE_LOCK)
         Lock();          // 对冲净敞口锁仓
      else if(InpBreakoutMode == BREAKOUT_TRAIL_SL)
         UpdateTrailingSL(close1 > g_upper);  // 给逆势单挂/推进跟踪止损
      // PAUSE_ONLY: 什么都不做, 仅靠下面的 return 暂停开单
      return;
     }
   else if(InpBreakoutMode == BREAKOUT_TRAIL_SL)
     {
      // 回到区间内: 撤销所有跟踪止损, 让单子重新交给网格止盈
      ClearAllSL();
     }

   // 4) [手段5] 趋势过滤: 明显趋势时暂停开新单(已有单的止盈/跟踪止损不受影响)
   if(InpTrendFilter != TREND_FILTER_OFF && IsTrending())
      return;

   // 5) 区间内开网格单
   TradeGrid(grid);
  }

//+------------------------------------------------------------------+
//| 趋势判定: 返回 true 表示当前是明显趋势(应暂停开新网格单)。      |
//|  ADX 模式: ADX > 阈值 即趋势。                                  |
//|  ADX_BB 模式: ADX>阈值 且 布林带宽较 N 根前扩张, 才算趋势。     |
//+------------------------------------------------------------------+
bool IsTrending()
  {
   // 读 ADX(主线在 buffer 0), 取上一根已收盘值
   double adx[];
   if(CopyBuffer(g_adxHandle, 0, 1, 1, adx) < 1)
      return(false);   // 读不到则不拦截
   bool adxTrend = (adx[0] > InpADXThreshold);

   if(InpTrendFilter == TREND_FILTER_ADX)
      return(adxTrend);

   // ADX_BB: 还要求布林带宽在扩张
   if(!adxTrend)
      return(false);   // ADX 都没到, 直接判震荡
   double up[], dn[];
   // buffer 1=上轨, 2=下轨; 取最近 InpBBWidenBars+1 根比较带宽
   int nb = InpBBWidenBars + 1;
   if(CopyBuffer(g_bbHandle, 1, 1, nb, up) < nb || CopyBuffer(g_bbHandle, 2, 1, nb, dn) < nb)
      return(adxTrend); // 带宽读不到, 退回只看 ADX
   double widthNow  = up[nb-1] - dn[nb-1];   // 最新
   double widthPrev = up[0]    - dn[0];        // N 根前
   bool   widening  = (widthNow > widthPrev);
   return(adxTrend && widening);
  }

//+------------------------------------------------------------------+
//| 锁仓: 开一笔反向单对冲当前净敞口, 使盈亏冻结                     |
//+------------------------------------------------------------------+
void Lock()
  {
   double netLots = NetLots();   // 多手数 - 空手数(正=净多)
   double lockLots = NormalizeLots(MathAbs(netLots));
   if(lockLots <= 0)
     {
      // 净敞口为零, 无需对冲, 直接标记锁定(纯暂停)
      g_locked = true;
      g_hedgeTicket = 0;
      g_lockCount++;
      DrawMark("LOCK", true);
      return;
     }

   // 净多 -> 开空对冲; 净空 -> 开多对冲
   bool ok;
   if(netLots > 0)
      ok = trade.Sell(lockLots, _Symbol, 0.0, 0.0, 0.0, "Hedge Lock");
   else
      ok = trade.Buy (lockLots, _Symbol, 0.0, 0.0, 0.0, "Hedge Lock");

   if(ok)
     {
      g_hedgeTicket = trade.ResultOrder() > 0 ? PositionTicketByDeal() : 0;
      g_locked = true;
      g_lockCount++;
      DrawMark("LOCK", true);
      PrintFormat("超界锁仓#%d: 净敞口=%.2f 手, 开对冲 %.2f 手", g_lockCount, netLots, lockLots);
     }
   else
      PrintFormat("锁仓对冲失败 retcode=%d err=%d", trade.ResultRetcode(), GetLastError());
  }

//+------------------------------------------------------------------+
//| 解锁: 平掉对冲单, 网格恢复                                       |
//+------------------------------------------------------------------+
void Unlock()
  {
   if(g_hedgeTicket != 0)
     {
      // 平仓前记录对冲单实际盈亏(含点差+库存费), 量化锁仓成本
      if(pos.SelectByTicket(g_hedgeTicket))
         g_hedgeCostSum += pos.Profit() + pos.Swap() + pos.Commission();

      if(!trade.PositionClose(g_hedgeTicket))
         PrintFormat("解锁平对冲单失败 ticket=%I64u retcode=%d", g_hedgeTicket, trade.ResultRetcode());
     }
   g_locked = false;
   g_hedgeTicket = 0;
   DrawMark("UNLOCK", false);   // 图上标记解锁点
   Print("回到区间, 解锁");
  }

//+------------------------------------------------------------------+
//| 跟踪止损: 给逆势浮亏单挂/推进 SL                                |
//|  breakUp=true : 价格破上界, 逆势单是空单(SELL), SL 在上方       |
//|  breakUp=false: 价格破下界, 逆势单是多单(BUY),  SL 在下方       |
//|  SL 只朝收紧方向移动(不回撤), 触及由服务器/测试器自动平仓。     |
//+------------------------------------------------------------------+
void UpdateTrailingSL(const bool breakUp)
  {
   double dist  = InpTrailDistPips * g_pip;
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int    stopLv= (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minGap= stopLv * g_point;

   ENUM_POSITION_TYPE target = breakUp ? POSITION_TYPE_SELL : POSITION_TYPE_BUY;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!pos.SelectByIndex(i))          continue;
      if(pos.Symbol() != _Symbol)        continue;
      if(pos.Magic()  != InpMagic)       continue;
      if(pos.PositionType() != target)   continue;

      double curSL = pos.StopLoss();
      double newSL;

      if(target == POSITION_TYPE_SELL)
        {
         // 空单: SL 在上方 = ask + dist; 越低越紧, 只下移
         newSL = NormalizeDouble(ask + dist, g_digits);
         // 遵守 stops level: SL 距当前 ask 至少 minGap
         if(newSL < ask + minGap) newSL = NormalizeDouble(ask + minGap, g_digits);
         if(curSL == 0.0 || newSL < curSL - g_point*0.5)
            ModifySL(pos.Ticket(), newSL, pos.TakeProfit());
        }
      else // BUY
        {
         // 多单: SL 在下方 = bid - dist; 越高越紧, 只上移
         newSL = NormalizeDouble(bid - dist, g_digits);
         // 遵守 stops level: SL 距当前 bid 至少 minGap
         if(newSL > bid - minGap) newSL = NormalizeDouble(bid - minGap, g_digits);
         if(curSL == 0.0 || newSL > curSL + g_point*0.5)
            ModifySL(pos.Ticket(), newSL, pos.TakeProfit());
        }
     }
  }

//+------------------------------------------------------------------+
//| 撤销本 symbol+magic 所有持仓的 SL (回区间后)                    |
//+------------------------------------------------------------------+
void ClearAllSL()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!pos.SelectByIndex(i))    continue;
      if(pos.Symbol() != _Symbol)  continue;
      if(pos.Magic()  != InpMagic) continue;
      if(pos.StopLoss() != 0.0)
         ModifySL(pos.Ticket(), 0.0, pos.TakeProfit());
     }
  }

//+------------------------------------------------------------------+
//| 修改单个持仓的 SL                                               |
//+------------------------------------------------------------------+
void ModifySL(const ulong ticket, const double sl, const double tp)
  {
   if(!trade.PositionModify(ticket, sl, tp))
      PrintFormat("改SL失败 ticket=%I64u sl=%.5f retcode=%d err=%d",
                  ticket, sl, trade.ResultRetcode(), GetLastError());
  }

//+------------------------------------------------------------------+
//| 在当前价位画锁仓/解锁标记 (回测可视化时直观观察)               |
//|  isLock=true : 锁仓点, 红色向下箭头 + "LOCK"                    |
//|  isLock=false: 解锁点, 蓝色向上箭头 + "UNLOCK"                  |
//+------------------------------------------------------------------+
void DrawMark(const string tag, const bool isLock)
  {
   datetime t = TimeCurrent();
   double   p = isLock ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                       : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   string name = StringFormat("GT_%s_%d_%I64d", tag, g_lockCount, (long)t);

   // 箭头: 锁仓用向下(241), 解锁用向上(241/242) 这里用醒目的图标码
   ObjectCreate(0, name, OBJ_ARROW, 0, t, p);
   ObjectSetInteger(0, name, OBJPROP_ARROWCODE, isLock ? 251 : 252); // 251=×(锁), 252=√(解)
   ObjectSetInteger(0, name, OBJPROP_COLOR,     isLock ? clrRed : clrDeepSkyBlue);
   ObjectSetInteger(0, name, OBJPROP_WIDTH,     3);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR,    isLock ? ANCHOR_TOP : ANCHOR_BOTTOM);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);

   // 竖直虚线标出时刻, 更易定位
   string vname = name + "_v";
   ObjectCreate(0, vname, OBJ_VLINE, 0, t, 0);
   ObjectSetInteger(0, vname, OBJPROP_COLOR,     isLock ? clrRed : clrDeepSkyBlue);
   ObjectSetInteger(0, vname, OBJPROP_STYLE,     STYLE_DOT);
   ObjectSetInteger(0, vname, OBJPROP_WIDTH,     1);
   ObjectSetInteger(0, vname, OBJPROP_BACK,      true);
   ObjectSetInteger(0, vname, OBJPROP_SELECTABLE, false);
  }

//+------------------------------------------------------------------+
//| 净敞口手数 = 多单总手 - 空单总手 (仅本 symbol+magic, 排除对冲单) |
//+------------------------------------------------------------------+
double NetLots()
  {
   double net = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!pos.SelectByIndex(i))    continue;
      if(pos.Symbol() != _Symbol)  continue;
      if(pos.Magic()  != InpMagic) continue;
      if(pos.Ticket() == g_hedgeTicket) continue; // 不算已有对冲单
      if(pos.PositionType() == POSITION_TYPE_BUY) net += pos.Volume();
      else                                         net -= pos.Volume();
     }
   return(net);
  }

//+------------------------------------------------------------------+
//| 取刚开的对冲单 ticket(通过最近持仓中 Hedge Lock 注释定位)      |
//+------------------------------------------------------------------+
ulong PositionTicketByDeal()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!pos.SelectByIndex(i))    continue;
      if(pos.Symbol() != _Symbol)  continue;
      if(pos.Magic()  != InpMagic) continue;
      if(pos.Comment() == "Hedge Lock") return(pos.Ticket());
     }
   return(0);
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
