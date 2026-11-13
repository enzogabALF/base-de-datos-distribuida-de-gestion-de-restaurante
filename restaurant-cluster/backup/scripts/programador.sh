#!/usr/bin/env bash
# ============================================================================
# AE4 - TIFAS FASE 2: PROGRAMADOR AUTOMÁTICO DE RESPALDOS
# ----------------------------------------------------------------------------
# Proceso principal del contenedor "backup". Cada 30 s decide qué respaldo toca
# según la política (configurable por variables de entorno en docker-compose):
#
#   COMPLETO       cada FULL_CADA_MIN         (por defecto 1440 min = 1 día)
#   DIFERENCIAL    cada DIFERENCIAL_CADA_MIN  (por defecto 360 min  = 6 h)
#   INCREMENTAL    cada INCREMENTAL_CADA_MIN  (por defecto 15 min) -> RPO lógico
#
# Tolerancia a fallas del propio respaldo: si el nodo origen de la cadena está
# caído, no se puede seguir la cadena (sus binlogs son propios de ese servidor),
# así que se inicia una cadena NUEVA con un completo desde el otro nodo, que
# tiene todos los datos gracias a la replicación completa.
# ============================================================================
source "$(dirname "$0")/comun.sh"
trap - ERR
set +e

FULL_CADA_MIN="${FULL_CADA_MIN:-1440}"
DIFERENCIAL_CADA_MIN="${DIFERENCIAL_CADA_MIN:-360}"
INCREMENTAL_CADA_MIN="${INCREMENTAL_CADA_MIN:-15}"
SCRIPTS="$(dirname "$0")"
ESTADO="$BACKUP_DIR/programador.estado"

ULT_FULL=0 ULT_DIF=0 ULT_INC=0
[[ -f "$ESTADO" ]] && source "$ESTADO"

guardar_estado() {
    printf 'ULT_FULL=%s\nULT_DIF=%s\nULT_INC=%s\n' "$ULT_FULL" "$ULT_DIF" "$ULT_INC" > "$ESTADO"
}

completo() {
    if bash "$SCRIPTS/backup_full.sh"; then
        ULT_FULL=$(date +%s); ULT_DIF=$ULT_FULL; ULT_INC=$ULT_FULL
        guardar_estado
    fi
}

log "programador iniciado: completo c/${FULL_CADA_MIN} min, diferencial c/${DIFERENCIAL_CADA_MIN} min, incremental c/${INCREMENTAL_CADA_MIN} min, retención ${RETENCION_DIAS} días"

while true; do
    AHORA=$(date +%s)

    if ! primer_nodo_disponible >/dev/null; then
        sleep 30; continue
    fi

    if ! cadena_actual >/dev/null || (( AHORA - ULT_FULL >= FULL_CADA_MIN * 60 )); then
        completo
    elif (( AHORA - ULT_DIF >= DIFERENCIAL_CADA_MIN * 60 )); then
        if bash "$SCRIPTS/backup_diferencial.sh"; then
            ULT_DIF=$AHORA; ULT_INC=$AHORA; guardar_estado
        else
            log "diferencial fallido: se inicia una cadena nueva desde un nodo disponible"
            completo
        fi
    elif (( AHORA - ULT_INC >= INCREMENTAL_CADA_MIN * 60 )); then
        if bash "$SCRIPTS/backup_incremental.sh"; then
            ULT_INC=$AHORA; guardar_estado
        else
            log "incremental fallido: se inicia una cadena nueva desde un nodo disponible"
            completo
        fi
    fi

    sleep 30
done
