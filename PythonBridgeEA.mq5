//+------------------------------------------------------------------+
//| PythonBridgeEA.mq5                                               |
//| Two-way bridge: MT5 (Mac/Wine) ↔ Python research engine          |
//|                                                                  |
//| Direction 1 — MT5 → Python (data export)                        |
//|   Every new bar: writes OHLCV + account info to                 |
//|   MQL5/Files/bridge/market_data.csv                             |
//|                                                                  |
//| Direction 2 — Python → MT5 (order execution)                    |
//|   Reads MQL5/Files/bridge/signals.csv every tick               |
//|   Executes market orders from Python signal engine              |
//|                                                                  |
//| Setup:                                                           |
//|   1. Attach to ANY chart in MT5 (e.g. EURUSD H1)               |
//|   2. Allow DLL imports + file operations in EA settings         |
//|   3. Run: python3 live_monitor.py --bridge                      |
//+------------------------------------------------------------------+

#property copyright "Research Bridge"
#property version   "1.00"
#property strict

input int    BridgeInterval = 60;   // Seconds between data exports
input bool   ExecuteSignals = true; // Execute signals from Python
input double MaxLotSize     = 0.10; // Safety cap on lot size
input int    Magic          = 20260519;

string DATA_FILE   = "bridge\\market_data.csv";
string SIGNAL_FILE = "bridge\\signals.csv";
string EXEC_FILE   = "bridge\\executed.csv";
string LOG_FILE    = "bridge\\bridge.log";

datetime last_export  = 0;
datetime last_sig_time= 0;
int      signal_count = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   // Create bridge directory (files go to MQL5/Files/bridge/)
   int f = FileOpen(DATA_FILE, FILE_WRITE|FILE_CSV|FILE_COMMON);
   if(f == INVALID_HANDLE) {
      Print("PythonBridgeEA: Cannot create data file. Check file permissions.");
      return INIT_FAILED;
   }
   FileClose(f);
   
   Print("PythonBridgeEA initialized. Bridge files at: MQL5/Files/bridge/");
   WriteLog("EA initialized on " + Symbol() + " " + EnumToString(Period()));
   ExportMarketData();
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnTick()
{
   datetime now = TimeCurrent();
   
   // Export market data every BridgeInterval seconds
   if(now - last_export >= BridgeInterval)
   {
      ExportMarketData();
      last_export = now;
   }
   
   // Read and execute Python signals
   if(ExecuteSignals)
      ProcessPythonSignals();
}

//+------------------------------------------------------------------+
// Export current market state to CSV for Python to read
//+------------------------------------------------------------------+
void ExportMarketData()
{
   // Write account info + OHLCV for all monitored symbols
   string symbols[] = {"EURUSD","USDJPY","USDCHF","AUDCAD","XAUUSD","NAS100","US500"};
   int nsyms = ArraySize(symbols);
   
   int f = FileOpen(DATA_FILE, FILE_WRITE|FILE_CSV|FILE_COMMON);
   if(f == INVALID_HANDLE) { WriteLog("ERROR: Cannot write market_data.csv"); return; }
   
   // Header
   FileWrite(f, "ts,symbol,bid,ask,close,open,high,low,volume,spread_pts,bar_time");
   
   for(int i = 0; i < nsyms; i++)
   {
      string sym = symbols[i];
      if(!SymbolSelect(sym, true)) continue;
      
      MqlTick tick;
      if(!SymbolInfoTick(sym, tick)) continue;
      
      MqlRates rates[1];
      if(CopyRates(sym, PERIOD_H1, 0, 1, rates) != 1) continue;
      
      double spread = (tick.ask - tick.bid) / SymbolInfoDouble(sym, SYMBOL_POINT);
      
      FileWrite(f,
         IntegerToString((int)TimeCurrent()),
         sym,
         DoubleToString(tick.bid, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS)),
         DoubleToString(tick.ask, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS)),
         DoubleToString(rates[0].close, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS)),
         DoubleToString(rates[0].open,  (int)SymbolInfoInteger(sym, SYMBOL_DIGITS)),
         DoubleToString(rates[0].high,  (int)SymbolInfoInteger(sym, SYMBOL_DIGITS)),
         DoubleToString(rates[0].low,   (int)SymbolInfoInteger(sym, SYMBOL_DIGITS)),
         IntegerToString((int)rates[0].tick_volume),
         DoubleToString(spread, 1),
         IntegerToString((int)rates[0].time)
      );
   }
   
   // Account info row (prefixed with ACCOUNT)
   double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
   double margin   = AccountInfoDouble(ACCOUNT_MARGIN);
   double free_mg  = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   int    n_pos    = PositionsTotal();
   
   FileWrite(f,
      IntegerToString((int)TimeCurrent()),
      "ACCOUNT",
      DoubleToString(balance, 2),
      DoubleToString(equity,  2),
      DoubleToString(margin,  2),
      DoubleToString(free_mg, 2),
      IntegerToString(n_pos),
      "0", "0", "0",
      AccountInfoString(ACCOUNT_CURRENCY)
   );
   
   FileClose(f);
}

