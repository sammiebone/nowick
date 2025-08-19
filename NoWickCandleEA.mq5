//+------------------------------------------------------------------+
//|                                             NoWickCandleEA.mq5 |
//|                      Copyright 2024, OpenAI & MetaQuotes Software Corp. |
//|                                              https://www.openai.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, OpenAI & MetaQuotes Software Corp."
#property link      "https://www.openai.com"
#property version   "1.00"

#include <Trade\Trade.mqh>

//--- input parameters
input int      SMAPeriod   = 50;
input double   Lots        = 1.0;
input int      StopLoss    = 100;
input int      TakeProfit1 = 50;
input int      TakeProfit2 = 100;
input int      TakeProfit3 = 150;
input int      BreakevenPips = 10;
input double   VolumeMultiplier = 1.5;
input ulong    MagicNumber = 12345;
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
#define GV_PB_SIGNAL_TYPE "PB_SignalType_" + _Symbol
#define GV_PB_ENTRY_PRICE "PB_EntryPrice_" + _Symbol
#define GV_PB_STOP_LOSS   "PB_StopLoss_"   + _Symbol
#define GV_PB_TAKE_PROFIT "PB_TakeProfit_" + _Symbol
#define GV_PB_EXPIRY_TIME "PB_ExpiryTime_" + _Symbol
#define GV_PB_PATTERN_TYPE "PB_PatternType_" + _Symbol

//--- Global objects
CTrade m_trade;

// Forward declarations
void ManageOpenTrades();
void LookForNewSignal();
void CheckPullbackAndEnter();
void SetPendingPullback(ENUM_ORDER_TYPE signalType, double entry, double sl, double tp, int patternCode);
void ClearPendingPullback();
bool PlaceSafeRequest(MqlTradeRequest &request, string patternType, string tradeType);

