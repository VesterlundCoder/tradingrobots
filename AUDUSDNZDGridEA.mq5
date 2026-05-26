//+------------------------------------------------------------------+
//|  AUDUSDNZDGridEA.mq5                                             |
//|  Grid / Martingale on AUDUSD + NZDUSD                            |
//|                                                                  |
//|  Designed from PAMM real-trade analysis (10 471 trades):         |
//|    AUDUSD: win rate 79.3%, +$59k net                             |
//|    NZDUSD: win rate 67.3%, +$42k net                             |
//|                                                                  |
//|  Key calibrations vs generic grid robots:                        |
//|   1. TP = 12 pips (PAMM2 style — take profits fast)             |
//|   2. Grid step = 16 pips (median grid spacing from real data)   |
//|   3. Max 4 grid levels (PAMM max streak was 40 → cap exposure)  |
//|   4. Max hold = 21h (2× median win hold; losses held 14× more)  |
//|   5. Session filter: London+NY only (08-22). Asia = -$64k       |
//|   6. Per-symbol loss streak cooldown (2 basket losses → 24h off)|
//|   7. EMA200 + RSI filter on entries                              |
//|   8. Lot scaling = 1.5× (confirmed from lot proxy analysis)     |
//|   9. No correlation: max 1 basket open simultaneously           |
//|      (AUDUSD and NZDUSD move together — never both at once)     |
//|                                                                  |
//|  Attach to: any chart (EA runs on both symbols internally)       |
//|  Timeframe: H1                                                   |
//|  Demo account only until validated.                              |
//+------------------------------------------------------------------+

#property copyright "AUDUSDNZDGridEA — tuned from PAMM real-data analysis"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

CTrade        Trade;
CPositionInfo PosInfo;

//+------------------------------------------------------------------+
//|  Inputs                                                          |
//+------------------------------------------------------------------+

input group "=== SYMBOL SELECTION ==="
input bool   TradeAUDUSD    = true;    // Trade AUDUSD (win rate 79.3% in data)
input bool   TradeNZDUSD    = true;    // Trade NZDUSD (win rate 67.3% in data)

input group "=== GRID PARAMETERS (calibrated from 10k real trades) ==="
input double GridPips        = 16.0;   // Grid spacing pips (median from real data)
input double TakeProfitPips  = 12.0;   // TP pips on weighted avg — PAMM2 style (fast exit)
input double StartLots       = 0.01;   // Initial lot size
input double LotMultiplier   = 1.5;    // Martingale multiplier (1.5× confirmed from data)
input int    MaxGridLevels   = 4;      // Hard cap at 4 levels (safety — PAMM streaks hit 40)
input int    BreakoutBars    = 20;     // N-bar breakout signal window (H1)

input group "=== RISK MANAGEMENT ==="
input double MaxBasketLossPct   = 2.0;   // Force-close if floating loss > X% equity
input double MaxAccountDDPct    = 20.0;  // Circuit breaker: stop all if account DD > X%
input int    MaxHoldHours       = 21;    // Force-close basket after N hours (2× median win)
input bool   UseTrailingStop    = true;  // Lock in profits — trail basket weighted avg
input double TrailActivatePips  = 8.0;   // Activate trailing once weighted avg exceeds this
input double TrailDistancePips  = 4.0;   // Close basket if weighted avg drops this far from peak

input group "=== CORRELATION GUARD ==="
input int    MaxSimultaneous    = 1;     // Max baskets open at same time (AUDUSD+NZDUSD correlated!)

input group "=== ENTRY FILTERS ==="
input bool   UseEmaFilter       = true;  // Only trade in EMA200 direction
input int    EmaPeriod          = 200;
input bool   UseRsiFilter       = true;  // Skip extreme RSI
input int    RsiPeriod          = 14;
input double RsiOverbought      = 70.0;
input double RsiOversold        = 30.0;
input int    MaxSpreadPoints    = 25;    // Skip if spread too wide

