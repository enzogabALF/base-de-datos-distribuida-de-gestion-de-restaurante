# Texto para el informe: secciones 5.5 y 5.6

> **Nota para el equipo (borrar al pegar):** este texto reemplaza los "(Pendiente.)" de las secciones 5.5 y 5.6 del informe. Mantiene el estilo y la numeración de citas del informe actual: Oracle Corporation s.f.-a, -b y -c ya existen, y se agregan s.f.-d y s.f.-e. Al final están las referencias nuevas para la bibliografía. Las cifras salen de las pruebas guardadas en `restaurant-cluster/pruebas_fase2/resultados/`. El detalle técnico completo está en `docs/FASE2_RESILIENCIA_Y_BACKUPS.md`.

---

## 5.5. Prueba de caída y failover

La replicación mantiene los mismos datos en ambos nodos, pero eso no alcanza para seguir operando: si la aplicación del salón se conecta directamente al Nodo 1 y ese nodo cae, el salón se detiene aunque el Nodo 2 tenga toda la información. Por eso se agregó un balanceador HAProxy entre las aplicaciones y la base de datos. Cada área se conecta a un punto de entrada propio:

- **Salón (puerto 3310):** usa el Nodo 1 como principal y el Nodo 2 como respaldo.
- **Cocina (puerto 3311):** usa el Nodo 2 como principal y el Nodo 1 como respaldo.

HAProxy verifica cada dos segundos que cada nodo acepte un inicio de sesión MySQL real. Si el nodo principal falla tres veces seguidas, redirige las conexiones al respaldo y, cuando el principal se recupera, el tráfico vuelve a él (HAProxy Technologies, s.f.). Como cada área escribe en un único nodo a la vez, se respeta la fragmentación funcional del diseño.

Se realizaron cuatro pruebas reproducibles, cuyos resultados se resumen en la Tabla 1.

**Caída abrupta.** Se confirmó una comanda en el Nodo 1 y se lo detuvo sin apagado ordenado, como en un corte de energía. HAProxy redirigió el salón al Nodo 2 en 8,6 segundos, y la comanda confirmada antes de la caída estaba en el Nodo 2. La primera escritura posterior demoró 3,3 segundos, porque el nodo esperó la confirmación del otro hasta agotar el tiempo de la replicación semisincrónica. Después la replicación pasó a ser asincrónica y las escrituras volvieron a tardar 0,2 segundos. Durante la falla el sistema priorizó la disponibilidad, como plantea el teorema CAP (Brewer, 2012).

Al reiniciar el Nodo 1, su registro mostró el proceso descripto en la sección 5.3:

1. InnoDB detectó que los archivos de datos estaban atrasados respecto del último checkpoint.
2. Inició la recuperación ("Starting crash recovery") y reaplicó 16 registros del redo log.
3. Coordinó con el binary log las transacciones pendientes ("XA crash recovery").

Luego se puso al día por GTID en menos de un segundo, recibió el tráfico del salón de nuevo y ambos nodos quedaron idénticos.

**Conmutación planificada (switchover).** Para un mantenimiento programado, el nodo no se apaga de golpe:

1. Se lo pone en solo lectura.
2. Se espera a que el otro nodo aplique todas sus transacciones, comprobándolo con los GTID.
3. Recién entonces se lo retira del balanceador.

El salón quedó sin poder escribir solo 1,7 segundos, y no se perdió ninguna transacción.

**Partición de red.** Se cortó la replicación entre los nodos mientras cada área seguía conectada al suyo. Ambas siguieron registrando comandas, y los identificadores impares y pares evitaron cualquier colisión de claves. Al restablecer el enlace, los nodos se reconciliaron en 3,7 segundos.

La prueba también mostró el límite del diseño. Si las dos áreas modifican la misma fila durante la partición, cada nodo aplica el cambio del otro y los valores quedan cruzados sin que MySQL lo advierta. Esto confirma la regla de que cada tabla tenga un único nodo dueño de sus escrituras. Además, se incorporó un script que compara una huella digital de cada tabla en ambos nodos y detecta este tipo de divergencias.

**Pérdida del disco de un nodo.** La replicación por sí sola no alcanza para reconstruir un nodo perdido. En una topología circular, cada servidor descarta los eventos que llevan su propio identificador, para que no circulen indefinidamente entre los nodos. Por eso el nodo rehecho ignoraba las transacciones que él mismo había generado antes de la falla, y en la prueba quedó con 11 de 16 comandas sin informar ningún error.

El procedimiento adoptado es:

1. Sembrar el nodo con una copia consistente del nodo sobreviviente, que incluye el conjunto exacto de GTID que contiene.
2. Reanudar la replicación.

Así el nodo se reconstruyó en 54 segundos sin pérdida de datos.

*Tabla 1. Resultados de las pruebas de tolerancia a fallas*

| Escenario | Datos perdidos (RPO) | Tiempo sin servicio (RTO) |
| :--- | :--- | :--- |
| Caída abrupta de un nodo | 0 | 8,6 s |
| Conmutación planificada | 0 | 1,7 s |
| Partición de red entre nodos | 0 | 0 s (ambas áreas siguieron operando) |
| Pérdida del disco de un nodo | 0 | 54 s (el otro nodo atendió mientras tanto) |

## 5.6. Política de copias de seguridad (RPO/RTO)

La replicación protege contra la caída de un servidor, pero no contra un error. Si alguien borra datos por equivocación, la orden se replica al otro nodo en milisegundos. Por eso el sistema necesita copias de seguridad con historia.

La política se definió a partir de dos objetivos de negocio:

- **Punto de recuperación (RPO):** cuántos datos puede perder el restaurante.
- **Tiempo de recuperación (RTO):** cuánto tiempo puede estar sin sistema.

Perder un cobro genera un problema fiscal, y quedarse sin sistema en pleno servicio paraliza el salón y la cocina. Por eso se fijó un RPO máximo de 15 minutos y un RTO de 30 minutos ante errores lógicos.

La política combina tres tipos de copia (Tabla 2), que un servicio dedicado ejecuta automáticamente:

- **Completa:** usa `mysqldump` dentro de una única transacción. Así obtiene una foto consistente de la base sin bloquear a los mozos ni a la cocina, y registra la posición exacta del binary log en ese instante (Oracle Corporation, s.f.-e).
- **Diferencial e incremental:** copian los archivos del binary log, que registran cada cambio confirmado fila por fila. El diferencial guarda todo lo ocurrido desde la copia completa; el incremental, solo lo ocurrido desde la última copia de cualquier tipo.

*Tabla 2. Política de copias de seguridad*

| Tipo | Frecuencia | Contenido | Retención |
| :--- | :--- | :--- | :--- |
| Completa | Diaria | Toda la base de datos | 7 días |
| Diferencial | Cada 6 horas | Cambios desde la última copia completa | Con su copia completa |
| Incremental | Cada 15 minutos | Cambios desde la última copia de cualquier tipo | Con su copia completa |

Para restaurar alcanza con la copia completa, el último diferencial y los incrementales posteriores. Eso acorta la recuperación y reduce el riesgo de que un incremental dañado impida restaurar. Cada copia guarda un código de verificación (SHA-256) que se controla antes de usarla.

La restauración se ejecuta sobre una instancia separada, sin tocar los nodos en servicio. Como los binary logs registran cada transacción, se puede recuperar el estado de la base en cualquier instante, o reaplicar todo salvo una transacción determinada (Oracle Corporation, s.f.-d).

La política se probó con un caso de desastre lógico. Se ejecutó por error un borrado de todos los pagos en el Nodo 1, y la replicación lo propagó de inmediato: ambos nodos quedaron sin pagos. Después se restauró la copia completa, el diferencial y el último incremental, excluyendo únicamente la transacción del borrado, identificada por su GTID. La restauración tardó 5,7 segundos y recuperó:

- los cuatro pagos borrados;
- una comanda registrada después del error, que no se perdió.

Los pagos se reinyectaron en el Nodo 1, la replicación los llevó al Nodo 2 y el total cobrado volvió a coincidir exactamente con el anterior al error.

La política también tolera fallas del propio sistema de copias. Si el nodo del que se toman las copias está caído, el servicio inicia una nueva serie desde el otro nodo, que tiene todos los datos gracias a la replicación completa.

Como mejora para un entorno real, las copias deberían guardarse además fuera del equipo donde corren los nodos (regla 3-2-1), para proteger los datos ante la pérdida total de la instalación.

---

## Referencias nuevas para agregar a la bibliografía

HAProxy Technologies. (s.f.). *HAProxy 2.8 configuration manual*. https://docs.haproxy.org/2.8/configuration.html

Oracle Corporation. (s.f.-d). *Point-in-time (incremental) recovery*. MySQL 8.0 Reference Manual. https://dev.mysql.com/doc/refman/8.0/en/point-in-time-recovery.html

Oracle Corporation. (s.f.-e). *mysqldump — A database backup program*. MySQL 8.0 Reference Manual. https://dev.mysql.com/doc/refman/8.0/en/mysqldump.html
