#!/usr/bin/env bash
# ============================================================================
# AE4 - TIFAS FASE 2: BACKUP COMPLETO (FULL)
# ----------------------------------------------------------------------------
# Copia lógica consistente de restaurante_db con mysqldump. Inicia una CADENA
# nueva: los diferenciales e incrementales posteriores dependen de este completo.
#
#   --single-transaction  lee todo dentro de una única transacción REPEATABLE READ
#                         (snapshot MVCC de InnoDB): no bloquea a mozos ni cocina.
#   --source-data=2       anota (comentado) el archivo y posición del binlog del
#                         instante del snapshot: ahí arranca la recuperación.
#   --flush-logs          rota el binlog en ese instante: el siguiente archivo
#                         contiene exactamente lo ocurrido DESPUÉS del completo.
#   --set-gtid-purged=ON  guarda los GTID ya incluidos en el dump, para que al
#                         reaplicar binlogs no se dupliquen transacciones.
#
# Uso: backup_full.sh [nodo1|nodo2]   (sin argumento: el primer nodo disponible)
# ============================================================================
source "$(dirname "$0")/comun.sh"
tomar_candado

if [[ $# -ge 1 ]]; then
    NODO="$1"
    HOST="$(host_de_nodo "$NODO")" || fallar "nodo desconocido: $NODO"
    nodo_responde "$HOST" || fallar "el $NODO ($HOST) no responde"
else
    read -r NODO HOST < <(primer_nodo_disponible) || fallar "ningún nodo responde"
fi

INICIO=$(date +%s)
FECHA="$(date +%Y%m%d_%H%M%S)"
CADENA="${FECHA}_${NODO}"
DIR="$CADENAS_DIR/$CADENA"
mkdir -p "$DIR/full"
# Un completo a medio hacer no sirve para restaurar: si algo falla se borra la carpeta.
trap 'rm -rf "$DIR"; fallar "falló el comando en la línea $LINENO: $BASH_COMMAND (se descartó cadenas/$CADENA)"' ERR
log "iniciando backup COMPLETO desde $NODO ($HOST) -> cadenas/$CADENA"

mysqldump --defaults-extra-file="$CNF" -h "$HOST" \
    --single-transaction --source-data=2 --flush-logs --set-gtid-purged=ON \
    --routines --triggers --events --hex-blob \
    --databases "$BASE_DATOS" \
    | gzip -6 > "$DIR/full/dump.sql.gz"

# Archivo de binlog en el que comienza todo lo posterior al completo.
# (zcat || true): grep -m1 corta la lectura temprano y zcat recibe SIGPIPE, que no es un error.
LINEA_POS="$( (zcat "$DIR/full/dump.sql.gz" || true) | grep -m1 -E "CHANGE (REPLICATION SOURCE|MASTER) TO")"
BINLOG_INICIO="$(echo "$LINEA_POS" | sed -E "s/.*(SOURCE|MASTER)_LOG_FILE='([^']+)'.*/\2/")"
[[ "$BINLOG_INICIO" == mysql-bin.* ]] || fallar "no se pudo leer la posición del binlog del dump"
GTID_DUMP="$(sql "$HOST" "SELECT REPLACE(@@GLOBAL.gtid_executed, '\n', '')")"

(cd "$DIR/full" && sha256sum dump.sql.gz > SHA256SUMS)
cat > "$DIR/full/meta.env" <<EOF
TIPO=COMPLETO
FECHA=$FECHA
NODO=$NODO
HOST=$HOST
BINLOG_INICIO=$BINLOG_INICIO
GTID_APROXIMADO="$GTID_DUMP"
EOF
echo "ULTIMO_BINLOG=$(( $(numero_binlog "$BINLOG_INICIO") - 1 ))" > "$DIR/estado.env"
echo "$CADENA" > "$BACKUP_DIR/cadena_actual"

TAMANIO="$(du -h "$DIR/full/dump.sql.gz" | cut -f1)"
log "backup COMPLETO OK: $TAMANIO, binlog inicial $BINLOG_INICIO, $(( $(date +%s) - INICIO )) s"

# ---- Retención: borrar cadenas completas más viejas que RETENCION_DIAS ----
# Se borra la cadena entera (completo + diferenciales + incrementales) porque sus
# piezas no sirven por separado. Nunca se borra la cadena actual.
find "$CADENAS_DIR" -mindepth 1 -maxdepth 1 -type d -mtime "+$RETENCION_DIAS" \
    ! -name "$CADENA" -print | while read -r vieja; do
    rm -rf "$vieja"
    log "retención: eliminada cadena vencida $(basename "$vieja")"
done
