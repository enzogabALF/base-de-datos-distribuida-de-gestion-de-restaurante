-- R3 optimizada: misma consulta con una pista de orden de JOIN.
-- Con los índices creados, el optimizador igual prefiere recorrer el índice
-- completo del historial (470.000 entradas) y buscar cada comanda, porque
-- sobreestima cuántas comandas devuelve el rango de fechas. La pista
-- JOIN_ORDER(c, h) le indica empezar por las ~29.000 comandas del rango
-- (índice I1) y buscar solo su evento LISTA_PARA_SERVIR (índice I5).
SELECT /*+ JOIN_ORDER(c, h) */
       c.mozo,
       COUNT(*) AS comandas,
       SUM(c.total) AS facturado,
       ROUND(AVG(TIMESTAMPDIFF(MINUTE, c.fecha_apertura, h.fecha_cambio)), 1) AS min_hasta_servir
FROM comandas c
JOIN historial_estados_comanda h
  ON h.id_comanda = c.id_comanda AND h.estado_nuevo = 'LISTA_PARA_SERVIR'
WHERE c.estado = 'PAGADA'
  AND c.fecha_apertura >= '2026-08-01' AND c.fecha_apertura < '2026-11-01'
GROUP BY c.mozo
ORDER BY facturado DESC;
