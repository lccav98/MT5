#!/bin/bash
# prevent_sleep.sh - Impede o macOS de hibernar enquanto o MetaTrader 5 estiver aberto.

echo "[+] Monitor de hibernação iniciado..."

while true; do
    # Procura o PID do MetaTrader 5 (terminal64.exe)
    PID=$(pgrep -f "terminal64.exe" | head -n 1)
    
    if [ ! -z "$PID" ]; then
        echo "[+] MetaTrader 5 detectado (PID: $PID). Ativando prevenção de hibernação..."
        # Executa o caffeinate atrelado ao PID do MetaTrader 5.
        # O caffeinate manterá o Mac acordado e terminará automaticamente quando o PID deixar de existir.
        caffeinate -s -i -w $PID
        echo "[-] MetaTrader 5 foi fechado. Monitor voltando a aguardar..."
    fi
    
    # Aguarda 15 segundos antes de verificar novamente se o MT5 foi aberto
    sleep 15
done
