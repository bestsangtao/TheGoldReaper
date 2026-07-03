//+------------------------------------------------------------------+
//|                                              GeminiAI_EA.mq5     |
//|  Multi-strategy MT5 EA that uses Google Gemini as its decision   |
//|  engine.                                                          |
//|                                                                    |
//|  - 10 fully independent gating strategies (own indicators, own   |
//|    timeframe, own magic number, own cooldown). Each one only     |
//|    decides WHEN market conditions are worth asking the AI about. |
//|  - When a strategy's gate fires, the EA packages recent OHLC     |
//|    candles + a common indicator basket + the strategy's own      |
//|    indicator readings + timeframe/account context into JSON and  |
//|    asks Gemini for action/order_type/entry/sl/tp.                |
//|  - Once a resulting limit/stop order is triggered (or a market   |
//|    order fills), the position is handed to the Momentum Gate,    |
//|    which re-asks Gemini how to manage the trade (trail stop,     |
//|    move sl/tp, close early, partial close) every time price      |
//|    advances by another ratcheted ATR-based threshold.            |
//+------------------------------------------------------------------+
#property copyright "GeminiAI EA"
#property version   "1.00"
#property strict

#include <GeminiAI/GeminiClient.mqh>
#include <GeminiAI/MarketSnapshot.mqh>
#include <GeminiAI/TradeManager.mqh>
#include <GeminiAI/MomentumGate.mqh>
#include <GeminiAI/StrategyBase.mqh>
#include <GeminiAI/Strategies/Strategy01_TrendEMA.mqh>
#include <GeminiAI/Strategies/Strategy02_BollingerRSI.mqh>
#include <GeminiAI/Strategies/Strategy03_DonchianBreakout.mqh>
#include <GeminiAI/Strategies/Strategy04_MACDMomentum.mqh>
#include <GeminiAI/Strategies/Strategy05_StochasticReversal.mqh>
#include <GeminiAI/Strategies/Strategy06_Ichimoku.mqh>
#include <GeminiAI/Strategies/Strategy07_ATRVolatilityBreakout.mqh>
#include <GeminiAI/Strategies/Strategy08_ParabolicSAR.mqh>
#include <GeminiAI/Strategies/Strategy09_CCIExtreme.mqh>
#include <GeminiAI/Strategies/Strategy10_MTFRsiTrend.mqh>

//======================= INPUTS =======================//
input group "=== Gemini API ==="
input string           InpApiKey            = "";                    // Gemini API key (generativelanguage.googleapis.com)
input string           InpModel             = "gemini-2.0-flash";    // Gemini model id
input int              InpApiTimeoutMs      = 15000;                 // WebRequest timeout (ms)
input double           InpTemperature       = 0.2;                   // Model temperature
input double           InpMinConfidence     = 0.55;                  // Minimum AI confidence (0..1) required to trade

input group "=== Risk / Execution ==="
input double           InpFixedLot          = 0.01;                  // Fixed lot size (used when InpRiskPercent<=0)
input double           InpRiskPercent       = 0.0;                   // Risk % of balance per trade (0 = use fixed lot)
input int              InpSlippagePoints    = 20;                    // Max slippage for market orders, in points
input long             InpMagicBase         = 900000;                // Magic base; each strategy uses InpMagicBase+id
input int              InpMaxTotalPositions = 15;                    // Max simultaneous open positions across all strategies

input group "=== Momentum Management Gate ==="
input double           InpMomentumStartATR  = 0.5;                   // Profit (in ATR units) before first management call
input double           InpMomentumStepATR   = 0.5;                   // Extra ATR units required between management calls
input int              InpManageCooldownSec = 300;                   // Minimum seconds between management calls per position
input int              InpMomentumPeriod    = 14;                    // Momentum(N) indicator period used to confirm the ATR ratchet
input double           InpMomentumMinDeviation = 0.05;                // Min |Momentum-100| required to confirm genuine momentum (not noise)
input int              InpManageSnapshotBars= 60;                    // OHLC bars sent with each management call

input group "=== Multi-Timeframe Filter (shared by all strategies) ==="
input int               InpHtfBars       = 60;                       // Higher-TF OHLC candles sent to the AI
input int               InpHtfEmaFast    = 50;                       // Higher-TF EMA fast period (trend filter)
input int               InpHtfEmaSlow    = 200;                      // Higher-TF EMA slow period (trend filter)

