-- R6. Diez mejores clientes de 2026 (programa de fidelización).
-- Escrita con dos subconsultas correlacionadas: para CADA uno de los ~3.000
-- clientes se ejecutan dos búsquedas en comandas, y el filtro YEAR() no es sargable.
SELECT cl.id_cliente,
       cl.nombre_completo,
       (SELECT COUNT(*) FROM comandas c
         WHERE c.id_cliente = cl.id_cliente AND YEAR(c.fecha_apertura) = 2026 AND c.estado = 'PAGADA') AS visitas,
       (SELECT SUM(c.total) FROM comandas c
         WHERE c.id_cliente = cl.id_cliente AND YEAR(c.fecha_apertura) = 2026 AND c.estado = 'PAGADA') AS gastado
FROM clientes cl
ORDER BY gastado DESC
LIMIT 10;
