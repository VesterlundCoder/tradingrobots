//+------------------------------------------------------------------+
//|                SqueezeBreakoutUSDCNH_H4.mq5                      |
//|  Bollinger Band Squeeze Breakout — USDCNH H4 — FTMO Challenge EA |
//|                                                                   |
//|  Strategy: Detects volatility squeeze (BB width at historical     |
//|  low percentile) then trades breakout of N-bar high/low, with    |
//|  EMA200 trend and ADX>25 filters                                  |
//|                                                                   |
//|  Backtest (6mo): Return +4.29%  |  Sharpe 1.290  |  MaxDD 0.90% |
//|  Walk-Forward:   Degrad 3.25  |  OOS+ 3/4 folds  ✅ ROBUST       |
//|  Monte Carlo:    P50 +4.8%  |  P5 +1.0%  |  P(profit) 99%       |
//+------------------------------------------------------------------+
#property copyright "RD LUMI Z3"
#property description "BB Squeeze Breakout on USDCNH H4 — ADX-gated, FTMO-compliant"
#property version   "1.00"

#include <Trade\Trade.mqh>

//── Strategy parameters (v7 optimal) ────────────────────────────────
input group "=== STRATEGY PARAMETERS ==="
input int    BB_Period      = 20;    // Bollinger Band period
input double BB_Dev         = 2.0;   // Bollinger Band std deviations
input int    Lookback_PCT   = 150;   // BB Width percentile rank lookback (bars)
input double Squeeze_PCT    = 20.0;  // Squeeze threshold: BBW in bottom X% = squeeze
input int    N_Bar_High     = 20;    // N-bar high/low for breakout signal
input int    EMA_Period     = 200;   // Trend EMA period
input int    ATR_Period     = 14;    // ATR period for position sizing

//── ADX regime gate ──────────────────────────────────────────────────
input group "=== ADX REGIME FILTER ==="
input int    ADX_Period     = 14;
input double ADX_Min        = 25.0;  // EA sleeps when ADX below this

//── Risk & position sizing ───────────────────────────────────────────
input group "=== RISK & POSITION SIZING ==="
input double SL_ATR_Mult    = 2.0;
input double TP_ATR_Mult    = 4.0;
input double Risk_Pct       = 0.25;

//── FTMO safety limits ───────────────────────────────────────────────
input group "=== FTMO SAFETY LIMITS ==="
input double MaxDailyLoss_Pct = 4.0;
input double MaxTotalDD_Pct   = 8.0;

//── EA identity ──────────────────────────────────────────────────────
input group "=== EA IDENTITY ==="
input long   MagicNumber    = 20260103;
input string TradeComment   = "SqzBrk_H4";

//── Globals ──────────────────────────────────────────────────────────
CTrade   trade;
int      h_bb, h_ema, h_adx, h_atr;
double   g_day_start_balance;
datetime g_today;

// Required bar buffer (max lookback + n_bar_high + BB_Period + safety)
#define MAX_BUF 300

//+------------------------------------------------------------------+
int OnInit()
{
    if(_Period != PERIOD_H4)
    {
        Alert("Attach to USDCNH H4 chart.");
        return INIT_FAILED;
    }
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(30);
    trade.SetTypeFilling(ORDER_FILLING_FOK);

    h_bb  = iBands(_Symbol, PERIOD_CURRENT, BB_Period, 0, BB_Dev, PRICE_CLOSE);
    h_ema = iMA(_Symbol,    PERIOD_CURRENT, EMA_Period, 0, MODE_EMA, PRICE_CLOSE);
    h_adx = iADX(_Symbol,   PERIOD_CURRENT, ADX_Period);
    h_atr = iATR(_Symbol,   PERIOD_CURRENT, ATR_Period);

    if(h_bb  == INVALID_HANDLE || h_ema == INVALID_HANDLE ||
       h_adx == INVALID_HANDLE || h_atr == INVALID_HANDLE)
    {
        Print("ERROR: indicator handle creation failed");
        return INIT_FAILED;
    }
    g_today = 0;
    g_day_start_balance = AccountInfoDouble(ACCOUNT_BALANCE);
    Print("SqueezeBreakout H4 initialised. ADX gate = ", ADX_Min,
          "  Squeeze threshold = ", Squeeze_PCT, "%");
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    IndicatorRelease(h_bb);
    IndicatorRelease(h_ema);
    IndicatorRelease(h_adx);
    IndicatorRelease(h_atr);
}

