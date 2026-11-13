#!/usr/bin/env bash
# ============================================================================
# AE4 - TIFAS FASE 2: REINICIO REPRODUCIBLE DEL ENTORNO DE PRUEBA
# ----------------------------------------------------------------------------
# Deja el clúster en un estado inicial conocido, idéntico en cualquier máquina:
#   1. Baja todos los contenedores.
#   2. BORRA los datos de ambos nodos (nodo1/data, nodo2/data) y los respaldos (backups/).
#   3. Levanta todo de nuevo (se ejecutan los scripts de init/ desde cero).
#   4. Carga los datos de demostración con los scripts de ABM de la Fase 1.
#   5. Verifica que ambos nodos queden consistentes.
#
# Uso: bash pruebas_fase2/reiniciar_entorno.sh [--si]   (--si: no pide confirmación)
# ============================================================================
source "$(dirname "$0")/comun.sh"

if [[ "${1:-}" != "--si" ]]; then
    echo "ATENCIÓN: se borrarán TODOS los datos de los nodos y TODOS los respaldos locales."
    read -r -p "¿Continuar? (s/N): " r
    [[ "$r" == "s" || "$r" == "S" ]] || { echo "Cancelado."; exit 0; }
fi

titulo "REINICIO DEL ENTORNO"

paso "1. Bajando contenedores"
docker compose down

paso "2. Borrando datos de los nodos y respaldos"
rm -rf ./nodo1/data ./nodo2/data ./backups
ok "nodo1/data, nodo2/data y backups/ eliminados"

paso "3. Levantando el clúster (Nodo 1, Nodo 2, HAProxy y backup)"
docker compose up -d --build
esperar_healthy "$N1" 180 || falla "el Nodo 1 no quedó healthy"
esperar_healthy "$N2" 180 || falla "el Nodo 2 no quedó healthy"
for _ in $(seq 1 30); do replicacion_ok "$N1" && replicacion_ok "$N2" && break; sleep 2; done
replicacion_ok "$N1" && replicacion_ok "$N2" || falla "la replicación no arrancó"
ok "nodos healthy y replicación bidireccional activa"

paso "4. Cargando datos de demostración (scripts de ABM de la Fase 1)"
M=(mysql -uroot -p"$ROOT_PW" --default-character-set=utf8mb4)
docker exec -i "$N1" "${M[@]}" < nodo1/scripts_abm/verificacion_tecnica_nodo1.sql > /dev/null 2>&1 || falla "verificacion_tecnica_nodo1.sql"
ok "verificacion_tecnica_nodo1.sql (Nodo 1)"
docker exec -i "$N1" "${M[@]}" < nodo1/scripts_abm/abm_salon.sql > /dev/null 2>&1 || falla "abm_salon.sql"
ok "abm_salon.sql (Nodo 1)"
sleep 1
docker exec -i "$N2" "${M[@]}" < nodo2/scripts_abm/abm_cocina.sql > /dev/null 2>&1 || falla "abm_cocina.sql"
ok "abm_cocina.sql (Nodo 2)"
docker exec -i "$N2" "${M[@]}" < nodo2/scripts_abm/verificacion_tecnica_nodo2.sql > /dev/null 2>&1 || falla "verificacion_tecnica_nodo2.sql"
ok "verificacion_tecnica_nodo2.sql (Nodo 2)"

paso "5. Esperando que HAProxy detecte ambos nodos"
for _ in $(seq 1 30); do
    [[ "$(sql_app salon "SELECT @@hostname" || true)" == "nodo1-salon" && "$(sql_app cocina "SELECT @@hostname" || true)" == "nodo2-cocina" ]] && break
    sleep 1
done
ok "Salón (3310) -> $(sql_app salon "SELECT @@hostname") | Cocina (3311) -> $(sql_app cocina "SELECT @@hostname")"

bash pruebas_fase2/verificar_consistencia.sh
