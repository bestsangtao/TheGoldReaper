//+------------------------------------------------------------------+
//| MQL4Compat.mqh                                                    |
//|                                                                    |
//| Lop tuong thich MQL4 -> MQL5 danh rieng cho The Gold Reaper.       |
//| Muc dich: cho phep GIU NGUYEN 100% logic goc viet theo phong cach  |
//| MQL4 (OrderSend/OrderModify/OrderClose/OrderDelete/OrderSelect,    |
//| OrdersTotal/HistoryTotal, MarketInfo, AccountBalance/Equity,       |
//| Time*()/Year()/Month()/Day()/Hour()/Minute()/Seconds()/DayOfWeek(),|
//| iMA()/iFractals() kieu tra ve gia tri truc tiep...) trong khi thuc |
//| thi ben duoi hoan toan bang API MQL5 (Position/Order/Deal, request |
//| giao dich MqlTradeRequest/OrderSend, SymbolInfo*, AccountInfo*,    |
//| TimeToStruct...).                                                  |
//|                                                                    |
//| QUAN TRONG:                                                        |
//|  - EA nay mo dong thoi nhieu lenh/vi the tren cung 1 symbol voi    |
//|    nhieu magic number khac nhau (multi-strategy). Vi vay tai khoan |
//|    MT5 chay EA nay BAT BUOC phai o che do HEDGING. O che do        |
//|    Netting, moi lenh cung symbol se bi gop thanh 1 vi the duy nhat |
//|    va lam sai toan bo logic quan ly lenh cua EA.                   |
//|  - Cac ham lay lich su lenh (pool=MODE_HISTORY) duoc dung lai tu   |
//|    HistoryDealsTotal(): moi cap deal (DEAL_ENTRY_IN + DEAL_ENTRY_  |
//|    OUT/OUT_BY cung POSITION_ID) duoc ghep thanh 1 "lenh lich su"   |
//|    kieu MQL4. Neu 1 vi the bi dong nhieu lan (dong 1 phan), cac    |
//|    deal dong se duoc GOM lai thanh 1 ban ghi duy nhat (tong loi/lo)|
//|    -> khac biet nho so voi MQL4 (MQL4 tao 1 ticket rieng cho moi   |
//|    lan dong 1 phan). EA nay khong dung dong 1 phan lenh nen anh    |
//|    huong la khong dang ke.                                        |
//+------------------------------------------------------------------+
#ifndef __MQL4COMPAT_MQH__
#define __MQL4COMPAT_MQH__

//====================================================================
// Hang so kieu MQL4
//====================================================================
#define OP_BUY        0
#define OP_SELL       1
#define OP_BUYLIMIT   2
#define OP_SELLLIMIT  3
#define OP_BUYSTOP    4
#define OP_SELLSTOP   5

#define SELECT_BY_POS    0
#define SELECT_BY_TICKET 1
#define MODE_TRADES      0
#define MODE_HISTORY     1

// Ma so MarketInfo() kieu MQL4 (chi gom cac ma EA nay su dung)
#define MODE_BID              9
#define MODE_ASK              10
#define MODE_POINT            11
#define MODE_DIGITS           12
#define MODE_STOPLEVEL        14
#define MODE_TICKVALUE        16
#define MODE_TRADEALLOWED     22
#define MODE_MINLOT           23
#define MODE_LOTSTEP          24
#define MODE_MAXLOT           25
#define MODE_FREEZELEVEL      33

//====================================================================
// Bien trang thai noi bo
//====================================================================
long g_mt4_lastTicket = -1;
int  g_mt4_lastError  = 0;

//====================================================================
// Quy doi timeframe kieu "so phut" (MQL4 cu) -> ENUM_TIMEFRAMES MQL5.
// Neu tham so da la hang PERIOD_xxx cua MQL5 (gia tri >= 16385) thi
// tra ve nguyen (pass-through) vi da dung.
//====================================================================
ENUM_TIMEFRAMES MT4Period(int minutes)
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

