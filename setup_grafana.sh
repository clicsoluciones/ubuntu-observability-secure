#!/usr/bin/env bash
# Actualizador y aprovisionador rápido de Grafana (Datasources + Dashboards + Home Dashboard)
# Útil para servidores donde ya se ejecutó install.sh y solo se desea inyectar o reparar los paneles de Grafana.
set -Eeuo pipefail
umask 027

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
GRAFANA_PORT=""
RESET_PASS=0
CUSTOM_PASS=""

show_help() {
  cat <<'EOF'
Uso: sudo ./setup_grafana.sh [OPCIONES]

Aprovisiona o repara las fuentes de datos (Prometheus y Loki), el Dashboard principal
de Observabilidad & Seguridad Activa y la pantalla de inicio (Home Dashboard) en Grafana,
sin necesidad de reinstalar toda la suite.

Opciones:
  --port <PUERTO>         Define el puerto de Grafana (si se omite, detecta el actual o usa 3000).
  --reset-password        Genera una nueva contraseña aleatoria de 24 caracteres para 'admin' y la muestra.
  --password <CLAVE>      Establece la contraseña especificada para el usuario 'admin' en Grafana.
  -h, --help              Muestra esta ayuda.

Ejemplos:
  sudo ./setup_grafana.sh
  sudo ./setup_grafana.sh --reset-password
  sudo ./setup_grafana.sh --port 3001 --reset-password
EOF
}

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
    --reset-password)
      RESET_PASS=1
      shift
      ;;
    --password)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "Error: --password requiere una clave no vacía." >&2
        exit 1
      fi
      RESET_PASS=1
      CUSTOM_PASS="$2"
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

# Auto-detectar puerto actual si no se especificó con --port
OVERRIDE_FILE="/etc/systemd/system/grafana-server.service.d/observability.conf"
if [[ -z "$GRAFANA_PORT" ]]; then
  if [[ -f "$OVERRIDE_FILE" ]]; then
    detected_port=$(sed -n 's/.*GF_SERVER_HTTP_PORT=\([0-9]*\).*/\1/p' "$OVERRIDE_FILE" | head -n 1 || true)
    if [[ -n "$detected_port" ]]; then
      GRAFANA_PORT="$detected_port"
    fi
  fi
  GRAFANA_PORT="${GRAFANA_PORT:-3000}"
fi

echo "==> Aprovisionando fuentes de datos (Prometheus y Loki) en Grafana"
install -d -m 0755 /etc/grafana/provisioning/datasources
install -m 0644 "$SCRIPT_DIR/grafana/provisioning/datasources/datasources.yml" \
  /etc/grafana/provisioning/datasources/observability.yml

echo "==> Aprovisionando proveedor de Dashboards y paneles JSON"
install -d -m 0755 /etc/grafana/provisioning/dashboards
install -m 0644 "$SCRIPT_DIR/grafana/provisioning/dashboards/dashboards.yml" \
  /etc/grafana/provisioning/dashboards/observability-dashboards.yml

echo "==> Aprovisionando catálogo de 16 reglas en Grafana Unified Alerting"
install -d -m 0755 /etc/grafana/provisioning/alerting
install -m 0640 "$SCRIPT_DIR/grafana/provisioning/alerting/alerts.yml" \
  /etc/grafana/provisioning/alerting/observability-alerts.yml
chown root:grafana /etc/grafana/provisioning/alerting/observability-alerts.yml

install -d -o grafana -g grafana -m 0755 /var/lib/grafana/dashboards
install -o grafana -g grafana -m 0644 "$SCRIPT_DIR/grafana/dashboards/ubuntu-security-overview.json" \
  /var/lib/grafana/dashboards/ubuntu-security-overview.json

