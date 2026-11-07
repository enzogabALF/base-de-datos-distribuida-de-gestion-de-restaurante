-- ============================================================================
-- AE4 - TIFAS: PROTOCOLO DE VERIFICACIÓN TÉCNICA Y PRUEBAS ABM (NODO 1 - SALÓN)
-- Cátedra: Gestión Avanzada de Bases de Datos
-- ============================================================================

USE restaurante_db;

-- ============================================================================
-- BLOQUE 1: VERIFICACIÓN DE VARIABLES CRÍTICAS DE CONSISTENCIA Y TOPOLOGÍA
-- ============================================================================
SELECT 
    @@server_id AS nodo_server_id,
    @@auto_increment_increment AS auto_inc_increment,
    @@auto_increment_offset AS auto_inc_offset,
    @@innodb_flush_log_at_trx_commit AS flush_log_trx,
    @@sync_binlog AS sync_binlog,
    @@gtid_mode AS gtid_mode,
    @@enforce_gtid_consistency AS enforce_gtid;

-- Verificación de Replicación Semisincrónica y Wait Point (AFTER_SYNC - 2PC)
SHOW VARIABLES LIKE 'rpl_semi_sync%';
SHOW STATUS LIKE 'Rpl_semi_sync%';


-- ============================================================================
-- BLOQUE 2: PRUEBAS DE RESTRICCIONES DE INTEGRIDAD Y REGLAS DE NEGOCIO
-- ============================================================================

-- 2.1. Verificación de CHECK Constraint en Menú (Debe fallar si precio < 0)
-- EXPECTATIVA: Error 3819 (Check constraint 'productos_menu_chk_1' is violated)
-- INSERT INTO productos_menu (nombre, categoria, precio, stock_disponible)
-- VALUES ('Plato Inválido', 'ENTRADA', -500.00, 10);

-- 2.2. Verificación de CHECK Constraint en Detalle (Debe fallar si cantidad <= 0)
-- EXPECTATIVA: Error 3819 (Check constraint 'detalle_comanda_chk_1' is violated)
-- INSERT INTO detalle_comanda (id_comanda, id_producto, cantidad, precio_unitario)
-- VALUES (1, 1, 0, 1000.00);

-- 2.3. Verificación de UNIQUE Constraint en Mesas (Debe fallar con mesa duplicada)
-- EXPECTATIVA: Error 1062 (Duplicate entry '1' for key 'mesas.numero_mesa')
-- INSERT INTO mesas (numero_mesa, capacidad, sector) VALUES (1, 4, 'Salón Principal');


-- ============================================================================
-- BLOQUE 3: PRUEBAS DE ALTA (INSERT) Y VERIFICACIÓN DE IDENTIFICADORES IMPARES
-- ============================================================================

-- Apertura de 3 comandas consecutivas desde el Nodo 1 (Salón)
-- Todas deben generarse con id_comanda IMPAR (ej. 1, 3, 5...)
INSERT INTO comandas (id_mesa, id_cliente, mozo, nodo_origen, estado, total, historial_estados) VALUES
(1, 1, 'Carlos Gómez', 'NODO_1_SALON', 'ABIERTA', 0.00, 
 JSON_ARRAY(JSON_OBJECT('evento', 'APERTURA', 'hora', NOW(), 'nodo', 'NODO_1_SALON'))),
(3, 2, 'Lucía Fernández', 'NODO_1_SALON', 'ABIERTA', 0.00,
 JSON_ARRAY(JSON_OBJECT('evento', 'APERTURA', 'hora', NOW(), 'nodo', 'NODO_1_SALON'))),
(4, 3, 'Carlos Gómez', 'NODO_1_SALON', 'ABIERTA', 0.00,
 JSON_ARRAY(JSON_OBJECT('evento', 'APERTURA', 'hora', NOW(), 'nodo', 'NODO_1_SALON')));

-- Cargar detalle con especificaciones NoSQL JSON
INSERT INTO detalle_comanda (id_comanda, id_producto, cantidad, precio_unitario, estado_cocina, especificaciones, observaciones)
SELECT 
    c.id_comanda,
    3, -- Bife de Chorizo Angus
    2,
    22500.00,
    'PENDIENTE',
    JSON_OBJECT('punto_carne', 'Jugoso', 'sin_sal', false),
    'Bien caliente la guarnición'
FROM comandas c
WHERE c.id_mesa = 1 AND c.estado = 'ABIERTA'
LIMIT 1;

