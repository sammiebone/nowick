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
input int      SMAPeriod   = 50;      // SMA Period
input double   Lots        = 1.0;     // Lots size
input int      StopLoss    = 100;     // Stop Loss in pips
input int      TakeProfit1 = 50;      // Take Profit 1 in pips
input int      TakeProfit2 = 100;     // Take Profit 2 in pips
input int      TakeProfit3 = 150;     // Take Profit 3 in pips
input int      BreakevenPips = 10;    // Pips to add for breakeven SL
input int      MagicNumber = 12345;   // Magic Number

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Check StopLoss and TakeProfit values against server's StopLevel
   double stopLevel = MarketInfo(Symbol(), MODE_STOPLEVEL);
   if(StopLoss > 0 && StopLoss < stopLevel)
   {
      Print("Error: StopLoss value is too small. Please set a value greater than ", stopLevel);
      return(INIT_FAILED);
   }
   if(TakeProfit1 > 0 && TakeProfit1 < stopLevel)
   {
      Print("Error: TakeProfit1 value is too small. Please set a value greater than ", stopLevel);
      return(INIT_FAILED);
   }
   if(TakeProfit2 > 0 && TakeProfit2 < stopLevel)
   {
      Print("Error: TakeProfit2 value is too small. Please set a value greater than ", stopLevel);
      return(INIT_FAILED);
   }
   if(TakeProfit3 > 0 && TakeProfit3 < stopLevel)
   {
      Print("Error: TakeProfit3 value is too small. Please set a value greater than ", stopLevel);
      return(INIT_FAILED);
   }

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
   string prefix = "NWEA_State_";
   for(int i = GlobalVariablesTotal() - 1; i >= 0; i--)
   {
      string gv_name = GlobalVariableName(i);
      if(StringFind(gv_name, prefix, 0) == 0)
      {
         GlobalVariableDel(gv_name);
      }
   }
}

