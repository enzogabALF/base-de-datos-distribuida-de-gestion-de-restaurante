-- ============================================================================
-- AE4 - TIFAS FASE 3: VISTAS MATERIALIZADAS CON REFRESCO PERIÓDICO
-- ----------------------------------------------------------------------------
-- MySQL no tiene CREATE MATERIALIZED VIEW (PostgreSQL y Oracle sí). Se
-- implementa con los tres elementos que la definen:
--   1. Una TABLA con el resultado precalculado de la consulta (mv_ventas_mensuales).
--   2. Un PROCEDIMIENTO de refresco, completo o incremental (dw_refrescar_mv_ventas).
--   3. Una POLÍTICA de refresco periódico: un EVENT del planificador de MySQL
--      (event_scheduler) que cada 15 minutos ejecuta el ETL incremental y
--      refresca la vista.
--
-- Política elegida: refresco INCREMENTAL cada 15 minutos (el mismo RPO de los
-- respaldos de la Fase 2). Solo se recalculan los meses que recibieron hechos
-- nuevos desde el último refresco (columna hechos_ventas.cargado_en), dentro de
-- una transacción: quien lee la vista durante el refresco ve la versión
-- anterior completa (MVCC de InnoDB), nunca una a medio armar.
-- El refresco COMPLETO (vaciar y recalcular todo) queda para cambios de
-- definición o reparaciones.
--
-- Replicación: el EVENT se crea en el Nodo 1. Al replicarse, MySQL lo crea en
-- el Nodo 2 deshabilitado (SLAVESIDE_DISABLED) para que el refresco no corra
-- dos veces; los datos refrescados llegan al Nodo 2 por replicación. Si el
-- Nodo 1 cae por mucho tiempo, se habilita en el Nodo 2 con ALTER EVENT ... ENABLE.
-- ============================================================================

SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci;   -- la misma intercalación que las tablas
USE restaurante_dw;

-- ----------------------------------------------------------------------------
-- 1. Tabla de la vista materializada: ventas por mes, categoría, sector y turno
-- ----------------------------------------------------------------------------
CREATE TABLE mv_ventas_mensuales (
    periodo       CHAR(7) NOT NULL,
    categoria     VARCHAR(20) NOT NULL,
    sector        VARCHAR(50) NOT NULL,
    turno         VARCHAR(12) NOT NULL,
    tickets       INT NOT NULL,
    unidades      INT NOT NULL,
    importe       DECIMAL(14, 2) NOT NULL,
    costo         DECIMAL(14, 2) NOT NULL,
    margen        DECIMAL(14, 2) NOT NULL,
    actualizado_en DATETIME(6) NOT NULL,
    PRIMARY KEY (periodo, categoria, sector, turno)
) ENGINE = InnoDB;

-- Registro de cada refresco (cuándo, de qué tipo, cuántos meses y cuánto tardó)
CREATE TABLE mv_control (
    id_refresco  INT AUTO_INCREMENT PRIMARY KEY,
    vista        VARCHAR(40) NOT NULL,
    modo         VARCHAR(12) NOT NULL,
    inicio       DATETIME(6) NOT NULL,
    fin          DATETIME(6) NULL,
    periodos     INT NULL,
    filas        INT NULL,
    origen       VARCHAR(20) NOT NULL DEFAULT 'MANUAL'
) ENGINE = InnoDB;

DELIMITER //