input group "=== Strategy 1: Trend EMA Cross + ADX ==="
input bool              InpS1_Enable   = true;
input ENUM_TIMEFRAMES   InpS1_TF       = PERIOD_H1;
input ENUM_TIMEFRAMES   InpS1_HigherTF = PERIOD_H4;
input int               InpS1_FastEma  = 20;
input int               InpS1_SlowEma  = 50;
input int               InpS1_AdxPeriod= 14;
input double            InpS1_AdxLevel = 20.0;
input int               InpS1_Cooldown = 1800;
input int               InpS1_Bars     = 120;

input group "=== Strategy 2: Bollinger Band + RSI Mean Reversion ==="
input bool              InpS2_Enable      = true;
input ENUM_TIMEFRAMES   InpS2_TF          = PERIOD_M15;
input ENUM_TIMEFRAMES   InpS2_HigherTF    = PERIOD_H1;
input int               InpS2_BandsPeriod = 20;
input double            InpS2_BandsDev    = 2.0;
input int               InpS2_RsiPeriod   = 14;
input double            InpS2_RsiOB       = 70.0;
input double            InpS2_RsiOS       = 30.0;
input int               InpS2_Cooldown    = 1800;
input int               InpS2_Bars        = 120;

input group "=== Strategy 3: Donchian Channel Breakout ==="
input bool              InpS3_Enable   = true;
input ENUM_TIMEFRAMES   InpS3_TF       = PERIOD_H1;
input ENUM_TIMEFRAMES   InpS3_HigherTF = PERIOD_H4;
input int               InpS3_Channel  = 20;
input double            InpS3_VolMult  = 1.5;
input int               InpS3_Cooldown = 1800;
input int               InpS3_Bars     = 120;

input group "=== Strategy 4: MACD Momentum Cross ==="
input bool              InpS4_Enable   = true;
input ENUM_TIMEFRAMES   InpS4_TF       = PERIOD_M30;
input ENUM_TIMEFRAMES   InpS4_HigherTF = PERIOD_H4;
input int               InpS4_Fast     = 12;
input int               InpS4_Slow     = 26;
input int               InpS4_Signal   = 9;
input int               InpS4_Cooldown = 1200;
input int               InpS4_Bars     = 120;

input group "=== Strategy 5: Stochastic Reversal ==="
input bool              InpS5_Enable   = true;
input ENUM_TIMEFRAMES   InpS5_TF       = PERIOD_M15;
input ENUM_TIMEFRAMES   InpS5_HigherTF = PERIOD_H1;
input int               InpS5_K        = 5;
input int               InpS5_D        = 3;
input int               InpS5_Slowing  = 3;
input double            InpS5_OB       = 80.0;
input double            InpS5_OS       = 20.0;
input int               InpS5_Cooldown = 900;
input int               InpS5_Bars     = 120;

input group "=== Strategy 6: Ichimoku Cloud ==="
input bool              InpS6_Enable   = true;
input ENUM_TIMEFRAMES   InpS6_TF       = PERIOD_H1;
input ENUM_TIMEFRAMES   InpS6_HigherTF = PERIOD_H4;
input int               InpS6_Tenkan   = 9;
input int               InpS6_Kijun    = 26;
input int               InpS6_Senkou   = 52;
input int               InpS6_Cooldown = 1800;
input int               InpS6_Bars     = 150;

input group "=== Strategy 7: ATR Volatility Breakout ==="
input bool              InpS7_Enable   = true;
input ENUM_TIMEFRAMES   InpS7_TF       = PERIOD_M30;
input ENUM_TIMEFRAMES   InpS7_HigherTF = PERIOD_H4;
input int               InpS7_AtrPeriod= 14;
input double            InpS7_Expansion= 1.8;
input int               InpS7_Cooldown = 1800;
input int               InpS7_Bars     = 120;

