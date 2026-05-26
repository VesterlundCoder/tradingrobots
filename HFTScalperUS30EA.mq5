//+------------------------------------------------------------------+
//| HFTScalperUS30EA.mq5                                             |
//| Tick-momentum scalper reverse-engineered from hft-prop-ea        |
//|                                                                  |
//| Strategy fingerprint (31,400 real trades, Jun 2023–Apr 2024):   |
//|   - Fires on every qualifying tick during NY session             |
//|   - Direction = last tick direction (momentum follow)            |
//|   - TP = 2 points, SL = 1 point  →  R:R 2:1                    |
//|   - Max hold = 3 seconds, then force-close at market             |
//|   - One trade at a time, fixed lot, no martingale, no grid       |
//|                                                                  |
//| Observed live stats (hft-prop-ea myfxbook):                     |
//|   WR (non-scratch): 76.4%  |  PF: 6.97  |  R:R: 2.16            |
//|   3,741% gain  |  3.6% max DD  |  ~102 trades/day               |
//|   All trades closed in 1–3 seconds — zero overnight risk         |
//|                                                                  |
//| Broker requirement: US30 CFD, spread ≤ 1.0 pt (IC Markets /    |
//|   Pepperstone / FP Markets recommended — raw/ECN account)        |
//+------------------------------------------------------------------+

#property copyright "Research — HFTScalperUS30"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

CTrade g_trade;

//── Inputs ─────────────────────────────────────────────────────────
input group "=== POSITION SIZING ==="
input double InpLot            = 1.0;    // Fixed lot ($1/pt at most US30 CFDs)

input group "=== ENTRY SIGNAL (tick momentum) ==="
input int    InpTpPoints       = 2;      // Take profit in index points
input int    InpSlPoints       = 1;      // Stop loss in index points
input int    InpMaxHoldSecs    = 5;      // Force-close if still open after N seconds
input int    InpMaxSpreadPts   = 2;      // Skip entry if spread > N points (×SYMBOL_POINT)
input int    InpMinTickMove    = 1;      // Min tick move (in points) to qualify as signal
input bool   InpMomentum       = true;   // true=enter in tick direction; false=counter-tick (mean reversion)

input group "=== SESSION FILTER (NY session — matches original ~98% NY) ==="
input int    InpSessionStartUTC = 13;   // UTC hour to start trading
input int    InpSessionEndUTC   = 17;   // UTC hour to stop new entries
input bool   InpNoFriAfter14   = true;  // Block new entries on Friday after 14:00 UTC

input group "=== DAILY SAFETY NET ==="
input double InpMaxDailyLossPct = 2.0;  // Close all + stop if daily loss > X% of balance

input group "=== EA IDENTITY ==="
input int    InpMagic          = 77301;

//── State ──────────────────────────────────────────────────────────
double   g_prev_bid       = 0;
ulong    g_open_ticket    = 0;
datetime g_trade_open_ts  = 0;
double   g_day_start_bal  = 0;
datetime g_last_day       = 0;
bool     g_daily_stopped  = false;

int      g_n_wins   = 0;
int      g_n_losses = 0;
int      g_n_scratc = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(50);
   g_trade.SetTypeFilling(ORDER_FILLING_IOC);

   g_prev_bid      = 0;
   g_open_ticket   = 0;
   g_trade_open_ts = 0;
   g_daily_stopped = false;
   g_day_start_bal = AccountInfoDouble(ACCOUNT_BALANCE);
   g_last_day      = 0;

   Print(StringFormat(
      "HFTScalperUS30 started | Lot=%.2f TP=%dpts SL=%dpts MaxHold=%ds"
      " Session=%d-%d UTC MaxSpread=%dpts",
      InpLot, InpTpPoints, InpSlPoints, InpMaxHoldSecs,
      InpSessionStartUTC, InpSessionEndUTC, InpMaxSpreadPts));
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
bool SessionOK()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_week == 0 || dt.day_of_week == 6) return false;
   if(InpNoFriAfter14 && dt.day_of_week == 5 && dt.hour >= 14) return false;
   return (dt.hour >= InpSessionStartUTC && dt.hour < InpSessionEndUTC);
}

//+------------------------------------------------------------------+
bool SpreadOK()
{
   double spread = SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                 - SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double pt     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(pt <= 0) return false;
   return (spread / pt) <= InpMaxSpreadPts;
}

//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      g_open_ticket = t;
      return true;
   }
   g_open_ticket = 0;
   return false;
}

//+------------------------------------------------------------------+
void ForceClose(string reason)
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      g_trade.PositionClose(t);
      g_n_scratc++;
   }
   g_open_ticket   = 0;
   g_trade_open_ts = 0;
}

//+------------------------------------------------------------------+
void CheckDailyReset()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   datetime today = (datetime)(TimeCurrent() - dt.hour*3600 - dt.min*60 - dt.sec);
   if(today != g_last_day)
   {
      g_last_day      = today;
      g_day_start_bal = AccountInfoDouble(ACCOUNT_BALANCE);
      g_daily_stopped = false;
   }
}

