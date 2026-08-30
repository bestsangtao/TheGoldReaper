// ============================================================================
// The Gold Reaper v4.6 - full dump reconstruction
// Dump: metatester64.DMP, restored from RAR part01 through part05
// Verified JIT base: 0x0000019AA50B0000
// Verified JIT size: 0x0004F000 (PAGE_EXECUTE_READ)
// Adjacent EA data: 0x0000019AA50FF000, size 0x00181000
// Fresh aligned scan found 68 native entry/prologue candidates.
//
// Baseline: V4.6 dump/JIT reconstruction, NOT the V4.5 reconstruction.
// V4.6-specific recovered behavior is retained (including V4.6 panel/version,
// BacktestSpeed runtime handling, HighestBalance/OnlyUp behavior, and NFP path).
// Logic/data were checked against the recovered dump. Final compile and
// differential Strategy Tester validation still require MetaTrader 5.
// ============================================================================

#property copyright  "Copyright 2026 - Pham Duy Linh"
#property link       "https://t.me/Khonglamdoicoan96"
#property version    "4.6"
#property description "- Fixed the www.worldtimeserver GMT fetch bug"
#property description "- HighestBalance/OnlyUp restored to original V4.6 dump behavior"
#property description "- NFP filter with MT5 Economic Calendar + hardcoded fallback"
#property description "- Added input to close trades at end of Friday session"
#property description "- Warns the exact missing allowed URL"
#property description "- Native MT5 position, order and deal handling"
#property description "- A few handy inputs (all default to the original behavior)"
#property description "Telegram: t.me/Khonglamdoicoan96"

#include <Trade\Trade.mqh>
CTrade trade;

//==================================================================
// Native MT5 execution/state layer.
// Strategy conditions and call order remain unchanged from V6; this layer
// reads MT5 positions, pending orders and deals through the native APIs and
// executes synchronously through CTrade.
//
// IMPORTANT: the EA runs multiple simultaneous strategies on one symbol,
// so the MT5 account must use HEDGING mode. Netting would merge positions
// and therefore cannot preserve the strategy's position-management model.
//==================================================================

enum NativeSelectMode
{
   NATIVE_SELECT_BY_POSITION=0,
   NATIVE_SELECT_BY_TICKET=1
};

enum NativeTradePool
{
   NATIVE_ACTIVE_POOL=0,
   NATIVE_HISTORY_POOL=1
};

//====================================================================
// Bien trang thai noi bo
//====================================================================
long g_native_lastTicket = -1;
// MT5 ticket/order/deal IDs are 64-bit. Khong ep ticket ve int.

uint g_native_lastRetcode=TRADE_RETCODE_DONE;

//====================================================================
// Convert the strategy's minute-based timeframe inputs to native MT5 enums.
// Existing PERIOD_xxx enum values pass through unchanged.
//====================================================================
ENUM_TIMEFRAMES NativeTimeframe(int minutes)
{
   switch(minutes)
   {
      case 0:     return PERIOD_CURRENT;
      case 1:     return PERIOD_M1;
      case 2:     return PERIOD_M2;
      case 3:     return PERIOD_M3;
      case 4:     return PERIOD_M4;
      case 5:     return PERIOD_M5;
      case 6:     return PERIOD_M6;
      case 10:    return PERIOD_M10;
      case 12:    return PERIOD_M12;
      case 15:    return PERIOD_M15;
      case 20:    return PERIOD_M20;
      case 30:    return PERIOD_M30;
      case 60:    return PERIOD_H1;
      case 120:   return PERIOD_H2;
      case 180:   return PERIOD_H3;
      case 240:   return PERIOD_H4;
      case 360:   return PERIOD_H6;
      case 480:   return PERIOD_H8;
      case 720:   return PERIOD_H12;
      case 1440:  return PERIOD_D1;
      case 10080: return PERIOD_W1;
      case 43200: return PERIOD_MN1;
      default:    return (ENUM_TIMEFRAMES)minutes; // da la PERIOD_xxx cua MQL5
   }
}

double NativeFreeMarginAfterOrder(string symbol,ENUM_ORDER_TYPE cmd,double volume)
{
   double margin=0.0;
   ENUM_ORDER_TYPE type=(cmd==ORDER_TYPE_BUY)?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
   double price=(cmd==ORDER_TYPE_BUY)?SymbolInfoDouble(symbol,SYMBOL_ASK):SymbolInfoDouble(symbol,SYMBOL_BID);
   if(!OrderCalcMargin(type,symbol,volume,price,margin))
      return AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   return AccountInfoDouble(ACCOUNT_MARGIN_FREE)-margin;
}

//====================================================================
// NativeSessionMarket: Market/session gate for BOTH live/demo and Strategy Tester.
//
// IMPORTANT:
//  - This is the SINGLE Market Close gate used before NativeSendOrder().
//  - Uses broker trade-session metadata, not OrderCheck().
//  - Uses TimeTradeServer() on live/demo so a stale last tick cannot make
//    a closed weekend/session look open.
//  - If session metadata is unavailable, fail CLOSED: no new order is sent.
//====================================================================
bool NativeSessionMarket(string symbol,datetime when=0)
{
   long trade_mode=SymbolInfoInteger(symbol,SYMBOL_TRADE_MODE);
   // Preserve the V6 rule: trading is allowed only in FULL symbol trade mode.
   if(trade_mode!=SYMBOL_TRADE_MODE_FULL)
      return false;

   if(when<=0)
   {
      if(MQLInfoInteger(MQL_TESTER)==1)
         when=TimeCurrent();
      else
         when=TimeTradeServer();

      if(when<=0)
         when=TimeCurrent();
   }

   if(when<=0)
      return false;

   MqlDateTime now_struct;
   TimeToStruct(when,now_struct);
   ENUM_DAY_OF_WEEK dow=(ENUM_DAY_OF_WEEK)now_struct.day_of_week;
   int now_seconds=now_struct.hour*3600 + now_struct.min*60 + now_struct.sec;

   datetime session_from=0;
   datetime session_to=0;
   for(uint session_index=0; session_index<64; session_index++)
   {
      if(!SymbolInfoSessionTrade(symbol,dow,session_index,session_from,session_to))
         break;

      MqlDateTime from_struct;
      MqlDateTime to_struct;
      TimeToStruct(session_from,from_struct);
      TimeToStruct(session_to,to_struct);
      int from_seconds=from_struct.hour*3600 + from_struct.min*60 + from_struct.sec;
      int to_seconds=to_struct.hour*3600 + to_struct.min*60 + to_struct.sec;

      // Some brokers encode a 24-hour session as 00:00 -> 00:00.
      if(from_seconds==to_seconds)
         return true;

      if(from_seconds<to_seconds)
      {
         if(now_seconds>=from_seconds && now_seconds<to_seconds)
            return true;
      }
      else
      {
         // Session crosses midnight.
         if(now_seconds>=from_seconds || now_seconds<to_seconds)
            return true;
      }
   }

   // No matching session means market closed. If the broker/tester does not
   // expose session metadata, fail closed instead of risking an unwanted order.
   return false;
}

//====================================================================
// Native MT5 date-part helpers based on TimeToStruct().
//====================================================================
int DateYear(datetime t)      { MqlDateTime s; TimeToStruct(t,s); return s.year; }
int DateMonth(datetime t)     { MqlDateTime s; TimeToStruct(t,s); return s.mon;  }
int DateDay(datetime t)       { MqlDateTime s; TimeToStruct(t,s); return s.day;  }
int DateHour(datetime t)      { MqlDateTime s; TimeToStruct(t,s); return s.hour; }
int DateMinute(datetime t)    { MqlDateTime s; TimeToStruct(t,s); return s.min;  }
int DateSecond(datetime t)   { MqlDateTime s; TimeToStruct(t,s); return s.sec;  }
int DateDayOfWeek(datetime t) { MqlDateTime s; TimeToStruct(t,s); return s.day_of_week; }
int DateDayOfYear(datetime t) { MqlDateTime s; TimeToStruct(t,s); return s.day_of_year;  }

// Current server-time date parts.
int CurrentYear()      { return DateYear(TimeCurrent());      }
int CurrentMonth()     { return DateMonth(TimeCurrent());     }
int CurrentDay()       { return DateDay(TimeCurrent());       }
int CurrentHour()      { return DateHour(TimeCurrent());      }
int CurrentMinute()    { return DateMinute(TimeCurrent());    }
int CurrentSecond()   { return DateSecond(TimeCurrent());   }
int CurrentDayOfWeek() { return DateDayOfWeek(TimeCurrent());  }

//====================================================================
// Native MT5 indicator handles with CopyBuffer value access.
//====================================================================
ENUM_APPLIED_PRICE NativeAppliedPrice(int p) { return (ENUM_APPLIED_PRICE)(p+1); }

struct NativeMAHandleEntry
{
   string symbol;
   ENUM_TIMEFRAMES timeframe;
   int period;
   int ma_shift;
   ENUM_MA_METHOD method;
   ENUM_APPLIED_PRICE applied_price;
   int handle;
};

struct NativeATRHandleEntry
{
   string symbol;
   ENUM_TIMEFRAMES timeframe;
   int period;
   int handle;
};

struct NativeFractalHandleEntry
{
   string symbol;
   ENUM_TIMEFRAMES timeframe;
   int handle;
};

NativeMAHandleEntry g_ma_handles[];
NativeATRHandleEntry g_atr_handles[];
NativeFractalHandleEntry g_fractal_handles[];

int NativeGetMAHandle(const string symbol,const ENUM_TIMEFRAMES timeframe,
                      const int period,const int ma_shift,
                      const ENUM_MA_METHOD method,
                      const ENUM_APPLIED_PRICE applied_price)
{
   int count=ArraySize(g_ma_handles);
   for(int i=0;i<count;i++)
   {
      if(g_ma_handles[i].symbol==symbol &&
         g_ma_handles[i].timeframe==timeframe &&
         g_ma_handles[i].period==period &&
         g_ma_handles[i].ma_shift==ma_shift &&
         g_ma_handles[i].method==method &&
         g_ma_handles[i].applied_price==applied_price)
         return g_ma_handles[i].handle;
   }

   int handle=iMA(symbol,timeframe,period,ma_shift,method,applied_price);
   if(handle==INVALID_HANDLE) return INVALID_HANDLE;

   ArrayResize(g_ma_handles,count+1);
   g_ma_handles[count].symbol=symbol;
   g_ma_handles[count].timeframe=timeframe;
   g_ma_handles[count].period=period;
   g_ma_handles[count].ma_shift=ma_shift;
   g_ma_handles[count].method=method;
   g_ma_handles[count].applied_price=applied_price;
   g_ma_handles[count].handle=handle;
   return handle;
}

int NativeGetATRHandle(const string symbol,const ENUM_TIMEFRAMES timeframe,
                       const int period)
{
   int count=ArraySize(g_atr_handles);
   for(int i=0;i<count;i++)
   {
      if(g_atr_handles[i].symbol==symbol &&
         g_atr_handles[i].timeframe==timeframe &&
         g_atr_handles[i].period==period)
         return g_atr_handles[i].handle;
   }

   int handle=iATR(symbol,timeframe,period);
   if(handle==INVALID_HANDLE) return INVALID_HANDLE;

   ArrayResize(g_atr_handles,count+1);
   g_atr_handles[count].symbol=symbol;
   g_atr_handles[count].timeframe=timeframe;
   g_atr_handles[count].period=period;
   g_atr_handles[count].handle=handle;
   return handle;
}

int NativeGetFractalHandle(const string symbol,const ENUM_TIMEFRAMES timeframe)
{
   int count=ArraySize(g_fractal_handles);
   for(int i=0;i<count;i++)
   {
      if(g_fractal_handles[i].symbol==symbol &&
         g_fractal_handles[i].timeframe==timeframe)
         return g_fractal_handles[i].handle;
   }

   int handle=iFractals(symbol,timeframe);
   if(handle==INVALID_HANDLE) return INVALID_HANDLE;

   ArrayResize(g_fractal_handles,count+1);
   g_fractal_handles[count].symbol=symbol;
   g_fractal_handles[count].timeframe=timeframe;
   g_fractal_handles[count].handle=handle;
   return handle;
}

void NativeReleaseIndicatorHandles()
{
   for(int i=0;i<ArraySize(g_ma_handles);i++)
      if(g_ma_handles[i].handle!=INVALID_HANDLE)
         IndicatorRelease(g_ma_handles[i].handle);
   for(int i=0;i<ArraySize(g_atr_handles);i++)
      if(g_atr_handles[i].handle!=INVALID_HANDLE)
         IndicatorRelease(g_atr_handles[i].handle);
   for(int i=0;i<ArraySize(g_fractal_handles);i++)
      if(g_fractal_handles[i].handle!=INVALID_HANDLE)
         IndicatorRelease(g_fractal_handles[i].handle);

   ArrayResize(g_ma_handles,0);
   ArrayResize(g_atr_handles,0);
   ArrayResize(g_fractal_handles,0);
}

double NativeMAValue(string symbol,int timeframe,int period,int ma_shift,int ma_method,int applied_price,int shift)
{
   int handle=NativeGetMAHandle(symbol,NativeTimeframe(timeframe),period,ma_shift,
                                (ENUM_MA_METHOD)ma_method,NativeAppliedPrice(applied_price));
   if(handle==INVALID_HANDLE) return 0.0;
   double buf[];
   ArraySetAsSeries(buf,true);
   if(CopyBuffer(handle,0,shift,1,buf)<=0) return 0.0;
   return buf[0];
}

double NativeFractalValue(string symbol,int timeframe,int mode,int shift)
{
   // The EA requests only shift=1 during OnInit.
   // A standard Bill Williams fractal needs two newer bars for confirmation,
   // therefore shift 0/1 cannot contain a confirmed fractal and is exactly 0.0.
   // Returning here avoids creating visual iFractals handles in MT5 Visual Tester.
   if(shift < 2) return 0.0;

   // Preserve the V6 result path for any unexpected call at shift>=2.
   int handle=NativeGetFractalHandle(symbol,NativeTimeframe(timeframe));
   if(handle==INVALID_HANDLE) return 0.0;
   int bufIndex=(mode==1)?0:1; // mode 1=upper buffer, mode 2=lower buffer
   double buf[];
   ArraySetAsSeries(buf,true);
   if(CopyBuffer(handle,bufIndex,shift,1,buf)<=0) return 0.0;
   return buf[0];
}

//====================================================================
// Native MT5 trade result retained for retry and diagnostics.
//====================================================================
uint NativeTradeRetcode() { return g_native_lastRetcode; }

//====================================================================
// Native CTrade execution layer with synchronous ResultRetcode validation.
//====================================================================
ENUM_ORDER_TYPE_FILLING NativeSelectFilling(string symbol)
{
   long mask=SymbolInfoInteger(symbol,SYMBOL_FILLING_MODE);
   if((mask&SYMBOL_FILLING_FOK)!=0)  return ORDER_FILLING_FOK;
   if((mask&SYMBOL_FILLING_IOC)!=0)  return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
}

//====================================================================
// Preserve the V6 Experts-tab trade messages. Logging does not alter trading.
//====================================================================
string NativeOrderTypeName(ENUM_ORDER_TYPE type)
{
   switch(type)
   {
      case ORDER_TYPE_BUY:        return "buy";
      case ORDER_TYPE_SELL:       return "sell";
      case ORDER_TYPE_BUY_LIMIT:  return "buy limit";
      case ORDER_TYPE_SELL_LIMIT: return "sell limit";
      case ORDER_TYPE_BUY_STOP:   return "buy stop";
      case ORDER_TYPE_SELL_STOP:  return "sell stop";
   }
   return "order";
}

void NativeConfigureMarketFilling(const string symbol)
{
   if(!trade.SetTypeFillingBySymbol(symbol))
      trade.SetTypeFilling(NativeSelectFilling(symbol));
}

//====================================================================
// Native MT5 order/position entry through CTrade::OrderOpen/PositionOpen.
//====================================================================
long NativeSendOrder(string symbol,ENUM_ORDER_TYPE cmd,double volume,double price,int slippage,
               double stoploss,double takeprofit,string comment="",int magic=0,
               datetime expiration=0,color arrow_color=clrNONE)
{
   ENUM_ORDER_TYPE type;
   switch(cmd)
   {
      case ORDER_TYPE_BUY:       type=ORDER_TYPE_BUY;        break;
      case ORDER_TYPE_SELL:      type=ORDER_TYPE_SELL;       break;
      case ORDER_TYPE_BUY_LIMIT:  type=ORDER_TYPE_BUY_LIMIT;  break;
      case ORDER_TYPE_SELL_LIMIT: type=ORDER_TYPE_SELL_LIMIT; break;
      case ORDER_TYPE_BUY_STOP:   type=ORDER_TYPE_BUY_STOP;   break;
      case ORDER_TYPE_SELL_STOP:  type=ORDER_TYPE_SELL_STOP;  break;
      default:
         g_native_lastRetcode=TRADE_RETCODE_INVALID;
         g_native_lastTicket=-1;
         return -1;
   }

   trade.SetExpertMagicNumber((ulong)magic);
   trade.SetDeviationInPoints((ulong)MathMax(slippage,0));

   bool accepted=false;
   double executionPrice=price;
   if(type==ORDER_TYPE_BUY || type==ORDER_TYPE_SELL)
   {
      NativeConfigureMarketFilling(symbol);
      executionPrice=(type==ORDER_TYPE_BUY)
                     ?SymbolInfoDouble(symbol,SYMBOL_ASK)
                     :SymbolInfoDouble(symbol,SYMBOL_BID);
      accepted=trade.PositionOpen(symbol,type,volume,executionPrice,
                                  stoploss,takeprofit,comment);
   }
   else
   {
      trade.SetTypeFilling(ORDER_FILLING_RETURN);
      ENUM_ORDER_TYPE_TIME timeType=(expiration>0)?ORDER_TIME_SPECIFIED:ORDER_TIME_GTC;
      accepted=trade.OrderOpen(symbol,type,volume,0.0,price,
                               stoploss,takeprofit,timeType,expiration,comment);
   }

   uint retcode=trade.ResultRetcode();
   if(!accepted && retcode==0) retcode=TRADE_RETCODE_ERROR;
   g_native_lastRetcode=retcode;
   if(accepted && (retcode==TRADE_RETCODE_DONE ||
                   retcode==TRADE_RETCODE_DONE_PARTIAL ||
                   retcode==TRADE_RETCODE_PLACED))
   {
      g_native_lastRetcode=retcode;
      ulong ticket=trade.ResultOrder();
      if(ticket==0) ticket=trade.ResultDeal();
      g_native_lastTicket=(long)ticket;
      PrintFormat("open #%I64d %s %.2f %s at %.5f sl: %.5f tp: %.5f ok",
                  g_native_lastTicket,NativeOrderTypeName(type),volume,
                  symbol,executionPrice,stoploss,takeprofit);
      NativeInvalidateHistoryCache();
      return g_native_lastTicket;
   }

   PrintFormat("failed open %s %.2f %s at %.5f sl: %.5f tp: %.5f [%s] (retcode=%u)",
               NativeOrderTypeName(type),volume,symbol,executionPrice,
               stoploss,takeprofit,trade.ResultRetcodeDescription(),retcode);
   g_native_lastTicket=-1;
   return -1;
}

bool NativeModifyTrade(long ticket,double price,double stoploss,double takeprofit,datetime expiration,color arrow_color=clrNONE)
{
   bool accepted=false;
   string symbol="";
   double logPrice=price;

   if(PositionSelectByTicket((ulong)ticket))
   {
      symbol=PositionGetString(POSITION_SYMBOL);
      logPrice=PositionGetDouble(POSITION_PRICE_OPEN);
      trade.SetExpertMagicNumber((ulong)PositionGetInteger(POSITION_MAGIC));
      accepted=trade.PositionModify((ulong)ticket,stoploss,takeprofit);
   }
   else if(OrderSelect((ulong)ticket))
   {
      symbol=OrderGetString(ORDER_SYMBOL);
      trade.SetExpertMagicNumber((ulong)OrderGetInteger(ORDER_MAGIC));
      ENUM_ORDER_TYPE_TIME timeType=(expiration>0)?ORDER_TIME_SPECIFIED:ORDER_TIME_GTC;
      accepted=trade.OrderModify((ulong)ticket,price,stoploss,takeprofit,
                                 timeType,expiration,0.0);
      logPrice=price;
   }
   else
   {
      g_native_lastRetcode=TRADE_RETCODE_INVALID_ORDER;
      return false;
   }

   uint retcode=trade.ResultRetcode();
   if(!accepted && retcode==0) retcode=TRADE_RETCODE_ERROR;
   g_native_lastRetcode=retcode;
   if(accepted && (retcode==TRADE_RETCODE_DONE || retcode==TRADE_RETCODE_DONE_PARTIAL))
   {
      g_native_lastRetcode=retcode;
      PrintFormat("modify #%I64d %s price: %.5f sl: %.5f tp: %.5f ok",
                  ticket,symbol,logPrice,stoploss,takeprofit);
      NativeInvalidateHistoryCache();
      return true;
   }

   PrintFormat("failed modify %s at %.5f sl: %.5f tp: %.5f [%s] (retcode=%u, ticket=%I64d)",
               symbol,logPrice,stoploss,takeprofit,
               trade.ResultRetcodeDescription(),retcode,ticket);
   return false;
}

bool NativeClosePosition(long ticket,double lots,double price,int slippage,color arrow_color=clrNONE)
{
   if(!PositionSelectByTicket((ulong)ticket))
   {
      g_native_lastRetcode=TRADE_RETCODE_INVALID_ORDER;
      return false;
   }

   string symbol=PositionGetString(POSITION_SYMBOL);
   double positionVolume=PositionGetDouble(POSITION_VOLUME);
   ENUM_POSITION_TYPE positionType=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   trade.SetExpertMagicNumber((ulong)PositionGetInteger(POSITION_MAGIC));
   double closeVolume=(lots>0.0 && lots<positionVolume)?lots:positionVolume;
   ulong deviation=(ulong)MathMax(slippage,0);
   trade.SetDeviationInPoints(deviation);
   NativeConfigureMarketFilling(symbol);

   bool accepted=(closeVolume>=positionVolume)
                 ?trade.PositionClose((ulong)ticket,deviation)
                 :trade.PositionClosePartial((ulong)ticket,closeVolume,deviation);

   uint retcode=trade.ResultRetcode();
   if(!accepted && retcode==0) retcode=TRADE_RETCODE_ERROR;
   g_native_lastRetcode=retcode;
   if(accepted && (retcode==TRADE_RETCODE_DONE || retcode==TRADE_RETCODE_DONE_PARTIAL))
   {
      g_native_lastRetcode=retcode;
      PrintFormat("close #%I64d %s %.2f %s at %.5f ok",ticket,
                  (positionType==POSITION_TYPE_BUY)?"buy":"sell",
                  closeVolume,symbol,trade.ResultPrice());
      NativeInvalidateHistoryCache();
      return true;
   }

   PrintFormat("failed close %s %.2f %s [%s] (retcode=%u, ticket=%I64d)",
               (positionType==POSITION_TYPE_BUY)?"buy":"sell",closeVolume,symbol,
               trade.ResultRetcodeDescription(),retcode,ticket);
   return false;
}

bool NativeDeletePending(long ticket,color arrow_color=clrNONE)
{
   string orderName="order";
   double orderVolume=0.0;
   double orderPrice=0.0;
   string symbol="";

   if(OrderSelect((ulong)ticket))
   {
      orderName=NativeOrderTypeName((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE));
      orderVolume=OrderGetDouble(ORDER_VOLUME_CURRENT);
      orderPrice=OrderGetDouble(ORDER_PRICE_OPEN);
      symbol=OrderGetString(ORDER_SYMBOL);
      trade.SetExpertMagicNumber((ulong)OrderGetInteger(ORDER_MAGIC));
   }

   bool accepted=trade.OrderDelete((ulong)ticket);
   uint retcode=trade.ResultRetcode();
   if(!accepted && retcode==0) retcode=TRADE_RETCODE_ERROR;
   g_native_lastRetcode=retcode;
   if(accepted && retcode==TRADE_RETCODE_DONE)
   {
      g_native_lastRetcode=retcode;
      PrintFormat("delete #%I64d %s %.2f %s at %.5f ok",
                  ticket,orderName,orderVolume,symbol,orderPrice);
      NativeInvalidateHistoryCache();
      return true;
   }

   PrintFormat("failed delete %s %.2f %s at %.5f [%s] (retcode=%u, ticket=%I64d)",
               orderName,orderVolume,symbol,orderPrice,
               trade.ResultRetcodeDescription(),retcode,ticket);
   return false;
}

//====================================================================
// Typed MT5 cursor used by the unchanged strategy scans.
enum NativeTradeKind
{
   NATIVE_TRADE_NONE=0,
   NATIVE_TRADE_POSITION=1,
   NATIVE_TRADE_PENDING=2,
   NATIVE_TRADE_CLOSED_DEAL=3
};

struct NativeTradeRecord
{
   NativeTradeKind kind;
   long     ticket;
   string   symbol;
   ENUM_ORDER_TYPE type;
   double   lots;
   double   openPrice;
   double   closePrice;
   double   sl;
   double   tp;
   datetime openTime;
   datetime closeTime;
   datetime expiration;
   double   profit;
   double   swap;
   double   commission;
   string   comment;
   int      magic;
};

class CNativeTradeView
{
private:
   NativeTradeRecord m_value;

public:
   bool Select(long index_or_ticket,NativeSelectMode select,
               NativeTradePool pool=NATIVE_ACTIVE_POOL);
   NativeTradeKind Kind();
   long Ticket();
   string SymbolName();
   ENUM_ORDER_TYPE OrderType();
   double Volume();
   double PriceOpen();
   double PriceClose();
   double StopLoss();
   double TakeProfit();
   datetime TimeOpen();
   datetime TimeClose();
   datetime Expiration();
   double Profit();
   double Swap();
   double Commission();
   string Comment();
   int Magic();
};

CNativeTradeView g_trade_view;

//--- danh sach cache cho pool=NATIVE_HISTORY_POOL (xay tu HistoryDealsTotal) ---
long     g_hist_ticket[];
string   g_hist_symbol[];
ENUM_ORDER_TYPE g_hist_type[];
double   g_hist_lots[];
double   g_hist_openPrice[];
double   g_hist_closePrice[];
datetime g_hist_openTime[];
datetime g_hist_closeTime[];
double   g_hist_profit[];
double   g_hist_swap[];
double   g_hist_commission[];
string   g_hist_comment[];
int      g_hist_magic[];
datetime g_hist_expiration[];
int      g_hist_count=0;
datetime g_hist_builtAt=0;

void NativeInvalidateHistoryCache()
{
   g_hist_builtAt=0;
}

void NativeBuildHistoryCache()
{
   // Rebuild at most once per server second, preserving the V6 cadence.
   if(TimeCurrent()==g_hist_builtAt) return;
   g_hist_builtAt=TimeCurrent();

   ArrayResize(g_hist_ticket,0);
   ArrayResize(g_hist_symbol,0);
   ArrayResize(g_hist_type,0);
   ArrayResize(g_hist_lots,0);
   ArrayResize(g_hist_openPrice,0);
   ArrayResize(g_hist_closePrice,0);
   ArrayResize(g_hist_openTime,0);
   ArrayResize(g_hist_closeTime,0);
   ArrayResize(g_hist_profit,0);
   ArrayResize(g_hist_swap,0);
   ArrayResize(g_hist_commission,0);
   ArrayResize(g_hist_comment,0);
   ArrayResize(g_hist_magic,0);
   ArrayResize(g_hist_expiration,0);
   g_hist_count=0;

   if(!HistorySelect(0,TimeCurrent())) return;
   int deals=HistoryDealsTotal();
   if(deals<=0) return;

   // Position-level opening metadata. Each closing deal remains an independent
   // closed-trade record, including partial closes.
   long     posIds[];
   double   posEntryVol[];
   double   posOpenPxVol[];
   datetime posOpenTime[];
   ENUM_ORDER_TYPE posType[];
   string   posSymbol[];
   int      posMagic[];
   string   posComment[];
   double   posEntryCommission[];
   int posCount=0;

   // Pass 1: collect opening metadata for every position id.
   for(int i=0;i<deals;i++)
   {
      ulong d=HistoryDealGetTicket(i);
      if(d==0) continue;
      ENUM_DEAL_TYPE dt=(ENUM_DEAL_TYPE)HistoryDealGetInteger(d,DEAL_TYPE);
      if(dt!=DEAL_TYPE_BUY && dt!=DEAL_TYPE_SELL) continue;
      ENUM_DEAL_ENTRY entry=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(d,DEAL_ENTRY);
      if(entry!=DEAL_ENTRY_IN) continue;
      long pid=HistoryDealGetInteger(d,DEAL_POSITION_ID);
      int pos=-1;
      for(int k=0;k<posCount;k++) if(posIds[k]==pid) { pos=k; break; }
      if(pos<0)
      {
         pos=posCount++;
         ArrayResize(posIds,posCount);
         ArrayResize(posEntryVol,posCount);
         ArrayResize(posOpenPxVol,posCount);
         ArrayResize(posOpenTime,posCount);
         ArrayResize(posType,posCount);
         ArrayResize(posSymbol,posCount);
         ArrayResize(posMagic,posCount);
         ArrayResize(posComment,posCount);
         ArrayResize(posEntryCommission,posCount);
         posIds[pos]=pid;
         posEntryVol[pos]=0.0;
         posOpenPxVol[pos]=0.0;
         posOpenTime[pos]=0;
         posType[pos]=(dt==DEAL_TYPE_BUY)?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
         posSymbol[pos]=HistoryDealGetString(d,DEAL_SYMBOL);
         posMagic[pos]=(int)HistoryDealGetInteger(d,DEAL_MAGIC);
         posComment[pos]=HistoryDealGetString(d,DEAL_COMMENT);
         posEntryCommission[pos]=0.0;
      }
      double v=HistoryDealGetDouble(d,DEAL_VOLUME);
      double px=HistoryDealGetDouble(d,DEAL_PRICE);
      datetime ot=(datetime)HistoryDealGetInteger(d,DEAL_TIME);
      posEntryVol[pos]+=v;
      posOpenPxVol[pos]+=px*v;
      if(posOpenTime[pos]==0 || ot<posOpenTime[pos]) posOpenTime[pos]=ot;
      posEntryCommission[pos]+=HistoryDealGetDouble(d,DEAL_COMMISSION);
   }

   // Pass 2: every OUT/OUT_BY deal is an independent closed-history item.
   for(int i=0;i<deals;i++)
   {
      ulong d=HistoryDealGetTicket(i);
      if(d==0) continue;
      ENUM_DEAL_TYPE dt=(ENUM_DEAL_TYPE)HistoryDealGetInteger(d,DEAL_TYPE);
      if(dt!=DEAL_TYPE_BUY && dt!=DEAL_TYPE_SELL) continue;
      ENUM_DEAL_ENTRY entry=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(d,DEAL_ENTRY);
      if(entry!=DEAL_ENTRY_OUT && entry!=DEAL_ENTRY_OUT_BY) continue;

      long pid=HistoryDealGetInteger(d,DEAL_POSITION_ID);
      int pos=-1;
      for(int k=0;k<posCount;k++) if(posIds[k]==pid) { pos=k; break; }

      int n=g_hist_count+1;
      ArrayResize(g_hist_ticket,n);
      ArrayResize(g_hist_symbol,n);
      ArrayResize(g_hist_type,n);
      ArrayResize(g_hist_lots,n);
      ArrayResize(g_hist_openPrice,n);
      ArrayResize(g_hist_closePrice,n);
      ArrayResize(g_hist_openTime,n);
      ArrayResize(g_hist_closeTime,n);
      ArrayResize(g_hist_profit,n);
      ArrayResize(g_hist_swap,n);
      ArrayResize(g_hist_commission,n);
      ArrayResize(g_hist_comment,n);
      ArrayResize(g_hist_magic,n);
      ArrayResize(g_hist_expiration,n);

      double closeVol=HistoryDealGetDouble(d,DEAL_VOLUME);
      string sym=HistoryDealGetString(d,DEAL_SYMBOL);
      int magic=(int)HistoryDealGetInteger(d,DEAL_MAGIC);
      string comment=HistoryDealGetString(d,DEAL_COMMENT);
      ENUM_ORDER_TYPE originalType=(dt==DEAL_TYPE_SELL)?ORDER_TYPE_BUY:ORDER_TYPE_SELL; // fallback: close deal is opposite side
      double openPrice=0.0;
      datetime openTime=0;
      double entryCommissionShare=0.0;
      if(pos>=0)
      {
         if(posSymbol[pos]!="") sym=posSymbol[pos];
         if(posMagic[pos]!=0) magic=posMagic[pos];
         if(posComment[pos]!="") comment=posComment[pos];
         originalType=posType[pos];
         openTime=posOpenTime[pos];
         if(posEntryVol[pos]>0.0)
         {
            openPrice=posOpenPxVol[pos]/posEntryVol[pos];
            entryCommissionShare=posEntryCommission[pos]*(closeVol/posEntryVol[pos]);
         }
      }

      int h=g_hist_count;
      g_hist_ticket[h]=(long)d; // unique close-deal ticket; preserves partial-close records
      g_hist_symbol[h]=sym;
      g_hist_type[h]=originalType;
      g_hist_lots[h]=closeVol;
      g_hist_openPrice[h]=openPrice;
      g_hist_closePrice[h]=HistoryDealGetDouble(d,DEAL_PRICE);
      g_hist_openTime[h]=openTime;
      g_hist_closeTime[h]=(datetime)HistoryDealGetInteger(d,DEAL_TIME);
      g_hist_profit[h]=HistoryDealGetDouble(d,DEAL_PROFIT);
      g_hist_swap[h]=HistoryDealGetDouble(d,DEAL_SWAP);
      g_hist_commission[h]=HistoryDealGetDouble(d,DEAL_COMMISSION)+entryCommissionShare;
      g_hist_comment[h]=comment;
      g_hist_magic[h]=magic;
      g_hist_expiration[h]=0;
      g_hist_count=n;
   }

   // Oldest closed record first. Tie-break by deal ticket for deterministic order.
   for(int a=0;a<g_hist_count;a++)
   for(int b=a+1;b<g_hist_count;b++)
   {
      if(g_hist_closeTime[b]<g_hist_closeTime[a] ||
         (g_hist_closeTime[b]==g_hist_closeTime[a] && g_hist_ticket[b]<g_hist_ticket[a]))
      {
         long lt; string ss; int it; double dd; datetime dtt; ENUM_ORDER_TYPE orderType;
         lt=g_hist_ticket[a]; g_hist_ticket[a]=g_hist_ticket[b]; g_hist_ticket[b]=lt;
         ss=g_hist_symbol[a]; g_hist_symbol[a]=g_hist_symbol[b]; g_hist_symbol[b]=ss;
         orderType=g_hist_type[a]; g_hist_type[a]=g_hist_type[b]; g_hist_type[b]=orderType;
         dd=g_hist_lots[a]; g_hist_lots[a]=g_hist_lots[b]; g_hist_lots[b]=dd;
         dd=g_hist_openPrice[a]; g_hist_openPrice[a]=g_hist_openPrice[b]; g_hist_openPrice[b]=dd;
         dd=g_hist_closePrice[a]; g_hist_closePrice[a]=g_hist_closePrice[b]; g_hist_closePrice[b]=dd;
         dtt=g_hist_openTime[a]; g_hist_openTime[a]=g_hist_openTime[b]; g_hist_openTime[b]=dtt;
         dtt=g_hist_closeTime[a]; g_hist_closeTime[a]=g_hist_closeTime[b]; g_hist_closeTime[b]=dtt;
         dd=g_hist_profit[a]; g_hist_profit[a]=g_hist_profit[b]; g_hist_profit[b]=dd;
         dd=g_hist_swap[a]; g_hist_swap[a]=g_hist_swap[b]; g_hist_swap[b]=dd;
         dd=g_hist_commission[a]; g_hist_commission[a]=g_hist_commission[b]; g_hist_commission[b]=dd;
         ss=g_hist_comment[a]; g_hist_comment[a]=g_hist_comment[b]; g_hist_comment[b]=ss;
         it=g_hist_magic[a]; g_hist_magic[a]=g_hist_magic[b]; g_hist_magic[b]=it;
         dtt=g_hist_expiration[a]; g_hist_expiration[a]=g_hist_expiration[b]; g_hist_expiration[b]=dtt;
      }
   }
}

//====================================================================
// Strategy-wide active count: native positions plus native pending orders.
//====================================================================
int NativeTradesTotal()
{
   return PositionsTotal()+OrdersTotal();
}

int NativeHistoryTotal()
{
   NativeBuildHistoryCache();
   return g_hist_count;
}

//====================================================================
// Select from the strategy's native active or closed-trade view.
//====================================================================
bool CNativeTradeView::Select(long index_or_ticket,NativeSelectMode select,
                              NativeTradePool pool)
{
   m_value.kind=NATIVE_TRADE_NONE;
   if(select==NATIVE_SELECT_BY_TICKET)
   {
      long ticket=(long)index_or_ticket;
      if(PositionSelectByTicket((ulong)ticket))
      {
         m_value.kind=NATIVE_TRADE_POSITION;
         m_value.ticket=ticket;
         m_value.symbol=PositionGetString(POSITION_SYMBOL);
         m_value.type=(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)
                      ?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
         m_value.lots=PositionGetDouble(POSITION_VOLUME);
         m_value.openPrice=PositionGetDouble(POSITION_PRICE_OPEN);
         m_value.closePrice=PositionGetDouble(POSITION_PRICE_CURRENT);
         m_value.sl=PositionGetDouble(POSITION_SL);
         m_value.tp=PositionGetDouble(POSITION_TP);
         m_value.openTime=(datetime)PositionGetInteger(POSITION_TIME);
         m_value.closeTime=0;
         m_value.expiration=0;
         m_value.profit=PositionGetDouble(POSITION_PROFIT);
         m_value.swap=PositionGetDouble(POSITION_SWAP);
         m_value.commission=0.0;
         m_value.comment=PositionGetString(POSITION_COMMENT);
         m_value.magic=(int)PositionGetInteger(POSITION_MAGIC);
         return true;
      }
      if(OrderSelect((ulong)ticket))
      {
         m_value.kind=NATIVE_TRADE_PENDING;
         m_value.ticket=ticket;
         m_value.symbol=OrderGetString(ORDER_SYMBOL);
         m_value.type=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
         m_value.lots=OrderGetDouble(ORDER_VOLUME_CURRENT);
         m_value.openPrice=OrderGetDouble(ORDER_PRICE_OPEN);
         m_value.closePrice=0.0;
         m_value.sl=OrderGetDouble(ORDER_SL);
         m_value.tp=OrderGetDouble(ORDER_TP);
         m_value.openTime=(datetime)OrderGetInteger(ORDER_TIME_SETUP);
         m_value.closeTime=0;
         m_value.expiration=(datetime)OrderGetInteger(ORDER_TIME_EXPIRATION);
         m_value.profit=0.0;
         m_value.swap=0.0;
         m_value.commission=0.0;
         m_value.comment=OrderGetString(ORDER_COMMENT);
         m_value.magic=(int)OrderGetInteger(ORDER_MAGIC);
         return true;
      }
      NativeBuildHistoryCache();
      for(int i=0;i<g_hist_count;i++)
      {
         if(g_hist_ticket[i]==ticket)
         {
            m_value.kind=NATIVE_TRADE_CLOSED_DEAL;
            m_value.ticket=g_hist_ticket[i];
            m_value.symbol=g_hist_symbol[i];
            m_value.type=g_hist_type[i];
            m_value.lots=g_hist_lots[i];
            m_value.openPrice=g_hist_openPrice[i];
            m_value.closePrice=g_hist_closePrice[i];
            m_value.sl=0.0;
            m_value.tp=0.0;
            m_value.openTime=g_hist_openTime[i];
            m_value.closeTime=g_hist_closeTime[i];
            m_value.expiration=0;
            m_value.profit=g_hist_profit[i];
            m_value.swap=g_hist_swap[i];
            m_value.commission=g_hist_commission[i];
            m_value.comment=g_hist_comment[i];
            m_value.magic=g_hist_magic[i];
            return true;
         }
      }
      return false;
   }

   // NATIVE_SELECT_BY_POSITION
   if(pool==NATIVE_HISTORY_POOL)
   {
      NativeBuildHistoryCache();
      if(index_or_ticket<0 || index_or_ticket>=g_hist_count) return false;
      int i=(int)index_or_ticket; // da kiem tra nam trong [0, g_hist_count)
      m_value.kind=NATIVE_TRADE_CLOSED_DEAL;
      m_value.ticket=g_hist_ticket[i];
      m_value.symbol=g_hist_symbol[i];
      m_value.type=g_hist_type[i];
      m_value.lots=g_hist_lots[i];
      m_value.openPrice=g_hist_openPrice[i];
      m_value.closePrice=g_hist_closePrice[i];
      m_value.sl=0.0;
      m_value.tp=0.0;
      m_value.openTime=g_hist_openTime[i];
      m_value.closeTime=g_hist_closeTime[i];
      m_value.expiration=0;
      m_value.profit=g_hist_profit[i];
      m_value.swap=g_hist_swap[i];
      m_value.commission=g_hist_commission[i];
      m_value.comment=g_hist_comment[i];
      m_value.magic=g_hist_magic[i];
      return true;
   }

   // pool==NATIVE_ACTIVE_POOL: vi the dang mo (index 0..PositionsTotal()-1) roi
   // toi lenh cho dang mo (index PositionsTotal()..total-1)
   int posTotal=PositionsTotal();
   if(index_or_ticket>=0 && index_or_ticket<posTotal)
   {
      int posIdx=(int)index_or_ticket; // da kiem tra nam trong [0, posTotal)
      ulong ticket=PositionGetTicket(posIdx);
      if(ticket==0) return false;
      m_value.kind=NATIVE_TRADE_POSITION;
      m_value.ticket=(long)ticket;
      m_value.symbol=PositionGetString(POSITION_SYMBOL);
      m_value.type=(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)
                   ?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
      m_value.lots=PositionGetDouble(POSITION_VOLUME);
      m_value.openPrice=PositionGetDouble(POSITION_PRICE_OPEN);
      m_value.closePrice=PositionGetDouble(POSITION_PRICE_CURRENT);
      m_value.sl=PositionGetDouble(POSITION_SL);
      m_value.tp=PositionGetDouble(POSITION_TP);
      m_value.openTime=(datetime)PositionGetInteger(POSITION_TIME);
      m_value.closeTime=0;
      m_value.expiration=0;
      m_value.profit=PositionGetDouble(POSITION_PROFIT);
      m_value.swap=PositionGetDouble(POSITION_SWAP);
      m_value.commission=0.0;
      m_value.comment=PositionGetString(POSITION_COMMENT);
      m_value.magic=(int)PositionGetInteger(POSITION_MAGIC);
      return true;
   }
   long ordIdx64=index_or_ticket-posTotal;
   int ordTotal=OrdersTotal();
   if(ordIdx64>=0 && ordIdx64<ordTotal)
   {
      int ordIdx=(int)ordIdx64; // da kiem tra nam trong [0, ordTotal)
      ulong ticket=OrderGetTicket(ordIdx);
      if(ticket==0) return false;
      m_value.kind=NATIVE_TRADE_PENDING;
      m_value.ticket=(long)ticket;
      m_value.symbol=OrderGetString(ORDER_SYMBOL);
      m_value.type=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      m_value.lots=OrderGetDouble(ORDER_VOLUME_CURRENT);
      m_value.openPrice=OrderGetDouble(ORDER_PRICE_OPEN);
      m_value.closePrice=0.0;
      m_value.sl=OrderGetDouble(ORDER_SL);
      m_value.tp=OrderGetDouble(ORDER_TP);
      m_value.openTime=(datetime)OrderGetInteger(ORDER_TIME_SETUP);
      m_value.closeTime=0;
      m_value.expiration=(datetime)OrderGetInteger(ORDER_TIME_EXPIRATION);
      m_value.profit=0.0;
      m_value.swap=0.0;
      m_value.commission=0.0;
      m_value.comment=OrderGetString(ORDER_COMMENT);
      m_value.magic=(int)OrderGetInteger(ORDER_MAGIC);
      return true;
   }
   return false;
}

//====================================================================
// Typed access to the current MT5 record.
//====================================================================
NativeTradeKind CNativeTradeView::Kind() { return m_value.kind; }
long CNativeTradeView::Ticket()          { return m_value.ticket; }
string CNativeTradeView::SymbolName()    { return m_value.symbol; }
ENUM_ORDER_TYPE CNativeTradeView::OrderType(){ return m_value.type; }
double CNativeTradeView::Volume()        { return m_value.lots; }
double CNativeTradeView::PriceOpen()     { return m_value.openPrice; }
double CNativeTradeView::PriceClose()    { return m_value.closePrice; }
double CNativeTradeView::StopLoss()      { return m_value.sl; }
double CNativeTradeView::TakeProfit()    { return m_value.tp; }
datetime CNativeTradeView::TimeOpen()    { return m_value.openTime; }
datetime CNativeTradeView::TimeClose()   { return m_value.closeTime; }
datetime CNativeTradeView::Expiration()  { return m_value.expiration; }
double CNativeTradeView::Profit()        { return m_value.profit; }
double CNativeTradeView::Swap()          { return m_value.swap; }
double CNativeTradeView::Commission()    { return m_value.commission; }
string CNativeTradeView::Comment()       { return m_value.comment; }
int CNativeTradeView::Magic()            { return m_value.magic; }

  enum BacktestSpeedOptions      {speed_normal = 1,//normal
                   speed_fast = 2,//fast
                   speed_super = 3//ultra fast
                     };
  enum enum_TradeFrequency      {Extreme_cons_Frequency = 0,//extreme conservative
                   Conservative_Frequency = 1,//conservative
                   Moderate_Frequency = 2,//moderate
                   Intens_Frequency = 3,//Intense
                   Extreme_Frequency = 4,//Extreme (high risk!)
                   Auto_Frequency = 5,//Auto (based on balance and risk)
                   Manual_Strategy_Selection = 6//Manual strategy selection
                     };
  enum e_SlippageControlMode      {SCT_1 = 1,SCT_2 = 2  };
  enum FakeoutFilters      {Filter_Off = 0,//OFF
                   Filter_Low = 1,//Low
                   Filter_Medium = 2,//Medium
                   Filter_High = 3//High
                     };
  enum e_VirtualStopMode      {VSL_OFF = 1,VSL_BASIC = 2,VSL_ADV = 3  };
  enum Select_Entry_Strategy      {Strategy_ONE = 1,Strategy_TWO = 2  };
  enum e_TimeFrame_St_ONE      {ST1_M1 = 1,ST1_M5 = 5,ST1_M15 = 15,ST1_M30 = 30,ST1_H1 = 60,ST1_H4 = 240,ST1_Daily = 1440,ST1_Chart = 0  };
  enum e_TimeFrame_Entry_Timing      {Entry_T_Tick = 0,Entry_T_M1 = 1,Entry_T_M5 = 5,Entry_T_M15 = 15,Entry_T_M30 = 30,Entry_T_H1 = 60,Entry_T_H4 = 240  };
  enum e_UseOfCompound      {no_compound = 0,one_trade = 1,Multi_trades = 2  };
  enum e_MonitorTradesFilter      {MT_all = 0,MT_PairOfChart = 1  };
  enum e_TimeFrame_Exit_Timing      {ET_Tick = 0,ET_M1 = 1,ET_M5 = 5,ET_M15 = 15,ET_M30 = 30,ET_H1 = 60  };
  enum e_Exit_HL_trailingSL_timeframe      {HLT_Chart = 0,HLT_M1 = 1,HLT_M5 = 5,HLT_M15 = 15,HLT_M30 = 30,HLT_H1 = 60,HLT_H4 = 240,HLT_D1 = 1440  };
  enum ST1_e_MagicTrail_Mode      {ST1_MT_M_O = 0,ST1_MT_M_F = 1,ST1_MT_M_B = 2  };
  enum e_Risk      {Manual_Lotsize = 0,//use StartLots
                   MaxHistoricalDD = 1234,//Max Allowed Total Drawdown
                   MaxRiskStrat = 3//Max Risk Per Strategy
                     };
  enum Performance_options      {NormalizedProfit = 2,RealProfit = 1  };
  enum RankingOptions      {ranking_profit = 1,ranking_pertrade = 2  };
  enum Reduction_choices      {Red_10 = 10,Red_20 = 20,Red_30 = 30,Red_40 = 40,Red_50 = 50,Red_60 = 60,Red_70 = 70,Red_80 = 80,Red_90 = 90  };
  enum e_factortype      {factor_type_1 = 1,factor_type_2 = 2,factor_type_3 = 3  };
  enum e_TimeSource      {TZ_GMT = 0,TZ_PC = 1,TZ_Broker = 2  };


//------------------
input string lijntje="============================================================="  ;   //- - -
input bool UseVariableValues=true  ;   
input bool AdjustLotsizeToVariableValues=true  ;   
input bool ShowInfoPanel=true  ;   
input bool UpdateInfoTesting=false ;    //update infopanel during testing
input double InfoPanelSizeAdjust=1  ;    //Adjustment for Infopanel size
input int   SetFontSize=0  ;
input string BacktestSpeed_string="------------------------------ Backtest Speed settings ------------------------------"  ;
input BacktestSpeedOptions BacktestSpeed=speed_normal  ;
input string spreadfilter="------------------------------ settings ------------------------------"  ;   //- - -
input bool AllowBuyTrades=true  ;    //Allow Buy Trades
input bool AllowSellTrades=true  ;    //Allow Sell Trades
input  enum_TradeFrequency  TradeFrequency=Auto_Frequency  ;   
input double MaxSpread=500  ;    //Maximum allowed spread
input bool UseHL_TrailingSL=true  ;   
input int   FridayStopHour=25  ;    //Friday stop hour (brokertime; close all trades)
input bool FridayClosePending=true  ;
input bool FridayCloseOpen=true  ;
input bool setSL_TP_After_Entry=false ;   
input bool Virtual_expiration=false  ;    //Use Virtual Expiration
input double Randomization=0  ;    //Randomization (entries and exit) in pips
input  FakeoutFilters  FakeOutFilter=2  ;    //Fake Breakout Filter
input int   ST1_MagicNumber=8000  ;    //BaseMagicnumber
input string ST1_Comment="The Gold Reaper"  ;   //Comment for trades
input bool RemoveCommentSuffix=false ;   
input string NFP_FILTER="----------------------- NFP Filter -----------------------"  ;  
input bool EnableNFP_Filter=true  ;
input bool UseMQL5Calendar=true  ;
input bool AutoGMT=true  ;
input int   Broker_GMT_OFFSET_Winter=2  ;    //GMT_OFFSET_Winter (AutoGMT=false or backtesting)
input int   Broker_GMT_OFFSET_Summer=3  ;    //MT_OFFSET_Summer (AutoGMT=false or backtesting)
input bool NFP_CloseOpenTrades=true  ;   
input bool NFP_ClosePendingOrders=true  ;   
input int   NFP_MinutesBefore=100  ;   
input int   NFP_MinutesAfter=60  ;   
input string propfirmsettings="----------------------- Propfirm unique trades settings -----------------------"  ;   //- - -
input double AdjustEntry=0  ;   
input double AdjustSL=0  ;   
input double AdjustTP=0  ;   
input double AdjustTrailSL=0  ;   
input double AdjustTrailTP=0  ;   
input double AdjustBreakEven=0  ;   
input string LotSizeSettings="----------------------- LotSize Settings -----------------------"  ;   //- - -
input double ManualBalance=0.0  ;    //manually set balance to use (if > 0)
input  e_Risk  Risk=1234  ;    //Lotsize Calculation method
input double StartLots=0.01  ;   
double g_startLots_rw=0.0;
input double MaxAllowedDD=30  ;    //Max Allowed TOTAL Drawdown
input bool UseWeightedLots=true  ;    //Weighted Lotsize
input double MaxRiskPerStrategy_=1  ;    //Max Risk Per Strat
input double PropFirmMaxDailyDD=0  ;    //Set Max DAILY Drawdown (Prop Firms)
input bool OnlyUp=true  ;   
input bool ResetHighestBalance=false ;
input bool CheckMargin=true  ;    //check for free margin before setting trades
input bool UseEquity=false ;    //Use Equity Instead of Balance
input string ManualStratSelect="------------------------- Manual Strategy Selection -------------------------"  ;   //- - -
input string ManStratWarn="!! DO NOT RUN MANUAL STRATEGIES WHILE USING \'MAX ALLOWED TOTAL DD\' OPTION !! "  ;   //- - -
input bool RunStrat1=true  ;    //Run Strategy 1 (low risk)
input bool RunStrat2=true  ;    //Run Strategy 2 (low risk)
input bool RunStrat3=true  ;    //Run Strategy 3 (low risk)
input bool RunStrat4=true  ;    //Run Strategy 4 (med risk)
input bool RunStrat5=true  ;    //Run Strategy 5 (med risk)
input bool RunStrat6=true  ;    //Run Strategy 6 (med risk)
input bool RunStrat7=true  ;    //Run Strategy 7 (med risk)
input bool RunStrat8=true  ;    //Run Strategy 8 (high risk)
input bool RunStrat9=true  ;    //Run Strategy 9 (high risk)
  double    总_1_do_0 = 0.0;
  double    总_2_do_8 = 0.0;
  int       总_3_in_10 = 30;
  int       总_4_in_14 = (int)PERIOD_D1;
  int       总_5_in_18 = 0;
  double    总_6_do_1C_ko[];
  double    总_7_do_50 = 0.0;
  double    总_8_do_58 = 0.0;
  double    总_9_do_60 = 0.0;
  bool      总_10_bo_68 = false;
  int       总_11_in_6C = 3;
  int       总_12_in_70 = 2;
  bool      总_13_bo_74 = false;
  bool      总_14_bo_75 = false;
  int       总_15_in_78 = 0;
  string    总_16_st_80 = "------------------------------ trading filters ------------------------------";
  bool      总_17_bo_8C = false;
  string    总_18_st_90 = "EURUSD;GBPUSD;USDJPY;AUDJPY;AUDUSD;EURAUD;EURCAD;EURGBP;EURJPY;GBPJPY;USDCAD;USDCHF;";
  int       总_19_in_9C = 5;
  bool      总_20_bo_A0 = true;
  bool      总_21_bo_A1 = false;
  bool      总_22_bo_A2 = false;
  bool      总_23_bo_A3 = true;
  bool      总_24_bo_A4 = false;
  bool      总_25_bo_A5 = false;
  bool      总_26_bo_A6 = true;
  bool      总_27_bo_A7 = false;
  bool      总_28_bo_A8 = false;
  bool      总_29_bo_A9 = false;
  bool      总_30_bo_AA = false;
  bool      总_31_bo_AB = false;
  bool      总_32_bo_AC = false;
  bool      总_33_bo_AD = false;
  bool      总_34_bo_AE = false;
  bool      总_35_bo_AF = true;
  int       总_36_in_B0 = 2;
  double    总_37_do_B8 = 0.0;
  double    总_38_do_C0 = 5000.0;
  int       总_39_in_C8 = 1;
  double    总_40_do_D0 = 40.0;
  double    总_41_do_D8 = 10.0;
  double    总_42_do_E0 = 30.0;
  bool      总_43_bo_E8 = false; // v106: marketplace trace uses actual fill as trailing-reference threshold
  string    总_44_st_F0 = "------------------------------ time filters ------------------------------";
  bool      总_45_bo_FC = false;
  bool      总_46_bo_FD = false;
  bool      总_47_bo_FE = false;
  int       总_48_in_100 = 14;
  int       总_49_in_104 = 17;
  string    总_50_st_108 = "------------------------------ other filters ------------------------------";
  int       总_51_in_114 = 1;
  int       总_52_in_118 = 1;
  bool      总_53_bo_11C = false;
  int       总_54_in_120 = 5;
  bool      总_55_bo_124 = false;
  int       总_56_in_128 = 15;
  bool      总_57_bo_12C = false;
  int       总_58_in_130 = 30;
  bool      总_59_bo_134 = false;
  int       总_60_in_138 = 60;
  bool      总_61_bo_13C = false;
  bool      总_62_bo_13D = false;
  int       总_63_in_140 = 1;
  double    总_64_do_148 = 0.0;
  int       总_65_in_150 = 99;
  int       总_66_in_154 = 5;
  bool      总_67_bo_158 = false;
  int       总_68_in_15C = 5;
  int       总_69_in_160 = 1;
  string    总_70_st_168 = "------------------------------ Trade Entry management ------------------------------";
  int       总_71_in_174 = 0;
  int       总_72_in_178 = 60;
  int       总_73_in_17C = 10;
  int       总_74_in_180 = 3;
  bool      总_75_bo_184 = false;
  bool      总_76_bo_185 = false;
  int       总_77_in_188 = 120;
  int       总_78_in_18C = 0;
  int       总_79_in_190 = 0;
  double    总_80_do_198 = 30.0;
  double    总_81_do_1A0 = 0.0;
  double    总_82_do_1A8 = 25.0;
  double    总_83_do_1B0 = 0.5;
  double    总_84_do_1B8 = 0.0;
  double    总_85_do_1C0 = 0.0;
  int       总_86_in_1C8 = 1;
  int       总_87_in_1CC = 99;
  double    总_88_do_1D0 = 1.0;
  int       总_89_in_1D8 = 24;
  double    总_90_do_1E0 = 3.0;
  int       总_91_in_1E8 = 0;
  int       总_92_in_1EC = 100;
  int       总_93_in_1F0 = 0;
  string    总_94_st_1F8 = "------------------------------ Strategy 2 - Manual Trade settings ------------------------------";
  int       总_95_in_204 = 1;
  int       总_96_in_208 = 1991199118;
  string    总_97_st_210 = "";
  string    总_98_st_220 = "------------------------------ Trade Exit management ------------------------------";
  int       总_99_in_22C = 0;
  double    总_100_do_230 = 20.0;
  double    总_101_do_238 = 100.0;
  string    总_102_st_240 = "------------------------------ Trailing SL settings ------------------------------";
  double    总_103_do_250 = 10.0;
  double    总_104_do_258 = 10.0;
  double    总_105_do_260 = 100.0;
  double    总_106_do_268 = 0.1;
  double    总_107_do_270 = 0.0;
  double    总_108_do_278 = 0.0;
  double    总_109_do_280 = 0.0;
  double    总_110_do_288 = 0.0;
  double    总_111_do_290 = 0.0;
  string    总_112_st_298 = "------------------------------ Break-even SL management ------------------------------";
  double    总_113_do_2A8 = 0.0;
  double    总_114_do_2B0 = 0.0;
  string    总_115_st_2B8 = "------------------------------ HIGH/LOW Trailing SL settings ------------------------------";
  bool      总_116_bo_2C4 = false;
  int       总_117_in_2C8 = 0;
  int       总_118_in_2CC = 0;
  int       总_119_in_2D0 = 0;
  int       总_120_in_2D4 = 0;
  int       总_121_in_2D8 = 0;
  int       总_122_in_2DC = 0;
  double    总_123_do_2E0 = 2.0;
  string    总_124_st_2E8 = "------------------------------ recovery Trailing SL based on time ------------------------------";
  double    总_125_do_2F8 = 0.0;
  double    总_126_do_300 = 0.0;
  string    总_127_st_308 = "------------------------------ MagicTrail SL settings ------------------------------";
  int       总_128_in_314 = 0;
  double    总_129_do_318 = 0.1;
  int       总_130_in_320 = 1;
  double    总_131_do_328 = 0.1;
  double    总_132_do_330 = 1.0;
  int       总_133_in_338 = 0;
  double    总_134_do_340 = 0.0;
  bool      总_135_bo_348 = false;
  bool      总_136_bo_349 = false;
  int       总_137_in_34C = 2024;
  datetime  总_138_da_384_si13[13];
  bool      总_139_bo_3EC = false;
  double    总_140_do_3F0 = 5.0;
  double    总_141_do_3F8 = 99.0;
  int       总_142_in_400 = 999;
  int       总_143_in_404 = 9999;
  int       总_144_in_408 = 99999;
  int       总_145_in_40C = 600;
  double    总_146_do_410 = 1.0;
  double    总_147_do_418 = 10.0;
  double    总_148_do_420 = 2.0;
  string    总_149_st_428 = "==== Performance numbers overview ====";
  bool      总_150_bo_434 = true;
  int       总_151_in_438 = 1;
  int       总_152_in_43C = 1;
  int       总_153_in_440 = 90;
  int       总_154_in_444 = 30;
  int       总_155_in_448 = 10;
  int       总_156_in_44C = 50;
  bool      总_157_bo_450 = true;
  string    总_158_st_458 = "------------------------------ zone_recovery_settings ------------------------------";
  bool      总_159_bo_464 = false;
  double    总_160_do_468 = 50.0;
  double    总_161_do_470 = 10.0;
  double    总_162_do_478 = 5.0;
  double    总_163_do_480 = 0.0;
  int       总_164_in_488 = 1;
  double    总_165_do_490 = 2.0;
  int       总_166_in_498 = 999;
  double    总_167_do_4A0 = 100.0;
  int       总_168_in_4A8 = 900010;
  int       总_169_in_4AC = 900011;
  string    总_170_st_4B0 = "------------------------- Trading hours ST1 -------------------------";
  bool      总_171_bo_4BC = false;
  int       总_172_in_4C0 = 2;
  bool      总_173_bo_4C4 = false;
  int       总_174_in_4C8 = 0;
  int       总_175_in_4CC = 24;
  int       总_176_in_4D0 = 0;
  int       总_177_in_4D4 = 24;
  int       总_178_in_4D8 = 0;
  int       总_179_in_4DC = 24;
  int       总_180_in_4E0 = 0;
  int       总_181_in_4E4 = 24;
  int       总_182_in_4E8 = 0;
  int       总_183_in_4EC = 24;
  int       总_184_in_4F0 = 0;
  int       总_185_in_4F4 = 24;
  string    总_186_st_4F8 = "------------------------- use for backtesting only! -------------------------";
  int       总_187_in_504 = 0;
  double    总_188_do_508 = 0.0;
  double    总_189_do_510 = 0.0;
  int       总_190_in_518 = 0;
  double    总_191_do_520 = 0.0;
  int       总_192_in_528 = 0;
  int       总_193_in_52C = 0;
  bool      总_194_bo_530 = false;
  bool      总_195_bo_531 = false;
  double    总_196_do_568_si20si2[20][2];
  double    总_197_do_6DC_si100si3[100][3];
  double    总_198_do_1070_si100si2[100][2];
  int       总_199_in_16B0 = 20;
  int       总_200_in_16B4 = 100;
  double    总_201_do_16B8 = 0.0;
  double    总_202_do_16C0 = 0.0;
  double    总_203_do_16C8 = 0.0;
  double    总_204_do_16D0 = 0.0;
  double    总_205_do_16D8 = 0.0;
  double    总_206_do_16E0 = 0.0;
  bool      总_207_bo_16E8 = false;
  int       总_208_in_16EC = 10;
  double    总_209_do_16F0 = 0.0;
  double    总_210_do_16F8 = 0.0;
  double    总_211_do_1700 = 0.0;
  double    总_212_do_1708 = 0.0;
  bool      总_213_bo_1710 = false;
  int       总_214_in_1714 = 1;
  datetime  总_215_da_174C_si99[99];
  long      总_216_lo_1A68 = 0;
  int       总_217_in_1A70 = 370;
  bool      总_218_bo_1A74 = true;
  bool      总_219_bo_1A75 = false;
  int       总_220_in_1A78 = 0;
  double    总_221_do_1A80 = 4.0;
  double    总_222_do_1A88 = 0.0;
  double    总_223_do_1AC4_si99[99];
  double    总_224_do_1DE0 = 0.0;
  int       总_225_in_1DE8 = 0;
  int       总_226_in_1DEC = 0;
  double    总_227_do_1DF0 = 0.0;
  double    总_228_do_1DF8 = 0.0;
  double    总_229_do_1E00 = 0.0;
  long      总_230_in_1E08 = 0; // ticket NativeSendOrder la 64-bit; bool NativeModifyTrade van gan duoc 0/1
  bool      总_231_bo_1E0C = false;
  double    总_232_do_1E10 = 0.0;
  double    总_233_do_1E18 = 0.0;
  int       总_234_in_1E20 = 0;
  double    总_235_do_1E28 = 0.0;
  double    总_236_do_1E30 = 0.0;
  double    总_237_do_1E38 = 0.0;
  bool      总_238_bo_1E40 = false;
  bool      总_239_bo_1E41 = false;
  bool      总_240_bo_1E42 = false;
  double    总_241_do_1E78_si99[99];
  double    总_242_do_21C4_si99[99];
  double    总_243_do_24E0 = 0.0;
  double    总_244_do_24E8 = 0.0;
  double    总_245_do_24F0 = 0.0;
  double    总_246_do_24F8 = 0.0;
  double    总_247_do_2500 = 0.0;
  double    总_248_do_2508 = 0.0;
  double    总_249_do_2510 = 0.0;
  int       总_250_in_2518 = 0;
  double    总_251_do_2520 = 0.0;
  string    总_252_st_2528;
  string    总_253_st_2538;
  string    总_254_st_2548;
  string    总_255_st_2558;
  bool      总_256_bo_2564 = false;
  bool      总_257_bo_2565 = false;
  int       总_258_in_2568 = 0;
  int       总_259_in_256C = 0;
  double    总_260_do_2570 = 0.0;
  double    总_261_do_2578 = 0.0;
  double    总_262_do_2580 = 0.0;
  double    总_263_do_2588 = 0.0;
  double    总_264_do_2590 = 0.0;
  int       总_265_in_2598 = 0;
  int       总_266_in_259C = 0;
  int       总_267_in_25A0 = 0;
  double    总_268_do_25A8 = 0.0;
  double    总_269_do_25B0 = 0.0;
  double    总_270_do_25B8 = 0.0;
  double    总_271_do_25C0 = 0.0;
  double    总_272_do_25C8 = 0.0;
  double    总_273_do_25D0 = 0.0;
  int       总_274_in_25D8 = 0;
  double    总_275_do_25E0 = 0.0;
  double    总_276_do_25E8 = 0.0;
  double    总_277_do_25F0 = 0.0;
  bool      总_278_bo_25F8 = false;
  bool      总_279_bo_25F9 = false;
  bool      总_280_bo_25FA = false;
  bool      总_281_bo_25FB = false;
  bool      总_282_bo_25FC = false;
  bool      总_283_bo_25FD = false;
  double    总_284_do_2600 = 0.0;
  double    总_285_do_2608 = 0.0;
  bool      总_286_bo_2610 = false;
  double    总_287_do_2618 = 0.0;
  double    总_288_do_2620 = 0.0;
  int       总_289_in_2628 = 0;
  int       总_290_in_262C = 0;
  double    总_291_do_2664_si10[10];
  double    总_292_do_26E8_si10[10];
  double    总_293_do_276C_si10[10];
  double    总_294_do_27F0_si10[10];
  int       总_295_in_2840 = 0;
  int       总_296_in_2844 = 0;
  int       总_297_in_2848 = 0;
  int       总_298_in_284C = 0;
  string    总_299_st_2850;
  double    总_300_do_2860 = 0.0;
  double    总_301_do_2868 = 0.0;
  datetime  总_302_da_2870 = 0;
  bool      总_303_bo_2878 = false;
  int       总_304_in_287C = 0;
  bool      总_305_bo_2880 = false;
  int       总_306_in_2884 = 0;
  double    总_307_do_2888 = 0.0;
  double    总_308_do_2890 = 0.0;
  double    总_309_do_2898 = 0.0;
  double    总_310_do_28A0 = 0.0;
  double    总_311_do_28A8 = 0.0;
  bool      总_312_bo_28B0 = false;
  datetime  总_313_da_28B8 = 0;
  datetime  总_314_da_28C0 = 0;
  datetime  总_315_da_28C8 = 0;
  bool      总_316_bo_28D0 = false;
  bool      总_317_bo_28D1 = false;
  double    总_318_do_28D8 = 0.0;
  datetime  总_319_da_28E0 = 0;
  bool      总_320_bo_28E8 = false;
  int       总_321_in_2920_si99[99];
  int       总_322_in_2AE0_si99[99];
  double    总_323_do_2CA0_si30[30];
  double    总_324_do_2DC4_si30[30];
  double    总_325_do_2EE8_si30[30];
  double    总_326_do_300C_si30[30];
  int       总_327_in_30FC = 1;
  int       总_328_in_3100 = 0;
  uint      总_329_ui_3104 = DarkBlue;
  bool      总_330_bo_3108 = false;
  long      总_331_lo_3110 = 0;
  int       总_332_in_3118 = 5;
  bool      总_333_bo_311C = false;
  string    总_334_st_3120;
  bool      总_335_bo_312C = false;
  string    总_336_st_3130;
  double    总_337_do_3140 = 0.0;
  double    总_338_do_3148 = 0.0;
  int       总_339_in_3184_si99[99];
  int       总_340_in_3310 = 0;
  double    总_341_do_3348_si99[99];
  bool      总_342_bo_3694_si99[99];
  int       总_343_in_372C_si99[99];
  int       总_344_in_38EC_si99[99];
  double    总_345_do_3AAC_si99[99];
  double    总_346_do_3DF8_si99[99];
  string    总_347_st_4144_si99[99]={};
  bool      总_348_bo_461C_si99[99];
  double    总_349_do_46B4_si99[99];
  double    总_350_do_4A00_si99[99];
  double    总_351_do_4D4C_si99[99];
  double    总_352_do_5098_si99[99];
  double    总_353_do_53E4_si99[99];
  double    总_354_do_5730_si99[99];
  bool      总_355_bo_5A7C_si99[99];
  int       总_356_in_5B14_si99[99];
  bool      总_357_bo_5CA0 = false;
  double    总_358_do_5CA8 = 5.0;
  double    总_359_do_5CB0 = 10.0;
  int       总_360_in_5CB8 = 0;
  double    总_361_do_5CC0 = 0.0;
  double    总_362_do_5CC8 = 0.0;
  int       总_363_in_5CD0 = 0;
  uint      总_364_ui_5CD4 = LightSteelBlue;
  bool      总_365_bo_5CD8 = true;
  double    总_366_do_5CE0 = 12.0;
  int       总_367_in_5CE8 = 230;
  int       总_368_in_5CEC = 320;
  int       总_369_in_5CF0 = 500;
  int       总_370_in_5CF4 = 350;
  int       总_371_in_5CF8 = 2;
  int       总_372_in_5CFC = 7;
  int       总_373_in_5D00 = 10;
  int       总_374_in_5D04 = 30;
  string    总_375_st_5D3C_si4[4]={};
  double    总_376_do_5D70 = 0.45;
  double    总_377_do_5D78 = 0.6;
  int       总_378_in_5D80 = 0;
  datetime  总_379_da_5D88 = 0;
  bool      总_380_bo_5D90 = false;
  int       总_381_in_5D94 = 0;
  bool      总_382_bo_5D98 = false;
  int       总_383_in_5D9C = 0;
  double    总_384_do_5DA0 = 0.0;
  int       总_385_in_5DA8 = 200;
  int       总_386_in_5DAC = 330;
  int       总_387_in_5DB0 = 560;
  int       总_388_in_5DB4 = 810;
  int       总_389_in_5DB8 = 1150;
  datetime  总_390_da_5DC0 = 0;
  datetime  总_391_da_5DFC_si300[300];
  bool      总_392_bo_675C = false;
  bool      总_393_bo_675D = false;
  bool      总_394_bo_675E = false;
  int       总_395_in_6760 = 0;
  int       总_396_in_6764 = 0;
  double    总_397_do_6768 = 0.0;
  double    总_398_do_6770 = 0.0;
  datetime  总_399_da_6778 = 0;
  double    总_400_do_67B4_si99[99];
  double    总_401_do_6AD0 = 0.0;
  double    总_402_do_6AD8 = 0.0;
  bool      g_backtestSpeedFast = false;
  bool      g_backtestSpeedEnabled = false;
  datetime  g_backtestSpeedLastTime = 0;
  datetime  g_backtestSpeedLastM1 = 0;
  double    g_MaxSpread_rw = 0.0;
  // Original V4.6 keeps one calendar-derived NFP timestamp, not a rebuilt
  // 300-element calendar array.  The hardcoded array remains intact as fallback.
  datetime  g_nextNFPCalendar = 0;
  datetime  g_nfpCalendarLastRefresh = 0;

//+------------------------------------------------------------------+
//| Recovered from original V4.6 JIT (0x19aa50b5170).                |
//| CalendarEventByCurrency("USD") -> exact name substring          |
//| "Nonfarm Payrolls" -> values in [server_now-1d, server_now+30d]|
//| -> earliest value in that window.                               |
//+------------------------------------------------------------------+
 datetime GetNextNFPFromCalendar()
 {
  datetime 临_now = TimeTradeServer();
  MqlCalendarEvent 临_events[];
  int 临_evTotal = CalendarEventByCurrency("USD",临_events);
  if ( 临_evTotal <= 0 )   return(0);

  ulong 临_nfpId = 0;
  bool 临_found = false;
  for (int 临_i=0; 临_i<临_evTotal; 临_i++)
  {
    if ( StringFind(临_events[临_i].name,"Nonfarm Payrolls") >= 0 )
    {
      临_nfpId = 临_events[临_i].id;
      临_found = true;
      break;
    }
  }
  if ( !(临_found) )   return(0);

  MqlCalendarValue 临_values[];
  datetime 临_from = 临_now - 86400;
  datetime 临_to   = 临_now + 2592000;
  int 临_n = CalendarValueHistoryByEvent(临_nfpId,临_values,临_from,临_to);
  if ( 临_n <= 0 )   return(0);

  datetime 临_best = 0;
  for (int 临_i=0; 临_i<临_n; 临_i++)
  {
    datetime 临_t = 临_values[临_i].time;
    // JIT compares against the lower query bound (now-1 day), not strictly now.
    if ( 临_t <= 临_from )   continue;
    if ( 临_best == 0 || 临_t < 临_best )   临_best = 临_t;
  }
  return(临_best);
 }
//GetNextNFPFromCalendar <<==--------   --------

// Original V4.6 dump has no withdrawal-reconciliation layer here.

 int OnInit()
 {
 trade.SetAsyncMode(false);
 trade.LogLevel(LOG_LEVEL_NO);
g_startLots_rw=StartLots;
 // Recovered from original JIT: BacktestSpeed is active only in Strategy Tester.
 g_backtestSpeedFast = false;
 g_backtestSpeedEnabled = false;
 g_backtestSpeedLastTime = 0;
 g_backtestSpeedLastM1 = 0;
 if ( MQLInfoInteger(MQL_TESTER) == 1 )
 {
   if ( BacktestSpeed == speed_fast )
   {
     g_backtestSpeedFast = true;
     g_backtestSpeedEnabled = true;
   }
   else if ( BacktestSpeed == speed_super )
   {
     g_backtestSpeedFast = false;
     g_backtestSpeedEnabled = true;
   }
 }
  double    子_2_do;
  double    子_3_do;
  int       子_4_in;
  int       子_5_in;
  int       子_6_in;
  int       子_7_in;
  int       子_8_in;
  int       子_9_in;
//----- -----
 // Explicit initialization preserves the V6 value before its first use.
 bool       临_bo_1 = false;

 // SetFontSize >0: ghi de co chu panel (0 = co mac dinh theo thiet ke goc)
 if ( SetFontSize > 0 )   总_372_in_5CFC = SetFontSize ;

 // Recovered directly from original V4.6 JIT around 0x19aa50b0f47-0x19aa50b13c7.
 // Important ordering in the original:
 //   1) account BALANCE, optionally EQUITY;
 //   2) ResetHighestBalance => GlobalVariableSet("HighestBalance",0) + Sleep(5000);
 //   3) read the single terminal Global Variable "HighestBalance";
 //   4) highest = max(account value, stored value), write it back unconditionally;
 //   5) only AFTER that, ManualBalance may override the working risk balance.
 总_401_do_6AD0 = AccountInfoDouble(ACCOUNT_BALANCE) ;
 if ( UseEquity )
 {
   总_401_do_6AD0 = AccountInfoDouble(ACCOUNT_EQUITY) ;
 }
 if ( ResetHighestBalance )
 {
   GlobalVariableSet("HighestBalance",0.0) ;
   Sleep(5000) ;
 }
 double 临_storedHighest = GlobalVariableGet("HighestBalance") ;
 if ( 临_storedHighest>总_401_do_6AD0 )
 {
   Print("HighestBalance value found: ",临_storedHighest) ;
   总_402_do_6AD8 = 临_storedHighest ;
 }
 else
 {
   总_402_do_6AD8 = 总_401_do_6AD0 ;
 }
 GlobalVariableSet("HighestBalance",总_402_do_6AD8) ;
 if ( ManualBalance>0.0 )
 {
   总_401_do_6AD0 = ManualBalance ;
 }
 总_392_bo_675C = false ;
 总_393_bo_675D = false ;
 总_391_da_5DFC_si300[0] = D'2026.12.04 12:30';
 总_391_da_5DFC_si300[1] = D'2026.11.06 12:30';
 总_391_da_5DFC_si300[2] = D'2026.10.02 12:30';
 总_391_da_5DFC_si300[3] = D'2026.09.04 12:30';
 总_391_da_5DFC_si300[4] = D'2026.08.07 12:30';
 总_391_da_5DFC_si300[5] = D'2026.07.02 12:30';
 总_391_da_5DFC_si300[6] = D'2026.06.05 12:30';
 总_391_da_5DFC_si300[7] = D'2026.05.08 12:30';
 总_391_da_5DFC_si300[8] = D'2026.04.03 12:30';
 总_391_da_5DFC_si300[9] = D'2026.03.06 12:30';
 总_391_da_5DFC_si300[10] = D'2026.02.06 12:30';
 总_391_da_5DFC_si300[11] = D'2026.01.09 12:30';
 总_391_da_5DFC_si300[12] = D'2025.12.16 12:30';
 总_391_da_5DFC_si300[13] = D'2025.11.07 12:30';
 总_391_da_5DFC_si300[14] = D'2025.10.03 12:30';
 总_391_da_5DFC_si300[15] = D'2025.09.05 12:30';
 总_391_da_5DFC_si300[16] = D'2025.08.01 12:30';
 总_391_da_5DFC_si300[17] = D'2025.07.03 12:30';
 总_391_da_5DFC_si300[18] = D'2025.06.06 12:30';
 总_391_da_5DFC_si300[19] = D'2025.05.02 12:30';
 总_391_da_5DFC_si300[20] = D'2025.04.04 12:30';
 总_391_da_5DFC_si300[21] = D'2025.03.07 12:30';
 总_391_da_5DFC_si300[22] = D'2025.02.07 12:30';
 总_391_da_5DFC_si300[23] = D'2025.01.10 12:30';
 总_391_da_5DFC_si300[24] = D'2024.12.06 12:30';
 总_391_da_5DFC_si300[25] = D'2024.11.01 12:30';
 总_391_da_5DFC_si300[26] = D'2024.10.04 12:30';
 总_391_da_5DFC_si300[27] = D'2024.09.06 12:30';
 总_391_da_5DFC_si300[28] = D'2024.08.02 12:30';
 总_391_da_5DFC_si300[29] = D'2024.07.05 12:30';
 总_391_da_5DFC_si300[30] = D'2024.06.07 12:30';
 总_391_da_5DFC_si300[31] = D'2024.05.03 12:30';
 总_391_da_5DFC_si300[32] = D'2024.04.05 12:30';
 总_391_da_5DFC_si300[33] = D'2024.03.08 12:30';
 总_391_da_5DFC_si300[34] = D'2024.02.02 12:30';
 总_391_da_5DFC_si300[35] = D'2024.01.05 12:30';
 总_391_da_5DFC_si300[36] = D'2023.12.08 12:30';
 总_391_da_5DFC_si300[37] = D'2023.11.03 12:30';
 总_391_da_5DFC_si300[38] = D'2023.10.06 12:30';
 总_391_da_5DFC_si300[39] = D'2023.09.01 12:30';
 总_391_da_5DFC_si300[40] = D'2023.08.04 12:30';
 总_391_da_5DFC_si300[41] = D'2023.07.07 12:30';
 总_391_da_5DFC_si300[42] = D'2023.06.02 12:30';
 总_391_da_5DFC_si300[43] = D'2023.05.05 12:30';
 总_391_da_5DFC_si300[44] = D'2023.04.07 12:30';
 总_391_da_5DFC_si300[45] = D'2023.03.10 12:30';
 总_391_da_5DFC_si300[46] = D'2023.02.03 12:30';
 总_391_da_5DFC_si300[47] = D'2023.01.06 12:30';
 总_391_da_5DFC_si300[48] = D'2022.12.02 12:30';
 总_391_da_5DFC_si300[49] = D'2022.11.04 12:30';
 总_391_da_5DFC_si300[50] = D'2022.10.07 12:30';
 总_391_da_5DFC_si300[51] = D'2022.09.02 12:30';
 总_391_da_5DFC_si300[52] = D'2022.08.05 12:30';
 总_391_da_5DFC_si300[53] = D'2022.07.08 12:30';
 总_391_da_5DFC_si300[54] = D'2022.06.03 12:30';
 总_391_da_5DFC_si300[55] = D'2022.05.06 12:30';
 总_391_da_5DFC_si300[56] = D'2022.04.01 12:30';
 总_391_da_5DFC_si300[57] = D'2022.03.04 12:30';
 总_391_da_5DFC_si300[58] = D'2022.02.04 12:30';
 总_391_da_5DFC_si300[59] = D'2022.01.07 12:30';
 总_391_da_5DFC_si300[60] = D'2021.12.03 12:30';
 总_391_da_5DFC_si300[61] = D'2021.11.05 12:30';
 总_391_da_5DFC_si300[62] = D'2021.10.08 12:30';
 总_391_da_5DFC_si300[63] = D'2021.09.03 12:30';
 总_391_da_5DFC_si300[64] = D'2021.08.06 12:30';
 总_391_da_5DFC_si300[65] = D'2021.07.02 12:30';
 总_391_da_5DFC_si300[66] = D'2021.06.04 12:30';
 总_391_da_5DFC_si300[67] = D'2021.05.07 12:30';
 总_391_da_5DFC_si300[68] = D'2021.04.02 12:30';
 总_391_da_5DFC_si300[69] = D'2021.03.05 12:30';
 总_391_da_5DFC_si300[70] = D'2021.02.05 12:30';
 总_391_da_5DFC_si300[71] = D'2021.01.08 12:30';
 总_391_da_5DFC_si300[72] = D'2020.12.04 12:30';
 总_391_da_5DFC_si300[73] = D'2020.11.06 12:30';
 总_391_da_5DFC_si300[74] = D'2020.10.02 12:30';
 总_391_da_5DFC_si300[75] = D'2020.09.04 12:30';
 总_391_da_5DFC_si300[76] = D'2020.08.07 12:30';
 总_391_da_5DFC_si300[77] = D'2020.07.02 12:30';
 总_391_da_5DFC_si300[78] = D'2020.06.05 12:30';
 总_391_da_5DFC_si300[79] = D'2020.05.08 12:30';
 总_391_da_5DFC_si300[80] = D'2020.04.03 12:30';
 总_391_da_5DFC_si300[81] = D'2020.03.06 12:30';
 总_391_da_5DFC_si300[82] = D'2020.02.07 12:30';
 总_391_da_5DFC_si300[83] = D'2020.01.10 12:30';
 总_391_da_5DFC_si300[84] = D'2019.12.06 12:30';
 总_391_da_5DFC_si300[85] = D'2019.11.01 12:30';
 总_391_da_5DFC_si300[86] = D'2019.10.04 12:30';
 总_391_da_5DFC_si300[87] = D'2019.09.06 12:30';
 总_391_da_5DFC_si300[88] = D'2019.08.02 12:30';
 总_391_da_5DFC_si300[89] = D'2019.07.05 12:30';
 总_391_da_5DFC_si300[90] = D'2019.06.07 12:30';
 总_391_da_5DFC_si300[91] = D'2019.05.03 12:30';
 总_391_da_5DFC_si300[92] = D'2019.04.05 12:30';
 总_391_da_5DFC_si300[93] = D'2019.03.08 12:30';
 总_391_da_5DFC_si300[94] = D'2019.02.01 12:30';
 总_391_da_5DFC_si300[95] = D'2019.01.04 12:30';
 总_391_da_5DFC_si300[96] = D'2018.12.07 12:30';
 总_391_da_5DFC_si300[97] = D'2018.11.02 12:30';
 总_391_da_5DFC_si300[98] = D'2018.10.05 12:30';
 总_391_da_5DFC_si300[99] = D'2018.09.07 12:30';
 总_391_da_5DFC_si300[100] = D'2018.08.03 12:30';
 总_391_da_5DFC_si300[101] = D'2018.07.06 12:30';
 总_391_da_5DFC_si300[102] = D'2018.06.01 12:30';
 总_391_da_5DFC_si300[103] = D'2018.05.04 12:30';
 总_391_da_5DFC_si300[104] = D'2018.04.06 12:30';
 总_391_da_5DFC_si300[105] = D'2018.03.09 12:30';
 总_391_da_5DFC_si300[106] = D'2018.02.02 12:30';
 总_391_da_5DFC_si300[107] = D'2018.01.05 12:30';
 总_391_da_5DFC_si300[108] = D'2017.12.08 12:30';
 总_391_da_5DFC_si300[109] = D'2017.11.03 12:30';
 总_391_da_5DFC_si300[110] = D'2017.10.06 12:30';
 总_391_da_5DFC_si300[111] = D'2017.09.01 12:30';
 总_391_da_5DFC_si300[112] = D'2017.08.04 12:30';
 总_391_da_5DFC_si300[113] = D'2017.07.07 12:30';
 总_391_da_5DFC_si300[114] = D'2017.06.02 12:30';
 总_391_da_5DFC_si300[115] = D'2017.05.05 12:30';
 总_391_da_5DFC_si300[116] = D'2017.04.07 12:30';
 总_391_da_5DFC_si300[117] = D'2017.03.10 12:30';
 总_391_da_5DFC_si300[118] = D'2017.02.03 12:30';
 总_391_da_5DFC_si300[119] = D'2017.01.06 12:30';
 总_391_da_5DFC_si300[120] = D'2016.12.02 12:30';
 总_391_da_5DFC_si300[121] = D'2016.11.04 12:30';
 总_391_da_5DFC_si300[122] = D'2016.10.07 12:30';
 总_391_da_5DFC_si300[123] = D'2016.09.02 12:30';
 总_391_da_5DFC_si300[124] = D'2016.08.05 12:30';
 总_391_da_5DFC_si300[125] = D'2016.07.08 12:30';
 总_391_da_5DFC_si300[126] = D'2016.06.03 12:30';
 总_391_da_5DFC_si300[127] = D'2016.05.06 12:30';
 总_391_da_5DFC_si300[128] = D'2016.04.01 12:30';
 总_391_da_5DFC_si300[129] = D'2016.03.04 12:30';
 总_391_da_5DFC_si300[130] = D'2016.02.05 12:30';
 总_391_da_5DFC_si300[131] = D'2016.01.08 12:30';
 总_391_da_5DFC_si300[132] = D'2015.12.04 12:30';
 总_391_da_5DFC_si300[133] = D'2015.11.06 12:30';
 总_391_da_5DFC_si300[134] = D'2015.10.02 12:30';
 总_391_da_5DFC_si300[135] = D'2015.09.04 12:30';
 总_391_da_5DFC_si300[136] = D'2015.08.07 12:30';
 总_391_da_5DFC_si300[137] = D'2015.07.02 12:30';
 总_391_da_5DFC_si300[138] = D'2015.06.05 12:30';
 总_391_da_5DFC_si300[139] = D'2015.05.08 12:30';
 总_391_da_5DFC_si300[140] = D'2015.04.03 12:30';
 总_391_da_5DFC_si300[141] = D'2015.03.06 12:30';
 总_391_da_5DFC_si300[142] = D'2015.02.06 12:30';
 总_391_da_5DFC_si300[143] = D'2015.01.09 12:30';
 总_391_da_5DFC_si300[144] = D'2014.12.05 12:30';
 总_391_da_5DFC_si300[145] = D'2014.11.07 12:30';
 总_391_da_5DFC_si300[146] = D'2014.10.03 12:30';
 总_391_da_5DFC_si300[147] = D'2014.09.05 12:30';
 总_391_da_5DFC_si300[148] = D'2014.08.01 12:30';
 总_391_da_5DFC_si300[149] = D'2014.07.03 12:30';
 总_391_da_5DFC_si300[150] = D'2014.06.06 12:30';
 总_391_da_5DFC_si300[151] = D'2014.05.02 12:30';
 总_391_da_5DFC_si300[152] = D'2014.04.04 12:30';
 总_391_da_5DFC_si300[153] = D'2014.03.07 12:30';
 总_391_da_5DFC_si300[154] = D'2014.02.07 12:30';
 总_391_da_5DFC_si300[155] = D'2014.01.10 12:30';
 总_391_da_5DFC_si300[156] = D'2013.12.06 12:30';
 总_391_da_5DFC_si300[157] = D'2013.11.08 12:30';
 总_391_da_5DFC_si300[158] = D'2013.10.22 12:30';
 总_391_da_5DFC_si300[159] = D'2013.09.06 12:30';
 总_391_da_5DFC_si300[160] = D'2013.08.02 12:30';
 总_391_da_5DFC_si300[161] = D'2013.07.05 12:30';
 总_391_da_5DFC_si300[162] = D'2013.06.07 12:30';
 总_391_da_5DFC_si300[163] = D'2013.05.03 12:30';
 总_391_da_5DFC_si300[164] = D'2013.04.05 12:30';
 总_391_da_5DFC_si300[165] = D'2013.03.08 12:30';
 总_391_da_5DFC_si300[166] = D'2013.02.01 12:30';
 总_391_da_5DFC_si300[167] = D'2013.01.04 12:30';
 总_391_da_5DFC_si300[168] = D'2012.12.07 12:30';
 总_391_da_5DFC_si300[169] = D'2012.11.02 12:30';
 总_391_da_5DFC_si300[170] = D'2012.10.05 12:30';
 总_391_da_5DFC_si300[171] = D'2012.09.07 12:30';
 总_391_da_5DFC_si300[172] = D'2012.08.03 12:30';
 总_391_da_5DFC_si300[173] = D'2012.07.06 12:30';
 总_391_da_5DFC_si300[174] = D'2012.06.01 12:30';
 总_391_da_5DFC_si300[175] = D'2012.05.04 12:30';
 总_391_da_5DFC_si300[176] = D'2012.04.06 12:30';
 总_391_da_5DFC_si300[177] = D'2012.03.09 12:30';
 总_391_da_5DFC_si300[178] = D'2012.02.03 12:30';
 总_391_da_5DFC_si300[179] = D'2012.01.06 12:30';
 总_391_da_5DFC_si300[180] = D'2011.12.02 12:30';
 总_391_da_5DFC_si300[181] = D'2011.11.04 12:30';
 总_391_da_5DFC_si300[182] = D'2011.10.07 12:30';
 总_391_da_5DFC_si300[183] = D'2011.09.02 12:30';
 总_391_da_5DFC_si300[184] = D'2011.08.05 12:30';
 总_391_da_5DFC_si300[185] = D'2011.07.08 12:30';
 总_391_da_5DFC_si300[186] = D'2011.06.03 12:30';
 总_391_da_5DFC_si300[187] = D'2011.05.06 12:30';
 总_391_da_5DFC_si300[188] = D'2011.04.01 12:30';
 总_391_da_5DFC_si300[189] = D'2011.03.04 12:30';
 总_391_da_5DFC_si300[190] = D'2011.02.04 12:30';
 总_391_da_5DFC_si300[191] = D'2011.01.07 12:30';
 总_391_da_5DFC_si300[192] = D'2010.12.03 12:30';
 总_391_da_5DFC_si300[193] = D'2010.11.05 12:30';
 总_391_da_5DFC_si300[194] = D'2010.10.08 12:30';
 总_391_da_5DFC_si300[195] = D'2010.09.03 12:30';
 总_391_da_5DFC_si300[196] = D'2010.08.06 12:30';
 总_391_da_5DFC_si300[197] = D'2010.07.02 12:30';
 总_391_da_5DFC_si300[198] = D'2010.06.04 12:30';
 总_391_da_5DFC_si300[199] = D'2010.05.07 12:30';
 总_391_da_5DFC_si300[200] = D'2010.04.02 12:30';
 总_391_da_5DFC_si300[201] = D'2010.03.05 12:30';
 总_391_da_5DFC_si300[202] = D'2010.02.05 12:30';
 总_391_da_5DFC_si300[203] = D'2010.01.08 12:30';
 总_391_da_5DFC_si300[204] = D'2009.12.04 12:30';
 总_391_da_5DFC_si300[205] = D'2009.11.06 12:30';
 总_391_da_5DFC_si300[206] = D'2009.10.02 12:30';
 总_391_da_5DFC_si300[207] = D'2009.09.04 12:30';
 总_391_da_5DFC_si300[208] = D'2009.08.07 12:30';
 总_391_da_5DFC_si300[209] = D'2009.07.02 12:30';
 总_391_da_5DFC_si300[210] = D'2009.06.05 12:30';
 总_391_da_5DFC_si300[211] = D'2009.05.08 12:30';
 总_391_da_5DFC_si300[212] = D'2009.04.03 12:30';
 总_391_da_5DFC_si300[213] = D'2009.03.06 12:30';
 总_391_da_5DFC_si300[214] = D'2009.02.06 12:30';
 总_391_da_5DFC_si300[215] = D'2009.01.09 12:30';
 总_391_da_5DFC_si300[216] = D'2008.12.05 12:30';
 总_391_da_5DFC_si300[217] = D'2008.11.07 12:30';
 总_391_da_5DFC_si300[218] = D'2008.10.03 12:30';
 总_391_da_5DFC_si300[219] = D'2008.09.05 12:30';
 总_391_da_5DFC_si300[220] = D'2008.08.01 12:30';
 总_391_da_5DFC_si300[221] = D'2008.07.03 12:30';
 总_391_da_5DFC_si300[222] = D'2008.06.06 12:30';
 总_391_da_5DFC_si300[223] = D'2008.05.02 12:30';
 总_391_da_5DFC_si300[224] = D'2008.04.04 12:30';
 总_391_da_5DFC_si300[225] = D'2008.03.07 12:30';
 总_391_da_5DFC_si300[226] = D'2008.02.01 12:30';
 总_391_da_5DFC_si300[227] = D'2008.01.04 12:30';
 总_391_da_5DFC_si300[228] = D'2007.12.07 12:30';
 总_391_da_5DFC_si300[229] = D'2007.11.02 12:30';
 总_391_da_5DFC_si300[230] = D'2007.10.05 12:30';
 总_391_da_5DFC_si300[231] = D'2007.09.07 12:30';
 总_391_da_5DFC_si300[232] = D'2007.08.03 12:30';
 总_391_da_5DFC_si300[233] = D'2007.07.06 12:30';
 总_391_da_5DFC_si300[234] = D'2007.06.01 12:30';
 总_391_da_5DFC_si300[235] = D'2007.05.04 12:30';
 总_391_da_5DFC_si300[236] = D'2007.04.06 12:30';
 总_391_da_5DFC_si300[237] = D'2007.03.09 12:30';
 总_391_da_5DFC_si300[238] = D'2007.02.02 12:30';
 总_391_da_5DFC_si300[239] = D'2007.01.05 12:30';
 // Original OnInit calls the calendar helper whenever the NFP filter is enabled.
 // In Strategy Tester the calendar normally returns 0; runtime then uses hardcoded dates.
 if ( EnableNFP_Filter )   g_nextNFPCalendar = GetNextNFPFromCalendar();
 g_nfpCalendarLastRefresh = 0;
 if ( Risk == 1234 )
 {
   g_startLots_rw = SymbolInfoDouble(总_336_st_3130,SYMBOL_VOLUME_MIN) ;
 }
 if ( TradeFrequency == 5 && Risk == 1234 )
 {
   子_2_do = lizong_36(AccountInfoDouble(ACCOUNT_BALANCE)) ;
   子_3_do = MaxAllowedDD / 100.0 * 子_2_do ;
   if ( 子_3_do>总_388_in_5DB4 )
   {
     总_19_in_9C = 3 ;
   }
   else
   {
     if ( 子_3_do>总_387_in_5DB0 )
     {
       总_19_in_9C = 2 ;
     }
     else
     {
       if ( 子_3_do>总_386_in_5DAC )
       {
         总_19_in_9C = 1 ;
       }
       else
       {
         总_19_in_9C = 0 ;
       }
     }
   }
 }
 else
 {
   总_19_in_9C = TradeFrequency ;
 }
 if ( 总_19_in_9C == 0 )
 {
   总_27_bo_A7 = false ;
   总_31_bo_AB = false ;
   总_28_bo_A8 = false ;
   总_33_bo_AD = false ;
   总_34_bo_AE = false ;
   总_32_bo_AC = false ;
   总_398_do_6770 = 2.4 ;
   if ( UseVariableValues )
   {
     总_398_do_6770 = 3.0 ;
   }
 }
 else
 {
   if ( 总_19_in_9C == 1 )
   {
     总_27_bo_A7 = true ;
     总_31_bo_AB = true ;
     总_28_bo_A8 = false ;
     总_33_bo_AD = false ;
     总_34_bo_AE = false ;
     总_32_bo_AC = false ;
     总_398_do_6770 = 3.4 ;
     if ( UseVariableValues )
     {
       总_398_do_6770 = 4.0 ;
     }
   }
   else
   {
     if ( 总_19_in_9C == 2 )
     {
       总_27_bo_A7 = true ;
       总_31_bo_AB = true ;
       总_28_bo_A8 = true ;
       总_33_bo_AD = true ;
       总_34_bo_AE = false ;
       总_32_bo_AC = false ;
       总_398_do_6770 = 4.1 ;
       if ( UseVariableValues )
       {
         总_398_do_6770 = 5.0 ;
       }
     }
     else
     {
       if ( 总_19_in_9C == 3 )
       {
         总_27_bo_A7 = true ;
         总_31_bo_AB = true ;
         总_28_bo_A8 = true ;
         总_33_bo_AD = true ;
         总_34_bo_AE = true ;
         总_32_bo_AC = false ;
         总_398_do_6770 = 4.8 ;
         if ( UseVariableValues )
         {
           总_398_do_6770 = 5.6 ;
         }
       }
       else
       {
         if ( 总_19_in_9C == 4 )
         {
           总_27_bo_A7 = true ;
           总_31_bo_AB = true ;
           总_28_bo_A8 = true ;
           总_33_bo_AD = true ;
           总_34_bo_AE = true ;
           总_32_bo_AC = true ;
           总_398_do_6770 = 5.1 ;
           if ( UseVariableValues )
           {
             总_398_do_6770 = 6.0 ;
           }
         }
         else
         {
           if ( 总_19_in_9C == 6 )
           {
             总_20_bo_A0 = RunStrat1 ;
             总_23_bo_A3 = RunStrat2 ;
             总_26_bo_A6 = RunStrat3 ;
             总_27_bo_A7 = RunStrat4 ;
             总_31_bo_AB = RunStrat5 ;
             总_28_bo_A8 = RunStrat6 ;
             总_33_bo_AD = RunStrat7 ;
             总_34_bo_AE = RunStrat8 ;
             总_32_bo_AC = RunStrat9 ;
           }
         }
       }
     }
   }
 }
 总_334_st_3120 = ST1_Comment ;
 总_384_do_5DA0 = 0.0 ;
 总_382_bo_5D98 = false ;
 总_379_da_5D88 = 0 ;
 总_380_bo_5D90 = true ;
 总_358_do_5CA8 = 5.0 ;
 总_359_do_5CB0 = 10.0 ;
 总_93_in_1F0 = ST1_MagicNumber ;
 总_360_in_5CB8 = 300 ;
 总_361_do_5CC0 = 总_372_in_5CFC * 25 * 总_376_do_5D70 * InfoPanelSizeAdjust ;
 总_362_do_5CC8 = 总_372_in_5CFC * 3.5 * 总_377_do_5D78 * InfoPanelSizeAdjust ;
 总_363_in_5CD0 = 7 ;
 总_328_in_3100 = 0 ;
 总_336_st_3130 = Symbol() ;
 总_337_do_3140 = SymbolInfoDouble(总_336_st_3130,SYMBOL_POINT) ;
 总_229_do_1E00 = 总_337_do_3140 ;
 if ( ( (double)SymbolInfoInteger(总_336_st_3130,SYMBOL_DIGITS)==3.0 || (double)SymbolInfoInteger(总_336_st_3130,SYMBOL_DIGITS)==5.0 ) )
 {
   总_229_do_1E00 = 总_337_do_3140 * 10.0 ;
 }
 if ( SymbolInfoInteger(总_336_st_3130,SYMBOL_DIGITS) == 0x1 )
 {
   总_229_do_1E00 = 总_337_do_3140 / 10.0 ;
 }
 总_190_in_518 = (int)(double)SymbolInfoInteger(总_336_st_3130,SYMBOL_DIGITS) ;
 if ( FridayStopHour <  0 )
 {
   总_45_bo_FC = false ;
 }
 else
 {
   总_45_bo_FC = true ;
 }
 总_251_do_2520 = (double)TimeCurrent() ;
 总_1_do_0 = SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK) - SymbolInfoDouble(总_336_st_3130,SYMBOL_BID) ;
 总_223_do_1AC4_si99[总_328_in_3100] = NormalizeDouble(MathFloor(g_startLots_rw * 100.0) / 100.0,2);
 if ( SymbolInfoDouble(总_336_st_3130,SYMBOL_VOLUME_STEP)==0.1 )
 {
   总_223_do_1AC4_si99[总_328_in_3100] = NormalizeDouble((MathFloor(g_startLots_rw * 10.0)) / 10.0,1);
   if ( 总_223_do_1AC4_si99[总_328_in_3100]<0.1 )
   {
     总_223_do_1AC4_si99[总_328_in_3100] = 0.1;
   }
 }
 if ( 总_223_do_1AC4_si99[总_328_in_3100]<SymbolInfoDouble(总_336_st_3130,SYMBOL_VOLUME_MIN) )
 {
   总_223_do_1AC4_si99[总_328_in_3100] = SymbolInfoDouble(总_336_st_3130,SYMBOL_VOLUME_MIN);
 }
 if ( 总_223_do_1AC4_si99[总_328_in_3100]>SymbolInfoDouble(总_336_st_3130,SYMBOL_VOLUME_MAX) )
 {
   总_223_do_1AC4_si99[总_328_in_3100] = SymbolInfoDouble(总_336_st_3130,SYMBOL_VOLUME_MAX);
 }
 总_306_in_2884 = iBars(总_336_st_3130,NativeTimeframe(PERIOD_CURRENT)) ;
 if ( 总_131_do_328 * 总_229_do_1E00<总_337_do_3140 )
 {
   总_131_do_328 = 总_337_do_3140 / 总_229_do_1E00 ;
 }
 总_307_do_2888 = AccountInfoDouble(ACCOUNT_BALANCE) ;
 总_221_do_1A80 = (double)SymbolInfoInteger(总_336_st_3130,SYMBOL_TRADE_STOPS_LEVEL) * 总_337_do_3140 ;
 总_309_do_2898 = (double)SymbolInfoInteger(总_336_st_3130,SYMBOL_TRADE_FREEZE_LEVEL) * 总_337_do_3140 ;
 总_299_st_2850 = StringSubstr(Symbol(),6,10) ;
 if ( 总_299_st_2850 != "" )
 {
   Print("Suffix detected: " + 总_299_st_2850); 
 }
 if ( ( StringFind(Symbol(),"XAUUSD",0) >= 0 || StringFind(Symbol(),"xauusd",0) >= 0 || StringFind(Symbol(),"GOLD",0) >= 0 || StringFind(Symbol(),"gold",0) >= 0 || StringFind(Symbol(),"Gold",0) >= 0 || StringFind(Symbol(),"GLD",0) >= 0 ) )
 {
   总_336_st_3130 = Symbol() ;
   总_347_st_4144_si99[总_378_in_5D80] = Symbol();
   lizong_37(); 
   lizong_6(0); 
   总_378_in_5D80 ++;
 }
 else
 {
   总_336_st_3130 = Symbol() ;
   lizong_6(0); 
 }
 // Original dump contains no separate pair-initialisation failure message here.
 if ( 总_100_do_230<=0.0 )
 {
   总_100_do_230 = 1.0 ;
 }
 if ( 总_101_do_238<=0.0 )
 {
   总_101_do_238 = 1.0 ;
 }
 if ( 总_114_do_2B0>总_113_do_2A8 )
 {
   总_114_do_2B0 = 总_113_do_2A8 + 0.1 ;
 }
 if ( 总_36_in_B0<总_309_do_2898 / 总_229_do_1E00 )
 {
   总_36_in_B0 = (int)(总_309_do_2898 / 总_229_do_1E00) ;
 }
 if ( 总_103_do_250!=0.0 && 总_103_do_250<总_309_do_2898 / 总_229_do_1E00 )
 {
   总_103_do_250 = 总_309_do_2898 / 总_229_do_1E00 ;
 }
 if ( 总_103_do_250!=0.0 && 总_103_do_250<总_221_do_1A80 / 总_229_do_1E00 )
 {
   总_103_do_250 = 总_221_do_1A80 / 总_229_do_1E00 ;
 }
 if ( 总_125_do_2F8>0.0 && 总_126_do_300<总_309_do_2898 / 总_229_do_1E00 )
 {
   总_126_do_300 = 总_309_do_2898 / 总_229_do_1E00 ;
 }
 if ( 总_125_do_2F8>0.0 && 总_126_do_300<总_221_do_1A80 / 总_229_do_1E00 )
 {
   总_126_do_300 = 总_221_do_1A80 / 总_229_do_1E00 ;
 }
 if ( 总_100_do_230<总_221_do_1A80 * 2.0 / 总_229_do_1E00 )
 {
   总_100_do_230 = 总_221_do_1A80 * 2.0 / 总_229_do_1E00 ;
 }
 if ( 总_101_do_238<总_221_do_1A80 * 2.0 / 总_229_do_1E00 )
 {
   总_101_do_238 = 总_221_do_1A80 * 2.0 / 总_229_do_1E00 ;
 }
 if ( 总_80_do_198<总_221_do_1A80 * 2.0 / 总_229_do_1E00 )
 {
   总_80_do_198 = 总_221_do_1A80 * 2.0 / 总_229_do_1E00 ;
 }
 if ( 总_73_in_17C <  1 )
 {
   总_73_in_17C = 1 ;
 }
 if ( 总_74_in_180 <  1 )
 {
   总_74_in_180 = 1 ;
 }
 if ( 总_80_do_198<0.1 )
 {
   总_80_do_198 = 0.1 ;
 }
 总_234_in_1E20=总_89_in_1D8 * 60 * 60;
 if ( 总_89_in_1D8 >  0 )
 {
   总_302_da_2870=TimeCurrent() + 总_234_in_1E20;
 }
 else
 {
   总_302_da_2870 = 0 ;
 }
 if ( Virtual_expiration )
 {
   总_302_da_2870 = 0 ;
 }
 总_320_bo_28E8 = false ;
 总_260_do_2570 = CurrentSecond() ;
 总_319_da_28E0 = TimeCurrent() ;
 总_194_bo_530 = false ;
 总_195_bo_531 = false ;
 总_258_in_2568 = CurrentMonth() ;
 总_313_da_28B8 = iTime(总_336_st_3130,NativeTimeframe(PERIOD_W1),1) ;
 总_314_da_28C0 = iTime(总_336_st_3130,NativeTimeframe(PERIOD_M1),1) ;
 总_315_da_28C8 = iTime(总_336_st_3130,NativeTimeframe(PERIOD_M1),1) ;
 if ( 总_37_do_B8>g_MaxSpread_rw )
 {
   总_37_do_B8 = g_MaxSpread_rw ;
 }
 总_257_bo_2565 = false ;
 lizong_11(总_71_in_174); 
 lizong_12(总_71_in_174); 
 总_188_do_508 = NormalizeDouble(总_262_do_2580,总_190_in_518) ;
 总_189_do_510 = NormalizeDouble(总_261_do_2578,总_190_in_518) ;
 总_250_in_2518 = 0 ;
 总_256_bo_2564 = false ;
 总_304_in_287C = (int)(总_125_do_2F8 * 60.0) ;
 总_139_bo_3EC = false ;
 总_303_bo_2878 = true ;
 总_309_do_2898 = (double)SymbolInfoInteger(总_336_st_3130,SYMBOL_TRADE_FREEZE_LEVEL) * 总_337_do_3140 ;
 if ( !(总_171_bo_4BC) )
 {
   总_303_bo_2878 = false ;
 }
 总_191_do_520 = 0.0 ;
 总_201_do_16B8 = 0.0 ;
 总_202_do_16C0 = 0.0 ;
 总_240_bo_1E42 = false ;
 总_299_st_2850 = StringSubstr(总_336_st_3130,6,0) ;
 if ( Risk >  0 )
 {
   总_139_bo_3EC = true ;
 }
 if ( g_startLots_rw<0.0 )
 {
   g_startLots_rw = 0.01 ;
 }
 if ( 总_141_do_3F8>SymbolInfoDouble(总_336_st_3130,SYMBOL_VOLUME_MAX) )
 {
   总_141_do_3F8 = SymbolInfoDouble(总_336_st_3130,SYMBOL_VOLUME_MAX) ;
 }
 for (子_4_in = 0 ; 子_4_in < 总_199_in_16B0 ; 子_4_in ++)
 {
   for (子_5_in = 0 ; 子_5_in < 2 ; 子_5_in ++)
   {
     总_196_do_568_si20si2[子_4_in][子_5_in] = 0.0;
   }
 }
 for (子_6_in = 0 ; 子_6_in < 总_200_in_16B4 ; 子_6_in ++)
 {
   for (子_7_in = 0 ; 子_7_in < 3 ; 子_7_in ++)
   {
     总_197_do_6DC_si100si3[子_6_in][子_7_in] = 0.0;
   }
 }
 for (子_8_in = 0 ; 子_8_in < 100 ; 子_8_in ++)
 {
   总_197_do_6DC_si100si3[子_8_in][0] = 0.0;
   总_197_do_6DC_si100si3[子_8_in][1] = 0.0;
 }
 总_305_bo_2880 = false ;
 总_272_do_25C8 = NativeFractalValue(总_336_st_3130,0,1,1) ;
 总_273_do_25D0 = NativeFractalValue(总_336_st_3130,0,2,1) ;
 总_270_do_25B8 = 总_272_do_25C8 ;
 总_271_do_25C0 = 总_273_do_25D0 ;
 总_275_do_25E0 = 0.0 ;
 总_231_bo_1E0C = false ;
 总_290_in_262C = CurrentHour() ;
 总_289_in_2628 = 0 ;
 总_252_st_2528=ST1_Comment + "B1";
 总_253_st_2538=ST1_Comment + "B2";
 总_254_st_2548=ST1_Comment + "S1";
 总_255_st_2558=ST1_Comment + "S2";
 总_297_in_2848 = 0 ;
 总_298_in_284C = 0 ;
 总_267_in_25A0 = CurrentHour() ;
 if ( 总_67_bo_158 )
 {
   总_86_in_1C8 = 1 ;
   总_278_bo_25F8 = true ;
   总_279_bo_25F9 = true ;
 }
 总_209_do_16F0 = 999.0 ;
 总_210_do_16F8 = 0.0 ;
 总_300_do_2860 = 0.0 ;
 总_301_do_2868 = 0.0 ;
 for (子_9_in = 0 ; 子_9_in < 99 ; 子_9_in ++)
 {
   总_322_in_2AE0_si99[子_9_in] = 0;
   总_321_in_2920_si99[子_9_in] = 0;
   总_215_da_174C_si99[子_9_in] = iTime(总_336_st_3130,NativeTimeframe(总_71_in_174),1);
   if ( !(总_223_do_1AC4_si99[子_9_in]<g_startLots_rw) )   continue;
   总_223_do_1AC4_si99[子_9_in] = g_startLots_rw;
   
 }
 总_216_lo_1A68 = 0 ;
 总_238_bo_1E40 = false ;
 总_239_bo_1E41 = false ;
 if ( 总_63_in_140 == 1 )
 {
   总_64_do_148 = 0.0 ;
 }
 总_190_in_518 = (int)(double)SymbolInfoInteger(总_336_st_3130,SYMBOL_DIGITS) ;
 总_312_bo_28B0 = false ;
 if ( 临_bo_1 == true )
 {
   总_312_bo_28B0 = true ;
 }
 if ( ShowInfoPanel )
 {
   if ( 总_152_in_43C == 1 )
   {
     lizong_33(); 
   }
   else
   {
     if ( 总_152_in_43C == 2 )
     {
       lizong_34(); 
     }
   }
   lizong_24(); 
   lizong_27(); 
   lizong_29(); 
 }
 return(0); 
 }
//init <<==--------   --------
 bool DumpBacktestSpeedAllowTick()
 {
  if ( !(g_backtestSpeedEnabled) )   return(true);

  bool 临_skip = false;
  if ( g_backtestSpeedFast )
  {
    datetime 临_now = TimeCurrent();
    if ( 临_now > g_backtestSpeedLastTime + 1 )
    {
      g_backtestSpeedLastTime = TimeCurrent();
      临_skip = false;
    }
    else
    {
      临_skip = true;
    }
  }
  else
  {
    // speed_super: only a new closed M1 bar is accepted.
    临_skip = true;
  }

  datetime 临_m1 = iTime(Symbol(),PERIOD_M1,1);
  if ( 临_m1 > g_backtestSpeedLastM1 )
  {
    g_backtestSpeedLastM1 = iTime(Symbol(),PERIOD_M1,1);
    return(true);
  }
  if ( 临_skip )   return(false);
  return(true);
 }
//DumpBacktestSpeedAllowTick <<==--------   --------

 void OnTick()
 {
  bool      子_1_bo;
  double    子_2_do;
  double    子_3_do;
  bool      子_4_bo;
  MqlDateTime 子_5_a_129;
  MqlDateTime 子_6_a_129;
//----- -----
 bool       临_bo_1;
 double     临_do_2;
 double     临_do_3;
 int        临_in_4;
 double     临_do_5;
 double     临_do_6;
 int        临_in_7;
 double     临_do_8;
 double     临_do_9;
 int        临_in_10;
 double     临_do_11;
 double     临_do_12;
 int        临_in_13;
 double     临_do_14;
 double     临_do_15;
 int        临_in_16;
 double     临_do_17;
 double     临_do_18;
 int        临_in_19;
 double     临_do_20;
 double     临_do_21;
 int        临_in_22;
 double     临_do_23;
 double     临_do_24;
 int        临_in_25;
 double     临_do_26;
 double     临_do_27;
 int        临_in_28;

 // Original JIT exits before any trading/risk work when tester speed rejects the tick.
 if ( !(DumpBacktestSpeedAllowTick()) )   return;

 总_401_do_6AD0 = AccountInfoDouble(ACCOUNT_BALANCE) ;
 if ( UseEquity )
 {
   总_401_do_6AD0 = AccountInfoDouble(ACCOUNT_EQUITY) ;
 }
 if ( OnlyUp && 总_402_do_6AD8>总_401_do_6AD0 )
 {
   总_401_do_6AD0 = 总_402_do_6AD8 ;
 }
 if ( 总_401_do_6AD0>总_402_do_6AD8 )
 {
   总_402_do_6AD8 = 总_401_do_6AD0 ;
   GlobalVariableSet("HighestBalance",总_402_do_6AD8) ;
 }
 if ( ManualBalance>0.0 )
 {
   总_401_do_6AD0 = ManualBalance ;
 }
 if ( FakeOutFilter == 0 )
 {
   总_53_bo_11C = false ;
   总_57_bo_12C = false ;
   总_61_bo_13C = false ;
 }
 else
 {
   if ( FakeOutFilter == 1 )
   {
     总_53_bo_11C = true ;
     总_57_bo_12C = false ;
     总_61_bo_13C = false ;
   }
   else
   {
     if ( FakeOutFilter == 2 )
     {
       总_53_bo_11C = true ;
       总_57_bo_12C = true ;
       总_61_bo_13C = false ;
     }
     else
     {
       if ( FakeOutFilter == 3 )
       {
         总_53_bo_11C = true ;
         总_57_bo_12C = true ;
         总_61_bo_13C = true ;
       }
     }
   }
 }
 子_1_bo = false ;
 if ( lizong_48() )
 {
   总_395_in_6760 = Broker_GMT_OFFSET_Summer ;
   if ( ( !(总_392_bo_675C) || !(总_394_bo_675E) ) && AutoGMT && !(子_1_bo) )
   {
     总_392_bo_675C = true ;
     总_393_bo_675D = true ;
     总_396_in_6764 = lizong_47() ;
     if ( 总_396_in_6764 == 999 )
     {
       Print("GMT_Offset wrongly detected.  Trying againg!"); 
       Sleep(2000); 
       总_396_in_6764 = lizong_47() ;
     }
     if ( 总_396_in_6764 == 999 )
     {
       Print("GMT_Offset still wrong.  Using VPS time for GMT detection!"); 
     }
     总_394_bo_675E = true ;
     子_1_bo = true ;
     Print("DST_US on"); 
   }
 }
 else
 {
   总_395_in_6760 = Broker_GMT_OFFSET_Winter ;
   if ( ( 总_392_bo_675C || !(总_394_bo_675E) ) && AutoGMT && !(子_1_bo) )
   {
     总_392_bo_675C = false ;
     总_393_bo_675D = false ;
     总_396_in_6764 = lizong_47() ;
     if ( 总_396_in_6764 == 999 )
     {
       Print("GMT_Offset wrongly detected.  Trying againg!"); 
       Sleep(2000); 
       总_396_in_6764 = lizong_47() ;
     }
     if ( 总_396_in_6764 == 999 )
     {
       Print("GMT_Offset still wrong.  Using VPS time for GMT detection!"); 
     }
     总_394_bo_675E = true ;
     子_1_bo = true ;
     Print("DST_US off"); 
   }
 }
 TimeToStruct(StringToTime(string(DateYear(TimeCurrent())) + ".03.31 01:00"),子_5_a_129); 
 TimeToStruct(StringToTime(string(DateYear(TimeCurrent())) + ".10.31 02:00"),子_6_a_129); 
 if ( DateDayOfYear(TimeCurrent()) >  DateDayOfYear(StringToTime(string(DateYear(TimeCurrent())) + ".03.31 01:00") - 子_5_a_129.day_of_week * 86400) && DateDayOfYear(TimeCurrent()) <  DateDayOfYear(StringToTime(string(DateYear(TimeCurrent())) + ".10.31 02:00") - 子_6_a_129.day_of_week * 86400) )
 {
   临_bo_1 = true;
 }
 else
 {
   临_bo_1 = false;
 }
 if ( 临_bo_1 )
 {
   if ( ( !(总_393_bo_675D) || !(总_394_bo_675E) ) && AutoGMT && !(子_1_bo) )
   {
     总_393_bo_675D = true ;
     总_396_in_6764 = lizong_47() ;
     if ( 总_396_in_6764 == 999 )
     {
       Print("GMT_Offset wrongly detected.  Trying againg!"); 
       Sleep(2000); 
       总_396_in_6764 = lizong_47() ;
     }
     if ( 总_396_in_6764 == 999 )
     {
       Print("GMT_Offset still wrong.  Using VPS time for GMT detection!"); 
     }
     总_394_bo_675E = true ;
     子_1_bo = true ;
     Print("DST_EU on"); 
   }
 }
 else
 {
   if ( ( 总_393_bo_675D || !(总_394_bo_675E) ) && AutoGMT && !(子_1_bo) )
   {
     总_393_bo_675D = false ;
     总_396_in_6764 = lizong_47() ;
     if ( 总_396_in_6764 == 999 )
     {
       Print("GMT_Offset wrongly detected.  Trying againg!"); 
       Sleep(2000); 
       总_396_in_6764 = lizong_47() ;
     }
     if ( 总_396_in_6764 == 999 )
     {
       Print("GMT_Offset still wrong.  Using VPS time for GMT detection!"); 
     }
     总_394_bo_675E = true ;
     子_1_bo = true ;
     Print("DST_EU off"); 
   }
 }
 if ( AutoGMT && MQLInfoInteger(MQL_TESTER) != 1 )
 {
   if ( 总_396_in_6764 != 999 )
   {
     总_390_da_5DC0=TimeCurrent() - 总_396_in_6764 * 3600;
   }
   else
   {
     总_390_da_5DC0 = TimeGMT() ;
   }
 }
 else
 {
   总_390_da_5DC0=TimeCurrent() - 总_395_in_6760 * 3600;
 }
 // Original V4.6 live-calendar cache: refresh after 900 seconds, or immediately
 // whenever no event is cached.  Tester bypasses this path and uses hardcoded dates.
 if ( EnableNFP_Filter && UseMQL5Calendar && MQLInfoInteger(MQL_TESTER) != 1 )
 {
   datetime 临_nfpRefreshNow = TimeTradeServer();
   if ( 临_nfpRefreshNow > g_nfpCalendarLastRefresh + 900 || g_nextNFPCalendar == 0 )
   {
     g_nextNFPCalendar = GetNextNFPFromCalendar();
     g_nfpCalendarLastRefresh = TimeTradeServer();
   }
 }
 if ( TradeFrequency == 5 && Risk == 1234 )
 {
   子_2_do = lizong_36(AccountInfoDouble(ACCOUNT_BALANCE)) ;
   子_3_do = MaxAllowedDD / 100.0 * 子_2_do ;
   if ( 子_3_do>总_388_in_5DB4 )
   {
     总_19_in_9C = 3 ;
   }
   else
   {
     if ( 子_3_do>总_387_in_5DB0 )
     {
       总_19_in_9C = 2 ;
     }
     else
     {
       if ( 子_3_do>总_386_in_5DAC )
       {
         总_19_in_9C = 1 ;
       }
       else
       {
         总_19_in_9C = 0 ;
       }
     }
   }
 }
 else
 {
   总_19_in_9C = TradeFrequency ;
 }
 if ( 总_19_in_9C == 0 )
 {
   总_27_bo_A7 = false ;
   总_31_bo_AB = false ;
   总_28_bo_A8 = false ;
   总_33_bo_AD = false ;
   总_34_bo_AE = false ;
   总_32_bo_AC = false ;
   总_398_do_6770 = 2.4 ;
   if ( UseVariableValues )
   {
     总_398_do_6770 = 3.0 ;
   }
 }
 else
 {
   if ( 总_19_in_9C == 1 )
   {
     总_27_bo_A7 = true ;
     总_31_bo_AB = true ;
     总_28_bo_A8 = false ;
     总_33_bo_AD = false ;
     总_34_bo_AE = false ;
     总_32_bo_AC = false ;
     总_398_do_6770 = 3.4 ;
     if ( UseVariableValues )
     {
       总_398_do_6770 = 4.0 ;
     }
   }
   else
   {
     if ( 总_19_in_9C == 2 )
     {
       总_27_bo_A7 = true ;
       总_31_bo_AB = true ;
       总_28_bo_A8 = true ;
       总_33_bo_AD = true ;
       总_34_bo_AE = false ;
       总_32_bo_AC = false ;
       总_398_do_6770 = 4.1 ;
       if ( UseVariableValues )
       {
         总_398_do_6770 = 5.0 ;
       }
     }
     else
     {
       if ( 总_19_in_9C == 3 )
       {
         总_27_bo_A7 = true ;
         总_31_bo_AB = true ;
         总_28_bo_A8 = true ;
         总_33_bo_AD = true ;
         总_34_bo_AE = true ;
         总_32_bo_AC = false ;
         总_398_do_6770 = 4.8 ;
         if ( UseVariableValues )
         {
           总_398_do_6770 = 5.6 ;
         }
       }
       else
       {
         if ( 总_19_in_9C == 4 )
         {
           总_27_bo_A7 = true ;
           总_31_bo_AB = true ;
           总_28_bo_A8 = true ;
           总_33_bo_AD = true ;
           总_34_bo_AE = true ;
           总_32_bo_AC = true ;
           总_398_do_6770 = 5.1 ;
           if ( UseVariableValues )
           {
             总_398_do_6770 = 6.0 ;
           }
         }
         else
         {
           if ( 总_19_in_9C == 6 )
           {
             总_20_bo_A0 = RunStrat1 ;
             总_23_bo_A3 = RunStrat2 ;
             总_26_bo_A6 = RunStrat3 ;
             总_27_bo_A7 = RunStrat4 ;
             总_31_bo_AB = RunStrat5 ;
             总_28_bo_A8 = RunStrat6 ;
             总_33_bo_AD = RunStrat7 ;
             总_34_bo_AE = RunStrat8 ;
             总_32_bo_AC = RunStrat9 ;
           }
         }
       }
     }
   }
 }
 if ( iBars(总_336_st_3130,NativeTimeframe(PERIOD_D1)) != 总_383_in_5D9C )
 {
   总_383_in_5D9C = iBars(总_336_st_3130,NativeTimeframe(PERIOD_D1)) ;
   总_382_bo_5D98 = false ;
   总_384_do_5DA0 = 0.0 ;
 }
 if ( PropFirmMaxDailyDD>0.0 )
 {
   lizong_46(); 
 }
 if ( 总_382_bo_5D98 || !(总_380_bo_5D90) )   return;
 子_4_bo = false ;
 if ( 总_399_da_6778 != iTime(总_336_st_3130,NativeTimeframe(PERIOD_H1),1) )
 {
   子_4_bo = true ;
   总_399_da_6778 = iTime(总_336_st_3130,NativeTimeframe(PERIOD_H1),1) ;
 }
 if ( ( StringFind(Symbol(),"XAUUSD",0) >= 0 || StringFind(Symbol(),"xauusd",0) >= 0 || StringFind(Symbol(),"GOLD",0) >= 0 || StringFind(Symbol(),"GLD",0) >= 0 || StringFind(Symbol(),"gold",0) >= 0 || StringFind(Symbol(),"Gold",0) >= 0 ) )
 {
   总_336_st_3130 = Symbol() ;
   if ( 总_20_bo_A0 )
   {
     lizong_37(); 
     lizong_6(0); 
     lizong_7(0); 
     if ( 子_4_bo )
     {
       if ( MQLInfoInteger(MQL_TESTER) == 1 && !(UpdateInfoTesting) )
       {
         临_do_2 = 0.0;
       }
       else
       {
         临_do_3 = 0.0;
         总_343_in_372C_si99[总_328_in_3100] = 0;
         for (临_in_4 = NativeHistoryTotal() ; 临_in_4 >= 0 ; 临_in_4=临_in_4 - 1)
         {
           if ( g_trade_view.Select(临_in_4,NATIVE_SELECT_BY_POSITION,NATIVE_HISTORY_POOL) != true || g_trade_view.SymbolName() != 总_336_st_3130 || g_trade_view.Magic() != 总_93_in_1F0 )   continue;
           
           if ( ( g_trade_view.OrderType() != ORDER_TYPE_BUY && g_trade_view.OrderType() != ORDER_TYPE_SELL ) )   continue;
           总_343_in_372C_si99[总_328_in_3100] ++;
           临_do_3 = 临_do_3 + g_trade_view.Profit() + g_trade_view.Swap() + g_trade_view.Commission();
           
         }
         临_do_2 = 临_do_3;
       }
       总_400_do_67B4_si99[0] = 临_do_2;
       if ( 总_400_do_67B4_si99[0]!=0.0 && 总_343_in_372C_si99[0] >  0 )
       {
         总_345_do_3AAC_si99[0] = 总_400_do_67B4_si99[0] / 总_343_in_372C_si99[0];
       }
     }
   }
   if ( 总_27_bo_A7 )
   {
     lizong_38(); 
     lizong_6(3); 
     lizong_7(3); 
     if ( 子_4_bo )
     {
       if ( MQLInfoInteger(MQL_TESTER) == 1 && !(UpdateInfoTesting) )
       {
         临_do_5 = 0.0;
       }
       else
       {
         临_do_6 = 0.0;
         总_343_in_372C_si99[总_328_in_3100] = 0;
         for (临_in_7 = NativeHistoryTotal() ; 临_in_7 >= 0 ; 临_in_7=临_in_7 - 1)
         {
           if ( g_trade_view.Select(临_in_7,NATIVE_SELECT_BY_POSITION,NATIVE_HISTORY_POOL) != true || g_trade_view.SymbolName() != 总_336_st_3130 || g_trade_view.Magic() != 总_93_in_1F0 )   continue;
           
           if ( ( g_trade_view.OrderType() != ORDER_TYPE_BUY && g_trade_view.OrderType() != ORDER_TYPE_SELL ) )   continue;
           总_343_in_372C_si99[总_328_in_3100] ++;
           临_do_6 = 临_do_6 + g_trade_view.Profit() + g_trade_view.Swap() + g_trade_view.Commission();
           
         }
         临_do_5 = 临_do_6;
       }
       总_400_do_67B4_si99[3] = 临_do_5;
       if ( 总_400_do_67B4_si99[3]!=0.0 && 总_343_in_372C_si99[3] >  0 )
       {
         总_345_do_3AAC_si99[3] = 总_400_do_67B4_si99[3] / 总_343_in_372C_si99[3];
       }
     }
   }
   if ( 总_23_bo_A3 )
   {
     lizong_39(); 
     lizong_6(1); 
     lizong_7(1); 
     if ( 子_4_bo )
     {
       if ( MQLInfoInteger(MQL_TESTER) == 1 && !(UpdateInfoTesting) )
       {
         临_do_8 = 0.0;
       }
       else
       {
         临_do_9 = 0.0;
         总_343_in_372C_si99[总_328_in_3100] = 0;
         for (临_in_10 = NativeHistoryTotal() ; 临_in_10 >= 0 ; 临_in_10=临_in_10 - 1)
         {
           if ( g_trade_view.Select(临_in_10,NATIVE_SELECT_BY_POSITION,NATIVE_HISTORY_POOL) != true || g_trade_view.SymbolName() != 总_336_st_3130 || g_trade_view.Magic() != 总_93_in_1F0 )   continue;
           
           if ( ( g_trade_view.OrderType() != ORDER_TYPE_BUY && g_trade_view.OrderType() != ORDER_TYPE_SELL ) )   continue;
           总_343_in_372C_si99[总_328_in_3100] ++;
           临_do_9 = 临_do_9 + g_trade_view.Profit() + g_trade_view.Swap() + g_trade_view.Commission();
           
         }
         临_do_8 = 临_do_9;
       }
       总_400_do_67B4_si99[1] = 临_do_8;
       if ( 总_400_do_67B4_si99[1]!=0.0 && 总_343_in_372C_si99[1] >  0 )
       {
         总_345_do_3AAC_si99[1] = 总_400_do_67B4_si99[1] / 总_343_in_372C_si99[1];
       }
     }
   }
   if ( 总_26_bo_A6 )
   {
     lizong_40(); 
     lizong_6(2); 
     lizong_7(2); 
     if ( 子_4_bo )
     {
       if ( MQLInfoInteger(MQL_TESTER) == 1 && !(UpdateInfoTesting) )
       {
         临_do_11 = 0.0;
       }
       else
       {
         临_do_12 = 0.0;
         总_343_in_372C_si99[总_328_in_3100] = 0;
         for (临_in_13 = NativeHistoryTotal() ; 临_in_13 >= 0 ; 临_in_13=临_in_13 - 1)
         {
           if ( g_trade_view.Select(临_in_13,NATIVE_SELECT_BY_POSITION,NATIVE_HISTORY_POOL) != true || g_trade_view.SymbolName() != 总_336_st_3130 || g_trade_view.Magic() != 总_93_in_1F0 )   continue;
           
           if ( ( g_trade_view.OrderType() != ORDER_TYPE_BUY && g_trade_view.OrderType() != ORDER_TYPE_SELL ) )   continue;
           总_343_in_372C_si99[总_328_in_3100] ++;
           临_do_12 = 临_do_12 + g_trade_view.Profit() + g_trade_view.Swap() + g_trade_view.Commission();
           
         }
         临_do_11 = 临_do_12;
       }
       总_400_do_67B4_si99[2] = 临_do_11;
       if ( 总_400_do_67B4_si99[2]!=0.0 && 总_343_in_372C_si99[2] >  0 )
       {
         总_345_do_3AAC_si99[2] = 总_400_do_67B4_si99[2] / 总_343_in_372C_si99[2];
       }
     }
   }
   if ( 总_28_bo_A8 )
   {
     lizong_41(); 
     lizong_6(5); 
     lizong_7(5); 
     if ( 子_4_bo )
     {
       if ( MQLInfoInteger(MQL_TESTER) == 1 && !(UpdateInfoTesting) )
       {
         临_do_14 = 0.0;
       }
       else
       {
         临_do_15 = 0.0;
         总_343_in_372C_si99[总_328_in_3100] = 0;
         for (临_in_16 = NativeHistoryTotal() ; 临_in_16 >= 0 ; 临_in_16=临_in_16 - 1)
         {
           if ( g_trade_view.Select(临_in_16,NATIVE_SELECT_BY_POSITION,NATIVE_HISTORY_POOL) != true || g_trade_view.SymbolName() != 总_336_st_3130 || g_trade_view.Magic() != 总_93_in_1F0 )   continue;
           
           if ( ( g_trade_view.OrderType() != ORDER_TYPE_BUY && g_trade_view.OrderType() != ORDER_TYPE_SELL ) )   continue;
           总_343_in_372C_si99[总_328_in_3100] ++;
           临_do_15 = 临_do_15 + g_trade_view.Profit() + g_trade_view.Swap() + g_trade_view.Commission();
           
         }
         临_do_14 = 临_do_15;
       }
       总_400_do_67B4_si99[5] = 临_do_14;
       if ( 总_400_do_67B4_si99[5]!=0.0 && 总_343_in_372C_si99[5] >  0 )
       {
         总_345_do_3AAC_si99[5] = 总_400_do_67B4_si99[5] / 总_343_in_372C_si99[5];
       }
     }
   }
   if ( 总_31_bo_AB )
   {
     lizong_42(); 
     lizong_6(4); 
     lizong_7(4); 
     if ( 子_4_bo )
     {
       if ( MQLInfoInteger(MQL_TESTER) == 1 && !(UpdateInfoTesting) )
       {
         临_do_17 = 0.0;
       }
       else
       {
         临_do_18 = 0.0;
         总_343_in_372C_si99[总_328_in_3100] = 0;
         for (临_in_19 = NativeHistoryTotal() ; 临_in_19 >= 0 ; 临_in_19=临_in_19 - 1)
         {
           if ( g_trade_view.Select(临_in_19,NATIVE_SELECT_BY_POSITION,NATIVE_HISTORY_POOL) != true || g_trade_view.SymbolName() != 总_336_st_3130 || g_trade_view.Magic() != 总_93_in_1F0 )   continue;
           
           if ( ( g_trade_view.OrderType() != ORDER_TYPE_BUY && g_trade_view.OrderType() != ORDER_TYPE_SELL ) )   continue;
           总_343_in_372C_si99[总_328_in_3100] ++;
           临_do_18 = 临_do_18 + g_trade_view.Profit() + g_trade_view.Swap() + g_trade_view.Commission();
           
         }
         临_do_17 = 临_do_18;
       }
       总_400_do_67B4_si99[4] = 临_do_17;
       if ( 总_400_do_67B4_si99[4]!=0.0 && 总_343_in_372C_si99[4] >  0 )
       {
         总_345_do_3AAC_si99[4] = 总_400_do_67B4_si99[4] / 总_343_in_372C_si99[4];
       }
     }
   }
   if ( 总_32_bo_AC )
   {
     lizong_43(); 
     lizong_6(8); 
     lizong_7(8); 
     if ( 子_4_bo )
     {
       if ( MQLInfoInteger(MQL_TESTER) == 1 && !(UpdateInfoTesting) )
       {
         临_do_20 = 0.0;
       }
       else
       {
         临_do_21 = 0.0;
         总_343_in_372C_si99[总_328_in_3100] = 0;
         for (临_in_22 = NativeHistoryTotal() ; 临_in_22 >= 0 ; 临_in_22=临_in_22 - 1)
         {
           if ( g_trade_view.Select(临_in_22,NATIVE_SELECT_BY_POSITION,NATIVE_HISTORY_POOL) != true || g_trade_view.SymbolName() != 总_336_st_3130 || g_trade_view.Magic() != 总_93_in_1F0 )   continue;
           
           if ( ( g_trade_view.OrderType() != ORDER_TYPE_BUY && g_trade_view.OrderType() != ORDER_TYPE_SELL ) )   continue;
           总_343_in_372C_si99[总_328_in_3100] ++;
           临_do_21 = 临_do_21 + g_trade_view.Profit() + g_trade_view.Swap() + g_trade_view.Commission();
           
         }
         临_do_20 = 临_do_21;
       }
       总_400_do_67B4_si99[8] = 临_do_20;
       if ( 总_400_do_67B4_si99[8]!=0.0 && 总_343_in_372C_si99[8] >  0 )
       {
         总_345_do_3AAC_si99[8] = 总_400_do_67B4_si99[8] / 总_343_in_372C_si99[8];
       }
     }
   }
   if ( 总_33_bo_AD )
   {
     lizong_44(); 
     lizong_6(6); 
     lizong_7(6); 
     if ( 子_4_bo )
     {
       if ( MQLInfoInteger(MQL_TESTER) == 1 && !(UpdateInfoTesting) )
       {
         临_do_23 = 0.0;
       }
       else
       {
         临_do_24 = 0.0;
         总_343_in_372C_si99[总_328_in_3100] = 0;
         for (临_in_25 = NativeHistoryTotal() ; 临_in_25 >= 0 ; 临_in_25=临_in_25 - 1)
         {
           if ( g_trade_view.Select(临_in_25,NATIVE_SELECT_BY_POSITION,NATIVE_HISTORY_POOL) != true || g_trade_view.SymbolName() != 总_336_st_3130 || g_trade_view.Magic() != 总_93_in_1F0 )   continue;
           
           if ( ( g_trade_view.OrderType() != ORDER_TYPE_BUY && g_trade_view.OrderType() != ORDER_TYPE_SELL ) )   continue;
           总_343_in_372C_si99[总_328_in_3100] ++;
           临_do_24 = 临_do_24 + g_trade_view.Profit() + g_trade_view.Swap() + g_trade_view.Commission();
           
         }
         临_do_23 = 临_do_24;
       }
       总_400_do_67B4_si99[6] = 临_do_23;
       if ( 总_400_do_67B4_si99[6]!=0.0 && 总_343_in_372C_si99[6] >  0 )
       {
         总_345_do_3AAC_si99[6] = 总_400_do_67B4_si99[6] / 总_343_in_372C_si99[6];
       }
     }
   }
   if ( 总_34_bo_AE )
   {
     lizong_45(); 
     lizong_6(7); 
     lizong_7(7); 
     if ( 子_4_bo )
     {
       if ( MQLInfoInteger(MQL_TESTER) == 1 && !(UpdateInfoTesting) )
       {
         临_do_26 = 0.0;
       }
       else
       {
         临_do_27 = 0.0;
         总_343_in_372C_si99[总_328_in_3100] = 0;
         for (临_in_28 = NativeHistoryTotal() ; 临_in_28 >= 0 ; 临_in_28=临_in_28 - 1)
         {
           if ( g_trade_view.Select(临_in_28,NATIVE_SELECT_BY_POSITION,NATIVE_HISTORY_POOL) != true || g_trade_view.SymbolName() != 总_336_st_3130 || g_trade_view.Magic() != 总_93_in_1F0 )   continue;
           
           if ( ( g_trade_view.OrderType() != ORDER_TYPE_BUY && g_trade_view.OrderType() != ORDER_TYPE_SELL ) )   continue;
           总_343_in_372C_si99[总_328_in_3100] ++;
           临_do_27 = 临_do_27 + g_trade_view.Profit() + g_trade_view.Swap() + g_trade_view.Commission();
           
         }
         临_do_26 = 临_do_27;
       }
       总_400_do_67B4_si99[7] = 临_do_26;
       if ( 总_400_do_67B4_si99[7]!=0.0 && 总_343_in_372C_si99[7] >  0 )
       {
         总_345_do_3AAC_si99[7] = 总_400_do_67B4_si99[7] / 总_343_in_372C_si99[7];
       }
     }
   }
 }
 else
 {
   总_336_st_3130 = Symbol() ;
   lizong_7(0); 
 }
 lizong_27(); 
 if ( iTime(Symbol(),PERIOD_M5,1) != 总_379_da_5D88 )
 {
   总_379_da_5D88 = iTime(Symbol(),PERIOD_M5,1) ;
   lizong_28(); 
   lizong_29(); 
 }
 总_381_in_5D94 ++;
 if ( 总_381_in_5D94 < 2 )
 {
   return;
 }
 总_318_do_28D8 = AccountInfoDouble(ACCOUNT_BALANCE) ; // JIT sync: original LastLotResizeBalance snapshots ACCOUNT_BALANCE
 总_381_in_5D94 = 0 ;
 }
//OnTick <<==--------   --------
void OnDeinit(const int reason)
{
 lizong_26(); 
 NativeReleaseIndicatorHandles();
}
//deinit <<==--------   --------

// Original V4.6 dump has no custom OnTradeTransaction withdrawal adjustment.
 void lizong_6( int 木_0_in)
 {
 // -----------------------------------------------------------------
 // Recovered from the original MetaTester64 full-memory dump/JIT.
 // The V6 readiness gate copies 100 ATR values, sets the buffer as series
 // and touches [1]. The native handle is reused for the same parameters;
 // the copied values and gate behavior remain unchanged.
 // -----------------------------------------------------------------
 总_5_in_18 = NativeGetATRHandle(总_336_st_3130,NativeTimeframe(总_4_in_14),总_3_in_10) ;
 if ( 总_5_in_18 < 0 )
 {
   Print("The creation of iATR has failed: Runtime error =" + IntegerToString(GetLastError()));
   return;
 }
 if ( CopyBuffer(总_5_in_18,0,0,100,总_6_do_1C_ko) == 0 )
 {
   return;
 }
 ArraySetAsSeries(总_6_do_1C_ko,true);
 // Original JIT contains the bounds check for element [1].
 总_2_do_8 = 总_6_do_1C_ko[1];

 // Original JIT first derives the variable-value ratio, then selects
 // either that ratio or 1.0 according to UseVariableValues.  The 1000
 // threshold and the absence of NormalizeDouble() on entry offsets are
 // both visible in the dump (e.g. -170 -> -402.49625 at ratio 2.367625).
 double 临_variableRatio = 1.0 ;
 if ( 总_7_do_50>=1000.0 )
 {
   临_variableRatio = iOpen(总_336_st_3130,NativeTimeframe(PERIOD_D1),1) / 总_7_do_50 ;
 }
 if ( UseVariableValues )
 {
   总_8_do_58 = 临_variableRatio ;
 }
 else
 {
   总_8_do_58 = 1.0 ;
 }
 if ( AdjustLotsizeToVariableValues )
 {
   总_9_do_60 = 1.0 / 总_8_do_58 ;
 }
 else
 {
   总_9_do_60 = 1.0 ;
 }
 if ( 总_8_do_58==0.0 )
 {
   总_8_do_58 = 1.0 ;
 }


 总_328_in_3100 = 木_0_in ;

 // The original explicitly checks that a current tick is available.
 // Failure is logged, but execution continues exactly as in the dump.
 MqlTick 临_tick;
 if ( !(SymbolInfoTick(总_336_st_3130,临_tick)) )
 {
   Print("Tick not ok");
 }

 总_337_do_3140 = SymbolInfoDouble(总_336_st_3130,SYMBOL_POINT) ;
 总_229_do_1E00 = 总_337_do_3140 ;
 if ( ( (double)SymbolInfoInteger(总_336_st_3130,SYMBOL_DIGITS)==3.0 || (double)SymbolInfoInteger(总_336_st_3130,SYMBOL_DIGITS)==5.0 ) )
 {
   总_229_do_1E00 = 总_337_do_3140 * 10.0 ;
 }
 if ( SymbolInfoInteger(总_336_st_3130,SYMBOL_DIGITS) == 0x1 )
 {
   总_229_do_1E00 = 总_337_do_3140 / 10.0 ;
 }
 总_190_in_518 = (int)(double)SymbolInfoInteger(总_336_st_3130,SYMBOL_DIGITS) ;
 总_1_do_0 = SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK) - SymbolInfoDouble(总_336_st_3130,SYMBOL_BID) ;
 总_221_do_1A80 = (double)SymbolInfoInteger(总_336_st_3130,SYMBOL_TRADE_STOPS_LEVEL) * 总_337_do_3140 ;
 总_309_do_2898 = (double)SymbolInfoInteger(总_336_st_3130,SYMBOL_TRADE_FREEZE_LEVEL) * 总_337_do_3140 ;

 // Recovered working-value transform from original JIT.  The nine strategy
 // setup functions rewrite every raw field before lizong_6(), so in-place use
 // is behaviorally safe for fields without an explicit shadow in the rebuild.
 g_MaxSpread_rw = MaxSpread * 总_8_do_58 ;
 总_80_do_198 = 总_80_do_198 * 总_8_do_58 ;
 总_83_do_1B0 = 总_83_do_1B0 * 总_8_do_58 ;
 总_84_do_1B8 = 总_84_do_1B8 * 总_8_do_58 ;
 总_88_do_1D0 = 总_88_do_1D0 * 总_8_do_58 ;
 总_100_do_230 = 总_100_do_230 * 总_8_do_58 ;
 总_101_do_238 = 总_101_do_238 * 总_8_do_58 ;
 总_103_do_250 = 总_103_do_250 * 总_8_do_58 ;
 总_104_do_258 = 总_104_do_258 * 总_8_do_58 ;
 总_105_do_260 = 总_105_do_260 * 总_8_do_58 ;
 总_106_do_268 = 总_106_do_268 * 总_8_do_58 ;
 // Original keeps raw trailing-TP settings and writes scaled shadows.
 总_110_do_288 = 总_108_do_278 * 总_8_do_58 ;
 总_111_do_290 = 总_109_do_280 * 总_8_do_58 ;
 总_113_do_2A8 = 总_113_do_2A8 * 总_8_do_58 ;
 总_114_do_2B0 = 总_114_do_2B0 * 总_8_do_58 ;

 // These clamps are part of lizong_6() in the original JIT and therefore
 // must run for every strategy, not only once during OnInit().
 if ( 总_100_do_230<=0.0 )
 {
   总_100_do_230 = 1.0 ;
 }
 if ( 总_101_do_238<=0.0 )
 {
   总_101_do_238 = 1.0 ;
 }
 if ( 总_114_do_2B0>总_113_do_2A8 )
 {
   总_114_do_2B0 = 总_113_do_2A8 + 0.1 ;
 }
 if ( 总_37_do_B8>g_MaxSpread_rw )
 {
   总_37_do_B8 = g_MaxSpread_rw ;
 }
 if ( 总_36_in_B0<总_309_do_2898 / 总_229_do_1E00 )
 {
   总_36_in_B0 = (int)(总_309_do_2898 / 总_229_do_1E00) ;
 }
 if ( 总_103_do_250!=0.0 && 总_103_do_250<总_309_do_2898 / 总_229_do_1E00 )
 {
   总_103_do_250 = 总_309_do_2898 / 总_229_do_1E00 ;
 }
 if ( 总_103_do_250!=0.0 && 总_103_do_250<总_221_do_1A80 / 总_229_do_1E00 )
 {
   总_103_do_250 = 总_221_do_1A80 / 总_229_do_1E00 ;
 }
 if ( 总_125_do_2F8>0.0 && 总_126_do_300<总_309_do_2898 / 总_229_do_1E00 )
 {
   总_126_do_300 = 总_309_do_2898 / 总_229_do_1E00 ;
 }
 if ( 总_125_do_2F8>0.0 && 总_126_do_300<总_221_do_1A80 / 总_229_do_1E00 )
 {
   总_126_do_300 = 总_221_do_1A80 / 总_229_do_1E00 ;
 }
 if ( 总_100_do_230<总_221_do_1A80 * 2.0 / 总_229_do_1E00 )
 {
   总_100_do_230 = 总_221_do_1A80 * 2.0 / 总_229_do_1E00 ;
 }
 if ( 总_101_do_238<总_221_do_1A80 * 2.0 / 总_229_do_1E00 )
 {
   总_101_do_238 = 总_221_do_1A80 * 2.0 / 总_229_do_1E00 ;
 }
 if ( 总_80_do_198<总_221_do_1A80 * 2.0 / 总_229_do_1E00 )
 {
   总_80_do_198 = 总_221_do_1A80 * 2.0 / 总_229_do_1E00 ;
 }
 if ( 总_73_in_17C < 1 )
 {
   总_73_in_17C = 1 ;
 }
 if ( 总_74_in_180 < 1 )
 {
   总_74_in_180 = 1 ;
 }
 if ( 总_80_do_198<0.1 )
 {
   总_80_do_198 = 0.1 ;
 }

 总_234_in_1E20=总_89_in_1D8 * 60 * 60;
 if ( 总_89_in_1D8 > 0 )
 {
   总_302_da_2870=TimeCurrent() + 总_234_in_1E20;
 }
 else
 {
   总_302_da_2870 = 0 ;
 }
 if ( Virtual_expiration )
 {
   总_302_da_2870 = 0 ;
 }
 }
//lizong_6 <<==--------   --------
 int lizong_7( int 木_0_in)
 {
  bool      子_2_bo;
  datetime  子_3_lo;
  int       子_4_in;
  int       子_5_in;
  string    子_6_st;
  datetime  子_7_da;
  int       子_8_in;
  int       子_9_in;
//----- -----
 int        临_in_1;
 int        临_in_2;
 int        临_in_3;
 int        临_in_4;
 int        临_in_5;
 int        临_in_6;
 int        临_in_7;
 int        临_in_8;
 int        临_in_9;
 int        临_in_10;
 int        临_in_11;
 int        临_in_12;
 int        临_in_13;
 int        临_in_14;
 int        临_in_15;
 int        临_in_16;
 int        临_in_17;
 int        临_in_18;
 int        临_in_19;
 int        临_in_20;
 int        临_in_21;
 int        临_in_22;
 int        临_in_23;
 int        临_in_24;
 int        临_in_25;
 int        临_in_26;
 int        临_in_27;
 int        临_in_28;
 int        临_in_29;
 int        临_in_30;
 int        临_in_31;
 int        临_in_32;
 int        临_in_33;
 int        临_in_34;
 int        临_in_35;
 int        临_in_36;
 int        临_in_37;
 int        临_in_38;
 int        临_in_39;
 int        临_in_40;
 int        临_in_41;
 int        临_in_42;
 int        临_in_43;
 int        临_in_44;
 int        临_in_45;
 int        临_in_46;
 int        临_in_47;
 int        临_in_48;
 int        临_in_49;
 int        临_in_50;
 int        临_in_51;
 int        临_in_52;
 int        临_in_53;
 int        临_in_54;
 int        临_in_55;
 int        临_in_56;
 int        临_in_57;
 int        临_in_58;
 int        临_in_59;
 int        临_in_60;
 int        临_in_61;
 int        临_in_62;
 int        临_in_63;
 int        临_in_64;
 int        临_in_65;
 int        临_in_66;
 int        临_in_67;
 int        临_in_68;
 int        临_in_69;
 int        临_in_70;
 int        临_in_71;
 int        临_in_72;
 int        临_in_73;
 int        临_in_74;
 int        临_in_75;
 int        临_in_76;
 int        临_in_77;
 int        临_in_78;
 int        临_in_79;
 int        临_in_80;
 int        临_in_81;
 int        临_in_82;
 int        临_in_83;
 int        临_in_84;
 int        临_in_85;
 int        临_in_86;
 int        临_in_87;
 int        临_in_88;
 int        临_in_89;
 double     临_do_90;
 long       临_lo_91;
 int        临_in_92;
 long       临_lo_93;
 int        临_in_94;
 int        临_in_95;
 int        临_in_96;
 double     临_do_97;
 long       临_lo_98;
 int        临_in_99;
 long       临_lo_100;
 int        临_in_101;
 int        临_in_102;
 int        临_in_103;
 int        临_in_104;
 int        临_in_105;
 bool       临_bo_106;
 int        临_in_107;
 int        临_in_108;
 bool       临_bo_109;
 int        临_in_110;
 long       临_lo_111;
 int        临_in_112;
 long       临_lo_113;
 string     临_st_114;

 总_328_in_3100 = 木_0_in ;
 子_2_bo = false ;
 
 if ( 总_81_do_1A0>0.0 )
 {
   总_80_do_198 = 总_81_do_1A0 / 100.0 * SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK) * 10.0 ;
 }
 bool 临_tradeAllowedForManagement = ((NativeSessionMarket(总_336_st_3130)?1.0:0.0)!=0.0);
 if ( 总_99_in_22C == 0 )
 {
   if ( 临_tradeAllowedForManagement )
   {
     if ( lizong_18() )
     {
       子_2_bo = true ;
     }
     if ( lizong_19() )
     {
       子_2_bo = true ;
     }
     if ( 子_2_bo )
     {
       return(0); 
     }
   }
 }
 else
 {
   // Do not consume the management-timeframe marker while the broker session
   // is still quote-only/closed.  The first trade-enabled tick must retry the
   // same bar, exactly when the original Market EA can also place pending orders.
   if ( 临_tradeAllowedForManagement &&
        总_321_in_2920_si99[总_328_in_3100] != iBars(总_336_st_3130,NativeTimeframe(总_99_in_22C)) )
   {
     总_321_in_2920_si99[总_328_in_3100] = iBars(总_336_st_3130,NativeTimeframe(总_99_in_22C));
     if ( lizong_18() )
     {
       子_2_bo = true ;
     }
     if ( lizong_19() )
     {
       子_2_bo = true ;
     }
     if ( 子_2_bo )
     {
       return(0); 
     }
   }
 }
 lizong_22(false); 
 if ( (NativeSessionMarket(总_336_st_3130)?1.0:0.0)==0.0 )
 {
   总_256_bo_2564 = true ;
   return(0); 
 }
 if ( 总_68_in_15C >  0 && ( ( CurrentHour() == 0 && CurrentMinute() < 总_68_in_15C ) || (CurrentHour() == 23 && 总_68_in_15C >  60 - 总_68_in_15C) ) )
 {
   if ( !(总_256_bo_2564) )
   {
     Print("DAYSWITCH -> Market might be closed... waiting " + string(总_68_in_15C) + " minutes before setting order.."); 
   }
   总_256_bo_2564 = true ;
   return(0); 
 }
 总_256_bo_2564 = false ;
 if ( 总_171_bo_4BC )
 {
   if ( lizong_20() && 总_303_bo_2878 )
   {
     if ( 总_173_bo_4C4 )
     {
       lizong_8(); 
     }
     总_303_bo_2878 = false ;
   }
   if ( !(lizong_20()) && !(总_303_bo_2878) )
   {
     Print("Weekend starting! closing trades.."); 
     if ( 总_173_bo_4C4 )
     {
       for (临_in_1 = 0 ; 临_in_1 < 总_200_in_16B4 ; 临_in_1=临_in_1 + 1)
       {
         for (临_in_2 = 0 ; 临_in_2 < 2 ; 临_in_2=临_in_2 + 1)
         {
           总_197_do_6DC_si100si3[临_in_1][临_in_2] = 0.0;
         }
       }
       临_in_3 = 0;
       for (临_in_4 = NativeTradesTotal() ; 临_in_4 >= 0 ; 临_in_4=临_in_4 - 1)
       {
         if ( g_trade_view.Select(临_in_4,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true || g_trade_view.Magic() != 总_93_in_1F0 || g_trade_view.SymbolName() != 总_336_st_3130 )   continue;
         
         if ( ( g_trade_view.OrderType() != ORDER_TYPE_BUY_STOP && g_trade_view.OrderType() != ORDER_TYPE_SELL_STOP ) )   continue;
         Print("Storing pending order nr " + string(g_trade_view.Ticket())); 
         总_197_do_6DC_si100si3[临_in_3][1] = g_trade_view.OrderType();
         总_197_do_6DC_si100si3[临_in_3][0] = g_trade_view.PriceOpen();
         总_197_do_6DC_si100si3[临_in_3][2] = g_trade_view.Volume();
         临_in_3=临_in_3 + 1;
         
       }
     }
     临_in_5 = 1;
     for (临_in_6 = NativeTradesTotal() ; 临_in_6 >= 0 ; 临_in_6=临_in_6 - 1)
     {
       if ( g_trade_view.Select(临_in_6,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true || g_trade_view.Magic() != 总_93_in_1F0 || g_trade_view.SymbolName() != 总_336_st_3130 || g_trade_view.OrderType() != ORDER_TYPE_BUY_STOP )   continue;
       NativeDeletePending(g_trade_view.Ticket(),0xFFFFFFFF); 
       
     }
     if ( 临_in_5 == 2 )
     {
       for (临_in_7 = NativeTradesTotal() ; 临_in_7 >= 0 ; 临_in_7=临_in_7 - 1)
       {
         if ( g_trade_view.Select(临_in_7,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true || g_trade_view.Magic() != 总_96_in_208 || g_trade_view.SymbolName() != 总_336_st_3130 || g_trade_view.OrderType() != ORDER_TYPE_BUY_STOP )   continue;
         NativeDeletePending(g_trade_view.Ticket(),0xFFFFFFFF); 
         
       }
     }
     临_in_8 = 1;
     for (临_in_9 = NativeTradesTotal() ; 临_in_9 >= 0 ; 临_in_9=临_in_9 - 1)
     {
       if ( g_trade_view.Select(临_in_9,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true || g_trade_view.Magic() != 总_93_in_1F0 || g_trade_view.SymbolName() != 总_336_st_3130 || g_trade_view.OrderType() != ORDER_TYPE_SELL_STOP )   continue;
       NativeDeletePending(g_trade_view.Ticket(),0xFFFFFFFF); 
       
     }
     if ( 临_in_8 == 2 )
     {
       for (临_in_10 = NativeTradesTotal() ; 临_in_10 >= 0 ; 临_in_10=临_in_10 - 1)
       {
         if ( g_trade_view.Select(临_in_10,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true || g_trade_view.Magic() != 总_96_in_208 || g_trade_view.SymbolName() != 总_336_st_3130 || g_trade_view.OrderType() != ORDER_TYPE_SELL_STOP )   continue;
         NativeDeletePending(g_trade_view.Ticket(),0xFFFFFFFF); 
         
       }
     }
     临_in_11 = 2;
     if(1==0) //条件不成立
     {
       do
       {
         if ( g_trade_view.Select(1,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true || g_trade_view.Magic() != 总_93_in_1F0 || g_trade_view.SymbolName() != 总_336_st_3130 || g_trade_view.OrderType() != ORDER_TYPE_BUY_STOP )   continue;
         NativeDeletePending(g_trade_view.Ticket(),0xFFFFFFFF); 
         
       }
       while( - 1 >= 0);
       
     }
     if ( 临_in_11 == 2 )
     {
       for (临_in_12 = NativeTradesTotal() ; 临_in_12 >= 0 ; 临_in_12=临_in_12 - 1)
       {
         if ( g_trade_view.Select(临_in_12,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true || g_trade_view.Magic() != 总_96_in_208 || g_trade_view.SymbolName() != 总_336_st_3130 || g_trade_view.OrderType() != ORDER_TYPE_BUY_STOP )   continue;
         NativeDeletePending(g_trade_view.Ticket(),0xFFFFFFFF); 
         
       }
     }
     临_in_13 = 2;
     if(1==0) //条件不成立
     {
       do
       {
         if ( g_trade_view.Select(1,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true || g_trade_view.Magic() != 总_93_in_1F0 || g_trade_view.SymbolName() != 总_336_st_3130 || g_trade_view.OrderType() != ORDER_TYPE_SELL_STOP )   continue;
         NativeDeletePending(g_trade_view.Ticket(),0xFFFFFFFF); 
         
       }
       while( - 1 >= 0);
       
     }
     if ( 临_in_13 == 2 )
     {
       for (临_in_14 = NativeTradesTotal() ; 临_in_14 >= 0 ; 临_in_14=临_in_14 - 1)
       {
         if ( g_trade_view.Select(临_in_14,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true || g_trade_view.Magic() != 总_96_in_208 || g_trade_view.SymbolName() != 总_336_st_3130 || g_trade_view.OrderType() != ORDER_TYPE_SELL_STOP )   continue;
         NativeDeletePending(g_trade_view.Ticket(),0xFFFFFFFF); 
         
       }
     }
     总_303_bo_2878 = true ;
     return(0); 
   }
 }
 if ( EnableNFP_Filter )
 {
   bool 临_nfpLiveCalendar = (UseMQL5Calendar && MQLInfoInteger(MQL_TESTER) != 1 && g_nextNFPCalendar != 0);
   // Exact original fallback rule: if live Calendar is disabled/unavailable (timestamp=0),
   // continue into the hardcoded table; after 2026 use the first-Friday fallback.
   if ( 临_nfpLiveCalendar || CurrentYear() <= 2026 )
   {
     子_3_lo = 0 ;
     子_5_in = 0 ;
     datetime 临_nfpCompareNow = TimeCurrent();
     if ( 临_nfpLiveCalendar )
     {
       // Calendar timestamps are already in trade-server time. No GMT conversion here.
       子_3_lo = g_nextNFPCalendar;
     }
     else
     {
       for (子_4_in = 0 ; 子_4_in < 300 ; 子_4_in ++)
       {
         临_in_15 = DateYear(总_391_da_5DFC_si300[子_4_in]);
         if ( 临_in_15 != CurrentYear() )   continue;
         临_in_16 = DateMonth(总_391_da_5DFC_si300[子_4_in]);
         if ( 临_in_16 != CurrentMonth() )   continue;
         子_3_lo = 总_391_da_5DFC_si300[子_4_in] ;
         break;
       }
       // Hardcoded table is GMT-based: NFP is 13:30 GMT in US winter, 12:30 in DST.
       子_5_in = 60 ;
       if ( lizong_48() )   子_5_in = 0 ;
       临_nfpCompareNow = 总_390_da_5DC0;
     }
     if ( 临_nfpCompareNow >= 子_3_lo - NFP_MinutesBefore * 60 + 子_5_in * 60 && 临_nfpCompareNow <= 子_3_lo + NFP_MinutesAfter * 60 + 子_5_in * 60 )
     {
       if ( NFP_ClosePendingOrders )
       {
         临_in_17 = 1;
         for (临_in_18 = NativeTradesTotal() ; 临_in_18 >= 0 ; 临_in_18=临_in_18 - 1)
         {
           if ( g_trade_view.Select(临_in_18,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true || g_trade_view.Magic() != 总_93_in_1F0 || g_trade_view.SymbolName() != 总_336_st_3130 || g_trade_view.OrderType() != ORDER_TYPE_BUY_STOP )   continue;
           NativeDeletePending(g_trade_view.Ticket(),0xFFFFFFFF); 
           
         }
         if ( 临_in_17 == 2 )
         {
           for (临_in_19 = NativeTradesTotal() ; 临_in_19 >= 0 ; 临_in_19=临_in_19 - 1)
           {
             if ( g_trade_view.Select(临_in_19,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true || g_trade_view.Magic() != 总_96_in_208 || g_trade_view.SymbolName() != 总_336_st_3130 || g_trade_view.OrderType() != ORDER_TYPE_BUY_STOP )   continue;
             NativeDeletePending(g_trade_view.Ticket(),0xFFFFFFFF); 
             
           }
         }
         临_in_20 = 1;
         for (临_in_21 = NativeTradesTotal() ; 临_in_21 >= 0 ; 临_in_21=临_in_21 - 1)
         {
           if ( g_trade_view.Select(临_in_21,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true || g_trade_view.Magic() != 总_93_in_1F0 || g_trade_view.SymbolName() != 总_336_st_3130 || g_trade_view.OrderType() != ORDER_TYPE_SELL_STOP )   continue;
           NativeDeletePending(g_trade_view.Ticket(),0xFFFFFFFF); 
           
         }
         if ( 临_in_20 == 2 )
         {
           for (临_in_22 = NativeTradesTotal() ; 临_in_22 >= 0 ; 临_in_22=临_in_22 - 1)
           {
             if ( g_trade_view.Select(临_in_22,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true || g_trade_view.Magic() != 总_96_in_208 || g_trade_view.SymbolName() != 总_336_st_3130 || g_trade_view.OrderType() != ORDER_TYPE_SELL_STOP )   continue;
             NativeDeletePending(g_trade_view.Ticket(),0xFFFFFFFF); 
             
           }
         }
         临_in_23 = 2;
         if(1==0) //条件不成立
         {
           do
           {
             if ( g_trade_view.Select(1,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true || g_trade_view.Magic() != 总_93_in_1F0 || g_trade_view.SymbolName() != 总_336_st_3130 || g_trade_view.OrderType() != ORDER_TYPE_BUY_STOP )   continue;
             NativeDeletePending(g_trade_view.Ticket(),0xFFFFFFFF); 
             
           }
           while( - 1 >= 0);
           
         }
         if ( 临_in_23 == 2 )
         {
           for (临_in_24 = NativeTradesTotal() ; 临_in_24 >= 0 ; 临_in_24=临_in_24 - 1)
           {
             if ( g_trade_view.Select(临_in_24,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true || g_trade_view.Magic() != 总_96_in_208 || g_trade_view.SymbolName() != 总_336_st_3130 || g_trade_view.OrderType() != ORDER_TYPE_BUY_STOP )   continue;
             NativeDeletePending(g_trade_view.Ticket(),0xFFFFFFFF); 
             
           }
         }
         临_in_25 = 2;
         if(1==0) //条件不成立
         {
           do
           {
             if ( g_trade_view.Select(1,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true || g_trade_view.Magic() != 总_93_in_1F0 || g_trade_view.SymbolName() != 总_336_st_3130 || g_trade_view.OrderType() != ORDER_TYPE_SELL_STOP )   continue;
             NativeDeletePending(g_trade_view.Ticket(),0xFFFFFFFF); 
             
           }
           while( - 1 >= 0);
           
         }
         if ( 临_in_25 == 2 )
         {
           for (临_in_26 = NativeTradesTotal() ; 临_in_26 >= 0 ; 临_in_26=临_in_26 - 1)
           {
             if ( g_trade_view.Select(临_in_26,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true || g_trade_view.Magic() != 总_96_in_208 || g_trade_view.SymbolName() != 总_336_st_3130 || g_trade_view.OrderType() != ORDER_TYPE_SELL_STOP )   continue;
             NativeDeletePending(g_trade_view.Ticket(),0xFFFFFFFF); 
             
           }
         }
       }
       if ( NFP_CloseOpenTrades )
       {
         for (临_in_27 = NativeTradesTotal() ; 临_in_27 >= 0 ; 临_in_27=临_in_27 - 1)
         {
           if ( g_trade_view.Select(临_in_27,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true || g_trade_view.SymbolName() != 总_336_st_3130 )   continue;
           临_in_28 = g_trade_view.Magic();
           临_in_29=ST1_MagicNumber + 1;
           if ( 临_in_28 != 临_in_29 )
           {
             临_in_29 = g_trade_view.Magic();
             临_in_30=ST1_MagicNumber + 2;
             if ( 临_in_29 != 临_in_30 )
             {
               临_in_30 = g_trade_view.Magic();
               临_in_31=ST1_MagicNumber + 3;
               if ( 临_in_30 != 临_in_31 )
               {
                 临_in_31 = g_trade_view.Magic();
                 临_in_32=ST1_MagicNumber + 4;
                 if ( 临_in_31 != 临_in_32 )
                 {
                   临_in_32 = g_trade_view.Magic();
                   临_in_33=ST1_MagicNumber + 5;
                   if ( 临_in_32 != 临_in_33 )
                   {
                     临_in_33 = g_trade_view.Magic();
                     临_in_34=ST1_MagicNumber + 6;
                     if ( 临_in_33 != 临_in_34 )
                     {
                       临_in_34 = g_trade_view.Magic();
                       临_in_35=ST1_MagicNumber + 7;
                       if ( 临_in_34 != 临_in_35 )
                       {
                         临_in_35 = g_trade_view.Magic();
                         临_in_36=ST1_MagicNumber + 8;
                         if ( 临_in_35 != 临_in_36 )
                         {
                           临_in_36 = g_trade_view.Magic();
                           临_in_37=ST1_MagicNumber + 9;
                           if ( 临_in_36 != 临_in_37 )
                           {
                             临_in_37 = g_trade_view.Magic();
                             临_in_38=ST1_MagicNumber + 10;
                             if ( 临_in_37 != 临_in_38 )
                             {
                               临_in_38 = g_trade_view.Magic();
                               临_in_39=ST1_MagicNumber + 11;
                               if ( 临_in_38 != 临_in_39 )
                               {
                                 临_in_39 = g_trade_view.Magic();
                                 临_in_40=ST1_MagicNumber + 12;
                                 if ( 临_in_39 != 临_in_40 )
                                 {
                                   临_in_40 = g_trade_view.Magic();
                                   临_in_41=ST1_MagicNumber + 13;
                                   if ( 临_in_40 != 临_in_41 )
                                   {
                                     临_in_41 = g_trade_view.Magic();
                                     临_in_42=ST1_MagicNumber + 14;
                                     if ( 临_in_41 != 临_in_42 )
                                     {
                                       临_in_42 = g_trade_view.Magic();
                                       临_in_43=ST1_MagicNumber + 15;
                                     if ( 临_in_42 != 临_in_43 )   continue;
                                     }
                                   }
                                 }
                               }
                             }
                           }
                         }
                       }
                     }
                   }
                 }
               }
             }
           }
           if ( g_trade_view.OrderType() == ORDER_TYPE_BUY )
           {
             NativeClosePosition(g_trade_view.Ticket(),g_trade_view.Volume(),SymbolInfoDouble(总_336_st_3130,SYMBOL_BID),99999,clrRed); 
           }
           if ( g_trade_view.OrderType() != ORDER_TYPE_SELL )   continue;
           NativeClosePosition(g_trade_view.Ticket(),g_trade_view.Volume(),SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK),99999,clrRed); 
           
         }
       }
       if ( !(总_320_bo_28E8) )
       {
         Print("NFP!! deleting trades!!"); 
       }
       总_320_bo_28E8 = true ;
     }
     else
     {
       总_320_bo_28E8 = false ;
     }
   }
   else
   {
     if ( CurrentDay() <= 7 && CurrentDayOfWeek() == 5 )
     {
       子_6_st = IntegerToString(CurrentYear(),0,32) + IntegerToString(CurrentMonth(),0,32) + IntegerToString(CurrentDay(),0,32) + " " + IntegerToString(0x4CE,0,32) ;
       子_7_da = StringToTime(子_6_st) ;
       if ( 总_390_da_5DC0 >= 子_7_da - NFP_MinutesBefore * 60 && 总_390_da_5DC0 <= 子_7_da + NFP_MinutesAfter * 60 )
       {
         if ( NFP_ClosePendingOrders )
         {
           临_in_44 = 1;
           for (临_in_45 = NativeTradesTotal() ; 临_in_45 >= 0 ; 临_in_45=临_in_45 - 1)
           {
             if ( g_trade_view.Select(临_in_45,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true || g_trade_view.Magic() != 总_93_in_1F0 || g_trade_view.SymbolName() != 总_336_st_3130 || g_trade_view.OrderType() != ORDER_TYPE_BUY_STOP )   continue;
             NativeDeletePending(g_trade_view.Ticket(),0xFFFFFFFF); 
             
           }
           if ( 临_in_44 == 2 )
           {
             for (临_in_46 = NativeTradesTotal() ; 临_in_46 >= 0 ; 临_in_46=临_in_46 - 1)
             {
               if ( g_trade_view.Select(临_in_46,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true || g_trade_view.Magic() != 总_96_in_208 || g_trade_view.SymbolName() != 总_336_st_3130 || g_trade_view.OrderType() != ORDER_TYPE_BUY_STOP )   continue;
               NativeDeletePending(g_trade_view.Ticket(),0xFFFFFFFF); 
               
             }
           }
           临_in_47 = 1;
           for (临_in_48 = NativeTradesTotal() ; 临_in_48 >= 0 ; 临_in_48=临_in_48 - 1)
           {
             if ( g_trade_view.Select(临_in_48,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true || g_trade_view.Magic() != 总_93_in_1F0 || g_trade_view.SymbolName() != 总_336_st_3130 || g_trade_view.OrderType() != ORDER_TYPE_SELL_STOP )   continue;
             NativeDeletePending(g_trade_view.Ticket(),0xFFFFFFFF); 
             
           }
           if ( 临_in_47 == 2 )
           {
             for (临_in_49 = NativeTradesTotal() ; 临_in_49 >= 0 ; 临_in_49=临_in_49 - 1)
             {
               if ( g_trade_view.Select(临_in_49,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true || g_trade_view.Magic() != 总_96_in_208 || g_trade_view.SymbolName() != 总_336_st_3130 || g_trade_view.OrderType() != ORDER_TYPE_SELL_STOP )   continue;
               NativeDeletePending(g_trade_view.Ticket(),0xFFFFFFFF); 
               
             }
           }
           临_in_50 = 2;
           if(1==0) //条件不成立
           {
             do
             {
               if ( g_trade_view.Select(1,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true || g_trade_view.Magic() != 总_93_in_1F0 || g_trade_view.SymbolName() != 总_336_st_3130 || g_trade_view.OrderType() != ORDER_TYPE_BUY_STOP )   continue;
               NativeDeletePending(g_trade_view.Ticket(),0xFFFFFFFF); 
               
             }
             while( - 1 >= 0);
             
           }
           if ( 临_in_50 == 2 )
           {
             for (临_in_51 = NativeTradesTotal() ; 临_in_51 >= 0 ; 临_in_51=临_in_51 - 1)
             {
               if ( g_trade_view.Select(临_in_51,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true || g_trade_view.Magic() != 总_96_in_208 || g_trade_view.SymbolName() != 总_336_st_3130 || g_trade_view.OrderType() != ORDER_TYPE_BUY_STOP )   continue;
               NativeDeletePending(g_trade_view.Ticket(),0xFFFFFFFF); 
               
             }
           }
           临_in_52 = 2;
           if(1==0) //条件不成立
           {
             do
             {
               if ( g_trade_view.Select(1,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true || g_trade_view.Magic() != 总_93_in_1F0 || g_trade_view.SymbolName() != 总_336_st_3130 || g_trade_view.OrderType() != ORDER_TYPE_SELL_STOP )   continue;
               NativeDeletePending(g_trade_view.Ticket(),0xFFFFFFFF); 
               
             }
             while( - 1 >= 0);
             
           }
           if ( 临_in_52 == 2 )
           {
             for (临_in_53 = NativeTradesTotal() ; 临_in_53 >= 0 ; 临_in_53=临_in_53 - 1)
             {
               if ( g_trade_view.Select(临_in_53,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true || g_trade_view.Magic() != 总_96_in_208 || g_trade_view.SymbolName() != 总_336_st_3130 || g_trade_view.OrderType() != ORDER_TYPE_SELL_STOP )   continue;
               NativeDeletePending(g_trade_view.Ticket(),0xFFFFFFFF); 
               
             }
           }
         }
         if ( NFP_CloseOpenTrades )
         {
           for (临_in_54 = NativeTradesTotal() ; 临_in_54 >= 0 ; 临_in_54=临_in_54 - 1)
           {
             if ( g_trade_view.Select(临_in_54,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true || g_trade_view.SymbolName() != 总_336_st_3130 )   continue;
             临_in_55 = g_trade_view.Magic();
             临_in_56=ST1_MagicNumber + 1;
             if ( 临_in_55 != 临_in_56 )
             {
               临_in_56 = g_trade_view.Magic();
               临_in_57=ST1_MagicNumber + 2;
               if ( 临_in_56 != 临_in_57 )
               {
                 临_in_57 = g_trade_view.Magic();
                 临_in_58=ST1_MagicNumber + 3;
                 if ( 临_in_57 != 临_in_58 )
                 {
                   临_in_58 = g_trade_view.Magic();
                   临_in_59=ST1_MagicNumber + 4;
                   if ( 临_in_58 != 临_in_59 )
                   {
                     临_in_59 = g_trade_view.Magic();
                     临_in_60=ST1_MagicNumber + 5;
                     if ( 临_in_59 != 临_in_60 )
                     {
                       临_in_60 = g_trade_view.Magic();
                       临_in_61=ST1_MagicNumber + 6;
                       if ( 临_in_60 != 临_in_61 )
                       {
                         临_in_61 = g_trade_view.Magic();
                         临_in_62=ST1_MagicNumber + 7;
                         if ( 临_in_61 != 临_in_62 )
                         {
                           临_in_62 = g_trade_view.Magic();
                           临_in_63=ST1_MagicNumber + 8;
                           if ( 临_in_62 != 临_in_63 )
                           {
                             临_in_63 = g_trade_view.Magic();
                             临_in_64=ST1_MagicNumber + 9;
                             if ( 临_in_63 != 临_in_64 )
                             {
                               临_in_64 = g_trade_view.Magic();
                               临_in_65=ST1_MagicNumber + 10;
                               if ( 临_in_64 != 临_in_65 )
                               {
                                 临_in_65 = g_trade_view.Magic();
                                 临_in_66=ST1_MagicNumber + 11;
                                 if ( 临_in_65 != 临_in_66 )
                                 {
                                   临_in_66 = g_trade_view.Magic();
                                   临_in_67=ST1_MagicNumber + 12;
                                   if ( 临_in_66 != 临_in_67 )
                                   {
                                     临_in_67 = g_trade_view.Magic();
                                     临_in_68=ST1_MagicNumber + 13;
                                     if ( 临_in_67 != 临_in_68 )
                                     {
                                       临_in_68 = g_trade_view.Magic();
                                       临_in_69=ST1_MagicNumber + 14;
                                       if ( 临_in_68 != 临_in_69 )
                                       {
                                         临_in_69 = g_trade_view.Magic();
                                         临_in_70=ST1_MagicNumber + 15;
                                       if ( 临_in_69 != 临_in_70 )   continue;
                                       }
                                     }
                                   }
                                 }
                               }
                             }
                           }
                         }
                       }
                     }
                   }
                 }
               }
             }
             if ( g_trade_view.OrderType() == ORDER_TYPE_BUY )
             {
               NativeClosePosition(g_trade_view.Ticket(),g_trade_view.Volume(),SymbolInfoDouble(总_336_st_3130,SYMBOL_BID),99999,clrRed); 
             }
             if ( g_trade_view.OrderType() != ORDER_TYPE_SELL )   continue;
             NativeClosePosition(g_trade_view.Ticket(),g_trade_view.Volume(),SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK),99999,clrRed); 
             
           }
         }
         if ( !(总_320_bo_28E8) )
         {
           Print("NFP!! deleting trades!!"); 
         }
         总_320_bo_28E8 = true ;
       }
       else
       {
         总_320_bo_28E8 = false ;
       }
     }
   }
 }
 if ( 总_320_bo_28E8 )
 {
   return(0); 
 }
 if ( 总_45_bo_FC )
 {
   if ( CurrentDayOfWeek() == 5 && CurrentHour() >= FridayStopHour && !(总_305_bo_2880) )
   {
     for (临_in_71 = NativeTradesTotal() ; 临_in_71 >= 0 ; 临_in_71=临_in_71 - 1)
     {
       if ( g_trade_view.Select(临_in_71,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true || g_trade_view.SymbolName() != 总_336_st_3130 )   continue;
       临_in_72 = g_trade_view.Magic();
       临_in_73=ST1_MagicNumber + 1;
       if ( 临_in_72 != 临_in_73 )
       {
         临_in_73 = g_trade_view.Magic();
         临_in_74=ST1_MagicNumber + 2;
         if ( 临_in_73 != 临_in_74 )
         {
           临_in_74 = g_trade_view.Magic();
           临_in_75=ST1_MagicNumber + 3;
           if ( 临_in_74 != 临_in_75 )
           {
             临_in_75 = g_trade_view.Magic();
             临_in_76=ST1_MagicNumber + 4;
             if ( 临_in_75 != 临_in_76 )
             {
               临_in_76 = g_trade_view.Magic();
               临_in_77=ST1_MagicNumber + 5;
               if ( 临_in_76 != 临_in_77 )
               {
                 临_in_77 = g_trade_view.Magic();
                 临_in_78=ST1_MagicNumber + 6;
                 if ( 临_in_77 != 临_in_78 )
                 {
                   临_in_78 = g_trade_view.Magic();
                   临_in_79=ST1_MagicNumber + 7;
                   if ( 临_in_78 != 临_in_79 )
                   {
                     临_in_79 = g_trade_view.Magic();
                     临_in_80=ST1_MagicNumber + 8;
                     if ( 临_in_79 != 临_in_80 )
                     {
                       临_in_80 = g_trade_view.Magic();
                       临_in_81=ST1_MagicNumber + 9;
                       if ( 临_in_80 != 临_in_81 )
                       {
                         临_in_81 = g_trade_view.Magic();
                         临_in_82=ST1_MagicNumber + 10;
                         if ( 临_in_81 != 临_in_82 )
                         {
                           临_in_82 = g_trade_view.Magic();
                           临_in_83=ST1_MagicNumber + 11;
                           if ( 临_in_82 != 临_in_83 )
                           {
                             临_in_83 = g_trade_view.Magic();
                             临_in_84=ST1_MagicNumber + 12;
                             if ( 临_in_83 != 临_in_84 )
                             {
                               临_in_84 = g_trade_view.Magic();
                               临_in_85=ST1_MagicNumber + 13;
                               if ( 临_in_84 != 临_in_85 )
                               {
                                 临_in_85 = g_trade_view.Magic();
                                 临_in_86=ST1_MagicNumber + 14;
                                 if ( 临_in_85 != 临_in_86 )
                                 {
                                   临_in_86 = g_trade_view.Magic();
                                   临_in_87=ST1_MagicNumber + 15;
                                 if ( 临_in_86 != 临_in_87 )   continue;
                                 }
                               }
                             }
                           }
                         }
                       }
                     }
                   }
                 }
               }
             }
           }
         }
       }
       if ( FridayCloseOpen && g_trade_view.OrderType() == ORDER_TYPE_BUY )
       {
         NativeClosePosition(g_trade_view.Ticket(),g_trade_view.Volume(),SymbolInfoDouble(总_336_st_3130,SYMBOL_BID),(int)总_38_do_C0,clrRed); 
       }
       if ( FridayCloseOpen && g_trade_view.OrderType() == ORDER_TYPE_SELL )
       {
         NativeClosePosition(g_trade_view.Ticket(),g_trade_view.Volume(),SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK),(int)总_38_do_C0,clrRed); 
       }
       if ( ( g_trade_view.OrderType() != ORDER_TYPE_BUY_STOP && g_trade_view.OrderType() != ORDER_TYPE_SELL_STOP ) || !(FridayClosePending) )   continue;
       NativeDeletePending(g_trade_view.Ticket(),clrRed); 
       
     }
     Print("Weekend starting! closing trades.."); 
     总_305_bo_2880 = true ;
     return(0); 
   }
   if ( CurrentDayOfWeek() != 5 && 总_305_bo_2880 == true )
   {
     总_305_bo_2880 = false ;
     if ( 总_46_bo_FD )
     {
       lizong_8(); 
       return(0); 
     }
   }
 }
 总_1_do_0 = SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK) - SymbolInfoDouble(总_336_st_3130,SYMBOL_BID) ;
 if ( 总_35_bo_AF )
 {
   if ( 总_1_do_0>g_MaxSpread_rw * 总_229_do_1E00 )
   {
     lizong_9(); 
     return(0); 
   }
   if ( 总_1_do_0<=总_37_do_B8 * 总_229_do_1E00 && ( !(总_45_bo_FC) || CurrentDayOfWeek() != 5 || CurrentHour() <  FridayStopHour ) && ( !(总_171_bo_4BC) || lizong_20() ) )
   {
     lizong_8(); 
   }
 }
 if ( 总_69_in_160 == 1 )
 {
   临_in_88 = 0;
   for (临_in_89 = NativeTradesTotal() ; 临_in_89 >= 0 ; 临_in_89=临_in_89 - 1)
   {
     if ( g_trade_view.Select(临_in_89,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true || g_trade_view.Magic() != 总_93_in_1F0 || g_trade_view.SymbolName() != 总_336_st_3130 || g_trade_view.OrderType() != ORDER_TYPE_BUY_STOP )   continue;
     临_in_88=临_in_88 + 1;
     
   }
   if ( 临_in_88 >  总_86_in_1C8 )
   {
     临_do_90 = 0.0;
     临_lo_91 = 0;
     for (临_in_92 = NativeTradesTotal() ; 临_in_92 >= 0 ; 临_in_92=临_in_92 - 1)
     {
       if ( g_trade_view.Select(临_in_92,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true || g_trade_view.Magic() != 总_93_in_1F0 || g_trade_view.SymbolName() != 总_336_st_3130 || g_trade_view.OrderType() != ORDER_TYPE_BUY_STOP || !(g_trade_view.PriceOpen()>临_do_90) )   continue;
       临_lo_91 = g_trade_view.Ticket();
       临_do_90 = g_trade_view.PriceOpen();
       
     }
     if ( 临_lo_91 != 0 )
     {
       NativeDeletePending(临_lo_91,clrGreen); 
       临_lo_93 = 临_lo_91;
       for (临_in_94 = 0 ; 临_in_94 < 100 ; 临_in_94=临_in_94 + 1)
       {
         if ( !(总_198_do_1070_si100si2[临_in_94][0]==临_lo_93) )   continue;
         总_198_do_1070_si100si2[临_in_94][0] = 0.0;
         总_198_do_1070_si100si2[临_in_94][1] = 0.0;
         break;
         
       }
       Print("Max number of pending buy orders reached... deleting highest buystop order!"); 
     }
   }
   临_in_95 = 0;
   for (临_in_96 = NativeTradesTotal() ; 临_in_96 >= 0 ; 临_in_96=临_in_96 - 1)
   {
     if ( g_trade_view.Select(临_in_96,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true || g_trade_view.Magic() != 总_93_in_1F0 || g_trade_view.SymbolName() != 总_336_st_3130 || g_trade_view.OrderType() != ORDER_TYPE_SELL_STOP )   continue;
     临_in_95=临_in_95 + 1;
     
   }
   if ( 临_in_95 >  总_86_in_1C8 )
   {
     临_do_97 = 9999.0;
     临_lo_98 = 0;
     for (临_in_99 = NativeTradesTotal() ; 临_in_99 >= 0 ; 临_in_99=临_in_99 - 1)
     {
       if ( g_trade_view.Select(临_in_99,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true || g_trade_view.Magic() != 总_93_in_1F0 || g_trade_view.SymbolName() != 总_336_st_3130 || g_trade_view.OrderType() != ORDER_TYPE_SELL_STOP || !(g_trade_view.PriceOpen()<临_do_97) )   continue;
       临_lo_98 = g_trade_view.Ticket();
       临_do_97 = g_trade_view.PriceOpen();
       
     }
     if ( 临_lo_98 != 0 )
     {
       NativeDeletePending(临_lo_98,clrGreen); 
       临_lo_100 = 临_lo_98;
       for (临_in_101 = 0 ; 临_in_101 < 100 ; 临_in_101=临_in_101 + 1)
       {
         if ( !(总_198_do_1070_si100si2[临_in_101][0]==临_lo_100) )   continue;
         总_198_do_1070_si100si2[临_in_101][0] = 0.0;
         总_198_do_1070_si100si2[临_in_101][1] = 0.0;
         break;
         
       }
       Print("Max number of pending sell orders reached... deleting lowest sellstop order!"); 
     }
   }
 }
 if ( !(总_305_bo_2880) && 总_69_in_160 == 1 && !(总_303_bo_2878) )
 {
   if ( ( 总_322_in_2AE0_si99[总_328_in_3100] != iBars(总_336_st_3130,NativeTimeframe(总_72_in_178)) || 总_72_in_178 == 0 ) )
   {
     总_322_in_2AE0_si99[总_328_in_3100] = iBars(总_336_st_3130,NativeTimeframe(总_72_in_178));
     if ( 总_119_in_2D0 >  0 && 总_120_in_2D4 >= 0 )
     {
       总_241_do_1E78_si99[总_328_in_3100] = 总_123_do_2E0 * 总_229_do_1E00 + (lizong_13(总_117_in_2C8,总_119_in_2D0,总_120_in_2D4) + 总_1_do_0);
       总_242_do_21C4_si99[总_328_in_3100] = lizong_14(总_117_in_2C8,总_119_in_2D0,总_120_in_2D4) - 总_123_do_2E0 * 总_229_do_1E00;
     }
     if ( 总_187_in_504 >  0 )
     {
       子_8_in=MathRand() * 总_187_in_504 / 32768 + 1;
       总_15_in_78 = 子_8_in ;
     }
     if ( 总_63_in_140 != 1 )
     {
       临_in_102 = 0;
       for (临_in_103 = NativeTradesTotal() ; 临_in_103 >= 0 ; 临_in_103=临_in_103 - 1)
       {
         if ( g_trade_view.Select(临_in_103,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true || g_trade_view.Magic() != 总_93_in_1F0 || g_trade_view.SymbolName() != 总_336_st_3130 || g_trade_view.OrderType() != ORDER_TYPE_BUY )   continue;
         临_in_102=临_in_102 + 1;
         
       }
       if ( 临_in_102 == 0 )
       {
         临_in_104 = 0;
         for (临_in_105 = NativeTradesTotal() ; 临_in_105 >= 0 ; 临_in_105=临_in_105 - 1)
         {
           if ( g_trade_view.Select(临_in_105,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true || g_trade_view.Magic() != 总_93_in_1F0 || g_trade_view.SymbolName() != 总_336_st_3130 || g_trade_view.OrderType() != ORDER_TYPE_SELL )   continue;
           临_in_104=临_in_104 + 1;
           
         }
         if ( 临_in_104 == 0 )
         {
           临_bo_106 = false;
           for (临_in_107 = 0 ; 临_in_107 < 总_199_in_16B0 ; 临_in_107=临_in_107 + 1)
           {
             if ( !(总_196_do_568_si20si2[临_in_107][0]>0.0) )   continue;
             临_bo_106 = false;
             for (临_in_108 = NativeTradesTotal() ; 临_in_108 >= 0 ; 临_in_108=临_in_108 - 1)
             {
               if ( g_trade_view.Select(临_in_108,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true )   continue;
               
               if ( ( g_trade_view.OrderType() != ORDER_TYPE_BUY && g_trade_view.OrderType() != ORDER_TYPE_SELL ) || !(g_trade_view.Ticket()==总_196_do_568_si20si2[临_in_107][0]) )   continue;
               临_bo_106 = true;
               
             }
             if ( 临_bo_106 )   continue;
             总_196_do_568_si20si2[临_in_107][0] = 0.0;
             总_196_do_568_si20si2[临_in_107][1] = 0.0;
             
           }
         }
       }
     }
     for (子_9_in = 0 ; 子_9_in < 总_86_in_1C8 ; 子_9_in ++)
     {
       lizong_15(); 
     }
   }
   lizong_29(); 
   if ( 总_267_in_25A0 != CurrentHour() )
   {
     总_267_in_25A0 = CurrentHour() ;
     临_bo_109 = false;
     for (临_in_110 = 0 ; 临_in_110 < 100 ; 临_in_110=临_in_110 + 1)
     {
       临_lo_111 = (long)总_198_do_1070_si100si2[临_in_110][0];
       临_bo_109 = false;
       for (临_in_112 = NativeTradesTotal() ; 临_in_112 >= 0 ; 临_in_112=临_in_112 - 1)
       {
         if ( !(g_trade_view.Select(临_in_112,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL)) )   continue;
         临_lo_113 = g_trade_view.Ticket();
         if ( 临_lo_111 != 临_lo_113 )   continue;
         临_bo_109 = true;
         
       }
       if ( 临_bo_109 )   continue;
       总_198_do_1070_si100si2[临_in_110][0] = 0.0;
       总_198_do_1070_si100si2[临_in_110][1] = 0.0;
       
     }
   }
 }
 // The dump has no current-spread/pending-order Comment overlay in this path.
 return(0); 
 }
//lizong_7 <<==--------   --------
 void lizong_8()
 {
  int       子_1_in;
//----- -----
 double     临_do_1;
 long       临_lo_2;
 int        临_in_3;
 double     临_do_4;
 long       临_lo_5;
 int        临_in_6;
 double     临_do_7;
 long       临_lo_8;
 int        临_in_9;
 double     临_do_10;
 long       临_lo_11;
 int        临_in_12;
 int        临_in_13;

 for (子_1_in = 0 ; 子_1_in < 总_200_in_16B4 ; 子_1_in ++)
 {
   if ( !(总_197_do_6DC_si100si3[子_1_in][0]>0.0) )   continue;
   
   if ( 总_197_do_6DC_si100si3[子_1_in][1]==4.0 && SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK)<总_197_do_6DC_si100si3[子_1_in][0] - 总_221_do_1A80 )
   {
     Print("Restoring pending buy-order"); 
     总_230_in_1E08 = NativeSendOrder(总_336_st_3130,ORDER_TYPE_BUY_STOP,总_197_do_6DC_si100si3[子_1_in][2],总_197_do_6DC_si100si3[子_1_in][0],int(总_38_do_C0 * 总_229_do_1E00),总_197_do_6DC_si100si3[子_1_in][0] - (总_100_do_230 + 总_64_do_148) * 总_229_do_1E00,总_101_do_238 * 总_229_do_1E00 + 总_197_do_6DC_si100si3[子_1_in][0],总_334_st_3120,总_93_in_1F0,总_302_da_2870 + 0x2A300,clrGreen) ;
     总_280_bo_25FA = false ;
     临_do_1 = 总_197_do_6DC_si100si3[子_1_in][0];
     临_lo_2 = 总_230_in_1E08;
     for (临_in_3 = 0 ; 临_in_3 < 100 ; 临_in_3=临_in_3 + 1)
     {
       if ( !(总_198_do_1070_si100si2[临_in_3][0]==0.0) )   continue;
       总_198_do_1070_si100si2[临_in_3][0] = (double)临_lo_2;
       总_198_do_1070_si100si2[临_in_3][1] = 临_do_1;
       break;
       
     }
     if ( 总_230_in_1E08 <= 0 )
     {
       if ( NativeTradeRetcode() == TRADE_RETCODE_MARKET_CLOSED )
       {
         ResetLastError();
         
           do
           {
             Sleep(2500); 
             总_230_in_1E08 = NativeSendOrder(总_336_st_3130,ORDER_TYPE_BUY_STOP,总_197_do_6DC_si100si3[子_1_in][2],总_197_do_6DC_si100si3[子_1_in][0],int(总_38_do_C0 * 总_229_do_1E00),总_197_do_6DC_si100si3[子_1_in][0] - (总_100_do_230 + 总_64_do_148) * 总_229_do_1E00,总_101_do_238 * 总_229_do_1E00 + 总_197_do_6DC_si100si3[子_1_in][0],总_334_st_3120,总_93_in_1F0,总_302_da_2870 + 0x2A300,clrGreen) ;
             总_280_bo_25FA = false ;
             临_do_4 = 总_197_do_6DC_si100si3[子_1_in][0];
             临_lo_5 = 总_230_in_1E08;
             for (临_in_6 = 0 ; 临_in_6 < 100 ; 临_in_6=临_in_6 + 1)
             {
               if ( !(总_198_do_1070_si100si2[临_in_6][0]==0.0) )   continue;
               总_198_do_1070_si100si2[临_in_6][0] = (double)临_lo_5;
               总_198_do_1070_si100si2[临_in_6][1] = 临_do_4;
               break;
               
             }
           }
           while(NativeTradeRetcode() == TRADE_RETCODE_MARKET_CLOSED);
           
         
       }
       Print("error: \'" + NativeTradeRetcodeText(NativeTradeRetcode()) + "\' when setting entry order"); 
     }
   }
   if ( !(总_197_do_6DC_si100si3[子_1_in][1]==5.0) || !(SymbolInfoDouble(总_336_st_3130,SYMBOL_BID)>总_197_do_6DC_si100si3[子_1_in][0] + 总_221_do_1A80) )   continue;
   Print("Restoring pending sell-order"); 
   总_230_in_1E08 = NativeSendOrder(总_336_st_3130,ORDER_TYPE_SELL_STOP,总_197_do_6DC_si100si3[子_1_in][2],总_197_do_6DC_si100si3[子_1_in][0],int(总_38_do_C0 * 总_229_do_1E00),(总_100_do_230 + 总_64_do_148) * 总_229_do_1E00 + 总_197_do_6DC_si100si3[子_1_in][0],总_197_do_6DC_si100si3[子_1_in][0] - 总_101_do_238 * 总_229_do_1E00,总_334_st_3120,总_93_in_1F0,总_302_da_2870 + 0x2A300,clrGreen) ;
   总_281_bo_25FB = false ;
   临_do_7 = 总_197_do_6DC_si100si3[子_1_in][0];
   临_lo_8 = 总_230_in_1E08;
   for (临_in_9 = 0 ; 临_in_9 < 100 ; 临_in_9=临_in_9 + 1)
   {
     if ( !(总_198_do_1070_si100si2[临_in_9][0]==0.0) )   continue;
     总_198_do_1070_si100si2[临_in_9][0] = (double)临_lo_8;
     总_198_do_1070_si100si2[临_in_9][1] = 临_do_7;
     break;
     
   }
   if ( 总_230_in_1E08 > 0 )   continue;
   
   if ( NativeTradeRetcode() == TRADE_RETCODE_MARKET_CLOSED )
   {
     ResetLastError();
     
       do
       {
         Sleep(2500); 
         总_230_in_1E08 = NativeSendOrder(总_336_st_3130,ORDER_TYPE_SELL_STOP,总_197_do_6DC_si100si3[子_1_in][2],总_197_do_6DC_si100si3[子_1_in][0],int(总_38_do_C0 * 总_229_do_1E00),(总_100_do_230 + 总_64_do_148) * 总_229_do_1E00 + 总_197_do_6DC_si100si3[子_1_in][0],总_197_do_6DC_si100si3[子_1_in][0] - 总_101_do_238 * 总_229_do_1E00,总_334_st_3120,总_93_in_1F0,总_302_da_2870 + 0x2A300,clrGreen) ;
         总_281_bo_25FB = false ;
         临_do_10 = 总_197_do_6DC_si100si3[子_1_in][0];
         临_lo_11 = 总_230_in_1E08;
         for (临_in_12 = 0 ; 临_in_12 < 100 ; 临_in_12=临_in_12 + 1)
         {
           if ( !(总_198_do_1070_si100si2[临_in_12][0]==0.0) )   continue;
           总_198_do_1070_si100si2[临_in_12][0] = (double)临_lo_11;
           总_198_do_1070_si100si2[临_in_12][1] = 临_do_10;
           break;
           
         }
       }
       while(NativeTradeRetcode() == TRADE_RETCODE_MARKET_CLOSED);
       
     
   }
   Print("error: \'" + NativeTradeRetcodeText(NativeTradeRetcode()) + "\' when setting entry order"); 
   
 }
 for (临_in_13 = 0 ; 临_in_13 < 总_200_in_16B4 ; 临_in_13=临_in_13 + 1)
 {
   总_197_do_6DC_si100si3[临_in_13][0] = 0.0;
   总_197_do_6DC_si100si3[临_in_13][1] = 0.0;
   总_197_do_6DC_si100si3[临_in_13][2] = 0.0;
 }
 }
//lizong_8 <<==--------   --------
 bool lizong_9()
 {
  int       子_2_in;
  int       子_3_in;
  int       子_4_in;
//----- -----
 long       临_lo_1;
 int        临_in_2;
 long       临_lo_3;
 int        临_in_4;
 double     临_do_5;
 double     临_do_6;
 long       临_lo_7;
 int        临_in_8;
 long       临_lo_9;
 int        临_in_10;

 for (子_2_in = NativeTradesTotal() ; 子_2_in >= 0 ; 子_2_in --)
 {
   if ( g_trade_view.Select(子_2_in,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true )   continue;
   
   if ( ( g_trade_view.Magic() != 总_93_in_1F0 && g_trade_view.Magic() != 总_96_in_208 ) || g_trade_view.SymbolName() != 总_336_st_3130 )   continue;
   
   if ( g_trade_view.OrderType() == ORDER_TYPE_BUY_STOP && g_trade_view.PriceOpen()<总_36_in_B0 * 总_229_do_1E00 + SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK) && SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK)<g_trade_view.PriceOpen() - 总_309_do_2898 )
   {
     if ( 总_37_do_B8>0.0 )
     {
       Print("Spread too high..(" + string(总_1_do_0) + ") storing and deleting order " + string(g_trade_view.Ticket())); 
       for (子_3_in = 0 ; 子_3_in < 总_200_in_16B4 ; 子_3_in ++)
       {
         if ( 总_197_do_6DC_si100si3[子_3_in][0]==0.0 )
         {
           Print("Storing pending order nr " + string(g_trade_view.Ticket())); 
           总_197_do_6DC_si100si3[子_3_in][1] = g_trade_view.OrderType();
           总_197_do_6DC_si100si3[子_3_in][0] = g_trade_view.PriceOpen();
           总_197_do_6DC_si100si3[子_3_in][2] = g_trade_view.Volume();
           break;
         }
       }
       临_lo_1 = g_trade_view.Ticket();
       for (临_in_2 = 0 ; 临_in_2 < 100 ; 临_in_2=临_in_2 + 1)
       {
         if ( !(总_198_do_1070_si100si2[临_in_2][0]==临_lo_1) )   continue;
         总_198_do_1070_si100si2[临_in_2][0] = 0.0;
         总_198_do_1070_si100si2[临_in_2][1] = 0.0;
         break;
         
       }
       NativeDeletePending(g_trade_view.Ticket(),clrGreen); 
     }
     else
     {
       Print("Spread too high..(" + string(总_1_do_0) + ") deleting order " + string(g_trade_view.Ticket())); 
       临_lo_3 = g_trade_view.Ticket();
       for (临_in_4 = 0 ; 临_in_4 < 100 ; 临_in_4=临_in_4 + 1)
       {
         if ( !(总_198_do_1070_si100si2[临_in_4][0]==临_lo_3) )   continue;
         总_198_do_1070_si100si2[临_in_4][0] = 0.0;
         总_198_do_1070_si100si2[临_in_4][1] = 0.0;
         break;
         
       }
       NativeDeletePending(g_trade_view.Ticket(),clrGreen); 
     }
   }
   if ( g_trade_view.OrderType() != ORDER_TYPE_SELL_STOP )   continue;
   临_do_5 = g_trade_view.PriceOpen();
   if ( !(临_do_5>SymbolInfoDouble(总_336_st_3130,SYMBOL_BID) - 总_36_in_B0 * 总_229_do_1E00) )   continue;
   临_do_6 = SymbolInfoDouble(总_336_st_3130,SYMBOL_BID);
   if ( !(临_do_6>g_trade_view.PriceOpen() + 总_309_do_2898) )   continue;
   
   if ( 总_37_do_B8>0.0 )
   {
     Print("Spread too high..(" + string(总_1_do_0) + ") storing and deleting order " + string(g_trade_view.Ticket())); 
     for (子_4_in = 0 ; 子_4_in < 总_200_in_16B4 ; 子_4_in ++)
     {
       if ( 总_197_do_6DC_si100si3[子_4_in][0]==0.0 )
       {
         Print("Storing pending order nr " + string(g_trade_view.Ticket())); 
         总_197_do_6DC_si100si3[子_4_in][1] = g_trade_view.OrderType();
         总_197_do_6DC_si100si3[子_4_in][0] = g_trade_view.PriceOpen();
         总_197_do_6DC_si100si3[子_4_in][2] = g_trade_view.Volume();
         break;
       }
     }
     临_lo_7 = g_trade_view.Ticket();
     for (临_in_8 = 0 ; 临_in_8 < 100 ; 临_in_8=临_in_8 + 1)
     {
       if ( !(总_198_do_1070_si100si2[临_in_8][0]==临_lo_7) )   continue;
       总_198_do_1070_si100si2[临_in_8][0] = 0.0;
       总_198_do_1070_si100si2[临_in_8][1] = 0.0;
       break;
       
     }
     NativeDeletePending(g_trade_view.Ticket(),clrGreen); 
      continue;
   }
   Print("Spread too high..(" + string(总_1_do_0) + ") deleting order " + string(g_trade_view.Ticket())); 
   临_lo_9 = g_trade_view.Ticket();
   for (临_in_10 = 0 ; 临_in_10 < 100 ; 临_in_10=临_in_10 + 1)
   {
     if ( !(总_198_do_1070_si100si2[临_in_10][0]==临_lo_9) )   continue;
     总_198_do_1070_si100si2[临_in_10][0] = 0.0;
     总_198_do_1070_si100si2[临_in_10][1] = 0.0;
     break;
     
   }
   NativeDeletePending(g_trade_view.Ticket(),clrGreen); 
   
 }
 return(false); 
 }
//lizong_9 <<==--------   --------
 void lizong_10( double 木_0_do,int 木_1_in)
 {
  double    子_1_do;
  double    子_2_do;
  double    子_3_do;
  double    子_4_do;
  double    子_5_do;
  double    子_6_do;
  double    子_7_do;
//----- -----

 子_1_do = 总_223_do_1AC4_si99[总_328_in_3100] ;
 子_2_do = 总_223_do_1AC4_si99[总_328_in_3100] ;
 总_401_do_6AD0 = AccountInfoDouble(ACCOUNT_BALANCE) ;
 if ( UseEquity )
 {
   总_401_do_6AD0 = AccountInfoDouble(ACCOUNT_EQUITY) ;
 }
 if ( OnlyUp && 总_402_do_6AD8>总_401_do_6AD0 )
 {
   总_401_do_6AD0 = 总_402_do_6AD8 ;
 }
 if ( 总_401_do_6AD0>总_402_do_6AD8 )
 {
   总_402_do_6AD8 = 总_401_do_6AD0 ;
   GlobalVariableSet("HighestBalance",总_402_do_6AD8) ;
 }
 if ( ManualBalance>0.0 )
 {
   总_401_do_6AD0 = ManualBalance ;
 }
 // Original JIT 0x19aa50e89e7-0x19aa50e8a29: lot-sizing guard.
 if ( 总_401_do_6AD0==0.0 )
 {
   总_401_do_6AD0 = 0.01 ;
 }
 子_3_do = 木_0_do ;
 if ( ( 总_190_in_518 == 2 || 总_190_in_518 == 4 ) )
 {
   子_3_do = 木_0_do / 10.0 ;
 }
 if ( Risk <  999 && Risk >  0 )
 {
   子_4_do = Risk ;
   子_5_do = 子_4_do / 1000.0 * 总_401_do_6AD0 ;
   if ( SymbolInfoDouble(总_336_st_3130,SYMBOL_VOLUME_STEP)==0.1 )
   {
     子_2_do = NormalizeDouble(木_1_in * 0.01 * (子_5_do / (SymbolInfoDouble(总_336_st_3130,SYMBOL_TRADE_TICK_VALUE) * 子_3_do) * 0.1),1) ;
   }
   if ( SymbolInfoDouble(总_336_st_3130,SYMBOL_VOLUME_STEP)==0.01 )
   {
     子_2_do = NormalizeDouble(木_1_in * 0.01 * (子_5_do / (SymbolInfoDouble(总_336_st_3130,SYMBOL_TRADE_TICK_VALUE) * 子_3_do) * 0.1),2) ;
   }
 }
 if ( Risk == 999 )
 {
   子_6_do = 总_148_do_420 / 100.0 * 总_401_do_6AD0 ;
   if ( SymbolInfoDouble(总_336_st_3130,SYMBOL_VOLUME_STEP)==0.1 )
   {
     子_2_do = NormalizeDouble(木_1_in * 0.01 * (子_6_do / (SymbolInfoDouble(总_336_st_3130,SYMBOL_TRADE_TICK_VALUE) * 子_3_do) * 0.1),1) ;
   }
   if ( SymbolInfoDouble(总_336_st_3130,SYMBOL_VOLUME_STEP)==0.01 )
   {
     子_2_do = NormalizeDouble(木_1_in * 0.01 * (子_6_do / (SymbolInfoDouble(总_336_st_3130,SYMBOL_TRADE_TICK_VALUE) * 子_3_do) * 0.1),2) ;
   }
 }
 if ( Risk == 0 )
 {
   if ( SymbolInfoDouble(总_336_st_3130,SYMBOL_VOLUME_STEP)==0.1 )
   {
     子_2_do = NormalizeDouble(木_1_in * 0.01 * g_startLots_rw,1) ;
   }
   if ( SymbolInfoDouble(总_336_st_3130,SYMBOL_VOLUME_STEP)==0.01 )
   {
     子_2_do = NormalizeDouble(木_1_in * 0.01 * g_startLots_rw,2) ;
   }
 }
 if ( Risk == 9999 )
 {
   if ( SymbolInfoDouble(总_336_st_3130,SYMBOL_VOLUME_STEP)==0.1 )
   {
     子_2_do = NormalizeDouble(木_1_in * 0.01 * (总_401_do_6AD0 / 总_145_in_40C * 0.01),1) ;
   }
   if ( SymbolInfoDouble(总_336_st_3130,SYMBOL_VOLUME_STEP)==0.01 )
   {
     子_2_do = NormalizeDouble(木_1_in * 0.01 * (总_401_do_6AD0 / 总_145_in_40C * 0.01),2) ;
   }
 }
 if ( Risk == 1234 )
 {
   if ( UseWeightedLots )
   {
     if ( 总_397_do_6768==0.0 )
     {
       总_397_do_6768 = 100000.0 ;
     }
     总_146_do_410 = MaxAllowedDD / 总_398_do_6770 ;
     if ( SymbolInfoDouble(总_336_st_3130,SYMBOL_VOLUME_STEP)==0.1 )
     {
       子_2_do = NormalizeDouble(总_146_do_410 / 总_397_do_6768 * 总_401_do_6AD0 / 100.0 * 0.01,1) ;
     }
     if ( SymbolInfoDouble(总_336_st_3130,SYMBOL_VOLUME_STEP)==0.01 )
     {
       子_2_do = NormalizeDouble(总_146_do_410 / 总_397_do_6768 * 总_401_do_6AD0 / 100.0 * 0.01,2) ;
     }
   }
   else
   {
     if ( 总_397_do_6768==0.0 )
     {
       总_397_do_6768 = 100000.0 ;
     }
     子_7_do = lizong_36(总_401_do_6AD0) ;
     if ( 总_19_in_9C == 0 )
     {
       总_145_in_40C = (int)(总_385_in_5DA8 / (MaxAllowedDD / 100.0)) ;
     }
     if ( 总_19_in_9C == 1 )
     {
       总_145_in_40C = (int)(总_386_in_5DAC / (MaxAllowedDD / 100.0)) ;
     }
     if ( 总_19_in_9C == 2 )
     {
       总_145_in_40C = (int)(总_387_in_5DB0 / (MaxAllowedDD / 100.0)) ;
     }
     if ( 总_19_in_9C == 3 )
     {
       总_145_in_40C = (int)(总_388_in_5DB4 / (MaxAllowedDD / 100.0)) ;
     }
     if ( 总_19_in_9C == 4 )
     {
       总_145_in_40C = (int)(总_389_in_5DB8 / (MaxAllowedDD / 100.0)) ;
     }
     if ( SymbolInfoDouble(总_336_st_3130,SYMBOL_VOLUME_STEP)==0.1 )
     {
       子_2_do = NormalizeDouble(木_1_in * 0.01 * (子_7_do / 总_145_in_40C * 0.01),1) ;
     }
     if ( SymbolInfoDouble(总_336_st_3130,SYMBOL_VOLUME_STEP)==0.01 )
     {
       子_2_do = NormalizeDouble(木_1_in * 0.01 * (子_7_do / 总_145_in_40C * 0.01),2) ;
     }
   }
 }
 if ( Risk == 3 )
 {
   if ( SymbolInfoDouble(总_336_st_3130,SYMBOL_VOLUME_STEP)==0.1 )
   {
     子_2_do = NormalizeDouble(MaxRiskPerStrategy_ / 总_397_do_6768 * 总_401_do_6AD0 / 100.0 * 0.01,1) ;
   }
   if ( SymbolInfoDouble(总_336_st_3130,SYMBOL_VOLUME_STEP)==0.01 )
   {
     子_2_do = NormalizeDouble(MaxRiskPerStrategy_ / 总_397_do_6768 * 总_401_do_6AD0 / 100.0 * 0.01,2) ;
   }
 }
 子_2_do = 子_2_do * 总_9_do_60 ;
 if ( 子_2_do<SymbolInfoDouble(总_336_st_3130,SYMBOL_VOLUME_STEP) )
 {
   子_2_do = SymbolInfoDouble(总_336_st_3130,SYMBOL_VOLUME_STEP) ;
 }
 if ( 子_2_do>总_141_do_3F8 )
 {
   子_2_do = 总_141_do_3F8 ;
 }
 if ( 子_2_do<SymbolInfoDouble(总_336_st_3130,SYMBOL_VOLUME_MIN) )
 {
   子_2_do = SymbolInfoDouble(总_336_st_3130,SYMBOL_VOLUME_MIN) ;
 }
 if ( 子_2_do>SymbolInfoDouble(总_336_st_3130,SYMBOL_VOLUME_MAX) && SymbolInfoDouble(总_336_st_3130,SYMBOL_VOLUME_MAX)!=0.0 )
 {
   子_2_do = SymbolInfoDouble(总_336_st_3130,SYMBOL_VOLUME_MAX) ;
 }
 if ( SymbolInfoDouble(总_336_st_3130,SYMBOL_VOLUME_STEP)==0.1 )
 {
   总_223_do_1AC4_si99[总_328_in_3100] = NormalizeDouble((MathFloor(子_2_do * 10.0)) / 10.0,1);
   return;
 }
 总_223_do_1AC4_si99[总_328_in_3100] = NormalizeDouble(MathFloor(子_2_do * 100.0) / 100.0,2);
 }
//lizong_10 <<==--------   --------
 double lizong_11( int 木_0_in)
 {
  bool      子_2_bo = false;
  bool      子_3_bo = false;
  bool      子_4_bo;
  int       子_5_in;
  int       子_6_in;
  int       子_7_in;
//----- -----
 double     临_do_1;
 int        临_in_2;
 double     临_do_3;
 int        临_in_4;
 double     临_do_5;
 int        临_in_6;
 bool       临_bo_7;

 子_4_bo = false ;
 子_5_in=总_74_in_180 + 1;
 do
 {
   子_3_bo = true ;
   子_4_bo = true ;
   for (子_6_in = 子_5_in ; 子_6_in >= 子_5_in - 总_74_in_180 ; 子_6_in --)
   {
     if ( iHigh(总_336_st_3130,NativeTimeframe(木_0_in),子_6_in)>iHigh(总_336_st_3130,NativeTimeframe(木_0_in),子_5_in) )
     {
       子_4_bo = false ;
     }
   }
   for (子_7_in = 子_5_in ; 子_7_in <= 子_5_in + 总_73_in_17C ; 子_7_in ++)
   {
     if ( iHigh(总_336_st_3130,NativeTimeframe(木_0_in),子_7_in)>iHigh(总_336_st_3130,NativeTimeframe(木_0_in),子_5_in) )
     {
       子_3_bo = false ;
     }
   }
   if ( 子_4_bo && 子_3_bo && iHigh(总_336_st_3130,NativeTimeframe(木_0_in),子_5_in)>总_80_do_198 * 总_229_do_1E00 + SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK) )
   {
     临_do_1 = iHigh(总_336_st_3130,NativeTimeframe(木_0_in),子_5_in);
     临_in_2 = 子_5_in;
     临_do_3 = iHigh(总_336_st_3130,NativeTimeframe(总_71_in_174),0);
     for (临_in_4 = 1 ; 临_in_4 <= 临_in_2 ; 临_in_4=临_in_4 + 1)
     {
       if ( iHigh(总_336_st_3130,NativeTimeframe(总_71_in_174),临_in_4)>临_do_3 )
       {
         临_do_3 = iHigh(总_336_st_3130,NativeTimeframe(总_71_in_174),临_in_4);
       }
     }
     if ( 临_do_1>=临_do_3 )
     {
       临_do_5 = NormalizeDouble(iHigh(总_336_st_3130,NativeTimeframe(木_0_in),子_5_in),总_190_in_518);
       临_bo_7=false; 
       for (临_in_6 = NativeTradesTotal() ; 临_in_6 >= 0 ; 临_in_6=临_in_6 - 1)
       {
         if ( g_trade_view.Select(临_in_6,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true || g_trade_view.Magic() != 总_93_in_1F0 || g_trade_view.SymbolName() != 总_336_st_3130 || g_trade_view.OrderType() != ORDER_TYPE_BUY_STOP || !(MathAbs(g_trade_view.PriceOpen() - (总_83_do_1B0 * 总_229_do_1E00 + 临_do_5))<总_88_do_1D0 * 总_229_do_1E00) )   continue;
         临_bo_7 = true;
          break;
         
       }
       if ( !(临_bo_7) && ( !(总_75_bo_184) || !(iClose(总_336_st_3130,NativeTimeframe(木_0_in),子_5_in - 1)>iHigh(总_336_st_3130,NativeTimeframe(木_0_in),子_5_in) - 总_80_do_198 * 总_229_do_1E00) ) )
       {
         子_2_bo = true ;
         总_262_do_2580 = NormalizeDouble(iHigh(总_336_st_3130,NativeTimeframe(木_0_in),子_5_in),总_190_in_518) ;
         总_265_in_2598 = 子_5_in ;
         break;
       }
     }
   }
   子_5_in ++;
   if ( 子_5_in <= 总_77_in_188 )   continue;
   总_262_do_2580 = 0.0 ;
   break;
   
 }
 while(!(子_2_bo));
 
 return(总_262_do_2580); 
 }
//lizong_11 <<==--------   --------
 double lizong_12( int 木_0_in)
 {
  bool      子_2_bo = false;
  bool      子_3_bo = false;
  bool      子_4_bo;
  int       子_5_in;
  int       子_6_in;
  int       子_7_in;
//----- -----
 double     临_do_1;
 int        临_in_2;
 double     临_do_3;
 int        临_in_4;
 double     临_do_5;
 int        临_in_6;
 bool       临_bo_7;

 子_4_bo = false ;
 子_5_in=总_74_in_180 + 1;
 do
 {
   子_3_bo = true ;
   子_4_bo = true ;
   for (子_6_in = 子_5_in ; 子_6_in >= 子_5_in - 总_74_in_180 ; 子_6_in --)
   {
     if ( iLow(总_336_st_3130,NativeTimeframe(木_0_in),子_6_in)<iLow(总_336_st_3130,NativeTimeframe(木_0_in),子_5_in) )
     {
       子_4_bo = false ;
     }
   }
   for (子_7_in = 子_5_in ; 子_7_in <= 子_5_in + 总_73_in_17C ; 子_7_in ++)
   {
     if ( iLow(总_336_st_3130,NativeTimeframe(木_0_in),子_7_in)<iLow(总_336_st_3130,NativeTimeframe(木_0_in),子_5_in) )
     {
       子_3_bo = false ;
     }
   }
   if ( 子_4_bo && 子_3_bo && iLow(总_336_st_3130,NativeTimeframe(木_0_in),子_5_in)<SymbolInfoDouble(总_336_st_3130,SYMBOL_BID) - 总_80_do_198 * 总_229_do_1E00 )
   {
     临_do_1 = iLow(总_336_st_3130,NativeTimeframe(木_0_in),子_5_in);
     临_in_2 = 子_5_in;
     临_do_3 = iLow(总_336_st_3130,NativeTimeframe(总_71_in_174),0);
     for (临_in_4 = 1 ; 临_in_4 <= 临_in_2 ; 临_in_4=临_in_4 + 1)
     {
       if ( iLow(总_336_st_3130,NativeTimeframe(总_71_in_174),临_in_4)<临_do_3 )
       {
         临_do_3 = iLow(总_336_st_3130,NativeTimeframe(总_71_in_174),临_in_4);
       }
     }
     if ( 临_do_1<=临_do_3 )
     {
       临_do_5 = NormalizeDouble(iLow(总_336_st_3130,NativeTimeframe(木_0_in),子_5_in),总_190_in_518);
       临_bo_7=false; 
       for (临_in_6 = NativeTradesTotal() ; 临_in_6 >= 0 ; 临_in_6=临_in_6 - 1)
       {
         if ( g_trade_view.Select(临_in_6,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true || g_trade_view.Magic() != 总_93_in_1F0 || g_trade_view.SymbolName() != 总_336_st_3130 || g_trade_view.OrderType() != ORDER_TYPE_SELL_STOP || !(MathAbs(g_trade_view.PriceOpen() - (临_do_5 - 总_84_do_1B8 * 总_229_do_1E00))<总_88_do_1D0 * 总_229_do_1E00) )   continue;
         临_bo_7 = true;
          break;
         
       }
       if ( !(临_bo_7) && ( !(总_75_bo_184) || !(iClose(总_336_st_3130,NativeTimeframe(木_0_in),子_5_in - 1)<总_80_do_198 * 总_229_do_1E00 + iLow(总_336_st_3130,NativeTimeframe(木_0_in),子_5_in)) ) )
       {
         子_2_bo = true ;
         总_261_do_2578 = NormalizeDouble(iLow(总_336_st_3130,NativeTimeframe(木_0_in),子_5_in),总_190_in_518) ;
         总_266_in_259C = 子_5_in ;
         break;
       }
     }
   }
   子_5_in ++;
   if ( 子_5_in <= 总_77_in_188 )   continue;
   总_261_do_2578 = 0.0 ;
   break;
   
 }
 while(!(子_2_bo));
 
 return(总_261_do_2578); 
 }
//lizong_12 <<==--------   --------
 double lizong_13( int 木_0_in,int 木_1_in,int 木_2_in)
 {
  bool      子_2_bo = false;
  double    子_3_do = 0.0;
  bool      子_4_bo = false;
  bool      子_5_bo;
  int       子_6_in;
  int       子_7_in;
  int       子_8_in;
//----- -----

 子_5_bo = false ;
 子_6_in=木_2_in + 1;
 do
 {
   子_4_bo = true ;
   子_5_bo = true ;
   for (子_7_in = 子_6_in ; 子_7_in >= 子_6_in - 木_2_in ; 子_7_in --)
   {
     if ( iHigh(总_336_st_3130,NativeTimeframe(木_0_in),子_7_in)>iHigh(总_336_st_3130,NativeTimeframe(木_0_in),子_6_in) )
     {
       子_5_bo = false ;
     }
   }
   for (子_8_in = 子_6_in ; 子_8_in <= 子_6_in + 木_1_in ; 子_8_in ++)
   {
     if ( iHigh(总_336_st_3130,NativeTimeframe(木_0_in),子_8_in)>iHigh(总_336_st_3130,NativeTimeframe(木_0_in),子_6_in) )
     {
       子_4_bo = false ;
     }
   }
   if ( 子_5_bo && 子_4_bo && iHigh(总_336_st_3130,NativeTimeframe(木_0_in),子_6_in)>总_221_do_1A80 + SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK) )
   {
     子_2_bo = true ;
     子_3_do = NormalizeDouble(iHigh(总_336_st_3130,NativeTimeframe(木_0_in),子_6_in),总_190_in_518) ;
     break;
   }
   子_6_in ++;
   if ( 子_6_in <= 总_118_in_2CC )   continue;
   子_3_do = 9999.0 ;
   break;
   
 }
 while(!(子_2_bo));
 
 return(子_3_do); 
 }
//lizong_13 <<==--------   --------
 double lizong_14( int 木_0_in,int 木_1_in,int 木_2_in)
 {
  bool      子_2_bo = false;
  double    子_3_do = 0.0;
  bool      子_4_bo = false;
  bool      子_5_bo;
  int       子_6_in;
  int       子_7_in;
  int       子_8_in;
//----- -----

 子_5_bo = false ;
 子_6_in=木_2_in + 1;
 do
 {
   子_4_bo = true ;
   子_5_bo = true ;
   for (子_7_in = 子_6_in ; 子_7_in >= 子_6_in - 木_2_in ; 子_7_in --)
   {
     if ( iLow(总_336_st_3130,NativeTimeframe(木_0_in),子_7_in)<iLow(总_336_st_3130,NativeTimeframe(木_0_in),子_6_in) )
     {
       子_5_bo = false ;
     }
   }
   for (子_8_in = 子_6_in ; 子_8_in <= 子_6_in + 木_1_in ; 子_8_in ++)
   {
     if ( iLow(总_336_st_3130,NativeTimeframe(木_0_in),子_8_in)<iLow(总_336_st_3130,NativeTimeframe(木_0_in),子_6_in) )
     {
       子_4_bo = false ;
     }
   }
   if ( 子_5_bo && 子_4_bo && iLow(总_336_st_3130,NativeTimeframe(木_0_in),子_6_in)<SymbolInfoDouble(总_336_st_3130,SYMBOL_BID) - 总_221_do_1A80 )
   {
     子_2_bo = true ;
     子_3_do = NormalizeDouble(iLow(总_336_st_3130,NativeTimeframe(木_0_in),子_6_in),总_190_in_518) ;
     break;
   }
   子_6_in ++;
   if ( 子_6_in <= 总_118_in_2CC )   continue;
   子_3_do = 0.0 ;
   break;
   
 }
 while(!(子_2_bo));
 
 return(子_3_do); 
 }
//lizong_14 <<==--------   --------
 void lizong_15()
 {
  int       子_1_in;
//----- -----
 long       临_lo_1;
 long       临_lo_2;
 int        临_in_3;
 int        临_in_4;
 int        临_in_5;
 int        临_in_6;
 int        临_in_7;
 int        临_in_8;
 int        临_in_9;
 int        临_in_10;
 int        临_in_11;
 int        临_in_12;

 if ( 总_213_bo_1710 )
 {
   总_268_do_25A8 = NativeMAValue(总_336_st_3130,0,总_214_in_1714,0,1,0,1) ;
   总_269_do_25B0 = NativeMAValue(总_336_st_3130,0,总_217_in_1A70,0,1,0,1) ;
 }
 lizong_10(总_100_do_230,总_92_in_1EC); 
 if ( 总_223_do_1AC4_si99[总_328_in_3100]>总_141_do_3F8 )
 {
   总_223_do_1AC4_si99[总_328_in_3100] = 总_141_do_3F8;
 }
 if ( 总_89_in_1D8 >  0 )
 {
   总_302_da_2870=TimeCurrent() + 总_234_in_1E20;
 }
 if ( Virtual_expiration )
 {
   总_302_da_2870 = 0 ;
   for (子_1_in = NativeTradesTotal() ; 子_1_in >= 0 ; 子_1_in --)
   {
     if ( g_trade_view.Select(子_1_in,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true || g_trade_view.Magic() != 总_93_in_1F0 || g_trade_view.SymbolName() != 总_336_st_3130 )   continue;
     
     if ( ( g_trade_view.OrderType() != ORDER_TYPE_BUY_STOP && g_trade_view.OrderType() != ORDER_TYPE_SELL_STOP ) )   continue;
     临_lo_1 = TimeCurrent();
     临_lo_2=g_trade_view.TimeOpen() + 总_234_in_1E20;
     if ( 临_lo_1 < 临_lo_2 )   continue;
     NativeDeletePending(g_trade_view.Ticket(),clrRed); 
     
   }
 }
 临_in_3 = 0;
 for (临_in_4 = NativeTradesTotal() ; 临_in_4 >= 0 ; 临_in_4=临_in_4 - 1)
 {
   if ( g_trade_view.Select(临_in_4,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true || g_trade_view.Magic() != 总_93_in_1F0 || g_trade_view.SymbolName() != 总_336_st_3130 || g_trade_view.OrderType() != ORDER_TYPE_BUY )   continue;
   临_in_3=临_in_3 + 1;
   
 }
 if ( 临_in_3 <  总_87_in_1CC )
 {
   lizong_16(1); 
 }
 else
 {
   临_in_5 = 1;
   for (临_in_6 = NativeTradesTotal() ; 临_in_6 >= 0 ; 临_in_6=临_in_6 - 1)
   {
     if ( g_trade_view.Select(临_in_6,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true || g_trade_view.Magic() != 总_93_in_1F0 || g_trade_view.SymbolName() != 总_336_st_3130 || g_trade_view.OrderType() != ORDER_TYPE_BUY_STOP )   continue;
     NativeDeletePending(g_trade_view.Ticket(),0xFFFFFFFF); 
     
   }
   if ( 临_in_5 == 2 )
   {
     for (临_in_7 = NativeTradesTotal() ; 临_in_7 >= 0 ; 临_in_7=临_in_7 - 1)
     {
       if ( g_trade_view.Select(临_in_7,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true || g_trade_view.Magic() != 总_96_in_208 || g_trade_view.SymbolName() != 总_336_st_3130 || g_trade_view.OrderType() != ORDER_TYPE_BUY_STOP )   continue;
       NativeDeletePending(g_trade_view.Ticket(),0xFFFFFFFF); 
       
     }
   }
 }
 临_in_8 = 0;
 for (临_in_9 = NativeTradesTotal() ; 临_in_9 >= 0 ; 临_in_9=临_in_9 - 1)
 {
   if ( g_trade_view.Select(临_in_9,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true || g_trade_view.Magic() != 总_93_in_1F0 || g_trade_view.SymbolName() != 总_336_st_3130 || g_trade_view.OrderType() != ORDER_TYPE_SELL )   continue;
   临_in_8=临_in_8 + 1;
   
 }
 if ( 临_in_8 <  总_87_in_1CC )
 {
   lizong_17(1); 
   return;
 }
 临_in_10 = 1;
 for (临_in_11 = NativeTradesTotal() ; 临_in_11 >= 0 ; 临_in_11=临_in_11 - 1)
 {
   if ( g_trade_view.Select(临_in_11,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true || g_trade_view.Magic() != 总_93_in_1F0 || g_trade_view.SymbolName() != 总_336_st_3130 || g_trade_view.OrderType() != ORDER_TYPE_SELL_STOP )   continue;
   NativeDeletePending(g_trade_view.Ticket(),0xFFFFFFFF); 
   
 }
 if ( 临_in_10 != 2 )   return;
 for (临_in_12 = NativeTradesTotal() ; 临_in_12 >= 0 ; 临_in_12=临_in_12 - 1)
 {
   if ( g_trade_view.Select(临_in_12,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true || g_trade_view.Magic() != 总_96_in_208 || g_trade_view.SymbolName() != 总_336_st_3130 || g_trade_view.OrderType() != ORDER_TYPE_SELL_STOP )   continue;
   NativeDeletePending(g_trade_view.Ticket(),0xFFFFFFFF); 
   
 }
 }
//lizong_15 <<==--------   --------
 bool lizong_16( int 木_0_in)
 {
  bool      子_2_bo;
  double    子_3_do;
  double    子_4_do;
  double    子_5_do;
  double    子_6_do;
//----- -----
 bool       临_bo_1;
 int        临_in_2;
 double     临_do_3;
 int        临_in_4;
 bool       临_bo_5;
 int        临_in_6;
 int        临_in_7;
 double     临_do_8;
 int        临_in_9;
 double     临_do_10;
 int        临_in_11;
 bool       临_bo_12;
 bool       临_bo_13;
 int        临_in_14;
 bool       临_bo_15;
 int        临_in_16;
 double     临_do_17;
 long       临_lo_18;
 int        临_in_19;

 if ( !(AllowBuyTrades) )
 {
   return(false); 
 }
 if ( 总_218_bo_1A74 )
 {
   临_bo_1 = false;
 }
 else
 {
   临_bo_1=false; 
   for (临_in_2 = 0 ; 临_in_2 < NativeTradesTotal() ; 临_in_2=临_in_2 + 1)
   {
     if ( g_trade_view.Select(临_in_2,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true || g_trade_view.OrderType() != ORDER_TYPE_BUY || g_trade_view.Magic() != 总_93_in_1F0 || g_trade_view.SymbolName() != 总_336_st_3130 )   continue;
     临_bo_1 = true;
      break;
     
   }
 }
 if ( 临_bo_1 == true )
 {
   return(false); 
 }
 if ( 总_213_bo_1710 && 总_268_do_25A8<总_269_do_25B0 )
 {
   return(false); 
 }
 if ( 木_0_in == 1 )
 {
   lizong_11(总_71_in_174); 
   子_2_bo = false ;
   临_do_3 = 总_262_do_2580;
   临_bo_5=false; 
   for (临_in_4 = NativeTradesTotal() ; 临_in_4 >= 0 ; 临_in_4=临_in_4 - 1)
   {
     if ( g_trade_view.Select(临_in_4,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true || g_trade_view.Magic() != 总_93_in_1F0 || g_trade_view.SymbolName() != 总_336_st_3130 || g_trade_view.OrderType() != ORDER_TYPE_BUY_STOP || !(MathAbs(g_trade_view.PriceOpen() - (总_83_do_1B0 * 总_229_do_1E00 + 临_do_3))<总_88_do_1D0 * 总_229_do_1E00) )   continue;
     临_bo_5 = true;
      break;
     
   }
   if ( !(临_bo_5) )
   {
     临_in_6 = 0;
     for (临_in_7 = NativeTradesTotal() ; 临_in_7 >= 0 ; 临_in_7=临_in_7 - 1)
     {
       if ( g_trade_view.Select(临_in_7,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true || g_trade_view.Magic() != 总_93_in_1F0 || g_trade_view.SymbolName() != 总_336_st_3130 || g_trade_view.OrderType() != ORDER_TYPE_BUY_STOP )   continue;
       临_in_6=临_in_6 + 1;
       
     }
     if ( 临_in_6 == 总_86_in_1C8 )
     {
       临_do_8 = 9999.0;
       for (临_in_9 = NativeTradesTotal() ; 临_in_9 >= 0 ; 临_in_9=临_in_9 - 1)
       {
         if ( g_trade_view.Select(临_in_9,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true || g_trade_view.Magic() != 总_93_in_1F0 || g_trade_view.SymbolName() != 总_336_st_3130 || g_trade_view.OrderType() != ORDER_TYPE_BUY_STOP || !(g_trade_view.PriceOpen()<临_do_8) )   continue;
         临_do_8 = g_trade_view.PriceOpen();
         
       }
       if ( 总_262_do_2580>临_do_8 )
       {
         return(false); 
       }
     }
     总_264_do_2590 = 总_262_do_2580 ;
     子_2_bo = true ;
     总_188_do_508 = NormalizeDouble(总_262_do_2580,总_190_in_518) ;
   }
   if ( 总_188_do_508==0.0 )
   {
     return(false); 
   }
   if ( 子_2_bo )
   {
     总_247_do_2500 = 总_129_do_318 ;
     子_3_do = NormalizeDouble(总_83_do_1B0 * 总_229_do_1E00 + 总_188_do_508,总_190_in_518) ;
     临_do_10 = 子_3_do;
     临_bo_12=false; 
     for (临_in_11 = NativeTradesTotal() ; 临_in_11 >= 0 ; 临_in_11=临_in_11 - 1)
     {
       if ( g_trade_view.Select(临_in_11,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true || g_trade_view.Magic() != 总_93_in_1F0 || g_trade_view.SymbolName() != 总_336_st_3130 || g_trade_view.OrderType() != ORDER_TYPE_BUY_STOP || !(g_trade_view.PriceOpen()<=临_do_10) )   continue;
       临_bo_12 = true;
        break;
       
     }
     if ( 临_bo_12 )
     {
       return(false); 
     }
     总_310_do_28A0 = 子_3_do ;
     if ( !(总_67_bo_158) )
     {
       if ( CheckMargin && NativeFreeMarginAfterOrder(总_336_st_3130,ORDER_TYPE_BUY,总_223_do_1AC4_si99[总_328_in_3100])<=0.0 )
       {
         Print("Free margin not sufficient for setting order..."); 
         return(false); 
       }
       子_4_do = NormalizeDouble(总_15_in_78 * 总_229_do_1E00 + 子_3_do,总_190_in_518) ;
       子_5_do = NormalizeDouble(子_3_do - (总_100_do_230 + 总_64_do_148) * 总_229_do_1E00,总_190_in_518) ;
       子_6_do = NormalizeDouble(总_101_do_238 * 总_229_do_1E00 + 子_3_do,总_190_in_518) ;
       if ( 总_223_do_1AC4_si99[总_328_in_3100]<SymbolInfoDouble(总_336_st_3130,SYMBOL_VOLUME_MIN) )
       {
         Print("Volume is less than the minimal allowed SYMBOL_VOLUME_MIN=" + string(SymbolInfoDouble(总_336_st_3130,SYMBOL_VOLUME_MIN))); 
         临_bo_13 = false;
       }
       else
       {
         if ( 总_223_do_1AC4_si99[总_328_in_3100]>SymbolInfoDouble(总_336_st_3130,SYMBOL_VOLUME_MAX) )
         {
           Print("Volume is greater than the maximal allowed SYMBOL_VOLUME_MAX=" + string(SymbolInfoDouble(总_336_st_3130,SYMBOL_VOLUME_MAX))); 
           临_bo_13 = false;
         }
         else
         {
           if ( MathAbs(NormalizeDouble(总_223_do_1AC4_si99[总_328_in_3100] / SymbolInfoDouble(总_336_st_3130,SYMBOL_VOLUME_STEP),0) * SymbolInfoDouble(总_336_st_3130,SYMBOL_VOLUME_STEP) - 总_223_do_1AC4_si99[总_328_in_3100])>0.0000001 )
           {
             Print("Volume " + string(总_223_do_1AC4_si99[总_328_in_3100]) + " is not a multiple of the minimal step SYMBOL_VOLUME_STEP=" + string(SymbolInfoDouble(总_336_st_3130,SYMBOL_VOLUME_STEP))); 
             临_bo_13 = false;
           }
           else
           {
             临_bo_13 = true;
           }
         }
       }

       临_in_14 = (int)AccountInfoInteger(ACCOUNT_LIMIT_ORDERS);
       if ( 临_in_14 == 0 )
       {
         临_bo_15 = true;
       }
       else
       {
         临_bo_15 = NativeTradesTotal()<临_in_14;
       }
       if ( ( !(临_bo_13) || !(临_bo_15) ) )
       {
         return(false); 
       }
       if ( SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK)<子_4_do - 总_309_do_2898 && SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK)<子_4_do - 总_221_do_1A80 )
       {
         if ( !(setSL_TP_After_Entry) )
         {
           总_230_in_1E08 = NativeSendOrder(总_336_st_3130,ORDER_TYPE_BUY_STOP,总_223_do_1AC4_si99[总_328_in_3100],子_4_do,int(总_38_do_C0 * 总_229_do_1E00),子_5_do,子_6_do,总_334_st_3120,总_93_in_1F0,总_302_da_2870,clrGreen) ;
         }
         else
         {
           总_230_in_1E08 = NativeSendOrder(总_336_st_3130,ORDER_TYPE_BUY_STOP,总_223_do_1AC4_si99[总_328_in_3100],子_4_do,int(总_38_do_C0 * 总_229_do_1E00),0.0,0.0,总_334_st_3120,总_93_in_1F0,总_302_da_2870,clrGreen) ;
         }
         总_280_bo_25FA = false ;
         if ( 总_230_in_1E08 <= 0 )
         {
           临_in_16 = NativeTradeRetcode();
           if ( 临_in_16 == TRADE_RETCODE_MARKET_CLOSED )
           {
             ResetLastError();
             
               do
               {
                 Sleep(2500); 
                 if ( !(setSL_TP_After_Entry) )
                 {
                   临_in_16 = (int)(总_38_do_C0 * 总_229_do_1E00);
                   总_230_in_1E08 = NativeSendOrder(总_336_st_3130,ORDER_TYPE_BUY_STOP,总_223_do_1AC4_si99[总_328_in_3100],子_4_do,临_in_16,子_5_do,子_6_do,总_334_st_3120,总_93_in_1F0,总_302_da_2870,clrGreen) ;
                 }
                 else
                 {
                   总_230_in_1E08 = NativeSendOrder(总_336_st_3130,ORDER_TYPE_BUY_STOP,总_223_do_1AC4_si99[总_328_in_3100],子_4_do,int(总_38_do_C0 * 总_229_do_1E00),0.0,0.0,总_334_st_3120,总_93_in_1F0,总_302_da_2870,clrGreen) ;
                 }
                 总_280_bo_25FA = false ;
               }
               while(NativeTradeRetcode() == TRADE_RETCODE_MARKET_CLOSED);
               
             
           }
           Print("error: \'" + NativeTradeRetcodeText(NativeTradeRetcode()) + "\' when setting entry order"); 
         }
         else
         {
           临_do_17 = 子_3_do;
           临_lo_18 = 总_230_in_1E08;
           for (临_in_19 = 0 ; 临_in_19 < 100 ; 临_in_19=临_in_19 + 1)
           {
             if ( !(总_198_do_1070_si100si2[临_in_19][0]==0.0) )   continue;
             总_198_do_1070_si100si2[临_in_19][0] = (double)临_lo_18;
             总_198_do_1070_si100si2[临_in_19][1] = 临_do_17;
             break;
             
           }
         }
       }
     }
     return(true); 
   }
 }
 return(false); 
 }
//lizong_16 <<==--------   --------
 bool lizong_17( int 木_0_in)
 {
  bool      子_2_bo;
  double    子_3_do;
  double    子_4_do;
  double    子_5_do;
  double    子_6_do;
//----- -----
 bool       临_bo_1;
 int        临_in_2;
 double     临_do_3;
 int        临_in_4;
 bool       临_bo_5;
 int        临_in_6;
 int        临_in_7;
 double     临_do_8;
 int        临_in_9;
 double     临_do_10;
 int        临_in_11;
 bool       临_bo_12;
 bool       临_bo_13;
 int        临_in_14;
 bool       临_bo_15;
 int        临_in_16;
 double     临_do_17;
 long       临_lo_18;
 int        临_in_19;

 if ( !(AllowSellTrades) )
 {
   return(false); 
 }
 if ( 总_218_bo_1A74 )
 {
   临_bo_1 = false;
 }
 else
 {
   临_bo_1=false; 
   for (临_in_2 = 0 ; 临_in_2 < NativeTradesTotal() ; 临_in_2=临_in_2 + 1)
   {
     if ( g_trade_view.Select(临_in_2,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true || g_trade_view.OrderType() != ORDER_TYPE_SELL || g_trade_view.Magic() != 总_93_in_1F0 || g_trade_view.SymbolName() != 总_336_st_3130 )   continue;
     临_bo_1 = true;
      break;
     
   }
 }
 if ( 临_bo_1 == true )
 {
   return(false); 
 }
 if ( 总_213_bo_1710 && 总_268_do_25A8>总_269_do_25B0 )
 {
   return(false); 
 }
 if ( 木_0_in == 1 )
 {
   lizong_12(总_71_in_174); 
   子_2_bo = false ;
   临_do_3 = 总_261_do_2578;
   临_bo_5=false; 
   for (临_in_4 = NativeTradesTotal() ; 临_in_4 >= 0 ; 临_in_4=临_in_4 - 1)
   {
     if ( g_trade_view.Select(临_in_4,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true || g_trade_view.Magic() != 总_93_in_1F0 || g_trade_view.SymbolName() != 总_336_st_3130 || g_trade_view.OrderType() != ORDER_TYPE_SELL_STOP || !(MathAbs(g_trade_view.PriceOpen() - (临_do_3 - 总_84_do_1B8 * 总_229_do_1E00))<总_88_do_1D0 * 总_229_do_1E00) )   continue;
     临_bo_5 = true;
      break;
     
   }
   if ( !(临_bo_5) )
   {
     临_in_6 = 0;
     for (临_in_7 = NativeTradesTotal() ; 临_in_7 >= 0 ; 临_in_7=临_in_7 - 1)
     {
       if ( g_trade_view.Select(临_in_7,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true || g_trade_view.Magic() != 总_93_in_1F0 || g_trade_view.SymbolName() != 总_336_st_3130 || g_trade_view.OrderType() != ORDER_TYPE_SELL_STOP )   continue;
       临_in_6=临_in_6 + 1;
       
     }
     if ( 临_in_6 == 总_86_in_1C8 )
     {
       临_do_8 = 0.0;
       for (临_in_9 = NativeTradesTotal() ; 临_in_9 >= 0 ; 临_in_9=临_in_9 - 1)
       {
         if ( g_trade_view.Select(临_in_9,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true || g_trade_view.Magic() != 总_93_in_1F0 || g_trade_view.SymbolName() != 总_336_st_3130 || g_trade_view.OrderType() != ORDER_TYPE_SELL_STOP || !(g_trade_view.PriceOpen()>临_do_8) )   continue;
         临_do_8 = g_trade_view.PriceOpen();
         
       }
       if ( 总_261_do_2578<临_do_8 )
       {
         return(false); 
       }
     }
     总_263_do_2588 = 总_261_do_2578 ;
     子_2_bo = true ;
     总_189_do_510 = NormalizeDouble(总_261_do_2578,总_190_in_518) ;
   }
   if ( 总_189_do_510==0.0 )
   {
     return(false); 
   }
   if ( 子_2_bo )
   {
     总_247_do_2500 = 总_129_do_318 ;
     子_3_do = NormalizeDouble(总_189_do_510 - 总_84_do_1B8 * 总_229_do_1E00,总_190_in_518) ;
     临_do_10 = 子_3_do;
     临_bo_12=false; 
     for (临_in_11 = NativeTradesTotal() ; 临_in_11 >= 0 ; 临_in_11=临_in_11 - 1)
     {
       if ( g_trade_view.Select(临_in_11,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true || g_trade_view.Magic() != 总_93_in_1F0 || g_trade_view.SymbolName() != 总_336_st_3130 || g_trade_view.OrderType() != ORDER_TYPE_SELL_STOP || !(g_trade_view.PriceOpen()>=临_do_10) )   continue;
       临_bo_12 = true;
        break;
       
     }
     if ( 临_bo_12 )
     {
       return(false); 
     }
     总_311_do_28A8 = 子_3_do ;
     if ( !(总_67_bo_158) )
     {
       if ( CheckMargin && NativeFreeMarginAfterOrder(总_336_st_3130,ORDER_TYPE_SELL,总_223_do_1AC4_si99[总_328_in_3100])<=0.0 )
       {
         Print("Free margin not sufficient for setting order..."); 
         return(false); 
       }
       子_4_do = NormalizeDouble(子_3_do - 总_15_in_78 * 总_229_do_1E00,总_190_in_518) ;
       子_5_do = NormalizeDouble((总_100_do_230 + 总_64_do_148) * 总_229_do_1E00 + 子_3_do,总_190_in_518) ;
       子_6_do = NormalizeDouble(子_3_do - 总_101_do_238 * 总_229_do_1E00,总_190_in_518) ;
       if ( 总_223_do_1AC4_si99[总_328_in_3100]<SymbolInfoDouble(总_336_st_3130,SYMBOL_VOLUME_MIN) )
       {
         Print("Volume is less than the minimal allowed SYMBOL_VOLUME_MIN=" + string(SymbolInfoDouble(总_336_st_3130,SYMBOL_VOLUME_MIN))); 
         临_bo_13 = false;
       }
       else
       {
         if ( 总_223_do_1AC4_si99[总_328_in_3100]>SymbolInfoDouble(总_336_st_3130,SYMBOL_VOLUME_MAX) )
         {
           Print("Volume is greater than the maximal allowed SYMBOL_VOLUME_MAX=" + string(SymbolInfoDouble(总_336_st_3130,SYMBOL_VOLUME_MAX))); 
           临_bo_13 = false;
         }
         else
         {
           if ( MathAbs(NormalizeDouble(总_223_do_1AC4_si99[总_328_in_3100] / SymbolInfoDouble(总_336_st_3130,SYMBOL_VOLUME_STEP),0) * SymbolInfoDouble(总_336_st_3130,SYMBOL_VOLUME_STEP) - 总_223_do_1AC4_si99[总_328_in_3100])>0.0000001 )
           {
             Print("Volume " + string(总_223_do_1AC4_si99[总_328_in_3100]) + " is not a multiple of the minimal step SYMBOL_VOLUME_STEP=" + string(SymbolInfoDouble(总_336_st_3130,SYMBOL_VOLUME_STEP))); 
             临_bo_13 = false;
           }
           else
           {
             临_bo_13 = true;
           }
         }
       }

       临_in_14 = (int)AccountInfoInteger(ACCOUNT_LIMIT_ORDERS);
       if ( 临_in_14 == 0 )
       {
         临_bo_15 = true;
       }
       else
       {
         临_bo_15 = NativeTradesTotal()<临_in_14;
       }
       if ( ( !(临_bo_13) || !(临_bo_15) ) )
       {
         return(false); 
       }
       if ( SymbolInfoDouble(总_336_st_3130,SYMBOL_BID)>总_309_do_2898 + 子_4_do && SymbolInfoDouble(总_336_st_3130,SYMBOL_BID)>总_221_do_1A80 + 子_4_do )
       {
         if ( !(setSL_TP_After_Entry) )
         {
           总_230_in_1E08 = NativeSendOrder(总_336_st_3130,ORDER_TYPE_SELL_STOP,总_223_do_1AC4_si99[总_328_in_3100],子_4_do,int(总_38_do_C0 * 总_229_do_1E00),子_5_do,子_6_do,总_334_st_3120,总_93_in_1F0,总_302_da_2870,clrRed) ;
         }
         else
         {
           总_230_in_1E08 = NativeSendOrder(总_336_st_3130,ORDER_TYPE_SELL_STOP,总_223_do_1AC4_si99[总_328_in_3100],子_4_do,int(总_38_do_C0 * 总_229_do_1E00),0.0,0.0,总_334_st_3120,总_93_in_1F0,总_302_da_2870,clrRed) ;
         }
         总_281_bo_25FB = false ;
         if ( 总_230_in_1E08 <= 0 )
         {
           临_in_16 = NativeTradeRetcode();
           if ( 临_in_16 == TRADE_RETCODE_MARKET_CLOSED )
           {
             ResetLastError();
             
               do
               {
                 Sleep(2500); 
                 if ( !(setSL_TP_After_Entry) )
                 {
                   临_in_16 = (int)(总_38_do_C0 * 总_229_do_1E00);
                   总_230_in_1E08 = NativeSendOrder(总_336_st_3130,ORDER_TYPE_SELL_STOP,总_223_do_1AC4_si99[总_328_in_3100],子_4_do,临_in_16,子_5_do,子_6_do,总_334_st_3120,总_93_in_1F0,总_302_da_2870,clrRed) ;
                 }
                 else
                 {
                   总_230_in_1E08 = NativeSendOrder(总_336_st_3130,ORDER_TYPE_SELL_STOP,总_223_do_1AC4_si99[总_328_in_3100],子_4_do,int(总_38_do_C0 * 总_229_do_1E00),0.0,0.0,总_334_st_3120,总_93_in_1F0,总_302_da_2870,clrRed) ;
                 }
                 总_281_bo_25FB = false ;
               }
               while(NativeTradeRetcode() == TRADE_RETCODE_MARKET_CLOSED);
               
             
           }
           Print("error: \'" + NativeTradeRetcodeText(NativeTradeRetcode()) + "\' when setting entry order"); 
         }
         else
         {
           临_do_17 = 子_3_do;
           临_lo_18 = 总_230_in_1E08;
           for (临_in_19 = 0 ; 临_in_19 < 100 ; 临_in_19=临_in_19 + 1)
           {
             if ( !(总_198_do_1070_si100si2[临_in_19][0]==0.0) )   continue;
             总_198_do_1070_si100si2[临_in_19][0] = (double)临_lo_18;
             总_198_do_1070_si100si2[临_in_19][1] = 临_do_17;
             break;
             
           }
         }
       }
     }
   }
 }
 return(false); 
 }
//lizong_17 <<==--------   --------
 bool lizong_18()
 {
  bool      子_2_bo = false;
  bool      子_3_bo = false;
  double    子_4_do;
  double    子_5_do;
  int       子_6_in;
  double    子_7_do;
  double    子_8_do;
  long      子_9_lo;
  double    子_10_do;
  string    子_11_st;
  double    子_12_do;
  datetime  子_13_da;
  int       子_14_in;
  int       子_15_in;
  string    子_16_st;
  double    子_17_do;
  double    子_18_do;
  bool      子_19_bo;
  bool      子_20_bo;
  double    子_21_do;
  bool      子_22_bo;
  double    子_23_do;
  double    子_24_do;
  double    子_25_do;
  double    子_26_do;
  double    子_27_do;
  int       子_28_in;
  double    子_29_do;
//----- -----
 int        临_in_1;
 long       临_lo_2;
 int        临_in_3;
 double     临_do_4;
 double     临_do_5;
 long       临_lo_6;
 int        临_in_7;
 long       临_lo_8;
 int        临_in_9;
 int        临_in_10;
 string     临_st_11;
 double     临_do_12;
 int        临_in_13;
 long       临_lo_14;
 double     临_do_15;
 int        临_in_16;
 long       临_lo_17;
 long       临_lo_18;
 int        临_in_19;
 int        临_in_20;
 int        临_in_21;
 string     临_st_22;
 long       临_lo_23;
 double     临_do_24;
 double     临_do_25;
 int        临_in_26;
 double     临_do_27;
 bool       临_bo_28;
 int        临_in_29;
 int        临_in_30;
 double     临_do_31;
 long       临_lo_32;
 int        临_in_33;
 long       临_lo_34;
 double     临_do_35;
 double     临_do_36;
 int        临_in_37;
 double     临_do_38;
 bool       临_bo_39;
 int        临_in_40;
 int        临_in_41;
 double     临_do_42;
 long       临_lo_43;
 int        临_in_44;

 // Pre-gate trade guard: preserve the strategy/lot state flow, but do not
 // emit modify/close/hedge requests before the tester/broker trade session opens.
 if ( (NativeSessionMarket(总_336_st_3130)?1.0:0.0)==0.0 )
 {
   return(false);
 }

 子_4_do = 0.0 ;
 子_5_do = 0.0 ;
 for (子_6_in = 0 ; 子_6_in < NativeTradesTotal() ; 子_6_in ++)
 {
   if ( g_trade_view.Select(子_6_in,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) == true )
   {
     子_2_bo = false ;
     子_7_do = NormalizeDouble(g_trade_view.StopLoss(),总_190_in_518) ;
     子_8_do = NormalizeDouble(g_trade_view.TakeProfit(),总_190_in_518) ;
     子_9_lo = g_trade_view.Ticket() ;
     子_10_do = NormalizeDouble(g_trade_view.PriceOpen(),总_190_in_518) ;
     子_11_st = g_trade_view.Comment() ;
     子_12_do = g_trade_view.Volume() ;
     子_13_da = g_trade_view.TimeOpen() ;
     子_14_in = g_trade_view.OrderType() ;
     子_15_in = g_trade_view.Magic() ;
     子_16_st = g_trade_view.SymbolName() ;
     if ( ( 子_14_in == 4 || 子_14_in == 2 ) && 总_69_in_160 == 2 && ( 总_95_in_204 == 0 || (总_95_in_204 == 1 && 子_16_st == 总_336_st_3130) ) && ( 子_15_in == 总_96_in_208 || 总_96_in_208 == 0 ) && ( 子_11_st == 总_97_st_210 || 总_97_st_210 == "" ) )
     {
       if ( ( 子_7_do==0.0 || 子_7_do==0.0 ) )
       {
         子_7_do = NormalizeDouble(子_10_do - 总_100_do_230 * 总_229_do_1E00,总_190_in_518) ;
         NativeModifyTrade(子_9_lo,子_10_do,子_7_do,子_8_do,0,clrGreen); 
       }
       if ( ( 子_8_do==0.0 || 子_8_do==0.0 ) )
       {
         子_8_do = NormalizeDouble(总_101_do_238 * 总_229_do_1E00 + 子_10_do,总_190_in_518) ;
         NativeModifyTrade(子_9_lo,子_10_do,子_7_do,子_8_do,0,clrGreen); 
       }
     }
     if ( 子_14_in == 0 && ( ( 子_15_in == 总_93_in_1F0 && 总_69_in_160 == 1 && 子_16_st == 总_336_st_3130 ) || (总_69_in_160 == 2 && ( 总_95_in_204 == 0 || (总_95_in_204 == 1 && 子_16_st == 总_336_st_3130) ) && ( 子_15_in == 总_96_in_208 || 总_96_in_208 == 0 ) && (子_11_st == 总_97_st_210 || 总_97_st_210 == "")) ) )
     {
       if ( ( 子_7_do==0.0 || 子_7_do==0.0 ) )
       {
         子_7_do = NormalizeDouble(子_10_do - 总_100_do_230 * 总_229_do_1E00,总_190_in_518) ;
         NativeModifyTrade(子_9_lo,子_10_do,子_7_do,子_8_do,0,clrGreen); 
       }
       if ( ( 子_8_do==0.0 || 子_8_do==0.0 ) )
       {
         子_8_do = NormalizeDouble(总_101_do_238 * 总_229_do_1E00 + 子_10_do,总_190_in_518) ;
         NativeModifyTrade(子_9_lo,子_10_do,子_7_do,子_8_do,0,clrGreen); 
       }
       if ( 总_53_bo_11C && iTime(总_336_st_3130,NativeTimeframe(总_52_in_118),总_51_in_114) <= 子_13_da && iTime(总_336_st_3130,NativeTimeframe(总_52_in_118),0) >  子_13_da && iClose(总_336_st_3130,NativeTimeframe(总_52_in_118),1)<iOpen(总_336_st_3130,NativeTimeframe(总_52_in_118),1) && iClose(总_336_st_3130,NativeTimeframe(总_52_in_118),1)<子_10_do )
       {
         NativeClosePosition(子_9_lo,子_12_do,SymbolInfoDouble(总_336_st_3130,SYMBOL_BID),0,clrRed); 
         Print("closing candle confirmation"); 
       }
       if ( 总_55_bo_124 && iTime(总_336_st_3130,NativeTimeframe(总_54_in_120),总_51_in_114) <= 子_13_da && iTime(总_336_st_3130,NativeTimeframe(总_54_in_120),0) >  子_13_da && iClose(总_336_st_3130,NativeTimeframe(总_54_in_120),1)<iOpen(总_336_st_3130,NativeTimeframe(总_54_in_120),1) && iClose(总_336_st_3130,NativeTimeframe(总_54_in_120),1)<子_10_do )
       {
         NativeClosePosition(子_9_lo,子_12_do,SymbolInfoDouble(总_336_st_3130,SYMBOL_BID),0,clrRed); 
         Print("closing candle confirmation"); 
       }
       if ( 总_57_bo_12C && iTime(总_336_st_3130,NativeTimeframe(总_56_in_128),总_51_in_114) <= 子_13_da && iTime(总_336_st_3130,NativeTimeframe(总_56_in_128),0) >  子_13_da && iClose(总_336_st_3130,NativeTimeframe(总_56_in_128),1)<iOpen(总_336_st_3130,NativeTimeframe(总_56_in_128),1) && iClose(总_336_st_3130,NativeTimeframe(总_56_in_128),1)<子_10_do )
       {
         NativeClosePosition(子_9_lo,子_12_do,SymbolInfoDouble(总_336_st_3130,SYMBOL_BID),0,clrRed); 
         Print("closing candle confirmation"); 
       }
       if ( 总_59_bo_134 && iTime(总_336_st_3130,NativeTimeframe(总_58_in_130),总_51_in_114) <= 子_13_da && iTime(总_336_st_3130,NativeTimeframe(总_58_in_130),0) >  子_13_da && iClose(总_336_st_3130,NativeTimeframe(总_58_in_130),1)<iOpen(总_336_st_3130,NativeTimeframe(总_58_in_130),1) && iClose(总_336_st_3130,NativeTimeframe(总_58_in_130),1)<子_10_do )
       {
         NativeClosePosition(子_9_lo,子_12_do,SymbolInfoDouble(总_336_st_3130,SYMBOL_BID),0,clrRed); 
         Print("closing candle confirmation"); 
       }
       if ( 总_61_bo_13C && iTime(总_336_st_3130,NativeTimeframe(总_60_in_138),总_51_in_114) <= 子_13_da && iTime(总_336_st_3130,NativeTimeframe(总_60_in_138),0) >  子_13_da && iClose(总_336_st_3130,NativeTimeframe(总_60_in_138),1)<iOpen(总_336_st_3130,NativeTimeframe(总_60_in_138),1) && iClose(总_336_st_3130,NativeTimeframe(总_60_in_138),1)<子_10_do )
       {
         NativeClosePosition(子_9_lo,子_12_do,SymbolInfoDouble(总_336_st_3130,SYMBOL_BID),0,clrRed); 
         Print("closing candle confirmation"); 
       }
       总_247_do_2500 = 总_129_do_318 ;
       if ( 总_133_in_338 >  0 && TimeCurrent() >  子_13_da + 总_133_in_338 * 60 )
       {
         总_247_do_2500 = 总_134_do_340 ;
       }
       临_in_1 = 总_190_in_518;
       临_lo_2 = 子_9_lo;
       临_do_4 = 0.0;
       for (临_in_3 = 0 ; 临_in_3 < 100 ; 临_in_3=临_in_3 + 1)
       {
         if ( !(总_198_do_1070_si100si2[临_in_3][0]==临_lo_2) )   continue;
         临_do_4 = 总_198_do_1070_si100si2[临_in_3][1];
         break;
         
       }
       子_17_do = NormalizeDouble(临_do_4,临_in_1) ;
       if ( 子_17_do==0.0 )
       {
         临_do_5 = 子_10_do;
         临_lo_6 = 子_9_lo;
         for (临_in_7 = 0 ; 临_in_7 < 100 ; 临_in_7=临_in_7 + 1)
         {
           if ( !(总_198_do_1070_si100si2[临_in_7][0]==0.0) )   continue;
           总_198_do_1070_si100si2[临_in_7][0] = (double)临_lo_6;
           总_198_do_1070_si100si2[临_in_7][1] = 临_do_5;
           break;
           
         }
         子_17_do = 子_10_do ;
       }
       else
       {
         子_17_do = 子_17_do - 总_85_do_1C0 * 总_229_do_1E00 ;
       }
       子_18_do = 子_10_do - 子_17_do ;
       子_19_bo = false ;
       if ( 子_17_do>0.0 - 总_85_do_1C0 * 总_229_do_1E00 && 子_18_do>总_38_do_C0 * 总_229_do_1E00 )
       {
         子_19_bo = true ;
         if ( 总_39_in_C8 == 2 )
         {
           总_247_do_2500 = -1000.0 ;
           Print("Slippage control active"); 
         }
       }
       if ( 总_43_bo_E8 )
       {
         子_5_do = 子_17_do ;
       }
       else
       {
         子_5_do = 子_10_do ;
       }
       // EX5 behavior: maximum-loss is a virtual close boundary here.
       // Do not rewrite the broker SL on every management pass.
       if ( SymbolInfoDouble(总_336_st_3130,SYMBOL_BID)<子_10_do - (总_100_do_230 + 总_64_do_148) * 总_229_do_1E00 - 总_1_do_0 )
       {
         NativeClosePosition(g_trade_view.Ticket(),g_trade_view.Volume(),SymbolInfoDouble(总_336_st_3130,SYMBOL_BID),(int)总_1_do_0,clrRed); 
         return(true); 
       }
       子_20_bo = false ;
       if ( 总_159_bo_464 )
       {
         临_lo_8 = 子_9_lo;
         临_in_9 = 0;
         for (临_in_10 = NativeTradesTotal() ; 临_in_10 >= 0 ; 临_in_10=临_in_10 - 1)
         {
           if ( g_trade_view.Select(临_in_10,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true || g_trade_view.Magic() != 总_168_in_4A8 || g_trade_view.SymbolName() != 总_336_st_3130 )   continue;
           临_st_11 = g_trade_view.Comment();
           if ( 临_st_11 != IntegerToString(临_lo_8,0,32) )   continue;
           临_in_9=临_in_9 + 1;
           
         }
         子_21_do = 临_in_9 ;
         子_22_bo = false ;
         if ( !(总_194_bo_530) )
         {
           总_194_bo_530 = true ;
           总_192_in_528 = 0 ;
         }
         if ( 子_21_do==0.0 )
         {
           总_192_in_528 = 0 ;
         }
         if ( MathFloor(子_21_do / 2.0)==子_21_do / 2.0 )
         {
           总_192_in_528 = 0 ;
         }
         else
         {
           总_192_in_528 = 1 ;
         }
         if ( 总_194_bo_530 )
         {
           if ( 子_21_do>0.0 )
           {
             临_do_12 = AccountInfoDouble(ACCOUNT_EQUITY);
             if ( 临_do_12>AccountInfoDouble(ACCOUNT_BALANCE) + 总_163_do_480 )
             {
               for (临_in_13 = NativeTradesTotal() ; 临_in_13 >= 0 ; 临_in_13=临_in_13 - 1)
               {
                 if ( g_trade_view.Select(临_in_13,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true )   continue;
                 
                 if ( ( g_trade_view.Magic() != 总_93_in_1F0 && g_trade_view.Magic() != 总_169_in_4AC && g_trade_view.Magic() != 总_168_in_4A8 ) )   continue;
                 
                 if ( g_trade_view.OrderType() == ORDER_TYPE_BUY )
                 {
                   NativeClosePosition(g_trade_view.Ticket(),g_trade_view.Volume(),SymbolInfoDouble(总_336_st_3130,SYMBOL_BID),(int)总_38_do_C0,clrRed); 
                 }
                 if ( g_trade_view.OrderType() != ORDER_TYPE_SELL )   continue;
                 NativeClosePosition(g_trade_view.Ticket(),g_trade_view.Volume(),SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK),(int)总_38_do_C0,clrRed); 
                 
               }
             }
           }
           if ( 子_21_do>0.0 )
           {
             临_lo_14 = 子_9_lo;
             临_do_15 = 0.0;
             for (临_in_16 = NativeTradesTotal() ; 临_in_16 >= 0 ; 临_in_16=临_in_16 - 1)
             {
               if ( g_trade_view.Select(临_in_16,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true )   continue;
               临_lo_17 = g_trade_view.Ticket();
               if ( 临_lo_17 != 临_lo_14 )
               {
                 临_st_11 = g_trade_view.Comment();
               if ( 临_st_11 != IntegerToString(临_lo_14,0,32) )   continue;
               }
               临_do_15 = 临_do_15 + g_trade_view.Profit();
               
             }
             if ( 临_do_15>总_163_do_480 )
             {
               临_lo_18 = 子_9_lo;
               for (临_in_19 = NativeTradesTotal() ; 临_in_19 >= 0 ; 临_in_19=临_in_19 - 1)
               {
                 if ( g_trade_view.Select(临_in_19,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true )   continue;
                 
                 if ( g_trade_view.Magic() == 总_93_in_1F0 && g_trade_view.Ticket() == 临_lo_18 )
                 {
                   NativeClosePosition(g_trade_view.Ticket(),g_trade_view.Volume(),SymbolInfoDouble(总_336_st_3130,SYMBOL_BID),3,clrRed); 
                 }
                 if ( g_trade_view.Magic() != 总_168_in_4A8 )   continue;
                 临_st_11 = g_trade_view.Comment();
                 if ( 临_st_11 != IntegerToString(临_lo_18,0,32) )   continue;
                 
                 if ( g_trade_view.OrderType() == ORDER_TYPE_BUY )
                 {
                   NativeClosePosition(g_trade_view.Ticket(),g_trade_view.Volume(),SymbolInfoDouble(总_336_st_3130,SYMBOL_BID),(int)总_38_do_C0,clrRed); 
                 }
                 if ( g_trade_view.OrderType() != ORDER_TYPE_SELL )   continue;
                 NativeClosePosition(g_trade_view.Ticket(),g_trade_view.Volume(),SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK),(int)总_38_do_C0,clrRed); 
                 
               }
               总_194_bo_530 = false ;
               子_20_bo = true ;
             }
           }
           else
           {
             子_23_do = 子_12_do * 总_165_do_490 ;
             if ( 总_164_in_488 == 2 )
             {
               子_23_do = (子_21_do + 1.0) * 子_12_do + 子_12_do ;
             }
             if ( 总_164_in_488 == 3 )
             {
               子_23_do = 子_12_do * (MathPow(总_165_do_490,子_21_do + 1.0)) ;
             }
             if ( 总_192_in_528 == 0 )
             {
               子_24_do = 子_21_do * 总_161_do_470 * 总_229_do_1E00 + (子_17_do - 总_160_do_468 * 总_229_do_1E00) ;
               if ( 子_24_do>子_17_do - 总_162_do_478 * 总_229_do_1E00 )
               {
                 子_24_do = 子_17_do - 总_162_do_478 * 总_229_do_1E00 ;
               }
               if ( SymbolInfoDouble(总_336_st_3130,SYMBOL_BID)<子_24_do )
               {
                 if ( 子_21_do>=总_166_in_498 )
                 {
                   for (临_in_20 = NativeTradesTotal() ; 临_in_20 >= 0 ; 临_in_20=临_in_20 - 1)
                   {
                     if ( g_trade_view.Select(临_in_20,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true )   continue;
                     
                     if ( g_trade_view.Magic() == 总_93_in_1F0 && g_trade_view.Ticket() == 子_9_lo )
                     {
                       NativeClosePosition(g_trade_view.Ticket(),g_trade_view.Volume(),SymbolInfoDouble(总_336_st_3130,SYMBOL_BID),3,clrRed); 
                     }
                     if ( g_trade_view.Magic() != 总_168_in_4A8 )   continue;
                     临_st_11 = g_trade_view.Comment();
                     if ( 临_st_11 != IntegerToString(子_9_lo,0,32) )   continue;
                     
                     if ( g_trade_view.OrderType() == ORDER_TYPE_BUY )
                     {
                       NativeClosePosition(g_trade_view.Ticket(),g_trade_view.Volume(),SymbolInfoDouble(总_336_st_3130,SYMBOL_BID),(int)总_38_do_C0,clrRed); 
                     }
                     if ( g_trade_view.OrderType() != ORDER_TYPE_SELL )   continue;
                     NativeClosePosition(g_trade_view.Ticket(),g_trade_view.Volume(),SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK),(int)总_38_do_C0,clrRed); 
                     
                   }
                 }
                 else
                 {
                   NativeSendOrder(总_336_st_3130,ORDER_TYPE_SELL,子_23_do,SymbolInfoDouble(总_336_st_3130,SYMBOL_BID),(int)总_38_do_C0,0.0,0.0,IntegerToString(子_9_lo,0,32),总_168_in_4A8,0,clrGreen); 
                   总_192_in_528 = 1 ;
                   子_22_bo = true ;
                 }
               }
             }
             else
             {
               子_25_do = 子_17_do ;
               if ( SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK)>子_17_do )
               {
                 if ( 子_21_do>=总_166_in_498 )
                 {
                   for (临_in_21 = NativeTradesTotal() ; 临_in_21 >= 0 ; 临_in_21=临_in_21 - 1)
                   {
                     if ( g_trade_view.Select(临_in_21,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true )   continue;
                     
                     if ( g_trade_view.Magic() == 总_93_in_1F0 && g_trade_view.Ticket() == 子_9_lo )
                     {
                       NativeClosePosition(g_trade_view.Ticket(),g_trade_view.Volume(),SymbolInfoDouble(总_336_st_3130,SYMBOL_BID),3,clrRed); 
                     }
                     if ( g_trade_view.Magic() != 总_168_in_4A8 )   continue;
                     临_st_22 = g_trade_view.Comment();
                     if ( 临_st_22 != IntegerToString(子_9_lo,0,32) )   continue;
                     
                     if ( g_trade_view.OrderType() == ORDER_TYPE_BUY )
                     {
                       NativeClosePosition(g_trade_view.Ticket(),g_trade_view.Volume(),SymbolInfoDouble(总_336_st_3130,SYMBOL_BID),(int)总_38_do_C0,clrRed); 
                     }
                     if ( g_trade_view.OrderType() != ORDER_TYPE_SELL )   continue;
                     NativeClosePosition(g_trade_view.Ticket(),g_trade_view.Volume(),SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK),(int)总_38_do_C0,clrRed); 
                     
                   }
                 }
                 else
                 {
                   NativeSendOrder(总_336_st_3130,ORDER_TYPE_BUY,子_23_do,SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK),(int)总_38_do_C0,0.0,0.0,IntegerToString(子_9_lo,0,32),总_168_in_4A8,0,clrGreen); 
                   总_192_in_528 = 0 ;
                   子_22_bo = true ;
                 }
               }
             }
           }
         }
         if ( ( 子_21_do>0.0 || 子_22_bo ) )
         {
           子_20_bo = true ;
         }
       }
       if ( !(子_20_bo) )
       {
         if ( ( 总_63_in_140 == 1 || (总_63_in_140 != 3 && 总_63_in_140 != 2) ) )
         {
           临_lo_23 = 子_9_lo;
           临_do_24 = 总_100_do_230;
           临_do_25 = 子_10_do;
           临_in_26 = 1;
           临_do_27 = 0.0;
           临_bo_28 = false;
           for (临_in_29 = 0 ; 临_in_29 < 总_199_in_16B0 ; 临_in_29=临_in_29 + 1)
           {
             if ( 总_196_do_568_si20si2[临_in_29][0]==临_lo_23 )
             {
               临_do_27 = 总_196_do_568_si20si2[临_in_29][1];
               临_bo_28 = true;
               break;
             }
           }
           if ( !(临_bo_28) )
           {
             if ( 临_in_26 == 1 )
             {
               临_do_27 = NormalizeDouble(临_do_25 - 临_do_24 * 总_229_do_1E00,总_190_in_518);
             }
             if ( 临_in_26 == 2 )
             {
               临_do_27 = NormalizeDouble(临_do_24 * 总_229_do_1E00 + 临_do_25,总_190_in_518);
             }
             for (临_in_30 = 0 ; 临_in_30 < 总_199_in_16B0 ; 临_in_30=临_in_30 + 1)
             {
               if ( 总_196_do_568_si20si2[临_in_30][0]==0.0 )
               {
                 总_196_do_568_si20si2[临_in_30][0] = (double)临_lo_23;
                 总_196_do_568_si20si2[临_in_30][1] = 临_do_27;
                 break;
               }
             }
           }
           总_191_do_520 = 临_do_27 ;
           子_4_do = 总_191_do_520 ;
           if ( SymbolInfoDouble(总_336_st_3130,SYMBOL_BID)<子_4_do )
           {
             Print("Closing with virtual SL"); 
             NativeClosePosition(子_9_lo,子_12_do,SymbolInfoDouble(总_336_st_3130,SYMBOL_BID),(int)总_1_do_0,0xFFFFFFFF); 
             return(true); 
           }
           if ( 总_125_do_2F8>0.0 && TimeCurrent() >= 子_13_da + 总_304_in_287C && SymbolInfoDouble(总_336_st_3130,SYMBOL_BID)>NormalizeDouble(总_126_do_300 * 总_229_do_1E00 + (子_7_do + 总_337_do_3140),总_190_in_518) && SymbolInfoDouble(总_336_st_3130,SYMBOL_BID)<子_8_do - 总_309_do_2898 )
           {
             子_7_do = NormalizeDouble(SymbolInfoDouble(总_336_st_3130,SYMBOL_BID) - 总_126_do_300 * 总_229_do_1E00,总_190_in_518) ;
             if ( 子_7_do<SymbolInfoDouble(总_336_st_3130,SYMBOL_BID) - 总_221_do_1A80 )
             {
               总_230_in_1E08 = NativeModifyTrade(子_9_lo,子_10_do,子_7_do,子_8_do,0,0xFFFFFFFF) ;
               if ( 总_230_in_1E08 <= 0 )
               {
                 Print("TrailStop error: \'" + NativeTradeRetcodeText(NativeTradeRetcode()) + "\' when setting trailing Exit_TrailSL_after_X_Minutes_size_ loss.  Trying again!"); 
               }
               子_2_bo = true ;
             }
           }
           if ( 总_103_do_250>0.0 && SymbolInfoDouble(总_336_st_3130,SYMBOL_BID)>NormalizeDouble((总_103_do_250 + 总_106_do_268) * 总_229_do_1E00 + (子_7_do + 总_337_do_3140),总_190_in_518) && SymbolInfoDouble(总_336_st_3130,SYMBOL_BID)>NormalizeDouble(总_104_do_258 * 总_229_do_1E00 + 子_10_do,总_190_in_518) && SymbolInfoDouble(总_336_st_3130,SYMBOL_BID)<子_8_do - 总_309_do_2898 && 子_7_do<NormalizeDouble(总_105_do_260 * 总_229_do_1E00 + 子_10_do,总_190_in_518) )
           {
             子_7_do = NormalizeDouble(SymbolInfoDouble(总_336_st_3130,SYMBOL_BID) - 总_103_do_250 * 总_229_do_1E00,总_190_in_518) ;
             if ( 子_7_do<SymbolInfoDouble(总_336_st_3130,SYMBOL_BID) - 总_221_do_1A80 )
             {
               总_230_in_1E08 = NativeModifyTrade(子_9_lo,子_10_do,子_7_do,子_8_do,0,0xFFFFFFFF) ;
               if ( 总_230_in_1E08 <= 0 )
               {
                 Print("TrailStop error: \'" + NativeTradeRetcodeText(NativeTradeRetcode()) + "\' when setting trailing Exit_stop_ loss.  Trying again!"); 
               }
               else
               {
                 子_26_do = NormalizeDouble(总_107_do_270 / 100.0 * 总_223_do_1AC4_si99[总_328_in_3100],2) ;
                 if ( 子_26_do<子_12_do && 子_26_do>=SymbolInfoDouble(总_336_st_3130,SYMBOL_VOLUME_STEP) )
                 {
                   NativeClosePosition(子_9_lo,子_26_do,SymbolInfoDouble(总_336_st_3130,SYMBOL_BID),(int)总_38_do_C0,clrRed); 
                   return(true); 
                 }
               }
               子_2_bo = true ;
             }
           }
           if ( 总_110_do_288>0.0 && SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK)<NormalizeDouble(子_8_do - 总_337_do_3140 - 总_110_do_288 * 总_229_do_1E00,总_190_in_518) && SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK)<NormalizeDouble(子_5_do - 总_111_do_290 * 总_229_do_1E00,总_190_in_518) && SymbolInfoDouble(总_336_st_3130,SYMBOL_BID)<子_8_do - 总_309_do_2898 )
           {
             子_8_do = NormalizeDouble(SymbolInfoDouble(总_336_st_3130,SYMBOL_BID) + 总_110_do_288 * 总_229_do_1E00,总_190_in_518) ;
             if ( 子_8_do>SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK) + 总_221_do_1A80 )
             {
               总_230_in_1E08 = NativeModifyTrade(子_9_lo,子_10_do,子_7_do,子_8_do,0,0xFFFFFFFF) ;
               if ( 总_230_in_1E08 <= 0 )
               {
                 Print("TrailStop error: \'" + NativeTradeRetcodeText(NativeTradeRetcode()) + "\' when setting trailing Exit_TP.  Trying again!"); 
               }
               else
               {
                 子_27_do = NormalizeDouble(总_107_do_270 / 100.0 * 总_223_do_1AC4_si99[总_328_in_3100],2) ;
                 if ( 子_27_do<子_12_do && 子_27_do>=SymbolInfoDouble(总_336_st_3130,SYMBOL_VOLUME_MIN) )
                 {
                   NativeClosePosition(子_9_lo,子_27_do,SymbolInfoDouble(总_336_st_3130,SYMBOL_BID),(int)总_38_do_C0,clrRed); 
                   return(true); 
                 }
               }
               子_2_bo = true ;
             }
           }
           if ( 子_19_bo && 总_39_in_C8 == 1 && 总_41_do_D8>0.0 && SymbolInfoDouble(总_336_st_3130,SYMBOL_BID)>NormalizeDouble(总_41_do_D8 * 总_229_do_1E00 + (子_7_do + 总_337_do_3140),总_190_in_518) && SymbolInfoDouble(总_336_st_3130,SYMBOL_BID)>NormalizeDouble(总_40_do_D0 * 总_229_do_1E00 + 子_17_do,总_190_in_518) && SymbolInfoDouble(总_336_st_3130,SYMBOL_BID)<子_8_do - 总_309_do_2898 && 子_7_do<NormalizeDouble(总_42_do_E0 * 总_229_do_1E00 + 子_10_do,总_190_in_518) )
           {
             子_7_do = NormalizeDouble(SymbolInfoDouble(总_336_st_3130,SYMBOL_BID) - 总_41_do_D8 * 总_229_do_1E00,总_190_in_518) ;
             if ( 子_7_do<SymbolInfoDouble(总_336_st_3130,SYMBOL_BID) - 总_221_do_1A80 )
             {
               总_230_in_1E08 = NativeModifyTrade(子_9_lo,子_10_do,子_7_do,子_8_do,0,0xFFFFFFFF) ;
               if ( 总_230_in_1E08 <= 0 )
               {
                 Print("TrailStop error: \'" + NativeTradeRetcodeText(NativeTradeRetcode()) + "\' when setting Slip TL.  Trying again!"); 
               }
               else
               {
                 Print("Slippage control active"); 
               }
               子_2_bo = true ;
             }
           }
           if ( 总_119_in_2D0 >  0 && 总_120_in_2D4 >= 0 && UseHL_TrailingSL && 总_242_do_21C4_si99[总_328_in_3100]>NormalizeDouble(子_7_do + 总_221_do_1A80 + 总_337_do_3140,总_190_in_518) && 总_242_do_21C4_si99[总_328_in_3100]<SymbolInfoDouble(总_336_st_3130,SYMBOL_BID) - 总_121_in_2D8 * 总_229_do_1E00 && ( 总_242_do_21C4_si99[总_328_in_3100]<子_10_do || !(总_116_bo_2C4) ) && 总_242_do_21C4_si99[总_328_in_3100]<NormalizeDouble(SymbolInfoDouble(总_336_st_3130,SYMBOL_BID) - 总_122_in_2DC * 总_229_do_1E00 - 总_221_do_1A80 - 总_337_do_3140,总_190_in_518) && SymbolInfoDouble(总_336_st_3130,SYMBOL_BID)<子_8_do - 总_309_do_2898 )
           {
             子_7_do = NormalizeDouble(总_242_do_21C4_si99[总_328_in_3100],总_190_in_518) ;
             if ( 子_7_do<SymbolInfoDouble(总_336_st_3130,SYMBOL_BID) - 总_221_do_1A80 )
             {
               总_230_in_1E08 = NativeModifyTrade(子_9_lo,子_10_do,子_7_do,子_8_do,0,0xFFFFFFFF) ;
               if ( 总_230_in_1E08 <= 0 )
               {
                 Print("error: \'" + NativeTradeRetcodeText(NativeTradeRetcode()) + "\' when modifying stoploss"); 
               }
               子_2_bo = true ;
             }
           }
           if ( 总_113_do_2A8>0.0 && SymbolInfoDouble(总_336_st_3130,SYMBOL_BID)>NormalizeDouble(总_113_do_2A8 * 总_229_do_1E00 + 子_10_do,总_190_in_518) && NormalizeDouble(总_114_do_2B0 * 总_229_do_1E00 + 子_10_do,总_190_in_518)>子_7_do + 总_337_do_3140 && SymbolInfoDouble(总_336_st_3130,SYMBOL_BID)>NormalizeDouble(总_114_do_2B0 * 总_229_do_1E00 + 子_10_do + 总_221_do_1A80,总_190_in_518) && SymbolInfoDouble(总_336_st_3130,SYMBOL_BID)<子_8_do - 总_309_do_2898 )
           {
             子_7_do = NormalizeDouble(总_114_do_2B0 * 总_229_do_1E00 + 子_10_do,总_190_in_518) ;
             if ( 子_7_do<SymbolInfoDouble(总_336_st_3130,SYMBOL_BID) - 总_221_do_1A80 )
             {
               总_230_in_1E08 = NativeModifyTrade(子_9_lo,子_10_do,子_7_do,子_8_do,0,0xFFFFFFFF) ;
               if ( 总_230_in_1E08 <= 0 )
               {
                 Print("error when setting breakeven: \'" + NativeTradeRetcodeText(NativeTradeRetcode()) + "\' ..\'Exit_BE_start_\' to close to \'Exit_BE_extra_pips_\' ..trying again!"); 
               }
               子_2_bo = true ;
             }
           }
           if ( !(子_2_bo) && ( 总_128_in_314 == 1 || (总_128_in_314 == 2 && 总_131_do_328 * 总_229_do_1E00 + 子_7_do<=总_132_do_330 * 总_229_do_1E00 + (子_5_do + 总_1_do_0)) ) )
           {
             总_250_in_2518 ++;
             if ( SymbolInfoDouble(总_336_st_3130,SYMBOL_BID)>总_131_do_328 * 总_229_do_1E00 + 子_7_do + 总_221_do_1A80 && SymbolInfoDouble(总_336_st_3130,SYMBOL_BID)<子_8_do - 总_309_do_2898 && ( 总_129_do_318==0.0 || SymbolInfoDouble(总_336_st_3130,SYMBOL_BID)>总_247_do_2500 * 总_229_do_1E00 + 子_5_do ) && 总_250_in_2518 >= 总_130_in_320 && NormalizeDouble(总_131_do_328 * 总_229_do_1E00 + 子_7_do,总_190_in_518)>子_7_do )
             {
               总_250_in_2518 = 0 ;
               子_7_do = NormalizeDouble(总_131_do_328 * 总_229_do_1E00 + 子_7_do,总_190_in_518) ;
               NativeModifyTrade(子_9_lo,子_10_do,子_7_do,子_8_do,0,0xFFFFFFFF); 
               子_2_bo = true ;
             }
           }
           总_191_do_520 = 子_7_do ;
           if ( SymbolInfoDouble(总_336_st_3130,SYMBOL_BID)<子_7_do )
           {
             Print("Closing with virtual SL"); 
             NativeClosePosition(子_9_lo,子_12_do,SymbolInfoDouble(总_336_st_3130,SYMBOL_BID),(int)总_1_do_0,0xFFFFFFFF); 
             return(true); 
           }
           if ( NormalizeDouble(子_4_do,总_190_in_518)!=NormalizeDouble(总_191_do_520,总_190_in_518) )
           {
             临_do_31 = NormalizeDouble(总_191_do_520,总_190_in_518);
             临_lo_32 = 子_9_lo;
             for (临_in_33 = 0 ; 临_in_33 < 总_199_in_16B0 ; 临_in_33=临_in_33 + 1)
             {
               if ( 总_196_do_568_si20si2[临_in_33][0]==临_lo_32 )
               {
                 总_196_do_568_si20si2[临_in_33][1] = 临_do_31;
                 break;
               }
             }
           }
           if ( 子_2_bo && 总_135_bo_348 )
           {
             return(true); 
           }
         }
         if ( ( 总_63_in_140 == 2 || 总_63_in_140 == 3 ) )
         {
           临_lo_34 = 子_9_lo;
           临_do_35 = 总_100_do_230;
           临_do_36 = 子_10_do;
           临_in_37 = 1;
           临_do_38 = 0.0;
           临_bo_39 = false;
           for (临_in_40 = 0 ; 临_in_40 < 总_199_in_16B0 ; 临_in_40=临_in_40 + 1)
           {
             if ( 总_196_do_568_si20si2[临_in_40][0]==临_lo_34 )
             {
               临_do_38 = 总_196_do_568_si20si2[临_in_40][1];
               临_bo_39 = true;
               break;
             }
           }
           if ( !(临_bo_39) )
           {
             if ( 临_in_37 == 1 )
             {
               临_do_38 = NormalizeDouble(临_do_36 - 临_do_35 * 总_229_do_1E00,总_190_in_518);
             }
             if ( 临_in_37 == 2 )
             {
               临_do_38 = NormalizeDouble(临_do_35 * 总_229_do_1E00 + 临_do_36,总_190_in_518);
             }
             for (临_in_41 = 0 ; 临_in_41 < 总_199_in_16B0 ; 临_in_41=临_in_41 + 1)
             {
               if ( 总_196_do_568_si20si2[临_in_41][0]==0.0 )
               {
                 总_196_do_568_si20si2[临_in_41][0] = (double)临_lo_34;
                 总_196_do_568_si20si2[临_in_41][1] = 临_do_38;
                 break;
               }
             }
           }
           总_191_do_520 = 临_do_38 ;
           子_4_do = 总_191_do_520 ;
           if ( SymbolInfoDouble(总_336_st_3130,SYMBOL_BID)<=子_4_do )
           {
             NativeClosePosition(子_9_lo,子_12_do,SymbolInfoDouble(总_336_st_3130,SYMBOL_BID),(int)总_1_do_0,0xFFFFFFFF); 
             return(true); 
           }
           子_28_in = (int)(TimeCurrent() - 总_319_da_28E0) ;
           if ( 子_28_in >= 总_65_in_150 )
           {
             if ( NormalizeDouble(总_191_do_520,总_190_in_518)>子_7_do + 总_337_do_3140 )
             {
               NativeModifyTrade(子_9_lo,子_10_do,NormalizeDouble(总_191_do_520,总_190_in_518),子_8_do,0,0xFFFFFFFF); 
             }
             总_319_da_28E0 = TimeCurrent() ;
           }
           if ( 总_125_do_2F8>0.0 && TimeCurrent() >= 子_13_da + 总_304_in_287C && SymbolInfoDouble(总_336_st_3130,SYMBOL_BID)>总_126_do_300 * 总_229_do_1E00 + (总_191_do_520 + 总_337_do_3140) && SymbolInfoDouble(总_336_st_3130,SYMBOL_BID)<子_8_do - 总_309_do_2898 )
           {
             子_2_bo = true ;
             总_191_do_520 = SymbolInfoDouble(总_336_st_3130,SYMBOL_BID) - 总_126_do_300 * 总_229_do_1E00 ;
           }
           if ( 总_103_do_250>0.0 && SymbolInfoDouble(总_336_st_3130,SYMBOL_BID)>(总_103_do_250 + 总_106_do_268) * 总_229_do_1E00 + (总_191_do_520 + 总_337_do_3140) && SymbolInfoDouble(总_336_st_3130,SYMBOL_BID)>总_104_do_258 * 总_229_do_1E00 + 子_5_do && 总_191_do_520<总_105_do_260 * 总_229_do_1E00 + 子_10_do )
           {
             子_2_bo = true ;
             总_191_do_520 = SymbolInfoDouble(总_336_st_3130,SYMBOL_BID) - 总_103_do_250 * 总_229_do_1E00 ;
             子_29_do = NormalizeDouble(总_107_do_270 / 100.0 * 总_223_do_1AC4_si99[总_328_in_3100],2) ;
             if ( 子_29_do<子_12_do && 子_29_do>=SymbolInfoDouble(总_336_st_3130,SYMBOL_VOLUME_STEP) )
             {
               NativeClosePosition(子_9_lo,子_29_do,SymbolInfoDouble(总_336_st_3130,SYMBOL_BID),(int)总_38_do_C0,clrRed); 
               return(true); 
             }
           }
           if ( 子_19_bo && 总_39_in_C8 == 1 && 总_41_do_D8>0.0 && SymbolInfoDouble(总_336_st_3130,SYMBOL_BID)>总_41_do_D8 * 总_229_do_1E00 + (总_191_do_520 + 总_337_do_3140) && SymbolInfoDouble(总_336_st_3130,SYMBOL_BID)>总_40_do_D0 * 总_229_do_1E00 + 子_17_do && SymbolInfoDouble(总_336_st_3130,SYMBOL_BID)<子_8_do - 总_309_do_2898 && 总_191_do_520<总_42_do_E0 * 总_229_do_1E00 + 子_10_do )
           {
             Print("Slippage control active"); 
             子_2_bo = true ;
             总_191_do_520 = SymbolInfoDouble(总_336_st_3130,SYMBOL_BID) - 总_41_do_D8 * 总_229_do_1E00 ;
           }
           if ( 总_119_in_2D0 >  0 && 总_120_in_2D4 >= 0 && 总_242_do_21C4_si99[总_328_in_3100]>总_191_do_520 + 总_221_do_1A80 + 总_337_do_3140 && ( 总_242_do_21C4_si99[总_328_in_3100]<子_10_do || !(总_116_bo_2C4) ) && 总_242_do_21C4_si99[总_328_in_3100]<SymbolInfoDouble(总_336_st_3130,SYMBOL_BID) - 总_122_in_2DC * 总_229_do_1E00 - 总_221_do_1A80 - 总_337_do_3140 && SymbolInfoDouble(总_336_st_3130,SYMBOL_BID)<子_8_do - 总_309_do_2898 )
           {
             总_191_do_520 = 总_242_do_21C4_si99[总_328_in_3100] ;
             子_2_bo = true ;
           }
           if ( 总_113_do_2A8>0.0 && 总_63_in_140 == 3 && SymbolInfoDouble(总_336_st_3130,SYMBOL_BID)>总_113_do_2A8 * 总_229_do_1E00 + 子_10_do && 总_114_do_2B0 * 总_229_do_1E00 + 子_10_do>子_7_do + 总_337_do_3140 && SymbolInfoDouble(总_336_st_3130,SYMBOL_BID)>总_114_do_2B0 * 总_229_do_1E00 + 子_10_do + 总_221_do_1A80 && SymbolInfoDouble(总_336_st_3130,SYMBOL_BID)<子_8_do - 总_309_do_2898 && NormalizeDouble(总_114_do_2B0 * 总_229_do_1E00 + 子_10_do,总_190_in_518)>g_trade_view.StopLoss() )
           {
             总_191_do_520 = NormalizeDouble(总_114_do_2B0 * 总_229_do_1E00 + 子_10_do,总_190_in_518) ;
             总_230_in_1E08 = NativeModifyTrade(子_9_lo,子_10_do,总_191_do_520,子_8_do,0,0xFFFFFFFF) ;
             if ( 总_230_in_1E08 <= 0 )
             {
               Print("error when setting breakeven: \'" + NativeTradeRetcodeText(NativeTradeRetcode()) + "\' ..\'Exit_BE_start_\' to close to \'Exit_BE_extra_pips_\' ..trying again!"); 
             }
             子_2_bo = true ;
           }
           if ( 总_113_do_2A8>0.0 && 总_63_in_140 == 2 && SymbolInfoDouble(总_336_st_3130,SYMBOL_BID)>总_113_do_2A8 * 总_229_do_1E00 + 子_10_do && 总_114_do_2B0 * 总_229_do_1E00 + 子_10_do>总_191_do_520 + 总_337_do_3140 && SymbolInfoDouble(总_336_st_3130,SYMBOL_BID)>总_114_do_2B0 * 总_229_do_1E00 + 子_10_do + 总_221_do_1A80 && SymbolInfoDouble(总_336_st_3130,SYMBOL_BID)<子_8_do - 总_309_do_2898 )
           {
             总_191_do_520 = 总_114_do_2B0 * 总_229_do_1E00 + 子_10_do ;
             子_2_bo = true ;
           }
           if ( !(子_2_bo) && ( 总_128_in_314 == 1 || (总_128_in_314 == 2 && 总_131_do_328 * 总_229_do_1E00 + 总_191_do_520<=总_132_do_330 * 总_229_do_1E00 + (子_5_do + 总_1_do_0)) ) )
           {
             总_250_in_2518 ++;
             if ( SymbolInfoDouble(总_336_st_3130,SYMBOL_BID)>总_131_do_328 * 总_229_do_1E00 + 总_191_do_520 + 总_221_do_1A80 && SymbolInfoDouble(总_336_st_3130,SYMBOL_BID)<子_8_do - 总_309_do_2898 && ( 总_129_do_318==0.0 || SymbolInfoDouble(总_336_st_3130,SYMBOL_BID)>总_247_do_2500 * 总_229_do_1E00 + 子_5_do ) && 总_250_in_2518 >= 总_130_in_320 )
             {
               总_250_in_2518 = 0 ;
               总_191_do_520 = 总_131_do_328 * 总_229_do_1E00 + 总_191_do_520 ;
               子_2_bo = true ;
             }
           }
           if ( SymbolInfoDouble(总_336_st_3130,SYMBOL_BID)<=总_191_do_520 )
           {
             NativeClosePosition(子_9_lo,子_12_do,SymbolInfoDouble(总_336_st_3130,SYMBOL_BID),(int)总_1_do_0,0xFFFFFFFF); 
             return(true); 
           }
           if ( NormalizeDouble(子_4_do,总_190_in_518)!=NormalizeDouble(总_191_do_520,总_190_in_518) )
           {
             临_do_42 = NormalizeDouble(总_191_do_520,总_190_in_518);
             临_lo_43 = 子_9_lo;
             for (临_in_44 = 0 ; 临_in_44 < 总_199_in_16B0 ; 临_in_44=临_in_44 + 1)
             {
               if ( 总_196_do_568_si20si2[临_in_44][0]==临_lo_43 )
               {
                 总_196_do_568_si20si2[临_in_44][1] = 临_do_42;
                 break;
               }
             }
           }
         }
       }
     }
     if ( 子_2_bo )
     {
       子_3_bo = true ;
     }
   }
   if ( 子_2_bo )
   {
     子_3_bo = true ;
   }
 }
 return(子_3_bo); 
 }
//lizong_18 <<==--------   --------
 bool lizong_19()
 {
  bool      子_2_bo = false;
  bool      子_3_bo = false;
  double    子_4_do;
  double    子_5_do;
  int       子_6_in;
  double    子_7_do;
  double    子_8_do;
  long      子_9_lo;
  double    子_10_do;
  string    子_11_st;
  double    子_12_do;
  datetime  子_13_da;
  int       子_14_in;
  int       子_15_in;
  string    子_16_st;
  double    子_17_do;
  double    子_18_do;
  bool      子_19_bo;
  bool      子_20_bo;
  double    子_21_do;
  bool      子_22_bo;
  double    子_23_do;
  double    子_24_do;
  double    子_25_do;
  double    子_26_do;
  double    子_27_do;
  int       子_28_in;
  double    子_29_do;
//----- -----
 int        临_in_1;
 long       临_lo_2;
 int        临_in_3;
 double     临_do_4;
 double     临_do_5;
 long       临_lo_6;
 int        临_in_7;
 long       临_lo_8;
 int        临_in_9;
 int        临_in_10;
 string     临_st_11;
 double     临_do_12;
 int        临_in_13;
 long       临_lo_14;
 double     临_do_15;
 int        临_in_16;
 long       临_lo_17;
 long       临_lo_18;
 int        临_in_19;
 int        临_in_20;
 int        临_in_21;
 string     临_st_22;
 long       临_lo_23;
 double     临_do_24;
 double     临_do_25;
 int        临_in_26;
 double     临_do_27;
 bool       临_bo_28;
 int        临_in_29;
 int        临_in_30;
 double     临_do_31;
 long       临_lo_32;
 int        临_in_33;
 long       临_lo_34;
 double     临_do_35;
 double     临_do_36;
 int        临_in_37;
 double     临_do_38;
 bool       临_bo_39;
 int        临_in_40;
 int        临_in_41;
 double     临_do_42;
 long       临_lo_43;
 int        临_in_44;

 // Same pre-gate protection as lizong_18().
 if ( (NativeSessionMarket(总_336_st_3130)?1.0:0.0)==0.0 )
 {
   return(false);
 }

 子_4_do = 0.0 ;
 子_5_do = 0.0 ;
 for (子_6_in = 0 ; 子_6_in < NativeTradesTotal() ; 子_6_in ++)
 {
   if ( g_trade_view.Select(子_6_in,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) == true )
   {
     子_2_bo = false ;
     子_7_do = NormalizeDouble(g_trade_view.StopLoss(),总_190_in_518) ;
     子_8_do = NormalizeDouble(g_trade_view.TakeProfit(),总_190_in_518) ;
     子_9_lo = g_trade_view.Ticket() ;
     子_10_do = NormalizeDouble(g_trade_view.PriceOpen(),总_190_in_518) ;
     子_11_st = g_trade_view.Comment() ;
     子_12_do = g_trade_view.Volume() ;
     子_13_da = g_trade_view.TimeOpen() ;
     子_14_in = g_trade_view.OrderType() ;
     子_15_in = g_trade_view.Magic() ;
     子_16_st = g_trade_view.SymbolName() ;
     if ( ( 子_14_in == 5 || 子_14_in == 3 ) && 总_69_in_160 == 2 && ( 总_95_in_204 == 0 || (总_95_in_204 == 1 && 子_16_st == 总_336_st_3130) ) && ( 子_15_in == 总_96_in_208 || 总_96_in_208 == 0 ) && ( 子_11_st == 总_97_st_210 || 总_97_st_210 == "" ) )
     {
       if ( ( 子_7_do==0.0 || 子_7_do==0.0 ) )
       {
         子_7_do = NormalizeDouble(总_100_do_230 * 总_229_do_1E00 + 子_10_do,总_190_in_518) ;
         NativeModifyTrade(子_9_lo,子_10_do,子_7_do,子_8_do,0,clrGreen); 
       }
       if ( ( 子_8_do==0.0 || 子_8_do==0.0 ) )
       {
         子_8_do = NormalizeDouble(子_10_do - 总_101_do_238 * 总_229_do_1E00,总_190_in_518) ;
         NativeModifyTrade(子_9_lo,子_10_do,子_7_do,子_8_do,0,clrGreen); 
       }
     }
     if ( 子_14_in == 1 && ( ( 子_15_in == 总_93_in_1F0 && 总_69_in_160 == 1 && 子_16_st == 总_336_st_3130 ) || (总_69_in_160 == 2 && ( 总_95_in_204 == 0 || (总_95_in_204 == 1 && 子_16_st == 总_336_st_3130) ) && ( 子_15_in == 总_96_in_208 || 总_96_in_208 == 0 ) && (子_11_st == 总_97_st_210 || 总_97_st_210 == "")) ) )
     {
       if ( ( 子_7_do==0.0 || 子_7_do==0.0 ) )
       {
         子_7_do = NormalizeDouble(总_100_do_230 * 总_229_do_1E00 + 子_10_do,总_190_in_518) ;
         NativeModifyTrade(子_9_lo,子_10_do,子_7_do,子_8_do,0,clrGreen); 
       }
       if ( ( 子_8_do==0.0 || 子_8_do==0.0 ) )
       {
         子_8_do = NormalizeDouble(子_10_do - 总_101_do_238 * 总_229_do_1E00,总_190_in_518) ;
         NativeModifyTrade(子_9_lo,子_10_do,子_7_do,子_8_do,0,clrGreen); 
       }
       if ( 总_53_bo_11C && iTime(总_336_st_3130,NativeTimeframe(总_52_in_118),总_51_in_114) <= 子_13_da && iTime(总_336_st_3130,NativeTimeframe(总_52_in_118),0) >  子_13_da && iClose(总_336_st_3130,NativeTimeframe(总_52_in_118),1)>iOpen(总_336_st_3130,NativeTimeframe(总_52_in_118),1) && iClose(总_336_st_3130,NativeTimeframe(总_52_in_118),1)>子_10_do )
       {
         NativeClosePosition(子_9_lo,子_12_do,SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK),0,clrRed); 
         Print("closing candle confirmation"); 
       }
       if ( 总_55_bo_124 && iTime(总_336_st_3130,NativeTimeframe(总_54_in_120),总_51_in_114) <= 子_13_da && iTime(总_336_st_3130,NativeTimeframe(总_54_in_120),0) >  子_13_da && iClose(总_336_st_3130,NativeTimeframe(总_54_in_120),1)>iOpen(总_336_st_3130,NativeTimeframe(总_54_in_120),1) && iClose(总_336_st_3130,NativeTimeframe(总_54_in_120),1)>子_10_do )
       {
         NativeClosePosition(子_9_lo,子_12_do,SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK),0,clrRed); 
         Print("closing candle confirmation"); 
       }
       if ( 总_57_bo_12C && iTime(总_336_st_3130,NativeTimeframe(总_56_in_128),总_51_in_114) <= 子_13_da && iTime(总_336_st_3130,NativeTimeframe(总_56_in_128),0) >  子_13_da && iClose(总_336_st_3130,NativeTimeframe(总_56_in_128),1)>iOpen(总_336_st_3130,NativeTimeframe(总_56_in_128),1) && iClose(总_336_st_3130,NativeTimeframe(总_56_in_128),1)>子_10_do )
       {
         NativeClosePosition(子_9_lo,子_12_do,SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK),0,clrRed); 
         Print("closing candle confirmation"); 
       }
       if ( 总_59_bo_134 && iTime(总_336_st_3130,NativeTimeframe(总_58_in_130),总_51_in_114) <= 子_13_da && iTime(总_336_st_3130,NativeTimeframe(总_58_in_130),0) >  子_13_da && iClose(总_336_st_3130,NativeTimeframe(总_58_in_130),1)>iOpen(总_336_st_3130,NativeTimeframe(总_58_in_130),1) && iClose(总_336_st_3130,NativeTimeframe(总_58_in_130),1)>子_10_do )
       {
         NativeClosePosition(子_9_lo,子_12_do,SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK),0,clrRed); 
         Print("closing candle confirmation"); 
       }
       if ( 总_61_bo_13C && iTime(总_336_st_3130,NativeTimeframe(总_60_in_138),总_51_in_114) <= 子_13_da && iTime(总_336_st_3130,NativeTimeframe(总_60_in_138),0) >  子_13_da && iClose(总_336_st_3130,NativeTimeframe(总_60_in_138),1)>iOpen(总_336_st_3130,NativeTimeframe(总_60_in_138),1) && iClose(总_336_st_3130,NativeTimeframe(总_60_in_138),1)>子_10_do )
       {
         NativeClosePosition(子_9_lo,子_12_do,SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK),0,clrRed); 
         Print("closing candle confirmation"); 
       }
       总_247_do_2500 = 总_129_do_318 ;
       if ( 总_133_in_338 >  0 && TimeCurrent() >  子_13_da + 总_133_in_338 * 60 )
       {
         总_247_do_2500 = 总_134_do_340 ;
       }
       临_in_1 = 总_190_in_518;
       临_lo_2 = 子_9_lo;
       临_do_4 = 0.0;
       for (临_in_3 = 0 ; 临_in_3 < 100 ; 临_in_3=临_in_3 + 1)
       {
         if ( !(总_198_do_1070_si100si2[临_in_3][0]==临_lo_2) )   continue;
         临_do_4 = 总_198_do_1070_si100si2[临_in_3][1];
         break;
         
       }
       子_17_do = NormalizeDouble(临_do_4,临_in_1) ;
       if ( 子_17_do==0.0 )
       {
         临_do_5 = 子_10_do;
         临_lo_6 = 子_9_lo;
         for (临_in_7 = 0 ; 临_in_7 < 100 ; 临_in_7=临_in_7 + 1)
         {
           if ( !(总_198_do_1070_si100si2[临_in_7][0]==0.0) )   continue;
           总_198_do_1070_si100si2[临_in_7][0] = (double)临_lo_6;
           总_198_do_1070_si100si2[临_in_7][1] = 临_do_5;
           break;
           
         }
         子_17_do = 子_10_do ;
       }
       else
       {
         子_17_do = 子_17_do - 总_85_do_1C0 * 总_229_do_1E00 ;
       }
       子_18_do = 子_17_do - 子_10_do ;
       子_19_bo = false ;
       if ( 子_17_do>总_85_do_1C0 * 总_229_do_1E00 && 子_18_do>总_38_do_C0 * 总_229_do_1E00 )
       {
         子_19_bo = true ;
         if ( 总_39_in_C8 == 2 )
         {
           总_247_do_2500 = -1000.0 ;
           Print("Slippage controle active"); 
         }
       }
       if ( 总_43_bo_E8 )
       {
         子_5_do = 子_17_do ;
       }
       else
       {
         子_5_do = 子_10_do ;
       }
       // EX5 behavior: maximum-loss is a virtual close boundary here.
       // Do not rewrite the broker SL on every management pass.
       if ( SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK)>(总_100_do_230 + 总_64_do_148) * 总_229_do_1E00 + 子_10_do + 总_1_do_0 )
       {
         NativeClosePosition(g_trade_view.Ticket(),g_trade_view.Volume(),SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK),(int)总_1_do_0,clrRed); 
         return(true); 
       }
       子_20_bo = false ;
       if ( 总_159_bo_464 )
       {
         临_lo_8 = 子_9_lo;
         临_in_9 = 0;
         for (临_in_10 = NativeTradesTotal() ; 临_in_10 >= 0 ; 临_in_10=临_in_10 - 1)
         {
           if ( g_trade_view.Select(临_in_10,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true || g_trade_view.Magic() != 总_169_in_4AC || g_trade_view.SymbolName() != 总_336_st_3130 )   continue;
           临_st_11 = g_trade_view.Comment();
           if ( 临_st_11 != IntegerToString(临_lo_8,0,32) )   continue;
           临_in_9=临_in_9 + 1;
           
         }
         子_21_do = 临_in_9 ;
         子_22_bo = false ;
         if ( !(总_195_bo_531) )
         {
           总_195_bo_531 = true ;
           总_193_in_52C = 1 ;
         }
         if ( 子_21_do==0.0 )
         {
           总_193_in_52C = 1 ;
         }
         if ( MathFloor(子_21_do / 2.0)==子_21_do / 2.0 )
         {
           总_193_in_52C = 1 ;
         }
         else
         {
           总_193_in_52C = 0 ;
         }
         if ( 总_195_bo_531 )
         {
           if ( 子_21_do>0.0 )
           {
             临_do_12 = AccountInfoDouble(ACCOUNT_EQUITY);
             if ( 临_do_12>AccountInfoDouble(ACCOUNT_BALANCE) + 总_163_do_480 )
             {
               for (临_in_13 = NativeTradesTotal() ; 临_in_13 >= 0 ; 临_in_13=临_in_13 - 1)
               {
                 if ( g_trade_view.Select(临_in_13,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true )   continue;
                 
                 if ( ( g_trade_view.Magic() != 总_93_in_1F0 && g_trade_view.Magic() != 总_169_in_4AC && g_trade_view.Magic() != 总_168_in_4A8 ) )   continue;
                 
                 if ( g_trade_view.OrderType() == ORDER_TYPE_BUY )
                 {
                   NativeClosePosition(g_trade_view.Ticket(),g_trade_view.Volume(),SymbolInfoDouble(总_336_st_3130,SYMBOL_BID),(int)总_38_do_C0,clrRed); 
                 }
                 if ( g_trade_view.OrderType() != ORDER_TYPE_SELL )   continue;
                 NativeClosePosition(g_trade_view.Ticket(),g_trade_view.Volume(),SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK),(int)总_38_do_C0,clrRed); 
                 
               }
             }
           }
           if ( 子_21_do>0.0 )
           {
             临_lo_14 = 子_9_lo;
             临_do_15 = 0.0;
             for (临_in_16 = NativeTradesTotal() ; 临_in_16 >= 0 ; 临_in_16=临_in_16 - 1)
             {
               if ( g_trade_view.Select(临_in_16,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true )   continue;
               临_lo_17 = g_trade_view.Ticket();
               if ( 临_lo_17 != 临_lo_14 )
               {
                 临_st_11 = g_trade_view.Comment();
               if ( 临_st_11 != IntegerToString(临_lo_14,0,32) )   continue;
               }
               临_do_15 = 临_do_15 + g_trade_view.Profit();
               
             }
             if ( 临_do_15>总_163_do_480 )
             {
               临_lo_18 = 子_9_lo;
               for (临_in_19 = NativeTradesTotal() ; 临_in_19 >= 0 ; 临_in_19=临_in_19 - 1)
               {
                 if ( g_trade_view.Select(临_in_19,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true )   continue;
                 
                 if ( g_trade_view.Magic() == 总_93_in_1F0 && g_trade_view.Ticket() == 临_lo_18 )
                 {
                   NativeClosePosition(g_trade_view.Ticket(),g_trade_view.Volume(),SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK),3,clrRed); 
                 }
                 if ( g_trade_view.Magic() != 总_169_in_4AC )   continue;
                 临_st_11 = g_trade_view.Comment();
                 if ( 临_st_11 != IntegerToString(临_lo_18,0,32) )   continue;
                 
                 if ( g_trade_view.OrderType() == ORDER_TYPE_BUY )
                 {
                   NativeClosePosition(g_trade_view.Ticket(),g_trade_view.Volume(),SymbolInfoDouble(总_336_st_3130,SYMBOL_BID),(int)总_38_do_C0,clrRed); 
                 }
                 if ( g_trade_view.OrderType() != ORDER_TYPE_SELL )   continue;
                 NativeClosePosition(g_trade_view.Ticket(),g_trade_view.Volume(),SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK),(int)总_38_do_C0,clrRed); 
                 
               }
               总_195_bo_531 = false ;
               子_20_bo = true ;
             }
           }
           else
           {
             子_23_do = 子_12_do * 总_165_do_490 ;
             if ( 总_164_in_488 == 2 )
             {
               子_23_do = (子_21_do + 1.0) * 子_12_do + 子_12_do ;
             }
             if ( 总_164_in_488 == 3 )
             {
               子_23_do = 子_12_do * (MathPow(总_165_do_490,子_21_do + 1.0)) ;
             }
             if ( 总_193_in_52C == 0 )
             {
               子_24_do = 子_17_do ;
               if ( SymbolInfoDouble(总_336_st_3130,SYMBOL_BID)<子_17_do )
               {
                 if ( 子_21_do>=总_166_in_498 )
                 {
                   for (临_in_20 = NativeTradesTotal() ; 临_in_20 >= 0 ; 临_in_20=临_in_20 - 1)
                   {
                     if ( g_trade_view.Select(临_in_20,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true )   continue;
                     
                     if ( g_trade_view.Magic() == 总_93_in_1F0 && g_trade_view.Ticket() == 子_9_lo )
                     {
                       NativeClosePosition(g_trade_view.Ticket(),g_trade_view.Volume(),SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK),3,clrRed); 
                     }
                     if ( g_trade_view.Magic() != 总_169_in_4AC )   continue;
                     临_st_11 = g_trade_view.Comment();
                     if ( 临_st_11 != IntegerToString(子_9_lo,0,32) )   continue;
                     
                     if ( g_trade_view.OrderType() == ORDER_TYPE_BUY )
                     {
                       NativeClosePosition(g_trade_view.Ticket(),g_trade_view.Volume(),SymbolInfoDouble(总_336_st_3130,SYMBOL_BID),(int)总_38_do_C0,clrRed); 
                     }
                     if ( g_trade_view.OrderType() != ORDER_TYPE_SELL )   continue;
                     NativeClosePosition(g_trade_view.Ticket(),g_trade_view.Volume(),SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK),(int)总_38_do_C0,clrRed); 
                     
                   }
                 }
                 else
                 {
                   NativeSendOrder(总_336_st_3130,ORDER_TYPE_SELL,子_23_do,SymbolInfoDouble(总_336_st_3130,SYMBOL_BID),(int)总_38_do_C0,0.0,0.0,IntegerToString(子_9_lo,0,32),总_169_in_4AC,0,clrGreen); 
                   总_193_in_52C = 1 ;
                   子_22_bo = true ;
                 }
               }
             }
             else
             {
               子_25_do = 总_160_do_468 * 总_229_do_1E00 + 子_17_do - 子_21_do * 总_161_do_470 * 总_229_do_1E00 ;
               if ( 子_25_do<总_162_do_478 * 总_229_do_1E00 + 子_17_do )
               {
                 子_25_do = 总_162_do_478 * 总_229_do_1E00 + 子_17_do ;
               }
               if ( SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK)>子_25_do )
               {
                 if ( 子_21_do>=总_166_in_498 )
                 {
                   for (临_in_21 = NativeTradesTotal() ; 临_in_21 >= 0 ; 临_in_21=临_in_21 - 1)
                   {
                     if ( g_trade_view.Select(临_in_21,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true )   continue;
                     
                     if ( g_trade_view.Magic() == 总_93_in_1F0 && g_trade_view.Ticket() == 子_9_lo )
                     {
                       NativeClosePosition(g_trade_view.Ticket(),g_trade_view.Volume(),SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK),3,clrRed); 
                     }
                     if ( g_trade_view.Magic() != 总_169_in_4AC )   continue;
                     临_st_22 = g_trade_view.Comment();
                     if ( 临_st_22 != IntegerToString(子_9_lo,0,32) )   continue;
                     
                     if ( g_trade_view.OrderType() == ORDER_TYPE_BUY )
                     {
                       NativeClosePosition(g_trade_view.Ticket(),g_trade_view.Volume(),SymbolInfoDouble(总_336_st_3130,SYMBOL_BID),(int)总_38_do_C0,clrRed); 
                     }
                     if ( g_trade_view.OrderType() != ORDER_TYPE_SELL )   continue;
                     NativeClosePosition(g_trade_view.Ticket(),g_trade_view.Volume(),SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK),(int)总_38_do_C0,clrRed); 
                     
                   }
                 }
                 else
                 {
                   NativeSendOrder(总_336_st_3130,ORDER_TYPE_BUY,子_23_do,SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK),(int)总_38_do_C0,0.0,0.0,IntegerToString(子_9_lo,0,32),总_169_in_4AC,0,clrGreen); 
                   总_193_in_52C = 0 ;
                   子_22_bo = true ;
                 }
               }
             }
           }
         }
         if ( ( 子_21_do>0.0 || 子_22_bo ) )
         {
           子_20_bo = true ;
         }
       }
       if ( !(子_20_bo) )
       {
         if ( ( 总_63_in_140 == 1 || (总_63_in_140 != 2 && 总_63_in_140 != 3) ) )
         {
           临_lo_23 = 子_9_lo;
           临_do_24 = 总_100_do_230;
           临_do_25 = 子_10_do;
           临_in_26 = 2;
           临_do_27 = 0.0;
           临_bo_28 = false;
           for (临_in_29 = 0 ; 临_in_29 < 总_199_in_16B0 ; 临_in_29=临_in_29 + 1)
           {
             if ( 总_196_do_568_si20si2[临_in_29][0]==临_lo_23 )
             {
               临_do_27 = 总_196_do_568_si20si2[临_in_29][1];
               临_bo_28 = true;
               break;
             }
           }
           if ( !(临_bo_28) )
           {
             if ( 临_in_26 == 1 )
             {
               临_do_27 = NormalizeDouble(临_do_25 - 临_do_24 * 总_229_do_1E00,总_190_in_518);
             }
             if ( 临_in_26 == 2 )
             {
               临_do_27 = NormalizeDouble(临_do_24 * 总_229_do_1E00 + 临_do_25,总_190_in_518);
             }
             for (临_in_30 = 0 ; 临_in_30 < 总_199_in_16B0 ; 临_in_30=临_in_30 + 1)
             {
               if ( 总_196_do_568_si20si2[临_in_30][0]==0.0 )
               {
                 总_196_do_568_si20si2[临_in_30][0] = (double)临_lo_23;
                 总_196_do_568_si20si2[临_in_30][1] = 临_do_27;
                 break;
               }
             }
           }
           总_191_do_520 = 临_do_27 ;
           子_4_do = 总_191_do_520 ;
           if ( SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK)>子_4_do )
           {
             Print("Closing with virtual SL"); 
             NativeClosePosition(子_9_lo,子_12_do,SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK),(int)总_1_do_0,0xFFFFFFFF); 
             return(true); 
           }
           if ( 总_125_do_2F8>0.0 && TimeCurrent() >= 子_13_da + 总_304_in_287C && SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK)<子_7_do - 总_337_do_3140 - 总_126_do_300 * 总_229_do_1E00 && SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK)>子_8_do + 总_309_do_2898 && NormalizeDouble(SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK) + 总_126_do_300 * 总_229_do_1E00,总_190_in_518)<子_7_do )
           {
             子_7_do = NormalizeDouble(SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK) + 总_126_do_300 * 总_229_do_1E00,总_190_in_518) ;
             if ( 子_7_do>SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK) + 总_221_do_1A80 )
             {
               总_230_in_1E08 = NativeModifyTrade(子_9_lo,子_10_do,子_7_do,子_8_do,0,0xFFFFFFFF) ;
               if ( 总_230_in_1E08 <= 0 )
               {
                 Print("TrailStop error: \'" + NativeTradeRetcodeText(NativeTradeRetcode()) + "\' when setting trailing Exit_TrailSL_after_X_Minutes_size_ loss.  Trying again!"); 
               }
               子_2_bo = true ;
             }
           }
           if ( 总_103_do_250>0.0 && SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK)<子_7_do - 总_337_do_3140 - (总_103_do_250 + 总_106_do_268) * 总_229_do_1E00 && SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK)<子_10_do - 总_104_do_258 * 总_229_do_1E00 && SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK)>子_8_do + 总_309_do_2898 && 子_7_do>子_10_do - 总_105_do_260 * 总_229_do_1E00 && NormalizeDouble(总_103_do_250 * 总_229_do_1E00 + SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK),总_190_in_518)<子_7_do )
           {
             子_7_do = NormalizeDouble(SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK) + 总_103_do_250 * 总_229_do_1E00,总_190_in_518) ;
             if ( 子_7_do>SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK) + 总_221_do_1A80 )
             {
               总_230_in_1E08 = NativeModifyTrade(子_9_lo,子_10_do,子_7_do,子_8_do,0,0xFFFFFFFF) ;
               if ( 总_230_in_1E08 <= 0 )
               {
                 Print("TrailStop error: \'" + NativeTradeRetcodeText(NativeTradeRetcode()) + "\' when setting trailing Exit_stop_ loss.  Trying again!"); 
               }
               else
               {
                 子_26_do = NormalizeDouble(总_107_do_270 / 100.0 * 总_223_do_1AC4_si99[总_328_in_3100],2) ;
                 if ( 子_26_do<子_12_do && 子_26_do>=SymbolInfoDouble(总_336_st_3130,SYMBOL_VOLUME_STEP) )
                 {
                   NativeClosePosition(子_9_lo,子_26_do,SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK),(int)总_38_do_C0,clrRed); 
                   return(true); 
                 }
               }
               子_2_bo = true ;
             }
           }
           if ( 总_110_do_288>0.0 && SymbolInfoDouble(总_336_st_3130,SYMBOL_BID)>NormalizeDouble(总_110_do_288 * 总_229_do_1E00 + (子_8_do + 总_337_do_3140),总_190_in_518) && SymbolInfoDouble(总_336_st_3130,SYMBOL_BID)>NormalizeDouble(总_111_do_290 * 总_229_do_1E00 + 子_5_do,总_190_in_518) && SymbolInfoDouble(总_336_st_3130,SYMBOL_BID)>子_8_do + 总_309_do_2898 )
           {
             子_8_do = NormalizeDouble(SymbolInfoDouble(总_336_st_3130,SYMBOL_BID) - 总_110_do_288 * 总_229_do_1E00,总_190_in_518) ;
             if ( 子_8_do<SymbolInfoDouble(总_336_st_3130,SYMBOL_BID) - 总_221_do_1A80 )
             {
               总_230_in_1E08 = NativeModifyTrade(子_9_lo,子_10_do,子_7_do,子_8_do,0,0xFFFFFFFF) ;
               if ( 总_230_in_1E08 <= 0 )
               {
                 Print("TrailStop error: \'" + NativeTradeRetcodeText(NativeTradeRetcode()) + "\' when setting trailing Exit_TP.  Trying again!"); 
               }
               else
               {
                 子_27_do = NormalizeDouble(总_107_do_270 / 100.0 * 总_223_do_1AC4_si99[总_328_in_3100],2) ;
                 if ( 子_27_do<子_12_do && 子_27_do>=SymbolInfoDouble(总_336_st_3130,SYMBOL_VOLUME_MIN) )
                 {
                   NativeClosePosition(子_9_lo,子_27_do,SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK),(int)总_38_do_C0,clrRed); 
                   return(true); 
                 }
               }
               子_2_bo = true ;
             }
           }
           if ( 子_19_bo && 总_39_in_C8 == 1 && 总_41_do_D8>0.0 && SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK)<子_7_do - 总_337_do_3140 - 总_41_do_D8 * 总_229_do_1E00 && SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK)<子_17_do - 总_40_do_D0 * 总_229_do_1E00 && SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK)>子_8_do + 总_309_do_2898 && 子_7_do>子_10_do - 总_42_do_E0 * 总_229_do_1E00 && NormalizeDouble(SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK) + 总_41_do_D8 * 总_229_do_1E00,总_190_in_518)<子_7_do )
           {
             子_7_do = NormalizeDouble(SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK) + 总_41_do_D8 * 总_229_do_1E00,总_190_in_518) ;
             if ( 子_7_do>SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK) + 总_221_do_1A80 )
             {
               总_230_in_1E08 = NativeModifyTrade(子_9_lo,子_10_do,子_7_do,子_8_do,0,0xFFFFFFFF) ;
               if ( 总_230_in_1E08 <= 0 )
               {
                 Print("TrailStop error: \'" + NativeTradeRetcodeText(NativeTradeRetcode()) + "\' when setting Slip TL.  Trying again!"); 
               }
               else
               {
                 Print("Slippage controle active"); 
               }
               子_2_bo = true ;
             }
           }
           if ( 总_119_in_2D0 >  0 && 总_120_in_2D4 >= 0 && UseHL_TrailingSL && 总_241_do_1E78_si99[总_328_in_3100]<子_7_do - 总_221_do_1A80 - 总_337_do_3140 && 总_241_do_1E78_si99[总_328_in_3100]>总_121_in_2D8 * 总_229_do_1E00 + SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK) && ( 总_241_do_1E78_si99[总_328_in_3100]>子_10_do || !(总_116_bo_2C4) ) && 总_241_do_1E78_si99[总_328_in_3100]>总_122_in_2DC * 总_229_do_1E00 + SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK) + 总_221_do_1A80 + 总_337_do_3140 && SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK)>子_8_do + 总_309_do_2898 && NormalizeDouble(总_241_do_1E78_si99[总_328_in_3100],总_190_in_518)<子_7_do )
           {
             子_7_do = NormalizeDouble(总_241_do_1E78_si99[总_328_in_3100],总_190_in_518) ;
             if ( 子_7_do>SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK) + 总_221_do_1A80 )
             {
               总_230_in_1E08 = NativeModifyTrade(子_9_lo,子_10_do,子_7_do,子_8_do,0,0xFFFFFFFF) ;
               if ( 总_230_in_1E08 <= 0 )
               {
                 Print("error: \'" + NativeTradeRetcodeText(NativeTradeRetcode()) + "\' when modifying stoploss"); 
               }
               子_2_bo = true ;
             }
           }
           if ( 总_113_do_2A8>0.0 && SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK)<子_10_do - 总_113_do_2A8 * 总_229_do_1E00 && 子_10_do - 总_114_do_2B0 * 总_229_do_1E00<子_7_do - 总_337_do_3140 && SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK)<子_10_do - 总_114_do_2B0 * 总_229_do_1E00 - 总_221_do_1A80 && SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK)>子_8_do + 总_309_do_2898 && NormalizeDouble(子_10_do - 总_114_do_2B0 * 总_229_do_1E00,总_190_in_518)<子_7_do )
           {
             子_7_do = NormalizeDouble(子_10_do - 总_114_do_2B0 * 总_229_do_1E00,总_190_in_518) ;
             if ( 子_7_do>SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK) + 总_221_do_1A80 )
             {
               总_230_in_1E08 = NativeModifyTrade(子_9_lo,子_10_do,子_7_do,子_8_do,0,0xFFFFFFFF) ;
               if ( 总_230_in_1E08 <= 0 )
               {
                 Print("error when setting breakeven: \'" + NativeTradeRetcodeText(NativeTradeRetcode()) + "\' ..\'Exit_BE_start_\' to close to \'Exit_BE_extra_pips_\' ..trying again!"); 
               }
               子_2_bo = true ;
             }
           }
           if ( !(子_2_bo) && ( 总_128_in_314 == 1 || (总_128_in_314 == 2 && 子_7_do - 总_131_do_328 * 总_229_do_1E00>=子_5_do - 总_1_do_0 - 总_132_do_330 * 总_229_do_1E00) ) )
           {
             总_250_in_2518 ++;
             if ( SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK)<子_7_do - 总_131_do_328 * 总_229_do_1E00 - 总_221_do_1A80 && SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK)>子_8_do + 总_309_do_2898 && ( 总_129_do_318==0.0 || SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK)<子_5_do - 总_247_do_2500 * 总_229_do_1E00 ) && 总_250_in_2518 >= 总_130_in_320 && NormalizeDouble(子_7_do - 总_131_do_328 * 总_229_do_1E00,总_190_in_518)<子_7_do )
             {
               总_250_in_2518 = 0 ;
               子_7_do = NormalizeDouble(子_7_do - 总_131_do_328 * 总_229_do_1E00,总_190_in_518) ;
               NativeModifyTrade(子_9_lo,子_10_do,子_7_do,子_8_do,0,0xFFFFFFFF); 
               子_2_bo = true ;
             }
           }
           总_191_do_520 = 子_7_do ;
           if ( SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK)>子_7_do )
           {
             Print("Closing with virtual SL"); 
             NativeClosePosition(子_9_lo,子_12_do,SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK),(int)总_1_do_0,0xFFFFFFFF); 
             return(true); 
           }
           if ( NormalizeDouble(子_4_do,总_190_in_518)!=NormalizeDouble(总_191_do_520,总_190_in_518) )
           {
             临_do_31 = NormalizeDouble(总_191_do_520,总_190_in_518);
             临_lo_32 = 子_9_lo;
             for (临_in_33 = 0 ; 临_in_33 < 总_199_in_16B0 ; 临_in_33=临_in_33 + 1)
             {
               if ( 总_196_do_568_si20si2[临_in_33][0]==临_lo_32 )
               {
                 总_196_do_568_si20si2[临_in_33][1] = 临_do_31;
                 break;
               }
             }
           }
           if ( 子_2_bo && 总_135_bo_348 )
           {
             return(true); 
           }
         }
         if ( ( 总_63_in_140 == 2 || 总_63_in_140 == 3 ) )
         {
           临_lo_34 = 子_9_lo;
           临_do_35 = 总_100_do_230;
           临_do_36 = 子_10_do;
           临_in_37 = 2;
           临_do_38 = 0.0;
           临_bo_39 = false;
           for (临_in_40 = 0 ; 临_in_40 < 总_199_in_16B0 ; 临_in_40=临_in_40 + 1)
           {
             if ( 总_196_do_568_si20si2[临_in_40][0]==临_lo_34 )
             {
               临_do_38 = 总_196_do_568_si20si2[临_in_40][1];
               临_bo_39 = true;
               break;
             }
           }
           if ( !(临_bo_39) )
           {
             if ( 临_in_37 == 1 )
             {
               临_do_38 = NormalizeDouble(临_do_36 - 临_do_35 * 总_229_do_1E00,总_190_in_518);
             }
             if ( 临_in_37 == 2 )
             {
               临_do_38 = NormalizeDouble(临_do_35 * 总_229_do_1E00 + 临_do_36,总_190_in_518);
             }
             for (临_in_41 = 0 ; 临_in_41 < 总_199_in_16B0 ; 临_in_41=临_in_41 + 1)
             {
               if ( 总_196_do_568_si20si2[临_in_41][0]==0.0 )
               {
                 总_196_do_568_si20si2[临_in_41][0] = (double)临_lo_34;
                 总_196_do_568_si20si2[临_in_41][1] = 临_do_38;
                 break;
               }
             }
           }
           总_191_do_520 = 临_do_38 ;
           子_4_do = 总_191_do_520 ;
           if ( SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK)>=子_4_do )
           {
             NativeClosePosition(子_9_lo,子_12_do,SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK),(int)总_1_do_0,0xFFFFFFFF); 
             return(true); 
           }
           子_28_in = (int)(TimeCurrent() - 总_319_da_28E0) ;
           if ( 子_28_in >= 总_65_in_150 )
           {
             if ( NormalizeDouble(总_191_do_520,总_190_in_518)<子_7_do - 总_337_do_3140 )
             {
               NativeModifyTrade(子_9_lo,子_10_do,NormalizeDouble(总_191_do_520,总_190_in_518),子_8_do,0,0xFFFFFFFF); 
             }
             总_319_da_28E0 = TimeCurrent() ;
           }
           if ( 总_125_do_2F8>0.0 && TimeCurrent() >= 子_13_da + 总_304_in_287C && SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK)<总_191_do_520 - 总_337_do_3140 - 总_126_do_300 * 总_229_do_1E00 && SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK)>子_8_do + 总_309_do_2898 )
           {
             总_191_do_520 = SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK) + 总_126_do_300 * 总_229_do_1E00 ;
             子_2_bo = true ;
           }
           if ( 总_103_do_250>0.0 && SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK)<总_191_do_520 - 总_337_do_3140 - (总_103_do_250 + 总_106_do_268) * 总_229_do_1E00 && SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK)<子_5_do - 总_104_do_258 * 总_229_do_1E00 && 总_191_do_520>子_10_do - 总_105_do_260 * 总_229_do_1E00 )
           {
             总_191_do_520 = 总_103_do_250 * 总_229_do_1E00 + SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK) ;
             子_29_do = NormalizeDouble(总_107_do_270 / 100.0 * 总_223_do_1AC4_si99[总_328_in_3100],2) ;
             if ( 子_29_do<子_12_do && 子_29_do>=SymbolInfoDouble(总_336_st_3130,SYMBOL_VOLUME_STEP) )
             {
               NativeClosePosition(子_9_lo,子_29_do,SymbolInfoDouble(总_336_st_3130,SYMBOL_BID),(int)总_38_do_C0,clrRed); 
               return(true); 
             }
             子_2_bo = true ;
           }
           if ( 子_19_bo && 总_39_in_C8 == 1 && 总_41_do_D8>0.0 && SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK)<总_191_do_520 - 总_337_do_3140 - 总_41_do_D8 * 总_229_do_1E00 && SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK)<子_17_do - 总_40_do_D0 * 总_229_do_1E00 && SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK)>子_8_do + 总_309_do_2898 && 总_191_do_520>子_10_do - 总_42_do_E0 * 总_229_do_1E00 )
           {
             Print("Slippage controle active"); 
             子_2_bo = true ;
             总_191_do_520 = SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK) + 总_41_do_D8 * 总_229_do_1E00 ;
           }
           if ( 总_119_in_2D0 >  0 && 总_120_in_2D4 >= 0 && 总_241_do_1E78_si99[总_328_in_3100]<总_191_do_520 - 总_221_do_1A80 - 总_337_do_3140 && ( 总_241_do_1E78_si99[总_328_in_3100]>子_10_do || !(总_116_bo_2C4) ) && 总_241_do_1E78_si99[总_328_in_3100]>总_122_in_2DC * 总_229_do_1E00 + SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK) + 总_221_do_1A80 + 总_337_do_3140 && SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK)>子_8_do + 总_309_do_2898 )
           {
             总_191_do_520 = 总_241_do_1E78_si99[总_328_in_3100] ;
             子_2_bo = true ;
           }
           if ( 总_113_do_2A8>0.0 && 总_63_in_140 == 3 && SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK)<子_10_do - 总_113_do_2A8 * 总_229_do_1E00 && 子_10_do - 总_114_do_2B0 * 总_229_do_1E00<子_7_do - 总_337_do_3140 && SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK)<子_10_do - 总_114_do_2B0 * 总_229_do_1E00 - 总_221_do_1A80 && SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK)>子_8_do + 总_309_do_2898 && NormalizeDouble(子_10_do - 总_114_do_2B0 * 总_229_do_1E00,总_190_in_518)<总_191_do_520 )
           {
             总_191_do_520 = NormalizeDouble(子_10_do - 总_114_do_2B0 * 总_229_do_1E00,总_190_in_518) ;
             总_230_in_1E08 = NativeModifyTrade(子_9_lo,子_10_do,总_191_do_520,子_8_do,0,0xFFFFFFFF) ;
             if ( 总_230_in_1E08 <= 0 )
             {
               Print("error when setting breakeven: \'" + NativeTradeRetcodeText(NativeTradeRetcode()) + "\' ..\'Exit_BE_start_\' to close to \'Exit_BE_extra_pips_\' ..trying again!"); 
             }
             子_2_bo = true ;
           }
           if ( 总_113_do_2A8>0.0 && 总_63_in_140 == 2 && SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK)<子_10_do - 总_113_do_2A8 * 总_229_do_1E00 && 子_10_do - 总_114_do_2B0 * 总_229_do_1E00<总_191_do_520 - 总_337_do_3140 && SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK)<子_10_do - 总_114_do_2B0 * 总_229_do_1E00 - 总_221_do_1A80 && SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK)>子_8_do + 总_309_do_2898 )
           {
             总_191_do_520 = 子_10_do - 总_114_do_2B0 * 总_229_do_1E00 ;
             子_2_bo = true ;
           }
           if ( !(子_2_bo) && ( 总_128_in_314 == 1 || (总_128_in_314 == 2 && 总_191_do_520 - 总_131_do_328 * 总_229_do_1E00>=子_5_do - 总_1_do_0 - 总_132_do_330 * 总_229_do_1E00) ) )
           {
             总_250_in_2518 ++;
             if ( SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK)<总_191_do_520 - 总_131_do_328 * 总_229_do_1E00 - 总_221_do_1A80 && SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK)>子_8_do + 总_309_do_2898 && ( 总_129_do_318==0.0 || SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK)<子_5_do - 总_247_do_2500 * 总_229_do_1E00 ) && 总_250_in_2518 >= 总_130_in_320 )
             {
               总_250_in_2518 = 0 ;
               总_191_do_520 = 总_191_do_520 - 总_131_do_328 * 总_229_do_1E00 ;
               子_2_bo = true ;
             }
           }
           if ( SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK)>=总_191_do_520 )
           {
             NativeClosePosition(子_9_lo,子_12_do,SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK),(int)总_1_do_0,0xFFFFFFFF); 
             return(true); 
           }
           if ( NormalizeDouble(子_4_do,总_190_in_518)!=NormalizeDouble(总_191_do_520,总_190_in_518) )
           {
             临_do_42 = NormalizeDouble(总_191_do_520,总_190_in_518);
             临_lo_43 = 子_9_lo;
             for (临_in_44 = 0 ; 临_in_44 < 总_199_in_16B0 ; 临_in_44=临_in_44 + 1)
             {
               if ( 总_196_do_568_si20si2[临_in_44][0]==临_lo_43 )
               {
                 总_196_do_568_si20si2[临_in_44][1] = 临_do_42;
                 break;
               }
             }
           }
         }
       }
     }
     if ( 子_2_bo )
     {
       子_3_bo = true ;
     }
   }
   if ( 子_2_bo )
   {
     子_3_bo = true ;
   }
 }
 return(子_3_bo); 
 }
//lizong_19 <<==--------   --------
 bool lizong_20()
 {
  bool      子_2_bo;
  datetime  子_3_da;
  int       子_4_in;
//----- -----
 bool       临_bo_1;
 bool       临_bo_2;
 bool       临_bo_3;
 bool       临_bo_4;
 bool       临_bo_5;
 bool       临_bo_6;

 if ( !(总_171_bo_4BC) )
 {
   return(true); 
 }
 子_2_bo = false ;
 子_3_da = 0 ;
 if ( 总_172_in_4C0 == 2 )
 {
   子_3_da = TimeCurrent() ;
 }
 if ( 总_172_in_4C0 == 0 )
 {
   TimeGMT(); 
 }
 if ( 总_172_in_4C0 == 1 )
 {
   TimeLocal(); 
 }
 子_4_in = DateHour(子_3_da) ;
 if ( DateDayOfWeek(子_3_da) == 0 )
 {
   if ( 总_174_in_4C8 <  总_175_in_4CC && ( 子_4_in < 总_174_in_4C8 || 子_4_in >= 总_175_in_4CC ) )
   {
     临_bo_1 = false;
   }
   else
   {
     if ( 总_174_in_4C8 >  总_175_in_4CC && 子_4_in <  总_174_in_4C8 && 子_4_in >= 总_175_in_4CC )
     {
       临_bo_1 = false;
     }
     else
     {
       if ( 总_174_in_4C8 == 总_175_in_4CC )
       {
         临_bo_1 = false;
       }
       else
       {
         临_bo_1 = true;
       }
     }
   }
   if ( 临_bo_1 )
   {
     子_2_bo = true ;
   }
 }
 if ( DateDayOfWeek(子_3_da) == 1 )
 {
   if ( 总_176_in_4D0 <  总_177_in_4D4 && ( 子_4_in < 总_176_in_4D0 || 子_4_in >= 总_177_in_4D4 ) )
   {
     临_bo_2 = false;
   }
   else
   {
     if ( 总_176_in_4D0 >  总_177_in_4D4 && 子_4_in <  总_176_in_4D0 && 子_4_in >= 总_177_in_4D4 )
     {
       临_bo_2 = false;
     }
     else
     {
       if ( 总_176_in_4D0 == 总_177_in_4D4 )
       {
         临_bo_2 = false;
       }
       else
       {
         临_bo_2 = true;
       }
     }
   }
   if ( 临_bo_2 )
   {
     子_2_bo = true ;
   }
 }
 if ( DateDayOfWeek(子_3_da) == 2 )
 {
   if ( 总_178_in_4D8 <  总_179_in_4DC && ( 子_4_in < 总_178_in_4D8 || 子_4_in >= 总_179_in_4DC ) )
   {
     临_bo_3 = false;
   }
   else
   {
     if ( 总_178_in_4D8 >  总_179_in_4DC && 子_4_in <  总_178_in_4D8 && 子_4_in >= 总_179_in_4DC )
     {
       临_bo_3 = false;
     }
     else
     {
       if ( 总_178_in_4D8 == 总_179_in_4DC )
       {
         临_bo_3 = false;
       }
       else
       {
         临_bo_3 = true;
       }
     }
   }
   if ( 临_bo_3 )
   {
     子_2_bo = true ;
   }
 }
 if ( DateDayOfWeek(子_3_da) == 3 )
 {
   if ( 总_180_in_4E0 <  总_181_in_4E4 && ( 子_4_in < 总_180_in_4E0 || 子_4_in >= 总_181_in_4E4 ) )
   {
     临_bo_4 = false;
   }
   else
   {
     if ( 总_180_in_4E0 >  总_181_in_4E4 && 子_4_in <  总_180_in_4E0 && 子_4_in >= 总_181_in_4E4 )
     {
       临_bo_4 = false;
     }
     else
     {
       if ( 总_180_in_4E0 == 总_181_in_4E4 )
       {
         临_bo_4 = false;
       }
       else
       {
         临_bo_4 = true;
       }
     }
   }
   if ( 临_bo_4 )
   {
     子_2_bo = true ;
   }
 }
 if ( DateDayOfWeek(子_3_da) == 4 )
 {
   if ( 总_182_in_4E8 <  总_183_in_4EC && ( 子_4_in < 总_182_in_4E8 || 子_4_in >= 总_183_in_4EC ) )
   {
     临_bo_5 = false;
   }
   else
   {
     if ( 总_182_in_4E8 >  总_183_in_4EC && 子_4_in <  总_182_in_4E8 && 子_4_in >= 总_183_in_4EC )
     {
       临_bo_5 = false;
     }
     else
     {
       if ( 总_182_in_4E8 == 总_183_in_4EC )
       {
         临_bo_5 = false;
       }
       else
       {
         临_bo_5 = true;
       }
     }
   }
   if ( 临_bo_5 )
   {
     子_2_bo = true ;
   }
 }
 if ( DateDayOfWeek(子_3_da) == 5 )
 {
   if ( 总_184_in_4F0 <  总_185_in_4F4 && ( 子_4_in < 总_184_in_4F0 || 子_4_in >= 总_185_in_4F4 ) )
   {
     临_bo_6 = false;
   }
   else
   {
     if ( 总_184_in_4F0 >  总_185_in_4F4 && 子_4_in <  总_184_in_4F0 && 子_4_in >= 总_185_in_4F4 )
     {
       临_bo_6 = false;
     }
     else
     {
       if ( 总_184_in_4F0 == 总_185_in_4F4 )
       {
         临_bo_6 = false;
       }
       else
       {
         临_bo_6 = true;
       }
     }
   }
   if ( 临_bo_6 )
   {
     子_2_bo = true ;
   }
 }
 return(子_2_bo); 
 }
//lizong_20 <<==--------   --------
 string NativeTradeRetcodeText(const uint retcode)
 {
  总_274_in_25D8 ++;
  switch(retcode)
  {
   case TRADE_RETCODE_REQUOTE:        return("requote");
   case TRADE_RETCODE_REJECT:         return("request rejected");
   case TRADE_RETCODE_CONNECTION:     return("no connection");
   case TRADE_RETCODE_MARKET_CLOSED:  return("market is closed");
   case TRADE_RETCODE_TRADE_DISABLED: return("trade is disabled");
   case TRADE_RETCODE_NO_MONEY:       return("not enough money");
   case TRADE_RETCODE_PRICE_CHANGED:  return("price changed");
   case TRADE_RETCODE_PRICE_OFF:      return("no quotes");
   case TRADE_RETCODE_INVALID_STOPS:  return("invalid stops");
   case TRADE_RETCODE_INVALID_PRICE:  return("invalid price");
   case TRADE_RETCODE_TIMEOUT:        return("request timeout");
   case TRADE_RETCODE_INVALID_VOLUME: return("invalid volume");
   case TRADE_RETCODE_INVALID_ORDER:  return("invalid order or position");
   case TRADE_RETCODE_INVALID:        return("invalid request");
   case TRADE_RETCODE_DONE:           return("request completed");
   case TRADE_RETCODE_DONE_PARTIAL:   return("request partially completed");
   case TRADE_RETCODE_PLACED:         return("order placed");
  }
  return("MT5 retcode " + IntegerToString((int)retcode));
 }
//NativeTradeRetcodeText <<==--------   --------
 void lizong_22( bool 木_0_bo)
 {
  double    子_1_do;
  int       子_2_in;
  int       子_3_in;
  double    子_4_do;
  long      子_5_lo;
  double    子_6_do;
  double    子_7_do;
  datetime  子_8_da;
  string    子_9_st;
  long      子_10_in; // ticket 64-bit
  double    子_11_do;
  long      子_12_lo;
  double    子_13_do;
  double    子_14_do;
  datetime  子_15_da;
  string    子_16_st;
  long      子_17_in; // ticket 64-bit
//----- -----
 long       临_lo_1;
 long       临_lo_2;
 int        临_in_3;
 long       临_lo_4;
 long       临_lo_5;
 int        临_in_6;

 子_1_do = 总_140_do_3F0 / 100.0 + 1.0 ;
 // JIT compare fix: threshold uses the lot-sizing balance basis
 // (OnlyUp / ManualBalance aware), while OnTick keeps LastLotResizeBalance
 // as the raw account-balance snapshot.
 if ( ( !(总_401_do_6AD0!=总_318_do_28D8) && !(木_0_bo) ) )
 {
   return;
 }
 
 if ( ( !(总_401_do_6AD0>总_318_do_28D8 * 子_1_do) && !(总_401_do_6AD0<总_318_do_28D8 / 子_1_do) && !(木_0_bo) ) )
 {
   return;
 }

 lizong_10(总_100_do_230,总_92_in_1EC); 

 // Preserve the lot-size refresh above while the market is closed.  Moving
 // the entire market gate before lizong_22() skipped this refresh and changed
 // several first orders from 0.01 to 0.02.  Only pending delete/recreate is
 // deferred until the native symbol/session gate becomes true.
 if ( (NativeSessionMarket(总_336_st_3130)?1.0:0.0)==0.0 )
 {
   return;
 }
 子_2_in = NativeTradesTotal() ;
 for (子_3_in = 子_2_in ; 子_3_in >= 0 ; 子_3_in --)
 {
   if ( g_trade_view.Select(子_3_in,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true || g_trade_view.Magic() != 总_93_in_1F0 || g_trade_view.SymbolName() != 总_336_st_3130 )   continue;
   
   if ( g_trade_view.OrderType() == ORDER_TYPE_BUY_STOP && g_trade_view.Volume()!=总_223_do_1AC4_si99[总_328_in_3100] )
   {
     子_4_do = g_trade_view.StopLoss() ;
     子_5_lo = g_trade_view.Ticket() ;
     子_6_do = g_trade_view.TakeProfit() ;
     子_7_do = g_trade_view.PriceOpen() ;
     子_8_da = g_trade_view.Expiration() ;
     子_9_st = g_trade_view.Comment() ;
     NativeDeletePending(子_5_lo,clrRed); 
     子_10_in = NativeSendOrder(总_336_st_3130,ORDER_TYPE_BUY_STOP,总_223_do_1AC4_si99[总_328_in_3100],子_7_do,(int)总_38_do_C0,子_4_do,子_6_do,子_9_st,总_93_in_1F0,子_8_da,clrGreen) ;
     临_lo_1 = 子_10_in;
     临_lo_2 = 子_5_lo;
     for (临_in_3 = 0 ; 临_in_3 < 100 ; 临_in_3=临_in_3 + 1)
     {
       if ( !(总_198_do_1070_si100si2[临_in_3][0]==临_lo_2) )   continue;
       总_198_do_1070_si100si2[临_in_3][0] = (double)临_lo_1;
       break;
       
     }
     Print("Lotsize changed more than " + string(总_140_do_3F0) + "%... adjusting lotsize of pending orders"); 
     Sleep(1000); 
   }
   if ( g_trade_view.OrderType() != ORDER_TYPE_SELL_STOP || !(g_trade_view.Volume()!=总_223_do_1AC4_si99[总_328_in_3100]) )   continue;
   子_11_do = g_trade_view.StopLoss() ;
   子_12_lo = g_trade_view.Ticket() ;
   子_13_do = g_trade_view.TakeProfit() ;
   子_14_do = g_trade_view.PriceOpen() ;
   子_15_da = g_trade_view.Expiration() ;
   子_16_st = g_trade_view.Comment() ;
   NativeDeletePending(子_12_lo,clrRed); 
   子_17_in = NativeSendOrder(总_336_st_3130,ORDER_TYPE_SELL_STOP,总_223_do_1AC4_si99[总_328_in_3100],子_14_do,(int)总_38_do_C0,子_11_do,子_13_do,子_16_st,总_93_in_1F0,子_15_da,clrGreen) ;
   临_lo_4 = 子_17_in;
   临_lo_5 = 子_12_lo;
   for (临_in_6 = 0 ; 临_in_6 < 100 ; 临_in_6=临_in_6 + 1)
   {
     if ( !(总_198_do_1070_si100si2[临_in_6][0]==临_lo_5) )   continue;
     总_198_do_1070_si100si2[临_in_6][0] = (double)临_lo_4;
     break;
     
   }
   Print("Lotsize changed more than " + string(总_140_do_3F0) + "%... adjusting lotsize of pending orders"); 
   Sleep(1000); 
   
 }
 }

 void lizong_24()
 {
  int       子_1_in = 0;
  int       子_2_in = 0;
  int       子_3_in;
  int       子_4_in;
  int       子_5_in;
  double    子_6_do;
  int       子_7_in;
  int       子_8_in;
  int       子_9_in;
  int       子_10_in;
  int       子_11_in;
  int       子_12_in;
  int       子_13_in;
  uint      子_14_ui;
  bool      子_15_bo;
  int       子_16_in;
  string    子_17_st;
  int       子_18_in;
  int       子_19_in;
  int       子_20_in;
  string    子_21_st;
  int       子_22_in;
  int       子_23_in;
  int       子_24_in;
//----- -----

 子_3_in = 20 ;
 子_4_in = 300 ;
 子_5_in = 7 ;
 子_6_do = InfoPanelSizeAdjust ;
 子_7_in = 6 ;
 子_8_in = 4 ;
 子_9_in = 350 ;
 子_10_in = 366 ;
 子_11_in = 0 ;
 子_12_in = 5 ;
 子_13_in = 20 ;
 子_14_ui = LightSteelBlue ;
 子_15_bo = false ;
 子_16_in = 0 ;
 if ( 总_17_bo_8C )
 {
   子_16_in = (int)((总_378_in_5D80 + 3) * 总_362_do_5CC8) ;
 }
 ObjectCreate(0,"infopanel_rectangle",OBJ_RECTANGLE_LABEL,0,0,0.0); 
 ObjectSetInteger(0,"infopanel_rectangle",OBJPROP_XDISTANCE,子_12_in); 
 ObjectSetInteger(0,"infopanel_rectangle",OBJPROP_YDISTANCE,子_13_in); 
 ObjectSetInteger(0,"infopanel_rectangle",OBJPROP_XSIZE,long(子_9_in * InfoPanelSizeAdjust)); 
 ObjectSetInteger(0,"infopanel_rectangle",OBJPROP_YSIZE,long(子_10_in * InfoPanelSizeAdjust + 子_16_in)); 
 ObjectSetInteger(0,"infopanel_rectangle",OBJPROP_CORNER,0); 
 ObjectSetInteger(0,"infopanel_rectangle",OBJPROP_COLOR,0xFF0000); 
 ObjectSetInteger(0,"infopanel_rectangle",OBJPROP_BGCOLOR,子_14_ui); 
 ObjectSetInteger(0,"infopanel_rectangle",OBJPROP_BACK,0); 
 ObjectSetInteger(0,"infopanel_rectangle",OBJPROP_BORDER_COLOR,0xFF0000); 
 ObjectSetInteger(0,"infopanel_rectangle",OBJPROP_COLOR,0xFF0000); 
 ObjectSetInteger(0,"infopanel_rectangle",OBJPROP_BORDER_TYPE,0); 
 ObjectSetInteger(0,"infopanel_rectangle",OBJPROP_STYLE,0); 
 ObjectSetInteger(0,"infopanel_rectangle",OBJPROP_WIDTH,0x2); 
 ObjectSetInteger(0,"infopanel_rectangle",OBJPROP_SELECTABLE,0); 
 ObjectCreate(0,"line1",OBJ_LABEL,0,0,0.0); 
 ObjectSetInteger(0,"line1",OBJPROP_CORNER,子_11_in); 
 ObjectSetInteger(0,"line1",OBJPROP_YDISTANCE,子_13_in + 子_8_in); 
 ObjectSetInteger(0,"line1",OBJPROP_XDISTANCE,子_12_in + 子_7_in); 
 ObjectSetString(0,"line1",OBJPROP_TEXT,"The Gold Reaper v4.6"); 
 ObjectSetInteger(0,"line1",OBJPROP_COLOR,总_329_ui_3104);
 // Ban decompile goc thieu set co chu rieng cho cac dong tieu de/tom tat panel
 // (chi co bang chien luoc phia duoi duoc set), trong khi kich thuoc khung panel
 // lai duoc tinh dua tren dung hang so co chu nay -> khien cac dong nay hien thi
 // to hon binh thuong (dung co mac dinh cua nen tang) so voi thiet ke that su cua
 // khung panel. Set khop voi co chu cua bang chien luoc de dong bo.
 ObjectSetInteger(0,"line1",OBJPROP_FONTSIZE,总_372_in_5CFC);
 ObjectCreate(0,"linec",OBJ_LABEL,0,0,0.0);
 ObjectSetInteger(0,"linec",OBJPROP_CORNER,子_11_in); 
 ObjectSetInteger(0,"linec",OBJPROP_YDISTANCE,long(子_13_in + InfoPanelSizeAdjust * 20.0 + 子_8_in)); 
 ObjectSetInteger(0,"linec",OBJPROP_XDISTANCE,子_12_in + 子_7_in); 
 ObjectSetString(0,"linec",OBJPROP_TEXT,"EA Developed by Wim Schrynemakers - 2024"); 
 ObjectSetInteger(0,"linec",OBJPROP_COLOR,总_329_ui_3104);
 ObjectSetInteger(0,"linec",OBJPROP_FONTSIZE,总_372_in_5CFC);
 ObjectCreate(0,"line2",OBJ_LABEL,0,0,0.0);
 ObjectSetInteger(0,"line2",OBJPROP_CORNER,子_11_in); 
 ObjectSetInteger(0,"line2",OBJPROP_YDISTANCE,long(子_13_in + InfoPanelSizeAdjust * 32.0 + 子_8_in)); 
 ObjectSetInteger(0,"line2",OBJPROP_XDISTANCE,子_12_in + 子_7_in); 
 ObjectSetString(0,"line2",OBJPROP_TEXT,"------------------------------------------------------"); 
 ObjectSetInteger(0,"line2",OBJPROP_COLOR,总_329_ui_3104);
 ObjectSetInteger(0,"line2",OBJPROP_FONTSIZE,总_372_in_5CFC);
 ObjectCreate(0,"lines",OBJ_LABEL,0,0,0.0);
 ObjectSetInteger(0,"lines",OBJPROP_CORNER,子_11_in); 
 ObjectSetInteger(0,"lines",OBJPROP_YDISTANCE,long(子_13_in + InfoPanelSizeAdjust * 44.0 + 子_8_in)); 
 ObjectSetInteger(0,"lines",OBJPROP_XDISTANCE,子_12_in + 子_7_in); 
 if ( 总_19_in_9C == 1 )
 {
   子_17_st = "conservative" ;
 }
 else
 {
   if ( 总_19_in_9C == 2 )
   {
     子_17_st = "moderate" ;
   }
   else
   {
     if ( 总_19_in_9C == 3 )
     {
       子_17_st = "intense" ;
     }
     else
     {
       if ( 总_19_in_9C == 4 )
       {
         子_17_st = "extreme" ;
       }
       else
       {
         if ( 总_19_in_9C == 0 )
         {
           子_17_st = "extreme conservative" ;
         }
         else
         {
           子_17_st = "manual strategy selection" ;
         }
       }
     }
   }
 }
 ObjectSetString(0,"lines",OBJPROP_TEXT,"Trade Frequency: " + 子_17_st);
 ObjectSetInteger(0,"lines",OBJPROP_COLOR,总_329_ui_3104);
 ObjectSetInteger(0,"lines",OBJPROP_FONTSIZE,总_372_in_5CFC);
 if ( Risk == 1234 )
 {
   ObjectCreate(0,"linet",OBJ_LABEL,0,0,0.0); 
   ObjectSetInteger(0,"linet",OBJPROP_CORNER,子_11_in); 
   ObjectSetInteger(0,"linet",OBJPROP_YDISTANCE,long(子_13_in + InfoPanelSizeAdjust * 60.0 + 子_8_in)); 
   ObjectSetInteger(0,"linet",OBJPROP_XDISTANCE,子_12_in + 子_7_in); 
   ObjectSetString(0,"linet",OBJPROP_TEXT,"Max allowed DD: " + string(MaxAllowedDD) + "%");
   ObjectSetInteger(0,"linet",OBJPROP_COLOR,总_329_ui_3104);
   ObjectSetInteger(0,"linet",OBJPROP_FONTSIZE,总_372_in_5CFC);
 }
 else
 {
   if ( Risk == 3 )
   {
     ObjectCreate(0,"linet",OBJ_LABEL,0,0,0.0); 
     ObjectSetInteger(0,"linet",OBJPROP_CORNER,子_11_in); 
     ObjectSetInteger(0,"linet",OBJPROP_YDISTANCE,long(子_13_in + InfoPanelSizeAdjust * 60.0 + 子_8_in)); 
     ObjectSetInteger(0,"linet",OBJPROP_XDISTANCE,子_12_in + 子_7_in); 
     ObjectSetString(0,"linet",OBJPROP_TEXT,"Max risk per strategy: " + string(MaxRiskPerStrategy_) + "%");
     ObjectSetInteger(0,"linet",OBJPROP_COLOR,总_329_ui_3104);
     ObjectSetInteger(0,"linet",OBJPROP_FONTSIZE,总_372_in_5CFC);
   }
   else
   {
     ObjectCreate(0,"linet",OBJ_LABEL,0,0,0.0);
     ObjectSetInteger(0,"linet",OBJPROP_CORNER,子_11_in); 
     ObjectSetInteger(0,"linet",OBJPROP_YDISTANCE,long(子_13_in + InfoPanelSizeAdjust * 60.0 + 子_8_in)); 
     ObjectSetInteger(0,"linet",OBJPROP_XDISTANCE,子_12_in + 子_7_in); 
     ObjectSetString(0,"linet",OBJPROP_TEXT,"Manual lotsize: " + string(g_startLots_rw) + "lots");
     ObjectSetInteger(0,"linet",OBJPROP_COLOR,总_329_ui_3104);
     ObjectSetInteger(0,"linet",OBJPROP_FONTSIZE,总_372_in_5CFC);
   }
 }
 ObjectCreate(0,"lineopl" + IntegerToString(0,0,32),OBJ_LABEL,0,0,0.0);
 ObjectSetInteger(0,"lineopl" + IntegerToString(0,0,32),OBJPROP_CORNER,子_11_in); 
 ObjectSetInteger(0,"lineopl" + IntegerToString(0,0,32),OBJPROP_YDISTANCE,(long)(子_13_in + InfoPanelSizeAdjust * 76.0 + 子_8_in)); 
 ObjectSetInteger(0,"lineopl" + IntegerToString(0,0,32),OBJPROP_XDISTANCE,子_12_in + 子_7_in); 
 ObjectSetString(0,"lineopl" + IntegerToString(0,0,32),OBJPROP_TEXT,"Open P/L: -");
 ObjectSetInteger(0,"lineopl" + IntegerToString(0,0,32),OBJPROP_COLOR,总_329_ui_3104);
 ObjectSetInteger(0,"lineopl" + IntegerToString(0,0,32),OBJPROP_FONTSIZE,总_372_in_5CFC);
 ObjectCreate(0,"linehb" + IntegerToString(0,0,32),OBJ_LABEL,0,0,0.0);
 ObjectSetInteger(0,"linehb" + IntegerToString(0,0,32),OBJPROP_CORNER,子_11_in);
 ObjectSetInteger(0,"linehb" + IntegerToString(0,0,32),OBJPROP_YDISTANCE,(long)(子_13_in + InfoPanelSizeAdjust * 92.0 + 子_8_in));
 ObjectSetInteger(0,"linehb" + IntegerToString(0,0,32),OBJPROP_XDISTANCE,子_12_in + 子_7_in);
 ObjectSetString(0,"linehb" + IntegerToString(0,0,32),OBJPROP_TEXT,"Higher Balance: -");
 ObjectSetInteger(0,"linehb" + IntegerToString(0,0,32),OBJPROP_COLOR,总_329_ui_3104);
 ObjectSetInteger(0,"linehb" + IntegerToString(0,0,32),OBJPROP_FONTSIZE,总_372_in_5CFC);
 ObjectCreate(0,"linea" + IntegerToString(0,0,32),OBJ_LABEL,0,0,0.0);
 ObjectSetInteger(0,"linea" + IntegerToString(0,0,32),OBJPROP_CORNER,子_11_in); 
 ObjectSetInteger(0,"linea" + IntegerToString(0,0,32),OBJPROP_YDISTANCE,(long)(子_13_in + InfoPanelSizeAdjust * 108.0 + 子_8_in)); 
 ObjectSetInteger(0,"linea" + IntegerToString(0,0,32),OBJPROP_XDISTANCE,子_12_in + 子_7_in); 
 ObjectSetString(0,"linea" + IntegerToString(0,0,32),OBJPROP_TEXT,"Account Balance: -");
 ObjectSetInteger(0,"linea" + IntegerToString(0,0,32),OBJPROP_COLOR,总_329_ui_3104);
 ObjectSetInteger(0,"linea" + IntegerToString(0,0,32),OBJPROP_FONTSIZE,总_372_in_5CFC);
 ObjectCreate(0,"linetp" + IntegerToString(0,0,32),OBJ_LABEL,0,0,0.0);
 ObjectSetInteger(0,"linetp" + IntegerToString(0,0,32),OBJPROP_CORNER,子_11_in);
 ObjectSetInteger(0,"linetp" + IntegerToString(0,0,32),OBJPROP_YDISTANCE,(long)(子_13_in + InfoPanelSizeAdjust * 124.0 + 子_8_in));
 ObjectSetInteger(0,"linetp" + IntegerToString(0,0,32),OBJPROP_XDISTANCE,子_12_in + 子_7_in);
 ObjectSetString(0,"linetp" + IntegerToString(0,0,32),OBJPROP_TEXT,"Total P/L so far: -");
 ObjectSetInteger(0,"linetp" + IntegerToString(0,0,32),OBJPROP_COLOR,总_329_ui_3104);
 ObjectSetInteger(0,"linetp" + IntegerToString(0,0,32),OBJPROP_FONTSIZE,总_372_in_5CFC);
 if ( EnableNFP_Filter )
 {
   ObjectCreate(0,"linenfp" + IntegerToString(0,0,32),OBJ_LABEL,0,0,0.0);
   ObjectSetInteger(0,"linenfp" + IntegerToString(0,0,32),OBJPROP_CORNER,子_11_in);
   ObjectSetInteger(0,"linenfp" + IntegerToString(0,0,32),OBJPROP_YDISTANCE,(long)(子_13_in + InfoPanelSizeAdjust * 140.0 + 子_8_in));
   ObjectSetInteger(0,"linenfp" + IntegerToString(0,0,32),OBJPROP_XDISTANCE,子_12_in + 子_7_in);
   ObjectSetString(0,"linenfp" + IntegerToString(0,0,32),OBJPROP_TEXT,"no news coming up");
   ObjectSetInteger(0,"linenfp" + IntegerToString(0,0,32),OBJPROP_COLOR,总_329_ui_3104);
   ObjectSetInteger(0,"linenfp" + IntegerToString(0,0,32),OBJPROP_FONTSIZE,总_372_in_5CFC);
 }
 子_18_in = 0 ;
 子_19_in = 0 ;
 子_20_in = 0 ;
 子_22_in = 子_12_in + 子_7_in ;
 子_23_in = (int)(子_13_in + InfoPanelSizeAdjust * 176.0 + 子_8_in) ;
 子_21_st = "Strategy" ;
 lizong_25(子_22_in,子_23_in,0,"Strategy",0,0,1,0,1.0); 
 子_18_in = 1 ;
 子_19_in = 1 ;
 子_21_st = "Closed PL" ;
 if ( 总_152_in_43C == 1 )
 {
   子_21_st = "Closed PL*" ;
 }
 lizong_25(子_22_in,子_23_in,子_18_in,子_21_st,子_20_in,子_19_in,1,0,1.0); 
 子_18_in ++;
 子_19_in ++;
 子_21_st = "PL per trade" ;
 lizong_25(子_22_in,子_23_in,子_18_in,子_21_st,子_20_in,子_19_in,1,0,1.0); 
 子_18_in ++;
 子_19_in ++;
 子_21_st = "Lotsize" ;
 lizong_25(子_22_in,子_23_in,子_18_in,"Lotsize",子_20_in,子_19_in,1,0,1.0); 
 子_18_in ++;
 子_19_in = 0 ;
 子_20_in ++;
 总_340_in_3310 = 子_18_in ;
 for (子_24_in = 0 ; 子_24_in < 9 ; 子_24_in ++)
 {
   子_21_st="Strategy " + IntegerToString(子_24_in + 1,0,32);
   lizong_25(子_22_in,子_23_in,子_18_in,子_21_st,子_20_in,子_19_in,1,0,1.0); 
   子_18_in ++;
   子_19_in ++;
   子_21_st = DoubleToString(NormalizeDouble(总_400_do_67B4_si99[子_24_in],2),2) ;
   lizong_25(子_22_in,子_23_in,子_18_in,子_21_st,子_20_in,子_19_in,1,0,1.0); 
   子_18_in ++;
   子_19_in ++;
   子_21_st = DoubleToString(NormalizeDouble(总_345_do_3AAC_si99[子_24_in],2),2) ;
   lizong_25(子_22_in,子_23_in,子_18_in,子_21_st,子_20_in,子_19_in,1,0,1.0); 
   子_18_in ++;
   子_19_in ++;
   子_21_st = DoubleToString(NormalizeDouble(总_223_do_1AC4_si99[子_24_in],2),2) ;
   lizong_25(子_22_in,子_23_in,子_18_in,子_21_st,子_20_in,子_19_in,1,0,1.0); 
   子_18_in ++;
   子_19_in = 0 ;
   子_20_in ++;
 }
 }
//lizong_24 <<==--------   --------
 void lizong_25( int 木_0_in,int 木_1_in,int 木_2_in,string 木_3_st,int 木_4_in,int 木_5_in,int 木_6_in,uint 木_7_ui,double 木_8_do)
 {
 ObjectCreate(0,"info_ea" + IntegerToString(木_2_in,0,32),OBJ_EDIT,0,0,0.0); 
 ObjectSetInteger(0,"info_ea" + IntegerToString(木_2_in,0,32),OBJPROP_XDISTANCE,(long)(木_0_in + 木_5_in * 总_361_do_5CC0)); 
 ObjectSetInteger(0,"info_ea" + IntegerToString(木_2_in,0,32),OBJPROP_YDISTANCE,(long)(木_1_in + 木_4_in * 总_362_do_5CC8)); 
 ObjectSetString(0,"info_ea" + IntegerToString(木_2_in,0,32),OBJPROP_TEXT,木_3_st); 
 ObjectSetInteger(0,"info_ea" + IntegerToString(木_2_in,0,32),OBJPROP_BACK,0); 
 ObjectSetInteger(0,"info_ea" + IntegerToString(木_2_in,0,32),OBJPROP_COLOR,木_7_ui); 
 ObjectSetInteger(0,"info_ea" + IntegerToString(木_2_in,0,32),OBJPROP_BGCOLOR,总_364_ui_5CD4); 
 ObjectSetInteger(0,"info_ea" + IntegerToString(木_2_in,0,32),OBJPROP_BORDER_COLOR,0); 
 ObjectSetInteger(0,"info_ea" + IntegerToString(木_2_in,0,32),OBJPROP_FONTSIZE,(long)(总_372_in_5CFC * 木_8_do)); 
 ObjectSetInteger(0,"info_ea" + IntegerToString(木_2_in,0,32),OBJPROP_READONLY,0x1); 
 ObjectSetInteger(0,"info_ea" + IntegerToString(木_2_in,0,32),OBJPROP_YSIZE,(long)总_362_do_5CC8); 
 ObjectSetInteger(0,"info_ea" + IntegerToString(木_2_in,0,32),OBJPROP_XSIZE,(long)总_361_do_5CC0); 
 ObjectSetInteger(0,"info_ea" + IntegerToString(木_2_in,0,32),OBJPROP_YSIZE,(long)总_362_do_5CC8); 
 if ( 木_6_in == 0 )
 {
   ObjectSetInteger(0,"info_ea" + IntegerToString(木_2_in,0,32),OBJPROP_ALIGN,0x1); 
 }
 if ( 木_6_in == 1 )
 {
   ObjectSetInteger(0,"info_ea" + IntegerToString(木_2_in,0,32),OBJPROP_ALIGN,0x2); 
 }
 if ( 木_6_in != 2 )   return;
 ObjectSetInteger(0,"info_ea" + IntegerToString(木_2_in,0,32),OBJPROP_ALIGN,0); 
 }
//lizong_25 <<==--------   --------
 void lizong_26()
 {
  int       子_1_in;
  int       子_2_in;
  int       子_3_in;
  int       子_4_in;
//----- -----

 ObjectDelete(0,"line1"); 
 ObjectDelete(0,"linec"); 
 ObjectDelete(0,"line2"); 
 ObjectDelete(0,"lines"); 
 ObjectDelete(0,"linet"); 
 ObjectDelete(0,"lineTradeStart"); 
 for (子_1_in = 0 ; 子_1_in <= 99 ; 子_1_in ++)
 {
   ObjectDelete(0,"lineopl" + IntegerToString(子_1_in,0,32)); 
   ObjectDelete(0,"linehb" + IntegerToString(子_1_in,0,32));
   ObjectDelete(0,"linea" + IntegerToString(子_1_in,0,32)); 
   ObjectDelete(0,"lineto" + IntegerToString(子_1_in,0,32)); 
   ObjectDelete(0,"linetp" + IntegerToString(子_1_in,0,32));
   ObjectDelete(0,"linetq" + IntegerToString(子_1_in,0,32));
   ObjectDelete(0,"linenfp" + IntegerToString(子_1_in,0,32));
   for (子_2_in = 0 ; 子_2_in < 10 ; 子_2_in ++)
   {
     ObjectDelete(0,"tabel_info" + IntegerToString(子_1_in * 100 + 子_2_in,0,32)); 
   }
 }
 ObjectDelete(0,"infopanel_rectangle"); 
 for (子_3_in = 0 ; 子_3_in < 10 ; 子_3_in ++)
 {
   ObjectDelete(0,"tabel_heading" + IntegerToString(子_3_in,0,32)); 
   ObjectDelete(0,"tabel_totals" + IntegerToString(子_3_in,0,32)); 
 }
 for (子_4_in = 0 ; 子_4_in < 总_360_in_5CB8 ; 子_4_in ++)
 {
   ObjectDelete(0,"horizontalrect" + IntegerToString(子_4_in,0,32)); 
   ObjectDelete(0,"info_ea" + IntegerToString(子_4_in,0,32)); 
 }
 }
//lizong_26 <<==--------   --------
 string GetNextNFPText()
 {
  // Original V4.6 panel reads only the single cached calendar timestamp.
  // It does not scan the hardcoded backtest table for display fallback.
  if ( g_nextNFPCalendar != 0 )
  {
    return("Next NFP: " + TimeToString(g_nextNFPCalendar,TIME_DATE|TIME_SECONDS));
  }
  return("no news coming up");
 }
//GetNextNFPText <<==--------   --------
 void lizong_27()
 {
  string    子_1_st;
//----- -----
 double     临_do_1;
 double     临_do_2;
 int        临_in_3;
 int        临_in_4;
 int        临_in_5;
 int        临_in_6;
 int        临_in_7;
 int        临_in_8;
 int        临_in_9;
 int        临_in_10;
 int        临_in_11;
 int        临_in_12;
 int        临_in_13;
 int        临_in_14;
 int        临_in_15;
 int        临_in_16;
 int        临_in_17;
 int        临_in_18;
 int        临_in_19;

 if ( !(ShowInfoPanel) )   return;
 
 if ( ( MQLInfoInteger(MQL_TESTER) == 1 && !(UpdateInfoTesting) ) )   return;
 
 if ( MQLInfoInteger(MQL_TESTER) == 1 && !(UpdateInfoTesting) )
 {
   临_do_1 = 0.0;
 }
 else
 {
   临_do_2 = 0.0;
   for (临_in_3 = NativeTradesTotal() ; 临_in_3 >= 0 ; 临_in_3=临_in_3 - 1)
   {
     if ( g_trade_view.Select(临_in_3,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true )   continue;
     
     if ( ( g_trade_view.SymbolName() != 总_336_st_3130 && !(总_17_bo_8C) ) )   continue;
     临_in_4 = g_trade_view.Magic();
     临_in_5=ST1_MagicNumber + 1;
     if ( 临_in_4 != 临_in_5 )
     {
       临_in_5 = g_trade_view.Magic();
       临_in_6=ST1_MagicNumber + 2;
       if ( 临_in_5 != 临_in_6 )
       {
         临_in_6 = g_trade_view.Magic();
         临_in_7=ST1_MagicNumber + 3;
         if ( 临_in_6 != 临_in_7 )
         {
           临_in_7 = g_trade_view.Magic();
           临_in_8=ST1_MagicNumber + 4;
           if ( 临_in_7 != 临_in_8 )
           {
             临_in_8 = g_trade_view.Magic();
             临_in_9=ST1_MagicNumber + 5;
             if ( 临_in_8 != 临_in_9 )
             {
               临_in_9 = g_trade_view.Magic();
               临_in_10=ST1_MagicNumber + 6;
               if ( 临_in_9 != 临_in_10 )
               {
                 临_in_10 = g_trade_view.Magic();
                 临_in_11=ST1_MagicNumber + 7;
                 if ( 临_in_10 != 临_in_11 )
                 {
                   临_in_11 = g_trade_view.Magic();
                   临_in_12=ST1_MagicNumber + 8;
                   if ( 临_in_11 != 临_in_12 )
                   {
                     临_in_12 = g_trade_view.Magic();
                     临_in_13=ST1_MagicNumber + 9;
                     if ( 临_in_12 != 临_in_13 )
                     {
                       临_in_13 = g_trade_view.Magic();
                       临_in_14=ST1_MagicNumber + 10;
                       if ( 临_in_13 != 临_in_14 )
                       {
                         临_in_14 = g_trade_view.Magic();
                         临_in_15=ST1_MagicNumber + 11;
                         if ( 临_in_14 != 临_in_15 )
                         {
                           临_in_15 = g_trade_view.Magic();
                           临_in_16=ST1_MagicNumber + 12;
                           if ( 临_in_15 != 临_in_16 )
                           {
                             临_in_16 = g_trade_view.Magic();
                             临_in_17=ST1_MagicNumber + 13;
                             if ( 临_in_16 != 临_in_17 )
                             {
                               临_in_17 = g_trade_view.Magic();
                               临_in_18=ST1_MagicNumber + 14;
                               if ( 临_in_17 != 临_in_18 )
                               {
                                 临_in_18 = g_trade_view.Magic();
                                 临_in_19=ST1_MagicNumber + 15;
                               if ( 临_in_18 != 临_in_19 )   continue;
                               }
                             }
                           }
                         }
                       }
                     }
                   }
                 }
               }
             }
           }
         }
       }
     }
     if ( ( g_trade_view.OrderType() != ORDER_TYPE_BUY && g_trade_view.OrderType() != ORDER_TYPE_SELL ) )   continue;
     临_do_2 = g_trade_view.Profit() + g_trade_view.Swap() + g_trade_view.Commission() + 临_do_2;
     
   }
   总_323_do_2CA0_si30[总_328_in_3100] = 临_do_2;
   临_do_1 = 临_do_2;
 }
 ObjectSetString(0,"lineopl" + IntegerToString(0,0,32),OBJPROP_TEXT,"Open P/L: " + DoubleToString(临_do_1,2)); 
 ObjectSetString(0,"linehb" + IntegerToString(0,0,32),OBJPROP_TEXT,"Higher Balance: " + DoubleToString(总_402_do_6AD8,2));
 ObjectSetString(0,"linea" + IntegerToString(0,0,32),OBJPROP_TEXT,"Account Balance: " + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE),2)); 
 if ( 总_19_in_9C == 1 )
 {
   子_1_st = "conservative" ;
 }
 else
 {
   if ( 总_19_in_9C == 2 )
   {
     子_1_st = "moderate" ;
   }
   else
   {
     if ( 总_19_in_9C == 3 )
     {
       子_1_st = "intense" ;
     }
     else
     {
       if ( 总_19_in_9C == 4 )
       {
         子_1_st = "extreme" ;
       }
       else
       {
         if ( 总_19_in_9C == 0 )
         {
           子_1_st = "extreme conservative" ;
         }
         else
         {
           子_1_st = "manual strategy selection" ;
         }
       }
     }
   }
 }
 ObjectSetString(0,"lines",OBJPROP_TEXT,"Trade Frequency: " + 子_1_st); 
 if ( Risk == 1234 )
 {
   ObjectSetString(0,"linet",OBJPROP_TEXT,"Max allowed DD: " + string(MaxAllowedDD) + "%"); 
 }
 else
 {
   if ( Risk == 3 )
   {
     ObjectSetString(0,"linet",OBJPROP_TEXT,"Max risk per strategy: " + string(MaxRiskPerStrategy_) + "%"); 
   }
   else
   {
     ObjectSetString(0,"linet",OBJPROP_TEXT,"Manual lotsize: " + string(g_startLots_rw) + "lots"); 
   }
 }
 }
//lizong_27 <<==--------   --------
 void lizong_28()
 {
  int       子_1_in;
  string    子_2_st;
  int       子_3_in;
//----- -----

 if ( !(ShowInfoPanel) )   return;
 
 if ( ( MQLInfoInteger(MQL_TESTER) == 1 && !(UpdateInfoTesting) ) )   return;
 子_1_in = 总_340_in_3310 ;
 for (子_3_in = 0 ; 子_3_in < 9 ; 子_3_in ++)
 {
   子_2_st="Strategy " + IntegerToString(子_3_in + 1,0,32);
   ObjectSetString(0,"info_ea" + IntegerToString(子_1_in,0,32),OBJPROP_TEXT,子_2_st); 
   子_1_in ++;
   子_2_st = DoubleToString(NormalizeDouble(总_400_do_67B4_si99[子_3_in],2),2) ;
   ObjectSetString(0,"info_ea" + IntegerToString(子_1_in,0,32),OBJPROP_TEXT,子_2_st); 
   子_1_in ++;
   子_2_st = DoubleToString(NormalizeDouble(总_345_do_3AAC_si99[子_3_in],2),2) ;
   ObjectSetString(0,"info_ea" + IntegerToString(子_1_in,0,32),OBJPROP_TEXT,子_2_st); 
   子_1_in ++;
   子_2_st = DoubleToString(NormalizeDouble(总_223_do_1AC4_si99[子_3_in],2),2) ;
   ObjectSetString(0,"info_ea" + IntegerToString(子_1_in,0,32),OBJPROP_TEXT,子_2_st); 
   子_1_in ++;
 }
 }
//lizong_28 <<==--------   --------
 void lizong_29()
 {
 double     临_do_1;
 double     临_do_2;
 int        临_in_3;
 int        临_in_4;
 int        临_in_5;
 int        临_in_6;
 int        临_in_7;
 int        临_in_8;
 int        临_in_9;
 int        临_in_10;
 int        临_in_11;
 int        临_in_12;
 int        临_in_13;
 int        临_in_14;
 int        临_in_15;
 int        临_in_16;
 int        临_in_17;
 int        临_in_18;
 int        临_in_19;
 int        临_in_20;

 if ( !(ShowInfoPanel) )   return;
 
 if ( ( MQLInfoInteger(MQL_TESTER) == 1 && !(UpdateInfoTesting) ) )   return;
 ObjectSetString(0,"lineto" + IntegerToString(0,0,32),OBJPROP_TEXT,"Total profits/losses so far: " + IntegerToString(lizong_30(0,9999999),0,32) + "/" + IntegerToString(lizong_31(0,9999999),0,32)); 
 if ( MQLInfoInteger(MQL_TESTER) == 1 && !(UpdateInfoTesting) )
 {
   临_do_1 = 0.0;
 }
 else
 {
   临_do_2 = 0.0;
   临_in_3 = 0;
   for (临_in_4 = NativeHistoryTotal() ; 临_in_4 >= 0 ; 临_in_4=临_in_4 - 1)
   {
     if ( g_trade_view.Select(临_in_4,NATIVE_SELECT_BY_POSITION,NATIVE_HISTORY_POOL) != true )   continue;
     
     if ( ( g_trade_view.SymbolName() != 总_336_st_3130 && !(总_17_bo_8C) ) )   continue;
     临_in_5 = g_trade_view.Magic();
     临_in_6=ST1_MagicNumber + 1;
     if ( 临_in_5 != 临_in_6 )
     {
       临_in_6 = g_trade_view.Magic();
       临_in_7=ST1_MagicNumber + 2;
       if ( 临_in_6 != 临_in_7 )
       {
         临_in_7 = g_trade_view.Magic();
         临_in_8=ST1_MagicNumber + 3;
         if ( 临_in_7 != 临_in_8 )
         {
           临_in_8 = g_trade_view.Magic();
           临_in_9=ST1_MagicNumber + 4;
           if ( 临_in_8 != 临_in_9 )
           {
             临_in_9 = g_trade_view.Magic();
             临_in_10=ST1_MagicNumber + 5;
             if ( 临_in_9 != 临_in_10 )
             {
               临_in_10 = g_trade_view.Magic();
               临_in_11=ST1_MagicNumber + 6;
               if ( 临_in_10 != 临_in_11 )
               {
                 临_in_11 = g_trade_view.Magic();
                 临_in_12=ST1_MagicNumber + 7;
                 if ( 临_in_11 != 临_in_12 )
                 {
                   临_in_12 = g_trade_view.Magic();
                   临_in_13=ST1_MagicNumber + 8;
                   if ( 临_in_12 != 临_in_13 )
                   {
                     临_in_13 = g_trade_view.Magic();
                     临_in_14=ST1_MagicNumber + 9;
                     if ( 临_in_13 != 临_in_14 )
                     {
                       临_in_14 = g_trade_view.Magic();
                       临_in_15=ST1_MagicNumber + 10;
                       if ( 临_in_14 != 临_in_15 )
                       {
                         临_in_15 = g_trade_view.Magic();
                         临_in_16=ST1_MagicNumber + 11;
                         if ( 临_in_15 != 临_in_16 )
                         {
                           临_in_16 = g_trade_view.Magic();
                           临_in_17=ST1_MagicNumber + 12;
                           if ( 临_in_16 != 临_in_17 )
                           {
                             临_in_17 = g_trade_view.Magic();
                             临_in_18=ST1_MagicNumber + 13;
                             if ( 临_in_17 != 临_in_18 )
                             {
                               临_in_18 = g_trade_view.Magic();
                               临_in_19=ST1_MagicNumber + 14;
                               if ( 临_in_18 != 临_in_19 )
                               {
                                 临_in_19 = g_trade_view.Magic();
                                 临_in_20=ST1_MagicNumber + 15;
                               if ( 临_in_19 != 临_in_20 )   continue;
                               }
                             }
                           }
                         }
                       }
                     }
                   }
                 }
               }
             }
           }
         }
       }
     }
     临_in_3=临_in_3 + 1;
     临_do_2 = 临_do_2 + g_trade_view.Profit() + g_trade_view.Swap() + g_trade_view.Commission();
     if ( 临_in_3 >= 1000 )   break;
     
   }
   总_326_do_300C_si30[总_328_in_3100] = 临_do_2;
   临_do_1 = 临_do_2;
 }
 ObjectSetString(0,"linetp" + IntegerToString(0,0,32),OBJPROP_TEXT,"Total P/L so far: " + DoubleToString(NormalizeDouble(临_do_1,2),2));
 if ( EnableNFP_Filter )
 {
   ObjectSetString(0,"linenfp" + IntegerToString(0,0,32),OBJPROP_TEXT,GetNextNFPText());
 }
 }
//lizong_29 <<==--------   --------
 int lizong_30( int 木_0_in,int 木_1_in)
 {
  double    子_2_do;
  int       子_3_in;
  int       子_4_in;
  int       子_5_in;
//----- -----
 int        临_in_1;
 int        临_in_2;
 int        临_in_3;
 int        临_in_4;
 int        临_in_5;
 int        临_in_6;
 int        临_in_7;
 int        临_in_8;
 int        临_in_9;
 int        临_in_10;
 int        临_in_11;
 int        临_in_12;
 int        临_in_13;
 int        临_in_14;
 int        临_in_15;
 int        临_in_16;

 if ( MQLInfoInteger(MQL_TESTER) == 1 && !(UpdateInfoTesting) )
 {
   return(0); 
 }
 子_2_do = 0.0 ;
 子_3_in = 0 ;
 子_4_in = 0 ;
 for (子_5_in = NativeHistoryTotal() ; 子_5_in >= 0 ; 子_5_in --)
 {
   if ( g_trade_view.Select(子_5_in,NATIVE_SELECT_BY_POSITION,NATIVE_HISTORY_POOL) != true )   continue;
   
   if ( ( g_trade_view.SymbolName() != 总_336_st_3130 && !(总_17_bo_8C) ) )   continue;
   临_in_1 = g_trade_view.Magic();
   临_in_2=ST1_MagicNumber + 1;
   if ( 临_in_1 != 临_in_2 )
   {
     临_in_2 = g_trade_view.Magic();
     临_in_3=ST1_MagicNumber + 2;
     if ( 临_in_2 != 临_in_3 )
     {
       临_in_3 = g_trade_view.Magic();
       临_in_4=ST1_MagicNumber + 3;
       if ( 临_in_3 != 临_in_4 )
       {
         临_in_4 = g_trade_view.Magic();
         临_in_5=ST1_MagicNumber + 4;
         if ( 临_in_4 != 临_in_5 )
         {
           临_in_5 = g_trade_view.Magic();
           临_in_6=ST1_MagicNumber + 5;
           if ( 临_in_5 != 临_in_6 )
           {
             临_in_6 = g_trade_view.Magic();
             临_in_7=ST1_MagicNumber + 6;
             if ( 临_in_6 != 临_in_7 )
             {
               临_in_7 = g_trade_view.Magic();
               临_in_8=ST1_MagicNumber + 7;
               if ( 临_in_7 != 临_in_8 )
               {
                 临_in_8 = g_trade_view.Magic();
                 临_in_9=ST1_MagicNumber + 8;
                 if ( 临_in_8 != 临_in_9 )
                 {
                   临_in_9 = g_trade_view.Magic();
                   临_in_10=ST1_MagicNumber + 9;
                   if ( 临_in_9 != 临_in_10 )
                   {
                     临_in_10 = g_trade_view.Magic();
                     临_in_11=ST1_MagicNumber + 10;
                     if ( 临_in_10 != 临_in_11 )
                     {
                       临_in_11 = g_trade_view.Magic();
                       临_in_12=ST1_MagicNumber + 11;
                       if ( 临_in_11 != 临_in_12 )
                       {
                         临_in_12 = g_trade_view.Magic();
                         临_in_13=ST1_MagicNumber + 12;
                         if ( 临_in_12 != 临_in_13 )
                         {
                           临_in_13 = g_trade_view.Magic();
                           临_in_14=ST1_MagicNumber + 13;
                           if ( 临_in_13 != 临_in_14 )
                           {
                             临_in_14 = g_trade_view.Magic();
                             临_in_15=ST1_MagicNumber + 14;
                             if ( 临_in_14 != 临_in_15 )
                             {
                               临_in_15 = g_trade_view.Magic();
                               临_in_16=ST1_MagicNumber + 15;
                             if ( 临_in_15 != 临_in_16 )   continue;
                             }
                           }
                         }
                       }
                     }
                   }
                 }
               }
             }
           }
         }
       }
     }
   }
   子_3_in ++;
   if ( ( g_trade_view.OrderType() == ORDER_TYPE_BUY || g_trade_view.OrderType() == ORDER_TYPE_SELL ) )
   {
     if ( g_trade_view.OrderType() == ORDER_TYPE_BUY )
     {
       子_2_do = g_trade_view.PriceClose() - g_trade_view.PriceOpen() ;
     }
     else
     {
       if ( g_trade_view.OrderType() == ORDER_TYPE_SELL )
       {
         子_2_do = g_trade_view.PriceOpen() - g_trade_view.PriceClose() ;
       }
     }
     if ( 子_2_do>0.0 )
     {
       子_4_in ++;
     }
   }
   if ( 子_3_in >= 木_1_in )   break;
   
 }
 总_324_do_2DC4_si30[总_328_in_3100] = 子_4_in;
 return(子_4_in); 
 }
//lizong_30 <<==--------   --------
 int lizong_31( int 木_0_in,int 木_1_in)
 {
  double    子_2_do;
  int       子_3_in;
  int       子_4_in;
  int       子_5_in;
//----- -----
 int        临_in_1;
 int        临_in_2;
 int        临_in_3;
 int        临_in_4;
 int        临_in_5;
 int        临_in_6;
 int        临_in_7;
 int        临_in_8;
 int        临_in_9;
 int        临_in_10;
 int        临_in_11;
 int        临_in_12;
 int        临_in_13;
 int        临_in_14;
 int        临_in_15;
 int        临_in_16;

 if ( MQLInfoInteger(MQL_TESTER) == 1 && !(UpdateInfoTesting) )
 {
   return(0); 
 }
 子_2_do = 0.0 ;
 子_3_in = 0 ;
 子_4_in = 0 ;
 for (子_5_in = NativeHistoryTotal() ; 子_5_in >= 0 ; 子_5_in --)
 {
   if ( g_trade_view.Select(子_5_in,NATIVE_SELECT_BY_POSITION,NATIVE_HISTORY_POOL) != true )   continue;
   
   if ( ( g_trade_view.SymbolName() != 总_336_st_3130 && !(总_17_bo_8C) ) )   continue;
   临_in_1 = g_trade_view.Magic();
   临_in_2=ST1_MagicNumber + 1;
   if ( 临_in_1 != 临_in_2 )
   {
     临_in_2 = g_trade_view.Magic();
     临_in_3=ST1_MagicNumber + 2;
     if ( 临_in_2 != 临_in_3 )
     {
       临_in_3 = g_trade_view.Magic();
       临_in_4=ST1_MagicNumber + 3;
       if ( 临_in_3 != 临_in_4 )
       {
         临_in_4 = g_trade_view.Magic();
         临_in_5=ST1_MagicNumber + 4;
         if ( 临_in_4 != 临_in_5 )
         {
           临_in_5 = g_trade_view.Magic();
           临_in_6=ST1_MagicNumber + 5;
           if ( 临_in_5 != 临_in_6 )
           {
             临_in_6 = g_trade_view.Magic();
             临_in_7=ST1_MagicNumber + 6;
             if ( 临_in_6 != 临_in_7 )
             {
               临_in_7 = g_trade_view.Magic();
               临_in_8=ST1_MagicNumber + 7;
               if ( 临_in_7 != 临_in_8 )
               {
                 临_in_8 = g_trade_view.Magic();
                 临_in_9=ST1_MagicNumber + 8;
                 if ( 临_in_8 != 临_in_9 )
                 {
                   临_in_9 = g_trade_view.Magic();
                   临_in_10=ST1_MagicNumber + 9;
                   if ( 临_in_9 != 临_in_10 )
                   {
                     临_in_10 = g_trade_view.Magic();
                     临_in_11=ST1_MagicNumber + 10;
                     if ( 临_in_10 != 临_in_11 )
                     {
                       临_in_11 = g_trade_view.Magic();
                       临_in_12=ST1_MagicNumber + 11;
                       if ( 临_in_11 != 临_in_12 )
                       {
                         临_in_12 = g_trade_view.Magic();
                         临_in_13=ST1_MagicNumber + 12;
                         if ( 临_in_12 != 临_in_13 )
                         {
                           临_in_13 = g_trade_view.Magic();
                           临_in_14=ST1_MagicNumber + 13;
                           if ( 临_in_13 != 临_in_14 )
                           {
                             临_in_14 = g_trade_view.Magic();
                             临_in_15=ST1_MagicNumber + 14;
                             if ( 临_in_14 != 临_in_15 )
                             {
                               临_in_15 = g_trade_view.Magic();
                               临_in_16=ST1_MagicNumber + 15;
                             if ( 临_in_15 != 临_in_16 )   continue;
                             }
                           }
                         }
                       }
                     }
                   }
                 }
               }
             }
           }
         }
       }
     }
   }
   子_3_in ++;
   if ( g_trade_view.OrderType() == ORDER_TYPE_BUY )
   {
     子_2_do = g_trade_view.PriceClose() - g_trade_view.PriceOpen() ;
   }
   else
   {
     if ( g_trade_view.OrderType() == ORDER_TYPE_SELL )
     {
       子_2_do = g_trade_view.PriceOpen() - g_trade_view.PriceClose() ;
     }
   }
   if ( 子_2_do<0.0 )
   {
     子_4_in ++;
   }
   if ( 子_3_in >= 木_1_in )   break;
   
 }
 总_325_do_2EE8_si30[总_328_in_3100] = 子_4_in;
 return(子_4_in); 
 }
//lizong_31 <<==--------   --------
 void lizong_32()
 {
  int       子_1_in = 0;
  double    子_2_do_si99[99];
  double    子_3_do_si99[99];
  int       子_4_in;
  int       子_5_in;
  bool      子_6_bo;
  int       子_7_in;
  double    子_8_do;
  int       子_9_in;
  int       子_10_in;
//----- -----
 long       临_lo_1;
 long       临_lo_2;
 long       临_lo_3;
 long       临_lo_4;
 long       临_lo_5;

 if ( ( MQLInfoInteger(MQL_TESTER) == 1 && !(UpdateInfoTesting) ) )   return;
 for (子_4_in = 0 ; 子_4_in < 总_378_in_5D80 ; 子_4_in ++)
 {
   子_2_do_si99[子_4_in] = 0.0;
   子_3_do_si99[子_4_in] = 0.0;
   总_342_bo_3694_si99[子_4_in] = false;
   总_343_in_372C_si99[子_4_in] = 0;
   总_344_in_38EC_si99[子_4_in] = 0;
 }
 for (子_5_in = NativeHistoryTotal() ; 子_5_in >= 0 ; 子_5_in --)
 {
   if ( g_trade_view.Select(子_5_in,NATIVE_SELECT_BY_POSITION,NATIVE_HISTORY_POOL) != true || g_trade_view.Magic() != 总_93_in_1F0 )   continue;
   子_6_bo = true ;
   for (子_7_in = 0 ; 子_7_in < 总_378_in_5D80 ; 子_7_in ++)
   {
     if ( !(总_342_bo_3694_si99[子_7_in]) )
     {
       子_6_bo = false ;
     }
   }
   if ( ( g_trade_view.TimeClose() <  TimeCurrent() - 总_153_in_440 * 24 * 60 * 60 && 子_6_bo ) )   break;
   子_8_do = g_trade_view.Volume() * 100.0 ;
   if ( 总_151_in_438 == 1 )
   {
     子_8_do = 1.0 ;
   }
   子_9_in = 0 ;
   if ( 总_378_in_5D80 <= 0 )   continue;
   
   for ( ; 子_9_in < 总_378_in_5D80 ; 子_9_in ++)
   {
     if ( 总_347_st_4144_si99[子_9_in] != g_trade_view.SymbolName() )   continue;
     
     if ( ( g_trade_view.OrderType() != ORDER_TYPE_BUY && g_trade_view.OrderType() != ORDER_TYPE_SELL ) )   continue;
     临_lo_1 = g_trade_view.TimeClose();
     临_lo_2=TimeCurrent() - 总_153_in_440 * 24 * 60 * 60;
     if ( 临_lo_1 <  临_lo_2 )
     {
       临_lo_2 = g_trade_view.TimeClose();
       临_lo_3=TimeCurrent() - 总_153_in_440 * 24 * 60 * 60;
     if ( (临_lo_2 >= 临_lo_3 || 总_342_bo_3694_si99[子_9_in]) )   continue;
     }
     总_343_in_372C_si99[子_9_in] ++;
     if ( 总_343_in_372C_si99[子_9_in] >= 总_155_in_448 )
     {
       总_342_bo_3694_si99[子_9_in] = true;
     }
     子_2_do_si99[子_9_in] +=g_trade_view.Profit() / 子_8_do;
     子_2_do_si99[子_9_in] +=g_trade_view.Swap() / 子_8_do;
     子_2_do_si99[子_9_in] +=g_trade_view.Commission() / 子_8_do;
     临_lo_4 = g_trade_view.TimeClose();
     临_lo_5=TimeCurrent() - 总_154_in_444 * 24 * 60 * 60;
     if ( 临_lo_4 < 临_lo_5 )   continue;
     子_3_do_si99[子_9_in] +=g_trade_view.Profit() / 子_8_do;
     子_3_do_si99[子_9_in] +=g_trade_view.Swap() / 子_8_do;
     子_3_do_si99[子_9_in] +=g_trade_view.Commission() / 子_8_do;
     总_344_in_38EC_si99[子_9_in] ++;
     
   }
   
 }
 for (子_10_in = 0 ; 子_10_in < 总_378_in_5D80 ; 子_10_in ++)
 {
   总_349_do_46B4_si99[子_10_in] = 子_2_do_si99[子_10_in];
   if ( 总_343_in_372C_si99[子_10_in] >  0 )
   {
     总_345_do_3AAC_si99[子_10_in] = NormalizeDouble(子_2_do_si99[子_10_in] / 总_343_in_372C_si99[子_10_in],2);
   }
   else
   {
     总_345_do_3AAC_si99[子_10_in] = 0.0;
   }
   总_350_do_4A00_si99[子_10_in] = 子_3_do_si99[子_10_in];
   if ( 总_344_in_38EC_si99[子_10_in] >  0 )
   {
     总_346_do_3DF8_si99[子_10_in] = NormalizeDouble(子_3_do_si99[子_10_in] / 总_344_in_38EC_si99[子_10_in],2);
   }
   else
   {
     总_346_do_3DF8_si99[子_10_in] = 0.0;
   }
 }
 }
//lizong_32 <<==--------   --------
 void lizong_33()
 {
  int       子_1_in;
  double    子_2_do;
  int       子_3_in;
  int       子_4_in;
  int       子_5_in;
  int       子_6_in;
  bool      子_7_bo;
  int       子_8_in;
  int       子_9_in;
  int       子_10_in;
  int       子_11_in;
//----- -----

 lizong_32(); 
 for (子_1_in = 0 ; 子_1_in < 总_378_in_5D80 ; 子_1_in ++)
 {
   子_2_do = 总_349_do_46B4_si99[子_1_in] ;
   子_3_in = 1 ;
   for (子_4_in = 0 ; 子_4_in < 总_378_in_5D80 ; 子_4_in ++)
   {
     if ( 子_4_in == 子_1_in || !(总_349_do_46B4_si99[子_4_in]>子_2_do) )   continue;
     子_3_in ++;
     
   }
   总_356_in_5B14_si99[子_1_in] = 子_3_in;
 }
 for (子_5_in = 0 ; 子_5_in < 总_378_in_5D80 ; 子_5_in ++)
 {
   子_6_in = 总_356_in_5B14_si99[子_5_in] ;
   子_7_bo = true ;
   do
   {
     子_7_bo = false ;
     子_8_in = 0 ;
     if ( 总_378_in_5D80 <= 0 )   continue;
     
     for ( ; 子_8_in < 总_378_in_5D80 ; 子_8_in ++)
     {
       if ( 子_8_in == 子_5_in || 总_356_in_5B14_si99[子_8_in] != 总_356_in_5B14_si99[子_5_in] )   continue;
       总_356_in_5B14_si99[子_8_in] ++;
       子_7_bo = true ;
       
     }
     
   }
   while(子_7_bo);
   
 }
 for (子_9_in = 0 ; 子_9_in < 总_378_in_5D80 ; 子_9_in ++)
 {
   总_354_do_5730_si99[子_9_in] = 1.0;
 }
 for (子_10_in = 1 ; 子_10_in <= 总_378_in_5D80 ; 子_10_in ++)
 {
   for (子_11_in = 0 ; 子_11_in < 总_378_in_5D80 ; 子_11_in ++)
   {
     if ( 总_356_in_5B14_si99[子_11_in] == 子_10_in )
     {
       总_339_in_3184_si99[子_10_in - 1] = 子_11_in;
     }
   }
 }
 }
//lizong_33 <<==--------   --------
 void lizong_34()
 {
  int       子_1_in;
  double    子_2_do;
  int       子_3_in;
  int       子_4_in;
  int       子_5_in;
  int       子_6_in;
  bool      子_7_bo;
  int       子_8_in;
  int       子_9_in;
  int       子_10_in;
  int       子_11_in;
//----- -----

 lizong_32(); 
 for (子_1_in = 0 ; 子_1_in < 总_378_in_5D80 ; 子_1_in ++)
 {
   子_2_do = 总_345_do_3AAC_si99[子_1_in] ;
   子_3_in = 1 ;
   for (子_4_in = 0 ; 子_4_in < 总_378_in_5D80 ; 子_4_in ++)
   {
     if ( 子_4_in == 子_1_in || !(总_345_do_3AAC_si99[子_4_in]>子_2_do) )   continue;
     子_3_in ++;
     
   }
   总_356_in_5B14_si99[子_1_in] = 子_3_in;
 }
 for (子_5_in = 0 ; 子_5_in < 总_378_in_5D80 ; 子_5_in ++)
 {
   子_6_in = 总_356_in_5B14_si99[子_5_in] ;
   子_7_bo = true ;
   do
   {
     子_7_bo = false ;
     子_8_in = 0 ;
     if ( 总_378_in_5D80 <= 0 )   continue;
     
     for ( ; 子_8_in < 总_378_in_5D80 ; 子_8_in ++)
     {
       if ( 子_8_in == 子_5_in || 总_356_in_5B14_si99[子_8_in] != 总_356_in_5B14_si99[子_5_in] )   continue;
       总_356_in_5B14_si99[子_8_in] ++;
       子_7_bo = true ;
       
     }
     
   }
   while(子_7_bo);
   
 }
 for (子_9_in = 0 ; 子_9_in < 总_378_in_5D80 ; 子_9_in ++)
 {
   总_354_do_5730_si99[子_9_in] = 1.0;
 }
 for (子_10_in = 1 ; 子_10_in <= 总_378_in_5D80 ; 子_10_in ++)
 {
   for (子_11_in = 0 ; 子_11_in < 总_378_in_5D80 ; 子_11_in ++)
   {
     if ( 总_356_in_5B14_si99[子_11_in] == 子_10_in )
     {
       总_339_in_3184_si99[子_10_in - 1] = 子_11_in;
     }
   }
 }
 }
//lizong_34 <<==--------   --------
 double lizong_35( double 木_0_do)
 {
  double    子_2_do;
  string    子_3_st;
//----- -----

 子_2_do = 木_0_do ;
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "USD" || AccountInfoString(ACCOUNT_CURRENCY) == "usd" ) )
 {
   子_2_do = 木_0_do ;
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "EUR" || AccountInfoString(ACCOUNT_CURRENCY) == "eur" ) )
 {
   子_3_st="EURUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,NativeTimeframe(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do / iClose(子_3_st,NativeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "GBP" || AccountInfoString(ACCOUNT_CURRENCY) == "gbp" ) )
 {
   子_3_st="GBPUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,NativeTimeframe(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do / iClose(子_3_st,NativeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "AUD" || AccountInfoString(ACCOUNT_CURRENCY) == "aud" ) )
 {
   子_3_st="AUDUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,NativeTimeframe(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do / iClose(子_3_st,NativeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "JPY" || AccountInfoString(ACCOUNT_CURRENCY) == "jpy" || AccountInfoString(ACCOUNT_CURRENCY) == "YEN" || AccountInfoString(ACCOUNT_CURRENCY) == "yen" ) )
 {
   子_3_st="USDJPY" + 总_299_st_2850;
   if ( iClose(子_3_st,NativeTimeframe(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do * iClose(子_3_st,NativeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "CHF" || AccountInfoString(ACCOUNT_CURRENCY) == "chf" ) )
 {
   子_3_st="USDCHF" + 总_299_st_2850;
   if ( iClose(子_3_st,NativeTimeframe(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do * iClose(子_3_st,NativeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "HKD" || AccountInfoString(ACCOUNT_CURRENCY) == "hkd" ) )
 {
   子_3_st="USDHKD" + 总_299_st_2850;
   if ( iClose(子_3_st,NativeTimeframe(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do * iClose(子_3_st,NativeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "SGD" || AccountInfoString(ACCOUNT_CURRENCY) == "sgd" ) )
 {
   子_3_st="USDSGD" + 总_299_st_2850;
   if ( iClose(子_3_st,NativeTimeframe(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do * iClose(子_3_st,NativeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "RUB" || AccountInfoString(ACCOUNT_CURRENCY) == "rub" ) )
 {
   子_3_st="USDRUB" + 总_299_st_2850;
   if ( iClose(子_3_st,NativeTimeframe(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do * iClose(子_3_st,NativeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "BTC" || AccountInfoString(ACCOUNT_CURRENCY) == "btc" ) )
 {
   子_3_st="BTCUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,NativeTimeframe(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do / iClose(子_3_st,NativeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "ETH" || AccountInfoString(ACCOUNT_CURRENCY) == "eth" ) )
 {
   子_3_st="ETHUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,NativeTimeframe(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do / iClose(子_3_st,NativeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "BCH" || AccountInfoString(ACCOUNT_CURRENCY) == "bch" ) )
 {
   子_3_st="BCHUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,NativeTimeframe(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do / iClose(子_3_st,NativeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "BCC" || AccountInfoString(ACCOUNT_CURRENCY) == "bcc" ) )
 {
   子_3_st="BCCUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,NativeTimeframe(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do / iClose(子_3_st,NativeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "XRP" || AccountInfoString(ACCOUNT_CURRENCY) == "xrp" ) )
 {
   子_3_st="XRPUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,NativeTimeframe(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do / iClose(子_3_st,NativeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "LTC" || AccountInfoString(ACCOUNT_CURRENCY) == "ltc" ) )
 {
   子_3_st="LTCUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,NativeTimeframe(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do / iClose(子_3_st,NativeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "XMR" || AccountInfoString(ACCOUNT_CURRENCY) == "xmr" ) )
 {
   子_3_st="XMRUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,NativeTimeframe(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do / iClose(子_3_st,NativeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "DSH" || AccountInfoString(ACCOUNT_CURRENCY) == "dsh" ) )
 {
   子_3_st="DSHUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,NativeTimeframe(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do / iClose(子_3_st,NativeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "EOS" || AccountInfoString(ACCOUNT_CURRENCY) == "eos" ) )
 {
   子_3_st="EOSUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,NativeTimeframe(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do / iClose(子_3_st,NativeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "TRX" || AccountInfoString(ACCOUNT_CURRENCY) == "trx" ) )
 {
   子_3_st="TRXUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,NativeTimeframe(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do / iClose(子_3_st,NativeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "ADA" || AccountInfoString(ACCOUNT_CURRENCY) == "ada" ) )
 {
   子_3_st="ADAUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,NativeTimeframe(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do / iClose(子_3_st,NativeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "BSV" || AccountInfoString(ACCOUNT_CURRENCY) == "bsv" ) )
 {
   子_3_st="BSVUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,NativeTimeframe(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do / iClose(子_3_st,NativeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "XLM" || AccountInfoString(ACCOUNT_CURRENCY) == "xlm" ) )
 {
   子_3_st="XLMUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,NativeTimeframe(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do / iClose(子_3_st,NativeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "GLD" || AccountInfoString(ACCOUNT_CURRENCY) == "gld" ) )
 {
   子_3_st="GLDUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,NativeTimeframe(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do / iClose(子_3_st,NativeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "ZEC" || AccountInfoString(ACCOUNT_CURRENCY) == "zec" ) )
 {
   子_3_st="ZECUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,NativeTimeframe(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do / iClose(子_3_st,NativeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "XEM" || AccountInfoString(ACCOUNT_CURRENCY) == "xem" ) )
 {
   子_3_st="XEMUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,NativeTimeframe(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do / iClose(子_3_st,NativeTimeframe(PERIOD_D1),1) ;
   }
 }
 return(子_2_do); 
 }
//lizong_35 <<==--------   --------
 double lizong_36( double 木_0_do)
 {
  double    子_2_do;
  string    子_3_st;
//----- -----

 子_2_do = 木_0_do ;
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "USD" || AccountInfoString(ACCOUNT_CURRENCY) == "usd" ) )
 {
   子_2_do = 木_0_do ;
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "EUR" || AccountInfoString(ACCOUNT_CURRENCY) == "eur" ) )
 {
   子_3_st="EURUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,NativeTimeframe(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do * iClose(子_3_st,NativeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "GBP" || AccountInfoString(ACCOUNT_CURRENCY) == "gbp" ) )
 {
   子_3_st="GBPUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,NativeTimeframe(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do * iClose(子_3_st,NativeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "AUD" || AccountInfoString(ACCOUNT_CURRENCY) == "aud" ) )
 {
   子_3_st="AUDUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,NativeTimeframe(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do * iClose(子_3_st,NativeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "JPY" || AccountInfoString(ACCOUNT_CURRENCY) == "jpy" || AccountInfoString(ACCOUNT_CURRENCY) == "YEN" || AccountInfoString(ACCOUNT_CURRENCY) == "yen" ) )
 {
   子_3_st="USDJPY" + 总_299_st_2850;
   if ( iClose(子_3_st,NativeTimeframe(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do / iClose(子_3_st,NativeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "CHF" || AccountInfoString(ACCOUNT_CURRENCY) == "chf" ) )
 {
   子_3_st="USDCHF" + 总_299_st_2850;
   if ( iClose(子_3_st,NativeTimeframe(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do / iClose(子_3_st,NativeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "HKD" || AccountInfoString(ACCOUNT_CURRENCY) == "hkd" ) )
 {
   子_3_st="USDHKD" + 总_299_st_2850;
   if ( iClose(子_3_st,NativeTimeframe(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do / iClose(子_3_st,NativeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "RUB" || AccountInfoString(ACCOUNT_CURRENCY) == "rub" ) )
 {
   子_3_st="USDRUB" + 总_299_st_2850;
   if ( iClose(子_3_st,NativeTimeframe(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do / iClose(子_3_st,NativeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "CNH" || AccountInfoString(ACCOUNT_CURRENCY) == "cnh" ) )
 {
   子_3_st="USDCNH" + 总_299_st_2850;
   if ( iClose(子_3_st,NativeTimeframe(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do / iClose(子_3_st,NativeTimeframe(PERIOD_D1),1) ;
   }
   else
   {
     子_3_st="USDCNY" + 总_299_st_2850;
     if ( iClose(子_3_st,NativeTimeframe(PERIOD_D1),1)>0.0 )
     {
       子_2_do = 木_0_do / iClose(子_3_st,NativeTimeframe(PERIOD_D1),1) ;
     }
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "CNY" || AccountInfoString(ACCOUNT_CURRENCY) == "cny" ) )
 {
   子_3_st="USDCNH" + 总_299_st_2850;
   if ( iClose(子_3_st,NativeTimeframe(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do / iClose(子_3_st,NativeTimeframe(PERIOD_D1),1) ;
   }
   else
   {
     子_3_st="USDCNY" + 总_299_st_2850;
     if ( iClose(子_3_st,NativeTimeframe(PERIOD_D1),1)>0.0 )
     {
       子_2_do = 木_0_do / iClose(子_3_st,NativeTimeframe(PERIOD_D1),1) ;
     }
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "SGD" || AccountInfoString(ACCOUNT_CURRENCY) == "sgd" ) )
 {
   子_3_st="USDSGD" + 总_299_st_2850;
   if ( iClose(子_3_st,NativeTimeframe(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do / iClose(子_3_st,NativeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "BTC" || AccountInfoString(ACCOUNT_CURRENCY) == "btc" ) )
 {
   子_3_st="BTCUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,NativeTimeframe(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do * iClose(子_3_st,NativeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "ETH" || AccountInfoString(ACCOUNT_CURRENCY) == "eth" ) )
 {
   子_3_st="ETHUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,NativeTimeframe(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do * iClose(子_3_st,NativeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "BCH" || AccountInfoString(ACCOUNT_CURRENCY) == "bch" ) )
 {
   子_3_st="BCHUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,NativeTimeframe(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do * iClose(子_3_st,NativeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "BCC" || AccountInfoString(ACCOUNT_CURRENCY) == "bcc" ) )
 {
   子_3_st="BCCUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,NativeTimeframe(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do * iClose(子_3_st,NativeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "XRP" || AccountInfoString(ACCOUNT_CURRENCY) == "xrp" ) )
 {
   子_3_st="XRPUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,NativeTimeframe(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do * iClose(子_3_st,NativeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "LTC" || AccountInfoString(ACCOUNT_CURRENCY) == "ltc" ) )
 {
   子_3_st="LTCUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,NativeTimeframe(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do * iClose(子_3_st,NativeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "XMR" || AccountInfoString(ACCOUNT_CURRENCY) == "xmr" ) )
 {
   子_3_st="XMRUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,NativeTimeframe(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do * iClose(子_3_st,NativeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "DSH" || AccountInfoString(ACCOUNT_CURRENCY) == "dsh" ) )
 {
   子_3_st="DSHUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,NativeTimeframe(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do * iClose(子_3_st,NativeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "EOS" || AccountInfoString(ACCOUNT_CURRENCY) == "eos" ) )
 {
   子_3_st="EOSUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,NativeTimeframe(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do * iClose(子_3_st,NativeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "TRX" || AccountInfoString(ACCOUNT_CURRENCY) == "trx" ) )
 {
   子_3_st="TRXUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,NativeTimeframe(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do * iClose(子_3_st,NativeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "ADA" || AccountInfoString(ACCOUNT_CURRENCY) == "ada" ) )
 {
   子_3_st="ADAUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,NativeTimeframe(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do * iClose(子_3_st,NativeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "BSV" || AccountInfoString(ACCOUNT_CURRENCY) == "bsv" ) )
 {
   子_3_st="BSVUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,NativeTimeframe(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do * iClose(子_3_st,NativeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "XLM" || AccountInfoString(ACCOUNT_CURRENCY) == "xlm" ) )
 {
   子_3_st="XLMUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,NativeTimeframe(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do * iClose(子_3_st,NativeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "GLD" || AccountInfoString(ACCOUNT_CURRENCY) == "gld" ) )
 {
   子_3_st="GLDUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,NativeTimeframe(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do * iClose(子_3_st,NativeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "ZEC" || AccountInfoString(ACCOUNT_CURRENCY) == "zec" ) )
 {
   子_3_st="ZECUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,NativeTimeframe(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do * iClose(子_3_st,NativeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "XEM" || AccountInfoString(ACCOUNT_CURRENCY) == "xem" ) )
 {
   子_3_st="XEMUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,NativeTimeframe(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do * iClose(子_3_st,NativeTimeframe(PERIOD_D1),1) ;
   }
 }
 return(MathRound(子_2_do)); 
 }
//lizong_36 <<==--------   --------
 void lizong_37()
 {
 double     临_do_1;
 double     临_do_2;
 double     临_do_3;
 double     临_do_4;
 double     临_do_5;
 double     临_do_6;
 double     临_do_7;
 double     临_do_8;
 double     临_do_9;
 double     临_do_10;
 double     临_do_11;
 double     临_do_12;

 // Recovered from original MetaTester JIT dump: internal ATR readiness gate.
 总_3_in_10 = 16 ;
 总_4_in_14 = (int)PERIOD_D1 ;
 总_71_in_174 = (int)PERIOD_D1 ;
 总_72_in_178 = (int)PERIOD_M15 ;
 总_73_in_17C = 24 ;
 总_74_in_180 = 3 ;
 总_77_in_188 = 105 ;
 总_80_do_198 = 45.0 ;
 总_81_do_1A0 = 0.0 ;
 临_do_1 = AdjustEntry + -275.0;
 if ( Randomization>0.0 )
 {
   临_do_2 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_2 = 0.0;
 }
 总_83_do_1B0 = 临_do_1 + 临_do_2 ;
 临_do_2 = AdjustEntry + -160.0;
 if ( Randomization>0.0 )
 {
   临_do_3 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_3 = 0.0;
 }
 总_84_do_1B8 = 临_do_2 + 临_do_3 ;
 总_86_in_1C8 = 5 ;
 总_88_do_1D0 = 30.0 ;
 总_89_in_1D8 = 35 ;
 总_99_in_22C = 1 ;
 临_do_3 = AdjustSL + 6100.0;
 if ( Randomization>0.0 )
 {
   临_do_4 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_4 = 0.0;
 }
 总_100_do_230 = 临_do_3 + 临_do_4 ;
 临_do_4 = AdjustTP + 1450.0;
 if ( Randomization>0.0 )
 {
   临_do_5 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_5 = 0.0;
 }
 总_101_do_238 = 临_do_4 + 临_do_5 ;
 临_do_5 = AdjustTrailSL + 1800.0;
 if ( Randomization>0.0 )
 {
   临_do_6 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_6 = 0.0;
 }
 总_103_do_250 = 临_do_5 + 临_do_6 ;
 if ( Randomization>0.0 )
 {
   临_do_7 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_7 = 0.0;
 }
 总_104_do_258 = 临_do_7 + 1800.0 ;
 if ( Randomization>0.0 )
 {
   临_do_8 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_8 = 0.0;
 }
 总_105_do_260 = 临_do_8 + 5000.0 ;
 总_106_do_268 = 0.1 ;
 总_107_do_270 = 0.0 ;
 if ( Randomization>0.0 )
 {
   临_do_9 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_9 = 0.0;
 }
 总_109_do_280 = 临_do_9 + 1600.0 ;
 临_do_9 = AdjustTrailTP + 700.0;
 if ( Randomization>0.0 )
 {
   临_do_10 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_10 = 0.0;
 }
 总_108_do_278 = 临_do_9 + 临_do_10 ;
 if ( Randomization>0.0 )
 {
   临_do_11 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_11 = 0.0;
 }
 总_113_do_2A8 = 临_do_11 + 930.0 ;
 临_do_11 = AdjustBreakEven + 120.0;
 if ( Randomization>0.0 )
 {
   临_do_12 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_12 = 0.0;
 }
 总_114_do_2B0 = 临_do_11 + 临_do_12 ;
 总_117_in_2C8 = 60 ;
 总_118_in_2CC = 50 ;
 总_119_in_2D0 = 14 ;
 总_120_in_2D4 = 12 ;
 总_121_in_2D8 = 300 ;
 总_123_do_2E0 = 22.0 ;
 总_87_in_1CC = 5 ;
 if ( !(RemoveCommentSuffix) )
 {
   总_334_st_3120=ST1_Comment + "_XAUUSD_1";
 }
 总_93_in_1F0=ST1_MagicNumber + 1;
 总_397_do_6768 = lizong_35(145.0) ;
 if ( !(UseVariableValues) )   return;
 总_7_do_50 = 2000.0 ;
 总_397_do_6768 = lizong_35(60.0) ;
 }
//lizong_37 <<==--------   --------
 void lizong_38()
 {
 double     临_do_1;
 double     临_do_2;
 double     临_do_3;
 double     临_do_4;
 double     临_do_5;
 double     临_do_6;
 double     临_do_7;
 double     临_do_8;
 double     临_do_9;
 double     临_do_10;
 double     临_do_11;
 double     临_do_12;
 double     临_do_13;

 // Recovered from original MetaTester JIT dump: internal ATR readiness gate.
 总_3_in_10 = 16 ;
 总_4_in_14 = (int)PERIOD_D1 ;
 总_71_in_174 = (int)PERIOD_H4 ;
 总_72_in_178 = (int)PERIOD_H1 ;
 总_73_in_17C = 12 ;
 总_74_in_180 = 8 ;
 总_77_in_188 = 90 ;
 总_80_do_198 = 1050.0 ;
 总_81_do_1A0 = 0.0 ;
 临_do_1 = AdjustEntry + -40.0;
 if ( Randomization>0.0 )
 {
   临_do_2 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_2 = 0.0;
 }
 总_83_do_1B0 = 临_do_1 + 临_do_2 ;
 临_do_2 = AdjustEntry + -100.0;
 if ( Randomization>0.0 )
 {
   临_do_3 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_3 = 0.0;
 }
 总_84_do_1B8 = 临_do_2 + 临_do_3 ;
 总_86_in_1C8 = 2 ;
 总_88_do_1D0 = 130.0 ;
 总_89_in_1D8 = 192 ;
 总_99_in_22C = 5 ;
 if ( !(UseHL_TrailingSL) )
 {
   临_do_3 = AdjustSL + 700.0;
   if ( Randomization>0.0 )
   {
     临_do_4 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
   }
   else
   {
     临_do_4 = 0.0;
   }
   总_100_do_230 = 临_do_3 + 临_do_4 ;
 }
 else
 {
   临_do_4 = AdjustSL + 800.0;
   if ( Randomization>0.0 )
   {
     临_do_5 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
   }
   else
   {
     临_do_5 = 0.0;
   }
   总_100_do_230 = 临_do_4 + 临_do_5 ;
 }
 临_do_5 = AdjustTP + 4900.0;
 if ( Randomization>0.0 )
 {
   临_do_6 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_6 = 0.0;
 }
 总_101_do_238 = 临_do_5 + 临_do_6 ;
 临_do_6 = AdjustTrailSL + 1300.0;
 if ( Randomization>0.0 )
 {
   临_do_7 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_7 = 0.0;
 }
 总_103_do_250 = 临_do_6 + 临_do_7 ;
 if ( Randomization>0.0 )
 {
   临_do_8 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_8 = 0.0;
 }
 总_104_do_258 = 临_do_8 + 1450.0 ;
 if ( Randomization>0.0 )
 {
   临_do_9 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_9 = 0.0;
 }
 总_105_do_260 = 临_do_9 + 2000.0 ;
 总_106_do_268 = 0.1 ;
 总_107_do_270 = 0.0 ;
 if ( Randomization>0.0 )
 {
   临_do_10 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_10 = 0.0;
 }
 总_109_do_280 = 临_do_10 + 1400.0 ;
 临_do_10 = AdjustTrailTP + 200.0;
 if ( Randomization>0.0 )
 {
   临_do_11 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_11 = 0.0;
 }
 总_108_do_278 = 临_do_10 + 临_do_11 ;
 if ( Randomization>0.0 )
 {
   临_do_12 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_12 = 0.0;
 }
 总_113_do_2A8 = 临_do_12 + 500.0 ;
 临_do_12 = AdjustBreakEven + 200.0;
 if ( Randomization>0.0 )
 {
   临_do_13 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_13 = 0.0;
 }
 总_114_do_2B0 = 临_do_12 + 临_do_13 ;
 总_117_in_2C8 = 60 ;
 总_118_in_2CC = 50 ;
 总_119_in_2D0 = 14 ;
 总_120_in_2D4 = 6 ;
 总_121_in_2D8 = 400 ;
 总_123_do_2E0 = 32.0 ;
 总_87_in_1CC = 99 ;
 if ( !(RemoveCommentSuffix) )
 {
   总_334_st_3120=ST1_Comment + "_XAUUSD_4";
 }
 总_93_in_1F0=ST1_MagicNumber + 2;
 总_397_do_6768 = lizong_35(57.0) ;
 if ( !(UseVariableValues) )   return;
 总_7_do_50 = 1600.0 ;
 总_397_do_6768 = lizong_35(52.0) ;
 }
//lizong_38 <<==--------   --------
 void lizong_39()
 {
 double     临_do_1;
 double     临_do_2;
 double     临_do_3;
 double     临_do_4;
 double     临_do_5;
 double     临_do_6;
 double     临_do_7;
 double     临_do_8;
 double     临_do_9;
 double     临_do_10;
 double     临_do_11;
 double     临_do_12;

 // Recovered from original MetaTester JIT dump: internal ATR readiness gate.
 总_3_in_10 = 41 ;
 总_4_in_14 = (int)PERIOD_D1 ;
 总_71_in_174 = (int)PERIOD_D1 ;
 总_72_in_178 = (int)PERIOD_H1 ;
 总_73_in_17C = 15 ;
 总_74_in_180 = 3 ;
 总_77_in_188 = 230 ;
 总_80_do_198 = 550.0 ;
 总_81_do_1A0 = 0.0 ;
 临_do_1 = AdjustEntry + -170.0;
 if ( Randomization>0.0 )
 {
   临_do_2 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_2 = 0.0;
 }
 总_83_do_1B0 = 临_do_1 + 临_do_2 ;
 临_do_2 = AdjustEntry + -70.0;
 if ( Randomization>0.0 )
 {
   临_do_3 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_3 = 0.0;
 }
 总_84_do_1B8 = 临_do_2 + 临_do_3 ;
 总_86_in_1C8 = 1 ;
 总_88_do_1D0 = 480.0 ;
 总_89_in_1D8 = 480 ;
 总_99_in_22C = 1 ;
 临_do_3 = AdjustSL + 1000.0;
 if ( Randomization>0.0 )
 {
   临_do_4 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_4 = 0.0;
 }
 总_100_do_230 = 临_do_3 + 临_do_4 ;
 临_do_4 = AdjustTP + 4100.0;
 if ( Randomization>0.0 )
 {
   临_do_5 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_5 = 0.0;
 }
 总_101_do_238 = 临_do_4 + 临_do_5 ;
 临_do_5 = AdjustTrailSL + 450.0;
 if ( Randomization>0.0 )
 {
   临_do_6 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_6 = 0.0;
 }
 总_103_do_250 = 临_do_5 + 临_do_6 ;
 if ( Randomization>0.0 )
 {
   临_do_7 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_7 = 0.0;
 }
 总_104_do_258 = 临_do_7 + 1400.0 ;
 if ( Randomization>0.0 )
 {
   临_do_8 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_8 = 0.0;
 }
 总_105_do_260 = 临_do_8 + 5000.0 ;
 总_106_do_268 = 0.1 ;
 总_107_do_270 = 0.0 ;
 if ( Randomization>0.0 )
 {
   临_do_9 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_9 = 0.0;
 }
 总_109_do_280 = 临_do_9 + 1600.0 ;
 临_do_9 = AdjustTrailTP + 400.0;
 if ( Randomization>0.0 )
 {
   临_do_10 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_10 = 0.0;
 }
 总_108_do_278 = 临_do_9 + 临_do_10 ;
 if ( Randomization>0.0 )
 {
   临_do_11 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_11 = 0.0;
 }
 总_113_do_2A8 = 临_do_11 + 500.0 ;
 临_do_11 = AdjustBreakEven + 100.0;
 if ( Randomization>0.0 )
 {
   临_do_12 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_12 = 0.0;
 }
 总_114_do_2B0 = 临_do_11 + 临_do_12 ;
 总_117_in_2C8 = 60 ;
 总_118_in_2CC = 50 ;
 总_119_in_2D0 = 1 ;
 总_120_in_2D4 = 5 ;
 总_121_in_2D8 = 700 ;
 总_123_do_2E0 = 22.0 ;
 总_87_in_1CC = 99 ;
 if ( !(RemoveCommentSuffix) )
 {
   总_334_st_3120=ST1_Comment + "_XAUUSD_2";
 }
 总_93_in_1F0=ST1_MagicNumber + 5;
 总_397_do_6768 = lizong_35(30.0) ;
 if ( !(UseVariableValues) )   return;
 总_7_do_50 = 2000.0 ;
 总_397_do_6768 = lizong_35(30.0) ;
 }
//lizong_39 <<==--------   --------
 void lizong_40()
 {
 double     临_do_1;
 double     临_do_2;
 double     临_do_3;
 double     临_do_4;
 double     临_do_5;
 double     临_do_6;
 double     临_do_7;
 double     临_do_8;
 double     临_do_9;
 double     临_do_10;
 double     临_do_11;
 double     临_do_12;
 double     临_do_13;

 // Recovered from original MetaTester JIT dump: internal ATR readiness gate.
 总_3_in_10 = 5 ;
 总_4_in_14 = (int)PERIOD_D1 ;
 总_71_in_174 = (int)PERIOD_D1 ;
 总_72_in_178 = (int)PERIOD_H1 ;
 总_73_in_17C = 7 ;
 总_74_in_180 = 2 ;
 总_77_in_188 = 20 ;
 总_80_do_198 = 250.0 ;
 总_81_do_1A0 = 0.0 ;
 临_do_1 = AdjustEntry + -130.0;
 if ( Randomization>0.0 )
 {
   临_do_2 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_2 = 0.0;
 }
 总_83_do_1B0 = 临_do_1 + 临_do_2 ;
 临_do_2 = AdjustEntry + -120.0;
 if ( Randomization>0.0 )
 {
   临_do_3 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_3 = 0.0;
 }
 总_84_do_1B8 = 临_do_2 + 临_do_3 ;
 总_86_in_1C8 = 1 ;
 总_88_do_1D0 = 980.0 ;
 总_89_in_1D8 = 432 ;
 总_99_in_22C = 1 ;
 if ( !(UseHL_TrailingSL) )
 {
   临_do_3 = AdjustSL + 600.0;
   if ( Randomization>0.0 )
   {
     临_do_4 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
   }
   else
   {
     临_do_4 = 0.0;
   }
   总_100_do_230 = 临_do_3 + 临_do_4 ;
 }
 else
 {
   临_do_4 = AdjustSL + 700.0;
   if ( Randomization>0.0 )
   {
     临_do_5 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
   }
   else
   {
     临_do_5 = 0.0;
   }
   总_100_do_230 = 临_do_4 + 临_do_5 ;
 }
 临_do_5 = AdjustTP + 3300.0;
 if ( Randomization>0.0 )
 {
   临_do_6 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_6 = 0.0;
 }
 总_101_do_238 = 临_do_5 + 临_do_6 ;
 临_do_6 = AdjustTrailSL + 500.0;
 if ( Randomization>0.0 )
 {
   临_do_7 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_7 = 0.0;
 }
 总_103_do_250 = 临_do_6 + 临_do_7 ;
 if ( Randomization>0.0 )
 {
   临_do_8 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_8 = 0.0;
 }
 总_104_do_258 = 临_do_8 + 400.0 ;
 if ( Randomization>0.0 )
 {
   临_do_9 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_9 = 0.0;
 }
 总_105_do_260 = 临_do_9 + 5000.0 ;
 if ( Randomization>0.0 )
 {
   临_do_10 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_10 = 0.0;
 }
 总_109_do_280 = 临_do_10 + 1000.0 ;
 临_do_10 = AdjustTrailTP + 2000.0;
 if ( Randomization>0.0 )
 {
   临_do_11 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_11 = 0.0;
 }
 总_108_do_278 = 临_do_10 + 临_do_11 ;
 总_106_do_268 = 0.1 ;
 总_107_do_270 = 0.0 ;
 if ( Randomization>0.0 )
 {
   临_do_12 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_12 = 0.0;
 }
 总_113_do_2A8 = 临_do_12 + 400.0 ;
 临_do_12 = AdjustBreakEven;
 if ( Randomization>0.0 )
 {
   临_do_13 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_13 = 0.0;
 }
 总_114_do_2B0 = 临_do_12 + 临_do_13 ;
 总_117_in_2C8 = 60 ;
 总_118_in_2CC = 50 ;
 总_119_in_2D0 = 7 ;
 总_120_in_2D4 = 4 ;
 总_121_in_2D8 = 100 ;
 总_123_do_2E0 = 0.0 ;
 总_87_in_1CC = 99 ;
 if ( !(RemoveCommentSuffix) )
 {
   总_334_st_3120=ST1_Comment + "_XAUUSD_3";
 }
 总_93_in_1F0=ST1_MagicNumber + 8;
 总_397_do_6768 = lizong_35(32.0) ;
 if ( !(UseVariableValues) )   return;
 总_7_do_50 = 2000.0 ;
 总_397_do_6768 = lizong_35(35.0) ;
 }
//lizong_40 <<==--------   --------
 void lizong_41()
 {
 double     临_do_1;
 double     临_do_2;
 double     临_do_3;
 double     临_do_4;
 double     临_do_5;
 double     临_do_6;
 double     临_do_7;
 double     临_do_8;
 double     临_do_9;
 double     临_do_10;
 double     临_do_11;
 double     临_do_12;

 // Recovered from original MetaTester JIT dump: internal ATR readiness gate.
 总_3_in_10 = 20 ;
 总_4_in_14 = (int)PERIOD_D1 ;
 总_71_in_174 = (int)PERIOD_H1 ;
 总_72_in_178 = (int)PERIOD_M5 ;
 总_73_in_17C = 26 ;
 总_74_in_180 = 24 ;
 总_77_in_188 = 140 ;
 总_80_do_198 = 120.0 ;
 总_81_do_1A0 = 0.0 ;
 临_do_1 = AdjustEntry + -115.0;
 if ( Randomization>0.0 )
 {
   临_do_2 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_2 = 0.0;
 }
 总_83_do_1B0 = 临_do_1 + 临_do_2 ;
 临_do_2 = AdjustEntry + -145.0;
 if ( Randomization>0.0 )
 {
   临_do_3 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_3 = 0.0;
 }
 总_84_do_1B8 = 临_do_2 + 临_do_3 ;
 总_86_in_1C8 = 5 ;
 总_88_do_1D0 = 55.0 ;
 总_89_in_1D8 = 20 ;
 总_99_in_22C = 1 ;
 临_do_3 = AdjustSL + 10100.0;
 if ( Randomization>0.0 )
 {
   临_do_4 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_4 = 0.0;
 }
 总_100_do_230 = 临_do_3 + 临_do_4 ;
 临_do_4 = AdjustTP + 800.0;
 if ( Randomization>0.0 )
 {
   临_do_5 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_5 = 0.0;
 }
 总_101_do_238 = 临_do_4 + 临_do_5 ;
 临_do_5 = AdjustTrailSL + 500.0;
 if ( Randomization>0.0 )
 {
   临_do_6 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_6 = 0.0;
 }
 总_103_do_250 = 临_do_5 + 临_do_6 ;
 if ( Randomization>0.0 )
 {
   临_do_7 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_7 = 0.0;
 }
 总_104_do_258 = 临_do_7 + 1200.0 ;
 if ( Randomization>0.0 )
 {
   临_do_8 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_8 = 0.0;
 }
 总_105_do_260 = 临_do_8 + 5000.0 ;
 总_106_do_268 = 0.1 ;
 总_107_do_270 = 0.0 ;
 if ( Randomization>0.0 )
 {
   临_do_9 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_9 = 0.0;
 }
 总_109_do_280 = 临_do_9 + 1950.0 ;
 临_do_9 = AdjustTrailTP + 350.0;
 if ( Randomization>0.0 )
 {
   临_do_10 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_10 = 0.0;
 }
 总_108_do_278 = 临_do_9 + 临_do_10 ;
 if ( Randomization>0.0 )
 {
   临_do_11 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_11 = 0.0;
 }
 总_113_do_2A8 = 临_do_11 + 330.0 ;
 临_do_11 = AdjustBreakEven + 80.0;
 if ( Randomization>0.0 )
 {
   临_do_12 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_12 = 0.0;
 }
 总_114_do_2B0 = 临_do_11 + 临_do_12 ;
 总_117_in_2C8 = 60 ;
 总_118_in_2CC = 50 ;
 总_119_in_2D0 = 0 ;
 总_120_in_2D4 = 0 ;
 总_121_in_2D8 = 100 ;
 总_123_do_2E0 = 0.0 ;
 总_87_in_1CC = 5 ;
 if ( !(RemoveCommentSuffix) )
 {
   总_334_st_3120=ST1_Comment + "_XAUUSD_6";
 }
 总_93_in_1F0=ST1_MagicNumber + 9;
 总_397_do_6768 = lizong_35(348.0) ;
 if ( !(UseVariableValues) )   return;
 总_7_do_50 = 2400.0 ;
 总_397_do_6768 = lizong_35(140.0) ;
 }
//lizong_41 <<==--------   --------
 void lizong_42()
 {
 double     临_do_1;
 double     临_do_2;
 double     临_do_3;
 double     临_do_4;
 double     临_do_5;
 double     临_do_6;
 double     临_do_7;
 double     临_do_8;
 double     临_do_9;
 double     临_do_10;
 double     临_do_11;
 double     临_do_12;

 // Recovered from original MetaTester JIT dump: internal ATR readiness gate.
 总_3_in_10 = 24 ;
 总_4_in_14 = (int)PERIOD_D1 ;
 总_71_in_174 = (int)PERIOD_H1 ;
 总_72_in_178 = (int)PERIOD_M15 ;
 总_73_in_17C = 30 ;
 总_74_in_180 = 19 ;
 总_77_in_188 = 110 ;
 总_80_do_198 = 160.0 ;
 总_81_do_1A0 = 0.0 ;
 临_do_1 = AdjustEntry + -120.0;
 if ( Randomization>0.0 )
 {
   临_do_2 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_2 = 0.0;
 }
 总_83_do_1B0 = 临_do_1 + 临_do_2 ;
 临_do_2 = AdjustEntry + -110.0;
 if ( Randomization>0.0 )
 {
   临_do_3 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_3 = 0.0;
 }
 总_84_do_1B8 = 临_do_2 + 临_do_3 ;
 总_86_in_1C8 = 3 ;
 总_88_do_1D0 = 55.0 ;
 总_89_in_1D8 = 30 ;
 总_99_in_22C = 1 ;
 临_do_3 = AdjustSL + 5300.0;
 if ( Randomization>0.0 )
 {
   临_do_4 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_4 = 0.0;
 }
 总_100_do_230 = 临_do_3 + 临_do_4 ;
 临_do_4 = AdjustTP + 900.0;
 if ( Randomization>0.0 )
 {
   临_do_5 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_5 = 0.0;
 }
 总_101_do_238 = 临_do_4 + 临_do_5 ;
 临_do_5 = AdjustTrailSL + 495.0;
 if ( Randomization>0.0 )
 {
   临_do_6 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_6 = 0.0;
 }
 总_103_do_250 = 临_do_5 + 临_do_6 ;
 if ( Randomization>0.0 )
 {
   临_do_7 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_7 = 0.0;
 }
 总_104_do_258 = 临_do_7 + 400.0 ;
 if ( Randomization>0.0 )
 {
   临_do_8 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_8 = 0.0;
 }
 总_105_do_260 = 临_do_8 + 5000.0 ;
 总_106_do_268 = 0.1 ;
 总_107_do_270 = 0.0 ;
 if ( Randomization>0.0 )
 {
   临_do_9 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_9 = 0.0;
 }
 总_109_do_280 = 临_do_9 + 1900.0 ;
 临_do_9 = AdjustTrailTP + 250.0;
 if ( Randomization>0.0 )
 {
   临_do_10 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_10 = 0.0;
 }
 总_108_do_278 = 临_do_9 + 临_do_10 ;
 if ( Randomization>0.0 )
 {
   临_do_11 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_11 = 0.0;
 }
 总_113_do_2A8 = 临_do_11 + 260.0 ;
 临_do_11 = AdjustBreakEven + 80.0;
 if ( Randomization>0.0 )
 {
   临_do_12 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_12 = 0.0;
 }
 总_114_do_2B0 = 临_do_11 + 临_do_12 ;
 总_117_in_2C8 = 60 ;
 总_118_in_2CC = 50 ;
 总_119_in_2D0 = 0 ;
 总_120_in_2D4 = 0 ;
 总_121_in_2D8 = 100 ;
 总_123_do_2E0 = 0.0 ;
 总_87_in_1CC = 99 ;
 if ( !(RemoveCommentSuffix) )
 {
   总_334_st_3120=ST1_Comment + "_XAUUSD_5";
 }
 总_93_in_1F0=ST1_MagicNumber + 12;
 总_397_do_6768 = lizong_35(281.0) ;
 if ( !(UseVariableValues) )   return;
 总_7_do_50 = 2600.0 ;
 总_397_do_6768 = lizong_35(110.0) ;
 }
//lizong_42 <<==--------   --------
 void lizong_43()
 {
 double     临_do_1;
 double     临_do_2;
 double     临_do_3;
 double     临_do_4;
 double     临_do_5;
 double     临_do_6;
 double     临_do_7;
 double     临_do_8;
 double     临_do_9;
 double     临_do_10;
 double     临_do_11;
 double     临_do_12;

 // Recovered from original MetaTester JIT dump: internal ATR readiness gate.
 总_3_in_10 = 12 ;
 总_4_in_14 = (int)PERIOD_D1 ;
 总_71_in_174 = (int)PERIOD_H1 ;
 总_72_in_178 = (int)PERIOD_M15 ;
 总_73_in_17C = 7 ;
 总_74_in_180 = 5 ;
 总_77_in_188 = 200 ;
 总_80_do_198 = 40.0 ;
 总_81_do_1A0 = 0.0 ;
 临_do_1 = AdjustEntry + -150.0;
 if ( Randomization>0.0 )
 {
   临_do_2 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_2 = 0.0;
 }
 总_83_do_1B0 = 临_do_1 + 临_do_2 ;
 临_do_2 = AdjustEntry + -145.0;
 if ( Randomization>0.0 )
 {
   临_do_3 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_3 = 0.0;
 }
 总_84_do_1B8 = 临_do_2 + 临_do_3 ;
 总_86_in_1C8 = 3 ;
 总_88_do_1D0 = 5.0 ;
 总_89_in_1D8 = 15 ;
 总_99_in_22C = 1 ;
 临_do_3 = AdjustSL + 3900.0;
 if ( Randomization>0.0 )
 {
   临_do_4 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_4 = 0.0;
 }
 总_100_do_230 = 临_do_3 + 临_do_4 ;
 临_do_4 = AdjustTP + 1350.0;
 if ( Randomization>0.0 )
 {
   临_do_5 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_5 = 0.0;
 }
 总_101_do_238 = 临_do_4 + 临_do_5 ;
 临_do_5 = AdjustTrailSL + 445.0;
 if ( Randomization>0.0 )
 {
   临_do_6 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_6 = 0.0;
 }
 总_103_do_250 = 临_do_5 + 临_do_6 ;
 if ( Randomization>0.0 )
 {
   临_do_7 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_7 = 0.0;
 }
 总_104_do_258 = 临_do_7 + 355.0 ;
 if ( Randomization>0.0 )
 {
   临_do_8 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_8 = 0.0;
 }
 总_105_do_260 = 临_do_8 + 5000.0 ;
 总_106_do_268 = 0.1 ;
 总_107_do_270 = 0.0 ;
 if ( Randomization>0.0 )
 {
   临_do_9 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_9 = 0.0;
 }
 总_109_do_280 = 临_do_9 + 1850.0 ;
 临_do_9 = AdjustTrailTP + 250.0;
 if ( Randomization>0.0 )
 {
   临_do_10 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_10 = 0.0;
 }
 总_108_do_278 = 临_do_9 + 临_do_10 ;
 if ( Randomization>0.0 )
 {
   临_do_11 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_11 = 0.0;
 }
 总_113_do_2A8 = 临_do_11 + 160.0 ;
 临_do_11 = AdjustBreakEven + 50.0;
 if ( Randomization>0.0 )
 {
   临_do_12 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_12 = 0.0;
 }
 总_114_do_2B0 = 临_do_11 + 临_do_12 ;
 总_117_in_2C8 = 60 ;
 总_118_in_2CC = 50 ;
 总_119_in_2D0 = 1 ;
 总_120_in_2D4 = 9 ;
 总_121_in_2D8 = 1500 ;
 总_123_do_2E0 = 46.0 ;
 总_87_in_1CC = 99 ;
 if ( !(RemoveCommentSuffix) )
 {
   总_334_st_3120=ST1_Comment + "_XAUUSD_9";
 }
 总_93_in_1F0=ST1_MagicNumber + 13;
 总_397_do_6768 = lizong_35(968.0) ;
 if ( !(UseVariableValues) )   return;
 总_7_do_50 = 1900.0 ;
 总_397_do_6768 = lizong_35(700.0) ;
 }
//lizong_43 <<==--------   --------
 void lizong_44()
 {
 double     临_do_1;
 double     临_do_2;
 double     临_do_3;
 double     临_do_4;
 double     临_do_5;
 double     临_do_6;
 double     临_do_7;
 double     临_do_8;
 double     临_do_9;
 double     临_do_10;
 double     临_do_11;
 double     临_do_12;

 // Recovered from original MetaTester JIT dump: internal ATR readiness gate.
 总_3_in_10 = 28 ;
 总_4_in_14 = (int)PERIOD_H1 ;
 总_71_in_174 = (int)PERIOD_H1 ;
 总_72_in_178 = (int)PERIOD_M15 ;
 总_73_in_17C = 25 ;
 总_74_in_180 = 23 ;
 总_77_in_188 = 145 ;
 总_80_do_198 = 10.0 ;
 总_81_do_1A0 = 0.0 ;
 临_do_1 = AdjustEntry + -10.0;
 if ( Randomization>0.0 )
 {
   临_do_2 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_2 = 0.0;
 }
 总_83_do_1B0 = 临_do_1 + 临_do_2 ;
 临_do_2 = AdjustEntry + -145.0;
 if ( Randomization>0.0 )
 {
   临_do_3 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_3 = 0.0;
 }
 总_84_do_1B8 = 临_do_2 + 临_do_3 ;
 总_86_in_1C8 = 5 ;
 总_88_do_1D0 = 90.0 ;
 总_89_in_1D8 = 60 ;
 总_99_in_22C = 1 ;
 临_do_3 = AdjustSL + 2250.0;
 if ( Randomization>0.0 )
 {
   临_do_4 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_4 = 0.0;
 }
 总_100_do_230 = 临_do_3 + 临_do_4 ;
 临_do_4 = AdjustTP + 1450.0;
 if ( Randomization>0.0 )
 {
   临_do_5 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_5 = 0.0;
 }
 总_101_do_238 = 临_do_4 + 临_do_5 ;
 临_do_5 = AdjustTrailSL + 450.0;
 if ( Randomization>0.0 )
 {
   临_do_6 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_6 = 0.0;
 }
 总_103_do_250 = 临_do_5 + 临_do_6 ;
 if ( Randomization>0.0 )
 {
   临_do_7 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_7 = 0.0;
 }
 总_104_do_258 = 临_do_7 + 900.0 ;
 if ( Randomization>0.0 )
 {
   临_do_8 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_8 = 0.0;
 }
 总_105_do_260 = 临_do_8 + 5000.0 ;
 总_106_do_268 = 0.1 ;
 总_107_do_270 = 0.0 ;
 if ( Randomization>0.0 )
 {
   临_do_9 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_9 = 0.0;
 }
 总_109_do_280 = 临_do_9 + 2800.0 ;
 临_do_9 = AdjustTrailTP + 350.0;
 if ( Randomization>0.0 )
 {
   临_do_10 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_10 = 0.0;
 }
 总_108_do_278 = 临_do_9 + 临_do_10 ;
 if ( Randomization>0.0 )
 {
   临_do_11 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_11 = 0.0;
 }
 总_113_do_2A8 = 临_do_11 + 340.0 ;
 临_do_11 = AdjustBreakEven + 30.0;
 if ( Randomization>0.0 )
 {
   临_do_12 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_12 = 0.0;
 }
 总_114_do_2B0 = 临_do_11 + 临_do_12 ;
 总_117_in_2C8 = 60 ;
 总_118_in_2CC = 50 ;
 总_119_in_2D0 = 12 ;
 总_120_in_2D4 = 17 ;
 总_121_in_2D8 = 1000 ;
 总_123_do_2E0 = 45.0 ;
 总_87_in_1CC = 5 ;
 if ( !(RemoveCommentSuffix) )
 {
   总_334_st_3120=ST1_Comment + "_XAUUSD_7";
 }
 总_93_in_1F0=ST1_MagicNumber + 14;
 总_397_do_6768 = lizong_35(149.0) ;
 if ( !(UseVariableValues) )   return;
 总_7_do_50 = 2600.0 ;
 总_397_do_6768 = lizong_35(90.0) ;
 }
//lizong_44 <<==--------   --------
 void lizong_45()
 {
 double     临_do_1;
 double     临_do_2;
 double     临_do_3;
 double     临_do_4;
 double     临_do_5;
 double     临_do_6;
 double     临_do_7;
 double     临_do_8;
 double     临_do_9;
 double     临_do_10;
 double     临_do_11;
 double     临_do_12;

 // Recovered from original MetaTester JIT dump: internal ATR readiness gate.
 总_3_in_10 = 11 ;
 总_4_in_14 = (int)PERIOD_D1 ;
 总_71_in_174 = (int)PERIOD_H1 ;
 总_72_in_178 = (int)PERIOD_M15 ;
 总_73_in_17C = 26 ;
 总_74_in_180 = 20 ;
 总_77_in_188 = 235 ;
 总_80_do_198 = 80.0 ;
 总_81_do_1A0 = 0.0 ;
 临_do_1 = AdjustEntry + -140.0;
 if ( Randomization>0.0 )
 {
   临_do_2 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_2 = 0.0;
 }
 总_83_do_1B0 = 临_do_1 + 临_do_2 ;
 临_do_2 = AdjustEntry + -170.0;
 if ( Randomization>0.0 )
 {
   临_do_3 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_3 = 0.0;
 }
 总_84_do_1B8 = 临_do_2 + 临_do_3 ;
 总_86_in_1C8 = 5 ;
 总_88_do_1D0 = 5.0 ;
 总_89_in_1D8 = 55 ;
 总_99_in_22C = 1 ;
 临_do_3 = AdjustSL + 1900.0;
 if ( Randomization>0.0 )
 {
   临_do_4 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_4 = 0.0;
 }
 总_100_do_230 = 临_do_3 + 临_do_4 ;
 临_do_4 = AdjustTP + 1200.0;
 if ( Randomization>0.0 )
 {
   临_do_5 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_5 = 0.0;
 }
 总_101_do_238 = 临_do_4 + 临_do_5 ;
 临_do_5 = AdjustTrailSL + 1250.0;
 if ( Randomization>0.0 )
 {
   临_do_6 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_6 = 0.0;
 }
 总_103_do_250 = 临_do_5 + 临_do_6 ;
 if ( Randomization>0.0 )
 {
   临_do_7 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_7 = 0.0;
 }
 总_104_do_258 = 临_do_7 + 650.0 ;
 if ( Randomization>0.0 )
 {
   临_do_8 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_8 = 0.0;
 }
 总_105_do_260 = 临_do_8 + 5000.0 ;
 总_106_do_268 = 0.1 ;
 总_107_do_270 = 0.0 ;
 if ( Randomization>0.0 )
 {
   临_do_9 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_9 = 0.0;
 }
 总_109_do_280 = 临_do_9 + 1950.0 ;
 临_do_9 = AdjustTrailTP + 250.0;
 if ( Randomization>0.0 )
 {
   临_do_10 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_10 = 0.0;
 }
 总_108_do_278 = 临_do_9 + 临_do_10 ;
 if ( Randomization>0.0 )
 {
   临_do_11 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_11 = 0.0;
 }
 总_113_do_2A8 = 临_do_11 + 270.0 ;
 临_do_11 = AdjustBreakEven;
 if ( Randomization>0.0 )
 {
   临_do_12 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   临_do_12 = 0.0;
 }
 总_114_do_2B0 = 临_do_11 + 临_do_12 ;
 总_117_in_2C8 = 60 ;
 总_118_in_2CC = 50 ;
 总_119_in_2D0 = 15 ;
 总_120_in_2D4 = 3 ;
 总_121_in_2D8 = 1200 ;
 总_123_do_2E0 = 16.0 ;
 总_87_in_1CC = 20 ;
 if ( !(RemoveCommentSuffix) )
 {
   总_334_st_3120=ST1_Comment + "_XAUUSD_8";
 }
 总_93_in_1F0=ST1_MagicNumber + 15;
 总_397_do_6768 = lizong_35(276.0) ;
 if ( !(UseVariableValues) )   return;
 总_7_do_50 = 2800.0 ;
 总_397_do_6768 = lizong_35(130.0) ;
 }
//lizong_45 <<==--------   --------
 void lizong_46()
 {
  double    子_1_do;
  int       子_2_in;
  double    子_3_do;
  double    子_4_do;
  double    子_5_do;
//----- -----
 double     临_do_1;
 long       临_lo_2;
 int        临_in_3;
 int        临_in_4;
 int        临_in_5;
 int        临_in_6;
 int        临_in_7;
 int        临_in_8;
 int        临_in_9;
 int        临_in_10;
 int        临_in_11;
 int        临_in_12;
 int        临_in_13;
 int        临_in_14;
 int        临_in_15;
 int        临_in_16;
 int        临_in_17;
 int        临_in_18;
 int        临_in_19;

 临_do_1 = AccountInfoDouble(ACCOUNT_EQUITY);
 if ( 临_do_1==AccountInfoDouble(ACCOUNT_BALANCE) )   return;
 子_1_do = 0.0 ;
 if ( AccountInfoDouble(ACCOUNT_EQUITY)>总_384_do_5DA0 )
 {
   总_384_do_5DA0 = AccountInfoDouble(ACCOUNT_EQUITY) ;
 }
 for (子_2_in = NativeHistoryTotal() ; 子_2_in >= 0 ; 子_2_in --)
 {
   if ( g_trade_view.Select(子_2_in,NATIVE_SELECT_BY_POSITION,NATIVE_HISTORY_POOL) != true )   continue;
   临_lo_2 = g_trade_view.TimeClose();
   if ( 临_lo_2 < iTime(总_336_st_3130,NativeTimeframe(PERIOD_D1),0) )   continue;
   子_3_do = g_trade_view.Profit() + g_trade_view.Swap() + g_trade_view.Commission() ;
   子_1_do = 子_3_do + 子_1_do ;
   
 }
 子_4_do = AccountInfoDouble(ACCOUNT_EQUITY) - AccountInfoDouble(ACCOUNT_BALANCE) ;
 子_5_do = 子_4_do + 子_1_do ;
 if ( !( -(子_5_do)>总_384_do_5DA0 * PropFirmMaxDailyDD / 100.0) )   return;
 
 if ( !(总_382_bo_5D98) )
 {
   Print("Max Daily Drawdown reached, closing trades and skipping rest of the day"); 
 }
 for (临_in_3 = NativeTradesTotal() ; 临_in_3 >= 0 ; 临_in_3=临_in_3 - 1)
 {
   if ( g_trade_view.Select(临_in_3,NATIVE_SELECT_BY_POSITION,NATIVE_ACTIVE_POOL) != true || g_trade_view.SymbolName() != 总_336_st_3130 )   continue;
   临_in_4 = g_trade_view.Magic();
   临_in_5=ST1_MagicNumber + 1;
   if ( 临_in_4 != 临_in_5 )
   {
     临_in_5 = g_trade_view.Magic();
     临_in_6=ST1_MagicNumber + 2;
     if ( 临_in_5 != 临_in_6 )
     {
       临_in_6 = g_trade_view.Magic();
       临_in_7=ST1_MagicNumber + 3;
       if ( 临_in_6 != 临_in_7 )
       {
         临_in_7 = g_trade_view.Magic();
         临_in_8=ST1_MagicNumber + 4;
         if ( 临_in_7 != 临_in_8 )
         {
           临_in_8 = g_trade_view.Magic();
           临_in_9=ST1_MagicNumber + 5;
           if ( 临_in_8 != 临_in_9 )
           {
             临_in_9 = g_trade_view.Magic();
             临_in_10=ST1_MagicNumber + 6;
             if ( 临_in_9 != 临_in_10 )
             {
               临_in_10 = g_trade_view.Magic();
               临_in_11=ST1_MagicNumber + 7;
               if ( 临_in_10 != 临_in_11 )
               {
                 临_in_11 = g_trade_view.Magic();
                 临_in_12=ST1_MagicNumber + 8;
                 if ( 临_in_11 != 临_in_12 )
                 {
                   临_in_12 = g_trade_view.Magic();
                   临_in_13=ST1_MagicNumber + 9;
                   if ( 临_in_12 != 临_in_13 )
                   {
                     临_in_13 = g_trade_view.Magic();
                     临_in_14=ST1_MagicNumber + 10;
                     if ( 临_in_13 != 临_in_14 )
                     {
                       临_in_14 = g_trade_view.Magic();
                       临_in_15=ST1_MagicNumber + 11;
                       if ( 临_in_14 != 临_in_15 )
                       {
                         临_in_15 = g_trade_view.Magic();
                         临_in_16=ST1_MagicNumber + 12;
                         if ( 临_in_15 != 临_in_16 )
                         {
                           临_in_16 = g_trade_view.Magic();
                           临_in_17=ST1_MagicNumber + 13;
                           if ( 临_in_16 != 临_in_17 )
                           {
                             临_in_17 = g_trade_view.Magic();
                             临_in_18=ST1_MagicNumber + 14;
                             if ( 临_in_17 != 临_in_18 )
                             {
                               临_in_18 = g_trade_view.Magic();
                               临_in_19=ST1_MagicNumber + 15;
                             if ( 临_in_18 != 临_in_19 )   continue;
                             }
                           }
                         }
                       }
                     }
                   }
                 }
               }
             }
           }
         }
       }
     }
   }
   if ( g_trade_view.OrderType() == ORDER_TYPE_BUY )
   {
     NativeClosePosition(g_trade_view.Ticket(),g_trade_view.Volume(),SymbolInfoDouble(总_336_st_3130,SYMBOL_BID),(int)总_38_do_C0,clrRed); 
   }
   if ( g_trade_view.OrderType() == ORDER_TYPE_SELL )
   {
     NativeClosePosition(g_trade_view.Ticket(),g_trade_view.Volume(),SymbolInfoDouble(总_336_st_3130,SYMBOL_ASK),(int)总_38_do_C0,clrRed); 
   }
   if ( ( g_trade_view.OrderType() != ORDER_TYPE_BUY_STOP && g_trade_view.OrderType() != ORDER_TYPE_SELL_STOP ) )   continue;
   NativeDeletePending(g_trade_view.Ticket(),clrRed); 
   
 }
 总_382_bo_5D98 = true ;
 总_384_do_5DA0 = 0.0 ;
 }
//lizong_46 <<==--------   --------
// WorldTimeServer GMT parser.
// Priority:
//   1) RFC 7231 HTTP "Date:" header returned by worldtimeserver.com.
//   2) Current WorldTimeServer page text: "UTC/GMT is HH:MM on ...".
//   3) Legacy hidden field "serverTimeStamp" (older site layout).
// This keeps AutoGMT dependent on WorldTimeServer while avoiding a fragile
// dependency on one specific HTML field/layout.
 int WTS_MonthToInt(string 月_st)
 {
   string 月小写_st = 月_st;
   StringToLower(月小写_st);
   if(StringLen(月小写_st) >= 3)
      月小写_st = StringSubstr(月小写_st,0,3);
   if(月小写_st == "jan") return(1);
   if(月小写_st == "feb") return(2);
   if(月小写_st == "mar") return(3);
   if(月小写_st == "apr") return(4);
   if(月小写_st == "may") return(5);
   if(月小写_st == "jun") return(6);
   if(月小写_st == "jul") return(7);
   if(月小写_st == "aug") return(8);
   if(月小写_st == "sep") return(9);
   if(月小写_st == "oct") return(10);
   if(月小写_st == "nov") return(11);
   if(月小写_st == "dec") return(12);
   return(0);
 }

 bool WTS_BuildDateTime(int 年_in,int 月_in,int 日_in,int 时_in,int 分_in,int 秒_in,datetime &输出_da)
 {
   if(年_in < 2000 || 年_in > 2200 || 月_in < 1 || 月_in > 12 ||
      日_in < 1 || 日_in > 31 || 时_in < 0 || 时_in > 23 ||
      分_in < 0 || 分_in > 59 || 秒_in < 0 || 秒_in > 59)
      return(false);

   MqlDateTime 时结构;
   ZeroMemory(时结构);
   时结构.year = 年_in;
   时结构.mon  = 月_in;
   时结构.day  = 日_in;
   时结构.hour = 时_in;
   时结构.min  = 分_in;
   时结构.sec  = 秒_in;
   输出_da = StructToTime(时结构);
   return(输出_da > 0);
 }

 bool WTS_ParseHttpDate(string 头_st,datetime &输出_da)
 {
   string 小写头_st = 头_st;
   StringToLower(小写头_st);

   int 位置_in = StringFind(小写头_st,"\r\ndate:",0);
   if(位置_in >= 0)
      位置_in += 2;
   else
   {
      位置_in = StringFind(小写头_st,"\ndate:",0);
      if(位置_in >= 0)
         位置_in += 1;
      else if(StringFind(小写头_st,"date:",0) == 0)
         位置_in = 0;
      else
         return(false);
   }

   int 行尾_in = StringFind(头_st,"\n",位置_in);
   string 日期行_st;
   if(行尾_in < 0)
      日期行_st = StringSubstr(头_st,位置_in + 5);
   else
      日期行_st = StringSubstr(头_st,位置_in + 5,行尾_in - (位置_in + 5));
   StringReplace(日期行_st,"\r","");
   StringTrimLeft(日期行_st);
   StringTrimRight(日期行_st);

   // RFC 7231 example: Fri, 14 Aug 2026 08:27:31 GMT
   string 项_st[];
   int 项数_in = StringSplit(日期行_st,' ',项_st);
   if(项数_in < 6)
      return(false);

   int 日_in = (int)StringToInteger(项_st[1]);
   int 月_in = WTS_MonthToInt(项_st[2]);
   int 年_in = (int)StringToInteger(项_st[3]);

   string 时项_st[];
   if(StringSplit(项_st[4],':',时项_st) < 3)
      return(false);
   int 时_in = (int)StringToInteger(时项_st[0]);
   int 分_in = (int)StringToInteger(时项_st[1]);
   int 秒_in = (int)StringToInteger(时项_st[2]);

   return(WTS_BuildDateTime(年_in,月_in,日_in,时_in,分_in,秒_in,输出_da));
 }

 string WTS_StripTags(string 输入_st)
 {
   string 输出_st = "";
   bool 标签内_bo = false;
   int 长度_in = StringLen(输入_st);
   for(int i=0;i<长度_in;i++)
   {
      ushort 字_ch = (ushort)StringGetCharacter(输入_st,i);
      if(字_ch == '<')
      {
         标签内_bo = true;
         输出_st += " ";
         continue;
      }
      if(字_ch == '>')
      {
         标签内_bo = false;
         输出_st += " ";
         continue;
      }
      if(!标签内_bo)
         输出_st += ShortToString(字_ch);
   }

   StringReplace(输出_st,"&nbsp;"," ");
   StringReplace(输出_st,"&#160;"," ");
   StringReplace(输出_st,"\r"," ");
   StringReplace(输出_st,"\n"," ");
   StringReplace(输出_st,"\t"," ");
   while(StringFind(输出_st,"  ",0) >= 0)
      StringReplace(输出_st,"  "," ");
   StringTrimLeft(输出_st);
   StringTrimRight(输出_st);
   return(输出_st);
 }

 bool WTS_ParseHtmlTime(string 网页_st,datetime &输出_da)
 {
   // Old WorldTimeServer layout: Unix timestamp in a hidden field.
   int 位置_in = StringFind(网页_st,"\"serverTimeStamp\" value=",0);
   if(位置_in >= 0)
   {
      int 长度_in = StringLen(网页_st);
      int i = 位置_in + 20;
      while(i < 长度_in)
      {
         ushort c = (ushort)StringGetCharacter(网页_st,i);
         if(c >= '0' && c <= '9')
            break;
         i++;
      }
      string 数字_st = "";
      while(i < 长度_in && StringLen(数字_st) < 12)
      {
         ushort c = (ushort)StringGetCharacter(网页_st,i);
         if(c < '0' || c > '9')
            break;
         数字_st += ShortToString(c);
         i++;
      }
      long 时间戳_lo = (long)StringToInteger(数字_st);
      if(时间戳_lo > 1000000000)
      {
         输出_da = (datetime)时间戳_lo;
         return(true);
      }
   }

   // Current WorldTimeServer layout (2026):
   // "UTC/GMT is 08:27 on Friday, August 14, 2026"
   位置_in = StringFind(网页_st,"UTC/GMT is",0);
   if(位置_in < 0)
      return(false);

   string 片段_st = StringSubstr(网页_st,位置_in,500);
   string 文本_st = WTS_StripTags(片段_st);
   int 标记_in = StringFind(文本_st,"UTC/GMT is ",0);
   if(标记_in < 0)
      return(false);

   int 时间开始_in = 标记_in + StringLen("UTC/GMT is ");
   if(StringLen(文本_st) < 时间开始_in + 5)
      return(false);
   string 时分_st = StringSubstr(文本_st,时间开始_in,5);
   string 时分项_st[];
   if(StringSplit(时分_st,':',时分项_st) < 2)
      return(false);

   int 时_in = (int)StringToInteger(时分项_st[0]);
   int 分_in = (int)StringToInteger(时分项_st[1]);

   int on位置_in = StringFind(文本_st," on ",时间开始_in);
   if(on位置_in < 0)
      return(false);
   string 日期部分_st = StringSubstr(文本_st,on位置_in + 4,80);
   string 日期项_st[];
   int 日期项数_in = StringSplit(日期部分_st,' ',日期项_st);
   if(日期项数_in < 4)
      return(false);

   // tokens: Friday, August 14, 2026
   string 日_st = 日期项_st[2];
   string 年_st = 日期项_st[3];
   StringReplace(日_st,",","");
   StringReplace(年_st,",","");
   int 月_in = WTS_MonthToInt(日期项_st[1]);
   int 日_in = (int)StringToInteger(日_st);
   int 年_in = (int)StringToInteger(年_st);

   // The visible "UTC/GMT is" line has minute precision. This is sufficient
   // for broker GMT offset detection and remains independent of VPS time.
   return(WTS_BuildDateTime(年_in,月_in,日_in,时_in,分_in,0,输出_da));
 }

 int lizong_47()
 {
  string    子_2_st;
  long      子_5_lo;
  int       子_6_in;
  char      子_7_ch_ko[];
  char      子_8_ch_ko[];
//----- -----
 string     临_st_1;
 string     临_st_2;
 datetime   临_da_3 = 0;
 int        临_in_4;

 ResetLastError();
 临_in_4 = WebRequest("GET","https://www.worldtimeserver.com/time-zones/utc/",NULL,NULL,10000,子_7_ch_ko,0,子_8_ch_ko,临_st_1);
 if ( 临_in_4 == -1 )
 {
   Print("Error when reading GMT URL. Error code  =",GetLastError());
   MessageBox("Add the address \'https://www.worldtimeserver.com/\' in the list of allowed URLs on tab \'Expert Advisors\'","Error",64);
   临_st_2 = "999";
 }
 else
 {
   // MQL5: count=-1 means read the whole WebRequest response array.
   临_st_2 = CharArrayToString(子_8_ch_ko,0,-1,CP_UTF8);
 }
 子_2_st = 临_st_2 ;
 if ( 子_2_st == "999" )
 {
   return(999);
 }

 // Prefer WorldTimeServer's HTTP Date header. It is standardized and does
 // not change when the site's visual HTML layout changes.
 bool 解析成功_bo = WTS_ParseHttpDate(临_st_1,临_da_3);
 if(!解析成功_bo)
    解析成功_bo = WTS_ParseHtmlTime(子_2_st,临_da_3);

 if(!解析成功_bo || 临_da_3 <= 0)
 {
   Print("Error in detecting GMT time with WorldTimeServer response");
   return(999);
 }

 子_5_lo = (long)临_da_3;
 Print("GMT time = ",子_5_lo);
 Print("Broker time = ",TimeCurrent());
 子_6_in=DateHour(TimeCurrent()) - DateHour((datetime)子_5_lo);
 if ( 子_6_in <  -12 )
 {
   子_6_in +=24;
 }
 if ( 子_6_in >  12 )
 {
   子_6_in -=24;
 }
 Print("GMT_Offset detected: " + string(子_6_in));
 if ( ( 子_6_in < -12 || 子_6_in >  12 ) )
 {
   Print("Error in detecting GMT offset with URL");
   return(999);
 }
 if ( 子_5_lo <  TimeCurrent() - 0x15180 )
 {
   Print("Error in detecting GMT time with URL");
   return(999);
 }
 return(子_6_in);
 }
//lizong_47 <<==--------   --------
 bool lizong_48()
 {
  int       子_2_in;
  datetime  子_3_da;
  datetime  子_4_da;
  int       子_5_in;
  int       子_6_in;
//----- -----

 子_2_in = DateYear(TimeCurrent()) ;
 子_3_da = 0 ;
 子_4_da = 0 ;
 if ( 子_2_in <  1987 )
 {
   Print("AmericanDST(): Invalid year."); 
   return(false); 
 }
 子_5_in = 0 ;
 子_6_in = 0 ;
 if ( 子_2_in >= 1987 && 子_2_in <= 2006 )
 {
   子_5_in = (int)(MathMod(子_2_in * 6 + 2 - 子_2_in / 4,7.0) + 1.0) ;
   子_6_in = (int)(31.0 - (MathMod(子_2_in * 5 / 4 + 1,7.0))) ;
   子_3_da=StringToTime(((string)子_2_in+".04.01")) + (子_5_in - 1) * 86400 + 0x1C20;
   子_4_da=StringToTime(((string)子_2_in+".10.01")) + (子_6_in - 1) * 86400 + 0x1C20;
 }
 else
 {
   if ( 子_2_in >= 2007 )
   {
     子_5_in = (int)(14.0 - (MathMod(子_2_in * 5 / 4 + 1,7.0))) ;
     子_6_in = (int)(7.0 - (MathMod(子_2_in * 5 / 4 + 1,7.0))) ;
     子_3_da=StringToTime(((string)子_2_in+".03.01")) + (子_5_in - 1) * 86400 + 0x1C20;
     子_4_da=StringToTime(((string)子_2_in+".11.01")) + (子_6_in - 1) * 86400 + 0x1C20;
   }
 }
 if ( DateDayOfYear(TimeCurrent()) >  DateDayOfYear(子_3_da) && DateDayOfYear(TimeCurrent()) <  DateDayOfYear(子_4_da) )
 {
   return(true); 
 }
 return(false); 
 }
//<<==lizong_48 <<==
