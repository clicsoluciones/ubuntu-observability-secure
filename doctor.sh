#!/usr/bin/env bash
# Ubuntu 22.04/24.04 - Observability & Active Security Stack Doctor
# Diagnoses and automatically repairs permissions, systemd units, service health,
# and active metric/log ingestion (Prometheus, Loki, Alloy, Grafana, CrowdSec, auditd).
set -Eeuo pipefail
umask 027

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
GRAFANA_PORT="${GRAFANA_PORT:-3000}"
CHECK_ONLY=0

show_help() {
  cat <<'EOF'
Uso: sudo ./doctor.sh [OPCIONES]

Herramienta de diagnóstico y autorreparación para la suite de Observabilidad y Seguridad Activa.

Opciones:
  --fix                (Por defecto) Diagnostica y repara automáticamente permisos, servicios e ingesta.
  --check-only         Modo solo lectura: reporta problemas sin aplicar cambios ni reiniciar servicios.
  --port <PUERTO>      Puerto HTTP de Grafana a verificar (por defecto: 3000 o detectado del drop-in).
  -h, --help           Muestra esta ayuda y termina.

Ejemplos:
  sudo ./doctor.sh
  sudo ./doctor.sh --check-only
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fix)
      CHECK_ONLY=0
      shift
      ;;
    --check-only)
      CHECK_ONLY=1
      shift
      ;;
    --port)
      if [[ $# -lt 2 || -z "${2:-}" || ! "${2:-}" =~ ^[0-9]+$ ]]; then
        echo "Error: --port requiere un número de puerto válido." >&2
        exit 1
      fi
      GRAFANA_PORT="$2"
      shift 2
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    *)
      echo "Opción desconocida: $1" >&2
      echo "Usa: $0 --help" >&2
      exit 1
      ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "Error: Requiere privilegios de superusuario. Ejecuta con: sudo $0" >&2
  exit 1
fi

# Auto-detect custom Grafana port from drop-in if present
if [[ -f /etc/systemd/system/grafana-server.service.d/observability.conf ]]; then
  detected_port="$(awk -F= '/GF_SERVER_HTTP_PORT=/ {gsub(/"/, "", $2); print $2}' /etc/systemd/system/grafana-server.service.d/observability.conf | tail -n1 || true)"
  if [[ -n "$detected_port" && "$detected_port" =~ ^[0-9]+$ ]]; then
    GRAFANA_PORT="$detected_port"
  fi
fi

# Colors & Counters
if [[ -t 1 ]]; then
  C_RESET='\033[0m'
  C_GREEN='\033[1;32m'
  C_YELLOW='\033[1;33m'
  C_BLUE='\033[1;34m'
  C_RED='\033[1;31m'
  C_BOLD='\033[1m'
else
  C_RESET=''
  C_GREEN=''
  C_YELLOW=''
  C_BLUE=''
  C_RED=''
  C_BOLD=''
fi

CNT_PASS=0
CNT_FIXED=0
CNT_WARN=0
CNT_FAIL=0

report_pass() {
  CNT_PASS=$((CNT_PASS + 1))
  printf "  [${C_GREEN}PASS${C_RESET}]  %s\n" "$1"
}

report_fixed() {
  CNT_FIXED=$((CNT_FIXED + 1))
  printf "  [${C_BLUE}FIXED${C_RESET}] %s\n" "$1"
}

report_warn() {
  CNT_WARN=$((CNT_WARN + 1))
  printf "  [${C_YELLOW}WARN${C_RESET}]  %s\n" "$1"
}

report_fail() {
  CNT_FAIL=$((CNT_FAIL + 1))
  printf "  [${C_RED}FAIL${C_RESET}]  %s\n" "$1"
}

get_loki_service_name() {
  if systemctl list-unit-files loki-server.service >/dev/null 2>&1; then
    echo "loki-server"
  else
    echo "loki"
  fi
}

LOKI_SERVICE="$(get_loki_service_name)"
NEED_DAEMON_RELOAD=0
NEED_LOKI_RESTART=0
NEED_ALLOY_RESTART=0
NEED_PROM_RESTART=0
NEED_GRAFANA_RESTART=0