//+------------------------------------------------------------------+
int OnInit()
{
   m_trade.SetExpertMagicNumber(MagicNumber);
   m_trade.SetMarginMode();
   return(INIT_SUCCEEDED);
}
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   string prefix = "NWEA_MQL5_State_";
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
   if(PositionSelect(_Symbol)) { ManageOpenTrades(); return; }
   if(GlobalVariableGet(GV_PB_SIGNAL_TYPE) != 0) { CheckPullbackAndEnter(); return; }
   static datetime lastBarTime = 0;
   if(lastBarTime == TimeCurrent()) return;
   lastBarTime = TimeCurrent();
   if(OrdersTotal() > 0) return;
   LookForNewSignal();
}
//+------------------------------------------------------------------+
void LookForNewSignal()
{
   MqlRates rates[22];
   if(CopyRates(_Symbol, _Period, 0, 22, rates) < 22) return;
   double sma_buffer[1];
   int sma_handle = iMA(_Symbol, _Period, SMAPeriod, 0, MODE_SMA, PRICE_CLOSE);
   if(sma_handle == INVALID_HANDLE || CopyBuffer(sma_handle, 0, 0, 1, sma_buffer) < 1) return;
   double smaValue = sma_buffer[0];
   bool isBearishTrend = rates[0].close < smaValue;
   bool isBullishTrend = rates[0].close > smaValue;
   long total_volume = 0;
   for(int i = 2; i < 22; i++) { total_volume += rates[i].tick_volume; }
   double avgVolume = total_volume / 20.0;
   bool isVolumeConfirmed = rates[1].tick_volume > avgVolume * VolumeMultiplier;
   bool isBearish = rates[1].close < rates[1].open;
   bool isBullish = rates[1].close > rates[1].open;
   if(!((isBearish && isBearishTrend) || (isBullish && isBullishTrend))) return;
   bool topIsFlat = (isBullish ? (rates[1].high - rates[1].close) < _Point : (rates[1].high - rates[1].open) < _Point);
   bool bottomIsFlat = (isBullish ? (rates[1].open - rates[1].low) < _Point : (rates[1].close - rates[1].low) < _Point);
   bool isFull = topIsFlat && bottomIsFlat;
   bool isOpening = (isBullish && bottomIsFlat && !topIsFlat) || (isBearish && topIsFlat && !bottomIsFlat);
   bool isClosing = (isBullish && !bottomIsFlat && topIsFlat) || (isBearish && !topIsFlat && bottomIsFlat);
   bool patternFound = (TradeFullMarubozu && isFull) || (TradeOpeningMarubozu && isOpening) || (TradeClosingMarubozu && isClosing);
   int patternCode = 0;
   if(isFull) patternCode = 1; else if(isOpening) patternCode = 2; else if(isClosing) patternCode = 3;
   bool rsiFilterPassed = true;
   if(UseRsiFilter)
   {
      double rsi_buffer[1];
      int rsi_handle = iRSI(_Symbol, _Period, RsiPeriod, PRICE_CLOSE);
      if(rsi_handle != INVALID_HANDLE && CopyBuffer(rsi_handle, 0, 1, 1, rsi_buffer) == 1)
      {
         double rsiValue = rsi_buffer[0];
         if(isBullish || (EnableParadoxStrategy && isBearish)) { if(rsiValue >= RsiOverbought) rsiFilterPassed = false; }
         else if(isBearish && !EnableParadoxStrategy) { if(rsiValue <= RsiOversold) rsiFilterPassed = false; }
      }
   }
   bool macdFilterPassed = true;
   if(UseMacdFilter)
   {
      double macd_main[1], macd_signal[1];
      int macd_handle = iMACD(_Symbol, _Period, MacdFastEma, MacdSlowEma, MacdSignalSma, PRICE_CLOSE);
      if(macd_handle != INVALID_HANDLE && CopyBuffer(macd_handle, 0, 1, 1, macd_main) == 1 && CopyBuffer(macd_handle, 1, 1, 1, macd_signal) == 1)
      {
         if(isBullish || (EnableParadoxStrategy && isBearish)) { if(macd_main[0] <= macd_signal[0]) macdFilterPassed = false; }
         else if(isBearish && !EnableParadoxStrategy) { if(macd_main[0] >= macd_signal[0]) macdFilterPassed = false; }
      }
   }
   if(patternFound && isVolumeConfirmed && rsiFilterPassed && macdFilterPassed)
   {
      MqlTradeRequest request;
      string patternType = (patternCode == 1 ? "Full" : (patternCode == 2 ? "Opening" : "Closing"));
      if(!EnableParadoxStrategy)
      {
         if(isBearish)
         {
            request.price = rates[1].high;
            request.sl = request.price + StopLoss * _Point;
            request.tp = request.price - TakeProfit3 * _Point;
            request.type = ORDER_TYPE_SELL_LIMIT;
            if(WaitForPullbackEntry)
            {
               double pullbackEntry = rates[1].close + (rates[1].open - rates[1].close) * (PullbackPercent/100.0);
               SetPendingPullback(ORDER_TYPE_SELL, pullbackEntry, request.sl, request.tp, patternCode);
            }
            else { PlaceSafeRequest(request, patternType, "Sell"); }
         }
         if(isBullish)
         {
            request.price = rates[1].low;
            request.sl = request.price - StopLoss * _Point;
            request.tp = request.price + TakeProfit3 * _Point;
            request.type = ORDER_TYPE_BUY_LIMIT;
            if(WaitForPullbackEntry)
            {
               double pullbackEntry = rates[1].open + (rates[1].close - rates[1].open) * (PullbackPercent/100.0);
               SetPendingPullback(ORDER_TYPE_BUY, pullbackEntry, request.sl, request.tp, patternCode);
            }
            else { PlaceSafeRequest(request, patternType, "Buy"); }
         }
      }
      else
      {
         if(isBearish)
         {
            request.price = rates[1].high;
            request.sl = rates[1].low - (SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point);
            request.tp = request.price + TakeProfit3 * _Point;
            request.type = ORDER_TYPE_BUY_STOP;
            PlaceSafeRequest(request, patternType, "Paradox Buy");
         }
      }
   }
}
//+------------------------------------------------------------------+
void SetPendingPullback(ENUM_ORDER_TYPE signalType, double entry, double sl, double tp, int patternCode)
{
   GlobalVariableSet(GV_PB_SIGNAL_TYPE, signalType);
   GlobalVariableSet(GV_PB_ENTRY_PRICE, entry);
   GlobalVariableSet(GV_PB_STOP_LOSS, sl);
   GlobalVariableSet(GV_PB_TAKE_PROFIT, tp);
   GlobalVariableSet(GV_PB_EXPIRY_TIME, TimeCurrent() + PullbackExpiryBars * PeriodSeconds());
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
   if(TimeCurrent() > GlobalVariableGet(GV_PB_EXPIRY_TIME)) { ClearPendingPullback(); return; }
   ENUM_ORDER_TYPE signalType = (ENUM_ORDER_TYPE)GlobalVariableGet(GV_PB_SIGNAL_TYPE);
   double entryPrice = GlobalVariableGet(GV_PB_ENTRY_PRICE);
   double sl = GlobalVariableGet(GV_PB_STOP_LOSS);
   double tp = GlobalVariableGet(GV_PB_TAKE_PROFIT);
   int patternCode = (int)GlobalVariableGet(GV_PB_PATTERN_TYPE);
   string patternType = (patternCode == 1 ? "Full" : (patternCode == 2 ? "Opening" : "Closing"));
   string tradeType = (signalType == ORDER_TYPE_BUY ? "Buy" : "Sell");
   bool entry_hit = false;
   if(signalType == ORDER_TYPE_BUY && SymbolInfoDouble(_Symbol, SYMBOL_ASK) <= entryPrice) entry_hit = true;
   if(signalType == ORDER_TYPE_SELL && SymbolInfoDouble(_Symbol, SYMBOL_BID) >= entryPrice) entry_hit = true;
   if(entry_hit)
   {
      MqlTradeRequest request;
      request.type = signalType;
      request.price = SymbolInfoDouble(_Symbol, signalType == ORDER_TYPE_BUY ? SYMBOL_ASK : SYMBOL_BID);
      request.sl = sl;
      request.tp = tp;
      PlaceSafeRequest(request, patternType, tradeType);
      ClearPendingPullback();
   }
}
//+------------------------------------------------------------------+
bool PlaceSafeRequest(MqlTradeRequest &request, string patternType, string tradeType)
{
   if(request.sl == 0 || request.tp == 0)
   {
      Print("CRITICAL ERROR: MQL5 SL or TP is zero. Order placement aborted.");
      return false;
   }
   MqlTradeResult result;
   ZeroMemory(request);
   ZeroMemory(result);
   request.symbol = _Symbol;
   request.volume = Lots;
   request.magic = MagicNumber;
   request.comment = "NoWickCandleEA " + _Symbol + " " + tradeType + " " + patternType + " " + EnumToString(_Period);
   if(request.action==0) request.action = (request.type >= ORDER_TYPE_BUY_LIMIT ? TRADE_ACTION_PENDING : TRADE_ACTION_DEAL);
   if(!m_trade.OrderSend(request,result)) { Print("OrderSend error ", m_trade.ResultRetcode()); }
   return result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_PLACED;
}
//+------------------------------------------------------------------+
void ManageOpenTrades()
{
   if(!PositionSelect(_Symbol)) return;
   if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) return;
   long id = PositionGetInteger(POSITION_IDENTIFIER);
   long type = PositionGetInteger(POSITION_TYPE);
   double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
   double volume = PositionGetDouble(POSITION_VOLUME);
   string gv_name = "NWEA_MQL5_State_" + (string)id;
   int stage = (int)GlobalVariableGet(gv_name);
   if(stage == 0) stage = 1;
   if(stage == 1)
   {
      bool tp1_hit = false;
      if(type == POSITION_TYPE_BUY && SymbolInfoDouble(_Symbol, SYMBOL_BID) >= open_price + TakeProfit1 * _Point) tp1_hit = true;
      if(type == POSITION_TYPE_SELL && SymbolInfoDouble(_Symbol, SYMBOL_ASK) <= open_price - TakeProfit1 * _Point) tp1_hit = true;
      if(tp1_hit)
      {
         double lotsToClose = NormalizeDouble(Lots / 3.0, 2);
         if(lotsToClose > 0 && volume > lotsToClose)
         {
            if(type == POSITION_TYPE_BUY) m_trade.Sell(lotsToClose, _Symbol); else m_trade.Buy(lotsToClose, _Symbol);
         }
         double newSL = 0;
         if(type == POSITION_TYPE_BUY) newSL = NormalizeDouble(open_price + BreakevenPips * _Point, _Digits);
         else newSL = NormalizeDouble(open_price - BreakevenPips * _Point, _Digits);
         m_trade.PositionModify(_Symbol, newSL, PositionGetDouble(POSITION_TP));
         GlobalVariableSet(gv_name, 2);
      }
   }
   if(stage == 2)
   {
      bool tp2_hit = false;
      if(type == POSITION_TYPE_BUY && SymbolInfoDouble(_Symbol, SYMBOL_BID) >= open_price + TakeProfit2 * _Point) tp2_hit = true;
      if(type == POSITION_TYPE_SELL && SymbolInfoDouble(_Symbol, SYMBOL_ASK) <= open_price - TakeProfit2 * _Point) tp2_hit = true;
      if(tp2_hit)
      {
         double lotsToClose = NormalizeDouble(Lots / 3.0, 2);
         if(lotsToClose > 0 && volume > lotsToClose)
         {
            if(type == POSITION_TYPE_BUY) m_trade.Sell(lotsToClose, _Symbol); else m_trade.Buy(lotsToClose, _Symbol);
         }
         else { if(type == POSITION_TYPE_BUY) m_trade.Sell(volume, _Symbol); else m_trade.Buy(volume, _Symbol); }
         GlobalVariableSet(gv_name, 3);
      }
   }
}
