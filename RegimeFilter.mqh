//+------------------------------------------------------------------+
//| RegimeFilter.mqh                                                 |
//| Reads regime_state.json written by live_scorer.py and exposes   |
//| a simple gate: RegimeAllows(strategy_bucket) → bool             |
//|                                                                  |
//| Drop-in for any EA:                                             |
//|   #include "RegimeFilter.mqh"                                   |
//|   RegimeFilter regime("GBPUSD", "MeanReversion");               |
//|   // In OnTick or OnBarOpen:                                     |
//|   if (!regime.IsAllowed()) return;                               |
//+------------------------------------------------------------------+
#property copyright "WestCode 2026"

//--- Regime labels (mirror Python REGIME_THRESHOLDS)
#define REGIME_NORMAL      0
#define REGIME_TRANSITION  1
#define REGIME_ABNORMAL    2
#define REGIME_STRESS      3

//--- Strategy bucket → max regime it may trade in
//    Must match STRATEGY_MATRIX in run_regime.py
int RegimeMaxAllowed(string bucket)
{
   if (bucket == "MeanReversion")   return REGIME_TRANSITION;  // 0-1
   if (bucket == "GapContinuation") return REGIME_TRANSITION;  // 0-1
   if (bucket == "GridInventory")   return REGIME_NORMAL;      // 0 only
   if (bucket == "ATRBreakout")     return REGIME_ABNORMAL;    // 0-2
   if (bucket == "TrendFollowing")  return REGIME_STRESS;      // always
   if (bucket == "SqueezeBreakout") return REGIME_ABNORMAL;    // 0-2
   if (bucket == "AsianRange")      return REGIME_TRANSITION;  // 0-1
   if (bucket == "RSI2Trend")       return REGIME_TRANSITION;  // 0-1
   if (bucket == "HFTScalper")      return REGIME_NORMAL;      // 0 only
   if (bucket == "HedgeMode")       return REGIME_STRESS;      // stress only (min=3)
   return REGIME_TRANSITION; // safe default
}

int RegimeMinAllowed(string bucket)
{
   if (bucket == "HedgeMode") return REGIME_STRESS;
   return REGIME_NORMAL;
}

//+------------------------------------------------------------------+
//| RegimeState — holds current regime for one symbol               |
//+------------------------------------------------------------------+
struct RegimeState
{
   int      label;           // 0-3
   double   score;           // rolling Z-score of loss
   double   loss;            // raw reconstruction loss
   int      cluster;         // KMeans cluster id
   datetime last_update;     // when the file was last parsed
   bool     valid;           // false if file not found or stale
};

//+------------------------------------------------------------------+
//| RegimeFilter — main class                                        |
//+------------------------------------------------------------------+
class RegimeFilter
{
private:
   string         m_symbol;
   string         m_bucket;
   string         m_json_path;
   RegimeState    m_state;
   datetime       m_last_read;
   int            m_read_interval_sec;
   bool           m_enabled;

   //--- Very minimal JSON field extractor (no library needed)
   bool ExtractJsonInt(const string &json, const string key, int &val)
   {
      string search = "\"" + key + "\": ";
      int pos = StringFind(json, search);
      if (pos < 0) return false;
      pos += StringLen(search);
      string raw = StringSubstr(json, pos, 6);
      val = (int)StringToInteger(raw);
      return true;
   }

   bool ExtractJsonDouble(const string &json, const string key, double &val)
   {
      string search = "\"" + key + "\": ";
      int pos = StringFind(json, search);
      if (pos < 0) return false;
      pos += StringLen(search);
      string raw = StringSubstr(json, pos, 12);
      val = StringToDouble(raw);
      return true;
   }

