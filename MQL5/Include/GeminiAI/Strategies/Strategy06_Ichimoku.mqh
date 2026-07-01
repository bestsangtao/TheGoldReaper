//+------------------------------------------------------------------+
//| Strategy06_Ichimoku.mqh                                          |
//| Gate: Tenkan-sen / Kijun-sen cross while price is outside        |
//| (above/below) the Kumo cloud - trend-confirmation setup.         |
//+------------------------------------------------------------------+
#property strict
#include <GeminiAI/StrategyBase.mqh>

class CStrategy06_Ichimoku : public CStrategyBase
  {
private:
   int      m_hIchimoku;
   int      m_tenkanPeriod, m_kijunPeriod, m_senkouPeriod;

public:
   void     Configure(const string symbol, const ENUM_TIMEFRAMES tf, const long magic,
                      const int tenkanPeriod = 9, const int kijunPeriod = 26, const int senkouPeriod = 52,
                      const int cooldownSec = 1800, const int snapshotBars = 150)
     {
      BaseInit(symbol, tf, magic);
      m_id = 6; m_name = "Ichimoku";
      m_cooldownSec = cooldownSec; m_snapshotBars = snapshotBars;
      m_tenkanPeriod = tenkanPeriod; m_kijunPeriod = kijunPeriod; m_senkouPeriod = senkouPeriod;
     }

   virtual bool Init(void) override
     {
      m_hIchimoku = iIchimoku(m_symbol, m_tf, m_tenkanPeriod, m_kijunPeriod, m_senkouPeriod);
      return (m_hIchimoku != INVALID_HANDLE);
     }

   virtual void Deinit(void) override
     {
      if(m_hIchimoku != INVALID_HANDLE) IndicatorRelease(m_hIchimoku);
     }

   virtual bool CheckSignal(string &json, string &note) override
     {
      if(!IsNewBar() || !CooldownReady())
         return false;

      double tenkan[], kijun[], spanA[], spanB[];
      ArraySetAsSeries(tenkan, true);
      ArraySetAsSeries(kijun, true);
      ArraySetAsSeries(spanA, true);
      ArraySetAsSeries(spanB, true);
      if(CopyBuffer(m_hIchimoku, 0, 0, 3, tenkan) < 3) return false;
      if(CopyBuffer(m_hIchimoku, 1, 0, 3, kijun) < 3) return false;
      if(CopyBuffer(m_hIchimoku, 2, 0, 2, spanA) < 2) return false;
      if(CopyBuffer(m_hIchimoku, 3, 0, 2, spanB) < 2) return false;

      double lastClose = iClose(m_symbol, m_tf, 1);
      double cloudTop    = MathMax(spanA[1], spanB[1]);
      double cloudBottom = MathMin(spanA[1], spanB[1]);

      bool crossUp   = (tenkan[2] <= kijun[2] && tenkan[1] > kijun[1] && lastClose > cloudTop);
      bool crossDown = (tenkan[2] >= kijun[2] && tenkan[1] < kijun[1] && lastClose < cloudBottom);

      if(crossUp || crossDown)
        {
         json = StringFormat("{\"tenkan\":%.5f,\"kijun\":%.5f,\"senkou_a\":%.5f,\"senkou_b\":%.5f,\"last_close\":%.5f}",
                              tenkan[1], kijun[1], spanA[1], spanB[1], lastClose);
         note = StringFormat("Ichimoku Tenkan/Kijun %s cross with price %s the Kumo cloud",
                              crossUp ? "bullish" : "bearish", crossUp ? "above" : "below");
         MarkTriggered();
         return true;
        }
      return false;
     }
  };
//+------------------------------------------------------------------+
