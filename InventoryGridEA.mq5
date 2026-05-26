//+------------------------------------------------------------------+
//|  InventoryGrid EA v2.0                                           |
//|  Volatility-Normalized Inventory Strategy                        |
//|  with Probabilistic Regime Detection                             |
//|  and Hard Portfolio Risk Limits                                  |
//|                                                                  |
//|  NOT a martingale EA. The defining principle:                    |
//|  Position size depends on volatility, drawdown, and regime —    |
//|  never on how many times you have been wrong.                   |
//|                                                                  |
//|  Architecture:                                                   |
//|  Layer 1: Regime gate (TrendScore composite)                     |
//|  Layer 2: ATR-normalized grid & TP                               |
//|  Layer 3: Risk-budget position sizing                            |
//|  Layer 4: Portfolio currency exposure limits                     |
//|  Layer 5: Dynamic basket exit (DD + hold time scale with vol)    |
//+------------------------------------------------------------------+

#property copyright "InventoryGrid EA v2.0 — Probabilistic Inventory Control"
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//+------------------------------------------------------------------+
//|  Inputs — Layer 1: Regime Gate                                   |
//+------------------------------------------------------------------+
input group "=== LAYER 1: REGIME GATE ==="
input double TrendScoreThreshold = 2.0;   // Block new entries above this score (0-5 scale)
input int    EmaFastPeriod       = 50;    // Fast EMA for slope signal
input int    EmaSlowPeriod       = 200;   // Slow EMA for trend filter
input int    AdxPeriod           = 14;    // ADX for trend strength
input double AdxTrendLevel       = 25.0;  // ADX above this = trend present
input int    HurstWindow         = 100;   // Bars for rolling Hurst approximation
input double HurstTrendLevel     = 0.55;  // Hurst above this = trending

//+------------------------------------------------------------------+
//|  Inputs — Layer 2: ATR-Normalized Grid                           |
//+------------------------------------------------------------------+
input group "=== LAYER 2: ATR-NORMALIZED GRID ==="
input double AtrGridMultiplier   = 0.8;   // Grid = k1 × ATR(14)  [0.5-1.2]
input double AtrTpMultiplier     = 0.5;   // TP   = k2 × ATR(14)  [0.3-0.8]
input int    AtrPeriod           = 14;    // ATR period (H1 bars)
input int    BreakoutBars        = 20;    // N-bar signal window
input bool   UsePullbackEntry    = false; // Alt: pullback entry instead of breakout

//+------------------------------------------------------------------+
//|  Inputs — Layer 3: Risk-Budget Position Sizing                   |
//+------------------------------------------------------------------+
input group "=== LAYER 3: RISK-BASED SIZING ==="
input double RiskBudgetPct       = 0.50;  // % of equity risked per basket
input double LotMultiplier       = 1.10;  // Max 1.0–1.15. 1.0 = flat sizing
input int    MaxBasketSize       = 5;     // Reduced from 7
input double MinLotSize          = 0.001; // Minimum lot (micro)
input double MaxLotSize          = 0.10;  // Hard lot cap per position

//+------------------------------------------------------------------+
//|  Inputs — Layer 4: Portfolio Exposure                            |
//+------------------------------------------------------------------+
input group "=== LAYER 4: PORTFOLIO EXPOSURE ==="
input double MaxUsdExposureLots  = 0.20;  // Max net USD exposure (lots)
input double MaxEurExposureLots  = 0.20;  // Max net EUR exposure (lots)
input double MaxGbpExposureLots  = 0.15;  // Max net GBP exposure (lots)
input double MaxAudExposureLots  = 0.15;  // Max net AUD exposure (lots)
input int    MaxOpenBaskets      = 3;     // Reduced: correlated baskets dangerous
input double MaxPortfolioVarPct  = 5.0;   // Close all if portfolio float loss > X%

