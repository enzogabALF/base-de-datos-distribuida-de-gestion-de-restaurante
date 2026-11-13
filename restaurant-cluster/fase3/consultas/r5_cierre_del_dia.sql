-- R5. Cierre de caja de un día, por medio de pago.
-- El filtro aplica una función a la columna: DATE(fecha_pago). El motor no
-- puede buscar en el índice I4 por "DATE(...)", así que recorre todo el índice
-- y calcula la función fila por fila (condición no "sargable").
SELECT pg.metodo_pago, COUNT(*) AS operaciones, SUM(pg.monto_total) AS recaudado
FROM pagos pg
WHERE DATE(pg.fecha_pago) = '2026-10-15'
GROUP BY pg.metodo_pago;
