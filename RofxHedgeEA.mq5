//+------------------------------------------------------------------+
//|                                                 RofxHedgeEA.mq5  |
//|  Donchian Channel Breakout — Tail Hedge for RofxRecoveryEA       |
//|                                                                   |
//|  PURPOSE: Anti-correlated companion to RofxRecoveryEA.           |
//|  Earns during sustained trends (exactly when the martingale       |
//|  bleeds). Loses small in ranging markets (when martingale earns). |
//|                                                                   |
//|  PORTFOLIO SPLIT (€100k demo):                                    |
//|    RofxRecoveryEA  →  €70k  (income engine)                      |
//|    RofxHedgeEA     →  €20k  (tail protection)                    |
//|    Cash buffer     →  €10k  (margin safety)                      |
//|                                                                   |
//|  Attach to GBPUSD H4 and EURUSD H4 separately.                   |
//+------------------------------------------------------------------+
#property copyright "WestCode 2026"
#property version   "1.00"
#property description "Donchian breakout hedge — companion to RofxRecoveryEA"

#include <Trade\Trade.mqh>

//──────────────────────────────────────────────────────────────────
//  INPUT PARAMETERS
//──────────────────────────────────────────────────────────────────

input group "=== BREAKOUT CHANNEL ==="
input int    InpChannelPeriod = 20;        // Donchian channel period (H4 bars)
input int    InpConfirmBars   = 1;         // Closed bars above/below channel to confirm

input group "=== TRADE MANAGEMENT ==="
input double InpLot            = 0.02;    // Fixed lot size per trade
input int    InpTrailStartPips = 30;      // Pips in profit before trail activates
input int    InpTrailStepPips  = 20;      // Trail step size in pips
input int    InpHardStopPips   = 80;      // Hard stop loss from entry (pips)
input int    InpMaxHoldBars    = 60;      // Max hold time in H4 bars (= 10 trading days)

input group "=== FILTERS ==="
input bool   InpFilterNews     = true;    // Skip entries on Friday after 20:00
input int    InpMaxOpenTrades  = 1;       // Max simultaneous trades per direction

input group "=== EA IDENTITY ==="
input int    InpMagic  = 202800;          // Magic number base
input string InpComment = "RofxHedge";   // Order comment

//──────────────────────────────────────────────────────────────────
//  GLOBALS
//──────────────────────────────────────────────────────────────────
CTrade   g_trade;
int      g_magic;
double   g_pipSize;
double   g_lotStep;
double   g_minLot;
double   g_maxLot;

int      g_hHigh = INVALID_HANDLE;   // Donchian upper band
int      g_hLow  = INVALID_HANDLE;   // Donchian lower band

datetime g_lastBarTime = 0;

//──────────────────────────────────────────────────────────────────
//  INIT / DEINIT
//──────────────────────────────────────────────────────────────────
int OnInit()
{
    string sym = _Symbol;
    if(sym != "GBPUSD" && sym != "EURUSD" &&
       sym != "GBPUSDm" && sym != "EURUSDm")
    {
        Alert("RofxHedgeEA: attach to GBPUSD or EURUSD only");
        return INIT_FAILED;
    }

    g_pipSize = (_Digits == 5 || _Digits == 3) ? _Point * 10.0 : _Point;
    g_minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    g_maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    g_lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

    g_magic = InpMagic + (StringFind(sym, "GBP") >= 0 ? 1 : 2);
    g_trade.SetExpertMagicNumber(g_magic);
    g_trade.SetDeviationInPoints(30);
    g_trade.SetTypeFilling(ORDER_FILLING_IOC);
    g_trade.LogLevel(LOG_LEVEL_ERRORS);

    // Donchian uses Highest/Lowest over N bars
    g_hHigh = iHighest(_Symbol, PERIOD_H4, MODE_HIGH, InpChannelPeriod, 1);
    g_hLow  = iLowest (_Symbol, PERIOD_H4, MODE_LOW,  InpChannelPeriod, 1);

    if(g_hHigh == INVALID_HANDLE || g_hLow == INVALID_HANDLE)
    {
        Print("RofxHedgeEA: indicator handle error");
        return INIT_FAILED;
    }

    PrintFormat("RofxHedgeEA ready | %s | pip=%.5f | magic=%d | "
                "Channel=%d H4 bars | Lot=%.2f | Trail=%d/%d pips",
                sym, g_pipSize, g_magic,
                InpChannelPeriod, InpLot, InpTrailStartPips, InpTrailStepPips);
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
    if(g_hHigh != INVALID_HANDLE) IndicatorRelease(g_hHigh);
    if(g_hLow  != INVALID_HANDLE) IndicatorRelease(g_hLow);
    PrintFormat("RofxHedgeEA deinit | symbol=%s reason=%d", _Symbol, reason);
}

//──────────────────────────────────────────────────────────────────
//  HELPERS
//──────────────────────────────────────────────────────────────────

// Normalize lot
double NormLot(double lot)
{
    lot = MathFloor(lot / g_lotStep) * g_lotStep;
    return NormalizeDouble(MathMax(g_minLot, MathMin(g_maxLot, lot)), 2);
}

// Count our positions in one direction
int CountPos(ENUM_POSITION_TYPE dir)
{
    int n = 0;
    for(int i = PositionsTotal() - 1; i >= 0; i--)
        if(PositionGetTicket(i) &&
           PositionGetString(POSITION_SYMBOL)  == _Symbol &&
           PositionGetInteger(POSITION_MAGIC)  == g_magic &&
           PositionGetInteger(POSITION_TYPE)   == dir)
            n++;
    return n;
}

