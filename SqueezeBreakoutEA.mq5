//+------------------------------------------------------------------+
//| SqueezeBreakoutEA.mq5                                            |
//| Bollinger Squeeze Breakout - Rank #5 EURUSD (Sharpe 4.51)       |
//| Squeeze then N-bar high/low breakout with EMA200 filter.        |
//+------------------------------------------------------------------+
#property copyright "Research"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
CTrade g_trade;

input group "=== SIZING ==="
input double InpRiskPct   = 0.25;    // Risk % per trade
input group "=== SIGNAL ==="
input int    InpBBLen     = 20;      // Bollinger period
input double InpBBDev     = 2.0;     // Bollinger deviations
input int    InpSqzLookbk = 100;     // Bars to assess squeeze percentile
input double InpSqzPct    = 0.20;    // BB width below this percentile = squeeze
input int    InpBreakBars = 20;      // N-bar high/low breakout
input double InpSLATR     = 2.0;     // SL = N * ATR
input double InpTPR       = 2.0;     // TP = N * SL
input group "=== SESSION (UTC) ==="
input int    InpSessStart = 7;       // Session start hour UTC
input int    InpSessEnd   = 17;      // Session end hour UTC
input group "=== PROP SAFETY ==="
input double InpDailyDD   = 4.0;     // Max daily loss %
input double InpTotalDD   = 8.0;     // Max total drawdown %
input int    InpMagic     = 88305;   // Magic number

datetime g_last_bar = 0;
datetime g_last_day = 0;
double   g_day_bal  = 0;
double   g_peak_eq  = 0;

int OnInit()
{
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(50);
   g_trade.SetTypeFilling(ORDER_FILLING_IOC);
   g_peak_eq = AccountInfoDouble(ACCOUNT_BALANCE);
   g_day_bal = g_peak_eq;
   Print("SqueezeBreakoutEA started | ", _Symbol);
   return(INIT_SUCCEEDED);
}

bool HasPos()
{
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol) return(true);
   }
   return(false);
}

bool SessOK()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_week == 0 || dt.day_of_week == 6) return(false);
   if(dt.day_of_week == 5 && dt.hour >= 14) return(false);
   return(dt.hour >= InpSessStart && dt.hour < InpSessEnd);
}

bool RiskOK()
{
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   if(bal > g_peak_eq) g_peak_eq = bal;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   datetime today = (datetime)(TimeCurrent() - dt.hour*3600 - dt.min*60 - dt.sec);
   if(today != g_last_day) { g_last_day = today; g_day_bal = bal; }
   double wst = MathMin(bal, eq);
   if(g_day_bal > 0 && (g_day_bal - wst)/g_day_bal*100.0 >= InpDailyDD) return(false);
   if(g_peak_eq > 0 && (g_peak_eq - wst)/g_peak_eq*100.0 >= InpTotalDD) return(false);
   return(true);
}

double CalcLot(double sl_dist)
{
   double risk = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPct / 100.0;
   double tv   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double ts   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(sl_dist <= 0 || tv <= 0 || ts <= 0) return(0);
   double lot  = risk / (sl_dist / ts * tv);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot = MathFloor(lot / step) * step;
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   return(MathMax(MathMin(lot, vmax), vmin));
}

double GetATR()
{
   double buf[];
   ArraySetAsSeries(buf, true);
   int handle = iATR(_Symbol, PERIOD_H1, 14);
   if(handle == INVALID_HANDLE) return(0);
   int copied = CopyBuffer(handle, 0, 1, 1, buf);
   IndicatorRelease(handle);
   return(copied >= 1 ? buf[0] : 0);
}

double GetEMA200()
{
   double buf[];
   ArraySetAsSeries(buf, true);
   int handle = iMA(_Symbol, PERIOD_H1, 200, 0, MODE_EMA, PRICE_CLOSE);
   if(handle == INVALID_HANDLE) return(0);
   int copied = CopyBuffer(handle, 0, 1, 1, buf);
   IndicatorRelease(handle);
   return(copied >= 1 ? buf[0] : 0);
}

bool IsSqueeze(int bar_idx)
{
   int need = InpSqzLookbk + bar_idx + 2;
   double bb_up[], bb_lo[], bb_mid[];
   ArraySetAsSeries(bb_up,  true);
   ArraySetAsSeries(bb_lo,  true);
   ArraySetAsSeries(bb_mid, true);
   int handle = iBands(_Symbol, PERIOD_H1, InpBBLen, 0, InpBBDev, PRICE_CLOSE);
   if(handle == INVALID_HANDLE) return(false);
   int cp1 = CopyBuffer(handle, 1, bar_idx, need, bb_up);
   int cp2 = CopyBuffer(handle, 2, bar_idx, need, bb_lo);
   int cp3 = CopyBuffer(handle, 0, bar_idx, need, bb_mid);
   IndicatorRelease(handle);
   if(cp1 < need || cp2 < need || cp3 < need) return(false);

   double mid0 = bb_mid[0];
   if(mid0 <= 0) return(false);
   double bbw_cur = (bb_up[0] - bb_lo[0]) / mid0;

   double bbw_hist[];
   ArrayResize(bbw_hist, InpSqzLookbk);
   for(int i = 0; i < InpSqzLookbk; i++)
   {
      double m = bb_mid[i+1];
      bbw_hist[i] = (m > 0) ? (bb_up[i+1] - bb_lo[i+1]) / m : 0;
   }
   ArraySort(bbw_hist);
   double threshold = bbw_hist[(int)(InpSqzLookbk * InpSqzPct)];
   return(bbw_cur < threshold);
}

void OnTick()
{
   if(!RiskOK() || HasPos() || !SessOK()) return;
   datetime bar0 = iTime(_Symbol, PERIOD_H1, 0);
   if(bar0 == g_last_bar) return;
   g_last_bar = bar0;

   if(!IsSqueeze(2)) return;

   double ema200 = GetEMA200();
   if(ema200 <= 0) return;

   double atr = GetATR();
   if(atr <= 0) return;

   double close1 = iClose(_Symbol, PERIOD_H1, 1);
   double hi_n = 0, lo_n = DBL_MAX;
   for(int i = 2; i <= InpBreakBars + 1; i++)
   {
      hi_n = MathMax(hi_n, iHigh(_Symbol, PERIOD_H1, i));
      lo_n = MathMin(lo_n, iLow (_Symbol, PERIOD_H1, i));
   }

   int sig = 0;
   if(close1 > hi_n && close1 > ema200) sig =  1;
   if(close1 < lo_n && close1 < ema200) sig = -1;
   if(sig == 0) return;

   int    digs = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double sl_d = atr * InpSLATR;
   double lot  = CalcLot(sl_d);
   if(lot <= 0) return;

   if(sig == 1)
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      g_trade.Buy(lot, _Symbol, ask,
                  NormalizeDouble(ask - sl_d, digs),
                  NormalizeDouble(ask + sl_d * InpTPR, digs), "SqzBk_L");
   }
   else
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      g_trade.Sell(lot, _Symbol, bid,
                   NormalizeDouble(bid + sl_d, digs),
                   NormalizeDouble(bid - sl_d * InpTPR, digs), "SqzBk_S");
   }
}

void OnDeinit(const int reason)
{
   Print("SqueezeBreakoutEA stopped | ", _Symbol);
}
