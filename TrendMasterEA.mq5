//+------------------------------------------------------------------+
//|                                                 TrendMasterEA.mq5 |
//|            Скальпинг Expert Advisor для XAUUSD (золото), M5        |
//|                                          Target broker: XM (MT5)   |
//+------------------------------------------------------------------+
//|  СТРАТЕГИЯ (значения по умолчанию, меняются в input):             |
//|   - Тип: скальпинг по тренду (fast trend scalping)                |
//|   - Инструмент: XAUUSD (золото)                                   |
//|   - Рабочий ТФ: M5, MTF-фильтр тренда на M15                      |
//|   - Вход: пересечение EMA(5)/EMA(13) + фильтр RSI(7) +            |
//|           фильтр волатильности ATR(14)                            |
//|   - Выход: тесные ATR-based SL/TP, быстрый break-even, трейлинг,  |
//|            частичное закрытие, выход по противоположному сигналу  |
//|                                                                    |
//|  ВАЖНО: XAUUSD имеет Digits=2, поэтому "пункт" (pip) в параметрах  |
//|  фильтров = 1 пункт цены = 0.01 USD. Значения ниже заданы с учётом |
//|  этого. Бюджет $15 — экстремально малый (см. предупреждения ниже). |
//|                                                                    |
//|  ЯЗЫК: MQL5 (для MT5). Компилируется в MetaEditor без ошибок.      |
//+------------------------------------------------------------------+
#property copyright   "TrendMasterEA"
#property version     "1.10"
#property description "XAUUSD M5 скальпинг: EMA cross + RSI + ATR, MTF-фильтр, риск-менеджмент, Telegram, dashboard"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//====================================================================
//                        ВХОДНЫЕ ПАРАМЕТРЫ                           
//====================================================================

//--- Общие ---------------------------------------------------------
input group "=== ОБЩИЕ НАСТРОЙКИ ==="
input long     InpMagicNumber      = 20260705;      // Magic Number (идентификатор сделок бота)
input string   InpTradeComment     = "TrendMasterEA";// Комментарий к ордерам
input int      InpMaxSlippage      = 30;            // Макс. проскальзывание (в пунктах; золото волатильно)
input int      InpMaxRetries       = 3;             // Кол-во повторов при requote/timeout
input int      InpRetryDelayMs     = 500;           // Пауза между повторами (мс)

//--- Стратегия (скальпинг XAUUSD M5) -------------------------------
input group "=== СТРАТЕГИЯ (СИГНАЛЫ) ==="
input ENUM_TIMEFRAMES InpWorkTF    = PERIOD_M5;     // Рабочий таймфрейм (скальпинг)
input ENUM_TIMEFRAMES InpTrendTF   = PERIOD_M15;    // Старший ТФ для MTF-фильтра
input bool     InpUseMTFFilter     = true;          // Включить мультитаймфрейм-фильтр
input int      InpEmaFast          = 5;             // EMA быстрая (скальпинг)
input int      InpEmaSlow          = 13;            // EMA медленная (скальпинг)
input int      InpEmaTrend         = 50;            // EMA тренда (на старшем ТФ M15)
input int      InpRsiPeriod        = 7;             // Период RSI (быстрый для скальпинга)
input double   InpRsiBuyMax        = 75.0;          // RSI: не покупать выше этого уровня
input double   InpRsiSellMin       = 25.0;          // RSI: не продавать ниже этого уровня
input int      InpAtrPeriod        = 14;            // Период ATR

//--- Управление позицией / выход -----------------------------------
input group "=== ВЫХОД / УПРАВЛЕНИЕ ПОЗИЦИЕЙ ==="
input double   InpSL_ATR_Mult      = 1.5;           // Stop Loss = ATR * множитель (тесный для скальпинга)
input double   InpTP_ATR_Mult      = 1.5;           // Take Profit = ATR * множитель (быстрая фиксация)
input bool     InpUseTrailing      = true;          // Включить трейлинг-стоп
input double   InpTrail_ATR_Mult   = 1.0;           // Дистанция трейлинга = ATR * множитель
input bool     InpUseBreakEven     = true;          // Включить перенос в безубыток
input double   InpBE_TriggerATR    = 0.6;           // BE: сработать после движения ATR * множитель
input double   InpBE_LockPips      = 20.0;          // BE: зафиксировать прибыль (пункты цены)
input bool     InpUsePartialClose  = true;          // Включить частичное закрытие
input double   InpPartial_TriggerATR= 0.8;          // Частичное закрытие: цель ATR * множитель
input double   InpPartial_Percent  = 50.0;          // % объёма для частичного закрытия
input bool     InpExitOnOpposite   = true;          // Выход по противоположному сигналу

//--- Риск- и денежный менеджмент -----------------------------------
input group "=== РИСК-МЕНЕДЖМЕНТ ==="
input bool     InpUseRiskPercent   = false;         // Считать лот от % риска (для $15 → фикс. лот)
input double   InpRiskPercent      = 2.0;           // Риск на сделку (% от эквити), если включён
input double   InpFixedLot         = 0.01;          // Фикс. лот (мин. лот XAUUSD у XM = 0.01)
input double   InpMaxLot           = 0.10;          // Ограничение макс. лота (малый депозит!)
input double   InpDailyLossPct     = 10.0;          // Дневной лимит убытка (% от баланса)
input double   InpMaxDrawdownPct   = 30.0;          // Макс. просадка от пика эквити (%)
input double   InpMinEquityStop    = 15.0;          // Мин. эквити ($): ниже — полная остановка
input int      InpMaxPositions     = 1;             // Макс. одновременных позиций (всего)
input int      InpMaxPerSymbol     = 1;             // Макс. позиций на один символ

