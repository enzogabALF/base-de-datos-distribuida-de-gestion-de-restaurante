#!/usr/bin/env bash
# ============================================================================
# AE4 - TIFAS FASE 2: FUNCIONES COMUNES DE LOS SCRIPTS DE RESPALDO
# ----------------------------------------------------------------------------
# Estructura en disco (carpeta ./backups del repositorio, montada en /backups):
#
#   /backups/
#     cadena_actual                 nombre de la cadena en uso
#     backup.log                    bitácora de todas las ejecuciones
#     cadenas/<fecha>_<nodo>/       una CADENA = 1 completo + sus binlogs
#       full/dump.sql.gz            backup completo lógico (mysqldump)
#       full/meta.env               nodo, binlog inicial, GTIDs, checksum
#       diferencial_<fecha>/        binlogs desde el completo hasta ese momento
#       incremental_<fecha>/        binlogs desde el último respaldo de la cadena
#       estado.env                  último binlog copiado (para el siguiente)
#
# Una cadena está atada al nodo que hizo el completo, porque los archivos de
# binlog (mysql-bin.000NNN) son propios de cada servidor.
# ============================================================================
set -Eeuo pipefail

BACKUP_DIR="${BACKUP_DIR:-/backups}"
BACKUP_USER="${BACKUP_USER:-backup_user}"
BACKUP_PASSWORD="${BACKUP_PASSWORD:-backup_password_ae4}"
BASE_DATOS="${BASE_DATOS:-restaurante_db}"
# Orden de preferencia de los nodos origen del respaldo: "nombre:host ..."
NODOS="${NODOS:-nodo1:172.28.0.11 nodo2:172.28.0.12}"
RETENCION_DIAS="${RETENCION_DIAS:-7}"

CADENAS_DIR="$BACKUP_DIR/cadenas"
LOG_FILE="$BACKUP_DIR/backup.log"
CNF="/tmp/backup_client.cnf"

mkdir -p "$CADENAS_DIR"

# Credenciales en un archivo de opciones (evita la contraseña en la línea de comandos).
umask 077
cat > "$CNF" <<EOF
[client]
user=$BACKUP_USER
password=$BACKUP_PASSWORD
port=3306
[mysql]
connect-timeout=3
EOF
umask 022

log() {
    local msg
    msg="$(date '+%F %T') [$(basename "${0%.sh}")] $*"
    echo "$msg" >&2
    echo "$msg" >> "$LOG_FILE"
}

fallar() {
    log "ERROR: $*"
    exit 1
}

trap 'fallar "falló el comando en la línea $LINENO: $BASH_COMMAND"' ERR

# sql <host> <consulta>  -> resultado sin encabezados, separado por tabulaciones
sql() {
    local host="$1"; shift
    mysql --defaults-extra-file="$CNF" -h "$host" -N -B -e "$*"
}

# host_de_nodo <nombre>  -> IP del nodo
host_de_nodo() {
    local par
    for par in $NODOS; do
        [[ "${par%%:*}" == "$1" ]] && { echo "${par#*:}"; return 0; }
    done
    return 1
}

nodo_responde() {
    sql "$1" "SELECT 1" >/dev/null 2>&1
}

# primer_nodo_disponible  -> "nombre host" del primer nodo que responde
primer_nodo_disponible() {
    local par
    for par in $NODOS; do
        if nodo_responde "${par#*:}"; then
            echo "${par%%:*} ${par#*:}"
            return 0
        fi
    done
    return 1
}

# tomar_candado: evita que dos respaldos (el programador y uno manual) modifiquen
# la misma cadena a la vez. mkdir es atómico: solo un proceso puede crear el directorio.
# Si el dueño del candado ya no existe (proceso muerto), el candado se libera.
CANDADO="$BACKUP_DIR/.candado"
tomar_candado() {
    local i pid_duenio
    for ((i = 0; i < 300; i++)); do
        if mkdir "$CANDADO" 2>/dev/null; then
            echo $$ > "$CANDADO/pid"
            trap 'rm -rf "$CANDADO"' EXIT
            return 0
        fi
        pid_duenio="$(cat "$CANDADO/pid" 2>/dev/null || true)"
        if [[ -n "$pid_duenio" ]] && ! kill -0 "$pid_duenio" 2>/dev/null; then
            rm -rf "$CANDADO"
            continue
        fi
        sleep 1
    done
    fallar "otro respaldo sigue en curso (candado $CANDADO)"
}

# Número de un archivo de binlog: mysql-bin.000012 -> 12
numero_binlog() {
    local n="${1##*.}"
    echo $((10#$n))
}

cadena_actual() {
    [[ -f "$BACKUP_DIR/cadena_actual" ]] || return 1
    local c
    c="$(cat "$BACKUP_DIR/cadena_actual")"
    [[ -d "$CADENAS_DIR/$c/full" ]] || return 1
    echo "$c"
}

# copiar_binlogs <host> <desde_numero> <directorio_destino>
# Rota el binlog del servidor (FLUSH BINARY LOGS) y descarga por red todos los
# binlogs CERRADOS cuyo número sea >= desde_numero. Imprime el último número copiado.
copiar_binlogs() {
    local host="$1" desde="$2" destino="$3"
    local archivos=() lista actual nombre num

    sql "$host" "FLUSH BINARY LOGS"
    lista="$(sql "$host" "SHOW BINARY LOGS" | awk '{print $1}')"
    actual="$(echo "$lista" | tail -n 1)"   # el archivo abierto no se copia

    # El primer binlog requerido debe seguir existiendo en el servidor; si fue purgado
    # la cadena quedó rota y hace falta un nuevo backup completo.
    if [[ "$(numero_binlog "$(echo "$lista" | head -n 1)")" -gt "$desde" ]]; then
        fallar "el binlog número $desde ya fue purgado en $host: cadena rota, se requiere un backup completo"
    fi

    while read -r nombre; do
        [[ -z "$nombre" || "$nombre" == "$actual" ]] && continue
        num="$(numero_binlog "$nombre")"
        [[ "$num" -ge "$desde" ]] && archivos+=("$nombre")
    done <<< "$lista"

    [[ ${#archivos[@]} -gt 0 ]] || fallar "no hay binlogs cerrados para copiar desde el número $desde"

    mkdir -p "$destino"
    # --raw: guarda los binlogs binarios tal cual (no como SQL), igual que en el servidor.
    mysqlbinlog --defaults-extra-file="$CNF" --read-from-remote-server --host="$host" \
        --raw --result-file="$destino/" "${archivos[@]}"
    (cd "$destino" && sha256sum mysql-bin.* > SHA256SUMS)

    numero_binlog "${archivos[-1]}"
}