//+------------------------------------------------------------------+
// Read signals written by Python and execute them
// Signal CSV format: ts,symbol,action,lots,sl_pips,tp_pips,comment
//+------------------------------------------------------------------+
void ProcessPythonSignals()
{
   if(!FileIsExist(SIGNAL_FILE, FILE_COMMON)) return;
   
   int f = FileOpen(SIGNAL_FILE, FILE_READ|FILE_CSV|FILE_COMMON);
   if(f == INVALID_HANDLE) return;
   
   // Skip header
   if(!FileIsEnding(f)) FileReadString(f);
   
   while(!FileIsEnding(f))
   {
      string ts_str  = FileReadString(f);
      string sym     = FileReadString(f);
      string action  = FileReadString(f);
      string lots_s  = FileReadString(f);
      string sl_s    = FileReadString(f);
      string tp_s    = FileReadString(f);
      string comment = FileReadString(f);
      
      if(sym == "") continue;
      
      datetime sig_ts = (datetime)StringToInteger(ts_str);
      if(sig_ts <= last_sig_time) continue;  // already processed
      
      double lots    = MathMin(StringToDouble(lots_s), MaxLotSize);
      double sl_pips = StringToDouble(sl_s);
      double tp_pips = StringToDouble(tp_s);
      
      if(action == "buy" || action == "sell")
      {
         bool ok = SendMarketOrder(sym, action, lots, sl_pips, tp_pips, comment);
         WriteLog("Signal [" + ts_str + "] " + action + " " + sym +
                  " lots=" + lots_s + " → " + (ok ? "EXECUTED" : "FAILED"));
         if(ok) last_sig_time = sig_ts;
         signal_count++;
      }
      else if(action == "close_all")
      {
         CloseAllPositions(sym);
         WriteLog("close_all " + sym + " from Python signal");
      }
   }
   
   FileClose(f);
}

//+------------------------------------------------------------------+
bool SendMarketOrder(string sym, string action, double lots,
                      double sl_pips, double tp_pips, string comment)
{
   if(!SymbolSelect(sym, true)) { WriteLog("Symbol not found: " + sym); return false; }
   
   MqlTick tick;
   if(!SymbolInfoTick(sym, tick)) return false;
   
   double point   = SymbolInfoDouble(sym, SYMBOL_POINT);
   int    digits  = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double pip     = point * 10;
   
   ENUM_ORDER_TYPE order_type = (action == "buy") ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double price   = (action == "buy") ? tick.ask : tick.bid;
   double sl      = 0, tp = 0;
   
   if(sl_pips > 0)
      sl = (action == "buy") ? price - sl_pips * pip : price + sl_pips * pip;
   if(tp_pips > 0)
      tp = (action == "buy") ? price + tp_pips * pip : price - tp_pips * pip;
   
   MqlTradeRequest  req = {};
   MqlTradeResult   res = {};
   
   req.action    = TRADE_ACTION_DEAL;
   req.symbol    = sym;
   req.volume    = NormalizeDouble(lots, 2);
   req.type      = order_type;
   req.price     = NormalizeDouble(price, digits);
   req.sl        = (sl > 0) ? NormalizeDouble(sl, digits) : 0;
   req.tp        = (tp > 0) ? NormalizeDouble(tp, digits) : 0;
   req.deviation = 20;
   req.magic     = Magic;
   req.comment   = comment;
   req.type_time = ORDER_TIME_GTC;
   req.type_filling = ORDER_FILLING_IOC;
   
   bool ok = OrderSend(req, res);
   
   // Log execution result
   int fe = FileOpen(EXEC_FILE, FILE_READ|FILE_WRITE|FILE_CSV|FILE_COMMON);
   if(fe != INVALID_HANDLE)
   {
      FileSeek(fe, 0, SEEK_END);
      FileWrite(fe, IntegerToString((int)TimeCurrent()), sym, action,
                DoubleToString(lots, 2),
                DoubleToString(res.price, digits),
                IntegerToString(res.retcode),
                IntegerToString(res.order),
                comment);
      FileClose(fe);
   }
   
   return ok && res.retcode == TRADE_RETCODE_DONE;
}

//+------------------------------------------------------------------+
void CloseAllPositions(string sym)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym && sym != "ALL") continue;
      
      string pos_sym = PositionGetString(POSITION_SYMBOL);
      double vol     = PositionGetDouble(POSITION_VOLUME);
      int    ptype   = (int)PositionGetInteger(POSITION_TYPE);
      
      // Reverse direction to close
      SendMarketOrder(pos_sym, (ptype == POSITION_TYPE_BUY ? "sell" : "buy"),
                       vol, 0, 0, "close_from_python");
   }
}

//+------------------------------------------------------------------+
void WriteLog(string msg)
{
   int f = FileOpen(LOG_FILE, FILE_READ|FILE_WRITE|FILE_TXT|FILE_COMMON);
   if(f == INVALID_HANDLE) return;
   FileSeek(f, 0, SEEK_END);
   FileWriteString(f, TimeToString(TimeCurrent()) + " | " + msg + "\n");
   FileClose(f);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   WriteLog("EA stopped. Reason: " + IntegerToString(reason));
}
//+------------------------------------------------------------------+