//--- Фильтры безопасности ------------------------------------------
input group "=== ФИЛЬТРЫ БЕЗОПАСНОСТИ ==="
input double   InpMaxSpreadPips    = 40.0;          // Макс. спред (пункты цены; золото ~20-35)
input bool     InpUseSessionFilter = true;          // Фильтр торговой сессии
input int      InpSessionStartHour = 9;             // Начало торговли (час сервера; актив. золота)
input int      InpSessionEndHour   = 20;            // Конец торговли (час сервера)
input bool     InpUseVolatilityFlt = true;          // Фильтр по волатильности ATR
input double   InpAtrMinPips       = 20.0;          // Мин. ATR для входа (пункты цены)
input double   InpAtrMaxPips       = 800.0;         // Макс. ATR для входа (пункты цены)
input bool     InpUseNewsFilter    = true;          // Фильтр новостей (кален. MQL5)
input int      InpNewsMinsBefore   = 15;            // Стоп торговли за N мин до новости
input int      InpNewsMinsAfter    = 15;            // Стоп торговли N мин после новости
input string   InpNewsCurrencies   = "USD,EUR";     // Валюты новостей (золото чувств. к USD)
input bool     InpUseWeekendFilter = true;          // Не открывать перед выходными
input int      InpFridayCloseHour  = 21;            // В пятницу не открывать после этого часа
input bool     InpCloseBeforeWeekend = false;       // Закрывать все позиции перед выходными

//--- Уведомления / мониторинг --------------------------------------
input group "=== УВЕДОМЛЕНИЯ / МОНИТОРИНГ ==="
input bool     InpUseTelegram      = true;          // Уведомления в Telegram
input string   InpTelegramToken    = "8507213977:AAEugqHLl804tgCiYZJqRDXbAl43ONS8Kfg"; // Telegram Bot Token
input string   InpTelegramChatID   = "1978497895";  // Telegram Chat ID
input bool     InpUsePush          = false;         // Push-уведомления MetaTrader
input bool     InpLogToFile        = true;          // Логировать в файл
input bool     InpShowDashboard    = true;          // Показывать панель на графике

//====================================================================
//                        ГЛОБАЛЬНЫЕ ОБЪЕКТЫ                          
//====================================================================
CTrade         trade;         // Торговый объект
CPositionInfo  posInfo;       // Инфо о позиции
CSymbolInfo    symInfo;       // Инфо о символе

//--- Хендлы индикаторов --------------------------------------------
int hEmaFast   = INVALID_HANDLE;
int hEmaSlow   = INVALID_HANDLE;
int hRsi       = INVALID_HANDLE;
int hAtr       = INVALID_HANDLE;
int hEmaTrend  = INVALID_HANDLE;   // старший ТФ

//--- Состояние учёта -----------------------------------------------
double   g_dayStartBalance = 0.0;   // Баланс на начало дня
double   g_equityPeak      = 0.0;   // Пик эквити (для расчёта просадки)
int      g_currentDay      = -1;    // Текущий день (для сброса дневной статистики)
bool     g_tradingHalted   = false; // Полная остановка (просадка)
bool     g_dayHalted       = false; // Остановка на день (дневной убыток)
datetime g_lastBarTime     = 0;     // Время последнего обработанного бара
string   g_logFileName     = "";    // Имя файла лога
int      g_dashLabels      = 0;     // Счётчик объектов панели

//--- Направление сигнала -------------------------------------------
enum ENUM_SIGNAL { SIGNAL_NONE=0, SIGNAL_BUY=1, SIGNAL_SELL=-1 };

