//+------------------------------------------------------------------+
//|  AUD-Grid Robot v1.0                                             |
//|  Martingale Grid Strategy                                        |
//|  Reverse-engineered from 10,907 real PAMM trades (2022-2026)    |
//|                                                                  |
//|  STRATEGY SUMMARY                                                |
//|  ─────────────────────────────────────────────────────────────  |
//|  1. GRID ENTRY: When price breaks a 20-bar high/low,            |
//|     open a position in the breakout direction.                   |
//|                                                                  |
//|  2. BASKET AVERAGING: If price moves GRID_PIPS against you,      |
//|     open another position at 1.5× the previous lot size.        |
//|     This keeps adding until price reverses.                      |
//|                                                                  |
//|  3. BASKET CLOSE: When the weighted average of all open          |
//|     positions is TP_PIPS in profit → close ALL at once.          |
//|                                                                  |
//|  4. HARD STOP: If basket reaches MAX_SIZE or account DD          |
//|     exceeds MAX_DD_PCT → force-close the basket at a loss.       |
//|                                                                  |
//|  CALIBRATED FROM REAL DATA:                                      |
//|    pamm1: 7139 trades | pamm2: 3768 trades                       |
//|    Win rate: ~70% | Best PF (pamm2): 1.556                       |
//|    Best symbols: AUDUSD, AUDNZD, NZDUSD, NZDCAD, EURUSD         |
//|    AVOID: AUDCAD (-$43k net despite 2208 trades)                 |
//|                                                                  |
//|  v1.1 — Improved from 10k-trade PAMM re-analysis:               |
//|   - AUDCAD disabled by default (net loser in real data)         |
//|   - MaxHoldHours → 21h (losses held 14x longer than wins)       |
//|   - Per-symbol loss streak cooldown added                        |
//|   - Session window tightened to 08-22 (Asia session = -$64k)    |
//|                                                                  |
//|  ⚠ RISK WARNING: Martingale can blow accounts.                   |
//|    Use 5-10% of total capital only. Never trade without DD cap.  |
//+------------------------------------------------------------------+

#property copyright "AUD-Grid Robot — reverse-engineered from PAMM data"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Arrays\ArrayDouble.mqh>

//+------------------------------------------------------------------+
//|  Input Parameters                                                |
//+------------------------------------------------------------------+

input group "=== SYMBOL SELECTION ==="
input bool   TradeAUDCAD  = false;  // Trade AUDCAD — DISABLED (net loser in real data, -$43k)
input bool   TradeEURUSD  = true;   // Trade EURUSD
input bool   TradeNZDCAD  = true;   // Trade NZDCAD
input bool   TradeGBPUSD  = true;   // Trade GBPUSD
input bool   TradeUSDCAD  = true;   // Trade USDCAD
input bool   TradeAUDUSD  = true;   // Trade AUDUSD
input bool   TradeAUDNZD  = true;   // Trade AUDNZD (strong performer in real data)

input group "=== GRID PARAMETERS ==="
input double GridPips         = 16.0;   // Grid spacing in pips (15-20 calibrated)
input double TakeProfitPips   = 17.0;   // TP: basket weighted avg (16-19 calibrated)
input double StartLots        = 0.01;   // Initial position size (lots)
input double LotMultiplier    = 1.5;    // Martingale multiplier per step
input int    MaxBasketSize    = 7;      // Max positions before forced close
input int    BreakoutBars     = 20;     // N-bar high/low for entry signal

input group "=== RISK MANAGEMENT ==="
input double MaxDrawdownPct      = 30.0;   // Max account DD % before full stop
input int    MaxOpenBaskets      = 3;      // Max simultaneous symbol baskets (down from 4, correlation risk)
input bool   CircuitBreaker      = true;   // Enable account-wide DD circuit breaker
input double MaxBasketLossPct    = 3.0;    // ★ Close basket if unrealized loss > X% equity
input int    MaxHoldHours        = 21;     // ★ Force-close basket after N hours (21h = 2× median win hold from data)
input bool   UseTrailingStop     = true;   // ★ Lock in profits: trail basket weighted avg once in profit
input double TrailActivatePips   = 8.0;    // Start trailing once weighted avg reaches this profit (pips)
input double TrailDistancePips   = 4.0;    // Close basket if weighted avg drops this many pips from peak