echo -e "${C_BOLD}================================================================================${C_RESET}"
echo -e "${C_BOLD}       DOCTOR DE OBSERVABILIDAD Y SEGURIDAD ACTIVA (DIAGNÓSTICO Y REPARACIÓN)   ${C_RESET}"
echo -e "${C_BOLD}================================================================================${C_RESET}"
if [[ "$CHECK_ONLY" -eq 1 ]]; then
  echo "Modo: SOLO LECTURA (--check-only)"
else
  echo "Modo: AUTORREPARACIÓN ACTIVA (--fix)"
fi
echo

# ------------------------------------------------------------------------------
# 1. USUARIOS, GRUPOS Y DROP-INS DE SYSTEMD
# ------------------------------------------------------------------------------
echo -e "${C_BOLD}[1/5] Verificando usuarios del sistema, grupos y aislamiento systemd...${C_RESET}"

for sys_user in prometheus loki alloy grafana; do
  if getent passwd "$sys_user" >/dev/null 2>&1; then
    report_pass "Usuario de sistema '$sys_user' existe"
  else
    if [[ "$CHECK_ONLY" -eq 1 ]]; then
      report_fail "Usuario de sistema '$sys_user' no existe"
    else
      groupadd --system "$sys_user" 2>/dev/null || true
      useradd --system -g "$sys_user" -d "/var/lib/$sys_user" -s /usr/sbin/nologin "$sys_user" 2>/dev/null || true
      report_fixed "Creado usuario y grupo de sistema '$sys_user'"
    fi
  fi
done

# Verificar membresía de alloy en adm, systemd-journal (y docker si está instalado)
alloy_groups="$(id -Gn alloy 2>/dev/null || true)"
expected_supp_groups="adm systemd-journal"
need_group_fix=0

if [[ " $alloy_groups " != *" adm "* || " $alloy_groups " != *" systemd-journal "* ]]; then
  need_group_fix=1
fi
if getent group docker >/dev/null 2>&1; then
  expected_supp_groups="adm systemd-journal docker"
  if [[ " $alloy_groups " != *" docker "* ]]; then
    need_group_fix=1
  fi
fi

if [[ "$need_group_fix" -eq 0 ]]; then
  report_pass "Usuario 'alloy' pertenece a los grupos requeridos ($expected_supp_groups)"
else
  if [[ "$CHECK_ONLY" -eq 1 ]]; then
    report_fail "Usuario 'alloy' no pertenece a todos los grupos requeridos ($expected_supp_groups; actual: $alloy_groups)"
  else
    if getent group docker >/dev/null 2>&1; then
      usermod -aG adm,systemd-journal,docker alloy
    else
      usermod -aG adm,systemd-journal alloy
    fi
    NEED_ALLOY_RESTART=1
    report_fixed "Añadido usuario 'alloy' a los grupos ($expected_supp_groups)"
  fi
fi

# Verificar drop-in systemd de Alloy para SupplementaryGroups
ALLOY_DROPIN="/etc/systemd/system/alloy.service.d/observability.conf"
if [[ -f "$ALLOY_DROPIN" ]] && grep -q "SupplementaryGroups=${expected_supp_groups}" "$ALLOY_DROPIN" 2>/dev/null; then
  report_pass "Drop-in systemd de Alloy ($ALLOY_DROPIN) configurado ($expected_supp_groups)"
else
  if [[ "$CHECK_ONLY" -eq 1 ]]; then
    report_fail "Falta o está desactualizado el drop-in systemd $ALLOY_DROPIN (requiere SupplementaryGroups=$expected_supp_groups)"
  else
    install -d -m 0755 /etc/systemd/system/alloy.service.d
    cat > "$ALLOY_DROPIN" <<EOF
[Service]
SupplementaryGroups=$expected_supp_groups
EOF
    NEED_DAEMON_RELOAD=1
    NEED_ALLOY_RESTART=1
    report_fixed "Actualizado $ALLOY_DROPIN (SupplementaryGroups=$expected_supp_groups)"
  fi
fi

# ------------------------------------------------------------------------------
# 2. PERMISOS DE DIRECTORIOS, CONFIGURACIONES Y ARCHIVOS DE LOG
# ------------------------------------------------------------------------------
echo
echo -e "${C_BOLD}[2/5] Verificando permisos de almacenamiento (Loki/Prometheus/Grafana) y lectura de logs...${C_RESET}"