//+------------------------------------------------------------------+
//|                          OnInit                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Защита от повторной/некорректной инициализации ------------
   if(!ValidateInputs())
      return(INIT_PARAMETERS_INCORRECT);

   //--- Настройка торгового объекта -------------------------------
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpMaxSlippage);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);
   trade.LogLevel(LOG_LEVEL_ERRORS);

   if(!symInfo.Name(_Symbol))
   {
      Print("Ошибка: не удалось инициализировать символ ", _Symbol);
      return(INIT_FAILED);
   }

   //--- Создание хендлов индикаторов ------------------------------
   hEmaFast  = iMA(_Symbol, InpWorkTF, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
   hEmaSlow  = iMA(_Symbol, InpWorkTF, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
   hRsi      = iRSI(_Symbol, InpWorkTF, InpRsiPeriod, PRICE_CLOSE);
   hAtr      = iATR(_Symbol, InpWorkTF, InpAtrPeriod);
   hEmaTrend = iMA(_Symbol, InpTrendTF, InpEmaTrend, 0, MODE_EMA, PRICE_CLOSE);

   if(hEmaFast==INVALID_HANDLE || hEmaSlow==INVALID_HANDLE ||
      hRsi==INVALID_HANDLE || hAtr==INVALID_HANDLE || hEmaTrend==INVALID_HANDLE)
   {
      Print("Ошибка создания хендлов индикаторов. Код: ", GetLastError());
      return(INIT_FAILED);
   }

   //--- Инициализация учёта дня/просадки --------------------------
   g_logFileName = "TrendMasterEA_" + _Symbol + ".log";
   g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_equityPeak      = AccountInfoDouble(ACCOUNT_EQUITY);
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   g_currentDay = dt.day;

   //--- Таймер для панели/учёта (раз в секунду) -------------------
   EventSetTimer(1);

   Log("=== EA инициализирован. Symbol=" + _Symbol +
       " TF=" + EnumToString(InpWorkTF) +
       " Magic=" + (string)InpMagicNumber + " ===");

   if(InpShowDashboard)
      CreateDashboard();

   //--- Тестовое уведомление при старте (проверка связи) ----------
   SendStartupNotification();

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Стартовое уведомление: проверяет связь с Telegram/Push при старте |
//| В тестере не отправляется (защита внутри Notify).                 |
//+------------------------------------------------------------------+
void SendStartupNotification()
{
   string msg = StringFormat("🚀 EA запущен | %s %s | Баланс=%.2f | Magic=%I64d",
                             _Symbol,
                             EnumToString(InpWorkTF),
                             AccountInfoDouble(ACCOUNT_BALANCE),
                             InpMagicNumber);
   Log(msg);
   Notify(msg);
}

//+------------------------------------------------------------------+
//|                          OnDeinit                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();

   //--- Освобождаем хендлы ----------------------------------------
   if(hEmaFast!=INVALID_HANDLE)  IndicatorRelease(hEmaFast);
   if(hEmaSlow!=INVALID_HANDLE)  IndicatorRelease(hEmaSlow);
   if(hRsi!=INVALID_HANDLE)      IndicatorRelease(hRsi);
   if(hAtr!=INVALID_HANDLE)      IndicatorRelease(hAtr);
   if(hEmaTrend!=INVALID_HANDLE) IndicatorRelease(hEmaTrend);

   //--- Чистим панель ---------------------------------------------
   ObjectsDeleteAll(0, "TMD_");
   ChartRedraw();

   Log("=== EA остановлен. Причина деинициализации: " + (string)reason + " ===");
}

//+------------------------------------------------------------------+
//|                          OnTimer                                  |
//|  Обновление панели и учёта раз в секунду (не в тике)             |
//+------------------------------------------------------------------+
void OnTimer()
{
   UpdateAccountState();
   if(InpShowDashboard)
      UpdateDashboard();
}

//+------------------------------------------------------------------+
//|                          OnTick                                   |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- Управление уже открытыми позициями на каждом тике ---------
   ManageOpenPositions();

   //--- Проверка лимитов риска (обновляет флаги остановки) --------
   UpdateAccountState();
   if(g_tradingHalted || g_dayHalted)
      return;

   //--- Работаем только на закрытии бара (без дребезга сигналов) --
   datetime curBarTime = iTime(_Symbol, InpWorkTF, 0);
   if(curBarTime == g_lastBarTime)
      return;
   g_lastBarTime = curBarTime;

   //--- Закрытие перед выходными (если включено) ------------------
   if(InpCloseBeforeWeekend && IsWeekendApproaching())
   {
      CloseAllPositions("Закрытие перед выходными");
      return;
   }

   //--- Генерация сигнала ------------------------------------------
   ENUM_SIGNAL signal = CheckEntrySignal();

   //--- Выход по противоположному сигналу -------------------------
   if(InpExitOnOpposite && signal != SIGNAL_NONE)
      CloseOppositePositions(signal);

   if(signal == SIGNAL_NONE)
      return;

   //--- Прогон всех фильтров безопасности -------------------------
   if(!PassAllFilters(signal))
      return;

   //--- Проверка лимитов на кол-во позиций ------------------------
   if(!PositionLimitsOK())
      return;

   //--- Исполнение ------------------------------------------------
   ExecuteEntry(signal);
}

//====================================================================
//                     МОДУЛЬ 1: СИГНАЛЫ                             
//====================================================================

//+------------------------------------------------------------------+
//| Генерация торгового сигнала: EMA cross + RSI + MTF-тренд          |
//| Возвращает SIGNAL_BUY / SIGNAL_SELL / SIGNAL_NONE                 |
//+------------------------------------------------------------------+
ENUM_SIGNAL CheckEntrySignal()
{
   double emaFast[3], emaSlow[3], rsi[2];

   //--- Копируем данные закрытых баров (индекс 1 и 2) -------------
   if(CopyBuffer(hEmaFast, 0, 1, 2, emaFast) < 2) return SIGNAL_NONE;
   if(CopyBuffer(hEmaSlow, 0, 1, 2, emaSlow) < 2) return SIGNAL_NONE;
   if(CopyBuffer(hRsi,     0, 1, 1, rsi)     < 1) return SIGNAL_NONE;

   // emaFast[0] = бар 1 (последний закрытый), emaFast[1] = бар 2
   bool crossUp   = (emaFast[1] <= emaSlow[1]) && (emaFast[0] > emaSlow[0]);
   bool crossDown = (emaFast[1] >= emaSlow[1]) && (emaFast[0] < emaSlow[0]);

   //--- BUY: пересечение вверх + RSI не перекуплен ----------------
   if(crossUp && rsi[0] < InpRsiBuyMax)
   {
      if(!InpUseMTFFilter || TrendDirection() == SIGNAL_BUY)
      {
         Log(StringFormat("Сигнал BUY: EMA cross up (%.5f>%.5f), RSI=%.1f",
                          emaFast[0], emaSlow[0], rsi[0]));
         return SIGNAL_BUY;
      }
   }

   //--- SELL: пересечение вниз + RSI не перепродан ----------------
   if(crossDown && rsi[0] > InpRsiSellMin)
   {
      if(!InpUseMTFFilter || TrendDirection() == SIGNAL_SELL)
      {
         Log(StringFormat("Сигнал SELL: EMA cross down (%.5f<%.5f), RSI=%.1f",
                          emaFast[0], emaSlow[0], rsi[0]));
         return SIGNAL_SELL;
      }
   }

   return SIGNAL_NONE;
}

