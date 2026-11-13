#!/usr/bin/env bash
# ============================================================================
# AE4 - TIFAS FASE 2: CONMUTACIÓN PLANIFICADA (SWITCHOVER) SIN PÉRDIDA DE DATOS
# ----------------------------------------------------------------------------
# Para mantenimiento programado (actualizar MySQL, cambiar hardware, etc.) no se
# "tira" el nodo: se lo saca de servicio de forma ordenada y verificada.
#
#   bash pruebas_fase2/switchover.sh salir nodo1   -> el Salón pasa al Nodo 2
#   bash pruebas_fase2/switchover.sh volver nodo1  -> el Salón regresa al Nodo 1
#   bash pruebas_fase2/switchover.sh prueba        -> ciclo completo de demostración
#                                                     (salir + reinicio + volver)
#
# Procedimiento de salida (nodo X sale, nodo Y toma su área):
#   1. super_read_only = ON en X: congela las escrituras (la replicación entrante
#      sigue funcionando, porque el hilo de réplica no está sujeto a read_only).
#   2. Espera a que Y aplique TODAS las transacciones de X (WAIT_FOR_EXECUTED_GTID_SET).
#      Recién entonces es seguro mover el tráfico: RPO = 0 garantizado.
#   3. HAProxy (API de administración): X pasa a MAINT en las dos áreas y se
#      cortan sus sesiones: los clientes reconectan y llegan a Y.
#   4. X queda libre para mantenimiento.
# La vuelta hace lo inverso y espera a que X se ponga al día antes de recibir tráfico.
# ============================================================================
source "$(dirname "$0")/comun.sh"

contenedor() { [[ "$1" == "nodo1" ]] && echo "$N1" || echo "$N2"; }
otro()       { [[ "$1" == "nodo1" ]] && echo "nodo2" || echo "nodo1"; }

# area_principal nodoX -> el área (listen de HAProxy) de la que es principal
area_principal() { [[ "$1" == "nodo1" ]] && echo "salon" || echo "cocina"; }

esperar_ruteo() {   # esperar_ruteo <area> <hostname_esperado>
    local i
    for ((i = 0; i < 40; i++)); do
        [[ "$(sql_app "$1" "SELECT @@hostname" || true)" == "$2" ]] && return 0
        sleep 0.5
    done
    return 1
}

hostname_de() { [[ "$1" == "nodo1" ]] && echo "nodo1-salon" || echo "nodo2-cocina"; }

salir() {
    local X="$1" Y CX CY G T0
    Y="$(otro "$X")"; CX="$(contenedor "$X")"; CY="$(contenedor "$Y")"
    titulo "SWITCHOVER: $X SALE DE SERVICIO, $Y TOMA SU ÁREA"
    precondiciones

    paso "1. Congelar escrituras en $X (super_read_only = ON)"
    sql_nodo "$CX" "SET GLOBAL super_read_only = ON"
    ok "$X en solo lectura: read_only=$(sql_nodo "$CX" "SELECT @@read_only"), super_read_only=$(sql_nodo "$CX" "SELECT @@super_read_only")"
    T0="$(ahora_ms)"

    paso "2. Esperar a que $Y tenga TODAS las transacciones de $X"
    G="$(sql_nodo "$CX" "SELECT REPLACE(@@GLOBAL.gtid_executed, '\n', '')")"
    [[ "$(sql_nodo "$CY" "SELECT WAIT_FOR_EXECUTED_GTID_SET('$G', 30)")" == "0" ]] \
        || { sql_nodo "$CX" "SET GLOBAL super_read_only = OFF; SET GLOBAL read_only = OFF"; falla "$Y no se puso al día: se cancela el switchover"; }
    ok "$Y aplicó todo lo de $X (GTID $G)"

    paso "3. Sacar $X de HAProxy (estado MAINT) y cortar sus sesiones"
    for area in salon cocina; do
        haproxy_cmd "set server $area/$X state maint" > /dev/null
        haproxy_cmd "shutdown sessions server $area/$X" > /dev/null
    done
    esperar_ruteo "$(area_principal "$X")" "$(hostname_de "$Y")" || falla "HAProxy no redirigió el área"
    ok "área $(area_principal "$X") -> $(sql_app "$(area_principal "$X")" "SELECT @@hostname") (corte de escrituras: $(segundos_desde "$T0") s)"
    info "HAProxy $(area_principal "$X")/$X: $(estado_haproxy "$(area_principal "$X")" "$X")"
    ok "$X fuera de servicio, listo para mantenimiento"
}

