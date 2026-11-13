-- R3. Ranking de mozos del trimestre: comandas, facturación y minutos promedio
-- desde la apertura hasta que la cocina despacha (LISTA_PARA_SERVIR).
-- JOIN comandas -> historial_estados_comanda (~470.000 filas).
SELECT c.mozo,
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
