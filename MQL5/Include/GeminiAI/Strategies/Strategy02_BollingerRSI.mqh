//+------------------------------------------------------------------+
//| Strategy02_BollingerRSI.mqh                                      |
//| Gate: mean-reversion setup - price tags an outer Bollinger band  |
//| while RSI is in an extreme (overbought/oversold) zone.           |
//+------------------------------------------------------------------+
#property strict
#include <GeminiAI/StrategyBase.mqh>

class CStrategy02_BollingerRSI : public CStrategyBase
  {
private:
   int      m_hBands, m_hRsi;
   int      m_bandsPeriod, m_rsiPeriod;
   double   m_bandsDeviation, m_rsiOverbought, m_rsiOversold;

public:
   void     Configure(const string symbol, const ENUM_TIMEFRAMES tf, const long magic,
                      const int bandsPeriod = 20, const double bandsDeviation = 2.0, const int rsiPeriod = 14,
                      const double rsiOverbought = 70.0, const double rsiOversold = 30.0,
                      const int cooldownSec = 1800, const int snapshotBars = 120)
     {
      BaseInit(symbol, tf, magic);
      m_id = 2; m_name = "BollingerRSI";
      m_cooldownSec = cooldownSec; m_snapshotBars = snapshotBars;
      m_bandsPeriod = bandsPeriod; m_bandsDeviation = bandsDeviation; m_rsiPeriod = rsiPeriod;
      m_rsiOverbought = rsiOverbought; m_rsiOversold = rsiOversold;
     }

   virtual bool Init(void) override
     {
      m_hBands = iBands(m_symbol, m_tf, m_bandsPeriod, 0, m_bandsDeviation, PRICE_CLOSE);
      m_hRsi   = iRSI(m_symbol, m_tf, m_rsiPeriod, PRICE_CLOSE);
      return (m_hBands != INVALID_HANDLE && m_hRsi != INVALID_HANDLE);
     }

   virtual void Deinit(void) override
     {
      if(m_hBands != INVALID_HANDLE) IndicatorRelease(m_hBands);
      if(m_hRsi   != INVALID_HANDLE) IndicatorRelease(m_hRsi);
     }

   virtual bool CheckSignal(string &json, string &note) override
     {
      if(!IsNewBar() || !CooldownReady())
         return false;

      double upper[], lower[], rsi[];
      ArraySetAsSeries(upper, true);
      ArraySetAsSeries(lower, true);
      ArraySetAsSeries(rsi, true);
      if(CopyBuffer(m_hBands, 1, 0, 2, upper) < 2) return false;
      if(CopyBuffer(m_hBands, 2, 0, 2, lower) < 2) return false;
      if(CopyBuffer(m_hRsi, 0, 0, 2, rsi) < 2) return false;

      double closePrice = iClose(m_symbol, m_tf, 1);

      bool oversoldTag  = (closePrice <= lower[1] && rsi[1] <= m_rsiOversold);
      bool overboughtTag = (closePrice >= upper[1] && rsi[1] >= m_rsiOverbought);

      if(oversoldTag || overboughtTag)
        {
         json = StringFormat("{\"bb_upper\":%.5f,\"bb_lower\":%.5f,\"rsi14\":%.2f,\"last_close\":%.5f}",
                              upper[1], lower[1], rsi[1], closePrice);
         note = oversoldTag
                ? StringFormat("Price tagged lower Bollinger band with RSI=%.1f (oversold <= %.1f)", rsi[1], m_rsiOversold)
                : StringFormat("Price tagged upper Bollinger band with RSI=%.1f (overbought >= %.1f)", rsi[1], m_rsiOverbought);
         MarkTriggered();
         return true;
        }
      return false;
     }
  };
//+------------------------------------------------------------------+
