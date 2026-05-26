//+------------------------------------------------------------------+
//|               GapContinuationSPX500_H1.mq5                      |
//|  Gap Continuation — S&P 500 (US500/SP500) — H1                  |
//|                                                                   |
//|  HFT Lab scan (6m/12m H1 OOS holdout):                           |
//|    Mean OOS Sharpe: +4.04 | Best: +8.1 | 86% param combos pos   |
//|    Best params: gap_pct=0.1-0.2%, ema=50-100, 12m_H1             |
//|                                                                   |
//|  Logic: When H1 bar opens with gap ≥ gap_pct% vs prior close     |
//|  AND in direction of EMA trend → enter in gap direction.         |
//|  NYSE open gaps in trend direction tend to extend in SPX.        |
//|                                                                   |
//|  NOTE: Not for FTMO challenge. Use on funded/prop account.       |
//+------------------------------------------------------------------+
#property copyright "RD LUMI Z3"
#property description "Gap Continuation SPX500 H1 — US500 index, gap+trend filter."
#property version   "1.00"

#include <Trade\Trade.mqh>

input group "=== GAP PARAMETERS ==="
input double Gap_Pct       = 0.10;   // Min gap size as % of prior close (best: 0.1%)
input int    EMA_Period    = 100;    // EMA trend filter

input group "=== TRADE MANAGEMENT ==="
input int    ATR_Period    = 14;
input double SL_ATR_Mult   = 2.0;
input double TP_ATR_Mult   = 6.0;
input int    MaxHold_Bars  = 48;

input group "=== SESSION FILTER (NYSE hours) ==="
input int    Session_Open_UTC  = 13;   // NYSE open 13:30 UTC — use 13 to catch open bar
input int    Session_Close_UTC = 20;   // NYSE close
input bool   UseSessionFilter  = true;

input group "=== RISK + LEVERAGE ==="
input double Risk_Pct      = 0.10;   // Base risk % per trade (leverage amplifies this)
input double Leverage_Mult = 30.0;   // Broker leverage (1.0 = no leverage, 30.0 = 1:30)

input group "=== FTMO SAFETY ==="
input double MaxDailyLoss_Pct = 4.0;
input double MaxTotalDD_Pct   = 8.0;

input group "=== EA IDENTITY ==="
input long   MagicNumber  = 20260402;
input string TradeComment = "GapCont_SPX500_H1";

CTrade   trade;
int      h_ema, h_atr;
double   g_day_start_balance;
datetime g_today, g_entry_time;

int OnInit()
{
    if(_Period != PERIOD_H1) { Alert("Attach to SPX500/US500 H1 chart."); return INIT_FAILED; }
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(500);
    trade.SetTypeFilling(ORDER_FILLING_IOC);
    h_ema = iMA(_Symbol, PERIOD_CURRENT, EMA_Period, 0, MODE_EMA, PRICE_CLOSE);
    h_atr = iATR(_Symbol, PERIOD_CURRENT, ATR_Period);
    if(h_ema == INVALID_HANDLE || h_atr == INVALID_HANDLE) return INIT_FAILED;
    g_today = 0; g_day_start_balance = AccountInfoDouble(ACCOUNT_BALANCE); g_entry_time = 0;
    Print("GapCont SPX500 H1 | gap=",Gap_Pct,"% | EMA(",EMA_Period,")");
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) { IndicatorRelease(h_ema); IndicatorRelease(h_atr); }

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

    double ema_buf[], atr_buf[];
    ArraySetAsSeries(ema_buf, true); ArraySetAsSeries(atr_buf, true);
    if(CopyBuffer(h_ema, 0, 0, 3, ema_buf) < 3) return;
    if(CopyBuffer(h_atr, 0, 0, 3, atr_buf) < 3) return;

    double open_now   = iOpen(_Symbol, PERIOD_CURRENT, 1);
    double close_prev = iClose(_Symbol, PERIOD_CURRENT, 2);
    double ema        = ema_buf[1];
    double atr        = atr_buf[1];

    if(close_prev <= 0) return;
    double gap_pct_actual = (open_now - close_prev) / close_prev * 100.0;

    bool long_signal  = (gap_pct_actual >  Gap_Pct) && (close_prev > ema);
    bool short_signal = (gap_pct_actual < -Gap_Pct) && (close_prev < ema);
    if(!long_signal && !short_signal) return;

    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double lot = CalcLot(atr * SL_ATR_Mult);
    if(lot <= 0) return;

    if(long_signal) {
        if(trade.Buy(lot, _Symbol, ask, ask - atr*SL_ATR_Mult, ask + atr*TP_ATR_Mult, TradeComment))
            { g_entry_time = TimeCurrent(); Print("LONG gap=",DoubleToString(gap_pct_actual,3),"%"); }
    } else {
        if(trade.Sell(lot, _Symbol, bid, bid + atr*SL_ATR_Mult, bid - atr*TP_ATR_Mult, TradeComment))
            { g_entry_time = TimeCurrent(); Print("SHORT gap=",DoubleToString(gap_pct_actual,3),"%"); }
    }
}

double CalcLot(double sl_dist)
{
    double balance=AccountInfoDouble(ACCOUNT_BALANCE), tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE),
           ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE), ls=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP),
           lmin=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN), lmax=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
    if(tv==0||sl_dist==0) return lmin;
    double lot=MathFloor((balance*Risk_Pct*Leverage_Mult/100.0)/(sl_dist/ts*tv)/ls)*ls;
    return MathMin(MathMax(lot,lmin),lmax);
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
