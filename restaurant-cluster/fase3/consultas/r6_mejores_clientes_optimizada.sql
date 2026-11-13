-- R6 optimizada: un único recorrido con JOIN y GROUP BY, y el año expresado
-- como rango (sargable). Con el índice I2 (id_cliente, estado, fecha_apertura,
-- total) cada cliente se resuelve leyendo solo el índice.
SELECT cl.id_cliente,
       cl.nombre_completo,
       COUNT(*) AS visitas,
       SUM(c.total) AS gastado
FROM comandas c
JOIN clientes cl ON cl.id_cliente = c.id_cliente
WHERE c.estado = 'PAGADA'
  AND c.fecha_apertura >= '2026-01-01' AND c.fecha_apertura < '2027-01-01'
GROUP BY cl.id_cliente, cl.nombre_completo
ORDER BY gastado DESC
LIMIT 10;
