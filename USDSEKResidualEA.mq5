//+------------------------------------------------------------------+
//| USDSEKResidualEA.mq5                                             |
//| USD/SEK Statistical Relative-Value Strategy — Version 1          |
//|                                                                  |
//| Concept:                                                         |
//|   Build cross-asset fair-value model via rolling OLS:            |
//|     USDSEK = α + β1·EURUSD + β2·EURSEK + β3·USDJPY + ε         |
//|   Trade the residual z-score when USDSEK deviates from model.   |
//|                                                                  |
//| Signals:                                                         |
//|   z > +2.0  → USDSEK overvalued vs model → SELL                |
//|   z < -2.0  → USDSEK undervalued vs model → BUY                |
//|   |z| < 0.3 → mean reversion complete → CLOSE                  |
//|   |z| > 3.5 → divergence too large → HARD STOP                 |
//|   t > 96h   → TIME STOP                                        |
//|                                                                  |
//| Timeframe: H4 (attach to USDSEK H4 chart)                      |
//| Required symbols in Market Watch: EURUSD, EURSEK, USDJPY        |
//|                                                                  |
//| Research roadmap:                                                |
//|   v1 → Rolling OLS (this file)                                  |
//|   v2 → Kalman filter (time-varying β)                           |
//|   v3 → Bayesian posterior P(mean-reversion within N bars)       |
//|   v4 → RL allocator                                             |
//|                                                                  |
//| v1.1 — Added from PAMM analysis (10 000 real trades):           |
//|   - Session filter  : only enter London(07-17) and NY(17-22)   |
//|     Asia session produced -$64k net across all AUD pairs        |
//|   - Loss streak     : cooldown after N consecutive losses       |
//+------------------------------------------------------------------+

#property copyright "Research — USDSEK ResidualReversion v1"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
CTrade Trade;

//── Inputs ────────────────────────────────────────────────────────

input group "=== MODEL ==="
input int    RegressionWindow  = 500;     // OLS fit window (H4 bars, ~3 months)
input int    ZScoreWindow      = 200;     // Residual z-score window (H4 bars)
input string SymEURUSD         = "EURUSD";
input string SymEURSEK         = "EURSEK";
input string SymUSDJPY         = "USDJPY";

input group "=== SIGNAL ==="
input double ZEntry            = 2.0;    // Enter when |z| exceeds this
input double ZExit             = 0.30;   // Exit when |z| falls below this
input double ZHardStop         = 3.5;    // Hard statistical stop
input int    TimeStopHours     = 96;     // Max hours to hold position

input group "=== RISK ==="
input double RiskPct           = 0.25;   // % of equity at risk per trade
input int    AtrPeriod         = 20;     // ATR period for sizing + regime
input double AtrHighMult       = 1.7;    // Block entry if ATR > mult × median ATR
input double MaxSpreadAtrRatio = 0.08;   // Block entry if spread > ratio × ATR

input group "=== SESSION FILTER (analysis: Asia session = -$64k net) ==="
input bool   UseSessionFilter  = true;  // Block new entries outside window
input int    SessionStart      = 7;     // Hour to start allowing new entries (broker time)
input int    SessionEnd        = 22;    // Hour to stop allowing new entries (broker time)
input bool   NoFriAfter20      = true;  // No new entries Friday after 20:00

input group "=== LOSS STREAK FILTER ==="
input bool   UseLossFilter     = true;  // Pause after N consecutive losses
input int    MaxConsecLosses   = 2;     // Stat arb is more sensitive — lower threshold
input int    CooldownBars      = 24;    // H4 bars to wait (24 × 4h = 4 days)

input group "=== EXECUTION ==="
input int    Magic             = 12001;

//── Globals ───────────────────────────────────────────────────────
datetime g_last_bar    = 0;
datetime g_entry_time  = 0;
int      g_pos_dir     = 0;    // 1=long, -1=short, 0=flat
double   g_last_z      = 0;
double   g_last_beta[4];       // α, β_EURUSD, β_EURSEK, β_USDJPY
int      g_n_entries   = 0;
int      g_n_z_stops   = 0;
int      g_n_t_stops   = 0;
int      g_n_exits     = 0;
int      g_consec_losses = 0;  // consecutive closing losses
int      g_cooldown_bars = 0;  // H4 bars remaining in cooldown