input group "=== SESSION FILTER (Asia session = -$64k in real data) ==="
input bool   UseSessionFilter   = true;
input int    SessionStart       = 8;     // London open (broker time)
input int    SessionEnd         = 22;    // End of NY session
input bool   NoFriAfter20       = true;  // No new entries Friday after 20:00

input group "=== LOSS STREAK FILTER ==="
input bool   UseLossStreakFilter = true;
input int    MaxConsecLosses     = 2;    // Pause symbol after N losing baskets
input int    CooldownHours       = 24;   // Hours to pause per symbol

input group "=== IDENTIFICATION ==="
input int    MagicNumber        = 20260521;

//+------------------------------------------------------------------+
//|  Globals                                                         |
//+------------------------------------------------------------------+

string   Symbols[];
int      NSymbols        = 0;
double   InitialEquity   = 0;
bool     CircuitTripped  = false;

datetime BasketOpenTime[];
int      ConsecLosses[];
datetime CooldownUntil[];
double   BasketPeakPips[];   // trailing stop high-water mark per symbol

//+------------------------------------------------------------------+
//|  OnInit                                                          |
//+------------------------------------------------------------------+

int OnInit()
{
   Trade.SetExpertMagicNumber(MagicNumber);
   Trade.SetDeviationInPoints(20);
   ENUM_ORDER_TYPE_FILLING fill = (ENUM_ORDER_TYPE_FILLING)
      (int)SymbolInfoInteger(Symbol(), SYMBOL_FILLING_MODE);
   if((fill & ORDER_FILLING_FOK) != 0)       Trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((fill & ORDER_FILLING_IOC) != 0)  Trade.SetTypeFilling(ORDER_FILLING_IOC);
   else                                       Trade.SetTypeFilling(ORDER_FILLING_RETURN);

   InitialEquity = AccountInfoDouble(ACCOUNT_EQUITY);

   int n = 0;
   string cands[] = {"AUDUSD", "NZDUSD"};
   bool   active[] = {TradeAUDUSD, TradeNZDUSD};
   ArrayResize(Symbols, 2);
   for(int i = 0; i < 2; i++)
      if(active[i])
      {
         // Verify symbol exists
         if(!SymbolSelect(cands[i], true))
         {
            Print("WARNING: ", cands[i], " not found in Market Watch — skipping");
            continue;
         }
         Symbols[n++] = cands[i];
      }
   NSymbols = n;
   ArrayResize(Symbols,       NSymbols);
   ArrayResize(BasketOpenTime,  NSymbols);
   ArrayResize(ConsecLosses,    NSymbols);
   ArrayResize(CooldownUntil,   NSymbols);
   ArrayResize(BasketPeakPips,  NSymbols);
   ArrayInitialize(BasketOpenTime, 0);
   ArrayInitialize(ConsecLosses,   0);
   ArrayInitialize(CooldownUntil,  0);
   ArrayInitialize(BasketPeakPips, -999);

   Print(StringFormat(
      "AUDUSDNZDGridEA started | Symbols=%d [%s] | GridPips=%.1f TP=%.1f | "
      "MaxLevels=%d MaxHold=%dh | Session=%d-%d | Magic=%d",
      NSymbols, (NSymbols==2 ? "AUDUSD+NZDUSD" : (NSymbols==1 ? Symbols[0] : "none")),
      GridPips, TakeProfitPips, MaxGridLevels, MaxHoldHours,
      SessionStart, SessionEnd, MagicNumber));

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//|  OnTick                                                          |
//+------------------------------------------------------------------+

void OnTick()
{
   if(CircuitTripped) return;

   // Account-wide circuit breaker
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double dd      = (InitialEquity - equity) / InitialEquity * 100.0;
   if(dd > MaxAccountDDPct)
   {
      CloseAll("CIRCUIT_BREAKER");
      CircuitTripped = true;
      Print(StringFormat("CIRCUIT BREAKER: DD=%.1f%% > %.1f%% — all positions closed", dd, MaxAccountDDPct));
      return;
   }

   for(int s = 0; s < NSymbols; s++)
      ProcessSymbol(Symbols[s], s);
}

//+------------------------------------------------------------------+
//|  ProcessSymbol                                                   |
//+------------------------------------------------------------------+

void ProcessSymbol(string sym, int idx)
{
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double pip = GetPipSize(sym);
   if(bid <= 0 || pip <= 0) return;

   int basketSize = CountBasket(sym);

   if(basketSize > 0)
   {
      // ── Manage open basket ─────────────────────────────────────────
      double wavgPips = WeightedAvgPips(sym, pip);
      double floatUSD = BasketFloatUSD(sym);
      double eq       = AccountInfoDouble(ACCOUNT_EQUITY);
      int    holdH    = (BasketOpenTime[idx] > 0) ?
                        (int)((TimeCurrent() - BasketOpenTime[idx]) / 3600) : 0;
      int    dir      = BasketDirection(sym);

      // Take profit: weighted avg in profit by TakeProfitPips
      if(wavgPips >= TakeProfitPips)
      { CloseBasket(sym, "TP", idx); return; }

      // Basket trailing stop — lock in profits before reversal wipes them
      if(UseTrailingStop)
      {
         if(wavgPips > BasketPeakPips[idx])
            BasketPeakPips[idx] = wavgPips;  // raise high-water mark

         if(BasketPeakPips[idx] >= TrailActivatePips &&
            wavgPips <= BasketPeakPips[idx] - TrailDistancePips)
         {
            CloseBasket(sym, StringFormat("TRAIL peak=%.1f cur=%.1f",
                        BasketPeakPips[idx], wavgPips), idx);
            return;
         }
      }

      // Hard size cap
      if(basketSize >= MaxGridLevels)
      { CloseBasket(sym, "MAX_LEVELS", idx); return; }

      // Basket drawdown limit
      if(MaxBasketLossPct > 0 && eq > 0)
         if(floatUSD / eq < -(MaxBasketLossPct / 100.0))
         { CloseBasket(sym, "BASKET_DD", idx); return; }

      // Max hold time (21h default — 2× median win from real data)
      if(MaxHoldHours > 0 && holdH >= MaxHoldHours)
      { CloseBasket(sym, StringFormat("TIMEOUT_%dh", holdH), idx); return; }

      // Add next grid level if price moved GridPips against last entry
      if(basketSize < MaxGridLevels)
      {
         double lastPrice = LastPositionPrice(sym);
         double curPrice  = (dir == 1) ? bid : ask;
         double movePips  = (lastPrice - curPrice) * dir / pip;

         if(movePips >= GridPips)
         {
            double nextLots = NextLots(sym);
            string cmt      = StringFormat("Grid+%d_%.5f", basketSize + 1, curPrice);
            if(dir == 1) Trade.Buy(nextLots,  sym, ask, 0, 0, cmt);
            else         Trade.Sell(nextLots, sym, bid, 0, 0, cmt);
         }
      }
   }
   else
   {
      // ── Look for new basket entry ──────────────────────────────────

      // Correlation guard: never open more than MaxSimultaneous baskets
      if(CountAllBaskets() >= MaxSimultaneous) return;

      // Session filter
      if(UseSessionFilter && !SessionOK()) return;

      // Spread filter
      if(SymbolInfoInteger(sym, SYMBOL_SPREAD) > MaxSpreadPoints) return;

      // Loss streak cooldown
      if(UseLossStreakFilter && TimeCurrent() < CooldownUntil[idx])
      {
         int h = (int)((CooldownUntil[idx] - TimeCurrent()) / 3600);
         Print(sym, " loss-streak cooldown: ", h, "h remaining");
         return;
      }

      // Breakout signal
      int signal = BreakoutSignal(sym, BreakoutBars);
      if(signal == 0) return;

      // EMA200 trend alignment
      if(UseEmaFilter)
      {
         double emaBuf[];
         ArraySetAsSeries(emaBuf, true);
         int h = iMA(sym, PERIOD_H1, EmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
         if(h != INVALID_HANDLE && CopyBuffer(h, 0, 0, 1, emaBuf) == 1)
         {
            double mid = (bid + ask) / 2.0;
            IndicatorRelease(h);
            if(signal == +1 && mid < emaBuf[0]) return;  // don't buy below EMA
            if(signal == -1 && mid > emaBuf[0]) return;  // don't sell above EMA
         }
      }

      // RSI filter
      if(UseRsiFilter)
      {
         double rsiBuf[];
         ArraySetAsSeries(rsiBuf, true);
         int h = iRSI(sym, PERIOD_H1, RsiPeriod, PRICE_CLOSE);
         if(h != INVALID_HANDLE && CopyBuffer(h, 0, 0, 1, rsiBuf) == 1)
         {
            double r = rsiBuf[0];
            IndicatorRelease(h);
            if(signal == +1 && r > RsiOverbought) return;
            if(signal == -1 && r < RsiOversold)   return;
         }
      }

      // Fire entry
      string cmt = StringFormat("L0_%s_z%.5f", (signal==1?"BUY":"SELL"), bid);
      bool ok = (signal == 1) ? Trade.Buy(StartLots,  sym, ask, 0, 0, cmt)
                               : Trade.Sell(StartLots, sym, bid, 0, 0, cmt);
      if(ok)
      {
         BasketOpenTime[idx] = TimeCurrent();
         Print(StringFormat("ENTRY [%s] %s %.2f lots @ %.5f | session=%d:%02d",
               sym, (signal==1?"BUY":"SELL"), StartLots,
               (signal==1 ? ask : bid),
               GetHour(), GetMinute()));
      }
   }
}

//+------------------------------------------------------------------+
//|  Breakout signal: N-bar H1 high/low                              |
//+------------------------------------------------------------------+

int BreakoutSignal(string sym, int bars)
{
   double highs[], lows[];
   ArraySetAsSeries(highs, true);
   ArraySetAsSeries(lows, true);
   if(CopyHigh(sym, PERIOD_H1, 1, bars, highs) < bars) return 0;
   if(CopyLow(sym,  PERIOD_H1, 1, bars, lows)  < bars) return 0;

   double curHigh = iHigh(sym, PERIOD_H1, 0);
   double curLow  = iLow(sym,  PERIOD_H1, 0);
   double pip     = GetPipSize(sym);

   double hiMax = highs[ArrayMaximum(highs, 0, bars)];
   double loMin = lows[ArrayMinimum(lows,   0, bars)];

   if(curHigh > hiMax + pip) return +1;
   if(curLow  < loMin - pip) return -1;
   return 0;
}

//+------------------------------------------------------------------+
//|  Basket helpers                                                  |
//+------------------------------------------------------------------+

int CountBasket(string sym)
{
   int count = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
      if(PosInfo.SelectByIndex(i))
         if(PosInfo.Symbol() == sym && PosInfo.Magic() == MagicNumber)
            count++;
   return count;
}

int CountAllBaskets()
{
   int count = 0;
   for(int s = 0; s < NSymbols; s++)
      if(CountBasket(Symbols[s]) > 0) count++;
   return count;
}

int BasketDirection(string sym)
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
      if(PosInfo.SelectByIndex(i))
         if(PosInfo.Symbol() == sym && PosInfo.Magic() == MagicNumber)
            return (PosInfo.PositionType() == POSITION_TYPE_BUY) ? 1 : -1;
   return 0;
}

double WeightedAvgPips(string sym, double pip)
{
   double totalLots = 0, weightedPL = 0;
   double curPrice = SymbolInfoDouble(sym, SYMBOL_BID);
   for(int i = PositionsTotal()-1; i >= 0; i--)
      if(PosInfo.SelectByIndex(i))
         if(PosInfo.Symbol() == sym && PosInfo.Magic() == MagicNumber)
         {
            double lots  = PosInfo.Volume();
            int    dir   = (PosInfo.PositionType() == POSITION_TYPE_BUY) ? 1 : -1;
            double pips  = (curPrice - PosInfo.PriceOpen()) * dir / pip;
            weightedPL  += pips * lots;
            totalLots   += lots;
         }
   return (totalLots > 0) ? (weightedPL / totalLots) : 0;
}

double BasketFloatUSD(string sym)
{
   double total = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
      if(PosInfo.SelectByIndex(i))
         if(PosInfo.Symbol() == sym && PosInfo.Magic() == MagicNumber)
            total += PosInfo.Profit() + PosInfo.Swap();
   return total;
}

double LastPositionPrice(string sym)
{
   double lastPrice = 0;
   datetime lastTime = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
      if(PosInfo.SelectByIndex(i))
         if(PosInfo.Symbol() == sym && PosInfo.Magic() == MagicNumber)
            if(PosInfo.Time() >= lastTime)
            { lastTime = PosInfo.Time(); lastPrice = PosInfo.PriceOpen(); }
   return lastPrice;
}

double NextLots(string sym)
{
   double maxLots = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
      if(PosInfo.SelectByIndex(i))
         if(PosInfo.Symbol() == sym && PosInfo.Magic() == MagicNumber)
            maxLots = MathMax(maxLots, PosInfo.Volume());
   double next    = (maxLots > 0) ? maxLots * LotMultiplier : StartLots;
   double lotStep = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   next = MathRound(next / lotStep) * lotStep;
   return MathMax(SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN),
          MathMin(SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX), next));
}

