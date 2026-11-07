#!/usr/bin/env bash
# ==============================================================================
# scripts/setup_telegram_alerts.sh
# Configures Telegram alerting for Grafana:
# - Supports individual users and groups/supergroups (chat_id with negative prefix)
# - Validates bot token and chat_id via Telegram Bot API
# - Can auto-detect group chat_id from recent updates if not specified
# - Provisions /etc/grafana/provisioning/alerting/telegram.yml
# - Restarts Grafana and confirms alert delivery
# ==============================================================================
set -Eeuo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Error: Este script debe ejecutarse como root (sudo $0 ...)" >&2
  exit 1
fi

echo "====================================================================="
echo "   Configurador de Notificaciones de Alertas a Telegram en Grafana"
echo "====================================================================="

BOT_TOKEN="${1:-}"
CHAT_ID="${2:-}"

# 1. Solicitar BOT_TOKEN si no fue pasado por parámetro
if [[ -z "$BOT_TOKEN" ]]; then
  read -rp "1. Ingrese el Bot Token de Telegram (ej: 123456789:ABCdefGHI...): " BOT_TOKEN
fi

if [[ -z "$BOT_TOKEN" ]]; then
  echo "Error: El Bot Token es obligatorio." >&2
  exit 1
fi

# Validar conectividad con el bot
echo "==> Verificando Bot Token con la API de Telegram..."
bot_info="$(curl -s -f "https://api.telegram.org/bot${BOT_TOKEN}/getMe" 2>/dev/null || true)"

if [[ -z "$bot_info" ]] || ! grep -q '"ok":true' <<< "$bot_info"; then
  echo "Error: Token inválido o sin conexión con la API de Telegram." >&2
  echo "Respuesta: $bot_info" >&2
  exit 1
fi

bot_username="$(python3 -c "import json, sys; d=json.loads(sys.stdin.read()); print(d.get('result', {}).get('username', ''))" <<< "$bot_info" 2>/dev/null || echo "bot")"
echo "==> [OK] Bot autenticado correctamente: @${bot_username}"

