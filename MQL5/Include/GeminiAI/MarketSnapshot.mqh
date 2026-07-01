//+------------------------------------------------------------------+
//|                                            MarketSnapshot.mqh   |
//|  Builds the JSON payload sent to Gemini: recent OHLC candles,    |
//|  a common indicator basket, account/symbol context, plus a      |
//|  strategy-specific indicator fragment supplied by the caller.   |
//+------------------------------------------------------------------+
#property strict
#include <GeminiAI/Json.mqh>

double SnapshotBufferValue(const int handle, const int bufferIndex, const int shift = 0)
  {
   if(handle == INVALID_HANDLE)
      return 0.0;
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(handle, bufferIndex, shift, 1, buf) <= 0)
      return 0.0;
   return buf[0];
  }

class CMarketSnapshot
  {
public:
   //--- builds the full JSON document sent to Gemini
   static string Build(const string symbol, const ENUM_TIMEFRAMES tf, const int bars,
                       const string strategyIndicatorsJson, const string conditionNote)
     {
      MqlRates rates[];
      ArraySetAsSeries(rates, true);
      int copied = CopyRates(symbol, tf, 0, bars, rates);

      string ohlc = "[";
      for(int i = copied - 1; i >= 0; i--)
        {
         ohlc += StringFormat("{\"time\":\"%s\",\"o\":%s,\"h\":%s,\"l\":%s,\"c\":%s,\"vol\":%d}",
                               TimeToString(rates[i].time, TIME_DATE | TIME_MINUTES),
                               DoubleToString(rates[i].open, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)),
                               DoubleToString(rates[i].high, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)),
                               DoubleToString(rates[i].low, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)),
                               DoubleToString(rates[i].close, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)),
                               (int)rates[i].tick_volume);
         if(i > 0)
            ohlc += ",";
        }
      ohlc += "]";

      //--- common indicator basket (evaluated on the last CLOSED bar, shift=1)
      int hRsi   = iRSI(symbol, tf, 14, PRICE_CLOSE);
      int hMacd  = iMACD(symbol, tf, 12, 26, 9, PRICE_CLOSE);
      int hAdx   = iADX(symbol, tf, 14);
      int hAtr   = iATR(symbol, tf, 14);
      int hStoch = iStochastic(symbol, tf, 5, 3, 3, MODE_SMA, STO_LOWHIGH);
      int hCci   = iCCI(symbol, tf, 14, PRICE_TYPICAL);
      int hMom   = iMomentum(symbol, tf, 14, PRICE_CLOSE);
      int hBands = iBands(symbol, tf, 20, 0, 2.0, PRICE_CLOSE);
      int hMa20  = iMA(symbol, tf, 20, 0, MODE_EMA, PRICE_CLOSE);
      int hMa50  = iMA(symbol, tf, 50, 0, MODE_EMA, PRICE_CLOSE);
      int hMa200 = iMA(symbol, tf, 200, 0, MODE_SMA, PRICE_CLOSE);

      double rsi     = SnapshotBufferValue(hRsi, 0, 1);
      double macdMain = SnapshotBufferValue(hMacd, 0, 1);
      double macdSig  = SnapshotBufferValue(hMacd, 1, 1);
      double adx      = SnapshotBufferValue(hAdx, 0, 1);
      double plusDi    = SnapshotBufferValue(hAdx, 1, 1);
      double minusDi   = SnapshotBufferValue(hAdx, 2, 1);
      double atr       = SnapshotBufferValue(hAtr, 0, 1);
      double stochK    = SnapshotBufferValue(hStoch, 0, 1);
      double stochD    = SnapshotBufferValue(hStoch, 1, 1);
      double cci       = SnapshotBufferValue(hCci, 0, 1);
      double mom       = SnapshotBufferValue(hMom, 0, 1);
      double bandsUp   = SnapshotBufferValue(hBands, 1, 1);
      double bandsLo   = SnapshotBufferValue(hBands, 2, 1);
      double ma20      = SnapshotBufferValue(hMa20, 0, 1);
      double ma50      = SnapshotBufferValue(hMa50, 0, 1);
      double ma200     = SnapshotBufferValue(hMa200, 0, 1);

      IndicatorRelease(hRsi);
      IndicatorRelease(hMacd);
      IndicatorRelease(hAdx);
      IndicatorRelease(hAtr);
      IndicatorRelease(hStoch);
      IndicatorRelease(hCci);
      IndicatorRelease(hMom);
      IndicatorRelease(hBands);
      IndicatorRelease(hMa20);
      IndicatorRelease(hMa50);
      IndicatorRelease(hMa200);

      int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
      string commonInd = StringFormat(
         "{\"rsi14\":%s,\"macd_main\":%s,\"macd_signal\":%s,\"adx14\":%s,\"plus_di\":%s,\"minus_di\":%s,"
         "\"atr14\":%s,\"stoch_k\":%s,\"stoch_d\":%s,\"cci14\":%s,\"momentum14\":%s,"
         "\"bb_upper\":%s,\"bb_lower\":%s,\"ema20\":%s,\"ema50\":%s,\"sma200\":%s}",
         DoubleToString(rsi, 2), DoubleToString(macdMain, 6), DoubleToString(macdSig, 6),
         DoubleToString(adx, 2), DoubleToString(plusDi, 2), DoubleToString(minusDi, 2),
         DoubleToString(atr, digits), DoubleToString(stochK, 2), DoubleToString(stochD, 2),
         DoubleToString(cci, 2), DoubleToString(mom, 4),
         DoubleToString(bandsUp, digits), DoubleToString(bandsLo, digits),
         DoubleToString(ma20, digits), DoubleToString(ma50, digits), DoubleToString(ma200, digits));

      double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
      double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
      long spreadPts = SymbolInfoInteger(symbol, SYMBOL_SPREAD);
      long stopLevel = SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);

      string account = StringFormat(
         "{\"balance\":%s,\"equity\":%s,\"free_margin\":%s,\"currency\":\"%s\"}",
         DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2),
         DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2),
         DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN_FREE), 2),
         AccountInfoString(ACCOUNT_CURRENCY));

      string strategyInd = StringLen(strategyIndicatorsJson) > 0 ? strategyIndicatorsJson : "{}";

      string json = StringFormat(
         "{\"symbol\":\"%s\",\"timeframe\":\"%s\",\"server_time\":\"%s\","
         "\"bid\":%s,\"ask\":%s,\"spread_points\":%d,\"point\":%s,\"digits\":%d,\"stop_level_points\":%d,"
         "\"account\":%s,\"ohlc\":%s,\"common_indicators\":%s,\"strategy_indicators\":%s,\"condition_note\":\"%s\"}",
         symbol, EnumToString(tf), TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS),
         DoubleToString(bid, digits), DoubleToString(ask, digits), (int)spreadPts,
         DoubleToString(point, digits), digits, (int)stopLevel,
         account, ohlc, commonInd, strategyInd, JsonEscape(conditionNote));

      return json;
     }
  };
//+------------------------------------------------------------------+