# Loki storage permissions (causa raíz #1 de fallo status=1/FAILURE en loki.service)
loki_dirs=(/var/lib/loki /var/lib/loki/chunks /var/lib/loki/rules /var/lib/loki/compactor)
loki_perm_issue=0
for d in "${loki_dirs[@]}"; do
  if [[ ! -d "$d" ]]; then
    loki_perm_issue=1
  fi
done
if [[ -d /var/lib/loki ]]; then
  bad_loki_files="$(find /var/lib/loki \( ! -user loki -o ! -group loki \) -print -quit 2>/dev/null || true)"
  if [[ -n "$bad_loki_files" ]]; then
    loki_perm_issue=1
  fi
fi

# Sincronizar /etc/loki/config.yml con el repositorio si falta o si no tiene instance_addr configurado
if [[ -f "$SCRIPT_DIR/loki/config.yml" ]]; then
  if [[ ! -f /etc/loki/config.yml ]] || ! grep -q 'instance_addr' /etc/loki/config.yml 2>/dev/null; then
    if [[ "$CHECK_ONLY" -eq 1 ]]; then
      report_fail "/etc/loki/config.yml no existe o le falta 'instance_addr: 127.0.0.1' (provoca error 500 al recibir logs)"
    else
      install -d -m 0755 /etc/loki
      install -m 0644 "$SCRIPT_DIR/loki/config.yml" /etc/loki/config.yml
      chown loki:loki /etc/loki/config.yml
      NEED_LOKI_RESTART=1
      report_fixed "Actualizado /etc/loki/config.yml con 'instance_addr: 127.0.0.1' para gRPC interno en loopback"
    fi
  fi
fi

if [[ "$loki_perm_issue" -eq 0 ]]; then
  report_pass "Directorios en /var/lib/loki existen y pertenecen íntegramente a loki:loki"
else
  if [[ "$CHECK_ONLY" -eq 1 ]]; then
    report_fail "Directorios faltantes o archivos con propietario incorrecto (root) dentro de /var/lib/loki"
  else
    install -d -o loki -g loki -m 0750 /var/lib/loki /var/lib/loki/chunks /var/lib/loki/rules /var/lib/loki/compactor
    chown -R loki:loki /var/lib/loki
    chmod 0750 /var/lib/loki
    NEED_LOKI_RESTART=1
    report_fixed "Reparada estructura y propiedad recursiva loki:loki en /var/lib/loki"
  fi
fi

if [[ -f /etc/loki/config.yml ]]; then
  if runuser -u loki -- test -r /etc/loki/config.yml 2>/dev/null; then
    report_pass "Configuración /etc/loki/config.yml legible por usuario 'loki'"
  else
    if [[ "$CHECK_ONLY" -eq 1 ]]; then
      report_fail "El usuario 'loki' NO puede leer /etc/loki/config.yml (su grupo primario suele ser nogroup)"
    else
      chmod 0755 /etc/loki 2>/dev/null || true
      chown loki:loki /etc/loki/config.yml
      chmod 0644 /etc/loki/config.yml
      NEED_LOKI_RESTART=1
      report_fixed "Ajustado propietario de /etc/loki/config.yml a loki:loki (0644) para lectura directa por el proceso"
    fi
  fi
fi

# Alloy config & data directory permissions (sincronizar con repo si falta soporte Docker, CrowdSec o glob de Nginx)
if [[ -f "$SCRIPT_DIR/alloy/config.alloy" ]]; then
  if [[ ! -f /etc/alloy/config.alloy ]] || ! grep -q 'crowdsec_metrics' /etc/alloy/config.alloy 2>/dev/null; then
    if [[ "$CHECK_ONLY" -eq 1 ]]; then
      report_fail "/etc/alloy/config.alloy no existe o no incluye la recolección de CrowdSec / Docker"
    else
      install -d -m 0755 /etc/alloy
      install -m 0644 "$SCRIPT_DIR/alloy/config.alloy" /etc/alloy/config.alloy
      chown alloy:alloy /etc/alloy/config.alloy
      NEED_ALLOY_RESTART=1
      report_fixed "Actualizado /etc/alloy/config.alloy con scrape de CrowdSec (:6060), Docker y Nginx"
    fi
  fi