volver() {
    local X="$1" Y CX CY G
    Y="$(otro "$X")"; CX="$(contenedor "$X")"; CY="$(contenedor "$Y")"
    titulo "SWITCHOVER DE REGRESO: $X VUELVE A SU ÁREA"

    paso "1. Verificar que $X esté sano y replicando"
    esperar_healthy "$CX" 180 || falla "$X no está healthy"
    for _ in $(seq 1 30); do replicacion_ok "$CX" && break; sleep 1; done
    replicacion_ok "$CX" || falla "la replicación de $X no está corriendo"
    ok "$X healthy y replicando"

    paso "2. Esperar a que $X tenga todo lo que $Y escribió mientras no estaba"
    G="$(sql_nodo "$CY" "SELECT REPLACE(@@GLOBAL.gtid_executed, '\n', '')")"
    [[ "$(sql_nodo "$CX" "SELECT WAIT_FOR_EXECUTED_GTID_SET('$G', 60)")" == "0" ]] || falla "$X no se puso al día"
    ok "$X al día (GTID $G)"

    paso "3. Habilitar escrituras en $X y devolverlo a HAProxy"
    sql_nodo "$CX" "SET GLOBAL super_read_only = OFF; SET GLOBAL read_only = OFF"
    for area in salon cocina; do haproxy_cmd "set server $area/$X state ready" > /dev/null; done
    # Cortar las sesiones que el área tenía en el respaldo para que reconecten al principal.
    haproxy_cmd "shutdown sessions server $(area_principal "$X")/$Y" > /dev/null
    esperar_ruteo "$(area_principal "$X")" "$(hostname_de "$X")" || falla "HAProxy no devolvió el área a $X"
    ok "área $(area_principal "$X") -> $(sql_app "$(area_principal "$X")" "SELECT @@hostname")"
}

case "${1:-}" in
    salir)  salir "${2:?indicar nodo1 o nodo2}" ;;
    volver) volver "${2:?indicar nodo1 o nodo2}" ;;
    prueba)
        registrar "prueba_switchover"
        salir nodo1

        paso "Durante el mantenimiento: el Salón sigue operando (contra el Nodo 2)"
        ID="$(sql_app salon "INSERT INTO comandas (id_mesa, mozo, estado) VALUES (8, 'Switchover - durante mantenimiento', 'ABIERTA'); SELECT LAST_INSERT_ID();")"
        ok "comanda #$ID creada vía HAProxy en $(sql_app salon "SELECT @@hostname")"
        info "Escritura directa al Nodo 1 congelado (debe fallar):"
        docker exec "$N1" mysql -uapp_salon -psalon_password_ae4 -D "$DB" \
            -e "INSERT INTO comandas (id_mesa, mozo) VALUES (8, 'no debe entrar')" 2>&1 | grep -v Warning | sed 's/^/      /' || true

        paso "Mantenimiento simulado: reinicio ordenado del Nodo 1 (docker restart)"
        docker restart "$N1" > /dev/null
        ok "Nodo 1 reiniciado"

        volver nodo1
        paso "Consistencia final"
        bash pruebas_fase2/verificar_consistencia.sh | sed -n '/Huella digital/,$p'
        echo
        echo "Resultado guardado en: $ARCHIVO_RESULTADO"
        ;;
    *)
        echo "Uso: bash pruebas_fase2/switchover.sh salir|volver nodo1|nodo2"
        echo "     bash pruebas_fase2/switchover.sh prueba"
        exit 1 ;;
esac
