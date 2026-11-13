#!/usr/bin/env bash
# ============================================================================
# AE4 - TIFAS FASE 3: GENERACIÓN DEL TABLERO DIMENSIONAL
# ----------------------------------------------------------------------------
# Ejecuta fase3/14_tablero_datos.sql (un documento JSON con los indicadores),
# lo inserta en fase3/tablero/plantilla.html y escribe fase3/tablero/tablero.html.
# El resultado es un archivo HTML autocontenido que se abre con doble clic.
#
# Uso (desde restaurant-cluster/):
#     bash pruebas_fase3/generar_tablero.sh [nodo1|nodo2]
# Con "nodo2" el tablero se arma desde la réplica del data warehouse en el
# Nodo 2 (por ejemplo, con el Nodo 1 caído).
# ============================================================================
source "$(dirname "$0")/../pruebas_fase2/comun.sh"

NODO="$N1"
[[ "${1:-}" == "nodo2" ]] && NODO="$N2"

PLANTILLA=fase3/tablero/plantilla.html
SALIDA=fase3/tablero/tablero.html

JSON="$(docker exec -i "$NODO" mysql -uroot -p"$ROOT_PW" --default-character-set=utf8mb4 -N -B -r \
        < fase3/14_tablero_datos.sql 2>/dev/null)"
[[ "$JSON" == \{* ]] || falla "la consulta del tablero no devolvió un JSON (¿se ejecutó la Fase 3?)"

# La plantilla tiene la línea "// DATOS" seguida de "null": se reemplaza ese null por el JSON
{
    sed -n '1,/^\/\/ DATOS$/p' "$PLANTILLA"
    printf '%s\n' "$JSON"
    sed -n '/^\/\/ DATOS$/,$p' "$PLANTILLA" | tail -n +3
} > "$SALIDA"

ok "tablero generado desde $NODO: $SALIDA ($(wc -c < "$SALIDA") bytes)"
