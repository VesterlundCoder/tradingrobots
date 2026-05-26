//+------------------------------------------------------------------+
//| DecliningGridEA.mq5                                              |
//| Anti-Martingale Grid: Double spacing + 30% declining lots        |
//|                                                                  |
//| Key differences vs ClassicGridMartingaleEA:                     |
//|   • Grid spacing = ATR × 2.0  (DOUBLE the classic)             |
//|   • Each new level = previous × 0.70  (30% LESS, not more)     |
//|   • Max levels = 10 (safe because total lots SHRINK)            |
//|                                                                  |
//| Mathematical properties:                                         |
//|   Total lots = base × Σ(0.70^k, k=0..9) ≈ base × 2.87         |
//|   vs Martingale: base × 63  (22x less total exposure at L6)    |
//|                                                                  |
//|   Break-even requires smaller price recovery because later      |
//|   buys are CHEAP — the big position was bought at the TOP.     |
//|                                                                  |
//| Risk: 1% of account as base lot                                 |
//| This is the research strategy. Compare results vs Classic.      |
//+------------------------------------------------------------------+

#property copyright "Research — DecliningGrid"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

CTrade Trade;

//── Inputs ────────────────────────────────────────────────────────
input group "=== RISK ==="
input double RiskPct          = 1.0;   // % of balance for base lot
input double MaxTotalRiskPct  = 5.0;   // Hard stop: close ALL above this drawdown %

input group "=== GRID ==="
input int    AtrPeriod        = 14;    // ATR period (H1)
input double GridMultiplier   = 2.0;   // Grid step = ATR × this (double vs classic)
input double TpMultiplier     = 1.5;   // TP above avgEntry = ATR × this
input int    MaxLevels        = 10;    // Maximum grid levels
input double LotDecayFactor   = 0.70;  // Each level = previous × this (0.70 = -30%)

input group "=== EXECUTION ==="
input int    Magic            = 11002;
input int    MaxSpreadPoints  = 30;

//── Global state ──────────────────────────────────────────────────
double g_levels[];          // Entry price of each level
double g_lots[];            // Lot size of each level
int    g_n_levels     = 0;
double g_next_price   = 0;
double g_base_lot     = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   Trade.SetExpertMagicNumber(Magic);
   Trade.SetDeviationInPoints(20);
   Trade.SetTypeFilling(ORDER_FILLING_IOC);
   g_n_levels = 0;

   double total_geom = 0;
   for(int i=0; i<MaxLevels; i++) total_geom += MathPow(LotDecayFactor, i);
   Print(StringFormat("DecliningGridEA | Risk=%.1f%%  Spacing=ATR×%.1f  "
                       "Decay=%.2f  MaxLevels=%d  MaxTotalLots≈%.2f×base",
                       RiskPct, GridMultiplier, LotDecayFactor,
                       MaxLevels, total_geom));
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
double CalcATR()
{
   double buf[]; ArraySetAsSeries(buf, true);
   int h = iATR(_Symbol, PERIOD_H1, AtrPeriod);
   if(h == INVALID_HANDLE) return 0;
   CopyBuffer(h, 0, 0, 1, buf);
   IndicatorRelease(h);
   return buf[0];
}

double CalcBaseLot(double sl_pips)
{
   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk_amt  = balance * RiskPct / 100.0;
   double tick_val  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double pt        = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(tick_val == 0 || tick_size == 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double pip_money = (pt * 10.0 / tick_size) * tick_val;
   double lots      = risk_amt / MathMax(sl_pips * pip_money, 0.01);
   double step      = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lots = MathFloor(lots / step) * step;
   return MathMax(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN),
          MathMin(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX), lots));
}

double CalcAvgEntry()
{
   double w = 0, tot = 0;
   for(int i = 0; i < g_n_levels; i++) { w += g_lots[i] * g_levels[i]; tot += g_lots[i]; }
   return (tot > 0) ? w / tot : 0;
}

double TotalFloatingLoss()
{
   double avg  = CalcAvgEntry();
   if(avg == 0) return 0;
   double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double pt   = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double pips = MathMax(0, (avg - bid) / (pt * 10.0));
   double tv   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double ts   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double pm   = (pt * 10.0 / ts) * tv;
   double tot  = 0; for(int i=0;i<g_n_levels;i++) tot += g_lots[i];
   return pips * pm * tot;
}

