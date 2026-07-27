#include <Trade/Trade.mqh>
#property copyright  "Copyright 2026 - Pham Duy Linh"
#property link       "https://t.me/Khonglamdoicoan96"
#property version    "4.5"
#property description "- Fixed the www.worldtimeserver GMT fetch bug"
#property description "- Fixed the OnlyUp bug"
#property description "- Hardcoded NFP dates -> now automatic (MT5 Economic Calendar), auto-retries on error"
#property description "- Added input to close trades at end of Friday session"
#property description "- Highest Balance shown on panel"
#property description "- Warns the exact missing allowed URL"
#property description "- Native MQL5 position/order/deal handling with detailed trade logging"
#property description "- A few handy inputs (all default to the original behavior)"
#property description "Telegram: t.me/Khonglamdoicoan96"



//==================================================================
// Native MQL5 execution layer
//==================================================================
// The strategy keeps its original combined traversal order (positions first,
// then pending orders) through a selected-record view. All data is sourced
// directly from MQL5 Position*, Order*, HistoryDeal*, SymbolInfo* and
// AccountInfo* APIs. The account must use RETAIL_HEDGING because the strategy
// manages multiple independent positions on the same symbol and magic numbers.

#define SECONDS_PER_DAY                                      86400
#define RESTORED_PENDING_EXPIRATION_EXTENSION_SECONDS       172800
#define DST_TRANSITION_TIME_SECONDS                           7200
#define NFP_FALLBACK_TIME_HHMM                                1230
#define MATH_RAND_RANGE                                    32768.0

const int STRATEGY_ERROR_MARKET_CLOSED = 132;
const int STRATEGY_ERROR_INVALID_TICKET = 4108;

enum TradeRecordSelectMode
{
   TRADE_SELECT_BY_INDEX  = 0,
   TRADE_SELECT_BY_TICKET = 1
};

enum TradeRecordPool
{
   TRADE_POOL_ACTIVE  = 0,
   TRADE_POOL_HISTORY = 1
};

CTrade trade;
long lastSubmittedTradeTicket = -1;
int  lastTradeErrorCode = 0;

ENUM_TIMEFRAMES NormalizeTimeframe(const int minutes)
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
   }
   return (ENUM_TIMEFRAMES)minutes;
}

bool RefreshCurrentSymbolTick()
{
   MqlTick latestTick;
   return SymbolInfoTick(_Symbol,latestTick);
}

bool IsDemoAccount()
{
   return AccountInfoInteger(ACCOUNT_TRADE_MODE)==ACCOUNT_TRADE_MODE_DEMO;
}

bool IsStrategyTester()
{
   return (bool)MQLInfoInteger(MQL_TESTER);
}

int DateTimeYear(const datetime value)      { MqlDateTime parts; TimeToStruct(value,parts); return parts.year; }
int DateTimeMonth(const datetime value)     { MqlDateTime parts; TimeToStruct(value,parts); return parts.mon; }
int DateTimeDay(const datetime value)       { MqlDateTime parts; TimeToStruct(value,parts); return parts.day; }
int DateTimeHour(const datetime value)      { MqlDateTime parts; TimeToStruct(value,parts); return parts.hour; }
int DateTimeMinute(const datetime value)    { MqlDateTime parts; TimeToStruct(value,parts); return parts.min; }
int DateTimeSecond(const datetime value)    { MqlDateTime parts; TimeToStruct(value,parts); return parts.sec; }
int DateTimeDayOfWeek(const datetime value) { MqlDateTime parts; TimeToStruct(value,parts); return parts.day_of_week; }
int DateTimeDayOfYear(const datetime value) { MqlDateTime parts; TimeToStruct(value,parts); return parts.day_of_year; }

int CurrentYear()      { return DateTimeYear(TimeCurrent()); }
int CurrentMonth()     { return DateTimeMonth(TimeCurrent()); }
int CurrentDay()       { return DateTimeDay(TimeCurrent()); }
int CurrentHour()      { return DateTimeHour(TimeCurrent()); }
int CurrentMinute()    { return DateTimeMinute(TimeCurrent()); }
int CurrentSecond()    { return DateTimeSecond(TimeCurrent()); }
int CurrentDayOfWeek() { return DateTimeDayOfWeek(TimeCurrent()); }

ENUM_APPLIED_PRICE NormalizeAppliedPrice(const int legacyPriceCode)
{
   return (ENUM_APPLIED_PRICE)(legacyPriceCode+1);
}

double GetMovingAverageValue(const string symbol,const int timeframe,const int period,
                             const int maShift,const int maMethod,
                             const int appliedPrice,const int bufferShift)
{
   int handle=::iMA(symbol,NormalizeTimeframe(timeframe),period,maShift,
                    (ENUM_MA_METHOD)maMethod,NormalizeAppliedPrice(appliedPrice));
   if(handle==INVALID_HANDLE)
      return 0.0;

   double values[];
   ArraySetAsSeries(values,true);
   if(CopyBuffer(handle,0,bufferShift,1,values)<=0)
      return 0.0;
   return values[0];
}

double GetFractalValue(const string symbol,const int timeframe,const int fractalBufferMode,
                       const int bufferShift)
{
   int handle=::iFractals(symbol,NormalizeTimeframe(timeframe));
   if(handle==INVALID_HANDLE)
      return 0.0;

   int bufferIndex=(fractalBufferMode==1)?0:1;
   double values[];
   ArraySetAsSeries(values,true);
   if(CopyBuffer(handle,bufferIndex,bufferShift,1,values)<=0)
      return 0.0;
   return values[0];
}

double ProjectedFreeMarginAfterOrder(const string symbol,const ENUM_ORDER_TYPE orderType,
                                     const double volume)
{
   double margin=0.0;
   ENUM_ORDER_TYPE marketType=(orderType==ORDER_TYPE_BUY)?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
   double price=(marketType==ORDER_TYPE_BUY)
                ?SymbolInfoDouble(symbol,SYMBOL_ASK)
                :SymbolInfoDouble(symbol,SYMBOL_BID);
   if(!OrderCalcMargin(marketType,symbol,volume,price,margin))
      return AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   return AccountInfoDouble(ACCOUNT_MARGIN_FREE)-margin;
}

int LastTradeErrorCode()
{
   return lastTradeErrorCode;
}

int TradeRetcodeToStrategyError(const uint retcode)
{
   switch(retcode)
   {
      case TRADE_RETCODE_REQUOTE:        return 138;
      case TRADE_RETCODE_REJECT:         return 134;
      case TRADE_RETCODE_CONNECTION:     return 137;
      case TRADE_RETCODE_MARKET_CLOSED:  return STRATEGY_ERROR_MARKET_CLOSED;
      case TRADE_RETCODE_TRADE_DISABLED: return 133;
      case TRADE_RETCODE_NO_MONEY:       return 134;
      case TRADE_RETCODE_PRICE_CHANGED:  return 135;
      case TRADE_RETCODE_PRICE_OFF:      return 136;
      case TRADE_RETCODE_INVALID_STOPS:  return 130;
      case TRADE_RETCODE_INVALID_PRICE:  return 129;
      case TRADE_RETCODE_TIMEOUT:        return 128;
      case TRADE_RETCODE_INVALID_VOLUME: return 131;
      case TRADE_RETCODE_DONE:
      case TRADE_RETCODE_DONE_PARTIAL:
      case TRADE_RETCODE_PLACED:         return 0;
   }
   return (int)retcode;
}

ENUM_ORDER_TYPE_FILLING SelectSymbolFillingMode(const string symbol)
{
   long fillingMask=SymbolInfoInteger(symbol,SYMBOL_FILLING_MODE);
   if((fillingMask&SYMBOL_FILLING_FOK)!=0)
      return ORDER_FILLING_FOK;
   if((fillingMask&SYMBOL_FILLING_IOC)!=0)
      return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
}

string TradeOrderTypeName(const ENUM_ORDER_TYPE orderType)
{
   switch(orderType)
   {
      case ORDER_TYPE_BUY:        return "buy";
      case ORDER_TYPE_SELL:       return "sell";
      case ORDER_TYPE_BUY_LIMIT:  return "buy limit";
      case ORDER_TYPE_SELL_LIMIT: return "sell limit";
      case ORDER_TYPE_BUY_STOP:   return "buy stop";
      case ORDER_TYPE_SELL_STOP:  return "sell stop";
      default:                    return "order";
   }
}

long SendTradeOrder(const string symbol,const ENUM_ORDER_TYPE orderType,
                    const double volume,const double requestedPrice,
                    const int slippagePoints,const double stopLoss,
                    const double takeProfit,const string comment="",
                    const int magic=0,const datetime expiration=0,
                    const color arrowColor=clrNONE)
{
   trade.SetExpertMagicNumber((ulong)magic);
   trade.SetDeviationInPoints((ulong)MathMax(slippagePoints,0));

   bool requestAccepted=false;
   double executionPrice=requestedPrice;

   if(orderType==ORDER_TYPE_BUY || orderType==ORDER_TYPE_SELL)
   {
      trade.SetTypeFilling(SelectSymbolFillingMode(symbol));
      executionPrice=(orderType==ORDER_TYPE_BUY)
                     ?SymbolInfoDouble(symbol,SYMBOL_ASK)
                     :SymbolInfoDouble(symbol,SYMBOL_BID);
      requestAccepted=trade.PositionOpen(symbol,orderType,volume,executionPrice,
                                         stopLoss,takeProfit,comment);
   }
   else
   {
      trade.SetTypeFilling(ORDER_FILLING_RETURN);
      ENUM_ORDER_TYPE_TIME timeType=(expiration>0)?ORDER_TIME_SPECIFIED:ORDER_TIME_GTC;
      requestAccepted=trade.OrderOpen(symbol,orderType,volume,0.0,requestedPrice,
                                      stopLoss,takeProfit,timeType,expiration,comment);
   }

   uint retcode=trade.ResultRetcode();
   if(!requestAccepted && retcode==0)
      retcode=TRADE_RETCODE_ERROR;
   lastTradeErrorCode=TradeRetcodeToStrategyError(retcode);

   if(requestAccepted &&
      (retcode==TRADE_RETCODE_DONE || retcode==TRADE_RETCODE_DONE_PARTIAL ||
       retcode==TRADE_RETCODE_PLACED))
   {
      lastTradeErrorCode=0;
      ulong resultTicket=trade.ResultOrder();
      if(resultTicket==0)
         resultTicket=trade.ResultDeal();
      lastSubmittedTradeTicket=(long)resultTicket;
      PrintFormat("open #%I64d %s %.2f %s at %.5f sl: %.5f tp: %.5f ok",
                  lastSubmittedTradeTicket,TradeOrderTypeName(orderType),volume,
                  symbol,executionPrice,stopLoss,takeProfit);
      return lastSubmittedTradeTicket;
   }

   PrintFormat("failed open %s %.2f %s at %.5f sl: %.5f tp: %.5f [%s] (retcode=%u)",
               TradeOrderTypeName(orderType),volume,symbol,executionPrice,
               stopLoss,takeProfit,trade.ResultRetcodeDescription(),retcode);
   lastSubmittedTradeTicket=-1;
   return -1;
}

bool ModifyTradeByTicket(const long ticket,const double price,const double stopLoss,
                         const double takeProfit,const datetime expiration,
                         const color arrowColor=clrNONE)
{
   bool requestAccepted=false;
   string symbol="";

   if(PositionSelectByTicket((ulong)ticket))
   {
      symbol=PositionGetString(POSITION_SYMBOL);
      requestAccepted=trade.PositionModify((ulong)ticket,stopLoss,takeProfit);
   }
   else if(::OrderSelect((ulong)ticket))
   {
      symbol=::OrderGetString(ORDER_SYMBOL);
      ENUM_ORDER_TYPE_TIME timeType=(expiration>0)?ORDER_TIME_SPECIFIED:ORDER_TIME_GTC;
      requestAccepted=trade.OrderModify((ulong)ticket,price,stopLoss,takeProfit,
                                        timeType,expiration,0.0);
   }
   else
   {
      lastTradeErrorCode=STRATEGY_ERROR_INVALID_TICKET;
      return false;
   }

   uint retcode=trade.ResultRetcode();
   if(!requestAccepted && retcode==0)
      retcode=TRADE_RETCODE_ERROR;
   lastTradeErrorCode=TradeRetcodeToStrategyError(retcode);

   if(requestAccepted &&
      (retcode==TRADE_RETCODE_DONE || retcode==TRADE_RETCODE_DONE_PARTIAL))
   {
      lastTradeErrorCode=0;
      PrintFormat("modify #%I64d %s price: %.5f sl: %.5f tp: %.5f ok",
                  ticket,symbol,price,stopLoss,takeProfit);
      return true;
   }

   PrintFormat("failed modify %s at %.5f sl: %.5f tp: %.5f [%s] (retcode=%u, ticket=%I64d)",
               symbol,price,stopLoss,takeProfit,trade.ResultRetcodeDescription(),retcode,ticket);
   return false;
}

bool ClosePositionByTicket(const long ticket,const double requestedVolume,
                           const double requestedPrice,const int slippagePoints,
                           const color arrowColor=clrNONE)
{
   if(!PositionSelectByTicket((ulong)ticket))
   {
      lastTradeErrorCode=STRATEGY_ERROR_INVALID_TICKET;
      return false;
   }

   string symbol=PositionGetString(POSITION_SYMBOL);
   double positionVolume=PositionGetDouble(POSITION_VOLUME);
   ENUM_POSITION_TYPE positionType=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double closeVolume=(requestedVolume>0.0 && requestedVolume<positionVolume)
                      ?requestedVolume:positionVolume;
   ulong deviation=(ulong)MathMax(slippagePoints,0);

   trade.SetDeviationInPoints(deviation);
   trade.SetTypeFilling(SelectSymbolFillingMode(symbol));

   bool requestAccepted=(closeVolume>=positionVolume)
                        ?trade.PositionClose((ulong)ticket,deviation)
                        :trade.PositionClosePartial((ulong)ticket,closeVolume,deviation);

   uint retcode=trade.ResultRetcode();
   if(!requestAccepted && retcode==0)
      retcode=TRADE_RETCODE_ERROR;
   lastTradeErrorCode=TradeRetcodeToStrategyError(retcode);

   if(requestAccepted &&
      (retcode==TRADE_RETCODE_DONE || retcode==TRADE_RETCODE_DONE_PARTIAL))
   {
      lastTradeErrorCode=0;
      PrintFormat("close #%I64d %s %.2f %s at %.5f ok",ticket,
                  (positionType==POSITION_TYPE_BUY)?"buy":"sell",
                  closeVolume,symbol,trade.ResultPrice());
      return true;
   }

   PrintFormat("failed close %s %.2f %s [%s] (retcode=%u, ticket=%I64d)",
               (positionType==POSITION_TYPE_BUY)?"buy":"sell",closeVolume,symbol,
               trade.ResultRetcodeDescription(),retcode,ticket);
   return false;
}

bool DeletePendingOrderByTicket(const long ticket,const color arrowColor=clrNONE)
{
   string orderName="order";
   double orderVolume=0.0;
   double orderPrice=0.0;
   string symbol="";

   if(::OrderSelect((ulong)ticket))
   {
      orderName=TradeOrderTypeName((ENUM_ORDER_TYPE)::OrderGetInteger(ORDER_TYPE));
      orderVolume=::OrderGetDouble(ORDER_VOLUME_CURRENT);
      orderPrice=::OrderGetDouble(ORDER_PRICE_OPEN);
      symbol=::OrderGetString(ORDER_SYMBOL);
   }

   bool requestAccepted=trade.OrderDelete((ulong)ticket);
   uint retcode=trade.ResultRetcode();
   if(!requestAccepted && retcode==0)
      retcode=TRADE_RETCODE_ERROR;
   lastTradeErrorCode=TradeRetcodeToStrategyError(retcode);

   if(requestAccepted && retcode==TRADE_RETCODE_DONE)
   {
      lastTradeErrorCode=0;
      PrintFormat("delete #%I64d %s %.2f %s at %.5f ok",
                  ticket,orderName,orderVolume,symbol,orderPrice);
      return true;
   }

   PrintFormat("failed delete %s %.2f %s at %.5f [%s] (retcode=%u, ticket=%I64d)",
               orderName,orderVolume,symbol,orderPrice,
               trade.ResultRetcodeDescription(),retcode,ticket);
   return false;
}

struct SelectedTradeRecord
{
   long            ticket;
   string          symbol;
   ENUM_ORDER_TYPE type;
   double          volume;
   double          openPrice;
   double          closePrice;
   double          stopLoss;
   double          takeProfit;
   datetime        openTime;
   datetime        closeTime;
   datetime        expiration;
   double          profit;
   double          swap;
   double          commission;
   string          comment;
   long            magic;
};

SelectedTradeRecord selectedTrade;

long            closedTradeTicket[];
string          closedTradeSymbol[];
ENUM_ORDER_TYPE closedTradeType[];
double          closedTradeVolume[];
double          closedTradeOpenPrice[];
double          closedTradeClosePrice[];
datetime        closedTradeOpenTime[];
datetime        closedTradeCloseTime[];
double          closedTradeProfit[];
double          closedTradeSwap[];
double          closedTradeCommission[];
string          closedTradeComment[];
long            closedTradeMagic[];
datetime        closedTradeExpiration[];
int             closedTradeCount=0;
datetime        closedTradeCacheBuiltAt=0;

void BuildClosedTradeCache()
{
   if(TimeCurrent()==closedTradeCacheBuiltAt)
      return;
   closedTradeCacheBuiltAt=TimeCurrent();

   ArrayResize(closedTradeTicket,0);
   ArrayResize(closedTradeSymbol,0);
   ArrayResize(closedTradeType,0);
   ArrayResize(closedTradeVolume,0);
   ArrayResize(closedTradeOpenPrice,0);
   ArrayResize(closedTradeClosePrice,0);
   ArrayResize(closedTradeOpenTime,0);
   ArrayResize(closedTradeCloseTime,0);
   ArrayResize(closedTradeProfit,0);
   ArrayResize(closedTradeSwap,0);
   ArrayResize(closedTradeCommission,0);
   ArrayResize(closedTradeComment,0);
   ArrayResize(closedTradeMagic,0);
   ArrayResize(closedTradeExpiration,0);
   closedTradeCount=0;

   if(!HistorySelect(0,TimeCurrent()))
      return;

   int dealCount=HistoryDealsTotal();
   long positionIdentifiers[];
   ArrayResize(positionIdentifiers,0);

   for(int dealIndex=0;dealIndex<dealCount;dealIndex++)
   {
      ulong dealTicket=HistoryDealGetTicket(dealIndex);
      if(dealTicket==0)
         continue;

      ENUM_DEAL_ENTRY entry=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket,DEAL_ENTRY);
      long positionIdentifier=HistoryDealGetInteger(dealTicket,DEAL_POSITION_ID);
      ENUM_DEAL_TYPE dealType=(ENUM_DEAL_TYPE)HistoryDealGetInteger(dealTicket,DEAL_TYPE);
      if(dealType!=DEAL_TYPE_BUY && dealType!=DEAL_TYPE_SELL)
         continue;

      int recordIndex=-1;
      for(int searchIndex=0;searchIndex<ArraySize(positionIdentifiers);searchIndex++)
      {
         if(positionIdentifiers[searchIndex]==positionIdentifier)
         {
            recordIndex=searchIndex;
            break;
         }
      }

      if(recordIndex<0)
      {
         recordIndex=ArraySize(positionIdentifiers);
         ArrayResize(positionIdentifiers,recordIndex+1);
         positionIdentifiers[recordIndex]=positionIdentifier;

         int newSize=closedTradeCount+1;
         ArrayResize(closedTradeTicket,newSize);
         ArrayResize(closedTradeSymbol,newSize);
         ArrayResize(closedTradeType,newSize);
         ArrayResize(closedTradeVolume,newSize);
         ArrayResize(closedTradeOpenPrice,newSize);
         ArrayResize(closedTradeClosePrice,newSize);
         ArrayResize(closedTradeOpenTime,newSize);
         ArrayResize(closedTradeCloseTime,newSize);
         ArrayResize(closedTradeProfit,newSize);
         ArrayResize(closedTradeSwap,newSize);
         ArrayResize(closedTradeCommission,newSize);
         ArrayResize(closedTradeComment,newSize);
         ArrayResize(closedTradeMagic,newSize);
         ArrayResize(closedTradeExpiration,newSize);

         closedTradeTicket[closedTradeCount]=positionIdentifier;
         closedTradeSymbol[closedTradeCount]="";
         closedTradeType[closedTradeCount]=ORDER_TYPE_BUY;
         closedTradeVolume[closedTradeCount]=0.0;
         closedTradeOpenPrice[closedTradeCount]=0.0;
         closedTradeClosePrice[closedTradeCount]=0.0;
         closedTradeOpenTime[closedTradeCount]=0;
         closedTradeCloseTime[closedTradeCount]=0;
         closedTradeProfit[closedTradeCount]=0.0;
         closedTradeSwap[closedTradeCount]=0.0;
         closedTradeCommission[closedTradeCount]=0.0;
         closedTradeComment[closedTradeCount]="";
         closedTradeMagic[closedTradeCount]=0;
         closedTradeExpiration[closedTradeCount]=0;
         closedTradeCount=newSize;
      }

      if(entry==DEAL_ENTRY_IN)
      {
         closedTradeSymbol[recordIndex]=HistoryDealGetString(dealTicket,DEAL_SYMBOL);
         closedTradeType[recordIndex]=(dealType==DEAL_TYPE_BUY)?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
         closedTradeVolume[recordIndex]=HistoryDealGetDouble(dealTicket,DEAL_VOLUME);
         closedTradeOpenPrice[recordIndex]=HistoryDealGetDouble(dealTicket,DEAL_PRICE);
         closedTradeOpenTime[recordIndex]=(datetime)HistoryDealGetInteger(dealTicket,DEAL_TIME);
         closedTradeMagic[recordIndex]=HistoryDealGetInteger(dealTicket,DEAL_MAGIC);
         closedTradeComment[recordIndex]=HistoryDealGetString(dealTicket,DEAL_COMMENT);
         closedTradeProfit[recordIndex]+=HistoryDealGetDouble(dealTicket,DEAL_PROFIT);
         closedTradeSwap[recordIndex]+=HistoryDealGetDouble(dealTicket,DEAL_SWAP);
         closedTradeCommission[recordIndex]+=HistoryDealGetDouble(dealTicket,DEAL_COMMISSION);
      }
      else
      {
         closedTradeClosePrice[recordIndex]=HistoryDealGetDouble(dealTicket,DEAL_PRICE);
         datetime closeTime=(datetime)HistoryDealGetInteger(dealTicket,DEAL_TIME);
         if(closeTime>closedTradeCloseTime[recordIndex])
            closedTradeCloseTime[recordIndex]=closeTime;
         closedTradeProfit[recordIndex]+=HistoryDealGetDouble(dealTicket,DEAL_PROFIT);
         closedTradeSwap[recordIndex]+=HistoryDealGetDouble(dealTicket,DEAL_SWAP);
         closedTradeCommission[recordIndex]+=HistoryDealGetDouble(dealTicket,DEAL_COMMISSION);
         if(closedTradeSymbol[recordIndex]=="")
            closedTradeSymbol[recordIndex]=HistoryDealGetString(dealTicket,DEAL_SYMBOL);
         if(closedTradeMagic[recordIndex]==0)
            closedTradeMagic[recordIndex]=HistoryDealGetInteger(dealTicket,DEAL_MAGIC);
      }
   }

   for(int left=0;left<closedTradeCount;left++)
   {
      for(int right=left+1;right<closedTradeCount;right++)
      {
         if(closedTradeCloseTime[right]>=closedTradeCloseTime[left])
            continue;

         long longValue;
         string stringValue;
         ENUM_ORDER_TYPE typeValue;
         double doubleValue;
         datetime timeValue;

         longValue=closedTradeTicket[left]; closedTradeTicket[left]=closedTradeTicket[right]; closedTradeTicket[right]=longValue;
         stringValue=closedTradeSymbol[left]; closedTradeSymbol[left]=closedTradeSymbol[right]; closedTradeSymbol[right]=stringValue;
         typeValue=closedTradeType[left]; closedTradeType[left]=closedTradeType[right]; closedTradeType[right]=typeValue;
         doubleValue=closedTradeVolume[left]; closedTradeVolume[left]=closedTradeVolume[right]; closedTradeVolume[right]=doubleValue;
         doubleValue=closedTradeOpenPrice[left]; closedTradeOpenPrice[left]=closedTradeOpenPrice[right]; closedTradeOpenPrice[right]=doubleValue;
         doubleValue=closedTradeClosePrice[left]; closedTradeClosePrice[left]=closedTradeClosePrice[right]; closedTradeClosePrice[right]=doubleValue;
         timeValue=closedTradeOpenTime[left]; closedTradeOpenTime[left]=closedTradeOpenTime[right]; closedTradeOpenTime[right]=timeValue;
         timeValue=closedTradeCloseTime[left]; closedTradeCloseTime[left]=closedTradeCloseTime[right]; closedTradeCloseTime[right]=timeValue;
         doubleValue=closedTradeProfit[left]; closedTradeProfit[left]=closedTradeProfit[right]; closedTradeProfit[right]=doubleValue;
         doubleValue=closedTradeSwap[left]; closedTradeSwap[left]=closedTradeSwap[right]; closedTradeSwap[right]=doubleValue;
         doubleValue=closedTradeCommission[left]; closedTradeCommission[left]=closedTradeCommission[right]; closedTradeCommission[right]=doubleValue;
         stringValue=closedTradeComment[left]; closedTradeComment[left]=closedTradeComment[right]; closedTradeComment[right]=stringValue;
         longValue=closedTradeMagic[left]; closedTradeMagic[left]=closedTradeMagic[right]; closedTradeMagic[right]=longValue;
      }
   }
}

int ActiveTradeCount()
{
   return PositionsTotal()+::OrdersTotal();
}

int ClosedTradeCount()
{
   BuildClosedTradeCache();
   return closedTradeCount;
}

void FillSelectedTradeFromPosition(const long ticket)
{
   selectedTrade.ticket=ticket;
   selectedTrade.symbol=PositionGetString(POSITION_SYMBOL);
   selectedTrade.type=(ENUM_ORDER_TYPE)PositionGetInteger(POSITION_TYPE);
   selectedTrade.volume=PositionGetDouble(POSITION_VOLUME);
   selectedTrade.openPrice=PositionGetDouble(POSITION_PRICE_OPEN);
   selectedTrade.closePrice=PositionGetDouble(POSITION_PRICE_CURRENT);
   selectedTrade.stopLoss=PositionGetDouble(POSITION_SL);
   selectedTrade.takeProfit=PositionGetDouble(POSITION_TP);
   selectedTrade.openTime=(datetime)PositionGetInteger(POSITION_TIME);
   selectedTrade.closeTime=0;
   selectedTrade.expiration=0;
   selectedTrade.profit=PositionGetDouble(POSITION_PROFIT);
   selectedTrade.swap=PositionGetDouble(POSITION_SWAP);
   selectedTrade.commission=0.0;
   selectedTrade.comment=PositionGetString(POSITION_COMMENT);
   selectedTrade.magic=PositionGetInteger(POSITION_MAGIC);
}

void FillSelectedTradeFromPendingOrder(const long ticket)
{
   selectedTrade.ticket=ticket;
   selectedTrade.symbol=::OrderGetString(ORDER_SYMBOL);
   selectedTrade.type=(ENUM_ORDER_TYPE)::OrderGetInteger(ORDER_TYPE);
   selectedTrade.volume=::OrderGetDouble(ORDER_VOLUME_CURRENT);
   selectedTrade.openPrice=::OrderGetDouble(ORDER_PRICE_OPEN);
   selectedTrade.closePrice=0.0;
   selectedTrade.stopLoss=::OrderGetDouble(ORDER_SL);
   selectedTrade.takeProfit=::OrderGetDouble(ORDER_TP);
   selectedTrade.openTime=(datetime)::OrderGetInteger(ORDER_TIME_SETUP);
   selectedTrade.closeTime=0;
   selectedTrade.expiration=(datetime)::OrderGetInteger(ORDER_TIME_EXPIRATION);
   selectedTrade.profit=0.0;
   selectedTrade.swap=0.0;
   selectedTrade.commission=0.0;
   selectedTrade.comment=::OrderGetString(ORDER_COMMENT);
   selectedTrade.magic=::OrderGetInteger(ORDER_MAGIC);
}

void FillSelectedTradeFromHistory(const int recordIndex)
{
   selectedTrade.ticket=closedTradeTicket[recordIndex];
   selectedTrade.symbol=closedTradeSymbol[recordIndex];
   selectedTrade.type=closedTradeType[recordIndex];
   selectedTrade.volume=closedTradeVolume[recordIndex];
   selectedTrade.openPrice=closedTradeOpenPrice[recordIndex];
   selectedTrade.closePrice=closedTradeClosePrice[recordIndex];
   selectedTrade.stopLoss=0.0;
   selectedTrade.takeProfit=0.0;
   selectedTrade.openTime=closedTradeOpenTime[recordIndex];
   selectedTrade.closeTime=closedTradeCloseTime[recordIndex];
   selectedTrade.expiration=0;
   selectedTrade.profit=closedTradeProfit[recordIndex];
   selectedTrade.swap=closedTradeSwap[recordIndex];
   selectedTrade.commission=closedTradeCommission[recordIndex];
   selectedTrade.comment=closedTradeComment[recordIndex];
   selectedTrade.magic=closedTradeMagic[recordIndex];
}

bool SelectTradeRecord(const long indexOrTicket,const TradeRecordSelectMode selectMode,
                       const TradeRecordPool pool=TRADE_POOL_ACTIVE)
{
   if(selectMode==TRADE_SELECT_BY_TICKET)
   {
      long ticket=indexOrTicket;
      if(PositionSelectByTicket((ulong)ticket))
      {
         FillSelectedTradeFromPosition(ticket);
         return true;
      }
      if(::OrderSelect((ulong)ticket))
      {
         FillSelectedTradeFromPendingOrder(ticket);
         return true;
      }

      BuildClosedTradeCache();
      for(int historyIndex=0;historyIndex<closedTradeCount;historyIndex++)
      {
         if(closedTradeTicket[historyIndex]!=ticket)
            continue;
         FillSelectedTradeFromHistory(historyIndex);
         return true;
      }
      return false;
   }

   if(pool==TRADE_POOL_HISTORY)
   {
      BuildClosedTradeCache();
      if(indexOrTicket<0 || indexOrTicket>=closedTradeCount)
         return false;
      FillSelectedTradeFromHistory((int)indexOrTicket);
      return true;
   }

   int positionCount=PositionsTotal();
   if(indexOrTicket>=0 && indexOrTicket<positionCount)
   {
      ulong positionTicket=PositionGetTicket((int)indexOrTicket);
      if(positionTicket==0)
         return false;
      FillSelectedTradeFromPosition((long)positionTicket);
      return true;
   }

   long orderIndex64=indexOrTicket-positionCount;
   int pendingOrderCount=::OrdersTotal();
   if(orderIndex64>=0 && orderIndex64<pendingOrderCount)
   {
      ulong orderTicket=::OrderGetTicket((int)orderIndex64);
      if(orderTicket==0)
         return false;
      FillSelectedTradeFromPendingOrder((long)orderTicket);
      return true;
   }
   return false;
}

long            SelectedTradeTicket()      { return selectedTrade.ticket; }
string          SelectedTradeSymbol()      { return selectedTrade.symbol; }
ENUM_ORDER_TYPE SelectedTradeType()        { return selectedTrade.type; }
double          SelectedTradeVolume()      { return selectedTrade.volume; }
double          SelectedTradeOpenPrice()   { return selectedTrade.openPrice; }
double          SelectedTradeClosePrice()  { return selectedTrade.closePrice; }
double          SelectedTradeStopLoss()    { return selectedTrade.stopLoss; }
double          SelectedTradeTakeProfit()  { return selectedTrade.takeProfit; }
datetime        SelectedTradeOpenTime()    { return selectedTrade.openTime; }
datetime        SelectedTradeCloseTime()   { return selectedTrade.closeTime; }
datetime        SelectedTradeExpiration()  { return selectedTrade.expiration; }
double          SelectedTradeProfit()      { return selectedTrade.profit; }
double          SelectedTradeSwap()        { return selectedTrade.swap; }
double          SelectedTradeCommission()  { return selectedTrade.commission; }
string          SelectedTradeComment()     { return selectedTrade.comment; }
long            SelectedTradeMagic()       { return selectedTrade.magic; }


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
input string lijntje="=============================================================="  ;   //- - -
input bool UseVariableValues=true  ;   
input bool AdjustLotsizeToVariableValues=true  ;   
input bool ShowInfoPanel=true  ;   
input bool UpdateInfoTesting=false ;    //update infopanel during testing
input double InfoPanelSizeAdjust=1  ;    //Adjustment for Infopanel size
input int   SetFontSize=0  ;
input string spreadfilter="------------------------------ Settings ------------------------------"  ;   //- - -
input bool AllowBuyTrades=true  ;    //Allow Buy Trades
input bool AllowSellTrades=true  ;    //Allow Sell Trades
input  enum_TradeFrequency  TradeFrequency=5  ;   
input double MaxSpread=500  ;    //Maximum allowed spread
input bool UseHL_TrailingSL=true  ;   
input int   FridayStopHour=25  ;    //Friday stop hour (brokertime; close all trades)
input bool FridayClosePending=true  ;
input bool FridayCloseOpen=true  ;
input bool setSL_TP_After_Entry=false ;   
input bool Virtual_expiration=true  ;    //Use Virtual Expiration
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
input double ManualBalance=0  ;    //manually set balance to use (if > 0)
input  e_Risk  Risk=1234  ;    //Lotsize Calculation method
input double StartLots=0.01  ;   
double startLots_rw=0.0;
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
  double    currentSpreadPrice = 0.0;
  double    unusedLegacyDouble002 = 0.0;
  int       unusedLegacyInt003 = 30;
  int       unusedLegacyInt004 = 1440;
  int       unusedLegacyInt005 = 0;
  double    unusedLegacyDoubleArray006[];
  double    lotSizeReferenceBalance = 0.0;
  double    variableValueScaleFactor = 0.0;
  double    variableLotInverseScaleFactor = 0.0;
  bool      unusedLegacyBool010 = false;
  int       unusedLegacyInt011 = 3;
  int       unusedLegacyInt012 = 2;
  bool      unusedLegacyBool013 = false;
  bool      unusedLegacyBool014 = false;
  int       randomizedPendingEntryOffsetPips = 0;
  string    tradingFiltersHeader = "------------------------------ trading filters ------------------------------";
  bool      oneChartSetupEnabled = false;
  string    oneChartSymbolList = "EURUSD;GBPUSD;USDJPY;AUDJPY;AUDUSD;EURAUD;EURCAD;EURGBP;EURJPY;GBPJPY;USDCAD;USDCHF;";
  int       activeTradeFrequency = 5;
  bool      enableStrategy1 = true;
  bool      unusedLegacyBool021 = false;
  bool      unusedLegacyBool022 = false;
  bool      enableStrategy2 = true;
  bool      unusedLegacyBool024 = false;
  bool      unusedLegacyBool025 = false;
  bool      enableStrategy3 = true;
  bool      enableStrategy4 = false;
  bool      enableStrategy6 = false;
  bool      unusedLegacyBool029 = false;
  bool      unusedLegacyBool030 = false;
  bool      enableStrategy5 = false;
  bool      enableStrategy9 = false;
  bool      enableStrategy7 = false;
  bool      enableStrategy8 = false;
  bool      suspendPendingOrdersOnHighSpread = true;
  int       minPendingMarketGapPips = 2;
  double    maxSpreadPips = 0.0;
  double    orderSlippageSetting = 5000.0;
  int       slippageControlMode = 1;
  double    slippageRecoveryTriggerPips = 400.0;
  double    slippageRecoveryTrailDistancePips = 100.0;
  double    slippageRecoveryMaximumStopPips = 300.0;
  bool      useRequestedEntryAsTrailReference = true;
  string    timeFiltersHeader = "------------------------------ time filters ------------------------------";
  bool      fridayStopEnabled = false;
  bool      restorePendingOrdersAfterFridayPause = false;
  bool      unusedLegacyBool047 = false;
  int       unusedLegacyInt048 = 14;
  int       unusedLegacyInt049 = 17;
  string    otherFiltersHeader = "------------------------------ other filters ------------------------------";
  int       candleExitOpenBarShift = 1;
  int       candleExitM1TimeframeMinutes = 1;
  bool      candleExitM1Enabled = false;
  int       candleExitM5TimeframeMinutes = 5;
  bool      candleExitM5Enabled = false;
  int       candleExitM15TimeframeMinutes = 15;
  bool      candleExitM15Enabled = false;
  int       candleExitM30TimeframeMinutes = 30;
  bool      candleExitM30Enabled = false;
  int       candleExitH1TimeframeMinutes = 60;
  bool      candleExitH1Enabled = false;
  bool      showTradeDebugComments = false;
  int       tradeMonitorFilterMode = 1;
  double    extraStopLossPips = 0.0;
  int       virtualStopSyncIntervalSeconds = 99;
  int       unusedLegacyInt066 = 5;
  bool      virtualPendingOrdersEnabled = false;
  int       dayChangeRecoveryDelayMinutes = 5;
  int       entryStrategyMode = 1;
  string    entryManagementHeader = "------------------------------ Trade Entry management ------------------------------";
  int       signalTimeframeMinutes = 0;
  int       entryTimingTimeframeMinutes = 60;
  int       swingLeftBars = 10;
  int       swingRightBars = 3;
  bool      fakeoutConfirmationEnabled = false;
  bool      unusedLegacyBool076 = false;
  int       entryLookbackBars = 120;
  int       unusedLegacyInt078 = 0;
  int       unusedLegacyInt079 = 0;
  double    minEntryDistancePips = 30.0;
  double    minimumEntryDistancePercent = 0.0;
  double    unusedLegacyDouble082 = 25.0;
  double    buyEntryOffsetPips = 0.5;
  double    sellEntryOffsetPips = 0.0;
  double    requestedEntryAdjustmentPips = 0.0;
  int       maxPendingOrders = 1;
  int       maxOpenTradesPerSide = 99;
  double    duplicatePendingTolerancePips = 1.0;
  int       pendingExpirationHours = 24;
  double    unusedLegacyDouble090 = 3.0;
  int       unusedLegacyInt091 = 0;
  int       lotSizePercentMultiplier = 100;
  int       strategyMagicNumber = 0;
  string    manualStrategy2Header = "------------------------------ Strategy 2 - Manual Trade settings ------------------------------";
  int       manualTradeSymbolFilterMode = 1;
  int       manualStrategy2MagicNumber = 1991199118;
  string    manualStrategy2Comment = "";
  string    exitManagementHeader = "------------------------------ Trade Exit management ------------------------------";
  int       exitTimingMode = 0;
  double    stopLossPips = 20.0;
  double    takeProfitPips = 100.0;
  string    trailingStopHeader = "------------------------------ Trailing SL settings ------------------------------";
  double    trailingSLStartPips = 10.0;
  double    trailingSLDistancePips = 10.0;
  double    trailingSLStepLimitPips = 100.0;
  double    trailingActivationBufferPips = 0.1;
  double    trailingPartialClosePercent = 0.0;
  double    trailingTPStartPips = 0.0;
  double    trailingTPDistancePips = 0.0;
  double    unusedLegacyDouble110 = 0.0;
  double    unusedLegacyDouble111 = 0.0;
  string    breakEvenHeader = "------------------------------ Break-even SL management ------------------------------";
  double    breakEvenStartPips = 0.0;
  double    breakEvenExtraPips = 0.0;
  string    highLowTrailingHeader = "------------------------------ HIGH/LOW Trailing SL settings ------------------------------";
  bool      highLowTrailingEnabled = false;
  int       highLowTrailingTimeframeMinutes = 0;
  int       swingQualificationMinimumShift = 0;
  int       highLowLeftBars = 0;
  int       highLowRightBars = 0;
  int       highLowLookbackBars = 0;
  int       highLowMinimumMarketGapPips = 0;
  double    highLowTrailingOffsetPips = 2.0;
  string    timeRecoveryTrailingHeader = "------------------------------ recovery Trailing SL based on time ------------------------------";
  double    timeRecoveryAfterMinutes = 0.0;
  double    timeRecoveryStopPips = 0.0;
  string    magicTrailHeader = "------------------------------ MagicTrail SL settings ------------------------------";
  int       magicTrailMode = 0;
  double    magicTrailActivationDistancePips = 0.1;
  int       magicTrailMinimumTickCount = 1;
  double    magicTrailStepPips = 0.1;
  double    magicTrailMode2SpreadBufferPips = 1.0;
  int       magicTrailDelayMinutes = 0;
  double    magicTrailDelayedActivationPips = 0.0;
  bool      returnAfterStopModification = false;
  bool      unusedLegacyBool136 = false;
  int       licenseYearMarker = 2024;
  datetime  monthBoundaryDates[13];
  bool      dynamicLotSizingEnabled = false;
  double    pendingLotResizeThresholdPercent = 5.0;
  double    maxCalculatedLotSize = 99.0;
  int       unusedLegacyInt142 = 999;
  int       unusedLegacyInt143 = 9999;
  int       unusedLegacyInt144 = 99999;
  int       lotSizingBalanceDivisor = 600;
  double    weightedRiskPercentPerStrategy = 1.0;
  double    unusedLegacyDouble147 = 10.0;
  double    fixedRiskPercent = 2.0;
  string    performanceHeader = "==== Performance numbers overview ====";
  bool      showPerformanceOverview = true;
  int       performanceCalculationMode = 1;
  int       strategyRankingMode = 1;
  int       performanceLookbackDays = 90;
  int       recentPerformanceDays = 30;
  int       minTradesForPerformance = 10;
  int       unusedLegacyInt156 = 50;
  bool      unusedLegacyBool157 = true;
  string    zoneRecoveryHeader = "------------------------------ zone_recovery_settings ------------------------------";
  bool      zoneRecoveryEnabled = false;
  double    zoneRecoveryInitialDistancePips = 50.0;
  double    zoneRecoveryStepDistancePips = 10.0;
  double    zoneRecoveryMinimumDistancePips = 5.0;
  double    zoneRecoveryProfitTarget = 0.0;
  int       zoneRecoveryLotSizingMode = 1;
  double    zoneRecoveryLotMultiplier = 2.0;
  int       zoneRecoveryMaximumTrades = 999;
  double    unusedLegacyDouble167 = 100.0;
  int       zoneRecoveryBuyMagic = 900010;
  int       zoneRecoverySellMagic = 900011;
  string    tradingHoursHeader = "------------------------- Trading hours ST1 -------------------------";
  bool      tradingHoursEnabled = false;
  int       tradingHoursTimeSource = 2;
  bool      storePendingOrdersOutsideTradingHours = false;
  int       sundayStartHour = 0;
  int       sundayEndHour = 24;
  int       mondayStartHour = 0;
  int       mondayEndHour = 24;
  int       tuesdayStartHour = 0;
  int       tuesdayEndHour = 24;
  int       wednesdayStartHour = 0;
  int       wednesdayEndHour = 24;
  int       thursdayStartHour = 0;
  int       thursdayEndHour = 24;
  int       fridayStartHour = 0;
  int       fridayEndHour = 24;
  string    backtestOnlyHeader = "------------------------- use for backtesting only! -------------------------";
  int       randomPendingOffsetMaximumPips = 0;
  double    cachedBuySignalPrice = 0.0;
  double    cachedSellSignalPrice = 0.0;
  int       symbolDigits = 0;
  double    activeVirtualStopPrice = 0.0;
  int       buyZoneNextOrderSide = 0;
  int       sellZoneNextOrderSide = 0;
  bool      buyZoneStateInitialized = false;
  bool      sellZoneStateInitialized = false;
  double    virtualStopByTicket[20][2];
  double    storedPendingOrders[100][3];
  double    pendingTicketPriceMap[100][2];
  int       smallBufferCapacity = 20;
  int       orderBufferCapacity = 100;
  double    legacyWriteOnlyTradeStateValuePrimary = 0.0;
  double    legacyWriteOnlyTradeStateValueSecondary = 0.0;
  double    unusedLegacyDouble203 = 0.0;
  double    unusedLegacyDouble204 = 0.0;
  double    unusedLegacyDouble205 = 0.0;
  double    unusedLegacyDouble206 = 0.0;
  bool      unusedLegacyBool207 = false;
  int       unusedLegacyInt208 = 10;
  double    legacyWriteOnlyUpperPriceSentinel = 0.0;
  double    legacyWriteOnlyLowerPriceSentinel = 0.0;
  double    unusedLegacyDouble211 = 0.0;
  double    unusedLegacyDouble212 = 0.0;
  bool      movingAverageTrendFilterEnabled = false;
  int       fastMovingAveragePeriod = 1;
  datetime  lastSignalBarTimeByStrategy[99];
  long      legacyWriteOnlyOrderTicket = 0;
  int       slowMovingAveragePeriod = 370;
  bool      allowMultipleOpenTradesPerSide = true;
  bool      unusedLegacyBool219 = false;
  int       unusedLegacyInt220 = 0;
  double    stopLevelPriceDistance = 4.0;
  double    unusedLegacyDouble222 = 0.0;
  double    lotSizeByStrategy[99];
  double    unusedLegacyDouble224 = 0.0;
  int       unusedLegacyInt225 = 0;
  int       unusedLegacyInt226 = 0;
  double    unusedLegacyDouble227 = 0.0;
  double    unusedLegacyDouble228 = 0.0;
  double    pipSize = 0.0;
  long      lastTradeTicket = 0; // ticket OrderSend la 64-bit; bool OrderModify van gan duoc 0/1
  bool      legacyWriteOnlyFractalStateFlag = false;
  double    unusedLegacyDouble232 = 0.0;
  double    unusedLegacyDouble233 = 0.0;
  int       pendingExpirationSeconds = 0;
  double    unusedLegacyDouble235 = 0.0;
  double    unusedLegacyDouble236 = 0.0;
  double    unusedLegacyDouble237 = 0.0;
  bool      legacyWriteOnlyOrderStateFlagPrimary = false;
  bool      legacyWriteOnlyOrderStateFlagSecondary = false;
  bool      legacyWriteOnlyTradeStateFlag = false;
  double    buyTriggerPriceByStrategy[99];
  double    sellTriggerPriceByStrategy[99];
  double    unusedLegacyDouble243 = 0.0;
  double    unusedLegacyDouble244 = 0.0;
  double    unusedLegacyDouble245 = 0.0;
  double    unusedLegacyDouble246 = 0.0;
  double    activeMagicTrailActivationPips = 0.0;
  double    unusedLegacyDouble248 = 0.0;
  double    unusedLegacyDouble249 = 0.0;
  int       magicTrailTickCounter = 0;
  double    legacyWriteOnlyInitializationTimestamp = 0.0;
  string    buyComment1;
  string    buyComment2;
  string    sellComment1;
  string    sellComment2;
  bool      marketPauseMessageLogged = false;
  bool      legacyWriteOnlyInitializationFlag = false;
  int       legacyWriteOnlyInitializationMonth = 0;
  int       unusedLegacyInt259 = 0;
  double    legacyWriteOnlyInitializationSecond = 0.0;
  double    currentSellEntryPrice = 0.0;
  double    currentBuyEntryPrice = 0.0;
  double    lastSellSignalCandidatePrice = 0.0;
  double    lastBuySignalCandidatePrice = 0.0;
  int       buySignalBarShift = 0;
  int       sellSignalBarShift = 0;
  int       lastEntryHour = 0;
  double    fastMovingAverageValue = 0.0;
  double    slowMovingAverageValue = 0.0;
  double    previousUpperFractal = 0.0;
  double    previousLowerFractal = 0.0;
  double    currentUpperFractal = 0.0;
  double    currentLowerFractal = 0.0;
  int       errorDescriptionCallCount = 0;
  double    legacyWriteOnlyFractalStateValue = 0.0;
  double    unusedLegacyDouble276 = 0.0;
  double    unusedLegacyDouble277 = 0.0;
  bool      legacyWriteOnlyVirtualBuyPendingFlag = false;
  bool      legacyWriteOnlyVirtualSellPendingFlag = false;
  bool      buyPendingRestoreState = false;
  bool      sellPendingRestoreState = false;
  bool      unusedLegacyBool282 = false;
  bool      unusedLegacyBool283 = false;
  double    unusedLegacyDouble284 = 0.0;
  double    unusedLegacyDouble285 = 0.0;
  bool      unusedLegacyBool286 = false;
  double    unusedLegacyDouble287 = 0.0;
  double    unusedLegacyDouble288 = 0.0;
  int       legacyWriteOnlyInitializationCounter = 0;
  int       legacyWriteOnlyInitializationHour = 0;
  double    unusedLegacyDoubleArray291[10];
  double    unusedLegacyDoubleArray292[10];
  double    unusedLegacyDoubleArray293[10];
  double    unusedLegacyDoubleArray294[10];
  int       unusedLegacyInt295 = 0;
  int       unusedLegacyInt296 = 0;
  int       legacyWriteOnlyCommentStateCounterPrimary = 0;
  int       legacyWriteOnlyCommentStateCounterSecondary = 0;
  string    symbolSuffix;
  double    legacyWriteOnlyEntryStateValuePrimary = 0.0;
  double    legacyWriteOnlyEntryStateValueSecondary = 0.0;
  datetime  pendingOrderExpirationTime = 0;
  bool      tradingHoursState = false;
  int       timeRecoveryDelaySeconds = 0;
  bool      fridayTradingSuspended = false;
  int       currentChartBars = 0;
  double    initialAccountBalance = 0.0;
  double    unusedLegacyDouble308 = 0.0;
  double    freezeLevelPriceDistance = 0.0;
  double    lastBuyPendingBasePrice = 0.0;
  double    lastSellPendingBasePrice = 0.0;
  bool      demoAccountDetectedFlag = false;
  datetime  legacyWriteOnlyPreviousWeeklyBarTime = 0;
  datetime  legacyWriteOnlyPreviousMonthlyBarTimePrimary = 0;
  datetime  legacyWriteOnlyPreviousMonthlyBarTimeSecondary = 0;
  bool      unusedLegacyBool316 = false;
  bool      unusedLegacyBool317 = false;
  double    lastLotResizeBalance = 0.0;
  datetime  lastVirtualStopSyncTime = 0;
  bool      nfpTradingSuspended = false;
  int       lastExitBarCountByStrategy[99];
  int       lastEntryBarCountByStrategy[99];
  double    openProfitByStrategy[30];
  double    winningTradesByStrategy[30];
  double    losingTradesByStrategy[30];
  double    closedProfitByStrategy[30];
  int       unusedLegacyInt327 = 1;
  int       currentStrategyIndex = 0;
  uint      panelTextColor = DarkBlue;
  bool      unusedLegacyBool330 = false;
  long      unusedLegacyLong331 = 0;
  int       unusedLegacyInt332 = 5;
  bool      unusedLegacyBool333 = false;
  string    currentStrategyComment;
  bool      unusedLegacyBool335 = false;
  string    currentSymbol;
  double    symbolPoint = 0.0;
  double    unusedLegacyDouble338 = 0.0;
  int       rankedStrategyIndexes[99];
  int       panelStrategyRowStartIndex = 0;
  double    unusedLegacyDoubleArray341[99];
  bool      performanceHistoryComplete[99];
  int       totalTradeCountByStrategy[99];
  int       recentTradeCountByStrategy[99];
  double    averageProfitByStrategy[99];
  double    recentAverageProfitByStrategy[99];
  string    strategySymbols[99]={};
  bool      unusedLegacyBoolArray348[99];
  double    totalProfitByStrategy[99];
  double    recentProfitByStrategy[99];
  double    unusedLegacyDoubleArray351[99];
  double    unusedLegacyDoubleArray352[99];
  double    unusedLegacyDoubleArray353[99];
  double    strategyLotWeights[99];
  bool      unusedLegacyBoolArray355[99];
  int       strategyRanks[99];
  bool      unusedLegacyBool357 = false;
  double    legacyWriteOnlyPanelSpacingPrimary = 5.0;
  double    legacyWriteOnlyPanelSpacingSecondary = 10.0;
  int       panelObjectCount = 0;
  double    panelRowWidth = 0.0;
  double    panelRowHeight = 0.0;
  int       legacyWriteOnlyPanelColumnCount = 0;
  uint      panelCellBackgroundColor = LightSteelBlue;
  bool      unusedLegacyBool365 = true;
  double    unusedLegacyDouble366 = 12.0;
  int       unusedLegacyInt367 = 230;
  int       unusedLegacyInt368 = 320;
  int       unusedLegacyInt369 = 500;
  int       unusedLegacyInt370 = 350;
  int       unusedLegacyInt371 = 2;
  int       panelFontSize = 7;
  int       unusedLegacyInt373 = 10;
  int       unusedLegacyInt374 = 30;
  string    unusedLegacyStringArray375[4]={};
  double    panelWidthScaleFactor = 0.45;
  double    panelHeightScaleFactor = 0.6;
  int       strategySymbolCount = 0;
  datetime  lastPanelRefreshM5BarTime = 0;
  bool      pairInitializationSucceeded = false;
  int       panelRefreshTickCounter = 0;
  bool      dailyDrawdownLockActive = false;
  int       lastDailyBarCount = 0;
  double    dailyDrawdownReference = 0.0;
  int       autoFrequencyThreshold1 = 200;
  int       autoFrequencyThreshold2 = 330;
  int       autoFrequencyThreshold3 = 560;
  int       autoFrequencyThreshold4 = 810;
  int       autoFrequencyThreshold5 = 1150;
  datetime  currentGmtTime = 0;
  datetime  nfpDatesGmt[300];
  bool      usDaylightSavingState = false;
  bool      europeDaylightSavingState = false;
  bool      gmtDetectionInitialized = false;
  int       brokerGmtOffsetHours = 0;
  int       detectedUtcOffsetHours = 0;
  double    strategyDrawdownReferenceUsd = 0.0;
  double    enabledStrategyRiskWeight = 0.0;
  datetime  lastPerformanceRefreshH1BarTime = 0;
  double    strategyDisplayProfit[99];
  double    currentBalanceBasis = 0.0;
  double    highestBalanceBasis = 0.0;
  bool      nfpFromCalendar = false;      // true neu nfpDatesGmt[] dang lay tu Lich MQL5 (khong con dung mang hardcode)
  datetime  nfpCalendarBuiltDay = 0;      // ngay (00:00, GMT) lan gan nhat da thu lam moi tu Lich MQL5
  int       nfpStatus = 0;                // trang thai lay tin NFP cho panel: 0 = binh thuong (dung nfpDatesGmt[]), 2 = loi lay tin (Lich MQL5 khong doc duoc). mq5 dung Lich (khong co link) nen khong co trang thai thieu link (=1)
  long      onlyUpRunId = 0;              // ma rieng cho moi lan chay Strategy Tester, dung de tach biet dinh OnlyUp giua cac lan backtest (xem OnlyUpPeakGVName)
  long      onlyUpWithdrawScannedMsc = 0;  // moc DEAL_TIME_MSC da xu ly, tranh tru lap giao dich rut tien sau khi EA khoi dong lai

//+------------------------------------------------------------------+
//| Lay ngay NFP (Non-Farm Payrolls) tu Lich kinh te (Economic       |
//| Calendar) co san cua MQL5, thay cho mang nfpDatesGmt[]   |
//| ma hoa cung. Neu khong tim/lay duoc (vi du: khong kha dung trong |
//| Strategy Tester cua broker nay) thi GIU NGUYEN mang hardcode co  |
//| san de kiem thu nguoc (backtest) van chay binh thuong.           |
//+------------------------------------------------------------------+
 void BuildNFPDatesFromCalendar()
 {
  nfpCalendarBuiltDay = (datetime)(TimeCurrent() - TimeCurrent() % SECONDS_PER_DAY) ;
  MqlCalendarEvent calendarEvents[];
  int       calendarEventCount = CalendarEventByCountry("US",calendarEvents) ;
  long      nonfarmPayrollEventId = -1;
  int       calendarItemIndex;
  string    normalizedEventCode;
//----------------------------------------------------------------------
 if ( calendarEventCount <= 0 )   { nfpStatus = 2 ; return; } // Lich MQL5 khong doc duoc -> panel bao loi lay tin
 for (calendarItemIndex = 0 ; calendarItemIndex < calendarEventCount ; calendarItemIndex ++)
 {
   // MqlCalendarEvent.name tra ve theo NGON NGU CUA TERMINAL (tai lieu MQL5)
   // nen so sanh chuoi tieng Anh co the khong bao gio khop neu terminal dat
   // ngon ngu khac. event_code moi la ma dinh danh CO DINH, khong phu thuoc
   // ngon ngu (vi du "NONFARM-PAYROLLS") - dung field nay lam chinh, giu lai
   // kiem tra .name nhu du phong.
   normalizedEventCode = calendarEvents[calendarItemIndex].event_code ;
   StringToUpper(normalizedEventCode) ;
   if ( StringFind(normalizedEventCode,"NONFARM") >= 0 || StringFind(calendarEvents[calendarItemIndex].name,"Nonfarm Payrolls") >= 0 || StringFind(calendarEvents[calendarItemIndex].name,"Non-Farm Payrolls") >= 0 || StringFind(calendarEvents[calendarItemIndex].name,"Non Farm Payrolls") >= 0 )
   {
     nonfarmPayrollEventId = (long)calendarEvents[calendarItemIndex].id ;
     break;
   }
 }
 if ( nonfarmPayrollEventId < 0 )   { nfpStatus = 2 ; return; } // khong tim thay su kien NFP trong Lich -> loi lay tin
 MqlCalendarValue calendarValues[];
 datetime  calendarHistoryStart = D'2007.01.01 00:00';
 datetime  calendarHistoryEnd = TimeCurrent() + 400 * 24 * 60 * 60 ;
 int       calendarValueCount = CalendarValueHistoryByEvent((ulong)nonfarmPayrollEventId,calendarValues,calendarHistoryStart,calendarHistoryEnd) ;
 if ( calendarValueCount <= 0 )   { nfpStatus = 2 ; return; } // khong lay duoc gia tri lich NFP -> loi lay tin
 // currentGmtTime (GMT hien tai) da duoc tinh xong truoc khi ham nay duoc goi (xem
 // OnTick). MqlCalendarValue.time tra ve theo GIO SERVER, trong khi
 // nfpDatesGmt[] va toan bo bo loc NFP con lai dang quy uoc luu GIO GMT roi
 // moi cong offset de quy doi sang gio server luc so sanh/hien thi. TimeCurrent()-
 // currentGmtTime chinh la offset GMT bo loc dang dung tai thoi diem nay (du la tu
 // AutoGMT/WebRequest thanh cong hay phai roi ve TimeGMT()), nen dung gia tri nay de
 // tru truoc khi luu, tranh bi quy doi 2 lan.
 long      serverToGmtOffsetSeconds = (long)(TimeCurrent() - currentGmtTime) ;
 int       validNfpDateCount = 0;
 for (calendarItemIndex = 0 ; calendarItemIndex < calendarValueCount && validNfpDateCount < 300 ; calendarItemIndex ++)
 {
   if ( calendarValues[calendarItemIndex].time <= 0 )   continue;
   nfpDatesGmt[validNfpDateCount] = (datetime)(calendarValues[calendarItemIndex].time - serverToGmtOffsetSeconds) ;
   validNfpDateCount ++;
 }
 if ( validNfpDateCount <= 0 )   { nfpStatus = 0 ; return; } // lay tin OK nhung khong co ngay hop le -> "No News Coming Up"
 for (calendarItemIndex = validNfpDateCount ; calendarItemIndex < 300 ; calendarItemIndex ++)   nfpDatesGmt[calendarItemIndex] = 0 ;
 nfpFromCalendar = true ;
 nfpStatus = 0 ; // lay Lich thanh cong -> panel hien binh thuong (Next NFP / No News)
 }
//BuildNFPDatesFromCalendar <<==--------   --------

//+------------------------------------------------------------------+
//| Dieu chinh dinh OnlyUp khi tai khoan co giao dich rut tien.       |
//| Trong MT5, nap/rut tien duoc ghi thanh DEAL_TYPE_BALANCE; rut     |
//| tien co DEAL_PROFIT am. Dinh cu phai giam dung bang so tien rut,  |
//| nhung khong duoc thap hon balance/equity hien tai.                |
//+------------------------------------------------------------------+
 void ApplyOnlyUpWithdrawal(double amount)
 {
  if ( !(OnlyUp) || ManualBalance>0.0 || amount>=0.0 )   return;
  highestBalanceBasis = highestBalanceBasis + amount ; // amount am => tru tien rut khoi dinh
  double currentOnlyUpBasisValue = AccountInfoDouble(ACCOUNT_BALANCE) ;
  if ( UseEquity )   currentOnlyUpBasisValue = AccountInfoDouble(ACCOUNT_EQUITY) ;
  if ( highestBalanceBasis<currentOnlyUpBasisValue )   highestBalanceBasis = currentOnlyUpBasisValue ;
  if ( highestBalanceBasis<0.0 )   highestBalanceBasis = 0.0 ;
  GlobalVariableSet(OnlyUpPeakGVName(),highestBalanceBasis) ;
 }
//ApplyOnlyUpWithdrawal <<==--------   --------

//+------------------------------------------------------------------+
//| Doc cac giao dich rut tien bi bo lo khi EA/MT5 khong chay.        |
//| Moc quet luu theo mili-giay vi GlobalVariable kieu double van luu |
//| chinh xac DEAL_TIME_MSC (~10^12), dong thoi tranh xu ly lap.      |
//+------------------------------------------------------------------+
 void ReconcileOnlyUpWithdrawals()
 {
  if ( !(OnlyUp) || ManualBalance>0.0 )   return;
  long reconcileTimestampMsc = (long)TimeCurrent() * 1000 ;
  if ( onlyUpWithdrawScannedMsc<=0 )
  {
    onlyUpWithdrawScannedMsc = reconcileTimestampMsc ;
    GlobalVariableSet(OnlyUpWithdrawGVName(),(double)onlyUpWithdrawScannedMsc) ;
    return;
  }
  datetime historyScanStart = (datetime)(onlyUpWithdrawScannedMsc / 1000) ;
  datetime historyScanEnd = TimeCurrent() ;
  if ( historyScanStart>historyScanEnd )   historyScanStart = historyScanEnd ;
  if ( !(HistorySelect(historyScanStart,historyScanEnd)) )   return;
  int historyDealCount = HistoryDealsTotal() ;
  double withdrawalTotal = 0.0 ;
  long latestProcessedDealMsc = onlyUpWithdrawScannedMsc ;
  for (int historyDealIndex = 0 ; historyDealIndex < historyDealCount ; historyDealIndex ++)
  {
    ulong historyDealTicket = HistoryDealGetTicket(historyDealIndex) ;
    if ( historyDealTicket==0 )   continue;
    long historyDealTimeMsc = (long)HistoryDealGetInteger(historyDealTicket,DEAL_TIME_MSC) ;
    if ( historyDealTimeMsc<=onlyUpWithdrawScannedMsc )   continue;
    if ( historyDealTimeMsc>latestProcessedDealMsc )   latestProcessedDealMsc = historyDealTimeMsc ;
    ENUM_DEAL_TYPE historyDealType = (ENUM_DEAL_TYPE)HistoryDealGetInteger(historyDealTicket,DEAL_TYPE) ;
    if ( historyDealType!=DEAL_TYPE_BALANCE )   continue;
    double historyDealAmount = HistoryDealGetDouble(historyDealTicket,DEAL_PROFIT) ;
    if ( historyDealAmount<0.0 )   withdrawalTotal = withdrawalTotal + historyDealAmount ;
  }
  if ( withdrawalTotal<0.0 )   ApplyOnlyUpWithdrawal(withdrawalTotal) ;
  if ( reconcileTimestampMsc>latestProcessedDealMsc )   latestProcessedDealMsc = reconcileTimestampMsc ;
  onlyUpWithdrawScannedMsc = latestProcessedDealMsc ;
  GlobalVariableSet(OnlyUpWithdrawGVName(),(double)onlyUpWithdrawScannedMsc) ;
 }
//ReconcileOnlyUpWithdrawals <<==--------   --------

 int OnInit()
 {
trade.SetAsyncMode(false);
trade.LogLevel(LOG_LEVEL_NO);

// Guard bat buoc cho MT5: EA dung DCA/grid (nhieu lenh cung chieu tren cung
// XAUUSD ton tai doc lap). tai khoan hedging cho phep nhieu vi the doc lap nen ban goc khong
// can kiem tra gi. Ben MT5, neu tai khoan dang o che do Netting thi lenh
// DCA thu 2/3/... se tu dong GOP vao vi the dau tien (cong don volume) thay
// vi ton tai rieng - pha vo hoan toan logic quan ly virtual stop/tung lenh
// rieng cua EA. Chan EA chay ngay tu OnInit() de tranh "chay am tham sai"
// ma nguoi dung khong biet.
if(AccountInfoInteger(ACCOUNT_MARGIN_MODE)!=ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
{
   Alert("The Gold Reaper: tai khoan dang o che do NETTING. EA nay bat buoc phai chay tren tai khoan Hedging (MT5) vi dung DCA/grid nhieu lenh cung chieu. Vao MT5 -> mo tai khoan Hedging hoac lien he broker de doi che do, roi gan lai EA.");
   return(INIT_FAILED);
}

startLots_rw=StartLots;
  double    accountBalanceUsd;
  double    allowedDrawdownUsd;
  int       riskBufferRowIndex;
  int       virtualStopFieldIndex;
  int       storedOrderRowIndex;
  int       storedOrderFieldIndex;
  int       storedOrderResetIndex;
  int       strategyInitializationIndex;
//----------------------------------------------------------------------
 // Bien local can duoc khoi tao ro rang de giu hanh vi xac dinh
 // ro rang de giu dung hanh vi ban goc (bien nay khong duoc gan truoc khi
 // dung o duoi, ket qua nhan dien demo duoc co y bo qua trong logic goc).
 bool       ignoredDemoDetectionResult = false;

 // Sinh ma rieng cho lan chay Strategy Tester nay (xem OnlyUpPeakGVName) -
 // GetTickCount() (mili-giay tu luc terminal khoi dong) + so ngau nhien de
 // moi lan backtest deu co ma khac nhau, tranh trung khi nhieu agent toi uu
 // hoa chay song song va bat dau o cung mot thoi diem. MathRand() bat buoc
 // phai MathSrand() truoc thi moi cho ra chuoi so khac nhau giua cac lan
 // chay (theo tai lieu MQL5) - neu khong se luon ra cung 1 gia tri co dinh
 // moi lan khoi dong, lam mat tac dung chong trung.
 // SetFontSize >0: ghi de co chu panel (0 = co mac dinh theo thiet ke goc)
 if ( SetFontSize > 0 )   panelFontSize = SetFontSize ;
 MathSrand((int)GetTickCount()) ;
 onlyUpRunId = (long)GetTickCount() * 1000 + MathRand() ;

 currentBalanceBasis = AccountInfoDouble(ACCOUNT_BALANCE) ;
 if ( UseEquity )
 {
   currentBalanceBasis = AccountInfoDouble(ACCOUNT_EQUITY) ;
 }
 if ( ManualBalance>0.0 )
 {
   currentBalanceBasis = ManualBalance ;
 }
 // OnlyUp cai tien: doc lai muc so du cao nhat da luu trong GlobalVariable
 // cua terminal (ton tai xuyen suot restart EA/MT5), thay vi luon reset ve
 // so du hien tai moi lan khoi dong nhu truoc - tranh mat muc dinh cao da
 // dat duoc truoc do.
 // ResetHighestBalance: xoa ca dinh va moc quet rut tien, bat dau lai tu
 // balance/equity hien tai va khong tru lai cac lan rut tien cu.
 if ( ResetHighestBalance )
 {
   GlobalVariableDel(OnlyUpPeakGVName()) ;
   GlobalVariableDel(OnlyUpWithdrawGVName()) ;
 }
 bool storedOnlyUpPeakExists = (OnlyUp && GlobalVariableCheck(OnlyUpPeakGVName())) ;
 datetime storedOnlyUpPeakSaveTime = 0 ;
 if ( storedOnlyUpPeakExists )   storedOnlyUpPeakSaveTime = GlobalVariableTime(OnlyUpPeakGVName()) ;
 if ( storedOnlyUpPeakExists )
 {
   highestBalanceBasis = GlobalVariableGet(OnlyUpPeakGVName()) ;
 }
 else
 {
   highestBalanceBasis = currentBalanceBasis ;
 }
 if ( OnlyUp )
 {
   // Ban moi da co moc quet rieng. Khi nang cap tu ban cu, dung thoi diem dinh
   // da duoc luu lam moc dau de co the bu lai cac lan rut tien xay ra sau do.
   if ( GlobalVariableCheck(OnlyUpWithdrawGVName()) )
   {
     onlyUpWithdrawScannedMsc = (long)GlobalVariableGet(OnlyUpWithdrawGVName()) ;
   }
   else
   {
     if ( storedOnlyUpPeakExists && storedOnlyUpPeakSaveTime>0 )
       onlyUpWithdrawScannedMsc = (long)storedOnlyUpPeakSaveTime * 1000 ;
     else
       onlyUpWithdrawScannedMsc = (long)TimeCurrent() * 1000 ;
   }
   ReconcileOnlyUpWithdrawals() ;
   // Neu balance/equity hien tai da tao dinh moi (vi du sau loi nhuan hoac nap
   // tien), dinh moi van phai duoc uu tien sau khi da bu cac khoan rut.
   if ( currentBalanceBasis>highestBalanceBasis )   highestBalanceBasis = currentBalanceBasis ;
   GlobalVariableSet(OnlyUpPeakGVName(),highestBalanceBasis) ;
   GlobalVariableSet(OnlyUpWithdrawGVName(),(double)onlyUpWithdrawScannedMsc) ;
 }
 else
 {
   highestBalanceBasis = currentBalanceBasis ;
 }
 usDaylightSavingState = false ;
 europeDaylightSavingState = false ;
 nfpDatesGmt[0] = D'2026.12.04 12:30';
 nfpDatesGmt[1] = D'2026.11.06 12:30';
 nfpDatesGmt[2] = D'2026.10.02 12:30';
 nfpDatesGmt[3] = D'2026.09.04 12:30';
 nfpDatesGmt[4] = D'2026.08.07 12:30';
 nfpDatesGmt[5] = D'2026.07.02 12:30';
 nfpDatesGmt[6] = D'2026.06.05 12:30';
 nfpDatesGmt[7] = D'2026.05.08 12:30';
 nfpDatesGmt[8] = D'2026.04.03 12:30';
 nfpDatesGmt[9] = D'2026.03.06 12:30';
 nfpDatesGmt[10] = D'2026.02.11 12:30';
 nfpDatesGmt[11] = D'2026.01.09 12:30';
 nfpDatesGmt[12] = D'2025.12.16 12:30';
 nfpDatesGmt[13] = D'2025.11.07 12:30';
 nfpDatesGmt[14] = D'2025.10.03 12:30';
 nfpDatesGmt[15] = D'2025.09.05 12:30';
 nfpDatesGmt[16] = D'2025.08.01 12:30';
 nfpDatesGmt[17] = D'2025.07.03 12:30';
 nfpDatesGmt[18] = D'2025.06.06 12:30';
 nfpDatesGmt[19] = D'2025.05.02 12:30';
 nfpDatesGmt[20] = D'2025.04.04 12:30';
 nfpDatesGmt[21] = D'2025.03.07 12:30';
 nfpDatesGmt[22] = D'2025.02.07 12:30';
 nfpDatesGmt[23] = D'2025.01.10 12:30';
 nfpDatesGmt[24] = D'2024.12.06 12:30';
 nfpDatesGmt[25] = D'2024.11.01 12:30';
 nfpDatesGmt[26] = D'2024.10.04 12:30';
 nfpDatesGmt[27] = D'2024.09.06 12:30';
 nfpDatesGmt[28] = D'2024.08.02 12:30';
 nfpDatesGmt[29] = D'2024.07.05 12:30';
 nfpDatesGmt[30] = D'2024.06.07 12:30';
 nfpDatesGmt[31] = D'2024.05.03 12:30';
 nfpDatesGmt[32] = D'2024.04.05 12:30';
 nfpDatesGmt[33] = D'2024.03.08 12:30';
 nfpDatesGmt[34] = D'2024.02.02 12:30';
 nfpDatesGmt[35] = D'2024.01.05 12:30';
 nfpDatesGmt[36] = D'2023.12.08 12:30';
 nfpDatesGmt[37] = D'2023.11.03 12:30';
 nfpDatesGmt[38] = D'2023.10.06 12:30';
 nfpDatesGmt[39] = D'2023.09.01 12:30';
 nfpDatesGmt[40] = D'2023.08.04 12:30';
 nfpDatesGmt[41] = D'2023.07.07 12:30';
 nfpDatesGmt[42] = D'2023.06.02 12:30';
 nfpDatesGmt[43] = D'2023.05.05 12:30';
 nfpDatesGmt[44] = D'2023.04.07 12:30';
 nfpDatesGmt[45] = D'2023.03.10 12:30';
 nfpDatesGmt[46] = D'2023.02.03 12:30';
 nfpDatesGmt[47] = D'2023.01.06 12:30';
 nfpDatesGmt[48] = D'2022.12.02 12:30';
 nfpDatesGmt[49] = D'2022.11.04 12:30';
 nfpDatesGmt[50] = D'2022.10.07 12:30';
 nfpDatesGmt[51] = D'2022.09.02 12:30';
 nfpDatesGmt[52] = D'2022.08.05 12:30';
 nfpDatesGmt[53] = D'2022.07.08 12:30';
 nfpDatesGmt[54] = D'2022.06.03 12:30';
 nfpDatesGmt[55] = D'2022.05.06 12:30';
 nfpDatesGmt[56] = D'2022.04.01 12:30';
 nfpDatesGmt[57] = D'2022.03.04 12:30';
 nfpDatesGmt[58] = D'2022.02.04 12:30';
 nfpDatesGmt[59] = D'2022.01.07 12:30';
 nfpDatesGmt[60] = D'2021.12.03 12:30';
 nfpDatesGmt[61] = D'2021.11.05 12:30';
 nfpDatesGmt[62] = D'2021.10.08 12:30';
 nfpDatesGmt[63] = D'2021.09.03 12:30';
 nfpDatesGmt[64] = D'2021.08.06 12:30';
 nfpDatesGmt[65] = D'2021.07.02 12:30';
 nfpDatesGmt[66] = D'2021.06.04 12:30';
 nfpDatesGmt[67] = D'2021.05.07 12:30';
 nfpDatesGmt[68] = D'2021.04.02 12:30';
 nfpDatesGmt[69] = D'2021.03.05 12:30';
 nfpDatesGmt[70] = D'2021.02.05 12:30';
 nfpDatesGmt[71] = D'2021.01.08 12:30';
 nfpDatesGmt[72] = D'2020.12.04 12:30';
 nfpDatesGmt[73] = D'2020.11.06 12:30';
 nfpDatesGmt[74] = D'2020.10.02 12:30';
 nfpDatesGmt[75] = D'2020.09.04 12:30';
 nfpDatesGmt[76] = D'2020.08.07 12:30';
 nfpDatesGmt[77] = D'2020.07.02 12:30';
 nfpDatesGmt[78] = D'2020.06.05 12:30';
 nfpDatesGmt[79] = D'2020.05.08 12:30';
 nfpDatesGmt[80] = D'2020.04.03 12:30';
 nfpDatesGmt[81] = D'2020.03.06 12:30';
 nfpDatesGmt[82] = D'2020.02.07 12:30';
 nfpDatesGmt[83] = D'2020.01.10 12:30';
 nfpDatesGmt[84] = D'2019.12.06 12:30';
 nfpDatesGmt[85] = D'2019.11.01 12:30';
 nfpDatesGmt[86] = D'2019.10.04 12:30';
 nfpDatesGmt[87] = D'2019.09.06 12:30';
 nfpDatesGmt[88] = D'2019.08.02 12:30';
 nfpDatesGmt[89] = D'2019.07.05 12:30';
 nfpDatesGmt[90] = D'2019.06.07 12:30';
 nfpDatesGmt[91] = D'2019.05.03 12:30';
 nfpDatesGmt[92] = D'2019.04.05 12:30';
 nfpDatesGmt[93] = D'2019.03.08 12:30';
 nfpDatesGmt[94] = D'2019.02.01 12:30';
 nfpDatesGmt[95] = D'2019.01.04 12:30';
 nfpDatesGmt[96] = D'2018.12.07 12:30';
 nfpDatesGmt[97] = D'2018.11.02 12:30';
 nfpDatesGmt[98] = D'2018.10.05 12:30';
 nfpDatesGmt[99] = D'2018.09.07 12:30';
 nfpDatesGmt[100] = D'2018.08.03 12:30';
 nfpDatesGmt[101] = D'2018.07.06 12:30';
 nfpDatesGmt[102] = D'2018.06.01 12:30';
 nfpDatesGmt[103] = D'2018.05.04 12:30';
 nfpDatesGmt[104] = D'2018.04.06 12:30';
 nfpDatesGmt[105] = D'2018.03.09 12:30';
 nfpDatesGmt[106] = D'2018.02.02 12:30';
 nfpDatesGmt[107] = D'2018.01.05 12:30';
 nfpDatesGmt[108] = D'2017.12.08 12:30';
 nfpDatesGmt[109] = D'2017.11.03 12:30';
 nfpDatesGmt[110] = D'2017.10.06 12:30';
 nfpDatesGmt[111] = D'2017.09.01 12:30';
 nfpDatesGmt[112] = D'2017.08.04 12:30';
 nfpDatesGmt[113] = D'2017.07.07 12:30';
 nfpDatesGmt[114] = D'2017.06.02 12:30';
 nfpDatesGmt[115] = D'2017.05.05 12:30';
 nfpDatesGmt[116] = D'2017.04.07 12:30';
 nfpDatesGmt[117] = D'2017.03.10 12:30';
 nfpDatesGmt[118] = D'2017.02.03 12:30';
 nfpDatesGmt[119] = D'2017.01.06 12:30';
 nfpDatesGmt[120] = D'2016.12.02 12:30';
 nfpDatesGmt[121] = D'2016.11.04 12:30';
 nfpDatesGmt[122] = D'2016.10.07 12:30';
 nfpDatesGmt[123] = D'2016.09.02 12:30';
 nfpDatesGmt[124] = D'2016.08.05 12:30';
 nfpDatesGmt[125] = D'2016.07.08 12:30';
 nfpDatesGmt[126] = D'2016.06.03 12:30';
 nfpDatesGmt[127] = D'2016.05.06 12:30';
 nfpDatesGmt[128] = D'2016.04.01 12:30';
 nfpDatesGmt[129] = D'2016.03.04 12:30';
 nfpDatesGmt[130] = D'2016.02.05 12:30';
 nfpDatesGmt[131] = D'2016.01.08 12:30';
 nfpDatesGmt[132] = D'2015.12.04 12:30';
 nfpDatesGmt[133] = D'2015.11.06 12:30';
 nfpDatesGmt[134] = D'2015.10.02 12:30';
 nfpDatesGmt[135] = D'2015.09.04 12:30';
 nfpDatesGmt[136] = D'2015.08.07 12:30';
 nfpDatesGmt[137] = D'2015.07.02 12:30';
 nfpDatesGmt[138] = D'2015.06.05 12:30';
 nfpDatesGmt[139] = D'2015.05.08 12:30';
 nfpDatesGmt[140] = D'2015.04.03 12:30';
 nfpDatesGmt[141] = D'2015.03.06 12:30';
 nfpDatesGmt[142] = D'2015.02.06 12:30';
 nfpDatesGmt[143] = D'2015.01.09 12:30';
 nfpDatesGmt[144] = D'2014.12.05 12:30';
 nfpDatesGmt[145] = D'2014.11.07 12:30';
 nfpDatesGmt[146] = D'2014.10.03 12:30';
 nfpDatesGmt[147] = D'2014.09.05 12:30';
 nfpDatesGmt[148] = D'2014.08.01 12:30';
 nfpDatesGmt[149] = D'2014.07.03 12:30';
 nfpDatesGmt[150] = D'2014.06.06 12:30';
 nfpDatesGmt[151] = D'2014.05.02 12:30';
 nfpDatesGmt[152] = D'2014.04.04 12:30';
 nfpDatesGmt[153] = D'2014.03.07 12:30';
 nfpDatesGmt[154] = D'2014.02.07 12:30';
 nfpDatesGmt[155] = D'2014.01.10 12:30';
 nfpDatesGmt[156] = D'2013.12.06 12:30';
 nfpDatesGmt[157] = D'2013.11.08 12:30';
 nfpDatesGmt[158] = D'2013.10.22 12:30';
 nfpDatesGmt[159] = D'2013.09.06 12:30';
 nfpDatesGmt[160] = D'2013.08.02 12:30';
 nfpDatesGmt[161] = D'2013.07.05 12:30';
 nfpDatesGmt[162] = D'2013.06.07 12:30';
 nfpDatesGmt[163] = D'2013.05.03 12:30';
 nfpDatesGmt[164] = D'2013.04.05 12:30';
 nfpDatesGmt[165] = D'2013.03.08 12:30';
 nfpDatesGmt[166] = D'2013.02.01 12:30';
 nfpDatesGmt[167] = D'2013.01.04 12:30';
 nfpDatesGmt[168] = D'2012.12.07 12:30';
 nfpDatesGmt[169] = D'2012.11.02 12:30';
 nfpDatesGmt[170] = D'2012.10.05 12:30';
 nfpDatesGmt[171] = D'2012.09.07 12:30';
 nfpDatesGmt[172] = D'2012.08.03 12:30';
 nfpDatesGmt[173] = D'2012.07.06 12:30';
 nfpDatesGmt[174] = D'2012.06.01 12:30';
 nfpDatesGmt[175] = D'2012.05.04 12:30';
 nfpDatesGmt[176] = D'2012.04.06 12:30';
 nfpDatesGmt[177] = D'2012.03.09 12:30';
 nfpDatesGmt[178] = D'2012.02.03 12:30';
 nfpDatesGmt[179] = D'2012.01.06 12:30';
 nfpDatesGmt[180] = D'2011.12.02 12:30';
 nfpDatesGmt[181] = D'2011.11.04 12:30';
 nfpDatesGmt[182] = D'2011.10.07 12:30';
 nfpDatesGmt[183] = D'2011.09.02 12:30';
 nfpDatesGmt[184] = D'2011.08.05 12:30';
 nfpDatesGmt[185] = D'2011.07.08 12:30';
 nfpDatesGmt[186] = D'2011.06.03 12:30';
 nfpDatesGmt[187] = D'2011.05.06 12:30';
 nfpDatesGmt[188] = D'2011.04.01 12:30';
 nfpDatesGmt[189] = D'2011.03.04 12:30';
 nfpDatesGmt[190] = D'2011.02.04 12:30';
 nfpDatesGmt[191] = D'2011.01.07 12:30';
 nfpDatesGmt[192] = D'2010.12.03 12:30';
 nfpDatesGmt[193] = D'2010.11.05 12:30';
 nfpDatesGmt[194] = D'2010.10.08 12:30';
 nfpDatesGmt[195] = D'2010.09.03 12:30';
 nfpDatesGmt[196] = D'2010.08.06 12:30';
 nfpDatesGmt[197] = D'2010.07.02 12:30';
 nfpDatesGmt[198] = D'2010.06.04 12:30';
 nfpDatesGmt[199] = D'2010.05.07 12:30';
 nfpDatesGmt[200] = D'2010.04.02 12:30';
 nfpDatesGmt[201] = D'2010.03.05 12:30';
 nfpDatesGmt[202] = D'2010.02.05 12:30';
 nfpDatesGmt[203] = D'2010.01.08 12:30';
 nfpDatesGmt[204] = D'2009.12.04 12:30';
 nfpDatesGmt[205] = D'2009.11.06 12:30';
 nfpDatesGmt[206] = D'2009.10.02 12:30';
 nfpDatesGmt[207] = D'2009.09.04 12:30';
 nfpDatesGmt[208] = D'2009.08.07 12:30';
 nfpDatesGmt[209] = D'2009.07.02 12:30';
 nfpDatesGmt[210] = D'2009.06.05 12:30';
 nfpDatesGmt[211] = D'2009.05.08 12:30';
 nfpDatesGmt[212] = D'2009.04.03 12:30';
 nfpDatesGmt[213] = D'2009.03.06 12:30';
 nfpDatesGmt[214] = D'2009.02.06 12:30';
 nfpDatesGmt[215] = D'2009.01.09 12:30';
 nfpDatesGmt[216] = D'2008.12.05 12:30';
 nfpDatesGmt[217] = D'2008.11.07 12:30';
 nfpDatesGmt[218] = D'2008.10.03 12:30';
 nfpDatesGmt[219] = D'2008.09.05 12:30';
 nfpDatesGmt[220] = D'2008.08.01 12:30';
 nfpDatesGmt[221] = D'2008.07.03 12:30';
 nfpDatesGmt[222] = D'2008.06.06 12:30';
 nfpDatesGmt[223] = D'2008.05.02 12:30';
 nfpDatesGmt[224] = D'2008.04.04 12:30';
 nfpDatesGmt[225] = D'2008.03.07 12:30';
 nfpDatesGmt[226] = D'2008.02.01 12:30';
 nfpDatesGmt[227] = D'2008.01.04 12:30';
 nfpDatesGmt[228] = D'2007.12.07 12:30';
 nfpDatesGmt[229] = D'2007.11.02 12:30';
 nfpDatesGmt[230] = D'2007.10.05 12:30';
 nfpDatesGmt[231] = D'2007.09.07 12:30';
 nfpDatesGmt[232] = D'2007.08.03 12:30';
 nfpDatesGmt[233] = D'2007.07.06 12:30';
 nfpDatesGmt[234] = D'2007.06.01 12:30';
 nfpDatesGmt[235] = D'2007.05.04 12:30';
 nfpDatesGmt[236] = D'2007.04.06 12:30';
 nfpDatesGmt[237] = D'2007.03.09 12:30';
 nfpDatesGmt[238] = D'2007.02.02 12:30';
 nfpDatesGmt[239] = D'2007.01.05 12:30';
 // UseMQL5Calendar=true: CHI dung Lich MQL5 lam nguon ngay NFP - xoa sach
 // mang ngay co san vua gan o tren, de khi Lich chua tai duoc/khong co du
 // lieu thi KHONG roi ve mang cu (panel se hien "no news coming up" va bo
 // loc NFP khong co ngay nao cho den khi Lich tra du lieu). Rieng trong
 // Strategy Tester van giu mang co san bat ke cong tac, vi Lich MQL5 khong
 // hoat dong trong tester (gioi han cua nen tang) - giong hanh vi v4.3.
 if ( UseMQL5Calendar && MQLInfoInteger(MQL_TESTER) != 1 )
 {
   for (riskBufferRowIndex = 0 ; riskBufferRowIndex < 300 ; riskBufferRowIndex ++)   nfpDatesGmt[riskBufferRowIndex] = 0 ;
 }
 if ( Risk == 1234 )
 {
   startLots_rw = SymbolInfoDouble(currentSymbol,SYMBOL_VOLUME_MIN) ;
 }
 if ( TradeFrequency == 5 && Risk == 1234 )
 {
   accountBalanceUsd = ConvertAccountCurrencyToUsdRounded(AccountInfoDouble(ACCOUNT_BALANCE)) ;
   allowedDrawdownUsd = MaxAllowedDD / 100.0 * accountBalanceUsd ;
   if ( allowedDrawdownUsd>autoFrequencyThreshold4 )
   {
     activeTradeFrequency = 3 ;
   }
   else
   {
     if ( allowedDrawdownUsd>autoFrequencyThreshold3 )
     {
       activeTradeFrequency = 2 ;
     }
     else
     {
       if ( allowedDrawdownUsd>autoFrequencyThreshold2 )
       {
         activeTradeFrequency = 1 ;
       }
       else
       {
         activeTradeFrequency = 0 ;
       }
     }
   }
 }
 else
 {
   activeTradeFrequency = TradeFrequency ;
 }
 if ( activeTradeFrequency == 0 )
 {
   enableStrategy4 = false ;
   enableStrategy5 = false ;
   enableStrategy6 = false ;
   enableStrategy7 = false ;
   enableStrategy8 = false ;
   enableStrategy9 = false ;
   enabledStrategyRiskWeight = 2.4 ;
   if ( UseVariableValues )
   {
     enabledStrategyRiskWeight = 3.0 ;
   }
 }
 else
 {
   if ( activeTradeFrequency == 1 )
   {
     enableStrategy4 = true ;
     enableStrategy5 = true ;
     enableStrategy6 = false ;
     enableStrategy7 = false ;
     enableStrategy8 = false ;
     enableStrategy9 = false ;
     enabledStrategyRiskWeight = 3.4 ;
     if ( UseVariableValues )
     {
       enabledStrategyRiskWeight = 4.0 ;
     }
   }
   else
   {
     if ( activeTradeFrequency == 2 )
     {
       enableStrategy4 = true ;
       enableStrategy5 = true ;
       enableStrategy6 = true ;
       enableStrategy7 = true ;
       enableStrategy8 = false ;
       enableStrategy9 = false ;
       enabledStrategyRiskWeight = 4.1 ;
       if ( UseVariableValues )
       {
         enabledStrategyRiskWeight = 5.0 ;
       }
     }
     else
     {
       if ( activeTradeFrequency == 3 )
       {
         enableStrategy4 = true ;
         enableStrategy5 = true ;
         enableStrategy6 = true ;
         enableStrategy7 = true ;
         enableStrategy8 = true ;
         enableStrategy9 = false ;
         enabledStrategyRiskWeight = 4.8 ;
         if ( UseVariableValues )
         {
           enabledStrategyRiskWeight = 5.6 ;
         }
       }
       else
       {
         if ( activeTradeFrequency == 4 )
         {
           enableStrategy4 = true ;
           enableStrategy5 = true ;
           enableStrategy6 = true ;
           enableStrategy7 = true ;
           enableStrategy8 = true ;
           enableStrategy9 = true ;
           enabledStrategyRiskWeight = 5.1 ;
           if ( UseVariableValues )
           {
             enabledStrategyRiskWeight = 6.0 ;
           }
         }
         else
         {
           if ( activeTradeFrequency == 6 )
           {
             enableStrategy1 = RunStrat1 ;
             enableStrategy2 = RunStrat2 ;
             enableStrategy3 = RunStrat3 ;
             enableStrategy4 = RunStrat4 ;
             enableStrategy5 = RunStrat5 ;
             enableStrategy6 = RunStrat6 ;
             enableStrategy7 = RunStrat7 ;
             enableStrategy8 = RunStrat8 ;
             enableStrategy9 = RunStrat9 ;
           }
         }
       }
     }
   }
 }
 currentStrategyComment = ST1_Comment ;
 dailyDrawdownReference = 0.0 ;
 dailyDrawdownLockActive = false ;
 lastPanelRefreshM5BarTime = 0 ;
 pairInitializationSucceeded = true ;
 legacyWriteOnlyPanelSpacingPrimary = 5.0 ;
 legacyWriteOnlyPanelSpacingSecondary = 10.0 ;
 strategyMagicNumber = ST1_MagicNumber ;
 panelObjectCount = 300 ;
 panelRowWidth = panelFontSize * 25 * panelWidthScaleFactor * InfoPanelSizeAdjust ;
 panelRowHeight = panelFontSize * 3.5 * panelHeightScaleFactor * InfoPanelSizeAdjust ;
 legacyWriteOnlyPanelColumnCount = 7 ;
 currentStrategyIndex = 0 ;
 currentSymbol = Symbol() ;
 symbolPoint = SymbolInfoDouble(currentSymbol,SYMBOL_POINT) ;
 pipSize = symbolPoint ;
 if ( ( ((double)SymbolInfoInteger(currentSymbol,SYMBOL_DIGITS))==3.0 || ((double)SymbolInfoInteger(currentSymbol,SYMBOL_DIGITS))==5.0 ) )
 {
   pipSize = symbolPoint * 10.0 ;
 }
 if ( SymbolInfoInteger(currentSymbol,SYMBOL_DIGITS) == 1 )
 {
   pipSize = symbolPoint / 10.0 ;
 }
 symbolDigits = (int)((double)SymbolInfoInteger(currentSymbol,SYMBOL_DIGITS)) ;
 if ( FridayStopHour <  0 )
 {
   fridayStopEnabled = false ;
 }
 else
 {
   fridayStopEnabled = true ;
 }
 legacyWriteOnlyInitializationTimestamp = (double)TimeCurrent() ;
 currentSpreadPrice = SymbolInfoDouble(currentSymbol,SYMBOL_ASK) - SymbolInfoDouble(currentSymbol,SYMBOL_BID) ;
 lotSizeByStrategy[currentStrategyIndex] = NormalizeDouble(MathFloor(startLots_rw * 100.0) / 100.0,2);
 if ( SymbolInfoDouble(currentSymbol,SYMBOL_VOLUME_STEP)==0.1 )
 {
   lotSizeByStrategy[currentStrategyIndex] = NormalizeDouble((MathFloor(startLots_rw * 10.0)) / 10.0,1);
   if ( lotSizeByStrategy[currentStrategyIndex]<0.1 )
   {
     lotSizeByStrategy[currentStrategyIndex] = 0.1;
   }
 }
 if ( lotSizeByStrategy[currentStrategyIndex]<SymbolInfoDouble(currentSymbol,SYMBOL_VOLUME_MIN) )
 {
   lotSizeByStrategy[currentStrategyIndex] = SymbolInfoDouble(currentSymbol,SYMBOL_VOLUME_MIN);
 }
 if ( lotSizeByStrategy[currentStrategyIndex]>SymbolInfoDouble(currentSymbol,SYMBOL_VOLUME_MAX) )
 {
   lotSizeByStrategy[currentStrategyIndex] = SymbolInfoDouble(currentSymbol,SYMBOL_VOLUME_MAX);
 }
 currentChartBars = iBars(currentSymbol,NormalizeTimeframe(PERIOD_CURRENT)) ;
 if ( magicTrailStepPips * pipSize<symbolPoint )
 {
   magicTrailStepPips = symbolPoint / pipSize ;
 }
 initialAccountBalance = AccountInfoDouble(ACCOUNT_BALANCE) ;
 stopLevelPriceDistance = ((double)SymbolInfoInteger(currentSymbol,SYMBOL_TRADE_STOPS_LEVEL)) * symbolPoint ;
 freezeLevelPriceDistance = ((double)SymbolInfoInteger(currentSymbol,SYMBOL_TRADE_FREEZE_LEVEL)) * symbolPoint ;
 symbolSuffix = StringSubstr(Symbol(),6,10) ;
 if ( symbolSuffix != "" )
 {
   Print("Suffix detected: " + symbolSuffix); 
 }
 if ( ( StringFind(Symbol(),"XAUUSD",0) >= 0 || StringFind(Symbol(),"xauusd",0) >= 0 || StringFind(Symbol(),"GOLD",0) >= 0 || StringFind(Symbol(),"gold",0) >= 0 || StringFind(Symbol(),"Gold",0) >= 0 || StringFind(Symbol(),"GLD",0) >= 0 ) )
 {
   currentSymbol = Symbol() ;
   strategySymbols[strategySymbolCount] = Symbol();
   LoadStrategy1Profile(); 
   LoadStrategyRuntimeContext(0); 
   strategySymbolCount ++;
 }
 else
 {
   currentSymbol = Symbol() ;
   LoadStrategyRuntimeContext(0); 
 }
 if ( !(pairInitializationSucceeded) )
 {
   Print("Initialisation of pairs failed!"); 
 }
 if ( stopLossPips<=0.0 )
 {
   stopLossPips = 1.0 ;
 }
 if ( takeProfitPips<=0.0 )
 {
   takeProfitPips = 1.0 ;
 }
 if ( breakEvenExtraPips>breakEvenStartPips )
 {
   breakEvenExtraPips = breakEvenStartPips + 0.1 ;
 }
 if ( minPendingMarketGapPips<freezeLevelPriceDistance / pipSize )
 {
   minPendingMarketGapPips = (int)(freezeLevelPriceDistance / pipSize) ;
 }
 if ( trailingSLStartPips!=0.0 && trailingSLStartPips<freezeLevelPriceDistance / pipSize )
 {
   trailingSLStartPips = freezeLevelPriceDistance / pipSize ;
 }
 if ( trailingSLStartPips!=0.0 && trailingSLStartPips<stopLevelPriceDistance / pipSize )
 {
   trailingSLStartPips = stopLevelPriceDistance / pipSize ;
 }
 if ( timeRecoveryAfterMinutes>0.0 && timeRecoveryStopPips<freezeLevelPriceDistance / pipSize )
 {
   timeRecoveryStopPips = freezeLevelPriceDistance / pipSize ;
 }
 if ( timeRecoveryAfterMinutes>0.0 && timeRecoveryStopPips<stopLevelPriceDistance / pipSize )
 {
   timeRecoveryStopPips = stopLevelPriceDistance / pipSize ;
 }
 if ( stopLossPips<stopLevelPriceDistance * 2.0 / pipSize )
 {
   stopLossPips = stopLevelPriceDistance * 2.0 / pipSize ;
 }
 if ( takeProfitPips<stopLevelPriceDistance * 2.0 / pipSize )
 {
   takeProfitPips = stopLevelPriceDistance * 2.0 / pipSize ;
 }
 if ( minEntryDistancePips<stopLevelPriceDistance * 2.0 / pipSize )
 {
   minEntryDistancePips = stopLevelPriceDistance * 2.0 / pipSize ;
 }
 if ( swingLeftBars <  1 )
 {
   swingLeftBars = 1 ;
 }
 if ( swingRightBars <  1 )
 {
   swingRightBars = 1 ;
 }
 if ( minEntryDistancePips<0.1 )
 {
   minEntryDistancePips = 0.1 ;
 }
 pendingExpirationSeconds=pendingExpirationHours * 60 * 60;
 if ( pendingExpirationHours >  0 )
 {
   pendingOrderExpirationTime=TimeCurrent() + pendingExpirationSeconds;
 }
 else
 {
   pendingOrderExpirationTime = 0 ;
 }
 if ( Virtual_expiration )
 {
   pendingOrderExpirationTime = 0 ;
 }
 nfpTradingSuspended = false ;
 legacyWriteOnlyInitializationSecond = CurrentSecond() ;
 lastVirtualStopSyncTime = TimeCurrent() ;
 buyZoneStateInitialized = false ;
 sellZoneStateInitialized = false ;
 legacyWriteOnlyInitializationMonth = CurrentMonth() ;
 legacyWriteOnlyPreviousWeeklyBarTime = iTime(currentSymbol,NormalizeTimeframe(PERIOD_W1),1) ;
 legacyWriteOnlyPreviousMonthlyBarTimePrimary = iTime(currentSymbol,NormalizeTimeframe(PERIOD_M1),1) ;
 legacyWriteOnlyPreviousMonthlyBarTimeSecondary = iTime(currentSymbol,NormalizeTimeframe(PERIOD_M1),1) ;
 if ( maxSpreadPips>MaxSpread )
 {
   maxSpreadPips = MaxSpread ;
 }
 legacyWriteOnlyInitializationFlag = false ;
 CalculateBuyEntryPrice(signalTimeframeMinutes); 
 CalculateSellEntryPrice(signalTimeframeMinutes); 
 cachedBuySignalPrice = NormalizeDouble(currentBuyEntryPrice,symbolDigits) ;
 cachedSellSignalPrice = NormalizeDouble(currentSellEntryPrice,symbolDigits) ;
 magicTrailTickCounter = 0 ;
 marketPauseMessageLogged = false ;
 timeRecoveryDelaySeconds = (int)(timeRecoveryAfterMinutes * 60.0) ;
 dynamicLotSizingEnabled = false ;
 tradingHoursState = true ;
 freezeLevelPriceDistance = ((double)SymbolInfoInteger(currentSymbol,SYMBOL_TRADE_FREEZE_LEVEL)) * symbolPoint ;
 if ( !(tradingHoursEnabled) )
 {
   tradingHoursState = false ;
 }
 activeVirtualStopPrice = 0.0 ;
 legacyWriteOnlyTradeStateValuePrimary = 0.0 ;
 legacyWriteOnlyTradeStateValueSecondary = 0.0 ;
 legacyWriteOnlyTradeStateFlag = false ;
 symbolSuffix = StringSubstr(currentSymbol,6,0) ;
 if ( Risk >  0 )
 {
   dynamicLotSizingEnabled = true ;
 }
 if ( startLots_rw<0.0 )
 {
   startLots_rw = 0.01 ;
 }
 if ( maxCalculatedLotSize>SymbolInfoDouble(currentSymbol,SYMBOL_VOLUME_MAX) )
 {
   maxCalculatedLotSize = SymbolInfoDouble(currentSymbol,SYMBOL_VOLUME_MAX) ;
 }
 for (riskBufferRowIndex = 0 ; riskBufferRowIndex < smallBufferCapacity ; riskBufferRowIndex ++)
 {
   for (virtualStopFieldIndex = 0 ; virtualStopFieldIndex < 2 ; virtualStopFieldIndex ++)
   {
     virtualStopByTicket[riskBufferRowIndex][virtualStopFieldIndex] = 0.0;
   }
 }
 for (storedOrderRowIndex = 0 ; storedOrderRowIndex < orderBufferCapacity ; storedOrderRowIndex ++)
 {
   for (storedOrderFieldIndex = 0 ; storedOrderFieldIndex < 3 ; storedOrderFieldIndex ++)
   {
     storedPendingOrders[storedOrderRowIndex][storedOrderFieldIndex] = 0.0;
   }
 }
 for (storedOrderResetIndex = 0 ; storedOrderResetIndex < 100 ; storedOrderResetIndex ++)
 {
   storedPendingOrders[storedOrderResetIndex][0] = 0.0;
   storedPendingOrders[storedOrderResetIndex][1] = 0.0;
 }
 fridayTradingSuspended = false ;
 currentUpperFractal = GetFractalValue(currentSymbol,0,1,1) ;
 currentLowerFractal = GetFractalValue(currentSymbol,0,2,1) ;
 previousUpperFractal = currentUpperFractal ;
 previousLowerFractal = currentLowerFractal ;
 legacyWriteOnlyFractalStateValue = 0.0 ;
 legacyWriteOnlyFractalStateFlag = false ;
 legacyWriteOnlyInitializationHour = CurrentHour() ;
 legacyWriteOnlyInitializationCounter = 0 ;
 buyComment1=ST1_Comment + "B1";
 buyComment2=ST1_Comment + "B2";
 sellComment1=ST1_Comment + "S1";
 sellComment2=ST1_Comment + "S2";
 legacyWriteOnlyCommentStateCounterPrimary = 0 ;
 legacyWriteOnlyCommentStateCounterSecondary = 0 ;
 lastEntryHour = CurrentHour() ;
 if ( virtualPendingOrdersEnabled )
 {
   maxPendingOrders = 1 ;
   legacyWriteOnlyVirtualBuyPendingFlag = true ;
   legacyWriteOnlyVirtualSellPendingFlag = true ;
 }
 legacyWriteOnlyUpperPriceSentinel = 999.0 ;
 legacyWriteOnlyLowerPriceSentinel = 0.0 ;
 legacyWriteOnlyEntryStateValuePrimary = 0.0 ;
 legacyWriteOnlyEntryStateValueSecondary = 0.0 ;
 for (strategyInitializationIndex = 0 ; strategyInitializationIndex < 99 ; strategyInitializationIndex ++)
 {
   lastEntryBarCountByStrategy[strategyInitializationIndex] = 0;
   lastExitBarCountByStrategy[strategyInitializationIndex] = 0;
   lastSignalBarTimeByStrategy[strategyInitializationIndex] = iTime(currentSymbol,NormalizeTimeframe(signalTimeframeMinutes),1);
   if ( !(lotSizeByStrategy[strategyInitializationIndex]<startLots_rw) )   continue;
   lotSizeByStrategy[strategyInitializationIndex] = startLots_rw;
   
 }
 legacyWriteOnlyOrderTicket = 0 ;
 legacyWriteOnlyOrderStateFlagPrimary = false ;
 legacyWriteOnlyOrderStateFlagSecondary = false ;
 if ( tradeMonitorFilterMode == 1 )
 {
   extraStopLossPips = 0.0 ;
 }
 symbolDigits = (int)((double)SymbolInfoInteger(currentSymbol,SYMBOL_DIGITS)) ;
 demoAccountDetectedFlag = false ;
 IsDemoAccount(); 

 if ( ignoredDemoDetectionResult == true )
 {
   demoAccountDetectedFlag = true ;
 }
 if ( ShowInfoPanel )
 {
   if ( strategyRankingMode == 1 )
   {
     RankStrategiesByTotalProfit(); 
   }
   else
   {
     if ( strategyRankingMode == 2 )
     {
       RankStrategiesByAverageProfit(); 
     }
   }
   CreateInfoPanel(); 
   UpdateInfoPanelSummary(); 
   UpdateInfoPanelTotals(); 
 }
 return(0); 
 }
//init <<==--------   --------
 void OnTick()
 {
  bool      gmtRefreshPerformed;
  double    accountBalanceUsd;
  double    allowedDrawdownUsd;
  bool      refreshPerformanceThisHour;
  MqlDateTime marchDstBoundaryParts;
  MqlDateTime octoberDstBoundaryParts;
//----------------------------------------------------------------------
 bool       isEuropeanDaylightSavingTime;
 double     strategy1DisplayedProfit;
 double     strategy1ProfitAccumulator;
 int        strategy1HistoryIndex;
 double     strategy4DisplayedProfit;
 double     strategy4ProfitAccumulator;
 int        strategy4HistoryIndex;
 double     strategy2DisplayedProfit;
 double     strategy2ProfitAccumulator;
 int        strategy2HistoryIndex;
 double     strategy3DisplayedProfit;
 double     strategy3ProfitAccumulator;
 int        strategy3HistoryIndex;
 double     strategy6DisplayedProfit;
 double     strategy6ProfitAccumulator;
 int        strategy6HistoryIndex;
 double     strategy5DisplayedProfit;
 double     strategy5ProfitAccumulator;
 int        strategy5HistoryIndex;
 double     strategy9DisplayedProfit;
 double     strategy9ProfitAccumulator;
 int        strategy9HistoryIndex;
 double     strategy7DisplayedProfit;
 double     strategy7ProfitAccumulator;
 int        strategy7HistoryIndex;
 double     strategy8DisplayedProfit;
 double     strategy8ProfitAccumulator;
 int        strategy8HistoryIndex;

 currentBalanceBasis = AccountInfoDouble(ACCOUNT_BALANCE) ;
 if ( UseEquity )
 {
   currentBalanceBasis = AccountInfoDouble(ACCOUNT_EQUITY) ;
 }
 if ( ManualBalance>0.0 )
 {
   currentBalanceBasis = ManualBalance ;
 }
 if ( OnlyUp && highestBalanceBasis>currentBalanceBasis )
 {
   currentBalanceBasis = highestBalanceBasis ;
 }
 if ( currentBalanceBasis>highestBalanceBasis )
 {
   highestBalanceBasis = currentBalanceBasis ;
   if ( OnlyUp )   GlobalVariableSet(OnlyUpPeakGVName(),highestBalanceBasis) ;
 }
 if ( FakeOutFilter == 0 )
 {
   candleExitM1Enabled = false ;
   candleExitM15Enabled = false ;
   candleExitH1Enabled = false ;
 }
 else
 {
   if ( FakeOutFilter == 1 )
   {
     candleExitM1Enabled = true ;
     candleExitM15Enabled = false ;
     candleExitH1Enabled = false ;
   }
   else
   {
     if ( FakeOutFilter == 2 )
     {
       candleExitM1Enabled = true ;
       candleExitM15Enabled = true ;
       candleExitH1Enabled = false ;
     }
     else
     {
       if ( FakeOutFilter == 3 )
       {
         candleExitM1Enabled = true ;
         candleExitM15Enabled = true ;
         candleExitH1Enabled = true ;
       }
     }
   }
 }
 gmtRefreshPerformed = false ;
 if ( IsAmericanDaylightSavingTime() )
 {
   brokerGmtOffsetHours = Broker_GMT_OFFSET_Summer ;
   if ( ( !(usDaylightSavingState) || !(gmtDetectionInitialized) ) && AutoGMT && !(gmtRefreshPerformed) )
   {
     usDaylightSavingState = true ;
     europeDaylightSavingState = true ;
     detectedUtcOffsetHours = FetchUtcOffsetHours() ;
     if ( detectedUtcOffsetHours == 999 )
     {
       Print("GMT_Offset wrongly detected.  Trying againg!"); 
       Sleep(2000); 
       detectedUtcOffsetHours = FetchUtcOffsetHours() ;
     }
     if ( detectedUtcOffsetHours == 999 )
     {
       Print("GMT_Offset still wrong.  Using VPS time for GMT detection!"); 
     }
     gmtDetectionInitialized = true ;
     gmtRefreshPerformed = true ;
     Print("DST_US on"); 
   }
 }
 else
 {
   brokerGmtOffsetHours = Broker_GMT_OFFSET_Winter ;
   if ( ( usDaylightSavingState || !(gmtDetectionInitialized) ) && AutoGMT && !(gmtRefreshPerformed) )
   {
     usDaylightSavingState = false ;
     europeDaylightSavingState = false ;
     detectedUtcOffsetHours = FetchUtcOffsetHours() ;
     if ( detectedUtcOffsetHours == 999 )
     {
       Print("GMT_Offset wrongly detected.  Trying againg!"); 
       Sleep(2000); 
       detectedUtcOffsetHours = FetchUtcOffsetHours() ;
     }
     if ( detectedUtcOffsetHours == 999 )
     {
       Print("GMT_Offset still wrong.  Using VPS time for GMT detection!"); 
     }
     gmtDetectionInitialized = true ;
     gmtRefreshPerformed = true ;
     Print("DST_US off"); 
   }
 }
 TimeToStruct(StringToTime(string(DateTimeYear(TimeCurrent())) + ".03.31 01:00"),marchDstBoundaryParts); 
 TimeToStruct(StringToTime(string(DateTimeYear(TimeCurrent())) + ".10.31 02:00"),octoberDstBoundaryParts); 
 if ( DateTimeDayOfYear(TimeCurrent()) >  DateTimeDayOfYear(StringToTime(string(DateTimeYear(TimeCurrent())) + ".03.31 01:00") - marchDstBoundaryParts.day_of_week * SECONDS_PER_DAY) && DateTimeDayOfYear(TimeCurrent()) <  DateTimeDayOfYear(StringToTime(string(DateTimeYear(TimeCurrent())) + ".10.31 02:00") - octoberDstBoundaryParts.day_of_week * SECONDS_PER_DAY) )
 {
   isEuropeanDaylightSavingTime = true;
 }
 else
 {
   isEuropeanDaylightSavingTime = false;
 }
 if ( isEuropeanDaylightSavingTime )
 {
   if ( ( !(europeDaylightSavingState) || !(gmtDetectionInitialized) ) && AutoGMT && !(gmtRefreshPerformed) )
   {
     europeDaylightSavingState = true ;
     detectedUtcOffsetHours = FetchUtcOffsetHours() ;
     if ( detectedUtcOffsetHours == 999 )
     {
       Print("GMT_Offset wrongly detected.  Trying againg!"); 
       Sleep(2000); 
       detectedUtcOffsetHours = FetchUtcOffsetHours() ;
     }
     if ( detectedUtcOffsetHours == 999 )
     {
       Print("GMT_Offset still wrong.  Using VPS time for GMT detection!"); 
     }
     gmtDetectionInitialized = true ;
     gmtRefreshPerformed = true ;
     Print("DST_EU on"); 
   }
 }
 else
 {
   if ( ( europeDaylightSavingState || !(gmtDetectionInitialized) ) && AutoGMT && !(gmtRefreshPerformed) )
   {
     europeDaylightSavingState = false ;
     detectedUtcOffsetHours = FetchUtcOffsetHours() ;
     if ( detectedUtcOffsetHours == 999 )
     {
       Print("GMT_Offset wrongly detected.  Trying againg!"); 
       Sleep(2000); 
       detectedUtcOffsetHours = FetchUtcOffsetHours() ;
     }
     if ( detectedUtcOffsetHours == 999 )
     {
       Print("GMT_Offset still wrong.  Using VPS time for GMT detection!"); 
     }
     gmtDetectionInitialized = true ;
     gmtRefreshPerformed = true ;
     Print("DST_EU off"); 
   }
 }
 if ( AutoGMT && MQLInfoInteger(MQL_TESTER) != 1 )
 {
   if ( detectedUtcOffsetHours != 999 )
   {
     currentGmtTime=TimeCurrent() - detectedUtcOffsetHours * 3600;
   }
   else
   {
     currentGmtTime = TimeGMT() ;
   }
 }
 else
 {
   currentGmtTime=TimeCurrent() - brokerGmtOffsetHours * 3600;
 }
 // Lich MQL5 khong kha dung/dang tin cay trong Strategy Tester (backtest) nen chi
 // lam moi tu Lich MQL5 khi dang chay live/demo that; kiem thu nguoc luon dung mang
 // nfpDatesGmt[] ma hoa cung ben tren (da cap nhat toi het nam 2026) de dam
 // bao ket qua backtest 100% xac dinh, lap lai duoc.
 if ( EnableNFP_Filter && UseMQL5Calendar && MQLInfoInteger(MQL_TESTER) != 1 && TimeCurrent() - TimeCurrent() % SECONDS_PER_DAY > nfpCalendarBuiltDay )
 {
   BuildNFPDatesFromCalendar();
 }
 if ( TradeFrequency == 5 && Risk == 1234 )
 {
   accountBalanceUsd = ConvertAccountCurrencyToUsdRounded(AccountInfoDouble(ACCOUNT_BALANCE)) ;
   allowedDrawdownUsd = MaxAllowedDD / 100.0 * accountBalanceUsd ;
   if ( allowedDrawdownUsd>autoFrequencyThreshold4 )
   {
     activeTradeFrequency = 3 ;
   }
   else
   {
     if ( allowedDrawdownUsd>autoFrequencyThreshold3 )
     {
       activeTradeFrequency = 2 ;
     }
     else
     {
       if ( allowedDrawdownUsd>autoFrequencyThreshold2 )
       {
         activeTradeFrequency = 1 ;
       }
       else
       {
         activeTradeFrequency = 0 ;
       }
     }
   }
 }
 else
 {
   activeTradeFrequency = TradeFrequency ;
 }
 if ( activeTradeFrequency == 0 )
 {
   enableStrategy4 = false ;
   enableStrategy5 = false ;
   enableStrategy6 = false ;
   enableStrategy7 = false ;
   enableStrategy8 = false ;
   enableStrategy9 = false ;
   enabledStrategyRiskWeight = 2.4 ;
   if ( UseVariableValues )
   {
     enabledStrategyRiskWeight = 3.0 ;
   }
 }
 else
 {
   if ( activeTradeFrequency == 1 )
   {
     enableStrategy4 = true ;
     enableStrategy5 = true ;
     enableStrategy6 = false ;
     enableStrategy7 = false ;
     enableStrategy8 = false ;
     enableStrategy9 = false ;
     enabledStrategyRiskWeight = 3.4 ;
     if ( UseVariableValues )
     {
       enabledStrategyRiskWeight = 4.0 ;
     }
   }
   else
   {
     if ( activeTradeFrequency == 2 )
     {
       enableStrategy4 = true ;
       enableStrategy5 = true ;
       enableStrategy6 = true ;
       enableStrategy7 = true ;
       enableStrategy8 = false ;
       enableStrategy9 = false ;
       enabledStrategyRiskWeight = 4.1 ;
       if ( UseVariableValues )
       {
         enabledStrategyRiskWeight = 5.0 ;
       }
     }
     else
     {
       if ( activeTradeFrequency == 3 )
       {
         enableStrategy4 = true ;
         enableStrategy5 = true ;
         enableStrategy6 = true ;
         enableStrategy7 = true ;
         enableStrategy8 = true ;
         enableStrategy9 = false ;
         enabledStrategyRiskWeight = 4.8 ;
         if ( UseVariableValues )
         {
           enabledStrategyRiskWeight = 5.6 ;
         }
       }
       else
       {
         if ( activeTradeFrequency == 4 )
         {
           enableStrategy4 = true ;
           enableStrategy5 = true ;
           enableStrategy6 = true ;
           enableStrategy7 = true ;
           enableStrategy8 = true ;
           enableStrategy9 = true ;
           enabledStrategyRiskWeight = 5.1 ;
           if ( UseVariableValues )
           {
             enabledStrategyRiskWeight = 6.0 ;
           }
         }
         else
         {
           if ( activeTradeFrequency == 6 )
           {
             enableStrategy1 = RunStrat1 ;
             enableStrategy2 = RunStrat2 ;
             enableStrategy3 = RunStrat3 ;
             enableStrategy4 = RunStrat4 ;
             enableStrategy5 = RunStrat5 ;
             enableStrategy6 = RunStrat6 ;
             enableStrategy7 = RunStrat7 ;
             enableStrategy8 = RunStrat8 ;
             enableStrategy9 = RunStrat9 ;
           }
         }
       }
     }
   }
 }
 if ( iBars(currentSymbol,NormalizeTimeframe(PERIOD_D1)) != lastDailyBarCount )
 {
   lastDailyBarCount = iBars(currentSymbol,NormalizeTimeframe(PERIOD_D1)) ;
   dailyDrawdownLockActive = false ;
   dailyDrawdownReference = 0.0 ;
 }
 if ( PropFirmMaxDailyDD>0.0 )
 {
   EnforcePropFirmDailyDrawdown(); 
 }
 if ( dailyDrawdownLockActive || !(pairInitializationSucceeded) )   return;
 refreshPerformanceThisHour = false ;
 if ( lastPerformanceRefreshH1BarTime != iTime(currentSymbol,NormalizeTimeframe(PERIOD_H1),1) )
 {
   refreshPerformanceThisHour = true ;
   lastPerformanceRefreshH1BarTime = iTime(currentSymbol,NormalizeTimeframe(PERIOD_H1),1) ;
 }
 if ( ( StringFind(Symbol(),"XAUUSD",0) >= 0 || StringFind(Symbol(),"xauusd",0) >= 0 || StringFind(Symbol(),"GOLD",0) >= 0 || StringFind(Symbol(),"GLD",0) >= 0 || StringFind(Symbol(),"gold",0) >= 0 || StringFind(Symbol(),"Gold",0) >= 0 ) )
 {
   currentSymbol = Symbol() ;
   if ( enableStrategy1 )
   {
     LoadStrategy1Profile(); 
     LoadStrategyRuntimeContext(0); 
     RunStrategyCycle(0); 
     if ( refreshPerformanceThisHour )
     {
       if ( MQLInfoInteger(MQL_TESTER) == 1 && !(UpdateInfoTesting) )
       {
         strategy1DisplayedProfit = 0.0;
       }
       else
       {
         strategy1ProfitAccumulator = 0.0;
         totalTradeCountByStrategy[currentStrategyIndex] = 0;
         for (strategy1HistoryIndex = ClosedTradeCount() ; strategy1HistoryIndex >= 0 ; strategy1HistoryIndex=strategy1HistoryIndex - 1)
         {
           if ( SelectTradeRecord(strategy1HistoryIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_HISTORY) != true || SelectedTradeSymbol() != currentSymbol || SelectedTradeMagic() != strategyMagicNumber )   continue;
           
           if ( ( SelectedTradeType() != ORDER_TYPE_BUY && SelectedTradeType() != ORDER_TYPE_SELL ) )   continue;
           totalTradeCountByStrategy[currentStrategyIndex] ++;
           strategy1ProfitAccumulator = strategy1ProfitAccumulator + SelectedTradeProfit() + SelectedTradeSwap() + SelectedTradeCommission();
           
         }
         strategy1DisplayedProfit = strategy1ProfitAccumulator;
       }
       strategyDisplayProfit[0] = strategy1DisplayedProfit;
       if ( strategyDisplayProfit[0]!=0.0 && totalTradeCountByStrategy[0] >  0 )
       {
         averageProfitByStrategy[0] = strategyDisplayProfit[0] / totalTradeCountByStrategy[0];
       }
     }
   }
   if ( enableStrategy4 )
   {
     LoadStrategy2Profile(); 
     LoadStrategyRuntimeContext(3); 
     RunStrategyCycle(3); 
     if ( refreshPerformanceThisHour )
     {
       if ( MQLInfoInteger(MQL_TESTER) == 1 && !(UpdateInfoTesting) )
       {
         strategy4DisplayedProfit = 0.0;
       }
       else
       {
         strategy4ProfitAccumulator = 0.0;
         totalTradeCountByStrategy[currentStrategyIndex] = 0;
         for (strategy4HistoryIndex = ClosedTradeCount() ; strategy4HistoryIndex >= 0 ; strategy4HistoryIndex=strategy4HistoryIndex - 1)
         {
           if ( SelectTradeRecord(strategy4HistoryIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_HISTORY) != true || SelectedTradeSymbol() != currentSymbol || SelectedTradeMagic() != strategyMagicNumber )   continue;
           
           if ( ( SelectedTradeType() != ORDER_TYPE_BUY && SelectedTradeType() != ORDER_TYPE_SELL ) )   continue;
           totalTradeCountByStrategy[currentStrategyIndex] ++;
           strategy4ProfitAccumulator = strategy4ProfitAccumulator + SelectedTradeProfit() + SelectedTradeSwap() + SelectedTradeCommission();
           
         }
         strategy4DisplayedProfit = strategy4ProfitAccumulator;
       }
       strategyDisplayProfit[3] = strategy4DisplayedProfit;
       if ( strategyDisplayProfit[3]!=0.0 && totalTradeCountByStrategy[3] >  0 )
       {
         averageProfitByStrategy[3] = strategyDisplayProfit[3] / totalTradeCountByStrategy[3];
       }
     }
   }
   if ( enableStrategy2 )
   {
     LoadStrategy3Profile(); 
     LoadStrategyRuntimeContext(1); 
     RunStrategyCycle(1); 
     if ( refreshPerformanceThisHour )
     {
       if ( MQLInfoInteger(MQL_TESTER) == 1 && !(UpdateInfoTesting) )
       {
         strategy2DisplayedProfit = 0.0;
       }
       else
       {
         strategy2ProfitAccumulator = 0.0;
         totalTradeCountByStrategy[currentStrategyIndex] = 0;
         for (strategy2HistoryIndex = ClosedTradeCount() ; strategy2HistoryIndex >= 0 ; strategy2HistoryIndex=strategy2HistoryIndex - 1)
         {
           if ( SelectTradeRecord(strategy2HistoryIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_HISTORY) != true || SelectedTradeSymbol() != currentSymbol || SelectedTradeMagic() != strategyMagicNumber )   continue;
           
           if ( ( SelectedTradeType() != ORDER_TYPE_BUY && SelectedTradeType() != ORDER_TYPE_SELL ) )   continue;
           totalTradeCountByStrategy[currentStrategyIndex] ++;
           strategy2ProfitAccumulator = strategy2ProfitAccumulator + SelectedTradeProfit() + SelectedTradeSwap() + SelectedTradeCommission();
           
         }
         strategy2DisplayedProfit = strategy2ProfitAccumulator;
       }
       strategyDisplayProfit[1] = strategy2DisplayedProfit;
       if ( strategyDisplayProfit[1]!=0.0 && totalTradeCountByStrategy[1] >  0 )
       {
         averageProfitByStrategy[1] = strategyDisplayProfit[1] / totalTradeCountByStrategy[1];
       }
     }
   }
   if ( enableStrategy3 )
   {
     LoadStrategy4Profile(); 
     LoadStrategyRuntimeContext(2); 
     RunStrategyCycle(2); 
     if ( refreshPerformanceThisHour )
     {
       if ( MQLInfoInteger(MQL_TESTER) == 1 && !(UpdateInfoTesting) )
       {
         strategy3DisplayedProfit = 0.0;
       }
       else
       {
         strategy3ProfitAccumulator = 0.0;
         totalTradeCountByStrategy[currentStrategyIndex] = 0;
         for (strategy3HistoryIndex = ClosedTradeCount() ; strategy3HistoryIndex >= 0 ; strategy3HistoryIndex=strategy3HistoryIndex - 1)
         {
           if ( SelectTradeRecord(strategy3HistoryIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_HISTORY) != true || SelectedTradeSymbol() != currentSymbol || SelectedTradeMagic() != strategyMagicNumber )   continue;
           
           if ( ( SelectedTradeType() != ORDER_TYPE_BUY && SelectedTradeType() != ORDER_TYPE_SELL ) )   continue;
           totalTradeCountByStrategy[currentStrategyIndex] ++;
           strategy3ProfitAccumulator = strategy3ProfitAccumulator + SelectedTradeProfit() + SelectedTradeSwap() + SelectedTradeCommission();
           
         }
         strategy3DisplayedProfit = strategy3ProfitAccumulator;
       }
       strategyDisplayProfit[2] = strategy3DisplayedProfit;
       if ( strategyDisplayProfit[2]!=0.0 && totalTradeCountByStrategy[2] >  0 )
       {
         averageProfitByStrategy[2] = strategyDisplayProfit[2] / totalTradeCountByStrategy[2];
       }
     }
   }
   if ( enableStrategy6 )
   {
     LoadStrategy5Profile(); 
     LoadStrategyRuntimeContext(5); 
     RunStrategyCycle(5); 
     if ( refreshPerformanceThisHour )
     {
       if ( MQLInfoInteger(MQL_TESTER) == 1 && !(UpdateInfoTesting) )
       {
         strategy6DisplayedProfit = 0.0;
       }
       else
       {
         strategy6ProfitAccumulator = 0.0;
         totalTradeCountByStrategy[currentStrategyIndex] = 0;
         for (strategy6HistoryIndex = ClosedTradeCount() ; strategy6HistoryIndex >= 0 ; strategy6HistoryIndex=strategy6HistoryIndex - 1)
         {
           if ( SelectTradeRecord(strategy6HistoryIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_HISTORY) != true || SelectedTradeSymbol() != currentSymbol || SelectedTradeMagic() != strategyMagicNumber )   continue;
           
           if ( ( SelectedTradeType() != ORDER_TYPE_BUY && SelectedTradeType() != ORDER_TYPE_SELL ) )   continue;
           totalTradeCountByStrategy[currentStrategyIndex] ++;
           strategy6ProfitAccumulator = strategy6ProfitAccumulator + SelectedTradeProfit() + SelectedTradeSwap() + SelectedTradeCommission();
           
         }
         strategy6DisplayedProfit = strategy6ProfitAccumulator;
       }
       strategyDisplayProfit[5] = strategy6DisplayedProfit;
       if ( strategyDisplayProfit[5]!=0.0 && totalTradeCountByStrategy[5] >  0 )
       {
         averageProfitByStrategy[5] = strategyDisplayProfit[5] / totalTradeCountByStrategy[5];
       }
     }
   }
   if ( enableStrategy5 )
   {
     LoadStrategy6Profile(); 
     LoadStrategyRuntimeContext(4); 
     RunStrategyCycle(4); 
     if ( refreshPerformanceThisHour )
     {
       if ( MQLInfoInteger(MQL_TESTER) == 1 && !(UpdateInfoTesting) )
       {
         strategy5DisplayedProfit = 0.0;
       }
       else
       {
         strategy5ProfitAccumulator = 0.0;
         totalTradeCountByStrategy[currentStrategyIndex] = 0;
         for (strategy5HistoryIndex = ClosedTradeCount() ; strategy5HistoryIndex >= 0 ; strategy5HistoryIndex=strategy5HistoryIndex - 1)
         {
           if ( SelectTradeRecord(strategy5HistoryIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_HISTORY) != true || SelectedTradeSymbol() != currentSymbol || SelectedTradeMagic() != strategyMagicNumber )   continue;
           
           if ( ( SelectedTradeType() != ORDER_TYPE_BUY && SelectedTradeType() != ORDER_TYPE_SELL ) )   continue;
           totalTradeCountByStrategy[currentStrategyIndex] ++;
           strategy5ProfitAccumulator = strategy5ProfitAccumulator + SelectedTradeProfit() + SelectedTradeSwap() + SelectedTradeCommission();
           
         }
         strategy5DisplayedProfit = strategy5ProfitAccumulator;
       }
       strategyDisplayProfit[4] = strategy5DisplayedProfit;
       if ( strategyDisplayProfit[4]!=0.0 && totalTradeCountByStrategy[4] >  0 )
       {
         averageProfitByStrategy[4] = strategyDisplayProfit[4] / totalTradeCountByStrategy[4];
       }
     }
   }
   if ( enableStrategy9 )
   {
     LoadStrategy7Profile(); 
     LoadStrategyRuntimeContext(8); 
     RunStrategyCycle(8); 
     if ( refreshPerformanceThisHour )
     {
       if ( MQLInfoInteger(MQL_TESTER) == 1 && !(UpdateInfoTesting) )
       {
         strategy9DisplayedProfit = 0.0;
       }
       else
       {
         strategy9ProfitAccumulator = 0.0;
         totalTradeCountByStrategy[currentStrategyIndex] = 0;
         for (strategy9HistoryIndex = ClosedTradeCount() ; strategy9HistoryIndex >= 0 ; strategy9HistoryIndex=strategy9HistoryIndex - 1)
         {
           if ( SelectTradeRecord(strategy9HistoryIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_HISTORY) != true || SelectedTradeSymbol() != currentSymbol || SelectedTradeMagic() != strategyMagicNumber )   continue;
           
           if ( ( SelectedTradeType() != ORDER_TYPE_BUY && SelectedTradeType() != ORDER_TYPE_SELL ) )   continue;
           totalTradeCountByStrategy[currentStrategyIndex] ++;
           strategy9ProfitAccumulator = strategy9ProfitAccumulator + SelectedTradeProfit() + SelectedTradeSwap() + SelectedTradeCommission();
           
         }
         strategy9DisplayedProfit = strategy9ProfitAccumulator;
       }
       strategyDisplayProfit[8] = strategy9DisplayedProfit;
       if ( strategyDisplayProfit[8]!=0.0 && totalTradeCountByStrategy[8] >  0 )
       {
         averageProfitByStrategy[8] = strategyDisplayProfit[8] / totalTradeCountByStrategy[8];
       }
     }
   }
   if ( enableStrategy7 )
   {
     LoadStrategy8Profile(); 
     LoadStrategyRuntimeContext(6); 
     RunStrategyCycle(6); 
     if ( refreshPerformanceThisHour )
     {
       if ( MQLInfoInteger(MQL_TESTER) == 1 && !(UpdateInfoTesting) )
       {
         strategy7DisplayedProfit = 0.0;
       }
       else
       {
         strategy7ProfitAccumulator = 0.0;
         totalTradeCountByStrategy[currentStrategyIndex] = 0;
         for (strategy7HistoryIndex = ClosedTradeCount() ; strategy7HistoryIndex >= 0 ; strategy7HistoryIndex=strategy7HistoryIndex - 1)
         {
           if ( SelectTradeRecord(strategy7HistoryIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_HISTORY) != true || SelectedTradeSymbol() != currentSymbol || SelectedTradeMagic() != strategyMagicNumber )   continue;
           
           if ( ( SelectedTradeType() != ORDER_TYPE_BUY && SelectedTradeType() != ORDER_TYPE_SELL ) )   continue;
           totalTradeCountByStrategy[currentStrategyIndex] ++;
           strategy7ProfitAccumulator = strategy7ProfitAccumulator + SelectedTradeProfit() + SelectedTradeSwap() + SelectedTradeCommission();
           
         }
         strategy7DisplayedProfit = strategy7ProfitAccumulator;
       }
       strategyDisplayProfit[6] = strategy7DisplayedProfit;
       if ( strategyDisplayProfit[6]!=0.0 && totalTradeCountByStrategy[6] >  0 )
       {
         averageProfitByStrategy[6] = strategyDisplayProfit[6] / totalTradeCountByStrategy[6];
       }
     }
   }
   if ( enableStrategy8 )
   {
     LoadStrategy9Profile(); 
     LoadStrategyRuntimeContext(7); 
     RunStrategyCycle(7); 
     if ( refreshPerformanceThisHour )
     {
       if ( MQLInfoInteger(MQL_TESTER) == 1 && !(UpdateInfoTesting) )
       {
         strategy8DisplayedProfit = 0.0;
       }
       else
       {
         strategy8ProfitAccumulator = 0.0;
         totalTradeCountByStrategy[currentStrategyIndex] = 0;
         for (strategy8HistoryIndex = ClosedTradeCount() ; strategy8HistoryIndex >= 0 ; strategy8HistoryIndex=strategy8HistoryIndex - 1)
         {
           if ( SelectTradeRecord(strategy8HistoryIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_HISTORY) != true || SelectedTradeSymbol() != currentSymbol || SelectedTradeMagic() != strategyMagicNumber )   continue;
           
           if ( ( SelectedTradeType() != ORDER_TYPE_BUY && SelectedTradeType() != ORDER_TYPE_SELL ) )   continue;
           totalTradeCountByStrategy[currentStrategyIndex] ++;
           strategy8ProfitAccumulator = strategy8ProfitAccumulator + SelectedTradeProfit() + SelectedTradeSwap() + SelectedTradeCommission();
           
         }
         strategy8DisplayedProfit = strategy8ProfitAccumulator;
       }
       strategyDisplayProfit[7] = strategy8DisplayedProfit;
       if ( strategyDisplayProfit[7]!=0.0 && totalTradeCountByStrategy[7] >  0 )
       {
         averageProfitByStrategy[7] = strategyDisplayProfit[7] / totalTradeCountByStrategy[7];
       }
     }
   }
 }
 else
 {
   currentSymbol = Symbol() ;
   RunStrategyCycle(0); 
 }
 UpdateInfoPanelSummary(); 
 if ( iTime(Symbol(),PERIOD_M5,1) != lastPanelRefreshM5BarTime )
 {
   lastPanelRefreshM5BarTime = iTime(Symbol(),PERIOD_M5,1) ;
   UpdateInfoPanelStrategyRows(); 
   UpdateInfoPanelTotals(); 
 }
 panelRefreshTickCounter ++;
 if ( panelRefreshTickCounter < 2 )   return;
 lastLotResizeBalance = AccountInfoDouble(ACCOUNT_BALANCE) ;
 panelRefreshTickCounter = 0 ;
 }
//OnTick <<==--------   --------
 void OnDeinit(const int reason)
 {
 DeleteInfoPanel(); 
 }
//deinit <<==--------   --------

//+------------------------------------------------------------------+
//| Xu ly ngay giao dich nap/rut tien khi EA dang chay.               |
//+------------------------------------------------------------------+
 void OnTradeTransaction(const MqlTradeTransaction &trans,
                         const MqlTradeRequest &request,
                         const MqlTradeResult &result)
 {
  if ( !(OnlyUp) || ManualBalance>0.0 )   return;
  if ( trans.type!=TRADE_TRANSACTION_DEAL_ADD || trans.deal==0 )   return;
  if ( !(HistoryDealSelect(trans.deal)) )   return;
  ENUM_DEAL_TYPE transactionDealType = (ENUM_DEAL_TYPE)HistoryDealGetInteger(trans.deal,DEAL_TYPE) ;
  if ( transactionDealType!=DEAL_TYPE_BALANCE )   return;
  long transactionDealTimeMsc = (long)HistoryDealGetInteger(trans.deal,DEAL_TIME_MSC) ;
  // Giao dich da duoc ReconcileOnlyUpWithdrawals() xu ly luc khoi dong.
  if ( transactionDealTimeMsc<=onlyUpWithdrawScannedMsc )   return;
  double transactionDealAmount = HistoryDealGetDouble(trans.deal,DEAL_PROFIT) ;
  if ( transactionDealAmount<0.0 )   ApplyOnlyUpWithdrawal(transactionDealAmount) ;
  onlyUpWithdrawScannedMsc = transactionDealTimeMsc ;
  GlobalVariableSet(OnlyUpWithdrawGVName(),(double)onlyUpWithdrawScannedMsc) ;
 }
//OnTradeTransaction <<==--------   --------
 void LoadStrategyRuntimeContext( int strategyIndex)
 {
 currentStrategyIndex = strategyIndex ;
 symbolPoint = SymbolInfoDouble(currentSymbol,SYMBOL_POINT) ;
 pipSize = symbolPoint ;
 if ( ( ((double)SymbolInfoInteger(currentSymbol,SYMBOL_DIGITS))==3.0 || ((double)SymbolInfoInteger(currentSymbol,SYMBOL_DIGITS))==5.0 ) )
 {
   pipSize = symbolPoint * 10.0 ;
 }
 if ( SymbolInfoInteger(currentSymbol,SYMBOL_DIGITS) == 1 )
 {
   pipSize = symbolPoint / 10.0 ;
 }
 symbolDigits = (int)((double)SymbolInfoInteger(currentSymbol,SYMBOL_DIGITS)) ;
 currentSpreadPrice = SymbolInfoDouble(currentSymbol,SYMBOL_ASK) - SymbolInfoDouble(currentSymbol,SYMBOL_BID) ;
 stopLevelPriceDistance = ((double)SymbolInfoInteger(currentSymbol,SYMBOL_TRADE_STOPS_LEVEL)) * symbolPoint ;
 freezeLevelPriceDistance = ((double)SymbolInfoInteger(currentSymbol,SYMBOL_TRADE_FREEZE_LEVEL)) * symbolPoint ;
 pendingExpirationSeconds=pendingExpirationHours * 60 * 60;
 if ( pendingExpirationHours >  0 )
 {
   pendingOrderExpirationTime=TimeCurrent() + pendingExpirationSeconds;
 }
 else
 {
   pendingOrderExpirationTime = 0 ;
 }
 if ( Virtual_expiration )
 {
   pendingOrderExpirationTime = 0 ;
 }
 variableLotInverseScaleFactor = 1.0 ;
 if ( !(UseVariableValues) )   return;
 
 if ( lotSizeReferenceBalance>0.0 )
 {
   variableValueScaleFactor = iOpen(currentSymbol,NormalizeTimeframe(PERIOD_D1),1) / lotSizeReferenceBalance ;
 }
 else
 {
   variableValueScaleFactor = 1.0 ;
 }
 if ( AdjustLotsizeToVariableValues )
 {
   variableLotInverseScaleFactor = 1.0 / variableValueScaleFactor ;
 }
 else
 {
   variableLotInverseScaleFactor = 1.0 ;
 }
 minEntryDistancePips = minEntryDistancePips * variableValueScaleFactor ;
 buyEntryOffsetPips = NormalizeDouble(buyEntryOffsetPips * variableValueScaleFactor,0) ;
 sellEntryOffsetPips = NormalizeDouble(sellEntryOffsetPips * variableValueScaleFactor,0) ;
 stopLossPips = stopLossPips * variableValueScaleFactor ;
 takeProfitPips = takeProfitPips * variableValueScaleFactor ;
 trailingSLStartPips = trailingSLStartPips * variableValueScaleFactor ;
 trailingSLDistancePips = trailingSLDistancePips * variableValueScaleFactor ;
 trailingSLStepLimitPips = trailingSLStepLimitPips * variableValueScaleFactor ;
 trailingTPStartPips = trailingTPStartPips * variableValueScaleFactor ;
 trailingTPDistancePips = trailingTPDistancePips * variableValueScaleFactor ;
 breakEvenStartPips = breakEvenStartPips * variableValueScaleFactor ;
 breakEvenExtraPips = breakEvenExtraPips * variableValueScaleFactor ;
 }
//LoadStrategyRuntimeContext <<==--------   --------
 int RunStrategyCycle( int strategyIndex)
 {
  bool      tradeManagementChanged;
  datetime  currentYearNfpTimeGmt;
  int       nfpDateIndex;
  int       nfpDstAdjustmentMinutes;
  string    fallbackNfpDateText;
  datetime  fallbackNfpTime;
  int       randomizedEntryOffsetPips;
  int       pendingPlacementAttemptIndex;
//----------------------------------------------------------------------
 int        storedOrderRowIndex;
 int        storedOrderFieldIndex;
 int        storedOrderCount;
 int        orderStorageScanIndex;
 int        primaryBuyDeleteMode;
 int        primaryBuyDeleteIndex;
 int        manualBuyDeleteIndex;
 int        primarySellDeleteMode;
 int        primarySellDeleteIndex;
 int        manualSellDeleteIndex;
 int        legacyManualBuyDeleteMode;
 int        legacyManualBuyDeleteIndex;
 int        legacyManualSellDeleteMode;
 int        legacyManualSellDeleteIndex;
 int        nfpEventYear;
 int        nfpEventMonth;
 int        nfpPrimaryBuyDeleteMode;
 int        nfpPrimaryBuyDeleteIndex;
 int        nfpManualBuyDeleteIndex;
 int        nfpPrimarySellDeleteMode;
 int        nfpPrimarySellDeleteIndex;
 int        nfpManualSellDeleteIndex;
 int        nfpLegacyBuyDeleteMode;
 int        nfpLegacyBuyDeleteIndex;
 int        nfpLegacySellDeleteMode;
 int        nfpLegacySellDeleteIndex;
 int        nfpCloseOrderIndex;
 long        nfpMagicCheck01;
 long        nfpMagicCheck02;
 long        nfpMagicCheck03;
 long        nfpMagicCheck04;
 long        nfpMagicCheck05;
 long        nfpMagicCheck06;
 long        nfpMagicCheck07;
 long        nfpMagicCheck08;
 long        nfpMagicCheck09;
 long        nfpMagicCheck10;
 long        nfpMagicCheck11;
 long        nfpMagicCheck12;
 long        nfpMagicCheck13;
 long        nfpMagicCheck14;
 long        nfpMagicCheck15;
 long        nfpMagicCheck16;
 int        fallbackNfpPrimaryBuyDeleteMode;
 int        fallbackNfpPrimaryBuyDeleteIndex;
 int        fallbackNfpManualBuyDeleteIndex;
 int        fallbackNfpPrimarySellDeleteMode;
 int        fallbackNfpPrimarySellDeleteIndex;
 int        fallbackNfpManualSellDeleteIndex;
 int        fallbackNfpLegacyBuyDeleteMode;
 int        fallbackNfpLegacyBuyDeleteIndex;
 int        fallbackNfpLegacySellDeleteMode;
 int        fallbackNfpLegacySellDeleteIndex;
 int        fallbackNfpCloseOrderIndex;
 long        fallbackNfpMagicCheck01;
 long        fallbackNfpMagicCheck02;
 long        fallbackNfpMagicCheck03;
 long        fallbackNfpMagicCheck04;
 long        fallbackNfpMagicCheck05;
 long        fallbackNfpMagicCheck06;
 long        fallbackNfpMagicCheck07;
 long        fallbackNfpMagicCheck08;
 long        fallbackNfpMagicCheck09;
 long        fallbackNfpMagicCheck10;
 long        fallbackNfpMagicCheck11;
 long        fallbackNfpMagicCheck12;
 long        fallbackNfpMagicCheck13;
 long        fallbackNfpMagicCheck14;
 long        fallbackNfpMagicCheck15;
 long        fallbackNfpMagicCheck16;
 int        fridayCloseOrderIndex;
 long        fridayMagicCheck01;
 long        fridayMagicCheck02;
 long        fridayMagicCheck03;
 long        fridayMagicCheck04;
 long        fridayMagicCheck05;
 long        fridayMagicCheck06;
 long        fridayMagicCheck07;
 long        fridayMagicCheck08;
 long        fridayMagicCheck09;
 long        fridayMagicCheck10;
 long        fridayMagicCheck11;
 long        fridayMagicCheck12;
 long        fridayMagicCheck13;
 long        fridayMagicCheck14;
 long        fridayMagicCheck15;
 long        fridayMagicCheck16;
 int        pendingBuyCount;
 int        pendingBuyCountScanIndex;
 double     highestBuyStopPrice;
 long       highestBuyStopTicket;
 int        highestBuyStopScanIndex;
 long       deletedBuyStopTicket;
 int        buyTicketMapIndex;
 int        pendingSellCount;
 int        pendingSellCountScanIndex;
 double     lowestSellStopPrice;
 long       lowestSellStopTicket;
 int        lowestSellStopScanIndex;
 long       deletedSellStopTicket;
 int        sellTicketMapIndex;
 int        openBuyCount;
 int        openBuyScanIndex;
 int        openSellCount;
 int        openSellScanIndex;
 bool       virtualStopTicketStillOpen;
 int        virtualStopBufferIndex;
 int        virtualStopOrderScanIndex;
 bool       ticketMapEntryStillOpen;
 int        ticketMapIndex;
 long       mappedPendingTicket;
 int        ticketMapOrderScanIndex;
 long       selectedOrderTicket;
 string     debugStatusText;
 int        debugPendingBuyCount;
 int        debugBuyScanIndex;
 int        debugPendingSellCount;
 int        debugSellScanIndex;

 currentStrategyIndex = strategyIndex ;
 tradeManagementChanged = false ;
 
 if ( minimumEntryDistancePercent>0.0 )
 {
   minEntryDistancePips = minimumEntryDistancePercent / 100.0 * SymbolInfoDouble(currentSymbol,SYMBOL_ASK) * 10.0 ;
 }
 if ( exitTimingMode == 0 )
 {
   if ( ManageBuyTrades() )
   {
     tradeManagementChanged = true ;
   }
   if ( ManageSellTrades() )
   {
     tradeManagementChanged = true ;
   }
   if ( tradeManagementChanged )
   {
     return(0); 
   }
 }
 else
 {
   if ( lastExitBarCountByStrategy[currentStrategyIndex] != iBars(currentSymbol,NormalizeTimeframe(exitTimingMode)) )
   {
     lastExitBarCountByStrategy[currentStrategyIndex] = iBars(currentSymbol,NormalizeTimeframe(exitTimingMode));
     if ( ManageBuyTrades() )
     {
       tradeManagementChanged = true ;
     }
     if ( ManageSellTrades() )
     {
       tradeManagementChanged = true ;
     }
     if ( tradeManagementChanged )
     {
       return(0); 
     }
   }
 }
 ResizePendingOrderLots(false); 
 if ( !(IsStrategyTester()) && ((SymbolInfoInteger(currentSymbol,SYMBOL_TRADE_MODE)==SYMBOL_TRADE_MODE_FULL)?1.0:0.0)==0.0 )
 {
   if ( !(marketPauseMessageLogged) )
   {
     Print("Market closed... waiting to continue"); 
   }
   marketPauseMessageLogged = true ;
   return(0); 
 }
 if ( dayChangeRecoveryDelayMinutes >  0 && ( ( CurrentHour() == 0 && CurrentMinute() < dayChangeRecoveryDelayMinutes ) || (CurrentHour() == 23 && dayChangeRecoveryDelayMinutes >  60 - dayChangeRecoveryDelayMinutes) ) )
 {
   if ( !(marketPauseMessageLogged) )
   {
     Print("DAYSWITCH -> Market might be closed... waiting " + string(dayChangeRecoveryDelayMinutes) + " minutes before setting order.."); 
   }
   marketPauseMessageLogged = true ;
   return(0); 
 }
 marketPauseMessageLogged = false ;
 if ( tradingHoursEnabled )
 {
   if ( IsTradingSessionOpen() && tradingHoursState )
   {
     if ( storePendingOrdersOutsideTradingHours )
     {
       RestoreStoredPendingOrders(); 
     }
     tradingHoursState = false ;
   }
   if ( !(IsTradingSessionOpen()) && !(tradingHoursState) )
   {
     Print("ENTERING NON-TRADING HOURS! Closing orders..."); 
     if ( storePendingOrdersOutsideTradingHours )
     {
       for (storedOrderRowIndex = 0 ; storedOrderRowIndex < orderBufferCapacity ; storedOrderRowIndex=storedOrderRowIndex + 1)
       {
         for (storedOrderFieldIndex = 0 ; storedOrderFieldIndex < 2 ; storedOrderFieldIndex=storedOrderFieldIndex + 1)
         {
           storedPendingOrders[storedOrderRowIndex][storedOrderFieldIndex] = 0.0;
         }
       }
       storedOrderCount = 0;
       for (orderStorageScanIndex = ActiveTradeCount() ; orderStorageScanIndex >= 0 ; orderStorageScanIndex=orderStorageScanIndex - 1)
       {
         if ( SelectTradeRecord(orderStorageScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != strategyMagicNumber || SelectedTradeSymbol() != currentSymbol )   continue;
         
         if ( ( SelectedTradeType() != ORDER_TYPE_BUY_STOP && SelectedTradeType() != ORDER_TYPE_SELL_STOP ) )   continue;
         Print("Storing pending order nr " + string(SelectedTradeTicket())); 
         storedPendingOrders[storedOrderCount][1] = SelectedTradeType();
         storedPendingOrders[storedOrderCount][0] = SelectedTradeOpenPrice();
         storedPendingOrders[storedOrderCount][2] = SelectedTradeVolume();
         storedOrderCount=storedOrderCount + 1;
         
       }
     }
     primaryBuyDeleteMode = 1;
     for (primaryBuyDeleteIndex = ActiveTradeCount() ; primaryBuyDeleteIndex >= 0 ; primaryBuyDeleteIndex=primaryBuyDeleteIndex - 1)
     {
       if ( SelectTradeRecord(primaryBuyDeleteIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != strategyMagicNumber || SelectedTradeSymbol() != currentSymbol || SelectedTradeType() != ORDER_TYPE_BUY_STOP )   continue;
       DeletePendingOrderByTicket(SelectedTradeTicket(),clrNONE); 
       
     }
     if ( primaryBuyDeleteMode == 2 )
     {
       for (manualBuyDeleteIndex = ActiveTradeCount() ; manualBuyDeleteIndex >= 0 ; manualBuyDeleteIndex=manualBuyDeleteIndex - 1)
       {
         if ( SelectTradeRecord(manualBuyDeleteIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != manualStrategy2MagicNumber || SelectedTradeSymbol() != currentSymbol || SelectedTradeType() != ORDER_TYPE_BUY_STOP )   continue;
         DeletePendingOrderByTicket(SelectedTradeTicket(),clrNONE); 
         
       }
     }
     primarySellDeleteMode = 1;
     for (primarySellDeleteIndex = ActiveTradeCount() ; primarySellDeleteIndex >= 0 ; primarySellDeleteIndex=primarySellDeleteIndex - 1)
     {
       if ( SelectTradeRecord(primarySellDeleteIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != strategyMagicNumber || SelectedTradeSymbol() != currentSymbol || SelectedTradeType() != ORDER_TYPE_SELL_STOP )   continue;
       DeletePendingOrderByTicket(SelectedTradeTicket(),clrNONE); 
       
     }
     if ( primarySellDeleteMode == 2 )
     {
       for (manualSellDeleteIndex = ActiveTradeCount() ; manualSellDeleteIndex >= 0 ; manualSellDeleteIndex=manualSellDeleteIndex - 1)
       {
         if ( SelectTradeRecord(manualSellDeleteIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != manualStrategy2MagicNumber || SelectedTradeSymbol() != currentSymbol || SelectedTradeType() != ORDER_TYPE_SELL_STOP )   continue;
         DeletePendingOrderByTicket(SelectedTradeTicket(),clrNONE); 
         
       }
     }
     legacyManualBuyDeleteMode = 2;
     if(1==0) // Điều kiện luôn sai; giữ nguyên nhánh vô hiệu từ mã gốc.
     {
       do
       {
         if ( SelectTradeRecord(1,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != strategyMagicNumber || SelectedTradeSymbol() != currentSymbol || SelectedTradeType() != ORDER_TYPE_BUY_STOP )   continue;
         DeletePendingOrderByTicket(SelectedTradeTicket(),clrNONE); 
         
       }
       while( - 1 >= 0);
       
     }
     if ( legacyManualBuyDeleteMode == 2 )
     {
       for (legacyManualBuyDeleteIndex = ActiveTradeCount() ; legacyManualBuyDeleteIndex >= 0 ; legacyManualBuyDeleteIndex=legacyManualBuyDeleteIndex - 1)
       {
         if ( SelectTradeRecord(legacyManualBuyDeleteIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != manualStrategy2MagicNumber || SelectedTradeSymbol() != currentSymbol || SelectedTradeType() != ORDER_TYPE_BUY_STOP )   continue;
         DeletePendingOrderByTicket(SelectedTradeTicket(),clrNONE); 
         
       }
     }
     legacyManualSellDeleteMode = 2;
     if(1==0) // Điều kiện luôn sai; giữ nguyên nhánh vô hiệu từ mã gốc.
     {
       do
       {
         if ( SelectTradeRecord(1,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != strategyMagicNumber || SelectedTradeSymbol() != currentSymbol || SelectedTradeType() != ORDER_TYPE_SELL_STOP )   continue;
         DeletePendingOrderByTicket(SelectedTradeTicket(),clrNONE); 
         
       }
       while( - 1 >= 0);
       
     }
     if ( legacyManualSellDeleteMode == 2 )
     {
       for (legacyManualSellDeleteIndex = ActiveTradeCount() ; legacyManualSellDeleteIndex >= 0 ; legacyManualSellDeleteIndex=legacyManualSellDeleteIndex - 1)
       {
         if ( SelectTradeRecord(legacyManualSellDeleteIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != manualStrategy2MagicNumber || SelectedTradeSymbol() != currentSymbol || SelectedTradeType() != ORDER_TYPE_SELL_STOP )   continue;
         DeletePendingOrderByTicket(SelectedTradeTicket(),clrNONE); 
         
       }
     }
     tradingHoursState = true ;
     return(0); 
   }
 }
 if ( EnableNFP_Filter )
 {
   if ( CurrentYear() <= 2026 || nfpFromCalendar )
   {
     currentYearNfpTimeGmt = 0 ;
     for (nfpDateIndex = 0 ; nfpDateIndex < 300 ; nfpDateIndex ++)
     {
       nfpEventYear = DateTimeYear(nfpDatesGmt[nfpDateIndex]);
       if ( nfpEventYear != CurrentYear() )   continue;
       nfpEventMonth = DateTimeMonth(nfpDatesGmt[nfpDateIndex]);
       if ( nfpEventMonth != CurrentMonth() )   continue;
       currentYearNfpTimeGmt = nfpDatesGmt[nfpDateIndex] ;
       break;
       
     }
     nfpDstAdjustmentMinutes = 60 ;
     if ( IsAmericanDaylightSavingTime() )
     {
       nfpDstAdjustmentMinutes = 0 ;
     }
     if ( currentGmtTime >= currentYearNfpTimeGmt - NFP_MinutesBefore * 60 + nfpDstAdjustmentMinutes * 60 && currentGmtTime <= currentYearNfpTimeGmt + NFP_MinutesAfter * 60 + nfpDstAdjustmentMinutes * 60 )
     {
       if ( NFP_ClosePendingOrders )
       {
         nfpPrimaryBuyDeleteMode = 1;
         for (nfpPrimaryBuyDeleteIndex = ActiveTradeCount() ; nfpPrimaryBuyDeleteIndex >= 0 ; nfpPrimaryBuyDeleteIndex=nfpPrimaryBuyDeleteIndex - 1)
         {
           if ( SelectTradeRecord(nfpPrimaryBuyDeleteIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != strategyMagicNumber || SelectedTradeSymbol() != currentSymbol || SelectedTradeType() != ORDER_TYPE_BUY_STOP )   continue;
           DeletePendingOrderByTicket(SelectedTradeTicket(),clrNONE); 
           
         }
         if ( nfpPrimaryBuyDeleteMode == 2 )
         {
           for (nfpManualBuyDeleteIndex = ActiveTradeCount() ; nfpManualBuyDeleteIndex >= 0 ; nfpManualBuyDeleteIndex=nfpManualBuyDeleteIndex - 1)
           {
             if ( SelectTradeRecord(nfpManualBuyDeleteIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != manualStrategy2MagicNumber || SelectedTradeSymbol() != currentSymbol || SelectedTradeType() != ORDER_TYPE_BUY_STOP )   continue;
             DeletePendingOrderByTicket(SelectedTradeTicket(),clrNONE); 
             
           }
         }
         nfpPrimarySellDeleteMode = 1;
         for (nfpPrimarySellDeleteIndex = ActiveTradeCount() ; nfpPrimarySellDeleteIndex >= 0 ; nfpPrimarySellDeleteIndex=nfpPrimarySellDeleteIndex - 1)
         {
           if ( SelectTradeRecord(nfpPrimarySellDeleteIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != strategyMagicNumber || SelectedTradeSymbol() != currentSymbol || SelectedTradeType() != ORDER_TYPE_SELL_STOP )   continue;
           DeletePendingOrderByTicket(SelectedTradeTicket(),clrNONE); 
           
         }
         if ( nfpPrimarySellDeleteMode == 2 )
         {
           for (nfpManualSellDeleteIndex = ActiveTradeCount() ; nfpManualSellDeleteIndex >= 0 ; nfpManualSellDeleteIndex=nfpManualSellDeleteIndex - 1)
           {
             if ( SelectTradeRecord(nfpManualSellDeleteIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != manualStrategy2MagicNumber || SelectedTradeSymbol() != currentSymbol || SelectedTradeType() != ORDER_TYPE_SELL_STOP )   continue;
             DeletePendingOrderByTicket(SelectedTradeTicket(),clrNONE); 
             
           }
         }
         nfpLegacyBuyDeleteMode = 2;
         if(1==0) // Điều kiện luôn sai; giữ nguyên nhánh vô hiệu từ mã gốc.
         {
           do
           {
             if ( SelectTradeRecord(1,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != strategyMagicNumber || SelectedTradeSymbol() != currentSymbol || SelectedTradeType() != ORDER_TYPE_BUY_STOP )   continue;
             DeletePendingOrderByTicket(SelectedTradeTicket(),clrNONE); 
             
           }
           while( - 1 >= 0);
           
         }
         if ( nfpLegacyBuyDeleteMode == 2 )
         {
           for (nfpLegacyBuyDeleteIndex = ActiveTradeCount() ; nfpLegacyBuyDeleteIndex >= 0 ; nfpLegacyBuyDeleteIndex=nfpLegacyBuyDeleteIndex - 1)
           {
             if ( SelectTradeRecord(nfpLegacyBuyDeleteIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != manualStrategy2MagicNumber || SelectedTradeSymbol() != currentSymbol || SelectedTradeType() != ORDER_TYPE_BUY_STOP )   continue;
             DeletePendingOrderByTicket(SelectedTradeTicket(),clrNONE); 
             
           }
         }
         nfpLegacySellDeleteMode = 2;
         if(1==0) // Điều kiện luôn sai; giữ nguyên nhánh vô hiệu từ mã gốc.
         {
           do
           {
             if ( SelectTradeRecord(1,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != strategyMagicNumber || SelectedTradeSymbol() != currentSymbol || SelectedTradeType() != ORDER_TYPE_SELL_STOP )   continue;
             DeletePendingOrderByTicket(SelectedTradeTicket(),clrNONE); 
             
           }
           while( - 1 >= 0);
           
         }
         if ( nfpLegacySellDeleteMode == 2 )
         {
           for (nfpLegacySellDeleteIndex = ActiveTradeCount() ; nfpLegacySellDeleteIndex >= 0 ; nfpLegacySellDeleteIndex=nfpLegacySellDeleteIndex - 1)
           {
             if ( SelectTradeRecord(nfpLegacySellDeleteIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != manualStrategy2MagicNumber || SelectedTradeSymbol() != currentSymbol || SelectedTradeType() != ORDER_TYPE_SELL_STOP )   continue;
             DeletePendingOrderByTicket(SelectedTradeTicket(),clrNONE); 
             
           }
         }
       }
       if ( NFP_CloseOpenTrades )
       {
         for (nfpCloseOrderIndex = ActiveTradeCount() ; nfpCloseOrderIndex >= 0 ; nfpCloseOrderIndex=nfpCloseOrderIndex - 1)
         {
           if ( SelectTradeRecord(nfpCloseOrderIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeSymbol() != currentSymbol )   continue;
           nfpMagicCheck01 = SelectedTradeMagic();
           nfpMagicCheck02=ST1_MagicNumber + 1;
           if ( nfpMagicCheck01 != nfpMagicCheck02 )
           {
             nfpMagicCheck02 = SelectedTradeMagic();
             nfpMagicCheck03=ST1_MagicNumber + 2;
             if ( nfpMagicCheck02 != nfpMagicCheck03 )
             {
               nfpMagicCheck03 = SelectedTradeMagic();
               nfpMagicCheck04=ST1_MagicNumber + 3;
               if ( nfpMagicCheck03 != nfpMagicCheck04 )
               {
                 nfpMagicCheck04 = SelectedTradeMagic();
                 nfpMagicCheck05=ST1_MagicNumber + 4;
                 if ( nfpMagicCheck04 != nfpMagicCheck05 )
                 {
                   nfpMagicCheck05 = SelectedTradeMagic();
                   nfpMagicCheck06=ST1_MagicNumber + 5;
                   if ( nfpMagicCheck05 != nfpMagicCheck06 )
                   {
                     nfpMagicCheck06 = SelectedTradeMagic();
                     nfpMagicCheck07=ST1_MagicNumber + 6;
                     if ( nfpMagicCheck06 != nfpMagicCheck07 )
                     {
                       nfpMagicCheck07 = SelectedTradeMagic();
                       nfpMagicCheck08=ST1_MagicNumber + 7;
                       if ( nfpMagicCheck07 != nfpMagicCheck08 )
                       {
                         nfpMagicCheck08 = SelectedTradeMagic();
                         nfpMagicCheck09=ST1_MagicNumber + 8;
                         if ( nfpMagicCheck08 != nfpMagicCheck09 )
                         {
                           nfpMagicCheck09 = SelectedTradeMagic();
                           nfpMagicCheck10=ST1_MagicNumber + 9;
                           if ( nfpMagicCheck09 != nfpMagicCheck10 )
                           {
                             nfpMagicCheck10 = SelectedTradeMagic();
                             nfpMagicCheck11=ST1_MagicNumber + 10;
                             if ( nfpMagicCheck10 != nfpMagicCheck11 )
                             {
                               nfpMagicCheck11 = SelectedTradeMagic();
                               nfpMagicCheck12=ST1_MagicNumber + 11;
                               if ( nfpMagicCheck11 != nfpMagicCheck12 )
                               {
                                 nfpMagicCheck12 = SelectedTradeMagic();
                                 nfpMagicCheck13=ST1_MagicNumber + 12;
                                 if ( nfpMagicCheck12 != nfpMagicCheck13 )
                                 {
                                   nfpMagicCheck13 = SelectedTradeMagic();
                                   nfpMagicCheck14=ST1_MagicNumber + 13;
                                   if ( nfpMagicCheck13 != nfpMagicCheck14 )
                                   {
                                     nfpMagicCheck14 = SelectedTradeMagic();
                                     nfpMagicCheck15=ST1_MagicNumber + 14;
                                     if ( nfpMagicCheck14 != nfpMagicCheck15 )
                                     {
                                       nfpMagicCheck15 = SelectedTradeMagic();
                                       nfpMagicCheck16=ST1_MagicNumber + 15;
                                     if ( nfpMagicCheck15 != nfpMagicCheck16 )   continue;
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
           if ( SelectedTradeType() == ORDER_TYPE_BUY )
           {
             ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(currentSymbol,SYMBOL_BID),99999,Red); 
           }
           if ( SelectedTradeType() != ORDER_TYPE_SELL )   continue;
           ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(currentSymbol,SYMBOL_ASK),99999,Red); 
           
         }
       }
       if ( !(nfpTradingSuspended) )
       {
         Print("NFP!! deleting trades!!"); 
       }
       nfpTradingSuspended = true ;
     }
     else
     {
       nfpTradingSuspended = false ;
     }
   }
   else
   {
     if ( CurrentDay() <= 7 && CurrentDayOfWeek() == 5 )
     {
       fallbackNfpDateText = IntegerToString(CurrentYear(),0,32) + IntegerToString(CurrentMonth(),0,32) + IntegerToString(CurrentDay(),0,32) + " " + IntegerToString(NFP_FALLBACK_TIME_HHMM,0,32) ;
       fallbackNfpTime = StringToTime(fallbackNfpDateText) ;
       if ( currentGmtTime >= fallbackNfpTime - NFP_MinutesBefore * 60 && currentGmtTime <= fallbackNfpTime + NFP_MinutesAfter * 60 )
       {
         if ( NFP_ClosePendingOrders )
         {
           fallbackNfpPrimaryBuyDeleteMode = 1;
           for (fallbackNfpPrimaryBuyDeleteIndex = ActiveTradeCount() ; fallbackNfpPrimaryBuyDeleteIndex >= 0 ; fallbackNfpPrimaryBuyDeleteIndex=fallbackNfpPrimaryBuyDeleteIndex - 1)
           {
             if ( SelectTradeRecord(fallbackNfpPrimaryBuyDeleteIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != strategyMagicNumber || SelectedTradeSymbol() != currentSymbol || SelectedTradeType() != ORDER_TYPE_BUY_STOP )   continue;
             DeletePendingOrderByTicket(SelectedTradeTicket(),clrNONE); 
             
           }
           if ( fallbackNfpPrimaryBuyDeleteMode == 2 )
           {
             for (fallbackNfpManualBuyDeleteIndex = ActiveTradeCount() ; fallbackNfpManualBuyDeleteIndex >= 0 ; fallbackNfpManualBuyDeleteIndex=fallbackNfpManualBuyDeleteIndex - 1)
             {
               if ( SelectTradeRecord(fallbackNfpManualBuyDeleteIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != manualStrategy2MagicNumber || SelectedTradeSymbol() != currentSymbol || SelectedTradeType() != ORDER_TYPE_BUY_STOP )   continue;
               DeletePendingOrderByTicket(SelectedTradeTicket(),clrNONE); 
               
             }
           }
           fallbackNfpPrimarySellDeleteMode = 1;
           for (fallbackNfpPrimarySellDeleteIndex = ActiveTradeCount() ; fallbackNfpPrimarySellDeleteIndex >= 0 ; fallbackNfpPrimarySellDeleteIndex=fallbackNfpPrimarySellDeleteIndex - 1)
           {
             if ( SelectTradeRecord(fallbackNfpPrimarySellDeleteIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != strategyMagicNumber || SelectedTradeSymbol() != currentSymbol || SelectedTradeType() != ORDER_TYPE_SELL_STOP )   continue;
             DeletePendingOrderByTicket(SelectedTradeTicket(),clrNONE); 
             
           }
           if ( fallbackNfpPrimarySellDeleteMode == 2 )
           {
             for (fallbackNfpManualSellDeleteIndex = ActiveTradeCount() ; fallbackNfpManualSellDeleteIndex >= 0 ; fallbackNfpManualSellDeleteIndex=fallbackNfpManualSellDeleteIndex - 1)
             {
               if ( SelectTradeRecord(fallbackNfpManualSellDeleteIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != manualStrategy2MagicNumber || SelectedTradeSymbol() != currentSymbol || SelectedTradeType() != ORDER_TYPE_SELL_STOP )   continue;
               DeletePendingOrderByTicket(SelectedTradeTicket(),clrNONE); 
               
             }
           }
           fallbackNfpLegacyBuyDeleteMode = 2;
           if(1==0) // Điều kiện luôn sai; giữ nguyên nhánh vô hiệu từ mã gốc.
           {
             do
             {
               if ( SelectTradeRecord(1,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != strategyMagicNumber || SelectedTradeSymbol() != currentSymbol || SelectedTradeType() != ORDER_TYPE_BUY_STOP )   continue;
               DeletePendingOrderByTicket(SelectedTradeTicket(),clrNONE); 
               
             }
             while( - 1 >= 0);
             
           }
           if ( fallbackNfpLegacyBuyDeleteMode == 2 )
           {
             for (fallbackNfpLegacyBuyDeleteIndex = ActiveTradeCount() ; fallbackNfpLegacyBuyDeleteIndex >= 0 ; fallbackNfpLegacyBuyDeleteIndex=fallbackNfpLegacyBuyDeleteIndex - 1)
             {
               if ( SelectTradeRecord(fallbackNfpLegacyBuyDeleteIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != manualStrategy2MagicNumber || SelectedTradeSymbol() != currentSymbol || SelectedTradeType() != ORDER_TYPE_BUY_STOP )   continue;
               DeletePendingOrderByTicket(SelectedTradeTicket(),clrNONE); 
               
             }
           }
           fallbackNfpLegacySellDeleteMode = 2;
           if(1==0) // Điều kiện luôn sai; giữ nguyên nhánh vô hiệu từ mã gốc.
           {
             do
             {
               if ( SelectTradeRecord(1,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != strategyMagicNumber || SelectedTradeSymbol() != currentSymbol || SelectedTradeType() != ORDER_TYPE_SELL_STOP )   continue;
               DeletePendingOrderByTicket(SelectedTradeTicket(),clrNONE); 
               
             }
             while( - 1 >= 0);
             
           }
           if ( fallbackNfpLegacySellDeleteMode == 2 )
           {
             for (fallbackNfpLegacySellDeleteIndex = ActiveTradeCount() ; fallbackNfpLegacySellDeleteIndex >= 0 ; fallbackNfpLegacySellDeleteIndex=fallbackNfpLegacySellDeleteIndex - 1)
             {
               if ( SelectTradeRecord(fallbackNfpLegacySellDeleteIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != manualStrategy2MagicNumber || SelectedTradeSymbol() != currentSymbol || SelectedTradeType() != ORDER_TYPE_SELL_STOP )   continue;
               DeletePendingOrderByTicket(SelectedTradeTicket(),clrNONE); 
               
             }
           }
         }
         if ( NFP_CloseOpenTrades )
         {
           for (fallbackNfpCloseOrderIndex = ActiveTradeCount() ; fallbackNfpCloseOrderIndex >= 0 ; fallbackNfpCloseOrderIndex=fallbackNfpCloseOrderIndex - 1)
           {
             if ( SelectTradeRecord(fallbackNfpCloseOrderIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeSymbol() != currentSymbol )   continue;
             fallbackNfpMagicCheck01 = SelectedTradeMagic();
             fallbackNfpMagicCheck02=ST1_MagicNumber + 1;
             if ( fallbackNfpMagicCheck01 != fallbackNfpMagicCheck02 )
             {
               fallbackNfpMagicCheck02 = SelectedTradeMagic();
               fallbackNfpMagicCheck03=ST1_MagicNumber + 2;
               if ( fallbackNfpMagicCheck02 != fallbackNfpMagicCheck03 )
               {
                 fallbackNfpMagicCheck03 = SelectedTradeMagic();
                 fallbackNfpMagicCheck04=ST1_MagicNumber + 3;
                 if ( fallbackNfpMagicCheck03 != fallbackNfpMagicCheck04 )
                 {
                   fallbackNfpMagicCheck04 = SelectedTradeMagic();
                   fallbackNfpMagicCheck05=ST1_MagicNumber + 4;
                   if ( fallbackNfpMagicCheck04 != fallbackNfpMagicCheck05 )
                   {
                     fallbackNfpMagicCheck05 = SelectedTradeMagic();
                     fallbackNfpMagicCheck06=ST1_MagicNumber + 5;
                     if ( fallbackNfpMagicCheck05 != fallbackNfpMagicCheck06 )
                     {
                       fallbackNfpMagicCheck06 = SelectedTradeMagic();
                       fallbackNfpMagicCheck07=ST1_MagicNumber + 6;
                       if ( fallbackNfpMagicCheck06 != fallbackNfpMagicCheck07 )
                       {
                         fallbackNfpMagicCheck07 = SelectedTradeMagic();
                         fallbackNfpMagicCheck08=ST1_MagicNumber + 7;
                         if ( fallbackNfpMagicCheck07 != fallbackNfpMagicCheck08 )
                         {
                           fallbackNfpMagicCheck08 = SelectedTradeMagic();
                           fallbackNfpMagicCheck09=ST1_MagicNumber + 8;
                           if ( fallbackNfpMagicCheck08 != fallbackNfpMagicCheck09 )
                           {
                             fallbackNfpMagicCheck09 = SelectedTradeMagic();
                             fallbackNfpMagicCheck10=ST1_MagicNumber + 9;
                             if ( fallbackNfpMagicCheck09 != fallbackNfpMagicCheck10 )
                             {
                               fallbackNfpMagicCheck10 = SelectedTradeMagic();
                               fallbackNfpMagicCheck11=ST1_MagicNumber + 10;
                               if ( fallbackNfpMagicCheck10 != fallbackNfpMagicCheck11 )
                               {
                                 fallbackNfpMagicCheck11 = SelectedTradeMagic();
                                 fallbackNfpMagicCheck12=ST1_MagicNumber + 11;
                                 if ( fallbackNfpMagicCheck11 != fallbackNfpMagicCheck12 )
                                 {
                                   fallbackNfpMagicCheck12 = SelectedTradeMagic();
                                   fallbackNfpMagicCheck13=ST1_MagicNumber + 12;
                                   if ( fallbackNfpMagicCheck12 != fallbackNfpMagicCheck13 )
                                   {
                                     fallbackNfpMagicCheck13 = SelectedTradeMagic();
                                     fallbackNfpMagicCheck14=ST1_MagicNumber + 13;
                                     if ( fallbackNfpMagicCheck13 != fallbackNfpMagicCheck14 )
                                     {
                                       fallbackNfpMagicCheck14 = SelectedTradeMagic();
                                       fallbackNfpMagicCheck15=ST1_MagicNumber + 14;
                                       if ( fallbackNfpMagicCheck14 != fallbackNfpMagicCheck15 )
                                       {
                                         fallbackNfpMagicCheck15 = SelectedTradeMagic();
                                         fallbackNfpMagicCheck16=ST1_MagicNumber + 15;
                                       if ( fallbackNfpMagicCheck15 != fallbackNfpMagicCheck16 )   continue;
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
             if ( SelectedTradeType() == ORDER_TYPE_BUY )
             {
               ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(currentSymbol,SYMBOL_BID),99999,Red); 
             }
             if ( SelectedTradeType() != ORDER_TYPE_SELL )   continue;
             ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(currentSymbol,SYMBOL_ASK),99999,Red); 
             
           }
         }
         if ( !(nfpTradingSuspended) )
         {
           Print("NFP!! deleting trades!!"); 
         }
         nfpTradingSuspended = true ;
       }
       else
       {
         nfpTradingSuspended = false ;
       }
     }
   }
 }
 if ( nfpTradingSuspended )
 {
   return(0); 
 }
 if ( fridayStopEnabled )
 {
   if ( CurrentDayOfWeek() == 5 && CurrentHour() >= FridayStopHour && !(fridayTradingSuspended) )
   {
     for (fridayCloseOrderIndex = ActiveTradeCount() ; fridayCloseOrderIndex >= 0 ; fridayCloseOrderIndex=fridayCloseOrderIndex - 1)
     {
       if ( SelectTradeRecord(fridayCloseOrderIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeSymbol() != currentSymbol )   continue;
       fridayMagicCheck01 = SelectedTradeMagic();
       fridayMagicCheck02=ST1_MagicNumber + 1;
       if ( fridayMagicCheck01 != fridayMagicCheck02 )
       {
         fridayMagicCheck02 = SelectedTradeMagic();
         fridayMagicCheck03=ST1_MagicNumber + 2;
         if ( fridayMagicCheck02 != fridayMagicCheck03 )
         {
           fridayMagicCheck03 = SelectedTradeMagic();
           fridayMagicCheck04=ST1_MagicNumber + 3;
           if ( fridayMagicCheck03 != fridayMagicCheck04 )
           {
             fridayMagicCheck04 = SelectedTradeMagic();
             fridayMagicCheck05=ST1_MagicNumber + 4;
             if ( fridayMagicCheck04 != fridayMagicCheck05 )
             {
               fridayMagicCheck05 = SelectedTradeMagic();
               fridayMagicCheck06=ST1_MagicNumber + 5;
               if ( fridayMagicCheck05 != fridayMagicCheck06 )
               {
                 fridayMagicCheck06 = SelectedTradeMagic();
                 fridayMagicCheck07=ST1_MagicNumber + 6;
                 if ( fridayMagicCheck06 != fridayMagicCheck07 )
                 {
                   fridayMagicCheck07 = SelectedTradeMagic();
                   fridayMagicCheck08=ST1_MagicNumber + 7;
                   if ( fridayMagicCheck07 != fridayMagicCheck08 )
                   {
                     fridayMagicCheck08 = SelectedTradeMagic();
                     fridayMagicCheck09=ST1_MagicNumber + 8;
                     if ( fridayMagicCheck08 != fridayMagicCheck09 )
                     {
                       fridayMagicCheck09 = SelectedTradeMagic();
                       fridayMagicCheck10=ST1_MagicNumber + 9;
                       if ( fridayMagicCheck09 != fridayMagicCheck10 )
                       {
                         fridayMagicCheck10 = SelectedTradeMagic();
                         fridayMagicCheck11=ST1_MagicNumber + 10;
                         if ( fridayMagicCheck10 != fridayMagicCheck11 )
                         {
                           fridayMagicCheck11 = SelectedTradeMagic();
                           fridayMagicCheck12=ST1_MagicNumber + 11;
                           if ( fridayMagicCheck11 != fridayMagicCheck12 )
                           {
                             fridayMagicCheck12 = SelectedTradeMagic();
                             fridayMagicCheck13=ST1_MagicNumber + 12;
                             if ( fridayMagicCheck12 != fridayMagicCheck13 )
                             {
                               fridayMagicCheck13 = SelectedTradeMagic();
                               fridayMagicCheck14=ST1_MagicNumber + 13;
                               if ( fridayMagicCheck13 != fridayMagicCheck14 )
                               {
                                 fridayMagicCheck14 = SelectedTradeMagic();
                                 fridayMagicCheck15=ST1_MagicNumber + 14;
                                 if ( fridayMagicCheck14 != fridayMagicCheck15 )
                                 {
                                   fridayMagicCheck15 = SelectedTradeMagic();
                                   fridayMagicCheck16=ST1_MagicNumber + 15;
                                 if ( fridayMagicCheck15 != fridayMagicCheck16 )   continue;
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
       if ( FridayCloseOpen && SelectedTradeType() == ORDER_TYPE_BUY )
       {
         ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(currentSymbol,SYMBOL_BID),(int)orderSlippageSetting,Red); 
       }
       if ( FridayCloseOpen && SelectedTradeType() == ORDER_TYPE_SELL )
       {
         ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(currentSymbol,SYMBOL_ASK),(int)orderSlippageSetting,Red); 
       }
       if ( ( SelectedTradeType() != ORDER_TYPE_BUY_STOP && SelectedTradeType() != ORDER_TYPE_SELL_STOP ) || !(FridayClosePending) )   continue;
       DeletePendingOrderByTicket(SelectedTradeTicket(),Red); 
       
     }
     Print("Weekend starting! closing trades.."); 
     fridayTradingSuspended = true ;
     return(0); 
   }
   if ( CurrentDayOfWeek() != 5 && fridayTradingSuspended == true )
   {
     fridayTradingSuspended = false ;
     if ( restorePendingOrdersAfterFridayPause )
     {
       RestoreStoredPendingOrders(); 
       return(0); 
     }
   }
 }
 currentSpreadPrice = SymbolInfoDouble(currentSymbol,SYMBOL_ASK) - SymbolInfoDouble(currentSymbol,SYMBOL_BID) ;
 if ( suspendPendingOrdersOnHighSpread )
 {
   if ( currentSpreadPrice>MaxSpread * pipSize )
   {
     SuspendPendingOrdersOnHighSpread(); 
     return(0); 
   }
   if ( currentSpreadPrice<=maxSpreadPips * pipSize && ( !(fridayStopEnabled) || CurrentDayOfWeek() != 5 || CurrentHour() <  FridayStopHour ) && ( !(tradingHoursEnabled) || IsTradingSessionOpen() ) )
   {
     RestoreStoredPendingOrders(); 
   }
 }
 if ( entryStrategyMode == 1 )
 {
   pendingBuyCount = 0;
   for (pendingBuyCountScanIndex = ActiveTradeCount() ; pendingBuyCountScanIndex >= 0 ; pendingBuyCountScanIndex=pendingBuyCountScanIndex - 1)
   {
     if ( SelectTradeRecord(pendingBuyCountScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != strategyMagicNumber || SelectedTradeSymbol() != currentSymbol || SelectedTradeType() != ORDER_TYPE_BUY_STOP )   continue;
     pendingBuyCount=pendingBuyCount + 1;
     
   }
   if ( pendingBuyCount >  maxPendingOrders )
   {
     highestBuyStopPrice = 0.0;
     highestBuyStopTicket = 0;
     for (highestBuyStopScanIndex = ActiveTradeCount() ; highestBuyStopScanIndex >= 0 ; highestBuyStopScanIndex=highestBuyStopScanIndex - 1)
     {
       if ( SelectTradeRecord(highestBuyStopScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != strategyMagicNumber || SelectedTradeSymbol() != currentSymbol || SelectedTradeType() != ORDER_TYPE_BUY_STOP || !(SelectedTradeOpenPrice()>highestBuyStopPrice) )   continue;
       highestBuyStopTicket = SelectedTradeTicket();
       highestBuyStopPrice = SelectedTradeOpenPrice();
       
     }
     if ( highestBuyStopTicket != 0 )
     {
       DeletePendingOrderByTicket(highestBuyStopTicket,Green); 
       deletedBuyStopTicket = highestBuyStopTicket;
       for (buyTicketMapIndex = 0 ; buyTicketMapIndex < 100 ; buyTicketMapIndex=buyTicketMapIndex + 1)
       {
         if ( !(pendingTicketPriceMap[buyTicketMapIndex][0]==deletedBuyStopTicket) )   continue;
         pendingTicketPriceMap[buyTicketMapIndex][0] = 0.0;
         pendingTicketPriceMap[buyTicketMapIndex][1] = 0.0;
         break;
         
       }
       Print("Max number of pending buy orders reached... deleting highest buystop order!"); 
     }
   }
   pendingSellCount = 0;
   for (pendingSellCountScanIndex = ActiveTradeCount() ; pendingSellCountScanIndex >= 0 ; pendingSellCountScanIndex=pendingSellCountScanIndex - 1)
   {
     if ( SelectTradeRecord(pendingSellCountScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != strategyMagicNumber || SelectedTradeSymbol() != currentSymbol || SelectedTradeType() != ORDER_TYPE_SELL_STOP )   continue;
     pendingSellCount=pendingSellCount + 1;
     
   }
   if ( pendingSellCount >  maxPendingOrders )
   {
     lowestSellStopPrice = 9999.0;
     lowestSellStopTicket = 0;
     for (lowestSellStopScanIndex = ActiveTradeCount() ; lowestSellStopScanIndex >= 0 ; lowestSellStopScanIndex=lowestSellStopScanIndex - 1)
     {
       if ( SelectTradeRecord(lowestSellStopScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != strategyMagicNumber || SelectedTradeSymbol() != currentSymbol || SelectedTradeType() != ORDER_TYPE_SELL_STOP || !(SelectedTradeOpenPrice()<lowestSellStopPrice) )   continue;
       lowestSellStopTicket = SelectedTradeTicket();
       lowestSellStopPrice = SelectedTradeOpenPrice();
       
     }
     if ( lowestSellStopTicket != 0 )
     {
       DeletePendingOrderByTicket(lowestSellStopTicket,Green); 
       deletedSellStopTicket = lowestSellStopTicket;
       for (sellTicketMapIndex = 0 ; sellTicketMapIndex < 100 ; sellTicketMapIndex=sellTicketMapIndex + 1)
       {
         if ( !(pendingTicketPriceMap[sellTicketMapIndex][0]==deletedSellStopTicket) )   continue;
         pendingTicketPriceMap[sellTicketMapIndex][0] = 0.0;
         pendingTicketPriceMap[sellTicketMapIndex][1] = 0.0;
         break;
         
       }
       Print("Max number of pending sell orders reached... deleting lowest sellstop order!"); 
     }
   }
 }
 if ( !(fridayTradingSuspended) && entryStrategyMode == 1 && !(tradingHoursState) )
 {
   if ( ( lastEntryBarCountByStrategy[currentStrategyIndex] != iBars(currentSymbol,NormalizeTimeframe(entryTimingTimeframeMinutes)) || entryTimingTimeframeMinutes == 0 ) )
   {
     lastEntryBarCountByStrategy[currentStrategyIndex] = iBars(currentSymbol,NormalizeTimeframe(entryTimingTimeframeMinutes));
     if ( highLowLeftBars >  0 && highLowRightBars >= 0 )
     {
       buyTriggerPriceByStrategy[currentStrategyIndex] = highLowTrailingOffsetPips * pipSize + (FindQualifiedSwingHigh(highLowTrailingTimeframeMinutes,highLowLeftBars,highLowRightBars) + currentSpreadPrice);
       sellTriggerPriceByStrategy[currentStrategyIndex] = FindQualifiedSwingLow(highLowTrailingTimeframeMinutes,highLowLeftBars,highLowRightBars) - highLowTrailingOffsetPips * pipSize;
     }
     if ( randomPendingOffsetMaximumPips >  0 )
     {
       randomizedEntryOffsetPips=MathRand() * randomPendingOffsetMaximumPips / 32768 + 1;
       randomizedPendingEntryOffsetPips = randomizedEntryOffsetPips ;
       Print("Slippage: " + (string(randomizedEntryOffsetPips))); 
     }
     if ( tradeMonitorFilterMode != 1 )
     {
       openBuyCount = 0;
       for (openBuyScanIndex = ActiveTradeCount() ; openBuyScanIndex >= 0 ; openBuyScanIndex=openBuyScanIndex - 1)
       {
         if ( SelectTradeRecord(openBuyScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != strategyMagicNumber || SelectedTradeSymbol() != currentSymbol || SelectedTradeType() != ORDER_TYPE_BUY )   continue;
         openBuyCount=openBuyCount + 1;
         
       }
       if ( openBuyCount == 0 )
       {
         openSellCount = 0;
         for (openSellScanIndex = ActiveTradeCount() ; openSellScanIndex >= 0 ; openSellScanIndex=openSellScanIndex - 1)
         {
           if ( SelectTradeRecord(openSellScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != strategyMagicNumber || SelectedTradeSymbol() != currentSymbol || SelectedTradeType() != ORDER_TYPE_SELL )   continue;
           openSellCount=openSellCount + 1;
           
         }
         if ( openSellCount == 0 )
         {
           virtualStopTicketStillOpen = false;
           for (virtualStopBufferIndex = 0 ; virtualStopBufferIndex < smallBufferCapacity ; virtualStopBufferIndex=virtualStopBufferIndex + 1)
           {
             if ( !(virtualStopByTicket[virtualStopBufferIndex][0]>0.0) )   continue;
             virtualStopTicketStillOpen = false;
             for (virtualStopOrderScanIndex = ActiveTradeCount() ; virtualStopOrderScanIndex >= 0 ; virtualStopOrderScanIndex=virtualStopOrderScanIndex - 1)
             {
               if ( SelectTradeRecord(virtualStopOrderScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true )   continue;
               
               if ( ( SelectedTradeType() != ORDER_TYPE_BUY && SelectedTradeType() != ORDER_TYPE_SELL ) || !(SelectedTradeTicket()==virtualStopByTicket[virtualStopBufferIndex][0]) )   continue;
               virtualStopTicketStillOpen = true;
               
             }
             if ( virtualStopTicketStillOpen )   continue;
             virtualStopByTicket[virtualStopBufferIndex][0] = 0.0;
             virtualStopByTicket[virtualStopBufferIndex][1] = 0.0;
             
           }
         }
       }
     }
     for (pendingPlacementAttemptIndex = 0 ; pendingPlacementAttemptIndex < maxPendingOrders ; pendingPlacementAttemptIndex ++)
     {
       ManagePendingEntries(); 
     }
   }
   UpdateInfoPanelTotals(); 
   if ( lastEntryHour != CurrentHour() )
   {
     lastEntryHour = CurrentHour() ;
     ticketMapEntryStillOpen = false;
     for (ticketMapIndex = 0 ; ticketMapIndex < 100 ; ticketMapIndex=ticketMapIndex + 1)
     {
       mappedPendingTicket = (long)pendingTicketPriceMap[ticketMapIndex][0];
       ticketMapEntryStillOpen = false;
       for (ticketMapOrderScanIndex = ActiveTradeCount() ; ticketMapOrderScanIndex >= 0 ; ticketMapOrderScanIndex=ticketMapOrderScanIndex - 1)
       {
         if ( !(SelectTradeRecord(ticketMapOrderScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE)) )   continue;
         selectedOrderTicket = SelectedTradeTicket();
         if ( mappedPendingTicket != selectedOrderTicket )   continue;
         ticketMapEntryStillOpen = true;
         
       }
       if ( ticketMapEntryStillOpen )   continue;
       pendingTicketPriceMap[ticketMapIndex][0] = 0.0;
       pendingTicketPriceMap[ticketMapIndex][1] = 0.0;
       
     }
   }
 }
 if ( showTradeDebugComments )
 {
   debugStatusText="Current spread: " + string(NormalizeDouble(currentSpreadPrice / pipSize,1)) + "\nPending Buy Order: ";
   debugPendingBuyCount = 0;
   for (debugBuyScanIndex = ActiveTradeCount() ; debugBuyScanIndex >= 0 ; debugBuyScanIndex=debugBuyScanIndex - 1)
   {
     if ( SelectTradeRecord(debugBuyScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != strategyMagicNumber || SelectedTradeSymbol() != currentSymbol || SelectedTradeType() != ORDER_TYPE_BUY_STOP )   continue;
     debugPendingBuyCount=debugPendingBuyCount + 1;
     
   }
   debugStatusText=debugStatusText + string(debugPendingBuyCount);
   debugStatusText=debugStatusText + "\nPending Sell Orders: ";
   debugPendingSellCount = 0;
   for (debugSellScanIndex = ActiveTradeCount() ; debugSellScanIndex >= 0 ; debugSellScanIndex=debugSellScanIndex - 1)
   {
     if ( SelectTradeRecord(debugSellScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != strategyMagicNumber || SelectedTradeSymbol() != currentSymbol || SelectedTradeType() != ORDER_TYPE_SELL_STOP )   continue;
     debugPendingSellCount=debugPendingSellCount + 1;
     
   }
   debugStatusText=debugStatusText + string(debugPendingSellCount);
   Comment(debugStatusText); 
 }
 return(0); 
 }
//RunStrategyCycle <<==--------   --------
 void RestoreStoredPendingOrders()
 {
  int       storedOrderIndex;
//----------------------------------------------------------------------
 double     buyStoredPrice;
 long       restoredBuyTicket;
 int        buyTicketMapInsertIndex;
 double     retryBuyStoredPrice;
 long       retryRestoredBuyTicket;
 int        retryBuyTicketMapIndex;
 double     sellStoredPrice;
 long       restoredSellTicket;
 int        sellTicketMapInsertIndex;
 double     retrySellStoredPrice;
 long       retryRestoredSellTicket;
 int        retrySellTicketMapIndex;
 int        storedOrderClearIndex;

 for (storedOrderIndex = 0 ; storedOrderIndex < orderBufferCapacity ; storedOrderIndex ++)
 {
   if ( !(storedPendingOrders[storedOrderIndex][0]>0.0) )   continue;
   
   if ( storedPendingOrders[storedOrderIndex][1]==ORDER_TYPE_BUY_STOP && SymbolInfoDouble(currentSymbol,SYMBOL_ASK)<storedPendingOrders[storedOrderIndex][0] - stopLevelPriceDistance )
   {
     Print("Restoring pending buy-order"); 
     lastTradeTicket = SendTradeOrder(currentSymbol,ORDER_TYPE_BUY_STOP,storedPendingOrders[storedOrderIndex][2],storedPendingOrders[storedOrderIndex][0],int(orderSlippageSetting * pipSize),storedPendingOrders[storedOrderIndex][0] - (stopLossPips + extraStopLossPips) * pipSize,takeProfitPips * pipSize + storedPendingOrders[storedOrderIndex][0],currentStrategyComment,strategyMagicNumber,pendingOrderExpirationTime + RESTORED_PENDING_EXPIRATION_EXTENSION_SECONDS,Green) ;
     buyPendingRestoreState = false ;
     buyStoredPrice = storedPendingOrders[storedOrderIndex][0];
     restoredBuyTicket = lastTradeTicket;
     for (buyTicketMapInsertIndex = 0 ; buyTicketMapInsertIndex < 100 ; buyTicketMapInsertIndex=buyTicketMapInsertIndex + 1)
     {
       if ( !(pendingTicketPriceMap[buyTicketMapInsertIndex][0]==0.0) )   continue;
       pendingTicketPriceMap[buyTicketMapInsertIndex][0] = (double)restoredBuyTicket;
       pendingTicketPriceMap[buyTicketMapInsertIndex][1] = buyStoredPrice;
       break;
       
     }
     if ( lastTradeTicket <= 0 )
     {
       if ( LastTradeErrorCode() == STRATEGY_ERROR_MARKET_CLOSED )
       {
         ResetLastError();
         if(1==0) // Điều kiện luôn sai; giữ nguyên nhánh vô hiệu từ mã gốc.
         {
           do
           {
             Sleep(2500); 
             lastTradeTicket = SendTradeOrder(currentSymbol,ORDER_TYPE_BUY_STOP,storedPendingOrders[storedOrderIndex][2],storedPendingOrders[storedOrderIndex][0],int(orderSlippageSetting * pipSize),storedPendingOrders[storedOrderIndex][0] - (stopLossPips + extraStopLossPips) * pipSize,takeProfitPips * pipSize + storedPendingOrders[storedOrderIndex][0],currentStrategyComment,strategyMagicNumber,pendingOrderExpirationTime + RESTORED_PENDING_EXPIRATION_EXTENSION_SECONDS,Green) ;
             buyPendingRestoreState = false ;
             retryBuyStoredPrice = storedPendingOrders[storedOrderIndex][0];
             retryRestoredBuyTicket = lastTradeTicket;
             for (retryBuyTicketMapIndex = 0 ; retryBuyTicketMapIndex < 100 ; retryBuyTicketMapIndex=retryBuyTicketMapIndex + 1)
             {
               if ( !(pendingTicketPriceMap[retryBuyTicketMapIndex][0]==0.0) )   continue;
               pendingTicketPriceMap[retryBuyTicketMapIndex][0] = (double)retryRestoredBuyTicket;
               pendingTicketPriceMap[retryBuyTicketMapIndex][1] = retryBuyStoredPrice;
               break;
               
             }
           }
           while(LastTradeErrorCode() == STRATEGY_ERROR_MARKET_CLOSED);
           
         }
       }
       Print("error: \'" + TradeErrorDescription(LastTradeErrorCode()) + "\' when setting entry order"); 
     }
   }
   if ( !(storedPendingOrders[storedOrderIndex][1]==ORDER_TYPE_SELL_STOP) || !(SymbolInfoDouble(currentSymbol,SYMBOL_BID)>storedPendingOrders[storedOrderIndex][0] + stopLevelPriceDistance) )   continue;
   Print("Restoring pending sell-order"); 
   lastTradeTicket = SendTradeOrder(currentSymbol,ORDER_TYPE_SELL_STOP,storedPendingOrders[storedOrderIndex][2],storedPendingOrders[storedOrderIndex][0],int(orderSlippageSetting * pipSize),(stopLossPips + extraStopLossPips) * pipSize + storedPendingOrders[storedOrderIndex][0],storedPendingOrders[storedOrderIndex][0] - takeProfitPips * pipSize,currentStrategyComment,strategyMagicNumber,pendingOrderExpirationTime + RESTORED_PENDING_EXPIRATION_EXTENSION_SECONDS,Green) ;
   sellPendingRestoreState = false ;
   sellStoredPrice = storedPendingOrders[storedOrderIndex][0];
   restoredSellTicket = lastTradeTicket;
   for (sellTicketMapInsertIndex = 0 ; sellTicketMapInsertIndex < 100 ; sellTicketMapInsertIndex=sellTicketMapInsertIndex + 1)
   {
     if ( !(pendingTicketPriceMap[sellTicketMapInsertIndex][0]==0.0) )   continue;
     pendingTicketPriceMap[sellTicketMapInsertIndex][0] = (double)restoredSellTicket;
     pendingTicketPriceMap[sellTicketMapInsertIndex][1] = sellStoredPrice;
     break;
     
   }
   if ( lastTradeTicket > 0 )   continue;
   
   if ( LastTradeErrorCode() == STRATEGY_ERROR_MARKET_CLOSED )
   {
     ResetLastError();
     if(1==0) // Điều kiện luôn sai; giữ nguyên nhánh vô hiệu từ mã gốc.
     {
       do
       {
         Sleep(2500); 
         lastTradeTicket = SendTradeOrder(currentSymbol,ORDER_TYPE_SELL_STOP,storedPendingOrders[storedOrderIndex][2],storedPendingOrders[storedOrderIndex][0],int(orderSlippageSetting * pipSize),(stopLossPips + extraStopLossPips) * pipSize + storedPendingOrders[storedOrderIndex][0],storedPendingOrders[storedOrderIndex][0] - takeProfitPips * pipSize,currentStrategyComment,strategyMagicNumber,pendingOrderExpirationTime + RESTORED_PENDING_EXPIRATION_EXTENSION_SECONDS,Green) ;
         sellPendingRestoreState = false ;
         retrySellStoredPrice = storedPendingOrders[storedOrderIndex][0];
         retryRestoredSellTicket = lastTradeTicket;
         for (retrySellTicketMapIndex = 0 ; retrySellTicketMapIndex < 100 ; retrySellTicketMapIndex=retrySellTicketMapIndex + 1)
         {
           if ( !(pendingTicketPriceMap[retrySellTicketMapIndex][0]==0.0) )   continue;
           pendingTicketPriceMap[retrySellTicketMapIndex][0] = (double)retryRestoredSellTicket;
           pendingTicketPriceMap[retrySellTicketMapIndex][1] = retrySellStoredPrice;
           break;
           
         }
       }
       while(LastTradeErrorCode() == STRATEGY_ERROR_MARKET_CLOSED);
       
     }
   }
   Print("error: \'" + TradeErrorDescription(LastTradeErrorCode()) + "\' when setting entry order"); 
   
 }
 for (storedOrderClearIndex = 0 ; storedOrderClearIndex < orderBufferCapacity ; storedOrderClearIndex=storedOrderClearIndex + 1)
 {
   storedPendingOrders[storedOrderClearIndex][0] = 0.0;
   storedPendingOrders[storedOrderClearIndex][1] = 0.0;
   storedPendingOrders[storedOrderClearIndex][2] = 0.0;
 }
 }
//RestoreStoredPendingOrders <<==--------   --------
 bool SuspendPendingOrdersOnHighSpread()
 {
  int       orderScanIndex;
  int       buyStorageIndex;
  int       sellStorageIndex;
//----------------------------------------------------------------------
 long       storedBuyTicket;
 int        storedBuyTicketMapIndex;
 long       deletedBuyTicket;
 int        deletedBuyTicketMapIndex;
 double     sellOrderPrice;
 double     currentBid;
 long       storedSellTicket;
 int        storedSellTicketMapIndex;
 long       deletedSellTicket;
 int        deletedSellTicketMapIndex;

 for (orderScanIndex = ActiveTradeCount() ; orderScanIndex >= 0 ; orderScanIndex --)
 {
   if ( SelectTradeRecord(orderScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true )   continue;
   
   if ( ( SelectedTradeMagic() != strategyMagicNumber && SelectedTradeMagic() != manualStrategy2MagicNumber ) || SelectedTradeSymbol() != currentSymbol )   continue;
   
   if ( SelectedTradeType() == ORDER_TYPE_BUY_STOP && SelectedTradeOpenPrice()<minPendingMarketGapPips * pipSize + SymbolInfoDouble(currentSymbol,SYMBOL_ASK) && SymbolInfoDouble(currentSymbol,SYMBOL_ASK)<SelectedTradeOpenPrice() - freezeLevelPriceDistance )
   {
     if ( maxSpreadPips>0.0 )
     {
       Print("Spread too high..(" + string(currentSpreadPrice) + ") storing and deleting order " + string(SelectedTradeTicket())); 
       for (buyStorageIndex = 0 ; buyStorageIndex < orderBufferCapacity ; buyStorageIndex ++)
       {
         if ( storedPendingOrders[buyStorageIndex][0]==0.0 )
         {
           Print("Storing pending order nr " + string(SelectedTradeTicket())); 
           storedPendingOrders[buyStorageIndex][1] = SelectedTradeType();
           storedPendingOrders[buyStorageIndex][0] = SelectedTradeOpenPrice();
           storedPendingOrders[buyStorageIndex][2] = SelectedTradeVolume();
           break;
         }
       }
       storedBuyTicket = SelectedTradeTicket();
       for (storedBuyTicketMapIndex = 0 ; storedBuyTicketMapIndex < 100 ; storedBuyTicketMapIndex=storedBuyTicketMapIndex + 1)
       {
         if ( !(pendingTicketPriceMap[storedBuyTicketMapIndex][0]==storedBuyTicket) )   continue;
         pendingTicketPriceMap[storedBuyTicketMapIndex][0] = 0.0;
         pendingTicketPriceMap[storedBuyTicketMapIndex][1] = 0.0;
         break;
         
       }
       DeletePendingOrderByTicket(SelectedTradeTicket(),Green); 
     }
     else
     {
       Print("Spread too high..(" + string(currentSpreadPrice) + ") deleting order " + string(SelectedTradeTicket())); 
       deletedBuyTicket = SelectedTradeTicket();
       for (deletedBuyTicketMapIndex = 0 ; deletedBuyTicketMapIndex < 100 ; deletedBuyTicketMapIndex=deletedBuyTicketMapIndex + 1)
       {
         if ( !(pendingTicketPriceMap[deletedBuyTicketMapIndex][0]==deletedBuyTicket) )   continue;
         pendingTicketPriceMap[deletedBuyTicketMapIndex][0] = 0.0;
         pendingTicketPriceMap[deletedBuyTicketMapIndex][1] = 0.0;
         break;
         
       }
       DeletePendingOrderByTicket(SelectedTradeTicket(),Green); 
     }
   }
   if ( SelectedTradeType() != ORDER_TYPE_SELL_STOP )   continue;
   sellOrderPrice = SelectedTradeOpenPrice();
   if ( !(sellOrderPrice>SymbolInfoDouble(currentSymbol,SYMBOL_BID) - minPendingMarketGapPips * pipSize) )   continue;
   currentBid = SymbolInfoDouble(currentSymbol,SYMBOL_BID);
   if ( !(currentBid>SelectedTradeOpenPrice() + freezeLevelPriceDistance) )   continue;
   
   if ( maxSpreadPips>0.0 )
   {
     Print("Spread too high..(" + string(currentSpreadPrice) + ") storing and deleting order " + string(SelectedTradeTicket())); 
     for (sellStorageIndex = 0 ; sellStorageIndex < orderBufferCapacity ; sellStorageIndex ++)
     {
       if ( storedPendingOrders[sellStorageIndex][0]==0.0 )
       {
         Print("Storing pending order nr " + string(SelectedTradeTicket())); 
         storedPendingOrders[sellStorageIndex][1] = SelectedTradeType();
         storedPendingOrders[sellStorageIndex][0] = SelectedTradeOpenPrice();
         storedPendingOrders[sellStorageIndex][2] = SelectedTradeVolume();
         break;
       }
     }
     storedSellTicket = SelectedTradeTicket();
     for (storedSellTicketMapIndex = 0 ; storedSellTicketMapIndex < 100 ; storedSellTicketMapIndex=storedSellTicketMapIndex + 1)
     {
       if ( !(pendingTicketPriceMap[storedSellTicketMapIndex][0]==storedSellTicket) )   continue;
       pendingTicketPriceMap[storedSellTicketMapIndex][0] = 0.0;
       pendingTicketPriceMap[storedSellTicketMapIndex][1] = 0.0;
       break;
       
     }
     DeletePendingOrderByTicket(SelectedTradeTicket(),Green); 
      continue;
   }
   Print("Spread too high..(" + string(currentSpreadPrice) + ") deleting order " + string(SelectedTradeTicket())); 
   deletedSellTicket = SelectedTradeTicket();
   for (deletedSellTicketMapIndex = 0 ; deletedSellTicketMapIndex < 100 ; deletedSellTicketMapIndex=deletedSellTicketMapIndex + 1)
   {
     if ( !(pendingTicketPriceMap[deletedSellTicketMapIndex][0]==deletedSellTicket) )   continue;
     pendingTicketPriceMap[deletedSellTicketMapIndex][0] = 0.0;
     pendingTicketPriceMap[deletedSellTicketMapIndex][1] = 0.0;
     break;
     
   }
   DeletePendingOrderByTicket(SelectedTradeTicket(),Green); 
   
 }
 return(false); 
 }
//SuspendPendingOrdersOnHighSpread <<==--------   --------
 void CalculateStrategyLotSize( double requestedStopLossPips,int lotPercentMultiplier)
 {
  double    previousLotSize;
  double    calculatedLotSize;
  double    normalizedStopLossPips;
  double    riskSettingValue;
  double    weightedRiskCapital;
  double    fixedRiskCapital;
  double    accountBalanceUsd;
//----------------------------------------------------------------------

 previousLotSize = lotSizeByStrategy[currentStrategyIndex] ;
 calculatedLotSize = lotSizeByStrategy[currentStrategyIndex] ;
 currentBalanceBasis = AccountInfoDouble(ACCOUNT_BALANCE) ;
 if ( UseEquity )
 {
   currentBalanceBasis = AccountInfoDouble(ACCOUNT_EQUITY) ;
 }
 if ( ManualBalance>0.0 )
 {
   currentBalanceBasis = ManualBalance ;
 }
 if ( OnlyUp && highestBalanceBasis>currentBalanceBasis )
 {
   currentBalanceBasis = highestBalanceBasis ;
 }
 if ( currentBalanceBasis>highestBalanceBasis )
 {
   highestBalanceBasis = currentBalanceBasis ;
   if ( OnlyUp )   GlobalVariableSet(OnlyUpPeakGVName(),highestBalanceBasis) ;
 }
 normalizedStopLossPips = requestedStopLossPips ;
 if ( ( symbolDigits == 2 || symbolDigits == 4 ) )
 {
   normalizedStopLossPips = requestedStopLossPips / 10.0 ;
 }
 if ( Risk <  999 && Risk >  0 )
 {
   riskSettingValue = Risk ;
   weightedRiskCapital = riskSettingValue / 1000.0 * currentBalanceBasis ;
   if ( SymbolInfoDouble(currentSymbol,SYMBOL_VOLUME_STEP)==0.1 )
   {
     calculatedLotSize = NormalizeDouble(lotPercentMultiplier * 0.01 * (weightedRiskCapital / (SymbolInfoDouble(currentSymbol,SYMBOL_TRADE_TICK_VALUE) * normalizedStopLossPips) * 0.1),1) ;
   }
   if ( SymbolInfoDouble(currentSymbol,SYMBOL_VOLUME_STEP)==0.01 )
   {
     calculatedLotSize = NormalizeDouble(lotPercentMultiplier * 0.01 * (weightedRiskCapital / (SymbolInfoDouble(currentSymbol,SYMBOL_TRADE_TICK_VALUE) * normalizedStopLossPips) * 0.1),2) ;
   }
 }
 if ( Risk == 999 )
 {
   fixedRiskCapital = fixedRiskPercent / 100.0 * currentBalanceBasis ;
   if ( SymbolInfoDouble(currentSymbol,SYMBOL_VOLUME_STEP)==0.1 )
   {
     calculatedLotSize = NormalizeDouble(lotPercentMultiplier * 0.01 * (fixedRiskCapital / (SymbolInfoDouble(currentSymbol,SYMBOL_TRADE_TICK_VALUE) * normalizedStopLossPips) * 0.1),1) ;
   }
   if ( SymbolInfoDouble(currentSymbol,SYMBOL_VOLUME_STEP)==0.01 )
   {
     calculatedLotSize = NormalizeDouble(lotPercentMultiplier * 0.01 * (fixedRiskCapital / (SymbolInfoDouble(currentSymbol,SYMBOL_TRADE_TICK_VALUE) * normalizedStopLossPips) * 0.1),2) ;
   }
 }
 if ( Risk == 0 )
 {
   if ( SymbolInfoDouble(currentSymbol,SYMBOL_VOLUME_STEP)==0.1 )
   {
     calculatedLotSize = NormalizeDouble(lotPercentMultiplier * 0.01 * startLots_rw,1) ;
   }
   if ( SymbolInfoDouble(currentSymbol,SYMBOL_VOLUME_STEP)==0.01 )
   {
     calculatedLotSize = NormalizeDouble(lotPercentMultiplier * 0.01 * startLots_rw,2) ;
   }
 }
 if ( Risk == 9999 )
 {
   if ( SymbolInfoDouble(currentSymbol,SYMBOL_VOLUME_STEP)==0.1 )
   {
     calculatedLotSize = NormalizeDouble(lotPercentMultiplier * 0.01 * (currentBalanceBasis / lotSizingBalanceDivisor * 0.01),1) ;
   }
   if ( SymbolInfoDouble(currentSymbol,SYMBOL_VOLUME_STEP)==0.01 )
   {
     calculatedLotSize = NormalizeDouble(lotPercentMultiplier * 0.01 * (currentBalanceBasis / lotSizingBalanceDivisor * 0.01),2) ;
   }
 }
 if ( Risk == 1234 )
 {
   if ( UseWeightedLots )
   {
     if ( strategyDrawdownReferenceUsd==0.0 )
     {
       strategyDrawdownReferenceUsd = 100000.0 ;
     }
     weightedRiskPercentPerStrategy = MaxAllowedDD / enabledStrategyRiskWeight ;
     if ( SymbolInfoDouble(currentSymbol,SYMBOL_VOLUME_STEP)==0.1 )
     {
       calculatedLotSize = NormalizeDouble(weightedRiskPercentPerStrategy / strategyDrawdownReferenceUsd * currentBalanceBasis / 100.0 * 0.01,1) ;
     }
     if ( SymbolInfoDouble(currentSymbol,SYMBOL_VOLUME_STEP)==0.01 )
     {
       calculatedLotSize = NormalizeDouble(weightedRiskPercentPerStrategy / strategyDrawdownReferenceUsd * currentBalanceBasis / 100.0 * 0.01,2) ;
     }
   }
   else
   {
     if ( strategyDrawdownReferenceUsd==0.0 )
     {
       strategyDrawdownReferenceUsd = 100000.0 ;
     }
     accountBalanceUsd = ConvertAccountCurrencyToUsdRounded(currentBalanceBasis) ;
     if ( activeTradeFrequency == 0 )
     {
       lotSizingBalanceDivisor = (int)(autoFrequencyThreshold1 / (MaxAllowedDD / 100.0)) ;
     }
     if ( activeTradeFrequency == 1 )
     {
       lotSizingBalanceDivisor = (int)(autoFrequencyThreshold2 / (MaxAllowedDD / 100.0)) ;
     }
     if ( activeTradeFrequency == 2 )
     {
       lotSizingBalanceDivisor = (int)(autoFrequencyThreshold3 / (MaxAllowedDD / 100.0)) ;
     }
     if ( activeTradeFrequency == 3 )
     {
       lotSizingBalanceDivisor = (int)(autoFrequencyThreshold4 / (MaxAllowedDD / 100.0)) ;
     }
     if ( activeTradeFrequency == 4 )
     {
       lotSizingBalanceDivisor = (int)(autoFrequencyThreshold5 / (MaxAllowedDD / 100.0)) ;
     }
     if ( SymbolInfoDouble(currentSymbol,SYMBOL_VOLUME_STEP)==0.1 )
     {
       calculatedLotSize = NormalizeDouble(lotPercentMultiplier * 0.01 * (accountBalanceUsd / lotSizingBalanceDivisor * 0.01),1) ;
     }
     if ( SymbolInfoDouble(currentSymbol,SYMBOL_VOLUME_STEP)==0.01 )
     {
       calculatedLotSize = NormalizeDouble(lotPercentMultiplier * 0.01 * (accountBalanceUsd / lotSizingBalanceDivisor * 0.01),2) ;
     }
   }
 }
 if ( Risk == 3 )
 {
   if ( SymbolInfoDouble(currentSymbol,SYMBOL_VOLUME_STEP)==0.1 )
   {
     calculatedLotSize = NormalizeDouble(MaxRiskPerStrategy_ / strategyDrawdownReferenceUsd * currentBalanceBasis / 100.0 * 0.01,1) ;
   }
   if ( SymbolInfoDouble(currentSymbol,SYMBOL_VOLUME_STEP)==0.01 )
   {
     calculatedLotSize = NormalizeDouble(MaxRiskPerStrategy_ / strategyDrawdownReferenceUsd * currentBalanceBasis / 100.0 * 0.01,2) ;
   }
 }
 calculatedLotSize = calculatedLotSize * variableLotInverseScaleFactor ;
 if ( calculatedLotSize<SymbolInfoDouble(currentSymbol,SYMBOL_VOLUME_STEP) )
 {
   calculatedLotSize = SymbolInfoDouble(currentSymbol,SYMBOL_VOLUME_STEP) ;
 }
 if ( calculatedLotSize>maxCalculatedLotSize )
 {
   calculatedLotSize = maxCalculatedLotSize ;
 }
 if ( calculatedLotSize<SymbolInfoDouble(currentSymbol,SYMBOL_VOLUME_MIN) )
 {
   calculatedLotSize = SymbolInfoDouble(currentSymbol,SYMBOL_VOLUME_MIN) ;
 }
 if ( calculatedLotSize>SymbolInfoDouble(currentSymbol,SYMBOL_VOLUME_MAX) && SymbolInfoDouble(currentSymbol,SYMBOL_VOLUME_MAX)!=0.0 )
 {
   calculatedLotSize = SymbolInfoDouble(currentSymbol,SYMBOL_VOLUME_MAX) ;
 }
 if ( SymbolInfoDouble(currentSymbol,SYMBOL_VOLUME_STEP)==0.1 )
 {
   lotSizeByStrategy[currentStrategyIndex] = NormalizeDouble((MathFloor(calculatedLotSize * 10.0)) / 10.0,1);
   return;
 }
 lotSizeByStrategy[currentStrategyIndex] = NormalizeDouble(MathFloor(calculatedLotSize * 100.0) / 100.0,2);
 }
//CalculateStrategyLotSize <<==--------   --------
 double CalculateBuyEntryPrice( int timeframeMinutes)
 {
  bool      signalFound = false;
  bool      leftSideConfirmed = false;
  bool      rightSideConfirmed;
  int       candidateBarShift;
  int       rightCheckShift;
  int       leftCheckShift;
//----------------------------------------------------------------------
 double     candidateSwingPrice;
 int        candidateMaximumShift;
 double     extremePriceSinceCurrentBar;
 int        extremeScanShift;
 double     normalizedCandidatePrice;
 int        pendingOrderScanIndex;
 bool       duplicatePendingFound;

 rightSideConfirmed = false ;
 candidateBarShift=swingRightBars + 1;
 do
 {
   leftSideConfirmed = true ;
   rightSideConfirmed = true ;
   for (rightCheckShift = candidateBarShift ; rightCheckShift >= candidateBarShift - swingRightBars ; rightCheckShift --)
   {
     if ( iHigh(currentSymbol,NormalizeTimeframe(timeframeMinutes),rightCheckShift)>iHigh(currentSymbol,NormalizeTimeframe(timeframeMinutes),candidateBarShift) )
     {
       rightSideConfirmed = false ;
     }
   }
   for (leftCheckShift = candidateBarShift ; leftCheckShift <= candidateBarShift + swingLeftBars ; leftCheckShift ++)
   {
     if ( iHigh(currentSymbol,NormalizeTimeframe(timeframeMinutes),leftCheckShift)>iHigh(currentSymbol,NormalizeTimeframe(timeframeMinutes),candidateBarShift) )
     {
       leftSideConfirmed = false ;
     }
   }
   if ( rightSideConfirmed && leftSideConfirmed && iHigh(currentSymbol,NormalizeTimeframe(timeframeMinutes),candidateBarShift)>minEntryDistancePips * pipSize + SymbolInfoDouble(currentSymbol,SYMBOL_ASK) )
   {
     candidateSwingPrice = iHigh(currentSymbol,NormalizeTimeframe(timeframeMinutes),candidateBarShift);
     candidateMaximumShift = candidateBarShift;
     extremePriceSinceCurrentBar = iHigh(currentSymbol,NormalizeTimeframe(signalTimeframeMinutes),0);
     for (extremeScanShift = 1 ; extremeScanShift <= candidateMaximumShift ; extremeScanShift=extremeScanShift + 1)
     {
       if ( iHigh(currentSymbol,NormalizeTimeframe(signalTimeframeMinutes),extremeScanShift)>extremePriceSinceCurrentBar )
       {
         extremePriceSinceCurrentBar = iHigh(currentSymbol,NormalizeTimeframe(signalTimeframeMinutes),extremeScanShift);
       }
     }
     if ( candidateSwingPrice>=extremePriceSinceCurrentBar )
     {
       normalizedCandidatePrice = NormalizeDouble(iHigh(currentSymbol,NormalizeTimeframe(timeframeMinutes),candidateBarShift),symbolDigits);
       duplicatePendingFound=false; 
       for (pendingOrderScanIndex = ActiveTradeCount() ; pendingOrderScanIndex >= 0 ; pendingOrderScanIndex=pendingOrderScanIndex - 1)
       {
         if ( SelectTradeRecord(pendingOrderScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != strategyMagicNumber || SelectedTradeSymbol() != currentSymbol || SelectedTradeType() != ORDER_TYPE_BUY_STOP || !(MathAbs(SelectedTradeOpenPrice() - (buyEntryOffsetPips * pipSize + normalizedCandidatePrice))<duplicatePendingTolerancePips * pipSize) )   continue;
         duplicatePendingFound = true;
          break;
         
       }
       if ( !(duplicatePendingFound) && ( !(fakeoutConfirmationEnabled) || !(iClose(currentSymbol,NormalizeTimeframe(timeframeMinutes),candidateBarShift - 1)>iHigh(currentSymbol,NormalizeTimeframe(timeframeMinutes),candidateBarShift) - minEntryDistancePips * pipSize) ) )
       {
         signalFound = true ;
         currentBuyEntryPrice = NormalizeDouble(iHigh(currentSymbol,NormalizeTimeframe(timeframeMinutes),candidateBarShift),symbolDigits) ;
         buySignalBarShift = candidateBarShift ;
         break;
       }
     }
   }
   candidateBarShift ++;
   if ( candidateBarShift <= entryLookbackBars )   continue;
   currentBuyEntryPrice = 0.0 ;
   break;
   
 }
 while(!(signalFound));
 
 return(currentBuyEntryPrice); 
 }
//CalculateBuyEntryPrice <<==--------   --------
 double CalculateSellEntryPrice( int timeframeMinutes)
 {
  bool      signalFound = false;
  bool      leftSideConfirmed = false;
  bool      rightSideConfirmed;
  int       candidateBarShift;
  int       rightCheckShift;
  int       leftCheckShift;
//----------------------------------------------------------------------
 double     candidateSwingPrice;
 int        candidateMaximumShift;
 double     extremePriceSinceCurrentBar;
 int        extremeScanShift;
 double     normalizedCandidatePrice;
 int        pendingOrderScanIndex;
 bool       duplicatePendingFound;

 rightSideConfirmed = false ;
 candidateBarShift=swingRightBars + 1;
 do
 {
   leftSideConfirmed = true ;
   rightSideConfirmed = true ;
   for (rightCheckShift = candidateBarShift ; rightCheckShift >= candidateBarShift - swingRightBars ; rightCheckShift --)
   {
     if ( iLow(currentSymbol,NormalizeTimeframe(timeframeMinutes),rightCheckShift)<iLow(currentSymbol,NormalizeTimeframe(timeframeMinutes),candidateBarShift) )
     {
       rightSideConfirmed = false ;
     }
   }
   for (leftCheckShift = candidateBarShift ; leftCheckShift <= candidateBarShift + swingLeftBars ; leftCheckShift ++)
   {
     if ( iLow(currentSymbol,NormalizeTimeframe(timeframeMinutes),leftCheckShift)<iLow(currentSymbol,NormalizeTimeframe(timeframeMinutes),candidateBarShift) )
     {
       leftSideConfirmed = false ;
     }
   }
   if ( rightSideConfirmed && leftSideConfirmed && iLow(currentSymbol,NormalizeTimeframe(timeframeMinutes),candidateBarShift)<SymbolInfoDouble(currentSymbol,SYMBOL_BID) - minEntryDistancePips * pipSize )
   {
     candidateSwingPrice = iLow(currentSymbol,NormalizeTimeframe(timeframeMinutes),candidateBarShift);
     candidateMaximumShift = candidateBarShift;
     extremePriceSinceCurrentBar = iLow(currentSymbol,NormalizeTimeframe(signalTimeframeMinutes),0);
     for (extremeScanShift = 1 ; extremeScanShift <= candidateMaximumShift ; extremeScanShift=extremeScanShift + 1)
     {
       if ( iLow(currentSymbol,NormalizeTimeframe(signalTimeframeMinutes),extremeScanShift)<extremePriceSinceCurrentBar )
       {
         extremePriceSinceCurrentBar = iLow(currentSymbol,NormalizeTimeframe(signalTimeframeMinutes),extremeScanShift);
       }
     }
     if ( candidateSwingPrice<=extremePriceSinceCurrentBar )
     {
       normalizedCandidatePrice = NormalizeDouble(iLow(currentSymbol,NormalizeTimeframe(timeframeMinutes),candidateBarShift),symbolDigits);
       duplicatePendingFound=false; 
       for (pendingOrderScanIndex = ActiveTradeCount() ; pendingOrderScanIndex >= 0 ; pendingOrderScanIndex=pendingOrderScanIndex - 1)
       {
         if ( SelectTradeRecord(pendingOrderScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != strategyMagicNumber || SelectedTradeSymbol() != currentSymbol || SelectedTradeType() != ORDER_TYPE_SELL_STOP || !(MathAbs(SelectedTradeOpenPrice() - (normalizedCandidatePrice - sellEntryOffsetPips * pipSize))<duplicatePendingTolerancePips * pipSize) )   continue;
         duplicatePendingFound = true;
          break;
         
       }
       if ( !(duplicatePendingFound) && ( !(fakeoutConfirmationEnabled) || !(iClose(currentSymbol,NormalizeTimeframe(timeframeMinutes),candidateBarShift - 1)<minEntryDistancePips * pipSize + iLow(currentSymbol,NormalizeTimeframe(timeframeMinutes),candidateBarShift)) ) )
       {
         signalFound = true ;
         currentSellEntryPrice = NormalizeDouble(iLow(currentSymbol,NormalizeTimeframe(timeframeMinutes),candidateBarShift),symbolDigits) ;
         sellSignalBarShift = candidateBarShift ;
         break;
       }
     }
   }
   candidateBarShift ++;
   if ( candidateBarShift <= entryLookbackBars )   continue;
   currentSellEntryPrice = 0.0 ;
   break;
   
 }
 while(!(signalFound));
 
 return(currentSellEntryPrice); 
 }
//CalculateSellEntryPrice <<==--------   --------
 double FindQualifiedSwingHigh( int timeframeMinutes,int leftBars,int rightBars)
 {
  bool      swingFound = false;
  double    qualifiedSwingPrice = 0.0;
  bool      leftSideConfirmed = false;
  bool      rightSideConfirmed;
  int       candidateBarShift;
  int       rightCheckShift;
  int       leftCheckShift;
//----------------------------------------------------------------------

 rightSideConfirmed = false ;
 candidateBarShift=rightBars + 1;
 do
 {
   leftSideConfirmed = true ;
   rightSideConfirmed = true ;
   for (rightCheckShift = candidateBarShift ; rightCheckShift >= candidateBarShift - rightBars ; rightCheckShift --)
   {
     if ( iHigh(currentSymbol,NormalizeTimeframe(timeframeMinutes),rightCheckShift)>iHigh(currentSymbol,NormalizeTimeframe(timeframeMinutes),candidateBarShift) )
     {
       rightSideConfirmed = false ;
     }
   }
   for (leftCheckShift = candidateBarShift ; leftCheckShift <= candidateBarShift + leftBars ; leftCheckShift ++)
   {
     if ( iHigh(currentSymbol,NormalizeTimeframe(timeframeMinutes),leftCheckShift)>iHigh(currentSymbol,NormalizeTimeframe(timeframeMinutes),candidateBarShift) )
     {
       leftSideConfirmed = false ;
     }
   }
   if ( rightSideConfirmed && leftSideConfirmed && iHigh(currentSymbol,NormalizeTimeframe(timeframeMinutes),candidateBarShift)>stopLevelPriceDistance * pipSize + SymbolInfoDouble(currentSymbol,SYMBOL_ASK) )
   {
     swingFound = true ;
     qualifiedSwingPrice = NormalizeDouble(iHigh(currentSymbol,NormalizeTimeframe(timeframeMinutes),candidateBarShift),symbolDigits) ;
     break;
   }
   candidateBarShift ++;
   if ( candidateBarShift <= swingQualificationMinimumShift )   continue;
   qualifiedSwingPrice = 9999.0 ;
   break;
   
 }
 while(!(swingFound));
 
 return(qualifiedSwingPrice); 
 }
//FindQualifiedSwingHigh <<==--------   --------
 double FindQualifiedSwingLow( int timeframeMinutes,int leftBars,int rightBars)
 {
  bool      swingFound = false;
  double    qualifiedSwingPrice = 0.0;
  bool      leftSideConfirmed = false;
  bool      rightSideConfirmed;
  int       candidateBarShift;
  int       rightCheckShift;
  int       leftCheckShift;
//----------------------------------------------------------------------

 rightSideConfirmed = false ;
 candidateBarShift=rightBars + 1;
 do
 {
   leftSideConfirmed = true ;
   rightSideConfirmed = true ;
   for (rightCheckShift = candidateBarShift ; rightCheckShift >= candidateBarShift - rightBars ; rightCheckShift --)
   {
     if ( iLow(currentSymbol,NormalizeTimeframe(timeframeMinutes),rightCheckShift)<iLow(currentSymbol,NormalizeTimeframe(timeframeMinutes),candidateBarShift) )
     {
       rightSideConfirmed = false ;
     }
   }
   for (leftCheckShift = candidateBarShift ; leftCheckShift <= candidateBarShift + leftBars ; leftCheckShift ++)
   {
     if ( iLow(currentSymbol,NormalizeTimeframe(timeframeMinutes),leftCheckShift)<iLow(currentSymbol,NormalizeTimeframe(timeframeMinutes),candidateBarShift) )
     {
       leftSideConfirmed = false ;
     }
   }
   if ( rightSideConfirmed && leftSideConfirmed && iLow(currentSymbol,NormalizeTimeframe(timeframeMinutes),candidateBarShift)<SymbolInfoDouble(currentSymbol,SYMBOL_BID) - stopLevelPriceDistance * pipSize )
   {
     swingFound = true ;
     qualifiedSwingPrice = NormalizeDouble(iLow(currentSymbol,NormalizeTimeframe(timeframeMinutes),candidateBarShift),symbolDigits) ;
     break;
   }
   candidateBarShift ++;
   if ( candidateBarShift <= swingQualificationMinimumShift )   continue;
   qualifiedSwingPrice = 0.0 ;
   break;
   
 }
 while(!(swingFound));
 
 return(qualifiedSwingPrice); 
 }
//FindQualifiedSwingLow <<==--------   --------
 void ManagePendingEntries()
 {
  int       pendingExpirationScanIndex;
//----------------------------------------------------------------------
 long       currentTime;
 long       virtualExpirationTime;
 int        openBuyCount;
 int        openBuyScanIndex;
 int        buyDeleteMode;
 int        buyPendingDeleteIndex;
 int        manualBuyPendingDeleteIndex;
 int        openSellCount;
 int        openSellScanIndex;
 int        sellDeleteMode;
 int        sellPendingDeleteIndex;
 int        manualSellPendingDeleteIndex;

 if ( movingAverageTrendFilterEnabled )
 {
   fastMovingAverageValue = GetMovingAverageValue(currentSymbol,0,fastMovingAveragePeriod,0,1,0,1) ;
   slowMovingAverageValue = GetMovingAverageValue(currentSymbol,0,slowMovingAveragePeriod,0,1,0,1) ;
 }
 CalculateStrategyLotSize(stopLossPips,lotSizePercentMultiplier); 
 if ( lotSizeByStrategy[currentStrategyIndex]>maxCalculatedLotSize )
 {
   lotSizeByStrategy[currentStrategyIndex] = maxCalculatedLotSize;
 }
 if ( pendingExpirationHours >  0 )
 {
   pendingOrderExpirationTime=TimeCurrent() + pendingExpirationSeconds;
 }
 if ( Virtual_expiration )
 {
   pendingOrderExpirationTime = 0 ;
   for (pendingExpirationScanIndex = ActiveTradeCount() ; pendingExpirationScanIndex >= 0 ; pendingExpirationScanIndex --)
   {
     if ( SelectTradeRecord(pendingExpirationScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != strategyMagicNumber || SelectedTradeSymbol() != currentSymbol )   continue;
     
     if ( ( SelectedTradeType() != ORDER_TYPE_BUY_STOP && SelectedTradeType() != ORDER_TYPE_SELL_STOP ) )   continue;
     currentTime = TimeCurrent();
     virtualExpirationTime=SelectedTradeOpenTime() + pendingExpirationSeconds;
     if ( currentTime < virtualExpirationTime )   continue;
     DeletePendingOrderByTicket(SelectedTradeTicket(),Red); 
     
   }
 }
 openBuyCount = 0;
 for (openBuyScanIndex = ActiveTradeCount() ; openBuyScanIndex >= 0 ; openBuyScanIndex=openBuyScanIndex - 1)
 {
   if ( SelectTradeRecord(openBuyScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != strategyMagicNumber || SelectedTradeSymbol() != currentSymbol || SelectedTradeType() != ORDER_TYPE_BUY )   continue;
   openBuyCount=openBuyCount + 1;
   
 }
 if ( openBuyCount <  maxOpenTradesPerSide )
 {
   PlaceBuyStopOrder(1); 
 }
 else
 {
   buyDeleteMode = 1;
   for (buyPendingDeleteIndex = ActiveTradeCount() ; buyPendingDeleteIndex >= 0 ; buyPendingDeleteIndex=buyPendingDeleteIndex - 1)
   {
     if ( SelectTradeRecord(buyPendingDeleteIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != strategyMagicNumber || SelectedTradeSymbol() != currentSymbol || SelectedTradeType() != ORDER_TYPE_BUY_STOP )   continue;
     DeletePendingOrderByTicket(SelectedTradeTicket(),clrNONE); 
     
   }
   if ( buyDeleteMode == 2 )
   {
     for (manualBuyPendingDeleteIndex = ActiveTradeCount() ; manualBuyPendingDeleteIndex >= 0 ; manualBuyPendingDeleteIndex=manualBuyPendingDeleteIndex - 1)
     {
       if ( SelectTradeRecord(manualBuyPendingDeleteIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != manualStrategy2MagicNumber || SelectedTradeSymbol() != currentSymbol || SelectedTradeType() != ORDER_TYPE_BUY_STOP )   continue;
       DeletePendingOrderByTicket(SelectedTradeTicket(),clrNONE); 
       
     }
   }
 }
 openSellCount = 0;
 for (openSellScanIndex = ActiveTradeCount() ; openSellScanIndex >= 0 ; openSellScanIndex=openSellScanIndex - 1)
 {
   if ( SelectTradeRecord(openSellScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != strategyMagicNumber || SelectedTradeSymbol() != currentSymbol || SelectedTradeType() != ORDER_TYPE_SELL )   continue;
   openSellCount=openSellCount + 1;
   
 }
 if ( openSellCount <  maxOpenTradesPerSide )
 {
   PlaceSellStopOrder(1); 
   return;
 }
 sellDeleteMode = 1;
 for (sellPendingDeleteIndex = ActiveTradeCount() ; sellPendingDeleteIndex >= 0 ; sellPendingDeleteIndex=sellPendingDeleteIndex - 1)
 {
   if ( SelectTradeRecord(sellPendingDeleteIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != strategyMagicNumber || SelectedTradeSymbol() != currentSymbol || SelectedTradeType() != ORDER_TYPE_SELL_STOP )   continue;
   DeletePendingOrderByTicket(SelectedTradeTicket(),clrNONE); 
   
 }
 if ( sellDeleteMode != 2 )   return;
 for (manualSellPendingDeleteIndex = ActiveTradeCount() ; manualSellPendingDeleteIndex >= 0 ; manualSellPendingDeleteIndex=manualSellPendingDeleteIndex - 1)
 {
   if ( SelectTradeRecord(manualSellPendingDeleteIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != manualStrategy2MagicNumber || SelectedTradeSymbol() != currentSymbol || SelectedTradeType() != ORDER_TYPE_SELL_STOP )   continue;
   DeletePendingOrderByTicket(SelectedTradeTicket(),clrNONE); 
   
 }
 }
//ManagePendingEntries <<==--------   --------
 bool PlaceBuyStopOrder( int entryRequestMode)
 {
  bool      newSignalAvailable;
  double    pendingBasePrice;
  double    pendingOrderPrice;
  double    stopLossPrice;
  double    takeProfitPrice;
//----------------------------------------------------------------------
 bool       sameSideMarketTradeExists;
 int        marketTradeScanIndex;
 double     signalPrice;
 int        duplicateScanIndex;
 bool       duplicatePendingFound;
 int        pendingOrderCount;
 int        pendingCountScanIndex;
 double     boundaryPendingPrice;
 int        boundaryScanIndex;
 double     candidatePendingPrice;
 int        blockingOrderScanIndex;
 bool       moreExtremePendingExists;
 bool       volumeValid;
 int        accountOrderLimit;
 bool       orderLimitAvailable;
 int        sendErrorCode;
 double     requestedEntryPrice;
 long       submittedPendingTicket;
 int        ticketMapInsertIndex;

 if ( !(AllowBuyTrades) )
 {
   return(false); 
 }
 if ( allowMultipleOpenTradesPerSide )
 {
   sameSideMarketTradeExists = false;
 }
 else
 {
   sameSideMarketTradeExists=false; 
   for (marketTradeScanIndex = 0 ; marketTradeScanIndex < ActiveTradeCount() ; marketTradeScanIndex=marketTradeScanIndex + 1)
   {
     if ( SelectTradeRecord(marketTradeScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeType() != ORDER_TYPE_BUY || SelectedTradeMagic() != strategyMagicNumber || SelectedTradeSymbol() != currentSymbol )   continue;
     sameSideMarketTradeExists = true;
      break;
     
   }
 }
 if ( sameSideMarketTradeExists == true )
 {
   return(false); 
 }
 if ( movingAverageTrendFilterEnabled && fastMovingAverageValue<slowMovingAverageValue )
 {
   return(false); 
 }
 if ( entryRequestMode == 1 )
 {
   CalculateBuyEntryPrice(signalTimeframeMinutes); 
   newSignalAvailable = false ;
   signalPrice = currentBuyEntryPrice;
   duplicatePendingFound=false; 
   for (duplicateScanIndex = ActiveTradeCount() ; duplicateScanIndex >= 0 ; duplicateScanIndex=duplicateScanIndex - 1)
   {
     if ( SelectTradeRecord(duplicateScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != strategyMagicNumber || SelectedTradeSymbol() != currentSymbol || SelectedTradeType() != ORDER_TYPE_BUY_STOP || !(MathAbs(SelectedTradeOpenPrice() - (buyEntryOffsetPips * pipSize + signalPrice))<duplicatePendingTolerancePips * pipSize) )   continue;
     duplicatePendingFound = true;
      break;
     
   }
   if ( !(duplicatePendingFound) )
   {
     pendingOrderCount = 0;
     for (pendingCountScanIndex = ActiveTradeCount() ; pendingCountScanIndex >= 0 ; pendingCountScanIndex=pendingCountScanIndex - 1)
     {
       if ( SelectTradeRecord(pendingCountScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != strategyMagicNumber || SelectedTradeSymbol() != currentSymbol || SelectedTradeType() != ORDER_TYPE_BUY_STOP )   continue;
       pendingOrderCount=pendingOrderCount + 1;
       
     }
     if ( pendingOrderCount == maxPendingOrders )
     {
       boundaryPendingPrice = 9999.0;
       for (boundaryScanIndex = ActiveTradeCount() ; boundaryScanIndex >= 0 ; boundaryScanIndex=boundaryScanIndex - 1)
       {
         if ( SelectTradeRecord(boundaryScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != strategyMagicNumber || SelectedTradeSymbol() != currentSymbol || SelectedTradeType() != ORDER_TYPE_BUY_STOP || !(SelectedTradeOpenPrice()<boundaryPendingPrice) )   continue;
         boundaryPendingPrice = SelectedTradeOpenPrice();
         
       }
       if ( currentBuyEntryPrice>boundaryPendingPrice )
       {
         return(false); 
       }
     }
     lastBuySignalCandidatePrice = currentBuyEntryPrice ;
     newSignalAvailable = true ;
     cachedBuySignalPrice = NormalizeDouble(currentBuyEntryPrice,symbolDigits) ;
   }
   if ( cachedBuySignalPrice==0.0 )
   {
     return(false); 
   }
   if ( newSignalAvailable )
   {
     activeMagicTrailActivationPips = magicTrailActivationDistancePips ;
     pendingBasePrice = NormalizeDouble(buyEntryOffsetPips * pipSize + cachedBuySignalPrice,symbolDigits) ;
     candidatePendingPrice = pendingBasePrice;
     moreExtremePendingExists=false; 
     for (blockingOrderScanIndex = ActiveTradeCount() ; blockingOrderScanIndex >= 0 ; blockingOrderScanIndex=blockingOrderScanIndex - 1)
     {
       if ( SelectTradeRecord(blockingOrderScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != strategyMagicNumber || SelectedTradeSymbol() != currentSymbol || SelectedTradeType() != ORDER_TYPE_BUY_STOP || !(SelectedTradeOpenPrice()<=candidatePendingPrice) )   continue;
       moreExtremePendingExists = true;
        break;
       
     }
     if ( moreExtremePendingExists )
     {
       return(false); 
     }
     lastBuyPendingBasePrice = pendingBasePrice ;
     if ( !(virtualPendingOrdersEnabled) )
     {
       if ( CheckMargin && ProjectedFreeMarginAfterOrder(currentSymbol,ORDER_TYPE_BUY,lotSizeByStrategy[currentStrategyIndex])<=0.0 )
       {
         Print("Free margin not sufficient for setting order with lotsize " + string(lotSizeByStrategy[currentStrategyIndex]) + "..."); 
         return(false); 
       }
       pendingOrderPrice = NormalizeDouble(randomizedPendingEntryOffsetPips * pipSize + pendingBasePrice,symbolDigits) ;
       stopLossPrice = NormalizeDouble(pendingBasePrice - (stopLossPips + extraStopLossPips) * pipSize,symbolDigits) ;
       takeProfitPrice = NormalizeDouble(takeProfitPips * pipSize + pendingBasePrice,symbolDigits) ;
       if ( lotSizeByStrategy[currentStrategyIndex]<SymbolInfoDouble(currentSymbol,SYMBOL_VOLUME_MIN) )
       {
         Print("Volume is less than the minimal allowed SYMBOL_VOLUME_MIN=" + string(SymbolInfoDouble(currentSymbol,SYMBOL_VOLUME_MIN))); 
         volumeValid = false;
       }
       else
       {
         if ( lotSizeByStrategy[currentStrategyIndex]>SymbolInfoDouble(currentSymbol,SYMBOL_VOLUME_MAX) )
         {
           Print("Volume is greater than the maximal allowed SYMBOL_VOLUME_MAX=" + string(SymbolInfoDouble(currentSymbol,SYMBOL_VOLUME_MAX))); 
           volumeValid = false;
         }
         else
         {
           if ( MathAbs(NormalizeDouble(lotSizeByStrategy[currentStrategyIndex] / SymbolInfoDouble(currentSymbol,SYMBOL_VOLUME_STEP),0) * SymbolInfoDouble(currentSymbol,SYMBOL_VOLUME_STEP) - lotSizeByStrategy[currentStrategyIndex])>0.0000001 )
           {
             Print("Volume " + string(lotSizeByStrategy[currentStrategyIndex]) + " is not a multiple of the minimal step SYMBOL_VOLUME_STEP=" + string(SymbolInfoDouble(currentSymbol,SYMBOL_VOLUME_STEP))); 
             volumeValid = false;
           }
           else
           {
             volumeValid = true;
           }
         }
       }

       accountOrderLimit = (int)AccountInfoInteger(ACCOUNT_LIMIT_ORDERS);
       if ( accountOrderLimit == 0 )
       {
         orderLimitAvailable = true;
       }
       else
       {
         orderLimitAvailable = ActiveTradeCount()<accountOrderLimit;
       }
       if ( ( !(volumeValid) || !(orderLimitAvailable) ) )
       {
         return(false); 
       }
       if ( SymbolInfoDouble(currentSymbol,SYMBOL_ASK)<pendingOrderPrice - freezeLevelPriceDistance * pipSize && SymbolInfoDouble(currentSymbol,SYMBOL_ASK)<pendingOrderPrice - stopLevelPriceDistance * pipSize )
       {
         if ( !(setSL_TP_After_Entry) )
         {
           lastTradeTicket = SendTradeOrder(currentSymbol,ORDER_TYPE_BUY_STOP,lotSizeByStrategy[currentStrategyIndex],pendingOrderPrice,int(orderSlippageSetting * pipSize),stopLossPrice,takeProfitPrice,currentStrategyComment,strategyMagicNumber,pendingOrderExpirationTime,Green) ;
         }
         else
         {
           lastTradeTicket = SendTradeOrder(currentSymbol,ORDER_TYPE_BUY_STOP,lotSizeByStrategy[currentStrategyIndex],pendingOrderPrice,int(orderSlippageSetting * pipSize),0.0,0.0,currentStrategyComment,strategyMagicNumber,pendingOrderExpirationTime,Green) ;
         }
         buyPendingRestoreState = false ;
         if ( lastTradeTicket <= 0 )
         {
           sendErrorCode = LastTradeErrorCode();
           if ( sendErrorCode == 132 )
           {
             ResetLastError();
             if(1==0) // Điều kiện luôn sai; giữ nguyên nhánh vô hiệu từ mã gốc.
             {
               do
               {
                 Sleep(2500); 
                 if ( !(setSL_TP_After_Entry) )
                 {
                   sendErrorCode = (int)(orderSlippageSetting * pipSize);
                   lastTradeTicket = SendTradeOrder(currentSymbol,ORDER_TYPE_BUY_STOP,lotSizeByStrategy[currentStrategyIndex],pendingOrderPrice,sendErrorCode,stopLossPrice,takeProfitPrice,currentStrategyComment,strategyMagicNumber,pendingOrderExpirationTime,Green) ;
                 }
                 else
                 {
                   lastTradeTicket = SendTradeOrder(currentSymbol,ORDER_TYPE_BUY_STOP,lotSizeByStrategy[currentStrategyIndex],pendingOrderPrice,int(orderSlippageSetting * pipSize),0.0,0.0,currentStrategyComment,strategyMagicNumber,pendingOrderExpirationTime,Green) ;
                 }
                 buyPendingRestoreState = false ;
               }
               while(LastTradeErrorCode() == STRATEGY_ERROR_MARKET_CLOSED);
               
             }
           }
           Print("error: \'" + TradeErrorDescription(LastTradeErrorCode()) + "\' when setting entry order"); 
         }
         else
         {
           requestedEntryPrice = pendingBasePrice;
           submittedPendingTicket = lastTradeTicket;
           for (ticketMapInsertIndex = 0 ; ticketMapInsertIndex < 100 ; ticketMapInsertIndex=ticketMapInsertIndex + 1)
           {
             if ( !(pendingTicketPriceMap[ticketMapInsertIndex][0]==0.0) )   continue;
             pendingTicketPriceMap[ticketMapInsertIndex][0] = (double)submittedPendingTicket;
             pendingTicketPriceMap[ticketMapInsertIndex][1] = requestedEntryPrice;
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
//PlaceBuyStopOrder <<==--------   --------
 bool PlaceSellStopOrder( int entryRequestMode)
 {
  bool      newSignalAvailable;
  double    pendingBasePrice;
  double    pendingOrderPrice;
  double    stopLossPrice;
  double    takeProfitPrice;
//----------------------------------------------------------------------
 bool       sameSideMarketTradeExists;
 int        marketTradeScanIndex;
 double     signalPrice;
 int        duplicateScanIndex;
 bool       duplicatePendingFound;
 int        pendingOrderCount;
 int        pendingCountScanIndex;
 double     boundaryPendingPrice;
 int        boundaryScanIndex;
 double     candidatePendingPrice;
 int        blockingOrderScanIndex;
 bool       moreExtremePendingExists;
 bool       volumeValid;
 int        accountOrderLimit;
 bool       orderLimitAvailable;
 int        sendErrorCode;
 double     requestedEntryPrice;
 long       submittedPendingTicket;
 int        ticketMapInsertIndex;

 if ( !(AllowSellTrades) )
 {
   return(false); 
 }
 if ( allowMultipleOpenTradesPerSide )
 {
   sameSideMarketTradeExists = false;
 }
 else
 {
   sameSideMarketTradeExists=false; 
   for (marketTradeScanIndex = 0 ; marketTradeScanIndex < ActiveTradeCount() ; marketTradeScanIndex=marketTradeScanIndex + 1)
   {
     if ( SelectTradeRecord(marketTradeScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeType() != ORDER_TYPE_SELL || SelectedTradeMagic() != strategyMagicNumber || SelectedTradeSymbol() != currentSymbol )   continue;
     sameSideMarketTradeExists = true;
      break;
     
   }
 }
 if ( sameSideMarketTradeExists == true )
 {
   return(false); 
 }
 if ( movingAverageTrendFilterEnabled && fastMovingAverageValue>slowMovingAverageValue )
 {
   return(false); 
 }
 if ( entryRequestMode == 1 )
 {
   CalculateSellEntryPrice(signalTimeframeMinutes); 
   newSignalAvailable = false ;
   signalPrice = currentSellEntryPrice;
   duplicatePendingFound=false; 
   for (duplicateScanIndex = ActiveTradeCount() ; duplicateScanIndex >= 0 ; duplicateScanIndex=duplicateScanIndex - 1)
   {
     if ( SelectTradeRecord(duplicateScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != strategyMagicNumber || SelectedTradeSymbol() != currentSymbol || SelectedTradeType() != ORDER_TYPE_SELL_STOP || !(MathAbs(SelectedTradeOpenPrice() - (signalPrice - sellEntryOffsetPips * pipSize))<duplicatePendingTolerancePips * pipSize) )   continue;
     duplicatePendingFound = true;
      break;
     
   }
   if ( !(duplicatePendingFound) )
   {
     pendingOrderCount = 0;
     for (pendingCountScanIndex = ActiveTradeCount() ; pendingCountScanIndex >= 0 ; pendingCountScanIndex=pendingCountScanIndex - 1)
     {
       if ( SelectTradeRecord(pendingCountScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != strategyMagicNumber || SelectedTradeSymbol() != currentSymbol || SelectedTradeType() != ORDER_TYPE_SELL_STOP )   continue;
       pendingOrderCount=pendingOrderCount + 1;
       
     }
     if ( pendingOrderCount == maxPendingOrders )
     {
       boundaryPendingPrice = 0.0;
       for (boundaryScanIndex = ActiveTradeCount() ; boundaryScanIndex >= 0 ; boundaryScanIndex=boundaryScanIndex - 1)
       {
         if ( SelectTradeRecord(boundaryScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != strategyMagicNumber || SelectedTradeSymbol() != currentSymbol || SelectedTradeType() != ORDER_TYPE_SELL_STOP || !(SelectedTradeOpenPrice()>boundaryPendingPrice) )   continue;
         boundaryPendingPrice = SelectedTradeOpenPrice();
         
       }
       if ( currentSellEntryPrice<boundaryPendingPrice )
       {
         return(false); 
       }
     }
     lastSellSignalCandidatePrice = currentSellEntryPrice ;
     newSignalAvailable = true ;
     cachedSellSignalPrice = NormalizeDouble(currentSellEntryPrice,symbolDigits) ;
   }
   if ( cachedSellSignalPrice==0.0 )
   {
     return(false); 
   }
   if ( newSignalAvailable )
   {
     activeMagicTrailActivationPips = magicTrailActivationDistancePips ;
     pendingBasePrice = NormalizeDouble(cachedSellSignalPrice - sellEntryOffsetPips * pipSize,symbolDigits) ;
     candidatePendingPrice = pendingBasePrice;
     moreExtremePendingExists=false; 
     for (blockingOrderScanIndex = ActiveTradeCount() ; blockingOrderScanIndex >= 0 ; blockingOrderScanIndex=blockingOrderScanIndex - 1)
     {
       if ( SelectTradeRecord(blockingOrderScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != strategyMagicNumber || SelectedTradeSymbol() != currentSymbol || SelectedTradeType() != ORDER_TYPE_SELL_STOP || !(SelectedTradeOpenPrice()>=candidatePendingPrice) )   continue;
       moreExtremePendingExists = true;
        break;
       
     }
     if ( moreExtremePendingExists )
     {
       return(false); 
     }
     lastSellPendingBasePrice = pendingBasePrice ;
     if ( !(virtualPendingOrdersEnabled) )
     {
       if ( CheckMargin && ProjectedFreeMarginAfterOrder(currentSymbol,ORDER_TYPE_SELL,lotSizeByStrategy[currentStrategyIndex])<=0.0 )
       {
         Print("Free margin not sufficient for setting order with lotsize " + string(lotSizeByStrategy[currentStrategyIndex]) + "..."); 
         return(false); 
       }
       pendingOrderPrice = NormalizeDouble(pendingBasePrice - randomizedPendingEntryOffsetPips * pipSize,symbolDigits) ;
       stopLossPrice = NormalizeDouble((stopLossPips + extraStopLossPips) * pipSize + pendingBasePrice,symbolDigits) ;
       takeProfitPrice = NormalizeDouble(pendingBasePrice - takeProfitPips * pipSize,symbolDigits) ;
       if ( lotSizeByStrategy[currentStrategyIndex]<SymbolInfoDouble(currentSymbol,SYMBOL_VOLUME_MIN) )
       {
         Print("Volume is less than the minimal allowed SYMBOL_VOLUME_MIN=" + string(SymbolInfoDouble(currentSymbol,SYMBOL_VOLUME_MIN))); 
         volumeValid = false;
       }
       else
       {
         if ( lotSizeByStrategy[currentStrategyIndex]>SymbolInfoDouble(currentSymbol,SYMBOL_VOLUME_MAX) )
         {
           Print("Volume is greater than the maximal allowed SYMBOL_VOLUME_MAX=" + string(SymbolInfoDouble(currentSymbol,SYMBOL_VOLUME_MAX))); 
           volumeValid = false;
         }
         else
         {
           if ( MathAbs(NormalizeDouble(lotSizeByStrategy[currentStrategyIndex] / SymbolInfoDouble(currentSymbol,SYMBOL_VOLUME_STEP),0) * SymbolInfoDouble(currentSymbol,SYMBOL_VOLUME_STEP) - lotSizeByStrategy[currentStrategyIndex])>0.0000001 )
           {
             Print("Volume " + string(lotSizeByStrategy[currentStrategyIndex]) + " is not a multiple of the minimal step SYMBOL_VOLUME_STEP=" + string(SymbolInfoDouble(currentSymbol,SYMBOL_VOLUME_STEP))); 
             volumeValid = false;
           }
           else
           {
             volumeValid = true;
           }
         }
       }

       accountOrderLimit = (int)AccountInfoInteger(ACCOUNT_LIMIT_ORDERS);
       if ( accountOrderLimit == 0 )
       {
         orderLimitAvailable = true;
       }
       else
       {
         orderLimitAvailable = ActiveTradeCount()<accountOrderLimit;
       }
       if ( ( !(volumeValid) || !(orderLimitAvailable) ) )
       {
         return(false); 
       }
       if ( SymbolInfoDouble(currentSymbol,SYMBOL_BID)>freezeLevelPriceDistance * pipSize + pendingOrderPrice && SymbolInfoDouble(currentSymbol,SYMBOL_BID)>stopLevelPriceDistance * pipSize + pendingOrderPrice )
       {
         if ( !(setSL_TP_After_Entry) )
         {
           lastTradeTicket = SendTradeOrder(currentSymbol,ORDER_TYPE_SELL_STOP,lotSizeByStrategy[currentStrategyIndex],pendingOrderPrice,int(orderSlippageSetting * pipSize),stopLossPrice,takeProfitPrice,currentStrategyComment,strategyMagicNumber,pendingOrderExpirationTime,Red) ;
         }
         else
         {
           lastTradeTicket = SendTradeOrder(currentSymbol,ORDER_TYPE_SELL_STOP,lotSizeByStrategy[currentStrategyIndex],pendingOrderPrice,int(orderSlippageSetting * pipSize),0.0,0.0,currentStrategyComment,strategyMagicNumber,pendingOrderExpirationTime,Red) ;
         }
         sellPendingRestoreState = false ;
         if ( lastTradeTicket <= 0 )
         {
           sendErrorCode = LastTradeErrorCode();
           if ( sendErrorCode == 132 )
           {
             ResetLastError();
             if(1==0) // Điều kiện luôn sai; giữ nguyên nhánh vô hiệu từ mã gốc.
             {
               do
               {
                 Sleep(2500); 
                 if ( !(setSL_TP_After_Entry) )
                 {
                   sendErrorCode = (int)(orderSlippageSetting * pipSize);
                   lastTradeTicket = SendTradeOrder(currentSymbol,ORDER_TYPE_SELL_STOP,lotSizeByStrategy[currentStrategyIndex],pendingOrderPrice,sendErrorCode,stopLossPrice,takeProfitPrice,currentStrategyComment,strategyMagicNumber,pendingOrderExpirationTime,Red) ;
                 }
                 else
                 {
                   lastTradeTicket = SendTradeOrder(currentSymbol,ORDER_TYPE_SELL_STOP,lotSizeByStrategy[currentStrategyIndex],pendingOrderPrice,int(orderSlippageSetting * pipSize),0.0,0.0,currentStrategyComment,strategyMagicNumber,pendingOrderExpirationTime,Red) ;
                 }
                 sellPendingRestoreState = false ;
               }
               while(LastTradeErrorCode() == STRATEGY_ERROR_MARKET_CLOSED);
               
             }
           }
           Print("error: \'" + TradeErrorDescription(LastTradeErrorCode()) + "\' when setting entry order"); 
         }
         else
         {
           requestedEntryPrice = pendingBasePrice;
           submittedPendingTicket = lastTradeTicket;
           for (ticketMapInsertIndex = 0 ; ticketMapInsertIndex < 100 ; ticketMapInsertIndex=ticketMapInsertIndex + 1)
           {
             if ( !(pendingTicketPriceMap[ticketMapInsertIndex][0]==0.0) )   continue;
             pendingTicketPriceMap[ticketMapInsertIndex][0] = (double)submittedPendingTicket;
             pendingTicketPriceMap[ticketMapInsertIndex][1] = requestedEntryPrice;
             break;
             
           }
         }
       }
     }
   }
 }
 return(false); 
 }
//PlaceSellStopOrder <<==--------   --------
 bool ManageBuyTrades()
 {
  bool      orderStateChanged = false;
  bool      anyTradeChanged = false;
  double    originalStopLoss;
  double    trailReferencePrice;
  int       orderScanIndex;
  double    stopLossPrice;
  double    takeProfitPrice;
  long      orderTicket;
  double    openPrice;
  string    orderComment;
  double    orderLots;
  datetime  openTime;
  int       orderType;
  long       orderMagic;
  string    orderSymbol;
  double    requestedEntryPrice;
  double    entrySlippagePrice;
  bool      excessiveEntrySlippage;
  bool      zoneRecoveryHandled;
  double    zoneRecoveryOrderCount;
  bool      zoneRecoveryOrderPlaced;
  double    zoneRecoveryNextLots;
  double    zoneRecoveryTriggerPrice;
  double    zoneRecoveryReverseTriggerPrice;
  double    partialCloseLots;
  double    virtualStopPrice;
  int       virtualStopSyncElapsedSeconds;
  double    partialCloseLotsAfterTrail;
//----------------------------------------------------------------------
 int        priceDigits;
 long       entryTicketLookup;
 int        entryPriceMapIndex;
 double     mappedRequestedEntryPrice;
 double     openPriceForMap;
 long       ticketForMapInsert;
 int        ticketMapInsertIndex;
 long       zoneParentTicket;
 int        zoneOrderCount;
 int        zoneOrderScanIndex;
 string     zoneOrderComment;
 double     accountEquity;
 int        zoneCloseAllScanIndex;
 long       zoneProfitParentTicket;
 double     zoneCombinedProfit;
 int        zoneProfitScanIndex;
 long       zoneSelectedTicket;
 long       zoneCloseParentTicket;
 int        zoneCloseScanIndex;
 int        zoneMaximumTradesCloseScanIndexA;
 int        zoneMaximumTradesCloseScanIndexB;
 string     zoneReverseOrderComment;
 long       virtualStopTicketPrimary;
 double     virtualStopDistancePipsPrimary;
 double     virtualStopOpenPricePrimary;
 int        virtualStopDirectionPrimary;
 double     storedVirtualStopPrimary;
 bool       virtualStopFoundPrimary;
 int        virtualStopLookupIndexPrimary;
 int        virtualStopInsertIndexPrimary;
 double     updatedVirtualStopPrimary;
 long       virtualStopUpdateTicketPrimary;
 int        virtualStopUpdateIndexPrimary;
 long       virtualStopTicketSecondary;
 double     virtualStopDistancePipsSecondary;
 double     virtualStopOpenPriceSecondary;
 int        virtualStopDirectionSecondary;
 double     storedVirtualStopSecondary;
 bool       virtualStopFoundSecondary;
 int        virtualStopLookupIndexSecondary;
 int        virtualStopInsertIndexSecondary;
 double     updatedVirtualStopSecondary;
 long       virtualStopUpdateTicketSecondary;
 int        virtualStopUpdateIndexSecondary;

 originalStopLoss = 0.0 ;
 trailReferencePrice = 0.0 ;
 for (orderScanIndex = 0 ; orderScanIndex < ActiveTradeCount() ; orderScanIndex ++)
 {
   if ( SelectTradeRecord(orderScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) == true )
   {
     orderStateChanged = false ;
     stopLossPrice = NormalizeDouble(SelectedTradeStopLoss(),symbolDigits) ;
     takeProfitPrice = NormalizeDouble(SelectedTradeTakeProfit(),symbolDigits) ;
     orderTicket = SelectedTradeTicket() ;
     openPrice = NormalizeDouble(SelectedTradeOpenPrice(),symbolDigits) ;
     orderComment = SelectedTradeComment() ;
     orderLots = SelectedTradeVolume() ;
     openTime = SelectedTradeOpenTime() ;
     orderType = SelectedTradeType() ;
     orderMagic = SelectedTradeMagic() ;
     orderSymbol = SelectedTradeSymbol() ;
     if ( ( orderType == 4 || orderType == 2 ) && entryStrategyMode == 2 && ( manualTradeSymbolFilterMode == 0 || (manualTradeSymbolFilterMode == 1 && orderSymbol == currentSymbol) ) && ( orderMagic == manualStrategy2MagicNumber || manualStrategy2MagicNumber == 0 ) && ( orderComment == manualStrategy2Comment || manualStrategy2Comment == "" ) )
     {
       if ( ( stopLossPrice==0.0 || stopLossPrice==0.0 ) )
       {
         stopLossPrice = NormalizeDouble(openPrice - stopLossPips * pipSize,symbolDigits) ;
         ModifyTradeByTicket(orderTicket,openPrice,stopLossPrice,takeProfitPrice,0,Green); 
       }
       if ( ( takeProfitPrice==0.0 || takeProfitPrice==0.0 ) )
       {
         takeProfitPrice = NormalizeDouble(takeProfitPips * pipSize + openPrice,symbolDigits) ;
         ModifyTradeByTicket(orderTicket,openPrice,stopLossPrice,takeProfitPrice,0,Green); 
       }
     }
     if ( orderType == 0 && ( ( orderMagic == strategyMagicNumber && entryStrategyMode == 1 && orderSymbol == currentSymbol ) || (entryStrategyMode == 2 && ( manualTradeSymbolFilterMode == 0 || (manualTradeSymbolFilterMode == 1 && orderSymbol == currentSymbol) ) && ( orderMagic == manualStrategy2MagicNumber || manualStrategy2MagicNumber == 0 ) && (orderComment == manualStrategy2Comment || manualStrategy2Comment == "")) ) )
     {
       if ( ( stopLossPrice==0.0 || stopLossPrice==0.0 ) )
       {
         stopLossPrice = NormalizeDouble(openPrice - stopLossPips * pipSize,symbolDigits) ;
         ModifyTradeByTicket(orderTicket,openPrice,stopLossPrice,takeProfitPrice,0,Green); 
       }
       if ( ( takeProfitPrice==0.0 || takeProfitPrice==0.0 ) )
       {
         takeProfitPrice = NormalizeDouble(takeProfitPips * pipSize + openPrice,symbolDigits) ;
         ModifyTradeByTicket(orderTicket,openPrice,stopLossPrice,takeProfitPrice,0,Green); 
       }
       if ( candleExitM1Enabled && iTime(currentSymbol,NormalizeTimeframe(candleExitM1TimeframeMinutes),candleExitOpenBarShift) <= openTime && iTime(currentSymbol,NormalizeTimeframe(candleExitM1TimeframeMinutes),0) >  openTime && iClose(currentSymbol,NormalizeTimeframe(candleExitM1TimeframeMinutes),1)<iOpen(currentSymbol,NormalizeTimeframe(candleExitM1TimeframeMinutes),1) && iClose(currentSymbol,NormalizeTimeframe(candleExitM1TimeframeMinutes),1)<openPrice )
       {
         ClosePositionByTicket(orderTicket,orderLots,SymbolInfoDouble(currentSymbol,SYMBOL_BID),0,Red); 
         Print("closing candle confirmation"); 
       }
       if ( candleExitM5Enabled && iTime(currentSymbol,NormalizeTimeframe(candleExitM5TimeframeMinutes),candleExitOpenBarShift) <= openTime && iTime(currentSymbol,NormalizeTimeframe(candleExitM5TimeframeMinutes),0) >  openTime && iClose(currentSymbol,NormalizeTimeframe(candleExitM5TimeframeMinutes),1)<iOpen(currentSymbol,NormalizeTimeframe(candleExitM5TimeframeMinutes),1) && iClose(currentSymbol,NormalizeTimeframe(candleExitM5TimeframeMinutes),1)<openPrice )
       {
         ClosePositionByTicket(orderTicket,orderLots,SymbolInfoDouble(currentSymbol,SYMBOL_BID),0,Red); 
         Print("closing candle confirmation"); 
       }
       if ( candleExitM15Enabled && iTime(currentSymbol,NormalizeTimeframe(candleExitM15TimeframeMinutes),candleExitOpenBarShift) <= openTime && iTime(currentSymbol,NormalizeTimeframe(candleExitM15TimeframeMinutes),0) >  openTime && iClose(currentSymbol,NormalizeTimeframe(candleExitM15TimeframeMinutes),1)<iOpen(currentSymbol,NormalizeTimeframe(candleExitM15TimeframeMinutes),1) && iClose(currentSymbol,NormalizeTimeframe(candleExitM15TimeframeMinutes),1)<openPrice )
       {
         ClosePositionByTicket(orderTicket,orderLots,SymbolInfoDouble(currentSymbol,SYMBOL_BID),0,Red); 
         Print("closing candle confirmation"); 
       }
       if ( candleExitM30Enabled && iTime(currentSymbol,NormalizeTimeframe(candleExitM30TimeframeMinutes),candleExitOpenBarShift) <= openTime && iTime(currentSymbol,NormalizeTimeframe(candleExitM30TimeframeMinutes),0) >  openTime && iClose(currentSymbol,NormalizeTimeframe(candleExitM30TimeframeMinutes),1)<iOpen(currentSymbol,NormalizeTimeframe(candleExitM30TimeframeMinutes),1) && iClose(currentSymbol,NormalizeTimeframe(candleExitM30TimeframeMinutes),1)<openPrice )
       {
         ClosePositionByTicket(orderTicket,orderLots,SymbolInfoDouble(currentSymbol,SYMBOL_BID),0,Red); 
         Print("closing candle confirmation"); 
       }
       if ( candleExitH1Enabled && iTime(currentSymbol,NormalizeTimeframe(candleExitH1TimeframeMinutes),candleExitOpenBarShift) <= openTime && iTime(currentSymbol,NormalizeTimeframe(candleExitH1TimeframeMinutes),0) >  openTime && iClose(currentSymbol,NormalizeTimeframe(candleExitH1TimeframeMinutes),1)<iOpen(currentSymbol,NormalizeTimeframe(candleExitH1TimeframeMinutes),1) && iClose(currentSymbol,NormalizeTimeframe(candleExitH1TimeframeMinutes),1)<openPrice )
       {
         ClosePositionByTicket(orderTicket,orderLots,SymbolInfoDouble(currentSymbol,SYMBOL_BID),0,Red); 
         Print("closing candle confirmation"); 
       }
       activeMagicTrailActivationPips = magicTrailActivationDistancePips ;
       if ( magicTrailDelayMinutes >  0 && TimeCurrent() >  openTime + magicTrailDelayMinutes * 60 )
       {
         activeMagicTrailActivationPips = magicTrailDelayedActivationPips ;
       }
       priceDigits = symbolDigits;
       entryTicketLookup = orderTicket;
       for (entryPriceMapIndex = 0 ; entryPriceMapIndex < 100 ; entryPriceMapIndex=entryPriceMapIndex + 1)
       {
         if ( !(pendingTicketPriceMap[entryPriceMapIndex][0]==entryTicketLookup) )   continue;
         mappedRequestedEntryPrice = pendingTicketPriceMap[entryPriceMapIndex][1];
         break;
         
       }
       mappedRequestedEntryPrice = 0.0;
       requestedEntryPrice = NormalizeDouble(mappedRequestedEntryPrice,priceDigits) ;
       if ( requestedEntryPrice==0.0 )
       {
         openPriceForMap = openPrice;
         ticketForMapInsert = orderTicket;
         for (ticketMapInsertIndex = 0 ; ticketMapInsertIndex < 100 ; ticketMapInsertIndex=ticketMapInsertIndex + 1)
         {
           if ( !(pendingTicketPriceMap[ticketMapInsertIndex][0]==0.0) )   continue;
           pendingTicketPriceMap[ticketMapInsertIndex][0] = (double)ticketForMapInsert;
           pendingTicketPriceMap[ticketMapInsertIndex][1] = openPriceForMap;
           break;
           
         }
         requestedEntryPrice = openPrice ;
       }
       else
       {
         requestedEntryPrice = requestedEntryPrice - requestedEntryAdjustmentPips * pipSize ;
       }
       entrySlippagePrice = openPrice - requestedEntryPrice ;
       excessiveEntrySlippage = false ;
       if ( requestedEntryPrice>0.0 - requestedEntryAdjustmentPips * pipSize && entrySlippagePrice>orderSlippageSetting * pipSize )
       {
         excessiveEntrySlippage = true ;
         if ( slippageControlMode == 2 )
         {
           activeMagicTrailActivationPips = -1000.0 ;
           Print("SlippageMode 2 active"); 
         }
       }
       if ( useRequestedEntryAsTrailReference )
       {
         trailReferencePrice = requestedEntryPrice ;
       }
       else
       {
         trailReferencePrice = openPrice ;
       }
       if ( stopLossPrice<NormalizeDouble(openPrice - (stopLossPips + extraStopLossPips) * pipSize - currentSpreadPrice,symbolDigits) )
       {
         stopLossPrice = NormalizeDouble(openPrice - (stopLossPips + extraStopLossPips) * pipSize - currentSpreadPrice,symbolDigits) ;
         ModifyTradeByTicket(orderTicket,openPrice,stopLossPrice,takeProfitPrice,0,clrNONE); 
       }
       if ( SymbolInfoDouble(currentSymbol,SYMBOL_BID)<openPrice - (stopLossPips + extraStopLossPips) * pipSize - currentSpreadPrice )
       {
         RefreshCurrentSymbolTick(); 
         ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(currentSymbol,SYMBOL_BID),(int)currentSpreadPrice,Red); 
         return(true); 
       }
       zoneRecoveryHandled = false ;
       if ( zoneRecoveryEnabled )
       {
         zoneParentTicket = orderTicket;
         zoneOrderCount = 0;
         for (zoneOrderScanIndex = ActiveTradeCount() ; zoneOrderScanIndex >= 0 ; zoneOrderScanIndex=zoneOrderScanIndex - 1)
         {
           if ( SelectTradeRecord(zoneOrderScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != zoneRecoveryBuyMagic || SelectedTradeSymbol() != currentSymbol )   continue;
           zoneOrderComment = SelectedTradeComment();
           if ( zoneOrderComment != IntegerToString(zoneParentTicket,0,32) )   continue;
           zoneOrderCount=zoneOrderCount + 1;
           
         }
         zoneRecoveryOrderCount = zoneOrderCount ;
         zoneRecoveryOrderPlaced = false ;
         if ( !(buyZoneStateInitialized) )
         {
           buyZoneStateInitialized = true ;
           buyZoneNextOrderSide = 0 ;
         }
         if ( zoneRecoveryOrderCount==0.0 )
         {
           buyZoneNextOrderSide = 0 ;
         }
         if ( MathFloor(zoneRecoveryOrderCount / 2.0)==zoneRecoveryOrderCount / 2.0 )
         {
           buyZoneNextOrderSide = 0 ;
         }
         else
         {
           buyZoneNextOrderSide = 1 ;
         }
         if ( buyZoneStateInitialized )
         {
           if ( zoneRecoveryOrderCount>0.0 )
           {
             accountEquity = AccountInfoDouble(ACCOUNT_EQUITY);
             if ( accountEquity>AccountInfoDouble(ACCOUNT_BALANCE) + zoneRecoveryProfitTarget )
             {
               for (zoneCloseAllScanIndex = ActiveTradeCount() ; zoneCloseAllScanIndex >= 0 ; zoneCloseAllScanIndex=zoneCloseAllScanIndex - 1)
               {
                 if ( SelectTradeRecord(zoneCloseAllScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true )   continue;
                 
                 if ( ( SelectedTradeMagic() != strategyMagicNumber && SelectedTradeMagic() != zoneRecoverySellMagic && SelectedTradeMagic() != zoneRecoveryBuyMagic ) )   continue;
                 
                 if ( SelectedTradeType() == ORDER_TYPE_BUY )
                 {
                   ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(currentSymbol,SYMBOL_BID),(int)orderSlippageSetting,Red); 
                 }
                 if ( SelectedTradeType() != ORDER_TYPE_SELL )   continue;
                 ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(currentSymbol,SYMBOL_ASK),(int)orderSlippageSetting,Red); 
                 
               }
             }
           }
           if ( zoneRecoveryOrderCount>0.0 )
           {
             zoneProfitParentTicket = orderTicket;
             zoneCombinedProfit = 0.0;
             for (zoneProfitScanIndex = ActiveTradeCount() ; zoneProfitScanIndex >= 0 ; zoneProfitScanIndex=zoneProfitScanIndex - 1)
             {
               if ( SelectTradeRecord(zoneProfitScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true )   continue;
               zoneSelectedTicket = SelectedTradeTicket();
               if ( zoneSelectedTicket != zoneProfitParentTicket )
               {
                 zoneOrderComment = SelectedTradeComment();
               if ( zoneOrderComment != IntegerToString(zoneProfitParentTicket,0,32) )   continue;
               }
               zoneCombinedProfit = zoneCombinedProfit + SelectedTradeProfit();
               
             }
             if ( zoneCombinedProfit>zoneRecoveryProfitTarget )
             {
               Print("Closing zone"); 
               zoneCloseParentTicket = orderTicket;
               for (zoneCloseScanIndex = ActiveTradeCount() ; zoneCloseScanIndex >= 0 ; zoneCloseScanIndex=zoneCloseScanIndex - 1)
               {
                 if ( SelectTradeRecord(zoneCloseScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true )   continue;
                 
                 if ( SelectedTradeMagic() == strategyMagicNumber && SelectedTradeTicket() == zoneCloseParentTicket )
                 {
                   ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(currentSymbol,SYMBOL_BID),3,Red); 
                 }
                 if ( SelectedTradeMagic() != zoneRecoveryBuyMagic )   continue;
                 zoneOrderComment = SelectedTradeComment();
                 if ( zoneOrderComment != IntegerToString(zoneCloseParentTicket,0,32) )   continue;
                 
                 if ( SelectedTradeType() == ORDER_TYPE_BUY )
                 {
                   ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(currentSymbol,SYMBOL_BID),(int)orderSlippageSetting,Red); 
                 }
                 if ( SelectedTradeType() != ORDER_TYPE_SELL )   continue;
                 ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(currentSymbol,SYMBOL_ASK),(int)orderSlippageSetting,Red); 
                 
               }
               buyZoneStateInitialized = false ;
               zoneRecoveryHandled = true ;
             }
           }
           else
           {
             zoneRecoveryNextLots = orderLots * zoneRecoveryLotMultiplier ;
             if ( zoneRecoveryLotSizingMode == 2 )
             {
               zoneRecoveryNextLots = (zoneRecoveryOrderCount + 1.0) * orderLots + orderLots ;
             }
             if ( zoneRecoveryLotSizingMode == 3 )
             {
               zoneRecoveryNextLots = orderLots * (MathPow(zoneRecoveryLotMultiplier,zoneRecoveryOrderCount + 1.0)) ;
             }
             if ( buyZoneNextOrderSide == 0 )
             {
               zoneRecoveryTriggerPrice = zoneRecoveryOrderCount * zoneRecoveryStepDistancePips * pipSize + (requestedEntryPrice - zoneRecoveryInitialDistancePips * pipSize) ;
               if ( zoneRecoveryTriggerPrice>requestedEntryPrice - zoneRecoveryMinimumDistancePips * pipSize )
               {
                 zoneRecoveryTriggerPrice = requestedEntryPrice - zoneRecoveryMinimumDistancePips * pipSize ;
               }
               if ( SymbolInfoDouble(currentSymbol,SYMBOL_BID)<zoneRecoveryTriggerPrice )
               {
                 if ( zoneRecoveryOrderCount>=zoneRecoveryMaximumTrades )
                 {
                   for (zoneMaximumTradesCloseScanIndexA = ActiveTradeCount() ; zoneMaximumTradesCloseScanIndexA >= 0 ; zoneMaximumTradesCloseScanIndexA=zoneMaximumTradesCloseScanIndexA - 1)
                   {
                     if ( SelectTradeRecord(zoneMaximumTradesCloseScanIndexA,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true )   continue;
                     
                     if ( SelectedTradeMagic() == strategyMagicNumber && SelectedTradeTicket() == orderTicket )
                     {
                       ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(currentSymbol,SYMBOL_BID),3,Red); 
                     }
                     if ( SelectedTradeMagic() != zoneRecoveryBuyMagic )   continue;
                     zoneOrderComment = SelectedTradeComment();
                     if ( zoneOrderComment != IntegerToString(orderTicket,0,32) )   continue;
                     
                     if ( SelectedTradeType() == ORDER_TYPE_BUY )
                     {
                       ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(currentSymbol,SYMBOL_BID),(int)orderSlippageSetting,Red); 
                     }
                     if ( SelectedTradeType() != ORDER_TYPE_SELL )   continue;
                     ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(currentSymbol,SYMBOL_ASK),(int)orderSlippageSetting,Red); 
                     
                   }
                 }
                 else
                 {
                   SendTradeOrder(currentSymbol,ORDER_TYPE_SELL,zoneRecoveryNextLots,SymbolInfoDouble(currentSymbol,SYMBOL_BID),(int)orderSlippageSetting,0.0,0.0,IntegerToString(orderTicket,0,32),zoneRecoveryBuyMagic,0,Green); 
                   buyZoneNextOrderSide = 1 ;
                   zoneRecoveryOrderPlaced = true ;
                 }
               }
             }
             else
             {
               zoneRecoveryReverseTriggerPrice = requestedEntryPrice ;
               if ( SymbolInfoDouble(currentSymbol,SYMBOL_ASK)>requestedEntryPrice )
               {
                 if ( zoneRecoveryOrderCount>=zoneRecoveryMaximumTrades )
                 {
                   for (zoneMaximumTradesCloseScanIndexB = ActiveTradeCount() ; zoneMaximumTradesCloseScanIndexB >= 0 ; zoneMaximumTradesCloseScanIndexB=zoneMaximumTradesCloseScanIndexB - 1)
                   {
                     if ( SelectTradeRecord(zoneMaximumTradesCloseScanIndexB,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true )   continue;
                     
                     if ( SelectedTradeMagic() == strategyMagicNumber && SelectedTradeTicket() == orderTicket )
                     {
                       ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(currentSymbol,SYMBOL_BID),3,Red); 
                     }
                     if ( SelectedTradeMagic() != zoneRecoveryBuyMagic )   continue;
                     zoneReverseOrderComment = SelectedTradeComment();
                     if ( zoneReverseOrderComment != IntegerToString(orderTicket,0,32) )   continue;
                     
                     if ( SelectedTradeType() == ORDER_TYPE_BUY )
                     {
                       ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(currentSymbol,SYMBOL_BID),(int)orderSlippageSetting,Red); 
                     }
                     if ( SelectedTradeType() != ORDER_TYPE_SELL )   continue;
                     ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(currentSymbol,SYMBOL_ASK),(int)orderSlippageSetting,Red); 
                     
                   }
                 }
                 else
                 {
                   SendTradeOrder(currentSymbol,ORDER_TYPE_BUY,zoneRecoveryNextLots,SymbolInfoDouble(currentSymbol,SYMBOL_ASK),(int)orderSlippageSetting,0.0,0.0,IntegerToString(orderTicket,0,32),zoneRecoveryBuyMagic,0,Green); 
                   buyZoneNextOrderSide = 0 ;
                   zoneRecoveryOrderPlaced = true ;
                 }
               }
             }
           }
         }
         if ( ( zoneRecoveryOrderCount>0.0 || zoneRecoveryOrderPlaced ) )
         {
           zoneRecoveryHandled = true ;
         }
       }
       if ( !(zoneRecoveryHandled) )
       {
         if ( ( tradeMonitorFilterMode == 1 || (tradeMonitorFilterMode != 3 && tradeMonitorFilterMode != 2) ) )
         {
           virtualStopTicketPrimary = orderTicket;
           virtualStopDistancePipsPrimary = stopLossPips;
           virtualStopOpenPricePrimary = openPrice;
           virtualStopDirectionPrimary = 1;
           storedVirtualStopPrimary = 0.0;
           virtualStopFoundPrimary = false;
           for (virtualStopLookupIndexPrimary = 0 ; virtualStopLookupIndexPrimary < smallBufferCapacity ; virtualStopLookupIndexPrimary=virtualStopLookupIndexPrimary + 1)
           {
             if ( virtualStopByTicket[virtualStopLookupIndexPrimary][0]==virtualStopTicketPrimary )
             {
               storedVirtualStopPrimary = virtualStopByTicket[virtualStopLookupIndexPrimary][1];
               virtualStopFoundPrimary = true;
               break;
             }
           }
           if ( !(virtualStopFoundPrimary) )
           {
             if ( virtualStopDirectionPrimary == 1 )
             {
               storedVirtualStopPrimary = NormalizeDouble(virtualStopOpenPricePrimary - virtualStopDistancePipsPrimary * pipSize,symbolDigits);
             }
             if ( virtualStopDirectionPrimary == 2 )
             {
               storedVirtualStopPrimary = NormalizeDouble(virtualStopDistancePipsPrimary * pipSize + virtualStopOpenPricePrimary,symbolDigits);
             }
             for (virtualStopInsertIndexPrimary = 0 ; virtualStopInsertIndexPrimary < smallBufferCapacity ; virtualStopInsertIndexPrimary=virtualStopInsertIndexPrimary + 1)
             {
               if ( virtualStopByTicket[virtualStopInsertIndexPrimary][0]==0.0 )
               {
                 virtualStopByTicket[virtualStopInsertIndexPrimary][0] = (double)virtualStopTicketPrimary;
                 virtualStopByTicket[virtualStopInsertIndexPrimary][1] = storedVirtualStopPrimary;
                 break;
               }
             }
           }
           activeVirtualStopPrice = storedVirtualStopPrimary ;
           originalStopLoss = activeVirtualStopPrice ;
           if ( SymbolInfoDouble(currentSymbol,SYMBOL_BID)<originalStopLoss )
           {
             Print("Closing with virtual SL"); 
             RefreshCurrentSymbolTick(); 
             ClosePositionByTicket(orderTicket,orderLots,SymbolInfoDouble(currentSymbol,SYMBOL_BID),(int)currentSpreadPrice,clrNONE); 
             return(true); 
           }
           if ( timeRecoveryAfterMinutes>0.0 && TimeCurrent() >= openTime + timeRecoveryDelaySeconds && SymbolInfoDouble(currentSymbol,SYMBOL_BID)>NormalizeDouble(timeRecoveryStopPips * pipSize + (stopLossPrice + symbolPoint),symbolDigits) && SymbolInfoDouble(currentSymbol,SYMBOL_BID)<takeProfitPrice - freezeLevelPriceDistance )
           {
             stopLossPrice = NormalizeDouble(SymbolInfoDouble(currentSymbol,SYMBOL_BID) - timeRecoveryStopPips * pipSize,symbolDigits) ;
             if ( stopLossPrice<SymbolInfoDouble(currentSymbol,SYMBOL_BID) - stopLevelPriceDistance )
             {
               lastTradeTicket = ModifyTradeByTicket(orderTicket,openPrice,stopLossPrice,takeProfitPrice,0,clrNONE) ;
               if ( lastTradeTicket <= 0 )
               {
                 Print("TrailStop error: \'" + TradeErrorDescription(LastTradeErrorCode()) + "\' when setting trailing Exit_TrailSL_after_X_Minutes_size loss.  Trying again!"); 
               }
               orderStateChanged = true ;
             }
           }
           if ( trailingSLStartPips>0.0 && SymbolInfoDouble(currentSymbol,SYMBOL_BID)>NormalizeDouble((trailingSLStartPips + trailingActivationBufferPips) * pipSize + (stopLossPrice + symbolPoint),symbolDigits) && SymbolInfoDouble(currentSymbol,SYMBOL_BID)>NormalizeDouble(trailingSLDistancePips * pipSize + trailReferencePrice,symbolDigits) && SymbolInfoDouble(currentSymbol,SYMBOL_BID)<takeProfitPrice - freezeLevelPriceDistance && stopLossPrice<NormalizeDouble(trailingSLStepLimitPips * pipSize + openPrice,symbolDigits) )
           {
             stopLossPrice = NormalizeDouble(SymbolInfoDouble(currentSymbol,SYMBOL_BID) - trailingSLStartPips * pipSize,symbolDigits) ;
             if ( stopLossPrice<SymbolInfoDouble(currentSymbol,SYMBOL_BID) - stopLevelPriceDistance )
             {
               lastTradeTicket = ModifyTradeByTicket(orderTicket,openPrice,stopLossPrice,takeProfitPrice,0,clrNONE) ;
               if ( lastTradeTicket <= 0 )
               {
                 Print("TrailStop error: \'" + TradeErrorDescription(LastTradeErrorCode()) + "\' when setting trailing Exit_stop loss.  Trying again!"); 
               }
               else
               {
                 partialCloseLots = NormalizeDouble(trailingPartialClosePercent / 100.0 * lotSizeByStrategy[currentStrategyIndex],2) ;
                 if ( partialCloseLots<orderLots && partialCloseLots>=SymbolInfoDouble(currentSymbol,SYMBOL_VOLUME_STEP) )
                 {
                   ClosePositionByTicket(orderTicket,partialCloseLots,SymbolInfoDouble(currentSymbol,SYMBOL_BID),(int)orderSlippageSetting,Red); 
                   return(true); 
                 }
               }
               orderStateChanged = true ;
             }
           }
           if ( trailingTPStartPips>0.0 && SymbolInfoDouble(currentSymbol,SYMBOL_ASK)<NormalizeDouble(takeProfitPrice - symbolPoint - trailingTPStartPips * pipSize,symbolDigits) && SymbolInfoDouble(currentSymbol,SYMBOL_ASK)<NormalizeDouble(trailReferencePrice - trailingTPDistancePips * pipSize,symbolDigits) && SymbolInfoDouble(currentSymbol,SYMBOL_BID)<takeProfitPrice - freezeLevelPriceDistance )
           {
             takeProfitPrice = NormalizeDouble(SymbolInfoDouble(currentSymbol,SYMBOL_BID) + trailingTPStartPips * pipSize,symbolDigits) ;
             if ( takeProfitPrice>SymbolInfoDouble(currentSymbol,SYMBOL_ASK) + stopLevelPriceDistance )
             {
               lastTradeTicket = ModifyTradeByTicket(orderTicket,openPrice,stopLossPrice,takeProfitPrice,0,clrNONE) ;
               if ( lastTradeTicket <= 0 )
               {
                 Print("TrailStop error: \'" + TradeErrorDescription(LastTradeErrorCode()) + "\' when setting trailing Exit_TP.  Trying again!"); 
               }
               else
               {
                 virtualStopPrice = NormalizeDouble(trailingPartialClosePercent / 100.0 * lotSizeByStrategy[currentStrategyIndex],2) ;
                 if ( virtualStopPrice<orderLots && virtualStopPrice>=SymbolInfoDouble(currentSymbol,SYMBOL_VOLUME_MIN) )
                 {
                   ClosePositionByTicket(orderTicket,virtualStopPrice,SymbolInfoDouble(currentSymbol,SYMBOL_BID),(int)orderSlippageSetting,Red); 
                   return(true); 
                 }
               }
               orderStateChanged = true ;
             }
           }
           if ( excessiveEntrySlippage && slippageControlMode == 1 && slippageRecoveryTrailDistancePips>0.0 && SymbolInfoDouble(currentSymbol,SYMBOL_BID)>NormalizeDouble(slippageRecoveryTrailDistancePips * pipSize + (stopLossPrice + symbolPoint),symbolDigits) && SymbolInfoDouble(currentSymbol,SYMBOL_BID)>NormalizeDouble(slippageRecoveryTriggerPips * pipSize + requestedEntryPrice,symbolDigits) && SymbolInfoDouble(currentSymbol,SYMBOL_BID)<takeProfitPrice - freezeLevelPriceDistance && stopLossPrice<NormalizeDouble(slippageRecoveryMaximumStopPips * pipSize + openPrice,symbolDigits) )
           {
             stopLossPrice = NormalizeDouble(SymbolInfoDouble(currentSymbol,SYMBOL_BID) - slippageRecoveryTrailDistancePips * pipSize,symbolDigits) ;
             if ( stopLossPrice<SymbolInfoDouble(currentSymbol,SYMBOL_BID) - stopLevelPriceDistance )
             {
               lastTradeTicket = ModifyTradeByTicket(orderTicket,openPrice,stopLossPrice,takeProfitPrice,0,clrNONE) ;
               if ( lastTradeTicket <= 0 )
               {
                 Print("TrailStop error: \'" + TradeErrorDescription(LastTradeErrorCode()) + "\' when setting Slip TL.  Trying again!"); 
               }
               else
               {
                 Print("Slippage control active"); 
               }
               orderStateChanged = true ;
             }
           }
           if ( highLowLeftBars >  0 && highLowRightBars >= 0 && UseHL_TrailingSL && sellTriggerPriceByStrategy[currentStrategyIndex]>NormalizeDouble(stopLossPrice + stopLevelPriceDistance + symbolPoint,symbolDigits) && sellTriggerPriceByStrategy[currentStrategyIndex]<SymbolInfoDouble(currentSymbol,SYMBOL_BID) - highLowLookbackBars * pipSize && ( sellTriggerPriceByStrategy[currentStrategyIndex]<openPrice || !(highLowTrailingEnabled) ) && sellTriggerPriceByStrategy[currentStrategyIndex]<NormalizeDouble(SymbolInfoDouble(currentSymbol,SYMBOL_BID) - highLowMinimumMarketGapPips * pipSize - stopLevelPriceDistance - symbolPoint,symbolDigits) && SymbolInfoDouble(currentSymbol,SYMBOL_BID)<takeProfitPrice - freezeLevelPriceDistance )
           {
             stopLossPrice = NormalizeDouble(sellTriggerPriceByStrategy[currentStrategyIndex],symbolDigits) ;
             if ( stopLossPrice<SymbolInfoDouble(currentSymbol,SYMBOL_BID) - stopLevelPriceDistance )
             {
               lastTradeTicket = ModifyTradeByTicket(orderTicket,openPrice,stopLossPrice,takeProfitPrice,0,clrNONE) ;
               if ( lastTradeTicket <= 0 )
               {
                 Print("error: \'" + TradeErrorDescription(LastTradeErrorCode()) + "\' when modifying stoploss"); 
               }
               orderStateChanged = true ;
             }
           }
           if ( breakEvenStartPips>0.0 && SymbolInfoDouble(currentSymbol,SYMBOL_BID)>NormalizeDouble(breakEvenStartPips * pipSize + openPrice,symbolDigits) && NormalizeDouble(breakEvenExtraPips * pipSize + openPrice,symbolDigits)>stopLossPrice + symbolPoint && SymbolInfoDouble(currentSymbol,SYMBOL_BID)>NormalizeDouble(breakEvenExtraPips * pipSize + openPrice + stopLevelPriceDistance,symbolDigits) && SymbolInfoDouble(currentSymbol,SYMBOL_BID)<takeProfitPrice - freezeLevelPriceDistance )
           {
             stopLossPrice = NormalizeDouble(breakEvenExtraPips * pipSize + openPrice,symbolDigits) ;
             if ( stopLossPrice<SymbolInfoDouble(currentSymbol,SYMBOL_BID) - stopLevelPriceDistance )
             {
               lastTradeTicket = ModifyTradeByTicket(orderTicket,openPrice,stopLossPrice,takeProfitPrice,0,clrNONE) ;
               if ( lastTradeTicket <= 0 )
               {
                 Print("error when setting breakeven: \'" + TradeErrorDescription(LastTradeErrorCode()) + "\' ..\'Exit_BE_start\' to close to \'Exit_BE_extra_pips\' ..trying again!"); 
               }
               orderStateChanged = true ;
             }
           }
           if ( !(orderStateChanged) && ( magicTrailMode == 1 || (magicTrailMode == 2 && magicTrailStepPips * pipSize + stopLossPrice<=magicTrailMode2SpreadBufferPips * pipSize + (trailReferencePrice + currentSpreadPrice)) ) )
           {
             magicTrailTickCounter ++;
             if ( SymbolInfoDouble(currentSymbol,SYMBOL_BID)>magicTrailStepPips * pipSize + stopLossPrice + stopLevelPriceDistance && SymbolInfoDouble(currentSymbol,SYMBOL_BID)<takeProfitPrice - freezeLevelPriceDistance && ( magicTrailActivationDistancePips==0.0 || SymbolInfoDouble(currentSymbol,SYMBOL_BID)>activeMagicTrailActivationPips * pipSize + trailReferencePrice ) && magicTrailTickCounter >= magicTrailMinimumTickCount && NormalizeDouble(magicTrailStepPips * pipSize + stopLossPrice,symbolDigits)>stopLossPrice )
             {
               magicTrailTickCounter = 0 ;
               stopLossPrice = NormalizeDouble(magicTrailStepPips * pipSize + stopLossPrice,symbolDigits) ;
               ModifyTradeByTicket(orderTicket,openPrice,stopLossPrice,takeProfitPrice,0,clrNONE); 
               orderStateChanged = true ;
             }
           }
           activeVirtualStopPrice = stopLossPrice ;
           if ( SymbolInfoDouble(currentSymbol,SYMBOL_BID)<stopLossPrice )
           {
             Print("Closing with virtual SL"); 
             RefreshCurrentSymbolTick(); 
             ClosePositionByTicket(orderTicket,orderLots,SymbolInfoDouble(currentSymbol,SYMBOL_BID),(int)currentSpreadPrice,clrNONE); 
             return(true); 
           }
           if ( NormalizeDouble(originalStopLoss,symbolDigits)!=NormalizeDouble(activeVirtualStopPrice,symbolDigits) )
           {
             updatedVirtualStopPrimary = NormalizeDouble(activeVirtualStopPrice,symbolDigits);
             virtualStopUpdateTicketPrimary = orderTicket;
             for (virtualStopUpdateIndexPrimary = 0 ; virtualStopUpdateIndexPrimary < smallBufferCapacity ; virtualStopUpdateIndexPrimary=virtualStopUpdateIndexPrimary + 1)
             {
               if ( virtualStopByTicket[virtualStopUpdateIndexPrimary][0]==virtualStopUpdateTicketPrimary )
               {
                 virtualStopByTicket[virtualStopUpdateIndexPrimary][1] = updatedVirtualStopPrimary;
                 break;
               }
             }
           }
           if ( orderStateChanged && returnAfterStopModification )
           {
             return(true); 
           }
         }
         if ( ( tradeMonitorFilterMode == 2 || tradeMonitorFilterMode == 3 ) )
         {
           virtualStopTicketSecondary = orderTicket;
           virtualStopDistancePipsSecondary = stopLossPips;
           virtualStopOpenPriceSecondary = openPrice;
           virtualStopDirectionSecondary = 1;
           storedVirtualStopSecondary = 0.0;
           virtualStopFoundSecondary = false;
           for (virtualStopLookupIndexSecondary = 0 ; virtualStopLookupIndexSecondary < smallBufferCapacity ; virtualStopLookupIndexSecondary=virtualStopLookupIndexSecondary + 1)
           {
             if ( virtualStopByTicket[virtualStopLookupIndexSecondary][0]==virtualStopTicketSecondary )
             {
               storedVirtualStopSecondary = virtualStopByTicket[virtualStopLookupIndexSecondary][1];
               virtualStopFoundSecondary = true;
               break;
             }
           }
           if ( !(virtualStopFoundSecondary) )
           {
             if ( virtualStopDirectionSecondary == 1 )
             {
               storedVirtualStopSecondary = NormalizeDouble(virtualStopOpenPriceSecondary - virtualStopDistancePipsSecondary * pipSize,symbolDigits);
             }
             if ( virtualStopDirectionSecondary == 2 )
             {
               storedVirtualStopSecondary = NormalizeDouble(virtualStopDistancePipsSecondary * pipSize + virtualStopOpenPriceSecondary,symbolDigits);
             }
             for (virtualStopInsertIndexSecondary = 0 ; virtualStopInsertIndexSecondary < smallBufferCapacity ; virtualStopInsertIndexSecondary=virtualStopInsertIndexSecondary + 1)
             {
               if ( virtualStopByTicket[virtualStopInsertIndexSecondary][0]==0.0 )
               {
                 virtualStopByTicket[virtualStopInsertIndexSecondary][0] = (double)virtualStopTicketSecondary;
                 virtualStopByTicket[virtualStopInsertIndexSecondary][1] = storedVirtualStopSecondary;
                 break;
               }
             }
           }
           activeVirtualStopPrice = storedVirtualStopSecondary ;
           originalStopLoss = activeVirtualStopPrice ;
           if ( SymbolInfoDouble(currentSymbol,SYMBOL_BID)<=originalStopLoss )
           {
             RefreshCurrentSymbolTick(); 
             ClosePositionByTicket(orderTicket,orderLots,SymbolInfoDouble(currentSymbol,SYMBOL_BID),(int)currentSpreadPrice,clrNONE); 
             return(true); 
           }
           virtualStopSyncElapsedSeconds = (int)(TimeCurrent() - lastVirtualStopSyncTime) ;
           if ( virtualStopSyncElapsedSeconds >= virtualStopSyncIntervalSeconds )
           {
             if ( NormalizeDouble(activeVirtualStopPrice,symbolDigits)>stopLossPrice + symbolPoint )
             {
               ModifyTradeByTicket(orderTicket,openPrice,NormalizeDouble(activeVirtualStopPrice,symbolDigits),takeProfitPrice,0,clrNONE); 
             }
             lastVirtualStopSyncTime = TimeCurrent() ;
           }
           if ( timeRecoveryAfterMinutes>0.0 && TimeCurrent() >= openTime + timeRecoveryDelaySeconds && SymbolInfoDouble(currentSymbol,SYMBOL_BID)>timeRecoveryStopPips * pipSize + (activeVirtualStopPrice + symbolPoint) && SymbolInfoDouble(currentSymbol,SYMBOL_BID)<takeProfitPrice - freezeLevelPriceDistance )
           {
             orderStateChanged = true ;
             activeVirtualStopPrice = SymbolInfoDouble(currentSymbol,SYMBOL_BID) - timeRecoveryStopPips * pipSize ;
           }
           if ( trailingSLStartPips>0.0 && SymbolInfoDouble(currentSymbol,SYMBOL_BID)>(trailingSLStartPips + trailingActivationBufferPips) * pipSize + (activeVirtualStopPrice + symbolPoint) && SymbolInfoDouble(currentSymbol,SYMBOL_BID)>trailingSLDistancePips * pipSize + trailReferencePrice && activeVirtualStopPrice<trailingSLStepLimitPips * pipSize + openPrice )
           {
             orderStateChanged = true ;
             activeVirtualStopPrice = SymbolInfoDouble(currentSymbol,SYMBOL_BID) - trailingSLStartPips * pipSize ;
             partialCloseLotsAfterTrail = NormalizeDouble(trailingPartialClosePercent / 100.0 * lotSizeByStrategy[currentStrategyIndex],2) ;
             if ( partialCloseLotsAfterTrail<orderLots && partialCloseLotsAfterTrail>=SymbolInfoDouble(currentSymbol,SYMBOL_VOLUME_STEP) )
             {
               ClosePositionByTicket(orderTicket,partialCloseLotsAfterTrail,SymbolInfoDouble(currentSymbol,SYMBOL_BID),(int)orderSlippageSetting,Red); 
               return(true); 
             }
           }
           if ( excessiveEntrySlippage && slippageControlMode == 1 && slippageRecoveryTrailDistancePips>0.0 && SymbolInfoDouble(currentSymbol,SYMBOL_BID)>slippageRecoveryTrailDistancePips * pipSize + (activeVirtualStopPrice + symbolPoint) && SymbolInfoDouble(currentSymbol,SYMBOL_BID)>slippageRecoveryTriggerPips * pipSize + requestedEntryPrice && SymbolInfoDouble(currentSymbol,SYMBOL_BID)<takeProfitPrice - freezeLevelPriceDistance && activeVirtualStopPrice<slippageRecoveryMaximumStopPips * pipSize + openPrice )
           {
             Print("Slippage control active"); 
             orderStateChanged = true ;
             activeVirtualStopPrice = SymbolInfoDouble(currentSymbol,SYMBOL_BID) - slippageRecoveryTrailDistancePips * pipSize ;
           }
           if ( highLowLeftBars >  0 && highLowRightBars >= 0 && sellTriggerPriceByStrategy[currentStrategyIndex]>activeVirtualStopPrice + stopLevelPriceDistance + symbolPoint && ( sellTriggerPriceByStrategy[currentStrategyIndex]<openPrice || !(highLowTrailingEnabled) ) && sellTriggerPriceByStrategy[currentStrategyIndex]<SymbolInfoDouble(currentSymbol,SYMBOL_BID) - highLowMinimumMarketGapPips * pipSize - stopLevelPriceDistance - symbolPoint && SymbolInfoDouble(currentSymbol,SYMBOL_BID)<takeProfitPrice - freezeLevelPriceDistance )
           {
             activeVirtualStopPrice = sellTriggerPriceByStrategy[currentStrategyIndex] ;
             orderStateChanged = true ;
           }
           if ( breakEvenStartPips>0.0 && tradeMonitorFilterMode == 3 && SymbolInfoDouble(currentSymbol,SYMBOL_BID)>breakEvenStartPips * pipSize + openPrice && breakEvenExtraPips * pipSize + openPrice>stopLossPrice + symbolPoint && SymbolInfoDouble(currentSymbol,SYMBOL_BID)>breakEvenExtraPips * pipSize + openPrice + stopLevelPriceDistance && SymbolInfoDouble(currentSymbol,SYMBOL_BID)<takeProfitPrice - freezeLevelPriceDistance && NormalizeDouble(breakEvenExtraPips * pipSize + openPrice,symbolDigits)>SelectedTradeStopLoss() )
           {
             activeVirtualStopPrice = NormalizeDouble(breakEvenExtraPips * pipSize + openPrice,symbolDigits) ;
             lastTradeTicket = ModifyTradeByTicket(orderTicket,openPrice,activeVirtualStopPrice,takeProfitPrice,0,clrNONE) ;
             if ( lastTradeTicket <= 0 )
             {
               Print("error when setting breakeven: \'" + TradeErrorDescription(LastTradeErrorCode()) + "\' ..\'Exit_BE_start\' to close to \'Exit_BE_extra_pips\' ..trying again!"); 
             }
             orderStateChanged = true ;
           }
           if ( breakEvenStartPips>0.0 && tradeMonitorFilterMode == 2 && SymbolInfoDouble(currentSymbol,SYMBOL_BID)>breakEvenStartPips * pipSize + openPrice && breakEvenExtraPips * pipSize + openPrice>activeVirtualStopPrice + symbolPoint && SymbolInfoDouble(currentSymbol,SYMBOL_BID)>breakEvenExtraPips * pipSize + openPrice + stopLevelPriceDistance && SymbolInfoDouble(currentSymbol,SYMBOL_BID)<takeProfitPrice - freezeLevelPriceDistance )
           {
             activeVirtualStopPrice = breakEvenExtraPips * pipSize + openPrice ;
             orderStateChanged = true ;
           }
           if ( !(orderStateChanged) && ( magicTrailMode == 1 || (magicTrailMode == 2 && magicTrailStepPips * pipSize + activeVirtualStopPrice<=magicTrailMode2SpreadBufferPips * pipSize + (trailReferencePrice + currentSpreadPrice)) ) )
           {
             magicTrailTickCounter ++;
             if ( SymbolInfoDouble(currentSymbol,SYMBOL_BID)>magicTrailStepPips * pipSize + activeVirtualStopPrice + stopLevelPriceDistance && SymbolInfoDouble(currentSymbol,SYMBOL_BID)<takeProfitPrice - freezeLevelPriceDistance && ( magicTrailActivationDistancePips==0.0 || SymbolInfoDouble(currentSymbol,SYMBOL_BID)>activeMagicTrailActivationPips * pipSize + trailReferencePrice ) && magicTrailTickCounter >= magicTrailMinimumTickCount )
             {
               magicTrailTickCounter = 0 ;
               activeVirtualStopPrice = magicTrailStepPips * pipSize + activeVirtualStopPrice ;
               orderStateChanged = true ;
             }
           }
           if ( SymbolInfoDouble(currentSymbol,SYMBOL_BID)<=activeVirtualStopPrice )
           {
             RefreshCurrentSymbolTick(); 
             ClosePositionByTicket(orderTicket,orderLots,SymbolInfoDouble(currentSymbol,SYMBOL_BID),(int)currentSpreadPrice,clrNONE); 
             return(true); 
           }
           if ( NormalizeDouble(originalStopLoss,symbolDigits)!=NormalizeDouble(activeVirtualStopPrice,symbolDigits) )
           {
             updatedVirtualStopSecondary = NormalizeDouble(activeVirtualStopPrice,symbolDigits);
             virtualStopUpdateTicketSecondary = orderTicket;
             for (virtualStopUpdateIndexSecondary = 0 ; virtualStopUpdateIndexSecondary < smallBufferCapacity ; virtualStopUpdateIndexSecondary=virtualStopUpdateIndexSecondary + 1)
             {
               if ( virtualStopByTicket[virtualStopUpdateIndexSecondary][0]==virtualStopUpdateTicketSecondary )
               {
                 virtualStopByTicket[virtualStopUpdateIndexSecondary][1] = updatedVirtualStopSecondary;
                 break;
               }
             }
           }
         }
       }
     }
     if ( orderStateChanged )
     {
       anyTradeChanged = true ;
     }
   }
   if ( orderStateChanged )
   {
     anyTradeChanged = true ;
   }
 }
 return(anyTradeChanged); 
 }
//ManageBuyTrades <<==--------   --------
 bool ManageSellTrades()
 {
  bool      orderStateChanged = false;
  bool      anyTradeChanged = false;
  double    originalStopLoss;
  double    trailReferencePrice;
  int       orderScanIndex;
  double    stopLossPrice;
  double    takeProfitPrice;
  long      orderTicket;
  double    openPrice;
  string    orderComment;
  double    orderLots;
  datetime  openTime;
  int       orderType;
  long       orderMagic;
  string    orderSymbol;
  double    requestedEntryPrice;
  double    entrySlippagePrice;
  bool      excessiveEntrySlippage;
  bool      zoneRecoveryHandled;
  double    zoneRecoveryOrderCount;
  bool      zoneRecoveryOrderPlaced;
  double    zoneRecoveryNextLots;
  double    zoneRecoveryTriggerPrice;
  double    zoneRecoveryReverseTriggerPrice;
  double    partialCloseLots;
  double    virtualStopPrice;
  int       virtualStopSyncElapsedSeconds;
  double    partialCloseLotsAfterTrail;
//----------------------------------------------------------------------
 int        priceDigits;
 long       entryTicketLookup;
 int        entryPriceMapIndex;
 double     mappedRequestedEntryPrice;
 double     openPriceForMap;
 long       ticketForMapInsert;
 int        ticketMapInsertIndex;
 long       zoneParentTicket;
 int        zoneOrderCount;
 int        zoneOrderScanIndex;
 string     zoneOrderComment;
 double     accountEquity;
 int        zoneCloseAllScanIndex;
 long       zoneProfitParentTicket;
 double     zoneCombinedProfit;
 int        zoneProfitScanIndex;
 long       zoneSelectedTicket;
 long       zoneCloseParentTicket;
 int        zoneCloseScanIndex;
 int        zoneMaximumTradesCloseScanIndexA;
 int        zoneMaximumTradesCloseScanIndexB;
 string     zoneReverseOrderComment;
 long       virtualStopTicketPrimary;
 double     virtualStopDistancePipsPrimary;
 double     virtualStopOpenPricePrimary;
 int        virtualStopDirectionPrimary;
 double     storedVirtualStopPrimary;
 bool       virtualStopFoundPrimary;
 int        virtualStopLookupIndexPrimary;
 int        virtualStopInsertIndexPrimary;
 double     updatedVirtualStopPrimary;
 long       virtualStopUpdateTicketPrimary;
 int        virtualStopUpdateIndexPrimary;
 long       virtualStopTicketSecondary;
 double     virtualStopDistancePipsSecondary;
 double     virtualStopOpenPriceSecondary;
 int        virtualStopDirectionSecondary;
 double     storedVirtualStopSecondary;
 bool       virtualStopFoundSecondary;
 int        virtualStopLookupIndexSecondary;
 int        virtualStopInsertIndexSecondary;
 double     updatedVirtualStopSecondary;
 long       virtualStopUpdateTicketSecondary;
 int        virtualStopUpdateIndexSecondary;

 originalStopLoss = 0.0 ;
 trailReferencePrice = 0.0 ;
 for (orderScanIndex = 0 ; orderScanIndex < ActiveTradeCount() ; orderScanIndex ++)
 {
   if ( SelectTradeRecord(orderScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) == true )
   {
     orderStateChanged = false ;
     stopLossPrice = NormalizeDouble(SelectedTradeStopLoss(),symbolDigits) ;
     takeProfitPrice = NormalizeDouble(SelectedTradeTakeProfit(),symbolDigits) ;
     orderTicket = SelectedTradeTicket() ;
     openPrice = NormalizeDouble(SelectedTradeOpenPrice(),symbolDigits) ;
     orderComment = SelectedTradeComment() ;
     orderLots = SelectedTradeVolume() ;
     openTime = SelectedTradeOpenTime() ;
     orderType = SelectedTradeType() ;
     orderMagic = SelectedTradeMagic() ;
     orderSymbol = SelectedTradeSymbol() ;
     if ( ( orderType == 5 || orderType == 3 ) && entryStrategyMode == 2 && ( manualTradeSymbolFilterMode == 0 || (manualTradeSymbolFilterMode == 1 && orderSymbol == currentSymbol) ) && ( orderMagic == manualStrategy2MagicNumber || manualStrategy2MagicNumber == 0 ) && ( orderComment == manualStrategy2Comment || manualStrategy2Comment == "" ) )
     {
       if ( ( stopLossPrice==0.0 || stopLossPrice==0.0 ) )
       {
         stopLossPrice = NormalizeDouble(stopLossPips * pipSize + openPrice,symbolDigits) ;
         ModifyTradeByTicket(orderTicket,openPrice,stopLossPrice,takeProfitPrice,0,Green); 
       }
       if ( ( takeProfitPrice==0.0 || takeProfitPrice==0.0 ) )
       {
         takeProfitPrice = NormalizeDouble(openPrice - takeProfitPips * pipSize,symbolDigits) ;
         ModifyTradeByTicket(orderTicket,openPrice,stopLossPrice,takeProfitPrice,0,Green); 
       }
     }
     if ( orderType == 1 && ( ( orderMagic == strategyMagicNumber && entryStrategyMode == 1 && orderSymbol == currentSymbol ) || (entryStrategyMode == 2 && ( manualTradeSymbolFilterMode == 0 || (manualTradeSymbolFilterMode == 1 && orderSymbol == currentSymbol) ) && ( orderMagic == manualStrategy2MagicNumber || manualStrategy2MagicNumber == 0 ) && (orderComment == manualStrategy2Comment || manualStrategy2Comment == "")) ) )
     {
       if ( ( stopLossPrice==0.0 || stopLossPrice==0.0 ) )
       {
         stopLossPrice = NormalizeDouble(stopLossPips * pipSize + openPrice,symbolDigits) ;
         ModifyTradeByTicket(orderTicket,openPrice,stopLossPrice,takeProfitPrice,0,Green); 
       }
       if ( ( takeProfitPrice==0.0 || takeProfitPrice==0.0 ) )
       {
         takeProfitPrice = NormalizeDouble(openPrice - takeProfitPips * pipSize,symbolDigits) ;
         ModifyTradeByTicket(orderTicket,openPrice,stopLossPrice,takeProfitPrice,0,Green); 
       }
       if ( candleExitM1Enabled && iTime(currentSymbol,NormalizeTimeframe(candleExitM1TimeframeMinutes),candleExitOpenBarShift) <= openTime && iTime(currentSymbol,NormalizeTimeframe(candleExitM1TimeframeMinutes),0) >  openTime && iClose(currentSymbol,NormalizeTimeframe(candleExitM1TimeframeMinutes),1)>iOpen(currentSymbol,NormalizeTimeframe(candleExitM1TimeframeMinutes),1) && iClose(currentSymbol,NormalizeTimeframe(candleExitM1TimeframeMinutes),1)>openPrice )
       {
         ClosePositionByTicket(orderTicket,orderLots,SymbolInfoDouble(currentSymbol,SYMBOL_ASK),0,Red); 
         Print("closing candle confirmation"); 
       }
       if ( candleExitM5Enabled && iTime(currentSymbol,NormalizeTimeframe(candleExitM5TimeframeMinutes),candleExitOpenBarShift) <= openTime && iTime(currentSymbol,NormalizeTimeframe(candleExitM5TimeframeMinutes),0) >  openTime && iClose(currentSymbol,NormalizeTimeframe(candleExitM5TimeframeMinutes),1)>iOpen(currentSymbol,NormalizeTimeframe(candleExitM5TimeframeMinutes),1) && iClose(currentSymbol,NormalizeTimeframe(candleExitM5TimeframeMinutes),1)>openPrice )
       {
         ClosePositionByTicket(orderTicket,orderLots,SymbolInfoDouble(currentSymbol,SYMBOL_ASK),0,Red); 
         Print("closing candle confirmation"); 
       }
       if ( candleExitM15Enabled && iTime(currentSymbol,NormalizeTimeframe(candleExitM15TimeframeMinutes),candleExitOpenBarShift) <= openTime && iTime(currentSymbol,NormalizeTimeframe(candleExitM15TimeframeMinutes),0) >  openTime && iClose(currentSymbol,NormalizeTimeframe(candleExitM15TimeframeMinutes),1)>iOpen(currentSymbol,NormalizeTimeframe(candleExitM15TimeframeMinutes),1) && iClose(currentSymbol,NormalizeTimeframe(candleExitM15TimeframeMinutes),1)>openPrice )
       {
         ClosePositionByTicket(orderTicket,orderLots,SymbolInfoDouble(currentSymbol,SYMBOL_ASK),0,Red); 
         Print("closing candle confirmation"); 
       }
       if ( candleExitM30Enabled && iTime(currentSymbol,NormalizeTimeframe(candleExitM30TimeframeMinutes),candleExitOpenBarShift) <= openTime && iTime(currentSymbol,NormalizeTimeframe(candleExitM30TimeframeMinutes),0) >  openTime && iClose(currentSymbol,NormalizeTimeframe(candleExitM30TimeframeMinutes),1)>iOpen(currentSymbol,NormalizeTimeframe(candleExitM30TimeframeMinutes),1) && iClose(currentSymbol,NormalizeTimeframe(candleExitM30TimeframeMinutes),1)>openPrice )
       {
         ClosePositionByTicket(orderTicket,orderLots,SymbolInfoDouble(currentSymbol,SYMBOL_ASK),0,Red); 
         Print("closing candle confirmation"); 
       }
       if ( candleExitH1Enabled && iTime(currentSymbol,NormalizeTimeframe(candleExitH1TimeframeMinutes),candleExitOpenBarShift) <= openTime && iTime(currentSymbol,NormalizeTimeframe(candleExitH1TimeframeMinutes),0) >  openTime && iClose(currentSymbol,NormalizeTimeframe(candleExitH1TimeframeMinutes),1)>iOpen(currentSymbol,NormalizeTimeframe(candleExitH1TimeframeMinutes),1) && iClose(currentSymbol,NormalizeTimeframe(candleExitH1TimeframeMinutes),1)>openPrice )
       {
         ClosePositionByTicket(orderTicket,orderLots,SymbolInfoDouble(currentSymbol,SYMBOL_ASK),0,Red); 
         Print("closing candle confirmation"); 
       }
       activeMagicTrailActivationPips = magicTrailActivationDistancePips ;
       if ( magicTrailDelayMinutes >  0 && TimeCurrent() >  openTime + magicTrailDelayMinutes * 60 )
       {
         activeMagicTrailActivationPips = magicTrailDelayedActivationPips ;
       }
       priceDigits = symbolDigits;
       entryTicketLookup = orderTicket;
       for (entryPriceMapIndex = 0 ; entryPriceMapIndex < 100 ; entryPriceMapIndex=entryPriceMapIndex + 1)
       {
         if ( !(pendingTicketPriceMap[entryPriceMapIndex][0]==entryTicketLookup) )   continue;
         mappedRequestedEntryPrice = pendingTicketPriceMap[entryPriceMapIndex][1];
         break;
         
       }
       mappedRequestedEntryPrice = 0.0;
       requestedEntryPrice = NormalizeDouble(mappedRequestedEntryPrice,priceDigits) ;
       if ( requestedEntryPrice==0.0 )
       {
         openPriceForMap = openPrice;
         ticketForMapInsert = orderTicket;
         for (ticketMapInsertIndex = 0 ; ticketMapInsertIndex < 100 ; ticketMapInsertIndex=ticketMapInsertIndex + 1)
         {
           if ( !(pendingTicketPriceMap[ticketMapInsertIndex][0]==0.0) )   continue;
           pendingTicketPriceMap[ticketMapInsertIndex][0] = (double)ticketForMapInsert;
           pendingTicketPriceMap[ticketMapInsertIndex][1] = openPriceForMap;
           break;
           
         }
         requestedEntryPrice = openPrice ;
       }
       else
       {
         requestedEntryPrice = requestedEntryPrice - requestedEntryAdjustmentPips * pipSize ;
       }
       entrySlippagePrice = requestedEntryPrice - openPrice ;
       excessiveEntrySlippage = false ;
       if ( requestedEntryPrice>requestedEntryAdjustmentPips * pipSize && entrySlippagePrice>orderSlippageSetting * pipSize )
       {
         excessiveEntrySlippage = true ;
         if ( slippageControlMode == 2 )
         {
           activeMagicTrailActivationPips = -1000.0 ;
           Print("Slippage Mode 2 active"); 
         }
       }
       if ( useRequestedEntryAsTrailReference )
       {
         trailReferencePrice = requestedEntryPrice ;
       }
       else
       {
         trailReferencePrice = openPrice ;
       }
       if ( stopLossPrice>NormalizeDouble((stopLossPips + extraStopLossPips) * pipSize + openPrice + currentSpreadPrice,symbolDigits) )
       {
         stopLossPrice = NormalizeDouble((stopLossPips + extraStopLossPips) * pipSize + openPrice + currentSpreadPrice,symbolDigits) ;
         ModifyTradeByTicket(orderTicket,openPrice,stopLossPrice,takeProfitPrice,0,clrNONE); 
       }
       if ( SymbolInfoDouble(currentSymbol,SYMBOL_ASK)>(stopLossPips + extraStopLossPips) * pipSize + openPrice + currentSpreadPrice )
       {
         RefreshCurrentSymbolTick(); 
         ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(currentSymbol,SYMBOL_ASK),(int)currentSpreadPrice,Red); 
         return(true); 
       }
       zoneRecoveryHandled = false ;
       if ( zoneRecoveryEnabled )
       {
         zoneParentTicket = orderTicket;
         zoneOrderCount = 0;
         for (zoneOrderScanIndex = ActiveTradeCount() ; zoneOrderScanIndex >= 0 ; zoneOrderScanIndex=zoneOrderScanIndex - 1)
         {
           if ( SelectTradeRecord(zoneOrderScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != zoneRecoverySellMagic || SelectedTradeSymbol() != currentSymbol )   continue;
           zoneOrderComment = SelectedTradeComment();
           if ( zoneOrderComment != IntegerToString(zoneParentTicket,0,32) )   continue;
           zoneOrderCount=zoneOrderCount + 1;
           
         }
         zoneRecoveryOrderCount = zoneOrderCount ;
         zoneRecoveryOrderPlaced = false ;
         if ( !(sellZoneStateInitialized) )
         {
           sellZoneStateInitialized = true ;
           sellZoneNextOrderSide = 1 ;
         }
         if ( zoneRecoveryOrderCount==0.0 )
         {
           sellZoneNextOrderSide = 1 ;
         }
         if ( MathFloor(zoneRecoveryOrderCount / 2.0)==zoneRecoveryOrderCount / 2.0 )
         {
           sellZoneNextOrderSide = 1 ;
         }
         else
         {
           sellZoneNextOrderSide = 0 ;
         }
         if ( sellZoneStateInitialized )
         {
           if ( zoneRecoveryOrderCount>0.0 )
           {
             accountEquity = AccountInfoDouble(ACCOUNT_EQUITY);
             if ( accountEquity>AccountInfoDouble(ACCOUNT_BALANCE) + zoneRecoveryProfitTarget )
             {
               for (zoneCloseAllScanIndex = ActiveTradeCount() ; zoneCloseAllScanIndex >= 0 ; zoneCloseAllScanIndex=zoneCloseAllScanIndex - 1)
               {
                 if ( SelectTradeRecord(zoneCloseAllScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true )   continue;
                 
                 if ( ( SelectedTradeMagic() != strategyMagicNumber && SelectedTradeMagic() != zoneRecoverySellMagic && SelectedTradeMagic() != zoneRecoveryBuyMagic ) )   continue;
                 
                 if ( SelectedTradeType() == ORDER_TYPE_BUY )
                 {
                   ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(currentSymbol,SYMBOL_BID),(int)orderSlippageSetting,Red); 
                 }
                 if ( SelectedTradeType() != ORDER_TYPE_SELL )   continue;
                 ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(currentSymbol,SYMBOL_ASK),(int)orderSlippageSetting,Red); 
                 
               }
             }
           }
           if ( zoneRecoveryOrderCount>0.0 )
           {
             zoneProfitParentTicket = orderTicket;
             zoneCombinedProfit = 0.0;
             for (zoneProfitScanIndex = ActiveTradeCount() ; zoneProfitScanIndex >= 0 ; zoneProfitScanIndex=zoneProfitScanIndex - 1)
             {
               if ( SelectTradeRecord(zoneProfitScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true )   continue;
               zoneSelectedTicket = SelectedTradeTicket();
               if ( zoneSelectedTicket != zoneProfitParentTicket )
               {
                 zoneOrderComment = SelectedTradeComment();
               if ( zoneOrderComment != IntegerToString(zoneProfitParentTicket,0,32) )   continue;
               }
               zoneCombinedProfit = zoneCombinedProfit + SelectedTradeProfit();
               
             }
             if ( zoneCombinedProfit>zoneRecoveryProfitTarget )
             {
               Print("Closing zone"); 
               zoneCloseParentTicket = orderTicket;
               for (zoneCloseScanIndex = ActiveTradeCount() ; zoneCloseScanIndex >= 0 ; zoneCloseScanIndex=zoneCloseScanIndex - 1)
               {
                 if ( SelectTradeRecord(zoneCloseScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true )   continue;
                 
                 if ( SelectedTradeMagic() == strategyMagicNumber && SelectedTradeTicket() == zoneCloseParentTicket )
                 {
                   ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(currentSymbol,SYMBOL_ASK),3,Red); 
                 }
                 if ( SelectedTradeMagic() != zoneRecoverySellMagic )   continue;
                 zoneOrderComment = SelectedTradeComment();
                 if ( zoneOrderComment != IntegerToString(zoneCloseParentTicket,0,32) )   continue;
                 
                 if ( SelectedTradeType() == ORDER_TYPE_BUY )
                 {
                   ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(currentSymbol,SYMBOL_BID),(int)orderSlippageSetting,Red); 
                 }
                 if ( SelectedTradeType() != ORDER_TYPE_SELL )   continue;
                 ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(currentSymbol,SYMBOL_ASK),(int)orderSlippageSetting,Red); 
                 
               }
               sellZoneStateInitialized = false ;
               zoneRecoveryHandled = true ;
             }
           }
           else
           {
             zoneRecoveryNextLots = orderLots * zoneRecoveryLotMultiplier ;
             if ( zoneRecoveryLotSizingMode == 2 )
             {
               zoneRecoveryNextLots = (zoneRecoveryOrderCount + 1.0) * orderLots + orderLots ;
             }
             if ( zoneRecoveryLotSizingMode == 3 )
             {
               zoneRecoveryNextLots = orderLots * (MathPow(zoneRecoveryLotMultiplier,zoneRecoveryOrderCount + 1.0)) ;
             }
             if ( sellZoneNextOrderSide == 0 )
             {
               zoneRecoveryTriggerPrice = requestedEntryPrice ;
               if ( SymbolInfoDouble(currentSymbol,SYMBOL_BID)<requestedEntryPrice )
               {
                 if ( zoneRecoveryOrderCount>=zoneRecoveryMaximumTrades )
                 {
                   for (zoneMaximumTradesCloseScanIndexA = ActiveTradeCount() ; zoneMaximumTradesCloseScanIndexA >= 0 ; zoneMaximumTradesCloseScanIndexA=zoneMaximumTradesCloseScanIndexA - 1)
                   {
                     if ( SelectTradeRecord(zoneMaximumTradesCloseScanIndexA,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true )   continue;
                     
                     if ( SelectedTradeMagic() == strategyMagicNumber && SelectedTradeTicket() == orderTicket )
                     {
                       ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(currentSymbol,SYMBOL_ASK),3,Red); 
                     }
                     if ( SelectedTradeMagic() != zoneRecoverySellMagic )   continue;
                     zoneOrderComment = SelectedTradeComment();
                     if ( zoneOrderComment != IntegerToString(orderTicket,0,32) )   continue;
                     
                     if ( SelectedTradeType() == ORDER_TYPE_BUY )
                     {
                       ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(currentSymbol,SYMBOL_BID),(int)orderSlippageSetting,Red); 
                     }
                     if ( SelectedTradeType() != ORDER_TYPE_SELL )   continue;
                     ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(currentSymbol,SYMBOL_ASK),(int)orderSlippageSetting,Red); 
                     
                   }
                 }
                 else
                 {
                   SendTradeOrder(currentSymbol,ORDER_TYPE_SELL,zoneRecoveryNextLots,SymbolInfoDouble(currentSymbol,SYMBOL_BID),(int)orderSlippageSetting,0.0,0.0,IntegerToString(orderTicket,0,32),zoneRecoverySellMagic,0,Green); 
                   sellZoneNextOrderSide = 1 ;
                   zoneRecoveryOrderPlaced = true ;
                 }
               }
             }
             else
             {
               zoneRecoveryReverseTriggerPrice = zoneRecoveryInitialDistancePips * pipSize + requestedEntryPrice - zoneRecoveryOrderCount * zoneRecoveryStepDistancePips * pipSize ;
               if ( zoneRecoveryReverseTriggerPrice<zoneRecoveryMinimumDistancePips * pipSize + requestedEntryPrice )
               {
                 zoneRecoveryReverseTriggerPrice = zoneRecoveryMinimumDistancePips * pipSize + requestedEntryPrice ;
               }
               if ( SymbolInfoDouble(currentSymbol,SYMBOL_ASK)>zoneRecoveryReverseTriggerPrice )
               {
                 if ( zoneRecoveryOrderCount>=zoneRecoveryMaximumTrades )
                 {
                   for (zoneMaximumTradesCloseScanIndexB = ActiveTradeCount() ; zoneMaximumTradesCloseScanIndexB >= 0 ; zoneMaximumTradesCloseScanIndexB=zoneMaximumTradesCloseScanIndexB - 1)
                   {
                     if ( SelectTradeRecord(zoneMaximumTradesCloseScanIndexB,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true )   continue;
                     
                     if ( SelectedTradeMagic() == strategyMagicNumber && SelectedTradeTicket() == orderTicket )
                     {
                       ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(currentSymbol,SYMBOL_ASK),3,Red); 
                     }
                     if ( SelectedTradeMagic() != zoneRecoverySellMagic )   continue;
                     zoneReverseOrderComment = SelectedTradeComment();
                     if ( zoneReverseOrderComment != IntegerToString(orderTicket,0,32) )   continue;
                     
                     if ( SelectedTradeType() == ORDER_TYPE_BUY )
                     {
                       ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(currentSymbol,SYMBOL_BID),(int)orderSlippageSetting,Red); 
                     }
                     if ( SelectedTradeType() != ORDER_TYPE_SELL )   continue;
                     ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(currentSymbol,SYMBOL_ASK),(int)orderSlippageSetting,Red); 
                     
                   }
                 }
                 else
                 {
                   SendTradeOrder(currentSymbol,ORDER_TYPE_BUY,zoneRecoveryNextLots,SymbolInfoDouble(currentSymbol,SYMBOL_ASK),(int)orderSlippageSetting,0.0,0.0,IntegerToString(orderTicket,0,32),zoneRecoverySellMagic,0,Green); 
                   sellZoneNextOrderSide = 0 ;
                   zoneRecoveryOrderPlaced = true ;
                 }
               }
             }
           }
         }
         if ( ( zoneRecoveryOrderCount>0.0 || zoneRecoveryOrderPlaced ) )
         {
           zoneRecoveryHandled = true ;
         }
       }
       if ( !(zoneRecoveryHandled) )
       {
         if ( ( tradeMonitorFilterMode == 1 || (tradeMonitorFilterMode != 2 && tradeMonitorFilterMode != 3) ) )
         {
           virtualStopTicketPrimary = orderTicket;
           virtualStopDistancePipsPrimary = stopLossPips;
           virtualStopOpenPricePrimary = openPrice;
           virtualStopDirectionPrimary = 2;
           storedVirtualStopPrimary = 0.0;
           virtualStopFoundPrimary = false;
           for (virtualStopLookupIndexPrimary = 0 ; virtualStopLookupIndexPrimary < smallBufferCapacity ; virtualStopLookupIndexPrimary=virtualStopLookupIndexPrimary + 1)
           {
             if ( virtualStopByTicket[virtualStopLookupIndexPrimary][0]==virtualStopTicketPrimary )
             {
               storedVirtualStopPrimary = virtualStopByTicket[virtualStopLookupIndexPrimary][1];
               virtualStopFoundPrimary = true;
               break;
             }
           }
           if ( !(virtualStopFoundPrimary) )
           {
             if ( virtualStopDirectionPrimary == 1 )
             {
               storedVirtualStopPrimary = NormalizeDouble(virtualStopOpenPricePrimary - virtualStopDistancePipsPrimary * pipSize,symbolDigits);
             }
             if ( virtualStopDirectionPrimary == 2 )
             {
               storedVirtualStopPrimary = NormalizeDouble(virtualStopDistancePipsPrimary * pipSize + virtualStopOpenPricePrimary,symbolDigits);
             }
             for (virtualStopInsertIndexPrimary = 0 ; virtualStopInsertIndexPrimary < smallBufferCapacity ; virtualStopInsertIndexPrimary=virtualStopInsertIndexPrimary + 1)
             {
               if ( virtualStopByTicket[virtualStopInsertIndexPrimary][0]==0.0 )
               {
                 virtualStopByTicket[virtualStopInsertIndexPrimary][0] = (double)virtualStopTicketPrimary;
                 virtualStopByTicket[virtualStopInsertIndexPrimary][1] = storedVirtualStopPrimary;
                 break;
               }
             }
           }
           activeVirtualStopPrice = storedVirtualStopPrimary ;
           originalStopLoss = activeVirtualStopPrice ;
           if ( SymbolInfoDouble(currentSymbol,SYMBOL_ASK)>originalStopLoss )
           {
             Print("Closing with virtual SL"); 
             RefreshCurrentSymbolTick(); 
             ClosePositionByTicket(orderTicket,orderLots,SymbolInfoDouble(currentSymbol,SYMBOL_ASK),(int)currentSpreadPrice,clrNONE); 
             return(true); 
           }
           if ( timeRecoveryAfterMinutes>0.0 && TimeCurrent() >= openTime + timeRecoveryDelaySeconds && SymbolInfoDouble(currentSymbol,SYMBOL_ASK)<stopLossPrice - symbolPoint - timeRecoveryStopPips * pipSize && SymbolInfoDouble(currentSymbol,SYMBOL_ASK)>takeProfitPrice + freezeLevelPriceDistance && NormalizeDouble(SymbolInfoDouble(currentSymbol,SYMBOL_ASK) + timeRecoveryStopPips * pipSize,symbolDigits)<stopLossPrice )
           {
             stopLossPrice = NormalizeDouble(SymbolInfoDouble(currentSymbol,SYMBOL_ASK) + timeRecoveryStopPips * pipSize,symbolDigits) ;
             if ( stopLossPrice>SymbolInfoDouble(currentSymbol,SYMBOL_ASK) + stopLevelPriceDistance )
             {
               lastTradeTicket = ModifyTradeByTicket(orderTicket,openPrice,stopLossPrice,takeProfitPrice,0,clrNONE) ;
               if ( lastTradeTicket <= 0 )
               {
                 Print("TrailStop error: \'" + TradeErrorDescription(LastTradeErrorCode()) + "\' when setting trailing Exit_TrailSL_after_X_Minutes_size loss.  Trying again!"); 
               }
               orderStateChanged = true ;
             }
           }
           if ( trailingSLStartPips>0.0 && SymbolInfoDouble(currentSymbol,SYMBOL_ASK)<stopLossPrice - symbolPoint - (trailingSLStartPips + trailingActivationBufferPips) * pipSize && SymbolInfoDouble(currentSymbol,SYMBOL_ASK)<trailReferencePrice - trailingSLDistancePips * pipSize && SymbolInfoDouble(currentSymbol,SYMBOL_ASK)>takeProfitPrice + freezeLevelPriceDistance && stopLossPrice>openPrice - trailingSLStepLimitPips * pipSize && NormalizeDouble(trailingSLStartPips * pipSize + SymbolInfoDouble(currentSymbol,SYMBOL_ASK),symbolDigits)<stopLossPrice )
           {
             stopLossPrice = NormalizeDouble(SymbolInfoDouble(currentSymbol,SYMBOL_ASK) + trailingSLStartPips * pipSize,symbolDigits) ;
             if ( stopLossPrice>SymbolInfoDouble(currentSymbol,SYMBOL_ASK) + stopLevelPriceDistance )
             {
               lastTradeTicket = ModifyTradeByTicket(orderTicket,openPrice,stopLossPrice,takeProfitPrice,0,clrNONE) ;
               if ( lastTradeTicket <= 0 )
               {
                 Print("TrailStop error: \'" + TradeErrorDescription(LastTradeErrorCode()) + "\' when setting trailing Exit_stop loss.  Trying again!"); 
               }
               else
               {
                 partialCloseLots = NormalizeDouble(trailingPartialClosePercent / 100.0 * lotSizeByStrategy[currentStrategyIndex],2) ;
                 if ( partialCloseLots<orderLots && partialCloseLots>=SymbolInfoDouble(currentSymbol,SYMBOL_VOLUME_STEP) )
                 {
                   ClosePositionByTicket(orderTicket,partialCloseLots,SymbolInfoDouble(currentSymbol,SYMBOL_ASK),(int)orderSlippageSetting,Red); 
                   return(true); 
                 }
               }
               orderStateChanged = true ;
             }
           }
           if ( trailingTPStartPips>0.0 && SymbolInfoDouble(currentSymbol,SYMBOL_BID)>NormalizeDouble(trailingTPStartPips * pipSize + (takeProfitPrice + symbolPoint),symbolDigits) && SymbolInfoDouble(currentSymbol,SYMBOL_BID)>NormalizeDouble(trailingTPDistancePips * pipSize + trailReferencePrice,symbolDigits) && SymbolInfoDouble(currentSymbol,SYMBOL_BID)>takeProfitPrice + freezeLevelPriceDistance )
           {
             takeProfitPrice = NormalizeDouble(SymbolInfoDouble(currentSymbol,SYMBOL_BID) - trailingTPStartPips * pipSize,symbolDigits) ;
             if ( takeProfitPrice<SymbolInfoDouble(currentSymbol,SYMBOL_BID) - stopLevelPriceDistance )
             {
               lastTradeTicket = ModifyTradeByTicket(orderTicket,openPrice,stopLossPrice,takeProfitPrice,0,clrNONE) ;
               if ( lastTradeTicket <= 0 )
               {
                 Print("TrailStop error: \'" + TradeErrorDescription(LastTradeErrorCode()) + "\' when setting trailing Exit_TP.  Trying again!"); 
               }
               else
               {
                 virtualStopPrice = NormalizeDouble(trailingPartialClosePercent / 100.0 * lotSizeByStrategy[currentStrategyIndex],2) ;
                 if ( virtualStopPrice<orderLots && virtualStopPrice>=SymbolInfoDouble(currentSymbol,SYMBOL_VOLUME_MIN) )
                 {
                   ClosePositionByTicket(orderTicket,virtualStopPrice,SymbolInfoDouble(currentSymbol,SYMBOL_ASK),(int)orderSlippageSetting,Red); 
                   return(true); 
                 }
               }
               orderStateChanged = true ;
             }
           }
           if ( excessiveEntrySlippage && slippageControlMode == 1 && slippageRecoveryTrailDistancePips>0.0 && SymbolInfoDouble(currentSymbol,SYMBOL_ASK)<stopLossPrice - symbolPoint - slippageRecoveryTrailDistancePips * pipSize && SymbolInfoDouble(currentSymbol,SYMBOL_ASK)<requestedEntryPrice - slippageRecoveryTriggerPips * pipSize && SymbolInfoDouble(currentSymbol,SYMBOL_ASK)>takeProfitPrice + freezeLevelPriceDistance && stopLossPrice>openPrice - slippageRecoveryMaximumStopPips * pipSize && NormalizeDouble(SymbolInfoDouble(currentSymbol,SYMBOL_ASK) + slippageRecoveryTrailDistancePips * pipSize,symbolDigits)<stopLossPrice )
           {
             stopLossPrice = NormalizeDouble(SymbolInfoDouble(currentSymbol,SYMBOL_ASK) + slippageRecoveryTrailDistancePips * pipSize,symbolDigits) ;
             if ( stopLossPrice>SymbolInfoDouble(currentSymbol,SYMBOL_ASK) + stopLevelPriceDistance )
             {
               lastTradeTicket = ModifyTradeByTicket(orderTicket,openPrice,stopLossPrice,takeProfitPrice,0,clrNONE) ;
               if ( lastTradeTicket <= 0 )
               {
                 Print("TrailStop error: \'" + TradeErrorDescription(LastTradeErrorCode()) + "\' when setting Slip TL.  Trying again!"); 
               }
               else
               {
                 Print("Slippage controle active"); 
               }
               orderStateChanged = true ;
             }
           }
           if ( highLowLeftBars >  0 && highLowRightBars >= 0 && UseHL_TrailingSL && buyTriggerPriceByStrategy[currentStrategyIndex]<stopLossPrice - stopLevelPriceDistance - symbolPoint && buyTriggerPriceByStrategy[currentStrategyIndex]>highLowLookbackBars * pipSize + SymbolInfoDouble(currentSymbol,SYMBOL_ASK) && ( buyTriggerPriceByStrategy[currentStrategyIndex]>openPrice || !(highLowTrailingEnabled) ) && buyTriggerPriceByStrategy[currentStrategyIndex]>highLowMinimumMarketGapPips * pipSize + SymbolInfoDouble(currentSymbol,SYMBOL_ASK) + stopLevelPriceDistance + symbolPoint && SymbolInfoDouble(currentSymbol,SYMBOL_ASK)>takeProfitPrice + freezeLevelPriceDistance && NormalizeDouble(buyTriggerPriceByStrategy[currentStrategyIndex],symbolDigits)<stopLossPrice )
           {
             stopLossPrice = NormalizeDouble(buyTriggerPriceByStrategy[currentStrategyIndex],symbolDigits) ;
             if ( stopLossPrice>SymbolInfoDouble(currentSymbol,SYMBOL_ASK) + stopLevelPriceDistance )
             {
               lastTradeTicket = ModifyTradeByTicket(orderTicket,openPrice,stopLossPrice,takeProfitPrice,0,clrNONE) ;
               if ( lastTradeTicket <= 0 )
               {
                 Print("error: \'" + TradeErrorDescription(LastTradeErrorCode()) + "\' when modifying stoploss"); 
               }
               orderStateChanged = true ;
             }
           }
           if ( breakEvenStartPips>0.0 && SymbolInfoDouble(currentSymbol,SYMBOL_ASK)<openPrice - breakEvenStartPips * pipSize && openPrice - breakEvenExtraPips * pipSize<stopLossPrice - symbolPoint && SymbolInfoDouble(currentSymbol,SYMBOL_ASK)<openPrice - breakEvenExtraPips * pipSize - stopLevelPriceDistance && SymbolInfoDouble(currentSymbol,SYMBOL_ASK)>takeProfitPrice + freezeLevelPriceDistance && NormalizeDouble(openPrice - breakEvenExtraPips * pipSize,symbolDigits)<stopLossPrice )
           {
             stopLossPrice = NormalizeDouble(openPrice - breakEvenExtraPips * pipSize,symbolDigits) ;
             if ( stopLossPrice>SymbolInfoDouble(currentSymbol,SYMBOL_ASK) + stopLevelPriceDistance )
             {
               lastTradeTicket = ModifyTradeByTicket(orderTicket,openPrice,stopLossPrice,takeProfitPrice,0,clrNONE) ;
               if ( lastTradeTicket <= 0 )
               {
                 Print("error when setting breakeven: \'" + TradeErrorDescription(LastTradeErrorCode()) + "\' ..\'Exit_BE_start\' to close to \'Exit_BE_extra_pips\' ..trying again!"); 
               }
               orderStateChanged = true ;
             }
           }
           if ( !(orderStateChanged) && ( magicTrailMode == 1 || (magicTrailMode == 2 && stopLossPrice - magicTrailStepPips * pipSize>=trailReferencePrice - currentSpreadPrice - magicTrailMode2SpreadBufferPips * pipSize) ) )
           {
             magicTrailTickCounter ++;
             if ( SymbolInfoDouble(currentSymbol,SYMBOL_ASK)<stopLossPrice - magicTrailStepPips * pipSize - stopLevelPriceDistance && SymbolInfoDouble(currentSymbol,SYMBOL_ASK)>takeProfitPrice + freezeLevelPriceDistance && ( magicTrailActivationDistancePips==0.0 || SymbolInfoDouble(currentSymbol,SYMBOL_ASK)<trailReferencePrice - activeMagicTrailActivationPips * pipSize ) && magicTrailTickCounter >= magicTrailMinimumTickCount && NormalizeDouble(stopLossPrice - magicTrailStepPips * pipSize,symbolDigits)<stopLossPrice )
             {
               magicTrailTickCounter = 0 ;
               stopLossPrice = NormalizeDouble(stopLossPrice - magicTrailStepPips * pipSize,symbolDigits) ;
               ModifyTradeByTicket(orderTicket,openPrice,stopLossPrice,takeProfitPrice,0,clrNONE); 
               orderStateChanged = true ;
             }
           }
           activeVirtualStopPrice = stopLossPrice ;
           if ( SymbolInfoDouble(currentSymbol,SYMBOL_ASK)>stopLossPrice )
           {
             Print("Closing with virtual SL"); 
             RefreshCurrentSymbolTick(); 
             ClosePositionByTicket(orderTicket,orderLots,SymbolInfoDouble(currentSymbol,SYMBOL_ASK),(int)currentSpreadPrice,clrNONE); 
             return(true); 
           }
           if ( NormalizeDouble(originalStopLoss,symbolDigits)!=NormalizeDouble(activeVirtualStopPrice,symbolDigits) )
           {
             updatedVirtualStopPrimary = NormalizeDouble(activeVirtualStopPrice,symbolDigits);
             virtualStopUpdateTicketPrimary = orderTicket;
             for (virtualStopUpdateIndexPrimary = 0 ; virtualStopUpdateIndexPrimary < smallBufferCapacity ; virtualStopUpdateIndexPrimary=virtualStopUpdateIndexPrimary + 1)
             {
               if ( virtualStopByTicket[virtualStopUpdateIndexPrimary][0]==virtualStopUpdateTicketPrimary )
               {
                 virtualStopByTicket[virtualStopUpdateIndexPrimary][1] = updatedVirtualStopPrimary;
                 break;
               }
             }
           }
           if ( orderStateChanged && returnAfterStopModification )
           {
             return(true); 
           }
         }
         if ( ( tradeMonitorFilterMode == 2 || tradeMonitorFilterMode == 3 ) )
         {
           virtualStopTicketSecondary = orderTicket;
           virtualStopDistancePipsSecondary = stopLossPips;
           virtualStopOpenPriceSecondary = openPrice;
           virtualStopDirectionSecondary = 2;
           storedVirtualStopSecondary = 0.0;
           virtualStopFoundSecondary = false;
           for (virtualStopLookupIndexSecondary = 0 ; virtualStopLookupIndexSecondary < smallBufferCapacity ; virtualStopLookupIndexSecondary=virtualStopLookupIndexSecondary + 1)
           {
             if ( virtualStopByTicket[virtualStopLookupIndexSecondary][0]==virtualStopTicketSecondary )
             {
               storedVirtualStopSecondary = virtualStopByTicket[virtualStopLookupIndexSecondary][1];
               virtualStopFoundSecondary = true;
               break;
             }
           }
           if ( !(virtualStopFoundSecondary) )
           {
             if ( virtualStopDirectionSecondary == 1 )
             {
               storedVirtualStopSecondary = NormalizeDouble(virtualStopOpenPriceSecondary - virtualStopDistancePipsSecondary * pipSize,symbolDigits);
             }
             if ( virtualStopDirectionSecondary == 2 )
             {
               storedVirtualStopSecondary = NormalizeDouble(virtualStopDistancePipsSecondary * pipSize + virtualStopOpenPriceSecondary,symbolDigits);
             }
             for (virtualStopInsertIndexSecondary = 0 ; virtualStopInsertIndexSecondary < smallBufferCapacity ; virtualStopInsertIndexSecondary=virtualStopInsertIndexSecondary + 1)
             {
               if ( virtualStopByTicket[virtualStopInsertIndexSecondary][0]==0.0 )
               {
                 virtualStopByTicket[virtualStopInsertIndexSecondary][0] = (double)virtualStopTicketSecondary;
                 virtualStopByTicket[virtualStopInsertIndexSecondary][1] = storedVirtualStopSecondary;
                 break;
               }
             }
           }
           activeVirtualStopPrice = storedVirtualStopSecondary ;
           originalStopLoss = activeVirtualStopPrice ;
           if ( SymbolInfoDouble(currentSymbol,SYMBOL_ASK)>=originalStopLoss )
           {
             RefreshCurrentSymbolTick(); 
             ClosePositionByTicket(orderTicket,orderLots,SymbolInfoDouble(currentSymbol,SYMBOL_ASK),(int)currentSpreadPrice,clrNONE); 
             return(true); 
           }
           virtualStopSyncElapsedSeconds = (int)(TimeCurrent() - lastVirtualStopSyncTime) ;
           if ( virtualStopSyncElapsedSeconds >= virtualStopSyncIntervalSeconds )
           {
             if ( NormalizeDouble(activeVirtualStopPrice,symbolDigits)<stopLossPrice - symbolPoint )
             {
               ModifyTradeByTicket(orderTicket,openPrice,NormalizeDouble(activeVirtualStopPrice,symbolDigits),takeProfitPrice,0,clrNONE); 
             }
             lastVirtualStopSyncTime = TimeCurrent() ;
           }
           if ( timeRecoveryAfterMinutes>0.0 && TimeCurrent() >= openTime + timeRecoveryDelaySeconds && SymbolInfoDouble(currentSymbol,SYMBOL_ASK)<activeVirtualStopPrice - symbolPoint - timeRecoveryStopPips * pipSize && SymbolInfoDouble(currentSymbol,SYMBOL_ASK)>takeProfitPrice + freezeLevelPriceDistance )
           {
             activeVirtualStopPrice = SymbolInfoDouble(currentSymbol,SYMBOL_ASK) + timeRecoveryStopPips * pipSize ;
             orderStateChanged = true ;
           }
           if ( trailingSLStartPips>0.0 && SymbolInfoDouble(currentSymbol,SYMBOL_ASK)<activeVirtualStopPrice - symbolPoint - (trailingSLStartPips + trailingActivationBufferPips) * pipSize && SymbolInfoDouble(currentSymbol,SYMBOL_ASK)<trailReferencePrice - trailingSLDistancePips * pipSize && activeVirtualStopPrice>openPrice - trailingSLStepLimitPips * pipSize )
           {
             activeVirtualStopPrice = trailingSLStartPips * pipSize + SymbolInfoDouble(currentSymbol,SYMBOL_ASK) ;
             partialCloseLotsAfterTrail = NormalizeDouble(trailingPartialClosePercent / 100.0 * lotSizeByStrategy[currentStrategyIndex],2) ;
             if ( partialCloseLotsAfterTrail<orderLots && partialCloseLotsAfterTrail>=SymbolInfoDouble(currentSymbol,SYMBOL_VOLUME_STEP) )
             {
               ClosePositionByTicket(orderTicket,partialCloseLotsAfterTrail,SymbolInfoDouble(currentSymbol,SYMBOL_BID),(int)orderSlippageSetting,Red); 
               return(true); 
             }
             orderStateChanged = true ;
           }
           if ( excessiveEntrySlippage && slippageControlMode == 1 && slippageRecoveryTrailDistancePips>0.0 && SymbolInfoDouble(currentSymbol,SYMBOL_ASK)<activeVirtualStopPrice - symbolPoint - slippageRecoveryTrailDistancePips * pipSize && SymbolInfoDouble(currentSymbol,SYMBOL_ASK)<requestedEntryPrice - slippageRecoveryTriggerPips * pipSize && SymbolInfoDouble(currentSymbol,SYMBOL_ASK)>takeProfitPrice + freezeLevelPriceDistance && activeVirtualStopPrice>openPrice - slippageRecoveryMaximumStopPips * pipSize )
           {
             Print("Slippage controle active"); 
             orderStateChanged = true ;
             activeVirtualStopPrice = SymbolInfoDouble(currentSymbol,SYMBOL_ASK) + slippageRecoveryTrailDistancePips * pipSize ;
           }
           if ( highLowLeftBars >  0 && highLowRightBars >= 0 && buyTriggerPriceByStrategy[currentStrategyIndex]<activeVirtualStopPrice - stopLevelPriceDistance - symbolPoint && ( buyTriggerPriceByStrategy[currentStrategyIndex]>openPrice || !(highLowTrailingEnabled) ) && buyTriggerPriceByStrategy[currentStrategyIndex]>highLowMinimumMarketGapPips * pipSize + SymbolInfoDouble(currentSymbol,SYMBOL_ASK) + stopLevelPriceDistance + symbolPoint && SymbolInfoDouble(currentSymbol,SYMBOL_ASK)>takeProfitPrice + freezeLevelPriceDistance )
           {
             activeVirtualStopPrice = buyTriggerPriceByStrategy[currentStrategyIndex] ;
             orderStateChanged = true ;
           }
           if ( breakEvenStartPips>0.0 && tradeMonitorFilterMode == 3 && SymbolInfoDouble(currentSymbol,SYMBOL_ASK)<openPrice - breakEvenStartPips * pipSize && openPrice - breakEvenExtraPips * pipSize<stopLossPrice - symbolPoint && SymbolInfoDouble(currentSymbol,SYMBOL_ASK)<openPrice - breakEvenExtraPips * pipSize - stopLevelPriceDistance && SymbolInfoDouble(currentSymbol,SYMBOL_ASK)>takeProfitPrice + freezeLevelPriceDistance && NormalizeDouble(openPrice - breakEvenExtraPips * pipSize,symbolDigits)<activeVirtualStopPrice )
           {
             activeVirtualStopPrice = NormalizeDouble(openPrice - breakEvenExtraPips * pipSize,symbolDigits) ;
             lastTradeTicket = ModifyTradeByTicket(orderTicket,openPrice,activeVirtualStopPrice,takeProfitPrice,0,clrNONE) ;
             if ( lastTradeTicket <= 0 )
             {
               Print("error when setting breakeven: \'" + TradeErrorDescription(LastTradeErrorCode()) + "\' ..\'Exit_BE_start\' to close to \'Exit_BE_extra_pips\' ..trying again!"); 
             }
             orderStateChanged = true ;
           }
           if ( breakEvenStartPips>0.0 && tradeMonitorFilterMode == 2 && SymbolInfoDouble(currentSymbol,SYMBOL_ASK)<openPrice - breakEvenStartPips * pipSize && openPrice - breakEvenExtraPips * pipSize<activeVirtualStopPrice - symbolPoint && SymbolInfoDouble(currentSymbol,SYMBOL_ASK)<openPrice - breakEvenExtraPips * pipSize - stopLevelPriceDistance && SymbolInfoDouble(currentSymbol,SYMBOL_ASK)>takeProfitPrice + freezeLevelPriceDistance )
           {
             activeVirtualStopPrice = openPrice - breakEvenExtraPips * pipSize ;
             orderStateChanged = true ;
           }
           if ( !(orderStateChanged) && ( magicTrailMode == 1 || (magicTrailMode == 2 && activeVirtualStopPrice - magicTrailStepPips * pipSize>=trailReferencePrice - currentSpreadPrice - magicTrailMode2SpreadBufferPips * pipSize) ) )
           {
             magicTrailTickCounter ++;
             if ( SymbolInfoDouble(currentSymbol,SYMBOL_ASK)<activeVirtualStopPrice - magicTrailStepPips * pipSize - stopLevelPriceDistance && SymbolInfoDouble(currentSymbol,SYMBOL_ASK)>takeProfitPrice + freezeLevelPriceDistance && ( magicTrailActivationDistancePips==0.0 || SymbolInfoDouble(currentSymbol,SYMBOL_ASK)<trailReferencePrice - activeMagicTrailActivationPips * pipSize ) && magicTrailTickCounter >= magicTrailMinimumTickCount )
             {
               magicTrailTickCounter = 0 ;
               activeVirtualStopPrice = activeVirtualStopPrice - magicTrailStepPips * pipSize ;
               orderStateChanged = true ;
             }
           }
           if ( SymbolInfoDouble(currentSymbol,SYMBOL_ASK)>=activeVirtualStopPrice )
           {
             RefreshCurrentSymbolTick(); 
             ClosePositionByTicket(orderTicket,orderLots,SymbolInfoDouble(currentSymbol,SYMBOL_ASK),(int)currentSpreadPrice,clrNONE); 
             return(true); 
           }
           if ( NormalizeDouble(originalStopLoss,symbolDigits)!=NormalizeDouble(activeVirtualStopPrice,symbolDigits) )
           {
             updatedVirtualStopSecondary = NormalizeDouble(activeVirtualStopPrice,symbolDigits);
             virtualStopUpdateTicketSecondary = orderTicket;
             for (virtualStopUpdateIndexSecondary = 0 ; virtualStopUpdateIndexSecondary < smallBufferCapacity ; virtualStopUpdateIndexSecondary=virtualStopUpdateIndexSecondary + 1)
             {
               if ( virtualStopByTicket[virtualStopUpdateIndexSecondary][0]==virtualStopUpdateTicketSecondary )
               {
                 virtualStopByTicket[virtualStopUpdateIndexSecondary][1] = updatedVirtualStopSecondary;
                 break;
               }
             }
           }
         }
       }
     }
     if ( orderStateChanged )
     {
       anyTradeChanged = true ;
     }
   }
   if ( orderStateChanged )
   {
     anyTradeChanged = true ;
   }
 }
 return(anyTradeChanged); 
 }
//ManageSellTrades <<==--------   --------
 bool IsTradingSessionOpen()
 {
  bool      sessionOpen;
  datetime  referenceTime;
  int       referenceHour;
//----------------------------------------------------------------------
 bool       sundayOpen;
 bool       mondayOpen;
 bool       tuesdayOpen;
 bool       wednesdayOpen;
 bool       thursdayOpen;
 bool       fridayOpen;

 if ( !(tradingHoursEnabled) )
 {
   return(true); 
 }
 sessionOpen = false ;
 referenceTime = 0 ;
 if ( tradingHoursTimeSource == 2 )
 {
   referenceTime = TimeCurrent() ;
 }
 if ( tradingHoursTimeSource == 0 )
 {
   TimeGMT(); 
 }
 if ( tradingHoursTimeSource == 1 )
 {
   TimeLocal(); 
 }
 referenceHour = DateTimeHour(referenceTime) ;
 if ( DateTimeDayOfWeek(referenceTime) == 0 )
 {
   if ( sundayStartHour <  sundayEndHour && ( referenceHour < sundayStartHour || referenceHour >= sundayEndHour ) )
   {
     sundayOpen = false;
   }
   else
   {
     if ( sundayStartHour >  sundayEndHour && referenceHour <  sundayStartHour && referenceHour >= sundayEndHour )
     {
       sundayOpen = false;
     }
     else
     {
       if ( sundayStartHour == sundayEndHour )
       {
         sundayOpen = false;
       }
       else
       {
         sundayOpen = true;
       }
     }
   }
   if ( sundayOpen )
   {
     sessionOpen = true ;
   }
 }
 if ( DateTimeDayOfWeek(referenceTime) == 1 )
 {
   if ( mondayStartHour <  mondayEndHour && ( referenceHour < mondayStartHour || referenceHour >= mondayEndHour ) )
   {
     mondayOpen = false;
   }
   else
   {
     if ( mondayStartHour >  mondayEndHour && referenceHour <  mondayStartHour && referenceHour >= mondayEndHour )
     {
       mondayOpen = false;
     }
     else
     {
       if ( mondayStartHour == mondayEndHour )
       {
         mondayOpen = false;
       }
       else
       {
         mondayOpen = true;
       }
     }
   }
   if ( mondayOpen )
   {
     sessionOpen = true ;
   }
 }
 if ( DateTimeDayOfWeek(referenceTime) == 2 )
 {
   if ( tuesdayStartHour <  tuesdayEndHour && ( referenceHour < tuesdayStartHour || referenceHour >= tuesdayEndHour ) )
   {
     tuesdayOpen = false;
   }
   else
   {
     if ( tuesdayStartHour >  tuesdayEndHour && referenceHour <  tuesdayStartHour && referenceHour >= tuesdayEndHour )
     {
       tuesdayOpen = false;
     }
     else
     {
       if ( tuesdayStartHour == tuesdayEndHour )
       {
         tuesdayOpen = false;
       }
       else
       {
         tuesdayOpen = true;
       }
     }
   }
   if ( tuesdayOpen )
   {
     sessionOpen = true ;
   }
 }
 if ( DateTimeDayOfWeek(referenceTime) == 3 )
 {
   if ( wednesdayStartHour <  wednesdayEndHour && ( referenceHour < wednesdayStartHour || referenceHour >= wednesdayEndHour ) )
   {
     wednesdayOpen = false;
   }
   else
   {
     if ( wednesdayStartHour >  wednesdayEndHour && referenceHour <  wednesdayStartHour && referenceHour >= wednesdayEndHour )
     {
       wednesdayOpen = false;
     }
     else
     {
       if ( wednesdayStartHour == wednesdayEndHour )
       {
         wednesdayOpen = false;
       }
       else
       {
         wednesdayOpen = true;
       }
     }
   }
   if ( wednesdayOpen )
   {
     sessionOpen = true ;
   }
 }
 if ( DateTimeDayOfWeek(referenceTime) == 4 )
 {
   if ( thursdayStartHour <  thursdayEndHour && ( referenceHour < thursdayStartHour || referenceHour >= thursdayEndHour ) )
   {
     thursdayOpen = false;
   }
   else
   {
     if ( thursdayStartHour >  thursdayEndHour && referenceHour <  thursdayStartHour && referenceHour >= thursdayEndHour )
     {
       thursdayOpen = false;
     }
     else
     {
       if ( thursdayStartHour == thursdayEndHour )
       {
         thursdayOpen = false;
       }
       else
       {
         thursdayOpen = true;
       }
     }
   }
   if ( thursdayOpen )
   {
     sessionOpen = true ;
   }
 }
 if ( DateTimeDayOfWeek(referenceTime) == 5 )
 {
   if ( fridayStartHour <  fridayEndHour && ( referenceHour < fridayStartHour || referenceHour >= fridayEndHour ) )
   {
     fridayOpen = false;
   }
   else
   {
     if ( fridayStartHour >  fridayEndHour && referenceHour <  fridayStartHour && referenceHour >= fridayEndHour )
     {
       fridayOpen = false;
     }
     else
     {
       if ( fridayStartHour == fridayEndHour )
       {
         fridayOpen = false;
       }
       else
       {
         fridayOpen = true;
       }
     }
   }
   if ( fridayOpen )
   {
     sessionOpen = true ;
   }
 }
 return(sessionOpen); 
 }
//IsTradingSessionOpen <<==--------   --------
 string TradeErrorDescription( int errorCode)
 {
  string    description;
//----------------------------------------------------------------------

 errorDescriptionCallCount ++;
 switch(errorCode)
 {
   case 0 : case 1 :
   description = "no error" ;
     break;
   case 2 :
   description = "common error" ;
     break;
   case 3 :
   description = "invalid trade parameters" ;
     break;
   case 4 :
   description = "trade server is busy" ;
     break;
   case 5 :
   description = "old version of the client terminal" ;
     break;
   case 6 :
   description = "no connection with trade server" ;
     break;
   case 7 :
   description = "not enough rights" ;
     break;
   case 8 :
   description = "too frequent requests" ;
     break;
   case 9 :
   description = "malfunctional trade operation (never returned error)" ;
     break;
   case 64 :
   description = "account disabled" ;
     break;
   case 65 :
   description = "invalid account" ;
     break;
   case 128 :
   description = "trade timeout" ;
     break;
   case 129 :
   description = "invalid price" ;
     break;
   case 130 :
   description = "invalid stops" ;
     break;
   case 131 :
   description = "invalid trade volume" ;
     break;
   case 132 :
   description = "market is closed" ;
     break;
   case 133 :
   description = "trade is disabled" ;
     break;
   case 134 :
   description = "not enough money" ;
     break;
   case 135 :
   description = "price changed" ;
     break;
   case 136 :
   description = "off quotes" ;
     break;
   case 137 :
   description = "broker is busy (never returned error)" ;
     break;
   case 138 :
   description = "requote" ;
     break;
   case 139 :
   description = "order is locked" ;
     break;
   case 140 :
   description = "long positions only allowed" ;
     break;
   case 141 :
   description = "too many requests" ;
     break;
   case 145 :
   description = "modification denied because order too close to market" ;
     break;
   case 146 :
   description = "trade context is busy" ;
     break;
   case 147 :
   description = "expirations are denied by broker" ;
     break;
   case 148 :
   description = "amount of open and pending orders has reached the Exit_limit" ;
     break;
   case 149 :
   description = "hedging is prohibited" ;
     break;
   case 150 :
   description = "prohibited by FIFO rules" ;
     break;
   case 4000 :
   description = "no error (never generated code)" ;
     break;
   case 4001 :
   description = "wrong function pointer" ;
     break;
   case 4002 :
   description = "array index is out of range" ;
     break;
   case 4003 :
   description = "no memory for function call stack" ;
     break;
   case 4004 :
   description = "recursive stack overflow" ;
     break;
   case 4005 :
   description = "not enough stack for parameter" ;
     break;
   case 4006 :
   description = "no memory for parameter string" ;
     break;
   case 4007 :
   description = "no memory for temp string" ;
     break;
   case 4008 :
   description = "not initialized string" ;
     break;
   case 4009 :
   description = "not initialized string in array" ;
     break;
   case 4010 :
   description = "no memory for array\' string" ;
     break;
   case 4011 :
   description = "too long string" ;
     break;
   case 4012 :
   description = "remainder from zero divide" ;
     break;
   case 4013 :
   description = "zero divide" ;
     break;
   case 4014 :
   description = "unknown command" ;
     break;
   case 4015 :
   description = "wrong jump (never generated error)" ;
     break;
   case 4016 :
   description = "not initialized array" ;
     break;
   case 4017 :
   description = "dll calls are not allowed" ;
     break;
   case 4018 :
   description = "cannot load library" ;
     break;
   case 4019 :
   description = "cannot call function" ;
     break;
   case 4020 :
   description = "expert function calls are not allowed" ;
     break;
   case 4021 :
   description = "not enough memory for temp string returned from function" ;
     break;
   case 4022 :
   description = "system is busy (never generated error)" ;
     break;
   case 4050 :
   description = "invalid function parameters count" ;
     break;
   case 4051 :
   description = "invalid function parameter value" ;
     break;
   case 4052 :
   description = "string function internal error" ;
     break;
   case 4053 :
   description = "some array error" ;
     break;
   case 4054 :
   description = "incorrect series array using" ;
     break;
   case 4055 :
   description = "custom indicator error" ;
     break;
   case 4056 :
   description = "arrays are incompatible" ;
     break;
   case 4057 :
   description = "global variables processing error" ;
     break;
   case 4058 :
   description = "global variable not found" ;
     break;
   case 4059 :
   description = "function is not allowed in testing mode" ;
     break;
   case 4060 :
   description = "function is not confirmed" ;
     break;
   case 4061 :
   description = "send mail error" ;
     break;
   case 4062 :
   description = "string parameter expected" ;
     break;
   case 4063 :
   description = "integer parameter expected" ;
     break;
   case 4064 :
   description = "double parameter expected" ;
     break;
   case 4065 :
   description = "array as parameter expected" ;
     break;
   case 4066 :
   description = "requested history data in update state" ;
     break;
   case 4099 :
   description = "end of file" ;
     break;
   case 4100 :
   description = "some file error" ;
     break;
   case 4101 :
   description = "wrong file name" ;
     break;
   case 4102 :
   description = "too many opened files" ;
     break;
   case 4103 :
   description = "cannot open file" ;
     break;
   case 4104 :
   description = "incompatible access to a file" ;
     break;
   case 4105 :
   description = "no order selected" ;
     break;
   case 4106 :
   description = "unknown symbol" ;
     break;
   case 4107 :
   description = "invalid price parameter for trade function" ;
     break;
   case 4108 :
   description = "invalid ticket" ;
     break;
   case 4109 :
   description = "trade is not allowed in the expert properties" ;
     break;
   case 4110 :
   description = "longs are not allowed in the expert properties" ;
     break;
   case 4111 :
   description = "shorts are not allowed in the expert properties" ;
     break;
   case 4200 :
   description = "object is already exist" ;
     break;
   case 4201 :
   description = "unknown object property" ;
     break;
   case 4202 :
   description = "object is not exist" ;
     break;
   case 4203 :
   description = "unknown object type" ;
     break;
   case 4204 :
   description = "no object name" ;
     break;
   case 4205 :
   description = "object coordinates error" ;
     break;
   case 4206 :
   description = "no specified subwindow" ;
     break;
   default :
   description = "unknown error" ;
 }
 return(description);
 }
//TradeErrorDescription <<==--------   --------
 void ResizePendingOrderLots( bool forceResize)
 {
  double    resizeThresholdFactor;
  int       orderCount;
  int       orderScanIndex;
  double    buyStopLoss;
  long      oldBuyTicket;
  double    buyTakeProfit;
  double    buyOpenPrice;
  datetime  buyExpiration;
  string    buyComment;
  long      newBuyTicket; // ticket 64-bit
  double    sellStopLoss;
  long      oldSellTicket;
  double    sellTakeProfit;
  double    sellOpenPrice;
  datetime  sellExpiration;
  string    sellComment;
  long      newSellTicket; // ticket 64-bit
//----------------------------------------------------------------------
 long       mappedNewBuyTicket;
 long       mappedOldBuyTicket;
 int        buyTicketMapIndex;
 long       mappedNewSellTicket;
 long       mappedOldSellTicket;
 int        sellTicketMapIndex;

 resizeThresholdFactor = pendingLotResizeThresholdPercent / 100.0 + 1.0 ;
 if ( ( !(AccountInfoDouble(ACCOUNT_BALANCE)!=lastLotResizeBalance) && !(forceResize) ) )   return;
 
 if ( ( !(AccountInfoDouble(ACCOUNT_BALANCE)>lastLotResizeBalance * resizeThresholdFactor) && !(AccountInfoDouble(ACCOUNT_BALANCE)<lastLotResizeBalance / resizeThresholdFactor) && !(forceResize) ) )   return;
 CalculateStrategyLotSize(stopLossPips,lotSizePercentMultiplier); 
 orderCount = ActiveTradeCount() ;
 for (orderScanIndex = orderCount ; orderScanIndex >= 0 ; orderScanIndex --)
 {
   if ( SelectTradeRecord(orderScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != strategyMagicNumber || SelectedTradeSymbol() != currentSymbol )   continue;
   
   if ( SelectedTradeType() == ORDER_TYPE_BUY_STOP && SelectedTradeVolume()!=lotSizeByStrategy[currentStrategyIndex] )
   {
     buyStopLoss = SelectedTradeStopLoss() ;
     oldBuyTicket = SelectedTradeTicket() ;
     buyTakeProfit = SelectedTradeTakeProfit() ;
     buyOpenPrice = SelectedTradeOpenPrice() ;
     buyExpiration = SelectedTradeExpiration() ;
     buyComment = SelectedTradeComment() ;
     DeletePendingOrderByTicket(oldBuyTicket,Red); 
     newBuyTicket = SendTradeOrder(currentSymbol,ORDER_TYPE_BUY_STOP,lotSizeByStrategy[currentStrategyIndex],buyOpenPrice,(int)orderSlippageSetting,buyStopLoss,buyTakeProfit,buyComment,strategyMagicNumber,buyExpiration,Green) ;
     mappedNewBuyTicket = newBuyTicket;
     mappedOldBuyTicket = oldBuyTicket;
     for (buyTicketMapIndex = 0 ; buyTicketMapIndex < 100 ; buyTicketMapIndex=buyTicketMapIndex + 1)
     {
       if ( !(pendingTicketPriceMap[buyTicketMapIndex][0]==mappedOldBuyTicket) )   continue;
       pendingTicketPriceMap[buyTicketMapIndex][0] = (double)mappedNewBuyTicket;
       break;
       
     }
     Print("Lotsize changed more than " + string(pendingLotResizeThresholdPercent) + "%... adjusting lotsize of pending orders"); 
     Sleep(1000); 
   }
   if ( SelectedTradeType() != ORDER_TYPE_SELL_STOP || !(SelectedTradeVolume()!=lotSizeByStrategy[currentStrategyIndex]) )   continue;
   sellStopLoss = SelectedTradeStopLoss() ;
   oldSellTicket = SelectedTradeTicket() ;
   sellTakeProfit = SelectedTradeTakeProfit() ;
   sellOpenPrice = SelectedTradeOpenPrice() ;
   sellExpiration = SelectedTradeExpiration() ;
   sellComment = SelectedTradeComment() ;
   DeletePendingOrderByTicket(oldSellTicket,Red); 
   newSellTicket = SendTradeOrder(currentSymbol,ORDER_TYPE_SELL_STOP,lotSizeByStrategy[currentStrategyIndex],sellOpenPrice,(int)orderSlippageSetting,sellStopLoss,sellTakeProfit,sellComment,strategyMagicNumber,sellExpiration,Green) ;
   mappedNewSellTicket = newSellTicket;
   mappedOldSellTicket = oldSellTicket;
   for (sellTicketMapIndex = 0 ; sellTicketMapIndex < 100 ; sellTicketMapIndex=sellTicketMapIndex + 1)
   {
     if ( !(pendingTicketPriceMap[sellTicketMapIndex][0]==mappedOldSellTicket) )   continue;
     pendingTicketPriceMap[sellTicketMapIndex][0] = (double)mappedNewSellTicket;
     break;
     
   }
   Print("Lotsize changed more than " + string(pendingLotResizeThresholdPercent) + "%... adjusting lotsize of pending orders"); 
   Sleep(1000); 
   
 }
 }

 void CreateInfoPanel()
 {
  int       unusedPanelIntegerA = 0;
  int       unusedPanelIntegerB = 0;
  int       unusedPanelTitleOffset;
  int       unusedPanelBaseWidth;
  int       unusedPanelDefaultFontSize;
  double    unusedPanelScale;
  int       panelTextXPadding;
  int       panelTextYPadding;
  int       panelWidth;
  int       panelHeight;
  int       chartCorner;
  int       panelX;
  int       panelY;
  uint      panelBackgroundColor;
  bool      unusedAlternateRowFlag;
  int       oneChartExtraHeight;
  string    tradeFrequencyText;
  int       cellObjectIndex;
  int       columnIndex;
  int       rowIndex;
  string    cellText;
  int       tableOriginX;
  int       tableOriginY;
  int       strategyRowIndex;
//----------------------------------------------------------------------

 unusedPanelTitleOffset = 20 ;
 unusedPanelBaseWidth = 300 ;
 unusedPanelDefaultFontSize = 7 ;
 unusedPanelScale = InfoPanelSizeAdjust ;
 panelTextXPadding = 6 ;
 panelTextYPadding = 4 ;
 panelWidth = 350 ;
 panelHeight = 366 ;
 chartCorner = 0 ;
 panelX = 5 ;
 panelY = 20 ;
 panelBackgroundColor = LightSteelBlue ;
 unusedAlternateRowFlag = false ;
 oneChartExtraHeight = 0 ;
 if ( oneChartSetupEnabled )
 {
   oneChartExtraHeight = (int)((strategySymbolCount + 3) * panelRowHeight) ;
 }
 ObjectCreate(0,"infopanel_rectangle",OBJ_RECTANGLE_LABEL,0,0,0.0); 
 ObjectSetInteger(0,"infopanel_rectangle",OBJPROP_XDISTANCE,panelX); 
 ObjectSetInteger(0,"infopanel_rectangle",OBJPROP_YDISTANCE,panelY); 
 ObjectSetInteger(0,"infopanel_rectangle",OBJPROP_XSIZE,long(panelWidth * InfoPanelSizeAdjust)); 
 ObjectSetInteger(0,"infopanel_rectangle",OBJPROP_YSIZE,long(panelHeight * InfoPanelSizeAdjust + oneChartExtraHeight)); 
 ObjectSetInteger(0,"infopanel_rectangle",OBJPROP_CORNER,CORNER_LEFT_UPPER); 
 ObjectSetInteger(0,"infopanel_rectangle",OBJPROP_COLOR,clrBlue); 
 ObjectSetInteger(0,"infopanel_rectangle",OBJPROP_BGCOLOR,panelBackgroundColor); 
 ObjectSetInteger(0,"infopanel_rectangle",OBJPROP_BACK,0); 
 ObjectSetInteger(0,"infopanel_rectangle",OBJPROP_BORDER_COLOR,clrBlue); 
 ObjectSetInteger(0,"infopanel_rectangle",OBJPROP_COLOR,clrBlue); 
 ObjectSetInteger(0,"infopanel_rectangle",OBJPROP_BORDER_TYPE,BORDER_FLAT); 
 ObjectSetInteger(0,"infopanel_rectangle",OBJPROP_STYLE,STYLE_SOLID); 
 ObjectSetInteger(0,"infopanel_rectangle",OBJPROP_WIDTH,2); 
 ObjectSetInteger(0,"infopanel_rectangle",OBJPROP_SELECTABLE,0); 
 ObjectCreate(0,"line1",OBJ_LABEL,0,0,0.0); 
 ObjectSetInteger(0,"line1",OBJPROP_CORNER,chartCorner); 
 ObjectSetInteger(0,"line1",OBJPROP_YDISTANCE,panelY + panelTextYPadding); 
 ObjectSetInteger(0,"line1",OBJPROP_XDISTANCE,panelX + panelTextXPadding); 
 if ( !(oneChartSetupEnabled) )
 {
   ObjectSetString(0,"line1",OBJPROP_TEXT,"The Gold Reaper V4.5"); 
 }
 else
 {
   ObjectSetString(0,"line1",OBJPROP_TEXT,"The Gold Reaper V4.5 - OneChartSetup"); 
 }
 ObjectSetInteger(0,"line1",OBJPROP_COLOR,panelTextColor);
 // Ban decompile goc thieu set co chu rieng cho cac dong tieu de/tom tat panel
 // (chi co bang chien luoc phia duoi duoc set), trong khi kich thuoc khung panel
 // lai duoc tinh dua tren dung hang so co chu nay -> khien cac dong nay hien thi
 // to hon binh thuong (dung co mac dinh cua nen tang) so voi thiet ke that su cua
 // khung panel. Set khop voi co chu cua bang chien luoc de dong bo.
 ObjectSetInteger(0,"line1",OBJPROP_FONTSIZE,panelFontSize);
 ObjectCreate(0,"linec",OBJ_LABEL,0,0,0.0);
 ObjectSetInteger(0,"linec",OBJPROP_CORNER,chartCorner); 
 ObjectSetInteger(0,"linec",OBJPROP_YDISTANCE,long(panelY + InfoPanelSizeAdjust * 20.0 + panelTextYPadding)); 
 ObjectSetInteger(0,"linec",OBJPROP_XDISTANCE,panelX + panelTextXPadding); 
 ObjectSetString(0,"linec",OBJPROP_TEXT,"EA developer by Pham Duy Linh - 2026"); 
 ObjectSetInteger(0,"linec",OBJPROP_COLOR,panelTextColor);
 ObjectSetInteger(0,"linec",OBJPROP_FONTSIZE,panelFontSize);
 ObjectCreate(0,"line2",OBJ_LABEL,0,0,0.0);
 ObjectSetInteger(0,"line2",OBJPROP_CORNER,chartCorner); 
 ObjectSetInteger(0,"line2",OBJPROP_YDISTANCE,long(panelY + InfoPanelSizeAdjust * 32.0 + panelTextYPadding)); 
 ObjectSetInteger(0,"line2",OBJPROP_XDISTANCE,panelX + panelTextXPadding); 
 ObjectSetString(0,"line2",OBJPROP_TEXT,"------------------------------------------------------"); 
 ObjectSetInteger(0,"line2",OBJPROP_COLOR,panelTextColor);
 ObjectSetInteger(0,"line2",OBJPROP_FONTSIZE,panelFontSize);
 ObjectCreate(0,"lines",OBJ_LABEL,0,0,0.0);
 ObjectSetInteger(0,"lines",OBJPROP_CORNER,chartCorner); 
 ObjectSetInteger(0,"lines",OBJPROP_YDISTANCE,long(panelY + InfoPanelSizeAdjust * 44.0 + panelTextYPadding)); 
 ObjectSetInteger(0,"lines",OBJPROP_XDISTANCE,panelX + panelTextXPadding); 
 if ( activeTradeFrequency == 1 )
 {
   tradeFrequencyText = "conservative" ;
 }
 else
 {
   if ( activeTradeFrequency == 2 )
   {
     tradeFrequencyText = "moderate" ;
   }
   else
   {
     if ( activeTradeFrequency == 3 )
     {
       tradeFrequencyText = "intense" ;
     }
     else
     {
       if ( activeTradeFrequency == 4 )
       {
         tradeFrequencyText = "extreme" ;
       }
       else
       {
         if ( activeTradeFrequency == 0 )
         {
           tradeFrequencyText = "extreme conservative" ;
         }
         else
         {
           tradeFrequencyText = "manual strategy selection" ;
         }
       }
     }
   }
 }
 ObjectSetString(0,"lines",OBJPROP_TEXT,"Trade Frequency: " + tradeFrequencyText);
 ObjectSetInteger(0,"lines",OBJPROP_COLOR,panelTextColor);
 ObjectSetInteger(0,"lines",OBJPROP_FONTSIZE,panelFontSize);
 if ( Risk == 1234 )
 {
   ObjectCreate(0,"linet",OBJ_LABEL,0,0,0.0); 
   ObjectSetInteger(0,"linet",OBJPROP_CORNER,chartCorner); 
   ObjectSetInteger(0,"linet",OBJPROP_YDISTANCE,long(panelY + InfoPanelSizeAdjust * 60.0 + panelTextYPadding)); 
   ObjectSetInteger(0,"linet",OBJPROP_XDISTANCE,panelX + panelTextXPadding); 
   ObjectSetString(0,"linet",OBJPROP_TEXT,"Max allowed DD: " + string(MaxAllowedDD) + "%");
   ObjectSetInteger(0,"linet",OBJPROP_COLOR,panelTextColor);
   ObjectSetInteger(0,"linet",OBJPROP_FONTSIZE,panelFontSize);
 }
 else
 {
   if ( Risk == 3 )
   {
     ObjectCreate(0,"linet",OBJ_LABEL,0,0,0.0); 
     ObjectSetInteger(0,"linet",OBJPROP_CORNER,chartCorner); 
     ObjectSetInteger(0,"linet",OBJPROP_YDISTANCE,long(panelY + InfoPanelSizeAdjust * 60.0 + panelTextYPadding)); 
     ObjectSetInteger(0,"linet",OBJPROP_XDISTANCE,panelX + panelTextXPadding); 
     ObjectSetString(0,"linet",OBJPROP_TEXT,"Max risk per strategy: " + string(MaxRiskPerStrategy_) + "%");
     ObjectSetInteger(0,"linet",OBJPROP_COLOR,panelTextColor);
     ObjectSetInteger(0,"linet",OBJPROP_FONTSIZE,panelFontSize);
   }
   else
   {
     ObjectCreate(0,"linet",OBJ_LABEL,0,0,0.0);
     ObjectSetInteger(0,"linet",OBJPROP_CORNER,chartCorner); 
     ObjectSetInteger(0,"linet",OBJPROP_YDISTANCE,long(panelY + InfoPanelSizeAdjust * 60.0 + panelTextYPadding)); 
     ObjectSetInteger(0,"linet",OBJPROP_XDISTANCE,panelX + panelTextXPadding); 
     ObjectSetString(0,"linet",OBJPROP_TEXT,"Manual lotsize: " + string(startLots_rw) + "lots");
     ObjectSetInteger(0,"linet",OBJPROP_COLOR,panelTextColor);
     ObjectSetInteger(0,"linet",OBJPROP_FONTSIZE,panelFontSize);
   }
 }
 ObjectCreate(0,"lineopl" + IntegerToString(0,0,32),OBJ_LABEL,0,0,0.0);
 ObjectSetInteger(0,"lineopl" + IntegerToString(0,0,32),OBJPROP_CORNER,chartCorner); 
 ObjectSetInteger(0,"lineopl" + IntegerToString(0,0,32),OBJPROP_YDISTANCE,(long)(panelY + InfoPanelSizeAdjust * 76.0 + panelTextYPadding)); 
 ObjectSetInteger(0,"lineopl" + IntegerToString(0,0,32),OBJPROP_XDISTANCE,panelX + panelTextXPadding); 
 ObjectSetString(0,"lineopl" + IntegerToString(0,0,32),OBJPROP_TEXT,"Open P/L: -");
 ObjectSetInteger(0,"lineopl" + IntegerToString(0,0,32),OBJPROP_COLOR,panelTextColor);
 ObjectSetInteger(0,"lineopl" + IntegerToString(0,0,32),OBJPROP_FONTSIZE,panelFontSize);
 ObjectCreate(0,"linea" + IntegerToString(0,0,32),OBJ_LABEL,0,0,0.0);
 ObjectSetInteger(0,"linea" + IntegerToString(0,0,32),OBJPROP_CORNER,chartCorner); 
 ObjectSetInteger(0,"linea" + IntegerToString(0,0,32),OBJPROP_YDISTANCE,(long)(panelY + InfoPanelSizeAdjust * 108.0 + panelTextYPadding)); 
 ObjectSetInteger(0,"linea" + IntegerToString(0,0,32),OBJPROP_XDISTANCE,panelX + panelTextXPadding); 
 ObjectSetString(0,"linea" + IntegerToString(0,0,32),OBJPROP_TEXT,"Account Balance: -");
 ObjectSetInteger(0,"linea" + IntegerToString(0,0,32),OBJPROP_COLOR,panelTextColor);
 ObjectSetInteger(0,"linea" + IntegerToString(0,0,32),OBJPROP_FONTSIZE,panelFontSize);
 ObjectCreate(0,"linetp" + IntegerToString(0,0,32),OBJ_LABEL,0,0,0.0);
 ObjectSetInteger(0,"linetp" + IntegerToString(0,0,32),OBJPROP_CORNER,chartCorner);
 ObjectSetInteger(0,"linetp" + IntegerToString(0,0,32),OBJPROP_YDISTANCE,(long)(panelY + InfoPanelSizeAdjust * 124.0 + panelTextYPadding));
 ObjectSetInteger(0,"linetp" + IntegerToString(0,0,32),OBJPROP_XDISTANCE,panelX + panelTextXPadding);
 ObjectSetString(0,"linetp" + IntegerToString(0,0,32),OBJPROP_TEXT,"Total P/L so far: -");
 ObjectSetInteger(0,"linetp" + IntegerToString(0,0,32),OBJPROP_COLOR,panelTextColor);
 ObjectSetInteger(0,"linetp" + IntegerToString(0,0,32),OBJPROP_FONTSIZE,panelFontSize);
 if ( EnableNFP_Filter )
 {
   ObjectCreate(0,"linenfp" + IntegerToString(0,0,32),OBJ_LABEL,0,0,0.0);
   ObjectSetInteger(0,"linenfp" + IntegerToString(0,0,32),OBJPROP_CORNER,chartCorner);
   ObjectSetInteger(0,"linenfp" + IntegerToString(0,0,32),OBJPROP_YDISTANCE,(long)(panelY + InfoPanelSizeAdjust * 140.0 + panelTextYPadding));
   ObjectSetInteger(0,"linenfp" + IntegerToString(0,0,32),OBJPROP_XDISTANCE,panelX + panelTextXPadding);
   ObjectSetString(0,"linenfp" + IntegerToString(0,0,32),OBJPROP_TEXT,"No News Coming Up");
   ObjectSetInteger(0,"linenfp" + IntegerToString(0,0,32),OBJPROP_COLOR,panelTextColor);
   ObjectSetInteger(0,"linenfp" + IntegerToString(0,0,32),OBJPROP_FONTSIZE,panelFontSize);
 }
 if ( OnlyUp )
 {
   ObjectCreate(0,"lineup" + IntegerToString(0,0,32),OBJ_LABEL,0,0,0.0);
   ObjectSetInteger(0,"lineup" + IntegerToString(0,0,32),OBJPROP_CORNER,chartCorner);
   ObjectSetInteger(0,"lineup" + IntegerToString(0,0,32),OBJPROP_YDISTANCE,(long)(panelY + InfoPanelSizeAdjust * 92.0 + panelTextYPadding));
   ObjectSetInteger(0,"lineup" + IntegerToString(0,0,32),OBJPROP_XDISTANCE,panelX + panelTextXPadding);
   ObjectSetString(0,"lineup" + IntegerToString(0,0,32),OBJPROP_TEXT,"Highest Balance: -");
   ObjectSetInteger(0,"lineup" + IntegerToString(0,0,32),OBJPROP_COLOR,panelTextColor);
   ObjectSetInteger(0,"lineup" + IntegerToString(0,0,32),OBJPROP_FONTSIZE,panelFontSize);
 }
 cellObjectIndex = 0 ;
 columnIndex = 0 ;
 rowIndex = 0 ;
 tableOriginX = panelX + panelTextXPadding ;
 tableOriginY = (int)(panelY + InfoPanelSizeAdjust * 176.0 + panelTextYPadding) ;
 cellText = "Strategy" ;
 CreatePanelCell(tableOriginX,tableOriginY,0,"Strategy",0,0,0,0,1.0); 
 cellObjectIndex = 1 ;
 columnIndex = 1 ;
 cellText = "Closed PL" ;
 if ( strategyRankingMode == 1 )
 {
   cellText = "Closed PL*" ;
 }
 CreatePanelCell(tableOriginX,tableOriginY,cellObjectIndex,cellText,rowIndex,columnIndex,0,0,1.0); 
 cellObjectIndex ++;
 columnIndex ++;
 cellText = "PL per trade" ;
 if ( strategyRankingMode == 2 )
 {
   cellText = "PL per trade*" ;
 }
 CreatePanelCell(tableOriginX,tableOriginY,cellObjectIndex,cellText,rowIndex,columnIndex,0,0,1.0); 
 cellObjectIndex ++;
 columnIndex ++;
 cellText = "Lotsize" ;
 CreatePanelCell(tableOriginX,tableOriginY,cellObjectIndex,"Lotsize",rowIndex,columnIndex,0,0,1.0); 
 cellObjectIndex ++;
 columnIndex = 0 ;
 rowIndex ++;
 panelStrategyRowStartIndex = cellObjectIndex ;
 for (strategyRowIndex = 0 ; strategyRowIndex < 9 ; strategyRowIndex ++)
 {
   cellText="Strategy " + IntegerToString(strategyRowIndex + 1,0,32);
   CreatePanelCell(tableOriginX,tableOriginY,cellObjectIndex,cellText,rowIndex,columnIndex,0,0,1.0); 
   cellObjectIndex ++;
   columnIndex ++;
   cellText = DoubleToString(NormalizeDouble(strategyDisplayProfit[strategyRowIndex],2),2) ;
   CreatePanelCell(tableOriginX,tableOriginY,cellObjectIndex,cellText,rowIndex,columnIndex,0,0,1.0); 
   cellObjectIndex ++;
   columnIndex ++;
   cellText = DoubleToString(NormalizeDouble(averageProfitByStrategy[strategyRowIndex],2),2) ;
   CreatePanelCell(tableOriginX,tableOriginY,cellObjectIndex,cellText,rowIndex,columnIndex,0,0,1.0); 
   cellObjectIndex ++;
   columnIndex ++;
   cellText = DoubleToString(NormalizeDouble(lotSizeByStrategy[strategyRowIndex],2),2) ;
   CreatePanelCell(tableOriginX,tableOriginY,cellObjectIndex,cellText,rowIndex,columnIndex,0,0,1.0); 
   cellObjectIndex ++;
   columnIndex = 0 ;
   rowIndex ++;
 }
 }
//CreateInfoPanel <<==--------   --------
 void CreatePanelCell( int baseX,int baseY,int objectIndex,string text,int rowIndex,int columnIndex,int alignmentMode,uint textColor,double fontScale)
 {
 ObjectCreate(0,"info_ea" + IntegerToString(objectIndex,0,32),OBJ_EDIT,0,0,0.0); 
 ObjectSetInteger(0,"info_ea" + IntegerToString(objectIndex,0,32),OBJPROP_XDISTANCE,(long)(baseX + columnIndex * panelRowWidth)); 
 ObjectSetInteger(0,"info_ea" + IntegerToString(objectIndex,0,32),OBJPROP_YDISTANCE,(long)(baseY + rowIndex * panelRowHeight)); 
 ObjectSetString(0,"info_ea" + IntegerToString(objectIndex,0,32),OBJPROP_TEXT,text); 
 ObjectSetInteger(0,"info_ea" + IntegerToString(objectIndex,0,32),OBJPROP_BACK,0); 
 ObjectSetInteger(0,"info_ea" + IntegerToString(objectIndex,0,32),OBJPROP_COLOR,textColor); 
 ObjectSetInteger(0,"info_ea" + IntegerToString(objectIndex,0,32),OBJPROP_BGCOLOR,panelCellBackgroundColor); 
 ObjectSetInteger(0,"info_ea" + IntegerToString(objectIndex,0,32),OBJPROP_BORDER_COLOR,0); 
 ObjectSetInteger(0,"info_ea" + IntegerToString(objectIndex,0,32),OBJPROP_FONTSIZE,(long)(panelFontSize * fontScale)); 
 ObjectSetInteger(0,"info_ea" + IntegerToString(objectIndex,0,32),OBJPROP_READONLY,true); 
 ObjectSetInteger(0,"info_ea" + IntegerToString(objectIndex,0,32),OBJPROP_YSIZE,(long)panelRowHeight); 
 ObjectSetInteger(0,"info_ea" + IntegerToString(objectIndex,0,32),OBJPROP_XSIZE,(long)panelRowWidth); 
 ObjectSetInteger(0,"info_ea" + IntegerToString(objectIndex,0,32),OBJPROP_YSIZE,(long)panelRowHeight); 
 if ( alignmentMode == 0 )
 {
   ObjectSetInteger(0,"info_ea" + IntegerToString(objectIndex,0,32),OBJPROP_ALIGN,ALIGN_CENTER); 
 }
 if ( alignmentMode == 1 )
 {
   ObjectSetInteger(0,"info_ea" + IntegerToString(objectIndex,0,32),OBJPROP_ALIGN,ALIGN_RIGHT); 
 }
 if ( alignmentMode != 2 )   return;
 ObjectSetInteger(0,"info_ea" + IntegerToString(objectIndex,0,32),OBJPROP_ALIGN,0); 
 }
//CreatePanelCell <<==--------   --------
 void DeleteInfoPanel()
 {
  int       summaryObjectIndex;
  int       tableObjectIndex;
  int       headingObjectIndex;
  int       panelObjectIndex;
//----------------------------------------------------------------------

 ObjectDelete(0,"line1"); 
 ObjectDelete(0,"linec"); 
 ObjectDelete(0,"line2"); 
 ObjectDelete(0,"lines"); 
 ObjectDelete(0,"linet"); 
 ObjectDelete(0,"lineTradeStart"); 
 for (summaryObjectIndex = 0 ; summaryObjectIndex <= 99 ; summaryObjectIndex ++)
 {
   ObjectDelete(0,"lineopl" + IntegerToString(summaryObjectIndex,0,32)); 
   ObjectDelete(0,"linea" + IntegerToString(summaryObjectIndex,0,32)); 
   ObjectDelete(0,"lineto" + IntegerToString(summaryObjectIndex,0,32)); 
   ObjectDelete(0,"linetp" + IntegerToString(summaryObjectIndex,0,32));
   ObjectDelete(0,"linetq" + IntegerToString(summaryObjectIndex,0,32));
   ObjectDelete(0,"linenfp" + IntegerToString(summaryObjectIndex,0,32));
   ObjectDelete(0,"lineup" + IntegerToString(summaryObjectIndex,0,32));
   for (tableObjectIndex = 0 ; tableObjectIndex < 10 ; tableObjectIndex ++)
   {
     ObjectDelete(0,"tabel_info" + IntegerToString(summaryObjectIndex * 100 + tableObjectIndex,0,32)); 
   }
 }
 ObjectDelete(0,"infopanel_rectangle"); 
 for (headingObjectIndex = 0 ; headingObjectIndex < 10 ; headingObjectIndex ++)
 {
   ObjectDelete(0,"tabel_heading" + IntegerToString(headingObjectIndex,0,32)); 
   ObjectDelete(0,"tabel_totals" + IntegerToString(headingObjectIndex,0,32)); 
 }
 for (panelObjectIndex = 0 ; panelObjectIndex < panelObjectCount ; panelObjectIndex ++)
 {
   ObjectDelete(0,"horizontalrect" + IntegerToString(panelObjectIndex,0,32)); 
   ObjectDelete(0,"info_ea" + IntegerToString(panelObjectIndex,0,32)); 
 }
 }
//DeleteInfoPanel <<==--------   --------
 string OnlyUpPeakGVName()
 {
 // Tach biet hoan toan dinh giua cac "phien": trong Strategy Tester, moi lan
 // chay (launch) mang mot onlyUpRunId rieng (sinh moi lan OnInit) nen khong
 // bao gio doc phai dinh con sot tu lan backtest truoc - moi lan backtest doc
 // lap 100% nhung van cap nhat/luu dinh binh thuong trong suot lan chay do.
 // Ngoai Tester (live/demo that), tach theo so tai khoan (ACCOUNT_LOGIN) de
 // tai khoan live va demo khac nhau khong dung chung 1 dinh.
 if ( MQLInfoInteger(MQL_TESTER) == 1 )
 {
   return("GR_OnlyUpPeak_TESTER_" + Symbol() + "_" + IntegerToString(ST1_MagicNumber) + "_" + IntegerToString(onlyUpRunId));
 }
 return("GR_OnlyUpPeak_" + Symbol() + "_" + IntegerToString(ST1_MagicNumber) + "_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)));
 }
//OnlyUpPeakGVName <<==--------   --------
 string OnlyUpWithdrawGVName()
 {
 // Ten ngan hon gioi han 63 ky tu cua Global Variable, nhung van tach theo
 // phien tester / symbol / magic / tai khoan giong dinh OnlyUp.
 if ( MQLInfoInteger(MQL_TESTER) == 1 )
 {
   return("GR_OUWD_T_" + Symbol() + "_" + IntegerToString(ST1_MagicNumber) + "_" + IntegerToString(onlyUpRunId));
 }
 return("GR_OUWD_" + Symbol() + "_" + IntegerToString(ST1_MagicNumber) + "_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)));
 }
//OnlyUpWithdrawGVName <<==--------   --------
 string GetNextNFPText()
 {
  datetime  nextNfpTime = 0;
  int       nfpDateIndex;
//----------------------------------------------------------------------
 // Theo trang thai lay tin (nfpStatus): 2 = Lich MQL5 khong doc duoc -> bao
 // loi lay tin. mq5 dung Lich (khong co link) nen khong co trang thai thieu
 // link. Binh thuong (0): co NFP -> "Next NFP: ..."; khong co -> "No News".
 if ( nfpStatus == 2 )   return("NFP: news fetch error");
 for (nfpDateIndex = 0 ; nfpDateIndex < 300 ; nfpDateIndex ++)
 {
   if ( nfpDatesGmt[nfpDateIndex] <= 0 )   continue;
   if ( nfpDatesGmt[nfpDateIndex] >= currentGmtTime )
   {
     if ( nextNfpTime == 0 || nfpDatesGmt[nfpDateIndex] < nextNfpTime )   nextNfpTime = nfpDatesGmt[nfpDateIndex];
   }
 }
 if ( nextNfpTime == 0 )   return("No News Coming Up"); // chua co/chua lay duoc lich -> giong panel v4.3
 return("Next NFP: " + TimeToString(nextNfpTime + brokerGmtOffsetHours * 3600,TIME_DATE|TIME_SECONDS));
 }
//GetNextNFPText <<==--------   --------
 void UpdateInfoPanelSummary()
 {
  string    tradeFrequencyText;
//----------------------------------------------------------------------
 double     displayOpenProfit;
 double     openProfitAccumulator;
 int        openOrderScanIndex;
 long        openProfitMagicCheck01;
 long        openProfitMagicCheck02;
 long        openProfitMagicCheck03;
 long        openProfitMagicCheck04;
 long        openProfitMagicCheck05;
 long        openProfitMagicCheck06;
 long        openProfitMagicCheck07;
 long        openProfitMagicCheck08;
 long        openProfitMagicCheck09;
 long        openProfitMagicCheck10;
 long        openProfitMagicCheck11;
 long        openProfitMagicCheck12;
 long        openProfitMagicCheck13;
 long        openProfitMagicCheck14;
 long        openProfitMagicCheck15;
 long        openProfitMagicCheck16;

 if ( !(ShowInfoPanel) )   return;
 
 if ( ( MQLInfoInteger(MQL_TESTER) == 1 && !(UpdateInfoTesting) ) )   return;
 
 if ( MQLInfoInteger(MQL_TESTER) == 1 && !(UpdateInfoTesting) )
 {
   displayOpenProfit = 0.0;
 }
 else
 {
   openProfitAccumulator = 0.0;
   for (openOrderScanIndex = ActiveTradeCount() ; openOrderScanIndex >= 0 ; openOrderScanIndex=openOrderScanIndex - 1)
   {
     if ( SelectTradeRecord(openOrderScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true )   continue;
     
     if ( ( SelectedTradeSymbol() != currentSymbol && !(oneChartSetupEnabled) ) )   continue;
     openProfitMagicCheck01 = SelectedTradeMagic();
     openProfitMagicCheck02=ST1_MagicNumber + 1;
     if ( openProfitMagicCheck01 != openProfitMagicCheck02 )
     {
       openProfitMagicCheck02 = SelectedTradeMagic();
       openProfitMagicCheck03=ST1_MagicNumber + 2;
       if ( openProfitMagicCheck02 != openProfitMagicCheck03 )
       {
         openProfitMagicCheck03 = SelectedTradeMagic();
         openProfitMagicCheck04=ST1_MagicNumber + 3;
         if ( openProfitMagicCheck03 != openProfitMagicCheck04 )
         {
           openProfitMagicCheck04 = SelectedTradeMagic();
           openProfitMagicCheck05=ST1_MagicNumber + 4;
           if ( openProfitMagicCheck04 != openProfitMagicCheck05 )
           {
             openProfitMagicCheck05 = SelectedTradeMagic();
             openProfitMagicCheck06=ST1_MagicNumber + 5;
             if ( openProfitMagicCheck05 != openProfitMagicCheck06 )
             {
               openProfitMagicCheck06 = SelectedTradeMagic();
               openProfitMagicCheck07=ST1_MagicNumber + 6;
               if ( openProfitMagicCheck06 != openProfitMagicCheck07 )
               {
                 openProfitMagicCheck07 = SelectedTradeMagic();
                 openProfitMagicCheck08=ST1_MagicNumber + 7;
                 if ( openProfitMagicCheck07 != openProfitMagicCheck08 )
                 {
                   openProfitMagicCheck08 = SelectedTradeMagic();
                   openProfitMagicCheck09=ST1_MagicNumber + 8;
                   if ( openProfitMagicCheck08 != openProfitMagicCheck09 )
                   {
                     openProfitMagicCheck09 = SelectedTradeMagic();
                     openProfitMagicCheck10=ST1_MagicNumber + 9;
                     if ( openProfitMagicCheck09 != openProfitMagicCheck10 )
                     {
                       openProfitMagicCheck10 = SelectedTradeMagic();
                       openProfitMagicCheck11=ST1_MagicNumber + 10;
                       if ( openProfitMagicCheck10 != openProfitMagicCheck11 )
                       {
                         openProfitMagicCheck11 = SelectedTradeMagic();
                         openProfitMagicCheck12=ST1_MagicNumber + 11;
                         if ( openProfitMagicCheck11 != openProfitMagicCheck12 )
                         {
                           openProfitMagicCheck12 = SelectedTradeMagic();
                           openProfitMagicCheck13=ST1_MagicNumber + 12;
                           if ( openProfitMagicCheck12 != openProfitMagicCheck13 )
                           {
                             openProfitMagicCheck13 = SelectedTradeMagic();
                             openProfitMagicCheck14=ST1_MagicNumber + 13;
                             if ( openProfitMagicCheck13 != openProfitMagicCheck14 )
                             {
                               openProfitMagicCheck14 = SelectedTradeMagic();
                               openProfitMagicCheck15=ST1_MagicNumber + 14;
                               if ( openProfitMagicCheck14 != openProfitMagicCheck15 )
                               {
                                 openProfitMagicCheck15 = SelectedTradeMagic();
                                 openProfitMagicCheck16=ST1_MagicNumber + 15;
                               if ( openProfitMagicCheck15 != openProfitMagicCheck16 )   continue;
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
     if ( ( SelectedTradeType() != ORDER_TYPE_BUY && SelectedTradeType() != ORDER_TYPE_SELL ) )   continue;
     openProfitAccumulator = SelectedTradeProfit() + SelectedTradeSwap() + SelectedTradeCommission() + openProfitAccumulator;
     
   }
   openProfitByStrategy[currentStrategyIndex] = openProfitAccumulator;
   displayOpenProfit = openProfitAccumulator;
 }
 ObjectSetString(0,"lineopl" + IntegerToString(0,0,32),OBJPROP_TEXT,"Open P/L: " + DoubleToString(displayOpenProfit,2)); 
 ObjectSetString(0,"linea" + IntegerToString(0,0,32),OBJPROP_TEXT,"Account Balance: " + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE),2)); 
 if ( activeTradeFrequency == 1 )
 {
   tradeFrequencyText = "conservative" ;
 }
 else
 {
   if ( activeTradeFrequency == 2 )
   {
     tradeFrequencyText = "moderate" ;
   }
   else
   {
     if ( activeTradeFrequency == 3 )
     {
       tradeFrequencyText = "intense" ;
     }
     else
     {
       if ( activeTradeFrequency == 4 )
       {
         tradeFrequencyText = "extreme" ;
       }
       else
       {
         if ( activeTradeFrequency == 0 )
         {
           tradeFrequencyText = "extreme conservative" ;
         }
         else
         {
           tradeFrequencyText = "manual strategy selection" ;
         }
       }
     }
   }
 }
 ObjectSetString(0,"lines",OBJPROP_TEXT,"Trade Frequency: " + tradeFrequencyText); 
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
     ObjectSetString(0,"linet",OBJPROP_TEXT,"Manual lotsize: " + string(startLots_rw) + "lots"); 
   }
 }
 }
//UpdateInfoPanelSummary <<==--------   --------
 void UpdateInfoPanelStrategyRows()
 {
  int       cellObjectIndex;
  string    cellText;
  int       strategyIndex;
//----------------------------------------------------------------------

 if ( !(ShowInfoPanel) )   return;
 
 if ( ( MQLInfoInteger(MQL_TESTER) == 1 && !(UpdateInfoTesting) ) )   return;
 cellObjectIndex = panelStrategyRowStartIndex ;
 for (strategyIndex = 0 ; strategyIndex < 9 ; strategyIndex ++)
 {
   cellText="Strategy " + IntegerToString(strategyIndex + 1,0,32);
   ObjectSetString(0,"info_ea" + IntegerToString(cellObjectIndex,0,32),OBJPROP_TEXT,cellText); 
   cellObjectIndex ++;
   cellText = DoubleToString(NormalizeDouble(strategyDisplayProfit[strategyIndex],2),2) ;
   ObjectSetString(0,"info_ea" + IntegerToString(cellObjectIndex,0,32),OBJPROP_TEXT,cellText); 
   cellObjectIndex ++;
   cellText = DoubleToString(NormalizeDouble(averageProfitByStrategy[strategyIndex],2),2) ;
   ObjectSetString(0,"info_ea" + IntegerToString(cellObjectIndex,0,32),OBJPROP_TEXT,cellText); 
   cellObjectIndex ++;
   cellText = DoubleToString(NormalizeDouble(lotSizeByStrategy[strategyIndex],2),2) ;
   ObjectSetString(0,"info_ea" + IntegerToString(cellObjectIndex,0,32),OBJPROP_TEXT,cellText); 
   cellObjectIndex ++;
 }
 }
//UpdateInfoPanelStrategyRows <<==--------   --------
 void UpdateInfoPanelTotals()
 {
 double     displayClosedProfit;
 double     closedProfitAccumulator;
 int        panelClosedTradeCount;
 int        historyScanIndex;
 long        closedProfitMagicCheck01;
 long        closedProfitMagicCheck02;
 long        closedProfitMagicCheck03;
 long        closedProfitMagicCheck04;
 long        closedProfitMagicCheck05;
 long        closedProfitMagicCheck06;
 long        closedProfitMagicCheck07;
 long        closedProfitMagicCheck08;
 long        closedProfitMagicCheck09;
 long        closedProfitMagicCheck10;
 long        closedProfitMagicCheck11;
 long        closedProfitMagicCheck12;
 long        closedProfitMagicCheck13;
 long        closedProfitMagicCheck14;
 long        closedProfitMagicCheck15;
 long        closedProfitMagicCheck16;

 if ( !(ShowInfoPanel) )   return;
 
 if ( ( MQLInfoInteger(MQL_TESTER) == 1 && !(UpdateInfoTesting) ) )   return;
 ObjectSetString(0,"lineto" + IntegerToString(0,0,32),OBJPROP_TEXT,"Total profits/losses so far: " + IntegerToString(CountWinningClosedTrades(0,9999999),0,32) + "/" + IntegerToString(CountLosingClosedTrades(0,9999999),0,32)); 
 if ( MQLInfoInteger(MQL_TESTER) == 1 && !(UpdateInfoTesting) )
 {
   displayClosedProfit = 0.0;
 }
 else
 {
   closedProfitAccumulator = 0.0;
   panelClosedTradeCount = 0;
   for (historyScanIndex = ClosedTradeCount() ; historyScanIndex >= 0 ; historyScanIndex=historyScanIndex - 1)
   {
     if ( SelectTradeRecord(historyScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_HISTORY) != true )   continue;
     
     if ( ( SelectedTradeSymbol() != currentSymbol && !(oneChartSetupEnabled) ) )   continue;
     closedProfitMagicCheck01 = SelectedTradeMagic();
     closedProfitMagicCheck02=ST1_MagicNumber + 1;
     if ( closedProfitMagicCheck01 != closedProfitMagicCheck02 )
     {
       closedProfitMagicCheck02 = SelectedTradeMagic();
       closedProfitMagicCheck03=ST1_MagicNumber + 2;
       if ( closedProfitMagicCheck02 != closedProfitMagicCheck03 )
       {
         closedProfitMagicCheck03 = SelectedTradeMagic();
         closedProfitMagicCheck04=ST1_MagicNumber + 3;
         if ( closedProfitMagicCheck03 != closedProfitMagicCheck04 )
         {
           closedProfitMagicCheck04 = SelectedTradeMagic();
           closedProfitMagicCheck05=ST1_MagicNumber + 4;
           if ( closedProfitMagicCheck04 != closedProfitMagicCheck05 )
           {
             closedProfitMagicCheck05 = SelectedTradeMagic();
             closedProfitMagicCheck06=ST1_MagicNumber + 5;
             if ( closedProfitMagicCheck05 != closedProfitMagicCheck06 )
             {
               closedProfitMagicCheck06 = SelectedTradeMagic();
               closedProfitMagicCheck07=ST1_MagicNumber + 6;
               if ( closedProfitMagicCheck06 != closedProfitMagicCheck07 )
               {
                 closedProfitMagicCheck07 = SelectedTradeMagic();
                 closedProfitMagicCheck08=ST1_MagicNumber + 7;
                 if ( closedProfitMagicCheck07 != closedProfitMagicCheck08 )
                 {
                   closedProfitMagicCheck08 = SelectedTradeMagic();
                   closedProfitMagicCheck09=ST1_MagicNumber + 8;
                   if ( closedProfitMagicCheck08 != closedProfitMagicCheck09 )
                   {
                     closedProfitMagicCheck09 = SelectedTradeMagic();
                     closedProfitMagicCheck10=ST1_MagicNumber + 9;
                     if ( closedProfitMagicCheck09 != closedProfitMagicCheck10 )
                     {
                       closedProfitMagicCheck10 = SelectedTradeMagic();
                       closedProfitMagicCheck11=ST1_MagicNumber + 10;
                       if ( closedProfitMagicCheck10 != closedProfitMagicCheck11 )
                       {
                         closedProfitMagicCheck11 = SelectedTradeMagic();
                         closedProfitMagicCheck12=ST1_MagicNumber + 11;
                         if ( closedProfitMagicCheck11 != closedProfitMagicCheck12 )
                         {
                           closedProfitMagicCheck12 = SelectedTradeMagic();
                           closedProfitMagicCheck13=ST1_MagicNumber + 12;
                           if ( closedProfitMagicCheck12 != closedProfitMagicCheck13 )
                           {
                             closedProfitMagicCheck13 = SelectedTradeMagic();
                             closedProfitMagicCheck14=ST1_MagicNumber + 13;
                             if ( closedProfitMagicCheck13 != closedProfitMagicCheck14 )
                             {
                               closedProfitMagicCheck14 = SelectedTradeMagic();
                               closedProfitMagicCheck15=ST1_MagicNumber + 14;
                               if ( closedProfitMagicCheck14 != closedProfitMagicCheck15 )
                               {
                                 closedProfitMagicCheck15 = SelectedTradeMagic();
                                 closedProfitMagicCheck16=ST1_MagicNumber + 15;
                               if ( closedProfitMagicCheck15 != closedProfitMagicCheck16 )   continue;
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
     panelClosedTradeCount=panelClosedTradeCount + 1;
     closedProfitAccumulator = closedProfitAccumulator + SelectedTradeProfit() + SelectedTradeSwap() + SelectedTradeCommission();
     if ( panelClosedTradeCount >= 1000 )   break;
     
   }
   closedProfitByStrategy[currentStrategyIndex] = closedProfitAccumulator;
   displayClosedProfit = closedProfitAccumulator;
 }
 ObjectSetString(0,"linetp" + IntegerToString(0,0,32),OBJPROP_TEXT,"Total P/L so far: " + DoubleToString(NormalizeDouble(displayClosedProfit,2),2));
 if ( EnableNFP_Filter )
 {
   ObjectSetString(0,"linenfp" + IntegerToString(0,0,32),OBJPROP_TEXT,GetNextNFPText());
 }
 if ( OnlyUp )
 {
   ObjectSetString(0,"lineup" + IntegerToString(0,0,32),OBJPROP_TEXT,"Highest Balance: " + DoubleToString(NormalizeDouble(highestBalanceBasis,2),2));
 }
 }
// UpdateInfoPanelTotals
 int CountWinningClosedTrades( int legacyUnusedStartIndex,int maximumTradesToScan)
 {
  double    tradeNetProfit;
  int       eligibleTradeCount;
  int       winningTradeCount;
  int       historyScanIndex;
//----------------------------------------------------------------------
 long        magicCheck01;
 long        magicCheck02;
 long        magicCheck03;
 long        magicCheck04;
 long        magicCheck05;
 long        magicCheck06;
 long        magicCheck07;
 long        magicCheck08;
 long        magicCheck09;
 long        magicCheck10;
 long        magicCheck11;
 long        magicCheck12;
 long        magicCheck13;
 long        magicCheck14;
 long        magicCheck15;
 long        magicCheck16;

 if ( MQLInfoInteger(MQL_TESTER) == 1 && !(UpdateInfoTesting) )
 {
   return(0); 
 }
 tradeNetProfit = 0.0 ;
 eligibleTradeCount = 0 ;
 winningTradeCount = 0 ;
 for (historyScanIndex = ClosedTradeCount() ; historyScanIndex >= 0 ; historyScanIndex --)
 {
   if ( SelectTradeRecord(historyScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_HISTORY) != true )   continue;
   
   if ( ( SelectedTradeSymbol() != currentSymbol && !(oneChartSetupEnabled) ) )   continue;
   magicCheck01 = SelectedTradeMagic();
   magicCheck02=ST1_MagicNumber + 1;
   if ( magicCheck01 != magicCheck02 )
   {
     magicCheck02 = SelectedTradeMagic();
     magicCheck03=ST1_MagicNumber + 2;
     if ( magicCheck02 != magicCheck03 )
     {
       magicCheck03 = SelectedTradeMagic();
       magicCheck04=ST1_MagicNumber + 3;
       if ( magicCheck03 != magicCheck04 )
       {
         magicCheck04 = SelectedTradeMagic();
         magicCheck05=ST1_MagicNumber + 4;
         if ( magicCheck04 != magicCheck05 )
         {
           magicCheck05 = SelectedTradeMagic();
           magicCheck06=ST1_MagicNumber + 5;
           if ( magicCheck05 != magicCheck06 )
           {
             magicCheck06 = SelectedTradeMagic();
             magicCheck07=ST1_MagicNumber + 6;
             if ( magicCheck06 != magicCheck07 )
             {
               magicCheck07 = SelectedTradeMagic();
               magicCheck08=ST1_MagicNumber + 7;
               if ( magicCheck07 != magicCheck08 )
               {
                 magicCheck08 = SelectedTradeMagic();
                 magicCheck09=ST1_MagicNumber + 8;
                 if ( magicCheck08 != magicCheck09 )
                 {
                   magicCheck09 = SelectedTradeMagic();
                   magicCheck10=ST1_MagicNumber + 9;
                   if ( magicCheck09 != magicCheck10 )
                   {
                     magicCheck10 = SelectedTradeMagic();
                     magicCheck11=ST1_MagicNumber + 10;
                     if ( magicCheck10 != magicCheck11 )
                     {
                       magicCheck11 = SelectedTradeMagic();
                       magicCheck12=ST1_MagicNumber + 11;
                       if ( magicCheck11 != magicCheck12 )
                       {
                         magicCheck12 = SelectedTradeMagic();
                         magicCheck13=ST1_MagicNumber + 12;
                         if ( magicCheck12 != magicCheck13 )
                         {
                           magicCheck13 = SelectedTradeMagic();
                           magicCheck14=ST1_MagicNumber + 13;
                           if ( magicCheck13 != magicCheck14 )
                           {
                             magicCheck14 = SelectedTradeMagic();
                             magicCheck15=ST1_MagicNumber + 14;
                             if ( magicCheck14 != magicCheck15 )
                             {
                               magicCheck15 = SelectedTradeMagic();
                               magicCheck16=ST1_MagicNumber + 15;
                             if ( magicCheck15 != magicCheck16 )   continue;
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
   eligibleTradeCount ++;
   if ( ( SelectedTradeType() == ORDER_TYPE_BUY || SelectedTradeType() == ORDER_TYPE_SELL ) )
   {
     if ( SelectedTradeType() == ORDER_TYPE_BUY )
     {
       tradeNetProfit = SelectedTradeClosePrice() - SelectedTradeOpenPrice() ;
     }
     else
     {
       if ( SelectedTradeType() == ORDER_TYPE_SELL )
       {
         tradeNetProfit = SelectedTradeOpenPrice() - SelectedTradeClosePrice() ;
       }
     }
     if ( tradeNetProfit>0.0 )
     {
       winningTradeCount ++;
     }
   }
   if ( eligibleTradeCount >= maximumTradesToScan )   break;
   
 }
 winningTradesByStrategy[currentStrategyIndex] = winningTradeCount;
 return(winningTradeCount); 
 }
// CountWinningClosedTrades
 int CountLosingClosedTrades( int legacyUnusedStartIndex,int maximumTradesToScan)
 {
  double    tradeNetProfit;
  int       eligibleTradeCount;
  int       losingTradeCount;
  int       historyScanIndex;
//----------------------------------------------------------------------
 long        magicCheck01;
 long        magicCheck02;
 long        magicCheck03;
 long        magicCheck04;
 long        magicCheck05;
 long        magicCheck06;
 long        magicCheck07;
 long        magicCheck08;
 long        magicCheck09;
 long        magicCheck10;
 long        magicCheck11;
 long        magicCheck12;
 long        magicCheck13;
 long        magicCheck14;
 long        magicCheck15;
 long        magicCheck16;

 if ( MQLInfoInteger(MQL_TESTER) == 1 && !(UpdateInfoTesting) )
 {
   return(0); 
 }
 tradeNetProfit = 0.0 ;
 eligibleTradeCount = 0 ;
 losingTradeCount = 0 ;
 for (historyScanIndex = ClosedTradeCount() ; historyScanIndex >= 0 ; historyScanIndex --)
 {
   if ( SelectTradeRecord(historyScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_HISTORY) != true )   continue;
   
   if ( ( SelectedTradeSymbol() != currentSymbol && !(oneChartSetupEnabled) ) )   continue;
   magicCheck01 = SelectedTradeMagic();
   magicCheck02=ST1_MagicNumber + 1;
   if ( magicCheck01 != magicCheck02 )
   {
     magicCheck02 = SelectedTradeMagic();
     magicCheck03=ST1_MagicNumber + 2;
     if ( magicCheck02 != magicCheck03 )
     {
       magicCheck03 = SelectedTradeMagic();
       magicCheck04=ST1_MagicNumber + 3;
       if ( magicCheck03 != magicCheck04 )
       {
         magicCheck04 = SelectedTradeMagic();
         magicCheck05=ST1_MagicNumber + 4;
         if ( magicCheck04 != magicCheck05 )
         {
           magicCheck05 = SelectedTradeMagic();
           magicCheck06=ST1_MagicNumber + 5;
           if ( magicCheck05 != magicCheck06 )
           {
             magicCheck06 = SelectedTradeMagic();
             magicCheck07=ST1_MagicNumber + 6;
             if ( magicCheck06 != magicCheck07 )
             {
               magicCheck07 = SelectedTradeMagic();
               magicCheck08=ST1_MagicNumber + 7;
               if ( magicCheck07 != magicCheck08 )
               {
                 magicCheck08 = SelectedTradeMagic();
                 magicCheck09=ST1_MagicNumber + 8;
                 if ( magicCheck08 != magicCheck09 )
                 {
                   magicCheck09 = SelectedTradeMagic();
                   magicCheck10=ST1_MagicNumber + 9;
                   if ( magicCheck09 != magicCheck10 )
                   {
                     magicCheck10 = SelectedTradeMagic();
                     magicCheck11=ST1_MagicNumber + 10;
                     if ( magicCheck10 != magicCheck11 )
                     {
                       magicCheck11 = SelectedTradeMagic();
                       magicCheck12=ST1_MagicNumber + 11;
                       if ( magicCheck11 != magicCheck12 )
                       {
                         magicCheck12 = SelectedTradeMagic();
                         magicCheck13=ST1_MagicNumber + 12;
                         if ( magicCheck12 != magicCheck13 )
                         {
                           magicCheck13 = SelectedTradeMagic();
                           magicCheck14=ST1_MagicNumber + 13;
                           if ( magicCheck13 != magicCheck14 )
                           {
                             magicCheck14 = SelectedTradeMagic();
                             magicCheck15=ST1_MagicNumber + 14;
                             if ( magicCheck14 != magicCheck15 )
                             {
                               magicCheck15 = SelectedTradeMagic();
                               magicCheck16=ST1_MagicNumber + 15;
                             if ( magicCheck15 != magicCheck16 )   continue;
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
   eligibleTradeCount ++;
   if ( SelectedTradeType() == ORDER_TYPE_BUY )
   {
     tradeNetProfit = SelectedTradeClosePrice() - SelectedTradeOpenPrice() ;
   }
   else
   {
     if ( SelectedTradeType() == ORDER_TYPE_SELL )
     {
       tradeNetProfit = SelectedTradeOpenPrice() - SelectedTradeClosePrice() ;
     }
   }
   if ( tradeNetProfit<0.0 )
   {
     losingTradeCount ++;
   }
   if ( eligibleTradeCount >= maximumTradesToScan )   break;
   
 }
 losingTradesByStrategy[currentStrategyIndex] = losingTradeCount;
 return(losingTradeCount); 
 }
//CountLosingClosedTrades <<==--------   --------
 void CalculateStrategyPerformance()
 {
  int       unusedStrategyCounter = 0;
  double    lookbackProfitByStrategy[99];
  double    recentWindowProfitByStrategy[99];
  int       strategyResetIndex;
  int       historyScanIndex;
  bool      allStrategiesComplete;
  int       completionCheckIndex;
  double    profitNormalizationFactor;
  int       symbolStrategyIndex;
  int       resultStrategyIndex;
//----------------------------------------------------------------------
 long       orderCloseTime;
 long       lookbackCutoffTime;
 long       lookbackCutoffConfirmation;
 long       recentOrderCloseTime;
 long       recentCutoffTime;

 if ( ( MQLInfoInteger(MQL_TESTER) == 1 && !(UpdateInfoTesting) ) )   return;
 for (strategyResetIndex = 0 ; strategyResetIndex < strategySymbolCount ; strategyResetIndex ++)
 {
   lookbackProfitByStrategy[strategyResetIndex] = 0.0;
   recentWindowProfitByStrategy[strategyResetIndex] = 0.0;
   performanceHistoryComplete[strategyResetIndex] = false;
   totalTradeCountByStrategy[strategyResetIndex] = 0;
   recentTradeCountByStrategy[strategyResetIndex] = 0;
 }
 for (historyScanIndex = ClosedTradeCount() ; historyScanIndex >= 0 ; historyScanIndex --)
 {
   if ( SelectTradeRecord(historyScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_HISTORY) != true || SelectedTradeMagic() != strategyMagicNumber )   continue;
   allStrategiesComplete = true ;
   for (completionCheckIndex = 0 ; completionCheckIndex < strategySymbolCount ; completionCheckIndex ++)
   {
     if ( !(performanceHistoryComplete[completionCheckIndex]) )
     {
       allStrategiesComplete = false ;
     }
   }
   if ( ( SelectedTradeCloseTime() <  TimeCurrent() - performanceLookbackDays * 24 * 60 * 60 && allStrategiesComplete ) )   break;
   profitNormalizationFactor = SelectedTradeVolume() * 100.0 ;
   if ( performanceCalculationMode == 1 )
   {
     profitNormalizationFactor = 1.0 ;
   }
   symbolStrategyIndex = 0 ;
   if ( strategySymbolCount <= 0 )   continue;
   
   for ( ; symbolStrategyIndex < strategySymbolCount ; symbolStrategyIndex ++)
   {
     if ( strategySymbols[symbolStrategyIndex] != SelectedTradeSymbol() )   continue;
     
     if ( ( SelectedTradeType() != ORDER_TYPE_BUY && SelectedTradeType() != ORDER_TYPE_SELL ) )   continue;
     orderCloseTime = SelectedTradeCloseTime();
     lookbackCutoffTime=TimeCurrent() - performanceLookbackDays * 24 * 60 * 60;
     if ( orderCloseTime <  lookbackCutoffTime )
     {
       lookbackCutoffTime = SelectedTradeCloseTime();
       lookbackCutoffConfirmation=TimeCurrent() - performanceLookbackDays * 24 * 60 * 60;
     if ( (lookbackCutoffTime >= lookbackCutoffConfirmation || performanceHistoryComplete[symbolStrategyIndex]) )   continue;
     }
     totalTradeCountByStrategy[symbolStrategyIndex] ++;
     if ( totalTradeCountByStrategy[symbolStrategyIndex] >= minTradesForPerformance )
     {
       performanceHistoryComplete[symbolStrategyIndex] = true;
     }
     lookbackProfitByStrategy[symbolStrategyIndex] +=SelectedTradeProfit() / profitNormalizationFactor;
     lookbackProfitByStrategy[symbolStrategyIndex] +=SelectedTradeSwap() / profitNormalizationFactor;
     lookbackProfitByStrategy[symbolStrategyIndex] +=SelectedTradeCommission() / profitNormalizationFactor;
     recentOrderCloseTime = SelectedTradeCloseTime();
     recentCutoffTime=TimeCurrent() - recentPerformanceDays * 24 * 60 * 60;
     if ( recentOrderCloseTime < recentCutoffTime )   continue;
     recentWindowProfitByStrategy[symbolStrategyIndex] +=SelectedTradeProfit() / profitNormalizationFactor;
     recentWindowProfitByStrategy[symbolStrategyIndex] +=SelectedTradeSwap() / profitNormalizationFactor;
     recentWindowProfitByStrategy[symbolStrategyIndex] +=SelectedTradeCommission() / profitNormalizationFactor;
     recentTradeCountByStrategy[symbolStrategyIndex] ++;
     
   }
   
 }
 for (resultStrategyIndex = 0 ; resultStrategyIndex < strategySymbolCount ; resultStrategyIndex ++)
 {
   totalProfitByStrategy[resultStrategyIndex] = lookbackProfitByStrategy[resultStrategyIndex];
   if ( totalTradeCountByStrategy[resultStrategyIndex] >  0 )
   {
     averageProfitByStrategy[resultStrategyIndex] = NormalizeDouble(lookbackProfitByStrategy[resultStrategyIndex] / totalTradeCountByStrategy[resultStrategyIndex],2);
   }
   else
   {
     averageProfitByStrategy[resultStrategyIndex] = 0.0;
   }
   recentProfitByStrategy[resultStrategyIndex] = recentWindowProfitByStrategy[resultStrategyIndex];
   if ( recentTradeCountByStrategy[resultStrategyIndex] >  0 )
   {
     recentAverageProfitByStrategy[resultStrategyIndex] = NormalizeDouble(recentWindowProfitByStrategy[resultStrategyIndex] / recentTradeCountByStrategy[resultStrategyIndex],2);
   }
   else
   {
     recentAverageProfitByStrategy[resultStrategyIndex] = 0.0;
   }
 }
 }
//CalculateStrategyPerformance <<==--------   --------
 void RankStrategiesByTotalProfit()
 {
  int       strategyIndex;
  double    strategyMetric;
  int       computedRank;
  int       comparisonIndex;
  int       duplicateCheckStrategy;
  int       originalRank;
  bool      rankCollisionFound;
  int       rankCollisionScanIndex;
  int       weightResetIndex;
  int       rankPosition;
  int       strategyLookupIndex;
//----------------------------------------------------------------------

 CalculateStrategyPerformance(); 
 for (strategyIndex = 0 ; strategyIndex < strategySymbolCount ; strategyIndex ++)
 {
   strategyMetric = totalProfitByStrategy[strategyIndex] ;
   computedRank = 1 ;
   for (comparisonIndex = 0 ; comparisonIndex < strategySymbolCount ; comparisonIndex ++)
   {
     if ( comparisonIndex == strategyIndex || !(totalProfitByStrategy[comparisonIndex]>strategyMetric) )   continue;
     computedRank ++;
     
   }
   strategyRanks[strategyIndex] = computedRank;
 }
 for (duplicateCheckStrategy = 0 ; duplicateCheckStrategy < strategySymbolCount ; duplicateCheckStrategy ++)
 {
   originalRank = strategyRanks[duplicateCheckStrategy] ;
   rankCollisionFound = true ;
   do
   {
     rankCollisionFound = false ;
     rankCollisionScanIndex = 0 ;
     if ( strategySymbolCount <= 0 )   continue;
     
     for ( ; rankCollisionScanIndex < strategySymbolCount ; rankCollisionScanIndex ++)
     {
       if ( rankCollisionScanIndex == duplicateCheckStrategy || strategyRanks[rankCollisionScanIndex] != strategyRanks[duplicateCheckStrategy] )   continue;
       strategyRanks[rankCollisionScanIndex] ++;
       rankCollisionFound = true ;
       
     }
     
   }
   while(rankCollisionFound);
   
 }
 for (weightResetIndex = 0 ; weightResetIndex < strategySymbolCount ; weightResetIndex ++)
 {
   strategyLotWeights[weightResetIndex] = 1.0;
 }
 for (rankPosition = 1 ; rankPosition <= strategySymbolCount ; rankPosition ++)
 {
   for (strategyLookupIndex = 0 ; strategyLookupIndex < strategySymbolCount ; strategyLookupIndex ++)
   {
     if ( strategyRanks[strategyLookupIndex] == rankPosition )
     {
       rankedStrategyIndexes[rankPosition - 1] = strategyLookupIndex;
     }
   }
 }
 }
//RankStrategiesByTotalProfit <<==--------   --------
 void RankStrategiesByAverageProfit()
 {
  int       strategyIndex;
  double    strategyMetric;
  int       computedRank;
  int       comparisonIndex;
  int       duplicateCheckStrategy;
  int       originalRank;
  bool      rankCollisionFound;
  int       rankCollisionScanIndex;
  int       weightResetIndex;
  int       rankPosition;
  int       strategyLookupIndex;
//----------------------------------------------------------------------

 CalculateStrategyPerformance(); 
 for (strategyIndex = 0 ; strategyIndex < strategySymbolCount ; strategyIndex ++)
 {
   strategyMetric = averageProfitByStrategy[strategyIndex] ;
   computedRank = 1 ;
   for (comparisonIndex = 0 ; comparisonIndex < strategySymbolCount ; comparisonIndex ++)
   {
     if ( comparisonIndex == strategyIndex || !(averageProfitByStrategy[comparisonIndex]>strategyMetric) )   continue;
     computedRank ++;
     
   }
   strategyRanks[strategyIndex] = computedRank;
 }
 for (duplicateCheckStrategy = 0 ; duplicateCheckStrategy < strategySymbolCount ; duplicateCheckStrategy ++)
 {
   originalRank = strategyRanks[duplicateCheckStrategy] ;
   rankCollisionFound = true ;
   do
   {
     rankCollisionFound = false ;
     rankCollisionScanIndex = 0 ;
     if ( strategySymbolCount <= 0 )   continue;
     
     for ( ; rankCollisionScanIndex < strategySymbolCount ; rankCollisionScanIndex ++)
     {
       if ( rankCollisionScanIndex == duplicateCheckStrategy || strategyRanks[rankCollisionScanIndex] != strategyRanks[duplicateCheckStrategy] )   continue;
       strategyRanks[rankCollisionScanIndex] ++;
       rankCollisionFound = true ;
       
     }
     
   }
   while(rankCollisionFound);
   
 }
 for (weightResetIndex = 0 ; weightResetIndex < strategySymbolCount ; weightResetIndex ++)
 {
   strategyLotWeights[weightResetIndex] = 1.0;
 }
 for (rankPosition = 1 ; rankPosition <= strategySymbolCount ; rankPosition ++)
 {
   for (strategyLookupIndex = 0 ; strategyLookupIndex < strategySymbolCount ; strategyLookupIndex ++)
   {
     if ( strategyRanks[strategyLookupIndex] == rankPosition )
     {
       rankedStrategyIndexes[rankPosition - 1] = strategyLookupIndex;
     }
   }
 }
 }
//RankStrategiesByAverageProfit <<==--------   --------
 double ConvertUsdToAccountCurrency( double amountUsd)
 {
  double    convertedAmount;
  string    conversionSymbol;
//----------------------------------------------------------------------

 convertedAmount = amountUsd ;
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "USD" || AccountInfoString(ACCOUNT_CURRENCY) == "usd" ) )
 {
   convertedAmount = amountUsd ;
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "EUR" || AccountInfoString(ACCOUNT_CURRENCY) == "eur" ) )
 {
   conversionSymbol="EURUSD" + symbolSuffix;
   if ( iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     convertedAmount = amountUsd / iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "GBP" || AccountInfoString(ACCOUNT_CURRENCY) == "gbp" ) )
 {
   conversionSymbol="GBPUSD" + symbolSuffix;
   if ( iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     convertedAmount = amountUsd / iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "AUD" || AccountInfoString(ACCOUNT_CURRENCY) == "aud" ) )
 {
   conversionSymbol="AUDUSD" + symbolSuffix;
   if ( iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     convertedAmount = amountUsd / iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "JPY" || AccountInfoString(ACCOUNT_CURRENCY) == "jpy" || AccountInfoString(ACCOUNT_CURRENCY) == "YEN" || AccountInfoString(ACCOUNT_CURRENCY) == "yen" ) )
 {
   conversionSymbol="USDJPY" + symbolSuffix;
   if ( iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     convertedAmount = amountUsd * iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "CHF" || AccountInfoString(ACCOUNT_CURRENCY) == "chf" ) )
 {
   conversionSymbol="USDCHF" + symbolSuffix;
   if ( iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     convertedAmount = amountUsd * iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "HKD" || AccountInfoString(ACCOUNT_CURRENCY) == "hkd" ) )
 {
   conversionSymbol="USDHKD" + symbolSuffix;
   if ( iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     convertedAmount = amountUsd * iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "SGD" || AccountInfoString(ACCOUNT_CURRENCY) == "sgd" ) )
 {
   conversionSymbol="USDSGD" + symbolSuffix;
   if ( iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     convertedAmount = amountUsd * iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "PLN" || AccountInfoString(ACCOUNT_CURRENCY) == "pln" ) )
 {
   conversionSymbol="USDPLN" + symbolSuffix;
   if ( iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     convertedAmount = amountUsd * iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "RUB" || AccountInfoString(ACCOUNT_CURRENCY) == "rub" ) )
 {
   conversionSymbol="USDRUB" + symbolSuffix;
   if ( iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     convertedAmount = amountUsd * iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "BTC" || AccountInfoString(ACCOUNT_CURRENCY) == "btc" ) )
 {
   conversionSymbol="BTCUSD" + symbolSuffix;
   if ( iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     convertedAmount = amountUsd / iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "ETH" || AccountInfoString(ACCOUNT_CURRENCY) == "eth" ) )
 {
   conversionSymbol="ETHUSD" + symbolSuffix;
   if ( iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     convertedAmount = amountUsd / iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "BCH" || AccountInfoString(ACCOUNT_CURRENCY) == "bch" ) )
 {
   conversionSymbol="BCHUSD" + symbolSuffix;
   if ( iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     convertedAmount = amountUsd / iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "BCC" || AccountInfoString(ACCOUNT_CURRENCY) == "bcc" ) )
 {
   conversionSymbol="BCCUSD" + symbolSuffix;
   if ( iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     convertedAmount = amountUsd / iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "XRP" || AccountInfoString(ACCOUNT_CURRENCY) == "xrp" ) )
 {
   conversionSymbol="XRPUSD" + symbolSuffix;
   if ( iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     convertedAmount = amountUsd / iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "LTC" || AccountInfoString(ACCOUNT_CURRENCY) == "ltc" ) )
 {
   conversionSymbol="LTCUSD" + symbolSuffix;
   if ( iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     convertedAmount = amountUsd / iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "XMR" || AccountInfoString(ACCOUNT_CURRENCY) == "xmr" ) )
 {
   conversionSymbol="XMRUSD" + symbolSuffix;
   if ( iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     convertedAmount = amountUsd / iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "DSH" || AccountInfoString(ACCOUNT_CURRENCY) == "dsh" ) )
 {
   conversionSymbol="DSHUSD" + symbolSuffix;
   if ( iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     convertedAmount = amountUsd / iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "EOS" || AccountInfoString(ACCOUNT_CURRENCY) == "eos" ) )
 {
   conversionSymbol="EOSUSD" + symbolSuffix;
   if ( iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     convertedAmount = amountUsd / iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "TRX" || AccountInfoString(ACCOUNT_CURRENCY) == "trx" ) )
 {
   conversionSymbol="TRXUSD" + symbolSuffix;
   if ( iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     convertedAmount = amountUsd / iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "ADA" || AccountInfoString(ACCOUNT_CURRENCY) == "ada" ) )
 {
   conversionSymbol="ADAUSD" + symbolSuffix;
   if ( iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     convertedAmount = amountUsd / iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "BSV" || AccountInfoString(ACCOUNT_CURRENCY) == "bsv" ) )
 {
   conversionSymbol="BSVUSD" + symbolSuffix;
   if ( iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     convertedAmount = amountUsd / iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "XLM" || AccountInfoString(ACCOUNT_CURRENCY) == "xlm" ) )
 {
   conversionSymbol="XLMUSD" + symbolSuffix;
   if ( iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     convertedAmount = amountUsd / iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "GLD" || AccountInfoString(ACCOUNT_CURRENCY) == "gld" ) )
 {
   conversionSymbol="GLDUSD" + symbolSuffix;
   if ( iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     convertedAmount = amountUsd / iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "ZEC" || AccountInfoString(ACCOUNT_CURRENCY) == "zec" ) )
 {
   conversionSymbol="ZECUSD" + symbolSuffix;
   if ( iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     convertedAmount = amountUsd / iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "XEM" || AccountInfoString(ACCOUNT_CURRENCY) == "xem" ) )
 {
   conversionSymbol="XEMUSD" + symbolSuffix;
   if ( iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     convertedAmount = amountUsd / iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 return(convertedAmount); 
 }
//ConvertUsdToAccountCurrency <<==--------   --------
 double ConvertAccountCurrencyToUsdRounded( double accountCurrencyAmount)
 {
  double    convertedAmountUsd;
  string    conversionSymbol;
//----------------------------------------------------------------------

 convertedAmountUsd = accountCurrencyAmount ;
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "USD" || AccountInfoString(ACCOUNT_CURRENCY) == "usd" ) )
 {
   convertedAmountUsd = accountCurrencyAmount ;
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "EUR" || AccountInfoString(ACCOUNT_CURRENCY) == "eur" ) )
 {
   conversionSymbol="EURUSD" + symbolSuffix;
   if ( iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     convertedAmountUsd = accountCurrencyAmount * iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "GBP" || AccountInfoString(ACCOUNT_CURRENCY) == "gbp" ) )
 {
   conversionSymbol="GBPUSD" + symbolSuffix;
   if ( iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     convertedAmountUsd = accountCurrencyAmount * iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "AUD" || AccountInfoString(ACCOUNT_CURRENCY) == "aud" ) )
 {
   conversionSymbol="AUDUSD" + symbolSuffix;
   if ( iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     convertedAmountUsd = accountCurrencyAmount * iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "JPY" || AccountInfoString(ACCOUNT_CURRENCY) == "jpy" || AccountInfoString(ACCOUNT_CURRENCY) == "YEN" || AccountInfoString(ACCOUNT_CURRENCY) == "yen" ) )
 {
   conversionSymbol="USDJPY" + symbolSuffix;
   if ( iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     convertedAmountUsd = accountCurrencyAmount / iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "CHF" || AccountInfoString(ACCOUNT_CURRENCY) == "chf" ) )
 {
   conversionSymbol="USDCHF" + symbolSuffix;
   if ( iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     convertedAmountUsd = accountCurrencyAmount / iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "HKD" || AccountInfoString(ACCOUNT_CURRENCY) == "hkd" ) )
 {
   conversionSymbol="USDHKD" + symbolSuffix;
   if ( iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     convertedAmountUsd = accountCurrencyAmount / iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "RUB" || AccountInfoString(ACCOUNT_CURRENCY) == "rub" ) )
 {
   conversionSymbol="USDRUB" + symbolSuffix;
   if ( iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     convertedAmountUsd = accountCurrencyAmount / iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "CNH" || AccountInfoString(ACCOUNT_CURRENCY) == "cnh" ) )
 {
   conversionSymbol="USDCNH" + symbolSuffix;
   if ( iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     convertedAmountUsd = accountCurrencyAmount / iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
   else
   {
     conversionSymbol="USDCNY" + symbolSuffix;
     if ( iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
     {
       convertedAmountUsd = accountCurrencyAmount / iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
     }
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "CNY" || AccountInfoString(ACCOUNT_CURRENCY) == "cny" ) )
 {
   conversionSymbol="USDCNH" + symbolSuffix;
   if ( iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     convertedAmountUsd = accountCurrencyAmount / iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
   else
   {
     conversionSymbol="USDCNY" + symbolSuffix;
     if ( iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
     {
       convertedAmountUsd = accountCurrencyAmount / iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
     }
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "SGD" || AccountInfoString(ACCOUNT_CURRENCY) == "sgd" ) )
 {
   conversionSymbol="USDSGD" + symbolSuffix;
   if ( iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     convertedAmountUsd = accountCurrencyAmount / iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "BTC" || AccountInfoString(ACCOUNT_CURRENCY) == "btc" ) )
 {
   conversionSymbol="BTCUSD" + symbolSuffix;
   if ( iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     convertedAmountUsd = accountCurrencyAmount * iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "ETH" || AccountInfoString(ACCOUNT_CURRENCY) == "eth" ) )
 {
   conversionSymbol="ETHUSD" + symbolSuffix;
   if ( iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     convertedAmountUsd = accountCurrencyAmount * iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "BCH" || AccountInfoString(ACCOUNT_CURRENCY) == "bch" ) )
 {
   conversionSymbol="BCHUSD" + symbolSuffix;
   if ( iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     convertedAmountUsd = accountCurrencyAmount * iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "BCC" || AccountInfoString(ACCOUNT_CURRENCY) == "bcc" ) )
 {
   conversionSymbol="BCCUSD" + symbolSuffix;
   if ( iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     convertedAmountUsd = accountCurrencyAmount * iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "XRP" || AccountInfoString(ACCOUNT_CURRENCY) == "xrp" ) )
 {
   conversionSymbol="XRPUSD" + symbolSuffix;
   if ( iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     convertedAmountUsd = accountCurrencyAmount * iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "LTC" || AccountInfoString(ACCOUNT_CURRENCY) == "ltc" ) )
 {
   conversionSymbol="LTCUSD" + symbolSuffix;
   if ( iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     convertedAmountUsd = accountCurrencyAmount * iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "XMR" || AccountInfoString(ACCOUNT_CURRENCY) == "xmr" ) )
 {
   conversionSymbol="XMRUSD" + symbolSuffix;
   if ( iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     convertedAmountUsd = accountCurrencyAmount * iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "DSH" || AccountInfoString(ACCOUNT_CURRENCY) == "dsh" ) )
 {
   conversionSymbol="DSHUSD" + symbolSuffix;
   if ( iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     convertedAmountUsd = accountCurrencyAmount * iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "EOS" || AccountInfoString(ACCOUNT_CURRENCY) == "eos" ) )
 {
   conversionSymbol="EOSUSD" + symbolSuffix;
   if ( iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     convertedAmountUsd = accountCurrencyAmount * iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "TRX" || AccountInfoString(ACCOUNT_CURRENCY) == "trx" ) )
 {
   conversionSymbol="TRXUSD" + symbolSuffix;
   if ( iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     convertedAmountUsd = accountCurrencyAmount * iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "ADA" || AccountInfoString(ACCOUNT_CURRENCY) == "ada" ) )
 {
   conversionSymbol="ADAUSD" + symbolSuffix;
   if ( iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     convertedAmountUsd = accountCurrencyAmount * iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "BSV" || AccountInfoString(ACCOUNT_CURRENCY) == "bsv" ) )
 {
   conversionSymbol="BSVUSD" + symbolSuffix;
   if ( iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     convertedAmountUsd = accountCurrencyAmount * iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "XLM" || AccountInfoString(ACCOUNT_CURRENCY) == "xlm" ) )
 {
   conversionSymbol="XLMUSD" + symbolSuffix;
   if ( iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     convertedAmountUsd = accountCurrencyAmount * iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "GLD" || AccountInfoString(ACCOUNT_CURRENCY) == "gld" ) )
 {
   conversionSymbol="GLDUSD" + symbolSuffix;
   if ( iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     convertedAmountUsd = accountCurrencyAmount * iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "ZEC" || AccountInfoString(ACCOUNT_CURRENCY) == "zec" ) )
 {
   conversionSymbol="ZECUSD" + symbolSuffix;
   if ( iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     convertedAmountUsd = accountCurrencyAmount * iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "XEM" || AccountInfoString(ACCOUNT_CURRENCY) == "xem" ) )
 {
   conversionSymbol="XEMUSD" + symbolSuffix;
   if ( iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     convertedAmountUsd = accountCurrencyAmount * iClose(conversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 return(MathRound(convertedAmountUsd)); 
 }
//ConvertAccountCurrencyToUsdRounded <<==--------   --------
 void LoadStrategy1Profile()
 {
 double     profileScratchValue01;
 double     profileScratchValue02;
 double     profileScratchValue03;
 double     profileScratchValue04;
 double     profileScratchValue05;
 double     profileScratchValue06;
 double     profileScratchValue07;
 double     profileScratchValue08;
 double     profileScratchValue09;
 double     profileScratchValue10;
 double     profileScratchValue11;
 double     profileScratchValue12;

 signalTimeframeMinutes = 1440 ;
 entryTimingTimeframeMinutes = 15 ;
 swingLeftBars = 24 ;
 swingRightBars = 3 ;
 entryLookbackBars = 105 ;
 minEntryDistancePips = 45.0 ;
 minimumEntryDistancePercent = 0.0 ;
 profileScratchValue01 = AdjustEntry + -275.0;
 if ( Randomization>0.0 )
 {
   profileScratchValue02 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue02 = 0.0;
 }
 buyEntryOffsetPips = profileScratchValue01 + profileScratchValue02 ;
 profileScratchValue02 = AdjustEntry + -160.0;
 if ( Randomization>0.0 )
 {
   profileScratchValue03 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue03 = 0.0;
 }
 sellEntryOffsetPips = profileScratchValue02 + profileScratchValue03 ;
 maxPendingOrders = 5 ;
 duplicatePendingTolerancePips = 30.0 ;
 pendingExpirationHours = 35 ;
 exitTimingMode = 1 ;
 profileScratchValue03 = AdjustSL + 6100.0;
 if ( Randomization>0.0 )
 {
   profileScratchValue04 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue04 = 0.0;
 }
 stopLossPips = profileScratchValue03 + profileScratchValue04 ;
 profileScratchValue04 = AdjustTP + 1450.0;
 if ( Randomization>0.0 )
 {
   profileScratchValue05 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue05 = 0.0;
 }
 takeProfitPips = profileScratchValue04 + profileScratchValue05 ;
 profileScratchValue05 = AdjustTrailSL + 1800.0;
 if ( Randomization>0.0 )
 {
   profileScratchValue06 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue06 = 0.0;
 }
 trailingSLStartPips = profileScratchValue05 + profileScratchValue06 ;
 if ( Randomization>0.0 )
 {
   profileScratchValue07 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue07 = 0.0;
 }
 trailingSLDistancePips = profileScratchValue07 + 1800.0 ;
 if ( Randomization>0.0 )
 {
   profileScratchValue08 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue08 = 0.0;
 }
 trailingSLStepLimitPips = profileScratchValue08 + 5000.0 ;
 trailingActivationBufferPips = 0.1 ;
 trailingPartialClosePercent = 0.0 ;
 if ( Randomization>0.0 )
 {
   profileScratchValue09 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue09 = 0.0;
 }
 trailingTPDistancePips = profileScratchValue09 + 1600.0 ;
 profileScratchValue09 = AdjustTrailTP + 700.0;
 if ( Randomization>0.0 )
 {
   profileScratchValue10 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue10 = 0.0;
 }
 trailingTPStartPips = profileScratchValue09 + profileScratchValue10 ;
 if ( Randomization>0.0 )
 {
   profileScratchValue11 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue11 = 0.0;
 }
 breakEvenStartPips = profileScratchValue11 + 930.0 ;
 profileScratchValue11 = AdjustBreakEven + 120.0;
 if ( Randomization>0.0 )
 {
   profileScratchValue12 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue12 = 0.0;
 }
 breakEvenExtraPips = profileScratchValue11 + profileScratchValue12 ;
 highLowTrailingTimeframeMinutes = 60 ;
 swingQualificationMinimumShift = 50 ;
 highLowLeftBars = 14 ;
 highLowRightBars = 12 ;
 highLowLookbackBars = 300 ;
 highLowTrailingOffsetPips = 22.0 ;
 maxOpenTradesPerSide = 5 ;
 if ( !(RemoveCommentSuffix) )
 {
   currentStrategyComment=ST1_Comment + "_XAUUSD_1";
 }
 strategyMagicNumber=ST1_MagicNumber + 1;
 strategyDrawdownReferenceUsd = ConvertUsdToAccountCurrency(145.0) ;
 if ( !(UseVariableValues) )   return;
 lotSizeReferenceBalance = 2000.0 ;
 strategyDrawdownReferenceUsd = ConvertUsdToAccountCurrency(60.0) ;
 }
//LoadStrategy1Profile <<==--------   --------
 void LoadStrategy2Profile()
 {
 double     profileScratchValue01;
 double     profileScratchValue02;
 double     profileScratchValue03;
 double     profileScratchValue04;
 double     profileScratchValue05;
 double     profileScratchValue06;
 double     profileScratchValue07;
 double     profileScratchValue08;
 double     profileScratchValue09;
 double     profileScratchValue10;
 double     profileScratchValue11;
 double     profileScratchValue12;
 double     profileScratchValue13;

 signalTimeframeMinutes = 240 ;
 entryTimingTimeframeMinutes = 60 ;
 swingLeftBars = 12 ;
 swingRightBars = 8 ;
 entryLookbackBars = 90 ;
 minEntryDistancePips = 1050.0 ;
 minimumEntryDistancePercent = 0.0 ;
 profileScratchValue01 = AdjustEntry + -40.0;
 if ( Randomization>0.0 )
 {
   profileScratchValue02 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue02 = 0.0;
 }
 buyEntryOffsetPips = profileScratchValue01 + profileScratchValue02 ;
 profileScratchValue02 = AdjustEntry + -100.0;
 if ( Randomization>0.0 )
 {
   profileScratchValue03 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue03 = 0.0;
 }
 sellEntryOffsetPips = profileScratchValue02 + profileScratchValue03 ;
 maxPendingOrders = 2 ;
 duplicatePendingTolerancePips = 130.0 ;
 pendingExpirationHours = 192 ;
 exitTimingMode = 5 ;
 if ( !(UseHL_TrailingSL) )
 {
   profileScratchValue03 = AdjustSL + 700.0;
   if ( Randomization>0.0 )
   {
     profileScratchValue04 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
   }
   else
   {
     profileScratchValue04 = 0.0;
   }
   stopLossPips = profileScratchValue03 + profileScratchValue04 ;
 }
 else
 {
   profileScratchValue04 = AdjustSL + 800.0;
   if ( Randomization>0.0 )
   {
     profileScratchValue05 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
   }
   else
   {
     profileScratchValue05 = 0.0;
   }
   stopLossPips = profileScratchValue04 + profileScratchValue05 ;
 }
 profileScratchValue05 = AdjustTP + 4900.0;
 if ( Randomization>0.0 )
 {
   profileScratchValue06 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue06 = 0.0;
 }
 takeProfitPips = profileScratchValue05 + profileScratchValue06 ;
 profileScratchValue06 = AdjustTrailSL + 1300.0;
 if ( Randomization>0.0 )
 {
   profileScratchValue07 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue07 = 0.0;
 }
 trailingSLStartPips = profileScratchValue06 + profileScratchValue07 ;
 if ( Randomization>0.0 )
 {
   profileScratchValue08 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue08 = 0.0;
 }
 trailingSLDistancePips = profileScratchValue08 + 1450.0 ;
 if ( Randomization>0.0 )
 {
   profileScratchValue09 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue09 = 0.0;
 }
 trailingSLStepLimitPips = profileScratchValue09 + 2000.0 ;
 trailingActivationBufferPips = 0.1 ;
 trailingPartialClosePercent = 0.0 ;
 if ( Randomization>0.0 )
 {
   profileScratchValue10 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue10 = 0.0;
 }
 trailingTPDistancePips = profileScratchValue10 + 1400.0 ;
 profileScratchValue10 = AdjustTrailTP + 200.0;
 if ( Randomization>0.0 )
 {
   profileScratchValue11 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue11 = 0.0;
 }
 trailingTPStartPips = profileScratchValue10 + profileScratchValue11 ;
 if ( Randomization>0.0 )
 {
   profileScratchValue12 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue12 = 0.0;
 }
 breakEvenStartPips = profileScratchValue12 + 500.0 ;
 profileScratchValue12 = AdjustBreakEven + 200.0;
 if ( Randomization>0.0 )
 {
   profileScratchValue13 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue13 = 0.0;
 }
 breakEvenExtraPips = profileScratchValue12 + profileScratchValue13 ;
 highLowTrailingTimeframeMinutes = 60 ;
 swingQualificationMinimumShift = 50 ;
 highLowLeftBars = 14 ;
 highLowRightBars = 6 ;
 highLowLookbackBars = 400 ;
 highLowTrailingOffsetPips = 32.0 ;
 maxOpenTradesPerSide = 99 ;
 if ( !(RemoveCommentSuffix) )
 {
   currentStrategyComment=ST1_Comment + "_XAUUSD_4";
 }
 strategyMagicNumber=ST1_MagicNumber + 2;
 strategyDrawdownReferenceUsd = ConvertUsdToAccountCurrency(57.0) ;
 if ( !(UseVariableValues) )   return;
 lotSizeReferenceBalance = 1600.0 ;
 strategyDrawdownReferenceUsd = ConvertUsdToAccountCurrency(52.0) ;
 }
//LoadStrategy2Profile <<==--------   --------
 void LoadStrategy3Profile()
 {
 double     profileScratchValue01;
 double     profileScratchValue02;
 double     profileScratchValue03;
 double     profileScratchValue04;
 double     profileScratchValue05;
 double     profileScratchValue06;
 double     profileScratchValue07;
 double     profileScratchValue08;
 double     profileScratchValue09;
 double     profileScratchValue10;
 double     profileScratchValue11;
 double     profileScratchValue12;

 signalTimeframeMinutes = 1440 ;
 entryTimingTimeframeMinutes = 60 ;
 swingLeftBars = 15 ;
 swingRightBars = 3 ;
 entryLookbackBars = 230 ;
 minEntryDistancePips = 550.0 ;
 minimumEntryDistancePercent = 0.0 ;
 profileScratchValue01 = AdjustEntry + -170.0;
 if ( Randomization>0.0 )
 {
   profileScratchValue02 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue02 = 0.0;
 }
 buyEntryOffsetPips = profileScratchValue01 + profileScratchValue02 ;
 profileScratchValue02 = AdjustEntry + -70.0;
 if ( Randomization>0.0 )
 {
   profileScratchValue03 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue03 = 0.0;
 }
 sellEntryOffsetPips = profileScratchValue02 + profileScratchValue03 ;
 maxPendingOrders = 1 ;
 duplicatePendingTolerancePips = 480.0 ;
 pendingExpirationHours = 480 ;
 exitTimingMode = 1 ;
 profileScratchValue03 = AdjustSL + 1000.0;
 if ( Randomization>0.0 )
 {
   profileScratchValue04 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue04 = 0.0;
 }
 stopLossPips = profileScratchValue03 + profileScratchValue04 ;
 profileScratchValue04 = AdjustTP + 4100.0;
 if ( Randomization>0.0 )
 {
   profileScratchValue05 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue05 = 0.0;
 }
 takeProfitPips = profileScratchValue04 + profileScratchValue05 ;
 profileScratchValue05 = AdjustTrailSL + 450.0;
 if ( Randomization>0.0 )
 {
   profileScratchValue06 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue06 = 0.0;
 }
 trailingSLStartPips = profileScratchValue05 + profileScratchValue06 ;
 if ( Randomization>0.0 )
 {
   profileScratchValue07 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue07 = 0.0;
 }
 trailingSLDistancePips = profileScratchValue07 + 1400.0 ;
 if ( Randomization>0.0 )
 {
   profileScratchValue08 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue08 = 0.0;
 }
 trailingSLStepLimitPips = profileScratchValue08 + 5000.0 ;
 trailingActivationBufferPips = 0.1 ;
 trailingPartialClosePercent = 0.0 ;
 if ( Randomization>0.0 )
 {
   profileScratchValue09 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue09 = 0.0;
 }
 trailingTPDistancePips = profileScratchValue09 + 1600.0 ;
 profileScratchValue09 = AdjustTrailTP + 400.0;
 if ( Randomization>0.0 )
 {
   profileScratchValue10 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue10 = 0.0;
 }
 trailingTPStartPips = profileScratchValue09 + profileScratchValue10 ;
 if ( Randomization>0.0 )
 {
   profileScratchValue11 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue11 = 0.0;
 }
 breakEvenStartPips = profileScratchValue11 + 500.0 ;
 profileScratchValue11 = AdjustBreakEven + 100.0;
 if ( Randomization>0.0 )
 {
   profileScratchValue12 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue12 = 0.0;
 }
 breakEvenExtraPips = profileScratchValue11 + profileScratchValue12 ;
 highLowTrailingTimeframeMinutes = 60 ;
 swingQualificationMinimumShift = 50 ;
 highLowLeftBars = 1 ;
 highLowRightBars = 5 ;
 highLowLookbackBars = 700 ;
 highLowTrailingOffsetPips = 22.0 ;
 maxOpenTradesPerSide = 99 ;
 if ( !(RemoveCommentSuffix) )
 {
   currentStrategyComment=ST1_Comment + "_XAUUSD_2";
 }
 strategyMagicNumber=ST1_MagicNumber + 5;
 strategyDrawdownReferenceUsd = ConvertUsdToAccountCurrency(30.0) ;
 if ( !(UseVariableValues) )   return;
 lotSizeReferenceBalance = 2000.0 ;
 strategyDrawdownReferenceUsd = ConvertUsdToAccountCurrency(30.0) ;
 }
//LoadStrategy3Profile <<==--------   --------
 void LoadStrategy4Profile()
 {
 double     profileScratchValue01;
 double     profileScratchValue02;
 double     profileScratchValue03;
 double     profileScratchValue04;
 double     profileScratchValue05;
 double     profileScratchValue06;
 double     profileScratchValue07;
 double     profileScratchValue08;
 double     profileScratchValue09;
 double     profileScratchValue10;
 double     profileScratchValue11;
 double     profileScratchValue12;
 double     profileScratchValue13;

 signalTimeframeMinutes = 1440 ;
 entryTimingTimeframeMinutes = 60 ;
 swingLeftBars = 7 ;
 swingRightBars = 2 ;
 entryLookbackBars = 20 ;
 minEntryDistancePips = 250.0 ;
 minimumEntryDistancePercent = 0.0 ;
 profileScratchValue01 = AdjustEntry + -130.0;
 if ( Randomization>0.0 )
 {
   profileScratchValue02 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue02 = 0.0;
 }
 buyEntryOffsetPips = profileScratchValue01 + profileScratchValue02 ;
 profileScratchValue02 = AdjustEntry + -120.0;
 if ( Randomization>0.0 )
 {
   profileScratchValue03 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue03 = 0.0;
 }
 sellEntryOffsetPips = profileScratchValue02 + profileScratchValue03 ;
 maxPendingOrders = 1 ;
 duplicatePendingTolerancePips = 980.0 ;
 pendingExpirationHours = 432 ;
 exitTimingMode = 1 ;
 if ( !(UseHL_TrailingSL) )
 {
   profileScratchValue03 = AdjustSL + 600.0;
   if ( Randomization>0.0 )
   {
     profileScratchValue04 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
   }
   else
   {
     profileScratchValue04 = 0.0;
   }
   stopLossPips = profileScratchValue03 + profileScratchValue04 ;
 }
 else
 {
   profileScratchValue04 = AdjustSL + 700.0;
   if ( Randomization>0.0 )
   {
     profileScratchValue05 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
   }
   else
   {
     profileScratchValue05 = 0.0;
   }
   stopLossPips = profileScratchValue04 + profileScratchValue05 ;
 }
 profileScratchValue05 = AdjustTP + 3300.0;
 if ( Randomization>0.0 )
 {
   profileScratchValue06 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue06 = 0.0;
 }
 takeProfitPips = profileScratchValue05 + profileScratchValue06 ;
 profileScratchValue06 = AdjustTrailSL + 500.0;
 if ( Randomization>0.0 )
 {
   profileScratchValue07 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue07 = 0.0;
 }
 trailingSLStartPips = profileScratchValue06 + profileScratchValue07 ;
 if ( Randomization>0.0 )
 {
   profileScratchValue08 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue08 = 0.0;
 }
 trailingSLDistancePips = profileScratchValue08 + 400.0 ;
 if ( Randomization>0.0 )
 {
   profileScratchValue09 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue09 = 0.0;
 }
 trailingSLStepLimitPips = profileScratchValue09 + 5000.0 ;
 if ( Randomization>0.0 )
 {
   profileScratchValue10 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue10 = 0.0;
 }
 trailingTPDistancePips = profileScratchValue10 + 1000.0 ;
 profileScratchValue10 = AdjustTrailTP + 2000.0;
 if ( Randomization>0.0 )
 {
   profileScratchValue11 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue11 = 0.0;
 }
 trailingTPStartPips = profileScratchValue10 + profileScratchValue11 ;
 trailingActivationBufferPips = 0.1 ;
 trailingPartialClosePercent = 0.0 ;
 if ( Randomization>0.0 )
 {
   profileScratchValue12 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue12 = 0.0;
 }
 breakEvenStartPips = profileScratchValue12 + 400.0 ;
 profileScratchValue12 = AdjustBreakEven;
 if ( Randomization>0.0 )
 {
   profileScratchValue13 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue13 = 0.0;
 }
 breakEvenExtraPips = profileScratchValue12 + profileScratchValue13 ;
 highLowTrailingTimeframeMinutes = 60 ;
 swingQualificationMinimumShift = 50 ;
 highLowLeftBars = 7 ;
 highLowRightBars = 4 ;
 highLowLookbackBars = 100 ;
 highLowTrailingOffsetPips = 0.0 ;
 maxOpenTradesPerSide = 99 ;
 if ( !(RemoveCommentSuffix) )
 {
   currentStrategyComment=ST1_Comment + "_XAUUSD_3";
 }
 strategyMagicNumber=ST1_MagicNumber + 8;
 strategyDrawdownReferenceUsd = ConvertUsdToAccountCurrency(32.0) ;
 if ( !(UseVariableValues) )   return;
 lotSizeReferenceBalance = 2000.0 ;
 strategyDrawdownReferenceUsd = ConvertUsdToAccountCurrency(35.0) ;
 }
//LoadStrategy4Profile <<==--------   --------
 void LoadStrategy5Profile()
 {
 double     profileScratchValue01;
 double     profileScratchValue02;
 double     profileScratchValue03;
 double     profileScratchValue04;
 double     profileScratchValue05;
 double     profileScratchValue06;
 double     profileScratchValue07;
 double     profileScratchValue08;
 double     profileScratchValue09;
 double     profileScratchValue10;
 double     profileScratchValue11;
 double     profileScratchValue12;

 signalTimeframeMinutes = 60 ;
 entryTimingTimeframeMinutes = 5 ;
 swingLeftBars = 26 ;
 swingRightBars = 24 ;
 entryLookbackBars = 140 ;
 minEntryDistancePips = 120.0 ;
 minimumEntryDistancePercent = 0.0 ;
 profileScratchValue01 = AdjustEntry + -115.0;
 if ( Randomization>0.0 )
 {
   profileScratchValue02 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue02 = 0.0;
 }
 buyEntryOffsetPips = profileScratchValue01 + profileScratchValue02 ;
 profileScratchValue02 = AdjustEntry + -145.0;
 if ( Randomization>0.0 )
 {
   profileScratchValue03 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue03 = 0.0;
 }
 sellEntryOffsetPips = profileScratchValue02 + profileScratchValue03 ;
 maxPendingOrders = 5 ;
 duplicatePendingTolerancePips = 55.0 ;
 pendingExpirationHours = 20 ;
 exitTimingMode = 1 ;
 profileScratchValue03 = AdjustSL + 10100.0;
 if ( Randomization>0.0 )
 {
   profileScratchValue04 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue04 = 0.0;
 }
 stopLossPips = profileScratchValue03 + profileScratchValue04 ;
 profileScratchValue04 = AdjustTP + 800.0;
 if ( Randomization>0.0 )
 {
   profileScratchValue05 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue05 = 0.0;
 }
 takeProfitPips = profileScratchValue04 + profileScratchValue05 ;
 profileScratchValue05 = AdjustTrailSL + 500.0;
 if ( Randomization>0.0 )
 {
   profileScratchValue06 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue06 = 0.0;
 }
 trailingSLStartPips = profileScratchValue05 + profileScratchValue06 ;
 if ( Randomization>0.0 )
 {
   profileScratchValue07 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue07 = 0.0;
 }
 trailingSLDistancePips = profileScratchValue07 + 1200.0 ;
 if ( Randomization>0.0 )
 {
   profileScratchValue08 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue08 = 0.0;
 }
 trailingSLStepLimitPips = profileScratchValue08 + 5000.0 ;
 trailingActivationBufferPips = 0.1 ;
 trailingPartialClosePercent = 0.0 ;
 if ( Randomization>0.0 )
 {
   profileScratchValue09 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue09 = 0.0;
 }
 trailingTPDistancePips = profileScratchValue09 + 1950.0 ;
 profileScratchValue09 = AdjustTrailTP + 350.0;
 if ( Randomization>0.0 )
 {
   profileScratchValue10 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue10 = 0.0;
 }
 trailingTPStartPips = profileScratchValue09 + profileScratchValue10 ;
 if ( Randomization>0.0 )
 {
   profileScratchValue11 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue11 = 0.0;
 }
 breakEvenStartPips = profileScratchValue11 + 330.0 ;
 profileScratchValue11 = AdjustBreakEven + 80.0;
 if ( Randomization>0.0 )
 {
   profileScratchValue12 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue12 = 0.0;
 }
 breakEvenExtraPips = profileScratchValue11 + profileScratchValue12 ;
 highLowTrailingTimeframeMinutes = 60 ;
 swingQualificationMinimumShift = 50 ;
 highLowLeftBars = 0 ;
 highLowRightBars = 0 ;
 highLowLookbackBars = 100 ;
 highLowTrailingOffsetPips = 0.0 ;
 maxOpenTradesPerSide = 5 ;
 if ( !(RemoveCommentSuffix) )
 {
   currentStrategyComment=ST1_Comment + "_XAUUSD_6";
 }
 strategyMagicNumber=ST1_MagicNumber + 9;
 strategyDrawdownReferenceUsd = ConvertUsdToAccountCurrency(348.0) ;
 if ( !(UseVariableValues) )   return;
 lotSizeReferenceBalance = 2400.0 ;
 strategyDrawdownReferenceUsd = ConvertUsdToAccountCurrency(140.0) ;
 }
//LoadStrategy5Profile <<==--------   --------
 void LoadStrategy6Profile()
 {
 double     profileScratchValue01;
 double     profileScratchValue02;
 double     profileScratchValue03;
 double     profileScratchValue04;
 double     profileScratchValue05;
 double     profileScratchValue06;
 double     profileScratchValue07;
 double     profileScratchValue08;
 double     profileScratchValue09;
 double     profileScratchValue10;
 double     profileScratchValue11;
 double     profileScratchValue12;

 signalTimeframeMinutes = 60 ;
 entryTimingTimeframeMinutes = 15 ;
 swingLeftBars = 30 ;
 swingRightBars = 19 ;
 entryLookbackBars = 110 ;
 minEntryDistancePips = 160.0 ;
 minimumEntryDistancePercent = 0.0 ;
 profileScratchValue01 = AdjustEntry + -120.0;
 if ( Randomization>0.0 )
 {
   profileScratchValue02 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue02 = 0.0;
 }
 buyEntryOffsetPips = profileScratchValue01 + profileScratchValue02 ;
 profileScratchValue02 = AdjustEntry + -110.0;
 if ( Randomization>0.0 )
 {
   profileScratchValue03 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue03 = 0.0;
 }
 sellEntryOffsetPips = profileScratchValue02 + profileScratchValue03 ;
 maxPendingOrders = 3 ;
 duplicatePendingTolerancePips = 55.0 ;
 pendingExpirationHours = 30 ;
 exitTimingMode = 1 ;
 profileScratchValue03 = AdjustSL + 5300.0;
 if ( Randomization>0.0 )
 {
   profileScratchValue04 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue04 = 0.0;
 }
 stopLossPips = profileScratchValue03 + profileScratchValue04 ;
 profileScratchValue04 = AdjustTP + 900.0;
 if ( Randomization>0.0 )
 {
   profileScratchValue05 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue05 = 0.0;
 }
 takeProfitPips = profileScratchValue04 + profileScratchValue05 ;
 profileScratchValue05 = AdjustTrailSL + 495.0;
 if ( Randomization>0.0 )
 {
   profileScratchValue06 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue06 = 0.0;
 }
 trailingSLStartPips = profileScratchValue05 + profileScratchValue06 ;
 if ( Randomization>0.0 )
 {
   profileScratchValue07 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue07 = 0.0;
 }
 trailingSLDistancePips = profileScratchValue07 + 400.0 ;
 if ( Randomization>0.0 )
 {
   profileScratchValue08 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue08 = 0.0;
 }
 trailingSLStepLimitPips = profileScratchValue08 + 5000.0 ;
 trailingActivationBufferPips = 0.1 ;
 trailingPartialClosePercent = 0.0 ;
 if ( Randomization>0.0 )
 {
   profileScratchValue09 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue09 = 0.0;
 }
 trailingTPDistancePips = profileScratchValue09 + 1900.0 ;
 profileScratchValue09 = AdjustTrailTP + 250.0;
 if ( Randomization>0.0 )
 {
   profileScratchValue10 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue10 = 0.0;
 }
 trailingTPStartPips = profileScratchValue09 + profileScratchValue10 ;
 if ( Randomization>0.0 )
 {
   profileScratchValue11 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue11 = 0.0;
 }
 breakEvenStartPips = profileScratchValue11 + 260.0 ;
 profileScratchValue11 = AdjustBreakEven + 80.0;
 if ( Randomization>0.0 )
 {
   profileScratchValue12 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue12 = 0.0;
 }
 breakEvenExtraPips = profileScratchValue11 + profileScratchValue12 ;
 highLowTrailingTimeframeMinutes = 60 ;
 swingQualificationMinimumShift = 50 ;
 highLowLeftBars = 0 ;
 highLowRightBars = 0 ;
 highLowLookbackBars = 100 ;
 highLowTrailingOffsetPips = 0.0 ;
 maxOpenTradesPerSide = 99 ;
 if ( !(RemoveCommentSuffix) )
 {
   currentStrategyComment=ST1_Comment + "_XAUUSD_5";
 }
 strategyMagicNumber=ST1_MagicNumber + 12;
 strategyDrawdownReferenceUsd = ConvertUsdToAccountCurrency(281.0) ;
 if ( !(UseVariableValues) )   return;
 lotSizeReferenceBalance = 2600.0 ;
 strategyDrawdownReferenceUsd = ConvertUsdToAccountCurrency(110.0) ;
 }
//LoadStrategy6Profile <<==--------   --------
 void LoadStrategy7Profile()
 {
 double     profileScratchValue01;
 double     profileScratchValue02;
 double     profileScratchValue03;
 double     profileScratchValue04;
 double     profileScratchValue05;
 double     profileScratchValue06;
 double     profileScratchValue07;
 double     profileScratchValue08;
 double     profileScratchValue09;
 double     profileScratchValue10;
 double     profileScratchValue11;
 double     profileScratchValue12;

 signalTimeframeMinutes = 60 ;
 entryTimingTimeframeMinutes = 15 ;
 swingLeftBars = 7 ;
 swingRightBars = 5 ;
 entryLookbackBars = 200 ;
 minEntryDistancePips = 40.0 ;
 minimumEntryDistancePercent = 0.0 ;
 profileScratchValue01 = AdjustEntry + -150.0;
 if ( Randomization>0.0 )
 {
   profileScratchValue02 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue02 = 0.0;
 }
 buyEntryOffsetPips = profileScratchValue01 + profileScratchValue02 ;
 profileScratchValue02 = AdjustEntry + -145.0;
 if ( Randomization>0.0 )
 {
   profileScratchValue03 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue03 = 0.0;
 }
 sellEntryOffsetPips = profileScratchValue02 + profileScratchValue03 ;
 maxPendingOrders = 3 ;
 duplicatePendingTolerancePips = 5.0 ;
 pendingExpirationHours = 15 ;
 exitTimingMode = 1 ;
 profileScratchValue03 = AdjustSL + 3900.0;
 if ( Randomization>0.0 )
 {
   profileScratchValue04 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue04 = 0.0;
 }
 stopLossPips = profileScratchValue03 + profileScratchValue04 ;
 profileScratchValue04 = AdjustTP + 1350.0;
 if ( Randomization>0.0 )
 {
   profileScratchValue05 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue05 = 0.0;
 }
 takeProfitPips = profileScratchValue04 + profileScratchValue05 ;
 profileScratchValue05 = AdjustTrailSL + 445.0;
 if ( Randomization>0.0 )
 {
   profileScratchValue06 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue06 = 0.0;
 }
 trailingSLStartPips = profileScratchValue05 + profileScratchValue06 ;
 if ( Randomization>0.0 )
 {
   profileScratchValue07 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue07 = 0.0;
 }
 trailingSLDistancePips = profileScratchValue07 + 355.0 ;
 if ( Randomization>0.0 )
 {
   profileScratchValue08 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue08 = 0.0;
 }
 trailingSLStepLimitPips = profileScratchValue08 + 5000.0 ;
 trailingActivationBufferPips = 0.1 ;
 trailingPartialClosePercent = 0.0 ;
 if ( Randomization>0.0 )
 {
   profileScratchValue09 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue09 = 0.0;
 }
 trailingTPDistancePips = profileScratchValue09 + 1850.0 ;
 profileScratchValue09 = AdjustTrailTP + 250.0;
 if ( Randomization>0.0 )
 {
   profileScratchValue10 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue10 = 0.0;
 }
 trailingTPStartPips = profileScratchValue09 + profileScratchValue10 ;
 if ( Randomization>0.0 )
 {
   profileScratchValue11 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue11 = 0.0;
 }
 breakEvenStartPips = profileScratchValue11 + 160.0 ;
 profileScratchValue11 = AdjustBreakEven + 50.0;
 if ( Randomization>0.0 )
 {
   profileScratchValue12 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue12 = 0.0;
 }
 breakEvenExtraPips = profileScratchValue11 + profileScratchValue12 ;
 highLowTrailingTimeframeMinutes = 60 ;
 swingQualificationMinimumShift = 50 ;
 highLowLeftBars = 1 ;
 highLowRightBars = 9 ;
 highLowLookbackBars = 1500 ;
 highLowTrailingOffsetPips = 46.0 ;
 maxOpenTradesPerSide = 99 ;
 if ( !(RemoveCommentSuffix) )
 {
   currentStrategyComment=ST1_Comment + "_XAUUSD_9";
 }
 strategyMagicNumber=ST1_MagicNumber + 13;
 strategyDrawdownReferenceUsd = ConvertUsdToAccountCurrency(968.0) ;
 if ( !(UseVariableValues) )   return;
 lotSizeReferenceBalance = 1900.0 ;
 strategyDrawdownReferenceUsd = ConvertUsdToAccountCurrency(700.0) ;
 }
//LoadStrategy7Profile <<==--------   --------
 void LoadStrategy8Profile()
 {
 double     profileScratchValue01;
 double     profileScratchValue02;
 double     profileScratchValue03;
 double     profileScratchValue04;
 double     profileScratchValue05;
 double     profileScratchValue06;
 double     profileScratchValue07;
 double     profileScratchValue08;
 double     profileScratchValue09;
 double     profileScratchValue10;
 double     profileScratchValue11;
 double     profileScratchValue12;

 signalTimeframeMinutes = 60 ;
 entryTimingTimeframeMinutes = 15 ;
 swingLeftBars = 25 ;
 swingRightBars = 23 ;
 entryLookbackBars = 145 ;
 minEntryDistancePips = 10.0 ;
 minimumEntryDistancePercent = 0.0 ;
 profileScratchValue01 = AdjustEntry + -60.0;
 if ( Randomization>0.0 )
 {
   profileScratchValue02 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue02 = 0.0;
 }
 buyEntryOffsetPips = profileScratchValue01 + profileScratchValue02 ;
 profileScratchValue02 = AdjustEntry + -145.0;
 if ( Randomization>0.0 )
 {
   profileScratchValue03 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue03 = 0.0;
 }
 sellEntryOffsetPips = profileScratchValue02 + profileScratchValue03 ;
 maxPendingOrders = 5 ;
 duplicatePendingTolerancePips = 90.0 ;
 pendingExpirationHours = 60 ;
 exitTimingMode = 1 ;
 profileScratchValue03 = AdjustSL + 2250.0;
 if ( Randomization>0.0 )
 {
   profileScratchValue04 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue04 = 0.0;
 }
 stopLossPips = profileScratchValue03 + profileScratchValue04 ;
 profileScratchValue04 = AdjustTP + 1450.0;
 if ( Randomization>0.0 )
 {
   profileScratchValue05 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue05 = 0.0;
 }
 takeProfitPips = profileScratchValue04 + profileScratchValue05 ;
 profileScratchValue05 = AdjustTrailSL + 450.0;
 if ( Randomization>0.0 )
 {
   profileScratchValue06 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue06 = 0.0;
 }
 trailingSLStartPips = profileScratchValue05 + profileScratchValue06 ;
 if ( Randomization>0.0 )
 {
   profileScratchValue07 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue07 = 0.0;
 }
 trailingSLDistancePips = profileScratchValue07 + 900.0 ;
 if ( Randomization>0.0 )
 {
   profileScratchValue08 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue08 = 0.0;
 }
 trailingSLStepLimitPips = profileScratchValue08 + 5000.0 ;
 trailingActivationBufferPips = 0.1 ;
 trailingPartialClosePercent = 0.0 ;
 if ( Randomization>0.0 )
 {
   profileScratchValue09 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue09 = 0.0;
 }
 trailingTPDistancePips = profileScratchValue09 + 2800.0 ;
 profileScratchValue09 = AdjustTrailTP + 350.0;
 if ( Randomization>0.0 )
 {
   profileScratchValue10 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue10 = 0.0;
 }
 trailingTPStartPips = profileScratchValue09 + profileScratchValue10 ;
 if ( Randomization>0.0 )
 {
   profileScratchValue11 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue11 = 0.0;
 }
 breakEvenStartPips = profileScratchValue11 + 340.0 ;
 profileScratchValue11 = AdjustBreakEven + 30.0;
 if ( Randomization>0.0 )
 {
   profileScratchValue12 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue12 = 0.0;
 }
 breakEvenExtraPips = profileScratchValue11 + profileScratchValue12 ;
 highLowTrailingTimeframeMinutes = 60 ;
 swingQualificationMinimumShift = 50 ;
 highLowLeftBars = 12 ;
 highLowRightBars = 17 ;
 highLowLookbackBars = 1000 ;
 highLowTrailingOffsetPips = 45.0 ;
 maxOpenTradesPerSide = 5 ;
 if ( !(RemoveCommentSuffix) )
 {
   currentStrategyComment=ST1_Comment + "_XAUUSD_7";
 }
 strategyMagicNumber=ST1_MagicNumber + 14;
 strategyDrawdownReferenceUsd = ConvertUsdToAccountCurrency(149.0) ;
 if ( !(UseVariableValues) )   return;
 lotSizeReferenceBalance = 2600.0 ;
 strategyDrawdownReferenceUsd = ConvertUsdToAccountCurrency(90.0) ;
 }
//LoadStrategy8Profile <<==--------   --------
 void LoadStrategy9Profile()
 {
 double     profileScratchValue01;
 double     profileScratchValue02;
 double     profileScratchValue03;
 double     profileScratchValue04;
 double     profileScratchValue05;
 double     profileScratchValue06;
 double     profileScratchValue07;
 double     profileScratchValue08;
 double     profileScratchValue09;
 double     profileScratchValue10;
 double     profileScratchValue11;
 double     profileScratchValue12;

 signalTimeframeMinutes = 60 ;
 entryTimingTimeframeMinutes = 15 ;
 swingLeftBars = 26 ;
 swingRightBars = 20 ;
 entryLookbackBars = 235 ;
 minEntryDistancePips = 80.0 ;
 minimumEntryDistancePercent = 0.0 ;
 profileScratchValue01 = AdjustEntry + -140.0;
 if ( Randomization>0.0 )
 {
   profileScratchValue02 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue02 = 0.0;
 }
 buyEntryOffsetPips = profileScratchValue01 + profileScratchValue02 ;
 profileScratchValue02 = AdjustEntry + -170.0;
 if ( Randomization>0.0 )
 {
   profileScratchValue03 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue03 = 0.0;
 }
 sellEntryOffsetPips = profileScratchValue02 + profileScratchValue03 ;
 maxPendingOrders = 5 ;
 duplicatePendingTolerancePips = 5.0 ;
 pendingExpirationHours = 55 ;
 exitTimingMode = 1 ;
 profileScratchValue03 = AdjustSL + 1900.0;
 if ( Randomization>0.0 )
 {
   profileScratchValue04 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue04 = 0.0;
 }
 stopLossPips = profileScratchValue03 + profileScratchValue04 ;
 profileScratchValue04 = AdjustTP + 1200.0;
 if ( Randomization>0.0 )
 {
   profileScratchValue05 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue05 = 0.0;
 }
 takeProfitPips = profileScratchValue04 + profileScratchValue05 ;
 profileScratchValue05 = AdjustTrailSL + 1250.0;
 if ( Randomization>0.0 )
 {
   profileScratchValue06 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue06 = 0.0;
 }
 trailingSLStartPips = profileScratchValue05 + profileScratchValue06 ;
 if ( Randomization>0.0 )
 {
   profileScratchValue07 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue07 = 0.0;
 }
 trailingSLDistancePips = profileScratchValue07 + 650.0 ;
 if ( Randomization>0.0 )
 {
   profileScratchValue08 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue08 = 0.0;
 }
 trailingSLStepLimitPips = profileScratchValue08 + 5000.0 ;
 trailingActivationBufferPips = 0.1 ;
 trailingPartialClosePercent = 0.0 ;
 if ( Randomization>0.0 )
 {
   profileScratchValue09 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue09 = 0.0;
 }
 trailingTPDistancePips = profileScratchValue09 + 1950.0 ;
 profileScratchValue09 = AdjustTrailTP + 250.0;
 if ( Randomization>0.0 )
 {
   profileScratchValue10 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue10 = 0.0;
 }
 trailingTPStartPips = profileScratchValue09 + profileScratchValue10 ;
 if ( Randomization>0.0 )
 {
   profileScratchValue11 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue11 = 0.0;
 }
 breakEvenStartPips = profileScratchValue11 + 270.0 ;
 profileScratchValue11 = AdjustBreakEven;
 if ( Randomization>0.0 )
 {
   profileScratchValue12 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   profileScratchValue12 = 0.0;
 }
 breakEvenExtraPips = profileScratchValue11 + profileScratchValue12 ;
 highLowTrailingTimeframeMinutes = 60 ;
 swingQualificationMinimumShift = 50 ;
 highLowLeftBars = 15 ;
 highLowRightBars = 3 ;
 highLowLookbackBars = 1200 ;
 highLowTrailingOffsetPips = 16.0 ;
 maxOpenTradesPerSide = 20 ;
 if ( !(RemoveCommentSuffix) )
 {
   currentStrategyComment=ST1_Comment + "_XAUUSD_8";
 }
 strategyMagicNumber=ST1_MagicNumber + 15;
 strategyDrawdownReferenceUsd = ConvertUsdToAccountCurrency(276.0) ;
 if ( !(UseVariableValues) )   return;
 lotSizeReferenceBalance = 2800.0 ;
 strategyDrawdownReferenceUsd = ConvertUsdToAccountCurrency(130.0) ;
 }
//LoadStrategy9Profile <<==--------   --------
 void EnforcePropFirmDailyDrawdown()
 {
  double    todayClosedProfit;
  int       historyScanIndex;
  double    closedTradeNetProfit;
  double    currentFloatingProfit;
  double    combinedDailyProfit;
//----------------------------------------------------------------------
 double     currentEquity;
 long       orderCloseTime;
 int        openOrderScanIndex;
 long        drawdownMagicCheck01;
 long        drawdownMagicCheck02;
 long        drawdownMagicCheck03;
 long        drawdownMagicCheck04;
 long        drawdownMagicCheck05;
 long        drawdownMagicCheck06;
 long        drawdownMagicCheck07;
 long        drawdownMagicCheck08;
 long        drawdownMagicCheck09;
 long        drawdownMagicCheck10;
 long        drawdownMagicCheck11;
 long        drawdownMagicCheck12;
 long        drawdownMagicCheck13;
 long        drawdownMagicCheck14;
 long        drawdownMagicCheck15;
 long        drawdownMagicCheck16;

 currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
 if ( currentEquity==AccountInfoDouble(ACCOUNT_BALANCE) )   return;
 todayClosedProfit = 0.0 ;
 if ( AccountInfoDouble(ACCOUNT_EQUITY)>dailyDrawdownReference )
 {
   dailyDrawdownReference = AccountInfoDouble(ACCOUNT_EQUITY) ;
 }
 for (historyScanIndex = ClosedTradeCount() ; historyScanIndex >= 0 ; historyScanIndex --)
 {
   if ( SelectTradeRecord(historyScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_HISTORY) != true )   continue;
   orderCloseTime = SelectedTradeCloseTime();
   if ( orderCloseTime < iTime(currentSymbol,NormalizeTimeframe(PERIOD_D1),0) )   continue;
   closedTradeNetProfit = SelectedTradeProfit() + SelectedTradeSwap() + SelectedTradeCommission() ;
   todayClosedProfit = closedTradeNetProfit + todayClosedProfit ;
   
 }
 currentFloatingProfit = AccountInfoDouble(ACCOUNT_EQUITY) - AccountInfoDouble(ACCOUNT_BALANCE) ;
 combinedDailyProfit = currentFloatingProfit + todayClosedProfit ;
 if ( !( -(combinedDailyProfit)>dailyDrawdownReference * PropFirmMaxDailyDD / 100.0) )   return;
 
 if ( !(dailyDrawdownLockActive) )
 {
   Print("Max Daily Drawdown reached, closing trades and skipping rest of the day"); 
 }
 for (openOrderScanIndex = ActiveTradeCount() ; openOrderScanIndex >= 0 ; openOrderScanIndex=openOrderScanIndex - 1)
 {
   if ( SelectTradeRecord(openOrderScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeSymbol() != currentSymbol )   continue;
   drawdownMagicCheck01 = SelectedTradeMagic();
   drawdownMagicCheck02=ST1_MagicNumber + 1;
   if ( drawdownMagicCheck01 != drawdownMagicCheck02 )
   {
     drawdownMagicCheck02 = SelectedTradeMagic();
     drawdownMagicCheck03=ST1_MagicNumber + 2;
     if ( drawdownMagicCheck02 != drawdownMagicCheck03 )
     {
       drawdownMagicCheck03 = SelectedTradeMagic();
       drawdownMagicCheck04=ST1_MagicNumber + 3;
       if ( drawdownMagicCheck03 != drawdownMagicCheck04 )
       {
         drawdownMagicCheck04 = SelectedTradeMagic();
         drawdownMagicCheck05=ST1_MagicNumber + 4;
         if ( drawdownMagicCheck04 != drawdownMagicCheck05 )
         {
           drawdownMagicCheck05 = SelectedTradeMagic();
           drawdownMagicCheck06=ST1_MagicNumber + 5;
           if ( drawdownMagicCheck05 != drawdownMagicCheck06 )
           {
             drawdownMagicCheck06 = SelectedTradeMagic();
             drawdownMagicCheck07=ST1_MagicNumber + 6;
             if ( drawdownMagicCheck06 != drawdownMagicCheck07 )
             {
               drawdownMagicCheck07 = SelectedTradeMagic();
               drawdownMagicCheck08=ST1_MagicNumber + 7;
               if ( drawdownMagicCheck07 != drawdownMagicCheck08 )
               {
                 drawdownMagicCheck08 = SelectedTradeMagic();
                 drawdownMagicCheck09=ST1_MagicNumber + 8;
                 if ( drawdownMagicCheck08 != drawdownMagicCheck09 )
                 {
                   drawdownMagicCheck09 = SelectedTradeMagic();
                   drawdownMagicCheck10=ST1_MagicNumber + 9;
                   if ( drawdownMagicCheck09 != drawdownMagicCheck10 )
                   {
                     drawdownMagicCheck10 = SelectedTradeMagic();
                     drawdownMagicCheck11=ST1_MagicNumber + 10;
                     if ( drawdownMagicCheck10 != drawdownMagicCheck11 )
                     {
                       drawdownMagicCheck11 = SelectedTradeMagic();
                       drawdownMagicCheck12=ST1_MagicNumber + 11;
                       if ( drawdownMagicCheck11 != drawdownMagicCheck12 )
                       {
                         drawdownMagicCheck12 = SelectedTradeMagic();
                         drawdownMagicCheck13=ST1_MagicNumber + 12;
                         if ( drawdownMagicCheck12 != drawdownMagicCheck13 )
                         {
                           drawdownMagicCheck13 = SelectedTradeMagic();
                           drawdownMagicCheck14=ST1_MagicNumber + 13;
                           if ( drawdownMagicCheck13 != drawdownMagicCheck14 )
                           {
                             drawdownMagicCheck14 = SelectedTradeMagic();
                             drawdownMagicCheck15=ST1_MagicNumber + 14;
                             if ( drawdownMagicCheck14 != drawdownMagicCheck15 )
                             {
                               drawdownMagicCheck15 = SelectedTradeMagic();
                               drawdownMagicCheck16=ST1_MagicNumber + 15;
                             if ( drawdownMagicCheck15 != drawdownMagicCheck16 )   continue;
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
   if ( SelectedTradeType() == ORDER_TYPE_BUY )
   {
     ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(currentSymbol,SYMBOL_BID),(int)orderSlippageSetting,Red); 
   }
   if ( SelectedTradeType() == ORDER_TYPE_SELL )
   {
     ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(currentSymbol,SYMBOL_ASK),(int)orderSlippageSetting,Red); 
   }
   if ( ( SelectedTradeType() != ORDER_TYPE_BUY_STOP && SelectedTradeType() != ORDER_TYPE_SELL_STOP ) )   continue;
   DeletePendingOrderByTicket(SelectedTradeTicket(),Red); 
   
 }
 dailyDrawdownLockActive = true ;
 dailyDrawdownReference = 0.0 ;
 }
//EnforcePropFirmDailyDrawdown <<==--------   --------
 int FetchUtcOffsetHours()
 {
  string    responseBody;
  int       timestampMarkerIndex;
  string    timestampText;
  long      utcTimestamp;
  int       utcOffsetHours;
  char      requestBodyBytes[];
  char      responseBytes[];
//----------------------------------------------------------------------
 string     responseHeaders;
 string     responseText;

 ResetLastError();
 if ( WebRequest("GET","https://www.worldtimeserver.com/time-zones/utc/",NULL,NULL,10000,requestBodyBytes,0,responseBytes,responseHeaders) == -1 )
 {
   Print("Error when reading GMT URL. Error code  =",GetLastError());
   MessageBox("Add the address \'https://www.worldtimeserver.com/\' in the list of allowed URLs on tab \'Expert Advisors\'","Error",64);
   responseText = "999";
 }
 else
 {
   // WHOLE_ARRAY=0 duoc dung de lay "toan bo mang" khi
   // count=0; nhung MQL5 dinh nghia lai WHOLE_ARRAY=-1, con count=0 trong MQL5
   // co nghia den la "lay 0 ky tu" -> luon ra chuoi rong du HTTP tra ve 200 va
   // co du du lieu (day chinh la nguyen nhan that su cua loi "GMT time = 0").
   responseText = CharArrayToString(responseBytes,0,-1,0);
 }
 responseBody = responseText ;
 if ( responseBody == "999" )
 {
   return(999);
 }
 timestampMarkerIndex = StringFind(responseBody,"\"serverTimeStamp\" value=",0) ;
 timestampText = StringSubstr(responseBody,timestampMarkerIndex + 25,10) ;
 utcTimestamp = (long)ulong(timestampText) ;
 Print("GMT time = ",utcTimestamp); 
 Print("Broker time = ",TimeCurrent()); 
 utcOffsetHours=DateTimeHour(TimeCurrent()) - DateTimeHour(utcTimestamp);
 if ( utcOffsetHours <  -12 )
 {
   utcOffsetHours +=24;
 }
 if ( utcOffsetHours >  12 )
 {
   utcOffsetHours -=24;
 }
 Print("GMT_Offset detected: " + string(utcOffsetHours)); 
 if ( ( utcOffsetHours < -12 || utcOffsetHours >  12 ) )
 {
   Print("Error in detecting GMT offset with URL"); 
   return(999); 
 }
 if ( utcTimestamp <  TimeCurrent() - SECONDS_PER_DAY )
 {
   Print("Error in detecting GMT time with URL"); 
   return(999); 
 }
 return(utcOffsetHours); 
 }
//FetchUtcOffsetHours <<==--------   --------
 bool IsAmericanDaylightSavingTime()
 {
  int       year;
  datetime  dstStart;
  datetime  dstEnd;
  int       startDayOffset;
  int       endDayOffset;
//----------------------------------------------------------------------

 year = DateTimeYear(TimeCurrent()) ;
 dstStart = 0 ;
 dstEnd = 0 ;
 if ( year <  1987 )
 {
   Print("AmericanDST(): Invalid year."); 
   return(false); 
 }
 startDayOffset = 0 ;
 endDayOffset = 0 ;
 if ( year >= 1987 && year <= 2006 )
 {
   startDayOffset = (int)(MathMod(year * 6 + 2 - year / 4,7.0) + 1.0) ;
   endDayOffset = (int)(31.0 - (MathMod(year * 5 / 4 + 1,7.0))) ;
   dstStart=StringToTime(((string)year+".04.01")) + (startDayOffset - 1) * SECONDS_PER_DAY + DST_TRANSITION_TIME_SECONDS;
   dstEnd=StringToTime(((string)year+".10.01")) + (endDayOffset - 1) * SECONDS_PER_DAY + DST_TRANSITION_TIME_SECONDS;
 }
 else
 {
   if ( year >= 2007 )
   {
     startDayOffset = (int)(14.0 - (MathMod(year * 5 / 4 + 1,7.0))) ;
     endDayOffset = (int)(7.0 - (MathMod(year * 5 / 4 + 1,7.0))) ;
     dstStart=StringToTime(((string)year+".03.01")) + (startDayOffset - 1) * SECONDS_PER_DAY + DST_TRANSITION_TIME_SECONDS;
     dstEnd=StringToTime(((string)year+".11.01")) + (endDayOffset - 1) * SECONDS_PER_DAY + DST_TRANSITION_TIME_SECONDS;
   }
 }
 if ( DateTimeDayOfYear(TimeCurrent()) >  DateTimeDayOfYear(dstStart) && DateTimeDayOfYear(TimeCurrent()) <  DateTimeDayOfYear(dstEnd) )
 {
   return(true); 
 }
 return(false); 
 }
//<<==IsAmericanDaylightSavingTime <<==