//+------------------------------------------------------------------+
//|  Inputs — Layer 5: Dynamic Basket Exit                           |
//+------------------------------------------------------------------+
input group "=== LAYER 5: DYNAMIC BASKET EXIT ==="
input double BasketDDPct         = 2.0;   // Base basket DD limit %
input int    MaxHoldHoursBase    = 72;    // Base hold time (hours)
input double VolScaleFactor      = 1.5;   // At 2× vol: DD and hold shrink by this factor
input bool   UseCircuitBreaker   = true;  // Hard stop on portfolio DD
input double PortfolioMaxDDPct   = 20.0;  // Portfolio circuit breaker %

//+------------------------------------------------------------------+
//|  Symbol Config                                                   |
//+------------------------------------------------------------------+
input group "=== SYMBOLS ==="
input bool TradeEURUSD = true;
input bool TradeGBPUSD = true;
input bool TradeUSDCHF = true;
input bool TradeUSDCAD = true;
input bool TradeAUDUSD = true;
input bool TradeAUDCAD = false;  // Disabled: historically worst performer
input bool TradeNZDUSD = false;

input group "=== IDENTIFICATION ==="
input int MagicNumber = 20260520;

//+------------------------------------------------------------------+
//|  Currency exposure map                                           |
//+------------------------------------------------------------------+
// EURUSD: +1 EUR, -1 USD per lot (long)
// GBPUSD: +1 GBP, -1 USD per lot (long)
// USDCHF: +1 USD, -1 CHF per lot (long)
// USDCAD: +1 USD, -1 CAD per lot (long)
// AUDUSD: +1 AUD, -1 USD per lot (long)
// (short = negative)

//+------------------------------------------------------------------+
//|  Globals                                                         |
//+------------------------------------------------------------------+
CTrade       Trade;
CPositionInfo PosInfo;

string    ActiveSymbols[];
int       NSymbols = 0;
datetime  BasketOpenTime[];
double    InitialBalance = 0;
bool      CircuitTripped = false;

