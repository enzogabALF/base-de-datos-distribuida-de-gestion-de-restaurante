-- R4. Pedidos de festejo de cumpleaños en todo el historial, por producto
-- (para planificar la compra de velas y la producción de postres).
-- LIKE '%texto%' empieza con comodín: ningún B+Tree sirve y se lee todo el detalle.
SELECT p.nombre, COUNT(*) AS pedidos
FROM detalle_comanda d
JOIN productos_menu p ON p.id_producto = d.id_producto
WHERE d.observaciones LIKE '%cumpleaños%'
GROUP BY p.nombre
ORDER BY pedidos DESC;
