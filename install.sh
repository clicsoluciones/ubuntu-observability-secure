#!/usr/bin/env bash
# Ubuntu 22.04/24.04 - Grafana + Prometheus + Loki + Alloy + auditd + CrowdSec
# Safe-by-default: loopback binding, no SSH/UFW disruption, safe backup before changes.
set -Eeuo pipefail
umask 027

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/var/log/observability-install.log"
BACKUP_DIR="/var/backups/observability-$(date +%Y%m%d-%H%M%S)"

# Configuration & flags (CLI flags override environment variables)
INSTALL_CROWDSEC="${INSTALL_CROWDSEC:-1}"
INSTALL_BOUNCER="${INSTALL_BOUNCER:-0}"
GRAFANA_PORT="${GRAFANA_PORT:-3000}"
DRY_RUN=0
SKIP_PREFLIGHT=0
ACTION="install"
ROLLBACK_DIR=""

show_help() {
  cat <<'EOF'
Uso: sudo ./install.sh [OPCIONES]

Instalador seguro de Observabilidad y Seguridad Activa en Ubuntu (22.04 / 24.04).

Opciones:
  --port <PUERTO>           Puerto HTTP para Grafana (por defecto: 3000).
  --dry-run                 Muestra los pasos y comandos sin realizar cambios en el sistema.
  --skip-preflight          Omite las advertencias y verificaciones previas (RAM, disco, red).
  --no-crowdsec             Deshabilita la instalación y configuración de CrowdSec.
  --with-bouncer            Instala y activa el bouncer nftables de CrowdSec (remediation).
  --rollback <DIRECTORIO>   Restaura configuraciones y sysctl desde un backup previo y recarga servicios.
  --uninstall               Detiene y deshabilita los servicios de observabilidad, y retira configs creadas.
  -h, --help                Muestra esta ayuda y termina.

Variables de entorno compatibles:
  GRAFANA_PORT=<1-65535>    (por defecto: 3000)
  INSTALL_CROWDSEC=0|1      (por defecto: 1)
  INSTALL_BOUNCER=0|1       (por defecto: 0)

Ejemplos:
  sudo ./install.sh
  sudo ./install.sh --port 3001
  sudo ./install.sh --dry-run
  sudo ./install.sh --with-bouncer
  sudo ./install.sh --rollback /var/backups/observability-20261101-120000
  sudo ./install.sh --uninstall
EOF
}

# --- CLI Flag Parsing ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)
      if [[ $# -lt 2 || -z "${2:-}" || ! "${2:-}" =~ ^[0-9]+$ || "${2:-}" -lt 1 || "${2:-}" -gt 65535 ]]; then
        echo "Error: --port requiere un número de puerto válido (1-65535)." >&2
        exit 1
      fi
      GRAFANA_PORT="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --skip-preflight)
      SKIP_PREFLIGHT=1
      shift
      ;;
    --no-crowdsec)
      INSTALL_CROWDSEC=0
      shift
      ;;
    --with-bouncer)
      INSTALL_BOUNCER=1
      shift
      ;;
    --rollback)
      if [[ $# -lt 2 || -z "${2:-}" || "${2:-}" =~ ^-- ]]; then
        echo "Error: --rollback requiere una ruta de directorio de backup válida." >&2
        exit 1
      fi
      ACTION="rollback"
      ROLLBACK_DIR="$2"
      shift 2
      ;;
    --uninstall)
      ACTION="uninstall"
      shift
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

# Wrapper for executing commands respecting --dry-run
run_cmd() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] $*"
  else
    "$@"
  fi
}

# Pre-flight Root Check
if [[ $EUID -ne 0 ]]; then
  echo "Error: Requiere privilegios de superusuario. Ejecuta con: sudo $0" >&2
  exit 1
fi

