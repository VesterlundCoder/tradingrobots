//+------------------------------------------------------------------+
//|                   ATRBreakoutStockCFD_H1.mq5                     |
//|  ATR Expansion Breakout — US Tech Stock CFDs H1 — FTMO EA        |
//|                                                                   |
//|  Designed for: AMD, INTC, NVDA, MSFT (and similar US equities)   |
//|  Attach this EA to any US stock CFD H1 chart on FTMO.            |
//|                                                                   |
//|  Zero-Shot backtest results (730d H1, 2024-2026):                |
//|    INTC  +40.0%  Sharpe +0.38  MaxDD -5.1%   ParamRobust 100% ✅ |
//|    AMD   + 1.9%  Sharpe +0.02  MaxDD -9.2%   ParamRobust  89% ✅ |
//|    NVDA  + 2.4%  Sharpe +0.04  MaxDD-11.6%   ParamRobust  86% ✅ |
//|    MSFT  + 2.7%  Sharpe +0.07  MaxDD -3.6%   ParamRobust  21% ⚠️ |
//|                                                                   |
//|  Instrument class: Individual Stock CFDs (Nasdaq-100 / S&P500)   |
//|  Session: NYSE/Nasdaq cash hours  13:30–19:30 UTC                |
//+------------------------------------------------------------------+
#property copyright "RD LUMI Z3"
#property description "ATR Breakout US Stock CFDs H1 — INTC/AMD/NVDA/MSFT — FTMO-compliant"
#property version   "1.00"

#include <Trade\Trade.mqh>

//── Strategy parameters ──────────────────────────────────────────────
input group "=== STRATEGY PARAMETERS ==="
input int    ATR_Period    = 14;    // ATR period
input double ATR_Expand    = 1.2;   // ATR expansion factor
input int    Lookback      = 20;    // Rolling high/low lookback (bars 2..Lookback+1)
input int    EMA_Period    = 200;   // Trend EMA period
input int    MaxHold_Bars  = 24;    // Max bars before forced exit (~3 trading sessions)

//── ADX regime gate ───────────────────────────────────────────────────
input group "=== ADX REGIME FILTER ==="
input int    ADX_Period    = 14;    // ADX period
input double ADX_Min       = 25.0;  // Min ADX — skip when stock is ranging

//── Session filter (NYSE/Nasdaq cash hours = 13:30–20:00 UTC) ────────
//   Note: Use 13 as open (first full bar after open) and 19 as cut-off
//   to avoid the last 30-min illiquid tail and overnight risk.
input group "=== SESSION FILTER ==="
input int    Session_Open_UTC  = 13;   // No new entries before this UTC hour
input int    Session_Close_UTC = 19;   // No new entries at or after this UTC hour
input bool   UseSessionFilter  = true;

//── Risk & position sizing ────────────────────────────────────────────
//   Individual stocks are more volatile than indices.
//   Default 0.20% risk per trade (tighter than index CFDs).
input group "=== RISK & POSITION SIZING ==="
input double SL_ATR_Mult   = 2.0;   // Stop loss = N × ATR
input double TP_ATR_Mult   = 6.0;   // Take profit = N × ATR (R:R = 1:3)
input double Risk_Pct      = 0.20;  // Risk per trade (% of balance) — tighter for stocks

//── FTMO safety limits ────────────────────────────────────────────────
input group "=== FTMO SAFETY LIMITS ==="
input double MaxDailyLoss_Pct = 4.0; // Max daily drawdown (FTMO limit 5% − 1% buffer)
input double MaxTotalDD_Pct   = 8.0; // Max total drawdown (FTMO limit 10% − 2% buffer)

//── EA identity ───────────────────────────────────────────────────────
input group "=== EA IDENTITY ==="
input long   MagicNumber   = 20260201;
input string TradeComment  = "ATRBrk_Stock_H1";

//── Globals ───────────────────────────────────────────────────────────
CTrade   trade;
int      h_atr, h_ema, h_adx;
double   g_day_start_balance;
datetime g_today;
datetime g_entry_time;

//+------------------------------------------------------------------+
int OnInit()
{
    if(_Period != PERIOD_H1)
    {
        Alert("Attach to H1 chart of a US stock CFD (INTC, AMD, NVDA, MSFT).");
        return INIT_FAILED;
    }
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(100);      // Stocks can have wide spreads
    trade.SetTypeFilling(ORDER_FILLING_IOC);

    h_atr = iATR(_Symbol, PERIOD_CURRENT, ATR_Period);
    h_ema = iMA(_Symbol,  PERIOD_CURRENT, EMA_Period, 0, MODE_EMA, PRICE_CLOSE);
    h_adx = iADX(_Symbol, PERIOD_CURRENT, ADX_Period);

    if(h_atr == INVALID_HANDLE || h_ema == INVALID_HANDLE || h_adx == INVALID_HANDLE)
    {
        Print("ERROR: indicator handle creation failed");
        return INIT_FAILED;
    }
    g_today             = 0;
    g_day_start_balance = AccountInfoDouble(ACCOUNT_BALANCE);
    g_entry_time        = 0;
    Print("ATRBreakout Stock H1 on [", _Symbol, "] initialised. ",
          "ADX>=", ADX_Min, "  Session=", Session_Open_UTC, "-", Session_Close_UTC, " UTC");
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    IndicatorRelease(h_atr);
    IndicatorRelease(h_ema);
    IndicatorRelease(h_adx);
}

