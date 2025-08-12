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
input double   Lots        = 0.01;    // Lots size
input int      StopLoss    = 50;      // Stop Loss in pips
input int      TakeProfit  = 100;     // Take Profit in pips
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
   if(TakeProfit > 0 && TakeProfit < stopLevel)
   {
      Print("Error: TakeProfit value is too small. Please set a value greater than ", stopLevel);
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
   //--- Cleanup code can be placed here
}

// Forward declaration
bool DoesOrderExist();

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- Run only once per new bar to avoid duplicate trades
   static datetime lastBarTime = 0;
   if(lastBarTime == Time[0])
      return;
   lastBarTime = Time[0];

   //--- Do not trade if an order for this EA already exists on the current symbol
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
         //--- Place Sell Limit Order at the top of the candle
         double price = NormalizeDouble(High[1], _Digits);
         double sl = NormalizeDouble(price + StopLoss * _Point, _Digits);
         double tp = NormalizeDouble(price - TakeProfit * _Point, _Digits);
         OrderSend(Symbol(), OP_SELLLIMIT, Lots, price, 3, sl, tp, "No Wick Sell", MagicNumber, 0, clrRed);
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
         //--- Place Buy Limit Order at the bottom of the candle
         double price = NormalizeDouble(Low[1], _Digits);
         double sl = NormalizeDouble(price - StopLoss * _Point, _Digits);
         double tp = NormalizeDouble(price + TakeProfit * _Point, _Digits);
         OrderSend(Symbol(), OP_BUYLIMIT, Lots, price, 3, sl, tp, "No Wick Buy", MagicNumber, 0, clrBlue);
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
