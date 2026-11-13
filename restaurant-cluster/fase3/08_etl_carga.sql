-- ============================================================================
-- AE4 - TIFAS FASE 3: EJECUCIÓN DEL ETL (CARGA INICIAL DEL DATA WAREHOUSE)
-- ----------------------------------------------------------------------------
-- Requisitos (los resuelve pruebas_fase3/ejecutar_fase3.sh):
--   * /var/lib/mysql-files/planilla_costos_proveedores.csv (copiada con docker cp)
--   * /var/lib/mysql-files/kds_eventos.log (generada por 06_generar_log_kds.sql)
-- /var/lib/mysql-files es la carpeta habilitada por secure_file_priv: MySQL no
-- lee ni escribe archivos fuera de ella.
-- ============================================================================

SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci;   -- la misma intercalación que las tablas
USE restaurante_dw;

-- 1. Dimensiones desde la base relacional
CALL dw_cargar_dimensiones();

-- 2. Planilla de costos (Excel exportado: Windows-1252, ';', fin de línea CRLF).
--    IGNORE convierte en advertencias los errores de filas incompletas (la línea
--    vacía del archivo): la validación y el rechazo se hacen después, en SQL.
TRUNCATE TABLE stg_costos_proveedor;
LOAD DATA INFILE '/var/lib/mysql-files/planilla_costos_proveedores.csv'
    IGNORE INTO TABLE stg_costos_proveedor
    CHARACTER SET latin1
    FIELDS TERMINATED BY ';'
    LINES TERMINATED BY '\r\n'
    IGNORE 1 LINES
    (producto, mes, costo, proveedor);
CALL dw_cargar_costos();

-- 3. Log de texto del KDS: una línea completa por fila, sin interpretar
TRUNCATE TABLE stg_log_kds;
LOAD DATA INFILE '/var/lib/mysql-files/kds_eventos.log'
    INTO TABLE stg_log_kds
    CHARACTER SET utf8mb4
    FIELDS TERMINATED BY '\t' ESCAPED BY ''
    LINES TERMINATED BY '\n'
    (linea);
CALL dw_cargar_preparacion();

-- 4. Hechos de ventas desde la base relacional (incremental)
CALL dw_cargar_hechos_ventas();

-- ----------------------------------------------------------------------------
-- Resumen
-- ----------------------------------------------------------------------------
SELECT proceso,
       filas_leidas,
       filas_cargadas,
       filas_rechazadas,
       ROUND(TIMESTAMPDIFF(MICROSECOND, inicio, fin) / 1e6, 2) AS segundos,
       marca_agua
FROM etl_control
ORDER BY id_ejecucion;

SELECT fuente, motivo, COUNT(*) AS filas, MIN(contenido) AS ejemplo
FROM etl_rechazos
GROUP BY fuente, motivo
ORDER BY fuente, filas DESC;

-- Las filas con errores de formato quedaron limpias y asociadas al producto
SELECT p.nombre, c.periodo, c.costo_unitario, c.proveedor
FROM costos_producto_mes c JOIN dim_producto p ON p.id_producto = c.id_producto
WHERE (c.id_producto = 3 AND c.periodo = '2025-06') OR (c.id_producto = 12 AND c.periodo = '2025-10');

SELECT 'hechos_ventas' AS tabla, COUNT(*) AS filas, SUM(costo_total IS NULL) AS sin_costo FROM hechos_ventas
UNION ALL
SELECT 'hechos_preparacion', COUNT(*), NULL FROM hechos_preparacion;
