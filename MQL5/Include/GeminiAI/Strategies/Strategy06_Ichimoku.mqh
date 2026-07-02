//+------------------------------------------------------------------+
//| Strategy06_Ichimoku.mqh                                          |
//| Gate: Tenkan-sen / Kijun-sen cross while price is outside        |
//| (above/below) the Kumo cloud - trend-confirmation setup, further |
//| confirmed by higher-timeframe EMA trend agreement (multi-TF).    |
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
                      const ENUM_TIMEFRAMES higherTf = PERIOD_H4,
                      const int cooldownSec = 1800, const int snapshotBars = 150, const int htfBars = 60,
                      const int htfEmaFast = 50, const int htfEmaSlow = 200)
     {
      BaseInit(symbol, tf, magic, higherTf, htfBars, htfEmaFast, htfEmaSlow);
      m_id = 6; m_name = "Ichimoku";
      m_cooldownSec = cooldownSec; m_snapshotBars = snapshotBars;
      m_tenkanPeriod = tenkanPeriod; m_kijunPeriod = kijunPeriod; m_senkouPeriod = senkouPeriod;
     }

   virtual bool Init(void) override
     {
      m_hIchimoku = iIchimoku(m_symbol, m_tf, m_tenkanPeriod, m_kijunPeriod, m_senkouPeriod);
      return (m_hIchimoku != INVALID_HANDLE && InitHtfFilter());
     }

   virtual void Deinit(void) override
     {
      if(m_hIchimoku != INVALID_HANDLE) IndicatorRelease(m_hIchimoku);
      DeinitHtfFilter();
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

      if(!(crossUp || crossDown))
         return false;

      string htfJson;
      ENUM_HTF_BIAS bias = HtfBias(htfJson);
      bool htfAgrees = (crossUp && bias == HTF_BULLISH) || (crossDown && bias == HTF_BEARISH);
      if(!htfAgrees)
         return false;

      string ownJson = StringFormat("{\"tenkan\":%.5f,\"kijun\":%.5f,\"senkou_a\":%.5f,\"senkou_b\":%.5f,\"last_close\":%.5f}",
                                     tenkan[1], kijun[1], spanA[1], spanB[1], lastClose);
      json = JsonMergeObjects(ownJson, htfJson);
      note = StringFormat("Ichimoku Tenkan/Kijun %s cross with price %s the Kumo cloud, confirmed by %s bias on %s",
                           crossUp ? "bullish" : "bearish", crossUp ? "above" : "below",
                           crossUp ? "bullish" : "bearish", EnumToString(m_higherTf));
      MarkTriggered();
      return true;
     }
  };
//+------------------------------------------------------------------+