input group "=== Strategy 8: Parabolic SAR Flip ==="
input bool              InpS8_Enable   = true;
input ENUM_TIMEFRAMES   InpS8_TF       = PERIOD_H1;
input ENUM_TIMEFRAMES   InpS8_HigherTF = PERIOD_H4;
input double            InpS8_Step     = 0.02;
input double            InpS8_Max      = 0.2;
input int               InpS8_Cooldown = 1200;
input int               InpS8_Bars     = 120;

input group "=== Strategy 9: CCI Extreme Reversal ==="
input bool              InpS9_Enable   = true;
input ENUM_TIMEFRAMES   InpS9_TF       = PERIOD_M15;
input ENUM_TIMEFRAMES   InpS9_HigherTF = PERIOD_H1;
input int               InpS9_CciPeriod= 14;
input double            InpS9_Extreme  = 100.0;
input int               InpS9_Cooldown = 900;
input int               InpS9_Bars     = 120;

input group "=== Strategy 10: Multi-Timeframe RSI Trend ==="
input bool              InpS10_Enable    = true;
input ENUM_TIMEFRAMES   InpS10_TF        = PERIOD_H1;
input ENUM_TIMEFRAMES   InpS10_HigherTF  = PERIOD_H4;
input int               InpS10_RsiPeriod = 14;
input int               InpS10_Cooldown  = 1800;
input int               InpS10_Bars      = 120;

//======================= GLOBALS =======================//
CGeminiClient     g_gemini;
CTradeManager     g_tradeMgr;
CMomentumGate     g_momentumGate;
CStrategyBase    *g_strategies[];

