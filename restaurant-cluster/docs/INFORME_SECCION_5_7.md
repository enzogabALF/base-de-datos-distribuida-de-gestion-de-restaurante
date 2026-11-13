# Texto para el informe: sección 5.7

> **Nota para el equipo (borrar al pegar):** este texto reemplaza el "(Pendiente.)" de la sección 5.7. Sigue el estilo de las secciones 5.5 y 5.6: se agregan las tablas 3 a 6 y las citas Oracle Corporation s.f.-g a s.f.-j, que continúan la numeración de las secciones anteriores. La s.f.-f (`mysqlbinlog`) figura en `FASE2_RESILIENCIA_Y_BACKUPS.md`: si no la agregaron al informe, corran estas letras una posición (g → f, etc.). Las cifras salen de `restaurant-cluster/pruebas_fase3/resultados/`, y el detalle técnico completo está en `docs/FASE3_TUNING_INDEXACION_PARTICIONAMIENTO.md`. Al final están las referencias nuevas para la bibliografía.

---

## 5.7. Ajuste de rendimiento, indexación y particionamiento

Con los pocos datos de la Fase 1, cualquier consulta respondía al instante. Para evaluar el rendimiento real se simuló la migración de 22 meses de historial del sistema anterior: 120.007 comandas, 310.440 líneas de pedido y 470.328 registros de historial, en total cerca de un millón de filas. La carga es determinista, así que produce exactamente los mismos datos en cualquier equipo. Sobre ese volumen se analizaron seis reportes de gestión con la instrucción `EXPLAIN ANALYZE`, que muestra el plan elegido por el optimizador y el tiempo real de cada paso (Oracle Corporation, s.f.-g).

**Diagnóstico.** El reporte de ventas por categoría del último trimestre une tres tablas. El plan mostró que el motor recorría las 310.440 líneas de pedido y buscaba la comanda de cada una, para descartar el 75 % que estaba fuera del trimestre. Los demás reportes leían tablas completas porque no había índices sobre las fechas, filtraban con funciones aplicadas a las columnas o ejecutaban subconsultas una vez por cada cliente.

**Estadísticas.** El primer hallazgo no estuvo en los índices. El optimizador creía que la tabla de productos tenía cero filas, porque se había creado vacía y sus estadísticas nunca se recalcularon. Con esa estimación elegía un orden de unión ineficiente y, durante el desarrollo, ignoraba incluso los índices nuevos. Actualizar las estadísticas y agregar histogramas sobre el estado y la fecha de las comandas fue condición necesaria para todo lo demás (Oracle Corporation, s.f.-i).

**Indexación.** Se crearon índices B+Tree compuestos de cobertura: contienen todas las columnas que necesita el reporte, de modo que el motor no lee la fila completa. Las columnas se ordenaron con la igualdad primero y el rango después (por ejemplo, estado y luego fecha), porque un B+Tree solo aprovecha las columnas que siguen a un rango si ese rango es la última condición (Silberschatz et al., 2014). Tres de estos índices empiezan por la columna de una clave foránea, así que reemplazaron al índice que InnoDB había creado para esa clave en lugar de sumarse a él.

Para las búsquedas de texto en las observaciones de cocina se usó un índice FULLTEXT, que es un índice invertido como el GIN de PostgreSQL. InnoDB, en cambio, no permite índices hash explícitos: mantiene automáticamente un índice hash adaptativo sobre las páginas más consultadas.

**Reescritura de consultas.** Algunas consultas no mejoraban con índices y hubo que reescribirlas:

- un filtro `DATE(fecha_pago) = ...` se reemplazó por un rango sobre la columna;
- dos subconsultas correlacionadas se convirtieron en una única unión agrupada;
- en el ranking de mozos se agregó una pista de orden de unión, porque el optimizador sobreestimaba la cantidad de comandas del trimestre.

La Tabla 3 resume el efecto acumulado de cada paso.

*Tabla 3. Tiempo de los reportes (milisegundos, mejor de tres ejecuciones)*

| Reporte | Inicial | + Estadísticas | + Índices | + Reescritura | Mejora |
| :--- | ---: | ---: | ---: | ---: | ---: |
| Ventas por categoría (3 tablas) | 828,0 | 200,0 | 138,0 | — | 6,0× |
| Arqueo de caja (3 tablas) | 47,9 | 42,2 | 31,4 | — | 1,5× |
| Ranking de mozos (2 tablas) | 305,0 | 226,0 | 100,0 | 64,2 | 3,0× |
| Pedidos de festejo (texto) | 364,0 | 72,4 | 99,4 | 11,4 | 31,9× |
| Cierre de caja del día | 24,7 | 20,4 | 20,1 | 0,2 | 123,5× |
| Mejores clientes del año | 123,0 | 130,0 | 48,6 | 39,3 | 3,1× |

*Nota.* En el ranking de mozos, la pista produce el mismo plan que los histogramas, y la diferencia entre 100 y 64 ms es variación de medición. La búsqueda con `LIKE '%texto%'` no puede usar índices B+Tree.

La consigna pide no penalizar severamente la inserción operativa, y eso se midió: se insertaron las mismas filas en tablas que solo diferían en sus índices. Los índices B+Tree nuevos encarecen la inserción de una línea de pedido un 5,9 %. El índice FULLTEXT no agrega un costo medible en la operación normal, pero encarece una carga masiva un 43,6 %. Por eso, en futuras migraciones, conviene quitarlo, cargar los datos y volver a crearlo.

