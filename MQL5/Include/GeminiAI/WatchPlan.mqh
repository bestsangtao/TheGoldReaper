//+------------------------------------------------------------------+
//|                                                  WatchPlan.mqh   |
//|  Real-time "watch and wait" entry engine.                        |
//|                                                                    |
//|  When Gemini decides the idea is good but the ideal entry is at a |
//|  price the market has not reached yet, it returns decision_mode=  |
//|  WATCH with an entry zone + an invalidation price + an expiry.    |
//|  Instead of placing a static pending order, the EA keeps the plan |
//|  here and re-checks it on EVERY tick (like a human watching the   |
//|  chart with an alert set):                                        |
//|    - price enters the zone      -> enter with a market order      |
//|    - price passes invalidation  -> cancel the plan                |
//|    - higher-timeframe trend flips against the trade -> cancel      |
//|    - expiry reached             -> cancel                          |
//|  No extra API call happens at the trigger moment - the decision   |
//|  was already made when the plan was created.                      |
//+------------------------------------------------------------------+
#property strict
#include <GeminiAI/TradeManager.mqh>
#include <GeminiAI/StrategyBase.mqh>

struct SWatchPlan
  {
   int               strategyId;
   long              magic;
   string            strategyName;
   string            symbol;
   ENUM_TIMEFRAMES   tf;
   ENUM_TIMEFRAMES   higherTf;
   int               htfEmaFastPeriod;
   int               htfEmaSlowPeriod;
   bool              isBuy;
   double            entryLow;
   double            entryHigh;
   double            invalidatePrice;
   double            stopLoss;
   double            takeProfit;
   datetime          expiry;
   double            confidence;
   string            reason;
   datetime          createdAt;
  };

class CWatchPlanManager
  {
private:
   SWatchPlan        m_plans[];
   int               m_defaultExpiryMin;

   int               FindByMagic(const long magic) const
     {
      for(int i = 0; i < ArraySize(m_plans); i++)
         if(m_plans[i].magic == magic)
            return i;
      return -1;
     }

   void              RemoveAt(const int idx)
     {
      int n = ArraySize(m_plans);
      for(int i = idx; i < n - 1; i++)
         m_plans[i] = m_plans[i + 1];
      ArrayResize(m_plans, n - 1);
     }

public:
   void              Init(const int defaultExpiryMin) { m_defaultExpiryMin = defaultExpiryMin; ArrayResize(m_plans, 0); }
   int               Count() const { return ArraySize(m_plans); }
   void              Clear() { ArrayResize(m_plans, 0); }

   //--- register a plan; at most one active plan per strategy magic (newest wins)
   void              AddOrReplace(const SWatchPlan &plan)
     {
      int idx = FindByMagic(plan.magic);
      if(idx >= 0)
         m_plans[idx] = plan;
      else
        {
         int n = ArraySize(m_plans);
         ArrayResize(m_plans, n + 1);
         m_plans[n] = plan;
        }
      Print("[WatchPlan] ", plan.strategyName, " armed ", (plan.isBuy ? "BUY" : "SELL"),
            " zone[", plan.entryLow, ",", plan.entryHigh, "] invalidate=", plan.invalidatePrice,
            " sl=", plan.stopLoss, " tp=", plan.takeProfit, " expires=", TimeToString(plan.expiry));
     }

   //--- called every tick: watch all armed plans and act in real time.
   //--- currentOpenCount / maxTotalPositions gate how many new trades may open.
   void              Update(CTradeManager &tm, const double fixedLot, const double riskPercent,
                            const int currentOpenCount, const int maxTotalPositions)
     {
      int openedThisTick = 0;
      for(int i = ArraySize(m_plans) - 1; i >= 0; i--)
        {
         string symbol = m_plans[i].symbol;

         //--- expiry
         if(m_plans[i].expiry > 0 && TimeCurrent() >= m_plans[i].expiry)
           {
            Print("[WatchPlan] ", m_plans[i].strategyName, " expired without triggering - cancelled");
            RemoveAt(i);
            continue;
           }

         double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
         double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
         double mid = (bid + ask) / 2.0;

         //--- invalidation by price (BUY: broke down below; SELL: broke up above)
         bool priceInvalidated = m_plans[i].isBuy ? (mid <= m_plans[i].invalidatePrice)
                                                   : (mid >= m_plans[i].invalidatePrice);
         if(m_plans[i].invalidatePrice > 0 && priceInvalidated)
           {
            Print("[WatchPlan] ", m_plans[i].strategyName, " invalidated (price passed ", m_plans[i].invalidatePrice, ") - cancelled");
            RemoveAt(i);
            continue;
           }

         //--- invalidation by higher-timeframe trend flipping against the trade
         string htfJson;
         ENUM_HTF_BIAS bias = ComputeHtfTrendBias(symbol, m_plans[i].higherTf,
                                                  m_plans[i].htfEmaFastPeriod, m_plans[i].htfEmaSlowPeriod, htfJson);
         bool htfAgainst = (m_plans[i].isBuy && bias == HTF_BEARISH) || (!m_plans[i].isBuy && bias == HTF_BULLISH);
         if(htfAgainst)
           {
            Print("[WatchPlan] ", m_plans[i].strategyName, " cancelled - higher-timeframe trend flipped against the trade");
            RemoveAt(i);
            continue;
           }

         //--- trigger: price reached the entry zone
         bool inZone = (mid >= m_plans[i].entryLow && mid <= m_plans[i].entryHigh);
         if(!inZone)
            continue;

         if(currentOpenCount + openedThisTick >= maxTotalPositions)
            continue; // at capacity - keep the plan armed and retry on a later tick

         SEntryDecision dec;
         dec.valid = true;
         dec.decisionMode = "ENTER_NOW";
         dec.action = m_plans[i].isBuy ? "BUY" : "SELL";
         dec.orderType = "MARKET";
         dec.entryPrice = 0.0;
         dec.stopLoss = m_plans[i].stopLoss;
         dec.takeProfit = m_plans[i].takeProfit;
         dec.expiryMinutes = 0;
         dec.confidence = m_plans[i].confidence;
         dec.reason = m_plans[i].reason;

         ulong ticket = 0;
         Print("[WatchPlan] ", m_plans[i].strategyName, " TRIGGERED at ", mid, " - entering ", dec.action);
         if(tm.ExecuteEntry(symbol, m_plans[i].magic, fixedLot, riskPercent, dec, ticket))
           {
            openedThisTick++;
            RemoveAt(i); // plan fulfilled
           }
         else
           {
            Print("[WatchPlan] ", m_plans[i].strategyName, " trigger execution failed - keeping plan armed");
           }
        }
     }

   int               DefaultExpiryMinutes() const { return m_defaultExpiryMin; }
  };
//+------------------------------------------------------------------+
