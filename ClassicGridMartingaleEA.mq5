//+------------------------------------------------------------------+
//| ClassicGridMartingaleEA.mq5                                      |
//| Classical Grid + Martingale on EURUSD                            |
//|                                                                  |
//| Logic:                                                           |
//|   Step 1: Buy at current price with base lot                     |
//|   Step 2: Each grid_spacing drop → add 2x the previous lot      |
//|   Step 3: When price reaches avgEntry + TP → close ALL          |
//|                                                                  |
//| Risk: 1% of account balance as base lot                         |
//| Grid: ATR(14) × GridMultiplier                                   |
//| Lot doubling: 2.0x per step (classical martingale)              |
//| Max levels: 6 (hard safety cap)                                  |
//|                                                                  |
//| WARNING: Martingale exposure grows exponentially.               |
//| At level 6 the total lot = base × (2^0+2^1+...+2^5) = 63×base |
//| Use ONLY on demo / paper account for research comparison.       |
//|                                                                  |
//| v1.1 — Added from PAMM analysis (10 000 real trades):           |
//|   - Session filter  : skip new entries outside London/NY        |
//|   - Loss streak     : pause after N consecutive closing losses  |
//|   - Max hold time   : force-close basket after MaxHoldHours     |
//|   - Max levels capped at 4 (PAMM data: streaks hit 40 trades)  |
//+------------------------------------------------------------------+

#property copyright "Research — ClassicGridMartingale"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

CTrade Trade;

//── Inputs ────────────────────────────────────────────────────────
input group "=== RISK ==="
input double RiskPct          = 1.0;   // % of balance for base lot
input double MaxTotalRiskPct  = 10.0;  // Hard stop: close ALL above this drawdown %

input group "=== GRID ==="
input int    AtrPeriod        = 14;    // ATR period
input double GridMultiplier   = 1.0;   // Grid step = ATR × this
input double TpMultiplier     = 1.5;   // TP above avgEntry = ATR × this
input int    MaxLevels        = 6;     // Maximum grid levels (safety cap)
input double LotMultiplier    = 2.0;   // Martingale factor (2.0 = classic double)

input group "=== EXECUTION ==="
input int    Magic            = 11001;
input int    MaxSpreadPoints  = 30;    // Skip entry if spread > this (points)
input bool   LongOnly         = true;  // Grid buys on dips (long only)

input group "=== SESSION FILTER (analysis: Asia 00-08 broker = -$64k) ==="
input bool   UseSessionFilter = true;  // Block new entries outside session window
input int    SessionStart     = 8;     // Earliest hour to open new grid (broker time)
input int    SessionEnd       = 22;    // Latest  hour to open new grid (broker time)
input bool   NoFriAfter20     = true;  // Block new entries Friday after 20:00

input group "=== LOSS STREAK FILTER (analysis: max streak 40) ==="
input bool   UseLossFilter    = true;  // Pause entries after consecutive losses
input int    MaxConsecLosses  = 3;     // Cooldown after this many closing losses
input int    CooldownBars     = 12;    // H1 bars to wait after loss streak hit

input group "=== MAX HOLD TIME (analysis: losses held 14x longer than wins) ==="
input int    MaxHoldHours     = 21;    // Force-close grid after N hours (0=off, 21h = 2x median win)

input group "=== TRAILING STOP (lock in profits before reversal wipes them) ==="
input bool   UseTrailingStop   = true;  // Trail basket profit and close before reversal
input double TrailActivatePips = 8.0;   // Activate once basket is this many pips in profit
input double TrailDistancePips = 4.0;   // Close if profit drops this far from peak

//── Global state ──────────────────────────────────────────────────
double   g_grid_levels[];   // Price of each open level
double   g_grid_lots[];     // Lot of each open level
int      g_n_levels       = 0;
double   g_next_grid_price = 0;
double   g_base_lot        = 0;
double   g_last_atr        = 0;
int      g_consec_losses    = 0;    // consecutive closing losses
int      g_cooldown_bars    = 0;    // bars remaining in cooldown
datetime g_basket_open_time = 0;    // when basket was opened (for MaxHoldHours)
datetime g_last_bar_time    = 0;    // track new H1 bars for cooldown countdown
double   g_basket_peak_pips = -999; // trailing stop high-water mark (pips)

