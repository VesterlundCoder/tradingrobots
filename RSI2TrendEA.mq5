//+------------------------------------------------------------------+
//| RSI2TrendEA.mq5                                                  |
//| RSI-2 Pullback in Trend - Rank #2 USDCAD (Sharpe 4.69, DD -3%) |
//| 1H chart. Long: above EMA200, RSI(2) dips <10.                  |
//+------------------------------------------------------------------+
#property copyright "Research"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
CTrade g_trade;

input group "=== SIZING ==="
input double InpRiskPct    = 0.25;   // Risk % per trade
input group "=== SIGNAL ==="
input int    InpEMALen     = 200;    // EMA trend filter period
input int    InpRSILevel   = 10;     // RSI2 entry threshold
input double InpSLATR      = 2.0;    // SL = N * ATR
input double InpTPR        = 2.0;    // TP = N * SL
input group "=== SESSION (UTC) ==="
input int    InpSessStart  = 7;      // Session start hour UTC
input int    InpSessEnd    = 17;     // Session end hour UTC
input group "=== PROP SAFETY ==="
input double InpDailyDD    = 4.0;    // Max daily loss %
input double InpTotalDD    = 8.0;    // Max total drawdown %
input int    InpMagic      = 88302;  // Magic number

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
   Print("RSI2TrendEA started | ", _Symbol);
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

double GetEMA()
{
   double buf[];
   ArraySetAsSeries(buf, true);
   int handle = iMA(_Symbol, PERIOD_H1, InpEMALen, 0, MODE_EMA, PRICE_CLOSE);
   if(handle == INVALID_HANDLE) return(0);
   int copied = CopyBuffer(handle, 0, 1, 1, buf);
   IndicatorRelease(handle);
   return(copied >= 1 ? buf[0] : 0);
}

bool GetRSI2(double &rsi1, double &rsi2)
{
   double buf[];
   ArraySetAsSeries(buf, true);
   int handle = iRSI(_Symbol, PERIOD_H1, 2, PRICE_CLOSE);
   if(handle == INVALID_HANDLE) return(false);
   int copied = CopyBuffer(handle, 0, 1, 2, buf);
   IndicatorRelease(handle);
   if(copied < 2) return(false);
   rsi1 = buf[0];
   rsi2 = buf[1];
   return(true);
}

void OnTick()
{
   if(!RiskOK() || HasPos() || !SessOK()) return;
   datetime bar0 = iTime(_Symbol, PERIOD_H1, 0);
   if(bar0 == g_last_bar) return;
   g_last_bar = bar0;

   double rsi1 = 0, rsi2 = 0;
   if(!GetRSI2(rsi1, rsi2)) return;

   double ema200 = GetEMA();
   if(ema200 <= 0) return;

   double atr = GetATR();
   if(atr <= 0) return;

   double close1 = iClose(_Symbol, PERIOD_H1, 1);
   int sig = 0;
   if(close1 > ema200 && rsi1 < InpRSILevel         && rsi2 >= InpRSILevel)          sig =  1;
   if(close1 < ema200 && rsi1 > (100-InpRSILevel)   && rsi2 <= (100-InpRSILevel))    sig = -1;
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
                  NormalizeDouble(ask + sl_d * InpTPR, digs), "RSI2T_L");
   }
   else
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      g_trade.Sell(lot, _Symbol, bid,
                   NormalizeDouble(bid + sl_d, digs),
                   NormalizeDouble(bid - sl_d * InpTPR, digs), "RSI2T_S");
   }
}

void OnDeinit(const int reason)
{
   Print("RSI2TrendEA stopped | ", _Symbol);
}
