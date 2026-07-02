//+------------------------------------------------------------------+
//| Strategy05_StochasticReversal.mqh                                |
//| Gate: Stochastic %K/%D cross while inside an overbought/oversold |
//| zone (classic reversal-from-extreme setup), confirmed by higher- |
//| timeframe EMA trend agreement (multi-timeframe).                  |
//+------------------------------------------------------------------+
#property strict
#include <GeminiAI/StrategyBase.mqh>

class CStrategy05_StochasticReversal : public CStrategyBase
  {
private:
   int      m_hStoch;
   int      m_kPeriod, m_dPeriod, m_slowing;
   double   m_overbought, m_oversold;

public:
   void     Configure(const string symbol, const ENUM_TIMEFRAMES tf, const long magic,
                      const int kPeriod = 5, const int dPeriod = 3, const int slowing = 3,
                      const double overbought = 80.0, const double oversold = 20.0,
                      const ENUM_TIMEFRAMES higherTf = PERIOD_H1,
                      const int cooldownSec = 900, const int snapshotBars = 120, const int htfBars = 60,
                      const int htfEmaFast = 50, const int htfEmaSlow = 200)
     {
      BaseInit(symbol, tf, magic, higherTf, htfBars, htfEmaFast, htfEmaSlow);
      m_id = 5; m_name = "StochasticReversal";
      m_cooldownSec = cooldownSec; m_snapshotBars = snapshotBars;
      m_kPeriod = kPeriod; m_dPeriod = dPeriod; m_slowing = slowing;
      m_overbought = overbought; m_oversold = oversold;
     }

   virtual bool Init(void) override
     {
      m_hStoch = iStochastic(m_symbol, m_tf, m_kPeriod, m_dPeriod, m_slowing, MODE_SMA, STO_LOWHIGH);
      return (m_hStoch != INVALID_HANDLE && InitHtfFilter());
     }

   virtual void Deinit(void) override
     {
      if(m_hStoch != INVALID_HANDLE) IndicatorRelease(m_hStoch);
      DeinitHtfFilter();
     }

   virtual bool CheckSignal(string &json, string &note) override
     {
      if(!IsNewBar() || !CooldownReady())
         return false;

      double k[], d[];
      ArraySetAsSeries(k, true);
      ArraySetAsSeries(d, true);
      if(CopyBuffer(m_hStoch, 0, 0, 3, k) < 3) return false;
      if(CopyBuffer(m_hStoch, 1, 0, 3, d) < 3) return false;

      bool crossUpFromOversold     = (k[2] <= d[2] && k[1] > d[1] && k[1] <= m_oversold + 10 && d[1] <= m_oversold + 10);
      bool crossDownFromOverbought = (k[2] >= d[2] && k[1] < d[1] && k[1] >= m_overbought - 10 && d[1] >= m_overbought - 10);

      if(!(crossUpFromOversold || crossDownFromOverbought))
         return false;

      string htfJson;
      ENUM_HTF_BIAS bias = HtfBias(htfJson);
      bool htfAgrees = (crossUpFromOversold && bias == HTF_BULLISH) || (crossDownFromOverbought && bias == HTF_BEARISH);
      if(!htfAgrees)
         return false;

      string ownJson = StringFormat("{\"stoch_k\":%.2f,\"stoch_d\":%.2f}", k[1], d[1]);
      json = JsonMergeObjects(ownJson, htfJson);
      note = StringFormat("Stochastic(%d,%d,%d) %s crossover near %s zone (K=%.1f D=%.1f), confirmed by %s bias on %s",
                           m_kPeriod, m_dPeriod, m_slowing,
                           crossUpFromOversold ? "bullish" : "bearish",
                           crossUpFromOversold ? "oversold" : "overbought", k[1], d[1],
                           crossUpFromOversold ? "bullish" : "bearish", EnumToString(m_higherTf));
      MarkTriggered();
      return true;
     }
  };
//+------------------------------------------------------------------+
