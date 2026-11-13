-- ============================================================================
-- AE4 - TIFAS FASE 3: DEMOSTRACIÓN DE LA OPTIMIZACIÓN FÍSICA DEL DATA WAREHOUSE
-- ----------------------------------------------------------------------------
-- A. Vista materializada frente a la consulta sobre las tablas base.
-- B. Frescura: un cambio en la base operativa llega a la vista en el
--    siguiente refresco, y el EVENT lo ejecuta solo.
-- C. Particionamiento por rango: poda de particiones (partition pruning).
-- D. Particionamiento por lista: cada estación de cocina lee su partición.
-- E. Retención: DROP PARTITION frente a DELETE.
--
-- Las comparaciones contra tablas sin particionar usan copias locales con
-- sql_log_bin = 0 en un esquema aparte (fase3_bench) que se borra al final:
-- no se replican y no alteran el data warehouse.
-- ============================================================================

SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci;   -- la misma intercalación que las tablas
USE restaurante_dw;

-- ============================================================================
-- A. "Ventas de 2026 por mes, categoría y sector" de tres maneras
-- ============================================================================

SELECT 'A1. Desde la base operativa (4 tablas, 120.000 comandas)' AS consulta;
EXPLAIN ANALYZE
SELECT DATE_FORMAT(c.fecha_apertura, '%Y-%m') AS periodo, p.categoria, m.sector,
       SUM(d.subtotal) AS importe
FROM restaurante_db.comandas c
JOIN restaurante_db.detalle_comanda d ON d.id_comanda = c.id_comanda
JOIN restaurante_db.productos_menu p ON p.id_producto = d.id_producto
JOIN restaurante_db.mesas m ON m.id_mesa = c.id_mesa
WHERE c.estado = 'PAGADA' AND c.fecha_apertura >= '2026-01-01' AND c.fecha_apertura < '2027-01-01'
GROUP BY periodo, p.categoria, m.sector;

SELECT 'A2. Desde el esquema en estrella (hechos particionados + dimensiones)' AS consulta;
EXPLAIN ANALYZE
SELECT t.periodo, pr.categoria, me.sector, SUM(h.importe) AS importe
FROM hechos_ventas h
JOIN dim_tiempo t ON t.fecha_key = h.fecha_key
JOIN dim_producto pr ON pr.id_producto = h.id_producto
JOIN dim_mesa me ON me.id_mesa = h.id_mesa
WHERE h.fecha_key BETWEEN 20260101 AND 20261231
GROUP BY t.periodo, pr.categoria, me.sector;

SELECT 'A3. Desde la vista materializada' AS consulta;
EXPLAIN ANALYZE
SELECT periodo, categoria, sector, SUM(importe) AS importe
FROM mv_ventas_mensuales
WHERE periodo BETWEEN '2026-01' AND '2026-12'
GROUP BY periodo, categoria, sector;

-- Las tres devuelven lo mismo: total de 2026 por cada camino
SELECT
  (SELECT SUM(d.subtotal) FROM restaurante_db.comandas c
     JOIN restaurante_db.detalle_comanda d ON d.id_comanda = c.id_comanda
    WHERE c.estado = 'PAGADA' AND c.fecha_apertura >= '2026-01-01' AND c.fecha_apertura < '2027-01-01') AS total_base_operativa,
  (SELECT SUM(importe) FROM hechos_ventas WHERE fecha_key BETWEEN 20260101 AND 20261231) AS total_estrella,
  (SELECT SUM(importe) FROM mv_ventas_mensuales WHERE periodo BETWEEN '2026-01' AND '2026-12') AS total_vista_materializada;

-- ============================================================================
-- B. Frescura y refresco periódico
-- ============================================================================

SELECT 'B1. Se cobra una comanda nueva en el Salón (base operativa)' AS paso;
START TRANSACTION;
INSERT INTO restaurante_db.comandas (id_mesa, id_cliente, mozo, nodo_origen, estado, total, fecha_apertura)
VALUES (7, NULL, 'Sofía Benítez', 'NODO_1_SALON', 'ABIERTA', 0, NOW() - INTERVAL 50 MINUTE);
SET @c = LAST_INSERT_ID();
INSERT INTO restaurante_db.detalle_comanda (id_comanda, id_producto, cantidad, precio_unitario, estado_cocina)
VALUES (@c, 4, 2, 24000.00, 'ENTREGADO'), (@c, 12, 1, 18900.00, 'ENTREGADO');
UPDATE restaurante_db.comandas
SET total = 66900.00, estado = 'PAGADA', fecha_cierre = NOW()
WHERE id_comanda = @c;
INSERT INTO restaurante_db.pagos (id_comanda, metodo_pago, monto_total, nodo_caja)
VALUES (@c, 'TRANSFERENCIA_QR', 66900.00, 'NODO_1_SALON');
COMMIT;

SET @periodo_actual = DATE_FORMAT(NOW(), '%Y-%m');
SET @vista_antes = (SELECT COALESCE(SUM(importe), 0) FROM mv_ventas_mensuales WHERE periodo = @periodo_actual);
SELECT @c AS comanda_nueva, @periodo_actual AS periodo, @vista_antes AS importe_en_la_vista,
       'la vista todavía no incluye la comanda nueva' AS estado;

SELECT 'B2. Refresco manual: ETL incremental + refresco incremental de la vista' AS paso;
CALL dw_ciclo_actualizacion('MANUAL');
SET @vista_despues = (SELECT COALESCE(SUM(importe), 0) FROM mv_ventas_mensuales WHERE periodo = @periodo_actual);
SELECT @vista_despues AS importe_en_la_vista,
       @vista_despues - @vista_antes AS diferencia,
       IF(@vista_despues - @vista_antes = 66900, 'la vista incluye la comanda de $66.900', 'REVISAR') AS estado;

