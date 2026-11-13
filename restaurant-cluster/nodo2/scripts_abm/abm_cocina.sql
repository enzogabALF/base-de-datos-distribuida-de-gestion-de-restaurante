-- ============================================================================
-- AE4 - TIFAS: SCRIPTS DE ABM COMPLETO - NODO 2 (COCINA Y STOCK)
-- Operaciones Transaccionales ACID, Control de Inventario y Despacho de Comandas (SQL Puro)
-- ============================================================================

USE restaurante_db;

-- ============================================================================
-- 1. ALTAS (CREATE)
-- ============================================================================

-- CASO 1.A: Recepción de mercadería de proveedor (Ingreso a Stock)
START TRANSACTION;

SET @prod_id = 3; -- Bife de Chorizo Angus 400g
SET @cant_ingreso = 20;

-- 1. Obtener stock actual con bloqueo pesimista
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
    total
) VALUES (
    10, -- Barra
    NULL,
    'Chef Ejecutivo',
    'NODO_2_COCINA',
    'ABIERTA',
    0.00
);

SET @id_comanda_cocina = LAST_INSERT_ID();

-- Auditoría relacional inicial
INSERT INTO historial_estados_comanda (
    id_comanda,
    estado_anterior,
    estado_nuevo,
    operador,
    nodo_emisor,
    observacion
) VALUES (
    @id_comanda_cocina,
    NULL,
    'ABIERTA',
    'Chef Ejecutivo',
    'NODO_2_COCINA',
    'Apertura interna para control de calidad de pastas'
);

-- Detalle de comanda interno
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
    @id_comanda_cocina,
    5, -- Sorrentinos
    1,
    17800.00,
    'EN_COCCION',
    'NO_APLICA',
    FALSE,
    FALSE,
    'Prueba de lote de pasta fresca con salsa filetto'
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

SET @comanda_a_marchar = 1;

-- Actualizar estado general de la comanda
UPDATE comandas
SET estado = 'EN_PREPARACION'
WHERE id_comanda = @comanda_a_marchar;

-- Registrar transición en el historial relacional
INSERT INTO historial_estados_comanda (
    id_comanda,
    estado_anterior,
    estado_nuevo,
    operador,
    nodo_emisor,
    observacion
) VALUES (
    @comanda_a_marchar,
    'ABIERTA',
    'EN_PREPARACION',
    'Jefe de Partida',
    'NODO_2_COCINA',
    'Ingreso a cocina: inicio de marchas de cocción'
);

-- Actualizar las líneas de detalle culinarias que estaban pendientes
UPDATE detalle_comanda
SET estado_cocina = 'EN_COCCION'
WHERE id_comanda = @comanda_a_marchar 
  AND estado_cocina = 'PENDIENTE'
  AND id_producto IN (SELECT id_producto FROM productos_menu WHERE categoria IN ('ENTRADA', 'PLATO_PRINCIPAL', 'POSTRE'));

-- Bloqueo pesimista de los productos de la comanda (igual que en el Caso 1.A):
-- nadie puede modificar ese stock hasta el COMMIT, así stock_previo es exacto.
SELECT p.id_producto, p.stock_disponible
FROM productos_menu p
WHERE p.id_producto IN (SELECT id_producto FROM detalle_comanda WHERE id_comanda = @comanda_a_marchar)
FOR UPDATE;

-- Registrar en el Kardex (movimientos_stock) la salida por venta, ANTES de descontar,
-- para que stock_previo refleje el valor anterior. Se agrupa por producto: si la comanda
-- tiene dos líneas del mismo plato, se registra un único movimiento con la suma.
INSERT INTO movimientos_stock (
    id_producto,
    tipo_movimiento,
    cantidad,
    stock_previo,
    stock_posterior,
    motivo,
    nodo_origen
)
SELECT
    p.id_producto,
    'VENTA_COMANDA',
    v.cantidad_total,
    p.stock_disponible,
    p.stock_disponible - v.cantidad_total,  -- el CHECK (stock_posterior >= 0) impide vender sin stock
    CONCAT('Marcha de comanda #', @comanda_a_marchar),
    'NODO_2_COCINA'
FROM productos_menu p
JOIN (
    SELECT id_producto, SUM(cantidad) AS cantidad_total
    FROM detalle_comanda
    WHERE id_comanda = @comanda_a_marchar
    GROUP BY id_producto
) v ON v.id_producto = p.id_producto;

-- Descontar del stock disponible de cada producto de la comanda.
-- También se agrupa por producto: un UPDATE con JOIN directo a detalle_comanda
-- actualiza cada fila de productos_menu una sola vez y descontaría solo una línea.
UPDATE productos_menu p
JOIN (
    SELECT id_producto, SUM(cantidad) AS cantidad_total
    FROM detalle_comanda
    WHERE id_comanda = @comanda_a_marchar
    GROUP BY id_producto
) v ON v.id_producto = p.id_producto
SET p.stock_disponible = p.stock_disponible - v.cantidad_total;

COMMIT;


-- CASO 2.B: Finalización de platos y aviso a Salón (LISTA_PARA_SERVIR)
START TRANSACTION;

UPDATE detalle_comanda
SET estado_cocina = 'LISTO'
WHERE id_comanda = @comanda_a_marchar AND estado_cocina = 'EN_COCCION';

UPDATE comandas
SET estado = 'LISTA_PARA_SERVIR'
WHERE id_comanda = @comanda_a_marchar;

INSERT INTO historial_estados_comanda (
    id_comanda,
    estado_anterior,
    estado_nuevo,
    operador,
    nodo_emisor,
    observacion
) VALUES (
    @comanda_a_marchar,
    'EN_PREPARACION',
    'LISTA_PARA_SERVIR',
    'Despachador',
    'NODO_2_COCINA',
    'Campana de despacho: platos listos en bandeja para retirar por mozo'
);

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
-- 4. CONSULTAS Y ANÁLISIS RELACIONAL (COMANDERA Y STOCK)
-- ============================================================================

-- Consulta 4.1: Pantalla / Comandera digital de cocina con especificaciones relacionales
SELECT 
    c.id_comanda,
    c.nodo_origen,
    c.mozo,
    m.numero_mesa,
    m.sector,
    p.nombre AS plato,
    d.cantidad,
    d.estado_cocina,
    d.punto_coccion,
    d.apto_celiaco,
    d.sin_sal,
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
