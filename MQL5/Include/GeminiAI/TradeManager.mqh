//+------------------------------------------------------------------+
//|                                                TradeManager.mqh  |
//|  Thin wrapper around CTrade that:                                 |
//|   - validates / repairs AI-provided sl/tp/entry against broker    |
//|     stop-level & freeze-level constraints                        |
//|   - sizes volume either fixed or risk-% based                    |
//|   - sends market/limit/stop orders                                |
//|   - exposes modify / close / partial-close for management calls   |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>
#include <GeminiAI/GeminiClient.mqh>

class CTradeManager
  {
private:
   CTrade   m_trade;

   double   NormalizeVolume(const string symbol, double vol) const
     {
      double step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
      double minVol = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
      double maxVol = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
      if(step <= 0) step = 0.01;
      double v = MathRound(vol / step) * step;
      v = MathMax(minVol, MathMin(maxVol, v));
      return NormalizeDouble(v, 2);
     }

   double   CalcLotByRisk(const string symbol, const double riskMoney, const double slDistance) const
     {
      double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
      if(tickSize <= 0 || tickValue <= 0 || slDistance <= 0)
         return SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
      double lossPerLot = (slDistance / tickSize) * tickValue;
      if(lossPerLot <= 0)
         return SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
      return NormalizeVolume(symbol, riskMoney / lossPerLot);
     }

public:
   void     Init(const int slippagePoints)
     {
      m_trade.SetDeviationInPoints(slippagePoints);
      m_trade.SetAsyncMode(false);
      m_trade.LogLevel(LOG_LEVEL_ERRORS);
     }

   //--- validates and repairs entry/sl/tp in place; returns false if the idea must be discarded
   bool     PrepareEntry(const string symbol, SEntryDecision &decision) const
     {
      if(decision.action != "BUY" && decision.action != "SELL")
         return false;

      int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
      double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
      double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
      long stopLevelPts = SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
      long freezeLevelPts = SymbolInfoInteger(symbol, SYMBOL_TRADE_FREEZE_LEVEL);
      double minDist = MathMax((double)MathMax(stopLevelPts, freezeLevelPts), 5.0) * point;

      bool isBuy = (decision.action == "BUY");
      double refPrice = isBuy ? ask : bid;

      string ot = decision.orderType;
      if(ot != "MARKET" && ot != "LIMIT" && ot != "STOP")
         ot = "MARKET";

      if(ot == "LIMIT")
        {
         bool validSide = isBuy ? (decision.entryPrice < refPrice - minDist) : (decision.entryPrice > refPrice + minDist);
         if(!validSide || decision.entryPrice <= 0)
            ot = "MARKET";
        }
      else if(ot == "STOP")
        {
         bool validSide = isBuy ? (decision.entryPrice > refPrice + minDist) : (decision.entryPrice < refPrice - minDist);
         if(!validSide || decision.entryPrice <= 0)
            ot = "MARKET";
        }

      if(ot == "MARKET")
         decision.entryPrice = refPrice;

      decision.orderType = ot;
      decision.entryPrice = NormalizeDouble(decision.entryPrice, digits);

      double entry = decision.entryPrice;
      if(isBuy)
        {
         if(decision.stopLoss <= 0 || decision.stopLoss >= entry) return false;
         if(decision.takeProfit <= 0 || decision.takeProfit <= entry) return false;
         if(entry - decision.stopLoss < minDist) decision.stopLoss = entry - minDist;
         if(decision.takeProfit - entry < minDist) decision.takeProfit = entry + minDist;
        }
      else
        {
         if(decision.stopLoss <= 0 || decision.stopLoss <= entry) return false;
         if(decision.takeProfit <= 0 || decision.takeProfit >= entry) return false;
         if(decision.stopLoss - entry < minDist) decision.stopLoss = entry + minDist;
         if(entry - decision.takeProfit < minDist) decision.takeProfit = entry - minDist;
        }

      decision.stopLoss = NormalizeDouble(decision.stopLoss, digits);
      decision.takeProfit = NormalizeDouble(decision.takeProfit, digits);
      return true;
     }

   //--- sends the (already validated) entry; on success outTicket is the order ticket
   //--- (equal to the position ticket for an instantly-filled market order)
   bool     ExecuteEntry(const string symbol, const long magic, const double fixedLot, const double riskPercent,
                         SEntryDecision &decision, ulong &outTicket)
     {
      if(!PrepareEntry(symbol, decision))
        {
         Print("[TradeManager] entry rejected - invalid action/sl/tp: ", decision.action, " sl=", decision.stopLoss, " tp=", decision.takeProfit);
         return false;
        }

      double lot;
      if(riskPercent > 0)
        {
         double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * riskPercent / 100.0;
         double slDist = MathAbs(decision.entryPrice - decision.stopLoss);
         lot = CalcLotByRisk(symbol, riskMoney, slDist);
        }
      else
         lot = NormalizeVolume(symbol, fixedLot);

      if(lot <= 0)
        {
         Print("[TradeManager] computed lot size is 0, aborting entry");
         return false;
        }

      m_trade.SetExpertMagicNumber(magic);

      bool sent = false;
      datetime expiration = decision.expiryMinutes > 0 ? (TimeCurrent() + decision.expiryMinutes * 60) : 0;
      ENUM_ORDER_TYPE_TIME timeType = decision.expiryMinutes > 0 ? ORDER_TIME_SPECIFIED : ORDER_TIME_GTC;
      string comment = "GeminiAI#" + IntegerToString(magic);

      if(decision.orderType == "MARKET")
        {
         sent = (decision.action == "BUY")
                ? m_trade.Buy(lot, symbol, 0, decision.stopLoss, decision.takeProfit, comment)
                : m_trade.Sell(lot, symbol, 0, decision.stopLoss, decision.takeProfit, comment);
        }
      else if(decision.orderType == "LIMIT")
        {
         sent = (decision.action == "BUY")
                ? m_trade.BuyLimit(lot, decision.entryPrice, symbol, decision.stopLoss, decision.takeProfit, timeType, expiration, comment)
                : m_trade.SellLimit(lot, decision.entryPrice, symbol, decision.stopLoss, decision.takeProfit, timeType, expiration, comment);
        }
      else // STOP
        {
         sent = (decision.action == "BUY")
                ? m_trade.BuyStop(lot, decision.entryPrice, symbol, decision.stopLoss, decision.takeProfit, timeType, expiration, comment)
                : m_trade.SellStop(lot, decision.entryPrice, symbol, decision.stopLoss, decision.takeProfit, timeType, expiration, comment);
        }

      if(!sent)
        {
         Print("[TradeManager] order send failed, retcode=", m_trade.ResultRetcode(), " ", m_trade.ResultRetcodeDescription());
         return false;
        }

      outTicket = m_trade.ResultOrder();
      return true;
     }

   bool     ModifySlTp(const ulong ticket, const double newSL, const double newTP)
     {
      if(!PositionSelectByTicket(ticket))
         return false;
      string symbol = PositionGetString(POSITION_SYMBOL);
      int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
      double sl = newSL > 0 ? NormalizeDouble(newSL, digits) : PositionGetDouble(POSITION_SL);
      double tp = newTP > 0 ? NormalizeDouble(newTP, digits) : PositionGetDouble(POSITION_TP);
      if(!m_trade.PositionModify(ticket, sl, tp))
        {
         Print("[TradeManager] modify failed ticket=", ticket, " retcode=", m_trade.ResultRetcode());
         return false;
        }
      return true;
     }

   bool     ClosePosition(const ulong ticket)
     {
      if(!PositionSelectByTicket(ticket))
         return false;
      if(!m_trade.PositionClose(ticket))
        {
         Print("[TradeManager] close failed ticket=", ticket, " retcode=", m_trade.ResultRetcode());
         return false;
        }
      return true;
     }

   bool     ClosePartial(const ulong ticket, const double fraction)
     {
      if(!PositionSelectByTicket(ticket))
         return false;
      string symbol = PositionGetString(POSITION_SYMBOL);
      double vol = PositionGetDouble(POSITION_VOLUME);
      double closeVol = NormalizeVolume(symbol, vol * MathMax(0.01, MathMin(0.99, fraction)));
      double minVol = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
      if(closeVol < minVol || closeVol >= vol)
         return ClosePosition(ticket);
      if(!m_trade.PositionClosePartial(ticket, closeVol))
        {
         Print("[TradeManager] partial close failed ticket=", ticket, " retcode=", m_trade.ResultRetcode());
         return false;
        }
      return true;
     }
  };
//+------------------------------------------------------------------+
