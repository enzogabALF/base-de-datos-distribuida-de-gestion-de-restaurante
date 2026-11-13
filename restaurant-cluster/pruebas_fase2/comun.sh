#!/usr/bin/env bash
# ============================================================================
# AE4 - TIFAS FASE 2: FUNCIONES COMUNES DE LAS PRUEBAS DE RESILIENCIA
# ----------------------------------------------------------------------------
# Las pruebas se ejecutan desde la PC anfitriona (Git Bash en Windows, o bash en
# Linux/macOS) con Docker Desktop abierto y el clúster levantado:
#     cd restaurant-cluster
#     bash pruebas_fase2/<prueba>.sh
# No hace falta un cliente MySQL instalado: todo se ejecuta con "docker exec".
# Cada prueba guarda su salida completa en pruebas_fase2/resultados/.
# ============================================================================
set -Eeuo pipefail
export MSYS_NO_PATHCONV=1   # Git Bash: no convertir rutas del contenedor (/backups) a rutas de Windows

cd "$(dirname "${BASH_SOURCE[0]}")/.."   # carpeta restaurant-cluster

N1=restaurante_nodo1_salon
N2=restaurante_nodo2_cocina
HA=restaurante_haproxy
BK=restaurante_backup
HA_IP=172.28.0.20
ROOT_PW=root_password_ae4
DB=restaurante_db
RESULTADOS=pruebas_fase2/resultados

# sql_nodo <contenedor> <consulta>   (como root, directo al nodo)
sql_nodo() {
    local c="$1"; shift
    docker exec "$c" mysql -uroot -p"$ROOT_PW" --default-character-set=utf8mb4 -N -B -D "$DB" -e "$*" 2>/dev/null
}

# sql_app <salon|cocina> <consulta>
# Simula la aplicación del área: entra por HAProxy, no sabe a qué nodo llega.
# El cliente corre dentro del contenedor de backup porque está en la misma red.
sql_app() {
    local area="$1"; shift
    local puerto=3310 usuario=app_salon clave=salon_password_ae4
    if [[ "$area" == "cocina" ]]; then puerto=3311 usuario=app_cocina clave=cocina_password_ae4; fi
    docker exec "$BK" mysql -h"$HA_IP" -P"$puerto" -u"$usuario" -p"$clave" --connect-timeout=2 \
        --default-character-set=utf8mb4 -N -B -D "$DB" -e "$*" 2>/dev/null
}

# haproxy_cmd <comando>   API de administración de HAProxy (runtime API)
haproxy_cmd() {
    docker exec "$BK" bash -c "exec 3<>/dev/tcp/$HA_IP/9999; echo '$*' >&3; cat <&3"
}

ahora_ms() { date +%s%3N; }
segundos_desde() { awk -v a="$1" -v b="$(ahora_ms)" 'BEGIN { printf "%.1f", (b - a) / 1000 }'; }

titulo() { printf '\n%s\n %s\n%s\n' "==================================================================" "$*" "=================================================================="; }
paso()   { printf '\n>> %s\n' "$*"; }
ok()     { printf '   [OK] %s\n' "$*"; }
info()   { printf '   %s\n' "$*"; }
falla()  { printf '   [ERROR] %s\n' "$*"; exit 1; }

# registrar <nombre>: duplica toda la salida en pruebas_fase2/resultados/<nombre>_<fecha>.txt
registrar() {
    mkdir -p "$RESULTADOS"
    ARCHIVO_RESULTADO="$RESULTADOS/$1_$(date +%Y%m%d_%H%M%S).txt"
    exec > >(tee "$ARCHIVO_RESULTADO") 2>&1
    echo "Prueba: $1 | Fecha: $(date '+%F %T') | Equipo: $(uname -s)"
}

estado_salud() { docker inspect -f '{{.State.Health.Status}}' "$1" 2>/dev/null || echo "inexistente"; }

esperar_healthy() {
    local c="$1" max="${2:-120}" i
    for ((i = 0; i < max; i++)); do
        [[ "$(estado_salud "$c")" == "healthy" ]] && return 0
        sleep 1
    done
    return 1
}

# replicacion_ok <contenedor>: hilos de replicación IO y SQL en "Yes"
replicacion_ok() {
    local s
    s="$(docker exec "$1" mysql -uroot -p"$ROOT_PW" -e "SHOW REPLICA STATUS\G" 2>/dev/null)"
    grep -q "Replica_IO_Running: Yes" <<< "$s" && grep -q "Replica_SQL_Running: Yes" <<< "$s"
}

semisync() { sql_nodo "$1" "SHOW STATUS LIKE 'Rpl_semi_sync_master_status'" | cut -f2; }

# Estado de un servidor en HAProxy: UP / DOWN / MAINT
estado_haproxy() {
    haproxy_cmd "show servers state $1" | awk -v s="$2" '$4 == s { print ($6 == 2 ? "UP" : ($6 == 0 ? "DOWN" : "TRANSICION")) (($7 % 2 == 1) ? "+MAINT" : "") }'
}

precondiciones() {
    paso "Precondiciones: contenedores sanos y replicación activa en ambos sentidos"
    for c in "$N1" "$N2"; do
        [[ "$(estado_salud "$c")" == "healthy" ]] || falla "$c no está healthy (levantar con: docker compose up -d)"
        replicacion_ok "$c" || falla "la replicación de $c no está corriendo"
    done
    docker ps --format '{{.Names}}' | grep -q "^$HA$" || falla "HAProxy no está corriendo"
    docker ps --format '{{.Names}}' | grep -q "^$BK$" || falla "el contenedor de backup no está corriendo"
    ok "nodos healthy, replicación IO/SQL corriendo, HAProxy y backup activos"
}
