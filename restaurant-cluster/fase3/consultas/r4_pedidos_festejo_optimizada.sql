-- R4 optimizada: búsqueda en el índice invertido FULLTEXT (I6), el equivalente
-- MySQL del GIN de PostgreSQL. El índice devuelve directamente las filas que
-- contienen la palabra, sin recorrer las que no la tienen. Rinde más cuanto
-- menos frecuente es la palabra (aquí, ~1 % de las líneas).
SELECT p.nombre, COUNT(*) AS pedidos
FROM detalle_comanda d
JOIN productos_menu p ON p.id_producto = d.id_producto
WHERE MATCH(d.observaciones) AGAINST ('cumpleaños' IN BOOLEAN MODE)
GROUP BY p.nombre
ORDER BY pedidos DESC;
