//+------------------------------------------------------------------+
//|  The_Gold_Reaper.mq4  -  BAN CHU GIAI (annotated)               |
//|  Tu dong chuyen doi tu ban decompile, GIU NGUYEN LOGIC.         |
//|  Da thay doi (chi de DE DOC, khong doi hanh vi):                |
//|   - Hex thoi gian -> giay thap phan + ghi chu:                  |
//|       0x2A300=172800(2 ngay) 0x1C20=7200(2h) 0x15180=86400(1ngay)|
//|   - 0xFFFFFFFF (tham so mau OrderDelete) -> clrNONE             |
//|   - 0xFF0000 (OBJPROP_COLOR, BGR) -> C(0,0,255) = mau xanh duong|
//|   - OrderSend type so -> OP_BUY/OP_SELL/OP_BUYSTOP/OP_SELLSTOP   |
//|       (0=OP_BUY 1=OP_SELL 4=OP_BUYSTOP 5=OP_SELLSTOP)            |
//|   - SymbolInfoDouble(...,N) -> hang ten:                         |
//|       16=SYMBOL_TRADE_TICK_SIZE 34=SYMBOL_VOLUME_MIN             |
//|       35=SYMBOL_VOLUME_MAX 36=SYMBOL_VOLUME_STEP                 |
//|  KHONG sua: ten bien tu sinh (lv_*, tmp_*) - da mat khi decompile|
//+------------------------------------------------------------------+
// ============================================================
// The Gold Reaper v4.1 - Decompiled & Renamed
// EA by: Wim Schrynemakers (2024)
// Decompiled: variable/function names restored for readability
// Original logic preserved 100%
// ============================================================
//+------------------------------------------------------------------+
//| BAN CHUYEN DOI SANG MQL5 (chuyen doi tu dong tu ban .mq4 o tren). |
//| Logic goc duoc GIU NGUYEN 100%. Toan bo cac ham dac thu MQL4      |
//| (OrderSend/OrderModify/OrderClose/OrderDelete/OrderSelect,        |
//| OrdersTotal/HistoryTotal, MarketInfo, AccountBalance/Equity,      |
//| Year()/Month()/Day()/Hour()/Minute()/DayOfWeek(), iMA()/          |
//| iFractals() kieu MQL4...) duoc anh xa sang API MQL5 thong qua     |
//| Include/GoldReaper/MQL4Compat.mqh - xem chi tiet & luu y trong    |
//| file do (dac biet: TAI KHOAN CHAY EA NAY PHAI O CHE DO HEDGING).  |
//| Cac thay doi con lai chi la co phap: extern->input, init()/       |
//| deinit()->OnInit()/OnDeinit(), timeframe "so phut" kieu MQL4 duoc |
//| quy doi qua MT4Period() truoc khi goi iHigh/iLow/iOpen/iClose/    |
//| iTime/iVolume/iBars/iBarShift/iHighest/iLowest.                   |
//+------------------------------------------------------------------+

#property copyright ""
#property version "4.1"

#include <GoldReaper/MQL4Compat.mqh>

//+------------------------------------------------------------------+
//| HAN SU DUNG EA - qua ngay gio nay EA se tu dong ngung hoat dong.  |
//| Sua truc tiep gia tri ben duoi (KHONG phai input) de nguoi dung   |
//| cuoi khong tu y chinh sua duoc qua tab Inputs.                    |
//+------------------------------------------------------------------+
datetime ExpiryDate = D'2026.12.31 23:59:59'; // Han su dung EA (yyyy.mm.dd hh:mi:ss)

enum enum_TradeFrequency {Extreme_cons_Frequency=0,// extreme conservative
Conservative_Frequency=1,// conservative
Moderate_Frequency=2,// moderate
Intens_Frequency=3,// Intense
Extreme_Frequency=4,// Extreme (high risk!)
Auto_Frequency=5,// Auto (based on balance and risk)
Manual_Strategy_Selection=6// Manual strategy selection
};
enum e_SlippageControlMode {SCT_1=1,SCT_2=2 };
enum FakeoutFilters {Filter_Off=0,// OFF
Filter_Low=1,// Low
Filter_Medium=2,// Medium
Filter_High=3// High
};
enum e_VirtualStopMode {VSL_OFF=1,VSL_BASIC=2,VSL_ADV=3 };
enum Select_Entry_Strategy {Strategy_ONE=1,Strategy_TWO=2 };
enum e_TimeFrame_St_ONE {ST1_M1=1,ST1_M5=5,ST1_M15=15,ST1_M30=30,ST1_H1=60,ST1_H4=240,ST1_Daily=1440,ST1_Chart=0 };
enum e_TimeFrame_Entry_Timing {Entry_T_Tick=0,Entry_T_M1=1,Entry_T_M5=5,Entry_T_M15=15,Entry_T_M30=30,Entry_T_H1=60,Entry_T_H4=240 };
enum e_UseOfCompound {no_compound=0,one_trade=1,Multi_trades=2 };
enum e_MonitorTradesFilter {MT_all=0,MT_PairOfChart=1 };
enum e_TimeFrame_Exit_Timing {ET_Tick=0,ET_M1=1,ET_M5=5,ET_M15=15,ET_M30=30,ET_H1=60 };
enum e_Exit_HL_trailingSL_timeframe {HLT_Chart=0,HLT_M1=1,HLT_M5=5,HLT_M15=15,HLT_M30=30,HLT_H1=60,HLT_H4=240,HLT_D1=1440 };
enum ST1_e_MagicTrail_Mode {ST1_MT_M_O=0,ST1_MT_M_F=1,ST1_MT_M_B=2 };
enum e_Risk {Manual_Lotsize=0,// use StartLots
MaxHistoricalDD=1234,// Max Allowed Total Drawdown
MaxRiskStrat=3// Max Risk Per Strategy
};
enum Performance_options {NormalizedProfit=2,RealProfit=1 };
enum RankingOptions {ranking_profit=1,ranking_pertrade=2 };
enum Reduction_choices {Red_10=10,Red_20=20,Red_30=30,Red_40=40,Red_50=50,Red_60=60,Red_70=70,Red_80=80,Red_90=90 };
enum e_factortype {factor_type_1=1,factor_type_2=2,factor_type_3=3 };
enum e_TimeSource {TZ_GMT=0,TZ_PC=1,TZ_Broker=2 };


//------------------
input bool UseVariableValues=true ; // Use Variable Values
input bool AdjustLotsizeToVariableValues=true ; // Adjust Lotsize To Variable Values
input bool ShowInfoPanel=true ; // Show Info Panel
input double InfoPanelSizeAdjust=1 ; // Adjustment for Infopanel size
input bool UpdateInfoTesting=false; // update infopanel during testing
input string spreadfilter="------------------------------Settings------------------------------" ; //---
input bool AllowBuyTrades=true ; // Allow Buy Trades
input bool AllowSellTrades=true ; // Allow Sell Trades
input enum_TradeFrequency TradeFrequency=5 ; // Trade Frequency
input double MaxSpread=500 ; // Maximum allowed spread
input bool UseHL_TrailingSL=true ; // Use HL Trailing SL
input int FridayStopHour=25 ; // Friday stop hour (brokertime; close all trades)
input bool setSL_TP_After_Entry=false; // Set SL/TP After Entry
input bool Virtual_expiration=true ; // Use Virtual Expiration
input double Randomization=0 ; // Randomization (entries and exit) in pips
input FakeoutFilters FakeOutFilter=2 ; // Fake Breakout Filter
input int ST1_MagicNumber=8000 ; // Base Magicnumber
input string ST1_Comment="The Gold Reaper" ; // Comment for trades
input bool RemoveCommentSuffix=false; // Remove Comment Suffix
input string NFP_FILTER="----------------------- NFP Filter -----------------------" ;
input bool EnableNFP_Filter=true ; // Enable NFP Filter
input bool AutoGMT=true ; // Auto GMT Detect
input int Broker_GMT_OFFSET_Winter=2 ; // GMT_OFFSET_Winter (AutoGMT=false or backtesting)
input int Broker_GMT_OFFSET_Summer=3 ; // MT_OFFSET_Summer (AutoGMT=false or backtesting)
input bool NFP_CloseOpenTrades=true ; // NFP Close Open Trades
input bool NFP_ClosePendingOrders=true ; // NFP Close Pending Orders
input int NFP_MinutesBefore=100 ; // NFP Minutes Before
input int NFP_MinutesAfter=60 ; // NFP Minutes After
input string propfirmsettings="----------------------- Propfirm unique trades settings -----------------------" ; //---
input double AdjustEntry=0 ; // Adjust Entry (pips)
input double AdjustSL=0 ; // Adjust SL (pips)
input double AdjustTP=0 ; // Adjust TP (pips)
input double AdjustTrailSL=0 ; // Adjust Trail SL (pips)
input double AdjustTrailTP=0 ; // Adjust Trail TP (pips)
input double AdjustBreakEven=0 ; // Adjust Break Even (pips)
input string LotSizeSettings="----------------------- LotSize Settings -----------------------" ; //---
input double ForceBalanceToUse=0 ; // manually set balance to use (if > 0)
input e_Risk Risk=1234 ; // Lotsize Calculation method
input double StartLots=0.01 ; // Start Lots
double g_startLots=0.0; // ban sao co the ghi duoc cua input StartLots (input la hang so trong MQL5, khong the gan lai)
input double MaxAllowedDD=30 ; // Max Allowed TOTAL Drawdown
input bool UseWeightedLots=true ; // Weighted Lotsize
input double MaxRiskPerStrategy_=1 ; // Max Risk Per Strat
input double PropFirmMaxDailyDD=0 ; // Set Max DAILY Drawdown (Prop Firms)
input bool UseEquity=false; // Use Equity Instead of Balance
input bool OnlyUp=true ; // OnlyUp
input bool CheckMargin=true ; // check for free margin before setting trades
input string ManualStratSelect="------------------------- Manual Strategy Selection -------------------------" ; //---
input string ManStratWarn="!! DO NOT RUN MANUAL STRATEGIES WHILE USING 'MAX ALLOWED TOTAL DD' OPTION !!" ; //---
input bool RunStrat1=true ; // Run Strategy 1 (low risk)
input bool RunStrat2=true ; // Run Strategy 2 (low risk)
input bool RunStrat3=true ; // Run Strategy 3 (low risk)
input bool RunStrat4=true ; // Run Strategy 4 (med risk)
input bool RunStrat5=true ; // Run Strategy 5 (med risk)
input bool RunStrat6=true ; // Run Strategy 6 (med risk)
input bool RunStrat7=true ; // Run Strategy 7 (med risk)
input bool RunStrat8=true ; // Run Strategy 8 (high risk)
input bool RunStrat9=true ; // Run Strategy 9 (high risk)
double g_spread=0.0;
double g_prevSpread=0.0;
int g_maxRetries=30;
int g_dailyTF=1440;
int g_slippage=0;
double g_tempBuffer[];
double g_totalProfit=0.0;
double g_totalLoss=0.0;
double g_netProfit=0.0;
bool g_newBar=false;
int g_maxPendingBuy=3;
int g_maxPendingSell=2;
bool g_buyAllowed=false;
bool g_sellAllowed=false;
int g_tradeCount=0;
string g_sep_tradingFilters="------------------------------trading filters------------------------------";
bool g_useSymbolFilter=false;
string g_allowedSymbols="EURUSD;GBPUSD;USDJPY;AUDJPY;AUDUSD;EURAUD;EURCAD;EURGBP;EURJPY;GBPJPY;USDCAD;USDCHF;";
int g_minBarsBetween=5;
bool g_strat1_enabled=true;
bool g_strat2_enabled=false;
bool g_strat3_enabled=false;
bool g_strat4_enabled=true;
bool g_strat5_enabled=false;
bool g_strat6_enabled=false;
bool g_strat7_enabled=true;
bool g_strat8_enabled=false;
bool g_strat9_enabled=false;
bool g_strat10_enabled=false;
bool g_strat11_enabled=false;
bool g_strat12_enabled=false;
bool g_strat13_enabled=false;
bool g_strat14_enabled=false;
bool g_strat15_enabled=false;
bool g_strat16_enabled=true;
int g_fakeoutStrength=2;
double g_minVolatility=0.0;
double g_maxVolatility=5000.0;
int g_volPeriod=1;
double g_entryRange=400.0;
double g_exitRange=100.0;
double g_filterRange=300.0;
bool g_useVirtualSL=true;
string g_sep_timeFilters="------------------------------time filters------------------------------";
bool g_useMonFilter=false;
bool g_useTueFilter=false;
bool g_useWedFilter=false;
int g_tradeStartHour=14;
int g_tradeEndHour=17;
string g_sep_otherFilters="------------------------------other filters------------------------------";
int g_maxTradesPerDir=1;
int g_maxTotalTrades=1;
bool g_use5minFilter=false;
int g_filter5minPeriod=5;
bool g_use15minFilter=false;
int g_filter15minPeriod=15;
bool g_use30minFilter=false;
int g_filter30minPeriod=30;
bool g_use1hrFilter=false;
int g_filter1hrPeriod=60;
bool g_useNewsFilter=false;
bool g_closeDuringNews=false;
int g_newsFilterMode=1;
double g_newsImpactLevel=0.0;
int g_maxSpreadFilter=99;
int g_spreadFilterPeriod=5;
bool g_useSpreadFilter=false;
int g_spreadFilterBars=5;
int g_entryMode=1;
string g_sep_tradeEntry="------------------------------Trade Entry management------------------------------";
int g_entryTF=0;
int g_entryPeriod=60;
int g_entryBars=10;
int g_entryRetries=3;
bool g_useEntryDelay=false;
bool g_usePartialClose=false;
int g_entryDelaySeconds=120;
int g_partialClosePercent=0;
int g_partialCloseTrigger=0;
double g_takeProfitPips=30.0;
double g_tpOffset=0.0;
double g_stopLossPips=25.0;
double g_slOffset=0.5;
double g_breakEvenPips=0.0;
double g_breakEvenOffset=0.0;
int g_maxConcurrent=1;  // (cu: g_tradeDir) - NGUONG so lenh dong thoi, KHONG phai huong lenh
int g_maxOrdersTotal=99;
double g_lotMultiplier=1.0;
int g_expiryHours=24;
double g_slippagePips=3.0;
int g_magicOffset=0;
int g_strategyMask=100;
int g_magicMain=0;
string g_sep_strat2Manual="------------------------------Strategy2 - Manual Trade settings------------------------------";
int g_strat2_type=1;
int g_magicStrat2=1991199118;
string g_strat2_comment="";
string g_sep_tradeExit="------------------------------Trade Exit management------------------------------";
int g_exitMode=0;
double g_minProfitClose=20.0;
double g_maxLossClose=100.0;
string g_sep_trailingSL="------------------------------Trailing SL settings------------------------------";
double g_trailStep=10.0;
double g_trailStart=10.0;
double g_trailStop=100.0;
double g_trailOffset=0.1;
double g_trailMin=0.0;
double g_trailMax=0.0;
double g_trailFactor=0.0;
double g_trailAccel=0.0;
double g_trailAccelMax=0.0;
string g_sep_breakEven="------------------------------Break-even SL management------------------------------";
double g_beProfitTrigger=0.0;
double g_beOffset=0.0;
string g_sep_hlTrail="------------------------------HIGH/LOW Trailing SL settings------------------------------";
bool g_useHLTrail=false;
int g_hlTrailTF=0;
int g_hlTrailPeriod=0;
int g_hlTrailShift=0;
int g_hlTrailMode=0;
int g_hlTrailBars=0;
int g_hlTrailOffset=0;
double g_hlTrailMult=2.0;
string g_sep_recoveryTrail="------------------------------recovery Trailing SL based on time------------------------------";
double g_recovTrailStart=0.0;
double g_recovTrailStep=0.0;
string g_sep_magicTrail="------------------------------MagicTrail SL settings------------------------------";
int g_magicTrailMode=0;
double g_magicTrailStep=0.1;
int g_magicTrailPeriod=1;
double g_magicTrailFast=0.1;
double g_magicTrailSlow=1.0;
int g_magicTrailShift=0;
double g_magicTrailOffset=0.0;
bool g_useCompound=false;
bool g_compoundMulti=false;
int g_startYear=2024;
datetime g_scheduleDates[13];
bool g_useZoneRecovery=false;
double g_zrMinDist=5.0;
double g_zrMaxLoss=99.0;
int g_zrMagic1=999;
int g_zrMagic2=9999;
int g_zrMagic3=99999;
int g_zrLotStep=600;
double g_zrLotFactor=1.0;
double g_zrMaxLots=10.0;
double g_zrProfitTarget=2.0;
string g_sep_performance="==== Performance numbers overview ====";
bool g_showPerformance=true;
int g_perfRankMode=1;
int g_perfSortMode=1;
int g_perfReduction1=90;
int g_perfReduction2=30;
int g_perfMinTrades=10;
int g_perfLookback=50;
bool g_useWeightedPerf=true;
string g_sep_zoneRecovery="------------------------------zone_recovery_settings------------------------------";
bool g_zrEnabled=false;
double g_zrZoneSize=50.0;
double g_zrStep=10.0;
double g_zrMinStep=5.0;
double g_zrMaxStep=0.0;
int g_zrMaxOrders=1;
double g_zrLotMultiplier=2.0;
int g_zrMaxMagic=999;
double g_zrMaxDD=100.0;
int g_zrBuyMagic=900010;
int g_zrSellMagic=900011;
string g_sep_tradingHours="------------------------- Trading hours ST1 -------------------------";
bool g_useTradingHours=false;
int g_tradingHoursMode=2;
bool g_useGMTOffset=false;
int g_monStart=0;
int g_monEnd=24;
int g_tueStart=0;
int g_tueEnd=24;
int g_wedStart=0;
int g_wedEnd=24;
int g_thuStart=0;
int g_thuEnd=24;
int g_friStart=0;
int g_friEnd=24;
int g_satStart=0;
int g_satEnd=24;
string g_sep_backtestOnly="------------------------- use for backtesting only! -------------------------";
int g_backtestYear=0;
double g_backtestLot=0.0;
double g_backtestBalance=0.0;
int g_digits=0;
double g_ask=0.0;
int g_openBuyCount=0;
int g_openSellCount=0;
bool g_hasBuyOrder=false;
bool g_hasSellOrder=false;
double g_perfMatrix[20][2];
double g_tradeHistory[100][3];
double g_tradeStats[100][2];
int g_panelX=20;
int g_panelY=100;
double g_totalBuyLots=0.0;
double g_totalSellLots=0.0;
double g_totalOpenProfit=0.0;
double g_totalBuyProfit=0.0;
double g_totalSellProfit=0.0;
double g_totalPendingLots=0.0;
bool g_hasOpenTrades=false;
int g_totalOpenOrders=10;
double g_closedBuyProfit=0.0;
double g_closedSellProfit=0.0;
double g_closedTotalProfit=0.0;
double g_equityDrawdown=0.0;
bool g_virtualSLActive=false;
int g_virtualSLMode=1;
datetime g_pairLastBar[99];
long g_chartID=0;
int g_panelWidth=370;
bool g_panelVisible=true;
bool g_panelMinimized=false;
int g_panelRows=0;
double g_minStopLevel=4.0;
double g_freezeLevel=0.0;
double g_pairStratLots[99];
double g_currentBid=0.0;
int g_barCount=0;
int g_prevBarCount=0;
double g_prevClose=0.0;
double g_prevOpen=0.0;
double g_pointSize=0.0;
int g_lastError=0;
bool g_isFirstTick=false;
double g_highPrice=0.0;
double g_lowPrice=0.0;
int g_expirySeconds=0;
double g_entryPrice=0.0;
double g_stopLossPrice=0.0;
double g_takeProfitPrice=0.0;
bool g_fridayClose=false;
bool g_nfpActive=false;
bool g_dailySwitchDone=false;
double g_pairOpenProfit[99];
double g_pairClosedProfit[99];
double g_st1_entryHigh=0.0;
double g_st1_entryLow=0.0;
double g_st1_SL=0.0;
double g_st1_TP=0.0;
double g_st2_entryHigh=0.0;
double g_st2_entryLow=0.0;
double g_st2_SL=0.0;
int g_st2_TP=0;
double g_st2_lots=0.0;
string g_orderComment1;
string g_orderComment2;
string g_orderComment3;
string g_orderComment4;
bool g_pendBuyExists=false;
bool g_pendSellExists=false;
int g_pendBuyTicket=0;
int g_pendSellTicket=0;
double g_pendBuyPrice=0.0;
double g_pendSellPrice=0.0;
double g_pendBuySL=0.0;
double g_pendSellSL=0.0;
double g_pendBuyTP=0.0;
int g_openBuyTicket=0;
int g_openSellTicket=0;
int g_errorCount=0;
double g_openBuyPrice=0.0;
double g_openSellPrice=0.0;
double g_openBuySL=0.0;
double g_openSellSL=0.0;
double g_openBuyTP=0.0;
double g_openSellTP=0.0;
int g_tradeErrCount=0;
double g_openBuyLots=0.0;
double g_openSellLots=0.0;
double g_openBuyProfit=0.0;
bool g_sl_hitBuy=false;
bool g_sl_hitSell=false;
bool g_tp_hitBuy=false;
bool g_tp_hitSell=false;
bool g_trail_activeBuy=false;
bool g_trail_activeSell=false;
double g_trail_highWater=0.0;
double g_trail_lowWater=0.0;
bool g_be_activeBuy=false;
double g_be_buyLevel=0.0;
double g_be_sellLevel=0.0;
int g_hlTrail_barBuy=0;
int g_hlTrail_barSell=0;
double g_recentHighs[10];
double g_recentLows[10];
double g_recentBuyEntry[10];
double g_recentSellEntry[10];
int g_pendBuyCount=0;
int g_pendSellCount=0;
int g_openBuyTotal=0;
int g_openSellTotal=0;
string g_symbolSuffix;
double g_accountBalance=0.0;
double g_prevBalance=0.0;
datetime g_lastTradeTime=0;
bool g_isInitialized=false;
int g_initRetries=0;
bool g_symbolReady=false;
int g_strategyIndex=0;
double g_balance=0.0;
double g_equity=0.0;
double g_stopLevelPts=0.0;
double g_ddStartBalance=0.0;
double g_maxDDBalance=0.0;
bool g_ddLimitReached=false;
datetime g_dayStartTime=0;
datetime g_weekStartTime=0;
datetime g_lastBarTime=0;
bool g_newDayFlag=false;
bool g_newWeekFlag=false;
double g_dailyStartBal=0.0;
datetime g_dailyResetTime=0;
bool g_dailyDDHit=false;
int g_pairBuyTickets[99];
int g_pairSellTickets[99];
double g_hlBuyBuffer[30];
double g_hlSellBuffer[30];
double g_magicBuyBuffer[30];
double g_magicSellBuffer[30];
int g_pairCount=1;
int g_pairIdx=0;
uint g_panelFgColor=DarkBlue;
bool g_slipMode2=false;
long g_prevVolume=0;
int g_slipRetries=5;
bool g_orderModified=false;
string g_currentSymbol;
bool g_orderPending=false;
string g_tradeSymbol;
double g_point=0.0;
double g_lotStep=0.0;
int g_stratMagics[99];
int g_labelIdx=0;
double g_pairLots[99];
bool g_pairActive[99];
int g_pairBuyOpen[99];
int g_pairSellOpen[99];
double g_pairBuyPrice[99];
double g_pairSellPrice[99];
string g_pairNames[99]={};
bool g_pairHasOrder[99];
double g_pairBuySL[99];
double g_pairSellSL[99];
double g_pairBuyTP[99];
double g_pairSellTP[99];
double g_pairBuyLots[99];
double g_pairSellLots[99];
bool g_pairNewBar[99];
int g_pairBarCount[99];
bool g_showPanel=false;
double g_panelFontSize=5.0;
double g_panelRowH=10.0;
int g_panelCols=0;
double g_panelColW=0.0;
double g_panelRowPx=0.0;
int g_panelLabels=0;
uint g_panelBgColor=LightSteelBlue;
bool g_panelBorder=true;
double g_panelBorderW=12.0;
int g_panelPosX=230;
int g_panelPosY=320;
int g_panelW=500;
int g_panelH=350;
int g_panelAlign=2;
int g_panelFont=7;
int g_panelMaxRows=10;
int g_panelMaxCols=30;
string g_stratLabels[4]={};
double g_panelScaleSmall=0.45;
double g_panelScaleLarge=0.6;
int g_activePairs=0;
datetime g_lastInitTime=0;
bool g_pairInitOK=false;
int g_labelCount=0;
bool g_panelCreated=false;
int g_panelUpdateCnt=0;
double g_prevEquity=0.0;
int g_panelCol1X=200;
int g_panelCol2X=330;
int g_panelCol3X=560;
int g_autoMaxTrades=810;
int g_autoCount=1150;
datetime g_autoResetTime=0;
datetime g_nfpDates[300];
bool g_nfpChecked=false;
bool g_nfpToday=false;
bool g_nfpWindowOpen=false;
int g_nfpGMTOfs=0;
int g_gmtOffset=0;
double g_gmtOffsetFloat=0.0;
double g_maxEquityDD=0.0;
datetime g_ddResetTime=0;
double g_stratScores[99];
double g_balForLots=0.0;
double g_balSnapshot=0.0;


int OnInit()
{
if(TimeCurrent()>ExpiryDate)
{
   Alert("The Gold Reaper: EA da het han su dung (han: "+TimeToString(ExpiryDate,TIME_DATE|TIME_MINUTES)+"). Vui long lien he de gia han.");
   return(INIT_FAILED);
}
g_startLots=StartLots;
double lv_d2;
double lv_d3;
int lv_i4;
int lv_i5;
int lv_i6;
int lv_i7;
int lv_i8;
int lv_i9;
//----------
bool tmp_b1 = false;

g_balForLots=AccountInfoDouble(ACCOUNT_BALANCE);
if(UseEquity)
{
g_balForLots=AccountInfoDouble(ACCOUNT_EQUITY);
}
if(ForceBalanceToUse>0.0)
{
g_balForLots=ForceBalanceToUse;
}
g_balSnapshot=g_balForLots;
g_nfpChecked=false;
g_nfpToday=false;
g_nfpDates[0]=D'2026.12.04 12:30';
g_nfpDates[1]=D'2026.11.06 12:30';
g_nfpDates[2]=D'2026.10.02 12:30';
g_nfpDates[3]=D'2026.09.04 12:30';
g_nfpDates[4]=D'2026.08.07 12:30';
g_nfpDates[5]=D'2026.07.02 12:30';
g_nfpDates[6]=D'2026.06.05 12:30';
g_nfpDates[7]=D'2026.05.08 12:30';
g_nfpDates[8]=D'2026.04.03 12:30';
g_nfpDates[9]=D'2026.03.06 12:30';
g_nfpDates[10]=D'2026.02.11 12:30';
g_nfpDates[11]=D'2026.01.09 12:30';
g_nfpDates[12]=D'2025.12.16 12:30';
g_nfpDates[13]=D'2025.11.07 12:30';
g_nfpDates[14]=D'2025.10.03 12:30';
g_nfpDates[15]=D'2025.09.05 12:30';
g_nfpDates[16]=D'2025.08.01 12:30';
g_nfpDates[17]=D'2025.07.03 12:30';
g_nfpDates[18]=D'2025.06.06 12:30';
g_nfpDates[19]=D'2025.05.02 12:30';
g_nfpDates[20]=D'2025.04.04 12:30';
g_nfpDates[21]=D'2025.03.07 12:30';
g_nfpDates[22]=D'2025.02.07 12:30';
g_nfpDates[23]=D'2025.01.10 12:30';
g_nfpDates[24]=D'2024.12.06 12:30';
g_nfpDates[25]=D'2024.11.01 12:30';
g_nfpDates[26]=D'2024.10.04 12:30';
g_nfpDates[27]=D'2024.09.06 12:30';
g_nfpDates[28]=D'2024.08.02 12:30';
g_nfpDates[29]=D'2024.07.05 12:30';
g_nfpDates[30]=D'2024.06.07 12:30';
g_nfpDates[31]=D'2024.05.03 12:30';
g_nfpDates[32]=D'2024.04.05 12:30';
g_nfpDates[33]=D'2024.03.08 12:30';
g_nfpDates[34]=D'2024.02.02 12:30';
g_nfpDates[35]=D'2024.01.05 12:30';
g_nfpDates[36]=D'2023.12.08 12:30';
g_nfpDates[37]=D'2023.11.03 12:30';
g_nfpDates[38]=D'2023.10.06 12:30';
g_nfpDates[39]=D'2023.09.01 12:30';
g_nfpDates[40]=D'2023.08.04 12:30';
g_nfpDates[41]=D'2023.07.07 12:30';
g_nfpDates[42]=D'2023.06.02 12:30';
g_nfpDates[43]=D'2023.05.05 12:30';
g_nfpDates[44]=D'2023.04.07 12:30';
g_nfpDates[45]=D'2023.03.10 12:30';
g_nfpDates[46]=D'2023.02.03 12:30';
g_nfpDates[47]=D'2023.01.06 12:30';
g_nfpDates[48]=D'2022.12.02 12:30';
g_nfpDates[49]=D'2022.11.04 12:30';
g_nfpDates[50]=D'2022.10.07 12:30';
g_nfpDates[51]=D'2022.09.02 12:30';
g_nfpDates[52]=D'2022.08.05 12:30';
g_nfpDates[53]=D'2022.07.08 12:30';
g_nfpDates[54]=D'2022.06.03 12:30';
g_nfpDates[55]=D'2022.05.06 12:30';
g_nfpDates[56]=D'2022.04.01 12:30';
g_nfpDates[57]=D'2022.03.04 12:30';
g_nfpDates[58]=D'2022.02.04 12:30';
g_nfpDates[59]=D'2022.01.07 12:30';
g_nfpDates[60]=D'2021.12.03 12:30';
g_nfpDates[61]=D'2021.11.05 12:30';
g_nfpDates[62]=D'2021.10.08 12:30';
g_nfpDates[63]=D'2021.09.03 12:30';
g_nfpDates[64]=D'2021.08.06 12:30';
g_nfpDates[65]=D'2021.07.02 12:30';
g_nfpDates[66]=D'2021.06.04 12:30';
g_nfpDates[67]=D'2021.05.07 12:30';
g_nfpDates[68]=D'2021.04.02 12:30';
g_nfpDates[69]=D'2021.03.05 12:30';
g_nfpDates[70]=D'2021.02.05 12:30';
g_nfpDates[71]=D'2021.01.08 12:30';
g_nfpDates[72]=D'2020.12.04 12:30';
g_nfpDates[73]=D'2020.11.06 12:30';
g_nfpDates[74]=D'2020.10.02 12:30';
g_nfpDates[75]=D'2020.09.04 12:30';
g_nfpDates[76]=D'2020.08.07 12:30';
g_nfpDates[77]=D'2020.07.02 12:30';
g_nfpDates[78]=D'2020.06.05 12:30';
g_nfpDates[79]=D'2020.05.08 12:30';
g_nfpDates[80]=D'2020.04.03 12:30';
g_nfpDates[81]=D'2020.03.06 12:30';
g_nfpDates[82]=D'2020.02.07 12:30';
g_nfpDates[83]=D'2020.01.10 12:30';
g_nfpDates[84]=D'2019.12.06 12:30';
g_nfpDates[85]=D'2019.11.01 12:30';
g_nfpDates[86]=D'2019.10.04 12:30';
g_nfpDates[87]=D'2019.09.06 12:30';
g_nfpDates[88]=D'2019.08.02 12:30';
g_nfpDates[89]=D'2019.07.05 12:30';
g_nfpDates[90]=D'2019.06.07 12:30';
g_nfpDates[91]=D'2019.05.03 12:30';
g_nfpDates[92]=D'2019.04.05 12:30';
g_nfpDates[93]=D'2019.03.08 12:30';
g_nfpDates[94]=D'2019.02.01 12:30';
g_nfpDates[95]=D'2019.01.04 12:30';
g_nfpDates[96]=D'2018.12.07 12:30';
g_nfpDates[97]=D'2018.11.02 12:30';
g_nfpDates[98]=D'2018.10.05 12:30';
g_nfpDates[99]=D'2018.09.07 12:30';
g_nfpDates[100]=D'2018.08.03 12:30';
g_nfpDates[101]=D'2018.07.06 12:30';
g_nfpDates[102]=D'2018.06.01 12:30';
g_nfpDates[103]=D'2018.05.04 12:30';
g_nfpDates[104]=D'2018.04.06 12:30';
g_nfpDates[105]=D'2018.03.09 12:30';
g_nfpDates[106]=D'2018.02.02 12:30';
g_nfpDates[107]=D'2018.01.05 12:30';
g_nfpDates[108]=D'2017.12.08 12:30';
g_nfpDates[109]=D'2017.11.03 12:30';
g_nfpDates[110]=D'2017.10.06 12:30';
g_nfpDates[111]=D'2017.09.01 12:30';
g_nfpDates[112]=D'2017.08.04 12:30';
g_nfpDates[113]=D'2017.07.07 12:30';
g_nfpDates[114]=D'2017.06.02 12:30';
g_nfpDates[115]=D'2017.05.05 12:30';
g_nfpDates[116]=D'2017.04.07 12:30';
g_nfpDates[117]=D'2017.03.10 12:30';
g_nfpDates[118]=D'2017.02.03 12:30';
g_nfpDates[119]=D'2017.01.06 12:30';
g_nfpDates[120]=D'2016.12.02 12:30';
g_nfpDates[121]=D'2016.11.04 12:30';
g_nfpDates[122]=D'2016.10.07 12:30';
g_nfpDates[123]=D'2016.09.02 12:30';
g_nfpDates[124]=D'2016.08.05 12:30';
g_nfpDates[125]=D'2016.07.08 12:30';
g_nfpDates[126]=D'2016.06.03 12:30';
g_nfpDates[127]=D'2016.05.06 12:30';
g_nfpDates[128]=D'2016.04.01 12:30';
g_nfpDates[129]=D'2016.03.04 12:30';
g_nfpDates[130]=D'2016.02.05 12:30';
g_nfpDates[131]=D'2016.01.08 12:30';
g_nfpDates[132]=D'2015.12.04 12:30';
g_nfpDates[133]=D'2015.11.06 12:30';
g_nfpDates[134]=D'2015.10.02 12:30';
g_nfpDates[135]=D'2015.09.04 12:30';
g_nfpDates[136]=D'2015.08.07 12:30';
g_nfpDates[137]=D'2015.07.02 12:30';
g_nfpDates[138]=D'2015.06.05 12:30';
g_nfpDates[139]=D'2015.05.08 12:30';
g_nfpDates[140]=D'2015.04.03 12:30';
g_nfpDates[141]=D'2015.03.06 12:30';
g_nfpDates[142]=D'2015.02.06 12:30';
g_nfpDates[143]=D'2015.01.09 12:30';
g_nfpDates[144]=D'2014.12.05 12:30';
g_nfpDates[145]=D'2014.11.07 12:30';
g_nfpDates[146]=D'2014.10.03 12:30';
g_nfpDates[147]=D'2014.09.05 12:30';
g_nfpDates[148]=D'2014.08.01 12:30';
g_nfpDates[149]=D'2014.07.03 12:30';
g_nfpDates[150]=D'2014.06.06 12:30';
g_nfpDates[151]=D'2014.05.02 12:30';
g_nfpDates[152]=D'2014.04.04 12:30';
g_nfpDates[153]=D'2014.03.07 12:30';
g_nfpDates[154]=D'2014.02.07 12:30';
g_nfpDates[155]=D'2014.01.10 12:30';
g_nfpDates[156]=D'2013.12.06 12:30';
g_nfpDates[157]=D'2013.11.08 12:30';
g_nfpDates[158]=D'2013.10.22 12:30';
g_nfpDates[159]=D'2013.09.06 12:30';
g_nfpDates[160]=D'2013.08.02 12:30';
g_nfpDates[161]=D'2013.07.05 12:30';
g_nfpDates[162]=D'2013.06.07 12:30';
g_nfpDates[163]=D'2013.05.03 12:30';
g_nfpDates[164]=D'2013.04.05 12:30';
g_nfpDates[165]=D'2013.03.08 12:30';
g_nfpDates[166]=D'2013.02.01 12:30';
g_nfpDates[167]=D'2013.01.04 12:30';
g_nfpDates[168]=D'2012.12.07 12:30';
g_nfpDates[169]=D'2012.11.02 12:30';
g_nfpDates[170]=D'2012.10.05 12:30';
g_nfpDates[171]=D'2012.09.07 12:30';
g_nfpDates[172]=D'2012.08.03 12:30';
g_nfpDates[173]=D'2012.07.06 12:30';
g_nfpDates[174]=D'2012.06.01 12:30';
g_nfpDates[175]=D'2012.05.04 12:30';
g_nfpDates[176]=D'2012.04.06 12:30';
g_nfpDates[177]=D'2012.03.09 12:30';
g_nfpDates[178]=D'2012.02.03 12:30';
g_nfpDates[179]=D'2012.01.06 12:30';
g_nfpDates[180]=D'2011.12.02 12:30';
g_nfpDates[181]=D'2011.11.04 12:30';
g_nfpDates[182]=D'2011.10.07 12:30';
g_nfpDates[183]=D'2011.09.02 12:30';
g_nfpDates[184]=D'2011.08.05 12:30';
g_nfpDates[185]=D'2011.07.08 12:30';
g_nfpDates[186]=D'2011.06.03 12:30';
g_nfpDates[187]=D'2011.05.06 12:30';
g_nfpDates[188]=D'2011.04.01 12:30';
g_nfpDates[189]=D'2011.03.04 12:30';
g_nfpDates[190]=D'2011.02.04 12:30';
g_nfpDates[191]=D'2011.01.07 12:30';
g_nfpDates[192]=D'2010.12.03 12:30';
g_nfpDates[193]=D'2010.11.05 12:30';
g_nfpDates[194]=D'2010.10.08 12:30';
g_nfpDates[195]=D'2010.09.03 12:30';
g_nfpDates[196]=D'2010.08.06 12:30';
g_nfpDates[197]=D'2010.07.02 12:30';
g_nfpDates[198]=D'2010.06.04 12:30';
g_nfpDates[199]=D'2010.05.07 12:30';
g_nfpDates[200]=D'2010.04.02 12:30';
g_nfpDates[201]=D'2010.03.05 12:30';
g_nfpDates[202]=D'2010.02.05 12:30';
g_nfpDates[203]=D'2010.01.08 12:30';
g_nfpDates[204]=D'2009.12.04 12:30';
g_nfpDates[205]=D'2009.11.06 12:30';
g_nfpDates[206]=D'2009.10.02 12:30';
g_nfpDates[207]=D'2009.09.04 12:30';
g_nfpDates[208]=D'2009.08.07 12:30';
g_nfpDates[209]=D'2009.07.02 12:30';
g_nfpDates[210]=D'2009.06.05 12:30';
g_nfpDates[211]=D'2009.05.08 12:30';
g_nfpDates[212]=D'2009.04.03 12:30';
g_nfpDates[213]=D'2009.03.06 12:30';
g_nfpDates[214]=D'2009.02.06 12:30';
g_nfpDates[215]=D'2009.01.09 12:30';
g_nfpDates[216]=D'2008.12.05 12:30';
g_nfpDates[217]=D'2008.11.07 12:30';
g_nfpDates[218]=D'2008.10.03 12:30';
g_nfpDates[219]=D'2008.09.05 12:30';
g_nfpDates[220]=D'2008.08.01 12:30';
g_nfpDates[221]=D'2008.07.03 12:30';
g_nfpDates[222]=D'2008.06.06 12:30';
g_nfpDates[223]=D'2008.05.02 12:30';
g_nfpDates[224]=D'2008.04.04 12:30';
g_nfpDates[225]=D'2008.03.07 12:30';
g_nfpDates[226]=D'2008.02.01 12:30';
g_nfpDates[227]=D'2008.01.04 12:30';
g_nfpDates[228]=D'2007.12.07 12:30';
g_nfpDates[229]=D'2007.11.02 12:30';
g_nfpDates[230]=D'2007.10.05 12:30';
g_nfpDates[231]=D'2007.09.07 12:30';
g_nfpDates[232]=D'2007.08.03 12:30';
g_nfpDates[233]=D'2007.07.06 12:30';
g_nfpDates[234]=D'2007.06.01 12:30';
g_nfpDates[235]=D'2007.05.04 12:30';
g_nfpDates[236]=D'2007.04.06 12:30';
g_nfpDates[237]=D'2007.03.09 12:30';
g_nfpDates[238]=D'2007.02.02 12:30';
g_nfpDates[239]=D'2007.01.05 12:30';
if(Risk==1234)
{
g_startLots=MarketInfo(g_tradeSymbol,MODE_MINLOT);
}
if(TradeFrequency==5&&Risk==1234)
{
lv_d2=ConvertToUSD(AccountInfoDouble(ACCOUNT_BALANCE));
lv_d3=MaxAllowedDD/100.0*lv_d2;
if(lv_d3>g_autoMaxTrades)
{
g_minBarsBetween=3;
}
else
{
if(lv_d3>g_panelCol3X)
{
g_minBarsBetween=2;
}
else
{
if(lv_d3>g_panelCol2X)
{
g_minBarsBetween=1;
}
else
{
g_minBarsBetween=0;
}
}
}
}
else
{
g_minBarsBetween=TradeFrequency;
}
if(g_minBarsBetween==0)
{
g_strat8_enabled=false;
g_strat12_enabled=false;
g_strat9_enabled=false;
g_strat14_enabled=false;
g_strat15_enabled=false;
g_strat13_enabled=false;
g_maxEquityDD=2.4;
if(UseVariableValues)
{
g_maxEquityDD=3.0;
}
}
else
{
if(g_minBarsBetween==1)
{
g_strat8_enabled=true;
g_strat12_enabled=true;
g_strat9_enabled=false;
g_strat14_enabled=false;
g_strat15_enabled=false;
g_strat13_enabled=false;
g_maxEquityDD=3.4;
if(UseVariableValues)
{
g_maxEquityDD=4.0;
}
}
else
{
if(g_minBarsBetween==2)
{
g_strat8_enabled=true;
g_strat12_enabled=true;
g_strat9_enabled=true;
g_strat14_enabled=true;
g_strat15_enabled=false;
g_strat13_enabled=false;
g_maxEquityDD=4.1;
if(UseVariableValues)
{
g_maxEquityDD=5.0;
}
}
else
{
if(g_minBarsBetween==3)
{
g_strat8_enabled=true;
g_strat12_enabled=true;
g_strat9_enabled=true;
g_strat14_enabled=true;
g_strat15_enabled=true;
g_strat13_enabled=false;
g_maxEquityDD=4.8;
if(UseVariableValues)
{
g_maxEquityDD=5.6;
}
}
else
{
if(g_minBarsBetween==4)
{
g_strat8_enabled=true;
g_strat12_enabled=true;
g_strat9_enabled=true;
g_strat14_enabled=true;
g_strat15_enabled=true;
g_strat13_enabled=true;
g_maxEquityDD=5.1;
if(UseVariableValues)
{
g_maxEquityDD=6.0;
}
}
else
{
if(g_minBarsBetween==6)
{
g_strat1_enabled=RunStrat1;
g_strat4_enabled=RunStrat2;
g_strat7_enabled=RunStrat3;
g_strat8_enabled=RunStrat4;
g_strat12_enabled=RunStrat5;
g_strat9_enabled=RunStrat6;
g_strat14_enabled=RunStrat7;
g_strat15_enabled=RunStrat8;
g_strat13_enabled=RunStrat9;
}
}
}
}
}
}
g_currentSymbol=ST1_Comment;
g_prevEquity=0.0;
g_panelCreated=false;
g_lastInitTime=0;
g_pairInitOK=true;
g_panelFontSize=5.0;
g_panelRowH=10.0;
g_magicMain=ST1_MagicNumber;
g_panelCols=300;
g_panelColW=g_panelFont*25*g_panelScaleSmall*InfoPanelSizeAdjust;
g_panelRowPx=g_panelFont*3.5*g_panelScaleLarge*InfoPanelSizeAdjust;
g_panelLabels=7;
g_pairIdx=0;
g_tradeSymbol=Symbol();
g_point=SymbolInfoDouble(g_tradeSymbol,SYMBOL_TRADE_TICK_SIZE);
g_pointSize=g_point;
if((MarketInfo(g_tradeSymbol,MODE_DIGITS)==3.0||MarketInfo(g_tradeSymbol,MODE_DIGITS)==5.0))
{
g_pointSize=g_point*10.0;
}
if(SymbolInfoInteger(g_tradeSymbol,17)==0x1)
{
g_pointSize=g_point/10.0;
}
g_digits = (int)MarketInfo(g_tradeSymbol,MODE_DIGITS);
if(FridayStopHour< 0)
{
g_useMonFilter=false;
}
else
{
g_useMonFilter=true;
}
g_st2_lots=(double)TimeCurrent();
g_spread=MarketInfo(g_tradeSymbol,MODE_ASK)-MarketInfo(g_tradeSymbol,MODE_BID);
g_pairStratLots[g_pairIdx]=NormalizeDouble(MathFloor(g_startLots*100.0)/100.0,2);
if(MarketInfo(g_tradeSymbol,MODE_LOTSTEP)==0.1)
{
g_pairStratLots[g_pairIdx]=NormalizeDouble((MathFloor(g_startLots*10.0))/10.0,1);
if(g_pairStratLots[g_pairIdx]<0.1)
{
g_pairStratLots[g_pairIdx]=0.1;
}
}
if(g_pairStratLots[g_pairIdx]<MarketInfo(g_tradeSymbol,MODE_MINLOT))
{
g_pairStratLots[g_pairIdx]=MarketInfo(g_tradeSymbol,MODE_MINLOT);
}
if(g_pairStratLots[g_pairIdx]>MarketInfo(g_tradeSymbol,MODE_MAXLOT))
{
g_pairStratLots[g_pairIdx]=MarketInfo(g_tradeSymbol,MODE_MAXLOT);
}
g_strategyIndex=iBars(g_tradeSymbol,MT4Period(PERIOD_CURRENT));
if(g_magicTrailFast*g_pointSize<g_point)
{
g_magicTrailFast=g_point/g_pointSize;
}
g_balance=AccountBalance();
g_minStopLevel=MarketInfo(g_tradeSymbol,MODE_STOPLEVEL)*g_point;
g_stopLevelPts=MarketInfo(g_tradeSymbol,MODE_FREEZELEVEL)*g_point;
g_symbolSuffix=StringSubstr(Symbol(),6,10);
if(g_symbolSuffix!="")
{
Print("Suffix detected: "+g_symbolSuffix);
}
if((StringFind(Symbol(),"XAUUSD",0)>=0||StringFind(Symbol(),"xauusd",0)>=0||StringFind(Symbol(),"GOLD",0)>=0||StringFind(Symbol(),"gold",0)>=0||StringFind(Symbol(),"Gold",0)>=0||StringFind(Symbol(),"GLD",0)>=0))
{
g_tradeSymbol=Symbol();
g_pairNames[g_activePairs]=Symbol();
LoadStrategy1Params();
InitSymbolData(0);
g_activePairs++;
}
else
{
g_tradeSymbol=Symbol();
InitSymbolData(0);
}
if(!(g_pairInitOK))
{
Print("Initialisation of pairs failed!");
}
if(g_minProfitClose<=0.0)
{
g_minProfitClose=1.0;
}
if(g_maxLossClose<=0.0)
{
g_maxLossClose=1.0;
}
if(g_beOffset>g_beProfitTrigger)
{
g_beOffset=g_beProfitTrigger+0.1;
}
if(g_fakeoutStrength<g_stopLevelPts/g_pointSize)
{
g_fakeoutStrength = (int)(g_stopLevelPts/g_pointSize);
}
if(g_trailStep!=0.0&&g_trailStep<g_stopLevelPts/g_pointSize)
{
g_trailStep=g_stopLevelPts/g_pointSize;
}
if(g_trailStep!=0.0&&g_trailStep<g_minStopLevel/g_pointSize)
{
g_trailStep=g_minStopLevel/g_pointSize;
}
if(g_recovTrailStart>0.0&&g_recovTrailStep<g_stopLevelPts/g_pointSize)
{
g_recovTrailStep=g_stopLevelPts/g_pointSize;
}
if(g_recovTrailStart>0.0&&g_recovTrailStep<g_minStopLevel/g_pointSize)
{
g_recovTrailStep=g_minStopLevel/g_pointSize;
}
if(g_minProfitClose<g_minStopLevel*2.0/g_pointSize)
{
g_minProfitClose=g_minStopLevel*2.0/g_pointSize;
}
if(g_maxLossClose<g_minStopLevel*2.0/g_pointSize)
{
g_maxLossClose=g_minStopLevel*2.0/g_pointSize;
}
if(g_takeProfitPips<g_minStopLevel*2.0/g_pointSize)
{
g_takeProfitPips=g_minStopLevel*2.0/g_pointSize;
}
if(g_entryBars< 1)
{
g_entryBars=1;
}
if(g_entryRetries< 1)
{
g_entryRetries=1;
}
if(g_takeProfitPips<0.1)
{
g_takeProfitPips=0.1;
}
g_expirySeconds=g_expiryHours*60*60;
if(g_expiryHours> 0)
{
g_lastTradeTime=TimeCurrent()+g_expirySeconds;
}
else
{
g_lastTradeTime=0;
}
if(Virtual_expiration)
{
g_lastTradeTime=0;
}
g_dailyDDHit=false;
g_pendBuyPrice=Seconds();
g_dailyResetTime=TimeCurrent();
g_hasBuyOrder=false;
g_hasSellOrder=false;
g_pendBuyTicket=Month();
g_dayStartTime=iTime(g_tradeSymbol,MT4Period(PERIOD_W1),1);
g_weekStartTime=iTime(g_tradeSymbol,MT4Period(PERIOD_M1),1);
g_lastBarTime=iTime(g_tradeSymbol,MT4Period(PERIOD_M1),1);
if(g_minVolatility>MaxSpread)
{
g_minVolatility=MaxSpread;
}
g_pendSellExists=false;
GetBuyEntryPrice(g_entryTF);
GetSellEntryPrice(g_entryTF);
g_backtestLot=NormalizeDouble(g_pendBuySL,g_digits);
g_backtestBalance=NormalizeDouble(g_pendSellPrice,g_digits);
g_st2_TP=0;
g_pendBuyExists=false;
g_initRetries = (int)(g_recovTrailStart*60.0);
g_useZoneRecovery=false;
g_isInitialized=true;
g_stopLevelPts=MarketInfo(g_tradeSymbol,MODE_FREEZELEVEL)*g_point;
if(!(g_useTradingHours))
{
g_isInitialized=false;
}
g_ask=0.0;
g_totalBuyLots=0.0;
g_totalSellLots=0.0;
g_dailySwitchDone=false;
g_symbolSuffix=StringSubstr(g_tradeSymbol,6,0);
if(Risk> 0)
{
g_useZoneRecovery=true;
}
if(g_startLots<0.0)
{
g_startLots=0.01;
}
if(g_zrMaxLoss>MarketInfo(g_tradeSymbol,MODE_MAXLOT))
{
g_zrMaxLoss=MarketInfo(g_tradeSymbol,MODE_MAXLOT);
}
for(lv_i4=0;lv_i4<g_panelX;lv_i4++)
{
for(lv_i5=0;lv_i5<2;lv_i5++)
{
g_perfMatrix[lv_i4][lv_i5]=0.0;
}
}
for(lv_i6=0;lv_i6<g_panelY;lv_i6++)
{
for(lv_i7=0;lv_i7<3;lv_i7++)
{
g_tradeHistory[lv_i6][lv_i7]=0.0;
}
}
for(lv_i8=0;lv_i8<100;lv_i8++)
{
g_tradeHistory[lv_i8][0]=0.0;
g_tradeHistory[lv_i8][1]=0.0;
}
g_symbolReady=false;
g_openBuyTP=iFractals(g_tradeSymbol,0,1,1);
g_openSellTP=iFractals(g_tradeSymbol,0,2,1);
g_openBuySL=g_openBuyTP;
g_openSellSL=g_openSellTP;
g_openBuyLots=0.0;
g_isFirstTick=false;
g_hlTrail_barSell=Hour();
g_hlTrail_barBuy=0;
g_orderComment1=ST1_Comment+"B1";
g_orderComment2=ST1_Comment+"B2";
g_orderComment3=ST1_Comment+"S1";
g_orderComment4=ST1_Comment+"S2";
g_openBuyTotal=0;
g_openSellTotal=0;
g_errorCount=Hour();
if(g_useSpreadFilter)
{
g_maxConcurrent=1;
g_sl_hitBuy=true;
g_sl_hitSell=true;
}
g_closedBuyProfit=999.0;
g_closedSellProfit=0.0;
g_accountBalance=0.0;
g_prevBalance=0.0;
for(lv_i9=0;lv_i9<99;lv_i9++)
{
g_pairSellTickets[lv_i9]=0;
g_pairBuyTickets[lv_i9]=0;
g_pairLastBar[lv_i9]=iTime(g_tradeSymbol,MT4Period(g_entryTF),1);
if(!(g_pairStratLots[lv_i9]<g_startLots)) continue;
g_pairStratLots[lv_i9]=g_startLots;

}
g_chartID=0;
g_fridayClose=false;
g_nfpActive=false;
if(g_newsFilterMode==1)
{
g_newsImpactLevel=0.0;
}
g_digits = (int)MarketInfo(g_tradeSymbol,MODE_DIGITS);
g_ddLimitReached=false;
IsDemo();

if(tmp_b1==true)
{
g_ddLimitReached=true;
}
if(ShowInfoPanel)
{
if(g_perfSortMode==1)
{
ProcessBuyStrategies();
}
else
{
if(g_perfSortMode==2)
{
ProcessSellStrategies();
}
}
UpdateInfoPanel();
DrawPanelBackground();
DrawPanelDetails();
}
return(0);
}
// init<<==-------- --------
void OnTick()
{
if(TimeCurrent()>ExpiryDate)
{
   Comment("The Gold Reaper: EA da het han su dung (han: "+TimeToString(ExpiryDate,TIME_DATE|TIME_MINUTES)+"). Vui long lien he de gia han.");
   return;
}
bool lv_b1;
double lv_d2;
double lv_d3;
bool lv_b4;
MqlDateTime lv_mqlDst1;
MqlDateTime lv_mqlDst2;
//----------
bool tmp_b1 = false;
double tmp_d2;
double tmp_d3;
int tmp_i4;
double tmp_d5;
double tmp_d6;
int tmp_i7;
double tmp_d8;
double tmp_d9;
int tmp_i10;
double tmp_d11;
double tmp_d12;
int tmp_i13;
double tmp_d14;
double tmp_d15;
int tmp_i16;
double tmp_d17;
double tmp_d18;
int tmp_i19;
double tmp_d20;
double tmp_d21;
int tmp_i22;
double tmp_d23;
double tmp_d24;
int tmp_i25;
double tmp_d26;
double tmp_d27;
int tmp_i28;

g_balForLots=AccountInfoDouble(ACCOUNT_BALANCE);
if(UseEquity)
{
g_balForLots=AccountInfoDouble(ACCOUNT_EQUITY);
}
if(ForceBalanceToUse>0.0)
{
g_balForLots=ForceBalanceToUse;
}
if(OnlyUp&&g_balSnapshot>g_balForLots)
{
g_balForLots=g_balSnapshot;
}
if(g_balForLots>g_balSnapshot)
{
g_balSnapshot=g_balForLots;
}
if(FakeOutFilter==0)
{
g_use5minFilter=false;
g_use30minFilter=false;
g_useNewsFilter=false;
}
else
{
if(FakeOutFilter==1)
{
g_use5minFilter=true;
g_use30minFilter=false;
g_useNewsFilter=false;
}
else
{
if(FakeOutFilter==2)
{
g_use5minFilter=true;
g_use30minFilter=true;
g_useNewsFilter=false;
}
else
{
if(FakeOutFilter==3)
{
g_use5minFilter=true;
g_use30minFilter=true;
g_useNewsFilter=true;
}
}
}
}
lv_b1=false;
if(IsAmericanDST())
{
g_nfpGMTOfs=Broker_GMT_OFFSET_Summer;
if((!(g_nfpChecked)||!(g_nfpWindowOpen))&&AutoGMT&&!(lv_b1))
{
g_nfpChecked=true;
g_nfpToday=true;
g_gmtOffset=GetGMT_Offset();
if(g_gmtOffset==999)
{
Print("GMT_Offsetwronglydetected. Tryingagaing!");
Sleep(2000);
g_gmtOffset=GetGMT_Offset();
}
if(g_gmtOffset==999)
{
Print("GMT_Offsetstillwrong. UsingVPStimeforGMTdetection!");
}
g_nfpWindowOpen=true;
lv_b1=true;
Print("DST_USon");
}
}
else
{
g_nfpGMTOfs=Broker_GMT_OFFSET_Winter;
if((g_nfpChecked||!(g_nfpWindowOpen))&&AutoGMT&&!(lv_b1))
{
g_nfpChecked=false;
g_nfpToday=false;
g_gmtOffset=GetGMT_Offset();
if(g_gmtOffset==999)
{
Print("GMT_Offsetwronglydetected. Tryingagaing!");
Sleep(2000);
g_gmtOffset=GetGMT_Offset();
}
if(g_gmtOffset==999)
{
Print("GMT_Offsetstillwrong. UsingVPStimeforGMTdetection!");
}
g_nfpWindowOpen=true;
lv_b1=true;
Print("DST_US off");
}
}
TimeToStruct(StringToTime(string(TimeYear(TimeCurrent()))+".03.31 01:00"),lv_mqlDst1);
TimeToStruct(StringToTime(string(TimeYear(TimeCurrent()))+".10.31 02:00"),lv_mqlDst2);
if(TimeDayOfYear(TimeCurrent())> TimeDayOfYear(StringToTime(string(TimeYear(TimeCurrent()))+".03.31 01:00")-lv_mqlDst1.day_of_week*86400)&&TimeDayOfYear(TimeCurrent())< TimeDayOfYear(StringToTime(string(TimeYear(TimeCurrent()))+".10.31 02:00")-lv_mqlDst2.day_of_week*86400))
{
tmp_b1=true;
}
else
{
tmp_b1=false;
}
if(tmp_b1)
{
if((!(g_nfpToday)||!(g_nfpWindowOpen))&&AutoGMT&&!(lv_b1))
{
g_nfpToday=true;
g_gmtOffset=GetGMT_Offset();
if(g_gmtOffset==999)
{
Print("GMT_Offsetwronglydetected. Tryingagaing!");
Sleep(2000);
g_gmtOffset=GetGMT_Offset();
}
if(g_gmtOffset==999)
{
Print("GMT_Offsetstillwrong. UsingVPStimeforGMTdetection!");
}
g_nfpWindowOpen=true;
lv_b1=true;
Print("DST_EUon");
}
}
else
{
if((g_nfpToday||!(g_nfpWindowOpen))&&AutoGMT&&!(lv_b1))
{
g_nfpToday=false;
g_gmtOffset=GetGMT_Offset();
if(g_gmtOffset==999)
{
Print("GMT_Offsetwronglydetected. Tryingagaing!");
Sleep(2000);
g_gmtOffset=GetGMT_Offset();
}
if(g_gmtOffset==999)
{
Print("GMT_Offsetstillwrong. UsingVPStimeforGMTdetection!");
}
g_nfpWindowOpen=true;
lv_b1=true;
Print("DST_EU off");
}
}
if(AutoGMT&&MQLInfoInteger(MQL_TESTER)!=1)
{
if(g_gmtOffset!=999)
{
g_autoResetTime=TimeCurrent()-g_gmtOffset*3600;
}
else
{
g_autoResetTime=TimeGMT();
}
}
else
{
g_autoResetTime=TimeCurrent()-g_nfpGMTOfs*3600;
}
if(TradeFrequency==5&&Risk==1234)
{
lv_d2=ConvertToUSD(AccountInfoDouble(ACCOUNT_BALANCE));
lv_d3=MaxAllowedDD/100.0*lv_d2;
if(lv_d3>g_autoMaxTrades)
{
g_minBarsBetween=3;
}
else
{
if(lv_d3>g_panelCol3X)
{
g_minBarsBetween=2;
}
else
{
if(lv_d3>g_panelCol2X)
{
g_minBarsBetween=1;
}
else
{
g_minBarsBetween=0;
}
}
}
}
else
{
g_minBarsBetween=TradeFrequency;
}
if(g_minBarsBetween==0)
{
g_strat8_enabled=false;
g_strat12_enabled=false;
g_strat9_enabled=false;
g_strat14_enabled=false;
g_strat15_enabled=false;
g_strat13_enabled=false;
g_maxEquityDD=2.4;
if(UseVariableValues)
{
g_maxEquityDD=3.0;
}
}
else
{
if(g_minBarsBetween==1)
{
g_strat8_enabled=true;
g_strat12_enabled=true;
g_strat9_enabled=false;
g_strat14_enabled=false;
g_strat15_enabled=false;
g_strat13_enabled=false;
g_maxEquityDD=3.4;
if(UseVariableValues)
{
g_maxEquityDD=4.0;
}
}
else
{
if(g_minBarsBetween==2)
{
g_strat8_enabled=true;
g_strat12_enabled=true;
g_strat9_enabled=true;
g_strat14_enabled=true;
g_strat15_enabled=false;
g_strat13_enabled=false;
g_maxEquityDD=4.1;
if(UseVariableValues)
{
g_maxEquityDD=5.0;
}
}
else
{
if(g_minBarsBetween==3)
{
g_strat8_enabled=true;
g_strat12_enabled=true;
g_strat9_enabled=true;
g_strat14_enabled=true;
g_strat15_enabled=true;
g_strat13_enabled=false;
g_maxEquityDD=4.8;
if(UseVariableValues)
{
g_maxEquityDD=5.6;
}
}
else
{
if(g_minBarsBetween==4)
{
g_strat8_enabled=true;
g_strat12_enabled=true;
g_strat9_enabled=true;
g_strat14_enabled=true;
g_strat15_enabled=true;
g_strat13_enabled=true;
g_maxEquityDD=5.1;
if(UseVariableValues)
{
g_maxEquityDD=6.0;
}
}
else
{
if(g_minBarsBetween==6)
{
g_strat1_enabled=RunStrat1;
g_strat4_enabled=RunStrat2;
g_strat7_enabled=RunStrat3;
g_strat8_enabled=RunStrat4;
g_strat12_enabled=RunStrat5;
g_strat9_enabled=RunStrat6;
g_strat14_enabled=RunStrat7;
g_strat15_enabled=RunStrat8;
g_strat13_enabled=RunStrat9;
}
}
}
}
}
}
if(iBars(g_tradeSymbol,MT4Period(PERIOD_D1))!=g_panelUpdateCnt)
{
g_panelUpdateCnt=iBars(g_tradeSymbol,MT4Period(PERIOD_D1));
g_panelCreated=false;
g_prevEquity=0.0;
}
if(PropFirmMaxDailyDD>0.0)
{
CalcPerformanceStats();
}
if(g_panelCreated||!(g_pairInitOK)) return;
lv_b4=false;
if(g_ddResetTime!=iTime(g_tradeSymbol,MT4Period(PERIOD_H1),1))
{
lv_b4=true;
g_ddResetTime=iTime(g_tradeSymbol,MT4Period(PERIOD_H1),1);
}
if((StringFind(Symbol(),"XAUUSD",0)>=0||StringFind(Symbol(),"xauusd",0)>=0||StringFind(Symbol(),"GOLD",0)>=0||StringFind(Symbol(),"GLD",0)>=0||StringFind(Symbol(),"gold",0)>=0||StringFind(Symbol(),"Gold",0)>=0))
{
g_tradeSymbol=Symbol();
if(g_strat1_enabled)
{
LoadStrategy1Params();
InitSymbolData(0);
ManageOrders(0);
if(lv_b4)
{
if(MQLInfoInteger(MQL_TESTER)==1&&!(UpdateInfoTesting))
{
tmp_d2=0.0;
}
else
{
tmp_d3=0.0;
g_pairBuyOpen[g_pairIdx]=0;
for(tmp_i4=HistoryTotal();tmp_i4>=0;tmp_i4=tmp_i4-1)
{
if(OrderSelect(tmp_i4,0,1)!=true||OrderSymbol()!=g_tradeSymbol||OrderMagicNumber()!=g_magicMain) continue;

if((OrderType()!=0&&OrderType()!=1)) continue;
g_pairBuyOpen[g_pairIdx]++;
tmp_d3=tmp_d3+OrderProfit()+OrderSwap()+OrderCommission();

}
tmp_d2=tmp_d3;
}
g_stratScores[0]=tmp_d2;
if(g_stratScores[0]!=0.0&&g_pairBuyOpen[0]> 0)
{
g_pairBuyPrice[0]=g_stratScores[0]/g_pairBuyOpen[0];
}
}
}
if(g_strat8_enabled)
{
LoadStrategy2Params();
InitSymbolData(3);
ManageOrders(3);
if(lv_b4)
{
if(MQLInfoInteger(MQL_TESTER)==1&&!(UpdateInfoTesting))
{
tmp_d5=0.0;
}
else
{
tmp_d6=0.0;
g_pairBuyOpen[g_pairIdx]=0;
for(tmp_i7=HistoryTotal();tmp_i7>=0;tmp_i7=tmp_i7-1)
{
if(OrderSelect(tmp_i7,0,1)!=true||OrderSymbol()!=g_tradeSymbol||OrderMagicNumber()!=g_magicMain) continue;

if((OrderType()!=0&&OrderType()!=1)) continue;
g_pairBuyOpen[g_pairIdx]++;
tmp_d6=tmp_d6+OrderProfit()+OrderSwap()+OrderCommission();

}
tmp_d5=tmp_d6;
}
g_stratScores[3]=tmp_d5;
if(g_stratScores[3]!=0.0&&g_pairBuyOpen[3]> 0)
{
g_pairBuyPrice[3]=g_stratScores[3]/g_pairBuyOpen[3];
}
}
}
if(g_strat4_enabled)
{
LoadStrategy3Params();
InitSymbolData(1);
ManageOrders(1);
if(lv_b4)
{
if(MQLInfoInteger(MQL_TESTER)==1&&!(UpdateInfoTesting))
{
tmp_d8=0.0;
}
else
{
tmp_d9=0.0;
g_pairBuyOpen[g_pairIdx]=0;
for(tmp_i10=HistoryTotal();tmp_i10>=0;tmp_i10=tmp_i10-1)
{
if(OrderSelect(tmp_i10,0,1)!=true||OrderSymbol()!=g_tradeSymbol||OrderMagicNumber()!=g_magicMain) continue;

if((OrderType()!=0&&OrderType()!=1)) continue;
g_pairBuyOpen[g_pairIdx]++;
tmp_d9=tmp_d9+OrderProfit()+OrderSwap()+OrderCommission();

}
tmp_d8=tmp_d9;
}
g_stratScores[1]=tmp_d8;
if(g_stratScores[1]!=0.0&&g_pairBuyOpen[1]> 0)
{
g_pairBuyPrice[1]=g_stratScores[1]/g_pairBuyOpen[1];
}
}
}
if(g_strat7_enabled)
{
LoadStrategy4Params();
InitSymbolData(2);
ManageOrders(2);
if(lv_b4)
{
if(MQLInfoInteger(MQL_TESTER)==1&&!(UpdateInfoTesting))
{
tmp_d11=0.0;
}
else
{
tmp_d12=0.0;
g_pairBuyOpen[g_pairIdx]=0;
for(tmp_i13=HistoryTotal();tmp_i13>=0;tmp_i13=tmp_i13-1)
{
if(OrderSelect(tmp_i13,0,1)!=true||OrderSymbol()!=g_tradeSymbol||OrderMagicNumber()!=g_magicMain) continue;

if((OrderType()!=0&&OrderType()!=1)) continue;
g_pairBuyOpen[g_pairIdx]++;
tmp_d12=tmp_d12+OrderProfit()+OrderSwap()+OrderCommission();

}
tmp_d11=tmp_d12;
}
g_stratScores[2]=tmp_d11;
if(g_stratScores[2]!=0.0&&g_pairBuyOpen[2]> 0)
{
g_pairBuyPrice[2]=g_stratScores[2]/g_pairBuyOpen[2];
}
}
}
if(g_strat9_enabled)
{
LoadStrategy5Params();
InitSymbolData(5);
ManageOrders(5);
if(lv_b4)
{
if(MQLInfoInteger(MQL_TESTER)==1&&!(UpdateInfoTesting))
{
tmp_d14=0.0;
}
else
{
tmp_d15=0.0;
g_pairBuyOpen[g_pairIdx]=0;
for(tmp_i16=HistoryTotal();tmp_i16>=0;tmp_i16=tmp_i16-1)
{
if(OrderSelect(tmp_i16,0,1)!=true||OrderSymbol()!=g_tradeSymbol||OrderMagicNumber()!=g_magicMain) continue;

if((OrderType()!=0&&OrderType()!=1)) continue;
g_pairBuyOpen[g_pairIdx]++;
tmp_d15=tmp_d15+OrderProfit()+OrderSwap()+OrderCommission();

}
tmp_d14=tmp_d15;
}
g_stratScores[5]=tmp_d14;
if(g_stratScores[5]!=0.0&&g_pairBuyOpen[5]> 0)
{
g_pairBuyPrice[5]=g_stratScores[5]/g_pairBuyOpen[5];
}
}
}
if(g_strat12_enabled)
{
LoadStrategy6Params();
InitSymbolData(4);
ManageOrders(4);
if(lv_b4)
{
if(MQLInfoInteger(MQL_TESTER)==1&&!(UpdateInfoTesting))
{
tmp_d17=0.0;
}
else
{
tmp_d18=0.0;
g_pairBuyOpen[g_pairIdx]=0;
for(tmp_i19=HistoryTotal();tmp_i19>=0;tmp_i19=tmp_i19-1)
{
if(OrderSelect(tmp_i19,0,1)!=true||OrderSymbol()!=g_tradeSymbol||OrderMagicNumber()!=g_magicMain) continue;

if((OrderType()!=0&&OrderType()!=1)) continue;
g_pairBuyOpen[g_pairIdx]++;
tmp_d18=tmp_d18+OrderProfit()+OrderSwap()+OrderCommission();

}
tmp_d17=tmp_d18;
}
g_stratScores[4]=tmp_d17;
if(g_stratScores[4]!=0.0&&g_pairBuyOpen[4]> 0)
{
g_pairBuyPrice[4]=g_stratScores[4]/g_pairBuyOpen[4];
}
}
}
if(g_strat13_enabled)
{
LoadStrategy7Params();
InitSymbolData(8);
ManageOrders(8);
if(lv_b4)
{
if(MQLInfoInteger(MQL_TESTER)==1&&!(UpdateInfoTesting))
{
tmp_d20=0.0;
}
else
{
tmp_d21=0.0;
g_pairBuyOpen[g_pairIdx]=0;
for(tmp_i22=HistoryTotal();tmp_i22>=0;tmp_i22=tmp_i22-1)
{
if(OrderSelect(tmp_i22,0,1)!=true||OrderSymbol()!=g_tradeSymbol||OrderMagicNumber()!=g_magicMain) continue;

if((OrderType()!=0&&OrderType()!=1)) continue;
g_pairBuyOpen[g_pairIdx]++;
tmp_d21=tmp_d21+OrderProfit()+OrderSwap()+OrderCommission();

}
tmp_d20=tmp_d21;
}
g_stratScores[8]=tmp_d20;
if(g_stratScores[8]!=0.0&&g_pairBuyOpen[8]> 0)
{
g_pairBuyPrice[8]=g_stratScores[8]/g_pairBuyOpen[8];
}
}
}
if(g_strat14_enabled)
{
LoadStrategy8Params();
InitSymbolData(6);
ManageOrders(6);
if(lv_b4)
{
if(MQLInfoInteger(MQL_TESTER)==1&&!(UpdateInfoTesting))
{
tmp_d23=0.0;
}
else
{
tmp_d24=0.0;
g_pairBuyOpen[g_pairIdx]=0;
for(tmp_i25=HistoryTotal();tmp_i25>=0;tmp_i25=tmp_i25-1)
{
if(OrderSelect(tmp_i25,0,1)!=true||OrderSymbol()!=g_tradeSymbol||OrderMagicNumber()!=g_magicMain) continue;

if((OrderType()!=0&&OrderType()!=1)) continue;
g_pairBuyOpen[g_pairIdx]++;
tmp_d24=tmp_d24+OrderProfit()+OrderSwap()+OrderCommission();

}
tmp_d23=tmp_d24;
}
g_stratScores[6]=tmp_d23;
if(g_stratScores[6]!=0.0&&g_pairBuyOpen[6]> 0)
{
g_pairBuyPrice[6]=g_stratScores[6]/g_pairBuyOpen[6];
}
}
}
if(g_strat15_enabled)
{
LoadStrategy9Params();
InitSymbolData(7);
ManageOrders(7);
if(lv_b4)
{
if(MQLInfoInteger(MQL_TESTER)==1&&!(UpdateInfoTesting))
{
tmp_d26=0.0;
}
else
{
tmp_d27=0.0;
g_pairBuyOpen[g_pairIdx]=0;
for(tmp_i28=HistoryTotal();tmp_i28>=0;tmp_i28=tmp_i28-1)
{
if(OrderSelect(tmp_i28,0,1)!=true||OrderSymbol()!=g_tradeSymbol||OrderMagicNumber()!=g_magicMain) continue;

if((OrderType()!=0&&OrderType()!=1)) continue;
g_pairBuyOpen[g_pairIdx]++;
tmp_d27=tmp_d27+OrderProfit()+OrderSwap()+OrderCommission();

}
tmp_d26=tmp_d27;
}
g_stratScores[7]=tmp_d26;
if(g_stratScores[7]!=0.0&&g_pairBuyOpen[7]> 0)
{
g_pairBuyPrice[7]=g_stratScores[7]/g_pairBuyOpen[7];
}
}
}
}
else
{
g_tradeSymbol=Symbol();
ManageOrders(0);
}
DrawPanelBackground();
if(iTime(Symbol(),PERIOD_M5,1)!=g_lastInitTime)
{
g_lastInitTime=iTime(Symbol(),PERIOD_M5,1);
UpdateStrategyStats();
DrawPanelDetails();
}
g_labelCount++;
if(g_labelCount<2) return;
g_dailyStartBal=AccountBalance();
g_labelCount=0;
}
// OnTick<<==-------- --------
void OnDeinit(const int reason)
{
DeleteChartObjects();
}
// deinit<<==-------- --------
void InitSymbolData(int param0)
{
g_pairIdx=param0;
g_point=SymbolInfoDouble(g_tradeSymbol,SYMBOL_TRADE_TICK_SIZE);
g_pointSize=g_point;
if((MarketInfo(g_tradeSymbol,MODE_DIGITS)==3.0||MarketInfo(g_tradeSymbol,MODE_DIGITS)==5.0))
{
g_pointSize=g_point*10.0;
}
if(SymbolInfoInteger(g_tradeSymbol,17)==0x1)
{
g_pointSize=g_point/10.0;
}
g_digits = (int)MarketInfo(g_tradeSymbol,MODE_DIGITS);
g_spread=MarketInfo(g_tradeSymbol,MODE_ASK)-MarketInfo(g_tradeSymbol,MODE_BID);
g_minStopLevel=MarketInfo(g_tradeSymbol,MODE_STOPLEVEL)*g_point;
g_stopLevelPts=MarketInfo(g_tradeSymbol,MODE_FREEZELEVEL)*g_point;
g_expirySeconds=g_expiryHours*60*60;
if(g_expiryHours> 0)
{
g_lastTradeTime=TimeCurrent()+g_expirySeconds;
}
else
{
g_lastTradeTime=0;
}
if(Virtual_expiration)
{
g_lastTradeTime=0;
}
g_netProfit=1.0;
if(!(UseVariableValues)) return;

if(g_totalProfit>0.0)
{
g_totalLoss=iOpen(g_tradeSymbol,MT4Period(PERIOD_D1),1)/g_totalProfit;
}
else
{
g_totalLoss=1.0;
}
if(AdjustLotsizeToVariableValues)
{
g_netProfit=1.0/g_totalLoss;
}
else
{
g_netProfit=1.0;
}
g_takeProfitPips=g_takeProfitPips*g_totalLoss;
g_slOffset=NormalizeDouble(g_slOffset*g_totalLoss,0);
g_breakEvenPips=NormalizeDouble(g_breakEvenPips*g_totalLoss,0);
g_minProfitClose=g_minProfitClose*g_totalLoss;
g_maxLossClose=g_maxLossClose*g_totalLoss;
g_trailStep=g_trailStep*g_totalLoss;
g_trailStart=g_trailStart*g_totalLoss;
g_trailStop=g_trailStop*g_totalLoss;
g_trailMax=g_trailMax*g_totalLoss;
g_trailFactor=g_trailFactor*g_totalLoss;
g_beProfitTrigger=g_beProfitTrigger*g_totalLoss;
g_beOffset=g_beOffset*g_totalLoss;
}
// InitSymbolData<<==-------- --------
int ManageOrders(int param0)
{
bool lv_b2;
datetime lv_dt3;
int lv_i4;
int lv_i5;
string lv_s6;
datetime lv_dt7;
int lv_i8;
int lv_i9;
//----------
bool _orderOK;
int tmp_i1;
int tmp_i2;
int tmp_i3;
int tmp_i4;
int tmp_i5;
int tmp_i6;
int tmp_i7;
int tmp_i8;
int tmp_i9;
int tmp_i10;
int tmp_i11;
int tmp_i12;
int tmp_i13;
int tmp_i14;
int tmp_i15;
int tmp_i16;
int tmp_i17;
int tmp_i18;
int tmp_i19;
int tmp_i20;
int tmp_i21;
int tmp_i22;
int tmp_i23;
int tmp_i24;
int tmp_i25;
int tmp_i26;
int tmp_i27;
int tmp_i28;
int tmp_i29;
int tmp_i30;
int tmp_i31;
int tmp_i32;
int tmp_i33;
int tmp_i34;
int tmp_i35;
int tmp_i36;
int tmp_i37;
int tmp_i38;
int tmp_i39;
int tmp_i40;
int tmp_i41;
int tmp_i42;
int tmp_i43;
int tmp_i44;
int tmp_i45;
int tmp_i46;
int tmp_i47;
int tmp_i48;
int tmp_i49;
int tmp_i50;
int tmp_i51;
int tmp_i52;
int tmp_i53;
int tmp_i54;
int tmp_i55;
int tmp_i56;
int tmp_i57;
int tmp_i58;
int tmp_i59;
int tmp_i60;
int tmp_i61;
int tmp_i62;
int tmp_i63;
int tmp_i64;
int tmp_i65;
int tmp_i66;
int tmp_i67;
int tmp_i68;
int tmp_i69;
int tmp_i70;
int tmp_i71;
int tmp_i72;
int tmp_i73;
int tmp_i74;
int tmp_i75;
int tmp_i76;
int tmp_i77;
int tmp_i78;
int tmp_i79;
int tmp_i80;
int tmp_i81;
int tmp_i82;
int tmp_i83;
int tmp_i84;
int tmp_i85;
int tmp_i86;
int tmp_i87;
int tmp_i88;
int tmp_i89;
double tmp_d90;
long tmp_l91;
int tmp_i92;
long tmp_l93;
int tmp_i94;
int tmp_i95;
int tmp_i96;
double tmp_d97;
long tmp_l98;
int tmp_i99;
long tmp_l100;
int tmp_i101;
int tmp_i102;
int tmp_i103;
int tmp_i104;
int tmp_i105;
bool tmp_b106 = false;
int tmp_i107;
int tmp_i108;
bool tmp_b109 = false;
int tmp_i110;
long tmp_l111;
int tmp_i112;
long tmp_l113;
string tmp_s114;
int tmp_i115;
int tmp_i116;
int tmp_i117;
int tmp_i118;

g_pairIdx=param0;
lv_b2=false;

if(g_tpOffset>0.0)
{
g_takeProfitPips=g_tpOffset/100.0*MarketInfo(g_tradeSymbol,MODE_ASK)*10.0;
}
if(g_exitMode==0)
{
if(ManageBuyTrade())
{
lv_b2=true;
}
if(ManageSellTrade())
{
lv_b2=true;
}
if(lv_b2)
{
return(0);
}
}
else
{
if(g_pairBuyTickets[g_pairIdx]!=iBars(g_tradeSymbol,MT4Period(g_exitMode)))
{
g_pairBuyTickets[g_pairIdx]=iBars(g_tradeSymbol,MT4Period(g_exitMode));
if(ManageBuyTrade())
{
lv_b2=true;
}
if(ManageSellTrade())
{
lv_b2=true;
}
if(lv_b2)
{
return(0);
}
}
}
DrawInfoPanel(false);
if(!(IsTesting())&&MarketInfo(g_tradeSymbol,MODE_TRADEALLOWED)==0.0)
{
if(!(g_pendBuyExists))
{
Print("Marketclosed...waitingto continue");
}
g_pendBuyExists=true;
return(0);
}
if(g_spreadFilterBars> 0&&((Hour()==0&&Minute()<g_spreadFilterBars)||(Hour()==23&&g_spreadFilterBars> 60-g_spreadFilterBars)))
{
if(!(g_pendBuyExists))
{
Print("DAYSWITCH -> Market might be closed... waiting"+string(g_spreadFilterBars)+" minutes before setting order..");
}
g_pendBuyExists=true;
return(0);
}
g_pendBuyExists=false;
if(g_useTradingHours)
{
if(CheckTradingHours()&&g_isInitialized)
{
if(g_useGMTOffset)
{
PrintOrderInfo();
}
g_isInitialized=false;
}
if(!(CheckTradingHours())&&!(g_isInitialized))
{
Print("ENTERING NON-TRADING HOURS! Closing orders...");
if(g_useGMTOffset)
{
for(tmp_i1=0;tmp_i1<g_panelY;tmp_i1=tmp_i1+1)
{
for(tmp_i2=0;tmp_i2<2;tmp_i2=tmp_i2+1)
{
g_tradeHistory[tmp_i1][tmp_i2]=0.0;
}
}
tmp_i3=0;
for(tmp_i4=MT4OrdersTotal();tmp_i4>=0;tmp_i4=tmp_i4-1)
{
if(OrderSelect(tmp_i4,0,0)!=true||OrderMagicNumber()!=g_magicMain||OrderSymbol()!=g_tradeSymbol) continue;

if((OrderType()!=4&&OrderType()!=5)) continue;
Print("Storing pending order nr "+string(OrderTicket()));
g_tradeHistory[tmp_i3][1]=OrderType();
g_tradeHistory[tmp_i3][0]=OrderOpenPrice();
g_tradeHistory[tmp_i3][2]=OrderLots();
tmp_i3=tmp_i3+1;

}
}
tmp_i5=1;
for(tmp_i6=MT4OrdersTotal();tmp_i6>=0;tmp_i6=tmp_i6-1)
{
if(OrderSelect(tmp_i6,0,0)!=true||OrderMagicNumber()!=g_magicMain||OrderSymbol()!=g_tradeSymbol||OrderType()!=4) continue;
_orderOK = OrderDelete(OrderTicket(),clrNONE);

}
if(tmp_i5==2)
{
for(tmp_i7=MT4OrdersTotal();tmp_i7>=0;tmp_i7=tmp_i7-1)
{
if(OrderSelect(tmp_i7,0,0)!=true||OrderMagicNumber()!=g_magicStrat2||OrderSymbol()!=g_tradeSymbol||OrderType()!=4) continue;
_orderOK = OrderDelete(OrderTicket(),clrNONE);

}
}
tmp_i8=1;
for(tmp_i9=MT4OrdersTotal();tmp_i9>=0;tmp_i9=tmp_i9-1)
{
if(OrderSelect(tmp_i9,0,0)!=true||OrderMagicNumber()!=g_magicMain||OrderSymbol()!=g_tradeSymbol||OrderType()!=5) continue;
_orderOK = OrderDelete(OrderTicket(),clrNONE);

}
if(tmp_i8==2)
{
for(tmp_i10=MT4OrdersTotal();tmp_i10>=0;tmp_i10=tmp_i10-1)
{
if(OrderSelect(tmp_i10,0,0)!=true||OrderMagicNumber()!=g_magicStrat2||OrderSymbol()!=g_tradeSymbol||OrderType()!=5) continue;
_orderOK = OrderDelete(OrderTicket(),clrNONE);

}
}
tmp_i11=2;
if(1==0)//false
{
do
{
if(OrderSelect(1,0,0)!=true||OrderMagicNumber()!=g_magicMain||OrderSymbol()!=g_tradeSymbol||OrderType()!=4) continue;
_orderOK = OrderDelete(OrderTicket(),clrNONE);

}
while(-1>=0);

}
if(tmp_i11==2)
{
for(tmp_i12=MT4OrdersTotal();tmp_i12>=0;tmp_i12=tmp_i12-1)
{
if(OrderSelect(tmp_i12,0,0)!=true||OrderMagicNumber()!=g_magicStrat2||OrderSymbol()!=g_tradeSymbol||OrderType()!=4) continue;
_orderOK = OrderDelete(OrderTicket(),clrNONE);

}
}
tmp_i13=2;
if(1==0)//false
{
do
{
if(OrderSelect(1,0,0)!=true||OrderMagicNumber()!=g_magicMain||OrderSymbol()!=g_tradeSymbol||OrderType()!=5) continue;
_orderOK = OrderDelete(OrderTicket(),clrNONE);

}
while(-1>=0);

}
if(tmp_i13==2)
{
for(tmp_i14=MT4OrdersTotal();tmp_i14>=0;tmp_i14=tmp_i14-1)
{
if(OrderSelect(tmp_i14,0,0)!=true||OrderMagicNumber()!=g_magicStrat2||OrderSymbol()!=g_tradeSymbol||OrderType()!=5) continue;
_orderOK = OrderDelete(OrderTicket(),clrNONE);

}
}
g_isInitialized=true;
return(0);
}
}
if(EnableNFP_Filter)
{
if(Year()<=2026)
{
lv_dt3=0;
for(lv_i4=0;lv_i4<300;lv_i4++)
{
tmp_i15=TimeYear(g_nfpDates[lv_i4]);
if(tmp_i15!=Year()) continue;
tmp_i16=TimeMonth(g_nfpDates[lv_i4]);
if(tmp_i16!=Month()) continue;
lv_dt3=g_nfpDates[lv_i4];
break;

}
lv_i5=60;
if(IsAmericanDST())
{
lv_i5=0;
}
if(g_autoResetTime>=lv_dt3-NFP_MinutesBefore*60+lv_i5*60&&g_autoResetTime<=lv_dt3+NFP_MinutesAfter*60+lv_i5*60)
{
if(NFP_ClosePendingOrders)
{
tmp_i17=1;
for(tmp_i18=MT4OrdersTotal();tmp_i18>=0;tmp_i18=tmp_i18-1)
{
if(OrderSelect(tmp_i18,0,0)!=true||OrderMagicNumber()!=g_magicMain||OrderSymbol()!=g_tradeSymbol||OrderType()!=4) continue;
_orderOK = OrderDelete(OrderTicket(),clrNONE);

}
if(tmp_i17==2)
{
for(tmp_i19=MT4OrdersTotal();tmp_i19>=0;tmp_i19=tmp_i19-1)
{
if(OrderSelect(tmp_i19,0,0)!=true||OrderMagicNumber()!=g_magicStrat2||OrderSymbol()!=g_tradeSymbol||OrderType()!=4) continue;
_orderOK = OrderDelete(OrderTicket(),clrNONE);

}
}
tmp_i20=1;
for(tmp_i21=MT4OrdersTotal();tmp_i21>=0;tmp_i21=tmp_i21-1)
{
if(OrderSelect(tmp_i21,0,0)!=true||OrderMagicNumber()!=g_magicMain||OrderSymbol()!=g_tradeSymbol||OrderType()!=5) continue;
_orderOK = OrderDelete(OrderTicket(),clrNONE);

}
if(tmp_i20==2)
{
for(tmp_i22=MT4OrdersTotal();tmp_i22>=0;tmp_i22=tmp_i22-1)
{
if(OrderSelect(tmp_i22,0,0)!=true||OrderMagicNumber()!=g_magicStrat2||OrderSymbol()!=g_tradeSymbol||OrderType()!=5) continue;
_orderOK = OrderDelete(OrderTicket(),clrNONE);

}
}
tmp_i23=2;
if(1==0)//false
{
do
{
if(OrderSelect(1,0,0)!=true||OrderMagicNumber()!=g_magicMain||OrderSymbol()!=g_tradeSymbol||OrderType()!=4) continue;
_orderOK = OrderDelete(OrderTicket(),clrNONE);

}
while(-1>=0);

}
if(tmp_i23==2)
{
for(tmp_i24=MT4OrdersTotal();tmp_i24>=0;tmp_i24=tmp_i24-1)
{
if(OrderSelect(tmp_i24,0,0)!=true||OrderMagicNumber()!=g_magicStrat2||OrderSymbol()!=g_tradeSymbol||OrderType()!=4) continue;
_orderOK = OrderDelete(OrderTicket(),clrNONE);

}
}
tmp_i25=2;
if(1==0)//false
{
do
{
if(OrderSelect(1,0,0)!=true||OrderMagicNumber()!=g_magicMain||OrderSymbol()!=g_tradeSymbol||OrderType()!=5) continue;
_orderOK = OrderDelete(OrderTicket(),clrNONE);

}
while(-1>=0);

}
if(tmp_i25==2)
{
for(tmp_i26=MT4OrdersTotal();tmp_i26>=0;tmp_i26=tmp_i26-1)
{
if(OrderSelect(tmp_i26,0,0)!=true||OrderMagicNumber()!=g_magicStrat2||OrderSymbol()!=g_tradeSymbol||OrderType()!=5) continue;
_orderOK = OrderDelete(OrderTicket(),clrNONE);

}
}
}
if(NFP_CloseOpenTrades)
{
for(tmp_i27=MT4OrdersTotal();tmp_i27>=0;tmp_i27=tmp_i27-1)
{
if(OrderSelect(tmp_i27,0,0)!=true||OrderSymbol()!=g_tradeSymbol) continue;
tmp_i28=OrderMagicNumber();
tmp_i29=ST1_MagicNumber+1;
if(tmp_i28!=tmp_i29)
{
tmp_i29=OrderMagicNumber();
tmp_i30=ST1_MagicNumber+2;
if(tmp_i29!=tmp_i30)
{
tmp_i30=OrderMagicNumber();
tmp_i31=ST1_MagicNumber+3;
if(tmp_i30!=tmp_i31)
{
tmp_i31=OrderMagicNumber();
tmp_i32=ST1_MagicNumber+4;
if(tmp_i31!=tmp_i32)
{
tmp_i32=OrderMagicNumber();
tmp_i33=ST1_MagicNumber+5;
if(tmp_i32!=tmp_i33)
{
tmp_i33=OrderMagicNumber();
tmp_i34=ST1_MagicNumber+6;
if(tmp_i33!=tmp_i34)
{
tmp_i34=OrderMagicNumber();
tmp_i35=ST1_MagicNumber+7;
if(tmp_i34!=tmp_i35)
{
tmp_i35=OrderMagicNumber();
tmp_i36=ST1_MagicNumber+8;
if(tmp_i35!=tmp_i36)
{
tmp_i36=OrderMagicNumber();
tmp_i37=ST1_MagicNumber+9;
if(tmp_i36!=tmp_i37)
{
tmp_i37=OrderMagicNumber();
tmp_i38=ST1_MagicNumber+10;
if(tmp_i37!=tmp_i38)
{
tmp_i38=OrderMagicNumber();
tmp_i39=ST1_MagicNumber+11;
if(tmp_i38!=tmp_i39)
{
tmp_i39=OrderMagicNumber();
tmp_i40=ST1_MagicNumber+12;
if(tmp_i39!=tmp_i40)
{
tmp_i40=OrderMagicNumber();
tmp_i41=ST1_MagicNumber+13;
if(tmp_i40!=tmp_i41)
{
tmp_i41=OrderMagicNumber();
tmp_i42=ST1_MagicNumber+14;
if(tmp_i41!=tmp_i42)
{
tmp_i42=OrderMagicNumber();
tmp_i43=ST1_MagicNumber+15;
if(tmp_i42!=tmp_i43) continue;
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
if(OrderType()==0)
{
_orderOK = OrderClose(OrderTicket(),OrderLots(),MarketInfo(g_tradeSymbol,MODE_BID),99999,Red);
}
if(OrderType()!=1) continue;
_orderOK = OrderClose(OrderTicket(),OrderLots(),MarketInfo(g_tradeSymbol,MODE_ASK),99999,Red);

}
}
if(!(g_dailyDDHit))
{
Print("NFP!! deleting trades!!");
}
g_dailyDDHit=true;
}
else
{
g_dailyDDHit=false;
}
}
else
{
if(Day()<=7&&DayOfWeek()==5)
{
lv_s6=IntegerToString(Year(),0,32)+IntegerToString(Month(),0,32)+IntegerToString(Day(),0,32)+""+IntegerToString(1230,0,32);
lv_dt7=StringToTime(lv_s6);
if(g_autoResetTime>=lv_dt7-NFP_MinutesBefore*60&&g_autoResetTime<=lv_dt7+NFP_MinutesAfter*60)
{
if(NFP_ClosePendingOrders)
{
tmp_i44=1;
for(tmp_i45=MT4OrdersTotal();tmp_i45>=0;tmp_i45=tmp_i45-1)
{
if(OrderSelect(tmp_i45,0,0)!=true||OrderMagicNumber()!=g_magicMain||OrderSymbol()!=g_tradeSymbol||OrderType()!=4) continue;
_orderOK = OrderDelete(OrderTicket(),clrNONE);

}
if(tmp_i44==2)
{
for(tmp_i46=MT4OrdersTotal();tmp_i46>=0;tmp_i46=tmp_i46-1)
{
if(OrderSelect(tmp_i46,0,0)!=true||OrderMagicNumber()!=g_magicStrat2||OrderSymbol()!=g_tradeSymbol||OrderType()!=4) continue;
_orderOK = OrderDelete(OrderTicket(),clrNONE);

}
}
tmp_i47=1;
for(tmp_i48=MT4OrdersTotal();tmp_i48>=0;tmp_i48=tmp_i48-1)
{
if(OrderSelect(tmp_i48,0,0)!=true||OrderMagicNumber()!=g_magicMain||OrderSymbol()!=g_tradeSymbol||OrderType()!=5) continue;
_orderOK = OrderDelete(OrderTicket(),clrNONE);

}
if(tmp_i47==2)
{
for(tmp_i49=MT4OrdersTotal();tmp_i49>=0;tmp_i49=tmp_i49-1)
{
if(OrderSelect(tmp_i49,0,0)!=true||OrderMagicNumber()!=g_magicStrat2||OrderSymbol()!=g_tradeSymbol||OrderType()!=5) continue;
_orderOK = OrderDelete(OrderTicket(),clrNONE);

}
}
tmp_i50=2;
if(1==0)//false
{
do
{
if(OrderSelect(1,0,0)!=true||OrderMagicNumber()!=g_magicMain||OrderSymbol()!=g_tradeSymbol||OrderType()!=4) continue;
_orderOK = OrderDelete(OrderTicket(),clrNONE);

}
while(-1>=0);

}
if(tmp_i50==2)
{
for(tmp_i51=MT4OrdersTotal();tmp_i51>=0;tmp_i51=tmp_i51-1)
{
if(OrderSelect(tmp_i51,0,0)!=true||OrderMagicNumber()!=g_magicStrat2||OrderSymbol()!=g_tradeSymbol||OrderType()!=4) continue;
_orderOK = OrderDelete(OrderTicket(),clrNONE);

}
}
tmp_i52=2;
if(1==0)//false
{
do
{
if(OrderSelect(1,0,0)!=true||OrderMagicNumber()!=g_magicMain||OrderSymbol()!=g_tradeSymbol||OrderType()!=5) continue;
_orderOK = OrderDelete(OrderTicket(),clrNONE);

}
while(-1>=0);

}
if(tmp_i52==2)
{
for(tmp_i53=MT4OrdersTotal();tmp_i53>=0;tmp_i53=tmp_i53-1)
{
if(OrderSelect(tmp_i53,0,0)!=true||OrderMagicNumber()!=g_magicStrat2||OrderSymbol()!=g_tradeSymbol||OrderType()!=5) continue;
_orderOK = OrderDelete(OrderTicket(),clrNONE);

}
}
}
if(NFP_CloseOpenTrades)
{
for(tmp_i54=MT4OrdersTotal();tmp_i54>=0;tmp_i54=tmp_i54-1)
{
if(OrderSelect(tmp_i54,0,0)!=true||OrderSymbol()!=g_tradeSymbol) continue;
tmp_i55=OrderMagicNumber();
tmp_i56=ST1_MagicNumber+1;
if(tmp_i55!=tmp_i56)
{
tmp_i56=OrderMagicNumber();
tmp_i57=ST1_MagicNumber+2;
if(tmp_i56!=tmp_i57)
{
tmp_i57=OrderMagicNumber();
tmp_i58=ST1_MagicNumber+3;
if(tmp_i57!=tmp_i58)
{
tmp_i58=OrderMagicNumber();
tmp_i59=ST1_MagicNumber+4;
if(tmp_i58!=tmp_i59)
{
tmp_i59=OrderMagicNumber();
tmp_i60=ST1_MagicNumber+5;
if(tmp_i59!=tmp_i60)
{
tmp_i60=OrderMagicNumber();
tmp_i61=ST1_MagicNumber+6;
if(tmp_i60!=tmp_i61)
{
tmp_i61=OrderMagicNumber();
tmp_i62=ST1_MagicNumber+7;
if(tmp_i61!=tmp_i62)
{
tmp_i62=OrderMagicNumber();
tmp_i63=ST1_MagicNumber+8;
if(tmp_i62!=tmp_i63)
{
tmp_i63=OrderMagicNumber();
tmp_i64=ST1_MagicNumber+9;
if(tmp_i63!=tmp_i64)
{
tmp_i64=OrderMagicNumber();
tmp_i65=ST1_MagicNumber+10;
if(tmp_i64!=tmp_i65)
{
tmp_i65=OrderMagicNumber();
tmp_i66=ST1_MagicNumber+11;
if(tmp_i65!=tmp_i66)
{
tmp_i66=OrderMagicNumber();
tmp_i67=ST1_MagicNumber+12;
if(tmp_i66!=tmp_i67)
{
tmp_i67=OrderMagicNumber();
tmp_i68=ST1_MagicNumber+13;
if(tmp_i67!=tmp_i68)
{
tmp_i68=OrderMagicNumber();
tmp_i69=ST1_MagicNumber+14;
if(tmp_i68!=tmp_i69)
{
tmp_i69=OrderMagicNumber();
tmp_i70=ST1_MagicNumber+15;
if(tmp_i69!=tmp_i70) continue;
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
if(OrderType()==0)
{
_orderOK = OrderClose(OrderTicket(),OrderLots(),MarketInfo(g_tradeSymbol,MODE_BID),99999,Red);
}
if(OrderType()!=1) continue;
_orderOK = OrderClose(OrderTicket(),OrderLots(),MarketInfo(g_tradeSymbol,MODE_ASK),99999,Red);

}
}
if(!(g_dailyDDHit))
{
Print("NFP!! deleting trades!!");
}
g_dailyDDHit=true;
}
else
{
g_dailyDDHit=false;
}
}
}
}
if(g_dailyDDHit)
{
return(0);
}
if(g_useMonFilter)
{
if(DayOfWeek()==5&&Hour()>=FridayStopHour&&!(g_symbolReady))
{
for(tmp_i71=MT4OrdersTotal();tmp_i71>=0;tmp_i71=tmp_i71-1)
{
if(OrderSelect(tmp_i71,0,0)!=true||OrderSymbol()!=g_tradeSymbol) continue;
tmp_i72=OrderMagicNumber();
tmp_i73=ST1_MagicNumber+1;
if(tmp_i72!=tmp_i73)
{
tmp_i73=OrderMagicNumber();
tmp_i74=ST1_MagicNumber+2;
if(tmp_i73!=tmp_i74)
{
tmp_i74=OrderMagicNumber();
tmp_i75=ST1_MagicNumber+3;
if(tmp_i74!=tmp_i75)
{
tmp_i75=OrderMagicNumber();
tmp_i76=ST1_MagicNumber+4;
if(tmp_i75!=tmp_i76)
{
tmp_i76=OrderMagicNumber();
tmp_i77=ST1_MagicNumber+5;
if(tmp_i76!=tmp_i77)
{
tmp_i77=OrderMagicNumber();
tmp_i78=ST1_MagicNumber+6;
if(tmp_i77!=tmp_i78)
{
tmp_i78=OrderMagicNumber();
tmp_i79=ST1_MagicNumber+7;
if(tmp_i78!=tmp_i79)
{
tmp_i79=OrderMagicNumber();
tmp_i80=ST1_MagicNumber+8;
if(tmp_i79!=tmp_i80)
{
tmp_i80=OrderMagicNumber();
tmp_i81=ST1_MagicNumber+9;
if(tmp_i80!=tmp_i81)
{
tmp_i81=OrderMagicNumber();
tmp_i82=ST1_MagicNumber+10;
if(tmp_i81!=tmp_i82)
{
tmp_i82=OrderMagicNumber();
tmp_i83=ST1_MagicNumber+11;
if(tmp_i82!=tmp_i83)
{
tmp_i83=OrderMagicNumber();
tmp_i84=ST1_MagicNumber+12;
if(tmp_i83!=tmp_i84)
{
tmp_i84=OrderMagicNumber();
tmp_i85=ST1_MagicNumber+13;
if(tmp_i84!=tmp_i85)
{
tmp_i85=OrderMagicNumber();
tmp_i86=ST1_MagicNumber+14;
if(tmp_i85!=tmp_i86)
{
tmp_i86=OrderMagicNumber();
tmp_i87=ST1_MagicNumber+15;
if(tmp_i86!=tmp_i87) continue;
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
if(OrderType()==0)
{
_orderOK = OrderClose(OrderTicket(),OrderLots(),MarketInfo(g_tradeSymbol,MODE_BID),(int)g_maxVolatility,Red);
}
if(OrderType()==1)
{
_orderOK = OrderClose(OrderTicket(),OrderLots(),MarketInfo(g_tradeSymbol,MODE_ASK),(int)g_maxVolatility,Red);
}
if((OrderType()!=4&&OrderType()!=5)) continue;
_orderOK = OrderDelete(OrderTicket(),Red);

}
Print("Weekend starting! closing trades..");
g_symbolReady=true;
return(0);
}
if(DayOfWeek()!=5&&g_symbolReady==true)
{
g_symbolReady=false;
if(g_useTueFilter)
{
PrintOrderInfo();
return(0);
}
}
}
g_spread=MarketInfo(g_tradeSymbol,MODE_ASK)-MarketInfo(g_tradeSymbol,MODE_BID);
if(g_strat16_enabled)
{
if(g_spread>MaxSpread*g_pointSize)
{
CheckMaxOrders();
return(0);
}
if(g_spread<=g_minVolatility*g_pointSize&&(!(g_useMonFilter)||DayOfWeek()!=5||Hour()< FridayStopHour)&&(!(g_useTradingHours)||CheckTradingHours()))
{
PrintOrderInfo();
}
}
if(g_entryMode==1)
{
tmp_i88=0;
for(tmp_i89=MT4OrdersTotal();tmp_i89>=0;tmp_i89=tmp_i89-1)
{
if(OrderSelect(tmp_i89,0,0)!=true||OrderMagicNumber()!=g_magicMain||OrderSymbol()!=g_tradeSymbol||OrderType()!=4) continue;
tmp_i88=tmp_i88+1;

}
if(tmp_i88> g_maxConcurrent)
{
tmp_d90=0.0;
tmp_l91=0;
for(tmp_i92=MT4OrdersTotal();tmp_i92>=0;tmp_i92=tmp_i92-1)
{
if(OrderSelect(tmp_i92,0,0)!=true||OrderMagicNumber()!=g_magicMain||OrderSymbol()!=g_tradeSymbol||OrderType()!=4||!(OrderOpenPrice()>tmp_d90)) continue;
tmp_l91=OrderTicket();
tmp_d90=OrderOpenPrice();

}
if(tmp_l91!=0)
{
_orderOK = OrderDelete((int)tmp_l91,Green);
tmp_l93=tmp_l91;
for(tmp_i94=0;tmp_i94<100;tmp_i94=tmp_i94+1)
{
if(!(g_tradeStats[tmp_i94][0]==tmp_l93)) continue;
g_tradeStats[tmp_i94][0]=0.0;
g_tradeStats[tmp_i94][1]=0.0;
break;

}
Print("Max number of pending buy orders reached... deleting highest buy stop order!");
}
}
tmp_i95=0;
for(tmp_i96=MT4OrdersTotal();tmp_i96>=0;tmp_i96=tmp_i96-1)
{
if(OrderSelect(tmp_i96,0,0)!=true||OrderMagicNumber()!=g_magicMain||OrderSymbol()!=g_tradeSymbol||OrderType()!=5) continue;
tmp_i95=tmp_i95+1;

}
if(tmp_i95> g_maxConcurrent)
{
tmp_d97=9999.0;
tmp_l98=0;
for(tmp_i99=MT4OrdersTotal();tmp_i99>=0;tmp_i99=tmp_i99-1)
{
if(OrderSelect(tmp_i99,0,0)!=true||OrderMagicNumber()!=g_magicMain||OrderSymbol()!=g_tradeSymbol||OrderType()!=5||!(OrderOpenPrice()<tmp_d97)) continue;
tmp_l98=OrderTicket();
tmp_d97=OrderOpenPrice();

}
if(tmp_l98!=0)
{
_orderOK = OrderDelete((int)tmp_l98,Green);
tmp_l100=tmp_l98;
for(tmp_i101=0;tmp_i101<100;tmp_i101=tmp_i101+1)
{
if(!(g_tradeStats[tmp_i101][0]==tmp_l100)) continue;
g_tradeStats[tmp_i101][0]=0.0;
g_tradeStats[tmp_i101][1]=0.0;
break;

}
Print("Max number of pending sell orders reached... deleting lowest sell stop order!");
}
}
}
if(!(g_symbolReady)&&g_entryMode==1&&!(g_isInitialized))
{
if((g_pairSellTickets[g_pairIdx]!=iBars(g_tradeSymbol,MT4Period(g_entryPeriod))||g_entryPeriod==0))
{
g_pairSellTickets[g_pairIdx]=iBars(g_tradeSymbol,MT4Period(g_entryPeriod));
if(g_hlTrailShift> 0&&g_hlTrailMode>=0)
{
g_pairOpenProfit[g_pairIdx]=g_hlTrailMult*g_pointSize+(GetHighestHigh(g_hlTrailTF,g_hlTrailShift,g_hlTrailMode)+g_spread);
g_pairClosedProfit[g_pairIdx]=GetLowestLow(g_hlTrailTF,g_hlTrailShift,g_hlTrailMode)-g_hlTrailMult*g_pointSize;
}
if(g_backtestYear> 0)
{
lv_i8=MathRand()*g_backtestYear/32768+1;
g_tradeCount=lv_i8;
Print("Slippage: "+(string(lv_i8)));
}
if(g_newsFilterMode!=1)
{
tmp_i102=0;
for(tmp_i103=MT4OrdersTotal();tmp_i103>=0;tmp_i103=tmp_i103-1)
{
if(OrderSelect(tmp_i103,0,0)!=true||OrderMagicNumber()!=g_magicMain||OrderSymbol()!=g_tradeSymbol||OrderType()!=0) continue;
tmp_i102=tmp_i102+1;

}
if(tmp_i102==0)
{
tmp_i104=0;
for(tmp_i105=MT4OrdersTotal();tmp_i105>=0;tmp_i105=tmp_i105-1)
{
if(OrderSelect(tmp_i105,0,0)!=true||OrderMagicNumber()!=g_magicMain||OrderSymbol()!=g_tradeSymbol||OrderType()!=1) continue;
tmp_i104=tmp_i104+1;

}
if(tmp_i104==0)
{
tmp_b106=false;
for(tmp_i107=0;tmp_i107<g_panelX;tmp_i107=tmp_i107+1)
{
if(!(g_perfMatrix[tmp_i107][0]>0.0)) continue;
tmp_b106=false;
for(tmp_i108=MT4OrdersTotal();tmp_i108>=0;tmp_i108=tmp_i108-1)
{
if(OrderSelect(tmp_i108,0,0)!=true) continue;

if((OrderType()!=0&&OrderType()!=1)||!(OrderTicket()==g_perfMatrix[tmp_i107][0])) continue;
tmp_b106=true;

}
if(tmp_b106) continue;
g_perfMatrix[tmp_i107][0]=0.0;
g_perfMatrix[tmp_i107][1]=0.0;

}
}
}
}
for(lv_i9=0;lv_i9<g_maxConcurrent;lv_i9++)
{
DeletePendingOrders();
}
}
DrawPanelDetails();
if(g_errorCount!=Hour())
{
g_errorCount=Hour();
tmp_b109=false;
for(tmp_i110=0;tmp_i110<100;tmp_i110=tmp_i110+1)
{
tmp_l111 = (long)(g_tradeStats[tmp_i110][0]);
tmp_b109=false;
for(tmp_i112=MT4OrdersTotal();tmp_i112>=0;tmp_i112=tmp_i112-1)
{
if(!(OrderSelect(tmp_i112,0,0))) continue;
tmp_l113=OrderTicket();
if(tmp_l111!=tmp_l113) continue;
tmp_b109=true;

}
if(tmp_b109) continue;
g_tradeStats[tmp_i110][0]=0.0;
g_tradeStats[tmp_i110][1]=0.0;

}
}
}
if(g_closeDuringNews)
{
tmp_s114="Current spread: "+string(NormalizeDouble(g_spread/g_pointSize,1))+"\nPending Buy Order: ";
tmp_i115=0;
for(tmp_i116=MT4OrdersTotal();tmp_i116>=0;tmp_i116=tmp_i116-1)
{
if(OrderSelect(tmp_i116,0,0)!=true||OrderMagicNumber()!=g_magicMain||OrderSymbol()!=g_tradeSymbol||OrderType()!=4) continue;
tmp_i115=tmp_i115+1;

}
tmp_s114=tmp_s114+string(tmp_i115);
tmp_s114=tmp_s114+"\nPending Sell Orders: ";
tmp_i117=0;
for(tmp_i118=MT4OrdersTotal();tmp_i118>=0;tmp_i118=tmp_i118-1)
{
if(OrderSelect(tmp_i118,0,0)!=true||OrderMagicNumber()!=g_magicMain||OrderSymbol()!=g_tradeSymbol||OrderType()!=5) continue;
tmp_i117=tmp_i117+1;

}
tmp_s114=tmp_s114+string(tmp_i117);
Comment(tmp_s114);
}
return(0);
}
// ManageOrders<<==-------- --------
void PrintOrderInfo()
{
int lv_i1;
//----------
double tmp_d1;
long tmp_l2;
int tmp_i3;
double tmp_d4;
long tmp_l5;
int tmp_i6;
double tmp_d7;
long tmp_l8;
int tmp_i9;
double tmp_d10;
long tmp_l11;
int tmp_i12;
int tmp_i13;

for(lv_i1=0;lv_i1<g_panelY;lv_i1++)
{
if(!(g_tradeHistory[lv_i1][0]>0.0)) continue;

if(g_tradeHistory[lv_i1][1]==4.0&&MarketInfo(g_tradeSymbol,MODE_ASK)<g_tradeHistory[lv_i1][0]-g_minStopLevel)
{
Print("Restoring pending buy-order ");
g_lastError=(int)OrderSend(g_tradeSymbol,OP_BUYSTOP,g_tradeHistory[lv_i1][2],g_tradeHistory[lv_i1][0],int(g_maxVolatility*g_pointSize),g_tradeHistory[lv_i1][0]-(g_minProfitClose+g_newsImpactLevel)*g_pointSize,g_maxLossClose*g_pointSize+g_tradeHistory[lv_i1][0],g_currentSymbol,g_magicMain,g_lastTradeTime+172800/*=2 ngay*/,Green);
g_tp_hitBuy=false;
tmp_d1=g_tradeHistory[lv_i1][0];
tmp_l2=g_lastError;
for(tmp_i3=0;tmp_i3<100;tmp_i3=tmp_i3+1)
{
if(!(g_tradeStats[tmp_i3][0]==0.0)) continue;
g_tradeStats[tmp_i3][0] = (double)(tmp_l2);
g_tradeStats[tmp_i3][1]=tmp_d1;
break;

}
if(g_lastError<=0)
{
if(MT4_LastError()==132)
{
ResetLastError();
if(1==0)//false
{
do
{
Sleep((uint)2500);
g_lastError=(int)OrderSend(g_tradeSymbol,OP_BUYSTOP,g_tradeHistory[lv_i1][2],g_tradeHistory[lv_i1][0],int(g_maxVolatility*g_pointSize),g_tradeHistory[lv_i1][0]-(g_minProfitClose+g_newsImpactLevel)*g_pointSize,g_maxLossClose*g_pointSize+g_tradeHistory[lv_i1][0],g_currentSymbol,g_magicMain,g_lastTradeTime+172800/*=2 ngay*/,Green);
g_tp_hitBuy=false;
tmp_d4=g_tradeHistory[lv_i1][0];
tmp_l5=g_lastError;
for(tmp_i6=0;tmp_i6<100;tmp_i6=tmp_i6+1)
{
if(!(g_tradeStats[tmp_i6][0]==0.0)) continue;
g_tradeStats[tmp_i6][0] = (double)(tmp_l5);
g_tradeStats[tmp_i6][1]=tmp_d4;
break;

}
}
while(MT4_LastError()==132);

}
}
Print("error:\'"+GetErrorDescription(MT4_LastError())+"\'whensettingentryorder");
}
}
if(!(g_tradeHistory[lv_i1][1]==5.0)||!(MarketInfo(g_tradeSymbol,MODE_BID)>g_tradeHistory[lv_i1][0]+g_minStopLevel)) continue;
Print("Restoring pending sell-order ");
g_lastError=(int)OrderSend(g_tradeSymbol,OP_SELLSTOP,g_tradeHistory[lv_i1][2],g_tradeHistory[lv_i1][0],int(g_maxVolatility*g_pointSize),(g_minProfitClose+g_newsImpactLevel)*g_pointSize+g_tradeHistory[lv_i1][0],g_tradeHistory[lv_i1][0]-g_maxLossClose*g_pointSize,g_currentSymbol,g_magicMain,g_lastTradeTime+172800/*=2 ngay*/,Green);
g_tp_hitSell=false;
tmp_d7=g_tradeHistory[lv_i1][0];
tmp_l8=g_lastError;
for(tmp_i9=0;tmp_i9<100;tmp_i9=tmp_i9+1)
{
if(!(g_tradeStats[tmp_i9][0]==0.0)) continue;
g_tradeStats[tmp_i9][0] = (double)(tmp_l8);
g_tradeStats[tmp_i9][1]=tmp_d7;
break;

}
if(g_lastError>0) continue;

if(MT4_LastError()==132)
{
ResetLastError();
if(1==0)//false
{
do
{
Sleep((uint)2500);
g_lastError=(int)OrderSend(g_tradeSymbol,OP_SELLSTOP,g_tradeHistory[lv_i1][2],g_tradeHistory[lv_i1][0],int(g_maxVolatility*g_pointSize),(g_minProfitClose+g_newsImpactLevel)*g_pointSize+g_tradeHistory[lv_i1][0],g_tradeHistory[lv_i1][0]-g_maxLossClose*g_pointSize,g_currentSymbol,g_magicMain,g_lastTradeTime+172800/*=2 ngay*/,Green);
g_tp_hitSell=false;
tmp_d10=g_tradeHistory[lv_i1][0];
tmp_l11=g_lastError;
for(tmp_i12=0;tmp_i12<100;tmp_i12=tmp_i12+1)
{
if(!(g_tradeStats[tmp_i12][0]==0.0)) continue;
g_tradeStats[tmp_i12][0] = (double)(tmp_l11);
g_tradeStats[tmp_i12][1]=tmp_d10;
break;

}
}
while(MT4_LastError()==132);

}
}
Print("error:\'"+GetErrorDescription(MT4_LastError())+"\'whensettingentryorder");

}
for(tmp_i13=0;tmp_i13<g_panelY;tmp_i13=tmp_i13+1)
{
g_tradeHistory[tmp_i13][0]=0.0;
g_tradeHistory[tmp_i13][1]=0.0;
g_tradeHistory[tmp_i13][2]=0.0;
}
}
// PrintOrderInfo<<==-------- --------
bool CheckMaxOrders()
{
int lv_i2;
int lv_i3;
int lv_i4;
//----------
bool _orderOK;
long tmp_l1;
int tmp_i2;
long tmp_l3;
int tmp_i4;
double tmp_d5;
double tmp_d6;
long tmp_l7;
int tmp_i8;
long tmp_l9;
int tmp_i10;

for(lv_i2=MT4OrdersTotal();lv_i2>=0;lv_i2--)
{
if(OrderSelect(lv_i2,0,0)!=true) continue;

if((OrderMagicNumber()!=g_magicMain&&OrderMagicNumber()!=g_magicStrat2)||OrderSymbol()!=g_tradeSymbol) continue;

if(OrderType()==4&&OrderOpenPrice()<g_fakeoutStrength*g_pointSize+MarketInfo(g_tradeSymbol,MODE_ASK)&&MarketInfo(g_tradeSymbol,MODE_ASK)<OrderOpenPrice()-g_stopLevelPts)
{
if(g_minVolatility>0.0)
{
Print("Spread too high.. ("+string(g_spread)+") storing and deleting order"+string(OrderTicket()));
for(lv_i3=0;lv_i3<g_panelY;lv_i3++)
{
if(g_tradeHistory[lv_i3][0]==0.0)
{
Print("Storing pending order nr "+string(OrderTicket()));
g_tradeHistory[lv_i3][1]=OrderType();
g_tradeHistory[lv_i3][0]=OrderOpenPrice();
g_tradeHistory[lv_i3][2]=OrderLots();
break;
}
}
tmp_l1=OrderTicket();
for(tmp_i2=0;tmp_i2<100;tmp_i2=tmp_i2+1)
{
if(!(g_tradeStats[tmp_i2][0]==tmp_l1)) continue;
g_tradeStats[tmp_i2][0]=0.0;
g_tradeStats[tmp_i2][1]=0.0;
break;

}
_orderOK = OrderDelete(OrderTicket(),Green);
}
else
{
Print("Spread too high.. ("+string(g_spread)+") deleting order"+string(OrderTicket()));
tmp_l3=OrderTicket();
for(tmp_i4=0;tmp_i4<100;tmp_i4=tmp_i4+1)
{
if(!(g_tradeStats[tmp_i4][0]==tmp_l3)) continue;
g_tradeStats[tmp_i4][0]=0.0;
g_tradeStats[tmp_i4][1]=0.0;
break;

}
_orderOK = OrderDelete(OrderTicket(),Green);
}
}
if(OrderType()!=5) continue;
tmp_d5=OrderOpenPrice();
if(!(tmp_d5>MarketInfo(g_tradeSymbol,MODE_BID)-g_fakeoutStrength*g_pointSize)) continue;
tmp_d6=MarketInfo(g_tradeSymbol,MODE_BID);
if(!(tmp_d6>OrderOpenPrice()+g_stopLevelPts)) continue;

if(g_minVolatility>0.0)
{
Print("Spread too high.. ("+string(g_spread)+") storing and deleting order"+string(OrderTicket()));
for(lv_i4=0;lv_i4<g_panelY;lv_i4++)
{
if(g_tradeHistory[lv_i4][0]==0.0)
{
Print("Storing pending order nr "+string(OrderTicket()));
g_tradeHistory[lv_i4][1]=OrderType();
g_tradeHistory[lv_i4][0]=OrderOpenPrice();
g_tradeHistory[lv_i4][2]=OrderLots();
break;
}
}
tmp_l7=OrderTicket();
for(tmp_i8=0;tmp_i8<100;tmp_i8=tmp_i8+1)
{
if(!(g_tradeStats[tmp_i8][0]==tmp_l7)) continue;
g_tradeStats[tmp_i8][0]=0.0;
g_tradeStats[tmp_i8][1]=0.0;
break;

}
_orderOK = OrderDelete(OrderTicket(),Green);
continue;
}
Print("Spread too high.. ("+string(g_spread)+") deleting order"+string(OrderTicket()));
tmp_l9=OrderTicket();
for(tmp_i10=0;tmp_i10<100;tmp_i10=tmp_i10+1)
{
if(!(g_tradeStats[tmp_i10][0]==tmp_l9)) continue;
g_tradeStats[tmp_i10][0]=0.0;
g_tradeStats[tmp_i10][1]=0.0;
break;

}
_orderOK = OrderDelete(OrderTicket(),Green);

}
return(false);
}
// CheckMaxOrders<<==-------- --------
void CalcLotSize(double dParam0,int param1)
{
double lv_d1;
double lv_d2;
double lv_d3;
double lv_d4;
double lv_d5;
double lv_d6;
double lv_d7;
//----------

lv_d1=g_pairStratLots[g_pairIdx];
lv_d2=g_pairStratLots[g_pairIdx];
g_balForLots=AccountInfoDouble(ACCOUNT_BALANCE);
if(UseEquity)
{
g_balForLots=AccountInfoDouble(ACCOUNT_EQUITY);
}
if(ForceBalanceToUse>0.0)
{
g_balForLots=ForceBalanceToUse;
}
if(OnlyUp&&g_balSnapshot>g_balForLots)
{
g_balForLots=g_balSnapshot;
}
if(g_balForLots>g_balSnapshot)
{
g_balSnapshot=g_balForLots;
}
lv_d3=dParam0;
if((g_digits==2||g_digits==4))
{
lv_d3=dParam0/10.0;
}
if(Risk< 999&&Risk> 0)
{
lv_d4=Risk;
lv_d5=lv_d4/1000.0*g_balForLots;
if(MarketInfo(g_tradeSymbol,MODE_LOTSTEP)==0.1)
{
lv_d2=NormalizeDouble(param1*0.01*(lv_d5/(MarketInfo(g_tradeSymbol,MODE_TICKVALUE)*lv_d3)*0.1),1);
}
if(MarketInfo(g_tradeSymbol,MODE_LOTSTEP)==0.01)
{
lv_d2=NormalizeDouble(param1*0.01*(lv_d5/(MarketInfo(g_tradeSymbol,MODE_TICKVALUE)*lv_d3)*0.1),2);
}
}
if(Risk==999)
{
lv_d6=g_zrProfitTarget/100.0*g_balForLots;
if(MarketInfo(g_tradeSymbol,MODE_LOTSTEP)==0.1)
{
lv_d2=NormalizeDouble(param1*0.01*(lv_d6/(MarketInfo(g_tradeSymbol,MODE_TICKVALUE)*lv_d3)*0.1),1);
}
if(MarketInfo(g_tradeSymbol,MODE_LOTSTEP)==0.01)
{
lv_d2=NormalizeDouble(param1*0.01*(lv_d6/(MarketInfo(g_tradeSymbol,MODE_TICKVALUE)*lv_d3)*0.1),2);
}
}
if(Risk==0)
{
if(MarketInfo(g_tradeSymbol,MODE_LOTSTEP)==0.1)
{
lv_d2=NormalizeDouble(param1*0.01*g_startLots,1);
}
if(MarketInfo(g_tradeSymbol,MODE_LOTSTEP)==0.01)
{
lv_d2=NormalizeDouble(param1*0.01*g_startLots,2);
}
}
if(Risk==9999)
{
if(MarketInfo(g_tradeSymbol,MODE_LOTSTEP)==0.1)
{
lv_d2=NormalizeDouble(param1*0.01*(g_balForLots/g_zrLotStep*0.01),1);
}
if(MarketInfo(g_tradeSymbol,MODE_LOTSTEP)==0.01)
{
lv_d2=NormalizeDouble(param1*0.01*(g_balForLots/g_zrLotStep*0.01),2);
}
}
if(Risk==1234)
{
if(UseWeightedLots)
{
if(g_gmtOffsetFloat==0.0)
{
g_gmtOffsetFloat=100000.0;
}
g_zrLotFactor=MaxAllowedDD/g_maxEquityDD;
if(SymbolInfoDouble(g_tradeSymbol,SYMBOL_VOLUME_STEP)==0.1)
{
lv_d2=NormalizeDouble(g_zrLotFactor/g_gmtOffsetFloat*g_balForLots/100.0*0.01,1);
}
if(SymbolInfoDouble(g_tradeSymbol,SYMBOL_VOLUME_STEP)==0.01)
{
lv_d2=NormalizeDouble(g_zrLotFactor/g_gmtOffsetFloat*g_balForLots/100.0*0.01,2);
}
}
else
{
if(g_gmtOffsetFloat==0.0)
{
g_gmtOffsetFloat=100000.0;
}
lv_d7=ConvertToUSD(g_balForLots);
if(g_minBarsBetween==0)
{
g_zrLotStep = (int)(g_panelCol1X/(MaxAllowedDD/100.0));
}
if(g_minBarsBetween==1)
{
g_zrLotStep = (int)(g_panelCol2X/(MaxAllowedDD/100.0));
}
if(g_minBarsBetween==2)
{
g_zrLotStep = (int)(g_panelCol3X/(MaxAllowedDD/100.0));
}
if(g_minBarsBetween==3)
{
g_zrLotStep = (int)(g_autoMaxTrades/(MaxAllowedDD/100.0));
}
if(g_minBarsBetween==4)
{
g_zrLotStep = (int)(g_autoCount/(MaxAllowedDD/100.0));
}
if(SymbolInfoDouble(g_tradeSymbol,SYMBOL_VOLUME_STEP)==0.1)
{
lv_d2=NormalizeDouble(param1*0.01*(lv_d7/g_zrLotStep*0.01),1);
}
if(SymbolInfoDouble(g_tradeSymbol,SYMBOL_VOLUME_STEP)==0.01)
{
lv_d2=NormalizeDouble(param1*0.01*(lv_d7/g_zrLotStep*0.01),2);
}
}
}
if(Risk==3)
{
if(SymbolInfoDouble(g_tradeSymbol,SYMBOL_VOLUME_STEP)==0.1)
{
lv_d2=NormalizeDouble(MaxRiskPerStrategy_/g_gmtOffsetFloat*g_balForLots/100.0*0.01,1);
}
if(SymbolInfoDouble(g_tradeSymbol,SYMBOL_VOLUME_STEP)==0.01)
{
lv_d2=NormalizeDouble(MaxRiskPerStrategy_/g_gmtOffsetFloat*g_balForLots/100.0*0.01,2);
}
}
lv_d2=lv_d2*g_netProfit;
if(lv_d2<MarketInfo(g_tradeSymbol,MODE_LOTSTEP))
{
lv_d2=MarketInfo(g_tradeSymbol,MODE_LOTSTEP);
}
if(lv_d2>g_zrMaxLoss)
{
lv_d2=g_zrMaxLoss;
}
if(lv_d2<MarketInfo(g_tradeSymbol,MODE_MINLOT))
{
lv_d2=MarketInfo(g_tradeSymbol,MODE_MINLOT);
}
if(lv_d2>MarketInfo(g_tradeSymbol,MODE_MAXLOT)&&MarketInfo(g_tradeSymbol,MODE_MAXLOT)!=0.0)
{
lv_d2=MarketInfo(g_tradeSymbol,MODE_MAXLOT);
}
if(MarketInfo(g_tradeSymbol,MODE_LOTSTEP)==0.1)
{
g_pairStratLots[g_pairIdx]=NormalizeDouble((MathFloor(lv_d2*10.0))/10.0,1);
return;
}
g_pairStratLots[g_pairIdx]=NormalizeDouble(MathFloor(lv_d2*100.0)/100.0,2);
}
// CalcLotSize<<==-------- --------
double GetBuyEntryPrice(int searchTF)
{
//==================================================================
// TIM DIEM VAO LENH BUY = quet nguoc lich su tim DINH SWING (fractal high)
//   - centerBar: nen dang xet lam dinh swing
//   - isRightConfirmed: khong nen nao trong 'g_entryRetries' nen ben phai cao hon
//   - isLeftConfirmed : khong nen nao trong 'g_entryBars'   nen ben trai cao hon
//   - extremeSinceSwing: dinh cao nhat tu nen 0..swingBar (loc HTF)
//   - dupExists: da co BUYSTOP gan muc nay chua (chong dat trung)
//   Ket qua: g_pendBuySL = gia dinh swing de dat BUY STOP.
//==================================================================
bool entryFound=false;
bool isLeftConfirmed=false;
bool isRightConfirmed;
int centerBar;
int rBar;
int lBar;
//----------
double swingPrice;
int swingBar;
double extremeSinceSwing;
int scanBar;
double swingPriceNorm;
int ordIdx;
bool dupExists = false;

isRightConfirmed=false;
centerBar=g_entryRetries+1;
do
{
isLeftConfirmed=true;
isRightConfirmed=true;
for(rBar=centerBar;rBar>=centerBar-g_entryRetries;rBar--)
{
if(iHigh(g_tradeSymbol,MT4Period(searchTF),rBar)>iHigh(g_tradeSymbol,MT4Period(searchTF),centerBar))
{
isRightConfirmed=false;
}
}
for(lBar=centerBar;lBar<=centerBar+g_entryBars;lBar++)
{
if(iHigh(g_tradeSymbol,MT4Period(searchTF),lBar)>iHigh(g_tradeSymbol,MT4Period(searchTF),centerBar))
{
isLeftConfirmed=false;
}
}
if(isRightConfirmed&&isLeftConfirmed&&iHigh(g_tradeSymbol,MT4Period(searchTF),centerBar)>g_takeProfitPips*g_pointSize+MarketInfo(g_tradeSymbol,MODE_ASK))
{
swingPrice=iHigh(g_tradeSymbol,MT4Period(searchTF),centerBar);
swingBar=centerBar;
extremeSinceSwing=iHigh(g_tradeSymbol,MT4Period(g_entryTF),0);
for(scanBar=1;scanBar<=swingBar;scanBar=scanBar+1)
{
if(iHigh(g_tradeSymbol,MT4Period(g_entryTF),scanBar)>extremeSinceSwing)
{
extremeSinceSwing=iHigh(g_tradeSymbol,MT4Period(g_entryTF),scanBar);
}
}
if(swingPrice>=extremeSinceSwing)
{
swingPriceNorm=NormalizeDouble(iHigh(g_tradeSymbol,MT4Period(searchTF),centerBar),g_digits);
dupExists=false;
for(ordIdx=MT4OrdersTotal();ordIdx>=0;ordIdx=ordIdx-1)
{
if(OrderSelect(ordIdx,0,0)!=true||OrderMagicNumber()!=g_magicMain||OrderSymbol()!=g_tradeSymbol||OrderType()!=4||!(MathAbs(OrderOpenPrice()-(g_slOffset*g_pointSize+swingPriceNorm))<g_lotMultiplier*g_pointSize)) continue;
dupExists=true;
break;

}
if(!(dupExists)&&(!(g_useEntryDelay)||!(iClose(g_tradeSymbol,MT4Period(searchTF),centerBar-1)>iHigh(g_tradeSymbol,MT4Period(searchTF),centerBar)-g_takeProfitPips*g_pointSize)))
{
entryFound=true;
g_pendBuySL=NormalizeDouble(iHigh(g_tradeSymbol,MT4Period(searchTF),centerBar),g_digits);
g_openBuyTicket=centerBar;
break;
}
}
}
centerBar++;
if(centerBar<=g_entryDelaySeconds) continue;
g_pendBuySL=0.0;
break;

}
while(!(entryFound));

return(g_pendBuySL);
}
// GetBuyEntryPrice<<==-------- --------
double GetSellEntryPrice(int searchTF)
{
//==================================================================
// TIM DIEM VAO LENH SELL = quet nguoc lich su tim DAY SWING (fractal low)
//   Doi xung voi GetBuyEntryPrice. Ket qua: g_pendSellPrice.
//==================================================================
bool entryFound=false;
bool isLeftConfirmed=false;
bool isRightConfirmed;
int centerBar;
int rBar;
int lBar;
//----------
double swingPrice;
int swingBar;
double extremeSinceSwing;
int scanBar;
double swingPriceNorm;
int ordIdx;
bool dupExists = false;

isRightConfirmed=false;
centerBar=g_entryRetries+1;
do
{
isLeftConfirmed=true;
isRightConfirmed=true;
for(rBar=centerBar;rBar>=centerBar-g_entryRetries;rBar--)
{
if(iLow(g_tradeSymbol,MT4Period(searchTF),rBar)<iLow(g_tradeSymbol,MT4Period(searchTF),centerBar))
{
isRightConfirmed=false;
}
}
for(lBar=centerBar;lBar<=centerBar+g_entryBars;lBar++)
{
if(iLow(g_tradeSymbol,MT4Period(searchTF),lBar)<iLow(g_tradeSymbol,MT4Period(searchTF),centerBar))
{
isLeftConfirmed=false;
}
}
if(isRightConfirmed&&isLeftConfirmed&&iLow(g_tradeSymbol,MT4Period(searchTF),centerBar)<MarketInfo(g_tradeSymbol,MODE_BID)-g_takeProfitPips*g_pointSize)
{
swingPrice=iLow(g_tradeSymbol,MT4Period(searchTF),centerBar);
swingBar=centerBar;
extremeSinceSwing=iLow(g_tradeSymbol,MT4Period(g_entryTF),0);
for(scanBar=1;scanBar<=swingBar;scanBar=scanBar+1)
{
if(iLow(g_tradeSymbol,MT4Period(g_entryTF),scanBar)<extremeSinceSwing)
{
extremeSinceSwing=iLow(g_tradeSymbol,MT4Period(g_entryTF),scanBar);
}
}
if(swingPrice<=extremeSinceSwing)
{
swingPriceNorm=NormalizeDouble(iLow(g_tradeSymbol,MT4Period(searchTF),centerBar),g_digits);
dupExists=false;
for(ordIdx=MT4OrdersTotal();ordIdx>=0;ordIdx=ordIdx-1)
{
if(OrderSelect(ordIdx,0,0)!=true||OrderMagicNumber()!=g_magicMain||OrderSymbol()!=g_tradeSymbol||OrderType()!=5||!(MathAbs(OrderOpenPrice()-(swingPriceNorm-g_breakEvenPips*g_pointSize))<g_lotMultiplier*g_pointSize)) continue;
dupExists=true;
break;

}
if(!(dupExists)&&(!(g_useEntryDelay)||!(iClose(g_tradeSymbol,MT4Period(searchTF),centerBar-1)<g_takeProfitPips*g_pointSize+iLow(g_tradeSymbol,MT4Period(searchTF),centerBar))))
{
entryFound=true;
g_pendSellPrice=NormalizeDouble(iLow(g_tradeSymbol,MT4Period(searchTF),centerBar),g_digits);
g_openSellTicket=centerBar;
break;
}
}
}
centerBar++;
if(centerBar<=g_entryDelaySeconds) continue;
g_pendSellPrice=0.0;
break;

}
while(!(entryFound));

return(g_pendSellPrice);
}
// GetSellEntryPrice<<==-------- --------
double GetHighestHigh(int param0,int param1,int param2)
{
bool lv_b2=false;
double lv_d3=0.0;
bool lv_b4=false;
bool lv_b5;
int lv_i6;
int lv_i7;
int lv_i8;
//----------

lv_b5=false;
lv_i6=param2+1;
do
{
lv_b4=true;
lv_b5=true;
for(lv_i7=lv_i6;lv_i7>=lv_i6-param2;lv_i7--)
{
if(iHigh(g_tradeSymbol,MT4Period(param0),lv_i7)>iHigh(g_tradeSymbol,MT4Period(param0),lv_i6))
{
lv_b5=false;
}
}
for(lv_i8=lv_i6;lv_i8<=lv_i6+param1;lv_i8++)
{
if(iHigh(g_tradeSymbol,MT4Period(param0),lv_i8)>iHigh(g_tradeSymbol,MT4Period(param0),lv_i6))
{
lv_b4=false;
}
}
if(lv_b5&&lv_b4&&iHigh(g_tradeSymbol,MT4Period(param0),lv_i6)>g_minStopLevel*g_pointSize+MarketInfo(g_tradeSymbol,MODE_ASK))
{
lv_b2=true;
lv_d3=NormalizeDouble(iHigh(g_tradeSymbol,MT4Period(param0),lv_i6),g_digits);
break;
}
lv_i6++;
if(lv_i6<=g_hlTrailPeriod) continue;
lv_d3=9999.0;
break;

}
while(!(lv_b2));

return(lv_d3);
}
// GetHighestHigh<<==-------- --------
double GetLowestLow(int param0,int param1,int param2)
{
bool lv_b2=false;
double lv_d3=0.0;
bool lv_b4=false;
bool lv_b5;
int lv_i6;
int lv_i7;
int lv_i8;
//----------

lv_b5=false;
lv_i6=param2+1;
do
{
lv_b4=true;
lv_b5=true;
for(lv_i7=lv_i6;lv_i7>=lv_i6-param2;lv_i7--)
{
if(iLow(g_tradeSymbol,MT4Period(param0),lv_i7)<iLow(g_tradeSymbol,MT4Period(param0),lv_i6))
{
lv_b5=false;
}
}
for(lv_i8=lv_i6;lv_i8<=lv_i6+param1;lv_i8++)
{
if(iLow(g_tradeSymbol,MT4Period(param0),lv_i8)<iLow(g_tradeSymbol,MT4Period(param0),lv_i6))
{
lv_b4=false;
}
}
if(lv_b5&&lv_b4&&iLow(g_tradeSymbol,MT4Period(param0),lv_i6)<MarketInfo(g_tradeSymbol,MODE_BID)-g_minStopLevel*g_pointSize)
{
lv_b2=true;
lv_d3=NormalizeDouble(iLow(g_tradeSymbol,MT4Period(param0),lv_i6),g_digits);
break;
}
lv_i6++;
if(lv_i6<=g_hlTrailPeriod) continue;
lv_d3=0.0;
break;

}
while(!(lv_b2));

return(lv_d3);
}
// GetLowestLow<<==-------- --------
void DeletePendingOrders()
{
int lv_i1;
//----------
bool _orderOK;
long tmp_l1;
long tmp_l2;
int tmp_i3;
int tmp_i4;
int tmp_i5;
int tmp_i6;
int tmp_i7;
int tmp_i8;
int tmp_i9;
int tmp_i10;
int tmp_i11;
int tmp_i12;

if(g_virtualSLActive)
{
g_openBuyPrice=iMA(g_tradeSymbol,0,g_virtualSLMode,0,1,0,1);
g_openSellPrice=iMA(g_tradeSymbol,0,g_panelWidth,0,1,0,1);
}
CalcLotSize(g_minProfitClose,g_strategyMask);
if(g_pairStratLots[g_pairIdx]>g_zrMaxLoss)
{
g_pairStratLots[g_pairIdx]=g_zrMaxLoss;
}
if(g_expiryHours> 0)
{
g_lastTradeTime=TimeCurrent()+g_expirySeconds;
}
if(Virtual_expiration)
{
g_lastTradeTime=0;
for(lv_i1=MT4OrdersTotal();lv_i1>=0;lv_i1--)
{
if(OrderSelect(lv_i1,0,0)!=true||OrderMagicNumber()!=g_magicMain||OrderSymbol()!=g_tradeSymbol) continue;

if((OrderType()!=4&&OrderType()!=5)) continue;
tmp_l1=TimeCurrent();
tmp_l2=OrderOpenTime()+g_expirySeconds;
if(tmp_l1<tmp_l2) continue;
_orderOK = OrderDelete(OrderTicket(),Red);

}
}
tmp_i3=0;
for(tmp_i4=MT4OrdersTotal();tmp_i4>=0;tmp_i4=tmp_i4-1)
{
if(OrderSelect(tmp_i4,0,0)!=true||OrderMagicNumber()!=g_magicMain||OrderSymbol()!=g_tradeSymbol||OrderType()!=0) continue;
tmp_i3=tmp_i3+1;

}
if(tmp_i3< g_maxOrdersTotal)
{
PlaceBuyOrder(1);
}
else
{
tmp_i5=1;
for(tmp_i6=MT4OrdersTotal();tmp_i6>=0;tmp_i6=tmp_i6-1)
{
if(OrderSelect(tmp_i6,0,0)!=true||OrderMagicNumber()!=g_magicMain||OrderSymbol()!=g_tradeSymbol||OrderType()!=4) continue;
_orderOK = OrderDelete(OrderTicket(),clrNONE);

}
if(tmp_i5==2)
{
for(tmp_i7=MT4OrdersTotal();tmp_i7>=0;tmp_i7=tmp_i7-1)
{
if(OrderSelect(tmp_i7,0,0)!=true||OrderMagicNumber()!=g_magicStrat2||OrderSymbol()!=g_tradeSymbol||OrderType()!=4) continue;
_orderOK = OrderDelete(OrderTicket(),clrNONE);

}
}
}
tmp_i8=0;
for(tmp_i9=MT4OrdersTotal();tmp_i9>=0;tmp_i9=tmp_i9-1)
{
if(OrderSelect(tmp_i9,0,0)!=true||OrderMagicNumber()!=g_magicMain||OrderSymbol()!=g_tradeSymbol||OrderType()!=1) continue;
tmp_i8=tmp_i8+1;

}
if(tmp_i8< g_maxOrdersTotal)
{
PlaceSellOrder(1);
return;
}
tmp_i10=1;
for(tmp_i11=MT4OrdersTotal();tmp_i11>=0;tmp_i11=tmp_i11-1)
{
if(OrderSelect(tmp_i11,0,0)!=true||OrderMagicNumber()!=g_magicMain||OrderSymbol()!=g_tradeSymbol||OrderType()!=5) continue;
_orderOK = OrderDelete(OrderTicket(),clrNONE);

}
if(tmp_i10!=2) return;
for(tmp_i12=MT4OrdersTotal();tmp_i12>=0;tmp_i12=tmp_i12-1)
{
if(OrderSelect(tmp_i12,0,0)!=true||OrderMagicNumber()!=g_magicStrat2||OrderSymbol()!=g_tradeSymbol||OrderType()!=5) continue;
_orderOK = OrderDelete(OrderTicket(),clrNONE);

}
}
// DeletePendingOrders<<==-------- --------
bool PlaceBuyOrder(int param0)
{
bool lv_b2;
double lv_d3;
double lv_d4;
double lv_d5;
double lv_d6;
//----------
bool tmp_b1 = false;
int tmp_i2;
double tmp_d3;
int tmp_i4;
bool tmp_b5 = false;
int tmp_i6;
int tmp_i7;
double tmp_d8;
int tmp_i9;
double tmp_d10;
int tmp_i11;
bool tmp_b12 = false;
bool tmp_b13 = false;
int tmp_i14;
bool tmp_b15 = false;
int tmp_i16;
double tmp_d17;
long tmp_l18;
int tmp_i19;

if(!(AllowBuyTrades))
{
return(false);
}
if(g_panelVisible)
{
tmp_b1=false;
}
else
{
tmp_b1=false;
for(tmp_i2=0;tmp_i2<MT4OrdersTotal();tmp_i2=tmp_i2+1)
{
if(OrderSelect(tmp_i2,0,0)!=true||OrderType()!=0||OrderMagicNumber()!=g_magicMain||OrderSymbol()!=g_tradeSymbol) continue;
tmp_b1=true;
break;

}
}
if(tmp_b1==true)
{
return(false);
}
if(g_virtualSLActive&&g_openBuyPrice<g_openSellPrice)
{
return(false);
}
if(param0==1)
{
GetBuyEntryPrice(g_entryTF);
lv_b2=false;
tmp_d3=g_pendBuySL;
tmp_b5=false;
for(tmp_i4=MT4OrdersTotal();tmp_i4>=0;tmp_i4=tmp_i4-1)
{
if(OrderSelect(tmp_i4,0,0)!=true||OrderMagicNumber()!=g_magicMain||OrderSymbol()!=g_tradeSymbol||OrderType()!=4||!(MathAbs(OrderOpenPrice()-(g_slOffset*g_pointSize+tmp_d3))<g_lotMultiplier*g_pointSize)) continue;
tmp_b5=true;
break;

}
if(!(tmp_b5))
{
tmp_i6=0;
for(tmp_i7=MT4OrdersTotal();tmp_i7>=0;tmp_i7=tmp_i7-1)
{
if(OrderSelect(tmp_i7,0,0)!=true||OrderMagicNumber()!=g_magicMain||OrderSymbol()!=g_tradeSymbol||OrderType()!=4) continue;
tmp_i6=tmp_i6+1;

}
if(tmp_i6==g_maxConcurrent)
{
tmp_d8=9999.0;
for(tmp_i9=MT4OrdersTotal();tmp_i9>=0;tmp_i9=tmp_i9-1)
{
if(OrderSelect(tmp_i9,0,0)!=true||OrderMagicNumber()!=g_magicMain||OrderSymbol()!=g_tradeSymbol||OrderType()!=4||!(OrderOpenPrice()<tmp_d8)) continue;
tmp_d8=OrderOpenPrice();

}
if(g_pendBuySL>tmp_d8)
{
return(false);
}
}
g_pendBuyTP=g_pendBuySL;
lv_b2=true;
g_backtestLot=NormalizeDouble(g_pendBuySL,g_digits);
}
if(g_backtestLot==0.0)
{
return(false);
}
if(lv_b2)
{
g_st2_entryHigh=g_magicTrailStep;
lv_d3=NormalizeDouble(g_slOffset*g_pointSize+g_backtestLot,g_digits);
tmp_d10=lv_d3;
tmp_b12=false;
for(tmp_i11=MT4OrdersTotal();tmp_i11>=0;tmp_i11=tmp_i11-1)
{
if(OrderSelect(tmp_i11,0,0)!=true||OrderMagicNumber()!=g_magicMain||OrderSymbol()!=g_tradeSymbol||OrderType()!=4||!(OrderOpenPrice()<=tmp_d10)) continue;
tmp_b12=true;
break;

}
if(tmp_b12)
{
return(false);
}
g_ddStartBalance=lv_d3;
if(!(g_useSpreadFilter))
{
if(CheckMargin&&AccountFreeMarginCheck(g_tradeSymbol,0,g_pairStratLots[g_pairIdx])<=0.0)
{
Print("Free margin not sufficient for setting order with lotsize "+string(g_pairStratLots[g_pairIdx])+"...");
return(false);
}
lv_d4=NormalizeDouble(g_tradeCount*g_pointSize+lv_d3,g_digits);
lv_d5=NormalizeDouble(lv_d3-(g_minProfitClose+g_newsImpactLevel)*g_pointSize,g_digits);
lv_d6=NormalizeDouble(g_maxLossClose*g_pointSize+lv_d3,g_digits);
if(g_pairStratLots[g_pairIdx]<SymbolInfoDouble(g_tradeSymbol,SYMBOL_VOLUME_MIN))
{
Print("Volume is less than the minimal allowed SYMBOL_VOLUME_MIN="+string(SymbolInfoDouble(g_tradeSymbol,SYMBOL_VOLUME_MIN)));
tmp_b13=false;
}
else
{
if(g_pairStratLots[g_pairIdx]>SymbolInfoDouble(g_tradeSymbol,SYMBOL_VOLUME_MAX))
{
Print("Volume is greater than the maximal allowed SYMBOL_VOLUME_MAX="+string(SymbolInfoDouble(g_tradeSymbol,SYMBOL_VOLUME_MAX)));
tmp_b13=false;
}
else
{
if(MathAbs(NormalizeDouble(g_pairStratLots[g_pairIdx]/SymbolInfoDouble(g_tradeSymbol,SYMBOL_VOLUME_STEP),0)*SymbolInfoDouble(g_tradeSymbol,SYMBOL_VOLUME_STEP)-g_pairStratLots[g_pairIdx])>0.0000001)
{
Print("Volume"+string(g_pairStratLots[g_pairIdx])+" is not a multiple of the minimal step SYMBOL_VOLUME_STEP="+string(SymbolInfoDouble(g_tradeSymbol,SYMBOL_VOLUME_STEP)));
tmp_b13=false;
}
else
{
tmp_b13=true;
}
}
}

tmp_i14 = (int)AccountInfoInteger(ACCOUNT_LIMIT_ORDERS);
if(tmp_i14==0)
{
tmp_b15=true;
}
else
{
tmp_b15=MT4OrdersTotal()<tmp_i14;
}
if((!(tmp_b13)||!(tmp_b15)))
{
return(false);
}
if(MarketInfo(g_tradeSymbol,MODE_ASK)<lv_d4-g_stopLevelPts*g_pointSize&&MarketInfo(g_tradeSymbol,MODE_ASK)<lv_d4-g_minStopLevel*g_pointSize)
{
if(!(setSL_TP_After_Entry))
{
g_lastError=(int)OrderSend(g_tradeSymbol,OP_BUYSTOP,g_pairStratLots[g_pairIdx],lv_d4,int(g_maxVolatility*g_pointSize),lv_d5,lv_d6,g_currentSymbol,g_magicMain,g_lastTradeTime,Green);
}
else
{
g_lastError=(int)OrderSend(g_tradeSymbol,OP_BUYSTOP,g_pairStratLots[g_pairIdx],lv_d4,int(g_maxVolatility*g_pointSize),0.0,0.0,g_currentSymbol,g_magicMain,g_lastTradeTime,Green);
}
g_tp_hitBuy=false;
if(g_lastError<=0)
{
tmp_i16=MT4_LastError();
if(tmp_i16==132)
{
ResetLastError();
if(1==0)//false
{
do
{
Sleep((uint)2500);
if(!(setSL_TP_After_Entry))
{
tmp_i16 = (int)(g_maxVolatility*g_pointSize);
g_lastError=(int)OrderSend(g_tradeSymbol,OP_BUYSTOP,g_pairStratLots[g_pairIdx],lv_d4,tmp_i16,lv_d5,lv_d6,g_currentSymbol,g_magicMain,g_lastTradeTime,Green);
}
else
{
g_lastError=(int)OrderSend(g_tradeSymbol,OP_BUYSTOP,g_pairStratLots[g_pairIdx],lv_d4,int(g_maxVolatility*g_pointSize),0.0,0.0,g_currentSymbol,g_magicMain,g_lastTradeTime,Green);
}
g_tp_hitBuy=false;
}
while(MT4_LastError()==132);

}
}
Print("error:\'"+GetErrorDescription(MT4_LastError())+"\'whensettingentryorder");
}
else
{
tmp_d17=lv_d3;
tmp_l18=g_lastError;
for(tmp_i19=0;tmp_i19<100;tmp_i19=tmp_i19+1)
{
if(!(g_tradeStats[tmp_i19][0]==0.0)) continue;
g_tradeStats[tmp_i19][0] = (double)(tmp_l18);
g_tradeStats[tmp_i19][1]=tmp_d17;
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
// PlaceBuyOrder<<==-------- --------
bool PlaceSellOrder(int param0)
{
bool lv_b2;
double lv_d3;
double lv_d4;
double lv_d5;
double lv_d6;
//----------
bool tmp_b1 = false;
int tmp_i2;
double tmp_d3;
int tmp_i4;
bool tmp_b5 = false;
int tmp_i6;
int tmp_i7;
double tmp_d8;
int tmp_i9;
double tmp_d10;
int tmp_i11;
bool tmp_b12 = false;
bool tmp_b13 = false;
int tmp_i14;
bool tmp_b15 = false;
int tmp_i16;
double tmp_d17;
long tmp_l18;
int tmp_i19;

if(!(AllowSellTrades))
{
return(false);
}
if(g_panelVisible)
{
tmp_b1=false;
}
else
{
tmp_b1=false;
for(tmp_i2=0;tmp_i2<MT4OrdersTotal();tmp_i2=tmp_i2+1)
{
if(OrderSelect(tmp_i2,0,0)!=true||OrderType()!=1||OrderMagicNumber()!=g_magicMain||OrderSymbol()!=g_tradeSymbol) continue;
tmp_b1=true;
break;

}
}
if(tmp_b1==true)
{
return(false);
}
if(g_virtualSLActive&&g_openBuyPrice>g_openSellPrice)
{
return(false);
}
if(param0==1)
{
GetSellEntryPrice(g_entryTF);
lv_b2=false;
tmp_d3=g_pendSellPrice;
tmp_b5=false;
for(tmp_i4=MT4OrdersTotal();tmp_i4>=0;tmp_i4=tmp_i4-1)
{
if(OrderSelect(tmp_i4,0,0)!=true||OrderMagicNumber()!=g_magicMain||OrderSymbol()!=g_tradeSymbol||OrderType()!=5||!(MathAbs(OrderOpenPrice()-(tmp_d3-g_breakEvenPips*g_pointSize))<g_lotMultiplier*g_pointSize)) continue;
tmp_b5=true;
break;

}
if(!(tmp_b5))
{
tmp_i6=0;
for(tmp_i7=MT4OrdersTotal();tmp_i7>=0;tmp_i7=tmp_i7-1)
{
if(OrderSelect(tmp_i7,0,0)!=true||OrderMagicNumber()!=g_magicMain||OrderSymbol()!=g_tradeSymbol||OrderType()!=5) continue;
tmp_i6=tmp_i6+1;

}
if(tmp_i6==g_maxConcurrent)
{
tmp_d8=0.0;
for(tmp_i9=MT4OrdersTotal();tmp_i9>=0;tmp_i9=tmp_i9-1)
{
if(OrderSelect(tmp_i9,0,0)!=true||OrderMagicNumber()!=g_magicMain||OrderSymbol()!=g_tradeSymbol||OrderType()!=5||!(OrderOpenPrice()>tmp_d8)) continue;
tmp_d8=OrderOpenPrice();

}
if(g_pendSellPrice<tmp_d8)
{
return(false);
}
}
g_pendSellSL=g_pendSellPrice;
lv_b2=true;
g_backtestBalance=NormalizeDouble(g_pendSellPrice,g_digits);
}
if(g_backtestBalance==0.0)
{
return(false);
}
if(lv_b2)
{
g_st2_entryHigh=g_magicTrailStep;
lv_d3=NormalizeDouble(g_backtestBalance-g_breakEvenPips*g_pointSize,g_digits);
tmp_d10=lv_d3;
tmp_b12=false;
for(tmp_i11=MT4OrdersTotal();tmp_i11>=0;tmp_i11=tmp_i11-1)
{
if(OrderSelect(tmp_i11,0,0)!=true||OrderMagicNumber()!=g_magicMain||OrderSymbol()!=g_tradeSymbol||OrderType()!=5||!(OrderOpenPrice()>=tmp_d10)) continue;
tmp_b12=true;
break;

}
if(tmp_b12)
{
return(false);
}
g_maxDDBalance=lv_d3;
if(!(g_useSpreadFilter))
{
if(CheckMargin&&AccountFreeMarginCheck(g_tradeSymbol,1,g_pairStratLots[g_pairIdx])<=0.0)
{
Print("Free margin not sufficient for setting order with lotsize "+string(g_pairStratLots[g_pairIdx])+"...");
return(false);
}
lv_d4=NormalizeDouble(lv_d3-g_tradeCount*g_pointSize,g_digits);
lv_d5=NormalizeDouble((g_minProfitClose+g_newsImpactLevel)*g_pointSize+lv_d3,g_digits);
lv_d6=NormalizeDouble(lv_d3-g_maxLossClose*g_pointSize,g_digits);
if(g_pairStratLots[g_pairIdx]<SymbolInfoDouble(g_tradeSymbol,SYMBOL_VOLUME_MIN))
{
Print("Volume is less than the minimal allowed SYMBOL_VOLUME_MIN="+string(SymbolInfoDouble(g_tradeSymbol,SYMBOL_VOLUME_MIN)));
tmp_b13=false;
}
else
{
if(g_pairStratLots[g_pairIdx]>SymbolInfoDouble(g_tradeSymbol,SYMBOL_VOLUME_MAX))
{
Print("Volume is greater than the maximal allowed SYMBOL_VOLUME_MAX="+string(SymbolInfoDouble(g_tradeSymbol,SYMBOL_VOLUME_MAX)));
tmp_b13=false;
}
else
{
if(MathAbs(NormalizeDouble(g_pairStratLots[g_pairIdx]/SymbolInfoDouble(g_tradeSymbol,SYMBOL_VOLUME_STEP),0)*SymbolInfoDouble(g_tradeSymbol,SYMBOL_VOLUME_STEP)-g_pairStratLots[g_pairIdx])>0.0000001)
{
Print("Volume"+string(g_pairStratLots[g_pairIdx])+" is not a multiple of the minimal step SYMBOL_VOLUME_STEP="+string(SymbolInfoDouble(g_tradeSymbol,SYMBOL_VOLUME_STEP)));
tmp_b13=false;
}
else
{
tmp_b13=true;
}
}
}

tmp_i14 = (int)AccountInfoInteger(ACCOUNT_LIMIT_ORDERS);
if(tmp_i14==0)
{
tmp_b15=true;
}
else
{
tmp_b15=MT4OrdersTotal()<tmp_i14;
}
if((!(tmp_b13)||!(tmp_b15)))
{
return(false);
}
if(MarketInfo(g_tradeSymbol,MODE_BID)>g_stopLevelPts*g_pointSize+lv_d4&&MarketInfo(g_tradeSymbol,MODE_BID)>g_minStopLevel*g_pointSize+lv_d4)
{
if(!(setSL_TP_After_Entry))
{
g_lastError=(int)OrderSend(g_tradeSymbol,OP_SELLSTOP,g_pairStratLots[g_pairIdx],lv_d4,int(g_maxVolatility*g_pointSize),lv_d5,lv_d6,g_currentSymbol,g_magicMain,g_lastTradeTime,Red);
}
else
{
g_lastError=(int)OrderSend(g_tradeSymbol,OP_SELLSTOP,g_pairStratLots[g_pairIdx],lv_d4,int(g_maxVolatility*g_pointSize),0.0,0.0,g_currentSymbol,g_magicMain,g_lastTradeTime,Red);
}
g_tp_hitSell=false;
if(g_lastError<=0)
{
tmp_i16=MT4_LastError();
if(tmp_i16==132)
{
ResetLastError();
if(1==0)//false
{
do
{
Sleep((uint)2500);
if(!(setSL_TP_After_Entry))
{
tmp_i16 = (int)(g_maxVolatility*g_pointSize);
g_lastError=(int)OrderSend(g_tradeSymbol,OP_SELLSTOP,g_pairStratLots[g_pairIdx],lv_d4,tmp_i16,lv_d5,lv_d6,g_currentSymbol,g_magicMain,g_lastTradeTime,Red);
}
else
{
g_lastError=(int)OrderSend(g_tradeSymbol,OP_SELLSTOP,g_pairStratLots[g_pairIdx],lv_d4,int(g_maxVolatility*g_pointSize),0.0,0.0,g_currentSymbol,g_magicMain,g_lastTradeTime,Red);
}
g_tp_hitSell=false;
}
while(MT4_LastError()==132);

}
}
Print("error:\'"+GetErrorDescription(MT4_LastError())+"\'whensettingentryorder");
}
else
{
tmp_d17=lv_d3;
tmp_l18=g_lastError;
for(tmp_i19=0;tmp_i19<100;tmp_i19=tmp_i19+1)
{
if(!(g_tradeStats[tmp_i19][0]==0.0)) continue;
g_tradeStats[tmp_i19][0] = (double)(tmp_l18);
g_tradeStats[tmp_i19][1]=tmp_d17;
break;

}
}
}
}
}
}
return(false);
}
// PlaceSellOrder<<==-------- --------
bool ManageBuyTrade()
{
bool lv_b2=false;
bool lv_b3=false;
double lv_d4;
double lv_d5;
int lv_i6;
double lv_d7;
double lv_d8;
long lv_l9;
double lv_d10;
string lv_s11;
double lv_d12;
datetime lv_dt13;
int lv_i14;
int lv_i15;
string lv_s16;
double lv_d17;
double lv_d18;
bool lv_b19;
bool lv_b20;
double lv_d21;
bool lv_b22;
double lv_d23;
double lv_d24;
double lv_d25;
double lv_d26;
double lv_d27;
int lv_i28;
double lv_d29;
//----------
bool _orderOK;
int tmp_i1;
long tmp_l2;
int tmp_i3;
double tmp_d4;
double tmp_d5;
long tmp_l6;
int tmp_i7;
long tmp_l8;
int tmp_i9;
int tmp_i10;
string tmp_s11;
double tmp_d12;
int tmp_i13;
long tmp_l14;
double tmp_d15;
int tmp_i16;
long tmp_l17;
long tmp_l18;
int tmp_i19;
int tmp_i20;
int tmp_i21;
string tmp_s22;
long tmp_l23;
double tmp_d24;
double tmp_d25;
int tmp_i26;
double tmp_d27;
bool tmp_b28 = false;
int tmp_i29;
int tmp_i30;
double tmp_d31;
long tmp_l32;
int tmp_i33;
long tmp_l34;
double tmp_d35;
double tmp_d36;
int tmp_i37;
double tmp_d38;
bool tmp_b39 = false;
int tmp_i40;
int tmp_i41;
double tmp_d42;
long tmp_l43;
int tmp_i44;

lv_d4=0.0;
lv_d5=0.0;
for(lv_i6=0;lv_i6<MT4OrdersTotal();lv_i6++)
{
if(OrderSelect(lv_i6,0,0)==true)
{
lv_b2=false;
lv_d7=NormalizeDouble(OrderStopLoss(),g_digits);
lv_d8=NormalizeDouble(OrderTakeProfit(),g_digits);
lv_l9=OrderTicket();
lv_d10=NormalizeDouble(OrderOpenPrice(),g_digits);
lv_s11=OrderComment();
lv_d12=OrderLots();
lv_dt13=OrderOpenTime();
lv_i14=OrderType();
lv_i15=OrderMagicNumber();
lv_s16=OrderSymbol();
if((lv_i14==4||lv_i14==2)&&g_entryMode==2&&(g_strat2_type==0||(g_strat2_type==1&&lv_s16==g_tradeSymbol))&&(lv_i15==g_magicStrat2||g_magicStrat2==0)&&(lv_s11==g_strat2_comment||g_strat2_comment==""))
{
if((lv_d7==0.0||lv_d7==0.0))
{
lv_d7=NormalizeDouble(lv_d10-g_minProfitClose*g_pointSize,g_digits);
_orderOK = OrderModify((int)lv_l9,lv_d10,lv_d7,lv_d8,0,Green);
}
if((lv_d8==0.0||lv_d8==0.0))
{
lv_d8=NormalizeDouble(g_maxLossClose*g_pointSize+lv_d10,g_digits);
_orderOK = OrderModify((int)lv_l9,lv_d10,lv_d7,lv_d8,0,Green);
}
}
if(lv_i14==0&&((lv_i15==g_magicMain&&g_entryMode==1&&lv_s16==g_tradeSymbol)||(g_entryMode==2&&(g_strat2_type==0||(g_strat2_type==1&&lv_s16==g_tradeSymbol))&&(lv_i15==g_magicStrat2||g_magicStrat2==0)&&(lv_s11==g_strat2_comment||g_strat2_comment==""))))
{
if((lv_d7==0.0||lv_d7==0.0))
{
lv_d7=NormalizeDouble(lv_d10-g_minProfitClose*g_pointSize,g_digits);
_orderOK = OrderModify((int)lv_l9,lv_d10,lv_d7,lv_d8,0,Green);
}
if((lv_d8==0.0||lv_d8==0.0))
{
lv_d8=NormalizeDouble(g_maxLossClose*g_pointSize+lv_d10,g_digits);
_orderOK = OrderModify((int)lv_l9,lv_d10,lv_d7,lv_d8,0,Green);
}
if(g_use5minFilter&&iTime(g_tradeSymbol,MT4Period(g_maxTotalTrades),g_maxTradesPerDir)<=lv_dt13&&iTime(g_tradeSymbol,MT4Period(g_maxTotalTrades),0)> lv_dt13&&iClose(g_tradeSymbol,MT4Period(g_maxTotalTrades),1)<iOpen(g_tradeSymbol,MT4Period(g_maxTotalTrades),1)&&iClose(g_tradeSymbol,MT4Period(g_maxTotalTrades),1)<lv_d10)
{
_orderOK = OrderClose((int)lv_l9,lv_d12,MarketInfo(g_tradeSymbol,MODE_BID),0,Red);
Print("closingcandleconfirmation");
}
if(g_use15minFilter&&iTime(g_tradeSymbol,MT4Period(g_filter5minPeriod),g_maxTradesPerDir)<=lv_dt13&&iTime(g_tradeSymbol,MT4Period(g_filter5minPeriod),0)> lv_dt13&&iClose(g_tradeSymbol,MT4Period(g_filter5minPeriod),1)<iOpen(g_tradeSymbol,MT4Period(g_filter5minPeriod),1)&&iClose(g_tradeSymbol,MT4Period(g_filter5minPeriod),1)<lv_d10)
{
_orderOK = OrderClose((int)lv_l9,lv_d12,MarketInfo(g_tradeSymbol,MODE_BID),0,Red);
Print("closingcandleconfirmation");
}
if(g_use30minFilter&&iTime(g_tradeSymbol,MT4Period(g_filter15minPeriod),g_maxTradesPerDir)<=lv_dt13&&iTime(g_tradeSymbol,MT4Period(g_filter15minPeriod),0)> lv_dt13&&iClose(g_tradeSymbol,MT4Period(g_filter15minPeriod),1)<iOpen(g_tradeSymbol,MT4Period(g_filter15minPeriod),1)&&iClose(g_tradeSymbol,MT4Period(g_filter15minPeriod),1)<lv_d10)
{
_orderOK = OrderClose((int)lv_l9,lv_d12,MarketInfo(g_tradeSymbol,MODE_BID),0,Red);
Print("closingcandleconfirmation");
}
if(g_use1hrFilter&&iTime(g_tradeSymbol,MT4Period(g_filter30minPeriod),g_maxTradesPerDir)<=lv_dt13&&iTime(g_tradeSymbol,MT4Period(g_filter30minPeriod),0)> lv_dt13&&iClose(g_tradeSymbol,MT4Period(g_filter30minPeriod),1)<iOpen(g_tradeSymbol,MT4Period(g_filter30minPeriod),1)&&iClose(g_tradeSymbol,MT4Period(g_filter30minPeriod),1)<lv_d10)
{
_orderOK = OrderClose((int)lv_l9,lv_d12,MarketInfo(g_tradeSymbol,MODE_BID),0,Red);
Print("closingcandleconfirmation");
}
if(g_useNewsFilter&&iTime(g_tradeSymbol,MT4Period(g_filter1hrPeriod),g_maxTradesPerDir)<=lv_dt13&&iTime(g_tradeSymbol,MT4Period(g_filter1hrPeriod),0)> lv_dt13&&iClose(g_tradeSymbol,MT4Period(g_filter1hrPeriod),1)<iOpen(g_tradeSymbol,MT4Period(g_filter1hrPeriod),1)&&iClose(g_tradeSymbol,MT4Period(g_filter1hrPeriod),1)<lv_d10)
{
_orderOK = OrderClose((int)lv_l9,lv_d12,MarketInfo(g_tradeSymbol,MODE_BID),0,Red);
Print("closingcandleconfirmation");
}
g_st2_entryHigh=g_magicTrailStep;
if(g_magicTrailShift> 0&&TimeCurrent()> lv_dt13+g_magicTrailShift*60)
{
g_st2_entryHigh=g_magicTrailOffset;
}
tmp_i1=g_digits;
tmp_l2=lv_l9;
for(tmp_i3=0;tmp_i3<100;tmp_i3=tmp_i3+1)
{
if(!(g_tradeStats[tmp_i3][0]==tmp_l2)) continue;
tmp_d4=g_tradeStats[tmp_i3][1];
break;

}
tmp_d4=0.0;
lv_d17=NormalizeDouble(tmp_d4,tmp_i1);
if(lv_d17==0.0)
{
tmp_d5=lv_d10;
tmp_l6=lv_l9;
for(tmp_i7=0;tmp_i7<100;tmp_i7=tmp_i7+1)
{
if(!(g_tradeStats[tmp_i7][0]==0.0)) continue;
g_tradeStats[tmp_i7][0] = (double)(tmp_l6);
g_tradeStats[tmp_i7][1]=tmp_d5;
break;

}
lv_d17=lv_d10;
}
else
{
lv_d17=lv_d17-g_breakEvenOffset*g_pointSize;
}
lv_d18=lv_d10-lv_d17;
lv_b19=false;
if(lv_d17>0.0-g_breakEvenOffset*g_pointSize&&lv_d18>g_maxVolatility*g_pointSize)
{
lv_b19=true;
if(g_volPeriod==2)
{
g_st2_entryHigh=-1000.0;
Print("Slippage Mode 2 active");
}
}
if(g_useVirtualSL)
{
lv_d5=lv_d17;
}
else
{
lv_d5=lv_d10;
}
if(lv_d7<NormalizeDouble(lv_d10-(g_minProfitClose+g_newsImpactLevel)*g_pointSize-g_spread,g_digits))
{
lv_d7=NormalizeDouble(lv_d10-(g_minProfitClose+g_newsImpactLevel)*g_pointSize-g_spread,g_digits);
_orderOK = OrderModify((int)lv_l9,lv_d10,lv_d7,lv_d8,0,clrNONE);
}
if(MarketInfo(g_tradeSymbol,MODE_BID)<lv_d10-(g_minProfitClose+g_newsImpactLevel)*g_pointSize-g_spread)
{
RefreshRates();
_orderOK = OrderClose(OrderTicket(),OrderLots(),MarketInfo(g_tradeSymbol,MODE_BID),(int)g_spread,Red);
return(true);
}
lv_b20=false;
if(g_zrEnabled)
{
tmp_l8=lv_l9;
tmp_i9=0;
for(tmp_i10=MT4OrdersTotal();tmp_i10>=0;tmp_i10=tmp_i10-1)
{
if(OrderSelect(tmp_i10,0,0)!=true||OrderMagicNumber()!=g_zrBuyMagic||OrderSymbol()!=g_tradeSymbol) continue;
tmp_s11=OrderComment();
if(tmp_s11!=IntegerToString(tmp_l8,0,32)) continue;
tmp_i9=tmp_i9+1;

}
lv_d21=tmp_i9;
lv_b22=false;
if(!(g_hasBuyOrder))
{
g_hasBuyOrder=true;
g_openBuyCount=0;
}
if(lv_d21==0.0)
{
g_openBuyCount=0;
}
if(MathFloor(lv_d21/2.0)==lv_d21/2.0)
{
g_openBuyCount=0;
}
else
{
g_openBuyCount=1;
}
if(g_hasBuyOrder)
{
if(lv_d21>0.0)
{
tmp_d12=AccountEquity();
if(tmp_d12>AccountBalance()+g_zrMaxStep)
{
for(tmp_i13=MT4OrdersTotal();tmp_i13>=0;tmp_i13=tmp_i13-1)
{
if(OrderSelect(tmp_i13,0,0)!=true) continue;

if((OrderMagicNumber()!=g_magicMain&&OrderMagicNumber()!=g_zrSellMagic&&OrderMagicNumber()!=g_zrBuyMagic)) continue;

if(OrderType()==0)
{
_orderOK = OrderClose(OrderTicket(),OrderLots(),MarketInfo(g_tradeSymbol,MODE_BID),(int)g_maxVolatility,Red);
}
if(OrderType()!=1) continue;
_orderOK = OrderClose(OrderTicket(),OrderLots(),MarketInfo(g_tradeSymbol,MODE_ASK),(int)g_maxVolatility,Red);

}
}
}
if(lv_d21>0.0)
{
tmp_l14=lv_l9;
tmp_d15=0.0;
for(tmp_i16=MT4OrdersTotal();tmp_i16>=0;tmp_i16=tmp_i16-1)
{
if(OrderSelect(tmp_i16,0,0)!=true) continue;
tmp_l17=OrderTicket();
if(tmp_l17!=tmp_l14)
{
tmp_s11=OrderComment();
if(tmp_s11!=IntegerToString(tmp_l14,0,32)) continue;
}
tmp_d15=tmp_d15+OrderProfit();

}
if(tmp_d15>g_zrMaxStep)
{
Print("Closingzone");
tmp_l18=lv_l9;
for(tmp_i19=MT4OrdersTotal();tmp_i19>=0;tmp_i19=tmp_i19-1)
{
if(OrderSelect(tmp_i19,0,0)!=true) continue;

if(OrderMagicNumber()==g_magicMain&&OrderTicket()==tmp_l18)
{
_orderOK = OrderClose(OrderTicket(),OrderLots(),MarketInfo(g_tradeSymbol,MODE_BID),3,Red);
}
if(OrderMagicNumber()!=g_zrBuyMagic) continue;
tmp_s11=OrderComment();
if(tmp_s11!=IntegerToString(tmp_l18,0,32)) continue;

if(OrderType()==0)
{
_orderOK = OrderClose(OrderTicket(),OrderLots(),MarketInfo(g_tradeSymbol,MODE_BID),(int)g_maxVolatility,Red);
}
if(OrderType()!=1) continue;
_orderOK = OrderClose(OrderTicket(),OrderLots(),MarketInfo(g_tradeSymbol,MODE_ASK),(int)g_maxVolatility,Red);

}
g_hasBuyOrder=false;
lv_b20=true;
}
}
else
{
lv_d23=lv_d12*g_zrLotMultiplier;
if(g_zrMaxOrders==2)
{
lv_d23=(lv_d21+1.0)*lv_d12+lv_d12;
}
if(g_zrMaxOrders==3)
{
lv_d23=lv_d12*(MathPow(g_zrLotMultiplier,lv_d21+1.0));
}
if(g_openBuyCount==0)
{
lv_d24=lv_d21*g_zrStep*g_pointSize+(lv_d17-g_zrZoneSize*g_pointSize);
if(lv_d24>lv_d17-g_zrMinStep*g_pointSize)
{
lv_d24=lv_d17-g_zrMinStep*g_pointSize;
}
if(MarketInfo(g_tradeSymbol,MODE_BID)<lv_d24)
{
if(lv_d21>=g_zrMaxMagic)
{
for(tmp_i20=MT4OrdersTotal();tmp_i20>=0;tmp_i20=tmp_i20-1)
{
if(OrderSelect(tmp_i20,0,0)!=true) continue;

if(OrderMagicNumber()==g_magicMain&&OrderTicket()==lv_l9)
{
_orderOK = OrderClose(OrderTicket(),OrderLots(),MarketInfo(g_tradeSymbol,MODE_BID),3,Red);
}
if(OrderMagicNumber()!=g_zrBuyMagic) continue;
tmp_s11=OrderComment();
if(tmp_s11!=IntegerToString(lv_l9,0,32)) continue;

if(OrderType()==0)
{
_orderOK = OrderClose(OrderTicket(),OrderLots(),MarketInfo(g_tradeSymbol,MODE_BID),(int)g_maxVolatility,Red);
}
if(OrderType()!=1) continue;
_orderOK = OrderClose(OrderTicket(),OrderLots(),MarketInfo(g_tradeSymbol,MODE_ASK),(int)g_maxVolatility,Red);

}
}
else
{
_orderOK = OrderSend(g_tradeSymbol,OP_SELL,lv_d23,MarketInfo(g_tradeSymbol,MODE_BID),(int)g_maxVolatility,0.0,0.0,IntegerToString(lv_l9,0,32),g_zrBuyMagic,0,Green);
g_openBuyCount=1;
lv_b22=true;
}
}
}
else
{
lv_d25=lv_d17;
if(MarketInfo(g_tradeSymbol,MODE_ASK)>lv_d17)
{
if(lv_d21>=g_zrMaxMagic)
{
for(tmp_i21=MT4OrdersTotal();tmp_i21>=0;tmp_i21=tmp_i21-1)
{
if(OrderSelect(tmp_i21,0,0)!=true) continue;

if(OrderMagicNumber()==g_magicMain&&OrderTicket()==lv_l9)
{
_orderOK = OrderClose(OrderTicket(),OrderLots(),MarketInfo(g_tradeSymbol,MODE_BID),3,Red);
}
if(OrderMagicNumber()!=g_zrBuyMagic) continue;
tmp_s22=OrderComment();
if(tmp_s22!=IntegerToString(lv_l9,0,32)) continue;

if(OrderType()==0)
{
_orderOK = OrderClose(OrderTicket(),OrderLots(),MarketInfo(g_tradeSymbol,MODE_BID),(int)g_maxVolatility,Red);
}
if(OrderType()!=1) continue;
_orderOK = OrderClose(OrderTicket(),OrderLots(),MarketInfo(g_tradeSymbol,MODE_ASK),(int)g_maxVolatility,Red);

}
}
else
{
_orderOK = OrderSend(g_tradeSymbol,OP_BUY,lv_d23,MarketInfo(g_tradeSymbol,MODE_ASK),(int)g_maxVolatility,0.0,0.0,IntegerToString(lv_l9,0,32),g_zrBuyMagic,0,Green);
g_openBuyCount=0;
lv_b22=true;
}
}
}
}
}
if((lv_d21>0.0||lv_b22))
{
lv_b20=true;
}
}
if(!(lv_b20))
{
if((g_newsFilterMode==1||(g_newsFilterMode!=3&&g_newsFilterMode!=2)))
{
tmp_l23=lv_l9;
tmp_d24=g_minProfitClose;
tmp_d25=lv_d10;
tmp_i26=1;
tmp_d27=0.0;
tmp_b28=false;
for(tmp_i29=0;tmp_i29<g_panelX;tmp_i29=tmp_i29+1)
{
if(g_perfMatrix[tmp_i29][0]==tmp_l23)
{
tmp_d27=g_perfMatrix[tmp_i29][1];
tmp_b28=true;
break;
}
}
if(!(tmp_b28))
{
if(tmp_i26==1)
{
tmp_d27=NormalizeDouble(tmp_d25-tmp_d24*g_pointSize,g_digits);
}
if(tmp_i26==2)
{
tmp_d27=NormalizeDouble(tmp_d24*g_pointSize+tmp_d25,g_digits);
}
for(tmp_i30=0;tmp_i30<g_panelX;tmp_i30=tmp_i30+1)
{
if(g_perfMatrix[tmp_i30][0]==0.0)
{
g_perfMatrix[tmp_i30][0] = (double)(tmp_l23);
g_perfMatrix[tmp_i30][1]=tmp_d27;
break;
}
}
}
g_ask=tmp_d27;
lv_d4=g_ask;
if(MarketInfo(g_tradeSymbol,MODE_BID)<lv_d4)
{
Print("Closing with virtual SL");
RefreshRates();
_orderOK = OrderClose((int)lv_l9,lv_d12,MarketInfo(g_tradeSymbol,MODE_BID),(int)g_spread,clrNONE);
return(true);
}
if(g_recovTrailStart>0.0&&TimeCurrent()>=lv_dt13+g_initRetries&&MarketInfo(g_tradeSymbol,MODE_BID)>NormalizeDouble(g_recovTrailStep*g_pointSize+(lv_d7+g_point),g_digits)&&MarketInfo(g_tradeSymbol,MODE_BID)<lv_d8-g_stopLevelPts)
{
lv_d7=NormalizeDouble(MarketInfo(g_tradeSymbol,MODE_BID)-g_recovTrailStep*g_pointSize,g_digits);
if(lv_d7<MarketInfo(g_tradeSymbol,MODE_BID)-g_minStopLevel)
{
g_lastError=OrderModify((int)lv_l9,lv_d10,lv_d7,lv_d8,0,clrNONE);
if(g_lastError<=0)
{
Print("TrailStoperror:\'"+GetErrorDescription(MT4_LastError())+"\'whensettingtrailingExit_TrailSL_after_X_Minutes_sizeloss. Tryingagain!");
}
lv_b2=true;
}
}
if(g_trailStep>0.0&&MarketInfo(g_tradeSymbol,MODE_BID)>NormalizeDouble((g_trailStep+g_trailOffset)*g_pointSize+(lv_d7+g_point),g_digits)&&MarketInfo(g_tradeSymbol,MODE_BID)>NormalizeDouble(g_trailStart*g_pointSize+lv_d5,g_digits)&&MarketInfo(g_tradeSymbol,MODE_BID)<lv_d8-g_stopLevelPts&&lv_d7<NormalizeDouble(g_trailStop*g_pointSize+lv_d10,g_digits))
{
lv_d7=NormalizeDouble(MarketInfo(g_tradeSymbol,MODE_BID)-g_trailStep*g_pointSize,g_digits);
if(lv_d7<MarketInfo(g_tradeSymbol,MODE_BID)-g_minStopLevel)
{
g_lastError=OrderModify((int)lv_l9,lv_d10,lv_d7,lv_d8,0,clrNONE);
if(g_lastError<=0)
{
Print("TrailStoperror:\'"+GetErrorDescription(MT4_LastError())+"\'whensettingtrailingExit_stoploss. Tryingagain!");
}
else
{
lv_d26=NormalizeDouble(g_trailMin/100.0*g_pairStratLots[g_pairIdx],2);
if(lv_d26<lv_d12&&lv_d26>=MarketInfo(g_tradeSymbol,MODE_LOTSTEP))
{
_orderOK = OrderClose((int)lv_l9,lv_d26,MarketInfo(g_tradeSymbol,MODE_BID),(int)g_maxVolatility,Red);
return(true);
}
}
lv_b2=true;
}
}
if(g_trailMax>0.0&&MarketInfo(g_tradeSymbol,MODE_ASK)<NormalizeDouble(lv_d8-g_point-g_trailMax*g_pointSize,g_digits)&&MarketInfo(g_tradeSymbol,MODE_ASK)<NormalizeDouble(lv_d5-g_trailFactor*g_pointSize,g_digits)&&MarketInfo(g_tradeSymbol,MODE_BID)<lv_d8-g_stopLevelPts)
{
lv_d8=NormalizeDouble(MarketInfo(g_tradeSymbol,MODE_BID)+g_trailMax*g_pointSize,g_digits);
if(lv_d8>MarketInfo(g_tradeSymbol,MODE_ASK)+g_minStopLevel)
{
g_lastError=OrderModify((int)lv_l9,lv_d10,lv_d7,lv_d8,0,clrNONE);
if(g_lastError<=0)
{
Print("TrailStoperror:\'"+GetErrorDescription(MT4_LastError())+"\'whensettingtrailingExit_TP. Tryingagain!");
}
else
{
lv_d27=NormalizeDouble(g_trailMin/100.0*g_pairStratLots[g_pairIdx],2);
if(lv_d27<lv_d12&&lv_d27>=SymbolInfoDouble(g_tradeSymbol,SYMBOL_VOLUME_MIN))
{
_orderOK = OrderClose((int)lv_l9,lv_d27,MarketInfo(g_tradeSymbol,MODE_BID),(int)g_maxVolatility,Red);
return(true);
}
}
lv_b2=true;
}
}
if(lv_b19&&g_volPeriod==1&&g_exitRange>0.0&&MarketInfo(g_tradeSymbol,MODE_BID)>NormalizeDouble(g_exitRange*g_pointSize+(lv_d7+g_point),g_digits)&&MarketInfo(g_tradeSymbol,MODE_BID)>NormalizeDouble(g_entryRange*g_pointSize+lv_d17,g_digits)&&MarketInfo(g_tradeSymbol,MODE_BID)<lv_d8-g_stopLevelPts&&lv_d7<NormalizeDouble(g_filterRange*g_pointSize+lv_d10,g_digits))
{
lv_d7=NormalizeDouble(MarketInfo(g_tradeSymbol,MODE_BID)-g_exitRange*g_pointSize,g_digits);
if(lv_d7<MarketInfo(g_tradeSymbol,MODE_BID)-g_minStopLevel)
{
g_lastError=OrderModify((int)lv_l9,lv_d10,lv_d7,lv_d8,0,clrNONE);
if(g_lastError<=0)
{
Print("TrailStoperror:\'"+GetErrorDescription(MT4_LastError())+"\'whensettingSlipTL. Tryingagain!");
}
else
{
Print("Slippagecontrolactive");
}
lv_b2=true;
}
}
if(g_hlTrailShift> 0&&g_hlTrailMode>=0&&UseHL_TrailingSL&&g_pairClosedProfit[g_pairIdx]>NormalizeDouble(lv_d7+g_minStopLevel+g_point,g_digits)&&g_pairClosedProfit[g_pairIdx]<MarketInfo(g_tradeSymbol,MODE_BID)-g_hlTrailBars*g_pointSize&&(g_pairClosedProfit[g_pairIdx]<lv_d10||!(g_useHLTrail))&&g_pairClosedProfit[g_pairIdx]<NormalizeDouble(MarketInfo(g_tradeSymbol,MODE_BID)-g_hlTrailOffset*g_pointSize-g_minStopLevel-g_point,g_digits)&&MarketInfo(g_tradeSymbol,MODE_BID)<lv_d8-g_stopLevelPts)
{
lv_d7=NormalizeDouble(g_pairClosedProfit[g_pairIdx],g_digits);
if(lv_d7<MarketInfo(g_tradeSymbol,MODE_BID)-g_minStopLevel)
{
g_lastError=OrderModify((int)lv_l9,lv_d10,lv_d7,lv_d8,0,clrNONE);
if(g_lastError<=0)
{
Print("error:\'"+GetErrorDescription(MT4_LastError())+"\'whenmodifyingstoploss");
}
lv_b2=true;
}
}
if(g_beProfitTrigger>0.0&&MarketInfo(g_tradeSymbol,MODE_BID)>NormalizeDouble(g_beProfitTrigger*g_pointSize+lv_d10,g_digits)&&NormalizeDouble(g_beOffset*g_pointSize+lv_d10,g_digits)>lv_d7+g_point&&MarketInfo(g_tradeSymbol,MODE_BID)>NormalizeDouble(g_beOffset*g_pointSize+lv_d10+g_minStopLevel,g_digits)&&MarketInfo(g_tradeSymbol,MODE_BID)<lv_d8-g_stopLevelPts)
{
lv_d7=NormalizeDouble(g_beOffset*g_pointSize+lv_d10,g_digits);
if(lv_d7<MarketInfo(g_tradeSymbol,MODE_BID)-g_minStopLevel)
{
g_lastError=OrderModify((int)lv_l9,lv_d10,lv_d7,lv_d8,0,clrNONE);
if(g_lastError<=0)
{
Print("errorwhensettingbreakeven:\'"+GetErrorDescription(MT4_LastError())+"\'..\'Exit_BE_start\'tocloseto\'Exit_BE_extra_pips\'..tryingagain!");
}
lv_b2=true;
}
}
if(!(lv_b2)&&(g_magicTrailMode==1||(g_magicTrailMode==2&&g_magicTrailFast*g_pointSize+lv_d7<=g_magicTrailSlow*g_pointSize+(lv_d5+g_spread))))
{
g_st2_TP++;
if(MarketInfo(g_tradeSymbol,MODE_BID)>g_magicTrailFast*g_pointSize+lv_d7+g_minStopLevel&&MarketInfo(g_tradeSymbol,MODE_BID)<lv_d8-g_stopLevelPts&&(g_magicTrailStep==0.0||MarketInfo(g_tradeSymbol,MODE_BID)>g_st2_entryHigh*g_pointSize+lv_d5)&&g_st2_TP>=g_magicTrailPeriod&&NormalizeDouble(g_magicTrailFast*g_pointSize+lv_d7,g_digits)>lv_d7)
{
g_st2_TP=0;
lv_d7=NormalizeDouble(g_magicTrailFast*g_pointSize+lv_d7,g_digits);
_orderOK = OrderModify((int)lv_l9,lv_d10,lv_d7,lv_d8,0,clrNONE);
lv_b2=true;
}
}
g_ask=lv_d7;
if(MarketInfo(g_tradeSymbol,MODE_BID)<lv_d7)
{
Print("Closing with virtual SL");
RefreshRates();
_orderOK = OrderClose((int)lv_l9,lv_d12,MarketInfo(g_tradeSymbol,MODE_BID),(int)g_spread,clrNONE);
return(true);
}
if(NormalizeDouble(lv_d4,g_digits)!=NormalizeDouble(g_ask,g_digits))
{
tmp_d31=NormalizeDouble(g_ask,g_digits);
tmp_l32=lv_l9;
for(tmp_i33=0;tmp_i33<g_panelX;tmp_i33=tmp_i33+1)
{
if(g_perfMatrix[tmp_i33][0]==tmp_l32)
{
g_perfMatrix[tmp_i33][1]=tmp_d31;
break;
}
}
}
if(lv_b2&&g_useCompound)
{
return(true);
}
}
if((g_newsFilterMode==2||g_newsFilterMode==3))
{
tmp_l34=lv_l9;
tmp_d35=g_minProfitClose;
tmp_d36=lv_d10;
tmp_i37=1;
tmp_d38=0.0;
tmp_b39=false;
for(tmp_i40=0;tmp_i40<g_panelX;tmp_i40=tmp_i40+1)
{
if(g_perfMatrix[tmp_i40][0]==tmp_l34)
{
tmp_d38=g_perfMatrix[tmp_i40][1];
tmp_b39=true;
break;
}
}
if(!(tmp_b39))
{
if(tmp_i37==1)
{
tmp_d38=NormalizeDouble(tmp_d36-tmp_d35*g_pointSize,g_digits);
}
if(tmp_i37==2)
{
tmp_d38=NormalizeDouble(tmp_d35*g_pointSize+tmp_d36,g_digits);
}
for(tmp_i41=0;tmp_i41<g_panelX;tmp_i41=tmp_i41+1)
{
if(g_perfMatrix[tmp_i41][0]==0.0)
{
g_perfMatrix[tmp_i41][0] = (double)(tmp_l34);
g_perfMatrix[tmp_i41][1]=tmp_d38;
break;
}
}
}
g_ask=tmp_d38;
lv_d4=g_ask;
if(MarketInfo(g_tradeSymbol,MODE_BID)<=lv_d4)
{
RefreshRates();
_orderOK = OrderClose((int)lv_l9,lv_d12,MarketInfo(g_tradeSymbol,MODE_BID),(int)g_spread,clrNONE);
return(true);
}
lv_i28 = (int)(TimeCurrent()-g_dailyResetTime);
if(lv_i28>=g_maxSpreadFilter)
{
if(NormalizeDouble(g_ask,g_digits)>lv_d7+g_point)
{
_orderOK = OrderModify((int)lv_l9,lv_d10,NormalizeDouble(g_ask,g_digits),lv_d8,0,clrNONE);
}
g_dailyResetTime=TimeCurrent();
}
if(g_recovTrailStart>0.0&&TimeCurrent()>=lv_dt13+g_initRetries&&MarketInfo(g_tradeSymbol,MODE_BID)>g_recovTrailStep*g_pointSize+(g_ask+g_point)&&MarketInfo(g_tradeSymbol,MODE_BID)<lv_d8-g_stopLevelPts)
{
lv_b2=true;
g_ask=MarketInfo(g_tradeSymbol,MODE_BID)-g_recovTrailStep*g_pointSize;
}
if(g_trailStep>0.0&&MarketInfo(g_tradeSymbol,MODE_BID)>(g_trailStep+g_trailOffset)*g_pointSize+(g_ask+g_point)&&MarketInfo(g_tradeSymbol,MODE_BID)>g_trailStart*g_pointSize+lv_d5&&g_ask<g_trailStop*g_pointSize+lv_d10)
{
lv_b2=true;
g_ask=MarketInfo(g_tradeSymbol,MODE_BID)-g_trailStep*g_pointSize;
lv_d29=NormalizeDouble(g_trailMin/100.0*g_pairStratLots[g_pairIdx],2);
if(lv_d29<lv_d12&&lv_d29>=MarketInfo(g_tradeSymbol,MODE_LOTSTEP))
{
_orderOK = OrderClose((int)lv_l9,lv_d29,MarketInfo(g_tradeSymbol,MODE_BID),(int)g_maxVolatility,Red);
return(true);
}
}
if(lv_b19&&g_volPeriod==1&&g_exitRange>0.0&&MarketInfo(g_tradeSymbol,MODE_BID)>g_exitRange*g_pointSize+(g_ask+g_point)&&MarketInfo(g_tradeSymbol,MODE_BID)>g_entryRange*g_pointSize+lv_d17&&MarketInfo(g_tradeSymbol,MODE_BID)<lv_d8-g_stopLevelPts&&g_ask<g_filterRange*g_pointSize+lv_d10)
{
Print("Slippagecontrolactive");
lv_b2=true;
g_ask=MarketInfo(g_tradeSymbol,MODE_BID)-g_exitRange*g_pointSize;
}
if(g_hlTrailShift> 0&&g_hlTrailMode>=0&&g_pairClosedProfit[g_pairIdx]>g_ask+g_minStopLevel+g_point&&(g_pairClosedProfit[g_pairIdx]<lv_d10||!(g_useHLTrail))&&g_pairClosedProfit[g_pairIdx]<MarketInfo(g_tradeSymbol,MODE_BID)-g_hlTrailOffset*g_pointSize-g_minStopLevel-g_point&&MarketInfo(g_tradeSymbol,MODE_BID)<lv_d8-g_stopLevelPts)
{
g_ask=g_pairClosedProfit[g_pairIdx];
lv_b2=true;
}
if(g_beProfitTrigger>0.0&&g_newsFilterMode==3&&MarketInfo(g_tradeSymbol,MODE_BID)>g_beProfitTrigger*g_pointSize+lv_d10&&g_beOffset*g_pointSize+lv_d10>lv_d7+g_point&&MarketInfo(g_tradeSymbol,MODE_BID)>g_beOffset*g_pointSize+lv_d10+g_minStopLevel&&MarketInfo(g_tradeSymbol,MODE_BID)<lv_d8-g_stopLevelPts&&NormalizeDouble(g_beOffset*g_pointSize+lv_d10,g_digits)>OrderStopLoss())
{
g_ask=NormalizeDouble(g_beOffset*g_pointSize+lv_d10,g_digits);
g_lastError=OrderModify((int)lv_l9,lv_d10,g_ask,lv_d8,0,clrNONE);
if(g_lastError<=0)
{
Print("errorwhensettingbreakeven:\'"+GetErrorDescription(MT4_LastError())+"\'..\'Exit_BE_start\'tocloseto\'Exit_BE_extra_pips\'..tryingagain!");
}
lv_b2=true;
}
if(g_beProfitTrigger>0.0&&g_newsFilterMode==2&&MarketInfo(g_tradeSymbol,MODE_BID)>g_beProfitTrigger*g_pointSize+lv_d10&&g_beOffset*g_pointSize+lv_d10>g_ask+g_point&&MarketInfo(g_tradeSymbol,MODE_BID)>g_beOffset*g_pointSize+lv_d10+g_minStopLevel&&MarketInfo(g_tradeSymbol,MODE_BID)<lv_d8-g_stopLevelPts)
{
g_ask=g_beOffset*g_pointSize+lv_d10;
lv_b2=true;
}
if(!(lv_b2)&&(g_magicTrailMode==1||(g_magicTrailMode==2&&g_magicTrailFast*g_pointSize+g_ask<=g_magicTrailSlow*g_pointSize+(lv_d5+g_spread))))
{
g_st2_TP++;
if(MarketInfo(g_tradeSymbol,MODE_BID)>g_magicTrailFast*g_pointSize+g_ask+g_minStopLevel&&MarketInfo(g_tradeSymbol,MODE_BID)<lv_d8-g_stopLevelPts&&(g_magicTrailStep==0.0||MarketInfo(g_tradeSymbol,MODE_BID)>g_st2_entryHigh*g_pointSize+lv_d5)&&g_st2_TP>=g_magicTrailPeriod)
{
g_st2_TP=0;
g_ask=g_magicTrailFast*g_pointSize+g_ask;
lv_b2=true;
}
}
if(MarketInfo(g_tradeSymbol,MODE_BID)<=g_ask)
{
RefreshRates();
_orderOK = OrderClose((int)lv_l9,lv_d12,MarketInfo(g_tradeSymbol,MODE_BID),(int)g_spread,clrNONE);
return(true);
}
if(NormalizeDouble(lv_d4,g_digits)!=NormalizeDouble(g_ask,g_digits))
{
tmp_d42=NormalizeDouble(g_ask,g_digits);
tmp_l43=lv_l9;
for(tmp_i44=0;tmp_i44<g_panelX;tmp_i44=tmp_i44+1)
{
if(g_perfMatrix[tmp_i44][0]==tmp_l43)
{
g_perfMatrix[tmp_i44][1]=tmp_d42;
break;
}
}
}
}
}
}
if(lv_b2)
{
lv_b3=true;
}
}
if(lv_b2)
{
lv_b3=true;
}
}
return(lv_b3);
}
// ManageBuyTrade<<==-------- --------
bool ManageSellTrade()
{
bool lv_b2=false;
bool lv_b3=false;
double lv_d4;
double lv_d5;
int lv_i6;
double lv_d7;
double lv_d8;
long lv_l9;
double lv_d10;
string lv_s11;
double lv_d12;
datetime lv_dt13;
int lv_i14;
int lv_i15;
string lv_s16;
double lv_d17;
double lv_d18;
bool lv_b19;
bool lv_b20;
double lv_d21;
bool lv_b22;
double lv_d23;
double lv_d24;
double lv_d25;
double lv_d26;
double lv_d27;
int lv_i28;
double lv_d29;
//----------
bool _orderOK;
int tmp_i1;
long tmp_l2;
int tmp_i3;
double tmp_d4;
double tmp_d5;
long tmp_l6;
int tmp_i7;
long tmp_l8;
int tmp_i9;
int tmp_i10;
string tmp_s11;
double tmp_d12;
int tmp_i13;
long tmp_l14;
double tmp_d15;
int tmp_i16;
long tmp_l17;
long tmp_l18;
int tmp_i19;
int tmp_i20;
int tmp_i21;
string tmp_s22;
long tmp_l23;
double tmp_d24;
double tmp_d25;
int tmp_i26;
double tmp_d27;
bool tmp_b28 = false;
int tmp_i29;
int tmp_i30;
double tmp_d31;
long tmp_l32;
int tmp_i33;
long tmp_l34;
double tmp_d35;
double tmp_d36;
int tmp_i37;
double tmp_d38;
bool tmp_b39 = false;
int tmp_i40;
int tmp_i41;
double tmp_d42;
long tmp_l43;
int tmp_i44;

lv_d4=0.0;
lv_d5=0.0;
for(lv_i6=0;lv_i6<MT4OrdersTotal();lv_i6++)
{
if(OrderSelect(lv_i6,0,0)==true)
{
lv_b2=false;
lv_d7=NormalizeDouble(OrderStopLoss(),g_digits);
lv_d8=NormalizeDouble(OrderTakeProfit(),g_digits);
lv_l9=OrderTicket();
lv_d10=NormalizeDouble(OrderOpenPrice(),g_digits);
lv_s11=OrderComment();
lv_d12=OrderLots();
lv_dt13=OrderOpenTime();
lv_i14=OrderType();
lv_i15=OrderMagicNumber();
lv_s16=OrderSymbol();
if((lv_i14==5||lv_i14==3)&&g_entryMode==2&&(g_strat2_type==0||(g_strat2_type==1&&lv_s16==g_tradeSymbol))&&(lv_i15==g_magicStrat2||g_magicStrat2==0)&&(lv_s11==g_strat2_comment||g_strat2_comment==""))
{
if((lv_d7==0.0||lv_d7==0.0))
{
lv_d7=NormalizeDouble(g_minProfitClose*g_pointSize+lv_d10,g_digits);
_orderOK = OrderModify((int)lv_l9,lv_d10,lv_d7,lv_d8,0,Green);
}
if((lv_d8==0.0||lv_d8==0.0))
{
lv_d8=NormalizeDouble(lv_d10-g_maxLossClose*g_pointSize,g_digits);
_orderOK = OrderModify((int)lv_l9,lv_d10,lv_d7,lv_d8,0,Green);
}
}
if(lv_i14==1&&((lv_i15==g_magicMain&&g_entryMode==1&&lv_s16==g_tradeSymbol)||(g_entryMode==2&&(g_strat2_type==0||(g_strat2_type==1&&lv_s16==g_tradeSymbol))&&(lv_i15==g_magicStrat2||g_magicStrat2==0)&&(lv_s11==g_strat2_comment||g_strat2_comment==""))))
{
if((lv_d7==0.0||lv_d7==0.0))
{
lv_d7=NormalizeDouble(g_minProfitClose*g_pointSize+lv_d10,g_digits);
_orderOK = OrderModify((int)lv_l9,lv_d10,lv_d7,lv_d8,0,Green);
}
if((lv_d8==0.0||lv_d8==0.0))
{
lv_d8=NormalizeDouble(lv_d10-g_maxLossClose*g_pointSize,g_digits);
_orderOK = OrderModify((int)lv_l9,lv_d10,lv_d7,lv_d8,0,Green);
}
if(g_use5minFilter&&iTime(g_tradeSymbol,MT4Period(g_maxTotalTrades),g_maxTradesPerDir)<=lv_dt13&&iTime(g_tradeSymbol,MT4Period(g_maxTotalTrades),0)> lv_dt13&&iClose(g_tradeSymbol,MT4Period(g_maxTotalTrades),1)>iOpen(g_tradeSymbol,MT4Period(g_maxTotalTrades),1)&&iClose(g_tradeSymbol,MT4Period(g_maxTotalTrades),1)>lv_d10)
{
_orderOK = OrderClose((int)lv_l9,lv_d12,MarketInfo(g_tradeSymbol,MODE_ASK),0,Red);
Print("closingcandleconfirmation");
}
if(g_use15minFilter&&iTime(g_tradeSymbol,MT4Period(g_filter5minPeriod),g_maxTradesPerDir)<=lv_dt13&&iTime(g_tradeSymbol,MT4Period(g_filter5minPeriod),0)> lv_dt13&&iClose(g_tradeSymbol,MT4Period(g_filter5minPeriod),1)>iOpen(g_tradeSymbol,MT4Period(g_filter5minPeriod),1)&&iClose(g_tradeSymbol,MT4Period(g_filter5minPeriod),1)>lv_d10)
{
_orderOK = OrderClose((int)lv_l9,lv_d12,MarketInfo(g_tradeSymbol,MODE_ASK),0,Red);
Print("closingcandleconfirmation");
}
if(g_use30minFilter&&iTime(g_tradeSymbol,MT4Period(g_filter15minPeriod),g_maxTradesPerDir)<=lv_dt13&&iTime(g_tradeSymbol,MT4Period(g_filter15minPeriod),0)> lv_dt13&&iClose(g_tradeSymbol,MT4Period(g_filter15minPeriod),1)>iOpen(g_tradeSymbol,MT4Period(g_filter15minPeriod),1)&&iClose(g_tradeSymbol,MT4Period(g_filter15minPeriod),1)>lv_d10)
{
_orderOK = OrderClose((int)lv_l9,lv_d12,MarketInfo(g_tradeSymbol,MODE_ASK),0,Red);
Print("closingcandleconfirmation");
}
if(g_use1hrFilter&&iTime(g_tradeSymbol,MT4Period(g_filter30minPeriod),g_maxTradesPerDir)<=lv_dt13&&iTime(g_tradeSymbol,MT4Period(g_filter30minPeriod),0)> lv_dt13&&iClose(g_tradeSymbol,MT4Period(g_filter30minPeriod),1)>iOpen(g_tradeSymbol,MT4Period(g_filter30minPeriod),1)&&iClose(g_tradeSymbol,MT4Period(g_filter30minPeriod),1)>lv_d10)
{
_orderOK = OrderClose((int)lv_l9,lv_d12,MarketInfo(g_tradeSymbol,MODE_ASK),0,Red);
Print("closingcandleconfirmation");
}
if(g_useNewsFilter&&iTime(g_tradeSymbol,MT4Period(g_filter1hrPeriod),g_maxTradesPerDir)<=lv_dt13&&iTime(g_tradeSymbol,MT4Period(g_filter1hrPeriod),0)> lv_dt13&&iClose(g_tradeSymbol,MT4Period(g_filter1hrPeriod),1)>iOpen(g_tradeSymbol,MT4Period(g_filter1hrPeriod),1)&&iClose(g_tradeSymbol,MT4Period(g_filter1hrPeriod),1)>lv_d10)
{
_orderOK = OrderClose((int)lv_l9,lv_d12,MarketInfo(g_tradeSymbol,MODE_ASK),0,Red);
Print("closingcandleconfirmation");
}
g_st2_entryHigh=g_magicTrailStep;
if(g_magicTrailShift> 0&&TimeCurrent()> lv_dt13+g_magicTrailShift*60)
{
g_st2_entryHigh=g_magicTrailOffset;
}
tmp_i1=g_digits;
tmp_l2=lv_l9;
for(tmp_i3=0;tmp_i3<100;tmp_i3=tmp_i3+1)
{
if(!(g_tradeStats[tmp_i3][0]==tmp_l2)) continue;
tmp_d4=g_tradeStats[tmp_i3][1];
break;

}
tmp_d4=0.0;
lv_d17=NormalizeDouble(tmp_d4,tmp_i1);
if(lv_d17==0.0)
{
tmp_d5=lv_d10;
tmp_l6=lv_l9;
for(tmp_i7=0;tmp_i7<100;tmp_i7=tmp_i7+1)
{
if(!(g_tradeStats[tmp_i7][0]==0.0)) continue;
g_tradeStats[tmp_i7][0] = (double)(tmp_l6);
g_tradeStats[tmp_i7][1]=tmp_d5;
break;

}
lv_d17=lv_d10;
}
else
{
lv_d17=lv_d17-g_breakEvenOffset*g_pointSize;
}
lv_d18=lv_d17-lv_d10;
lv_b19=false;
if(lv_d17>g_breakEvenOffset*g_pointSize&&lv_d18>g_maxVolatility*g_pointSize)
{
lv_b19=true;
if(g_volPeriod==2)
{
g_st2_entryHigh=-1000.0;
Print("Slippage Mode 2 active");
}
}
if(g_useVirtualSL)
{
lv_d5=lv_d17;
}
else
{
lv_d5=lv_d10;
}
if(lv_d7>NormalizeDouble((g_minProfitClose+g_newsImpactLevel)*g_pointSize+lv_d10+g_spread,g_digits))
{
lv_d7=NormalizeDouble((g_minProfitClose+g_newsImpactLevel)*g_pointSize+lv_d10+g_spread,g_digits);
_orderOK = OrderModify((int)lv_l9,lv_d10,lv_d7,lv_d8,0,clrNONE);
}
if(MarketInfo(g_tradeSymbol,MODE_ASK)>(g_minProfitClose+g_newsImpactLevel)*g_pointSize+lv_d10+g_spread)
{
RefreshRates();
_orderOK = OrderClose(OrderTicket(),OrderLots(),MarketInfo(g_tradeSymbol,MODE_ASK),(int)g_spread,Red);
return(true);
}
lv_b20=false;
if(g_zrEnabled)
{
tmp_l8=lv_l9;
tmp_i9=0;
for(tmp_i10=MT4OrdersTotal();tmp_i10>=0;tmp_i10=tmp_i10-1)
{
if(OrderSelect(tmp_i10,0,0)!=true||OrderMagicNumber()!=g_zrSellMagic||OrderSymbol()!=g_tradeSymbol) continue;
tmp_s11=OrderComment();
if(tmp_s11!=IntegerToString(tmp_l8,0,32)) continue;
tmp_i9=tmp_i9+1;

}
lv_d21=tmp_i9;
lv_b22=false;
if(!(g_hasSellOrder))
{
g_hasSellOrder=true;
g_openSellCount=1;
}
if(lv_d21==0.0)
{
g_openSellCount=1;
}
if(MathFloor(lv_d21/2.0)==lv_d21/2.0)
{
g_openSellCount=1;
}
else
{
g_openSellCount=0;
}
if(g_hasSellOrder)
{
if(lv_d21>0.0)
{
tmp_d12=AccountEquity();
if(tmp_d12>AccountBalance()+g_zrMaxStep)
{
for(tmp_i13=MT4OrdersTotal();tmp_i13>=0;tmp_i13=tmp_i13-1)
{
if(OrderSelect(tmp_i13,0,0)!=true) continue;

if((OrderMagicNumber()!=g_magicMain&&OrderMagicNumber()!=g_zrSellMagic&&OrderMagicNumber()!=g_zrBuyMagic)) continue;

if(OrderType()==0)
{
_orderOK = OrderClose(OrderTicket(),OrderLots(),MarketInfo(g_tradeSymbol,MODE_BID),(int)g_maxVolatility,Red);
}
if(OrderType()!=1) continue;
_orderOK = OrderClose(OrderTicket(),OrderLots(),MarketInfo(g_tradeSymbol,MODE_ASK),(int)g_maxVolatility,Red);

}
}
}
if(lv_d21>0.0)
{
tmp_l14=lv_l9;
tmp_d15=0.0;
for(tmp_i16=MT4OrdersTotal();tmp_i16>=0;tmp_i16=tmp_i16-1)
{
if(OrderSelect(tmp_i16,0,0)!=true) continue;
tmp_l17=OrderTicket();
if(tmp_l17!=tmp_l14)
{
tmp_s11=OrderComment();
if(tmp_s11!=IntegerToString(tmp_l14,0,32)) continue;
}
tmp_d15=tmp_d15+OrderProfit();

}
if(tmp_d15>g_zrMaxStep)
{
Print("Closingzone");
tmp_l18=lv_l9;
for(tmp_i19=MT4OrdersTotal();tmp_i19>=0;tmp_i19=tmp_i19-1)
{
if(OrderSelect(tmp_i19,0,0)!=true) continue;

if(OrderMagicNumber()==g_magicMain&&OrderTicket()==tmp_l18)
{
_orderOK = OrderClose(OrderTicket(),OrderLots(),MarketInfo(g_tradeSymbol,MODE_ASK),3,Red);
}
if(OrderMagicNumber()!=g_zrSellMagic) continue;
tmp_s11=OrderComment();
if(tmp_s11!=IntegerToString(tmp_l18,0,32)) continue;

if(OrderType()==0)
{
_orderOK = OrderClose(OrderTicket(),OrderLots(),MarketInfo(g_tradeSymbol,MODE_BID),(int)g_maxVolatility,Red);
}
if(OrderType()!=1) continue;
_orderOK = OrderClose(OrderTicket(),OrderLots(),MarketInfo(g_tradeSymbol,MODE_ASK),(int)g_maxVolatility,Red);

}
g_hasSellOrder=false;
lv_b20=true;
}
}
else
{
lv_d23=lv_d12*g_zrLotMultiplier;
if(g_zrMaxOrders==2)
{
lv_d23=(lv_d21+1.0)*lv_d12+lv_d12;
}
if(g_zrMaxOrders==3)
{
lv_d23=lv_d12*(MathPow(g_zrLotMultiplier,lv_d21+1.0));
}
if(g_openSellCount==0)
{
lv_d24=lv_d17;
if(MarketInfo(g_tradeSymbol,MODE_BID)<lv_d17)
{
if(lv_d21>=g_zrMaxMagic)
{
for(tmp_i20=MT4OrdersTotal();tmp_i20>=0;tmp_i20=tmp_i20-1)
{
if(OrderSelect(tmp_i20,0,0)!=true) continue;

if(OrderMagicNumber()==g_magicMain&&OrderTicket()==lv_l9)
{
_orderOK = OrderClose(OrderTicket(),OrderLots(),MarketInfo(g_tradeSymbol,MODE_ASK),3,Red);
}
if(OrderMagicNumber()!=g_zrSellMagic) continue;
tmp_s11=OrderComment();
if(tmp_s11!=IntegerToString(lv_l9,0,32)) continue;

if(OrderType()==0)
{
_orderOK = OrderClose(OrderTicket(),OrderLots(),MarketInfo(g_tradeSymbol,MODE_BID),(int)g_maxVolatility,Red);
}
if(OrderType()!=1) continue;
_orderOK = OrderClose(OrderTicket(),OrderLots(),MarketInfo(g_tradeSymbol,MODE_ASK),(int)g_maxVolatility,Red);

}
}
else
{
_orderOK = OrderSend(g_tradeSymbol,OP_SELL,lv_d23,MarketInfo(g_tradeSymbol,MODE_BID),(int)g_maxVolatility,0.0,0.0,IntegerToString(lv_l9,0,32),g_zrSellMagic,0,Green);
g_openSellCount=1;
lv_b22=true;
}
}
}
else
{
lv_d25=g_zrZoneSize*g_pointSize+lv_d17-lv_d21*g_zrStep*g_pointSize;
if(lv_d25<g_zrMinStep*g_pointSize+lv_d17)
{
lv_d25=g_zrMinStep*g_pointSize+lv_d17;
}
if(MarketInfo(g_tradeSymbol,MODE_ASK)>lv_d25)
{
if(lv_d21>=g_zrMaxMagic)
{
for(tmp_i21=MT4OrdersTotal();tmp_i21>=0;tmp_i21=tmp_i21-1)
{
if(OrderSelect(tmp_i21,0,0)!=true) continue;

if(OrderMagicNumber()==g_magicMain&&OrderTicket()==lv_l9)
{
_orderOK = OrderClose(OrderTicket(),OrderLots(),MarketInfo(g_tradeSymbol,MODE_ASK),3,Red);
}
if(OrderMagicNumber()!=g_zrSellMagic) continue;
tmp_s22=OrderComment();
if(tmp_s22!=IntegerToString(lv_l9,0,32)) continue;

if(OrderType()==0)
{
_orderOK = OrderClose(OrderTicket(),OrderLots(),MarketInfo(g_tradeSymbol,MODE_BID),(int)g_maxVolatility,Red);
}
if(OrderType()!=1) continue;
_orderOK = OrderClose(OrderTicket(),OrderLots(),MarketInfo(g_tradeSymbol,MODE_ASK),(int)g_maxVolatility,Red);

}
}
else
{
_orderOK = OrderSend(g_tradeSymbol,OP_BUY,lv_d23,MarketInfo(g_tradeSymbol,MODE_ASK),(int)g_maxVolatility,0.0,0.0,IntegerToString(lv_l9,0,32),g_zrSellMagic,0,Green);
g_openSellCount=0;
lv_b22=true;
}
}
}
}
}
if((lv_d21>0.0||lv_b22))
{
lv_b20=true;
}
}
if(!(lv_b20))
{
if((g_newsFilterMode==1||(g_newsFilterMode!=2&&g_newsFilterMode!=3)))
{
tmp_l23=lv_l9;
tmp_d24=g_minProfitClose;
tmp_d25=lv_d10;
tmp_i26=2;
tmp_d27=0.0;
tmp_b28=false;
for(tmp_i29=0;tmp_i29<g_panelX;tmp_i29=tmp_i29+1)
{
if(g_perfMatrix[tmp_i29][0]==tmp_l23)
{
tmp_d27=g_perfMatrix[tmp_i29][1];
tmp_b28=true;
break;
}
}
if(!(tmp_b28))
{
if(tmp_i26==1)
{
tmp_d27=NormalizeDouble(tmp_d25-tmp_d24*g_pointSize,g_digits);
}
if(tmp_i26==2)
{
tmp_d27=NormalizeDouble(tmp_d24*g_pointSize+tmp_d25,g_digits);
}
for(tmp_i30=0;tmp_i30<g_panelX;tmp_i30=tmp_i30+1)
{
if(g_perfMatrix[tmp_i30][0]==0.0)
{
g_perfMatrix[tmp_i30][0] = (double)(tmp_l23);
g_perfMatrix[tmp_i30][1]=tmp_d27;
break;
}
}
}
g_ask=tmp_d27;
lv_d4=g_ask;
if(MarketInfo(g_tradeSymbol,MODE_ASK)>lv_d4)
{
Print("Closing with virtual SL");
RefreshRates();
_orderOK = OrderClose((int)lv_l9,lv_d12,MarketInfo(g_tradeSymbol,MODE_ASK),(int)g_spread,clrNONE);
return(true);
}
if(g_recovTrailStart>0.0&&TimeCurrent()>=lv_dt13+g_initRetries&&MarketInfo(g_tradeSymbol,MODE_ASK)<lv_d7-g_point-g_recovTrailStep*g_pointSize&&MarketInfo(g_tradeSymbol,MODE_ASK)>lv_d8+g_stopLevelPts&&NormalizeDouble(MarketInfo(g_tradeSymbol,MODE_ASK)+g_recovTrailStep*g_pointSize,g_digits)<lv_d7)
{
lv_d7=NormalizeDouble(MarketInfo(g_tradeSymbol,MODE_ASK)+g_recovTrailStep*g_pointSize,g_digits);
if(lv_d7>MarketInfo(g_tradeSymbol,MODE_ASK)+g_minStopLevel)
{
g_lastError=OrderModify((int)lv_l9,lv_d10,lv_d7,lv_d8,0,clrNONE);
if(g_lastError<=0)
{
Print("TrailStoperror:\'"+GetErrorDescription(MT4_LastError())+"\'whensettingtrailingExit_TrailSL_after_X_Minutes_sizeloss. Tryingagain!");
}
lv_b2=true;
}
}
if(g_trailStep>0.0&&MarketInfo(g_tradeSymbol,MODE_ASK)<lv_d7-g_point-(g_trailStep+g_trailOffset)*g_pointSize&&MarketInfo(g_tradeSymbol,MODE_ASK)<lv_d5-g_trailStart*g_pointSize&&MarketInfo(g_tradeSymbol,MODE_ASK)>lv_d8+g_stopLevelPts&&lv_d7>lv_d10-g_trailStop*g_pointSize&&NormalizeDouble(g_trailStep*g_pointSize+MarketInfo(g_tradeSymbol,MODE_ASK),g_digits)<lv_d7)
{
lv_d7=NormalizeDouble(MarketInfo(g_tradeSymbol,MODE_ASK)+g_trailStep*g_pointSize,g_digits);
if(lv_d7>MarketInfo(g_tradeSymbol,MODE_ASK)+g_minStopLevel)
{
g_lastError=OrderModify((int)lv_l9,lv_d10,lv_d7,lv_d8,0,clrNONE);
if(g_lastError<=0)
{
Print("TrailStoperror:\'"+GetErrorDescription(MT4_LastError())+"\'whensettingtrailingExit_stoploss. Tryingagain!");
}
else
{
lv_d26=NormalizeDouble(g_trailMin/100.0*g_pairStratLots[g_pairIdx],2);
if(lv_d26<lv_d12&&lv_d26>=MarketInfo(g_tradeSymbol,MODE_LOTSTEP))
{
_orderOK = OrderClose((int)lv_l9,lv_d26,MarketInfo(g_tradeSymbol,MODE_ASK),(int)g_maxVolatility,Red);
return(true);
}
}
lv_b2=true;
}
}
if(g_trailMax>0.0&&MarketInfo(g_tradeSymbol,MODE_BID)>NormalizeDouble(g_trailMax*g_pointSize+(lv_d8+g_point),g_digits)&&MarketInfo(g_tradeSymbol,MODE_BID)>NormalizeDouble(g_trailFactor*g_pointSize+lv_d5,g_digits)&&MarketInfo(g_tradeSymbol,MODE_BID)>lv_d8+g_stopLevelPts)
{
lv_d8=NormalizeDouble(MarketInfo(g_tradeSymbol,MODE_BID)-g_trailMax*g_pointSize,g_digits);
if(lv_d8<MarketInfo(g_tradeSymbol,MODE_BID)-g_minStopLevel)
{
g_lastError=OrderModify((int)lv_l9,lv_d10,lv_d7,lv_d8,0,clrNONE);
if(g_lastError<=0)
{
Print("TrailStoperror:\'"+GetErrorDescription(MT4_LastError())+"\'whensettingtrailingExit_TP. Tryingagain!");
}
else
{
lv_d27=NormalizeDouble(g_trailMin/100.0*g_pairStratLots[g_pairIdx],2);
if(lv_d27<lv_d12&&lv_d27>=SymbolInfoDouble(g_tradeSymbol,SYMBOL_VOLUME_MIN))
{
_orderOK = OrderClose((int)lv_l9,lv_d27,MarketInfo(g_tradeSymbol,MODE_ASK),(int)g_maxVolatility,Red);
return(true);
}
}
lv_b2=true;
}
}
if(lv_b19&&g_volPeriod==1&&g_exitRange>0.0&&MarketInfo(g_tradeSymbol,MODE_ASK)<lv_d7-g_point-g_exitRange*g_pointSize&&MarketInfo(g_tradeSymbol,MODE_ASK)<lv_d17-g_entryRange*g_pointSize&&MarketInfo(g_tradeSymbol,MODE_ASK)>lv_d8+g_stopLevelPts&&lv_d7>lv_d10-g_filterRange*g_pointSize&&NormalizeDouble(MarketInfo(g_tradeSymbol,MODE_ASK)+g_exitRange*g_pointSize,g_digits)<lv_d7)
{
lv_d7=NormalizeDouble(MarketInfo(g_tradeSymbol,MODE_ASK)+g_exitRange*g_pointSize,g_digits);
if(lv_d7>MarketInfo(g_tradeSymbol,MODE_ASK)+g_minStopLevel)
{
g_lastError=OrderModify((int)lv_l9,lv_d10,lv_d7,lv_d8,0,clrNONE);
if(g_lastError<=0)
{
Print("TrailStoperror:\'"+GetErrorDescription(MT4_LastError())+"\'whensettingSlipTL. Tryingagain!");
}
else
{
Print("Slippagecontroleactive");
}
lv_b2=true;
}
}
if(g_hlTrailShift> 0&&g_hlTrailMode>=0&&UseHL_TrailingSL&&g_pairOpenProfit[g_pairIdx]<lv_d7-g_minStopLevel-g_point&&g_pairOpenProfit[g_pairIdx]>g_hlTrailBars*g_pointSize+MarketInfo(g_tradeSymbol,MODE_ASK)&&(g_pairOpenProfit[g_pairIdx]>lv_d10||!(g_useHLTrail))&&g_pairOpenProfit[g_pairIdx]>g_hlTrailOffset*g_pointSize+MarketInfo(g_tradeSymbol,MODE_ASK)+g_minStopLevel+g_point&&MarketInfo(g_tradeSymbol,MODE_ASK)>lv_d8+g_stopLevelPts&&NormalizeDouble(g_pairOpenProfit[g_pairIdx],g_digits)<lv_d7)
{
lv_d7=NormalizeDouble(g_pairOpenProfit[g_pairIdx],g_digits);
if(lv_d7>MarketInfo(g_tradeSymbol,MODE_ASK)+g_minStopLevel)
{
g_lastError=OrderModify((int)lv_l9,lv_d10,lv_d7,lv_d8,0,clrNONE);
if(g_lastError<=0)
{
Print("error:\'"+GetErrorDescription(MT4_LastError())+"\'whenmodifyingstoploss");
}
lv_b2=true;
}
}
if(g_beProfitTrigger>0.0&&MarketInfo(g_tradeSymbol,MODE_ASK)<lv_d10-g_beProfitTrigger*g_pointSize&&lv_d10-g_beOffset*g_pointSize<lv_d7-g_point&&MarketInfo(g_tradeSymbol,MODE_ASK)<lv_d10-g_beOffset*g_pointSize-g_minStopLevel&&MarketInfo(g_tradeSymbol,MODE_ASK)>lv_d8+g_stopLevelPts&&NormalizeDouble(lv_d10-g_beOffset*g_pointSize,g_digits)<lv_d7)
{
lv_d7=NormalizeDouble(lv_d10-g_beOffset*g_pointSize,g_digits);
if(lv_d7>MarketInfo(g_tradeSymbol,MODE_ASK)+g_minStopLevel)
{
g_lastError=OrderModify((int)lv_l9,lv_d10,lv_d7,lv_d8,0,clrNONE);
if(g_lastError<=0)
{
Print("errorwhensettingbreakeven:\'"+GetErrorDescription(MT4_LastError())+"\'..\'Exit_BE_start\'tocloseto\'Exit_BE_extra_pips\'..tryingagain!");
}
lv_b2=true;
}
}
if(!(lv_b2)&&(g_magicTrailMode==1||(g_magicTrailMode==2&&lv_d7-g_magicTrailFast*g_pointSize>=lv_d5-g_spread-g_magicTrailSlow*g_pointSize)))
{
g_st2_TP++;
if(MarketInfo(g_tradeSymbol,MODE_ASK)<lv_d7-g_magicTrailFast*g_pointSize-g_minStopLevel&&MarketInfo(g_tradeSymbol,MODE_ASK)>lv_d8+g_stopLevelPts&&(g_magicTrailStep==0.0||MarketInfo(g_tradeSymbol,MODE_ASK)<lv_d5-g_st2_entryHigh*g_pointSize)&&g_st2_TP>=g_magicTrailPeriod&&NormalizeDouble(lv_d7-g_magicTrailFast*g_pointSize,g_digits)<lv_d7)
{
g_st2_TP=0;
lv_d7=NormalizeDouble(lv_d7-g_magicTrailFast*g_pointSize,g_digits);
_orderOK = OrderModify((int)lv_l9,lv_d10,lv_d7,lv_d8,0,clrNONE);
lv_b2=true;
}
}
g_ask=lv_d7;
if(MarketInfo(g_tradeSymbol,MODE_ASK)>lv_d7)
{
Print("Closing with virtual SL");
RefreshRates();
_orderOK = OrderClose((int)lv_l9,lv_d12,MarketInfo(g_tradeSymbol,MODE_ASK),(int)g_spread,clrNONE);
return(true);
}
if(NormalizeDouble(lv_d4,g_digits)!=NormalizeDouble(g_ask,g_digits))
{
tmp_d31=NormalizeDouble(g_ask,g_digits);
tmp_l32=lv_l9;
for(tmp_i33=0;tmp_i33<g_panelX;tmp_i33=tmp_i33+1)
{
if(g_perfMatrix[tmp_i33][0]==tmp_l32)
{
g_perfMatrix[tmp_i33][1]=tmp_d31;
break;
}
}
}
if(lv_b2&&g_useCompound)
{
return(true);
}
}
if((g_newsFilterMode==2||g_newsFilterMode==3))
{
tmp_l34=lv_l9;
tmp_d35=g_minProfitClose;
tmp_d36=lv_d10;
tmp_i37=2;
tmp_d38=0.0;
tmp_b39=false;
for(tmp_i40=0;tmp_i40<g_panelX;tmp_i40=tmp_i40+1)
{
if(g_perfMatrix[tmp_i40][0]==tmp_l34)
{
tmp_d38=g_perfMatrix[tmp_i40][1];
tmp_b39=true;
break;
}
}
if(!(tmp_b39))
{
if(tmp_i37==1)
{
tmp_d38=NormalizeDouble(tmp_d36-tmp_d35*g_pointSize,g_digits);
}
if(tmp_i37==2)
{
tmp_d38=NormalizeDouble(tmp_d35*g_pointSize+tmp_d36,g_digits);
}
for(tmp_i41=0;tmp_i41<g_panelX;tmp_i41=tmp_i41+1)
{
if(g_perfMatrix[tmp_i41][0]==0.0)
{
g_perfMatrix[tmp_i41][0] = (double)(tmp_l34);
g_perfMatrix[tmp_i41][1]=tmp_d38;
break;
}
}
}
g_ask=tmp_d38;
lv_d4=g_ask;
if(MarketInfo(g_tradeSymbol,MODE_ASK)>=lv_d4)
{
RefreshRates();
_orderOK = OrderClose((int)lv_l9,lv_d12,MarketInfo(g_tradeSymbol,MODE_ASK),(int)g_spread,clrNONE);
return(true);
}
lv_i28 = (int)(TimeCurrent()-g_dailyResetTime);
if(lv_i28>=g_maxSpreadFilter)
{
if(NormalizeDouble(g_ask,g_digits)<lv_d7-g_point)
{
_orderOK = OrderModify((int)lv_l9,lv_d10,NormalizeDouble(g_ask,g_digits),lv_d8,0,clrNONE);
}
g_dailyResetTime=TimeCurrent();
}
if(g_recovTrailStart>0.0&&TimeCurrent()>=lv_dt13+g_initRetries&&MarketInfo(g_tradeSymbol,MODE_ASK)<g_ask-g_point-g_recovTrailStep*g_pointSize&&MarketInfo(g_tradeSymbol,MODE_ASK)>lv_d8+g_stopLevelPts)
{
g_ask=MarketInfo(g_tradeSymbol,MODE_ASK)+g_recovTrailStep*g_pointSize;
lv_b2=true;
}
if(g_trailStep>0.0&&MarketInfo(g_tradeSymbol,MODE_ASK)<g_ask-g_point-(g_trailStep+g_trailOffset)*g_pointSize&&MarketInfo(g_tradeSymbol,MODE_ASK)<lv_d5-g_trailStart*g_pointSize&&g_ask>lv_d10-g_trailStop*g_pointSize)
{
g_ask=g_trailStep*g_pointSize+MarketInfo(g_tradeSymbol,MODE_ASK);
lv_d29=NormalizeDouble(g_trailMin/100.0*g_pairStratLots[g_pairIdx],2);
if(lv_d29<lv_d12&&lv_d29>=MarketInfo(g_tradeSymbol,MODE_LOTSTEP))
{
_orderOK = OrderClose((int)lv_l9,lv_d29,MarketInfo(g_tradeSymbol,MODE_BID),(int)g_maxVolatility,Red);
return(true);
}
lv_b2=true;
}
if(lv_b19&&g_volPeriod==1&&g_exitRange>0.0&&MarketInfo(g_tradeSymbol,MODE_ASK)<g_ask-g_point-g_exitRange*g_pointSize&&MarketInfo(g_tradeSymbol,MODE_ASK)<lv_d17-g_entryRange*g_pointSize&&MarketInfo(g_tradeSymbol,MODE_ASK)>lv_d8+g_stopLevelPts&&g_ask>lv_d10-g_filterRange*g_pointSize)
{
Print("Slippagecontroleactive");
lv_b2=true;
g_ask=MarketInfo(g_tradeSymbol,MODE_ASK)+g_exitRange*g_pointSize;
}
if(g_hlTrailShift> 0&&g_hlTrailMode>=0&&g_pairOpenProfit[g_pairIdx]<g_ask-g_minStopLevel-g_point&&(g_pairOpenProfit[g_pairIdx]>lv_d10||!(g_useHLTrail))&&g_pairOpenProfit[g_pairIdx]>g_hlTrailOffset*g_pointSize+MarketInfo(g_tradeSymbol,MODE_ASK)+g_minStopLevel+g_point&&MarketInfo(g_tradeSymbol,MODE_ASK)>lv_d8+g_stopLevelPts)
{
g_ask=g_pairOpenProfit[g_pairIdx];
lv_b2=true;
}
if(g_beProfitTrigger>0.0&&g_newsFilterMode==3&&MarketInfo(g_tradeSymbol,MODE_ASK)<lv_d10-g_beProfitTrigger*g_pointSize&&lv_d10-g_beOffset*g_pointSize<lv_d7-g_point&&MarketInfo(g_tradeSymbol,MODE_ASK)<lv_d10-g_beOffset*g_pointSize-g_minStopLevel&&MarketInfo(g_tradeSymbol,MODE_ASK)>lv_d8+g_stopLevelPts&&NormalizeDouble(lv_d10-g_beOffset*g_pointSize,g_digits)<g_ask)
{
g_ask=NormalizeDouble(lv_d10-g_beOffset*g_pointSize,g_digits);
g_lastError=OrderModify((int)lv_l9,lv_d10,g_ask,lv_d8,0,clrNONE);
if(g_lastError<=0)
{
Print("errorwhensettingbreakeven:\'"+GetErrorDescription(MT4_LastError())+"\'..\'Exit_BE_start\'tocloseto\'Exit_BE_extra_pips\'..tryingagain!");
}
lv_b2=true;
}
if(g_beProfitTrigger>0.0&&g_newsFilterMode==2&&MarketInfo(g_tradeSymbol,MODE_ASK)<lv_d10-g_beProfitTrigger*g_pointSize&&lv_d10-g_beOffset*g_pointSize<g_ask-g_point&&MarketInfo(g_tradeSymbol,MODE_ASK)<lv_d10-g_beOffset*g_pointSize-g_minStopLevel&&MarketInfo(g_tradeSymbol,MODE_ASK)>lv_d8+g_stopLevelPts)
{
g_ask=lv_d10-g_beOffset*g_pointSize;
lv_b2=true;
}
if(!(lv_b2)&&(g_magicTrailMode==1||(g_magicTrailMode==2&&g_ask-g_magicTrailFast*g_pointSize>=lv_d5-g_spread-g_magicTrailSlow*g_pointSize)))
{
g_st2_TP++;
if(MarketInfo(g_tradeSymbol,MODE_ASK)<g_ask-g_magicTrailFast*g_pointSize-g_minStopLevel&&MarketInfo(g_tradeSymbol,MODE_ASK)>lv_d8+g_stopLevelPts&&(g_magicTrailStep==0.0||MarketInfo(g_tradeSymbol,MODE_ASK)<lv_d5-g_st2_entryHigh*g_pointSize)&&g_st2_TP>=g_magicTrailPeriod)
{
g_st2_TP=0;
g_ask=g_ask-g_magicTrailFast*g_pointSize;
lv_b2=true;
}
}
if(MarketInfo(g_tradeSymbol,MODE_ASK)>=g_ask)
{
RefreshRates();
_orderOK = OrderClose((int)lv_l9,lv_d12,MarketInfo(g_tradeSymbol,MODE_ASK),(int)g_spread,clrNONE);
return(true);
}
if(NormalizeDouble(lv_d4,g_digits)!=NormalizeDouble(g_ask,g_digits))
{
tmp_d42=NormalizeDouble(g_ask,g_digits);
tmp_l43=lv_l9;
for(tmp_i44=0;tmp_i44<g_panelX;tmp_i44=tmp_i44+1)
{
if(g_perfMatrix[tmp_i44][0]==tmp_l43)
{
g_perfMatrix[tmp_i44][1]=tmp_d42;
break;
}
}
}
}
}
}
if(lv_b2)
{
lv_b3=true;
}
}
if(lv_b2)
{
lv_b3=true;
}
}
return(lv_b3);
}
// ManageSellTrade<<==-------- --------
bool CheckTradingHours()
{
bool lv_b2;
datetime lv_dt3;
int lv_i4;
//----------
bool tmp_b1 = false;
bool tmp_b2 = false;
bool tmp_b3 = false;
bool tmp_b4 = false;
bool tmp_b5 = false;
bool tmp_b6 = false;

if(!(g_useTradingHours))
{
return(true);
}
lv_b2=false;
lv_dt3=0;
if(g_tradingHoursMode==2)
{
lv_dt3=TimeCurrent();
}
if(g_tradingHoursMode==0)
{
TimeGMT();
}
if(g_tradingHoursMode==1)
{
TimeLocal();
}
lv_i4=TimeHour(lv_dt3);
if(TimeDayOfWeek(lv_dt3)==0)
{
if(g_monStart< g_monEnd&&(lv_i4<g_monStart||lv_i4>=g_monEnd))
{
tmp_b1=false;
}
else
{
if(g_monStart> g_monEnd&&lv_i4< g_monStart&&lv_i4>=g_monEnd)
{
tmp_b1=false;
}
else
{
if(g_monStart==g_monEnd)
{
tmp_b1=false;
}
else
{
tmp_b1=true;
}
}
}
if(tmp_b1)
{
lv_b2=true;
}
}
if(TimeDayOfWeek(lv_dt3)==1)
{
if(g_tueStart< g_tueEnd&&(lv_i4<g_tueStart||lv_i4>=g_tueEnd))
{
tmp_b2=false;
}
else
{
if(g_tueStart> g_tueEnd&&lv_i4< g_tueStart&&lv_i4>=g_tueEnd)
{
tmp_b2=false;
}
else
{
if(g_tueStart==g_tueEnd)
{
tmp_b2=false;
}
else
{
tmp_b2=true;
}
}
}
if(tmp_b2)
{
lv_b2=true;
}
}
if(TimeDayOfWeek(lv_dt3)==2)
{
if(g_wedStart< g_wedEnd&&(lv_i4<g_wedStart||lv_i4>=g_wedEnd))
{
tmp_b3=false;
}
else
{
if(g_wedStart> g_wedEnd&&lv_i4< g_wedStart&&lv_i4>=g_wedEnd)
{
tmp_b3=false;
}
else
{
if(g_wedStart==g_wedEnd)
{
tmp_b3=false;
}
else
{
tmp_b3=true;
}
}
}
if(tmp_b3)
{
lv_b2=true;
}
}
if(TimeDayOfWeek(lv_dt3)==3)
{
if(g_thuStart< g_thuEnd&&(lv_i4<g_thuStart||lv_i4>=g_thuEnd))
{
tmp_b4=false;
}
else
{
if(g_thuStart> g_thuEnd&&lv_i4< g_thuStart&&lv_i4>=g_thuEnd)
{
tmp_b4=false;
}
else
{
if(g_thuStart==g_thuEnd)
{
tmp_b4=false;
}
else
{
tmp_b4=true;
}
}
}
if(tmp_b4)
{
lv_b2=true;
}
}
if(TimeDayOfWeek(lv_dt3)==4)
{
if(g_friStart< g_friEnd&&(lv_i4<g_friStart||lv_i4>=g_friEnd))
{
tmp_b5=false;
}
else
{
if(g_friStart> g_friEnd&&lv_i4< g_friStart&&lv_i4>=g_friEnd)
{
tmp_b5=false;
}
else
{
if(g_friStart==g_friEnd)
{
tmp_b5=false;
}
else
{
tmp_b5=true;
}
}
}
if(tmp_b5)
{
lv_b2=true;
}
}
if(TimeDayOfWeek(lv_dt3)==5)
{
if(g_satStart< g_satEnd&&(lv_i4<g_satStart||lv_i4>=g_satEnd))
{
tmp_b6=false;
}
else
{
if(g_satStart> g_satEnd&&lv_i4< g_satStart&&lv_i4>=g_satEnd)
{
tmp_b6=false;
}
else
{
if(g_satStart==g_satEnd)
{
tmp_b6=false;
}
else
{
tmp_b6=true;
}
}
}
if(tmp_b6)
{
lv_b2=true;
}
}
return(lv_b2);
}
// CheckTradingHours<<==-------- --------
string GetErrorDescription(int param0)
{
string errorStr;
//----------

g_tradeErrCount++;
switch(param0)
{
case 0:case 1:
errorStr="no error";
break;
case 2:
errorStr="common error";
break;
case 3:
errorStr="invalid trade parameters";
break;
case 4:
errorStr="trade server is busy";
break;
case 5:
errorStr="oldversionoftheclientterminal";
break;
case 6:
errorStr="noconnectionwithtradeserver";
break;
case 7:
errorStr="notenoughrights";
break;
case 8:
errorStr="toofrequentrequests";
break;
case 9:
errorStr="malfunctionaltradeoperation(neverreturnederror)";
break;
case 64:
errorStr="accountdisabled";
break;
case 65:
errorStr="invalidaccount";
break;
case 128:
errorStr="tradetimeout";
break;
case 129:
errorStr="invalidprice";
break;
case 130:
errorStr="invalidstops";
break;
case 131:
errorStr="invalidtradevolume";
break;
case 132:
errorStr="marketisclosed";
break;
case 133:
errorStr="tradeisdisabled";
break;
case 134:
errorStr="notenoughmoney";
break;
case 135:
errorStr="pricechanged";
break;
case 136:
errorStr="off quotes";
break;
case 137:
errorStr="brokerisbusy(neverreturnederror)";
break;
case 138:
errorStr="requote";
break;
case 139:
errorStr="orderislocked";
break;
case 140:
errorStr="long positionsonlyallowed";
break;
case 141:
errorStr="toomanyrequests";
break;
case 145:
errorStr="modificationdeniedbecauseordertooclosetomarket";
break;
case 146:
errorStr="tradecontextisbusy";
break;
case 147:
errorStr="expirationsaredeniedbybroker";
break;
case 148:
errorStr="amount of open and pending orders has reached the Exit_limit";
break;
case 149:
errorStr="hedgingisprohibited";
break;
case 150:
errorStr="prohibited by FIFO rules";
break;
case 4000:
errorStr="noerror(nevergeneratedcode)";
break;
case 4001:
errorStr="wrongfunctionpointer";
break;
case 4002:
errorStr="arrayindexisoutofrange";
break;
case 4003:
errorStr="nomemoryforfunctioncallstack";
break;
case 4004:
errorStr="recursivestackoverflow";
break;
case 4005:
errorStr="notenoughstackforparameter";
break;
case 4006:
errorStr="nomemoryforparameter string";
break;
case 4007:
errorStr="nomemoryfortemp string";
break;
case 4008:
errorStr="notinitialized string";
break;
case 4009:
errorStr="notinitializedstringinarray";
break;
case 4010:
errorStr="nomemoryforarray\'string";
break;
case 4011:
errorStr="too long string";
break;
case 4012:
errorStr="remainderfromzerodivide";
break;
case 4013:
errorStr="zerodivide";
break;
case 4014:
errorStr="unknowncommand";
break;
case 4015:
errorStr="wrongjump(nevergeneratederror)";
break;
case 4016:
errorStr="notinitializedarray";
break;
case 4017:
errorStr="dllcallsarenotallowed";
break;
case 4018:
errorStr="cannotloadlibrary";
break;
case 4019:
errorStr="cannotcallfunction";
break;
case 4020:
errorStr="expertfunctioncallsarenotallowed";
break;
case 4021:
errorStr="notenoughmemoryfortempstringreturnedfromfunction";
break;
case 4022:
errorStr="systemisbusy(nevergeneratederror)";
break;
case 4050:
errorStr="invalidfunctionparameterscount";
break;
case 4051:
errorStr="invalidfunctionparametervalue";
break;
case 4052:
errorStr="string function internal error";
break;
case 4053:
errorStr="somearrayerror";
break;
case 4054:
errorStr="incorrectseriesarrayusing";
break;
case 4055:
errorStr="customindicatorerror";
break;
case 4056:
errorStr="arraysareincompatible";
break;
case 4057:
errorStr="globalvariablesprocessingerror";
break;
case 4058:
errorStr="globalvariablenotfound";
break;
case 4059:
errorStr="functionisnotallowedintestingmode";
break;
case 4060:
errorStr="functionisnotconfirmed";
break;
case 4061:
errorStr="sendmailerror";
break;
case 4062:
errorStr="string parameter expected";
break;
case 4063:
errorStr="integer parameter expected";
break;
case 4064:
errorStr="double parameter expected";
break;
case 4065:
errorStr="arrayasparameterexpected";
break;
case 4066:
errorStr="requestedhistorydatainupdatestate";
break;
case 4099:
errorStr="endoffile";
break;
case 4100:
errorStr="somefileerror";
break;
case 4101:
errorStr="wrongfilename";
break;
case 4102:
errorStr="toomanyopenedfiles";
break;
case 4103:
errorStr="cannotopenfile";
break;
case 4104:
errorStr="incompatibleaccesstoafile";
break;
case 4105:
errorStr="noorderselected";
break;
case 4106:
errorStr="unknownsymbol";
break;
case 4107:
errorStr="invalidpriceparameterfortradefunction";
break;
case 4108:
errorStr="invalidticket";
break;
case 4109:
errorStr="tradeisnotallowedintheexpertproperties";
break;
case 4110:
errorStr="long sarenotallowedintheexpertproperties";
break;
case 4111:
errorStr="short sarenotallowedintheexpertproperties";
break;
case 4200:
errorStr="objectisalreadyexist";
break;
case 4201:
errorStr="unknownobjectproperty";
break;
case 4202:
errorStr="objectisnotexist";
break;
case 4203:
errorStr="unknownobjecttype";
break;
case 4204:
errorStr="noobjectname";
break;
case 4205:
errorStr="objectcoordinateserror";
break;
case 4206:
errorStr="nospecifiedsubwindow";
break;
default:
errorStr="unknownerror";
}
return(errorStr);
}
// GetErrorDescription<<==-------- --------
void DrawInfoPanel(bool bParam0)
{
double lv_d1;
int lv_i2;
int lv_i3;
double lv_d4;
long lv_l5;
double lv_d6;
double lv_d7;
datetime lv_dt8;
string lv_s9;
int lv_i10;
double lv_d11;
long lv_l12;
double lv_d13;
double lv_d14;
datetime lv_dt15;
string lv_s16;
int lv_i17;
//----------
bool _orderOK;
long tmp_l1;
long tmp_l2;
int tmp_i3;
long tmp_l4;
long tmp_l5;
int tmp_i6;

lv_d1=g_zrMinDist/100.0+1.0;
if((!(AccountBalance()!=g_dailyStartBal)&&!(bParam0))) return;

if((!(AccountBalance()>g_dailyStartBal*lv_d1)&&!(AccountBalance()<g_dailyStartBal/lv_d1)&&!(bParam0))) return;
CalcLotSize(g_minProfitClose,g_strategyMask);
lv_i2=MT4OrdersTotal();
for(lv_i3=lv_i2;lv_i3>=0;lv_i3--)
{
if(OrderSelect(lv_i3,0,0)!=true||OrderMagicNumber()!=g_magicMain||OrderSymbol()!=g_tradeSymbol) continue;

if(OrderType()==4&&OrderLots()!=g_pairStratLots[g_pairIdx])
{
lv_d4=OrderStopLoss();
lv_l5=OrderTicket();
lv_d6=OrderTakeProfit();
lv_d7=OrderOpenPrice();
lv_dt8=OrderExpiration();
lv_s9=OrderComment();
_orderOK = OrderDelete((int)lv_l5,Red);
lv_i10=(int)OrderSend(g_tradeSymbol,OP_BUYSTOP,g_pairStratLots[g_pairIdx],lv_d7,(int)g_maxVolatility,lv_d4,lv_d6,lv_s9,g_magicMain,lv_dt8,Green);
tmp_l1=lv_i10;
tmp_l2=lv_l5;
for(tmp_i3=0;tmp_i3<100;tmp_i3=tmp_i3+1)
{
if(!(g_tradeStats[tmp_i3][0]==tmp_l2)) continue;
g_tradeStats[tmp_i3][0] = (double)(tmp_l1);
break;

}
Print("Lotsizechangedmorethan"+string(g_zrMinDist)+"%...adjustinglotsizeofpendingorders");
Sleep(1000);
}
if(OrderType()!=5||!(OrderLots()!=g_pairStratLots[g_pairIdx])) continue;
lv_d11=OrderStopLoss();
lv_l12=OrderTicket();
lv_d13=OrderTakeProfit();
lv_d14=OrderOpenPrice();
lv_dt15=OrderExpiration();
lv_s16=OrderComment();
_orderOK = OrderDelete((int)lv_l12,Red);
lv_i17=(int)OrderSend(g_tradeSymbol,OP_SELLSTOP,g_pairStratLots[g_pairIdx],lv_d14,(int)g_maxVolatility,lv_d11,lv_d13,lv_s16,g_magicMain,lv_dt15,Green);
tmp_l4=lv_i17;
tmp_l5=lv_l12;
for(tmp_i6=0;tmp_i6<100;tmp_i6=tmp_i6+1)
{
if(!(g_tradeStats[tmp_i6][0]==tmp_l5)) continue;
g_tradeStats[tmp_i6][0] = (double)(tmp_l4);
break;

}
Print("Lotsizechangedmorethan"+string(g_zrMinDist)+"%...adjustinglotsizeofpendingorders");
Sleep(1000);

}
}

void UpdateInfoPanel()
{
int lv_i1=0;
int lv_i2=0;
int lv_i3;
int lv_i4;
int lv_i5;
double lv_d6;
int lv_i7;
int lv_i8;
int lv_i9;
int lv_i10;
int lv_i11;
int lv_i12;
int lv_i13;
uint lv_u14;
bool lv_b15;
int lv_i16;
string lv_s17;
int lv_i18;
int lv_i19;
int lv_i20;
string lv_s21;
int lv_i22;
int lv_i23;
int lv_i24;
//----------

lv_i3=20;
lv_i4=300;
lv_i5=7;
lv_d6=InfoPanelSizeAdjust;
lv_i7=6;
lv_i8=4;
lv_i9=350;
lv_i10=350;
lv_i11=0;
lv_i12=5;
lv_i13=20;
lv_u14=LightSteelBlue;
lv_b15=false;
lv_i16=0;
if(g_useSymbolFilter)
{
lv_i16 = (int)((g_activePairs+3)*g_panelRowPx);
}
ObjectCreate(0,"infopanel_rectangle",OBJ_RECTANGLE_LABEL,0,0,0.0);
ObjectSetInteger(0,"infopanel_rectangle",OBJPROP_XDISTANCE,lv_i12);
ObjectSetInteger(0,"infopanel_rectangle",OBJPROP_YDISTANCE,lv_i13);
ObjectSetInteger(0,"infopanel_rectangle",OBJPROP_XSIZE,long(lv_i9*InfoPanelSizeAdjust));
ObjectSetInteger(0,"infopanel_rectangle",OBJPROP_YSIZE,long(lv_i10*InfoPanelSizeAdjust+lv_i16));
ObjectSetInteger(0,"infopanel_rectangle",OBJPROP_CORNER,0);
ObjectSetInteger(0,"infopanel_rectangle",OBJPROP_COLOR,C'0,0,255'/*Blue_BGR*/);
ObjectSetInteger(0,"infopanel_rectangle",OBJPROP_BGCOLOR,lv_u14);
ObjectSetInteger(0,"infopanel_rectangle",OBJPROP_BACK,0);
ObjectSetInteger(0,"infopanel_rectangle",OBJPROP_BORDER_COLOR,C'0,0,255'/*Blue_BGR*/);
ObjectSetInteger(0,"infopanel_rectangle",OBJPROP_COLOR,C'0,0,255'/*Blue_BGR*/);
ObjectSetInteger(0,"infopanel_rectangle",OBJPROP_BORDER_TYPE,0);
ObjectSetInteger(0,"infopanel_rectangle",OBJPROP_STYLE,0);
ObjectSetInteger(0,"infopanel_rectangle",OBJPROP_WIDTH,0x2);
ObjectSetInteger(0,"infopanel_rectangle",OBJPROP_SELECTABLE,0);
ObjectCreate(0,"line1",OBJ_LABEL,0,0,0.0);
ObjectSetInteger(0,"line1",OBJPROP_CORNER,lv_i11);
ObjectSetInteger(0,"line1",OBJPROP_YDISTANCE,lv_i13+lv_i8);
ObjectSetInteger(0,"line1",OBJPROP_XDISTANCE,lv_i12+lv_i7);
if(!(g_useSymbolFilter))
{
ObjectSetString(0,"line1",OBJPROP_TEXT,"The Gold Reaper V4.1");
}
else
{
ObjectSetString(0,"line1",OBJPROP_TEXT,"The Gold Reaper V4.1 - One Chart Setup");
}
ObjectSetInteger(0,"line1",OBJPROP_COLOR,g_panelFgColor);
ObjectCreate(0,"linec",OBJ_LABEL,0,0,0.0);
ObjectSetInteger(0,"linec",OBJPROP_CORNER,lv_i11);
ObjectSetInteger(0,"linec",OBJPROP_YDISTANCE,long(lv_i13+InfoPanelSizeAdjust*20.0+lv_i8));
ObjectSetInteger(0,"linec",OBJPROP_XDISTANCE,lv_i12+lv_i7);
ObjectSetString(0,"linec",OBJPROP_TEXT,"EA Developed by Wim Schrynemakers - 2024");
ObjectSetInteger(0,"linec",OBJPROP_COLOR,g_panelFgColor);
ObjectCreate(0,"line2",OBJ_LABEL,0,0,0.0);
ObjectSetInteger(0,"line2",OBJPROP_CORNER,lv_i11);
ObjectSetInteger(0,"line2",OBJPROP_YDISTANCE,long(lv_i13+InfoPanelSizeAdjust*32.0+lv_i8));
ObjectSetInteger(0,"line2",OBJPROP_XDISTANCE,lv_i12+lv_i7);
ObjectSetString(0,"line2",OBJPROP_TEXT,"------------------------------------------------------");
ObjectSetInteger(0,"line2",OBJPROP_COLOR,g_panelFgColor);
ObjectCreate(0,"lines",OBJ_LABEL,0,0,0.0);
ObjectSetInteger(0,"lines",OBJPROP_CORNER,lv_i11);
ObjectSetInteger(0,"lines",OBJPROP_YDISTANCE,long(lv_i13+InfoPanelSizeAdjust*44.0+lv_i8));
ObjectSetInteger(0,"lines",OBJPROP_XDISTANCE,lv_i12+lv_i7);
if(g_minBarsBetween==1)
{
lv_s17="conservative";
}
else
{
if(g_minBarsBetween==2)
{
lv_s17="moderate";
}
else
{
if(g_minBarsBetween==3)
{
lv_s17="Intense";
}
else
{
if(g_minBarsBetween==4)
{
lv_s17="extreme";
}
else
{
if(g_minBarsBetween==0)
{
lv_s17="extremeconservative";
}
else
{
lv_s17="manualstrategyselection";
}
}
}
}
}
ObjectSetString(0,"lines",OBJPROP_TEXT,"Trade Frequency: "+lv_s17);
ObjectSetInteger(0,"lines",OBJPROP_COLOR,g_panelFgColor);
if(Risk==1234)
{
ObjectCreate(0,"linet",OBJ_LABEL,0,0,0.0);
ObjectSetInteger(0,"linet",OBJPROP_CORNER,lv_i11);
ObjectSetInteger(0,"linet",OBJPROP_YDISTANCE,long(lv_i13+InfoPanelSizeAdjust*60.0+lv_i8));
ObjectSetInteger(0,"linet",OBJPROP_XDISTANCE,lv_i12+lv_i7);
ObjectSetString(0,"linet",OBJPROP_TEXT,"Max allowed DD: "+string(MaxAllowedDD)+"%");
ObjectSetInteger(0,"linet",OBJPROP_COLOR,g_panelFgColor);
}
else
{
if(Risk==3)
{
ObjectCreate(0,"linet",OBJ_LABEL,0,0,0.0);
ObjectSetInteger(0,"linet",OBJPROP_CORNER,lv_i11);
ObjectSetInteger(0,"linet",OBJPROP_YDISTANCE,long(lv_i13+InfoPanelSizeAdjust*60.0+lv_i8));
ObjectSetInteger(0,"linet",OBJPROP_XDISTANCE,lv_i12+lv_i7);
ObjectSetString(0,"linet",OBJPROP_TEXT,"Max risk per strategy: "+string(MaxRiskPerStrategy_)+"%");
ObjectSetInteger(0,"linet",OBJPROP_COLOR,g_panelFgColor);
}
else
{
ObjectCreate(0,"linet",OBJ_LABEL,0,0,0.0);
ObjectSetInteger(0,"linet",OBJPROP_CORNER,lv_i11);
ObjectSetInteger(0,"linet",OBJPROP_YDISTANCE,long(lv_i13+InfoPanelSizeAdjust*60.0+lv_i8));
ObjectSetInteger(0,"linet",OBJPROP_XDISTANCE,lv_i12+lv_i7);
ObjectSetString(0,"linet",OBJPROP_TEXT,"Manual lot size: "+string(g_startLots)+"lots");
ObjectSetInteger(0,"linet",OBJPROP_COLOR,g_panelFgColor);
}
}
ObjectCreate(0,"lineopl"+IntegerToString(0,0,32),OBJ_LABEL,0,0,0.0);
ObjectSetInteger(0,"lineopl"+IntegerToString(0,0,32),OBJPROP_CORNER,lv_i11);
ObjectSetInteger(0,"lineopl"+IntegerToString(0,0,32),OBJPROP_YDISTANCE,(int)(lv_i13+InfoPanelSizeAdjust*76.0+lv_i8));
ObjectSetInteger(0,"lineopl"+IntegerToString(0,0,32),OBJPROP_XDISTANCE,lv_i12+lv_i7);
ObjectSetString(0,"lineopl"+IntegerToString(0,0,32),OBJPROP_TEXT,"Open P/L: -");
ObjectSetInteger(0,"lineopl"+IntegerToString(0,0,32),OBJPROP_COLOR,g_panelFgColor);
ObjectCreate(0,"linea"+IntegerToString(0,0,32),OBJ_LABEL,0,0,0.0);
ObjectSetInteger(0,"linea"+IntegerToString(0,0,32),OBJPROP_CORNER,lv_i11);
ObjectSetInteger(0,"linea"+IntegerToString(0,0,32),OBJPROP_YDISTANCE,(int)(lv_i13+InfoPanelSizeAdjust*92.0+lv_i8));
ObjectSetInteger(0,"linea"+IntegerToString(0,0,32),OBJPROP_XDISTANCE,lv_i12+lv_i7);
ObjectSetString(0,"linea"+IntegerToString(0,0,32),OBJPROP_TEXT,"Account Balance: -");
ObjectSetInteger(0,"linea"+IntegerToString(0,0,32),OBJPROP_COLOR,g_panelFgColor);
ObjectCreate(0,"linetp"+IntegerToString(0,0,32),OBJ_LABEL,0,0,0.0);
ObjectSetInteger(0,"linetp"+IntegerToString(0,0,32),OBJPROP_CORNER,lv_i11);
ObjectSetInteger(0,"linetp"+IntegerToString(0,0,32),OBJPROP_YDISTANCE,(int)(lv_i13+InfoPanelSizeAdjust*108.0+lv_i8));
ObjectSetInteger(0,"linetp"+IntegerToString(0,0,32),OBJPROP_XDISTANCE,lv_i12+lv_i7);
ObjectSetString(0,"linetp"+IntegerToString(0,0,32),OBJPROP_TEXT,"Total P/L so far: -");
ObjectSetInteger(0,"linetp"+IntegerToString(0,0,32),OBJPROP_COLOR,g_panelFgColor);
lv_i18=0;
lv_i19=0;
lv_i20=0;
lv_i22=lv_i12+lv_i7;
lv_i23 = (int)(lv_i13+InfoPanelSizeAdjust*160.0+lv_i8);
lv_s21="Strategy";
CreateInfoLabel(lv_i22,lv_i23,0,"Strategy",0,0,1,0,1.0);
lv_i18=1;
lv_i19=1;
lv_s21="ClosedPL";
if(g_perfSortMode==1)
{
lv_s21="Closed PL*";
}
CreateInfoLabel(lv_i22,lv_i23,lv_i18,lv_s21,lv_i20,lv_i19,1,0,1.0);
lv_i18++;
lv_i19++;
lv_s21="PL per trade";
if(g_perfSortMode==2)
{
lv_s21="PLpertrade*";
}
CreateInfoLabel(lv_i22,lv_i23,lv_i18,lv_s21,lv_i20,lv_i19,1,0,1.0);
lv_i18++;
lv_i19++;
lv_s21="Lotsize";
CreateInfoLabel(lv_i22,lv_i23,lv_i18,"Lotsize",lv_i20,lv_i19,1,0,1.0);
lv_i18++;
lv_i19=0;
lv_i20++;
g_labelIdx=lv_i18;
for(lv_i24=0;lv_i24<9;lv_i24++)
{
lv_s21="Strategy"+IntegerToString(lv_i24+1,0,32);
CreateInfoLabel(lv_i22,lv_i23,lv_i18,lv_s21,lv_i20,lv_i19,1,0,1.0);
lv_i18++;
lv_i19++;
lv_s21=DoubleToString(NormalizeDouble(g_stratScores[lv_i24],2),2);
CreateInfoLabel(lv_i22,lv_i23,lv_i18,lv_s21,lv_i20,lv_i19,1,0,1.0);
lv_i18++;
lv_i19++;
lv_s21=DoubleToString(NormalizeDouble(g_pairBuyPrice[lv_i24],2),2);
CreateInfoLabel(lv_i22,lv_i23,lv_i18,lv_s21,lv_i20,lv_i19,1,0,1.0);
lv_i18++;
lv_i19++;
lv_s21=DoubleToString(NormalizeDouble(g_pairStratLots[lv_i24],2),2);
CreateInfoLabel(lv_i22,lv_i23,lv_i18,lv_s21,lv_i20,lv_i19,1,0,1.0);
lv_i18++;
lv_i19=0;
lv_i20++;
}
}
// UpdateInfoPanel<<==-------- --------
void CreateInfoLabel(int param0,int param1,int param2,string sParam3,int param4,int param5,int param6,uint colorParam,double dParam8)
{
ObjectCreate(0,"info_ea"+IntegerToString(param2,0,32),OBJ_EDIT,0,0,0.0);
ObjectSetInteger(0,"info_ea"+IntegerToString(param2,0,32),OBJPROP_XDISTANCE,(int)(param0+param5*g_panelColW));
ObjectSetInteger(0,"info_ea"+IntegerToString(param2,0,32),OBJPROP_YDISTANCE,(int)(param1+param4*g_panelRowPx));
ObjectSetString(0,"info_ea"+IntegerToString(param2,0,32),OBJPROP_TEXT,sParam3);
ObjectSetInteger(0,"info_ea"+IntegerToString(param2,0,32),OBJPROP_BACK,0);
ObjectSetInteger(0,"info_ea"+IntegerToString(param2,0,32),OBJPROP_COLOR,colorParam);
ObjectSetInteger(0,"info_ea"+IntegerToString(param2,0,32),OBJPROP_BGCOLOR,g_panelBgColor);
ObjectSetInteger(0,"info_ea"+IntegerToString(param2,0,32),OBJPROP_BORDER_COLOR,0);
ObjectSetInteger(0,"info_ea"+IntegerToString(param2,0,32),OBJPROP_FONTSIZE,(int)(g_panelFont*dParam8));
ObjectSetInteger(0,"info_ea"+IntegerToString(param2,0,32),OBJPROP_READONLY,0x1);
ObjectSetInteger(0,"info_ea"+IntegerToString(param2,0,32),OBJPROP_YSIZE,(int)(g_panelRowPx));
ObjectSetInteger(0,"info_ea"+IntegerToString(param2,0,32),OBJPROP_XSIZE,(int)(g_panelColW));
ObjectSetInteger(0,"info_ea"+IntegerToString(param2,0,32),OBJPROP_YSIZE,(int)(g_panelRowPx));
if(param6==0)
{
ObjectSetInteger(0,"info_ea"+IntegerToString(param2,0,32),OBJPROP_ALIGN,0x1);
}
if(param6==1)
{
ObjectSetInteger(0,"info_ea"+IntegerToString(param2,0,32),OBJPROP_ALIGN,0x2);
}
if(param6!=2) return;
ObjectSetInteger(0,"info_ea"+IntegerToString(param2,0,32),OBJPROP_ALIGN,0);
}
// CreateInfoLabel<<==-------- --------
void DeleteChartObjects()
{
int lv_i1;
int lv_i2;
int lv_i3;
int lv_i4;
//----------

ObjectDelete(0,"line1");
ObjectDelete(0,"linec");
ObjectDelete(0,"line2");
ObjectDelete(0,"lines");
ObjectDelete(0,"linet");
ObjectDelete(0,"line Trade Start");
for(lv_i1=0;lv_i1<=99;lv_i1++)
{
ObjectDelete(0,"lineopl"+IntegerToString(lv_i1,0,32));
ObjectDelete(0,"linea"+IntegerToString(lv_i1,0,32));
ObjectDelete(0,"lineto"+IntegerToString(lv_i1,0,32));
ObjectDelete(0,"linetp"+IntegerToString(lv_i1,0,32));
ObjectDelete(0,"linetq"+IntegerToString(lv_i1,0,32));
for(lv_i2=0;lv_i2<10;lv_i2++)
{
ObjectDelete(0,"tabel_info"+IntegerToString(lv_i1*100+lv_i2,0,32));
}
}
ObjectDelete(0,"infopanel_rectangle");
for(lv_i3=0;lv_i3<10;lv_i3++)
{
ObjectDelete(0,"tabel_heading"+IntegerToString(lv_i3,0,32));
ObjectDelete(0,"tabel_totals"+IntegerToString(lv_i3,0,32));
}
for(lv_i4=0;lv_i4<g_panelCols;lv_i4++)
{
ObjectDelete(0,"horizontalrect"+IntegerToString(lv_i4,0,32));
ObjectDelete(0,"info_ea"+IntegerToString(lv_i4,0,32));
}
}
// DeleteChartObjects<<==-------- --------
void DrawPanelBackground()
{
string errorStr;
//----------
double tmp_d1;
double tmp_d2;
int tmp_i3;
int tmp_i4;
int tmp_i5;
int tmp_i6;
int tmp_i7;
int tmp_i8;
int tmp_i9;
int tmp_i10;
int tmp_i11;
int tmp_i12;
int tmp_i13;
int tmp_i14;
int tmp_i15;
int tmp_i16;
int tmp_i17;
int tmp_i18;
int tmp_i19;

if(!(ShowInfoPanel)) return;

if((MQLInfoInteger(MQL_TESTER)==1&&!(UpdateInfoTesting))) return;

if(MQLInfoInteger(MQL_TESTER)==1&&!(UpdateInfoTesting))
{
tmp_d1=0.0;
}
else
{
tmp_d2=0.0;
for(tmp_i3=MT4OrdersTotal();tmp_i3>=0;tmp_i3=tmp_i3-1)
{
if(OrderSelect(tmp_i3,0,0)!=true) continue;

if((OrderSymbol()!=g_tradeSymbol&&!(g_useSymbolFilter))) continue;
tmp_i4=OrderMagicNumber();
tmp_i5=ST1_MagicNumber+1;
if(tmp_i4!=tmp_i5)
{
tmp_i5=OrderMagicNumber();
tmp_i6=ST1_MagicNumber+2;
if(tmp_i5!=tmp_i6)
{
tmp_i6=OrderMagicNumber();
tmp_i7=ST1_MagicNumber+3;
if(tmp_i6!=tmp_i7)
{
tmp_i7=OrderMagicNumber();
tmp_i8=ST1_MagicNumber+4;
if(tmp_i7!=tmp_i8)
{
tmp_i8=OrderMagicNumber();
tmp_i9=ST1_MagicNumber+5;
if(tmp_i8!=tmp_i9)
{
tmp_i9=OrderMagicNumber();
tmp_i10=ST1_MagicNumber+6;
if(tmp_i9!=tmp_i10)
{
tmp_i10=OrderMagicNumber();
tmp_i11=ST1_MagicNumber+7;
if(tmp_i10!=tmp_i11)
{
tmp_i11=OrderMagicNumber();
tmp_i12=ST1_MagicNumber+8;
if(tmp_i11!=tmp_i12)
{
tmp_i12=OrderMagicNumber();
tmp_i13=ST1_MagicNumber+9;
if(tmp_i12!=tmp_i13)
{
tmp_i13=OrderMagicNumber();
tmp_i14=ST1_MagicNumber+10;
if(tmp_i13!=tmp_i14)
{
tmp_i14=OrderMagicNumber();
tmp_i15=ST1_MagicNumber+11;
if(tmp_i14!=tmp_i15)
{
tmp_i15=OrderMagicNumber();
tmp_i16=ST1_MagicNumber+12;
if(tmp_i15!=tmp_i16)
{
tmp_i16=OrderMagicNumber();
tmp_i17=ST1_MagicNumber+13;
if(tmp_i16!=tmp_i17)
{
tmp_i17=OrderMagicNumber();
tmp_i18=ST1_MagicNumber+14;
if(tmp_i17!=tmp_i18)
{
tmp_i18=OrderMagicNumber();
tmp_i19=ST1_MagicNumber+15;
if(tmp_i18!=tmp_i19) continue;
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
if((OrderType()!=0&&OrderType()!=1)) continue;
tmp_d2=OrderProfit()+OrderSwap()+OrderCommission()+tmp_d2;

}
g_hlBuyBuffer[g_pairIdx]=tmp_d2;
tmp_d1=tmp_d2;
}
ObjectSetString(0,"lineopl"+IntegerToString(0,0,32),OBJPROP_TEXT,"Open P/L: "+DoubleToString(tmp_d1,2));
ObjectSetString(0,"linea"+IntegerToString(0,0,32),OBJPROP_TEXT,"Account Balance: "+DoubleToString(AccountBalance(),2));
if(g_minBarsBetween==1)
{
errorStr="conservative";
}
else
{
if(g_minBarsBetween==2)
{
errorStr="moderate";
}
else
{
if(g_minBarsBetween==3)
{
errorStr="Intense";
}
else
{
if(g_minBarsBetween==4)
{
errorStr="extreme";
}
else
{
if(g_minBarsBetween==0)
{
errorStr="extremeconservative";
}
else
{
errorStr="manualstrategyselection";
}
}
}
}
}
ObjectSetString(0,"lines",OBJPROP_TEXT,"Trade Frequency: "+errorStr);
if(Risk==1234)
{
ObjectSetString(0,"linet",OBJPROP_TEXT,"Max allowed DD: "+string(MaxAllowedDD)+"%");
}
else
{
if(Risk==3)
{
ObjectSetString(0,"linet",OBJPROP_TEXT,"Max risk per strategy: "+string(MaxRiskPerStrategy_)+"%");
}
else
{
ObjectSetString(0,"linet",OBJPROP_TEXT,"Manual lot size: "+string(g_startLots)+"lots");
}
}
}
// DrawPanelBackground<<==-------- --------
void UpdateStrategyStats()
{
int lv_i1;
string lv_s2;
int lv_i3;
//----------

if(!(ShowInfoPanel)) return;

if((MQLInfoInteger(MQL_TESTER)==1&&!(UpdateInfoTesting))) return;
lv_i1=g_labelIdx;
for(lv_i3=0;lv_i3<9;lv_i3++)
{
lv_s2="Strategy"+IntegerToString(lv_i3+1,0,32);
ObjectSetString(0,"info_ea"+IntegerToString(lv_i1,0,32),OBJPROP_TEXT,lv_s2);
lv_i1++;
lv_s2=DoubleToString(NormalizeDouble(g_stratScores[lv_i3],2),2);
ObjectSetString(0,"info_ea"+IntegerToString(lv_i1,0,32),OBJPROP_TEXT,lv_s2);
lv_i1++;
lv_s2=DoubleToString(NormalizeDouble(g_pairBuyPrice[lv_i3],2),2);
ObjectSetString(0,"info_ea"+IntegerToString(lv_i1,0,32),OBJPROP_TEXT,lv_s2);
lv_i1++;
lv_s2=DoubleToString(NormalizeDouble(g_pairStratLots[lv_i3],2),2);
ObjectSetString(0,"info_ea"+IntegerToString(lv_i1,0,32),OBJPROP_TEXT,lv_s2);
lv_i1++;
}
}
// UpdateStrategyStats<<==-------- --------
void DrawPanelDetails()
{
double tmp_d1;
double tmp_d2;
int tmp_i3;
int tmp_i4;
int tmp_i5;
int tmp_i6;
int tmp_i7;
int tmp_i8;
int tmp_i9;
int tmp_i10;
int tmp_i11;
int tmp_i12;
int tmp_i13;
int tmp_i14;
int tmp_i15;
int tmp_i16;
int tmp_i17;
int tmp_i18;
int tmp_i19;
int tmp_i20;

if(!(ShowInfoPanel)) return;

if((MQLInfoInteger(MQL_TESTER)==1&&!(UpdateInfoTesting))) return;
ObjectSetString(0,"lineto"+IntegerToString(0,0,32),OBJPROP_TEXT,"Total profits/losses so far: "+IntegerToString(CountBuyOrders(0,9999999),0,32)+"/"+IntegerToString(CountSellOrders(0,9999999),0,32));
if(MQLInfoInteger(MQL_TESTER)==1&&!(UpdateInfoTesting))
{
tmp_d1=0.0;
}
else
{
tmp_d2=0.0;
tmp_i3=0;
for(tmp_i4=HistoryTotal();tmp_i4>=0;tmp_i4=tmp_i4-1)
{
if(OrderSelect(tmp_i4,0,1)!=true) continue;

if((OrderSymbol()!=g_tradeSymbol&&!(g_useSymbolFilter))) continue;
tmp_i5=OrderMagicNumber();
tmp_i6=ST1_MagicNumber+1;
if(tmp_i5!=tmp_i6)
{
tmp_i6=OrderMagicNumber();
tmp_i7=ST1_MagicNumber+2;
if(tmp_i6!=tmp_i7)
{
tmp_i7=OrderMagicNumber();
tmp_i8=ST1_MagicNumber+3;
if(tmp_i7!=tmp_i8)
{
tmp_i8=OrderMagicNumber();
tmp_i9=ST1_MagicNumber+4;
if(tmp_i8!=tmp_i9)
{
tmp_i9=OrderMagicNumber();
tmp_i10=ST1_MagicNumber+5;
if(tmp_i9!=tmp_i10)
{
tmp_i10=OrderMagicNumber();
tmp_i11=ST1_MagicNumber+6;
if(tmp_i10!=tmp_i11)
{
tmp_i11=OrderMagicNumber();
tmp_i12=ST1_MagicNumber+7;
if(tmp_i11!=tmp_i12)
{
tmp_i12=OrderMagicNumber();
tmp_i13=ST1_MagicNumber+8;
if(tmp_i12!=tmp_i13)
{
tmp_i13=OrderMagicNumber();
tmp_i14=ST1_MagicNumber+9;
if(tmp_i13!=tmp_i14)
{
tmp_i14=OrderMagicNumber();
tmp_i15=ST1_MagicNumber+10;
if(tmp_i14!=tmp_i15)
{
tmp_i15=OrderMagicNumber();
tmp_i16=ST1_MagicNumber+11;
if(tmp_i15!=tmp_i16)
{
tmp_i16=OrderMagicNumber();
tmp_i17=ST1_MagicNumber+12;
if(tmp_i16!=tmp_i17)
{
tmp_i17=OrderMagicNumber();
tmp_i18=ST1_MagicNumber+13;
if(tmp_i17!=tmp_i18)
{
tmp_i18=OrderMagicNumber();
tmp_i19=ST1_MagicNumber+14;
if(tmp_i18!=tmp_i19)
{
tmp_i19=OrderMagicNumber();
tmp_i20=ST1_MagicNumber+15;
if(tmp_i19!=tmp_i20) continue;
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
tmp_i3=tmp_i3+1;
tmp_d2=tmp_d2+OrderProfit()+OrderSwap()+OrderCommission();
if(tmp_i3>=1000) break;

}
g_magicSellBuffer[g_pairIdx]=tmp_d2;
tmp_d1=tmp_d2;
}
ObjectSetString(0,"linetp"+IntegerToString(0,0,32),OBJPROP_TEXT,"Total P/L so far: "+DoubleToString(NormalizeDouble(tmp_d1,2),2));
}
// DrawPanelDetails<<==-------- --------
int CountBuyOrders(int param0,int param1)
{
double lv_d2;
int lv_i3;
int lv_i4;
int lv_i5;
//----------
int tmp_i1;
int tmp_i2;
int tmp_i3;
int tmp_i4;
int tmp_i5;
int tmp_i6;
int tmp_i7;
int tmp_i8;
int tmp_i9;
int tmp_i10;
int tmp_i11;
int tmp_i12;
int tmp_i13;
int tmp_i14;
int tmp_i15;
int tmp_i16;

if(MQLInfoInteger(MQL_TESTER)==1&&!(UpdateInfoTesting))
{
return(0);
}
lv_d2=0.0;
lv_i3=0;
lv_i4=0;
for(lv_i5=HistoryTotal();lv_i5>=0;lv_i5--)
{
if(OrderSelect(lv_i5,0,1)!=true) continue;

if((OrderSymbol()!=g_tradeSymbol&&!(g_useSymbolFilter))) continue;
tmp_i1=OrderMagicNumber();
tmp_i2=ST1_MagicNumber+1;
if(tmp_i1!=tmp_i2)
{
tmp_i2=OrderMagicNumber();
tmp_i3=ST1_MagicNumber+2;
if(tmp_i2!=tmp_i3)
{
tmp_i3=OrderMagicNumber();
tmp_i4=ST1_MagicNumber+3;
if(tmp_i3!=tmp_i4)
{
tmp_i4=OrderMagicNumber();
tmp_i5=ST1_MagicNumber+4;
if(tmp_i4!=tmp_i5)
{
tmp_i5=OrderMagicNumber();
tmp_i6=ST1_MagicNumber+5;
if(tmp_i5!=tmp_i6)
{
tmp_i6=OrderMagicNumber();
tmp_i7=ST1_MagicNumber+6;
if(tmp_i6!=tmp_i7)
{
tmp_i7=OrderMagicNumber();
tmp_i8=ST1_MagicNumber+7;
if(tmp_i7!=tmp_i8)
{
tmp_i8=OrderMagicNumber();
tmp_i9=ST1_MagicNumber+8;
if(tmp_i8!=tmp_i9)
{
tmp_i9=OrderMagicNumber();
tmp_i10=ST1_MagicNumber+9;
if(tmp_i9!=tmp_i10)
{
tmp_i10=OrderMagicNumber();
tmp_i11=ST1_MagicNumber+10;
if(tmp_i10!=tmp_i11)
{
tmp_i11=OrderMagicNumber();
tmp_i12=ST1_MagicNumber+11;
if(tmp_i11!=tmp_i12)
{
tmp_i12=OrderMagicNumber();
tmp_i13=ST1_MagicNumber+12;
if(tmp_i12!=tmp_i13)
{
tmp_i13=OrderMagicNumber();
tmp_i14=ST1_MagicNumber+13;
if(tmp_i13!=tmp_i14)
{
tmp_i14=OrderMagicNumber();
tmp_i15=ST1_MagicNumber+14;
if(tmp_i14!=tmp_i15)
{
tmp_i15=OrderMagicNumber();
tmp_i16=ST1_MagicNumber+15;
if(tmp_i15!=tmp_i16) continue;
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
lv_i3++;
if((OrderType()==0||OrderType()==1))
{
if(OrderType()==0)
{
lv_d2=OrderClosePrice()-OrderOpenPrice();
}
else
{
if(OrderType()==1)
{
lv_d2=OrderOpenPrice()-OrderClosePrice();
}
}
if(lv_d2>0.0)
{
lv_i4++;
}
}
if(lv_i3>=param1) break;

}
g_hlSellBuffer[g_pairIdx]=lv_i4;
return(lv_i4);
}
// CountBuyOrders<<==-------- --------
int CountSellOrders(int param0,int param1)
{
double lv_d2;
int lv_i3;
int lv_i4;
int lv_i5;
//----------
int tmp_i1;
int tmp_i2;
int tmp_i3;
int tmp_i4;
int tmp_i5;
int tmp_i6;
int tmp_i7;
int tmp_i8;
int tmp_i9;
int tmp_i10;
int tmp_i11;
int tmp_i12;
int tmp_i13;
int tmp_i14;
int tmp_i15;
int tmp_i16;

if(MQLInfoInteger(MQL_TESTER)==1&&!(UpdateInfoTesting))
{
return(0);
}
lv_d2=0.0;
lv_i3=0;
lv_i4=0;
for(lv_i5=HistoryTotal();lv_i5>=0;lv_i5--)
{
if(OrderSelect(lv_i5,0,1)!=true) continue;

if((OrderSymbol()!=g_tradeSymbol&&!(g_useSymbolFilter))) continue;
tmp_i1=OrderMagicNumber();
tmp_i2=ST1_MagicNumber+1;
if(tmp_i1!=tmp_i2)
{
tmp_i2=OrderMagicNumber();
tmp_i3=ST1_MagicNumber+2;
if(tmp_i2!=tmp_i3)
{
tmp_i3=OrderMagicNumber();
tmp_i4=ST1_MagicNumber+3;
if(tmp_i3!=tmp_i4)
{
tmp_i4=OrderMagicNumber();
tmp_i5=ST1_MagicNumber+4;
if(tmp_i4!=tmp_i5)
{
tmp_i5=OrderMagicNumber();
tmp_i6=ST1_MagicNumber+5;
if(tmp_i5!=tmp_i6)
{
tmp_i6=OrderMagicNumber();
tmp_i7=ST1_MagicNumber+6;
if(tmp_i6!=tmp_i7)
{
tmp_i7=OrderMagicNumber();
tmp_i8=ST1_MagicNumber+7;
if(tmp_i7!=tmp_i8)
{
tmp_i8=OrderMagicNumber();
tmp_i9=ST1_MagicNumber+8;
if(tmp_i8!=tmp_i9)
{
tmp_i9=OrderMagicNumber();
tmp_i10=ST1_MagicNumber+9;
if(tmp_i9!=tmp_i10)
{
tmp_i10=OrderMagicNumber();
tmp_i11=ST1_MagicNumber+10;
if(tmp_i10!=tmp_i11)
{
tmp_i11=OrderMagicNumber();
tmp_i12=ST1_MagicNumber+11;
if(tmp_i11!=tmp_i12)
{
tmp_i12=OrderMagicNumber();
tmp_i13=ST1_MagicNumber+12;
if(tmp_i12!=tmp_i13)
{
tmp_i13=OrderMagicNumber();
tmp_i14=ST1_MagicNumber+13;
if(tmp_i13!=tmp_i14)
{
tmp_i14=OrderMagicNumber();
tmp_i15=ST1_MagicNumber+14;
if(tmp_i14!=tmp_i15)
{
tmp_i15=OrderMagicNumber();
tmp_i16=ST1_MagicNumber+15;
if(tmp_i15!=tmp_i16) continue;
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
lv_i3++;
if(OrderType()==0)
{
lv_d2=OrderClosePrice()-OrderOpenPrice();
}
else
{
if(OrderType()==1)
{
lv_d2=OrderOpenPrice()-OrderClosePrice();
}
}
if(lv_d2<0.0)
{
lv_i4++;
}
if(lv_i3>=param1) break;

}
g_magicBuyBuffer[g_pairIdx]=lv_i4;
return(lv_i4);
}
// CountSellOrders<<==-------- --------
void ScanAllOrders()
{
int lv_i1=0;
double lv_d2[99]={};
double lv_d3[99]={};
int lv_i4;
int lv_i5;
bool lv_b6;
int lv_i7;
double lv_d8;
int lv_i9;
int lv_i10;
//----------
long tmp_l1;
long tmp_l2;
long tmp_l3;
long tmp_l4;
long tmp_l5;

if((MQLInfoInteger(MQL_TESTER)==1&&!(UpdateInfoTesting))) return;
for(lv_i4=0;lv_i4<g_activePairs;lv_i4++)
{
lv_d2[lv_i4]=0.0;
lv_d3[lv_i4]=0.0;
g_pairActive[lv_i4]=false;
g_pairBuyOpen[lv_i4]=0;
g_pairSellOpen[lv_i4]=0;
}
for(lv_i5=HistoryTotal();lv_i5>=0;lv_i5--)
{
if(OrderSelect(lv_i5,0,1)!=true||OrderMagicNumber()!=g_magicMain) continue;
lv_b6=true;
for(lv_i7=0;lv_i7<g_activePairs;lv_i7++)
{
if(!(g_pairActive[lv_i7]))
{
lv_b6=false;
}
}
if((OrderCloseTime()< TimeCurrent()-g_perfReduction1*24*60*60&&lv_b6)) break;
lv_d8=OrderLots()*100.0;
if(g_perfRankMode==1)
{
lv_d8=1.0;
}
lv_i9=0;
if(g_activePairs<=0) continue;

for(;lv_i9<g_activePairs;lv_i9++)
{
if(g_pairNames[lv_i9]!=OrderSymbol()) continue;

if((OrderType()!=0&&OrderType()!=1)) continue;
tmp_l1=OrderCloseTime();
tmp_l2=TimeCurrent()-g_perfReduction1*24*60*60;
if(tmp_l1< tmp_l2)
{
tmp_l2=OrderCloseTime();
tmp_l3=TimeCurrent()-g_perfReduction1*24*60*60;
if((tmp_l2>=tmp_l3||g_pairActive[lv_i9])) continue;
}
g_pairBuyOpen[lv_i9]++;
if(g_pairBuyOpen[lv_i9]>=g_perfMinTrades)
{
g_pairActive[lv_i9]=true;
}
lv_d2[lv_i9]+=OrderProfit()/lv_d8;
lv_d2[lv_i9]+=OrderSwap()/lv_d8;
lv_d2[lv_i9]+=OrderCommission()/lv_d8;
tmp_l4=OrderCloseTime();
tmp_l5=TimeCurrent()-g_perfReduction2*24*60*60;
if(tmp_l4<tmp_l5) continue;
lv_d3[lv_i9]+=OrderProfit()/lv_d8;
lv_d3[lv_i9]+=OrderSwap()/lv_d8;
lv_d3[lv_i9]+=OrderCommission()/lv_d8;
g_pairSellOpen[lv_i9]++;

}

}
for(lv_i10=0;lv_i10<g_activePairs;lv_i10++)
{
g_pairBuySL[lv_i10]=lv_d2[lv_i10];
if(g_pairBuyOpen[lv_i10]> 0)
{
g_pairBuyPrice[lv_i10]=NormalizeDouble(lv_d2[lv_i10]/g_pairBuyOpen[lv_i10],2);
}
else
{
g_pairBuyPrice[lv_i10]=0.0;
}
g_pairSellSL[lv_i10]=lv_d3[lv_i10];
if(g_pairSellOpen[lv_i10]> 0)
{
g_pairSellPrice[lv_i10]=NormalizeDouble(lv_d3[lv_i10]/g_pairSellOpen[lv_i10],2);
}
else
{
g_pairSellPrice[lv_i10]=0.0;
}
}
}
// ScanAllOrders<<==-------- --------
void ProcessBuyStrategies()
{
int lv_i1;
double lv_d2;
int lv_i3;
int lv_i4;
int lv_i5;
int lv_i6;
bool lv_b7;
int lv_i8;
int lv_i9;
int lv_i10;
int lv_i11;
//----------

ScanAllOrders();
for(lv_i1=0;lv_i1<g_activePairs;lv_i1++)
{
lv_d2=g_pairBuySL[lv_i1];
lv_i3=1;
for(lv_i4=0;lv_i4<g_activePairs;lv_i4++)
{
if(lv_i4==lv_i1||!(g_pairBuySL[lv_i4]>lv_d2)) continue;
lv_i3++;

}
g_pairBarCount[lv_i1]=lv_i3;
}
for(lv_i5=0;lv_i5<g_activePairs;lv_i5++)
{
lv_i6=g_pairBarCount[lv_i5];
lv_b7=true;
do
{
lv_b7=false;
lv_i8=0;
if(g_activePairs<=0) continue;

for(;lv_i8<g_activePairs;lv_i8++)
{
if(lv_i8==lv_i5||g_pairBarCount[lv_i8]!=g_pairBarCount[lv_i5]) continue;
g_pairBarCount[lv_i8]++;
lv_b7=true;

}

}
while(lv_b7);

}
for(lv_i9=0;lv_i9<g_activePairs;lv_i9++)
{
g_pairSellLots[lv_i9]=1.0;
}
for(lv_i10=1;lv_i10<=g_activePairs;lv_i10++)
{
for(lv_i11=0;lv_i11<g_activePairs;lv_i11++)
{
if(g_pairBarCount[lv_i11]==lv_i10)
{
g_stratMagics[lv_i10-1]=lv_i11;
}
}
}
}
// ProcessBuyStrategies<<==-------- --------
void ProcessSellStrategies()
{
int lv_i1;
double lv_d2;
int lv_i3;
int lv_i4;
int lv_i5;
int lv_i6;
bool lv_b7;
int lv_i8;
int lv_i9;
int lv_i10;
int lv_i11;
//----------

ScanAllOrders();
for(lv_i1=0;lv_i1<g_activePairs;lv_i1++)
{
lv_d2=g_pairBuyPrice[lv_i1];
lv_i3=1;
for(lv_i4=0;lv_i4<g_activePairs;lv_i4++)
{
if(lv_i4==lv_i1||!(g_pairBuyPrice[lv_i4]>lv_d2)) continue;
lv_i3++;

}
g_pairBarCount[lv_i1]=lv_i3;
}
for(lv_i5=0;lv_i5<g_activePairs;lv_i5++)
{
lv_i6=g_pairBarCount[lv_i5];
lv_b7=true;
do
{
lv_b7=false;
lv_i8=0;
if(g_activePairs<=0) continue;

for(;lv_i8<g_activePairs;lv_i8++)
{
if(lv_i8==lv_i5||g_pairBarCount[lv_i8]!=g_pairBarCount[lv_i5]) continue;
g_pairBarCount[lv_i8]++;
lv_b7=true;

}

}
while(lv_b7);

}
for(lv_i9=0;lv_i9<g_activePairs;lv_i9++)
{
g_pairSellLots[lv_i9]=1.0;
}
for(lv_i10=1;lv_i10<=g_activePairs;lv_i10++)
{
for(lv_i11=0;lv_i11<g_activePairs;lv_i11++)
{
if(g_pairBarCount[lv_i11]==lv_i10)
{
g_stratMagics[lv_i10-1]=lv_i11;
}
}
}
}
// ProcessSellStrategies<<==-------- --------
double ConvertToUSD_Old(double dParam0)
{
double lv_d2;
string lv_s3;
//----------

lv_d2=dParam0;
if((AccountCurrency()=="USD"||AccountCurrency()=="usd"))
{
lv_d2=dParam0;
}
if((AccountCurrency()=="EUR"||AccountCurrency()=="eur"))
{
lv_s3="EURUSD"+g_symbolSuffix;
if(iClose(lv_s3,MT4Period(PERIOD_D1),1)>0.0)
{
lv_d2=dParam0/iClose(lv_s3,MT4Period(PERIOD_D1),1);
}
}
if((AccountCurrency()=="GBP"||AccountCurrency()=="gbp"))
{
lv_s3="GBPUSD"+g_symbolSuffix;
if(iClose(lv_s3,MT4Period(PERIOD_D1),1)>0.0)
{
lv_d2=dParam0/iClose(lv_s3,MT4Period(PERIOD_D1),1);
}
}
if((AccountCurrency()=="AUD"||AccountCurrency()=="aud"))
{
lv_s3="AUDUSD"+g_symbolSuffix;
if(iClose(lv_s3,MT4Period(PERIOD_D1),1)>0.0)
{
lv_d2=dParam0/iClose(lv_s3,MT4Period(PERIOD_D1),1);
}
}
if((AccountCurrency()=="JPY"||AccountCurrency()=="jpy"||AccountCurrency()=="YEN"||AccountCurrency()=="yen"))
{
lv_s3="USDJPY"+g_symbolSuffix;
if(iClose(lv_s3,MT4Period(PERIOD_D1),1)>0.0)
{
lv_d2=dParam0*iClose(lv_s3,MT4Period(PERIOD_D1),1);
}
}
if((AccountCurrency()=="CHF"||AccountCurrency()=="chf"))
{
lv_s3="USDCHF"+g_symbolSuffix;
if(iClose(lv_s3,MT4Period(PERIOD_D1),1)>0.0)
{
lv_d2=dParam0*iClose(lv_s3,MT4Period(PERIOD_D1),1);
}
}
if((AccountCurrency()=="HKD"||AccountCurrency()=="hkd"))
{
lv_s3="USDHKD"+g_symbolSuffix;
if(iClose(lv_s3,MT4Period(PERIOD_D1),1)>0.0)
{
lv_d2=dParam0*iClose(lv_s3,MT4Period(PERIOD_D1),1);
}
}
if((AccountCurrency()=="SGD"||AccountCurrency()=="sgd"))
{
lv_s3="USDSGD"+g_symbolSuffix;
if(iClose(lv_s3,MT4Period(PERIOD_D1),1)>0.0)
{
lv_d2=dParam0*iClose(lv_s3,MT4Period(PERIOD_D1),1);
}
}
if((AccountCurrency()=="PLN"||AccountCurrency()=="pln"))
{
lv_s3="USDPLN"+g_symbolSuffix;
if(iClose(lv_s3,MT4Period(PERIOD_D1),1)>0.0)
{
lv_d2=dParam0*iClose(lv_s3,MT4Period(PERIOD_D1),1);
}
}
if((AccountCurrency()=="RUB"||AccountCurrency()=="rub"))
{
lv_s3="USDRUB"+g_symbolSuffix;
if(iClose(lv_s3,MT4Period(PERIOD_D1),1)>0.0)
{
lv_d2=dParam0*iClose(lv_s3,MT4Period(PERIOD_D1),1);
}
}
if((AccountCurrency()=="BTC"||AccountCurrency()=="btc"))
{
lv_s3="BTCUSD"+g_symbolSuffix;
if(iClose(lv_s3,MT4Period(PERIOD_D1),1)>0.0)
{
lv_d2=dParam0/iClose(lv_s3,MT4Period(PERIOD_D1),1);
}
}
if((AccountCurrency()=="ETH"||AccountCurrency()=="eth"))
{
lv_s3="ETHUSD"+g_symbolSuffix;
if(iClose(lv_s3,MT4Period(PERIOD_D1),1)>0.0)
{
lv_d2=dParam0/iClose(lv_s3,MT4Period(PERIOD_D1),1);
}
}
if((AccountCurrency()=="BCH"||AccountCurrency()=="bch"))
{
lv_s3="BCHUSD"+g_symbolSuffix;
if(iClose(lv_s3,MT4Period(PERIOD_D1),1)>0.0)
{
lv_d2=dParam0/iClose(lv_s3,MT4Period(PERIOD_D1),1);
}
}
if((AccountCurrency()=="BCC"||AccountCurrency()=="bcc"))
{
lv_s3="BCCUSD"+g_symbolSuffix;
if(iClose(lv_s3,MT4Period(PERIOD_D1),1)>0.0)
{
lv_d2=dParam0/iClose(lv_s3,MT4Period(PERIOD_D1),1);
}
}
if((AccountCurrency()=="XRP"||AccountCurrency()=="xrp"))
{
lv_s3="XRPUSD"+g_symbolSuffix;
if(iClose(lv_s3,MT4Period(PERIOD_D1),1)>0.0)
{
lv_d2=dParam0/iClose(lv_s3,MT4Period(PERIOD_D1),1);
}
}
if((AccountCurrency()=="LTC"||AccountCurrency()=="ltc"))
{
lv_s3="LTCUSD"+g_symbolSuffix;
if(iClose(lv_s3,MT4Period(PERIOD_D1),1)>0.0)
{
lv_d2=dParam0/iClose(lv_s3,MT4Period(PERIOD_D1),1);
}
}
if((AccountCurrency()=="XMR"||AccountCurrency()=="xmr"))
{
lv_s3="XMRUSD"+g_symbolSuffix;
if(iClose(lv_s3,MT4Period(PERIOD_D1),1)>0.0)
{
lv_d2=dParam0/iClose(lv_s3,MT4Period(PERIOD_D1),1);
}
}
if((AccountCurrency()=="DSH"||AccountCurrency()=="dsh"))
{
lv_s3="DSHUSD"+g_symbolSuffix;
if(iClose(lv_s3,MT4Period(PERIOD_D1),1)>0.0)
{
lv_d2=dParam0/iClose(lv_s3,MT4Period(PERIOD_D1),1);
}
}
if((AccountCurrency()=="EOS"||AccountCurrency()=="eos"))
{
lv_s3="EOSUSD"+g_symbolSuffix;
if(iClose(lv_s3,MT4Period(PERIOD_D1),1)>0.0)
{
lv_d2=dParam0/iClose(lv_s3,MT4Period(PERIOD_D1),1);
}
}
if((AccountCurrency()=="TRX"||AccountCurrency()=="trx"))
{
lv_s3="TRXUSD"+g_symbolSuffix;
if(iClose(lv_s3,MT4Period(PERIOD_D1),1)>0.0)
{
lv_d2=dParam0/iClose(lv_s3,MT4Period(PERIOD_D1),1);
}
}
if((AccountCurrency()=="ADA"||AccountCurrency()=="ada"))
{
lv_s3="ADAUSD"+g_symbolSuffix;
if(iClose(lv_s3,MT4Period(PERIOD_D1),1)>0.0)
{
lv_d2=dParam0/iClose(lv_s3,MT4Period(PERIOD_D1),1);
}
}
if((AccountCurrency()=="BSV"||AccountCurrency()=="bsv"))
{
lv_s3="BSVUSD"+g_symbolSuffix;
if(iClose(lv_s3,MT4Period(PERIOD_D1),1)>0.0)
{
lv_d2=dParam0/iClose(lv_s3,MT4Period(PERIOD_D1),1);
}
}
if((AccountCurrency()=="XLM"||AccountCurrency()=="xlm"))
{
lv_s3="XLMUSD"+g_symbolSuffix;
if(iClose(lv_s3,MT4Period(PERIOD_D1),1)>0.0)
{
lv_d2=dParam0/iClose(lv_s3,MT4Period(PERIOD_D1),1);
}
}
if((AccountCurrency()=="GLD"||AccountCurrency()=="gld"))
{
lv_s3="GLDUSD"+g_symbolSuffix;
if(iClose(lv_s3,MT4Period(PERIOD_D1),1)>0.0)
{
lv_d2=dParam0/iClose(lv_s3,MT4Period(PERIOD_D1),1);
}
}
if((AccountCurrency()=="ZEC"||AccountCurrency()=="zec"))
{
lv_s3="ZECUSD"+g_symbolSuffix;
if(iClose(lv_s3,MT4Period(PERIOD_D1),1)>0.0)
{
lv_d2=dParam0/iClose(lv_s3,MT4Period(PERIOD_D1),1);
}
}
if((AccountCurrency()=="XEM"||AccountCurrency()=="xem"))
{
lv_s3="XEMUSD"+g_symbolSuffix;
if(iClose(lv_s3,MT4Period(PERIOD_D1),1)>0.0)
{
lv_d2=dParam0/iClose(lv_s3,MT4Period(PERIOD_D1),1);
}
}
return(lv_d2);
}
// ConvertToUSD_Old<<==-------- --------
double ConvertToUSD(double dParam0)
{
double lv_d2;
string lv_s3;
//----------

lv_d2=dParam0;
if((AccountInfoString(ACCOUNT_CURRENCY)=="USD"||AccountInfoString(ACCOUNT_CURRENCY)=="usd"))
{
lv_d2=dParam0;
}
if((AccountInfoString(ACCOUNT_CURRENCY)=="EUR"||AccountInfoString(ACCOUNT_CURRENCY)=="eur"))
{
lv_s3="EURUSD"+g_symbolSuffix;
if(iClose(lv_s3,MT4Period(PERIOD_D1),1)>0.0)
{
lv_d2=dParam0*iClose(lv_s3,MT4Period(PERIOD_D1),1);
}
}
if((AccountInfoString(ACCOUNT_CURRENCY)=="GBP"||AccountInfoString(ACCOUNT_CURRENCY)=="gbp"))
{
lv_s3="GBPUSD"+g_symbolSuffix;
if(iClose(lv_s3,MT4Period(PERIOD_D1),1)>0.0)
{
lv_d2=dParam0*iClose(lv_s3,MT4Period(PERIOD_D1),1);
}
}
if((AccountInfoString(ACCOUNT_CURRENCY)=="AUD"||AccountInfoString(ACCOUNT_CURRENCY)=="aud"))
{
lv_s3="AUDUSD"+g_symbolSuffix;
if(iClose(lv_s3,MT4Period(PERIOD_D1),1)>0.0)
{
lv_d2=dParam0*iClose(lv_s3,MT4Period(PERIOD_D1),1);
}
}
if((AccountInfoString(ACCOUNT_CURRENCY)=="JPY"||AccountInfoString(ACCOUNT_CURRENCY)=="jpy"||AccountInfoString(ACCOUNT_CURRENCY)=="YEN"||AccountInfoString(ACCOUNT_CURRENCY)=="yen"))
{
lv_s3="USDJPY"+g_symbolSuffix;
if(iClose(lv_s3,MT4Period(PERIOD_D1),1)>0.0)
{
lv_d2=dParam0/iClose(lv_s3,MT4Period(PERIOD_D1),1);
}
}
if((AccountInfoString(ACCOUNT_CURRENCY)=="CHF"||AccountInfoString(ACCOUNT_CURRENCY)=="chf"))
{
lv_s3="USDCHF"+g_symbolSuffix;
if(iClose(lv_s3,MT4Period(PERIOD_D1),1)>0.0)
{
lv_d2=dParam0/iClose(lv_s3,MT4Period(PERIOD_D1),1);
}
}
if((AccountInfoString(ACCOUNT_CURRENCY)=="HKD"||AccountInfoString(ACCOUNT_CURRENCY)=="hkd"))
{
lv_s3="USDHKD"+g_symbolSuffix;
if(iClose(lv_s3,MT4Period(PERIOD_D1),1)>0.0)
{
lv_d2=dParam0/iClose(lv_s3,MT4Period(PERIOD_D1),1);
}
}
if((AccountInfoString(ACCOUNT_CURRENCY)=="RUB"||AccountInfoString(ACCOUNT_CURRENCY)=="rub"))
{
lv_s3="USDRUB"+g_symbolSuffix;
if(iClose(lv_s3,MT4Period(PERIOD_D1),1)>0.0)
{
lv_d2=dParam0/iClose(lv_s3,MT4Period(PERIOD_D1),1);
}
}
if((AccountInfoString(ACCOUNT_CURRENCY)=="CNH"||AccountInfoString(ACCOUNT_CURRENCY)=="cnh"))
{
lv_s3="USDCNH"+g_symbolSuffix;
if(iClose(lv_s3,MT4Period(PERIOD_D1),1)>0.0)
{
lv_d2=dParam0/iClose(lv_s3,MT4Period(PERIOD_D1),1);
}
else
{
lv_s3="USDCNY"+g_symbolSuffix;
if(iClose(lv_s3,MT4Period(PERIOD_D1),1)>0.0)
{
lv_d2=dParam0/iClose(lv_s3,MT4Period(PERIOD_D1),1);
}
}
}
if((AccountInfoString(ACCOUNT_CURRENCY)=="CNY"||AccountInfoString(ACCOUNT_CURRENCY)=="cny"))
{
lv_s3="USDCNH"+g_symbolSuffix;
if(iClose(lv_s3,MT4Period(PERIOD_D1),1)>0.0)
{
lv_d2=dParam0/iClose(lv_s3,MT4Period(PERIOD_D1),1);
}
else
{
lv_s3="USDCNY"+g_symbolSuffix;
if(iClose(lv_s3,MT4Period(PERIOD_D1),1)>0.0)
{
lv_d2=dParam0/iClose(lv_s3,MT4Period(PERIOD_D1),1);
}
}
}
if((AccountInfoString(ACCOUNT_CURRENCY)=="SGD"||AccountInfoString(ACCOUNT_CURRENCY)=="sgd"))
{
lv_s3="USDSGD"+g_symbolSuffix;
if(iClose(lv_s3,MT4Period(PERIOD_D1),1)>0.0)
{
lv_d2=dParam0/iClose(lv_s3,MT4Period(PERIOD_D1),1);
}
}
if((AccountInfoString(ACCOUNT_CURRENCY)=="BTC"||AccountInfoString(ACCOUNT_CURRENCY)=="btc"))
{
lv_s3="BTCUSD"+g_symbolSuffix;
if(iClose(lv_s3,MT4Period(PERIOD_D1),1)>0.0)
{
lv_d2=dParam0*iClose(lv_s3,MT4Period(PERIOD_D1),1);
}
}
if((AccountInfoString(ACCOUNT_CURRENCY)=="ETH"||AccountInfoString(ACCOUNT_CURRENCY)=="eth"))
{
lv_s3="ETHUSD"+g_symbolSuffix;
if(iClose(lv_s3,MT4Period(PERIOD_D1),1)>0.0)
{
lv_d2=dParam0*iClose(lv_s3,MT4Period(PERIOD_D1),1);
}
}
if((AccountInfoString(ACCOUNT_CURRENCY)=="BCH"||AccountInfoString(ACCOUNT_CURRENCY)=="bch"))
{
lv_s3="BCHUSD"+g_symbolSuffix;
if(iClose(lv_s3,MT4Period(PERIOD_D1),1)>0.0)
{
lv_d2=dParam0*iClose(lv_s3,MT4Period(PERIOD_D1),1);
}
}
if((AccountInfoString(ACCOUNT_CURRENCY)=="BCC"||AccountInfoString(ACCOUNT_CURRENCY)=="bcc"))
{
lv_s3="BCCUSD"+g_symbolSuffix;
if(iClose(lv_s3,MT4Period(PERIOD_D1),1)>0.0)
{
lv_d2=dParam0*iClose(lv_s3,MT4Period(PERIOD_D1),1);
}
}
if((AccountInfoString(ACCOUNT_CURRENCY)=="XRP"||AccountInfoString(ACCOUNT_CURRENCY)=="xrp"))
{
lv_s3="XRPUSD"+g_symbolSuffix;
if(iClose(lv_s3,MT4Period(PERIOD_D1),1)>0.0)
{
lv_d2=dParam0*iClose(lv_s3,MT4Period(PERIOD_D1),1);
}
}
if((AccountInfoString(ACCOUNT_CURRENCY)=="LTC"||AccountInfoString(ACCOUNT_CURRENCY)=="ltc"))
{
lv_s3="LTCUSD"+g_symbolSuffix;
if(iClose(lv_s3,MT4Period(PERIOD_D1),1)>0.0)
{
lv_d2=dParam0*iClose(lv_s3,MT4Period(PERIOD_D1),1);
}
}
if((AccountInfoString(ACCOUNT_CURRENCY)=="XMR"||AccountInfoString(ACCOUNT_CURRENCY)=="xmr"))
{
lv_s3="XMRUSD"+g_symbolSuffix;
if(iClose(lv_s3,MT4Period(PERIOD_D1),1)>0.0)
{
lv_d2=dParam0*iClose(lv_s3,MT4Period(PERIOD_D1),1);
}
}
if((AccountInfoString(ACCOUNT_CURRENCY)=="DSH"||AccountInfoString(ACCOUNT_CURRENCY)=="dsh"))
{
lv_s3="DSHUSD"+g_symbolSuffix;
if(iClose(lv_s3,MT4Period(PERIOD_D1),1)>0.0)
{
lv_d2=dParam0*iClose(lv_s3,MT4Period(PERIOD_D1),1);
}
}
if((AccountInfoString(ACCOUNT_CURRENCY)=="EOS"||AccountInfoString(ACCOUNT_CURRENCY)=="eos"))
{
lv_s3="EOSUSD"+g_symbolSuffix;
if(iClose(lv_s3,MT4Period(PERIOD_D1),1)>0.0)
{
lv_d2=dParam0*iClose(lv_s3,MT4Period(PERIOD_D1),1);
}
}
if((AccountInfoString(ACCOUNT_CURRENCY)=="TRX"||AccountInfoString(ACCOUNT_CURRENCY)=="trx"))
{
lv_s3="TRXUSD"+g_symbolSuffix;
if(iClose(lv_s3,MT4Period(PERIOD_D1),1)>0.0)
{
lv_d2=dParam0*iClose(lv_s3,MT4Period(PERIOD_D1),1);
}
}
if((AccountInfoString(ACCOUNT_CURRENCY)=="ADA"||AccountInfoString(ACCOUNT_CURRENCY)=="ada"))
{
lv_s3="ADAUSD"+g_symbolSuffix;
if(iClose(lv_s3,MT4Period(PERIOD_D1),1)>0.0)
{
lv_d2=dParam0*iClose(lv_s3,MT4Period(PERIOD_D1),1);
}
}
if((AccountInfoString(ACCOUNT_CURRENCY)=="BSV"||AccountInfoString(ACCOUNT_CURRENCY)=="bsv"))
{
lv_s3="BSVUSD"+g_symbolSuffix;
if(iClose(lv_s3,MT4Period(PERIOD_D1),1)>0.0)
{
lv_d2=dParam0*iClose(lv_s3,MT4Period(PERIOD_D1),1);
}
}
if((AccountInfoString(ACCOUNT_CURRENCY)=="XLM"||AccountInfoString(ACCOUNT_CURRENCY)=="xlm"))
{
lv_s3="XLMUSD"+g_symbolSuffix;
if(iClose(lv_s3,MT4Period(PERIOD_D1),1)>0.0)
{
lv_d2=dParam0*iClose(lv_s3,MT4Period(PERIOD_D1),1);
}
}
if((AccountInfoString(ACCOUNT_CURRENCY)=="GLD"||AccountInfoString(ACCOUNT_CURRENCY)=="gld"))
{
lv_s3="GLDUSD"+g_symbolSuffix;
if(iClose(lv_s3,MT4Period(PERIOD_D1),1)>0.0)
{
lv_d2=dParam0*iClose(lv_s3,MT4Period(PERIOD_D1),1);
}
}
if((AccountInfoString(ACCOUNT_CURRENCY)=="ZEC"||AccountInfoString(ACCOUNT_CURRENCY)=="zec"))
{
lv_s3="ZECUSD"+g_symbolSuffix;
if(iClose(lv_s3,MT4Period(PERIOD_D1),1)>0.0)
{
lv_d2=dParam0*iClose(lv_s3,MT4Period(PERIOD_D1),1);
}
}
if((AccountInfoString(ACCOUNT_CURRENCY)=="XEM"||AccountInfoString(ACCOUNT_CURRENCY)=="xem"))
{
lv_s3="XEMUSD"+g_symbolSuffix;
if(iClose(lv_s3,MT4Period(PERIOD_D1),1)>0.0)
{
lv_d2=dParam0*iClose(lv_s3,MT4Period(PERIOD_D1),1);
}
}
return(MathRound(lv_d2));
}
// ConvertToUSD<<==-------- --------
void LoadStrategy1Params()
{
double tmp_d1;
double tmp_d2;
double tmp_d3;
double tmp_d4;
double tmp_d5;
double tmp_d6;
double tmp_d7;
double tmp_d8;
double tmp_d9;
double tmp_d10;
double tmp_d11;
double tmp_d12;

g_entryTF=1440;
g_entryPeriod=15;
g_entryBars=24;
g_entryRetries=3;
g_entryDelaySeconds=105;
g_takeProfitPips=45.0;
g_tpOffset=0.0;
tmp_d1=AdjustEntry+-275.0;
if(Randomization>0.0)
{
tmp_d2=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d2=0.0;
}
g_slOffset=tmp_d1+tmp_d2;
tmp_d2=AdjustEntry+-160.0;
if(Randomization>0.0)
{
tmp_d3=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d3=0.0;
}
g_breakEvenPips=tmp_d2+tmp_d3;
g_maxConcurrent=5;
g_lotMultiplier=30.0;
g_expiryHours=35;
g_exitMode=1;
tmp_d3=AdjustSL+6100.0;
if(Randomization>0.0)
{
tmp_d4=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d4=0.0;
}
g_minProfitClose=tmp_d3+tmp_d4;
tmp_d4=AdjustTP+1450.0;
if(Randomization>0.0)
{
tmp_d5=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d5=0.0;
}
g_maxLossClose=tmp_d4+tmp_d5;
tmp_d5=AdjustTrailSL+1800.0;
if(Randomization>0.0)
{
tmp_d6=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d6=0.0;
}
g_trailStep=tmp_d5+tmp_d6;
if(Randomization>0.0)
{
tmp_d7=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d7=0.0;
}
g_trailStart=tmp_d7+1800.0;
if(Randomization>0.0)
{
tmp_d8=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d8=0.0;
}
g_trailStop=tmp_d8+5000.0;
g_trailOffset=0.1;
g_trailMin=0.0;
if(Randomization>0.0)
{
tmp_d9=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d9=0.0;
}
g_trailFactor=tmp_d9+1600.0;
tmp_d9=AdjustTrailTP+700.0;
if(Randomization>0.0)
{
tmp_d10=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d10=0.0;
}
g_trailMax=tmp_d9+tmp_d10;
if(Randomization>0.0)
{
tmp_d11=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d11=0.0;
}
g_beProfitTrigger=tmp_d11+930.0;
tmp_d11=AdjustBreakEven+120.0;
if(Randomization>0.0)
{
tmp_d12=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d12=0.0;
}
g_beOffset=tmp_d11+tmp_d12;
g_hlTrailTF=60;
g_hlTrailPeriod=50;
g_hlTrailShift=14;
g_hlTrailMode=12;
g_hlTrailBars=300;
g_hlTrailMult=22.0;
g_maxOrdersTotal=5;
if(!(RemoveCommentSuffix))
{
g_currentSymbol=ST1_Comment+"_XAUUSD_1";
}
g_magicMain=ST1_MagicNumber+1;
g_gmtOffsetFloat=ConvertToUSD_Old(145.0);
if(!(UseVariableValues)) return;
g_totalProfit=2000.0;
g_gmtOffsetFloat=ConvertToUSD_Old(60.0);
}
// LoadStrategy1Params<<==-------- --------
void LoadStrategy2Params()
{
double tmp_d1;
double tmp_d2;
double tmp_d3;
double tmp_d4;
double tmp_d5;
double tmp_d6;
double tmp_d7;
double tmp_d8;
double tmp_d9;
double tmp_d10;
double tmp_d11;
double tmp_d12;
double tmp_d13;

g_entryTF=240;
g_entryPeriod=60;
g_entryBars=12;
g_entryRetries=8;
g_entryDelaySeconds=90;
g_takeProfitPips=1050.0;
g_tpOffset=0.0;
tmp_d1=AdjustEntry+-40.0;
if(Randomization>0.0)
{
tmp_d2=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d2=0.0;
}
g_slOffset=tmp_d1+tmp_d2;
tmp_d2=AdjustEntry+-100.0;
if(Randomization>0.0)
{
tmp_d3=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d3=0.0;
}
g_breakEvenPips=tmp_d2+tmp_d3;
g_maxConcurrent=2;
g_lotMultiplier=130.0;
g_expiryHours=192;
g_exitMode=5;
if(!(UseHL_TrailingSL))
{
tmp_d3=AdjustSL+700.0;
if(Randomization>0.0)
{
tmp_d4=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d4=0.0;
}
g_minProfitClose=tmp_d3+tmp_d4;
}
else
{
tmp_d4=AdjustSL+800.0;
if(Randomization>0.0)
{
tmp_d5=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d5=0.0;
}
g_minProfitClose=tmp_d4+tmp_d5;
}
tmp_d5=AdjustTP+4900.0;
if(Randomization>0.0)
{
tmp_d6=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d6=0.0;
}
g_maxLossClose=tmp_d5+tmp_d6;
tmp_d6=AdjustTrailSL+1300.0;
if(Randomization>0.0)
{
tmp_d7=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d7=0.0;
}
g_trailStep=tmp_d6+tmp_d7;
if(Randomization>0.0)
{
tmp_d8=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d8=0.0;
}
g_trailStart=tmp_d8+1450.0;
if(Randomization>0.0)
{
tmp_d9=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d9=0.0;
}
g_trailStop=tmp_d9+2000.0;
g_trailOffset=0.1;
g_trailMin=0.0;
if(Randomization>0.0)
{
tmp_d10=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d10=0.0;
}
g_trailFactor=tmp_d10+1400.0;
tmp_d10=AdjustTrailTP+200.0;
if(Randomization>0.0)
{
tmp_d11=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d11=0.0;
}
g_trailMax=tmp_d10+tmp_d11;
if(Randomization>0.0)
{
tmp_d12=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d12=0.0;
}
g_beProfitTrigger=tmp_d12+500.0;
tmp_d12=AdjustBreakEven+200.0;
if(Randomization>0.0)
{
tmp_d13=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d13=0.0;
}
g_beOffset=tmp_d12+tmp_d13;
g_hlTrailTF=60;
g_hlTrailPeriod=50;
g_hlTrailShift=14;
g_hlTrailMode=6;
g_hlTrailBars=400;
g_hlTrailMult=32.0;
g_maxOrdersTotal=99;
if(!(RemoveCommentSuffix))
{
g_currentSymbol=ST1_Comment+"_XAUUSD_4";
}
g_magicMain=ST1_MagicNumber+2;
g_gmtOffsetFloat=ConvertToUSD_Old(57.0);
if(!(UseVariableValues)) return;
g_totalProfit=1600.0;
g_gmtOffsetFloat=ConvertToUSD_Old(52.0);
}
// LoadStrategy2Params<<==-------- --------
void LoadStrategy3Params()
{
double tmp_d1;
double tmp_d2;
double tmp_d3;
double tmp_d4;
double tmp_d5;
double tmp_d6;
double tmp_d7;
double tmp_d8;
double tmp_d9;
double tmp_d10;
double tmp_d11;
double tmp_d12;

g_entryTF=1440;
g_entryPeriod=60;
g_entryBars=15;
g_entryRetries=3;
g_entryDelaySeconds=230;
g_takeProfitPips=550.0;
g_tpOffset=0.0;
tmp_d1=AdjustEntry+-170.0;
if(Randomization>0.0)
{
tmp_d2=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d2=0.0;
}
g_slOffset=tmp_d1+tmp_d2;
tmp_d2=AdjustEntry+-70.0;
if(Randomization>0.0)
{
tmp_d3=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d3=0.0;
}
g_breakEvenPips=tmp_d2+tmp_d3;
g_maxConcurrent=1;
g_lotMultiplier=480.0;
g_expiryHours=480;
g_exitMode=1;
tmp_d3=AdjustSL+1000.0;
if(Randomization>0.0)
{
tmp_d4=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d4=0.0;
}
g_minProfitClose=tmp_d3+tmp_d4;
tmp_d4=AdjustTP+4100.0;
if(Randomization>0.0)
{
tmp_d5=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d5=0.0;
}
g_maxLossClose=tmp_d4+tmp_d5;
tmp_d5=AdjustTrailSL+450.0;
if(Randomization>0.0)
{
tmp_d6=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d6=0.0;
}
g_trailStep=tmp_d5+tmp_d6;
if(Randomization>0.0)
{
tmp_d7=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d7=0.0;
}
g_trailStart=tmp_d7+1400.0;
if(Randomization>0.0)
{
tmp_d8=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d8=0.0;
}
g_trailStop=tmp_d8+5000.0;
g_trailOffset=0.1;
g_trailMin=0.0;
if(Randomization>0.0)
{
tmp_d9=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d9=0.0;
}
g_trailFactor=tmp_d9+1600.0;
tmp_d9=AdjustTrailTP+400.0;
if(Randomization>0.0)
{
tmp_d10=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d10=0.0;
}
g_trailMax=tmp_d9+tmp_d10;
if(Randomization>0.0)
{
tmp_d11=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d11=0.0;
}
g_beProfitTrigger=tmp_d11+500.0;
tmp_d11=AdjustBreakEven+100.0;
if(Randomization>0.0)
{
tmp_d12=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d12=0.0;
}
g_beOffset=tmp_d11+tmp_d12;
g_hlTrailTF=60;
g_hlTrailPeriod=50;
g_hlTrailShift=1;
g_hlTrailMode=5;
g_hlTrailBars=700;
g_hlTrailMult=22.0;
g_maxOrdersTotal=99;
if(!(RemoveCommentSuffix))
{
g_currentSymbol=ST1_Comment+"_XAUUSD_2";
}
g_magicMain=ST1_MagicNumber+5;
g_gmtOffsetFloat=ConvertToUSD_Old(30.0);
if(!(UseVariableValues)) return;
g_totalProfit=2000.0;
g_gmtOffsetFloat=ConvertToUSD_Old(30.0);
}
// LoadStrategy3Params<<==-------- --------
void LoadStrategy4Params()
{
double tmp_d1;
double tmp_d2;
double tmp_d3;
double tmp_d4;
double tmp_d5;
double tmp_d6;
double tmp_d7;
double tmp_d8;
double tmp_d9;
double tmp_d10;
double tmp_d11;
double tmp_d12;
double tmp_d13;

g_entryTF=1440;
g_entryPeriod=60;
g_entryBars=7;
g_entryRetries=2;
g_entryDelaySeconds=20;
g_takeProfitPips=250.0;
g_tpOffset=0.0;
tmp_d1=AdjustEntry+-130.0;
if(Randomization>0.0)
{
tmp_d2=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d2=0.0;
}
g_slOffset=tmp_d1+tmp_d2;
tmp_d2=AdjustEntry+-120.0;
if(Randomization>0.0)
{
tmp_d3=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d3=0.0;
}
g_breakEvenPips=tmp_d2+tmp_d3;
g_maxConcurrent=1;
g_lotMultiplier=980.0;
g_expiryHours=432;
g_exitMode=1;
if(!(UseHL_TrailingSL))
{
tmp_d3=AdjustSL+600.0;
if(Randomization>0.0)
{
tmp_d4=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d4=0.0;
}
g_minProfitClose=tmp_d3+tmp_d4;
}
else
{
tmp_d4=AdjustSL+700.0;
if(Randomization>0.0)
{
tmp_d5=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d5=0.0;
}
g_minProfitClose=tmp_d4+tmp_d5;
}
tmp_d5=AdjustTP+3300.0;
if(Randomization>0.0)
{
tmp_d6=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d6=0.0;
}
g_maxLossClose=tmp_d5+tmp_d6;
tmp_d6=AdjustTrailSL+500.0;
if(Randomization>0.0)
{
tmp_d7=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d7=0.0;
}
g_trailStep=tmp_d6+tmp_d7;
if(Randomization>0.0)
{
tmp_d8=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d8=0.0;
}
g_trailStart=tmp_d8+400.0;
if(Randomization>0.0)
{
tmp_d9=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d9=0.0;
}
g_trailStop=tmp_d9+5000.0;
if(Randomization>0.0)
{
tmp_d10=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d10=0.0;
}
g_trailFactor=tmp_d10+1000.0;
tmp_d10=AdjustTrailTP+2000.0;
if(Randomization>0.0)
{
tmp_d11=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d11=0.0;
}
g_trailMax=tmp_d10+tmp_d11;
g_trailOffset=0.1;
g_trailMin=0.0;
if(Randomization>0.0)
{
tmp_d12=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d12=0.0;
}
g_beProfitTrigger=tmp_d12+400.0;
tmp_d12=AdjustBreakEven;
if(Randomization>0.0)
{
tmp_d13=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d13=0.0;
}
g_beOffset=tmp_d12+tmp_d13;
g_hlTrailTF=60;
g_hlTrailPeriod=50;
g_hlTrailShift=7;
g_hlTrailMode=4;
g_hlTrailBars=100;
g_hlTrailMult=0.0;
g_maxOrdersTotal=99;
if(!(RemoveCommentSuffix))
{
g_currentSymbol=ST1_Comment+"_XAUUSD_3";
}
g_magicMain=ST1_MagicNumber+8;
g_gmtOffsetFloat=ConvertToUSD_Old(32.0);
if(!(UseVariableValues)) return;
g_totalProfit=2000.0;
g_gmtOffsetFloat=ConvertToUSD_Old(35.0);
}
// LoadStrategy4Params<<==-------- --------
void LoadStrategy5Params()
{
double tmp_d1;
double tmp_d2;
double tmp_d3;
double tmp_d4;
double tmp_d5;
double tmp_d6;
double tmp_d7;
double tmp_d8;
double tmp_d9;
double tmp_d10;
double tmp_d11;
double tmp_d12;

g_entryTF=60;
g_entryPeriod=5;
g_entryBars=26;
g_entryRetries=24;
g_entryDelaySeconds=140;
g_takeProfitPips=120.0;
g_tpOffset=0.0;
tmp_d1=AdjustEntry+-115.0;
if(Randomization>0.0)
{
tmp_d2=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d2=0.0;
}
g_slOffset=tmp_d1+tmp_d2;
tmp_d2=AdjustEntry+-145.0;
if(Randomization>0.0)
{
tmp_d3=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d3=0.0;
}
g_breakEvenPips=tmp_d2+tmp_d3;
g_maxConcurrent=5;
g_lotMultiplier=55.0;
g_expiryHours=20;
g_exitMode=1;
tmp_d3=AdjustSL+10100.0;
if(Randomization>0.0)
{
tmp_d4=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d4=0.0;
}
g_minProfitClose=tmp_d3+tmp_d4;
tmp_d4=AdjustTP+800.0;
if(Randomization>0.0)
{
tmp_d5=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d5=0.0;
}
g_maxLossClose=tmp_d4+tmp_d5;
tmp_d5=AdjustTrailSL+500.0;
if(Randomization>0.0)
{
tmp_d6=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d6=0.0;
}
g_trailStep=tmp_d5+tmp_d6;
if(Randomization>0.0)
{
tmp_d7=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d7=0.0;
}
g_trailStart=tmp_d7+1200.0;
if(Randomization>0.0)
{
tmp_d8=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d8=0.0;
}
g_trailStop=tmp_d8+5000.0;
g_trailOffset=0.1;
g_trailMin=0.0;
if(Randomization>0.0)
{
tmp_d9=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d9=0.0;
}
g_trailFactor=tmp_d9+1950.0;
tmp_d9=AdjustTrailTP+350.0;
if(Randomization>0.0)
{
tmp_d10=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d10=0.0;
}
g_trailMax=tmp_d9+tmp_d10;
if(Randomization>0.0)
{
tmp_d11=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d11=0.0;
}
g_beProfitTrigger=tmp_d11+330.0;
tmp_d11=AdjustBreakEven+80.0;
if(Randomization>0.0)
{
tmp_d12=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d12=0.0;
}
g_beOffset=tmp_d11+tmp_d12;
g_hlTrailTF=60;
g_hlTrailPeriod=50;
g_hlTrailShift=0;
g_hlTrailMode=0;
g_hlTrailBars=100;
g_hlTrailMult=0.0;
g_maxOrdersTotal=5;
if(!(RemoveCommentSuffix))
{
g_currentSymbol=ST1_Comment+"_XAUUSD_6";
}
g_magicMain=ST1_MagicNumber+9;
g_gmtOffsetFloat=ConvertToUSD_Old(348.0);
if(!(UseVariableValues)) return;
g_totalProfit=2400.0;
g_gmtOffsetFloat=ConvertToUSD_Old(140.0);
}
// LoadStrategy5Params<<==-------- --------
void LoadStrategy6Params()
{
double tmp_d1;
double tmp_d2;
double tmp_d3;
double tmp_d4;
double tmp_d5;
double tmp_d6;
double tmp_d7;
double tmp_d8;
double tmp_d9;
double tmp_d10;
double tmp_d11;
double tmp_d12;

g_entryTF=60;
g_entryPeriod=15;
g_entryBars=30;
g_entryRetries=19;
g_entryDelaySeconds=110;
g_takeProfitPips=160.0;
g_tpOffset=0.0;
tmp_d1=AdjustEntry+-120.0;
if(Randomization>0.0)
{
tmp_d2=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d2=0.0;
}
g_slOffset=tmp_d1+tmp_d2;
tmp_d2=AdjustEntry+-110.0;
if(Randomization>0.0)
{
tmp_d3=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d3=0.0;
}
g_breakEvenPips=tmp_d2+tmp_d3;
g_maxConcurrent=3;
g_lotMultiplier=55.0;
g_expiryHours=30;
g_exitMode=1;
tmp_d3=AdjustSL+5300.0;
if(Randomization>0.0)
{
tmp_d4=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d4=0.0;
}
g_minProfitClose=tmp_d3+tmp_d4;
tmp_d4=AdjustTP+900.0;
if(Randomization>0.0)
{
tmp_d5=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d5=0.0;
}
g_maxLossClose=tmp_d4+tmp_d5;
tmp_d5=AdjustTrailSL+495.0;
if(Randomization>0.0)
{
tmp_d6=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d6=0.0;
}
g_trailStep=tmp_d5+tmp_d6;
if(Randomization>0.0)
{
tmp_d7=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d7=0.0;
}
g_trailStart=tmp_d7+400.0;
if(Randomization>0.0)
{
tmp_d8=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d8=0.0;
}
g_trailStop=tmp_d8+5000.0;
g_trailOffset=0.1;
g_trailMin=0.0;
if(Randomization>0.0)
{
tmp_d9=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d9=0.0;
}
g_trailFactor=tmp_d9+1900.0;
tmp_d9=AdjustTrailTP+250.0;
if(Randomization>0.0)
{
tmp_d10=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d10=0.0;
}
g_trailMax=tmp_d9+tmp_d10;
if(Randomization>0.0)
{
tmp_d11=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d11=0.0;
}
g_beProfitTrigger=tmp_d11+260.0;
tmp_d11=AdjustBreakEven+80.0;
if(Randomization>0.0)
{
tmp_d12=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d12=0.0;
}
g_beOffset=tmp_d11+tmp_d12;
g_hlTrailTF=60;
g_hlTrailPeriod=50;
g_hlTrailShift=0;
g_hlTrailMode=0;
g_hlTrailBars=100;
g_hlTrailMult=0.0;
g_maxOrdersTotal=99;
if(!(RemoveCommentSuffix))
{
g_currentSymbol=ST1_Comment+"_XAUUSD_5";
}
g_magicMain=ST1_MagicNumber+12;
g_gmtOffsetFloat=ConvertToUSD_Old(281.0);
if(!(UseVariableValues)) return;
g_totalProfit=2600.0;
g_gmtOffsetFloat=ConvertToUSD_Old(110.0);
}
// LoadStrategy6Params<<==-------- --------
void LoadStrategy7Params()
{
double tmp_d1;
double tmp_d2;
double tmp_d3;
double tmp_d4;
double tmp_d5;
double tmp_d6;
double tmp_d7;
double tmp_d8;
double tmp_d9;
double tmp_d10;
double tmp_d11;
double tmp_d12;

g_entryTF=60;
g_entryPeriod=15;
g_entryBars=7;
g_entryRetries=5;
g_entryDelaySeconds=200;
g_takeProfitPips=40.0;
g_tpOffset=0.0;
tmp_d1=AdjustEntry+-150.0;
if(Randomization>0.0)
{
tmp_d2=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d2=0.0;
}
g_slOffset=tmp_d1+tmp_d2;
tmp_d2=AdjustEntry+-145.0;
if(Randomization>0.0)
{
tmp_d3=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d3=0.0;
}
g_breakEvenPips=tmp_d2+tmp_d3;
g_maxConcurrent=3;
g_lotMultiplier=5.0;
g_expiryHours=15;
g_exitMode=1;
tmp_d3=AdjustSL+3900.0;
if(Randomization>0.0)
{
tmp_d4=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d4=0.0;
}
g_minProfitClose=tmp_d3+tmp_d4;
tmp_d4=AdjustTP+1350.0;
if(Randomization>0.0)
{
tmp_d5=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d5=0.0;
}
g_maxLossClose=tmp_d4+tmp_d5;
tmp_d5=AdjustTrailSL+445.0;
if(Randomization>0.0)
{
tmp_d6=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d6=0.0;
}
g_trailStep=tmp_d5+tmp_d6;
if(Randomization>0.0)
{
tmp_d7=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d7=0.0;
}
g_trailStart=tmp_d7+355.0;
if(Randomization>0.0)
{
tmp_d8=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d8=0.0;
}
g_trailStop=tmp_d8+5000.0;
g_trailOffset=0.1;
g_trailMin=0.0;
if(Randomization>0.0)
{
tmp_d9=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d9=0.0;
}
g_trailFactor=tmp_d9+1850.0;
tmp_d9=AdjustTrailTP+250.0;
if(Randomization>0.0)
{
tmp_d10=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d10=0.0;
}
g_trailMax=tmp_d9+tmp_d10;
if(Randomization>0.0)
{
tmp_d11=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d11=0.0;
}
g_beProfitTrigger=tmp_d11+160.0;
tmp_d11=AdjustBreakEven+50.0;
if(Randomization>0.0)
{
tmp_d12=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d12=0.0;
}
g_beOffset=tmp_d11+tmp_d12;
g_hlTrailTF=60;
g_hlTrailPeriod=50;
g_hlTrailShift=1;
g_hlTrailMode=9;
g_hlTrailBars=1500;
g_hlTrailMult=46.0;
g_maxOrdersTotal=99;
if(!(RemoveCommentSuffix))
{
g_currentSymbol=ST1_Comment+"_XAUUSD_9";
}
g_magicMain=ST1_MagicNumber+13;
g_gmtOffsetFloat=ConvertToUSD_Old(968.0);
if(!(UseVariableValues)) return;
g_totalProfit=1900.0;
g_gmtOffsetFloat=ConvertToUSD_Old(700.0);
}
// LoadStrategy7Params<<==-------- --------
void LoadStrategy8Params()
{
double tmp_d1;
double tmp_d2;
double tmp_d3;
double tmp_d4;
double tmp_d5;
double tmp_d6;
double tmp_d7;
double tmp_d8;
double tmp_d9;
double tmp_d10;
double tmp_d11;
double tmp_d12;

g_entryTF=60;
g_entryPeriod=15;
g_entryBars=25;
g_entryRetries=23;
g_entryDelaySeconds=145;
g_takeProfitPips=10.0;
g_tpOffset=0.0;
tmp_d1=AdjustEntry+-60.0;
if(Randomization>0.0)
{
tmp_d2=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d2=0.0;
}
g_slOffset=tmp_d1+tmp_d2;
tmp_d2=AdjustEntry+-145.0;
if(Randomization>0.0)
{
tmp_d3=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d3=0.0;
}
g_breakEvenPips=tmp_d2+tmp_d3;
g_maxConcurrent=5;
g_lotMultiplier=90.0;
g_expiryHours=60;
g_exitMode=1;
tmp_d3=AdjustSL+2250.0;
if(Randomization>0.0)
{
tmp_d4=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d4=0.0;
}
g_minProfitClose=tmp_d3+tmp_d4;
tmp_d4=AdjustTP+1450.0;
if(Randomization>0.0)
{
tmp_d5=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d5=0.0;
}
g_maxLossClose=tmp_d4+tmp_d5;
tmp_d5=AdjustTrailSL+450.0;
if(Randomization>0.0)
{
tmp_d6=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d6=0.0;
}
g_trailStep=tmp_d5+tmp_d6;
if(Randomization>0.0)
{
tmp_d7=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d7=0.0;
}
g_trailStart=tmp_d7+900.0;
if(Randomization>0.0)
{
tmp_d8=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d8=0.0;
}
g_trailStop=tmp_d8+5000.0;
g_trailOffset=0.1;
g_trailMin=0.0;
if(Randomization>0.0)
{
tmp_d9=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d9=0.0;
}
g_trailFactor=tmp_d9+2800.0;
tmp_d9=AdjustTrailTP+350.0;
if(Randomization>0.0)
{
tmp_d10=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d10=0.0;
}
g_trailMax=tmp_d9+tmp_d10;
if(Randomization>0.0)
{
tmp_d11=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d11=0.0;
}
g_beProfitTrigger=tmp_d11+340.0;
tmp_d11=AdjustBreakEven+30.0;
if(Randomization>0.0)
{
tmp_d12=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d12=0.0;
}
g_beOffset=tmp_d11+tmp_d12;
g_hlTrailTF=60;
g_hlTrailPeriod=50;
g_hlTrailShift=12;
g_hlTrailMode=17;
g_hlTrailBars=1000;
g_hlTrailMult=45.0;
g_maxOrdersTotal=5;
if(!(RemoveCommentSuffix))
{
g_currentSymbol=ST1_Comment+"_XAUUSD_7";
}
g_magicMain=ST1_MagicNumber+14;
g_gmtOffsetFloat=ConvertToUSD_Old(149.0);
if(!(UseVariableValues)) return;
g_totalProfit=2600.0;
g_gmtOffsetFloat=ConvertToUSD_Old(90.0);
}
// LoadStrategy8Params<<==-------- --------
void LoadStrategy9Params()
{
double tmp_d1;
double tmp_d2;
double tmp_d3;
double tmp_d4;
double tmp_d5;
double tmp_d6;
double tmp_d7;
double tmp_d8;
double tmp_d9;
double tmp_d10;
double tmp_d11;
double tmp_d12;

g_entryTF=60;
g_entryPeriod=15;
g_entryBars=26;
g_entryRetries=20;
g_entryDelaySeconds=235;
g_takeProfitPips=80.0;
g_tpOffset=0.0;
tmp_d1=AdjustEntry+-140.0;
if(Randomization>0.0)
{
tmp_d2=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d2=0.0;
}
g_slOffset=tmp_d1+tmp_d2;
tmp_d2=AdjustEntry+-170.0;
if(Randomization>0.0)
{
tmp_d3=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d3=0.0;
}
g_breakEvenPips=tmp_d2+tmp_d3;
g_maxConcurrent=5;
g_lotMultiplier=5.0;
g_expiryHours=55;
g_exitMode=1;
tmp_d3=AdjustSL+1900.0;
if(Randomization>0.0)
{
tmp_d4=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d4=0.0;
}
g_minProfitClose=tmp_d3+tmp_d4;
tmp_d4=AdjustTP+1200.0;
if(Randomization>0.0)
{
tmp_d5=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d5=0.0;
}
g_maxLossClose=tmp_d4+tmp_d5;
tmp_d5=AdjustTrailSL+1250.0;
if(Randomization>0.0)
{
tmp_d6=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d6=0.0;
}
g_trailStep=tmp_d5+tmp_d6;
if(Randomization>0.0)
{
tmp_d7=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d7=0.0;
}
g_trailStart=tmp_d7+650.0;
if(Randomization>0.0)
{
tmp_d8=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d8=0.0;
}
g_trailStop=tmp_d8+5000.0;
g_trailOffset=0.1;
g_trailMin=0.0;
if(Randomization>0.0)
{
tmp_d9=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d9=0.0;
}
g_trailFactor=tmp_d9+1950.0;
tmp_d9=AdjustTrailTP+250.0;
if(Randomization>0.0)
{
tmp_d10=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d10=0.0;
}
g_trailMax=tmp_d9+tmp_d10;
if(Randomization>0.0)
{
tmp_d11=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d11=0.0;
}
g_beProfitTrigger=tmp_d11+270.0;
tmp_d11=AdjustBreakEven;
if(Randomization>0.0)
{
tmp_d12=Randomization*2.0*MathRand()/32768.0+(0.0-Randomization);
}
else
{
tmp_d12=0.0;
}
g_beOffset=tmp_d11+tmp_d12;
g_hlTrailTF=60;
g_hlTrailPeriod=50;
g_hlTrailShift=15;
g_hlTrailMode=3;
g_hlTrailBars=1200;
g_hlTrailMult=16.0;
g_maxOrdersTotal=20;
if(!(RemoveCommentSuffix))
{
g_currentSymbol=ST1_Comment+"_XAUUSD_8";
}
g_magicMain=ST1_MagicNumber+15;
g_gmtOffsetFloat=ConvertToUSD_Old(276.0);
if(!(UseVariableValues)) return;
g_totalProfit=2800.0;
g_gmtOffsetFloat=ConvertToUSD_Old(130.0);
}
// LoadStrategy9Params<<==-------- --------
void CalcPerformanceStats()
{
double lv_d1;
int lv_i2;
double lv_d3;
double lv_d4;
double lv_d5;
//----------
bool _orderOK;
double tmp_d1;
long tmp_l2;
int tmp_i3;
int tmp_i4;
int tmp_i5;
int tmp_i6;
int tmp_i7;
int tmp_i8;
int tmp_i9;
int tmp_i10;
int tmp_i11;
int tmp_i12;
int tmp_i13;
int tmp_i14;
int tmp_i15;
int tmp_i16;
int tmp_i17;
int tmp_i18;
int tmp_i19;

tmp_d1=AccountEquity();
if(tmp_d1==AccountBalance()) return;
lv_d1=0.0;
if(AccountEquity()>g_prevEquity)
{
g_prevEquity=AccountEquity();
}
for(lv_i2=HistoryTotal();lv_i2>=0;lv_i2--)
{
if(OrderSelect(lv_i2,0,1)!=true) continue;
tmp_l2=OrderCloseTime();
if(tmp_l2<iTime(g_tradeSymbol,MT4Period(PERIOD_D1),0)) continue;
lv_d3=OrderProfit()+OrderSwap()+OrderCommission();
lv_d1=lv_d3+lv_d1;

}
lv_d4=AccountEquity()-AccountBalance();
lv_d5=lv_d4+lv_d1;
if(!(-(lv_d5)>g_prevEquity*PropFirmMaxDailyDD/100.0)) return;

if(!(g_panelCreated))
{
Print("Max Daily Drawdown reached, closing trades and skipping rest of the day");
}
for(tmp_i3=MT4OrdersTotal();tmp_i3>=0;tmp_i3=tmp_i3-1)
{
if(OrderSelect(tmp_i3,0,0)!=true||OrderSymbol()!=g_tradeSymbol) continue;
tmp_i4=OrderMagicNumber();
tmp_i5=ST1_MagicNumber+1;
if(tmp_i4!=tmp_i5)
{
tmp_i5=OrderMagicNumber();
tmp_i6=ST1_MagicNumber+2;
if(tmp_i5!=tmp_i6)
{
tmp_i6=OrderMagicNumber();
tmp_i7=ST1_MagicNumber+3;
if(tmp_i6!=tmp_i7)
{
tmp_i7=OrderMagicNumber();
tmp_i8=ST1_MagicNumber+4;
if(tmp_i7!=tmp_i8)
{
tmp_i8=OrderMagicNumber();
tmp_i9=ST1_MagicNumber+5;
if(tmp_i8!=tmp_i9)
{
tmp_i9=OrderMagicNumber();
tmp_i10=ST1_MagicNumber+6;
if(tmp_i9!=tmp_i10)
{
tmp_i10=OrderMagicNumber();
tmp_i11=ST1_MagicNumber+7;
if(tmp_i10!=tmp_i11)
{
tmp_i11=OrderMagicNumber();
tmp_i12=ST1_MagicNumber+8;
if(tmp_i11!=tmp_i12)
{
tmp_i12=OrderMagicNumber();
tmp_i13=ST1_MagicNumber+9;
if(tmp_i12!=tmp_i13)
{
tmp_i13=OrderMagicNumber();
tmp_i14=ST1_MagicNumber+10;
if(tmp_i13!=tmp_i14)
{
tmp_i14=OrderMagicNumber();
tmp_i15=ST1_MagicNumber+11;
if(tmp_i14!=tmp_i15)
{
tmp_i15=OrderMagicNumber();
tmp_i16=ST1_MagicNumber+12;
if(tmp_i15!=tmp_i16)
{
tmp_i16=OrderMagicNumber();
tmp_i17=ST1_MagicNumber+13;
if(tmp_i16!=tmp_i17)
{
tmp_i17=OrderMagicNumber();
tmp_i18=ST1_MagicNumber+14;
if(tmp_i17!=tmp_i18)
{
tmp_i18=OrderMagicNumber();
tmp_i19=ST1_MagicNumber+15;
if(tmp_i18!=tmp_i19) continue;
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
if(OrderType()==0)
{
_orderOK = OrderClose(OrderTicket(),OrderLots(),MarketInfo(g_tradeSymbol,MODE_BID),(int)g_maxVolatility,Red);
}
if(OrderType()==1)
{
_orderOK = OrderClose(OrderTicket(),OrderLots(),MarketInfo(g_tradeSymbol,MODE_ASK),(int)g_maxVolatility,Red);
}
if((OrderType()!=4&&OrderType()!=5)) continue;
_orderOK = OrderDelete(OrderTicket(),Red);

}
g_panelCreated=true;
g_prevEquity=0.0;
}
// CalcPerformanceStats<<==-------- --------
int GetGMT_Offset()
{
string lv_s2;
int lv_i3;
string lv_s4;
long lv_l5;
int lv_i6;
char lv_httpReqBuf[];
char lv_httpRespBuf[];
//----------
string tmp_s1;
string tmp_s2;

ResetLastError();
if(WebRequest("GET","https://www.worldtimeserver.com/time-zones/utc/",NULL,NULL,10000,lv_httpReqBuf,0,lv_httpRespBuf,tmp_s1)==-1)
{
Print("Error when reading GMT URL. Error code  =",GetLastError());
MessageBox("Add the address 'https://www.worldtimeserver.com/' in the list of allowed URLs on tab 'Expert Advisors'","Error",64);
tmp_s2="999";
}
else
{
tmp_s2=CharArrayToString(lv_httpRespBuf,0,0,0);
}
lv_s2=tmp_s2;
if(lv_s2=="999")
{
return(999);
}
lv_i3=StringFind(lv_s2,"\"serverTimeStamp\"value=",0);
lv_s4=StringSubstr(lv_s2,lv_i3+25,10);
lv_l5 = (long)ulong(lv_s4);
Print("GMT time = ",lv_l5);
Print("Broker time = ",TimeCurrent());
lv_i6=TimeHour(TimeCurrent())-TimeHour(lv_l5);
if(lv_i6< -12)
{
lv_i6+=24;
}
if(lv_i6> 12)
{
lv_i6-=24;
}
Print("GMT_Offset detected: "+string(lv_i6));
if((lv_i6<-12||lv_i6> 12))
{
Print("Error in detecting GMT offset with URL");
return(999);
}
if(lv_l5< TimeCurrent()-86400/*=1 ngay*/)
{
Print("Error in detecting GMT time with URL");
return(999);
}
return(lv_i6);
}
// GetGMT_Offset<<==-------- --------
bool IsAmericanDST()
{
int lv_i2;
datetime lv_dt3;
datetime lv_dt4;
int lv_i5;
int lv_i6;
//----------

lv_i2=TimeYear(TimeCurrent());
lv_dt3=0;
lv_dt4=0;
if(lv_i2< 1987)
{
Print("AmericanDST(): Invalid year.");
return(false);
}
lv_i5=0;
lv_i6=0;
if(lv_i2>=1987&&lv_i2<=2006)
{
lv_i5 = (int)(MathMod(lv_i2*6+2-lv_i2/4,7.0)+1.0);
lv_i6 = (int)(31.0-(MathMod(lv_i2*5/4+1,7.0)));
lv_dt3=StringToTime(((string)lv_i2+".04.01"))+(lv_i5-1)*86400+7200/*=2 gio*/;
lv_dt4=StringToTime(((string)lv_i2+".10.01"))+(lv_i6-1)*86400+7200/*=2 gio*/;
}
else
{
if(lv_i2>=2007)
{
lv_i5 = (int)(14.0-(MathMod(lv_i2*5/4+1,7.0)));
lv_i6 = (int)(7.0-(MathMod(lv_i2*5/4+1,7.0)));
lv_dt3=StringToTime(((string)lv_i2+".03.01"))+(lv_i5-1)*86400+7200/*=2 gio*/;
lv_dt4=StringToTime(((string)lv_i2+".11.01"))+(lv_i6-1)*86400+7200/*=2 gio*/;
}
}
if(TimeDayOfYear(TimeCurrent())> TimeDayOfYear(lv_dt3)&&TimeDayOfYear(TimeCurrent())< TimeDayOfYear(lv_dt4))
{
return(true);
}
return(false);
}
//<<==IsAmericanDST<<==