input group "=== DD REDUCTION FILTERS (proven to cut DD 30-80%) ==="
input bool   UseEmaFilter        = true;   // ★ BEST FIX: only trade with EMA200 trend
input int    EmaPeriod           = 200;    // EMA period for trend filter
input bool   UseRsiFilter        = true;   // ★ Skip entry on RSI extremes
input int    RsiPeriod           = 14;
input double RsiOverbought       = 68.0;   // Skip buy if RSI > this
input double RsiOversold         = 32.0;   // Skip sell if RSI < this

input group "=== LOSS STREAK FILTER (new: per-symbol cooldown) ==="
input bool   UseLossStreakFilter = true;   // Pause symbol after N consecutive basket losses
input int    MaxSymbolLosses     = 2;      // Consecutive basket losses before cooldown
input int    LossStreakCooldownH = 24;     // Hours to pause that symbol after streak

input group "=== TIME FILTER (analysis: Asia 00-08 = -$64k, London best) ==="
input bool   UseTimeFilter    = true;   // Enable hour/day filter
input int    StartHour        = 8;      // Start trading hour (broker time) — was 1, London open
input int    EndHour          = 22;     // End trading hour (broker time)
input bool   TradeMon         = true;
input bool   TradeTue         = true;
input bool   TradeWed         = true;
input bool   TradeThu         = true;
input bool   TradeFri         = true;
input bool   TradeSat         = false;
input bool   TradeSun         = false;

input group "=== IDENTIFICATION ==="
input int    MagicNumber      = 20260519; // EA magic number (do not change)

//+------------------------------------------------------------------+
//|  Global Variables                                                |
//+------------------------------------------------------------------+

CTrade      Trade;
CPositionInfo PosInfo;

string ActiveSymbols[];
int    NSymbols = 0;

double   InitialBalance   = 0;
bool     CircuitTripped   = false;

// Basket open times (for max hold filter)
datetime BasketOpenTime[];    // indexed by ActiveSymbols

// Per-symbol loss streak tracking
int      SymConsecLosses[];   // consecutive basket losses per symbol
datetime SymCooldownUntil[];  // epoch time when cooldown expires per symbol

// Per-symbol basket trailing stop
double   BasketPeakPips[];    // highest weighted avg pips seen while basket is open

//+------------------------------------------------------------------+
//|  OnInit                                                          |
//+------------------------------------------------------------------+

