# Análisis de Estado del Proyecto y Lista de Tareas Pendientes

**Proyecto:** Sistema Distribuido de Gestión Gastronómica (AE4 - TIFAS)  
**Repositorio:** `base-de-datos-distribuida-de-gestion-de-restaurante`  
**Propósito del documento:** Relevar qué componentes ya están terminados y detallar la lista accionable de correcciones y tareas que restan implementar por el equipo.

---

## 1. Análisis de lo que YA está Realizado

### 1.1. Infraestructura, Contenedores y Red (`100% Completado`)
* **`docker-compose.yml`:** Orquestación de los dos nodos simétricos sobre MySQL 8.0 (`restaurante_nodo1_salon` en puerto `3307` / IP `172.28.0.11` y `restaurante_nodo2_cocina` en puerto `3308` / IP `172.28.0.12`) con red bridge dedicada (`172.28.0.0/24`) y `healthcheck`.
* **Configuración de Motores (`nodo1/conf/my.cnf` y `nodo2/conf/my.cnf`):**
  * Prevención matemática de colisiones: `auto_increment_increment = 2` con `offset = 1` en Nodo 1 (IDs impares) y `offset = 2` en Nodo 2 (IDs pares).
  * Durabilidad ACID: `innodb_flush_log_at_trx_commit = 1` y `sync_binlog = 1`.
  * Replicación Semisincrónica: Plugins `semisync_master.so` y `semisync_slave.so` activos con `rpl_semi_sync_master_wait_point = AFTER_SYNC` y timeout de `3000 ms`.
  * Trazabilidad GTID: `gtid_mode = ON`, `enforce_gtid_consistency = ON` y `binlog_format = ROW`.
* **Enlace de Replicación Bidireccional (`02_setup_repl_user.sql` y `03_configure_replication.sql`):**
  * Creación automática del usuario `repl_user` y configuración cruzada `CHANGE MASTER TO ... MASTER_AUTO_POSITION = 1` en ambos nodos.

### 1.2. Modelado de Datos Relacional y DDL (`100% Completado`)
* **Esquema Global (`01_schema_restaurante.sql` en Nodo 1 y Nodo 2):**
  * 8 tablas en motor transaccional **InnoDB** en 3FN (`clientes`, `mesas`, `productos_menu`, `movimientos_stock`, `comandas`, `historial_estados_comanda`, `detalle_comanda`, `pagos`).
  * Restricciones declarativas implementadas: `PRIMARY KEY`, `FOREIGN KEY` (`ON DELETE RESTRICT` / `CASCADE` / `SET NULL`), `UNIQUE` (`numero_mesa`, `cuit_dni`, `id_comanda` en pagos), `CHECK` (`precio >= 0`, `cantidad > 0`, `stock >= 0`, `capacidad > 0`), `ENUM` de estados y columna calculada `subtotal GENERATED ALWAYS AS (cantidad * precio_unitario) STORED`.

### 1.3. Scripts Operativos Iniciales y Documentación Base (`Avanzado`)
* **Catálogo semilla:** `04_seed_catalogos.sql` en ambos nodos.
* **ABM Salón (Nodo 1):** `nodo1/scripts_abm/abm_salon.sql` y `nodo1/scripts_abm/verificacion_tecnica_nodo1.sql`.
* **ABM Cocina (Nodo 2):** `nodo2/scripts_abm/abm_cocina.sql`.
* **Documentación:** `docs/MODELADO_Y_DISTRIBUCION_AE4.md` y `docs/GUIA_DESPLIEGUE_Y_OPERACION.md`.

---

## 2. Lista de Tareas Pendientes para Realizar (Backlog del Compañero)

A partir de la auditoría técnica de los scripts SQL actuales, se identificaron **4 tareas concretas** (1 corrección crítica de semillas/FKs y 3 implementaciones/mejoras de pruebas) que deben realizarse para cerrar el trabajo sin errores de ejecución:

---

### 🔴 Tarea 1 (Prioridad Crítica): Fijar IDs explícitos en `04_seed_catalogos.sql` (Nodo 1 y Nodo 2)

