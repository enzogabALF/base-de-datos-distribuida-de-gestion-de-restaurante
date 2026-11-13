#!/usr/bin/env bash
# ============================================================================
# AE4 - TIFAS FASE 2: PRUEBA DE CAÍDA ABRUPTA Y CONMUTACIÓN AUTOMÁTICA (FAILOVER)
# ----------------------------------------------------------------------------
# Escenario: se corta la energía del servidor del Salón (Nodo 1) en plena
# operación. Se simula con "docker kill" (SIGKILL): MySQL muere sin cerrar
# archivos ni hacer checkpoint, igual que en un corte de luz.
#
# Se comprueba y se mide:
#   1. RPO = 0: lo confirmado en el Nodo 1 antes de la caída existe en el Nodo 2
#      (replicación semisincrónica AFTER_SYNC).
#   2. Failover automático: HAProxy redirige el Salón al Nodo 2 (tiempo medido).
#   3. Disponibilidad (CAP): el Salón sigue escribiendo en el Nodo 2; la primera
#      escritura espera el timeout semisincrónico (3 s) y luego degrada a asíncrona.
#   4. Recuperación ante caída (crash recovery): al volver, InnoDB rehace (redo)
#      y deshace (undo) según el WAL; se muestra el registro del motor.
#   5. Resincronización por GTID: el Nodo 1 recibe lo que se escribió mientras
#      estaba caído, y el Salón vuelve a él (failback).
#   6. Consistencia final idéntica en ambos nodos.
#
# Uso: bash pruebas_fase2/prueba_failover.sh
# ============================================================================
source "$(dirname "$0")/comun.sh"
registrar "prueba_failover"
titulo "PRUEBA 1: CAÍDA ABRUPTA DEL NODO 1 Y FAILOVER AUTOMÁTICO"

precondiciones

paso "1. Ruteo inicial de HAProxy"
R="$(sql_app salon "SELECT @@hostname")"
[[ "$R" == "nodo1-salon" ]] || falla "el Salón debería entrar por el Nodo 1 y entra por: $R"
ok "Salón (puerto 3310) -> $R"
ok "Cocina (puerto 3311) -> $(sql_app cocina "SELECT @@hostname")"

paso "2. El Salón abre una comanda justo antes de la caída"
ANTES="$(sql_app salon "INSERT INTO comandas (id_mesa, mozo, estado) VALUES (6, 'Failover - antes de la caída', 'ABIERTA'); SELECT LAST_INSERT_ID();")"
ok "comanda #$ANTES confirmada (COMMIT) en el Nodo 1 (ID impar)"

paso "3. CORTE DE ENERGÍA del Nodo 1 (docker kill = SIGKILL, sin apagado ordenado)"
docker kill "$N1" > /dev/null
T_CAIDA="$(ahora_ms)"
ok "Nodo 1 detenido abruptamente a las $(date '+%T')"

paso "4. Esperando la conmutación automática de HAProxy"
NUEVO=""
for _ in $(seq 1 60); do
    NUEVO="$(sql_app salon "SELECT @@hostname" || true)"
    [[ "$NUEVO" == "nodo2-cocina" ]] && break
    sleep 0.5
done
[[ "$NUEVO" == "nodo2-cocina" ]] || falla "HAProxy no conmutó al Nodo 2"
T_FAILOVER="$(segundos_desde "$T_CAIDA")"
ok "FAILOVER AUTOMÁTICO: el Salón ahora entra por $NUEVO, $T_FAILOVER s después de la caída"
info "HAProxy salon/nodo1: $(estado_haproxy salon nodo1) | salon/nodo2 (backup): $(estado_haproxy salon nodo2)"

paso "5. RPO: ¿la comanda confirmada antes de la caída sobrevivió?"
EXISTE="$(sql_nodo "$N2" "SELECT COUNT(*) FROM comandas WHERE id_comanda = $ANTES")"
[[ "$EXISTE" == "1" ]] || falla "la comanda #$ANTES se perdió"
ok "la comanda #$ANTES está en el Nodo 2: RPO = 0 (ninguna transacción confirmada se perdió)"

