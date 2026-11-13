#!/usr/bin/env bash
# ============================================================================
# AE4 - TIFAS FASE 3: EJECUCIÓN COMPLETA Y REPRODUCIBLE
# ----------------------------------------------------------------------------
# Ejecuta todos los scripts de fase3/ en orden y mide cada reporte en cuatro
# etapas, para atribuir cada mejora a su causa:
#   A. inicial        : sin índices nuevos y con las estadísticas como quedaron
#   B. +estadísticas  : ANALYZE TABLE de todas las tablas
#   C. +índices       : estrategia de indexación de 03_indices.sql
#   D. +reescritura   : versión optimizada de la consulta (_optimizada.sql)
# Cada tiempo es el mejor de 3 ejecuciones de EXPLAIN ANALYZE (tiempo real
# medido por el servidor, con los datos ya en memoria).
#
# Uso (desde restaurant-cluster/, con Docker Desktop abierto):
#     bash pruebas_fase3/ejecutar_fase3.sh --desde-cero      # reinicia el clúster y ejecuta todo (~10 min)
#     bash pruebas_fase3/ejecutar_fase3.sh                   # sobre un clúster recién reiniciado
#     agregar --sin-benchmark para saltear la medición de inserción (~3 min)
# La salida completa queda en pruebas_fase3/resultados/.
# ============================================================================
source "$(dirname "$0")/../pruebas_fase2/comun.sh"
RESULTADOS=pruebas_fase3/resultados

DESDE_CERO=0
BENCHMARK=1
for a in "$@"; do
    case "$a" in
        --desde-cero) DESDE_CERO=1 ;;
        --sin-benchmark) BENCHMARK=0 ;;
        *) echo "Opción desconocida: $a"; exit 1 ;;
    esac
done

registrar ejecutar_fase3
titulo "FASE 3: TUNING, INDEXACIÓN, PARTICIONAMIENTO, VISTAS MATERIALIZADAS Y KDD"
T_INICIO="$(ahora_ms)"

if (( DESDE_CERO )); then
    paso "0. Reinicio del clúster desde cero"
    bash pruebas_fase2/reiniciar_entorno.sh --si | grep -E '\[OK\]|\[ERROR\]'
fi
precondiciones

# sql_archivo <contenedor> <archivo> [opciones de mysql]: ejecuta un script completo
sql_archivo() {
    local c="$1" f="$2"; shift 2
    local salida
    salida="$(docker exec -i "$c" mysql -uroot -p"$ROOT_PW" --default-character-set=utf8mb4 "$@" < "$f" 2>&1)" \
        || { echo "$salida"; falla "error al ejecutar $f"; }
    grep -v -e 'Using a password' -e 'World-writable' <<< "$salida" || true
}

paso "Verificando que el clúster esté en el estado inicial"
YA_INDEXADO="$(sql_nodo "$N1" "SELECT COUNT(*) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = 'restaurante_db' AND INDEX_NAME = 'idx_comandas_estado_fecha'")"
YA_DW="$(sql_nodo "$N1" "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = 'restaurante_dw'")"
[[ "$YA_INDEXADO" == "0" && "$YA_DW" == "0" ]] \
    || falla "la Fase 3 ya se ejecutó sobre este clúster: usar --desde-cero"
ok "sin índices de la Fase 3 ni data warehouse"

# ----------------------------------------------------------------------------
paso "1. Carga masiva de datos históricos (fase3/01_carga_masiva.sql)"
sql_archivo "$N1" fase3/01_carga_masiva.sql -t | sed 's/^/   /'

# ----------------------------------------------------------------------------
# Medición de reportes
# ----------------------------------------------------------------------------
REPORTES=(r1_ventas_por_categoria r2_arqueo_de_caja r3_ranking_mozos r4_pedidos_festejo r5_cierre_del_dia r6_mejores_clientes)
declare -A TIEMPO

