#!/usr/bin/env bash
# ============================================================================
# AE4 - TIFAS FASE 2: VERIFICADOR DE CONSISTENCIA ENTRE NODOS
# ----------------------------------------------------------------------------
# Comprueba que el Nodo 1 y el Nodo 2 tengan exactamente los mismos datos:
#   1. Ambos hilos de replicación corriendo en cada nodo.
#   2. Convergencia de GTID: cada nodo aplicó todas las transacciones del otro
#      (WAIT_FOR_EXECUTED_GTID_SET espera hasta 30 s a que se pongan al día).
#   3. Huella digital de cada tabla: cantidad de filas + XOR de un SHA-256 por fila,
#      calculado sobre TODAS las columnas (incluidas las marcas de tiempo).
#
# Uso: bash pruebas_fase2/verificar_consistencia.sh      (código 0 = consistente)
# ============================================================================
source "$(dirname "$0")/comun.sh"

titulo "VERIFICACIÓN DE CONSISTENCIA NODO 1 <-> NODO 2"

paso "1. Hilos de replicación"
for c in "$N1" "$N2"; do
    replicacion_ok "$c" && ok "$c: Replica_IO_Running=Yes, Replica_SQL_Running=Yes" || falla "$c: replicación detenida"
done

paso "2. Convergencia de transacciones (GTID)"
G1="$(sql_nodo "$N1" "SELECT REPLACE(@@GLOBAL.gtid_executed, '\n', '')")"
G2="$(sql_nodo "$N2" "SELECT REPLACE(@@GLOBAL.gtid_executed, '\n', '')")"
[[ "$(sql_nodo "$N2" "SELECT WAIT_FOR_EXECUTED_GTID_SET('$G1', 30)")" == "0" ]] || falla "el Nodo 2 no aplicó todas las transacciones del Nodo 1"
[[ "$(sql_nodo "$N1" "SELECT WAIT_FOR_EXECUTED_GTID_SET('$G2', 30)")" == "0" ]] || falla "el Nodo 1 no aplicó todas las transacciones del Nodo 2"
ok "ambos nodos ejecutaron el mismo conjunto de transacciones"
info "GTID Nodo 1: $(sql_nodo "$N1" "SELECT REPLACE(@@GLOBAL.gtid_executed, '\n', '')")"
info "GTID Nodo 2: $(sql_nodo "$N2" "SELECT REPLACE(@@GLOBAL.gtid_executed, '\n', '')")"

paso "3. Huella digital de cada tabla"
TABLAS="$(sql_nodo "$N1" "SELECT table_name FROM information_schema.tables WHERE table_schema='$DB' AND table_type='BASE TABLE' ORDER BY table_name")"
DIFERENCIAS=0
printf '   %-27s %-26s %-26s %s\n' "TABLA" "NODO 1 (filas:huella)" "NODO 2 (filas:huella)" "RESULTADO"
for t in $TABLAS; do
    COLS="$(sql_nodo "$N1" "SET SESSION group_concat_max_len = 65535;
        SELECT GROUP_CONCAT(CONCAT('IFNULL(\`', column_name, '\`, ''<NULL>'')') ORDER BY ordinal_position SEPARATOR ', ')
        FROM information_schema.columns
        WHERE table_schema = '$DB' AND table_name = '$t'")"
    Q="SELECT CONCAT(COUNT(*), ':', LPAD(HEX(BIT_XOR(CAST(CONV(LEFT(SHA2(CONCAT_WS('|', $COLS), 256), 16), 16, 10) AS UNSIGNED))), 16, '0')) FROM \`$t\`"
    H1="$(sql_nodo "$N1" "$Q")"
    H2="$(sql_nodo "$N2" "$Q")"
    if [[ "$H1" == "$H2" ]]; then r="IGUAL"; else r="DIFERENTE"; DIFERENCIAS=$((DIFERENCIAS + 1)); fi
    printf '   %-27s %-26s %-26s %s\n' "$t" "$H1" "$H2" "$r"
done

echo
if [[ $DIFERENCIAS -eq 0 ]]; then
    ok "CONSISTENTE: las $(wc -w <<< "$TABLAS") tablas son idénticas en ambos nodos"
else
    falla "INCONSISTENTE: $DIFERENCIAS tablas difieren entre los nodos"
fi