//+------------------------------------------------------------------+
void AddStrategy(CStrategyBase *s)
  {
   if(s.Init())
     {
      int n = ArraySize(g_strategies);
      ArrayResize(g_strategies, n + 1);
      g_strategies[n] = s;
      Print("[GeminiAI_EA] strategy enabled: ", s.Name(), " symbol=", s.Symbol(), " tf=", EnumToString(s.Timeframe()), " magic=", s.Magic());
     }
   else
     {
      Print("[GeminiAI_EA] strategy FAILED to init: ", s.Name(), " - indicator handle creation error");
      delete s;
     }
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   if(StringLen(InpApiKey) == 0)
     {
      Print("[GeminiAI_EA] ERROR: InpApiKey is empty. Set your Gemini API key in the EA inputs.");
      return(INIT_PARAMETERS_INCORRECT);
     }

   Print("[GeminiAI_EA] Make sure 'https://generativelanguage.googleapis.com' is added under "
         "Tools > Options > Expert Advisors > 'Allow WebRequest for listed URL', otherwise all AI calls will fail.");

   g_gemini.Init(InpApiKey, InpModel, InpApiTimeoutMs, InpTemperature);
   g_tradeMgr.Init(InpSlippagePoints);
   g_momentumGate.Init(InpMomentumStartATR, InpMomentumStepATR, InpManageCooldownSec, InpManageSnapshotBars,
                       InpMomentumPeriod, InpMomentumMinDeviation);

   ArrayResize(g_strategies, 0);

   if(InpS1_Enable)
     {
      CStrategy01_TrendEMA *s = new CStrategy01_TrendEMA();
      s.Configure(_Symbol, InpS1_TF, InpMagicBase + 1, InpS1_FastEma, InpS1_SlowEma, InpS1_AdxPeriod, InpS1_AdxLevel,
                  InpS1_HigherTF, InpS1_Cooldown, InpS1_Bars, InpHtfBars, InpHtfEmaFast, InpHtfEmaSlow);
      AddStrategy(s);
     }
   if(InpS2_Enable)
     {
      CStrategy02_BollingerRSI *s = new CStrategy02_BollingerRSI();
      s.Configure(_Symbol, InpS2_TF, InpMagicBase + 2, InpS2_BandsPeriod, InpS2_BandsDev, InpS2_RsiPeriod, InpS2_RsiOB, InpS2_RsiOS,
                  InpS2_HigherTF, InpS2_Cooldown, InpS2_Bars, InpHtfBars, InpHtfEmaFast, InpHtfEmaSlow);
      AddStrategy(s);
     }
   if(InpS3_Enable)
     {
      CStrategy03_DonchianBreakout *s = new CStrategy03_DonchianBreakout();
      s.Configure(_Symbol, InpS3_TF, InpMagicBase + 3, InpS3_Channel, InpS3_VolMult,
                  InpS3_HigherTF, InpS3_Cooldown, InpS3_Bars, InpHtfBars, InpHtfEmaFast, InpHtfEmaSlow);
      AddStrategy(s);
     }
   if(InpS4_Enable)
     {
      CStrategy04_MACDMomentum *s = new CStrategy04_MACDMomentum();
      s.Configure(_Symbol, InpS4_TF, InpMagicBase + 4, InpS4_Fast, InpS4_Slow, InpS4_Signal,
                  InpS4_HigherTF, InpS4_Cooldown, InpS4_Bars, InpHtfBars, InpHtfEmaFast, InpHtfEmaSlow);
      AddStrategy(s);
     }
   if(InpS5_Enable)
     {
      CStrategy05_StochasticReversal *s = new CStrategy05_StochasticReversal();
      s.Configure(_Symbol, InpS5_TF, InpMagicBase + 5, InpS5_K, InpS5_D, InpS5_Slowing, InpS5_OB, InpS5_OS,
                  InpS5_HigherTF, InpS5_Cooldown, InpS5_Bars, InpHtfBars, InpHtfEmaFast, InpHtfEmaSlow);
      AddStrategy(s);
     }
   if(InpS6_Enable)
     {
      CStrategy06_Ichimoku *s = new CStrategy06_Ichimoku();
      s.Configure(_Symbol, InpS6_TF, InpMagicBase + 6, InpS6_Tenkan, InpS6_Kijun, InpS6_Senkou,
                  InpS6_HigherTF, InpS6_Cooldown, InpS6_Bars, InpHtfBars, InpHtfEmaFast, InpHtfEmaSlow);
      AddStrategy(s);
     }
   if(InpS7_Enable)
     {
      CStrategy07_ATRVolatilityBreakout *s = new CStrategy07_ATRVolatilityBreakout();
      s.Configure(_Symbol, InpS7_TF, InpMagicBase + 7, InpS7_AtrPeriod, InpS7_Expansion,
                  InpS7_HigherTF, InpS7_Cooldown, InpS7_Bars, InpHtfBars, InpHtfEmaFast, InpHtfEmaSlow);
      AddStrategy(s);
     }
   if(InpS8_Enable)
     {
      CStrategy08_ParabolicSAR *s = new CStrategy08_ParabolicSAR();
      s.Configure(_Symbol, InpS8_TF, InpMagicBase + 8, InpS8_Step, InpS8_Max,
                  InpS8_HigherTF, InpS8_Cooldown, InpS8_Bars, InpHtfBars, InpHtfEmaFast, InpHtfEmaSlow);
      AddStrategy(s);
     }
   if(InpS9_Enable)
     {
      CStrategy09_CCIExtreme *s = new CStrategy09_CCIExtreme();
      s.Configure(_Symbol, InpS9_TF, InpMagicBase + 9, InpS9_CciPeriod, InpS9_Extreme,
                  InpS9_HigherTF, InpS9_Cooldown, InpS9_Bars, InpHtfBars, InpHtfEmaFast, InpHtfEmaSlow);
      AddStrategy(s);
     }
   if(InpS10_Enable)
     {
      CStrategy10_MTFRsiTrend *s = new CStrategy10_MTFRsiTrend();
      s.Configure(_Symbol, InpS10_TF, InpMagicBase + 10, InpS10_HigherTF, InpS10_RsiPeriod,
                  InpS10_Cooldown, InpS10_Bars, InpHtfBars, InpHtfEmaFast, InpHtfEmaSlow);
      AddStrategy(s);
     }

   if(ArraySize(g_strategies) == 0)
     {
      Print("[GeminiAI_EA] ERROR: no strategy could be initialized.");
      return(INIT_FAILED);
     }

   EventSetTimer(15);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   for(int i = 0; i < ArraySize(g_strategies); i++)
     {
      g_strategies[i].Deinit();
      delete g_strategies[i];
     }
   ArrayFree(g_strategies);
  }

//+------------------------------------------------------------------+
int MagicToStrategyId(const long magic)
  {
   long offset = magic - InpMagicBase;
   if(offset >= 1 && offset <= 10)
      return (int)offset;
   return -1;
  }

