#!/usr/bin/env bash
# ============================================================================
# AE4 - TIFAS FASE 1: PRUEBA INTEGRADA SALÓN (NODO 1) <-> COCINA (NODO 2)
# ----------------------------------------------------------------------------
# Recorre el ciclo de vida completo de una comanda repartido entre los dos nodos,
# tal como ocurre en el restaurante:
#   1. El Salón abre la comanda en el Nodo 1 (puerto 3307).
#   2. La comanda aparece en la comandera de la Cocina, en el Nodo 2 (puerto 3308).
#   3. La Cocina la marcha en el Nodo 2: descuenta stock y registra VENTA_COMANDA.
#   4. La Cocina la despacha (LISTA_PARA_SERVIR).
#   5. El Salón la ve lista en el Nodo 1, la entrega y la cobra (PAGADA).
#   6. El cobro llega al Nodo 2.
#   7. Trazabilidad: historial con IDs impares (Salón) y pares (Cocina) y
#      verificación de que ambos nodos quedaron idénticos.
# Cada paso mide cuánto tardó el cambio en verse en el otro nodo. La medición
# incluye el costo de "docker exec" (~0,1-0,2 s), así que es una cota superior.
#
# Uso (desde restaurant-cluster/, con el clúster levantado):
#     bash pruebas_fase1/prueba_flujo_cruzado.sh
# ============================================================================
source "$(dirname "$0")/../pruebas_fase2/comun.sh"
RESULTADOS=pruebas_fase1/resultados

# sql_tabla <contenedor> <consulta>: igual que sql_nodo pero con formato de tabla
sql_tabla() {
    local c="$1"; shift
    docker exec "$c" mysql -uroot -p"$ROOT_PW" --default-character-set=utf8mb4 -t -D "$DB" -e "$*" 2>/dev/null | sed 's/^/   /'
}

# esperar_valor <contenedor> <consulta> <valor>: espera hasta que la consulta devuelva
# el valor y escribe cuántos milisegundos tardó.
esperar_valor() {
    local c="$1" q="$2" v="$3" t0 i
    t0="$(ahora_ms)"
    for ((i = 0; i < 100; i++)); do
        if [[ "$(sql_nodo "$c" "$q")" == "$v" ]]; then
            echo $(( $(ahora_ms) - t0 ))
            return 0
        fi
        sleep 0.1
    done
    return 1
}

registrar prueba_flujo_cruzado
titulo "PRUEBA INTEGRADA: FLUJO CRUZADO SALÓN (NODO 1) <-> COCINA (NODO 2)"
precondiciones

MESA=6
[[ "$(sql_nodo "$N1" "SELECT estado FROM mesas WHERE id_mesa = $MESA")" == "LIBRE" ]] \
    || falla "la mesa $MESA no está LIBRE; reiniciar el entorno o liberar la mesa"

paso "Stock inicial de los productos que se van a pedir (Nodo 2, dueño del stock)"
sql_tabla "$N2" "SELECT id_producto, nombre, stock_disponible FROM productos_menu WHERE id_producto IN (2, 4, 12)"
STOCK_ANTES="$(sql_nodo "$N2" "SELECT GROUP_CONCAT(stock_disponible ORDER BY id_producto) FROM productos_menu WHERE id_producto IN (2, 4, 12)")"

