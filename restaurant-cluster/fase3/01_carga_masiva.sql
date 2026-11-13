-- ============================================================================
-- AE4 - TIFAS FASE 3: CARGA MASIVA DE DATOS HISTÓRICOS (NODO 1 - SALÓN)
-- ----------------------------------------------------------------------------
-- Simula la migración del historial del sistema anterior del restaurante:
-- 22 meses de operación (enero 2025 a octubre 2026), con el volumen necesario
-- para que los reportes sufran los problemas de rendimiento que la Fase 3
-- tiene que diagnosticar y corregir.
--
-- Volumen con el valor por defecto (@n_comandas = 120000):
--   clientes ~3.000 | comandas 120.000 | detalle ~310.000
--   historial ~465.000 | pagos ~115.000
--
-- Decisiones:
--   * Se ejecuta en el Nodo 1 con el binary log activo: la replicación lleva
--     los datos al Nodo 2, igual que cualquier otra transacción.
--   * Los datos son DETERMINISTAS: cada valor sale de CRC32(número de fila), no
--     de RAND(). Así la carga produce exactamente los mismos datos en cualquier
--     máquina y los resultados de la Fase 3 son reproducibles.
--   * Los IDs son explícitos y respetan la fragmentación de claves del diseño:
--     impares para lo generado por el Salón y pares para los eventos de Cocina.
--     Empiezan en 1.000.001 para no mezclarse con los datos de demostración.
--   * Los datos incluyen patrones de consumo reales (la parrilla se acompaña con
--     Malbec, las pastas con postre, etc.) que el análisis KDD debe descubrir.
--   * Los precios históricos se deflactan un 2,5 % mensual hacia atrás.
--
-- Uso (desde restaurant-cluster/):
--   docker exec -i restaurante_nodo1_salon mysql -uroot -proot_password_ae4 < fase3/01_carga_masiva.sql
-- Para una carga más chica: anteponer "SET @n_comandas = 20000;" en la misma sesión.
-- ============================================================================

SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci;   -- la misma intercalación que las tablas
USE restaurante_db;

SET @n_comandas = IFNULL(@n_comandas, 120000);
SET SESSION cte_max_recursion_depth = 1000000;
-- Reloj fijo: las columnas con DEFAULT CURRENT_TIMESTAMP quedan iguales en cualquier máquina
SET TIMESTAMP = UNIX_TIMESTAMP('2026-11-01 06:00:00');

SELECT CONCAT('Carga masiva: ', @n_comandas, ' comandas') AS inicio, SYSDATE(6) AS hora;
-- SYSDATE() da la hora real aunque SET TIMESTAMP haya fijado NOW()
SET @t0 = SYSDATE(6);

-- ----------------------------------------------------------------------------
-- 1. Clientes fidelizados (3.000, IDs impares desde 1001)
-- ----------------------------------------------------------------------------
INSERT INTO clientes (id_cliente, nombre_completo, cuit_dni, telefono, email, puntos_fidelidad, activo, created_at)
WITH RECURSIVE seq (n) AS (SELECT 0 UNION ALL SELECT n + 1 FROM seq WHERE n < 2999)
SELECT
    1001 + 2 * n,
    CONCAT(ELT(1 + CRC32(CONCAT(n, '|nombre')) % 16,
               'Ana', 'Bruno', 'Camila', 'Diego', 'Elena', 'Facundo', 'Gabriela', 'Hernán',
               'Inés', 'Joaquín', 'Lorena', 'Matías', 'Natalia', 'Pablo', 'Romina', 'Tomás'),
           ' ',
           ELT(1 + CRC32(CONCAT(n, '|apellido')) % 16,
               'García', 'Romero', 'Sosa', 'Benítez', 'Acosta', 'Medina', 'Herrera', 'Suárez',
               'Aguirre', 'Giménez', 'Molina', 'Silva', 'Castro', 'Rojas', 'Ortiz', 'Núñez')),
    CONCAT(IF(n % 2 = 0, '20-', '27-'), 30000000 + n, '-', n % 10),
    CONCAT('379-4', LPAD(CRC32(CONCAT(n, '|tel')) % 1000000, 6, '0')),
    CONCAT('cliente', 1001 + 2 * n, '@correo.com'),
    0,
    TRUE,
    TIMESTAMP('2025-01-01') + INTERVAL (n % 365) DAY
FROM seq;

