//+------------------------------------------------------------------+
//|                                              RofxRecoveryEA.mq5  |
//|  Reverse-engineered rofx strategy                                |
//|  London session martingale recovery on GBPUSD / EURUSD           |
//|                                                                   |
//|  ACCOUNT SCALING: €50,000 demo, max 10% at risk = €5,000         |
//|  Attach this EA separately to GBPUSD H1 and EURUSD H1 charts.    |
//|                                                                   |
//|  Strategy fingerprint (rofx, 20,900 trade sample):               |
//|    Win rate:       78.3%   |  Profit factor: 4.5                  |
//|    Martingale:     1.62x   |  Avg basket:    5 levels             |
//|    Symbols:        GBPUSD (58%) / EURUSD (42%)                    |
//|    Session:        London-dominant (63%)                          |
//+------------------------------------------------------------------+
#property copyright "WestCode 2026"
#property version   "1.00"
#property description "Rofx-style London martingale recovery — scaled for €50k demo"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//──────────────────────────────────────────────────────────────────
//  INPUT PARAMETERS
//──────────────────────────────────────────────────────────────────

input group "=== SIGNAL ==="
input int    InpFastEMA    = 21;          // Fast EMA period (H1)
input int    InpSlowEMA    = 50;          // Slow EMA period (H1)
input int    InpRSIPeriod  = 14;          // RSI period (H1) — confirm trend
input double InpRSIBuyMin  = 52.0;        // RSI min for BUY entry
input double InpRSISellMax = 48.0;        // RSI max for SELL entry

input group "=== MARTINGALE GRID ==="
input double InpBaseLot      = 0.01;     // Base lot (Level 1)
input double InpMultiplier   = 1.60;     // Lot multiplier per level
input int    InpMaxLevels    = 6;        // Max martingale levels (safe cap)
input int    InpGridStepPips = 25;       // Pips adverse from avg price → add level
input int    InpBasketTPPips = 18;       // Pips above avg entry to close basket

input group "=== RISK MANAGEMENT ==="
input double InpMaxBasketRiskPct = 3.0;  // Hard stop: max basket loss % of balance
input double InpMaxTotalRiskPct  = 9.5;  // Global ceiling: total open loss % of balance
input bool   InpCloseOnSessionEnd = true;// Close open baskets at session end

input group "=== SESSION FILTER (server time) ==="
input int    InpSessionStart = 9;        // Session open hour (09:00)
input int    InpSessionEnd   = 18;       // Session close hour (18:00)
input bool   InpMonday       = true;
input bool   InpTuesday      = true;
input bool   InpWednesday    = true;
input bool   InpThursday     = true;
input bool   InpFriday       = true;

input group "=== EA IDENTITY ==="
input int    InpMagic  = 202700;         // Magic number base (symbol offset added)
input string InpComment = "RofxRec";    // Order comment prefix

//──────────────────────────────────────────────────────────────────
//  GLOBALS
//──────────────────────────────────────────────────────────────────
CTrade   g_trade;
int      g_magic;
double   g_pipSize;      // 1 pip in price units
double   g_lotStep;
double   g_minLot;
double   g_maxLot;

int      g_hFastEMA    = INVALID_HANDLE;
int      g_hSlowEMA    = INVALID_HANDLE;
int      g_hRSI        = INVALID_HANDLE;

datetime g_lastBarTime = 0;   // last H1 bar we signalled on

