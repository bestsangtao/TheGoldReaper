//+------------------------------------------------------------------+
//|                                               StrategyBase.mqh   |
//|  Abstract base for the 10 independent gating strategies.          |
//|  A strategy's only job is to decide WHEN the AI should be asked   |
//|  for a trade decision (its own indicators / own logic / own       |
//|  magic number / own cooldown) - the actual buy/sell/entry/sl/tp    |
//|  decision always comes back from Gemini, never from the strategy. |
//+------------------------------------------------------------------+
#property strict

class CStrategyBase
  {
protected:
   int               m_id;
   string            m_name;
   long              m_magic;
   string            m_symbol;
   ENUM_TIMEFRAMES   m_tf;
   int               m_snapshotBars;   // how many OHLC candles to send to the AI
   int               m_cooldownSec;    // minimum seconds between two entry calls from this strategy
   datetime          m_lastSignalTime;
   datetime          m_lastBarTime;

public:
   virtual void      BaseInit(const string symbol, const ENUM_TIMEFRAMES tf, const long magic)
     {
      m_symbol = symbol;
      m_tf = tf;
      m_magic = magic;
      m_lastSignalTime = 0;
      m_lastBarTime = 0;
     }

   virtual bool      Init() { return true; }
   virtual void      Deinit() {}

   //--- returns true when this strategy's gating condition just fired.
   //--- fills strategyIndicatorsJson with a JSON object of the indicator values
   //--- that caused the trigger, and conditionNote with a short human-readable reason.
   virtual bool      CheckSignal(string &strategyIndicatorsJson, string &conditionNote) = 0;

   long              Magic() const { return m_magic; }
   string            Name() const { return m_name; }
   int               Id() const { return m_id; }
   string            Symbol() const { return m_symbol; }
   ENUM_TIMEFRAMES   Timeframe() const { return m_tf; }
   int               SnapshotBars() const { return m_snapshotBars; }

   //--- true once per newly closed bar on this strategy's own timeframe
   bool              IsNewBar()
     {
      datetime t[];
      ArraySetAsSeries(t, true);
      if(CopyTime(m_symbol, m_tf, 0, 1, t) <= 0)
         return false;
      if(t[0] != m_lastBarTime)
        {
         m_lastBarTime = t[0];
         return true;
        }
      return false;
     }

   bool              CooldownReady() const { return (TimeCurrent() - m_lastSignalTime) >= m_cooldownSec; }
   void              MarkTriggered() { m_lastSignalTime = TimeCurrent(); }
  };
//+------------------------------------------------------------------+