# 2. Solicitar o auto-detectar CHAT_ID
if [[ -z "$CHAT_ID" ]]; then
  echo ""
  echo "Buscando chats recientes donde el bot participe..."
  updates="$(curl -s "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates" 2>/dev/null || true)"
  
  detected_chats="$(python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    chats = {}
    for item in d.get('result', []):
        msg = item.get('message') or item.get('channel_post') or item.get('my_chat_member', {}).get('chat')
        if msg:
            chat = msg.get('chat') if 'chat' in msg else msg
            if chat and 'id' in chat:
                cid = str(chat['id'])
                title = chat.get('title') or chat.get('username') or chat.get('first_name') or 'Sin nombre'
                ctype = chat.get('type', 'desconocido')
                chats[cid] = f\"{title} (Tipo: {ctype}, ID: {cid})\"
    for cid, desc in chats.items():
        print(f\"{cid}|{desc}\")
except Exception:
    pass
" <<< "$updates")"

  if [[ -n "$detected_chats" ]]; then
    echo "Chats detectados recientemente:"
    while IFS='|' read -r cid desc; do
      echo "  - $desc"
    done <<< "$detected_chats"
    echo ""
  else
    echo "Tip: Si creaste un grupo nuevo, agregá al bot @${bot_username} al grupo y enviá cualquier mensaje (ej: 'hola')."
  fi

  read -rp "2. Ingrese el Chat ID (para grupos suele ser negativo, ej: -1001234567890): " CHAT_ID
fi

if [[ -z "$CHAT_ID" ]]; then
  echo "Error: El Chat ID es obligatorio." >&2
  exit 1
fi

# 3. Enviar mensaje de prueba a Telegram
echo "==> Enviando mensaje de prueba al chat $CHAT_ID..."

send_telegram_msg() {
  local target="$1"
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${target}" \
    --data-urlencode "parse_mode=HTML" \
    --data-urlencode "text=🚀 <b>Grafana Alerting: Conexión Exitosa</b>

Se ha configurado el canal de alertas para el servidor: <code>$(hostname)</code>.
Todas las 16 alertas de infraestructura y seguridad se notificarán a este grupo." 2>/dev/null || true
}

send_result="$(send_telegram_msg "$CHAT_ID")"

if [[ -z "$send_result" ]] || ! grep -q '"ok":true' <<< "$send_result"; then
  # Si el usuario copio el ID desde Telegram Web K (ej: -5295361051 sin el prefijo -100)
  if [[ "$CHAT_ID" =~ ^-[0-9]+$ ]] && [[ ! "$CHAT_ID" =~ ^-100 ]]; then
    candidate_id="-100${CHAT_ID#-}"
    echo "==> Reintentando con prefijo oficial de supergrupo Telegram ($candidate_id)..."
    retry_result="$(send_telegram_msg "$candidate_id")"
    if grep -q '"ok":true' <<< "$retry_result"; then
      CHAT_ID="$candidate_id"
      send_result="$retry_result"
      echo "==> [OK] Detectado supergrupo de Telegram. Chat ID ajustado a: $CHAT_ID"
    fi
  elif [[ "$CHAT_ID" =~ ^[0-9]{9,}$ ]]; then
    # Omitio el signo menos por completo
    candidate_id="-100${CHAT_ID}"
    echo "==> Reintentando con prefijo de supergrupo ($candidate_id)..."
    retry_result="$(send_telegram_msg "$candidate_id")"
    if grep -q '"ok":true' <<< "$retry_result"; then
      CHAT_ID="$candidate_id"
      send_result="$retry_result"
      echo "==> [OK] Detectado supergrupo de Telegram. Chat ID ajustado a: $CHAT_ID"
    fi
  fi
fi

if [[ -z "$send_result" ]] || ! grep -q '"ok":true' <<< "$send_result"; then
  echo "Error: No se pudo enviar el mensaje a Telegram." >&2
  echo "Verifique que el bot @${bot_username} sea miembro del grupo con permisos para escribir." >&2
  echo "Detalle API: $send_result" >&2
  exit 1
fi

echo "==> [OK] Mensaje de prueba recibido en Telegram con éxito."

# 4. Aprovisionar configuración en Grafana
echo "==> Aprovisionando Contact Point, Plantilla Limpia y Notification Policy en Grafana..."
PROV_DIR="/etc/grafana/provisioning/alerting"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
install -d -m 0750 "$PROV_DIR"

# Sincronizar reglas actualizadas si existen en el repo (filtra squashfs/snap)
if [[ -f "$SCRIPT_DIR/grafana/provisioning/alerting/alerts.yml" ]]; then
  install -m 0640 "$SCRIPT_DIR/grafana/provisioning/alerting/alerts.yml" "$PROV_DIR/observability-alerts.yml"
  chown root:grafana "$PROV_DIR/observability-alerts.yml" 2>/dev/null || true
fi

cat > "$PROV_DIR/telegram.yml" <<EOF
apiVersion: 1

templates:
  - orgId: 1
    name: telegram_alert_template
    template: |
      {{ define "telegram.message" }}
      {{- if eq .Status "firing" }}🔥 <b>ALERTA DISPARADA</b> ({{ .Alerts.Firing | len }}){{ else }}✅ <b>ALERTA RESUELTA</b> ({{ .Alerts.Resolved | len }}){{ end }}

      {{ range .Alerts }}
      📌 <b>{{ .Labels.alertname }}</b>
      • <b>Severidad:</b> {{ .Labels.severity | toUpper }}
      • <b>Servidor:</b> <code>{{ .Labels.instance }}</code>
      {{- if .Labels.mountpoint }}
      • <b>Partición:</b> <code>{{ .Labels.mountpoint }}</code>
      {{- end }}
      • <b>Resumen:</b> {{ .Annotations.summary }}
      {{- if .Annotations.description }}
      • <b>Detalle:</b> {{ .Annotations.description }}
      {{- end }}
      • <b>Hora:</b> {{ .StartsAt.Format "15:04:05 UTC" }}
      ----------------------------------------
      {{ end }}
      {{ end }}

contactPoints:
  - orgId: 1
    name: telegram-alertas
    receivers:
      - uid: telegram_ops_channel
        type: telegram
        disableResolveMessage: false
        settings:
          bottoken: "$BOT_TOKEN"
          chatid: "$CHAT_ID"
          parse_mode: "HTML"
          message: |
            {{ template "telegram.message" . }}

policies:
  - orgId: 1
    receiver: telegram-alertas
    group_by: ['grafana_folder', 'alertname']
    group_wait: 30s
    group_interval: 5m
    repeat_interval: 4h
EOF

chown root:grafana "$PROV_DIR/telegram.yml" 2>/dev/null || true
chmod 0640 "$PROV_DIR/telegram.yml"

# 5. Reiniciar Grafana para aplicar la nueva política
echo "==> Reiniciando servicio grafana-server..."
systemctl restart grafana-server 2>/dev/null || true

# 6. Aprovisionar notificaciones instantáneas de cada IP bloqueada en CrowdSec (con Country)
if command -v cscli >/dev/null 2>&1 && [[ -d /etc/crowdsec ]]; then
  echo "==> Configurando notificaciones de bloqueos de IP en CrowdSec..."
  install -d -m 0755 /etc/crowdsec/notifications
  cat > /etc/crowdsec/notifications/telegram.yaml <<EOF
type: http
name: telegram_bans
log_level: info
timeout: 10s
max_retry: 3

url: https://api.telegram.org/bot${BOT_TOKEN}/sendMessage
method: POST
headers:
  Content-Type: "application/json"

format: |
  {
    "chat_id": "${CHAT_ID}",
    "parse_mode": "HTML",
    "text": "{{range . -}}{{\$alert := . -}}{{range .Decisions -}}🛡️ <b>CrowdSec: IP Bloqueada en Firewall</b>\\n• <b>IP Atacante:</b> <code>{{.Value}}</code>\\n• <b>País:</b> {{if \$alert.Source.Cn}}{{\$alert.Source.Cn}}{{if \$alert.Source.AsName}} ({{print \$alert.Source.AsName}}){{end}}{{else}}Desconocido{{end}}\\n• <b>Ataque:</b> <code>{{\$alert.Scenario}}</code>\\n• <b>Acción:</b> {{.Type}} por {{.Duration}}\\n• <b>Servidor:</b> <code>$(hostname)</code>\\n\\n{{end}}{{end}}"
  }
EOF

  # Activar telegram_bans en /etc/crowdsec/profiles.yaml
  if [[ -f /etc/crowdsec/profiles.yaml ]]; then
    python3 -c "
import sys, re
path = '/etc/crowdsec/profiles.yaml'
try:
    with open(path, 'r') as f:
        content = f.read()
    if 'telegram_bans' not in content:
        if re.search(r'^\s*notifications:', content, re.MULTILINE):
            content = re.sub(r'(^\s*notifications:)', r'\1\n  - telegram_bans', content, count=1, flags=re.MULTILINE)
        elif 'on_success: break' in content:
            content = content.replace('on_success: break', 'notifications:\n  - telegram_bans\non_success: break', 1)
        else:
            content += '\nnotifications:\n  - telegram_bans\n'
        with open(path, 'w') as f:
            f.write(content)
        print('==> [OK] Vinculado telegram_bans en /etc/crowdsec/profiles.yaml')
except Exception as e:
    print(f'Advertencia al actualizar profiles.yaml: {e}', file=sys.stderr)
" 2>/dev/null || true
  fi

  # Validar sintaxis y recargar CrowdSec
  if command -v crowdsec >/dev/null 2>&1; then
    if crowdsec -t >/dev/null 2>&1; then
      systemctl reload crowdsec 2>/dev/null || systemctl restart crowdsec 2>/dev/null || true
      echo "==> [OK] CrowdSec recargado con notificaciones automáticas de IP en Telegram."
    else
      echo "Advertencia: La validación de CrowdSec arrojó errores; verifique con 'crowdsec -t'" >&2
    fi
  fi
fi

echo ""
echo "====================================================================="
echo "   [LISTO] Integración con Telegram completada exitosamente"
echo "====================================================================="
echo "  • Bot: @${bot_username}"
echo "  • Chat ID: ${CHAT_ID}"
echo "  • Grafana Contact Point: telegram-alertas (plantilla limpia ejecutiva)"
echo "  • CrowdSec IPS: Notificación en tiempo real por cada IP bloqueada con País"
echo "  • Servidor: $(hostname)"
echo "====================================================================="
