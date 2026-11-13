#!/usr/bin/env bash
# ============================================================================
# AE4 - TIFAS FASE 2: RECONSTRUCCIÓN DE UN NODO TRAS LA PÉRDIDA TOTAL DE SU DISCO
# ----------------------------------------------------------------------------
# ¿Por qué no alcanza con dejar que la replicación lo vuelva a llenar?
#   En replicación circular, cada servidor DESCARTA los eventos que llevan su propio
#   server_id (replicate-same-server-id = 0), para que una transacción no gire para
#   siempre entre los nodos. El nodo reconstruido conserva su server_id, así que al
#   recibir del otro nodo las transacciones que él mismo había generado antes del
#   desastre, las ignora: quedaría con datos incompletos SIN dar error.
#   (Comprobado en este clúster: el Nodo 2 rehecho por replicación quedó con 11 de 16 comandas.)
#
# Procedimiento correcto (siembra + replicación):
#   1. Sacar el nodo de HAProxy (MAINT): no debe recibir clientes con datos parciales.
#   2. Levantar el nodo vacío (los scripts de init/ crean esquema y usuarios).
#   3. Detener su replicación, borrar la base y limpiar su historial GTID (RESET MASTER).
#   4. Sembrarlo con una copia consistente y en caliente del nodo sobreviviente
#      (mysqldump --single-transaction --set-gtid-purged=ON): los datos y el conjunto
#      exacto de GTID que esa copia contiene.
#   5. Reanudar la replicación: recibe solo lo posterior a la copia (RPO = 0).
#   6. Verificar consistencia y devolverlo a HAProxy.
#
# Uso:
#   bash pruebas_fase2/reconstruir_nodo.sh nodo2                    (el disco ya se perdió)
#   bash pruebas_fase2/reconstruir_nodo.sh nodo2 --simular-perdida  (borra el disco primero: prueba)
# ============================================================================
source "$(dirname "$0")/comun.sh"

NODO="${1:?indicar nodo1 o nodo2}"
case "$NODO" in
    nodo1) C="$N1"; SVC=mysql-nodo1; IP=172.28.0.11; SOBREV="$N2"; IP_SOBREV=172.28.0.12 ;;
    nodo2) C="$N2"; SVC=mysql-nodo2; IP=172.28.0.12; SOBREV="$N1"; IP_SOBREV=172.28.0.11 ;;
    *) falla "nodo desconocido: $NODO" ;;
esac

registrar "reconstruir_${NODO}"
titulo "RECONSTRUCCIÓN DEL $NODO DESDE EL NODO SOBREVIVIENTE"
T_TOTAL="$(ahora_ms)"

paso "1. Sacar el $NODO de HAProxy (no debe atender clientes mientras se reconstruye)"
for area in salon cocina; do
    haproxy_cmd "set server $area/$NODO state maint" > /dev/null
    haproxy_cmd "shutdown sessions server $area/$NODO" > /dev/null
done
ok "salon/$NODO: $(estado_haproxy salon "$NODO") | cocina/$NODO: $(estado_haproxy cocina "$NODO")"

if [[ "${2:-}" == "--simular-perdida" ]]; then
    paso "Simulación: se destruye el disco del $NODO"
    COMANDAS_ANTES="$(sql_nodo "$SOBREV" "SELECT COUNT(*) FROM comandas")"
    docker compose stop "$SVC" > /dev/null 2>&1
    rm -rf "./$NODO/data"
    ok "./$NODO/data eliminado (comandas en el sobreviviente: $COMANDAS_ANTES)"
fi

paso "2. Levantar el $NODO vacío (init/ crea esquema, semillas y usuarios)"
docker compose up -d "$SVC" > /dev/null 2>&1
esperar_healthy "$C" 240 || falla "el $NODO no quedó healthy"
# Ojo: el entrypoint de MySQL ejecuta init/ en un servidor TEMPORAL que ya responde al
# healthcheck. Hay que esperar al servidor definitivo: es el único que arranca la réplica.
for _ in $(seq 1 120); do replicacion_ok "$C" && break; sleep 1; done
replicacion_ok "$C" || falla "el $NODO no terminó de inicializarse (la réplica no arrancó)"
ok "$NODO healthy, init/ terminado y servidor definitivo en marcha"

paso "3. Detener su replicación, borrar la base y limpiar su historial GTID"
# Primero se pausa la lectura del sobreviviente desde este nodo: RESET MASTER borra los
# binlogs que el sobreviviente está leyendo y su hilo receptor se cortaría con error 1236.
sql_nodo "$SOBREV" "STOP REPLICA IO_THREAD"
# sql_log_bin = 0 es OBLIGATORIO: el otro nodo replica DESDE este. Si el DROP DATABASE
# se escribiera en el binlog, el sobreviviente lo recibiría y borraría su propia base.
sql_nodo "$C" "SET SESSION sql_log_bin = 0; STOP REPLICA; DROP DATABASE IF EXISTS restaurante_db; RESET MASTER;"
ok "replicación detenida, base eliminada (sin registrar en el binlog), gtid_executed vacío"
info "el sobreviviente conserva sus datos: $(sql_nodo "$SOBREV" "SELECT COUNT(*) FROM comandas") comandas"

paso "4. Siembra: copia consistente en caliente del nodo sobreviviente"
T0="$(ahora_ms)"
docker exec "$BK" bash -c "
    set -o pipefail
    mysqldump -h $IP_SOBREV -ubackup_user -pbackup_password_ae4 \
        --single-transaction --set-gtid-purged=ON --routines --triggers --events \
        --databases $DB 2>/dev/null \
    | mysql -h $IP -uroot -p'$ROOT_PW' 2>/dev/null" || falla "la siembra falló"
ok "siembra completa en $(segundos_desde "$T0") s"
info "GTID sembrados: $(sql_nodo "$C" "SELECT REPLACE(@@GLOBAL.gtid_executed, '\n', '')")"

paso "5. Reanudar la replicación (solo recibe lo posterior a la copia)"
sql_nodo "$C" "START REPLICA"
sql_nodo "$SOBREV" "START REPLICA IO_THREAD"
for _ in $(seq 1 30); do replicacion_ok "$C" && replicacion_ok "$SOBREV" && break; sleep 1; done
replicacion_ok "$C" && replicacion_ok "$SOBREV" || falla "la replicación no se restableció"
ok "replicación bidireccional activa"

paso "6. Verificar consistencia antes de devolverlo al servicio"
bash pruebas_fase2/verificar_consistencia.sh | sed -n '/Convergencia/,$p'
for area in salon cocina; do haproxy_cmd "set server $area/$NODO state ready" > /dev/null; done
sleep 2
ok "$NODO devuelto a HAProxy -> salon/$NODO: $(estado_haproxy salon "$NODO") | cocina/$NODO: $(estado_haproxy cocina "$NODO")"

titulo "RESUMEN"
printf '   %-45s %s\n' "Tiempo total de reconstrucción (RTO)" "$(segundos_desde "$T_TOTAL") s"
printf '   %-45s %s\n' "Datos perdidos (RPO)" "0 (copia en caliente del sobreviviente)"
echo
echo "Resultado guardado en: $ARCHIVO_RESULTADO"
