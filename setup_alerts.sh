#!/usr/bin/env bash
# Aprovisionador y personalizador de las 16 Reglas de Alerta (Grafana Unified Alerting + Prometheus)
# y configuración opcional de Contact Points (Discord, Slack, Telegram) sin reinstalar la suite.
set -Eeuo pipefail
umask 027

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
GRAFANA_PORT=""
SSH_LOGIN_ALERT=""
HTTP_RPS_THRESHOLD=""
DISCORD_WEBHOOK=""
SLACK_WEBHOOK=""
TELEGRAM_TOKEN=""
TELEGRAM_CHAT_ID=""

show_help() {
  cat <<'EOF'
Uso: sudo ./setup_alerts.sh [OPCIONES]

Instala, actualiza o personaliza automáticamente el catálogo completo de 16 reglas de alerta
(5 de Salud/Recursos en PromQL + 11 de Seguridad/DDoS/BotScan en LogQL y PromQL) dentro de
Grafana Unified Alerting y Prometheus, y configura opcionalmente el canal de notificación.

Opciones de personalización de reglas:
  --ssh-login-alert <on|off>      Activa ('on') o pausa ('off') la alerta de Login SSH Exitoso
                                  para evitar ruido en servidores con acceso frecuente.
  --http-rps-threshold <NUM>      Personaliza el umbral de peticiones/seg para la alerta de
                                  Inundación HTTP Web L7 (por defecto: 400).

Opciones de canales de notificación (Contact Points automáticos):
  --discord-webhook <URL>         Aprovisiona un Contact Point de Discord y lo asigna como política raíz.
  --slack-webhook <URL>           Aprovisiona un Contact Point de Slack y lo asigna como política raíz.
  --telegram <BOT_TOKEN> <CHAT_ID> Aprovisiona un Contact Point de Telegram y lo asigna como política raíz.

Opciones generales:
  --port <PUERTO>                 Puerto HTTP de Grafana (por defecto: detecta del drop-in o 3000).
  -h, --help                      Muestra esta ayuda y termina.

Ejemplos:
  sudo ./setup_alerts.sh
  sudo ./setup_alerts.sh --ssh-login-alert off --http-rps-threshold 800
  sudo ./setup_alerts.sh --discord-webhook 'https://discord.com/api/webhooks/...'
  sudo ./setup_alerts.sh --telegram '123456:ABC-DEF...' '-100123456789'
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ssh-login-alert)
      if [[ $# -lt 2 || ! "${2:-}" =~ ^(on|off)$ ]]; then
        echo "Error: --ssh-login-alert requiere 'on' u 'off'." >&2
        exit 1
      fi
      SSH_LOGIN_ALERT="$2"
      shift 2
      ;;
    --http-rps-threshold)
      if [[ $# -lt 2 || ! "${2:-}" =~ ^[0-9]+$ || "${2:-}" -lt 1 ]]; then
        echo "Error: --http-rps-threshold requiere un número entero positivo." >&2
        exit 1
      fi
      HTTP_RPS_THRESHOLD="$2"
      shift 2
      ;;
    --discord-webhook)
      if [[ $# -lt 2 || -z "${2:-}" || ! "${2:-}" =~ ^https?:// ]]; then
        echo "Error: --discord-webhook requiere una URL válida (https://...)." >&2
        exit 1
      fi
      DISCORD_WEBHOOK="$2"
      shift 2
      ;;
    --slack-webhook)
      if [[ $# -lt 2 || -z "${2:-}" || ! "${2:-}" =~ ^https?:// ]]; then
        echo "Error: --slack-webhook requiere una URL válida (https://...)." >&2
        exit 1
      fi
      SLACK_WEBHOOK="$2"
      shift 2
      ;;
    --telegram)
      if [[ $# -lt 3 || -z "${2:-}" || -z "${3:-}" ]]; then
        echo "Error: --telegram requiere dos argumentos: <BOT_TOKEN> <CHAT_ID>." >&2
        exit 1
      fi
      TELEGRAM_TOKEN="$2"
      TELEGRAM_CHAT_ID="$3"
      shift 3
      ;;
    --port)
      if [[ $# -lt 2 || ! "${2:-}" =~ ^[0-9]+$ || "${2:-}" -lt 1 || "${2:-}" -gt 65535 ]]; then
        echo "Error: --port requiere un número de puerto válido (1-65535)." >&2
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

# Auto-detectar puerto actual de Grafana
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

echo "==> [1/4] Aprovisionando reglas nativas de Prometheus (/etc/prometheus/rules/host-alerts.yml)"
if getent passwd prometheus >/dev/null 2>&1; then
  install -d -o prometheus -g prometheus -m 0750 /etc/prometheus/rules
  install -o prometheus -g prometheus -m 0640 "$SCRIPT_DIR/rules/host-alerts.yml" /etc/prometheus/rules/host-alerts.yml
else
  install -d -m 0750 /etc/prometheus/rules
  install -m 0640 "$SCRIPT_DIR/rules/host-alerts.yml" /etc/prometheus/rules/host-alerts.yml
fi

if command -v promtool >/dev/null 2>&1; then
  promtool check rules /etc/prometheus/rules/host-alerts.yml
fi

if systemctl is-active --quiet prometheus 2>/dev/null; then
  systemctl reload prometheus 2>/dev/null || systemctl restart prometheus
  echo "  [OK] Prometheus recargado con 9 reglas PromQL de host y red."
fi

echo "==> [2/4] Aprovisionando las 16 reglas y el Dashboard en Grafana"
ALERTING_DIR="/etc/grafana/provisioning/alerting"
TARGET_ALERTS="$ALERTING_DIR/observability-alerts.yml"
DASHBOARDS_DIR="/var/lib/grafana/dashboards"
TARGET_DASHBOARD="$DASHBOARDS_DIR/ubuntu-security-overview.json"

install -d -m 0755 "$ALERTING_DIR"
install -m 0640 "$SCRIPT_DIR/grafana/provisioning/alerting/alerts.yml" "$TARGET_ALERTS"

if getent passwd grafana >/dev/null 2>&1; then
  install -d -o grafana -g grafana -m 0755 "$DASHBOARDS_DIR"
  install -o grafana -g grafana -m 0644 "$SCRIPT_DIR/grafana/dashboards/ubuntu-security-overview.json" "$TARGET_DASHBOARD"
else
  install -d -m 0755 "$DASHBOARDS_DIR"
  install -m 0644 "$SCRIPT_DIR/grafana/dashboards/ubuntu-security-overview.json" "$TARGET_DASHBOARD"
fi
echo "  [OK] Dashboard visual con los 16 vectores y monitor de alertas actualizado en $TARGET_DASHBOARD"

# Aplicar personalizaciones solicitadas por CLI sobre el archivo aprovisionado
if [[ -n "$SSH_LOGIN_ALERT" ]]; then
  if [[ "$SSH_LOGIN_ALERT" == "off" ]]; then
    python3 -c '
import sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    text = f.read()
marker = "uid: alert_ssh_login_success"
idx = text.find(marker)
if idx != -1:
    end_idx = text.find("isPaused:", idx)
    if end_idx != -1:
        line_end = text.find("\n", end_idx)
        text = text[:end_idx] + "isPaused: true" + text[line_end:]
with open(path, "w", encoding="utf-8") as f:
    f.write(text)
' "$TARGET_ALERTS"
    echo "  [OK] Regla 'alert_ssh_login_success' configurada en modo PAUSADO (isPaused: true)."
  else
    echo "  [OK] Regla 'alert_ssh_login_success' configurada en modo ACTIVO (isPaused: false)."
  fi
fi

if [[ -n "$HTTP_RPS_THRESHOLD" ]]; then
  python3 -c '
import sys, re
path, threshold = sys.argv[1], int(sys.argv[2])
with open(path, "r", encoding="utf-8") as f:
    text = f.read()
marker = "uid: alert_ddos_http_flood"
idx = text.find(marker)
if idx != -1:
    next_uid = text.find("- uid:", idx + len(marker))
    block = text[idx:next_uid] if next_uid != -1 else text[idx:]
    block = re.sub(r"title: \"\[DDoS L7\] Inundación HTTP Web \(>[0-9]+ req/s\)\"", f"title: \"[DDoS L7] Inundación HTTP Web (>{threshold} req/s)\"", block)
    block = re.sub(r"(params:\s+-\s+)400", f"\\g<1>{threshold}", block, count=1)
    block = re.sub(r"\(400 req/s\)", f"({threshold} req/s)", block)
    text = (text[:idx] + block + text[next_uid:]) if next_uid != -1 else (text[:idx] + block)
with open(path, "w", encoding="utf-8") as f:
    f.write(text)
' "$TARGET_ALERTS" "$HTTP_RPS_THRESHOLD"
  echo "  [OK] Umbral de 'alert_ddos_http_flood' actualizado a > ${HTTP_RPS_THRESHOLD} req/s."
fi

if getent group grafana >/dev/null 2>&1; then
  chown root:grafana "$TARGET_ALERTS"
  chmod 0640 "$TARGET_ALERTS"
fi

echo "==> [3/4] Verificando canales de notificación (Contact Points)"
TARGET_CONTACTS="$ALERTING_DIR/observability-contactpoints.yml"
if [[ -n "$DISCORD_WEBHOOK" || -n "$SLACK_WEBHOOK" || -n "$TELEGRAM_TOKEN" ]]; then
  cp_name="observability-default-contact"
  {
    echo "apiVersion: 1"
    echo ""
    echo "contactPoints:"
    echo "  - orgId: 1"
    echo "    name: $cp_name"
    echo "    receivers:"
    if [[ -n "$DISCORD_WEBHOOK" ]]; then
      cat <<EOF
      - uid: cp_discord_webhook
        type: discord
        settings:
          url: "$DISCORD_WEBHOOK"
          use_discord_username: true
        disableResolveMessage: false
EOF
    fi
    if [[ -n "$SLACK_WEBHOOK" ]]; then
      cat <<EOF
      - uid: cp_slack_webhook
        type: slack
        settings:
          url: "$SLACK_WEBHOOK"
        disableResolveMessage: false
EOF
    fi
    if [[ -n "$TELEGRAM_TOKEN" ]]; then
      cat <<EOF
      - uid: cp_telegram_bot
        type: telegram
        settings:
          bottoken: "$TELEGRAM_TOKEN"
          chatid: "$TELEGRAM_CHAT_ID"
        disableResolveMessage: false
EOF
    fi
    cat <<EOF

policies:
  - orgId: 1
    receiver: $cp_name
    group_by:
      - grafana_folder
      - alertname
    group_wait: 30s
    group_interval: 5m
    repeat_interval: 4h
EOF
  } > "$TARGET_CONTACTS"

  if getent group grafana >/dev/null 2>&1; then
    chown root:grafana "$TARGET_CONTACTS"
  fi
  chmod 0640 "$TARGET_CONTACTS"
  echo "  [OK] Contact Point y política de notificación aprovisionados en $TARGET_CONTACTS"
else
  echo "  [INFO] No se especificaron flags de webhook (--discord-webhook, --slack-webhook, --telegram)."
  echo "         Las 16 alertas quedan activas en la interfaz de Grafana."
fi

echo "==> [4/4] Reiniciando Grafana y verificando carga de reglas"
if systemctl list-unit-files grafana-server.service >/dev/null 2>&1; then
  systemctl restart grafana-server
  echo -n "  Esperando a que Grafana esté listo en 127.0.0.1:${GRAFANA_PORT}... "
  for _ in {1..15}; do
    if curl -fsSL "http://127.0.0.1:${GRAFANA_PORT}/api/health" >/dev/null 2>&1; then
      echo "[OK]"
      break
    fi
    sleep 2
  done
fi

echo
echo "================================================================================"
echo "     CATÁLOGO DE 16 ALERTAS Y DASHBOARD APROVISIONADOS EN GRAFANA Y PROMETHEUS  "
echo "================================================================================"
echo "  - Archivo Grafana:     $TARGET_ALERTS"
echo "  - Dashboard Visual:    $TARGET_DASHBOARD"
echo "  - Archivo Prometheus:  /etc/prometheus/rules/host-alerts.yml"
echo "  - Carpeta en Grafana:  Alerting -> Alert rules -> 'Observabilidad y Seguridad'"
echo "  - Grupos activos:      1) salud-y-recursos-host (5 reglas PromQL)"
echo "                         2) seguridad-ddos-y-accesos (11 reglas LogQL/PromQL)"
echo "================================================================================"