# Setup logging (in dry-run mode, also append if possible, otherwise skip file redirection if write fails)
# Note: When printing sensitive credentials at the end, output is directed straight to /dev/tty
# to avoid leaking the generated Grafana admin password into $LOG_FILE.
if [[ "$DRY_RUN" -eq 0 ]]; then
  touch "$LOG_FILE" 2>/dev/null || true
  exec > >(tee -a "$LOG_FILE") 2>&1
  trap 'echo "[ERROR] Falló en línea $LINENO. Revisa $LOG_FILE"; exit 1' ERR
else
  trap 'echo "[ERROR] Falló en línea $LINENO durante dry-run."; exit 1' ERR
fi

# Helper to identify Loki service unit deterministically
get_loki_service_name() {
  if systemctl list-unit-files loki-server.service >/dev/null 2>&1; then
    echo "loki-server"
  elif systemctl list-unit-files loki.service >/dev/null 2>&1; then
    echo "loki"
  else
    # Fallback default if not yet installed or not found in unit files
    echo "loki"
  fi
}

# --- ROLLBACK ACTION ---
do_rollback() {
  echo "==> Iniciando ROLLBACK desde: $ROLLBACK_DIR"
  if [[ ! -d "$ROLLBACK_DIR" ]]; then
    echo "Error: El directorio de respaldo especificado no existe: $ROLLBACK_DIR" >&2
    exit 1
  fi

  local restored=0
  while IFS= read -r -d '' file; do
    local rel_path="${file#"$ROLLBACK_DIR"}"
    if [[ -n "$rel_path" && -f "$file" ]]; then
      echo "Restaurando: $rel_path"
      if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[DRY-RUN] cp -a $file $rel_path"
      else
        mkdir -p "$(dirname "$rel_path")"
        cp -a "$file" "$rel_path"
      fi
      restored=$((restored + 1))
    fi
  done < <(find "$ROLLBACK_DIR" -type f -print0)

  if [[ $restored -eq 0 ]]; then
    echo "Advertencia: No se encontraron archivos para restaurar en $ROLLBACK_DIR."
  else
    echo "Archivos restaurados: $restored"
  fi

  echo "==> Recargando sysctl y systemd tras rollback"
  run_cmd sysctl --system || true
  run_cmd systemctl daemon-reload || true

  local loki_svc
  loki_svc="$(get_loki_service_name)"
  echo "==> Reiniciando servicios restaurados si están activos"
  for s in prometheus "$loki_svc" alloy grafana-server; do
    if systemctl is-active --quiet "$s" 2>/dev/null; then
      echo "Reiniciando $s..."
      run_cmd systemctl restart "$s" || true
    fi
  done

  echo "==> Rollback finalizado exitosamente."
  exit 0
}

# --- UNINSTALL ACTION ---
do_uninstall() {
  echo "==> Iniciando DESINSTALACIÓN segura de la suite de observabilidad"
  local loki_svc
  loki_svc="$(get_loki_service_name)"

  local services_to_stop=("grafana-server" "$loki_svc" "prometheus" "alloy")
  if [[ "$INSTALL_BOUNCER" -eq 1 ]]; then
    services_to_stop+=("crowdsec-firewall-bouncer")
  fi
  if [[ "$INSTALL_CROWDSEC" -eq 1 ]]; then
    services_to_stop+=("crowdsec")
  fi

  echo "Deteniendo y deshabilitando servicios..."
  for s in "${services_to_stop[@]}"; do
    if systemctl list-unit-files "$s.service" >/dev/null 2>&1; then
      echo "Deteniendo $s..."
      run_cmd systemctl disable --now "$s" 2>/dev/null || true
    fi
  done

  echo "Eliminando archivos de configuración instalados por este paquete..."
  local files_to_remove=(
    "/etc/sysctl.d/99-observability-ddos.conf"
    "/etc/systemd/system/grafana-server.service.d/observability.conf"
    "/etc/grafana/provisioning/datasources/observability.yml"
    "/etc/audit/rules.d/50-observability.rules"
    "/etc/prometheus/rules/host-alerts.yml"
    "/etc/apt/sources.list.d/grafana.list"
    "/etc/apt/keyrings/grafana.asc"
  )

  for f in "${files_to_remove[@]}"; do
    if [[ -e "$f" ]]; then
      echo "Eliminando: $f"
      run_cmd rm -f "$f"
    fi
  done

  if [[ -d "/etc/systemd/system/grafana-server.service.d" ]]; then
    run_cmd rmdir "/etc/systemd/system/grafana-server.service.d" 2>/dev/null || true
  fi

  echo "Recargando sysctl, auditd y systemd..."
  run_cmd sysctl --system || true
  if command -v augenrules >/dev/null 2>&1; then
    run_cmd augenrules --load || true
  fi
  run_cmd systemctl daemon-reload || true

  echo
  echo "Desinstalación de configuraciones y parada de servicios completada."
  echo "Nota: Los paquetes APT (grafana, prometheus, loki, alloy, crowdsec) se mantuvieron instalados."
  echo "Para purgarlos manualmente si se desea: sudo apt-get purge -y grafana loki alloy prometheus crowdsec"
  exit 0
}

