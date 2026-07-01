//+------------------------------------------------------------------+
//| Strategy03_DonchianBreakout.mqh                                  |
//| Gate: close breaks outside the N-bar Donchian channel (highest   |
//| high / lowest low of the previous N closed bars) on strong       |
//| volume relative to its recent average.                           |
//+------------------------------------------------------------------+
#property strict
#include <GeminiAI/StrategyBase.mqh>

class CStrategy03_DonchianBreakout : public CStrategyBase
  {
private:
   int      m_channelPeriod;
   double   m_volumeMultiplier;

public:
   void     Configure(const string symbol, const ENUM_TIMEFRAMES tf, const long magic,
                      const int channelPeriod = 20, const double volumeMultiplier = 1.5,
                      const int cooldownSec = 1800, const int snapshotBars = 120)
     {
      BaseInit(symbol, tf, magic);
      m_id = 3; m_name = "DonchianBreakout";
      m_cooldownSec = cooldownSec; m_snapshotBars = snapshotBars;
      m_channelPeriod = channelPeriod; m_volumeMultiplier = volumeMultiplier;
     }

   virtual bool Init(void) override { return true; } // uses raw price data, no indicator handles needed
   virtual void Deinit(void) override {}

   virtual bool CheckSignal(string &json, string &note) override
     {
      if(!IsNewBar() || !CooldownReady())
         return false;

      double highs[], lows[];
      long   vols[];
      ArraySetAsSeries(highs, true);
      ArraySetAsSeries(lows, true);
      ArraySetAsSeries(vols, true);
      // shift 1..channelPeriod = the N most recently CLOSED bars, excluding the just-closed one at shift 1's own extremes
      if(CopyHigh(m_symbol, m_tf, 2, m_channelPeriod, highs) < m_channelPeriod) return false;
      if(CopyLow(m_symbol, m_tf, 2, m_channelPeriod, lows) < m_channelPeriod) return false;
      if(CopyTickVolume(m_symbol, m_tf, 1, m_channelPeriod + 1, vols) < m_channelPeriod + 1) return false;

      double channelHigh = highs[ArrayMaximum(highs)];
      double channelLow  = lows[ArrayMinimum(lows)];
      double lastClose   = iClose(m_symbol, m_tf, 1);
      long   lastVol     = vols[0];

      double avgVol = 0;
      for(int i = 1; i < ArraySize(vols); i++)
         avgVol += (double)vols[i];
      avgVol /= (ArraySize(vols) - 1);

      bool volumeConfirms = (avgVol > 0 && lastVol >= avgVol * m_volumeMultiplier);
      bool breakoutUp   = (lastClose > channelHigh);
      bool breakoutDown = (lastClose < channelLow);

      if((breakoutUp || breakoutDown) && volumeConfirms)
        {
         json = StringFormat("{\"channel_high\":%.5f,\"channel_low\":%.5f,\"last_close\":%.5f,\"last_volume\":%d,\"avg_volume\":%.1f}",
                              channelHigh, channelLow, lastClose, (int)lastVol, avgVol);
         note = StringFormat("%d-bar Donchian channel breakout %s with volume %d vs avg %.1f",
                              m_channelPeriod, breakoutUp ? "up" : "down", (int)lastVol, avgVol);
         MarkTriggered();
         return true;
        }
      return false;
     }
  };
//+------------------------------------------------------------------+
