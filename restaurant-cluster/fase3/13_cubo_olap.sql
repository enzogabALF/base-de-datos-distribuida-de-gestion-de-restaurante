-- ============================================================================
-- AE4 - TIFAS FASE 3: CONSULTAS OLAP SOBRE EL ESQUEMA EN ESTRELLA
-- ----------------------------------------------------------------------------
-- Operaciones típicas de un cubo sobre las dimensiones del data warehouse:
--   * roll-up    : subir de nivel en una jerarquía (mes -> trimestre -> año)
--   * drill-down : bajar de nivel (año -> trimestre -> mes)
--   * slice/dice : fijar una o varias dimensiones (año 2026, turno CENA)
--   * pivot      : rotar una dimensión a columnas (medio de pago)
-- MySQL implementa los subtotales jerárquicos con GROUP BY ... WITH ROLLUP y la
-- función GROUPING(), que indica si una fila es un subtotal.
-- ============================================================================

SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci;   -- la misma intercalación que las tablas
USE restaurante_dw;

-- ----------------------------------------------------------------------------
-- 1. Roll-up: año -> trimestre -> categoría, con subtotales y total general
-- ----------------------------------------------------------------------------
SELECT IF(GROUPING(t.anio), 'TOTAL GENERAL', t.anio) AS anio,
       IF(GROUPING(t.trimestre), IF(GROUPING(t.anio), '', 'Total del año'), CONCAT('T', t.trimestre)) AS trimestre,
       IF(GROUPING(pr.categoria), IF(GROUPING(t.trimestre), '', 'Total del trimestre'), pr.categoria) AS categoria,
       FORMAT(SUM(h.importe), 0, 'es_AR') AS importe,
       CONCAT(ROUND(SUM(h.importe - h.costo_total) * 100 / SUM(h.importe), 1), ' %') AS margen
FROM hechos_ventas h
JOIN dim_tiempo t ON t.fecha_key = h.fecha_key
JOIN dim_producto pr ON pr.id_producto = h.id_producto
WHERE t.fecha < '2026-11-01'
GROUP BY t.anio, t.trimestre, pr.categoria WITH ROLLUP;

-- ----------------------------------------------------------------------------
-- 2. Slice + dice + pivot: 2026, por sector y turno, medios de pago en columnas
-- ----------------------------------------------------------------------------
SELECT IF(GROUPING(me.sector), 'TOTAL', me.sector) AS sector,
       IF(GROUPING(tu.turno), IF(GROUPING(me.sector), '', 'Total sector'), tu.turno) AS turno,
       FORMAT(SUM(IF(mp.metodo_pago = 'EFECTIVO', h.importe, 0)), 0, 'es_AR') AS efectivo,
       FORMAT(SUM(IF(mp.metodo_pago = 'TARJETA_DEBITO', h.importe, 0)), 0, 'es_AR') AS debito,
       FORMAT(SUM(IF(mp.metodo_pago = 'TARJETA_CREDITO', h.importe, 0)), 0, 'es_AR') AS credito,
       FORMAT(SUM(IF(mp.metodo_pago = 'TRANSFERENCIA_QR', h.importe, 0)), 0, 'es_AR') AS qr,
       FORMAT(SUM(h.importe), 0, 'es_AR') AS total
FROM hechos_ventas h
JOIN dim_tiempo t ON t.fecha_key = h.fecha_key
JOIN dim_mesa me ON me.id_mesa = h.id_mesa
JOIN dim_turno tu ON tu.id_turno = h.id_turno
JOIN dim_medio_pago mp ON mp.id_medio_pago = h.id_medio_pago
WHERE t.anio = 2026 AND t.fecha < '2026-11-01'
GROUP BY me.sector, tu.turno WITH ROLLUP;

-- ----------------------------------------------------------------------------
-- 3. Drill-down del mejor trimestre de 2026 a sus meses, con variación
--    interanual (mismo mes de 2025) calculada con funciones de ventana
-- ----------------------------------------------------------------------------
SELECT periodo,
       FORMAT(importe, 0, 'es_AR') AS importe,
       FORMAT(importe_anio_anterior, 0, 'es_AR') AS mismo_mes_2025,
       CONCAT(ROUND((importe / importe_anio_anterior - 1) * 100, 1), ' %') AS variacion_interanual
FROM (
    SELECT t.periodo, t.anio, t.mes,
           SUM(h.importe) AS importe,
           LAG(SUM(h.importe), 12) OVER (ORDER BY t.anio, t.mes) AS importe_anio_anterior
    FROM hechos_ventas h
    JOIN dim_tiempo t ON t.fecha_key = h.fecha_key
    WHERE t.fecha < '2026-11-01'
    GROUP BY t.periodo, t.anio, t.mes
) m
WHERE anio = 2026
ORDER BY periodo;
