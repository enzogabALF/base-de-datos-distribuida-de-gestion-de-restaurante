-- ============================================================================
-- AE4 - TIFAS: SCRIPTS DE ABM COMPLETO - NODO 1 (SALÓN Y CAJA)
-- Operaciones Transaccionales ACID, Integridad y Arquitectura 100% Relacional (SQL Puro)
-- ============================================================================

USE restaurante_db;

-- ============================================================================
-- 1. ALTAS (CREATE)
-- ============================================================================

-- CASO 1.A: Apertura de una nueva comanda en el Salón
-- Paso transaccional: Ocupar la mesa y abrir comanda (generará id_comanda IMPAR: 1, 3, 5...)
START TRANSACTION;

-- 1. Actualizar estado de la mesa seleccionada (Mesa 2)
UPDATE mesas
SET estado = 'OCUPADA'
WHERE id_mesa = 2 AND estado = 'LIBRE';

-- 2. Insertar Comanda
INSERT INTO comandas (
    id_mesa,
    id_cliente,
    mozo,
    nodo_origen,
    estado,
    total
) VALUES (
    2,
    1, -- Cliente Juan Pérez
    'Carlos Gómez',
    'NODO_1_SALON',
    'ABIERTA',
    0.00
);

SET @id_comanda_nueva = LAST_INSERT_ID();

-- 3. Registrar auditoría inicial en la tabla relacional de historial
INSERT INTO historial_estados_comanda (
    id_comanda,
    estado_anterior,
    estado_nuevo,
    operador,
    nodo_emisor,
    observacion
) VALUES (
    @id_comanda_nueva,
    NULL,
    'ABIERTA',
    'Carlos Gómez',
    'NODO_1_SALON',
    'Apertura de mesa y asignación inicial'
);

-- 4. Cargar ítems en el detalle con especificaciones normalizadas
-- Ítem 1: Bife de Chorizo Angus (A punto, con papas rústicas)
INSERT INTO detalle_comanda (
    id_comanda,
    id_producto,
    cantidad,
    precio_unitario,
    estado_cocina,
    punto_coccion,
    apto_celiaco,
    sin_sal,
    observaciones
) VALUES (
    @id_comanda_nueva,
    3, -- Bife de Chorizo Angus 400g
    2,
    22500.00,
    'PENDIENTE',
    'A_PUNTO',
    FALSE,
    FALSE,
    'Uno bien dorado por fuera con papas rústicas'
);

-- Ítem 2: Empanada Criolla
INSERT INTO detalle_comanda (
    id_comanda,
    id_producto,
    cantidad,
    precio_unitario,
    estado_cocina,
    punto_coccion,
    apto_celiaco,
    sin_sal,
    observaciones
) VALUES (
    @id_comanda_nueva,
    1, -- Empanada Criolla
    4,
    3200.00,
    'PENDIENTE',
    'NO_APLICA',
    FALSE,
    FALSE,
    'Servir bien calientes con rodajas de limón'
);

-- Ítem 3: Bebida (Agua Mineral)
INSERT INTO detalle_comanda (
    id_comanda,
    id_producto,
    cantidad,
    precio_unitario,
    estado_cocina,
    punto_coccion,
    apto_celiaco,
    sin_sal,
    observaciones
) VALUES (
    @id_comanda_nueva,
    9, -- Agua Mineral sin Gas
    2,
    2800.00,
    'ENTREGADO', -- Despacho inmediato en salón
    'NO_APLICA',
    TRUE,
    TRUE,
    'Con hielo'
);

-- 5. Actualizar total de la comanda en base a la columna generada STORED (subtotal)
UPDATE comandas
SET total = (SELECT COALESCE(SUM(subtotal), 0) FROM detalle_comanda WHERE id_comanda = @id_comanda_nueva)
WHERE id_comanda = @id_comanda_nueva;

COMMIT;


-- CASO 1.B: Adición de un nuevo cliente fidelizado desde Salón
INSERT INTO clientes (
    nombre_completo,
    cuit_dni,
    telefono,
    email,
    puntos_fidelidad
) VALUES (
    'Esteban Quito',
    '20-11223344-5',
    '11-7788-9900',
    'esteban.quito@email.com',
    10
);


