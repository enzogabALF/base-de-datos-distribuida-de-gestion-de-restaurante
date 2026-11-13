-- ============================================================================
-- AE4 - TIFAS FASE 3: PROCEDIMIENTOS DEL ETL (EXTRACCIÓN, LIMPIEZA Y CARGA)
-- ----------------------------------------------------------------------------
-- Integra tres fuentes heterogéneas en el data warehouse:
--   1. Relacional estructurada: restaurante_db (comandas, detalle, pagos...).
--   2. Planilla semiestructurada: costos de proveedores exportados de Excel
--      (Windows-1252, separador ';', coma decimal, errores de carga manual).
--   3. Texto plano desestructurado: log del sistema de pantallas de cocina (KDS).
--
-- Cada procedimiento registra su ejecución en etl_control y las filas
-- descartadas, con su motivo, en etl_rechazos.
-- LOAD DATA no puede ejecutarse dentro de un procedimiento almacenado: la
-- lectura de los archivos a las tablas stg_ está en 08_etl_carga.sql.
-- ============================================================================

SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci;   -- la misma intercalación que las tablas
USE restaurante_dw;

-- ----------------------------------------------------------------------------
-- Vistas de validación: transforman el texto crudo en columnas tipadas y
-- calculan el motivo de rechazo (NULL = fila válida). Las conversiones solo se
-- aplican después de validar el formato con REGEXP: en modo estricto, un
-- CAST o STR_TO_DATE sobre un valor inválido haría fallar todo el INSERT.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW v_costos_validados AS
SELECT s.id_fila,
       CONCAT_WS(';', s.producto, s.mes, s.costo, s.proveedor) AS contenido,
       p.id_producto,
       IF(s.mes REGEXP '^[0-9]{2}/[0-9]{4}$',
          CONCAT(SUBSTRING(s.mes, 4, 4), '-', SUBSTRING(s.mes, 1, 2)), NULL) AS periodo,
       IF(TRIM(s.costo) REGEXP '^[0-9]{1,3}([.][0-9]{3})*,[0-9]{2}$',
          CAST(REPLACE(REPLACE(TRIM(s.costo), '.', ''), ',', '.') AS DECIMAL(10, 2)), NULL) AS costo_unitario,
       TRIM(s.proveedor) AS proveedor,
       CASE
           WHEN COALESCE(TRIM(s.producto), '') = '' THEN 'Línea vacía'
           WHEN NOT (s.mes REGEXP '^[0-9]{2}/[0-9]{4}$') THEN 'Mes con formato inválido'
           WHEN NOT (COALESCE(TRIM(s.costo), '') REGEXP '^[0-9]{1,3}([.][0-9]{3})*,[0-9]{2}$')
                THEN 'Costo vacío o con formato inválido'
           WHEN p.id_producto IS NULL THEN 'Producto que no está en el menú'
           WHEN ROW_NUMBER() OVER (PARTITION BY TRIM(s.producto), s.mes ORDER BY s.id_fila) > 1
                THEN 'Fila duplicada (mismo producto y mes)'
       END AS motivo_rechazo
FROM stg_costos_proveedor s
-- El nombre se compara sin espacios sobrantes y sin distinguir mayúsculas
-- (la intercalación utf8mb4_unicode_ci ya ignora mayúsculas y acentos)
LEFT JOIN dim_producto p ON p.nombre = TRIM(s.producto);

CREATE OR REPLACE VIEW v_kds_validado AS
SELECT x.*,
       CASE
           WHEN x.linea NOT LIKE '% [KDS] %' THEN 'Evento de sistema, no de cocina'
           WHEN x.momento IS NULL THEN 'Fecha y hora con formato inválido'
           WHEN x.estacion NOT IN ('PARRILLA', 'COCINA_CALIENTE', 'PASTELERIA', 'BARRA') THEN 'Estación desconocida'
           WHEN x.evento <> 'FIN_COCCION' THEN 'Evento de cocina no analizado'
           WHEN x.id_comanda IS NULL OR x.id_producto IS NULL OR x.cantidad IS NULL
                THEN 'Identificadores no numéricos'
           WHEN x.duracion_seg IS NULL THEN 'Duración inválida (reinicio del KDS)'
           WHEN NOT EXISTS (SELECT 1 FROM dim_producto p WHERE p.id_producto = x.id_producto)
                THEN 'Producto inexistente'
       END AS motivo_rechazo