* **Problema detectado:**
  En `nodo1/init/04_seed_catalogos.sql` y `nodo2/init/04_seed_catalogos.sql`, la tabla `productos_menu` sí tiene definidos explícitamente los `id_producto` del `1` al `12`, pero los `INSERT` de **`clientes`** y **`mesas`** no especifican `id_cliente` ni `id_mesa`.
  Como ese archivo corre localmente con `SET sql_log_bin = 0`:
  * En **Nodo 1** (`offset = 1`), las 10 mesas se crean con `id_mesa` **impares** (`1, 3, 5, 7, 9, 11, 13, 15, 17, 19`) y los 4 clientes con `id_cliente` **impares** (`1, 3, 5, 7`).
  * En **Nodo 2** (`offset = 2`), las 10 mesas se crean con `id_mesa` **pares** (`2, 4, 6, 8, 10, 12, 14, 16, 18, 20`) y los 4 clientes con `id_cliente` **pares** (`2, 4, 6, 8`).
* **Consecuencia actual:**
  1. `verificacion_tecnica_nodo1.sql` (líneas 50-53) intenta insertar comandas con `id_mesa = 4` e `id_cliente = 2` en el Nodo 1, lo cual falla con **`ERROR 1452: Cannot add or update a child row: a foreign key constraint fails`** porque en el Nodo 1 solo existen IDs impares.
  2. `abm_salon.sql` (líneas 19 y 30) intenta usar `id_mesa = 2` en el Nodo 1, que tampoco existe.
  3. Cuando el Nodo 1 inserta una comanda con `id_mesa = 1` e `id_cliente = 1`, al viajar por replicación al **Nodo 2**, el hilo `Slave_SQL_Running` del Nodo 2 se detiene por error de clave foránea porque en el Nodo 2 no existen `id_mesa = 1` ni `id_cliente = 1`.
* **Qué debe hacer el compañero:**
  Modificar `nodo1/init/04_seed_catalogos.sql` y `nodo2/init/04_seed_catalogos.sql` agregando explícitamente `id_cliente` (`1, 2, 3, 4`) en el `INSERT INTO clientes` e `id_mesa` (`1, 2, 3, 4, 5, 6, 7, 8, 9, 10`) en el `INSERT INTO mesas` en ambos archivos (igual que se hizo con `productos_menu`).

---

### 🟠 Tarea 2 (Prioridad Alta): Crear `verificacion_tecnica_nodo2.sql` en `nodo2/scripts_abm/`

* **Qué falta:**
  El Nodo 1 cuenta con `nodo1/scripts_abm/verificacion_tecnica_nodo1.sql`, pero el Nodo 2 no tiene su script equivalente de verificación técnica.
* **Qué debe hacer el compañero:**
  Crear el archivo `restaurant-cluster/nodo2/scripts_abm/verificacion_tecnica_nodo2.sql` que incluya:
  1. Verificación de variables de servidor del Nodo 2 (`@@server_id = 2`, `@@auto_increment_increment = 2`, `@@auto_increment_offset = 2`, `@@gtid_mode = ON`).
  2. Verificación de variables y estado de replicación semisincrónica (`SHOW VARIABLES LIKE 'rpl_semi_sync%'`, `SHOW STATUS LIKE 'Rpl_semi_sync%'`).
  3. Comprobación de que las comandas, historiales y movimientos de stock originados en el Nodo 2 generan exclusivamente claves primarias **pares** (`MOD(id_comanda, 2) = 0`).

---

### 🟡 Tarea 3 (Prioridad Media): Registrar el movimiento `VENTA_COMANDA` en `abm_cocina.sql`

* **Problema detectado:**
  En `01_schema_restaurante.sql`, la tabla `movimientos_stock` define el tipo `'VENTA_COMANDA'` dentro de su `ENUM('INGRESO_PROVEEDOR', 'VENTA_COMANDA', 'MERMA_ROTURA', 'AJUSTE_INVENTARIO')`. Sin embargo, en `nodo2/scripts_abm/abm_cocina.sql` (Caso 2.A, líneas 157-161), cuando Cocina marcha los platos de una comanda y descuenta `stock_disponible` en `productos_menu`, **no se inserta el movimiento en `movimientos_stock`**.
* **Qué debe hacer el compañero:**
  En el **Caso 2.A** de `nodo2/scripts_abm/abm_cocina.sql`, antes de descontar `stock_disponible` en `productos_menu`, agregar un `INSERT INTO movimientos_stock ... SELECT ...` con `tipo_movimiento = 'VENTA_COMANDA'` para que el Kardex de inventario (`Consulta 4.3`) refleje también los descuentos por comandas marchadas.

