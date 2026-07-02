//+------------------------------------------------------------------+
//| Strategy01_TrendEMA.mqh                                          |
//| Gate: fast/slow EMA crossover confirmed by ADX trend strength on |
//| the working timeframe AND agreement with the higher-timeframe    |
//| EMA trend filter (multi-timeframe confirmation).                 |
//+------------------------------------------------------------------+
#property strict
#include <GeminiAI/StrategyBase.mqh>

class CStrategy01_TrendEMA : public CStrategyBase
  {
private:
   int      m_hFast, m_hSlow, m_hAdx;
   int      m_fastPeriod, m_slowPeriod, m_adxPeriod;
   double   m_adxThreshold;

public:
   void     Configure(const string symbol, const ENUM_TIMEFRAMES tf, const long magic,
                      const int fastPeriod = 20, const int slowPeriod = 50, const int adxPeriod = 14,
                      const double adxThreshold = 20.0, const ENUM_TIMEFRAMES higherTf = PERIOD_H4,
                      const int cooldownSec = 1800, const int snapshotBars = 120, const int htfBars = 60,
                      const int htfEmaFast = 50, const int htfEmaSlow = 200)
     {
      BaseInit(symbol, tf, magic, higherTf, htfBars, htfEmaFast, htfEmaSlow);
      m_id = 1; m_name = "TrendEMA";
      m_cooldownSec = cooldownSec; m_snapshotBars = snapshotBars;
      m_fastPeriod = fastPeriod; m_slowPeriod = slowPeriod; m_adxPeriod = adxPeriod; m_adxThreshold = adxThreshold;
     }

   virtual bool Init(void) override
     {
      m_hFast = iMA(m_symbol, m_tf, m_fastPeriod, 0, MODE_EMA, PRICE_CLOSE);
      m_hSlow = iMA(m_symbol, m_tf, m_slowPeriod, 0, MODE_EMA, PRICE_CLOSE);
      m_hAdx  = iADX(m_symbol, m_tf, m_adxPeriod);
      return (m_hFast != INVALID_HANDLE && m_hSlow != INVALID_HANDLE && m_hAdx != INVALID_HANDLE && InitHtfFilter());
     }

   virtual void Deinit(void) override
     {
      if(m_hFast != INVALID_HANDLE) IndicatorRelease(m_hFast);
      if(m_hSlow != INVALID_HANDLE) IndicatorRelease(m_hSlow);
      if(m_hAdx  != INVALID_HANDLE) IndicatorRelease(m_hAdx);
      DeinitHtfFilter();
     }

   virtual bool CheckSignal(string &json, string &note) override
     {
      if(!IsNewBar() || !CooldownReady())
         return false;

      double fast[], slow[], adx[];
      ArraySetAsSeries(fast, true);
      ArraySetAsSeries(slow, true);
      ArraySetAsSeries(adx, true);
      if(CopyBuffer(m_hFast, 0, 0, 3, fast) < 3) return false;
      if(CopyBuffer(m_hSlow, 0, 0, 3, slow) < 3) return false;
      if(CopyBuffer(m_hAdx, 0, 0, 2, adx) < 2) return false;

      bool crossUp   = (fast[2] <= slow[2] && fast[1] > slow[1]);
      bool crossDown = (fast[2] >= slow[2] && fast[1] < slow[1]);
      bool trending  = (adx[1] >= m_adxThreshold);

      if(!((crossUp || crossDown) && trending))
         return false;

      string htfJson;
      ENUM_HTF_BIAS bias = HtfBias(htfJson);
      bool htfAgrees = (crossUp && bias == HTF_BULLISH) || (crossDown && bias == HTF_BEARISH);
      if(!htfAgrees)
         return false;

      string ownJson = StringFormat("{\"ema_fast\":%.5f,\"ema_slow\":%.5f,\"adx14\":%.2f}", fast[1], slow[1], adx[1]);
      json = JsonMergeObjects(ownJson, htfJson);
      note = StringFormat("EMA%d/EMA%d %s crossover with ADX=%.1f (threshold %.1f), confirmed by %s trend on %s",
                           m_fastPeriod, m_slowPeriod, crossUp ? "bullish" : "bearish", adx[1], m_adxThreshold,
                           crossUp ? "bullish" : "bearish", EnumToString(m_higherTf));
      MarkTriggered();
      return true;
     }
  };
//+------------------------------------------------------------------+
