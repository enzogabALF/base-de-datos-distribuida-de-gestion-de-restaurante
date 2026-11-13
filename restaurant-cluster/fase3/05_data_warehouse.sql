-- ============================================================================
-- AE4 - TIFAS FASE 3: DATA WAREHOUSE DIMENSIONAL (ESQUEMA EN ESTRELLA)
-- ----------------------------------------------------------------------------
-- Los reportes estratégicos no deberían competir con la toma de comandas. Se
-- separan en un esquema analítico, restaurante_dw, con un modelo en estrella
-- (Kimball): tablas de hechos con las medidas numéricas, rodeadas de
-- dimensiones con los atributos por los que se analiza.
--
--                       dim_tiempo   dim_turno
--                             \        /
--   dim_producto ---- HECHOS_VENTAS ---- dim_mesa
--                        /    |    \
--             dim_cliente  dim_mozo  dim_medio_pago
--
--   HECHOS_PREPARACION (tiempos de cocina del log del KDS) comparte
--   dim_tiempo, dim_turno y dim_producto.
--
-- Optimización física:
--   * hechos_ventas está PARTICIONADA POR RANGO de fecha (un mes por partición):
--     los reportes de un período leen solo sus particiones (partition pruning) y
--     la depuración de meses viejos es un DROP PARTITION instantáneo.
--   * hechos_preparacion está PARTICIONADA POR LISTA de estación de cocina:
--     cada pantalla de estación (parrilla, cocina, pastelería, barra) lee solo
--     su partición.
--   * InnoDB no admite claves foráneas en tablas particionadas. En un data
--     warehouse es lo habitual: la integridad la garantiza el proceso de ETL,
--     que solo inserta claves que existen en las dimensiones.
--   * Toda clave única de una tabla particionada debe incluir la columna de
--     particionamiento: por eso las PK son (id, fecha_key) y (id, estacion).
--
-- Se crea en el Nodo 1 y se replica: el Nodo 2 tiene una copia del data
-- warehouse y puede atender los tableros si el Nodo 1 cae.
-- ============================================================================

SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci;   -- la misma intercalación que las tablas

CREATE DATABASE IF NOT EXISTS restaurante_dw
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

USE restaurante_dw;

-- ----------------------------------------------------------------------------
-- DIMENSIONES
-- ----------------------------------------------------------------------------

-- Calendario: una fila por día, clave inteligente AAAAMMDD
CREATE TABLE dim_tiempo (
    fecha_key        INT PRIMARY KEY,
    fecha            DATE NOT NULL UNIQUE,
    anio             SMALLINT NOT NULL,
    trimestre        TINYINT NOT NULL,
    mes              TINYINT NOT NULL,
    periodo          CHAR(7) NOT NULL,          -- '2026-10'
    nombre_mes       VARCHAR(12) NOT NULL,
    dia              TINYINT NOT NULL,
    dia_semana       TINYINT NOT NULL,          -- 1 = lunes ... 7 = domingo
    nombre_dia       VARCHAR(10) NOT NULL,
    es_fin_de_semana BOOLEAN NOT NULL,
    INDEX idx_tiempo_periodo (periodo)
) ENGINE = InnoDB;

CREATE TABLE dim_turno (
    id_turno   TINYINT PRIMARY KEY,
    turno      VARCHAR(12) NOT NULL,
    hora_desde TINYINT NOT NULL,
    hora_hasta TINYINT NOT NULL
) ENGINE = InnoDB;

CREATE TABLE dim_producto (
    id_producto INT PRIMARY KEY,
    nombre      VARCHAR(100) NOT NULL,
    categoria   VARCHAR(20) NOT NULL,
    estacion    VARCHAR(20) NOT NULL,           -- estación de cocina que lo prepara
    precio_lista DECIMAL(10, 2) NOT NULL
) ENGINE = InnoDB;

CREATE TABLE dim_mesa (
    id_mesa     INT PRIMARY KEY,
    numero_mesa INT NOT NULL,
    sector      VARCHAR(50) NOT NULL,
    capacidad   INT NOT NULL
) ENGINE = InnoDB;

-- id_cliente = 0 representa al "Consumidor final" (comandas sin cliente)
CREATE TABLE dim_cliente (
    id_cliente      INT PRIMARY KEY,
    nombre_completo VARCHAR(100) NOT NULL,
    tipo            VARCHAR(20) NOT NULL        -- CONSUMIDOR_FINAL / FIDELIZADO
) ENGINE = InnoDB;