-- Cargar ítem secundario (Bebida)
INSERT INTO detalle_comanda (id_comanda, id_producto, cantidad, precio_unitario, estado_cocina, especificaciones)
SELECT 
    c.id_comanda,
    11, -- Cerveza IPA
    2,
    5500.00,
    'ENTREGADO',
    JSON_OBJECT('copas_frias', true)
FROM comandas c
WHERE c.id_mesa = 1 AND c.estado = 'ABIERTA'
LIMIT 1;


-- ============================================================================
-- BLOQUE 4: PRUEBAS DE MODIFICACIÓN (UPDATE) Y CÁLCULO ATÓMICO
-- ============================================================================

-- 4.1. Actualizar total de la comanda calculando subtotales generados
UPDATE comandas c
SET total = (SELECT COALESCE(SUM(subtotal), 0) FROM detalle_comanda WHERE id_comanda = c.id_comanda),
    estado = 'EN_PREPARACION'
WHERE c.id_mesa = 1 AND c.estado = 'ABIERTA';

-- 4.2. Cambiar estado de mesa a OCUPADA
UPDATE mesas SET estado = 'OCUPADA' WHERE id_mesa IN (1, 3, 4);


-- ============================================================================
-- BLOQUE 5: PRUEBAS DE BAJA (DELETE: FÍSICA Y LÓGICA)
-- ============================================================================

-- 5.1. Baja Lógica: Cancelación de la comanda de la Mesa 4
UPDATE comandas
SET estado = 'CANCELADA',
    fecha_cierre = NOW(),
    historial_estados = JSON_ARRAY_APPEND(
        historial_estados,
        '$',
        JSON_OBJECT('evento', 'CANCELACION', 'motivo', 'Los comensales se retiraron')
    )
WHERE id_mesa = 4 AND estado = 'ABIERTA';

-- Liberar mesa cancelada
UPDATE mesas SET estado = 'LIBRE' WHERE id_mesa = 4;


-- ============================================================================
-- BLOQUE 6: FACTURACIÓN, COBRO Y OPERACIONES NoSQL
-- ============================================================================

-- Registro de pago con metadatos JSON para la comanda de Mesa 1
SET @id_comanda_pago = (SELECT id_comanda FROM comandas WHERE id_mesa = 1 AND estado != 'CANCELADA' LIMIT 1);

INSERT INTO pagos (
    id_comanda,
    metodo_pago,
    monto_total,
    metadatos_fiscales,
    nodo_caja
) VALUES (
    @id_comanda_pago,
    'TRANSFERENCIA_QR',
    (SELECT total FROM comandas WHERE id_comanda = @id_comanda_pago),
    JSON_OBJECT(
        'billetera', 'MercadoPago',
        'cvu_origen', '0000003100012345678901',
        'transaccion_id', 'MP-987123654'
    ),
    'NODO_1_SALON'
);

UPDATE comandas SET estado = 'PAGADA', fecha_cierre = NOW() WHERE id_comanda = @id_comanda_pago;
UPDATE mesas SET estado = 'LIBRE' WHERE id_mesa = 1;


-- ============================================================================
-- BLOQUE 7: EVIDENCIA DE RESULTADOS (IDs Impares, Integridad y NoSQL)
-- ============================================================================

-- 7.1. Comprobación de IDs Impares en Comandas generadas por el Nodo 1
SELECT 
    id_comanda,
    MOD(id_comanda, 2) AS es_impar,
    id_mesa,
    mozo,
    nodo_origen,
    estado,
    total,
    fecha_apertura
FROM comandas;

-- 7.2. Extracción de datos NoSQL JSON desde detalle_comanda
SELECT 
    id_detalle,
    id_comanda,
    id_producto,
    cantidad,
    subtotal,
    especificaciones->>'$.punto_carne' AS punto_carne_solicitado,
    especificaciones->>'$.copas_frias' AS requiere_copas_frias
FROM detalle_comanda;

-- 7.3. Estado de pagos y comprobantes
SELECT 
    id_pago,
    id_comanda,
    metodo_pago,
    monto_total,
    metadatos_fiscales->>'$.billetera' AS pasarela,
    metadatos_fiscales->>'$.transaccion_id' AS transaccion
FROM pagos;

-- 7.4. Estado consolidado de mesas
SELECT id_mesa, numero_mesa, sector, estado FROM mesas ORDER BY numero_mesa;
