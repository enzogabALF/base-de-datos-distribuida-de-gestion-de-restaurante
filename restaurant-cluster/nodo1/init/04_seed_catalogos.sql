-- ============================================================================
-- AE4 - TIFAS: DATOS SEMILLA DE CATÁLOGOS BASE (NODO 1 - SALÓN / CAJA)
-- Inicialización de datos maestros compartidos: Mesas, Menú, Clientes y Stock Base
-- ============================================================================

SET sql_log_bin = 0;

USE restaurante_db;

-- 1. Semilla de Clientes Iniciales
INSERT INTO clientes (nombre_completo, cuit_dni, telefono, email, puntos_fidelidad) VALUES
('Juan Pérez', '20-34567890-9', '11-4567-8901', 'juan.perez@email.com', 150),
('María Rodríguez', '27-38123456-4', '11-6789-0123', 'maria.rodriguez@email.com', 80),
('Martín Palermo', '20-23456789-2', '11-3456-7890', 'martin.palermo@email.com', 320),
('Lucía Morales', '27-40987654-1', '11-5678-9012', 'lucia.morales@email.com', 50);

-- 2. Semilla de Mesas de Salón y Terraza
INSERT INTO mesas (numero_mesa, capacidad, sector, estado) VALUES
(1, 2, 'Salón Principal', 'LIBRE'),
(2, 4, 'Salón Principal', 'LIBRE'),
(3, 4, 'Salón Principal', 'LIBRE'),
(4, 6, 'Salón Principal', 'LIBRE'),
(5, 8, 'Salón Principal', 'LIBRE'),
(6, 2, 'Terraza Exterior', 'LIBRE'),
(7, 4, 'Terraza Exterior', 'LIBRE'),
(8, 4, 'Terraza Exterior', 'LIBRE'),
(9, 2, 'Barra / Cocktails', 'LIBRE'),
(10, 2, 'Barra / Cocktails', 'LIBRE');

-- 3. Semilla de Productos de Menú
INSERT INTO productos_menu (id_producto, nombre, categoria, precio, stock_disponible) VALUES
(1, 'Empanada Criolla Cortada a Cuchillo', 'ENTRADA', 3200.00, 80),
(2, 'Provoleta a la Parrilla con Orégano', 'ENTRADA', 8500.00, 40),
(3, 'Bife de Chorizo Angus 400g', 'PLATO_PRINCIPAL', 22500.00, 35),
(4, 'Ojo de Bife con Papas Rústicas', 'PLATO_PRINCIPAL', 24000.00, 30),
(5, 'Sorrentinos Caseros de Salmón y Ricota', 'PLATO_PRINCIPAL', 17800.00, 25),
(6, 'Milanesa Napolitana con Papas Fritas', 'PLATO_PRINCIPAL', 16500.00, 50),
(7, 'Volcán de Chocolate con Helado', 'POSTRE', 7200.00, 20),
(8, 'Flan Casero con Dulce de Leche y Crema', 'POSTRE', 5800.00, 30),
(9, 'Agua Mineral sin Gas 500ml', 'BEBIDA', 2800.00, 120),
(10, 'Gaseosa Cola 500ml', 'BEBIDA', 3200.00, 100),
(11, 'Cerveza Artesanal IPA 500ml', 'BEBIDA', 5500.00, 60),
(12, 'Vino Malbec Reserva 750ml', 'BEBIDA', 18900.00, 45);

-- 4. Semilla de Registro de Movimientos de Stock Inicial
INSERT INTO movimientos_stock (id_producto, tipo_movimiento, cantidad, stock_previo, stock_posterior, motivo, nodo_origen) VALUES
(1, 'INGRESO_PROVEEDOR', 80, 0, 80, 'Carga de stock inicial de apertura', 'NODO_1_SALON'),
(2, 'INGRESO_PROVEEDOR', 40, 0, 40, 'Carga de stock inicial de apertura', 'NODO_1_SALON'),
(3, 'INGRESO_PROVEEDOR', 35, 0, 35, 'Carga de stock inicial de apertura', 'NODO_1_SALON'),
(4, 'INGRESO_PROVEEDOR', 30, 0, 30, 'Carga de stock inicial de apertura', 'NODO_1_SALON'),
(5, 'INGRESO_PROVEEDOR', 25, 0, 25, 'Carga de stock inicial de apertura', 'NODO_1_SALON'),
(6, 'INGRESO_PROVEEDOR', 50, 0, 50, 'Carga de stock inicial de apertura', 'NODO_1_SALON'),
(7, 'INGRESO_PROVEEDOR', 20, 0, 20, 'Carga de stock inicial de apertura', 'NODO_1_SALON'),
(8, 'INGRESO_PROVEEDOR', 30, 0, 30, 'Carga de stock inicial de apertura', 'NODO_1_SALON'),
(9, 'INGRESO_PROVEEDOR', 120, 0, 120, 'Carga de stock inicial de apertura', 'NODO_1_SALON'),
(10, 'INGRESO_PROVEEDOR', 100, 0, 100, 'Carga de stock inicial de apertura', 'NODO_1_SALON'),
(11, 'INGRESO_PROVEEDOR', 60, 0, 60, 'Carga de stock inicial de apertura', 'NODO_1_SALON'),
(12, 'INGRESO_PROVEEDOR', 45, 0, 45, 'Carga de stock inicial de apertura', 'NODO_1_SALON');

SET sql_log_bin = 1;
