#!/usr/bin/env bash
# ============================================================================
# AE4 - TIFAS FASE 2: RESTAURACIÓN AUTOMÁTICA Y VERIFICADA
# ----------------------------------------------------------------------------
# Restaura una cadena de respaldos en una instancia MySQL AISLADA (puerto 3309),
# sin tocar los nodos productivos, y verifica el resultado. Pasos:
#
#   1. Verifica los checksums SHA-256 del completo y de cada binlog.
#   2. Elige los binlogs: último diferencial + incrementales posteriores (o todos
#      los incrementales si no hay diferencial) y controla que no falte ninguno.
#   3. Crea una instancia vacía, carga el completo (mysqldump).
#   4. Reaplica los binlogs con mysqlbinlog (roll-forward), opcionalmente hasta un
#      instante (--hasta) o salteando transacciones dañinas (--excluir-gtids):
#      recuperación a un punto en el tiempo (PITR).
#   5. Compara la cantidad de filas con el nodo productivo y mide el tiempo (RTO).
#
# La instancia queda levantada para inspección:
#   host 127.0.0.1, puerto 3309, usuario root, clave root_password_ae4
#
# Uso:
#   restaurar.sh [--cadena NOMBRE] [--hasta "AAAA-MM-DD HH:MM:SS"]
#                [--excluir-gtids "uuid:n[-m]"] [--solo-completo]
#   restaurar.sh --detener        apaga la instancia de restauración
# ============================================================================
source "$(dirname "$0")/comun.sh"

RESTORE_DIR="/var/lib/mysql-restore"
DATADIR="$RESTORE_DIR/data"
SOCK="$RESTORE_DIR/mysqld.sock"
PIDFILE="$RESTORE_DIR/mysqld.pid"
PUERTO_RESTORE=3309
CLAVE_RESTORE="root_password_ae4"

CADENA="" HASTA="" EXCLUIR="" SOLO_COMPLETO=0

detener_instancia() {
    if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        local pid
        pid="$(cat "$PIDFILE")"
        kill "$pid"
        while kill -0 "$pid" 2>/dev/null; do sleep 0.5; done
        log "instancia de restauración detenida"
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cadena)         CADENA="$2"; shift 2 ;;
        --hasta)          HASTA="$2"; shift 2 ;;
        --excluir-gtids)  EXCLUIR="$2"; shift 2 ;;
        --solo-completo)  SOLO_COMPLETO=1; shift ;;
        --detener)        detener_instancia; exit 0 ;;
        *) fallar "opción desconocida: $1" ;;
    esac
done

INICIO=$(date +%s)
[[ -n "$CADENA" ]] || CADENA="$(cadena_actual)" || fallar "no hay cadenas de respaldo"
DIR="$CADENAS_DIR/$CADENA"
[[ -f "$DIR/full/meta.env" ]] || fallar "la cadena $CADENA no existe o está incompleta"
source "$DIR/full/meta.env"
log "=== RESTAURACIÓN de la cadena $CADENA (origen $NODO) ==="

# ---- 1. Integridad de los archivos ----
(cd "$DIR/full" && sha256sum --quiet -c SHA256SUMS) || fallar "checksum inválido en el backup completo"
log "checksum del completo OK"

