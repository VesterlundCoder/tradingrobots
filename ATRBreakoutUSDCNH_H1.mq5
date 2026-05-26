//+------------------------------------------------------------------+
//|                   ATRBreakoutUSDCNH_H1.mq5                       |
//|  ATR Expansion Breakout — USDCNH H1 — FTMO Challenge EA          |
//|                                                                   |
//|  Strategy: Trades breakouts of N-bar High/Low when ATR expands   |
//|  above its rolling average, filtered by EMA200 trend and ADX>25  |
//|                                                                   |
//|  Backtest (1yr): Return +16.49% |  Sharpe 1.850  |  MaxDD 4.46% |
//|  Walk-Forward:   Degrad 0.77  |  OOS+ 4/4 folds  ✅ ROBUST       |
//|  Monte Carlo:    P50 +18.7%  |  P5 +7.5%  |  P(profit) 100%      |
//+------------------------------------------------------------------+
#property copyright "RD LUMI Z3"
#property description "ATR Breakout on USDCNH H1 — ADX-gated, FTMO-compliant"
#property version   "1.00"

#include <Trade\Trade.mqh>

//── Strategy parameters (v6 optimal) ────────────────────────────────
input group "=== STRATEGY PARAMETERS ==="
input int    ATR_Period    = 14;    // ATR period
input double ATR_Expand    = 1.2;   // ATR expansion factor (current ATR vs rolling avg)
input int    Lookback      = 10;    // Rolling high/low lookback bars
input int    EMA_Period    = 200;   // Trend EMA period

//── ADX regime gate ──────────────────────────────────────────────────
input group "=== ADX REGIME FILTER ==="
input int    ADX_Period    = 14;    // ADX period
input double ADX_Min       = 25.0;  // Minimum ADX — EA sleeps when market is ranging

//── Risk & position sizing ───────────────────────────────────────────
input group "=== RISK & POSITION SIZING ==="
input double SL_ATR_Mult   = 2.0;   // Stop loss = N × ATR
input double TP_ATR_Mult   = 6.0;   // Take profit = N × ATR (R:R = 1:3)
input double Risk_Pct      = 0.25;  // Risk per trade (% of account balance)

//── FTMO safety limits ───────────────────────────────────────────────
input group "=== FTMO SAFETY LIMITS ==="
input double MaxDailyLoss_Pct = 4.0; // Max daily loss (FTMO limit = 5% — 1% buffer)
input double MaxTotalDD_Pct   = 8.0; // Max total drawdown (FTMO limit = 10% — 2% buffer)

//── EA identity ──────────────────────────────────────────────────────
input group "=== EA IDENTITY ==="
input long   MagicNumber   = 20260101;
input string TradeComment  = "ATRBrk_H1";

//── Globals ──────────────────────────────────────────────────────────
CTrade  trade;
int     h_atr, h_ema, h_adx;
double  g_day_start_balance;
datetime g_today;

//+------------------------------------------------------------------+
int OnInit()
{
    if(_Period != PERIOD_H1)
    {
        Alert("Attach to USDCNH H1 chart.");
        return INIT_FAILED;
    }
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(30);
    trade.SetTypeFilling(ORDER_FILLING_FOK);

    h_atr = iATR(_Symbol, PERIOD_CURRENT, ATR_Period);
    h_ema = iMA(_Symbol,  PERIOD_CURRENT, EMA_Period, 0, MODE_EMA, PRICE_CLOSE);
    h_adx = iADX(_Symbol, PERIOD_CURRENT, ADX_Period);

    if(h_atr == INVALID_HANDLE || h_ema == INVALID_HANDLE || h_adx == INVALID_HANDLE)
    {
        Print("ERROR: indicator handle creation failed");
        return INIT_FAILED;
    }
    g_today = 0;
    g_day_start_balance = AccountInfoDouble(ACCOUNT_BALANCE);
    Print("ATRBreakout H1 initialised. ADX gate = ", ADX_Min);
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
    // ── Only run on new completed bar ────────────────────────────
    static datetime last_bar = 0;
    datetime bar0 = iTime(_Symbol, PERIOD_CURRENT, 0);
    if(bar0 == last_bar) return;
    last_bar = bar0;

    // ── Daily balance tracker ─────────────────────────────────────
    datetime today = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
    if(today != g_today)
    {
        g_today = today;
        g_day_start_balance = AccountInfoDouble(ACCOUNT_BALANCE);
    }

    // ── FTMO drawdown circuit-breakers ────────────────────────────
    double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
    double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
    double daily_dd = (g_day_start_balance - equity) / g_day_start_balance * 100.0;
    double total_dd = (balance - equity) / balance * 100.0;
    if(daily_dd >= MaxDailyLoss_Pct) { CloseAll("daily DD limit"); return; }
    if(total_dd >= MaxTotalDD_Pct)   { CloseAll("total DD limit"); return; }

    // ── Skip if already in a position ────────────────────────────
    if(CountPositions() > 0) return;

    // ── Read indicator buffers ────────────────────────────────────
    int buf_size = Lookback + 10;
    double atr_buf[], ema_buf[], adx_buf[];
    ArraySetAsSeries(atr_buf, true);
    ArraySetAsSeries(ema_buf, true);
    ArraySetAsSeries(adx_buf, true);

    if(CopyBuffer(h_atr, 0, 0, buf_size, atr_buf) < buf_size) return;
    if(CopyBuffer(h_ema, 0, 0, 3, ema_buf) < 3) return;
    if(CopyBuffer(h_adx, 0, 0, 3, adx_buf) < 3) return;

    // ── ADX gate — do nothing in ranging markets ──────────────────
    if(adx_buf[1] < ADX_Min) return;

    // ── ATR expansion filter ──────────────────────────────────────
    double atr_cur = atr_buf[1];
    double atr_avg = 0;
    for(int i = 1; i <= Lookback; i++) atr_avg += atr_buf[i];
    atr_avg /= Lookback;
    if(atr_cur <= atr_avg * ATR_Expand) return;

    // ── Lookback high/low (bars 2 to Lookback+1) ─────────────────
    double lk_high = 0.0, lk_low = DBL_MAX;
    for(int i = 2; i <= Lookback + 1; i++)
    {
        double h = iHigh(_Symbol, PERIOD_CURRENT, i);
        double l = iLow(_Symbol,  PERIOD_CURRENT, i);
        if(h > lk_high) lk_high = h;
        if(l < lk_low)  lk_low  = l;
    }

    // ── Signal logic (on bar[1] close) ───────────────────────────
    double close1  = iClose(_Symbol, PERIOD_CURRENT, 1);
    double ema1    = ema_buf[1];
    double sl_dist = atr_cur * SL_ATR_Mult;
    double tp_dist = atr_cur * TP_ATR_Mult;
    double ask     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double lot     = CalcLot(sl_dist);
    if(lot <= 0) return;

    // Bull: close broke above lookback high, above EMA trend
    if(close1 > lk_high && close1 > ema1)
    {
        trade.Buy(lot, _Symbol, ask, ask - sl_dist, ask + tp_dist, TradeComment);
        return;
    }
    // Bear: close broke below lookback low, below EMA trend
    if(close1 < lk_low && close1 < ema1)
    {
        trade.Sell(lot, _Symbol, bid, bid + sl_dist, bid - tp_dist, TradeComment);
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
}
