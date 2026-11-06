-- ============================================================================
-- AE4 - TIFAS: CONFIGURACIÓN DE USUARIO DE REPLICACIÓN Y PERMISOS (NODO 1)
-- ============================================================================

SET sql_log_bin = 0;

-- Creación del usuario de replicación para topología simétrica (Nodo 1 <-> Nodo 2)
CREATE USER IF NOT EXISTS 'repl_user'@'%' IDENTIFIED WITH mysql_native_password BY 'repl_password_ae4';
GRANT REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO 'repl_user'@'%';

-- Permisos sobre la base de datos para el usuario de aplicación del Salón
GRANT ALL PRIVILEGES ON restaurante_db.* TO 'app_salon'@'%';

FLUSH PRIVILEGES;

SET sql_log_bin = 1;
RESET MASTER;
