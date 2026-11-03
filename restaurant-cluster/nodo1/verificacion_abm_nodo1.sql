-- ============================================================================
-- AE4 - TIFAS: SCRIPT DE VERIFICACIÓN TÉCNICA Y PRUEBAS ABM (NODO 1 - SALÓN)
-- ============================================================================
USE restaurante_db;

-- 1. VERIFICACIÓN DE VARIABLES CRÍTICAS DE CONSISTENCIA Y MULTI-PRIMARY
SELECT 
    @@server_id AS server_id,
    @@auto_increment_increment AS auto_inc_increment,
    @@auto_increment_offset AS auto_inc_offset,
    @@innodb_flush_log_at_trx_commit AS flush_log_trx,
    @@sync_binlog AS sync_binlog,
    @@gtid_mode AS gtid_mode;

SHOW VARIABLES LIKE 'rpl_semi_sync%';
SHOW STATUS LIKE 'Rpl_semi_sync%';

-- 2. PRUEBA DE ALTA (INSERT): Apertura de 3 comandas desde Salón
-- Deben generarse con id_comanda IMPARES (1, 3, 5)
INSERT INTO comandas (id_mesa, mozo, nodo_origen, estado, total) VALUES
(1, 'Carlos Gómez', 'NODO_1_SALON', 'ABIERTA', 0.00),
(3, 'Lucía Fernández', 'NODO_1_SALON', 'ABIERTA', 0.00),
(5, 'Carlos Gómez', 'NODO_1_SALON', 'ABIERTA', 0.00);

-- Alta de ítems en detalle_comanda para la Comanda #1
INSERT INTO detalle_comanda (id_comanda, id_producto, cantidad, precio_unitario, observaciones) VALUES
(1, 1, 2, 18500.00, 'Punto jugoso'),
(1, 7, 2, 2500.00, 'Sin gas');

-- 3. PRUEBA DE MODIFICACIÓN (UPDATE): Actualización de total de comanda y estado de mesa
UPDATE comandas
SET estado = 'EN_PREPARACION',
    total = (SELECT COALESCE(SUM(subtotal), 0) FROM detalle_comanda WHERE id_comanda = 1)
WHERE id_comanda = 1;

UPDATE mesas
SET estado = 'OCUPADA'
WHERE id_mesa = 1;

-- 4. PRUEBA DE BAJA (DELETE / Cancelación): Baja de una comanda errónea (Comanda #5)
DELETE FROM comandas WHERE id_comanda = 5;

-- 5. CONSULTA DE VERIFICACIÓN FINAL ( Evidencia de IDs impares y consistencia )
SELECT * FROM mesas;
SELECT * FROM comandas;
SELECT * FROM detalle_comanda;
