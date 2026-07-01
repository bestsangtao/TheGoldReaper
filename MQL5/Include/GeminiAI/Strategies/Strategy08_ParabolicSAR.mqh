//+------------------------------------------------------------------+
//| Strategy08_ParabolicSAR.mqh                                      |
//| Gate: Parabolic SAR dot flips to the opposite side of price -    |
//| a trend-reversal / trend-start signal.                           |
//+------------------------------------------------------------------+
#property strict
#include <GeminiAI/StrategyBase.mqh>

class CStrategy08_ParabolicSAR : public CStrategyBase
  {
private:
   int      m_hSar;
   double   m_step, m_maximum;

public:
   void     Configure(const string symbol, const ENUM_TIMEFRAMES tf, const long magic,
                      const double step = 0.02, const double maximum = 0.2,
                      const int cooldownSec = 1200, const int snapshotBars = 120)
     {
      BaseInit(symbol, tf, magic);
      m_id = 8; m_name = "ParabolicSAR";
      m_cooldownSec = cooldownSec; m_snapshotBars = snapshotBars;
      m_step = step; m_maximum = maximum;
     }

   virtual bool Init(void) override
     {
      m_hSar = iSAR(m_symbol, m_tf, m_step, m_maximum);
      return (m_hSar != INVALID_HANDLE);
     }

   virtual void Deinit(void) override
     {
      if(m_hSar != INVALID_HANDLE) IndicatorRelease(m_hSar);
     }

   virtual bool CheckSignal(string &json, string &note) override
     {
      if(!IsNewBar() || !CooldownReady())
         return false;

      double sar[];
      ArraySetAsSeries(sar, true);
      if(CopyBuffer(m_hSar, 0, 1, 2, sar) < 2) return false; // sar[0]=last closed bar, sar[1]=bar before that

      double close1 = iClose(m_symbol, m_tf, 1);
      double close2 = iClose(m_symbol, m_tf, 2);

      bool wasAbove = sar[1] > close2;
      bool nowBelow = sar[0] < close1;
      bool wasBelow = sar[1] < close2;
      bool nowAbove = sar[0] > close1;

      bool bullishFlip = (wasAbove && nowBelow);
      bool bearishFlip = (wasBelow && nowAbove);

      if(bullishFlip || bearishFlip)
        {
         json = StringFormat("{\"sar\":%.5f,\"last_close\":%.5f}", sar[0], close1);
         note = StringFormat("Parabolic SAR (step=%.3f, max=%.2f) flipped %s of price",
                              m_step, m_maximum, bullishFlip ? "below" : "above");
         MarkTriggered();
         return true;
        }
      return false;
     }
  };
//+------------------------------------------------------------------+
