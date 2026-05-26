//+------------------------------------------------------------------+
//| AsianRangeBreakoutEA.mq5                                         |
//| Asian Session Range Breakout — Rank #3 USDCAD (Sharpe 4.49)    |
//| Asian range: 00:00-08:00 UTC. Entry: London 08:00-17:00 UTC.    |
//| Max 1 trade per day.                                             |
//+------------------------------------------------------------------+
#include <Trade\Trade.mqh>
CTrade g_trade;

input group "=== SIZING ==="
input double InpRiskPct   = 0.25;
input group "=== SIGNAL ==="
input int    InpAsianEnd  = 8;       // UTC hour Asian session ends
input double InpBufPips   = 0.5;     // Breakout buffer in pips
input double InpSLATR     = 2.0;
input double InpTPR       = 2.0;
input group "=== SESSION (UTC) ==="
input int    InpSessStart = 8;
input int    InpSessEnd   = 17;
input group "=== PROP SAFETY ==="
input double InpDailyDD   = 4.0;
input double InpTotalDD   = 8.0;
input int    InpMagic     = 88303;

int  h_atr;
datetime g_last_bar = 0, g_last_day = 0, g_last_trade_day = 0;
double   g_day_bal, g_peak_eq;
double   g_asian_h, g_asian_l;
bool     g_asian_ready;

int OnInit() {
   h_atr = iATR(_Symbol, PERIOD_H1, 14);
   if(h_atr == INVALID_HANDLE) return INIT_FAILED;
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(50);
   g_trade.SetTypeFilling(ORDER_FILLING_IOC);
   g_peak_eq     = AccountInfoDouble(ACCOUNT_BALANCE);
   g_day_bal     = g_peak_eq;
   g_asian_h     = 0; g_asian_l = DBL_MAX; g_asian_ready = false;
   Print("AsianRangeBreakoutEA started | ", _Symbol);
   return INIT_SUCCEEDED;
}

bool HasPos() {
   for(int i = 0; i < PositionsTotal(); i++) {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol) return true;
   }
   return false;
}

bool RiskOK() {
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   g_peak_eq  = MathMax(g_peak_eq, bal);
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   datetime today = (datetime)(TimeCurrent() - dt.hour*3600 - dt.min*60 - dt.sec);
   if(today != g_last_day) {
      g_last_day = today;
      g_day_bal  = bal;
      g_asian_h  = 0; g_asian_l = DBL_MAX; g_asian_ready = false;
   }
   double wst = MathMin(bal, eq);
   if((g_day_bal - wst) / g_day_bal * 100.0 >= InpDailyDD) return false;
   if((g_peak_eq - wst) / g_peak_eq * 100.0 >= InpTotalDD) return false;
   return true;
}

double CalcLot(double sl_dist) {
   double risk = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPct / 100.0;
   double tv   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double ts   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(sl_dist <= 0 || tv <= 0 || ts <= 0) return 0;
   double lot  = risk / (sl_dist / ts * tv);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot = MathFloor(lot / step) * step;
   return MathMax(MathMin(lot, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX)),
                  SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN));
}

void UpdateAsianRange() {
   MqlDateTime dt; TimeToStruct(iTime(_Symbol, PERIOD_H1, 1), dt);
   int hour1 = dt.hour;
   // Accumulate Asian bars (hour 0 to InpAsianEnd-1)
   if(hour1 < InpAsianEnd) {
      double h = iHigh(_Symbol, PERIOD_H1, 1);
      double l = iLow (_Symbol, PERIOD_H1, 1);
      g_asian_h = MathMax(g_asian_h, h);
      g_asian_l = MathMin(g_asian_l, l);
   }
   // Mark ready once London starts
   if(hour1 == InpAsianEnd && g_asian_h > g_asian_l && g_asian_l < DBL_MAX)
      g_asian_ready = true;
}

void OnTick() {
   if(!RiskOK()) return;
   datetime bar0 = iTime(_Symbol, PERIOD_H1, 0);
   if(bar0 == g_last_bar) return;
   g_last_bar = bar0;

   UpdateAsianRange();
   if(!g_asian_ready) return;

   // Only one trade per day
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_week == 0 || dt.day_of_week == 6) return;
   if(dt.day_of_week == 5 && dt.hour >= 14) return;
   if(dt.hour < InpSessStart || dt.hour >= InpSessEnd) return;
   datetime today = (datetime)(TimeCurrent() - dt.hour*3600 - dt.min*60 - dt.sec);
   if(today == g_last_trade_day) return;
   if(HasPos()) return;

   double atr_buf[2]; ArraySetAsSeries(atr_buf, true);
   if(CopyBuffer(h_atr, 0, 1, 2, atr_buf) < 2) return;
   double atr = atr_buf[0];

   // Pip size
   int    digs  = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double pt    = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double pip   = (digs == 3 || digs == 5) ? pt * 10.0 : pt;
   double buf   = InpBufPips * pip;

   double close1 = iClose(_Symbol, PERIOD_H1, 1);
   int sig = 0;
   if(close1 > g_asian_h + buf) sig =  1;
   if(close1 < g_asian_l - buf) sig = -1;
   if(sig == 0) return;

   double sl_d = atr * InpSLATR;
   double lot  = CalcLot(sl_d);
   if(lot <= 0) return;

   bool ok = false;
   if(sig == 1) {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      ok = g_trade.Buy(lot, _Symbol, ask,
                       NormalizeDouble(ask - sl_d, digs),
                       NormalizeDouble(ask + sl_d * InpTPR, digs), "AsianBk_L");
   } else {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      ok = g_trade.Sell(lot, _Symbol, bid,
                        NormalizeDouble(bid + sl_d, digs),
                        NormalizeDouble(bid - sl_d * InpTPR, digs), "AsianBk_S");
   }
   if(ok) g_last_trade_day = today;
}

void OnDeinit(const int reason) { IndicatorRelease(h_atr); }
