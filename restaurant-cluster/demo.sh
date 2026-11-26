#!/usr/bin/env bash
# ============================================================================
# AE4 - TIFAS: DEMOSTRACIÓN INTERACTIVA DEL CLÚSTER
# ----------------------------------------------------------------------------
# Menú para presentar el proyecto en vivo sobre el clúster ya levantado:
# estado de los nodos, pruebas de las Fases 1 y 2, la Fase 3 consultada en
# vivo (índices, particiones, vista materializada, KDD), la evidencia guardada,
# el panel de HAProxy y el tablero.
#
# Uso (Git Bash en Windows, o bash en Linux/macOS, con Docker Desktop abierto):
#     cd restaurant-cluster
#     bash demo.sh
#
# No borra datos: no ejecuta reiniciar_entorno.sh ni la Fase 3 desde cero.
# Si los contenedores están detenidos, los levanta conservando los datos.
# ============================================================================
source "$(dirname "$0")/pruebas_fase2/comun.sh"
set +Eeuo pipefail   # el menú sigue aunque una prueba falle

if [[ -t 1 ]]; then
    NEG=$'\e[1m'; CIAN=$'\e[36m'; VERDE=$'\e[32m'; ROJO=$'\e[31m'; AMAR=$'\e[33m'; GRIS=$'\e[90m'; RST=$'\e[0m'
else
    NEG=''; CIAN=''; VERDE=''; ROJO=''; AMAR=''; GRIS=''; RST=''
fi

# --------------------------------------------------------------------------
# Utilidades
# --------------------------------------------------------------------------
encabezado() {
    printf '\n%s══════════════════════════════════════════════════════════════════%s\n' "$CIAN" "$RST"
    printf '%s %s%s\n' "$NEG" "$*" "$RST"
    printf '%s══════════════════════════════════════════════════════════════════%s\n' "$CIAN" "$RST"
}

# explicar "línea 1" "línea 2" ...: qué demuestra la parte que sigue
explicar() {
    printf '%sQué se demuestra:%s\n' "$AMAR" "$RST"
    local l
    for l in "$@"; do printf '%s  • %s%s\n' "$AMAR" "$l" "$RST"; done
    echo
}

comando() { printf '%s$ %s%s\n\n' "$GRIS" "$*" "$RST"; }

pausa() { echo; read -r -p "${GRIS}Enter para continuar...${RST}" _; }

# tabla <contenedor> <esquema> <consulta>: resultado con formato de tabla
tabla() {
    docker exec "$1" mysql -uroot -p"$ROOT_PW" --default-character-set=utf8mb4 -t -D "$2" -e "$3" 2>/dev/null
}

# correr <script> [args]: ejecuta una prueba existente e informa el resultado
correr() {
    comando "bash $*"
    local inicio=$SECONDS
    bash "$@"
    local rc=$?
    echo
    if (( rc == 0 )); then
        printf '%s%s✔ %s terminó bien (%d s)%s\n' "$VERDE" "$NEG" "$1" $((SECONDS - inicio)) "$RST"
    else
        printf '%s%s✘ %s terminó con error (código %d)%s\n' "$ROJO" "$NEG" "$1" "$rc" "$RST"
    fi
    return $rc
}

# abrir <url|archivo>: lo abre con el programa predeterminado del sistema
abrir() {
    local destino="$1"
    if [[ -e "$destino" ]] && command -v cygpath >/dev/null 2>&1; then
        destino="$(cygpath -w "$(cd "$(dirname "$destino")" && pwd)/$(basename "$destino")")"
    fi
    if command -v cmd.exe >/dev/null 2>&1; then
        cmd.exe /c start "" "$destino" >/dev/null 2>&1
    elif command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$destino" >/dev/null 2>&1 &
    elif command -v open >/dev/null 2>&1; then
        open "$destino"
    else
        echo "Abrir manualmente: $destino"; return
    fi
    printf '%s✔ Abierto: %s%s\n' "$VERDE" "$1" "$RST"
}

# ver_archivo <ruta>: lo muestra paginado (q para salir)
ver_archivo() {
    if command -v less >/dev/null 2>&1; then
        printf '%s(flechas o espacio para avanzar, q para salir)%s\n' "$GRIS" "$RST"; sleep 1
        less -R "$1"
    else
        cat "$1"
    fi
}