---

### 🟢 Tarea 4 (Prioridad Media): Script / Protocolo de Prueba Integrada Entre Nodos y Failover

* **Qué falta:**
  Actualmente los scripts `abm_salon.sql` y `abm_cocina.sql` están pensados por separado, pero falta un script o guía de prueba cruzada (`docs/EVIDENCIA_PRUEBAS_DISTRIBUIDAS.md` o script integrado) que documente la ejecución combinada entre ambos nodos.
* **Qué debe hacer el compañero:**
  Documentar y capturar la salida de 3 pruebas clave del clúster:
  1. **Flujo cruzado Salón ↔ Cocina:** Abrir la comanda `#1` en Nodo 1 (`3307`), verificar que aparece en la comandera del Nodo 2 (`3308`), marcharla y despacharla desde el Nodo 2 (`LISTA_PARA_SERVIR`), y finalmente cobrarla en el Nodo 1 (`PAGADA`).
  2. **Desactivación de CHECK constraints comentadas:** Capturar la evidencia de los errores esperados (`Error 3819` por `CHECK` y `Error 1062` por `UNIQUE`) del Bloque 2 de `verificacion_tecnica_nodo1.sql`.
  3. **Prueba de Tolerancia a Fallos (Caída y Recuperación de un Nodo):**
     * Detener el Nodo 2 (`docker stop restaurante_nodo2_cocina`).
     * Insertar una comanda en el Nodo 1 verificando que tras el timeout (`3000 ms`) pasa a autonomía local (`Rpl_semi_sync_master_status = OFF`) sin perder disponibilidad.
     * Volver a encender el Nodo 2 (`docker start restaurante_nodo2_cocina`) y comprobar que recupera automáticamente las transacciones pendientes mediante GTID (`Seconds_Behind_Master = 0` y `Rpl_semi_sync_master_status = ON`).

---

## 3. Checklist Resumen para el Compañero

- [x] **1.** Agregar `id_cliente` (`1..4`) e `id_mesa` (`1..10`) explícitos en `nodo1/init/04_seed_catalogos.sql` y `nodo2/init/04_seed_catalogos.sql`.
- [x] **2.** Reiniciar limpio el clúster (borrando `nodo1/data/*` y `nodo2/data/*`) y validar que `verificacion_tecnica_nodo1.sql` y `abm_salon.sql` corran de principio a fin sin errores de Foreign Key ni rotura de replicación en `SHOW SLAVE STATUS`.
- [x] **3.** Crear `nodo2/scripts_abm/verificacion_tecnica_nodo2.sql` validando IDs pares (`MOD(id, 2) = 0`) y estado semisync del Nodo 2.
- [x] **4.** Agregar el `INSERT INTO movimientos_stock` (`VENTA_COMANDA`) en el Caso 2.A de `nodo2/scripts_abm/abm_cocina.sql`.
- [x] **5.** Ejecutar y documentar la prueba cruzada Nodo 1 ↔ Nodo 2 y la prueba de caída/recuperación de un nodo (`failover`).

### Estado al 13/11/2026: tareas completadas

| Tarea | Dónde quedó |
| :--- | :--- |
| 1 y 2 | `04_seed_catalogos.sql` con IDs explícitos y reloj fijo. El reinicio limpio se automatizó en `pruebas_fase2/reiniciar_entorno.sh`, que ejecuta todos los scripts de ABM y verifica la consistencia. Además se corrigió la codificación de los acentos con `SET NAMES utf8mb4`. Detalle en `FASE2_RESILIENCIA_Y_BACKUPS.md`, sección 6.1, y en `EVIDENCIA_PRUEBAS_DISTRIBUIDAS.md`, sección 4. |
| 3 | `nodo2/scripts_abm/verificacion_tecnica_nodo2.sql` (configuración, semisync, réplica, altas con IDs pares y chequeo automático de violaciones). |
| 4 | Caso 2.A de `abm_cocina.sql`: movimiento `VENTA_COMANDA` con bloqueo `FOR UPDATE` y agrupado por producto. |
| 5 | `pruebas_fase1/prueba_flujo_cruzado.sh`, `pruebas_fase1/prueba_restricciones.sh` (17/17 errores esperados) y `pruebas_fase2/prueba_failover.sh`. Evidencia en `EVIDENCIA_PRUEBAS_DISTRIBUIDAS.md`. |