fi

if [[ -f /etc/alloy/config.alloy ]]; then
  if command -v alloy >/dev/null 2>&1 && [[ "$CHECK_ONLY" -eq 0 ]]; then
    alloy fmt -w /etc/alloy/config.alloy >/dev/null 2>&1 || true
    chown alloy:alloy /etc/alloy/config.alloy 2>/dev/null || true
    chmod 0644 /etc/alloy/config.alloy 2>/dev/null || true
  fi
  if runuser -u alloy -- test -r /etc/alloy/config.alloy 2>/dev/null; then
    report_pass "Configuración /etc/alloy/config.alloy legible por usuario 'alloy'"
  else
    if [[ "$CHECK_ONLY" -eq 1 ]]; then
      report_fail "El usuario 'alloy' no puede leer /etc/alloy/config.alloy"
    else
      chmod 0755 /etc/alloy 2>/dev/null || true
      chown alloy:alloy /etc/alloy/config.alloy
      chmod 0644 /etc/alloy/config.alloy
      NEED_ALLOY_RESTART=1
      report_fixed "Ajustados permisos de /etc/alloy/config.alloy (alloy:alloy 0644)"
    fi
  fi
fi

# Verificar lectura real de /var/log/auth.log por parte de alloy
if [[ ! -f /var/log/auth.log ]]; then
  if [[ "$CHECK_ONLY" -eq 1 ]]; then
    report_warn "/var/log/auth.log aún no existe en el sistema"
  else
    touch /var/log/auth.log
    chown syslog:adm /var/log/auth.log 2>/dev/null || chgrp adm /var/log/auth.log 2>/dev/null || true
    chmod 0640 /var/log/auth.log
    systemctl restart rsyslog 2>/dev/null || true
    NEED_ALLOY_RESTART=1
    report_fixed "Creado /var/log/auth.log (0640 syslog:adm) y recargado rsyslog"
  fi
fi

if [[ -f /var/log/auth.log ]]; then
  if runuser -u alloy -- test -r /var/log/auth.log 2>/dev/null; then
    report_pass "El usuario 'alloy' tiene acceso de lectura verificado sobre /var/log/auth.log"
  else
    if [[ "$CHECK_ONLY" -eq 1 ]]; then
      report_fail "El usuario 'alloy' NO puede leer /var/log/auth.log (permisos actuales: $(stat -c '%a %U:%G' /var/log/auth.log 2>/dev/null))"
    else
      chgrp adm /var/log/auth.log 2>/dev/null || true
      chmod 0640 /var/log/auth.log 2>/dev/null || true
      chmod o+rx /var/log 2>/dev/null || true
      NEED_ALLOY_RESTART=1
      if runuser -u alloy -- test -r /var/log/auth.log 2>/dev/null; then
        report_fixed "Reparados permisos de /var/log/auth.log (grupo adm, modo 0640) para lectura por Alloy"
      else
        report_fail "No se pudo otorgar lectura a 'alloy' sobre /var/log/auth.log"
      fi
    fi
  fi
fi

# Verificar permisos de /var/lib/grafana, dashboard y alertas aprovisionadas
if [[ -f /etc/grafana/provisioning/alerting/observability-alerts.yml ]]; then
  report_pass "Catálogo de 16 reglas de Grafana Alerting aprovisionado (/etc/grafana/provisioning/alerting/observability-alerts.yml)"
else
  if [[ "$CHECK_ONLY" -eq 1 ]]; then
    report_fail "Falta el archivo de alertas /etc/grafana/provisioning/alerting/observability-alerts.yml"
  elif [[ -f "$SCRIPT_DIR/grafana/provisioning/alerting/alerts.yml" ]]; then
    install -d -m 0755 /etc/grafana/provisioning/alerting
    install -m 0640 "$SCRIPT_DIR/grafana/provisioning/alerting/alerts.yml" \
      /etc/grafana/provisioning/alerting/observability-alerts.yml
    chown root:grafana /etc/grafana/provisioning/alerting/observability-alerts.yml
    NEED_GRAFANA_RESTART=1
    report_fixed "Aprovisionadas las 16 alertas en /etc/grafana/provisioning/alerting/observability-alerts.yml"
  fi
