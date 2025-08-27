//+------------------------------------------------------------------+
//|                                               NoWickCandleEA.mq4 |
//|                      Copyright 2024, OpenAI & MetaQuotes Software Corp. |
//|                                              https://www.openai.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, OpenAI & MetaQuotes Software Corp."
#property link      "https://www.openai.com"
#property version   "1.00"
#property strict

//--- input parameters
input int      SMAPeriod   = 50;
input double   Lots        = 3.0;
input int      StopLoss    = 100;
input int      TakeProfit1 = 50;
input int      TakeProfit2 = 100;
input int      TakeProfit3 = 150;
input int      BreakevenPips = 10;
input double   VolumeMultiplier = 1.5;
input int      MagicNumber = 12345;
input bool     EnableParadoxStrategy = false;
//--- Pattern Selection
input bool     TradeFullMarubozu    = true;
input bool     TradeOpeningMarubozu = true;
input bool     TradeClosingMarubozu = true;
//--- RSI Filter
input bool     UseRsiFilter         = true;
input int      RsiPeriod            = 14;
input int      RsiOverbought        = 70;
input int      RsiOversold          = 30;
//--- Pullback Entry
input bool     WaitForPullbackEntry = false;
input double   PullbackPercent      = 50.0;
input int      PullbackExpiryBars   = 3;
//--- MACD Filter
input bool     UseMacdFilter        = true;
input int      MacdFastEma          = 12;
input int      MacdSlowEma          = 26;
input int      MacdSignalSma        = 9;

//--- Global Variable Name definitions for Pullback State
#define GV_PB_SIGNAL_TYPE "PB_SignalType_" + Symbol()
#define GV_PB_ENTRY_PRICE "PB_EntryPrice_" + Symbol()
#define GV_PB_STOP_LOSS   "PB_StopLoss_"   + Symbol()
#define GV_PB_TAKE_PROFIT "PB_TakeProfit_" + Symbol()
#define GV_PB_EXPIRY_TIME "PB_ExpiryTime_" + Symbol()
#define GV_PB_PATTERN_TYPE "PB_PatternType_" + Symbol()

// Forward declarations
bool DoesOrderExist();
void ManageOpenTrades();
void LookForNewSignal();
void CheckPullbackAndEnter();
void SetPendingPullback(int signalType, double entry, double sl, double tp, int patternCode);
void ClearPendingPullback();
int PlaceSafeOrder(int type, double price, double sl, double tp, string patternType, string tradeType);

