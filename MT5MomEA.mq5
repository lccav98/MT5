//+------------------------------------------------------------------+
//|                                                   MT5MomEA.mq5   |
//|                        Ecosystem: MT5 Momentum & SMC Robot       |
//|                                             https://github.com/  |
//+------------------------------------------------------------------+
#property copyright "Luiz Claudio Araujo"
#property link      "https://github.com/"
#property version   "2.60"
#property description "Expert Advisor de Momentum, Volume e SMC Altamente Responsivo com FVG Ativo"
#property description "Opera de forma 100% nativa e automatizada no MetaTrader 5 (macOS/Windows)"
#property description "Filtros de Smart Money (Fair Value Gap) ativados e calibrados por padrão"

// Inclui classe oficial para envio de ordens simplificado
#include <Trade\Trade.mqh>
CTrade trade;

//--- Parâmetros de Entrada (Inputs)
input group "=== Configurações de Momentum ==="
input double   c1_thresh         = 0.0005;    // Momentum de 1 candle do Timeframe (0.05%)
input double   c5_thresh         = 0.001;     // Momentum de 5 candles do Timeframe (0.10%)
input bool     use_ema_alignment = true;      // Exigir alinhamento de médias (5 > 10 > 21)
input bool     allow_short       = true;      // Permitir operações de Venda (Short)

input group "=== Smart Money Concepts (SMC) & Volume (SMC ATIVO) ==="
input bool     use_fvg_filter    = true;      // Exigir Fair Value Gap (Imbalanço FVG Ativo por Padrão)
input bool     use_volume_filter = true;      // Exigir Volume acima da média
input int      volume_ma_period  = 20;        // Período da média simples do Volume
input double   volume_mult       = 1.5;       // Multiplicador de Volume (1.5 = 50% acima da média para seletividade institucional)

input group "=== Filtros de Indicadores ==="
input double   atr_mult          = 2.2;       // Multiplicador de volatilidade do ATR
input int      rsi_max           = 70;        // RSI máximo para Compra (evitar sobrecompra)
input int      rsi_min           = 30;        // RSI mínimo para Venda (evitar sobrevenda)
input int      stoch_max         = 80;        // Estocástico máximo para Compra
input int      stoch_min         = 20;        // Estocástico mínimo para Venda
input int      adx_thresh        = 20;        // ADX mínimo para força de tendência

input group "=== Gerenciamento de Risco (OCO) ==="
input double   lot_size          = 0.1;       // Tamanho do Lote fixo
input double   profit_target_1   = 0.005;     // Alvo 1 de lucro (0.5% - Parcial/Break-Even)
input double   profit_target_2   = 0.030;     // Alvo 2 de lucro final (3.0%)
input double   stop_loss_pct     = 0.015;     // Stop Loss inicial (1.5%)

input group "=== Depuração ==="
input bool     print_diagnostics = true;      // Imprimir status dos filtros a cada fechamento de candle
bool           force_test_trade  = false;     // MODO TESTE FORÇADO: Abre trade de teste imediatamente para validação

//--- Estrutura para gerenciar handles de indicadores por ativo
struct SymbolHandles
{
   string symbol;
   int handle_ema5;
   int handle_ema10;
   int handle_ema21;
   int handle_ema20;
   int handle_ema50;
   int handle_rsi;
   int handle_stoch;
   int handle_adx;
   int handle_atr;
   int handle_ema20_htf;
   datetime last_time; // Controle individual de candle fechado por ativo
};

//--- Array global de ativos monitorados
SymbolHandles symbol_list[];

//--- Variável global para armazenar o ID mágico exclusivo do timeframe
int active_magic_id = 123456;

//--- Configuração dinâmica do timeframe através do painel
input group "=== Configurações de Timeframe (Multiframe) ==="
input ENUM_TIMEFRAMES operation_timeframe = PERIOD_M1;  // Tempo gráfico de operação (M1 a M30)
input bool            use_htf_filter      = false;      // Usar confluência de tendência de Timeframe Maior (HTF)
input ENUM_TIMEFRAMES htf_period          = PERIOD_M15; // Timeframe Maior de Confirmação (ex: M15 ou M30)

