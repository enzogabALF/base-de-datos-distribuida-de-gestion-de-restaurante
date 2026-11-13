#!/usr/bin/env bash
# ============================================================================
# AE4 - TIFAS FASE 2: PARTICIÓN DE RED ENTRE NODOS (TEOREMA CAP)
# ----------------------------------------------------------------------------
# Escenario: se corta el enlace entre el Salón y la Cocina, pero cada área sigue
# conectada a su propio servidor. Se simula deteniendo el hilo receptor de la
# replicación en ambos nodos (STOP REPLICA IO_THREAD): ningún nodo recibe los
# cambios del otro, igual que si se cortara el cable entre ellos.
#
# Parte A - Disponibilidad (A de CAP): ambos nodos siguen aceptando escrituras.
#   No hay colisión de claves gracias a la fragmentación de IDs (impares/pares),
#   y al reconectarse la replicación GTID reconcilia todo sin intervención.
#
# Parte B - Límite del diseño: si las DOS áreas modifican la MISMA fila durante la
#   partición, cada nodo aplica la versión del otro al reconectarse y quedan
#   CRUZADOS (divergencia silenciosa: MySQL no detecta el conflicto). Por eso
#   el diseño asigna cada tabla a un único nodo dueño de sus escrituras
#   (fragmentación funcional) y por eso existe verificar_consistencia.sh, que
#   detecta la divergencia para repararla.
#
# Uso: bash pruebas_fase2/prueba_particion.sh
# ============================================================================
source "$(dirname "$0")/comun.sh"
registrar "prueba_particion"
titulo "PRUEBA 3: PARTICIÓN DE RED ENTRE NODOS (TEOREMA CAP)"

precondiciones

cortar_enlace() {
    sql_nodo "$N1" "STOP REPLICA IO_THREAD"
    sql_nodo "$N2" "STOP REPLICA IO_THREAD"
}
restablecer_enlace() {
    sql_nodo "$N1" "START REPLICA IO_THREAD"
    sql_nodo "$N2" "START REPLICA IO_THREAD"
    for _ in $(seq 1 30); do replicacion_ok "$N1" && replicacion_ok "$N2" && break; sleep 1; done
    local G1 G2
    G1="$(sql_nodo "$N1" "SELECT REPLACE(@@GLOBAL.gtid_executed, '\n', '')")"
    G2="$(sql_nodo "$N2" "SELECT REPLACE(@@GLOBAL.gtid_executed, '\n', '')")"
    sql_nodo "$N2" "SELECT WAIT_FOR_EXECUTED_GTID_SET('$G1', 30)" > /dev/null
    sql_nodo "$N1" "SELECT WAIT_FOR_EXECUTED_GTID_SET('$G2', 30)" > /dev/null
}

# ---------------------------------------------------------------------------
titulo "PARTE A: CADA ÁREA SIGUE OPERANDO DURANTE LA PARTICIÓN"

paso "1. Se corta el enlace de replicación entre los nodos"
cortar_enlace
ok "Replica_IO_Running = No en ambos nodos: no se ven entre sí"

paso "2. Salón y Cocina siguen trabajando, cada uno en su nodo"
T0="$(ahora_ms)"
C_SALON="$(sql_app salon "INSERT INTO comandas (id_mesa, mozo, estado) VALUES (2, 'Partición - Salón', 'ABIERTA'); SELECT LAST_INSERT_ID();")"
T_S="$(segundos_desde "$T0")"
T0="$(ahora_ms)"
C_COCINA="$(sql_app cocina "INSERT INTO comandas (id_mesa, mozo, nodo_origen, estado) VALUES (3, 'Partición - Cocina', 'NODO_2_COCINA', 'ABIERTA'); SELECT LAST_INSERT_ID();")"
T_C="$(segundos_desde "$T0")"
ok "Salón creó la comanda #$C_SALON en el Nodo 1 ($T_S s, espera el timeout semisincrónico)"
ok "Cocina creó la comanda #$C_COCINA en el Nodo 2 ($T_C s)"
info "Semisincronía -> Nodo 1: $(semisync "$N1") | Nodo 2: $(semisync "$N2")  (degradada a asíncrona: se eligió A sobre C)"

