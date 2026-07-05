//+------------------------------------------------------------------+
//|                                               StrategyBase.mqh   |
//|  Abstract base for the 10 independent gating strategies.          |
//|  A strategy's only job is to decide WHEN the AI should be asked   |
//|  for a trade decision (its own indicators / own logic / own       |
//|  magic number / own cooldown) - the actual buy/sell/entry/sl/tp    |
//|  decision always comes back from Gemini, never from the strategy. |
//|                                                                    |
//|  Every strategy is multi-timeframe by construction: on top of its |
//|  own working-timeframe indicator(s), CStrategyBase provides a     |
//|  higher-timeframe EMA trend filter (InitHtfFilter/HtfBias) that   |
//|  each strategy must agree with before it is allowed to fire, and  |
//|  the market snapshot handed to Gemini always carries OHLC +       |
//|  indicators from BOTH timeframes so the AI itself reasons across  |
//|  timeframes too.                                                  |
//+------------------------------------------------------------------+
#property strict
#include <GeminiAI/Conversation.mqh>

enum ENUM_HTF_BIAS
  {
   HTF_BULLISH,
   HTF_BEARISH,
   HTF_NEUTRAL
  };

//--- merges two JSON object literals ("{...}" + "{...}") into a single object
string JsonMergeObjects(const string a, const string b)
  {
   string innerA = (StringLen(a) >= 2) ? StringSubstr(a, 1, StringLen(a) - 2) : "";
   string innerB = (StringLen(b) >= 2) ? StringSubstr(b, 1, StringLen(b) - 2) : "";
   if(StringLen(innerA) == 0) return "{" + innerB + "}";
   if(StringLen(innerB) == 0) return "{" + innerA + "}";
   return "{" + innerA + "," + innerB + "}";
  }

//--- standalone (handle-on-demand) higher-timeframe EMA trend bias, usable by code that
//--- does not keep a persistent strategy object around - e.g. the momentum management gate.
ENUM_HTF_BIAS ComputeHtfTrendBias(const string symbol, const ENUM_TIMEFRAMES higherTf,
                                  const int emaFastPeriod, const int emaSlowPeriod, string &htfJson)
  {
   int hFast = iMA(symbol, higherTf, emaFastPeriod, 0, MODE_EMA, PRICE_CLOSE);
   int hSlow = iMA(symbol, higherTf, emaSlowPeriod, 0, MODE_EMA, PRICE_CLOSE);
   ENUM_HTF_BIAS bias = HTF_NEUTRAL;
   double fast[], slow[];
   ArraySetAsSeries(fast, true);
   ArraySetAsSeries(slow, true);
   if(hFast != INVALID_HANDLE && hSlow != INVALID_HANDLE &&
      CopyBuffer(hFast, 0, 1, 1, fast) > 0 && CopyBuffer(hSlow, 0, 1, 1, slow) > 0)
     {
      htfJson = StringFormat("{\"htf\":\"%s\",\"htf_ema_fast\":%.5f,\"htf_ema_slow\":%.5f}", EnumToString(higherTf), fast[0], slow[0]);
      if(fast[0] > slow[0]) bias = HTF_BULLISH;
      else if(fast[0] < slow[0]) bias = HTF_BEARISH;
     }
   else
      htfJson = "{}";
   if(hFast != INVALID_HANDLE) IndicatorRelease(hFast);
   if(hSlow != INVALID_HANDLE) IndicatorRelease(hSlow);
   return bias;
  }

