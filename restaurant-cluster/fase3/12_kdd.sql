-- ============================================================================
-- AE4 - TIFAS FASE 3: DESCUBRIMIENTO DE CONOCIMIENTO (KDD) SOBRE EL DATA WAREHOUSE
-- ----------------------------------------------------------------------------
-- Proceso KDD (Fayyad, Piatetsky-Shapiro y Smyth, 1996):
--   1. Selección     -> hechos_ventas y hechos_preparacion del data warehouse
--   2. Preprocesamiento -> el ETL limpió la planilla y el log (etl_rechazos)
--   3. Transformación -> canasta por ticket, métricas RFM por cliente
--   4. Minería       -> reglas de asociación (Apriori) y segmentación RFM
--   5. Interpretación -> reglas ordenadas por lift, segmentos con su acción
--
-- Todo se implementa en SQL dentro del motor, sin exportar los datos.
-- ============================================================================

SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci;   -- la misma intercalación que las tablas
USE restaurante_dw;

-- ----------------------------------------------------------------------------
-- Tablas de resultados
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS kdd_reglas_asociacion (
    id_antecedente   INT NOT NULL,
    id_consecuente   INT NOT NULL,
    antecedente      VARCHAR(100) NOT NULL,
    consecuente      VARCHAR(100) NOT NULL,
    tickets_ab       INT NOT NULL,
    soporte          DECIMAL(7, 4) NOT NULL,   -- P(A y B)
    confianza        DECIMAL(7, 4) NOT NULL,   -- P(B | A)
    lift             DECIMAL(8, 3) NOT NULL,   -- confianza / P(B); > 1 = asociación positiva
    calculado_en     DATETIME NOT NULL,
    PRIMARY KEY (id_antecedente, id_consecuente)
) ENGINE = InnoDB;

CREATE TABLE IF NOT EXISTS kdd_segmentos_rfm (
    id_cliente     INT PRIMARY KEY,
    recencia_dias  INT NOT NULL,
    frecuencia     INT NOT NULL,
    monto          DECIMAL(14, 2) NOT NULL,
    r              TINYINT NOT NULL,
    f              TINYINT NOT NULL,
    m              TINYINT NOT NULL,
    segmento       VARCHAR(30) NOT NULL,
    fecha_corte    DATE NOT NULL,
    INDEX idx_rfm_segmento (segmento)
) ENGINE = InnoDB;

DELIMITER //