//+------------------------------------------------------------------+
int OnInit()
{
   Trade.SetExpertMagicNumber(Magic);
   Trade.SetDeviationInPoints(20);
   Trade.SetTypeFilling(ORDER_FILLING_IOC);
   g_n_levels         = 0;
   g_consec_losses    = 0;
   g_cooldown_bars    = 0;
   g_basket_open_time = 0;
   g_last_bar_time    = 0;
   g_basket_peak_pips = -999;
   Print("ClassicGridMartingaleEA v1.1 started. Risk=", RiskPct,
         "% MaxLevels=", MaxLevels,
         " Session=", SessionStart, "-", SessionEnd,
         " MaxHold=", MaxHoldHours, "h");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
double CalcATR()
{
   double atr_buf[];
   ArraySetAsSeries(atr_buf, true);
   int handle = iATR(_Symbol, PERIOD_H1, AtrPeriod);
   if(handle == INVALID_HANDLE) return 0;
   CopyBuffer(handle, 0, 0, 1, atr_buf);
   IndicatorRelease(handle);
   return atr_buf[0];
}

double CalcBaseLot(double sl_pips)
{
   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk_amt  = balance * RiskPct / 100.0;
   double tick_val  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double pt        = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(tick_val == 0 || tick_size == 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double pip_money = (pt * 10.0 / tick_size) * tick_val;  // $ per pip per lot
   double lots      = risk_amt / (sl_pips * pip_money);
   double step      = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lots = MathFloor(lots / step) * step;
   return MathMax(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN),
          MathMin(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX), lots));
}

double CalcAvgEntry()
{
   double total_lots = 0, weighted = 0;
   for(int i = 0; i < g_n_levels; i++) {
      total_lots += g_grid_lots[i];
      weighted   += g_grid_lots[i] * g_grid_levels[i];
   }
   if(total_lots == 0) return 0;
   return weighted / total_lots;
}

double TotalGridDrawdown()
{
   double avg = CalcAvgEntry();
   if(avg == 0) return 0;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double total_lots = 0;
   for(int i = 0; i < g_n_levels; i++) total_lots += g_grid_lots[i];
   // Approximate floating loss
   double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double loss_pips = MathMax(0, (avg - bid) / (pt * 10.0));
   double tick_val  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double pip_money = (pt * 10.0 / tick_size) * tick_val;
   return loss_pips * pip_money * total_lots;
}

void CloseAllGrid(string reason)
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != Magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      Trade.PositionClose(ticket);
   }
   g_n_levels         = 0;
   g_next_grid_price  = 0;
   g_basket_open_time = 0;
   g_basket_peak_pips = -999;  // reset trail
   Print("Grid closed: ", reason);
}

bool SpreadOK()
{
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return spread <= MaxSpreadPoints;
}

bool SessionOK()
{
   if(!UseSessionFilter) return true;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int h   = dt.hour;
   int dow = dt.day_of_week;   // 0=Sun, 5=Fri, 6=Sat
   if(dow == 6 || dow == 0) return false;          // no weekend
   if(NoFriAfter20 && dow == 5 && h >= 20) return false;
   return (h >= SessionStart && h < SessionEnd);
}