// Manage trailing stops on open positions
void ManageTrails()
{
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(!PositionGetTicket(i))                             continue;
        if(PositionGetString(POSITION_SYMBOL) != _Symbol)    continue;
        if(PositionGetInteger(POSITION_MAGIC) != g_magic)    continue;

        ulong  ticket    = PositionGetInteger(POSITION_TICKET);
        double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
        double curSL     = PositionGetDouble(POSITION_SL);
        double curTP     = PositionGetDouble(POSITION_TP);
        ENUM_POSITION_TYPE dir = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

        // ── Max hold time → force close ────────────────────────
        datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
        int barsOpen = (int)((TimeCurrent() - openTime) / (4 * 3600));
        if(barsOpen >= InpMaxHoldBars)
        {
            PrintFormat("MaxHold reached (%d H4 bars) — closing ticket=%I64u", barsOpen, ticket);
            g_trade.PositionClose(ticket, 50);
            continue;
        }

        double trailStart = InpTrailStartPips * g_pipSize;
        double trailStep  = InpTrailStepPips  * g_pipSize;

        if(dir == POSITION_TYPE_BUY)
        {
            double profitPips = (bid - openPrice) / g_pipSize;
            if(profitPips < InpTrailStartPips) continue;

            double newSL = bid - trailStep;
            newSL = NormalizeDouble(newSL, _Digits);
            if(newSL > curSL + g_pipSize)   // only move up
            {
                g_trade.PositionModify(ticket, newSL, curTP);
            }
        }
        else // SELL
        {
            double profitPips = (openPrice - ask) / g_pipSize;
            if(profitPips < InpTrailStartPips) continue;

            double newSL = ask + trailStep;
            newSL = NormalizeDouble(newSL, _Digits);
            if(newSL < curSL - g_pipSize || curSL == 0)   // only move down
            {
                g_trade.PositionModify(ticket, newSL, curTP);
            }
        }
    }
}

// Skip Friday late + weekend gap risk
bool NewsFilter()
{
    if(!InpFilterNews) return true;
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    if(dt.day_of_week == 5 && dt.hour >= 20) return false;
    if(dt.day_of_week == 6 || dt.day_of_week == 0) return false;
    return true;
}

//──────────────────────────────────────────────────────────────────
//  ONTICK
//──────────────────────────────────────────────────────────────────
void OnTick()
{
    // ── Manage trailing stops every tick ──────────────────────────
    ManageTrails();

    // ── Signal check: once per H4 bar close ───────────────────────
    datetime currentBar = iTime(_Symbol, PERIOD_H4, 0);
    if(currentBar == g_lastBarTime) return;

    if(!NewsFilter()) return;

    // ── Read Donchian channel (from closed bars, shift=1) ─────────
    // Upper band: highest HIGH of last N bars (excluding current)
    double channelHigh = EMPTY_VALUE;
    double channelLow  = EMPTY_VALUE;

    double highBuf[], lowBuf[];
    ArraySetAsSeries(highBuf, true);
    ArraySetAsSeries(lowBuf,  true);

    // Copy N+1 bars of High/Low data (shift 1 to skip current bar)
    if(CopyHigh(_Symbol, PERIOD_H4, 1, InpChannelPeriod, highBuf) <= 0) return;
    if(CopyLow (_Symbol, PERIOD_H4, 1, InpChannelPeriod, lowBuf)  <= 0) return;

    channelHigh = highBuf[ArrayMaximum(highBuf)];
    channelLow  = lowBuf [ArrayMinimum(lowBuf)];

    if(channelHigh <= 0 || channelLow <= 0) return;

    // ── Last closed bar close price ────────────────────────────────
    double closedBarClose[];
    ArraySetAsSeries(closedBarClose, true);
    if(CopyClose(_Symbol, PERIOD_H4, 1, InpConfirmBars, closedBarClose) <= 0) return;
    double lastClose = closedBarClose[0];

    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double lot = NormLot(InpLot);

    // ── BUY breakout: close above upper channel ────────────────────
    if(lastClose > channelHigh && CountPos(POSITION_TYPE_BUY) < InpMaxOpenTrades)
    {
        double sl = NormalizeDouble(ask - InpHardStopPips * g_pipSize, _Digits);
        if(g_trade.Buy(lot, _Symbol, 0, sl, 0,
                       InpComment + "_Break_H"))
        {
            g_lastBarTime = currentBar;
            PrintFormat("BREAKOUT BUY | close=%.5f > channel_high=%.5f | lot=%.2f | sl=%.5f",
                        lastClose, channelHigh, lot, sl);
        }
    }
    // ── SELL breakout: close below lower channel ───────────────────
    else if(lastClose < channelLow && CountPos(POSITION_TYPE_SELL) < InpMaxOpenTrades)
    {
        double sl = NormalizeDouble(bid + InpHardStopPips * g_pipSize, _Digits);
        if(g_trade.Sell(lot, _Symbol, 0, sl, 0,
                        InpComment + "_Break_L"))
        {
            g_lastBarTime = currentBar;
            PrintFormat("BREAKOUT SELL | close=%.5f < channel_low=%.5f | lot=%.2f | sl=%.5f",
                        lastClose, channelLow, lot, sl);
        }
    }
}
