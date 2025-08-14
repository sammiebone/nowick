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
input int      SMAPeriod   = 50;      // SMA Period
input double   Lots        = 1.0;     // Lots size
input int      StopLoss    = 100;     // Stop Loss in pips
input int      TakeProfit1 = 50;      // Take Profit 1 in pips
input int      TakeProfit2 = 100;     // Take Profit 2 in pips
input int      TakeProfit3 = 150;     // Take Profit 3 in pips
input int      BreakevenPips = 10;    // Pips to add for breakeven SL
input double   VolumeMultiplier = 1.5; // Required volume increase over average
input ulong    MagicNumber = 12345;   // Magic Number (ulong for MQL5)
input bool     EnableParadoxStrategy = false; // Switch to Mean-Reversion strategy
//--- Pattern Selection
input bool     TradeFullMarubozu    = true; // Trade Marubozu with no wicks
input bool     TradeOpeningMarubozu = true; // Trade Marubozu with flat open
input bool     TradeClosingMarubozu = true; // Trade Marubozu with flat close
//--- RSI Filter
input bool     UseRsiFilter         = true;  // Use RSI to filter signals
input int      RsiPeriod            = 14;    // RSI Period
input int      RsiOverbought        = 70;    // RSI Overbought Level
input int      RsiOversold          = 30;    // RSI Oversold Level
//--- Pullback Entry
input bool     WaitForPullbackEntry = false; // Wait for a pullback before entering
input double   PullbackPercent      = 50.0;  // Pullback percent (0-100)
input int      PullbackExpiryBars   = 3;     // Bars to wait for a pullback
//--- MACD Filter
input bool     UseMacdFilter        = true;  // Use MACD to filter signals
input int      MacdFastEma          = 12;    // MACD Fast EMA Period
input int      MacdSlowEma          = 26;    // MACD Slow EMA Period
input int      MacdSignalSma        = 9;     // MACD Signal SMA Period

//--- Global Variable Name definitions for Pullback State
#define GV_PB_SIGNAL_TYPE "PB_SignalType_" + _Symbol
#define GV_PB_ENTRY_PRICE "PB_EntryPrice_" + _Symbol
#define GV_PB_STOP_LOSS   "PB_StopLoss_"   + _Symbol
#define GV_PB_TAKE_PROFIT "PB_TakeProfit_" + _Symbol
#define GV_PB_EXPIRY_TIME "PB_ExpiryTime_" + _Symbol
#define GV_PB_PATTERN_TYPE "PB_PatternType_" + _Symbol

//--- Global objects
CTrade m_trade;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   m_trade.SetExpertMagicNumber(MagicNumber);
   m_trade.SetMarginMode();

   int stops_level = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   if(StopLoss < stops_level) Print("StopLoss value of ", StopLoss, " is too small. Minimum is ", stops_level);
   if(TakeProfit1 < stops_level) Print("TakeProfit1 value of ", TakeProfit1, " is too small. Minimum is ", stops_level);
   if(TakeProfit2 < stops_level) Print("TakeProfit2 value of ", TakeProfit2, " is too small. Minimum is ", stops_level);
   if(TakeProfit3 < stops_level) Print("TakeProfit3 value of ", TakeProfit3, " is too small. Minimum is ", stops_level);

   if(Lots < 0.03) { Print("Error: Lots size must be at least 0.03 for the partial close logic to work."); return(INIT_FAILED); }
   if(PullbackPercent < 0 || PullbackPercent > 100) { Print("Error: PullbackPercent must be between 0 and 100."); return(INIT_FAILED); }

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
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

// Forward declarations
void ManageOpenTrades();
void LookForNewSignal();
void CheckPullbackAndEnter();
void SetPendingPullback(ENUM_ORDER_TYPE signalType, double entry, double sl, double tp, int patternCode);
void ClearPendingPullback();

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   if(PositionSelect(_Symbol))
   {
      ManageOpenTrades();
      return;
   }

   if(GlobalVariableGet(GV_PB_SIGNAL_TYPE) != 0)
   {
      CheckPullbackAndEnter();
      return;
   }

   static datetime lastBarTime = 0;
   if(lastBarTime == TimeCurrent()) return;
   lastBarTime = TimeCurrent();

   if(OrdersTotal() > 0) return;

   LookForNewSignal();
}

