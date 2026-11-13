#!/usr/bin/env bash
# ============================================================================
# AE4 - TIFAS FASE 1: EVIDENCIA DE LAS RESTRICCIONES DE INTEGRIDAD
# ----------------------------------------------------------------------------
# Ejecuta, sin comentar, las sentencias inválidas del Bloque 2 de
# verificacion_tecnica_nodo1.sql y del Bloque 3 de verificacion_tecnica_nodo2.sql,
# más otros casos de integridad referencial, y comprueba que:
#   1. El motor rechaza cada una con el código de error esperado
#      (3819 CHECK, 1062 UNIQUE, 1452/1451 FOREIGN KEY, 1265 ENUM, 3105 columna generada).
#   2. Ninguna fila inválida quedó guardada.
#   3. Las sentencias rechazadas no generaron transacciones (GTID) ni se
#      replicaron: el otro nodo nunca las recibe y la replicación sigue sana.
#
# Uso (desde restaurant-cluster/, con el clúster levantado):
#     bash pruebas_fase1/prueba_restricciones.sh
# ============================================================================
source "$(dirname "$0")/../pruebas_fase2/comun.sh"
RESULTADOS=pruebas_fase1/resultados

registrar prueba_restricciones
titulo "PRUEBA DE RESTRICCIONES DE INTEGRIDAD (CHECK, UNIQUE, FOREIGN KEY)"
precondiciones

TOTAL=0
APROBADAS=0

# esperar_error <contenedor> <código> <descripción> <sentencia>
esperar_error() {
    local c="$1" codigo="$2" desc="$3" sentencia="$4" salida
    TOTAL=$((TOTAL + 1))
    salida="$(docker exec "$c" mysql -uroot -p"$ROOT_PW" --default-character-set=utf8mb4 -D "$DB" -e "$sentencia" 2>&1 \
              | grep -v -e 'Using a password' -e 'World-writable' || true)"
    printf '\n   [%d] %s\n' "$TOTAL" "$desc"
    printf '       SQL:       %s\n' "$(tr -s ' \n' ' ' <<< "$sentencia")"
    printf '       Respuesta: %s\n' "${salida:-(sin error)}"
    if grep -q "^ERROR $codigo " <<< "$salida"; then
        APROBADAS=$((APROBADAS + 1))
        printf '       [OK] rechazada con el error %s esperado\n' "$codigo"
    else
        printf '       [ERROR] se esperaba el error %s\n' "$codigo"
    fi
}

# Foto de control: filas por tabla y GTID ejecutados en cada nodo
conteo() {
    sql_nodo "$1" "SELECT CONCAT_WS(',',
        (SELECT COUNT(*) FROM clientes), (SELECT COUNT(*) FROM mesas), (SELECT COUNT(*) FROM productos_menu),
        (SELECT COUNT(*) FROM movimientos_stock), (SELECT COUNT(*) FROM comandas),
        (SELECT COUNT(*) FROM historial_estados_comanda), (SELECT COUNT(*) FROM detalle_comanda), (SELECT COUNT(*) FROM pagos),
        (SELECT SUM(stock_disponible) FROM productos_menu))"
}
gtid() { sql_nodo "$1" "SELECT REPLACE(@@global.gtid_executed, '\n', '')"; }

paso "Foto de control antes de las pruebas"
C1_ANTES="$(conteo "$N1")"; C2_ANTES="$(conteo "$N2")"
G1_ANTES="$(gtid "$N1")"; G2_ANTES="$(gtid "$N2")"
info "Filas por tabla + stock total, Nodo 1: $C1_ANTES"
info "Filas por tabla + stock total, Nodo 2: $C2_ANTES"
info "GTID Nodo 1: $G1_ANTES"

# Una comanda existente y ya pagada para los casos que la necesitan
COMANDA="$(sql_nodo "$N1" "SELECT MIN(id_comanda) FROM pagos")"
[[ -n "$COMANDA" && "$COMANDA" != "NULL" ]] || falla "no hay comandas pagadas; ejecutar antes reiniciar_entorno.sh"

# ----------------------------------------------------------------------------
paso "A. Bloque 2 de verificacion_tecnica_nodo1.sql (Nodo 1 - Salón)"

esperar_error "$N1" 3819 "2.1 CHECK: precio negativo en el menú" \
    "INSERT INTO productos_menu (nombre, categoria, precio, stock_disponible) VALUES ('Plato Inválido', 'ENTRADA', -500.00, 10)"

esperar_error "$N1" 3819 "2.2 CHECK: cantidad 0 en una línea de comanda" \
    "INSERT INTO detalle_comanda (id_comanda, id_producto, cantidad, precio_unitario) VALUES ($COMANDA, 1, 0, 1000.00)"

esperar_error "$N1" 1062 "2.3 UNIQUE: número de mesa duplicado" \
    "INSERT INTO mesas (numero_mesa, capacidad, sector) VALUES (1, 4, 'Salón Principal')"

# ----------------------------------------------------------------------------
paso "B. Casos adicionales de integridad (Nodo 1 - Salón)"

