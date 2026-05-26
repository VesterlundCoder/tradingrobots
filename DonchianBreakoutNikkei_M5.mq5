//+------------------------------------------------------------------+
//|               DonchianBreakoutNikkei_M5.mq5                     |
//|  Donchian Channel Breakout — Nikkei 225 (JP225/NI225) — M5      |
//|                                                                   |
//|  HFT Lab scan (Nikkei M5, Donchian_Break strategy):             |
//|    OOS Sharpe: +4.5 | OOS Trades: 41 (statistically credible)   |
//|    Best params: n=20, adx_min=20                                 |
//|                                                                   |
//|  Logic: Enter long when price breaks above N-bar highest high    |
//|  Enter short when price breaks below N-bar lowest low            |
//|  ADX filter ensures we only trade in trending conditions         |
//|                                                                   |
//|  Leverage: Risk_Pct × Leverage_Mult (default 0.10% × 30 = 3%)  |
//+------------------------------------------------------------------+
#property copyright "RD LUMI Z3"
#property version   "1.00"

#include <Trade\Trade.mqh>

input group "=== DONCHIAN PARAMETERS ==="
input int    Channel_Period = 20;    // N-bar lookback for channel high/low (best: 20)
input int    ADX_Period     = 14;    // ADX period for trend strength filter
input double ADX_Min        = 20.0;  // Minimum ADX to enter (best: 20)

input group "=== TRADE MANAGEMENT ==="
input int    ATR_Period     = 14;
input double SL_ATR_Mult    = 2.0;
input double TP_ATR_Mult    = 6.0;
input int    MaxHold_Bars   = 24;    // 24 × 5 min = 2h max hold

input group "=== SESSION FILTER ==="
input int    Session_Open_UTC  = 0;    // Tokyo open
input int    Session_Close_UTC = 20;   // NY close
input bool   UseSessionFilter  = true;

input group "=== RISK + LEVERAGE ==="
input double Risk_Pct      = 0.10;   // Base risk % per trade
input double Leverage_Mult = 30.0;   // Broker leverage (1:30 = 30.0)

input group "=== FTMO SAFETY ==="
input double MaxDailyLoss_Pct = 4.0;
input double MaxTotalDD_Pct   = 8.0;

input group "=== EA IDENTITY ==="
input long   MagicNumber  = 20260502;
input string TradeComment = "Donchian_Nikkei_M5";

CTrade   trade;
int      h_adx, h_atr;
double   g_day_start_balance;
datetime g_today, g_entry_time;

int OnInit()
{
    if(_Period != PERIOD_M5) { Alert("Attach to Nikkei M5 chart."); return INIT_FAILED; }
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(200);
    trade.SetTypeFilling(ORDER_FILLING_IOC);
    h_adx = iADX(_Symbol, PERIOD_CURRENT, ADX_Period);
    h_atr = iATR(_Symbol, PERIOD_CURRENT, ATR_Period);
    if(h_adx == INVALID_HANDLE || h_atr == INVALID_HANDLE) return INIT_FAILED;
    g_today = 0; g_day_start_balance = AccountInfoDouble(ACCOUNT_BALANCE); g_entry_time = 0;
    double eff_risk = Risk_Pct * Leverage_Mult;
    Print("Donchian Nikkei M5 | n=",Channel_Period," | ADX>",ADX_Min," | Effective risk/trade=",eff_risk,"%");
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) { IndicatorRelease(h_adx); IndicatorRelease(h_atr); }

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

    // ADX filter
    double adx_buf[];
    ArraySetAsSeries(adx_buf, true);
    if(CopyBuffer(h_adx, 0, 0, 3, adx_buf) < 3) return;
    if(adx_buf[1] < ADX_Min) return;

    // ATR for sizing
    double atr_buf[];
    ArraySetAsSeries(atr_buf, true);
    if(CopyBuffer(h_atr, 0, 0, 3, atr_buf) < 3) return;
    double atr = atr_buf[1];

    // Donchian channel: highest high and lowest low over last N+1 closed bars (bars 1..N+1)
    // Use bars 2 through Channel_Period+1 (exclude current forming bar and the just-closed bar[1])
    int lookback = Channel_Period + 2;
    double roll_high = iHigh(_Symbol, PERIOD_CURRENT, iHighest(_Symbol, PERIOD_CURRENT, MODE_HIGH, Channel_Period, 2));
    double roll_low  = iLow(_Symbol,  PERIOD_CURRENT, iLowest(_Symbol,  PERIOD_CURRENT, MODE_LOW,  Channel_Period, 2));

    double close1 = iClose(_Symbol, PERIOD_CURRENT, 1);  // just-closed bar

    bool long_signal  = (close1 > roll_high);
    bool short_signal = (close1 < roll_low);
    if(!long_signal && !short_signal) return;

    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double lot = CalcLot(atr * SL_ATR_Mult);
    if(lot <= 0) return;

    if(long_signal) {
        if(trade.Buy(lot, _Symbol, ask, ask - atr*SL_ATR_Mult, ask + atr*TP_ATR_Mult, TradeComment))
            { g_entry_time = TimeCurrent(); Print("LONG | close>roll_high | ADX=",DoubleToString(adx_buf[1],1)); }
    } else {
        if(trade.Sell(lot, _Symbol, bid, bid + atr*SL_ATR_Mult, bid - atr*TP_ATR_Mult, TradeComment))
            { g_entry_time = TimeCurrent(); Print("SHORT | close<roll_low | ADX=",DoubleToString(adx_buf[1],1)); }
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
