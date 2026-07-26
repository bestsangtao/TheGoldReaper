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

CTrade TradeExecutor;
long LastSubmittedTradeTicket = -1;
int  LastTradeErrorCodeValue = 0;

ENUM_TIMEFRAMES NormalizeTimeframe(const int Minutes)
{
   switch(Minutes)
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
   return (ENUM_TIMEFRAMES)Minutes;
}

bool RefreshCurrentSymbolTick()
{
   MqlTick LatestTick;
   return SymbolInfoTick(_Symbol,LatestTick);
}

bool IsDemoAccount()
{
   return AccountInfoInteger(ACCOUNT_TRADE_MODE)==ACCOUNT_TRADE_MODE_DEMO;
}

bool IsStrategyTester()
{
   return (bool)MQLInfoInteger(MQL_TESTER);
}

int DateTimeYear(const datetime Value)      { MqlDateTime Parts; TimeToStruct(Value,Parts); return Parts.year; }
int DateTimeMonth(const datetime Value)     { MqlDateTime Parts; TimeToStruct(Value,Parts); return Parts.mon; }
int DateTimeDay(const datetime Value)       { MqlDateTime Parts; TimeToStruct(Value,Parts); return Parts.day; }
int DateTimeHour(const datetime Value)      { MqlDateTime Parts; TimeToStruct(Value,Parts); return Parts.hour; }
int DateTimeMinute(const datetime Value)    { MqlDateTime Parts; TimeToStruct(Value,Parts); return Parts.min; }
int DateTimeSecond(const datetime Value)    { MqlDateTime Parts; TimeToStruct(Value,Parts); return Parts.sec; }
int DateTimeDayOfWeek(const datetime Value) { MqlDateTime Parts; TimeToStruct(Value,Parts); return Parts.day_of_week; }
int DateTimeDayOfYear(const datetime Value) { MqlDateTime Parts; TimeToStruct(Value,Parts); return Parts.day_of_year; }

int CurrentYear()      { return DateTimeYear(TimeCurrent()); }
int CurrentMonth()     { return DateTimeMonth(TimeCurrent()); }
int CurrentDay()       { return DateTimeDay(TimeCurrent()); }
int CurrentHour()      { return DateTimeHour(TimeCurrent()); }
int CurrentMinute()    { return DateTimeMinute(TimeCurrent()); }
int CurrentSecond()    { return DateTimeSecond(TimeCurrent()); }
int CurrentDayOfWeek() { return DateTimeDayOfWeek(TimeCurrent()); }

ENUM_APPLIED_PRICE NormalizeAppliedPrice(const int LegacyPriceCode)
{
   return (ENUM_APPLIED_PRICE)(LegacyPriceCode+1);
}

double GetMovingAverageValue(const string SymbolName,const int Timeframe,const int Period,
                             const int MaShift,const int MaMethod,
                             const int AppliedPrice,const int BufferShift)
{
   int Handle=::iMA(SymbolName,NormalizeTimeframe(Timeframe),Period,MaShift,
                    (ENUM_MA_METHOD)MaMethod,NormalizeAppliedPrice(AppliedPrice));
   if(Handle==INVALID_HANDLE)
      return 0.0;

   double Values[];
   ArraySetAsSeries(Values,true);
   if(CopyBuffer(Handle,0,BufferShift,1,Values)<=0)
      return 0.0;
   return Values[0];
}

double GetFractalValue(const string SymbolName,const int Timeframe,const int FractalBufferMode,
                       const int BufferShift)
{
   int Handle=::iFractals(SymbolName,NormalizeTimeframe(Timeframe));
   if(Handle==INVALID_HANDLE)
      return 0.0;

   int BufferIndex=(FractalBufferMode==1)?0:1;
   double Values[];
   ArraySetAsSeries(Values,true);
   if(CopyBuffer(Handle,BufferIndex,BufferShift,1,Values)<=0)
      return 0.0;
   return Values[0];
}

double ProjectedFreeMarginAfterOrder(const string SymbolName,const ENUM_ORDER_TYPE OrderType,
                                     const double Volume)
{
   double Margin=0.0;
   ENUM_ORDER_TYPE MarketType=(OrderType==ORDER_TYPE_BUY)?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
   double Price=(MarketType==ORDER_TYPE_BUY)
                ?SymbolInfoDouble(SymbolName,SYMBOL_ASK)
                :SymbolInfoDouble(SymbolName,SYMBOL_BID);
   if(!OrderCalcMargin(MarketType,SymbolName,Volume,Price,Margin))
      return AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   return AccountInfoDouble(ACCOUNT_MARGIN_FREE)-Margin;
}

int LastTradeErrorCode()
{
   return LastTradeErrorCodeValue;
}

int TradeRetcodeToStrategyError(const uint Retcode)
{
   switch(Retcode)
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
   return (int)Retcode;
}

ENUM_ORDER_TYPE_FILLING SelectSymbolFillingMode(const string SymbolName)
{
   long FillingMask=SymbolInfoInteger(SymbolName,SYMBOL_FILLING_MODE);
   if((FillingMask&SYMBOL_FILLING_FOK)!=0)
      return ORDER_FILLING_FOK;
   if((FillingMask&SYMBOL_FILLING_IOC)!=0)
      return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
}

string TradeOrderTypeName(const ENUM_ORDER_TYPE OrderType)
{
   switch(OrderType)
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

long SendTradeOrder(const string SymbolName,const ENUM_ORDER_TYPE OrderType,
                    const double Volume,const double RequestedPrice,
                    const int SlippagePoints,const double StopLoss,
                    const double TakeProfit,const string CommentText="",
                    const int Magic=0,const datetime Expiration=0,
                    const color ArrowColor=clrNONE)
{
   TradeExecutor.SetExpertMagicNumber((ulong)Magic);
   TradeExecutor.SetDeviationInPoints((ulong)MathMax(SlippagePoints,0));

   bool RequestAccepted=false;
   double ExecutionPrice=RequestedPrice;

   if(OrderType==ORDER_TYPE_BUY || OrderType==ORDER_TYPE_SELL)
   {
      TradeExecutor.SetTypeFilling(SelectSymbolFillingMode(SymbolName));
      ExecutionPrice=(OrderType==ORDER_TYPE_BUY)
                     ?SymbolInfoDouble(SymbolName,SYMBOL_ASK)
                     :SymbolInfoDouble(SymbolName,SYMBOL_BID);
      RequestAccepted=TradeExecutor.PositionOpen(SymbolName,OrderType,Volume,ExecutionPrice,
                                         StopLoss,TakeProfit,CommentText);
   }
   else
   {
      TradeExecutor.SetTypeFilling(ORDER_FILLING_RETURN);
      ENUM_ORDER_TYPE_TIME TimeType=(Expiration>0)?ORDER_TIME_SPECIFIED:ORDER_TIME_GTC;
      RequestAccepted=TradeExecutor.OrderOpen(SymbolName,OrderType,Volume,0.0,RequestedPrice,
                                      StopLoss,TakeProfit,TimeType,Expiration,CommentText);
   }

   uint Retcode=TradeExecutor.ResultRetcode();
   if(!RequestAccepted && Retcode==0)
      Retcode=TRADE_RETCODE_ERROR;
   LastTradeErrorCodeValue=TradeRetcodeToStrategyError(Retcode);

   if(RequestAccepted &&
      (Retcode==TRADE_RETCODE_DONE || Retcode==TRADE_RETCODE_DONE_PARTIAL ||
       Retcode==TRADE_RETCODE_PLACED))
   {
      LastTradeErrorCodeValue=0;
      ulong ResultTicket=TradeExecutor.ResultOrder();
      if(ResultTicket==0)
         ResultTicket=TradeExecutor.ResultDeal();
      LastSubmittedTradeTicket=(long)ResultTicket;
      PrintFormat("open #%I64d %s %.2f %s at %.5f sl: %.5f tp: %.5f ok",
                  LastSubmittedTradeTicket,TradeOrderTypeName(OrderType),Volume,
                  SymbolName,ExecutionPrice,StopLoss,TakeProfit);
      return LastSubmittedTradeTicket;
   }

   PrintFormat("failed open %s %.2f %s at %.5f sl: %.5f tp: %.5f [%s] (retcode=%u)",
               TradeOrderTypeName(OrderType),Volume,SymbolName,ExecutionPrice,
               StopLoss,TakeProfit,TradeExecutor.ResultRetcodeDescription(),Retcode);
   LastSubmittedTradeTicket=-1;
   return -1;
}

bool ModifyTradeByTicket(const long Ticket,const double Price,const double StopLoss,
                         const double TakeProfit,const datetime Expiration,
                         const color ArrowColor=clrNONE)
{
   bool RequestAccepted=false;
   string SymbolName="";

   if(PositionSelectByTicket((ulong)Ticket))
   {
      SymbolName=PositionGetString(POSITION_SYMBOL);
      RequestAccepted=TradeExecutor.PositionModify((ulong)Ticket,StopLoss,TakeProfit);
   }
   else if(::OrderSelect((ulong)Ticket))
   {
      SymbolName=::OrderGetString(ORDER_SYMBOL);
      ENUM_ORDER_TYPE_TIME TimeType=(Expiration>0)?ORDER_TIME_SPECIFIED:ORDER_TIME_GTC;
      RequestAccepted=TradeExecutor.OrderModify((ulong)Ticket,Price,StopLoss,TakeProfit,
                                        TimeType,Expiration,0.0);
   }
   else
   {
      LastTradeErrorCodeValue=STRATEGY_ERROR_INVALID_TICKET;
      return false;
   }

   uint Retcode=TradeExecutor.ResultRetcode();
   if(!RequestAccepted && Retcode==0)
      Retcode=TRADE_RETCODE_ERROR;
   LastTradeErrorCodeValue=TradeRetcodeToStrategyError(Retcode);

   if(RequestAccepted &&
      (Retcode==TRADE_RETCODE_DONE || Retcode==TRADE_RETCODE_DONE_PARTIAL))
   {
      LastTradeErrorCodeValue=0;
      PrintFormat("modify #%I64d %s price: %.5f sl: %.5f tp: %.5f ok",
                  Ticket,SymbolName,Price,StopLoss,TakeProfit);
      return true;
   }

   PrintFormat("failed modify %s at %.5f sl: %.5f tp: %.5f [%s] (retcode=%u, ticket=%I64d)",
               SymbolName,Price,StopLoss,TakeProfit,TradeExecutor.ResultRetcodeDescription(),Retcode,Ticket);
   return false;
}

bool ClosePositionByTicket(const long Ticket,const double RequestedVolume,
                           const double RequestedPrice,const int SlippagePoints,
                           const color ArrowColor=clrNONE)
{
   if(!PositionSelectByTicket((ulong)Ticket))
   {
      LastTradeErrorCodeValue=STRATEGY_ERROR_INVALID_TICKET;
      return false;
   }

   string SymbolName=PositionGetString(POSITION_SYMBOL);
   double PositionVolume=PositionGetDouble(POSITION_VOLUME);
   ENUM_POSITION_TYPE PositionType=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double CloseVolume=(RequestedVolume>0.0 && RequestedVolume<PositionVolume)
                      ?RequestedVolume:PositionVolume;
   ulong Deviation=(ulong)MathMax(SlippagePoints,0);

   TradeExecutor.SetDeviationInPoints(Deviation);
   TradeExecutor.SetTypeFilling(SelectSymbolFillingMode(SymbolName));

   bool RequestAccepted=(CloseVolume>=PositionVolume)
                        ?TradeExecutor.PositionClose((ulong)Ticket,Deviation)
                        :TradeExecutor.PositionClosePartial((ulong)Ticket,CloseVolume,Deviation);

   uint Retcode=TradeExecutor.ResultRetcode();
   if(!RequestAccepted && Retcode==0)
      Retcode=TRADE_RETCODE_ERROR;
   LastTradeErrorCodeValue=TradeRetcodeToStrategyError(Retcode);

   if(RequestAccepted &&
      (Retcode==TRADE_RETCODE_DONE || Retcode==TRADE_RETCODE_DONE_PARTIAL))
   {
      LastTradeErrorCodeValue=0;
      PrintFormat("close #%I64d %s %.2f %s at %.5f ok",Ticket,
                  (PositionType==POSITION_TYPE_BUY)?"buy":"sell",
                  CloseVolume,SymbolName,TradeExecutor.ResultPrice());
      return true;
   }

   PrintFormat("failed close %s %.2f %s [%s] (retcode=%u, ticket=%I64d)",
               (PositionType==POSITION_TYPE_BUY)?"buy":"sell",CloseVolume,SymbolName,
               TradeExecutor.ResultRetcodeDescription(),Retcode,Ticket);
   return false;
}

bool DeletePendingOrderByTicket(const long Ticket,const color ArrowColor=clrNONE)
{
   string OrderName="order";
   double OrderVolume=0.0;
   double OrderPrice=0.0;
   string SymbolName="";

   if(::OrderSelect((ulong)Ticket))
   {
      OrderName=TradeOrderTypeName((ENUM_ORDER_TYPE)::OrderGetInteger(ORDER_TYPE));
      OrderVolume=::OrderGetDouble(ORDER_VOLUME_CURRENT);
      OrderPrice=::OrderGetDouble(ORDER_PRICE_OPEN);
      SymbolName=::OrderGetString(ORDER_SYMBOL);
   }

   bool RequestAccepted=TradeExecutor.OrderDelete((ulong)Ticket);
   uint Retcode=TradeExecutor.ResultRetcode();
   if(!RequestAccepted && Retcode==0)
      Retcode=TRADE_RETCODE_ERROR;
   LastTradeErrorCodeValue=TradeRetcodeToStrategyError(Retcode);

   if(RequestAccepted && Retcode==TRADE_RETCODE_DONE)
   {
      LastTradeErrorCodeValue=0;
      PrintFormat("delete #%I64d %s %.2f %s at %.5f ok",
                  Ticket,OrderName,OrderVolume,SymbolName,OrderPrice);
      return true;
   }

   PrintFormat("failed delete %s %.2f %s at %.5f [%s] (retcode=%u, ticket=%I64d)",
               OrderName,OrderVolume,SymbolName,OrderPrice,
               TradeExecutor.ResultRetcodeDescription(),Retcode,Ticket);
   return false;
}

struct SelectedTradeRecord
{
   long            Ticket;
   string          Symbol;
   ENUM_ORDER_TYPE Type;
   double          Volume;
   double          OpenPrice;
   double          ClosePrice;
   double          StopLoss;
   double          TakeProfit;
   datetime        OpenTime;
   datetime        CloseTime;
   datetime        Expiration;
   double          Profit;
   double          Swap;
   double          Commission;
   string          Comment;
   long            Magic;
};

SelectedTradeRecord SelectedTrade;

long            ClosedTradeTicket[];
string          ClosedTradeSymbol[];
ENUM_ORDER_TYPE ClosedTradeType[];
double          ClosedTradeVolume[];
double          ClosedTradeOpenPrice[];
double          ClosedTradeClosePrice[];
datetime        ClosedTradeOpenTime[];
datetime        ClosedTradeCloseTime[];
double          ClosedTradeProfit[];
double          ClosedTradeSwap[];
double          ClosedTradeCommission[];
string          ClosedTradeComment[];
long            ClosedTradeMagic[];
datetime        ClosedTradeExpiration[];
int             ClosedTradeCountValue=0;
datetime        ClosedTradeCacheBuiltAt=0;

void BuildClosedTradeCache()
{
   if(TimeCurrent()==ClosedTradeCacheBuiltAt)
      return;
   ClosedTradeCacheBuiltAt=TimeCurrent();

   ArrayResize(ClosedTradeTicket,0);
   ArrayResize(ClosedTradeSymbol,0);
   ArrayResize(ClosedTradeType,0);
   ArrayResize(ClosedTradeVolume,0);
   ArrayResize(ClosedTradeOpenPrice,0);
   ArrayResize(ClosedTradeClosePrice,0);
   ArrayResize(ClosedTradeOpenTime,0);
   ArrayResize(ClosedTradeCloseTime,0);
   ArrayResize(ClosedTradeProfit,0);
   ArrayResize(ClosedTradeSwap,0);
   ArrayResize(ClosedTradeCommission,0);
   ArrayResize(ClosedTradeComment,0);
   ArrayResize(ClosedTradeMagic,0);
   ArrayResize(ClosedTradeExpiration,0);
   ClosedTradeCountValue=0;

   if(!HistorySelect(0,TimeCurrent()))
      return;

   int DealCount=HistoryDealsTotal();
   long PositionIdentifiers[];
   ArrayResize(PositionIdentifiers,0);

   for(int DealIndex=0;DealIndex<DealCount;DealIndex++)
   {
      ulong DealTicket=HistoryDealGetTicket(DealIndex);
      if(DealTicket==0)
         continue;

      ENUM_DEAL_ENTRY Entry=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(DealTicket,DEAL_ENTRY);
      long PositionIdentifier=HistoryDealGetInteger(DealTicket,DEAL_POSITION_ID);
      ENUM_DEAL_TYPE DealType=(ENUM_DEAL_TYPE)HistoryDealGetInteger(DealTicket,DEAL_TYPE);
      if(DealType!=DEAL_TYPE_BUY && DealType!=DEAL_TYPE_SELL)
         continue;

      int RecordIndex=-1;
      for(int SearchIndex=0;SearchIndex<ArraySize(PositionIdentifiers);SearchIndex++)
      {
         if(PositionIdentifiers[SearchIndex]==PositionIdentifier)
         {
            RecordIndex=SearchIndex;
            break;
         }
      }

      if(RecordIndex<0)
      {
         RecordIndex=ArraySize(PositionIdentifiers);
         ArrayResize(PositionIdentifiers,RecordIndex+1);
         PositionIdentifiers[RecordIndex]=PositionIdentifier;

         int NewSize=ClosedTradeCountValue+1;
         ArrayResize(ClosedTradeTicket,NewSize);
         ArrayResize(ClosedTradeSymbol,NewSize);
         ArrayResize(ClosedTradeType,NewSize);
         ArrayResize(ClosedTradeVolume,NewSize);
         ArrayResize(ClosedTradeOpenPrice,NewSize);
         ArrayResize(ClosedTradeClosePrice,NewSize);
         ArrayResize(ClosedTradeOpenTime,NewSize);
         ArrayResize(ClosedTradeCloseTime,NewSize);
         ArrayResize(ClosedTradeProfit,NewSize);
         ArrayResize(ClosedTradeSwap,NewSize);
         ArrayResize(ClosedTradeCommission,NewSize);
         ArrayResize(ClosedTradeComment,NewSize);
         ArrayResize(ClosedTradeMagic,NewSize);
         ArrayResize(ClosedTradeExpiration,NewSize);

         ClosedTradeTicket[ClosedTradeCountValue]=PositionIdentifier;
         ClosedTradeSymbol[ClosedTradeCountValue]="";
         ClosedTradeType[ClosedTradeCountValue]=ORDER_TYPE_BUY;
         ClosedTradeVolume[ClosedTradeCountValue]=0.0;
         ClosedTradeOpenPrice[ClosedTradeCountValue]=0.0;
         ClosedTradeClosePrice[ClosedTradeCountValue]=0.0;
         ClosedTradeOpenTime[ClosedTradeCountValue]=0;
         ClosedTradeCloseTime[ClosedTradeCountValue]=0;
         ClosedTradeProfit[ClosedTradeCountValue]=0.0;
         ClosedTradeSwap[ClosedTradeCountValue]=0.0;
         ClosedTradeCommission[ClosedTradeCountValue]=0.0;
         ClosedTradeComment[ClosedTradeCountValue]="";
         ClosedTradeMagic[ClosedTradeCountValue]=0;
         ClosedTradeExpiration[ClosedTradeCountValue]=0;
         ClosedTradeCountValue=NewSize;
      }

      if(Entry==DEAL_ENTRY_IN)
      {
         ClosedTradeSymbol[RecordIndex]=HistoryDealGetString(DealTicket,DEAL_SYMBOL);
         ClosedTradeType[RecordIndex]=(DealType==DEAL_TYPE_BUY)?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
         ClosedTradeVolume[RecordIndex]=HistoryDealGetDouble(DealTicket,DEAL_VOLUME);
         ClosedTradeOpenPrice[RecordIndex]=HistoryDealGetDouble(DealTicket,DEAL_PRICE);
         ClosedTradeOpenTime[RecordIndex]=(datetime)HistoryDealGetInteger(DealTicket,DEAL_TIME);
         ClosedTradeMagic[RecordIndex]=HistoryDealGetInteger(DealTicket,DEAL_MAGIC);
         ClosedTradeComment[RecordIndex]=HistoryDealGetString(DealTicket,DEAL_COMMENT);
         ClosedTradeProfit[RecordIndex]+=HistoryDealGetDouble(DealTicket,DEAL_PROFIT);
         ClosedTradeSwap[RecordIndex]+=HistoryDealGetDouble(DealTicket,DEAL_SWAP);
         ClosedTradeCommission[RecordIndex]+=HistoryDealGetDouble(DealTicket,DEAL_COMMISSION);
      }
      else
      {
         ClosedTradeClosePrice[RecordIndex]=HistoryDealGetDouble(DealTicket,DEAL_PRICE);
         datetime CloseTime=(datetime)HistoryDealGetInteger(DealTicket,DEAL_TIME);
         if(CloseTime>ClosedTradeCloseTime[RecordIndex])
            ClosedTradeCloseTime[RecordIndex]=CloseTime;
         ClosedTradeProfit[RecordIndex]+=HistoryDealGetDouble(DealTicket,DEAL_PROFIT);
         ClosedTradeSwap[RecordIndex]+=HistoryDealGetDouble(DealTicket,DEAL_SWAP);
         ClosedTradeCommission[RecordIndex]+=HistoryDealGetDouble(DealTicket,DEAL_COMMISSION);
         if(ClosedTradeSymbol[RecordIndex]=="")
            ClosedTradeSymbol[RecordIndex]=HistoryDealGetString(DealTicket,DEAL_SYMBOL);
         if(ClosedTradeMagic[RecordIndex]==0)
            ClosedTradeMagic[RecordIndex]=HistoryDealGetInteger(DealTicket,DEAL_MAGIC);
      }
   }

   for(int Left=0;Left<ClosedTradeCountValue;Left++)
   {
      for(int Right=Left+1;Right<ClosedTradeCountValue;Right++)
      {
         if(ClosedTradeCloseTime[Right]>=ClosedTradeCloseTime[Left])
            continue;

         long LongValue;
         string StringValue;
         ENUM_ORDER_TYPE TypeValue;
         double DoubleValue;
         datetime TimeValue;

         LongValue=ClosedTradeTicket[Left]; ClosedTradeTicket[Left]=ClosedTradeTicket[Right]; ClosedTradeTicket[Right]=LongValue;
         StringValue=ClosedTradeSymbol[Left]; ClosedTradeSymbol[Left]=ClosedTradeSymbol[Right]; ClosedTradeSymbol[Right]=StringValue;
         TypeValue=ClosedTradeType[Left]; ClosedTradeType[Left]=ClosedTradeType[Right]; ClosedTradeType[Right]=TypeValue;
         DoubleValue=ClosedTradeVolume[Left]; ClosedTradeVolume[Left]=ClosedTradeVolume[Right]; ClosedTradeVolume[Right]=DoubleValue;
         DoubleValue=ClosedTradeOpenPrice[Left]; ClosedTradeOpenPrice[Left]=ClosedTradeOpenPrice[Right]; ClosedTradeOpenPrice[Right]=DoubleValue;
         DoubleValue=ClosedTradeClosePrice[Left]; ClosedTradeClosePrice[Left]=ClosedTradeClosePrice[Right]; ClosedTradeClosePrice[Right]=DoubleValue;
         TimeValue=ClosedTradeOpenTime[Left]; ClosedTradeOpenTime[Left]=ClosedTradeOpenTime[Right]; ClosedTradeOpenTime[Right]=TimeValue;
         TimeValue=ClosedTradeCloseTime[Left]; ClosedTradeCloseTime[Left]=ClosedTradeCloseTime[Right]; ClosedTradeCloseTime[Right]=TimeValue;
         DoubleValue=ClosedTradeProfit[Left]; ClosedTradeProfit[Left]=ClosedTradeProfit[Right]; ClosedTradeProfit[Right]=DoubleValue;
         DoubleValue=ClosedTradeSwap[Left]; ClosedTradeSwap[Left]=ClosedTradeSwap[Right]; ClosedTradeSwap[Right]=DoubleValue;
         DoubleValue=ClosedTradeCommission[Left]; ClosedTradeCommission[Left]=ClosedTradeCommission[Right]; ClosedTradeCommission[Right]=DoubleValue;
         StringValue=ClosedTradeComment[Left]; ClosedTradeComment[Left]=ClosedTradeComment[Right]; ClosedTradeComment[Right]=StringValue;
         LongValue=ClosedTradeMagic[Left]; ClosedTradeMagic[Left]=ClosedTradeMagic[Right]; ClosedTradeMagic[Right]=LongValue;
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
   return ClosedTradeCountValue;
}

void FillSelectedTradeFromPosition(const long Ticket)
{
   SelectedTrade.Ticket=Ticket;
   SelectedTrade.Symbol=PositionGetString(POSITION_SYMBOL);
   SelectedTrade.Type=(ENUM_ORDER_TYPE)PositionGetInteger(POSITION_TYPE);
   SelectedTrade.Volume=PositionGetDouble(POSITION_VOLUME);
   SelectedTrade.OpenPrice=PositionGetDouble(POSITION_PRICE_OPEN);
   SelectedTrade.ClosePrice=PositionGetDouble(POSITION_PRICE_CURRENT);
   SelectedTrade.StopLoss=PositionGetDouble(POSITION_SL);
   SelectedTrade.TakeProfit=PositionGetDouble(POSITION_TP);
   SelectedTrade.OpenTime=(datetime)PositionGetInteger(POSITION_TIME);
   SelectedTrade.CloseTime=0;
   SelectedTrade.Expiration=0;
   SelectedTrade.Profit=PositionGetDouble(POSITION_PROFIT);
   SelectedTrade.Swap=PositionGetDouble(POSITION_SWAP);
   SelectedTrade.Commission=0.0;
   SelectedTrade.Comment=PositionGetString(POSITION_COMMENT);
   SelectedTrade.Magic=PositionGetInteger(POSITION_MAGIC);
}

void FillSelectedTradeFromPendingOrder(const long Ticket)
{
   SelectedTrade.Ticket=Ticket;
   SelectedTrade.Symbol=::OrderGetString(ORDER_SYMBOL);
   SelectedTrade.Type=(ENUM_ORDER_TYPE)::OrderGetInteger(ORDER_TYPE);
   SelectedTrade.Volume=::OrderGetDouble(ORDER_VOLUME_CURRENT);
   SelectedTrade.OpenPrice=::OrderGetDouble(ORDER_PRICE_OPEN);
   SelectedTrade.ClosePrice=0.0;
   SelectedTrade.StopLoss=::OrderGetDouble(ORDER_SL);
   SelectedTrade.TakeProfit=::OrderGetDouble(ORDER_TP);
   SelectedTrade.OpenTime=(datetime)::OrderGetInteger(ORDER_TIME_SETUP);
   SelectedTrade.CloseTime=0;
   SelectedTrade.Expiration=(datetime)::OrderGetInteger(ORDER_TIME_EXPIRATION);
   SelectedTrade.Profit=0.0;
   SelectedTrade.Swap=0.0;
   SelectedTrade.Commission=0.0;
   SelectedTrade.Comment=::OrderGetString(ORDER_COMMENT);
   SelectedTrade.Magic=::OrderGetInteger(ORDER_MAGIC);
}

void FillSelectedTradeFromHistory(const int RecordIndex)
{
   SelectedTrade.Ticket=ClosedTradeTicket[RecordIndex];
   SelectedTrade.Symbol=ClosedTradeSymbol[RecordIndex];
   SelectedTrade.Type=ClosedTradeType[RecordIndex];
   SelectedTrade.Volume=ClosedTradeVolume[RecordIndex];
   SelectedTrade.OpenPrice=ClosedTradeOpenPrice[RecordIndex];
   SelectedTrade.ClosePrice=ClosedTradeClosePrice[RecordIndex];
   SelectedTrade.StopLoss=0.0;
   SelectedTrade.TakeProfit=0.0;
   SelectedTrade.OpenTime=ClosedTradeOpenTime[RecordIndex];
   SelectedTrade.CloseTime=ClosedTradeCloseTime[RecordIndex];
   SelectedTrade.Expiration=0;
   SelectedTrade.Profit=ClosedTradeProfit[RecordIndex];
   SelectedTrade.Swap=ClosedTradeSwap[RecordIndex];
   SelectedTrade.Commission=ClosedTradeCommission[RecordIndex];
   SelectedTrade.Comment=ClosedTradeComment[RecordIndex];
   SelectedTrade.Magic=ClosedTradeMagic[RecordIndex];
}

bool SelectTradeRecord(const long IndexOrTicket,const TradeRecordSelectMode SelectMode,
                       const TradeRecordPool Pool=TRADE_POOL_ACTIVE)
{
   if(SelectMode==TRADE_SELECT_BY_TICKET)
   {
      long Ticket=IndexOrTicket;
      if(PositionSelectByTicket((ulong)Ticket))
      {
         FillSelectedTradeFromPosition(Ticket);
         return true;
      }
      if(::OrderSelect((ulong)Ticket))
      {
         FillSelectedTradeFromPendingOrder(Ticket);
         return true;
      }

      BuildClosedTradeCache();
      for(int HistoryIndex=0;HistoryIndex<ClosedTradeCountValue;HistoryIndex++)
      {
         if(ClosedTradeTicket[HistoryIndex]!=Ticket)
            continue;
         FillSelectedTradeFromHistory(HistoryIndex);
         return true;
      }
      return false;
   }

   if(Pool==TRADE_POOL_HISTORY)
   {
      BuildClosedTradeCache();
      if(IndexOrTicket<0 || IndexOrTicket>=ClosedTradeCountValue)
         return false;
      FillSelectedTradeFromHistory((int)IndexOrTicket);
      return true;
   }

   int PositionCount=PositionsTotal();
   if(IndexOrTicket>=0 && IndexOrTicket<PositionCount)
   {
      ulong PositionTicket=PositionGetTicket((int)IndexOrTicket);
      if(PositionTicket==0)
         return false;
      FillSelectedTradeFromPosition((long)PositionTicket);
      return true;
   }

   long OrderIndex64=IndexOrTicket-PositionCount;
   int PendingOrderCount=::OrdersTotal();
   if(OrderIndex64>=0 && OrderIndex64<PendingOrderCount)
   {
      ulong OrderTicket=::OrderGetTicket((int)OrderIndex64);
      if(OrderTicket==0)
         return false;
      FillSelectedTradeFromPendingOrder((long)OrderTicket);
      return true;
   }
   return false;
}

long            SelectedTradeTicket()      { return SelectedTrade.Ticket; }
string          SelectedTradeSymbol()      { return SelectedTrade.Symbol; }
ENUM_ORDER_TYPE SelectedTradeType()        { return SelectedTrade.Type; }
double          SelectedTradeVolume()      { return SelectedTrade.Volume; }
double          SelectedTradeOpenPrice()   { return SelectedTrade.OpenPrice; }
double          SelectedTradeClosePrice()  { return SelectedTrade.ClosePrice; }
double          SelectedTradeStopLoss()    { return SelectedTrade.StopLoss; }
double          SelectedTradeTakeProfit()  { return SelectedTrade.TakeProfit; }
datetime        SelectedTradeOpenTime()    { return SelectedTrade.OpenTime; }
datetime        SelectedTradeCloseTime()   { return SelectedTrade.CloseTime; }
datetime        SelectedTradeExpiration()  { return SelectedTrade.Expiration; }
double          SelectedTradeProfit()      { return SelectedTrade.Profit; }
double          SelectedTradeSwap()        { return SelectedTrade.Swap; }
double          SelectedTradeCommission()  { return SelectedTrade.Commission; }
string          SelectedTradeComment()     { return SelectedTrade.Comment; }
long            SelectedTradeMagic()       { return SelectedTrade.Magic; }


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
double StartLots_rw=0.0;
input int    MaxAllowedDD=30  ;    //Max Allowed TOTAL Drawdown
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
  double    CurrentSpreadPrice = 0.0;
  double    UnusedLegacyDouble002 = 0.0;
  int       UnusedLegacyInt003 = 30;
  int       UnusedLegacyInt004 = 1440;
  int       UnusedLegacyInt005 = 0;
  double    UnusedLegacyDoubleArray006[];
  double    LotSizeReferenceBalance = 0.0;
  double    VariableValueScaleFactor = 0.0;
  double    VariableLotInverseScaleFactor = 0.0;
  bool      UnusedLegacyBool010 = false;
  int       UnusedLegacyInt011 = 3;
  int       UnusedLegacyInt012 = 2;
  bool      UnusedLegacyBool013 = false;
  bool      UnusedLegacyBool014 = false;
  int       RandomizedPendingEntryOffsetPips = 0;
  string    TradingFiltersHeader = "------------------------------ trading filters ------------------------------";
  bool      OneChartSetupEnabled = false;
  string    OneChartSymbolList = "EURUSD;GBPUSD;USDJPY;AUDJPY;AUDUSD;EURAUD;EURCAD;EURGBP;EURJPY;GBPJPY;USDCAD;USDCHF;";
  int       ActiveTradeFrequency = 5;
  bool      EnableStrategy1 = true;
  bool      UnusedLegacyBool021 = false;
  bool      UnusedLegacyBool022 = false;
  bool      EnableStrategy2 = true;
  bool      UnusedLegacyBool024 = false;
  bool      UnusedLegacyBool025 = false;
  bool      EnableStrategy3 = true;
  bool      EnableStrategy4 = false;
  bool      EnableStrategy6 = false;
  bool      UnusedLegacyBool029 = false;
  bool      UnusedLegacyBool030 = false;
  bool      EnableStrategy5 = false;
  bool      EnableStrategy9 = false;
  bool      EnableStrategy7 = false;
  bool      EnableStrategy8 = false;
  bool      SuspendPendingOrdersOnHighSpreadEnabled = true;
  int       MinPendingMarketGapPips = 2;
  double    MaxSpreadPips = 0.0;
  double    OrderSlippageSetting = 5000.0;
  int       SlippageControlMode = 1;
  double    SlippageRecoveryTriggerPips = 400.0;
  double    SlippageRecoveryTrailDistancePips = 100.0;
  double    SlippageRecoveryMaximumStopPips = 300.0;
  bool      UseRequestedEntryAsTrailReference = true;
  string    TimeFiltersHeader = "------------------------------ time filters ------------------------------";
  bool      FridayStopEnabled = false;
  bool      RestorePendingOrdersAfterFridayPause = false;
  bool      UnusedLegacyBool047 = false;
  int       UnusedLegacyInt048 = 14;
  int       UnusedLegacyInt049 = 17;
  string    OtherFiltersHeader = "------------------------------ other filters ------------------------------";
  int       CandleExitOpenBarShift = 1;
  int       CandleExitM1TimeframeMinutes = 1;
  bool      CandleExitM1Enabled = false;
  int       CandleExitM5TimeframeMinutes = 5;
  bool      CandleExitM5Enabled = false;
  int       CandleExitM15TimeframeMinutes = 15;
  bool      CandleExitM15Enabled = false;
  int       CandleExitM30TimeframeMinutes = 30;
  bool      CandleExitM30Enabled = false;
  int       CandleExitH1TimeframeMinutes = 60;
  bool      CandleExitH1Enabled = false;
  bool      ShowTradeDebugComments = false;
  int       TradeMonitorFilterMode = 1;
  double    ExtraStopLossPips = 0.0;
  int       VirtualStopSyncIntervalSeconds = 99;
  int       UnusedLegacyInt066 = 5;
  bool      VirtualPendingOrdersEnabled = false;
  int       DayChangeRecoveryDelayMinutes = 5;
  int       EntryStrategyMode = 1;
  string    EntryManagementHeader = "------------------------------ Trade Entry management ------------------------------";
  int       SignalTimeframeMinutes = 0;
  int       EntryTimingTimeframeMinutes = 60;
  int       SwingLeftBars = 10;
  int       SwingRightBars = 3;
  bool      FakeoutConfirmationEnabled = false;
  bool      UnusedLegacyBool076 = false;
  int       EntryLookbackBars = 120;
  int       UnusedLegacyInt078 = 0;
  int       UnusedLegacyInt079 = 0;
  double    MinEntryDistancePips = 30.0;
  double    MinimumEntryDistancePercent = 0.0;
  double    UnusedLegacyDouble082 = 25.0;
  double    BuyEntryOffsetPips = 0.5;
  double    SellEntryOffsetPips = 0.0;
  double    RequestedEntryAdjustmentPips = 0.0;
  int       MaxPendingOrders = 1;
  int       MaxOpenTradesPerSide = 99;
  double    DuplicatePendingTolerancePips = 1.0;
  int       PendingExpirationHours = 24;
  double    UnusedLegacyDouble090 = 3.0;
  int       UnusedLegacyInt091 = 0;
  int       LotSizePercentMultiplier = 100;
  int       StrategyMagicNumber = 0;
  string    ManualStrategy2Header = "------------------------------ Strategy 2 - Manual Trade settings ------------------------------";
  int       ManualTradeSymbolFilterMode = 1;
  int       ManualStrategy2MagicNumber = 1991199118;
  string    ManualStrategy2Comment = "";
  string    ExitManagementHeader = "------------------------------ Trade Exit management ------------------------------";
  int       ExitTimingMode = 0;
  double    StopLossPips = 20.0;
  double    TakeProfitPips = 100.0;
  string    TrailingStopHeader = "------------------------------ Trailing SL settings ------------------------------";
  double    TrailingSLStartPips = 10.0;
  double    TrailingSLDistancePips = 10.0;
  double    TrailingSLStepLimitPips = 100.0;
  double    TrailingActivationBufferPips = 0.1;
  double    TrailingPartialClosePercent = 0.0;
  double    TrailingTPStartPips = 0.0;
  double    TrailingTPDistancePips = 0.0;
  double    UnusedLegacyDouble110 = 0.0;
  double    UnusedLegacyDouble111 = 0.0;
  string    BreakEvenHeader = "------------------------------ Break-even SL management ------------------------------";
  double    BreakEvenStartPips = 0.0;
  double    BreakEvenExtraPips = 0.0;
  string    HighLowTrailingHeader = "------------------------------ HIGH/LOW Trailing SL settings ------------------------------";
  bool      HighLowTrailingEnabled = false;
  int       HighLowTrailingTimeframeMinutes = 0;
  int       SwingQualificationMinimumShift = 0;
  int       HighLowLeftBars = 0;
  int       HighLowRightBars = 0;
  int       HighLowLookbackBars = 0;
  int       HighLowMinimumMarketGapPips = 0;
  double    HighLowTrailingOffsetPips = 2.0;
  string    TimeRecoveryTrailingHeader = "------------------------------ recovery Trailing SL based on time ------------------------------";
  double    TimeRecoveryAfterMinutes = 0.0;
  double    TimeRecoveryStopPips = 0.0;
  string    MagicTrailHeader = "------------------------------ MagicTrail SL settings ------------------------------";
  int       MagicTrailMode = 0;
  double    MagicTrailActivationDistancePips = 0.1;
  int       MagicTrailMinimumTickCount = 1;
  double    MagicTrailStepPips = 0.1;
  double    MagicTrailMode2SpreadBufferPips = 1.0;
  int       MagicTrailDelayMinutes = 0;
  double    MagicTrailDelayedActivationPips = 0.0;
  bool      ReturnAfterStopModification = false;
  bool      UnusedLegacyBool136 = false;
  int       LicenseYearMarker = 2024;
  datetime  MonthBoundaryDates[13];
  bool      DynamicLotSizingEnabled = false;
  double    PendingLotResizeThresholdPercent = 5.0;
  double    MaxCalculatedLotSize = 99.0;
  int       UnusedLegacyInt142 = 999;
  int       UnusedLegacyInt143 = 9999;
  int       UnusedLegacyInt144 = 99999;
  int       LotSizingBalanceDivisor = 600;
  double    WeightedRiskPercentPerStrategy = 1.0;
  double    UnusedLegacyDouble147 = 10.0;
  double    FixedRiskPercent = 2.0;
  string    PerformanceHeader = "==== Performance numbers overview ====";
  bool      ShowPerformanceOverview = true;
  int       PerformanceCalculationMode = 1;
  int       StrategyRankingMode = 1;
  int       PerformanceLookbackDays = 90;
  int       RecentPerformanceDays = 30;
  int       MinTradesForPerformance = 10;
  int       UnusedLegacyInt156 = 50;
  bool      UnusedLegacyBool157 = true;
  string    ZoneRecoveryHeader = "------------------------------ zone_recovery_settings ------------------------------";
  bool      ZoneRecoveryEnabled = false;
  double    ZoneRecoveryInitialDistancePips = 50.0;
  double    ZoneRecoveryStepDistancePips = 10.0;
  double    ZoneRecoveryMinimumDistancePips = 5.0;
  double    ZoneRecoveryProfitTarget = 0.0;
  int       ZoneRecoveryLotSizingMode = 1;
  double    ZoneRecoveryLotMultiplier = 2.0;
  int       ZoneRecoveryMaximumTrades = 999;
  double    UnusedLegacyDouble167 = 100.0;
  int       ZoneRecoveryBuyMagic = 900010;
  int       ZoneRecoverySellMagic = 900011;
  string    TradingHoursHeader = "------------------------- Trading hours ST1 -------------------------";
  bool      TradingHoursEnabled = false;
  int       TradingHoursTimeSource = 2;
  bool      StorePendingOrdersOutsideTradingHours = false;
  int       SundayStartHour = 0;
  int       SundayEndHour = 24;
  int       MondayStartHour = 0;
  int       MondayEndHour = 24;
  int       TuesdayStartHour = 0;
  int       TuesdayEndHour = 24;
  int       WednesdayStartHour = 0;
  int       WednesdayEndHour = 24;
  int       ThursdayStartHour = 0;
  int       ThursdayEndHour = 24;
  int       FridayStartHour = 0;
  int       FridayEndHour = 24;
  string    BacktestOnlyHeader = "------------------------- use for backtesting only! -------------------------";
  int       RandomPendingOffsetMaximumPips = 0;
  double    CachedBuySignalPrice = 0.0;
  double    CachedSellSignalPrice = 0.0;
  int       SymbolDigits = 0;
  double    ActiveVirtualStopPrice = 0.0;
  int       BuyZoneNextOrderSide = 0;
  int       SellZoneNextOrderSide = 0;
  bool      BuyZoneStateInitialized = false;
  bool      SellZoneStateInitialized = false;
  double    VirtualStopByTicket[20][2];
  double    StoredPendingOrders[100][3];
  double    PendingTicketPriceMap[100][2];
  int       SmallBufferCapacity = 20;
  int       OrderBufferCapacity = 100;
  double    LegacyWriteOnlyTradeStateValuePrimary = 0.0;
  double    LegacyWriteOnlyTradeStateValueSecondary = 0.0;
  double    UnusedLegacyDouble203 = 0.0;
  double    UnusedLegacyDouble204 = 0.0;
  double    UnusedLegacyDouble205 = 0.0;
  double    UnusedLegacyDouble206 = 0.0;
  bool      UnusedLegacyBool207 = false;
  int       UnusedLegacyInt208 = 10;
  double    LegacyWriteOnlyUpperPriceSentinel = 0.0;
  double    LegacyWriteOnlyLowerPriceSentinel = 0.0;
  double    UnusedLegacyDouble211 = 0.0;
  double    UnusedLegacyDouble212 = 0.0;
  bool      MovingAverageTrendFilterEnabled = false;
  int       FastMovingAveragePeriod = 1;
  datetime  LastSignalBarTimeByStrategy[99];
  long      LegacyWriteOnlyOrderTicket = 0;
  int       SlowMovingAveragePeriod = 370;
  bool      AllowMultipleOpenTradesPerSide = true;
  bool      UnusedLegacyBool219 = false;
  int       UnusedLegacyInt220 = 0;
  double    StopLevelPriceDistance = 4.0;
  double    UnusedLegacyDouble222 = 0.0;
  double    LotSizeByStrategy[99];
  double    UnusedLegacyDouble224 = 0.0;
  int       UnusedLegacyInt225 = 0;
  int       UnusedLegacyInt226 = 0;
  double    UnusedLegacyDouble227 = 0.0;
  double    UnusedLegacyDouble228 = 0.0;
  double    PipSize = 0.0;
  long      LastTradeTicket = 0; // ticket OrderSend la 64-bit; bool OrderModify van gan duoc 0/1
  bool      LegacyWriteOnlyFractalStateFlag = false;
  double    UnusedLegacyDouble232 = 0.0;
  double    UnusedLegacyDouble233 = 0.0;
  int       PendingExpirationSeconds = 0;
  double    UnusedLegacyDouble235 = 0.0;
  double    UnusedLegacyDouble236 = 0.0;
  double    UnusedLegacyDouble237 = 0.0;
  bool      LegacyWriteOnlyOrderStateFlagPrimary = false;
  bool      LegacyWriteOnlyOrderStateFlagSecondary = false;
  bool      LegacyWriteOnlyTradeStateFlag = false;
  double    BuyTriggerPriceByStrategy[99];
  double    SellTriggerPriceByStrategy[99];
  double    UnusedLegacyDouble243 = 0.0;
  double    UnusedLegacyDouble244 = 0.0;
  double    UnusedLegacyDouble245 = 0.0;
  double    UnusedLegacyDouble246 = 0.0;
  double    ActiveMagicTrailActivationPips = 0.0;
  double    UnusedLegacyDouble248 = 0.0;
  double    UnusedLegacyDouble249 = 0.0;
  int       MagicTrailTickCounter = 0;
  double    LegacyWriteOnlyInitializationTimestamp = 0.0;
  string    BuyComment1;
  string    BuyComment2;
  string    SellComment1;
  string    SellComment2;
  bool      MarketPauseMessageLogged = false;
  bool      LegacyWriteOnlyInitializationFlag = false;
  int       LegacyWriteOnlyInitializationMonth = 0;
  int       UnusedLegacyInt259 = 0;
  double    LegacyWriteOnlyInitializationSecond = 0.0;
  double    CurrentSellEntryPrice = 0.0;
  double    CurrentBuyEntryPrice = 0.0;
  double    LastSellSignalCandidatePrice = 0.0;
  double    LastBuySignalCandidatePrice = 0.0;
  int       BuySignalBarShift = 0;
  int       SellSignalBarShift = 0;
  int       LastEntryHour = 0;
  double    FastMovingAverageValue = 0.0;
  double    SlowMovingAverageValue = 0.0;
  double    PreviousUpperFractal = 0.0;
  double    PreviousLowerFractal = 0.0;
  double    CurrentUpperFractal = 0.0;
  double    CurrentLowerFractal = 0.0;
  int       ErrorDescriptionCallCount = 0;
  double    LegacyWriteOnlyFractalStateValue = 0.0;
  double    UnusedLegacyDouble276 = 0.0;
  double    UnusedLegacyDouble277 = 0.0;
  bool      LegacyWriteOnlyVirtualBuyPendingFlag = false;
  bool      LegacyWriteOnlyVirtualSellPendingFlag = false;
  bool      BuyPendingRestoreState = false;
  bool      SellPendingRestoreState = false;
  bool      UnusedLegacyBool282 = false;
  bool      UnusedLegacyBool283 = false;
  double    UnusedLegacyDouble284 = 0.0;
  double    UnusedLegacyDouble285 = 0.0;
  bool      UnusedLegacyBool286 = false;
  double    UnusedLegacyDouble287 = 0.0;
  double    UnusedLegacyDouble288 = 0.0;
  int       LegacyWriteOnlyInitializationCounter = 0;
  int       LegacyWriteOnlyInitializationHour = 0;
  double    UnusedLegacyDoubleArray291[10];
  double    UnusedLegacyDoubleArray292[10];
  double    UnusedLegacyDoubleArray293[10];
  double    UnusedLegacyDoubleArray294[10];
  int       UnusedLegacyInt295 = 0;
  int       UnusedLegacyInt296 = 0;
  int       LegacyWriteOnlyCommentStateCounterPrimary = 0;
  int       LegacyWriteOnlyCommentStateCounterSecondary = 0;
  string    SymbolSuffix;
  double    LegacyWriteOnlyEntryStateValuePrimary = 0.0;
  double    LegacyWriteOnlyEntryStateValueSecondary = 0.0;
  datetime  PendingOrderExpirationTime = 0;
  bool      TradingHoursState = false;
  int       TimeRecoveryDelaySeconds = 0;
  bool      FridayTradingSuspended = false;
  int       CurrentChartBars = 0;
  double    InitialAccountBalance = 0.0;
  double    UnusedLegacyDouble308 = 0.0;
  double    FreezeLevelPriceDistance = 0.0;
  double    LastBuyPendingBasePrice = 0.0;
  double    LastSellPendingBasePrice = 0.0;
  bool      DemoAccountDetectedFlag = false;
  datetime  LegacyWriteOnlyPreviousWeeklyBarTime = 0;
  datetime  LegacyWriteOnlyPreviousMonthlyBarTimePrimary = 0;
  datetime  LegacyWriteOnlyPreviousMonthlyBarTimeSecondary = 0;
  bool      UnusedLegacyBool316 = false;
  bool      UnusedLegacyBool317 = false;
  double    LastLotResizeBalance = 0.0;
  datetime  LastVirtualStopSyncTime = 0;
  bool      NfpTradingSuspended = false;
  int       LastExitBarCountByStrategy[99];
  int       LastEntryBarCountByStrategy[99];
  double    OpenProfitByStrategy[30];
  double    WinningTradesByStrategy[30];
  double    LosingTradesByStrategy[30];
  double    ClosedProfitByStrategy[30];
  int       UnusedLegacyInt327 = 1;
  int       CurrentStrategyIndex = 0;
  uint      PanelTextColor = DarkBlue;
  bool      UnusedLegacyBool330 = false;
  long      UnusedLegacyLong331 = 0;
  int       UnusedLegacyInt332 = 5;
  bool      UnusedLegacyBool333 = false;
  string    CurrentStrategyComment;
  bool      UnusedLegacyBool335 = false;
  string    CurrentSymbol;
  double    SymbolPoint = 0.0;
  double    UnusedLegacyDouble338 = 0.0;
  int       RankedStrategyIndexes[99];
  int       PanelStrategyRowStartIndex = 0;
  double    UnusedLegacyDoubleArray341[99];
  bool      PerformanceHistoryComplete[99];
  int       TotalTradeCountByStrategy[99];
  int       RecentTradeCountByStrategy[99];
  double    AverageProfitByStrategy[99];
  double    RecentAverageProfitByStrategy[99];
  string    StrategySymbols[99]={};
  bool      UnusedLegacyBoolArray348[99];
  double    TotalProfitByStrategy[99];
  double    RecentProfitByStrategy[99];
  double    UnusedLegacyDoubleArray351[99];
  double    UnusedLegacyDoubleArray352[99];
  double    UnusedLegacyDoubleArray353[99];
  double    StrategyLotWeights[99];
  bool      UnusedLegacyBoolArray355[99];
  int       StrategyRanks[99];
  bool      UnusedLegacyBool357 = false;
  double    LegacyWriteOnlyPanelSpacingPrimary = 5.0;
  double    LegacyWriteOnlyPanelSpacingSecondary = 10.0;
  int       PanelObjectCount = 0;
  double    PanelRowWidth = 0.0;
  double    PanelRowHeight = 0.0;
  int       LegacyWriteOnlyPanelColumnCount = 0;
  uint      PanelCellBackgroundColor = LightSteelBlue;
  bool      UnusedLegacyBool365 = true;
  double    UnusedLegacyDouble366 = 12.0;
  int       UnusedLegacyInt367 = 230;
  int       UnusedLegacyInt368 = 320;
  int       UnusedLegacyInt369 = 500;
  int       UnusedLegacyInt370 = 350;
  int       UnusedLegacyInt371 = 2;
  int       PanelFontSize = 7;
  int       UnusedLegacyInt373 = 10;
  int       UnusedLegacyInt374 = 30;
  string    UnusedLegacyStringArray375[4]={};
  double    PanelWidthScaleFactor = 0.45;
  double    PanelHeightScaleFactor = 0.6;
  int       StrategySymbolCount = 0;
  datetime  LastPanelRefreshM5BarTime = 0;
  bool      PairInitializationSucceeded = false;
  int       PanelRefreshTickCounter = 0;
  bool      DailyDrawdownLockActive = false;
  int       LastDailyBarCount = 0;
  double    DailyDrawdownReference = 0.0;
  int       AutoFrequencyThreshold1 = 200;
  int       AutoFrequencyThreshold2 = 330;
  int       AutoFrequencyThreshold3 = 560;
  int       AutoFrequencyThreshold4 = 810;
  int       AutoFrequencyThreshold5 = 1150;
  datetime  CurrentGmtTime = 0;
  datetime  NfpDatesGmt[300];
  bool      UsDaylightSavingState = false;
  bool      EuropeDaylightSavingState = false;
  bool      GmtDetectionInitialized = false;
  int       BrokerGmtOffsetHours = 0;
  int       DetectedUtcOffsetHours = 0;
  double    StrategyDrawdownReferenceUsd = 0.0;
  double    EnabledStrategyRiskWeight = 0.0;
  datetime  LastPerformanceRefreshH1BarTime = 0;
  double    StrategyDisplayProfit[99];
  double    CurrentBalanceBasis = 0.0;
  double    HighestBalanceBasis = 0.0;
  bool      NfpFromCalendar = false;      // true neu nfpDatesGmt[] dang lay tu Lich MQL5 (khong con dung mang hardcode)
  datetime  NfpCalendarBuiltDay = 0;      // ngay (00:00, GMT) lan gan nhat da thu lam moi tu Lich MQL5
  int       NfpStatus = 0;                // trang thai lay tin NFP cho panel: 0 = binh thuong (dung nfpDatesGmt[]), 2 = loi lay tin (Lich MQL5 khong doc duoc). mq5 dung Lich (khong co link) nen khong co trang thai thieu link (=1)
  long      OnlyUpRunId = 0;              // ma rieng cho moi lan chay Strategy Tester, dung de tach biet dinh OnlyUp giua cac lan backtest (xem OnlyUpPeakGVName)
  long      OnlyUpWithdrawScannedMsc = 0;  // moc DEAL_TIME_MSC da xu ly, tranh tru lap giao dich rut tien sau khi EA khoi dong lai

//+------------------------------------------------------------------+
//| Lay ngay NFP (Non-Farm Payrolls) tu Lich kinh te (Economic       |
//| Calendar) co san cua MQL5, thay cho mang nfpDatesGmt[]   |
//| ma hoa cung. Neu khong tim/lay duoc (vi du: khong kha dung trong |
//| Strategy Tester cua broker nay) thi GIU NGUYEN mang hardcode co  |
//| san de kiem thu nguoc (backtest) van chay binh thuong.           |
//+------------------------------------------------------------------+
 void BuildNFPDatesFromCalendar()
 {
  NfpCalendarBuiltDay = (datetime)(TimeCurrent() - TimeCurrent() % SECONDS_PER_DAY) ;
  MqlCalendarEvent CalendarEvents[];
  int       CalendarEventCount = CalendarEventByCountry("US",CalendarEvents) ;
  long      NonfarmPayrollEventId = -1;
  int       CalendarItemIndex;
  string    NormalizedEventCode;
//----------------------------------------------------------------------
 if ( CalendarEventCount <= 0 )   { NfpStatus = 2 ; return; } // Lich MQL5 khong doc duoc -> panel bao loi lay tin
 for (CalendarItemIndex = 0 ; CalendarItemIndex < CalendarEventCount ; CalendarItemIndex ++)
 {
   // MqlCalendarEvent.name tra ve theo NGON NGU CUA TERMINAL (tai lieu MQL5)
   // nen so sanh chuoi tieng Anh co the khong bao gio khop neu terminal dat
   // ngon ngu khac. event_code moi la ma dinh danh CO DINH, khong phu thuoc
   // ngon ngu (vi du "NONFARM-PAYROLLS") - dung field nay lam chinh, giu lai
   // kiem tra .name nhu du phong.
   NormalizedEventCode = CalendarEvents[CalendarItemIndex].event_code ;
   StringToUpper(NormalizedEventCode) ;
   if ( StringFind(NormalizedEventCode,"NONFARM") >= 0 || StringFind(CalendarEvents[CalendarItemIndex].name,"Nonfarm Payrolls") >= 0 || StringFind(CalendarEvents[CalendarItemIndex].name,"Non-Farm Payrolls") >= 0 || StringFind(CalendarEvents[CalendarItemIndex].name,"Non Farm Payrolls") >= 0 )
   {
     NonfarmPayrollEventId = (long)CalendarEvents[CalendarItemIndex].id ;
     break;
   }
 }
 if ( NonfarmPayrollEventId < 0 )   { NfpStatus = 2 ; return; } // khong tim thay su kien NFP trong Lich -> loi lay tin
 MqlCalendarValue CalendarValues[];
 datetime  CalendarHistoryStart = D'2007.01.01 00:00';
 datetime  CalendarHistoryEnd = TimeCurrent() + 400 * 24 * 60 * 60 ;
 int       CalendarValueCount = CalendarValueHistoryByEvent((ulong)NonfarmPayrollEventId,CalendarValues,CalendarHistoryStart,CalendarHistoryEnd) ;
 if ( CalendarValueCount <= 0 )   { NfpStatus = 2 ; return; } // khong lay duoc gia tri lich NFP -> loi lay tin
 // currentGmtTime (GMT hien tai) da duoc tinh xong truoc khi ham nay duoc goi (xem
 // OnTick). MqlCalendarValue.time tra ve theo GIO SERVER, trong khi
 // nfpDatesGmt[] va toan bo bo loc NFP con lai dang quy uoc luu GIO GMT roi
 // moi cong offset de quy doi sang gio server luc so sanh/hien thi. TimeCurrent()-
 // currentGmtTime chinh la offset GMT bo loc dang dung tai thoi diem nay (du la tu
 // AutoGMT/WebRequest thanh cong hay phai roi ve TimeGMT()), nen dung gia tri nay de
 // tru truoc khi luu, tranh bi quy doi 2 lan.
 long      ServerToGmtOffsetSeconds = (long)(TimeCurrent() - CurrentGmtTime) ;
 int       ValidNfpDateCount = 0;
 for (CalendarItemIndex = 0 ; CalendarItemIndex < CalendarValueCount && ValidNfpDateCount < 300 ; CalendarItemIndex ++)
 {
   if ( CalendarValues[CalendarItemIndex].time <= 0 )   continue;
   NfpDatesGmt[ValidNfpDateCount] = (datetime)(CalendarValues[CalendarItemIndex].time - ServerToGmtOffsetSeconds) ;
   ValidNfpDateCount ++;
 }
 if ( ValidNfpDateCount <= 0 )   { NfpStatus = 0 ; return; } // lay tin OK nhung khong co ngay hop le -> "No News Coming Up"
 for (CalendarItemIndex = ValidNfpDateCount ; CalendarItemIndex < 300 ; CalendarItemIndex ++)   NfpDatesGmt[CalendarItemIndex] = 0 ;
 NfpFromCalendar = true ;
 NfpStatus = 0 ; // lay Lich thanh cong -> panel hien binh thuong (Next NFP / No News)
 }
//BuildNFPDatesFromCalendar <<==--------   --------

//+------------------------------------------------------------------+
//| Dieu chinh dinh OnlyUp khi tai khoan co giao dich rut tien.       |
//| Trong MT5, nap/rut tien duoc ghi thanh DEAL_TYPE_BALANCE; rut     |
//| tien co DEAL_PROFIT am. Dinh cu phai giam dung bang so tien rut,  |
//| nhung khong duoc thap hon balance/equity hien tai.                |
//+------------------------------------------------------------------+
 void ApplyOnlyUpWithdrawal(double Amount)
 {
  if ( !(OnlyUp) || ManualBalance>0.0 || Amount>=0.0 )   return;
  HighestBalanceBasis = HighestBalanceBasis + Amount ; // amount am => tru tien rut khoi dinh
  double CurrentOnlyUpBasisValue = AccountInfoDouble(ACCOUNT_BALANCE) ;
  if ( UseEquity )   CurrentOnlyUpBasisValue = AccountInfoDouble(ACCOUNT_EQUITY) ;
  if ( HighestBalanceBasis<CurrentOnlyUpBasisValue )   HighestBalanceBasis = CurrentOnlyUpBasisValue ;
  if ( HighestBalanceBasis<0.0 )   HighestBalanceBasis = 0.0 ;
  GlobalVariableSet(OnlyUpPeakGVName(),HighestBalanceBasis) ;
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
  long ReconcileTimestampMsc = (long)TimeCurrent() * 1000 ;
  if ( OnlyUpWithdrawScannedMsc<=0 )
  {
    OnlyUpWithdrawScannedMsc = ReconcileTimestampMsc ;
    GlobalVariableSet(OnlyUpWithdrawGVName(),(double)OnlyUpWithdrawScannedMsc) ;
    return;
  }
  datetime HistoryScanStart = (datetime)(OnlyUpWithdrawScannedMsc / 1000) ;
  datetime HistoryScanEnd = TimeCurrent() ;
  if ( HistoryScanStart>HistoryScanEnd )   HistoryScanStart = HistoryScanEnd ;
  if ( !(HistorySelect(HistoryScanStart,HistoryScanEnd)) )   return;
  int HistoryDealCount = HistoryDealsTotal() ;
  double WithdrawalTotal = 0.0 ;
  long LatestProcessedDealMsc = OnlyUpWithdrawScannedMsc ;
  for (int HistoryDealIndex = 0 ; HistoryDealIndex < HistoryDealCount ; HistoryDealIndex ++)
  {
    ulong HistoryDealTicket = HistoryDealGetTicket(HistoryDealIndex) ;
    if ( HistoryDealTicket==0 )   continue;
    long HistoryDealTimeMsc = (long)HistoryDealGetInteger(HistoryDealTicket,DEAL_TIME_MSC) ;
    if ( HistoryDealTimeMsc<=OnlyUpWithdrawScannedMsc )   continue;
    if ( HistoryDealTimeMsc>LatestProcessedDealMsc )   LatestProcessedDealMsc = HistoryDealTimeMsc ;
    ENUM_DEAL_TYPE HistoryDealType = (ENUM_DEAL_TYPE)HistoryDealGetInteger(HistoryDealTicket,DEAL_TYPE) ;
    if ( HistoryDealType!=DEAL_TYPE_BALANCE )   continue;
    double HistoryDealAmount = HistoryDealGetDouble(HistoryDealTicket,DEAL_PROFIT) ;
    if ( HistoryDealAmount<0.0 )   WithdrawalTotal = WithdrawalTotal + HistoryDealAmount ;
  }
  if ( WithdrawalTotal<0.0 )   ApplyOnlyUpWithdrawal(WithdrawalTotal) ;
  if ( ReconcileTimestampMsc>LatestProcessedDealMsc )   LatestProcessedDealMsc = ReconcileTimestampMsc ;
  OnlyUpWithdrawScannedMsc = LatestProcessedDealMsc ;
  GlobalVariableSet(OnlyUpWithdrawGVName(),(double)OnlyUpWithdrawScannedMsc) ;
 }
//ReconcileOnlyUpWithdrawals <<==--------   --------

 int OnInit()
 {
TradeExecutor.SetAsyncMode(false);
TradeExecutor.LogLevel(LOG_LEVEL_NO);

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

StartLots_rw=StartLots;
  double    AccountBalanceUsd;
  double    AllowedDrawdownUsd;
  int       RiskBufferRowIndex;
  int       VirtualStopFieldIndex;
  int       StoredOrderRowIndex;
  int       StoredOrderFieldIndex;
  int       StoredOrderResetIndex;
  int       StrategyInitializationIndex;
//----------------------------------------------------------------------
 // Bien local can duoc khoi tao ro rang de giu hanh vi xac dinh
 // ro rang de giu dung hanh vi ban goc (bien nay khong duoc gan truoc khi
 // dung o duoi, ket qua nhan dien demo duoc co y bo qua trong logic goc).
 bool       IgnoredDemoDetectionResult = false;

 // Sinh ma rieng cho lan chay Strategy Tester nay (xem OnlyUpPeakGVName) -
 // GetTickCount() (mili-giay tu luc terminal khoi dong) + so ngau nhien de
 // moi lan backtest deu co ma khac nhau, tranh trung khi nhieu agent toi uu
 // hoa chay song song va bat dau o cung mot thoi diem. MathRand() bat buoc
 // phai MathSrand() truoc thi moi cho ra chuoi so khac nhau giua cac lan
 // chay (theo tai lieu MQL5) - neu khong se luon ra cung 1 gia tri co dinh
 // moi lan khoi dong, lam mat tac dung chong trung.
 // SetFontSize >0: ghi de co chu panel (0 = co mac dinh theo thiet ke goc)
 if ( SetFontSize > 0 )   PanelFontSize = SetFontSize ;
 MathSrand((int)GetTickCount()) ;
 OnlyUpRunId = (long)GetTickCount() * 1000 + MathRand() ;

 CurrentBalanceBasis = AccountInfoDouble(ACCOUNT_BALANCE) ;
 if ( UseEquity )
 {
   CurrentBalanceBasis = AccountInfoDouble(ACCOUNT_EQUITY) ;
 }
 if ( ManualBalance>0.0 )
 {
   CurrentBalanceBasis = ManualBalance ;
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
 bool StoredOnlyUpPeakExists = (OnlyUp && GlobalVariableCheck(OnlyUpPeakGVName())) ;
 datetime StoredOnlyUpPeakSaveTime = 0 ;
 if ( StoredOnlyUpPeakExists )   StoredOnlyUpPeakSaveTime = GlobalVariableTime(OnlyUpPeakGVName()) ;
 if ( StoredOnlyUpPeakExists )
 {
   HighestBalanceBasis = GlobalVariableGet(OnlyUpPeakGVName()) ;
 }
 else
 {
   HighestBalanceBasis = CurrentBalanceBasis ;
 }
 if ( OnlyUp )
 {
   // Ban moi da co moc quet rieng. Khi nang cap tu ban cu, dung thoi diem dinh
   // da duoc luu lam moc dau de co the bu lai cac lan rut tien xay ra sau do.
   if ( GlobalVariableCheck(OnlyUpWithdrawGVName()) )
   {
     OnlyUpWithdrawScannedMsc = (long)GlobalVariableGet(OnlyUpWithdrawGVName()) ;
   }
   else
   {
     if ( StoredOnlyUpPeakExists && StoredOnlyUpPeakSaveTime>0 )
       OnlyUpWithdrawScannedMsc = (long)StoredOnlyUpPeakSaveTime * 1000 ;
     else
       OnlyUpWithdrawScannedMsc = (long)TimeCurrent() * 1000 ;
   }
   ReconcileOnlyUpWithdrawals() ;
   // Neu balance/equity hien tai da tao dinh moi (vi du sau loi nhuan hoac nap
   // tien), dinh moi van phai duoc uu tien sau khi da bu cac khoan rut.
   if ( CurrentBalanceBasis>HighestBalanceBasis )   HighestBalanceBasis = CurrentBalanceBasis ;
   GlobalVariableSet(OnlyUpPeakGVName(),HighestBalanceBasis) ;
   GlobalVariableSet(OnlyUpWithdrawGVName(),(double)OnlyUpWithdrawScannedMsc) ;
 }
 else
 {
   HighestBalanceBasis = CurrentBalanceBasis ;
 }
 UsDaylightSavingState = false ;
 EuropeDaylightSavingState = false ;
 NfpDatesGmt[0] = D'2026.12.04 12:30';
 NfpDatesGmt[1] = D'2026.11.06 12:30';
 NfpDatesGmt[2] = D'2026.10.02 12:30';
 NfpDatesGmt[3] = D'2026.09.04 12:30';
 NfpDatesGmt[4] = D'2026.08.07 12:30';
 NfpDatesGmt[5] = D'2026.07.02 12:30';
 NfpDatesGmt[6] = D'2026.06.05 12:30';
 NfpDatesGmt[7] = D'2026.05.08 12:30';
 NfpDatesGmt[8] = D'2026.04.03 12:30';
 NfpDatesGmt[9] = D'2026.03.06 12:30';
 NfpDatesGmt[10] = D'2026.02.11 12:30';
 NfpDatesGmt[11] = D'2026.01.09 12:30';
 NfpDatesGmt[12] = D'2025.12.16 12:30';
 NfpDatesGmt[13] = D'2025.11.07 12:30';
 NfpDatesGmt[14] = D'2025.10.03 12:30';
 NfpDatesGmt[15] = D'2025.09.05 12:30';
 NfpDatesGmt[16] = D'2025.08.01 12:30';
 NfpDatesGmt[17] = D'2025.07.03 12:30';
 NfpDatesGmt[18] = D'2025.06.06 12:30';
 NfpDatesGmt[19] = D'2025.05.02 12:30';
 NfpDatesGmt[20] = D'2025.04.04 12:30';
 NfpDatesGmt[21] = D'2025.03.07 12:30';
 NfpDatesGmt[22] = D'2025.02.07 12:30';
 NfpDatesGmt[23] = D'2025.01.10 12:30';
 NfpDatesGmt[24] = D'2024.12.06 12:30';
 NfpDatesGmt[25] = D'2024.11.01 12:30';
 NfpDatesGmt[26] = D'2024.10.04 12:30';
 NfpDatesGmt[27] = D'2024.09.06 12:30';
 NfpDatesGmt[28] = D'2024.08.02 12:30';
 NfpDatesGmt[29] = D'2024.07.05 12:30';
 NfpDatesGmt[30] = D'2024.06.07 12:30';
 NfpDatesGmt[31] = D'2024.05.03 12:30';
 NfpDatesGmt[32] = D'2024.04.05 12:30';
 NfpDatesGmt[33] = D'2024.03.08 12:30';
 NfpDatesGmt[34] = D'2024.02.02 12:30';
 NfpDatesGmt[35] = D'2024.01.05 12:30';
 NfpDatesGmt[36] = D'2023.12.08 12:30';
 NfpDatesGmt[37] = D'2023.11.03 12:30';
 NfpDatesGmt[38] = D'2023.10.06 12:30';
 NfpDatesGmt[39] = D'2023.09.01 12:30';
 NfpDatesGmt[40] = D'2023.08.04 12:30';
 NfpDatesGmt[41] = D'2023.07.07 12:30';
 NfpDatesGmt[42] = D'2023.06.02 12:30';
 NfpDatesGmt[43] = D'2023.05.05 12:30';
 NfpDatesGmt[44] = D'2023.04.07 12:30';
 NfpDatesGmt[45] = D'2023.03.10 12:30';
 NfpDatesGmt[46] = D'2023.02.03 12:30';
 NfpDatesGmt[47] = D'2023.01.06 12:30';
 NfpDatesGmt[48] = D'2022.12.02 12:30';
 NfpDatesGmt[49] = D'2022.11.04 12:30';
 NfpDatesGmt[50] = D'2022.10.07 12:30';
 NfpDatesGmt[51] = D'2022.09.02 12:30';
 NfpDatesGmt[52] = D'2022.08.05 12:30';
 NfpDatesGmt[53] = D'2022.07.08 12:30';
 NfpDatesGmt[54] = D'2022.06.03 12:30';
 NfpDatesGmt[55] = D'2022.05.06 12:30';
 NfpDatesGmt[56] = D'2022.04.01 12:30';
 NfpDatesGmt[57] = D'2022.03.04 12:30';
 NfpDatesGmt[58] = D'2022.02.04 12:30';
 NfpDatesGmt[59] = D'2022.01.07 12:30';
 NfpDatesGmt[60] = D'2021.12.03 12:30';
 NfpDatesGmt[61] = D'2021.11.05 12:30';
 NfpDatesGmt[62] = D'2021.10.08 12:30';
 NfpDatesGmt[63] = D'2021.09.03 12:30';
 NfpDatesGmt[64] = D'2021.08.06 12:30';
 NfpDatesGmt[65] = D'2021.07.02 12:30';
 NfpDatesGmt[66] = D'2021.06.04 12:30';
 NfpDatesGmt[67] = D'2021.05.07 12:30';
 NfpDatesGmt[68] = D'2021.04.02 12:30';
 NfpDatesGmt[69] = D'2021.03.05 12:30';
 NfpDatesGmt[70] = D'2021.02.05 12:30';
 NfpDatesGmt[71] = D'2021.01.08 12:30';
 NfpDatesGmt[72] = D'2020.12.04 12:30';
 NfpDatesGmt[73] = D'2020.11.06 12:30';
 NfpDatesGmt[74] = D'2020.10.02 12:30';
 NfpDatesGmt[75] = D'2020.09.04 12:30';
 NfpDatesGmt[76] = D'2020.08.07 12:30';
 NfpDatesGmt[77] = D'2020.07.02 12:30';
 NfpDatesGmt[78] = D'2020.06.05 12:30';
 NfpDatesGmt[79] = D'2020.05.08 12:30';
 NfpDatesGmt[80] = D'2020.04.03 12:30';
 NfpDatesGmt[81] = D'2020.03.06 12:30';
 NfpDatesGmt[82] = D'2020.02.07 12:30';
 NfpDatesGmt[83] = D'2020.01.10 12:30';
 NfpDatesGmt[84] = D'2019.12.06 12:30';
 NfpDatesGmt[85] = D'2019.11.01 12:30';
 NfpDatesGmt[86] = D'2019.10.04 12:30';
 NfpDatesGmt[87] = D'2019.09.06 12:30';
 NfpDatesGmt[88] = D'2019.08.02 12:30';
 NfpDatesGmt[89] = D'2019.07.05 12:30';
 NfpDatesGmt[90] = D'2019.06.07 12:30';
 NfpDatesGmt[91] = D'2019.05.03 12:30';
 NfpDatesGmt[92] = D'2019.04.05 12:30';
 NfpDatesGmt[93] = D'2019.03.08 12:30';
 NfpDatesGmt[94] = D'2019.02.01 12:30';
 NfpDatesGmt[95] = D'2019.01.04 12:30';
 NfpDatesGmt[96] = D'2018.12.07 12:30';
 NfpDatesGmt[97] = D'2018.11.02 12:30';
 NfpDatesGmt[98] = D'2018.10.05 12:30';
 NfpDatesGmt[99] = D'2018.09.07 12:30';
 NfpDatesGmt[100] = D'2018.08.03 12:30';
 NfpDatesGmt[101] = D'2018.07.06 12:30';
 NfpDatesGmt[102] = D'2018.06.01 12:30';
 NfpDatesGmt[103] = D'2018.05.04 12:30';
 NfpDatesGmt[104] = D'2018.04.06 12:30';
 NfpDatesGmt[105] = D'2018.03.09 12:30';
 NfpDatesGmt[106] = D'2018.02.02 12:30';
 NfpDatesGmt[107] = D'2018.01.05 12:30';
 NfpDatesGmt[108] = D'2017.12.08 12:30';
 NfpDatesGmt[109] = D'2017.11.03 12:30';
 NfpDatesGmt[110] = D'2017.10.06 12:30';
 NfpDatesGmt[111] = D'2017.09.01 12:30';
 NfpDatesGmt[112] = D'2017.08.04 12:30';
 NfpDatesGmt[113] = D'2017.07.07 12:30';
 NfpDatesGmt[114] = D'2017.06.02 12:30';
 NfpDatesGmt[115] = D'2017.05.05 12:30';
 NfpDatesGmt[116] = D'2017.04.07 12:30';
 NfpDatesGmt[117] = D'2017.03.10 12:30';
 NfpDatesGmt[118] = D'2017.02.03 12:30';
 NfpDatesGmt[119] = D'2017.01.06 12:30';
 NfpDatesGmt[120] = D'2016.12.02 12:30';
 NfpDatesGmt[121] = D'2016.11.04 12:30';
 NfpDatesGmt[122] = D'2016.10.07 12:30';
 NfpDatesGmt[123] = D'2016.09.02 12:30';
 NfpDatesGmt[124] = D'2016.08.05 12:30';
 NfpDatesGmt[125] = D'2016.07.08 12:30';
 NfpDatesGmt[126] = D'2016.06.03 12:30';
 NfpDatesGmt[127] = D'2016.05.06 12:30';
 NfpDatesGmt[128] = D'2016.04.01 12:30';
 NfpDatesGmt[129] = D'2016.03.04 12:30';
 NfpDatesGmt[130] = D'2016.02.05 12:30';
 NfpDatesGmt[131] = D'2016.01.08 12:30';
 NfpDatesGmt[132] = D'2015.12.04 12:30';
 NfpDatesGmt[133] = D'2015.11.06 12:30';
 NfpDatesGmt[134] = D'2015.10.02 12:30';
 NfpDatesGmt[135] = D'2015.09.04 12:30';
 NfpDatesGmt[136] = D'2015.08.07 12:30';
 NfpDatesGmt[137] = D'2015.07.02 12:30';
 NfpDatesGmt[138] = D'2015.06.05 12:30';
 NfpDatesGmt[139] = D'2015.05.08 12:30';
 NfpDatesGmt[140] = D'2015.04.03 12:30';
 NfpDatesGmt[141] = D'2015.03.06 12:30';
 NfpDatesGmt[142] = D'2015.02.06 12:30';
 NfpDatesGmt[143] = D'2015.01.09 12:30';
 NfpDatesGmt[144] = D'2014.12.05 12:30';
 NfpDatesGmt[145] = D'2014.11.07 12:30';
 NfpDatesGmt[146] = D'2014.10.03 12:30';
 NfpDatesGmt[147] = D'2014.09.05 12:30';
 NfpDatesGmt[148] = D'2014.08.01 12:30';
 NfpDatesGmt[149] = D'2014.07.03 12:30';
 NfpDatesGmt[150] = D'2014.06.06 12:30';
 NfpDatesGmt[151] = D'2014.05.02 12:30';
 NfpDatesGmt[152] = D'2014.04.04 12:30';
 NfpDatesGmt[153] = D'2014.03.07 12:30';
 NfpDatesGmt[154] = D'2014.02.07 12:30';
 NfpDatesGmt[155] = D'2014.01.10 12:30';
 NfpDatesGmt[156] = D'2013.12.06 12:30';
 NfpDatesGmt[157] = D'2013.11.08 12:30';
 NfpDatesGmt[158] = D'2013.10.22 12:30';
 NfpDatesGmt[159] = D'2013.09.06 12:30';
 NfpDatesGmt[160] = D'2013.08.02 12:30';
 NfpDatesGmt[161] = D'2013.07.05 12:30';
 NfpDatesGmt[162] = D'2013.06.07 12:30';
 NfpDatesGmt[163] = D'2013.05.03 12:30';
 NfpDatesGmt[164] = D'2013.04.05 12:30';
 NfpDatesGmt[165] = D'2013.03.08 12:30';
 NfpDatesGmt[166] = D'2013.02.01 12:30';
 NfpDatesGmt[167] = D'2013.01.04 12:30';
 NfpDatesGmt[168] = D'2012.12.07 12:30';
 NfpDatesGmt[169] = D'2012.11.02 12:30';
 NfpDatesGmt[170] = D'2012.10.05 12:30';
 NfpDatesGmt[171] = D'2012.09.07 12:30';
 NfpDatesGmt[172] = D'2012.08.03 12:30';
 NfpDatesGmt[173] = D'2012.07.06 12:30';
 NfpDatesGmt[174] = D'2012.06.01 12:30';
 NfpDatesGmt[175] = D'2012.05.04 12:30';
 NfpDatesGmt[176] = D'2012.04.06 12:30';
 NfpDatesGmt[177] = D'2012.03.09 12:30';
 NfpDatesGmt[178] = D'2012.02.03 12:30';
 NfpDatesGmt[179] = D'2012.01.06 12:30';
 NfpDatesGmt[180] = D'2011.12.02 12:30';
 NfpDatesGmt[181] = D'2011.11.04 12:30';
 NfpDatesGmt[182] = D'2011.10.07 12:30';
 NfpDatesGmt[183] = D'2011.09.02 12:30';
 NfpDatesGmt[184] = D'2011.08.05 12:30';
 NfpDatesGmt[185] = D'2011.07.08 12:30';
 NfpDatesGmt[186] = D'2011.06.03 12:30';
 NfpDatesGmt[187] = D'2011.05.06 12:30';
 NfpDatesGmt[188] = D'2011.04.01 12:30';
 NfpDatesGmt[189] = D'2011.03.04 12:30';
 NfpDatesGmt[190] = D'2011.02.04 12:30';
 NfpDatesGmt[191] = D'2011.01.07 12:30';
 NfpDatesGmt[192] = D'2010.12.03 12:30';
 NfpDatesGmt[193] = D'2010.11.05 12:30';
 NfpDatesGmt[194] = D'2010.10.08 12:30';
 NfpDatesGmt[195] = D'2010.09.03 12:30';
 NfpDatesGmt[196] = D'2010.08.06 12:30';
 NfpDatesGmt[197] = D'2010.07.02 12:30';
 NfpDatesGmt[198] = D'2010.06.04 12:30';
 NfpDatesGmt[199] = D'2010.05.07 12:30';
 NfpDatesGmt[200] = D'2010.04.02 12:30';
 NfpDatesGmt[201] = D'2010.03.05 12:30';
 NfpDatesGmt[202] = D'2010.02.05 12:30';
 NfpDatesGmt[203] = D'2010.01.08 12:30';
 NfpDatesGmt[204] = D'2009.12.04 12:30';
 NfpDatesGmt[205] = D'2009.11.06 12:30';
 NfpDatesGmt[206] = D'2009.10.02 12:30';
 NfpDatesGmt[207] = D'2009.09.04 12:30';
 NfpDatesGmt[208] = D'2009.08.07 12:30';
 NfpDatesGmt[209] = D'2009.07.02 12:30';
 NfpDatesGmt[210] = D'2009.06.05 12:30';
 NfpDatesGmt[211] = D'2009.05.08 12:30';
 NfpDatesGmt[212] = D'2009.04.03 12:30';
 NfpDatesGmt[213] = D'2009.03.06 12:30';
 NfpDatesGmt[214] = D'2009.02.06 12:30';
 NfpDatesGmt[215] = D'2009.01.09 12:30';
 NfpDatesGmt[216] = D'2008.12.05 12:30';
 NfpDatesGmt[217] = D'2008.11.07 12:30';
 NfpDatesGmt[218] = D'2008.10.03 12:30';
 NfpDatesGmt[219] = D'2008.09.05 12:30';
 NfpDatesGmt[220] = D'2008.08.01 12:30';
 NfpDatesGmt[221] = D'2008.07.03 12:30';
 NfpDatesGmt[222] = D'2008.06.06 12:30';
 NfpDatesGmt[223] = D'2008.05.02 12:30';
 NfpDatesGmt[224] = D'2008.04.04 12:30';
 NfpDatesGmt[225] = D'2008.03.07 12:30';
 NfpDatesGmt[226] = D'2008.02.01 12:30';
 NfpDatesGmt[227] = D'2008.01.04 12:30';
 NfpDatesGmt[228] = D'2007.12.07 12:30';
 NfpDatesGmt[229] = D'2007.11.02 12:30';
 NfpDatesGmt[230] = D'2007.10.05 12:30';
 NfpDatesGmt[231] = D'2007.09.07 12:30';
 NfpDatesGmt[232] = D'2007.08.03 12:30';
 NfpDatesGmt[233] = D'2007.07.06 12:30';
 NfpDatesGmt[234] = D'2007.06.01 12:30';
 NfpDatesGmt[235] = D'2007.05.04 12:30';
 NfpDatesGmt[236] = D'2007.04.06 12:30';
 NfpDatesGmt[237] = D'2007.03.09 12:30';
 NfpDatesGmt[238] = D'2007.02.02 12:30';
 NfpDatesGmt[239] = D'2007.01.05 12:30';
 // UseMQL5Calendar=true: CHI dung Lich MQL5 lam nguon ngay NFP - xoa sach
 // mang ngay co san vua gan o tren, de khi Lich chua tai duoc/khong co du
 // lieu thi KHONG roi ve mang cu (panel se hien "no news coming up" va bo
 // loc NFP khong co ngay nao cho den khi Lich tra du lieu). Rieng trong
 // Strategy Tester van giu mang co san bat ke cong tac, vi Lich MQL5 khong
 // hoat dong trong tester (gioi han cua nen tang) - giong hanh vi v4.3.
 if ( UseMQL5Calendar && MQLInfoInteger(MQL_TESTER) != 1 )
 {
   for (RiskBufferRowIndex = 0 ; RiskBufferRowIndex < 300 ; RiskBufferRowIndex ++)   NfpDatesGmt[RiskBufferRowIndex] = 0 ;
 }
 if ( Risk == 1234 )
 {
   StartLots_rw = SymbolInfoDouble(CurrentSymbol,SYMBOL_VOLUME_MIN) ;
 }
 if ( TradeFrequency == 5 && Risk == 1234 )
 {
   AccountBalanceUsd = ConvertAccountCurrencyToUsdRounded(AccountInfoDouble(ACCOUNT_BALANCE)) ;
   AllowedDrawdownUsd = MaxAllowedDD / 100.0 * AccountBalanceUsd ;
   if ( AllowedDrawdownUsd>AutoFrequencyThreshold4 )
   {
     ActiveTradeFrequency = 3 ;
   }
   else
   {
     if ( AllowedDrawdownUsd>AutoFrequencyThreshold3 )
     {
       ActiveTradeFrequency = 2 ;
     }
     else
     {
       if ( AllowedDrawdownUsd>AutoFrequencyThreshold2 )
       {
         ActiveTradeFrequency = 1 ;
       }
       else
       {
         ActiveTradeFrequency = 0 ;
       }
     }
   }
 }
 else
 {
   ActiveTradeFrequency = TradeFrequency ;
 }
 if ( ActiveTradeFrequency == 0 )
 {
   EnableStrategy4 = false ;
   EnableStrategy5 = false ;
   EnableStrategy6 = false ;
   EnableStrategy7 = false ;
   EnableStrategy8 = false ;
   EnableStrategy9 = false ;
   EnabledStrategyRiskWeight = 2.4 ;
   if ( UseVariableValues )
   {
     EnabledStrategyRiskWeight = 3.0 ;
   }
 }
 else
 {
   if ( ActiveTradeFrequency == 1 )
   {
     EnableStrategy4 = true ;
     EnableStrategy5 = true ;
     EnableStrategy6 = false ;
     EnableStrategy7 = false ;
     EnableStrategy8 = false ;
     EnableStrategy9 = false ;
     EnabledStrategyRiskWeight = 3.4 ;
     if ( UseVariableValues )
     {
       EnabledStrategyRiskWeight = 4.0 ;
     }
   }
   else
   {
     if ( ActiveTradeFrequency == 2 )
     {
       EnableStrategy4 = true ;
       EnableStrategy5 = true ;
       EnableStrategy6 = true ;
       EnableStrategy7 = true ;
       EnableStrategy8 = false ;
       EnableStrategy9 = false ;
       EnabledStrategyRiskWeight = 4.1 ;
       if ( UseVariableValues )
       {
         EnabledStrategyRiskWeight = 5.0 ;
       }
     }
     else
     {
       if ( ActiveTradeFrequency == 3 )
       {
         EnableStrategy4 = true ;
         EnableStrategy5 = true ;
         EnableStrategy6 = true ;
         EnableStrategy7 = true ;
         EnableStrategy8 = true ;
         EnableStrategy9 = false ;
         EnabledStrategyRiskWeight = 4.8 ;
         if ( UseVariableValues )
         {
           EnabledStrategyRiskWeight = 5.6 ;
         }
       }
       else
       {
         if ( ActiveTradeFrequency == 4 )
         {
           EnableStrategy4 = true ;
           EnableStrategy5 = true ;
           EnableStrategy6 = true ;
           EnableStrategy7 = true ;
           EnableStrategy8 = true ;
           EnableStrategy9 = true ;
           EnabledStrategyRiskWeight = 5.1 ;
           if ( UseVariableValues )
           {
             EnabledStrategyRiskWeight = 6.0 ;
           }
         }
         else
         {
           if ( ActiveTradeFrequency == 6 )
           {
             EnableStrategy1 = RunStrat1 ;
             EnableStrategy2 = RunStrat2 ;
             EnableStrategy3 = RunStrat3 ;
             EnableStrategy4 = RunStrat4 ;
             EnableStrategy5 = RunStrat5 ;
             EnableStrategy6 = RunStrat6 ;
             EnableStrategy7 = RunStrat7 ;
             EnableStrategy8 = RunStrat8 ;
             EnableStrategy9 = RunStrat9 ;
           }
         }
       }
     }
   }
 }
 CurrentStrategyComment = ST1_Comment ;
 DailyDrawdownReference = 0.0 ;
 DailyDrawdownLockActive = false ;
 LastPanelRefreshM5BarTime = 0 ;
 PairInitializationSucceeded = true ;
 LegacyWriteOnlyPanelSpacingPrimary = 5.0 ;
 LegacyWriteOnlyPanelSpacingSecondary = 10.0 ;
 StrategyMagicNumber = ST1_MagicNumber ;
 PanelObjectCount = 300 ;
 PanelRowWidth = PanelFontSize * 25 * PanelWidthScaleFactor * InfoPanelSizeAdjust ;
 PanelRowHeight = PanelFontSize * 3.5 * PanelHeightScaleFactor * InfoPanelSizeAdjust ;
 LegacyWriteOnlyPanelColumnCount = 7 ;
 CurrentStrategyIndex = 0 ;
 CurrentSymbol = Symbol() ;
 SymbolPoint = SymbolInfoDouble(CurrentSymbol,SYMBOL_POINT) ;
 PipSize = SymbolPoint ;
 if ( ( ((double)SymbolInfoInteger(CurrentSymbol,SYMBOL_DIGITS))==3.0 || ((double)SymbolInfoInteger(CurrentSymbol,SYMBOL_DIGITS))==5.0 ) )
 {
   PipSize = SymbolPoint * 10.0 ;
 }
 if ( SymbolInfoInteger(CurrentSymbol,SYMBOL_DIGITS) == 1 )
 {
   PipSize = SymbolPoint / 10.0 ;
 }
 SymbolDigits = (int)((double)SymbolInfoInteger(CurrentSymbol,SYMBOL_DIGITS)) ;
 if ( FridayStopHour <  0 )
 {
   FridayStopEnabled = false ;
 }
 else
 {
   FridayStopEnabled = true ;
 }
 LegacyWriteOnlyInitializationTimestamp = (double)TimeCurrent() ;
 CurrentSpreadPrice = SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK) - SymbolInfoDouble(CurrentSymbol,SYMBOL_BID) ;
 LotSizeByStrategy[CurrentStrategyIndex] = NormalizeDouble(MathFloor(StartLots_rw * 100.0) / 100.0,2);
 if ( SymbolInfoDouble(CurrentSymbol,SYMBOL_VOLUME_STEP)==0.1 )
 {
   LotSizeByStrategy[CurrentStrategyIndex] = NormalizeDouble((MathFloor(StartLots_rw * 10.0)) / 10.0,1);
   if ( LotSizeByStrategy[CurrentStrategyIndex]<0.1 )
   {
     LotSizeByStrategy[CurrentStrategyIndex] = 0.1;
   }
 }
 if ( LotSizeByStrategy[CurrentStrategyIndex]<SymbolInfoDouble(CurrentSymbol,SYMBOL_VOLUME_MIN) )
 {
   LotSizeByStrategy[CurrentStrategyIndex] = SymbolInfoDouble(CurrentSymbol,SYMBOL_VOLUME_MIN);
 }
 if ( LotSizeByStrategy[CurrentStrategyIndex]>SymbolInfoDouble(CurrentSymbol,SYMBOL_VOLUME_MAX) )
 {
   LotSizeByStrategy[CurrentStrategyIndex] = SymbolInfoDouble(CurrentSymbol,SYMBOL_VOLUME_MAX);
 }
 CurrentChartBars = iBars(CurrentSymbol,NormalizeTimeframe(PERIOD_CURRENT)) ;
 if ( MagicTrailStepPips * PipSize<SymbolPoint )
 {
   MagicTrailStepPips = SymbolPoint / PipSize ;
 }
 InitialAccountBalance = AccountInfoDouble(ACCOUNT_BALANCE) ;
 StopLevelPriceDistance = ((double)SymbolInfoInteger(CurrentSymbol,SYMBOL_TRADE_STOPS_LEVEL)) * SymbolPoint ;
 FreezeLevelPriceDistance = ((double)SymbolInfoInteger(CurrentSymbol,SYMBOL_TRADE_FREEZE_LEVEL)) * SymbolPoint ;
 SymbolSuffix = StringSubstr(Symbol(),6,10) ;
 if ( SymbolSuffix != "" )
 {
   Print("Suffix detected: " + SymbolSuffix); 
 }
 if ( ( StringFind(Symbol(),"XAUUSD",0) >= 0 || StringFind(Symbol(),"xauusd",0) >= 0 || StringFind(Symbol(),"GOLD",0) >= 0 || StringFind(Symbol(),"gold",0) >= 0 || StringFind(Symbol(),"Gold",0) >= 0 || StringFind(Symbol(),"GLD",0) >= 0 ) )
 {
   CurrentSymbol = Symbol() ;
   StrategySymbols[StrategySymbolCount] = Symbol();
   LoadStrategy1Profile(); 
   LoadStrategyRuntimeContext(0); 
   StrategySymbolCount ++;
 }
 else
 {
   CurrentSymbol = Symbol() ;
   LoadStrategyRuntimeContext(0); 
 }
 if ( !(PairInitializationSucceeded) )
 {
   Print("Initialisation of pairs failed!"); 
 }
 if ( StopLossPips<=0.0 )
 {
   StopLossPips = 1.0 ;
 }
 if ( TakeProfitPips<=0.0 )
 {
   TakeProfitPips = 1.0 ;
 }
 if ( BreakEvenExtraPips>BreakEvenStartPips )
 {
   BreakEvenExtraPips = BreakEvenStartPips + 0.1 ;
 }
 if ( MinPendingMarketGapPips<FreezeLevelPriceDistance / PipSize )
 {
   MinPendingMarketGapPips = (int)(FreezeLevelPriceDistance / PipSize) ;
 }
 if ( TrailingSLStartPips!=0.0 && TrailingSLStartPips<FreezeLevelPriceDistance / PipSize )
 {
   TrailingSLStartPips = FreezeLevelPriceDistance / PipSize ;
 }
 if ( TrailingSLStartPips!=0.0 && TrailingSLStartPips<StopLevelPriceDistance / PipSize )
 {
   TrailingSLStartPips = StopLevelPriceDistance / PipSize ;
 }
 if ( TimeRecoveryAfterMinutes>0.0 && TimeRecoveryStopPips<FreezeLevelPriceDistance / PipSize )
 {
   TimeRecoveryStopPips = FreezeLevelPriceDistance / PipSize ;
 }
 if ( TimeRecoveryAfterMinutes>0.0 && TimeRecoveryStopPips<StopLevelPriceDistance / PipSize )
 {
   TimeRecoveryStopPips = StopLevelPriceDistance / PipSize ;
 }
 if ( StopLossPips<StopLevelPriceDistance * 2.0 / PipSize )
 {
   StopLossPips = StopLevelPriceDistance * 2.0 / PipSize ;
 }
 if ( TakeProfitPips<StopLevelPriceDistance * 2.0 / PipSize )
 {
   TakeProfitPips = StopLevelPriceDistance * 2.0 / PipSize ;
 }
 if ( MinEntryDistancePips<StopLevelPriceDistance * 2.0 / PipSize )
 {
   MinEntryDistancePips = StopLevelPriceDistance * 2.0 / PipSize ;
 }
 if ( SwingLeftBars <  1 )
 {
   SwingLeftBars = 1 ;
 }
 if ( SwingRightBars <  1 )
 {
   SwingRightBars = 1 ;
 }
 if ( MinEntryDistancePips<0.1 )
 {
   MinEntryDistancePips = 0.1 ;
 }
 PendingExpirationSeconds=PendingExpirationHours * 60 * 60;
 if ( PendingExpirationHours >  0 )
 {
   PendingOrderExpirationTime=TimeCurrent() + PendingExpirationSeconds;
 }
 else
 {
   PendingOrderExpirationTime = 0 ;
 }
 if ( Virtual_expiration )
 {
   PendingOrderExpirationTime = 0 ;
 }
 NfpTradingSuspended = false ;
 LegacyWriteOnlyInitializationSecond = CurrentSecond() ;
 LastVirtualStopSyncTime = TimeCurrent() ;
 BuyZoneStateInitialized = false ;
 SellZoneStateInitialized = false ;
 LegacyWriteOnlyInitializationMonth = CurrentMonth() ;
 LegacyWriteOnlyPreviousWeeklyBarTime = iTime(CurrentSymbol,NormalizeTimeframe(PERIOD_W1),1) ;
 LegacyWriteOnlyPreviousMonthlyBarTimePrimary = iTime(CurrentSymbol,NormalizeTimeframe(PERIOD_M1),1) ;
 LegacyWriteOnlyPreviousMonthlyBarTimeSecondary = iTime(CurrentSymbol,NormalizeTimeframe(PERIOD_M1),1) ;
 if ( MaxSpreadPips>MaxSpread )
 {
   MaxSpreadPips = MaxSpread ;
 }
 LegacyWriteOnlyInitializationFlag = false ;
 CalculateBuyEntryPrice(SignalTimeframeMinutes); 
 CalculateSellEntryPrice(SignalTimeframeMinutes); 
 CachedBuySignalPrice = NormalizeDouble(CurrentBuyEntryPrice,SymbolDigits) ;
 CachedSellSignalPrice = NormalizeDouble(CurrentSellEntryPrice,SymbolDigits) ;
 MagicTrailTickCounter = 0 ;
 MarketPauseMessageLogged = false ;
 TimeRecoveryDelaySeconds = (int)(TimeRecoveryAfterMinutes * 60.0) ;
 DynamicLotSizingEnabled = false ;
 TradingHoursState = true ;
 FreezeLevelPriceDistance = ((double)SymbolInfoInteger(CurrentSymbol,SYMBOL_TRADE_FREEZE_LEVEL)) * SymbolPoint ;
 if ( !(TradingHoursEnabled) )
 {
   TradingHoursState = false ;
 }
 ActiveVirtualStopPrice = 0.0 ;
 LegacyWriteOnlyTradeStateValuePrimary = 0.0 ;
 LegacyWriteOnlyTradeStateValueSecondary = 0.0 ;
 LegacyWriteOnlyTradeStateFlag = false ;
 SymbolSuffix = StringSubstr(CurrentSymbol,6,0) ;
 if ( Risk >  0 )
 {
   DynamicLotSizingEnabled = true ;
 }
 if ( StartLots_rw<0.0 )
 {
   StartLots_rw = 0.01 ;
 }
 if ( MaxCalculatedLotSize>SymbolInfoDouble(CurrentSymbol,SYMBOL_VOLUME_MAX) )
 {
   MaxCalculatedLotSize = SymbolInfoDouble(CurrentSymbol,SYMBOL_VOLUME_MAX) ;
 }
 for (RiskBufferRowIndex = 0 ; RiskBufferRowIndex < SmallBufferCapacity ; RiskBufferRowIndex ++)
 {
   for (VirtualStopFieldIndex = 0 ; VirtualStopFieldIndex < 2 ; VirtualStopFieldIndex ++)
   {
     VirtualStopByTicket[RiskBufferRowIndex][VirtualStopFieldIndex] = 0.0;
   }
 }
 for (StoredOrderRowIndex = 0 ; StoredOrderRowIndex < OrderBufferCapacity ; StoredOrderRowIndex ++)
 {
   for (StoredOrderFieldIndex = 0 ; StoredOrderFieldIndex < 3 ; StoredOrderFieldIndex ++)
   {
     StoredPendingOrders[StoredOrderRowIndex][StoredOrderFieldIndex] = 0.0;
   }
 }
 for (StoredOrderResetIndex = 0 ; StoredOrderResetIndex < 100 ; StoredOrderResetIndex ++)
 {
   StoredPendingOrders[StoredOrderResetIndex][0] = 0.0;
   StoredPendingOrders[StoredOrderResetIndex][1] = 0.0;
 }
 FridayTradingSuspended = false ;
 CurrentUpperFractal = GetFractalValue(CurrentSymbol,0,1,1) ;
 CurrentLowerFractal = GetFractalValue(CurrentSymbol,0,2,1) ;
 PreviousUpperFractal = CurrentUpperFractal ;
 PreviousLowerFractal = CurrentLowerFractal ;
 LegacyWriteOnlyFractalStateValue = 0.0 ;
 LegacyWriteOnlyFractalStateFlag = false ;
 LegacyWriteOnlyInitializationHour = CurrentHour() ;
 LegacyWriteOnlyInitializationCounter = 0 ;
 BuyComment1=ST1_Comment + "B1";
 BuyComment2=ST1_Comment + "B2";
 SellComment1=ST1_Comment + "S1";
 SellComment2=ST1_Comment + "S2";
 LegacyWriteOnlyCommentStateCounterPrimary = 0 ;
 LegacyWriteOnlyCommentStateCounterSecondary = 0 ;
 LastEntryHour = CurrentHour() ;
 if ( VirtualPendingOrdersEnabled )
 {
   MaxPendingOrders = 1 ;
   LegacyWriteOnlyVirtualBuyPendingFlag = true ;
   LegacyWriteOnlyVirtualSellPendingFlag = true ;
 }
 LegacyWriteOnlyUpperPriceSentinel = 999.0 ;
 LegacyWriteOnlyLowerPriceSentinel = 0.0 ;
 LegacyWriteOnlyEntryStateValuePrimary = 0.0 ;
 LegacyWriteOnlyEntryStateValueSecondary = 0.0 ;
 for (StrategyInitializationIndex = 0 ; StrategyInitializationIndex < 99 ; StrategyInitializationIndex ++)
 {
   LastEntryBarCountByStrategy[StrategyInitializationIndex] = 0;
   LastExitBarCountByStrategy[StrategyInitializationIndex] = 0;
   LastSignalBarTimeByStrategy[StrategyInitializationIndex] = iTime(CurrentSymbol,NormalizeTimeframe(SignalTimeframeMinutes),1);
   if ( !(LotSizeByStrategy[StrategyInitializationIndex]<StartLots_rw) )   continue;
   LotSizeByStrategy[StrategyInitializationIndex] = StartLots_rw;
   
 }
 LegacyWriteOnlyOrderTicket = 0 ;
 LegacyWriteOnlyOrderStateFlagPrimary = false ;
 LegacyWriteOnlyOrderStateFlagSecondary = false ;
 if ( TradeMonitorFilterMode == 1 )
 {
   ExtraStopLossPips = 0.0 ;
 }
 SymbolDigits = (int)((double)SymbolInfoInteger(CurrentSymbol,SYMBOL_DIGITS)) ;
 DemoAccountDetectedFlag = false ;
 IsDemoAccount(); 

 if ( IgnoredDemoDetectionResult == true )
 {
   DemoAccountDetectedFlag = true ;
 }
 if ( ShowInfoPanel )
 {
   if ( StrategyRankingMode == 1 )
   {
     RankStrategiesByTotalProfit(); 
   }
   else
   {
     if ( StrategyRankingMode == 2 )
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
  bool      GmtRefreshPerformed;
  double    AccountBalanceUsd;
  double    AllowedDrawdownUsd;
  bool      RefreshPerformanceThisHour;
  MqlDateTime MarchDstBoundaryParts;
  MqlDateTime OctoberDstBoundaryParts;
//----------------------------------------------------------------------
 bool       IsEuropeanDaylightSavingTime;
 double     Strategy1DisplayedProfit;
 double     Strategy1ProfitAccumulator;
 int        Strategy1HistoryIndex;
 double     Strategy4DisplayedProfit;
 double     Strategy4ProfitAccumulator;
 int        Strategy4HistoryIndex;
 double     Strategy2DisplayedProfit;
 double     Strategy2ProfitAccumulator;
 int        Strategy2HistoryIndex;
 double     Strategy3DisplayedProfit;
 double     Strategy3ProfitAccumulator;
 int        Strategy3HistoryIndex;
 double     Strategy6DisplayedProfit;
 double     Strategy6ProfitAccumulator;
 int        Strategy6HistoryIndex;
 double     Strategy5DisplayedProfit;
 double     Strategy5ProfitAccumulator;
 int        Strategy5HistoryIndex;
 double     Strategy9DisplayedProfit;
 double     Strategy9ProfitAccumulator;
 int        Strategy9HistoryIndex;
 double     Strategy7DisplayedProfit;
 double     Strategy7ProfitAccumulator;
 int        Strategy7HistoryIndex;
 double     Strategy8DisplayedProfit;
 double     Strategy8ProfitAccumulator;
 int        Strategy8HistoryIndex;

 CurrentBalanceBasis = AccountInfoDouble(ACCOUNT_BALANCE) ;
 if ( UseEquity )
 {
   CurrentBalanceBasis = AccountInfoDouble(ACCOUNT_EQUITY) ;
 }
 if ( ManualBalance>0.0 )
 {
   CurrentBalanceBasis = ManualBalance ;
 }
 if ( OnlyUp && HighestBalanceBasis>CurrentBalanceBasis )
 {
   CurrentBalanceBasis = HighestBalanceBasis ;
 }
 if ( CurrentBalanceBasis>HighestBalanceBasis )
 {
   HighestBalanceBasis = CurrentBalanceBasis ;
   if ( OnlyUp )   GlobalVariableSet(OnlyUpPeakGVName(),HighestBalanceBasis) ;
 }
 if ( FakeOutFilter == 0 )
 {
   CandleExitM1Enabled = false ;
   CandleExitM15Enabled = false ;
   CandleExitH1Enabled = false ;
 }
 else
 {
   if ( FakeOutFilter == 1 )
   {
     CandleExitM1Enabled = true ;
     CandleExitM15Enabled = false ;
     CandleExitH1Enabled = false ;
   }
   else
   {
     if ( FakeOutFilter == 2 )
     {
       CandleExitM1Enabled = true ;
       CandleExitM15Enabled = true ;
       CandleExitH1Enabled = false ;
     }
     else
     {
       if ( FakeOutFilter == 3 )
       {
         CandleExitM1Enabled = true ;
         CandleExitM15Enabled = true ;
         CandleExitH1Enabled = true ;
       }
     }
   }
 }
 GmtRefreshPerformed = false ;
 if ( IsAmericanDaylightSavingTime() )
 {
   BrokerGmtOffsetHours = Broker_GMT_OFFSET_Summer ;
   if ( ( !(UsDaylightSavingState) || !(GmtDetectionInitialized) ) && AutoGMT && !(GmtRefreshPerformed) )
   {
     UsDaylightSavingState = true ;
     EuropeDaylightSavingState = true ;
     DetectedUtcOffsetHours = FetchUtcOffsetHours() ;
     if ( DetectedUtcOffsetHours == 999 )
     {
       Print("GMT_Offset wrongly detected.  Trying againg!"); 
       Sleep(2000); 
       DetectedUtcOffsetHours = FetchUtcOffsetHours() ;
     }
     if ( DetectedUtcOffsetHours == 999 )
     {
       Print("GMT_Offset still wrong.  Using VPS time for GMT detection!"); 
     }
     GmtDetectionInitialized = true ;
     GmtRefreshPerformed = true ;
     Print("DST_US on"); 
   }
 }
 else
 {
   BrokerGmtOffsetHours = Broker_GMT_OFFSET_Winter ;
   if ( ( UsDaylightSavingState || !(GmtDetectionInitialized) ) && AutoGMT && !(GmtRefreshPerformed) )
   {
     UsDaylightSavingState = false ;
     EuropeDaylightSavingState = false ;
     DetectedUtcOffsetHours = FetchUtcOffsetHours() ;
     if ( DetectedUtcOffsetHours == 999 )
     {
       Print("GMT_Offset wrongly detected.  Trying againg!"); 
       Sleep(2000); 
       DetectedUtcOffsetHours = FetchUtcOffsetHours() ;
     }
     if ( DetectedUtcOffsetHours == 999 )
     {
       Print("GMT_Offset still wrong.  Using VPS time for GMT detection!"); 
     }
     GmtDetectionInitialized = true ;
     GmtRefreshPerformed = true ;
     Print("DST_US off"); 
   }
 }
 TimeToStruct(StringToTime(string(DateTimeYear(TimeCurrent())) + ".03.31 01:00"),MarchDstBoundaryParts); 
 TimeToStruct(StringToTime(string(DateTimeYear(TimeCurrent())) + ".10.31 02:00"),OctoberDstBoundaryParts); 
 if ( DateTimeDayOfYear(TimeCurrent()) >  DateTimeDayOfYear(StringToTime(string(DateTimeYear(TimeCurrent())) + ".03.31 01:00") - MarchDstBoundaryParts.day_of_week * SECONDS_PER_DAY) && DateTimeDayOfYear(TimeCurrent()) <  DateTimeDayOfYear(StringToTime(string(DateTimeYear(TimeCurrent())) + ".10.31 02:00") - OctoberDstBoundaryParts.day_of_week * SECONDS_PER_DAY) )
 {
   IsEuropeanDaylightSavingTime = true;
 }
 else
 {
   IsEuropeanDaylightSavingTime = false;
 }
 if ( IsEuropeanDaylightSavingTime )
 {
   if ( ( !(EuropeDaylightSavingState) || !(GmtDetectionInitialized) ) && AutoGMT && !(GmtRefreshPerformed) )
   {
     EuropeDaylightSavingState = true ;
     DetectedUtcOffsetHours = FetchUtcOffsetHours() ;
     if ( DetectedUtcOffsetHours == 999 )
     {
       Print("GMT_Offset wrongly detected.  Trying againg!"); 
       Sleep(2000); 
       DetectedUtcOffsetHours = FetchUtcOffsetHours() ;
     }
     if ( DetectedUtcOffsetHours == 999 )
     {
       Print("GMT_Offset still wrong.  Using VPS time for GMT detection!"); 
     }
     GmtDetectionInitialized = true ;
     GmtRefreshPerformed = true ;
     Print("DST_EU on"); 
   }
 }
 else
 {
   if ( ( EuropeDaylightSavingState || !(GmtDetectionInitialized) ) && AutoGMT && !(GmtRefreshPerformed) )
   {
     EuropeDaylightSavingState = false ;
     DetectedUtcOffsetHours = FetchUtcOffsetHours() ;
     if ( DetectedUtcOffsetHours == 999 )
     {
       Print("GMT_Offset wrongly detected.  Trying againg!"); 
       Sleep(2000); 
       DetectedUtcOffsetHours = FetchUtcOffsetHours() ;
     }
     if ( DetectedUtcOffsetHours == 999 )
     {
       Print("GMT_Offset still wrong.  Using VPS time for GMT detection!"); 
     }
     GmtDetectionInitialized = true ;
     GmtRefreshPerformed = true ;
     Print("DST_EU off"); 
   }
 }
 if ( AutoGMT && MQLInfoInteger(MQL_TESTER) != 1 )
 {
   if ( DetectedUtcOffsetHours != 999 )
   {
     CurrentGmtTime=TimeCurrent() - DetectedUtcOffsetHours * 3600;
   }
   else
   {
     CurrentGmtTime = TimeGMT() ;
   }
 }
 else
 {
   CurrentGmtTime=TimeCurrent() - BrokerGmtOffsetHours * 3600;
 }
 // Lich MQL5 khong kha dung/dang tin cay trong Strategy Tester (backtest) nen chi
 // lam moi tu Lich MQL5 khi dang chay live/demo that; kiem thu nguoc luon dung mang
 // nfpDatesGmt[] ma hoa cung ben tren (da cap nhat toi het nam 2026) de dam
 // bao ket qua backtest 100% xac dinh, lap lai duoc.
 if ( EnableNFP_Filter && UseMQL5Calendar && MQLInfoInteger(MQL_TESTER) != 1 && TimeCurrent() - TimeCurrent() % SECONDS_PER_DAY > NfpCalendarBuiltDay )
 {
   BuildNFPDatesFromCalendar();
 }
 if ( TradeFrequency == 5 && Risk == 1234 )
 {
   AccountBalanceUsd = ConvertAccountCurrencyToUsdRounded(AccountInfoDouble(ACCOUNT_BALANCE)) ;
   AllowedDrawdownUsd = MaxAllowedDD / 100.0 * AccountBalanceUsd ;
   if ( AllowedDrawdownUsd>AutoFrequencyThreshold4 )
   {
     ActiveTradeFrequency = 3 ;
   }
   else
   {
     if ( AllowedDrawdownUsd>AutoFrequencyThreshold3 )
     {
       ActiveTradeFrequency = 2 ;
     }
     else
     {
       if ( AllowedDrawdownUsd>AutoFrequencyThreshold2 )
       {
         ActiveTradeFrequency = 1 ;
       }
       else
       {
         ActiveTradeFrequency = 0 ;
       }
     }
   }
 }
 else
 {
   ActiveTradeFrequency = TradeFrequency ;
 }
 if ( ActiveTradeFrequency == 0 )
 {
   EnableStrategy4 = false ;
   EnableStrategy5 = false ;
   EnableStrategy6 = false ;
   EnableStrategy7 = false ;
   EnableStrategy8 = false ;
   EnableStrategy9 = false ;
   EnabledStrategyRiskWeight = 2.4 ;
   if ( UseVariableValues )
   {
     EnabledStrategyRiskWeight = 3.0 ;
   }
 }
 else
 {
   if ( ActiveTradeFrequency == 1 )
   {
     EnableStrategy4 = true ;
     EnableStrategy5 = true ;
     EnableStrategy6 = false ;
     EnableStrategy7 = false ;
     EnableStrategy8 = false ;
     EnableStrategy9 = false ;
     EnabledStrategyRiskWeight = 3.4 ;
     if ( UseVariableValues )
     {
       EnabledStrategyRiskWeight = 4.0 ;
     }
   }
   else
   {
     if ( ActiveTradeFrequency == 2 )
     {
       EnableStrategy4 = true ;
       EnableStrategy5 = true ;
       EnableStrategy6 = true ;
       EnableStrategy7 = true ;
       EnableStrategy8 = false ;
       EnableStrategy9 = false ;
       EnabledStrategyRiskWeight = 4.1 ;
       if ( UseVariableValues )
       {
         EnabledStrategyRiskWeight = 5.0 ;
       }
     }
     else
     {
       if ( ActiveTradeFrequency == 3 )
       {
         EnableStrategy4 = true ;
         EnableStrategy5 = true ;
         EnableStrategy6 = true ;
         EnableStrategy7 = true ;
         EnableStrategy8 = true ;
         EnableStrategy9 = false ;
         EnabledStrategyRiskWeight = 4.8 ;
         if ( UseVariableValues )
         {
           EnabledStrategyRiskWeight = 5.6 ;
         }
       }
       else
       {
         if ( ActiveTradeFrequency == 4 )
         {
           EnableStrategy4 = true ;
           EnableStrategy5 = true ;
           EnableStrategy6 = true ;
           EnableStrategy7 = true ;
           EnableStrategy8 = true ;
           EnableStrategy9 = true ;
           EnabledStrategyRiskWeight = 5.1 ;
           if ( UseVariableValues )
           {
             EnabledStrategyRiskWeight = 6.0 ;
           }
         }
         else
         {
           if ( ActiveTradeFrequency == 6 )
           {
             EnableStrategy1 = RunStrat1 ;
             EnableStrategy2 = RunStrat2 ;
             EnableStrategy3 = RunStrat3 ;
             EnableStrategy4 = RunStrat4 ;
             EnableStrategy5 = RunStrat5 ;
             EnableStrategy6 = RunStrat6 ;
             EnableStrategy7 = RunStrat7 ;
             EnableStrategy8 = RunStrat8 ;
             EnableStrategy9 = RunStrat9 ;
           }
         }
       }
     }
   }
 }
 if ( iBars(CurrentSymbol,NormalizeTimeframe(PERIOD_D1)) != LastDailyBarCount )
 {
   LastDailyBarCount = iBars(CurrentSymbol,NormalizeTimeframe(PERIOD_D1)) ;
   DailyDrawdownLockActive = false ;
   DailyDrawdownReference = 0.0 ;
 }
 if ( PropFirmMaxDailyDD>0.0 )
 {
   EnforcePropFirmDailyDrawdown(); 
 }
 if ( DailyDrawdownLockActive || !(PairInitializationSucceeded) )   return;
 RefreshPerformanceThisHour = false ;
 if ( LastPerformanceRefreshH1BarTime != iTime(CurrentSymbol,NormalizeTimeframe(PERIOD_H1),1) )
 {
   RefreshPerformanceThisHour = true ;
   LastPerformanceRefreshH1BarTime = iTime(CurrentSymbol,NormalizeTimeframe(PERIOD_H1),1) ;
 }
 if ( ( StringFind(Symbol(),"XAUUSD",0) >= 0 || StringFind(Symbol(),"xauusd",0) >= 0 || StringFind(Symbol(),"GOLD",0) >= 0 || StringFind(Symbol(),"GLD",0) >= 0 || StringFind(Symbol(),"gold",0) >= 0 || StringFind(Symbol(),"Gold",0) >= 0 ) )
 {
   CurrentSymbol = Symbol() ;
   if ( EnableStrategy1 )
   {
     LoadStrategy1Profile(); 
     LoadStrategyRuntimeContext(0); 
     RunStrategyCycle(0); 
     if ( RefreshPerformanceThisHour )
     {
       if ( MQLInfoInteger(MQL_TESTER) == 1 && !(UpdateInfoTesting) )
       {
         Strategy1DisplayedProfit = 0.0;
       }
       else
       {
         Strategy1ProfitAccumulator = 0.0;
         TotalTradeCountByStrategy[CurrentStrategyIndex] = 0;
         for (Strategy1HistoryIndex = ClosedTradeCount() ; Strategy1HistoryIndex >= 0 ; Strategy1HistoryIndex=Strategy1HistoryIndex - 1)
         {
           if ( SelectTradeRecord(Strategy1HistoryIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_HISTORY) != true || SelectedTradeSymbol() != CurrentSymbol || SelectedTradeMagic() != StrategyMagicNumber )   continue;
           
           if ( ( SelectedTradeType() != ORDER_TYPE_BUY && SelectedTradeType() != ORDER_TYPE_SELL ) )   continue;
           TotalTradeCountByStrategy[CurrentStrategyIndex] ++;
           Strategy1ProfitAccumulator = Strategy1ProfitAccumulator + SelectedTradeProfit() + SelectedTradeSwap() + SelectedTradeCommission();
           
         }
         Strategy1DisplayedProfit = Strategy1ProfitAccumulator;
       }
       StrategyDisplayProfit[0] = Strategy1DisplayedProfit;
       if ( StrategyDisplayProfit[0]!=0.0 && TotalTradeCountByStrategy[0] >  0 )
       {
         AverageProfitByStrategy[0] = StrategyDisplayProfit[0] / TotalTradeCountByStrategy[0];
       }
     }
   }
   if ( EnableStrategy4 )
   {
     LoadStrategy2Profile(); 
     LoadStrategyRuntimeContext(3); 
     RunStrategyCycle(3); 
     if ( RefreshPerformanceThisHour )
     {
       if ( MQLInfoInteger(MQL_TESTER) == 1 && !(UpdateInfoTesting) )
       {
         Strategy4DisplayedProfit = 0.0;
       }
       else
       {
         Strategy4ProfitAccumulator = 0.0;
         TotalTradeCountByStrategy[CurrentStrategyIndex] = 0;
         for (Strategy4HistoryIndex = ClosedTradeCount() ; Strategy4HistoryIndex >= 0 ; Strategy4HistoryIndex=Strategy4HistoryIndex - 1)
         {
           if ( SelectTradeRecord(Strategy4HistoryIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_HISTORY) != true || SelectedTradeSymbol() != CurrentSymbol || SelectedTradeMagic() != StrategyMagicNumber )   continue;
           
           if ( ( SelectedTradeType() != ORDER_TYPE_BUY && SelectedTradeType() != ORDER_TYPE_SELL ) )   continue;
           TotalTradeCountByStrategy[CurrentStrategyIndex] ++;
           Strategy4ProfitAccumulator = Strategy4ProfitAccumulator + SelectedTradeProfit() + SelectedTradeSwap() + SelectedTradeCommission();
           
         }
         Strategy4DisplayedProfit = Strategy4ProfitAccumulator;
       }
       StrategyDisplayProfit[3] = Strategy4DisplayedProfit;
       if ( StrategyDisplayProfit[3]!=0.0 && TotalTradeCountByStrategy[3] >  0 )
       {
         AverageProfitByStrategy[3] = StrategyDisplayProfit[3] / TotalTradeCountByStrategy[3];
       }
     }
   }
   if ( EnableStrategy2 )
   {
     LoadStrategy3Profile(); 
     LoadStrategyRuntimeContext(1); 
     RunStrategyCycle(1); 
     if ( RefreshPerformanceThisHour )
     {
       if ( MQLInfoInteger(MQL_TESTER) == 1 && !(UpdateInfoTesting) )
       {
         Strategy2DisplayedProfit = 0.0;
       }
       else
       {
         Strategy2ProfitAccumulator = 0.0;
         TotalTradeCountByStrategy[CurrentStrategyIndex] = 0;
         for (Strategy2HistoryIndex = ClosedTradeCount() ; Strategy2HistoryIndex >= 0 ; Strategy2HistoryIndex=Strategy2HistoryIndex - 1)
         {
           if ( SelectTradeRecord(Strategy2HistoryIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_HISTORY) != true || SelectedTradeSymbol() != CurrentSymbol || SelectedTradeMagic() != StrategyMagicNumber )   continue;
           
           if ( ( SelectedTradeType() != ORDER_TYPE_BUY && SelectedTradeType() != ORDER_TYPE_SELL ) )   continue;
           TotalTradeCountByStrategy[CurrentStrategyIndex] ++;
           Strategy2ProfitAccumulator = Strategy2ProfitAccumulator + SelectedTradeProfit() + SelectedTradeSwap() + SelectedTradeCommission();
           
         }
         Strategy2DisplayedProfit = Strategy2ProfitAccumulator;
       }
       StrategyDisplayProfit[1] = Strategy2DisplayedProfit;
       if ( StrategyDisplayProfit[1]!=0.0 && TotalTradeCountByStrategy[1] >  0 )
       {
         AverageProfitByStrategy[1] = StrategyDisplayProfit[1] / TotalTradeCountByStrategy[1];
       }
     }
   }
   if ( EnableStrategy3 )
   {
     LoadStrategy4Profile(); 
     LoadStrategyRuntimeContext(2); 
     RunStrategyCycle(2); 
     if ( RefreshPerformanceThisHour )
     {
       if ( MQLInfoInteger(MQL_TESTER) == 1 && !(UpdateInfoTesting) )
       {
         Strategy3DisplayedProfit = 0.0;
       }
       else
       {
         Strategy3ProfitAccumulator = 0.0;
         TotalTradeCountByStrategy[CurrentStrategyIndex] = 0;
         for (Strategy3HistoryIndex = ClosedTradeCount() ; Strategy3HistoryIndex >= 0 ; Strategy3HistoryIndex=Strategy3HistoryIndex - 1)
         {
           if ( SelectTradeRecord(Strategy3HistoryIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_HISTORY) != true || SelectedTradeSymbol() != CurrentSymbol || SelectedTradeMagic() != StrategyMagicNumber )   continue;
           
           if ( ( SelectedTradeType() != ORDER_TYPE_BUY && SelectedTradeType() != ORDER_TYPE_SELL ) )   continue;
           TotalTradeCountByStrategy[CurrentStrategyIndex] ++;
           Strategy3ProfitAccumulator = Strategy3ProfitAccumulator + SelectedTradeProfit() + SelectedTradeSwap() + SelectedTradeCommission();
           
         }
         Strategy3DisplayedProfit = Strategy3ProfitAccumulator;
       }
       StrategyDisplayProfit[2] = Strategy3DisplayedProfit;
       if ( StrategyDisplayProfit[2]!=0.0 && TotalTradeCountByStrategy[2] >  0 )
       {
         AverageProfitByStrategy[2] = StrategyDisplayProfit[2] / TotalTradeCountByStrategy[2];
       }
     }
   }
   if ( EnableStrategy6 )
   {
     LoadStrategy5Profile(); 
     LoadStrategyRuntimeContext(5); 
     RunStrategyCycle(5); 
     if ( RefreshPerformanceThisHour )
     {
       if ( MQLInfoInteger(MQL_TESTER) == 1 && !(UpdateInfoTesting) )
       {
         Strategy6DisplayedProfit = 0.0;
       }
       else
       {
         Strategy6ProfitAccumulator = 0.0;
         TotalTradeCountByStrategy[CurrentStrategyIndex] = 0;
         for (Strategy6HistoryIndex = ClosedTradeCount() ; Strategy6HistoryIndex >= 0 ; Strategy6HistoryIndex=Strategy6HistoryIndex - 1)
         {
           if ( SelectTradeRecord(Strategy6HistoryIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_HISTORY) != true || SelectedTradeSymbol() != CurrentSymbol || SelectedTradeMagic() != StrategyMagicNumber )   continue;
           
           if ( ( SelectedTradeType() != ORDER_TYPE_BUY && SelectedTradeType() != ORDER_TYPE_SELL ) )   continue;
           TotalTradeCountByStrategy[CurrentStrategyIndex] ++;
           Strategy6ProfitAccumulator = Strategy6ProfitAccumulator + SelectedTradeProfit() + SelectedTradeSwap() + SelectedTradeCommission();
           
         }
         Strategy6DisplayedProfit = Strategy6ProfitAccumulator;
       }
       StrategyDisplayProfit[5] = Strategy6DisplayedProfit;
       if ( StrategyDisplayProfit[5]!=0.0 && TotalTradeCountByStrategy[5] >  0 )
       {
         AverageProfitByStrategy[5] = StrategyDisplayProfit[5] / TotalTradeCountByStrategy[5];
       }
     }
   }
   if ( EnableStrategy5 )
   {
     LoadStrategy6Profile(); 
     LoadStrategyRuntimeContext(4); 
     RunStrategyCycle(4); 
     if ( RefreshPerformanceThisHour )
     {
       if ( MQLInfoInteger(MQL_TESTER) == 1 && !(UpdateInfoTesting) )
       {
         Strategy5DisplayedProfit = 0.0;
       }
       else
       {
         Strategy5ProfitAccumulator = 0.0;
         TotalTradeCountByStrategy[CurrentStrategyIndex] = 0;
         for (Strategy5HistoryIndex = ClosedTradeCount() ; Strategy5HistoryIndex >= 0 ; Strategy5HistoryIndex=Strategy5HistoryIndex - 1)
         {
           if ( SelectTradeRecord(Strategy5HistoryIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_HISTORY) != true || SelectedTradeSymbol() != CurrentSymbol || SelectedTradeMagic() != StrategyMagicNumber )   continue;
           
           if ( ( SelectedTradeType() != ORDER_TYPE_BUY && SelectedTradeType() != ORDER_TYPE_SELL ) )   continue;
           TotalTradeCountByStrategy[CurrentStrategyIndex] ++;
           Strategy5ProfitAccumulator = Strategy5ProfitAccumulator + SelectedTradeProfit() + SelectedTradeSwap() + SelectedTradeCommission();
           
         }
         Strategy5DisplayedProfit = Strategy5ProfitAccumulator;
       }
       StrategyDisplayProfit[4] = Strategy5DisplayedProfit;
       if ( StrategyDisplayProfit[4]!=0.0 && TotalTradeCountByStrategy[4] >  0 )
       {
         AverageProfitByStrategy[4] = StrategyDisplayProfit[4] / TotalTradeCountByStrategy[4];
       }
     }
   }
   if ( EnableStrategy9 )
   {
     LoadStrategy7Profile(); 
     LoadStrategyRuntimeContext(8); 
     RunStrategyCycle(8); 
     if ( RefreshPerformanceThisHour )
     {
       if ( MQLInfoInteger(MQL_TESTER) == 1 && !(UpdateInfoTesting) )
       {
         Strategy9DisplayedProfit = 0.0;
       }
       else
       {
         Strategy9ProfitAccumulator = 0.0;
         TotalTradeCountByStrategy[CurrentStrategyIndex] = 0;
         for (Strategy9HistoryIndex = ClosedTradeCount() ; Strategy9HistoryIndex >= 0 ; Strategy9HistoryIndex=Strategy9HistoryIndex - 1)
         {
           if ( SelectTradeRecord(Strategy9HistoryIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_HISTORY) != true || SelectedTradeSymbol() != CurrentSymbol || SelectedTradeMagic() != StrategyMagicNumber )   continue;
           
           if ( ( SelectedTradeType() != ORDER_TYPE_BUY && SelectedTradeType() != ORDER_TYPE_SELL ) )   continue;
           TotalTradeCountByStrategy[CurrentStrategyIndex] ++;
           Strategy9ProfitAccumulator = Strategy9ProfitAccumulator + SelectedTradeProfit() + SelectedTradeSwap() + SelectedTradeCommission();
           
         }
         Strategy9DisplayedProfit = Strategy9ProfitAccumulator;
       }
       StrategyDisplayProfit[8] = Strategy9DisplayedProfit;
       if ( StrategyDisplayProfit[8]!=0.0 && TotalTradeCountByStrategy[8] >  0 )
       {
         AverageProfitByStrategy[8] = StrategyDisplayProfit[8] / TotalTradeCountByStrategy[8];
       }
     }
   }
   if ( EnableStrategy7 )
   {
     LoadStrategy8Profile(); 
     LoadStrategyRuntimeContext(6); 
     RunStrategyCycle(6); 
     if ( RefreshPerformanceThisHour )
     {
       if ( MQLInfoInteger(MQL_TESTER) == 1 && !(UpdateInfoTesting) )
       {
         Strategy7DisplayedProfit = 0.0;
       }
       else
       {
         Strategy7ProfitAccumulator = 0.0;
         TotalTradeCountByStrategy[CurrentStrategyIndex] = 0;
         for (Strategy7HistoryIndex = ClosedTradeCount() ; Strategy7HistoryIndex >= 0 ; Strategy7HistoryIndex=Strategy7HistoryIndex - 1)
         {
           if ( SelectTradeRecord(Strategy7HistoryIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_HISTORY) != true || SelectedTradeSymbol() != CurrentSymbol || SelectedTradeMagic() != StrategyMagicNumber )   continue;
           
           if ( ( SelectedTradeType() != ORDER_TYPE_BUY && SelectedTradeType() != ORDER_TYPE_SELL ) )   continue;
           TotalTradeCountByStrategy[CurrentStrategyIndex] ++;
           Strategy7ProfitAccumulator = Strategy7ProfitAccumulator + SelectedTradeProfit() + SelectedTradeSwap() + SelectedTradeCommission();
           
         }
         Strategy7DisplayedProfit = Strategy7ProfitAccumulator;
       }
       StrategyDisplayProfit[6] = Strategy7DisplayedProfit;
       if ( StrategyDisplayProfit[6]!=0.0 && TotalTradeCountByStrategy[6] >  0 )
       {
         AverageProfitByStrategy[6] = StrategyDisplayProfit[6] / TotalTradeCountByStrategy[6];
       }
     }
   }
   if ( EnableStrategy8 )
   {
     LoadStrategy9Profile(); 
     LoadStrategyRuntimeContext(7); 
     RunStrategyCycle(7); 
     if ( RefreshPerformanceThisHour )
     {
       if ( MQLInfoInteger(MQL_TESTER) == 1 && !(UpdateInfoTesting) )
       {
         Strategy8DisplayedProfit = 0.0;
       }
       else
       {
         Strategy8ProfitAccumulator = 0.0;
         TotalTradeCountByStrategy[CurrentStrategyIndex] = 0;
         for (Strategy8HistoryIndex = ClosedTradeCount() ; Strategy8HistoryIndex >= 0 ; Strategy8HistoryIndex=Strategy8HistoryIndex - 1)
         {
           if ( SelectTradeRecord(Strategy8HistoryIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_HISTORY) != true || SelectedTradeSymbol() != CurrentSymbol || SelectedTradeMagic() != StrategyMagicNumber )   continue;
           
           if ( ( SelectedTradeType() != ORDER_TYPE_BUY && SelectedTradeType() != ORDER_TYPE_SELL ) )   continue;
           TotalTradeCountByStrategy[CurrentStrategyIndex] ++;
           Strategy8ProfitAccumulator = Strategy8ProfitAccumulator + SelectedTradeProfit() + SelectedTradeSwap() + SelectedTradeCommission();
           
         }
         Strategy8DisplayedProfit = Strategy8ProfitAccumulator;
       }
       StrategyDisplayProfit[7] = Strategy8DisplayedProfit;
       if ( StrategyDisplayProfit[7]!=0.0 && TotalTradeCountByStrategy[7] >  0 )
       {
         AverageProfitByStrategy[7] = StrategyDisplayProfit[7] / TotalTradeCountByStrategy[7];
       }
     }
   }
 }
 else
 {
   CurrentSymbol = Symbol() ;
   RunStrategyCycle(0); 
 }
 UpdateInfoPanelSummary(); 
 if ( iTime(Symbol(),PERIOD_M5,1) != LastPanelRefreshM5BarTime )
 {
   LastPanelRefreshM5BarTime = iTime(Symbol(),PERIOD_M5,1) ;
   UpdateInfoPanelStrategyRows(); 
   UpdateInfoPanelTotals(); 
 }
 PanelRefreshTickCounter ++;
 if ( PanelRefreshTickCounter < 2 )   return;
 LastLotResizeBalance = AccountInfoDouble(ACCOUNT_BALANCE) ;
 PanelRefreshTickCounter = 0 ;
 }
//OnTick <<==--------   --------
 void OnDeinit(const int Reason)
 {
 DeleteInfoPanel(); 
 }
//deinit <<==--------   --------

//+------------------------------------------------------------------+
//| Xu ly ngay giao dich nap/rut tien khi EA dang chay.               |
//+------------------------------------------------------------------+
 void OnTradeTransaction(const MqlTradeTransaction &Trans,
                         const MqlTradeRequest &Request,
                         const MqlTradeResult &Result)
 {
  if ( !(OnlyUp) || ManualBalance>0.0 )   return;
  if ( Trans.type!=TRADE_TRANSACTION_DEAL_ADD || Trans.deal==0 )   return;
  if ( !(HistoryDealSelect(Trans.deal)) )   return;
  ENUM_DEAL_TYPE TransactionDealType = (ENUM_DEAL_TYPE)HistoryDealGetInteger(Trans.deal,DEAL_TYPE) ;
  if ( TransactionDealType!=DEAL_TYPE_BALANCE )   return;
  long TransactionDealTimeMsc = (long)HistoryDealGetInteger(Trans.deal,DEAL_TIME_MSC) ;
  // Giao dich da duoc ReconcileOnlyUpWithdrawals() xu ly luc khoi dong.
  if ( TransactionDealTimeMsc<=OnlyUpWithdrawScannedMsc )   return;
  double TransactionDealAmount = HistoryDealGetDouble(Trans.deal,DEAL_PROFIT) ;
  if ( TransactionDealAmount<0.0 )   ApplyOnlyUpWithdrawal(TransactionDealAmount) ;
  OnlyUpWithdrawScannedMsc = TransactionDealTimeMsc ;
  GlobalVariableSet(OnlyUpWithdrawGVName(),(double)OnlyUpWithdrawScannedMsc) ;
 }
//OnTradeTransaction <<==--------   --------
 void LoadStrategyRuntimeContext( int StrategyIndex)
 {
 CurrentStrategyIndex = StrategyIndex ;
 SymbolPoint = SymbolInfoDouble(CurrentSymbol,SYMBOL_POINT) ;
 PipSize = SymbolPoint ;
 if ( ( ((double)SymbolInfoInteger(CurrentSymbol,SYMBOL_DIGITS))==3.0 || ((double)SymbolInfoInteger(CurrentSymbol,SYMBOL_DIGITS))==5.0 ) )
 {
   PipSize = SymbolPoint * 10.0 ;
 }
 if ( SymbolInfoInteger(CurrentSymbol,SYMBOL_DIGITS) == 1 )
 {
   PipSize = SymbolPoint / 10.0 ;
 }
 SymbolDigits = (int)((double)SymbolInfoInteger(CurrentSymbol,SYMBOL_DIGITS)) ;
 CurrentSpreadPrice = SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK) - SymbolInfoDouble(CurrentSymbol,SYMBOL_BID) ;
 StopLevelPriceDistance = ((double)SymbolInfoInteger(CurrentSymbol,SYMBOL_TRADE_STOPS_LEVEL)) * SymbolPoint ;
 FreezeLevelPriceDistance = ((double)SymbolInfoInteger(CurrentSymbol,SYMBOL_TRADE_FREEZE_LEVEL)) * SymbolPoint ;
 PendingExpirationSeconds=PendingExpirationHours * 60 * 60;
 if ( PendingExpirationHours >  0 )
 {
   PendingOrderExpirationTime=TimeCurrent() + PendingExpirationSeconds;
 }
 else
 {
   PendingOrderExpirationTime = 0 ;
 }
 if ( Virtual_expiration )
 {
   PendingOrderExpirationTime = 0 ;
 }
 VariableLotInverseScaleFactor = 1.0 ;
 if ( !(UseVariableValues) )   return;
 
 if ( LotSizeReferenceBalance>0.0 )
 {
   VariableValueScaleFactor = iOpen(CurrentSymbol,NormalizeTimeframe(PERIOD_D1),1) / LotSizeReferenceBalance ;
 }
 else
 {
   VariableValueScaleFactor = 1.0 ;
 }
 if ( AdjustLotsizeToVariableValues )
 {
   VariableLotInverseScaleFactor = 1.0 / VariableValueScaleFactor ;
 }
 else
 {
   VariableLotInverseScaleFactor = 1.0 ;
 }
 MinEntryDistancePips = MinEntryDistancePips * VariableValueScaleFactor ;
 BuyEntryOffsetPips = NormalizeDouble(BuyEntryOffsetPips * VariableValueScaleFactor,0) ;
 SellEntryOffsetPips = NormalizeDouble(SellEntryOffsetPips * VariableValueScaleFactor,0) ;
 StopLossPips = StopLossPips * VariableValueScaleFactor ;
 TakeProfitPips = TakeProfitPips * VariableValueScaleFactor ;
 TrailingSLStartPips = TrailingSLStartPips * VariableValueScaleFactor ;
 TrailingSLDistancePips = TrailingSLDistancePips * VariableValueScaleFactor ;
 TrailingSLStepLimitPips = TrailingSLStepLimitPips * VariableValueScaleFactor ;
 TrailingTPStartPips = TrailingTPStartPips * VariableValueScaleFactor ;
 TrailingTPDistancePips = TrailingTPDistancePips * VariableValueScaleFactor ;
 BreakEvenStartPips = BreakEvenStartPips * VariableValueScaleFactor ;
 BreakEvenExtraPips = BreakEvenExtraPips * VariableValueScaleFactor ;
 }
//LoadStrategyRuntimeContext <<==--------   --------
 int RunStrategyCycle( int StrategyIndex)
 {
  bool      TradeManagementChanged;
  datetime  CurrentYearNfpTimeGmt;
  int       NfpDateIndex;
  int       NfpDstAdjustmentMinutes;
  string    FallbackNfpDateText;
  datetime  FallbackNfpTime;
  int       RandomizedEntryOffsetPips;
  int       PendingPlacementAttemptIndex;
//----------------------------------------------------------------------
 int        StoredOrderRowIndex;
 int        StoredOrderFieldIndex;
 int        StoredOrderCount;
 int        OrderStorageScanIndex;
 int        PrimaryBuyDeleteMode;
 int        PrimaryBuyDeleteIndex;
 int        ManualBuyDeleteIndex;
 int        PrimarySellDeleteMode;
 int        PrimarySellDeleteIndex;
 int        ManualSellDeleteIndex;
 int        LegacyManualBuyDeleteMode;
 int        LegacyManualBuyDeleteIndex;
 int        LegacyManualSellDeleteMode;
 int        LegacyManualSellDeleteIndex;
 int        NfpEventYear;
 int        NfpEventMonth;
 int        NfpPrimaryBuyDeleteMode;
 int        NfpPrimaryBuyDeleteIndex;
 int        NfpManualBuyDeleteIndex;
 int        NfpPrimarySellDeleteMode;
 int        NfpPrimarySellDeleteIndex;
 int        NfpManualSellDeleteIndex;
 int        NfpLegacyBuyDeleteMode;
 int        NfpLegacyBuyDeleteIndex;
 int        NfpLegacySellDeleteMode;
 int        NfpLegacySellDeleteIndex;
 int        NfpCloseOrderIndex;
 long        NfpMagicCheck01;
 long        NfpMagicCheck02;
 long        NfpMagicCheck03;
 long        NfpMagicCheck04;
 long        NfpMagicCheck05;
 long        NfpMagicCheck06;
 long        NfpMagicCheck07;
 long        NfpMagicCheck08;
 long        NfpMagicCheck09;
 long        NfpMagicCheck10;
 long        NfpMagicCheck11;
 long        NfpMagicCheck12;
 long        NfpMagicCheck13;
 long        NfpMagicCheck14;
 long        NfpMagicCheck15;
 long        NfpMagicCheck16;
 int        FallbackNfpPrimaryBuyDeleteMode;
 int        FallbackNfpPrimaryBuyDeleteIndex;
 int        FallbackNfpManualBuyDeleteIndex;
 int        FallbackNfpPrimarySellDeleteMode;
 int        FallbackNfpPrimarySellDeleteIndex;
 int        FallbackNfpManualSellDeleteIndex;
 int        FallbackNfpLegacyBuyDeleteMode;
 int        FallbackNfpLegacyBuyDeleteIndex;
 int        FallbackNfpLegacySellDeleteMode;
 int        FallbackNfpLegacySellDeleteIndex;
 int        FallbackNfpCloseOrderIndex;
 long        FallbackNfpMagicCheck01;
 long        FallbackNfpMagicCheck02;
 long        FallbackNfpMagicCheck03;
 long        FallbackNfpMagicCheck04;
 long        FallbackNfpMagicCheck05;
 long        FallbackNfpMagicCheck06;
 long        FallbackNfpMagicCheck07;
 long        FallbackNfpMagicCheck08;
 long        FallbackNfpMagicCheck09;
 long        FallbackNfpMagicCheck10;
 long        FallbackNfpMagicCheck11;
 long        FallbackNfpMagicCheck12;
 long        FallbackNfpMagicCheck13;
 long        FallbackNfpMagicCheck14;
 long        FallbackNfpMagicCheck15;
 long        FallbackNfpMagicCheck16;
 int        FridayCloseOrderIndex;
 long        FridayMagicCheck01;
 long        FridayMagicCheck02;
 long        FridayMagicCheck03;
 long        FridayMagicCheck04;
 long        FridayMagicCheck05;
 long        FridayMagicCheck06;
 long        FridayMagicCheck07;
 long        FridayMagicCheck08;
 long        FridayMagicCheck09;
 long        FridayMagicCheck10;
 long        FridayMagicCheck11;
 long        FridayMagicCheck12;
 long        FridayMagicCheck13;
 long        FridayMagicCheck14;
 long        FridayMagicCheck15;
 long        FridayMagicCheck16;
 int        PendingBuyCount;
 int        PendingBuyCountScanIndex;
 double     HighestBuyStopPrice;
 long       HighestBuyStopTicket;
 int        HighestBuyStopScanIndex;
 long       DeletedBuyStopTicket;
 int        BuyTicketMapIndex;
 int        PendingSellCount;
 int        PendingSellCountScanIndex;
 double     LowestSellStopPrice;
 long       LowestSellStopTicket;
 int        LowestSellStopScanIndex;
 long       DeletedSellStopTicket;
 int        SellTicketMapIndex;
 int        OpenBuyCount;
 int        OpenBuyScanIndex;
 int        OpenSellCount;
 int        OpenSellScanIndex;
 bool       VirtualStopTicketStillOpen;
 int        VirtualStopBufferIndex;
 int        VirtualStopOrderScanIndex;
 bool       TicketMapEntryStillOpen;
 int        TicketMapIndex;
 long       MappedPendingTicket;
 int        TicketMapOrderScanIndex;
 long       SelectedOrderTicket;
 string     DebugStatusText;
 int        DebugPendingBuyCount;
 int        DebugBuyScanIndex;
 int        DebugPendingSellCount;
 int        DebugSellScanIndex;

 CurrentStrategyIndex = StrategyIndex ;
 TradeManagementChanged = false ;
 
 if ( MinimumEntryDistancePercent>0.0 )
 {
   MinEntryDistancePips = MinimumEntryDistancePercent / 100.0 * SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK) * 10.0 ;
 }
 if ( ExitTimingMode == 0 )
 {
   if ( ManageBuyTrades() )
   {
     TradeManagementChanged = true ;
   }
   if ( ManageSellTrades() )
   {
     TradeManagementChanged = true ;
   }
   if ( TradeManagementChanged )
   {
     return(0); 
   }
 }
 else
 {
   if ( LastExitBarCountByStrategy[CurrentStrategyIndex] != iBars(CurrentSymbol,NormalizeTimeframe(ExitTimingMode)) )
   {
     LastExitBarCountByStrategy[CurrentStrategyIndex] = iBars(CurrentSymbol,NormalizeTimeframe(ExitTimingMode));
     if ( ManageBuyTrades() )
     {
       TradeManagementChanged = true ;
     }
     if ( ManageSellTrades() )
     {
       TradeManagementChanged = true ;
     }
     if ( TradeManagementChanged )
     {
       return(0); 
     }
   }
 }
 ResizePendingOrderLots(false); 
 if ( !(IsStrategyTester()) && ((SymbolInfoInteger(CurrentSymbol,SYMBOL_TRADE_MODE)==SYMBOL_TRADE_MODE_FULL)?1.0:0.0)==0.0 )
 {
   if ( !(MarketPauseMessageLogged) )
   {
     Print("Market closed... waiting to continue"); 
   }
   MarketPauseMessageLogged = true ;
   return(0); 
 }
 if ( DayChangeRecoveryDelayMinutes >  0 && ( ( CurrentHour() == 0 && CurrentMinute() < DayChangeRecoveryDelayMinutes ) || (CurrentHour() == 23 && DayChangeRecoveryDelayMinutes >  60 - DayChangeRecoveryDelayMinutes) ) )
 {
   if ( !(MarketPauseMessageLogged) )
   {
     Print("DAYSWITCH -> Market might be closed... waiting " + string(DayChangeRecoveryDelayMinutes) + " minutes before setting order.."); 
   }
   MarketPauseMessageLogged = true ;
   return(0); 
 }
 MarketPauseMessageLogged = false ;
 if ( TradingHoursEnabled )
 {
   if ( IsTradingSessionOpen() && TradingHoursState )
   {
     if ( StorePendingOrdersOutsideTradingHours )
     {
       RestoreStoredPendingOrders(); 
     }
     TradingHoursState = false ;
   }
   if ( !(IsTradingSessionOpen()) && !(TradingHoursState) )
   {
     Print("ENTERING NON-TRADING HOURS! Closing orders..."); 
     if ( StorePendingOrdersOutsideTradingHours )
     {
       for (StoredOrderRowIndex = 0 ; StoredOrderRowIndex < OrderBufferCapacity ; StoredOrderRowIndex=StoredOrderRowIndex + 1)
       {
         for (StoredOrderFieldIndex = 0 ; StoredOrderFieldIndex < 2 ; StoredOrderFieldIndex=StoredOrderFieldIndex + 1)
         {
           StoredPendingOrders[StoredOrderRowIndex][StoredOrderFieldIndex] = 0.0;
         }
       }
       StoredOrderCount = 0;
       for (OrderStorageScanIndex = ActiveTradeCount() ; OrderStorageScanIndex >= 0 ; OrderStorageScanIndex=OrderStorageScanIndex - 1)
       {
         if ( SelectTradeRecord(OrderStorageScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != StrategyMagicNumber || SelectedTradeSymbol() != CurrentSymbol )   continue;
         
         if ( ( SelectedTradeType() != ORDER_TYPE_BUY_STOP && SelectedTradeType() != ORDER_TYPE_SELL_STOP ) )   continue;
         Print("Storing pending order nr " + string(SelectedTradeTicket())); 
         StoredPendingOrders[StoredOrderCount][1] = SelectedTradeType();
         StoredPendingOrders[StoredOrderCount][0] = SelectedTradeOpenPrice();
         StoredPendingOrders[StoredOrderCount][2] = SelectedTradeVolume();
         StoredOrderCount=StoredOrderCount + 1;
         
       }
     }
     PrimaryBuyDeleteMode = 1;
     for (PrimaryBuyDeleteIndex = ActiveTradeCount() ; PrimaryBuyDeleteIndex >= 0 ; PrimaryBuyDeleteIndex=PrimaryBuyDeleteIndex - 1)
     {
       if ( SelectTradeRecord(PrimaryBuyDeleteIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != StrategyMagicNumber || SelectedTradeSymbol() != CurrentSymbol || SelectedTradeType() != ORDER_TYPE_BUY_STOP )   continue;
       DeletePendingOrderByTicket(SelectedTradeTicket(),clrNONE); 
       
     }
     if ( PrimaryBuyDeleteMode == 2 )
     {
       for (ManualBuyDeleteIndex = ActiveTradeCount() ; ManualBuyDeleteIndex >= 0 ; ManualBuyDeleteIndex=ManualBuyDeleteIndex - 1)
       {
         if ( SelectTradeRecord(ManualBuyDeleteIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != ManualStrategy2MagicNumber || SelectedTradeSymbol() != CurrentSymbol || SelectedTradeType() != ORDER_TYPE_BUY_STOP )   continue;
         DeletePendingOrderByTicket(SelectedTradeTicket(),clrNONE); 
         
       }
     }
     PrimarySellDeleteMode = 1;
     for (PrimarySellDeleteIndex = ActiveTradeCount() ; PrimarySellDeleteIndex >= 0 ; PrimarySellDeleteIndex=PrimarySellDeleteIndex - 1)
     {
       if ( SelectTradeRecord(PrimarySellDeleteIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != StrategyMagicNumber || SelectedTradeSymbol() != CurrentSymbol || SelectedTradeType() != ORDER_TYPE_SELL_STOP )   continue;
       DeletePendingOrderByTicket(SelectedTradeTicket(),clrNONE); 
       
     }
     if ( PrimarySellDeleteMode == 2 )
     {
       for (ManualSellDeleteIndex = ActiveTradeCount() ; ManualSellDeleteIndex >= 0 ; ManualSellDeleteIndex=ManualSellDeleteIndex - 1)
       {
         if ( SelectTradeRecord(ManualSellDeleteIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != ManualStrategy2MagicNumber || SelectedTradeSymbol() != CurrentSymbol || SelectedTradeType() != ORDER_TYPE_SELL_STOP )   continue;
         DeletePendingOrderByTicket(SelectedTradeTicket(),clrNONE); 
         
       }
     }
     LegacyManualBuyDeleteMode = 2;
     if(1==0) // Điều kiện luôn sai; giữ nguyên nhánh vô hiệu từ mã gốc.
     {
       do
       {
         if ( SelectTradeRecord(1,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != StrategyMagicNumber || SelectedTradeSymbol() != CurrentSymbol || SelectedTradeType() != ORDER_TYPE_BUY_STOP )   continue;
         DeletePendingOrderByTicket(SelectedTradeTicket(),clrNONE); 
         
       }
       while( - 1 >= 0);
       
     }
     if ( LegacyManualBuyDeleteMode == 2 )
     {
       for (LegacyManualBuyDeleteIndex = ActiveTradeCount() ; LegacyManualBuyDeleteIndex >= 0 ; LegacyManualBuyDeleteIndex=LegacyManualBuyDeleteIndex - 1)
       {
         if ( SelectTradeRecord(LegacyManualBuyDeleteIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != ManualStrategy2MagicNumber || SelectedTradeSymbol() != CurrentSymbol || SelectedTradeType() != ORDER_TYPE_BUY_STOP )   continue;
         DeletePendingOrderByTicket(SelectedTradeTicket(),clrNONE); 
         
       }
     }
     LegacyManualSellDeleteMode = 2;
     if(1==0) // Điều kiện luôn sai; giữ nguyên nhánh vô hiệu từ mã gốc.
     {
       do
       {
         if ( SelectTradeRecord(1,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != StrategyMagicNumber || SelectedTradeSymbol() != CurrentSymbol || SelectedTradeType() != ORDER_TYPE_SELL_STOP )   continue;
         DeletePendingOrderByTicket(SelectedTradeTicket(),clrNONE); 
         
       }
       while( - 1 >= 0);
       
     }
     if ( LegacyManualSellDeleteMode == 2 )
     {
       for (LegacyManualSellDeleteIndex = ActiveTradeCount() ; LegacyManualSellDeleteIndex >= 0 ; LegacyManualSellDeleteIndex=LegacyManualSellDeleteIndex - 1)
       {
         if ( SelectTradeRecord(LegacyManualSellDeleteIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != ManualStrategy2MagicNumber || SelectedTradeSymbol() != CurrentSymbol || SelectedTradeType() != ORDER_TYPE_SELL_STOP )   continue;
         DeletePendingOrderByTicket(SelectedTradeTicket(),clrNONE); 
         
       }
     }
     TradingHoursState = true ;
     return(0); 
   }
 }
 if ( EnableNFP_Filter )
 {
   if ( CurrentYear() <= 2026 || NfpFromCalendar )
   {
     CurrentYearNfpTimeGmt = 0 ;
     for (NfpDateIndex = 0 ; NfpDateIndex < 300 ; NfpDateIndex ++)
     {
       NfpEventYear = DateTimeYear(NfpDatesGmt[NfpDateIndex]);
       if ( NfpEventYear != CurrentYear() )   continue;
       NfpEventMonth = DateTimeMonth(NfpDatesGmt[NfpDateIndex]);
       if ( NfpEventMonth != CurrentMonth() )   continue;
       CurrentYearNfpTimeGmt = NfpDatesGmt[NfpDateIndex] ;
       break;
       
     }
     NfpDstAdjustmentMinutes = 60 ;
     if ( IsAmericanDaylightSavingTime() )
     {
       NfpDstAdjustmentMinutes = 0 ;
     }
     if ( CurrentGmtTime >= CurrentYearNfpTimeGmt - NFP_MinutesBefore * 60 + NfpDstAdjustmentMinutes * 60 && CurrentGmtTime <= CurrentYearNfpTimeGmt + NFP_MinutesAfter * 60 + NfpDstAdjustmentMinutes * 60 )
     {
       if ( NFP_ClosePendingOrders )
       {
         NfpPrimaryBuyDeleteMode = 1;
         for (NfpPrimaryBuyDeleteIndex = ActiveTradeCount() ; NfpPrimaryBuyDeleteIndex >= 0 ; NfpPrimaryBuyDeleteIndex=NfpPrimaryBuyDeleteIndex - 1)
         {
           if ( SelectTradeRecord(NfpPrimaryBuyDeleteIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != StrategyMagicNumber || SelectedTradeSymbol() != CurrentSymbol || SelectedTradeType() != ORDER_TYPE_BUY_STOP )   continue;
           DeletePendingOrderByTicket(SelectedTradeTicket(),clrNONE); 
           
         }
         if ( NfpPrimaryBuyDeleteMode == 2 )
         {
           for (NfpManualBuyDeleteIndex = ActiveTradeCount() ; NfpManualBuyDeleteIndex >= 0 ; NfpManualBuyDeleteIndex=NfpManualBuyDeleteIndex - 1)
           {
             if ( SelectTradeRecord(NfpManualBuyDeleteIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != ManualStrategy2MagicNumber || SelectedTradeSymbol() != CurrentSymbol || SelectedTradeType() != ORDER_TYPE_BUY_STOP )   continue;
             DeletePendingOrderByTicket(SelectedTradeTicket(),clrNONE); 
             
           }
         }
         NfpPrimarySellDeleteMode = 1;
         for (NfpPrimarySellDeleteIndex = ActiveTradeCount() ; NfpPrimarySellDeleteIndex >= 0 ; NfpPrimarySellDeleteIndex=NfpPrimarySellDeleteIndex - 1)
         {
           if ( SelectTradeRecord(NfpPrimarySellDeleteIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != StrategyMagicNumber || SelectedTradeSymbol() != CurrentSymbol || SelectedTradeType() != ORDER_TYPE_SELL_STOP )   continue;
           DeletePendingOrderByTicket(SelectedTradeTicket(),clrNONE); 
           
         }
         if ( NfpPrimarySellDeleteMode == 2 )
         {
           for (NfpManualSellDeleteIndex = ActiveTradeCount() ; NfpManualSellDeleteIndex >= 0 ; NfpManualSellDeleteIndex=NfpManualSellDeleteIndex - 1)
           {
             if ( SelectTradeRecord(NfpManualSellDeleteIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != ManualStrategy2MagicNumber || SelectedTradeSymbol() != CurrentSymbol || SelectedTradeType() != ORDER_TYPE_SELL_STOP )   continue;
             DeletePendingOrderByTicket(SelectedTradeTicket(),clrNONE); 
             
           }
         }
         NfpLegacyBuyDeleteMode = 2;
         if(1==0) // Điều kiện luôn sai; giữ nguyên nhánh vô hiệu từ mã gốc.
         {
           do
           {
             if ( SelectTradeRecord(1,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != StrategyMagicNumber || SelectedTradeSymbol() != CurrentSymbol || SelectedTradeType() != ORDER_TYPE_BUY_STOP )   continue;
             DeletePendingOrderByTicket(SelectedTradeTicket(),clrNONE); 
             
           }
           while( - 1 >= 0);
           
         }
         if ( NfpLegacyBuyDeleteMode == 2 )
         {
           for (NfpLegacyBuyDeleteIndex = ActiveTradeCount() ; NfpLegacyBuyDeleteIndex >= 0 ; NfpLegacyBuyDeleteIndex=NfpLegacyBuyDeleteIndex - 1)
           {
             if ( SelectTradeRecord(NfpLegacyBuyDeleteIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != ManualStrategy2MagicNumber || SelectedTradeSymbol() != CurrentSymbol || SelectedTradeType() != ORDER_TYPE_BUY_STOP )   continue;
             DeletePendingOrderByTicket(SelectedTradeTicket(),clrNONE); 
             
           }
         }
         NfpLegacySellDeleteMode = 2;
         if(1==0) // Điều kiện luôn sai; giữ nguyên nhánh vô hiệu từ mã gốc.
         {
           do
           {
             if ( SelectTradeRecord(1,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != StrategyMagicNumber || SelectedTradeSymbol() != CurrentSymbol || SelectedTradeType() != ORDER_TYPE_SELL_STOP )   continue;
             DeletePendingOrderByTicket(SelectedTradeTicket(),clrNONE); 
             
           }
           while( - 1 >= 0);
           
         }
         if ( NfpLegacySellDeleteMode == 2 )
         {
           for (NfpLegacySellDeleteIndex = ActiveTradeCount() ; NfpLegacySellDeleteIndex >= 0 ; NfpLegacySellDeleteIndex=NfpLegacySellDeleteIndex - 1)
           {
             if ( SelectTradeRecord(NfpLegacySellDeleteIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != ManualStrategy2MagicNumber || SelectedTradeSymbol() != CurrentSymbol || SelectedTradeType() != ORDER_TYPE_SELL_STOP )   continue;
             DeletePendingOrderByTicket(SelectedTradeTicket(),clrNONE); 
             
           }
         }
       }
       if ( NFP_CloseOpenTrades )
       {
         for (NfpCloseOrderIndex = ActiveTradeCount() ; NfpCloseOrderIndex >= 0 ; NfpCloseOrderIndex=NfpCloseOrderIndex - 1)
         {
           if ( SelectTradeRecord(NfpCloseOrderIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeSymbol() != CurrentSymbol )   continue;
           NfpMagicCheck01 = SelectedTradeMagic();
           NfpMagicCheck02=ST1_MagicNumber + 1;
           if ( NfpMagicCheck01 != NfpMagicCheck02 )
           {
             NfpMagicCheck02 = SelectedTradeMagic();
             NfpMagicCheck03=ST1_MagicNumber + 2;
             if ( NfpMagicCheck02 != NfpMagicCheck03 )
             {
               NfpMagicCheck03 = SelectedTradeMagic();
               NfpMagicCheck04=ST1_MagicNumber + 3;
               if ( NfpMagicCheck03 != NfpMagicCheck04 )
               {
                 NfpMagicCheck04 = SelectedTradeMagic();
                 NfpMagicCheck05=ST1_MagicNumber + 4;
                 if ( NfpMagicCheck04 != NfpMagicCheck05 )
                 {
                   NfpMagicCheck05 = SelectedTradeMagic();
                   NfpMagicCheck06=ST1_MagicNumber + 5;
                   if ( NfpMagicCheck05 != NfpMagicCheck06 )
                   {
                     NfpMagicCheck06 = SelectedTradeMagic();
                     NfpMagicCheck07=ST1_MagicNumber + 6;
                     if ( NfpMagicCheck06 != NfpMagicCheck07 )
                     {
                       NfpMagicCheck07 = SelectedTradeMagic();
                       NfpMagicCheck08=ST1_MagicNumber + 7;
                       if ( NfpMagicCheck07 != NfpMagicCheck08 )
                       {
                         NfpMagicCheck08 = SelectedTradeMagic();
                         NfpMagicCheck09=ST1_MagicNumber + 8;
                         if ( NfpMagicCheck08 != NfpMagicCheck09 )
                         {
                           NfpMagicCheck09 = SelectedTradeMagic();
                           NfpMagicCheck10=ST1_MagicNumber + 9;
                           if ( NfpMagicCheck09 != NfpMagicCheck10 )
                           {
                             NfpMagicCheck10 = SelectedTradeMagic();
                             NfpMagicCheck11=ST1_MagicNumber + 10;
                             if ( NfpMagicCheck10 != NfpMagicCheck11 )
                             {
                               NfpMagicCheck11 = SelectedTradeMagic();
                               NfpMagicCheck12=ST1_MagicNumber + 11;
                               if ( NfpMagicCheck11 != NfpMagicCheck12 )
                               {
                                 NfpMagicCheck12 = SelectedTradeMagic();
                                 NfpMagicCheck13=ST1_MagicNumber + 12;
                                 if ( NfpMagicCheck12 != NfpMagicCheck13 )
                                 {
                                   NfpMagicCheck13 = SelectedTradeMagic();
                                   NfpMagicCheck14=ST1_MagicNumber + 13;
                                   if ( NfpMagicCheck13 != NfpMagicCheck14 )
                                   {
                                     NfpMagicCheck14 = SelectedTradeMagic();
                                     NfpMagicCheck15=ST1_MagicNumber + 14;
                                     if ( NfpMagicCheck14 != NfpMagicCheck15 )
                                     {
                                       NfpMagicCheck15 = SelectedTradeMagic();
                                       NfpMagicCheck16=ST1_MagicNumber + 15;
                                     if ( NfpMagicCheck15 != NfpMagicCheck16 )   continue;
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
             ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(CurrentSymbol,SYMBOL_BID),99999,Red); 
           }
           if ( SelectedTradeType() != ORDER_TYPE_SELL )   continue;
           ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK),99999,Red); 
           
         }
       }
       if ( !(NfpTradingSuspended) )
       {
         Print("NFP!! deleting trades!!"); 
       }
       NfpTradingSuspended = true ;
     }
     else
     {
       NfpTradingSuspended = false ;
     }
   }
   else
   {
     if ( CurrentDay() <= 7 && CurrentDayOfWeek() == 5 )
     {
       FallbackNfpDateText = IntegerToString(CurrentYear(),0,32) + IntegerToString(CurrentMonth(),0,32) + IntegerToString(CurrentDay(),0,32) + " " + IntegerToString(NFP_FALLBACK_TIME_HHMM,0,32) ;
       FallbackNfpTime = StringToTime(FallbackNfpDateText) ;
       if ( CurrentGmtTime >= FallbackNfpTime - NFP_MinutesBefore * 60 && CurrentGmtTime <= FallbackNfpTime + NFP_MinutesAfter * 60 )
       {
         if ( NFP_ClosePendingOrders )
         {
           FallbackNfpPrimaryBuyDeleteMode = 1;
           for (FallbackNfpPrimaryBuyDeleteIndex = ActiveTradeCount() ; FallbackNfpPrimaryBuyDeleteIndex >= 0 ; FallbackNfpPrimaryBuyDeleteIndex=FallbackNfpPrimaryBuyDeleteIndex - 1)
           {
             if ( SelectTradeRecord(FallbackNfpPrimaryBuyDeleteIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != StrategyMagicNumber || SelectedTradeSymbol() != CurrentSymbol || SelectedTradeType() != ORDER_TYPE_BUY_STOP )   continue;
             DeletePendingOrderByTicket(SelectedTradeTicket(),clrNONE); 
             
           }
           if ( FallbackNfpPrimaryBuyDeleteMode == 2 )
           {
             for (FallbackNfpManualBuyDeleteIndex = ActiveTradeCount() ; FallbackNfpManualBuyDeleteIndex >= 0 ; FallbackNfpManualBuyDeleteIndex=FallbackNfpManualBuyDeleteIndex - 1)
             {
               if ( SelectTradeRecord(FallbackNfpManualBuyDeleteIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != ManualStrategy2MagicNumber || SelectedTradeSymbol() != CurrentSymbol || SelectedTradeType() != ORDER_TYPE_BUY_STOP )   continue;
               DeletePendingOrderByTicket(SelectedTradeTicket(),clrNONE); 
               
             }
           }
           FallbackNfpPrimarySellDeleteMode = 1;
           for (FallbackNfpPrimarySellDeleteIndex = ActiveTradeCount() ; FallbackNfpPrimarySellDeleteIndex >= 0 ; FallbackNfpPrimarySellDeleteIndex=FallbackNfpPrimarySellDeleteIndex - 1)
           {
             if ( SelectTradeRecord(FallbackNfpPrimarySellDeleteIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != StrategyMagicNumber || SelectedTradeSymbol() != CurrentSymbol || SelectedTradeType() != ORDER_TYPE_SELL_STOP )   continue;
             DeletePendingOrderByTicket(SelectedTradeTicket(),clrNONE); 
             
           }
           if ( FallbackNfpPrimarySellDeleteMode == 2 )
           {
             for (FallbackNfpManualSellDeleteIndex = ActiveTradeCount() ; FallbackNfpManualSellDeleteIndex >= 0 ; FallbackNfpManualSellDeleteIndex=FallbackNfpManualSellDeleteIndex - 1)
             {
               if ( SelectTradeRecord(FallbackNfpManualSellDeleteIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != ManualStrategy2MagicNumber || SelectedTradeSymbol() != CurrentSymbol || SelectedTradeType() != ORDER_TYPE_SELL_STOP )   continue;
               DeletePendingOrderByTicket(SelectedTradeTicket(),clrNONE); 
               
             }
           }
           FallbackNfpLegacyBuyDeleteMode = 2;
           if(1==0) // Điều kiện luôn sai; giữ nguyên nhánh vô hiệu từ mã gốc.
           {
             do
             {
               if ( SelectTradeRecord(1,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != StrategyMagicNumber || SelectedTradeSymbol() != CurrentSymbol || SelectedTradeType() != ORDER_TYPE_BUY_STOP )   continue;
               DeletePendingOrderByTicket(SelectedTradeTicket(),clrNONE); 
               
             }
             while( - 1 >= 0);
             
           }
           if ( FallbackNfpLegacyBuyDeleteMode == 2 )
           {
             for (FallbackNfpLegacyBuyDeleteIndex = ActiveTradeCount() ; FallbackNfpLegacyBuyDeleteIndex >= 0 ; FallbackNfpLegacyBuyDeleteIndex=FallbackNfpLegacyBuyDeleteIndex - 1)
             {
               if ( SelectTradeRecord(FallbackNfpLegacyBuyDeleteIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != ManualStrategy2MagicNumber || SelectedTradeSymbol() != CurrentSymbol || SelectedTradeType() != ORDER_TYPE_BUY_STOP )   continue;
               DeletePendingOrderByTicket(SelectedTradeTicket(),clrNONE); 
               
             }
           }
           FallbackNfpLegacySellDeleteMode = 2;
           if(1==0) // Điều kiện luôn sai; giữ nguyên nhánh vô hiệu từ mã gốc.
           {
             do
             {
               if ( SelectTradeRecord(1,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != StrategyMagicNumber || SelectedTradeSymbol() != CurrentSymbol || SelectedTradeType() != ORDER_TYPE_SELL_STOP )   continue;
               DeletePendingOrderByTicket(SelectedTradeTicket(),clrNONE); 
               
             }
             while( - 1 >= 0);
             
           }
           if ( FallbackNfpLegacySellDeleteMode == 2 )
           {
             for (FallbackNfpLegacySellDeleteIndex = ActiveTradeCount() ; FallbackNfpLegacySellDeleteIndex >= 0 ; FallbackNfpLegacySellDeleteIndex=FallbackNfpLegacySellDeleteIndex - 1)
             {
               if ( SelectTradeRecord(FallbackNfpLegacySellDeleteIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != ManualStrategy2MagicNumber || SelectedTradeSymbol() != CurrentSymbol || SelectedTradeType() != ORDER_TYPE_SELL_STOP )   continue;
               DeletePendingOrderByTicket(SelectedTradeTicket(),clrNONE); 
               
             }
           }
         }
         if ( NFP_CloseOpenTrades )
         {
           for (FallbackNfpCloseOrderIndex = ActiveTradeCount() ; FallbackNfpCloseOrderIndex >= 0 ; FallbackNfpCloseOrderIndex=FallbackNfpCloseOrderIndex - 1)
           {
             if ( SelectTradeRecord(FallbackNfpCloseOrderIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeSymbol() != CurrentSymbol )   continue;
             FallbackNfpMagicCheck01 = SelectedTradeMagic();
             FallbackNfpMagicCheck02=ST1_MagicNumber + 1;
             if ( FallbackNfpMagicCheck01 != FallbackNfpMagicCheck02 )
             {
               FallbackNfpMagicCheck02 = SelectedTradeMagic();
               FallbackNfpMagicCheck03=ST1_MagicNumber + 2;
               if ( FallbackNfpMagicCheck02 != FallbackNfpMagicCheck03 )
               {
                 FallbackNfpMagicCheck03 = SelectedTradeMagic();
                 FallbackNfpMagicCheck04=ST1_MagicNumber + 3;
                 if ( FallbackNfpMagicCheck03 != FallbackNfpMagicCheck04 )
                 {
                   FallbackNfpMagicCheck04 = SelectedTradeMagic();
                   FallbackNfpMagicCheck05=ST1_MagicNumber + 4;
                   if ( FallbackNfpMagicCheck04 != FallbackNfpMagicCheck05 )
                   {
                     FallbackNfpMagicCheck05 = SelectedTradeMagic();
                     FallbackNfpMagicCheck06=ST1_MagicNumber + 5;
                     if ( FallbackNfpMagicCheck05 != FallbackNfpMagicCheck06 )
                     {
                       FallbackNfpMagicCheck06 = SelectedTradeMagic();
                       FallbackNfpMagicCheck07=ST1_MagicNumber + 6;
                       if ( FallbackNfpMagicCheck06 != FallbackNfpMagicCheck07 )
                       {
                         FallbackNfpMagicCheck07 = SelectedTradeMagic();
                         FallbackNfpMagicCheck08=ST1_MagicNumber + 7;
                         if ( FallbackNfpMagicCheck07 != FallbackNfpMagicCheck08 )
                         {
                           FallbackNfpMagicCheck08 = SelectedTradeMagic();
                           FallbackNfpMagicCheck09=ST1_MagicNumber + 8;
                           if ( FallbackNfpMagicCheck08 != FallbackNfpMagicCheck09 )
                           {
                             FallbackNfpMagicCheck09 = SelectedTradeMagic();
                             FallbackNfpMagicCheck10=ST1_MagicNumber + 9;
                             if ( FallbackNfpMagicCheck09 != FallbackNfpMagicCheck10 )
                             {
                               FallbackNfpMagicCheck10 = SelectedTradeMagic();
                               FallbackNfpMagicCheck11=ST1_MagicNumber + 10;
                               if ( FallbackNfpMagicCheck10 != FallbackNfpMagicCheck11 )
                               {
                                 FallbackNfpMagicCheck11 = SelectedTradeMagic();
                                 FallbackNfpMagicCheck12=ST1_MagicNumber + 11;
                                 if ( FallbackNfpMagicCheck11 != FallbackNfpMagicCheck12 )
                                 {
                                   FallbackNfpMagicCheck12 = SelectedTradeMagic();
                                   FallbackNfpMagicCheck13=ST1_MagicNumber + 12;
                                   if ( FallbackNfpMagicCheck12 != FallbackNfpMagicCheck13 )
                                   {
                                     FallbackNfpMagicCheck13 = SelectedTradeMagic();
                                     FallbackNfpMagicCheck14=ST1_MagicNumber + 13;
                                     if ( FallbackNfpMagicCheck13 != FallbackNfpMagicCheck14 )
                                     {
                                       FallbackNfpMagicCheck14 = SelectedTradeMagic();
                                       FallbackNfpMagicCheck15=ST1_MagicNumber + 14;
                                       if ( FallbackNfpMagicCheck14 != FallbackNfpMagicCheck15 )
                                       {
                                         FallbackNfpMagicCheck15 = SelectedTradeMagic();
                                         FallbackNfpMagicCheck16=ST1_MagicNumber + 15;
                                       if ( FallbackNfpMagicCheck15 != FallbackNfpMagicCheck16 )   continue;
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
               ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(CurrentSymbol,SYMBOL_BID),99999,Red); 
             }
             if ( SelectedTradeType() != ORDER_TYPE_SELL )   continue;
             ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK),99999,Red); 
             
           }
         }
         if ( !(NfpTradingSuspended) )
         {
           Print("NFP!! deleting trades!!"); 
         }
         NfpTradingSuspended = true ;
       }
       else
       {
         NfpTradingSuspended = false ;
       }
     }
   }
 }
 if ( NfpTradingSuspended )
 {
   return(0); 
 }
 if ( FridayStopEnabled )
 {
   if ( CurrentDayOfWeek() == 5 && CurrentHour() >= FridayStopHour && !(FridayTradingSuspended) )
   {
     for (FridayCloseOrderIndex = ActiveTradeCount() ; FridayCloseOrderIndex >= 0 ; FridayCloseOrderIndex=FridayCloseOrderIndex - 1)
     {
       if ( SelectTradeRecord(FridayCloseOrderIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeSymbol() != CurrentSymbol )   continue;
       FridayMagicCheck01 = SelectedTradeMagic();
       FridayMagicCheck02=ST1_MagicNumber + 1;
       if ( FridayMagicCheck01 != FridayMagicCheck02 )
       {
         FridayMagicCheck02 = SelectedTradeMagic();
         FridayMagicCheck03=ST1_MagicNumber + 2;
         if ( FridayMagicCheck02 != FridayMagicCheck03 )
         {
           FridayMagicCheck03 = SelectedTradeMagic();
           FridayMagicCheck04=ST1_MagicNumber + 3;
           if ( FridayMagicCheck03 != FridayMagicCheck04 )
           {
             FridayMagicCheck04 = SelectedTradeMagic();
             FridayMagicCheck05=ST1_MagicNumber + 4;
             if ( FridayMagicCheck04 != FridayMagicCheck05 )
             {
               FridayMagicCheck05 = SelectedTradeMagic();
               FridayMagicCheck06=ST1_MagicNumber + 5;
               if ( FridayMagicCheck05 != FridayMagicCheck06 )
               {
                 FridayMagicCheck06 = SelectedTradeMagic();
                 FridayMagicCheck07=ST1_MagicNumber + 6;
                 if ( FridayMagicCheck06 != FridayMagicCheck07 )
                 {
                   FridayMagicCheck07 = SelectedTradeMagic();
                   FridayMagicCheck08=ST1_MagicNumber + 7;
                   if ( FridayMagicCheck07 != FridayMagicCheck08 )
                   {
                     FridayMagicCheck08 = SelectedTradeMagic();
                     FridayMagicCheck09=ST1_MagicNumber + 8;
                     if ( FridayMagicCheck08 != FridayMagicCheck09 )
                     {
                       FridayMagicCheck09 = SelectedTradeMagic();
                       FridayMagicCheck10=ST1_MagicNumber + 9;
                       if ( FridayMagicCheck09 != FridayMagicCheck10 )
                       {
                         FridayMagicCheck10 = SelectedTradeMagic();
                         FridayMagicCheck11=ST1_MagicNumber + 10;
                         if ( FridayMagicCheck10 != FridayMagicCheck11 )
                         {
                           FridayMagicCheck11 = SelectedTradeMagic();
                           FridayMagicCheck12=ST1_MagicNumber + 11;
                           if ( FridayMagicCheck11 != FridayMagicCheck12 )
                           {
                             FridayMagicCheck12 = SelectedTradeMagic();
                             FridayMagicCheck13=ST1_MagicNumber + 12;
                             if ( FridayMagicCheck12 != FridayMagicCheck13 )
                             {
                               FridayMagicCheck13 = SelectedTradeMagic();
                               FridayMagicCheck14=ST1_MagicNumber + 13;
                               if ( FridayMagicCheck13 != FridayMagicCheck14 )
                               {
                                 FridayMagicCheck14 = SelectedTradeMagic();
                                 FridayMagicCheck15=ST1_MagicNumber + 14;
                                 if ( FridayMagicCheck14 != FridayMagicCheck15 )
                                 {
                                   FridayMagicCheck15 = SelectedTradeMagic();
                                   FridayMagicCheck16=ST1_MagicNumber + 15;
                                 if ( FridayMagicCheck15 != FridayMagicCheck16 )   continue;
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
         ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(CurrentSymbol,SYMBOL_BID),(int)OrderSlippageSetting,Red); 
       }
       if ( FridayCloseOpen && SelectedTradeType() == ORDER_TYPE_SELL )
       {
         ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK),(int)OrderSlippageSetting,Red); 
       }
       if ( ( SelectedTradeType() != ORDER_TYPE_BUY_STOP && SelectedTradeType() != ORDER_TYPE_SELL_STOP ) || !(FridayClosePending) )   continue;
       DeletePendingOrderByTicket(SelectedTradeTicket(),Red); 
       
     }
     Print("Weekend starting! closing trades.."); 
     FridayTradingSuspended = true ;
     return(0); 
   }
   if ( CurrentDayOfWeek() != 5 && FridayTradingSuspended == true )
   {
     FridayTradingSuspended = false ;
     if ( RestorePendingOrdersAfterFridayPause )
     {
       RestoreStoredPendingOrders(); 
       return(0); 
     }
   }
 }
 CurrentSpreadPrice = SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK) - SymbolInfoDouble(CurrentSymbol,SYMBOL_BID) ;
 if ( SuspendPendingOrdersOnHighSpreadEnabled )
 {
   if ( CurrentSpreadPrice>MaxSpread * PipSize )
   {
     SuspendPendingOrdersOnHighSpread(); 
     return(0); 
   }
   if ( CurrentSpreadPrice<=MaxSpreadPips * PipSize && ( !(FridayStopEnabled) || CurrentDayOfWeek() != 5 || CurrentHour() <  FridayStopHour ) && ( !(TradingHoursEnabled) || IsTradingSessionOpen() ) )
   {
     RestoreStoredPendingOrders(); 
   }
 }
 if ( EntryStrategyMode == 1 )
 {
   PendingBuyCount = 0;
   for (PendingBuyCountScanIndex = ActiveTradeCount() ; PendingBuyCountScanIndex >= 0 ; PendingBuyCountScanIndex=PendingBuyCountScanIndex - 1)
   {
     if ( SelectTradeRecord(PendingBuyCountScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != StrategyMagicNumber || SelectedTradeSymbol() != CurrentSymbol || SelectedTradeType() != ORDER_TYPE_BUY_STOP )   continue;
     PendingBuyCount=PendingBuyCount + 1;
     
   }
   if ( PendingBuyCount >  MaxPendingOrders )
   {
     HighestBuyStopPrice = 0.0;
     HighestBuyStopTicket = 0;
     for (HighestBuyStopScanIndex = ActiveTradeCount() ; HighestBuyStopScanIndex >= 0 ; HighestBuyStopScanIndex=HighestBuyStopScanIndex - 1)
     {
       if ( SelectTradeRecord(HighestBuyStopScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != StrategyMagicNumber || SelectedTradeSymbol() != CurrentSymbol || SelectedTradeType() != ORDER_TYPE_BUY_STOP || !(SelectedTradeOpenPrice()>HighestBuyStopPrice) )   continue;
       HighestBuyStopTicket = SelectedTradeTicket();
       HighestBuyStopPrice = SelectedTradeOpenPrice();
       
     }
     if ( HighestBuyStopTicket != 0 )
     {
       DeletePendingOrderByTicket(HighestBuyStopTicket,Green); 
       DeletedBuyStopTicket = HighestBuyStopTicket;
       for (BuyTicketMapIndex = 0 ; BuyTicketMapIndex < 100 ; BuyTicketMapIndex=BuyTicketMapIndex + 1)
       {
         if ( !(PendingTicketPriceMap[BuyTicketMapIndex][0]==DeletedBuyStopTicket) )   continue;
         PendingTicketPriceMap[BuyTicketMapIndex][0] = 0.0;
         PendingTicketPriceMap[BuyTicketMapIndex][1] = 0.0;
         break;
         
       }
       Print("Max number of pending buy orders reached... deleting highest buystop order!"); 
     }
   }
   PendingSellCount = 0;
   for (PendingSellCountScanIndex = ActiveTradeCount() ; PendingSellCountScanIndex >= 0 ; PendingSellCountScanIndex=PendingSellCountScanIndex - 1)
   {
     if ( SelectTradeRecord(PendingSellCountScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != StrategyMagicNumber || SelectedTradeSymbol() != CurrentSymbol || SelectedTradeType() != ORDER_TYPE_SELL_STOP )   continue;
     PendingSellCount=PendingSellCount + 1;
     
   }
   if ( PendingSellCount >  MaxPendingOrders )
   {
     LowestSellStopPrice = 9999.0;
     LowestSellStopTicket = 0;
     for (LowestSellStopScanIndex = ActiveTradeCount() ; LowestSellStopScanIndex >= 0 ; LowestSellStopScanIndex=LowestSellStopScanIndex - 1)
     {
       if ( SelectTradeRecord(LowestSellStopScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != StrategyMagicNumber || SelectedTradeSymbol() != CurrentSymbol || SelectedTradeType() != ORDER_TYPE_SELL_STOP || !(SelectedTradeOpenPrice()<LowestSellStopPrice) )   continue;
       LowestSellStopTicket = SelectedTradeTicket();
       LowestSellStopPrice = SelectedTradeOpenPrice();
       
     }
     if ( LowestSellStopTicket != 0 )
     {
       DeletePendingOrderByTicket(LowestSellStopTicket,Green); 
       DeletedSellStopTicket = LowestSellStopTicket;
       for (SellTicketMapIndex = 0 ; SellTicketMapIndex < 100 ; SellTicketMapIndex=SellTicketMapIndex + 1)
       {
         if ( !(PendingTicketPriceMap[SellTicketMapIndex][0]==DeletedSellStopTicket) )   continue;
         PendingTicketPriceMap[SellTicketMapIndex][0] = 0.0;
         PendingTicketPriceMap[SellTicketMapIndex][1] = 0.0;
         break;
         
       }
       Print("Max number of pending sell orders reached... deleting lowest sellstop order!"); 
     }
   }
 }
 if ( !(FridayTradingSuspended) && EntryStrategyMode == 1 && !(TradingHoursState) )
 {
   if ( ( LastEntryBarCountByStrategy[CurrentStrategyIndex] != iBars(CurrentSymbol,NormalizeTimeframe(EntryTimingTimeframeMinutes)) || EntryTimingTimeframeMinutes == 0 ) )
   {
     LastEntryBarCountByStrategy[CurrentStrategyIndex] = iBars(CurrentSymbol,NormalizeTimeframe(EntryTimingTimeframeMinutes));
     if ( HighLowLeftBars >  0 && HighLowRightBars >= 0 )
     {
       BuyTriggerPriceByStrategy[CurrentStrategyIndex] = HighLowTrailingOffsetPips * PipSize + (FindQualifiedSwingHigh(HighLowTrailingTimeframeMinutes,HighLowLeftBars,HighLowRightBars) + CurrentSpreadPrice);
       SellTriggerPriceByStrategy[CurrentStrategyIndex] = FindQualifiedSwingLow(HighLowTrailingTimeframeMinutes,HighLowLeftBars,HighLowRightBars) - HighLowTrailingOffsetPips * PipSize;
     }
     if ( RandomPendingOffsetMaximumPips >  0 )
     {
       RandomizedEntryOffsetPips=MathRand() * RandomPendingOffsetMaximumPips / 32768 + 1;
       RandomizedPendingEntryOffsetPips = RandomizedEntryOffsetPips ;
       Print("Slippage: " + (string(RandomizedEntryOffsetPips))); 
     }
     if ( TradeMonitorFilterMode != 1 )
     {
       OpenBuyCount = 0;
       for (OpenBuyScanIndex = ActiveTradeCount() ; OpenBuyScanIndex >= 0 ; OpenBuyScanIndex=OpenBuyScanIndex - 1)
       {
         if ( SelectTradeRecord(OpenBuyScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != StrategyMagicNumber || SelectedTradeSymbol() != CurrentSymbol || SelectedTradeType() != ORDER_TYPE_BUY )   continue;
         OpenBuyCount=OpenBuyCount + 1;
         
       }
       if ( OpenBuyCount == 0 )
       {
         OpenSellCount = 0;
         for (OpenSellScanIndex = ActiveTradeCount() ; OpenSellScanIndex >= 0 ; OpenSellScanIndex=OpenSellScanIndex - 1)
         {
           if ( SelectTradeRecord(OpenSellScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != StrategyMagicNumber || SelectedTradeSymbol() != CurrentSymbol || SelectedTradeType() != ORDER_TYPE_SELL )   continue;
           OpenSellCount=OpenSellCount + 1;
           
         }
         if ( OpenSellCount == 0 )
         {
           VirtualStopTicketStillOpen = false;
           for (VirtualStopBufferIndex = 0 ; VirtualStopBufferIndex < SmallBufferCapacity ; VirtualStopBufferIndex=VirtualStopBufferIndex + 1)
           {
             if ( !(VirtualStopByTicket[VirtualStopBufferIndex][0]>0.0) )   continue;
             VirtualStopTicketStillOpen = false;
             for (VirtualStopOrderScanIndex = ActiveTradeCount() ; VirtualStopOrderScanIndex >= 0 ; VirtualStopOrderScanIndex=VirtualStopOrderScanIndex - 1)
             {
               if ( SelectTradeRecord(VirtualStopOrderScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true )   continue;
               
               if ( ( SelectedTradeType() != ORDER_TYPE_BUY && SelectedTradeType() != ORDER_TYPE_SELL ) || !(SelectedTradeTicket()==VirtualStopByTicket[VirtualStopBufferIndex][0]) )   continue;
               VirtualStopTicketStillOpen = true;
               
             }
             if ( VirtualStopTicketStillOpen )   continue;
             VirtualStopByTicket[VirtualStopBufferIndex][0] = 0.0;
             VirtualStopByTicket[VirtualStopBufferIndex][1] = 0.0;
             
           }
         }
       }
     }
     for (PendingPlacementAttemptIndex = 0 ; PendingPlacementAttemptIndex < MaxPendingOrders ; PendingPlacementAttemptIndex ++)
     {
       ManagePendingEntries(); 
     }
   }
   UpdateInfoPanelTotals(); 
   if ( LastEntryHour != CurrentHour() )
   {
     LastEntryHour = CurrentHour() ;
     TicketMapEntryStillOpen = false;
     for (TicketMapIndex = 0 ; TicketMapIndex < 100 ; TicketMapIndex=TicketMapIndex + 1)
     {
       MappedPendingTicket = (long)PendingTicketPriceMap[TicketMapIndex][0];
       TicketMapEntryStillOpen = false;
       for (TicketMapOrderScanIndex = ActiveTradeCount() ; TicketMapOrderScanIndex >= 0 ; TicketMapOrderScanIndex=TicketMapOrderScanIndex - 1)
       {
         if ( !(SelectTradeRecord(TicketMapOrderScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE)) )   continue;
         SelectedOrderTicket = SelectedTradeTicket();
         if ( MappedPendingTicket != SelectedOrderTicket )   continue;
         TicketMapEntryStillOpen = true;
         
       }
       if ( TicketMapEntryStillOpen )   continue;
       PendingTicketPriceMap[TicketMapIndex][0] = 0.0;
       PendingTicketPriceMap[TicketMapIndex][1] = 0.0;
       
     }
   }
 }
 if ( ShowTradeDebugComments )
 {
   DebugStatusText="Current spread: " + string(NormalizeDouble(CurrentSpreadPrice / PipSize,1)) + "\nPending Buy Order: ";
   DebugPendingBuyCount = 0;
   for (DebugBuyScanIndex = ActiveTradeCount() ; DebugBuyScanIndex >= 0 ; DebugBuyScanIndex=DebugBuyScanIndex - 1)
   {
     if ( SelectTradeRecord(DebugBuyScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != StrategyMagicNumber || SelectedTradeSymbol() != CurrentSymbol || SelectedTradeType() != ORDER_TYPE_BUY_STOP )   continue;
     DebugPendingBuyCount=DebugPendingBuyCount + 1;
     
   }
   DebugStatusText=DebugStatusText + string(DebugPendingBuyCount);
   DebugStatusText=DebugStatusText + "\nPending Sell Orders: ";
   DebugPendingSellCount = 0;
   for (DebugSellScanIndex = ActiveTradeCount() ; DebugSellScanIndex >= 0 ; DebugSellScanIndex=DebugSellScanIndex - 1)
   {
     if ( SelectTradeRecord(DebugSellScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != StrategyMagicNumber || SelectedTradeSymbol() != CurrentSymbol || SelectedTradeType() != ORDER_TYPE_SELL_STOP )   continue;
     DebugPendingSellCount=DebugPendingSellCount + 1;
     
   }
   DebugStatusText=DebugStatusText + string(DebugPendingSellCount);
   Comment(DebugStatusText); 
 }
 return(0); 
 }
//RunStrategyCycle <<==--------   --------
 void RestoreStoredPendingOrders()
 {
  int       StoredOrderIndex;
//----------------------------------------------------------------------
 double     BuyStoredPrice;
 long       RestoredBuyTicket;
 int        BuyTicketMapInsertIndex;
 double     RetryBuyStoredPrice;
 long       RetryRestoredBuyTicket;
 int        RetryBuyTicketMapIndex;
 double     SellStoredPrice;
 long       RestoredSellTicket;
 int        SellTicketMapInsertIndex;
 double     RetrySellStoredPrice;
 long       RetryRestoredSellTicket;
 int        RetrySellTicketMapIndex;
 int        StoredOrderClearIndex;

 for (StoredOrderIndex = 0 ; StoredOrderIndex < OrderBufferCapacity ; StoredOrderIndex ++)
 {
   if ( !(StoredPendingOrders[StoredOrderIndex][0]>0.0) )   continue;
   
   if ( StoredPendingOrders[StoredOrderIndex][1]==ORDER_TYPE_BUY_STOP && SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK)<StoredPendingOrders[StoredOrderIndex][0] - StopLevelPriceDistance )
   {
     Print("Restoring pending buy-order"); 
     LastTradeTicket = SendTradeOrder(CurrentSymbol,ORDER_TYPE_BUY_STOP,StoredPendingOrders[StoredOrderIndex][2],StoredPendingOrders[StoredOrderIndex][0],int(OrderSlippageSetting * PipSize),StoredPendingOrders[StoredOrderIndex][0] - (StopLossPips + ExtraStopLossPips) * PipSize,TakeProfitPips * PipSize + StoredPendingOrders[StoredOrderIndex][0],CurrentStrategyComment,StrategyMagicNumber,PendingOrderExpirationTime + RESTORED_PENDING_EXPIRATION_EXTENSION_SECONDS,Green) ;
     BuyPendingRestoreState = false ;
     BuyStoredPrice = StoredPendingOrders[StoredOrderIndex][0];
     RestoredBuyTicket = LastTradeTicket;
     for (BuyTicketMapInsertIndex = 0 ; BuyTicketMapInsertIndex < 100 ; BuyTicketMapInsertIndex=BuyTicketMapInsertIndex + 1)
     {
       if ( !(PendingTicketPriceMap[BuyTicketMapInsertIndex][0]==0.0) )   continue;
       PendingTicketPriceMap[BuyTicketMapInsertIndex][0] = (double)RestoredBuyTicket;
       PendingTicketPriceMap[BuyTicketMapInsertIndex][1] = BuyStoredPrice;
       break;
       
     }
     if ( LastTradeTicket <= 0 )
     {
       if ( LastTradeErrorCode() == STRATEGY_ERROR_MARKET_CLOSED )
       {
         ResetLastError();
         if(1==0) // Điều kiện luôn sai; giữ nguyên nhánh vô hiệu từ mã gốc.
         {
           do
           {
             Sleep(2500); 
             LastTradeTicket = SendTradeOrder(CurrentSymbol,ORDER_TYPE_BUY_STOP,StoredPendingOrders[StoredOrderIndex][2],StoredPendingOrders[StoredOrderIndex][0],int(OrderSlippageSetting * PipSize),StoredPendingOrders[StoredOrderIndex][0] - (StopLossPips + ExtraStopLossPips) * PipSize,TakeProfitPips * PipSize + StoredPendingOrders[StoredOrderIndex][0],CurrentStrategyComment,StrategyMagicNumber,PendingOrderExpirationTime + RESTORED_PENDING_EXPIRATION_EXTENSION_SECONDS,Green) ;
             BuyPendingRestoreState = false ;
             RetryBuyStoredPrice = StoredPendingOrders[StoredOrderIndex][0];
             RetryRestoredBuyTicket = LastTradeTicket;
             for (RetryBuyTicketMapIndex = 0 ; RetryBuyTicketMapIndex < 100 ; RetryBuyTicketMapIndex=RetryBuyTicketMapIndex + 1)
             {
               if ( !(PendingTicketPriceMap[RetryBuyTicketMapIndex][0]==0.0) )   continue;
               PendingTicketPriceMap[RetryBuyTicketMapIndex][0] = (double)RetryRestoredBuyTicket;
               PendingTicketPriceMap[RetryBuyTicketMapIndex][1] = RetryBuyStoredPrice;
               break;
               
             }
           }
           while(LastTradeErrorCode() == STRATEGY_ERROR_MARKET_CLOSED);
           
         }
       }
       Print("error: \'" + TradeErrorDescription(LastTradeErrorCode()) + "\' when setting entry order"); 
     }
   }
   if ( !(StoredPendingOrders[StoredOrderIndex][1]==ORDER_TYPE_SELL_STOP) || !(SymbolInfoDouble(CurrentSymbol,SYMBOL_BID)>StoredPendingOrders[StoredOrderIndex][0] + StopLevelPriceDistance) )   continue;
   Print("Restoring pending sell-order"); 
   LastTradeTicket = SendTradeOrder(CurrentSymbol,ORDER_TYPE_SELL_STOP,StoredPendingOrders[StoredOrderIndex][2],StoredPendingOrders[StoredOrderIndex][0],int(OrderSlippageSetting * PipSize),(StopLossPips + ExtraStopLossPips) * PipSize + StoredPendingOrders[StoredOrderIndex][0],StoredPendingOrders[StoredOrderIndex][0] - TakeProfitPips * PipSize,CurrentStrategyComment,StrategyMagicNumber,PendingOrderExpirationTime + RESTORED_PENDING_EXPIRATION_EXTENSION_SECONDS,Green) ;
   SellPendingRestoreState = false ;
   SellStoredPrice = StoredPendingOrders[StoredOrderIndex][0];
   RestoredSellTicket = LastTradeTicket;
   for (SellTicketMapInsertIndex = 0 ; SellTicketMapInsertIndex < 100 ; SellTicketMapInsertIndex=SellTicketMapInsertIndex + 1)
   {
     if ( !(PendingTicketPriceMap[SellTicketMapInsertIndex][0]==0.0) )   continue;
     PendingTicketPriceMap[SellTicketMapInsertIndex][0] = (double)RestoredSellTicket;
     PendingTicketPriceMap[SellTicketMapInsertIndex][1] = SellStoredPrice;
     break;
     
   }
   if ( LastTradeTicket > 0 )   continue;
   
   if ( LastTradeErrorCode() == STRATEGY_ERROR_MARKET_CLOSED )
   {
     ResetLastError();
     if(1==0) // Điều kiện luôn sai; giữ nguyên nhánh vô hiệu từ mã gốc.
     {
       do
       {
         Sleep(2500); 
         LastTradeTicket = SendTradeOrder(CurrentSymbol,ORDER_TYPE_SELL_STOP,StoredPendingOrders[StoredOrderIndex][2],StoredPendingOrders[StoredOrderIndex][0],int(OrderSlippageSetting * PipSize),(StopLossPips + ExtraStopLossPips) * PipSize + StoredPendingOrders[StoredOrderIndex][0],StoredPendingOrders[StoredOrderIndex][0] - TakeProfitPips * PipSize,CurrentStrategyComment,StrategyMagicNumber,PendingOrderExpirationTime + RESTORED_PENDING_EXPIRATION_EXTENSION_SECONDS,Green) ;
         SellPendingRestoreState = false ;
         RetrySellStoredPrice = StoredPendingOrders[StoredOrderIndex][0];
         RetryRestoredSellTicket = LastTradeTicket;
         for (RetrySellTicketMapIndex = 0 ; RetrySellTicketMapIndex < 100 ; RetrySellTicketMapIndex=RetrySellTicketMapIndex + 1)
         {
           if ( !(PendingTicketPriceMap[RetrySellTicketMapIndex][0]==0.0) )   continue;
           PendingTicketPriceMap[RetrySellTicketMapIndex][0] = (double)RetryRestoredSellTicket;
           PendingTicketPriceMap[RetrySellTicketMapIndex][1] = RetrySellStoredPrice;
           break;
           
         }
       }
       while(LastTradeErrorCode() == STRATEGY_ERROR_MARKET_CLOSED);
       
     }
   }
   Print("error: \'" + TradeErrorDescription(LastTradeErrorCode()) + "\' when setting entry order"); 
   
 }
 for (StoredOrderClearIndex = 0 ; StoredOrderClearIndex < OrderBufferCapacity ; StoredOrderClearIndex=StoredOrderClearIndex + 1)
 {
   StoredPendingOrders[StoredOrderClearIndex][0] = 0.0;
   StoredPendingOrders[StoredOrderClearIndex][1] = 0.0;
   StoredPendingOrders[StoredOrderClearIndex][2] = 0.0;
 }
 }
//RestoreStoredPendingOrders <<==--------   --------
 bool SuspendPendingOrdersOnHighSpread()
 {
  int       OrderScanIndex;
  int       BuyStorageIndex;
  int       SellStorageIndex;
//----------------------------------------------------------------------
 long       StoredBuyTicket;
 int        StoredBuyTicketMapIndex;
 long       DeletedBuyTicket;
 int        DeletedBuyTicketMapIndex;
 double     SellOrderPrice;
 double     CurrentBid;
 long       StoredSellTicket;
 int        StoredSellTicketMapIndex;
 long       DeletedSellTicket;
 int        DeletedSellTicketMapIndex;

 for (OrderScanIndex = ActiveTradeCount() ; OrderScanIndex >= 0 ; OrderScanIndex --)
 {
   if ( SelectTradeRecord(OrderScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true )   continue;
   
   if ( ( SelectedTradeMagic() != StrategyMagicNumber && SelectedTradeMagic() != ManualStrategy2MagicNumber ) || SelectedTradeSymbol() != CurrentSymbol )   continue;
   
   if ( SelectedTradeType() == ORDER_TYPE_BUY_STOP && SelectedTradeOpenPrice()<MinPendingMarketGapPips * PipSize + SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK) && SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK)<SelectedTradeOpenPrice() - FreezeLevelPriceDistance )
   {
     if ( MaxSpreadPips>0.0 )
     {
       Print("Spread too high..(" + string(CurrentSpreadPrice) + ") storing and deleting order " + string(SelectedTradeTicket())); 
       for (BuyStorageIndex = 0 ; BuyStorageIndex < OrderBufferCapacity ; BuyStorageIndex ++)
       {
         if ( StoredPendingOrders[BuyStorageIndex][0]==0.0 )
         {
           Print("Storing pending order nr " + string(SelectedTradeTicket())); 
           StoredPendingOrders[BuyStorageIndex][1] = SelectedTradeType();
           StoredPendingOrders[BuyStorageIndex][0] = SelectedTradeOpenPrice();
           StoredPendingOrders[BuyStorageIndex][2] = SelectedTradeVolume();
           break;
         }
       }
       StoredBuyTicket = SelectedTradeTicket();
       for (StoredBuyTicketMapIndex = 0 ; StoredBuyTicketMapIndex < 100 ; StoredBuyTicketMapIndex=StoredBuyTicketMapIndex + 1)
       {
         if ( !(PendingTicketPriceMap[StoredBuyTicketMapIndex][0]==StoredBuyTicket) )   continue;
         PendingTicketPriceMap[StoredBuyTicketMapIndex][0] = 0.0;
         PendingTicketPriceMap[StoredBuyTicketMapIndex][1] = 0.0;
         break;
         
       }
       DeletePendingOrderByTicket(SelectedTradeTicket(),Green); 
     }
     else
     {
       Print("Spread too high..(" + string(CurrentSpreadPrice) + ") deleting order " + string(SelectedTradeTicket())); 
       DeletedBuyTicket = SelectedTradeTicket();
       for (DeletedBuyTicketMapIndex = 0 ; DeletedBuyTicketMapIndex < 100 ; DeletedBuyTicketMapIndex=DeletedBuyTicketMapIndex + 1)
       {
         if ( !(PendingTicketPriceMap[DeletedBuyTicketMapIndex][0]==DeletedBuyTicket) )   continue;
         PendingTicketPriceMap[DeletedBuyTicketMapIndex][0] = 0.0;
         PendingTicketPriceMap[DeletedBuyTicketMapIndex][1] = 0.0;
         break;
         
       }
       DeletePendingOrderByTicket(SelectedTradeTicket(),Green); 
     }
   }
   if ( SelectedTradeType() != ORDER_TYPE_SELL_STOP )   continue;
   SellOrderPrice = SelectedTradeOpenPrice();
   if ( !(SellOrderPrice>SymbolInfoDouble(CurrentSymbol,SYMBOL_BID) - MinPendingMarketGapPips * PipSize) )   continue;
   CurrentBid = SymbolInfoDouble(CurrentSymbol,SYMBOL_BID);
   if ( !(CurrentBid>SelectedTradeOpenPrice() + FreezeLevelPriceDistance) )   continue;
   
   if ( MaxSpreadPips>0.0 )
   {
     Print("Spread too high..(" + string(CurrentSpreadPrice) + ") storing and deleting order " + string(SelectedTradeTicket())); 
     for (SellStorageIndex = 0 ; SellStorageIndex < OrderBufferCapacity ; SellStorageIndex ++)
     {
       if ( StoredPendingOrders[SellStorageIndex][0]==0.0 )
       {
         Print("Storing pending order nr " + string(SelectedTradeTicket())); 
         StoredPendingOrders[SellStorageIndex][1] = SelectedTradeType();
         StoredPendingOrders[SellStorageIndex][0] = SelectedTradeOpenPrice();
         StoredPendingOrders[SellStorageIndex][2] = SelectedTradeVolume();
         break;
       }
     }
     StoredSellTicket = SelectedTradeTicket();
     for (StoredSellTicketMapIndex = 0 ; StoredSellTicketMapIndex < 100 ; StoredSellTicketMapIndex=StoredSellTicketMapIndex + 1)
     {
       if ( !(PendingTicketPriceMap[StoredSellTicketMapIndex][0]==StoredSellTicket) )   continue;
       PendingTicketPriceMap[StoredSellTicketMapIndex][0] = 0.0;
       PendingTicketPriceMap[StoredSellTicketMapIndex][1] = 0.0;
       break;
       
     }
     DeletePendingOrderByTicket(SelectedTradeTicket(),Green); 
      continue;
   }
   Print("Spread too high..(" + string(CurrentSpreadPrice) + ") deleting order " + string(SelectedTradeTicket())); 
   DeletedSellTicket = SelectedTradeTicket();
   for (DeletedSellTicketMapIndex = 0 ; DeletedSellTicketMapIndex < 100 ; DeletedSellTicketMapIndex=DeletedSellTicketMapIndex + 1)
   {
     if ( !(PendingTicketPriceMap[DeletedSellTicketMapIndex][0]==DeletedSellTicket) )   continue;
     PendingTicketPriceMap[DeletedSellTicketMapIndex][0] = 0.0;
     PendingTicketPriceMap[DeletedSellTicketMapIndex][1] = 0.0;
     break;
     
   }
   DeletePendingOrderByTicket(SelectedTradeTicket(),Green); 
   
 }
 return(false); 
 }
//SuspendPendingOrdersOnHighSpread <<==--------   --------
 void CalculateStrategyLotSize( double RequestedStopLossPips,int LotPercentMultiplier)
 {
  double    PreviousLotSize;
  double    CalculatedLotSize;
  double    NormalizedStopLossPips;
  double    RiskSettingValue;
  double    WeightedRiskCapital;
  double    FixedRiskCapital;
  double    AccountBalanceUsd;
//----------------------------------------------------------------------

 PreviousLotSize = LotSizeByStrategy[CurrentStrategyIndex] ;
 CalculatedLotSize = LotSizeByStrategy[CurrentStrategyIndex] ;
 CurrentBalanceBasis = AccountInfoDouble(ACCOUNT_BALANCE) ;
 if ( UseEquity )
 {
   CurrentBalanceBasis = AccountInfoDouble(ACCOUNT_EQUITY) ;
 }
 if ( ManualBalance>0.0 )
 {
   CurrentBalanceBasis = ManualBalance ;
 }
 if ( OnlyUp && HighestBalanceBasis>CurrentBalanceBasis )
 {
   CurrentBalanceBasis = HighestBalanceBasis ;
 }
 if ( CurrentBalanceBasis>HighestBalanceBasis )
 {
   HighestBalanceBasis = CurrentBalanceBasis ;
   if ( OnlyUp )   GlobalVariableSet(OnlyUpPeakGVName(),HighestBalanceBasis) ;
 }
 NormalizedStopLossPips = RequestedStopLossPips ;
 if ( ( SymbolDigits == 2 || SymbolDigits == 4 ) )
 {
   NormalizedStopLossPips = RequestedStopLossPips / 10.0 ;
 }
 if ( Risk <  999 && Risk >  0 )
 {
   RiskSettingValue = Risk ;
   WeightedRiskCapital = RiskSettingValue / 1000.0 * CurrentBalanceBasis ;
   if ( SymbolInfoDouble(CurrentSymbol,SYMBOL_VOLUME_STEP)==0.1 )
   {
     CalculatedLotSize = NormalizeDouble(LotPercentMultiplier * 0.01 * (WeightedRiskCapital / (SymbolInfoDouble(CurrentSymbol,SYMBOL_TRADE_TICK_VALUE) * NormalizedStopLossPips) * 0.1),1) ;
   }
   if ( SymbolInfoDouble(CurrentSymbol,SYMBOL_VOLUME_STEP)==0.01 )
   {
     CalculatedLotSize = NormalizeDouble(LotPercentMultiplier * 0.01 * (WeightedRiskCapital / (SymbolInfoDouble(CurrentSymbol,SYMBOL_TRADE_TICK_VALUE) * NormalizedStopLossPips) * 0.1),2) ;
   }
 }
 if ( Risk == 999 )
 {
   FixedRiskCapital = FixedRiskPercent / 100.0 * CurrentBalanceBasis ;
   if ( SymbolInfoDouble(CurrentSymbol,SYMBOL_VOLUME_STEP)==0.1 )
   {
     CalculatedLotSize = NormalizeDouble(LotPercentMultiplier * 0.01 * (FixedRiskCapital / (SymbolInfoDouble(CurrentSymbol,SYMBOL_TRADE_TICK_VALUE) * NormalizedStopLossPips) * 0.1),1) ;
   }
   if ( SymbolInfoDouble(CurrentSymbol,SYMBOL_VOLUME_STEP)==0.01 )
   {
     CalculatedLotSize = NormalizeDouble(LotPercentMultiplier * 0.01 * (FixedRiskCapital / (SymbolInfoDouble(CurrentSymbol,SYMBOL_TRADE_TICK_VALUE) * NormalizedStopLossPips) * 0.1),2) ;
   }
 }
 if ( Risk == 0 )
 {
   if ( SymbolInfoDouble(CurrentSymbol,SYMBOL_VOLUME_STEP)==0.1 )
   {
     CalculatedLotSize = NormalizeDouble(LotPercentMultiplier * 0.01 * StartLots_rw,1) ;
   }
   if ( SymbolInfoDouble(CurrentSymbol,SYMBOL_VOLUME_STEP)==0.01 )
   {
     CalculatedLotSize = NormalizeDouble(LotPercentMultiplier * 0.01 * StartLots_rw,2) ;
   }
 }
 if ( Risk == 9999 )
 {
   if ( SymbolInfoDouble(CurrentSymbol,SYMBOL_VOLUME_STEP)==0.1 )
   {
     CalculatedLotSize = NormalizeDouble(LotPercentMultiplier * 0.01 * (CurrentBalanceBasis / LotSizingBalanceDivisor * 0.01),1) ;
   }
   if ( SymbolInfoDouble(CurrentSymbol,SYMBOL_VOLUME_STEP)==0.01 )
   {
     CalculatedLotSize = NormalizeDouble(LotPercentMultiplier * 0.01 * (CurrentBalanceBasis / LotSizingBalanceDivisor * 0.01),2) ;
   }
 }
 if ( Risk == 1234 )
 {
   if ( UseWeightedLots )
   {
     if ( StrategyDrawdownReferenceUsd==0.0 )
     {
       StrategyDrawdownReferenceUsd = 100000.0 ;
     }
     WeightedRiskPercentPerStrategy = MaxAllowedDD / EnabledStrategyRiskWeight ;
     if ( SymbolInfoDouble(CurrentSymbol,SYMBOL_VOLUME_STEP)==0.1 )
     {
       CalculatedLotSize = NormalizeDouble(WeightedRiskPercentPerStrategy / StrategyDrawdownReferenceUsd * CurrentBalanceBasis / 100.0 * 0.01,1) ;
     }
     if ( SymbolInfoDouble(CurrentSymbol,SYMBOL_VOLUME_STEP)==0.01 )
     {
       CalculatedLotSize = NormalizeDouble(WeightedRiskPercentPerStrategy / StrategyDrawdownReferenceUsd * CurrentBalanceBasis / 100.0 * 0.01,2) ;
     }
   }
   else
   {
     if ( StrategyDrawdownReferenceUsd==0.0 )
     {
       StrategyDrawdownReferenceUsd = 100000.0 ;
     }
     AccountBalanceUsd = ConvertAccountCurrencyToUsdRounded(CurrentBalanceBasis) ;
     if ( ActiveTradeFrequency == 0 )
     {
       LotSizingBalanceDivisor = (int)(AutoFrequencyThreshold1 / (MaxAllowedDD / 100.0)) ;
     }
     if ( ActiveTradeFrequency == 1 )
     {
       LotSizingBalanceDivisor = (int)(AutoFrequencyThreshold2 / (MaxAllowedDD / 100.0)) ;
     }
     if ( ActiveTradeFrequency == 2 )
     {
       LotSizingBalanceDivisor = (int)(AutoFrequencyThreshold3 / (MaxAllowedDD / 100.0)) ;
     }
     if ( ActiveTradeFrequency == 3 )
     {
       LotSizingBalanceDivisor = (int)(AutoFrequencyThreshold4 / (MaxAllowedDD / 100.0)) ;
     }
     if ( ActiveTradeFrequency == 4 )
     {
       LotSizingBalanceDivisor = (int)(AutoFrequencyThreshold5 / (MaxAllowedDD / 100.0)) ;
     }
     if ( SymbolInfoDouble(CurrentSymbol,SYMBOL_VOLUME_STEP)==0.1 )
     {
       CalculatedLotSize = NormalizeDouble(LotPercentMultiplier * 0.01 * (AccountBalanceUsd / LotSizingBalanceDivisor * 0.01),1) ;
     }
     if ( SymbolInfoDouble(CurrentSymbol,SYMBOL_VOLUME_STEP)==0.01 )
     {
       CalculatedLotSize = NormalizeDouble(LotPercentMultiplier * 0.01 * (AccountBalanceUsd / LotSizingBalanceDivisor * 0.01),2) ;
     }
   }
 }
 if ( Risk == 3 )
 {
   if ( SymbolInfoDouble(CurrentSymbol,SYMBOL_VOLUME_STEP)==0.1 )
   {
     CalculatedLotSize = NormalizeDouble(MaxRiskPerStrategy_ / StrategyDrawdownReferenceUsd * CurrentBalanceBasis / 100.0 * 0.01,1) ;
   }
   if ( SymbolInfoDouble(CurrentSymbol,SYMBOL_VOLUME_STEP)==0.01 )
   {
     CalculatedLotSize = NormalizeDouble(MaxRiskPerStrategy_ / StrategyDrawdownReferenceUsd * CurrentBalanceBasis / 100.0 * 0.01,2) ;
   }
 }
 CalculatedLotSize = CalculatedLotSize * VariableLotInverseScaleFactor ;
 if ( CalculatedLotSize<SymbolInfoDouble(CurrentSymbol,SYMBOL_VOLUME_STEP) )
 {
   CalculatedLotSize = SymbolInfoDouble(CurrentSymbol,SYMBOL_VOLUME_STEP) ;
 }
 if ( CalculatedLotSize>MaxCalculatedLotSize )
 {
   CalculatedLotSize = MaxCalculatedLotSize ;
 }
 if ( CalculatedLotSize<SymbolInfoDouble(CurrentSymbol,SYMBOL_VOLUME_MIN) )
 {
   CalculatedLotSize = SymbolInfoDouble(CurrentSymbol,SYMBOL_VOLUME_MIN) ;
 }
 if ( CalculatedLotSize>SymbolInfoDouble(CurrentSymbol,SYMBOL_VOLUME_MAX) && SymbolInfoDouble(CurrentSymbol,SYMBOL_VOLUME_MAX)!=0.0 )
 {
   CalculatedLotSize = SymbolInfoDouble(CurrentSymbol,SYMBOL_VOLUME_MAX) ;
 }
 if ( SymbolInfoDouble(CurrentSymbol,SYMBOL_VOLUME_STEP)==0.1 )
 {
   LotSizeByStrategy[CurrentStrategyIndex] = NormalizeDouble((MathFloor(CalculatedLotSize * 10.0)) / 10.0,1);
   return;
 }
 LotSizeByStrategy[CurrentStrategyIndex] = NormalizeDouble(MathFloor(CalculatedLotSize * 100.0) / 100.0,2);
 }
//CalculateStrategyLotSize <<==--------   --------
 double CalculateBuyEntryPrice( int TimeframeMinutes)
 {
  bool      SignalFound = false;
  bool      LeftSideConfirmed = false;
  bool      RightSideConfirmed;
  int       CandidateBarShift;
  int       RightCheckShift;
  int       LeftCheckShift;
//----------------------------------------------------------------------
 double     CandidateSwingPrice;
 int        CandidateMaximumShift;
 double     ExtremePriceSinceCurrentBar;
 int        ExtremeScanShift;
 double     NormalizedCandidatePrice;
 int        PendingOrderScanIndex;
 bool       DuplicatePendingFound;

 RightSideConfirmed = false ;
 CandidateBarShift=SwingRightBars + 1;
 do
 {
   LeftSideConfirmed = true ;
   RightSideConfirmed = true ;
   for (RightCheckShift = CandidateBarShift ; RightCheckShift >= CandidateBarShift - SwingRightBars ; RightCheckShift --)
   {
     if ( iHigh(CurrentSymbol,NormalizeTimeframe(TimeframeMinutes),RightCheckShift)>iHigh(CurrentSymbol,NormalizeTimeframe(TimeframeMinutes),CandidateBarShift) )
     {
       RightSideConfirmed = false ;
     }
   }
   for (LeftCheckShift = CandidateBarShift ; LeftCheckShift <= CandidateBarShift + SwingLeftBars ; LeftCheckShift ++)
   {
     if ( iHigh(CurrentSymbol,NormalizeTimeframe(TimeframeMinutes),LeftCheckShift)>iHigh(CurrentSymbol,NormalizeTimeframe(TimeframeMinutes),CandidateBarShift) )
     {
       LeftSideConfirmed = false ;
     }
   }
   if ( RightSideConfirmed && LeftSideConfirmed && iHigh(CurrentSymbol,NormalizeTimeframe(TimeframeMinutes),CandidateBarShift)>MinEntryDistancePips * PipSize + SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK) )
   {
     CandidateSwingPrice = iHigh(CurrentSymbol,NormalizeTimeframe(TimeframeMinutes),CandidateBarShift);
     CandidateMaximumShift = CandidateBarShift;
     ExtremePriceSinceCurrentBar = iHigh(CurrentSymbol,NormalizeTimeframe(SignalTimeframeMinutes),0);
     for (ExtremeScanShift = 1 ; ExtremeScanShift <= CandidateMaximumShift ; ExtremeScanShift=ExtremeScanShift + 1)
     {
       if ( iHigh(CurrentSymbol,NormalizeTimeframe(SignalTimeframeMinutes),ExtremeScanShift)>ExtremePriceSinceCurrentBar )
       {
         ExtremePriceSinceCurrentBar = iHigh(CurrentSymbol,NormalizeTimeframe(SignalTimeframeMinutes),ExtremeScanShift);
       }
     }
     if ( CandidateSwingPrice>=ExtremePriceSinceCurrentBar )
     {
       NormalizedCandidatePrice = NormalizeDouble(iHigh(CurrentSymbol,NormalizeTimeframe(TimeframeMinutes),CandidateBarShift),SymbolDigits);
       DuplicatePendingFound=false; 
       for (PendingOrderScanIndex = ActiveTradeCount() ; PendingOrderScanIndex >= 0 ; PendingOrderScanIndex=PendingOrderScanIndex - 1)
       {
         if ( SelectTradeRecord(PendingOrderScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != StrategyMagicNumber || SelectedTradeSymbol() != CurrentSymbol || SelectedTradeType() != ORDER_TYPE_BUY_STOP || !(MathAbs(SelectedTradeOpenPrice() - (BuyEntryOffsetPips * PipSize + NormalizedCandidatePrice))<DuplicatePendingTolerancePips * PipSize) )   continue;
         DuplicatePendingFound = true;
          break;
         
       }
       if ( !(DuplicatePendingFound) && ( !(FakeoutConfirmationEnabled) || !(iClose(CurrentSymbol,NormalizeTimeframe(TimeframeMinutes),CandidateBarShift - 1)>iHigh(CurrentSymbol,NormalizeTimeframe(TimeframeMinutes),CandidateBarShift) - MinEntryDistancePips * PipSize) ) )
       {
         SignalFound = true ;
         CurrentBuyEntryPrice = NormalizeDouble(iHigh(CurrentSymbol,NormalizeTimeframe(TimeframeMinutes),CandidateBarShift),SymbolDigits) ;
         BuySignalBarShift = CandidateBarShift ;
         break;
       }
     }
   }
   CandidateBarShift ++;
   if ( CandidateBarShift <= EntryLookbackBars )   continue;
   CurrentBuyEntryPrice = 0.0 ;
   break;
   
 }
 while(!(SignalFound));
 
 return(CurrentBuyEntryPrice); 
 }
//CalculateBuyEntryPrice <<==--------   --------
 double CalculateSellEntryPrice( int TimeframeMinutes)
 {
  bool      SignalFound = false;
  bool      LeftSideConfirmed = false;
  bool      RightSideConfirmed;
  int       CandidateBarShift;
  int       RightCheckShift;
  int       LeftCheckShift;
//----------------------------------------------------------------------
 double     CandidateSwingPrice;
 int        CandidateMaximumShift;
 double     ExtremePriceSinceCurrentBar;
 int        ExtremeScanShift;
 double     NormalizedCandidatePrice;
 int        PendingOrderScanIndex;
 bool       DuplicatePendingFound;

 RightSideConfirmed = false ;
 CandidateBarShift=SwingRightBars + 1;
 do
 {
   LeftSideConfirmed = true ;
   RightSideConfirmed = true ;
   for (RightCheckShift = CandidateBarShift ; RightCheckShift >= CandidateBarShift - SwingRightBars ; RightCheckShift --)
   {
     if ( iLow(CurrentSymbol,NormalizeTimeframe(TimeframeMinutes),RightCheckShift)<iLow(CurrentSymbol,NormalizeTimeframe(TimeframeMinutes),CandidateBarShift) )
     {
       RightSideConfirmed = false ;
     }
   }
   for (LeftCheckShift = CandidateBarShift ; LeftCheckShift <= CandidateBarShift + SwingLeftBars ; LeftCheckShift ++)
   {
     if ( iLow(CurrentSymbol,NormalizeTimeframe(TimeframeMinutes),LeftCheckShift)<iLow(CurrentSymbol,NormalizeTimeframe(TimeframeMinutes),CandidateBarShift) )
     {
       LeftSideConfirmed = false ;
     }
   }
   if ( RightSideConfirmed && LeftSideConfirmed && iLow(CurrentSymbol,NormalizeTimeframe(TimeframeMinutes),CandidateBarShift)<SymbolInfoDouble(CurrentSymbol,SYMBOL_BID) - MinEntryDistancePips * PipSize )
   {
     CandidateSwingPrice = iLow(CurrentSymbol,NormalizeTimeframe(TimeframeMinutes),CandidateBarShift);
     CandidateMaximumShift = CandidateBarShift;
     ExtremePriceSinceCurrentBar = iLow(CurrentSymbol,NormalizeTimeframe(SignalTimeframeMinutes),0);
     for (ExtremeScanShift = 1 ; ExtremeScanShift <= CandidateMaximumShift ; ExtremeScanShift=ExtremeScanShift + 1)
     {
       if ( iLow(CurrentSymbol,NormalizeTimeframe(SignalTimeframeMinutes),ExtremeScanShift)<ExtremePriceSinceCurrentBar )
       {
         ExtremePriceSinceCurrentBar = iLow(CurrentSymbol,NormalizeTimeframe(SignalTimeframeMinutes),ExtremeScanShift);
       }
     }
     if ( CandidateSwingPrice<=ExtremePriceSinceCurrentBar )
     {
       NormalizedCandidatePrice = NormalizeDouble(iLow(CurrentSymbol,NormalizeTimeframe(TimeframeMinutes),CandidateBarShift),SymbolDigits);
       DuplicatePendingFound=false; 
       for (PendingOrderScanIndex = ActiveTradeCount() ; PendingOrderScanIndex >= 0 ; PendingOrderScanIndex=PendingOrderScanIndex - 1)
       {
         if ( SelectTradeRecord(PendingOrderScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != StrategyMagicNumber || SelectedTradeSymbol() != CurrentSymbol || SelectedTradeType() != ORDER_TYPE_SELL_STOP || !(MathAbs(SelectedTradeOpenPrice() - (NormalizedCandidatePrice - SellEntryOffsetPips * PipSize))<DuplicatePendingTolerancePips * PipSize) )   continue;
         DuplicatePendingFound = true;
          break;
         
       }
       if ( !(DuplicatePendingFound) && ( !(FakeoutConfirmationEnabled) || !(iClose(CurrentSymbol,NormalizeTimeframe(TimeframeMinutes),CandidateBarShift - 1)<MinEntryDistancePips * PipSize + iLow(CurrentSymbol,NormalizeTimeframe(TimeframeMinutes),CandidateBarShift)) ) )
       {
         SignalFound = true ;
         CurrentSellEntryPrice = NormalizeDouble(iLow(CurrentSymbol,NormalizeTimeframe(TimeframeMinutes),CandidateBarShift),SymbolDigits) ;
         SellSignalBarShift = CandidateBarShift ;
         break;
       }
     }
   }
   CandidateBarShift ++;
   if ( CandidateBarShift <= EntryLookbackBars )   continue;
   CurrentSellEntryPrice = 0.0 ;
   break;
   
 }
 while(!(SignalFound));
 
 return(CurrentSellEntryPrice); 
 }
//CalculateSellEntryPrice <<==--------   --------
 double FindQualifiedSwingHigh( int TimeframeMinutes,int LeftBars,int RightBars)
 {
  bool      SwingFound = false;
  double    QualifiedSwingPrice = 0.0;
  bool      LeftSideConfirmed = false;
  bool      RightSideConfirmed;
  int       CandidateBarShift;
  int       RightCheckShift;
  int       LeftCheckShift;
//----------------------------------------------------------------------

 RightSideConfirmed = false ;
 CandidateBarShift=RightBars + 1;
 do
 {
   LeftSideConfirmed = true ;
   RightSideConfirmed = true ;
   for (RightCheckShift = CandidateBarShift ; RightCheckShift >= CandidateBarShift - RightBars ; RightCheckShift --)
   {
     if ( iHigh(CurrentSymbol,NormalizeTimeframe(TimeframeMinutes),RightCheckShift)>iHigh(CurrentSymbol,NormalizeTimeframe(TimeframeMinutes),CandidateBarShift) )
     {
       RightSideConfirmed = false ;
     }
   }
   for (LeftCheckShift = CandidateBarShift ; LeftCheckShift <= CandidateBarShift + LeftBars ; LeftCheckShift ++)
   {
     if ( iHigh(CurrentSymbol,NormalizeTimeframe(TimeframeMinutes),LeftCheckShift)>iHigh(CurrentSymbol,NormalizeTimeframe(TimeframeMinutes),CandidateBarShift) )
     {
       LeftSideConfirmed = false ;
     }
   }
   if ( RightSideConfirmed && LeftSideConfirmed && iHigh(CurrentSymbol,NormalizeTimeframe(TimeframeMinutes),CandidateBarShift)>StopLevelPriceDistance * PipSize + SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK) )
   {
     SwingFound = true ;
     QualifiedSwingPrice = NormalizeDouble(iHigh(CurrentSymbol,NormalizeTimeframe(TimeframeMinutes),CandidateBarShift),SymbolDigits) ;
     break;
   }
   CandidateBarShift ++;
   if ( CandidateBarShift <= SwingQualificationMinimumShift )   continue;
   QualifiedSwingPrice = 9999.0 ;
   break;
   
 }
 while(!(SwingFound));
 
 return(QualifiedSwingPrice); 
 }
//FindQualifiedSwingHigh <<==--------   --------
 double FindQualifiedSwingLow( int TimeframeMinutes,int LeftBars,int RightBars)
 {
  bool      SwingFound = false;
  double    QualifiedSwingPrice = 0.0;
  bool      LeftSideConfirmed = false;
  bool      RightSideConfirmed;
  int       CandidateBarShift;
  int       RightCheckShift;
  int       LeftCheckShift;
//----------------------------------------------------------------------

 RightSideConfirmed = false ;
 CandidateBarShift=RightBars + 1;
 do
 {
   LeftSideConfirmed = true ;
   RightSideConfirmed = true ;
   for (RightCheckShift = CandidateBarShift ; RightCheckShift >= CandidateBarShift - RightBars ; RightCheckShift --)
   {
     if ( iLow(CurrentSymbol,NormalizeTimeframe(TimeframeMinutes),RightCheckShift)<iLow(CurrentSymbol,NormalizeTimeframe(TimeframeMinutes),CandidateBarShift) )
     {
       RightSideConfirmed = false ;
     }
   }
   for (LeftCheckShift = CandidateBarShift ; LeftCheckShift <= CandidateBarShift + LeftBars ; LeftCheckShift ++)
   {
     if ( iLow(CurrentSymbol,NormalizeTimeframe(TimeframeMinutes),LeftCheckShift)<iLow(CurrentSymbol,NormalizeTimeframe(TimeframeMinutes),CandidateBarShift) )
     {
       LeftSideConfirmed = false ;
     }
   }
   if ( RightSideConfirmed && LeftSideConfirmed && iLow(CurrentSymbol,NormalizeTimeframe(TimeframeMinutes),CandidateBarShift)<SymbolInfoDouble(CurrentSymbol,SYMBOL_BID) - StopLevelPriceDistance * PipSize )
   {
     SwingFound = true ;
     QualifiedSwingPrice = NormalizeDouble(iLow(CurrentSymbol,NormalizeTimeframe(TimeframeMinutes),CandidateBarShift),SymbolDigits) ;
     break;
   }
   CandidateBarShift ++;
   if ( CandidateBarShift <= SwingQualificationMinimumShift )   continue;
   QualifiedSwingPrice = 0.0 ;
   break;
   
 }
 while(!(SwingFound));
 
 return(QualifiedSwingPrice); 
 }
//FindQualifiedSwingLow <<==--------   --------
 void ManagePendingEntries()
 {
  int       PendingExpirationScanIndex;
//----------------------------------------------------------------------
 long       CurrentTime;
 long       VirtualExpirationTime;
 int        OpenBuyCount;
 int        OpenBuyScanIndex;
 int        BuyDeleteMode;
 int        BuyPendingDeleteIndex;
 int        ManualBuyPendingDeleteIndex;
 int        OpenSellCount;
 int        OpenSellScanIndex;
 int        SellDeleteMode;
 int        SellPendingDeleteIndex;
 int        ManualSellPendingDeleteIndex;

 if ( MovingAverageTrendFilterEnabled )
 {
   FastMovingAverageValue = GetMovingAverageValue(CurrentSymbol,0,FastMovingAveragePeriod,0,1,0,1) ;
   SlowMovingAverageValue = GetMovingAverageValue(CurrentSymbol,0,SlowMovingAveragePeriod,0,1,0,1) ;
 }
 CalculateStrategyLotSize(StopLossPips,LotSizePercentMultiplier); 
 if ( LotSizeByStrategy[CurrentStrategyIndex]>MaxCalculatedLotSize )
 {
   LotSizeByStrategy[CurrentStrategyIndex] = MaxCalculatedLotSize;
 }
 if ( PendingExpirationHours >  0 )
 {
   PendingOrderExpirationTime=TimeCurrent() + PendingExpirationSeconds;
 }
 if ( Virtual_expiration )
 {
   PendingOrderExpirationTime = 0 ;
   for (PendingExpirationScanIndex = ActiveTradeCount() ; PendingExpirationScanIndex >= 0 ; PendingExpirationScanIndex --)
   {
     if ( SelectTradeRecord(PendingExpirationScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != StrategyMagicNumber || SelectedTradeSymbol() != CurrentSymbol )   continue;
     
     if ( ( SelectedTradeType() != ORDER_TYPE_BUY_STOP && SelectedTradeType() != ORDER_TYPE_SELL_STOP ) )   continue;
     CurrentTime = TimeCurrent();
     VirtualExpirationTime=SelectedTradeOpenTime() + PendingExpirationSeconds;
     if ( CurrentTime < VirtualExpirationTime )   continue;
     DeletePendingOrderByTicket(SelectedTradeTicket(),Red); 
     
   }
 }
 OpenBuyCount = 0;
 for (OpenBuyScanIndex = ActiveTradeCount() ; OpenBuyScanIndex >= 0 ; OpenBuyScanIndex=OpenBuyScanIndex - 1)
 {
   if ( SelectTradeRecord(OpenBuyScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != StrategyMagicNumber || SelectedTradeSymbol() != CurrentSymbol || SelectedTradeType() != ORDER_TYPE_BUY )   continue;
   OpenBuyCount=OpenBuyCount + 1;
   
 }
 if ( OpenBuyCount <  MaxOpenTradesPerSide )
 {
   PlaceBuyStopOrder(1); 
 }
 else
 {
   BuyDeleteMode = 1;
   for (BuyPendingDeleteIndex = ActiveTradeCount() ; BuyPendingDeleteIndex >= 0 ; BuyPendingDeleteIndex=BuyPendingDeleteIndex - 1)
   {
     if ( SelectTradeRecord(BuyPendingDeleteIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != StrategyMagicNumber || SelectedTradeSymbol() != CurrentSymbol || SelectedTradeType() != ORDER_TYPE_BUY_STOP )   continue;
     DeletePendingOrderByTicket(SelectedTradeTicket(),clrNONE); 
     
   }
   if ( BuyDeleteMode == 2 )
   {
     for (ManualBuyPendingDeleteIndex = ActiveTradeCount() ; ManualBuyPendingDeleteIndex >= 0 ; ManualBuyPendingDeleteIndex=ManualBuyPendingDeleteIndex - 1)
     {
       if ( SelectTradeRecord(ManualBuyPendingDeleteIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != ManualStrategy2MagicNumber || SelectedTradeSymbol() != CurrentSymbol || SelectedTradeType() != ORDER_TYPE_BUY_STOP )   continue;
       DeletePendingOrderByTicket(SelectedTradeTicket(),clrNONE); 
       
     }
   }
 }
 OpenSellCount = 0;
 for (OpenSellScanIndex = ActiveTradeCount() ; OpenSellScanIndex >= 0 ; OpenSellScanIndex=OpenSellScanIndex - 1)
 {
   if ( SelectTradeRecord(OpenSellScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != StrategyMagicNumber || SelectedTradeSymbol() != CurrentSymbol || SelectedTradeType() != ORDER_TYPE_SELL )   continue;
   OpenSellCount=OpenSellCount + 1;
   
 }
 if ( OpenSellCount <  MaxOpenTradesPerSide )
 {
   PlaceSellStopOrder(1); 
   return;
 }
 SellDeleteMode = 1;
 for (SellPendingDeleteIndex = ActiveTradeCount() ; SellPendingDeleteIndex >= 0 ; SellPendingDeleteIndex=SellPendingDeleteIndex - 1)
 {
   if ( SelectTradeRecord(SellPendingDeleteIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != StrategyMagicNumber || SelectedTradeSymbol() != CurrentSymbol || SelectedTradeType() != ORDER_TYPE_SELL_STOP )   continue;
   DeletePendingOrderByTicket(SelectedTradeTicket(),clrNONE); 
   
 }
 if ( SellDeleteMode != 2 )   return;
 for (ManualSellPendingDeleteIndex = ActiveTradeCount() ; ManualSellPendingDeleteIndex >= 0 ; ManualSellPendingDeleteIndex=ManualSellPendingDeleteIndex - 1)
 {
   if ( SelectTradeRecord(ManualSellPendingDeleteIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != ManualStrategy2MagicNumber || SelectedTradeSymbol() != CurrentSymbol || SelectedTradeType() != ORDER_TYPE_SELL_STOP )   continue;
   DeletePendingOrderByTicket(SelectedTradeTicket(),clrNONE); 
   
 }
 }
//ManagePendingEntries <<==--------   --------
 bool PlaceBuyStopOrder( int EntryRequestMode)
 {
  bool      NewSignalAvailable;
  double    PendingBasePrice;
  double    PendingOrderPrice;
  double    StopLossPrice;
  double    TakeProfitPrice;
//----------------------------------------------------------------------
 bool       SameSideMarketTradeExists;
 int        MarketTradeScanIndex;
 double     SignalPrice;
 int        DuplicateScanIndex;
 bool       DuplicatePendingFound;
 int        PendingOrderCount;
 int        PendingCountScanIndex;
 double     BoundaryPendingPrice;
 int        BoundaryScanIndex;
 double     CandidatePendingPrice;
 int        BlockingOrderScanIndex;
 bool       MoreExtremePendingExists;
 bool       VolumeValid;
 int        AccountOrderLimit;
 bool       OrderLimitAvailable;
 int        SendErrorCode;
 double     RequestedEntryPrice;
 long       SubmittedPendingTicket;
 int        TicketMapInsertIndex;

 if ( !(AllowBuyTrades) )
 {
   return(false); 
 }
 if ( AllowMultipleOpenTradesPerSide )
 {
   SameSideMarketTradeExists = false;
 }
 else
 {
   SameSideMarketTradeExists=false; 
   for (MarketTradeScanIndex = 0 ; MarketTradeScanIndex < ActiveTradeCount() ; MarketTradeScanIndex=MarketTradeScanIndex + 1)
   {
     if ( SelectTradeRecord(MarketTradeScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeType() != ORDER_TYPE_BUY || SelectedTradeMagic() != StrategyMagicNumber || SelectedTradeSymbol() != CurrentSymbol )   continue;
     SameSideMarketTradeExists = true;
      break;
     
   }
 }
 if ( SameSideMarketTradeExists == true )
 {
   return(false); 
 }
 if ( MovingAverageTrendFilterEnabled && FastMovingAverageValue<SlowMovingAverageValue )
 {
   return(false); 
 }
 if ( EntryRequestMode == 1 )
 {
   CalculateBuyEntryPrice(SignalTimeframeMinutes); 
   NewSignalAvailable = false ;
   SignalPrice = CurrentBuyEntryPrice;
   DuplicatePendingFound=false; 
   for (DuplicateScanIndex = ActiveTradeCount() ; DuplicateScanIndex >= 0 ; DuplicateScanIndex=DuplicateScanIndex - 1)
   {
     if ( SelectTradeRecord(DuplicateScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != StrategyMagicNumber || SelectedTradeSymbol() != CurrentSymbol || SelectedTradeType() != ORDER_TYPE_BUY_STOP || !(MathAbs(SelectedTradeOpenPrice() - (BuyEntryOffsetPips * PipSize + SignalPrice))<DuplicatePendingTolerancePips * PipSize) )   continue;
     DuplicatePendingFound = true;
      break;
     
   }
   if ( !(DuplicatePendingFound) )
   {
     PendingOrderCount = 0;
     for (PendingCountScanIndex = ActiveTradeCount() ; PendingCountScanIndex >= 0 ; PendingCountScanIndex=PendingCountScanIndex - 1)
     {
       if ( SelectTradeRecord(PendingCountScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != StrategyMagicNumber || SelectedTradeSymbol() != CurrentSymbol || SelectedTradeType() != ORDER_TYPE_BUY_STOP )   continue;
       PendingOrderCount=PendingOrderCount + 1;
       
     }
     if ( PendingOrderCount == MaxPendingOrders )
     {
       BoundaryPendingPrice = 9999.0;
       for (BoundaryScanIndex = ActiveTradeCount() ; BoundaryScanIndex >= 0 ; BoundaryScanIndex=BoundaryScanIndex - 1)
       {
         if ( SelectTradeRecord(BoundaryScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != StrategyMagicNumber || SelectedTradeSymbol() != CurrentSymbol || SelectedTradeType() != ORDER_TYPE_BUY_STOP || !(SelectedTradeOpenPrice()<BoundaryPendingPrice) )   continue;
         BoundaryPendingPrice = SelectedTradeOpenPrice();
         
       }
       if ( CurrentBuyEntryPrice>BoundaryPendingPrice )
       {
         return(false); 
       }
     }
     LastBuySignalCandidatePrice = CurrentBuyEntryPrice ;
     NewSignalAvailable = true ;
     CachedBuySignalPrice = NormalizeDouble(CurrentBuyEntryPrice,SymbolDigits) ;
   }
   if ( CachedBuySignalPrice==0.0 )
   {
     return(false); 
   }
   if ( NewSignalAvailable )
   {
     ActiveMagicTrailActivationPips = MagicTrailActivationDistancePips ;
     PendingBasePrice = NormalizeDouble(BuyEntryOffsetPips * PipSize + CachedBuySignalPrice,SymbolDigits) ;
     CandidatePendingPrice = PendingBasePrice;
     MoreExtremePendingExists=false; 
     for (BlockingOrderScanIndex = ActiveTradeCount() ; BlockingOrderScanIndex >= 0 ; BlockingOrderScanIndex=BlockingOrderScanIndex - 1)
     {
       if ( SelectTradeRecord(BlockingOrderScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != StrategyMagicNumber || SelectedTradeSymbol() != CurrentSymbol || SelectedTradeType() != ORDER_TYPE_BUY_STOP || !(SelectedTradeOpenPrice()<=CandidatePendingPrice) )   continue;
       MoreExtremePendingExists = true;
        break;
       
     }
     if ( MoreExtremePendingExists )
     {
       return(false); 
     }
     LastBuyPendingBasePrice = PendingBasePrice ;
     if ( !(VirtualPendingOrdersEnabled) )
     {
       if ( CheckMargin && ProjectedFreeMarginAfterOrder(CurrentSymbol,ORDER_TYPE_BUY,LotSizeByStrategy[CurrentStrategyIndex])<=0.0 )
       {
         Print("Free margin not sufficient for setting order with lotsize " + string(LotSizeByStrategy[CurrentStrategyIndex]) + "..."); 
         return(false); 
       }
       PendingOrderPrice = NormalizeDouble(RandomizedPendingEntryOffsetPips * PipSize + PendingBasePrice,SymbolDigits) ;
       StopLossPrice = NormalizeDouble(PendingBasePrice - (StopLossPips + ExtraStopLossPips) * PipSize,SymbolDigits) ;
       TakeProfitPrice = NormalizeDouble(TakeProfitPips * PipSize + PendingBasePrice,SymbolDigits) ;
       if ( LotSizeByStrategy[CurrentStrategyIndex]<SymbolInfoDouble(CurrentSymbol,SYMBOL_VOLUME_MIN) )
       {
         Print("Volume is less than the minimal allowed SYMBOL_VOLUME_MIN=" + string(SymbolInfoDouble(CurrentSymbol,SYMBOL_VOLUME_MIN))); 
         VolumeValid = false;
       }
       else
       {
         if ( LotSizeByStrategy[CurrentStrategyIndex]>SymbolInfoDouble(CurrentSymbol,SYMBOL_VOLUME_MAX) )
         {
           Print("Volume is greater than the maximal allowed SYMBOL_VOLUME_MAX=" + string(SymbolInfoDouble(CurrentSymbol,SYMBOL_VOLUME_MAX))); 
           VolumeValid = false;
         }
         else
         {
           if ( MathAbs(NormalizeDouble(LotSizeByStrategy[CurrentStrategyIndex] / SymbolInfoDouble(CurrentSymbol,SYMBOL_VOLUME_STEP),0) * SymbolInfoDouble(CurrentSymbol,SYMBOL_VOLUME_STEP) - LotSizeByStrategy[CurrentStrategyIndex])>0.0000001 )
           {
             Print("Volume " + string(LotSizeByStrategy[CurrentStrategyIndex]) + " is not a multiple of the minimal step SYMBOL_VOLUME_STEP=" + string(SymbolInfoDouble(CurrentSymbol,SYMBOL_VOLUME_STEP))); 
             VolumeValid = false;
           }
           else
           {
             VolumeValid = true;
           }
         }
       }

       AccountOrderLimit = (int)AccountInfoInteger(ACCOUNT_LIMIT_ORDERS);
       if ( AccountOrderLimit == 0 )
       {
         OrderLimitAvailable = true;
       }
       else
       {
         OrderLimitAvailable = ActiveTradeCount()<AccountOrderLimit;
       }
       if ( ( !(VolumeValid) || !(OrderLimitAvailable) ) )
       {
         return(false); 
       }
       if ( SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK)<PendingOrderPrice - FreezeLevelPriceDistance * PipSize && SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK)<PendingOrderPrice - StopLevelPriceDistance * PipSize )
       {
         if ( !(setSL_TP_After_Entry) )
         {
           LastTradeTicket = SendTradeOrder(CurrentSymbol,ORDER_TYPE_BUY_STOP,LotSizeByStrategy[CurrentStrategyIndex],PendingOrderPrice,int(OrderSlippageSetting * PipSize),StopLossPrice,TakeProfitPrice,CurrentStrategyComment,StrategyMagicNumber,PendingOrderExpirationTime,Green) ;
         }
         else
         {
           LastTradeTicket = SendTradeOrder(CurrentSymbol,ORDER_TYPE_BUY_STOP,LotSizeByStrategy[CurrentStrategyIndex],PendingOrderPrice,int(OrderSlippageSetting * PipSize),0.0,0.0,CurrentStrategyComment,StrategyMagicNumber,PendingOrderExpirationTime,Green) ;
         }
         BuyPendingRestoreState = false ;
         if ( LastTradeTicket <= 0 )
         {
           SendErrorCode = LastTradeErrorCode();
           if ( SendErrorCode == 132 )
           {
             ResetLastError();
             if(1==0) // Điều kiện luôn sai; giữ nguyên nhánh vô hiệu từ mã gốc.
             {
               do
               {
                 Sleep(2500); 
                 if ( !(setSL_TP_After_Entry) )
                 {
                   SendErrorCode = (int)(OrderSlippageSetting * PipSize);
                   LastTradeTicket = SendTradeOrder(CurrentSymbol,ORDER_TYPE_BUY_STOP,LotSizeByStrategy[CurrentStrategyIndex],PendingOrderPrice,SendErrorCode,StopLossPrice,TakeProfitPrice,CurrentStrategyComment,StrategyMagicNumber,PendingOrderExpirationTime,Green) ;
                 }
                 else
                 {
                   LastTradeTicket = SendTradeOrder(CurrentSymbol,ORDER_TYPE_BUY_STOP,LotSizeByStrategy[CurrentStrategyIndex],PendingOrderPrice,int(OrderSlippageSetting * PipSize),0.0,0.0,CurrentStrategyComment,StrategyMagicNumber,PendingOrderExpirationTime,Green) ;
                 }
                 BuyPendingRestoreState = false ;
               }
               while(LastTradeErrorCode() == STRATEGY_ERROR_MARKET_CLOSED);
               
             }
           }
           Print("error: \'" + TradeErrorDescription(LastTradeErrorCode()) + "\' when setting entry order"); 
         }
         else
         {
           RequestedEntryPrice = PendingBasePrice;
           SubmittedPendingTicket = LastTradeTicket;
           for (TicketMapInsertIndex = 0 ; TicketMapInsertIndex < 100 ; TicketMapInsertIndex=TicketMapInsertIndex + 1)
           {
             if ( !(PendingTicketPriceMap[TicketMapInsertIndex][0]==0.0) )   continue;
             PendingTicketPriceMap[TicketMapInsertIndex][0] = (double)SubmittedPendingTicket;
             PendingTicketPriceMap[TicketMapInsertIndex][1] = RequestedEntryPrice;
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
 bool PlaceSellStopOrder( int EntryRequestMode)
 {
  bool      NewSignalAvailable;
  double    PendingBasePrice;
  double    PendingOrderPrice;
  double    StopLossPrice;
  double    TakeProfitPrice;
//----------------------------------------------------------------------
 bool       SameSideMarketTradeExists;
 int        MarketTradeScanIndex;
 double     SignalPrice;
 int        DuplicateScanIndex;
 bool       DuplicatePendingFound;
 int        PendingOrderCount;
 int        PendingCountScanIndex;
 double     BoundaryPendingPrice;
 int        BoundaryScanIndex;
 double     CandidatePendingPrice;
 int        BlockingOrderScanIndex;
 bool       MoreExtremePendingExists;
 bool       VolumeValid;
 int        AccountOrderLimit;
 bool       OrderLimitAvailable;
 int        SendErrorCode;
 double     RequestedEntryPrice;
 long       SubmittedPendingTicket;
 int        TicketMapInsertIndex;

 if ( !(AllowSellTrades) )
 {
   return(false); 
 }
 if ( AllowMultipleOpenTradesPerSide )
 {
   SameSideMarketTradeExists = false;
 }
 else
 {
   SameSideMarketTradeExists=false; 
   for (MarketTradeScanIndex = 0 ; MarketTradeScanIndex < ActiveTradeCount() ; MarketTradeScanIndex=MarketTradeScanIndex + 1)
   {
     if ( SelectTradeRecord(MarketTradeScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeType() != ORDER_TYPE_SELL || SelectedTradeMagic() != StrategyMagicNumber || SelectedTradeSymbol() != CurrentSymbol )   continue;
     SameSideMarketTradeExists = true;
      break;
     
   }
 }
 if ( SameSideMarketTradeExists == true )
 {
   return(false); 
 }
 if ( MovingAverageTrendFilterEnabled && FastMovingAverageValue>SlowMovingAverageValue )
 {
   return(false); 
 }
 if ( EntryRequestMode == 1 )
 {
   CalculateSellEntryPrice(SignalTimeframeMinutes); 
   NewSignalAvailable = false ;
   SignalPrice = CurrentSellEntryPrice;
   DuplicatePendingFound=false; 
   for (DuplicateScanIndex = ActiveTradeCount() ; DuplicateScanIndex >= 0 ; DuplicateScanIndex=DuplicateScanIndex - 1)
   {
     if ( SelectTradeRecord(DuplicateScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != StrategyMagicNumber || SelectedTradeSymbol() != CurrentSymbol || SelectedTradeType() != ORDER_TYPE_SELL_STOP || !(MathAbs(SelectedTradeOpenPrice() - (SignalPrice - SellEntryOffsetPips * PipSize))<DuplicatePendingTolerancePips * PipSize) )   continue;
     DuplicatePendingFound = true;
      break;
     
   }
   if ( !(DuplicatePendingFound) )
   {
     PendingOrderCount = 0;
     for (PendingCountScanIndex = ActiveTradeCount() ; PendingCountScanIndex >= 0 ; PendingCountScanIndex=PendingCountScanIndex - 1)
     {
       if ( SelectTradeRecord(PendingCountScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != StrategyMagicNumber || SelectedTradeSymbol() != CurrentSymbol || SelectedTradeType() != ORDER_TYPE_SELL_STOP )   continue;
       PendingOrderCount=PendingOrderCount + 1;
       
     }
     if ( PendingOrderCount == MaxPendingOrders )
     {
       BoundaryPendingPrice = 0.0;
       for (BoundaryScanIndex = ActiveTradeCount() ; BoundaryScanIndex >= 0 ; BoundaryScanIndex=BoundaryScanIndex - 1)
       {
         if ( SelectTradeRecord(BoundaryScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != StrategyMagicNumber || SelectedTradeSymbol() != CurrentSymbol || SelectedTradeType() != ORDER_TYPE_SELL_STOP || !(SelectedTradeOpenPrice()>BoundaryPendingPrice) )   continue;
         BoundaryPendingPrice = SelectedTradeOpenPrice();
         
       }
       if ( CurrentSellEntryPrice<BoundaryPendingPrice )
       {
         return(false); 
       }
     }
     LastSellSignalCandidatePrice = CurrentSellEntryPrice ;
     NewSignalAvailable = true ;
     CachedSellSignalPrice = NormalizeDouble(CurrentSellEntryPrice,SymbolDigits) ;
   }
   if ( CachedSellSignalPrice==0.0 )
   {
     return(false); 
   }
   if ( NewSignalAvailable )
   {
     ActiveMagicTrailActivationPips = MagicTrailActivationDistancePips ;
     PendingBasePrice = NormalizeDouble(CachedSellSignalPrice - SellEntryOffsetPips * PipSize,SymbolDigits) ;
     CandidatePendingPrice = PendingBasePrice;
     MoreExtremePendingExists=false; 
     for (BlockingOrderScanIndex = ActiveTradeCount() ; BlockingOrderScanIndex >= 0 ; BlockingOrderScanIndex=BlockingOrderScanIndex - 1)
     {
       if ( SelectTradeRecord(BlockingOrderScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != StrategyMagicNumber || SelectedTradeSymbol() != CurrentSymbol || SelectedTradeType() != ORDER_TYPE_SELL_STOP || !(SelectedTradeOpenPrice()>=CandidatePendingPrice) )   continue;
       MoreExtremePendingExists = true;
        break;
       
     }
     if ( MoreExtremePendingExists )
     {
       return(false); 
     }
     LastSellPendingBasePrice = PendingBasePrice ;
     if ( !(VirtualPendingOrdersEnabled) )
     {
       if ( CheckMargin && ProjectedFreeMarginAfterOrder(CurrentSymbol,ORDER_TYPE_SELL,LotSizeByStrategy[CurrentStrategyIndex])<=0.0 )
       {
         Print("Free margin not sufficient for setting order with lotsize " + string(LotSizeByStrategy[CurrentStrategyIndex]) + "..."); 
         return(false); 
       }
       PendingOrderPrice = NormalizeDouble(PendingBasePrice - RandomizedPendingEntryOffsetPips * PipSize,SymbolDigits) ;
       StopLossPrice = NormalizeDouble((StopLossPips + ExtraStopLossPips) * PipSize + PendingBasePrice,SymbolDigits) ;
       TakeProfitPrice = NormalizeDouble(PendingBasePrice - TakeProfitPips * PipSize,SymbolDigits) ;
       if ( LotSizeByStrategy[CurrentStrategyIndex]<SymbolInfoDouble(CurrentSymbol,SYMBOL_VOLUME_MIN) )
       {
         Print("Volume is less than the minimal allowed SYMBOL_VOLUME_MIN=" + string(SymbolInfoDouble(CurrentSymbol,SYMBOL_VOLUME_MIN))); 
         VolumeValid = false;
       }
       else
       {
         if ( LotSizeByStrategy[CurrentStrategyIndex]>SymbolInfoDouble(CurrentSymbol,SYMBOL_VOLUME_MAX) )
         {
           Print("Volume is greater than the maximal allowed SYMBOL_VOLUME_MAX=" + string(SymbolInfoDouble(CurrentSymbol,SYMBOL_VOLUME_MAX))); 
           VolumeValid = false;
         }
         else
         {
           if ( MathAbs(NormalizeDouble(LotSizeByStrategy[CurrentStrategyIndex] / SymbolInfoDouble(CurrentSymbol,SYMBOL_VOLUME_STEP),0) * SymbolInfoDouble(CurrentSymbol,SYMBOL_VOLUME_STEP) - LotSizeByStrategy[CurrentStrategyIndex])>0.0000001 )
           {
             Print("Volume " + string(LotSizeByStrategy[CurrentStrategyIndex]) + " is not a multiple of the minimal step SYMBOL_VOLUME_STEP=" + string(SymbolInfoDouble(CurrentSymbol,SYMBOL_VOLUME_STEP))); 
             VolumeValid = false;
           }
           else
           {
             VolumeValid = true;
           }
         }
       }

       AccountOrderLimit = (int)AccountInfoInteger(ACCOUNT_LIMIT_ORDERS);
       if ( AccountOrderLimit == 0 )
       {
         OrderLimitAvailable = true;
       }
       else
       {
         OrderLimitAvailable = ActiveTradeCount()<AccountOrderLimit;
       }
       if ( ( !(VolumeValid) || !(OrderLimitAvailable) ) )
       {
         return(false); 
       }
       if ( SymbolInfoDouble(CurrentSymbol,SYMBOL_BID)>FreezeLevelPriceDistance * PipSize + PendingOrderPrice && SymbolInfoDouble(CurrentSymbol,SYMBOL_BID)>StopLevelPriceDistance * PipSize + PendingOrderPrice )
       {
         if ( !(setSL_TP_After_Entry) )
         {
           LastTradeTicket = SendTradeOrder(CurrentSymbol,ORDER_TYPE_SELL_STOP,LotSizeByStrategy[CurrentStrategyIndex],PendingOrderPrice,int(OrderSlippageSetting * PipSize),StopLossPrice,TakeProfitPrice,CurrentStrategyComment,StrategyMagicNumber,PendingOrderExpirationTime,Red) ;
         }
         else
         {
           LastTradeTicket = SendTradeOrder(CurrentSymbol,ORDER_TYPE_SELL_STOP,LotSizeByStrategy[CurrentStrategyIndex],PendingOrderPrice,int(OrderSlippageSetting * PipSize),0.0,0.0,CurrentStrategyComment,StrategyMagicNumber,PendingOrderExpirationTime,Red) ;
         }
         SellPendingRestoreState = false ;
         if ( LastTradeTicket <= 0 )
         {
           SendErrorCode = LastTradeErrorCode();
           if ( SendErrorCode == 132 )
           {
             ResetLastError();
             if(1==0) // Điều kiện luôn sai; giữ nguyên nhánh vô hiệu từ mã gốc.
             {
               do
               {
                 Sleep(2500); 
                 if ( !(setSL_TP_After_Entry) )
                 {
                   SendErrorCode = (int)(OrderSlippageSetting * PipSize);
                   LastTradeTicket = SendTradeOrder(CurrentSymbol,ORDER_TYPE_SELL_STOP,LotSizeByStrategy[CurrentStrategyIndex],PendingOrderPrice,SendErrorCode,StopLossPrice,TakeProfitPrice,CurrentStrategyComment,StrategyMagicNumber,PendingOrderExpirationTime,Red) ;
                 }
                 else
                 {
                   LastTradeTicket = SendTradeOrder(CurrentSymbol,ORDER_TYPE_SELL_STOP,LotSizeByStrategy[CurrentStrategyIndex],PendingOrderPrice,int(OrderSlippageSetting * PipSize),0.0,0.0,CurrentStrategyComment,StrategyMagicNumber,PendingOrderExpirationTime,Red) ;
                 }
                 SellPendingRestoreState = false ;
               }
               while(LastTradeErrorCode() == STRATEGY_ERROR_MARKET_CLOSED);
               
             }
           }
           Print("error: \'" + TradeErrorDescription(LastTradeErrorCode()) + "\' when setting entry order"); 
         }
         else
         {
           RequestedEntryPrice = PendingBasePrice;
           SubmittedPendingTicket = LastTradeTicket;
           for (TicketMapInsertIndex = 0 ; TicketMapInsertIndex < 100 ; TicketMapInsertIndex=TicketMapInsertIndex + 1)
           {
             if ( !(PendingTicketPriceMap[TicketMapInsertIndex][0]==0.0) )   continue;
             PendingTicketPriceMap[TicketMapInsertIndex][0] = (double)SubmittedPendingTicket;
             PendingTicketPriceMap[TicketMapInsertIndex][1] = RequestedEntryPrice;
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
  bool      OrderStateChanged = false;
  bool      AnyTradeChanged = false;
  double    OriginalStopLoss;
  double    TrailReferencePrice;
  int       OrderScanIndex;
  double    StopLossPrice;
  double    TakeProfitPrice;
  long      OrderTicket;
  double    OpenPrice;
  string    OrderComment;
  double    OrderLots;
  datetime  OpenTime;
  int       OrderType;
  long       OrderMagic;
  string    OrderSymbol;
  double    RequestedEntryPrice;
  double    EntrySlippagePrice;
  bool      ExcessiveEntrySlippage;
  bool      ZoneRecoveryHandled;
  double    ZoneRecoveryOrderCount;
  bool      ZoneRecoveryOrderPlaced;
  double    ZoneRecoveryNextLots;
  double    ZoneRecoveryTriggerPrice;
  double    ZoneRecoveryReverseTriggerPrice;
  double    PartialCloseLots;
  double    VirtualStopPrice;
  int       VirtualStopSyncElapsedSeconds;
  double    PartialCloseLotsAfterTrail;
//----------------------------------------------------------------------
 int        PriceDigits;
 long       EntryTicketLookup;
 int        EntryPriceMapIndex;
 double     MappedRequestedEntryPrice;
 double     OpenPriceForMap;
 long       TicketForMapInsert;
 int        TicketMapInsertIndex;
 long       ZoneParentTicket;
 int        ZoneOrderCount;
 int        ZoneOrderScanIndex;
 string     ZoneOrderComment;
 double     AccountEquity;
 int        ZoneCloseAllScanIndex;
 long       ZoneProfitParentTicket;
 double     ZoneCombinedProfit;
 int        ZoneProfitScanIndex;
 long       ZoneSelectedTicket;
 long       ZoneCloseParentTicket;
 int        ZoneCloseScanIndex;
 int        ZoneMaximumTradesCloseScanIndexA;
 int        ZoneMaximumTradesCloseScanIndexB;
 string     ZoneReverseOrderComment;
 long       VirtualStopTicketPrimary;
 double     VirtualStopDistancePipsPrimary;
 double     VirtualStopOpenPricePrimary;
 int        VirtualStopDirectionPrimary;
 double     StoredVirtualStopPrimary;
 bool       VirtualStopFoundPrimary;
 int        VirtualStopLookupIndexPrimary;
 int        VirtualStopInsertIndexPrimary;
 double     UpdatedVirtualStopPrimary;
 long       VirtualStopUpdateTicketPrimary;
 int        VirtualStopUpdateIndexPrimary;
 long       VirtualStopTicketSecondary;
 double     VirtualStopDistancePipsSecondary;
 double     VirtualStopOpenPriceSecondary;
 int        VirtualStopDirectionSecondary;
 double     StoredVirtualStopSecondary;
 bool       VirtualStopFoundSecondary;
 int        VirtualStopLookupIndexSecondary;
 int        VirtualStopInsertIndexSecondary;
 double     UpdatedVirtualStopSecondary;
 long       VirtualStopUpdateTicketSecondary;
 int        VirtualStopUpdateIndexSecondary;

 OriginalStopLoss = 0.0 ;
 TrailReferencePrice = 0.0 ;
 for (OrderScanIndex = 0 ; OrderScanIndex < ActiveTradeCount() ; OrderScanIndex ++)
 {
   if ( SelectTradeRecord(OrderScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) == true )
   {
     OrderStateChanged = false ;
     StopLossPrice = NormalizeDouble(SelectedTradeStopLoss(),SymbolDigits) ;
     TakeProfitPrice = NormalizeDouble(SelectedTradeTakeProfit(),SymbolDigits) ;
     OrderTicket = SelectedTradeTicket() ;
     OpenPrice = NormalizeDouble(SelectedTradeOpenPrice(),SymbolDigits) ;
     OrderComment = SelectedTradeComment() ;
     OrderLots = SelectedTradeVolume() ;
     OpenTime = SelectedTradeOpenTime() ;
     OrderType = SelectedTradeType() ;
     OrderMagic = SelectedTradeMagic() ;
     OrderSymbol = SelectedTradeSymbol() ;
     if ( ( OrderType == 4 || OrderType == 2 ) && EntryStrategyMode == 2 && ( ManualTradeSymbolFilterMode == 0 || (ManualTradeSymbolFilterMode == 1 && OrderSymbol == CurrentSymbol) ) && ( OrderMagic == ManualStrategy2MagicNumber || ManualStrategy2MagicNumber == 0 ) && ( OrderComment == ManualStrategy2Comment || ManualStrategy2Comment == "" ) )
     {
       if ( ( StopLossPrice==0.0 || StopLossPrice==0.0 ) )
       {
         StopLossPrice = NormalizeDouble(OpenPrice - StopLossPips * PipSize,SymbolDigits) ;
         ModifyTradeByTicket(OrderTicket,OpenPrice,StopLossPrice,TakeProfitPrice,0,Green); 
       }
       if ( ( TakeProfitPrice==0.0 || TakeProfitPrice==0.0 ) )
       {
         TakeProfitPrice = NormalizeDouble(TakeProfitPips * PipSize + OpenPrice,SymbolDigits) ;
         ModifyTradeByTicket(OrderTicket,OpenPrice,StopLossPrice,TakeProfitPrice,0,Green); 
       }
     }
     if ( OrderType == 0 && ( ( OrderMagic == StrategyMagicNumber && EntryStrategyMode == 1 && OrderSymbol == CurrentSymbol ) || (EntryStrategyMode == 2 && ( ManualTradeSymbolFilterMode == 0 || (ManualTradeSymbolFilterMode == 1 && OrderSymbol == CurrentSymbol) ) && ( OrderMagic == ManualStrategy2MagicNumber || ManualStrategy2MagicNumber == 0 ) && (OrderComment == ManualStrategy2Comment || ManualStrategy2Comment == "")) ) )
     {
       if ( ( StopLossPrice==0.0 || StopLossPrice==0.0 ) )
       {
         StopLossPrice = NormalizeDouble(OpenPrice - StopLossPips * PipSize,SymbolDigits) ;
         ModifyTradeByTicket(OrderTicket,OpenPrice,StopLossPrice,TakeProfitPrice,0,Green); 
       }
       if ( ( TakeProfitPrice==0.0 || TakeProfitPrice==0.0 ) )
       {
         TakeProfitPrice = NormalizeDouble(TakeProfitPips * PipSize + OpenPrice,SymbolDigits) ;
         ModifyTradeByTicket(OrderTicket,OpenPrice,StopLossPrice,TakeProfitPrice,0,Green); 
       }
       if ( CandleExitM1Enabled && iTime(CurrentSymbol,NormalizeTimeframe(CandleExitM1TimeframeMinutes),CandleExitOpenBarShift) <= OpenTime && iTime(CurrentSymbol,NormalizeTimeframe(CandleExitM1TimeframeMinutes),0) >  OpenTime && iClose(CurrentSymbol,NormalizeTimeframe(CandleExitM1TimeframeMinutes),1)<iOpen(CurrentSymbol,NormalizeTimeframe(CandleExitM1TimeframeMinutes),1) && iClose(CurrentSymbol,NormalizeTimeframe(CandleExitM1TimeframeMinutes),1)<OpenPrice )
       {
         ClosePositionByTicket(OrderTicket,OrderLots,SymbolInfoDouble(CurrentSymbol,SYMBOL_BID),0,Red); 
         Print("closing candle confirmation"); 
       }
       if ( CandleExitM5Enabled && iTime(CurrentSymbol,NormalizeTimeframe(CandleExitM5TimeframeMinutes),CandleExitOpenBarShift) <= OpenTime && iTime(CurrentSymbol,NormalizeTimeframe(CandleExitM5TimeframeMinutes),0) >  OpenTime && iClose(CurrentSymbol,NormalizeTimeframe(CandleExitM5TimeframeMinutes),1)<iOpen(CurrentSymbol,NormalizeTimeframe(CandleExitM5TimeframeMinutes),1) && iClose(CurrentSymbol,NormalizeTimeframe(CandleExitM5TimeframeMinutes),1)<OpenPrice )
       {
         ClosePositionByTicket(OrderTicket,OrderLots,SymbolInfoDouble(CurrentSymbol,SYMBOL_BID),0,Red); 
         Print("closing candle confirmation"); 
       }
       if ( CandleExitM15Enabled && iTime(CurrentSymbol,NormalizeTimeframe(CandleExitM15TimeframeMinutes),CandleExitOpenBarShift) <= OpenTime && iTime(CurrentSymbol,NormalizeTimeframe(CandleExitM15TimeframeMinutes),0) >  OpenTime && iClose(CurrentSymbol,NormalizeTimeframe(CandleExitM15TimeframeMinutes),1)<iOpen(CurrentSymbol,NormalizeTimeframe(CandleExitM15TimeframeMinutes),1) && iClose(CurrentSymbol,NormalizeTimeframe(CandleExitM15TimeframeMinutes),1)<OpenPrice )
       {
         ClosePositionByTicket(OrderTicket,OrderLots,SymbolInfoDouble(CurrentSymbol,SYMBOL_BID),0,Red); 
         Print("closing candle confirmation"); 
       }
       if ( CandleExitM30Enabled && iTime(CurrentSymbol,NormalizeTimeframe(CandleExitM30TimeframeMinutes),CandleExitOpenBarShift) <= OpenTime && iTime(CurrentSymbol,NormalizeTimeframe(CandleExitM30TimeframeMinutes),0) >  OpenTime && iClose(CurrentSymbol,NormalizeTimeframe(CandleExitM30TimeframeMinutes),1)<iOpen(CurrentSymbol,NormalizeTimeframe(CandleExitM30TimeframeMinutes),1) && iClose(CurrentSymbol,NormalizeTimeframe(CandleExitM30TimeframeMinutes),1)<OpenPrice )
       {
         ClosePositionByTicket(OrderTicket,OrderLots,SymbolInfoDouble(CurrentSymbol,SYMBOL_BID),0,Red); 
         Print("closing candle confirmation"); 
       }
       if ( CandleExitH1Enabled && iTime(CurrentSymbol,NormalizeTimeframe(CandleExitH1TimeframeMinutes),CandleExitOpenBarShift) <= OpenTime && iTime(CurrentSymbol,NormalizeTimeframe(CandleExitH1TimeframeMinutes),0) >  OpenTime && iClose(CurrentSymbol,NormalizeTimeframe(CandleExitH1TimeframeMinutes),1)<iOpen(CurrentSymbol,NormalizeTimeframe(CandleExitH1TimeframeMinutes),1) && iClose(CurrentSymbol,NormalizeTimeframe(CandleExitH1TimeframeMinutes),1)<OpenPrice )
       {
         ClosePositionByTicket(OrderTicket,OrderLots,SymbolInfoDouble(CurrentSymbol,SYMBOL_BID),0,Red); 
         Print("closing candle confirmation"); 
       }
       ActiveMagicTrailActivationPips = MagicTrailActivationDistancePips ;
       if ( MagicTrailDelayMinutes >  0 && TimeCurrent() >  OpenTime + MagicTrailDelayMinutes * 60 )
       {
         ActiveMagicTrailActivationPips = MagicTrailDelayedActivationPips ;
       }
       PriceDigits = SymbolDigits;
       EntryTicketLookup = OrderTicket;
       for (EntryPriceMapIndex = 0 ; EntryPriceMapIndex < 100 ; EntryPriceMapIndex=EntryPriceMapIndex + 1)
       {
         if ( !(PendingTicketPriceMap[EntryPriceMapIndex][0]==EntryTicketLookup) )   continue;
         MappedRequestedEntryPrice = PendingTicketPriceMap[EntryPriceMapIndex][1];
         break;
         
       }
       MappedRequestedEntryPrice = 0.0;
       RequestedEntryPrice = NormalizeDouble(MappedRequestedEntryPrice,PriceDigits) ;
       if ( RequestedEntryPrice==0.0 )
       {
         OpenPriceForMap = OpenPrice;
         TicketForMapInsert = OrderTicket;
         for (TicketMapInsertIndex = 0 ; TicketMapInsertIndex < 100 ; TicketMapInsertIndex=TicketMapInsertIndex + 1)
         {
           if ( !(PendingTicketPriceMap[TicketMapInsertIndex][0]==0.0) )   continue;
           PendingTicketPriceMap[TicketMapInsertIndex][0] = (double)TicketForMapInsert;
           PendingTicketPriceMap[TicketMapInsertIndex][1] = OpenPriceForMap;
           break;
           
         }
         RequestedEntryPrice = OpenPrice ;
       }
       else
       {
         RequestedEntryPrice = RequestedEntryPrice - RequestedEntryAdjustmentPips * PipSize ;
       }
       EntrySlippagePrice = OpenPrice - RequestedEntryPrice ;
       ExcessiveEntrySlippage = false ;
       if ( RequestedEntryPrice>0.0 - RequestedEntryAdjustmentPips * PipSize && EntrySlippagePrice>OrderSlippageSetting * PipSize )
       {
         ExcessiveEntrySlippage = true ;
         if ( SlippageControlMode == 2 )
         {
           ActiveMagicTrailActivationPips = -1000.0 ;
           Print("SlippageMode 2 active"); 
         }
       }
       if ( UseRequestedEntryAsTrailReference )
       {
         TrailReferencePrice = RequestedEntryPrice ;
       }
       else
       {
         TrailReferencePrice = OpenPrice ;
       }
       if ( StopLossPrice<NormalizeDouble(OpenPrice - (StopLossPips + ExtraStopLossPips) * PipSize - CurrentSpreadPrice,SymbolDigits) )
       {
         StopLossPrice = NormalizeDouble(OpenPrice - (StopLossPips + ExtraStopLossPips) * PipSize - CurrentSpreadPrice,SymbolDigits) ;
         ModifyTradeByTicket(OrderTicket,OpenPrice,StopLossPrice,TakeProfitPrice,0,clrNONE); 
       }
       if ( SymbolInfoDouble(CurrentSymbol,SYMBOL_BID)<OpenPrice - (StopLossPips + ExtraStopLossPips) * PipSize - CurrentSpreadPrice )
       {
         RefreshCurrentSymbolTick(); 
         ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(CurrentSymbol,SYMBOL_BID),(int)CurrentSpreadPrice,Red); 
         return(true); 
       }
       ZoneRecoveryHandled = false ;
       if ( ZoneRecoveryEnabled )
       {
         ZoneParentTicket = OrderTicket;
         ZoneOrderCount = 0;
         for (ZoneOrderScanIndex = ActiveTradeCount() ; ZoneOrderScanIndex >= 0 ; ZoneOrderScanIndex=ZoneOrderScanIndex - 1)
         {
           if ( SelectTradeRecord(ZoneOrderScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != ZoneRecoveryBuyMagic || SelectedTradeSymbol() != CurrentSymbol )   continue;
           ZoneOrderComment = SelectedTradeComment();
           if ( ZoneOrderComment != IntegerToString(ZoneParentTicket,0,32) )   continue;
           ZoneOrderCount=ZoneOrderCount + 1;
           
         }
         ZoneRecoveryOrderCount = ZoneOrderCount ;
         ZoneRecoveryOrderPlaced = false ;
         if ( !(BuyZoneStateInitialized) )
         {
           BuyZoneStateInitialized = true ;
           BuyZoneNextOrderSide = 0 ;
         }
         if ( ZoneRecoveryOrderCount==0.0 )
         {
           BuyZoneNextOrderSide = 0 ;
         }
         if ( MathFloor(ZoneRecoveryOrderCount / 2.0)==ZoneRecoveryOrderCount / 2.0 )
         {
           BuyZoneNextOrderSide = 0 ;
         }
         else
         {
           BuyZoneNextOrderSide = 1 ;
         }
         if ( BuyZoneStateInitialized )
         {
           if ( ZoneRecoveryOrderCount>0.0 )
           {
             AccountEquity = AccountInfoDouble(ACCOUNT_EQUITY);
             if ( AccountEquity>AccountInfoDouble(ACCOUNT_BALANCE) + ZoneRecoveryProfitTarget )
             {
               for (ZoneCloseAllScanIndex = ActiveTradeCount() ; ZoneCloseAllScanIndex >= 0 ; ZoneCloseAllScanIndex=ZoneCloseAllScanIndex - 1)
               {
                 if ( SelectTradeRecord(ZoneCloseAllScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true )   continue;
                 
                 if ( ( SelectedTradeMagic() != StrategyMagicNumber && SelectedTradeMagic() != ZoneRecoverySellMagic && SelectedTradeMagic() != ZoneRecoveryBuyMagic ) )   continue;
                 
                 if ( SelectedTradeType() == ORDER_TYPE_BUY )
                 {
                   ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(CurrentSymbol,SYMBOL_BID),(int)OrderSlippageSetting,Red); 
                 }
                 if ( SelectedTradeType() != ORDER_TYPE_SELL )   continue;
                 ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK),(int)OrderSlippageSetting,Red); 
                 
               }
             }
           }
           if ( ZoneRecoveryOrderCount>0.0 )
           {
             ZoneProfitParentTicket = OrderTicket;
             ZoneCombinedProfit = 0.0;
             for (ZoneProfitScanIndex = ActiveTradeCount() ; ZoneProfitScanIndex >= 0 ; ZoneProfitScanIndex=ZoneProfitScanIndex - 1)
             {
               if ( SelectTradeRecord(ZoneProfitScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true )   continue;
               ZoneSelectedTicket = SelectedTradeTicket();
               if ( ZoneSelectedTicket != ZoneProfitParentTicket )
               {
                 ZoneOrderComment = SelectedTradeComment();
               if ( ZoneOrderComment != IntegerToString(ZoneProfitParentTicket,0,32) )   continue;
               }
               ZoneCombinedProfit = ZoneCombinedProfit + SelectedTradeProfit();
               
             }
             if ( ZoneCombinedProfit>ZoneRecoveryProfitTarget )
             {
               Print("Closing zone"); 
               ZoneCloseParentTicket = OrderTicket;
               for (ZoneCloseScanIndex = ActiveTradeCount() ; ZoneCloseScanIndex >= 0 ; ZoneCloseScanIndex=ZoneCloseScanIndex - 1)
               {
                 if ( SelectTradeRecord(ZoneCloseScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true )   continue;
                 
                 if ( SelectedTradeMagic() == StrategyMagicNumber && SelectedTradeTicket() == ZoneCloseParentTicket )
                 {
                   ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(CurrentSymbol,SYMBOL_BID),3,Red); 
                 }
                 if ( SelectedTradeMagic() != ZoneRecoveryBuyMagic )   continue;
                 ZoneOrderComment = SelectedTradeComment();
                 if ( ZoneOrderComment != IntegerToString(ZoneCloseParentTicket,0,32) )   continue;
                 
                 if ( SelectedTradeType() == ORDER_TYPE_BUY )
                 {
                   ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(CurrentSymbol,SYMBOL_BID),(int)OrderSlippageSetting,Red); 
                 }
                 if ( SelectedTradeType() != ORDER_TYPE_SELL )   continue;
                 ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK),(int)OrderSlippageSetting,Red); 
                 
               }
               BuyZoneStateInitialized = false ;
               ZoneRecoveryHandled = true ;
             }
           }
           else
           {
             ZoneRecoveryNextLots = OrderLots * ZoneRecoveryLotMultiplier ;
             if ( ZoneRecoveryLotSizingMode == 2 )
             {
               ZoneRecoveryNextLots = (ZoneRecoveryOrderCount + 1.0) * OrderLots + OrderLots ;
             }
             if ( ZoneRecoveryLotSizingMode == 3 )
             {
               ZoneRecoveryNextLots = OrderLots * (MathPow(ZoneRecoveryLotMultiplier,ZoneRecoveryOrderCount + 1.0)) ;
             }
             if ( BuyZoneNextOrderSide == 0 )
             {
               ZoneRecoveryTriggerPrice = ZoneRecoveryOrderCount * ZoneRecoveryStepDistancePips * PipSize + (RequestedEntryPrice - ZoneRecoveryInitialDistancePips * PipSize) ;
               if ( ZoneRecoveryTriggerPrice>RequestedEntryPrice - ZoneRecoveryMinimumDistancePips * PipSize )
               {
                 ZoneRecoveryTriggerPrice = RequestedEntryPrice - ZoneRecoveryMinimumDistancePips * PipSize ;
               }
               if ( SymbolInfoDouble(CurrentSymbol,SYMBOL_BID)<ZoneRecoveryTriggerPrice )
               {
                 if ( ZoneRecoveryOrderCount>=ZoneRecoveryMaximumTrades )
                 {
                   for (ZoneMaximumTradesCloseScanIndexA = ActiveTradeCount() ; ZoneMaximumTradesCloseScanIndexA >= 0 ; ZoneMaximumTradesCloseScanIndexA=ZoneMaximumTradesCloseScanIndexA - 1)
                   {
                     if ( SelectTradeRecord(ZoneMaximumTradesCloseScanIndexA,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true )   continue;
                     
                     if ( SelectedTradeMagic() == StrategyMagicNumber && SelectedTradeTicket() == OrderTicket )
                     {
                       ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(CurrentSymbol,SYMBOL_BID),3,Red); 
                     }
                     if ( SelectedTradeMagic() != ZoneRecoveryBuyMagic )   continue;
                     ZoneOrderComment = SelectedTradeComment();
                     if ( ZoneOrderComment != IntegerToString(OrderTicket,0,32) )   continue;
                     
                     if ( SelectedTradeType() == ORDER_TYPE_BUY )
                     {
                       ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(CurrentSymbol,SYMBOL_BID),(int)OrderSlippageSetting,Red); 
                     }
                     if ( SelectedTradeType() != ORDER_TYPE_SELL )   continue;
                     ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK),(int)OrderSlippageSetting,Red); 
                     
                   }
                 }
                 else
                 {
                   SendTradeOrder(CurrentSymbol,ORDER_TYPE_SELL,ZoneRecoveryNextLots,SymbolInfoDouble(CurrentSymbol,SYMBOL_BID),(int)OrderSlippageSetting,0.0,0.0,IntegerToString(OrderTicket,0,32),ZoneRecoveryBuyMagic,0,Green); 
                   BuyZoneNextOrderSide = 1 ;
                   ZoneRecoveryOrderPlaced = true ;
                 }
               }
             }
             else
             {
               ZoneRecoveryReverseTriggerPrice = RequestedEntryPrice ;
               if ( SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK)>RequestedEntryPrice )
               {
                 if ( ZoneRecoveryOrderCount>=ZoneRecoveryMaximumTrades )
                 {
                   for (ZoneMaximumTradesCloseScanIndexB = ActiveTradeCount() ; ZoneMaximumTradesCloseScanIndexB >= 0 ; ZoneMaximumTradesCloseScanIndexB=ZoneMaximumTradesCloseScanIndexB - 1)
                   {
                     if ( SelectTradeRecord(ZoneMaximumTradesCloseScanIndexB,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true )   continue;
                     
                     if ( SelectedTradeMagic() == StrategyMagicNumber && SelectedTradeTicket() == OrderTicket )
                     {
                       ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(CurrentSymbol,SYMBOL_BID),3,Red); 
                     }
                     if ( SelectedTradeMagic() != ZoneRecoveryBuyMagic )   continue;
                     ZoneReverseOrderComment = SelectedTradeComment();
                     if ( ZoneReverseOrderComment != IntegerToString(OrderTicket,0,32) )   continue;
                     
                     if ( SelectedTradeType() == ORDER_TYPE_BUY )
                     {
                       ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(CurrentSymbol,SYMBOL_BID),(int)OrderSlippageSetting,Red); 
                     }
                     if ( SelectedTradeType() != ORDER_TYPE_SELL )   continue;
                     ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK),(int)OrderSlippageSetting,Red); 
                     
                   }
                 }
                 else
                 {
                   SendTradeOrder(CurrentSymbol,ORDER_TYPE_BUY,ZoneRecoveryNextLots,SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK),(int)OrderSlippageSetting,0.0,0.0,IntegerToString(OrderTicket,0,32),ZoneRecoveryBuyMagic,0,Green); 
                   BuyZoneNextOrderSide = 0 ;
                   ZoneRecoveryOrderPlaced = true ;
                 }
               }
             }
           }
         }
         if ( ( ZoneRecoveryOrderCount>0.0 || ZoneRecoveryOrderPlaced ) )
         {
           ZoneRecoveryHandled = true ;
         }
       }
       if ( !(ZoneRecoveryHandled) )
       {
         if ( ( TradeMonitorFilterMode == 1 || (TradeMonitorFilterMode != 3 && TradeMonitorFilterMode != 2) ) )
         {
           VirtualStopTicketPrimary = OrderTicket;
           VirtualStopDistancePipsPrimary = StopLossPips;
           VirtualStopOpenPricePrimary = OpenPrice;
           VirtualStopDirectionPrimary = 1;
           StoredVirtualStopPrimary = 0.0;
           VirtualStopFoundPrimary = false;
           for (VirtualStopLookupIndexPrimary = 0 ; VirtualStopLookupIndexPrimary < SmallBufferCapacity ; VirtualStopLookupIndexPrimary=VirtualStopLookupIndexPrimary + 1)
           {
             if ( VirtualStopByTicket[VirtualStopLookupIndexPrimary][0]==VirtualStopTicketPrimary )
             {
               StoredVirtualStopPrimary = VirtualStopByTicket[VirtualStopLookupIndexPrimary][1];
               VirtualStopFoundPrimary = true;
               break;
             }
           }
           if ( !(VirtualStopFoundPrimary) )
           {
             if ( VirtualStopDirectionPrimary == 1 )
             {
               StoredVirtualStopPrimary = NormalizeDouble(VirtualStopOpenPricePrimary - VirtualStopDistancePipsPrimary * PipSize,SymbolDigits);
             }
             if ( VirtualStopDirectionPrimary == 2 )
             {
               StoredVirtualStopPrimary = NormalizeDouble(VirtualStopDistancePipsPrimary * PipSize + VirtualStopOpenPricePrimary,SymbolDigits);
             }
             for (VirtualStopInsertIndexPrimary = 0 ; VirtualStopInsertIndexPrimary < SmallBufferCapacity ; VirtualStopInsertIndexPrimary=VirtualStopInsertIndexPrimary + 1)
             {
               if ( VirtualStopByTicket[VirtualStopInsertIndexPrimary][0]==0.0 )
               {
                 VirtualStopByTicket[VirtualStopInsertIndexPrimary][0] = (double)VirtualStopTicketPrimary;
                 VirtualStopByTicket[VirtualStopInsertIndexPrimary][1] = StoredVirtualStopPrimary;
                 break;
               }
             }
           }
           ActiveVirtualStopPrice = StoredVirtualStopPrimary ;
           OriginalStopLoss = ActiveVirtualStopPrice ;
           if ( SymbolInfoDouble(CurrentSymbol,SYMBOL_BID)<OriginalStopLoss )
           {
             Print("Closing with virtual SL"); 
             RefreshCurrentSymbolTick(); 
             ClosePositionByTicket(OrderTicket,OrderLots,SymbolInfoDouble(CurrentSymbol,SYMBOL_BID),(int)CurrentSpreadPrice,clrNONE); 
             return(true); 
           }
           if ( TimeRecoveryAfterMinutes>0.0 && TimeCurrent() >= OpenTime + TimeRecoveryDelaySeconds && SymbolInfoDouble(CurrentSymbol,SYMBOL_BID)>NormalizeDouble(TimeRecoveryStopPips * PipSize + (StopLossPrice + SymbolPoint),SymbolDigits) && SymbolInfoDouble(CurrentSymbol,SYMBOL_BID)<TakeProfitPrice - FreezeLevelPriceDistance )
           {
             StopLossPrice = NormalizeDouble(SymbolInfoDouble(CurrentSymbol,SYMBOL_BID) - TimeRecoveryStopPips * PipSize,SymbolDigits) ;
             if ( StopLossPrice<SymbolInfoDouble(CurrentSymbol,SYMBOL_BID) - StopLevelPriceDistance )
             {
               LastTradeTicket = ModifyTradeByTicket(OrderTicket,OpenPrice,StopLossPrice,TakeProfitPrice,0,clrNONE) ;
               if ( LastTradeTicket <= 0 )
               {
                 Print("TrailStop error: \'" + TradeErrorDescription(LastTradeErrorCode()) + "\' when setting trailing Exit_TrailSL_after_X_Minutes_size loss.  Trying again!"); 
               }
               OrderStateChanged = true ;
             }
           }
           if ( TrailingSLStartPips>0.0 && SymbolInfoDouble(CurrentSymbol,SYMBOL_BID)>NormalizeDouble((TrailingSLStartPips + TrailingActivationBufferPips) * PipSize + (StopLossPrice + SymbolPoint),SymbolDigits) && SymbolInfoDouble(CurrentSymbol,SYMBOL_BID)>NormalizeDouble(TrailingSLDistancePips * PipSize + TrailReferencePrice,SymbolDigits) && SymbolInfoDouble(CurrentSymbol,SYMBOL_BID)<TakeProfitPrice - FreezeLevelPriceDistance && StopLossPrice<NormalizeDouble(TrailingSLStepLimitPips * PipSize + OpenPrice,SymbolDigits) )
           {
             StopLossPrice = NormalizeDouble(SymbolInfoDouble(CurrentSymbol,SYMBOL_BID) - TrailingSLStartPips * PipSize,SymbolDigits) ;
             if ( StopLossPrice<SymbolInfoDouble(CurrentSymbol,SYMBOL_BID) - StopLevelPriceDistance )
             {
               LastTradeTicket = ModifyTradeByTicket(OrderTicket,OpenPrice,StopLossPrice,TakeProfitPrice,0,clrNONE) ;
               if ( LastTradeTicket <= 0 )
               {
                 Print("TrailStop error: \'" + TradeErrorDescription(LastTradeErrorCode()) + "\' when setting trailing Exit_stop loss.  Trying again!"); 
               }
               else
               {
                 PartialCloseLots = NormalizeDouble(TrailingPartialClosePercent / 100.0 * LotSizeByStrategy[CurrentStrategyIndex],2) ;
                 if ( PartialCloseLots<OrderLots && PartialCloseLots>=SymbolInfoDouble(CurrentSymbol,SYMBOL_VOLUME_STEP) )
                 {
                   ClosePositionByTicket(OrderTicket,PartialCloseLots,SymbolInfoDouble(CurrentSymbol,SYMBOL_BID),(int)OrderSlippageSetting,Red); 
                   return(true); 
                 }
               }
               OrderStateChanged = true ;
             }
           }
           if ( TrailingTPStartPips>0.0 && SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK)<NormalizeDouble(TakeProfitPrice - SymbolPoint - TrailingTPStartPips * PipSize,SymbolDigits) && SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK)<NormalizeDouble(TrailReferencePrice - TrailingTPDistancePips * PipSize,SymbolDigits) && SymbolInfoDouble(CurrentSymbol,SYMBOL_BID)<TakeProfitPrice - FreezeLevelPriceDistance )
           {
             TakeProfitPrice = NormalizeDouble(SymbolInfoDouble(CurrentSymbol,SYMBOL_BID) + TrailingTPStartPips * PipSize,SymbolDigits) ;
             if ( TakeProfitPrice>SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK) + StopLevelPriceDistance )
             {
               LastTradeTicket = ModifyTradeByTicket(OrderTicket,OpenPrice,StopLossPrice,TakeProfitPrice,0,clrNONE) ;
               if ( LastTradeTicket <= 0 )
               {
                 Print("TrailStop error: \'" + TradeErrorDescription(LastTradeErrorCode()) + "\' when setting trailing Exit_TP.  Trying again!"); 
               }
               else
               {
                 VirtualStopPrice = NormalizeDouble(TrailingPartialClosePercent / 100.0 * LotSizeByStrategy[CurrentStrategyIndex],2) ;
                 if ( VirtualStopPrice<OrderLots && VirtualStopPrice>=SymbolInfoDouble(CurrentSymbol,SYMBOL_VOLUME_MIN) )
                 {
                   ClosePositionByTicket(OrderTicket,VirtualStopPrice,SymbolInfoDouble(CurrentSymbol,SYMBOL_BID),(int)OrderSlippageSetting,Red); 
                   return(true); 
                 }
               }
               OrderStateChanged = true ;
             }
           }
           if ( ExcessiveEntrySlippage && SlippageControlMode == 1 && SlippageRecoveryTrailDistancePips>0.0 && SymbolInfoDouble(CurrentSymbol,SYMBOL_BID)>NormalizeDouble(SlippageRecoveryTrailDistancePips * PipSize + (StopLossPrice + SymbolPoint),SymbolDigits) && SymbolInfoDouble(CurrentSymbol,SYMBOL_BID)>NormalizeDouble(SlippageRecoveryTriggerPips * PipSize + RequestedEntryPrice,SymbolDigits) && SymbolInfoDouble(CurrentSymbol,SYMBOL_BID)<TakeProfitPrice - FreezeLevelPriceDistance && StopLossPrice<NormalizeDouble(SlippageRecoveryMaximumStopPips * PipSize + OpenPrice,SymbolDigits) )
           {
             StopLossPrice = NormalizeDouble(SymbolInfoDouble(CurrentSymbol,SYMBOL_BID) - SlippageRecoveryTrailDistancePips * PipSize,SymbolDigits) ;
             if ( StopLossPrice<SymbolInfoDouble(CurrentSymbol,SYMBOL_BID) - StopLevelPriceDistance )
             {
               LastTradeTicket = ModifyTradeByTicket(OrderTicket,OpenPrice,StopLossPrice,TakeProfitPrice,0,clrNONE) ;
               if ( LastTradeTicket <= 0 )
               {
                 Print("TrailStop error: \'" + TradeErrorDescription(LastTradeErrorCode()) + "\' when setting Slip TL.  Trying again!"); 
               }
               else
               {
                 Print("Slippage control active"); 
               }
               OrderStateChanged = true ;
             }
           }
           if ( HighLowLeftBars >  0 && HighLowRightBars >= 0 && UseHL_TrailingSL && SellTriggerPriceByStrategy[CurrentStrategyIndex]>NormalizeDouble(StopLossPrice + StopLevelPriceDistance + SymbolPoint,SymbolDigits) && SellTriggerPriceByStrategy[CurrentStrategyIndex]<SymbolInfoDouble(CurrentSymbol,SYMBOL_BID) - HighLowLookbackBars * PipSize && ( SellTriggerPriceByStrategy[CurrentStrategyIndex]<OpenPrice || !(HighLowTrailingEnabled) ) && SellTriggerPriceByStrategy[CurrentStrategyIndex]<NormalizeDouble(SymbolInfoDouble(CurrentSymbol,SYMBOL_BID) - HighLowMinimumMarketGapPips * PipSize - StopLevelPriceDistance - SymbolPoint,SymbolDigits) && SymbolInfoDouble(CurrentSymbol,SYMBOL_BID)<TakeProfitPrice - FreezeLevelPriceDistance )
           {
             StopLossPrice = NormalizeDouble(SellTriggerPriceByStrategy[CurrentStrategyIndex],SymbolDigits) ;
             if ( StopLossPrice<SymbolInfoDouble(CurrentSymbol,SYMBOL_BID) - StopLevelPriceDistance )
             {
               LastTradeTicket = ModifyTradeByTicket(OrderTicket,OpenPrice,StopLossPrice,TakeProfitPrice,0,clrNONE) ;
               if ( LastTradeTicket <= 0 )
               {
                 Print("error: \'" + TradeErrorDescription(LastTradeErrorCode()) + "\' when modifying stoploss"); 
               }
               OrderStateChanged = true ;
             }
           }
           if ( BreakEvenStartPips>0.0 && SymbolInfoDouble(CurrentSymbol,SYMBOL_BID)>NormalizeDouble(BreakEvenStartPips * PipSize + OpenPrice,SymbolDigits) && NormalizeDouble(BreakEvenExtraPips * PipSize + OpenPrice,SymbolDigits)>StopLossPrice + SymbolPoint && SymbolInfoDouble(CurrentSymbol,SYMBOL_BID)>NormalizeDouble(BreakEvenExtraPips * PipSize + OpenPrice + StopLevelPriceDistance,SymbolDigits) && SymbolInfoDouble(CurrentSymbol,SYMBOL_BID)<TakeProfitPrice - FreezeLevelPriceDistance )
           {
             StopLossPrice = NormalizeDouble(BreakEvenExtraPips * PipSize + OpenPrice,SymbolDigits) ;
             if ( StopLossPrice<SymbolInfoDouble(CurrentSymbol,SYMBOL_BID) - StopLevelPriceDistance )
             {
               LastTradeTicket = ModifyTradeByTicket(OrderTicket,OpenPrice,StopLossPrice,TakeProfitPrice,0,clrNONE) ;
               if ( LastTradeTicket <= 0 )
               {
                 Print("error when setting breakeven: \'" + TradeErrorDescription(LastTradeErrorCode()) + "\' ..\'Exit_BE_start\' to close to \'Exit_BE_extra_pips\' ..trying again!"); 
               }
               OrderStateChanged = true ;
             }
           }
           if ( !(OrderStateChanged) && ( MagicTrailMode == 1 || (MagicTrailMode == 2 && MagicTrailStepPips * PipSize + StopLossPrice<=MagicTrailMode2SpreadBufferPips * PipSize + (TrailReferencePrice + CurrentSpreadPrice)) ) )
           {
             MagicTrailTickCounter ++;
             if ( SymbolInfoDouble(CurrentSymbol,SYMBOL_BID)>MagicTrailStepPips * PipSize + StopLossPrice + StopLevelPriceDistance && SymbolInfoDouble(CurrentSymbol,SYMBOL_BID)<TakeProfitPrice - FreezeLevelPriceDistance && ( MagicTrailActivationDistancePips==0.0 || SymbolInfoDouble(CurrentSymbol,SYMBOL_BID)>ActiveMagicTrailActivationPips * PipSize + TrailReferencePrice ) && MagicTrailTickCounter >= MagicTrailMinimumTickCount && NormalizeDouble(MagicTrailStepPips * PipSize + StopLossPrice,SymbolDigits)>StopLossPrice )
             {
               MagicTrailTickCounter = 0 ;
               StopLossPrice = NormalizeDouble(MagicTrailStepPips * PipSize + StopLossPrice,SymbolDigits) ;
               ModifyTradeByTicket(OrderTicket,OpenPrice,StopLossPrice,TakeProfitPrice,0,clrNONE); 
               OrderStateChanged = true ;
             }
           }
           ActiveVirtualStopPrice = StopLossPrice ;
           if ( SymbolInfoDouble(CurrentSymbol,SYMBOL_BID)<StopLossPrice )
           {
             Print("Closing with virtual SL"); 
             RefreshCurrentSymbolTick(); 
             ClosePositionByTicket(OrderTicket,OrderLots,SymbolInfoDouble(CurrentSymbol,SYMBOL_BID),(int)CurrentSpreadPrice,clrNONE); 
             return(true); 
           }
           if ( NormalizeDouble(OriginalStopLoss,SymbolDigits)!=NormalizeDouble(ActiveVirtualStopPrice,SymbolDigits) )
           {
             UpdatedVirtualStopPrimary = NormalizeDouble(ActiveVirtualStopPrice,SymbolDigits);
             VirtualStopUpdateTicketPrimary = OrderTicket;
             for (VirtualStopUpdateIndexPrimary = 0 ; VirtualStopUpdateIndexPrimary < SmallBufferCapacity ; VirtualStopUpdateIndexPrimary=VirtualStopUpdateIndexPrimary + 1)
             {
               if ( VirtualStopByTicket[VirtualStopUpdateIndexPrimary][0]==VirtualStopUpdateTicketPrimary )
               {
                 VirtualStopByTicket[VirtualStopUpdateIndexPrimary][1] = UpdatedVirtualStopPrimary;
                 break;
               }
             }
           }
           if ( OrderStateChanged && ReturnAfterStopModification )
           {
             return(true); 
           }
         }
         if ( ( TradeMonitorFilterMode == 2 || TradeMonitorFilterMode == 3 ) )
         {
           VirtualStopTicketSecondary = OrderTicket;
           VirtualStopDistancePipsSecondary = StopLossPips;
           VirtualStopOpenPriceSecondary = OpenPrice;
           VirtualStopDirectionSecondary = 1;
           StoredVirtualStopSecondary = 0.0;
           VirtualStopFoundSecondary = false;
           for (VirtualStopLookupIndexSecondary = 0 ; VirtualStopLookupIndexSecondary < SmallBufferCapacity ; VirtualStopLookupIndexSecondary=VirtualStopLookupIndexSecondary + 1)
           {
             if ( VirtualStopByTicket[VirtualStopLookupIndexSecondary][0]==VirtualStopTicketSecondary )
             {
               StoredVirtualStopSecondary = VirtualStopByTicket[VirtualStopLookupIndexSecondary][1];
               VirtualStopFoundSecondary = true;
               break;
             }
           }
           if ( !(VirtualStopFoundSecondary) )
           {
             if ( VirtualStopDirectionSecondary == 1 )
             {
               StoredVirtualStopSecondary = NormalizeDouble(VirtualStopOpenPriceSecondary - VirtualStopDistancePipsSecondary * PipSize,SymbolDigits);
             }
             if ( VirtualStopDirectionSecondary == 2 )
             {
               StoredVirtualStopSecondary = NormalizeDouble(VirtualStopDistancePipsSecondary * PipSize + VirtualStopOpenPriceSecondary,SymbolDigits);
             }
             for (VirtualStopInsertIndexSecondary = 0 ; VirtualStopInsertIndexSecondary < SmallBufferCapacity ; VirtualStopInsertIndexSecondary=VirtualStopInsertIndexSecondary + 1)
             {
               if ( VirtualStopByTicket[VirtualStopInsertIndexSecondary][0]==0.0 )
               {
                 VirtualStopByTicket[VirtualStopInsertIndexSecondary][0] = (double)VirtualStopTicketSecondary;
                 VirtualStopByTicket[VirtualStopInsertIndexSecondary][1] = StoredVirtualStopSecondary;
                 break;
               }
             }
           }
           ActiveVirtualStopPrice = StoredVirtualStopSecondary ;
           OriginalStopLoss = ActiveVirtualStopPrice ;
           if ( SymbolInfoDouble(CurrentSymbol,SYMBOL_BID)<=OriginalStopLoss )
           {
             RefreshCurrentSymbolTick(); 
             ClosePositionByTicket(OrderTicket,OrderLots,SymbolInfoDouble(CurrentSymbol,SYMBOL_BID),(int)CurrentSpreadPrice,clrNONE); 
             return(true); 
           }
           VirtualStopSyncElapsedSeconds = (int)(TimeCurrent() - LastVirtualStopSyncTime) ;
           if ( VirtualStopSyncElapsedSeconds >= VirtualStopSyncIntervalSeconds )
           {
             if ( NormalizeDouble(ActiveVirtualStopPrice,SymbolDigits)>StopLossPrice + SymbolPoint )
             {
               ModifyTradeByTicket(OrderTicket,OpenPrice,NormalizeDouble(ActiveVirtualStopPrice,SymbolDigits),TakeProfitPrice,0,clrNONE); 
             }
             LastVirtualStopSyncTime = TimeCurrent() ;
           }
           if ( TimeRecoveryAfterMinutes>0.0 && TimeCurrent() >= OpenTime + TimeRecoveryDelaySeconds && SymbolInfoDouble(CurrentSymbol,SYMBOL_BID)>TimeRecoveryStopPips * PipSize + (ActiveVirtualStopPrice + SymbolPoint) && SymbolInfoDouble(CurrentSymbol,SYMBOL_BID)<TakeProfitPrice - FreezeLevelPriceDistance )
           {
             OrderStateChanged = true ;
             ActiveVirtualStopPrice = SymbolInfoDouble(CurrentSymbol,SYMBOL_BID) - TimeRecoveryStopPips * PipSize ;
           }
           if ( TrailingSLStartPips>0.0 && SymbolInfoDouble(CurrentSymbol,SYMBOL_BID)>(TrailingSLStartPips + TrailingActivationBufferPips) * PipSize + (ActiveVirtualStopPrice + SymbolPoint) && SymbolInfoDouble(CurrentSymbol,SYMBOL_BID)>TrailingSLDistancePips * PipSize + TrailReferencePrice && ActiveVirtualStopPrice<TrailingSLStepLimitPips * PipSize + OpenPrice )
           {
             OrderStateChanged = true ;
             ActiveVirtualStopPrice = SymbolInfoDouble(CurrentSymbol,SYMBOL_BID) - TrailingSLStartPips * PipSize ;
             PartialCloseLotsAfterTrail = NormalizeDouble(TrailingPartialClosePercent / 100.0 * LotSizeByStrategy[CurrentStrategyIndex],2) ;
             if ( PartialCloseLotsAfterTrail<OrderLots && PartialCloseLotsAfterTrail>=SymbolInfoDouble(CurrentSymbol,SYMBOL_VOLUME_STEP) )
             {
               ClosePositionByTicket(OrderTicket,PartialCloseLotsAfterTrail,SymbolInfoDouble(CurrentSymbol,SYMBOL_BID),(int)OrderSlippageSetting,Red); 
               return(true); 
             }
           }
           if ( ExcessiveEntrySlippage && SlippageControlMode == 1 && SlippageRecoveryTrailDistancePips>0.0 && SymbolInfoDouble(CurrentSymbol,SYMBOL_BID)>SlippageRecoveryTrailDistancePips * PipSize + (ActiveVirtualStopPrice + SymbolPoint) && SymbolInfoDouble(CurrentSymbol,SYMBOL_BID)>SlippageRecoveryTriggerPips * PipSize + RequestedEntryPrice && SymbolInfoDouble(CurrentSymbol,SYMBOL_BID)<TakeProfitPrice - FreezeLevelPriceDistance && ActiveVirtualStopPrice<SlippageRecoveryMaximumStopPips * PipSize + OpenPrice )
           {
             Print("Slippage control active"); 
             OrderStateChanged = true ;
             ActiveVirtualStopPrice = SymbolInfoDouble(CurrentSymbol,SYMBOL_BID) - SlippageRecoveryTrailDistancePips * PipSize ;
           }
           if ( HighLowLeftBars >  0 && HighLowRightBars >= 0 && SellTriggerPriceByStrategy[CurrentStrategyIndex]>ActiveVirtualStopPrice + StopLevelPriceDistance + SymbolPoint && ( SellTriggerPriceByStrategy[CurrentStrategyIndex]<OpenPrice || !(HighLowTrailingEnabled) ) && SellTriggerPriceByStrategy[CurrentStrategyIndex]<SymbolInfoDouble(CurrentSymbol,SYMBOL_BID) - HighLowMinimumMarketGapPips * PipSize - StopLevelPriceDistance - SymbolPoint && SymbolInfoDouble(CurrentSymbol,SYMBOL_BID)<TakeProfitPrice - FreezeLevelPriceDistance )
           {
             ActiveVirtualStopPrice = SellTriggerPriceByStrategy[CurrentStrategyIndex] ;
             OrderStateChanged = true ;
           }
           if ( BreakEvenStartPips>0.0 && TradeMonitorFilterMode == 3 && SymbolInfoDouble(CurrentSymbol,SYMBOL_BID)>BreakEvenStartPips * PipSize + OpenPrice && BreakEvenExtraPips * PipSize + OpenPrice>StopLossPrice + SymbolPoint && SymbolInfoDouble(CurrentSymbol,SYMBOL_BID)>BreakEvenExtraPips * PipSize + OpenPrice + StopLevelPriceDistance && SymbolInfoDouble(CurrentSymbol,SYMBOL_BID)<TakeProfitPrice - FreezeLevelPriceDistance && NormalizeDouble(BreakEvenExtraPips * PipSize + OpenPrice,SymbolDigits)>SelectedTradeStopLoss() )
           {
             ActiveVirtualStopPrice = NormalizeDouble(BreakEvenExtraPips * PipSize + OpenPrice,SymbolDigits) ;
             LastTradeTicket = ModifyTradeByTicket(OrderTicket,OpenPrice,ActiveVirtualStopPrice,TakeProfitPrice,0,clrNONE) ;
             if ( LastTradeTicket <= 0 )
             {
               Print("error when setting breakeven: \'" + TradeErrorDescription(LastTradeErrorCode()) + "\' ..\'Exit_BE_start\' to close to \'Exit_BE_extra_pips\' ..trying again!"); 
             }
             OrderStateChanged = true ;
           }
           if ( BreakEvenStartPips>0.0 && TradeMonitorFilterMode == 2 && SymbolInfoDouble(CurrentSymbol,SYMBOL_BID)>BreakEvenStartPips * PipSize + OpenPrice && BreakEvenExtraPips * PipSize + OpenPrice>ActiveVirtualStopPrice + SymbolPoint && SymbolInfoDouble(CurrentSymbol,SYMBOL_BID)>BreakEvenExtraPips * PipSize + OpenPrice + StopLevelPriceDistance && SymbolInfoDouble(CurrentSymbol,SYMBOL_BID)<TakeProfitPrice - FreezeLevelPriceDistance )
           {
             ActiveVirtualStopPrice = BreakEvenExtraPips * PipSize + OpenPrice ;
             OrderStateChanged = true ;
           }
           if ( !(OrderStateChanged) && ( MagicTrailMode == 1 || (MagicTrailMode == 2 && MagicTrailStepPips * PipSize + ActiveVirtualStopPrice<=MagicTrailMode2SpreadBufferPips * PipSize + (TrailReferencePrice + CurrentSpreadPrice)) ) )
           {
             MagicTrailTickCounter ++;
             if ( SymbolInfoDouble(CurrentSymbol,SYMBOL_BID)>MagicTrailStepPips * PipSize + ActiveVirtualStopPrice + StopLevelPriceDistance && SymbolInfoDouble(CurrentSymbol,SYMBOL_BID)<TakeProfitPrice - FreezeLevelPriceDistance && ( MagicTrailActivationDistancePips==0.0 || SymbolInfoDouble(CurrentSymbol,SYMBOL_BID)>ActiveMagicTrailActivationPips * PipSize + TrailReferencePrice ) && MagicTrailTickCounter >= MagicTrailMinimumTickCount )
             {
               MagicTrailTickCounter = 0 ;
               ActiveVirtualStopPrice = MagicTrailStepPips * PipSize + ActiveVirtualStopPrice ;
               OrderStateChanged = true ;
             }
           }
           if ( SymbolInfoDouble(CurrentSymbol,SYMBOL_BID)<=ActiveVirtualStopPrice )
           {
             RefreshCurrentSymbolTick(); 
             ClosePositionByTicket(OrderTicket,OrderLots,SymbolInfoDouble(CurrentSymbol,SYMBOL_BID),(int)CurrentSpreadPrice,clrNONE); 
             return(true); 
           }
           if ( NormalizeDouble(OriginalStopLoss,SymbolDigits)!=NormalizeDouble(ActiveVirtualStopPrice,SymbolDigits) )
           {
             UpdatedVirtualStopSecondary = NormalizeDouble(ActiveVirtualStopPrice,SymbolDigits);
             VirtualStopUpdateTicketSecondary = OrderTicket;
             for (VirtualStopUpdateIndexSecondary = 0 ; VirtualStopUpdateIndexSecondary < SmallBufferCapacity ; VirtualStopUpdateIndexSecondary=VirtualStopUpdateIndexSecondary + 1)
             {
               if ( VirtualStopByTicket[VirtualStopUpdateIndexSecondary][0]==VirtualStopUpdateTicketSecondary )
               {
                 VirtualStopByTicket[VirtualStopUpdateIndexSecondary][1] = UpdatedVirtualStopSecondary;
                 break;
               }
             }
           }
         }
       }
     }
     if ( OrderStateChanged )
     {
       AnyTradeChanged = true ;
     }
   }
   if ( OrderStateChanged )
   {
     AnyTradeChanged = true ;
   }
 }
 return(AnyTradeChanged); 
 }
//ManageBuyTrades <<==--------   --------
 bool ManageSellTrades()
 {
  bool      OrderStateChanged = false;
  bool      AnyTradeChanged = false;
  double    OriginalStopLoss;
  double    TrailReferencePrice;
  int       OrderScanIndex;
  double    StopLossPrice;
  double    TakeProfitPrice;
  long      OrderTicket;
  double    OpenPrice;
  string    OrderComment;
  double    OrderLots;
  datetime  OpenTime;
  int       OrderType;
  long       OrderMagic;
  string    OrderSymbol;
  double    RequestedEntryPrice;
  double    EntrySlippagePrice;
  bool      ExcessiveEntrySlippage;
  bool      ZoneRecoveryHandled;
  double    ZoneRecoveryOrderCount;
  bool      ZoneRecoveryOrderPlaced;
  double    ZoneRecoveryNextLots;
  double    ZoneRecoveryTriggerPrice;
  double    ZoneRecoveryReverseTriggerPrice;
  double    PartialCloseLots;
  double    VirtualStopPrice;
  int       VirtualStopSyncElapsedSeconds;
  double    PartialCloseLotsAfterTrail;
//----------------------------------------------------------------------
 int        PriceDigits;
 long       EntryTicketLookup;
 int        EntryPriceMapIndex;
 double     MappedRequestedEntryPrice;
 double     OpenPriceForMap;
 long       TicketForMapInsert;
 int        TicketMapInsertIndex;
 long       ZoneParentTicket;
 int        ZoneOrderCount;
 int        ZoneOrderScanIndex;
 string     ZoneOrderComment;
 double     AccountEquity;
 int        ZoneCloseAllScanIndex;
 long       ZoneProfitParentTicket;
 double     ZoneCombinedProfit;
 int        ZoneProfitScanIndex;
 long       ZoneSelectedTicket;
 long       ZoneCloseParentTicket;
 int        ZoneCloseScanIndex;
 int        ZoneMaximumTradesCloseScanIndexA;
 int        ZoneMaximumTradesCloseScanIndexB;
 string     ZoneReverseOrderComment;
 long       VirtualStopTicketPrimary;
 double     VirtualStopDistancePipsPrimary;
 double     VirtualStopOpenPricePrimary;
 int        VirtualStopDirectionPrimary;
 double     StoredVirtualStopPrimary;
 bool       VirtualStopFoundPrimary;
 int        VirtualStopLookupIndexPrimary;
 int        VirtualStopInsertIndexPrimary;
 double     UpdatedVirtualStopPrimary;
 long       VirtualStopUpdateTicketPrimary;
 int        VirtualStopUpdateIndexPrimary;
 long       VirtualStopTicketSecondary;
 double     VirtualStopDistancePipsSecondary;
 double     VirtualStopOpenPriceSecondary;
 int        VirtualStopDirectionSecondary;
 double     StoredVirtualStopSecondary;
 bool       VirtualStopFoundSecondary;
 int        VirtualStopLookupIndexSecondary;
 int        VirtualStopInsertIndexSecondary;
 double     UpdatedVirtualStopSecondary;
 long       VirtualStopUpdateTicketSecondary;
 int        VirtualStopUpdateIndexSecondary;

 OriginalStopLoss = 0.0 ;
 TrailReferencePrice = 0.0 ;
 for (OrderScanIndex = 0 ; OrderScanIndex < ActiveTradeCount() ; OrderScanIndex ++)
 {
   if ( SelectTradeRecord(OrderScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) == true )
   {
     OrderStateChanged = false ;
     StopLossPrice = NormalizeDouble(SelectedTradeStopLoss(),SymbolDigits) ;
     TakeProfitPrice = NormalizeDouble(SelectedTradeTakeProfit(),SymbolDigits) ;
     OrderTicket = SelectedTradeTicket() ;
     OpenPrice = NormalizeDouble(SelectedTradeOpenPrice(),SymbolDigits) ;
     OrderComment = SelectedTradeComment() ;
     OrderLots = SelectedTradeVolume() ;
     OpenTime = SelectedTradeOpenTime() ;
     OrderType = SelectedTradeType() ;
     OrderMagic = SelectedTradeMagic() ;
     OrderSymbol = SelectedTradeSymbol() ;
     if ( ( OrderType == 5 || OrderType == 3 ) && EntryStrategyMode == 2 && ( ManualTradeSymbolFilterMode == 0 || (ManualTradeSymbolFilterMode == 1 && OrderSymbol == CurrentSymbol) ) && ( OrderMagic == ManualStrategy2MagicNumber || ManualStrategy2MagicNumber == 0 ) && ( OrderComment == ManualStrategy2Comment || ManualStrategy2Comment == "" ) )
     {
       if ( ( StopLossPrice==0.0 || StopLossPrice==0.0 ) )
       {
         StopLossPrice = NormalizeDouble(StopLossPips * PipSize + OpenPrice,SymbolDigits) ;
         ModifyTradeByTicket(OrderTicket,OpenPrice,StopLossPrice,TakeProfitPrice,0,Green); 
       }
       if ( ( TakeProfitPrice==0.0 || TakeProfitPrice==0.0 ) )
       {
         TakeProfitPrice = NormalizeDouble(OpenPrice - TakeProfitPips * PipSize,SymbolDigits) ;
         ModifyTradeByTicket(OrderTicket,OpenPrice,StopLossPrice,TakeProfitPrice,0,Green); 
       }
     }
     if ( OrderType == 1 && ( ( OrderMagic == StrategyMagicNumber && EntryStrategyMode == 1 && OrderSymbol == CurrentSymbol ) || (EntryStrategyMode == 2 && ( ManualTradeSymbolFilterMode == 0 || (ManualTradeSymbolFilterMode == 1 && OrderSymbol == CurrentSymbol) ) && ( OrderMagic == ManualStrategy2MagicNumber || ManualStrategy2MagicNumber == 0 ) && (OrderComment == ManualStrategy2Comment || ManualStrategy2Comment == "")) ) )
     {
       if ( ( StopLossPrice==0.0 || StopLossPrice==0.0 ) )
       {
         StopLossPrice = NormalizeDouble(StopLossPips * PipSize + OpenPrice,SymbolDigits) ;
         ModifyTradeByTicket(OrderTicket,OpenPrice,StopLossPrice,TakeProfitPrice,0,Green); 
       }
       if ( ( TakeProfitPrice==0.0 || TakeProfitPrice==0.0 ) )
       {
         TakeProfitPrice = NormalizeDouble(OpenPrice - TakeProfitPips * PipSize,SymbolDigits) ;
         ModifyTradeByTicket(OrderTicket,OpenPrice,StopLossPrice,TakeProfitPrice,0,Green); 
       }
       if ( CandleExitM1Enabled && iTime(CurrentSymbol,NormalizeTimeframe(CandleExitM1TimeframeMinutes),CandleExitOpenBarShift) <= OpenTime && iTime(CurrentSymbol,NormalizeTimeframe(CandleExitM1TimeframeMinutes),0) >  OpenTime && iClose(CurrentSymbol,NormalizeTimeframe(CandleExitM1TimeframeMinutes),1)>iOpen(CurrentSymbol,NormalizeTimeframe(CandleExitM1TimeframeMinutes),1) && iClose(CurrentSymbol,NormalizeTimeframe(CandleExitM1TimeframeMinutes),1)>OpenPrice )
       {
         ClosePositionByTicket(OrderTicket,OrderLots,SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK),0,Red); 
         Print("closing candle confirmation"); 
       }
       if ( CandleExitM5Enabled && iTime(CurrentSymbol,NormalizeTimeframe(CandleExitM5TimeframeMinutes),CandleExitOpenBarShift) <= OpenTime && iTime(CurrentSymbol,NormalizeTimeframe(CandleExitM5TimeframeMinutes),0) >  OpenTime && iClose(CurrentSymbol,NormalizeTimeframe(CandleExitM5TimeframeMinutes),1)>iOpen(CurrentSymbol,NormalizeTimeframe(CandleExitM5TimeframeMinutes),1) && iClose(CurrentSymbol,NormalizeTimeframe(CandleExitM5TimeframeMinutes),1)>OpenPrice )
       {
         ClosePositionByTicket(OrderTicket,OrderLots,SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK),0,Red); 
         Print("closing candle confirmation"); 
       }
       if ( CandleExitM15Enabled && iTime(CurrentSymbol,NormalizeTimeframe(CandleExitM15TimeframeMinutes),CandleExitOpenBarShift) <= OpenTime && iTime(CurrentSymbol,NormalizeTimeframe(CandleExitM15TimeframeMinutes),0) >  OpenTime && iClose(CurrentSymbol,NormalizeTimeframe(CandleExitM15TimeframeMinutes),1)>iOpen(CurrentSymbol,NormalizeTimeframe(CandleExitM15TimeframeMinutes),1) && iClose(CurrentSymbol,NormalizeTimeframe(CandleExitM15TimeframeMinutes),1)>OpenPrice )
       {
         ClosePositionByTicket(OrderTicket,OrderLots,SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK),0,Red); 
         Print("closing candle confirmation"); 
       }
       if ( CandleExitM30Enabled && iTime(CurrentSymbol,NormalizeTimeframe(CandleExitM30TimeframeMinutes),CandleExitOpenBarShift) <= OpenTime && iTime(CurrentSymbol,NormalizeTimeframe(CandleExitM30TimeframeMinutes),0) >  OpenTime && iClose(CurrentSymbol,NormalizeTimeframe(CandleExitM30TimeframeMinutes),1)>iOpen(CurrentSymbol,NormalizeTimeframe(CandleExitM30TimeframeMinutes),1) && iClose(CurrentSymbol,NormalizeTimeframe(CandleExitM30TimeframeMinutes),1)>OpenPrice )
       {
         ClosePositionByTicket(OrderTicket,OrderLots,SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK),0,Red); 
         Print("closing candle confirmation"); 
       }
       if ( CandleExitH1Enabled && iTime(CurrentSymbol,NormalizeTimeframe(CandleExitH1TimeframeMinutes),CandleExitOpenBarShift) <= OpenTime && iTime(CurrentSymbol,NormalizeTimeframe(CandleExitH1TimeframeMinutes),0) >  OpenTime && iClose(CurrentSymbol,NormalizeTimeframe(CandleExitH1TimeframeMinutes),1)>iOpen(CurrentSymbol,NormalizeTimeframe(CandleExitH1TimeframeMinutes),1) && iClose(CurrentSymbol,NormalizeTimeframe(CandleExitH1TimeframeMinutes),1)>OpenPrice )
       {
         ClosePositionByTicket(OrderTicket,OrderLots,SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK),0,Red); 
         Print("closing candle confirmation"); 
       }
       ActiveMagicTrailActivationPips = MagicTrailActivationDistancePips ;
       if ( MagicTrailDelayMinutes >  0 && TimeCurrent() >  OpenTime + MagicTrailDelayMinutes * 60 )
       {
         ActiveMagicTrailActivationPips = MagicTrailDelayedActivationPips ;
       }
       PriceDigits = SymbolDigits;
       EntryTicketLookup = OrderTicket;
       for (EntryPriceMapIndex = 0 ; EntryPriceMapIndex < 100 ; EntryPriceMapIndex=EntryPriceMapIndex + 1)
       {
         if ( !(PendingTicketPriceMap[EntryPriceMapIndex][0]==EntryTicketLookup) )   continue;
         MappedRequestedEntryPrice = PendingTicketPriceMap[EntryPriceMapIndex][1];
         break;
         
       }
       MappedRequestedEntryPrice = 0.0;
       RequestedEntryPrice = NormalizeDouble(MappedRequestedEntryPrice,PriceDigits) ;
       if ( RequestedEntryPrice==0.0 )
       {
         OpenPriceForMap = OpenPrice;
         TicketForMapInsert = OrderTicket;
         for (TicketMapInsertIndex = 0 ; TicketMapInsertIndex < 100 ; TicketMapInsertIndex=TicketMapInsertIndex + 1)
         {
           if ( !(PendingTicketPriceMap[TicketMapInsertIndex][0]==0.0) )   continue;
           PendingTicketPriceMap[TicketMapInsertIndex][0] = (double)TicketForMapInsert;
           PendingTicketPriceMap[TicketMapInsertIndex][1] = OpenPriceForMap;
           break;
           
         }
         RequestedEntryPrice = OpenPrice ;
       }
       else
       {
         RequestedEntryPrice = RequestedEntryPrice - RequestedEntryAdjustmentPips * PipSize ;
       }
       EntrySlippagePrice = RequestedEntryPrice - OpenPrice ;
       ExcessiveEntrySlippage = false ;
       if ( RequestedEntryPrice>RequestedEntryAdjustmentPips * PipSize && EntrySlippagePrice>OrderSlippageSetting * PipSize )
       {
         ExcessiveEntrySlippage = true ;
         if ( SlippageControlMode == 2 )
         {
           ActiveMagicTrailActivationPips = -1000.0 ;
           Print("Slippage Mode 2 active"); 
         }
       }
       if ( UseRequestedEntryAsTrailReference )
       {
         TrailReferencePrice = RequestedEntryPrice ;
       }
       else
       {
         TrailReferencePrice = OpenPrice ;
       }
       if ( StopLossPrice>NormalizeDouble((StopLossPips + ExtraStopLossPips) * PipSize + OpenPrice + CurrentSpreadPrice,SymbolDigits) )
       {
         StopLossPrice = NormalizeDouble((StopLossPips + ExtraStopLossPips) * PipSize + OpenPrice + CurrentSpreadPrice,SymbolDigits) ;
         ModifyTradeByTicket(OrderTicket,OpenPrice,StopLossPrice,TakeProfitPrice,0,clrNONE); 
       }
       if ( SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK)>(StopLossPips + ExtraStopLossPips) * PipSize + OpenPrice + CurrentSpreadPrice )
       {
         RefreshCurrentSymbolTick(); 
         ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK),(int)CurrentSpreadPrice,Red); 
         return(true); 
       }
       ZoneRecoveryHandled = false ;
       if ( ZoneRecoveryEnabled )
       {
         ZoneParentTicket = OrderTicket;
         ZoneOrderCount = 0;
         for (ZoneOrderScanIndex = ActiveTradeCount() ; ZoneOrderScanIndex >= 0 ; ZoneOrderScanIndex=ZoneOrderScanIndex - 1)
         {
           if ( SelectTradeRecord(ZoneOrderScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != ZoneRecoverySellMagic || SelectedTradeSymbol() != CurrentSymbol )   continue;
           ZoneOrderComment = SelectedTradeComment();
           if ( ZoneOrderComment != IntegerToString(ZoneParentTicket,0,32) )   continue;
           ZoneOrderCount=ZoneOrderCount + 1;
           
         }
         ZoneRecoveryOrderCount = ZoneOrderCount ;
         ZoneRecoveryOrderPlaced = false ;
         if ( !(SellZoneStateInitialized) )
         {
           SellZoneStateInitialized = true ;
           SellZoneNextOrderSide = 1 ;
         }
         if ( ZoneRecoveryOrderCount==0.0 )
         {
           SellZoneNextOrderSide = 1 ;
         }
         if ( MathFloor(ZoneRecoveryOrderCount / 2.0)==ZoneRecoveryOrderCount / 2.0 )
         {
           SellZoneNextOrderSide = 1 ;
         }
         else
         {
           SellZoneNextOrderSide = 0 ;
         }
         if ( SellZoneStateInitialized )
         {
           if ( ZoneRecoveryOrderCount>0.0 )
           {
             AccountEquity = AccountInfoDouble(ACCOUNT_EQUITY);
             if ( AccountEquity>AccountInfoDouble(ACCOUNT_BALANCE) + ZoneRecoveryProfitTarget )
             {
               for (ZoneCloseAllScanIndex = ActiveTradeCount() ; ZoneCloseAllScanIndex >= 0 ; ZoneCloseAllScanIndex=ZoneCloseAllScanIndex - 1)
               {
                 if ( SelectTradeRecord(ZoneCloseAllScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true )   continue;
                 
                 if ( ( SelectedTradeMagic() != StrategyMagicNumber && SelectedTradeMagic() != ZoneRecoverySellMagic && SelectedTradeMagic() != ZoneRecoveryBuyMagic ) )   continue;
                 
                 if ( SelectedTradeType() == ORDER_TYPE_BUY )
                 {
                   ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(CurrentSymbol,SYMBOL_BID),(int)OrderSlippageSetting,Red); 
                 }
                 if ( SelectedTradeType() != ORDER_TYPE_SELL )   continue;
                 ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK),(int)OrderSlippageSetting,Red); 
                 
               }
             }
           }
           if ( ZoneRecoveryOrderCount>0.0 )
           {
             ZoneProfitParentTicket = OrderTicket;
             ZoneCombinedProfit = 0.0;
             for (ZoneProfitScanIndex = ActiveTradeCount() ; ZoneProfitScanIndex >= 0 ; ZoneProfitScanIndex=ZoneProfitScanIndex - 1)
             {
               if ( SelectTradeRecord(ZoneProfitScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true )   continue;
               ZoneSelectedTicket = SelectedTradeTicket();
               if ( ZoneSelectedTicket != ZoneProfitParentTicket )
               {
                 ZoneOrderComment = SelectedTradeComment();
               if ( ZoneOrderComment != IntegerToString(ZoneProfitParentTicket,0,32) )   continue;
               }
               ZoneCombinedProfit = ZoneCombinedProfit + SelectedTradeProfit();
               
             }
             if ( ZoneCombinedProfit>ZoneRecoveryProfitTarget )
             {
               Print("Closing zone"); 
               ZoneCloseParentTicket = OrderTicket;
               for (ZoneCloseScanIndex = ActiveTradeCount() ; ZoneCloseScanIndex >= 0 ; ZoneCloseScanIndex=ZoneCloseScanIndex - 1)
               {
                 if ( SelectTradeRecord(ZoneCloseScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true )   continue;
                 
                 if ( SelectedTradeMagic() == StrategyMagicNumber && SelectedTradeTicket() == ZoneCloseParentTicket )
                 {
                   ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK),3,Red); 
                 }
                 if ( SelectedTradeMagic() != ZoneRecoverySellMagic )   continue;
                 ZoneOrderComment = SelectedTradeComment();
                 if ( ZoneOrderComment != IntegerToString(ZoneCloseParentTicket,0,32) )   continue;
                 
                 if ( SelectedTradeType() == ORDER_TYPE_BUY )
                 {
                   ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(CurrentSymbol,SYMBOL_BID),(int)OrderSlippageSetting,Red); 
                 }
                 if ( SelectedTradeType() != ORDER_TYPE_SELL )   continue;
                 ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK),(int)OrderSlippageSetting,Red); 
                 
               }
               SellZoneStateInitialized = false ;
               ZoneRecoveryHandled = true ;
             }
           }
           else
           {
             ZoneRecoveryNextLots = OrderLots * ZoneRecoveryLotMultiplier ;
             if ( ZoneRecoveryLotSizingMode == 2 )
             {
               ZoneRecoveryNextLots = (ZoneRecoveryOrderCount + 1.0) * OrderLots + OrderLots ;
             }
             if ( ZoneRecoveryLotSizingMode == 3 )
             {
               ZoneRecoveryNextLots = OrderLots * (MathPow(ZoneRecoveryLotMultiplier,ZoneRecoveryOrderCount + 1.0)) ;
             }
             if ( SellZoneNextOrderSide == 0 )
             {
               ZoneRecoveryTriggerPrice = RequestedEntryPrice ;
               if ( SymbolInfoDouble(CurrentSymbol,SYMBOL_BID)<RequestedEntryPrice )
               {
                 if ( ZoneRecoveryOrderCount>=ZoneRecoveryMaximumTrades )
                 {
                   for (ZoneMaximumTradesCloseScanIndexA = ActiveTradeCount() ; ZoneMaximumTradesCloseScanIndexA >= 0 ; ZoneMaximumTradesCloseScanIndexA=ZoneMaximumTradesCloseScanIndexA - 1)
                   {
                     if ( SelectTradeRecord(ZoneMaximumTradesCloseScanIndexA,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true )   continue;
                     
                     if ( SelectedTradeMagic() == StrategyMagicNumber && SelectedTradeTicket() == OrderTicket )
                     {
                       ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK),3,Red); 
                     }
                     if ( SelectedTradeMagic() != ZoneRecoverySellMagic )   continue;
                     ZoneOrderComment = SelectedTradeComment();
                     if ( ZoneOrderComment != IntegerToString(OrderTicket,0,32) )   continue;
                     
                     if ( SelectedTradeType() == ORDER_TYPE_BUY )
                     {
                       ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(CurrentSymbol,SYMBOL_BID),(int)OrderSlippageSetting,Red); 
                     }
                     if ( SelectedTradeType() != ORDER_TYPE_SELL )   continue;
                     ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK),(int)OrderSlippageSetting,Red); 
                     
                   }
                 }
                 else
                 {
                   SendTradeOrder(CurrentSymbol,ORDER_TYPE_SELL,ZoneRecoveryNextLots,SymbolInfoDouble(CurrentSymbol,SYMBOL_BID),(int)OrderSlippageSetting,0.0,0.0,IntegerToString(OrderTicket,0,32),ZoneRecoverySellMagic,0,Green); 
                   SellZoneNextOrderSide = 1 ;
                   ZoneRecoveryOrderPlaced = true ;
                 }
               }
             }
             else
             {
               ZoneRecoveryReverseTriggerPrice = ZoneRecoveryInitialDistancePips * PipSize + RequestedEntryPrice - ZoneRecoveryOrderCount * ZoneRecoveryStepDistancePips * PipSize ;
               if ( ZoneRecoveryReverseTriggerPrice<ZoneRecoveryMinimumDistancePips * PipSize + RequestedEntryPrice )
               {
                 ZoneRecoveryReverseTriggerPrice = ZoneRecoveryMinimumDistancePips * PipSize + RequestedEntryPrice ;
               }
               if ( SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK)>ZoneRecoveryReverseTriggerPrice )
               {
                 if ( ZoneRecoveryOrderCount>=ZoneRecoveryMaximumTrades )
                 {
                   for (ZoneMaximumTradesCloseScanIndexB = ActiveTradeCount() ; ZoneMaximumTradesCloseScanIndexB >= 0 ; ZoneMaximumTradesCloseScanIndexB=ZoneMaximumTradesCloseScanIndexB - 1)
                   {
                     if ( SelectTradeRecord(ZoneMaximumTradesCloseScanIndexB,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true )   continue;
                     
                     if ( SelectedTradeMagic() == StrategyMagicNumber && SelectedTradeTicket() == OrderTicket )
                     {
                       ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK),3,Red); 
                     }
                     if ( SelectedTradeMagic() != ZoneRecoverySellMagic )   continue;
                     ZoneReverseOrderComment = SelectedTradeComment();
                     if ( ZoneReverseOrderComment != IntegerToString(OrderTicket,0,32) )   continue;
                     
                     if ( SelectedTradeType() == ORDER_TYPE_BUY )
                     {
                       ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(CurrentSymbol,SYMBOL_BID),(int)OrderSlippageSetting,Red); 
                     }
                     if ( SelectedTradeType() != ORDER_TYPE_SELL )   continue;
                     ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK),(int)OrderSlippageSetting,Red); 
                     
                   }
                 }
                 else
                 {
                   SendTradeOrder(CurrentSymbol,ORDER_TYPE_BUY,ZoneRecoveryNextLots,SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK),(int)OrderSlippageSetting,0.0,0.0,IntegerToString(OrderTicket,0,32),ZoneRecoverySellMagic,0,Green); 
                   SellZoneNextOrderSide = 0 ;
                   ZoneRecoveryOrderPlaced = true ;
                 }
               }
             }
           }
         }
         if ( ( ZoneRecoveryOrderCount>0.0 || ZoneRecoveryOrderPlaced ) )
         {
           ZoneRecoveryHandled = true ;
         }
       }
       if ( !(ZoneRecoveryHandled) )
       {
         if ( ( TradeMonitorFilterMode == 1 || (TradeMonitorFilterMode != 2 && TradeMonitorFilterMode != 3) ) )
         {
           VirtualStopTicketPrimary = OrderTicket;
           VirtualStopDistancePipsPrimary = StopLossPips;
           VirtualStopOpenPricePrimary = OpenPrice;
           VirtualStopDirectionPrimary = 2;
           StoredVirtualStopPrimary = 0.0;
           VirtualStopFoundPrimary = false;
           for (VirtualStopLookupIndexPrimary = 0 ; VirtualStopLookupIndexPrimary < SmallBufferCapacity ; VirtualStopLookupIndexPrimary=VirtualStopLookupIndexPrimary + 1)
           {
             if ( VirtualStopByTicket[VirtualStopLookupIndexPrimary][0]==VirtualStopTicketPrimary )
             {
               StoredVirtualStopPrimary = VirtualStopByTicket[VirtualStopLookupIndexPrimary][1];
               VirtualStopFoundPrimary = true;
               break;
             }
           }
           if ( !(VirtualStopFoundPrimary) )
           {
             if ( VirtualStopDirectionPrimary == 1 )
             {
               StoredVirtualStopPrimary = NormalizeDouble(VirtualStopOpenPricePrimary - VirtualStopDistancePipsPrimary * PipSize,SymbolDigits);
             }
             if ( VirtualStopDirectionPrimary == 2 )
             {
               StoredVirtualStopPrimary = NormalizeDouble(VirtualStopDistancePipsPrimary * PipSize + VirtualStopOpenPricePrimary,SymbolDigits);
             }
             for (VirtualStopInsertIndexPrimary = 0 ; VirtualStopInsertIndexPrimary < SmallBufferCapacity ; VirtualStopInsertIndexPrimary=VirtualStopInsertIndexPrimary + 1)
             {
               if ( VirtualStopByTicket[VirtualStopInsertIndexPrimary][0]==0.0 )
               {
                 VirtualStopByTicket[VirtualStopInsertIndexPrimary][0] = (double)VirtualStopTicketPrimary;
                 VirtualStopByTicket[VirtualStopInsertIndexPrimary][1] = StoredVirtualStopPrimary;
                 break;
               }
             }
           }
           ActiveVirtualStopPrice = StoredVirtualStopPrimary ;
           OriginalStopLoss = ActiveVirtualStopPrice ;
           if ( SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK)>OriginalStopLoss )
           {
             Print("Closing with virtual SL"); 
             RefreshCurrentSymbolTick(); 
             ClosePositionByTicket(OrderTicket,OrderLots,SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK),(int)CurrentSpreadPrice,clrNONE); 
             return(true); 
           }
           if ( TimeRecoveryAfterMinutes>0.0 && TimeCurrent() >= OpenTime + TimeRecoveryDelaySeconds && SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK)<StopLossPrice - SymbolPoint - TimeRecoveryStopPips * PipSize && SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK)>TakeProfitPrice + FreezeLevelPriceDistance && NormalizeDouble(SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK) + TimeRecoveryStopPips * PipSize,SymbolDigits)<StopLossPrice )
           {
             StopLossPrice = NormalizeDouble(SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK) + TimeRecoveryStopPips * PipSize,SymbolDigits) ;
             if ( StopLossPrice>SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK) + StopLevelPriceDistance )
             {
               LastTradeTicket = ModifyTradeByTicket(OrderTicket,OpenPrice,StopLossPrice,TakeProfitPrice,0,clrNONE) ;
               if ( LastTradeTicket <= 0 )
               {
                 Print("TrailStop error: \'" + TradeErrorDescription(LastTradeErrorCode()) + "\' when setting trailing Exit_TrailSL_after_X_Minutes_size loss.  Trying again!"); 
               }
               OrderStateChanged = true ;
             }
           }
           if ( TrailingSLStartPips>0.0 && SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK)<StopLossPrice - SymbolPoint - (TrailingSLStartPips + TrailingActivationBufferPips) * PipSize && SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK)<TrailReferencePrice - TrailingSLDistancePips * PipSize && SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK)>TakeProfitPrice + FreezeLevelPriceDistance && StopLossPrice>OpenPrice - TrailingSLStepLimitPips * PipSize && NormalizeDouble(TrailingSLStartPips * PipSize + SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK),SymbolDigits)<StopLossPrice )
           {
             StopLossPrice = NormalizeDouble(SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK) + TrailingSLStartPips * PipSize,SymbolDigits) ;
             if ( StopLossPrice>SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK) + StopLevelPriceDistance )
             {
               LastTradeTicket = ModifyTradeByTicket(OrderTicket,OpenPrice,StopLossPrice,TakeProfitPrice,0,clrNONE) ;
               if ( LastTradeTicket <= 0 )
               {
                 Print("TrailStop error: \'" + TradeErrorDescription(LastTradeErrorCode()) + "\' when setting trailing Exit_stop loss.  Trying again!"); 
               }
               else
               {
                 PartialCloseLots = NormalizeDouble(TrailingPartialClosePercent / 100.0 * LotSizeByStrategy[CurrentStrategyIndex],2) ;
                 if ( PartialCloseLots<OrderLots && PartialCloseLots>=SymbolInfoDouble(CurrentSymbol,SYMBOL_VOLUME_STEP) )
                 {
                   ClosePositionByTicket(OrderTicket,PartialCloseLots,SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK),(int)OrderSlippageSetting,Red); 
                   return(true); 
                 }
               }
               OrderStateChanged = true ;
             }
           }
           if ( TrailingTPStartPips>0.0 && SymbolInfoDouble(CurrentSymbol,SYMBOL_BID)>NormalizeDouble(TrailingTPStartPips * PipSize + (TakeProfitPrice + SymbolPoint),SymbolDigits) && SymbolInfoDouble(CurrentSymbol,SYMBOL_BID)>NormalizeDouble(TrailingTPDistancePips * PipSize + TrailReferencePrice,SymbolDigits) && SymbolInfoDouble(CurrentSymbol,SYMBOL_BID)>TakeProfitPrice + FreezeLevelPriceDistance )
           {
             TakeProfitPrice = NormalizeDouble(SymbolInfoDouble(CurrentSymbol,SYMBOL_BID) - TrailingTPStartPips * PipSize,SymbolDigits) ;
             if ( TakeProfitPrice<SymbolInfoDouble(CurrentSymbol,SYMBOL_BID) - StopLevelPriceDistance )
             {
               LastTradeTicket = ModifyTradeByTicket(OrderTicket,OpenPrice,StopLossPrice,TakeProfitPrice,0,clrNONE) ;
               if ( LastTradeTicket <= 0 )
               {
                 Print("TrailStop error: \'" + TradeErrorDescription(LastTradeErrorCode()) + "\' when setting trailing Exit_TP.  Trying again!"); 
               }
               else
               {
                 VirtualStopPrice = NormalizeDouble(TrailingPartialClosePercent / 100.0 * LotSizeByStrategy[CurrentStrategyIndex],2) ;
                 if ( VirtualStopPrice<OrderLots && VirtualStopPrice>=SymbolInfoDouble(CurrentSymbol,SYMBOL_VOLUME_MIN) )
                 {
                   ClosePositionByTicket(OrderTicket,VirtualStopPrice,SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK),(int)OrderSlippageSetting,Red); 
                   return(true); 
                 }
               }
               OrderStateChanged = true ;
             }
           }
           if ( ExcessiveEntrySlippage && SlippageControlMode == 1 && SlippageRecoveryTrailDistancePips>0.0 && SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK)<StopLossPrice - SymbolPoint - SlippageRecoveryTrailDistancePips * PipSize && SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK)<RequestedEntryPrice - SlippageRecoveryTriggerPips * PipSize && SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK)>TakeProfitPrice + FreezeLevelPriceDistance && StopLossPrice>OpenPrice - SlippageRecoveryMaximumStopPips * PipSize && NormalizeDouble(SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK) + SlippageRecoveryTrailDistancePips * PipSize,SymbolDigits)<StopLossPrice )
           {
             StopLossPrice = NormalizeDouble(SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK) + SlippageRecoveryTrailDistancePips * PipSize,SymbolDigits) ;
             if ( StopLossPrice>SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK) + StopLevelPriceDistance )
             {
               LastTradeTicket = ModifyTradeByTicket(OrderTicket,OpenPrice,StopLossPrice,TakeProfitPrice,0,clrNONE) ;
               if ( LastTradeTicket <= 0 )
               {
                 Print("TrailStop error: \'" + TradeErrorDescription(LastTradeErrorCode()) + "\' when setting Slip TL.  Trying again!"); 
               }
               else
               {
                 Print("Slippage controle active"); 
               }
               OrderStateChanged = true ;
             }
           }
           if ( HighLowLeftBars >  0 && HighLowRightBars >= 0 && UseHL_TrailingSL && BuyTriggerPriceByStrategy[CurrentStrategyIndex]<StopLossPrice - StopLevelPriceDistance - SymbolPoint && BuyTriggerPriceByStrategy[CurrentStrategyIndex]>HighLowLookbackBars * PipSize + SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK) && ( BuyTriggerPriceByStrategy[CurrentStrategyIndex]>OpenPrice || !(HighLowTrailingEnabled) ) && BuyTriggerPriceByStrategy[CurrentStrategyIndex]>HighLowMinimumMarketGapPips * PipSize + SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK) + StopLevelPriceDistance + SymbolPoint && SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK)>TakeProfitPrice + FreezeLevelPriceDistance && NormalizeDouble(BuyTriggerPriceByStrategy[CurrentStrategyIndex],SymbolDigits)<StopLossPrice )
           {
             StopLossPrice = NormalizeDouble(BuyTriggerPriceByStrategy[CurrentStrategyIndex],SymbolDigits) ;
             if ( StopLossPrice>SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK) + StopLevelPriceDistance )
             {
               LastTradeTicket = ModifyTradeByTicket(OrderTicket,OpenPrice,StopLossPrice,TakeProfitPrice,0,clrNONE) ;
               if ( LastTradeTicket <= 0 )
               {
                 Print("error: \'" + TradeErrorDescription(LastTradeErrorCode()) + "\' when modifying stoploss"); 
               }
               OrderStateChanged = true ;
             }
           }
           if ( BreakEvenStartPips>0.0 && SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK)<OpenPrice - BreakEvenStartPips * PipSize && OpenPrice - BreakEvenExtraPips * PipSize<StopLossPrice - SymbolPoint && SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK)<OpenPrice - BreakEvenExtraPips * PipSize - StopLevelPriceDistance && SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK)>TakeProfitPrice + FreezeLevelPriceDistance && NormalizeDouble(OpenPrice - BreakEvenExtraPips * PipSize,SymbolDigits)<StopLossPrice )
           {
             StopLossPrice = NormalizeDouble(OpenPrice - BreakEvenExtraPips * PipSize,SymbolDigits) ;
             if ( StopLossPrice>SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK) + StopLevelPriceDistance )
             {
               LastTradeTicket = ModifyTradeByTicket(OrderTicket,OpenPrice,StopLossPrice,TakeProfitPrice,0,clrNONE) ;
               if ( LastTradeTicket <= 0 )
               {
                 Print("error when setting breakeven: \'" + TradeErrorDescription(LastTradeErrorCode()) + "\' ..\'Exit_BE_start\' to close to \'Exit_BE_extra_pips\' ..trying again!"); 
               }
               OrderStateChanged = true ;
             }
           }
           if ( !(OrderStateChanged) && ( MagicTrailMode == 1 || (MagicTrailMode == 2 && StopLossPrice - MagicTrailStepPips * PipSize>=TrailReferencePrice - CurrentSpreadPrice - MagicTrailMode2SpreadBufferPips * PipSize) ) )
           {
             MagicTrailTickCounter ++;
             if ( SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK)<StopLossPrice - MagicTrailStepPips * PipSize - StopLevelPriceDistance && SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK)>TakeProfitPrice + FreezeLevelPriceDistance && ( MagicTrailActivationDistancePips==0.0 || SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK)<TrailReferencePrice - ActiveMagicTrailActivationPips * PipSize ) && MagicTrailTickCounter >= MagicTrailMinimumTickCount && NormalizeDouble(StopLossPrice - MagicTrailStepPips * PipSize,SymbolDigits)<StopLossPrice )
             {
               MagicTrailTickCounter = 0 ;
               StopLossPrice = NormalizeDouble(StopLossPrice - MagicTrailStepPips * PipSize,SymbolDigits) ;
               ModifyTradeByTicket(OrderTicket,OpenPrice,StopLossPrice,TakeProfitPrice,0,clrNONE); 
               OrderStateChanged = true ;
             }
           }
           ActiveVirtualStopPrice = StopLossPrice ;
           if ( SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK)>StopLossPrice )
           {
             Print("Closing with virtual SL"); 
             RefreshCurrentSymbolTick(); 
             ClosePositionByTicket(OrderTicket,OrderLots,SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK),(int)CurrentSpreadPrice,clrNONE); 
             return(true); 
           }
           if ( NormalizeDouble(OriginalStopLoss,SymbolDigits)!=NormalizeDouble(ActiveVirtualStopPrice,SymbolDigits) )
           {
             UpdatedVirtualStopPrimary = NormalizeDouble(ActiveVirtualStopPrice,SymbolDigits);
             VirtualStopUpdateTicketPrimary = OrderTicket;
             for (VirtualStopUpdateIndexPrimary = 0 ; VirtualStopUpdateIndexPrimary < SmallBufferCapacity ; VirtualStopUpdateIndexPrimary=VirtualStopUpdateIndexPrimary + 1)
             {
               if ( VirtualStopByTicket[VirtualStopUpdateIndexPrimary][0]==VirtualStopUpdateTicketPrimary )
               {
                 VirtualStopByTicket[VirtualStopUpdateIndexPrimary][1] = UpdatedVirtualStopPrimary;
                 break;
               }
             }
           }
           if ( OrderStateChanged && ReturnAfterStopModification )
           {
             return(true); 
           }
         }
         if ( ( TradeMonitorFilterMode == 2 || TradeMonitorFilterMode == 3 ) )
         {
           VirtualStopTicketSecondary = OrderTicket;
           VirtualStopDistancePipsSecondary = StopLossPips;
           VirtualStopOpenPriceSecondary = OpenPrice;
           VirtualStopDirectionSecondary = 2;
           StoredVirtualStopSecondary = 0.0;
           VirtualStopFoundSecondary = false;
           for (VirtualStopLookupIndexSecondary = 0 ; VirtualStopLookupIndexSecondary < SmallBufferCapacity ; VirtualStopLookupIndexSecondary=VirtualStopLookupIndexSecondary + 1)
           {
             if ( VirtualStopByTicket[VirtualStopLookupIndexSecondary][0]==VirtualStopTicketSecondary )
             {
               StoredVirtualStopSecondary = VirtualStopByTicket[VirtualStopLookupIndexSecondary][1];
               VirtualStopFoundSecondary = true;
               break;
             }
           }
           if ( !(VirtualStopFoundSecondary) )
           {
             if ( VirtualStopDirectionSecondary == 1 )
             {
               StoredVirtualStopSecondary = NormalizeDouble(VirtualStopOpenPriceSecondary - VirtualStopDistancePipsSecondary * PipSize,SymbolDigits);
             }
             if ( VirtualStopDirectionSecondary == 2 )
             {
               StoredVirtualStopSecondary = NormalizeDouble(VirtualStopDistancePipsSecondary * PipSize + VirtualStopOpenPriceSecondary,SymbolDigits);
             }
             for (VirtualStopInsertIndexSecondary = 0 ; VirtualStopInsertIndexSecondary < SmallBufferCapacity ; VirtualStopInsertIndexSecondary=VirtualStopInsertIndexSecondary + 1)
             {
               if ( VirtualStopByTicket[VirtualStopInsertIndexSecondary][0]==0.0 )
               {
                 VirtualStopByTicket[VirtualStopInsertIndexSecondary][0] = (double)VirtualStopTicketSecondary;
                 VirtualStopByTicket[VirtualStopInsertIndexSecondary][1] = StoredVirtualStopSecondary;
                 break;
               }
             }
           }
           ActiveVirtualStopPrice = StoredVirtualStopSecondary ;
           OriginalStopLoss = ActiveVirtualStopPrice ;
           if ( SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK)>=OriginalStopLoss )
           {
             RefreshCurrentSymbolTick(); 
             ClosePositionByTicket(OrderTicket,OrderLots,SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK),(int)CurrentSpreadPrice,clrNONE); 
             return(true); 
           }
           VirtualStopSyncElapsedSeconds = (int)(TimeCurrent() - LastVirtualStopSyncTime) ;
           if ( VirtualStopSyncElapsedSeconds >= VirtualStopSyncIntervalSeconds )
           {
             if ( NormalizeDouble(ActiveVirtualStopPrice,SymbolDigits)<StopLossPrice - SymbolPoint )
             {
               ModifyTradeByTicket(OrderTicket,OpenPrice,NormalizeDouble(ActiveVirtualStopPrice,SymbolDigits),TakeProfitPrice,0,clrNONE); 
             }
             LastVirtualStopSyncTime = TimeCurrent() ;
           }
           if ( TimeRecoveryAfterMinutes>0.0 && TimeCurrent() >= OpenTime + TimeRecoveryDelaySeconds && SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK)<ActiveVirtualStopPrice - SymbolPoint - TimeRecoveryStopPips * PipSize && SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK)>TakeProfitPrice + FreezeLevelPriceDistance )
           {
             ActiveVirtualStopPrice = SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK) + TimeRecoveryStopPips * PipSize ;
             OrderStateChanged = true ;
           }
           if ( TrailingSLStartPips>0.0 && SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK)<ActiveVirtualStopPrice - SymbolPoint - (TrailingSLStartPips + TrailingActivationBufferPips) * PipSize && SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK)<TrailReferencePrice - TrailingSLDistancePips * PipSize && ActiveVirtualStopPrice>OpenPrice - TrailingSLStepLimitPips * PipSize )
           {
             ActiveVirtualStopPrice = TrailingSLStartPips * PipSize + SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK) ;
             PartialCloseLotsAfterTrail = NormalizeDouble(TrailingPartialClosePercent / 100.0 * LotSizeByStrategy[CurrentStrategyIndex],2) ;
             if ( PartialCloseLotsAfterTrail<OrderLots && PartialCloseLotsAfterTrail>=SymbolInfoDouble(CurrentSymbol,SYMBOL_VOLUME_STEP) )
             {
               ClosePositionByTicket(OrderTicket,PartialCloseLotsAfterTrail,SymbolInfoDouble(CurrentSymbol,SYMBOL_BID),(int)OrderSlippageSetting,Red); 
               return(true); 
             }
             OrderStateChanged = true ;
           }
           if ( ExcessiveEntrySlippage && SlippageControlMode == 1 && SlippageRecoveryTrailDistancePips>0.0 && SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK)<ActiveVirtualStopPrice - SymbolPoint - SlippageRecoveryTrailDistancePips * PipSize && SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK)<RequestedEntryPrice - SlippageRecoveryTriggerPips * PipSize && SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK)>TakeProfitPrice + FreezeLevelPriceDistance && ActiveVirtualStopPrice>OpenPrice - SlippageRecoveryMaximumStopPips * PipSize )
           {
             Print("Slippage controle active"); 
             OrderStateChanged = true ;
             ActiveVirtualStopPrice = SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK) + SlippageRecoveryTrailDistancePips * PipSize ;
           }
           if ( HighLowLeftBars >  0 && HighLowRightBars >= 0 && BuyTriggerPriceByStrategy[CurrentStrategyIndex]<ActiveVirtualStopPrice - StopLevelPriceDistance - SymbolPoint && ( BuyTriggerPriceByStrategy[CurrentStrategyIndex]>OpenPrice || !(HighLowTrailingEnabled) ) && BuyTriggerPriceByStrategy[CurrentStrategyIndex]>HighLowMinimumMarketGapPips * PipSize + SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK) + StopLevelPriceDistance + SymbolPoint && SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK)>TakeProfitPrice + FreezeLevelPriceDistance )
           {
             ActiveVirtualStopPrice = BuyTriggerPriceByStrategy[CurrentStrategyIndex] ;
             OrderStateChanged = true ;
           }
           if ( BreakEvenStartPips>0.0 && TradeMonitorFilterMode == 3 && SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK)<OpenPrice - BreakEvenStartPips * PipSize && OpenPrice - BreakEvenExtraPips * PipSize<StopLossPrice - SymbolPoint && SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK)<OpenPrice - BreakEvenExtraPips * PipSize - StopLevelPriceDistance && SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK)>TakeProfitPrice + FreezeLevelPriceDistance && NormalizeDouble(OpenPrice - BreakEvenExtraPips * PipSize,SymbolDigits)<ActiveVirtualStopPrice )
           {
             ActiveVirtualStopPrice = NormalizeDouble(OpenPrice - BreakEvenExtraPips * PipSize,SymbolDigits) ;
             LastTradeTicket = ModifyTradeByTicket(OrderTicket,OpenPrice,ActiveVirtualStopPrice,TakeProfitPrice,0,clrNONE) ;
             if ( LastTradeTicket <= 0 )
             {
               Print("error when setting breakeven: \'" + TradeErrorDescription(LastTradeErrorCode()) + "\' ..\'Exit_BE_start\' to close to \'Exit_BE_extra_pips\' ..trying again!"); 
             }
             OrderStateChanged = true ;
           }
           if ( BreakEvenStartPips>0.0 && TradeMonitorFilterMode == 2 && SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK)<OpenPrice - BreakEvenStartPips * PipSize && OpenPrice - BreakEvenExtraPips * PipSize<ActiveVirtualStopPrice - SymbolPoint && SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK)<OpenPrice - BreakEvenExtraPips * PipSize - StopLevelPriceDistance && SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK)>TakeProfitPrice + FreezeLevelPriceDistance )
           {
             ActiveVirtualStopPrice = OpenPrice - BreakEvenExtraPips * PipSize ;
             OrderStateChanged = true ;
           }
           if ( !(OrderStateChanged) && ( MagicTrailMode == 1 || (MagicTrailMode == 2 && ActiveVirtualStopPrice - MagicTrailStepPips * PipSize>=TrailReferencePrice - CurrentSpreadPrice - MagicTrailMode2SpreadBufferPips * PipSize) ) )
           {
             MagicTrailTickCounter ++;
             if ( SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK)<ActiveVirtualStopPrice - MagicTrailStepPips * PipSize - StopLevelPriceDistance && SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK)>TakeProfitPrice + FreezeLevelPriceDistance && ( MagicTrailActivationDistancePips==0.0 || SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK)<TrailReferencePrice - ActiveMagicTrailActivationPips * PipSize ) && MagicTrailTickCounter >= MagicTrailMinimumTickCount )
             {
               MagicTrailTickCounter = 0 ;
               ActiveVirtualStopPrice = ActiveVirtualStopPrice - MagicTrailStepPips * PipSize ;
               OrderStateChanged = true ;
             }
           }
           if ( SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK)>=ActiveVirtualStopPrice )
           {
             RefreshCurrentSymbolTick(); 
             ClosePositionByTicket(OrderTicket,OrderLots,SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK),(int)CurrentSpreadPrice,clrNONE); 
             return(true); 
           }
           if ( NormalizeDouble(OriginalStopLoss,SymbolDigits)!=NormalizeDouble(ActiveVirtualStopPrice,SymbolDigits) )
           {
             UpdatedVirtualStopSecondary = NormalizeDouble(ActiveVirtualStopPrice,SymbolDigits);
             VirtualStopUpdateTicketSecondary = OrderTicket;
             for (VirtualStopUpdateIndexSecondary = 0 ; VirtualStopUpdateIndexSecondary < SmallBufferCapacity ; VirtualStopUpdateIndexSecondary=VirtualStopUpdateIndexSecondary + 1)
             {
               if ( VirtualStopByTicket[VirtualStopUpdateIndexSecondary][0]==VirtualStopUpdateTicketSecondary )
               {
                 VirtualStopByTicket[VirtualStopUpdateIndexSecondary][1] = UpdatedVirtualStopSecondary;
                 break;
               }
             }
           }
         }
       }
     }
     if ( OrderStateChanged )
     {
       AnyTradeChanged = true ;
     }
   }
   if ( OrderStateChanged )
   {
     AnyTradeChanged = true ;
   }
 }
 return(AnyTradeChanged); 
 }
//ManageSellTrades <<==--------   --------
 bool IsTradingSessionOpen()
 {
  bool      SessionOpen;
  datetime  ReferenceTime;
  int       ReferenceHour;
//----------------------------------------------------------------------
 bool       SundayOpen;
 bool       MondayOpen;
 bool       TuesdayOpen;
 bool       WednesdayOpen;
 bool       ThursdayOpen;
 bool       FridayOpen;

 if ( !(TradingHoursEnabled) )
 {
   return(true); 
 }
 SessionOpen = false ;
 ReferenceTime = 0 ;
 if ( TradingHoursTimeSource == 2 )
 {
   ReferenceTime = TimeCurrent() ;
 }
 if ( TradingHoursTimeSource == 0 )
 {
   TimeGMT(); 
 }
 if ( TradingHoursTimeSource == 1 )
 {
   TimeLocal(); 
 }
 ReferenceHour = DateTimeHour(ReferenceTime) ;
 if ( DateTimeDayOfWeek(ReferenceTime) == 0 )
 {
   if ( SundayStartHour <  SundayEndHour && ( ReferenceHour < SundayStartHour || ReferenceHour >= SundayEndHour ) )
   {
     SundayOpen = false;
   }
   else
   {
     if ( SundayStartHour >  SundayEndHour && ReferenceHour <  SundayStartHour && ReferenceHour >= SundayEndHour )
     {
       SundayOpen = false;
     }
     else
     {
       if ( SundayStartHour == SundayEndHour )
       {
         SundayOpen = false;
       }
       else
       {
         SundayOpen = true;
       }
     }
   }
   if ( SundayOpen )
   {
     SessionOpen = true ;
   }
 }
 if ( DateTimeDayOfWeek(ReferenceTime) == 1 )
 {
   if ( MondayStartHour <  MondayEndHour && ( ReferenceHour < MondayStartHour || ReferenceHour >= MondayEndHour ) )
   {
     MondayOpen = false;
   }
   else
   {
     if ( MondayStartHour >  MondayEndHour && ReferenceHour <  MondayStartHour && ReferenceHour >= MondayEndHour )
     {
       MondayOpen = false;
     }
     else
     {
       if ( MondayStartHour == MondayEndHour )
       {
         MondayOpen = false;
       }
       else
       {
         MondayOpen = true;
       }
     }
   }
   if ( MondayOpen )
   {
     SessionOpen = true ;
   }
 }
 if ( DateTimeDayOfWeek(ReferenceTime) == 2 )
 {
   if ( TuesdayStartHour <  TuesdayEndHour && ( ReferenceHour < TuesdayStartHour || ReferenceHour >= TuesdayEndHour ) )
   {
     TuesdayOpen = false;
   }
   else
   {
     if ( TuesdayStartHour >  TuesdayEndHour && ReferenceHour <  TuesdayStartHour && ReferenceHour >= TuesdayEndHour )
     {
       TuesdayOpen = false;
     }
     else
     {
       if ( TuesdayStartHour == TuesdayEndHour )
       {
         TuesdayOpen = false;
       }
       else
       {
         TuesdayOpen = true;
       }
     }
   }
   if ( TuesdayOpen )
   {
     SessionOpen = true ;
   }
 }
 if ( DateTimeDayOfWeek(ReferenceTime) == 3 )
 {
   if ( WednesdayStartHour <  WednesdayEndHour && ( ReferenceHour < WednesdayStartHour || ReferenceHour >= WednesdayEndHour ) )
   {
     WednesdayOpen = false;
   }
   else
   {
     if ( WednesdayStartHour >  WednesdayEndHour && ReferenceHour <  WednesdayStartHour && ReferenceHour >= WednesdayEndHour )
     {
       WednesdayOpen = false;
     }
     else
     {
       if ( WednesdayStartHour == WednesdayEndHour )
       {
         WednesdayOpen = false;
       }
       else
       {
         WednesdayOpen = true;
       }
     }
   }
   if ( WednesdayOpen )
   {
     SessionOpen = true ;
   }
 }
 if ( DateTimeDayOfWeek(ReferenceTime) == 4 )
 {
   if ( ThursdayStartHour <  ThursdayEndHour && ( ReferenceHour < ThursdayStartHour || ReferenceHour >= ThursdayEndHour ) )
   {
     ThursdayOpen = false;
   }
   else
   {
     if ( ThursdayStartHour >  ThursdayEndHour && ReferenceHour <  ThursdayStartHour && ReferenceHour >= ThursdayEndHour )
     {
       ThursdayOpen = false;
     }
     else
     {
       if ( ThursdayStartHour == ThursdayEndHour )
       {
         ThursdayOpen = false;
       }
       else
       {
         ThursdayOpen = true;
       }
     }
   }
   if ( ThursdayOpen )
   {
     SessionOpen = true ;
   }
 }
 if ( DateTimeDayOfWeek(ReferenceTime) == 5 )
 {
   if ( FridayStartHour <  FridayEndHour && ( ReferenceHour < FridayStartHour || ReferenceHour >= FridayEndHour ) )
   {
     FridayOpen = false;
   }
   else
   {
     if ( FridayStartHour >  FridayEndHour && ReferenceHour <  FridayStartHour && ReferenceHour >= FridayEndHour )
     {
       FridayOpen = false;
     }
     else
     {
       if ( FridayStartHour == FridayEndHour )
       {
         FridayOpen = false;
       }
       else
       {
         FridayOpen = true;
       }
     }
   }
   if ( FridayOpen )
   {
     SessionOpen = true ;
   }
 }
 return(SessionOpen); 
 }
//IsTradingSessionOpen <<==--------   --------
 string TradeErrorDescription( int ErrorCode)
 {
  string    Description;
//----------------------------------------------------------------------

 ErrorDescriptionCallCount ++;
 switch(ErrorCode)
 {
   case 0 : case 1 :
   Description = "no error" ;
     break;
   case 2 :
   Description = "common error" ;
     break;
   case 3 :
   Description = "invalid trade parameters" ;
     break;
   case 4 :
   Description = "trade server is busy" ;
     break;
   case 5 :
   Description = "old version of the client terminal" ;
     break;
   case 6 :
   Description = "no connection with trade server" ;
     break;
   case 7 :
   Description = "not enough rights" ;
     break;
   case 8 :
   Description = "too frequent requests" ;
     break;
   case 9 :
   Description = "malfunctional trade operation (never returned error)" ;
     break;
   case 64 :
   Description = "account disabled" ;
     break;
   case 65 :
   Description = "invalid account" ;
     break;
   case 128 :
   Description = "trade timeout" ;
     break;
   case 129 :
   Description = "invalid price" ;
     break;
   case 130 :
   Description = "invalid stops" ;
     break;
   case 131 :
   Description = "invalid trade volume" ;
     break;
   case 132 :
   Description = "market is closed" ;
     break;
   case 133 :
   Description = "trade is disabled" ;
     break;
   case 134 :
   Description = "not enough money" ;
     break;
   case 135 :
   Description = "price changed" ;
     break;
   case 136 :
   Description = "off quotes" ;
     break;
   case 137 :
   Description = "broker is busy (never returned error)" ;
     break;
   case 138 :
   Description = "requote" ;
     break;
   case 139 :
   Description = "order is locked" ;
     break;
   case 140 :
   Description = "long positions only allowed" ;
     break;
   case 141 :
   Description = "too many requests" ;
     break;
   case 145 :
   Description = "modification denied because order too close to market" ;
     break;
   case 146 :
   Description = "trade context is busy" ;
     break;
   case 147 :
   Description = "expirations are denied by broker" ;
     break;
   case 148 :
   Description = "amount of open and pending orders has reached the Exit_limit" ;
     break;
   case 149 :
   Description = "hedging is prohibited" ;
     break;
   case 150 :
   Description = "prohibited by FIFO rules" ;
     break;
   case 4000 :
   Description = "no error (never generated code)" ;
     break;
   case 4001 :
   Description = "wrong function pointer" ;
     break;
   case 4002 :
   Description = "array index is out of range" ;
     break;
   case 4003 :
   Description = "no memory for function call stack" ;
     break;
   case 4004 :
   Description = "recursive stack overflow" ;
     break;
   case 4005 :
   Description = "not enough stack for parameter" ;
     break;
   case 4006 :
   Description = "no memory for parameter string" ;
     break;
   case 4007 :
   Description = "no memory for temp string" ;
     break;
   case 4008 :
   Description = "not initialized string" ;
     break;
   case 4009 :
   Description = "not initialized string in array" ;
     break;
   case 4010 :
   Description = "no memory for array\' string" ;
     break;
   case 4011 :
   Description = "too long string" ;
     break;
   case 4012 :
   Description = "remainder from zero divide" ;
     break;
   case 4013 :
   Description = "zero divide" ;
     break;
   case 4014 :
   Description = "unknown command" ;
     break;
   case 4015 :
   Description = "wrong jump (never generated error)" ;
     break;
   case 4016 :
   Description = "not initialized array" ;
     break;
   case 4017 :
   Description = "dll calls are not allowed" ;
     break;
   case 4018 :
   Description = "cannot load library" ;
     break;
   case 4019 :
   Description = "cannot call function" ;
     break;
   case 4020 :
   Description = "expert function calls are not allowed" ;
     break;
   case 4021 :
   Description = "not enough memory for temp string returned from function" ;
     break;
   case 4022 :
   Description = "system is busy (never generated error)" ;
     break;
   case 4050 :
   Description = "invalid function parameters count" ;
     break;
   case 4051 :
   Description = "invalid function parameter value" ;
     break;
   case 4052 :
   Description = "string function internal error" ;
     break;
   case 4053 :
   Description = "some array error" ;
     break;
   case 4054 :
   Description = "incorrect series array using" ;
     break;
   case 4055 :
   Description = "custom indicator error" ;
     break;
   case 4056 :
   Description = "arrays are incompatible" ;
     break;
   case 4057 :
   Description = "global variables processing error" ;
     break;
   case 4058 :
   Description = "global variable not found" ;
     break;
   case 4059 :
   Description = "function is not allowed in testing mode" ;
     break;
   case 4060 :
   Description = "function is not confirmed" ;
     break;
   case 4061 :
   Description = "send mail error" ;
     break;
   case 4062 :
   Description = "string parameter expected" ;
     break;
   case 4063 :
   Description = "integer parameter expected" ;
     break;
   case 4064 :
   Description = "double parameter expected" ;
     break;
   case 4065 :
   Description = "array as parameter expected" ;
     break;
   case 4066 :
   Description = "requested history data in update state" ;
     break;
   case 4099 :
   Description = "end of file" ;
     break;
   case 4100 :
   Description = "some file error" ;
     break;
   case 4101 :
   Description = "wrong file name" ;
     break;
   case 4102 :
   Description = "too many opened files" ;
     break;
   case 4103 :
   Description = "cannot open file" ;
     break;
   case 4104 :
   Description = "incompatible access to a file" ;
     break;
   case 4105 :
   Description = "no order selected" ;
     break;
   case 4106 :
   Description = "unknown symbol" ;
     break;
   case 4107 :
   Description = "invalid price parameter for trade function" ;
     break;
   case 4108 :
   Description = "invalid ticket" ;
     break;
   case 4109 :
   Description = "trade is not allowed in the expert properties" ;
     break;
   case 4110 :
   Description = "longs are not allowed in the expert properties" ;
     break;
   case 4111 :
   Description = "shorts are not allowed in the expert properties" ;
     break;
   case 4200 :
   Description = "object is already exist" ;
     break;
   case 4201 :
   Description = "unknown object property" ;
     break;
   case 4202 :
   Description = "object is not exist" ;
     break;
   case 4203 :
   Description = "unknown object type" ;
     break;
   case 4204 :
   Description = "no object name" ;
     break;
   case 4205 :
   Description = "object coordinates error" ;
     break;
   case 4206 :
   Description = "no specified subwindow" ;
     break;
   default :
   Description = "unknown error" ;
 }
 return(Description);
 }
//TradeErrorDescription <<==--------   --------
 void ResizePendingOrderLots( bool ForceResize)
 {
  double    ResizeThresholdFactor;
  int       OrderCount;
  int       OrderScanIndex;
  double    BuyStopLoss;
  long      OldBuyTicket;
  double    BuyTakeProfit;
  double    BuyOpenPrice;
  datetime  BuyExpiration;
  string    BuyComment;
  long      NewBuyTicket; // ticket 64-bit
  double    SellStopLoss;
  long      OldSellTicket;
  double    SellTakeProfit;
  double    SellOpenPrice;
  datetime  SellExpiration;
  string    SellComment;
  long      NewSellTicket; // ticket 64-bit
//----------------------------------------------------------------------
 long       MappedNewBuyTicket;
 long       MappedOldBuyTicket;
 int        BuyTicketMapIndex;
 long       MappedNewSellTicket;
 long       MappedOldSellTicket;
 int        SellTicketMapIndex;

 ResizeThresholdFactor = PendingLotResizeThresholdPercent / 100.0 + 1.0 ;
 if ( ( !(AccountInfoDouble(ACCOUNT_BALANCE)!=LastLotResizeBalance) && !(ForceResize) ) )   return;
 
 if ( ( !(AccountInfoDouble(ACCOUNT_BALANCE)>LastLotResizeBalance * ResizeThresholdFactor) && !(AccountInfoDouble(ACCOUNT_BALANCE)<LastLotResizeBalance / ResizeThresholdFactor) && !(ForceResize) ) )   return;
 CalculateStrategyLotSize(StopLossPips,LotSizePercentMultiplier); 
 OrderCount = ActiveTradeCount() ;
 for (OrderScanIndex = OrderCount ; OrderScanIndex >= 0 ; OrderScanIndex --)
 {
   if ( SelectTradeRecord(OrderScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeMagic() != StrategyMagicNumber || SelectedTradeSymbol() != CurrentSymbol )   continue;
   
   if ( SelectedTradeType() == ORDER_TYPE_BUY_STOP && SelectedTradeVolume()!=LotSizeByStrategy[CurrentStrategyIndex] )
   {
     BuyStopLoss = SelectedTradeStopLoss() ;
     OldBuyTicket = SelectedTradeTicket() ;
     BuyTakeProfit = SelectedTradeTakeProfit() ;
     BuyOpenPrice = SelectedTradeOpenPrice() ;
     BuyExpiration = SelectedTradeExpiration() ;
     BuyComment = SelectedTradeComment() ;
     DeletePendingOrderByTicket(OldBuyTicket,Red); 
     NewBuyTicket = SendTradeOrder(CurrentSymbol,ORDER_TYPE_BUY_STOP,LotSizeByStrategy[CurrentStrategyIndex],BuyOpenPrice,(int)OrderSlippageSetting,BuyStopLoss,BuyTakeProfit,BuyComment,StrategyMagicNumber,BuyExpiration,Green) ;
     MappedNewBuyTicket = NewBuyTicket;
     MappedOldBuyTicket = OldBuyTicket;
     for (BuyTicketMapIndex = 0 ; BuyTicketMapIndex < 100 ; BuyTicketMapIndex=BuyTicketMapIndex + 1)
     {
       if ( !(PendingTicketPriceMap[BuyTicketMapIndex][0]==MappedOldBuyTicket) )   continue;
       PendingTicketPriceMap[BuyTicketMapIndex][0] = (double)MappedNewBuyTicket;
       break;
       
     }
     Print("Lotsize changed more than " + string(PendingLotResizeThresholdPercent) + "%... adjusting lotsize of pending orders"); 
     Sleep(1000); 
   }
   if ( SelectedTradeType() != ORDER_TYPE_SELL_STOP || !(SelectedTradeVolume()!=LotSizeByStrategy[CurrentStrategyIndex]) )   continue;
   SellStopLoss = SelectedTradeStopLoss() ;
   OldSellTicket = SelectedTradeTicket() ;
   SellTakeProfit = SelectedTradeTakeProfit() ;
   SellOpenPrice = SelectedTradeOpenPrice() ;
   SellExpiration = SelectedTradeExpiration() ;
   SellComment = SelectedTradeComment() ;
   DeletePendingOrderByTicket(OldSellTicket,Red); 
   NewSellTicket = SendTradeOrder(CurrentSymbol,ORDER_TYPE_SELL_STOP,LotSizeByStrategy[CurrentStrategyIndex],SellOpenPrice,(int)OrderSlippageSetting,SellStopLoss,SellTakeProfit,SellComment,StrategyMagicNumber,SellExpiration,Green) ;
   MappedNewSellTicket = NewSellTicket;
   MappedOldSellTicket = OldSellTicket;
   for (SellTicketMapIndex = 0 ; SellTicketMapIndex < 100 ; SellTicketMapIndex=SellTicketMapIndex + 1)
   {
     if ( !(PendingTicketPriceMap[SellTicketMapIndex][0]==MappedOldSellTicket) )   continue;
     PendingTicketPriceMap[SellTicketMapIndex][0] = (double)MappedNewSellTicket;
     break;
     
   }
   Print("Lotsize changed more than " + string(PendingLotResizeThresholdPercent) + "%... adjusting lotsize of pending orders"); 
   Sleep(1000); 
   
 }
 }

 void CreateInfoPanel()
 {
  int       UnusedPanelIntegerA = 0;
  int       UnusedPanelIntegerB = 0;
  int       UnusedPanelTitleOffset;
  int       UnusedPanelBaseWidth;
  int       UnusedPanelDefaultFontSize;
  double    UnusedPanelScale;
  int       PanelTextXPadding;
  int       PanelTextYPadding;
  int       PanelWidth;
  int       PanelHeight;
  int       ChartCorner;
  int       PanelX;
  int       PanelY;
  uint      PanelBackgroundColor;
  bool      UnusedAlternateRowFlag;
  int       OneChartExtraHeight;
  string    TradeFrequencyText;
  int       CellObjectIndex;
  int       ColumnIndex;
  int       RowIndex;
  string    CellText;
  int       TableOriginX;
  int       TableOriginY;
  int       StrategyRowIndex;
//----------------------------------------------------------------------

 UnusedPanelTitleOffset = 20 ;
 UnusedPanelBaseWidth = 300 ;
 UnusedPanelDefaultFontSize = 7 ;
 UnusedPanelScale = InfoPanelSizeAdjust ;
 PanelTextXPadding = 6 ;
 PanelTextYPadding = 4 ;
 PanelWidth = 350 ;
 PanelHeight = 366 ;
 ChartCorner = 0 ;
 PanelX = 5 ;
 PanelY = 20 ;
 PanelBackgroundColor = LightSteelBlue ;
 UnusedAlternateRowFlag = false ;
 OneChartExtraHeight = 0 ;
 if ( OneChartSetupEnabled )
 {
   OneChartExtraHeight = (int)((StrategySymbolCount + 3) * PanelRowHeight) ;
 }
 ObjectCreate(0,"infopanel_rectangle",OBJ_RECTANGLE_LABEL,0,0,0.0); 
 ObjectSetInteger(0,"infopanel_rectangle",OBJPROP_XDISTANCE,PanelX); 
 ObjectSetInteger(0,"infopanel_rectangle",OBJPROP_YDISTANCE,PanelY); 
 ObjectSetInteger(0,"infopanel_rectangle",OBJPROP_XSIZE,long(PanelWidth * InfoPanelSizeAdjust)); 
 ObjectSetInteger(0,"infopanel_rectangle",OBJPROP_YSIZE,long(PanelHeight * InfoPanelSizeAdjust + OneChartExtraHeight)); 
 ObjectSetInteger(0,"infopanel_rectangle",OBJPROP_CORNER,CORNER_LEFT_UPPER); 
 ObjectSetInteger(0,"infopanel_rectangle",OBJPROP_COLOR,clrBlue); 
 ObjectSetInteger(0,"infopanel_rectangle",OBJPROP_BGCOLOR,PanelBackgroundColor); 
 ObjectSetInteger(0,"infopanel_rectangle",OBJPROP_BACK,0); 
 ObjectSetInteger(0,"infopanel_rectangle",OBJPROP_BORDER_COLOR,clrBlue); 
 ObjectSetInteger(0,"infopanel_rectangle",OBJPROP_COLOR,clrBlue); 
 ObjectSetInteger(0,"infopanel_rectangle",OBJPROP_BORDER_TYPE,BORDER_FLAT); 
 ObjectSetInteger(0,"infopanel_rectangle",OBJPROP_STYLE,STYLE_SOLID); 
 ObjectSetInteger(0,"infopanel_rectangle",OBJPROP_WIDTH,2); 
 ObjectSetInteger(0,"infopanel_rectangle",OBJPROP_SELECTABLE,0); 
 ObjectCreate(0,"line1",OBJ_LABEL,0,0,0.0); 
 ObjectSetInteger(0,"line1",OBJPROP_CORNER,ChartCorner); 
 ObjectSetInteger(0,"line1",OBJPROP_YDISTANCE,PanelY + PanelTextYPadding); 
 ObjectSetInteger(0,"line1",OBJPROP_XDISTANCE,PanelX + PanelTextXPadding); 
 if ( !(OneChartSetupEnabled) )
 {
   ObjectSetString(0,"line1",OBJPROP_TEXT,"The Gold Reaper V4.5"); 
 }
 else
 {
   ObjectSetString(0,"line1",OBJPROP_TEXT,"The Gold Reaper V4.5 - OneChartSetup"); 
 }
 ObjectSetInteger(0,"line1",OBJPROP_COLOR,PanelTextColor);
 // Ban decompile goc thieu set co chu rieng cho cac dong tieu de/tom tat panel
 // (chi co bang chien luoc phia duoi duoc set), trong khi kich thuoc khung panel
 // lai duoc tinh dua tren dung hang so co chu nay -> khien cac dong nay hien thi
 // to hon binh thuong (dung co mac dinh cua nen tang) so voi thiet ke that su cua
 // khung panel. Set khop voi co chu cua bang chien luoc de dong bo.
 ObjectSetInteger(0,"line1",OBJPROP_FONTSIZE,PanelFontSize);
 ObjectCreate(0,"linec",OBJ_LABEL,0,0,0.0);
 ObjectSetInteger(0,"linec",OBJPROP_CORNER,ChartCorner); 
 ObjectSetInteger(0,"linec",OBJPROP_YDISTANCE,long(PanelY + InfoPanelSizeAdjust * 20.0 + PanelTextYPadding)); 
 ObjectSetInteger(0,"linec",OBJPROP_XDISTANCE,PanelX + PanelTextXPadding); 
 ObjectSetString(0,"linec",OBJPROP_TEXT,"EA developer by Pham Duy Linh - 2026"); 
 ObjectSetInteger(0,"linec",OBJPROP_COLOR,PanelTextColor);
 ObjectSetInteger(0,"linec",OBJPROP_FONTSIZE,PanelFontSize);
 ObjectCreate(0,"line2",OBJ_LABEL,0,0,0.0);
 ObjectSetInteger(0,"line2",OBJPROP_CORNER,ChartCorner); 
 ObjectSetInteger(0,"line2",OBJPROP_YDISTANCE,long(PanelY + InfoPanelSizeAdjust * 32.0 + PanelTextYPadding)); 
 ObjectSetInteger(0,"line2",OBJPROP_XDISTANCE,PanelX + PanelTextXPadding); 
 ObjectSetString(0,"line2",OBJPROP_TEXT,"------------------------------------------------------"); 
 ObjectSetInteger(0,"line2",OBJPROP_COLOR,PanelTextColor);
 ObjectSetInteger(0,"line2",OBJPROP_FONTSIZE,PanelFontSize);
 ObjectCreate(0,"lines",OBJ_LABEL,0,0,0.0);
 ObjectSetInteger(0,"lines",OBJPROP_CORNER,ChartCorner); 
 ObjectSetInteger(0,"lines",OBJPROP_YDISTANCE,long(PanelY + InfoPanelSizeAdjust * 44.0 + PanelTextYPadding)); 
 ObjectSetInteger(0,"lines",OBJPROP_XDISTANCE,PanelX + PanelTextXPadding); 
 if ( ActiveTradeFrequency == 1 )
 {
   TradeFrequencyText = "conservative" ;
 }
 else
 {
   if ( ActiveTradeFrequency == 2 )
   {
     TradeFrequencyText = "moderate" ;
   }
   else
   {
     if ( ActiveTradeFrequency == 3 )
     {
       TradeFrequencyText = "intense" ;
     }
     else
     {
       if ( ActiveTradeFrequency == 4 )
       {
         TradeFrequencyText = "extreme" ;
       }
       else
       {
         if ( ActiveTradeFrequency == 0 )
         {
           TradeFrequencyText = "extreme conservative" ;
         }
         else
         {
           TradeFrequencyText = "manual strategy selection" ;
         }
       }
     }
   }
 }
 ObjectSetString(0,"lines",OBJPROP_TEXT,"Trade Frequency: " + TradeFrequencyText);
 ObjectSetInteger(0,"lines",OBJPROP_COLOR,PanelTextColor);
 ObjectSetInteger(0,"lines",OBJPROP_FONTSIZE,PanelFontSize);
 if ( Risk == 1234 )
 {
   ObjectCreate(0,"linet",OBJ_LABEL,0,0,0.0); 
   ObjectSetInteger(0,"linet",OBJPROP_CORNER,ChartCorner); 
   ObjectSetInteger(0,"linet",OBJPROP_YDISTANCE,long(PanelY + InfoPanelSizeAdjust * 60.0 + PanelTextYPadding)); 
   ObjectSetInteger(0,"linet",OBJPROP_XDISTANCE,PanelX + PanelTextXPadding); 
   ObjectSetString(0,"linet",OBJPROP_TEXT,"Max allowed DD: " + string(MaxAllowedDD) + "%");
   ObjectSetInteger(0,"linet",OBJPROP_COLOR,PanelTextColor);
   ObjectSetInteger(0,"linet",OBJPROP_FONTSIZE,PanelFontSize);
 }
 else
 {
   if ( Risk == 3 )
   {
     ObjectCreate(0,"linet",OBJ_LABEL,0,0,0.0); 
     ObjectSetInteger(0,"linet",OBJPROP_CORNER,ChartCorner); 
     ObjectSetInteger(0,"linet",OBJPROP_YDISTANCE,long(PanelY + InfoPanelSizeAdjust * 60.0 + PanelTextYPadding)); 
     ObjectSetInteger(0,"linet",OBJPROP_XDISTANCE,PanelX + PanelTextXPadding); 
     ObjectSetString(0,"linet",OBJPROP_TEXT,"Max risk per strategy: " + string(MaxRiskPerStrategy_) + "%");
     ObjectSetInteger(0,"linet",OBJPROP_COLOR,PanelTextColor);
     ObjectSetInteger(0,"linet",OBJPROP_FONTSIZE,PanelFontSize);
   }
   else
   {
     ObjectCreate(0,"linet",OBJ_LABEL,0,0,0.0);
     ObjectSetInteger(0,"linet",OBJPROP_CORNER,ChartCorner); 
     ObjectSetInteger(0,"linet",OBJPROP_YDISTANCE,long(PanelY + InfoPanelSizeAdjust * 60.0 + PanelTextYPadding)); 
     ObjectSetInteger(0,"linet",OBJPROP_XDISTANCE,PanelX + PanelTextXPadding); 
     ObjectSetString(0,"linet",OBJPROP_TEXT,"Manual lotsize: " + string(StartLots_rw) + "lots");
     ObjectSetInteger(0,"linet",OBJPROP_COLOR,PanelTextColor);
     ObjectSetInteger(0,"linet",OBJPROP_FONTSIZE,PanelFontSize);
   }
 }
 ObjectCreate(0,"lineopl" + IntegerToString(0,0,32),OBJ_LABEL,0,0,0.0);
 ObjectSetInteger(0,"lineopl" + IntegerToString(0,0,32),OBJPROP_CORNER,ChartCorner); 
 ObjectSetInteger(0,"lineopl" + IntegerToString(0,0,32),OBJPROP_YDISTANCE,(long)(PanelY + InfoPanelSizeAdjust * 76.0 + PanelTextYPadding)); 
 ObjectSetInteger(0,"lineopl" + IntegerToString(0,0,32),OBJPROP_XDISTANCE,PanelX + PanelTextXPadding); 
 ObjectSetString(0,"lineopl" + IntegerToString(0,0,32),OBJPROP_TEXT,"Open P/L: -");
 ObjectSetInteger(0,"lineopl" + IntegerToString(0,0,32),OBJPROP_COLOR,PanelTextColor);
 ObjectSetInteger(0,"lineopl" + IntegerToString(0,0,32),OBJPROP_FONTSIZE,PanelFontSize);
 ObjectCreate(0,"linea" + IntegerToString(0,0,32),OBJ_LABEL,0,0,0.0);
 ObjectSetInteger(0,"linea" + IntegerToString(0,0,32),OBJPROP_CORNER,ChartCorner); 
 ObjectSetInteger(0,"linea" + IntegerToString(0,0,32),OBJPROP_YDISTANCE,(long)(PanelY + InfoPanelSizeAdjust * 108.0 + PanelTextYPadding)); 
 ObjectSetInteger(0,"linea" + IntegerToString(0,0,32),OBJPROP_XDISTANCE,PanelX + PanelTextXPadding); 
 ObjectSetString(0,"linea" + IntegerToString(0,0,32),OBJPROP_TEXT,"Account Balance: -");
 ObjectSetInteger(0,"linea" + IntegerToString(0,0,32),OBJPROP_COLOR,PanelTextColor);
 ObjectSetInteger(0,"linea" + IntegerToString(0,0,32),OBJPROP_FONTSIZE,PanelFontSize);
 ObjectCreate(0,"linetp" + IntegerToString(0,0,32),OBJ_LABEL,0,0,0.0);
 ObjectSetInteger(0,"linetp" + IntegerToString(0,0,32),OBJPROP_CORNER,ChartCorner);
 ObjectSetInteger(0,"linetp" + IntegerToString(0,0,32),OBJPROP_YDISTANCE,(long)(PanelY + InfoPanelSizeAdjust * 124.0 + PanelTextYPadding));
 ObjectSetInteger(0,"linetp" + IntegerToString(0,0,32),OBJPROP_XDISTANCE,PanelX + PanelTextXPadding);
 ObjectSetString(0,"linetp" + IntegerToString(0,0,32),OBJPROP_TEXT,"Total P/L so far: -");
 ObjectSetInteger(0,"linetp" + IntegerToString(0,0,32),OBJPROP_COLOR,PanelTextColor);
 ObjectSetInteger(0,"linetp" + IntegerToString(0,0,32),OBJPROP_FONTSIZE,PanelFontSize);
 if ( EnableNFP_Filter )
 {
   ObjectCreate(0,"linenfp" + IntegerToString(0,0,32),OBJ_LABEL,0,0,0.0);
   ObjectSetInteger(0,"linenfp" + IntegerToString(0,0,32),OBJPROP_CORNER,ChartCorner);
   ObjectSetInteger(0,"linenfp" + IntegerToString(0,0,32),OBJPROP_YDISTANCE,(long)(PanelY + InfoPanelSizeAdjust * 140.0 + PanelTextYPadding));
   ObjectSetInteger(0,"linenfp" + IntegerToString(0,0,32),OBJPROP_XDISTANCE,PanelX + PanelTextXPadding);
   ObjectSetString(0,"linenfp" + IntegerToString(0,0,32),OBJPROP_TEXT,"No News Coming Up");
   ObjectSetInteger(0,"linenfp" + IntegerToString(0,0,32),OBJPROP_COLOR,PanelTextColor);
   ObjectSetInteger(0,"linenfp" + IntegerToString(0,0,32),OBJPROP_FONTSIZE,PanelFontSize);
 }
 if ( OnlyUp )
 {
   ObjectCreate(0,"lineup" + IntegerToString(0,0,32),OBJ_LABEL,0,0,0.0);
   ObjectSetInteger(0,"lineup" + IntegerToString(0,0,32),OBJPROP_CORNER,ChartCorner);
   ObjectSetInteger(0,"lineup" + IntegerToString(0,0,32),OBJPROP_YDISTANCE,(long)(PanelY + InfoPanelSizeAdjust * 92.0 + PanelTextYPadding));
   ObjectSetInteger(0,"lineup" + IntegerToString(0,0,32),OBJPROP_XDISTANCE,PanelX + PanelTextXPadding);
   ObjectSetString(0,"lineup" + IntegerToString(0,0,32),OBJPROP_TEXT,"Highest Balance: -");
   ObjectSetInteger(0,"lineup" + IntegerToString(0,0,32),OBJPROP_COLOR,PanelTextColor);
   ObjectSetInteger(0,"lineup" + IntegerToString(0,0,32),OBJPROP_FONTSIZE,PanelFontSize);
 }
 CellObjectIndex = 0 ;
 ColumnIndex = 0 ;
 RowIndex = 0 ;
 TableOriginX = PanelX + PanelTextXPadding ;
 TableOriginY = (int)(PanelY + InfoPanelSizeAdjust * 176.0 + PanelTextYPadding) ;
 CellText = "Strategy" ;
 CreatePanelCell(TableOriginX,TableOriginY,0,"Strategy",0,0,1,0,1.0); 
 CellObjectIndex = 1 ;
 ColumnIndex = 1 ;
 CellText = "Closed PL" ;
 if ( StrategyRankingMode == 1 )
 {
   CellText = "Closed PL*" ;
 }
 CreatePanelCell(TableOriginX,TableOriginY,CellObjectIndex,CellText,RowIndex,ColumnIndex,1,0,1.0); 
 CellObjectIndex ++;
 ColumnIndex ++;
 CellText = "PL per trade" ;
 if ( StrategyRankingMode == 2 )
 {
   CellText = "PL per trade*" ;
 }
 CreatePanelCell(TableOriginX,TableOriginY,CellObjectIndex,CellText,RowIndex,ColumnIndex,1,0,1.0); 
 CellObjectIndex ++;
 ColumnIndex ++;
 CellText = "Lotsize" ;
 CreatePanelCell(TableOriginX,TableOriginY,CellObjectIndex,"Lotsize",RowIndex,ColumnIndex,1,0,1.0); 
 CellObjectIndex ++;
 ColumnIndex = 0 ;
 RowIndex ++;
 PanelStrategyRowStartIndex = CellObjectIndex ;
 for (StrategyRowIndex = 0 ; StrategyRowIndex < 9 ; StrategyRowIndex ++)
 {
   CellText="Strategy " + IntegerToString(StrategyRowIndex + 1,0,32);
   CreatePanelCell(TableOriginX,TableOriginY,CellObjectIndex,CellText,RowIndex,ColumnIndex,1,0,1.0); 
   CellObjectIndex ++;
   ColumnIndex ++;
   CellText = DoubleToString(NormalizeDouble(StrategyDisplayProfit[StrategyRowIndex],2),2) ;
   CreatePanelCell(TableOriginX,TableOriginY,CellObjectIndex,CellText,RowIndex,ColumnIndex,1,0,1.0); 
   CellObjectIndex ++;
   ColumnIndex ++;
   CellText = DoubleToString(NormalizeDouble(AverageProfitByStrategy[StrategyRowIndex],2),2) ;
   CreatePanelCell(TableOriginX,TableOriginY,CellObjectIndex,CellText,RowIndex,ColumnIndex,1,0,1.0); 
   CellObjectIndex ++;
   ColumnIndex ++;
   CellText = DoubleToString(NormalizeDouble(LotSizeByStrategy[StrategyRowIndex],2),2) ;
   CreatePanelCell(TableOriginX,TableOriginY,CellObjectIndex,CellText,RowIndex,ColumnIndex,1,0,1.0); 
   CellObjectIndex ++;
   ColumnIndex = 0 ;
   RowIndex ++;
 }
 }
//CreateInfoPanel <<==--------   --------
 void CreatePanelCell( int BaseX,int BaseY,int ObjectIndex,string Text,int RowIndex,int ColumnIndex,int AlignmentMode,uint TextColor,double FontScale)
 {
 ObjectCreate(0,"info_ea" + IntegerToString(ObjectIndex,0,32),OBJ_EDIT,0,0,0.0); 
 ObjectSetInteger(0,"info_ea" + IntegerToString(ObjectIndex,0,32),OBJPROP_XDISTANCE,(long)(BaseX + ColumnIndex * PanelRowWidth)); 
 ObjectSetInteger(0,"info_ea" + IntegerToString(ObjectIndex,0,32),OBJPROP_YDISTANCE,(long)(BaseY + RowIndex * PanelRowHeight)); 
 ObjectSetString(0,"info_ea" + IntegerToString(ObjectIndex,0,32),OBJPROP_TEXT,Text); 
 ObjectSetInteger(0,"info_ea" + IntegerToString(ObjectIndex,0,32),OBJPROP_BACK,0); 
 ObjectSetInteger(0,"info_ea" + IntegerToString(ObjectIndex,0,32),OBJPROP_COLOR,TextColor); 
 ObjectSetInteger(0,"info_ea" + IntegerToString(ObjectIndex,0,32),OBJPROP_BGCOLOR,PanelCellBackgroundColor); 
 ObjectSetInteger(0,"info_ea" + IntegerToString(ObjectIndex,0,32),OBJPROP_BORDER_COLOR,0); 
 ObjectSetInteger(0,"info_ea" + IntegerToString(ObjectIndex,0,32),OBJPROP_FONTSIZE,(long)(PanelFontSize * FontScale)); 
 ObjectSetInteger(0,"info_ea" + IntegerToString(ObjectIndex,0,32),OBJPROP_READONLY,true); 
 ObjectSetInteger(0,"info_ea" + IntegerToString(ObjectIndex,0,32),OBJPROP_YSIZE,(long)PanelRowHeight); 
 ObjectSetInteger(0,"info_ea" + IntegerToString(ObjectIndex,0,32),OBJPROP_XSIZE,(long)PanelRowWidth); 
 ObjectSetInteger(0,"info_ea" + IntegerToString(ObjectIndex,0,32),OBJPROP_YSIZE,(long)PanelRowHeight); 
 if ( AlignmentMode == 0 )
 {
   ObjectSetInteger(0,"info_ea" + IntegerToString(ObjectIndex,0,32),OBJPROP_ALIGN,ALIGN_CENTER); 
 }
 if ( AlignmentMode == 1 )
 {
   ObjectSetInteger(0,"info_ea" + IntegerToString(ObjectIndex,0,32),OBJPROP_ALIGN,ALIGN_RIGHT); 
 }
 if ( AlignmentMode != 2 )   return;
 ObjectSetInteger(0,"info_ea" + IntegerToString(ObjectIndex,0,32),OBJPROP_ALIGN,0); 
 }
//CreatePanelCell <<==--------   --------
 void DeleteInfoPanel()
 {
  int       SummaryObjectIndex;
  int       TableObjectIndex;
  int       HeadingObjectIndex;
  int       PanelObjectIndex;
//----------------------------------------------------------------------

 ObjectDelete(0,"line1"); 
 ObjectDelete(0,"linec"); 
 ObjectDelete(0,"line2"); 
 ObjectDelete(0,"lines"); 
 ObjectDelete(0,"linet"); 
 ObjectDelete(0,"lineTradeStart"); 
 for (SummaryObjectIndex = 0 ; SummaryObjectIndex <= 99 ; SummaryObjectIndex ++)
 {
   ObjectDelete(0,"lineopl" + IntegerToString(SummaryObjectIndex,0,32)); 
   ObjectDelete(0,"linea" + IntegerToString(SummaryObjectIndex,0,32)); 
   ObjectDelete(0,"lineto" + IntegerToString(SummaryObjectIndex,0,32)); 
   ObjectDelete(0,"linetp" + IntegerToString(SummaryObjectIndex,0,32));
   ObjectDelete(0,"linetq" + IntegerToString(SummaryObjectIndex,0,32));
   ObjectDelete(0,"linenfp" + IntegerToString(SummaryObjectIndex,0,32));
   ObjectDelete(0,"lineup" + IntegerToString(SummaryObjectIndex,0,32));
   for (TableObjectIndex = 0 ; TableObjectIndex < 10 ; TableObjectIndex ++)
   {
     ObjectDelete(0,"tabel_info" + IntegerToString(SummaryObjectIndex * 100 + TableObjectIndex,0,32)); 
   }
 }
 ObjectDelete(0,"infopanel_rectangle"); 
 for (HeadingObjectIndex = 0 ; HeadingObjectIndex < 10 ; HeadingObjectIndex ++)
 {
   ObjectDelete(0,"tabel_heading" + IntegerToString(HeadingObjectIndex,0,32)); 
   ObjectDelete(0,"tabel_totals" + IntegerToString(HeadingObjectIndex,0,32)); 
 }
 for (PanelObjectIndex = 0 ; PanelObjectIndex < PanelObjectCount ; PanelObjectIndex ++)
 {
   ObjectDelete(0,"horizontalrect" + IntegerToString(PanelObjectIndex,0,32)); 
   ObjectDelete(0,"info_ea" + IntegerToString(PanelObjectIndex,0,32)); 
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
   return("GR_OnlyUpPeak_TESTER_" + Symbol() + "_" + IntegerToString(ST1_MagicNumber) + "_" + IntegerToString(OnlyUpRunId));
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
   return("GR_OUWD_T_" + Symbol() + "_" + IntegerToString(ST1_MagicNumber) + "_" + IntegerToString(OnlyUpRunId));
 }
 return("GR_OUWD_" + Symbol() + "_" + IntegerToString(ST1_MagicNumber) + "_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)));
 }
//OnlyUpWithdrawGVName <<==--------   --------
 string GetNextNFPText()
 {
  datetime  NextNfpTime = 0;
  int       NfpDateIndex;
//----------------------------------------------------------------------
 // Theo trang thai lay tin (nfpStatus): 2 = Lich MQL5 khong doc duoc -> bao
 // loi lay tin. mq5 dung Lich (khong co link) nen khong co trang thai thieu
 // link. Binh thuong (0): co NFP -> "Next NFP: ..."; khong co -> "No News".
 if ( NfpStatus == 2 )   return("NFP: news fetch error");
 for (NfpDateIndex = 0 ; NfpDateIndex < 300 ; NfpDateIndex ++)
 {
   if ( NfpDatesGmt[NfpDateIndex] <= 0 )   continue;
   if ( NfpDatesGmt[NfpDateIndex] >= CurrentGmtTime )
   {
     if ( NextNfpTime == 0 || NfpDatesGmt[NfpDateIndex] < NextNfpTime )   NextNfpTime = NfpDatesGmt[NfpDateIndex];
   }
 }
 if ( NextNfpTime == 0 )   return("No News Coming Up"); // chua co/chua lay duoc lich -> giong panel v4.3
 return("Next NFP: " + TimeToString(NextNfpTime + BrokerGmtOffsetHours * 3600,TIME_DATE|TIME_SECONDS));
 }
//GetNextNFPText <<==--------   --------
 void UpdateInfoPanelSummary()
 {
  string    TradeFrequencyText;
//----------------------------------------------------------------------
 double     DisplayOpenProfit;
 double     OpenProfitAccumulator;
 int        OpenOrderScanIndex;
 long        OpenProfitMagicCheck01;
 long        OpenProfitMagicCheck02;
 long        OpenProfitMagicCheck03;
 long        OpenProfitMagicCheck04;
 long        OpenProfitMagicCheck05;
 long        OpenProfitMagicCheck06;
 long        OpenProfitMagicCheck07;
 long        OpenProfitMagicCheck08;
 long        OpenProfitMagicCheck09;
 long        OpenProfitMagicCheck10;
 long        OpenProfitMagicCheck11;
 long        OpenProfitMagicCheck12;
 long        OpenProfitMagicCheck13;
 long        OpenProfitMagicCheck14;
 long        OpenProfitMagicCheck15;
 long        OpenProfitMagicCheck16;

 if ( !(ShowInfoPanel) )   return;
 
 if ( ( MQLInfoInteger(MQL_TESTER) == 1 && !(UpdateInfoTesting) ) )   return;
 
 if ( MQLInfoInteger(MQL_TESTER) == 1 && !(UpdateInfoTesting) )
 {
   DisplayOpenProfit = 0.0;
 }
 else
 {
   OpenProfitAccumulator = 0.0;
   for (OpenOrderScanIndex = ActiveTradeCount() ; OpenOrderScanIndex >= 0 ; OpenOrderScanIndex=OpenOrderScanIndex - 1)
   {
     if ( SelectTradeRecord(OpenOrderScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true )   continue;
     
     if ( ( SelectedTradeSymbol() != CurrentSymbol && !(OneChartSetupEnabled) ) )   continue;
     OpenProfitMagicCheck01 = SelectedTradeMagic();
     OpenProfitMagicCheck02=ST1_MagicNumber + 1;
     if ( OpenProfitMagicCheck01 != OpenProfitMagicCheck02 )
     {
       OpenProfitMagicCheck02 = SelectedTradeMagic();
       OpenProfitMagicCheck03=ST1_MagicNumber + 2;
       if ( OpenProfitMagicCheck02 != OpenProfitMagicCheck03 )
       {
         OpenProfitMagicCheck03 = SelectedTradeMagic();
         OpenProfitMagicCheck04=ST1_MagicNumber + 3;
         if ( OpenProfitMagicCheck03 != OpenProfitMagicCheck04 )
         {
           OpenProfitMagicCheck04 = SelectedTradeMagic();
           OpenProfitMagicCheck05=ST1_MagicNumber + 4;
           if ( OpenProfitMagicCheck04 != OpenProfitMagicCheck05 )
           {
             OpenProfitMagicCheck05 = SelectedTradeMagic();
             OpenProfitMagicCheck06=ST1_MagicNumber + 5;
             if ( OpenProfitMagicCheck05 != OpenProfitMagicCheck06 )
             {
               OpenProfitMagicCheck06 = SelectedTradeMagic();
               OpenProfitMagicCheck07=ST1_MagicNumber + 6;
               if ( OpenProfitMagicCheck06 != OpenProfitMagicCheck07 )
               {
                 OpenProfitMagicCheck07 = SelectedTradeMagic();
                 OpenProfitMagicCheck08=ST1_MagicNumber + 7;
                 if ( OpenProfitMagicCheck07 != OpenProfitMagicCheck08 )
                 {
                   OpenProfitMagicCheck08 = SelectedTradeMagic();
                   OpenProfitMagicCheck09=ST1_MagicNumber + 8;
                   if ( OpenProfitMagicCheck08 != OpenProfitMagicCheck09 )
                   {
                     OpenProfitMagicCheck09 = SelectedTradeMagic();
                     OpenProfitMagicCheck10=ST1_MagicNumber + 9;
                     if ( OpenProfitMagicCheck09 != OpenProfitMagicCheck10 )
                     {
                       OpenProfitMagicCheck10 = SelectedTradeMagic();
                       OpenProfitMagicCheck11=ST1_MagicNumber + 10;
                       if ( OpenProfitMagicCheck10 != OpenProfitMagicCheck11 )
                       {
                         OpenProfitMagicCheck11 = SelectedTradeMagic();
                         OpenProfitMagicCheck12=ST1_MagicNumber + 11;
                         if ( OpenProfitMagicCheck11 != OpenProfitMagicCheck12 )
                         {
                           OpenProfitMagicCheck12 = SelectedTradeMagic();
                           OpenProfitMagicCheck13=ST1_MagicNumber + 12;
                           if ( OpenProfitMagicCheck12 != OpenProfitMagicCheck13 )
                           {
                             OpenProfitMagicCheck13 = SelectedTradeMagic();
                             OpenProfitMagicCheck14=ST1_MagicNumber + 13;
                             if ( OpenProfitMagicCheck13 != OpenProfitMagicCheck14 )
                             {
                               OpenProfitMagicCheck14 = SelectedTradeMagic();
                               OpenProfitMagicCheck15=ST1_MagicNumber + 14;
                               if ( OpenProfitMagicCheck14 != OpenProfitMagicCheck15 )
                               {
                                 OpenProfitMagicCheck15 = SelectedTradeMagic();
                                 OpenProfitMagicCheck16=ST1_MagicNumber + 15;
                               if ( OpenProfitMagicCheck15 != OpenProfitMagicCheck16 )   continue;
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
     OpenProfitAccumulator = SelectedTradeProfit() + SelectedTradeSwap() + SelectedTradeCommission() + OpenProfitAccumulator;
     
   }
   OpenProfitByStrategy[CurrentStrategyIndex] = OpenProfitAccumulator;
   DisplayOpenProfit = OpenProfitAccumulator;
 }
 ObjectSetString(0,"lineopl" + IntegerToString(0,0,32),OBJPROP_TEXT,"Open P/L: " + DoubleToString(DisplayOpenProfit,2)); 
 ObjectSetString(0,"linea" + IntegerToString(0,0,32),OBJPROP_TEXT,"Account Balance: " + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE),2)); 
 if ( ActiveTradeFrequency == 1 )
 {
   TradeFrequencyText = "conservative" ;
 }
 else
 {
   if ( ActiveTradeFrequency == 2 )
   {
     TradeFrequencyText = "moderate" ;
   }
   else
   {
     if ( ActiveTradeFrequency == 3 )
     {
       TradeFrequencyText = "intense" ;
     }
     else
     {
       if ( ActiveTradeFrequency == 4 )
       {
         TradeFrequencyText = "extreme" ;
       }
       else
       {
         if ( ActiveTradeFrequency == 0 )
         {
           TradeFrequencyText = "extreme conservative" ;
         }
         else
         {
           TradeFrequencyText = "manual strategy selection" ;
         }
       }
     }
   }
 }
 ObjectSetString(0,"lines",OBJPROP_TEXT,"Trade Frequency: " + TradeFrequencyText); 
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
     ObjectSetString(0,"linet",OBJPROP_TEXT,"Manual lotsize: " + string(StartLots_rw) + "lots"); 
   }
 }
 }
//UpdateInfoPanelSummary <<==--------   --------
 void UpdateInfoPanelStrategyRows()
 {
  int       CellObjectIndex;
  string    CellText;
  int       StrategyIndex;
//----------------------------------------------------------------------

 if ( !(ShowInfoPanel) )   return;
 
 if ( ( MQLInfoInteger(MQL_TESTER) == 1 && !(UpdateInfoTesting) ) )   return;
 CellObjectIndex = PanelStrategyRowStartIndex ;
 for (StrategyIndex = 0 ; StrategyIndex < 9 ; StrategyIndex ++)
 {
   CellText="Strategy " + IntegerToString(StrategyIndex + 1,0,32);
   ObjectSetString(0,"info_ea" + IntegerToString(CellObjectIndex,0,32),OBJPROP_TEXT,CellText); 
   CellObjectIndex ++;
   CellText = DoubleToString(NormalizeDouble(StrategyDisplayProfit[StrategyIndex],2),2) ;
   ObjectSetString(0,"info_ea" + IntegerToString(CellObjectIndex,0,32),OBJPROP_TEXT,CellText); 
   CellObjectIndex ++;
   CellText = DoubleToString(NormalizeDouble(AverageProfitByStrategy[StrategyIndex],2),2) ;
   ObjectSetString(0,"info_ea" + IntegerToString(CellObjectIndex,0,32),OBJPROP_TEXT,CellText); 
   CellObjectIndex ++;
   CellText = DoubleToString(NormalizeDouble(LotSizeByStrategy[StrategyIndex],2),2) ;
   ObjectSetString(0,"info_ea" + IntegerToString(CellObjectIndex,0,32),OBJPROP_TEXT,CellText); 
   CellObjectIndex ++;
 }
 }
//UpdateInfoPanelStrategyRows <<==--------   --------
 void UpdateInfoPanelTotals()
 {
 double     DisplayClosedProfit;
 double     ClosedProfitAccumulator;
 int        PanelClosedTradeCount;
 int        HistoryScanIndex;
 long        ClosedProfitMagicCheck01;
 long        ClosedProfitMagicCheck02;
 long        ClosedProfitMagicCheck03;
 long        ClosedProfitMagicCheck04;
 long        ClosedProfitMagicCheck05;
 long        ClosedProfitMagicCheck06;
 long        ClosedProfitMagicCheck07;
 long        ClosedProfitMagicCheck08;
 long        ClosedProfitMagicCheck09;
 long        ClosedProfitMagicCheck10;
 long        ClosedProfitMagicCheck11;
 long        ClosedProfitMagicCheck12;
 long        ClosedProfitMagicCheck13;
 long        ClosedProfitMagicCheck14;
 long        ClosedProfitMagicCheck15;
 long        ClosedProfitMagicCheck16;

 if ( !(ShowInfoPanel) )   return;
 
 if ( ( MQLInfoInteger(MQL_TESTER) == 1 && !(UpdateInfoTesting) ) )   return;
 ObjectSetString(0,"lineto" + IntegerToString(0,0,32),OBJPROP_TEXT,"Total profits/losses so far: " + IntegerToString(CountWinningClosedTrades(0,9999999),0,32) + "/" + IntegerToString(CountLosingClosedTrades(0,9999999),0,32)); 
 if ( MQLInfoInteger(MQL_TESTER) == 1 && !(UpdateInfoTesting) )
 {
   DisplayClosedProfit = 0.0;
 }
 else
 {
   ClosedProfitAccumulator = 0.0;
   PanelClosedTradeCount = 0;
   for (HistoryScanIndex = ClosedTradeCount() ; HistoryScanIndex >= 0 ; HistoryScanIndex=HistoryScanIndex - 1)
   {
     if ( SelectTradeRecord(HistoryScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_HISTORY) != true )   continue;
     
     if ( ( SelectedTradeSymbol() != CurrentSymbol && !(OneChartSetupEnabled) ) )   continue;
     ClosedProfitMagicCheck01 = SelectedTradeMagic();
     ClosedProfitMagicCheck02=ST1_MagicNumber + 1;
     if ( ClosedProfitMagicCheck01 != ClosedProfitMagicCheck02 )
     {
       ClosedProfitMagicCheck02 = SelectedTradeMagic();
       ClosedProfitMagicCheck03=ST1_MagicNumber + 2;
       if ( ClosedProfitMagicCheck02 != ClosedProfitMagicCheck03 )
       {
         ClosedProfitMagicCheck03 = SelectedTradeMagic();
         ClosedProfitMagicCheck04=ST1_MagicNumber + 3;
         if ( ClosedProfitMagicCheck03 != ClosedProfitMagicCheck04 )
         {
           ClosedProfitMagicCheck04 = SelectedTradeMagic();
           ClosedProfitMagicCheck05=ST1_MagicNumber + 4;
           if ( ClosedProfitMagicCheck04 != ClosedProfitMagicCheck05 )
           {
             ClosedProfitMagicCheck05 = SelectedTradeMagic();
             ClosedProfitMagicCheck06=ST1_MagicNumber + 5;
             if ( ClosedProfitMagicCheck05 != ClosedProfitMagicCheck06 )
             {
               ClosedProfitMagicCheck06 = SelectedTradeMagic();
               ClosedProfitMagicCheck07=ST1_MagicNumber + 6;
               if ( ClosedProfitMagicCheck06 != ClosedProfitMagicCheck07 )
               {
                 ClosedProfitMagicCheck07 = SelectedTradeMagic();
                 ClosedProfitMagicCheck08=ST1_MagicNumber + 7;
                 if ( ClosedProfitMagicCheck07 != ClosedProfitMagicCheck08 )
                 {
                   ClosedProfitMagicCheck08 = SelectedTradeMagic();
                   ClosedProfitMagicCheck09=ST1_MagicNumber + 8;
                   if ( ClosedProfitMagicCheck08 != ClosedProfitMagicCheck09 )
                   {
                     ClosedProfitMagicCheck09 = SelectedTradeMagic();
                     ClosedProfitMagicCheck10=ST1_MagicNumber + 9;
                     if ( ClosedProfitMagicCheck09 != ClosedProfitMagicCheck10 )
                     {
                       ClosedProfitMagicCheck10 = SelectedTradeMagic();
                       ClosedProfitMagicCheck11=ST1_MagicNumber + 10;
                       if ( ClosedProfitMagicCheck10 != ClosedProfitMagicCheck11 )
                       {
                         ClosedProfitMagicCheck11 = SelectedTradeMagic();
                         ClosedProfitMagicCheck12=ST1_MagicNumber + 11;
                         if ( ClosedProfitMagicCheck11 != ClosedProfitMagicCheck12 )
                         {
                           ClosedProfitMagicCheck12 = SelectedTradeMagic();
                           ClosedProfitMagicCheck13=ST1_MagicNumber + 12;
                           if ( ClosedProfitMagicCheck12 != ClosedProfitMagicCheck13 )
                           {
                             ClosedProfitMagicCheck13 = SelectedTradeMagic();
                             ClosedProfitMagicCheck14=ST1_MagicNumber + 13;
                             if ( ClosedProfitMagicCheck13 != ClosedProfitMagicCheck14 )
                             {
                               ClosedProfitMagicCheck14 = SelectedTradeMagic();
                               ClosedProfitMagicCheck15=ST1_MagicNumber + 14;
                               if ( ClosedProfitMagicCheck14 != ClosedProfitMagicCheck15 )
                               {
                                 ClosedProfitMagicCheck15 = SelectedTradeMagic();
                                 ClosedProfitMagicCheck16=ST1_MagicNumber + 15;
                               if ( ClosedProfitMagicCheck15 != ClosedProfitMagicCheck16 )   continue;
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
     PanelClosedTradeCount=PanelClosedTradeCount + 1;
     ClosedProfitAccumulator = ClosedProfitAccumulator + SelectedTradeProfit() + SelectedTradeSwap() + SelectedTradeCommission();
     if ( PanelClosedTradeCount >= 1000 )   break;
     
   }
   ClosedProfitByStrategy[CurrentStrategyIndex] = ClosedProfitAccumulator;
   DisplayClosedProfit = ClosedProfitAccumulator;
 }
 ObjectSetString(0,"linetp" + IntegerToString(0,0,32),OBJPROP_TEXT,"Total P/L so far: " + DoubleToString(NormalizeDouble(DisplayClosedProfit,2),2));
 if ( EnableNFP_Filter )
 {
   ObjectSetString(0,"linenfp" + IntegerToString(0,0,32),OBJPROP_TEXT,GetNextNFPText());
 }
 if ( OnlyUp )
 {
   ObjectSetString(0,"lineup" + IntegerToString(0,0,32),OBJPROP_TEXT,"Highest Balance: " + DoubleToString(NormalizeDouble(HighestBalanceBasis,2),2));
 }
 }
// UpdateInfoPanelTotals
 int CountWinningClosedTrades( int LegacyUnusedStartIndex,int MaximumTradesToScan)
 {
  double    TradeNetProfit;
  int       EligibleTradeCount;
  int       WinningTradeCount;
  int       HistoryScanIndex;
//----------------------------------------------------------------------
 long        MagicCheck01;
 long        MagicCheck02;
 long        MagicCheck03;
 long        MagicCheck04;
 long        MagicCheck05;
 long        MagicCheck06;
 long        MagicCheck07;
 long        MagicCheck08;
 long        MagicCheck09;
 long        MagicCheck10;
 long        MagicCheck11;
 long        MagicCheck12;
 long        MagicCheck13;
 long        MagicCheck14;
 long        MagicCheck15;
 long        MagicCheck16;

 if ( MQLInfoInteger(MQL_TESTER) == 1 && !(UpdateInfoTesting) )
 {
   return(0); 
 }
 TradeNetProfit = 0.0 ;
 EligibleTradeCount = 0 ;
 WinningTradeCount = 0 ;
 for (HistoryScanIndex = ClosedTradeCount() ; HistoryScanIndex >= 0 ; HistoryScanIndex --)
 {
   if ( SelectTradeRecord(HistoryScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_HISTORY) != true )   continue;
   
   if ( ( SelectedTradeSymbol() != CurrentSymbol && !(OneChartSetupEnabled) ) )   continue;
   MagicCheck01 = SelectedTradeMagic();
   MagicCheck02=ST1_MagicNumber + 1;
   if ( MagicCheck01 != MagicCheck02 )
   {
     MagicCheck02 = SelectedTradeMagic();
     MagicCheck03=ST1_MagicNumber + 2;
     if ( MagicCheck02 != MagicCheck03 )
     {
       MagicCheck03 = SelectedTradeMagic();
       MagicCheck04=ST1_MagicNumber + 3;
       if ( MagicCheck03 != MagicCheck04 )
       {
         MagicCheck04 = SelectedTradeMagic();
         MagicCheck05=ST1_MagicNumber + 4;
         if ( MagicCheck04 != MagicCheck05 )
         {
           MagicCheck05 = SelectedTradeMagic();
           MagicCheck06=ST1_MagicNumber + 5;
           if ( MagicCheck05 != MagicCheck06 )
           {
             MagicCheck06 = SelectedTradeMagic();
             MagicCheck07=ST1_MagicNumber + 6;
             if ( MagicCheck06 != MagicCheck07 )
             {
               MagicCheck07 = SelectedTradeMagic();
               MagicCheck08=ST1_MagicNumber + 7;
               if ( MagicCheck07 != MagicCheck08 )
               {
                 MagicCheck08 = SelectedTradeMagic();
                 MagicCheck09=ST1_MagicNumber + 8;
                 if ( MagicCheck08 != MagicCheck09 )
                 {
                   MagicCheck09 = SelectedTradeMagic();
                   MagicCheck10=ST1_MagicNumber + 9;
                   if ( MagicCheck09 != MagicCheck10 )
                   {
                     MagicCheck10 = SelectedTradeMagic();
                     MagicCheck11=ST1_MagicNumber + 10;
                     if ( MagicCheck10 != MagicCheck11 )
                     {
                       MagicCheck11 = SelectedTradeMagic();
                       MagicCheck12=ST1_MagicNumber + 11;
                       if ( MagicCheck11 != MagicCheck12 )
                       {
                         MagicCheck12 = SelectedTradeMagic();
                         MagicCheck13=ST1_MagicNumber + 12;
                         if ( MagicCheck12 != MagicCheck13 )
                         {
                           MagicCheck13 = SelectedTradeMagic();
                           MagicCheck14=ST1_MagicNumber + 13;
                           if ( MagicCheck13 != MagicCheck14 )
                           {
                             MagicCheck14 = SelectedTradeMagic();
                             MagicCheck15=ST1_MagicNumber + 14;
                             if ( MagicCheck14 != MagicCheck15 )
                             {
                               MagicCheck15 = SelectedTradeMagic();
                               MagicCheck16=ST1_MagicNumber + 15;
                             if ( MagicCheck15 != MagicCheck16 )   continue;
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
   EligibleTradeCount ++;
   if ( ( SelectedTradeType() == ORDER_TYPE_BUY || SelectedTradeType() == ORDER_TYPE_SELL ) )
   {
     if ( SelectedTradeType() == ORDER_TYPE_BUY )
     {
       TradeNetProfit = SelectedTradeClosePrice() - SelectedTradeOpenPrice() ;
     }
     else
     {
       if ( SelectedTradeType() == ORDER_TYPE_SELL )
       {
         TradeNetProfit = SelectedTradeOpenPrice() - SelectedTradeClosePrice() ;
       }
     }
     if ( TradeNetProfit>0.0 )
     {
       WinningTradeCount ++;
     }
   }
   if ( EligibleTradeCount >= MaximumTradesToScan )   break;
   
 }
 WinningTradesByStrategy[CurrentStrategyIndex] = WinningTradeCount;
 return(WinningTradeCount); 
 }
// CountWinningClosedTrades
 int CountLosingClosedTrades( int LegacyUnusedStartIndex,int MaximumTradesToScan)
 {
  double    TradeNetProfit;
  int       EligibleTradeCount;
  int       LosingTradeCount;
  int       HistoryScanIndex;
//----------------------------------------------------------------------
 long        MagicCheck01;
 long        MagicCheck02;
 long        MagicCheck03;
 long        MagicCheck04;
 long        MagicCheck05;
 long        MagicCheck06;
 long        MagicCheck07;
 long        MagicCheck08;
 long        MagicCheck09;
 long        MagicCheck10;
 long        MagicCheck11;
 long        MagicCheck12;
 long        MagicCheck13;
 long        MagicCheck14;
 long        MagicCheck15;
 long        MagicCheck16;

 if ( MQLInfoInteger(MQL_TESTER) == 1 && !(UpdateInfoTesting) )
 {
   return(0); 
 }
 TradeNetProfit = 0.0 ;
 EligibleTradeCount = 0 ;
 LosingTradeCount = 0 ;
 for (HistoryScanIndex = ClosedTradeCount() ; HistoryScanIndex >= 0 ; HistoryScanIndex --)
 {
   if ( SelectTradeRecord(HistoryScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_HISTORY) != true )   continue;
   
   if ( ( SelectedTradeSymbol() != CurrentSymbol && !(OneChartSetupEnabled) ) )   continue;
   MagicCheck01 = SelectedTradeMagic();
   MagicCheck02=ST1_MagicNumber + 1;
   if ( MagicCheck01 != MagicCheck02 )
   {
     MagicCheck02 = SelectedTradeMagic();
     MagicCheck03=ST1_MagicNumber + 2;
     if ( MagicCheck02 != MagicCheck03 )
     {
       MagicCheck03 = SelectedTradeMagic();
       MagicCheck04=ST1_MagicNumber + 3;
       if ( MagicCheck03 != MagicCheck04 )
       {
         MagicCheck04 = SelectedTradeMagic();
         MagicCheck05=ST1_MagicNumber + 4;
         if ( MagicCheck04 != MagicCheck05 )
         {
           MagicCheck05 = SelectedTradeMagic();
           MagicCheck06=ST1_MagicNumber + 5;
           if ( MagicCheck05 != MagicCheck06 )
           {
             MagicCheck06 = SelectedTradeMagic();
             MagicCheck07=ST1_MagicNumber + 6;
             if ( MagicCheck06 != MagicCheck07 )
             {
               MagicCheck07 = SelectedTradeMagic();
               MagicCheck08=ST1_MagicNumber + 7;
               if ( MagicCheck07 != MagicCheck08 )
               {
                 MagicCheck08 = SelectedTradeMagic();
                 MagicCheck09=ST1_MagicNumber + 8;
                 if ( MagicCheck08 != MagicCheck09 )
                 {
                   MagicCheck09 = SelectedTradeMagic();
                   MagicCheck10=ST1_MagicNumber + 9;
                   if ( MagicCheck09 != MagicCheck10 )
                   {
                     MagicCheck10 = SelectedTradeMagic();
                     MagicCheck11=ST1_MagicNumber + 10;
                     if ( MagicCheck10 != MagicCheck11 )
                     {
                       MagicCheck11 = SelectedTradeMagic();
                       MagicCheck12=ST1_MagicNumber + 11;
                       if ( MagicCheck11 != MagicCheck12 )
                       {
                         MagicCheck12 = SelectedTradeMagic();
                         MagicCheck13=ST1_MagicNumber + 12;
                         if ( MagicCheck12 != MagicCheck13 )
                         {
                           MagicCheck13 = SelectedTradeMagic();
                           MagicCheck14=ST1_MagicNumber + 13;
                           if ( MagicCheck13 != MagicCheck14 )
                           {
                             MagicCheck14 = SelectedTradeMagic();
                             MagicCheck15=ST1_MagicNumber + 14;
                             if ( MagicCheck14 != MagicCheck15 )
                             {
                               MagicCheck15 = SelectedTradeMagic();
                               MagicCheck16=ST1_MagicNumber + 15;
                             if ( MagicCheck15 != MagicCheck16 )   continue;
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
   EligibleTradeCount ++;
   if ( SelectedTradeType() == ORDER_TYPE_BUY )
   {
     TradeNetProfit = SelectedTradeClosePrice() - SelectedTradeOpenPrice() ;
   }
   else
   {
     if ( SelectedTradeType() == ORDER_TYPE_SELL )
     {
       TradeNetProfit = SelectedTradeOpenPrice() - SelectedTradeClosePrice() ;
     }
   }
   if ( TradeNetProfit<0.0 )
   {
     LosingTradeCount ++;
   }
   if ( EligibleTradeCount >= MaximumTradesToScan )   break;
   
 }
 LosingTradesByStrategy[CurrentStrategyIndex] = LosingTradeCount;
 return(LosingTradeCount); 
 }
//CountLosingClosedTrades <<==--------   --------
 void CalculateStrategyPerformance()
 {
  int       UnusedStrategyCounter = 0;
  double    LookbackProfitByStrategy[99];
  double    RecentWindowProfitByStrategy[99];
  int       StrategyResetIndex;
  int       HistoryScanIndex;
  bool      AllStrategiesComplete;
  int       CompletionCheckIndex;
  double    ProfitNormalizationFactor;
  int       SymbolStrategyIndex;
  int       ResultStrategyIndex;
//----------------------------------------------------------------------
 long       OrderCloseTime;
 long       LookbackCutoffTime;
 long       LookbackCutoffConfirmation;
 long       RecentOrderCloseTime;
 long       RecentCutoffTime;

 if ( ( MQLInfoInteger(MQL_TESTER) == 1 && !(UpdateInfoTesting) ) )   return;
 for (StrategyResetIndex = 0 ; StrategyResetIndex < StrategySymbolCount ; StrategyResetIndex ++)
 {
   LookbackProfitByStrategy[StrategyResetIndex] = 0.0;
   RecentWindowProfitByStrategy[StrategyResetIndex] = 0.0;
   PerformanceHistoryComplete[StrategyResetIndex] = false;
   TotalTradeCountByStrategy[StrategyResetIndex] = 0;
   RecentTradeCountByStrategy[StrategyResetIndex] = 0;
 }
 for (HistoryScanIndex = ClosedTradeCount() ; HistoryScanIndex >= 0 ; HistoryScanIndex --)
 {
   if ( SelectTradeRecord(HistoryScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_HISTORY) != true || SelectedTradeMagic() != StrategyMagicNumber )   continue;
   AllStrategiesComplete = true ;
   for (CompletionCheckIndex = 0 ; CompletionCheckIndex < StrategySymbolCount ; CompletionCheckIndex ++)
   {
     if ( !(PerformanceHistoryComplete[CompletionCheckIndex]) )
     {
       AllStrategiesComplete = false ;
     }
   }
   if ( ( SelectedTradeCloseTime() <  TimeCurrent() - PerformanceLookbackDays * 24 * 60 * 60 && AllStrategiesComplete ) )   break;
   ProfitNormalizationFactor = SelectedTradeVolume() * 100.0 ;
   if ( PerformanceCalculationMode == 1 )
   {
     ProfitNormalizationFactor = 1.0 ;
   }
   SymbolStrategyIndex = 0 ;
   if ( StrategySymbolCount <= 0 )   continue;
   
   for ( ; SymbolStrategyIndex < StrategySymbolCount ; SymbolStrategyIndex ++)
   {
     if ( StrategySymbols[SymbolStrategyIndex] != SelectedTradeSymbol() )   continue;
     
     if ( ( SelectedTradeType() != ORDER_TYPE_BUY && SelectedTradeType() != ORDER_TYPE_SELL ) )   continue;
     OrderCloseTime = SelectedTradeCloseTime();
     LookbackCutoffTime=TimeCurrent() - PerformanceLookbackDays * 24 * 60 * 60;
     if ( OrderCloseTime <  LookbackCutoffTime )
     {
       LookbackCutoffTime = SelectedTradeCloseTime();
       LookbackCutoffConfirmation=TimeCurrent() - PerformanceLookbackDays * 24 * 60 * 60;
     if ( (LookbackCutoffTime >= LookbackCutoffConfirmation || PerformanceHistoryComplete[SymbolStrategyIndex]) )   continue;
     }
     TotalTradeCountByStrategy[SymbolStrategyIndex] ++;
     if ( TotalTradeCountByStrategy[SymbolStrategyIndex] >= MinTradesForPerformance )
     {
       PerformanceHistoryComplete[SymbolStrategyIndex] = true;
     }
     LookbackProfitByStrategy[SymbolStrategyIndex] +=SelectedTradeProfit() / ProfitNormalizationFactor;
     LookbackProfitByStrategy[SymbolStrategyIndex] +=SelectedTradeSwap() / ProfitNormalizationFactor;
     LookbackProfitByStrategy[SymbolStrategyIndex] +=SelectedTradeCommission() / ProfitNormalizationFactor;
     RecentOrderCloseTime = SelectedTradeCloseTime();
     RecentCutoffTime=TimeCurrent() - RecentPerformanceDays * 24 * 60 * 60;
     if ( RecentOrderCloseTime < RecentCutoffTime )   continue;
     RecentWindowProfitByStrategy[SymbolStrategyIndex] +=SelectedTradeProfit() / ProfitNormalizationFactor;
     RecentWindowProfitByStrategy[SymbolStrategyIndex] +=SelectedTradeSwap() / ProfitNormalizationFactor;
     RecentWindowProfitByStrategy[SymbolStrategyIndex] +=SelectedTradeCommission() / ProfitNormalizationFactor;
     RecentTradeCountByStrategy[SymbolStrategyIndex] ++;
     
   }
   
 }
 for (ResultStrategyIndex = 0 ; ResultStrategyIndex < StrategySymbolCount ; ResultStrategyIndex ++)
 {
   TotalProfitByStrategy[ResultStrategyIndex] = LookbackProfitByStrategy[ResultStrategyIndex];
   if ( TotalTradeCountByStrategy[ResultStrategyIndex] >  0 )
   {
     AverageProfitByStrategy[ResultStrategyIndex] = NormalizeDouble(LookbackProfitByStrategy[ResultStrategyIndex] / TotalTradeCountByStrategy[ResultStrategyIndex],2);
   }
   else
   {
     AverageProfitByStrategy[ResultStrategyIndex] = 0.0;
   }
   RecentProfitByStrategy[ResultStrategyIndex] = RecentWindowProfitByStrategy[ResultStrategyIndex];
   if ( RecentTradeCountByStrategy[ResultStrategyIndex] >  0 )
   {
     RecentAverageProfitByStrategy[ResultStrategyIndex] = NormalizeDouble(RecentWindowProfitByStrategy[ResultStrategyIndex] / RecentTradeCountByStrategy[ResultStrategyIndex],2);
   }
   else
   {
     RecentAverageProfitByStrategy[ResultStrategyIndex] = 0.0;
   }
 }
 }
//CalculateStrategyPerformance <<==--------   --------
 void RankStrategiesByTotalProfit()
 {
  int       StrategyIndex;
  double    StrategyMetric;
  int       ComputedRank;
  int       ComparisonIndex;
  int       DuplicateCheckStrategy;
  int       OriginalRank;
  bool      RankCollisionFound;
  int       RankCollisionScanIndex;
  int       WeightResetIndex;
  int       RankPosition;
  int       StrategyLookupIndex;
//----------------------------------------------------------------------

 CalculateStrategyPerformance(); 
 for (StrategyIndex = 0 ; StrategyIndex < StrategySymbolCount ; StrategyIndex ++)
 {
   StrategyMetric = TotalProfitByStrategy[StrategyIndex] ;
   ComputedRank = 1 ;
   for (ComparisonIndex = 0 ; ComparisonIndex < StrategySymbolCount ; ComparisonIndex ++)
   {
     if ( ComparisonIndex == StrategyIndex || !(TotalProfitByStrategy[ComparisonIndex]>StrategyMetric) )   continue;
     ComputedRank ++;
     
   }
   StrategyRanks[StrategyIndex] = ComputedRank;
 }
 for (DuplicateCheckStrategy = 0 ; DuplicateCheckStrategy < StrategySymbolCount ; DuplicateCheckStrategy ++)
 {
   OriginalRank = StrategyRanks[DuplicateCheckStrategy] ;
   RankCollisionFound = true ;
   do
   {
     RankCollisionFound = false ;
     RankCollisionScanIndex = 0 ;
     if ( StrategySymbolCount <= 0 )   continue;
     
     for ( ; RankCollisionScanIndex < StrategySymbolCount ; RankCollisionScanIndex ++)
     {
       if ( RankCollisionScanIndex == DuplicateCheckStrategy || StrategyRanks[RankCollisionScanIndex] != StrategyRanks[DuplicateCheckStrategy] )   continue;
       StrategyRanks[RankCollisionScanIndex] ++;
       RankCollisionFound = true ;
       
     }
     
   }
   while(RankCollisionFound);
   
 }
 for (WeightResetIndex = 0 ; WeightResetIndex < StrategySymbolCount ; WeightResetIndex ++)
 {
   StrategyLotWeights[WeightResetIndex] = 1.0;
 }
 for (RankPosition = 1 ; RankPosition <= StrategySymbolCount ; RankPosition ++)
 {
   for (StrategyLookupIndex = 0 ; StrategyLookupIndex < StrategySymbolCount ; StrategyLookupIndex ++)
   {
     if ( StrategyRanks[StrategyLookupIndex] == RankPosition )
     {
       RankedStrategyIndexes[RankPosition - 1] = StrategyLookupIndex;
     }
   }
 }
 }
//RankStrategiesByTotalProfit <<==--------   --------
 void RankStrategiesByAverageProfit()
 {
  int       StrategyIndex;
  double    StrategyMetric;
  int       ComputedRank;
  int       ComparisonIndex;
  int       DuplicateCheckStrategy;
  int       OriginalRank;
  bool      RankCollisionFound;
  int       RankCollisionScanIndex;
  int       WeightResetIndex;
  int       RankPosition;
  int       StrategyLookupIndex;
//----------------------------------------------------------------------

 CalculateStrategyPerformance(); 
 for (StrategyIndex = 0 ; StrategyIndex < StrategySymbolCount ; StrategyIndex ++)
 {
   StrategyMetric = AverageProfitByStrategy[StrategyIndex] ;
   ComputedRank = 1 ;
   for (ComparisonIndex = 0 ; ComparisonIndex < StrategySymbolCount ; ComparisonIndex ++)
   {
     if ( ComparisonIndex == StrategyIndex || !(AverageProfitByStrategy[ComparisonIndex]>StrategyMetric) )   continue;
     ComputedRank ++;
     
   }
   StrategyRanks[StrategyIndex] = ComputedRank;
 }
 for (DuplicateCheckStrategy = 0 ; DuplicateCheckStrategy < StrategySymbolCount ; DuplicateCheckStrategy ++)
 {
   OriginalRank = StrategyRanks[DuplicateCheckStrategy] ;
   RankCollisionFound = true ;
   do
   {
     RankCollisionFound = false ;
     RankCollisionScanIndex = 0 ;
     if ( StrategySymbolCount <= 0 )   continue;
     
     for ( ; RankCollisionScanIndex < StrategySymbolCount ; RankCollisionScanIndex ++)
     {
       if ( RankCollisionScanIndex == DuplicateCheckStrategy || StrategyRanks[RankCollisionScanIndex] != StrategyRanks[DuplicateCheckStrategy] )   continue;
       StrategyRanks[RankCollisionScanIndex] ++;
       RankCollisionFound = true ;
       
     }
     
   }
   while(RankCollisionFound);
   
 }
 for (WeightResetIndex = 0 ; WeightResetIndex < StrategySymbolCount ; WeightResetIndex ++)
 {
   StrategyLotWeights[WeightResetIndex] = 1.0;
 }
 for (RankPosition = 1 ; RankPosition <= StrategySymbolCount ; RankPosition ++)
 {
   for (StrategyLookupIndex = 0 ; StrategyLookupIndex < StrategySymbolCount ; StrategyLookupIndex ++)
   {
     if ( StrategyRanks[StrategyLookupIndex] == RankPosition )
     {
       RankedStrategyIndexes[RankPosition - 1] = StrategyLookupIndex;
     }
   }
 }
 }
//RankStrategiesByAverageProfit <<==--------   --------
 double ConvertUsdToAccountCurrency( double AmountUsd)
 {
  double    ConvertedAmount;
  string    ConversionSymbol;
//----------------------------------------------------------------------

 ConvertedAmount = AmountUsd ;
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "USD" || AccountInfoString(ACCOUNT_CURRENCY) == "usd" ) )
 {
   ConvertedAmount = AmountUsd ;
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "EUR" || AccountInfoString(ACCOUNT_CURRENCY) == "eur" ) )
 {
   ConversionSymbol="EURUSD" + SymbolSuffix;
   if ( iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     ConvertedAmount = AmountUsd / iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "GBP" || AccountInfoString(ACCOUNT_CURRENCY) == "gbp" ) )
 {
   ConversionSymbol="GBPUSD" + SymbolSuffix;
   if ( iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     ConvertedAmount = AmountUsd / iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "AUD" || AccountInfoString(ACCOUNT_CURRENCY) == "aud" ) )
 {
   ConversionSymbol="AUDUSD" + SymbolSuffix;
   if ( iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     ConvertedAmount = AmountUsd / iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "JPY" || AccountInfoString(ACCOUNT_CURRENCY) == "jpy" || AccountInfoString(ACCOUNT_CURRENCY) == "YEN" || AccountInfoString(ACCOUNT_CURRENCY) == "yen" ) )
 {
   ConversionSymbol="USDJPY" + SymbolSuffix;
   if ( iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     ConvertedAmount = AmountUsd * iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "CHF" || AccountInfoString(ACCOUNT_CURRENCY) == "chf" ) )
 {
   ConversionSymbol="USDCHF" + SymbolSuffix;
   if ( iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     ConvertedAmount = AmountUsd * iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "HKD" || AccountInfoString(ACCOUNT_CURRENCY) == "hkd" ) )
 {
   ConversionSymbol="USDHKD" + SymbolSuffix;
   if ( iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     ConvertedAmount = AmountUsd * iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "SGD" || AccountInfoString(ACCOUNT_CURRENCY) == "sgd" ) )
 {
   ConversionSymbol="USDSGD" + SymbolSuffix;
   if ( iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     ConvertedAmount = AmountUsd * iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "PLN" || AccountInfoString(ACCOUNT_CURRENCY) == "pln" ) )
 {
   ConversionSymbol="USDPLN" + SymbolSuffix;
   if ( iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     ConvertedAmount = AmountUsd * iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "RUB" || AccountInfoString(ACCOUNT_CURRENCY) == "rub" ) )
 {
   ConversionSymbol="USDRUB" + SymbolSuffix;
   if ( iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     ConvertedAmount = AmountUsd * iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "BTC" || AccountInfoString(ACCOUNT_CURRENCY) == "btc" ) )
 {
   ConversionSymbol="BTCUSD" + SymbolSuffix;
   if ( iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     ConvertedAmount = AmountUsd / iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "ETH" || AccountInfoString(ACCOUNT_CURRENCY) == "eth" ) )
 {
   ConversionSymbol="ETHUSD" + SymbolSuffix;
   if ( iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     ConvertedAmount = AmountUsd / iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "BCH" || AccountInfoString(ACCOUNT_CURRENCY) == "bch" ) )
 {
   ConversionSymbol="BCHUSD" + SymbolSuffix;
   if ( iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     ConvertedAmount = AmountUsd / iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "BCC" || AccountInfoString(ACCOUNT_CURRENCY) == "bcc" ) )
 {
   ConversionSymbol="BCCUSD" + SymbolSuffix;
   if ( iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     ConvertedAmount = AmountUsd / iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "XRP" || AccountInfoString(ACCOUNT_CURRENCY) == "xrp" ) )
 {
   ConversionSymbol="XRPUSD" + SymbolSuffix;
   if ( iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     ConvertedAmount = AmountUsd / iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "LTC" || AccountInfoString(ACCOUNT_CURRENCY) == "ltc" ) )
 {
   ConversionSymbol="LTCUSD" + SymbolSuffix;
   if ( iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     ConvertedAmount = AmountUsd / iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "XMR" || AccountInfoString(ACCOUNT_CURRENCY) == "xmr" ) )
 {
   ConversionSymbol="XMRUSD" + SymbolSuffix;
   if ( iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     ConvertedAmount = AmountUsd / iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "DSH" || AccountInfoString(ACCOUNT_CURRENCY) == "dsh" ) )
 {
   ConversionSymbol="DSHUSD" + SymbolSuffix;
   if ( iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     ConvertedAmount = AmountUsd / iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "EOS" || AccountInfoString(ACCOUNT_CURRENCY) == "eos" ) )
 {
   ConversionSymbol="EOSUSD" + SymbolSuffix;
   if ( iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     ConvertedAmount = AmountUsd / iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "TRX" || AccountInfoString(ACCOUNT_CURRENCY) == "trx" ) )
 {
   ConversionSymbol="TRXUSD" + SymbolSuffix;
   if ( iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     ConvertedAmount = AmountUsd / iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "ADA" || AccountInfoString(ACCOUNT_CURRENCY) == "ada" ) )
 {
   ConversionSymbol="ADAUSD" + SymbolSuffix;
   if ( iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     ConvertedAmount = AmountUsd / iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "BSV" || AccountInfoString(ACCOUNT_CURRENCY) == "bsv" ) )
 {
   ConversionSymbol="BSVUSD" + SymbolSuffix;
   if ( iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     ConvertedAmount = AmountUsd / iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "XLM" || AccountInfoString(ACCOUNT_CURRENCY) == "xlm" ) )
 {
   ConversionSymbol="XLMUSD" + SymbolSuffix;
   if ( iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     ConvertedAmount = AmountUsd / iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "GLD" || AccountInfoString(ACCOUNT_CURRENCY) == "gld" ) )
 {
   ConversionSymbol="GLDUSD" + SymbolSuffix;
   if ( iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     ConvertedAmount = AmountUsd / iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "ZEC" || AccountInfoString(ACCOUNT_CURRENCY) == "zec" ) )
 {
   ConversionSymbol="ZECUSD" + SymbolSuffix;
   if ( iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     ConvertedAmount = AmountUsd / iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "XEM" || AccountInfoString(ACCOUNT_CURRENCY) == "xem" ) )
 {
   ConversionSymbol="XEMUSD" + SymbolSuffix;
   if ( iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     ConvertedAmount = AmountUsd / iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 return(ConvertedAmount); 
 }
//ConvertUsdToAccountCurrency <<==--------   --------
 double ConvertAccountCurrencyToUsdRounded( double AccountCurrencyAmount)
 {
  double    ConvertedAmountUsd;
  string    ConversionSymbol;
//----------------------------------------------------------------------

 ConvertedAmountUsd = AccountCurrencyAmount ;
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "USD" || AccountInfoString(ACCOUNT_CURRENCY) == "usd" ) )
 {
   ConvertedAmountUsd = AccountCurrencyAmount ;
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "EUR" || AccountInfoString(ACCOUNT_CURRENCY) == "eur" ) )
 {
   ConversionSymbol="EURUSD" + SymbolSuffix;
   if ( iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     ConvertedAmountUsd = AccountCurrencyAmount * iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "GBP" || AccountInfoString(ACCOUNT_CURRENCY) == "gbp" ) )
 {
   ConversionSymbol="GBPUSD" + SymbolSuffix;
   if ( iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     ConvertedAmountUsd = AccountCurrencyAmount * iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "AUD" || AccountInfoString(ACCOUNT_CURRENCY) == "aud" ) )
 {
   ConversionSymbol="AUDUSD" + SymbolSuffix;
   if ( iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     ConvertedAmountUsd = AccountCurrencyAmount * iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "JPY" || AccountInfoString(ACCOUNT_CURRENCY) == "jpy" || AccountInfoString(ACCOUNT_CURRENCY) == "YEN" || AccountInfoString(ACCOUNT_CURRENCY) == "yen" ) )
 {
   ConversionSymbol="USDJPY" + SymbolSuffix;
   if ( iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     ConvertedAmountUsd = AccountCurrencyAmount / iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "CHF" || AccountInfoString(ACCOUNT_CURRENCY) == "chf" ) )
 {
   ConversionSymbol="USDCHF" + SymbolSuffix;
   if ( iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     ConvertedAmountUsd = AccountCurrencyAmount / iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "HKD" || AccountInfoString(ACCOUNT_CURRENCY) == "hkd" ) )
 {
   ConversionSymbol="USDHKD" + SymbolSuffix;
   if ( iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     ConvertedAmountUsd = AccountCurrencyAmount / iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "RUB" || AccountInfoString(ACCOUNT_CURRENCY) == "rub" ) )
 {
   ConversionSymbol="USDRUB" + SymbolSuffix;
   if ( iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     ConvertedAmountUsd = AccountCurrencyAmount / iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "CNH" || AccountInfoString(ACCOUNT_CURRENCY) == "cnh" ) )
 {
   ConversionSymbol="USDCNH" + SymbolSuffix;
   if ( iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     ConvertedAmountUsd = AccountCurrencyAmount / iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
   else
   {
     ConversionSymbol="USDCNY" + SymbolSuffix;
     if ( iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
     {
       ConvertedAmountUsd = AccountCurrencyAmount / iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
     }
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "CNY" || AccountInfoString(ACCOUNT_CURRENCY) == "cny" ) )
 {
   ConversionSymbol="USDCNH" + SymbolSuffix;
   if ( iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     ConvertedAmountUsd = AccountCurrencyAmount / iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
   else
   {
     ConversionSymbol="USDCNY" + SymbolSuffix;
     if ( iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
     {
       ConvertedAmountUsd = AccountCurrencyAmount / iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
     }
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "SGD" || AccountInfoString(ACCOUNT_CURRENCY) == "sgd" ) )
 {
   ConversionSymbol="USDSGD" + SymbolSuffix;
   if ( iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     ConvertedAmountUsd = AccountCurrencyAmount / iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "BTC" || AccountInfoString(ACCOUNT_CURRENCY) == "btc" ) )
 {
   ConversionSymbol="BTCUSD" + SymbolSuffix;
   if ( iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     ConvertedAmountUsd = AccountCurrencyAmount * iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "ETH" || AccountInfoString(ACCOUNT_CURRENCY) == "eth" ) )
 {
   ConversionSymbol="ETHUSD" + SymbolSuffix;
   if ( iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     ConvertedAmountUsd = AccountCurrencyAmount * iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "BCH" || AccountInfoString(ACCOUNT_CURRENCY) == "bch" ) )
 {
   ConversionSymbol="BCHUSD" + SymbolSuffix;
   if ( iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     ConvertedAmountUsd = AccountCurrencyAmount * iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "BCC" || AccountInfoString(ACCOUNT_CURRENCY) == "bcc" ) )
 {
   ConversionSymbol="BCCUSD" + SymbolSuffix;
   if ( iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     ConvertedAmountUsd = AccountCurrencyAmount * iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "XRP" || AccountInfoString(ACCOUNT_CURRENCY) == "xrp" ) )
 {
   ConversionSymbol="XRPUSD" + SymbolSuffix;
   if ( iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     ConvertedAmountUsd = AccountCurrencyAmount * iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "LTC" || AccountInfoString(ACCOUNT_CURRENCY) == "ltc" ) )
 {
   ConversionSymbol="LTCUSD" + SymbolSuffix;
   if ( iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     ConvertedAmountUsd = AccountCurrencyAmount * iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "XMR" || AccountInfoString(ACCOUNT_CURRENCY) == "xmr" ) )
 {
   ConversionSymbol="XMRUSD" + SymbolSuffix;
   if ( iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     ConvertedAmountUsd = AccountCurrencyAmount * iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "DSH" || AccountInfoString(ACCOUNT_CURRENCY) == "dsh" ) )
 {
   ConversionSymbol="DSHUSD" + SymbolSuffix;
   if ( iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     ConvertedAmountUsd = AccountCurrencyAmount * iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "EOS" || AccountInfoString(ACCOUNT_CURRENCY) == "eos" ) )
 {
   ConversionSymbol="EOSUSD" + SymbolSuffix;
   if ( iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     ConvertedAmountUsd = AccountCurrencyAmount * iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "TRX" || AccountInfoString(ACCOUNT_CURRENCY) == "trx" ) )
 {
   ConversionSymbol="TRXUSD" + SymbolSuffix;
   if ( iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     ConvertedAmountUsd = AccountCurrencyAmount * iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "ADA" || AccountInfoString(ACCOUNT_CURRENCY) == "ada" ) )
 {
   ConversionSymbol="ADAUSD" + SymbolSuffix;
   if ( iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     ConvertedAmountUsd = AccountCurrencyAmount * iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "BSV" || AccountInfoString(ACCOUNT_CURRENCY) == "bsv" ) )
 {
   ConversionSymbol="BSVUSD" + SymbolSuffix;
   if ( iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     ConvertedAmountUsd = AccountCurrencyAmount * iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "XLM" || AccountInfoString(ACCOUNT_CURRENCY) == "xlm" ) )
 {
   ConversionSymbol="XLMUSD" + SymbolSuffix;
   if ( iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     ConvertedAmountUsd = AccountCurrencyAmount * iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "GLD" || AccountInfoString(ACCOUNT_CURRENCY) == "gld" ) )
 {
   ConversionSymbol="GLDUSD" + SymbolSuffix;
   if ( iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     ConvertedAmountUsd = AccountCurrencyAmount * iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "ZEC" || AccountInfoString(ACCOUNT_CURRENCY) == "zec" ) )
 {
   ConversionSymbol="ZECUSD" + SymbolSuffix;
   if ( iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     ConvertedAmountUsd = AccountCurrencyAmount * iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "XEM" || AccountInfoString(ACCOUNT_CURRENCY) == "xem" ) )
 {
   ConversionSymbol="XEMUSD" + SymbolSuffix;
   if ( iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1)>0.0 )
   {
     ConvertedAmountUsd = AccountCurrencyAmount * iClose(ConversionSymbol,NormalizeTimeframe(PERIOD_D1),1) ;
   }
 }
 return(MathRound(ConvertedAmountUsd)); 
 }
//ConvertAccountCurrencyToUsdRounded <<==--------   --------
 void LoadStrategy1Profile()
 {
 double     ProfileScratchValue01;
 double     ProfileScratchValue02;
 double     ProfileScratchValue03;
 double     ProfileScratchValue04;
 double     ProfileScratchValue05;
 double     ProfileScratchValue06;
 double     ProfileScratchValue07;
 double     ProfileScratchValue08;
 double     ProfileScratchValue09;
 double     ProfileScratchValue10;
 double     ProfileScratchValue11;
 double     ProfileScratchValue12;

 SignalTimeframeMinutes = 1440 ;
 EntryTimingTimeframeMinutes = 15 ;
 SwingLeftBars = 24 ;
 SwingRightBars = 3 ;
 EntryLookbackBars = 105 ;
 MinEntryDistancePips = 45.0 ;
 MinimumEntryDistancePercent = 0.0 ;
 ProfileScratchValue01 = AdjustEntry + -275.0;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue02 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue02 = 0.0;
 }
 BuyEntryOffsetPips = ProfileScratchValue01 + ProfileScratchValue02 ;
 ProfileScratchValue02 = AdjustEntry + -160.0;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue03 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue03 = 0.0;
 }
 SellEntryOffsetPips = ProfileScratchValue02 + ProfileScratchValue03 ;
 MaxPendingOrders = 5 ;
 DuplicatePendingTolerancePips = 30.0 ;
 PendingExpirationHours = 35 ;
 ExitTimingMode = 1 ;
 ProfileScratchValue03 = AdjustSL + 6100.0;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue04 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue04 = 0.0;
 }
 StopLossPips = ProfileScratchValue03 + ProfileScratchValue04 ;
 ProfileScratchValue04 = AdjustTP + 1450.0;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue05 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue05 = 0.0;
 }
 TakeProfitPips = ProfileScratchValue04 + ProfileScratchValue05 ;
 ProfileScratchValue05 = AdjustTrailSL + 1800.0;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue06 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue06 = 0.0;
 }
 TrailingSLStartPips = ProfileScratchValue05 + ProfileScratchValue06 ;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue07 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue07 = 0.0;
 }
 TrailingSLDistancePips = ProfileScratchValue07 + 1800.0 ;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue08 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue08 = 0.0;
 }
 TrailingSLStepLimitPips = ProfileScratchValue08 + 5000.0 ;
 TrailingActivationBufferPips = 0.1 ;
 TrailingPartialClosePercent = 0.0 ;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue09 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue09 = 0.0;
 }
 TrailingTPDistancePips = ProfileScratchValue09 + 1600.0 ;
 ProfileScratchValue09 = AdjustTrailTP + 700.0;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue10 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue10 = 0.0;
 }
 TrailingTPStartPips = ProfileScratchValue09 + ProfileScratchValue10 ;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue11 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue11 = 0.0;
 }
 BreakEvenStartPips = ProfileScratchValue11 + 930.0 ;
 ProfileScratchValue11 = AdjustBreakEven + 120.0;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue12 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue12 = 0.0;
 }
 BreakEvenExtraPips = ProfileScratchValue11 + ProfileScratchValue12 ;
 HighLowTrailingTimeframeMinutes = 60 ;
 SwingQualificationMinimumShift = 50 ;
 HighLowLeftBars = 14 ;
 HighLowRightBars = 12 ;
 HighLowLookbackBars = 300 ;
 HighLowTrailingOffsetPips = 22.0 ;
 MaxOpenTradesPerSide = 5 ;
 if ( !(RemoveCommentSuffix) )
 {
   CurrentStrategyComment=ST1_Comment + "_XAUUSD_1";
 }
 StrategyMagicNumber=ST1_MagicNumber + 1;
 StrategyDrawdownReferenceUsd = ConvertUsdToAccountCurrency(145.0) ;
 if ( !(UseVariableValues) )   return;
 LotSizeReferenceBalance = 2000.0 ;
 StrategyDrawdownReferenceUsd = ConvertUsdToAccountCurrency(60.0) ;
 }
//LoadStrategy1Profile <<==--------   --------
 void LoadStrategy2Profile()
 {
 double     ProfileScratchValue01;
 double     ProfileScratchValue02;
 double     ProfileScratchValue03;
 double     ProfileScratchValue04;
 double     ProfileScratchValue05;
 double     ProfileScratchValue06;
 double     ProfileScratchValue07;
 double     ProfileScratchValue08;
 double     ProfileScratchValue09;
 double     ProfileScratchValue10;
 double     ProfileScratchValue11;
 double     ProfileScratchValue12;
 double     ProfileScratchValue13;

 SignalTimeframeMinutes = 240 ;
 EntryTimingTimeframeMinutes = 60 ;
 SwingLeftBars = 12 ;
 SwingRightBars = 8 ;
 EntryLookbackBars = 90 ;
 MinEntryDistancePips = 1050.0 ;
 MinimumEntryDistancePercent = 0.0 ;
 ProfileScratchValue01 = AdjustEntry + -40.0;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue02 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue02 = 0.0;
 }
 BuyEntryOffsetPips = ProfileScratchValue01 + ProfileScratchValue02 ;
 ProfileScratchValue02 = AdjustEntry + -100.0;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue03 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue03 = 0.0;
 }
 SellEntryOffsetPips = ProfileScratchValue02 + ProfileScratchValue03 ;
 MaxPendingOrders = 2 ;
 DuplicatePendingTolerancePips = 130.0 ;
 PendingExpirationHours = 192 ;
 ExitTimingMode = 5 ;
 if ( !(UseHL_TrailingSL) )
 {
   ProfileScratchValue03 = AdjustSL + 700.0;
   if ( Randomization>0.0 )
   {
     ProfileScratchValue04 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
   }
   else
   {
     ProfileScratchValue04 = 0.0;
   }
   StopLossPips = ProfileScratchValue03 + ProfileScratchValue04 ;
 }
 else
 {
   ProfileScratchValue04 = AdjustSL + 800.0;
   if ( Randomization>0.0 )
   {
     ProfileScratchValue05 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
   }
   else
   {
     ProfileScratchValue05 = 0.0;
   }
   StopLossPips = ProfileScratchValue04 + ProfileScratchValue05 ;
 }
 ProfileScratchValue05 = AdjustTP + 4900.0;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue06 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue06 = 0.0;
 }
 TakeProfitPips = ProfileScratchValue05 + ProfileScratchValue06 ;
 ProfileScratchValue06 = AdjustTrailSL + 1300.0;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue07 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue07 = 0.0;
 }
 TrailingSLStartPips = ProfileScratchValue06 + ProfileScratchValue07 ;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue08 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue08 = 0.0;
 }
 TrailingSLDistancePips = ProfileScratchValue08 + 1450.0 ;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue09 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue09 = 0.0;
 }
 TrailingSLStepLimitPips = ProfileScratchValue09 + 2000.0 ;
 TrailingActivationBufferPips = 0.1 ;
 TrailingPartialClosePercent = 0.0 ;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue10 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue10 = 0.0;
 }
 TrailingTPDistancePips = ProfileScratchValue10 + 1400.0 ;
 ProfileScratchValue10 = AdjustTrailTP + 200.0;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue11 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue11 = 0.0;
 }
 TrailingTPStartPips = ProfileScratchValue10 + ProfileScratchValue11 ;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue12 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue12 = 0.0;
 }
 BreakEvenStartPips = ProfileScratchValue12 + 500.0 ;
 ProfileScratchValue12 = AdjustBreakEven + 200.0;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue13 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue13 = 0.0;
 }
 BreakEvenExtraPips = ProfileScratchValue12 + ProfileScratchValue13 ;
 HighLowTrailingTimeframeMinutes = 60 ;
 SwingQualificationMinimumShift = 50 ;
 HighLowLeftBars = 14 ;
 HighLowRightBars = 6 ;
 HighLowLookbackBars = 400 ;
 HighLowTrailingOffsetPips = 32.0 ;
 MaxOpenTradesPerSide = 99 ;
 if ( !(RemoveCommentSuffix) )
 {
   CurrentStrategyComment=ST1_Comment + "_XAUUSD_4";
 }
 StrategyMagicNumber=ST1_MagicNumber + 2;
 StrategyDrawdownReferenceUsd = ConvertUsdToAccountCurrency(57.0) ;
 if ( !(UseVariableValues) )   return;
 LotSizeReferenceBalance = 1600.0 ;
 StrategyDrawdownReferenceUsd = ConvertUsdToAccountCurrency(52.0) ;
 }
//LoadStrategy2Profile <<==--------   --------
 void LoadStrategy3Profile()
 {
 double     ProfileScratchValue01;
 double     ProfileScratchValue02;
 double     ProfileScratchValue03;
 double     ProfileScratchValue04;
 double     ProfileScratchValue05;
 double     ProfileScratchValue06;
 double     ProfileScratchValue07;
 double     ProfileScratchValue08;
 double     ProfileScratchValue09;
 double     ProfileScratchValue10;
 double     ProfileScratchValue11;
 double     ProfileScratchValue12;

 SignalTimeframeMinutes = 1440 ;
 EntryTimingTimeframeMinutes = 60 ;
 SwingLeftBars = 15 ;
 SwingRightBars = 3 ;
 EntryLookbackBars = 230 ;
 MinEntryDistancePips = 550.0 ;
 MinimumEntryDistancePercent = 0.0 ;
 ProfileScratchValue01 = AdjustEntry + -170.0;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue02 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue02 = 0.0;
 }
 BuyEntryOffsetPips = ProfileScratchValue01 + ProfileScratchValue02 ;
 ProfileScratchValue02 = AdjustEntry + -70.0;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue03 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue03 = 0.0;
 }
 SellEntryOffsetPips = ProfileScratchValue02 + ProfileScratchValue03 ;
 MaxPendingOrders = 1 ;
 DuplicatePendingTolerancePips = 480.0 ;
 PendingExpirationHours = 480 ;
 ExitTimingMode = 1 ;
 ProfileScratchValue03 = AdjustSL + 1000.0;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue04 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue04 = 0.0;
 }
 StopLossPips = ProfileScratchValue03 + ProfileScratchValue04 ;
 ProfileScratchValue04 = AdjustTP + 4100.0;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue05 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue05 = 0.0;
 }
 TakeProfitPips = ProfileScratchValue04 + ProfileScratchValue05 ;
 ProfileScratchValue05 = AdjustTrailSL + 450.0;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue06 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue06 = 0.0;
 }
 TrailingSLStartPips = ProfileScratchValue05 + ProfileScratchValue06 ;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue07 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue07 = 0.0;
 }
 TrailingSLDistancePips = ProfileScratchValue07 + 1400.0 ;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue08 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue08 = 0.0;
 }
 TrailingSLStepLimitPips = ProfileScratchValue08 + 5000.0 ;
 TrailingActivationBufferPips = 0.1 ;
 TrailingPartialClosePercent = 0.0 ;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue09 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue09 = 0.0;
 }
 TrailingTPDistancePips = ProfileScratchValue09 + 1600.0 ;
 ProfileScratchValue09 = AdjustTrailTP + 400.0;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue10 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue10 = 0.0;
 }
 TrailingTPStartPips = ProfileScratchValue09 + ProfileScratchValue10 ;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue11 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue11 = 0.0;
 }
 BreakEvenStartPips = ProfileScratchValue11 + 500.0 ;
 ProfileScratchValue11 = AdjustBreakEven + 100.0;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue12 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue12 = 0.0;
 }
 BreakEvenExtraPips = ProfileScratchValue11 + ProfileScratchValue12 ;
 HighLowTrailingTimeframeMinutes = 60 ;
 SwingQualificationMinimumShift = 50 ;
 HighLowLeftBars = 1 ;
 HighLowRightBars = 5 ;
 HighLowLookbackBars = 700 ;
 HighLowTrailingOffsetPips = 22.0 ;
 MaxOpenTradesPerSide = 99 ;
 if ( !(RemoveCommentSuffix) )
 {
   CurrentStrategyComment=ST1_Comment + "_XAUUSD_2";
 }
 StrategyMagicNumber=ST1_MagicNumber + 5;
 StrategyDrawdownReferenceUsd = ConvertUsdToAccountCurrency(30.0) ;
 if ( !(UseVariableValues) )   return;
 LotSizeReferenceBalance = 2000.0 ;
 StrategyDrawdownReferenceUsd = ConvertUsdToAccountCurrency(30.0) ;
 }
//LoadStrategy3Profile <<==--------   --------
 void LoadStrategy4Profile()
 {
 double     ProfileScratchValue01;
 double     ProfileScratchValue02;
 double     ProfileScratchValue03;
 double     ProfileScratchValue04;
 double     ProfileScratchValue05;
 double     ProfileScratchValue06;
 double     ProfileScratchValue07;
 double     ProfileScratchValue08;
 double     ProfileScratchValue09;
 double     ProfileScratchValue10;
 double     ProfileScratchValue11;
 double     ProfileScratchValue12;
 double     ProfileScratchValue13;

 SignalTimeframeMinutes = 1440 ;
 EntryTimingTimeframeMinutes = 60 ;
 SwingLeftBars = 7 ;
 SwingRightBars = 2 ;
 EntryLookbackBars = 20 ;
 MinEntryDistancePips = 250.0 ;
 MinimumEntryDistancePercent = 0.0 ;
 ProfileScratchValue01 = AdjustEntry + -130.0;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue02 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue02 = 0.0;
 }
 BuyEntryOffsetPips = ProfileScratchValue01 + ProfileScratchValue02 ;
 ProfileScratchValue02 = AdjustEntry + -120.0;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue03 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue03 = 0.0;
 }
 SellEntryOffsetPips = ProfileScratchValue02 + ProfileScratchValue03 ;
 MaxPendingOrders = 1 ;
 DuplicatePendingTolerancePips = 980.0 ;
 PendingExpirationHours = 432 ;
 ExitTimingMode = 1 ;
 if ( !(UseHL_TrailingSL) )
 {
   ProfileScratchValue03 = AdjustSL + 600.0;
   if ( Randomization>0.0 )
   {
     ProfileScratchValue04 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
   }
   else
   {
     ProfileScratchValue04 = 0.0;
   }
   StopLossPips = ProfileScratchValue03 + ProfileScratchValue04 ;
 }
 else
 {
   ProfileScratchValue04 = AdjustSL + 700.0;
   if ( Randomization>0.0 )
   {
     ProfileScratchValue05 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
   }
   else
   {
     ProfileScratchValue05 = 0.0;
   }
   StopLossPips = ProfileScratchValue04 + ProfileScratchValue05 ;
 }
 ProfileScratchValue05 = AdjustTP + 3300.0;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue06 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue06 = 0.0;
 }
 TakeProfitPips = ProfileScratchValue05 + ProfileScratchValue06 ;
 ProfileScratchValue06 = AdjustTrailSL + 500.0;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue07 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue07 = 0.0;
 }
 TrailingSLStartPips = ProfileScratchValue06 + ProfileScratchValue07 ;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue08 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue08 = 0.0;
 }
 TrailingSLDistancePips = ProfileScratchValue08 + 400.0 ;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue09 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue09 = 0.0;
 }
 TrailingSLStepLimitPips = ProfileScratchValue09 + 5000.0 ;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue10 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue10 = 0.0;
 }
 TrailingTPDistancePips = ProfileScratchValue10 + 1000.0 ;
 ProfileScratchValue10 = AdjustTrailTP + 2000.0;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue11 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue11 = 0.0;
 }
 TrailingTPStartPips = ProfileScratchValue10 + ProfileScratchValue11 ;
 TrailingActivationBufferPips = 0.1 ;
 TrailingPartialClosePercent = 0.0 ;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue12 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue12 = 0.0;
 }
 BreakEvenStartPips = ProfileScratchValue12 + 400.0 ;
 ProfileScratchValue12 = AdjustBreakEven;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue13 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue13 = 0.0;
 }
 BreakEvenExtraPips = ProfileScratchValue12 + ProfileScratchValue13 ;
 HighLowTrailingTimeframeMinutes = 60 ;
 SwingQualificationMinimumShift = 50 ;
 HighLowLeftBars = 7 ;
 HighLowRightBars = 4 ;
 HighLowLookbackBars = 100 ;
 HighLowTrailingOffsetPips = 0.0 ;
 MaxOpenTradesPerSide = 99 ;
 if ( !(RemoveCommentSuffix) )
 {
   CurrentStrategyComment=ST1_Comment + "_XAUUSD_3";
 }
 StrategyMagicNumber=ST1_MagicNumber + 8;
 StrategyDrawdownReferenceUsd = ConvertUsdToAccountCurrency(32.0) ;
 if ( !(UseVariableValues) )   return;
 LotSizeReferenceBalance = 2000.0 ;
 StrategyDrawdownReferenceUsd = ConvertUsdToAccountCurrency(35.0) ;
 }
//LoadStrategy4Profile <<==--------   --------
 void LoadStrategy5Profile()
 {
 double     ProfileScratchValue01;
 double     ProfileScratchValue02;
 double     ProfileScratchValue03;
 double     ProfileScratchValue04;
 double     ProfileScratchValue05;
 double     ProfileScratchValue06;
 double     ProfileScratchValue07;
 double     ProfileScratchValue08;
 double     ProfileScratchValue09;
 double     ProfileScratchValue10;
 double     ProfileScratchValue11;
 double     ProfileScratchValue12;

 SignalTimeframeMinutes = 60 ;
 EntryTimingTimeframeMinutes = 5 ;
 SwingLeftBars = 26 ;
 SwingRightBars = 24 ;
 EntryLookbackBars = 140 ;
 MinEntryDistancePips = 120.0 ;
 MinimumEntryDistancePercent = 0.0 ;
 ProfileScratchValue01 = AdjustEntry + -115.0;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue02 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue02 = 0.0;
 }
 BuyEntryOffsetPips = ProfileScratchValue01 + ProfileScratchValue02 ;
 ProfileScratchValue02 = AdjustEntry + -145.0;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue03 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue03 = 0.0;
 }
 SellEntryOffsetPips = ProfileScratchValue02 + ProfileScratchValue03 ;
 MaxPendingOrders = 5 ;
 DuplicatePendingTolerancePips = 55.0 ;
 PendingExpirationHours = 20 ;
 ExitTimingMode = 1 ;
 ProfileScratchValue03 = AdjustSL + 10100.0;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue04 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue04 = 0.0;
 }
 StopLossPips = ProfileScratchValue03 + ProfileScratchValue04 ;
 ProfileScratchValue04 = AdjustTP + 800.0;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue05 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue05 = 0.0;
 }
 TakeProfitPips = ProfileScratchValue04 + ProfileScratchValue05 ;
 ProfileScratchValue05 = AdjustTrailSL + 500.0;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue06 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue06 = 0.0;
 }
 TrailingSLStartPips = ProfileScratchValue05 + ProfileScratchValue06 ;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue07 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue07 = 0.0;
 }
 TrailingSLDistancePips = ProfileScratchValue07 + 1200.0 ;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue08 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue08 = 0.0;
 }
 TrailingSLStepLimitPips = ProfileScratchValue08 + 5000.0 ;
 TrailingActivationBufferPips = 0.1 ;
 TrailingPartialClosePercent = 0.0 ;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue09 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue09 = 0.0;
 }
 TrailingTPDistancePips = ProfileScratchValue09 + 1950.0 ;
 ProfileScratchValue09 = AdjustTrailTP + 350.0;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue10 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue10 = 0.0;
 }
 TrailingTPStartPips = ProfileScratchValue09 + ProfileScratchValue10 ;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue11 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue11 = 0.0;
 }
 BreakEvenStartPips = ProfileScratchValue11 + 330.0 ;
 ProfileScratchValue11 = AdjustBreakEven + 80.0;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue12 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue12 = 0.0;
 }
 BreakEvenExtraPips = ProfileScratchValue11 + ProfileScratchValue12 ;
 HighLowTrailingTimeframeMinutes = 60 ;
 SwingQualificationMinimumShift = 50 ;
 HighLowLeftBars = 0 ;
 HighLowRightBars = 0 ;
 HighLowLookbackBars = 100 ;
 HighLowTrailingOffsetPips = 0.0 ;
 MaxOpenTradesPerSide = 5 ;
 if ( !(RemoveCommentSuffix) )
 {
   CurrentStrategyComment=ST1_Comment + "_XAUUSD_6";
 }
 StrategyMagicNumber=ST1_MagicNumber + 9;
 StrategyDrawdownReferenceUsd = ConvertUsdToAccountCurrency(348.0) ;
 if ( !(UseVariableValues) )   return;
 LotSizeReferenceBalance = 2400.0 ;
 StrategyDrawdownReferenceUsd = ConvertUsdToAccountCurrency(140.0) ;
 }
//LoadStrategy5Profile <<==--------   --------
 void LoadStrategy6Profile()
 {
 double     ProfileScratchValue01;
 double     ProfileScratchValue02;
 double     ProfileScratchValue03;
 double     ProfileScratchValue04;
 double     ProfileScratchValue05;
 double     ProfileScratchValue06;
 double     ProfileScratchValue07;
 double     ProfileScratchValue08;
 double     ProfileScratchValue09;
 double     ProfileScratchValue10;
 double     ProfileScratchValue11;
 double     ProfileScratchValue12;

 SignalTimeframeMinutes = 60 ;
 EntryTimingTimeframeMinutes = 15 ;
 SwingLeftBars = 30 ;
 SwingRightBars = 19 ;
 EntryLookbackBars = 110 ;
 MinEntryDistancePips = 160.0 ;
 MinimumEntryDistancePercent = 0.0 ;
 ProfileScratchValue01 = AdjustEntry + -120.0;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue02 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue02 = 0.0;
 }
 BuyEntryOffsetPips = ProfileScratchValue01 + ProfileScratchValue02 ;
 ProfileScratchValue02 = AdjustEntry + -110.0;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue03 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue03 = 0.0;
 }
 SellEntryOffsetPips = ProfileScratchValue02 + ProfileScratchValue03 ;
 MaxPendingOrders = 3 ;
 DuplicatePendingTolerancePips = 55.0 ;
 PendingExpirationHours = 30 ;
 ExitTimingMode = 1 ;
 ProfileScratchValue03 = AdjustSL + 5300.0;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue04 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue04 = 0.0;
 }
 StopLossPips = ProfileScratchValue03 + ProfileScratchValue04 ;
 ProfileScratchValue04 = AdjustTP + 900.0;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue05 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue05 = 0.0;
 }
 TakeProfitPips = ProfileScratchValue04 + ProfileScratchValue05 ;
 ProfileScratchValue05 = AdjustTrailSL + 495.0;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue06 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue06 = 0.0;
 }
 TrailingSLStartPips = ProfileScratchValue05 + ProfileScratchValue06 ;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue07 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue07 = 0.0;
 }
 TrailingSLDistancePips = ProfileScratchValue07 + 400.0 ;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue08 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue08 = 0.0;
 }
 TrailingSLStepLimitPips = ProfileScratchValue08 + 5000.0 ;
 TrailingActivationBufferPips = 0.1 ;
 TrailingPartialClosePercent = 0.0 ;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue09 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue09 = 0.0;
 }
 TrailingTPDistancePips = ProfileScratchValue09 + 1900.0 ;
 ProfileScratchValue09 = AdjustTrailTP + 250.0;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue10 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue10 = 0.0;
 }
 TrailingTPStartPips = ProfileScratchValue09 + ProfileScratchValue10 ;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue11 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue11 = 0.0;
 }
 BreakEvenStartPips = ProfileScratchValue11 + 260.0 ;
 ProfileScratchValue11 = AdjustBreakEven + 80.0;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue12 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue12 = 0.0;
 }
 BreakEvenExtraPips = ProfileScratchValue11 + ProfileScratchValue12 ;
 HighLowTrailingTimeframeMinutes = 60 ;
 SwingQualificationMinimumShift = 50 ;
 HighLowLeftBars = 0 ;
 HighLowRightBars = 0 ;
 HighLowLookbackBars = 100 ;
 HighLowTrailingOffsetPips = 0.0 ;
 MaxOpenTradesPerSide = 99 ;
 if ( !(RemoveCommentSuffix) )
 {
   CurrentStrategyComment=ST1_Comment + "_XAUUSD_5";
 }
 StrategyMagicNumber=ST1_MagicNumber + 12;
 StrategyDrawdownReferenceUsd = ConvertUsdToAccountCurrency(281.0) ;
 if ( !(UseVariableValues) )   return;
 LotSizeReferenceBalance = 2600.0 ;
 StrategyDrawdownReferenceUsd = ConvertUsdToAccountCurrency(110.0) ;
 }
//LoadStrategy6Profile <<==--------   --------
 void LoadStrategy7Profile()
 {
 double     ProfileScratchValue01;
 double     ProfileScratchValue02;
 double     ProfileScratchValue03;
 double     ProfileScratchValue04;
 double     ProfileScratchValue05;
 double     ProfileScratchValue06;
 double     ProfileScratchValue07;
 double     ProfileScratchValue08;
 double     ProfileScratchValue09;
 double     ProfileScratchValue10;
 double     ProfileScratchValue11;
 double     ProfileScratchValue12;

 SignalTimeframeMinutes = 60 ;
 EntryTimingTimeframeMinutes = 15 ;
 SwingLeftBars = 7 ;
 SwingRightBars = 5 ;
 EntryLookbackBars = 200 ;
 MinEntryDistancePips = 40.0 ;
 MinimumEntryDistancePercent = 0.0 ;
 ProfileScratchValue01 = AdjustEntry + -150.0;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue02 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue02 = 0.0;
 }
 BuyEntryOffsetPips = ProfileScratchValue01 + ProfileScratchValue02 ;
 ProfileScratchValue02 = AdjustEntry + -145.0;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue03 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue03 = 0.0;
 }
 SellEntryOffsetPips = ProfileScratchValue02 + ProfileScratchValue03 ;
 MaxPendingOrders = 3 ;
 DuplicatePendingTolerancePips = 5.0 ;
 PendingExpirationHours = 15 ;
 ExitTimingMode = 1 ;
 ProfileScratchValue03 = AdjustSL + 3900.0;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue04 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue04 = 0.0;
 }
 StopLossPips = ProfileScratchValue03 + ProfileScratchValue04 ;
 ProfileScratchValue04 = AdjustTP + 1350.0;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue05 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue05 = 0.0;
 }
 TakeProfitPips = ProfileScratchValue04 + ProfileScratchValue05 ;
 ProfileScratchValue05 = AdjustTrailSL + 445.0;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue06 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue06 = 0.0;
 }
 TrailingSLStartPips = ProfileScratchValue05 + ProfileScratchValue06 ;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue07 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue07 = 0.0;
 }
 TrailingSLDistancePips = ProfileScratchValue07 + 355.0 ;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue08 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue08 = 0.0;
 }
 TrailingSLStepLimitPips = ProfileScratchValue08 + 5000.0 ;
 TrailingActivationBufferPips = 0.1 ;
 TrailingPartialClosePercent = 0.0 ;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue09 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue09 = 0.0;
 }
 TrailingTPDistancePips = ProfileScratchValue09 + 1850.0 ;
 ProfileScratchValue09 = AdjustTrailTP + 250.0;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue10 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue10 = 0.0;
 }
 TrailingTPStartPips = ProfileScratchValue09 + ProfileScratchValue10 ;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue11 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue11 = 0.0;
 }
 BreakEvenStartPips = ProfileScratchValue11 + 160.0 ;
 ProfileScratchValue11 = AdjustBreakEven + 50.0;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue12 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue12 = 0.0;
 }
 BreakEvenExtraPips = ProfileScratchValue11 + ProfileScratchValue12 ;
 HighLowTrailingTimeframeMinutes = 60 ;
 SwingQualificationMinimumShift = 50 ;
 HighLowLeftBars = 1 ;
 HighLowRightBars = 9 ;
 HighLowLookbackBars = 1500 ;
 HighLowTrailingOffsetPips = 46.0 ;
 MaxOpenTradesPerSide = 99 ;
 if ( !(RemoveCommentSuffix) )
 {
   CurrentStrategyComment=ST1_Comment + "_XAUUSD_9";
 }
 StrategyMagicNumber=ST1_MagicNumber + 13;
 StrategyDrawdownReferenceUsd = ConvertUsdToAccountCurrency(968.0) ;
 if ( !(UseVariableValues) )   return;
 LotSizeReferenceBalance = 1900.0 ;
 StrategyDrawdownReferenceUsd = ConvertUsdToAccountCurrency(700.0) ;
 }
//LoadStrategy7Profile <<==--------   --------
 void LoadStrategy8Profile()
 {
 double     ProfileScratchValue01;
 double     ProfileScratchValue02;
 double     ProfileScratchValue03;
 double     ProfileScratchValue04;
 double     ProfileScratchValue05;
 double     ProfileScratchValue06;
 double     ProfileScratchValue07;
 double     ProfileScratchValue08;
 double     ProfileScratchValue09;
 double     ProfileScratchValue10;
 double     ProfileScratchValue11;
 double     ProfileScratchValue12;

 SignalTimeframeMinutes = 60 ;
 EntryTimingTimeframeMinutes = 15 ;
 SwingLeftBars = 25 ;
 SwingRightBars = 23 ;
 EntryLookbackBars = 145 ;
 MinEntryDistancePips = 10.0 ;
 MinimumEntryDistancePercent = 0.0 ;
 ProfileScratchValue01 = AdjustEntry + -60.0;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue02 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue02 = 0.0;
 }
 BuyEntryOffsetPips = ProfileScratchValue01 + ProfileScratchValue02 ;
 ProfileScratchValue02 = AdjustEntry + -145.0;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue03 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue03 = 0.0;
 }
 SellEntryOffsetPips = ProfileScratchValue02 + ProfileScratchValue03 ;
 MaxPendingOrders = 5 ;
 DuplicatePendingTolerancePips = 90.0 ;
 PendingExpirationHours = 60 ;
 ExitTimingMode = 1 ;
 ProfileScratchValue03 = AdjustSL + 2250.0;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue04 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue04 = 0.0;
 }
 StopLossPips = ProfileScratchValue03 + ProfileScratchValue04 ;
 ProfileScratchValue04 = AdjustTP + 1450.0;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue05 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue05 = 0.0;
 }
 TakeProfitPips = ProfileScratchValue04 + ProfileScratchValue05 ;
 ProfileScratchValue05 = AdjustTrailSL + 450.0;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue06 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue06 = 0.0;
 }
 TrailingSLStartPips = ProfileScratchValue05 + ProfileScratchValue06 ;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue07 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue07 = 0.0;
 }
 TrailingSLDistancePips = ProfileScratchValue07 + 900.0 ;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue08 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue08 = 0.0;
 }
 TrailingSLStepLimitPips = ProfileScratchValue08 + 5000.0 ;
 TrailingActivationBufferPips = 0.1 ;
 TrailingPartialClosePercent = 0.0 ;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue09 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue09 = 0.0;
 }
 TrailingTPDistancePips = ProfileScratchValue09 + 2800.0 ;
 ProfileScratchValue09 = AdjustTrailTP + 350.0;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue10 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue10 = 0.0;
 }
 TrailingTPStartPips = ProfileScratchValue09 + ProfileScratchValue10 ;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue11 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue11 = 0.0;
 }
 BreakEvenStartPips = ProfileScratchValue11 + 340.0 ;
 ProfileScratchValue11 = AdjustBreakEven + 30.0;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue12 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue12 = 0.0;
 }
 BreakEvenExtraPips = ProfileScratchValue11 + ProfileScratchValue12 ;
 HighLowTrailingTimeframeMinutes = 60 ;
 SwingQualificationMinimumShift = 50 ;
 HighLowLeftBars = 12 ;
 HighLowRightBars = 17 ;
 HighLowLookbackBars = 1000 ;
 HighLowTrailingOffsetPips = 45.0 ;
 MaxOpenTradesPerSide = 5 ;
 if ( !(RemoveCommentSuffix) )
 {
   CurrentStrategyComment=ST1_Comment + "_XAUUSD_7";
 }
 StrategyMagicNumber=ST1_MagicNumber + 14;
 StrategyDrawdownReferenceUsd = ConvertUsdToAccountCurrency(149.0) ;
 if ( !(UseVariableValues) )   return;
 LotSizeReferenceBalance = 2600.0 ;
 StrategyDrawdownReferenceUsd = ConvertUsdToAccountCurrency(90.0) ;
 }
//LoadStrategy8Profile <<==--------   --------
 void LoadStrategy9Profile()
 {
 double     ProfileScratchValue01;
 double     ProfileScratchValue02;
 double     ProfileScratchValue03;
 double     ProfileScratchValue04;
 double     ProfileScratchValue05;
 double     ProfileScratchValue06;
 double     ProfileScratchValue07;
 double     ProfileScratchValue08;
 double     ProfileScratchValue09;
 double     ProfileScratchValue10;
 double     ProfileScratchValue11;
 double     ProfileScratchValue12;

 SignalTimeframeMinutes = 60 ;
 EntryTimingTimeframeMinutes = 15 ;
 SwingLeftBars = 26 ;
 SwingRightBars = 20 ;
 EntryLookbackBars = 235 ;
 MinEntryDistancePips = 80.0 ;
 MinimumEntryDistancePercent = 0.0 ;
 ProfileScratchValue01 = AdjustEntry + -140.0;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue02 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue02 = 0.0;
 }
 BuyEntryOffsetPips = ProfileScratchValue01 + ProfileScratchValue02 ;
 ProfileScratchValue02 = AdjustEntry + -170.0;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue03 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue03 = 0.0;
 }
 SellEntryOffsetPips = ProfileScratchValue02 + ProfileScratchValue03 ;
 MaxPendingOrders = 5 ;
 DuplicatePendingTolerancePips = 5.0 ;
 PendingExpirationHours = 55 ;
 ExitTimingMode = 1 ;
 ProfileScratchValue03 = AdjustSL + 1900.0;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue04 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue04 = 0.0;
 }
 StopLossPips = ProfileScratchValue03 + ProfileScratchValue04 ;
 ProfileScratchValue04 = AdjustTP + 1200.0;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue05 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue05 = 0.0;
 }
 TakeProfitPips = ProfileScratchValue04 + ProfileScratchValue05 ;
 ProfileScratchValue05 = AdjustTrailSL + 1250.0;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue06 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue06 = 0.0;
 }
 TrailingSLStartPips = ProfileScratchValue05 + ProfileScratchValue06 ;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue07 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue07 = 0.0;
 }
 TrailingSLDistancePips = ProfileScratchValue07 + 650.0 ;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue08 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue08 = 0.0;
 }
 TrailingSLStepLimitPips = ProfileScratchValue08 + 5000.0 ;
 TrailingActivationBufferPips = 0.1 ;
 TrailingPartialClosePercent = 0.0 ;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue09 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue09 = 0.0;
 }
 TrailingTPDistancePips = ProfileScratchValue09 + 1950.0 ;
 ProfileScratchValue09 = AdjustTrailTP + 250.0;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue10 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue10 = 0.0;
 }
 TrailingTPStartPips = ProfileScratchValue09 + ProfileScratchValue10 ;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue11 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue11 = 0.0;
 }
 BreakEvenStartPips = ProfileScratchValue11 + 270.0 ;
 ProfileScratchValue11 = AdjustBreakEven;
 if ( Randomization>0.0 )
 {
   ProfileScratchValue12 = Randomization * 2.0 * MathRand() / 32768.0 + (0.0 - Randomization);
 }
 else
 {
   ProfileScratchValue12 = 0.0;
 }
 BreakEvenExtraPips = ProfileScratchValue11 + ProfileScratchValue12 ;
 HighLowTrailingTimeframeMinutes = 60 ;
 SwingQualificationMinimumShift = 50 ;
 HighLowLeftBars = 15 ;
 HighLowRightBars = 3 ;
 HighLowLookbackBars = 1200 ;
 HighLowTrailingOffsetPips = 16.0 ;
 MaxOpenTradesPerSide = 20 ;
 if ( !(RemoveCommentSuffix) )
 {
   CurrentStrategyComment=ST1_Comment + "_XAUUSD_8";
 }
 StrategyMagicNumber=ST1_MagicNumber + 15;
 StrategyDrawdownReferenceUsd = ConvertUsdToAccountCurrency(276.0) ;
 if ( !(UseVariableValues) )   return;
 LotSizeReferenceBalance = 2800.0 ;
 StrategyDrawdownReferenceUsd = ConvertUsdToAccountCurrency(130.0) ;
 }
//LoadStrategy9Profile <<==--------   --------
 void EnforcePropFirmDailyDrawdown()
 {
  double    TodayClosedProfit;
  int       HistoryScanIndex;
  double    ClosedTradeNetProfit;
  double    CurrentFloatingProfit;
  double    CombinedDailyProfit;
//----------------------------------------------------------------------
 double     CurrentEquity;
 long       OrderCloseTime;
 int        OpenOrderScanIndex;
 long        DrawdownMagicCheck01;
 long        DrawdownMagicCheck02;
 long        DrawdownMagicCheck03;
 long        DrawdownMagicCheck04;
 long        DrawdownMagicCheck05;
 long        DrawdownMagicCheck06;
 long        DrawdownMagicCheck07;
 long        DrawdownMagicCheck08;
 long        DrawdownMagicCheck09;
 long        DrawdownMagicCheck10;
 long        DrawdownMagicCheck11;
 long        DrawdownMagicCheck12;
 long        DrawdownMagicCheck13;
 long        DrawdownMagicCheck14;
 long        DrawdownMagicCheck15;
 long        DrawdownMagicCheck16;

 CurrentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
 if ( CurrentEquity==AccountInfoDouble(ACCOUNT_BALANCE) )   return;
 TodayClosedProfit = 0.0 ;
 if ( AccountInfoDouble(ACCOUNT_EQUITY)>DailyDrawdownReference )
 {
   DailyDrawdownReference = AccountInfoDouble(ACCOUNT_EQUITY) ;
 }
 for (HistoryScanIndex = ClosedTradeCount() ; HistoryScanIndex >= 0 ; HistoryScanIndex --)
 {
   if ( SelectTradeRecord(HistoryScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_HISTORY) != true )   continue;
   OrderCloseTime = SelectedTradeCloseTime();
   if ( OrderCloseTime < iTime(CurrentSymbol,NormalizeTimeframe(PERIOD_D1),0) )   continue;
   ClosedTradeNetProfit = SelectedTradeProfit() + SelectedTradeSwap() + SelectedTradeCommission() ;
   TodayClosedProfit = ClosedTradeNetProfit + TodayClosedProfit ;
   
 }
 CurrentFloatingProfit = AccountInfoDouble(ACCOUNT_EQUITY) - AccountInfoDouble(ACCOUNT_BALANCE) ;
 CombinedDailyProfit = CurrentFloatingProfit + TodayClosedProfit ;
 if ( !( -(CombinedDailyProfit)>DailyDrawdownReference * PropFirmMaxDailyDD / 100.0) )   return;
 
 if ( !(DailyDrawdownLockActive) )
 {
   Print("Max Daily Drawdown reached, closing trades and skipping rest of the day"); 
 }
 for (OpenOrderScanIndex = ActiveTradeCount() ; OpenOrderScanIndex >= 0 ; OpenOrderScanIndex=OpenOrderScanIndex - 1)
 {
   if ( SelectTradeRecord(OpenOrderScanIndex,TRADE_SELECT_BY_INDEX,TRADE_POOL_ACTIVE) != true || SelectedTradeSymbol() != CurrentSymbol )   continue;
   DrawdownMagicCheck01 = SelectedTradeMagic();
   DrawdownMagicCheck02=ST1_MagicNumber + 1;
   if ( DrawdownMagicCheck01 != DrawdownMagicCheck02 )
   {
     DrawdownMagicCheck02 = SelectedTradeMagic();
     DrawdownMagicCheck03=ST1_MagicNumber + 2;
     if ( DrawdownMagicCheck02 != DrawdownMagicCheck03 )
     {
       DrawdownMagicCheck03 = SelectedTradeMagic();
       DrawdownMagicCheck04=ST1_MagicNumber + 3;
       if ( DrawdownMagicCheck03 != DrawdownMagicCheck04 )
       {
         DrawdownMagicCheck04 = SelectedTradeMagic();
         DrawdownMagicCheck05=ST1_MagicNumber + 4;
         if ( DrawdownMagicCheck04 != DrawdownMagicCheck05 )
         {
           DrawdownMagicCheck05 = SelectedTradeMagic();
           DrawdownMagicCheck06=ST1_MagicNumber + 5;
           if ( DrawdownMagicCheck05 != DrawdownMagicCheck06 )
           {
             DrawdownMagicCheck06 = SelectedTradeMagic();
             DrawdownMagicCheck07=ST1_MagicNumber + 6;
             if ( DrawdownMagicCheck06 != DrawdownMagicCheck07 )
             {
               DrawdownMagicCheck07 = SelectedTradeMagic();
               DrawdownMagicCheck08=ST1_MagicNumber + 7;
               if ( DrawdownMagicCheck07 != DrawdownMagicCheck08 )
               {
                 DrawdownMagicCheck08 = SelectedTradeMagic();
                 DrawdownMagicCheck09=ST1_MagicNumber + 8;
                 if ( DrawdownMagicCheck08 != DrawdownMagicCheck09 )
                 {
                   DrawdownMagicCheck09 = SelectedTradeMagic();
                   DrawdownMagicCheck10=ST1_MagicNumber + 9;
                   if ( DrawdownMagicCheck09 != DrawdownMagicCheck10 )
                   {
                     DrawdownMagicCheck10 = SelectedTradeMagic();
                     DrawdownMagicCheck11=ST1_MagicNumber + 10;
                     if ( DrawdownMagicCheck10 != DrawdownMagicCheck11 )
                     {
                       DrawdownMagicCheck11 = SelectedTradeMagic();
                       DrawdownMagicCheck12=ST1_MagicNumber + 11;
                       if ( DrawdownMagicCheck11 != DrawdownMagicCheck12 )
                       {
                         DrawdownMagicCheck12 = SelectedTradeMagic();
                         DrawdownMagicCheck13=ST1_MagicNumber + 12;
                         if ( DrawdownMagicCheck12 != DrawdownMagicCheck13 )
                         {
                           DrawdownMagicCheck13 = SelectedTradeMagic();
                           DrawdownMagicCheck14=ST1_MagicNumber + 13;
                           if ( DrawdownMagicCheck13 != DrawdownMagicCheck14 )
                           {
                             DrawdownMagicCheck14 = SelectedTradeMagic();
                             DrawdownMagicCheck15=ST1_MagicNumber + 14;
                             if ( DrawdownMagicCheck14 != DrawdownMagicCheck15 )
                             {
                               DrawdownMagicCheck15 = SelectedTradeMagic();
                               DrawdownMagicCheck16=ST1_MagicNumber + 15;
                             if ( DrawdownMagicCheck15 != DrawdownMagicCheck16 )   continue;
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
     ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(CurrentSymbol,SYMBOL_BID),(int)OrderSlippageSetting,Red); 
   }
   if ( SelectedTradeType() == ORDER_TYPE_SELL )
   {
     ClosePositionByTicket(SelectedTradeTicket(),SelectedTradeVolume(),SymbolInfoDouble(CurrentSymbol,SYMBOL_ASK),(int)OrderSlippageSetting,Red); 
   }
   if ( ( SelectedTradeType() != ORDER_TYPE_BUY_STOP && SelectedTradeType() != ORDER_TYPE_SELL_STOP ) )   continue;
   DeletePendingOrderByTicket(SelectedTradeTicket(),Red); 
   
 }
 DailyDrawdownLockActive = true ;
 DailyDrawdownReference = 0.0 ;
 }
//EnforcePropFirmDailyDrawdown <<==--------   --------
 int FetchUtcOffsetHours()
 {
  string    ResponseBody;
  int       TimestampMarkerIndex;
  string    TimestampText;
  long      UtcTimestamp;
  int       UtcOffsetHours;
  char      RequestBodyBytes[];
  char      ResponseBytes[];
//----------------------------------------------------------------------
 string     ResponseHeaders;
 string     ResponseText;

 ResetLastError();
 if ( WebRequest("GET","https://www.worldtimeserver.com/time-zones/utc/",NULL,NULL,10000,RequestBodyBytes,0,ResponseBytes,ResponseHeaders) == -1 )
 {
   Print("Error when reading GMT URL. Error code  =",GetLastError());
   MessageBox("Add the address \'https://www.worldtimeserver.com/\' in the list of allowed URLs on tab \'Expert Advisors\'","Error",64);
   ResponseText = "999";
 }
 else
 {
   // WHOLE_ARRAY=0 duoc dung de lay "toan bo mang" khi
   // count=0; nhung MQL5 dinh nghia lai WHOLE_ARRAY=-1, con count=0 trong MQL5
   // co nghia den la "lay 0 ky tu" -> luon ra chuoi rong du HTTP tra ve 200 va
   // co du du lieu (day chinh la nguyen nhan that su cua loi "GMT time = 0").
   ResponseText = CharArrayToString(ResponseBytes,0,-1,0);
 }
 ResponseBody = ResponseText ;
 if ( ResponseBody == "999" )
 {
   return(999);
 }
 TimestampMarkerIndex = StringFind(ResponseBody,"\"serverTimeStamp\" value=",0) ;
 TimestampText = StringSubstr(ResponseBody,TimestampMarkerIndex + 25,10) ;
 UtcTimestamp = (long)ulong(TimestampText) ;
 Print("GMT time = ",UtcTimestamp); 
 Print("Broker time = ",TimeCurrent()); 
 UtcOffsetHours=DateTimeHour(TimeCurrent()) - DateTimeHour(UtcTimestamp);
 if ( UtcOffsetHours <  -12 )
 {
   UtcOffsetHours +=24;
 }
 if ( UtcOffsetHours >  12 )
 {
   UtcOffsetHours -=24;
 }
 Print("GMT_Offset detected: " + string(UtcOffsetHours)); 
 if ( ( UtcOffsetHours < -12 || UtcOffsetHours >  12 ) )
 {
   Print("Error in detecting GMT offset with URL"); 
   return(999); 
 }
 if ( UtcTimestamp <  TimeCurrent() - SECONDS_PER_DAY )
 {
   Print("Error in detecting GMT time with URL"); 
   return(999); 
 }
 return(UtcOffsetHours); 
 }
//FetchUtcOffsetHours <<==--------   --------
 bool IsAmericanDaylightSavingTime()
 {
  int       Year;
  datetime  DstStart;
  datetime  DstEnd;
  int       StartDayOffset;
  int       EndDayOffset;
//----------------------------------------------------------------------

 Year = DateTimeYear(TimeCurrent()) ;
 DstStart = 0 ;
 DstEnd = 0 ;
 if ( Year <  1987 )
 {
   Print("AmericanDST(): Invalid year."); 
   return(false); 
 }
 StartDayOffset = 0 ;
 EndDayOffset = 0 ;
 if ( Year >= 1987 && Year <= 2006 )
 {
   StartDayOffset = (int)(MathMod(Year * 6 + 2 - Year / 4,7.0) + 1.0) ;
   EndDayOffset = (int)(31.0 - (MathMod(Year * 5 / 4 + 1,7.0))) ;
   DstStart=StringToTime(((string)Year+".04.01")) + (StartDayOffset - 1) * SECONDS_PER_DAY + DST_TRANSITION_TIME_SECONDS;
   DstEnd=StringToTime(((string)Year+".10.01")) + (EndDayOffset - 1) * SECONDS_PER_DAY + DST_TRANSITION_TIME_SECONDS;
 }
 else
 {
   if ( Year >= 2007 )
   {
     StartDayOffset = (int)(14.0 - (MathMod(Year * 5 / 4 + 1,7.0))) ;
     EndDayOffset = (int)(7.0 - (MathMod(Year * 5 / 4 + 1,7.0))) ;
     DstStart=StringToTime(((string)Year+".03.01")) + (StartDayOffset - 1) * SECONDS_PER_DAY + DST_TRANSITION_TIME_SECONDS;
     DstEnd=StringToTime(((string)Year+".11.01")) + (EndDayOffset - 1) * SECONDS_PER_DAY + DST_TRANSITION_TIME_SECONDS;
   }
 }
 if ( DateTimeDayOfYear(TimeCurrent()) >  DateTimeDayOfYear(DstStart) && DateTimeDayOfYear(TimeCurrent()) <  DateTimeDayOfYear(DstEnd) )
 {
   return(true); 
 }
 return(false); 
 }
//<<==IsAmericanDaylightSavingTime <<==