//+------------------------------------------------------------------+
//| Libera handles de indicadores de todos os ativos da lista        |
//+------------------------------------------------------------------+
void ReleaseAllHandles()
{
   int size = ArraySize(symbol_list);
   for(int i = 0; i < size; i++)
   {
      if(symbol_list[i].handle_ema5 != INVALID_HANDLE)      IndicatorRelease(symbol_list[i].handle_ema5);
      if(symbol_list[i].handle_ema10 != INVALID_HANDLE)     IndicatorRelease(symbol_list[i].handle_ema10);
      if(symbol_list[i].handle_ema21 != INVALID_HANDLE)     IndicatorRelease(symbol_list[i].handle_ema21);
      if(symbol_list[i].handle_ema20 != INVALID_HANDLE)     IndicatorRelease(symbol_list[i].handle_ema20);
      if(symbol_list[i].handle_ema50 != INVALID_HANDLE)     IndicatorRelease(symbol_list[i].handle_ema50);
      if(symbol_list[i].handle_rsi != INVALID_HANDLE)       IndicatorRelease(symbol_list[i].handle_rsi);
      if(symbol_list[i].handle_stoch != INVALID_HANDLE)     IndicatorRelease(symbol_list[i].handle_stoch);
      if(symbol_list[i].handle_adx != INVALID_HANDLE)       IndicatorRelease(symbol_list[i].handle_adx);
      if(symbol_list[i].handle_atr != INVALID_HANDLE)       IndicatorRelease(symbol_list[i].handle_atr);
      if(symbol_list[i].handle_ema20_htf != INVALID_HANDLE) IndicatorRelease(symbol_list[i].handle_ema20_htf);
   }
   ArrayFree(symbol_list);
}

//+------------------------------------------------------------------+
//| Inicializa a lista de ativos a partir da Observação do Mercado   |
//+------------------------------------------------------------------+
bool InitializeSymbolList()
{
   // Libera recursos anteriores se houver
   ReleaseAllHandles();

   // Habilita automaticamente todos os ativos disponíveis na corretora na Observação do Mercado
   int total_server = SymbolsTotal(false); // false = Todos os ativos do servidor
   Print("[*] Sincronizando e adicionando ", total_server, " ativos disponíveis no servidor da corretora...");
   for(int i = 0; i < total_server; i++)
   {
      string sym_name = SymbolName(i, false);
      SymbolSelect(sym_name, true); // Adiciona na Observação do Mercado
   }

   int total = SymbolsTotal(true); // true = Apenas ativos na Observação do Mercado (Market Watch)
   if(total <= 0)
   {
      Print("[-] Erro: Nenhum ativo selecionado na Observação do Mercado!");
      return false;
   }

   ArrayResize(symbol_list, total);
   Print("[*] Inicializando Scanner para ", total, " ativos visíveis na Observação do Mercado...");

   for(int i = 0; i < total; i++)
   {
      string sym = SymbolName(i, true);
      symbol_list[i].symbol = sym;
      symbol_list[i].last_time = 0;

      // Garante que o ativo esteja selecionado e sincronizado no terminal
      SymbolSelect(sym, true);

      // Criação dinâmica dos handles dos indicadores técnicos para o ativo
      symbol_list[i].handle_ema5  = iMA(sym, operation_timeframe, 5, 0, MODE_EMA, PRICE_CLOSE);
      symbol_list[i].handle_ema10 = iMA(sym, operation_timeframe, 10, 0, MODE_EMA, PRICE_CLOSE);
      symbol_list[i].handle_ema21 = iMA(sym, operation_timeframe, 21, 0, MODE_EMA, PRICE_CLOSE);
      symbol_list[i].handle_ema20 = iMA(sym, operation_timeframe, 20, 0, MODE_EMA, PRICE_CLOSE);
      symbol_list[i].handle_ema50 = iMA(sym, operation_timeframe, 50, 0, MODE_EMA, PRICE_CLOSE);

      symbol_list[i].handle_rsi   = iRSI(sym, operation_timeframe, 7, PRICE_CLOSE);
      symbol_list[i].handle_stoch = iStochastic(sym, operation_timeframe, 7, 3, 3, MODE_SMA, STO_LOWHIGH);
      symbol_list[i].handle_adx   = iADX(sym, operation_timeframe, 14);
      symbol_list[i].handle_atr   = iATR(sym, operation_timeframe, 7);

      if(use_htf_filter)
      {
         symbol_list[i].handle_ema20_htf = iMA(sym, htf_period, 20, 0, MODE_EMA, PRICE_CLOSE);
      }
      else
      {
         symbol_list[i].handle_ema20_htf = INVALID_HANDLE;
      }

      // Validação básica dos handles críticos
      if(symbol_list[i].handle_ema5 == INVALID_HANDLE || symbol_list[i].handle_rsi == INVALID_HANDLE || symbol_list[i].handle_atr == INVALID_HANDLE)
      {
         Print("[-] Erro ao criar handles para o ativo: ", sym);
         return false;
      }

      Print("[+] Scanner Ativo registrado com sucesso: ", sym);
   }

   return true;
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // Cria número mágico exclusivo para este tempo gráfico para evitar conflito de ordens paralelas
   active_magic_id = 123456 + (int)operation_timeframe;
   trade.SetExpertMagicNumber(active_magic_id);
   
   // Diagnóstico de Saldo e Margem da Conta
   Print("[i] DIAGNOSTICO DA CONTA - Saldo: ", AccountInfoDouble(ACCOUNT_BALANCE), 
         " | Margem Livre: ", AccountInfoDouble(ACCOUNT_MARGIN_FREE), 
         " | Alavancagem: 1:", AccountInfoInteger(ACCOUNT_LEVERAGE));
   
   // Inicializa a lista de múltiplos ativos monitorados pelo Scanner
   if(!InitializeSymbolList())
   {
      return(INIT_FAILED);
   }
   
   Print("[+] Robô MT5MomEA v2.70 (Scanner Multiativos Automático) iniciado com sucesso! Monitorando ", ArraySize(symbol_list), " ativos.");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Libera todos os handles de indicadores de todos os ativos da memória
   ReleaseAllHandles();
   Print("[-] Robô MT5MomEA descarregado com sucesso.");
}