class CStrategyBase
  {
protected:
   int               m_id;
   string            m_name;
   long              m_magic;
   string            m_symbol;
   ENUM_TIMEFRAMES   m_tf;
   int               m_snapshotBars;   // how many working-TF OHLC candles to send to the AI
   int               m_cooldownSec;    // minimum seconds between two entry calls from this strategy
   datetime          m_lastSignalTime;
   datetime          m_lastBarTime;

   //--- multi-timeframe trend filter (higher timeframe EMA fast/slow)
   ENUM_TIMEFRAMES   m_higherTf;
   int               m_htfBars;        // higher-TF OHLC candles to send to the AI
   int               m_htfEmaFastPeriod;
   int               m_htfEmaSlowPeriod;
   int               m_htfEmaFastHandle;
   int               m_htfEmaSlowHandle;

   //--- rolling memory of this strategy's own recent entry decisions
   CConversation     m_entryConvo;

public:
   virtual void      BaseInit(const string symbol, const ENUM_TIMEFRAMES tf, const long magic,
                              const ENUM_TIMEFRAMES higherTf, const int htfBars = 60,
                              const int htfEmaFastPeriod = 50, const int htfEmaSlowPeriod = 200)
     {
      m_symbol = symbol;
      m_tf = tf;
      m_magic = magic;
      m_lastSignalTime = 0;
      m_lastBarTime = 0;
      m_higherTf = higherTf;
      m_htfBars = htfBars;
      m_htfEmaFastPeriod = htfEmaFastPeriod;
      m_htfEmaSlowPeriod = htfEmaSlowPeriod;
      m_htfEmaFastHandle = INVALID_HANDLE;
      m_htfEmaSlowHandle = INVALID_HANDLE;
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
   ENUM_TIMEFRAMES   HigherTimeframe() const { return m_higherTf; }
   int               HtfBars() const { return m_htfBars; }
   int               HtfEmaFastPeriod() const { return m_htfEmaFastPeriod; }
   int               HtfEmaSlowPeriod() const { return m_htfEmaSlowPeriod; }

   //--- entry-decision memory: set how many recent exchanges to remember (0 = off)
   void              SetEntryMemoryTurns(const int turns) { m_entryConvo.Init(turns); }
   CConversation    *EntryConvo() { return GetPointer(m_entryConvo); }

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

   //--- creates the higher-timeframe EMA fast/slow handles; call from each derived Init()
   bool              InitHtfFilter()
     {
      m_htfEmaFastHandle = iMA(m_symbol, m_higherTf, m_htfEmaFastPeriod, 0, MODE_EMA, PRICE_CLOSE);
      m_htfEmaSlowHandle = iMA(m_symbol, m_higherTf, m_htfEmaSlowPeriod, 0, MODE_EMA, PRICE_CLOSE);
      return (m_htfEmaFastHandle != INVALID_HANDLE && m_htfEmaSlowHandle != INVALID_HANDLE);
     }

   //--- releases the higher-timeframe handles; call from each derived Deinit()
   void              DeinitHtfFilter()
     {
      if(m_htfEmaFastHandle != INVALID_HANDLE) IndicatorRelease(m_htfEmaFastHandle);
      if(m_htfEmaSlowHandle != INVALID_HANDLE) IndicatorRelease(m_htfEmaSlowHandle);
     }

   //--- higher-timeframe trend bias (EMA fast vs EMA slow on the last closed HTF bar).
   //--- also fills htfJson with the raw values so they can be merged into the AI payload.
   ENUM_HTF_BIAS     HtfBias(string &htfJson) const
     {
      double fast[], slow[];
      ArraySetAsSeries(fast, true);
      ArraySetAsSeries(slow, true);
      if(CopyBuffer(m_htfEmaFastHandle, 0, 1, 1, fast) < 1 || CopyBuffer(m_htfEmaSlowHandle, 0, 1, 1, slow) < 1)
        {
         htfJson = "{}";
         return HTF_NEUTRAL;
        }
      htfJson = StringFormat("{\"htf\":\"%s\",\"htf_ema_fast\":%.5f,\"htf_ema_slow\":%.5f}",
                              EnumToString(m_higherTf), fast[0], slow[0]);
      if(fast[0] > slow[0]) return HTF_BULLISH;
      if(fast[0] < slow[0]) return HTF_BEARISH;
      return HTF_NEUTRAL;
     }
  };
//+------------------------------------------------------------------+