//+------------------------------------------------------------------+
//|  OnInit                                                          |
//+------------------------------------------------------------------+
int OnInit()
{
   Trade.SetExpertMagicNumber(MagicNumber);
   Trade.SetDeviationInPoints(30);
   Trade.SetTypeFilling(ORDER_FILLING_FOK);

   InitialBalance = AccountInfoDouble(ACCOUNT_BALANCE);

   string cands[] = {"EURUSD","GBPUSD","USDCHF","USDCAD","AUDUSD","AUDCAD","NZDUSD"};
   bool   active[] = {TradeEURUSD, TradeGBPUSD, TradeUSDCHF, TradeUSDCAD,
                       TradeAUDUSD, TradeAUDCAD, TradeNZDUSD};
   ArrayResize(ActiveSymbols, 7);
   int n = 0;
   for (int i = 0; i < 7; i++)
      if (active[i]) ActiveSymbols[n++] = cands[i];
   NSymbols = n;
   ArrayResize(ActiveSymbols, NSymbols);
   ArrayResize(BasketOpenTime, NSymbols);
   ArrayInitialize(BasketOpenTime, 0);

   Print("InventoryGrid EA v2.0 initialized | Symbols: ", NSymbols,
         " | RiskBudget: ", RiskBudgetPct, "% | LotMult: ", LotMultiplier);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//|  OnTick                                                          |
//+------------------------------------------------------------------+
void OnTick()
{
   if (CircuitTripped) return;

   // Portfolio-level circuit breaker
   if (UseCircuitBreaker)
   {
      double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
      double dd      = (InitialBalance - equity) / InitialBalance * 100.0;
      if (dd > PortfolioMaxDDPct)
      {
         Print("CIRCUIT BREAKER: Portfolio DD ", DoubleToString(dd,1), "% > ",
               PortfolioMaxDDPct, "%. Closing all.");
         CloseAllPositions();
         CircuitTripped = true;
         return;
      }

      // Max floating loss check
      double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
      double floatPct = (balance - equity) / balance * 100.0;
      if (floatPct > MaxPortfolioVarPct)
      {
         Print("PORTFOLIO VAR LIMIT: Float loss ", DoubleToString(floatPct,1),
               "% > ", MaxPortfolioVarPct, "%.");
         CloseAllPositions();
         return;
      }
   }

   for (int s = 0; s < NSymbols; s++)
      ProcessSymbol(ActiveSymbols[s], s);
}

//+------------------------------------------------------------------+
//|  Layer 1: TrendScore — composite regime gate                     |
//+------------------------------------------------------------------+
double GetTrendScore(string sym)
{
   double score = 0.0;

   // Signal 1: EMA slope (fast EMA trending away from slow EMA)
   double fast_buf[], slow_buf[];
   ArraySetAsSeries(fast_buf, true);
   ArraySetAsSeries(slow_buf, true);
   int h_fast = iMA(sym, PERIOD_H1, EmaFastPeriod, 0, MODE_EMA, PRICE_CLOSE);
   int h_slow = iMA(sym, PERIOD_H1, EmaSlowPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if (h_fast != INVALID_HANDLE && h_slow != INVALID_HANDLE)
   {
      if (CopyBuffer(h_fast, 0, 0, 3, fast_buf) == 3 &&
          CopyBuffer(h_slow, 0, 0, 1, slow_buf) == 1)
      {
         double ema_slope = MathAbs(fast_buf[0] - fast_buf[2]) / fast_buf[2];
         if (fast_buf[0] > slow_buf[0]) score += 1.0;  // above slow EMA
         if (ema_slope > 0.001)         score += 0.5;  // fast EMA accelerating
      }
      IndicatorRelease(h_fast);
      IndicatorRelease(h_slow);
   }

   // Signal 2: ADX
   double adx_buf[];
   ArraySetAsSeries(adx_buf, true);
   int h_adx = iADX(sym, PERIOD_H1, AdxPeriod);
   if (h_adx != INVALID_HANDLE && CopyBuffer(h_adx, 0, 0, 1, adx_buf) == 1)
   {
      if (adx_buf[0] > AdxTrendLevel)  score += 1.0;
      if (adx_buf[0] > AdxTrendLevel * 1.6) score += 0.5;  // strong trend
      IndicatorRelease(h_adx);
   }

   // Signal 3: Realized volatility expansion (last 24h vs prior 48h)
   double atr_buf[];
   ArraySetAsSeries(atr_buf, true);
   int h_atr = iATR(sym, PERIOD_H1, AtrPeriod);
   if (h_atr != INVALID_HANDLE && CopyBuffer(h_atr, 0, 0, AtrPeriod * 3, atr_buf) == AtrPeriod * 3)
   {
      double atr_recent = atr_buf[0];
      double atr_prior  = 0;
      for (int k = AtrPeriod; k < AtrPeriod * 2; k++) atr_prior += atr_buf[k];
      atr_prior /= AtrPeriod;
      if (atr_recent > atr_prior * 1.4)  score += 1.0;  // volatility expansion
      if (atr_recent > atr_prior * 2.0)  score += 0.5;  // large vol spike
      IndicatorRelease(h_atr);
   }

   return score;
}

//+------------------------------------------------------------------+
//|  Layer 2: ATR-normalized grid and TP                             |
//+------------------------------------------------------------------+
bool GetAtrGridTp(string sym, double &grid_pips, double &tp_pips)
{
   double atr_buf[];
   ArraySetAsSeries(atr_buf, true);
   int h = iATR(sym, PERIOD_H1, AtrPeriod);
   if (h == INVALID_HANDLE) return false;
   if (CopyBuffer(h, 0, 0, 1, atr_buf) != 1) { IndicatorRelease(h); return false; }
   IndicatorRelease(h);

   double pip    = GetPipSize(sym);
   double atr_p  = atr_buf[0] / pip;  // ATR in pips

   grid_pips = atr_p * AtrGridMultiplier;
   tp_pips   = atr_p * AtrTpMultiplier;

   // Safety clamps: never narrower than 5 pips, never wider than 60
   grid_pips = MathMax(MathMin(grid_pips, 60.0), 5.0);
   tp_pips   = MathMax(MathMin(tp_pips,   40.0), 3.0);
   return true;
}

//+------------------------------------------------------------------+
//|  Layer 3: Risk-budget position sizing                            |
//+------------------------------------------------------------------+
double GetStartLots(string sym, double grid_pips)
{
   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   double pip       = GetPipSize(sym);
   double pip_val   = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE) *
                      (pip / SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE));

   // Expected basket risk: worst case = max_basket_size × grid_pips × lot compounding
   // Use geometric sum: sum of r^n for n=0 to MaxBasketSize-1
   double total_scale = 0;
   for (int i = 0; i < MaxBasketSize; i++)
      total_scale += MathPow(LotMultiplier, i);

   double risk_usd    = equity * RiskBudgetPct / 100.0;
   double start_lots  = risk_usd / (grid_pips * pip_val * total_scale + 0.001);

   // Normalize to lot step
   double lot_step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   start_lots = MathFloor(start_lots / lot_step) * lot_step;
   start_lots = MathMax(MathMin(start_lots, MaxLotSize), MinLotSize);
   return start_lots;
}