void CloseBasket(string sym, string reason, int idx)
{
   double totalPnl = 0;
   int    count    = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
      if(PosInfo.SelectByIndex(i))
         if(PosInfo.Symbol() == sym && PosInfo.Magic() == MagicNumber)
         {
            totalPnl += PosInfo.Profit() + PosInfo.Swap();
            count++;
            Trade.PositionClose(PosInfo.Ticket());
         }

   BasketOpenTime[idx] = 0;
   BasketPeakPips[idx]  = -999;  // reset high-water mark

   // Loss streak tracking
   if(UseLossStreakFilter)
   {
      if(totalPnl < 0)
      {
         ConsecLosses[idx]++;
         if(ConsecLosses[idx] >= MaxConsecLosses)
         {
            CooldownUntil[idx] = TimeCurrent() + CooldownHours * 3600;
            Print(StringFormat("[%s] Loss streak %d — cooldown %dh until %s",
                  sym, ConsecLosses[idx], CooldownHours,
                  TimeToString(CooldownUntil[idx])));
         }
      }
      else { ConsecLosses[idx] = 0; }
   }

   Print(StringFormat("Closed [%s] %s | n=%d | PnL=$%.2f | streak=%d",
         sym, reason, count, totalPnl, ConsecLosses[idx]));
}

void CloseAll(string reason)
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
      if(PosInfo.SelectByIndex(i))
         if(PosInfo.Magic() == MagicNumber)
            Trade.PositionClose(PosInfo.Ticket());
   Print("CloseAll: ", reason);
}

//+------------------------------------------------------------------+
//|  Utility helpers                                                 |
//+------------------------------------------------------------------+

double GetPipSize(string sym)
{
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double pt  = SymbolInfoDouble(sym, SYMBOL_POINT);
   return (digits == 5 || digits == 3) ? pt * 10 : pt;
}

bool SessionOK()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int h   = dt.hour;
   int dow = dt.day_of_week;
   if(dow == 0 || dow == 6) return false;
   if(NoFriAfter20 && dow == 5 && h >= 20) return false;
   return (h >= SessionStart && h < SessionEnd);
}

int GetHour()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt); return dt.hour;
}
int GetMinute()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt); return dt.min;
}

//+------------------------------------------------------------------+
//|  OnDeinit                                                        |
//+------------------------------------------------------------------+

void OnDeinit(const int reason)
{
   Print(StringFormat("AUDUSDNZDGridEA stopped. Reason=%d | Open baskets=%d",
         reason, CountAllBaskets()));
}
//+------------------------------------------------------------------+
