-- ============================================================================
-- AE4 - TIFAS FASE 2: USUARIOS DE ALTA DISPONIBILIDAD Y RESPALDO (NODO 2)
-- Se ejecuta con sql_log_bin = 0: cada nodo crea sus propios usuarios
-- localmente (igual que 02_setup_repl_user.sql) y no se replican.
-- ============================================================================

SET sql_log_bin = 0;

-- 1. Usuario de chequeo de salud para HAProxy (option mysql-check).
--    Sin contraseña y SIN privilegios: solo puede autenticarse, no leer datos.
--    HAProxy lo usa para saber si el nodo acepta conexiones MySQL reales.
CREATE USER IF NOT EXISTS 'haproxy_check'@'172.28.0.%'
    IDENTIFIED WITH mysql_native_password BY '';

-- 2. Usuario de respaldo con privilegios mínimos (principio de menor privilegio):
--    - SELECT, SHOW VIEW, TRIGGER, EVENT, LOCK TABLES: leer el esquema y los datos (mysqldump).
--    - RELOAD: FLUSH TABLES WITH READ LOCK (punto consistente) y FLUSH BINARY LOGS (rotación).
--    - REPLICATION CLIENT: SHOW BINARY LOGS / posición del binlog.
--    - REPLICATION SLAVE: descargar binlogs remotos con mysqlbinlog --read-from-remote-server.
--    - PROCESS: requerido por mysqldump 8.0 para leer metadatos de tablespaces.
CREATE USER IF NOT EXISTS 'backup_user'@'172.28.0.%'
    IDENTIFIED BY 'backup_password_ae4';
GRANT SELECT, SHOW VIEW, TRIGGER, EVENT, LOCK TABLES, RELOAD, PROCESS,
      REPLICATION CLIENT, REPLICATION SLAVE
    ON *.* TO 'backup_user'@'172.28.0.%';

-- 3. Usuarios de aplicación cruzados para el failover.
--    El entrypoint de Docker crea app_cocina solo en el Nodo 2 y app_salon solo en
--    el Nodo 1. Si el Nodo 2 cae, HAProxy envía a la Cocina contra el Nodo 1, así que
--    ambos usuarios deben existir en ambos nodos con las mismas credenciales.
CREATE USER IF NOT EXISTS 'app_salon'@'%' IDENTIFIED BY 'salon_password_ae4';
GRANT ALL PRIVILEGES ON restaurante_db.* TO 'app_salon'@'%';

FLUSH PRIVILEGES;

SET sql_log_bin = 1;