   bool ParseStateFile()
   {
      int fh = FileOpen(m_json_path, FILE_READ | FILE_TXT | FILE_ANSI | FILE_SHARE_READ);
      if (fh == INVALID_HANDLE)
      {
         Print("[RegimeFilter] Cannot open: ", m_json_path, " (error ", GetLastError(), ")");
         m_state.valid = false;
         return false;
      }

      string raw = "";
      while (!FileIsEnding(fh))
         raw += FileReadString(fh);
      FileClose(fh);

      // Find the symbol block
      string sym_key = "\"" + m_symbol + "\"";
      int sym_pos = StringFind(raw, sym_key);
      if (sym_pos < 0)
      {
         Print("[RegimeFilter] Symbol '", m_symbol, "' not found in regime_state.json");
         m_state.valid = false;
         return false;
      }

      // Extract a window of ~300 chars starting from the symbol block
      string block = StringSubstr(raw, sym_pos, 400);

      int label;
      double score, loss;
      int cluster;

      if (!ExtractJsonInt(block,    "regime_label", label))   { m_state.valid = false; return false; }
      if (!ExtractJsonDouble(block, "regime_score", score))   { m_state.valid = false; return false; }
      if (!ExtractJsonDouble(block, "loss",         loss))    { m_state.valid = false; return false; }
      if (!ExtractJsonInt(block,    "cluster",      cluster)) { m_state.valid = false; return false; }

      m_state.label       = label;
      m_state.score       = score;
      m_state.loss        = loss;
      m_state.cluster     = cluster;
      m_state.last_update = TimeCurrent();
      m_state.valid       = true;

      return true;
   }

public:
   RegimeFilter(string symbol, string bucket,
                string json_path      = "",
                int    read_interval  = 300,
                bool   enabled        = true)
   {
      m_symbol           = symbol;
      m_bucket           = bucket;
      m_read_interval_sec = read_interval;
      m_enabled          = enabled;
      m_last_read        = 0;

      m_state.valid = false;
      m_state.label = REGIME_NORMAL;
      m_state.score = 0.0;
      m_state.loss  = 0.0;

      if (json_path == "")
      {
         // Default: same folder as the EA's MQL5/Files directory
         m_json_path = "regime_state.json";
      }
      else
      {
         m_json_path = json_path;
      }
   }

   //--- Call this at the start of OnTick or on new bar
   void Refresh()
   {
      if (!m_enabled) return;
      if (TimeCurrent() - m_last_read < m_read_interval_sec) return;
      m_last_read = TimeCurrent();
      ParseStateFile();
   }

   //--- Returns true if this strategy bucket may trade right now
   bool IsAllowed()
   {
      if (!m_enabled) return true;  // filter disabled → always trade

      Refresh();

      if (!m_state.valid)
      {
         // File missing or stale — fail safe: allow normal strategies, block stress
         Print("[RegimeFilter] State invalid/stale — defaulting to NORMAL regime");
         return RegimeMaxAllowed(m_bucket) >= REGIME_NORMAL &&
                RegimeMinAllowed(m_bucket) <= REGIME_NORMAL;
      }

      return (m_state.label >= RegimeMinAllowed(m_bucket)) &&
             (m_state.label <= RegimeMaxAllowed(m_bucket));
   }

   //--- Accessors
   int     Label()   { Refresh(); return m_state.label;   }
   double  Score()   { Refresh(); return m_state.score;   }
   double  Loss()    { Refresh(); return m_state.loss;     }
   int     Cluster() { Refresh(); return m_state.cluster;  }
   bool    Valid()   { return m_state.valid;                }
   string  Name()
   {
      switch(m_state.label)
      {
         case REGIME_NORMAL:     return "normal";
         case REGIME_TRANSITION: return "transition";
         case REGIME_ABNORMAL:   return "abnormal";
         case REGIME_STRESS:     return "stress";
         default:                return "unknown";
      }
   }

   void PrintStatus()
   {
      Print("[RegimeFilter] ", m_symbol, " | regime=", Name(),
            " (", m_state.label, ") | score=", DoubleToString(m_state.score, 3),
            " | allowed=", IsAllowed() ? "YES" : "NO",
            " | bucket=", m_bucket);
   }
};