//====================================================================
// MarketInfo() kieu MQL4
//====================================================================
double MarketInfo(string symbol,int mode)
{
   switch(mode)
   {
      case MODE_BID:          return SymbolInfoDouble(symbol,SYMBOL_BID);
      case MODE_ASK:           return SymbolInfoDouble(symbol,SYMBOL_ASK);
      case MODE_POINT:         return SymbolInfoDouble(symbol,SYMBOL_POINT);
      case MODE_DIGITS:        return (double)SymbolInfoInteger(symbol,SYMBOL_DIGITS);
      case MODE_STOPLEVEL:     return (double)SymbolInfoInteger(symbol,SYMBOL_TRADE_STOPS_LEVEL);
      case MODE_TICKVALUE:     return SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_VALUE);
      case MODE_TRADEALLOWED:  return (SymbolInfoInteger(symbol,SYMBOL_TRADE_MODE)==SYMBOL_TRADE_MODE_FULL)?1.0:0.0;
      case MODE_MINLOT:        return SymbolInfoDouble(symbol,SYMBOL_VOLUME_MIN);
      case MODE_LOTSTEP:       return SymbolInfoDouble(symbol,SYMBOL_VOLUME_STEP);
      case MODE_MAXLOT:        return SymbolInfoDouble(symbol,SYMBOL_VOLUME_MAX);
      case MODE_FREEZELEVEL:   return (double)SymbolInfoInteger(symbol,SYMBOL_TRADE_FREEZE_LEVEL);
   }
   return 0.0;
}

//====================================================================
// Account*() kieu MQL4
//====================================================================
double AccountBalance()  { return AccountInfoDouble(ACCOUNT_BALANCE); }
double AccountEquity()   { return AccountInfoDouble(ACCOUNT_EQUITY);  }
string AccountCurrency() { return AccountInfoString(ACCOUNT_CURRENCY);}

double AccountFreeMarginCheck(string symbol,int cmd,double volume)
{
   double margin=0.0;
   ENUM_ORDER_TYPE type=(cmd==OP_BUY)?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
   double price=(cmd==OP_BUY)?SymbolInfoDouble(symbol,SYMBOL_ASK):SymbolInfoDouble(symbol,SYMBOL_BID);
   if(!OrderCalcMargin(type,symbol,volume,price,margin))
      return AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   return AccountInfoDouble(ACCOUNT_MARGIN_FREE)-margin;
}

//====================================================================
// RefreshRates() - khong con can thiet trong MQL5 (gia luon la moi),
// giu lai de code cu bien dich duoc, luon tra ve true.
//====================================================================
bool RefreshRates() { return true; }

//====================================================================
// Cac ham thoi gian kieu MQL4 (khong con trong MQL5)
//====================================================================
int TimeYear(datetime t)      { MqlDateTime s; TimeToStruct(t,s); return s.year; }
int TimeMonth(datetime t)     { MqlDateTime s; TimeToStruct(t,s); return s.mon;  }
int TimeDay(datetime t)       { MqlDateTime s; TimeToStruct(t,s); return s.day;  }
int TimeHour(datetime t)      { MqlDateTime s; TimeToStruct(t,s); return s.hour; }
int TimeMinute(datetime t)    { MqlDateTime s; TimeToStruct(t,s); return s.min;  }
int TimeSeconds(datetime t)   { MqlDateTime s; TimeToStruct(t,s); return s.sec;  }
int TimeDayOfWeek(datetime t) { MqlDateTime s; TimeToStruct(t,s); return s.day_of_week; }
int TimeDayOfYear(datetime t) { MqlDateTime s; TimeToStruct(t,s); return s.day_of_year;  }

// Ban khong doi so (ngam dinh TimeCurrent()) - kieu MQL4 rat cu
int Year()      { return TimeYear(TimeCurrent());      }
int Month()     { return TimeMonth(TimeCurrent());     }
int Day()       { return TimeDay(TimeCurrent());       }
int Hour()      { return TimeHour(TimeCurrent());      }
int Minute()    { return TimeMinute(TimeCurrent());    }
int Seconds()   { return TimeSeconds(TimeCurrent());   }
int DayOfWeek() { return TimeDayOfWeek(TimeCurrent());  }

//====================================================================
// iMA()/iFractals() ban tra ve gia tri truc tiep (kieu MQL4), du lieu
// lay qua CopyBuffer tu handle indicator (MQL5 tu dong cache handle
// theo bo tham so nen goi lai moi tick khong gay ro ri tai nguyen).
//====================================================================
ENUM_APPLIED_PRICE MT4AppliedPrice(int p) { return (ENUM_APPLIED_PRICE)(p+1); }

double iMA(string symbol,int timeframe,int period,int ma_shift,int ma_method,int applied_price,int shift)
{
   int handle=iMA(symbol,MT4Period(timeframe),period,ma_shift,(ENUM_MA_METHOD)ma_method,MT4AppliedPrice(applied_price));
   if(handle==INVALID_HANDLE) return 0.0;
   double buf[];
   ArraySetAsSeries(buf,true);
   if(CopyBuffer(handle,0,shift,1,buf)<=0) return 0.0;
   return buf[0];
}

