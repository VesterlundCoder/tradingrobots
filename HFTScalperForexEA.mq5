//+------------------------------------------------------------------+
//| HFTScalperForexEA.mq5                                            |
//| Tick-momentum scalper — Forex port of hft-prop-ea strategy       |
//|                                                                  |
//| Identical logic to HFTScalperUS30EA, adapted for forex:         |
//|   - TP/SL expressed in PIPS (auto pip-size detection)           |
//|   - Session covers London + NY (07:00-17:00 UTC)                |
//|   - Spread guard in pips, not index points                       |
//|   - Works on any pair; best results on ECN tight-spread pairs    |
//|                                                                  |
//| Recommended pairs (ECN/Raw account, spread ≤ 0.3 pip):         |
//|   EURUSD  — most liquid, tightest spread, 24h action             |
//|   GBPUSD  — more volatile, higher profit per tick               |
//|   USDJPY  — high tick frequency during Tokyo/NY overlap         |
//|   XAUUSD  — if available as forex CFD, very high tick rate       |
//|                                                                  |
//| Original live stats (31,400 trades, US30, Jun 2023-Apr 2024):  |
//|   WR 76.4% | PF 6.97 | R:R 2.16 | 3,741% gain | 3.6% max DD   |
//+------------------------------------------------------------------+

#property copyright "Research — HFTScalperForex"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

CTrade g_trade;

//── Inputs ─────────────────────────────────────────────────────────
input group "=== POSITION SIZING ==="
input double InpLot             = 0.01;   // Base lot — multiplied by Leverage_Mult
input double Leverage_Mult      = 30.0;   // Broker leverage (1.0 = no leverage, 30.0 = 1:30)

input group "=== ENTRY SIGNAL ==="
input int    InpTpPips          = 2;      // Take profit in pips
input int    InpSlPips          = 1;      // Stop loss in pips
input int    InpMaxHoldSecs     = 5;      // Force-close if held longer than N seconds
input double InpMaxSpreadPips   = 0.5;   // Skip entry if spread > N pips
input double InpMinTickPips     = 0.1;   // Min tick move in pips to qualify as signal
input bool   InpMomentum        = true;  // true=follow tick; false=counter-tick (mean reversion)

input group "=== SESSION FILTER ==="
input int    InpSessionStartUTC = 7;     // UTC hour — London open
input int    InpSessionEndUTC   = 17;    // UTC hour — NY midday
input bool   InpNoFriAfter14    = true;  // Block new entries on Friday after 14:00 UTC

input group "=== DAILY SAFETY NET ==="
input double InpMaxDailyLossPct = 2.0;  // Stop trading if daily loss > X% of balance

input group "=== EA IDENTITY ==="
input int    InpMagic           = 77302;

//── State ──────────────────────────────────────────────────────────
double   g_pip_size       = 0;   // auto-detected pip size (e.g. 0.0001 for EURUSD)
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
// Pip-size detection: handles 2/3/4/5-digit brokers + XAUUSD
//+------------------------------------------------------------------+
double DetectPipSize()
{
   double pt   = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int    digs = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   // 5-digit forex (EURUSD): pt=0.00001, pip=0.0001 → ×10
   // 3-digit forex (USDJPY): pt=0.001,   pip=0.01  → ×10
   // 4-digit forex (EURUSD old): pt=0.0001, pip=0.0001 → ×1
   // 2-digit (XAUUSD): pt=0.01, pip=0.1 → ×10
   if(digs == 3 || digs == 5) return pt * 10.0;
   return pt;
}