-- ----------------------------------------------------------------------------
-- 2. Comandas (IDs impares desde 1.000.001)
--    * Fecha: la cantidad de comandas por día crece linealmente un 80 % entre
--      enero de 2025 y octubre de 2026 (el negocio crece de forma moderada).
--    * Turno: 40 % almuerzo (12:00-14:59) y 60 % cena (20:00-23:49).
--    * Cliente: 45 % consumidor final (NULL); el resto con una distribución
--      sesgada (pocos clientes muy frecuentes, muchos ocasionales).
--    * 4 % canceladas, el resto pagadas.
-- ----------------------------------------------------------------------------
INSERT INTO comandas (id_comanda, id_mesa, id_cliente, mozo, nodo_origen, estado, total,
                      motivo_cancelacion, fecha_apertura, fecha_cierre)
WITH RECURSIVE seq (n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < @n_comandas),
base AS (
    SELECT n,
           CRC32(CONCAT(n, '|mesa'))   AS h_mesa,
           CRC32(CONCAT(n, '|cli'))    AS h_cli,
           CRC32(CONCAT(n, '|mozo'))   AS h_mozo,
           CRC32(CONCAT(n, '|estado')) AS h_est,
           TIMESTAMP('2025-01-01')
             -- inversa de la distribución con densidad lineal 1 + 0,8x (la actividad
             -- crece 80 % en los 22 meses): x = (sqrt(1 + 2,24u) - 1) / 0,8
             + INTERVAL FLOOR(669 * (SQRT(1 + 2.24 * (CRC32(CONCAT(n, '|dia')) % 1000000) / 1000000) - 1) / 0.8) DAY
             + INTERVAL IF(CRC32(CONCAT(n, '|turno')) % 100 < 40,
                           12 * 60 + CRC32(CONCAT(n, '|hora')) % 180,
                           20 * 60 + CRC32(CONCAT(n, '|hora')) % 230) MINUTE AS apertura
    FROM seq
)
SELECT
    999999 + 2 * n,
    1 + h_mesa % 10,
    IF(h_cli % 100 < 45, NULL,
       1001 + 2 * FLOOR(3000 * POW((h_cli % 100000) / 100000, 2))),
    ELT(1 + h_mozo % 6, 'Carlos Gómez', 'Lucía Fernández', 'Diego Sosa',
                        'Valentina Ríos', 'Martín Acosta', 'Sofía Benítez'),
    'NODO_1_SALON',
    IF(h_est % 100 < 4, 'CANCELADA', 'PAGADA'),
    0.00,
    IF(h_est % 100 < 4, 'Cancelación registrada en el sistema anterior', NULL),
    apertura,
    apertura + INTERVAL (45 + h_est % 75) MINUTE
FROM base;

-- ----------------------------------------------------------------------------
-- 3. Detalle de comandas (IDs impares desde 2.000.001; hasta 4 líneas por comanda)
--    Cada comanda tiene un "perfil" que define qué se pide junto:
--      parrilla (30 %): bife u ojo de bife + Malbec (70 %) + provoleta (50 %) + flan (25 %)
--      pastas   (25 %): sorrentinos + agua (60 %) + empanada (20 %) + volcán (55 %)
--      minuta   (25 %): milanesa + gaseosa (75 %) + flan (30 %)
--      picada   (20 %): empanadas + cerveza IPA (75 %) + provoleta (35 %) + volcán (15 %)
-- ----------------------------------------------------------------------------
INSERT INTO detalle_comanda (id_detalle, id_comanda, id_producto, cantidad, precio_unitario,
                             estado_cocina, punto_coccion, apto_celiaco, sin_sal, observaciones)
