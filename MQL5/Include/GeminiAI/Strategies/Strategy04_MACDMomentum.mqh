//+------------------------------------------------------------------+
//| Strategy04_MACDMomentum.mqh                                      |
//| Gate: MACD main line crosses its signal line and the histogram   |
//| flips sign on the same bar (fresh momentum shift).                |
//+------------------------------------------------------------------+
#property strict
#include <GeminiAI/StrategyBase.mqh>

class CStrategy04_MACDMomentum : public CStrategyBase
  {
private:
   int      m_hMacd;
   int      m_fastEma, m_slowEma, m_signalPeriod;

public:
   void     Configure(const string symbol, const ENUM_TIMEFRAMES tf, const long magic,
                      const int fastEma = 12, const int slowEma = 26, const int signalPeriod = 9,
                      const int cooldownSec = 1200, const int snapshotBars = 120)
     {
      BaseInit(symbol, tf, magic);
      m_id = 4; m_name = "MACDMomentum";
      m_cooldownSec = cooldownSec; m_snapshotBars = snapshotBars;
      m_fastEma = fastEma; m_slowEma = slowEma; m_signalPeriod = signalPeriod;
     }

   virtual bool Init(void) override
     {
      m_hMacd = iMACD(m_symbol, m_tf, m_fastEma, m_slowEma, m_signalPeriod, PRICE_CLOSE);
      return (m_hMacd != INVALID_HANDLE);
     }

   virtual void Deinit(void) override
     {
      if(m_hMacd != INVALID_HANDLE) IndicatorRelease(m_hMacd);
     }

   virtual bool CheckSignal(string &json, string &note) override
     {
      if(!IsNewBar() || !CooldownReady())
         return false;

      double main[], signal[];
      ArraySetAsSeries(main, true);
      ArraySetAsSeries(signal, true);
      if(CopyBuffer(m_hMacd, 0, 0, 3, main) < 3) return false;
      if(CopyBuffer(m_hMacd, 1, 0, 3, signal) < 3) return false;

      double hist1 = main[1] - signal[1];
      double hist2 = main[2] - signal[2];

      bool crossUp   = (main[2] <= signal[2] && main[1] > signal[1] && hist2 <= 0 && hist1 > 0);
      bool crossDown = (main[2] >= signal[2] && main[1] < signal[1] && hist2 >= 0 && hist1 < 0);

      if(crossUp || crossDown)
        {
         json = StringFormat("{\"macd_main\":%.6f,\"macd_signal\":%.6f,\"macd_hist\":%.6f}", main[1], signal[1], hist1);
         note = StringFormat("MACD(%d,%d,%d) %s crossover with histogram flip", m_fastEma, m_slowEma, m_signalPeriod,
                              crossUp ? "bullish" : "bearish");
         MarkTriggered();
         return true;
        }
      return false;
     }
  };
//+------------------------------------------------------------------+