double iFractals(string symbol,int timeframe,int mode,int shift)
{
   int handle=iFractals(symbol,MT4Period(timeframe));
   if(handle==INVALID_HANDLE) return 0.0;
   int bufIndex=(mode==1)?0:1; // 1=MODE_UPPER->buffer0, 2=MODE_LOWER->buffer1
   double buf[];
   ArraySetAsSeries(buf,true);
   if(CopyBuffer(handle,bufIndex,shift,1,buf)<=0) return 0.0;
   return buf[0];
}

//====================================================================
// Chuyen doi retcode cua MQL5 -> ma loi kieu MQL4 (de cac doan retry
// "if(MT4_LastError()==132) ..." trong code goc hoat dong dung y nghia)
//====================================================================
int MT4_LastError() { return g_mt4_lastError; }

int TradeRetcodeToMT4Error(uint retcode)
{
   switch(retcode)
   {
      case TRADE_RETCODE_REQUOTE:        return 138; // ERR_REQUOTE
      case TRADE_RETCODE_REJECT:         return 134; // ERR_NOT_ENOUGH_MONEY (xap xi)
      case TRADE_RETCODE_CONNECTION:     return 137; // ERR_BROKER_BUSY (xap xi)
      case TRADE_RETCODE_MARKET_CLOSED:  return 132; // ERR_MARKET_CLOSED
      case TRADE_RETCODE_TRADE_DISABLED: return 133; // ERR_TRADE_DISABLED
      case TRADE_RETCODE_NO_MONEY:       return 134; // ERR_NOT_ENOUGH_MONEY
      case TRADE_RETCODE_PRICE_CHANGED:  return 135; // ERR_PRICE_CHANGED
      case TRADE_RETCODE_PRICE_OFF:      return 136; // ERR_OFF_QUOTES
      case TRADE_RETCODE_INVALID_STOPS:  return 130; // ERR_INVALID_STOPS
      case TRADE_RETCODE_INVALID_PRICE:  return 129; // ERR_INVALID_PRICE
      case TRADE_RETCODE_TIMEOUT:        return 128; // ERR_TRADE_TIMEOUT
      case TRADE_RETCODE_INVALID_VOLUME: return 131; // ERR_INVALID_TRADE_VOLUME
      case TRADE_RETCODE_DONE:           return 0;
      case TRADE_RETCODE_DONE_PARTIAL:   return 0;
      case TRADE_RETCODE_PLACED:         return 0;
   }
   return (int)retcode;
}

ENUM_ORDER_TYPE_FILLING MT4SelectFilling(string symbol)
{
   long filling=SymbolInfoInteger(symbol,SYMBOL_FILLING_MODE);
   if((filling&SYMBOL_FILLING_FOK)!=0)  return ORDER_FILLING_FOK;
   if((filling&SYMBOL_FILLING_IOC)!=0)  return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
}

//====================================================================
// OrderSend() kieu MQL4 (11 tham so) -> tra ve ticket (>=0) hoac -1
//====================================================================
long OrderSend(string symbol,int cmd,double volume,double price,int slippage,
               double stoploss,double takeprofit,string comment="",int magic=0,
               datetime expiration=0,color arrow_color=clrNONE)
{
   MqlTradeRequest request;
   MqlTradeResult  result;
   ZeroMemory(request);
   ZeroMemory(result);

   request.symbol   = symbol;
   request.volume    = volume;
   request.magic     = (ulong)magic;
   request.comment    = comment;
   request.deviation  = (ulong)MathMax(slippage,0);
   request.sl          = stoploss;
   request.tp          = takeprofit;

   if(cmd==OP_BUY || cmd==OP_SELL)
   {
      request.action       = TRADE_ACTION_DEAL;
      request.type          = (cmd==OP_BUY)?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
      request.price          = (price>0.0)?price:((cmd==OP_BUY)?SymbolInfoDouble(symbol,SYMBOL_ASK):SymbolInfoDouble(symbol,SYMBOL_BID));
      request.type_filling   = MT4SelectFilling(symbol);
   }
   else
   {
      request.action = TRADE_ACTION_PENDING;
      switch(cmd)
      {
         case OP_BUYLIMIT:  request.type=ORDER_TYPE_BUY_LIMIT;  break;
         case OP_SELLLIMIT: request.type=ORDER_TYPE_SELL_LIMIT; break;
         case OP_BUYSTOP:   request.type=ORDER_TYPE_BUY_STOP;   break;
         case OP_SELLSTOP:  request.type=ORDER_TYPE_SELL_STOP;  break;
      }
      request.price=price;
      if(expiration>0)
      {
         request.type_time = ORDER_TIME_SPECIFIED;
         request.expiration = expiration;
      }
      else request.type_time = ORDER_TIME_GTC;
      request.type_filling = ORDER_FILLING_RETURN;
   }

   ResetLastError();
   bool sent = ::OrderSend(request,result);
   g_mt4_lastError = TradeRetcodeToMT4Error(result.retcode);

   if(result.retcode==TRADE_RETCODE_DONE || result.retcode==TRADE_RETCODE_DONE_PARTIAL || result.retcode==TRADE_RETCODE_PLACED)
   {
      g_mt4_lastError = 0;
      g_mt4_lastTicket = (long)((result.order!=0)?result.order:result.deal);
      return g_mt4_lastTicket;
   }
   g_mt4_lastTicket = -1;
   return -1;
}