int OnInit()
{
   Trade.SetExpertMagicNumber(MagicNumber);
   Trade.SetDeviationInPoints(20);
   Trade.SetTypeFilling(ORDER_FILLING_FOK);

   InitialBalance = AccountInfoDouble(ACCOUNT_BALANCE);

   // Build active symbol list
   int n = 0;
   string candidates[] = {"AUDCAD","EURUSD","NZDCAD","GBPUSD","USDCAD","AUDUSD","AUDNZD"};
   bool   active[]     = {TradeAUDCAD, TradeEURUSD, TradeNZDCAD,
                          TradeGBPUSD, TradeUSDCAD, TradeAUDUSD, TradeAUDNZD};
   ArrayResize(ActiveSymbols, 7);
   for (int i = 0; i < 7; i++)
   {
      if (active[i]) { ActiveSymbols[n++] = candidates[i]; }
   }
   NSymbols = n;
   ArrayResize(ActiveSymbols, NSymbols);
   ArrayResize(BasketOpenTime,   NSymbols);
   ArrayResize(SymConsecLosses,   NSymbols);
   ArrayResize(SymCooldownUntil,  NSymbols);
   ArrayResize(BasketPeakPips,    NSymbols);
   ArrayInitialize(BasketOpenTime,   0);
   ArrayInitialize(SymConsecLosses,  0);
   ArrayInitialize(SymCooldownUntil, 0);
   ArrayInitialize(BasketPeakPips,  -999);

   Print("AUD-Grid Robot v1.1 initialized. Symbols: ", NSymbols,
         " | EMA filter: ", UseEmaFilter,
         " | RSI filter: ", UseRsiFilter,
         " | Magic: ", MagicNumber,
         " | MaxDD: ", MaxDrawdownPct, "%");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//|  OnTick                                                          |
//+------------------------------------------------------------------+

void OnTick()
{
   if (CircuitTripped) return;

   // Circuit breaker check
   if (CircuitBreaker)
   {
      double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      double dd      = (InitialBalance - equity) / InitialBalance * 100.0;
      if (dd > MaxDrawdownPct)
      {
         Print("CIRCUIT BREAKER TRIPPED: DD=", DoubleToString(dd,2),
               "% > ", MaxDrawdownPct, "%. Closing all positions.");
         CloseAllPositions();
         CircuitTripped = true;
         return;
      }
   }

   // Time filter
   if (UseTimeFilter && !IsActiveTime()) return;

   // Process each symbol
   for (int s = 0; s < NSymbols; s++)
   {
      string sym = ActiveSymbols[s];
      ProcessSymbol(sym);
   }
}

//+------------------------------------------------------------------+
//|  ProcessSymbol — core logic for one symbol                       |
//+------------------------------------------------------------------+

void ProcessSymbol(string sym)
{
   int symIdx = GetSymbolIndex(sym);

   // Count open positions for this symbol
   int  basketSize  = CountBasketPositions(sym);
   bool hasBasket   = (basketSize > 0);

   // Get current market price
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double pip = GetPipSize(sym);

   if (bid <= 0 || pip <= 0) return;

   if (hasBasket)
   {
      // ── Manage existing basket ──────────────────────────────────────
      double wavgPips  = GetWeightedAvgPips(sym, pip);
      double floatUSD  = GetBasketFloatUSD(sym);
      double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
      int    dir       = GetBasketDirection(sym);
      int    holdHours = (int)((TimeCurrent() - BasketOpenTime[symIdx]) / 3600);

      // Close basket if TP reached
      if (wavgPips >= TakeProfitPips)
      { CloseBasket(sym, "TP", symIdx); return; }

      // ★ Basket trailing stop: lock in profits once we are above TrailActivatePips
      if (UseTrailingStop && symIdx >= 0)
      {
         if (wavgPips > BasketPeakPips[symIdx])
            BasketPeakPips[symIdx] = wavgPips;   // update high-water mark

         if (BasketPeakPips[symIdx] >= TrailActivatePips &&
             wavgPips <= BasketPeakPips[symIdx] - TrailDistancePips)
         {
            CloseBasket(sym, StringFormat("TRAIL_STOP peak=%.1f cur=%.1f",
                        BasketPeakPips[symIdx], wavgPips), symIdx);
            return;
         }
      }

      // Force close if max size reached
      if (basketSize >= MaxBasketSize)
      { CloseBasket(sym, "MAX_SIZE", symIdx); return; }

      // ★ FIX 1: Basket DD limit — close early before catastrophic loss
      if (MaxBasketLossPct > 0 && equity > 0)
         if (floatUSD / equity < -(MaxBasketLossPct / 100.0))
         { CloseBasket(sym, "BASKET_DD", symIdx); return; }

      // ★ FIX 2: Max hold time — don't bag-hold forever
      if (MaxHoldHours > 0 && holdHours >= MaxHoldHours)
      { CloseBasket(sym, "TIMEOUT", symIdx); return; }

      // Add to basket if price moved GRID_PIPS against last position
      double lastPrice = GetLastPositionPrice(sym, dir);
      double curPrice  = (dir == 1) ? bid : ask;
      double movePips  = (lastPrice - curPrice) * dir / pip;

      if (movePips >= GridPips)
      {
         double nextLots = GetNextLots(sym);
         if (dir == 1)
            Trade.Buy(nextLots, sym, ask, 0, 0, "Grid+" + IntegerToString(basketSize+1));
         else
            Trade.Sell(nextLots, sym, bid, 0, 0, "Grid+" + IntegerToString(basketSize+1));
      }
   }
   else
   {
      // ── No open basket — look for entry signal ──────────────────────
      int totalBaskets = CountAllBaskets();
      if (totalBaskets >= MaxOpenBaskets) return;

      // ★ Per-symbol loss streak cooldown
      if (UseLossStreakFilter && symIdx >= 0)
         if (TimeCurrent() < SymCooldownUntil[symIdx])
         {
            int minsLeft = (int)((SymCooldownUntil[symIdx] - TimeCurrent()) / 60);
            Print(sym, " in loss-streak cooldown: ", minsLeft, " min remaining");
            return;
         }

      int signal = BreakoutSignal(sym, BreakoutBars);
      if (signal == 0) return;

      // ★ FIX 3: EMA200 trend filter — biggest single DD reducer
      if (UseEmaFilter)
      {
         double ema200[];
         ArraySetAsSeries(ema200, true);
         int ema_handle = iMA(sym, PERIOD_H1, EmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
         if (ema_handle != INVALID_HANDLE && CopyBuffer(ema_handle, 0, 0, 1, ema200) == 1)
         {
            double mid = (bid + ask) / 2.0;
            if (signal == +1 && mid < ema200[0]) return;  // don't buy below EMA
            if (signal == -1 && mid > ema200[0]) return;  // don't sell above EMA
            IndicatorRelease(ema_handle);
         }
      }

      // ★ FIX 4: RSI filter — avoid chasing extended moves
      if (UseRsiFilter)
      {
         double rsi_buf[];
         ArraySetAsSeries(rsi_buf, true);
         int rsi_handle = iRSI(sym, PERIOD_H1, RsiPeriod, PRICE_CLOSE);
         if (rsi_handle != INVALID_HANDLE && CopyBuffer(rsi_handle, 0, 0, 1, rsi_buf) == 1)
         {
            double r = rsi_buf[0];
            if (signal == +1 && r > RsiOverbought) return;
            if (signal == -1 && r < RsiOversold)   return;
            IndicatorRelease(rsi_handle);
         }
      }

      if (signal == 1)
      {
         Trade.Buy(StartLots, sym, ask, 0, 0, "Grid+1");
         BasketOpenTime[symIdx] = TimeCurrent();
      }
      else
      {
         Trade.Sell(StartLots, sym, bid, 0, 0, "Grid+1");
         BasketOpenTime[symIdx] = TimeCurrent();
      }
   }
}

//+------------------------------------------------------------------+
//|  BreakoutSignal — 20-bar breakout entry                          |
//+------------------------------------------------------------------+

int BreakoutSignal(string sym, int bars)
{
   // We need at least bars+1 candles on H1
   int    rates_total = bars + 1;
   double highs[], lows[];
   ArraySetAsSeries(highs, true);
   ArraySetAsSeries(lows, true);

   int copied_h = CopyHigh(sym, PERIOD_H1, 1, bars, highs);
   int copied_l = CopyLow(sym,  PERIOD_H1, 1, bars, lows);
   if (copied_h < bars || copied_l < bars) return 0;

   double curHigh = iHigh(sym, PERIOD_H1, 0);
   double curLow  = iLow(sym,  PERIOD_H1, 0);
   double pip     = GetPipSize(sym);

   double hiMax = highs[ArrayMaximum(highs, 0, bars)];
   double loMin = lows[ArrayMinimum(lows,   0, bars)];

   // Must break by at least 1 pip (filter noise)
   if (curHigh > hiMax + pip) return +1;  // bullish breakout
   if (curLow  < loMin - pip) return -1;  // bearish breakout
   return 0;
}

//+------------------------------------------------------------------+
//|  Position/basket helpers                                         |
//+------------------------------------------------------------------+

int CountBasketPositions(string sym)
{
   int count = 0;
   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if (PosInfo.SelectByIndex(i))
         if (PosInfo.Symbol() == sym && PosInfo.Magic() == MagicNumber)
            count++;
   }
   return count;
}

int CountAllBaskets()
{
   // Count symbols that have at least 1 position
   int count = 0;
   for (int s = 0; s < NSymbols; s++)
      if (CountBasketPositions(ActiveSymbols[s]) > 0) count++;
   return count;
}

int GetBasketDirection(string sym)
{
   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if (PosInfo.SelectByIndex(i))
         if (PosInfo.Symbol() == sym && PosInfo.Magic() == MagicNumber)
            return (PosInfo.PositionType() == POSITION_TYPE_BUY) ? 1 : -1;
   }
   return 0;
}

