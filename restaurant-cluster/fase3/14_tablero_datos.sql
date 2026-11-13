-- ============================================================================
-- AE4 - TIFAS FASE 3: DATOS DEL TABLERO DIMENSIONAL
-- ----------------------------------------------------------------------------
-- Devuelve un único documento JSON con todos los indicadores del tablero.
-- pruebas_fase3/generar_tablero.sh lo inserta en fase3/tablero/plantilla.html
-- y produce fase3/tablero/tablero.html, que se abre con cualquier navegador
-- sin servidor ni conexión a internet.
--
-- Las consultas leen la vista materializada y el esquema en estrella, nunca
-- la base operativa: el tablero no compite con la toma de comandas.
-- Período analizado: enero a octubre de 2026 contra el mismo período de 2025.
-- ============================================================================

SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci;   -- la misma intercalación que las tablas
USE restaurante_dw;
SET SESSION group_concat_max_len = 1000000;

SELECT JSON_OBJECT(
  'generado_en', DATE_FORMAT(NOW(), '%d/%m/%Y %H:%i'),
  'nodo', @@hostname,

  'kpi', (
    SELECT JSON_OBJECT(
      'facturacion', SUM(IF(periodo BETWEEN '2026-01' AND '2026-10', importe, 0)),
      'facturacion_anterior', SUM(IF(periodo BETWEEN '2025-01' AND '2025-10', importe, 0)),
      'margen', SUM(IF(periodo BETWEEN '2026-01' AND '2026-10', margen, 0)),
      'unidades', SUM(IF(periodo BETWEEN '2026-01' AND '2026-10', unidades, 0)))
    FROM mv_ventas_mensuales),

  'tickets', (
    SELECT JSON_OBJECT(
      'actual', COUNT(DISTINCT IF(fecha_key BETWEEN 20260101 AND 20261031, id_comanda, NULL)),
      'anterior', COUNT(DISTINCT IF(fecha_key BETWEEN 20250101 AND 20251031, id_comanda, NULL)))
    FROM hechos_ventas),

  'mensual', (
    SELECT JSON_ARRAYAGG(JSON_OBJECT('periodo', periodo, 'importe', importe, 'margen', margen))
    FROM (SELECT periodo, SUM(importe) AS importe, SUM(margen) AS margen
          FROM mv_ventas_mensuales WHERE periodo <= '2026-10' GROUP BY periodo) m),

  'categorias', (
    SELECT JSON_ARRAYAGG(JSON_OBJECT('nombre', categoria, 'importe', importe, 'margen', margen))
    FROM (SELECT categoria, SUM(importe) AS importe, SUM(margen) AS margen
          FROM mv_ventas_mensuales WHERE periodo BETWEEN '2026-01' AND '2026-10' GROUP BY categoria) c),

  'sectores', (
    SELECT JSON_ARRAYAGG(JSON_OBJECT('sector', sector, 'turno', turno, 'importe', importe))
    FROM (SELECT sector, turno, SUM(importe) AS importe
          FROM mv_ventas_mensuales WHERE periodo BETWEEN '2026-01' AND '2026-10' GROUP BY sector, turno) s),

  'productos', (
    SELECT JSON_ARRAYAGG(JSON_OBJECT('nombre', nombre, 'unidades', unidades, 'importe', importe))
    FROM (SELECT p.nombre, SUM(h.cantidad) AS unidades, SUM(h.importe) AS importe
          FROM hechos_ventas h JOIN dim_producto p ON p.id_producto = h.id_producto
          WHERE h.fecha_key BETWEEN 20260101 AND 20261031
          GROUP BY p.nombre) pr),

  'medios_pago', (
    SELECT JSON_ARRAYAGG(JSON_OBJECT('metodo', metodo_pago, 'importe', importe))
    FROM (SELECT mp.metodo_pago, SUM(h.importe) AS importe
          FROM hechos_ventas h JOIN dim_medio_pago mp ON mp.id_medio_pago = h.id_medio_pago
          WHERE h.fecha_key BETWEEN 20260101 AND 20261031
          GROUP BY mp.metodo_pago) m),

  'mapa_calor', (
    SELECT JSON_ARRAYAGG(JSON_OBJECT('dia', dia_semana, 'hora', hora, 'tickets', tickets))
    FROM (SELECT t.dia_semana, h.hora, COUNT(DISTINCT h.id_comanda) AS tickets
          FROM hechos_ventas h JOIN dim_tiempo t ON t.fecha_key = h.fecha_key
          WHERE h.fecha_key BETWEEN 20260101 AND 20261031
          GROUP BY t.dia_semana, h.hora) mc),

  'preparacion', (
    SELECT JSON_ARRAYAGG(JSON_OBJECT('estacion', estacion, 'hora', hora, 'minutos', minutos))
    FROM (SELECT estacion, hora, ROUND(AVG(duracion_seg) / 60, 1) AS minutos
          FROM hechos_preparacion GROUP BY estacion, hora) pp),

  'reglas', (
    SELECT JSON_ARRAYAGG(JSON_OBJECT('a', antecedente, 'b', consecuente, 'soporte', soporte,
                                     'confianza', confianza, 'lift', lift))
    FROM (SELECT * FROM kdd_reglas_asociacion WHERE lift > 1 AND id_antecedente < id_consecuente
          ORDER BY lift DESC LIMIT 8) r),

  'segmentos', (
    SELECT JSON_ARRAYAGG(JSON_OBJECT('segmento', segmento, 'clientes', clientes,
                                     'monto', monto, 'recencia', recencia, 'frecuencia', frecuencia))
    FROM (SELECT segmento, COUNT(*) AS clientes, SUM(monto) AS monto,
                 ROUND(AVG(recencia_dias)) AS recencia, ROUND(AVG(frecuencia), 1) AS frecuencia
          FROM kdd_segmentos_rfm GROUP BY segmento) sg),

  'refrescos', (
    SELECT JSON_OBJECT('ultimo', DATE_FORMAT(MAX(fin), '%d/%m/%Y %H:%i:%s'), 'cantidad', COUNT(*))
    FROM mv_control WHERE fin IS NOT NULL),

  'volumen', (
    SELECT JSON_OBJECT('hechos_ventas', (SELECT COUNT(*) FROM hechos_ventas),
                       'hechos_preparacion', (SELECT COUNT(*) FROM hechos_preparacion),
                       'particiones', (SELECT COUNT(*) FROM information_schema.PARTITIONS
                                       WHERE TABLE_SCHEMA = 'restaurante_dw' AND TABLE_NAME = 'hechos_ventas')))
) AS tablero;
