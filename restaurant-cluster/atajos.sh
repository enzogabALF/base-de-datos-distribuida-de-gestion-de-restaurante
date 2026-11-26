#!/usr/bin/env bash
# ============================================================================
# AE4 - TIFAS: ATAJOS PARA CONSULTAR LOS NODOS EN VIVO
# ----------------------------------------------------------------------------
# Uso (Git Bash, desde restaurant-cluster/):
#     source atajos.sh
#     n1 "SELECT * FROM mesas"          -> consulta en el Nodo 1 (Salón)
#     n2 "SELECT * FROM mesas"          -> consulta en el Nodo 2 (Cocina)
#
# Ejecutan cualquier sentencia SQL (SELECT, INSERT, UPDATE, DELETE, SHOW...)
# sobre restaurante_db, como root, y muestran el resultado en forma de tabla.
# Para el data warehouse, anteponer el esquema: restaurante_dw.hechos_ventas
# ============================================================================
export MSYS_NO_PATHCONV=1

_sql() {
    local c="$1"; shift
    docker exec "$c" mysql -uroot -proot_password_ae4 --default-character-set=utf8mb4 -t -D restaurante_db -e "$*" 2>&1 \
        | { grep -v '\[Warning\]' || true; }
}
n1() { _sql restaurante_nodo1_salon "$@"; }
n2() { _sql restaurante_nodo2_cocina "$@"; }

echo 'Atajos cargados:  n1 "SQL"  -> Nodo 1 (Salón)   |   n2 "SQL"  -> Nodo 2 (Cocina)'