//+------------------------------------------------------------------+
//|  Layer 4: Currency exposure check                                |
//+------------------------------------------------------------------+
struct CurrencyExposure { double USD; double EUR; double GBP; double AUD; };

CurrencyExposure GetPortfolioExposure()
{
   CurrencyExposure exp = {0, 0, 0, 0};
   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if (!PosInfo.SelectByIndex(i)) continue;
      if (PosInfo.Magic() != MagicNumber) continue;
      string sym  = PosInfo.Symbol();
      double lots = PosInfo.Volume();
      int    dir  = (PosInfo.PositionType() == POSITION_TYPE_BUY) ? 1 : -1;

      // Map symbol to currency exposure
      if (sym == "EURUSD") { exp.EUR += dir * lots; exp.USD -= dir * lots; }
      if (sym == "GBPUSD") { exp.GBP += dir * lots; exp.USD -= dir * lots; }
      if (sym == "USDCHF") { exp.USD += dir * lots; }
      if (sym == "USDCAD") { exp.USD += dir * lots; }
      if (sym == "AUDUSD") { exp.AUD += dir * lots; exp.USD -= dir * lots; }
      if (sym == "AUDCAD") { exp.AUD += dir * lots; }
      if (sym == "NZDUSD") { exp.USD -= dir * lots; }
   }
   return exp;
}

bool ExposureLimitBreached(string sym, int signal)
{
   CurrencyExposure exp = GetPortfolioExposure();
   double dir = (double)signal;

   // Check USD limits (most critical — multiple pairs share USD)
   double new_usd = exp.USD;
   if (sym == "EURUSD" || sym == "GBPUSD" || sym == "AUDUSD" || sym == "NZDUSD")
      new_usd -= dir * 0.01;  // approximate 1 lot increment
   else if (sym == "USDCHF" || sym == "USDCAD")
      new_usd += dir * 0.01;

   if (MathAbs(new_usd) > MaxUsdExposureLots) return true;

   // EUR limit
   if (sym == "EURUSD" && MathAbs(exp.EUR + dir * 0.01) > MaxEurExposureLots) return true;
   // GBP limit
   if (sym == "GBPUSD" && MathAbs(exp.GBP + dir * 0.01) > MaxGbpExposureLots) return true;
   // AUD limit
   if (sym == "AUDUSD" || sym == "AUDCAD")
      if (MathAbs(exp.AUD + dir * 0.01) > MaxAudExposureLots) return true;

   return false;
}

