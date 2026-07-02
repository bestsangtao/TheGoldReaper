//+------------------------------------------------------------------+
//| Strategy09_CCIExtreme.mqh                                        |
//| Gate: CCI re-enters its normal range from an extreme reading -   |
//| e.g. drops back below +100 after being above it (bearish), or    |
//| rises back above -100 after being below it (bullish), confirmed  |
//| by higher-timeframe EMA trend agreement (multi-timeframe).       |
//+------------------------------------------------------------------+
#property strict
#include <GeminiAI/StrategyBase.mqh>

class CStrategy09_CCIExtreme : public CStrategyBase
  {
private:
   int      m_hCci;
   int      m_ccitPeriod;
   double   m_extreme;

public:
   void     Configure(const string symbol, const ENUM_TIMEFRAMES tf, const long magic,
                      const int cciPeriod = 14, const double extreme = 100.0,
                      const ENUM_TIMEFRAMES higherTf = PERIOD_H1,
                      const int cooldownSec = 900, const int snapshotBars = 120, const int htfBars = 60,
                      const int htfEmaFast = 50, const int htfEmaSlow = 200)
     {
      BaseInit(symbol, tf, magic, higherTf, htfBars, htfEmaFast, htfEmaSlow);
      m_id = 9; m_name = "CCIExtreme";
      m_cooldownSec = cooldownSec; m_snapshotBars = snapshotBars;
      m_ccitPeriod = cciPeriod; m_extreme = extreme;
     }

   virtual bool Init(void) override
     {
      m_hCci = iCCI(m_symbol, m_tf, m_ccitPeriod, PRICE_TYPICAL);
      return (m_hCci != INVALID_HANDLE && InitHtfFilter());
     }

   virtual void Deinit(void) override
     {
      if(m_hCci != INVALID_HANDLE) IndicatorRelease(m_hCci);
      DeinitHtfFilter();
     }

   virtual bool CheckSignal(string &json, string &note) override
     {
      if(!IsNewBar() || !CooldownReady())
         return false;

      double cci[];
      ArraySetAsSeries(cci, true);
      if(CopyBuffer(m_hCci, 0, 0, 3, cci) < 3) return false;

      bool bullishReentry = (cci[2] <= -m_extreme && cci[1] > -m_extreme);
      bool bearishReentry = (cci[2] >= m_extreme && cci[1] < m_extreme);

      if(!(bullishReentry || bearishReentry))
         return false;

      string htfJson;
      ENUM_HTF_BIAS bias = HtfBias(htfJson);
      bool htfAgrees = (bullishReentry && bias == HTF_BULLISH) || (bearishReentry && bias == HTF_BEARISH);
      if(!htfAgrees)
         return false;

      string ownJson = StringFormat("{\"cci14\":%.2f,\"prev_cci\":%.2f}", cci[1], cci[2]);
      json = JsonMergeObjects(ownJson, htfJson);
      note = StringFormat("CCI(%d) re-entered normal range from %s extreme (%.1f -> %.1f), confirmed by %s bias on %s",
                           m_ccitPeriod, bullishReentry ? "oversold" : "overbought", cci[2], cci[1],
                           bullishReentry ? "bullish" : "bearish", EnumToString(m_higherTf));
      MarkTriggered();
      return true;
     }
  };
//+------------------------------------------------------------------+