# medir <archivo.sql>: deja en $MEJOR el mejor tiempo (ms) de 3 EXPLAIN ANALYZE
# y en $PLAN el último plan. Se llama sin $(...) para que las variables lleguen.
MEJOR=""
PLAN=""
medir() {
    local f="$1" t salida
    MEJOR=""
    for _ in 1 2 3; do
        salida="$( { echo "USE restaurante_db; EXPLAIN ANALYZE"; cat "$f"; } \
                   | docker exec -i "$N1" mysql -uroot -p"$ROOT_PW" --default-character-set=utf8mb4 -N -r 2>/dev/null)"
        t="$(head -1 <<< "$salida" | grep -oE 'actual time=[^ ]+' | head -1 | sed 's/.*\.\.//' | awk '{ printf "%.1f", $1 }')"
        if [[ -z "$MEJOR" ]] || awk -v a="$t" -v b="$MEJOR" 'BEGIN { exit !(a < b) }'; then
            MEJOR="$t"
        fi
        PLAN="$salida"
    done
}

medir_etapa() {
    local etapa="$1" mostrar_plan="$2" r f
    for r in "${REPORTES[@]}"; do
        f="fase3/consultas/$r.sql"
        [[ "$etapa" == "D" ]] && f="fase3/consultas/${r}_optimizada.sql"
        [[ -f "$f" ]] || continue
        medir "$f"
        TIEMPO["$r,$etapa"]="$MEJOR"
        info "$(printf '%-26s %10s ms' "$r" "${TIEMPO["$r,$etapa"]}")"
        if [[ "$mostrar_plan" == "plan" ]]; then
            sed 's/^/        /' <<< "$PLAN" | cut -c1-230
        fi
    done
}

paso "2A. Reportes en el estado inicial (planes de ejecución con EXPLAIN ANALYZE)"
info "Estadísticas que el optimizador tiene de las tablas chicas (TABLE_ROWS):"
sql_nodo "$N1" "SELECT TABLE_NAME, TABLE_ROWS FROM information_schema.TABLES WHERE TABLE_SCHEMA = 'restaurante_db' ORDER BY TABLE_NAME" \
    | awk '{ printf "      %-28s %s filas estimadas\n", $1, $2 }'
info "Filas reales en productos_menu: $(sql_nodo "$N1" "SELECT COUNT(*) FROM productos_menu")"
medir_etapa A plan

paso "2B. Reportes después de actualizar las estadísticas (ANALYZE TABLE)"
sql_nodo "$N1" "ANALYZE TABLE clientes, mesas, productos_menu, movimientos_stock, comandas, historial_estados_comanda, detalle_comanda, pagos" > /dev/null
medir_etapa B sin_plan

paso "2C. Estrategia de indexación (fase3/03_indices.sql)"
sql_archivo "$N1" fase3/03_indices.sql -t | sed 's/^/   /'
medir_etapa C plan

paso "2D. Consultas reescritas (fase3/consultas/*_optimizada.sql)"
medir_etapa D plan

paso "Resumen de tiempos (ms, mejor de 3)"
printf '   %-26s %10s %14s %10s %13s %9s\n' "Reporte" "A inicial" "B +estadíst." "C +índices" "D +reescrit." "Mejora"
for r in "${REPORTES[@]}"; do
    a="${TIEMPO["$r,A"]}"; final="${TIEMPO["$r,D"]:-${TIEMPO["$r,C"]}}"
    printf '   %-26s %10s %14s %10s %13s %8sx\n' "$r" "$a" "${TIEMPO["$r,B"]}" "${TIEMPO["$r,C"]}" "${TIEMPO["$r,D"]:--}" \
        "$(awk -v a="$a" -v f="$final" 'BEGIN { printf "%.1f", a / (f > 0 ? f : 0.001) }')"
done

# ----------------------------------------------------------------------------
if (( BENCHMARK )); then
    paso "3. Costo de los índices sobre la tasa de inserción (fase3/04_benchmark_insercion.sql, ~3 min)"
    sql_archivo "$N1" fase3/04_benchmark_insercion.sql -t | sed 's/^/   /'
else
    paso "3. Benchmark de inserción omitido (--sin-benchmark)"
fi

# ----------------------------------------------------------------------------
paso "4. Data warehouse en estrella con tablas de hechos particionadas (05)"
sql_archivo "$N1" fase3/05_data_warehouse.sql -t | sed 's/^/   /'