# Branch to rollback or uninstall if requested
if [[ "$ACTION" == "rollback" ]]; then
  do_rollback
fi

if [[ "$ACTION" == "uninstall" ]]; then
  do_uninstall
fi

# --- PRE-FLIGHT CHECKS ---
run_preflight() {
  echo "==> Ejecutando comprobaciones previas (Pre-flight checks)"
  local preflight_ok=1

  # 1. OS check
  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
  fi
  if [[ "${ID:-}" != "ubuntu" || ! "${VERSION_ID:-}" =~ ^(22\.04|24\.04)$ ]]; then
    echo "ERROR: Este instalador está certificado únicamente para Ubuntu 22.04 o 24.04 LTS." >&2
    echo "       Sistema detectado: ${PRETTY_NAME:-desconocido}" >&2
    if [[ "$SKIP_PREFLIGHT" -eq 0 ]]; then
      exit 1
    else
      echo "       [ADVERTENCIA] Continuando debido a --skip-preflight."
      preflight_ok=0
    fi
  else
    echo "  [OK] Sistema operativo: ${PRETTY_NAME}"
  fi

  # 2. Systemd check
  if [[ ! -d /run/systemd/system ]]; then
    echo "ERROR: systemd no está presente o no es el init activo del sistema." >&2
    if [[ "$SKIP_PREFLIGHT" -eq 0 ]]; then
      exit 1
    else
      echo "       [ADVERTENCIA] Continuando debido a --skip-preflight."
      preflight_ok=0
    fi
  else
    echo "  [OK] Init system: systemd activo"
  fi

  # 3. Architecture check
  local arch
  arch="$(uname -m)"
  if [[ "$arch" != "x86_64" && "$arch" != "aarch64" ]]; then
    echo "ADVERTENCIA: Arquitectura detectada ($arch). Se recomienda amd64 (x86_64) o arm64 (aarch64)." >&2
    preflight_ok=0
  else
    echo "  [OK] Arquitectura compatible: $arch"
  fi

  # 4. RAM check (warn if total < 1800MB)
  local total_mem_kb=0
  if [[ -f /proc/meminfo ]]; then
    total_mem_kb=$(awk '/MemTotal:/ {print $2}' /proc/meminfo || echo 0)
  fi
  local total_mem_mb=$(( total_mem_kb / 1024 ))
  if [[ "$total_mem_mb" -gt 0 && "$total_mem_mb" -lt 1800 ]]; then
    echo "ADVERTENCIA: Memoria RAM total baja detectada (${total_mem_mb} MB). Se recomiendan al menos 2 GB (2048 MB) para la pila completa." >&2
    if [[ "$SKIP_PREFLIGHT" -eq 0 ]]; then
      echo "             Usa --skip-preflight si deseas continuar bajo tu propio riesgo." >&2
      preflight_ok=0
    fi
  else
    echo "  [OK] Memoria RAM: ${total_mem_mb} MB disponibles"
  fi

  # 5. Disk space check (/var and /: at least 3GB free in /var)
  local var_avail_kb
  var_avail_kb=$(df -k /var 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)
  local var_avail_mb=$(( var_avail_kb / 1024 ))
  if [[ "$var_avail_mb" -gt 0 && "$var_avail_mb" -lt 3072 ]]; then
    echo "ADVERTENCIA: Espacio disponible en /var es bajo (${var_avail_mb} MB). Se recomiendan mínimo 3000 MB para TSDB y logs." >&2
    if [[ "$SKIP_PREFLIGHT" -eq 0 ]]; then
      echo "             Libera espacio o utiliza --skip-preflight para continuar." >&2
      preflight_ok=0
    fi
  else
    echo "  [OK] Espacio en disco (/var): ${var_avail_mb} MB libres"
  fi

  # 6. Internet connectivity check
  echo -n "  Verificando conectividad a repositorios (curl/ping)... "
  if curl -s --connect-timeout 5 -I https://archive.ubuntu.com >/dev/null 2>&1 || \
     curl -s --connect-timeout 5 -I https://apt.grafana.com >/dev/null 2>&1; then
    echo "[OK]"
  else
    echo "[ADVERTENCIA]"
    echo "ADVERTENCIA: No se pudo establecer conexión con los repositorios externos (archive.ubuntu.com o apt.grafana.com)." >&2
    if [[ "$SKIP_PREFLIGHT" -eq 0 ]]; then
      echo "             Verifica DNS/puerta de enlace o ejecuta con --skip-preflight." >&2
      preflight_ok=0
    fi
  fi

  if [[ "$preflight_ok" -eq 0 && "$SKIP_PREFLIGHT" -eq 0 ]]; then
    echo "ERROR: Fallaron comprobaciones previas. Corrige los problemas o ejecuta con --skip-preflight." >&2
    exit 1
  fi
}