//──────────────────────────────────────────────────────────────────
//  INIT / DEINIT
//──────────────────────────────────────────────────────────────────
int OnInit()
{
    string sym = _Symbol;
    if(sym != "GBPUSD" && sym != "EURUSD" &&
       sym != "GBPUSDm" && sym != "EURUSDm")
    {
        Alert("RofxRecoveryEA: attach to GBPUSD or EURUSD only — got ", sym);
        return INIT_FAILED;
    }

    // Pip size: 5-digit pairs → 10 points = 1 pip
    g_pipSize = (_Digits == 5 || _Digits == 3) ? _Point * 10.0 : _Point;

    g_minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    g_maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    g_lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

    g_magic = InpMagic + (StringFind(sym, "GBP") >= 0 ? 1 : 2);
    g_trade.SetExpertMagicNumber(g_magic);
    g_trade.SetDeviationInPoints(30);
    g_trade.SetTypeFilling(ORDER_FILLING_IOC);
    g_trade.LogLevel(LOG_LEVEL_ERRORS);

    g_hFastEMA = iMA(_Symbol, PERIOD_H1, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
    g_hSlowEMA = iMA(_Symbol, PERIOD_H1, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
    g_hRSI     = iRSI(_Symbol, PERIOD_H1, InpRSIPeriod, PRICE_CLOSE);

    if(g_hFastEMA == INVALID_HANDLE ||
       g_hSlowEMA == INVALID_HANDLE ||
       g_hRSI     == INVALID_HANDLE)
    {
        Print("RofxRecoveryEA: indicator handle error");
        return INIT_FAILED;
    }

    PrintFormat("RofxRecoveryEA ready | %s | pip=%.5f | magic=%d | "
                "BaseLot=%.2f | Grid=%d pips | TP=%d pips | MaxLevels=%d",
                sym, g_pipSize, g_magic,
                InpBaseLot, InpGridStepPips, InpBasketTPPips, InpMaxLevels);
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
    if(g_hFastEMA != INVALID_HANDLE) IndicatorRelease(g_hFastEMA);
    if(g_hSlowEMA != INVALID_HANDLE) IndicatorRelease(g_hSlowEMA);
    if(g_hRSI     != INVALID_HANDLE) IndicatorRelease(g_hRSI);
}

//──────────────────────────────────────────────────────────────────
//  HELPERS
//──────────────────────────────────────────────────────────────────

bool InSession()
{
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    if(dt.day_of_week == 0 || dt.day_of_week == 6) return false;
    bool dayOK = (dt.day_of_week == 1 && InpMonday)   ||
                 (dt.day_of_week == 2 && InpTuesday)  ||
                 (dt.day_of_week == 3 && InpWednesday)||
                 (dt.day_of_week == 4 && InpThursday) ||
                 (dt.day_of_week == 5 && InpFriday);
    return dayOK && (dt.hour >= InpSessionStart && dt.hour < InpSessionEnd);
}

// Lot for a given level index (0-based)
double LevelLot(int level)
{
    double lot = InpBaseLot;
    for(int i = 0; i < level; i++)
        lot *= InpMultiplier;
    lot = MathFloor(lot / g_lotStep) * g_lotStep;
    lot = MathMax(g_minLot, MathMin(g_maxLot, lot));
    return NormalizeDouble(lot, 2);
}

double GetIndicator(int handle, int shift = 1)
{
    double buf[];
    ArraySetAsSeries(buf, true);
    if(CopyBuffer(handle, 0, shift, 1, buf) <= 0) return EMPTY_VALUE;
    return buf[0];
}

// Count open positions for this EA + direction
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

// Weighted average entry price for direction
double AvgEntryPrice(ENUM_POSITION_TYPE dir)
{
    double cost = 0, lots = 0;
    for(int i = PositionsTotal() - 1; i >= 0; i--)
        if(PositionGetTicket(i) &&
           PositionGetString(POSITION_SYMBOL)  == _Symbol &&
           PositionGetInteger(POSITION_MAGIC)  == g_magic &&
           PositionGetInteger(POSITION_TYPE)   == dir)
        {
            double vol = PositionGetDouble(POSITION_VOLUME);
            cost += PositionGetDouble(POSITION_PRICE_OPEN) * vol;
            lots += vol;
        }
    return (lots > 0) ? cost / lots : 0.0;
}

// Total floating profit (USD/EUR) for direction
double BasketProfit(ENUM_POSITION_TYPE dir)
{
    double profit = 0;
    for(int i = PositionsTotal() - 1; i >= 0; i--)
        if(PositionGetTicket(i) &&
           PositionGetString(POSITION_SYMBOL)  == _Symbol &&
           PositionGetInteger(POSITION_MAGIC)  == g_magic &&
           PositionGetInteger(POSITION_TYPE)   == dir)
            profit += PositionGetDouble(POSITION_PROFIT)
                    + PositionGetDouble(POSITION_SWAP);
    return profit;
}

// Close all positions for direction
void CloseBasket(ENUM_POSITION_TYPE dir, string reason)
{
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(ticket == 0) continue;
        if(PositionGetString(POSITION_SYMBOL)  != _Symbol)  continue;
        if(PositionGetInteger(POSITION_MAGIC)  != g_magic)  continue;
        if(PositionGetInteger(POSITION_TYPE)   != dir)      continue;
        if(!g_trade.PositionClose(ticket, 50))
            PrintFormat("Close failed ticket=%I64u err=%d reason=%s",
                        ticket, GetLastError(), reason);
    }
}

// Global risk check (both symbols combined)
bool GlobalRiskOK()
{
    double balance = AccountInfoDouble(ACCOUNT_BALANCE);
    if(balance <= 0) return false;
    double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
    double loss    = MathMax(0.0, balance - equity);
    return (loss / balance * 100.0) < InpMaxTotalRiskPct;
}

//──────────────────────────────────────────────────────────────────
//  ONTICK
//──────────────────────────────────────────────────────────────────
void OnTick()
{
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double balance = AccountInfoDouble(ACCOUNT_BALANCE);

    //──────────────────────────────────────────────────────────────
    // PHASE 1: Manage existing baskets
    //──────────────────────────────────────────────────────────────
    for(int d = 0; d <= 1; d++)
    {
        ENUM_POSITION_TYPE dir = (ENUM_POSITION_TYPE)d;
        int levels = CountPos(dir);
        if(levels == 0) continue;

        double avgPrice = AvgEntryPrice(dir);
        double profit   = BasketProfit(dir);

        // ── Session end → close basket ─────────────────────────
        if(InpCloseOnSessionEnd && !InSession())
        {
            CloseBasket(dir, "session_end");
            continue;
        }

        // ── Hard basket stop (% of balance) ───────────────────
        double loss = -profit;
        if(loss > 0 && (loss / balance * 100.0) >= InpMaxBasketRiskPct)
        {
            PrintFormat("HardStop %s basket | loss=%.2f (%.1f%%)",
                        dir == POSITION_TYPE_BUY ? "BUY" : "SELL",
                        loss, loss / balance * 100.0);
            CloseBasket(dir, "hard_stop");
            continue;
        }

        // ── Take-profit: price reached TP level above avg entry ─
        double tpPrice;
        double currentPrice;
        if(dir == POSITION_TYPE_BUY)
        {
            tpPrice      = avgPrice + InpBasketTPPips * g_pipSize;
            currentPrice = bid;
            if(currentPrice >= tpPrice)
            {
                PrintFormat("TP hit BUY basket | avg=%.5f tp=%.5f bid=%.5f",
                            avgPrice, tpPrice, bid);
                CloseBasket(dir, "tp");
                continue;
            }
        }
        else
        {
            tpPrice      = avgPrice - InpBasketTPPips * g_pipSize;
            currentPrice = ask;
            if(currentPrice <= tpPrice)
            {
                PrintFormat("TP hit SELL basket | avg=%.5f tp=%.5f ask=%.5f",
                            avgPrice, tpPrice, ask);
                CloseBasket(dir, "tp");
                continue;
            }
        }

        // ── Martingale: add next level if price adverse by GridStep pips ─
        if(levels < InpMaxLevels && GlobalRiskOK())
        {
            double distPips;
            if(dir == POSITION_TYPE_BUY)
                distPips = (avgPrice - bid) / g_pipSize;   // adverse = price dropped
            else
                distPips = (ask - avgPrice) / g_pipSize;   // adverse = price rose

            if(distPips >= InpGridStepPips)
            {
                double nextLot = LevelLot(levels);
                bool   ok;
                if(dir == POSITION_TYPE_BUY)
                    ok = g_trade.Buy(nextLot, _Symbol, 0, 0, 0,
                                     InpComment + "_L" + IntegerToString(levels + 1));
                else
                    ok = g_trade.Sell(nextLot, _Symbol, 0, 0, 0,
                                      InpComment + "_L" + IntegerToString(levels + 1));

                if(ok)
                    PrintFormat("Level %d added | dir=%s lot=%.2f dist=%.1f pips",
                                levels + 1,
                                dir == POSITION_TYPE_BUY ? "BUY" : "SELL",
                                nextLot, distPips);
                else
                    PrintFormat("Level %d FAILED | err=%d", levels + 1, GetLastError());
            }
        }
    }

    //──────────────────────────────────────────────────────────────
    // PHASE 2: New entry signal
    //──────────────────────────────────────────────────────────────

    // Gate: session + global risk
    if(!InSession())    return;
    if(!GlobalRiskOK()) return;

    // One basket max per symbol (wait for previous to close)
    if(CountPos(POSITION_TYPE_BUY) > 0 || CountPos(POSITION_TYPE_SELL) > 0) return;

    // One signal per closed H1 bar (use bar[1] indicators to avoid repainting)
    datetime currentBar = iTime(_Symbol, PERIOD_H1, 0);
    if(currentBar == g_lastBarTime) return;

    // Read indicators from last closed bar (shift=1)
    double emaFast = GetIndicator(g_hFastEMA, 1);
    double emaSlow = GetIndicator(g_hSlowEMA, 1);
    double rsi     = GetIndicator(g_hRSI,     1);

    if(emaFast == EMPTY_VALUE || emaSlow == EMPTY_VALUE || rsi == EMPTY_VALUE)
        return;

    // Also read current bar to avoid acting on stale cross
    double emaFastCur = GetIndicator(g_hFastEMA, 0);
    double emaSlowCur = GetIndicator(g_hSlowEMA, 0);
    if(emaFastCur == EMPTY_VALUE || emaSlowCur == EMPTY_VALUE) return;

    double lot1 = LevelLot(0);

    // BUY: fast > slow on closed bar AND current bar, RSI confirms uptrend
    if(emaFast > emaSlow && emaFastCur > emaSlowCur && rsi >= InpRSIBuyMin)
    {
        if(g_trade.Buy(lot1, _Symbol, 0, 0, 0, InpComment + "_L1"))
        {
            g_lastBarTime = currentBar;
            PrintFormat("NEW BUY L1 | lot=%.2f | EMA%d=%.5f EMA%d=%.5f RSI=%.1f",
                        lot1, InpFastEMA, emaFast, InpSlowEMA, emaSlow, rsi);
        }
    }
    // SELL: fast < slow on closed bar AND current bar, RSI confirms downtrend
    else if(emaFast < emaSlow && emaFastCur < emaSlowCur && rsi <= InpRSISellMax)
    {
        if(g_trade.Sell(lot1, _Symbol, 0, 0, 0, InpComment + "_L1"))
        {
            g_lastBarTime = currentBar;
            PrintFormat("NEW SELL L1 | lot=%.2f | EMA%d=%.5f EMA%d=%.5f RSI=%.1f",
                        lot1, InpFastEMA, emaFast, InpSlowEMA, emaSlow, rsi);
        }
    }
}

//──────────────────────────────────────────────────────────────────
//  END OF FILE
//──────────────────────────────────────────────────────────────────