-- ----------------------------------------------------------------------------
-- 1. Reglas de asociación A -> B ("quien pide A, también pide B")
--    Apriori con conjuntos de hasta 2 productos:
--      a) cuenta los tickets y el soporte de cada producto;
--      b) descarta los productos con soporte menor al mínimo (propiedad
--         Apriori: si A no es frecuente, ningún par que lo contenga lo es);
--      c) cuenta los pares de productos frecuentes que aparecen en el mismo
--         ticket (autounión por id_comanda, que usa el índice
--         idx_hv_comanda_producto);
--      d) conserva las reglas que superan soporte y confianza mínimos.
-- ----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS kdd_calcular_reglas //
CREATE PROCEDURE kdd_calcular_reglas(IN p_soporte_min DECIMAL(7, 4), IN p_confianza_min DECIMAL(7, 4))
BEGIN
    DECLARE v_tickets INT;
    SELECT COUNT(DISTINCT id_comanda) INTO v_tickets FROM hechos_ventas;

    DROP TEMPORARY TABLE IF EXISTS tmp_item_frecuente;
    CREATE TEMPORARY TABLE tmp_item_frecuente (id_producto INT PRIMARY KEY, tickets INT NOT NULL);
    INSERT INTO tmp_item_frecuente
    SELECT id_producto, COUNT(DISTINCT id_comanda)
    FROM hechos_ventas
    GROUP BY id_producto
    HAVING COUNT(DISTINCT id_comanda) / v_tickets >= p_soporte_min;

    -- MySQL no permite usar una tabla temporal dos veces en la misma consulta
    -- ("Can't reopen table"): se usa una copia para el lado del consecuente.
    DROP TEMPORARY TABLE IF EXISTS tmp_item_frecuente_b;
    CREATE TEMPORARY TABLE tmp_item_frecuente_b LIKE tmp_item_frecuente;
    INSERT INTO tmp_item_frecuente_b SELECT * FROM tmp_item_frecuente;

    DROP TEMPORARY TABLE IF EXISTS tmp_par;
    CREATE TEMPORARY TABLE tmp_par (a INT, b INT, tickets_ab INT, PRIMARY KEY (a, b));
    INSERT INTO tmp_par
    SELECT x.id_producto, y.id_producto, COUNT(DISTINCT x.id_comanda)
    FROM hechos_ventas x
    JOIN hechos_ventas y
      ON y.id_comanda = x.id_comanda
     AND y.fecha_key = x.fecha_key          -- mismo ticket, misma partición
     AND y.id_producto <> x.id_producto
    WHERE x.id_producto IN (SELECT id_producto FROM tmp_item_frecuente)
      AND y.id_producto IN (SELECT id_producto FROM tmp_item_frecuente_b)
    GROUP BY x.id_producto, y.id_producto;

    DELETE FROM kdd_reglas_asociacion;
    INSERT INTO kdd_reglas_asociacion
    SELECT p.a, p.b, pa.nombre, pb.nombre,
           p.tickets_ab,
           p.tickets_ab / v_tickets,
           p.tickets_ab / fa.tickets,
           (p.tickets_ab / fa.tickets) / (fb.tickets / v_tickets),
           NOW()
    FROM tmp_par p
    JOIN tmp_item_frecuente fa ON fa.id_producto = p.a
    JOIN tmp_item_frecuente_b fb ON fb.id_producto = p.b
    JOIN dim_producto pa ON pa.id_producto = p.a
    JOIN dim_producto pb ON pb.id_producto = p.b
    WHERE p.tickets_ab / v_tickets >= p_soporte_min
      AND p.tickets_ab / fa.tickets >= p_confianza_min;

    DROP TEMPORARY TABLE tmp_par;
    DROP TEMPORARY TABLE tmp_item_frecuente;
    DROP TEMPORARY TABLE tmp_item_frecuente_b;
END //

-- ----------------------------------------------------------------------------
-- 2. Segmentación RFM de clientes fidelizados
--    R = días desde la última visita, F = cantidad de visitas, M = gasto total.
--    Cada métrica se convierte en un puntaje de 1 a 5 por quintiles (NTILE):
--    5 = el 20 % de mejores clientes en esa métrica.
-- ----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS kdd_segmentar_clientes //
CREATE PROCEDURE kdd_segmentar_clientes(IN p_fecha_corte DATE)
BEGIN
    DELETE FROM kdd_segmentos_rfm;
    INSERT INTO kdd_segmentos_rfm
    SELECT id_cliente, recencia, frecuencia, monto, r, f, m,
           CASE
               WHEN r >= 4 AND f >= 4 THEN 'Campeones'
               WHEN r >= 3 AND f >= 3 THEN 'Leales'
               WHEN r >= 4 AND f <= 2 THEN 'Recientes'
               WHEN r <= 2 AND f >= 3 THEN 'En riesgo'
               WHEN r <= 2 AND f <= 2 THEN 'Dormidos'
               ELSE 'Ocasionales'
           END,
           p_fecha_corte
    FROM (
        SELECT b.*,
               NTILE(5) OVER (ORDER BY recencia DESC)  AS r,   -- más reciente = 5
               NTILE(5) OVER (ORDER BY frecuencia ASC) AS f,
               NTILE(5) OVER (ORDER BY monto ASC)      AS m
        FROM (
            SELECT h.id_cliente,
                   DATEDIFF(p_fecha_corte, MAX(t.fecha)) AS recencia,
                   COUNT(DISTINCT h.id_comanda) AS frecuencia,
                   SUM(h.importe) AS monto
            FROM hechos_ventas h
            JOIN dim_tiempo t ON t.fecha_key = h.fecha_key
            WHERE h.id_cliente <> 0 AND t.fecha <= p_fecha_corte
            GROUP BY h.id_cliente
        ) b
    ) s;