//+------------------------------------------------------------------+
int OnInit()
{
   double stopLevel = MarketInfo(Symbol(), MODE_STOPLEVEL);
   if(StopLoss > 0 && StopLoss < stopLevel) { Print("Error: StopLoss is too small."); return(INIT_FAILED); }
   if(TakeProfit1 > 0 && TakeProfit1 < stopLevel) { Print("Error: TakeProfit1 is too small."); return(INIT_FAILED); }
   if(TakeProfit2 > 0 && TakeProfit2 < stopLevel) { Print("Error: TakeProfit2 is too small."); return(INIT_FAILED); }
   if(TakeProfit3 > 0 && TakeProfit3 < stopLevel) { Print("Error: TakeProfit3 is too small."); return(INIT_FAILED); }
   if(Lots < 0.03) { Print("Error: Lots size must be at least 0.03."); return(INIT_FAILED); }
   if(PullbackPercent < 0 || PullbackPercent > 100) { Print("Error: PullbackPercent must be between 0 and 100."); return(INIT_FAILED); }
   return(INIT_SUCCEEDED);
}
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   string prefix = "NWEA_State_";
   for(int i = GlobalVariablesTotal() - 1; i >= 0; i--)
   {
      string gv_name = GlobalVariableName(i);
      if(StringFind(gv_name, prefix, 0) == 0) GlobalVariableDel(gv_name);
   }
   ClearPendingPullback();
}
//+------------------------------------------------------------------+
void OnTick()
{
   if(OrdersTotal() > 0) { ManageOpenTrades(); }
   if(GlobalVariableGet(GV_PB_SIGNAL_TYPE) != 0) { CheckPullbackAndEnter(); return; }
   static datetime lastBarTime = 0;
   if(lastBarTime == Time[0]) return;
   lastBarTime = Time[0];
   if(DoesOrderExist()) return;
   LookForNewSignal();
}
//+------------------------------------------------------------------+
void LookForNewSignal()
{
   double smaValue = iMA(NULL, 0, SMAPeriod, 0, MODE_SMA, PRICE_CLOSE, 0);
   bool isBearishTrend = Close[0] < smaValue;
   bool isBullishTrend = Close[0] > smaValue;
   long totalVolume = 0;
   for(int i = 2; i < 22; i++) { totalVolume += iVolume(NULL, 0, i); }
   double avgVolume = totalVolume / 20.0;
   bool isVolumeConfirmed = iVolume(NULL, 0, 1) > avgVolume * VolumeMultiplier;
   bool isBearish = Close[1] < Open[1];
   bool isBullish = Close[1] > Open[1];
   if(!((isBearish && isBearishTrend) || (isBullish && isBullishTrend))) return;
   bool topIsFlat = (isBullish ? (High[1] - Close[1]) < _Point : (High[1] - Open[1]) < _Point);
   bool bottomIsFlat = (isBullish ? (Open[1] - Low[1]) < _Point : (Close[1] - Low[1]) < _Point);
   bool isFull = topIsFlat && bottomIsFlat;
   bool isOpening = (isBullish && bottomIsFlat && !topIsFlat) || (isBearish && topIsFlat && !bottomIsFlat);
   bool isClosing = (isBullish && !bottomIsFlat && topIsFlat) || (isBearish && !topIsFlat && bottomIsFlat);
   bool patternFound = (TradeFullMarubozu && isFull) || (TradeOpeningMarubozu && isOpening) || (TradeClosingMarubozu && isClosing);
   int patternCode = 0;
   if(isFull) patternCode = 1; else if(isOpening) patternCode = 2; else if(isClosing) patternCode = 3;
   bool rsiFilterPassed = true;
   if(UseRsiFilter)
   {
      double rsiValue = iRSI(NULL, 0, RsiPeriod, PRICE_CLOSE, 1);
      if(isBullish || (EnableParadoxStrategy && isBearish)) { if(rsiValue >= RsiOverbought) { rsiFilterPassed = false; } }
      else if(isBearish && !EnableParadoxStrategy) { if(rsiValue <= RsiOversold) { rsiFilterPassed = false; } }
   }
   bool macdFilterPassed = true;
   if(UseMacdFilter)
   {
      double macdMain = iMACD(NULL, 0, MacdFastEma, MacdSlowEma, MacdSignalSma, PRICE_CLOSE, MODE_MAIN, 1);
      double macdSignal = iMACD(NULL, 0, MacdFastEma, MacdSlowEma, MacdSignalSma, PRICE_CLOSE, MODE_SIGNAL, 1);
      if(isBullish || (EnableParadoxStrategy && isBearish)) { if(macdMain <= macdSignal) macdFilterPassed = false; }
      else if(isBearish && !EnableParadoxStrategy) { if(macdMain >= macdSignal) macdFilterPassed = false; }
   }
   if(patternFound && isVolumeConfirmed && rsiFilterPassed && macdFilterPassed)
   {
      string patternType = (patternCode == 1 ? "Full" : (patternCode == 2 ? "Opening" : "Closing"));
      if(!EnableParadoxStrategy)
      {
         if(isBearish)
         {
            double entry = NormalizeDouble(High[1], _Digits);
            double sl = NormalizeDouble(entry + StopLoss * _Point, _Digits);
            double tp = NormalizeDouble(entry - TakeProfit3 * _Point, _Digits);
            if(WaitForPullbackEntry)
            {
               double pullbackEntry = NormalizeDouble(Close[1] + (Open[1] - Close[1]) * (PullbackPercent/100.0), _Digits);
               SetPendingPullback(OP_SELL, pullbackEntry, sl, tp, patternCode);
            }
            else { PlaceSafeOrder(OP_SELLLIMIT, entry, sl, tp, patternType, "Sell"); }
         }
         if(isBullish)
         {
            double entry = NormalizeDouble(Low[1], _Digits);
            double sl = NormalizeDouble(entry - StopLoss * _Point, _Digits);
            double tp = NormalizeDouble(entry + TakeProfit3 * _Point, _Digits);
            if(WaitForPullbackEntry)
            {
               double pullbackEntry = NormalizeDouble(Open[1] + (Close[1] - Open[1]) * (PullbackPercent/100.0), _Digits);
               SetPendingPullback(OP_BUY, pullbackEntry, sl, tp, patternCode);
            }
            else { PlaceSafeOrder(OP_BUYLIMIT, entry, sl, tp, patternType, "Buy"); }
         }
      }
      else
      {
         if(isBearish)
         {
            double price = NormalizeDouble(High[1], _Digits);
            double sl = NormalizeDouble(Low[1] - (SymbolInfoInteger(Symbol(), SYMBOL_SPREAD) * _Point), _Digits);
            double tp = NormalizeDouble(price + TakeProfit3 * _Point, _Digits);
            PlaceSafeOrder(OP_BUYSTOP, price, sl, tp, patternType, "Paradox Buy");
         }
      }
   }
}
//+------------------------------------------------------------------+
void SetPendingPullback(int signalType, double entry, double sl, double tp, int patternCode)
{
   GlobalVariableSet(GV_PB_SIGNAL_TYPE, signalType);
   GlobalVariableSet(GV_PB_ENTRY_PRICE, entry);
   GlobalVariableSet(GV_PB_STOP_LOSS, sl);
   GlobalVariableSet(GV_PB_TAKE_PROFIT, tp);
   GlobalVariableSet(GV_PB_EXPIRY_TIME, TimeCurrent() + PullbackExpiryBars * Period()*60);
   GlobalVariableSet(GV_PB_PATTERN_TYPE, patternCode);
}
//+------------------------------------------------------------------+
void ClearPendingPullback()
{
   GlobalVariableDel(GV_PB_SIGNAL_TYPE);
   GlobalVariableDel(GV_PB_ENTRY_PRICE);
   GlobalVariableDel(GV_PB_STOP_LOSS);
   GlobalVariableDel(GV_PB_TAKE_PROFIT);
   GlobalVariableDel(GV_PB_EXPIRY_TIME);
   GlobalVariableDel(GV_PB_PATTERN_TYPE);
}
//+------------------------------------------------------------------+
void CheckPullbackAndEnter()
{
   if(TimeCurrent() > GlobalVariableGet(GV_PB_EXPIRY_TIME))
   {
      ClearPendingPullback();
      return;
   }
   int signalType = (int)GlobalVariableGet(GV_PB_SIGNAL_TYPE);
   double entryPrice = GlobalVariableGet(GV_PB_ENTRY_PRICE);
   double sl = GlobalVariableGet(GV_PB_STOP_LOSS);
   double tp = GlobalVariableGet(GV_PB_TAKE_PROFIT);
   int patternCode = (int)GlobalVariableGet(GV_PB_PATTERN_TYPE);
   string patternType = (patternCode == 1 ? "Full" : (patternCode == 2 ? "Opening" : "Closing"));
   string tradeType = (signalType == OP_BUY ? "Buy" : "Sell");
   bool entry_hit = false;
   if(signalType == OP_BUY && Ask <= entryPrice) entry_hit = true;
   if(signalType == OP_SELL && Bid >= entryPrice) entry_hit = true;
   if(entry_hit)
   {
      double price = (signalType == OP_BUY ? Ask : Bid);
      PlaceSafeOrder(signalType, price, sl, tp, patternType, tradeType);
      ClearPendingPullback();
   }
}
//+------------------------------------------------------------------+
int PlaceSafeOrder(int type, double price, double sl, double tp, string patternType, string tradeType)
{
   if(sl == 0 || tp == 0)
   {
      Print("CRITICAL ERROR: StopLoss or TakeProfit is zero. Order placement aborted.");
      return -1;
   }
   string comment = "NoWickCandleEA " + Symbol() + " " + tradeType + " " + patternType + " " + (string)Period();
   int ticket = OrderSend(Symbol(), type, Lots, price, 3, sl, tp, comment, MagicNumber, 0, (type == OP_BUY || type == OP_BUYSTOP ? clrBlue : clrRed));
   if(ticket < 0) { Print("OrderSend failed with error #", GetLastError()); }
   else { Print("Order successfully placed. Ticket #", ticket); }
   return ticket;
}
//+------------------------------------------------------------------+
bool DoesOrderExist()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
      {
         if(OrderSymbol() == Symbol() && OrderMagicNumber() == MagicNumber) return(true);
      }
   }
   return(false);
}
//+------------------------------------------------------------------+
void ManageOpenTrades()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != Symbol() || OrderMagicNumber() != MagicNumber) continue;
      int ticket = OrderTicket();
      string gv_name = "NWEA_State_" + (string)ticket;
      int stage = (int)GlobalVariableGet(gv_name);
      if(stage == 0) stage = 1;
      if(stage == 1)
      {
         bool tp1_hit = false;
         if(OrderType() == OP_BUY && Bid >= OrderOpenPrice() + TakeProfit1 * _Point) tp1_hit = true;
         if(OrderType() == OP_SELL && Ask <= OrderOpenPrice() - TakeProfit1 * _Point) tp1_hit = true;
         if(tp1_hit)
         {
            double lotsToClose = NormalizeDouble(Lots / 3.0, 2);
            if(lotsToClose > 0 && OrderLots() > lotsToClose) { if(!OrderClose(ticket, lotsToClose, OrderClosePrice(), 3)) Print("Error closing partial order for TP1: ", GetLastError()); }
            if(!OrderSelect(ticket, SELECT_BY_TICKET)) continue;
            double newSL = 0;
            if(OrderType() == OP_BUY) newSL = NormalizeDouble(OrderOpenPrice() + BreakevenPips * _Point, _Digits);
            else newSL = NormalizeDouble(OrderOpenPrice() - BreakevenPips * _Point, _Digits);
            if(!OrderModify(ticket, OrderOpenPrice(), newSL, OrderTakeProfit(), 0)) Print("Error modifying SL for breakeven: ", GetLastError());
            GlobalVariableSet(gv_name, 2);
            return;
         }
      }
      if(stage == 2)
      {
         bool tp2_hit = false;
         if(OrderType() == OP_BUY && Bid >= OrderOpenPrice() + TakeProfit2 * _Point) tp2_hit = true;
         if(OrderType() == OP_SELL && Ask <= OrderOpenPrice() - TakeProfit2 * _Point) tp2_hit = true;
         if(tp2_hit)
         {
            double lotsToClose = NormalizeDouble(Lots / 3.0, 2);
            if(lotsToClose > 0 && OrderLots() > lotsToClose) { if(!OrderClose(ticket, lotsToClose, OrderClosePrice(), 3)) Print("Error closing partial order for TP2: ", GetLastError()); }
            else { if(!OrderClose(ticket, OrderLots(), OrderClosePrice(), 3)) Print("Error closing remaining order for TP2: ", GetLastError()); }
            GlobalVariableSet(gv_name, 3);
            return;
         }
      }
   }
}