CREATE TABLE dim_mozo (
    id_mozo INT AUTO_INCREMENT PRIMARY KEY,
    nombre  VARCHAR(80) NOT NULL UNIQUE
) ENGINE = InnoDB;

CREATE TABLE dim_medio_pago (
    id_medio_pago TINYINT PRIMARY KEY,
    metodo_pago   VARCHAR(20) NOT NULL UNIQUE,
    tipo          VARCHAR(12) NOT NULL          -- EFECTIVO / ELECTRONICO
) ENGINE = InnoDB;

-- ----------------------------------------------------------------------------
-- HECHOS DE VENTAS
-- Granularidad: una fila por línea de comanda pagada.
-- Medidas: cantidad, importe, costo (de la planilla de proveedores).
-- id_comanda es una "dimensión degenerada": agrupa las líneas de un mismo
-- ticket (la usa el análisis de canasta de KDD).
-- ----------------------------------------------------------------------------
CREATE TABLE hechos_ventas (
    id_detalle     INT NOT NULL,
    fecha_key      INT NOT NULL,
    hora           TINYINT NOT NULL,
    id_turno       TINYINT NOT NULL,
    id_producto    INT NOT NULL,
    id_mesa        INT NOT NULL,
    id_cliente     INT NOT NULL,
    id_mozo        INT NOT NULL,
    id_medio_pago  TINYINT NOT NULL,
    id_comanda     INT NOT NULL,
    cantidad       INT NOT NULL,
    importe        DECIMAL(12, 2) NOT NULL,
    costo_unitario DECIMAL(10, 2) NULL,
    costo_total    DECIMAL(12, 2) NULL,
    cargado_en     TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id_detalle, fecha_key),
    INDEX idx_hv_comanda_producto (id_comanda, id_producto),
    INDEX idx_hv_cargado (cargado_en)
) ENGINE = InnoDB
PARTITION BY RANGE (fecha_key) (
    PARTITION p2025_01 VALUES LESS THAN (20250201),
    PARTITION p2025_02 VALUES LESS THAN (20250301),
    PARTITION p2025_03 VALUES LESS THAN (20250401),
    PARTITION p2025_04 VALUES LESS THAN (20250501),
    PARTITION p2025_05 VALUES LESS THAN (20250601),
    PARTITION p2025_06 VALUES LESS THAN (20250701),
    PARTITION p2025_07 VALUES LESS THAN (20250801),
    PARTITION p2025_08 VALUES LESS THAN (20250901),
    PARTITION p2025_09 VALUES LESS THAN (20251001),
    PARTITION p2025_10 VALUES LESS THAN (20251101),
    PARTITION p2025_11 VALUES LESS THAN (20251201),
    PARTITION p2025_12 VALUES LESS THAN (20260101),
    PARTITION p2026_01 VALUES LESS THAN (20260201),
    PARTITION p2026_02 VALUES LESS THAN (20260301),
    PARTITION p2026_03 VALUES LESS THAN (20260401),
    PARTITION p2026_04 VALUES LESS THAN (20260501),
    PARTITION p2026_05 VALUES LESS THAN (20260601),
    PARTITION p2026_06 VALUES LESS THAN (20260701),
    PARTITION p2026_07 VALUES LESS THAN (20260801),
    PARTITION p2026_08 VALUES LESS THAN (20260901),
    PARTITION p2026_09 VALUES LESS THAN (20261001),
    PARTITION p2026_10 VALUES LESS THAN (20261101),
    PARTITION p2026_11 VALUES LESS THAN (20261201),
    PARTITION p2026_12 VALUES LESS THAN (20270101),
    -- Red de seguridad: si el mantenimiento mensual no corrió, las filas nuevas
    -- caen aquí en lugar de dar error. dw_mantener_particiones() la divide.
    PARTITION p_futuro VALUES LESS THAN MAXVALUE
);

-- ----------------------------------------------------------------------------
-- HECHOS DE PREPARACIÓN (fuente: log de texto del sistema de pantallas de
-- cocina, KDS). Granularidad: un plato terminado por una estación.
-- ----------------------------------------------------------------------------
CREATE TABLE hechos_preparacion (
    id_evento    INT NOT NULL AUTO_INCREMENT,
    estacion     VARCHAR(20) NOT NULL,
    momento      DATETIME NOT NULL,
    fecha_key    INT NOT NULL,
    hora         TINYINT NOT NULL,
    id_turno     TINYINT NOT NULL,
    id_producto  INT NOT NULL,
    id_comanda   INT NOT NULL,
    cantidad     INT NOT NULL,
    duracion_seg INT NOT NULL,
    PRIMARY KEY (id_evento, estacion),
    UNIQUE KEY uq_evento (id_comanda, id_producto, momento, estacion)
) ENGINE = InnoDB
PARTITION BY LIST COLUMNS (estacion) (
    PARTITION p_parrilla   VALUES IN ('PARRILLA'),
    PARTITION p_cocina     VALUES IN ('COCINA_CALIENTE'),
    PARTITION p_pasteleria VALUES IN ('PASTELERIA'),
    PARTITION p_barra      VALUES IN ('BARRA')
);