//====================================================================
// OrderModify() kieu MQL4
//====================================================================
bool OrderModify(long ticket,double price,double stoploss,double takeprofit,datetime expiration,color arrow_color=clrNONE)
{
   MqlTradeRequest request;
   MqlTradeResult  result;
   ZeroMemory(request);
   ZeroMemory(result);

   if(PositionSelectByTicket((ulong)ticket))
   {
      request.action   = TRADE_ACTION_SLTP;
      request.position  = (ulong)ticket;
      request.symbol     = PositionGetString(POSITION_SYMBOL);
      request.sl          = stoploss;
      request.tp          = takeprofit;
   }
   else if(::OrderSelect((ulong)ticket))
   {
      request.action    = TRADE_ACTION_MODIFY;
      request.order       = (ulong)ticket;
      request.price        = price;
      request.sl            = stoploss;
      request.tp            = takeprofit;
      if(expiration>0)
      {
         request.type_time = ORDER_TIME_SPECIFIED;
         request.expiration = expiration;
      }
      else request.type_time = ORDER_TIME_GTC;
   }
   else
   {
      g_mt4_lastError = 4108; // ERR_INVALID_TICKET
      return false;
   }

   ResetLastError();
   bool sent = ::OrderSend(request,result);
   g_mt4_lastError = TradeRetcodeToMT4Error(result.retcode);
   if(result.retcode==TRADE_RETCODE_DONE || result.retcode==TRADE_RETCODE_DONE_PARTIAL)
   {
      g_mt4_lastError = 0;
      return true;
   }
   return false;
}

//====================================================================
// OrderClose() kieu MQL4 (dong vi the theo ticket)
//====================================================================
bool OrderClose(long ticket,double lots,double price,int slippage,color arrow_color=clrNONE)
{
   if(!PositionSelectByTicket((ulong)ticket))
   {
      g_mt4_lastError = 4108; // ERR_INVALID_TICKET
      return false;
   }
   string symbol=PositionGetString(POSITION_SYMBOL);
   long   posType=PositionGetInteger(POSITION_TYPE);
   double volume=PositionGetDouble(POSITION_VOLUME);
   double closeLots=(lots>0.0 && lots<volume)?lots:volume;

   MqlTradeRequest request;
   MqlTradeResult  result;
   ZeroMemory(request);
   ZeroMemory(result);

   request.action        = TRADE_ACTION_DEAL;
   request.position        = (ulong)ticket;
   request.symbol            = symbol;
   request.volume             = closeLots;
   request.deviation           = (ulong)MathMax(slippage,0);
   request.type_filling         = MT4SelectFilling(symbol);
   if(posType==POSITION_TYPE_BUY)
   {
      request.type  = ORDER_TYPE_SELL;
      request.price  = (price>0.0)?price:SymbolInfoDouble(symbol,SYMBOL_BID);
   }
   else
   {
      request.type   = ORDER_TYPE_BUY;
      request.price   = (price>0.0)?price:SymbolInfoDouble(symbol,SYMBOL_ASK);
   }

   ResetLastError();
   bool sent = ::OrderSend(request,result);
   g_mt4_lastError = TradeRetcodeToMT4Error(result.retcode);
   if(result.retcode==TRADE_RETCODE_DONE || result.retcode==TRADE_RETCODE_DONE_PARTIAL)
   {
      g_mt4_lastError = 0;
      return true;
   }
   return false;
}

