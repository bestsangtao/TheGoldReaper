//+------------------------------------------------------------------+
//| Strategy07_ATRVolatilityBreakout.mqh                             |
//| Gate: the last closed bar's true range expands well beyond its   |
//| ATR (volatility expansion) and closes beyond the prior bar's     |
//| high/low - a volatility breakout setup.                          |
//+------------------------------------------------------------------+
#property strict
#include <GeminiAI/StrategyBase.mqh>

class CStrategy07_ATRVolatilityBreakout : public CStrategyBase
  {
private:
   int      m_hAtr;
   int      m_atrPeriod;
   double   m_expansionMultiplier;

public:
   void     Configure(const string symbol, const ENUM_TIMEFRAMES tf, const long magic,
                      const int atrPeriod = 14, const double expansionMultiplier = 1.8,
                      const int cooldownSec = 1800, const int snapshotBars = 120)
     {
      BaseInit(symbol, tf, magic);
      m_id = 7; m_name = "ATRVolatilityBreakout";
      m_cooldownSec = cooldownSec; m_snapshotBars = snapshotBars;
      m_atrPeriod = atrPeriod; m_expansionMultiplier = expansionMultiplier;
     }

   virtual bool Init(void) override
     {
      m_hAtr = iATR(m_symbol, m_tf, m_atrPeriod);
      return (m_hAtr != INVALID_HANDLE);
     }

   virtual void Deinit(void) override
     {
      if(m_hAtr != INVALID_HANDLE) IndicatorRelease(m_hAtr);
     }

   virtual bool CheckSignal(string &json, string &note) override
     {
      if(!IsNewBar() || !CooldownReady())
         return false;

      double atr[];
      ArraySetAsSeries(atr, true);
      if(CopyBuffer(m_hAtr, 0, 1, 2, atr) < 2) return false; // atr[0]=prior bar's ATR (baseline, excludes the breakout bar itself)

      double high1  = iHigh(m_symbol, m_tf, 1);
      double low1   = iLow(m_symbol, m_tf, 1);
      double close1 = iClose(m_symbol, m_tf, 1);
      double high2  = iHigh(m_symbol, m_tf, 2);
      double low2   = iLow(m_symbol, m_tf, 2);
      double range1 = high1 - low1;
      double baselineAtr = atr[0];

      bool volatilityExpanded = (baselineAtr > 0 && range1 >= baselineAtr * m_expansionMultiplier);
      bool breakoutUp   = (close1 > high2);
      bool breakoutDown = (close1 < low2);

      if(volatilityExpanded && (breakoutUp || breakoutDown))
        {
         json = StringFormat("{\"atr14\":%.5f,\"last_range\":%.5f,\"last_close\":%.5f,\"prev_high\":%.5f,\"prev_low\":%.5f}",
                              baselineAtr, range1, close1, high2, low2);
         note = StringFormat("Bar range %.5f is %.1fx ATR(%d)=%.5f with a %s breakout of the prior bar",
                              range1, range1 / baselineAtr, m_atrPeriod, baselineAtr, breakoutUp ? "upside" : "downside");
         MarkTriggered();
         return true;
        }
      return false;
     }
  };
//+------------------------------------------------------------------+
