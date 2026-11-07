-- ============================================================================
-- AE4 - TIFAS: SCRIPTS DE ABM COMPLETO - NODO 1 (SALÓN Y CAJA)
-- Operaciones Transaccionales ACID, Integridad y Manejo Híbrido NoSQL (JSON)
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

-- 2. Insertar Comanda con trazabilidad NoSQL inicial
INSERT INTO comandas (
    id_mesa,
    id_cliente,
    mozo,
    nodo_origen,
    estado,
    total,
    historial_estados
) VALUES (
    2,
    1, -- Cliente Juan Pérez
    'Carlos Gómez',
    'NODO_1_SALON',
    'ABIERTA',
    0.00,
    JSON_ARRAY(
        JSON_OBJECT(
            'evento', 'APERTURA_COMANDA',
            'timestamp', NOW(),
            'operador', 'Carlos Gómez',
            'nodo', 'NODO_1_SALON'
        )
    )
);

-- Obtener el ID de la comanda recién generada
SET @id_comanda_nueva = LAST_INSERT_ID();

-- 3. Cargar ítems en el detalle con especificaciones culinarias NoSQL (JSON)
-- Ítem 1: Bife de Chorizo con punto de cocción y especificación
INSERT INTO detalle_comanda (
    id_comanda,
    id_producto,
    cantidad,
    precio_unitario,
    estado_cocina,
    especificaciones,
    observaciones
) VALUES (
    @id_comanda_nueva,
    3, -- Bife de Chorizo Angus 400g
    2,
    22500.00,
    'PENDIENTE',
    JSON_OBJECT(
        'punto_carne', 'A punto',
        'sin_sal', false,
        'guarnicion', 'Papas rústicas'
    ),
    'Uno bien dorado por fuera'
);

-- Ítem 2: Empanada Criolla
INSERT INTO detalle_comanda (
    id_comanda,
    id_producto,
    cantidad,
    precio_unitario,
    estado_cocina,
    especificaciones,
    observaciones
) VALUES (
    @id_comanda_nueva,
    1, -- Empanada Criolla
    4,
    3200.00,
    'PENDIENTE',
    JSON_OBJECT(
        'temperatura', 'Muy caliente',
        'limon', true
    ),
    NULL
);

-- Ítem 3: Bebida (Agua Mineral)
INSERT INTO detalle_comanda (
    id_comanda,
    id_producto,
    cantidad,
    precio_unitario,
    estado_cocina,
    especificaciones,
    observaciones
) VALUES (
    @id_comanda_nueva,
    9, -- Agua Mineral sin Gas
    2,
    2800.00,
    'ENTREGADO', -- Las bebidas directas del salón se marcan entregadas
    JSON_OBJECT(
        'hielo', true,
        'rodaja_limon', false
    ),
    NULL
);

-- 4. Actualizar total de la comanda en base a la columna generada STORED (subtotal)
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

-- CASO 2.A: Agregar un nuevo plato a comanda abierta y registrar evento en NoSQL
START TRANSACTION;

SET @comanda_activa = @id_comanda_nueva;

-- Agregar postre a la comanda
INSERT INTO detalle_comanda (
    id_comanda,
    id_producto,
    cantidad,
    precio_unitario,
    estado_cocina,
    especificaciones,
    observaciones
) VALUES (
    @comanda_activa,
    7, -- Volcán de Chocolate
    1,
    7200.00,
    'PENDIENTE',
    JSON_OBJECT('cucharas_extra', 2, 'sin_gluten', false),
    'Para compartir'
);

-- Recalcular total de la comanda y anexar evento al historial JSON
UPDATE comandas
SET total = (SELECT SUM(subtotal) FROM detalle_comanda WHERE id_comanda = @comanda_activa),
    historial_estados = JSON_ARRAY_APPEND(
        historial_estados,
        '$',
        JSON_OBJECT(
            'evento', 'ADICION_ITEM',
            'timestamp', NOW(),
            'producto_id', 7,
            'cantidad', 1
        )
    )
WHERE id_comanda = @comanda_activa;

COMMIT;


-- CASO 2.B: Cambio de mozo asignado o cambio de estado de comanda
UPDATE comandas
SET mozo = 'Lucía Fernández',
    historial_estados = JSON_ARRAY_APPEND(
        historial_estados,
        '$',
        JSON_OBJECT(
            'evento', 'CAMBIO_MOZO',
            'timestamp', NOW(),
            'mozo_anterior', 'Carlos Gómez',
            'nuevo_mozo', 'Lucía Fernández'
        )
    )
WHERE id_comanda = @comanda_activa;


-- ============================================================================
-- 3. BAJAS (DELETE: LÓGICA Y FÍSICA)
-- ============================================================================

-- CASO 3.A: Baja Física controlada (Eliminar ítem de detalle antes de preparación)
-- Supongamos que el cliente decide cancelar el postre antes de cocinarse
START TRANSACTION;

-- Eliminación física del ítem en detalle
DELETE FROM detalle_comanda
WHERE id_comanda = @comanda_activa
  AND id_producto = 7
  AND estado_cocina = 'PENDIENTE';