# ----------------------------------------------------------------------------
paso "1. SALÓN (Nodo 1, $(sql_nodo "$N1" "SELECT @@hostname")): apertura de la comanda de la mesa $MESA"
C="$(sql_nodo "$N1" "
START TRANSACTION;
UPDATE mesas SET estado = 'OCUPADA' WHERE id_mesa = $MESA AND estado = 'LIBRE';
INSERT INTO comandas (id_mesa, id_cliente, mozo, nodo_origen, estado, total)
VALUES ($MESA, 4, 'Lucía Fernández', 'NODO_1_SALON', 'ABIERTA', 0.00);
SET @c = LAST_INSERT_ID();
INSERT INTO historial_estados_comanda (id_comanda, estado_anterior, estado_nuevo, operador, nodo_emisor, observacion)
VALUES (@c, NULL, 'ABIERTA', 'Lucía Fernández', 'NODO_1_SALON', 'Apertura de la mesa $MESA (prueba integrada)');
INSERT INTO detalle_comanda (id_comanda, id_producto, cantidad, precio_unitario, estado_cocina, punto_coccion, apto_celiaco, sin_sal, observaciones) VALUES
(@c, 2,  1,  8500.00, 'PENDIENTE', 'NO_APLICA', FALSE, FALSE, 'Para compartir'),
(@c, 4,  2, 24000.00, 'PENDIENTE', 'A_PUNTO',   FALSE, TRUE,  'Uno de los dos sin sal'),
(@c, 12, 1, 18900.00, 'ENTREGADO', 'NO_APLICA', FALSE, FALSE, 'Servido en la mesa por el mozo');
UPDATE comandas SET total = (SELECT SUM(subtotal) FROM detalle_comanda WHERE id_comanda = @c) WHERE id_comanda = @c;
COMMIT;
SELECT @c;")"
[[ -n "$C" ]] || falla "no se pudo abrir la comanda"
TOTAL="$(sql_nodo "$N1" "SELECT total FROM comandas WHERE id_comanda = $C")"
ok "comanda #$C abierta en el Nodo 1 (ID $( (( C % 2 )) && echo IMPAR || echo PAR )), total \$$TOTAL"
(( C % 2 == 1 )) || falla "el Nodo 1 debería generar IDs impares"

# ----------------------------------------------------------------------------
paso "2. COCINA (Nodo 2): la comanda aparece en la comandera"
MS="$(esperar_valor "$N2" "SELECT estado FROM comandas WHERE id_comanda = $C" "ABIERTA")" \
    || falla "la comanda #$C no llegó al Nodo 2"
ok "la comanda #$C es visible en el Nodo 2 a los $MS ms"
info "Comandera digital de Cocina (Consulta 4.1 de abm_cocina.sql) en el Nodo 2:"
sql_tabla "$N2" "
SELECT c.id_comanda, c.nodo_origen, c.mozo, m.numero_mesa AS mesa, p.nombre AS plato,
       d.cantidad, d.estado_cocina, d.punto_coccion, d.sin_sal, d.observaciones
FROM comandas c
JOIN mesas m ON c.id_mesa = m.id_mesa
JOIN detalle_comanda d ON c.id_comanda = d.id_comanda
JOIN productos_menu p ON d.id_producto = p.id_producto
WHERE d.estado_cocina IN ('PENDIENTE', 'EN_COCCION') AND c.id_comanda = $C"

# ----------------------------------------------------------------------------
paso "3. COCINA (Nodo 2, $(sql_nodo "$N2" "SELECT @@hostname")): marcha de la comanda y descuento de stock (Caso 2.A)"
sql_nodo "$N2" "
SET @comanda_a_marchar = $C;
START TRANSACTION;
UPDATE comandas SET estado = 'EN_PREPARACION' WHERE id_comanda = @comanda_a_marchar AND estado = 'ABIERTA';
INSERT INTO historial_estados_comanda (id_comanda, estado_anterior, estado_nuevo, operador, nodo_emisor, observacion)
VALUES (@comanda_a_marchar, 'ABIERTA', 'EN_PREPARACION', 'Jefe de Partida', 'NODO_2_COCINA', 'Ingreso a cocina: inicio de marchas');
UPDATE detalle_comanda SET estado_cocina = 'EN_COCCION'
WHERE id_comanda = @comanda_a_marchar AND estado_cocina = 'PENDIENTE'
  AND id_producto IN (SELECT id_producto FROM productos_menu WHERE categoria IN ('ENTRADA', 'PLATO_PRINCIPAL', 'POSTRE'));
