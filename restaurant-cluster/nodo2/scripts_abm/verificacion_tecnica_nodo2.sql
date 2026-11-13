-- ============================================================================
-- AE4 - TIFAS: PROTOCOLO DE VERIFICACIÓN TÉCNICA Y PRUEBAS ABM (NODO 2 - COCINA)
-- Cátedra: Gestión Avanzada de Bases de Datos - Arquitectura 100% Relacional (SQL Puro)
-- ----------------------------------------------------------------------------
-- Equivalente del script verificacion_tecnica_nodo1.sql para el Nodo 2.
-- Se ejecuta conectado al Nodo 2 (puerto 3308), por ejemplo:
--   docker exec -i restaurante_nodo2_cocina mysql -uroot -proot_password_ae4 \
--       < nodo2/scripts_abm/verificacion_tecnica_nodo2.sql
-- Comprueba:
--   1. La configuración propia del Nodo 2 (server_id = 2, offset = 2, GTID).
--   2. La replicación semisincrónica y el enlace con el Nodo 1.
--   3. Que todo lo que se da de alta en el Nodo 2 recibe claves primarias PARES.
-- ============================================================================

USE restaurante_db;

-- ============================================================================
-- BLOQUE 1: VERIFICACIÓN DE VARIABLES CRÍTICAS DE CONSISTENCIA Y TOPOLOGÍA
-- ============================================================================

-- Valores esperados: server_id = 2, increment = 2, offset = 2,
-- flush_log_trx = 1, sync_binlog = 1, gtid_mode = ON, enforce_gtid = ON.
SELECT
    @@hostname                       AS host,
    @@server_id                      AS nodo_server_id,
    @@server_uuid                    AS nodo_server_uuid,
    @@auto_increment_increment       AS auto_inc_increment,
    @@auto_increment_offset          AS auto_inc_offset,
    @@innodb_flush_log_at_trx_commit AS flush_log_trx,
    @@sync_binlog                    AS sync_binlog,
    @@gtid_mode                      AS gtid_mode,
    @@enforce_gtid_consistency       AS enforce_gtid,
    @@binlog_format                  AS binlog_format;

-- Chequeo automático: 1 = la configuración es la esperada para el Nodo 2.
SELECT
    (@@server_id = 2
     AND @@auto_increment_increment = 2
     AND @@auto_increment_offset = 2
     AND @@gtid_mode = 'ON'
     AND @@enforce_gtid_consistency = 'ON'
     AND @@innodb_flush_log_at_trx_commit = 1
     AND @@sync_binlog = 1) AS configuracion_nodo2_ok;


-- ============================================================================
-- BLOQUE 2: REPLICACIÓN SEMISINCRÓNICA (AFTER_SYNC) Y ENLACE CON EL NODO 1
-- ============================================================================

-- Variables: master y slave habilitados, wait_point = AFTER_SYNC, timeout = 3000 ms.
SHOW VARIABLES LIKE 'rpl_semi_sync%';

-- Estado: Rpl_semi_sync_master_status = ON y Rpl_semi_sync_master_clients = 1
-- indican que el Nodo 1 está conectado y confirma cada transacción del Nodo 2.
-- Rpl_semi_sync_slave_status = ON indica que el Nodo 2 confirma las del Nodo 1.
SHOW STATUS LIKE 'Rpl_semi_sync%';

-- Enlace de replicación entrante (Nodo 1 -> Nodo 2).
-- Esperado: Replica_IO_Running = Yes, Replica_SQL_Running = Yes,
-- Source_Host = 172.28.0.11, Auto_Position = 1, Seconds_Behind_Source = 0.
SHOW REPLICA STATUS\G

-- Conjunto de GTID ejecutados: debe contener las transacciones de ambos servidores.
SELECT @@global.gtid_executed AS gtid_ejecutados;


-- ============================================================================
-- BLOQUE 3: PRUEBAS DE RESTRICCIONES DEL ÁREA DE COCINA / STOCK
-- (comentadas para que el script corra de punta a punta; la evidencia de cada
--  error está en pruebas_fase1/prueba_restricciones.sh)
-- ============================================================================

-- 3.1. CHECK de stock: no se puede dejar stock negativo.
-- EXPECTATIVA: Error 3819 (Check constraint 'productos_menu_chk_2' is violated)
-- UPDATE productos_menu SET stock_disponible = -1 WHERE id_producto = 8;

-- 3.2. CHECK del Kardex: un movimiento no puede dejar stock_posterior negativo.
-- EXPECTATIVA: Error 3819 (Check constraint 'movimientos_stock_chk_2' is violated)
-- INSERT INTO movimientos_stock (id_producto, tipo_movimiento, cantidad, stock_previo, stock_posterior, nodo_origen)
-- VALUES (8, 'MERMA_ROTURA', 500, 30, -470, 'NODO_2_COCINA');

-- 3.3. FOREIGN KEY: no se puede registrar stock de un producto inexistente.
-- EXPECTATIVA: Error 1452 (Cannot add or update a child row: a foreign key constraint fails)
-- INSERT INTO movimientos_stock (id_producto, tipo_movimiento, cantidad, stock_previo, stock_posterior, nodo_origen)
-- VALUES (999, 'INGRESO_PROVEEDOR', 10, 0, 10, 'NODO_2_COCINA');


-- ============================================================================
-- BLOQUE 4: PRUEBAS DE ALTA (INSERT) DESDE EL NODO 2 - IDENTIFICADORES PARES
-- ============================================================================

START TRANSACTION;

-- 4.1. Ingreso de mercadería (movimiento de stock generado en Cocina)
SET @prod_verif = 12; -- Vino Malbec Reserva 750ml
SET @cant_verif = 6;

