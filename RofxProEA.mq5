//+------------------------------------------------------------------+
//|                                                  RofxProEA.mq5   |
//|  Rofx strategy — AGGRESSIVE configuration                        |
//|  Target: ~25-35% CAGR at 8-12% max drawdown                     |
//|                                                                   |
//|  Key differences vs RofxRecoveryEA (conservative):               |
//|    • Base lot 0.07 (vs 0.01)                                     |
//|    • Holds overnight — no session-end force close                 |
//|    • Tighter grid 20 pips (vs 25) → faster basket recovery       |
//|    • Tighter TP 15 pips (vs 18) → higher hit probability         |
//|    • 5 max levels (vs 6) → slightly less tail exposure           |
//|    • Works on any major pair — attach to 4 charts:               |
//|        EURUSD H1 / GBPUSD H1 / AUDUSD H1 / USDJPY H1            |
//+------------------------------------------------------------------+
#property copyright "WestCode 2026"
#property version   "1.00"
#property description "Rofx Pro — aggressive mode, multi-pair, overnight holds"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//──────────────────────────────────────────────────────────────────
//  INPUT PARAMETERS
//──────────────────────────────────────────────────────────────────

input group "=== SIGNAL ==="
input int    InpFastEMA    = 21;
input int    InpSlowEMA    = 50;
input int    InpRSIPeriod  = 14;
input double InpRSIBuyMin  = 52.0;
input double InpRSISellMax = 48.0;
input int    InpADXPeriod  = 14;          // ADX confirmation — avoid flat markets
input double InpADXMin     = 18.0;        // Min ADX to allow entry

input group "=== MARTINGALE GRID ==="
input double InpBaseLot      = 0.05;     // Base lot — PRO mode
input double InpMultiplier   = 1.60;
input int    InpMaxLevels    = 5;        // Capped at 5 (controls tail risk)
input int    InpGridStepPips = 20;       // Tighter grid → faster recovery
input int    InpBasketTPPips = 15;       // Tighter TP → higher hit rate

input group "=== RISK MANAGEMENT ==="
input double InpMaxBasketRiskPct = 1.5;  // Hard stop per basket: 1.5% of balance
input double InpMaxTotalRiskPct  = 6.0;  // Global ceiling: 4 pairs × 1.5% = 6%
input bool   InpCloseOnSessionEnd = false; // OFF — hold overnight for full recovery

input group "=== SESSION FILTER ==="
input int    InpSessionStart = 0;        // All hours — true overnight holds
input int    InpSessionEnd   = 20;       // New entries only; holds run past this
input bool   InpMondayFriday = true;     // Close any open basket Friday 21:00

input group "=== EA IDENTITY ==="
input int    InpMagic  = 202900;
input string InpComment = "RofxPro";

//──────────────────────────────────────────────────────────────────
//  GLOBALS
//──────────────────────────────────────────────────────────────────
CTrade   g_trade;
int      g_magic;
double   g_pipSize;
double   g_lotStep, g_minLot, g_maxLot;

int      g_hFastEMA = INVALID_HANDLE;
int      g_hSlowEMA = INVALID_HANDLE;
int      g_hRSI     = INVALID_HANDLE;
int      g_hADX     = INVALID_HANDLE;

datetime g_lastBarTime = 0;