fi

# Sincronizar el dashboard JSON (incluyendo panel de contenedores Docker)
if [[ -f "$SCRIPT_DIR/grafana/dashboards/ubuntu-security-overview.json" ]]; then
  if [[ -f /var/lib/grafana/dashboards/ubuntu-security-overview.json ]] && \
     grep -q 'docker_containers' /var/lib/grafana/dashboards/ubuntu-security-overview.json 2>/dev/null; then
    report_pass "Dashboard principal de Grafana actualizado (incluye panel de Logs de Aplicaciones Docker)"
  else
    if [[ "$CHECK_ONLY" -eq 1 ]]; then
      report_fail "El dashboard en /var/lib/grafana/dashboards/ubuntu-security-overview.json no existe o no incluye el panel de logs Docker"
    else
      install -d -o grafana -g grafana -m 0755 /var/lib/grafana/dashboards
      install -o grafana -g grafana -m 0644 "$SCRIPT_DIR/grafana/dashboards/ubuntu-security-overview.json" \
        /var/lib/grafana/dashboards/ubuntu-security-overview.json
      NEED_GRAFANA_RESTART=1
      report_fixed "Actualizado /var/lib/grafana/dashboards/ubuntu-security-overview.json con panel de Logs de Aplicaciones Docker"
    fi
  fi
fi

if [[ -d /var/lib/grafana ]]; then
  bad_graf_files="$(find /var/lib/grafana \( ! -user grafana -o ! -group grafana \) -print -quit 2>/dev/null || true)"
  if [[ -z "$bad_graf_files" ]]; then
    report_pass "Directorio /var/lib/grafana pertenece íntegramente a grafana:grafana"
  else
    if [[ "$CHECK_ONLY" -eq 1 ]]; then
      report_fail "Archivos en /var/lib/grafana con propietario distinto de grafana:grafana"
    else
      chown -R grafana:grafana /var/lib/grafana
      NEED_GRAFANA_RESTART=1
      report_fixed "Corregido propietario recursivo grafana:grafana en /var/lib/grafana"
    fi
  fi
fi

# ------------------------------------------------------------------------------
# 3. SALUD DE SERVICIOS SYSTEMD
# ------------------------------------------------------------------------------
echo
echo -e "${C_BOLD}[3/5] Verificando estado y salud de servicios systemd...${C_RESET}"

if [[ "$NEED_DAEMON_RELOAD" -eq 1 && "$CHECK_ONLY" -eq 0 ]]; then
  systemctl daemon-reload
fi

# Reinicios preventivos ordenados si se repararon permisos
if [[ "$CHECK_ONLY" -eq 0 ]]; then
  if [[ "$NEED_PROM_RESTART" -eq 1 ]]; then
    systemctl reset-failed prometheus 2>/dev/null || true
    systemctl restart prometheus || true
  fi
  if [[ "$NEED_LOKI_RESTART" -eq 1 ]]; then
    systemctl reset-failed "$LOKI_SERVICE" 2>/dev/null || true
    systemctl restart "$LOKI_SERVICE" || true
  fi
fi

# Comprobar y levantar Prometheus y Loki primero
for svc in prometheus "$LOKI_SERVICE"; do
  if systemctl is-active --quiet "$svc" 2>/dev/null; then
    report_pass "Servicio '$svc' está activo (running)"
  else
    if [[ "$CHECK_ONLY" -eq 1 ]]; then
      report_fail "Servicio '$svc' NO está activo (estado: $(systemctl is-active "$svc" 2>/dev/null || echo 'inactive'))"
    else
      systemctl reset-failed "$svc" 2>/dev/null || true
      systemctl enable --now "$svc" 2>/dev/null || true
      # Usar timeout de 5 segundos con timeout de GNU coreutils para que systemctl JAMAS congele el script
      timeout 5s systemctl restart "$svc" 2>/dev/null || true
      sleep 1
      if systemctl is-active --quiet "$svc" 2>/dev/null; then
        report_fixed "Servicio '$svc' recuperado y activo"
      else
        report_fail "Servicio '$svc' continúa fallando tras intento de reinicio"
        echo "  [DIAGNÓSTICO] Últimas líneas de journalctl para $svc:"
        journalctl -u "$svc" -n 6 --no-pager 2>/dev/null | sed 's/^/    /' || true
      fi
    fi
  fi
