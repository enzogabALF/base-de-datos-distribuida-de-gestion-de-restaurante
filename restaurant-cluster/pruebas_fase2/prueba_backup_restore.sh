#!/usr/bin/env bash
# ============================================================================
# AE4 - TIFAS FASE 2: DESASTRE LÓGICO Y RECUPERACIÓN DESDE RESPALDOS (PITR)
# ----------------------------------------------------------------------------
# La replicación protege contra la caída de un SERVIDOR, pero no contra un ERROR:
# un "DELETE FROM pagos" ejecutado por equivocación se replica al otro nodo en
# milisegundos y borra los datos de ambos. Ahí es donde entran los respaldos.
#
# Recorrido completo de la política de respaldo:
#   1. Backup COMPLETO.
#   2. Operación normal + backup INCREMENTAL.
#   3. Operación normal + backup DIFERENCIAL.
#   4. DESASTRE: alguien borra todos los pagos. Se replica a ambos nodos.
#   5. La operación sigue (una comanda nueva legítima) + backup INCREMENTAL.
#   6. RESTAURACIÓN a un punto en el tiempo: completo + diferencial + incremental,
#      reaplicando los binlogs pero EXCLUYENDO solo la transacción dañina (su GTID).
#   7. Reinyección de los pagos recuperados en producción y verificación final.
#
# Uso: bash pruebas_fase2/prueba_backup_restore.sh
# ============================================================================
source "$(dirname "$0")/comun.sh"
registrar "prueba_backup_restore"
titulo "PRUEBA 4: DESASTRE LÓGICO Y RECUPERACIÓN A UN PUNTO EN EL TIEMPO"

precondiciones
BK_SCRIPT="/opt/backup"
respaldo() { docker exec "$BK" bash "$BK_SCRIPT/$1" 2>&1 | grep -v "^Warning: A partial dump" | sed 's/^/   /'; }

paso "1. Backup COMPLETO"
respaldo backup_full.sh
PAGOS_INICIALES="$(sql_nodo "$N1" "SELECT COUNT(*) FROM pagos")"
info "pagos en producción: $PAGOS_INICIALES"

paso "2. Operación normal: el Salón cobra una comanda nueva -> backup INCREMENTAL"
C1="$(sql_app salon "INSERT INTO comandas (id_mesa, mozo, estado, total) VALUES (4, 'PITR - cobrada', 'PAGADA', 16500.00); SELECT LAST_INSERT_ID();")"
sql_app salon "INSERT INTO pagos (id_comanda, metodo_pago, tipo_comprobante, numero_comprobante, monto_total) VALUES ($C1, 'EFECTIVO', 'TICKET_CONSUMO', 'T-0001-00009001', 16500.00)" > /dev/null
ok "comanda #$C1 cobrada"
respaldo backup_incremental.sh

paso "3. Operación normal: otra comanda cobrada -> backup DIFERENCIAL"
C2="$(sql_app salon "INSERT INTO comandas (id_mesa, mozo, estado, total) VALUES (5, 'PITR - cobrada', 'PAGADA', 22500.00); SELECT LAST_INSERT_ID();")"
sql_app salon "INSERT INTO pagos (id_comanda, metodo_pago, tipo_comprobante, numero_comprobante, monto_total) VALUES ($C2, 'TARJETA_DEBITO', 'FACTURA_B', 'B-0001-00009002', 22500.00)" > /dev/null
ok "comanda #$C2 cobrada"
respaldo backup_diferencial.sh
PAGOS_ANTES="$(sql_nodo "$N1" "SELECT COUNT(*) FROM pagos")"
TOTAL_ANTES="$(sql_nodo "$N1" "SELECT SUM(monto_total) FROM pagos")"
info "pagos antes del desastre: $PAGOS_ANTES (total \$$TOTAL_ANTES)"

paso "4. DESASTRE: se ejecuta por error DELETE FROM pagos en el Nodo 1"
G_ANTES="$(sql_nodo "$N1" "SELECT REPLACE(@@GLOBAL.gtid_executed, '\n', '')")"
sql_nodo "$N1" "DELETE FROM pagos"
G_DESPUES="$(sql_nodo "$N1" "SELECT REPLACE(@@GLOBAL.gtid_executed, '\n', '')")"
GTID_MALO="$(sql_nodo "$N1" "SELECT GTID_SUBTRACT('$G_DESPUES', '$G_ANTES')")"
FECHA_DESASTRE="$(date '+%F %T')"
ok "transacción dañina identificada por su GTID: $GTID_MALO ($FECHA_DESASTRE)"
sleep 1
info "pagos en Nodo 1: $(sql_nodo "$N1" "SELECT COUNT(*) FROM pagos") | pagos en Nodo 2: $(sql_nodo "$N2" "SELECT COUNT(*) FROM pagos")"
info "-> la replicación PROPAGÓ el error: la alta disponibilidad no reemplaza al respaldo."