//+------------------------------------------------------------------+
int OnInit()
{
   Trade.SetExpertMagicNumber(Magic);
   Trade.SetDeviationInPoints(60);
   // Filling mode: auto-detect from symbol to avoid broker-specific rejections
   ENUM_ORDER_TYPE_FILLING fill = (ENUM_ORDER_TYPE_FILLING)
      (int)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((fill & ORDER_FILLING_IOC) != 0)       Trade.SetTypeFilling(ORDER_FILLING_IOC);
   else if((fill & ORDER_FILLING_FOK) != 0)  Trade.SetTypeFilling(ORDER_FILLING_FOK);
   else                                       Trade.SetTypeFilling(ORDER_FILLING_RETURN);

   ArrayInitialize(g_last_beta, 0);
   g_consec_losses = 0;
   g_cooldown_bars = 0;

   // Try to add feature symbols to Market Watch
   string syms[3];
   syms[0] = SymEURUSD; syms[1] = SymEURSEK; syms[2] = SymUSDJPY;
   for(int i = 0; i < 3; i++)
   {
      bool sel = SymbolSelect(syms[i], true);
      Print(StringFormat("[USDSEK-EA] Symbol %s → %s",
            syms[i], sel ? "OK in Market Watch" : "NOT FOUND — add manually!"));
   }

   Print(StringFormat(
      "USDSEK ResidualReversion v1 STARTED | Symbol=%s | RegWin=%d ZWin=%d | "
      "z_in=%.1f z_out=%.2f z_stop=%.1f | tStop=%dh | Risk=%.2f%%",
      _Symbol, RegressionWindow, ZScoreWindow,
      ZEntry, ZExit, ZHardStop, TimeStopHours, RiskPct));

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//  Bar & position helpers
//+------------------------------------------------------------------+

bool IsNewH4Bar()
{
   datetime t[1];
   if(CopyTime(_Symbol, PERIOD_H4, 0, 1, t) < 1) return false;
   if(t[0] != g_last_bar)
   {
      g_last_bar = t[0];
      if(g_cooldown_bars > 0) g_cooldown_bars--;  // count down on each new H4 bar
      return true;
   }
   return false;
}

bool SessionOK()
{
   if(!UseSessionFilter) return true;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int h   = dt.hour;
   int dow = dt.day_of_week;
   if(dow == 0 || dow == 6)           return false;  // no weekend
   if(NoFriAfter20 && dow == 5 && h >= 20) return false;
   return (h >= SessionStart && h < SessionEnd);
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &req,
                        const MqlTradeResult      &res)
{
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
            Print(StringFormat("[USDSEK-EA] Loss streak %d — cooldown %d H4 bars (~%dd)",
                               g_consec_losses, CooldownBars, CooldownBars/6));
         }
      }
      else { g_consec_losses = 0; }
   }
}

int GetPosDir()
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(!PositionSelectByTicket(tk)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != Magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)    continue;
      return (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
   }
   return 0;
}

void CloseAll(string reason)
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(!PositionSelectByTicket(tk)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != Magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)    continue;
      Trade.PositionClose(tk);
   }
   Print(StringFormat("[USDSEK-EA] CLOSE | %s | z=%.3f", reason, g_last_z));
   g_pos_dir    = 0;
   g_entry_time = 0;
}

//+------------------------------------------------------------------+
//  ATR helpers
//+------------------------------------------------------------------+

double GetATR(int shift = 0)
{
   double buf[1]; ArraySetAsSeries(buf, true);
   int h = iATR(_Symbol, PERIOD_H4, AtrPeriod);
   if(h == INVALID_HANDLE) return 0;
   CopyBuffer(h, 0, shift, 1, buf);
   IndicatorRelease(h);
   return buf[0];
}