//+------------------------------------------------------------------+
bool DailyLossExceeded()
{
   if(InpMaxDailyLossPct <= 0) return false;
   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   double worst     = MathMin(balance, equity);
   double loss_pct  = (g_day_start_bal - worst) / g_day_start_bal * 100.0;
   return loss_pct >= InpMaxDailyLossPct;
}

//+------------------------------------------------------------------+
void OnTick()
{
   CheckDailyReset();

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double pt  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(pt <= 0 || bid <= 0) return;

   // ── 1. Max-hold timeout: close position if held too long ────────
   if(HasOpenPosition() && g_trade_open_ts > 0)
   {
      int held = (int)(TimeCurrent() - g_trade_open_ts);
      if(held >= InpMaxHoldSecs)
      {
         ForceClose(StringFormat("MaxHold %ds", held));
         g_prev_bid = bid;
         return;
      }
      // Position still active within hold window — just update prev
      g_prev_bid = bid;
      return;
   }

   // ── 2. Daily loss guard ─────────────────────────────────────────
   if(DailyLossExceeded())
   {
      if(!g_daily_stopped)
      {
         g_daily_stopped = true;
         Print(StringFormat("[HFT] Daily loss limit %.1f%% hit — stopped for today",
                            InpMaxDailyLossPct));
      }
      g_prev_bid = bid;
      return;
   }

   // ── 3. Session + spread gate ────────────────────────────────────
   if(!SessionOK() || !SpreadOK())
   {
      g_prev_bid = bid;
      return;
   }

   // ── 4. Determine tick direction ─────────────────────────────────
   if(g_prev_bid <= 0)
   {
      g_prev_bid = bid;
      return;
   }

   double tick_move_pts = (bid - g_prev_bid) / pt;

   // Need minimum tick movement to fire
   if(MathAbs(tick_move_pts) < InpMinTickMove)
   {
      g_prev_bid = bid;
      return;
   }

   bool tick_up = (tick_move_pts > 0);

   // Momentum: follow tick. Mean-reversion: oppose tick.
   bool go_long = InpMomentum ? tick_up : !tick_up;

   g_prev_bid = bid;

   // ── 5. Calculate SL/TP in price ─────────────────────────────────
   double tp_dist = InpTpPoints * pt;
   double sl_dist = InpSlPoints * pt;

   int digs = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   double tp_price, sl_price;

   if(go_long)
   {
      tp_price = NormalizeDouble(ask + tp_dist, digs);
      sl_price = NormalizeDouble(ask - sl_dist, digs);
   }
   else
   {
      tp_price = NormalizeDouble(bid - tp_dist, digs);
      sl_price = NormalizeDouble(bid + sl_dist, digs);
   }

   // ── 6. Fire the trade ────────────────────────────────────────────
   bool ok = false;
   if(go_long)
      ok = g_trade.Buy (InpLot, _Symbol, ask, sl_price, tp_price, "HFT_B");
   else
      ok = g_trade.Sell(InpLot, _Symbol, bid, sl_price, tp_price, "HFT_S");

   if(ok)
   {
      g_open_ticket   = g_trade.ResultOrder();
      g_trade_open_ts = TimeCurrent();
   }
}

//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeResult      &res,
                        const MqlTradeRequest     &req)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(trans.deal_type == DEAL_TYPE_BALANCE)     return;
   if(HistoryDealSelect(trans.deal) == false)   return;
   if((int)HistoryDealGetInteger(trans.deal, DEAL_MAGIC)  != InpMagic)    return;
   if(HistoryDealGetInteger(trans.deal, DEAL_ENTRY) != DEAL_ENTRY_OUT)    return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol)           return;

   double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
                 + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION)
                 + HistoryDealGetDouble(trans.deal, DEAL_SWAP);

   if(profit > 0.01)       g_n_wins++;
   else if(profit < -0.01) g_n_losses++;
   else                    g_n_scratc++;

   int total = g_n_wins + g_n_losses + g_n_scratc;
   if(total % 100 == 0 && total > 0)
   {
      int active = g_n_wins + g_n_losses;
      double wr  = active > 0 ? (double)g_n_wins / active * 100.0 : 0;
      Print(StringFormat(
         "[HFT] %d trades | W=%d L=%d Scratch=%d | WR(active)=%.1f%%",
         total, g_n_wins, g_n_losses, g_n_scratc, wr));
   }

   g_open_ticket   = 0;
   g_trade_open_ts = 0;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   int total  = g_n_wins + g_n_losses + g_n_scratc;
   int active = g_n_wins + g_n_losses;
   double wr  = active > 0 ? (double)g_n_wins / active * 100.0 : 0;
   Print(StringFormat(
      "HFTScalperUS30 stopped | Total=%d W=%d L=%d Scratch=%d WR(active)=%.1f%%",
      total, g_n_wins, g_n_losses, g_n_scratc, wr));
}
//+------------------------------------------------------------------+
