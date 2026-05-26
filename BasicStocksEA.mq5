//+------------------------------------------------------------------+
//| BasicStocksEA.mq5                                                |
//| Universal Basic Strategy for Stocks & Commodities               |
//|                                                                  |
//| Designed for: NAS100, SPX500, XAUUSD, XTIUSD (Oil), DE40       |
//| Apply one EA per chart. Each uses 1% account risk.              |
//|                                                                  |
//| Three strategy modes (select via StrategyMode input):           |
//|                                                                  |
//|  Mode 1 — EMA CROSSOVER (default, trend following)             |
//|    Entry:  EMA_Fast crosses EMA_Slow                            |
//|    Stop:   2 × ATR from entry                                   |
//|    Target: 3 × ATR from entry (R:R = 1.5)                      |
//|                                                                  |
//|  Mode 2 — RSI REVERSION (mean reversion)                       |
//|    Entry:  RSI < 30 → BUY,  RSI > 70 → SELL                   |
//|    Stop:   1.5 × ATR                                            |
//|    Target: RSI midpoint (50) = 2 × ATR from entry              |
//|                                                                  |
//|  Mode 3 — DONCHIAN BREAKOUT (momentum)                         |
//|    Entry:  Close breaks N-bar high/low                          |
//|    Stop:   1.5 × ATR trailing                                   |
//|    Target: 4 × ATR from entry                                   |
//|                                                                  |
//| Risk: 1% of balance per trade, ATR-based lot sizing             |
//+------------------------------------------------------------------+

#property copyright "Research — BasicStocksEA"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

CTrade Trade;

//── Strategy selection ────────────────────────────────────────────
enum STRATEGY_MODE {
   MODE_EMA_CROSS    = 1,    // EMA Fast/Slow crossover
   MODE_RSI_REVERT   = 2,    // RSI oversold/overbought
   MODE_DONCHIAN     = 3     // Donchian channel breakout
};

//── Inputs ────────────────────────────────────────────────────────
input group "=== STRATEGY ==="
input STRATEGY_MODE StrategyMode  = MODE_EMA_CROSS;  // Strategy to use

input group "=== MODE 1: EMA CROSSOVER ==="
input int    EmaFast        = 20;    // Fast EMA period
input int    EmaSlow        = 50;    // Slow EMA period

input group "=== MODE 2: RSI REVERSION ==="
input int    RsiPeriod      = 14;    // RSI period
input double RsiOversold    = 30.0;  // RSI buy threshold
input double RsiOverbought  = 70.0;  // RSI sell threshold
input bool   LongOnlyRSI    = true;  // Only take longs (stocks go up long term)

input group "=== MODE 3: DONCHIAN BREAKOUT ==="
input int    DonchianPeriod = 20;    // Lookback period for high/low

input group "=== RISK & ATR ==="
input int    AtrPeriod      = 14;    // ATR period
input double StopAtrMult    = 2.0;   // Stop = ATR × this
input double TpAtrMult      = 3.0;   // Take profit = ATR × this
input double RiskPct        = 1.0;   // % of balance per trade

input group "=== FILTERS ==="
input int    MaxSpreadPoints = 50;   // Skip if spread > this (wider for indices)
input int    TradeStartHour  = 9;    // Only trade from this UTC hour
input int    TradeEndHour    = 21;   // Only trade until this UTC hour

input group "=== EXECUTION ==="
input int    Magic           = 11003;
input int    MaxOpenTrades   = 1;    // Only 1 position per instrument

//+------------------------------------------------------------------+
int OnInit()
{
   Trade.SetExpertMagicNumber(Magic);
   Trade.SetDeviationInPoints(50);    // Wider for indices
   Trade.SetTypeFilling(ORDER_FILLING_IOC);

   string mode_str;
   switch(StrategyMode) {
      case MODE_EMA_CROSS:  mode_str = StringFormat("EMA Cross(%d/%d)", EmaFast, EmaSlow); break;
      case MODE_RSI_REVERT: mode_str = StringFormat("RSI Revert(%d)", RsiPeriod); break;
      case MODE_DONCHIAN:   mode_str = StringFormat("Donchian(%d)", DonchianPeriod); break;
   }
   Print(StringFormat("BasicStocksEA | %s | Risk=%.1f%%  Stop=%.1f×ATR  TP=%.1f×ATR",
                       mode_str, RiskPct, StopAtrMult, TpAtrMult));
   return INIT_SUCCEEDED;
}