//+------------------------------------------------------------------+
//| Looks for a new trade signal                                     |
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
      MqlTradeRequest request; MqlTradeResult result;
      string patternType = (patternCode == 1 ? "Full" : (patternCode == 2 ? "Opening" : "Closing"));

      if(!EnableParadoxStrategy)
      {
         string comment;
         if(isBearish)
         {
            double price = rates[1].high;
            double sl = price + StopLoss * _Point;
            double tp = price - TakeProfit3 * _Point;
            comment = _Symbol + " Sell " + patternType + " " + EnumToString(_Period);
            if(WaitForPullbackEntry)
            {
               double pullbackEntry = rates[1].close + (rates[1].open - rates[1].close) * (PullbackPercent/100.0);
               SetPendingPullback(ORDER_TYPE_SELL, pullbackEntry, sl, tp, patternCode);
            }
            else
            {
               ZeroMemory(request); ZeroMemory(result);
               request.action = TRADE_ACTION_PENDING; request.type = ORDER_TYPE_SELL_LIMIT;
               request.symbol = _Symbol; request.volume = Lots; request.price = price;
               request.sl = sl; request.tp = tp; request.comment = comment; request.magic = MagicNumber;
               if(!m_trade.OrderSend(request, result)) { Print("MQL5 OrderSend error ", m_trade.ResultRetcode()); }
            }
         }
         if(isBullish)
         {
            double price = rates[1].low;
            double sl = price - StopLoss * _Point;
            double tp = price + TakeProfit3 * _Point;
            comment = _Symbol + " Buy " + patternType + " " + EnumToString(_Period);
            if(WaitForPullbackEntry)
            {
               double pullbackEntry = rates[1].open + (rates[1].close - rates[1].open) * (PullbackPercent/100.0);
               SetPendingPullback(ORDER_TYPE_BUY, pullbackEntry, sl, tp, patternCode);
            }
            else
            {
               ZeroMemory(request); ZeroMemory(result);
               request.action = TRADE_ACTION_PENDING; request.type = ORDER_TYPE_BUY_LIMIT;
               request.symbol = _Symbol; request.volume = Lots; request.price = price;
               request.sl = sl; request.tp = tp; request.comment = comment; request.magic = MagicNumber;
               if(!m_trade.OrderSend(request, result)) { Print("MQL5 OrderSend error ", m_trade.ResultRetcode()); }
            }
         }
      }
      else
      {
         if(isBearish)
         {
            double price = rates[1].high;
            double sl = rates[1].low - (SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point);
            double tp = price + TakeProfit3 * _Point;
            string comment = _Symbol + " Paradox Buy " + patternType + " " + EnumToString(_Period);
            ZeroMemory(request); ZeroMemory(result);
            request.action = TRADE_ACTION_PENDING; request.type = ORDER_TYPE_BUY_STOP;
            request.symbol = _Symbol; request.volume = Lots; request.price = price;
            request.sl = sl; request.tp = tp; request.comment = comment; request.magic = MagicNumber;
            if(!m_trade.OrderSend(request, result)) { Print("MQL5 OrderSend error ", m_trade.ResultRetcode()); }
         }
      }
   }
}

void SetPendingPullback(ENUM_ORDER_TYPE signalType, double entry, double sl, double tp, int patternCode)
{
   GlobalVariableSet(GV_PB_SIGNAL_TYPE, signalType);
   GlobalVariableSet(GV_PB_ENTRY_PRICE, entry);
   GlobalVariableSet(GV_PB_STOP_LOSS, sl);
   GlobalVariableSet(GV_PB_TAKE_PROFIT, tp);
   GlobalVariableSet(GV_PB_EXPIRY_TIME, TimeCurrent() + PullbackExpiryBars * PeriodSeconds());
   GlobalVariableSet(GV_PB_PATTERN_TYPE, patternCode);
}

void ClearPendingPullback()
{
   GlobalVariableDel(GV_PB_SIGNAL_TYPE);
   GlobalVariableDel(GV_PB_ENTRY_PRICE);
   GlobalVariableDel(GV_PB_STOP_LOSS);
   GlobalVariableDel(GV_PB_TAKE_PROFIT);
   GlobalVariableDel(GV_PB_EXPIRY_TIME);
   GlobalVariableDel(GV_PB_PATTERN_TYPE);
}

void CheckPullbackAndEnter()
{
   if(TimeCurrent() > GlobalVariableGet(GV_PB_EXPIRY_TIME))
   {
      ClearPendingPullback();
      return;
   }

   ENUM_ORDER_TYPE signalType = (ENUM_ORDER_TYPE)GlobalVariableGet(GV_PB_SIGNAL_TYPE);
   double entryPrice = GlobalVariableGet(GV_PB_ENTRY_PRICE);
   double sl = GlobalVariableGet(GV_PB_STOP_LOSS);
   double tp = GlobalVariableGet(GV_PB_TAKE_PROFIT);
   int patternCode = (int)GlobalVariableGet(GV_PB_PATTERN_TYPE);
   string patternType = (patternCode == 1 ? "Full" : (patternCode == 2 ? "Opening" : "Closing"));

   string comment = "";
   if(signalType == ORDER_TYPE_BUY) comment = _Symbol + " Buy " + patternType + " " + EnumToString(_Period);
   else comment = _Symbol + " Sell " + patternType + " " + EnumToString(_Period);

   bool entry_hit = false;
   if(signalType == ORDER_TYPE_BUY && SymbolInfoDouble(_Symbol, SYMBOL_ASK) <= entryPrice) entry_hit = true;
   if(signalType == ORDER_TYPE_SELL && SymbolInfoDouble(_Symbol, SYMBOL_BID) >= entryPrice) entry_hit = true;

   if(entry_hit)
   {
      MqlTradeRequest request; MqlTradeResult result; ZeroMemory(request); ZeroMemory(result);
      request.action = TRADE_ACTION_DEAL; request.type = signalType;
      request.symbol = _Symbol; request.volume = Lots; request.price = SymbolInfoDouble(_Symbol, signalType == ORDER_TYPE_BUY ? SYMBOL_ASK : SYMBOL_BID);
      request.sl = sl; request.tp = tp; request.comment = comment; request.magic = MagicNumber;
      if(!m_trade.OrderSend(request, result)) { Print("MQL5 OrderSend error ", m_trade.ResultRetcode()); }
      ClearPendingPullback();
   }
}

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