-- ----------------------------------------------------------------------------
-- STAGING Y CONTROL DEL ETL
-- ----------------------------------------------------------------------------

-- Planilla de costos tal como viene del Excel (todo texto, sin validar)
CREATE TABLE stg_costos_proveedor (
    id_fila   INT AUTO_INCREMENT PRIMARY KEY,
    producto  VARCHAR(150),
    mes       VARCHAR(20),
    costo     VARCHAR(30),
    proveedor VARCHAR(100)
) ENGINE = InnoDB;

-- Costos ya limpios y asociados al producto: uno por producto y mes
CREATE TABLE costos_producto_mes (
    id_producto    INT NOT NULL,
    periodo        CHAR(7) NOT NULL,
    costo_unitario DECIMAL(10, 2) NOT NULL,
    proveedor      VARCHAR(100) NOT NULL,
    PRIMARY KEY (id_producto, periodo)
) ENGINE = InnoDB;

-- Log del KDS tal como viene: una fila por línea de texto
CREATE TABLE stg_log_kds (
    id_linea INT AUTO_INCREMENT PRIMARY KEY,
    linea    VARCHAR(500)
) ENGINE = InnoDB;

-- Bitácora de cada ejecución del ETL
CREATE TABLE etl_control (
    id_ejecucion     INT AUTO_INCREMENT PRIMARY KEY,
    proceso          VARCHAR(40) NOT NULL,
    inicio           DATETIME(6) NOT NULL,
    fin              DATETIME(6) NULL,
    filas_leidas     INT NULL,
    filas_cargadas   INT NULL,
    filas_rechazadas INT NULL,
    marca_agua       DATETIME NULL,          -- hasta dónde se procesó la fuente
    INDEX idx_etl_proceso (proceso, id_ejecucion)
) ENGINE = InnoDB;

-- Filas descartadas por calidad de datos, con el motivo
CREATE TABLE etl_rechazos (
    id_rechazo   INT AUTO_INCREMENT PRIMARY KEY,
    id_ejecucion INT NOT NULL,
    fuente       VARCHAR(30) NOT NULL,
    contenido    VARCHAR(500) NULL,
    motivo       VARCHAR(150) NOT NULL
) ENGINE = InnoDB;

-- ----------------------------------------------------------------------------
-- CARGA DE LAS DIMENSIONES ESTÁTICAS
-- ----------------------------------------------------------------------------
SET SESSION cte_max_recursion_depth = 2000;
SET lc_time_names = 'es_AR';

INSERT INTO dim_tiempo
WITH RECURSIVE dias (f) AS (
    SELECT DATE('2025-01-01')
    UNION ALL SELECT f + INTERVAL 1 DAY FROM dias WHERE f < '2027-12-31'
)
SELECT CAST(DATE_FORMAT(f, '%Y%m%d') AS UNSIGNED),
       f,
       YEAR(f),
       QUARTER(f),
       MONTH(f),
       DATE_FORMAT(f, '%Y-%m'),
       DATE_FORMAT(f, '%M'),
       DAY(f),
       WEEKDAY(f) + 1,
       DATE_FORMAT(f, '%W'),
       WEEKDAY(f) >= 5
FROM dias;

INSERT INTO dim_turno VALUES
(1, 'ALMUERZO', 11, 16),
(2, 'CENA', 19, 23),
(3, 'OTRO', 0, 23);

INSERT INTO dim_medio_pago VALUES
(1, 'EFECTIVO', 'EFECTIVO'),
(2, 'TARJETA_DEBITO', 'ELECTRONICO'),
(3, 'TARJETA_CREDITO', 'ELECTRONICO'),
(4, 'TRANSFERENCIA_QR', 'ELECTRONICO');

INSERT INTO dim_cliente VALUES (0, 'Consumidor final', 'CONSUMIDOR_FINAL');

SELECT TABLE_NAME AS tabla, COUNT(*) AS particiones
FROM information_schema.PARTITIONS
WHERE TABLE_SCHEMA = 'restaurante_dw' AND PARTITION_NAME IS NOT NULL
GROUP BY TABLE_NAME;