paso "3. Durante la partición los nodos difieren (consistencia eventual)"
info "Nodo 1 ve la #$C_COCINA: $(sql_nodo "$N1" "SELECT COUNT(*) FROM comandas WHERE id_comanda = $C_COCINA") fila(s) | Nodo 2 ve la #$C_SALON: $(sql_nodo "$N2" "SELECT COUNT(*) FROM comandas WHERE id_comanda = $C_SALON") fila(s)"

paso "4. Se restablece el enlace"
T0="$(ahora_ms)"
restablecer_enlace
ok "reconciliación por GTID en $(segundos_desde "$T0") s"
info "Nodo 1 ve la #$C_COCINA: $(sql_nodo "$N1" "SELECT COUNT(*) FROM comandas WHERE id_comanda = $C_COCINA") fila(s) | Nodo 2 ve la #$C_SALON: $(sql_nodo "$N2" "SELECT COUNT(*) FROM comandas WHERE id_comanda = $C_SALON") fila(s)"
info "IDs $C_SALON (impar) y $C_COCINA (par): sin colisión de clave primaria pese a escribir en paralelo"
bash pruebas_fase2/verificar_consistencia.sh | tail -n 1

# ---------------------------------------------------------------------------
titulo "PARTE B: CONFLICTO SOBRE LA MISMA FILA (LÍMITE DEL MULTI-PRIMARIO)"

paso "1. Nueva partición. Las dos áreas cambian el estado de la MISMA mesa (#9)"
cortar_enlace
sql_nodo "$N1" "UPDATE mesas SET estado = 'RESERVADA' WHERE id_mesa = 9"
sql_nodo "$N2" "UPDATE mesas SET estado = 'OCUPADA' WHERE id_mesa = 9"
info "Nodo 1 (Salón) dice: $(sql_nodo "$N1" "SELECT estado FROM mesas WHERE id_mesa = 9") | Nodo 2 (Cocina) dice: $(sql_nodo "$N2" "SELECT estado FROM mesas WHERE id_mesa = 9")"

paso "2. Se restablece el enlace: cada nodo aplica el cambio del otro"
restablecer_enlace
info "Nodo 1 ahora dice: $(sql_nodo "$N1" "SELECT estado FROM mesas WHERE id_mesa = 9") | Nodo 2 ahora dice: $(sql_nodo "$N2" "SELECT estado FROM mesas WHERE id_mesa = 9")"
info "Los valores quedaron CRUZADOS y la replicación sigue en 'Yes': MySQL no lo detecta."

paso "3. El verificador de consistencia sí lo detecta"
if bash pruebas_fase2/verificar_consistencia.sh > /tmp/verif_particion.txt 2>&1; then
    falla "se esperaba una divergencia y el verificador no la detectó"
fi
grep -E "mesas|INCONSISTENTE" /tmp/verif_particion.txt | sed 's/^/   /'

paso "4. Reparación según la regla de propiedad: las mesas son del Salón (Nodo 1)"
info "Se reescribe el valor válido en el nodo dueño y la replicación lo propaga"
sql_nodo "$N1" "UPDATE mesas SET estado = 'RESERVADA' WHERE id_mesa = 9"
restablecer_enlace
info "Nodo 1: $(sql_nodo "$N1" "SELECT estado FROM mesas WHERE id_mesa = 9") | Nodo 2: $(sql_nodo "$N2" "SELECT estado FROM mesas WHERE id_mesa = 9")"
sql_nodo "$N1" "UPDATE mesas SET estado = 'LIBRE' WHERE id_mesa = 9"
restablecer_enlace

paso "5. Consistencia final"
bash pruebas_fase2/verificar_consistencia.sh | sed -n '/Huella digital/,$p'
rm -f /tmp/verif_particion.txt

titulo "CONCLUSIÓN"
cat <<'EOF'
   - Ante una partición el clúster elige DISPONIBILIDAD (AP): ambas áreas siguen
     trabajando y la semisincronía se degrada a asíncrona tras 3 s.
   - Las altas no chocan gracias a los IDs impares/pares y se reconcilian solas.
   - Las modificaciones concurrentes de una MISMA fila divergen sin aviso: por eso
     cada tabla tiene un nodo dueño de sus escrituras (fragmentación funcional) y
     la consistencia se audita con verificar_consistencia.sh.
EOF
echo
echo "Resultado guardado en: $ARCHIVO_RESULTADO"
