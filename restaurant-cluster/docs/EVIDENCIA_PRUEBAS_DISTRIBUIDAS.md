# Evidencia de Pruebas Distribuidas entre Nodos (AE4 - TIFAS, Fase 1)

**Asignatura:** Gestión Avanzada de Bases de Datos
**Caso de estudio:** Sistema Distribuido de Gestión Gastronómica (Salón/Caja y Cocina/Stock)

Este documento cierra la Tarea 4 de [ANALISIS_ESTADO_Y_TAREAS_PENDIENTES.md](ANALISIS_ESTADO_Y_TAREAS_PENDIENTES.md). Reúne la evidencia de que el ABM funciona **repartido entre los dos nodos**, no solo dentro de cada uno, y de que las restricciones de integridad se cumplen en un entorno replicado.

Las pruebas son scripts reproducibles. Se ejecutan desde `restaurant-cluster/` con Git Bash (Windows) o bash (Linux/macOS), con Docker Desktop abierto, y guardan su salida completa en [pruebas_fase1/resultados/](../pruebas_fase1/resultados/):

```bash
cd restaurant-cluster
bash pruebas_fase2/reiniciar_entorno.sh --si     # clúster limpio + datos de los scripts de ABM
bash pruebas_fase1/prueba_flujo_cruzado.sh       # 1. ciclo de vida de una comanda entre ambos nodos
bash pruebas_fase1/prueba_restricciones.sh       # 2. CHECK, UNIQUE y FOREIGN KEY
bash pruebas_fase2/prueba_failover.sh            # 3. caída y recuperación de un nodo (Fase 2)
```

---

## 1. Flujo cruzado Salón ↔ Cocina

**Script:** [prueba_flujo_cruzado.sh](../pruebas_fase1/prueba_flujo_cruzado.sh)
**Resultado:** [prueba_flujo_cruzado_20261113_150228.txt](../pruebas_fase1/resultados/prueba_flujo_cruzado_20261113_150228.txt)

La comanda de la mesa 6 recorre todos sus estados. Cada área escribe **solo en su propio nodo**, y la otra área ve el cambio por replicación:

| Paso | Nodo que escribe | Operación | Visible en el otro nodo |
| :--- | :--- | :--- | :--- |
| 1 | Nodo 1 (Salón) | Abre la comanda #13 (ID **impar**) con 3 ítems; total $75.400 | — |
| 2 | — | La comanda aparece en la comandera de Cocina | **228 ms** |
| 3 | Nodo 2 (Cocina) | `EN_PREPARACION`, platos `EN_COCCION`, descuento de stock y 3 movimientos `VENTA_COMANDA` (IDs **pares**) | — |
| 4 | Nodo 2 (Cocina) | `LISTA_PARA_SERVIR` (campana de despacho) | **215 ms** |
| 5 | Nodo 1 (Salón) | `ENTREGADA`, pago con débito, `PAGADA`, +150 puntos al cliente, mesa `LIBRE` | — |
| 6 | — | El Nodo 2 recibe el cierre y el pago | **227 ms** |

Los tiempos incluyen el costo de lanzar `docker exec` en cada consulta (alrededor de 0,2 s), así que son una cota superior: la replicación en sí es más rápida.

**Trazabilidad.** El historial de la comanda es idéntico en ambos nodos y muestra la fragmentación de claves en acción: los eventos del Salón tienen IDs impares (23, 27, 29) y los de la Cocina, pares (24, 26). Ambos nodos escribieron en la misma tabla sin coordinarse y sin colisiones.

| id_historial | Paridad | Transición | Nodo emisor |
| :--- | :--- | :--- | :--- |
| 23 | Impar | — → `ABIERTA` | NODO_1_SALON |
| 24 | Par | `ABIERTA` → `EN_PREPARACION` | NODO_2_COCINA |
| 26 | Par | `EN_PREPARACION` → `LISTA_PARA_SERVIR` | NODO_2_COCINA |
| 27 | Impar | `LISTA_PARA_SERVIR` → `ENTREGADA` | NODO_1_SALON |
| 29 | Impar | `ENTREGADA` → `PAGADA` | NODO_1_SALON |

**Stock.** La provoleta, el ojo de bife y el Malbec pasaron de 40, 30 y 51 unidades a 39, 28 y 50, con el mismo valor en ambos nodos. El Kardex registra cada salida con su stock previo y posterior. Al final, el verificador de consistencia confirma que las **8 tablas son idénticas** en los dos nodos.

## 2. Restricciones de integridad

**Script:** [prueba_restricciones.sh](../pruebas_fase1/prueba_restricciones.sh)
**Resultado:** [prueba_restricciones_20261113_150242.txt](../pruebas_fase1/resultados/prueba_restricciones_20261113_150242.txt)

El script ejecuta, sin comentar, las sentencias inválidas del Bloque 2 de `verificacion_tecnica_nodo1.sql` y del Bloque 3 de `verificacion_tecnica_nodo2.sql`, más casos de integridad referencial. **Las 17 fueron rechazadas con el error esperado:**

