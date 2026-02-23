//+------------------------------------------------------------------+
//|   1_SingleRegime_EURUSD_EA_SlopeFilter_M5-TEST_rangeAndTrend.mq5 |
//|                  Copyright 2025, Developed by Salvatore La Rocca |
//|                                               weHope by Laysatek |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, Sviluppato per Utente AI"
#property link      "https://www.google.com"
#property version   "2.1" // --- MODIFICATO --- Versione con Filtro Pendenza MA e Gestione Multi-Regime
#property strict

#include <Trade\Trade.mqh>
#resource "rf_eurusd_h1.onnx" as uchar ExtModel[]


// Converte "HH:MM" in minuti da mezzanotte
int ParseHHMMToMinutes(const string hhmm)
  {
// Assumes "HH:MM" 24h
   int h = (int)StringToInteger(StringSubstr(hhmm,0,2));
   int m = (int)StringToInteger(StringSubstr(hhmm,3,2));
   return (h*60 + m) % (24*60);
  }

// True se siamo nella finestra "cutoff" verso la fine sessione
bool IsNearSessionEnd(const int cutoffMin)
  {
   if(!InpUseSessionFilter)
      return false;

   const int startMin = ParseHHMMToMinutes(InpSessionStart);
   const int endMin   = ParseHHMMToMinutes(InpSessionEnd);

   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now);
   const int curMin = now.hour*60 + now.min;

   int target = endMin - cutoffMin;
   if(target < 0)
      target += 1440;

   if(startMin <= endMin) // sessione nello stesso giorno
      return (curMin >= target && curMin <= endMin);
   else                   // sessione oltre mezzanotte
      return (curMin >= target || curMin <= endMin);
  }

// Chiudi tutte le posizioni del simbolo con il nostro Magic X minuti prima della fine
void ClosePositionsAtSessionEndBuffer()
  {
if(!InpUseSessionFilter) return;
if(!IsNearSessionEnd(InpEOD_CloseBufferMin)) return;

if(!PositionSelect(_Symbol)) return;
if((ulong)PositionGetInteger(POSITION_MAGIC)!=(ulong)InpMagicNumber) return;

double vol = PositionGetDouble(POSITION_VOLUME);
if(vol <= 0.0) return;

if(!trade.PositionClose(_Symbol))
   Print("EOD close failed: ", _LastError);

}




struct TrendRiskInfo { ulong ticket; double riskPoints; };
TrendRiskInfo g_trendRisk[]; // storage dinamico

struct PartialCloseState
  {
   ulong             ticket;
   double            initialVolume;
   bool              partialDone;
  };