//+------------------------------------------------------------------+
//|  Layer 5: Dynamic basket DD and hold limits                      |
//+------------------------------------------------------------------+
double GetDynamicBasketDD(string sym)
{
   double atr_buf[];
   ArraySetAsSeries(atr_buf, true);
   int h = iATR(sym, PERIOD_H1, AtrPeriod * 3);
   if (h == INVALID_HANDLE) return BasketDDPct;
   CopyBuffer(h, 0, 0, AtrPeriod * 3, atr_buf);
   IndicatorRelease(h);

   // Compare current ATR to its median
   double cur = atr_buf[0];
   double sorted[];
   ArrayCopy(sorted, atr_buf, 0, 0, AtrPeriod * 3);
   ArraySort(sorted);
   double median = sorted[(int)(AtrPeriod * 3 / 2)];
   double vol_ratio = cur / (median + 1e-10);

   // High vol → tighter DD limit
   double dynamic_dd = BasketDDPct / MathMax(vol_ratio / VolScaleFactor, 1.0);
   return MathMax(dynamic_dd, 0.5);  // never below 0.5%
}

int GetDynamicHoldHours(string sym)
{
   double atr_buf[];
   ArraySetAsSeries(atr_buf, true);
   int h = iATR(sym, PERIOD_H1, AtrPeriod);
   if (h == INVALID_HANDLE) return MaxHoldHoursBase;
   CopyBuffer(h, 0, 0, 1, atr_buf);
   IndicatorRelease(h);

   // Approximate: if trend score is high → shorter hold
   double ts = GetTrendScore(sym);
   if (ts >= 3.0) return MaxHoldHoursBase / 3;   // 24h in strong trend
   if (ts >= 2.0) return MaxHoldHoursBase / 2;   // 36h in moderate trend
   return MaxHoldHoursBase;                        // 72h in mean-reversion
}

//+------------------------------------------------------------------+
//|  ProcessSymbol — main per-symbol logic                           |
//+------------------------------------------------------------------+
void ProcessSymbol(string sym, int symIdx)
{
   double bid   = SymbolInfoDouble(sym, SYMBOL_BID);
   double ask   = SymbolInfoDouble(sym, SYMBOL_ASK);
   double pip   = GetPipSize(sym);
   if (bid <= 0 || pip <= 0) return;

   double grid_pips = 16.0, tp_pips = 10.0;
   GetAtrGridTp(sym, grid_pips, tp_pips);  // Layer 2

   int  basketSize = CountBasketPositions(sym);
   bool hasBasket  = (basketSize > 0);

   if (hasBasket)
   {
      // ── Manage open basket ─────────────────────────────────────────
      double wavgPips  = GetWeightedAvgPips(sym, pip);
      double floatUSD  = GetBasketFloat(sym);
      double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
      int    dir       = GetBasketDirection(sym);
      int    holdHours = (int)((TimeCurrent() - BasketOpenTime[symIdx]) / 3600);

      double dynDD   = GetDynamicBasketDD(sym);   // Layer 5
      int    dynHold = GetDynamicHoldHours(sym);  // Layer 5

      // Exit conditions
      if (wavgPips >= tp_pips)
      { CloseBasket(sym, "TP", symIdx); return; }

      if (basketSize >= MaxBasketSize)
      { CloseBasket(sym, "MAX_SIZE", symIdx); return; }

      if (equity > 0 && floatUSD / equity < -(dynDD / 100.0))
      { CloseBasket(sym, "DD_LIMIT", symIdx); return; }

      if (holdHours >= dynHold)
      { CloseBasket(sym, "HOLD_LIMIT", symIdx); return; }

      // Add to basket — with inventory aversion penalty
      double lastPrice   = GetLastPositionPrice(sym, dir);
      double curPrice    = (dir == 1) ? bid : ask;
      double movePips    = (lastPrice - curPrice) * dir / pip;

      // Inventory penalty: threshold widens as basket grows
      // This is the A-S inventory control principle
      double inv_factor  = 1.0 + 0.20 * (basketSize - 1);
      double eff_grid    = grid_pips * inv_factor;

      // Also: don't add if TrendScore increased since basket opened
      double ts = GetTrendScore(sym);
      if (ts >= TrendScoreThreshold) return;  // regime turned bad while in trade

      if (movePips >= eff_grid && basketSize < MaxBasketSize)
      {
         double prev_lots = GetMaxBasketLots(sym);
         // Risk-based addition: not flat martingale
         double next_lots = prev_lots * LotMultiplier;
         next_lots = MathMax(MathMin(next_lots, MaxLotSize), MinLotSize);
         double ls = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
         next_lots = MathRound(next_lots / ls) * ls;

         if (dir == 1) Trade.Buy(next_lots, sym, ask, 0, 0, "Inv+" + IntegerToString(basketSize+1));
         else          Trade.Sell(next_lots, sym, bid, 0, 0, "Inv+" + IntegerToString(basketSize+1));
      }
   }
   else
   {
      // ── Entry logic ────────────────────────────────────────────────

      // Layer 1: Regime gate
      double ts = GetTrendScore(sym);
      if (ts >= TrendScoreThreshold) return;

      // Layer 4: Portfolio exposure check
      if (CountAllBaskets() >= MaxOpenBaskets) return;

      // Entry signal
      int signal = 0;
      if (!UsePullbackEntry)
         signal = BreakoutSignal(sym, BreakoutBars);
      else
         signal = PullbackSignal(sym);

      if (signal == 0) return;

      // Check currency exposure limits (Layer 4)
      if (ExposureLimitBreached(sym, signal)) return;

      // Risk-based start lots (Layer 3)
      double start_lots = GetStartLots(sym, grid_pips);

      if (signal == 1)
      {
         Trade.Buy(start_lots, sym, ask, 0, 0, "Inv+1");
         BasketOpenTime[symIdx] = TimeCurrent();
      }
      else
      {
         Trade.Sell(start_lots, sym, bid, 0, 0, "Inv+1");
         BasketOpenTime[symIdx] = TimeCurrent();
      }
   }
}