double GetMedianATR()
{
   double buf[]; ArraySetAsSeries(buf, true);
   int h = iATR(_Symbol, PERIOD_H4, AtrPeriod);
   if(h == INVALID_HANDLE) return 0;
   if(CopyBuffer(h, 0, 1, 100, buf) < 100) { IndicatorRelease(h); return 0; }
   IndicatorRelease(h);
   double sorted[];
   ArrayCopy(sorted, buf);
   ArraySort(sorted);
   return sorted[50];
}

//+------------------------------------------------------------------+
//  Regime filter
//+------------------------------------------------------------------+

bool RegimeOK()
{
   double atr    = GetATR();
   double median = GetMedianATR();
   if(atr <= 0 || median <= 0) return false;

   // Block if volatility is abnormally high
   if(atr > median * AtrHighMult)
   {
      Print(StringFormat("[USDSEK-EA] Regime BLOCKED: high vol ATR=%.5f > %.1f×median=%.5f",
                          atr, AtrHighMult, median));
      return false;
   }

   // Block if spread is too wide relative to ATR
   double spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD)
                   * SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(spread > atr * MaxSpreadAtrRatio)
   {
      Print(StringFormat("[USDSEK-EA] Regime BLOCKED: wide spread=%.5f vs ATR=%.5f", spread, atr));
      return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//  Core: Rolling OLS → residual z-score  (fully inlined, no       |
//  external array passing — avoids all MQL5 array-ref restrictions)|
//  Model: USDSEK = α + β1*EURUSD + β2*EURSEK + β3*USDJPY + ε     |
//+------------------------------------------------------------------+

bool ComputeResidualZ(double &z_out)
{
   int N  = RegressionWindow;
   int ZW = MathMin(ZScoreWindow, N);

   // ── Fetch price series (index 0 = most recent bar) ────────────
   double y_arr[], eu[], es[], uj[];
   ArraySetAsSeries(y_arr, true);
   ArraySetAsSeries(eu,    true);
   ArraySetAsSeries(es,    true);
   ArraySetAsSeries(uj,    true);

   if(CopyClose(_Symbol,   PERIOD_H4, 0, N, y_arr) < N) return false;
   if(CopyClose(SymEURUSD, PERIOD_H4, 0, N, eu)    < N) return false;
   if(CopyClose(SymEURSEK, PERIOD_H4, 0, N, es)    < N) return false;
   if(CopyClose(SymUSDJPY, PERIOD_H4, 0, N, uj)    < N) return false;

   // ── Build augmented matrix M[4][5] = [XtX | Xty] directly ────
   // Row/col order: [const, EURUSD, EURSEK, USDJPY]
   double M[4][5];
   int r, c;
   for(r = 0; r < 4; r++)
      for(c = 0; c < 5; c++) M[r][c] = 0.0;

   for(int i = 0; i < N; i++)
   {
      double x0=1.0, x1=eu[i], x2=es[i], x3=uj[i], yi=y_arr[i];
      double xi[4]; xi[0]=x0; xi[1]=x1; xi[2]=x2; xi[3]=x3;
      for(r = 0; r < 4; r++)
      {
         M[r][0] += xi[r]*x0;
         M[r][1] += xi[r]*x1;
         M[r][2] += xi[r]*x2;
         M[r][3] += xi[r]*x3;
         M[r][4] += xi[r]*yi;   // Xty column
      }
   }

   // ── Gaussian elimination with partial pivoting ─────────────────
   for(int col = 0; col < 4; col++)
   {
      int pivot = col;
      for(r = col+1; r < 4; r++)
         if(MathAbs(M[r][col]) > MathAbs(M[pivot][col])) pivot = r;
      if(pivot != col)
         for(c = 0; c < 5; c++)
         { double tmp=M[col][c]; M[col][c]=M[pivot][c]; M[pivot][c]=tmp; }

      if(MathAbs(M[col][col]) < 1e-12)
      { Print("[USDSEK-EA] OLS singular — not enough bar variety"); return false; }

      for(r = col+1; r < 4; r++)
      {
         double f = M[r][col] / M[col][col];
         for(c = col; c < 5; c++) M[r][c] -= f * M[col][c];
      }
   }

   // ── Back substitution → beta[4] ───────────────────────────────
   double beta[4];
   for(int i = 3; i >= 0; i--)
   {
      beta[i] = M[i][4];
      for(int j = i+1; j < 4; j++) beta[i] -= M[i][j] * beta[j];
      beta[i] /= M[i][i];
   }
   for(int j = 0; j < 4; j++) g_last_beta[j] = beta[j];

   // ── Residuals for ZW most-recent bars ─────────────────────────
   double resids[]; ArrayResize(resids, ZW);
   for(int i = 0; i < ZW; i++)
      resids[i] = y_arr[i] - (beta[0] + beta[1]*eu[i] + beta[2]*es[i] + beta[3]*uj[i]);

   // ── Z-score of current (index 0) residual ─────────────────────
   double sum=0, sq=0;
   for(int i = 0; i < ZW; i++) { sum += resids[i]; sq += resids[i]*resids[i]; }
   double mean_r = sum / ZW;
   double var_r  = sq / ZW - mean_r * mean_r;
   if(var_r < 1e-14) return false;

   z_out = (resids[0] - mean_r) / MathSqrt(var_r);
   return true;
}

//+------------------------------------------------------------------+
//  Position sizing: Risk% / (1 ATR as proxy stop)
//+------------------------------------------------------------------+

double CalcLots()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double risk   = equity * RiskPct / 100.0;
   double atr    = GetATR();
   if(atr <= 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   double tv   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double ts   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double pt   = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(tv == 0 || ts == 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   // ATR expressed in ticks × tick_value = $ risk per lot
   double lots = risk / (atr / pt * tv / (ts / pt));
   // Simplification: lots = risk / (atr_in_ticks × tick_value)
   double atr_ticks = atr / ts;
   lots = risk / (atr_ticks * tv);

   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lots = MathFloor(lots / step) * step;
   return MathMax(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN),
          MathMin(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX), lots));
}