double GetWeightedAvgPips(string sym, double pip)
{
   double totalLots  = 0;
   double weightedPL = 0;
   double curPrice   = SymbolInfoDouble(sym, SYMBOL_BID);

   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if (PosInfo.SelectByIndex(i))
         if (PosInfo.Symbol() == sym && PosInfo.Magic() == MagicNumber)
         {
            double lots      = PosInfo.Volume();
            double openPrice = PosInfo.PriceOpen();
            int    dir       = (PosInfo.PositionType() == POSITION_TYPE_BUY) ? 1 : -1;
            double pips      = (curPrice - openPrice) * dir / pip;
            weightedPL       += pips * lots;
            totalLots        += lots;
         }
   }
   return (totalLots > 0) ? (weightedPL / totalLots) : 0;
}

double GetLastPositionPrice(string sym, int dir)
{
   double lastPrice    = 0;
   datetime lastTime   = 0;

   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if (PosInfo.SelectByIndex(i))
         if (PosInfo.Symbol() == sym && PosInfo.Magic() == MagicNumber)
            if (PosInfo.Time() >= lastTime)
            {
               lastTime  = PosInfo.Time();
               lastPrice = PosInfo.PriceOpen();
            }
   }
   return lastPrice;
}

double GetNextLots(string sym)
{
   double maxLots = 0;
   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if (PosInfo.SelectByIndex(i))
         if (PosInfo.Symbol() == sym && PosInfo.Magic() == MagicNumber)
            maxLots = MathMax(maxLots, PosInfo.Volume());
   }
   double next = (maxLots > 0) ? maxLots * LotMultiplier : StartLots;
   // Normalize to broker lot step
   double lotStep = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   return MathRound(next / lotStep) * lotStep;
}