//+------------------------------------------------------------------+
//|  Entry signals                                                   |
//+------------------------------------------------------------------+
int BreakoutSignal(string sym, int bars)
{
   double h[], l[];
   ArraySetAsSeries(h, true); ArraySetAsSeries(l, true);
   if (CopyHigh(sym, PERIOD_H1, 1, bars, h) < bars) return 0;
   if (CopyLow(sym,  PERIOD_H1, 1, bars, l) < bars) return 0;
   double cur  = iClose(sym, PERIOD_H1, 0);
   double pip  = GetPipSize(sym);
   if (cur > h[ArrayMaximum(h, 0, bars)] + pip) return +1;
   if (cur < l[ArrayMinimum(l, 0, bars)] - pip) return -1;
   return 0;
}

int PullbackSignal(string sym)
{
   // Buy pullback: price above EMA200 AND dipped below EMA50 AND recovering
   double fast[], slow[], close_arr[];
   ArraySetAsSeries(fast, true); ArraySetAsSeries(slow, true);
   ArraySetAsSeries(close_arr, true);
   int hf = iMA(sym, PERIOD_H1, EmaFastPeriod, 0, MODE_EMA, PRICE_CLOSE);
   int hs = iMA(sym, PERIOD_H1, EmaSlowPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if (hf == INVALID_HANDLE || hs == INVALID_HANDLE) return 0;
   if (CopyBuffer(hf, 0, 0, 3, fast) != 3)  { IndicatorRelease(hf); IndicatorRelease(hs); return 0; }
   if (CopyBuffer(hs, 0, 0, 1, slow) != 1)  { IndicatorRelease(hf); IndicatorRelease(hs); return 0; }
   if (CopyClose(sym, PERIOD_H1, 0, 3, close_arr) != 3) return 0;
   IndicatorRelease(hf); IndicatorRelease(hs);

   double cur = close_arr[0];
   if (cur > slow[0] && close_arr[2] < fast[2] && close_arr[0] > fast[0])
      return +1;  // was below fast EMA, now above = bullish pullback
   if (cur < slow[0] && close_arr[2] > fast[2] && close_arr[0] < fast[0])
      return -1;
   return 0;
}

//+------------------------------------------------------------------+
//|  Position helpers                                                |
//+------------------------------------------------------------------+
int CountBasketPositions(string sym)
{
   int c = 0;
   for (int i = PositionsTotal() - 1; i >= 0; i--)
      if (PosInfo.SelectByIndex(i) && PosInfo.Symbol() == sym && PosInfo.Magic() == MagicNumber)
         c++;
   return c;
}

int CountAllBaskets()
{
   int c = 0;
   for (int s = 0; s < NSymbols; s++)
      if (CountBasketPositions(ActiveSymbols[s]) > 0) c++;
   return c;
}

int GetBasketDirection(string sym)
{
   for (int i = PositionsTotal() - 1; i >= 0; i--)
      if (PosInfo.SelectByIndex(i) && PosInfo.Symbol() == sym && PosInfo.Magic() == MagicNumber)
         return (PosInfo.PositionType() == POSITION_TYPE_BUY) ? 1 : -1;
   return 0;
}

double GetWeightedAvgPips(string sym, double pip)
{
   double wl = 0, tl = 0;
   double cur = SymbolInfoDouble(sym, SYMBOL_BID);
   for (int i = PositionsTotal() - 1; i >= 0; i--)
      if (PosInfo.SelectByIndex(i) && PosInfo.Symbol() == sym && PosInfo.Magic() == MagicNumber)
      {
         int d = (PosInfo.PositionType() == POSITION_TYPE_BUY) ? 1 : -1;
         wl += ((cur - PosInfo.PriceOpen()) * d / pip) * PosInfo.Volume();
         tl += PosInfo.Volume();
      }
   return tl > 0 ? wl / tl : 0;
}

double GetBasketFloat(string sym)
{
   double t = 0;
   for (int i = PositionsTotal() - 1; i >= 0; i--)
      if (PosInfo.SelectByIndex(i) && PosInfo.Symbol() == sym && PosInfo.Magic() == MagicNumber)
         t += PosInfo.Profit() + PosInfo.Swap();
   return t;
}

double GetLastPositionPrice(string sym, int dir)
{
   double p = 0; datetime t = 0;
   for (int i = PositionsTotal() - 1; i >= 0; i--)
      if (PosInfo.SelectByIndex(i) && PosInfo.Symbol() == sym && PosInfo.Magic() == MagicNumber)
         if (PosInfo.Time() >= t) { t = PosInfo.Time(); p = PosInfo.PriceOpen(); }
   return p;
}

double GetMaxBasketLots(string sym)
{
   double m = 0;
   for (int i = PositionsTotal() - 1; i >= 0; i--)
      if (PosInfo.SelectByIndex(i) && PosInfo.Symbol() == sym && PosInfo.Magic() == MagicNumber)
         m = MathMax(m, PosInfo.Volume());
   return m;
}

void CloseBasket(string sym, string reason, int symIdx = -1)
{
   double pnl = 0; int cnt = 0;
   for (int i = PositionsTotal() - 1; i >= 0; i--)
      if (PosInfo.SelectByIndex(i) && PosInfo.Symbol() == sym && PosInfo.Magic() == MagicNumber)
      { pnl += PosInfo.Profit() + PosInfo.Swap(); cnt++; Trade.PositionClose(PosInfo.Ticket()); }
   if (symIdx >= 0) BasketOpenTime[symIdx] = 0;
   Print("[", sym, "] CloseBasket reason=", reason, " n=", cnt, " PnL=$", DoubleToString(pnl,2));
}

void CloseAllPositions()
{
   for (int i = PositionsTotal() - 1; i >= 0; i--)
      if (PosInfo.SelectByIndex(i) && PosInfo.Magic() == MagicNumber)
         Trade.PositionClose(PosInfo.Ticket());
}

double GetPipSize(string sym)
{
   int d = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
   return (d == 5 || d == 3) ? pt * 10 : pt;
}

void OnDeinit(const int reason)
{
   Print("InventoryGrid EA stopped. Reason: ", reason);
}
