#property copyright  "Copyright 2026 - Pham Duy Linh"
#property link       "https://t.me/Khonglammadoicoan96"
#property version    "4.5"
#property description "- Fixed the www.worldtimeserver GMT fetch bug"
#property description "- Fixed the OnlyUp bug"
#property description "- Hardcoded NFP dates -> now automatic (MT5 Economic Calendar), auto-retries on error"
#property description "- Added input to close trades at end of Friday session"
#property description "- Highest Balance shown on panel"
#property description "- Warns the exact missing allowed URL"
#property description "- Full MT4-style trade logging"
#property description "- A few handy inputs (all default to the original behavior)"
#property description "Telegram: t.me/Khonglammadoicoan96"

//==================================================================
// MQL4Compat: lop tuong thich MQL4->MQL5 (truoc day la file include
// rieng MQL4Compat.mqh) - da GOP truc tiep vao day de EA chi con 1
// file .mq5 duy nhat, khong can copy file include rieng.
//==================================================================
//+------------------------------------------------------------------+
//| MQL4Compat.mqh                                                    |
//|                                                                    |
//| Lop tuong thich MQL4 -> MQL5 danh rieng cho The Gold Reaper.       |
//| Muc dich: cho phep GIU NGUYEN 100% logic goc viet theo phong cach  |
//| MQL4 (OrderSend/OrderModify/OrderClose/OrderDelete/OrderSelect,    |
//| OrdersTotal/HistoryTotal, MarketInfo, AccountBalance/Equity,       |
//| Time*()/Year()/Month()/Day()/Hour()/Minute()/Seconds()/DayOfWeek(),|
//| iMA()/iFractals() kieu tra ve gia tri truc tiep...) trong khi thuc |
//| thi ben duoi hoan toan bang API MQL5 (Position/Order/Deal,         |
//| OrderSend(MqlTradeRequest&,MqlTradeResult&) dong bo truc tiep -    |
//| khong qua CTrade - de gui/sua/dong/huy lenh, SymbolInfo*,          |
//| AccountInfo*, TimeToStruct...).                                    |
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
// IsDemo()/IsTesting() kieu MQL4 (khong con la ham co san trong MQL5)
//====================================================================
bool IsDemo()    { return AccountInfoInteger(ACCOUNT_TRADE_MODE)==ACCOUNT_TRADE_MODE_DEMO; }
bool IsTesting() { return (bool)MQLInfoInteger(MQL_TESTER); }

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

//====================================================================
// Gui lenh truc tiep bang OrderSend(MqlTradeRequest&,MqlTradeResult&)
// dong bo nguyen sinh cua MQL5 - KHONG qua lop CTrade. CTrade them 1
// lop trung gian (kiem tra trang thai, log, tach rieng ham cho tung
// loai lenh...) phia tren cung 1 loi goi OrderSend() nay, nen ban than
// no khong lam lenh "vao nhanh hon" ma chi lam cham hon so voi tu xay
// MqlTradeRequest va goi thang OrderSend() nhu 1 EA MQL5 viet tay (goi
// la "lenh tho"). Ham nay van dong bo 100% (cho server tra loi that
// truoc khi return, giong CTrade truoc day) nen an toan/logic khong
// doi - chi bo bot lop trung gian de dat toc do bang lenh tho.
//====================================================================
ENUM_ORDER_TYPE_FILLING MT4SelectFilling(string symbol)
{
   long mask=SymbolInfoInteger(symbol,SYMBOL_FILLING_MODE);
   if((mask&SYMBOL_FILLING_FOK)!=0)  return ORDER_FILLING_FOK;
   if((mask&SYMBOL_FILLING_IOC)!=0)  return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
}

//====================================================================
// Log thao tac lenh GIONG TERMINAL MT4: MT4 tu dong in moi thao tac
// cua EA vao tab Experts ("open #123 buy stop 0.11 XAUUSD at ... ok"),
// ca thanh cong lan that bai. MT5 khong tu in nhu vay cho ::OrderSend
// tho, nen tu in lai o day de log giong het MT4. Chi log, khong doi logic.
//====================================================================
string MT4OrderTypeName(int t)
{
   switch(t)
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

void MT4PrintTradeOk(string op,long ticket,const MqlTradeRequest &request)
{
   PrintFormat("%s #%I64d %s %.2f %s at %.5f sl: %.5f tp: %.5f ok",
               op,ticket,MT4OrderTypeName((int)request.type),request.volume,
               request.symbol,request.price,request.sl,request.tp);
}

void MT4PrintTradeReject(string op,const MqlTradeRequest &request,const MqlTradeResult &result)
{
   PrintFormat("failed %s %s %.2f %s at %.5f sl: %.5f tp: %.5f [%s] (retcode=%u, ticket=%I64u)",
               op,MT4OrderTypeName((int)request.type),request.volume,request.symbol,
               request.price,request.sl,request.tp,result.comment,result.retcode,
               (request.position>0)?request.position:request.order);
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
   request.symbol=symbol;
   request.volume=volume;
   request.sl=stoploss;
   request.tp=takeprofit;
   request.comment=comment;
   request.magic=(ulong)magic;
   request.deviation=(ulong)MathMax(slippage,0);
   request.type_filling=MT4SelectFilling(symbol);

   if(cmd==OP_BUY || cmd==OP_SELL)
   {
      request.action=TRADE_ACTION_DEAL;
      request.type=(cmd==OP_BUY)?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
      request.price=(cmd==OP_BUY)?SymbolInfoDouble(symbol,SYMBOL_ASK):SymbolInfoDouble(symbol,SYMBOL_BID);
   }
   else
   {
      request.action=TRADE_ACTION_PENDING;
      switch(cmd)
      {
         case OP_BUYLIMIT:  request.type=ORDER_TYPE_BUY_LIMIT;  break;
         case OP_SELLLIMIT: request.type=ORDER_TYPE_SELL_LIMIT; break;
         case OP_BUYSTOP:   request.type=ORDER_TYPE_BUY_STOP;   break;
         case OP_SELLSTOP:  request.type=ORDER_TYPE_SELL_STOP;  break;
      }
      request.price=price;
      request.type_time=(expiration>0)?ORDER_TIME_SPECIFIED:ORDER_TIME_GTC;
      request.expiration=expiration;
      request.type_filling=ORDER_FILLING_RETURN;
   }

   bool ok=::OrderSend(request,result);
   if(!ok && result.retcode==0) result.retcode=TRADE_RETCODE_ERROR;
   g_mt4_lastError=TradeRetcodeToMT4Error(result.retcode);
   if(ok && (result.retcode==TRADE_RETCODE_DONE || result.retcode==TRADE_RETCODE_DONE_PARTIAL || result.retcode==TRADE_RETCODE_PLACED))
   {
      g_mt4_lastError=0;
      ulong ticket=result.order;
      if(ticket==0) ticket=result.deal;
      g_mt4_lastTicket=(long)ticket;
      MT4PrintTradeOk("open",g_mt4_lastTicket,request);
      return g_mt4_lastTicket;
   }
   MT4PrintTradeReject("open",request,result);
   g_mt4_lastTicket=-1;
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
      request.action=TRADE_ACTION_SLTP;
      request.position=(ulong)ticket;
      request.symbol=PositionGetString(POSITION_SYMBOL);
      request.sl=stoploss;
      request.tp=takeprofit;
   }
   else if(::OrderSelect((ulong)ticket))
   {
      request.action=TRADE_ACTION_MODIFY;
      request.order=(ulong)ticket;
      request.price=price;
      request.sl=stoploss;
      request.tp=takeprofit;
      request.type_time=(expiration>0)?ORDER_TIME_SPECIFIED:ORDER_TIME_GTC;
      request.expiration=expiration;
   }
   else
   {
      g_mt4_lastError = 4108; // ERR_INVALID_TICKET
      return false;
   }

   bool ok=::OrderSend(request,result);
   if(!ok && result.retcode==0) result.retcode=TRADE_RETCODE_ERROR;
   g_mt4_lastError=TradeRetcodeToMT4Error(result.retcode);
   if(ok && (result.retcode==TRADE_RETCODE_DONE || result.retcode==TRADE_RETCODE_DONE_PARTIAL))
   {
      g_mt4_lastError=0;
      PrintFormat("modify #%I64d %s price: %.5f sl: %.5f tp: %.5f ok",
                  ticket,request.symbol,request.price,request.sl,request.tp);
      return true;
   }
   MT4PrintTradeReject("modify",request,result);
   return false;
}

//====================================================================
// OrderClose() kieu MQL4 (dong vi the theo ticket, ho tro dong 1 phan)
//====================================================================
bool OrderClose(long ticket,double lots,double price,int slippage,color arrow_color=clrNONE)
{
   if(!PositionSelectByTicket((ulong)ticket))
   {
      g_mt4_lastError = 4108; // ERR_INVALID_TICKET
      return false;
   }
   string symbol=PositionGetString(POSITION_SYMBOL);
   double volume=PositionGetDouble(POSITION_VOLUME);
   long   posType=PositionGetInteger(POSITION_TYPE);
   double closeLots=(lots>0.0 && lots<volume)?lots:volume;

   MqlTradeRequest request;
   MqlTradeResult  result;
   ZeroMemory(request);
   ZeroMemory(result);
   request.action=TRADE_ACTION_DEAL;
   request.position=(ulong)ticket;
   request.symbol=symbol;
   request.volume=closeLots;
   request.deviation=(ulong)MathMax(slippage,0);
   request.type_filling=MT4SelectFilling(symbol);
   if(posType==POSITION_TYPE_BUY)
   {
      request.type=ORDER_TYPE_SELL;
      request.price=SymbolInfoDouble(symbol,SYMBOL_BID);
   }
   else
   {
      request.type=ORDER_TYPE_BUY;
      request.price=SymbolInfoDouble(symbol,SYMBOL_ASK);
   }

   bool ok=::OrderSend(request,result);
   if(!ok && result.retcode==0) result.retcode=TRADE_RETCODE_ERROR;
   g_mt4_lastError=TradeRetcodeToMT4Error(result.retcode);
   if(ok && (result.retcode==TRADE_RETCODE_DONE || result.retcode==TRADE_RETCODE_DONE_PARTIAL))
   {
      g_mt4_lastError=0;
      // MT4 in "close #ticket <chieu vi the goc> lots symbol at gia ok"
      PrintFormat("close #%I64d %s %.2f %s at %.5f ok",
                  ticket,(posType==POSITION_TYPE_BUY)?"buy":"sell",
                  closeLots,symbol,request.price);
      return true;
   }
   MT4PrintTradeReject("close",request,result);
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
   request.action=TRADE_ACTION_REMOVE;
   request.order=(ulong)ticket;
   // Lay thong tin lenh TRUOC khi xoa de log giong MT4
   // ("delete #123 buy stop 0.14 XAUUSD at 3962.66 ok")
   string delName="order"; double delVol=0.0,delPrice=0.0; string delSym="";
   if(::OrderSelect((ulong)ticket))
   {
      delName=MT4OrderTypeName((int)::OrderGetInteger(ORDER_TYPE));
      delVol=::OrderGetDouble(ORDER_VOLUME_CURRENT);
      delPrice=::OrderGetDouble(ORDER_PRICE_OPEN);
      delSym=::OrderGetString(ORDER_SYMBOL);
   }

   bool ok=::OrderSend(request,result);
   if(!ok && result.retcode==0) result.retcode=TRADE_RETCODE_ERROR;
   g_mt4_lastError=TradeRetcodeToMT4Error(result.retcode);
   if(ok && result.retcode==TRADE_RETCODE_DONE)
   {
      g_mt4_lastError=0;
      PrintFormat("delete #%I64d %s %.2f %s at %.5f ok",
                  ticket,delName,delVol,delSym,delPrice);
      return true;
   }
   MT4PrintTradeReject("delete",request,result);
   return false;
}

//====================================================================
// Vung du lieu "lenh dang chon" hien tai kieu MQL4 (OrderSelect/
// OrderTicket/OrderType/OrderLots/...). Ho tro ca vi the dang mo,
// lenh cho dang mo (pool=MODE_TRADES) va lich su (pool=MODE_HISTORY).
//====================================================================
// Trang thai "lenh dang chon" kieu MQL4 - gom vao 1 struct cho gon
// (truoc day la 16 bien toan cu roi g_selOrder.*). OrderSelect() dien
// vao day; OrderTicket()/OrderLots()/OrderType()/... doc ra tu day.
struct MT4SelectedOrder
{
   long     ticket;
   string   symbol;
   int      type;
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
MT4SelectedOrder g_selOrder;

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
         g_selOrder.ticket=ticket;
         g_selOrder.symbol=PositionGetString(POSITION_SYMBOL);
         g_selOrder.type=(int)PositionGetInteger(POSITION_TYPE);
         g_selOrder.lots=PositionGetDouble(POSITION_VOLUME);
         g_selOrder.openPrice=PositionGetDouble(POSITION_PRICE_OPEN);
         g_selOrder.closePrice=PositionGetDouble(POSITION_PRICE_CURRENT);
         g_selOrder.sl=PositionGetDouble(POSITION_SL);
         g_selOrder.tp=PositionGetDouble(POSITION_TP);
         g_selOrder.openTime=(datetime)PositionGetInteger(POSITION_TIME);
         g_selOrder.closeTime=0;
         g_selOrder.expiration=0;
         g_selOrder.profit=PositionGetDouble(POSITION_PROFIT);
         g_selOrder.swap=PositionGetDouble(POSITION_SWAP);
         g_selOrder.commission=0.0;
         g_selOrder.comment=PositionGetString(POSITION_COMMENT);
         g_selOrder.magic=(int)PositionGetInteger(POSITION_MAGIC);
         return true;
      }
      if(::OrderSelect((ulong)ticket))
      {
         g_selOrder.ticket=ticket;
         g_selOrder.symbol=::OrderGetString(ORDER_SYMBOL);
         g_selOrder.type=(int)::OrderGetInteger(ORDER_TYPE);
         g_selOrder.lots=::OrderGetDouble(ORDER_VOLUME_CURRENT);
         g_selOrder.openPrice=::OrderGetDouble(ORDER_PRICE_OPEN);
         g_selOrder.closePrice=0.0;
         g_selOrder.sl=::OrderGetDouble(ORDER_SL);
         g_selOrder.tp=::OrderGetDouble(ORDER_TP);
         g_selOrder.openTime=(datetime)::OrderGetInteger(ORDER_TIME_SETUP);
         g_selOrder.closeTime=0;
         g_selOrder.expiration=(datetime)::OrderGetInteger(ORDER_TIME_EXPIRATION);
         g_selOrder.profit=0.0;
         g_selOrder.swap=0.0;
         g_selOrder.commission=0.0;
         g_selOrder.comment=::OrderGetString(ORDER_COMMENT);
         g_selOrder.magic=(int)::OrderGetInteger(ORDER_MAGIC);
         return true;
      }
      MT4BuildHistoryCache();
      for(int i=0;i<g_hist_count;i++)
      {
         if(g_hist_ticket[i]==ticket)
         {
            g_selOrder.ticket=g_hist_ticket[i];
            g_selOrder.symbol=g_hist_symbol[i];
            g_selOrder.type=g_hist_type[i];
            g_selOrder.lots=g_hist_lots[i];
            g_selOrder.openPrice=g_hist_openPrice[i];
            g_selOrder.closePrice=g_hist_closePrice[i];
            g_selOrder.sl=0.0;
            g_selOrder.tp=0.0;
            g_selOrder.openTime=g_hist_openTime[i];
            g_selOrder.closeTime=g_hist_closeTime[i];
            g_selOrder.expiration=0;
            g_selOrder.profit=g_hist_profit[i];
            g_selOrder.swap=g_hist_swap[i];
            g_selOrder.commission=g_hist_commission[i];
            g_selOrder.comment=g_hist_comment[i];
            g_selOrder.magic=g_hist_magic[i];
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
      g_selOrder.ticket=g_hist_ticket[i];
      g_selOrder.symbol=g_hist_symbol[i];
      g_selOrder.type=g_hist_type[i];
      g_selOrder.lots=g_hist_lots[i];
      g_selOrder.openPrice=g_hist_openPrice[i];
      g_selOrder.closePrice=g_hist_closePrice[i];
      g_selOrder.sl=0.0;
      g_selOrder.tp=0.0;
      g_selOrder.openTime=g_hist_openTime[i];
      g_selOrder.closeTime=g_hist_closeTime[i];
      g_selOrder.expiration=0;
      g_selOrder.profit=g_hist_profit[i];
      g_selOrder.swap=g_hist_swap[i];
      g_selOrder.commission=g_hist_commission[i];
      g_selOrder.comment=g_hist_comment[i];
      g_selOrder.magic=g_hist_magic[i];
      return true;
   }

   // pool==MODE_TRADES: vi the dang mo (index 0..PositionsTotal()-1) roi
   // toi lenh cho dang mo (index PositionsTotal()..total-1)
   int posTotal=PositionsTotal();
   if(index_or_ticket>=0 && index_or_ticket<posTotal)
   {
      ulong ticket=PositionGetTicket(index_or_ticket);
      if(ticket==0) return false;
      g_selOrder.ticket=(long)ticket;
      g_selOrder.symbol=PositionGetString(POSITION_SYMBOL);
      g_selOrder.type=(int)PositionGetInteger(POSITION_TYPE);
      g_selOrder.lots=PositionGetDouble(POSITION_VOLUME);
      g_selOrder.openPrice=PositionGetDouble(POSITION_PRICE_OPEN);
      g_selOrder.closePrice=PositionGetDouble(POSITION_PRICE_CURRENT);
      g_selOrder.sl=PositionGetDouble(POSITION_SL);
      g_selOrder.tp=PositionGetDouble(POSITION_TP);
      g_selOrder.openTime=(datetime)PositionGetInteger(POSITION_TIME);
      g_selOrder.closeTime=0;
      g_selOrder.expiration=0;
      g_selOrder.profit=PositionGetDouble(POSITION_PROFIT);
      g_selOrder.swap=PositionGetDouble(POSITION_SWAP);
      g_selOrder.commission=0.0;
      g_selOrder.comment=PositionGetString(POSITION_COMMENT);
      g_selOrder.magic=(int)PositionGetInteger(POSITION_MAGIC);
      return true;
   }
   int ordIdx=index_or_ticket-posTotal;
   int ordTotal=::OrdersTotal();
   if(ordIdx>=0 && ordIdx<ordTotal)
   {
      ulong ticket=::OrderGetTicket(ordIdx);
      if(ticket==0) return false;
      g_selOrder.ticket=(long)ticket;
      g_selOrder.symbol=::OrderGetString(ORDER_SYMBOL);
      g_selOrder.type=(int)::OrderGetInteger(ORDER_TYPE);
      g_selOrder.lots=::OrderGetDouble(ORDER_VOLUME_CURRENT);
      g_selOrder.openPrice=::OrderGetDouble(ORDER_PRICE_OPEN);
      g_selOrder.closePrice=0.0;
      g_selOrder.sl=::OrderGetDouble(ORDER_SL);
      g_selOrder.tp=::OrderGetDouble(ORDER_TP);
      g_selOrder.openTime=(datetime)::OrderGetInteger(ORDER_TIME_SETUP);
      g_selOrder.closeTime=0;
      g_selOrder.expiration=(datetime)::OrderGetInteger(ORDER_TIME_EXPIRATION);
      g_selOrder.profit=0.0;
      g_selOrder.swap=0.0;
      g_selOrder.commission=0.0;
      g_selOrder.comment=::OrderGetString(ORDER_COMMENT);
      g_selOrder.magic=(int)::OrderGetInteger(ORDER_MAGIC);
      return true;
   }
   return false;
}

//====================================================================
// Cac ham lay thuoc tinh cua "lenh dang chon" kieu MQL4
//====================================================================
long   OrderTicket()      { return g_selOrder.ticket;      }
string OrderSymbol()      { return g_selOrder.symbol;      }
int    OrderType()        { return g_selOrder.type;        }
double OrderLots()        { return g_selOrder.lots;        }
double OrderOpenPrice()   { return g_selOrder.openPrice;   }
double OrderClosePrice()  { return g_selOrder.closePrice;  }
double OrderStopLoss()    { return g_selOrder.sl;          }
double OrderTakeProfit()  { return g_selOrder.tp;          }
datetime OrderOpenTime()  { return g_selOrder.openTime;    }
datetime OrderCloseTime() { return g_selOrder.closeTime;   }
datetime OrderExpiration(){ return g_selOrder.expiration;  }
double OrderProfit()      { return g_selOrder.profit;      }
double OrderSwap()        { return g_selOrder.swap;        }
double OrderCommission()  { return g_selOrder.commission;  }
string OrderComment()     { return g_selOrder.comment;     }
int    OrderMagicNumber() { return g_selOrder.magic;       }

#endif // __MQL4COMPAT_MQH__


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
  int       总_4_in_14 = 1440;
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
  double    总_40_do_D0 = 400.0;
  double    总_41_do_D8 = 100.0;
  double    总_42_do_E0 = 300.0;
  bool      总_43_bo_E8 = true;
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
  int       总_230_in_1E08 = 0;
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
  bool      g_nfpFromCalendar = false;      // true neu 总_391_da_5DFC_si300[] dang lay tu Lich MQL5 (khong con dung mang hardcode)
  datetime  g_nfpCalendarBuiltDay = 0;      // ngay (00:00, GMT) lan gan nhat da thu lam moi tu Lich MQL5
  int       g_nfpStatus = 0;                // trang thai lay tin NFP cho panel: 0 = binh thuong (dung 总_391_da_5DFC_si300[]), 2 = loi lay tin (Lich MQL5 khong doc duoc). mq5 dung Lich (khong co link) nen khong co trang thai thieu link (=1)
  long      g_onlyUpRunId = 0;              // ma rieng cho moi lan chay Strategy Tester, dung de tach biet dinh OnlyUp giua cac lan backtest (xem OnlyUpPeakGVName)

//+------------------------------------------------------------------+
//| Lay ngay NFP (Non-Farm Payrolls) tu Lich kinh te (Economic       |
//| Calendar) co san cua MQL5, thay cho mang 总_391_da_5DFC_si300[]   |
//| ma hoa cung. Neu khong tim/lay duoc (vi du: khong kha dung trong |
//| Strategy Tester cua broker nay) thi GIU NGUYEN mang hardcode co  |
//| san de kiem thu nguoc (backtest) van chay binh thuong.           |
//+------------------------------------------------------------------+
 void BuildNFPDatesFromCalendar()
 {
  g_nfpCalendarBuiltDay = (datetime)(TimeCurrent() - TimeCurrent() % 86400) ;
  MqlCalendarEvent 临_events[];
  int       临_evTotal = CalendarEventByCountry("US",临_events) ;
  long      临_nfpId = -1;
  int       临_i;
  string    临_code;
//----- -----
 if ( 临_evTotal <= 0 )   { g_nfpStatus = 2 ; return; } // Lich MQL5 khong doc duoc -> panel bao loi lay tin
 for (临_i = 0 ; 临_i < 临_evTotal ; 临_i ++)
 {
   // MqlCalendarEvent.name tra ve theo NGON NGU CUA TERMINAL (tai lieu MQL5)
   // nen so sanh chuoi tieng Anh co the khong bao gio khop neu terminal dat
   // ngon ngu khac. event_code moi la ma dinh danh CO DINH, khong phu thuoc
   // ngon ngu (vi du "NONFARM-PAYROLLS") - dung field nay lam chinh, giu lai
   // kiem tra .name nhu du phong.
   临_code = 临_events[临_i].event_code ;
   StringToUpper(临_code) ;
   if ( StringFind(临_code,"NONFARM") >= 0 || StringFind(临_events[临_i].name,"Nonfarm Payrolls") >= 0 || StringFind(临_events[临_i].name,"Non-Farm Payrolls") >= 0 || StringFind(临_events[临_i].name,"Non Farm Payrolls") >= 0 )
   {
     临_nfpId = (long)临_events[临_i].id ;
     break;
   }
 }
 if ( 临_nfpId < 0 )   { g_nfpStatus = 2 ; return; } // khong tim thay su kien NFP trong Lich -> loi lay tin
 MqlCalendarValue 临_values[];
 datetime  临_from = D'2007.01.01 00:00';
 datetime  临_to = TimeCurrent() + 400 * 24 * 60 * 60 ;
 int       临_n = CalendarValueHistoryByEvent((ulong)临_nfpId,临_values,临_from,临_to) ;
 if ( 临_n <= 0 )   { g_nfpStatus = 2 ; return; } // khong lay duoc gia tri lich NFP -> loi lay tin
 // 总_390_da_5DC0 (GMT hien tai) da duoc tinh xong truoc khi ham nay duoc goi (xem
 // OnTick). MqlCalendarValue.time tra ve theo GIO SERVER, trong khi
 // 总_391_da_5DFC_si300[] va toan bo bo loc NFP con lai dang quy uoc luu GIO GMT roi
 // moi cong offset de quy doi sang gio server luc so sanh/hien thi. TimeCurrent()-
 // 总_390_da_5DC0 chinh la offset GMT bo loc dang dung tai thoi diem nay (du la tu
 // AutoGMT/WebRequest thanh cong hay phai roi ve TimeGMT()), nen dung gia tri nay de
 // tru truoc khi luu, tranh bi quy doi 2 lan.
 long      临_offsetSeconds = (long)(TimeCurrent() - 总_390_da_5DC0) ;
 int       临_count = 0;
 for (临_i = 0 ; 临_i < 临_n && 临_count < 300 ; 临_i ++)
 {
   if ( 临_values[临_i].time <= 0 )   continue;
   总_391_da_5DFC_si300[临_count] = (datetime)(临_values[临_i].time - 临_offsetSeconds) ;
   临_count ++;
 }
 if ( 临_count <= 0 )   { g_nfpStatus = 0 ; return; } // lay tin OK nhung khong co ngay hop le -> "No News Coming Up"
 for (临_i = 临_count ; 临_i < 300 ; 临_i ++)   总_391_da_5DFC_si300[临_i] = 0 ;
 g_nfpFromCalendar = true ;
 g_nfpStatus = 0 ; // lay Lich thanh cong -> panel hien binh thuong (Next NFP / No News)
 }
