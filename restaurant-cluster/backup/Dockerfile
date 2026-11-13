# ============================================================================
# AE4 - TIFAS FASE 2: IMAGEN DEL SERVICIO DE RESPALDOS
# ----------------------------------------------------------------------------
# Parte de la misma imagen oficial que los nodos (misma versión de MySQL) y le
# agrega mysqlbinlog, que la imagen oficial no incluye. Se extrae SOLO ese binario
# del RPM oficial de Oracle de la misma versión, porque instalar el paquete cliente
# completo choca con los archivos de mysql-community-server-minimal.
#
# Contiene: mysqldump (backup completo), mysqlbinlog (backups diferenciales e
# incrementales + recuperación a un punto en el tiempo) y mysqld (instancia
# aislada donde se prueban las restauraciones).
# ============================================================================
ARG MYSQL_VERSION=8.0.46
FROM mysql:${MYSQL_VERSION}
ARG MYSQL_VERSION

RUN set -eux; \
    microdnf install -y cpio; \
    cd /tmp; \
    curl -fsSLO "https://repo.mysql.com/yum/mysql-8.0-community/el/9/x86_64/mysql-community-client-${MYSQL_VERSION}-1.el9.x86_64.rpm"; \
    rpm2cpio "mysql-community-client-${MYSQL_VERSION}-1.el9.x86_64.rpm" | cpio -idm ./usr/bin/mysqlbinlog; \
    install -m 0755 usr/bin/mysqlbinlog /usr/bin/mysqlbinlog; \
    rm -rf /tmp/*; \
    microdnf clean all; \
    mysqlbinlog --version

ENV TZ=America/Argentina/Buenos_Aires
# Se pisa el entrypoint de MySQL: este contenedor no es un servidor de base de datos,
# sino el programador de respaldos (los scripts se montan en /opt/backup).
ENTRYPOINT []
CMD ["bash", "/opt/backup/programador.sh"]