-- ============================================================================
-- 2. MODIFICACIONES (UPDATE)
-- ============================================================================

-- CASO 2.A: Agregar un nuevo plato a comanda abierta y registrar historial relacional
START TRANSACTION;

SET @comanda_activa = @id_comanda_nueva;

-- Agregar postre a la comanda
INSERT INTO detalle_comanda (
    id_comanda,
    id_producto,
    cantidad,
    precio_unitario,
    estado_cocina,
    punto_coccion,
    apto_celiaco,
    sin_sal,
    observaciones
) VALUES (
    @comanda_activa,
    7, -- Volcán de Chocolate
    1,
    7200.00,
    'PENDIENTE',
    'NO_APLICA',
    FALSE,
    FALSE,
    'Para compartir con dos cucharas'
);

-- Recalcular total de la comanda
UPDATE comandas
SET total = (SELECT SUM(subtotal) FROM detalle_comanda WHERE id_comanda = @comanda_activa)
WHERE id_comanda = @comanda_activa;

-- Registrar evento en la tabla de historial
INSERT INTO historial_estados_comanda (
    id_comanda,
    estado_anterior,
    estado_nuevo,
    operador,
    nodo_emisor,
    observacion
) VALUES (
    @comanda_activa,
    'ABIERTA',
    'ABIERTA',
    'Carlos Gómez',
    'NODO_1_SALON',
    'Adición de postre Volcán de Chocolate'
);

COMMIT;


-- CASO 2.B: Cambio de mozo asignado con registro relacional de trazabilidad
START TRANSACTION;

UPDATE comandas
SET mozo = 'Lucía Fernández'
WHERE id_comanda = @comanda_activa;

INSERT INTO historial_estados_comanda (
    id_comanda,
    estado_anterior,
    estado_nuevo,
    operador,
    nodo_emisor,
    observacion
) VALUES (
    @comanda_activa,
    'ABIERTA',
    'ABIERTA',
    'Supervisor Salón',
    'NODO_1_SALON',
    'Reasignación de mozo de Carlos Gómez a Lucía Fernández'
);

COMMIT;


-- ============================================================================
-- 3. BAJAS (DELETE: LÓGICA Y FÍSICA)
-- ============================================================================

-- CASO 3.A: Baja Física controlada (Eliminar ítem de detalle antes de preparación)
START TRANSACTION;

DELETE FROM detalle_comanda
WHERE id_comanda = @comanda_activa
  AND id_producto = 7
  AND estado_cocina = 'PENDIENTE';

-- Recalcular total
UPDATE comandas
SET total = (SELECT COALESCE(SUM(subtotal), 0) FROM detalle_comanda WHERE id_comanda = @comanda_activa)
WHERE id_comanda = @comanda_activa;

-- Registrar en historial de auditoría
INSERT INTO historial_estados_comanda (
    id_comanda,
    estado_anterior,
    estado_nuevo,
    operador,
    nodo_emisor,
    observacion
) VALUES (
    @comanda_activa,
    'ABIERTA',
    'ABIERTA',
    'Lucía Fernández',
    'NODO_1_SALON',
    'Baja física de postre Volcán por desistimiento del comensal antes de marcha'
);

COMMIT;


-- CASO 3.B: Baja Lógica (Cancelación total de comanda con motivo)
START TRANSACTION;

INSERT INTO comandas (id_mesa, mozo, nodo_origen, estado, total)
VALUES (5, 'Carlos Gómez', 'NODO_1_SALON', 'ABIERTA', 0.00);

SET @id_cancelar = LAST_INSERT_ID();

-- Baja lógica en la entidad comanda
UPDATE comandas
SET estado = 'CANCELADA',
    motivo_cancelacion = 'Error involuntario de carga de mesa por el mozo',
    fecha_cierre = NOW()
WHERE id_comanda = @id_cancelar;

-- Auditoría relacional del evento de cancelación
INSERT INTO historial_estados_comanda (
    id_comanda,
    estado_anterior,
    estado_nuevo,
    operador,
    nodo_emisor,
    observacion
) VALUES (
    @id_cancelar,
    'ABIERTA',
    'CANCELADA',
    'Jefe de Salón',
    'NODO_1_SALON',
    'Cancelación autorizada: Error de carga de mesa'
);