paso "5. La operación continúa: se abre una comanda legítima -> backup INCREMENTAL"
C3="$(sql_app salon "INSERT INTO comandas (id_mesa, mozo, estado) VALUES (6, 'PITR - posterior al desastre', 'ABIERTA'); SELECT LAST_INSERT_ID();")"
ok "comanda #$C3 creada DESPUÉS del desastre (no se debe perder al recuperar)"
respaldo backup_incremental.sh
docker exec "$BK" bash "$BK_SCRIPT/listar_backups.sh" | sed -n '/Cadena actual/,/^$/p;/== '"$(docker exec "$BK" cat /backups/cadena_actual)"'/,/^$/p' | sed 's/^/   /'

paso "6. RESTAURACIÓN: completo + diferencial + incremental, excluyendo SOLO el GTID $GTID_MALO"
T0="$(ahora_ms)"
docker exec "$BK" bash "$BK_SCRIPT/restaurar.sh" --excluir-gtids "$GTID_MALO" 2>&1 | sed 's/^/   /'
T_RESTAURACION="$(segundos_desde "$T0")"
RCLI=(docker exec "$BK" mysql -h127.0.0.1 -P3309 -uroot -p"$ROOT_PW" -N -B -D "$DB")
P_REST="$("${RCLI[@]}" -e "SELECT COUNT(*) FROM pagos" 2>/dev/null)"
C3_REST="$("${RCLI[@]}" -e "SELECT COUNT(*) FROM comandas WHERE id_comanda = $C3" 2>/dev/null)"
[[ "$P_REST" == "$PAGOS_ANTES" ]] || falla "la instancia restaurada tiene $P_REST pagos (se esperaban $PAGOS_ANTES)"
[[ "$C3_REST" == "1" ]] || falla "la comanda posterior al desastre (#$C3) no está en la restauración"
ok "instancia restaurada: $P_REST pagos (los de antes del error) y la comanda #$C3 posterior al error"

paso "7. Reinyección de los pagos recuperados en producción (Nodo 1, dueño de la caja)"
T0="$(ahora_ms)"
docker exec "$BK" bash -c "mysqldump -h127.0.0.1 -P3309 -uroot -p'$ROOT_PW' --no-create-info --skip-add-locks \
    --set-gtid-purged=OFF --replace $DB pagos 2>/dev/null \
    | mysql -h172.28.0.11 -uroot -p'$ROOT_PW' $DB 2>/dev/null"
T_REINYECCION="$(segundos_desde "$T0")"
sleep 1
P1="$(sql_nodo "$N1" "SELECT COUNT(*) FROM pagos")"; P2="$(sql_nodo "$N2" "SELECT COUNT(*) FROM pagos")"
TOTAL_DESPUES="$(sql_nodo "$N1" "SELECT SUM(monto_total) FROM pagos")"
[[ "$P1" == "$PAGOS_ANTES" && "$P2" == "$PAGOS_ANTES" ]] || falla "pagos tras reinyectar: Nodo 1=$P1, Nodo 2=$P2"
[[ "$TOTAL_DESPUES" == "$TOTAL_ANTES" ]] || falla "el total cobrado no coincide ($TOTAL_DESPUES vs $TOTAL_ANTES)"
ok "pagos en Nodo 1: $P1 | Nodo 2: $P2 | total \$$TOTAL_DESPUES (igual que antes del desastre)"

paso "8. Consistencia final"
bash pruebas_fase2/verificar_consistencia.sh | sed -n '/Huella digital/,$p'

titulo "RESUMEN"
printf '   %-55s %s\n' "Pagos antes del desastre / borrados / recuperados" "$PAGOS_ANTES / $PAGOS_ANTES / $P1"
printf '   %-55s %s\n' "Trabajo legítimo posterior al error conservado" "sí (comanda #$C3)"
printf '   %-55s %s\n' "Tiempo de restauración verificada (instancia aislada)" "$T_RESTAURACION s"
printf '   %-55s %s\n' "Tiempo de reinyección en producción" "$T_REINYECCION s"
echo
echo "Resultado guardado en: $ARCHIVO_RESULTADO"
