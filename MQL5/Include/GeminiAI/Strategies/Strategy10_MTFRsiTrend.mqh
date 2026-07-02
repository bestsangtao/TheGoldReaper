//+------------------------------------------------------------------+
//| Strategy10_MTFRsiTrend.mqh                                       |
//| Gate: multi-timeframe confirmation - RSI on the working          |
//| timeframe crosses the midline (50) in the same direction that    |
//| RSI on the higher timeframe (inherited from CStrategyBase) is    |
//| already positioned. This strategy's own gate IS the multi-       |
//| timeframe check, so it uses RSI on both timeframes directly      |
//| rather than the generic EMA HTF filter used by strategies 1-9.   |
//+------------------------------------------------------------------+
#property strict
#include <GeminiAI/StrategyBase.mqh>

class CStrategy10_MTFRsiTrend : public CStrategyBase
  {
private:
   int               m_hRsiLow, m_hRsiHigh;
   int               m_rsiPeriod;

public:
   void     Configure(const string symbol, const ENUM_TIMEFRAMES tf, const long magic,
                      const ENUM_TIMEFRAMES higherTf = PERIOD_H4, const int rsiPeriod = 14,
                      const int cooldownSec = 1800, const int snapshotBars = 120, const int htfBars = 60,
                      const int htfEmaFast = 50, const int htfEmaSlow = 200)
     {
      BaseInit(symbol, tf, magic, higherTf, htfBars, htfEmaFast, htfEmaSlow);
      m_id = 10; m_name = "MTFRsiTrend";
      m_cooldownSec = cooldownSec; m_snapshotBars = snapshotBars;
      m_rsiPeriod = rsiPeriod;
     }

   virtual bool Init(void) override
     {
      m_hRsiLow  = iRSI(m_symbol, m_tf, m_rsiPeriod, PRICE_CLOSE);
      m_hRsiHigh = iRSI(m_symbol, m_higherTf, m_rsiPeriod, PRICE_CLOSE);
      return (m_hRsiLow != INVALID_HANDLE && m_hRsiHigh != INVALID_HANDLE);
     }

   virtual void Deinit(void) override
     {
      if(m_hRsiLow  != INVALID_HANDLE) IndicatorRelease(m_hRsiLow);
      if(m_hRsiHigh != INVALID_HANDLE) IndicatorRelease(m_hRsiHigh);
     }

   virtual bool CheckSignal(string &json, string &note) override
     {
      if(!IsNewBar() || !CooldownReady())
         return false;

      double rsiLow[], rsiHigh[];
      ArraySetAsSeries(rsiLow, true);
      ArraySetAsSeries(rsiHigh, true);
      if(CopyBuffer(m_hRsiLow, 0, 0, 3, rsiLow) < 3) return false;
      if(CopyBuffer(m_hRsiHigh, 0, 0, 2, rsiHigh) < 2) return false;

      bool lowCrossUp    = (rsiLow[2] <= 50.0 && rsiLow[1] > 50.0);
      bool lowCrossDown  = (rsiLow[2] >= 50.0 && rsiLow[1] < 50.0);
      bool higherBullish = (rsiHigh[1] > 50.0);
      bool higherBearish = (rsiHigh[1] < 50.0);

      bool bullishConfirm = (lowCrossUp && higherBullish);
      bool bearishConfirm = (lowCrossDown && higherBearish);

      if(bullishConfirm || bearishConfirm)
        {
         json = StringFormat("{\"rsi_working_tf\":%.2f,\"rsi_higher_tf\":%.2f,\"higher_timeframe\":\"%s\"}",
                              rsiLow[1], rsiHigh[1], EnumToString(m_higherTf));
         note = StringFormat("RSI(%d) crossed 50 %s on %s, confirmed by RSI(%d)=%.1f on %s",
                              m_rsiPeriod, bullishConfirm ? "up" : "down", EnumToString(m_tf),
                              m_rsiPeriod, rsiHigh[1], EnumToString(m_higherTf));
         MarkTriggered();
         return true;
        }
      return false;
     }
  };
//+------------------------------------------------------------------+
