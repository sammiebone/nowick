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

//--- Global objects
CTrade m_trade;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Initialization of the trade object
   m_trade.SetExpertMagicNumber(MagicNumber);
   m_trade.SetMarginMode(); // Use the current symbol's margin mode

   //--- Check StopLevels
   int stops_level = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   if(StopLoss < stops_level)
      Print("StopLoss value of ", StopLoss, " is too small. Minimum is ", stops_level);
   if(TakeProfit1 < stops_level)
      Print("TakeProfit1 value of ", TakeProfit1, " is too small. Minimum is ", stops_level);
   if(TakeProfit2 < stops_level)
      Print("TakeProfit2 value of ", TakeProfit2, " is too small. Minimum is ", stops_level);
   if(TakeProfit3 < stops_level)
      Print("TakeProfit3 value of ", TakeProfit3, " is too small. Minimum is ", stops_level);

   //--- Check if lot size is valid for partial closing
   if(Lots < 0.03)
   {
      Print("Error: Lots size must be at least 0.03 for the partial close logic to work.");
      return(INIT_FAILED);
   }

   //--- Initialization successful
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   //--- Cleanup global variables on deinitialization
   string prefix = "NWEA_MQL5_State_";
   for(int i = GlobalVariablesTotal() - 1; i >= 0; i--)
   {
      string gv_name = GlobalVariableName(i);
      if(StringFind(gv_name, prefix, 0) == 0)
      {
         GlobalVariableDel(gv_name);
      }
   }
}