//+------------------------------------------------------------------+
//| Normaliza o volume (lote) para os limites e passo do ativo       |
//+------------------------------------------------------------------+
double NormalizeVolume(string symbol, double volume)
{
   double min_volume = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double max_volume = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double volume_step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   
   if(volume_step <= 0) volume_step = 0.01;
   
   // Arredonda para o passo mais próximo
   double normalized = MathRound(volume / volume_step) * volume_step;
   
   // Garante limites mínimos e máximos
   if(normalized < min_volume) normalized = min_volume;
   if(normalized > max_volume) normalized = max_volume;
   
   // Calcula casas decimais baseadas no passo do lote
   int digits = 0;
   double step = volume_step;
   while(step < 1.0)
   {
      step *= 10.0;
      digits++;
      if(digits > 8) break;
   }
   
   return NormalizeDouble(normalized, digits);
}

//+------------------------------------------------------------------+
//| Retorna o lote base dinâmico de acordo com a classe do ativo     |
//+------------------------------------------------------------------+
double GetDynamicLotSize(string symbol)
{
   string upper_sym = symbol;
   StringToUpper(upper_sym);
   
   // 1. Metais Preciosos (Ouro, Prata, Platina, Paládio)
   if(StringFind(upper_sym, "XAG") >= 0 || StringFind(upper_sym, "XAU") >= 0 || 
      StringFind(upper_sym, "XPT") >= 0 || StringFind(upper_sym, "XPD") >= 0 ||
      StringFind(upper_sym, "SILVER") >= 0 || StringFind(upper_sym, "GOLD") >= 0)
   {
      // Reduz o lote padrão em 10x para metais preciosos (mínimo de 0.01) para gerenciar o risco
      double metal_lot = lot_size * 0.1;
      return metal_lot;
   }
   
   // 2. Ações Americanas (CFDs de Ações)
   // Se o tamanho do contrato é 1.0 (ou seja, 1 lote = 1 ação), opera com lote base de 1.0
   double contract_size = SymbolInfoDouble(symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   if(contract_size == 1.0)
   {
      return 1.0; 
   }
   
   // Retorna o lote padrão para Forex, Criptos normais e Commodities
   return lot_size;
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   int total_symbols = ArraySize(symbol_list);
   
   // Se o número de ativos na Observação do Mercado mudou, reconstrói a lista dinamicamente
   if(total_symbols != SymbolsTotal(true))
   {
      Print("[*] Mudança detectada na Observação do Mercado. Reconstruindo lista de ativos...");
      if(!InitializeSymbolList()) return;
      return;
   }

   for(int s = 0; s < total_symbols; s++)
   {
      string sym = symbol_list[s].symbol;
      
      // Garante que só operamos no fechamento de cada barra do operation_timeframe para este ativo específico
      datetime current_time = iTime(sym, operation_timeframe, 0);
      if(current_time == 0) continue; // Dados ainda não disponíveis/sincronizados
      if(current_time == symbol_list[s].last_time) continue;

      //--- Buffers para leitura de dados dos indicadores
      double ema5[], ema10[], ema21[], ema20[], atr[], adx[], rsi[], stoch_k[];
      long volume[];
      
      // Define arrays como séries temporais
      ArraySetAsSeries(ema5, true);
      ArraySetAsSeries(ema10, true);
      ArraySetAsSeries(ema21, true);
      ArraySetAsSeries(ema20, true);
      ArraySetAsSeries(atr, true);
      ArraySetAsSeries(adx, true);
      ArraySetAsSeries(rsi, true);
      ArraySetAsSeries(stoch_k, true);
      ArraySetAsSeries(volume, true);
      
      // Copia dados dos buffers de indicadores baseados no operation_timeframe
      if(CopyBuffer(symbol_list[s].handle_ema5, 0, 0, 10, ema5) < 0) continue;
      if(CopyBuffer(symbol_list[s].handle_ema10, 0, 0, 10, ema10) < 0) continue;
      if(CopyBuffer(symbol_list[s].handle_ema21, 0, 0, 10, ema21) < 0) continue;
      if(CopyBuffer(symbol_list[s].handle_ema20, 0, 0, 10, ema20) < 0) continue;
      if(CopyBuffer(symbol_list[s].handle_rsi, 0, 0, 5, rsi) < 0) continue;
      if(CopyBuffer(symbol_list[s].handle_stoch, 0, 0, 5, stoch_k) < 0) continue;
      if(CopyBuffer(symbol_list[s].handle_adx, 0, 0, 5, adx) < 0) continue;
      if(CopyBuffer(symbol_list[s].handle_atr, 0, 0, 55, atr) < 0) continue;
      if(CopyTickVolume(sym, operation_timeframe, 0, volume_ma_period + 2, volume) < 0) continue;
      
      // Se chegamos aqui, os dados estão prontos! Atualiza o tempo do último candle processado
      symbol_list[s].last_time = current_time;

      // Lógica de confirmação do timeframe maior (HTF)
      bool htf_bull = true;
      bool htf_bear = true;
      
      if(use_htf_filter && symbol_list[s].handle_ema20_htf != INVALID_HANDLE)
      {
         double ema20_htf[];
         ArraySetAsSeries(ema20_htf, true);
         if(CopyBuffer(symbol_list[s].handle_ema20_htf, 0, 0, 5, ema20_htf) >= 0)
         {
            double close_htf = iClose(sym, htf_period, 1);
            htf_bull = (close_htf > ema20_htf[1]);
            htf_bear = (close_htf < ema20_htf[1]);
         }
         else
         {
            Print("[-] Erro ao ler dados do timeframe maior (HTF) para ", sym, ". Pulando filtro.");
         }
      }
      
      // Média móvel de 50 períodos do ATR para volatilidade no timeframe operacional
      double atr_sum = 0;
      for(int i=1; i<=50; i++) atr_sum += atr[i];
      double atr_base = atr_sum / 50.0;

      // Lógica de Volume Institucional (Smart Money Volume)
      double vol_sum = 0;
      for(int i=2; i<volume_ma_period+2; i++) {
         vol_sum += (double)volume[i];
      }
      double vol_avg = vol_sum / (double)volume_ma_period;
      bool volume_institucional = ((double)volume[1] >= vol_avg * volume_mult);

      // Lógica de Smart Money Concepts (SMC) - Fair Value Gap (FVG)
      bool bullish_fvg = (iLow(sym, operation_timeframe, 1) > iHigh(sym, operation_timeframe, 3));
      bool bearish_fvg = (iHigh(sym, operation_timeframe, 1) < iLow(sym, operation_timeframe, 3));

      // --- Lógica do Momentum e Filtros (Utiliza o timeframe operacional)
      double close1 = iClose(sym, operation_timeframe, 1);
      double close2 = iClose(sym, operation_timeframe, 2);
      double close6 = iClose(sym, operation_timeframe, 6);
      
      double c1 = (close1 - close2) / close2;
      double c5 = (close1 - close6) / close6;
      
      bool ema_bull = (ema5[1] > ema10[1] && ema10[1] > ema21[1]);
      bool ema_bear = (ema5[1] < ema10[1] && ema10[1] < ema21[1]);
      
      bool atr_ok = (atr[1] <= atr_base * atr_mult);
      bool adx_ok = (adx[1] > adx_thresh);
      
      // Condições de Compra (LONG)
      bool long_mom   = (c1 > c1_thresh && c5 > c5_thresh);
      bool long_ema   = (!use_ema_alignment || ema_bull);
      bool long_fomo  = (rsi[1] < rsi_max && stoch_k[1] < stoch_max);
      bool long_trend = (close1 > ema20[1] && ema20[1] > ema20[6]);
      bool smc_long_ok = (!use_fvg_filter || bullish_fvg);
      bool vol_ok = (!use_volume_filter || volume_institucional);
      
      // Condições de Venda (SHORT)
      bool short_mom   = (c1 < -c1_thresh && c5 < -c5_thresh);
      bool short_ema   = (!use_ema_alignment || ema_bear);
      bool short_fomo  = (rsi[1] > rsi_min && stoch_k[1] > stoch_min);
      bool short_trend = (close1 < ema20[1] && ema20[1] < ema20[6]);
      bool smc_short_ok = (!use_fvg_filter || bearish_fvg);
      bool vol_ok_sell = (!use_volume_filter || volume_institucional);

      // DIAGNÓSTICO ATIVO NO FECHAMENTO DE CADA CANDLE DO TIMEFRAME OPERACIONAL
      if(print_diagnostics)
      {
         string tf_str = EnumToString(operation_timeframe);
         string htf_str = use_htf_filter ? StringFormat("HTF(%s)=%s", EnumToString(htf_period), (htf_bull ? "BULL" : (htf_bear ? "BEAR" : "NEUTRAL"))) : "HTF=OFF";
         
         string long_details = StringFormat("LONG filters: c1=%.4f (req: >%.4f) [%s], c5=%.4f (req: >%.4f) [%s], ema=%s, trend=%s, rsi=%.1f/stoch=%.1f [%s], adx=%.1f [%s], atr=%.4f/base=%.4f [%s], fvg=%s, vol=%d/avg=%d [%s], %s",
                                            c1, c1_thresh, (c1 > c1_thresh ? "OK" : "FAIL"),
                                            c5, c5_thresh, (c5 > c5_thresh ? "OK" : "FAIL"),
                                            (long_ema ? "OK" : "FAIL"),
                                            (long_trend ? "OK" : "FAIL"),
                                            rsi[1], stoch_k[1], (long_fomo ? "OK" : "FAIL"),
                                            adx[1], (adx_ok ? "OK" : "FAIL"),
                                            atr[1], atr_base, (atr_ok ? "OK" : "FAIL"),
                                            (smc_long_ok ? "OK" : "FAIL"),
                                            volume[1], (long)vol_avg, (vol_ok ? "OK" : "FAIL"),
                                            htf_str);
         Print("[i] DIAGNOSTICO ", sym, " ", tf_str, " - ", long_details);
      }

      //--- Execução e Ordens
      int total_positions = PositionsTotal();
      bool has_position = false;
      
      // Verifica se o robô já possui posição aberta neste ativo com o magic_id correspondente ao timeframe
      for(int i=total_positions-1; i>=0; i--)
      {
         if(PositionGetSymbol(i) == sym && PositionGetInteger(POSITION_MAGIC) == active_magic_id)
         {
            has_position = true;
            break;
         }
      }

      // Se não houver posição aberta, analisa as entradas
      if(!has_position)
      {
         double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
         double bid = SymbolInfoDouble(sym, SYMBOL_BID);
         
         // MODO DE TESTE FORÇADO: Abre compra imediatamente para validar o robô multiativos
         if(force_test_trade)
         {
            double test_lot = NormalizeVolume(sym, 0.01);
            Print("[*] MODO TESTE FORÇADO - Disparando COMPRA de teste em ", sym, " com lote ", test_lot);
            trade.Buy(test_lot, sym, ask, 0, 0, "TESTE " + EnumToString(operation_timeframe));
            continue; // Pula para o próximo ativo
         }
         
         // Gatilho de COMPRA (LONG)
         if(long_mom && long_ema && atr_ok && long_fomo && long_trend && adx_ok && smc_long_ok && vol_ok && htf_bull)
         {
            double sl_price = ask * (1.0 - stop_loss_pct);
            double tp_price = ask * (1.0 + profit_target_2);
            double base_lot = GetDynamicLotSize(sym);
            double normal_lot = NormalizeVolume(sym, base_lot);
            
            Print("[*] MT5MomEA - Gatilho Ativo (COMPRA) disparado em ", EnumToString(operation_timeframe), " de ", sym, " | Volume: ", normal_lot, " (Base: ", base_lot, ", Original: ", lot_size, ", Média Vol: ", vol_avg, ")");
            trade.Buy(normal_lot, sym, ask, sl_price, tp_price, "LONG SMC " + EnumToString(operation_timeframe));
         }
         
         // Gatilho de VENDA (SHORT)
         else if(allow_short && short_mom && short_ema && atr_ok && short_fomo && short_trend && adx_ok && smc_short_ok && vol_ok_sell && htf_bear)
         {
            double sl_price = bid * (1.0 + stop_loss_pct);
            double tp_price = bid * (1.0 - profit_target_2);
            double base_lot = GetDynamicLotSize(sym);
            double normal_lot = NormalizeVolume(sym, base_lot);
            
            Print("[*] MT5MomEA - Gatilho Ativo (VENDA) disparado em ", EnumToString(operation_timeframe), " de ", sym, " | Volume: ", normal_lot, " (Base: ", base_lot, ", Original: ", lot_size, ", Média Vol: ", vol_avg, ")");
            trade.Sell(normal_lot, sym, bid, sl_price, tp_price, "SHORT SMC " + EnumToString(operation_timeframe));
         }
      }
      else
      {
         // Gerenciador de Posição Ativa (Ajuste para Break-Even / Realização Parcial)
         for(int i=PositionsTotal()-1; i>=0; i--)
         {
            if(PositionGetSymbol(i) == sym && PositionGetInteger(POSITION_MAGIC) == active_magic_id)
            {
               ulong ticket = PositionGetInteger(POSITION_TICKET);
               double entry_price = PositionGetDouble(POSITION_PRICE_OPEN);
               double current_price = PositionGetDouble(POSITION_PRICE_CURRENT);
               double current_sl = PositionGetDouble(POSITION_SL);
               
               if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
               {
                  // Compra: Se bater o Alvo 1, arrasta o Stop Loss para o Preço de Entrada (Break-Even)
                  if(current_price >= entry_price * (1.0 + profit_target_1))
                  {
                     if(current_sl < entry_price)
                     {
                        Print("[*] MT5MomEA - Alvo 1 alcançado! Ajustando SL para o Break-Even em ", sym, "...");
                        trade.PositionModify(ticket, entry_price, PositionGetDouble(POSITION_TP));
                     }
                  }
               }
               else if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL)
               {
                  // Venda: Se bater o Alvo 1, arrasta o Stop Loss para o Preço de Entrada (Break-Even)
                  if(current_price <= entry_price * (1.0 - profit_target_1))
                  {
                     if(current_sl > entry_price || current_sl == 0)
                     {
                        Print("[*] MT5MomEA - Alvo 1 alcançado! Ajustando SL para o Break-Even em ", sym, "...");
                        trade.PositionModify(ticket, entry_price, PositionGetDouble(POSITION_TP));
                     }
                  }
               }
            }
         }
      }
   }
}
//+------------------------------------------------------------------+
