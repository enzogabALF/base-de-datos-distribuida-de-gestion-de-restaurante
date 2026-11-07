-- ============================================================================
-- AE4 - TIFAS: SCRIPTS DE ABM COMPLETO - NODO 2 (COCINA Y STOCK)
-- Operaciones Transaccionales ACID, Control de Inventario y Despacho de Comandas
-- ============================================================================

USE restaurante_db;

-- ============================================================================
-- 1. ALTAS (CREATE)
-- ============================================================================

-- CASO 1.A: Recepción de mercadería de proveedor (Ingreso a Stock)
START TRANSACTION;

SET @prod_id = 3; -- Bife de Chorizo Angus 400g
SET @cant_ingreso = 20;

-- 1. Obtener stock actual
SELECT stock_disponible INTO @stock_actual 
FROM productos_menu 
WHERE id_producto = @prod_id FOR UPDATE;

-- 2. Registrar en movimientos_stock
INSERT INTO movimientos_stock (
    id_producto,
    tipo_movimiento,
    cantidad,
    stock_previo,
    stock_posterior,
    motivo,
    nodo_origen
) VALUES (
    @prod_id,
    'INGRESO_PROVEEDOR',
    @cant_ingreso,
    @stock_actual,
    (@stock_actual + @cant_ingreso),
    'Remito Nro. 0004-9812 Cabaña Las Lilas',
    'NODO_2_COCINA'
);

-- 3. Actualizar stock en catálogo de productos
UPDATE productos_menu
SET stock_disponible = stock_disponible + @cant_ingreso
WHERE id_producto = @prod_id;

COMMIT;


-- CASO 1.B: Apertura de Comanda Interna desde Cocina (Muestra / Degustación)
-- El Nodo 2 (offset=2) generará IDs PARES (2, 4, 6...)
START TRANSACTION;

INSERT INTO comandas (
    id_mesa,
    id_cliente,
    mozo,
    nodo_origen,
    estado,
    total,
    historial_estados
) VALUES (
    10, -- Barra
    NULL,
    'Chef Ejecutivo',
    'NODO_2_COCINA',
    'ABIERTA',
    0.00,
    JSON_ARRAY(
        JSON_OBJECT(
            'evento', 'APERTURA_COCINA_DEGUSTACION',
            'timestamp', NOW(),
            'autorizado_por', 'Jefe de Cocina'
        )
    )
);

SET @id_comanda_cocina = LAST_INSERT_ID();

INSERT INTO detalle_comanda (
    id_comanda,
    id_producto,
    cantidad,
    precio_unitario,
    estado_cocina,
    especificaciones,
    observaciones
) VALUES (
    @id_comanda_cocina,
    5, -- Sorrentinos
    1,
    17800.00,
    'EN_COCCION',
    JSON_OBJECT('control_calidad', true, 'degustacion_salsa', 'Filetto'),
    'Prueba de lote de pasta fresca'
);

UPDATE comandas
SET total = (SELECT SUM(subtotal) FROM detalle_comanda WHERE id_comanda = @id_comanda_cocina)
WHERE id_comanda = @id_comanda_cocina;

COMMIT;


-- ============================================================================
-- 2. MODIFICACIONES (UPDATE - GESTIÓN DE MARCHAS Y CONSUMO DE STOCK)
-- ============================================================================

-- CASO 2.A: Tomar una comanda recibida del Salón e iniciar cocción
START TRANSACTION;

-- Seleccionar la primera comanda disponible del salón
SET @comanda_a_marchar = 1;

-- Actualizar estado general de la comanda
UPDATE comandas
SET estado = 'EN_PREPARACION',
    historial_estados = JSON_ARRAY_APPEND(
        historial_estados,
        '$',
        JSON_OBJECT(
            'evento', 'INICIO_PREPARACION',
            'timestamp', NOW(),
            'nodo', 'NODO_2_COCINA',
            'responsable', 'Cocinero Turno Tarde'
        )
    )
WHERE id_comanda = @comanda_a_marchar;

-- Actualizar las líneas de detalle culinarias que estaban pendientes
UPDATE detalle_comanda
SET estado_cocina = 'EN_COCCION'
WHERE id_comanda = @comanda_a_marchar 
  AND estado_cocina = 'PENDIENTE'
  AND id_producto IN (SELECT id_producto FROM productos_menu WHERE categoria IN ('ENTRADA', 'PLATO_PRINCIPAL', 'POSTRE'));