//====================================================================
// OrderDelete() kieu MQL4 (huy lenh cho)
//====================================================================
bool OrderDelete(long ticket,color arrow_color=clrNONE)
{
   MqlTradeRequest request;
   MqlTradeResult  result;
   ZeroMemory(request);
   ZeroMemory(result);
   request.action = TRADE_ACTION_REMOVE;
   request.order    = (ulong)ticket;

   ResetLastError();
   bool sent = ::OrderSend(request,result);
   g_mt4_lastError = TradeRetcodeToMT4Error(result.retcode);
   if(result.retcode==TRADE_RETCODE_DONE)
   {
      g_mt4_lastError = 0;
      return true;
   }
   return false;
}

//====================================================================
// Vung du lieu "lenh dang chon" hien tai kieu MQL4 (OrderSelect/
// OrderTicket/OrderType/OrderLots/...). Ho tro ca vi the dang mo,
// lenh cho dang mo (pool=MODE_TRADES) va lich su (pool=MODE_HISTORY).
//====================================================================
long   g_selOrder_ticket=0;
string g_selOrder_symbol="";
int    g_selOrder_type=0;
double g_selOrder_lots=0.0;
double g_selOrder_openPrice=0.0;
double g_selOrder_closePrice=0.0;
double g_selOrder_sl=0.0;
double g_selOrder_tp=0.0;
datetime g_selOrder_openTime=0;
datetime g_selOrder_closeTime=0;
datetime g_selOrder_expiration=0;
double g_selOrder_profit=0.0;
double g_selOrder_swap=0.0;
double g_selOrder_commission=0.0;
string g_selOrder_comment="";
int    g_selOrder_magic=0;

//--- danh sach cache cho pool=MODE_HISTORY (xay tu HistoryDealsTotal) ---
long     g_hist_ticket[];
string   g_hist_symbol[];
int      g_hist_type[];
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

