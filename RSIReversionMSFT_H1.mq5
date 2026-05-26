//+------------------------------------------------------------------+
//|                   RSIReversionMSFT_H1.mq5                        |
//|  RSI Mean Reversion — MSFT CFD — H1 — FTMO-compliant EA          |
//|                                                                   |
//|  Strategy: Fade RSI extremes on H1. Enter long when RSI crosses  |
//|  back above oversold. Enter short when RSI crosses back below     |
//|  overbought. SL=2×ATR, TP=6×ATR.                                 |
//|                                                                   |
//|  HFT Lab scan results (180-day H1, OOS holdout 25%):             |
//|    IS  Sharpe: +2.70  |  OOS Sharpe: +16.0  |  degrad: 5.9x     |
//|    OOS return: +15.5% |  Win rate (IS): 48%  |  Max DD: -5.5%    |
//|    Best params: RSI(14), oversold=25, overbought=75               |
//|                                                                   |
//|  NOTE: OOS sample was 8 trades — treat as directional signal,    |
//|  NOT as a production-ready strategy. Monitor first 20 live trades.|
//+------------------------------------------------------------------+
#property copyright "RD LUMI Z3"
#property description "RSI Reversion MSFT H1 — FTMO-compliant. Fade RSI extremes on US stock CFD."
#property version   "1.00"

#include <Trade\Trade.mqh>

//── Strategy parameters ──────────────────────────────────────────────
input group "=== RSI PARAMETERS ==="
input int    RSI_Period    = 14;    // RSI period (best: 14)
input double RSI_Oversold  = 25.0;  // Oversold level — buy on cross back up
input double RSI_Overbought= 75.0;  // Overbought level — sell on cross back down

//── Trade management ─────────────────────────────────────────────────
input group "=== TRADE MANAGEMENT ==="
input int    ATR_Period    = 14;    // ATR period for SL/TP sizing
input double SL_ATR_Mult   = 2.0;   // Stop loss = N × ATR
input double TP_ATR_Mult   = 6.0;   // Take profit = N × ATR (R:R 1:3)
input int    MaxHold_Bars  = 24;    // Force exit after N bars (1 trading day on H1)

//── Session filter — NYSE cash hours ─────────────────────────────────
input group "=== SESSION FILTER (NYSE/Nasdaq) ==="
input int    Session_Open_UTC  = 13;   // Entry allowed from 13:00 UTC
input int    Session_Close_UTC = 19;   // No new entries at/after 19:00 UTC
input bool   UseSessionFilter  = true;

//── Risk ─────────────────────────────────────────────────────────────
input group "=== RISK ==="
input double Risk_Pct = 0.10;     // Base risk % per trade (leverage amplifies this)
input double Leverage_Mult = 30.0; // Broker leverage (1.0 = no leverage, 30.0 = 1:30)

//── FTMO safety limits ────────────────────────────────────────────────
input group "=== FTMO SAFETY LIMITS ==="
input double MaxDailyLoss_Pct = 4.0;
input double MaxTotalDD_Pct   = 8.0;

//── EA identity ───────────────────────────────────────────────────────
input group "=== EA IDENTITY ==="
input long   MagicNumber  = 20260301;
input string TradeComment = "RSIRev_MSFT_H1";

//── Globals ───────────────────────────────────────────────────────────
CTrade   trade;
int      h_rsi, h_atr;
double   g_day_start_balance;
datetime g_today;
datetime g_entry_time;

//+------------------------------------------------------------------+
int OnInit()
{
    if(_Period != PERIOD_H1)
    {
        Alert("Attach to MSFT H1 chart.");
        return INIT_FAILED;
    }
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(100);
    trade.SetTypeFilling(ORDER_FILLING_IOC);

    h_rsi = iRSI(_Symbol, PERIOD_CURRENT, RSI_Period, PRICE_CLOSE);
    h_atr = iATR(_Symbol, PERIOD_CURRENT, ATR_Period);

    if(h_rsi == INVALID_HANDLE || h_atr == INVALID_HANDLE)
    {
        Print("ERROR: indicator handle creation failed.");
        return INIT_FAILED;
    }
    g_today             = 0;
    g_day_start_balance = AccountInfoDouble(ACCOUNT_BALANCE);
    g_entry_time        = 0;
    Print("RSIReversion MSFT H1 initialised. RSI(",RSI_Period,") ",
          RSI_Oversold,"/",RSI_Overbought,
          "  Session=",Session_Open_UTC,"-",Session_Close_UTC," UTC");
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    IndicatorRelease(h_rsi);
    IndicatorRelease(h_atr);
}