-- Recalcular total y registrar en auditoría NoSQL
UPDATE comandas
SET total = (SELECT COALESCE(SUM(subtotal), 0) FROM detalle_comanda WHERE id_comanda = @comanda_activa),
    historial_estados = JSON_ARRAY_APPEND(
        historial_estados,
        '$',
        JSON_OBJECT(
            'evento', 'BAJA_FISICA_ITEM',
            'timestamp', NOW(),
            'producto_id', 7,
            'motivo', 'Desistimiento de cliente antes de marchar'
        )
    )
WHERE id_comanda = @comanda_activa;

COMMIT;


-- CASO 3.B: Baja Lógica (Cancelación total de comanda con motivo)
-- Simulación de apertura y cancelación inmediata de comanda por error
START TRANSACTION;

INSERT INTO comandas (id_mesa, mozo, nodo_origen, estado, total, historial_estados)
VALUES (
    5,
    'Carlos Gómez',
    'NODO_1_SALON',
    'ABIERTA',
    0.00,
    JSON_ARRAY(JSON_OBJECT('evento', 'APERTURA', 'timestamp', NOW()))
);

SET @id_cancelar = LAST_INSERT_ID();

-- Baja lógica: no se destruye el registro, se cambia el estado y se anexa motivo
UPDATE comandas
SET estado = 'CANCELADA',
    fecha_cierre = NOW(),
    historial_estados = JSON_ARRAY_APPEND(
        historial_estados,
        '$',
        JSON_OBJECT(
            'evento', 'CANCELACION_LOGICA',
            'timestamp', NOW(),
            'motivo', 'Error de carga de mesa por el mozo',
            'autorizado_por', 'Jefe de Salón'
        )
    )
WHERE id_comanda = @id_cancelar;

COMMIT;


-- ============================================================================
-- 4. CIERRE Y FACTURACIÓN (TRANSACCIÓN DE PAGO / CAJA)
-- ============================================================================

START TRANSACTION;

-- 1. Transición de comanda a PAGADA
UPDATE comandas
SET estado = 'PAGADA',
    fecha_cierre = NOW(),
    historial_estados = JSON_ARRAY_APPEND(
        historial_estados,
        '$',
        JSON_OBJECT(
            'evento', 'CIERRE_Y_PAGO',
            'timestamp', NOW(),
            'cajero', 'Caja Salón 1'
        )
    )
WHERE id_comanda = @comanda_activa;

-- 2. Inserción de Pago con metadatos fiscales semiestructurados (NoSQL JSON)
INSERT INTO pagos (
    id_comanda,
    metodo_pago,
    monto_total,
    metadatos_fiscales,
    nodo_caja
) VALUES (
    @comanda_activa,
    'TARJETA_CREDITO',
    (SELECT total FROM comandas WHERE id_comanda = @comanda_activa),
    JSON_OBJECT(
        'tipo_comprobante', 'FACTURA_B',
        'numero_ticket', '0001-00004521',
        'cae', '74389218942109',
        'tarjeta', JSON_OBJECT(
            'marca', 'VISA',
            'ultimos_cuatro', '4321',
            'cuotas', 1,
            'autorizacion_posnet', 'AP8921'
        )
    ),
    'NODO_1_SALON'
);

-- 3. Sumar puntos de fidelidad al cliente (1 punto por cada $500)
UPDATE clientes
SET puntos_fidelidad = puntos_fidelidad + FLOOR((SELECT total FROM comandas WHERE id_comanda = @comanda_activa) / 500)
WHERE id_cliente = (SELECT id_cliente FROM comandas WHERE id_comanda = @comanda_activa);

-- 4. Liberar la mesa
UPDATE mesas
SET estado = 'LIBRE'
WHERE id_mesa = (SELECT id_mesa FROM comandas WHERE id_comanda = @comanda_activa);

COMMIT;


-- ============================================================================
-- 5. CONSULTAS Y ANÁLISIS NoSQL / SQL (READ)
-- ============================================================================

-- Consulta 5.1: Vista rápida del estado actual del Salón
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

-- Consulta 5.2: Búsqueda NoSQL - Extracción de campos JSON en especificaciones culinarias
SELECT 
    d.id_detalle,
    d.id_comanda,
    p.nombre AS plato,
    d.cantidad,
    JSON_UNQUOTE(JSON_EXTRACT(d.especificaciones, '$.punto_carne')) AS punto_solicitado,
    JSON_UNQUOTE(JSON_EXTRACT(d.especificaciones, '$.guarnicion')) AS guarnicion_elegida,
    d.especificaciones->>'$.temperatura' AS temperatura,
    d.observaciones
FROM detalle_comanda d
JOIN productos_menu p ON d.id_producto = p.id_producto
WHERE d.especificaciones IS NOT NULL;

-- Consulta 5.3: Auditoría NoSQL - Visualizar historial cronológico de eventos de la comanda
SELECT 
    c.id_comanda,
    c.mozo,
    c.estado,
    c.historial_estados
FROM comandas c
WHERE c.id_comanda = @comanda_activa;

-- Consulta 5.4: Arqueo de Caja del Nodo 1 agrupado por método de pago y desglose fiscal
SELECT 
    p.metodo_pago,
    COUNT(p.id_pago) AS cantidad_operaciones,
    SUM(p.monto_total) AS total_recaudado,
    JSON_UNQUOTE(JSON_EXTRACT(p.metadatos_fiscales, '$.tipo_comprobante')) AS tipo_comprobante
FROM pagos p
WHERE p.nodo_caja = 'NODO_1_SALON'
GROUP BY p.metodo_pago, tipo_comprobante;