echo "==> Configurando override de systemd (puerto $GRAFANA_PORT y Home Dashboard automático)"
install -d -m 0755 /etc/systemd/system/grafana-server.service.d
cat > "$OVERRIDE_FILE" <<EOF
[Service]
Environment="GF_SERVER_HTTP_ADDR=127.0.0.1"
Environment="GF_SERVER_HTTP_PORT=$GRAFANA_PORT"
Environment="GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH=/var/lib/grafana/dashboards/ubuntu-security-overview.json"
EOF

# Limpiar posible base de datos huérfana creada en /usr/share/grafana/data
rm -rf /usr/share/grafana/data 2>/dev/null || true
chown -R grafana:grafana /var/lib/grafana 2>/dev/null || true

echo "==> Recargando systemd y reiniciando grafana-server"
systemctl daemon-reload
systemctl enable --now grafana-server
systemctl restart grafana-server

echo -n "==> Esperando a que Grafana esté operativo en 127.0.0.1:$GRAFANA_PORT... "
GRAFANA_READY=0
for _ in {1..15}; do
  if [[ -f /var/lib/grafana/grafana.db ]] && curl -fsSL "http://127.0.0.1:${GRAFANA_PORT}/api/health" >/dev/null 2>&1; then
    GRAFANA_READY=1
    break
  fi
  sleep 2
done

if [[ "$GRAFANA_READY" -eq 1 ]]; then
  echo "[OK]"
else
  echo "[ADVERTENCIA: Timeout esperando /api/health]"
fi

if [[ "$RESET_PASS" -eq 1 ]]; then
  echo "==> Actualizando contraseña del usuario 'admin' en /var/lib/grafana/grafana.db"
  if [[ -n "$CUSTOM_PASS" ]]; then
    ADMIN_PASS="$CUSTOM_PASS"
  else
    ADMIN_PASS="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24)"
  fi

  local_homepath="/usr/share/grafana"
  local_cfg="/etc/grafana/grafana.ini"
  local_data="/var/lib/grafana"
  local_logs="/var/log/grafana"
  local_plugins="/var/lib/grafana/plugins"
  PASS_OK=0

  if command -v grafana >/dev/null 2>&1; then
    if runuser -u grafana -- grafana cli \
      --homepath "$local_homepath" \
      --config "$local_cfg" \
      --configOverrides="cfg:default.paths.data=$local_data cfg:default.paths.logs=$local_logs cfg:default.paths.plugins=$local_plugins" \
      admin reset-admin-password "$ADMIN_PASS" >/dev/null 2>&1; then
      PASS_OK=1
    fi
  fi

  if [[ "$PASS_OK" -eq 0 ]] && command -v grafana-cli >/dev/null 2>&1; then
    if runuser -u grafana -- grafana-cli \
      --homepath "$local_homepath" \
      --config "$local_cfg" \
      --configOverrides="cfg:default.paths.data=$local_data cfg:default.paths.logs=$local_logs cfg:default.paths.plugins=$local_plugins" \
      admin reset-admin-password "$ADMIN_PASS" >/dev/null 2>&1; then
      PASS_OK=1
    fi
  fi

  chown -R grafana:grafana /var/lib/grafana 2>/dev/null || true
  systemctl restart grafana-server

  if [[ "$PASS_OK" -eq 1 ]]; then
    cat <<BANNER

================================================================================
                  CREDENCIALES ACTUALIZADAS DE GRAFANA
================================================================================
  - URL Local:       http://127.0.0.1:$GRAFANA_PORT
  - Usuario:         admin
  - Contraseña:      $ADMIN_PASS
================================================================================
BANNER
  else
    echo "ERROR: No fue posible restablecer la contraseña mediante grafana cli." >&2
  fi
fi

echo
echo "==> Aprovisionamiento completado."
echo "Al ingresar a http://localhost:$GRAFANA_PORT (vía túnel SSH), verás directamente"
echo "el panel 'Ubuntu Observabilidad & Seguridad Activa' como pantalla principal (Home)."
echo "También lo encontrarás en el menú: Dashboards -> carpeta 'Observabilidad y Seguridad'."
