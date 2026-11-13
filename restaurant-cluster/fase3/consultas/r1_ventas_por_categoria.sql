-- R1. Ventas por mes y categoría del último trimestre (reporte de gerencia)
-- JOIN de 3 tablas: comandas -> detalle_comanda -> productos_menu.
-- Sin índice sobre la fecha, el motor recorre las ~310.000 líneas de detalle y
-- busca su comanda una por una para descartar el 75 % que está fuera del rango.
-- Índices que la resuelven: I1 (estado, fecha_apertura) e I3 (cobertura del detalle).
SELECT DATE_FORMAT(c.fecha_apertura, '%Y-%m') AS mes,
       p.categoria,
       COUNT(DISTINCT c.id_comanda) AS tickets,
       SUM(d.cantidad) AS unidades,
       SUM(d.subtotal) AS importe
FROM comandas c
JOIN detalle_comanda d ON d.id_comanda = c.id_comanda
JOIN productos_menu p ON p.id_producto = d.id_producto
WHERE c.estado = 'PAGADA'
  AND c.fecha_apertura >= '2026-08-01' AND c.fecha_apertura < '2026-11-01'
GROUP BY mes, p.categoria
ORDER BY mes, importe DESC;
