-- ============================================================================
-- AE4 - TIFAS: ENLACE DE REPLICACIÓN BIDIRECCIONAL (NODO 1 -> ESCUCHA A NODO 2)
-- ============================================================================

SET sql_log_bin = 0;

CHANGE MASTER TO
    MASTER_HOST = '172.28.0.12',
    MASTER_PORT = 3306,
    MASTER_USER = 'repl_user',
    MASTER_PASSWORD = 'repl_password_ae4',
    MASTER_AUTO_POSITION = 1,
    MASTER_CONNECT_RETRY = 5,
    MASTER_RETRY_COUNT = 86400;

SET sql_log_bin = 1;