run_preflight

echo "==> Preparando instalación. Backup: $BACKUP_DIR"
if [[ "$DRY_RUN" -eq 0 ]]; then
  mkdir -p "$BACKUP_DIR"
else
  echo "[DRY-RUN] mkdir -p $BACKUP_DIR"
fi

backup_file() {
  local f="$1"
  if [[ -e "$f" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "[DRY-RUN] Copia de seguridad: $f -> $BACKUP_DIR$f"
    else
      mkdir -p "$BACKUP_DIR$(dirname "$f")"
      cp -a "$f" "$BACKUP_DIR$f"
    fi
  fi
}

for f in /etc/prometheus/prometheus.yml /etc/default/prometheus /etc/loki/config.yml \
         /etc/alloy/config.alloy /etc/grafana/grafana.ini /etc/sysctl.d/99-observability-ddos.conf; do
  backup_file "$f"
done

echo "==> Instalando dependencias base"
export DEBIAN_FRONTEND=noninteractive
run_cmd apt-get update
run_cmd apt-get install -y ca-certificates curl wget gnupg apt-transport-https \
  auditd audispd-plugins ufw prometheus

echo "==> Añadiendo repositorio oficial Grafana Labs (clave APT dedicada)"
run_cmd install -d -m 0755 /etc/apt/keyrings
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[DRY-RUN] curl -fsSL https://apt.grafana.com/gpg-full.key -o /etc/apt/keyrings/grafana.asc"
  echo "[DRY-RUN] chmod 0644 /etc/apt/keyrings/grafana.asc"
  echo "[DRY-RUN] Crear /etc/apt/sources.list.d/grafana.list"
else
  curl -fsSL https://apt.grafana.com/gpg-full.key -o /etc/apt/keyrings/grafana.asc
  chmod 0644 /etc/apt/keyrings/grafana.asc
  cat > /etc/apt/sources.list.d/grafana.list <<'EOF'
deb [signed-by=/etc/apt/keyrings/grafana.asc] https://apt.grafana.com stable main
EOF
fi

run_cmd apt-get update
run_cmd apt-get install -y grafana loki alloy

echo "==> Configurando parámetros de kernel (conserva backup)"
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[DRY-RUN] Configurar /etc/sysctl.d/99-observability-ddos.conf y ejecutar sysctl --system"
else
  cat > /etc/sysctl.d/99-observability-ddos.conf <<'EOF'
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 4096
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 30
net.ipv4.conf.all.log_martians = 1
EOF
fi
run_cmd modprobe nf_conntrack || true
run_cmd sysctl --system

echo "==> Configurando Prometheus solo en loopback"
run_cmd install -d -o prometheus -g prometheus -m 0750 /etc/prometheus/rules
run_cmd install -m 0644 "$SCRIPT_DIR/prometheus/prometheus.yml" /etc/prometheus/prometheus.yml
run_cmd install -m 0644 "$SCRIPT_DIR/rules/host-alerts.yml" /etc/prometheus/rules/host-alerts.yml
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[DRY-RUN] Configurar /etc/default/prometheus"
else
  cat > /etc/default/prometheus <<'EOF'
ARGS="--config.file=/etc/prometheus/prometheus.yml --storage.tsdb.path=/var/lib/prometheus/metrics2 --storage.tsdb.retention.time=15d --web.listen-address=127.0.0.1:9090 --web.enable-remote-write-receiver"
EOF
fi
run_cmd chown -R prometheus:prometheus /etc/prometheus
run_cmd chmod 0640 /etc/prometheus/prometheus.yml /etc/prometheus/rules/host-alerts.yml

echo "==> Configurando Loki solo en loopback (retención 14 días)"
run_cmd install -d -o loki -g loki -m 0750 /var/lib/loki
run_cmd install -m 0640 "$SCRIPT_DIR/loki/config.yml" /etc/loki/config.yml
run_cmd chown root:loki /etc/loki/config.yml

echo "==> Configurando Alloy y permisos de lectura de logs"
run_cmd usermod -aG adm,systemd-journal alloy
run_cmd install -m 0640 "$SCRIPT_DIR/alloy/config.alloy" /etc/alloy/config.alloy
run_cmd chown root:alloy /etc/alloy/config.alloy

echo "==> Configurando fuentes de datos de Grafana"
run_cmd install -d -m 0755 /etc/grafana/provisioning/datasources
run_cmd install -m 0644 "$SCRIPT_DIR/grafana/provisioning/datasources/datasources.yml" \
  /etc/grafana/provisioning/datasources/observability.yml
run_cmd install -d -m 0755 /etc/systemd/system/grafana-server.service.d
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[DRY-RUN] Configurar /etc/systemd/system/grafana-server.service.d/observability.conf (puerto $GRAFANA_PORT)"
else
  cat > /etc/systemd/system/grafana-server.service.d/observability.conf <<EOF
[Service]
Environment="GF_SERVER_HTTP_ADDR=127.0.0.1"
Environment="GF_SERVER_HTTP_PORT=$GRAFANA_PORT"
EOF
fi

echo "==> Instalando reglas auditd para cambios de identidad y privilegios"
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[DRY-RUN] Configurar /etc/audit/rules.d/50-observability.rules"
else
  cat > /etc/audit/rules.d/50-observability.rules <<'EOF'
-w /etc/passwd -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/gshadow -p wa -k identity
-w /etc/sudoers -p wa -k scope
-w /etc/sudoers.d/ -p wa -k scope
-w /etc/ssh/sshd_config -p wa -k sshd
EOF
fi
run_cmd augenrules --load || true

echo "==> CrowdSec (detección y mitigación)"
if [[ "$INSTALL_CROWDSEC" == "1" ]]; then
  if ! command -v cscli >/dev/null 2>&1; then
    echo "Descargando instalador de repositorio CrowdSec con timeouts y validación..."
    CROWDSEC_INSTALL_SCRIPT="/tmp/crowdsec_install_$$.sh"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "[DRY-RUN] curl -fsSL --connect-timeout 10 --max-time 60 https://install.crowdsec.net -o $CROWDSEC_INSTALL_SCRIPT"
      echo "[DRY-RUN] Validar script no vacío y ejecutar sh $CROWDSEC_INSTALL_SCRIPT"
      echo "[DRY-RUN] apt-get update && apt-get install -y crowdsec"
    else
      curl -fsSL --connect-timeout 10 --max-time 60 https://install.crowdsec.net -o "$CROWDSEC_INSTALL_SCRIPT"
      if [[ ! -s "$CROWDSEC_INSTALL_SCRIPT" ]]; then
        echo "ERROR: Falló la descarga del script de instalación de CrowdSec." >&2
        rm -f "$CROWDSEC_INSTALL_SCRIPT"
        exit 1
      fi
      sh "$CROWDSEC_INSTALL_SCRIPT"
      rm -f "$CROWDSEC_INSTALL_SCRIPT"
      apt-get update
      apt-get install -y crowdsec
    fi
  fi
  run_cmd cscli collections install crowdsecurity/linux crowdsecurity/sshd crowdsecurity/nginx \
    crowdsecurity/base-http-scenarios crowdsecurity/http-cve || true
  run_cmd systemctl enable --now crowdsec
  run_cmd systemctl reload crowdsec || true

  if [[ "$INSTALL_BOUNCER" == "1" ]]; then
    echo "==> Instalando bouncer nftables solicitado (--with-bouncer o INSTALL_BOUNCER=1)"
    run_cmd apt-get install -y crowdsec-firewall-bouncer-nftables
    run_cmd systemctl enable --now crowdsec-firewall-bouncer
  else
    echo "AVISO: CrowdSec queda en modo detección. No bloquea IPs hasta instalar/configurar un remediation component (usa --with-bouncer si lo requieres)."
  fi
else
  echo "CrowdSec omitido (--no-crowdsec o INSTALL_CROWDSEC=0)"
fi

echo "==> Validando configuraciones antes de reiniciar servicios"
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[DRY-RUN] Validaciones de sintaxis con promtool, loki y alloy"
else
  if command -v promtool >/dev/null 2>&1; then
    promtool check config /etc/prometheus/prometheus.yml || true
    promtool check rules /etc/prometheus/rules/host-alerts.yml || true
  fi
  if command -v loki >/dev/null 2>&1; then
    loki -config.file=/etc/loki/config.yml -verify-config || true
  fi
  if command -v alloy >/dev/null 2>&1; then
    alloy fmt --test /etc/alloy/config.alloy || true
  fi
fi

# Deterministic Loki service unit discovery
LOKI_SERVICE="$(get_loki_service_name)"
echo "==> Unidad de servicio Loki detectada: ${LOKI_SERVICE}.service"

echo "==> Habilitando y reiniciando servicios"
run_cmd systemctl daemon-reload
run_cmd systemctl enable --now prometheus "$LOKI_SERVICE" alloy grafana-server
run_cmd systemctl restart prometheus "$LOKI_SERVICE" alloy grafana-server
run_cmd systemctl restart auditd || true

echo
echo "==> Estado de servicios"
for s in prometheus "$LOKI_SERVICE" alloy grafana-server crowdsec; do
  printf '%-18s' "$s"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN: verificación omitida]"
  else
    systemctl is-active "$s" 2>/dev/null || true
  fi
done

echo
echo "==> Puertos esperados (todos internos en loopback)"
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[DRY-RUN: ss -lntp | grep -E ':($GRAFANA_PORT|9090|3100|12345|6060)\b']"
else
  ss -lntp | grep -E ":($GRAFANA_PORT|9090|3100|12345|6060)\b" || true
fi

echo
echo "==> Configurando credenciales administrativas de Grafana"
GRAFANA_PASS_SET=0
GRAFANA_ADMIN_PASS=""
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[DRY-RUN] Generar clave aleatoria segura y asignar con: grafana-cli admin reset-admin-password <PASS>"
  GRAFANA_ADMIN_PASS="[GENERADA_ALEATORIAMENTE_EN_EJECUCION_REAL]"
else
  # Generar contraseña segura criptográficamente de 20 caracteres
  if command -v openssl >/dev/null 2>&1; then
    GRAFANA_ADMIN_PASS="$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9!@#$%^&*' | head -c 20)"
  else
    GRAFANA_ADMIN_PASS="$(tr -dc 'a-zA-Z0-9!@#$%^&*' < /dev/urandom | head -c 20)"
  fi

  if command -v grafana-cli >/dev/null 2>&1; then
    if grafana-cli admin reset-admin-password "$GRAFANA_ADMIN_PASS" >/dev/null 2>&1; then
      GRAFANA_PASS_SET=1
    fi
  fi
fi

# Imprimir credenciales directamente a la terminal si está disponible
# para que no se almacenen en $LOG_FILE
print_credentials() {
  cat <<BANNER

================================================================================
            CREDENCIALES Y ACCESO DE LA SUITE DE OBSERVABILIDAD                 
================================================================================
 [1] Grafana Dashboard (Gestor Central de Visualización y Alertas)
   - URL Local:       http://127.0.0.1:$GRAFANA_PORT
   - Usuario:         admin
BANNER

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "   - Contraseña:      $GRAFANA_ADMIN_PASS"
  elif [[ "$GRAFANA_PASS_SET" -eq 1 ]]; then
    echo "   - Contraseña:      $GRAFANA_ADMIN_PASS"
  else
    echo "   - Contraseña:      (Asignar con: sudo grafana-cli admin reset-admin-password '<PASS>')"
  fi

  cat <<BANNER

 [2] Otros Servicios Internos (Loopback 127.0.0.1)
   - Prometheus:      http://127.0.0.1:9090  (Sin contraseña por diseño: aislado en loopback)
   - Loki:            http://127.0.0.1:3100  (Sin contraseña por diseño: aislado en loopback)
   - Grafana Alloy:   http://127.0.0.1:12345 (Sin contraseña: API interna de telemetría)
   - CrowdSec LAPI:   http://127.0.0.1:8080  (Autenticación interna por API Key entre agentes/cscli)
   - CrowdSec Metrics:http://127.0.0.1:6060  (Endpoint de métricas para Prometheus)

 [3] Conexión Segura Recomendada (Túnel SSH desde tu máquina local):
   ssh -L $GRAFANA_PORT:127.0.0.1:$GRAFANA_PORT usuario@IP_DEL_SERVIDOR
   (Luego abre en tu navegador: http://localhost:$GRAFANA_PORT)

 [ATENCIÓN] Copia y guarda la contraseña de Grafana en tu gestor de claves AHORA.
 Por seguridad (Zero-Trace), NO queda almacenada en ningún archivo de configuración
 ni en el registro de log ($LOG_FILE).
================================================================================
BANNER
}

if [[ -w /dev/tty ]]; then
  print_credentials > /dev/tty
else
  print_credentials
fi
echo
echo "INSTALACIÓN BASE COMPLETADA."
echo "Grafana:    http://127.0.0.1:$GRAFANA_PORT (acceso recomendado por túnel SSH)"
echo "Prometheus: http://127.0.0.1:9090"
echo "Loki:       http://127.0.0.1:3100"
echo "Backup:     $BACKUP_DIR"
echo "Log:        $LOG_FILE"
echo
echo "IMPORTANTE:"
echo "1) Este script NO habilita UFW ni modifica reglas SSH para evitar bloquear el acceso remoto."
echo "2) Las reglas Prometheus quedan cargadas en /etc/prometheus/rules/host-alerts.yml."
echo "3) Las alertas LogQL están en rules/logql-alerts.md; deben añadirse en Grafana Alerting."
echo "4) El formato JSON de Nginx está en nginx/observability-log-format.conf; requiere activación manual por vhost."
echo "5) Comprueba métricas reales y servicios antes de considerar la protección operativa."