void CloseAll(string reason)
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != Magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      Trade.PositionClose(t);
   }
   g_n_levels = 0; g_next_price = 0;
   Print("DecliningGrid closed: ", reason);
}

bool SpreadOK() { return SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) <= MaxSpreadPoints; }

void PlaceBuy(double lot, int level_idx)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double atr = CalcATR();
   if(Trade.Buy(lot, _Symbol, ask, 0, 0,
                StringFormat("DG_L%d_%.5f", level_idx, ask)))
   {
      int n = g_n_levels + 1;
      ArrayResize(g_levels, n); ArrayResize(g_lots, n);
      g_levels[g_n_levels] = ask;
      g_lots[g_n_levels]   = lot;
      g_n_levels = n;
      g_next_price = ask - atr * GridMultiplier;

      double avg = CalcAvgEntry();
      double total = 0; for(int i=0;i<g_n_levels;i++) total+=g_lots[i];
      Print(StringFormat("DG L%d: BUY %.3f @ %.5f  avg=%.5f  tot=%.3f  "
                          "tp=%.5f  next=%.5f",
                          level_idx, lot, ask, avg, total,
                          avg + atr * TpMultiplier, g_next_price));
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   double atr = CalcATR();
   if(atr == 0) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double tp_dist = atr * TpMultiplier;

   // ── Emergency exit ──────────────────────────────────────────────
   double loss    = TotalFloatingLoss();
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(loss > balance * MaxTotalRiskPct / 100.0 && g_n_levels > 0)
   { CloseAll(StringFormat("Emergency: loss %.1f%%", MaxTotalRiskPct)); return; }

   // ── Take profit check ────────────────────────────────────────────
   if(g_n_levels > 0)
   {
      double avg = CalcAvgEntry();
      if(bid >= avg + tp_dist)
      {
         double pips = tp_dist / (SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10.0);
         CloseAll(StringFormat("TP: avg=%.5f bid=%.5f +%.1fpips", avg, bid, pips));
         return;
      }
   }

   // ── Open first level ─────────────────────────────────────────────
   if(g_n_levels == 0 && SpreadOK())
   {
      double sl_pips = (atr * GridMultiplier * MaxLevels) /
                       (SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10.0);
      g_base_lot = CalcBaseLot(MathMax(sl_pips, 5.0));
      PlaceBuy(g_base_lot, 0);
      return;
   }

   // ── Add next declining level ──────────────────────────────────────
   if(g_n_levels > 0 && g_n_levels < MaxLevels &&
      bid <= g_next_price && SpreadOK())
   {
      // Lot DECREASES by LotDecayFactor
      double prev_lot = g_lots[g_n_levels - 1];
      double new_lot  = prev_lot * LotDecayFactor;
      double step     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      new_lot = MathFloor(new_lot / step) * step;
      new_lot = MathMax(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN), new_lot);
      PlaceBuy(new_lot, g_n_levels);
   }
}

//+------------------------------------------------------------------+
// Dashboard comment on the chart
void OnTimer() {}
void OnChartEvent(const int id, const long& lparam,
                   const double& dparam, const string& sparam)
{
   if(g_n_levels == 0) { Comment("DecliningGrid | Idle"); return; }
   double avg   = CalcAvgEntry();
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double pt    = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double pips  = (avg - bid) / (pt * 10.0);
   double atr   = CalcATR();
   double total = 0;
   for(int i = 0; i < g_n_levels; i++) total += g_lots[i];
   Comment(StringFormat(
      "DecliningGrid | Levels: %d/%d\n"
      "AvgEntry: %.5f  Bid: %.5f\n"
      "Float: %.1f pips\n"
      "TP target: %.5f  (+%.1f pips)\n"
      "Total lots: %.3f  (base: %.3f)",
      g_n_levels, MaxLevels, avg, bid, pips,
      avg + atr * TpMultiplier,
      (atr * TpMultiplier) / (pt * 10.0),
      total, g_base_lot
   ));
}

void OnDeinit(const int reason)
{
   Comment("");
   Print("DecliningGridEA stopped. Levels=", g_n_levels);
}
//+------------------------------------------------------------------+
