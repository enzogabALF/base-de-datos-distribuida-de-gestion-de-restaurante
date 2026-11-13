#!/usr/bin/env bash
# ============================================================================
# AE4 - TIFAS FASE 2: BACKUP INCREMENTAL
# ----------------------------------------------------------------------------
# Copia los binlogs generados desde el ÚLTIMO respaldo de la cadena (completo,
# diferencial o incremental). Es el respaldo más liviano y frecuente: define el
# RPO ante desastres lógicos (cada 15 min por defecto).
#
# El binlog en formato ROW registra cada cambio confirmado fila por fila, por lo
# que reaplicarlo sobre el completo reconstruye exactamente el estado posterior.
# ============================================================================
source "$(dirname "$0")/comun.sh"
tomar_candado

CADENA="$(cadena_actual)" || fallar "no hay backup completo: ejecutar primero backup_full.sh"
DIR="$CADENAS_DIR/$CADENA"
source "$DIR/full/meta.env"
source "$DIR/estado.env"

nodo_responde "$HOST" || fallar "el $NODO ($HOST), origen de la cadena $CADENA, no responde"

FECHA="$(date +%Y%m%d_%H%M%S)"
DESTINO="$DIR/incremental_$FECHA"
DESDE=$(( ULTIMO_BINLOG + 1 ))
log "iniciando backup INCREMENTAL de $NODO desde el binlog número $DESDE"

ULTIMO="$(copiar_binlogs "$HOST" "$DESDE" "$DESTINO")"
cat > "$DESTINO/meta.env" <<EOF
TIPO=INCREMENTAL
FECHA=$FECHA
DESDE=$DESDE
HASTA=$ULTIMO
EOF
echo "ULTIMO_BINLOG=$ULTIMO" > "$DIR/estado.env"
log "backup INCREMENTAL OK: binlogs $DESDE..$ULTIMO ($(du -sh "$DESTINO" | cut -f1))"