-- ----------------------------------------------------------------------------
-- 2. Procedimiento de refresco
-- ----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS dw_refrescar_mv_ventas //
CREATE PROCEDURE dw_refrescar_mv_ventas(IN p_modo VARCHAR(12), IN p_origen VARCHAR(20))
BEGIN
    DECLARE v_id INT;
    DECLARE v_desde DATETIME(6);

    -- Último refresco terminado: los hechos cargados después de ese instante
    -- son los que todavía no están en la vista
    SELECT COALESCE(MAX(inicio), '1900-01-01') INTO v_desde
    FROM mv_control WHERE vista = 'mv_ventas_mensuales' AND fin IS NOT NULL;

    INSERT INTO mv_control (vista, modo, inicio, origen)
    VALUES ('mv_ventas_mensuales', p_modo, SYSDATE(6), p_origen);
    SET v_id = LAST_INSERT_ID();

    -- Meses a recalcular
    DROP TEMPORARY TABLE IF EXISTS tmp_periodos;
    CREATE TEMPORARY TABLE tmp_periodos (periodo CHAR(7) PRIMARY KEY);
    IF p_modo = 'COMPLETO' THEN
        INSERT INTO tmp_periodos SELECT DISTINCT periodo FROM dim_tiempo;
    ELSE
        INSERT INTO tmp_periodos
        SELECT DISTINCT t.periodo
        FROM hechos_ventas h JOIN dim_tiempo t ON t.fecha_key = h.fecha_key
        WHERE h.cargado_en >= v_desde;
    END IF;

    START TRANSACTION;
        DELETE mv FROM mv_ventas_mensuales mv JOIN tmp_periodos p ON p.periodo = mv.periodo;

        INSERT INTO mv_ventas_mensuales
        SELECT t.periodo, pr.categoria, me.sector, tu.turno,
               COUNT(DISTINCT h.id_comanda),
               SUM(h.cantidad),
               SUM(h.importe),
               SUM(COALESCE(h.costo_total, 0)),
               SUM(h.importe - COALESCE(h.costo_total, 0)),
               SYSDATE(6)
        FROM hechos_ventas h
        JOIN dim_tiempo t    ON t.fecha_key = h.fecha_key
        JOIN tmp_periodos p  ON p.periodo = t.periodo
        JOIN dim_producto pr ON pr.id_producto = h.id_producto
        JOIN dim_mesa me     ON me.id_mesa = h.id_mesa
        JOIN dim_turno tu    ON tu.id_turno = h.id_turno
        GROUP BY t.periodo, pr.categoria, me.sector, tu.turno;
        SET @mv_filas = ROW_COUNT();
    COMMIT;

    UPDATE mv_control
    SET fin = SYSDATE(6), periodos = (SELECT COUNT(*) FROM tmp_periodos), filas = @mv_filas
    WHERE id_refresco = v_id;
    DROP TEMPORARY TABLE tmp_periodos;
END //

-- ----------------------------------------------------------------------------
-- 3. Ciclo de actualización del data warehouse: ETL incremental + refresco
-- ----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS dw_ciclo_actualizacion //
CREATE PROCEDURE dw_ciclo_actualizacion(IN p_origen VARCHAR(20))
BEGIN
    CALL dw_cargar_dimensiones();
    CALL dw_cargar_hechos_ventas();
    CALL dw_refrescar_mv_ventas('INCREMENTAL', p_origen);
END //

DELIMITER ;

-- Carga inicial de la vista (refresco completo)
CALL dw_refrescar_mv_ventas('COMPLETO', 'CARGA_INICIAL');

-- ----------------------------------------------------------------------------
-- 4. Política de refresco periódico
-- ----------------------------------------------------------------------------
SELECT @@event_scheduler AS planificador_de_eventos;

CREATE EVENT IF NOT EXISTS ev_dw_actualizacion
    ON SCHEDULE EVERY 15 MINUTE
    STARTS CURRENT_TIMESTAMP + INTERVAL 15 MINUTE
    ON COMPLETION PRESERVE
    COMMENT 'ETL incremental y refresco de mv_ventas_mensuales (RPO analítico de 15 min)'
    DO CALL dw_ciclo_actualizacion('EVENTO');

SELECT EVENT_NAME AS evento, STATUS AS estado, INTERVAL_VALUE AS cada, INTERVAL_FIELD AS unidad,
       EVENT_DEFINITION AS accion
FROM information_schema.EVENTS
WHERE EVENT_SCHEMA = 'restaurante_dw';

SELECT modo, origen, periodos, filas,
       ROUND(TIMESTAMPDIFF(MICROSECOND, inicio, fin) / 1e6, 2) AS segundos
FROM mv_control ORDER BY id_refresco;
