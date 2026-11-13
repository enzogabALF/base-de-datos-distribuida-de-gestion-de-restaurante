-- ============================================================================
-- AE4 - TIFAS FASE 3: COSTO DE LOS ÍNDICES SOBRE LA TASA DE INSERCIÓN
-- ----------------------------------------------------------------------------
-- La consigna pide índices que aceleren los reportes "sin penalizar
-- severamente la tasa de inserción operativa". Este script lo mide.
--
-- Se insertan las mismas líneas de detalle de comanda en tres copias de la
-- tabla que solo se diferencian en sus índices:
--   A. ORIGINAL : PK + índices de las FK (id_comanda) e (id_producto)
--   B. FASE 3   : PK + índice de cobertura (id_comanda, id_producto, cantidad,
--                 subtotal) que reemplaza al de id_comanda + (id_producto)
--   C. FASE 3 + FULLTEXT : B + índice invertido sobre observaciones
--
-- Dos mediciones por variante (se toma el mejor de 3 intentos):
--   1. Carga masiva: INSERT ... SELECT de todo el detalle (~310.000 filas).
--   2. Operación del salón: 20.000 INSERT de una fila, como los de una comanda.
--
-- Las tablas de prueba se crean en un esquema aparte con sql_log_bin = 0: no se
-- replican ni pasan por la red, así la medición refleja solo el costo de
-- mantener los índices. El esquema se borra al final.
-- ============================================================================

SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci;   -- la misma intercalación que las tablas
SET SESSION sql_log_bin = 0;

DROP DATABASE IF EXISTS fase3_bench;
CREATE DATABASE fase3_bench CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE fase3_bench;

-- Columnas comunes (las mismas de restaurante_db.detalle_comanda, sin FKs)
CREATE TABLE a_original (
    id_detalle INT AUTO_INCREMENT PRIMARY KEY,
    id_comanda INT NOT NULL,
    id_producto INT NOT NULL,
    cantidad INT NOT NULL,
    precio_unitario DECIMAL(10, 2) NOT NULL,
    subtotal DECIMAL(10, 2) GENERATED ALWAYS AS (cantidad * precio_unitario) STORED,
    estado_cocina VARCHAR(20) NOT NULL DEFAULT 'PENDIENTE',
    observaciones VARCHAR(255) NULL,
    INDEX idx_comanda (id_comanda),
    INDEX idx_producto (id_producto)
) ENGINE = InnoDB;

CREATE TABLE b_fase3 LIKE a_original;
ALTER TABLE b_fase3
    DROP INDEX idx_comanda,
    ADD INDEX idx_cobertura (id_comanda, id_producto, cantidad, subtotal);

CREATE TABLE c_fase3_fulltext LIKE b_fase3;
ALTER TABLE c_fase3_fulltext ADD FULLTEXT INDEX ft_observaciones (observaciones);

CREATE TABLE resultados (
    variante VARCHAR(30),
    prueba VARCHAR(40),
    intento INT,
    filas INT,
    segundos DECIMAL(10, 3)
);

DELIMITER //

-- Carga masiva: copia todo el detalle real
CREATE PROCEDURE medir_carga(IN p_tabla VARCHAR(30), IN p_intento INT)
BEGIN
    SET @sql_vaciar = CONCAT('TRUNCATE TABLE ', p_tabla);
    PREPARE s FROM @sql_vaciar; EXECUTE s; DEALLOCATE PREPARE s;

    SET @sql_carga = CONCAT('INSERT INTO ', p_tabla,
        ' (id_detalle, id_comanda, id_producto, cantidad, precio_unitario, estado_cocina, observaciones)',
        ' SELECT id_detalle, id_comanda, id_producto, cantidad, precio_unitario, estado_cocina, observaciones',
        ' FROM restaurante_db.detalle_comanda');
    PREPARE s FROM @sql_carga;
    SET @t0 = SYSDATE(6);
    EXECUTE s;
    SET @filas = ROW_COUNT();   -- antes del DEALLOCATE, que lo reinicia a 0
    SET @seg = TIMESTAMPDIFF(MICROSECOND, @t0, SYSDATE(6)) / 1e6;
    DEALLOCATE PREPARE s;

    INSERT INTO resultados VALUES (p_tabla, '1. carga masiva (INSERT SELECT)', p_intento, @filas, @seg);