//── Indicators ────────────────────────────────────────────────────

double GetEMA(int period, int shift = 0)
{
   double buf[]; ArraySetAsSeries(buf, true);
   int h = iMA(_Symbol, PERIOD_H1, period, 0, MODE_EMA, PRICE_CLOSE);
   if(h == INVALID_HANDLE) return 0;
   CopyBuffer(h, 0, shift, 1, buf);
   IndicatorRelease(h);
   return buf[0];
}

double GetRSI(int shift = 0)
{
   double buf[]; ArraySetAsSeries(buf, true);
   int h = iRSI(_Symbol, PERIOD_H1, RsiPeriod, PRICE_CLOSE);
   if(h == INVALID_HANDLE) return 50;
   CopyBuffer(h, 0, shift, 1, buf);
   IndicatorRelease(h);
   return buf[0];
}

double GetATR()
{
   double buf[]; ArraySetAsSeries(buf, true);
   int h = iATR(_Symbol, PERIOD_H1, AtrPeriod);
   if(h == INVALID_HANDLE) return 0;
   CopyBuffer(h, 0, 0, 1, buf);
   IndicatorRelease(h);
   return buf[0];
}

double GetDonchianHigh(int shift = 1)
{
   double buf[]; ArraySetAsSeries(buf, true);
   int h = iHighest(_Symbol, PERIOD_H1, MODE_HIGH, DonchianPeriod, shift);
   if(h < 0) return 0;
   double high[]; ArraySetAsSeries(high, true);
   CopyHigh(_Symbol, PERIOD_H1, shift, 1, high);
   // Get highest N bars
   double highs[]; ArraySetAsSeries(highs, true);
   CopyHigh(_Symbol, PERIOD_H1, shift, DonchianPeriod, highs);
   return highs[ArrayMaximum(highs)];
}

double GetDonchianLow(int shift = 1)
{
   double lows[]; ArraySetAsSeries(lows, true);
   CopyLow(_Symbol, PERIOD_H1, shift, DonchianPeriod, lows);
   return lows[ArrayMinimum(lows)];
}

//── Position management ───────────────────────────────────────────

int CountMyPositions()
{
   int n = 0;
   for(int i = 0; i < PositionsTotal(); i++) {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) == Magic &&
          PositionGetString(POSITION_SYMBOL) == _Symbol) n++;
   }
   return n;
}

bool HasPosition(int direction)  // 1=long, -1=short
{
   for(int i = 0; i < PositionsTotal(); i++) {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != Magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      int type = (int)PositionGetInteger(POSITION_TYPE);
      if(direction == 1  && type == POSITION_TYPE_BUY)  return true;
      if(direction == -1 && type == POSITION_TYPE_SELL) return true;
   }
   return false;
}

double CalcLots(double sl_price, bool is_buy)
{
   double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk_amt = balance * RiskPct / 100.0;
   double ask      = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid      = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double entry    = is_buy ? ask : bid;
   double sl_dist  = MathAbs(entry - sl_price);
   if(sl_dist == 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   double tick_val  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double lots = risk_amt / (sl_dist / tick_size * tick_val);

   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lots = MathFloor(lots / step) * step;
   return MathMax(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN),
          MathMin(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX), lots));
}

void OpenTrade(bool is_buy, double sl_price, double tp_price, string reason)
{
   int    digs = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double lots = CalcLots(sl_price, is_buy);

   if(is_buy) {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      Trade.Buy(lots, _Symbol, ask,
                NormalizeDouble(sl_price, digs),
                NormalizeDouble(tp_price, digs),
                reason);
   } else {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      Trade.Sell(lots, _Symbol, bid,
                 NormalizeDouble(sl_price, digs),
                 NormalizeDouble(tp_price, digs),
                 reason);
   }

   Print(StringFormat("%s | %s %.4f lots @ %.5f  SL=%.5f  TP=%.5f | %s",
         EnumToString(StrategyMode),
         is_buy ? "BUY" : "SELL", lots,
         is_buy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID),
         sl_price, tp_price, reason));
}

//── Bar tracker ───────────────────────────────────────────────────
datetime g_last_bar = 0;
bool IsNewBar()
{
   datetime t[];
   ArraySetAsSeries(t, true);
   CopyTime(_Symbol, PERIOD_H1, 0, 1, t);
   if(t[0] != g_last_bar) { g_last_bar = t[0]; return true; }
   return false;
}

