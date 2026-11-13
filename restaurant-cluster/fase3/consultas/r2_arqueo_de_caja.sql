-- R2. Arqueo de caja de octubre por día, medio de pago y sector del salón
-- JOIN de 3 tablas: pagos -> comandas -> mesas. Sin índice sobre fecha_pago
-- se recorre la tabla de pagos completa. Índice que la resuelve: I4.
SELECT DATE(pg.fecha_pago) AS dia,
       pg.metodo_pago,
       m.sector,
       COUNT(*) AS operaciones,
       SUM(pg.monto_total) AS recaudado
FROM pagos pg
JOIN comandas c ON c.id_comanda = pg.id_comanda
JOIN mesas m ON m.id_mesa = c.id_mesa
WHERE pg.fecha_pago >= '2026-10-01' AND pg.fecha_pago < '2026-11-01'
GROUP BY dia, pg.metodo_pago, m.sector
ORDER BY dia, pg.metodo_pago, m.sector;