END //

-- Operación del salón: inserciones de una fila dentro de una transacción
-- (se excluye el COMMIT de cada fila para medir solo el costo de los índices)
CREATE PROCEDURE medir_operacion(IN p_tabla VARCHAR(30), IN p_intento INT, IN p_filas INT)
BEGIN
    DECLARE i INT DEFAULT 0;
    SET @sql_vaciar = CONCAT('TRUNCATE TABLE ', p_tabla);
    PREPARE s FROM @sql_vaciar; EXECUTE s; DEALLOCATE PREPARE s;

    SET @sql_fila = CONCAT('INSERT INTO ', p_tabla,
        ' (id_comanda, id_producto, cantidad, precio_unitario, observaciones) VALUES (?, ?, ?, ?, ?)');
    PREPARE s FROM @sql_fila;
    SET @t0 = SYSDATE(6);
    START TRANSACTION;
    WHILE i < p_filas DO
        SET @c = 2000000 + FLOOR(i / 3);
        SET @p = 1 + CRC32(i) % 12;
        SET @q = 1 + i % 3;
        SET @precio = 1000 + CRC32(i) % 20000;
        SET @obs = IF(i % 10 = 0, 'Comensal celíaco: preparar sin TACC', NULL);
        EXECUTE s USING @c, @p, @q, @precio, @obs;
        SET i = i + 1;
    END WHILE;
    COMMIT;
    SET @seg = TIMESTAMPDIFF(MICROSECOND, @t0, SYSDATE(6)) / 1e6;
    DEALLOCATE PREPARE s;

    INSERT INTO resultados VALUES (p_tabla, '2. operación (INSERT de 1 fila)', p_intento, p_filas, @seg);
END //

CREATE PROCEDURE ejecutar_benchmark()
BEGIN
    DECLARE intento INT DEFAULT 1;
    WHILE intento <= 3 DO
        CALL medir_carga('a_original', intento);
        CALL medir_carga('b_fase3', intento);
        CALL medir_carga('c_fase3_fulltext', intento);
        CALL medir_operacion('a_original', intento, 20000);
        CALL medir_operacion('b_fase3', intento, 20000);
        CALL medir_operacion('c_fase3_fulltext', intento, 20000);
        SET intento = intento + 1;
    END WHILE;
END //

DELIMITER ;

CALL ejecutar_benchmark();

-- Resultado: mejor intento de cada variante y su diferencia con la original
SELECT r.prueba,
       r.variante,
       MAX(r.filas) AS filas,
       MIN(r.segundos) AS segundos,
       ROUND(MAX(r.filas) / MIN(r.segundos)) AS filas_por_segundo,
       ROUND(MIN(r.segundos) * 1e6 / MAX(r.filas), 1) AS microseg_por_fila,
       CONCAT(IF(MIN(r.segundos) >= base.seg, '+', ''),
              ROUND((MIN(r.segundos) / base.seg - 1) * 100, 1), ' %') AS vs_original
FROM resultados r
JOIN (SELECT prueba, MIN(segundos) AS seg FROM resultados WHERE variante = 'a_original' GROUP BY prueba) base
  ON base.prueba = r.prueba
GROUP BY r.prueba, r.variante, base.seg
ORDER BY r.prueba, r.variante;

-- Tamaño de los índices de cada variante después de la carga masiva
CALL medir_carga('a_original', 0);
CALL medir_carga('b_fase3', 0);
CALL medir_carga('c_fase3_fulltext', 0);
ANALYZE TABLE a_original, b_fase3, c_fase3_fulltext;
SELECT TABLE_NAME AS variante,
       ROUND(DATA_LENGTH / 1048576, 1) AS datos_mb,
       ROUND(INDEX_LENGTH / 1048576, 1) AS indices_secundarios_mb
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = 'fase3_bench' AND TABLE_NAME <> 'resultados'
ORDER BY TABLE_NAME;

DROP DATABASE fase3_bench;
SET SESSION sql_log_bin = 1;