**Data warehouse y fuentes heterogéneas.** Los reportes estratégicos agregan cientos de miles de filas y no deberían competir con la toma de comandas. Por eso se construyó un esquema analítico separado con un modelo en estrella (Kimball y Ross, 2013): una tabla de hechos de ventas rodeada de las dimensiones tiempo, turno, producto, mesa, cliente, mozo y medio de pago. Se carga mediante un proceso ETL desde tres fuentes heterogéneas:

- la base relacional, de forma incremental;
- una planilla Excel de costos de proveedores, exportada en Windows-1252 con coma decimal y errores de carga manual;
- el registro de texto del sistema de pantallas de cocina, con líneas de sistema y líneas corruptas mezcladas.

El proceso valida cada fila antes de convertirla y registra las descartadas con su motivo (Tabla 4).

*Tabla 4. Resultado del proceso ETL*

| Fuente | Filas leídas | Cargadas | Rechazadas |
| :--- | ---: | ---: | ---: |
| Planilla de costos de proveedores | 267 | 263 | 4 |
| Registro de cocina (KDS) | 50.834 | 50.562 | 272 |
| Base relacional (líneas de pedido cobradas) | — | 297.885 | 0 |

**Particionamiento.** La tabla de hechos se particionó por rango, con un mes por partición, y la de tiempos de cocina por lista, con una partición por estación (Oracle Corporation, s.f.-h). InnoDB no admite claves foráneas en tablas particionadas; en un data warehouse es lo habitual, porque la integridad la garantiza el ETL. El plan de ejecución muestra que un reporte de septiembre lee solo la partición de ese mes (poda de particiones). Además, borrar un semestre completo pasa a ser una operación sobre particiones en lugar de un borrado fila por fila (Tabla 5). Un evento mensual crea por adelantado las particiones de los próximos tres meses.

*Tabla 5. Efecto del particionamiento*

| Operación | Particionada | Sin particionar |
| :--- | ---: | ---: |
| Ventas de un mes por producto | 7,0 ms | 253 ms |
| Borrado de un semestre (63.243 filas) | 2.661 ms | 6.426 ms |

**Vista materializada.** MySQL no tiene vistas materializadas nativas, así que se implementaron con sus tres componentes:

1. una tabla con las ventas mensuales precalculadas;
2. un procedimiento que recalcula solo los meses que recibieron datos nuevos;
3. un evento programado que ejecuta el ETL y el refresco cada 15 minutos (Oracle Corporation, s.f.-j).

El intervalo coincide con el RPO de los respaldos de la Fase 2: los datos de gestión pueden tener hasta 15 minutos de atraso. La misma consulta pasó de 816 ms sobre la base operativa a 467 ms sobre el esquema en estrella y a 0,6 ms sobre la vista materializada.

El evento se replica al Nodo 2 deshabilitado, para que el refresco no se ejecute dos veces. Si el Nodo 1 quedara fuera de servicio por mucho tiempo, se lo habilita manualmente.

**Descubrimiento de conocimiento.** Sobre el data warehouse se aplicaron dos técnicas del proceso KDD (Fayyad et al., 1996):

- **Reglas de asociación (Agrawal y Srikant, 1994):** descubrieron qué productos se piden juntos, como las empanadas con cerveza IPA (lift 4,0) o el bife con Malbec.
- **Segmentación de clientes por recencia, frecuencia y monto (RFM):** mostró que el segmento "Campeones" reúne el 19 % de los clientes y aporta el 45,6 % de las ventas a clientes fidelizados.

El cruce del registro de cocina con la base operativa reveló, además, que todas las estaciones se demoran entre un 25 % y un 35 % más en el pico de las 21 h. Los resultados se presentan en un tablero dimensional que lee solo el esquema analítico (Tabla 6).

*Tabla 6. Reglas de asociación con mayor lift*

| Quien pide | también pide | Confianza | Lift |
| :--- | :--- | ---: | ---: |
| Empanada criolla | Cerveza IPA | 60,4 % | 4,03 |
| Ojo de bife | Vino Malbec | 70,1 % | 3,33 |
| Bife de chorizo | Vino Malbec | 69,7 % | 3,31 |
| Sorrentinos | Volcán de chocolate | 55,5 % | 3,31 |
| Sorrentinos | Agua mineral | 60,0 % | 2,83 |

---

## Referencias nuevas para agregar a la bibliografía

Agrawal, R., & Srikant, R. (1994). Fast algorithms for mining association rules. En *Proceedings of the 20th International Conference on Very Large Data Bases* (pp. 487–499). Morgan Kaufmann.

Fayyad, U., Piatetsky-Shapiro, G., & Smyth, P. (1996). From data mining to knowledge discovery in databases. *AI Magazine, 17*(3), 37–54. https://doi.org/10.1609/aimag.v17i3.1230

Kimball, R., & Ross, M. (2013). *The data warehouse toolkit: The definitive guide to dimensional modeling* (3.ª ed.). Wiley.

Oracle Corporation. (s.f.-g). *Optimizing queries with EXPLAIN*. MySQL 8.0 Reference Manual. https://dev.mysql.com/doc/refman/8.0/en/using-explain.html

Oracle Corporation. (s.f.-h). *Partitioning*. MySQL 8.0 Reference Manual. https://dev.mysql.com/doc/refman/8.0/en/partitioning.html

Oracle Corporation. (s.f.-i). *Optimizer statistics*. MySQL 8.0 Reference Manual. https://dev.mysql.com/doc/refman/8.0/en/optimizer-statistics.html

Oracle Corporation. (s.f.-j). *Using the Event Scheduler*. MySQL 8.0 Reference Manual. https://dev.mysql.com/doc/refman/8.0/en/event-scheduler.html