-- Descontar del stock disponible de cada producto preparado
UPDATE productos_menu p
JOIN detalle_comanda d ON p.id_producto = d.id_producto
SET p.stock_disponible = p.stock_disponible - d.cantidad
WHERE d.id_comanda = @comanda_a_marchar;

COMMIT;


-- CASO 2.B: Finalización de platos y aviso a Salón (LISTA_PARA_SERVIR)
START TRANSACTION;

UPDATE detalle_comanda
SET estado_cocina = 'LISTO'
WHERE id_comanda = @comanda_a_marchar AND estado_cocina = 'EN_COCCION';

UPDATE comandas
SET estado = 'LISTA_PARA_SERVIR',
    historial_estados = JSON_ARRAY_APPEND(
        historial_estados,
        '$',
        JSON_OBJECT(
            'evento', 'CAMPANA_DESPACHO_LISTO',
            'timestamp', NOW(),
            'nodo', 'NODO_2_COCINA'
        )
    )
WHERE id_comanda = @comanda_a_marchar;

COMMIT;


-- ============================================================================
-- 3. BAJAS (DELETE / CONTROL DE MERMAS Y ROTURAS)
-- ============================================================================

-- CASO 3.A: Registro de Merma / Baja de Insumo por vencimiento o rotura
START TRANSACTION;

SET @prod_merma = 8; -- Flan Casero
SET @cant_merma = 3;

SELECT stock_disponible INTO @stock_antes_merma 
FROM productos_menu 
WHERE id_producto = @prod_merma FOR UPDATE;

INSERT INTO movimientos_stock (
    id_producto,
    tipo_movimiento,
    cantidad,
    stock_previo,
    stock_posterior,
    motivo,
    nodo_origen
) VALUES (
    @prod_merma,
    'MERMA_ROTURA',
    @cant_merma,
    @stock_antes_merma,
    (@stock_antes_merma - @cant_merma),
    'Pérdida de cadena de frío en heladera de postres',
    'NODO_2_COCINA'
);

UPDATE productos_menu
SET stock_disponible = stock_disponible - @cant_merma
WHERE id_producto = @prod_merma;

COMMIT;


-- ============================================================================
-- 4. CONSULTAS Y ANÁLISIS NoSQL / SQL (COMANDERA Y STOCK)
-- ============================================================================

-- Consulta 4.1: Pantalla / Comandera digital de cocina con especificaciones NoSQL
SELECT 
    c.id_comanda,
    c.nodo_origen,
    c.mozo,
    m.numero_mesa,
    m.sector,
    p.nombre AS plato,
    d.cantidad,
    d.estado_cocina,
    d.especificaciones->>'$.punto_carne' AS punto,
    d.especificaciones->>'$.temperatura' AS temp,
    d.observaciones
FROM comandas c
JOIN mesas m ON c.id_mesa = m.id_mesa
JOIN detalle_comanda d ON c.id_comanda = d.id_comanda
JOIN productos_menu p ON d.id_producto = p.id_producto
WHERE d.estado_cocina IN ('PENDIENTE', 'EN_COCCION')
ORDER BY c.fecha_apertura ASC;

-- Consulta 4.2: Alerta de stock crítico (productos con menos de 30 unidades)
SELECT 
    id_producto,
    nombre,
    categoria,
    stock_disponible,
    CASE 
        WHEN stock_disponible <= 15 THEN 'CRÍTICO: REPONER URGENTE'
        WHEN stock_disponible <= 30 THEN 'ALERTA: STOCK BAJO'
        ELSE 'NORMAL'
    END AS semaforo_inventario
FROM productos_menu
WHERE activo = TRUE
ORDER BY stock_disponible ASC;

-- Consulta 4.3: Historial / Kardex de movimientos de stock registrados desde Cocina
SELECT 
    ms.id_movimiento,
    p.nombre AS producto,
    ms.tipo_movimiento,
    ms.cantidad,
    ms.stock_previo,
    ms.stock_posterior,
    ms.motivo,
    ms.nodo_origen,
    ms.fecha_movimiento
FROM movimientos_stock ms
JOIN productos_menu p ON ms.id_producto = p.id_producto
ORDER BY ms.fecha_movimiento DESC;