//BuildNFPDatesFromCalendar <<==--------   --------

 int OnInit()
 {
g_startLots_rw=StartLots;
  double    子_2_do;
  double    子_3_do;
  int       子_4_in;
  int       子_5_in;
  int       子_6_in;
  int       子_7_in;
  int       子_8_in;
  int       子_9_in;
//----- -----
 // MQL4 tu dong khoi tao bool local ve false; MQL5 thi khong, nen phai gan
 // ro rang de giu dung hanh vi ban goc (bien nay khong duoc gan truoc khi
 // dung o duoi, IsDemo() ket qua bi bo qua trong ca ban mq4 goc).
 bool       临_bo_1 = false;

 // Sinh ma rieng cho lan chay Strategy Tester nay (xem OnlyUpPeakGVName) -
 // GetTickCount() (mili-giay tu luc terminal khoi dong) + so ngau nhien de
 // moi lan backtest deu co ma khac nhau, tranh trung khi nhieu agent toi uu
 // hoa chay song song va bat dau o cung mot thoi diem. MathRand() bat buoc
 // phai MathSrand() truoc thi moi cho ra chuoi so khac nhau giua cac lan
 // chay (theo tai lieu MQL5) - neu khong se luon ra cung 1 gia tri co dinh
 // moi lan khoi dong, lam mat tac dung chong trung.
 // SetFontSize >0: ghi de co chu panel (0 = co mac dinh theo thiet ke goc)
 if ( SetFontSize > 0 )   总_372_in_5CFC = SetFontSize ;
 MathSrand((int)GetTickCount()) ;
 g_onlyUpRunId = (long)GetTickCount() * 1000 + MathRand() ;

 总_401_do_6AD0 = AccountInfoDouble(ACCOUNT_BALANCE) ;
 if ( UseEquity )
 {
   总_401_do_6AD0 = AccountInfoDouble(ACCOUNT_EQUITY) ;
 }
 if ( ManualBalance>0.0 )
 {
   总_401_do_6AD0 = ManualBalance ;
 }
 // OnlyUp cai tien: doc lai muc so du cao nhat da luu trong GlobalVariable
 // cua terminal (ton tai xuyen suot restart EA/MT5), thay vi luon reset ve
 // so du hien tai moi lan khoi dong nhu truoc - tranh mat muc dinh cao da
 // dat duoc truoc do.
 // ResetHighestBalance: xoa dinh OnlyUp da luu, bat dau lai tu balance hien tai
 if ( ResetHighestBalance )   GlobalVariableDel(OnlyUpPeakGVName()) ;
 if ( OnlyUp && GlobalVariableCheck(OnlyUpPeakGVName()) )
 {
   总_402_do_6AD8 = GlobalVariableGet(OnlyUpPeakGVName()) ;
   if ( 总_401_do_6AD0>总_402_do_6AD8 )   总_402_do_6AD8 = 总_401_do_6AD0 ;
 }
 else
 {
   总_402_do_6AD8 = 总_401_do_6AD0 ;
 }
 // Chi ghi GlobalVariable khi OnlyUp dang bat - 2 diem ghi con lai (OnTick,
 // lizong_10) da lam dung dieu nay, sua lai cho khop de khong tao GlobalVariable
 // vo ich khi tinh nang OnlyUp dang tat.
 if ( OnlyUp )   GlobalVariableSet(OnlyUpPeakGVName(),总_402_do_6AD8) ;
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
 总_391_da_5DFC_si300[10] = D'2026.02.11 12:30';
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
 // UseMQL5Calendar=true: CHI dung Lich MQL5 lam nguon ngay NFP - xoa sach
 // mang ngay co san vua gan o tren, de khi Lich chua tai duoc/khong co du
 // lieu thi KHONG roi ve mang cu (panel se hien "no news coming up" va bo
 // loc NFP khong co ngay nao cho den khi Lich tra du lieu). Rieng trong
 // Strategy Tester van giu mang co san bat ke cong tac, vi Lich MQL5 khong
 // hoat dong trong tester (gioi han cua nen tang) - giong hanh vi v4.3.
 if ( UseMQL5Calendar && MQLInfoInteger(MQL_TESTER) != 1 )
 {
   for (子_4_in = 0 ; 子_4_in < 300 ; 子_4_in ++)   总_391_da_5DFC_si300[子_4_in] = 0 ;
 }
 if ( Risk == 1234 )
 {
   g_startLots_rw = MarketInfo(总_336_st_3130,MODE_MINLOT) ;
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
 总_337_do_3140 = SymbolInfoDouble(总_336_st_3130,16) ;
 总_229_do_1E00 = 总_337_do_3140 ;
 if ( ( MarketInfo(总_336_st_3130,MODE_DIGITS)==3.0 || MarketInfo(总_336_st_3130,MODE_DIGITS)==5.0 ) )
 {
   总_229_do_1E00 = 总_337_do_3140 * 10.0 ;
 }
 if ( SymbolInfoInteger(总_336_st_3130,17) == 0x1 )
 {
   总_229_do_1E00 = 总_337_do_3140 / 10.0 ;
 }
 总_190_in_518 = (int)MarketInfo(总_336_st_3130,MODE_DIGITS) ;
 if ( FridayStopHour <  0 )
 {
   总_45_bo_FC = false ;
 }
 else
 {
   总_45_bo_FC = true ;
 }
 总_251_do_2520 = (double)TimeCurrent() ;
 总_1_do_0 = MarketInfo(总_336_st_3130,MODE_ASK) - MarketInfo(总_336_st_3130,MODE_BID) ;
 总_223_do_1AC4_si99[总_328_in_3100] = NormalizeDouble(MathFloor(g_startLots_rw * 100.0) / 100.0,2);
 if ( MarketInfo(总_336_st_3130,MODE_LOTSTEP)==0.1 )
 {
   总_223_do_1AC4_si99[总_328_in_3100] = NormalizeDouble((MathFloor(g_startLots_rw * 10.0)) / 10.0,1);
   if ( 总_223_do_1AC4_si99[总_328_in_3100]<0.1 )
   {
     总_223_do_1AC4_si99[总_328_in_3100] = 0.1;
   }
 }
 if ( 总_223_do_1AC4_si99[总_328_in_3100]<MarketInfo(总_336_st_3130,MODE_MINLOT) )
 {
   总_223_do_1AC4_si99[总_328_in_3100] = MarketInfo(总_336_st_3130,MODE_MINLOT);
 }
 if ( 总_223_do_1AC4_si99[总_328_in_3100]>MarketInfo(总_336_st_3130,MODE_MAXLOT) )
 {
   总_223_do_1AC4_si99[总_328_in_3100] = MarketInfo(总_336_st_3130,MODE_MAXLOT);
 }
 总_306_in_2884 = iBars(总_336_st_3130,MT4Period(PERIOD_CURRENT)) ;
 if ( 总_131_do_328 * 总_229_do_1E00<总_337_do_3140 )
 {
   总_131_do_328 = 总_337_do_3140 / 总_229_do_1E00 ;
 }
 总_307_do_2888 = AccountBalance() ;
 总_221_do_1A80 = MarketInfo(总_336_st_3130,MODE_STOPLEVEL) * 总_337_do_3140 ;
 总_309_do_2898 = MarketInfo(总_336_st_3130,MODE_FREEZELEVEL) * 总_337_do_3140 ;
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
 if ( !(总_380_bo_5D90) )
 {
   Print("Initialisation of pairs failed!"); 
 }
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
 总_260_do_2570 = Seconds() ;
 总_319_da_28E0 = TimeCurrent() ;
 总_194_bo_530 = false ;
 总_195_bo_531 = false ;
 总_258_in_2568 = Month() ;
 总_313_da_28B8 = iTime(总_336_st_3130,MT4Period(PERIOD_W1),1) ;
 总_314_da_28C0 = iTime(总_336_st_3130,MT4Period(PERIOD_M1),1) ;
 总_315_da_28C8 = iTime(总_336_st_3130,MT4Period(PERIOD_M1),1) ;
 if ( 总_37_do_B8>MaxSpread )
 {
   总_37_do_B8 = MaxSpread ;
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
 总_309_do_2898 = MarketInfo(总_336_st_3130,MODE_FREEZELEVEL) * 总_337_do_3140 ;
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
 if ( 总_141_do_3F8>MarketInfo(总_336_st_3130,MODE_MAXLOT) )
 {
   总_141_do_3F8 = MarketInfo(总_336_st_3130,MODE_MAXLOT) ;
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
 总_272_do_25C8 = iFractals(总_336_st_3130,0,1,1) ;
 总_273_do_25D0 = iFractals(总_336_st_3130,0,2,1) ;
 总_270_do_25B8 = 总_272_do_25C8 ;
 总_271_do_25C0 = 总_273_do_25D0 ;
 总_275_do_25E0 = 0.0 ;
 总_231_bo_1E0C = false ;
 总_290_in_262C = Hour() ;
 总_289_in_2628 = 0 ;
 总_252_st_2528=ST1_Comment + "B1";
 总_253_st_2538=ST1_Comment + "B2";
 总_254_st_2548=ST1_Comment + "S1";
 总_255_st_2558=ST1_Comment + "S2";
 总_297_in_2848 = 0 ;
 总_298_in_284C = 0 ;
 总_267_in_25A0 = Hour() ;
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
   总_215_da_174C_si99[子_9_in] = iTime(总_336_st_3130,MT4Period(总_71_in_174),1);
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
 总_190_in_518 = (int)MarketInfo(总_336_st_3130,MODE_DIGITS) ;
 总_312_bo_28B0 = false ;
 IsDemo(); 

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

 总_401_do_6AD0 = AccountInfoDouble(ACCOUNT_BALANCE) ;
 if ( UseEquity )
 {
   总_401_do_6AD0 = AccountInfoDouble(ACCOUNT_EQUITY) ;
 }
 if ( ManualBalance>0.0 )
 {
   总_401_do_6AD0 = ManualBalance ;
 }
 if ( OnlyUp && 总_402_do_6AD8>总_401_do_6AD0 )
 {
   总_401_do_6AD0 = 总_402_do_6AD8 ;
 }
 if ( 总_401_do_6AD0>总_402_do_6AD8 )
 {
   总_402_do_6AD8 = 总_401_do_6AD0 ;
   if ( OnlyUp )   GlobalVariableSet(OnlyUpPeakGVName(),总_402_do_6AD8) ;
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
 TimeToStruct(StringToTime(string(TimeYear(TimeCurrent())) + ".03.31 01:00"),子_5_a_129); 
 TimeToStruct(StringToTime(string(TimeYear(TimeCurrent())) + ".10.31 02:00"),子_6_a_129); 
 if ( TimeDayOfYear(TimeCurrent()) >  TimeDayOfYear(StringToTime(string(TimeYear(TimeCurrent())) + ".03.31 01:00") - 子_5_a_129.day_of_week * 86400) && TimeDayOfYear(TimeCurrent()) <  TimeDayOfYear(StringToTime(string(TimeYear(TimeCurrent())) + ".10.31 02:00") - 子_6_a_129.day_of_week * 86400) )
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
 // Lich MQL5 khong kha dung/dang tin cay trong Strategy Tester (backtest) nen chi
 // lam moi tu Lich MQL5 khi dang chay live/demo that; kiem thu nguoc luon dung mang
 // 总_391_da_5DFC_si300[] ma hoa cung ben tren (da cap nhat toi het nam 2026) de dam
 // bao ket qua backtest 100% xac dinh, lap lai duoc.
 if ( EnableNFP_Filter && UseMQL5Calendar && MQLInfoInteger(MQL_TESTER) != 1 && TimeCurrent() - TimeCurrent() % 86400 > g_nfpCalendarBuiltDay )
 {
   BuildNFPDatesFromCalendar();
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
 if ( iBars(总_336_st_3130,MT4Period(PERIOD_D1)) != 总_383_in_5D9C )
 {
   总_383_in_5D9C = iBars(总_336_st_3130,MT4Period(PERIOD_D1)) ;
   总_382_bo_5D98 = false ;
   总_384_do_5DA0 = 0.0 ;
 }
 if ( PropFirmMaxDailyDD>0.0 )
 {
   lizong_46(); 
 }
 if ( 总_382_bo_5D98 || !(总_380_bo_5D90) )   return;
 子_4_bo = false ;
 if ( 总_399_da_6778 != iTime(总_336_st_3130,MT4Period(PERIOD_H1),1) )
 {
   子_4_bo = true ;
   总_399_da_6778 = iTime(总_336_st_3130,MT4Period(PERIOD_H1),1) ;
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
         for (临_in_4 = HistoryTotal() ; 临_in_4 >= 0 ; 临_in_4=临_in_4 - 1)
         {
           if ( OrderSelect(临_in_4,0,1) != true || OrderSymbol() != 总_336_st_3130 || OrderMagicNumber() != 总_93_in_1F0 )   continue;
           
           if ( ( OrderType() != 0 && OrderType() != 1 ) )   continue;
           总_343_in_372C_si99[总_328_in_3100] ++;
           临_do_3 = 临_do_3 + OrderProfit() + OrderSwap() + OrderCommission();
           
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
         for (临_in_7 = HistoryTotal() ; 临_in_7 >= 0 ; 临_in_7=临_in_7 - 1)
         {
           if ( OrderSelect(临_in_7,0,1) != true || OrderSymbol() != 总_336_st_3130 || OrderMagicNumber() != 总_93_in_1F0 )   continue;
           
           if ( ( OrderType() != 0 && OrderType() != 1 ) )   continue;
           总_343_in_372C_si99[总_328_in_3100] ++;
           临_do_6 = 临_do_6 + OrderProfit() + OrderSwap() + OrderCommission();
           
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
         for (临_in_10 = HistoryTotal() ; 临_in_10 >= 0 ; 临_in_10=临_in_10 - 1)
         {
           if ( OrderSelect(临_in_10,0,1) != true || OrderSymbol() != 总_336_st_3130 || OrderMagicNumber() != 总_93_in_1F0 )   continue;
           
           if ( ( OrderType() != 0 && OrderType() != 1 ) )   continue;
           总_343_in_372C_si99[总_328_in_3100] ++;
           临_do_9 = 临_do_9 + OrderProfit() + OrderSwap() + OrderCommission();
           
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
         for (临_in_13 = HistoryTotal() ; 临_in_13 >= 0 ; 临_in_13=临_in_13 - 1)
         {
           if ( OrderSelect(临_in_13,0,1) != true || OrderSymbol() != 总_336_st_3130 || OrderMagicNumber() != 总_93_in_1F0 )   continue;
           
           if ( ( OrderType() != 0 && OrderType() != 1 ) )   continue;
           总_343_in_372C_si99[总_328_in_3100] ++;
           临_do_12 = 临_do_12 + OrderProfit() + OrderSwap() + OrderCommission();
           
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
         for (临_in_16 = HistoryTotal() ; 临_in_16 >= 0 ; 临_in_16=临_in_16 - 1)
         {
           if ( OrderSelect(临_in_16,0,1) != true || OrderSymbol() != 总_336_st_3130 || OrderMagicNumber() != 总_93_in_1F0 )   continue;
           
           if ( ( OrderType() != 0 && OrderType() != 1 ) )   continue;
           总_343_in_372C_si99[总_328_in_3100] ++;
           临_do_15 = 临_do_15 + OrderProfit() + OrderSwap() + OrderCommission();
           
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
         for (临_in_19 = HistoryTotal() ; 临_in_19 >= 0 ; 临_in_19=临_in_19 - 1)
         {
           if ( OrderSelect(临_in_19,0,1) != true || OrderSymbol() != 总_336_st_3130 || OrderMagicNumber() != 总_93_in_1F0 )   continue;
           
           if ( ( OrderType() != 0 && OrderType() != 1 ) )   continue;
           总_343_in_372C_si99[总_328_in_3100] ++;
           临_do_18 = 临_do_18 + OrderProfit() + OrderSwap() + OrderCommission();
           
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
         for (临_in_22 = HistoryTotal() ; 临_in_22 >= 0 ; 临_in_22=临_in_22 - 1)
         {
           if ( OrderSelect(临_in_22,0,1) != true || OrderSymbol() != 总_336_st_3130 || OrderMagicNumber() != 总_93_in_1F0 )   continue;
           
           if ( ( OrderType() != 0 && OrderType() != 1 ) )   continue;
           总_343_in_372C_si99[总_328_in_3100] ++;
           临_do_21 = 临_do_21 + OrderProfit() + OrderSwap() + OrderCommission();
           
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
         for (临_in_25 = HistoryTotal() ; 临_in_25 >= 0 ; 临_in_25=临_in_25 - 1)
         {
           if ( OrderSelect(临_in_25,0,1) != true || OrderSymbol() != 总_336_st_3130 || OrderMagicNumber() != 总_93_in_1F0 )   continue;
           
           if ( ( OrderType() != 0 && OrderType() != 1 ) )   continue;
           总_343_in_372C_si99[总_328_in_3100] ++;
           临_do_24 = 临_do_24 + OrderProfit() + OrderSwap() + OrderCommission();
           
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
         for (临_in_28 = HistoryTotal() ; 临_in_28 >= 0 ; 临_in_28=临_in_28 - 1)
         {
           if ( OrderSelect(临_in_28,0,1) != true || OrderSymbol() != 总_336_st_3130 || OrderMagicNumber() != 总_93_in_1F0 )   continue;
           
           if ( ( OrderType() != 0 && OrderType() != 1 ) )   continue;
           总_343_in_372C_si99[总_328_in_3100] ++;
           临_do_27 = 临_do_27 + OrderProfit() + OrderSwap() + OrderCommission();
           
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
 if ( 总_381_in_5D94 < 2 )   return;
 总_318_do_28D8 = AccountBalance() ;
 总_381_in_5D94 = 0 ;
 }
//OnTick <<==--------   --------
 void OnDeinit(const int reason)
 {
 lizong_26(); 
 }
//deinit <<==--------   --------
 void lizong_6( int 木_0_in)
 {
 总_328_in_3100 = 木_0_in ;
 总_337_do_3140 = SymbolInfoDouble(总_336_st_3130,16) ;
 总_229_do_1E00 = 总_337_do_3140 ;
 if ( ( MarketInfo(总_336_st_3130,MODE_DIGITS)==3.0 || MarketInfo(总_336_st_3130,MODE_DIGITS)==5.0 ) )
 {
   总_229_do_1E00 = 总_337_do_3140 * 10.0 ;
 }
 if ( SymbolInfoInteger(总_336_st_3130,17) == 0x1 )
 {
   总_229_do_1E00 = 总_337_do_3140 / 10.0 ;
 }
 总_190_in_518 = (int)MarketInfo(总_336_st_3130,MODE_DIGITS) ;
 总_1_do_0 = MarketInfo(总_336_st_3130,MODE_ASK) - MarketInfo(总_336_st_3130,MODE_BID) ;
 总_221_do_1A80 = MarketInfo(总_336_st_3130,MODE_STOPLEVEL) * 总_337_do_3140 ;
 总_309_do_2898 = MarketInfo(总_336_st_3130,MODE_FREEZELEVEL) * 总_337_do_3140 ;
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
 总_9_do_60 = 1.0 ;
 if ( !(UseVariableValues) )   return;
 
 if ( 总_7_do_50>0.0 )
 {
   总_8_do_58 = iOpen(总_336_st_3130,MT4Period(PERIOD_D1),1) / 总_7_do_50 ;
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
 总_80_do_198 = 总_80_do_198 * 总_8_do_58 ;
 总_83_do_1B0 = NormalizeDouble(总_83_do_1B0 * 总_8_do_58,0) ;
 总_84_do_1B8 = NormalizeDouble(总_84_do_1B8 * 总_8_do_58,0) ;
 总_100_do_230 = 总_100_do_230 * 总_8_do_58 ;
 总_101_do_238 = 总_101_do_238 * 总_8_do_58 ;
 总_103_do_250 = 总_103_do_250 * 总_8_do_58 ;
 总_104_do_258 = 总_104_do_258 * 总_8_do_58 ;
 总_105_do_260 = 总_105_do_260 * 总_8_do_58 ;
 总_108_do_278 = 总_108_do_278 * 总_8_do_58 ;
 总_109_do_280 = 总_109_do_280 * 总_8_do_58 ;
 总_113_do_2A8 = 总_113_do_2A8 * 总_8_do_58 ;
 总_114_do_2B0 = 总_114_do_2B0 * 总_8_do_58 ;
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
 int        临_in_115;
 int        临_in_116;
 int        临_in_117;
 int        临_in_118;

 总_328_in_3100 = 木_0_in ;
 子_2_bo = false ;
 
 if ( 总_81_do_1A0>0.0 )
 {
   总_80_do_198 = 总_81_do_1A0 / 100.0 * MarketInfo(总_336_st_3130,MODE_ASK) * 10.0 ;
 }
 if ( 总_99_in_22C == 0 )
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
 else
 {
   if ( 总_321_in_2920_si99[总_328_in_3100] != iBars(总_336_st_3130,MT4Period(总_99_in_22C)) )
   {
     总_321_in_2920_si99[总_328_in_3100] = iBars(总_336_st_3130,MT4Period(总_99_in_22C));
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
 if ( !(IsTesting()) && MarketInfo(总_336_st_3130,MODE_TRADEALLOWED)==0.0 )
 {
   if ( !(总_256_bo_2564) )
   {
     Print("Market closed... waiting to continue"); 
   }
   总_256_bo_2564 = true ;
   return(0); 
 }
 if ( 总_68_in_15C >  0 && ( ( Hour() == 0 && Minute() < 总_68_in_15C ) || (Hour() == 23 && 总_68_in_15C >  60 - 总_68_in_15C) ) )
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
     Print("ENTERING NON-TRADING HOURS! Closing orders..."); 
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
       for (临_in_4 = MT4OrdersTotal() ; 临_in_4 >= 0 ; 临_in_4=临_in_4 - 1)
       {
         if ( OrderSelect(临_in_4,0,0) != true || OrderMagicNumber() != 总_93_in_1F0 || OrderSymbol() != 总_336_st_3130 )   continue;
         
         if ( ( OrderType() != 4 && OrderType() != 5 ) )   continue;
         Print("Storing pending order nr " + string(OrderTicket())); 
         总_197_do_6DC_si100si3[临_in_3][1] = OrderType();
         总_197_do_6DC_si100si3[临_in_3][0] = OrderOpenPrice();
         总_197_do_6DC_si100si3[临_in_3][2] = OrderLots();
         临_in_3=临_in_3 + 1;
         
       }
     }
     临_in_5 = 1;
     for (临_in_6 = MT4OrdersTotal() ; 临_in_6 >= 0 ; 临_in_6=临_in_6 - 1)
     {
       if ( OrderSelect(临_in_6,0,0) != true || OrderMagicNumber() != 总_93_in_1F0 || OrderSymbol() != 总_336_st_3130 || OrderType() != 4 )   continue;
       OrderDelete(OrderTicket(),0xFFFFFFFF); 
       
     }
     if ( 临_in_5 == 2 )
     {
       for (临_in_7 = MT4OrdersTotal() ; 临_in_7 >= 0 ; 临_in_7=临_in_7 - 1)
       {
         if ( OrderSelect(临_in_7,0,0) != true || OrderMagicNumber() != 总_96_in_208 || OrderSymbol() != 总_336_st_3130 || OrderType() != 4 )   continue;
         OrderDelete(OrderTicket(),0xFFFFFFFF); 
         
       }
     }
     临_in_8 = 1;
     for (临_in_9 = MT4OrdersTotal() ; 临_in_9 >= 0 ; 临_in_9=临_in_9 - 1)
     {
       if ( OrderSelect(临_in_9,0,0) != true || OrderMagicNumber() != 总_93_in_1F0 || OrderSymbol() != 总_336_st_3130 || OrderType() != 5 )   continue;
       OrderDelete(OrderTicket(),0xFFFFFFFF); 
       
     }
     if ( 临_in_8 == 2 )
     {
       for (临_in_10 = MT4OrdersTotal() ; 临_in_10 >= 0 ; 临_in_10=临_in_10 - 1)
       {
         if ( OrderSelect(临_in_10,0,0) != true || OrderMagicNumber() != 总_96_in_208 || OrderSymbol() != 总_336_st_3130 || OrderType() != 5 )   continue;
         OrderDelete(OrderTicket(),0xFFFFFFFF); 
         
       }
     }
     临_in_11 = 2;
     if(1==0) //条件不成立
     {
       do
       {
         if ( OrderSelect(1,0,0) != true || OrderMagicNumber() != 总_93_in_1F0 || OrderSymbol() != 总_336_st_3130 || OrderType() != 4 )   continue;
         OrderDelete(OrderTicket(),0xFFFFFFFF); 
         
       }
       while( - 1 >= 0);
       
     }
     if ( 临_in_11 == 2 )
     {
       for (临_in_12 = MT4OrdersTotal() ; 临_in_12 >= 0 ; 临_in_12=临_in_12 - 1)
       {
         if ( OrderSelect(临_in_12,0,0) != true || OrderMagicNumber() != 总_96_in_208 || OrderSymbol() != 总_336_st_3130 || OrderType() != 4 )   continue;
         OrderDelete(OrderTicket(),0xFFFFFFFF); 
         
       }
     }
     临_in_13 = 2;
     if(1==0) //条件不成立
     {
       do
       {
         if ( OrderSelect(1,0,0) != true || OrderMagicNumber() != 总_93_in_1F0 || OrderSymbol() != 总_336_st_3130 || OrderType() != 5 )   continue;
         OrderDelete(OrderTicket(),0xFFFFFFFF); 
         
       }
       while( - 1 >= 0);
       
     }
     if ( 临_in_13 == 2 )
     {
       for (临_in_14 = MT4OrdersTotal() ; 临_in_14 >= 0 ; 临_in_14=临_in_14 - 1)
       {
         if ( OrderSelect(临_in_14,0,0) != true || OrderMagicNumber() != 总_96_in_208 || OrderSymbol() != 总_336_st_3130 || OrderType() != 5 )   continue;
         OrderDelete(OrderTicket(),0xFFFFFFFF); 
         
       }
     }
     总_303_bo_2878 = true ;
     return(0); 
   }
 }
 if ( EnableNFP_Filter )
 {
   if ( Year() <= 2026 || g_nfpFromCalendar )
   {
     子_3_lo = 0 ;
     for (子_4_in = 0 ; 子_4_in < 300 ; 子_4_in ++)
     {
       临_in_15 = TimeYear(总_391_da_5DFC_si300[子_4_in]);
       if ( 临_in_15 != Year() )   continue;
       临_in_16 = TimeMonth(总_391_da_5DFC_si300[子_4_in]);
       if ( 临_in_16 != Month() )   continue;
       子_3_lo = 总_391_da_5DFC_si300[子_4_in] ;
       break;
       
     }
     子_5_in = 60 ;
     if ( lizong_48() )
     {
       子_5_in = 0 ;
     }
     if ( 总_390_da_5DC0 >= 子_3_lo - NFP_MinutesBefore * 60 + 子_5_in * 60 && 总_390_da_5DC0 <= 子_3_lo + NFP_MinutesAfter * 60 + 子_5_in * 60 )
     {
       if ( NFP_ClosePendingOrders )
       {
         临_in_17 = 1;
         for (临_in_18 = MT4OrdersTotal() ; 临_in_18 >= 0 ; 临_in_18=临_in_18 - 1)
         {
           if ( OrderSelect(临_in_18,0,0) != true || OrderMagicNumber() != 总_93_in_1F0 || OrderSymbol() != 总_336_st_3130 || OrderType() != 4 )   continue;
           OrderDelete(OrderTicket(),0xFFFFFFFF); 
           
         }
         if ( 临_in_17 == 2 )
         {
           for (临_in_19 = MT4OrdersTotal() ; 临_in_19 >= 0 ; 临_in_19=临_in_19 - 1)
           {
             if ( OrderSelect(临_in_19,0,0) != true || OrderMagicNumber() != 总_96_in_208 || OrderSymbol() != 总_336_st_3130 || OrderType() != 4 )   continue;
             OrderDelete(OrderTicket(),0xFFFFFFFF); 
             
           }
         }
         临_in_20 = 1;
         for (临_in_21 = MT4OrdersTotal() ; 临_in_21 >= 0 ; 临_in_21=临_in_21 - 1)
         {
           if ( OrderSelect(临_in_21,0,0) != true || OrderMagicNumber() != 总_93_in_1F0 || OrderSymbol() != 总_336_st_3130 || OrderType() != 5 )   continue;
           OrderDelete(OrderTicket(),0xFFFFFFFF); 
           
         }
         if ( 临_in_20 == 2 )
         {
           for (临_in_22 = MT4OrdersTotal() ; 临_in_22 >= 0 ; 临_in_22=临_in_22 - 1)
           {
             if ( OrderSelect(临_in_22,0,0) != true || OrderMagicNumber() != 总_96_in_208 || OrderSymbol() != 总_336_st_3130 || OrderType() != 5 )   continue;
             OrderDelete(OrderTicket(),0xFFFFFFFF); 
             
           }
         }
         临_in_23 = 2;
         if(1==0) //条件不成立
         {
           do
           {
             if ( OrderSelect(1,0,0) != true || OrderMagicNumber() != 总_93_in_1F0 || OrderSymbol() != 总_336_st_3130 || OrderType() != 4 )   continue;
             OrderDelete(OrderTicket(),0xFFFFFFFF); 
             
           }
           while( - 1 >= 0);
           
         }
         if ( 临_in_23 == 2 )
         {
           for (临_in_24 = MT4OrdersTotal() ; 临_in_24 >= 0 ; 临_in_24=临_in_24 - 1)
           {
             if ( OrderSelect(临_in_24,0,0) != true || OrderMagicNumber() != 总_96_in_208 || OrderSymbol() != 总_336_st_3130 || OrderType() != 4 )   continue;
             OrderDelete(OrderTicket(),0xFFFFFFFF); 
             
           }
         }
         临_in_25 = 2;
         if(1==0) //条件不成立
         {
           do
           {
             if ( OrderSelect(1,0,0) != true || OrderMagicNumber() != 总_93_in_1F0 || OrderSymbol() != 总_336_st_3130 || OrderType() != 5 )   continue;
             OrderDelete(OrderTicket(),0xFFFFFFFF); 
             
           }
           while( - 1 >= 0);
           
         }
         if ( 临_in_25 == 2 )
         {
           for (临_in_26 = MT4OrdersTotal() ; 临_in_26 >= 0 ; 临_in_26=临_in_26 - 1)
           {
             if ( OrderSelect(临_in_26,0,0) != true || OrderMagicNumber() != 总_96_in_208 || OrderSymbol() != 总_336_st_3130 || OrderType() != 5 )   continue;
             OrderDelete(OrderTicket(),0xFFFFFFFF); 
             
           }
         }
       }
       if ( NFP_CloseOpenTrades )
       {
         for (临_in_27 = MT4OrdersTotal() ; 临_in_27 >= 0 ; 临_in_27=临_in_27 - 1)
         {
           if ( OrderSelect(临_in_27,0,0) != true || OrderSymbol() != 总_336_st_3130 )   continue;
           临_in_28 = OrderMagicNumber();
           临_in_29=ST1_MagicNumber + 1;
           if ( 临_in_28 != 临_in_29 )
           {
             临_in_29 = OrderMagicNumber();
             临_in_30=ST1_MagicNumber + 2;
             if ( 临_in_29 != 临_in_30 )
             {
               临_in_30 = OrderMagicNumber();
               临_in_31=ST1_MagicNumber + 3;
               if ( 临_in_30 != 临_in_31 )
               {
                 临_in_31 = OrderMagicNumber();
                 临_in_32=ST1_MagicNumber + 4;
                 if ( 临_in_31 != 临_in_32 )
                 {
                   临_in_32 = OrderMagicNumber();
                   临_in_33=ST1_MagicNumber + 5;
                   if ( 临_in_32 != 临_in_33 )
                   {
                     临_in_33 = OrderMagicNumber();
                     临_in_34=ST1_MagicNumber + 6;
                     if ( 临_in_33 != 临_in_34 )
                     {
                       临_in_34 = OrderMagicNumber();
                       临_in_35=ST1_MagicNumber + 7;
                       if ( 临_in_34 != 临_in_35 )
                       {
                         临_in_35 = OrderMagicNumber();
                         临_in_36=ST1_MagicNumber + 8;
                         if ( 临_in_35 != 临_in_36 )
                         {
                           临_in_36 = OrderMagicNumber();
                           临_in_37=ST1_MagicNumber + 9;
                           if ( 临_in_36 != 临_in_37 )
                           {
                             临_in_37 = OrderMagicNumber();
                             临_in_38=ST1_MagicNumber + 10;
                             if ( 临_in_37 != 临_in_38 )
                             {
                               临_in_38 = OrderMagicNumber();
                               临_in_39=ST1_MagicNumber + 11;
                               if ( 临_in_38 != 临_in_39 )
                               {
                                 临_in_39 = OrderMagicNumber();
                                 临_in_40=ST1_MagicNumber + 12;
                                 if ( 临_in_39 != 临_in_40 )
                                 {
                                   临_in_40 = OrderMagicNumber();
                                   临_in_41=ST1_MagicNumber + 13;
                                   if ( 临_in_40 != 临_in_41 )
                                   {
                                     临_in_41 = OrderMagicNumber();
                                     临_in_42=ST1_MagicNumber + 14;
                                     if ( 临_in_41 != 临_in_42 )
                                     {
                                       临_in_42 = OrderMagicNumber();
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
           if ( OrderType() == 0 )
           {
             OrderClose(OrderTicket(),OrderLots(),MarketInfo(总_336_st_3130,MODE_BID),99999,Red); 
           }
           if ( OrderType() != 1 )   continue;
           OrderClose(OrderTicket(),OrderLots(),MarketInfo(总_336_st_3130,MODE_ASK),99999,Red); 
           
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
     if ( Day() <= 7 && DayOfWeek() == 5 )
     {
       子_6_st = IntegerToString(Year(),0,32) + IntegerToString(Month(),0,32) + IntegerToString(Day(),0,32) + " " + IntegerToString(0x4CE,0,32) ;
       子_7_da = StringToTime(子_6_st) ;
       if ( 总_390_da_5DC0 >= 子_7_da - NFP_MinutesBefore * 60 && 总_390_da_5DC0 <= 子_7_da + NFP_MinutesAfter * 60 )
       {
         if ( NFP_ClosePendingOrders )
         {
           临_in_44 = 1;
           for (临_in_45 = MT4OrdersTotal() ; 临_in_45 >= 0 ; 临_in_45=临_in_45 - 1)
           {
             if ( OrderSelect(临_in_45,0,0) != true || OrderMagicNumber() != 总_93_in_1F0 || OrderSymbol() != 总_336_st_3130 || OrderType() != 4 )   continue;
             OrderDelete(OrderTicket(),0xFFFFFFFF); 
             
           }
           if ( 临_in_44 == 2 )
           {
             for (临_in_46 = MT4OrdersTotal() ; 临_in_46 >= 0 ; 临_in_46=临_in_46 - 1)
             {
               if ( OrderSelect(临_in_46,0,0) != true || OrderMagicNumber() != 总_96_in_208 || OrderSymbol() != 总_336_st_3130 || OrderType() != 4 )   continue;
               OrderDelete(OrderTicket(),0xFFFFFFFF); 
               
             }
           }
           临_in_47 = 1;
           for (临_in_48 = MT4OrdersTotal() ; 临_in_48 >= 0 ; 临_in_48=临_in_48 - 1)
           {
             if ( OrderSelect(临_in_48,0,0) != true || OrderMagicNumber() != 总_93_in_1F0 || OrderSymbol() != 总_336_st_3130 || OrderType() != 5 )   continue;
             OrderDelete(OrderTicket(),0xFFFFFFFF); 
             
           }
           if ( 临_in_47 == 2 )
           {
             for (临_in_49 = MT4OrdersTotal() ; 临_in_49 >= 0 ; 临_in_49=临_in_49 - 1)
             {
               if ( OrderSelect(临_in_49,0,0) != true || OrderMagicNumber() != 总_96_in_208 || OrderSymbol() != 总_336_st_3130 || OrderType() != 5 )   continue;
               OrderDelete(OrderTicket(),0xFFFFFFFF); 
               
             }
           }
           临_in_50 = 2;
           if(1==0) //条件不成立
           {
             do
             {
               if ( OrderSelect(1,0,0) != true || OrderMagicNumber() != 总_93_in_1F0 || OrderSymbol() != 总_336_st_3130 || OrderType() != 4 )   continue;
               OrderDelete(OrderTicket(),0xFFFFFFFF); 
               
             }
             while( - 1 >= 0);
             
           }
           if ( 临_in_50 == 2 )
           {
             for (临_in_51 = MT4OrdersTotal() ; 临_in_51 >= 0 ; 临_in_51=临_in_51 - 1)
             {
               if ( OrderSelect(临_in_51,0,0) != true || OrderMagicNumber() != 总_96_in_208 || OrderSymbol() != 总_336_st_3130 || OrderType() != 4 )   continue;
               OrderDelete(OrderTicket(),0xFFFFFFFF); 
               
             }
           }
           临_in_52 = 2;
           if(1==0) //条件不成立
           {
             do
             {
               if ( OrderSelect(1,0,0) != true || OrderMagicNumber() != 总_93_in_1F0 || OrderSymbol() != 总_336_st_3130 || OrderType() != 5 )   continue;
               OrderDelete(OrderTicket(),0xFFFFFFFF); 
               
             }
             while( - 1 >= 0);
             
           }
           if ( 临_in_52 == 2 )
           {
             for (临_in_53 = MT4OrdersTotal() ; 临_in_53 >= 0 ; 临_in_53=临_in_53 - 1)
             {
               if ( OrderSelect(临_in_53,0,0) != true || OrderMagicNumber() != 总_96_in_208 || OrderSymbol() != 总_336_st_3130 || OrderType() != 5 )   continue;
               OrderDelete(OrderTicket(),0xFFFFFFFF); 
               
             }
           }
         }
         if ( NFP_CloseOpenTrades )
         {
           for (临_in_54 = MT4OrdersTotal() ; 临_in_54 >= 0 ; 临_in_54=临_in_54 - 1)
           {
             if ( OrderSelect(临_in_54,0,0) != true || OrderSymbol() != 总_336_st_3130 )   continue;
             临_in_55 = OrderMagicNumber();
             临_in_56=ST1_MagicNumber + 1;
             if ( 临_in_55 != 临_in_56 )
             {
               临_in_56 = OrderMagicNumber();
               临_in_57=ST1_MagicNumber + 2;
               if ( 临_in_56 != 临_in_57 )
               {
                 临_in_57 = OrderMagicNumber();
                 临_in_58=ST1_MagicNumber + 3;
                 if ( 临_in_57 != 临_in_58 )
                 {
                   临_in_58 = OrderMagicNumber();
                   临_in_59=ST1_MagicNumber + 4;
                   if ( 临_in_58 != 临_in_59 )
                   {
                     临_in_59 = OrderMagicNumber();
                     临_in_60=ST1_MagicNumber + 5;
                     if ( 临_in_59 != 临_in_60 )
                     {
                       临_in_60 = OrderMagicNumber();
                       临_in_61=ST1_MagicNumber + 6;
                       if ( 临_in_60 != 临_in_61 )
                       {
                         临_in_61 = OrderMagicNumber();
                         临_in_62=ST1_MagicNumber + 7;
                         if ( 临_in_61 != 临_in_62 )
                         {
                           临_in_62 = OrderMagicNumber();
                           临_in_63=ST1_MagicNumber + 8;
                           if ( 临_in_62 != 临_in_63 )
                           {
                             临_in_63 = OrderMagicNumber();
                             临_in_64=ST1_MagicNumber + 9;
                             if ( 临_in_63 != 临_in_64 )
                             {
                               临_in_64 = OrderMagicNumber();
                               临_in_65=ST1_MagicNumber + 10;
                               if ( 临_in_64 != 临_in_65 )
                               {
                                 临_in_65 = OrderMagicNumber();
                                 临_in_66=ST1_MagicNumber + 11;
                                 if ( 临_in_65 != 临_in_66 )
                                 {
                                   临_in_66 = OrderMagicNumber();
                                   临_in_67=ST1_MagicNumber + 12;
                                   if ( 临_in_66 != 临_in_67 )
                                   {
                                     临_in_67 = OrderMagicNumber();
                                     临_in_68=ST1_MagicNumber + 13;
                                     if ( 临_in_67 != 临_in_68 )
                                     {
                                       临_in_68 = OrderMagicNumber();
                                       临_in_69=ST1_MagicNumber + 14;
                                       if ( 临_in_68 != 临_in_69 )
                                       {
                                         临_in_69 = OrderMagicNumber();
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
             if ( OrderType() == 0 )
             {
               OrderClose(OrderTicket(),OrderLots(),MarketInfo(总_336_st_3130,MODE_BID),99999,Red); 
             }
             if ( OrderType() != 1 )   continue;
             OrderClose(OrderTicket(),OrderLots(),MarketInfo(总_336_st_3130,MODE_ASK),99999,Red); 
             
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
   if ( DayOfWeek() == 5 && Hour() >= FridayStopHour && !(总_305_bo_2880) )
   {
     for (临_in_71 = MT4OrdersTotal() ; 临_in_71 >= 0 ; 临_in_71=临_in_71 - 1)
     {
       if ( OrderSelect(临_in_71,0,0) != true || OrderSymbol() != 总_336_st_3130 )   continue;
       临_in_72 = OrderMagicNumber();
       临_in_73=ST1_MagicNumber + 1;
       if ( 临_in_72 != 临_in_73 )
       {
         临_in_73 = OrderMagicNumber();
         临_in_74=ST1_MagicNumber + 2;
         if ( 临_in_73 != 临_in_74 )
         {
           临_in_74 = OrderMagicNumber();
           临_in_75=ST1_MagicNumber + 3;
           if ( 临_in_74 != 临_in_75 )
           {
             临_in_75 = OrderMagicNumber();
             临_in_76=ST1_MagicNumber + 4;
             if ( 临_in_75 != 临_in_76 )
             {
               临_in_76 = OrderMagicNumber();
               临_in_77=ST1_MagicNumber + 5;
               if ( 临_in_76 != 临_in_77 )
               {
                 临_in_77 = OrderMagicNumber();
                 临_in_78=ST1_MagicNumber + 6;
                 if ( 临_in_77 != 临_in_78 )
                 {
                   临_in_78 = OrderMagicNumber();
                   临_in_79=ST1_MagicNumber + 7;
                   if ( 临_in_78 != 临_in_79 )
                   {
                     临_in_79 = OrderMagicNumber();
                     临_in_80=ST1_MagicNumber + 8;
                     if ( 临_in_79 != 临_in_80 )
                     {
                       临_in_80 = OrderMagicNumber();
                       临_in_81=ST1_MagicNumber + 9;
                       if ( 临_in_80 != 临_in_81 )
                       {
                         临_in_81 = OrderMagicNumber();
                         临_in_82=ST1_MagicNumber + 10;
                         if ( 临_in_81 != 临_in_82 )
                         {
                           临_in_82 = OrderMagicNumber();
                           临_in_83=ST1_MagicNumber + 11;
                           if ( 临_in_82 != 临_in_83 )
                           {
                             临_in_83 = OrderMagicNumber();
                             临_in_84=ST1_MagicNumber + 12;
                             if ( 临_in_83 != 临_in_84 )
                             {
                               临_in_84 = OrderMagicNumber();
                               临_in_85=ST1_MagicNumber + 13;
                               if ( 临_in_84 != 临_in_85 )
                               {
                                 临_in_85 = OrderMagicNumber();
                                 临_in_86=ST1_MagicNumber + 14;
                                 if ( 临_in_85 != 临_in_86 )
                                 {
                                   临_in_86 = OrderMagicNumber();
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
       if ( FridayCloseOpen && OrderType() == 0 )
       {
         OrderClose(OrderTicket(),OrderLots(),MarketInfo(总_336_st_3130,MODE_BID),(int)总_38_do_C0,Red); 
       }
       if ( FridayCloseOpen && OrderType() == 1 )
       {
         OrderClose(OrderTicket(),OrderLots(),MarketInfo(总_336_st_3130,MODE_ASK),(int)总_38_do_C0,Red); 
       }
       if ( ( OrderType() != 4 && OrderType() != 5 ) || !(FridayClosePending) )   continue;
       OrderDelete(OrderTicket(),Red); 
       
     }
     Print("Weekend starting! closing trades.."); 
     总_305_bo_2880 = true ;
     return(0); 
   }
   if ( DayOfWeek() != 5 && 总_305_bo_2880 == true )
   {
     总_305_bo_2880 = false ;
     if ( 总_46_bo_FD )
     {
       lizong_8(); 
       return(0); 
     }
   }
 }
 总_1_do_0 = MarketInfo(总_336_st_3130,MODE_ASK) - MarketInfo(总_336_st_3130,MODE_BID) ;
 if ( 总_35_bo_AF )
 {
   if ( 总_1_do_0>MaxSpread * 总_229_do_1E00 )
   {
     lizong_9(); 
     return(0); 
   }
   if ( 总_1_do_0<=总_37_do_B8 * 总_229_do_1E00 && ( !(总_45_bo_FC) || DayOfWeek() != 5 || Hour() <  FridayStopHour ) && ( !(总_171_bo_4BC) || lizong_20() ) )
   {
     lizong_8(); 
   }
 }
 if ( 总_69_in_160 == 1 )
 {
   临_in_88 = 0;
   for (临_in_89 = MT4OrdersTotal() ; 临_in_89 >= 0 ; 临_in_89=临_in_89 - 1)
   {
     if ( OrderSelect(临_in_89,0,0) != true || OrderMagicNumber() != 总_93_in_1F0 || OrderSymbol() != 总_336_st_3130 || OrderType() != 4 )   continue;
     临_in_88=临_in_88 + 1;
     
   }
   if ( 临_in_88 >  总_86_in_1C8 )
   {
     临_do_90 = 0.0;
     临_lo_91 = 0;
     for (临_in_92 = MT4OrdersTotal() ; 临_in_92 >= 0 ; 临_in_92=临_in_92 - 1)
     {
       if ( OrderSelect(临_in_92,0,0) != true || OrderMagicNumber() != 总_93_in_1F0 || OrderSymbol() != 总_336_st_3130 || OrderType() != 4 || !(OrderOpenPrice()>临_do_90) )   continue;
       临_lo_91 = OrderTicket();
       临_do_90 = OrderOpenPrice();
       
     }
     if ( 临_lo_91 != 0 )
     {
       OrderDelete(临_lo_91,Green); 
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
   for (临_in_96 = MT4OrdersTotal() ; 临_in_96 >= 0 ; 临_in_96=临_in_96 - 1)
   {
     if ( OrderSelect(临_in_96,0,0) != true || OrderMagicNumber() != 总_93_in_1F0 || OrderSymbol() != 总_336_st_3130 || OrderType() != 5 )   continue;
     临_in_95=临_in_95 + 1;
     
   }
   if ( 临_in_95 >  总_86_in_1C8 )
   {
     临_do_97 = 9999.0;
     临_lo_98 = 0;
     for (临_in_99 = MT4OrdersTotal() ; 临_in_99 >= 0 ; 临_in_99=临_in_99 - 1)
     {
       if ( OrderSelect(临_in_99,0,0) != true || OrderMagicNumber() != 总_93_in_1F0 || OrderSymbol() != 总_336_st_3130 || OrderType() != 5 || !(OrderOpenPrice()<临_do_97) )   continue;
       临_lo_98 = OrderTicket();
       临_do_97 = OrderOpenPrice();
       
     }
     if ( 临_lo_98 != 0 )
     {
       OrderDelete(临_lo_98,Green); 
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
   if ( ( 总_322_in_2AE0_si99[总_328_in_3100] != iBars(总_336_st_3130,MT4Period(总_72_in_178)) || 总_72_in_178 == 0 ) )
   {
     总_322_in_2AE0_si99[总_328_in_3100] = iBars(总_336_st_3130,MT4Period(总_72_in_178));
     if ( 总_119_in_2D0 >  0 && 总_120_in_2D4 >= 0 )
     {
       总_241_do_1E78_si99[总_328_in_3100] = 总_123_do_2E0 * 总_229_do_1E00 + (lizong_13(总_117_in_2C8,总_119_in_2D0,总_120_in_2D4) + 总_1_do_0);
       总_242_do_21C4_si99[总_328_in_3100] = lizong_14(总_117_in_2C8,总_119_in_2D0,总_120_in_2D4) - 总_123_do_2E0 * 总_229_do_1E00;
     }
     if ( 总_187_in_504 >  0 )
     {
       子_8_in=MathRand() * 总_187_in_504 / 32768 + 1;
       总_15_in_78 = 子_8_in ;
       Print("Slippage: " + (string(子_8_in))); 
     }
     if ( 总_63_in_140 != 1 )
     {
       临_in_102 = 0;
       for (临_in_103 = MT4OrdersTotal() ; 临_in_103 >= 0 ; 临_in_103=临_in_103 - 1)
       {
         if ( OrderSelect(临_in_103,0,0) != true || OrderMagicNumber() != 总_93_in_1F0 || OrderSymbol() != 总_336_st_3130 || OrderType() != 0 )   continue;
         临_in_102=临_in_102 + 1;
         
       }
       if ( 临_in_102 == 0 )
       {
         临_in_104 = 0;
         for (临_in_105 = MT4OrdersTotal() ; 临_in_105 >= 0 ; 临_in_105=临_in_105 - 1)
         {
           if ( OrderSelect(临_in_105,0,0) != true || OrderMagicNumber() != 总_93_in_1F0 || OrderSymbol() != 总_336_st_3130 || OrderType() != 1 )   continue;
           临_in_104=临_in_104 + 1;
           
         }
         if ( 临_in_104 == 0 )
         {
           临_bo_106 = false;
           for (临_in_107 = 0 ; 临_in_107 < 总_199_in_16B0 ; 临_in_107=临_in_107 + 1)
           {
             if ( !(总_196_do_568_si20si2[临_in_107][0]>0.0) )   continue;
             临_bo_106 = false;
             for (临_in_108 = MT4OrdersTotal() ; 临_in_108 >= 0 ; 临_in_108=临_in_108 - 1)
             {
               if ( OrderSelect(临_in_108,0,0) != true )   continue;
               
               if ( ( OrderType() != 0 && OrderType() != 1 ) || !(OrderTicket()==总_196_do_568_si20si2[临_in_107][0]) )   continue;
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
   if ( 总_267_in_25A0 != Hour() )
   {
     总_267_in_25A0 = Hour() ;
     临_bo_109 = false;
     for (临_in_110 = 0 ; 临_in_110 < 100 ; 临_in_110=临_in_110 + 1)
     {
       临_lo_111 = (long)总_198_do_1070_si100si2[临_in_110][0];
       临_bo_109 = false;
       for (临_in_112 = MT4OrdersTotal() ; 临_in_112 >= 0 ; 临_in_112=临_in_112 - 1)
       {
         if ( !(OrderSelect(临_in_112,0,0)) )   continue;
         临_lo_113 = OrderTicket();
         if ( 临_lo_111 != 临_lo_113 )   continue;
         临_bo_109 = true;
         
       }
       if ( 临_bo_109 )   continue;
       总_198_do_1070_si100si2[临_in_110][0] = 0.0;
       总_198_do_1070_si100si2[临_in_110][1] = 0.0;
       
     }
   }
 }
 if ( 总_62_bo_13D )
 {
   临_st_114="Current spread: " + string(NormalizeDouble(总_1_do_0 / 总_229_do_1E00,1)) + "\nPending Buy Order: ";
   临_in_115 = 0;
   for (临_in_116 = MT4OrdersTotal() ; 临_in_116 >= 0 ; 临_in_116=临_in_116 - 1)
   {
     if ( OrderSelect(临_in_116,0,0) != true || OrderMagicNumber() != 总_93_in_1F0 || OrderSymbol() != 总_336_st_3130 || OrderType() != 4 )   continue;
     临_in_115=临_in_115 + 1;
     
   }
   临_st_114=临_st_114 + string(临_in_115);
   临_st_114=临_st_114 + "\nPending Sell Orders: ";
   临_in_117 = 0;
   for (临_in_118 = MT4OrdersTotal() ; 临_in_118 >= 0 ; 临_in_118=临_in_118 - 1)
   {
     if ( OrderSelect(临_in_118,0,0) != true || OrderMagicNumber() != 总_93_in_1F0 || OrderSymbol() != 总_336_st_3130 || OrderType() != 5 )   continue;
     临_in_117=临_in_117 + 1;
     
   }
   临_st_114=临_st_114 + string(临_in_117);
   Comment(临_st_114); 
 }
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
   
   if ( 总_197_do_6DC_si100si3[子_1_in][1]==4.0 && MarketInfo(总_336_st_3130,MODE_ASK)<总_197_do_6DC_si100si3[子_1_in][0] - 总_221_do_1A80 )
   {
     Print("Restoring pending buy-order"); 
     总_230_in_1E08 = (int)OrderSend(总_336_st_3130,4,总_197_do_6DC_si100si3[子_1_in][2],总_197_do_6DC_si100si3[子_1_in][0],int(总_38_do_C0 * 总_229_do_1E00),总_197_do_6DC_si100si3[子_1_in][0] - (总_100_do_230 + 总_64_do_148) * 总_229_do_1E00,总_101_do_238 * 总_229_do_1E00 + 总_197_do_6DC_si100si3[子_1_in][0],总_334_st_3120,总_93_in_1F0,总_302_da_2870 + 0x2A300,Green) ;
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
       if ( MT4_LastError() == 132 )
       {
         ResetLastError();
         if(1==0) //条件不成立
         {
           do
           {
             Sleep(2500); 
             总_230_in_1E08 = (int)OrderSend(总_336_st_3130,4,总_197_do_6DC_si100si3[子_1_in][2],总_197_do_6DC_si100si3[子_1_in][0],int(总_38_do_C0 * 总_229_do_1E00),总_197_do_6DC_si100si3[子_1_in][0] - (总_100_do_230 + 总_64_do_148) * 总_229_do_1E00,总_101_do_238 * 总_229_do_1E00 + 总_197_do_6DC_si100si3[子_1_in][0],总_334_st_3120,总_93_in_1F0,总_302_da_2870 + 0x2A300,Green) ;
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
           while(MT4_LastError() == 132);
           
         }
       }
       Print("error: \'" + lizong_21(MT4_LastError()) + "\' when setting entry order"); 
     }
   }
   if ( !(总_197_do_6DC_si100si3[子_1_in][1]==5.0) || !(MarketInfo(总_336_st_3130,MODE_BID)>总_197_do_6DC_si100si3[子_1_in][0] + 总_221_do_1A80) )   continue;
   Print("Restoring pending sell-order"); 
   总_230_in_1E08 = (int)OrderSend(总_336_st_3130,5,总_197_do_6DC_si100si3[子_1_in][2],总_197_do_6DC_si100si3[子_1_in][0],int(总_38_do_C0 * 总_229_do_1E00),(总_100_do_230 + 总_64_do_148) * 总_229_do_1E00 + 总_197_do_6DC_si100si3[子_1_in][0],总_197_do_6DC_si100si3[子_1_in][0] - 总_101_do_238 * 总_229_do_1E00,总_334_st_3120,总_93_in_1F0,总_302_da_2870 + 0x2A300,Green) ;
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
   
   if ( MT4_LastError() == 132 )
   {
     ResetLastError();
     if(1==0) //条件不成立
     {
       do
       {
         Sleep(2500); 
         总_230_in_1E08 = (int)OrderSend(总_336_st_3130,5,总_197_do_6DC_si100si3[子_1_in][2],总_197_do_6DC_si100si3[子_1_in][0],int(总_38_do_C0 * 总_229_do_1E00),(总_100_do_230 + 总_64_do_148) * 总_229_do_1E00 + 总_197_do_6DC_si100si3[子_1_in][0],总_197_do_6DC_si100si3[子_1_in][0] - 总_101_do_238 * 总_229_do_1E00,总_334_st_3120,总_93_in_1F0,总_302_da_2870 + 0x2A300,Green) ;
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
       while(MT4_LastError() == 132);
       
     }
   }
   Print("error: \'" + lizong_21(MT4_LastError()) + "\' when setting entry order"); 
   
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

 for (子_2_in = MT4OrdersTotal() ; 子_2_in >= 0 ; 子_2_in --)
 {
   if ( OrderSelect(子_2_in,0,0) != true )   continue;
   
   if ( ( OrderMagicNumber() != 总_93_in_1F0 && OrderMagicNumber() != 总_96_in_208 ) || OrderSymbol() != 总_336_st_3130 )   continue;
   
   if ( OrderType() == 4 && OrderOpenPrice()<总_36_in_B0 * 总_229_do_1E00 + MarketInfo(总_336_st_3130,MODE_ASK) && MarketInfo(总_336_st_3130,MODE_ASK)<OrderOpenPrice() - 总_309_do_2898 )
   {
     if ( 总_37_do_B8>0.0 )
     {
       Print("Spread too high..(" + string(总_1_do_0) + ") storing and deleting order " + string(OrderTicket())); 
       for (子_3_in = 0 ; 子_3_in < 总_200_in_16B4 ; 子_3_in ++)
       {
         if ( 总_197_do_6DC_si100si3[子_3_in][0]==0.0 )
         {
           Print("Storing pending order nr " + string(OrderTicket())); 
           总_197_do_6DC_si100si3[子_3_in][1] = OrderType();
           总_197_do_6DC_si100si3[子_3_in][0] = OrderOpenPrice();
           总_197_do_6DC_si100si3[子_3_in][2] = OrderLots();
           break;
         }
       }
       临_lo_1 = OrderTicket();
       for (临_in_2 = 0 ; 临_in_2 < 100 ; 临_in_2=临_in_2 + 1)
       {
         if ( !(总_198_do_1070_si100si2[临_in_2][0]==临_lo_1) )   continue;
         总_198_do_1070_si100si2[临_in_2][0] = 0.0;
         总_198_do_1070_si100si2[临_in_2][1] = 0.0;
         break;
         
       }
       OrderDelete(OrderTicket(),Green); 
     }
     else
     {
       Print("Spread too high..(" + string(总_1_do_0) + ") deleting order " + string(OrderTicket())); 
       临_lo_3 = OrderTicket();
       for (临_in_4 = 0 ; 临_in_4 < 100 ; 临_in_4=临_in_4 + 1)
       {
         if ( !(总_198_do_1070_si100si2[临_in_4][0]==临_lo_3) )   continue;
         总_198_do_1070_si100si2[临_in_4][0] = 0.0;
         总_198_do_1070_si100si2[临_in_4][1] = 0.0;
         break;
         
       }
       OrderDelete(OrderTicket(),Green); 
     }
   }
   if ( OrderType() != 5 )   continue;
   临_do_5 = OrderOpenPrice();
   if ( !(临_do_5>MarketInfo(总_336_st_3130,MODE_BID) - 总_36_in_B0 * 总_229_do_1E00) )   continue;
   临_do_6 = MarketInfo(总_336_st_3130,MODE_BID);
   if ( !(临_do_6>OrderOpenPrice() + 总_309_do_2898) )   continue;
   
   if ( 总_37_do_B8>0.0 )
   {
     Print("Spread too high..(" + string(总_1_do_0) + ") storing and deleting order " + string(OrderTicket())); 
     for (子_4_in = 0 ; 子_4_in < 总_200_in_16B4 ; 子_4_in ++)
     {
       if ( 总_197_do_6DC_si100si3[子_4_in][0]==0.0 )
       {
         Print("Storing pending order nr " + string(OrderTicket())); 
         总_197_do_6DC_si100si3[子_4_in][1] = OrderType();
         总_197_do_6DC_si100si3[子_4_in][0] = OrderOpenPrice();
         总_197_do_6DC_si100si3[子_4_in][2] = OrderLots();
         break;
       }
     }
     临_lo_7 = OrderTicket();
     for (临_in_8 = 0 ; 临_in_8 < 100 ; 临_in_8=临_in_8 + 1)
     {
       if ( !(总_198_do_1070_si100si2[临_in_8][0]==临_lo_7) )   continue;
       总_198_do_1070_si100si2[临_in_8][0] = 0.0;
       总_198_do_1070_si100si2[临_in_8][1] = 0.0;
       break;
       
     }
     OrderDelete(OrderTicket(),Green); 
      continue;
   }
   Print("Spread too high..(" + string(总_1_do_0) + ") deleting order " + string(OrderTicket())); 
   临_lo_9 = OrderTicket();
   for (临_in_10 = 0 ; 临_in_10 < 100 ; 临_in_10=临_in_10 + 1)
   {
     if ( !(总_198_do_1070_si100si2[临_in_10][0]==临_lo_9) )   continue;
     总_198_do_1070_si100si2[临_in_10][0] = 0.0;
     总_198_do_1070_si100si2[临_in_10][1] = 0.0;
     break;
     
   }
   OrderDelete(OrderTicket(),Green); 
   
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
 if ( ManualBalance>0.0 )
 {
   总_401_do_6AD0 = ManualBalance ;
 }
 if ( OnlyUp && 总_402_do_6AD8>总_401_do_6AD0 )
 {
   总_401_do_6AD0 = 总_402_do_6AD8 ;
 }
 if ( 总_401_do_6AD0>总_402_do_6AD8 )
 {
   总_402_do_6AD8 = 总_401_do_6AD0 ;
   if ( OnlyUp )   GlobalVariableSet(OnlyUpPeakGVName(),总_402_do_6AD8) ;
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
   if ( MarketInfo(总_336_st_3130,MODE_LOTSTEP)==0.1 )
   {
     子_2_do = NormalizeDouble(木_1_in * 0.01 * (子_5_do / (MarketInfo(总_336_st_3130,MODE_TICKVALUE) * 子_3_do) * 0.1),1) ;
   }
   if ( MarketInfo(总_336_st_3130,MODE_LOTSTEP)==0.01 )
   {
     子_2_do = NormalizeDouble(木_1_in * 0.01 * (子_5_do / (MarketInfo(总_336_st_3130,MODE_TICKVALUE) * 子_3_do) * 0.1),2) ;
   }
 }
 if ( Risk == 999 )
 {
   子_6_do = 总_148_do_420 / 100.0 * 总_401_do_6AD0 ;
   if ( MarketInfo(总_336_st_3130,MODE_LOTSTEP)==0.1 )
   {
     子_2_do = NormalizeDouble(木_1_in * 0.01 * (子_6_do / (MarketInfo(总_336_st_3130,MODE_TICKVALUE) * 子_3_do) * 0.1),1) ;
   }
   if ( MarketInfo(总_336_st_3130,MODE_LOTSTEP)==0.01 )
   {
     子_2_do = NormalizeDouble(木_1_in * 0.01 * (子_6_do / (MarketInfo(总_336_st_3130,MODE_TICKVALUE) * 子_3_do) * 0.1),2) ;
   }
 }
 if ( Risk == 0 )
 {
   if ( MarketInfo(总_336_st_3130,MODE_LOTSTEP)==0.1 )
   {
     子_2_do = NormalizeDouble(木_1_in * 0.01 * g_startLots_rw,1) ;
   }
   if ( MarketInfo(总_336_st_3130,MODE_LOTSTEP)==0.01 )
   {
     子_2_do = NormalizeDouble(木_1_in * 0.01 * g_startLots_rw,2) ;
   }
 }
 if ( Risk == 9999 )
 {
   if ( MarketInfo(总_336_st_3130,MODE_LOTSTEP)==0.1 )
   {
     子_2_do = NormalizeDouble(木_1_in * 0.01 * (总_401_do_6AD0 / 总_145_in_40C * 0.01),1) ;
   }
   if ( MarketInfo(总_336_st_3130,MODE_LOTSTEP)==0.01 )
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
     if ( SymbolInfoDouble(总_336_st_3130,36)==0.1 )
     {
       子_2_do = NormalizeDouble(总_146_do_410 / 总_397_do_6768 * 总_401_do_6AD0 / 100.0 * 0.01,1) ;
     }
     if ( SymbolInfoDouble(总_336_st_3130,36)==0.01 )
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
     if ( SymbolInfoDouble(总_336_st_3130,36)==0.1 )
     {
       子_2_do = NormalizeDouble(木_1_in * 0.01 * (子_7_do / 总_145_in_40C * 0.01),1) ;
     }
     if ( SymbolInfoDouble(总_336_st_3130,36)==0.01 )
     {
       子_2_do = NormalizeDouble(木_1_in * 0.01 * (子_7_do / 总_145_in_40C * 0.01),2) ;
     }
   }
 }
 if ( Risk == 3 )
 {
   if ( SymbolInfoDouble(总_336_st_3130,36)==0.1 )
   {
     子_2_do = NormalizeDouble(MaxRiskPerStrategy_ / 总_397_do_6768 * 总_401_do_6AD0 / 100.0 * 0.01,1) ;
   }
   if ( SymbolInfoDouble(总_336_st_3130,36)==0.01 )
   {
     子_2_do = NormalizeDouble(MaxRiskPerStrategy_ / 总_397_do_6768 * 总_401_do_6AD0 / 100.0 * 0.01,2) ;
   }
 }
 子_2_do = 子_2_do * 总_9_do_60 ;
 if ( 子_2_do<MarketInfo(总_336_st_3130,MODE_LOTSTEP) )
 {
   子_2_do = MarketInfo(总_336_st_3130,MODE_LOTSTEP) ;
 }
 if ( 子_2_do>总_141_do_3F8 )
 {
   子_2_do = 总_141_do_3F8 ;
 }
 if ( 子_2_do<MarketInfo(总_336_st_3130,MODE_MINLOT) )
 {
   子_2_do = MarketInfo(总_336_st_3130,MODE_MINLOT) ;
 }
 if ( 子_2_do>MarketInfo(总_336_st_3130,MODE_MAXLOT) && MarketInfo(总_336_st_3130,MODE_MAXLOT)!=0.0 )
 {
   子_2_do = MarketInfo(总_336_st_3130,MODE_MAXLOT) ;
 }
 if ( MarketInfo(总_336_st_3130,MODE_LOTSTEP)==0.1 )
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
     if ( iHigh(总_336_st_3130,MT4Period(木_0_in),子_6_in)>iHigh(总_336_st_3130,MT4Period(木_0_in),子_5_in) )
     {
       子_4_bo = false ;
     }
   }
   for (子_7_in = 子_5_in ; 子_7_in <= 子_5_in + 总_73_in_17C ; 子_7_in ++)
   {
     if ( iHigh(总_336_st_3130,MT4Period(木_0_in),子_7_in)>iHigh(总_336_st_3130,MT4Period(木_0_in),子_5_in) )
     {
       子_3_bo = false ;
     }
   }
   if ( 子_4_bo && 子_3_bo && iHigh(总_336_st_3130,MT4Period(木_0_in),子_5_in)>总_80_do_198 * 总_229_do_1E00 + MarketInfo(总_336_st_3130,MODE_ASK) )
   {
     临_do_1 = iHigh(总_336_st_3130,MT4Period(木_0_in),子_5_in);
     临_in_2 = 子_5_in;
     临_do_3 = iHigh(总_336_st_3130,MT4Period(总_71_in_174),0);
     for (临_in_4 = 1 ; 临_in_4 <= 临_in_2 ; 临_in_4=临_in_4 + 1)
     {
       if ( iHigh(总_336_st_3130,MT4Period(总_71_in_174),临_in_4)>临_do_3 )
       {
         临_do_3 = iHigh(总_336_st_3130,MT4Period(总_71_in_174),临_in_4);
       }
     }
     if ( 临_do_1>=临_do_3 )
     {
       临_do_5 = NormalizeDouble(iHigh(总_336_st_3130,MT4Period(木_0_in),子_5_in),总_190_in_518);
       临_bo_7=false; 
       for (临_in_6 = MT4OrdersTotal() ; 临_in_6 >= 0 ; 临_in_6=临_in_6 - 1)
       {
         if ( OrderSelect(临_in_6,0,0) != true || OrderMagicNumber() != 总_93_in_1F0 || OrderSymbol() != 总_336_st_3130 || OrderType() != 4 || !(MathAbs(OrderOpenPrice() - (总_83_do_1B0 * 总_229_do_1E00 + 临_do_5))<总_88_do_1D0 * 总_229_do_1E00) )   continue;
         临_bo_7 = true;
          break;
         
       }
       if ( !(临_bo_7) && ( !(总_75_bo_184) || !(iClose(总_336_st_3130,MT4Period(木_0_in),子_5_in - 1)>iHigh(总_336_st_3130,MT4Period(木_0_in),子_5_in) - 总_80_do_198 * 总_229_do_1E00) ) )
       {
         子_2_bo = true ;
         总_262_do_2580 = NormalizeDouble(iHigh(总_336_st_3130,MT4Period(木_0_in),子_5_in),总_190_in_518) ;
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
     if ( iLow(总_336_st_3130,MT4Period(木_0_in),子_6_in)<iLow(总_336_st_3130,MT4Period(木_0_in),子_5_in) )
     {
       子_4_bo = false ;
     }
   }
   for (子_7_in = 子_5_in ; 子_7_in <= 子_5_in + 总_73_in_17C ; 子_7_in ++)
   {
     if ( iLow(总_336_st_3130,MT4Period(木_0_in),子_7_in)<iLow(总_336_st_3130,MT4Period(木_0_in),子_5_in) )
     {
       子_3_bo = false ;
     }
   }
   if ( 子_4_bo && 子_3_bo && iLow(总_336_st_3130,MT4Period(木_0_in),子_5_in)<MarketInfo(总_336_st_3130,MODE_BID) - 总_80_do_198 * 总_229_do_1E00 )
   {
     临_do_1 = iLow(总_336_st_3130,MT4Period(木_0_in),子_5_in);
     临_in_2 = 子_5_in;
     临_do_3 = iLow(总_336_st_3130,MT4Period(总_71_in_174),0);
     for (临_in_4 = 1 ; 临_in_4 <= 临_in_2 ; 临_in_4=临_in_4 + 1)
     {
       if ( iLow(总_336_st_3130,MT4Period(总_71_in_174),临_in_4)<临_do_3 )
       {
         临_do_3 = iLow(总_336_st_3130,MT4Period(总_71_in_174),临_in_4);
       }
     }
     if ( 临_do_1<=临_do_3 )
     {
       临_do_5 = NormalizeDouble(iLow(总_336_st_3130,MT4Period(木_0_in),子_5_in),总_190_in_518);
       临_bo_7=false; 
       for (临_in_6 = MT4OrdersTotal() ; 临_in_6 >= 0 ; 临_in_6=临_in_6 - 1)
       {
         if ( OrderSelect(临_in_6,0,0) != true || OrderMagicNumber() != 总_93_in_1F0 || OrderSymbol() != 总_336_st_3130 || OrderType() != 5 || !(MathAbs(OrderOpenPrice() - (临_do_5 - 总_84_do_1B8 * 总_229_do_1E00))<总_88_do_1D0 * 总_229_do_1E00) )   continue;
         临_bo_7 = true;
          break;
         
       }
       if ( !(临_bo_7) && ( !(总_75_bo_184) || !(iClose(总_336_st_3130,MT4Period(木_0_in),子_5_in - 1)<总_80_do_198 * 总_229_do_1E00 + iLow(总_336_st_3130,MT4Period(木_0_in),子_5_in)) ) )
       {
         子_2_bo = true ;
         总_261_do_2578 = NormalizeDouble(iLow(总_336_st_3130,MT4Period(木_0_in),子_5_in),总_190_in_518) ;
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
     if ( iHigh(总_336_st_3130,MT4Period(木_0_in),子_7_in)>iHigh(总_336_st_3130,MT4Period(木_0_in),子_6_in) )
     {
       子_5_bo = false ;
     }
   }
   for (子_8_in = 子_6_in ; 子_8_in <= 子_6_in + 木_1_in ; 子_8_in ++)
   {
     if ( iHigh(总_336_st_3130,MT4Period(木_0_in),子_8_in)>iHigh(总_336_st_3130,MT4Period(木_0_in),子_6_in) )
     {
       子_4_bo = false ;
     }
   }
   if ( 子_5_bo && 子_4_bo && iHigh(总_336_st_3130,MT4Period(木_0_in),子_6_in)>总_221_do_1A80 * 总_229_do_1E00 + MarketInfo(总_336_st_3130,MODE_ASK) )
   {
     子_2_bo = true ;
     子_3_do = NormalizeDouble(iHigh(总_336_st_3130,MT4Period(木_0_in),子_6_in),总_190_in_518) ;
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
     if ( iLow(总_336_st_3130,MT4Period(木_0_in),子_7_in)<iLow(总_336_st_3130,MT4Period(木_0_in),子_6_in) )
     {
       子_5_bo = false ;
     }
   }
   for (子_8_in = 子_6_in ; 子_8_in <= 子_6_in + 木_1_in ; 子_8_in ++)
   {
     if ( iLow(总_336_st_3130,MT4Period(木_0_in),子_8_in)<iLow(总_336_st_3130,MT4Period(木_0_in),子_6_in) )
     {
       子_4_bo = false ;
     }
   }
   if ( 子_5_bo && 子_4_bo && iLow(总_336_st_3130,MT4Period(木_0_in),子_6_in)<MarketInfo(总_336_st_3130,MODE_BID) - 总_221_do_1A80 * 总_229_do_1E00 )
   {
     子_2_bo = true ;
     子_3_do = NormalizeDouble(iLow(总_336_st_3130,MT4Period(木_0_in),子_6_in),总_190_in_518) ;
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
   总_268_do_25A8 = iMA(总_336_st_3130,0,总_214_in_1714,0,1,0,1) ;
   总_269_do_25B0 = iMA(总_336_st_3130,0,总_217_in_1A70,0,1,0,1) ;
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
   for (子_1_in = MT4OrdersTotal() ; 子_1_in >= 0 ; 子_1_in --)
   {
     if ( OrderSelect(子_1_in,0,0) != true || OrderMagicNumber() != 总_93_in_1F0 || OrderSymbol() != 总_336_st_3130 )   continue;
     
     if ( ( OrderType() != 4 && OrderType() != 5 ) )   continue;
     临_lo_1 = TimeCurrent();
     临_lo_2=OrderOpenTime() + 总_234_in_1E20;
     if ( 临_lo_1 < 临_lo_2 )   continue;
     OrderDelete(OrderTicket(),Red); 
     
   }
 }
 临_in_3 = 0;
 for (临_in_4 = MT4OrdersTotal() ; 临_in_4 >= 0 ; 临_in_4=临_in_4 - 1)
 {
   if ( OrderSelect(临_in_4,0,0) != true || OrderMagicNumber() != 总_93_in_1F0 || OrderSymbol() != 总_336_st_3130 || OrderType() != 0 )   continue;
   临_in_3=临_in_3 + 1;
   
 }
 if ( 临_in_3 <  总_87_in_1CC )
 {
   lizong_16(1); 
 }
 else
 {
   临_in_5 = 1;
   for (临_in_6 = MT4OrdersTotal() ; 临_in_6 >= 0 ; 临_in_6=临_in_6 - 1)
   {
     if ( OrderSelect(临_in_6,0,0) != true || OrderMagicNumber() != 总_93_in_1F0 || OrderSymbol() != 总_336_st_3130 || OrderType() != 4 )   continue;
     OrderDelete(OrderTicket(),0xFFFFFFFF); 
     
   }
   if ( 临_in_5 == 2 )
   {
     for (临_in_7 = MT4OrdersTotal() ; 临_in_7 >= 0 ; 临_in_7=临_in_7 - 1)
     {
       if ( OrderSelect(临_in_7,0,0) != true || OrderMagicNumber() != 总_96_in_208 || OrderSymbol() != 总_336_st_3130 || OrderType() != 4 )   continue;
       OrderDelete(OrderTicket(),0xFFFFFFFF); 
       
     }
   }
 }
 临_in_8 = 0;
 for (临_in_9 = MT4OrdersTotal() ; 临_in_9 >= 0 ; 临_in_9=临_in_9 - 1)
 {
   if ( OrderSelect(临_in_9,0,0) != true || OrderMagicNumber() != 总_93_in_1F0 || OrderSymbol() != 总_336_st_3130 || OrderType() != 1 )   continue;
   临_in_8=临_in_8 + 1;
   
 }
 if ( 临_in_8 <  总_87_in_1CC )
 {
   lizong_17(1); 
   return;
 }
 临_in_10 = 1;
 for (临_in_11 = MT4OrdersTotal() ; 临_in_11 >= 0 ; 临_in_11=临_in_11 - 1)
 {
   if ( OrderSelect(临_in_11,0,0) != true || OrderMagicNumber() != 总_93_in_1F0 || OrderSymbol() != 总_336_st_3130 || OrderType() != 5 )   continue;
   OrderDelete(OrderTicket(),0xFFFFFFFF); 
   
 }
 if ( 临_in_10 != 2 )   return;
 for (临_in_12 = MT4OrdersTotal() ; 临_in_12 >= 0 ; 临_in_12=临_in_12 - 1)
 {
   if ( OrderSelect(临_in_12,0,0) != true || OrderMagicNumber() != 总_96_in_208 || OrderSymbol() != 总_336_st_3130 || OrderType() != 5 )   continue;
   OrderDelete(OrderTicket(),0xFFFFFFFF); 
   
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
   for (临_in_2 = 0 ; 临_in_2 < MT4OrdersTotal() ; 临_in_2=临_in_2 + 1)
   {
     if ( OrderSelect(临_in_2,0,0) != true || OrderType() != 0 || OrderMagicNumber() != 总_93_in_1F0 || OrderSymbol() != 总_336_st_3130 )   continue;
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
   for (临_in_4 = MT4OrdersTotal() ; 临_in_4 >= 0 ; 临_in_4=临_in_4 - 1)
   {
     if ( OrderSelect(临_in_4,0,0) != true || OrderMagicNumber() != 总_93_in_1F0 || OrderSymbol() != 总_336_st_3130 || OrderType() != 4 || !(MathAbs(OrderOpenPrice() - (总_83_do_1B0 * 总_229_do_1E00 + 临_do_3))<总_88_do_1D0 * 总_229_do_1E00) )   continue;
     临_bo_5 = true;
      break;
     
   }
   if ( !(临_bo_5) )
   {
     临_in_6 = 0;
     for (临_in_7 = MT4OrdersTotal() ; 临_in_7 >= 0 ; 临_in_7=临_in_7 - 1)
     {
       if ( OrderSelect(临_in_7,0,0) != true || OrderMagicNumber() != 总_93_in_1F0 || OrderSymbol() != 总_336_st_3130 || OrderType() != 4 )   continue;
       临_in_6=临_in_6 + 1;
       
     }
     if ( 临_in_6 == 总_86_in_1C8 )
     {
       临_do_8 = 9999.0;
       for (临_in_9 = MT4OrdersTotal() ; 临_in_9 >= 0 ; 临_in_9=临_in_9 - 1)
       {
         if ( OrderSelect(临_in_9,0,0) != true || OrderMagicNumber() != 总_93_in_1F0 || OrderSymbol() != 总_336_st_3130 || OrderType() != 4 || !(OrderOpenPrice()<临_do_8) )   continue;
         临_do_8 = OrderOpenPrice();
         
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
     for (临_in_11 = MT4OrdersTotal() ; 临_in_11 >= 0 ; 临_in_11=临_in_11 - 1)
     {
       if ( OrderSelect(临_in_11,0,0) != true || OrderMagicNumber() != 总_93_in_1F0 || OrderSymbol() != 总_336_st_3130 || OrderType() != 4 || !(OrderOpenPrice()<=临_do_10) )   continue;
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
       if ( CheckMargin && AccountFreeMarginCheck(总_336_st_3130,0,总_223_do_1AC4_si99[总_328_in_3100])<=0.0 )
       {
         Print("Free margin not sufficient for setting order with lotsize " + string(总_223_do_1AC4_si99[总_328_in_3100]) + "..."); 
         return(false); 
       }
       子_4_do = NormalizeDouble(总_15_in_78 * 总_229_do_1E00 + 子_3_do,总_190_in_518) ;
       子_5_do = NormalizeDouble(子_3_do - (总_100_do_230 + 总_64_do_148) * 总_229_do_1E00,总_190_in_518) ;
       子_6_do = NormalizeDouble(总_101_do_238 * 总_229_do_1E00 + 子_3_do,总_190_in_518) ;
       if ( 总_223_do_1AC4_si99[总_328_in_3100]<SymbolInfoDouble(总_336_st_3130,34) )
       {
         Print("Volume is less than the minimal allowed SYMBOL_VOLUME_MIN=" + string(SymbolInfoDouble(总_336_st_3130,34))); 
         临_bo_13 = false;
       }
       else
       {
         if ( 总_223_do_1AC4_si99[总_328_in_3100]>SymbolInfoDouble(总_336_st_3130,35) )
         {
           Print("Volume is greater than the maximal allowed SYMBOL_VOLUME_MAX=" + string(SymbolInfoDouble(总_336_st_3130,35))); 
           临_bo_13 = false;
         }
         else
         {
           if ( MathAbs(NormalizeDouble(总_223_do_1AC4_si99[总_328_in_3100] / SymbolInfoDouble(总_336_st_3130,36),0) * SymbolInfoDouble(总_336_st_3130,36) - 总_223_do_1AC4_si99[总_328_in_3100])>0.0000001 )
           {
             Print("Volume " + string(总_223_do_1AC4_si99[总_328_in_3100]) + " is not a multiple of the minimal step SYMBOL_VOLUME_STEP=" + string(SymbolInfoDouble(总_336_st_3130,36))); 
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
         临_bo_15 = MT4OrdersTotal()<临_in_14;
       }
       if ( ( !(临_bo_13) || !(临_bo_15) ) )
       {
         return(false); 
       }
       if ( MarketInfo(总_336_st_3130,MODE_ASK)<子_4_do - 总_309_do_2898 * 总_229_do_1E00 && MarketInfo(总_336_st_3130,MODE_ASK)<子_4_do - 总_221_do_1A80 * 总_229_do_1E00 )
       {
         if ( !(setSL_TP_After_Entry) )
         {
           总_230_in_1E08 = (int)OrderSend(总_336_st_3130,4,总_223_do_1AC4_si99[总_328_in_3100],子_4_do,int(总_38_do_C0 * 总_229_do_1E00),子_5_do,子_6_do,总_334_st_3120,总_93_in_1F0,总_302_da_2870,Green) ;
         }
         else
         {
           总_230_in_1E08 = (int)OrderSend(总_336_st_3130,4,总_223_do_1AC4_si99[总_328_in_3100],子_4_do,int(总_38_do_C0 * 总_229_do_1E00),0.0,0.0,总_334_st_3120,总_93_in_1F0,总_302_da_2870,Green) ;
         }
         总_280_bo_25FA = false ;
         if ( 总_230_in_1E08 <= 0 )
         {
           临_in_16 = MT4_LastError();
           if ( 临_in_16 == 132 )
           {
             ResetLastError();
             if(1==0) //条件不成立
             {
               do
               {
                 Sleep(2500); 
                 if ( !(setSL_TP_After_Entry) )
                 {
                   临_in_16 = (int)(总_38_do_C0 * 总_229_do_1E00);
                   总_230_in_1E08 = (int)OrderSend(总_336_st_3130,4,总_223_do_1AC4_si99[总_328_in_3100],子_4_do,临_in_16,子_5_do,子_6_do,总_334_st_3120,总_93_in_1F0,总_302_da_2870,Green) ;
                 }
                 else
                 {
                   总_230_in_1E08 = (int)OrderSend(总_336_st_3130,4,总_223_do_1AC4_si99[总_328_in_3100],子_4_do,int(总_38_do_C0 * 总_229_do_1E00),0.0,0.0,总_334_st_3120,总_93_in_1F0,总_302_da_2870,Green) ;
                 }
                 总_280_bo_25FA = false ;
               }
               while(MT4_LastError() == 132);
               
             }
           }
           Print("error: \'" + lizong_21(MT4_LastError()) + "\' when setting entry order"); 
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
   for (临_in_2 = 0 ; 临_in_2 < MT4OrdersTotal() ; 临_in_2=临_in_2 + 1)
   {
     if ( OrderSelect(临_in_2,0,0) != true || OrderType() != 1 || OrderMagicNumber() != 总_93_in_1F0 || OrderSymbol() != 总_336_st_3130 )   continue;
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
   for (临_in_4 = MT4OrdersTotal() ; 临_in_4 >= 0 ; 临_in_4=临_in_4 - 1)
   {
     if ( OrderSelect(临_in_4,0,0) != true || OrderMagicNumber() != 总_93_in_1F0 || OrderSymbol() != 总_336_st_3130 || OrderType() != 5 || !(MathAbs(OrderOpenPrice() - (临_do_3 - 总_84_do_1B8 * 总_229_do_1E00))<总_88_do_1D0 * 总_229_do_1E00) )   continue;
     临_bo_5 = true;
      break;
     
   }
   if ( !(临_bo_5) )
   {
     临_in_6 = 0;
     for (临_in_7 = MT4OrdersTotal() ; 临_in_7 >= 0 ; 临_in_7=临_in_7 - 1)
     {
       if ( OrderSelect(临_in_7,0,0) != true || OrderMagicNumber() != 总_93_in_1F0 || OrderSymbol() != 总_336_st_3130 || OrderType() != 5 )   continue;
       临_in_6=临_in_6 + 1;
       
     }
     if ( 临_in_6 == 总_86_in_1C8 )
     {
       临_do_8 = 0.0;
       for (临_in_9 = MT4OrdersTotal() ; 临_in_9 >= 0 ; 临_in_9=临_in_9 - 1)
       {
         if ( OrderSelect(临_in_9,0,0) != true || OrderMagicNumber() != 总_93_in_1F0 || OrderSymbol() != 总_336_st_3130 || OrderType() != 5 || !(OrderOpenPrice()>临_do_8) )   continue;
         临_do_8 = OrderOpenPrice();
         
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
     for (临_in_11 = MT4OrdersTotal() ; 临_in_11 >= 0 ; 临_in_11=临_in_11 - 1)
     {
       if ( OrderSelect(临_in_11,0,0) != true || OrderMagicNumber() != 总_93_in_1F0 || OrderSymbol() != 总_336_st_3130 || OrderType() != 5 || !(OrderOpenPrice()>=临_do_10) )   continue;
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
       if ( CheckMargin && AccountFreeMarginCheck(总_336_st_3130,1,总_223_do_1AC4_si99[总_328_in_3100])<=0.0 )
       {
         Print("Free margin not sufficient for setting order with lotsize " + string(总_223_do_1AC4_si99[总_328_in_3100]) + "..."); 
         return(false); 
       }
       子_4_do = NormalizeDouble(子_3_do - 总_15_in_78 * 总_229_do_1E00,总_190_in_518) ;
       子_5_do = NormalizeDouble((总_100_do_230 + 总_64_do_148) * 总_229_do_1E00 + 子_3_do,总_190_in_518) ;
       子_6_do = NormalizeDouble(子_3_do - 总_101_do_238 * 总_229_do_1E00,总_190_in_518) ;
       if ( 总_223_do_1AC4_si99[总_328_in_3100]<SymbolInfoDouble(总_336_st_3130,34) )
       {
         Print("Volume is less than the minimal allowed SYMBOL_VOLUME_MIN=" + string(SymbolInfoDouble(总_336_st_3130,34))); 
         临_bo_13 = false;
       }
       else
       {
         if ( 总_223_do_1AC4_si99[总_328_in_3100]>SymbolInfoDouble(总_336_st_3130,35) )
         {
           Print("Volume is greater than the maximal allowed SYMBOL_VOLUME_MAX=" + string(SymbolInfoDouble(总_336_st_3130,35))); 
           临_bo_13 = false;
         }
         else
         {
           if ( MathAbs(NormalizeDouble(总_223_do_1AC4_si99[总_328_in_3100] / SymbolInfoDouble(总_336_st_3130,36),0) * SymbolInfoDouble(总_336_st_3130,36) - 总_223_do_1AC4_si99[总_328_in_3100])>0.0000001 )
           {
             Print("Volume " + string(总_223_do_1AC4_si99[总_328_in_3100]) + " is not a multiple of the minimal step SYMBOL_VOLUME_STEP=" + string(SymbolInfoDouble(总_336_st_3130,36))); 
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
         临_bo_15 = MT4OrdersTotal()<临_in_14;
       }
       if ( ( !(临_bo_13) || !(临_bo_15) ) )
       {
         return(false); 
       }
       if ( MarketInfo(总_336_st_3130,MODE_BID)>总_309_do_2898 * 总_229_do_1E00 + 子_4_do && MarketInfo(总_336_st_3130,MODE_BID)>总_221_do_1A80 * 总_229_do_1E00 + 子_4_do )
       {
         if ( !(setSL_TP_After_Entry) )
         {
           总_230_in_1E08 = (int)OrderSend(总_336_st_3130,5,总_223_do_1AC4_si99[总_328_in_3100],子_4_do,int(总_38_do_C0 * 总_229_do_1E00),子_5_do,子_6_do,总_334_st_3120,总_93_in_1F0,总_302_da_2870,Red) ;
         }
         else
         {
           总_230_in_1E08 = (int)OrderSend(总_336_st_3130,5,总_223_do_1AC4_si99[总_328_in_3100],子_4_do,int(总_38_do_C0 * 总_229_do_1E00),0.0,0.0,总_334_st_3120,总_93_in_1F0,总_302_da_2870,Red) ;
         }
         总_281_bo_25FB = false ;
         if ( 总_230_in_1E08 <= 0 )
         {
           临_in_16 = MT4_LastError();
           if ( 临_in_16 == 132 )
           {
             ResetLastError();
             if(1==0) //条件不成立
             {
               do
               {
                 Sleep(2500); 
                 if ( !(setSL_TP_After_Entry) )
                 {
                   临_in_16 = (int)(总_38_do_C0 * 总_229_do_1E00);
                   总_230_in_1E08 = (int)OrderSend(总_336_st_3130,5,总_223_do_1AC4_si99[总_328_in_3100],子_4_do,临_in_16,子_5_do,子_6_do,总_334_st_3120,总_93_in_1F0,总_302_da_2870,Red) ;
                 }
                 else
                 {
                   总_230_in_1E08 = (int)OrderSend(总_336_st_3130,5,总_223_do_1AC4_si99[总_328_in_3100],子_4_do,int(总_38_do_C0 * 总_229_do_1E00),0.0,0.0,总_334_st_3120,总_93_in_1F0,总_302_da_2870,Red) ;
                 }
                 总_281_bo_25FB = false ;
               }
               while(MT4_LastError() == 132);
               
             }
           }
           Print("error: \'" + lizong_21(MT4_LastError()) + "\' when setting entry order"); 
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

 子_4_do = 0.0 ;
 子_5_do = 0.0 ;
 for (子_6_in = 0 ; 子_6_in < MT4OrdersTotal() ; 子_6_in ++)
 {
   if ( OrderSelect(子_6_in,0,0) == true )
   {
     子_2_bo = false ;
     子_7_do = NormalizeDouble(OrderStopLoss(),总_190_in_518) ;
     子_8_do = NormalizeDouble(OrderTakeProfit(),总_190_in_518) ;
     子_9_lo = OrderTicket() ;
     子_10_do = NormalizeDouble(OrderOpenPrice(),总_190_in_518) ;
     子_11_st = OrderComment() ;
     子_12_do = OrderLots() ;
     子_13_da = OrderOpenTime() ;
     子_14_in = OrderType() ;
     子_15_in = OrderMagicNumber() ;
     子_16_st = OrderSymbol() ;
     if ( ( 子_14_in == 4 || 子_14_in == 2 ) && 总_69_in_160 == 2 && ( 总_95_in_204 == 0 || (总_95_in_204 == 1 && 子_16_st == 总_336_st_3130) ) && ( 子_15_in == 总_96_in_208 || 总_96_in_208 == 0 ) && ( 子_11_st == 总_97_st_210 || 总_97_st_210 == "" ) )
     {
       if ( ( 子_7_do==0.0 || 子_7_do==0.0 ) )
       {
         子_7_do = NormalizeDouble(子_10_do - 总_100_do_230 * 总_229_do_1E00,总_190_in_518) ;
         OrderModify(子_9_lo,子_10_do,子_7_do,子_8_do,0,Green); 
       }
       if ( ( 子_8_do==0.0 || 子_8_do==0.0 ) )
       {
         子_8_do = NormalizeDouble(总_101_do_238 * 总_229_do_1E00 + 子_10_do,总_190_in_518) ;
         OrderModify(子_9_lo,子_10_do,子_7_do,子_8_do,0,Green); 
       }
     }
     if ( 子_14_in == 0 && ( ( 子_15_in == 总_93_in_1F0 && 总_69_in_160 == 1 && 子_16_st == 总_336_st_3130 ) || (总_69_in_160 == 2 && ( 总_95_in_204 == 0 || (总_95_in_204 == 1 && 子_16_st == 总_336_st_3130) ) && ( 子_15_in == 总_96_in_208 || 总_96_in_208 == 0 ) && (子_11_st == 总_97_st_210 || 总_97_st_210 == "")) ) )
     {
       if ( ( 子_7_do==0.0 || 子_7_do==0.0 ) )
       {
         子_7_do = NormalizeDouble(子_10_do - 总_100_do_230 * 总_229_do_1E00,总_190_in_518) ;
         OrderModify(子_9_lo,子_10_do,子_7_do,子_8_do,0,Green); 
       }
       if ( ( 子_8_do==0.0 || 子_8_do==0.0 ) )
       {
         子_8_do = NormalizeDouble(总_101_do_238 * 总_229_do_1E00 + 子_10_do,总_190_in_518) ;
         OrderModify(子_9_lo,子_10_do,子_7_do,子_8_do,0,Green); 
       }
       if ( 总_53_bo_11C && iTime(总_336_st_3130,MT4Period(总_52_in_118),总_51_in_114) <= 子_13_da && iTime(总_336_st_3130,MT4Period(总_52_in_118),0) >  子_13_da && iClose(总_336_st_3130,MT4Period(总_52_in_118),1)<iOpen(总_336_st_3130,MT4Period(总_52_in_118),1) && iClose(总_336_st_3130,MT4Period(总_52_in_118),1)<子_10_do )
       {
         OrderClose(子_9_lo,子_12_do,MarketInfo(总_336_st_3130,MODE_BID),0,Red); 
         Print("closing candle confirmation"); 
       }
       if ( 总_55_bo_124 && iTime(总_336_st_3130,MT4Period(总_54_in_120),总_51_in_114) <= 子_13_da && iTime(总_336_st_3130,MT4Period(总_54_in_120),0) >  子_13_da && iClose(总_336_st_3130,MT4Period(总_54_in_120),1)<iOpen(总_336_st_3130,MT4Period(总_54_in_120),1) && iClose(总_336_st_3130,MT4Period(总_54_in_120),1)<子_10_do )
       {
         OrderClose(子_9_lo,子_12_do,MarketInfo(总_336_st_3130,MODE_BID),0,Red); 
         Print("closing candle confirmation"); 
       }
       if ( 总_57_bo_12C && iTime(总_336_st_3130,MT4Period(总_56_in_128),总_51_in_114) <= 子_13_da && iTime(总_336_st_3130,MT4Period(总_56_in_128),0) >  子_13_da && iClose(总_336_st_3130,MT4Period(总_56_in_128),1)<iOpen(总_336_st_3130,MT4Period(总_56_in_128),1) && iClose(总_336_st_3130,MT4Period(总_56_in_128),1)<子_10_do )
       {
         OrderClose(子_9_lo,子_12_do,MarketInfo(总_336_st_3130,MODE_BID),0,Red); 
         Print("closing candle confirmation"); 
       }
       if ( 总_59_bo_134 && iTime(总_336_st_3130,MT4Period(总_58_in_130),总_51_in_114) <= 子_13_da && iTime(总_336_st_3130,MT4Period(总_58_in_130),0) >  子_13_da && iClose(总_336_st_3130,MT4Period(总_58_in_130),1)<iOpen(总_336_st_3130,MT4Period(总_58_in_130),1) && iClose(总_336_st_3130,MT4Period(总_58_in_130),1)<子_10_do )
       {
         OrderClose(子_9_lo,子_12_do,MarketInfo(总_336_st_3130,MODE_BID),0,Red); 
         Print("closing candle confirmation"); 
       }
       if ( 总_61_bo_13C && iTime(总_336_st_3130,MT4Period(总_60_in_138),总_51_in_114) <= 子_13_da && iTime(总_336_st_3130,MT4Period(总_60_in_138),0) >  子_13_da && iClose(总_336_st_3130,MT4Period(总_60_in_138),1)<iOpen(总_336_st_3130,MT4Period(总_60_in_138),1) && iClose(总_336_st_3130,MT4Period(总_60_in_138),1)<子_10_do )
       {
         OrderClose(子_9_lo,子_12_do,MarketInfo(总_336_st_3130,MODE_BID),0,Red); 
         Print("closing candle confirmation"); 
       }
       总_247_do_2500 = 总_129_do_318 ;
       if ( 总_133_in_338 >  0 && TimeCurrent() >  子_13_da + 总_133_in_338 * 60 )
       {
         总_247_do_2500 = 总_134_do_340 ;
       }
       临_in_1 = 总_190_in_518;
       临_lo_2 = 子_9_lo;
       for (临_in_3 = 0 ; 临_in_3 < 100 ; 临_in_3=临_in_3 + 1)
       {
         if ( !(总_198_do_1070_si100si2[临_in_3][0]==临_lo_2) )   continue;
         临_do_4 = 总_198_do_1070_si100si2[临_in_3][1];
         break;
         
       }
       临_do_4 = 0.0;
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
           Print("SlippageMode 2 active"); 
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
       if ( 子_7_do<NormalizeDouble(子_10_do - (总_100_do_230 + 总_64_do_148) * 总_229_do_1E00 - 总_1_do_0,总_190_in_518) )
       {
         子_7_do = NormalizeDouble(子_10_do - (总_100_do_230 + 总_64_do_148) * 总_229_do_1E00 - 总_1_do_0,总_190_in_518) ;
         OrderModify(子_9_lo,子_10_do,子_7_do,子_8_do,0,0xFFFFFFFF); 
       }
       if ( MarketInfo(总_336_st_3130,MODE_BID)<子_10_do - (总_100_do_230 + 总_64_do_148) * 总_229_do_1E00 - 总_1_do_0 )
       {
         RefreshRates(); 
         OrderClose(OrderTicket(),OrderLots(),MarketInfo(总_336_st_3130,MODE_BID),(int)总_1_do_0,Red); 
         return(true); 
       }
       子_20_bo = false ;
       if ( 总_159_bo_464 )
       {
         临_lo_8 = 子_9_lo;
         临_in_9 = 0;
         for (临_in_10 = MT4OrdersTotal() ; 临_in_10 >= 0 ; 临_in_10=临_in_10 - 1)
         {
           if ( OrderSelect(临_in_10,0,0) != true || OrderMagicNumber() != 总_168_in_4A8 || OrderSymbol() != 总_336_st_3130 )   continue;
           临_st_11 = OrderComment();
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
             临_do_12 = AccountEquity();
             if ( 临_do_12>AccountBalance() + 总_163_do_480 )
             {
               for (临_in_13 = MT4OrdersTotal() ; 临_in_13 >= 0 ; 临_in_13=临_in_13 - 1)
               {
                 if ( OrderSelect(临_in_13,0,0) != true )   continue;
                 
                 if ( ( OrderMagicNumber() != 总_93_in_1F0 && OrderMagicNumber() != 总_169_in_4AC && OrderMagicNumber() != 总_168_in_4A8 ) )   continue;
                 
                 if ( OrderType() == 0 )
                 {
                   OrderClose(OrderTicket(),OrderLots(),MarketInfo(总_336_st_3130,MODE_BID),(int)总_38_do_C0,Red); 
                 }
                 if ( OrderType() != 1 )   continue;
                 OrderClose(OrderTicket(),OrderLots(),MarketInfo(总_336_st_3130,MODE_ASK),(int)总_38_do_C0,Red); 
                 
               }
             }
           }
           if ( 子_21_do>0.0 )
           {
             临_lo_14 = 子_9_lo;
             临_do_15 = 0.0;
             for (临_in_16 = MT4OrdersTotal() ; 临_in_16 >= 0 ; 临_in_16=临_in_16 - 1)
             {
               if ( OrderSelect(临_in_16,0,0) != true )   continue;
               临_lo_17 = OrderTicket();
               if ( 临_lo_17 != 临_lo_14 )
               {
                 临_st_11 = OrderComment();
               if ( 临_st_11 != IntegerToString(临_lo_14,0,32) )   continue;
               }
               临_do_15 = 临_do_15 + OrderProfit();
               
             }
             if ( 临_do_15>总_163_do_480 )
             {
               Print("Closing zone"); 
               临_lo_18 = 子_9_lo;
               for (临_in_19 = MT4OrdersTotal() ; 临_in_19 >= 0 ; 临_in_19=临_in_19 - 1)
               {
                 if ( OrderSelect(临_in_19,0,0) != true )   continue;
                 
                 if ( OrderMagicNumber() == 总_93_in_1F0 && OrderTicket() == 临_lo_18 )
                 {
                   OrderClose(OrderTicket(),OrderLots(),MarketInfo(总_336_st_3130,MODE_BID),3,Red); 
                 }
                 if ( OrderMagicNumber() != 总_168_in_4A8 )   continue;
                 临_st_11 = OrderComment();
                 if ( 临_st_11 != IntegerToString(临_lo_18,0,32) )   continue;
                 
                 if ( OrderType() == 0 )
                 {
                   OrderClose(OrderTicket(),OrderLots(),MarketInfo(总_336_st_3130,MODE_BID),(int)总_38_do_C0,Red); 
                 }
                 if ( OrderType() != 1 )   continue;
                 OrderClose(OrderTicket(),OrderLots(),MarketInfo(总_336_st_3130,MODE_ASK),(int)总_38_do_C0,Red); 
                 
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
               if ( MarketInfo(总_336_st_3130,MODE_BID)<子_24_do )
               {
                 if ( 子_21_do>=总_166_in_498 )
                 {
                   for (临_in_20 = MT4OrdersTotal() ; 临_in_20 >= 0 ; 临_in_20=临_in_20 - 1)
                   {
                     if ( OrderSelect(临_in_20,0,0) != true )   continue;
                     
                     if ( OrderMagicNumber() == 总_93_in_1F0 && OrderTicket() == 子_9_lo )
                     {
                       OrderClose(OrderTicket(),OrderLots(),MarketInfo(总_336_st_3130,MODE_BID),3,Red); 
                     }
                     if ( OrderMagicNumber() != 总_168_in_4A8 )   continue;
                     临_st_11 = OrderComment();
                     if ( 临_st_11 != IntegerToString(子_9_lo,0,32) )   continue;
                     
                     if ( OrderType() == 0 )
                     {
                       OrderClose(OrderTicket(),OrderLots(),MarketInfo(总_336_st_3130,MODE_BID),(int)总_38_do_C0,Red); 
                     }
                     if ( OrderType() != 1 )   continue;
                     OrderClose(OrderTicket(),OrderLots(),MarketInfo(总_336_st_3130,MODE_ASK),(int)总_38_do_C0,Red); 
                     
                   }
                 }
                 else
                 {
                   OrderSend(总_336_st_3130,1,子_23_do,MarketInfo(总_336_st_3130,MODE_BID),(int)总_38_do_C0,0.0,0.0,IntegerToString(子_9_lo,0,32),总_168_in_4A8,0,Green); 
                   总_192_in_528 = 1 ;
                   子_22_bo = true ;
                 }
               }
             }
             else
             {
               子_25_do = 子_17_do ;
               if ( MarketInfo(总_336_st_3130,MODE_ASK)>子_17_do )
               {
                 if ( 子_21_do>=总_166_in_498 )
                 {
                   for (临_in_21 = MT4OrdersTotal() ; 临_in_21 >= 0 ; 临_in_21=临_in_21 - 1)
                   {
                     if ( OrderSelect(临_in_21,0,0) != true )   continue;
                     
                     if ( OrderMagicNumber() == 总_93_in_1F0 && OrderTicket() == 子_9_lo )
                     {
                       OrderClose(OrderTicket(),OrderLots(),MarketInfo(总_336_st_3130,MODE_BID),3,Red); 
                     }
                     if ( OrderMagicNumber() != 总_168_in_4A8 )   continue;
                     临_st_22 = OrderComment();
                     if ( 临_st_22 != IntegerToString(子_9_lo,0,32) )   continue;
                     
                     if ( OrderType() == 0 )
                     {
                       OrderClose(OrderTicket(),OrderLots(),MarketInfo(总_336_st_3130,MODE_BID),(int)总_38_do_C0,Red); 
                     }
                     if ( OrderType() != 1 )   continue;
                     OrderClose(OrderTicket(),OrderLots(),MarketInfo(总_336_st_3130,MODE_ASK),(int)总_38_do_C0,Red); 
                     
                   }
                 }
                 else
                 {
                   OrderSend(总_336_st_3130,0,子_23_do,MarketInfo(总_336_st_3130,MODE_ASK),(int)总_38_do_C0,0.0,0.0,IntegerToString(子_9_lo,0,32),总_168_in_4A8,0,Green); 
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
           if ( MarketInfo(总_336_st_3130,MODE_BID)<子_4_do )
           {
             Print("Closing with virtual SL"); 
             RefreshRates(); 
             OrderClose(子_9_lo,子_12_do,MarketInfo(总_336_st_3130,MODE_BID),(int)总_1_do_0,0xFFFFFFFF); 
             return(true); 
           }
           if ( 总_125_do_2F8>0.0 && TimeCurrent() >= 子_13_da + 总_304_in_287C && MarketInfo(总_336_st_3130,MODE_BID)>NormalizeDouble(总_126_do_300 * 总_229_do_1E00 + (子_7_do + 总_337_do_3140),总_190_in_518) && MarketInfo(总_336_st_3130,MODE_BID)<子_8_do - 总_309_do_2898 )
           {
             子_7_do = NormalizeDouble(MarketInfo(总_336_st_3130,MODE_BID) - 总_126_do_300 * 总_229_do_1E00,总_190_in_518) ;
             if ( 子_7_do<MarketInfo(总_336_st_3130,MODE_BID) - 总_221_do_1A80 )
             {
               总_230_in_1E08 = OrderModify(子_9_lo,子_10_do,子_7_do,子_8_do,0,0xFFFFFFFF) ;
               if ( 总_230_in_1E08 <= 0 )
               {
                 Print("TrailStop error: \'" + lizong_21(MT4_LastError()) + "\' when setting trailing Exit_TrailSL_after_X_Minutes_size loss.  Trying again!"); 
               }
               子_2_bo = true ;
             }
           }
           if ( 总_103_do_250>0.0 && MarketInfo(总_336_st_3130,MODE_BID)>NormalizeDouble((总_103_do_250 + 总_106_do_268) * 总_229_do_1E00 + (子_7_do + 总_337_do_3140),总_190_in_518) && MarketInfo(总_336_st_3130,MODE_BID)>NormalizeDouble(总_104_do_258 * 总_229_do_1E00 + 子_5_do,总_190_in_518) && MarketInfo(总_336_st_3130,MODE_BID)<子_8_do - 总_309_do_2898 && 子_7_do<NormalizeDouble(总_105_do_260 * 总_229_do_1E00 + 子_10_do,总_190_in_518) )
           {
             子_7_do = NormalizeDouble(MarketInfo(总_336_st_3130,MODE_BID) - 总_103_do_250 * 总_229_do_1E00,总_190_in_518) ;
             if ( 子_7_do<MarketInfo(总_336_st_3130,MODE_BID) - 总_221_do_1A80 )
             {
               总_230_in_1E08 = OrderModify(子_9_lo,子_10_do,子_7_do,子_8_do,0,0xFFFFFFFF) ;
               if ( 总_230_in_1E08 <= 0 )
               {
                 Print("TrailStop error: \'" + lizong_21(MT4_LastError()) + "\' when setting trailing Exit_stop loss.  Trying again!"); 
               }
               else
               {
                 子_26_do = NormalizeDouble(总_107_do_270 / 100.0 * 总_223_do_1AC4_si99[总_328_in_3100],2) ;
                 if ( 子_26_do<子_12_do && 子_26_do>=MarketInfo(总_336_st_3130,MODE_LOTSTEP) )
                 {
                   OrderClose(子_9_lo,子_26_do,MarketInfo(总_336_st_3130,MODE_BID),(int)总_38_do_C0,Red); 
                   return(true); 
                 }
               }
               子_2_bo = true ;
             }
           }
           if ( 总_108_do_278>0.0 && MarketInfo(总_336_st_3130,MODE_ASK)<NormalizeDouble(子_8_do - 总_337_do_3140 - 总_108_do_278 * 总_229_do_1E00,总_190_in_518) && MarketInfo(总_336_st_3130,MODE_ASK)<NormalizeDouble(子_5_do - 总_109_do_280 * 总_229_do_1E00,总_190_in_518) && MarketInfo(总_336_st_3130,MODE_BID)<子_8_do - 总_309_do_2898 )
           {
             子_8_do = NormalizeDouble(MarketInfo(总_336_st_3130,MODE_BID) + 总_108_do_278 * 总_229_do_1E00,总_190_in_518) ;
             if ( 子_8_do>MarketInfo(总_336_st_3130,MODE_ASK) + 总_221_do_1A80 )
             {
               总_230_in_1E08 = OrderModify(子_9_lo,子_10_do,子_7_do,子_8_do,0,0xFFFFFFFF) ;
               if ( 总_230_in_1E08 <= 0 )
               {
                 Print("TrailStop error: \'" + lizong_21(MT4_LastError()) + "\' when setting trailing Exit_TP.  Trying again!"); 
               }
               else
               {
                 子_27_do = NormalizeDouble(总_107_do_270 / 100.0 * 总_223_do_1AC4_si99[总_328_in_3100],2) ;
                 if ( 子_27_do<子_12_do && 子_27_do>=SymbolInfoDouble(总_336_st_3130,34) )
                 {
                   OrderClose(子_9_lo,子_27_do,MarketInfo(总_336_st_3130,MODE_BID),(int)总_38_do_C0,Red); 
                   return(true); 
                 }
               }
               子_2_bo = true ;
             }
           }
           if ( 子_19_bo && 总_39_in_C8 == 1 && 总_41_do_D8>0.0 && MarketInfo(总_336_st_3130,MODE_BID)>NormalizeDouble(总_41_do_D8 * 总_229_do_1E00 + (子_7_do + 总_337_do_3140),总_190_in_518) && MarketInfo(总_336_st_3130,MODE_BID)>NormalizeDouble(总_40_do_D0 * 总_229_do_1E00 + 子_17_do,总_190_in_518) && MarketInfo(总_336_st_3130,MODE_BID)<子_8_do - 总_309_do_2898 && 子_7_do<NormalizeDouble(总_42_do_E0 * 总_229_do_1E00 + 子_10_do,总_190_in_518) )
           {
             子_7_do = NormalizeDouble(MarketInfo(总_336_st_3130,MODE_BID) - 总_41_do_D8 * 总_229_do_1E00,总_190_in_518) ;
             if ( 子_7_do<MarketInfo(总_336_st_3130,MODE_BID) - 总_221_do_1A80 )
             {
               总_230_in_1E08 = OrderModify(子_9_lo,子_10_do,子_7_do,子_8_do,0,0xFFFFFFFF) ;
               if ( 总_230_in_1E08 <= 0 )
               {
                 Print("TrailStop error: \'" + lizong_21(MT4_LastError()) + "\' when setting Slip TL.  Trying again!"); 
               }
               else
               {
                 Print("Slippage control active"); 
               }
               子_2_bo = true ;
             }
           }
           if ( 总_119_in_2D0 >  0 && 总_120_in_2D4 >= 0 && UseHL_TrailingSL && 总_242_do_21C4_si99[总_328_in_3100]>NormalizeDouble(子_7_do + 总_221_do_1A80 + 总_337_do_3140,总_190_in_518) && 总_242_do_21C4_si99[总_328_in_3100]<MarketInfo(总_336_st_3130,MODE_BID) - 总_121_in_2D8 * 总_229_do_1E00 && ( 总_242_do_21C4_si99[总_328_in_3100]<子_10_do || !(总_116_bo_2C4) ) && 总_242_do_21C4_si99[总_328_in_3100]<NormalizeDouble(MarketInfo(总_336_st_3130,MODE_BID) - 总_122_in_2DC * 总_229_do_1E00 - 总_221_do_1A80 - 总_337_do_3140,总_190_in_518) && MarketInfo(总_336_st_3130,MODE_BID)<子_8_do - 总_309_do_2898 )
           {
             子_7_do = NormalizeDouble(总_242_do_21C4_si99[总_328_in_3100],总_190_in_518) ;
             if ( 子_7_do<MarketInfo(总_336_st_3130,MODE_BID) - 总_221_do_1A80 )
             {
               总_230_in_1E08 = OrderModify(子_9_lo,子_10_do,子_7_do,子_8_do,0,0xFFFFFFFF) ;
               if ( 总_230_in_1E08 <= 0 )
               {
                 Print("error: \'" + lizong_21(MT4_LastError()) + "\' when modifying stoploss"); 
               }
               子_2_bo = true ;
             }
           }
           if ( 总_113_do_2A8>0.0 && MarketInfo(总_336_st_3130,MODE_BID)>NormalizeDouble(总_113_do_2A8 * 总_229_do_1E00 + 子_10_do,总_190_in_518) && NormalizeDouble(总_114_do_2B0 * 总_229_do_1E00 + 子_10_do,总_190_in_518)>子_7_do + 总_337_do_3140 && MarketInfo(总_336_st_3130,MODE_BID)>NormalizeDouble(总_114_do_2B0 * 总_229_do_1E00 + 子_10_do + 总_221_do_1A80,总_190_in_518) && MarketInfo(总_336_st_3130,MODE_BID)<子_8_do - 总_309_do_2898 )
           {
             子_7_do = NormalizeDouble(总_114_do_2B0 * 总_229_do_1E00 + 子_10_do,总_190_in_518) ;
             if ( 子_7_do<MarketInfo(总_336_st_3130,MODE_BID) - 总_221_do_1A80 )
             {
               总_230_in_1E08 = OrderModify(子_9_lo,子_10_do,子_7_do,子_8_do,0,0xFFFFFFFF) ;
               if ( 总_230_in_1E08 <= 0 )
               {
                 Print("error when setting breakeven: \'" + lizong_21(MT4_LastError()) + "\' ..\'Exit_BE_start\' to close to \'Exit_BE_extra_pips\' ..trying again!"); 
               }
               子_2_bo = true ;
             }
           }
           if ( !(子_2_bo) && ( 总_128_in_314 == 1 || (总_128_in_314 == 2 && 总_131_do_328 * 总_229_do_1E00 + 子_7_do<=总_132_do_330 * 总_229_do_1E00 + (子_5_do + 总_1_do_0)) ) )
           {
             总_250_in_2518 ++;
             if ( MarketInfo(总_336_st_3130,MODE_BID)>总_131_do_328 * 总_229_do_1E00 + 子_7_do + 总_221_do_1A80 && MarketInfo(总_336_st_3130,MODE_BID)<子_8_do - 总_309_do_2898 && ( 总_129_do_318==0.0 || MarketInfo(总_336_st_3130,MODE_BID)>总_247_do_2500 * 总_229_do_1E00 + 子_5_do ) && 总_250_in_2518 >= 总_130_in_320 && NormalizeDouble(总_131_do_328 * 总_229_do_1E00 + 子_7_do,总_190_in_518)>子_7_do )
             {
               总_250_in_2518 = 0 ;
               子_7_do = NormalizeDouble(总_131_do_328 * 总_229_do_1E00 + 子_7_do,总_190_in_518) ;
               OrderModify(子_9_lo,子_10_do,子_7_do,子_8_do,0,0xFFFFFFFF); 
               子_2_bo = true ;
             }
           }
           总_191_do_520 = 子_7_do ;
           if ( MarketInfo(总_336_st_3130,MODE_BID)<子_7_do )
           {
             Print("Closing with virtual SL"); 
             RefreshRates(); 
             OrderClose(子_9_lo,子_12_do,MarketInfo(总_336_st_3130,MODE_BID),(int)总_1_do_0,0xFFFFFFFF); 
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
           if ( MarketInfo(总_336_st_3130,MODE_BID)<=子_4_do )
           {
             RefreshRates(); 
             OrderClose(子_9_lo,子_12_do,MarketInfo(总_336_st_3130,MODE_BID),(int)总_1_do_0,0xFFFFFFFF); 
             return(true); 
           }
           子_28_in = (int)(TimeCurrent() - 总_319_da_28E0) ;
           if ( 子_28_in >= 总_65_in_150 )
           {
             if ( NormalizeDouble(总_191_do_520,总_190_in_518)>子_7_do + 总_337_do_3140 )
             {
               OrderModify(子_9_lo,子_10_do,NormalizeDouble(总_191_do_520,总_190_in_518),子_8_do,0,0xFFFFFFFF); 
             }
             总_319_da_28E0 = TimeCurrent() ;
           }
           if ( 总_125_do_2F8>0.0 && TimeCurrent() >= 子_13_da + 总_304_in_287C && MarketInfo(总_336_st_3130,MODE_BID)>总_126_do_300 * 总_229_do_1E00 + (总_191_do_520 + 总_337_do_3140) && MarketInfo(总_336_st_3130,MODE_BID)<子_8_do - 总_309_do_2898 )
           {
             子_2_bo = true ;
             总_191_do_520 = MarketInfo(总_336_st_3130,MODE_BID) - 总_126_do_300 * 总_229_do_1E00 ;
           }
           if ( 总_103_do_250>0.0 && MarketInfo(总_336_st_3130,MODE_BID)>(总_103_do_250 + 总_106_do_268) * 总_229_do_1E00 + (总_191_do_520 + 总_337_do_3140) && MarketInfo(总_336_st_3130,MODE_BID)>总_104_do_258 * 总_229_do_1E00 + 子_5_do && 总_191_do_520<总_105_do_260 * 总_229_do_1E00 + 子_10_do )
           {
             子_2_bo = true ;
             总_191_do_520 = MarketInfo(总_336_st_3130,MODE_BID) - 总_103_do_250 * 总_229_do_1E00 ;
             子_29_do = NormalizeDouble(总_107_do_270 / 100.0 * 总_223_do_1AC4_si99[总_328_in_3100],2) ;
             if ( 子_29_do<子_12_do && 子_29_do>=MarketInfo(总_336_st_3130,MODE_LOTSTEP) )
             {
               OrderClose(子_9_lo,子_29_do,MarketInfo(总_336_st_3130,MODE_BID),(int)总_38_do_C0,Red); 
               return(true); 
             }
           }
           if ( 子_19_bo && 总_39_in_C8 == 1 && 总_41_do_D8>0.0 && MarketInfo(总_336_st_3130,MODE_BID)>总_41_do_D8 * 总_229_do_1E00 + (总_191_do_520 + 总_337_do_3140) && MarketInfo(总_336_st_3130,MODE_BID)>总_40_do_D0 * 总_229_do_1E00 + 子_17_do && MarketInfo(总_336_st_3130,MODE_BID)<子_8_do - 总_309_do_2898 && 总_191_do_520<总_42_do_E0 * 总_229_do_1E00 + 子_10_do )
           {
             Print("Slippage control active"); 
             子_2_bo = true ;
             总_191_do_520 = MarketInfo(总_336_st_3130,MODE_BID) - 总_41_do_D8 * 总_229_do_1E00 ;
           }
           if ( 总_119_in_2D0 >  0 && 总_120_in_2D4 >= 0 && 总_242_do_21C4_si99[总_328_in_3100]>总_191_do_520 + 总_221_do_1A80 + 总_337_do_3140 && ( 总_242_do_21C4_si99[总_328_in_3100]<子_10_do || !(总_116_bo_2C4) ) && 总_242_do_21C4_si99[总_328_in_3100]<MarketInfo(总_336_st_3130,MODE_BID) - 总_122_in_2DC * 总_229_do_1E00 - 总_221_do_1A80 - 总_337_do_3140 && MarketInfo(总_336_st_3130,MODE_BID)<子_8_do - 总_309_do_2898 )
           {
             总_191_do_520 = 总_242_do_21C4_si99[总_328_in_3100] ;
             子_2_bo = true ;
           }
           if ( 总_113_do_2A8>0.0 && 总_63_in_140 == 3 && MarketInfo(总_336_st_3130,MODE_BID)>总_113_do_2A8 * 总_229_do_1E00 + 子_10_do && 总_114_do_2B0 * 总_229_do_1E00 + 子_10_do>子_7_do + 总_337_do_3140 && MarketInfo(总_336_st_3130,MODE_BID)>总_114_do_2B0 * 总_229_do_1E00 + 子_10_do + 总_221_do_1A80 && MarketInfo(总_336_st_3130,MODE_BID)<子_8_do - 总_309_do_2898 && NormalizeDouble(总_114_do_2B0 * 总_229_do_1E00 + 子_10_do,总_190_in_518)>OrderStopLoss() )
           {
             总_191_do_520 = NormalizeDouble(总_114_do_2B0 * 总_229_do_1E00 + 子_10_do,总_190_in_518) ;
             总_230_in_1E08 = OrderModify(子_9_lo,子_10_do,总_191_do_520,子_8_do,0,0xFFFFFFFF) ;
             if ( 总_230_in_1E08 <= 0 )
             {
               Print("error when setting breakeven: \'" + lizong_21(MT4_LastError()) + "\' ..\'Exit_BE_start\' to close to \'Exit_BE_extra_pips\' ..trying again!"); 
             }
             子_2_bo = true ;
           }
           if ( 总_113_do_2A8>0.0 && 总_63_in_140 == 2 && MarketInfo(总_336_st_3130,MODE_BID)>总_113_do_2A8 * 总_229_do_1E00 + 子_10_do && 总_114_do_2B0 * 总_229_do_1E00 + 子_10_do>总_191_do_520 + 总_337_do_3140 && MarketInfo(总_336_st_3130,MODE_BID)>总_114_do_2B0 * 总_229_do_1E00 + 子_10_do + 总_221_do_1A80 && MarketInfo(总_336_st_3130,MODE_BID)<子_8_do - 总_309_do_2898 )
           {
             总_191_do_520 = 总_114_do_2B0 * 总_229_do_1E00 + 子_10_do ;
             子_2_bo = true ;
           }
           if ( !(子_2_bo) && ( 总_128_in_314 == 1 || (总_128_in_314 == 2 && 总_131_do_328 * 总_229_do_1E00 + 总_191_do_520<=总_132_do_330 * 总_229_do_1E00 + (子_5_do + 总_1_do_0)) ) )
           {
             总_250_in_2518 ++;
             if ( MarketInfo(总_336_st_3130,MODE_BID)>总_131_do_328 * 总_229_do_1E00 + 总_191_do_520 + 总_221_do_1A80 && MarketInfo(总_336_st_3130,MODE_BID)<子_8_do - 总_309_do_2898 && ( 总_129_do_318==0.0 || MarketInfo(总_336_st_3130,MODE_BID)>总_247_do_2500 * 总_229_do_1E00 + 子_5_do ) && 总_250_in_2518 >= 总_130_in_320 )
             {
               总_250_in_2518 = 0 ;
               总_191_do_520 = 总_131_do_328 * 总_229_do_1E00 + 总_191_do_520 ;
               子_2_bo = true ;
             }
           }
           if ( MarketInfo(总_336_st_3130,MODE_BID)<=总_191_do_520 )
           {
             RefreshRates(); 
             OrderClose(子_9_lo,子_12_do,MarketInfo(总_336_st_3130,MODE_BID),(int)总_1_do_0,0xFFFFFFFF); 
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

 子_4_do = 0.0 ;
 子_5_do = 0.0 ;
 for (子_6_in = 0 ; 子_6_in < MT4OrdersTotal() ; 子_6_in ++)
 {
   if ( OrderSelect(子_6_in,0,0) == true )
   {
     子_2_bo = false ;
     子_7_do = NormalizeDouble(OrderStopLoss(),总_190_in_518) ;
     子_8_do = NormalizeDouble(OrderTakeProfit(),总_190_in_518) ;
     子_9_lo = OrderTicket() ;
     子_10_do = NormalizeDouble(OrderOpenPrice(),总_190_in_518) ;
     子_11_st = OrderComment() ;
     子_12_do = OrderLots() ;
     子_13_da = OrderOpenTime() ;
     子_14_in = OrderType() ;
     子_15_in = OrderMagicNumber() ;
     子_16_st = OrderSymbol() ;
     if ( ( 子_14_in == 5 || 子_14_in == 3 ) && 总_69_in_160 == 2 && ( 总_95_in_204 == 0 || (总_95_in_204 == 1 && 子_16_st == 总_336_st_3130) ) && ( 子_15_in == 总_96_in_208 || 总_96_in_208 == 0 ) && ( 子_11_st == 总_97_st_210 || 总_97_st_210 == "" ) )
     {
       if ( ( 子_7_do==0.0 || 子_7_do==0.0 ) )
       {
         子_7_do = NormalizeDouble(总_100_do_230 * 总_229_do_1E00 + 子_10_do,总_190_in_518) ;
         OrderModify(子_9_lo,子_10_do,子_7_do,子_8_do,0,Green); 
       }
       if ( ( 子_8_do==0.0 || 子_8_do==0.0 ) )
       {
         子_8_do = NormalizeDouble(子_10_do - 总_101_do_238 * 总_229_do_1E00,总_190_in_518) ;
         OrderModify(子_9_lo,子_10_do,子_7_do,子_8_do,0,Green); 
       }
     }
     if ( 子_14_in == 1 && ( ( 子_15_in == 总_93_in_1F0 && 总_69_in_160 == 1 && 子_16_st == 总_336_st_3130 ) || (总_69_in_160 == 2 && ( 总_95_in_204 == 0 || (总_95_in_204 == 1 && 子_16_st == 总_336_st_3130) ) && ( 子_15_in == 总_96_in_208 || 总_96_in_208 == 0 ) && (子_11_st == 总_97_st_210 || 总_97_st_210 == "")) ) )
     {
       if ( ( 子_7_do==0.0 || 子_7_do==0.0 ) )
       {
         子_7_do = NormalizeDouble(总_100_do_230 * 总_229_do_1E00 + 子_10_do,总_190_in_518) ;
         OrderModify(子_9_lo,子_10_do,子_7_do,子_8_do,0,Green); 
       }
       if ( ( 子_8_do==0.0 || 子_8_do==0.0 ) )
       {
         子_8_do = NormalizeDouble(子_10_do - 总_101_do_238 * 总_229_do_1E00,总_190_in_518) ;
         OrderModify(子_9_lo,子_10_do,子_7_do,子_8_do,0,Green); 
       }
       if ( 总_53_bo_11C && iTime(总_336_st_3130,MT4Period(总_52_in_118),总_51_in_114) <= 子_13_da && iTime(总_336_st_3130,MT4Period(总_52_in_118),0) >  子_13_da && iClose(总_336_st_3130,MT4Period(总_52_in_118),1)>iOpen(总_336_st_3130,MT4Period(总_52_in_118),1) && iClose(总_336_st_3130,MT4Period(总_52_in_118),1)>子_10_do )
       {
         OrderClose(子_9_lo,子_12_do,MarketInfo(总_336_st_3130,MODE_ASK),0,Red); 
         Print("closing candle confirmation"); 
       }
       if ( 总_55_bo_124 && iTime(总_336_st_3130,MT4Period(总_54_in_120),总_51_in_114) <= 子_13_da && iTime(总_336_st_3130,MT4Period(总_54_in_120),0) >  子_13_da && iClose(总_336_st_3130,MT4Period(总_54_in_120),1)>iOpen(总_336_st_3130,MT4Period(总_54_in_120),1) && iClose(总_336_st_3130,MT4Period(总_54_in_120),1)>子_10_do )
       {
         OrderClose(子_9_lo,子_12_do,MarketInfo(总_336_st_3130,MODE_ASK),0,Red); 
         Print("closing candle confirmation"); 
       }
       if ( 总_57_bo_12C && iTime(总_336_st_3130,MT4Period(总_56_in_128),总_51_in_114) <= 子_13_da && iTime(总_336_st_3130,MT4Period(总_56_in_128),0) >  子_13_da && iClose(总_336_st_3130,MT4Period(总_56_in_128),1)>iOpen(总_336_st_3130,MT4Period(总_56_in_128),1) && iClose(总_336_st_3130,MT4Period(总_56_in_128),1)>子_10_do )
       {
         OrderClose(子_9_lo,子_12_do,MarketInfo(总_336_st_3130,MODE_ASK),0,Red); 
         Print("closing candle confirmation"); 
       }
       if ( 总_59_bo_134 && iTime(总_336_st_3130,MT4Period(总_58_in_130),总_51_in_114) <= 子_13_da && iTime(总_336_st_3130,MT4Period(总_58_in_130),0) >  子_13_da && iClose(总_336_st_3130,MT4Period(总_58_in_130),1)>iOpen(总_336_st_3130,MT4Period(总_58_in_130),1) && iClose(总_336_st_3130,MT4Period(总_58_in_130),1)>子_10_do )
       {
         OrderClose(子_9_lo,子_12_do,MarketInfo(总_336_st_3130,MODE_ASK),0,Red); 
         Print("closing candle confirmation"); 
       }
       if ( 总_61_bo_13C && iTime(总_336_st_3130,MT4Period(总_60_in_138),总_51_in_114) <= 子_13_da && iTime(总_336_st_3130,MT4Period(总_60_in_138),0) >  子_13_da && iClose(总_336_st_3130,MT4Period(总_60_in_138),1)>iOpen(总_336_st_3130,MT4Period(总_60_in_138),1) && iClose(总_336_st_3130,MT4Period(总_60_in_138),1)>子_10_do )
       {
         OrderClose(子_9_lo,子_12_do,MarketInfo(总_336_st_3130,MODE_ASK),0,Red); 
         Print("closing candle confirmation"); 
       }
       总_247_do_2500 = 总_129_do_318 ;
       if ( 总_133_in_338 >  0 && TimeCurrent() >  子_13_da + 总_133_in_338 * 60 )
       {
         总_247_do_2500 = 总_134_do_340 ;
       }
       临_in_1 = 总_190_in_518;
       临_lo_2 = 子_9_lo;
       for (临_in_3 = 0 ; 临_in_3 < 100 ; 临_in_3=临_in_3 + 1)
       {
         if ( !(总_198_do_1070_si100si2[临_in_3][0]==临_lo_2) )   continue;
         临_do_4 = 总_198_do_1070_si100si2[临_in_3][1];
         break;
         
       }
       临_do_4 = 0.0;
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
           Print("Slippage Mode 2 active"); 
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
       if ( 子_7_do>NormalizeDouble((总_100_do_230 + 总_64_do_148) * 总_229_do_1E00 + 子_10_do + 总_1_do_0,总_190_in_518) )
       {
         子_7_do = NormalizeDouble((总_100_do_230 + 总_64_do_148) * 总_229_do_1E00 + 子_10_do + 总_1_do_0,总_190_in_518) ;
         OrderModify(子_9_lo,子_10_do,子_7_do,子_8_do,0,0xFFFFFFFF); 
       }
       if ( MarketInfo(总_336_st_3130,MODE_ASK)>(总_100_do_230 + 总_64_do_148) * 总_229_do_1E00 + 子_10_do + 总_1_do_0 )
       {
         RefreshRates(); 
         OrderClose(OrderTicket(),OrderLots(),MarketInfo(总_336_st_3130,MODE_ASK),(int)总_1_do_0,Red); 
         return(true); 
       }
       子_20_bo = false ;
       if ( 总_159_bo_464 )
       {
         临_lo_8 = 子_9_lo;
         临_in_9 = 0;
         for (临_in_10 = MT4OrdersTotal() ; 临_in_10 >= 0 ; 临_in_10=临_in_10 - 1)
         {
           if ( OrderSelect(临_in_10,0,0) != true || OrderMagicNumber() != 总_169_in_4AC || OrderSymbol() != 总_336_st_3130 )   continue;
           临_st_11 = OrderComment();
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
             临_do_12 = AccountEquity();
             if ( 临_do_12>AccountBalance() + 总_163_do_480 )
             {
               for (临_in_13 = MT4OrdersTotal() ; 临_in_13 >= 0 ; 临_in_13=临_in_13 - 1)
               {
                 if ( OrderSelect(临_in_13,0,0) != true )   continue;
                 
                 if ( ( OrderMagicNumber() != 总_93_in_1F0 && OrderMagicNumber() != 总_169_in_4AC && OrderMagicNumber() != 总_168_in_4A8 ) )   continue;
                 
                 if ( OrderType() == 0 )
                 {
                   OrderClose(OrderTicket(),OrderLots(),MarketInfo(总_336_st_3130,MODE_BID),(int)总_38_do_C0,Red); 
                 }
                 if ( OrderType() != 1 )   continue;
                 OrderClose(OrderTicket(),OrderLots(),MarketInfo(总_336_st_3130,MODE_ASK),(int)总_38_do_C0,Red); 
                 
               }
             }
           }
           if ( 子_21_do>0.0 )
           {
             临_lo_14 = 子_9_lo;
             临_do_15 = 0.0;
             for (临_in_16 = MT4OrdersTotal() ; 临_in_16 >= 0 ; 临_in_16=临_in_16 - 1)
             {
               if ( OrderSelect(临_in_16,0,0) != true )   continue;
               临_lo_17 = OrderTicket();
               if ( 临_lo_17 != 临_lo_14 )
               {
                 临_st_11 = OrderComment();
               if ( 临_st_11 != IntegerToString(临_lo_14,0,32) )   continue;
               }
               临_do_15 = 临_do_15 + OrderProfit();
               
             }
             if ( 临_do_15>总_163_do_480 )
             {
               Print("Closing zone"); 
               临_lo_18 = 子_9_lo;
               for (临_in_19 = MT4OrdersTotal() ; 临_in_19 >= 0 ; 临_in_19=临_in_19 - 1)
               {
                 if ( OrderSelect(临_in_19,0,0) != true )   continue;
                 
                 if ( OrderMagicNumber() == 总_93_in_1F0 && OrderTicket() == 临_lo_18 )
                 {
                   OrderClose(OrderTicket(),OrderLots(),MarketInfo(总_336_st_3130,MODE_ASK),3,Red); 
                 }
                 if ( OrderMagicNumber() != 总_169_in_4AC )   continue;
                 临_st_11 = OrderComment();
                 if ( 临_st_11 != IntegerToString(临_lo_18,0,32) )   continue;
                 
                 if ( OrderType() == 0 )
                 {
                   OrderClose(OrderTicket(),OrderLots(),MarketInfo(总_336_st_3130,MODE_BID),(int)总_38_do_C0,Red); 
                 }
                 if ( OrderType() != 1 )   continue;
                 OrderClose(OrderTicket(),OrderLots(),MarketInfo(总_336_st_3130,MODE_ASK),(int)总_38_do_C0,Red); 
                 
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
               if ( MarketInfo(总_336_st_3130,MODE_BID)<子_17_do )
               {
                 if ( 子_21_do>=总_166_in_498 )
                 {
                   for (临_in_20 = MT4OrdersTotal() ; 临_in_20 >= 0 ; 临_in_20=临_in_20 - 1)
                   {
                     if ( OrderSelect(临_in_20,0,0) != true )   continue;
                     
                     if ( OrderMagicNumber() == 总_93_in_1F0 && OrderTicket() == 子_9_lo )
                     {
                       OrderClose(OrderTicket(),OrderLots(),MarketInfo(总_336_st_3130,MODE_ASK),3,Red); 
                     }
                     if ( OrderMagicNumber() != 总_169_in_4AC )   continue;
                     临_st_11 = OrderComment();
                     if ( 临_st_11 != IntegerToString(子_9_lo,0,32) )   continue;
                     
                     if ( OrderType() == 0 )
                     {
                       OrderClose(OrderTicket(),OrderLots(),MarketInfo(总_336_st_3130,MODE_BID),(int)总_38_do_C0,Red); 
                     }
                     if ( OrderType() != 1 )   continue;
                     OrderClose(OrderTicket(),OrderLots(),MarketInfo(总_336_st_3130,MODE_ASK),(int)总_38_do_C0,Red); 
                     
                   }
                 }
                 else
                 {
                   OrderSend(总_336_st_3130,1,子_23_do,MarketInfo(总_336_st_3130,MODE_BID),(int)总_38_do_C0,0.0,0.0,IntegerToString(子_9_lo,0,32),总_169_in_4AC,0,Green); 
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
               if ( MarketInfo(总_336_st_3130,MODE_ASK)>子_25_do )
               {
                 if ( 子_21_do>=总_166_in_498 )
                 {
                   for (临_in_21 = MT4OrdersTotal() ; 临_in_21 >= 0 ; 临_in_21=临_in_21 - 1)
                   {
                     if ( OrderSelect(临_in_21,0,0) != true )   continue;
                     
                     if ( OrderMagicNumber() == 总_93_in_1F0 && OrderTicket() == 子_9_lo )
                     {
                       OrderClose(OrderTicket(),OrderLots(),MarketInfo(总_336_st_3130,MODE_ASK),3,Red); 
                     }
                     if ( OrderMagicNumber() != 总_169_in_4AC )   continue;
                     临_st_22 = OrderComment();
                     if ( 临_st_22 != IntegerToString(子_9_lo,0,32) )   continue;
                     
                     if ( OrderType() == 0 )
                     {
                       OrderClose(OrderTicket(),OrderLots(),MarketInfo(总_336_st_3130,MODE_BID),(int)总_38_do_C0,Red); 
                     }
                     if ( OrderType() != 1 )   continue;
                     OrderClose(OrderTicket(),OrderLots(),MarketInfo(总_336_st_3130,MODE_ASK),(int)总_38_do_C0,Red); 
                     
                   }
                 }
                 else
                 {
                   OrderSend(总_336_st_3130,0,子_23_do,MarketInfo(总_336_st_3130,MODE_ASK),(int)总_38_do_C0,0.0,0.0,IntegerToString(子_9_lo,0,32),总_169_in_4AC,0,Green); 
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
           if ( MarketInfo(总_336_st_3130,MODE_ASK)>子_4_do )
           {
             Print("Closing with virtual SL"); 
             RefreshRates(); 
             OrderClose(子_9_lo,子_12_do,MarketInfo(总_336_st_3130,MODE_ASK),(int)总_1_do_0,0xFFFFFFFF); 
             return(true); 
           }
           if ( 总_125_do_2F8>0.0 && TimeCurrent() >= 子_13_da + 总_304_in_287C && MarketInfo(总_336_st_3130,MODE_ASK)<子_7_do - 总_337_do_3140 - 总_126_do_300 * 总_229_do_1E00 && MarketInfo(总_336_st_3130,MODE_ASK)>子_8_do + 总_309_do_2898 && NormalizeDouble(MarketInfo(总_336_st_3130,MODE_ASK) + 总_126_do_300 * 总_229_do_1E00,总_190_in_518)<子_7_do )
           {
             子_7_do = NormalizeDouble(MarketInfo(总_336_st_3130,MODE_ASK) + 总_126_do_300 * 总_229_do_1E00,总_190_in_518) ;
             if ( 子_7_do>MarketInfo(总_336_st_3130,MODE_ASK) + 总_221_do_1A80 )
             {
               总_230_in_1E08 = OrderModify(子_9_lo,子_10_do,子_7_do,子_8_do,0,0xFFFFFFFF) ;
               if ( 总_230_in_1E08 <= 0 )
               {
                 Print("TrailStop error: \'" + lizong_21(MT4_LastError()) + "\' when setting trailing Exit_TrailSL_after_X_Minutes_size loss.  Trying again!"); 
               }
               子_2_bo = true ;
             }
           }
           if ( 总_103_do_250>0.0 && MarketInfo(总_336_st_3130,MODE_ASK)<子_7_do - 总_337_do_3140 - (总_103_do_250 + 总_106_do_268) * 总_229_do_1E00 && MarketInfo(总_336_st_3130,MODE_ASK)<子_5_do - 总_104_do_258 * 总_229_do_1E00 && MarketInfo(总_336_st_3130,MODE_ASK)>子_8_do + 总_309_do_2898 && 子_7_do>子_10_do - 总_105_do_260 * 总_229_do_1E00 && NormalizeDouble(总_103_do_250 * 总_229_do_1E00 + MarketInfo(总_336_st_3130,MODE_ASK),总_190_in_518)<子_7_do )
           {
             子_7_do = NormalizeDouble(MarketInfo(总_336_st_3130,MODE_ASK) + 总_103_do_250 * 总_229_do_1E00,总_190_in_518) ;
             if ( 子_7_do>MarketInfo(总_336_st_3130,MODE_ASK) + 总_221_do_1A80 )
             {
               总_230_in_1E08 = OrderModify(子_9_lo,子_10_do,子_7_do,子_8_do,0,0xFFFFFFFF) ;
               if ( 总_230_in_1E08 <= 0 )
               {
                 Print("TrailStop error: \'" + lizong_21(MT4_LastError()) + "\' when setting trailing Exit_stop loss.  Trying again!"); 
               }
               else
               {
                 子_26_do = NormalizeDouble(总_107_do_270 / 100.0 * 总_223_do_1AC4_si99[总_328_in_3100],2) ;
                 if ( 子_26_do<子_12_do && 子_26_do>=MarketInfo(总_336_st_3130,MODE_LOTSTEP) )
                 {
                   OrderClose(子_9_lo,子_26_do,MarketInfo(总_336_st_3130,MODE_ASK),(int)总_38_do_C0,Red); 
                   return(true); 
                 }
               }
               子_2_bo = true ;
             }
           }
           if ( 总_108_do_278>0.0 && MarketInfo(总_336_st_3130,MODE_BID)>NormalizeDouble(总_108_do_278 * 总_229_do_1E00 + (子_8_do + 总_337_do_3140),总_190_in_518) && MarketInfo(总_336_st_3130,MODE_BID)>NormalizeDouble(总_109_do_280 * 总_229_do_1E00 + 子_5_do,总_190_in_518) && MarketInfo(总_336_st_3130,MODE_BID)>子_8_do + 总_309_do_2898 )
           {
             子_8_do = NormalizeDouble(MarketInfo(总_336_st_3130,MODE_BID) - 总_108_do_278 * 总_229_do_1E00,总_190_in_518) ;
             if ( 子_8_do<MarketInfo(总_336_st_3130,MODE_BID) - 总_221_do_1A80 )
             {
               总_230_in_1E08 = OrderModify(子_9_lo,子_10_do,子_7_do,子_8_do,0,0xFFFFFFFF) ;
               if ( 总_230_in_1E08 <= 0 )
               {
                 Print("TrailStop error: \'" + lizong_21(MT4_LastError()) + "\' when setting trailing Exit_TP.  Trying again!"); 
               }
               else
               {
                 子_27_do = NormalizeDouble(总_107_do_270 / 100.0 * 总_223_do_1AC4_si99[总_328_in_3100],2) ;
                 if ( 子_27_do<子_12_do && 子_27_do>=SymbolInfoDouble(总_336_st_3130,34) )
                 {
                   OrderClose(子_9_lo,子_27_do,MarketInfo(总_336_st_3130,MODE_ASK),(int)总_38_do_C0,Red); 
                   return(true); 
                 }
               }
               子_2_bo = true ;
             }
           }
           if ( 子_19_bo && 总_39_in_C8 == 1 && 总_41_do_D8>0.0 && MarketInfo(总_336_st_3130,MODE_ASK)<子_7_do - 总_337_do_3140 - 总_41_do_D8 * 总_229_do_1E00 && MarketInfo(总_336_st_3130,MODE_ASK)<子_17_do - 总_40_do_D0 * 总_229_do_1E00 && MarketInfo(总_336_st_3130,MODE_ASK)>子_8_do + 总_309_do_2898 && 子_7_do>子_10_do - 总_42_do_E0 * 总_229_do_1E00 && NormalizeDouble(MarketInfo(总_336_st_3130,MODE_ASK) + 总_41_do_D8 * 总_229_do_1E00,总_190_in_518)<子_7_do )
           {
             子_7_do = NormalizeDouble(MarketInfo(总_336_st_3130,MODE_ASK) + 总_41_do_D8 * 总_229_do_1E00,总_190_in_518) ;
             if ( 子_7_do>MarketInfo(总_336_st_3130,MODE_ASK) + 总_221_do_1A80 )
             {
               总_230_in_1E08 = OrderModify(子_9_lo,子_10_do,子_7_do,子_8_do,0,0xFFFFFFFF) ;
               if ( 总_230_in_1E08 <= 0 )
               {
                 Print("TrailStop error: \'" + lizong_21(MT4_LastError()) + "\' when setting Slip TL.  Trying again!"); 
               }
               else
               {
                 Print("Slippage controle active"); 
               }
               子_2_bo = true ;
             }
           }
           if ( 总_119_in_2D0 >  0 && 总_120_in_2D4 >= 0 && UseHL_TrailingSL && 总_241_do_1E78_si99[总_328_in_3100]<子_7_do - 总_221_do_1A80 - 总_337_do_3140 && 总_241_do_1E78_si99[总_328_in_3100]>总_121_in_2D8 * 总_229_do_1E00 + MarketInfo(总_336_st_3130,MODE_ASK) && ( 总_241_do_1E78_si99[总_328_in_3100]>子_10_do || !(总_116_bo_2C4) ) && 总_241_do_1E78_si99[总_328_in_3100]>总_122_in_2DC * 总_229_do_1E00 + MarketInfo(总_336_st_3130,MODE_ASK) + 总_221_do_1A80 + 总_337_do_3140 && MarketInfo(总_336_st_3130,MODE_ASK)>子_8_do + 总_309_do_2898 && NormalizeDouble(总_241_do_1E78_si99[总_328_in_3100],总_190_in_518)<子_7_do )
           {
             子_7_do = NormalizeDouble(总_241_do_1E78_si99[总_328_in_3100],总_190_in_518) ;
             if ( 子_7_do>MarketInfo(总_336_st_3130,MODE_ASK) + 总_221_do_1A80 )
             {
               总_230_in_1E08 = OrderModify(子_9_lo,子_10_do,子_7_do,子_8_do,0,0xFFFFFFFF) ;
               if ( 总_230_in_1E08 <= 0 )
               {
                 Print("error: \'" + lizong_21(MT4_LastError()) + "\' when modifying stoploss"); 
               }
               子_2_bo = true ;
             }
           }
           if ( 总_113_do_2A8>0.0 && MarketInfo(总_336_st_3130,MODE_ASK)<子_10_do - 总_113_do_2A8 * 总_229_do_1E00 && 子_10_do - 总_114_do_2B0 * 总_229_do_1E00<子_7_do - 总_337_do_3140 && MarketInfo(总_336_st_3130,MODE_ASK)<子_10_do - 总_114_do_2B0 * 总_229_do_1E00 - 总_221_do_1A80 && MarketInfo(总_336_st_3130,MODE_ASK)>子_8_do + 总_309_do_2898 && NormalizeDouble(子_10_do - 总_114_do_2B0 * 总_229_do_1E00,总_190_in_518)<子_7_do )
           {
             子_7_do = NormalizeDouble(子_10_do - 总_114_do_2B0 * 总_229_do_1E00,总_190_in_518) ;
             if ( 子_7_do>MarketInfo(总_336_st_3130,MODE_ASK) + 总_221_do_1A80 )
             {
               总_230_in_1E08 = OrderModify(子_9_lo,子_10_do,子_7_do,子_8_do,0,0xFFFFFFFF) ;
               if ( 总_230_in_1E08 <= 0 )
               {
                 Print("error when setting breakeven: \'" + lizong_21(MT4_LastError()) + "\' ..\'Exit_BE_start\' to close to \'Exit_BE_extra_pips\' ..trying again!"); 
               }
               子_2_bo = true ;
             }
           }
           if ( !(子_2_bo) && ( 总_128_in_314 == 1 || (总_128_in_314 == 2 && 子_7_do - 总_131_do_328 * 总_229_do_1E00>=子_5_do - 总_1_do_0 - 总_132_do_330 * 总_229_do_1E00) ) )
           {
             总_250_in_2518 ++;
             if ( MarketInfo(总_336_st_3130,MODE_ASK)<子_7_do - 总_131_do_328 * 总_229_do_1E00 - 总_221_do_1A80 && MarketInfo(总_336_st_3130,MODE_ASK)>子_8_do + 总_309_do_2898 && ( 总_129_do_318==0.0 || MarketInfo(总_336_st_3130,MODE_ASK)<子_5_do - 总_247_do_2500 * 总_229_do_1E00 ) && 总_250_in_2518 >= 总_130_in_320 && NormalizeDouble(子_7_do - 总_131_do_328 * 总_229_do_1E00,总_190_in_518)<子_7_do )
             {
               总_250_in_2518 = 0 ;
               子_7_do = NormalizeDouble(子_7_do - 总_131_do_328 * 总_229_do_1E00,总_190_in_518) ;
               OrderModify(子_9_lo,子_10_do,子_7_do,子_8_do,0,0xFFFFFFFF); 
               子_2_bo = true ;
             }
           }
           总_191_do_520 = 子_7_do ;
           if ( MarketInfo(总_336_st_3130,MODE_ASK)>子_7_do )
           {
             Print("Closing with virtual SL"); 
             RefreshRates(); 
             OrderClose(子_9_lo,子_12_do,MarketInfo(总_336_st_3130,MODE_ASK),(int)总_1_do_0,0xFFFFFFFF); 
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
           if ( MarketInfo(总_336_st_3130,MODE_ASK)>=子_4_do )
           {
             RefreshRates(); 
             OrderClose(子_9_lo,子_12_do,MarketInfo(总_336_st_3130,MODE_ASK),(int)总_1_do_0,0xFFFFFFFF); 
             return(true); 
           }
           子_28_in = (int)(TimeCurrent() - 总_319_da_28E0) ;
           if ( 子_28_in >= 总_65_in_150 )
           {
             if ( NormalizeDouble(总_191_do_520,总_190_in_518)<子_7_do - 总_337_do_3140 )
             {
               OrderModify(子_9_lo,子_10_do,NormalizeDouble(总_191_do_520,总_190_in_518),子_8_do,0,0xFFFFFFFF); 
             }
             总_319_da_28E0 = TimeCurrent() ;
           }
           if ( 总_125_do_2F8>0.0 && TimeCurrent() >= 子_13_da + 总_304_in_287C && MarketInfo(总_336_st_3130,MODE_ASK)<总_191_do_520 - 总_337_do_3140 - 总_126_do_300 * 总_229_do_1E00 && MarketInfo(总_336_st_3130,MODE_ASK)>子_8_do + 总_309_do_2898 )
           {
             总_191_do_520 = MarketInfo(总_336_st_3130,MODE_ASK) + 总_126_do_300 * 总_229_do_1E00 ;
             子_2_bo = true ;
           }
           if ( 总_103_do_250>0.0 && MarketInfo(总_336_st_3130,MODE_ASK)<总_191_do_520 - 总_337_do_3140 - (总_103_do_250 + 总_106_do_268) * 总_229_do_1E00 && MarketInfo(总_336_st_3130,MODE_ASK)<子_5_do - 总_104_do_258 * 总_229_do_1E00 && 总_191_do_520>子_10_do - 总_105_do_260 * 总_229_do_1E00 )
           {
             总_191_do_520 = 总_103_do_250 * 总_229_do_1E00 + MarketInfo(总_336_st_3130,MODE_ASK) ;
             子_29_do = NormalizeDouble(总_107_do_270 / 100.0 * 总_223_do_1AC4_si99[总_328_in_3100],2) ;
             if ( 子_29_do<子_12_do && 子_29_do>=MarketInfo(总_336_st_3130,MODE_LOTSTEP) )
             {
               OrderClose(子_9_lo,子_29_do,MarketInfo(总_336_st_3130,MODE_BID),(int)总_38_do_C0,Red); 
               return(true); 
             }
             子_2_bo = true ;
           }
           if ( 子_19_bo && 总_39_in_C8 == 1 && 总_41_do_D8>0.0 && MarketInfo(总_336_st_3130,MODE_ASK)<总_191_do_520 - 总_337_do_3140 - 总_41_do_D8 * 总_229_do_1E00 && MarketInfo(总_336_st_3130,MODE_ASK)<子_17_do - 总_40_do_D0 * 总_229_do_1E00 && MarketInfo(总_336_st_3130,MODE_ASK)>子_8_do + 总_309_do_2898 && 总_191_do_520>子_10_do - 总_42_do_E0 * 总_229_do_1E00 )
           {
             Print("Slippage controle active"); 
             子_2_bo = true ;
             总_191_do_520 = MarketInfo(总_336_st_3130,MODE_ASK) + 总_41_do_D8 * 总_229_do_1E00 ;
           }
           if ( 总_119_in_2D0 >  0 && 总_120_in_2D4 >= 0 && 总_241_do_1E78_si99[总_328_in_3100]<总_191_do_520 - 总_221_do_1A80 - 总_337_do_3140 && ( 总_241_do_1E78_si99[总_328_in_3100]>子_10_do || !(总_116_bo_2C4) ) && 总_241_do_1E78_si99[总_328_in_3100]>总_122_in_2DC * 总_229_do_1E00 + MarketInfo(总_336_st_3130,MODE_ASK) + 总_221_do_1A80 + 总_337_do_3140 && MarketInfo(总_336_st_3130,MODE_ASK)>子_8_do + 总_309_do_2898 )
           {
             总_191_do_520 = 总_241_do_1E78_si99[总_328_in_3100] ;
             子_2_bo = true ;
           }
           if ( 总_113_do_2A8>0.0 && 总_63_in_140 == 3 && MarketInfo(总_336_st_3130,MODE_ASK)<子_10_do - 总_113_do_2A8 * 总_229_do_1E00 && 子_10_do - 总_114_do_2B0 * 总_229_do_1E00<子_7_do - 总_337_do_3140 && MarketInfo(总_336_st_3130,MODE_ASK)<子_10_do - 总_114_do_2B0 * 总_229_do_1E00 - 总_221_do_1A80 && MarketInfo(总_336_st_3130,MODE_ASK)>子_8_do + 总_309_do_2898 && NormalizeDouble(子_10_do - 总_114_do_2B0 * 总_229_do_1E00,总_190_in_518)<总_191_do_520 )
           {
             总_191_do_520 = NormalizeDouble(子_10_do - 总_114_do_2B0 * 总_229_do_1E00,总_190_in_518) ;
             总_230_in_1E08 = OrderModify(子_9_lo,子_10_do,总_191_do_520,子_8_do,0,0xFFFFFFFF) ;
             if ( 总_230_in_1E08 <= 0 )
             {
               Print("error when setting breakeven: \'" + lizong_21(MT4_LastError()) + "\' ..\'Exit_BE_start\' to close to \'Exit_BE_extra_pips\' ..trying again!"); 
             }
             子_2_bo = true ;
           }
           if ( 总_113_do_2A8>0.0 && 总_63_in_140 == 2 && MarketInfo(总_336_st_3130,MODE_ASK)<子_10_do - 总_113_do_2A8 * 总_229_do_1E00 && 子_10_do - 总_114_do_2B0 * 总_229_do_1E00<总_191_do_520 - 总_337_do_3140 && MarketInfo(总_336_st_3130,MODE_ASK)<子_10_do - 总_114_do_2B0 * 总_229_do_1E00 - 总_221_do_1A80 && MarketInfo(总_336_st_3130,MODE_ASK)>子_8_do + 总_309_do_2898 )
           {
             总_191_do_520 = 子_10_do - 总_114_do_2B0 * 总_229_do_1E00 ;
             子_2_bo = true ;
           }
           if ( !(子_2_bo) && ( 总_128_in_314 == 1 || (总_128_in_314 == 2 && 总_191_do_520 - 总_131_do_328 * 总_229_do_1E00>=子_5_do - 总_1_do_0 - 总_132_do_330 * 总_229_do_1E00) ) )
           {
             总_250_in_2518 ++;
             if ( MarketInfo(总_336_st_3130,MODE_ASK)<总_191_do_520 - 总_131_do_328 * 总_229_do_1E00 - 总_221_do_1A80 && MarketInfo(总_336_st_3130,MODE_ASK)>子_8_do + 总_309_do_2898 && ( 总_129_do_318==0.0 || MarketInfo(总_336_st_3130,MODE_ASK)<子_5_do - 总_247_do_2500 * 总_229_do_1E00 ) && 总_250_in_2518 >= 总_130_in_320 )
             {
               总_250_in_2518 = 0 ;
               总_191_do_520 = 总_191_do_520 - 总_131_do_328 * 总_229_do_1E00 ;
               子_2_bo = true ;
             }
           }
           if ( MarketInfo(总_336_st_3130,MODE_ASK)>=总_191_do_520 )
           {
             RefreshRates(); 
             OrderClose(子_9_lo,子_12_do,MarketInfo(总_336_st_3130,MODE_ASK),(int)总_1_do_0,0xFFFFFFFF); 
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
 子_4_in = TimeHour(子_3_da) ;
 if ( TimeDayOfWeek(子_3_da) == 0 )
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
 if ( TimeDayOfWeek(子_3_da) == 1 )
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
 if ( TimeDayOfWeek(子_3_da) == 2 )
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
 if ( TimeDayOfWeek(子_3_da) == 3 )
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
 if ( TimeDayOfWeek(子_3_da) == 4 )
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
 if ( TimeDayOfWeek(子_3_da) == 5 )
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
 string lizong_21( int 木_0_in)
 {
  string    子_1_st;
//----- -----

 总_274_in_25D8 ++;
 switch(木_0_in)
 {
   case 0 : case 1 :
   子_1_st = "no error" ;
     break;
   case 2 :
   子_1_st = "common error" ;
     break;
   case 3 :
   子_1_st = "invalid trade parameters" ;
     break;
   case 4 :
   子_1_st = "trade server is busy" ;
     break;
   case 5 :
   子_1_st = "old version of the client terminal" ;
     break;
   case 6 :
   子_1_st = "no connection with trade server" ;
     break;
   case 7 :
   子_1_st = "not enough rights" ;
     break;
   case 8 :
   子_1_st = "too frequent requests" ;
     break;
   case 9 :
   子_1_st = "malfunctional trade operation (never returned error)" ;
     break;
   case 64 :
   子_1_st = "account disabled" ;
     break;
   case 65 :
   子_1_st = "invalid account" ;
     break;
   case 128 :
   子_1_st = "trade timeout" ;
     break;
   case 129 :
   子_1_st = "invalid price" ;
     break;
   case 130 :
   子_1_st = "invalid stops" ;
     break;
   case 131 :
   子_1_st = "invalid trade volume" ;
     break;
   case 132 :
   子_1_st = "market is closed" ;
     break;
   case 133 :
   子_1_st = "trade is disabled" ;
     break;
   case 134 :
   子_1_st = "not enough money" ;
     break;
   case 135 :
   子_1_st = "price changed" ;
     break;
   case 136 :
   子_1_st = "off quotes" ;
     break;
   case 137 :
   子_1_st = "broker is busy (never returned error)" ;
     break;
   case 138 :
   子_1_st = "requote" ;
     break;
   case 139 :
   子_1_st = "order is locked" ;
     break;
   case 140 :
   子_1_st = "long positions only allowed" ;
     break;
   case 141 :
   子_1_st = "too many requests" ;
     break;
   case 145 :
   子_1_st = "modification denied because order too close to market" ;
     break;
   case 146 :
   子_1_st = "trade context is busy" ;
     break;
   case 147 :
   子_1_st = "expirations are denied by broker" ;
     break;
   case 148 :
   子_1_st = "amount of open and pending orders has reached the Exit_limit" ;
     break;
   case 149 :
   子_1_st = "hedging is prohibited" ;
     break;
   case 150 :
   子_1_st = "prohibited by FIFO rules" ;
     break;
   case 4000 :
   子_1_st = "no error (never generated code)" ;
     break;
   case 4001 :
   子_1_st = "wrong function pointer" ;
     break;
   case 4002 :
   子_1_st = "array index is out of range" ;
     break;
   case 4003 :
   子_1_st = "no memory for function call stack" ;
     break;
   case 4004 :
   子_1_st = "recursive stack overflow" ;
     break;
   case 4005 :
   子_1_st = "not enough stack for parameter" ;
     break;
   case 4006 :
   子_1_st = "no memory for parameter string" ;
     break;
   case 4007 :
   子_1_st = "no memory for temp string" ;
     break;
   case 4008 :
   子_1_st = "not initialized string" ;
     break;
   case 4009 :
   子_1_st = "not initialized string in array" ;
     break;
   case 4010 :
   子_1_st = "no memory for array\' string" ;
     break;
   case 4011 :
   子_1_st = "too long string" ;
     break;
   case 4012 :
   子_1_st = "remainder from zero divide" ;
     break;
   case 4013 :
   子_1_st = "zero divide" ;
     break;
   case 4014 :
   子_1_st = "unknown command" ;
     break;
   case 4015 :
   子_1_st = "wrong jump (never generated error)" ;
     break;
   case 4016 :
   子_1_st = "not initialized array" ;
     break;
   case 4017 :
   子_1_st = "dll calls are not allowed" ;
     break;
   case 4018 :
   子_1_st = "cannot load library" ;
     break;
   case 4019 :
   子_1_st = "cannot call function" ;
     break;
   case 4020 :
   子_1_st = "expert function calls are not allowed" ;
     break;
   case 4021 :
   子_1_st = "not enough memory for temp string returned from function" ;
     break;
   case 4022 :
   子_1_st = "system is busy (never generated error)" ;
     break;
   case 4050 :
   子_1_st = "invalid function parameters count" ;
     break;
   case 4051 :
   子_1_st = "invalid function parameter value" ;
     break;
   case 4052 :
   子_1_st = "string function internal error" ;
     break;
   case 4053 :
   子_1_st = "some array error" ;
     break;
   case 4054 :
   子_1_st = "incorrect series array using" ;
     break;
   case 4055 :
   子_1_st = "custom indicator error" ;
     break;
   case 4056 :
   子_1_st = "arrays are incompatible" ;
     break;
   case 4057 :
   子_1_st = "global variables processing error" ;
     break;
   case 4058 :
   子_1_st = "global variable not found" ;
     break;
   case 4059 :
   子_1_st = "function is not allowed in testing mode" ;
     break;
   case 4060 :
   子_1_st = "function is not confirmed" ;
     break;
   case 4061 :
   子_1_st = "send mail error" ;
     break;
   case 4062 :
   子_1_st = "string parameter expected" ;
     break;
   case 4063 :
   子_1_st = "integer parameter expected" ;
     break;
   case 4064 :
   子_1_st = "double parameter expected" ;
     break;
   case 4065 :
   子_1_st = "array as parameter expected" ;
     break;
   case 4066 :
   子_1_st = "requested history data in update state" ;
     break;
   case 4099 :
   子_1_st = "end of file" ;
     break;
   case 4100 :
   子_1_st = "some file error" ;
     break;
   case 4101 :
   子_1_st = "wrong file name" ;
     break;
   case 4102 :
   子_1_st = "too many opened files" ;
     break;
   case 4103 :
   子_1_st = "cannot open file" ;
     break;
   case 4104 :
   子_1_st = "incompatible access to a file" ;
     break;
   case 4105 :
   子_1_st = "no order selected" ;
     break;
   case 4106 :
   子_1_st = "unknown symbol" ;
     break;
   case 4107 :
   子_1_st = "invalid price parameter for trade function" ;
     break;
   case 4108 :
   子_1_st = "invalid ticket" ;
     break;
   case 4109 :
   子_1_st = "trade is not allowed in the expert properties" ;
     break;
   case 4110 :
   子_1_st = "longs are not allowed in the expert properties" ;
     break;
   case 4111 :
   子_1_st = "shorts are not allowed in the expert properties" ;
     break;
   case 4200 :
   子_1_st = "object is already exist" ;
     break;
   case 4201 :
   子_1_st = "unknown object property" ;
     break;
   case 4202 :
   子_1_st = "object is not exist" ;
     break;
   case 4203 :
   子_1_st = "unknown object type" ;
     break;
   case 4204 :
   子_1_st = "no object name" ;
     break;
   case 4205 :
   子_1_st = "object coordinates error" ;
     break;
   case 4206 :
   子_1_st = "no specified subwindow" ;
     break;
   default :
   子_1_st = "unknown error" ;
 }
 return(子_1_st);
 }
//lizong_21 <<==--------   --------
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
  int       子_10_in;
  double    子_11_do;
  long      子_12_lo;
  double    子_13_do;
  double    子_14_do;
  datetime  子_15_da;
  string    子_16_st;
  int       子_17_in;
//----- -----
 long       临_lo_1;
 long       临_lo_2;
 int        临_in_3;
 long       临_lo_4;
 long       临_lo_5;
 int        临_in_6;

 子_1_do = 总_140_do_3F0 / 100.0 + 1.0 ;
 if ( ( !(AccountBalance()!=总_318_do_28D8) && !(木_0_bo) ) )   return;
 
 if ( ( !(AccountBalance()>总_318_do_28D8 * 子_1_do) && !(AccountBalance()<总_318_do_28D8 / 子_1_do) && !(木_0_bo) ) )   return;
 lizong_10(总_100_do_230,总_92_in_1EC); 
 子_2_in = MT4OrdersTotal() ;
 for (子_3_in = 子_2_in ; 子_3_in >= 0 ; 子_3_in --)
 {
   if ( OrderSelect(子_3_in,0,0) != true || OrderMagicNumber() != 总_93_in_1F0 || OrderSymbol() != 总_336_st_3130 )   continue;
   
   if ( OrderType() == 4 && OrderLots()!=总_223_do_1AC4_si99[总_328_in_3100] )
   {
     子_4_do = OrderStopLoss() ;
     子_5_lo = OrderTicket() ;
     子_6_do = OrderTakeProfit() ;
     子_7_do = OrderOpenPrice() ;
     子_8_da = OrderExpiration() ;
     子_9_st = OrderComment() ;
     OrderDelete(子_5_lo,Red); 
     子_10_in = (int)OrderSend(总_336_st_3130,4,总_223_do_1AC4_si99[总_328_in_3100],子_7_do,(int)总_38_do_C0,子_4_do,子_6_do,子_9_st,总_93_in_1F0,子_8_da,Green) ;
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
   if ( OrderType() != 5 || !(OrderLots()!=总_223_do_1AC4_si99[总_328_in_3100]) )   continue;
   子_11_do = OrderStopLoss() ;
   子_12_lo = OrderTicket() ;
   子_13_do = OrderTakeProfit() ;
   子_14_do = OrderOpenPrice() ;
   子_15_da = OrderExpiration() ;
   子_16_st = OrderComment() ;
   OrderDelete(子_12_lo,Red); 
   子_17_in = (int)OrderSend(总_336_st_3130,5,总_223_do_1AC4_si99[总_328_in_3100],子_14_do,(int)总_38_do_C0,子_11_do,子_13_do,子_16_st,总_93_in_1F0,子_15_da,Green) ;
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
 if ( !(总_17_bo_8C) )
 {
   ObjectSetString(0,"line1",OBJPROP_TEXT,"The Gold Reaper V4.5"); 
 }
 else
 {
   ObjectSetString(0,"line1",OBJPROP_TEXT,"The Gold Reaper V4.5 - OneChartSetup"); 
 }
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
 ObjectSetString(0,"linec",OBJPROP_TEXT,"EA developer by Pham Duy Linh - 2026"); 
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
   ObjectSetString(0,"linenfp" + IntegerToString(0,0,32),OBJPROP_TEXT,"No News Coming Up");
   ObjectSetInteger(0,"linenfp" + IntegerToString(0,0,32),OBJPROP_COLOR,总_329_ui_3104);
   ObjectSetInteger(0,"linenfp" + IntegerToString(0,0,32),OBJPROP_FONTSIZE,总_372_in_5CFC);
 }
 if ( OnlyUp )
 {
   ObjectCreate(0,"lineup" + IntegerToString(0,0,32),OBJ_LABEL,0,0,0.0);
   ObjectSetInteger(0,"lineup" + IntegerToString(0,0,32),OBJPROP_CORNER,子_11_in);
   ObjectSetInteger(0,"lineup" + IntegerToString(0,0,32),OBJPROP_YDISTANCE,(long)(子_13_in + InfoPanelSizeAdjust * 92.0 + 子_8_in));
   ObjectSetInteger(0,"lineup" + IntegerToString(0,0,32),OBJPROP_XDISTANCE,子_12_in + 子_7_in);
   ObjectSetString(0,"lineup" + IntegerToString(0,0,32),OBJPROP_TEXT,"Highest Balance: -");
   ObjectSetInteger(0,"lineup" + IntegerToString(0,0,32),OBJPROP_COLOR,总_329_ui_3104);
   ObjectSetInteger(0,"lineup" + IntegerToString(0,0,32),OBJPROP_FONTSIZE,总_372_in_5CFC);
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
 if ( 总_152_in_43C == 2 )
 {
   子_21_st = "PL per trade*" ;
 }
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
   ObjectDelete(0,"linea" + IntegerToString(子_1_in,0,32)); 
   ObjectDelete(0,"lineto" + IntegerToString(子_1_in,0,32)); 
   ObjectDelete(0,"linetp" + IntegerToString(子_1_in,0,32));
   ObjectDelete(0,"linetq" + IntegerToString(子_1_in,0,32));
   ObjectDelete(0,"linenfp" + IntegerToString(子_1_in,0,32));
   ObjectDelete(0,"lineup" + IntegerToString(子_1_in,0,32));
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
 string OnlyUpPeakGVName()
 {
 // Tach biet hoan toan dinh giua cac "phien": trong Strategy Tester, moi lan
 // chay (launch) mang mot g_onlyUpRunId rieng (sinh moi lan OnInit) nen khong
 // bao gio doc phai dinh con sot tu lan backtest truoc - moi lan backtest doc
 // lap 100% nhung van cap nhat/luu dinh binh thuong trong suot lan chay do.
 // Ngoai Tester (live/demo that), tach theo so tai khoan (ACCOUNT_LOGIN) de
 // tai khoan live va demo khac nhau khong dung chung 1 dinh.
 if ( MQLInfoInteger(MQL_TESTER) == 1 )
 {
   return("GR_OnlyUpPeak_TESTER_" + Symbol() + "_" + IntegerToString(ST1_MagicNumber) + "_" + IntegerToString(g_onlyUpRunId));
 }
 return("GR_OnlyUpPeak_" + Symbol() + "_" + IntegerToString(ST1_MagicNumber) + "_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)));
 }
//OnlyUpPeakGVName <<==--------   --------
 string GetNextNFPText()
 {
  datetime  临_da_best = 0;
  int       临_in_i;
//----- -----
 // Theo trang thai lay tin (g_nfpStatus): 2 = Lich MQL5 khong doc duoc -> bao
 // loi lay tin. mq5 dung Lich (khong co link) nen khong co trang thai thieu
 // link. Binh thuong (0): co NFP -> "Next NFP: ..."; khong co -> "No News".
 if ( g_nfpStatus == 2 )   return("NFP: news fetch error");
 for (临_in_i = 0 ; 临_in_i < 300 ; 临_in_i ++)
 {
   if ( 总_391_da_5DFC_si300[临_in_i] <= 0 )   continue;
   if ( 总_391_da_5DFC_si300[临_in_i] >= 总_390_da_5DC0 )
   {
     if ( 临_da_best == 0 || 总_391_da_5DFC_si300[临_in_i] < 临_da_best )   临_da_best = 总_391_da_5DFC_si300[临_in_i];
   }
 }
 if ( 临_da_best == 0 )   return("No News Coming Up"); // chua co/chua lay duoc lich -> giong panel v4.3
 return("Next NFP: " + TimeToString(临_da_best + 总_395_in_6760 * 3600,TIME_DATE|TIME_SECONDS));
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
   for (临_in_3 = MT4OrdersTotal() ; 临_in_3 >= 0 ; 临_in_3=临_in_3 - 1)
   {
     if ( OrderSelect(临_in_3,0,0) != true )   continue;
     
     if ( ( OrderSymbol() != 总_336_st_3130 && !(总_17_bo_8C) ) )   continue;
     临_in_4 = OrderMagicNumber();
     临_in_5=ST1_MagicNumber + 1;
     if ( 临_in_4 != 临_in_5 )
     {
       临_in_5 = OrderMagicNumber();
       临_in_6=ST1_MagicNumber + 2;
       if ( 临_in_5 != 临_in_6 )
       {
         临_in_6 = OrderMagicNumber();
         临_in_7=ST1_MagicNumber + 3;
         if ( 临_in_6 != 临_in_7 )
         {
           临_in_7 = OrderMagicNumber();
           临_in_8=ST1_MagicNumber + 4;
           if ( 临_in_7 != 临_in_8 )
           {
             临_in_8 = OrderMagicNumber();
             临_in_9=ST1_MagicNumber + 5;
             if ( 临_in_8 != 临_in_9 )
             {
               临_in_9 = OrderMagicNumber();
               临_in_10=ST1_MagicNumber + 6;
               if ( 临_in_9 != 临_in_10 )
               {
                 临_in_10 = OrderMagicNumber();
                 临_in_11=ST1_MagicNumber + 7;
                 if ( 临_in_10 != 临_in_11 )
                 {
                   临_in_11 = OrderMagicNumber();
                   临_in_12=ST1_MagicNumber + 8;
                   if ( 临_in_11 != 临_in_12 )
                   {
                     临_in_12 = OrderMagicNumber();
                     临_in_13=ST1_MagicNumber + 9;
                     if ( 临_in_12 != 临_in_13 )
                     {
                       临_in_13 = OrderMagicNumber();
                       临_in_14=ST1_MagicNumber + 10;
                       if ( 临_in_13 != 临_in_14 )
                       {
                         临_in_14 = OrderMagicNumber();
                         临_in_15=ST1_MagicNumber + 11;
                         if ( 临_in_14 != 临_in_15 )
                         {
                           临_in_15 = OrderMagicNumber();
                           临_in_16=ST1_MagicNumber + 12;
                           if ( 临_in_15 != 临_in_16 )
                           {
                             临_in_16 = OrderMagicNumber();
                             临_in_17=ST1_MagicNumber + 13;
                             if ( 临_in_16 != 临_in_17 )
                             {
                               临_in_17 = OrderMagicNumber();
                               临_in_18=ST1_MagicNumber + 14;
                               if ( 临_in_17 != 临_in_18 )
                               {
                                 临_in_18 = OrderMagicNumber();
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
     if ( ( OrderType() != 0 && OrderType() != 1 ) )   continue;
     临_do_2 = OrderProfit() + OrderSwap() + OrderCommission() + 临_do_2;
     
   }
   总_323_do_2CA0_si30[总_328_in_3100] = 临_do_2;
   临_do_1 = 临_do_2;
 }
 ObjectSetString(0,"lineopl" + IntegerToString(0,0,32),OBJPROP_TEXT,"Open P/L: " + DoubleToString(临_do_1,2)); 
 ObjectSetString(0,"linea" + IntegerToString(0,0,32),OBJPROP_TEXT,"Account Balance: " + DoubleToString(AccountBalance(),2)); 
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
   for (临_in_4 = HistoryTotal() ; 临_in_4 >= 0 ; 临_in_4=临_in_4 - 1)
   {
     if ( OrderSelect(临_in_4,0,1) != true )   continue;
     
     if ( ( OrderSymbol() != 总_336_st_3130 && !(总_17_bo_8C) ) )   continue;
     临_in_5 = OrderMagicNumber();
     临_in_6=ST1_MagicNumber + 1;
     if ( 临_in_5 != 临_in_6 )
     {
       临_in_6 = OrderMagicNumber();
       临_in_7=ST1_MagicNumber + 2;
       if ( 临_in_6 != 临_in_7 )
       {
         临_in_7 = OrderMagicNumber();
         临_in_8=ST1_MagicNumber + 3;
         if ( 临_in_7 != 临_in_8 )
         {
           临_in_8 = OrderMagicNumber();
           临_in_9=ST1_MagicNumber + 4;
           if ( 临_in_8 != 临_in_9 )
           {
             临_in_9 = OrderMagicNumber();
             临_in_10=ST1_MagicNumber + 5;
             if ( 临_in_9 != 临_in_10 )
             {
               临_in_10 = OrderMagicNumber();
               临_in_11=ST1_MagicNumber + 6;
               if ( 临_in_10 != 临_in_11 )
               {
                 临_in_11 = OrderMagicNumber();
                 临_in_12=ST1_MagicNumber + 7;
                 if ( 临_in_11 != 临_in_12 )
                 {
                   临_in_12 = OrderMagicNumber();
                   临_in_13=ST1_MagicNumber + 8;
                   if ( 临_in_12 != 临_in_13 )
                   {
                     临_in_13 = OrderMagicNumber();
                     临_in_14=ST1_MagicNumber + 9;
                     if ( 临_in_13 != 临_in_14 )
                     {
                       临_in_14 = OrderMagicNumber();
                       临_in_15=ST1_MagicNumber + 10;
                       if ( 临_in_14 != 临_in_15 )
                       {
                         临_in_15 = OrderMagicNumber();
                         临_in_16=ST1_MagicNumber + 11;
                         if ( 临_in_15 != 临_in_16 )
                         {
                           临_in_16 = OrderMagicNumber();
                           临_in_17=ST1_MagicNumber + 12;
                           if ( 临_in_16 != 临_in_17 )
                           {
                             临_in_17 = OrderMagicNumber();
                             临_in_18=ST1_MagicNumber + 13;
                             if ( 临_in_17 != 临_in_18 )
                             {
                               临_in_18 = OrderMagicNumber();
                               临_in_19=ST1_MagicNumber + 14;
                               if ( 临_in_18 != 临_in_19 )
                               {
                                 临_in_19 = OrderMagicNumber();
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
     临_do_2 = 临_do_2 + OrderProfit() + OrderSwap() + OrderCommission();
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
 if ( OnlyUp )
 {
   ObjectSetString(0,"lineup" + IntegerToString(0,0,32),OBJPROP_TEXT,"Highest Balance: " + DoubleToString(NormalizeDouble(总_402_do_6AD8,2),2));
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
 for (子_5_in = HistoryTotal() ; 子_5_in >= 0 ; 子_5_in --)
 {
   if ( OrderSelect(子_5_in,0,1) != true )   continue;
   
   if ( ( OrderSymbol() != 总_336_st_3130 && !(总_17_bo_8C) ) )   continue;
   临_in_1 = OrderMagicNumber();
   临_in_2=ST1_MagicNumber + 1;
   if ( 临_in_1 != 临_in_2 )
   {
     临_in_2 = OrderMagicNumber();
     临_in_3=ST1_MagicNumber + 2;
     if ( 临_in_2 != 临_in_3 )
     {
       临_in_3 = OrderMagicNumber();
       临_in_4=ST1_MagicNumber + 3;
       if ( 临_in_3 != 临_in_4 )
       {
         临_in_4 = OrderMagicNumber();
         临_in_5=ST1_MagicNumber + 4;
         if ( 临_in_4 != 临_in_5 )
         {
           临_in_5 = OrderMagicNumber();
           临_in_6=ST1_MagicNumber + 5;
           if ( 临_in_5 != 临_in_6 )
           {
             临_in_6 = OrderMagicNumber();
             临_in_7=ST1_MagicNumber + 6;
             if ( 临_in_6 != 临_in_7 )
             {
               临_in_7 = OrderMagicNumber();
               临_in_8=ST1_MagicNumber + 7;
               if ( 临_in_7 != 临_in_8 )
               {
                 临_in_8 = OrderMagicNumber();
                 临_in_9=ST1_MagicNumber + 8;
                 if ( 临_in_8 != 临_in_9 )
                 {
                   临_in_9 = OrderMagicNumber();
                   临_in_10=ST1_MagicNumber + 9;
                   if ( 临_in_9 != 临_in_10 )
                   {
                     临_in_10 = OrderMagicNumber();
                     临_in_11=ST1_MagicNumber + 10;
                     if ( 临_in_10 != 临_in_11 )
                     {
                       临_in_11 = OrderMagicNumber();
                       临_in_12=ST1_MagicNumber + 11;
                       if ( 临_in_11 != 临_in_12 )
                       {
                         临_in_12 = OrderMagicNumber();
                         临_in_13=ST1_MagicNumber + 12;
                         if ( 临_in_12 != 临_in_13 )
                         {
                           临_in_13 = OrderMagicNumber();
                           临_in_14=ST1_MagicNumber + 13;
                           if ( 临_in_13 != 临_in_14 )
                           {
                             临_in_14 = OrderMagicNumber();
                             临_in_15=ST1_MagicNumber + 14;
                             if ( 临_in_14 != 临_in_15 )
                             {
                               临_in_15 = OrderMagicNumber();
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
   if ( ( OrderType() == 0 || OrderType() == 1 ) )
   {
     if ( OrderType() == 0 )
     {
       子_2_do = OrderClosePrice() - OrderOpenPrice() ;
     }
     else
     {
       if ( OrderType() == 1 )
       {
         子_2_do = OrderOpenPrice() - OrderClosePrice() ;
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
 for (子_5_in = HistoryTotal() ; 子_5_in >= 0 ; 子_5_in --)
 {
   if ( OrderSelect(子_5_in,0,1) != true )   continue;
   
   if ( ( OrderSymbol() != 总_336_st_3130 && !(总_17_bo_8C) ) )   continue;
   临_in_1 = OrderMagicNumber();
   临_in_2=ST1_MagicNumber + 1;
   if ( 临_in_1 != 临_in_2 )
   {
     临_in_2 = OrderMagicNumber();
     临_in_3=ST1_MagicNumber + 2;
     if ( 临_in_2 != 临_in_3 )
     {
       临_in_3 = OrderMagicNumber();
       临_in_4=ST1_MagicNumber + 3;
       if ( 临_in_3 != 临_in_4 )
       {
         临_in_4 = OrderMagicNumber();
         临_in_5=ST1_MagicNumber + 4;
         if ( 临_in_4 != 临_in_5 )
         {
           临_in_5 = OrderMagicNumber();
           临_in_6=ST1_MagicNumber + 5;
           if ( 临_in_5 != 临_in_6 )
           {
             临_in_6 = OrderMagicNumber();
             临_in_7=ST1_MagicNumber + 6;
             if ( 临_in_6 != 临_in_7 )
             {
               临_in_7 = OrderMagicNumber();
               临_in_8=ST1_MagicNumber + 7;
               if ( 临_in_7 != 临_in_8 )
               {
                 临_in_8 = OrderMagicNumber();
                 临_in_9=ST1_MagicNumber + 8;
                 if ( 临_in_8 != 临_in_9 )
                 {
                   临_in_9 = OrderMagicNumber();
                   临_in_10=ST1_MagicNumber + 9;
                   if ( 临_in_9 != 临_in_10 )
                   {
                     临_in_10 = OrderMagicNumber();
                     临_in_11=ST1_MagicNumber + 10;
                     if ( 临_in_10 != 临_in_11 )
                     {
                       临_in_11 = OrderMagicNumber();
                       临_in_12=ST1_MagicNumber + 11;
                       if ( 临_in_11 != 临_in_12 )
                       {
                         临_in_12 = OrderMagicNumber();
                         临_in_13=ST1_MagicNumber + 12;
                         if ( 临_in_12 != 临_in_13 )
                         {
                           临_in_13 = OrderMagicNumber();
                           临_in_14=ST1_MagicNumber + 13;
                           if ( 临_in_13 != 临_in_14 )
                           {
                             临_in_14 = OrderMagicNumber();
                             临_in_15=ST1_MagicNumber + 14;
                             if ( 临_in_14 != 临_in_15 )
                             {
                               临_in_15 = OrderMagicNumber();
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
   if ( OrderType() == 0 )
   {
     子_2_do = OrderClosePrice() - OrderOpenPrice() ;
   }
   else
   {
     if ( OrderType() == 1 )
     {
       子_2_do = OrderOpenPrice() - OrderClosePrice() ;
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
 for (子_5_in = HistoryTotal() ; 子_5_in >= 0 ; 子_5_in --)
 {
   if ( OrderSelect(子_5_in,0,1) != true || OrderMagicNumber() != 总_93_in_1F0 )   continue;
   子_6_bo = true ;
   for (子_7_in = 0 ; 子_7_in < 总_378_in_5D80 ; 子_7_in ++)
   {
     if ( !(总_342_bo_3694_si99[子_7_in]) )
     {
       子_6_bo = false ;
     }
   }
   if ( ( OrderCloseTime() <  TimeCurrent() - 总_153_in_440 * 24 * 60 * 60 && 子_6_bo ) )   break;
   子_8_do = OrderLots() * 100.0 ;
   if ( 总_151_in_438 == 1 )
   {
     子_8_do = 1.0 ;
   }
   子_9_in = 0 ;
   if ( 总_378_in_5D80 <= 0 )   continue;
   
   for ( ; 子_9_in < 总_378_in_5D80 ; 子_9_in ++)
   {
     if ( 总_347_st_4144_si99[子_9_in] != OrderSymbol() )   continue;
     
     if ( ( OrderType() != 0 && OrderType() != 1 ) )   continue;
     临_lo_1 = OrderCloseTime();
     临_lo_2=TimeCurrent() - 总_153_in_440 * 24 * 60 * 60;
     if ( 临_lo_1 <  临_lo_2 )
     {
       临_lo_2 = OrderCloseTime();
       临_lo_3=TimeCurrent() - 总_153_in_440 * 24 * 60 * 60;
     if ( (临_lo_2 >= 临_lo_3 || 总_342_bo_3694_si99[子_9_in]) )   continue;
     }
     总_343_in_372C_si99[子_9_in] ++;
     if ( 总_343_in_372C_si99[子_9_in] >= 总_155_in_448 )
     {
       总_342_bo_3694_si99[子_9_in] = true;
     }
     子_2_do_si99[子_9_in] +=OrderProfit() / 子_8_do;
     子_2_do_si99[子_9_in] +=OrderSwap() / 子_8_do;
     子_2_do_si99[子_9_in] +=OrderCommission() / 子_8_do;
     临_lo_4 = OrderCloseTime();
     临_lo_5=TimeCurrent() - 总_154_in_444 * 24 * 60 * 60;
     if ( 临_lo_4 < 临_lo_5 )   continue;
     子_3_do_si99[子_9_in] +=OrderProfit() / 子_8_do;
     子_3_do_si99[子_9_in] +=OrderSwap() / 子_8_do;
     子_3_do_si99[子_9_in] +=OrderCommission() / 子_8_do;
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
 if ( ( AccountCurrency() == "USD" || AccountCurrency() == "usd" ) )
 {
   子_2_do = 木_0_do ;
 }
 if ( ( AccountCurrency() == "EUR" || AccountCurrency() == "eur" ) )
 {
   子_3_st="EURUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,MT4Period(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do / iClose(子_3_st,MT4Period(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountCurrency() == "GBP" || AccountCurrency() == "gbp" ) )
 {
   子_3_st="GBPUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,MT4Period(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do / iClose(子_3_st,MT4Period(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountCurrency() == "AUD" || AccountCurrency() == "aud" ) )
 {
   子_3_st="AUDUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,MT4Period(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do / iClose(子_3_st,MT4Period(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountCurrency() == "JPY" || AccountCurrency() == "jpy" || AccountCurrency() == "YEN" || AccountCurrency() == "yen" ) )
 {
   子_3_st="USDJPY" + 总_299_st_2850;
   if ( iClose(子_3_st,MT4Period(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do * iClose(子_3_st,MT4Period(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountCurrency() == "CHF" || AccountCurrency() == "chf" ) )
 {
   子_3_st="USDCHF" + 总_299_st_2850;
   if ( iClose(子_3_st,MT4Period(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do * iClose(子_3_st,MT4Period(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountCurrency() == "HKD" || AccountCurrency() == "hkd" ) )
 {
   子_3_st="USDHKD" + 总_299_st_2850;
   if ( iClose(子_3_st,MT4Period(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do * iClose(子_3_st,MT4Period(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountCurrency() == "SGD" || AccountCurrency() == "sgd" ) )
 {
   子_3_st="USDSGD" + 总_299_st_2850;
   if ( iClose(子_3_st,MT4Period(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do * iClose(子_3_st,MT4Period(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountCurrency() == "PLN" || AccountCurrency() == "pln" ) )
 {
   子_3_st="USDPLN" + 总_299_st_2850;
   if ( iClose(子_3_st,MT4Period(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do * iClose(子_3_st,MT4Period(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountCurrency() == "RUB" || AccountCurrency() == "rub" ) )
 {
   子_3_st="USDRUB" + 总_299_st_2850;
   if ( iClose(子_3_st,MT4Period(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do * iClose(子_3_st,MT4Period(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountCurrency() == "BTC" || AccountCurrency() == "btc" ) )
 {
   子_3_st="BTCUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,MT4Period(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do / iClose(子_3_st,MT4Period(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountCurrency() == "ETH" || AccountCurrency() == "eth" ) )
 {
   子_3_st="ETHUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,MT4Period(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do / iClose(子_3_st,MT4Period(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountCurrency() == "BCH" || AccountCurrency() == "bch" ) )
 {
   子_3_st="BCHUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,MT4Period(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do / iClose(子_3_st,MT4Period(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountCurrency() == "BCC" || AccountCurrency() == "bcc" ) )
 {
   子_3_st="BCCUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,MT4Period(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do / iClose(子_3_st,MT4Period(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountCurrency() == "XRP" || AccountCurrency() == "xrp" ) )
 {
   子_3_st="XRPUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,MT4Period(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do / iClose(子_3_st,MT4Period(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountCurrency() == "LTC" || AccountCurrency() == "ltc" ) )
 {
   子_3_st="LTCUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,MT4Period(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do / iClose(子_3_st,MT4Period(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountCurrency() == "XMR" || AccountCurrency() == "xmr" ) )
 {
   子_3_st="XMRUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,MT4Period(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do / iClose(子_3_st,MT4Period(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountCurrency() == "DSH" || AccountCurrency() == "dsh" ) )
 {
   子_3_st="DSHUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,MT4Period(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do / iClose(子_3_st,MT4Period(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountCurrency() == "EOS" || AccountCurrency() == "eos" ) )
 {
   子_3_st="EOSUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,MT4Period(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do / iClose(子_3_st,MT4Period(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountCurrency() == "TRX" || AccountCurrency() == "trx" ) )
 {
   子_3_st="TRXUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,MT4Period(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do / iClose(子_3_st,MT4Period(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountCurrency() == "ADA" || AccountCurrency() == "ada" ) )
 {
   子_3_st="ADAUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,MT4Period(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do / iClose(子_3_st,MT4Period(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountCurrency() == "BSV" || AccountCurrency() == "bsv" ) )
 {
   子_3_st="BSVUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,MT4Period(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do / iClose(子_3_st,MT4Period(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountCurrency() == "XLM" || AccountCurrency() == "xlm" ) )
 {
   子_3_st="XLMUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,MT4Period(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do / iClose(子_3_st,MT4Period(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountCurrency() == "GLD" || AccountCurrency() == "gld" ) )
 {
   子_3_st="GLDUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,MT4Period(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do / iClose(子_3_st,MT4Period(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountCurrency() == "ZEC" || AccountCurrency() == "zec" ) )
 {
   子_3_st="ZECUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,MT4Period(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do / iClose(子_3_st,MT4Period(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountCurrency() == "XEM" || AccountCurrency() == "xem" ) )
 {
   子_3_st="XEMUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,MT4Period(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do / iClose(子_3_st,MT4Period(PERIOD_D1),1) ;
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
   if ( iClose(子_3_st,MT4Period(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do * iClose(子_3_st,MT4Period(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "GBP" || AccountInfoString(ACCOUNT_CURRENCY) == "gbp" ) )
 {
   子_3_st="GBPUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,MT4Period(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do * iClose(子_3_st,MT4Period(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "AUD" || AccountInfoString(ACCOUNT_CURRENCY) == "aud" ) )
 {
   子_3_st="AUDUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,MT4Period(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do * iClose(子_3_st,MT4Period(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "JPY" || AccountInfoString(ACCOUNT_CURRENCY) == "jpy" || AccountInfoString(ACCOUNT_CURRENCY) == "YEN" || AccountInfoString(ACCOUNT_CURRENCY) == "yen" ) )
 {
   子_3_st="USDJPY" + 总_299_st_2850;
   if ( iClose(子_3_st,MT4Period(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do / iClose(子_3_st,MT4Period(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "CHF" || AccountInfoString(ACCOUNT_CURRENCY) == "chf" ) )
 {
   子_3_st="USDCHF" + 总_299_st_2850;
   if ( iClose(子_3_st,MT4Period(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do / iClose(子_3_st,MT4Period(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "HKD" || AccountInfoString(ACCOUNT_CURRENCY) == "hkd" ) )
 {
   子_3_st="USDHKD" + 总_299_st_2850;
   if ( iClose(子_3_st,MT4Period(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do / iClose(子_3_st,MT4Period(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "RUB" || AccountInfoString(ACCOUNT_CURRENCY) == "rub" ) )
 {
   子_3_st="USDRUB" + 总_299_st_2850;
   if ( iClose(子_3_st,MT4Period(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do / iClose(子_3_st,MT4Period(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "CNH" || AccountInfoString(ACCOUNT_CURRENCY) == "cnh" ) )
 {
   子_3_st="USDCNH" + 总_299_st_2850;
   if ( iClose(子_3_st,MT4Period(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do / iClose(子_3_st,MT4Period(PERIOD_D1),1) ;
   }
   else
   {
     子_3_st="USDCNY" + 总_299_st_2850;
     if ( iClose(子_3_st,MT4Period(PERIOD_D1),1)>0.0 )
     {
       子_2_do = 木_0_do / iClose(子_3_st,MT4Period(PERIOD_D1),1) ;
     }
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "CNY" || AccountInfoString(ACCOUNT_CURRENCY) == "cny" ) )
 {
   子_3_st="USDCNH" + 总_299_st_2850;
   if ( iClose(子_3_st,MT4Period(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do / iClose(子_3_st,MT4Period(PERIOD_D1),1) ;
   }
   else
   {
     子_3_st="USDCNY" + 总_299_st_2850;
     if ( iClose(子_3_st,MT4Period(PERIOD_D1),1)>0.0 )
     {
       子_2_do = 木_0_do / iClose(子_3_st,MT4Period(PERIOD_D1),1) ;
     }
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "SGD" || AccountInfoString(ACCOUNT_CURRENCY) == "sgd" ) )
 {
   子_3_st="USDSGD" + 总_299_st_2850;
   if ( iClose(子_3_st,MT4Period(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do / iClose(子_3_st,MT4Period(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "BTC" || AccountInfoString(ACCOUNT_CURRENCY) == "btc" ) )
 {
   子_3_st="BTCUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,MT4Period(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do * iClose(子_3_st,MT4Period(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "ETH" || AccountInfoString(ACCOUNT_CURRENCY) == "eth" ) )
 {
   子_3_st="ETHUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,MT4Period(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do * iClose(子_3_st,MT4Period(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "BCH" || AccountInfoString(ACCOUNT_CURRENCY) == "bch" ) )
 {
   子_3_st="BCHUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,MT4Period(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do * iClose(子_3_st,MT4Period(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "BCC" || AccountInfoString(ACCOUNT_CURRENCY) == "bcc" ) )
 {
   子_3_st="BCCUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,MT4Period(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do * iClose(子_3_st,MT4Period(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "XRP" || AccountInfoString(ACCOUNT_CURRENCY) == "xrp" ) )
 {
   子_3_st="XRPUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,MT4Period(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do * iClose(子_3_st,MT4Period(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "LTC" || AccountInfoString(ACCOUNT_CURRENCY) == "ltc" ) )
 {
   子_3_st="LTCUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,MT4Period(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do * iClose(子_3_st,MT4Period(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "XMR" || AccountInfoString(ACCOUNT_CURRENCY) == "xmr" ) )
 {
   子_3_st="XMRUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,MT4Period(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do * iClose(子_3_st,MT4Period(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "DSH" || AccountInfoString(ACCOUNT_CURRENCY) == "dsh" ) )
 {
   子_3_st="DSHUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,MT4Period(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do * iClose(子_3_st,MT4Period(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "EOS" || AccountInfoString(ACCOUNT_CURRENCY) == "eos" ) )
 {
   子_3_st="EOSUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,MT4Period(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do * iClose(子_3_st,MT4Period(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "TRX" || AccountInfoString(ACCOUNT_CURRENCY) == "trx" ) )
 {
   子_3_st="TRXUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,MT4Period(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do * iClose(子_3_st,MT4Period(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "ADA" || AccountInfoString(ACCOUNT_CURRENCY) == "ada" ) )
 {
   子_3_st="ADAUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,MT4Period(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do * iClose(子_3_st,MT4Period(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "BSV" || AccountInfoString(ACCOUNT_CURRENCY) == "bsv" ) )
 {
   子_3_st="BSVUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,MT4Period(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do * iClose(子_3_st,MT4Period(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "XLM" || AccountInfoString(ACCOUNT_CURRENCY) == "xlm" ) )
 {
   子_3_st="XLMUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,MT4Period(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do * iClose(子_3_st,MT4Period(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "GLD" || AccountInfoString(ACCOUNT_CURRENCY) == "gld" ) )
 {
   子_3_st="GLDUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,MT4Period(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do * iClose(子_3_st,MT4Period(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "ZEC" || AccountInfoString(ACCOUNT_CURRENCY) == "zec" ) )
 {
   子_3_st="ZECUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,MT4Period(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do * iClose(子_3_st,MT4Period(PERIOD_D1),1) ;
   }
 }
 if ( ( AccountInfoString(ACCOUNT_CURRENCY) == "XEM" || AccountInfoString(ACCOUNT_CURRENCY) == "xem" ) )
 {
   子_3_st="XEMUSD" + 总_299_st_2850;
   if ( iClose(子_3_st,MT4Period(PERIOD_D1),1)>0.0 )
   {
     子_2_do = 木_0_do * iClose(子_3_st,MT4Period(PERIOD_D1),1) ;
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

 总_71_in_174 = 1440 ;
 总_72_in_178 = 15 ;
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

 总_71_in_174 = 240 ;
 总_72_in_178 = 60 ;
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

 总_71_in_174 = 1440 ;
 总_72_in_178 = 60 ;
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

 总_71_in_174 = 1440 ;
 总_72_in_178 = 60 ;
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

 总_71_in_174 = 60 ;
 总_72_in_178 = 5 ;
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

 总_71_in_174 = 60 ;
 总_72_in_178 = 15 ;
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

 总_71_in_174 = 60 ;
 总_72_in_178 = 15 ;
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

 总_71_in_174 = 60 ;
 总_72_in_178 = 15 ;
 总_73_in_17C = 25 ;
 总_74_in_180 = 23 ;
 总_77_in_188 = 145 ;
 总_80_do_198 = 10.0 ;
 总_81_do_1A0 = 0.0 ;
 临_do_1 = AdjustEntry + -60.0;
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

 总_71_in_174 = 60 ;
 总_72_in_178 = 15 ;
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

 临_do_1 = AccountEquity();
 if ( 临_do_1==AccountBalance() )   return;
 子_1_do = 0.0 ;
 if ( AccountEquity()>总_384_do_5DA0 )
 {
   总_384_do_5DA0 = AccountEquity() ;
 }
 for (子_2_in = HistoryTotal() ; 子_2_in >= 0 ; 子_2_in --)
 {
   if ( OrderSelect(子_2_in,0,1) != true )   continue;
   临_lo_2 = OrderCloseTime();
   if ( 临_lo_2 < iTime(总_336_st_3130,MT4Period(PERIOD_D1),0) )   continue;
   子_3_do = OrderProfit() + OrderSwap() + OrderCommission() ;
   子_1_do = 子_3_do + 子_1_do ;
   
 }
 子_4_do = AccountEquity() - AccountBalance() ;
 子_5_do = 子_4_do + 子_1_do ;
 if ( !( -(子_5_do)>总_384_do_5DA0 * PropFirmMaxDailyDD / 100.0) )   return;
 
 if ( !(总_382_bo_5D98) )
 {
   Print("Max Daily Drawdown reached, closing trades and skipping rest of the day"); 
 }
 for (临_in_3 = MT4OrdersTotal() ; 临_in_3 >= 0 ; 临_in_3=临_in_3 - 1)
 {
   if ( OrderSelect(临_in_3,0,0) != true || OrderSymbol() != 总_336_st_3130 )   continue;
   临_in_4 = OrderMagicNumber();
   临_in_5=ST1_MagicNumber + 1;
   if ( 临_in_4 != 临_in_5 )
   {
     临_in_5 = OrderMagicNumber();
     临_in_6=ST1_MagicNumber + 2;
     if ( 临_in_5 != 临_in_6 )
     {
       临_in_6 = OrderMagicNumber();
       临_in_7=ST1_MagicNumber + 3;
       if ( 临_in_6 != 临_in_7 )
       {
         临_in_7 = OrderMagicNumber();
         临_in_8=ST1_MagicNumber + 4;
         if ( 临_in_7 != 临_in_8 )
         {
           临_in_8 = OrderMagicNumber();
           临_in_9=ST1_MagicNumber + 5;
           if ( 临_in_8 != 临_in_9 )
           {
             临_in_9 = OrderMagicNumber();
             临_in_10=ST1_MagicNumber + 6;
             if ( 临_in_9 != 临_in_10 )
             {
               临_in_10 = OrderMagicNumber();
               临_in_11=ST1_MagicNumber + 7;
               if ( 临_in_10 != 临_in_11 )
               {
                 临_in_11 = OrderMagicNumber();
                 临_in_12=ST1_MagicNumber + 8;
                 if ( 临_in_11 != 临_in_12 )
                 {
                   临_in_12 = OrderMagicNumber();
                   临_in_13=ST1_MagicNumber + 9;
                   if ( 临_in_12 != 临_in_13 )
                   {
                     临_in_13 = OrderMagicNumber();
                     临_in_14=ST1_MagicNumber + 10;
                     if ( 临_in_13 != 临_in_14 )
                     {
                       临_in_14 = OrderMagicNumber();
                       临_in_15=ST1_MagicNumber + 11;
                       if ( 临_in_14 != 临_in_15 )
                       {
                         临_in_15 = OrderMagicNumber();
                         临_in_16=ST1_MagicNumber + 12;
                         if ( 临_in_15 != 临_in_16 )
                         {
                           临_in_16 = OrderMagicNumber();
                           临_in_17=ST1_MagicNumber + 13;
                           if ( 临_in_16 != 临_in_17 )
                           {
                             临_in_17 = OrderMagicNumber();
                             临_in_18=ST1_MagicNumber + 14;
                             if ( 临_in_17 != 临_in_18 )
                             {
                               临_in_18 = OrderMagicNumber();
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
   if ( OrderType() == 0 )
   {
     OrderClose(OrderTicket(),OrderLots(),MarketInfo(总_336_st_3130,MODE_BID),(int)总_38_do_C0,Red); 
   }
   if ( OrderType() == 1 )
   {
     OrderClose(OrderTicket(),OrderLots(),MarketInfo(总_336_st_3130,MODE_ASK),(int)总_38_do_C0,Red); 
   }
   if ( ( OrderType() != 4 && OrderType() != 5 ) )   continue;
   OrderDelete(OrderTicket(),Red); 
   
 }
 总_382_bo_5D98 = true ;
 总_384_do_5DA0 = 0.0 ;
 }
//lizong_46 <<==--------   --------
 int lizong_47()
 {
  string    子_2_st;
  int       子_3_in;
  string    子_4_st;
  long      子_5_lo;
  int       子_6_in;
  char      子_7_ch_ko[];
  char      子_8_ch_ko[];
//----- -----
 string     临_st_1;
 string     临_st_2;

 ResetLastError();
 if ( WebRequest("GET","https://www.worldtimeserver.com/time-zones/utc/",NULL,NULL,10000,子_7_ch_ko,0,子_8_ch_ko,临_st_1) == -1 )
 {
   Print("Error when reading GMT URL. Error code  =",GetLastError());
   MessageBox("Add the address \'https://www.worldtimeserver.com/\' in the list of allowed URLs on tab \'Expert Advisors\'","Error",64);
   临_st_2 = "999";
 }
 else
 {
   // MQL4 dung WHOLE_ARRAY=0 (quy uoc cu cua MQL4) de lay "toan bo mang" khi
   // count=0; nhung MQL5 dinh nghia lai WHOLE_ARRAY=-1, con count=0 trong MQL5
   // co nghia den la "lay 0 ky tu" -> luon ra chuoi rong du HTTP tra ve 200 va
   // co du du lieu (day chinh la nguyen nhan that su cua loi "GMT time = 0").
   临_st_2 = CharArrayToString(子_8_ch_ko,0,-1,0);
 }
 子_2_st = 临_st_2 ;
 if ( 子_2_st == "999" )
 {
   return(999);
 }
 子_3_in = StringFind(子_2_st,"\"serverTimeStamp\" value=",0) ;
 子_4_st = StringSubstr(子_2_st,子_3_in + 25,10) ;
 子_5_lo = (long)ulong(子_4_st) ;
 Print("GMT time = ",子_5_lo); 
 Print("Broker time = ",TimeCurrent()); 
 子_6_in=TimeHour(TimeCurrent()) - TimeHour(子_5_lo);
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

 子_2_in = TimeYear(TimeCurrent()) ;
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
 if ( TimeDayOfYear(TimeCurrent()) >  TimeDayOfYear(子_3_da) && TimeDayOfYear(TimeCurrent()) <  TimeDayOfYear(子_4_da) )
 {
   return(true); 
 }
 return(false); 
 }
//<<==lizong_48 <<==