esperar_error "$N1" 1062 "UNIQUE: CUIT/DNI de cliente duplicado" \
    "INSERT INTO clientes (nombre_completo, cuit_dni) VALUES ('Cliente Duplicado', '20-34567890-9')"

esperar_error "$N1" 1062 "UNIQUE: segundo pago para una comanda ya cobrada (no se cobra dos veces)" \
    "INSERT INTO pagos (id_comanda, metodo_pago, monto_total) VALUES ($COMANDA, 'EFECTIVO', 100.00)"

esperar_error "$N1" 3819 "CHECK: pago con monto cero" \
    "INSERT INTO pagos (id_comanda, metodo_pago, monto_total) VALUES ($COMANDA, 'EFECTIVO', 0)"

esperar_error "$N1" 3819 "CHECK: mesa con capacidad 0" \
    "INSERT INTO mesas (numero_mesa, capacidad) VALUES (99, 0)"

esperar_error "$N1" 1452 "FOREIGN KEY: comanda para una mesa inexistente" \
    "INSERT INTO comandas (id_mesa, mozo) VALUES (999, 'Mozo de prueba')"

esperar_error "$N1" 1452 "FOREIGN KEY: línea de comanda con un producto inexistente" \
    "INSERT INTO detalle_comanda (id_comanda, id_producto, cantidad, precio_unitario) VALUES ($COMANDA, 999, 1, 1000.00)"

esperar_error "$N1" 1451 "FOREIGN KEY ON DELETE RESTRICT: borrar una mesa con comandas" \
    "DELETE FROM mesas WHERE id_mesa = (SELECT id_mesa FROM comandas WHERE id_comanda = $COMANDA)"

esperar_error "$N1" 1451 "FOREIGN KEY ON DELETE RESTRICT: borrar una comanda que tiene pago" \
    "DELETE FROM comandas WHERE id_comanda = $COMANDA"

esperar_error "$N1" 1265 "ENUM: estado de comanda inexistente (modo estricto)" \
    "UPDATE comandas SET estado = 'VOLANDO' WHERE id_comanda = $COMANDA"

esperar_error "$N1" 3105 "Columna generada: no se puede escribir el subtotal a mano" \
    "INSERT INTO detalle_comanda (id_comanda, id_producto, cantidad, precio_unitario, subtotal) VALUES ($COMANDA, 1, 1, 1000.00, 5.00)"

# ----------------------------------------------------------------------------
paso "C. Bloque 3 de verificacion_tecnica_nodo2.sql (Nodo 2 - Cocina / Stock)"

esperar_error "$N2" 3819 "3.1 CHECK: stock disponible negativo" \
    "UPDATE productos_menu SET stock_disponible = -1 WHERE id_producto = 8"

esperar_error "$N2" 3819 "3.2 CHECK: movimiento de stock que deja stock_posterior negativo" \
    "INSERT INTO movimientos_stock (id_producto, tipo_movimiento, cantidad, stock_previo, stock_posterior, nodo_origen) VALUES (8, 'MERMA_ROTURA', 500, 30, -470, 'NODO_2_COCINA')"

esperar_error "$N2" 1452 "3.3 FOREIGN KEY: movimiento de stock de un producto inexistente" \
    "INSERT INTO movimientos_stock (id_producto, tipo_movimiento, cantidad, stock_previo, stock_posterior, nodo_origen) VALUES (999, 'INGRESO_PROVEEDOR', 10, 0, 10, 'NODO_2_COCINA')"

esperar_error "$N2" 1451 "FOREIGN KEY ON DELETE RESTRICT: borrar un producto con historial de stock" \
    "DELETE FROM productos_menu WHERE id_producto = 3"

# ----------------------------------------------------------------------------
paso "D. Efecto sobre los datos y la replicación"
sleep 1
C1_DESP="$(conteo "$N1")"; C2_DESP="$(conteo "$N2")"
G1_DESP="$(gtid "$N1")"; G2_DESP="$(gtid "$N2")"
[[ "$C1_ANTES" == "$C1_DESP" && "$C2_ANTES" == "$C2_DESP" ]] \
    && ok "ninguna fila inválida quedó guardada (conteos y stock total sin cambios en ambos nodos)" \
    || falla "cambiaron los datos: Nodo 1 $C1_ANTES -> $C1_DESP | Nodo 2 $C2_ANTES -> $C2_DESP"
[[ "$G1_ANTES" == "$G1_DESP" && "$G2_ANTES" == "$G2_DESP" ]] \
    && ok "las sentencias rechazadas no generaron GTID: nunca llegaron al binary log ni al otro nodo" \
    || falla "cambió el conjunto de GTID ejecutados"
replicacion_ok "$N1" && replicacion_ok "$N2" \
    && ok "la replicación sigue corriendo en ambos sentidos (IO=Yes, SQL=Yes)" \
    || falla "la replicación se detuvo"

titulo "RESULTADO: $APROBADAS de $TOTAL violaciones rechazadas con el error esperado"
[[ "$APROBADAS" == "$TOTAL" ]] || falla "hubo casos que no respondieron como se esperaba"
bash pruebas_fase2/verificar_consistencia.sh