//+------------------------------------------------------------------+
//| MTF-фильтр: направление тренда на старшем ТФ по цене vs EMA(50)   |
//+------------------------------------------------------------------+
ENUM_SIGNAL TrendDirection()
{
   double emaTrend[1];
   if(CopyBuffer(hEmaTrend, 0, 1, 1, emaTrend) < 1) return SIGNAL_NONE;

   double closeTrend = iClose(_Symbol, InpTrendTF, 1);
   if(closeTrend <= 0) return SIGNAL_NONE;

   if(closeTrend > emaTrend[0]) return SIGNAL_BUY;
   if(closeTrend < emaTrend[0]) return SIGNAL_SELL;
   return SIGNAL_NONE;
}

//+------------------------------------------------------------------+
//| Текущее значение ATR (последний закрытый бар), в цене            |
//+------------------------------------------------------------------+
double GetATR()
{
   double atr[1];
   if(CopyBuffer(hAtr, 0, 1, 1, atr) < 1) return 0.0;
   return atr[0];
}

//====================================================================
//                     МОДУЛЬ 2: ФИЛЬТРЫ                             
//====================================================================

//+------------------------------------------------------------------+
//| Прогон всех фильтров безопасности                                 |
//+------------------------------------------------------------------+
bool PassAllFilters(ENUM_SIGNAL signal)
{
   if(!SpreadOK())       { Log("Фильтр: спред слишком высокий — вход отменён"); return false; }
   if(!SessionOK())      { Log("Фильтр: вне торговой сессии — вход отменён");    return false; }
   if(!VolatilityOK())   { Log("Фильтр: ATR вне допустимого диапазона");         return false; }
   if(!WeekendOK())      { Log("Фильтр: приближаются выходные — вход отменён");   return false; }
   if(!NewsOK())         { Log("Фильтр: рядом важная новость — вход отменён");    return false; }
   return true;
}

//+------------------------------------------------------------------+
//| Фильтр спреда                                                     |
//+------------------------------------------------------------------+
bool SpreadOK()
{
   double spreadPips = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD)
                       * _Point / PipSize();
   return (spreadPips <= InpMaxSpreadPips);
}

//+------------------------------------------------------------------+
//| Фильтр торговой сессии (по часу сервера)                          |
//+------------------------------------------------------------------+
bool SessionOK()
{
   if(!InpUseSessionFilter) return true;
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   int h = dt.hour;
   if(InpSessionStartHour <= InpSessionEndHour)
      return (h >= InpSessionStartHour && h < InpSessionEndHour);
   // сессия через полночь
   return (h >= InpSessionStartHour || h < InpSessionEndHour);
}

//+------------------------------------------------------------------+
//| Фильтр волатильности (ATR)                                        |
//+------------------------------------------------------------------+
bool VolatilityOK()
{
   if(!InpUseVolatilityFlt) return true;
   double atrPips = GetATR() / PipSize();
   return (atrPips >= InpAtrMinPips && atrPips <= InpAtrMaxPips);
}

//+------------------------------------------------------------------+
//| Фильтр выходных                                                   |
//+------------------------------------------------------------------+
bool WeekendOK()
{
   if(!InpUseWeekendFilter) return true;
   return !IsWeekendApproaching();
}

//+------------------------------------------------------------------+
//| Приближаются ли выходные (пятница после заданного часа / сб/вс)   |
//+------------------------------------------------------------------+
bool IsWeekendApproaching()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_week == 5 && dt.hour >= InpFridayCloseHour) return true; // пятница
   if(dt.day_of_week == 6 || dt.day_of_week == 0) return true;          // сб/вс
   return false;
}

//+------------------------------------------------------------------+
//| Фильтр новостей через экономический календарь MQL5                |
//| ВАЖНО: календарь недоступен в Strategy Tester — там всегда true.  |
//+------------------------------------------------------------------+
bool NewsOK()
{
   if(!InpUseNewsFilter) return true;
   if(MQLInfoInteger(MQL_TESTER)) return true; // в тестере календаря нет

   datetime now = TimeCurrent();
   datetime from = now - InpNewsMinsAfter*60;
   datetime to   = now + InpNewsMinsBefore*60;

   string currencies[];
   int cnt = StringSplit(InpNewsCurrencies, ',', currencies);
   if(cnt <= 0) return true;

   for(int c=0; c<cnt; c++)
   {
      string cur = currencies[c];
      StringTrimLeft(cur); StringTrimRight(cur);
      if(cur == "") continue;

      MqlCalendarValue values[];
      int n = CalendarValueHistory(values, from, to, NULL, cur);
      for(int i=0; i<n; i++)
      {
         MqlCalendarEvent event;
         if(!CalendarEventById(values[i].event_id, event)) continue;
         // Реагируем только на важные (high impact) события
         if(event.importance == CALENDAR_IMPORTANCE_HIGH)
         {
            Log("Новостной фильтр: рядом важная новость по " + cur);
            return false;
         }
      }
   }
   return true;
}

//====================================================================
//                МОДУЛЬ 3: РИСК-МЕНЕДЖМЕНТ                          
//====================================================================