SELECT id_producto FROM productos_menu
WHERE id_producto IN (SELECT id_producto FROM detalle_comanda WHERE id_comanda = @comanda_a_marchar) FOR UPDATE;
INSERT INTO movimientos_stock (id_producto, tipo_movimiento, cantidad, stock_previo, stock_posterior, motivo, nodo_origen)
SELECT p.id_producto, 'VENTA_COMANDA', v.cantidad_total, p.stock_disponible, p.stock_disponible - v.cantidad_total,
       CONCAT('Marcha de comanda #', @comanda_a_marchar), 'NODO_2_COCINA'
FROM productos_menu p
JOIN (SELECT id_producto, SUM(cantidad) AS cantidad_total FROM detalle_comanda
      WHERE id_comanda = @comanda_a_marchar GROUP BY id_producto) v ON v.id_producto = p.id_producto;
UPDATE productos_menu p
JOIN (SELECT id_producto, SUM(cantidad) AS cantidad_total FROM detalle_comanda
      WHERE id_comanda = @comanda_a_marchar GROUP BY id_producto) v ON v.id_producto = p.id_producto
SET p.stock_disponible = p.stock_disponible - v.cantidad_total;
COMMIT;" > /dev/null
ok "comanda #$C en EN_PREPARACION; platos en EN_COCCION"
info "Kardex: movimientos VENTA_COMANDA generados por la Cocina (IDs pares):"
sql_tabla "$N2" "SELECT id_movimiento, id_producto, tipo_movimiento, cantidad, stock_previo, stock_posterior, motivo
                 FROM movimientos_stock WHERE motivo = 'Marcha de comanda #$C' ORDER BY id_movimiento"

# ----------------------------------------------------------------------------
paso "4. COCINA (Nodo 2): platos terminados, campana de despacho (Caso 2.B)"
sql_nodo "$N2" "
START TRANSACTION;
UPDATE detalle_comanda SET estado_cocina = 'LISTO' WHERE id_comanda = $C AND estado_cocina = 'EN_COCCION';
UPDATE comandas SET estado = 'LISTA_PARA_SERVIR' WHERE id_comanda = $C AND estado = 'EN_PREPARACION';
INSERT INTO historial_estados_comanda (id_comanda, estado_anterior, estado_nuevo, operador, nodo_emisor, observacion)
VALUES ($C, 'EN_PREPARACION', 'LISTA_PARA_SERVIR', 'Despachador', 'NODO_2_COCINA', 'Platos listos para retirar');
COMMIT;"
ok "comanda #$C en LISTA_PARA_SERVIR (Nodo 2)"

# ----------------------------------------------------------------------------
paso "5. SALÓN (Nodo 1): el mozo ve la comanda lista, la entrega y la cobra"
MS="$(esperar_valor "$N1" "SELECT estado FROM comandas WHERE id_comanda = $C" "LISTA_PARA_SERVIR")" \
    || falla "el estado LISTA_PARA_SERVIR no llegó al Nodo 1"
ok "el Nodo 1 ve la comanda #$C LISTA_PARA_SERVIR a los $MS ms"
PUNTOS_ANTES="$(sql_nodo "$N1" "SELECT puntos_fidelidad FROM clientes WHERE id_cliente = 4")"
sql_nodo "$N1" "
START TRANSACTION;
UPDATE detalle_comanda SET estado_cocina = 'ENTREGADO' WHERE id_comanda = $C AND estado_cocina = 'LISTO';
UPDATE comandas SET estado = 'ENTREGADA' WHERE id_comanda = $C AND estado = 'LISTA_PARA_SERVIR';
INSERT INTO historial_estados_comanda (id_comanda, estado_anterior, estado_nuevo, operador, nodo_emisor, observacion)
VALUES ($C, 'LISTA_PARA_SERVIR', 'ENTREGADA', 'Lucía Fernández', 'NODO_1_SALON', 'Platos servidos en la mesa $MESA');
COMMIT;
START TRANSACTION;
INSERT INTO pagos (id_comanda, metodo_pago, tipo_comprobante, numero_comprobante, codigo_autorizacion, monto_total, nodo_caja)
SELECT id_comanda, 'TARJETA_DEBITO', 'FACTURA_B', '0001-00004600', 'AUT-DEB-4600', total, 'NODO_1_SALON'
FROM comandas WHERE id_comanda = $C;
UPDATE comandas SET estado = 'PAGADA', fecha_cierre = NOW() WHERE id_comanda = $C AND estado = 'ENTREGADA';
INSERT INTO historial_estados_comanda (id_comanda, estado_anterior, estado_nuevo, operador, nodo_emisor, observacion)
VALUES ($C, 'ENTREGADA', 'PAGADA', 'Cajero Salón 1', 'NODO_1_SALON', 'Cobro con tarjeta de débito');
UPDATE clientes SET puntos_fidelidad = puntos_fidelidad + FLOOR((SELECT total FROM comandas WHERE id_comanda = $C) / 500)
WHERE id_cliente = 4;
UPDATE mesas SET estado = 'LIBRE' WHERE id_mesa = $MESA;
COMMIT;"
PUNTOS_DESPUES="$(sql_nodo "$N1" "SELECT puntos_fidelidad FROM clientes WHERE id_cliente = 4")"
ok "comanda #$C PAGADA en el Nodo 1; mesa $MESA LIBRE; puntos del cliente: $PUNTOS_ANTES -> $PUNTOS_DESPUES"

