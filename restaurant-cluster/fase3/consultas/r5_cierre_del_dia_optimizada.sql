-- R5 optimizada: el mismo filtro escrito como rango sobre la columna original.
-- Ahora el motor salta directo al primer pago del día en el índice I4 y lee
-- solo los de ese día (alternativa: índice funcional sobre (DATE(fecha_pago))).
SELECT pg.metodo_pago, COUNT(*) AS operaciones, SUM(pg.monto_total) AS recaudado
FROM pagos pg
WHERE pg.fecha_pago >= '2026-10-15' AND pg.fecha_pago < '2026-10-16'
GROUP BY pg.metodo_pago;