done

# Esperar a que Loki responda en :3100/ready antes de evaluar/reiniciar Alloy
if systemctl is-active --quiet "$LOKI_SERVICE" 2>/dev/null; then
  loki_ready=0
  for _ in {1..8}; do
    if curl -fsSL --connect-timeout 1 --max-time 2 "http://127.0.0.1:3100/ready" >/dev/null 2>&1; then
      loki_ready=1
      break
    fi
    sleep 1
  done
  if [[ "$loki_ready" -eq 1 ]]; then
    report_pass "Endpoint de salud de Loki (127.0.0.1:3100/ready) responde READY"
  else
    report_warn "Loki está activo pero 127.0.0.1:3100/ready aún está inicializando"
  fi
fi

# Ahora comprobar Alloy, Grafana y CrowdSec
if [[ "$NEED_ALLOY_RESTART" -eq 1 && "$CHECK_ONLY" -eq 0 ]]; then
  systemctl reset-failed alloy 2>/dev/null || true
  timeout 5s systemctl restart alloy 2>/dev/null || true
  sleep 1
fi
if [[ "$NEED_GRAFANA_RESTART" -eq 1 && "$CHECK_ONLY" -eq 0 ]]; then
  systemctl reset-failed grafana-server 2>/dev/null || true
  timeout 5s systemctl restart grafana-server 2>/dev/null || true
  sleep 1
fi

for svc in alloy grafana-server crowdsec; do
  if ! systemctl list-unit-files "${svc}.service" >/dev/null 2>&1; then
    report_warn "Servicio opcional '$svc' no está instalado en este sistema"
    continue
  fi
  if systemctl is-active --quiet "$svc" 2>/dev/null; then
    report_pass "Servicio '$svc' está activo (running)"
  else
    if [[ "$CHECK_ONLY" -eq 1 ]]; then
      report_fail "Servicio '$svc' NO está activo"
    else
      systemctl reset-failed "$svc" 2>/dev/null || true
      systemctl enable --now "$svc" 2>/dev/null || true
      timeout 5s systemctl restart "$svc" 2>/dev/null || true
      sleep 1
      if systemctl is-active --quiet "$svc" 2>/dev/null; then
        report_fixed "Servicio '$svc' recuperado y activo"
      else
        report_fail "Servicio '$svc' no pudo iniciar"
        echo "  [DIAGNÓSTICO] Últimas líneas de journalctl para $svc:"
        journalctl -u "$svc" -n 6 --no-pager 2>/dev/null | sed 's/^/    /' || true
      fi
    fi
  fi
done

# Auditd: nunca se reinicia con systemctl restart porque Linux kernel auditd tiene RefuseManualStop=yes
# y causa congelamiento en terminal. Se usa augenrules --load para recargar reglas sin colgar el proceso.
if systemctl list-unit-files auditd.service >/dev/null 2>&1; then
  if systemctl is-active --quiet auditd 2>/dev/null; then
    report_pass "Servicio 'auditd' está activo (running)"
    if [[ "$CHECK_ONLY" -eq 0 ]]; then
      augenrules --load >/dev/null 2>&1 || true
    fi
  else
    if [[ "$CHECK_ONLY" -eq 1 ]]; then
      report_fail "Servicio 'auditd' no está activo"
    else
      service auditd start 2>/dev/null || systemctl start auditd 2>/dev/null || true
      sleep 1
      if systemctl is-active --quiet auditd 2>/dev/null; then
        report_fixed "Servicio 'auditd' iniciado"
      else
        report_warn "Servicio 'auditd' no pudo iniciar en este kernel/container"
      fi
    fi
  fi
fi

# ------------------------------------------------------------------------------
# 4. VERIFICACIÓN DE PUERTOS EN LOOPBACK
# ------------------------------------------------------------------------------
echo
echo -e "${C_BOLD}[4/5] Verificando aislamiento de sockets en loopback (127.0.0.1)...${C_RESET}"