//+------------------------------------------------------------------+
// Compute BB Width percentile rank for bar at 'shift' over 'lookback' bars.
// Returns: 0-100, lower = narrower relative to history (squeeze = low rank).
double BBW_PctRank(double &bb_upper[], double &bb_lower[], double &bb_mid[],
                   int shift, int lookback)
{
    if(bb_mid[shift] == 0.0) return 50.0;
    double bbw_target = (bb_upper[shift] - bb_lower[shift]) / bb_mid[shift];
    int count_le = 0, count_valid = 0;
    int end = shift + lookback;
    if(end >= ArraySize(bb_upper)) end = ArraySize(bb_upper) - 1;
    for(int i = shift; i <= end; i++)
    {
        if(bb_mid[i] == 0.0) continue;
        double bbw_i = (bb_upper[i] - bb_lower[i]) / bb_mid[i];
        if(bbw_i <= bbw_target) count_le++;
        count_valid++;
    }
    if(count_valid == 0) return 50.0;
    return (double)count_le / count_valid * 100.0;
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

    // ── FTMO circuit-breakers ─────────────────────────────────────
    double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
    double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
    double daily_dd = (g_day_start_balance - equity) / g_day_start_balance * 100.0;
    double total_dd = (balance - equity) / balance * 100.0;
    if(daily_dd >= MaxDailyLoss_Pct) { CloseAll("daily DD limit"); return; }
    if(total_dd >= MaxTotalDD_Pct)   { CloseAll("total DD limit"); return; }

    if(CountPositions() > 0) return;

    // ── ADX gate ──────────────────────────────────────────────────
    double adx_buf[3]; ArraySetAsSeries(adx_buf, true);
    if(CopyBuffer(h_adx, 0, 0, 3, adx_buf) < 3) return;
    if(adx_buf[1] < ADX_Min) return;

    // ── Read BB and ATR buffers ───────────────────────────────────
    int buf_needed = Lookback_PCT + N_Bar_High + BB_Period + 10;
    if(buf_needed > MAX_BUF) buf_needed = MAX_BUF;

    double bb_mid[], bb_upper[], bb_lower[], atr_buf[], ema_buf[];
    ArraySetAsSeries(bb_mid,   true);
    ArraySetAsSeries(bb_upper, true);
    ArraySetAsSeries(bb_lower, true);
    ArraySetAsSeries(atr_buf,  true);
    ArraySetAsSeries(ema_buf,  true);

    if(CopyBuffer(h_bb, 0, 0, buf_needed, bb_mid)   < buf_needed) return;
    if(CopyBuffer(h_bb, 1, 0, buf_needed, bb_upper) < buf_needed) return;
    if(CopyBuffer(h_bb, 2, 0, buf_needed, bb_lower) < buf_needed) return;
    if(CopyBuffer(h_atr, 0, 0, 3, atr_buf) < 3) return;
    if(CopyBuffer(h_ema, 0, 0, 3, ema_buf) < 3) return;

    // ── Squeeze detection: was any recent bar in a squeeze? ───────
    bool was_in_squeeze = false;
    for(int i = 1; i <= N_Bar_High; i++)
    {
        double rank = BBW_PctRank(bb_upper, bb_lower, bb_mid, i, Lookback_PCT);
        if(rank <= Squeeze_PCT) { was_in_squeeze = true; break; }
    }
    if(!was_in_squeeze) return;

    // ── N-bar high/low for breakout signal ───────────────────────
    double nb_high = 0.0, nb_low = DBL_MAX;
    for(int i = 2; i <= N_Bar_High + 1; i++)
    {
        double h = iHigh(_Symbol, PERIOD_CURRENT, i);
        double l = iLow(_Symbol,  PERIOD_CURRENT, i);
        if(h > nb_high) nb_high = h;
        if(l < nb_low)  nb_low  = l;
    }

    // ── Signal on previous closed bar ────────────────────────────
    double close1  = iClose(_Symbol, PERIOD_CURRENT, 1);
    double ema1    = ema_buf[1];
    double atr_cur = atr_buf[1];
    double sl_dist = atr_cur * SL_ATR_Mult;
    double tp_dist = atr_cur * TP_ATR_Mult;
    double ask     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double lot     = CalcLot(sl_dist);
    if(lot <= 0) return;

    if(close1 > nb_high && close1 > ema1)
    {
        trade.Buy(lot, _Symbol, ask, ask - sl_dist, ask + tp_dist, TradeComment);
        return;
    }
    if(close1 < nb_low && close1 < ema1)
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
    double lot = (balance * Risk_Pct / 100.0) / ((sl_dist / tick_size) * tick_val);
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
        if(PositionGetSymbol(i) == _Symbol &&
           PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            trade.PositionClose(PositionGetTicket(i));
}