//── Time filter ───────────────────────────────────────────────────
bool TradingHours()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   return dt.hour >= TradeStartHour && dt.hour < TradeEndHour;
}

bool SpreadOK()
{
   return SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) <= MaxSpreadPoints;
}

//+------------------------------------------------------------------+
void OnTick()
{
   if(!IsNewBar()) return;  // Only check on new H1 bar
   if(!TradingHours())     return;
   if(!SpreadOK())          return;
   if(CountMyPositions() >= MaxOpenTrades) return;

   double atr = GetATR();
   if(atr <= 0) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   //── Mode 1: EMA Crossover ─────────────────────────────────────
   if(StrategyMode == MODE_EMA_CROSS)
   {
      double fast_now  = GetEMA(EmaFast, 0);
      double slow_now  = GetEMA(EmaSlow, 0);
      double fast_prev = GetEMA(EmaFast, 1);
      double slow_prev = GetEMA(EmaSlow, 1);

      bool golden_cross = (fast_prev <= slow_prev && fast_now > slow_now);  // Bull
      bool death_cross  = (fast_prev >= slow_prev && fast_now < slow_now);  // Bear

      if(golden_cross && !HasPosition(1))
      {
         double sl = ask - atr * StopAtrMult;
         double tp = ask + atr * TpAtrMult;
         OpenTrade(true, sl, tp, StringFormat("EMA_BULL_%.0f/%.0f", EmaFast, EmaSlow));
      }
      else if(death_cross && !HasPosition(-1))
      {
         double sl = bid + atr * StopAtrMult;
         double tp = bid - atr * TpAtrMult;
         OpenTrade(false, sl, tp, StringFormat("EMA_BEAR_%.0f/%.0f", EmaFast, EmaSlow));
      }
   }

   //── Mode 2: RSI Mean Reversion ────────────────────────────────
   if(StrategyMode == MODE_RSI_REVERT)
   {
      double rsi_curr = GetRSI(0);
      double rsi_prev = GetRSI(1);

      // Buy: RSI was below oversold, now crossing back up
      bool rsi_buy  = (rsi_prev < RsiOversold  && rsi_curr >= RsiOversold);
      // Sell: RSI was above overbought, now crossing back down
      bool rsi_sell = (rsi_prev > RsiOverbought && rsi_curr <= RsiOverbought);

      if(rsi_buy && !HasPosition(1))
      {
         double sl = ask - atr * StopAtrMult;
         double tp = ask + atr * TpAtrMult;
         OpenTrade(true, sl, tp, StringFormat("RSI_BUY_%.0f", rsi_curr));
      }
      else if(rsi_sell && !LongOnlyRSI && !HasPosition(-1))
      {
         double sl = bid + atr * StopAtrMult;
         double tp = bid - atr * TpAtrMult;
         OpenTrade(false, sl, tp, StringFormat("RSI_SELL_%.0f", rsi_curr));
      }
   }

   //── Mode 3: Donchian Breakout ─────────────────────────────────
   if(StrategyMode == MODE_DONCHIAN)
   {
      double closes[2]; ArraySetAsSeries(closes, true);
      CopyClose(_Symbol, PERIOD_H1, 0, 2, closes);
      double close_now  = closes[0];
      double close_prev = closes[1];

      double don_high = GetDonchianHigh(1);  // N-bar high excluding current bar
      double don_low  = GetDonchianLow(1);   // N-bar low  excluding current bar

      bool breakout_up   = (close_prev <= don_high && close_now > don_high);
      bool breakout_down = (close_prev >= don_low  && close_now < don_low);

      if(breakout_up && !HasPosition(1))
      {
         double sl = ask - atr * StopAtrMult;
         double tp = ask + atr * TpAtrMult;
         OpenTrade(true, sl, tp, StringFormat("DON_UP_%.5f", don_high));
      }
      else if(breakout_down && !HasPosition(-1))
      {
         double sl = bid + atr * StopAtrMult;
         double tp = bid - atr * TpAtrMult;
         OpenTrade(false, sl, tp, StringFormat("DON_DOWN_%.5f", don_low));
      }
   }
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Comment("");
   Print("BasicStocksEA stopped.");
}
//+------------------------------------------------------------------+
