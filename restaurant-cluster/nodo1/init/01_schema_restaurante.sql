-- ============================================================================
-- AE4 - TIFAS: SISTEMA DISTRIBUIDO DE GESTIÓN GASTRONÓMICA
-- NODO 1: SALÓN Y CAJA (Esquema Global Replicado - Motor InnoDB)
-- ============================================================================

CREATE DATABASE IF NOT EXISTS restaurante_db
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

USE restaurante_db;

-- 1. Tabla de Mesas (Gestión principalmente en Salón - Nodo 1)
CREATE TABLE IF NOT EXISTS mesas (
    id_mesa INT AUTO_INCREMENT PRIMARY KEY,
    numero_mesa INT NOT NULL UNIQUE,
    capacidad INT NOT NULL DEFAULT 4,
    sector VARCHAR(50) NOT NULL DEFAULT 'Salón Principal',
    estado ENUM('LIBRE', 'OCUPADA', 'RESERVADA', 'CERRANDO_CUENTA') NOT NULL DEFAULT 'LIBRE',
    ultima_actualizacion TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB;

-- 2. Tabla de Productos / Menú e Insumos (Sincronizada entre Salón y Cocina/Stock)
CREATE TABLE IF NOT EXISTS productos_menu (
    id_producto INT AUTO_INCREMENT PRIMARY KEY,
    nombre VARCHAR(100) NOT NULL,
    categoria ENUM('ENTRADA', 'PLATO_PRINCIPAL', 'POSTRE', 'BEBIDA') NOT NULL,
    precio DECIMAL(10, 2) NOT NULL CHECK (precio >= 0),
    stock_disponible INT NOT NULL DEFAULT 0 CHECK (stock_disponible >= 0),
    activo BOOLEAN NOT NULL DEFAULT TRUE,
    ultima_actualizacion TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB;

-- 3. Tabla de Comandas / Órdenes (Núcleo transaccional Salón <-> Cocina)
-- Con auto_increment_increment=2 y offset=1, el Nodo 1 generará IDs impares (1, 3, 5...)
CREATE TABLE IF NOT EXISTS comandas (
    id_comanda INT AUTO_INCREMENT PRIMARY KEY,
    id_mesa INT NOT NULL,
    mozo VARCHAR(80) NOT NULL,
    nodo_origen VARCHAR(30) NOT NULL DEFAULT 'NODO_1_SALON',
    estado ENUM('ABIERTA', 'EN_PREPARACION', 'LISTA_PARA_SERVIR', 'ENTREGADA', 'PAGADA', 'CANCELADA') NOT NULL DEFAULT 'ABIERTA',
    total DECIMAL(10, 2) NOT NULL DEFAULT 0.00,
    fecha_apertura DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    fecha_cierre DATETIME NULL,
    CONSTRAINT fk_comanda_mesa FOREIGN KEY (id_mesa) REFERENCES mesas(id_mesa)
        ON UPDATE CASCADE ON DELETE RESTRICT
) ENGINE=InnoDB;

-- 4. Tabla de Detalle de Comanda (Ítems pedidos y estado de marcha en Cocina)
CREATE TABLE IF NOT EXISTS detalle_comanda (
    id_detalle INT AUTO_INCREMENT PRIMARY KEY,
    id_comanda INT NOT NULL,
    id_producto INT NOT NULL,
    cantidad INT NOT NULL CHECK (cantidad > 0),
    precio_unitario DECIMAL(10, 2) NOT NULL,
    subtotal DECIMAL(10, 2) GENERATED ALWAYS AS (cantidad * precio_unitario) STORED,
    estado_cocina ENUM('PENDIENTE', 'EN_COCCION', 'LISTO', 'ENTREGADO', 'ANULADO') NOT NULL DEFAULT 'PENDIENTE',
    observaciones VARCHAR(255) NULL,
    CONSTRAINT fk_detalle_comanda FOREIGN KEY (id_comanda) REFERENCES comandas(id_comanda)
        ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT fk_detalle_producto FOREIGN KEY (id_producto) REFERENCES productos_menu(id_producto)
        ON UPDATE CASCADE ON DELETE RESTRICT
) ENGINE=InnoDB;

-- 5. Tabla de Pagos / Caja (Registrada en Nodo 1 - Salón/Caja)
CREATE TABLE IF NOT EXISTS pagos (
    id_pago INT AUTO_INCREMENT PRIMARY KEY,
    id_comanda INT NOT NULL UNIQUE,
    metodo_pago ENUM('EFECTIVO', 'TARJETA_DEBITO', 'TARJETA_CREDITO', 'TRANSFERENCIA_QR') NOT NULL,
    monto_total DECIMAL(10, 2) NOT NULL,
    fecha_pago DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    nodo_caja VARCHAR(30) NOT NULL DEFAULT 'NODO_1_SALON',
    CONSTRAINT fk_pago_comanda FOREIGN KEY (id_comanda) REFERENCES comandas(id_comanda)
        ON UPDATE CASCADE ON DELETE RESTRICT
) ENGINE=InnoDB;

-- ============================================================================
-- DATOS SEMILLA INICIALES PARA VERIFICACIÓN DE ABM (GENERARÁN IDs IMPARES: 1, 3, 5...)
-- ============================================================================

INSERT INTO mesas (numero_mesa, capacidad, sector, estado) VALUES
(101, 4, 'Salón Principal', 'LIBRE'),
(102, 2, 'Salón Principal', 'LIBRE'),
(201, 6, 'Terraza', 'LIBRE');

INSERT INTO productos_menu (nombre, categoria, precio, stock_disponible) VALUES
('Bife de Chorizo 400g', 'PLATO_PRINCIPAL', 18500.00, 25),
('Sorrentinos de Jamón y Queso', 'PLATO_PRINCIPAL', 14200.00, 30),
('Empanada Cortada a Cuchillo', 'ENTRADA', 2800.00, 60),
('Agua Mineral 500ml', 'BEBIDA', 2500.00, 100),
('Flan Casero Mixto', 'POSTRE', 5500.00, 20);
