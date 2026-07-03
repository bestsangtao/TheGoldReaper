//+------------------------------------------------------------------+
//|                                                MomentumGate.mqh  |
//|  Post-entry order management gate.                                |
//|  Once a strategy's limit/stop entry is triggered (or a market      |
//|  order fills), the resulting position is registered here.          |
//|                                                                     |
//|  The management call itself is gated the same way entries are:    |
//|  indicator + multi-timeframe, not just raw price distance:         |
//|   1) profit-in-ATR ratchet (rate limiter: "has moved enough to be  |
//|      worth checking again") PLUS a real Momentum(N) indicator      |
//|      reading confirming genuine momentum (not noise) -> normal,    |
//|      rate-limited management call.                                 |
//|   2) the higher-timeframe EMA trend bias is re-evaluated every     |
//|      tick per position; if it FLIPS against the position's         |
//|      direction, that overrides the ratchet and fires an immediate  |
//|      management call (early warning - the AI may want to protect   |
//|      profit or exit before the working timeframe catches up).      |
//+------------------------------------------------------------------+
#property strict
#include <GeminiAI/GeminiClient.mqh>
#include <GeminiAI/MarketSnapshot.mqh>
#include <GeminiAI/TradeManager.mqh>
#include <GeminiAI/StrategyBase.mqh>

struct SManagedPosition
  {
   ulong             ticket;
   int               strategyId;
   long              magic;
   string            strategyName;
   string            symbol;
   ENUM_TIMEFRAMES   tf;
   ENUM_TIMEFRAMES   higherTf;
   int               htfBars;
   int               htfEmaFastPeriod;
   int               htfEmaSlowPeriod;
   ENUM_POSITION_TYPE type;
   double            entryPrice;
   double            atrAtEntry;
   int               ratchetLevel;
   datetime          lastManageCall;
   ENUM_HTF_BIAS     lastHtfBias;
  };