//+------------------------------------------------------------------+
int OnInit()
{
   g_pip_size = DetectPipSize();
   if(g_pip_size <= 0)
   {
      Print("ERROR: could not detect pip size for ", _Symbol);
      return INIT_FAILED;
   }

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(50);
   g_trade.SetTypeFilling(ORDER_FILLING_IOC);

   g_prev_bid      = 0;
   g_open_ticket   = 0;
   g_trade_open_ts = 0;
   g_daily_stopped = false;
   g_day_start_bal = AccountInfoDouble(ACCOUNT_BALANCE);
   g_last_day      = 0;

   double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   Print(StringFormat(
      "HFTScalperForex started | %s | Lot=%.2f TP=%dpips SL=%dpips"
      " MaxHold=%ds Session=%d-%d UTC PipSize=%.5f",
      _Symbol, InpLot, InpTpPips, InpSlPips,
      InpMaxHoldSecs, InpSessionStartUTC, InpSessionEndUTC, g_pip_size));
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
   double spread_price = SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                       - SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double spread_pips  = spread_price / g_pip_size;
   return spread_pips <= InpMaxSpreadPips;
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
void ForceClose()
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
   double worst    = MathMin(AccountInfoDouble(ACCOUNT_BALANCE),
                             AccountInfoDouble(ACCOUNT_EQUITY));
   double loss_pct = (g_day_start_bal - worst) / g_day_start_bal * 100.0;
   return loss_pct >= InpMaxDailyLossPct;
}

//+------------------------------------------------------------------+
void OnTick()
{
   CheckDailyReset();

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid <= 0 || ask <= 0) return;

   int digs = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   // ── 1. Max-hold timeout ─────────────────────────────────────────
   if(HasOpenPosition() && g_trade_open_ts > 0)
   {
      int held = (int)(TimeCurrent() - g_trade_open_ts);
      if(held >= InpMaxHoldSecs)
         ForceClose();
      g_prev_bid = bid;
      return;
   }

   // ── 2. Daily loss guard ─────────────────────────────────────────
   if(DailyLossExceeded())
   {
      if(!g_daily_stopped)
      {
         g_daily_stopped = true;
         Print(StringFormat("[HFTForex] Daily loss %.1f%% hit — stopped for today",
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

   // ── 4. Tick direction signal ─────────────────────────────────────
   if(g_prev_bid <= 0)
   {
      g_prev_bid = bid;
      return;
   }

   double tick_pips = (bid - g_prev_bid) / g_pip_size;

   if(MathAbs(tick_pips) < InpMinTickPips)
   {
      g_prev_bid = bid;
      return;
   }

   bool tick_up  = (tick_pips > 0);
   bool go_long  = InpMomentum ? tick_up : !tick_up;

   g_prev_bid = bid;

   // ── 5. TP / SL in price ─────────────────────────────────────────
   double tp_dist = InpTpPips * g_pip_size;
   double sl_dist = InpSlPips * g_pip_size;

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

   // ── 6. Fire ──────────────────────────────────────────────────────
   bool ok = go_long
      ? g_trade.Buy (InpLot * Leverage_Mult, _Symbol, ask, sl_price, tp_price, "HFTF_B")
      : g_trade.Sell(InpLot * Leverage_Mult, _Symbol, bid, sl_price, tp_price, "HFTF_S");

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
   if(!HistoryDealSelect(trans.deal))           return;
   if((int)HistoryDealGetInteger(trans.deal, DEAL_MAGIC)  != InpMagic) return;
   if(HistoryDealGetInteger(trans.deal, DEAL_ENTRY) != DEAL_ENTRY_OUT) return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol)        return;

   double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
                 + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION)
                 + HistoryDealGetDouble(trans.deal, DEAL_SWAP);

   if(profit >  0.001) g_n_wins++;
   else if(profit < -0.001) g_n_losses++;
   else                g_n_scratc++;

   int total  = g_n_wins + g_n_losses + g_n_scratc;
   int active = g_n_wins + g_n_losses;
   if(total % 50 == 0 && total > 0)
   {
      double wr = active > 0 ? (double)g_n_wins / active * 100.0 : 0;
      double spread_now = (SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                         - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / g_pip_size;
      Print(StringFormat(
         "[HFTForex] %d trades | W=%d L=%d Scratch=%d | WR(active)=%.1f%% | Spread=%.2fpips",
         total, g_n_wins, g_n_losses, g_n_scratc, wr, spread_now));
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
      "HFTScalperForex stopped | %s | Total=%d W=%d L=%d Scratch=%d WR(active)=%.1f%%",
      _Symbol, total, g_n_wins, g_n_losses, g_n_scratc, wr));
}
//+------------------------------------------------------------------+