//+------------------------------------------------------------------+
//| Обновление состояния счёта: дневной убыток и просадка от пика     |
//+------------------------------------------------------------------+
void UpdateAccountState()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);

   //--- Сброс дневной статистики при смене дня --------------------
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(dt.day != g_currentDay)
   {
      g_currentDay = dt.day;
      g_dayStartBalance = balance;
      g_dayHalted = false;
      Log("Новый торговый день. Дневной учёт сброшен. Баланс=" + DoubleToString(balance,2));
   }

   //--- Обновление пика эквити ------------------------------------
   if(equity > g_equityPeak)
      g_equityPeak = equity;

   //--- Дневной лимит убытка --------------------------------------
   if(!g_dayHalted && InpDailyLossPct > 0.0)
   {
      double dayPnL = equity - g_dayStartBalance;
      double dayLossLimit = -g_dayStartBalance * InpDailyLossPct / 100.0;
      if(dayPnL <= dayLossLimit)
      {
         g_dayHalted = true;
         string msg = StringFormat("СТОП НА ДЕНЬ: дневной убыток %.2f достиг лимита %.2f",
                                   dayPnL, dayLossLimit);
         Log(msg);
         Notify("⛔ " + msg);
      }
   }

   //--- Макс. просадка от пика эквити -----------------------------
   if(!g_tradingHalted && InpMaxDrawdownPct > 0.0 && g_equityPeak > 0.0)
   {
      double ddPct = (g_equityPeak - equity) / g_equityPeak * 100.0;
      if(ddPct >= InpMaxDrawdownPct)
      {
         g_tradingHalted = true;
         string msg = StringFormat("ПОЛНАЯ ОСТАНОВКА: просадка %.2f%% >= лимит %.2f%%",
                                   ddPct, InpMaxDrawdownPct);
         Log(msg);
         Notify("🛑 " + msg);
      }
   }

   //--- Минимальный бюджет: эквити ниже порога → полная остановка --
   if(!g_tradingHalted && InpMinEquityStop > 0.0 && equity < InpMinEquityStop)
   {
      g_tradingHalted = true;
      string msg = StringFormat("ПОЛНАЯ ОСТАНОВКА: эквити %.2f < мин. бюджет %.2f",
                                equity, InpMinEquityStop);
      Log(msg);
      Notify("🛑 " + msg);
   }
}

//+------------------------------------------------------------------+
//| Расчёт лота от % риска и дистанции стоп-лосса                     |
//| slDistancePrice — дистанция SL в цене (не в пунктах)             |
//+------------------------------------------------------------------+
double CalculateLotSize(double slDistancePrice)
{
   double lot = InpFixedLot;

   if(InpUseRiskPercent && slDistancePrice > 0.0)
   {
      double equity      = AccountInfoDouble(ACCOUNT_EQUITY);
      double riskMoney   = equity * InpRiskPercent / 100.0;

      double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      if(tickSize <= 0.0) tickSize = _Point;

      // Убыток на 1 лот при данной дистанции SL
      double lossPerLot = (slDistancePrice / tickSize) * tickValue;
      if(lossPerLot <= 0.0)
         return NormalizeLot(InpFixedLot);

      lot = riskMoney / lossPerLot;
   }

   return NormalizeLot(lot);
}

//+------------------------------------------------------------------+
//| Нормализация лота к шагу/мин/макс объёма символа                  |
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(lotStep <= 0.0) lotStep = 0.01;

   lot = MathFloor(lot / lotStep) * lotStep;
   lot = MathMax(lot, minLot);
   lot = MathMin(lot, maxLot);
   lot = MathMin(lot, InpMaxLot);

   int lotDigits = (int)MathMax(0, -MathLog10(lotStep) + 0.5);
   return NormalizeDouble(lot, lotDigits);
}

//+------------------------------------------------------------------+
//| Проверка лимитов на количество позиций                            |
//+------------------------------------------------------------------+
bool PositionLimitsOK()
{
   int total = 0, onSymbol = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      total++;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol) onSymbol++;
   }

   if(total >= InpMaxPositions)
   {
      Log("Лимит: достигнут максимум позиций (" + (string)total + ")");
      return false;
   }
   if(onSymbol >= InpMaxPerSymbol)
   {
      Log("Лимит: достигнут максимум позиций по символу (" + (string)onSymbol + ")");
      return false;
   }
   return true;
}

//====================================================================
//                МОДУЛЬ 4: ИСПОЛНЕНИЕ ОРДЕРОВ                       
//====================================================================

//+------------------------------------------------------------------+
//| Открытие позиции по сигналу с расчётом SL/TP и лота               |
//+------------------------------------------------------------------+
void ExecuteEntry(ENUM_SIGNAL signal)
{
   double atr = GetATR();
   if(atr <= 0.0) { Log("ATR=0, вход отменён"); return; }

   symInfo.RefreshRates();
   double ask = symInfo.Ask();
   double bid = symInfo.Bid();

   double slDist = atr * InpSL_ATR_Mult;
   double tpDist = atr * InpTP_ATR_Mult;

   double price, sl, tp;
   ENUM_ORDER_TYPE type;

   if(signal == SIGNAL_BUY)
   {
      type  = ORDER_TYPE_BUY;
      price = ask;
      sl    = NormalizePrice(price - slDist);
      tp    = NormalizePrice(price + tpDist);
   }
   else
   {
      type  = ORDER_TYPE_SELL;
      price = bid;
      sl    = NormalizePrice(price + slDist);
      tp    = NormalizePrice(price - tpDist);
   }

   //--- Проверка минимальной дистанции стопов (stops level) -------
   if(!CheckStopsLevel(price, sl, tp))
   {
      Log("Стопы ближе минимально допустимой дистанции — вход отменён");
      return;
   }

   double lot = CalculateLotSize(slDist);
   if(lot <= 0.0) { Log("Расчётный лот = 0 — вход отменён"); return; }

   //--- Исполнение с retry ----------------------------------------
   bool ok = OpenWithRetry(type, lot, price, sl, tp);

   if(ok)
   {
      string dir = (signal==SIGNAL_BUY) ? "BUY" : "SELL";
      string msg = StringFormat("Открыта %s %s lot=%.2f @%.5f SL=%.5f TP=%.5f",
                                dir, _Symbol, lot, price, sl, tp);
      Log(msg);
      Notify("📈 " + msg);
   }
}