PartialCloseState g_partialCloseStates[];

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void StoreTrendRisk(const ulong ticket, const double riskPoints)
  {
   int n = ArraySize(g_trendRisk);
   ArrayResize(g_trendRisk, n+1);
   g_trendRisk[n].ticket     = ticket;
   g_trendRisk[n].riskPoints = MathMax(1.0, riskPoints);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool GetTrendRisk(const ulong ticket, double &riskPoints)
  {
   for(int i=0; i<ArraySize(g_trendRisk); ++i)
      if(g_trendRisk[i].ticket == ticket)
        {
         riskPoints = g_trendRisk[i].riskPoints;
         return true;
        }
   return false;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void PurgeTrendRiskForClosed()
{
   // Se NON c'è posizione su _Symbol → pulisci tutto lo storage
   if(!PositionSelect(_Symbol))
   {
      ArrayResize(g_trendRisk, 0);
      return;
   }

   // Tieni solo il ticket della posizione corrente su _Symbol (NETTING = una sola posizione)
   ulong curTicket = (ulong)PositionGetInteger(POSITION_TICKET);
   for(int i=ArraySize(g_trendRisk)-1; i>=0; --i)
   {
      if(g_trendRisk[i].ticket != curTicket)
         ArrayRemove(g_trendRisk, i, 1);
   }
}

// ======================= LOT SIZING & MARGINE (inserito da patch) =======================

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double GetTickValueProfit()
  {
   double v = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_PROFIT);
   if(v <= 0.0)
      v = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   return v;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double NormalizeVolumeToStep(const double vol)
  {
   const double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   const double maxv = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step <= 0.0)
      return MathMin(maxv, vol);
   double v = MathFloor(vol / step) * step;
   if(v > maxv)
      v = maxv;
   if(v < 0.0)
      v = 0.0;
   return v;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double NormalizeVolumeToStepNearest(const double vol)
  {
   const double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   const double minv = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   const double maxv = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step <= 0.0)
      return MathMax(minv, MathMin(maxv, vol));
   double v = MathRound(vol / step) * step;
   v = MathMax(minv, MathMin(maxv, v));
   return v;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int FindPartialCloseStateIndex(const ulong ticket)
  {
   for(int i = 0; i < ArraySize(g_partialCloseStates); ++i)
      if(g_partialCloseStates[i].ticket == ticket)
         return i;
   return -1;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void UpsertPartialCloseState(const ulong ticket, const double currentVolume)
  {
   if(ticket == 0 || currentVolume <= 0.0)
      return;

   int idx = FindPartialCloseStateIndex(ticket);
   if(idx == -1)
     {
      int n = ArraySize(g_partialCloseStates);
      ArrayResize(g_partialCloseStates, n + 1);
      g_partialCloseStates[n].ticket = ticket;
      g_partialCloseStates[n].initialVolume = currentVolume;
      g_partialCloseStates[n].partialDone = false;
      return;
     }

   if(g_partialCloseStates[idx].initialVolume <= 0.0)
      g_partialCloseStates[idx].initialVolume = currentVolume;

   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0)
      step = 0.0000001;
   if(currentVolume < (g_partialCloseStates[idx].initialVolume - (step * 0.5)))
      g_partialCloseStates[idx].partialDone = true;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double GetInitialVolumeForTicket(const ulong ticket, const double fallbackVolume)
  {
   int idx = FindPartialCloseStateIndex(ticket);
   if(idx < 0 || g_partialCloseStates[idx].initialVolume <= 0.0)
      return fallbackVolume;
   return g_partialCloseStates[idx].initialVolume;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool IsPartialCloseDone(const ulong ticket)
  {
   int idx = FindPartialCloseStateIndex(ticket);
   if(idx < 0)
      return false;
   return g_partialCloseStates[idx].partialDone;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void MarkPartialCloseDone(const ulong ticket)
  {
   int idx = FindPartialCloseStateIndex(ticket);
   if(idx >= 0)
      g_partialCloseStates[idx].partialDone = true;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void PurgeClosedPartialCloseStates()
  {
   if(!PositionSelect(_Symbol))
     {
      ArrayResize(g_partialCloseStates, 0);
      return;
     }

   ulong curTicket = (ulong)PositionGetInteger(POSITION_TICKET);
   for(int i = ArraySize(g_partialCloseStates)-1; i >= 0; --i)
     {
      if(g_partialCloseStates[i].ticket != curTicket)
         ArrayRemove(g_partialCloseStates, i, 1);
     }
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool MoveStopToBreakEven(const ENUM_POSITION_TYPE posType, const double openPrice)
  {
   if(!PositionSelect(_Symbol))
      return false;

   double currentSL = PositionGetDouble(POSITION_SL);
   double currentTP = PositionGetDouble(POSITION_TP);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   int    stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minStop = MathMax((double)InpMinStopLossPoints, (double)stopsLevel) * _Point;

   double beSL = openPrice;
   if(posType == POSITION_TYPE_BUY)
     {
      if(beSL > bid - minStop)
         return false;
      if(currentSL >= beSL - (0.1 * _Point))
         return true;
     }
   else
      if(posType == POSITION_TYPE_SELL)
        {
         if(beSL < ask + minStop)
            return false;
         if(currentSL <= beSL + (0.1 * _Point) && currentSL > 0.0)
            return true;
        }

   if(!trade.PositionModify(_Symbol, beSL, currentTP))
     {
      Print("BE modify failed: ", _LastError);
      return false;
     }

   return true;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void ManagePartialCloseAtOneR(const ulong ticket, const ENUM_POSITION_TYPE posType, const double openPrice, const double riskPoints)
  {
   if(!InpUsePartialClose || ticket == 0 || riskPoints <= 0.0)
      return;
   if(!PositionSelectByTicket(ticket))
      return;

   double currentVolume = PositionGetDouble(POSITION_VOLUME);
   if(currentVolume <= 0.0)
      return;

   UpsertPartialCloseState(ticket, currentVolume);

   double currentPrice = (posType == POSITION_TYPE_BUY)
                         ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                         : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double profitPoints = (posType == POSITION_TYPE_BUY)
                         ? (currentPrice - openPrice) / _Point
                         : (openPrice - currentPrice) / _Point;

   if(!IsPartialCloseDone(ticket) && profitPoints >= riskPoints)
     {
      const double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      const double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

      double initialVolume = GetInitialVolumeForTicket(ticket, currentVolume);
      double halfVolume = NormalizeVolumeToStepNearest(initialVolume * 0.5);
      if(halfVolume > currentVolume)
         halfVolume = NormalizeVolumeToStepNearest(currentVolume * 0.5);
      if((currentVolume - halfVolume) < minLot)
         halfVolume = NormalizeVolumeToStepNearest(currentVolume - minLot);
      if(halfVolume > currentVolume - minLot)
         halfVolume = currentVolume - minLot;

      if(step > 0.0)
         halfVolume = MathFloor(halfVolume / step) * step;

      if(halfVolume >= minLot && halfVolume > 0.0 && (currentVolume - halfVolume) >= minLot)
        {
         if(trade.PositionClosePartial(ticket, halfVolume))
           {
            MarkPartialCloseDone(ticket);
           }
         else
           {
            Print("Partial close failed: ", _LastError);
           }
        }
      else
        {
         // Evita retry inutili su volumi incompatibili e prova comunque a proteggere a BE.
         MarkPartialCloseDone(ticket);
        }
     }

   if(IsPartialCloseDone(ticket))
      MoveStopToBreakEven(posType, openPrice);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double CalcVolumeByRisk(const double slDistanceInPrice, const double riskPercent)
  {
   if(riskPercent <= 0.0 || slDistanceInPrice <= 0.0)
      return 0.0;

   const double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   const double riskMoney = balance * (riskPercent / 100.0);

   const double tickValue = GetTickValueProfit();
   const double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0.0 || tickSize <= 0.0)
      return 0.0;

   const double valuePerLotAtSL = (slDistanceInPrice / tickSize) * tickValue;
   if(valuePerLotAtSL <= 0.0)
      return 0.0;

   double rawLots = riskMoney / valuePerLotAtSL;
   return NormalizeVolumeToStep(rawLots);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double CapVolumeByMargin(double requestedLots, const ENUM_ORDER_TYPE type, const double price, const double safety = 0.95)
  {
   requestedLots = MathMax(0.0, requestedLots);
   if(requestedLots <= 0.0)
      return 0.0;

   double marginPer1Lot = 0.0;
   if(!OrderCalcMargin(type, _Symbol, 1.0, price, marginPer1Lot) || marginPer1Lot <= 0.0)
     {
      return 0.0;
     }

   const double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(freeMargin <= 0.0)
      return 0.0;

   const double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLotsByMargin = (freeMargin * safety) / marginPer1Lot;
   if(maxLotsByMargin < minLot)
      return 0.0;

   double capped = MathMin(requestedLots, maxLotsByMargin);
   capped = NormalizeVolumeToStep(capped);
   if(capped < minLot)
      return 0.0;

   return capped;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool IsSymbolTradableNow()
  {
   long mode = (long)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if(mode == SYMBOL_TRADE_MODE_DISABLED)
      return false;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
      return false;
   if(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) <= 0)
      return false;
   return true;
  }

// ======================= FINE BLOCCO LOT SIZING & MARGINE =======================
// --- Oggetti globali
CTrade trade;

struct RangeRiskRecord
  {
   ulong             ticket;
   double            distance;
  };

RangeRiskRecord rangeRiskRecords[];

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int FindRangeRiskRecordIndex(const ulong ticket)
  {
   int size = ArraySize(rangeRiskRecords);
   for(int i = 0; i < size; ++i)
     {
      if(rangeRiskRecords[i].ticket == ticket)
         return i;
     }
   return -1;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void StoreRangeRiskDistance(const ulong ticket, const double distance)
  {
   if(ticket == 0 || distance <= 0.0)
      return;

   int idx = FindRangeRiskRecordIndex(ticket);
   if(idx == -1)
     {
      int newIndex = ArraySize(rangeRiskRecords);
      ArrayResize(rangeRiskRecords, newIndex + 1);
      rangeRiskRecords[newIndex].ticket = ticket;
      rangeRiskRecords[newIndex].distance = distance;
     }
   else
     {
      rangeRiskRecords[idx].distance = distance;
     }
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool GetRangeRiskDistance(const ulong ticket, double &distance)
  {
   int idx = FindRangeRiskRecordIndex(ticket);
   if(idx == -1)
      return false;

   distance = rangeRiskRecords[idx].distance;
   return true;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void RemoveRangeRiskDistance(const ulong ticket)
  {
   int size = ArraySize(rangeRiskRecords);
   if(size <= 0)
      return;

   for(int i = 0; i < size; ++i)
     {
      if(rangeRiskRecords[i].ticket == ticket)
        {
         int lastIndex = size - 1;
         if(i != lastIndex)
            rangeRiskRecords[i] = rangeRiskRecords[lastIndex];
         ArrayResize(rangeRiskRecords, lastIndex);
         return;
        }
     }
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void PurgeClosedRangeRiskRecords()
  {
   int i = 0;
   while(i < ArraySize(rangeRiskRecords))
     {
      ulong ticket = rangeRiskRecords[i].ticket;
      if(ticket == 0 || !PositionSelectByTicket(ticket))
        {
         RemoveRangeRiskDistance(ticket);
         continue;
        }
      ++i;
     }
  }


// --- Intraday EOD controls ---
input int    InpEOD_CloseBufferMin = 5;     // Minuti prima della fine sessione: chiudi posizioni
input int    InpEOD_EntryCutoffMin = 15;    // Minuti prima della fine sessione: non aprire nuovi trade


// --- Parametri Globali
input group           "Global Settings"
input double          InpRiskPercent       = 1.0;         // InpRiskPercent Rischio percentuale per trade (riallineato ai test utente)
input bool            InpUsePartialClose   = true;        // Use 50% Partial Close & Break-Even at 1R
input ulong           InpMagicNumber       = 13579;       // InpMagicNumber Magic Number predefinito per i trade monitorati
input uint            InpSlippage          = 10;          // InpSlippage Slippage massimo in punti
input bool            InpDataCollectionMode = false;      // Data Collection Mode (Blind EA + CSV)

// --- Trade Quality Gate (robustezza live) ---
input group           "Trade Quality Gate"
input int             InpMaxSpreadPoints      = 20;   // points
input int             InpMinATRPoints         = 150;  // --- PHASE 1 FIX --- H1 baseline ATR gate (points)
input bool            InpLogBlockedEntries    = true;
input string          InpEntryLogFileName     = "EA_entry_log.csv";

// --- MODIFICATO: Parametri Filtro Regime (Pendenza Media Mobile) ---
input group           "Market Regime Filter"
input int             InpMA_Filter_Period    = 220;         // InpMA_Filter_Period Periodo della media mobile per il filtro di regime
input ENUM_MA_METHOD  InpMA_Filter_Method    = MODE_EMA;    // InpMA_Filter_Method Metodo della media mobile (SMA, EMA, etc.)
input ENUM_TIMEFRAMES InpRegime_Timeframe    = PERIOD_H4;   // --- PHASE 1 FIX --- HTF regime baseline for H1 execution
input int             InpMA_Slope_Period     = 20;          // InpMA_Slope_Period Barre da confrontare per il calcolo della pendenza
input int             InpMA_Slope_ATR_Period = 14;          // InpMA_Slope_ATR_Period--- NUOVO --- Periodo ATR per normalizzare la pendenza
input double          InpMA_Slope_FlatThresh = 0.35;        // InpMA_Slope_FlatThresh--- NUOVO --- Soglia normalizzata sotto cui il mercato è considerato flat
input double          InpMA_Slope_TrendThresh= 0.8;         // InpMA_Slope_TrendThresh--- NUOVO --- Soglia normalizzata sopra cui il mercato è considerato in trend

// --- Parametri Logica TREND (Momentum Breakout)
input group           "Trend Strategy Settings"
input int             InpDonchian_Period   = 40;          // InpDonchian_Period Periodo del Canale di Donchian
input int             InpATR_Period_Trend  = 14;          // InpATR_Period_Trend Periodo ATR per la logica Trend
input double          InpSL_ATR_Multiplier_Trend = 3.25;  // InpSL_ATR_Multiplier_Trend Moltiplicatore ATR per lo Stop Loss (Trend)
input double          InpTS_ATR_Multiplier_Trend = 2.0;   // InpTS_ATR_Multiplier_Trend Moltiplicatore ATR per il TRAILING STOP (Trend)

// --- Trend Break-Even controls ---
input bool   InpTrend_UseBreakEven = true;  // InpTrend_UseBreakEven Abilita spostamento a BE per i trade Trend
input double InpTrend_BreakEvenRR  = 0.8;   // InpTrend_BreakEvenRR Quando profitto raggiunge R >= X
input double InpTrend_BE_Buffer_R  = 0.20;  // InpTrend_BE_Buffer_R Sposta SL a BE ± buffer*R (in R-units)

// --- Parametri Logica RANGE (Mean Reversion)
input group           "Range Strategy Settings"
input int             InpBB_Period         = 24;          // InpBB_Period Periodo delle Bande di Bollinger (riallineato ai test utente)
input double          InpBB_Deviation      = 2.3;         // InpBB_Deviation Deviazione delle Bande di Bollinger
input int             InpRSI_Period        = 14;          // InpRSI_Period Periodo dell'RSI
input double          InpRSI_Overbought    = 65.0;        // InpRSI_Overbought Livello Ipercomprato RSI
input double          InpRSI_Oversold      = 20.0;        // InpRSI_Oversold Livello Ipervenduto RSI
input int             InpATR_Period_Range  = 14;          // InpATR_Period_Range Periodo ATR per la logica Range
input double          InpSL_ATR_Multiplier_Range = 1.0;   // InpSL_ATR_Multiplier_Range Moltiplicatore ATR per lo Stop Loss (Range)
input double          InpTP_Multiplier_Range = 2.2;       // InpTP_Multiplier_Range--- MODIFICATO --- Rapporto TP meno ambizioso per aumentare l'hit-rate
input double          InpRange_BreakEvenRR = 0.7;         // InpRange_BreakEvenRR--- NUOVO --- Livello (in R) dove spostare lo stop a pareggio sui trade range
input double          InpRange_BE_Buffer   = 0.2;         // InpRange_BE_Buffer--- NUOVO --- Buffer in R oltre il punto di pareggio
input int             InpRange_MaxBarsInTrade = 36;       // InpRange_MaxBarsInTrade--- NUOVO --- Numero massimo di barre da mantenere un trade range aperto
input double          InpRange_ATR_VolatilityCap = 1.6;   // InpRange_ATR_VolatilityCap--- NUOVO --- Limite di volatilità (ATR corrente / ATR medio) per attivare la logica range

// --- NUOVO: Valvola di sicurezza per lo Stop Loss ---
input int             InpMinStopLossPoints = 150; // InpMinStopLossPoints --- Stop Loss minimo in Punti (es. 150 = 15 pips)

// --- NUOVO: Enumerazioni per la chiarezza del codice ---
enum ENUM_MARKET_REGIME
  {
   REGIME_UPTREND,       // Pendenza MA positiva oltre la soglia trend
   REGIME_DOWNTREND,     // Pendenza MA negativa oltre la soglia trend
   REGIME_FLAT,          // Pendenza normalizzata entro la zona neutra
   REGIME_TRANSITION     // --- NUOVO --- Zona di transizione: nessun nuovo trade
  };

enum ENUM_TRADE_DIRECTION
  {
   ALLOW_ANY,
   ALLOW_LONGS_ONLY,
   ALLOW_SHORTS_ONLY
  };

enum ENUM_DONCHIAN_MODE
  {
   DONCHIAN_UPPER, // Per il canale superiore
   DONCHIAN_LOWER  // Per il canale inferiore
  };

// --- Handles degli indicatori
int maFilterHandle; // --- NUOVO ---
int atrHandleSlope; // --- NUOVO --- ATR per normalizzare la pendenza
int atrHandleTrend;
int bbandsHandle;
int rsiHandle;
int atrHandleRange;
int ema220_handle;
int atr14_handle;
long onnx_handle = INVALID_HANDLE;
int g_onnx_output_size = 1;

// --- PHASE 1 FIX --- rimossi stato/contatori daily-cooldown tossici

// --- Ultimo regime e pendenza normalizzata ---
double g_lastSlopeNorm = 0.0;
ENUM_MARKET_REGIME g_lastRegime = REGIME_TRANSITION;

// --- NUOVO: Gestione sessioni e limiti ---
input group           "Session & Risk Controls"
input bool            InpUseSessionFilter   = true;        // --- NUOVO --- Abilita il filtro orario
input string          InpSessionStart       = "07:00";     // --- NUOVO --- Orario di inizio trading (HH:MM, server)
input string          InpSessionEnd         = "19:00";     // --- NUOVO --- Orario di fine trading (HH:MM, server)

// --- NUOVO: Prototipi delle funzioni helper ---
void ManageTrendPosition();
void ManageRangePosition();
bool RangeVolatilityFilter();
bool IsWithinTradingSession();
int  ParseTimeToMinutes(const string timeStr);
int GetSpreadPoints();
int GetATRPointsFromHandle(int atrHandle, int shift=1);
bool PassTradeQualityGate(string contextTag, int atrHandle, double slopeNorm, ENUM_MARKET_REGIME regime, string &blockReason);
void AppendCsvLog(string type, string contextTag, ENUM_MARKET_REGIME regime, double slopeNorm, int atrPoints, int spreadPoints, string reason);
string RegimeToString(ENUM_MARKET_REGIME regime);
int GetMLPrediction(bool is_trend, bool is_long);
bool BuildTradeFeatures(bool is_trend, bool is_long, float &features[]);
void ExportMLDataset(ulong ticket, const float &features[]);

//+------------------------------------------------------------------+
//| Funzione di Inizializzazione dell'Expert                       |
//+------------------------------------------------------------------+
int OnInit()
  {
//--- Inizializzazione oggetto di trading
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetDeviationInPoints(InpSlippage);

   Print(AccountInfoInteger(ACCOUNT_MARGIN_MODE));

//--- MODIFICATO: Ottenimento handle del filtro MA
   maFilterHandle = iMA(_Symbol, InpRegime_Timeframe, InpMA_Filter_Period, 0, InpMA_Filter_Method, PRICE_CLOSE); // --- MODIFICATO --- filtro su TF superiore
   if(maFilterHandle == INVALID_HANDLE)
     {
      printf("Errore nell'ottenere l'handle MA Filter: %d", GetLastError());
      return(INIT_FAILED);
     }

   atrHandleSlope = iATR(_Symbol, InpRegime_Timeframe, InpMA_Slope_ATR_Period); // --- NUOVO --- handle ATR per normalizzare la pendenza
   if(atrHandleSlope == INVALID_HANDLE)
     {
      printf("Errore nell'ottenere l'handle ATR (Slope): %d", GetLastError());
      return(INIT_FAILED);
     }

   atrHandleTrend = iATR(_Symbol, _Period, InpATR_Period_Trend);
   if(atrHandleTrend == INVALID_HANDLE)
     {
      printf("Errore nell'ottenere l'handle ATR (Trend): %d", GetLastError());
      return(INIT_FAILED);
     }

   bbandsHandle = iBands(_Symbol, _Period, InpBB_Period, 0, InpBB_Deviation, PRICE_CLOSE);
   if(bbandsHandle == INVALID_HANDLE)
     {
      printf("Errore nell'ottenere l'handle Bollinger Bands: %d", GetLastError());
      return(INIT_FAILED);
     }

   rsiHandle = iRSI(_Symbol, _Period, InpRSI_Period, PRICE_CLOSE);
   if(rsiHandle == INVALID_HANDLE)
     {
      printf("Errore nell'ottenere l'handle RSI: %d", GetLastError());
      return(INIT_FAILED);
     }

   atrHandleRange = iATR(_Symbol, _Period, InpATR_Period_Range);
   if(atrHandleRange == INVALID_HANDLE)
     {
      printf("Errore nell'ottenere l'handle ATR (Range): %d", GetLastError());
      return(INIT_FAILED);
     }

   ema220_handle = iMA(_Symbol, _Period, 220, 0, MODE_EMA, PRICE_CLOSE);
   if(ema220_handle == INVALID_HANDLE)
     {
      printf("Errore nell'ottenere l'handle EMA220: %d", GetLastError());
      return(INIT_FAILED);
     }

   atr14_handle = iATR(_Symbol, _Period, 14);
   if(atr14_handle == INVALID_HANDLE)
     {
      printf("Errore nell'ottenere l'handle ATR14 (ML): %d", GetLastError());
      return(INIT_FAILED);
     }

   //--- Inizializzazione ONNX
   onnx_handle = OnnxCreateFromBuffer(ExtModel, ONNX_DEFAULT);
   if(onnx_handle == INVALID_HANDLE)
   {
      printf("Errore creazione handle ONNX da resource: %d", GetLastError());
      return(INIT_FAILED);
   }

   // Definiamo l'input: 1 riga, 9 colonne
   const long input_shape[] = {1, 9};
   if(!OnnxSetInputShape(onnx_handle, 0, input_shape))
   {
      printf("Errore set input shape ONNX [1,9]: %d", GetLastError());
      OnnxRelease(onnx_handle);
      onnx_handle = INVALID_HANDLE;
      return(INIT_FAILED);
   }

   // Definiamo l'unico output: 1 valore (l'etichetta 1 o 0)
   const long output_shape[] = {1};
   if(!OnnxSetOutputShape(onnx_handle, 0, output_shape))
   {
      PrintFormat("Errore OnnxSetOutputShape (label): %d", GetLastError());
      OnnxRelease(onnx_handle);
      onnx_handle = INVALID_HANDLE;
      return(INIT_FAILED);
   }

   // Impostiamo la dimensione dell'output a 1 (Abbiamo rimosso la probabilità)
   g_onnx_output_size = 1;

   printf("EA Multi-Regime v2.1 (Slope Filter) inizializzato con successo. ONNX filtro NUCLEARE attivo.");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Funzione di De-inizializzazione dell'Expert                    |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
//--- Rilascia gli handles degli indicatori
   IndicatorRelease(maFilterHandle); // --- MODIFICATO ---
   IndicatorRelease(atrHandleSlope); // --- NUOVO ---
   IndicatorRelease(atrHandleTrend);
   IndicatorRelease(bbandsHandle);
   IndicatorRelease(rsiHandle);
   IndicatorRelease(atrHandleRange);
   IndicatorRelease(ema220_handle);
   IndicatorRelease(atr14_handle);
   if(onnx_handle != INVALID_HANDLE)
     {
      OnnxRelease(onnx_handle);
      onnx_handle = INVALID_HANDLE;
     }
   printf("EA Multi-Regime de-inizializzato.");
  }

//+------------------------------------------------------------------+
//| Funzione principale dell'Expert (OnTick)                        |
//+------------------------------------------------------------------+
void OnTick()
  {
// --- EOD: chiudi posizioni qualche minuto prima della fine sessione ---
   ClosePositionsAtSessionEndBuffer();

   PurgeTrendRiskForClosed(); // pulizia storage rischio Trend

   PurgeClosedRangeRiskRecords(); // pulizia storage rischio Range

   // --- PHASE 1 FIX --- rimossa refresh daily counters tossica

   MqlRates rates[1];
   static datetime lastBarTime = 0;
   if(CopyRates(_Symbol, _Period, 0, 1, rates) < 1)
     {
      printf("Errore nella copia dei dati della barra");
      return;
     }
   if(rates[0].time == lastBarTime)
      return;
   lastBarTime = rates[0].time;

   if(PositionSelect(_Symbol))
     {
      if(PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
        {
         ManageOpenPosition();
         return;
        }
     }
   else
     {
      PurgeClosedRangeRiskRecords();
     }

   CheckForNewSignal();
  }

////+------------------------------------------------------------------+
////| Controlla le condizioni di mercato e cerca un nuovo segnale      |
////+------------------------------------------------------------------+
//void CheckForNewSignal()
//{
//    //--- Determina il regime di mercato
//    ENUM_MARKET_REGIME regime = GetMarketRegime();
//
//    //--- Applica la NUOVA logica difensiva ---
//    if(regime == REGIME_FLAT)
//    {
//        // Se il mercato è piatto, attiva la logica di Range (sia Long che Short)
//        CheckRangeSignal(ALLOW_ANY);
//    }
//    // Se il regime è UPTREND o DOWNTREND, non viene eseguita nessuna azione.
//    // L'EA rimane inattivo per proteggersi dai trend forti.
//}

//+------------------------------------------------------------------+
//| Controlla le condizioni di mercato e cerca un nuovo segnale      |
//+------------------------------------------------------------------+
void CheckForNewSignal()
  {
   if(!IsWithinTradingSession())
     {
      Print("Sessione fuori orario operativo. Nessun nuovo trade.");
      return;
     }

// Stop nuovi ingressi a ridosso della chiusura
   if(InpUseSessionFilter && IsNearSessionEnd(InpEOD_EntryCutoffMin))
     {
      Print("Skip new entries: near session end.");
      return; // nessun nuovo trade
     }

   double slopePointsPerBar;
// Dichiariamo una variabile per ricevere il valore della pendenza
   double slopeNormalized;

// Chiamiamo la funzione aggiornata, che ci darà sia il regime sia la pendenza
   ENUM_MARKET_REGIME regime = GetMarketRegime(slopePointsPerBar, slopeNormalized);
   g_lastSlopeNorm = slopeNormalized;
   g_lastRegime = regime;

// Usiamo StringFormat per creare un messaggio di log dettagliato e pulito
   string message;

   switch(regime)
     {
      case REGIME_UPTREND:
         message = StringFormat("Regime: UPTREND | slopePts=%.2f | slopeNorm=%.2f | sogliaTrend=%.2f", slopePointsPerBar, slopeNormalized, InpMA_Slope_TrendThresh);
         Print(message);
         CheckTrendSignal(ALLOW_LONGS_ONLY);   // --- NUOVO --- trend in direzione long
         CheckRangeSignal(ALLOW_LONGS_ONLY);   // --- NUOVO --- mean reversion solo pro-trend
         break;

      case REGIME_DOWNTREND:
         message = StringFormat("Regime: DOWNTREND | slopePts=%.2f | slopeNorm=%.2f | sogliaTrend=-%.2f", slopePointsPerBar, slopeNormalized, InpMA_Slope_TrendThresh);
         Print(message);
         CheckTrendSignal(ALLOW_SHORTS_ONLY);  // --- NUOVO --- trend in direzione short
         CheckRangeSignal(ALLOW_SHORTS_ONLY);  // --- NUOVO --- mean reversion solo pro-trend
         break;

      case REGIME_FLAT:
         message = StringFormat("Regime: FLAT | slopePts=%.2f | slopeNorm=%.2f | sogliaFlat=%.2f", slopePointsPerBar, slopeNormalized, InpMA_Slope_FlatThresh);
         Print(message);
         CheckRangeSignal(ALLOW_ANY);
         break;

      case REGIME_TRANSITION:
         message = StringFormat("Regime: TRANSITION | slopePts=%.2f | slopeNorm=%.2f. Nessun nuovo trade.", slopePointsPerBar, slopeNormalized);
         Print(message);
         break;
     }
  }


//+------------------------------------------------------------------+
//| Determina il regime di mercato usando la pendenza della MA       |
//+------------------------------------------------------------------+
//ENUM_MARKET_REGIME GetMarketRegime()
//{
//    // --- INIZIO BLOCCO CORRETTO ---
//
//    // 1. Definiamo un array dinamico e stabiliamo la sua dimensione.
//    // Ci servono i dati dalla barra 0 alla barra 'InpMA_Slope_Period'.
//    int bars_to_copy = InpMA_Slope_Period + 1;
//    double ma_buffer[];
//
//    // 2. Impostiamo l'array come una serie, così l'indice 0 corrisponde alla barra corrente.
//    ArraySetAsSeries(ma_buffer, true);
//
//    // 3. Usiamo UNA SOLA chiamata a CopyBuffer per riempire l'array.
//    // Copiamo 'bars_to_copy' valori a partire dalla barra corrente (shift 0).
//    if(CopyBuffer(maFilterHandle, 0, 0, bars_to_copy, ma_buffer) < bars_to_copy)
//    {
//        printf("Errore nella copia dei dati del filtro MA: dati insufficienti sul grafico.");
//        return REGIME_FLAT; // Stato sicuro in caso di errore
//    }
//
//    // 4. Ora che l'array è pieno, accediamo ai dati che ci servono.
//    // ma_buffer[0] contiene il valore della MA della barra corrente.
//    // ma_buffer[InpMA_Slope_Period] contiene il valore della MA di 'InpMA_Slope_Period' barre fa.
//    double ma_now = ma_buffer[0];
//    double ma_past = ma_buffer[InpMA_Slope_Period];
//
//    // --- FINE BLOCCO CORRETTO ---
//
//    // Il resto della logica per calcolare la pendenza rimane identico.
//    double price_diff = ma_now - ma_past;
//
//    // Normalizziamo la pendenza dividendola per il numero di barre e per la dimensione del punto
//    // Questo ci dà un valore di "Punti per Barra", confrontabile e stabile
//    double slope = (price_diff / InpMA_Slope_Period) / _Point;
//
//    if(slope > InpMA_Slope_Threshold)
//        return REGIME_UPTREND;
//
//    if(slope < -InpMA_Slope_Threshold)
//        return REGIME_DOWNTREND;
//
//    return REGIME_FLAT;
//}

//+------------------------------------------------------------------+
//| Determina il regime di mercato e restituisce la pendenza calcolata |
//+------------------------------------------------------------------+
ENUM_MARKET_REGIME GetMarketRegime(double &slope_points_per_bar, double &slope_normalized)
  {
   int bars_to_copy = InpMA_Slope_Period + 1;
   double ma_buffer[];
   ArraySetAsSeries(ma_buffer, true);

// Copy starting from shift 1 so index 0 corresponds to the last fully closed bar
   if(CopyBuffer(maFilterHandle, 0, 1, bars_to_copy, ma_buffer) < bars_to_copy)
     {
      printf("Errore nella copia dei dati del filtro MA: dati insufficienti sul grafico.");
      slope_points_per_bar = 0; // In caso di errore, impostiamo la pendenza a 0
      slope_normalized = 0;
      return REGIME_FLAT;
     }

// ma_buffer[0] -> shift 1 (ultima barra chiusa), ma_buffer[InpMA_Slope_Period] -> shift 1 + periodo
   double ma_now = ma_buffer[0];
   double ma_past = ma_buffer[InpMA_Slope_Period];
   double price_diff = ma_now - ma_past;
   double slope = (price_diff / InpMA_Slope_Period) / _Point;

   slope_points_per_bar = slope; // --- MODIFICATO --- restituiamo la pendenza in punti/barra

   double atr_value = GetIndicatorValue(atrHandleSlope, 0, 1);
   double atr_points = atr_value > 0 ? atr_value / _Point : 0;

   if(atr_points <= 0)
     {
      slope_normalized = 0;
      return REGIME_FLAT;
     }

   slope_normalized = slope / atr_points; // --- MODIFICATO --- pendenza normalizzata rispetto all'ATR

   if(slope_normalized > InpMA_Slope_TrendThresh)
      return REGIME_UPTREND;

   if(slope_normalized < -InpMA_Slope_TrendThresh)
      return REGIME_DOWNTREND;

   if(MathAbs(slope_normalized) <= InpMA_Slope_FlatThresh)
      return REGIME_FLAT;

   return REGIME_TRANSITION; // --- NUOVO --- area grigia fra flat e trend
  }

////+------------------------------------------------------------------+
////| Controlla i segnali per la logica TREND (Breakout Donchian)      |
////+------------------------------------------------------------------+
//void CheckTrendSignal(ENUM_TRADE_DIRECTION direction_filter)
//{
//    double donchianUpper = GetDonchianValue(InpDonchian_Period, DONCHIAN_UPPER, 2);
//    double donchianLower = GetDonchianValue(InpDonchian_Period, DONCHIAN_LOWER, 2);
//    if(donchianUpper == 0 || donchianLower == 0) return;
//
//    double closePrice = iClose(_Symbol, _Period, 1);
//
//    //--- Segnale LONG: Chiusura sopra il canale
//    if(direction_filter != ALLOW_SHORTS_ONLY && closePrice > donchianUpper)
//    {
//        double atrValue = GetIndicatorValue(atrHandleTrend, 0, 1);
//        double slDistance = atrValue * InpSL_ATR_Multiplier_Trend;
//        double stopLossPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - slDistance;
//        double lotSize = CalculateLotSize(slDistance);
//
//        // --- CORREZIONE FIX: La funzione Buy() ha 6 parametri. Il risultato si ottiene dopo.
//        if(trade.Buy(lotSize, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_ASK), stopLossPrice, 0, "Trend_Long"))
//        {
//            ulong ticket = trade.ResultOrder(); // Ottieni il ticket dell'ordine dal risultato
//            if(ticket > 0)
//            {
//                StoreRangeRiskDistance(ticket, slDistance); // Salva il rischio usando il ticket
//            }
//        }
//    }
//    //--- Segnale SHORT: Chiusura sotto il canale
//    else if(direction_filter != ALLOW_LONGS_ONLY && closePrice < donchianLower)
//    {
//        double atrValue = GetIndicatorValue(atrHandleTrend, 0, 1);
//        double slDistance = atrValue * InpSL_ATR_Multiplier_Trend;
//        double stopLossPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID) + slDistance;
//        double lotSize = CalculateLotSize(slDistance);
//
//        // --- CORREZIONE FIX: La funzione Sell() ha 6 parametri. Il risultato si ottiene dopo.
//        if(trade.Sell(lotSize, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_BID), stopLossPrice, 0, "Trend_Short"))
//        {
//            ulong ticket = trade.ResultOrder(); // Ottieni il ticket dell'ordine dal risultato
//            if(ticket > 0)
//            {
//                StoreRangeRiskDistance(ticket, slDistance); // Salva il rischio usando il ticket
//            }
//        }
//    }
//}

//+------------------------------------------------------------------+
//| Controlla i segnali per la logica TREND (Breakout Donchian)      |
//| --- VERSIONE FINALE E SICURA ---                                 |
//+------------------------------------------------------------------+
void CheckTrendSignal(ENUM_TRADE_DIRECTION direction_filter)
  {
   double donchianUpper = GetDonchianValue(InpDonchian_Period, DONCHIAN_UPPER, 2);
   double donchianLower = GetDonchianValue(InpDonchian_Period, DONCHIAN_LOWER, 2);
   if(donchianUpper == 0 || donchianLower == 0)
      return;

   double closePrice = iClose(_Symbol, _Period, 1);

//--- Segnale LONG: Chiusura sopra il canale
   if(direction_filter != ALLOW_SHORTS_ONLY && closePrice > donchianUpper)
     {
      double atrValue = GetIndicatorValue(atrHandleTrend, 0, 1);
      double slDistance = atrValue * InpSL_ATR_Multiplier_Trend;

      // --- VALVOLA DI SICUREZZA ---
      double minSlDistance = InpMinStopLossPoints * _Point;
      if(slDistance < minSlDistance)
         slDistance = minSlDistance;
      // --- FINE VALVOLA ---

      double stopLossPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - slDistance;
      double lotSize = CalculateLotSize(slDistance, ORDER_TYPE_BUY, SymbolInfoDouble(_Symbol, SYMBOL_ASK));
      if(lotSize <= 0.0)
        {
         PrintFormat("SKIP Buy: volume=0 (margine insufficiente o rischio troppo basso). FreeMargin=%.2f", AccountInfoDouble(ACCOUNT_MARGIN_FREE));
        }
      else
        {
         string blockReason = "";
         if(!PassTradeQualityGate("Trend_Long", atrHandleTrend, g_lastSlopeNorm, g_lastRegime, blockReason))
           {
            int spreadPoints = GetSpreadPoints();
            int atrPoints = GetATRPointsFromHandle(atrHandleTrend, 1);
            if(InpLogBlockedEntries)
               AppendCsvLog("BLOCKED", "Trend_Long", g_lastRegime, g_lastSlopeNorm, atrPoints, spreadPoints, blockReason);
            return;
           }
         int spreadPoints = GetSpreadPoints();
         int atrPoints = GetATRPointsFromHandle(atrHandleTrend, 1);
         float features[9];
         if(!BuildTradeFeatures(true, true, features))
           {
            Print("BuildTradeFeatures fallita (Trend_Long): trade bloccato.");
            return;
           }
         int ml_prediction = GetMLPrediction(true, true);
         if(ml_prediction == 0 && !InpDataCollectionMode)
           {
            PrintFormat("ML Model Blocked Trade - Skipped");
            return; // Abort trade execution
           }
         AppendCsvLog("EXECUTED", "Trend_Long", g_lastRegime, g_lastSlopeNorm, atrPoints, spreadPoints, "OK");
         if(trade.Buy(lotSize, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_ASK), stopLossPrice, 0, "Trend_Long"))
           {
            // Dopo l'apertura Trend riuscita (adatta per BUY/SELL)
            Sleep(50); // breve attesa per sincronizzazione dei dati posizione
            if(PositionSelect(_Symbol))
              {
               ulong  posTicket = (ulong)PositionGetInteger(POSITION_TICKET);
               double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
               double slPrice   = PositionGetDouble(POSITION_SL);

               if(InpDataCollectionMode)
                  ExportMLDataset(posTicket, features);

               if(slPrice > 0.0)
                 {
                  double riskPts = MathAbs(openPrice - slPrice) / _Point; // rischio iniziale in punti
                  StoreTrendRisk(posTicket, riskPts);
                 }
              }
           }
         else
           {
            PrintFormat("Trade Buy fallito (Trend_Long). retcode=%d", trade.ResultRetcode());
           }
        }
     }
//--- Segnale SHORT: Chiusura sotto il canale
   else
      if(direction_filter != ALLOW_LONGS_ONLY && closePrice < donchianLower)
        {
         double atrValue = GetIndicatorValue(atrHandleTrend, 0, 1);
         double slDistance = atrValue * InpSL_ATR_Multiplier_Trend;

         // --- VALVOLA DI SICUREZZA ---
         double minSlDistance = InpMinStopLossPoints * _Point;
         if(slDistance < minSlDistance)
            slDistance = minSlDistance;
         // --- FINE VALVOLA ---

         double stopLossPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID) + slDistance;
         double lotSize = CalculateLotSize(slDistance, ORDER_TYPE_SELL, SymbolInfoDouble(_Symbol, SYMBOL_BID));
         if(lotSize <= 0.0)
           {
            PrintFormat("SKIP Sell: volume=0 (margine insufficiente o rischio troppo basso). FreeMargin=%.2f", AccountInfoDouble(ACCOUNT_MARGIN_FREE));
           }
         else
           {
            string blockReason = "";
            if(!PassTradeQualityGate("Trend_Short", atrHandleTrend, g_lastSlopeNorm, g_lastRegime, blockReason))
              {
               int spreadPoints = GetSpreadPoints();
               int atrPoints = GetATRPointsFromHandle(atrHandleTrend, 1);
               if(InpLogBlockedEntries)
                  AppendCsvLog("BLOCKED", "Trend_Short", g_lastRegime, g_lastSlopeNorm, atrPoints, spreadPoints, blockReason);
               return;
              }
            int spreadPoints = GetSpreadPoints();
            int atrPoints = GetATRPointsFromHandle(atrHandleTrend, 1);
            float features[9];
            if(!BuildTradeFeatures(true, false, features))
              {
               Print("BuildTradeFeatures fallita (Trend_Short): trade bloccato.");
               return;
              }
            int ml_prediction = GetMLPrediction(true, false);
            if(ml_prediction == 0 && !InpDataCollectionMode)
              {
               PrintFormat("ML Model Blocked Trade - Skipped");
               return; // Abort trade execution
              }
            AppendCsvLog("EXECUTED", "Trend_Short", g_lastRegime, g_lastSlopeNorm, atrPoints, spreadPoints, "OK");
            if(trade.Sell(lotSize, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_BID), stopLossPrice, 0, "Trend_Short"))
              {
               // Dopo l'apertura Trend riuscita (adatta per BUY/SELL)
               Sleep(50); // breve attesa per sincronizzazione dei dati posizione
               if(PositionSelect(_Symbol))
                 {
                  ulong  posTicket = (ulong)PositionGetInteger(POSITION_TICKET);
                  double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
                  double slPrice   = PositionGetDouble(POSITION_SL);

                  if(InpDataCollectionMode)
                     ExportMLDataset(posTicket, features);

                  if(slPrice > 0.0)
                    {
                     double riskPts = MathAbs(openPrice - slPrice) / _Point; // rischio iniziale in punti
                     StoreTrendRisk(posTicket, riskPts);
                    }
                 }
              }
            else
              {
               PrintFormat("Trade Sell fallito (Trend_Short). retcode=%d", trade.ResultRetcode());
              }
           }
        }
  }


//+------------------------------------------------------------------+
//| Controlla i segnali per la logica RANGE (Mean Reversion)         |
//+------------------------------------------------------------------+
//void CheckRangeSignal(ENUM_TRADE_DIRECTION direction_filter)
//{
//    if(!RangeVolatilityFilter())
//    {
//        Print("Volatilità eccessiva: logica range sospesa.");
//        return;
//    }
//
//    double bbUpper[1], bbLower[1], bbMiddle[1];
//    CopyBuffer(bbandsHandle, 1, 1, 1, bbUpper); // Upper Band
//    CopyBuffer(bbandsHandle, 2, 1, 1, bbLower); // Lower Band
//    CopyBuffer(bbandsHandle, 0, 1, 1, bbMiddle); // Middle Band
//
//    double rsiValue = GetIndicatorValue(rsiHandle, 0, 1);
//    double highPrice = iHigh(_Symbol, _Period, 1);
//    double lowPrice  = iLow(_Symbol, _Period, 1);
//
//    //--- Segnale LONG: Prezzo tocca la banda inferiore & RSI ipervenduto
//    if(direction_filter != ALLOW_SHORTS_ONLY && lowPrice <= bbLower[0] && rsiValue < InpRSI_Oversold)
//    {
//        double atrValue = GetIndicatorValue(atrHandleRange, 0, 1);
//        double slDistance = atrValue * InpSL_ATR_Multiplier_Range;
//        double takeProfitPrice = bbMiddle[0];
//        double stopLossPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - slDistance;
//
//        if (takeProfitPrice - SymbolInfoDouble(_Symbol, SYMBOL_ASK) < _Point * SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * 2)
//        {
//             takeProfitPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK) + (slDistance * InpTP_Multiplier_Range);
//        }
//
//        double lotSize = CalculateLotSize(slDistance);
//
//        // --- CORREZIONE FIX: La funzione Buy() ha 6 parametri. Il risultato si ottiene dopo.
//        if(trade.Buy(lotSize, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_ASK), stopLossPrice, takeProfitPrice, "Range_Long"))
//        {
//            ulong ticket = trade.ResultOrder(); // Ottieni il ticket dell'ordine dal risultato
//            if(ticket > 0)
//            {
//                StoreRangeRiskDistance(ticket, slDistance); // Salva il rischio usando il ticket
//            }
//        }
//    }
//    //--- Segnale SHORT: Prezzo tocca la banda superiore & RSI ipercomprato
//    else if(direction_filter != ALLOW_LONGS_ONLY && highPrice >= bbUpper[0] && rsiValue > InpRSI_Overbought)
//    {
//        double atrValue = GetIndicatorValue(atrHandleRange, 0, 1);
//        double slDistance = atrValue * InpSL_ATR_Multiplier_Range;
//        double takeProfitPrice = bbMiddle[0];
//        double stopLossPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID) + slDistance;
//
//        if (SymbolInfoDouble(_Symbol, SYMBOL_BID) - takeProfitPrice < _Point * SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * 2)
//        {
//             takeProfitPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID) - (slDistance * InpTP_Multiplier_Range);
//        }
//
//        double lotSize = CalculateLotSize(slDistance);
//
//        // --- CORREZIONE FIX: La funzione Sell() ha 6 parametri. Il risultato si ottiene dopo.
//        if(trade.Sell(lotSize, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_BID), stopLossPrice, takeProfitPrice, "Range_Short"))
//        {
//            ulong ticket = trade.ResultOrder(); // Ottieni il ticket dell'ordine dal risultato
//            if(ticket > 0)
//            {
//                StoreRangeRiskDistance(ticket, slDistance); // Salva il rischio usando il ticket
//            }
//        }
//    }
//}

//+------------------------------------------------------------------+
//| Controlla i segnali per la logica RANGE (Mean Reversion)         |
//| --- VERSIONE SUPER-DEBUG "SCATOLA NERA" ---                     |
//+------------------------------------------------------------------+
//void CheckRangeSignal(ENUM_TRADE_DIRECTION direction_filter)
//{
//    // --- STAMPA 1: Siamo entrati nella funzione? ---
//    Print("DEBUG: CheckRangeSignal avviata.");
//
//    if(!RangeVolatilityFilter())
//    {
//        Print("DEBUG: Uscita a causa del RangeVolatilityFilter.");
//        return;
//    }
//
//    double bbUpper[1], bbLower[1], bbMiddle[1];
//    if(CopyBuffer(bbandsHandle, 1, 1, 1, bbUpper) <= 0 ||
//       CopyBuffer(bbandsHandle, 2, 1, 1, bbLower) <= 0 ||
//       CopyBuffer(bbandsHandle, 0, 1, 1, bbMiddle) <= 0)
//    {
//        Print("DEBUG: Errore nel copiare i dati delle Bollinger Bands. Uscita.");
//        return;
//    }
//
//    double rsiValue = GetIndicatorValue(rsiHandle, 0, 1);
//    double highPrice = iHigh(_Symbol, _Period, 1);
//    double lowPrice  = iLow(_Symbol, _Period, 1);
//
//    // --- STAMPA 2: Valori chiave prima della decisione ---
//    PrintFormat("DEBUG: Dati Barra -> H:%.5f, L:%.5f, RSI:%.2f", highPrice, lowPrice, rsiValue);
//    PrintFormat("DEBUG: Dati BB -> Upper:%.5f, Lower:%.5f", bbUpper[0], bbLower[0]);
//    PrintFormat("DEBUG: Soglie RSI -> OB:%.2f, OS:%.2f", InpRSI_Overbought, InpRSI_Oversold);
//
//    // --- Logica di ingresso con buffer di debug ---
//    bool longBB_Condition  = lowPrice <= (bbLower[0] + (_Point * 20));
//    bool shortBB_Condition = highPrice >= (bbUpper[0] - (_Point * 20));
//
//    // --- STAMPA 3: Risultato delle condizioni booleane ---
//    bool longAllowed  = (direction_filter != ALLOW_SHORTS_ONLY);
//    bool shortAllowed = (direction_filter != ALLOW_LONGS_ONLY);
//    bool longRSI_Cond = (rsiValue < InpRSI_Oversold);
//    bool shortRSI_Cond= (rsiValue > InpRSI_Overbought);
//
//    PrintFormat("DEBUG: Condizioni LONG -> allowed:%s, bbCond:%s, rsiCond:%s",
//                longAllowed ? "Y":"N", longBB_Condition ? "Y":"N", longRSI_Cond ? "Y":"N");
//    PrintFormat("DEBUG: Condizioni SHORT -> allowed:%s, bbCond:%s, rsiCond:%s",
//                shortAllowed ? "Y":"N", shortBB_Condition ? "Y":"N", shortRSI_Cond ? "Y":"N");
//
//
//    //--- Logica di segnale ---
//    if(longAllowed && longBB_Condition && longRSI_Cond)
//    {
//        // --- STAMPA 4: Siamo dentro il blocco per inviare un ordine BUY ---
//        Print("DEBUG: CONDIZIONI BUY SODDISFATTE. Tento di aprire un trade LONG.");
//
//        double atrValue = GetIndicatorValue(atrHandleRange, 0, 1);
//        if(atrValue <= 0) { Print("DEBUG: ATR non valido, trade annullato."); return; }
//
//        double slDistance = atrValue * InpSL_ATR_Multiplier_Range;
//        double takeProfitPrice = bbMiddle[0];
//        double stopLossPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - slDistance;
//
//        double lotSize = CalculateLotSize(slDistance);
//        if(lotSize <= 0) { Print("DEBUG: lotSize calcolato non valido, trade annullato."); return; }
//
//        trade.Buy(lotSize, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_ASK), stopLossPrice, takeProfitPrice, "Range_Long_DEBUG");
//    }
//    else if(shortAllowed && shortBB_Condition && shortRSI_Cond)
//    {
//        // --- STAMPA 4: Siamo dentro il blocco per inviare un ordine SELL ---
//        Print("DEBUG: CONDIZIONI SELL SODDISFATTE. Tento di aprire un trade SHORT.");
//
//        double atrValue = GetIndicatorValue(atrHandleRange, 0, 1);
//        if(atrValue <= 0) { Print("DEBUG: ATR non valido, trade annullato."); return; }
//
//        double slDistance = atrValue * InpSL_ATR_Multiplier_Range;
//        double takeProfitPrice = bbMiddle[0];
//        double stopLossPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID) + slDistance;
//
//        double lotSize = CalculateLotSize(slDistance);
//        if(lotSize <= 0) { Print("DEBUG: lotSize calcolato non valido, trade annullato."); return; }
//
//        trade.Sell(lotSize, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_BID), stopLossPrice, takeProfitPrice, "Range_Short_DEBUG");
//    }
//    else
//    {
//        // --- STAMPA 5: Se nessuna delle due condizioni è vera ---
//        Print("DEBUG: Nessuna condizione di ingresso soddisfatta in questa barra.");
//    }
//    Print("--- FINE CHECK ---");
//}

//+------------------------------------------------------------------+
//| Controlla i segnali per la logica RANGE (Mean Reversion)         |
//| --- VERSIONE FINALE E CORRETTA ---                               |
//+------------------------------------------------------------------+
//void CheckRangeSignal(ENUM_TRADE_DIRECTION direction_filter)
//{
//    if(!RangeVolatilityFilter())
//    {
//        return;
//    }
//
//    double bbUpper[1], bbLower[1], bbMiddle[1];
//    CopyBuffer(bbandsHandle, 1, 1, 1, bbUpper); // Upper Band
//    CopyBuffer(bbandsHandle, 2, 1, 1, bbLower); // Lower Band
//    CopyBuffer(bbandsHandle, 0, 1, 1, bbMiddle); // Middle Band
//
//    double rsiValue = GetIndicatorValue(rsiHandle, 0, 1);
//    double highPrice = iHigh(_Symbol, _Period, 1);
//    double lowPrice  = iLow(_Symbol, _Period, 1);
//
//    //--- Segnale LONG: Prezzo tocca la banda inferiore & RSI ipervenduto
//    if(direction_filter != ALLOW_SHORTS_ONLY && lowPrice <= bbLower[0] && rsiValue < InpRSI_Oversold)
//    {
//        double atrValue = GetIndicatorValue(atrHandleRange, 0, 1);
//        double slDistance = atrValue * InpSL_ATR_Multiplier_Range;
//
//        // Calcoliamo SL e TP desiderati
//        double stopLossPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - slDistance;
//        double takeProfitPrice = bbMiddle[0];
//
//        // --- CORREZIONE FINALE: Normalizziamo il TP per evitare 'invalid stops' ---
//        takeProfitPrice = NormalizePrice(takeProfitPrice, ORDER_TYPE_BUY);
//
//        double lotSize = CalculateLotSize(slDistance);
//        trade.Buy(lotSize, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_ASK), stopLossPrice, takeProfitPrice, "Range_Long");
//    }
//    //--- Segnale SHORT: Prezzo tocca la banda superiore & RSI ipercomprato
//    else if(direction_filter != ALLOW_LONGS_ONLY && highPrice >= bbUpper[0] && rsiValue > InpRSI_Overbought)
//    {
//        double atrValue = GetIndicatorValue(atrHandleRange, 0, 1);
//        double slDistance = atrValue * InpSL_ATR_Multiplier_Range;
//
//        // Calcoliamo SL e TP desiderati
//        double stopLossPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID) + slDistance;
//        double takeProfitPrice = bbMiddle[0];
//
//        // --- CORREZIONE FINALE: Normalizziamo il TP per evitare 'invalid stops' ---
//        takeProfitPrice = NormalizePrice(takeProfitPrice, ORDER_TYPE_SELL);
//
//        double lotSize = CalculateLotSize(slDistance);
//        trade.Sell(lotSize, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_BID), stopLossPrice, takeProfitPrice, "Range_Short");
//    }
//}

//+------------------------------------------------------------------+
//| Controlla i segnali per la logica RANGE (Mean Reversion)         |
//| --- VERSIONE FINALE E SICURA ---                                 |
//+------------------------------------------------------------------+
void CheckRangeSignal(ENUM_TRADE_DIRECTION direction_filter)
  {
   if(!RangeVolatilityFilter())
      return;

   double bbUpper[1], bbLower[1], bbMiddle[1];
   CopyBuffer(bbandsHandle, 1, 1, 1, bbUpper);
   CopyBuffer(bbandsHandle, 2, 1, 1, bbLower);
   CopyBuffer(bbandsHandle, 0, 1, 1, bbMiddle);

   double rsiValue = GetIndicatorValue(rsiHandle, 0, 1);
   double highPrice = iHigh(_Symbol, _Period, 1);
   double lowPrice  = iLow(_Symbol, _Period, 1);

//--- Segnale LONG
   if(direction_filter != ALLOW_SHORTS_ONLY && lowPrice <= bbLower[0] && rsiValue < InpRSI_Oversold)
     {
      double atrValue = GetIndicatorValue(atrHandleRange, 0, 1);
      double slDistance = atrValue * InpSL_ATR_Multiplier_Range;

      // --- VALVOLA DI SICUREZZA ---
      double minSlDistance = InpMinStopLossPoints * _Point;
      if(slDistance < minSlDistance)
         slDistance = minSlDistance;
      // --- FINE VALVOLA ---

      double stopLossPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - slDistance;
      double takeProfitPrice = NormalizePrice(bbMiddle[0], ORDER_TYPE_BUY);
      double lotSize = CalculateLotSize(slDistance, ORDER_TYPE_BUY, SymbolInfoDouble(_Symbol, SYMBOL_ASK));
      if(lotSize <= 0.0)
        {
         PrintFormat("SKIP Buy: volume=0 (margine insufficiente o rischio troppo basso). FreeMargin=%.2f", AccountInfoDouble(ACCOUNT_MARGIN_FREE));
        }
      else
        {
         string blockReason = "";
         if(!PassTradeQualityGate("Range_Long", atrHandleRange, g_lastSlopeNorm, g_lastRegime, blockReason))
           {
            int spreadPoints = GetSpreadPoints();
            int atrPoints = GetATRPointsFromHandle(atrHandleRange, 1);
            if(InpLogBlockedEntries)
               AppendCsvLog("BLOCKED", "Range_Long", g_lastRegime, g_lastSlopeNorm, atrPoints, spreadPoints, blockReason);
            return;
           }
         int spreadPoints = GetSpreadPoints();
         int atrPoints = GetATRPointsFromHandle(atrHandleRange, 1);
         float features[9];
         if(!BuildTradeFeatures(false, true, features))
           {
            Print("BuildTradeFeatures fallita (Range_Long): trade bloccato.");
            return;
           }
         int ml_prediction = GetMLPrediction(false, true);
         if(ml_prediction == 0 && !InpDataCollectionMode)
           {
            PrintFormat("ML Model Blocked Trade - Skipped");
            return; // Abort trade execution
           }
         AppendCsvLog("EXECUTED", "Range_Long", g_lastRegime, g_lastSlopeNorm, atrPoints, spreadPoints, "OK");
         if(trade.Buy(lotSize, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_ASK), stopLossPrice, takeProfitPrice, "Range_Long"))
           {
            Sleep(50); // breve attesa per sincronizzazione dei dati posizione
            if(PositionSelect(_Symbol))
              {
               ulong posTicket = (ulong)PositionGetInteger(POSITION_TICKET);
               if(InpDataCollectionMode)
                  ExportMLDataset(posTicket, features);
              }
           }
         else
           {
            PrintFormat("Trade Buy fallito (Range_Long). retcode=%d", trade.ResultRetcode());
           }
        }
     }
//--- Segnale SHORT
   else
      if(direction_filter != ALLOW_LONGS_ONLY && highPrice >= bbUpper[0] && rsiValue > InpRSI_Overbought)
        {
         double atrValue = GetIndicatorValue(atrHandleRange, 0, 1);
         double slDistance = atrValue * InpSL_ATR_Multiplier_Range;

         // --- VALVOLA DI SICUREZZA ---
         double minSlDistance = InpMinStopLossPoints * _Point;
         if(slDistance < minSlDistance)
            slDistance = minSlDistance;
         // --- FINE VALVOLA ---

         double stopLossPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID) + slDistance;
         double takeProfitPrice = NormalizePrice(bbMiddle[0], ORDER_TYPE_SELL);
         double lotSize = CalculateLotSize(slDistance, ORDER_TYPE_SELL, SymbolInfoDouble(_Symbol, SYMBOL_BID));
         if(lotSize <= 0.0)
           {
            PrintFormat("SKIP Sell: volume=0 (margine insufficiente o rischio troppo basso). FreeMargin=%.2f", AccountInfoDouble(ACCOUNT_MARGIN_FREE));
           }
         else
           {
            string blockReason = "";
            if(!PassTradeQualityGate("Range_Short", atrHandleRange, g_lastSlopeNorm, g_lastRegime, blockReason))
              {
               int spreadPoints = GetSpreadPoints();
               int atrPoints = GetATRPointsFromHandle(atrHandleRange, 1);
               if(InpLogBlockedEntries)
                  AppendCsvLog("BLOCKED", "Range_Short", g_lastRegime, g_lastSlopeNorm, atrPoints, spreadPoints, blockReason);
               return;
              }
            int spreadPoints = GetSpreadPoints();
            int atrPoints = GetATRPointsFromHandle(atrHandleRange, 1);
            float features[9];
            if(!BuildTradeFeatures(false, false, features))
              {
               Print("BuildTradeFeatures fallita (Range_Short): trade bloccato.");
               return;
              }
            int ml_prediction = GetMLPrediction(false, false);
            if(ml_prediction == 0 && !InpDataCollectionMode)
              {
               PrintFormat("ML Model Blocked Trade - Skipped");
               return; // Abort trade execution
              }
            AppendCsvLog("EXECUTED", "Range_Short", g_lastRegime, g_lastSlopeNorm, atrPoints, spreadPoints, "OK");
            if(trade.Sell(lotSize, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_BID), stopLossPrice, takeProfitPrice, "Range_Short"))
              {
               Sleep(50); // breve attesa per sincronizzazione dei dati posizione
               if(PositionSelect(_Symbol))
                 {
                  ulong posTicket = (ulong)PositionGetInteger(POSITION_TICKET);
                  if(InpDataCollectionMode)
                     ExportMLDataset(posTicket, features);
                 }
              }
            else
              {
               PrintFormat("Trade Sell fallito (Range_Short). retcode=%d", trade.ResultRetcode());
              }
           }
        }
  }


//+------------------------------------------------------------------+
//| Gestisce le posizioni aperte (Trailing Stop ATR per Trend)      |
//+------------------------------------------------------------------+
void ManageOpenPosition()
  {
   if(!PositionSelect(_Symbol))
     {
      PurgeClosedRangeRiskRecords();
      PurgeClosedPartialCloseStates();
      return;
     }
   PurgeClosedPartialCloseStates();
   string comment = PositionGetString(POSITION_COMMENT);

   if(StringFind(comment, "Trend") != -1)
     {
      ManageTrendPosition();
     }
   else
      if(StringFind(comment, "Range") != -1)
        {
         ManageRangePosition();
        }
  }

//+------------------------------------------------------------------+
//| --- NUOVO --- Trailing ATR dinamico per i trade trend            |
//+------------------------------------------------------------------+

// === [PATCH] ATR helper for Trend (MQL5 handle + CopyBuffer) ===
double GetATRTrendValue()
{
   static int atr_handle = INVALID_HANDLE;
   static ENUM_TIMEFRAMES last_tf = PERIOD_CURRENT;
   static string last_sym = "";

   if(atr_handle == INVALID_HANDLE || last_tf != PERIOD_CURRENT || last_sym != _Symbol)
   {
      if(atr_handle != INVALID_HANDLE) IndicatorRelease(atr_handle);
      atr_handle = iATR(_Symbol, PERIOD_CURRENT, InpATR_Period_Trend);
      last_tf = PERIOD_CURRENT;
      last_sym = _Symbol;
   }
   if(atr_handle == INVALID_HANDLE) return 0.0;

   double buf[];
   if(CopyBuffer(atr_handle, 0, 0, 1, buf) != 1) return 0.0;
   return buf[0];
}
void ManageTrendPosition()
  {
if(!PositionSelect(_Symbol)) return;
if((ulong)PositionGetInteger(POSITION_MAGIC)!=(ulong)InpMagicNumber) return;

long   type   = PositionGetInteger(POSITION_TYPE);
double op     = PositionGetDouble(POSITION_PRICE_OPEN);
double sl     = PositionGetDouble(POSITION_SL);
double tp     = PositionGetDouble(POSITION_TP);
double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
ulong  ticket = (ulong)PositionGetInteger(POSITION_TICKET);

double riskPts;
if(!GetTrendRisk(ticket, riskPts))
   riskPts = MathMax(1.0, MathAbs(op - sl)/_Point);

ManagePartialCloseAtOneR(ticket, (ENUM_POSITION_TYPE)type, op, riskPts);
if(PositionSelectByTicket(ticket))
  {
   sl  = PositionGetDouble(POSITION_SL);
   tp  = PositionGetDouble(POSITION_TP);
   bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
  }

// --- Trailing ATR distance (MQL5: handle + CopyBuffer) ---
double atr = GetATRTrendValue();
if(atr <= 0) return;
double trailDist = atr * InpTS_ATR_Multiplier_Trend;

double newSL = sl;
if(type==POSITION_TYPE_BUY)
{
   double cand = bid - trailDist;
   cand = MathMax(cand, op);
   newSL = MathMax(sl, cand);
}
else if(type==POSITION_TYPE_SELL)
{
   double cand = ask + trailDist;
   cand = MathMin(cand, op);
   newSL = MathMin(sl, cand);
}

// --- Merge Break-Even in R ---
if(InpTrend_UseBreakEven)
{
   if(!GetTrendRisk(ticket, riskPts))
      riskPts = MathMax(1.0, MathAbs(op - sl)/_Point);

   double rMultiple = (type==POSITION_TYPE_BUY)
                      ? (bid - op)/(_Point * riskPts)
                      : (op - ask)/(_Point * riskPts);

   if(rMultiple >= InpTrend_BreakEvenRR)
   {
      double bePrice = (type==POSITION_TYPE_BUY)
                       ? op + (InpTrend_BE_Buffer_R * riskPts * _Point)
                       : op - (InpTrend_BE_Buffer_R * riskPts * _Point);

      int    stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
      double minStop    = MathMax((double)InpMinStopLossPoints, (double)stopsLevel) * _Point;

      if(type==POSITION_TYPE_BUY)  bePrice = MathMin(bePrice, bid - minStop);
      else                         bePrice = MathMax(bePrice, ask + minStop);

      if(type==POSITION_TYPE_BUY)  newSL = MathMax(newSL, bePrice);
      else                         newSL = MathMin(newSL, bePrice);
   }
}

bool advance = (type==POSITION_TYPE_BUY) ? (newSL > sl + (0.1*_Point))
                                         : (newSL < sl - (0.1*_Point));
if(advance)
{
   if(trade.PositionModify(_Symbol, newSL, tp))
   {
      ulong t = (ulong)PositionGetInteger(POSITION_TICKET);
      StoreTrendRisk(t, MathMax(1.0, MathAbs(op - newSL)/_Point));
   }
   else
   {
      Print("PositionModify failed: ", _LastError);
   }
}

}

//+------------------------------------------------------------------+
//| --- NUOVO --- Gestione avanzata dei trade range                  |
//+------------------------------------------------------------------+
void ManageRangePosition()
  {
   ENUM_POSITION_TYPE posType    = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double             currentSL  = PositionGetDouble(POSITION_SL);
   double             currentTP  = PositionGetDouble(POSITION_TP);
   double             openPrice  = PositionGetDouble(POSITION_PRICE_OPEN);
   datetime           openTime   = (datetime)PositionGetInteger(POSITION_TIME);
   ulong              ticket     = (ulong)PositionGetInteger(POSITION_TICKET);

   double storedRiskDistance = 0.0;
   if(!GetRangeRiskDistance(ticket, storedRiskDistance))
     {
      storedRiskDistance = MathAbs(openPrice - currentSL);
      if(storedRiskDistance > 0.0)
         StoreRangeRiskDistance(ticket, storedRiskDistance);
     }

   if(storedRiskDistance <= 0.0)
      storedRiskDistance = MathAbs(openPrice - currentSL);

   double riskPoints = storedRiskDistance / _Point;
   if(riskPoints <= 0.0)
      riskPoints = MathMax(1.0, MathAbs(openPrice - currentSL)/_Point);

   ManagePartialCloseAtOneR(ticket, posType, openPrice, riskPoints);
   if(PositionSelectByTicket(ticket))
     {
      currentSL = PositionGetDouble(POSITION_SL);
      currentTP = PositionGetDouble(POSITION_TP);
     }

   double currentPrice = (posType == POSITION_TYPE_BUY)
                         ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                         : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   double profitDistance = (posType == POSITION_TYPE_BUY)
                           ? currentPrice - openPrice
                           : openPrice - currentPrice;

   bool   hasRiskReference = (storedRiskDistance > 0.0);
   double rMultiple = 0.0;
   if(hasRiskReference)
      rMultiple = profitDistance / storedRiskDistance;
   double newSL = currentSL;
   double newTP = currentTP;

// --- Break even dinamico ---
   if(hasRiskReference && rMultiple >= InpRange_BreakEvenRR)
     {
      double targetSL = (posType == POSITION_TYPE_BUY)
                        ? openPrice + (storedRiskDistance * InpRange_BE_Buffer)
                        : openPrice - (storedRiskDistance * InpRange_BE_Buffer);

      if(posType == POSITION_TYPE_BUY && targetSL > currentSL)
         newSL = targetSL;
      else
         if(posType == POSITION_TYPE_SELL && (currentSL == 0 || targetSL < currentSL))
            newSL = targetSL;
     }

// --- Trailing Take Profit verso la banda centrale ---
   double bbMiddle[1];
   if(CopyBuffer(bbandsHandle, 0, 1, 1, bbMiddle) > 0)
     {
      double desiredTP = bbMiddle[0];
      if(posType == POSITION_TYPE_BUY && desiredTP > currentPrice && (currentTP == 0 || desiredTP < currentTP))
         newTP = desiredTP;
      else
         if(posType == POSITION_TYPE_SELL && desiredTP < currentPrice && (currentTP == 0 || desiredTP > currentTP))
            newTP = desiredTP;
     }

// --- Stop temporale ---
   if(InpRange_MaxBarsInTrade > 0)
     {
      int barsOpen = (int)((TimeCurrent() - openTime) / PeriodSeconds(_Period));
      if(barsOpen >= InpRange_MaxBarsInTrade)
        {
         Print("Chiusura trade range per timeout.");
         trade.PositionClose(_Symbol);
         RemoveRangeRiskDistance(ticket);
         return;
        }
     }

   if(newSL != currentSL || newTP != currentTP)
     {
      trade.PositionModify(_Symbol, newSL, newTP);
     }
  }

//+------------------------------------------------------------------+
//| --- NUOVO --- Controllo volatilità per la logica range           |
//+------------------------------------------------------------------+
bool RangeVolatilityFilter()
  {
   if(InpRange_ATR_VolatilityCap <= 0)
      return true;

   double currentATR = GetIndicatorValue(atrHandleRange, 0, 1);
   if(currentATR <= 0)
      return true; // In caso di dati insufficienti non blocchiamo l'operatività

   int lookback = MathMax(10, InpATR_Period_Range * 3);
   double atrBuffer[];
   ArraySetAsSeries(atrBuffer, true);
   if(CopyBuffer(atrHandleRange, 0, 1, lookback, atrBuffer) < lookback)
      return true;

   double sum = 0;
   for(int i = 0; i < lookback; i++)
      sum += atrBuffer[i];

   double avgATR = sum / lookback;
   if(avgATR <= 0)
      return true;

   double ratio = currentATR / avgATR;
   return (ratio <= InpRange_ATR_VolatilityCap);
  }

//+------------------------------------------------------------------+
//| --- NUOVO --- Filtro orario per l'operatività                    |
//+------------------------------------------------------------------+
bool IsWithinTradingSession()
  {
   if(!InpUseSessionFilter)
      return true;

   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now);
   int currentMinutes = now.hour * 60 + now.min;

   int startMinutes = ParseTimeToMinutes(InpSessionStart);
   int endMinutes   = ParseTimeToMinutes(InpSessionEnd);

   if(startMinutes == endMinutes)
      return true; // finestra sempre attiva

   if(startMinutes < endMinutes)
      return (currentMinutes >= startMinutes && currentMinutes <= endMinutes);

// Finestra che attraversa la mezzanotte
   return (currentMinutes >= startMinutes || currentMinutes <= endMinutes);
  }

//+------------------------------------------------------------------+
//| --- NUOVO --- Utility per convertire HH:MM in minuti             |
//+------------------------------------------------------------------+
int ParseTimeToMinutes(const string timeStr)
  {
   string parts[];
   int count = StringSplit(timeStr, ':', parts);
   if(count < 2)
      return 0;

   int hours   = (int)StringToInteger(parts[0]);
   int minutes = (int)StringToInteger(parts[1]);

   hours   = MathMax(0, MathMin(23, hours));
   minutes = MathMax(0, MathMin(59, minutes));

   return hours * 60 + minutes;
  }

//+------------------------------------------------------------------+
//| --- Trade Quality Gate helpers                                   |
//+------------------------------------------------------------------+
int GetSpreadPoints()
  {
   return (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
  }

int GetATRPointsFromHandle(int atrHandle, int shift=1)
  {
   double arr[1];
   if(CopyBuffer(atrHandle, 0, shift, 1, arr) < 1)
      return 0;
   return (int)MathRound(arr[0] / _Point);
  }

// --- PHASE 1 FIX --- rimossi helper GetDayStart/RefreshDailyCounters/RefreshFromHistory (solo per filtri tossici)

bool PassTradeQualityGate(string contextTag, int atrHandle, double slopeNorm, ENUM_MARKET_REGIME regime, string &blockReason)
  {
   int spreadPoints = GetSpreadPoints();
   if(spreadPoints > InpMaxSpreadPoints)
     {
      blockReason = "BLOCKED:SPREAD";
      return false;
     }

   int atrPoints = GetATRPointsFromHandle(atrHandle, 1);
   if(atrPoints < InpMinATRPoints)
     {
      blockReason = "BLOCKED:ATR_LOW";
      return false;
     }
   // --- PHASE 1 FIX --- rimossi gate MAX_TRADES_DAY e COOLDOWN

   blockReason = "OK";
   return true;
  }

string RegimeToString(ENUM_MARKET_REGIME regime)
  {
   switch(regime)
     {
      case REGIME_UPTREND:   return "UPTREND";
      case REGIME_DOWNTREND: return "DOWNTREND";
      case REGIME_FLAT:      return "FLAT";
      case REGIME_TRANSITION:return "TRANSITION";
     }
   return "UNKNOWN";
  }

void AppendCsvLog(string type, string contextTag, ENUM_MARKET_REGIME regime, double slopeNorm, int atrPoints, int spreadPoints, string reason)
  {
   if(type == "BLOCKED" && !InpLogBlockedEntries)
      return;

   int handle = FileOpen(InpEntryLogFileName, FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(handle == INVALID_HANDLE)
     {
      handle = FileOpen(InpEntryLogFileName, FILE_WRITE | FILE_TXT | FILE_ANSI);
      if(handle == INVALID_HANDLE)
         return;
     }

   if(FileSize(handle) == 0)
     {
      FileWriteString(handle, "timestamp;symbol;period;context;regime;slopeNorm;atrPoints;spreadPoints;type;reason\n");
     }

   FileSeek(handle, 0, SEEK_END);
   string ts = TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS);
   string periodStr = EnumToString(_Period);
   string regimeStr = RegimeToString(regime);
   string line = StringFormat("%s;%s;%s;%s;%s;%.4f;%d;%d;%s;%s",
                              ts, _Symbol, periodStr, contextTag, regimeStr, slopeNorm, atrPoints, spreadPoints, type, reason);
   FileWriteString(handle, line + "\n");
   FileClose(handle);
  }

void ExportMLDataset(ulong ticket, const float &features[])
  {
   if(ArraySize(features) < 9)
      return;

   int handle = FileOpen("MT5_ML_Dataset.csv", FILE_CSV | FILE_WRITE | FILE_READ | FILE_ANSI, ',');
   if(handle == INVALID_HANDLE)
     {
      PrintFormat("ExportMLDataset: impossibile aprire CSV. Errore=%d", GetLastError());
      return;
     }

   if(FileSize(handle) == 0)
     {
      FileWrite(handle,
                "Ticket",
                "slope_normalized",
                "rsi_14",
                "HourOfDay",
                "DayOfWeek",
                "ATR_normalized",
                "dist_ema_atr",
                "bb_position",
                "is_trend",
                "is_long");
     }

   FileSeek(handle, 0, SEEK_END);
   FileWrite(handle,
             (long)ticket,
             features[0],
             features[1],
             features[2],
             features[3],
             features[4],
             features[5],
             features[6],
             features[7],
             features[8]);
   FileClose(handle);
  }

//+------------------------------------------------------------------+
//| Calcola la dimensione del lotto basata sul rischio percentuale   |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double CalculateLotSize(const double slDistanceInPrice, const ENUM_ORDER_TYPE type, const double price)
{
   if(InpRiskPercent <= 0.0 || slDistanceInPrice <= 0.0)
      return 0.0;

   // 1. Calcolo del rischio puro in valuta
   double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * (InpRiskPercent / 100.0);
   if(riskMoney <= 0.0)
      return 0.0;

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0.0 || tickSize <= 0.0)
      return 0.0;

   // 2. Calcolo dei lotti matematici (Senza limiti)
   double lossPerLotAtSL = (slDistanceInPrice / tickSize) * tickValue;
   if(lossPerLotAtSL <= 0.0)
      return 0.0;
   double rawVolume = riskMoney / lossPerLotAtSL;

   // 3. SMART MARGIN CAP (La magia per la leva 1:33)
   double marginRequired;
   if(OrderCalcMargin(type, _Symbol, rawVolume, price, marginRequired))
   {
       double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE) * 0.90; // Usiamo massimo il 90% del conto
       if(marginRequired > freeMargin)
       {
           // Se sforiamo, riduciamo il volume proporzionalmente per farlo entrare!
           rawVolume = rawVolume * (freeMargin / marginRequired);
       }
   }

   // 4. Normalizzazione ai requisiti del broker
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   double volume = MathMax(minLot, MathMin(maxLot, rawVolume));
   if(step > 0.0)
      volume = MathFloor(volume / step) * step;
   
   // Controllo di sicurezza finale
   volume = MathMax(minLot, MathMin(maxLot, volume));

   return volume;
}

//+------------------------------------------------------------------+
//| Inferenza ML ONNX su 9 feature (ordine fisso modello)            |
//+------------------------------------------------------------------+
bool BuildTradeFeatures(bool is_trend, bool is_long, float &features[])
  {
   // Tutte le feature devono riferirsi alla barra chiusa (shift=1)
   const int shift = 1;
   ArrayResize(features, 9);

   double rsi_14 = GetIndicatorValue(rsiHandle, 0, shift);
   datetime barTime = iTime(_Symbol, _Period, shift);
   MqlDateTime dt;
   TimeToStruct(barTime, dt);
   float python_day = (float)((dt.day_of_week + 6) % 7); // Python: Monday=0 ... Sunday=6

   double atrBuffer[100];
   if(CopyBuffer(atr14_handle, 0, shift, 100, atrBuffer) < 100)
      return false;

   double atrCurrent = atrBuffer[0];
   if(atrCurrent <= 0.0)
      return false;

   double atrSum = 0.0;
   for(int i = 0; i < 100; i++)
      atrSum += atrBuffer[i];

   double atrAvg100 = atrSum / 100.0;
   if(atrAvg100 <= 0.0)
      return false;

   double ema220 = GetIndicatorValue(ema220_handle, 0, shift);
   double close1 = iClose(_Symbol, _Period, shift);

   double bbUpperArr[1], bbLowerArr[1];
   if(CopyBuffer(bbandsHandle, 1, shift, 1, bbUpperArr) <= 0 || CopyBuffer(bbandsHandle, 2, shift, 1, bbLowerArr) <= 0)
      return false;

   double bbUpper = bbUpperArr[0];
   double bbLower = bbLowerArr[0];
   double bbRange = bbUpper - bbLower;
   if(bbRange == 0.0)
      return false;

   features[0] = (float)g_lastSlopeNorm;                           // slope_normalized
   features[1] = (float)rsi_14;                                    // rsi_14
   features[2] = (float)dt.hour;                                   // HourOfDay
   features[3] = python_day;                                       // DayOfWeek (Python mapping)
   features[4] = (float)(atrCurrent / atrAvg100);                  // ATR_normalized
   features[5] = (float)((close1 - ema220) / atrCurrent);          // dist_ema_atr
   features[6] = (float)((close1 - bbLower) / bbRange);            // bb_position
   features[7] = is_trend ? 1.0f : 0.0f;                           // is_trend
   features[8] = is_long ? 1.0f : 0.0f;                            // is_long

   PrintFormat("ML_DEBUG | %s | SlopeNorm: %.4f, RSI: %.2f, Hour: %.0f, Day: %.0f, ATR_Norm: %.4f, DistEMA: %.4f, BB_Pos: %.4f, isTrend: %.0f, isLong: %.0f",
               TimeToString(barTime, TIME_DATE | TIME_MINUTES),
               features[0], features[1], features[2], features[3], features[4],
               features[5], features[6], features[7], features[8]);

   return true;
  }

int GetMLPrediction(bool is_trend, bool is_long)
{
   if(onnx_handle == INVALID_HANDLE)
   {
      Print("GetMLPrediction: handle ONNX non valido, trade bloccato.");
      return 0;
   }

   float features[9];
   if(!BuildTradeFeatures(is_trend, is_long, features))
   {
      Print("GetMLPrediction: errore costruzione feature, trade bloccato.");
      return 0;
   }

   // Prepariamo l'unico contenitore per l'output (solo l'etichetta)
   long output_label[1];
   ArrayInitialize(output_label, 0);

   // Esecuzione ONNX con 4 parametri (Handle, Flag, Input, Output)
   if(!OnnxRun(onnx_handle, ONNX_NO_CONVERSION, features, output_label))
   {
      PrintFormat("GetMLPrediction: OnnxRun fallita, errore=%d", GetLastError());
      return 0;
   }

   int prediction = (int)output_label[0];
   return prediction;
}


//+------------------------------------------------------------------+
//| Funzione helper per ottenere un valore da un indicatore          |
//+------------------------------------------------------------------+
double GetIndicatorValue(int handle, int buffer, int shift)
  {
   double val[1];
   if(CopyBuffer(handle, buffer, shift, 1, val) <= 0)
     {
      return 0.0;
     }
   return val[0];
  }

//+------------------------------------------------------------------+
//| Calcola manualmente il valore del Canale di Donchian             |
//+------------------------------------------------------------------+
double GetDonchianValue(int period, ENUM_DONCHIAN_MODE mode, int shift)
  {
   if(Bars(_Symbol, _Period) < period + shift)
     {
      printf("Non ci sono abbastanza barre per calcolare il Donchian Channel.");
      return 0;
     }

   double highs[], lows[];
   ArraySetAsSeries(highs, true);
   ArraySetAsSeries(lows, true);
   if(CopyHigh(_Symbol, _Period, shift, period, highs) == -1 || CopyLow(_Symbol, _Period, shift, period, lows) == -1)
     {
      printf("Errore nella copia dei dati High/Low per Donchian.");
      return 0;
     }

   if(mode == DONCHIAN_UPPER)
     {
      return highs[ArrayMaximum(highs, 0, period)];
     }
   else // DONCHIAN_LOWER
     {
      return lows[ArrayMinimum(lows, 0, period)];
     }
  }


//+------------------------------------------------------------------+
//| --- NUOVA FUNZIONE: Normalizza SL/TP per rispettare lo STOP_LEVEL |
//+------------------------------------------------------------------+
double NormalizePrice(double price, ENUM_ORDER_TYPE order_type)
  {
   double min_stop_level = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;

// Per un ordine di ACQUISTO
   if(order_type == ORDER_TYPE_BUY)
     {
      double min_tp_price = SymbolInfoDouble(_Symbol, SYMBOL_ASK) + min_stop_level;
      // Se il nostro TP è troppo vicino, lo spostiamo al minimo consentito
      if(price > SymbolInfoDouble(_Symbol, SYMBOL_ASK) && price < min_tp_price)
        {
         return min_tp_price;
        }
     }
// Per un ordine di VENDITA
   else
      if(order_type == ORDER_TYPE_SELL)
        {
         double min_tp_price = SymbolInfoDouble(_Symbol, SYMBOL_BID) - min_stop_level;
         // Se il nostro TP è troppo vicino, lo spostiamo al minimo consentito
         if(price < SymbolInfoDouble(_Symbol, SYMBOL_BID) && price > min_tp_price)
           {
            return min_tp_price;
           }
        }

   return price; // Se il prezzo è già valido, lo restituiamo invariato
  }
//+------------------------------------------------------------------+