void ManageOpenTrades();

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- If a position exists, we switch to trade management mode
   if(PositionSelect(_Symbol))
   {
      ManageOpenTrades();
      return;
   }

   //--- Get rates data for analysis
   MqlRates rates[22]; // Get enough data for 20-bar volume average
   if(CopyRates(_Symbol, _Period, 0, 22, rates) < 22)
   {
      Print("Error copying rates, not enough bars for volume MA.");
      return;
   }
   // MQL5 default indexing: rates[0] is the current bar, rates[1] is the previous bar.

   //--- Get the current SMA value
   double sma_buffer[1];
   int sma_handle = iMA(_Symbol, _Period, SMAPeriod, 0, MODE_SMA, PRICE_CLOSE);
   if(sma_handle == INVALID_HANDLE || CopyBuffer(sma_handle, 0, 0, 1, sma_buffer) < 1)
   {
      Print("Error getting SMA value.");
      return;
   }
   double smaValue = sma_buffer[0];

   //--- Trend and Candle Logic
   bool isBearishTrend = rates[0].close < smaValue;
   bool isBullishTrend = rates[0].close > smaValue;

   //--- Volume Confirmation
   long total_volume = 0;
   for(int i = 2; i < 22; i++) { total_volume += rates[i].tick_volume; }
   double avgVolume = total_volume / 20.0;
   bool isVolumeConfirmed = rates[1].tick_volume > avgVolume * VolumeMultiplier;

   //--- Enhanced Candle Identification & Order Placement ---
   bool isBearish = rates[1].close < rates[1].open;
   bool isBullish = rates[1].close > rates[1].open;

   if((isBearish && isBearishTrend) || (isBullish && isBullishTrend))
   {
      // Define wick properties for the specific candle type
      bool topIsFlat = (isBullish ? (rates[1].high - rates[1].close) < _Point : (rates[1].high - rates[1].open) < _Point);
      bool bottomIsFlat = (isBullish ? (rates[1].open - rates[1].low) < _Point : (rates[1].close - rates[1].low) < _Point);

      // Define Marubozu variations
      bool isFull = topIsFlat && bottomIsFlat;
      bool isOpening = (isBullish && bottomIsFlat && !topIsFlat) || (isBearish && topIsFlat && !bottomIsFlat);
      bool isClosing = (isBullish && !bottomIsFlat && topIsFlat) || (isBearish && !topIsFlat && bottomIsFlat);

      // Check if any selected pattern is found
      bool patternFound = (TradeFullMarubozu && isFull) ||
                          (TradeOpeningMarubozu && isOpening) ||
                          (TradeClosingMarubozu && isClosing);

      if(patternFound && isVolumeConfirmed)
      {
         string patternType = (isFull ? "Full" : (isOpening ? "Opening" : "Closing"));
         if(!EnableParadoxStrategy)
         {
            // --- STANDARD MOMENTUM STRATEGY ---
            if (isBearish)
            {
               Print("MQL5: Bearish Momentum Signal Found. Type: ", patternType);
               double price = rates[1].high;
               double sl = price + StopLoss * _Point;
               double tp = price - TakeProfit3 * _Point;
               MqlTradeRequest request; MqlTradeResult result; ZeroMemory(request); ZeroMemory(result);
               request.action = TRADE_ACTION_PENDING; request.symbol = _Symbol; request.volume = Lots;
               request.type = ORDER_TYPE_SELL_LIMIT; request.price = price; request.sl = sl; request.tp = tp;
               request.comment = _Symbol + " Sell " + patternType + " " + EnumToString(_Period); request.magic = MagicNumber;
               if(!m_trade.OrderSend(request, result)) { Print("MQL5: OrderSend error ", m_trade.ResultRetcode(), " - ", m_trade.ResultComment()); }
            }
            if (isBullish)
            {
               Print("MQL5: Bullish Momentum Signal Found. Type: ", patternType);
               double price = rates[1].low;
               double sl = price - StopLoss * _Point;
               double tp = price + TakeProfit3 * _Point;
               MqlTradeRequest request; MqlTradeResult result; ZeroMemory(request); ZeroMemory(result);
               request.action = TRADE_ACTION_PENDING; request.symbol = _Symbol; request.volume = Lots;
               request.type = ORDER_TYPE_BUY_LIMIT; request.price = price; request.sl = sl; request.tp = tp;
               request.comment = _Symbol + " Buy " + patternType + " " + EnumToString(_Period); request.magic = MagicNumber;
               if(!m_trade.OrderSend(request, result)) { Print("MQL5: OrderSend error ", m_trade.ResultRetcode(), " - ", m_trade.ResultComment()); }
            }
         }
         else
         {
            // --- PARADOX (MEAN-REVERSION) STRATEGY ---
            if (isBearish)
            {
               Print("MQL5: Paradox Strategy Signal Found. Type: ", patternType);
               double price = rates[1].high;
               double sl = rates[1].low - (SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point);
               double tp = price + TakeProfit3 * _Point;
               MqlTradeRequest request; MqlTradeResult result; ZeroMemory(request); ZeroMemory(result);
               request.action = TRADE_ACTION_PENDING; request.symbol = _Symbol; request.volume = Lots;
               request.type = ORDER_TYPE_BUY_STOP; request.price = price; request.sl = sl; request.tp = tp;
               request.comment = _Symbol + " Paradox Buy " + patternType + " " + EnumToString(_Period); request.magic = MagicNumber;
               if(!m_trade.OrderSend(request, result)) { Print("MQL5: OrderSend error ", m_trade.ResultRetcode(), " - ", m_trade.ResultComment()); }
            }
         }
      }
   }
}
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Manage Open Trades                                               |
//+------------------------------------------------------------------+
void ManageOpenTrades()
{
   // --- Ensure we have a position selected for the current symbol ---
   if(!PositionSelect(_Symbol))
      return;

   // --- Make sure the position was opened by this EA ---
   if(PositionGetInteger(POSITION_MAGIC) != MagicNumber)
      return;

   long position_id = PositionGetInteger(POSITION_IDENTIFIER);
   long position_type = PositionGetInteger(POSITION_TYPE);
   double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
   double current_profit = PositionGetDouble(POSITION_PROFIT);
   double current_volume = PositionGetDouble(POSITION_VOLUME);

   // --- State Management ---
   string gv_name = "NWEA_MQL5_State_" + (string)position_id;
   int stage = (int)GlobalVariableGet(gv_name);
   if(stage == 0) stage = 1;

   // --- Stage 1: Check for TP1 and move to Breakeven ---
   if(stage == 1)
   {
      bool tp1_hit = false;
      if(position_type == POSITION_TYPE_BUY && SymbolInfoDouble(_Symbol, SYMBOL_BID) >= open_price + TakeProfit1 * _Point)
         tp1_hit = true;
      if(position_type == POSITION_TYPE_SELL && SymbolInfoDouble(_Symbol, SYMBOL_ASK) <= open_price - TakeProfit1 * _Point)
         tp1_hit = true;

      if(tp1_hit)
      {
         Print("MQL5: TP1 hit for position #", position_id);
         // 1. Partial close (one third)
         double lotsToClose = NormalizeDouble(Lots / 3.0, 2);
         if(lotsToClose > 0 && current_volume > lotsToClose)
         {
            Print("MQL5: Closing ", lotsToClose, " lots for position #", position_id);
            if(position_type == POSITION_TYPE_BUY)
               m_trade.Sell(lotsToClose, _Symbol);
            else
               m_trade.Buy(lotsToClose, _Symbol);
         }

         // 2. Move SL to Breakeven
         double newSL = 0;
         if(position_type == POSITION_TYPE_BUY)
            newSL = NormalizeDouble(open_price + BreakevenPips * _Point, _Digits);
         else // POSITION_TYPE_SELL
            newSL = NormalizeDouble(open_price - BreakevenPips * _Point, _Digits);

         Print("MQL5: Moving SL to breakeven for position #", position_id, ". New SL: ", newSL);
         m_trade.PositionModify(_Symbol, newSL, PositionGetDouble(POSITION_TP));

         // 4. Update state to Stage 2
         GlobalVariableSet(gv_name, 2);
      }
   }

   // --- Stage 2: Check for TP2 ---
   if(stage == 2)
   {
      bool tp2_hit = false;
      if(position_type == POSITION_TYPE_BUY && SymbolInfoDouble(_Symbol, SYMBOL_BID) >= open_price + TakeProfit2 * _Point)
         tp2_hit = true;
      if(position_type == POSITION_TYPE_SELL && SymbolInfoDouble(_Symbol, SYMBOL_ASK) <= open_price - TakeProfit2 * _Point)
         tp2_hit = true;

      if(tp2_hit)
      {
         Print("MQL5: TP2 hit for position #", position_id);
         // Partial close (one third of original lots)
         double lotsToClose = NormalizeDouble(Lots / 3.0, 2);
         if(lotsToClose > 0 && current_volume > lotsToClose)
         {
            Print("MQL5: Closing ", lotsToClose, " lots for position #", position_id);
            if(position_type == POSITION_TYPE_BUY)
               m_trade.Sell(lotsToClose, _Symbol);
            else
               m_trade.Buy(lotsToClose, _Symbol);
         }
         else // Close the rest of the position
         {
            Print("MQL5: Closing remaining ", current_volume, " lots for position #", position_id);
            if(position_type == POSITION_TYPE_BUY)
               m_trade.Sell(current_volume, _Symbol);
            else
               m_trade.Buy(current_volume, _Symbol);
         }

         // Update state to Stage 3 (final stage)
         GlobalVariableSet(gv_name, 3);
      }
   }
}
//+------------------------------------------------------------------+