# --------------------------------------------------------------------------
# Comprobación inicial: Docker abierto y clúster arriba
# --------------------------------------------------------------------------
verificar_entorno() {
    if ! docker info >/dev/null 2>&1; then
        printf '%sDocker no responde. Abrí Docker Desktop, esperá a que diga "Engine running" y volvé a ejecutar: bash demo.sh%s\n' "$ROJO" "$RST"
        exit 1
    fi
    local faltan=() c
    for c in "$N1" "$N2" "$HA" "$BK"; do
        docker ps --format '{{.Names}}' | grep -q "^$c$" || faltan+=("$c")
    done
    if (( ${#faltan[@]} > 0 )); then
        printf '%sContenedores detenidos: %s%s\n' "$AMAR" "${faltan[*]}" "$RST"
        echo "Levantándolos con 'docker compose up -d' (los datos se conservan)..."
        docker compose up -d
    fi
    printf 'Esperando que los nodos estén sanos'
    for c in "$N1" "$N2"; do esperar_healthy "$c" 180 || { printf '\n%s%s no quedó healthy%s\n' "$ROJO" "$c" "$RST"; exit 1; }; printf '.'; done
    local i
    for i in $(seq 1 30); do replicacion_ok "$N1" && replicacion_ok "$N2" && break; printf '.'; sleep 2; done
    echo
    if replicacion_ok "$N1" && replicacion_ok "$N2"; then
        printf '%s✔ Clúster listo: 2 nodos sanos y replicación activa en ambos sentidos%s\n' "$VERDE" "$RST"
    else
        printf '%s✘ La replicación no está corriendo; revisar con la opción 1%s\n' "$ROJO" "$RST"
    fi
}

# --------------------------------------------------------------------------
# Secciones de la demo
# --------------------------------------------------------------------------
estado_cluster() {
    encabezado "ARQUITECTURA: ESTADO DEL CLÚSTER"
    explicar "Dos nodos MySQL 8.0 multiprimario: Nodo 1 = Salón/Caja, Nodo 2 = Cocina/Stock." \
             "Fragmentación de claves: el Nodo 1 genera IDs impares (offset 1) y el Nodo 2 pares (offset 2)." \
             "Replicación bidireccional semisincrónica con GTID; HAProxy enruta cada área a su nodo."

    comando "docker ps"
    docker ps --filter name=restaurante --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
    echo

    printf '%sConfiguración de cada nodo%s\n' "$NEG" "$RST"
    tabla "$N1" "$DB" "SELECT 'Nodo 1' AS nodo, @@hostname AS hostname, @@server_id AS server_id, @@auto_increment_increment AS incremento, @@auto_increment_offset AS offset_ids, @@gtid_mode AS gtid, @@read_only AS solo_lectura"
    tabla "$N2" "$DB" "SELECT 'Nodo 2' AS nodo, @@hostname AS hostname, @@server_id AS server_id, @@auto_increment_increment AS incremento, @@auto_increment_offset AS offset_ids, @@gtid_mode AS gtid, @@read_only AS solo_lectura"

    printf '\n%sReplicación (cada nodo es réplica del otro)%s\n' "$NEG" "$RST"
    for c in "$N1" "$N2"; do
        local s
        s="$(docker exec "$c" mysql -uroot -p"$ROOT_PW" -e "SHOW REPLICA STATUS\G" 2>/dev/null)"
        printf '  %-26s origen=%-12s IO=%-4s SQL=%-4s atraso=%ss  semisincrónica=%s\n' "$c" \
            "$(awk -F': ' '/ Source_Host:/ {print $2}' <<< "$s")" \
            "$(awk -F': ' '/ Replica_IO_Running:/ {print $2}' <<< "$s")" \
            "$(awk -F': ' '/ Replica_SQL_Running:/ {print $2}' <<< "$s")" \
            "$(awk -F': ' '/ Seconds_Behind_Source:/ {print $2}' <<< "$s")" \
            "$(semisync "$c")"
    done

    printf '\n%sEnrutamiento de HAProxy (lo que ve cada aplicación)%s\n' "$NEG" "$RST"
    printf '  App Salón  -> puerto 3310 -> %s\n' "$(sql_app salon "SELECT @@hostname" || echo 'sin respuesta')"
    printf '  App Cocina -> puerto 3311 -> %s\n' "$(sql_app cocina "SELECT @@hostname" || echo 'sin respuesta')"

    printf '\n%sVolumen de datos (Nodo 1)%s\n' "$NEG" "$RST"
    tabla "$N1" "$DB" "SELECT TABLE_NAME AS tabla, TABLE_ROWS AS filas_aprox FROM information_schema.TABLES WHERE TABLE_SCHEMA='restaurante_db' ORDER BY TABLE_NAME"
}

consistencia() {
    encabezado "CONSISTENCIA ENTRE NODOS"
    explicar "Compara hilos de replicación, conjunto de transacciones (GTID) y una huella digital de cada tabla." \
             "Si todas las tablas dan IGUAL, los dos nodos tienen exactamente los mismos datos."
    correr pruebas_fase2/verificar_consistencia.sh
}

# cargar_cliente <contenedor> <nombre del nodo>: pide nombre y DNI por teclado y los
# inserta en ese nodo. Deja el DNI cargado en CARGADO. Si el motor rechaza el alta
# (por ejemplo, DNI repetido: restricción UNIQUE), muestra el error y lo vuelve a pedir.
cargar_cliente() {
    local c="$1" nodo="$2" nombre dni err intento
    for intento in 1 2 3; do
        nombre=''; dni=''
        while [[ -z "$nombre" ]]; do read -r -p "   Nombre del cliente a cargar en el $nodo: " nombre; done
        while [[ -z "$dni" ]]; do read -r -p "   DNI o CUIT: " dni; done
        nombre="${nombre//\'/\'\'}"; dni="${dni//\'/\'\'}"
        echo
        comando "INSERT INTO clientes (nombre_completo, cuit_dni) VALUES ('$nombre', '$dni');   -- en el $nodo"
        err="$(docker exec "$c" mysql -uroot -p"$ROOT_PW" --default-character-set=utf8mb4 -D "$DB" \
               -e "INSERT INTO clientes (nombre_completo, cuit_dni) VALUES ('$nombre', '$dni')" 2>&1 | grep -v Warning)"
        if [[ -z "$err" ]]; then
            CARGADO="$dni"
            printf '%s   ✔ Cliente cargado en el %s%s\n' "$VERDE" "$nodo" "$RST"
            return 0
        fi
        printf '%s   ✘ El motor rechazó el alta: %s%s\n' "$ROJO" "$err" "$RST"
        printf '%s   (si el DNI ya existe, lo rechaza la restricción UNIQUE; probá con otro)%s\n\n' "$AMAR" "$RST"
    done
    return 1
}

replicacion_en_vivo() {
    encabezado "REPLICACIÓN EN VIVO: UN DATO CARGADO EN UN NODO APARECE EN EL OTRO"
    explicar "Vos cargás un cliente en el Nodo 1 (Salón) y se lee enseguida desde el Nodo 2 (Cocina)." \
             "Después cargás otro en el Nodo 2 y se leen los dos desde el Nodo 1: la replicación es bidireccional." \
             "El ID que genera el Nodo 1 es impar y el del Nodo 2 es par: así los IDs nunca chocan." \
             "Al final se pueden borrar los clientes cargados, y el borrado también se replica."
    local dnis=() lista ver r

    printf '%s1) Cargá un cliente en el Nodo 1 (Salón)%s\n' "$NEG" "$RST"
    cargar_cliente "$N1" "Nodo 1 (Salón)" || return
    dnis+=("$CARGADO")
    lista="'${dnis[0]}'"
    ver="SELECT id_cliente, nombre_completo, cuit_dni, @@hostname AS leido_en FROM clientes WHERE cuit_dni IN"
    tabla "$N1" "$DB" "$ver ($lista) ORDER BY id_cliente"
    pausa

    printf '\n%s2) Se lee desde el Nodo 2 (Cocina): ya está replicado%s\n' "$NEG" "$RST"
    sleep 1
    comando "SELECT ... FROM clientes WHERE cuit_dni = ${lista};   -- en el Nodo 2"
    tabla "$N2" "$DB" "$ver ($lista) ORDER BY id_cliente"
    pausa

    printf '\n%s3) Ahora al revés: cargá un cliente en el Nodo 2 (Cocina)%s\n' "$NEG" "$RST"
    if cargar_cliente "$N2" "Nodo 2 (Cocina)"; then
        dnis+=("$CARGADO")
        lista="'${dnis[0]}', '${dnis[1]}'"
        sleep 1
        printf '\n%s   Se leen los dos desde el Nodo 1: el del Salón con ID impar y el de la Cocina con ID par%s\n' "$NEG" "$RST"
        comando "SELECT ... FROM clientes WHERE cuit_dni IN (${lista});   -- en el Nodo 1"
        tabla "$N1" "$DB" "$ver ($lista) ORDER BY id_cliente"
    fi

    echo
    read -r -p "¿Borrar los clientes cargados para dejar la base como estaba? (S/n): " r
    [[ "$r" == [nN] ]] && return
    printf '\n%s4) Limpieza: se borran en el Nodo 1 y el borrado llega al Nodo 2%s\n' "$NEG" "$RST"
    comando "DELETE FROM clientes WHERE cuit_dni IN (${lista});   -- en el Nodo 1"
    docker exec "$N1" mysql -uroot -p"$ROOT_PW" --default-character-set=utf8mb4 -D "$DB" \
        -e "DELETE FROM clientes WHERE cuit_dni IN ($lista)" 2>/dev/null
    sleep 1
    printf '   Clientes cargados que quedan: Nodo 1 = %s | Nodo 2 = %s\n' \
        "$(sql_nodo "$N1" "SELECT COUNT(*) FROM clientes WHERE cuit_dni IN ($lista)")" \
        "$(sql_nodo "$N2" "SELECT COUNT(*) FROM clientes WHERE cuit_dni IN ($lista)")"
}

# esc <texto>: escapa comillas simples y barras para usarlo dentro de un literal SQL
esc() { local v="${1//\\/\\\\}"; printf '%s' "${v//\'/\'\'}"; }

# sql_err <contenedor> <sql>: ejecuta mostrando los errores del motor (sin los avisos)
sql_err() {
    docker exec "$1" mysql -uroot -p"$ROOT_PW" --default-character-set=utf8mb4 -N -B -D "$DB" -e "$2" 2>&1 \
        | { grep -v Warning || true; }
}

abm_completo() {
    encabezado "ABM COMPLETO: ALTA, MODIFICACIÓN, PEDIDO Y BAJA DE UN CLIENTE"
    explicar "ALTA: cargás un cliente nuevo en el Nodo 1 (Salón)." \
             "MODIFICACIÓN: le cambiás teléfono y email; el cambio se ve replicado en el Nodo 2." \
             "PEDIDO: le abrís una comanda en una mesa libre con un plato de la carta; la Cocina la ve en el Nodo 2." \
             "BAJA: se cancela el pedido, se libera la mesa y se da de baja al cliente (baja lógica)." \
             "Al final se puede borrar todo lo cargado para dejar la base como estaba."
    local ficha="SELECT id_cliente, nombre_completo, cuit_dni, telefono, email, IF(activo, 'ACTIVO', 'DADO DE BAJA') AS estado, @@hostname AS leido_en FROM clientes WHERE id_cliente ="
    local dni idc tel mail mesa idm prod precio cant idcom pedido err r

    # 1. ALTA
    printf '%s1) ALTA: cargá un cliente nuevo en el Nodo 1 (Salón)%s\n' "$NEG" "$RST"
    cargar_cliente "$N1" "Nodo 1 (Salón)" || return
    dni="$CARGADO"
    idc="$(sql_nodo "$N1" "SELECT id_cliente FROM clientes WHERE cuit_dni = '$dni'")"
    tabla "$N1" "$DB" "$ficha $idc"
    pausa

    # 2. MODIFICACIÓN
    printf '\n%s2) MODIFICACIÓN: actualizá sus datos de contacto (Nodo 1)%s\n' "$NEG" "$RST"
    read -r -p "   Teléfono: " tel
    read -r -p "   Email: " mail
    tel="$(esc "$tel")"; mail="$(esc "$mail")"
    echo
    comando "UPDATE clientes SET telefono = '$tel', email = '$mail' WHERE id_cliente = $idc;   -- en el Nodo 1"
    err="$(sql_err "$N1" "UPDATE clientes SET telefono = NULLIF('$tel', ''), email = NULLIF('$mail', '') WHERE id_cliente = $idc")"
    [[ -n "$err" ]] && printf '%s   ✘ %s%s\n' "$ROJO" "$err" "$RST"
    sleep 1
    printf '%s   Se lee desde el Nodo 2: la modificación ya está replicada%s\n' "$NEG" "$RST"
    tabla "$N2" "$DB" "$ficha $idc"
    pausa

    # 3. PEDIDO
    printf '\n%s3) PEDIDO: abrile una comanda en una mesa libre (Nodo 1, Salón)%s\n' "$NEG" "$RST"
    echo "   Mesas libres:"
    tabla "$N1" "$DB" "SELECT numero_mesa AS mesa, capacidad, sector FROM mesas WHERE estado = 'LIBRE' ORDER BY numero_mesa"
    while true; do
        read -r -p "   Número de mesa: " mesa
        idm=''
        [[ "$mesa" =~ ^[0-9]+$ ]] && idm="$(sql_nodo "$N1" "SELECT id_mesa FROM mesas WHERE numero_mesa = $mesa AND estado = 'LIBRE'")"
        [[ -n "$idm" ]] && break
        echo "   Esa mesa no existe o no está libre; elegí una de la lista."
    done
    echo "   Carta:"
    tabla "$N1" "$DB" "SELECT id_producto AS codigo, nombre, precio FROM productos_menu WHERE activo = 1 ORDER BY id_producto"
    while true; do
        read -r -p "   Código del plato: " prod
        precio=''
        [[ "$prod" =~ ^[0-9]+$ ]] && precio="$(sql_nodo "$N1" "SELECT precio FROM productos_menu WHERE id_producto = $prod AND activo = 1")"
        [[ -n "$precio" ]] && break
        echo "   Código inválido; elegí uno de la carta."
    done
    while true; do
        read -r -p "   Cantidad: " cant
        [[ "$cant" =~ ^[1-9][0-9]?$ ]] && break
        echo "   Ingresá un número entre 1 y 99."
    done
    echo
    comando "START TRANSACTION;
  UPDATE mesas SET estado = 'OCUPADA' WHERE numero_mesa = $mesa;
  INSERT INTO comandas (id_mesa, id_cliente, mozo, nodo_origen, estado) VALUES ($idm, $idc, 'Mozo Demo', 'NODO_1_SALON', 'ABIERTA');
  INSERT INTO historial_estados_comanda (...) VALUES (..., 'ABIERTA', ...);
  INSERT INTO detalle_comanda (id_comanda, id_producto, cantidad, precio_unitario) VALUES (..., $prod, $cant, $precio);
  UPDATE comandas SET total = (SELECT SUM(subtotal) FROM detalle_comanda WHERE ...);
COMMIT;   -- en el Nodo 1"
    idcom="$(sql_err "$N1" "START TRANSACTION;
        UPDATE mesas SET estado = 'OCUPADA' WHERE id_mesa = $idm AND estado = 'LIBRE';
        INSERT INTO comandas (id_mesa, id_cliente, mozo, nodo_origen, estado, total) VALUES ($idm, $idc, 'Mozo Demo', 'NODO_1_SALON', 'ABIERTA', 0);
        SET @c = LAST_INSERT_ID();
        INSERT INTO historial_estados_comanda (id_comanda, estado_anterior, estado_nuevo, operador, nodo_emisor, observacion)
            VALUES (@c, NULL, 'ABIERTA', 'Mozo Demo', 'NODO_1_SALON', 'Apertura de comanda (demo en vivo)');
        INSERT INTO detalle_comanda (id_comanda, id_producto, cantidad, precio_unitario, estado_cocina, punto_coccion)
            VALUES (@c, $prod, $cant, $precio, 'PENDIENTE', 'NO_APLICA');
        UPDATE comandas SET total = (SELECT SUM(subtotal) FROM detalle_comanda WHERE id_comanda = @c) WHERE id_comanda = @c;
        COMMIT;
        SELECT @c;")"
    if [[ ! "$idcom" =~ ^[0-9]+$ ]]; then
        printf '%s   ✘ No se pudo abrir la comanda: %s%s\n' "$ROJO" "$idcom" "$RST"
        return
    fi
    printf '%s   ✔ Comanda #%s abierta (ID impar: la generó el Nodo 1)%s\n' "$VERDE" "$idcom" "$RST"
    pedido="SELECT co.id_comanda AS comanda, cl.nombre_completo AS cliente, m.numero_mesa AS mesa, p.nombre AS plato, d.cantidad, co.total, co.estado, d.estado_cocina AS cocina, @@hostname AS leido_en
            FROM comandas co JOIN detalle_comanda d ON d.id_comanda = co.id_comanda JOIN productos_menu p ON p.id_producto = d.id_producto
            JOIN mesas m ON m.id_mesa = co.id_mesa LEFT JOIN clientes cl ON cl.id_cliente = co.id_cliente WHERE co.id_comanda = $idcom"
    sleep 1
    printf '%s   La Cocina ve el pedido en el Nodo 2:%s\n' "$NEG" "$RST"
    tabla "$N2" "$DB" "$pedido"
    pausa

    # 4. BAJA
    printf '\n%s4) BAJA: se cancela el pedido, se libera la mesa y se da de baja al cliente (Nodo 1)%s\n' "$NEG" "$RST"
    comando "START TRANSACTION;
  UPDATE comandas SET estado = 'CANCELADA', motivo_cancelacion = 'Baja del cliente', fecha_cierre = NOW() WHERE id_comanda = $idcom;
  INSERT INTO historial_estados_comanda (...) VALUES ($idcom, 'ABIERTA', 'CANCELADA', ...);
  UPDATE detalle_comanda SET estado_cocina = 'ANULADO' WHERE id_comanda = $idcom;
  UPDATE mesas SET estado = 'LIBRE' WHERE numero_mesa = $mesa;
  UPDATE clientes SET activo = 0 WHERE id_cliente = $idc;
COMMIT;   -- en el Nodo 1"
    err="$(sql_err "$N1" "START TRANSACTION;
        UPDATE comandas SET estado = 'CANCELADA', motivo_cancelacion = 'Baja del cliente (demo en vivo)', fecha_cierre = NOW() WHERE id_comanda = $idcom;
        INSERT INTO historial_estados_comanda (id_comanda, estado_anterior, estado_nuevo, operador, nodo_emisor, observacion)
            VALUES ($idcom, 'ABIERTA', 'CANCELADA', 'Jefe de Salón', 'NODO_1_SALON', 'Cancelación por baja del cliente');
        UPDATE detalle_comanda SET estado_cocina = 'ANULADO' WHERE id_comanda = $idcom;
        UPDATE mesas SET estado = 'LIBRE' WHERE id_mesa = $idm;
        UPDATE clientes SET activo = 0 WHERE id_cliente = $idc;
        COMMIT;")"
    [[ -n "$err" ]] && printf '%s   ✘ %s%s\n' "$ROJO" "$err" "$RST"
    sleep 1
    printf '%s   Desde el Nodo 2: el cliente figura dado de baja y su pedido cancelado%s\n' "$NEG" "$RST"
    tabla "$N2" "$DB" "$ficha $idc"
    tabla "$N2" "$DB" "$pedido"
    echo "   Es una baja lógica: el cliente no se borra, para conservar el historial de sus pedidos."

    echo
    read -r -p "¿Borrar todo lo cargado (cliente y comanda) para dejar la base como estaba? (S/n): " r
    [[ "$r" == [nN] ]] && return
    comando "DELETE FROM comandas WHERE id_comanda = $idcom;   DELETE FROM clientes WHERE id_cliente = $idc;   -- en el Nodo 1 (detalle e historial se borran en cascada)"
    err="$(sql_err "$N1" "DELETE FROM comandas WHERE id_comanda = $idcom; DELETE FROM clientes WHERE id_cliente = $idc;")"
    [[ -n "$err" ]] && printf '%s   ✘ %s%s\n' "$ROJO" "$err" "$RST"
    sleep 1
    printf '   Lo cargado que queda: Nodo 1 = %s | Nodo 2 = %s\n' \
        "$(sql_nodo "$N1" "SELECT (SELECT COUNT(*) FROM clientes WHERE id_cliente = $idc) + (SELECT COUNT(*) FROM comandas WHERE id_comanda = $idcom)")" \
        "$(sql_nodo "$N2" "SELECT (SELECT COUNT(*) FROM clientes WHERE id_cliente = $idc) + (SELECT COUNT(*) FROM comandas WHERE id_comanda = $idcom)")"
}

fase1_flujo() {
    encabezado "FASE 1: FLUJO DISTRIBUIDO SALÓN → COCINA → CAJA"
    explicar "El Salón abre una comanda en el Nodo 1, la Cocina la ve replicada y la prepara en el Nodo 2," \
             "descontando stock, y el Salón la cobra de nuevo en el Nodo 1." \
             "Cada área escribe en su nodo y los IDs no chocan (impares/pares)."
    correr pruebas_fase1/prueba_flujo_cruzado.sh
}

fase1_restricciones() {
    encabezado "FASE 1: RESTRICCIONES DE INTEGRIDAD"
    explicar "Se intentan 17 operaciones inválidas (CHECK, UNIQUE, FOREIGN KEY) en ambos nodos." \
             "Los 'ERROR' que aparecen son lo esperado: el motor las rechaza y los nodos siguen idénticos."
    correr pruebas_fase1/prueba_restricciones.sh
}

fase2_failover() {
    encabezado "FASE 2: FAILOVER AUTOMÁTICO"
    explicar "Se apaga un nodo de golpe. HAProxy lo detecta y manda su área al nodo sobreviviente." \
             "La aplicación sigue trabajando sin cambiar su conexión; al volver el nodo, se pone al día solo." \
             "Tip: tener abierto el panel http://localhost:8404 (opción 13) para verlo pasar a rojo."
    correr pruebas_fase2/prueba_failover.sh
}

fase2_switchover() {
    encabezado "FASE 2: SWITCHOVER PLANIFICADO"
    explicar "Mantenimiento programado: se pasa el tráfico de un nodo al otro de forma ordenada," \
             "con el nodo saliente en solo lectura (el ERROR 1290 de read-only es lo esperado)."
    correr pruebas_fase2/switchover.sh prueba
}

fase2_particion() {
    encabezado "FASE 2: PARTICIÓN DE RED"
    explicar "Se corta el enlace entre los nodos: cada área sigue operando (disponibilidad, teorema CAP)." \
             "Al reconectarse, los nodos se reconcilian por GTID." \
             "Después se fuerza un conflicto sobre la misma mesa: el verificador lo detecta (INCONSISTENTE)" \
             "y se repara con la regla de propiedad (las mesas son del Salón). Termina CONSISTENTE."
    correr pruebas_fase2/prueba_particion.sh
}

fase2_backup() {
    encabezado "FASE 2: DESASTRE LÓGICO, RESPALDOS Y RECUPERACIÓN A UN PUNTO EN EL TIEMPO"
    explicar "Respaldo completo + diferencial + incremental, y un borrado accidental de datos." \
             "Se restaura en una instancia aislada (puerto 3309), se aplica el binlog hasta justo antes" \
             "del error (PITR), se verifica y se reinyecta en producción."
    correr pruebas_fase2/prueba_backup_restore.sh
}

fase2_reconstruir() {
    encabezado "FASE 2: RECONSTRUCCIÓN DE UN NODO PERDIDO"
    explicar "Se simula la pérdida total del disco del Nodo 2." \
             "Se reconstruye con una copia en caliente del Nodo 1 y se reengancha la replicación." \
             "Mide el RTO (tiempo de recuperación) y el RPO (datos perdidos: 0)." \
             "Con los datos de la Fase 3 tarda ~6 min (copia ~1 GB entre los nodos)."
    read -r -p "¿Ejecutarla ahora? (s/N): " r
    [[ "$r" == [sS] ]] || { echo "Para ver su resultado sin esperar: opción 12, archivo reconstruir_nodo2_*.txt"; return; }
    correr pruebas_fase2/reconstruir_nodo.sh nodo2 --simular-perdida
}

fase3_en_vivo() {
    encabezado "FASE 3 EN VIVO: ÍNDICES, PARTICIONES, VISTA MATERIALIZADA Y KDD"
    explicar "Consultas en vivo sobre los ~120.000 tickets cargados en la Fase 3."

    printf '%s1) Índices diseñados para los reportes (B+Tree, de cobertura)%s\n' "$NEG" "$RST"
    tabla "$N1" "$DB" "SELECT TABLE_NAME AS tabla, INDEX_NAME AS indice, GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX) AS columnas FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='restaurante_db' AND INDEX_NAME LIKE 'idx%' GROUP BY TABLE_NAME, INDEX_NAME"
    pausa

    printf '\n%s2) Reescritura de consultas: cierre de caja del día (R5)%s\n' "$NEG" "$RST"
    echo "   Original:   WHERE DATE(fecha_pago) = '2026-10-15'   (la función impide usar el índice)"
    echo "   Optimizada: WHERE fecha_pago >= '2026-10-15' AND fecha_pago < '2026-10-16'"
    local f
    for f in r5_cierre_del_dia r5_cierre_del_dia_optimizada; do
        printf '\n   %sEXPLAIN ANALYZE %s%s\n' "$CIAN" "$f" "$RST"
        { echo "EXPLAIN ANALYZE"; grep -v '^--' "fase3/consultas/$f.sql"; } \
            | docker exec -i "$N1" mysql -uroot -p"$ROOT_PW" --default-character-set=utf8mb4 -N -B -r -D "$DB" 2>/dev/null \
            | cut -c1-170 | sed 's/^/   /'
    done
    echo "   → la original recorre el índice entero (covering index scan); la optimizada hace un range scan."
    pausa

    printf '\n%s3) Data warehouse: tabla de hechos particionada por mes (RANGE)%s\n' "$NEG" "$RST"
    tabla "$N1" restaurante_dw "SELECT TABLE_NAME AS tabla, COUNT(*) AS particiones, SUM(TABLE_ROWS) AS filas_aprox FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='restaurante_dw' AND PARTITION_NAME IS NOT NULL GROUP BY TABLE_NAME"
    echo "   Poda de particiones: las ventas de octubre 2026 solo leen la partición de ese mes"
    comando "EXPLAIN SELECT SUM(importe) FROM hechos_ventas WHERE fecha_key BETWEEN 20261001 AND 20261031"
    docker exec "$N1" mysql -uroot -p"$ROOT_PW" -E -D restaurante_dw -e "EXPLAIN SELECT SUM(importe) FROM hechos_ventas WHERE fecha_key BETWEEN 20261001 AND 20261031" 2>/dev/null \
        | grep -E ' (table|partitions|type|rows):' | sed 's/^/   /'
    pausa

    printf '\n%s4) Vista materializada de ventas mensuales y su registro de refrescos%s\n' "$NEG" "$RST"
    tabla "$N1" restaurante_dw "SELECT periodo, FORMAT(SUM(tickets),0) AS tickets, FORMAT(SUM(importe),0) AS importe, FORMAT(SUM(margen),0) AS margen FROM mv_ventas_mensuales GROUP BY periodo ORDER BY periodo DESC LIMIT 6"
    tabla "$N1" restaurante_dw "SELECT vista, modo, inicio, filas FROM mv_control ORDER BY id_refresco DESC LIMIT 3"
    echo "   Eventos programados (activos en el Nodo 1; en el Nodo 2 quedan deshabilitados como réplica):"
    tabla "$N1" restaurante_dw "SELECT EVENT_NAME AS evento, STATUS AS estado, CONCAT(INTERVAL_VALUE,' ',INTERVAL_FIELD) AS cada FROM information_schema.EVENTS WHERE EVENT_SCHEMA='restaurante_dw'"
    pausa

    printf '\n%s5) Minería de datos (KDD): reglas de asociación "quien pide A también pide B"%s\n' "$NEG" "$RST"
    tabla "$N1" restaurante_dw "SELECT antecedente, consecuente, ROUND(soporte,3) AS soporte, ROUND(confianza,3) AS confianza, ROUND(lift,2) AS lift FROM kdd_reglas_asociacion ORDER BY lift DESC LIMIT 5"
    printf '\n%s   Segmentación de clientes RFM (recencia, frecuencia, monto)%s\n' "$NEG" "$RST"
    tabla "$N1" restaurante_dw "SELECT segmento, COUNT(*) AS clientes, ROUND(AVG(frecuencia),1) AS visitas_prom, FORMAT(AVG(monto),0) AS gasto_prom FROM kdd_segmentos_rfm GROUP BY segmento ORDER BY clientes DESC"
    pausa

    printf '\n%s6) El data warehouse también está replicado en el Nodo 2%s\n' "$NEG" "$RST"
    printf '   hechos_ventas: Nodo 1 = %s filas | Nodo 2 = %s filas\n' \
        "$(docker exec "$N1" mysql -uroot -p"$ROOT_PW" -N -B -e "SELECT COUNT(*) FROM restaurante_dw.hechos_ventas" 2>/dev/null)" \
        "$(docker exec "$N2" mysql -uroot -p"$ROOT_PW" -N -B -e "SELECT COUNT(*) FROM restaurante_dw.hechos_ventas" 2>/dev/null)"
}

fase3_resumen() {
    encabezado "FASE 3: RESULTADOS DE LA OPTIMIZACIÓN (EJECUCIÓN COMPLETA)"
    local f
    f="$(ls pruebas_fase3/resultados/ejecutar_fase3_*.txt 2>/dev/null | sort | tail -1)"
    [[ -n "$f" ]] || { echo "No hay reporte de la Fase 3 en pruebas_fase3/resultados/"; return 1; }
    explicar "Tiempos de los 6 reportes en 4 etapas: A inicial, B con estadísticas (ANALYZE TABLE)," \
             "C con índices y D con consultas reescritas. La última columna es la mejora total." \
             "La ejecución completa tarda ~50 min, por eso se muestra el reporte guardado: $f"
    awk '/^>> Resumen de tiempos/,/^>> 3\./' "$f" | sed '$d'
    printf '\n%sCosto de los índices sobre la inserción%s\n' "$NEG" "$RST"
    awk '/^>> 3\./,/^>> 4\./' "$f" | sed '1d;$d' | grep -E '\||[A-C]\.|µs|%' | head -12
    echo
    read -r -p "¿Ver el reporte completo (EXPLAIN de cada etapa)? (s/N): " r
    [[ "$r" == [sS] ]] && ver_archivo "$f"
}

evidencia() {
    encabezado "EVIDENCIA GUARDADA DE LAS PRUEBAS"
    explicar "Cada prueba guarda su salida completa con fecha y hora en la carpeta resultados/ de su fase."
    local archivos=() i=1 f
    mapfile -t archivos < <(ls pruebas_fase1/resultados/*.txt pruebas_fase2/resultados/*.txt pruebas_fase3/resultados/*.txt 2>/dev/null)
    for f in "${archivos[@]}"; do printf '  %2d) %s\n' "$i" "$f"; ((i++)); done
    echo
    read -r -p "Número del archivo a ver (Enter para volver): " n
    [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#archivos[@]} )) && ver_archivo "${archivos[$((n - 1))]}"
}

panel_haproxy() {
    encabezado "PANEL DE HAPROXY"
    explicar "Estado en tiempo real de cada nodo detrás del balanceador (verde = activo, rojo = caído)."
    abrir "http://localhost:8404"
}

tablero() {
    encabezado "TABLERO DIMENSIONAL (FASE 3)"
    explicar "Indicadores, evolución mensual, reglas de asociación y segmentos de clientes," \
             "generados desde el data warehouse en un HTML autocontenido."
    abrir "fase3/tablero/tablero.html"
}

conexion() {
    encabezado "DATOS DE CONEXIÓN (MySQL Workbench / DBeaver)"
    cat <<EOF
  Nodo 1 (Salón) directo        localhost:3307   usuario root   clave $ROOT_PW
  Nodo 2 (Cocina) directo       localhost:3308   usuario root   clave $ROOT_PW
  App Salón vía HAProxy         localhost:3310   usuario app_salon    clave salon_password_ae4
  App Cocina vía HAProxy        localhost:3311   usuario app_cocina   clave cocina_password_ae4
  Panel de HAProxy              http://localhost:8404

  Bases: restaurante_db (operativa) y restaurante_dw (data warehouse)
EOF
}

# --------------------------------------------------------------------------
# Recorrido completo, con pausa entre partes
# --------------------------------------------------------------------------
recorrido() {
    local partes=(estado_cluster panel_haproxy replicacion_en_vivo consistencia fase1_flujo abm_completo fase1_restricciones fase2_failover
                  fase2_switchover fase2_particion fase2_backup fase3_en_vivo fase3_resumen tablero)
    local p r
    for p in "${partes[@]}"; do
        echo
        read -r -p "${CIAN}Siguiente: ${p}. Enter = ejecutar, s = saltear, m = volver al menú: ${RST}" r
        case "$r" in
            [sS]) continue ;;
            [mM]) return ;;
        esac
        "$p"
    done
    printf '\n%s%s✔ Recorrido completo%s\n' "$VERDE" "$NEG" "$RST"
}

menu() {
    clear 2>/dev/null
    cat <<EOF
${CIAN}${NEG}══════════════════════════════════════════════════════════════════
 BASE DE DATOS DISTRIBUIDA - GESTIÓN DE RESTAURANTE   (AE4 - TIFAS)
══════════════════════════════════════════════════════════════════${RST}
 ${NEG}Arquitectura${RST}
   1) Estado del clúster (nodos, replicación, HAProxy)
   2) Consistencia entre nodos
   R) Replicación en vivo: cargar un dato en un nodo y verlo en el otro
   A) ABM completo: alta, modificación, pedido y baja de un cliente
 ${NEG}Fase 1 - Distribución y ABM${RST}
   3) Flujo Salón → Cocina → Caja                       (~25 s)
   4) Restricciones de integridad                       (~30 s)
 ${NEG}Fase 2 - Resiliencia y respaldos${RST}
   5) Failover automático (cae un nodo)                 (~1 min)
   6) Switchover planificado                            (~45 s)
   7) Partición de red y conflicto                      (~1,5 min)
   8) Desastre lógico, backup y PITR                    (~1-2 min)
   9) Reconstrucción de un nodo perdido                 (~6 min: mejor mostrar su reporte con la 12)
 ${NEG}Fase 3 - Tuning y analítica${RST}
  10) En vivo: índices, particiones, vista mat., KDD
  11) Resultados de la optimización (reporte guardado)
 ${NEG}Extras${RST}
  12) Evidencia guardada de las pruebas
  13) Abrir panel de HAProxy en el navegador
  14) Abrir tablero de la Fase 3 en el navegador
  15) Datos de conexión para Workbench / DBeaver
   ${NEG}T) Recorrido completo, en orden y con pausas${RST}
   0) Salir
EOF
}

# --------------------------------------------------------------------------
verificar_entorno
sleep 1
while true; do
    menu
    read -r -p "Opción: " op
    case "$op" in
        1) estado_cluster ;;
        2) consistencia ;;
        [rR]) replicacion_en_vivo ;;
        [aA]) abm_completo ;;
        3) fase1_flujo ;;
        4) fase1_restricciones ;;
        5) fase2_failover ;;
        6) fase2_switchover ;;
        7) fase2_particion ;;
        8) fase2_backup ;;
        9) fase2_reconstruir ;;
        10) fase3_en_vivo ;;
        11) fase3_resumen ;;
        12) evidencia; continue ;;
        13) panel_haproxy ;;
        14) tablero ;;
        15) conexion ;;
        [tT]) recorrido ;;
        0|q|Q) echo "Fin de la demo."; exit 0 ;;
        *) continue ;;
    esac
    echo
    read -r -p "${GRIS}Enter para volver al menú...${RST}" _
done
