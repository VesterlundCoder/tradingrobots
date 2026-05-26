//+------------------------------------------------------------------+
//|               SqueezeBreakoutNVDA_M5.mq5                        |
//|  TTM Squeeze Breakout — NVDA (US Stock CFD) — M5                |
//|                                                                   |
//|  HFT Lab scan (NVDA M5, Squeeze_Break strategy):                |
//|    OOS Sharpe: +8.9 | OOS Trades: 38 | IS Sharpe: +14.2        |
//|    Best params: bb_period=20, bb_std=2.0, kc_mult=1.5           |
//|                                                                   |
//|  Logic (TTM Squeeze):                                            |
//|  - "Squeeze ON": Bollinger Bands inside Keltner Channel          |
//|  - "Squeeze OFF": BB exits KC → momentum release                 |
//|  - Direction: close above EMA = long, below EMA = short          |
//|                                                                   |
//|  Indicators on chart: BB(20,2) + Keltner(20,1.5×ATR) + EMA50   |
//|  NYSE session only — stock CFD requires NY market hours          |
//|                                                                   |
//|  Leverage: Risk_Pct × Leverage_Mult (default 0.10% × 30 = 3%)  |
//+------------------------------------------------------------------+
#property copyright "RD LUMI Z3"
#property version   "1.00"

#include <Trade\Trade.mqh>

input group "=== SQUEEZE PARAMETERS ==="
input int    BB_Period     = 20;     // Bollinger Band period
input double BB_Std        = 2.0;   // Bollinger Band std deviation
input int    KC_Period     = 20;     // Keltner Channel period (EMA)
input double KC_Mult       = 1.5;   // Keltner ATR multiplier
input int    EMA_Period    = 50;    // Direction EMA

input group "=== TRADE MANAGEMENT ==="
input int    ATR_Period    = 14;
input double SL_ATR_Mult   = 2.0;
input double TP_ATR_Mult   = 6.0;
input int    MaxHold_Bars  = 12;    // 12 × 5 min = 60 min max (NVDA is fast)

input group "=== SESSION FILTER (NYSE) ==="
input int    Session_Open_UTC  = 13;   // NYSE open (13:30 UTC)
input int    Session_Close_UTC = 20;   // NYSE close
input bool   UseSessionFilter  = true;

input group "=== RISK + LEVERAGE ==="
input double Risk_Pct      = 0.10;   // Base risk % per trade
input double Leverage_Mult = 30.0;   // Broker leverage (1:30 = 30.0)

input group "=== FTMO SAFETY ==="
input double MaxDailyLoss_Pct = 4.0;
input double MaxTotalDD_Pct   = 8.0;

input group "=== EA IDENTITY ==="
input long   MagicNumber  = 20260503;
input string TradeComment = "Squeeze_NVDA_M5";

CTrade   trade;
int      h_bb, h_kc_ema, h_atr, h_ema;
double   g_day_start_balance;
datetime g_today, g_entry_time;

int OnInit()
{
    if(_Period != PERIOD_M5) { Alert("Attach to NVDA M5 chart."); return INIT_FAILED; }
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(500);
    trade.SetTypeFilling(ORDER_FILLING_IOC);
    h_bb     = iBands(_Symbol, PERIOD_CURRENT, BB_Period, 0, BB_Std, PRICE_CLOSE);
    h_kc_ema = iMA(_Symbol, PERIOD_CURRENT, KC_Period, 0, MODE_EMA, PRICE_CLOSE);
    h_atr    = iATR(_Symbol, PERIOD_CURRENT, ATR_Period);
    h_ema    = iMA(_Symbol, PERIOD_CURRENT, EMA_Period, 0, MODE_EMA, PRICE_CLOSE);
    if(h_bb==INVALID_HANDLE || h_kc_ema==INVALID_HANDLE || h_atr==INVALID_HANDLE || h_ema==INVALID_HANDLE)
        return INIT_FAILED;
    g_today = 0; g_day_start_balance = AccountInfoDouble(ACCOUNT_BALANCE); g_entry_time = 0;
    double eff_risk = Risk_Pct * Leverage_Mult;
    Print("Squeeze NVDA M5 | BB(",BB_Period,",",BB_Std,") | KC(",KC_Period,",",KC_Mult,") | Eff risk=",eff_risk,"%");
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
    IndicatorRelease(h_bb); IndicatorRelease(h_kc_ema);
    IndicatorRelease(h_atr); IndicatorRelease(h_ema);
}