//+------------------------------------------------------------------+
//| Открытие с обработкой ошибок и повторами (requote/timeout/price)  |
//+------------------------------------------------------------------+
bool OpenWithRetry(ENUM_ORDER_TYPE type, double lot, double price, double sl, double tp)
{
   for(int attempt = 1; attempt <= InpMaxRetries; attempt++)
   {
      symInfo.RefreshRates();
      price = (type==ORDER_TYPE_BUY) ? symInfo.Ask() : symInfo.Bid();

      bool sent;
      if(type == ORDER_TYPE_BUY)
         sent = trade.Buy(lot, _Symbol, price, sl, tp, InpTradeComment);
      else
         sent = trade.Sell(lot, _Symbol, price, sl, tp, InpTradeComment);

      uint  retcode = trade.ResultRetcode();
      if(sent && (retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_PLACED))
         return true;

      //--- Разбор кода возврата --------------------------------
      Log(StringFormat("Попытка %d/%d не удалась. Retcode=%u (%s)",
                       attempt, InpMaxRetries, retcode, trade.ResultRetcodeDescription()));

      // Повторяем только на восстановимых ошибках
      if(retcode == TRADE_RETCODE_REQUOTE  ||
         retcode == TRADE_RETCODE_PRICE_CHANGED ||
         retcode == TRADE_RETCODE_PRICE_OFF ||
         retcode == TRADE_RETCODE_TIMEOUT   ||
         retcode == TRADE_RETCODE_CONNECTION)
      {
         Sleep(InpRetryDelayMs);
         continue;
      }
      // Невосстановимая ошибка — выходим
      break;
   }
   Notify("⚠️ Не удалось открыть ордер после " + (string)InpMaxRetries + " попыток");
   return false;
}

//====================================================================
//            МОДУЛЬ 5: УПРАВЛЕНИЕ ОТКРЫТЫМИ ПОЗИЦИЯМИ               
//====================================================================

//+------------------------------------------------------------------+
//| Проход по всем позициям бота: BE, трейлинг, частичное закрытие    |
//+------------------------------------------------------------------+
void ManageOpenPositions()
{
   double atr = GetATR();

   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      long   type       = PositionGetInteger(POSITION_TYPE);
      double openPrice  = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL      = PositionGetDouble(POSITION_SL);
      double curTP      = PositionGetDouble(POSITION_TP);
      double volume     = PositionGetDouble(POSITION_VOLUME);

      symInfo.RefreshRates();
      double priceNow = (type==POSITION_TYPE_BUY) ? symInfo.Bid() : symInfo.Ask();

      //--- Частичное закрытие --------------------------------------
      if(InpUsePartialClose && atr > 0.0)
         TryPartialClose(ticket, type, openPrice, priceNow, volume, atr);

      //--- Break-even ---------------------------------------------
      if(InpUseBreakEven && atr > 0.0)
         TryBreakEven(ticket, type, openPrice, priceNow, curSL, curTP, atr);

      //--- Трейлинг -----------------------------------------------
      if(InpUseTrailing && atr > 0.0)
         TryTrailing(ticket, type, priceNow, curSL, curTP, atr);
   }
}

//+------------------------------------------------------------------+
//| Перенос стопа в безубыток                                         |
//+------------------------------------------------------------------+
void TryBreakEven(ulong ticket, long type, double openPrice, double priceNow,
                  double curSL, double curTP, double atr)
{
   double trigger = atr * InpBE_TriggerATR;
   double lock    = InpBE_LockPips * PipSize();

   if(type == POSITION_TYPE_BUY)
   {
      double newSL = NormalizePrice(openPrice + lock);
      if(priceNow - openPrice >= trigger && (curSL < openPrice || curSL == 0.0))
      {
         if(newSL > curSL)
            ModifyWithRetry(ticket, newSL, curTP, "Break-even");
      }
   }
   else // SELL
   {
      double newSL = NormalizePrice(openPrice - lock);
      if(openPrice - priceNow >= trigger && (curSL > openPrice || curSL == 0.0))
      {
         if(curSL == 0.0 || newSL < curSL)
            ModifyWithRetry(ticket, newSL, curTP, "Break-even");
      }
   }
}

//+------------------------------------------------------------------+
//| Трейлинг-стоп на базе ATR                                         |
//+------------------------------------------------------------------+
void TryTrailing(ulong ticket, long type, double priceNow,
                 double curSL, double curTP, double atr)
{
   double dist = atr * InpTrail_ATR_Mult;

   if(type == POSITION_TYPE_BUY)
   {
      double newSL = NormalizePrice(priceNow - dist);
      if(newSL > curSL && newSL < priceNow)
         ModifyWithRetry(ticket, newSL, curTP, "Trailing");
   }
   else // SELL
   {
      double newSL = NormalizePrice(priceNow + dist);
      if((curSL == 0.0 || newSL < curSL) && newSL > priceNow)
         ModifyWithRetry(ticket, newSL, curTP, "Trailing");
   }
}