FROM (
    SELECT id_linea,
           linea,
           IF(LEFT(linea, 19) REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$',
              STR_TO_DATE(LEFT(linea, 19), '%Y-%m-%d %H:%i:%s'), NULL) AS momento,
           SUBSTRING_INDEX(SUBSTRING_INDEX(linea, 'estacion=', -1), ' ', 1) AS estacion,
           SUBSTRING_INDEX(SUBSTRING_INDEX(linea, 'evento=', -1), ' ', 1) AS evento,
           IF(SUBSTRING_INDEX(SUBSTRING_INDEX(linea, 'comanda=', -1), ' ', 1) REGEXP '^[0-9]+$',
              CAST(SUBSTRING_INDEX(SUBSTRING_INDEX(linea, 'comanda=', -1), ' ', 1) AS UNSIGNED), NULL) AS id_comanda,
           IF(SUBSTRING_INDEX(SUBSTRING_INDEX(linea, 'producto=', -1), ' ', 1) REGEXP '^[0-9]+$',
              CAST(SUBSTRING_INDEX(SUBSTRING_INDEX(linea, 'producto=', -1), ' ', 1) AS UNSIGNED), NULL) AS id_producto,
           IF(SUBSTRING_INDEX(SUBSTRING_INDEX(linea, 'cantidad=', -1), ' ', 1) REGEXP '^[0-9]+$',
              CAST(SUBSTRING_INDEX(SUBSTRING_INDEX(linea, 'cantidad=', -1), ' ', 1) AS UNSIGNED), NULL) AS cantidad,
           IF(TRIM(SUBSTRING_INDEX(linea, 'duracion_seg=', -1)) REGEXP '^[0-9]+$',
              CAST(TRIM(SUBSTRING_INDEX(linea, 'duracion_seg=', -1)) AS UNSIGNED), NULL) AS duracion_seg
    FROM stg_log_kds
) x;

DELIMITER //

-- ----------------------------------------------------------------------------
-- Turno a partir de la hora
-- ----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS fn_turno //
CREATE FUNCTION fn_turno(p_hora INT) RETURNS TINYINT DETERMINISTIC NO SQL
BEGIN
    RETURN CASE WHEN p_hora BETWEEN 11 AND 16 THEN 1
                WHEN p_hora >= 19 THEN 2
                ELSE 3 END;
END //

-- ----------------------------------------------------------------------------
-- 1. Dimensiones desde la base operativa (inserta las nuevas y actualiza las
--    existentes: dimensiones de tipo 1, sin historia de cambios)
-- ----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS dw_cargar_dimensiones //
CREATE PROCEDURE dw_cargar_dimensiones()
BEGIN
    DECLARE v_id INT;
    INSERT INTO etl_control (proceso, inicio) VALUES ('dimensiones', SYSDATE(6));
    SET v_id = LAST_INSERT_ID();

    INSERT INTO dim_producto (id_producto, nombre, categoria, estacion, precio_lista)
    SELECT id_producto, nombre, categoria,
           CASE WHEN nombre REGEXP 'Bife|Provoleta' THEN 'PARRILLA'
                WHEN categoria IN ('PLATO_PRINCIPAL', 'ENTRADA') THEN 'COCINA_CALIENTE'
                WHEN categoria = 'POSTRE' THEN 'PASTELERIA'
                ELSE 'BARRA' END,
           precio
    FROM restaurante_db.productos_menu AS n
    ON DUPLICATE KEY UPDATE nombre = n.nombre, categoria = n.categoria, precio_lista = n.precio;

    INSERT INTO dim_mesa (id_mesa, numero_mesa, sector, capacidad)
    SELECT id_mesa, numero_mesa, sector, capacidad FROM restaurante_db.mesas AS n
    ON DUPLICATE KEY UPDATE numero_mesa = n.numero_mesa, sector = n.sector, capacidad = n.capacidad;

    INSERT INTO dim_cliente (id_cliente, nombre_completo, tipo)
    SELECT id_cliente, nombre_completo, 'FIDELIZADO' FROM restaurante_db.clientes AS n
    ON DUPLICATE KEY UPDATE nombre_completo = n.nombre_completo;

    INSERT IGNORE INTO dim_mozo (nombre)
    SELECT DISTINCT mozo FROM restaurante_db.comandas;

    UPDATE etl_control SET fin = SYSDATE(6) WHERE id_ejecucion = v_id;