//──────────────────────────────────────────────────────────────────
//  INIT / DEINIT
//──────────────────────────────────────────────────────────────────
int OnInit()
{
    g_pipSize = (_Digits == 5 || _Digits == 3) ? _Point * 10.0 : _Point;
    g_minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    g_maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    g_lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

    // Unique magic per symbol to allow multi-pair
    ulong hash = 0;
    string sym  = _Symbol;
    for(int i = 0; i < StringLen(sym); i++)
        hash = hash * 31 + (ulong)StringGetCharacter(sym, i);
    g_magic = InpMagic + (int)(hash % 1000);

    g_trade.SetExpertMagicNumber(g_magic);
    g_trade.SetDeviationInPoints(40);
    g_trade.SetTypeFilling(ORDER_FILLING_IOC);
    g_trade.LogLevel(LOG_LEVEL_ERRORS);

    g_hFastEMA = iMA(_Symbol, PERIOD_H1, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
    g_hSlowEMA = iMA(_Symbol, PERIOD_H1, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
    g_hRSI     = iRSI(_Symbol, PERIOD_H1, InpRSIPeriod, PRICE_CLOSE);
    g_hADX     = iADX(_Symbol, PERIOD_H1, InpADXPeriod);

    if(g_hFastEMA == INVALID_HANDLE || g_hSlowEMA == INVALID_HANDLE ||
       g_hRSI == INVALID_HANDLE     || g_hADX == INVALID_HANDLE)
    {
        Print("RofxProEA: indicator handle error");
        return INIT_FAILED;
    }

    PrintFormat("RofxProEA ready | %s | magic=%d | BaseLot=%.2f | "
                "Grid=%d | TP=%d | MaxLevels=%d | Overnight=%s",
                sym, g_magic, InpBaseLot,
                InpGridStepPips, InpBasketTPPips, InpMaxLevels,
                InpCloseOnSessionEnd ? "NO" : "YES");
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
    if(g_hFastEMA != INVALID_HANDLE) IndicatorRelease(g_hFastEMA);
    if(g_hSlowEMA != INVALID_HANDLE) IndicatorRelease(g_hSlowEMA);
    if(g_hRSI     != INVALID_HANDLE) IndicatorRelease(g_hRSI);
    if(g_hADX     != INVALID_HANDLE) IndicatorRelease(g_hADX);
}

//──────────────────────────────────────────────────────────────────
//  HELPERS
//──────────────────────────────────────────────────────────────────
double NormLot(double lot)
{
    lot = MathFloor(lot / g_lotStep) * g_lotStep;
    return NormalizeDouble(MathMax(g_minLot, MathMin(g_maxLot, lot)), 2);
}

double LevelLot(int level)
{
    double lot = InpBaseLot;
    for(int i = 0; i < level; i++) lot *= InpMultiplier;
    return NormLot(lot);
}

double GetBuf(int handle, int buf = 0, int shift = 1)
{
    double b[];
    ArraySetAsSeries(b, true);
    if(CopyBuffer(handle, buf, shift, 1, b) <= 0) return EMPTY_VALUE;
    return b[0];
}

int CountPos(ENUM_POSITION_TYPE dir)
{
    int n = 0;
    for(int i = PositionsTotal()-1; i >= 0; i--)
        if(PositionGetTicket(i) &&
           PositionGetString(POSITION_SYMBOL) == _Symbol &&
           PositionGetInteger(POSITION_MAGIC) == g_magic &&
           PositionGetInteger(POSITION_TYPE)  == dir) n++;
    return n;
}

double AvgEntry(ENUM_POSITION_TYPE dir)
{
    double cost=0, lots=0;
    for(int i = PositionsTotal()-1; i >= 0; i--)
        if(PositionGetTicket(i) &&
           PositionGetString(POSITION_SYMBOL) == _Symbol &&
           PositionGetInteger(POSITION_MAGIC) == g_magic &&
           PositionGetInteger(POSITION_TYPE)  == dir)
        {
            double v = PositionGetDouble(POSITION_VOLUME);
            cost += PositionGetDouble(POSITION_PRICE_OPEN) * v;
            lots += v;
        }
    return lots > 0 ? cost/lots : 0;
}

double BasketPL(ENUM_POSITION_TYPE dir)
{
    double pl = 0;
    for(int i = PositionsTotal()-1; i >= 0; i--)
        if(PositionGetTicket(i) &&
           PositionGetString(POSITION_SYMBOL) == _Symbol &&
           PositionGetInteger(POSITION_MAGIC) == g_magic &&
           PositionGetInteger(POSITION_TYPE)  == dir)
            pl += PositionGetDouble(POSITION_PROFIT)
                + PositionGetDouble(POSITION_SWAP);
    return pl;
}

void CloseBasket(ENUM_POSITION_TYPE dir, string reason)
{
    for(int i = PositionsTotal()-1; i >= 0; i--)
    {
        ulong t = PositionGetTicket(i);
        if(!t) continue;
        if(PositionGetString(POSITION_SYMBOL) != _Symbol)   continue;
        if(PositionGetInteger(POSITION_MAGIC) != g_magic)   continue;
        if(PositionGetInteger(POSITION_TYPE)  != dir)       continue;
        if(!g_trade.PositionClose(t, 60))
            PrintFormat("Close err ticket=%I64u reason=%s err=%d",
                        t, reason, GetLastError());
    }
}

bool GlobalRiskOK()
{
    double bal = AccountInfoDouble(ACCOUNT_BALANCE);
    double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
    return bal > 0 && (bal - eq) / bal * 100.0 < InpMaxTotalRiskPct;
}

bool FridayClose()
{
    if(!InpMondayFriday) return false;
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    return (dt.day_of_week == 5 && dt.hour >= 21);
}

//──────────────────────────────────────────────────────────────────
//  ONTICK
//──────────────────────────────────────────────────────────────────
void OnTick()
{
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bal = AccountInfoDouble(ACCOUNT_BALANCE);

    //── Phase 1: Manage existing baskets ─────────────────────────
    for(int d = 0; d <= 1; d++)
    {
        ENUM_POSITION_TYPE dir = (ENUM_POSITION_TYPE)d;
        int levels = CountPos(dir);
        if(levels == 0) continue;

        double avg = AvgEntry(dir);
        double pl  = BasketPL(dir);

        // Friday EOW close
        if(FridayClose())
        {
            CloseBasket(dir, "friday_close");
            continue;
        }

        // Hard basket stop
        if(pl < 0 && -pl / bal * 100.0 >= InpMaxBasketRiskPct)
        {
            PrintFormat("HardStop %s | loss=%.2f (%.1f%%)",
                        EnumToString(dir), -pl, -pl/bal*100.0);
            CloseBasket(dir, "hard_stop");
            continue;
        }

        // Global risk ceiling
        if(!GlobalRiskOK())
        {
            CloseBasket(dir, "global_risk");
            continue;
        }

        // Take profit on basket (check intrabar)
        if(dir == POSITION_TYPE_BUY)
        {
            if(bid >= avg + InpBasketTPPips * g_pipSize)
            {
                CloseBasket(dir, "tp");
                continue;
            }
        }
        else
        {
            if(ask <= avg - InpBasketTPPips * g_pipSize)
            {
                CloseBasket(dir, "tp");
                continue;
            }
        }

        // Add martingale level
        if(levels < InpMaxLevels && GlobalRiskOK())
        {
            double dist;
            if(dir == POSITION_TYPE_BUY)
                dist = (avg - bid) / g_pipSize;
            else
                dist = (ask - avg) / g_pipSize;

            if(dist >= InpGridStepPips)
            {
                double nl = LevelLot(levels);
                bool ok = (dir == POSITION_TYPE_BUY)
                    ? g_trade.Buy (nl, _Symbol, 0, 0, 0,
                                   InpComment+"_L"+IntegerToString(levels+1))
                    : g_trade.Sell(nl, _Symbol, 0, 0, 0,
                                   InpComment+"_L"+IntegerToString(levels+1));
                if(ok)
                    PrintFormat("Level %d | %s | lot=%.2f | dist=%.1f pips",
                                levels+1, EnumToString(dir), nl, dist);
            }
        }
    }

    //── Phase 2: New entry signal ─────────────────────────────────
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    bool inEntryWindow = (dt.hour >= InpSessionStart &&
                          dt.hour < InpSessionEnd  &&
                          dt.day_of_week >= 1 &&
                          dt.day_of_week <= 4);
    // Allow Friday entries only in morning
    if(dt.day_of_week == 5 && dt.hour < 14) inEntryWindow = true;

    if(!inEntryWindow) return;
    if(!GlobalRiskOK()) return;
    if(CountPos(POSITION_TYPE_BUY) > 0 || CountPos(POSITION_TYPE_SELL) > 0) return;

    datetime curBar = iTime(_Symbol, PERIOD_H1, 0);
    if(curBar == g_lastBarTime) return;

    double ef  = GetBuf(g_hFastEMA, 0, 1);
    double es  = GetBuf(g_hSlowEMA, 0, 1);
    double rv  = GetBuf(g_hRSI,     0, 1);
    double adx = GetBuf(g_hADX,     0, 1);  // ADX main line

    if(ef == EMPTY_VALUE || es == EMPTY_VALUE ||
       rv == EMPTY_VALUE || adx == EMPTY_VALUE) return;

    // ADX filter: require some trend momentum to enter
    if(adx < InpADXMin) return;

    double lot1 = LevelLot(0);
    double sp   = g_pipSize;   // spread offset

    if(ef > es && rv >= InpRSIBuyMin)
    {
        if(g_trade.Buy(lot1, _Symbol, 0, 0, 0, InpComment+"_L1"))
        {
            g_lastBarTime = curBar;
            PrintFormat("BUY L1 | lot=%.2f | EMA=%.5f/%.5f RSI=%.1f ADX=%.1f",
                        lot1, ef, es, rv, adx);
        }
    }
    else if(ef < es && rv <= InpRSISellMax)
    {
        if(g_trade.Sell(lot1, _Symbol, 0, 0, 0, InpComment+"_L1"))
        {
            g_lastBarTime = curBar;
            PrintFormat("SELL L1 | lot=%.2f | EMA=%.5f/%.5f RSI=%.1f ADX=%.1f",
                        lot1, ef, es, rv, adx);
        }
    }
}