COMMIT;


-- ============================================================================
-- 4. CIERRE Y FACTURACIÓN (TRANSACCIÓN DE PAGO / CAJA)
-- ============================================================================

START TRANSACTION;

-- 1. Transición de comanda a PAGADA
UPDATE comandas
SET estado = 'PAGADA',
    fecha_cierre = NOW()
WHERE id_comanda = @comanda_activa;

-- 2. Registrar en historial relacional
INSERT INTO historial_estados_comanda (
    id_comanda,
    estado_anterior,
    estado_nuevo,
    operador,
    nodo_emisor,
    observacion
) VALUES (
    @comanda_activa,
    'ABIERTA',
    'PAGADA',
    'Cajero Salón 1',
    'NODO_1_SALON',
    'Liquidación y cobro de ticket fiscal'
);

-- 3. Inserción de Pago 100% Relacional
INSERT INTO pagos (
    id_comanda,
    metodo_pago,
    tipo_comprobante,
    numero_comprobante,
    codigo_autorizacion,
    monto_total,
    nodo_caja
) VALUES (
    @comanda_activa,
    'TARJETA_CREDITO',
    'FACTURA_B',
    '0001-00004521',
    'AUT-VISA-9821',
    (SELECT total FROM comandas WHERE id_comanda = @comanda_activa),
    'NODO_1_SALON'
);

-- 4. Sumar puntos de fidelidad al cliente (1 punto por cada $500)
UPDATE clientes
SET puntos_fidelidad = puntos_fidelidad + FLOOR((SELECT total FROM comandas WHERE id_comanda = @comanda_activa) / 500)
WHERE id_cliente = (SELECT id_cliente FROM comandas WHERE id_comanda = @comanda_activa);

-- 5. Liberar la mesa
UPDATE mesas
SET estado = 'LIBRE'
WHERE id_mesa = (SELECT id_mesa FROM comandas WHERE id_comanda = @comanda_activa);

COMMIT;


-- ============================================================================
-- 5. CONSULTAS Y ANÁLISIS RELACIONAL (READ)
-- ============================================================================

-- Consulta 5.1: Estado actual del Salón (Mesas, comandas y total acumulado)
SELECT 
    m.numero_mesa,
    m.capacidad,
    m.sector,
    m.estado AS estado_mesa,
    c.id_comanda,
    c.mozo,
    c.total AS total_acumulado,
    c.estado AS estado_comanda
FROM mesas m
LEFT JOIN comandas c ON m.id_mesa = c.id_mesa AND c.estado IN ('ABIERTA', 'EN_PREPARACION', 'LISTA_PARA_SERVIR')
ORDER BY m.numero_mesa;

-- Consulta 5.2: Detalle de pedidos activos con preferencias culinarias normalizadas
SELECT 
    d.id_detalle,
    d.id_comanda,
    p.nombre AS plato,
    d.cantidad,
    d.punto_coccion,
    d.apto_celiaco,
    d.sin_sal,
    d.subtotal,
    d.observaciones
FROM detalle_comanda d
JOIN productos_menu p ON d.id_producto = p.id_producto
WHERE d.id_comanda = @comanda_activa;

-- Consulta 5.3: Historial cronológico relacional de auditoría de una comanda
SELECT 
    h.id_historial,
    h.id_comanda,
    h.estado_anterior,
    h.estado_nuevo,
    h.operador,
    h.nodo_emisor,
    h.observacion,
    h.fecha_cambio
FROM historial_estados_comanda h
WHERE h.id_comanda = @comanda_activa
ORDER BY h.fecha_cambio ASC;

-- Consulta 5.4: Arqueo de Caja del Nodo 1 agrupado por método y tipo de comprobante
SELECT 
    p.metodo_pago,
    p.tipo_comprobante,
    COUNT(p.id_pago) AS cantidad_operaciones,
    SUM(p.monto_total) AS total_recaudado
FROM pagos p
WHERE p.nodo_caja = 'NODO_1_SALON'
GROUP BY p.metodo_pago, p.tipo_comprobante;