# Verificar que el drop-in de Grafana tenga GF_SERVER_HTTP_ADDR=127.0.0.1
GRAF_DROPIN="/etc/systemd/system/grafana-server.service.d/observability.conf"
if [[ -f "$GRAF_DROPIN" ]] && ! grep -q "GF_SERVER_HTTP_ADDR=127.0.0.1" "$GRAF_DROPIN" 2>/dev/null; then
  if [[ "$CHECK_ONLY" -eq 0 ]]; then
    cat > "$GRAF_DROPIN" <<EOF
[Service]
Environment="GF_SERVER_HTTP_ADDR=127.0.0.1"
Environment="GF_SERVER_HTTP_PORT=$GRAFANA_PORT"
Environment="GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH=/var/lib/grafana/dashboards/ubuntu-security-overview.json"
EOF
    systemctl daemon-reload
    systemctl restart grafana-server || true
    sleep 2
    report_fixed "Restaurado aislamiento GF_SERVER_HTTP_ADDR=127.0.0.1 en $GRAF_DROPIN"
  fi
fi

# Esperar hasta 5s si algún socket está terminando de enlazar tras el reinicio
for _ in {1..5}; do
  ss_out="$(ss -lntp 2>/dev/null || true)"
  if echo "$ss_out" | grep -qE ":3100\b" && echo "$ss_out" | grep -qE ":12345\b"; then
    break
  fi
  sleep 1
done

for port_pair in "9090:Prometheus" "3100:Loki" "12345:Alloy" "${GRAFANA_PORT}:Grafana"; do
  p="${port_pair%%:*}"
  name="${port_pair#*:}"
  if echo "$ss_out" | grep -qE "(127\.0\.0\.1|\[::1\]):${p}\b"; then
    report_pass "$name escuchando de forma segura en loopback (:${p})"
  elif echo "$ss_out" | grep -qE ":${p}\b"; then
    report_warn "$name escucha en el puerto :${p} pero verifica que no esté expuesto en 0.0.0.0"
  else
    report_fail "No se detectó socket activo en el puerto :${p} ($name)"
  fi
done

# ------------------------------------------------------------------------------
# 5. VERIFICACIÓN DE INGESTA EN VIVO (PROMETHEUS Y LOKI /var/log/auth.log)
# ------------------------------------------------------------------------------
echo
echo -e "${C_BOLD}[5/5] Verificando ingesta real de métricas (Prometheus) y logs (Loki)...${C_RESET}"

# 5.1 Prometheus metrics check
prom_up="$(curl -fsSL --connect-timeout 2 --max-time 4 "http://127.0.0.1:9090/api/v1/query?query=node_memory_MemTotal_bytes" 2>/dev/null || true)"
if echo "$prom_up" | grep -q '"result":\[{'; then
  report_pass "Prometheus recibe métricas de host desde Alloy (node_memory_MemTotal_bytes presente)"
else
  report_warn "Prometheus aún no muestra series de node_memory_MemTotal_bytes (espera 15s tras arranque de Alloy)"
fi

# 5.2 Loki ssh_auth (/var/log/auth.log) ingestion check & auto-repair
check_loki_ssh_auth() {
  local now_ns start_ns resp
  now_ns="$(date +%s)000000000"
  # Ventana de búsqueda de 24 horas hacia atrás
  start_ns="$(( $(date +%s) - 86400 ))000000000"
  resp="$(curl -fsSL --connect-timeout 2 --max-time 4 -G "http://127.0.0.1:3100/loki/api/v1/query_range" \
    --data-urlencode 'query={job="ssh_auth"}' \
    --data-urlencode "start=${start_ns}" \
    --data-urlencode "end=${now_ns}" \
    --data-urlencode "limit=5" 2>/dev/null || true)"
  if echo "$resp" | grep -q '"result":\[{'; then
    return 0
  fi
  return 1
}

if check_loki_ssh_auth; then
  report_pass "Loki tiene flujos activos para {job=\"ssh_auth\"} (/var/log/auth.log visible en Grafana)"