//+------------------------------------------------------------------+
//  Chart comment
//+------------------------------------------------------------------+

void UpdateComment()
{
   string pos_str = (g_pos_dir ==  1) ? "LONG"  :
                    (g_pos_dir == -1) ? "SHORT" : "FLAT";
   int hrs = (g_entry_time > 0 && g_pos_dir != 0) ?
             (int)((TimeCurrent() - g_entry_time) / 3600) : 0;

   string z_bar = "";
   double az = MathAbs(g_last_z);
   if(az < ZExit)      z_bar = " ← EXIT ZONE";
   else if(az > ZHardStop) z_bar = " ← STOP ZONE!";
   else if(az > ZEntry)    z_bar = " ← SIGNAL ZONE";

   Comment(StringFormat(
      "USDSEK Residual Reversion v1\n"
      "────────────────────────────────\n"
      "Z-score :  %+.4f%s\n"
      "Thresholds: entry=±%.1f  exit=±%.2f  stop=±%.1f\n"
      "ATR(H4) :  %.5f\n"
      "\n"
      "Model coefficients (last fit):\n"
      "  α      = %+.5f\n"
      "  EURUSD = %+.4f\n"
      "  EURSEK = %+.4f\n"
      "  USDJPY = %+.5f\n"
      "\n"
      "Position: %s%s\n"
      "────────────────────────────────\n"
      "Entries: %d  Z-stops: %d  T-stops: %d  Exits: %d  Streak: %d\n"
      "RegWin: %d bars  ZWin: %d bars  (H4)",
      g_last_z, z_bar,
      ZEntry, ZExit, ZHardStop,
      GetATR(),
      g_last_beta[0], g_last_beta[1], g_last_beta[2], g_last_beta[3],
      pos_str,
      (hrs > 0) ? StringFormat(" [%dh / %dh]", hrs, TimeStopHours) : "",
      g_n_entries, g_n_z_stops, g_n_t_stops, g_n_exits, g_consec_losses,
      RegressionWindow, ZScoreWindow
   ));
}