# ----------------------------------------------------------------------------
paso "6. COCINA (Nodo 2): recibe el cierre de la comanda"
MS="$(esperar_valor "$N2" "SELECT estado FROM comandas WHERE id_comanda = $C" "PAGADA")" \
    || falla "el cobro no llegó al Nodo 2"
ok "el Nodo 2 ve la comanda #$C PAGADA a los $MS ms"
[[ "$(sql_nodo "$N2" "SELECT monto_total FROM pagos WHERE id_comanda = $C")" == "$TOTAL" ]] \
    || falla "el pago no coincide en el Nodo 2"
ok "el pago de \$$TOTAL está en el Nodo 2"

# ----------------------------------------------------------------------------
paso "7. Trazabilidad de la comanda #$C vista desde cada nodo"
info "Historial en el Nodo 1 (IDs impares = Salón, pares = Cocina):"
sql_tabla "$N1" "SELECT id_historial, IF(MOD(id_historial, 2) = 1, 'IMPAR', 'PAR') AS paridad, estado_anterior, estado_nuevo, operador, nodo_emisor
                 FROM historial_estados_comanda WHERE id_comanda = $C ORDER BY fecha_cambio, id_historial"
info "Historial en el Nodo 2 (debe ser idéntico):"
sql_tabla "$N2" "SELECT id_historial, IF(MOD(id_historial, 2) = 1, 'IMPAR', 'PAR') AS paridad, estado_anterior, estado_nuevo, operador, nodo_emisor
                 FROM historial_estados_comanda WHERE id_comanda = $C ORDER BY fecha_cambio, id_historial"

MAL="$(sql_nodo "$N1" "SELECT COUNT(*) FROM historial_estados_comanda WHERE id_comanda = $C
       AND ((nodo_emisor = 'NODO_1_SALON' AND MOD(id_historial, 2) = 0) OR (nodo_emisor = 'NODO_2_COCINA' AND MOD(id_historial, 2) = 1))")"
[[ "$MAL" == "0" ]] || falla "hay filas de historial con la paridad cambiada"
ok "cada nodo generó claves solo de su paridad: no hubo colisiones"

info "Stock final en ambos nodos (antes: $STOCK_ANTES para los productos 2, 4 y 12):"
sql_tabla "$N1" "SELECT 'Nodo 1' AS nodo, GROUP_CONCAT(stock_disponible ORDER BY id_producto) AS stock_2_4_12 FROM productos_menu WHERE id_producto IN (2, 4, 12)"
sql_tabla "$N2" "SELECT 'Nodo 2' AS nodo, GROUP_CONCAT(stock_disponible ORDER BY id_producto) AS stock_2_4_12 FROM productos_menu WHERE id_producto IN (2, 4, 12)"

titulo "RESULTADO: flujo cruzado completo sin errores (comanda #$C, total \$$TOTAL)"
bash pruebas_fase2/verificar_consistencia.sh
