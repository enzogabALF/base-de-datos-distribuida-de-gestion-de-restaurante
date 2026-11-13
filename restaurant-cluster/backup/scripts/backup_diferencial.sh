#!/usr/bin/env bash
# ============================================================================
# AE4 - TIFAS FASE 2: BACKUP DIFERENCIAL
# ----------------------------------------------------------------------------
# Copia TODOS los binlogs desde el backup completo hasta ahora. Ocupa más que un
# incremental, pero acorta la restauración: alcanza con
#     completo + último diferencial + incrementales posteriores a ese diferencial
# en lugar de completo + todos los incrementales. Así se reduce el RTO y el
# riesgo de que un incremental dañado rompa toda la cadena.
# ============================================================================
source "$(dirname "$0")/comun.sh"
tomar_candado

CADENA="$(cadena_actual)" || fallar "no hay backup completo: ejecutar primero backup_full.sh"
DIR="$CADENAS_DIR/$CADENA"
source "$DIR/full/meta.env"

nodo_responde "$HOST" || fallar "el $NODO ($HOST), origen de la cadena $CADENA, no responde"

FECHA="$(date +%Y%m%d_%H%M%S)"
DESTINO="$DIR/diferencial_$FECHA"
DESDE="$(numero_binlog "$BINLOG_INICIO")"
log "iniciando backup DIFERENCIAL de $NODO desde el binlog número $DESDE (inicio de la cadena)"

ULTIMO="$(copiar_binlogs "$HOST" "$DESDE" "$DESTINO")"
cat > "$DESTINO/meta.env" <<EOF
TIPO=DIFERENCIAL
FECHA=$FECHA
DESDE=$DESDE
HASTA=$ULTIMO
EOF
echo "ULTIMO_BINLOG=$ULTIMO" > "$DIR/estado.env"
log "backup DIFERENCIAL OK: binlogs $DESDE..$ULTIMO ($(du -sh "$DESTINO" | cut -f1))"