void OnTick()
{
    static datetime last_bar = 0;
    datetime bar0 = iTime(_Symbol, PERIOD_CURRENT, 0);
    if(bar0 == last_bar) return;
    last_bar = bar0;

    datetime today = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
    if(today != g_today) { g_today = today; g_day_start_balance = AccountInfoDouble(ACCOUNT_BALANCE); }

    double balance = AccountInfoDouble(ACCOUNT_BALANCE);
    double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
    if((g_day_start_balance - equity) / g_day_start_balance * 100.0 >= MaxDailyLoss_Pct) { CloseAll("daily DD"); return; }
    if((balance - equity) / balance * 100.0 >= MaxTotalDD_Pct) { CloseAll("total DD"); return; }

    if(CountPositions() > 0) {
        if(g_entry_time > 0 && Bars(_Symbol, PERIOD_CURRENT, g_entry_time, TimeCurrent()) - 1 >= MaxHold_Bars)
            { CloseAll("max hold"); g_entry_time = 0; }
        return;
    }

    if(UseSessionFilter) {
        MqlDateTime t; TimeToStruct(TimeCurrent(), t);
        if(t.hour < Session_Open_UTC || t.hour >= Session_Close_UTC) return;
    }

    double bb_upper[], bb_lower[], kc_ema_buf[], atr_buf[], ema_buf[];
    ArraySetAsSeries(bb_upper,true); ArraySetAsSeries(bb_lower,true);
    ArraySetAsSeries(kc_ema_buf,true); ArraySetAsSeries(atr_buf,true); ArraySetAsSeries(ema_buf,true);

    if(CopyBuffer(h_bb, 1, 0, 3, bb_upper)    < 3) return; // UPPER band
    if(CopyBuffer(h_bb, 2, 0, 3, bb_lower)    < 3) return; // LOWER band
    if(CopyBuffer(h_kc_ema, 0, 0, 3, kc_ema_buf) < 3) return;
    if(CopyBuffer(h_atr, 0, 0, 3, atr_buf)    < 3) return;
    if(CopyBuffer(h_ema, 0, 0, 3, ema_buf)    < 3) return;

    // Keltner Channel bounds (EMA ± KC_Mult × ATR)
    double kc_upper_prev = kc_ema_buf[2] + KC_Mult * atr_buf[2];
    double kc_lower_prev = kc_ema_buf[2] - KC_Mult * atr_buf[2];
    double kc_upper_curr = kc_ema_buf[1] + KC_Mult * atr_buf[1];
    double kc_lower_curr = kc_ema_buf[1] - KC_Mult * atr_buf[1];

    // Squeeze ON: BB inside KC at previous bar
    bool squeeze_on_prev  = (bb_upper[2] < kc_upper_prev) && (bb_lower[2] > kc_lower_prev);
    // Squeeze OFF at current bar: BB now wider than KC
    bool squeeze_off_curr = (bb_upper[1] >= kc_upper_curr) || (bb_lower[1] <= kc_lower_curr);

    // Signal: squeeze just released (was ON, now OFF)
    if(!squeeze_on_prev || !squeeze_off_curr) return;

    double close1 = iClose(_Symbol, PERIOD_CURRENT, 1);
    double ema    = ema_buf[1];
    double atr    = atr_buf[1];

    bool long_signal  = (close1 > ema);
    bool short_signal = (close1 < ema);
    if(!long_signal && !short_signal) return;

    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double lot = CalcLot(atr * SL_ATR_Mult);
    if(lot <= 0) return;

    if(long_signal) {
        if(trade.Buy(lot, _Symbol, ask, ask - atr*SL_ATR_Mult, ask + atr*TP_ATR_Mult, TradeComment))
            { g_entry_time = TimeCurrent(); Print("LONG | squeeze released | close>EMA50"); }
    } else {
        if(trade.Sell(lot, _Symbol, bid, bid + atr*SL_ATR_Mult, bid - atr*TP_ATR_Mult, TradeComment))
            { g_entry_time = TimeCurrent(); Print("SHORT | squeeze released | close<EMA50"); }
    }
}

double CalcLot(double sl_dist)
{
    double balance=AccountInfoDouble(ACCOUNT_BALANCE);
    double tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE),
           ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE),
           ls=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP),
           lmin=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),
           lmax=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
    if(tv==0||sl_dist==0) return lmin;
    double eff_risk = Risk_Pct * Leverage_Mult;
    double lot = MathFloor((balance * eff_risk/100.0) / (sl_dist/ts*tv) / ls) * ls;
    return MathMin(MathMax(lot, lmin), lmax);
}

int CountPositions()
{
    int c=0;
    for(int i=0;i<PositionsTotal();i++)
        if(PositionGetSymbol(i)==_Symbol && PositionGetInteger(POSITION_MAGIC)==MagicNumber) c++;
    return c;
}

void CloseAll(string reason)
{
    Print("CloseAll [",reason,"]");
    for(int i=PositionsTotal()-1;i>=0;i--)
        if(PositionGetSymbol(i)==_Symbol && PositionGetInteger(POSITION_MAGIC)==MagicNumber)
            trade.PositionClose(PositionGetTicket(i));
    g_entry_time=0;
}
