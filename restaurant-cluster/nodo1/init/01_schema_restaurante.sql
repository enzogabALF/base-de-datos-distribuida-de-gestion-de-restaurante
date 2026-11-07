-- ============================================================================
-- AE4 - TIFAS: SISTEMA DISTRIBUIDO DE GESTIÓN GASTRONÓMICA
-- ESQUEMA GLOBAL REPLICADO - NODO 1 (SALÓN / CAJA)
-- Motor Transaccional InnoDB - Integración Relacional + NoSQL (JSON)
-- ============================================================================

SET sql_log_bin = 0;

CREATE DATABASE IF NOT EXISTS restaurante_db
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

USE restaurante_db;

-- 1. Tabla de Clientes (Fidelización y Facturación)
CREATE TABLE IF NOT EXISTS clientes (
    id_cliente INT AUTO_INCREMENT PRIMARY KEY,
    nombre_completo VARCHAR(100) NOT NULL,
    cuit_dni VARCHAR(20) NOT NULL UNIQUE,
    telefono VARCHAR(30) NULL,
    email VARCHAR(100) NULL,
    puntos_fidelidad INT NOT NULL DEFAULT 0 CHECK (puntos_fidelidad >= 0),
    activo BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    ultima_actualizacion TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB;

-- 2. Tabla de Mesas (Gestión de Salón)
CREATE TABLE IF NOT EXISTS mesas (
    id_mesa INT AUTO_INCREMENT PRIMARY KEY,
    numero_mesa INT NOT NULL UNIQUE,
    capacidad INT NOT NULL DEFAULT 4 CHECK (capacidad > 0),
    sector VARCHAR(50) NOT NULL DEFAULT 'Salón Principal',
    estado ENUM('LIBRE', 'OCUPADA', 'RESERVADA', 'CERRANDO_CUENTA') NOT NULL DEFAULT 'LIBRE',
    ultima_actualizacion TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB;

-- 3. Tabla de Productos / Menú (Catálogo Global Sincronizado)
CREATE TABLE IF NOT EXISTS productos_menu (
    id_producto INT AUTO_INCREMENT PRIMARY KEY,
    nombre VARCHAR(100) NOT NULL,
    categoria ENUM('ENTRADA', 'PLATO_PRINCIPAL', 'POSTRE', 'BEBIDA') NOT NULL,
    precio DECIMAL(10, 2) NOT NULL CHECK (precio >= 0),
    stock_disponible INT NOT NULL DEFAULT 0 CHECK (stock_disponible >= 0),
    activo BOOLEAN NOT NULL DEFAULT TRUE,
    ultima_actualizacion TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB;

-- 4. Tabla de Movimientos de Stock / Inventario (Control y Trazabilidad de Insumos)
CREATE TABLE IF NOT EXISTS movimientos_stock (
    id_movimiento INT AUTO_INCREMENT PRIMARY KEY,
    id_producto INT NOT NULL,
    tipo_movimiento ENUM('INGRESO_PROVEEDOR', 'VENTA_COMANDA', 'MERMA_ROTURA', 'AJUSTE_INVENTARIO') NOT NULL,
    cantidad INT NOT NULL,
    stock_previo INT NOT NULL CHECK (stock_previo >= 0),
    stock_posterior INT NOT NULL CHECK (stock_posterior >= 0),
    motivo VARCHAR(255) NULL,
    nodo_origen VARCHAR(30) NOT NULL DEFAULT 'NODO_1_SALON',
    fecha_movimiento TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_mov_producto FOREIGN KEY (id_producto) REFERENCES productos_menu(id_producto)
        ON UPDATE CASCADE ON DELETE RESTRICT
) ENGINE=InnoDB;

-- 5. Tabla de Comandas / Órdenes (Núcleo Transaccional Distribuido)
-- Nodo 1 (offset=1) genera IDs impares (1, 3, 5...)
-- Nodo 2 (offset=2) genera IDs pares (2, 4, 6...)
CREATE TABLE IF NOT EXISTS comandas (
    id_comanda INT AUTO_INCREMENT PRIMARY KEY,
    id_mesa INT NOT NULL,
    id_cliente INT NULL,
    mozo VARCHAR(80) NOT NULL,
    nodo_origen VARCHAR(30) NOT NULL DEFAULT 'NODO_1_SALON',
    estado ENUM('ABIERTA', 'EN_PREPARACION', 'LISTA_PARA_SERVIR', 'ENTREGADA', 'PAGADA', 'CANCELADA') NOT NULL DEFAULT 'ABIERTA',
    total DECIMAL(10, 2) NOT NULL DEFAULT 0.00 CHECK (total >= 0),
    historial_estados JSON NULL COMMENT 'Registro NoSQL de eventos y auditoría de la orden',
    fecha_apertura DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    fecha_cierre DATETIME NULL,
    CONSTRAINT fk_comanda_mesa FOREIGN KEY (id_mesa) REFERENCES mesas(id_mesa)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_comanda_cliente FOREIGN KEY (id_cliente) REFERENCES clientes(id_cliente)
        ON UPDATE CASCADE ON DELETE SET NULL
) ENGINE=InnoDB;

-- 6. Tabla de Detalle de Comanda (Líneas de Pedido y Marchas de Cocina)
CREATE TABLE IF NOT EXISTS detalle_comanda (
    id_detalle INT AUTO_INCREMENT PRIMARY KEY,
    id_comanda INT NOT NULL,
    id_producto INT NOT NULL,
    cantidad INT NOT NULL CHECK (cantidad > 0),
    precio_unitario DECIMAL(10, 2) NOT NULL CHECK (precio_unitario >= 0),
    subtotal DECIMAL(10, 2) GENERATED ALWAYS AS (cantidad * precio_unitario) STORED,
    estado_cocina ENUM('PENDIENTE', 'EN_COCCION', 'LISTO', 'ENTREGADO', 'ANULADO') NOT NULL DEFAULT 'PENDIENTE',
    especificaciones JSON NULL COMMENT 'Requerimientos culinarios NoSQL (alergenos, punto, condimentos)',
    observaciones VARCHAR(255) NULL,
    CONSTRAINT fk_detalle_comanda FOREIGN KEY (id_comanda) REFERENCES comandas(id_comanda)
        ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT fk_detalle_producto FOREIGN KEY (id_producto) REFERENCES productos_menu(id_producto)
        ON UPDATE CASCADE ON DELETE RESTRICT
) ENGINE=InnoDB;

-- 7. Tabla de Pagos / Caja (Cierre y Facturación de Comandas)
CREATE TABLE IF NOT EXISTS pagos (
    id_pago INT AUTO_INCREMENT PRIMARY KEY,
    id_comanda INT NOT NULL UNIQUE,
    metodo_pago ENUM('EFECTIVO', 'TARJETA_DEBITO', 'TARJETA_CREDITO', 'TRANSFERENCIA_QR') NOT NULL,
    monto_total DECIMAL(10, 2) NOT NULL CHECK (monto_total > 0),
    metadatos_fiscales JSON NULL COMMENT 'Datos de comprobante electrónico, CAE, lote o pasarela QR',
    fecha_pago DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    nodo_caja VARCHAR(30) NOT NULL DEFAULT 'NODO_1_SALON',
    CONSTRAINT fk_pago_comanda FOREIGN KEY (id_comanda) REFERENCES comandas(id_comanda)
        ON UPDATE CASCADE ON DELETE RESTRICT
) ENGINE=InnoDB;

SET sql_log_bin = 1;