END //

-- ----------------------------------------------------------------------------
-- 2. Costos de proveedores (planilla Excel ya cargada en stg_costos_proveedor)
-- ----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS dw_cargar_costos //
CREATE PROCEDURE dw_cargar_costos()
BEGIN
    DECLARE v_id INT;
    INSERT INTO etl_control (proceso, inicio) VALUES ('costos_proveedores', SYSDATE(6));
    SET v_id = LAST_INSERT_ID();

    INSERT INTO etl_rechazos (id_ejecucion, fuente, contenido, motivo)
    SELECT v_id, 'planilla_costos', contenido, motivo_rechazo
    FROM v_costos_validados WHERE motivo_rechazo IS NOT NULL;

    INSERT INTO costos_producto_mes (id_producto, periodo, costo_unitario, proveedor)
    SELECT id_producto, periodo, costo_unitario, proveedor
    FROM v_costos_validados AS v
    WHERE motivo_rechazo IS NULL
    ON DUPLICATE KEY UPDATE costo_unitario = v.costo_unitario, proveedor = v.proveedor;

    UPDATE etl_control
    SET fin = SYSDATE(6),
        filas_leidas = (SELECT COUNT(*) FROM stg_costos_proveedor),
        filas_cargadas = (SELECT COUNT(*) FROM v_costos_validados WHERE motivo_rechazo IS NULL),
        filas_rechazadas = (SELECT COUNT(*) FROM v_costos_validados WHERE motivo_rechazo IS NOT NULL)
    WHERE id_ejecucion = v_id;
END //