SELECT
    1999999 + 2 * ((x.n - 1) * 4 + x.k),
    x.id_comanda,
    x.id_producto,
    CASE
        WHEN x.id_producto = 1 THEN 3 + x.h_cant % 6          -- empanadas: 3 a 8
        WHEN x.k = 1 THEN 1 + x.h_cant % 3                     -- plato principal: 1 a 3
        WHEN x.k = 2 THEN 1 + x.h_cant % 2                     -- bebida: 1 o 2
        ELSE 1
    END,
    -- precio de la época: 2,5 % menos por cada mes previo a octubre de 2026
    ROUND(p.precio * POW(0.975, PERIOD_DIFF(202610, EXTRACT(YEAR_MONTH FROM x.fecha_apertura))), 2),
    IF(x.estado = 'CANCELADA', 'ANULADO', 'ENTREGADO'),
    IF(x.id_producto IN (3, 4), ELT(1 + x.h_obs % 4, 'JUGOSO', 'A_PUNTO', 'A_PUNTO', 'COCIDO'), 'NO_APLICA'),
    x.h_obs % 100 < 5,
    x.h_obs % 100 BETWEEN 5 AND 11,
    CASE
        WHEN x.h_obs % 100 < 5 THEN 'Comensal celíaco: preparar sin TACC'
        WHEN x.h_obs % 100 < 12 THEN 'Sin sal por indicación médica'
        WHEN x.h_obs % 100 < 15 THEN 'Salsa aparte'
        WHEN x.h_obs % 100 < 17 THEN 'Sin cebolla'
        WHEN x.h_obs % 100 < 18 THEN 'Festejo de cumpleaños: postre con vela'
        ELSE NULL
    END
FROM (
    SELECT c.id_comanda, c.estado, c.fecha_apertura, k.k,
           (c.id_comanda - 999999) DIV 2 AS n,
           CRC32(CONCAT(c.id_comanda, '|', k.k, '|cant')) AS h_cant,
           CRC32(CONCAT(c.id_comanda, '|', k.k, '|obs'))  AS h_obs,
           CASE
             -- perfil parrilla
             WHEN c.perfil < 30 THEN CASE k.k
                 WHEN 1 THEN IF(c.h % 2 = 0, 3, 4)
                 WHEN 2 THEN IF(c.h_b % 100 < 70, 12, 10)
                 WHEN 3 THEN IF(c.h_e % 100 < 50, 2, NULL)
                 WHEN 4 THEN IF(c.h_p % 100 < 25, 8, NULL) END
             -- perfil pastas
             WHEN c.perfil < 55 THEN CASE k.k
                 WHEN 1 THEN 5
                 WHEN 2 THEN IF(c.h_b % 100 < 60, 9, 10)
                 WHEN 3 THEN IF(c.h_e % 100 < 20, 1, NULL)
                 WHEN 4 THEN IF(c.h_p % 100 < 55, 7, NULL) END
             -- perfil minuta
             WHEN c.perfil < 80 THEN CASE k.k
                 WHEN 1 THEN 6
                 WHEN 2 THEN IF(c.h_b % 100 < 75, 10, 9)
                 WHEN 3 THEN NULL
                 WHEN 4 THEN IF(c.h_p % 100 < 30, 8, NULL) END
             -- perfil picada
             ELSE CASE k.k
                 WHEN 1 THEN 1
                 WHEN 2 THEN IF(c.h_b % 100 < 75, 11, 10)
                 WHEN 3 THEN IF(c.h_e % 100 < 35, 2, NULL)
                 WHEN 4 THEN IF(c.h_p % 100 < 15, 7, NULL) END
           END AS id_producto
    FROM (
        SELECT id_comanda, estado, fecha_apertura,
               CRC32(CONCAT(id_comanda, '|perfil')) % 100 AS perfil,
               CRC32(CONCAT(id_comanda, '|plato'))   AS h,
               CRC32(CONCAT(id_comanda, '|bebida'))  AS h_b,
               CRC32(CONCAT(id_comanda, '|entrada')) AS h_e,
               CRC32(CONCAT(id_comanda, '|postre'))  AS h_p
        FROM comandas
        WHERE id_comanda >= 1000001
    ) c
    CROSS JOIN (SELECT 1 AS k UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4) k
) x
JOIN productos_menu p ON p.id_producto = x.id_producto
WHERE x.id_producto IS NOT NULL;

-- ----------------------------------------------------------------------------
-- 4. Total de cada comanda a partir de la columna generada subtotal
-- ----------------------------------------------------------------------------
UPDATE comandas c
JOIN (
    SELECT id_comanda, SUM(subtotal) AS total
    FROM detalle_comanda
    WHERE id_comanda >= 1000001
    GROUP BY id_comanda
) d ON d.id_comanda = c.id_comanda
SET c.total = d.total;

-- ----------------------------------------------------------------------------
-- 5. Historial de estados (4 eventos por comanda pagada, 2 por cancelada)
--    IDs desde 3.000.001: los eventos del Salón son impares (+1, +3) y los de
--    Cocina pares (+2, +4), igual que si los hubiera generado cada nodo.
-- ----------------------------------------------------------------------------
INSERT INTO historial_estados_comanda (id_historial, id_comanda, estado_anterior, estado_nuevo,
                                       operador, nodo_emisor, observacion, fecha_cambio)