else
  if [[ "$CHECK_ONLY" -eq 1 ]]; then
    report_fail "Loki devuelve 0 resultados para {job=\"ssh_auth\"} (el panel de /var/log/auth.log mostrará 'No data')"
  else
    echo "  [INFO] No se encontraron eventos {job=\"ssh_auth\"} en Loki. Iniciando autorreparación de ingesta..."
    # Si Alloy leyó /var/log/auth.log cuando Loki estaba caído, guardó el offset final en positions.yml
    # y no volverá a enviar las líneas previas. Limpiamos positions.yml de log_scraper y emitimos un evento auth.
    systemctl stop alloy 2>/dev/null || true
    find /var/lib/alloy -name "positions.yml" -exec rm -f {} + 2>/dev/null || true

    # Emitir una línea de verificación en auth.log (vía logger auth.info y fallback directo si rsyslog no escribe)
    logger -p auth.info -t sshd "observability-doctor: verificacion de ingesta activa de /var/log/auth.log" 2>/dev/null || true
    if [[ ! -s /var/log/auth.log ]]; then
      printf "%s %s sshd[1]: observability-doctor: verificacion de ingesta activa de /var/log/auth.log\n" \
        "$(date '+%Y-%m-%dT%H:%M:%S%:z')" "$(hostname)" >> /var/log/auth.log
    fi
    chgrp adm /var/log/auth.log 2>/dev/null || true
    chmod 0640 /var/log/auth.log 2>/dev/null || true

    systemctl start alloy 2>/dev/null || true

    # Esperar hasta 12 segundos a que Alloy envíe el batch a Loki
    ingested=0
    for _ in {1..12}; do
      sleep 1
      if check_loki_ssh_auth; then
        ingested=1
        break
      fi
    done

    if [[ "$ingested" -eq 1 ]]; then
      report_fixed "Reseteado cache de posiciones de Alloy y verificada ingesta de {job=\"ssh_auth\"} en Loki"
    else
      report_warn "Se reinició el lector de Alloy para /var/log/auth.log; espera unos segundos y refresca Grafana"
    fi
  fi
fi

# 5.3 Loki systemd_journal check
now_ns="$(date +%s)000000000"
start_ns="$(( $(date +%s) - 3600 ))000000000"
journal_resp="$(curl -fsSL --connect-timeout 2 --max-time 4 -G "http://127.0.0.1:3100/loki/api/v1/query_range" \
  --data-urlencode 'query={job="systemd_journal"}' \
  --data-urlencode "start=${start_ns}" \
  --data-urlencode "end=${now_ns}" \
  --data-urlencode "limit=1" 2>/dev/null || true)"
if echo "$journal_resp" | grep -q '"result":\[{'; then
  report_pass "Loki recibe logs de systemd-journal ({job=\"systemd_journal\"} activo)"
else
  report_warn "Loki aún no reporta eventos recientes de {job=\"systemd_journal\"}"
fi

# 5.4 Docker container logs check (si /var/run/docker.sock existe)
if [[ -S /var/run/docker.sock ]]; then
  if runuser -u alloy -- test -r /var/run/docker.sock 2>/dev/null; then
    report_pass "El usuario 'alloy' tiene permiso de lectura sobre el socket Docker (/var/run/docker.sock)"
  else
    report_warn "El socket /var/run/docker.sock existe pero el proceso 'alloy' requiere reinicio o permisos de grupo 'docker'"
  fi
fi

# ------------------------------------------------------------------------------
# RESUMEN FINAL
# ------------------------------------------------------------------------------
echo
echo -e "${C_BOLD}================================================================================${C_RESET}"
printf " RESUMEN:  ${C_GREEN}%d PASS${C_RESET}  |  ${C_BLUE}%d FIXED${C_RESET}  |  ${C_YELLOW}%d WARN${C_RESET}  |  ${C_RED}%d FAIL${C_RESET}\n" \
  "$CNT_PASS" "$CNT_FIXED" "$CNT_WARN" "$CNT_FAIL"
echo -e "${C_BOLD}================================================================================${C_RESET}"

if [[ "$CNT_FAIL" -gt 0 ]]; then
  if [[ "$CHECK_ONLY" -eq 1 ]]; then
    echo "Ejecuta 'sudo ./doctor.sh' (sin --check-only) para reparar automáticamente los fallos detectados."
  else
    echo "Algunos componentes requieren revisión manual. Revisa la salida anterior."
  fi
  exit 1
fi

echo "Estado saludable. Abre Grafana en http://localhost:${GRAFANA_PORT} (vía túnel SSH) y refresca el dashboard."
exit 0