//+------------------------------------------------------------------+
//| Частичное закрытие при достижении промежуточной цели              |
//| Метку о выполненном частичном закрытии храним в комментарии SL-TP |
//| через глобальную проверку: закрываем один раз (по объёму).        |
//+------------------------------------------------------------------+
void TryPartialClose(ulong ticket, long type, double openPrice,
                     double priceNow, double volume, double atr)
{
   // Признак «уже закрывали»: если объём меньше исходного расчётного —
   // используем простую эвристику через глобальную переменную терминала.
   string gvKey = "TMD_PC_" + (string)ticket;
   if(GlobalVariableCheck(gvKey))
      return; // уже было частичное закрытие

   double target = atr * InpPartial_TriggerATR;
   bool reached = (type==POSITION_TYPE_BUY)
                  ? (priceNow - openPrice >= target)
                  : (openPrice - priceNow >= target);
   if(!reached) return;

   double closeVol = NormalizeLot(volume * InpPartial_Percent / 100.0);
   double minLot   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(closeVol < minLot) return;
   if(volume - closeVol < minLot) closeVol = volume; // остаток был бы меньше мин. лота

   if(trade.PositionClosePartial(ticket, closeVol))
   {
      GlobalVariableSet(gvKey, 1);
      string msg = StringFormat("Частичное закрытие #%I64u: %.2f лот", ticket, closeVol);
      Log(msg);
      Notify("✂️ " + msg);
   }
   else
   {
      Log("Ошибка частичного закрытия #" + (string)ticket + ": " + trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Модификация SL/TP с повторами                                     |
//+------------------------------------------------------------------+
bool ModifyWithRetry(ulong ticket, double sl, double tp, string reason)
{
   for(int attempt = 1; attempt <= InpMaxRetries; attempt++)
   {
      if(trade.PositionModify(ticket, sl, tp))
      {
         Log(StringFormat("%s: #%I64u SL=%.5f TP=%.5f", reason, ticket, sl, tp));
         return true;
      }
      uint rc = trade.ResultRetcode();
      if(rc==TRADE_RETCODE_REQUOTE || rc==TRADE_RETCODE_PRICE_CHANGED ||
         rc==TRADE_RETCODE_TIMEOUT || rc==TRADE_RETCODE_CONNECTION)
      {
         Sleep(InpRetryDelayMs);
         continue;
      }
      break;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Закрытие позиций, противоположных новому сигналу                  |
//+------------------------------------------------------------------+
void CloseOppositePositions(ENUM_SIGNAL signal)
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      long type = PositionGetInteger(POSITION_TYPE);
      bool opposite = (signal==SIGNAL_BUY  && type==POSITION_TYPE_SELL) ||
                      (signal==SIGNAL_SELL && type==POSITION_TYPE_BUY);
      if(opposite)
      {
         if(trade.PositionClose(ticket))
         {
            GlobalVariableDel("TMD_PC_" + (string)ticket);
            Log("Закрыта позиция #" + (string)ticket + " по противоположному сигналу");
            Notify("🔄 Закрыта #" + (string)ticket + " (реверс сигнала)");
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Закрыть все позиции бота                                          |
//+------------------------------------------------------------------+
void CloseAllPositions(string reason)
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      if(trade.PositionClose(ticket))
      {
         GlobalVariableDel("TMD_PC_" + (string)ticket);
         Log("Закрыта #" + (string)ticket + ": " + reason);
      }
   }
}

//====================================================================
//          МОДУЛЬ 6: НОРМАЛИЗАЦИЯ / ВСПОМОГАТЕЛЬНЫЕ                  
//====================================================================

//+------------------------------------------------------------------+
//| Размер пункта (pip): для 5/3-значных котировок = 10*Point         |
//+------------------------------------------------------------------+
double PipSize()
{
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(digits == 5 || digits == 3)
      return _Point * 10.0;
   return _Point;
}

//+------------------------------------------------------------------+
//| Нормализация цены к Digits символа                                |
//+------------------------------------------------------------------+
double NormalizePrice(double price)
{
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   return NormalizeDouble(price, digits);
}

//+------------------------------------------------------------------+
//| Проверка минимальной дистанции стопов (SYMBOL_TRADE_STOPS_LEVEL)  |
//+------------------------------------------------------------------+
bool CheckStopsLevel(double price, double sl, double tp)
{
   long stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist = stopsLevel * _Point;
   if(minDist <= 0.0) return true;

   if(sl > 0.0 && MathAbs(price - sl) < minDist) return false;
   if(tp > 0.0 && MathAbs(price - tp) < minDist) return false;
   return true;
}

//+------------------------------------------------------------------+
//| Проверка корректности входных параметров                          |
//+------------------------------------------------------------------+
bool ValidateInputs()
{
   bool ok = true;
   if(InpEmaFast >= InpEmaSlow)
      { Print("Ошибка: EMA быстрая должна быть < EMA медленной"); ok=false; }
   if(InpRiskPercent <= 0.0 && InpUseRiskPercent)
      { Print("Ошибка: риск % должен быть > 0"); ok=false; }
   if(InpSL_ATR_Mult <= 0.0)
      { Print("Ошибка: множитель SL должен быть > 0"); ok=false; }
   if(InpUseTelegram && (InpTelegramToken=="" || InpTelegramChatID==""))
      Print("Внимание: Telegram включён, но токен/chat_id пустые — уведомления отключены");

   //--- Предупреждение о малом бюджете (золото + $15) -------------
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq > 0.0 && eq < 100.0)
      Print(StringFormat("ВНИМАНИЕ: эквити %.2f очень мало для XAUUSD. "
            "Мин. лот 0.01 на золоте несёт высокий риск. Один стоп может "
            "составить 10-20%% депозита. Используйте только на демо/риск-капитал.", eq));
   return ok;
}

//====================================================================
//          МОДУЛЬ 7: ЛОГИРОВАНИЕ И УВЕДОМЛЕНИЯ                      
//====================================================================

//+------------------------------------------------------------------+
//| Лог в журнал терминала + файл (Files/)                            |
//+------------------------------------------------------------------+
void Log(string message)
{
   string line = TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS) + " | " + message;
   Print(line);

   if(!InpLogToFile) return;

   int h = FileOpen(g_logFileName, FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI);
   if(h != INVALID_HANDLE)
   {
      FileSeek(h, 0, SEEK_END);
      FileWriteString(h, line + "\r\n");
      FileClose(h);
   }
}

//+------------------------------------------------------------------+
//| Единая точка отправки уведомлений (Telegram + Push)               |
//+------------------------------------------------------------------+
void Notify(string message)
{
   if(InpUsePush && !MQLInfoInteger(MQL_TESTER))
      SendNotification(message);

   if(InpUseTelegram && !MQLInfoInteger(MQL_TESTER) &&
      InpTelegramToken != "" && InpTelegramChatID != "")
      SendTelegram(message);
}

//+------------------------------------------------------------------+
//| Отправка сообщения через Telegram Bot API (WebRequest)            |
//| Требует добавить https://api.telegram.org в список разрешённых    |
//| URL: Сервис -> Настройки -> Советники -> Разрешить WebRequest.    |
//+------------------------------------------------------------------+
void SendTelegram(string message)
{
   string url = "https://api.telegram.org/bot" + InpTelegramToken + "/sendMessage";
   string params = "chat_id=" + InpTelegramChatID +
                   "&text=" + UrlEncode("[" + _Symbol + "] " + message);

   char post[], result[];
   string headers = "Content-Type: application/x-www-form-urlencoded\r\n";
   string resultHeaders;

   // Тело POST без завершающего нуля (params уже URL-кодирован, все байты ASCII)
   int bodyLen = StringToCharArray(params, post, 0, StringLen(params), CP_UTF8);
   ArrayResize(post, bodyLen);

   ResetLastError();
   int res = WebRequest("POST", url, headers, 5000, post, result, resultHeaders);
   if(res == -1)
   {
      int err = GetLastError();
      Print("Telegram WebRequest ошибка ", err,
            " — добавьте https://api.telegram.org в разрешённые URL");
   }
}

//+------------------------------------------------------------------+
//| Простое URL-кодирование для текста Telegram                       |
//+------------------------------------------------------------------+
string UrlEncode(string text)
{
   string result = "";
   uchar bytes[];
   int len = StringToCharArray(text, bytes, 0, -1, CP_UTF8) - 1;
   for(int i=0; i<len; i++)
   {
      uchar c = bytes[i];
      if((c>='0'&&c<='9') || (c>='A'&&c<='Z') || (c>='a'&&c<='z') ||
         c=='-'||c=='_'||c=='.'||c=='~')
         result += CharToString(c);
      else if(c==' ')
         result += "%20";
      else
         result += StringFormat("%%%02X", c);
   }
   return result;
}

//====================================================================
//                МОДУЛЬ 8: ПАНЕЛЬ (DASHBOARD)                       
//====================================================================

//+------------------------------------------------------------------+
//| Создание объектов панели                                          |
//+------------------------------------------------------------------+
void CreateDashboard()
{
   CreateLabel("TMD_title", "TrendMasterEA", 10, 20, clrGold, 11, true);
   for(int i=1; i<=9; i++)
      CreateLabel("TMD_line"+(string)i, "", 10, 20+i*18, clrWhite, 9, false);
}

//+------------------------------------------------------------------+
//| Создание текстовой метки                                          |
//+------------------------------------------------------------------+
void CreateLabel(string name, string text, int x, int y, color clr, int size, bool bold)
{
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, size);
   ObjectSetString(0, name, OBJPROP_FONT, bold ? "Arial Bold" : "Arial");
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
}

//+------------------------------------------------------------------+
//| Обновление содержимого панели                                     |
//+------------------------------------------------------------------+
void UpdateDashboard()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double dayPnL  = equity - g_dayStartBalance;
   double ddPct   = (g_equityPeak>0.0) ? (g_equityPeak-equity)/g_equityPeak*100.0 : 0.0;

   int posCount = 0;
   double floatPnL = 0.0;
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      if(PositionGetTicket(i)==0) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber) continue;
      posCount++;
      floatPnL += PositionGetDouble(POSITION_PROFIT);
   }

   string status = g_tradingHalted ? "ОСТАНОВЛЕН (просадка)" :
                   (g_dayHalted ? "СТОП НА ДЕНЬ" : "АКТИВЕН");
   color statusClr = (g_tradingHalted||g_dayHalted) ? clrTomato : clrLime;

   ObjectSetString(0, "TMD_line1", OBJPROP_TEXT, "Статус: " + status);
   ObjectSetInteger(0,"TMD_line1", OBJPROP_COLOR, statusClr);
   ObjectSetString(0, "TMD_line2", OBJPROP_TEXT, StringFormat("Баланс:  %.2f", balance));
   ObjectSetString(0, "TMD_line3", OBJPROP_TEXT, StringFormat("Эквити:  %.2f", equity));
   ObjectSetString(0, "TMD_line4", OBJPROP_TEXT, StringFormat("Дневной P&L: %.2f", dayPnL));
   ObjectSetString(0, "TMD_line5", OBJPROP_TEXT, StringFormat("Плав. P&L:  %.2f", floatPnL));
   ObjectSetString(0, "TMD_line6", OBJPROP_TEXT, StringFormat("Просадка:   %.2f%%", ddPct));
   ObjectSetString(0, "TMD_line7", OBJPROP_TEXT, StringFormat("Позиций:    %d / %d", posCount, InpMaxPositions));
   ObjectSetString(0, "TMD_line8", OBJPROP_TEXT, StringFormat("Спред: %.1f | ATR: %.1f",
                   (double)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD)*_Point/PipSize(),
                   GetATR()/PipSize()));
   ObjectSetString(0, "TMD_line9", OBJPROP_TEXT, "Фильтры: " +
                   (SessionOK()?"Сессия✔ ":"Сессия✗ ") +
                   (SpreadOK()?"Спред✔ ":"Спред✗ ") +
                   (VolatilityOK()?"ATR✔":"ATR✗"));
   ChartRedraw();
}
//+------------------------------------------------------------------+