void MT4BuildHistoryCache()
{
   // Xay lai toi da 1 lan / giay de tranh qua tai khi vong lap goi lien tuc
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

   long     posIds[];
   int      idxByPos_pos[]; // song song voi posIds: vi tri trong mang cache
   ArrayResize(posIds,0);

   for(int i=0;i<deals;i++)
   {
      ulong dealTicket=HistoryDealGetTicket(i);
      if(dealTicket==0) continue;
      long entry=HistoryDealGetInteger(dealTicket,DEAL_ENTRY);
      long posId=HistoryDealGetInteger(dealTicket,DEAL_POSITION_ID);
      long dealType=HistoryDealGetInteger(dealTicket,DEAL_TYPE);
      if(dealType!=DEAL_TYPE_BUY && dealType!=DEAL_TYPE_SELL) continue; // bo qua balance/credit/...

      int pos=-1;
      for(int k=0;k<ArraySize(posIds);k++)
      {
         if(posIds[k]==posId) { pos=k; break; }
      }
      if(pos<0)
      {
         pos=ArraySize(posIds);
         ArrayResize(posIds,pos+1);
         posIds[pos]=posId;
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
         g_hist_ticket[g_hist_count]=(long)posId;
         g_hist_symbol[g_hist_count]="";
         g_hist_type[g_hist_count]=0;
         g_hist_lots[g_hist_count]=0.0;
         g_hist_openPrice[g_hist_count]=0.0;
         g_hist_closePrice[g_hist_count]=0.0;
         g_hist_openTime[g_hist_count]=0;
         g_hist_closeTime[g_hist_count]=0;
         g_hist_profit[g_hist_count]=0.0;
         g_hist_swap[g_hist_count]=0.0;
         g_hist_commission[g_hist_count]=0.0;
         g_hist_comment[g_hist_count]="";
         g_hist_magic[g_hist_count]=0;
         g_hist_expiration[g_hist_count]=0;
         g_hist_count=n;
      }

      if(entry==DEAL_ENTRY_IN)
      {
         g_hist_symbol[pos]=HistoryDealGetString(dealTicket,DEAL_SYMBOL);
         g_hist_type[pos]=(dealType==DEAL_TYPE_BUY)?OP_BUY:OP_SELL;
         g_hist_lots[pos]=HistoryDealGetDouble(dealTicket,DEAL_VOLUME);
         g_hist_openPrice[pos]=HistoryDealGetDouble(dealTicket,DEAL_PRICE);
         g_hist_openTime[pos]=(datetime)HistoryDealGetInteger(dealTicket,DEAL_TIME);
         g_hist_magic[pos]=(int)HistoryDealGetInteger(dealTicket,DEAL_MAGIC);
         g_hist_comment[pos]=HistoryDealGetString(dealTicket,DEAL_COMMENT);
         g_hist_profit[pos]+=HistoryDealGetDouble(dealTicket,DEAL_PROFIT);
         g_hist_swap[pos]+=HistoryDealGetDouble(dealTicket,DEAL_SWAP);
         g_hist_commission[pos]+=HistoryDealGetDouble(dealTicket,DEAL_COMMISSION);
      }
      else // DEAL_ENTRY_OUT hoac DEAL_ENTRY_OUT_BY (dong 1 phan/toan bo)
      {
         g_hist_closePrice[pos]=HistoryDealGetDouble(dealTicket,DEAL_PRICE);
         datetime ct=(datetime)HistoryDealGetInteger(dealTicket,DEAL_TIME);
         if(ct>g_hist_closeTime[pos]) g_hist_closeTime[pos]=ct;
         g_hist_profit[pos]+=HistoryDealGetDouble(dealTicket,DEAL_PROFIT);
         g_hist_swap[pos]+=HistoryDealGetDouble(dealTicket,DEAL_SWAP);
         g_hist_commission[pos]+=HistoryDealGetDouble(dealTicket,DEAL_COMMISSION);
         if(g_hist_symbol[pos]=="") g_hist_symbol[pos]=HistoryDealGetString(dealTicket,DEAL_SYMBOL);
         if(g_hist_magic[pos]==0)   g_hist_magic[pos]=(int)HistoryDealGetInteger(dealTicket,DEAL_MAGIC);
      }
   }
   // sap xep tang dan theo thoi gian dong (gan giong thu tu ticket MQL4)
   for(int a=0;a<g_hist_count;a++)
   for(int b=a+1;b<g_hist_count;b++)
   {
      if(g_hist_closeTime[b]<g_hist_closeTime[a])
      {
         long lt; string ss; int it; double dd; datetime dt;
         lt=g_hist_ticket[a]; g_hist_ticket[a]=g_hist_ticket[b]; g_hist_ticket[b]=lt;
         ss=g_hist_symbol[a]; g_hist_symbol[a]=g_hist_symbol[b]; g_hist_symbol[b]=ss;
         it=g_hist_type[a]; g_hist_type[a]=g_hist_type[b]; g_hist_type[b]=it;
         dd=g_hist_lots[a]; g_hist_lots[a]=g_hist_lots[b]; g_hist_lots[b]=dd;
         dd=g_hist_openPrice[a]; g_hist_openPrice[a]=g_hist_openPrice[b]; g_hist_openPrice[b]=dd;
         dd=g_hist_closePrice[a]; g_hist_closePrice[a]=g_hist_closePrice[b]; g_hist_closePrice[b]=dd;
         dt=g_hist_openTime[a]; g_hist_openTime[a]=g_hist_openTime[b]; g_hist_openTime[b]=dt;
         dt=g_hist_closeTime[a]; g_hist_closeTime[a]=g_hist_closeTime[b]; g_hist_closeTime[b]=dt;
         dd=g_hist_profit[a]; g_hist_profit[a]=g_hist_profit[b]; g_hist_profit[b]=dd;
         dd=g_hist_swap[a]; g_hist_swap[a]=g_hist_swap[b]; g_hist_swap[b]=dd;
         dd=g_hist_commission[a]; g_hist_commission[a]=g_hist_commission[b]; g_hist_commission[b]=dd;
         ss=g_hist_comment[a]; g_hist_comment[a]=g_hist_comment[b]; g_hist_comment[b]=ss;
         it=g_hist_magic[a]; g_hist_magic[a]=g_hist_magic[b]; g_hist_magic[b]=it;
      }
   }
}

//====================================================================
// OrdersTotal() kieu MQL4 (vi the dang mo + lenh cho) -> doi ten thanh
// MT4OrdersTotal() vi OrdersTotal() da la ham co san cua MQL5 (chi dem
// lenh cho) nen khong the dinh nghia chong len.
//====================================================================
int MT4OrdersTotal()
{
   return PositionsTotal()+OrdersTotal();
}

int HistoryTotal()
{
   MT4BuildHistoryCache();
   return g_hist_count;
}

