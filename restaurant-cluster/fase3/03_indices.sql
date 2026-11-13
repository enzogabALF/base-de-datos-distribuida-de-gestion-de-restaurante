-- ============================================================================
-- AE4 - TIFAS FASE 3: ESTRATEGIA DE INDEXACIÓN
-- ----------------------------------------------------------------------------
-- Se ejecuta en el Nodo 1. Las sentencias DDL se replican: el Nodo 2 recibe
-- exactamente los mismos índices (los dos nodos atienden lecturas, así que
-- los dos los necesitan).
--
-- Criterio general: cada índice responde a un reporte medido con EXPLAIN
-- ANALYZE en 02_diagnostico.sql. No se indexa "por las dudas": cada índice
-- secundario hay que mantenerlo en cada INSERT/UPDATE/DELETE, y eso penaliza
-- la toma de comandas (ver el benchmark de 04_benchmark_insercion.sql).
--
-- Tipos de índice usados en MySQL 8.0 / InnoDB:
--   * B+Tree (todos los índices secundarios de InnoDB): igualdad, rangos y
--     orden. Se usan compuestos y "de cobertura" (contienen todas las columnas
--     que la consulta necesita, así no se lee la fila completa).
--   * FULLTEXT: índice invertido (palabra -> filas). Es el equivalente en MySQL
--     al GIN de PostgreSQL para búsquedas de texto.
--   * HASH: InnoDB no permite crearlo explícitamente (USING HASH se convierte en
--     BTREE). En su lugar mantiene el Adaptive Hash Index: construye por su
--     cuenta un hash en memoria sobre las páginas B+Tree más consultadas.
-- ============================================================================

USE restaurante_db;

-- ----------------------------------------------------------------------------
-- I1. comandas (estado, fecha_apertura)
--     Reportes R1, R3 y R5: filtran comandas PAGADAS en un rango de fechas.
--     Orden de columnas: primero la igualdad (estado) y después el rango
--     (fecha), porque un B+Tree solo aprovecha las columnas que siguen a una
--     condición de rango si esa condición es la última.
--     Se agregan mozo y total para que R3 se resuelva sin leer la fila
--     (índice de cobertura).
-- ----------------------------------------------------------------------------
ALTER TABLE comandas
    ADD INDEX idx_comandas_estado_fecha (estado, fecha_apertura, mozo, total);

-- ----------------------------------------------------------------------------
-- I2. comandas (id_cliente, estado, fecha_apertura, total)
--     Reporte R6 (mejores clientes). REEMPLAZA al índice que InnoDB creó para
--     la clave foránea fk_comanda_cliente (id_cliente): el nuevo empieza por la
--     misma columna, así que también sirve a la FK, y mantener los dos sería
--     pagar dos veces el costo de escritura.
-- ----------------------------------------------------------------------------
ALTER TABLE comandas
    ADD INDEX idx_comandas_cliente_estado_fecha (id_cliente, estado, fecha_apertura, total),
    DROP INDEX fk_comanda_cliente;

-- ----------------------------------------------------------------------------
-- I3. detalle_comanda (id_comanda, id_producto, cantidad, subtotal)
--     Reportes R1 y R5: por cada comanda del rango hay que sumar cantidad y
--     subtotal por producto. Con el índice de cobertura, InnoDB recorre solo el
--     índice (más chico y ordenado por comanda). Reemplaza al índice de la FK
--     fk_detalle_comanda (id_comanda), que queda redundante.
--     subtotal es una columna generada STORED: se puede indexar.
-- ----------------------------------------------------------------------------
ALTER TABLE detalle_comanda
    ADD INDEX idx_detalle_comanda_cobertura (id_comanda, id_producto, cantidad, subtotal),
    DROP INDEX fk_detalle_comanda;

-- ----------------------------------------------------------------------------
-- I4. pagos (fecha_pago, metodo_pago, monto_total)
--     Reporte R2 (arqueo de caja): rango de fechas de pago. De cobertura para
--     la suma por medio de pago.
-- ----------------------------------------------------------------------------
ALTER TABLE pagos
    ADD INDEX idx_pagos_fecha_metodo (fecha_pago, metodo_pago, monto_total);

-- ----------------------------------------------------------------------------
-- I5. historial_estados_comanda (id_comanda, estado_nuevo, fecha_cambio)
--     Reporte R3: para cada comanda se busca el instante en que pasó a
--     LISTA_PARA_SERVIR. Reemplaza al índice de la FK fk_historial_comanda.
-- ----------------------------------------------------------------------------
ALTER TABLE historial_estados_comanda
    ADD INDEX idx_historial_comanda_estado (id_comanda, estado_nuevo, fecha_cambio),
    DROP INDEX fk_historial_comanda;

-- ----------------------------------------------------------------------------
-- I6. FULLTEXT detalle_comanda (observaciones)
--     Reporte R4: la cocina busca pedidos con indicaciones especiales
--     ("celíaco", "sin sal"). LIKE '%texto%' no puede usar un B+Tree porque
--     el patrón empieza con comodín. El índice invertido guarda cada palabra
--     con la lista de filas que la contienen.
-- ----------------------------------------------------------------------------
ALTER TABLE detalle_comanda
    ADD FULLTEXT INDEX ft_detalle_observaciones (observaciones);

-- ----------------------------------------------------------------------------
-- Estadísticas: histogramas para que el optimizador conozca la distribución
-- real de estado y fecha_apertura. Sin ellos supone distribuciones uniformes y
-- se equivoca en la cantidad de filas estimadas (estimaba 0,05 filas donde
-- había miles), lo que lo lleva a elegir un orden de JOIN malo.
-- ----------------------------------------------------------------------------
ANALYZE TABLE comandas UPDATE HISTOGRAM ON estado, fecha_apertura WITH 64 BUCKETS;
ANALYZE TABLE pagos UPDATE HISTOGRAM ON metodo_pago WITH 8 BUCKETS;
ANALYZE TABLE comandas, detalle_comanda, pagos, historial_estados_comanda;

-- ----------------------------------------------------------------------------
-- Demostración de HASH en InnoDB: el motor acepta la sintaxis pero crea un
-- B+Tree. SHOW INDEX muestra Index_type = BTREE.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS fase3_demo_hash (
    codigo CHAR(12) NOT NULL,
    descripcion VARCHAR(50),
    INDEX idx_demo_hash (codigo) USING HASH
) ENGINE = InnoDB;
SELECT INDEX_NAME, INDEX_TYPE AS tipo_real_en_innodb
FROM information_schema.STATISTICS
WHERE TABLE_SCHEMA = 'restaurante_db' AND TABLE_NAME = 'fase3_demo_hash';
DROP TABLE fase3_demo_hash;

-- Adaptive Hash Index: activo y usado automáticamente por InnoDB
SELECT @@innodb_adaptive_hash_index AS adaptive_hash_index_activo;

-- ----------------------------------------------------------------------------
-- Inventario final de índices de las tablas afectadas
-- ----------------------------------------------------------------------------
SELECT TABLE_NAME AS tabla, INDEX_NAME AS indice, INDEX_TYPE AS tipo,
       GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX) AS columnas
FROM information_schema.STATISTICS
WHERE TABLE_SCHEMA = 'restaurante_db'
  AND TABLE_NAME IN ('comandas', 'detalle_comanda', 'pagos', 'historial_estados_comanda')
GROUP BY TABLE_NAME, INDEX_NAME, INDEX_TYPE
ORDER BY TABLE_NAME, INDEX_NAME;
