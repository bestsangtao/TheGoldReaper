//+------------------------------------------------------------------+
//| Strategy05_StochasticReversal.mqh                                |
//| Gate: Stochastic %K/%D cross while inside an overbought/oversold |
//| zone (classic reversal-from-extreme setup).                      |
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
                      const int cooldownSec = 900, const int snapshotBars = 120)
     {
      BaseInit(symbol, tf, magic);
      m_id = 5; m_name = "StochasticReversal";
      m_cooldownSec = cooldownSec; m_snapshotBars = snapshotBars;
      m_kPeriod = kPeriod; m_dPeriod = dPeriod; m_slowing = slowing;
      m_overbought = overbought; m_oversold = oversold;
     }

   virtual bool Init(void) override
     {
      m_hStoch = iStochastic(m_symbol, m_tf, m_kPeriod, m_dPeriod, m_slowing, MODE_SMA, STO_LOWHIGH);
      return (m_hStoch != INVALID_HANDLE);
     }

   virtual void Deinit(void) override
     {
      if(m_hStoch != INVALID_HANDLE) IndicatorRelease(m_hStoch);
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

      bool crossUpFromOversold   = (k[2] <= d[2] && k[1] > d[1] && k[1] <= m_oversold + 10 && d[1] <= m_oversold + 10);
      bool crossDownFromOverbought = (k[2] >= d[2] && k[1] < d[1] && k[1] >= m_overbought - 10 && d[1] >= m_overbought - 10);

      if(crossUpFromOversold || crossDownFromOverbought)
        {
         json = StringFormat("{\"stoch_k\":%.2f,\"stoch_d\":%.2f}", k[1], d[1]);
         note = StringFormat("Stochastic(%d,%d,%d) %s crossover near %s zone (K=%.1f D=%.1f)",
                              m_kPeriod, m_dPeriod, m_slowing,
                              crossUpFromOversold ? "bullish" : "bearish",
                              crossUpFromOversold ? "oversold" : "overbought", k[1], d[1]);
         MarkTriggered();
         return true;
        }
      return false;
     }
  };
//+------------------------------------------------------------------+