paso "6. Disponibilidad: el Salón sigue operando contra el Nodo 2"
T0="$(ahora_ms)"
DURANTE="$(sql_app salon "INSERT INTO comandas (id_mesa, mozo, estado) VALUES (7, 'Failover - durante la caída', 'ABIERTA'); SELECT LAST_INSERT_ID();")"
T_ESCRITURA1="$(segundos_desde "$T0")"
T0="$(ahora_ms)"
sql_app salon "INSERT INTO historial_estados_comanda (id_comanda, estado_anterior, estado_nuevo, operador, nodo_emisor, observacion) VALUES ($DURANTE, NULL, 'ABIERTA', 'Mozo de turno', 'NODO_2_COCINA', 'Abierta durante la caída del Nodo 1')" > /dev/null
T_ESCRITURA2="$(segundos_desde "$T0")"
ok "comanda #$DURANTE creada en el Nodo 2 (ID par) mientras el Nodo 1 está caído"
info "1.ª escritura: $T_ESCRITURA1 s (espera el ACK del Nodo 1 hasta el timeout de 3 s)"
info "2.ª escritura: $T_ESCRITURA2 s (replicación ya degradada a asíncrona)"
info "Rpl_semi_sync_master_status en Nodo 2: $(semisync "$N2")  <- OFF = se priorizó disponibilidad (CAP: AP)"

paso "7. Se restablece la energía del Nodo 1"
INICIO_ARRANQUE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
docker start "$N1" > /dev/null
T0="$(ahora_ms)"
esperar_healthy "$N1" 180 || falla "el Nodo 1 no volvió a estar healthy"
ok "Nodo 1 healthy en $(segundos_desde "$T0") s"
info "Registro del motor durante ESTE arranque (recuperación ante caída, WAL redo/undo):"
docker logs --since "$INICIO_ARRANQUE" "$N1" 2>&1 \
    | grep -iE "checkpoint|not match|crash recovery|redo log records|rollback|rolled back|XA|ready for connections" \
    | grep -v -iE "warning|mysqlx|X Plugin|temporary tablespace" | sed 's/^/      /'

paso "8. Resincronización por GTID (el Nodo 1 recibe lo escrito durante su caída)"
T0="$(ahora_ms)"
G2="$(sql_nodo "$N2" "SELECT REPLACE(@@GLOBAL.gtid_executed, '\n', '')")"
[[ "$(sql_nodo "$N1" "SELECT WAIT_FOR_EXECUTED_GTID_SET('$G2', 60)")" == "0" ]] || falla "el Nodo 1 no se puso al día"
ok "Nodo 1 al día en $(segundos_desde "$T0") s: la comanda #$DURANTE ya está en el Nodo 1 ($(sql_nodo "$N1" "SELECT COUNT(*) FROM comandas WHERE id_comanda = $DURANTE") fila)"
for _ in $(seq 1 20); do [[ "$(semisync "$N2")" == "ON" ]] && break; sleep 1; done
info "Rpl_semi_sync_master_status en Nodo 2: $(semisync "$N2")  <- vuelve a ON cuando el Nodo 1 confirma"

paso "9. Failback: el Salón vuelve a su nodo principal"
T0="$(ahora_ms)"
for _ in $(seq 1 60); do
    [[ "$(sql_app salon "SELECT @@hostname" || true)" == "nodo1-salon" ]] && break
    sleep 0.5
done
[[ "$(sql_app salon "SELECT @@hostname")" == "nodo1-salon" ]] || falla "HAProxy no volvió al Nodo 1"
ok "Salón -> nodo1-salon otra vez ($(segundos_desde "$T0") s desde que el Nodo 1 quedó al día)"

paso "10. Consistencia final"
bash pruebas_fase2/verificar_consistencia.sh | sed -n '/Huella digital/,$p'

titulo "RESUMEN"
printf '   %-52s %s\n' "Tiempo de conmutación automática (failover)" "$T_FAILOVER s"
printf '   %-52s %s\n' "Transacciones confirmadas perdidas (RPO)" "0"
printf '   %-52s %s\n' "1.ª escritura con el otro nodo caído" "$T_ESCRITURA1 s"
printf '   %-52s %s\n' "Escrituras siguientes (modo asíncrono)" "$T_ESCRITURA2 s"
echo
echo "Resultado guardado en: $ARCHIVO_RESULTADO"