//====================================================================
// OrderSelect() kieu MQL4 (3 tham so, khac chu ky voi ham OrderSelect
// 1-tham-so co san cua MQL5 nen khong xung dot).
//====================================================================
bool OrderSelect(int index_or_ticket,int select,int pool=MODE_TRADES)
{
   if(select==SELECT_BY_TICKET)
   {
      long ticket=(long)index_or_ticket;
      if(PositionSelectByTicket((ulong)ticket))
      {
         g_selOrder_ticket=ticket;
         g_selOrder_symbol=PositionGetString(POSITION_SYMBOL);
         g_selOrder_type=(int)PositionGetInteger(POSITION_TYPE);
         g_selOrder_lots=PositionGetDouble(POSITION_VOLUME);
         g_selOrder_openPrice=PositionGetDouble(POSITION_PRICE_OPEN);
         g_selOrder_closePrice=PositionGetDouble(POSITION_PRICE_CURRENT);
         g_selOrder_sl=PositionGetDouble(POSITION_SL);
         g_selOrder_tp=PositionGetDouble(POSITION_TP);
         g_selOrder_openTime=(datetime)PositionGetInteger(POSITION_TIME);
         g_selOrder_closeTime=0;
         g_selOrder_expiration=0;
         g_selOrder_profit=PositionGetDouble(POSITION_PROFIT);
         g_selOrder_swap=PositionGetDouble(POSITION_SWAP);
         g_selOrder_commission=0.0;
         g_selOrder_comment=PositionGetString(POSITION_COMMENT);
         g_selOrder_magic=(int)PositionGetInteger(POSITION_MAGIC);
         return true;
      }
      if(::OrderSelect((ulong)ticket))
      {
         g_selOrder_ticket=ticket;
         g_selOrder_symbol=::OrderGetString(ORDER_SYMBOL);
         g_selOrder_type=(int)::OrderGetInteger(ORDER_TYPE);
         g_selOrder_lots=::OrderGetDouble(ORDER_VOLUME_CURRENT);
         g_selOrder_openPrice=::OrderGetDouble(ORDER_PRICE_OPEN);
         g_selOrder_closePrice=0.0;
         g_selOrder_sl=::OrderGetDouble(ORDER_SL);
         g_selOrder_tp=::OrderGetDouble(ORDER_TP);
         g_selOrder_openTime=(datetime)::OrderGetInteger(ORDER_TIME_SETUP);
         g_selOrder_closeTime=0;
         g_selOrder_expiration=(datetime)::OrderGetInteger(ORDER_TIME_EXPIRATION);
         g_selOrder_profit=0.0;
         g_selOrder_swap=0.0;
         g_selOrder_commission=0.0;
         g_selOrder_comment=::OrderGetString(ORDER_COMMENT);
         g_selOrder_magic=(int)::OrderGetInteger(ORDER_MAGIC);
         return true;
      }
      MT4BuildHistoryCache();
      for(int i=0;i<g_hist_count;i++)
      {
         if(g_hist_ticket[i]==ticket)
         {
            g_selOrder_ticket=g_hist_ticket[i];
            g_selOrder_symbol=g_hist_symbol[i];
            g_selOrder_type=g_hist_type[i];
            g_selOrder_lots=g_hist_lots[i];
            g_selOrder_openPrice=g_hist_openPrice[i];
            g_selOrder_closePrice=g_hist_closePrice[i];
            g_selOrder_sl=0.0;
            g_selOrder_tp=0.0;
            g_selOrder_openTime=g_hist_openTime[i];
            g_selOrder_closeTime=g_hist_closeTime[i];
            g_selOrder_expiration=0;
            g_selOrder_profit=g_hist_profit[i];
            g_selOrder_swap=g_hist_swap[i];
            g_selOrder_commission=g_hist_commission[i];
            g_selOrder_comment=g_hist_comment[i];
            g_selOrder_magic=g_hist_magic[i];
            return true;
         }
      }
      return false;
   }

   // SELECT_BY_POS
   if(pool==MODE_HISTORY)
   {
      MT4BuildHistoryCache();
      if(index_or_ticket<0 || index_or_ticket>=g_hist_count) return false;
      int i=index_or_ticket;
      g_selOrder_ticket=g_hist_ticket[i];
      g_selOrder_symbol=g_hist_symbol[i];
      g_selOrder_type=g_hist_type[i];
      g_selOrder_lots=g_hist_lots[i];
      g_selOrder_openPrice=g_hist_openPrice[i];
      g_selOrder_closePrice=g_hist_closePrice[i];
      g_selOrder_sl=0.0;
      g_selOrder_tp=0.0;
      g_selOrder_openTime=g_hist_openTime[i];
      g_selOrder_closeTime=g_hist_closeTime[i];
      g_selOrder_expiration=0;
      g_selOrder_profit=g_hist_profit[i];
      g_selOrder_swap=g_hist_swap[i];
      g_selOrder_commission=g_hist_commission[i];
      g_selOrder_comment=g_hist_comment[i];
      g_selOrder_magic=g_hist_magic[i];
      return true;
   }

   // pool==MODE_TRADES: vi the dang mo (index 0..PositionsTotal()-1) roi
   // toi lenh cho dang mo (index PositionsTotal()..total-1)
   int posTotal=PositionsTotal();
   if(index_or_ticket>=0 && index_or_ticket<posTotal)
   {
      ulong ticket=PositionGetTicket(index_or_ticket);
      if(ticket==0) return false;
      g_selOrder_ticket=(long)ticket;
      g_selOrder_symbol=PositionGetString(POSITION_SYMBOL);
      g_selOrder_type=(int)PositionGetInteger(POSITION_TYPE);
      g_selOrder_lots=PositionGetDouble(POSITION_VOLUME);
      g_selOrder_openPrice=PositionGetDouble(POSITION_PRICE_OPEN);
      g_selOrder_closePrice=PositionGetDouble(POSITION_PRICE_CURRENT);
      g_selOrder_sl=PositionGetDouble(POSITION_SL);
      g_selOrder_tp=PositionGetDouble(POSITION_TP);
      g_selOrder_openTime=(datetime)PositionGetInteger(POSITION_TIME);
      g_selOrder_closeTime=0;
      g_selOrder_expiration=0;
      g_selOrder_profit=PositionGetDouble(POSITION_PROFIT);
      g_selOrder_swap=PositionGetDouble(POSITION_SWAP);
      g_selOrder_commission=0.0;
      g_selOrder_comment=PositionGetString(POSITION_COMMENT);
      g_selOrder_magic=(int)PositionGetInteger(POSITION_MAGIC);
      return true;
   }
   int ordIdx=index_or_ticket-posTotal;
   int ordTotal=::OrdersTotal();
   if(ordIdx>=0 && ordIdx<ordTotal)
   {
      ulong ticket=::OrderGetTicket(ordIdx);
      if(ticket==0) return false;
      g_selOrder_ticket=(long)ticket;
      g_selOrder_symbol=::OrderGetString(ORDER_SYMBOL);
      g_selOrder_type=(int)::OrderGetInteger(ORDER_TYPE);
      g_selOrder_lots=::OrderGetDouble(ORDER_VOLUME_CURRENT);
      g_selOrder_openPrice=::OrderGetDouble(ORDER_PRICE_OPEN);
      g_selOrder_closePrice=0.0;
      g_selOrder_sl=::OrderGetDouble(ORDER_SL);
      g_selOrder_tp=::OrderGetDouble(ORDER_TP);
      g_selOrder_openTime=(datetime)::OrderGetInteger(ORDER_TIME_SETUP);
      g_selOrder_closeTime=0;
      g_selOrder_expiration=(datetime)::OrderGetInteger(ORDER_TIME_EXPIRATION);
      g_selOrder_profit=0.0;
      g_selOrder_swap=0.0;
      g_selOrder_commission=0.0;
      g_selOrder_comment=::OrderGetString(ORDER_COMMENT);
      g_selOrder_magic=(int)::OrderGetInteger(ORDER_MAGIC);
      return true;
   }
   return false;
}

//====================================================================
// Cac ham lay thuoc tinh cua "lenh dang chon" kieu MQL4
//====================================================================
long   OrderTicket()      { return g_selOrder_ticket;      }
string OrderSymbol()      { return g_selOrder_symbol;      }
int    OrderType()        { return g_selOrder_type;        }
double OrderLots()        { return g_selOrder_lots;        }
double OrderOpenPrice()   { return g_selOrder_openPrice;   }
double OrderClosePrice()  { return g_selOrder_closePrice;  }
double OrderStopLoss()    { return g_selOrder_sl;          }
double OrderTakeProfit()  { return g_selOrder_tp;          }
datetime OrderOpenTime()  { return g_selOrder_openTime;    }
datetime OrderCloseTime() { return g_selOrder_closeTime;   }
datetime OrderExpiration(){ return g_selOrder_expiration;  }
double OrderProfit()      { return g_selOrder_profit;      }
double OrderSwap()        { return g_selOrder_swap;        }
double OrderCommission()  { return g_selOrder_commission;  }
string OrderComment()     { return g_selOrder_comment;     }
int    OrderMagicNumber() { return g_selOrder_magic;       }

#endif // __MQL4COMPAT_MQH__