SELECT 3000000 + 4 * (c.n - 1) + e.slot,
       c.id_comanda,
       e.anterior,
       e.nuevo,
       CASE e.slot WHEN 1 THEN c.mozo WHEN 2 THEN 'Jefe de Partida' WHEN 4 THEN 'Despachador'
                   ELSE IF(c.estado = 'CANCELADA', 'Jefe de Salón', 'Cajero Salón 1') END,
       IF(e.slot IN (2, 4), 'NODO_2_COCINA', 'NODO_1_SALON'),
       'Migrado del sistema anterior',
       CASE e.slot
           WHEN 1 THEN c.fecha_apertura
           WHEN 2 THEN c.fecha_apertura + INTERVAL (2 + c.h % 8) MINUTE
           WHEN 4 THEN c.fecha_apertura + INTERVAL (12 + c.h % 22) MINUTE
           ELSE c.fecha_cierre
       END
FROM (
    SELECT id_comanda, mozo, estado, fecha_apertura, fecha_cierre,
           (id_comanda - 999999) DIV 2 AS n,
           CRC32(CONCAT(id_comanda, '|cocina')) AS h
    FROM comandas
    WHERE id_comanda >= 1000001
) c
JOIN (
    SELECT 1 AS slot, CAST(NULL AS CHAR(20)) AS anterior, 'ABIERTA' AS nuevo, 'TODAS' AS aplica
    UNION ALL SELECT 2, 'ABIERTA', 'EN_PREPARACION', 'PAGADA'
    UNION ALL SELECT 4, 'EN_PREPARACION', 'LISTA_PARA_SERVIR', 'PAGADA'
    UNION ALL SELECT 3, 'LISTA_PARA_SERVIR', 'PAGADA', 'PAGADA'
    UNION ALL SELECT 3, 'ABIERTA', 'CANCELADA', 'CANCELADA'
) e ON e.aplica = 'TODAS' OR e.aplica = c.estado;

-- ----------------------------------------------------------------------------
-- 6. Pagos de las comandas pagadas (IDs impares desde 4.000.001)
-- ----------------------------------------------------------------------------
INSERT INTO pagos (id_pago, id_comanda, metodo_pago, tipo_comprobante, numero_comprobante,
                   codigo_autorizacion, monto_total, fecha_pago, nodo_caja)
SELECT 3999999 + 2 * n,
       id_comanda,
       CASE WHEN h % 100 < 20 THEN 'EFECTIVO'
            WHEN h % 100 < 50 THEN 'TARJETA_DEBITO'
            WHEN h % 100 < 80 THEN 'TARJETA_CREDITO'
            ELSE 'TRANSFERENCIA_QR' END,
       CASE WHEN h % 10 < 7 THEN 'FACTURA_B' WHEN h % 10 < 9 THEN 'TICKET_CONSUMO' ELSE 'FACTURA_A' END,
       CONCAT('0002-', LPAD(n, 8, '0')),
       IF(h % 100 < 20, NULL, CONCAT('AUT-', LPAD(h % 1000000, 6, '0'))),
       total,
       fecha_cierre,
       'NODO_1_SALON'
FROM (
    SELECT id_comanda, total, fecha_cierre,
           (id_comanda - 999999) DIV 2 AS n,
           CRC32(CONCAT(id_comanda, '|pago')) AS h
    FROM comandas
    WHERE id_comanda >= 1000001 AND estado = 'PAGADA'
) c;

SET TIMESTAMP = DEFAULT;

-- ----------------------------------------------------------------------------
-- 7. Resumen de la carga
-- ----------------------------------------------------------------------------
SELECT ROUND(TIMESTAMPDIFF(MICROSECOND, @t0, SYSDATE(6)) / 1e6, 1) AS segundos_carga;

SELECT 'clientes' AS tabla, COUNT(*) AS filas FROM clientes
UNION ALL SELECT 'comandas', COUNT(*) FROM comandas
UNION ALL SELECT 'detalle_comanda', COUNT(*) FROM detalle_comanda
UNION ALL SELECT 'historial_estados_comanda', COUNT(*) FROM historial_estados_comanda
UNION ALL SELECT 'pagos', COUNT(*) FROM pagos;