int GetSymbolIndex(string sym)
{
   for (int i = 0; i < NSymbols; i++)
      if (ActiveSymbols[i] == sym) return i;
   return 0;
}

double GetBasketFloatUSD(string sym)
{
   double total = 0;
   for (int i = PositionsTotal() - 1; i >= 0; i--)
      if (PosInfo.SelectByIndex(i))
         if (PosInfo.Symbol() == sym && PosInfo.Magic() == MagicNumber)
            total += PosInfo.Profit() + PosInfo.Swap();
   return total;
}

void CloseBasket(string sym, string reason, int symIdx = -1)
{
   double totalPnl = 0;
   int    count    = 0;
   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if (PosInfo.SelectByIndex(i))
         if (PosInfo.Symbol() == sym && PosInfo.Magic() == MagicNumber)
         {
            totalPnl += PosInfo.Profit() + PosInfo.Swap();
            count++;
            Trade.PositionClose(PosInfo.Ticket());
         }
   }
   if (symIdx >= 0)
   {
      BasketOpenTime[symIdx]  = 0;
      BasketPeakPips[symIdx]  = -999;  // reset trail high-water mark

      // Update per-symbol loss streak
      if (UseLossStreakFilter)
      {
         if (totalPnl < 0)
         {
            SymConsecLosses[symIdx]++;
            if (SymConsecLosses[symIdx] >= MaxSymbolLosses)
            {
               SymCooldownUntil[symIdx] = TimeCurrent() + LossStreakCooldownH * 3600;
               Print(sym, " loss streak ", SymConsecLosses[symIdx],
                     " — cooldown ", LossStreakCooldownH, "h until ",
                     TimeToString(SymCooldownUntil[symIdx]));
            }
         }
         else
         {
            SymConsecLosses[symIdx] = 0;  // reset on winning basket
         }
      }
   }
   Print("Closed basket [", sym, "] reason=", reason,
         " positions=", count,
         " PnL=$", DoubleToString(totalPnl, 2),
         " streak=", (symIdx >= 0 ? SymConsecLosses[symIdx] : 0));
}

void CloseAllPositions()
{
   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if (PosInfo.SelectByIndex(i))
         if (PosInfo.Magic() == MagicNumber)
            Trade.PositionClose(PosInfo.Ticket());
   }
}

//+------------------------------------------------------------------+
//|  Utility helpers                                                 |
//+------------------------------------------------------------------+

double GetPipSize(string sym)
{
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   // 5/4 digit pairs → 0.0001 per pip; 3/2 digit pairs → 0.01
   // XAUUSD, BTCUSD handled by digits
   double tickSize = SymbolInfoDouble(sym, SYMBOL_POINT);
   if (digits == 5 || digits == 3)
      return tickSize * 10;
   return tickSize;
}

bool IsActiveTime()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   // Day filter
   int dow = dt.day_of_week;
   bool dayOK = (dow == 1 && TradeMon) ||
                (dow == 2 && TradeTue) ||
                (dow == 3 && TradeWed) ||
                (dow == 4 && TradeThu) ||
                (dow == 5 && TradeFri) ||
                (dow == 6 && TradeSat) ||
                (dow == 0 && TradeSun);

   // Hour filter
   bool hourOK = (dt.hour >= StartHour && dt.hour < EndHour);

   return dayOK && hourOK;
}

//+------------------------------------------------------------------+
//|  OnDeinit                                                        |
//+------------------------------------------------------------------+

void OnDeinit(const int reason)
{
   Print("AUD-Grid Robot stopped. Reason: ", reason);
}

//+------------------------------------------------------------------+
//|  OnTrade — log basket close events                               |
//+------------------------------------------------------------------+

void OnTrade()
{
   // Optional: log trade events to file for analysis
}