paso "5. Fuentes heterogéneas: planilla Excel (CSV) y log del KDS (06)"
docker cp fase3/fuentes/planilla_costos_proveedores.csv "$N1":/var/lib/mysql-files/planilla_costos_proveedores.csv
ok "planilla copiada a /var/lib/mysql-files del Nodo 1 ($(wc -l < fase3/fuentes/planilla_costos_proveedores.csv) líneas, Windows-1252)"
docker exec "$N1" rm -f /var/lib/mysql-files/kds_eventos.log
sql_archivo "$N1" fase3/06_generar_log_kds.sql
docker cp "$N1":/var/lib/mysql-files/kds_eventos.log fase3/fuentes/kds_eventos.log
ok "log del KDS generado: $(wc -l < fase3/fuentes/kds_eventos.log) líneas (copia en fase3/fuentes/kds_eventos.log)"
info "Muestra del log:"
grep -m1 '\[KDS\]' fase3/fuentes/kds_eventos.log | sed 's/^/      /'
grep -m1 '\[SYS\]' fase3/fuentes/kds_eventos.log | sed 's/^/      /'
grep -m1 'duracion_seg=ERR' fase3/fuentes/kds_eventos.log | sed 's/^/      /'

paso "6. ETL de las tres fuentes (07 y 08)"
sql_archivo "$N1" fase3/07_etl_procedimientos.sql
sql_archivo "$N1" fase3/08_etl_carga.sql -t | sed 's/^/   /'

paso "7. Vista materializada y política de refresco (09)"
sql_archivo "$N1" fase3/09_vistas_materializadas.sql -t | sed 's/^/   /'

paso "8. Mantenimiento automático de particiones (10)"
sql_archivo "$N1" fase3/10_particionamiento.sql -t | sed 's/^/   /'

paso "9. Demostración de la optimización física (11)"
sql_archivo "$N1" fase3/11_demostracion_optimizacion_fisica.sql -t | cut -c1-230 | sed 's/^/   /'

paso "10. Descubrimiento de conocimiento: reglas de asociación, RFM y tiempos de cocina (12)"
sql_archivo "$N1" fase3/12_kdd.sql -t | sed 's/^/   /'

paso "11. Consultas OLAP sobre el cubo (13)"
sql_archivo "$N1" fase3/13_cubo_olap.sql -t | sed 's/^/   /'

paso "12. Tablero dimensional"
bash pruebas_fase3/generar_tablero.sh

# ----------------------------------------------------------------------------
paso "13. Replicación del data warehouse: comparación de cada tabla en ambos nodos"
sleep 3
TABLAS_DW="$(sql_nodo "$N1" "SELECT GROUP_CONCAT(TABLE_NAME ORDER BY TABLE_NAME) FROM information_schema.TABLES WHERE TABLE_SCHEMA = 'restaurante_dw' AND TABLE_TYPE = 'BASE TABLE'")"
DIFERENTES=0
for t in ${TABLAS_DW//,/ }; do
    c1="$(sql_nodo "$N1" "CHECKSUM TABLE restaurante_dw.$t" | cut -f2)"
    c2="$(sql_nodo "$N2" "CHECKSUM TABLE restaurante_dw.$t" | cut -f2)"
    if [[ "$c1" == "$c2" ]]; then r="IGUAL"; else r="DIFERENTE"; DIFERENTES=$((DIFERENTES + 1)); fi
    printf '   %-26s %14s %14s   %s\n' "$t" "$c1" "$c2" "$r"
done
info "Eventos en cada nodo (en el Nodo 2 quedan deshabilitados por ser réplica):"
sql_nodo "$N1" "SELECT CONCAT('      Nodo 1: ', EVENT_NAME, ' ', STATUS) FROM information_schema.EVENTS WHERE EVENT_SCHEMA = 'restaurante_dw'"
sql_nodo "$N2" "SELECT CONCAT('      Nodo 2: ', EVENT_NAME, ' ', STATUS) FROM information_schema.EVENTS WHERE EVENT_SCHEMA = 'restaurante_dw'"
(( DIFERENTES == 0 )) && ok "las tablas del data warehouse son idénticas en ambos nodos" \
                      || falla "$DIFERENTES tablas del data warehouse difieren"

bash pruebas_fase2/verificar_consistencia.sh

titulo "FASE 3 COMPLETA en $(segundos_desde "$T_INICIO") s"
