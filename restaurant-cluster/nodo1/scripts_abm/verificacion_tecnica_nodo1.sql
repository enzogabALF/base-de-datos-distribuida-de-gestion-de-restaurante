-- ============================================================================
-- AE4 - TIFAS: PROTOCOLO DE VERIFICACIÓN TÉCNICA Y PRUEBAS ABM (NODO 1 - SALÓN)
-- Cátedra: Gestión Avanzada de Bases de Datos - Arquitectura 100% Relacional (SQL Puro)
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
INSERT INTO comandas (id_mesa, id_cliente, mozo, nodo_origen, estado, total) VALUES
(1, 1, 'Carlos Gómez', 'NODO_1_SALON', 'ABIERTA', 0.00),
(3, 2, 'Lucía Fernández', 'NODO_1_SALON', 'ABIERTA', 0.00),
(4, 3, 'Carlos Gómez', 'NODO_1_SALON', 'ABIERTA', 0.00);

-- Registrar auditoría relacional para la comanda de la Mesa 1
INSERT INTO historial_estados_comanda (id_comanda, estado_anterior, estado_nuevo, operador, nodo_emisor, observacion)
SELECT c.id_comanda, NULL, 'ABIERTA', 'Carlos Gómez', 'NODO_1_SALON', 'Apertura de orden en salón'
FROM comandas c WHERE c.id_mesa = 1 AND c.estado = 'ABIERTA' LIMIT 1;

-- Cargar detalle con atributos normalizados relacionales
INSERT INTO detalle_comanda (id_comanda, id_producto, cantidad, precio_unitario, estado_cocina, punto_coccion, apto_celiaco, sin_sal, observaciones)
SELECT 
    c.id_comanda,
    3, -- Bife de Chorizo Angus
    2,
    22500.00,
    'PENDIENTE',
    'JUGOSO',
    FALSE,
    FALSE,
    'Bien caliente la guarnición de papas rústicas'
FROM comandas c
WHERE c.id_mesa = 1 AND c.estado = 'ABIERTA'
LIMIT 1;

-- Cargar ítem secundario (Bebida)
INSERT INTO detalle_comanda (id_comanda, id_producto, cantidad, precio_unitario, estado_cocina, punto_coccion, apto_celiaco, sin_sal, observaciones)
SELECT 
    c.id_comanda,
    11, -- Cerveza IPA
    2,
    5500.00,
    'ENTREGADO',
    'NO_APLICA',
    FALSE,
    FALSE,
    'Servir con copas frías'
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

-- 5.1. Baja Lógica: Cancelación de la comanda de la Mesa 4 con motivo relacional
UPDATE comandas
SET estado = 'CANCELADA',
    motivo_cancelacion = 'Los comensales se retiraron por demora',
    fecha_cierre = NOW()
WHERE id_mesa = 4 AND estado = 'ABIERTA';

-- Registrar evento en historial relacional
INSERT INTO historial_estados_comanda (id_comanda, estado_anterior, estado_nuevo, operador, nodo_emisor, observacion)
SELECT c.id_comanda, 'ABIERTA', 'CANCELADA', 'Jefe de Salón', 'NODO_1_SALON', 'Cancelación por demora de mesa'
FROM comandas c WHERE c.id_mesa = 4 AND c.estado = 'CANCELADA' LIMIT 1;

-- Liberar mesa cancelada
UPDATE mesas SET estado = 'LIBRE' WHERE id_mesa = 4;


-- ============================================================================
-- BLOQUE 6: FACTURACIÓN Y COBRO RELACIONAL
-- ============================================================================

-- Registro de pago con comprobante y autorización relacional para la comanda de Mesa 1
SET @id_comanda_pago = (SELECT id_comanda FROM comandas WHERE id_mesa = 1 AND estado != 'CANCELADA' LIMIT 1);

INSERT INTO pagos (
    id_comanda,
    metodo_pago,
    tipo_comprobante,
    numero_comprobante,
    codigo_autorizacion,
    monto_total,
    nodo_caja
) VALUES (
    @id_comanda_pago,
    'TRANSFERENCIA_QR',
    'FACTURA_B',
    '0001-00004522',
    'MP-TX-987123',
    (SELECT total FROM comandas WHERE id_comanda = @id_comanda_pago),
    'NODO_1_SALON'
);

UPDATE comandas SET estado = 'PAGADA', fecha_cierre = NOW() WHERE id_comanda = @id_comanda_pago;
UPDATE mesas SET estado = 'LIBRE' WHERE id_mesa = 1;


-- ============================================================================
-- BLOQUE 7: EVIDENCIA DE RESULTADOS (IDs Impares, Integridad y Normalización)
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

-- 7.2. Detalle de comanda relacional con columnas tipadas
SELECT 
    id_detalle,
    id_comanda,
    id_producto,
    cantidad,
    subtotal,
    punto_coccion,
    apto_celiaco,
    sin_sal,
    observaciones
FROM detalle_comanda;

-- 7.3. Auditoría relacional cronológica
SELECT 
    id_historial,
    id_comanda,
    estado_anterior,
    estado_nuevo,
    operador,
    nodo_emisor,
    observacion,
    fecha_cambio
FROM historial_estados_comanda;

-- 7.4. Estado de pagos y comprobantes fiscales
SELECT 
    id_pago,
    id_comanda,
    metodo_pago,
    tipo_comprobante,
    numero_comprobante,
    codigo_autorizacion,
    monto_total
FROM pagos;

-- 7.5. Estado consolidado de mesas
SELECT id_mesa, numero_mesa, sector, estado FROM mesas ORDER BY numero_mesa;