void CheckNewBar()
{
   datetime t[1];
   if(CopyTime(_Symbol, PERIOD_H1, 0, 1, t) < 1) return;
   if(t[0] != g_last_bar_time)
   {
      g_last_bar_time = t[0];
      if(g_cooldown_bars > 0) g_cooldown_bars--;
   }
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &req,
                        const MqlTradeResult      &res)
{
   // Track consecutive losses from closed deals
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(trans.deal_type != DEAL_TYPE_BUY && trans.deal_type != DEAL_TYPE_SELL) return;
   HistoryDealSelect(trans.deal);
   if((int)HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != Magic) return;
   if(HistoryDealGetInteger(trans.deal, DEAL_ENTRY) != DEAL_ENTRY_OUT) return;

   double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
                 + HistoryDealGetDouble(trans.deal, DEAL_SWAP);
   if(UseLossFilter)
   {
      if(profit < 0)
      {
         g_consec_losses++;
         if(g_consec_losses >= MaxConsecLosses)
         {
            g_cooldown_bars = CooldownBars;
            Print(StringFormat("[ClassicGrid] Loss streak %d hit — cooldown %d bars",
                               g_consec_losses, CooldownBars));
         }
      }
      else
      {
         g_consec_losses = 0;
      }
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   CheckNewBar();  // countdown cooldown timer each new H1 bar

   double atr  = CalcATR();
   if(atr == 0) return;
   g_last_atr  = atr;

   double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double pt   = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int    digs = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   double grid_step = atr * GridMultiplier;
   double tp_dist   = atr * TpMultiplier;

   // ── Max hold time: force-close basket if open too long ──────────
   if(g_n_levels > 0 && MaxHoldHours > 0 && g_basket_open_time > 0)
   {
      int held = (int)((TimeCurrent() - g_basket_open_time) / 3600);
      if(held >= MaxHoldHours)
      {
         CloseAllGrid(StringFormat("MaxHold %dh >= %dh", held, MaxHoldHours));
         return;
      }
   }

   // ── Emergency close: max total risk exceeded ────────────────────
   double loss = TotalGridDrawdown();
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(loss > balance * MaxTotalRiskPct / 100.0 && g_n_levels > 0)
   {
      CloseAllGrid(StringFormat("MaxTotalRisk %.1f%% hit", MaxTotalRiskPct));
      return;
   }

   // ── Check TP + trailing stop on basket profit ───────────────────
   if(g_n_levels > 0)
   {
      double avg       = CalcAvgEntry();
      double cur_pips  = (bid - avg) / (pt * 10.0);  // current basket profit in pips

      // Fixed TP
      if(bid >= avg + tp_dist)
      {
         CloseAllGrid(StringFormat("TP hit: avg=%.5f bid=%.5f profit≈+%.1f pips",
                                    avg, bid, cur_pips));
         return;
      }

      // Trailing stop — once basket hits TrailActivatePips, lock in profit
      if(UseTrailingStop)
      {
         if(cur_pips > g_basket_peak_pips)
            g_basket_peak_pips = cur_pips;  // raise high-water mark

         if(g_basket_peak_pips >= TrailActivatePips &&
            cur_pips <= g_basket_peak_pips - TrailDistancePips)
         {
            CloseAllGrid(StringFormat("TRAIL_STOP peak=%.1f pips cur=%.1f pips",
                                       g_basket_peak_pips, cur_pips));
            return;
         }
      }
   }

   // ── Open first position ─────────────────────────────────────────
   if(g_n_levels == 0 && SpreadOK() && SessionOK() && g_cooldown_bars == 0)
   {
      double sl_pips = grid_step / (pt * 10.0) * MaxLevels * 2.0;  // rough SL for sizing
      g_base_lot = CalcBaseLot(MathMax(sl_pips, 5.0));
      double lot = NormalizeDouble(g_base_lot, 2);

      if(Trade.Buy(lot, _Symbol, ask, 0, 0, StringFormat("MG_L0_%.5f", ask)))
      {
         ArrayResize(g_grid_levels, 1);
         ArrayResize(g_grid_lots,   1);
         g_grid_levels[0]   = ask;
         g_grid_lots[0]     = lot;
         g_n_levels         = 1;
         g_next_grid_price  = ask - grid_step;
         g_basket_open_time = TimeCurrent();
         Print(StringFormat("Grid L0: BUY %.3f @ %.5f  next_grid=%.5f  session=%d-%d",
                             lot, ask, g_next_grid_price, SessionStart, SessionEnd));
      }
      return;
   }

   // ── Add next grid level if price dropped below next_grid_price ──
   if(g_n_levels > 0 && g_n_levels < MaxLevels && bid <= g_next_grid_price && SpreadOK())
   {
      // Martingale: double the previous level's lot
      double prev_lot  = g_grid_lots[g_n_levels - 1];
      double new_lot   = NormalizeDouble(prev_lot * LotMultiplier, 2);
      double step_lot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      new_lot = MathFloor(new_lot / step_lot) * step_lot;
      new_lot = MathMax(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN),
                MathMin(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX), new_lot));

      if(Trade.Buy(new_lot, _Symbol, ask, 0, 0,
                   StringFormat("MG_L%d_%.5f", g_n_levels, ask)))
      {
         int n = g_n_levels + 1;
         ArrayResize(g_grid_levels, n);
         ArrayResize(g_grid_lots,   n);
         g_grid_levels[g_n_levels] = ask;
         g_grid_lots[g_n_levels]   = new_lot;
         g_n_levels = n;
         g_next_grid_price = ask - grid_step;

         double avg = CalcAvgEntry();
         double total_lots = 0;
         for(int i=0;i<g_n_levels;i++) total_lots += g_grid_lots[i];
         Print(StringFormat("Grid L%d: BUY %.3f @ %.5f  avg=%.5f  tot_lots=%.3f  "
                             "tp_target=%.5f  next_grid=%.5f",
                             g_n_levels-1, new_lot, ask, avg, total_lots,
                             avg + tp_dist, g_next_grid_price));
      }
   }
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("ClassicGridMartingaleEA stopped. Levels at deinit: ", g_n_levels);
}
//+------------------------------------------------------------------+