class CMomentumGate
  {
private:
   SManagedPosition  m_positions[];
   double            m_startAtrMult;      // profit (in ATR units) required before the first management call
   double            m_stepAtrMult;       // additional ATR units required for every subsequent management call
   int               m_manageCooldownSec;
   int               m_snapshotBars;
   int               m_momentumPeriod;    // Momentum(N) indicator period used as confirmation
   double            m_momentumMinDeviation; // required |Momentum-100| to count as genuine momentum

   int               FindIndex(const ulong ticket) const
     {
      for(int i = 0; i < ArraySize(m_positions); i++)
         if(m_positions[i].ticket == ticket)
            return i;
      return -1;
     }

   void              RemoveAt(const int idx)
     {
      int n = ArraySize(m_positions);
      for(int i = idx; i < n - 1; i++)
         m_positions[i] = m_positions[i + 1];
      ArrayResize(m_positions, n - 1);
     }

   //--- genuine Momentum(N) indicator confirmation on the position's own working timeframe
   bool              CheckMomentumConfirmation(const string symbol, const ENUM_TIMEFRAMES tf, double &momentumValue, double &deviation) const
     {
      int handle = iMomentum(symbol, tf, m_momentumPeriod, PRICE_CLOSE);
      if(handle == INVALID_HANDLE)
         return false;
      double buf[];
      ArraySetAsSeries(buf, true);
      bool ok = (CopyBuffer(handle, 0, 1, 1, buf) > 0);
      IndicatorRelease(handle);
      if(!ok)
         return false;
      momentumValue = buf[0];
      deviation = MathAbs(momentumValue - 100.0);
      return (deviation >= m_momentumMinDeviation);
     }

   string            BuildPositionJson(const int idx, const double currentPrice, const double moveInAtr,
                                       const string triggerReason, const string momentumJson, const string htfJson) const
     {
      string dir = (m_positions[idx].type == POSITION_TYPE_BUY) ? "BUY" : "SELL";
      double sl = 0, tp = 0, profit = 0;
      if(PositionSelectByTicket(m_positions[idx].ticket))
        {
         sl = PositionGetDouble(POSITION_SL);
         tp = PositionGetDouble(POSITION_TP);
         profit = PositionGetDouble(POSITION_PROFIT);
        }
      int digits = (int)SymbolInfoInteger(m_positions[idx].symbol, SYMBOL_DIGITS);
      string posFields = StringFormat(
         "{\"ticket\":%I64u,\"direction\":\"%s\",\"entry_price\":%s,\"current_price\":%s,"
         "\"stop_loss\":%s,\"take_profit\":%s,\"floating_profit\":%s,\"move_in_atr\":%s,\"ratchet_level\":%d,"
         "\"trigger_reason\":\"%s\"}",
         m_positions[idx].ticket, dir,
         DoubleToString(m_positions[idx].entryPrice, digits), DoubleToString(currentPrice, digits),
         DoubleToString(sl, digits), DoubleToString(tp, digits),
         DoubleToString(profit, 2), DoubleToString(moveInAtr, 2), m_positions[idx].ratchetLevel,
         triggerReason);
      posFields = JsonMergeObjects(posFields, momentumJson);
      posFields = JsonMergeObjects(posFields, htfJson);

      string marketJson = CMarketSnapshot::Build(m_positions[idx].symbol, m_positions[idx].tf, m_snapshotBars,
                                                  "{}", "momentum management checkpoint reached: " + triggerReason,
                                                  m_positions[idx].higherTf, m_positions[idx].htfBars);
      return "{\"position\":" + posFields + ",\"market\":" + marketJson + "}";
     }

   void              ApplyDecision(CTradeManager &tm, const ulong ticket, const SManageDecision &dec) const
     {
      if(!dec.valid || dec.action == "HOLD")
         return;
      if(dec.action == "CLOSE")
        {
         tm.ClosePosition(ticket);
         return;
        }
      if(dec.action == "CLOSE_PARTIAL")
        {
         tm.ClosePartial(ticket, dec.closeFraction > 0 ? dec.closeFraction : 0.5);
         return;
        }
      if(dec.action == "MOVE_SL")
        {
         tm.ModifySlTp(ticket, dec.newSL, 0);
         return;
        }
      if(dec.action == "MOVE_TP")
        {
         tm.ModifySlTp(ticket, 0, dec.newTP);
         return;
        }
      if(dec.action == "TRAIL_SL")
        {
         if(!PositionSelectByTicket(ticket))
            return;
         string symbol = PositionGetString(POSITION_SYMBOL);
         double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
         double dist = dec.trailDistancePoints * point;
         if(dist <= 0)
            return;
         ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         double price = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(symbol, SYMBOL_BID) : SymbolInfoDouble(symbol, SYMBOL_ASK);
         double newSl = (type == POSITION_TYPE_BUY) ? (price - dist) : (price + dist);
         double curSl = PositionGetDouble(POSITION_SL);
         bool improves = (type == POSITION_TYPE_BUY) ? (curSl == 0 || newSl > curSl) : (curSl == 0 || newSl < curSl);
         if(improves)
            tm.ModifySlTp(ticket, newSl, 0);
        }
     }

public:
   void              Init(const double startAtrMult, const double stepAtrMult, const int manageCooldownSec, const int snapshotBars,
                          const int momentumPeriod = 14, const double momentumMinDeviation = 0.05)
     {
      m_startAtrMult = startAtrMult;
      m_stepAtrMult = stepAtrMult;
      m_manageCooldownSec = manageCooldownSec;
      m_snapshotBars = snapshotBars;
      m_momentumPeriod = momentumPeriod;
      m_momentumMinDeviation = momentumMinDeviation;
      ArrayResize(m_positions, 0);
     }

   bool              IsManaged(const ulong ticket) const { return FindIndex(ticket) >= 0; }

   void              Register(const ulong ticket, const int strategyId, const long magic, const string strategyName,
                               const string symbol, const ENUM_TIMEFRAMES tf, const ENUM_TIMEFRAMES higherTf,
                               const int htfBars, const int htfEmaFastPeriod, const int htfEmaSlowPeriod,
                               const ENUM_POSITION_TYPE type, const double entryPrice, const double atrAtEntry)
     {
      if(IsManaged(ticket))
         return;
      int n = ArraySize(m_positions);
      ArrayResize(m_positions, n + 1);
      m_positions[n].ticket = ticket;
      m_positions[n].strategyId = strategyId;
      m_positions[n].magic = magic;
      m_positions[n].strategyName = strategyName;
      m_positions[n].symbol = symbol;
      m_positions[n].tf = tf;
      m_positions[n].higherTf = higherTf;
      m_positions[n].htfBars = htfBars;
      m_positions[n].htfEmaFastPeriod = htfEmaFastPeriod;
      m_positions[n].htfEmaSlowPeriod = htfEmaSlowPeriod;
      m_positions[n].type = type;
      m_positions[n].entryPrice = entryPrice;
      m_positions[n].atrAtEntry = atrAtEntry > 0 ? atrAtEntry : SymbolInfoDouble(symbol, SYMBOL_POINT) * 100;
      m_positions[n].ratchetLevel = 0;
      m_positions[n].lastManageCall = 0;

      string htfJson;
      m_positions[n].lastHtfBias = ComputeHtfTrendBias(symbol, higherTf, htfEmaFastPeriod, htfEmaSlowPeriod, htfJson);
      Print("[MomentumGate] registered position #", ticket, " strategy=", strategyName, " atr=", m_positions[n].atrAtEntry,
            " initial_htf_bias=", EnumToString(m_positions[n].lastHtfBias));
     }

   //--- call once per tick (or per timer); drives the whole management gate
   void              Update(CGeminiClient &client, CTradeManager &tm)
     {
      for(int i = ArraySize(m_positions) - 1; i >= 0; i--)
        {
         ulong ticket = m_positions[i].ticket;
         if(!PositionSelectByTicket(ticket))
           {
            RemoveAt(i); // position closed (SL/TP/manual/CLOSE action) - stop tracking
            continue;
           }

         string symbol = m_positions[i].symbol;
         ENUM_POSITION_TYPE type = m_positions[i].type;
         double currentPrice = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(symbol, SYMBOL_BID) : SymbolInfoDouble(symbol, SYMBOL_ASK);
         double moveInPrice = (type == POSITION_TYPE_BUY) ? (currentPrice - m_positions[i].entryPrice) : (m_positions[i].entryPrice - currentPrice);
         double atr = m_positions[i].atrAtEntry;
         if(atr <= 0)
            continue;
         double moveInAtr = moveInPrice / atr;

         bool cooldownReady = (TimeCurrent() - m_positions[i].lastManageCall) >= m_manageCooldownSec;

         //--- multi-timeframe check: has the higher-timeframe trend flipped against the position?
         string htfJson;
         ENUM_HTF_BIAS curBias = ComputeHtfTrendBias(symbol, m_positions[i].higherTf,
                                                      m_positions[i].htfEmaFastPeriod, m_positions[i].htfEmaSlowPeriod, htfJson);
         bool htfFlippedAgainst = (type == POSITION_TYPE_BUY && curBias == HTF_BEARISH && m_positions[i].lastHtfBias != HTF_BEARISH) ||
                                  (type == POSITION_TYPE_SELL && curBias == HTF_BULLISH && m_positions[i].lastHtfBias != HTF_BULLISH);
         m_positions[i].lastHtfBias = curBias;

         //--- indicator confirmation: genuine Momentum(N) reading, checked once the ATR ratchet threshold is reached
         double nextThreshold = m_startAtrMult + m_positions[i].ratchetLevel * m_stepAtrMult;
         bool atrRatchetReached = (moveInAtr >= nextThreshold);
         double momentumValue = 100.0, momentumDeviation = 0.0;
         bool momentumConfirms = atrRatchetReached && CheckMomentumConfirmation(symbol, m_positions[i].tf, momentumValue, momentumDeviation);
         string momentumJson = StringFormat("{\"momentum%d\":%.4f,\"momentum_deviation\":%.4f}", m_momentumPeriod, momentumValue, momentumDeviation);

         string triggerReason = "";
         bool fire = false;
         if(htfFlippedAgainst && cooldownReady)
           {
            fire = true;
            triggerReason = "higher-timeframe trend flipped against the position";
           }
         else if(atrRatchetReached && momentumConfirms && cooldownReady)
           {
            fire = true;
            triggerReason = StringFormat("profit ratchet (%.2f ATR) confirmed by Momentum(%d) deviation %.4f",
                                          moveInAtr, m_momentumPeriod, momentumDeviation);
            m_positions[i].ratchetLevel++;
           }

         if(fire)
           {
            string posJson = BuildPositionJson(i, currentPrice, moveInAtr, triggerReason, momentumJson, htfJson);
            SManageDecision dec;
            if(client.RequestManageDecision(m_positions[i].strategyId, m_positions[i].strategyName, posJson, dec))
              {
               Print("[MomentumGate] manage decision for #", ticket, " (", triggerReason, "): ", dec.action, " - ", dec.reason);
               ApplyDecision(tm, ticket, dec);
              }
            m_positions[i].lastManageCall = TimeCurrent();
           }
        }
     }

   int               Count() const { return ArraySize(m_positions); }
  };
//+------------------------------------------------------------------+