//+------------------------------------------------------------------+
void OnTick()
{
    // ── New H1 bar only ──────────────────────────────────────────
    static datetime last_bar = 0;
    datetime bar0 = iTime(_Symbol, PERIOD_CURRENT, 0);
    if(bar0 == last_bar) return;
    last_bar = bar0;

    // ── Daily balance reset ──────────────────────────────────────
    datetime today = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
    if(today != g_today)
    {
        g_today             = today;
        g_day_start_balance = AccountInfoDouble(ACCOUNT_BALANCE);
    }

    // ── FTMO circuit-breakers ────────────────────────────────────
    double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
    double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
    double daily_dd = (g_day_start_balance - equity) / g_day_start_balance * 100.0;
    double total_dd = (balance - equity) / balance * 100.0;
    if(daily_dd >= MaxDailyLoss_Pct) { CloseAll("daily DD"); return; }
    if(total_dd >= MaxTotalDD_Pct)   { CloseAll("total DD"); return; }

    // ── Max hold guard ───────────────────────────────────────────
    if(CountPositions() > 0)
    {
        if(g_entry_time > 0)
        {
            int bars_held = Bars(_Symbol, PERIOD_CURRENT, g_entry_time, TimeCurrent()) - 1;
            if(bars_held >= MaxHold_Bars) { CloseAll("max hold"); g_entry_time = 0; }
        }
        return;
    }

    // ── Session filter ───────────────────────────────────────────
    if(UseSessionFilter)
    {
        MqlDateTime t; TimeToStruct(TimeCurrent(), t);
        if(t.hour < Session_Open_UTC || t.hour >= Session_Close_UTC) return;
    }

    // ── Read indicators ──────────────────────────────────────────
    double rsi_buf[], atr_buf[];
    ArraySetAsSeries(rsi_buf, true);
    ArraySetAsSeries(atr_buf, true);
    if(CopyBuffer(h_rsi, 0, 0, 3, rsi_buf) < 3) return;
    if(CopyBuffer(h_atr, 0, 0, 3, atr_buf) < 3) return;

    double rsi_now  = rsi_buf[1];   // Last closed bar
    double rsi_prev = rsi_buf[2];   // Bar before that
    double atr      = atr_buf[1];

    // ── RSI cross-back signals ───────────────────────────────────
    // Long: RSI was below oversold → now crossed back above
    bool long_signal  = (rsi_prev < RSI_Oversold)  && (rsi_now >= RSI_Oversold);
    // Short: RSI was above overbought → now crossed back below
    bool short_signal = (rsi_prev > RSI_Overbought) && (rsi_now <= RSI_Overbought);

    if(!long_signal && !short_signal) return;

    double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double lot    = CalcLot(atr * SL_ATR_Mult);
    if(lot <= 0) return;

    if(long_signal)
    {
        double sl = ask - atr * SL_ATR_Mult;
        double tp = ask + atr * TP_ATR_Mult;
        if(trade.Buy(lot, _Symbol, ask, sl, tp, TradeComment))
        {
            g_entry_time = TimeCurrent();
            Print("LONG | RSI crossed back above ",RSI_Oversold," | RSI=",DoubleToString(rsi_now,1));
        }
    }
    else if(short_signal)
    {
        double sl = bid + atr * SL_ATR_Mult;
        double tp = bid - atr * TP_ATR_Mult;
        if(trade.Sell(lot, _Symbol, bid, sl, tp, TradeComment))
        {
            g_entry_time = TimeCurrent();
            Print("SHORT | RSI crossed back below ",RSI_Overbought," | RSI=",DoubleToString(rsi_now,1));
        }
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
    double risk_money = balance * Risk_Pct * Leverage_Mult / 100.0;
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
    Print("CloseAll [",reason,"]");
    for(int i = PositionsTotal() - 1; i >= 0; i--)
        if(PositionGetSymbol(i) == _Symbol &&
           PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            trade.PositionClose(PositionGetTicket(i));
    g_entry_time = 0;
}