CStrategyBase *FindStrategyByMagic(const long magic)
  {
   for(int i = 0; i < ArraySize(g_strategies); i++)
      if(g_strategies[i].Magic() == magic)
         return g_strategies[i];
   return NULL;
  }

int CountOurOpenPositions()
  {
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      long magic = PositionGetInteger(POSITION_MAGIC);
      if(MagicToStrategyId(magic) > 0)
         count++;
     }
   return count;
  }

double ComputeAtrNow(const string symbol, const ENUM_TIMEFRAMES tf)
  {
   int handle = iATR(symbol, tf, 14);
   if(handle == INVALID_HANDLE)
      return 0.0;
   double buf[];
   ArraySetAsSeries(buf, true);
   double value = 0.0;
   if(CopyBuffer(handle, 0, 1, 1, buf) > 0)
      value = buf[0];
   IndicatorRelease(handle);
   return value;
  }

//+------------------------------------------------------------------+
void HandleStrategySignal(CStrategyBase *strat, const string &indicatorsJson, const string &conditionNote)
  {
   string marketJson = CMarketSnapshot::Build(strat.Symbol(), strat.Timeframe(), strat.SnapshotBars(), indicatorsJson, conditionNote,
                                              strat.HigherTimeframe(), strat.HtfBars());

   SEntryDecision dec;
   if(!g_gemini.RequestEntryDecision(strat.Id(), strat.Name(), conditionNote, marketJson, dec))
      return;

   Print("[", strat.Name(), "] Gemini => action=", dec.action, " type=", dec.orderType,
         " entry=", dec.entryPrice, " sl=", dec.stopLoss, " tp=", dec.takeProfit,
         " conf=", dec.confidence, " reason=", dec.reason);

   if(dec.action == "NONE")
      return;
   if(dec.confidence < InpMinConfidence)
     {
      Print("[", strat.Name(), "] confidence ", dec.confidence, " below threshold ", InpMinConfidence, " - skipping");
      return;
     }
   if(CountOurOpenPositions() >= InpMaxTotalPositions)
     {
      Print("[GeminiAI_EA] max total positions (", InpMaxTotalPositions, ") reached - skipping new entry");
      return;
     }

   ulong ticket = 0;
   if(g_tradeMgr.ExecuteEntry(strat.Symbol(), strat.Magic(), InpFixedLot, InpRiskPercent, dec, ticket))
      Print("[", strat.Name(), "] order sent, ticket=", ticket, " (registered for momentum management on fill)");
  }

//+------------------------------------------------------------------+
void ProcessAll()
  {
   g_momentumGate.Update(g_gemini, g_tradeMgr);

   for(int i = 0; i < ArraySize(g_strategies); i++)
     {
      string indJson, note;
      if(g_strategies[i].CheckSignal(indJson, note))
         HandleStrategySignal(g_strategies[i], indJson, note);
     }
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   ProcessAll();
  }

//+------------------------------------------------------------------+
void OnTimer()
  {
   ProcessAll();
  }

//+------------------------------------------------------------------+
//| Registers a position for momentum-gate management the moment it  |
//| opens - whether it was an instant market fill or a pending       |
//| limit/stop order that just got triggered.                        |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;
   if(!HistoryDealSelect(trans.deal))
      return;

   long magic = HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
   int strategyId = MagicToStrategyId(magic);
   if(strategyId <= 0)
      return;

   ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_IN)
      return;

   ulong posTicket = trans.position;
   if(!PositionSelectByTicket(posTicket))
      return;

   CStrategyBase *strat = FindStrategyByMagic(magic);
   if(strat == NULL || g_momentumGate.IsManaged(posTicket))
      return;

   ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double atr = ComputeAtrNow(strat.Symbol(), strat.Timeframe());

   g_momentumGate.Register(posTicket, strat.Id(), magic, strat.Name(), strat.Symbol(), strat.Timeframe(),
                           strat.HigherTimeframe(), strat.HtfBars(), strat.HtfEmaFastPeriod(), strat.HtfEmaSlowPeriod(),
                           type, entryPrice, atr);
   Print("[", strat.Name(), "] position opened, ticket=", posTicket, " entry=", entryPrice, " atr=", atr, " - now under momentum management");
  }
//+------------------------------------------------------------------+