END //

DELIMITER ;

-- ============================================================================
-- Ejecución y resultados
-- ============================================================================

SET @t0 = SYSDATE(6);
CALL kdd_calcular_reglas(0.02, 0.20);      -- soporte >= 2 %, confianza >= 20 %
SELECT ROUND(TIMESTAMPDIFF(MICROSECOND, @t0, SYSDATE(6)) / 1e6, 1) AS segundos_reglas,
       (SELECT COUNT(DISTINCT id_comanda) FROM hechos_ventas) AS tickets_analizados,
       (SELECT COUNT(*) FROM kdd_reglas_asociacion) AS reglas_encontradas;

SELECT '1. Reglas de asociación con mayor lift (quien pide A, también pide B)' AS resultado;
SELECT antecedente, consecuente,
       CONCAT(ROUND(soporte * 100, 1), ' %') AS soporte,
       CONCAT(ROUND(confianza * 100, 1), ' %') AS confianza,
       lift
FROM kdd_reglas_asociacion
WHERE lift > 1
ORDER BY lift DESC
LIMIT 10;

SELECT '1b. Pares que se evitan (lift < 1): no conviene ofrecerlos juntos' AS resultado;
SELECT antecedente, consecuente, CONCAT(ROUND(confianza * 100, 1), ' %') AS confianza, lift
FROM kdd_reglas_asociacion
ORDER BY lift ASC
LIMIT 5;

CALL kdd_segmentar_clientes('2026-10-31');

SELECT '2. Segmentos RFM de clientes al 31/10/2026' AS resultado;
SELECT segmento,
       COUNT(*) AS clientes,
       ROUND(AVG(recencia_dias)) AS recencia_promedio_dias,
       ROUND(AVG(frecuencia), 1) AS visitas_promedio,
       ROUND(AVG(monto)) AS gasto_promedio,
       CONCAT(ROUND(SUM(monto) * 100 / (SELECT SUM(monto) FROM kdd_segmentos_rfm), 1), ' %') AS participacion_en_ventas
FROM kdd_segmentos_rfm
GROUP BY segmento
ORDER BY SUM(monto) DESC;

SELECT '3. Tiempo de preparación (minutos) por estación y hora, desde el log del KDS' AS resultado;
SELECT estacion,
       ROUND(AVG(IF(hora BETWEEN 12 AND 14, duracion_seg, NULL)) / 60, 1) AS almuerzo_12_a_14,
       ROUND(AVG(IF(hora = 20, duracion_seg, NULL)) / 60, 1) AS cena_20,
       ROUND(AVG(IF(hora IN (21, 22), duracion_seg, NULL)) / 60, 1) AS pico_21_a_22,
       ROUND(AVG(IF(hora >= 23, duracion_seg, NULL)) / 60, 1) AS cena_23,
       CONCAT('+', ROUND((AVG(IF(hora IN (21, 22), duracion_seg, NULL))
                        / AVG(IF(hora NOT IN (13, 21, 22), duracion_seg, NULL)) - 1) * 100), ' %') AS demora_en_el_pico
FROM hechos_preparacion
GROUP BY estacion
ORDER BY AVG(duracion_seg) DESC;

SELECT '3b. Efecto del punto de cocción en la parrilla (cruce log KDS + base operativa)' AS resultado;
SELECT d.punto_coccion,
       COUNT(*) AS platos,
       ROUND(AVG(hp.duracion_seg) / 60, 1) AS minutos_promedio
FROM hechos_preparacion hp
JOIN restaurante_db.detalle_comanda d
  ON d.id_comanda = hp.id_comanda AND d.id_producto = hp.id_producto
WHERE hp.estacion = 'PARRILLA' AND hp.id_producto IN (3, 4)
GROUP BY d.punto_coccion
ORDER BY minutos_promedio;