SELECT 'B3. El EVENT refresca solo: se acelera a cada 5 s, se esperan 12 s y se restaura' AS paso;
SET @refrescos_antes = (SELECT COUNT(*) FROM mv_control WHERE origen = 'EVENTO');
ALTER EVENT ev_dw_actualizacion ON SCHEDULE EVERY 5 SECOND STARTS CURRENT_TIMESTAMP;
DO SLEEP(12);
ALTER EVENT ev_dw_actualizacion ON SCHEDULE EVERY 15 MINUTE STARTS CURRENT_TIMESTAMP + INTERVAL 15 MINUTE;
SELECT (SELECT COUNT(*) FROM mv_control WHERE origen = 'EVENTO') - @refrescos_antes AS refrescos_hechos_por_el_evento;

SELECT modo, origen, periodos AS meses_recalculados, filas,
       ROUND(TIMESTAMPDIFF(MICROSECOND, inicio, fin) / 1e6, 2) AS segundos
FROM mv_control ORDER BY id_refresco;

-- ============================================================================
-- C. Particionamiento por RANGO: poda de particiones
-- ============================================================================

SELECT 'C1. Un mes: EXPLAIN muestra que solo se lee la partición p2026_09' AS consulta;
EXPLAIN
SELECT id_producto, SUM(cantidad) AS unidades, SUM(importe) AS importe
FROM hechos_ventas
WHERE fecha_key BETWEEN 20260901 AND 20260930
GROUP BY id_producto;

-- Copia SIN particionar, con la misma clave primaria y sin índice por fecha
SET SESSION sql_log_bin = 0;
DROP DATABASE IF EXISTS fase3_bench;
CREATE DATABASE fase3_bench;
CREATE TABLE fase3_bench.hv_sin_particionar LIKE restaurante_dw.hechos_ventas;
ALTER TABLE fase3_bench.hv_sin_particionar REMOVE PARTITIONING;
INSERT INTO fase3_bench.hv_sin_particionar SELECT * FROM restaurante_dw.hechos_ventas;
CREATE TABLE fase3_bench.hv_particionada LIKE restaurante_dw.hechos_ventas;
INSERT INTO fase3_bench.hv_particionada SELECT * FROM restaurante_dw.hechos_ventas;
ANALYZE TABLE fase3_bench.hv_sin_particionar, fase3_bench.hv_particionada;

SELECT 'C2. Ventas de septiembre 2026 por producto: tabla particionada' AS consulta;
EXPLAIN ANALYZE
SELECT id_producto, SUM(cantidad) AS unidades, SUM(importe) AS importe
FROM fase3_bench.hv_particionada
WHERE fecha_key BETWEEN 20260901 AND 20260930
GROUP BY id_producto;

SELECT 'C3. La misma consulta sobre la tabla SIN particionar' AS consulta;
EXPLAIN ANALYZE
SELECT id_producto, SUM(cantidad) AS unidades, SUM(importe) AS importe
FROM fase3_bench.hv_sin_particionar
WHERE fecha_key BETWEEN 20260901 AND 20260930
GROUP BY id_producto;

-- ============================================================================
-- D. Particionamiento por LISTA: pantalla de la estación de parrilla
-- ============================================================================
SELECT 'D1. Tiempos de la parrilla: solo se lee la partición p_parrilla' AS consulta;
EXPLAIN
SELECT hora, ROUND(AVG(duracion_seg) / 60, 1) AS minutos_promedio
FROM restaurante_dw.hechos_preparacion
WHERE estacion = 'PARRILLA'
GROUP BY hora;

SELECT PARTITION_NAME AS particion, PARTITION_DESCRIPTION AS valores, TABLE_ROWS AS filas_aprox
FROM information_schema.PARTITIONS
WHERE TABLE_SCHEMA = 'restaurante_dw' AND TABLE_NAME = 'hechos_preparacion'
ORDER BY PARTITION_ORDINAL_POSITION;

-- ============================================================================
-- E. Retención: borrar el primer semestre de 2025
-- ============================================================================
SELECT 'E1. DELETE fila por fila en la tabla sin particionar' AS operacion;
SET @t0 = SYSDATE(6);
DELETE FROM fase3_bench.hv_sin_particionar WHERE fecha_key < 20250701;
SET @filas = ROW_COUNT();
SELECT @filas AS filas_borradas, ROUND(TIMESTAMPDIFF(MICROSECOND, @t0, SYSDATE(6)) / 1e3, 1) AS milisegundos;

SELECT 'E2. DROP PARTITION de los 6 meses en la tabla particionada' AS operacion;
SET @t0 = SYSDATE(6);
ALTER TABLE fase3_bench.hv_particionada
    DROP PARTITION p2025_01, p2025_02, p2025_03, p2025_04, p2025_05, p2025_06;
SELECT ROUND(TIMESTAMPDIFF(MICROSECOND, @t0, SYSDATE(6)) / 1e3, 1) AS milisegundos;

SELECT (SELECT COUNT(*) FROM fase3_bench.hv_sin_particionar) AS filas_restantes_sin_particionar,
       (SELECT COUNT(*) FROM fase3_bench.hv_particionada) AS filas_restantes_particionada;

DROP DATABASE fase3_bench;
SET SESSION sql_log_bin = 1;
