-- ============================================================================
-- AE4 - TIFAS FASE 3: SIMULACIÓN DEL LOG DEL SISTEMA DE PANTALLAS DE COCINA (KDS)
-- ----------------------------------------------------------------------------
-- Tercera fuente heterogénea del data warehouse: un archivo de texto plano, sin
-- estructura de tabla, como el que exporta el sistema de pantallas de cocina
-- (Kitchen Display System) instalado en agosto de 2026. Cada vez que una
-- estación termina un plato, el KDS escribe una línea:
--
--   2026-09-14 21:19:33 [KDS] estacion=PARRILLA comanda=1000123 producto=3 cantidad=2 evento=FIN_COCCION duracion_seg=1104
--
-- Mezcladas con esas líneas aparecen las de otros eventos del sistema
-- ([SYS] impresora sin papel) y algunas corruptas (duracion_seg=ERR tras un
-- reinicio de la pantalla). El ETL tiene que separar, validar y descartar.
--
-- Este script genera el archivo a partir de las comandas reales de agosto a
-- octubre de 2026, con tiempos deterministas (CRC32) que siguen patrones que
-- el análisis debe descubrir:
--   * base por estación: parrilla 14 min, cocina 10 min, pastelería 4 min, barra 75 s
--   * pico de la cena (21 y 22 h): +40 %; pico del almuerzo (13 h): +15 %
--   * viernes y sábados: +10 %
--   * punto de cocción: cocido +25 %, jugoso -15 %
--   * +8 % por cada unidad adicional del mismo plato, y ±20 % de variación
--
-- Se ejecuta en el Nodo 1 y escribe /var/lib/mysql-files/kds_eventos.log
-- (carpeta autorizada por secure_file_priv). El archivo no debe existir.
-- ============================================================================

SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci;   -- la misma intercalación que las tablas
USE restaurante_db;

SELECT linea
FROM (
    -- Eventos de cocina (las líneas corruptas reemplazan al evento real)
    SELECT momento,
           CONCAT(DATE_FORMAT(momento, '%Y-%m-%d %H:%i:%s'),
                  ' [KDS] estacion=', estacion,
                  ' comanda=', id_comanda,
                  ' producto=', id_producto,
                  ' cantidad=', cantidad,
                  ' evento=FIN_COCCION duracion_seg=',
                  IF(h % 400 = 1, 'ERR', duracion)) AS linea
    FROM (
        SELECT x.*,
               x.marcha + INTERVAL x.duracion SECOND AS momento
        FROM (
            SELECT d.id_comanda, d.id_producto, d.cantidad,
                   CRC32(CONCAT(d.id_detalle, '|kds')) AS h,
                   CASE WHEN p.nombre REGEXP 'Bife|Provoleta' THEN 'PARRILLA'
                        WHEN p.categoria IN ('PLATO_PRINCIPAL', 'ENTRADA') THEN 'COCINA_CALIENTE'
                        WHEN p.categoria = 'POSTRE' THEN 'PASTELERIA'
                        ELSE 'BARRA' END AS estacion,
                   c.fecha_apertura + INTERVAL (2 + CRC32(CONCAT(c.id_comanda, '|cocina')) % 8) MINUTE AS marcha,
                   ROUND(
                       CASE WHEN p.nombre REGEXP 'Bife|Provoleta' THEN 840
                            WHEN p.categoria IN ('PLATO_PRINCIPAL', 'ENTRADA') THEN 600
                            WHEN p.categoria = 'POSTRE' THEN 240
                            ELSE 75 END
                     * CASE WHEN HOUR(c.fecha_apertura) IN (21, 22) THEN 1.40
                            WHEN HOUR(c.fecha_apertura) = 13 THEN 1.15
                            ELSE 1.00 END
                     * IF(WEEKDAY(c.fecha_apertura) IN (4, 5), 1.10, 1.00)
                     * CASE d.punto_coccion WHEN 'COCIDO' THEN 1.25 WHEN 'JUGOSO' THEN 0.85 ELSE 1.00 END
                     * (1 + 0.08 * (d.cantidad - 1))
                     * (0.80 + (CRC32(CONCAT(d.id_detalle, '|dur')) % 41) / 100)
                   ) AS duracion
            FROM comandas c
            JOIN detalle_comanda d ON d.id_comanda = c.id_comanda
            JOIN productos_menu p ON p.id_producto = d.id_producto
            WHERE c.estado = 'PAGADA'
              AND c.fecha_apertura >= '2026-08-01' AND c.fecha_apertura < '2026-11-01'
        ) x
    ) eventos

    UNION ALL

    -- Eventos del sistema que no son de cocina (el ETL los descarta)
    SELECT c.fecha_apertura + INTERVAL 30 SECOND,
           CONCAT(DATE_FORMAT(c.fecha_apertura + INTERVAL 30 SECOND, '%Y-%m-%d %H:%i:%s'),
                  ' [SYS] impresora=IMP-0', 1 + CRC32(CONCAT(c.id_comanda, '|imp')) % 3,
                  ' estado=SIN_PAPEL')
    FROM comandas c
    WHERE c.estado = 'PAGADA'
      AND c.fecha_apertura >= '2026-08-01' AND c.fecha_apertura < '2026-11-01'
      AND CRC32(CONCAT(c.id_comanda, '|sys')) % 150 = 0
) log_completo
ORDER BY momento, linea
INTO OUTFILE '/var/lib/mysql-files/kds_eventos.log'
    FIELDS TERMINATED BY '\t' ESCAPED BY ''   -- una sola columna: el separador no se escribe
    LINES TERMINATED BY '\n';
