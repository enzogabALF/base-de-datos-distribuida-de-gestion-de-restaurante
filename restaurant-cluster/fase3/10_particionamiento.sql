-- ============================================================================
-- AE4 - TIFAS FASE 3: MANTENIMIENTO AUTOMÁTICO DE PARTICIONES
-- ----------------------------------------------------------------------------
-- La tabla de hechos tiene una partición por mes hasta diciembre de 2026 y una
-- partición p_futuro de seguridad. Para no depender de que alguien se acuerde
-- de crear las particiones nuevas, un EVENT mensual ejecuta
-- dw_mantener_particiones(meses_adelante), que divide p_futuro hasta cubrir
-- los próximos meses. REORGANIZE PARTITION solo reescribe las filas de
-- p_futuro (normalmente ninguna), no la tabla completa.
--
-- Para la depuración de datos viejos (retención), se usa DROP PARTITION:
-- borra un mes completo de forma instantánea, sin generar una fila de undo
-- ni de binlog por cada registro, como haría un DELETE.
-- ============================================================================

SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci;   -- la misma intercalación que las tablas
USE restaurante_dw;

DELIMITER //

DROP PROCEDURE IF EXISTS dw_mantener_particiones //
CREATE PROCEDURE dw_mantener_particiones(IN p_meses_adelante INT)
BEGIN
    DECLARE v_ultimo_limite INT;
    DECLARE v_objetivo DATE;
    DECLARE v_inicio DATE;
    DECLARE v_creadas INT DEFAULT 0;

    -- Límite superior de la última partición mensual (la anterior a p_futuro)
    SELECT MAX(CAST(PARTITION_DESCRIPTION AS UNSIGNED)) INTO v_ultimo_limite
    FROM information_schema.PARTITIONS
    WHERE TABLE_SCHEMA = 'restaurante_dw' AND TABLE_NAME = 'hechos_ventas'
      AND PARTITION_DESCRIPTION <> 'MAXVALUE';

    SET v_inicio = STR_TO_DATE(v_ultimo_limite, '%Y%m%d');      -- primer día sin partición
    SET v_objetivo = DATE_FORMAT(CURRENT_DATE + INTERVAL p_meses_adelante MONTH, '%Y-%m-01');

    WHILE v_inicio <= v_objetivo DO
        SET @ddl = CONCAT(
            'ALTER TABLE hechos_ventas REORGANIZE PARTITION p_futuro INTO (',
            'PARTITION p', DATE_FORMAT(v_inicio, '%Y_%m'),
            ' VALUES LESS THAN (', DATE_FORMAT(v_inicio + INTERVAL 1 MONTH, '%Y%m%d'), '), ',
            'PARTITION p_futuro VALUES LESS THAN MAXVALUE)');
        PREPARE s FROM @ddl;
        EXECUTE s;
        DEALLOCATE PREPARE s;
        SET v_creadas = v_creadas + 1;
        SET v_inicio = v_inicio + INTERVAL 1 MONTH;
    END WHILE;

    SELECT v_creadas AS particiones_creadas,
           DATE_FORMAT(v_objetivo, '%Y-%m') AS cubierto_hasta;
END //

DELIMITER ;

CREATE EVENT IF NOT EXISTS ev_dw_particiones
    ON SCHEDULE EVERY 1 MONTH
    STARTS (DATE_FORMAT(CURRENT_DATE + INTERVAL 1 MONTH, '%Y-%m-01') + INTERVAL 3 HOUR)
    ON COMPLETION PRESERVE
    COMMENT 'Crea por adelantado las particiones mensuales de hechos_ventas'
    DO CALL dw_mantener_particiones(3);

-- Ejecución inicial: deja creadas las particiones de los próximos 3 meses
CALL dw_mantener_particiones(3);

SELECT PARTITION_NAME AS particion, PARTITION_DESCRIPTION AS menor_que, TABLE_ROWS AS filas_aprox
FROM information_schema.PARTITIONS
WHERE TABLE_SCHEMA = 'restaurante_dw' AND TABLE_NAME = 'hechos_ventas'
ORDER BY PARTITION_ORDINAL_POSITION;