// Forward declarations
bool DoesOrderExist();
void ManageOpenTrades();

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- Manage existing trades on every tick
   if(OrdersTotal() > 0)
   {
      ManageOpenTrades();
   }

   //--- Look for new trades only on a new bar
   static datetime lastBarTime = 0;
   if(lastBarTime == Time[0])
      return;
   lastBarTime = Time[0];

   //--- Do not open new trade if one already exists for this EA
   if(DoesOrderExist())
      return;

   //--- Trend Identification using Simple Moving Average
   double smaValue = iMA(NULL, 0, SMAPeriod, 0, MODE_SMA, PRICE_CLOSE, 0);

   bool isBearishTrend = Close[0] < smaValue;
   bool isBullishTrend = Close[0] > smaValue;

   //--- Candle Identification & Order Placement
   // We analyze the most recently closed candle (index 1)

   // Bearish case: In a bearish trend, find a bearish candle with no top wick.
   if (isBearishTrend)
   {
      bool isBearishCandle = Close[1] < Open[1];
      // Using a small tolerance for floating point comparison
      bool noTopWick = (High[1] - Open[1]) < _Point;

      if (isBearishCandle && noTopWick)
      {
         Print("Bearish trend detected.");
         Print("Bearish no-wick candle found. Time: ", Time[1], " O:", Open[1], " H:", High[1], " L:", Low[1], " C:", Close[1]);
         //--- Place Sell Limit Order at the top of the candle
         double price = NormalizeDouble(High[1], _Digits);
         double sl = NormalizeDouble(price + StopLoss * _Point, _Digits);
         double tp = NormalizeDouble(price - TakeProfit3 * _Point, _Digits);
         Print("Placing Sell Limit. Price: ", price, " SL: ", sl, " TP: ", tp);
         string comment = Symbol() + " No Wick Sell " + (string)Period();
         int ticket = OrderSend(Symbol(), OP_SELLLIMIT, Lots, price, 3, sl, tp, comment, MagicNumber, 0, clrRed);
         if(ticket < 0)
         {
            Print("Error sending sell limit order: ", GetLastError());
         }
      }
   }

   // Bullish case: In a bullish trend, find a bullish candle with no bottom wick.
   if (isBullishTrend)
   {
      bool isBullishCandle = Close[1] > Open[1];
      // Using a small tolerance for floating point comparison
      bool noBottomWick = (Open[1] - Low[1]) < _Point;

      if (isBullishCandle && noBottomWick)
      {
         Print("Bullish trend detected.");
         Print("Bullish no-wick candle found. Time: ", Time[1], " O:", Open[1], " H:", High[1], " L:", Low[1], " C:", Close[1]);
         //--- Place Buy Limit Order at the bottom of the candle
         double price = NormalizeDouble(Low[1], _Digits);
         double sl = NormalizeDouble(price - StopLoss * _Point, _Digits);
         double tp = NormalizeDouble(price + TakeProfit3 * _Point, _Digits);
         Print("Placing Buy Limit. Price: ", price, " SL: ", sl, " TP: ", tp);
         string comment = Symbol() + " No Wick Buy " + (string)Period();
         int ticket = OrderSend(Symbol(), OP_BUYLIMIT, Lots, price, 3, sl, tp, comment, MagicNumber, 0, clrBlue);
         if(ticket < 0)
         {
            Print("Error sending buy limit order: ", GetLastError());
         }
      }
   }
}
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Check for existing orders                                        |
//+------------------------------------------------------------------+
bool DoesOrderExist()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
      {
         if(OrderSymbol() == Symbol() && OrderMagicNumber() == MagicNumber)
         {
            return(true);
         }
      }
   }
   return(false);
}
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Manage Open Trades                                               |
//+------------------------------------------------------------------+
void ManageOpenTrades()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;

      if(OrderSymbol() != Symbol() || OrderMagicNumber() != MagicNumber)
         continue;

      int ticket = OrderTicket();
      string gv_name = "NWEA_State_" + (string)ticket;
      // GlobalVariableGet returns 0.0 if the variable does not exist. We'll treat 0 or 1 as Stage 1.
      int stage = (int)GlobalVariableGet(gv_name);
      if(stage == 0) stage = 1;

      // --- Stage 1: Check for TP1 and move to Breakeven ---
      if(stage == 1)
      {
         bool tp1_hit = false;
         if(OrderType() == OP_BUY && Bid >= OrderOpenPrice() + TakeProfit1 * _Point)
            tp1_hit = true;
         if(OrderType() == OP_SELL && Ask <= OrderOpenPrice() - TakeProfit1 * _Point)
            tp1_hit = true;

         if(tp1_hit)
         {
            Print("TP1 hit for order #", ticket);
            // 1. Partial close (one third)
            double lotsToClose = NormalizeDouble(Lots / 3.0, 2);
            if(lotsToClose > 0 && OrderLots() > lotsToClose)
            {
               Print("Closing ", lotsToClose, " lots for order #", ticket);
               if(!OrderClose(ticket, lotsToClose, OrderClosePrice(), 3))
                  Print("Error closing partial order for TP1: ", GetLastError());
            }

            // Re-select order to get updated info
            if(!OrderSelect(ticket, SELECT_BY_TICKET)) continue;

            // 2. Move SL to Breakeven
            double newSL = 0;
            if(OrderType() == OP_BUY)
               newSL = NormalizeDouble(OrderOpenPrice() + BreakevenPips * _Point, _Digits);
            else // OP_SELL
               newSL = NormalizeDouble(OrderOpenPrice() - BreakevenPips * _Point, _Digits);

            // 3. Modify the Stop Loss
            Print("Moving SL to breakeven for order #", ticket, ". New SL: ", newSL);
            if(!OrderModify(ticket, OrderOpenPrice(), newSL, OrderTakeProfit(), 0))
               Print("Error modifying SL for breakeven: ", GetLastError());

            // 4. Update state to Stage 2
            GlobalVariableSet(gv_name, 2);

            // Exit loop for this tick as we have modified the trade
            return;
         }
      }

      // --- Stage 2: Check for TP2 ---
      if(stage == 2)
      {
         bool tp2_hit = false;
         if(OrderType() == OP_BUY && Bid >= OrderOpenPrice() + TakeProfit2 * _Point)
            tp2_hit = true;
         if(OrderType() == OP_SELL && Ask <= OrderOpenPrice() - TakeProfit2 * _Point)
            tp2_hit = true;

         if(tp2_hit)
         {
            Print("TP2 hit for order #", ticket);
            // Partial close (one third of original lots)
            double lotsToClose = NormalizeDouble(Lots / 3.0, 2);
            if(lotsToClose > 0 && OrderLots() > lotsToClose)
            {
               Print("Closing ", lotsToClose, " lots for order #", ticket);
               if(!OrderClose(ticket, lotsToClose, OrderClosePrice(), 3))
                  Print("Error closing partial order for TP2: ", GetLastError());
            }
            else // Close the rest of the position
            {
               Print("Closing remaining ", OrderLots(), " lots for order #", ticket);
               if(!OrderClose(ticket, OrderLots(), OrderClosePrice(), 3))
                  Print("Error closing remaining order for TP2: ", GetLastError());
            }

            // Update state to Stage 3 (final stage)
            GlobalVariableSet(gv_name, 3);

            // Exit loop for this tick
            return;
         }
      }
   }
}
//+------------------------------------------------------------------+