# ---- 2. Selección de binlogs ----
BINLOGS=()
if [[ $SOLO_COMPLETO -eq 0 ]]; then
    ULT_DIF="$(find "$DIR" -mindepth 1 -maxdepth 1 -type d -name 'diferencial_*' | sort | tail -n 1)"
    PIEZAS=()
    if [[ -n "$ULT_DIF" ]]; then
        PIEZAS+=("$ULT_DIF")
        while read -r inc; do
            [[ "$(basename "$inc" | sed 's/incremental_//')" > "$(basename "$ULT_DIF" | sed 's/diferencial_//')" ]] && PIEZAS+=("$inc")
        done < <(find "$DIR" -mindepth 1 -maxdepth 1 -type d -name 'incremental_*' | sort)
    else
        while read -r inc; do PIEZAS+=("$inc"); done \
            < <(find "$DIR" -mindepth 1 -maxdepth 1 -type d -name 'incremental_*' | sort)
    fi

    for pieza in "${PIEZAS[@]}"; do
        (cd "$pieza" && sha256sum --quiet -c SHA256SUMS) || fallar "checksum inválido en $(basename "$pieza")"
        log "usando $(basename "$pieza") (checksum OK)"
        for f in "$pieza"/mysql-bin.*; do BINLOGS+=("$f"); done
    done

    # Orden por número de binlog y control de continuidad (sin huecos).
    if [[ ${#BINLOGS[@]} -gt 0 ]]; then
        mapfile -t BINLOGS < <(printf '%s\n' "${BINLOGS[@]}" | awk -F. '{print $NF"\t"$0}' | sort -n | cut -f2-)
        ESPERADO="$(numero_binlog "$BINLOG_INICIO")"
        for f in "${BINLOGS[@]}"; do
            n="$(numero_binlog "$f")"
            [[ "$n" -eq "$ESPERADO" ]] || fallar "falta el binlog número $ESPERADO (se encontró $n): cadena incompleta"
            ESPERADO=$(( n + 1 ))
        done
    fi
fi
log "binlogs a reaplicar: ${#BINLOGS[@]}"

# ---- 3. Instancia aislada vacía ----
detener_instancia
rm -rf "$RESTORE_DIR"
mkdir -p "$RESTORE_DIR"
chown mysql:mysql "$RESTORE_DIR"
mysqld --no-defaults --initialize-insecure --user=mysql --datadir="$DATADIR" >/dev/null 2>&1 \
    || fallar "no se pudo inicializar la instancia de restauración"

# nohup + disown: la instancia sigue viva después de que termina este script (queda para inspección).
nohup mysqld --no-defaults --user=mysql --datadir="$DATADIR" --socket="$SOCK" --pid-file="$PIDFILE" \
    --port=$PUERTO_RESTORE --bind-address=0.0.0.0 --mysqlx=OFF \
    --server-id=99 --gtid-mode=ON --enforce-gtid-consistency=ON --skip-log-bin \
    --character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci \
    --default-time-zone=SYSTEM --log-error="$RESTORE_DIR/error.log" > /dev/null 2>&1 &
disown

for _ in $(seq 1 60); do
    mysqladmin --socket="$SOCK" -uroot ping >/dev/null 2>&1 && break
    sleep 1
done
mysqladmin --socket="$SOCK" -uroot ping >/dev/null 2>&1 || fallar "la instancia de restauración no arrancó (ver $RESTORE_DIR/error.log)"

mysql --socket="$SOCK" -uroot -e "
    CREATE USER 'root'@'%' IDENTIFIED BY '$CLAVE_RESTORE';
    GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
    ALTER USER 'root'@'localhost' IDENTIFIED BY '$CLAVE_RESTORE';"
RCNF="$RESTORE_DIR/cliente.cnf"
printf '[client]\nuser=root\npassword=%s\nsocket=%s\n' "$CLAVE_RESTORE" "$SOCK" > "$RCNF"
chmod 600 "$RCNF"
# GTID_PURGED del dump solo se puede fijar con gtid_executed vacío.
mysql --defaults-extra-file="$RCNF" -e "RESET MASTER"

# ---- 4a. Carga del completo ----
T0=$(date +%s)
zcat "$DIR/full/dump.sql.gz" | mysql --defaults-extra-file="$RCNF"
log "completo cargado en $(( $(date +%s) - T0 )) s"

# ---- 4b. Roll-forward con los binlogs (PITR) ----
if [[ ${#BINLOGS[@]} -gt 0 ]]; then
    OPCIONES=()
    [[ -n "$HASTA" ]]   && OPCIONES+=("--stop-datetime=$HASTA")   && log "PITR: se reaplica hasta $HASTA"
    [[ -n "$EXCLUIR" ]] && OPCIONES+=("--exclude-gtids=$EXCLUIR") && log "PITR: se excluyen las transacciones $EXCLUIR"
    T0=$(date +%s)
    # Todos los binlogs en UNA sola invocación (lo recomienda el manual de MySQL).
    # Las transacciones cuyos GTID ya están en el completo se saltean solas.
    mysqlbinlog "${OPCIONES[@]}" "${BINLOGS[@]}" | mysql --defaults-extra-file="$RCNF"
    log "binlogs reaplicados en $(( $(date +%s) - T0 )) s"
fi

# ---- 5. Verificación ----
TABLAS="$(mysql --defaults-extra-file="$RCNF" -N -B -e \
    "SELECT table_name FROM information_schema.tables WHERE table_schema='$BASE_DATOS' AND table_type='BASE TABLE' ORDER BY table_name")"
[[ -n "$TABLAS" ]] || fallar "la base restaurada no tiene tablas"

PROD="$(primer_nodo_disponible | cut -d' ' -f2 || true)"
echo
printf '%-28s %12s %12s\n' "TABLA" "RESTAURADO" "PRODUCCION"
printf '%-28s %12s %12s\n' "----------------------------" "------------" "------------"
DIFERENCIAS=0
for t in $TABLAS; do
    r="$(mysql --defaults-extra-file="$RCNF" -N -B -e "SELECT COUNT(*) FROM \`$BASE_DATOS\`.\`$t\`")"
    p="-"
    [[ -n "$PROD" ]] && p="$(sql "$PROD" "SELECT COUNT(*) FROM \`$BASE_DATOS\`.\`$t\`" 2>/dev/null || echo "-")"
    marca=""
    [[ "$r" != "$p" ]] && { marca="  <- difiere"; DIFERENCIAS=$((DIFERENCIAS + 1)); }
    printf '%-28s %12s %12s%s\n' "$t" "$r" "$p" "$marca"
done
echo

TOTAL=$(( $(date +%s) - INICIO ))
GTID_REST="$(mysql --defaults-extra-file="$RCNF" -N -B -e "SELECT REPLACE(@@GLOBAL.gtid_executed, '\n', '')")"
log "GTID restaurados: $GTID_REST"
if [[ $DIFERENCIAS -gt 0 && -z "$HASTA" && -z "$EXCLUIR" && $SOLO_COMPLETO -eq 0 ]]; then
    log "AVISO: $DIFERENCIAS tablas difieren de producción (cambios posteriores al último respaldo = pérdida dentro del RPO)"
fi
log "=== RESTAURACIÓN OK en $TOTAL s (RTO medido). Instancia disponible en 127.0.0.1:$PUERTO_RESTORE (root / $CLAVE_RESTORE) ==="
