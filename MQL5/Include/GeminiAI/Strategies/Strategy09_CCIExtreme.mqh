//+------------------------------------------------------------------+
//| Strategy09_CCIExtreme.mqh                                        |
//| Gate: CCI re-enters its normal range from an extreme reading -   |
//| e.g. drops back below +100 after being above it (bearish), or    |
//| rises back above -100 after being below it (bullish).            |
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
                      const int cooldownSec = 900, const int snapshotBars = 120)
     {
      BaseInit(symbol, tf, magic);
      m_id = 9; m_name = "CCIExtreme";
      m_cooldownSec = cooldownSec; m_snapshotBars = snapshotBars;
      m_ccitPeriod = cciPeriod; m_extreme = extreme;
     }

   virtual bool Init(void) override
     {
      m_hCci = iCCI(m_symbol, m_tf, m_ccitPeriod, PRICE_TYPICAL);
      return (m_hCci != INVALID_HANDLE);
     }

   virtual void Deinit(void) override
     {
      if(m_hCci != INVALID_HANDLE) IndicatorRelease(m_hCci);
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

      if(bullishReentry || bearishReentry)
        {
         json = StringFormat("{\"cci14\":%.2f,\"prev_cci\":%.2f}", cci[1], cci[2]);
         note = StringFormat("CCI(%d) re-entered normal range from %s extreme (%.1f -> %.1f)",
                              m_ccitPeriod, bullishReentry ? "oversold" : "overbought", cci[2], cci[1]);
         MarkTriggered();
         return true;
        }
      return false;
     }
  };
//+------------------------------------------------------------------+