SELECT stock_disponible INTO @stock_verif
FROM productos_menu
WHERE id_producto = @prod_verif FOR UPDATE;

INSERT INTO movimientos_stock (id_producto, tipo_movimiento, cantidad, stock_previo, stock_posterior, motivo, nodo_origen)
VALUES (@prod_verif, 'INGRESO_PROVEEDOR', @cant_verif, @stock_verif, @stock_verif + @cant_verif,
        'Verificación técnica Nodo 2: reposición de bodega', 'NODO_2_COCINA');
SET @id_mov_verif = LAST_INSERT_ID();

UPDATE productos_menu
SET stock_disponible = stock_disponible + @cant_verif
WHERE id_producto = @prod_verif;

-- 4.2. Comanda interna de Cocina (control de calidad) con su historial y detalle
INSERT INTO comandas (id_mesa, id_cliente, mozo, nodo_origen, estado, total)
VALUES (9, NULL, 'Sous Chef', 'NODO_2_COCINA', 'ABIERTA', 0.00);
SET @id_comanda_verif = LAST_INSERT_ID();

INSERT INTO historial_estados_comanda (id_comanda, estado_anterior, estado_nuevo, operador, nodo_emisor, observacion)
VALUES (@id_comanda_verif, NULL, 'ABIERTA', 'Sous Chef', 'NODO_2_COCINA', 'Verificación técnica Nodo 2: comanda interna');
SET @id_hist_verif = LAST_INSERT_ID();

INSERT INTO detalle_comanda (id_comanda, id_producto, cantidad, precio_unitario, estado_cocina, punto_coccion, observaciones)
VALUES (@id_comanda_verif, 2, 1, 8500.00, 'EN_COCCION', 'NO_APLICA', 'Prueba de punto de la provoleta');
SET @id_det_verif = LAST_INSERT_ID();

UPDATE comandas
SET total = (SELECT COALESCE(SUM(subtotal), 0) FROM detalle_comanda WHERE id_comanda = @id_comanda_verif)
WHERE id_comanda = @id_comanda_verif;

COMMIT;

-- 4.3. Las cuatro claves recién generadas en el Nodo 2 deben ser PARES (es_par = 1).
SELECT 'movimientos_stock' AS tabla, @id_mov_verif AS id_generado, MOD(@id_mov_verif, 2) = 0 AS es_par
UNION ALL SELECT 'comandas', @id_comanda_verif, MOD(@id_comanda_verif, 2) = 0
UNION ALL SELECT 'historial_estados_comanda', @id_hist_verif, MOD(@id_hist_verif, 2) = 0
UNION ALL SELECT 'detalle_comanda', @id_det_verif, MOD(@id_det_verif, 2) = 0;


-- ============================================================================
-- BLOQUE 5: EVIDENCIA GLOBAL DE LA FRAGMENTACIÓN DE CLAVES
-- ============================================================================

-- 5.1. Comandas abiertas en Cocina: todas con id_comanda PAR.
SELECT id_comanda, MOD(id_comanda, 2) = 0 AS es_par, id_mesa, mozo, nodo_origen, estado, total
FROM comandas
WHERE nodo_origen = 'NODO_2_COCINA'
ORDER BY id_comanda;

-- 5.2. Resumen por tabla y nodo de origen. Las filas creadas por el Nodo 2 tienen
-- ids_impares = 0 y las del Nodo 1 ids_pares = 0. Se excluye la semilla de stock
-- (ids 1 a 12), que se cargó con IDs explícitos y no por auto-incremento.
SELECT 'comandas' AS tabla, nodo_origen AS nodo,
       COUNT(*) AS filas, SUM(MOD(id_comanda, 2) = 0) AS ids_pares, SUM(MOD(id_comanda, 2) = 1) AS ids_impares
FROM comandas GROUP BY nodo_origen
UNION ALL
SELECT 'historial_estados_comanda', nodo_emisor,
       COUNT(*), SUM(MOD(id_historial, 2) = 0), SUM(MOD(id_historial, 2) = 1)
FROM historial_estados_comanda GROUP BY nodo_emisor
UNION ALL
SELECT 'movimientos_stock', nodo_origen,
       COUNT(*), SUM(MOD(id_movimiento, 2) = 0), SUM(MOD(id_movimiento, 2) = 1)
FROM movimientos_stock WHERE id_movimiento > 12 GROUP BY nodo_origen
ORDER BY tabla, nodo;

-- 5.3. Chequeo automático: 0 violaciones = ninguna fila del Nodo 2 tiene ID impar.
-- Nota: después de un failover de Cocina hacia el Nodo 1 (pruebas de la Fase 2) pueden
-- aparecer filas con nodo_origen = 'NODO_2_COCINA' e ID impar. Es lo esperado: esas filas
-- las generó físicamente el Nodo 1 mientras atendía a Cocina.
SELECT
    (SELECT COUNT(*) FROM comandas WHERE nodo_origen = 'NODO_2_COCINA' AND MOD(id_comanda, 2) = 1)
  + (SELECT COUNT(*) FROM historial_estados_comanda WHERE nodo_emisor = 'NODO_2_COCINA' AND MOD(id_historial, 2) = 1)
  + (SELECT COUNT(*) FROM movimientos_stock WHERE nodo_origen = 'NODO_2_COCINA' AND id_movimiento > 12 AND MOD(id_movimiento, 2) = 1)
    AS violaciones_ids_pares_nodo2;

-- 5.4. Kardex del producto usado en la prueba (ingreso recién registrado).
SELECT id_movimiento, tipo_movimiento, cantidad, stock_previo, stock_posterior, motivo, nodo_origen
FROM movimientos_stock
WHERE id_producto = @prod_verif
ORDER BY id_movimiento;