-- ----------------------------------------------------------------------------
-- 3. Hechos de ventas: carga INCREMENTAL desde la base operativa.
--    Marca de agua: la mayor fecha_cierre procesada. En cada ejecución solo se
--    leen las comandas cerradas desde la marca anterior (menos un día de
--    tolerancia para comandas que llegan tarde por replicación), y NOT EXISTS
--    evita duplicar las líneas que ya estaban: el proceso se puede repetir
--    sin efectos secundarios (idempotente).
--    Costo: el del mes de la venta; si la planilla no lo trae, el último
--    costo conocido anterior (LATERAL).
-- ----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS dw_cargar_hechos_ventas //
CREATE PROCEDURE dw_cargar_hechos_ventas()
BEGIN
    DECLARE v_id INT;
    DECLARE v_marca DATETIME;
    DECLARE v_nueva_marca DATETIME;

    SELECT COALESCE(MAX(marca_agua), '1900-01-01') INTO v_marca
    FROM etl_control WHERE proceso = 'hechos_ventas' AND fin IS NOT NULL;

    SELECT MAX(fecha_cierre) INTO v_nueva_marca
    FROM restaurante_db.comandas WHERE estado = 'PAGADA';

    INSERT INTO etl_control (proceso, inicio) VALUES ('hechos_ventas', SYSDATE(6));
    SET v_id = LAST_INSERT_ID();

    INSERT INTO hechos_ventas (id_detalle, fecha_key, hora, id_turno, id_producto, id_mesa, id_cliente,
                               id_mozo, id_medio_pago, id_comanda, cantidad, importe, costo_unitario, costo_total)
    SELECT d.id_detalle,
           CAST(DATE_FORMAT(c.fecha_apertura, '%Y%m%d') AS UNSIGNED),
           HOUR(c.fecha_apertura),
           fn_turno(HOUR(c.fecha_apertura)),
           d.id_producto,
           c.id_mesa,
           COALESCE(c.id_cliente, 0),
           mz.id_mozo,
           mp.id_medio_pago,
           c.id_comanda,
           d.cantidad,
           d.subtotal,
           cu.costo_unitario,
           ROUND(cu.costo_unitario * d.cantidad, 2)
    FROM restaurante_db.comandas c
    JOIN restaurante_db.detalle_comanda d ON d.id_comanda = c.id_comanda
    JOIN restaurante_db.pagos pg ON pg.id_comanda = c.id_comanda
    JOIN dim_mozo mz ON mz.nombre = c.mozo
    JOIN dim_medio_pago mp ON mp.metodo_pago = pg.metodo_pago
    LEFT JOIN LATERAL (
        SELECT cm.costo_unitario
        FROM costos_producto_mes cm
        WHERE cm.id_producto = d.id_producto
          AND cm.periodo <= DATE_FORMAT(c.fecha_apertura, '%Y-%m')
        ORDER BY cm.periodo DESC
        LIMIT 1
    ) cu ON TRUE
    WHERE c.estado = 'PAGADA'
      AND c.fecha_cierre > v_marca - INTERVAL 1 DAY
      AND NOT EXISTS (
          SELECT 1 FROM hechos_ventas h
          WHERE h.id_detalle = d.id_detalle
            AND h.fecha_key = CAST(DATE_FORMAT(c.fecha_apertura, '%Y%m%d') AS UNSIGNED)
      );
    SET @hv_cargadas = ROW_COUNT();

    UPDATE etl_control
    SET fin = SYSDATE(6), filas_cargadas = @hv_cargadas, filas_rechazadas = 0,
        marca_agua = COALESCE(v_nueva_marca, v_marca)
    WHERE id_ejecucion = v_id;
END //

-- ----------------------------------------------------------------------------
-- 4. Hechos de preparación desde el log del KDS (ya cargado en stg_log_kds)
-- ----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS dw_cargar_preparacion //
CREATE PROCEDURE dw_cargar_preparacion()
BEGIN
    DECLARE v_id INT;
    DECLARE v_cargadas INT;
    INSERT INTO etl_control (proceso, inicio) VALUES ('log_kds', SYSDATE(6));
    SET v_id = LAST_INSERT_ID();

    INSERT INTO etl_rechazos (id_ejecucion, fuente, contenido, motivo)
    SELECT v_id, 'log_kds', LEFT(linea, 500), motivo_rechazo
    FROM v_kds_validado WHERE motivo_rechazo IS NOT NULL;

    -- IGNORE: si el mismo archivo se procesa dos veces, la clave única
    -- (comanda, producto, momento, estación) descarta los eventos repetidos
    INSERT IGNORE INTO hechos_preparacion (estacion, momento, fecha_key, hora, id_turno,
                                           id_producto, id_comanda, cantidad, duracion_seg)
    SELECT estacion, momento,
           CAST(DATE_FORMAT(momento, '%Y%m%d') AS UNSIGNED),
           HOUR(momento),
           fn_turno(HOUR(momento)),
           id_producto, id_comanda, cantidad, duracion_seg
    FROM v_kds_validado
    WHERE motivo_rechazo IS NULL;
    SET v_cargadas = ROW_COUNT();

    UPDATE etl_control
    SET fin = SYSDATE(6),
        filas_leidas = (SELECT COUNT(*) FROM stg_log_kds),
        filas_cargadas = v_cargadas,
        filas_rechazadas = (SELECT COUNT(*) FROM etl_rechazos WHERE id_ejecucion = v_id),
        marca_agua = (SELECT MAX(momento) FROM v_kds_validado WHERE motivo_rechazo IS NULL)
    WHERE id_ejecucion = v_id;
END //

DELIMITER ;