| # | Nodo | Caso | Error |
| :--- | :--- | :--- | :--- |
| 1 | 1 | Precio negativo en el menú | `3819` `productos_menu_chk_1` |
| 2 | 1 | Cantidad 0 en una línea de comanda | `3819` `detalle_comanda_chk_1` |
| 3 | 1 | Número de mesa duplicado | `1062` `mesas.numero_mesa` |
| 4 | 1 | CUIT/DNI de cliente duplicado | `1062` `clientes.cuit_dni` |
| 5 | 1 | Segundo pago para una comanda ya cobrada | `1062` `pagos.id_comanda` |
| 6 | 1 | Pago con monto cero | `3819` `pagos_chk_1` |
| 7 | 1 | Mesa con capacidad 0 | `3819` `mesas_chk_1` |
| 8 | 1 | Comanda para una mesa inexistente | `1452` `fk_comanda_mesa` |
| 9 | 1 | Línea de comanda con un producto inexistente | `1452` `fk_detalle_producto` |
| 10 | 1 | Borrar una mesa que tiene comandas | `1451` `fk_comanda_mesa` (RESTRICT) |
| 11 | 1 | Borrar una comanda que tiene pago | `1451` `fk_pago_comanda` (RESTRICT) |
| 12 | 1 | Estado de comanda que no existe en el ENUM | `1265` (modo estricto) |
| 13 | 1 | Escribir a mano la columna generada `subtotal` | `3105` |
| 14 | 2 | Stock disponible negativo | `3819` `productos_menu_chk_2` |
| 15 | 2 | Movimiento que deja `stock_posterior` negativo | `3819` `movimientos_stock_chk_2` |
| 16 | 2 | Movimiento de stock de un producto inexistente | `1452` `fk_mov_producto` |
| 17 | 2 | Borrar un producto con ventas registradas | `1451` `fk_detalle_producto` (RESTRICT) |

Además, el script toma una foto de control antes y después:

- **Ninguna fila inválida quedó guardada:** las cantidades de filas por tabla y el stock total no cambiaron en ningún nodo.
- **Ninguna sentencia rechazada generó un GTID.** Una sentencia que falla nunca llega al binary log, así que **un error de integridad no puede propagarse al otro nodo ni romper la replicación**. Los hilos siguen en `Yes` y ambos nodos quedan idénticos.

Esto es lo que permite confiar la integridad referencial al motor en un entorno distribuido. Como el catálogo (mesas, clientes y productos) está replicado completo en ambos nodos, cada nodo valida localmente las claves foráneas sin consultar al otro.

## 3. Caída y recuperación de un nodo

Esta prueba se cubrió con mayor profundidad en la Fase 2, con cinco escenarios medidos. El detalle está en [FASE2_RESILIENCIA_Y_BACKUPS.md](FASE2_RESILIENCIA_Y_BACKUPS.md), sección 5.

En [prueba_failover.sh](../pruebas_fase2/prueba_failover.sh) se apaga abruptamente un nodo:

- El otro nodo sigue aceptando escrituras. La primera tarda unos 3 s (el `rpl_semi_sync_master_timeout`) y la replicación pasa a asíncrona (`Rpl_semi_sync_master_status = OFF`).
- Al volver el nodo caído, recupera por GTID las transacciones pendientes y la semisincronía vuelve a `ON`.
- No se pierde ninguna transacción confirmada.

La prueba se repitió el 13/11/2026 con el clúster cargado con el volumen de la Fase 3 (alrededor de 1 millón de filas y el data warehouse): failover en 8,5 s, RPO = 0, resincronización del nodo caído en 2,6 s y ambos nodos consistentes ([prueba_failover_20261113_163832.txt](../pruebas_fase2/resultados/prueba_failover_20261113_163832.txt)).

## 4. Correcciones hechas durante estas pruebas

| Problema | Causa | Corrección |
| :--- | :--- | :--- |
| Los acentos de la semilla y el valor por defecto `'Salón Principal'` quedaban guardados como `SalÃ³n` | El entrypoint de Docker ejecuta `init/` con el cliente `mysql` sin `LANG`, que interpreta los archivos UTF-8 como latin1 y los guarda con doble codificación (`C3 83 C2 B3` en lugar de `C3 B3`) | `SET NAMES utf8mb4;` al principio de `01_schema_restaurante.sql` y `04_seed_catalogos.sql` en ambos nodos |
| La marcha de una comanda descontaba stock sin registrarlo en el Kardex | Faltaba el `INSERT` en `movimientos_stock` del Caso 2.A de `abm_cocina.sql` | Se agregó el movimiento `VENTA_COMANDA` antes del descuento, con bloqueo `FOR UPDATE` |
| Con dos líneas del mismo producto en una comanda, se descontaba solo una | Un `UPDATE ... JOIN` modifica cada fila de `productos_menu` una sola vez | El descuento y el movimiento se calculan con `SUM(cantidad) ... GROUP BY id_producto` |
| El Nodo 2 no tenía script de verificación técnica | — | [verificacion_tecnica_nodo2.sql](../nodo2/scripts_abm/verificacion_tecnica_nodo2.sql), que también se ejecuta en `reiniciar_entorno.sh` |