//+------------------------------------------------------------------+
void OnTick()
{
   if(!IsNewH4Bar()) return;

   // ── Compute residual z-score ──────────────────────────────────
   double z = 0;
   if(!ComputeResidualZ(z)) { UpdateComment(); return; }
   g_last_z  = z;
   g_pos_dir = GetPosDir();

   // ── Manage existing position ──────────────────────────────────
   if(g_pos_dir != 0)
   {
      // Statistical hard stop
      if(MathAbs(z) > ZHardStop)
      {
         CloseAll(StringFormat("Z-STOP |z|=%.3f > %.1f", MathAbs(z), ZHardStop));
         g_n_z_stops++;
         UpdateComment();
         return;
      }

      // Time stop
      if(g_entry_time > 0)
      {
         int hrs = (int)((TimeCurrent() - g_entry_time) / 3600);
         if(hrs >= TimeStopHours)
         {
            CloseAll(StringFormat("TIME-STOP %dh >= %dh", hrs, TimeStopHours));
            g_n_t_stops++;
            UpdateComment();
            return;
         }
      }

      // Mean-reversion exit: z has reverted to near zero
      if(MathAbs(z) < ZExit)
      {
         CloseAll(StringFormat("Z-EXIT |z|=%.4f < %.2f", MathAbs(z), ZExit));
         g_n_exits++;
         UpdateComment();
         return;
      }

      // Optional: wrong direction deepening (model says flip)
      // If we are long and z shoots above +ZEntry again — model disagrees
      if(g_pos_dir == 1 && z > ZEntry)
      {
         CloseAll("Signal flip: long but z > +entry");
         UpdateComment();
         return;
      }
      if(g_pos_dir == -1 && z < -ZEntry)
      {
         CloseAll("Signal flip: short but z < -entry");
         UpdateComment();
         return;
      }

      UpdateComment();
      return;
   }

   // ── No position — check for new entry ────────────────────────
   if(!RegimeOK())    { UpdateComment(); return; }
   if(!SessionOK())   { UpdateComment(); return; }
   if(g_cooldown_bars > 0)
   {
      Print(StringFormat("[USDSEK-EA] Cooldown active: %d H4 bars remaining", g_cooldown_bars));
      UpdateComment(); return;
   }

   if(z > ZEntry)        // USDSEK overvalued → SHORT
   {
      double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double lots = CalcLots();
      if(Trade.Sell(lots, _Symbol, bid, 0, 0,
                    StringFormat("RR_SHORT z=%+.3f", z)))
      {
         g_entry_time = TimeCurrent();
         g_pos_dir    = -1;
         g_n_entries++;
         Print(StringFormat("[USDSEK-EA] SELL  %.4f lots @ %.5f  z=%+.3f  "
                             "α=%.4f β_EU=%+.4f β_ES=%+.4f β_UJ=%+.5f",
                             lots, bid, z,
                             g_last_beta[0], g_last_beta[1],
                             g_last_beta[2], g_last_beta[3]));
      }
   }
   else if(z < -ZEntry)  // USDSEK undervalued → LONG
   {
      double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double lots = CalcLots();
      if(Trade.Buy(lots, _Symbol, ask, 0, 0,
                   StringFormat("RR_LONG  z=%+.3f", z)))
      {
         g_entry_time = TimeCurrent();
         g_pos_dir    = 1;
         g_n_entries++;
         Print(StringFormat("[USDSEK-EA] BUY   %.4f lots @ %.5f  z=%+.3f  "
                             "α=%.4f β_EU=%+.4f β_ES=%+.4f β_UJ=%+.5f",
                             lots, ask, z,
                             g_last_beta[0], g_last_beta[1],
                             g_last_beta[2], g_last_beta[3]));
      }
   }

   UpdateComment();
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Comment("");
   Print(StringFormat(
      "[USDSEK-EA] Stopped | Entries=%d  Z-stops=%d  T-stops=%d  Exits=%d",
      g_n_entries, g_n_z_stops, g_n_t_stops, g_n_exits));
}
//+------------------------------------------------------------------+
