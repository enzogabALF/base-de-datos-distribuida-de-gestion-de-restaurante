#!/usr/bin/env bash
# ============================================================================
# AE4 - TIFAS FASE 2: INVENTARIO DE RESPALDOS
# Muestra cada cadena con su completo, diferenciales e incrementales.
# ============================================================================
source "$(dirname "$0")/comun.sh"

ACTUAL="$(cadena_actual 2>/dev/null || echo "-")"
echo "Cadena actual: $ACTUAL"
echo
for cadena in $(find "$CADENAS_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort); do
    echo "== $cadena  ($(du -sh "$CADENAS_DIR/$cadena" | cut -f1))"
    # Orden cronológico: primero el completo y después las piezas por su fecha.
    for pieza in full $(find "$CADENAS_DIR/$cadena" -mindepth 1 -maxdepth 1 -type d \
            \( -name 'diferencial_*' -o -name 'incremental_*' \) -printf '%f\n' \
            | awk -F_ '{print $2"_"$3"\t"$0}' | sort | cut -f2); do
        meta="$CADENAS_DIR/$cadena/$pieza/meta.env"
        [[ -f "$meta" ]] || continue
        (
            source "$meta"
            if [[ "$TIPO" == "COMPLETO" ]]; then
                printf '   %-12s %-16s binlog inicial %s\n' "$TIPO" "$FECHA" "$BINLOG_INICIO"
            else
                printf '   %-12s %-16s binlogs %s..%s\n' "$TIPO" "$FECHA" "$DESDE" "$HASTA"
            fi
        )
    done
done
echo
echo "Últimas líneas de la bitácora:"
tail -n 8 "$LOG_FILE" 2>/dev/null || true
