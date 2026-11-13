# Texto para el informe: sección 6 (desafíos y tendencias)

> **Nota para el equipo (borrar al pegar):** este texto complementa la sección 6 del informe, que todavía no trataba las tres tendencias que la consigna nombra explícitamente: computación en el borde (edge computing), procesamiento en tiempo real y bases de datos distribuidas en la nube. Cada tendencia se vincula con una decisión concreta de nuestro clúster, que es lo que más se valora en el coloquio. Las referencias nuevas están al final, en APA 7.

---

## 6.x. Tendencias actuales

### Computación en el borde (edge computing)

La computación en el borde propone procesar los datos cerca de donde se generan, en lugar de enviarlos a un centro de datos remoto, para reducir la latencia y seguir operando cuando falla la conexión (Satyanarayanan, 2017; Shi et al., 2016). Un restaurante es un caso típico: la toma de comandas y la cocina no pueden detenerse porque se cae internet.

Nuestro diseño ya aplica este principio a pequeña escala. Cada área tiene un nodo propio que atiende sus operaciones de forma autónoma, y la prueba de partición de red de la Fase 2 mostró que ambas áreas siguieron registrando comandas con el enlace cortado y se reconciliaron solas al reconectarse. Llevado a una cadena con varias sucursales, cada local tendría su nodo de borde y una base central en la nube consolidaría los datos de todas. El costo es el ya analizado con el teorema CAP: mientras dura la desconexión, la consistencia entre locales es solo eventual, y los conflictos sobre los mismos datos (por ejemplo, el precio de un producto) deben evitarse asignando un único nodo dueño de cada dato.

### Procesamiento en tiempo real

La segunda tendencia es tratar los cambios de la base como un flujo continuo de eventos en lugar de consultarla periódicamente. Plataformas como Apache Kafka distribuyen esos eventos a múltiples consumidores con baja latencia (Kreps et al., 2011), y la captura de cambios (change data capture) permite publicar cada transacción confirmada leyendo el registro de la base, sin tocar la aplicación (Kleppmann, 2017).

En el proyecto, la vista materializada de ventas se refresca cada 15 minutos, una política adecuada para reportes de gestión pero no para una pantalla de cocina. El clúster ya tiene la materia prima para el tiempo real: el binary log en formato ROW registra cada fila modificada con su GTID. Un conector de captura de cambios podría publicar esos eventos en Kafka y alimentar un tablero que se actualice en segundos. Ese mismo registro es el que hoy usan la replicación y la recuperación a un punto en el tiempo de los respaldos.

### Bases de datos distribuidas en la nube

En la nube, la base de datos se contrata como servicio administrado: el proveedor se ocupa de la replicación, los respaldos y el failover. Amazon Aurora, por ejemplo, separa el procesamiento de consultas del almacenamiento, que replica seis copias de los datos en tres zonas de disponibilidad, de modo que se toleran fallas de una zona completa sin perder datos (Verbitski et al., 2017). Un paso más allá están las bases NewSQL, como Spanner de Google o CockroachDB, que ofrecen transacciones con consistencia fuerte distribuidas geográficamente, usando protocolos de consenso y relojes sincronizados (Corbett et al., 2013; Taft et al., 2020).

Varias tareas que en el proyecto resolvimos a mano (el balanceador HAProxy, el servicio de respaldos, la reconstrucción de nodos) son justamente las que un servicio administrado automatiza. A la vez, la nube atiende dos limitaciones que dejamos documentadas en la Fase 2:

- **Respaldos fuera del equipo:** hoy están en la misma máquina que los nodos, y la regla 3-2-1 exige una copia en otro sitio.
- **Quórum con un tercer nodo:** con dos nodos no hay mayoría para decidir quién sigue operando. Un tercer nodo en otra zona permitiría pasar a un esquema con quórum que elimine la ventana de pérdida de datos durante la degradación a replicación asincrónica.

### Impacto en la gestión de datos de las empresas

Estas tendencias no eliminan los compromisos de los sistemas distribuidos, sino que los vuelven configurables. Abadi (2012) señala que, aun sin particiones de red, todo sistema replicado debe elegir entre latencia y consistencia, y esa elección pasa a ser una decisión de negocio. En nuestro caso:

| Dato | Prioridad | Consecuencia |
| :--- | :--- | :--- |
| Cobros | Consistencia | Se esperan las confirmaciones de la replicación semisincrónica |
| Tablero de gestión | Latencia y costo | Se acepta un retraso de 15 minutos |

Para las empresas, el desafío se desplaza de instalar servidores a definir qué consistencia necesita cada dato, cuánto cuesta y dónde debe procesarse. Por eso el conocimiento de los mecanismos internos (replicación, registros de transacciones, particionamiento) sigue siendo indispensable aun cuando la infraestructura sea administrada por un tercero.

---

## Referencias nuevas para agregar a la bibliografía

Abadi, D. (2012). Consistency tradeoffs in modern distributed database system design: CAP is only part of the story. *Computer, 45*(2), 37–42. https://doi.org/10.1109/MC.2012.33

Corbett, J. C., Dean, J., Epstein, M., Fikes, A., Frost, C., Furman, J. J., Ghemawat, S., Gubarev, A., Heiser, C., Hochschild, P., Hsieh, W., Kanthak, S., Kogan, E., Li, H., Lloyd, A., Melnik, S., Mwaura, D., Nagle, D., Quinlan, S., … Woodford, D. (2013). Spanner: Google's globally distributed database. *ACM Transactions on Computer Systems, 31*(3), Artículo 8. https://doi.org/10.1145/2491245

Kleppmann, M. (2017). *Designing data-intensive applications: The big ideas behind reliable, scalable, and maintainable systems*. O'Reilly Media.

Kreps, J., Narkhede, N., & Rao, J. (2011). Kafka: A distributed messaging system for log processing. En *Proceedings of the 6th International Workshop on Networking Meets Databases (NetDB)*.

Satyanarayanan, M. (2017). The emergence of edge computing. *Computer, 50*(1), 30–39. https://doi.org/10.1109/MC.2017.9

Shi, W., Cao, J., Zhang, Q., Li, Y., & Xu, L. (2016). Edge computing: Vision and challenges. *IEEE Internet of Things Journal, 3*(5), 637–646. https://doi.org/10.1109/JIOT.2016.2579198

Taft, R., Sharif, I., Matei, A., VanBenschoten, N., Lewis, J., Grieger, T., Niemi, K., Woods, A., Birzin, A., Poss, R., Bardea, P., Ranade, A., Darnell, B., Gruneir, B., Jaffray, J., Zhang, L., & Mattis, P. (2020). CockroachDB: The resilient geo-distributed SQL database. En *Proceedings of the 2020 ACM SIGMOD International Conference on Management of Data* (pp. 1493–1509). https://doi.org/10.1145/3318464.3386134

Verbitski, A., Gupta, A., Saha, D., Brahmadesam, M., Gupta, K., Mittal, R., Krishnamurthy, S., Maurice, S., Kharatishvili, T., & Bao, X. (2017). Amazon Aurora: Design considerations for high throughput cloud-native relational databases. En *Proceedings of the 2017 ACM International Conference on Management of Data* (pp. 1041–1052). https://doi.org/10.1145/3035918.3056101