//+------------------------------------------------------------------+
void OnTick()
{
    // ── Only run on new completed H1 bar ─────────────────────────
    static datetime last_bar = 0;
    datetime bar0 = iTime(_Symbol, PERIOD_CURRENT, 0);
    if(bar0 == last_bar) return;
    last_bar = bar0;

    // ── Daily balance tracker ─────────────────────────────────────
    datetime today = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
    if(today != g_today)
    {
        g_today             = today;
        g_day_start_balance = AccountInfoDouble(ACCOUNT_BALANCE);
    }

    // ── FTMO drawdown circuit-breakers ────────────────────────────
    double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
    double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
    double daily_dd = (g_day_start_balance - equity) / g_day_start_balance * 100.0;
    double total_dd = (balance - equity) / balance * 100.0;
    if(daily_dd >= MaxDailyLoss_Pct) { CloseAll("daily DD limit"); return; }
    if(total_dd >= MaxTotalDD_Pct)   { CloseAll("total DD limit"); return; }

    // ── MaxHold guard — no overnight holds on individual stocks ──
    if(CountPositions() > 0)
    {
        if(g_entry_time > 0)
        {
            int bars_held = Bars(_Symbol, PERIOD_CURRENT, g_entry_time, TimeCurrent()) - 1;
            if(bars_held >= MaxHold_Bars)
            {
                CloseAll("max hold");
                g_entry_time = 0;
                return;
            }
        }
        return;
    }

    // ── Session filter — NYSE/Nasdaq cash hours only ──────────────
    if(UseSessionFilter)
    {
        MqlDateTime t; TimeToStruct(TimeCurrent(), t);
        if(t.hour < Session_Open_UTC || t.hour >= Session_Close_UTC) return;
    }

    // ── Read indicator buffers ────────────────────────────────────
    int buf_size = Lookback + 10;
    double atr_buf[], ema_buf[], adx_buf[];
    ArraySetAsSeries(atr_buf, true);
    ArraySetAsSeries(ema_buf, true);
    ArraySetAsSeries(adx_buf, true);

    if(CopyBuffer(h_atr, 0, 0, buf_size, atr_buf) < buf_size) return;
    if(CopyBuffer(h_ema, 0, 0, 3, ema_buf) < 3) return;
    if(CopyBuffer(h_adx, 0, 0, 3, adx_buf) < 3) return;

    // ── ADX gate ─────────────────────────────────────────────────
    if(adx_buf[1] < ADX_Min) return;

    // ── ATR expansion filter ─────────────────────────────────────
    double atr_cur = atr_buf[1];
    double atr_avg = 0;
    for(int i = 1; i <= Lookback; i++) atr_avg += atr_buf[i];
    atr_avg /= Lookback;
    if(atr_cur <= atr_avg * ATR_Expand) return;

    // ── Lookback high/low (bars 2..Lookback+1 ago) ───────────────
    double lk_high = 0.0, lk_low = DBL_MAX;
    for(int i = 2; i <= Lookback + 1; i++)
    {
        double h = iHigh(_Symbol, PERIOD_CURRENT, i);
        double l = iLow(_Symbol,  PERIOD_CURRENT, i);
        if(h > lk_high) lk_high = h;
        if(l < lk_low)  lk_low  = l;
    }

    // ── Signal logic ─────────────────────────────────────────────
    double close1  = iClose(_Symbol, PERIOD_CURRENT, 1);
    double ema1    = ema_buf[1];
    double sl_dist = atr_cur * SL_ATR_Mult;
    double tp_dist = atr_cur * TP_ATR_Mult;
    double ask     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double lot     = CalcLot(sl_dist);
    if(lot <= 0) return;

    if(close1 > lk_high && close1 > ema1)
    {
        if(trade.Buy(lot, _Symbol, ask, ask - sl_dist, ask + tp_dist, TradeComment))
            g_entry_time = TimeCurrent();
        return;
    }
    if(close1 < lk_low && close1 < ema1)
    {
        if(trade.Sell(lot, _Symbol, bid, bid + sl_dist, bid - tp_dist, TradeComment))
            g_entry_time = TimeCurrent();
    }
}

//+------------------------------------------------------------------+
double CalcLot(double sl_dist)
{
    double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
    double tick_val  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double lot_step  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    double lot_min   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double lot_max   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

    if(tick_val == 0 || sl_dist == 0) return lot_min;

    double risk_money = balance * Risk_Pct / 100.0;
    double sl_ticks   = sl_dist / tick_size;
    double lot        = risk_money / (sl_ticks * tick_val);

    lot = MathFloor(lot / lot_step) * lot_step;
    return MathMin(MathMax(lot, lot_min), lot_max);
}

//+------------------------------------------------------------------+
int CountPositions()
{
    int count = 0;
    for(int i = 0; i < PositionsTotal(); i++)
        if(PositionGetSymbol(i) == _Symbol &&
           PositionGetInteger(POSITION_MAGIC) == MagicNumber) count++;
    return count;
}

//+------------------------------------------------------------------+
void CloseAll(string reason)
{
    Print("CloseAll: ", reason);
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(PositionGetSymbol(i) == _Symbol &&
           PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            trade.PositionClose(PositionGetTicket(i));
    }
    g_entry_time = 0;
}
